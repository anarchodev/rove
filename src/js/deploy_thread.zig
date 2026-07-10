//! Background deploy/compile thread. Backs the `platform.*` deploy
//! primitives the standing `__admin__` deploy app composes (`platform.compile`
//! / `platform.scope(t).blob.put` / `platform.scope(t).deploy.stampManifest`
//! — `docs/plans/rewind-cli-plan.md` §4). Each is issued as an `on.fetch` to a
//! trusted-door origin that `interpretCmd` intercepts and hands here; this
//! thread does the blocking work — compile handler sources to bytecode,
//! content-address files into the *target tenant's own* blob backends, PUT
//! the manifest — entirely OFF the worker poll loop
//! (`feedback: front_door_never_blocks_loop`).
//!
//! ## Why a dedicated thread (and a dedicated compiler)
//!
//! Compilation (`Context.compileToBytecode`, a privileged engine op) plus the
//! S3 PUTs are blocking work measured in tens-to-hundreds of ms. Running them
//! on the poll loop would stall every tenant the worker serves. The worker
//! already owns a `QjsCompiler` used by `deployStarterTrampoline` ON the poll
//! loop, so this thread can NOT share it (concurrent use of one QuickJS
//! runtime races). Instead it owns its own runtime/context, created on and
//! used only by this thread — zero shared mutable JS state.
//!
//! ## Model (mirrors `DeploymentLoader`)
//!
//! 1. `enqueue(job)` appends a `Job` (owned tenant id + owned payload/inputs)
//!    and wakes the thread.
//! 2. The thread pops one job at a time (the single compiler runtime
//!    serializes naturally) and runs it by kind: `compile_batch` compiles +
//!    stages bytecode blobs; `blob_put` lands a deferred content-addressed
//!    PUT; `manifest_put` PUTs the manifest (the deploy's staging barrier).
//! 3. Each job's completion is delivered back to the held `__admin__` chain
//!    as a BOUND `UpstreamFetchEvent` through the `MsgRouter` (`compile_batch`
//!    + `manifest_put`), resuming the parked handler. No raft, nothing
//!    replicated — staging writes the tenant's own content-addressed blobs;
//!    `release` (a separate raft step) later flips `_deploy/current`.

const std = @import("std");
const blob_mod = @import("rove-blob");
const files_mod = @import("rove-files");
const qjs = @import("rove-qjs");
const components_mod = @import("components.zig");
const msg_router_mod = @import("msg_router.zig");
const module_execution = @import("module_execution.zig");
const bytecode_cache_mod = @import("bytecode_cache.zig");

/// The trusted-door origin the `platform.compile` shim's `on.fetch`
/// stamps on its PendingFetch. Never reaches libcurl — `interpretCmd`
/// intercepts it (sibling to `rove-blob.internal` / `rove-receive.internal`)
/// and hands it to `worker.submitCompile`.
pub const COMPILE_ORIGIN_PREFIX = "http://rove-compile.internal/";

pub fn isCompileUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, COMPILE_ORIGIN_PREFIX);
}

/// `platform.scope(t).deploy.stampManifest` lowers to an on.fetch to this
/// origin. Intercepted in `interpretCmd` (sibling to the compile door) →
/// `worker.submitStampManifest`. It's the deploy's STAGING BARRIER: the
/// manifest_put is the last FIFO job on the single DeployThread, so its
/// completion proves all prior bytecode + static PUTs for the deploy are
/// durable — the bound completion event re-enters the held chain with the
/// dep_id, and the app can release without racing staging.
pub const STAGE_ORIGIN_PREFIX = "http://rove-stage.internal/";

pub fn isStageUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, STAGE_ORIGIN_PREFIX);
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

    pub const JobKind = enum {
        /// Batch compile handler sources + stage source/bytecode blobs
        /// into the SCOPE tenant, then emit a terminal `UpstreamFetchEvent`
        /// (the per-file hashes in `ctx_json`) through the router to resume
        /// the held chain on the CHAIN tenant (the `platform.compile`
        /// primitive). No manifest — the JS handler stamps it.
        compile_batch,
        /// The deploy's STAGING BARRIER + manifest write
        /// (`platform.scope(t).deploy.stampManifest`). PUTs the manifest
        /// into the SCOPE tenant's `deployments/`, then — being the LAST FIFO
        /// job for the deploy (the bytecode compile_batch preceded it; statics
        /// stream straight to S3 via blob.receive before the cut) — its
        /// completion proves the whole deploy is durable, so it emits a BOUND
        /// completion event (`{ok, dep_id}` in ctx_json) to resume the held
        /// chain. `key`=manifest key, `payload`=manifest JSON, `dep_id` for the
        /// event; `chain_tenant`/`fetch_id`/`name` route the resume.
        manifest_put,
    };

    pub const Job = struct {
        compile_id: u64,
        kind: JobKind,
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
        /// compile_batch: the issue-time `ctx` (on.fetch's threaded ctx,
        /// raw JSON) echoed back in the completion under `app` so the
        /// handler can thread state across the compile re-entry (e.g. the
        /// deploy app's `{target, statics}`). `"null"`/empty when absent.
        /// Owned.
        app_ctx: []u8 = &.{},
        // ── *_put-only payload (empty `&.{}` for other kinds) ──
        /// blob_put: the content hash (file-blobs key). manifest_put: the
        /// manifest key. Owned.
        key: []u8 = &.{},
        /// blob_put: the blob bytes. manifest_put: the manifest JSON.
        /// Owned.
        payload: []u8 = &.{},
        /// manifest_put: the dep_id to carry in the bound completion event.
        dep_id: u64 = 0,
        // ── compile_batch package context (PM P1) ──
        /// Raw `{packages, app_imports}` JSON (the manifest v2 section
        /// shapes) — the deploy's resolution side-channel. Referenced
        /// package bytecodes are fetched into the compile loader's map so
        /// every import resolves (= is validated) at compile. Empty → no
        /// packages in play. Owned.
        resolution_json: []u8 = &.{},
        /// Non-empty → this batch compiles a PACKAGE's files: each input
        /// compiles under its `/pkg/<pkg_hash>/<path>` virtual name (the
        /// module's baked identity + runtime resolution base). 64-hex,
        /// validated at the submit door. Owned.
        pkg_hash: []u8 = &.{},
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
        // never reached (their owned tenant id / inputs / payload).
        for (self.queue.items) |*job| freeJob(self.allocator, job);
        self.queue.deinit(self.allocator);
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

    fn popOne(self: *DeployThread) ?Job {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    fn threadMain(self: *DeployThread) void {
        // One compiler runtime for the whole thread lifetime, created on
        // (and used only by) this thread. `null` if init fails — every
        // job then resolves to a 500 "compiler unavailable" instead of
        // hanging the parked request to its deadline. The CONTEXT is
        // per-job (`processCompileBatch`): quickjs registers every
        // compiled/loaded module in the context's module table, so a
        // long-lived context would leak modules across jobs and let a
        // stale same-name module from one tenant's batch satisfy (or
        // pollute) another's import resolution.
        var rt_opt: ?qjs.Runtime = qjs.Runtime.init() catch |err| blk: {
            std.log.err("deploy thread: qjs runtime init failed: {s}", .{@errorName(err)});
            break :blk null;
        };
        defer if (rt_opt) |*rt| rt.deinit();

        const rt_ptr: ?*qjs.Runtime = if (rt_opt) |*rt| rt else null;

        while (!self.stop.load(.acquire)) {
            self.wake.wait();
            self.wake.reset();
            if (self.stop.load(.acquire)) break;
            while (self.popOne()) |job_val| {
                var job = job_val;
                switch (job.kind) {
                    .compile_batch => self.processCompileBatch(rt_ptr, &job),
                    .manifest_put => self.processManifestPut(&job),
                }
                freeJob(self.allocator, &job);
            }
        }
    }

    /// The staging-barrier manifest write: PUT the manifest into the SCOPE
    /// tenant's `deployments/`, then emit the bound completion event. Being
    /// the LAST FIFO job for the deploy, its completion proves every prior
    /// bytecode + static PUT has run — so the held chain resumes safe to
    /// release. `ctx_json` = `{ok, dep_id}`.
    fn processManifestPut(self: *DeployThread, job: *Job) void {
        const router = self.router orelse {
            std.log.err("deploy thread: manifest_put with no router; chain id={s} will reap on deadline", .{job.fetch_id});
            return;
        };
        const a = self.allocator;
        var put_ok = true;
        if (blob_mod.BlobBackend.openPerTenant(a, self.blob_cfg, job.tenant_id, "deployments")) |be_const| {
            var be = be_const;
            defer be.deinit();
            files_mod.putBlobIfMissingTo(be.blobStore(), job.key, job.payload) catch |err| {
                std.log.warn("deploy thread: manifest_put PUT {s}/deployments/{s} failed: {s}", .{ job.tenant_id, job.key, @errorName(err) });
                put_ok = false;
            };
        } else |err| {
            std.log.warn("deploy thread: manifest_put open {s}/deployments failed: {s}", .{ job.tenant_id, @errorName(err) });
            put_ok = false;
        }
        const ctx_json = std.fmt.allocPrint(a, "{{\"ok\":{s},\"dep_id\":\"{x:0>16}\"}}", .{ if (put_ok) "true" else "false", job.dep_id }) catch return;
        routeCompileEvent(router, a, job.fetch_id, job.chain_tenant, job.name, if (put_ok) 200 else 502, put_ok, ctx_json);
    }

    /// Compile + stage the batch into the SCOPE tenant, then emit ONE
    /// terminal `UpstreamFetchEvent` through the router to resume the held
    /// chain on the CHAIN tenant (the `blob_receive` pattern). The hashes
    /// (or an error) ride `ctx_json` → the resume export's `request.ctx`.
    fn processCompileBatch(self: *DeployThread, rt_ptr: ?*qjs.Runtime, job: *Job) void {
        const router = self.router orelse {
            std.log.err("deploy thread: compile_batch with no router; held chain id={s} will reap on deadline", .{job.fetch_id});
            return;
        };
        const a = self.allocator;

        const fail = struct {
            fn emit(dt: *DeployThread, r: *msg_router_mod.MsgRouter, j: *Job, status: u16, msg: []const u8) void {
                const cj = errorCtxJson(dt.allocator, status, msg) catch return;
                routeCompileEvent(r, dt.allocator, j.fetch_id, j.chain_tenant, j.name, status, false, cj);
            }
        }.emit;

        // PM P2 static gate: package source must not name the privileged
        // surface. Best-effort lexical backstop — the real boundary is the
        // natives' own `is_system_module` self-gate; this exists to reject
        // a package that even *mentions* `_system` / `__rove` with a clear
        // deploy-time error instead of a confusing runtime one (and it
        // deliberately hits comments/strings too — a distributed package
        // has no business naming the privileged surface at all).
        if (job.pkg_hash.len != 0) {
            for (job.inputs) |in| {
                if (referencesPrivilegedSurface(in.bytes)) {
                    std.log.warn("deploy thread: package {s} file {s} references the privileged surface; rejecting", .{ job.pkg_hash, in.path });
                    return fail(self, router, job, 400, "package source must not reference the privileged surface (_system / __rove)");
                }
            }
        }

        const rt = rt_ptr orelse return fail(self, router, job, 500, "compiler unavailable");
        // Fresh context per job — hermetic module table (see threadMain).
        var jctx = rt.newContext() catch |err| {
            std.log.err("deploy thread: qjs context init failed: {s}", .{@errorName(err)});
            return fail(self, router, job, 500, "compiler unavailable");
        };
        defer jctx.deinit();

        var file_be = blob_mod.BlobBackend.openPerTenant(a, self.blob_cfg, job.tenant_id, "file-blobs") catch |err| {
            std.log.warn("deploy thread: open file-blobs for {s} failed: {s}", .{ job.tenant_id, @errorName(err) });
            return fail(self, router, job, 502, "blob backend open failed");
        };
        defer file_be.deinit();

        // PM P1: stage the job's resolution context BEFORE compiling.
        // quickjs resolves + loads every import at compile (the deploy's
        // import-validation gate), so the loader must be able to serve the
        // referenced package bytecodes. Map values are job-local heap
        // blobs, freed on the way out.
        var pkg_bc: std.StringHashMapUnmanaged(*bytecode_cache_mod.BlobBytes) = .empty;
        defer {
            var it = pkg_bc.iterator();
            while (it.next()) |e| {
                a.free(e.value_ptr.*.bytes);
                a.destroy(e.value_ptr.*);
                a.free(e.key_ptr.*);
            }
            pkg_bc.deinit(a);
        }
        var resolver: ?module_execution.PackageResolver = null;
        defer if (resolver) |*r| r.deinit(a);

        if (job.resolution_json.len != 0) {
            var resolution = files_mod.manifest_json.decodeResolution(a, job.resolution_json) catch
                return fail(self, router, job, 400, "invalid resolution");
            defer resolution.deinit();
            resolver = module_execution.buildResolver(a, resolution.packages, resolution.app_imports) catch
                return fail(self, router, job, 500, "out of memory");

            const bs = file_be.blobStore();
            for (resolution.packages) |p| {
                for (p.files) |f| {
                    const key = std.fmt.allocPrint(a, "/pkg/{s}/{s}", .{ &p.pkg_hash_hex, f.path }) catch
                        return fail(self, router, job, 500, "out of memory");
                    if (pkg_bc.contains(key)) {
                        // Same pkg_hash listed twice — content-identical.
                        a.free(key);
                        continue;
                    }
                    // `bc/{hash}` — engine-only bytecode namespace (the
                    // JS_ReadObject trust boundary): an uploaded blob's
                    // hash laundered into `bytecode_hash` finds nothing
                    // here and fails loud.
                    var bc_key_buf: [files_mod.BC_KEY_LEN]u8 = undefined;
                    const bytes = bs.get(files_mod.bcKey(&bc_key_buf, &f.bytecode_hex), a) catch {
                        std.log.warn("deploy thread: package bytecode {s} for {s} not staged", .{ &f.bytecode_hex, key });
                        a.free(key);
                        return fail(self, router, job, 400, "package bytecode not staged");
                    };
                    const bb = a.create(bytecode_cache_mod.BlobBytes) catch {
                        a.free(key);
                        a.free(bytes);
                        return fail(self, router, job, 500, "out of memory");
                    };
                    bb.* = .{ .bytes = bytes, .hash_hex = f.bytecode_hex, .refcount = std.atomic.Value(u32).init(1) };
                    pkg_bc.put(a, key, bb) catch {
                        a.free(key);
                        a.free(bytes);
                        a.destroy(bb);
                        return fail(self, router, job, 500, "out of memory");
                    };
                }
            }
        }

        // Install the module loader for this job's compile calls, and
        // clear it before `lctx` (stack) goes out of scope.
        var lctx = module_execution.module_loader.Ctx{
            .allocator = a,
            .bytecodes = &pkg_bc,
            .resolver = if (resolver) |*r| r else null,
        };
        qjs.c.JS_SetModuleLoaderFunc(rt.raw, module_execution.module_loader.normalize, module_execution.module_loader.load, &lctx);
        defer qjs.c.JS_SetModuleLoaderFunc(rt.raw, null, null, null);

        // A package batch compiles each file under its package-virtual
        // name — the module's baked identity + the base its own imports
        // (re-)resolve against, at compile and at every runtime load.
        var vdir_buf: [files_mod.MAX_VIRTUAL_DIR_LEN]u8 = undefined;
        const virtual_dir: []const u8 = if (job.pkg_hash.len != 0)
            std.fmt.bufPrint(&vdir_buf, "/pkg/{s}/", .{job.pkg_hash}) catch
                return fail(self, router, job, 400, "invalid pkg_hash")
        else
            "";

        const compiled = files_mod.compileAndStage(a, file_be.blobStore(), compileThunk, &jctx, job.inputs, virtual_dir) catch |err| {
            std.log.warn("deploy thread: compile-batch scope={s} (compile {d}) failed: {s}", .{ job.tenant_id, job.compile_id, @errorName(err) });
            // Author feedback (PM P2): a CompileFailed leaves the quickjs
            // exception pending on the job context — its message names the
            // actual problem (syntax error, or "could not load module
            // '@scope/pkg'" for an undeclared/unstaged import). Surface it
            // instead of a bare "compile failed"; `fail` JSON-escapes.
            if (err == error.CompileFailed) {
                if (jctx.takeExceptionMessage(a)) |m| {
                    defer a.free(m);
                    if (m.len != 0) {
                        const detail = std.fmt.allocPrint(a, "compile failed: {s}", .{m}) catch
                            return fail(self, router, job, 400, "compile failed");
                        defer a.free(detail);
                        return fail(self, router, job, 400, detail);
                    }
                } else |_| {}
            }
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

        const ctx_json = buildResultsJson(a, compiled, job.app_ctx) catch
            return fail(self, router, job, 500, "out of memory");
        routeCompileEvent(router, a, job.fetch_id, job.chain_tenant, job.name, 200, true, ctx_json);
    }
};

/// Build the `ctx_json` payload (→ the resume export's `request.ctx`) for a
/// successful compile batch:
/// `{"ok":true,"results":[{"path","source_hex","bytecode_hex"},...],"app":<ctx>}`.
/// `app` echoes the issue-time on.fetch `ctx` (raw JSON) so the handler can
/// thread state across the compile re-entry (e.g. the deploy app's
/// `{target, statics}`). Paths are pre-validated (no JSON escaping needed);
/// hashes are hex. Caller owns the result.
fn buildResultsJson(allocator: std.mem.Allocator, compiled: []const files_mod.CompiledFile, app_ctx: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"ok\":true,\"results\":[");
    for (compiled, 0..) |cf, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"path\":\"{s}\",\"source_hex\":\"{s}\",\"bytecode_hex\":\"{s}\"}}", .{ cf.path, &cf.source_hex, &cf.bytecode_hex });
    }
    // Echo the threaded app ctx raw (it's already a JSON value; "null" when absent).
    try w.writeAll("],\"app\":");
    try w.writeAll(if (app_ctx.len == 0) "null" else app_ctx);
    try w.writeAll("}");
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

/// `{"ok":false,"status":N,"error":<msg>}` with `msg` JSON-escaped
/// (compile-failure detail carries quickjs exception text, which can
/// contain quotes/backslashes). Caller owns the result — in practice
/// `routeCompileEvent` takes ownership.
fn errorCtxJson(allocator: std.mem.Allocator, status: u16, msg: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    {
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = aw.toArrayList();
        try aw.writer.print("{{\"ok\":false,\"status\":{d},\"error\":", .{status});
        try std.json.Stringify.value(msg, .{}, &aw.writer);
        try aw.writer.writeByte('}');
    }
    return try buf.toOwnedSlice(allocator);
}

/// PM P2 static gate: does `src` name the privileged surface? Lexical,
/// identifier-boundary-aware, and deliberately blunt (matches inside
/// comments/strings too — best-effort hygiene, not the security
/// boundary; that's the natives' `is_system_module` self-gate).
/// Rules: `_system` as an exact identifier (both boundaries — so
/// `my_system` / `_systematic` pass); any identifier STARTING with
/// `__rove` (catches the `__rove.*` holder and every `__rove_*`
/// native).
pub fn referencesPrivilegedSurface(src: []const u8) bool {
    return findsIdent(src, "_system", true) or findsIdent(src, "__rove", false);
}

fn isIdentChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or ch == '_' or ch == '$';
}

fn findsIdent(src: []const u8, needle: []const u8, bound_after: bool) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, needle)) |at| {
        const pre_ok = at == 0 or !isIdentChar(src[at - 1]);
        const end = at + needle.len;
        const post_ok = !bound_after or end >= src.len or !isIdentChar(src[end]);
        if (pre_ok and post_ok) return true;
        i = at + 1;
    }
    return false;
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
    if (job.app_ctx.len != 0) allocator.free(job.app_ctx);
    // *_put-only payload (empty `&.{}` for other kinds).
    if (job.key.len != 0) allocator.free(job.key);
    if (job.payload.len != 0) allocator.free(job.payload);
    // compile_batch package context (PM P1).
    if (job.resolution_json.len != 0) allocator.free(job.resolution_json);
    if (job.pkg_hash.len != 0) allocator.free(job.pkg_hash);
}

// ── Tests ──────────────────────────────────────────────────────────
//
// These cover the queue + result-map plumbing in isolation (no network,
// no thread timing). The real compile+stage+S3 path is covered by
// rove-files' `compileAndStage` tests + the deploy smoke.

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
        .kind = .compile_batch,
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

test "referencesPrivilegedSurface: catches _system + __rove*, not lookalikes" {
    // hits
    try testing.expect(referencesPrivilegedSurface("const h = _system.http;"));
    try testing.expect(referencesPrivilegedSurface("globalThis.__rove.fetch(u)"));
    try testing.expect(referencesPrivilegedSurface("__rove_check_email_rate()"));
    try testing.expect(referencesPrivilegedSurface("x=_system"));
    try testing.expect(referencesPrivilegedSurface("// mentions _system in a comment"));
    // misses (identifier boundaries)
    try testing.expect(!referencesPrivilegedSurface("const my_system = 1;"));
    try testing.expect(!referencesPrivilegedSurface("let _systematic = 2;"));
    try testing.expect(!referencesPrivilegedSurface("import {v} from '@rewind/jwt';"));
    try testing.expect(!referencesPrivilegedSurface("const x__rove = 3;"));
    try testing.expect(!referencesPrivilegedSurface("rove and system, separately"));
    try testing.expect(!referencesPrivilegedSurface(""));
}

test "errorCtxJson escapes quotes in the message" {
    const a = testing.allocator;
    const cj = try errorCtxJson(a, 400, "compile failed: could not load module '@x/y' \"quoted\"");
    defer a.free(cj);
    try testing.expectEqualStrings(
        "{\"ok\":false,\"status\":400,\"error\":\"compile failed: could not load module '@x/y' \\\"quoted\\\"\"}",
        cj,
    );
    // Parses back as JSON.
    var parsed = try std.json.parseFromSlice(std.json.Value, a, cj, .{});
    defer parsed.deinit();
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
