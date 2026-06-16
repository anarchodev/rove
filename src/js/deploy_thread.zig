//! Background deploy/compile thread. The worker's `/_system/deploy`
//! handler parses an inbound bundle, hands the owned bytes here, and
//! parks the HTTP request; this thread compiles every handler source
//! to bytecode, content-addresses every file into the *target tenant's
//! own* blob backends, and stamps a deployment manifest — entirely OFF
//! the worker poll loop (`feedback: front_door_never_blocks_loop`).
//!
//! ## Why a dedicated thread (and a dedicated compiler)
//!
//! Compilation (`Context.compileToBytecode`, a privileged engine op)
//! plus the S3 PUTs `stageDeployment` issues are both blocking work
//! measured in tens-to-hundreds of ms. Running them on the poll loop
//! would stall every tenant the worker serves. The worker already owns
//! a `QjsCompiler` used by `deployStarterTrampoline` ON the poll loop,
//! so this thread can NOT share it (concurrent use of one QuickJS
//! runtime races). Instead it owns its own runtime/context, created on
//! and used only by this thread — zero shared mutable JS state.
//!
//! ## Model (mirrors `DeploymentLoader`)
//!
//! 1. `enqueue(job)` appends a `Job` (owned tenant id + owned inputs)
//!    and wakes the thread.
//! 2. The thread pops one job at a time (the single compiler runtime
//!    serializes naturally), opens the tenant's `file-blobs` +
//!    `deployments` backends from the shared `BackendConfig`, runs
//!    `files.stageDeployment`, and records a `Result` keyed by the
//!    job's `compile_id`.
//! 3. The worker's `drainCompilePending` (per tick) calls
//!    `takeResult(compile_id)`; on a hit it stamps the staged HTTP
//!    response (`{"dep_id":"…"}` on success, an error body otherwise)
//!    and ships it. No raft, nothing replicated — staging writes the
//!    tenant's own content-addressed blobs; `release` (a separate raft
//!    step) later flips `_deploy/current` to the returned dep_id.
//!
//! Completion is observed by polling `results` each tick (same posture
//! as `fetch_pending_durability` / `forward_pending`); no eventfd wake.

const std = @import("std");
const blob_mod = @import("rove-blob");
const files_mod = @import("rove-files");
const qjs = @import("rove-qjs");

pub const DeployThread = struct {
    allocator: std.mem.Allocator,
    /// Shared blob backend config (`NodeState.blob_backend_cfg`). Per
    /// job we open `{tenant}/file-blobs/` + `{tenant}/deployments/`
    /// against it — the same keys the deployment loader reads.
    blob_cfg: blob_mod.BackendConfig,

    /// Pending jobs (FIFO). Each job owns its tenant id + inputs;
    /// ownership transfers to the thread, which frees them after the
    /// job runs.
    queue: std.ArrayListUnmanaged(Job) = .empty,
    queue_mutex: std.Thread.Mutex = .{},

    /// Set by `enqueue` to wake the thread; cleared at the top of the
    /// work loop.
    wake: std.Thread.ResetEvent = .{},
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    /// Completed results, keyed by `compile_id`. The thread inserts;
    /// the worker's drain `fetchRemove`s. Mutex-guarded — the only
    /// cross-thread shared map.
    results: std.AutoHashMapUnmanaged(u64, Result) = .empty,
    results_mutex: std.Thread.Mutex = .{},

    pub const Job = struct {
        compile_id: u64,
        /// Owned copy of the target tenant id.
        tenant_id: []u8,
        /// Owned inputs — each `path` / `content_type` / `bytes` slice
        /// is an allocator-owned copy. Freed (with the slice itself)
        /// by `freeJob` after the job runs.
        inputs: []files_mod.DeployInput,
    };

    /// A finished deploy. On success `status == 200` and `dep_id` is the
    /// content-addressed deployment id; otherwise `status` is the HTTP
    /// status and `msg` a static (no-ownership) error string.
    pub const Result = struct {
        dep_id: u64 = 0,
        status: u16 = 200,
        msg: []const u8 = "",
    };

    pub fn init(allocator: std.mem.Allocator, blob_cfg: blob_mod.BackendConfig) !*DeployThread {
        const self = try allocator.create(DeployThread);
        self.* = .{ .allocator = allocator, .blob_cfg = blob_cfg };
        return self;
    }

    pub fn start(self: *DeployThread) !void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    pub fn shutdown(self: *DeployThread) void {
        self.stop.store(true, .release);
        self.wake.set();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *DeployThread) void {
        // Caller must have shutdown by here. Free any jobs the thread
        // never reached + the (small, value-only) results map.
        for (self.queue.items) |*job| freeJob(self.allocator, job);
        self.queue.deinit(self.allocator);
        self.results.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Enqueue a job; takes ownership of `job`'s owned memory. The
    /// caller must not touch `job.tenant_id` / `job.inputs` after this.
    pub fn enqueue(self: *DeployThread, job: Job) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        try self.queue.append(self.allocator, job);
        self.wake.set();
    }

    /// Pop a completed result by `compile_id`, or null if the job is
    /// still running (or never existed). Called from the worker poll
    /// loop each tick.
    pub fn takeResult(self: *DeployThread, compile_id: u64) ?Result {
        self.results_mutex.lock();
        defer self.results_mutex.unlock();
        const kv = self.results.fetchRemove(compile_id) orelse return null;
        return kv.value;
    }

    fn putResult(self: *DeployThread, compile_id: u64, result: Result) void {
        self.results_mutex.lock();
        defer self.results_mutex.unlock();
        self.results.put(self.allocator, compile_id, result) catch {
            // OOM recording the result: the parked request will reap on
            // its deadline (504). Nothing else we can do here.
            std.log.err("deploy thread: failed to record result for compile {d}", .{compile_id});
        };
    }

    fn popOne(self: *DeployThread) ?Job {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    fn threadMain(self: *DeployThread) void {
        // One compiler runtime/context for the whole thread lifetime,
        // created on (and used only by) this thread. `null` if init
        // fails — every job then resolves to a 500 "compiler
        // unavailable" instead of hanging the parked request to its
        // deadline.
        var rt_opt: ?qjs.Runtime = qjs.Runtime.init() catch |err| blk: {
            std.log.err("deploy thread: qjs runtime init failed: {s}", .{@errorName(err)});
            break :blk null;
        };
        defer if (rt_opt) |*rt| rt.deinit();

        var ctx_opt: ?qjs.Context = if (rt_opt) |*rt|
            (rt.newContext() catch |err| blk: {
                std.log.err("deploy thread: qjs context init failed: {s}", .{@errorName(err)});
                break :blk null;
            })
        else
            null;
        defer if (ctx_opt) |*c| c.deinit();

        const ctx_ptr: ?*qjs.Context = if (ctx_opt) |*c| c else null;

        while (!self.stop.load(.acquire)) {
            self.wake.wait();
            self.wake.reset();
            if (self.stop.load(.acquire)) break;
            while (self.popOne()) |job_val| {
                var job = job_val;
                const result = self.processJob(ctx_ptr, &job);
                self.putResult(job.compile_id, result);
                freeJob(self.allocator, &job);
            }
        }
    }

    fn processJob(self: *DeployThread, ctx_ptr: ?*qjs.Context, job: *Job) Result {
        const ctx = ctx_ptr orelse return .{ .status = 500, .msg = "compiler unavailable" };

        var file_be = blob_mod.BlobBackend.openPerTenant(
            self.allocator,
            self.blob_cfg,
            job.tenant_id,
            "file-blobs",
        ) catch |err| {
            std.log.warn("deploy thread: open file-blobs for {s} failed: {s}", .{ job.tenant_id, @errorName(err) });
            return .{ .status = 502, .msg = "blob backend open failed" };
        };
        defer file_be.deinit();

        var mani_be = blob_mod.BlobBackend.openPerTenant(
            self.allocator,
            self.blob_cfg,
            job.tenant_id,
            "deployments",
        ) catch |err| {
            std.log.warn("deploy thread: open deployments for {s} failed: {s}", .{ job.tenant_id, @errorName(err) });
            return .{ .status = 502, .msg = "manifest backend open failed" };
        };
        defer mani_be.deinit();

        const dep_id = files_mod.stageDeployment(
            self.allocator,
            file_be.blobStore(),
            mani_be.blobStore(),
            compileThunk,
            ctx,
            job.inputs,
        ) catch |err| {
            std.log.warn("deploy thread: stage {s} (compile {d}) failed: {s}", .{ job.tenant_id, job.compile_id, @errorName(err) });
            return switch (err) {
                error.CompileFailed => .{ .status = 400, .msg = "compile failed" },
                error.InvalidManifest => .{ .status = 400, .msg = "invalid manifest (duplicate paths or too many entries)" },
                error.InvalidPath => .{ .status = 400, .msg = "invalid path" },
                error.Blob => .{ .status = 502, .msg = "blob storage error" },
                error.OutOfMemory => .{ .status = 500, .msg = "out of memory" },
                else => .{ .status = 500, .msg = "deploy failed" },
            };
        };
        return .{ .dep_id = dep_id, .status = 200 };
    }
};

/// `files.CompileFn` over this thread's QuickJS context. `ctx_opaque`
/// is the `*qjs.Context` passed as `compile_ctx`. Mirrors the worker's
/// `QjsCompiler.compile` (module vs script chosen by extension).
fn compileThunk(
    ctx_opaque: ?*anyopaque,
    source: []const u8,
    filename: [:0]const u8,
    allocator: std.mem.Allocator,
) anyerror![]u8 {
    const ctx: *qjs.Context = @ptrCast(@alignCast(ctx_opaque.?));
    const kind: qjs.EvalFlags = if (files_mod.isJsModule(filename))
        .{ .kind = .module }
    else
        .{};
    return ctx.compileToBytecode(source, filename, allocator, kind);
}

/// Free a job's owned memory (its tenant id, every input's owned
/// slices, and the inputs slice itself).
fn freeJob(allocator: std.mem.Allocator, job: *DeployThread.Job) void {
    for (job.inputs) |*in| {
        allocator.free(in.path);
        if (in.content_type.len != 0) allocator.free(in.content_type);
        allocator.free(in.bytes);
    }
    allocator.free(job.inputs);
    allocator.free(job.tenant_id);
}

// ── Tests ──────────────────────────────────────────────────────────
//
// These cover the queue + result-map plumbing in isolation (no network,
// no thread timing). The real compile+stage+S3 path is covered by
// rove-files' `stageDeployment` tests + the deploy smoke.

const testing = std.testing;

const test_cfg: blob_mod.BackendConfig = .{
    .endpoint = "127.0.0.1:1",
    .region = "us",
    .bucket = "b",
    .key_prefix_base = "test/",
    .access_key = "k",
    .secret_key = "s",
    .use_tls = false,
};

fn makeJob(compile_id: u64, tenant: []const u8) !DeployThread.Job {
    const inputs = try testing.allocator.alloc(files_mod.DeployInput, 1);
    inputs[0] = .{
        .path = try testing.allocator.dupe(u8, "index.mjs"),
        .kind = .handler,
        .content_type = try testing.allocator.dupe(u8, ""),
        .bytes = try testing.allocator.dupe(u8, "export default {}"),
    };
    return .{
        .compile_id = compile_id,
        .tenant_id = try testing.allocator.dupe(u8, tenant),
        .inputs = inputs,
    };
}

test "queue is FIFO; popOne transfers ownership" {
    const dt = try DeployThread.init(testing.allocator, test_cfg);
    defer dt.deinit();

    try dt.enqueue(try makeJob(1, "acme"));
    try dt.enqueue(try makeJob(2, "beta"));

    var first = dt.popOne().?;
    try testing.expectEqual(@as(u64, 1), first.compile_id);
    try testing.expectEqualStrings("acme", first.tenant_id);
    freeJob(testing.allocator, &first);

    var second = dt.popOne().?;
    try testing.expectEqual(@as(u64, 2), second.compile_id);
    freeJob(testing.allocator, &second);

    try testing.expect(dt.popOne() == null);
}

test "deinit frees jobs the thread never reached" {
    const dt = try DeployThread.init(testing.allocator, test_cfg);
    // No shutdown/pop — the queued job's owned memory must be freed by
    // deinit (leak-checked by the test allocator).
    try dt.enqueue(try makeJob(3, "gamma"));
    dt.deinit();
}

test "result map round-trips and a take consumes it" {
    const dt = try DeployThread.init(testing.allocator, test_cfg);
    defer dt.deinit();

    try testing.expect(dt.takeResult(5) == null);
    dt.putResult(5, .{ .dep_id = 0x42, .status = 200 });
    const r = dt.takeResult(5).?;
    try testing.expectEqual(@as(u64, 0x42), r.dep_id);
    try testing.expectEqual(@as(u16, 200), r.status);
    // Consumed — a second take is null.
    try testing.expect(dt.takeResult(5) == null);
}
