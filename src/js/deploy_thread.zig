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
const components_mod = @import("components.zig");
const msg_router_mod = @import("msg_router.zig");

/// The trusted-door origin the `platform.compile` shim's `on.fetch`
/// stamps on its PendingFetch. Never reaches libcurl — `interpretCmd`
/// intercepts it (sibling to `rove-blob.internal` / `rove-receive.internal`)
/// and hands it to `worker.submitCompile`.
pub const COMPILE_ORIGIN_PREFIX = "http://rove-compile.internal/";

pub fn isCompileUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, COMPILE_ORIGIN_PREFIX);
}

pub const DeployThread = struct {
    allocator: std.mem.Allocator,
    /// Shared blob backend config (`NodeState.blob_backend_cfg`). Per
    /// job we open `{tenant}/file-blobs/` + `{tenant}/deployments/`
    /// against it — the same keys the deployment loader reads.
    blob_cfg: blob_mod.BackendConfig,
    /// The node's message router (`NodeState.router`). `compile_batch`
    /// jobs emit their terminal `UpstreamFetchEvent` through it to
    /// resume the held chain (the `blob_receive` pattern). Null in
    /// library/test builds that only run full-stage jobs.
    router: ?*msg_router_mod.MsgRouter = null,

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

    /// Completed full-stage results (`/_system/deploy`), keyed by
    /// `compile_id`. The thread inserts; the worker's drain
    /// `fetchRemove`s. Guarded by `results_mutex`. (`compile_batch`
    /// jobs don't use this — they emit a terminal event directly.)
    results: std.AutoHashMapUnmanaged(u64, Result) = .empty,
    results_mutex: std.Thread.Mutex = .{},

    pub const JobKind = enum {
        /// Full deploy: compile + stage + stamp manifest → dep_id
        /// (the `/_system/deploy` route). Result in `results`, picked
        /// up by `drainCompilePending`.
        stage,
        /// Batch compile handler sources + stage source/bytecode blobs
        /// into the SCOPE tenant, then emit a terminal `UpstreamFetchEvent`
        /// (the per-file hashes in `ctx_json`) through the router to resume
        /// the held chain on the CHAIN tenant (the `platform.compile`
        /// primitive). No manifest — the JS handler stamps it.
        compile_batch,
        /// Deferred cross-tenant content-addressed blob PUT into the SCOPE
        /// tenant's `file-blobs` (`platform.scope(t).blob.put`). The hash
        /// is returned to JS synchronously (derivable from the bytes); the
        /// PUT rides here off the poll loop. Fire-and-forget (`key`=hash,
        /// `payload`=bytes).
        blob_put,
        /// Deferred cross-tenant manifest PUT into the SCOPE tenant's
        /// `deployments/` (`platform.scope(t).deploy.stampManifest`). The
        /// dep_id is returned to JS synchronously (derivable from the
        /// entries); the PUT rides here. Fire-and-forget (`key`=manifest
        /// key, `payload`=manifest JSON).
        manifest_put,
    };

    pub const Job = struct {
        compile_id: u64,
        kind: JobKind = .stage,
        /// Owned copy of the target tenant id. For `compile_batch` /
        /// `blob_put` / `manifest_put` this is the SCOPE tenant.
        tenant_id: []u8,
        /// Owned inputs — each `path` / `content_type` / `bytes` slice
        /// is an allocator-owned copy. Freed (with the slice itself)
        /// by `freeJob` after the job runs. Empty for `*_put` jobs.
        inputs: []files_mod.DeployInput = &.{},
        // ── compile_batch-only routing (empty `&.{}` for other kinds) ──
        /// The tenant holding the bound chain (the issuing `__admin__`)
        /// — where the terminal event routes + the held socket resumes.
        /// Distinct from `tenant_id` (the scope). Owned.
        chain_tenant: []u8 = &.{},
        /// The bound `PendingFetch` id (`bound_fetch_entities` key) the
        /// terminal event must carry so the resume finds the held chain.
        /// Owned.
        fetch_id: []u8 = &.{},
        /// Resume export override (`on.fetch`'s `to`); empty → the
        /// default (`onFetchResult`). Owned.
        name: []u8 = &.{},
        // ── *_put-only payload (empty `&.{}` for other kinds) ──
        /// blob_put: the content hash (file-blobs key). manifest_put: the
        /// manifest key. Owned.
        key: []u8 = &.{},
        /// blob_put: the blob bytes. manifest_put: the manifest JSON.
        /// Owned.
        payload: []u8 = &.{},
    };

    /// A finished full-stage deploy. On success `status == 200` and
    /// `dep_id` is the content-addressed deployment id; otherwise
    /// `status` is the HTTP status and `msg` a static error string.
    pub const Result = struct {
        dep_id: u64 = 0,
        status: u16 = 200,
        msg: []const u8 = "",
    };

    pub fn init(
        allocator: std.mem.Allocator,
        blob_cfg: blob_mod.BackendConfig,
        router: ?*msg_router_mod.MsgRouter,
    ) !*DeployThread {
        const self = try allocator.create(DeployThread);
        self.* = .{ .allocator = allocator, .blob_cfg = blob_cfg, .router = router };
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
        // never reached + both results maps (compile_results values own
        // their files/paths; takers that never ran leave them here).
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
                switch (job.kind) {
                    .stage => self.putResult(job.compile_id, self.processStage(ctx_ptr, &job)),
                    .compile_batch => self.processCompileBatch(ctx_ptr, &job),
                    .blob_put => self.processKeyedPut(&job, "file-blobs"),
                    .manifest_put => self.processKeyedPut(&job, "deployments"),
                }
                freeJob(self.allocator, &job);
            }
        }
    }

    fn processStage(self: *DeployThread, ctx_ptr: ?*qjs.Context, job: *Job) Result {
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

    /// Deferred cross-tenant content-addressed PUT into the SCOPE tenant's
    /// `{subdir}` backend (`blob_put` → file-blobs, `manifest_put` →
    /// deployments). Fire-and-forget: the deterministic key/dep_id was
    /// already returned to JS synchronously; this just lands the bytes off
    /// the poll loop. Content-addressed, so a retry/redeploy is safe.
    fn processKeyedPut(self: *DeployThread, job: *Job, subdir: []const u8) void {
        var be = blob_mod.BlobBackend.openPerTenant(self.allocator, self.blob_cfg, job.tenant_id, subdir) catch |err| {
            std.log.warn("deploy thread: {s} open {s}/{s} failed: {s}", .{ @tagName(job.kind), job.tenant_id, subdir, @errorName(err) });
            return;
        };
        defer be.deinit();
        // Idempotent skip-if-present (content-addressed) for file-blobs;
        // manifests are dep_id-keyed (also content-addressed) so the same
        // skip applies. Best-effort: a failed PUT logs; the deploy's
        // release step is the customer's gate, not this.
        files_mod.putBlobIfMissingTo(be.blobStore(), job.key, job.payload) catch |err|
            std.log.warn("deploy thread: {s} PUT {s}/{s}/{s} failed: {s}", .{ @tagName(job.kind), job.tenant_id, subdir, job.key, @errorName(err) });
    }

    /// Compile + stage the batch into the SCOPE tenant, then emit ONE
    /// terminal `UpstreamFetchEvent` through the router to resume the held
    /// chain on the CHAIN tenant (the `blob_receive` pattern). The hashes
    /// (or an error) ride `ctx_json` → the resume export's `request.ctx`.
    fn processCompileBatch(self: *DeployThread, ctx_ptr: ?*qjs.Context, job: *Job) void {
        const router = self.router orelse {
            std.log.err("deploy thread: compile_batch with no router; held chain id={s} will reap on deadline", .{job.fetch_id});
            return;
        };
        const a = self.allocator;

        const fail = struct {
            fn emit(dt: *DeployThread, r: *msg_router_mod.MsgRouter, j: *Job, status: u16, msg: []const u8) void {
                const cj = std.fmt.allocPrint(dt.allocator, "{{\"ok\":false,\"status\":{d},\"error\":\"{s}\"}}", .{ status, msg }) catch return;
                routeCompileEvent(r, dt.allocator, j.fetch_id, j.chain_tenant, j.name, status, false, cj);
            }
        }.emit;

        const ctx = ctx_ptr orelse return fail(self, router, job, 500, "compiler unavailable");

        var file_be = blob_mod.BlobBackend.openPerTenant(a, self.blob_cfg, job.tenant_id, "file-blobs") catch |err| {
            std.log.warn("deploy thread: open file-blobs for {s} failed: {s}", .{ job.tenant_id, @errorName(err) });
            return fail(self, router, job, 502, "blob backend open failed");
        };
        defer file_be.deinit();

        const compiled = files_mod.compileAndStage(a, file_be.blobStore(), compileThunk, ctx, job.inputs) catch |err| {
            std.log.warn("deploy thread: compile-batch scope={s} (compile {d}) failed: {s}", .{ job.tenant_id, job.compile_id, @errorName(err) });
            const status: u16, const msg: []const u8 = switch (err) {
                error.CompileFailed => .{ 400, "compile failed" },
                error.InvalidManifest => .{ 400, "invalid input (duplicate paths or too many entries)" },
                error.InvalidPath => .{ 400, "invalid path" },
                error.Blob => .{ 502, "blob storage error" },
                error.OutOfMemory => .{ 500, "out of memory" },
                else => .{ 500, "compile failed" },
            };
            return fail(self, router, job, status, msg);
        };
        defer a.free(compiled); // the CompiledFile slice (paths borrow `job.inputs`)

        const ctx_json = buildResultsJson(a, compiled) catch
            return fail(self, router, job, 500, "out of memory");
        routeCompileEvent(router, a, job.fetch_id, job.chain_tenant, job.name, 200, true, ctx_json);
    }
};

/// Build the `ctx_json` payload for a successful compile batch:
/// `{"ok":true,"results":[{"path","source_hex","bytecode_hex"},...]}`.
/// Paths are pre-validated (lowercase/digits/`-_./`) so no JSON escaping
/// is needed; hashes are hex. Caller owns the result.
fn buildResultsJson(allocator: std.mem.Allocator, compiled: []const files_mod.CompiledFile) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"ok\":true,\"results\":[");
    for (compiled, 0..) |cf, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"path\":\"{s}\",\"source_hex\":\"{s}\",\"bytecode_hex\":\"{s}\"}}", .{ cf.path, &cf.source_hex, &cf.bytecode_hex });
    }
    try w.writeAll("]}");
    return buf.toOwnedSlice(allocator);
}

/// Build + route a terminal bound `UpstreamFetchEvent` so the held chain
/// resumes (mirrors `blob_receive.emitTerminal`). Takes ownership of
/// `ctx_json_owned`. `bind=true` routes it to the worker holding the
/// chain; `name` (empty → default `onFetchResult`) is the resume export.
pub fn routeCompileEvent(
    router: *msg_router_mod.MsgRouter,
    allocator: std.mem.Allocator,
    fetch_id: []const u8,
    chain_tenant: []const u8,
    name: []const u8,
    status: u16,
    ok: bool,
    ctx_json_owned: []u8,
) void {
    var ev: components_mod.UpstreamFetchEvent = .{
        .final = true,
        .terminal_ok = ok,
        .terminal_status = status,
        .stream = false,
        .bind = true,
    };
    ev.ctx_json = ctx_json_owned; // take ownership
    ev.fetch_id = allocator.dupe(u8, fetch_id) catch {
        components_mod.UpstreamFetchEvent.deinitItem(&ev, allocator);
        return;
    };
    ev.tenant_id = allocator.dupe(u8, chain_tenant) catch {
        components_mod.UpstreamFetchEvent.deinitItem(&ev, allocator);
        return;
    };
    if (name.len != 0) {
        ev.name = allocator.dupe(u8, name) catch {
            components_mod.UpstreamFetchEvent.deinitItem(&ev, allocator);
            return;
        };
    }
    router.enqueueFetchEventForTenant(chain_tenant, ev) catch |err| {
        std.log.warn("deploy thread: compile event route failed chain={s} id={s}: {s}", .{ chain_tenant, fetch_id, @errorName(err) });
        var e = ev;
        components_mod.UpstreamFetchEvent.deinitItem(&e, allocator);
    };
}

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
    // compile_batch-only routing fields (empty `&.{}` for other kinds).
    if (job.chain_tenant.len != 0) allocator.free(job.chain_tenant);
    if (job.fetch_id.len != 0) allocator.free(job.fetch_id);
    if (job.name.len != 0) allocator.free(job.name);
    // *_put-only payload (empty `&.{}` for other kinds).
    if (job.key.len != 0) allocator.free(job.key);
    if (job.payload.len != 0) allocator.free(job.payload);
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
    const dt = try DeployThread.init(testing.allocator, test_cfg, null);
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
    const dt = try DeployThread.init(testing.allocator, test_cfg, null);
    // No shutdown/pop — the queued job's owned memory must be freed by
    // deinit (leak-checked by the test allocator).
    try dt.enqueue(try makeJob(3, "gamma"));
    dt.deinit();
}

test "result map round-trips and a take consumes it" {
    const dt = try DeployThread.init(testing.allocator, test_cfg, null);
    defer dt.deinit();

    try testing.expect(dt.takeResult(5) == null);
    dt.putResult(5, .{ .dep_id = 0x42, .status = 200 });
    const r = dt.takeResult(5).?;
    try testing.expectEqual(@as(u64, 0x42), r.dep_id);
    try testing.expectEqual(@as(u16, 200), r.status);
    // Consumed — a second take is null.
    try testing.expect(dt.takeResult(5) == null);
}

test "freeJob frees compile_batch routing fields" {
    const a = testing.allocator;
    const inputs = try a.alloc(files_mod.DeployInput, 1);
    inputs[0] = .{
        .path = try a.dupe(u8, "index.mjs"),
        .kind = .handler,
        .content_type = try a.dupe(u8, ""),
        .bytes = try a.dupe(u8, "export default {}"),
    };
    var job: DeployThread.Job = .{
        .compile_id = 1,
        .kind = .compile_batch,
        .tenant_id = try a.dupe(u8, "scope-tenant"),
        .inputs = inputs,
        .chain_tenant = try a.dupe(u8, "__admin__"),
        .fetch_id = try a.dupe(u8, "deadbeef"),
        .name = try a.dupe(u8, "onCompiled"),
    };
    // Leak-checked: every owned field (incl. the routing trio) frees.
    freeJob(a, &job);
}
