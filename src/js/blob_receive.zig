//! `blob.receive` upload driver — the transport half of
//! blob-storage-plan §3.5 (P3 slice B; `docs/architecture/routing-and-ingress.md`).
//!
//! One `Job` per accepted inbound upload. The h2 layer routes body
//! DATA into the job's queue via the `BodySink` interface (worker
//! thread); the job's own thread drains it into S3 multipart parts
//! (slice A's `createMultipartUpload` / `uploadPart` /
//! `completeMultipartUpload` substrate, synchronous EasyPool calls
//! that must never run on the worker thread), hashing incrementally.
//! On END_STREAM it completes the upload at the temp key, server-side
//! copies to the content-addressed `app-blobs/{sha256}` home, deletes
//! the temp, and emits ONE terminal `UpstreamFetchEvent` — `{hash,
//! len}` in `ctx_json` — through the same router the FetchEngine
//! uses, so the held chain resumes at the customer's `{to}` export
//! with zero receive-specific resume machinery.
//!
//! Flow control is end-to-end: h2 only repays the client's
//! flow-control window as `drained()` reports bytes moved out of the
//! queue, so the client's send rate follows the S3 upload rate with
//! at most one window + one part buffer of RAM per job.
//!
//! Failure posture (§3.5): S3 multipart natively has commit-gate
//! semantics — nothing is externally observable until Complete, so a
//! dropped connection or any S3 error maps to AbortMultipartUpload +
//! one `ok: false` terminal event. Nothing is promised pre-complete.
//!
//! Lifetime: refcounted, exactly two owners — h2's sink reference
//! (released by `sweepBodySinks` when the stream dies) and the job
//! thread (released at thread exit). `abort` is idempotent and safe
//! after `finish` (a finished upload completes; the abort flag is
//! only honored before completion).

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const blob_mod = @import("rove-blob");
const components_mod = @import("components.zig");
const msg_router_mod = @import("msg_router.zig");

/// The trusted-door URL prefix the `_system.blob.receive` binding
/// stamps on its PendingFetch. Never reaches libcurl — the worker's
/// staging paths intercept it before the FetchEngine.
pub const RECEIVE_ORIGIN_PREFIX = "http://rove-receive.internal/";

pub fn isReceiveUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, RECEIVE_ORIGIN_PREFIX);
}

/// The binding encodes the activation entity in the URL tail as
/// `{index}.{generation}` — the arm site resolves the request's
/// stream identity (Session + StreamId) from it, wherever the entity
/// is parked by commit time.
pub fn entityFromReceiveUrl(url: []const u8) ?rove.Entity {
    if (!isReceiveUrl(url)) return null;
    var tail = url[RECEIVE_ORIGIN_PREFIX.len..];
    // Cross-tenant receives carry a `?scope={target}` query — the entity is the
    // `{index}.{generation}` before it.
    if (std.mem.indexOfScalar(u8, tail, '?')) |q| tail = tail[0..q];
    const dot = std.mem.indexOfScalar(u8, tail, '.') orelse return null;
    const index = std.fmt.parseInt(u32, tail[0..dot], 10) catch return null;
    const generation = std.fmt.parseInt(u32, tail[dot + 1 ..], 10) catch return null;
    return .{ .index = index, .generation = generation };
}

/// Cross-tenant receive target tenant, from the `?scope={target}` query — the
/// blob streams into THAT tenant's `file-blobs/` prefix instead of the issuing
/// tenant's `app-blobs/`. `null` for an own-tenant receive (no query). Only the
/// admin handler forms a scoped URL (`platform.scope(t).blob.receive`); the
/// staging-tenant gate is the platform-only binding.
pub fn targetFromReceiveUrl(url: []const u8) ?[]const u8 {
    if (!isReceiveUrl(url)) return null;
    const tail = url[RECEIVE_ORIGIN_PREFIX.len..];
    const marker = "?scope=";
    const i = std.mem.indexOf(u8, tail, marker) orelse return null;
    const v = tail[i + marker.len ..];
    return if (v.len == 0) null else v;
}

pub fn formatReceiveUrl(allocator: std.mem.Allocator, ent: rove.Entity) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{d}.{d}", .{ RECEIVE_ORIGIN_PREFIX, ent.index, ent.generation });
}

/// Node-wide active-job cap. A job costs one thread + one part
/// buffer (≤ 5 MiB + one window); 64 concurrent streaming uploads
/// per node is far past the launch envelope. Over-cap arms fail
/// loud with an `ok:false` terminal event.
pub const MAX_ACTIVE_JOBS: u32 = 64;
pub var active_jobs: std.atomic.Value(u32) = .init(0);

/// S3 multipart minimum for every part except the last.
const PART_BYTES: usize = blob_mod.s3.S3BlobStore.MULTIPART_MIN_PART_BYTES;

pub const Job = struct {
    allocator: std.mem.Allocator,
    /// Two owners: h2 sink ref + the job thread.
    refs: std.atomic.Value(u8) = .init(2),

    // Immutable after create():
    /// The tenant holding the chain (where the terminal event routes + the
    /// `{to}` export resumes). For own-tenant receives this is also the S3
    /// staging tenant; for cross-tenant (admin) receives the staging tenant is
    /// `target_id`.
    tenant_id: []u8,
    /// Cross-tenant staging tenant (`null` → stage into `tenant_id`). When set,
    /// bytes stream into `{target_id}/file-blobs/`; else `{tenant_id}/app-blobs/`.
    target_id: ?[]u8,
    /// Issue-time `ctx` (JSON) echoed back in the completion under `app` so the
    /// admin deploy app can thread {tenant, path, content_type} across the
    /// receive re-entry. Empty when absent.
    app_ctx: []u8,
    fetch_id: []u8,
    /// Customer `{to}` export the terminal event resumes.
    name: []u8,
    content_type: ?[]u8,
    router: *msg_router_mod.MsgRouter,
    /// Borrowed from NodeState — outlives every job.
    cfg: *const blob_mod.backend.BackendConfig,

    // Queue (worker thread pushes, job thread drains):
    mu: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    chunks: std.ArrayListUnmanaged([]u8) = .empty,
    eof: bool = false,
    aborted: bool = false,

    /// Bytes the job thread moved out of the queue since h2's last
    /// `drained()` sweep — the flow-control repayment counter.
    drained_bytes: std.atomic.Value(u32) = .init(0),

    pub fn create(
        allocator: std.mem.Allocator,
        router: *msg_router_mod.MsgRouter,
        cfg: *const blob_mod.backend.BackendConfig,
        tenant_id: []const u8,
        target_id: ?[]const u8,
        app_ctx: []const u8,
        fetch_id: []const u8,
        name: []const u8,
        content_type: ?[]const u8,
    ) !*Job {
        const self = try allocator.create(Job);
        errdefer allocator.destroy(self);
        const tenant_owned = try allocator.dupe(u8, tenant_id);
        errdefer allocator.free(tenant_owned);
        const target_owned: ?[]u8 = if (target_id) |t| try allocator.dupe(u8, t) else null;
        errdefer if (target_owned) |t| allocator.free(t);
        const ctx_owned = try allocator.dupe(u8, app_ctx);
        errdefer allocator.free(ctx_owned);
        const id_owned = try allocator.dupe(u8, fetch_id);
        errdefer allocator.free(id_owned);
        const name_owned = try allocator.dupe(u8, name);
        errdefer allocator.free(name_owned);
        const ct_owned: ?[]u8 = if (content_type) |ct| try allocator.dupe(u8, ct) else null;
        self.* = .{
            .allocator = allocator,
            .tenant_id = tenant_owned,
            .target_id = target_owned,
            .app_ctx = ctx_owned,
            .fetch_id = id_owned,
            .name = name_owned,
            .content_type = ct_owned,
            .router = router,
            .cfg = cfg,
        };
        _ = active_jobs.fetchAdd(1, .acq_rel);
        return self;
    }

    fn release(self: *Job) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        for (self.chunks.items) |ch| self.allocator.free(ch);
        self.chunks.deinit(self.allocator);
        self.allocator.free(self.tenant_id);
        if (self.target_id) |t| self.allocator.free(t);
        self.allocator.free(self.app_ctx);
        self.allocator.free(self.fetch_id);
        self.allocator.free(self.name);
        if (self.content_type) |ct| self.allocator.free(ct);
        self.allocator.destroy(self);
        _ = active_jobs.fetchSub(1, .acq_rel);
    }

    /// Spawn the upload thread (detached — the job outlives via
    /// refcount; process teardown is the only join point and smokes
    /// kill the process).
    pub fn start(self: *Job) !void {
        const t = try std.Thread.spawn(.{}, threadMain, .{self});
        t.detach();
    }

    // ── BodySink interface (h2 / worker thread) ─────────────────────

    pub fn sink(self: *Job) h2.BodySink {
        return .{
            .ctx = @ptrCast(self),
            .push = &sinkPush,
            .finish = &sinkFinish,
            .abort = &sinkAbort,
            .drained = &sinkDrained,
            .release = &sinkRelease,
        };
    }

    fn sinkPush(ctx: *anyopaque, bytes: []const u8) bool {
        const self: *Job = @ptrCast(@alignCast(ctx));
        const copy = self.allocator.dupe(u8, bytes) catch return false;
        self.mu.lock();
        defer self.mu.unlock();
        if (self.aborted) {
            self.allocator.free(copy);
            return false;
        }
        self.chunks.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            return false;
        };
        self.cond.signal();
        return true;
    }

    fn sinkFinish(ctx: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        self.eof = true;
        self.cond.signal();
    }

    fn sinkAbort(ctx: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        // Idempotent, and a no-op after a clean finish — the upload
        // is completing (or already completed); aborting it now
        // would race the Complete call for no benefit.
        if (self.eof) return;
        self.aborted = true;
        self.cond.signal();
    }

    fn sinkDrained(ctx: *anyopaque) u32 {
        const self: *Job = @ptrCast(@alignCast(ctx));
        return self.drained_bytes.swap(0, .acq_rel);
    }

    fn sinkRelease(ctx: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(ctx));
        self.release();
    }

    /// Mark aborted before the thread starts (sink attach found the
    /// stream gone). The thread then emits the failure event.
    pub fn markGone(self: *Job) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.aborted = true;
    }

    /// Drop the h2-side reference without a sweep (attach never
    /// registered — `.gone`).
    pub fn releaseSinkRef(self: *Job) void {
        self.release();
    }

    /// Thread spawn failed: emit the failure terminal inline and drop
    /// the thread's reference.
    pub fn failNow(self: *Job) void {
        self.emitTerminal(false, 0, 0, null);
        self.release();
    }

    // ── Upload thread ───────────────────────────────────────────────

    fn threadMain(self: *Job) void {
        defer self.release();
        self.run() catch |err| {
            std.log.warn(
                "rove-js blob.receive: upload failed tenant={s} id={s}: {s}",
                .{ self.tenant_id, self.fetch_id, @errorName(err) },
            );
            self.emitTerminal(false, 0, 0, null);
        };
    }

    fn run(self: *Job) !void {
        const a = self.allocator;

        // Cross-tenant (admin) receive stages into the TARGET tenant's deploy
        // namespace (`file-blobs`); an own-tenant receive uses `app-blobs`.
        const stage_tenant = self.target_id orelse self.tenant_id;
        const subdir: []const u8 = if (self.target_id != null) "file-blobs" else "app-blobs";
        var backend = try blob_mod.backend.BlobBackend.openPerTenant(
            a,
            self.cfg.*,
            stage_tenant,
            subdir,
        );
        defer backend.deinit();
        const s3 = &backend.inner.s3;

        const temp_key = try std.fmt.allocPrint(a, ".uploads/{s}", .{self.fetch_id});
        defer a.free(temp_key);

        const upload_id = try s3.createMultipartUpload(temp_key, if (self.content_type) |ct| ct else null, a);
        defer a.free(upload_id);
        // Until Complete succeeds, every exit aborts the upload so S3
        // doesn't accrue orphaned parts. (Abort-after-Complete is a
        // 404 no-op per slice A.)
        var completed = false;
        defer if (!completed) s3.abortMultipartUpload(temp_key, upload_id) catch {};

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var total: u64 = 0;
        var part_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer part_buf.deinit(a);
        var etags: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (etags.items) |e| a.free(e);
            etags.deinit(a);
        }
        var part_number: u32 = 1;

        var batch: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (batch.items) |ch| a.free(ch);
            batch.deinit(a);
        }

        while (true) {
            // Take everything queued (or wait for more / eof / abort).
            {
                self.mu.lock();
                defer self.mu.unlock();
                while (self.chunks.items.len == 0 and !self.eof and !self.aborted)
                    self.cond.wait(&self.mu);
                if (self.aborted) return error.ReceiveAborted;
                std.mem.swap(std.ArrayListUnmanaged([]u8), &batch, &self.chunks);
            }
            const drained_now = self.eofSafeDrain(&batch, &hasher, &part_buf, &total);
            if (drained_now > 0) _ = self.drained_bytes.fetchAdd(drained_now, .acq_rel);

            // Ship full parts. Every part except the last must be
            // ≥ 5 MiB; the loop leaves a sub-part tail in part_buf.
            while (part_buf.items.len >= PART_BYTES) {
                const etag = try s3.uploadPart(temp_key, upload_id, part_number, part_buf.items[0..PART_BYTES], a);
                errdefer a.free(etag);
                try etags.append(a, etag);
                part_number += 1;
                std.mem.copyForwards(u8, part_buf.items, part_buf.items[PART_BYTES..]);
                part_buf.items.len -= PART_BYTES;
            }

            const at_eof = blk: {
                self.mu.lock();
                defer self.mu.unlock();
                break :blk self.eof and self.chunks.items.len == 0;
            };
            if (at_eof) break;
        }

        // Tail part — any size (including a zero-byte only part for
        // an empty body; S3 requires at least one part).
        if (part_buf.items.len > 0 or etags.items.len == 0) {
            const etag = try s3.uploadPart(temp_key, upload_id, part_number, part_buf.items, a);
            errdefer a.free(etag);
            try etags.append(a, etag);
        }

        try s3.completeMultipartUpload(temp_key, upload_id, etags.items);
        completed = true;

        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        const hash_hex: [64]u8 = std.fmt.bytesToHex(hash, .lower);

        // Server-side move to the content-addressed home; zero bytes
        // transit the worker. Temp delete is best-effort (an orphan
        // temp object is a cost, not a correctness issue).
        try s3.copyObject(temp_key, &hash_hex);
        backend.blobStore().delete(temp_key) catch {};

        self.emitTerminal(true, 200, total, &hash_hex);
    }

    /// Move a drained batch into the hasher + part buffer. Returns
    /// the byte count for the flow-control repayment counter.
    fn eofSafeDrain(
        self: *Job,
        batch: *std.ArrayListUnmanaged([]u8),
        hasher: *std.crypto.hash.sha2.Sha256,
        part_buf: *std.ArrayListUnmanaged(u8),
        total: *u64,
    ) u32 {
        var moved: u32 = 0;
        for (batch.items) |ch| {
            hasher.update(ch);
            part_buf.appendSlice(self.allocator, ch) catch {
                // OOM growing the part buffer — surface via the abort
                // path (the caller's next uploadPart try will fail on
                // short data... fail loud instead: flip aborted).
                self.mu.lock();
                self.aborted = true;
                self.mu.unlock();
            };
            total.* += ch.len;
            moved += @intCast(ch.len);
            self.allocator.free(ch);
        }
        batch.clearRetainingCapacity();
        return moved;
    }

    /// One terminal `UpstreamFetchEvent` through the FetchEngine's
    /// router path: `bind` routes it to the worker holding the
    /// chain; `name` resumes the customer's `{to}` export;
    /// `ctx_json` carries `{hash, len}` (the §3.5 completion Msg —
    /// all replay strictly needs).
    fn emitTerminal(self: *Job, ok: bool, status: u16, len: u64, hash_hex: ?*const [64]u8) void {
        const a = self.allocator;
        var ev: components_mod.UpstreamFetchEvent = .{
            .final = true,
            .terminal_ok = ok,
            .terminal_status = status,
            .stream = false,
            .bind = true,
        };
        ev.fetch_id = a.dupe(u8, self.fetch_id) catch return;
        ev.tenant_id = a.dupe(u8, self.tenant_id) catch {
            components_mod.UpstreamFetchEvent.deinitItem(&ev, a);
            return;
        };
        ev.name = a.dupe(u8, self.name) catch {
            components_mod.UpstreamFetchEvent.deinitItem(&ev, a);
            return;
        };
        // `app` echoes the issue-time ctx (raw JSON) so a cross-tenant deploy
        // receive can thread {tenant, path, content_type} to its `{to}` export.
        const app: []const u8 = if (self.app_ctx.len == 0) "null" else self.app_ctx;
        ev.ctx_json = blk: {
            if (hash_hex) |h| {
                break :blk std.fmt.allocPrint(a, "{{\"hash\":\"{s}\",\"len\":{d},\"app\":{s}}}", .{ h, len, app }) catch {
                    components_mod.UpstreamFetchEvent.deinitItem(&ev, a);
                    return;
                };
            }
            break :blk std.fmt.allocPrint(a, "{{\"error\":\"receive failed\",\"app\":{s}}}", .{app}) catch {
                components_mod.UpstreamFetchEvent.deinitItem(&ev, a);
                return;
            };
        };
        self.router.enqueueFetchEventForTenant(self.tenant_id, ev) catch |err| {
            std.log.warn(
                "rove-js blob.receive: terminal event route failed tenant={s} id={s}: {s}",
                .{ self.tenant_id, self.fetch_id, @errorName(err) },
            );
            var e = ev;
            components_mod.UpstreamFetchEvent.deinitItem(&e, a);
        };
    }
};
