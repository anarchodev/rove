//! Background snapshot catch-up driver — the worker-thread half of the
//! raft-native alignment arc's Phase 1 (native trigger + out-of-band data,
//! `docs/architecture/raft-native-alignment.md`).
//!
//! The pump's `snapshotTriggerTick` detects a peer raft holds in
//! `ProgressState::Snapshot` (it fell below the leader's compacted first_index
//! under mechanism-A compaction) and enqueues a `(gid, peer, baseline)` job on
//! the bridge. The poll loop drains that queue (`drainSnapshotCatchupJobs`) and
//! hands each job to THIS thread, so the heavy work — a held-snapshot store dump
//! streamed over one blocking HTTP upload — runs off BOTH the pump (shared
//! multi-raft) and the customer poll loop. Per job it:
//!   1. opens a held-snapshot `StreamDumper` over the leader's tenant manifest
//!      (consistent MVCC view via overlay capture — no `durabilize` fsync);
//!   2. `POST /_system/v2-snapshot-stream` — a chunked upload whose body IS the
//!      pair stream (libcurl pulls from the dumper at the wire's drain rate, so
//!      a multi-GB store is never buffered whole), with the data-free baseline
//!      `{tenant, index, term}` carried in headers. The dest applies in bounded
//!      txns and, on clean END_STREAM, installs the raft baseline — ONE call vs
//!      the retired v2-load-replace + v2-apply-snapshot pair (raft Phase 2.5).
//! The peer's `match` then advances past the leader's first_index, raft clears
//! `StateSnapshot`, and the tail replicates normally — the `promote_back`
//! sequence, now streamed + auto-orchestrated by the native trigger.
//!
//! Leader-push first (the leader dumps + pushes); a follower-sourced offload is
//! a later optimization. On completion (success OR failure) the job clears its
//! `(gid, peer)` in-flight mark on the bridge, so a still-behind peer re-triggers
//! next tick (a failed push retries; a successful one no longer appears in
//! `snapshotPendingPeers`).

const std = @import("std");
const rove = @import("rove");
const kv_mod = @import("raft-kv");
const tenant_mod = @import("rove-tenant");
const blob_mod = @import("rove-blob");
const bridge_mod = @import("bridge");
const snapshot_sink_mod = @import("snapshot_sink.zig");
const curl = blob_mod.curl;

const SNAP_MODE_HEADER = "x-rewind-snapshot-mode";

const TENANT_HEADER = "X-Rewind-Tenant";
const MOVE_SECRET_HEADER = "X-Rewind-Move-Secret";
const SNAP_INDEX_HEADER = "x-rewind-snapshot-index";
const SNAP_TERM_HEADER = "x-rewind-snapshot-term";

/// Upload producer over a held-snapshot `StreamDumper` (raft Phase 2.5): libcurl
/// pulls the next wire slice via `fill` only as fast as the peer's receive
/// window drains, so the body is never materialized whole.
const DumpProducerCtx = struct {
    dumper: *kv_mod.StreamDumper,
    /// Absolute wall-clock deadline (ms). The held snapshot's read txn pins LMDB
    /// pages for the whole transfer, so the leader's DB grows by roughly
    /// write_rate × transfer_time. Past the deadline we ABORT (fail loud) rather
    /// than let a too-hot/too-large tenant balloon the leader unboundedly.
    deadline_ms: i64,
    failed: bool = false,
    timed_out: bool = false,

    fn fill(dst: []u8, ctx: *anyopaque) ?usize {
        const self: *DumpProducerCtx = @ptrCast(@alignCast(ctx));
        if (std.time.milliTimestamp() > self.deadline_ms) {
            self.timed_out = true;
            return null; // abort the upload — bounds the page-pinning window
        }
        return self.dumper.pull(dst) catch {
            self.failed = true;
            return null; // abort the upload (CURL_READFUNC_ABORT)
        };
    }
};

/// Max wall-clock per-transfer duration (`REWIND_SNAPSHOT_XFER_MAX_MS`, default
/// 10 min) — the page-pinning bound. A transfer that overruns is aborted +
/// logged loudly and retried next trigger tick from a fresh snapshot.
fn readXferMaxMs() i64 {
    const default_ms: i64 = 10 * 60 * 1000;
    const s = std.posix.getenv("REWIND_SNAPSHOT_XFER_MAX_MS") orelse return default_ms;
    return std.fmt.parseInt(i64, s, 10) catch default_ms;
}

pub const SnapshotCatchupThread = struct {
    allocator: std.mem.Allocator,
    /// Resolves the tenant instance whose store the leader dumps. Internally
    /// locked, so `getInstance` is safe alongside the poll loop.
    tenant: *tenant_mod.Tenant,
    /// For `clearSnapshotCatchup` when a job finishes (re-arms the trigger).
    bridge: *bridge_mod.Bridge,
    /// Shared move secret (`REWIND_MOVE_SECRET`) presented to the peer's
    /// move-secret-gated `v2-load-replace` / `v2-apply-snapshot`. Null → the
    /// peer rejects the push; treat as a misconfiguration (logged per job).
    move_secret: ?[]const u8,
    /// Peer HTTP base URLs indexed by raft id − 1 (`REWIND_PEER_URLS`), the
    /// worker analog of CP's `REWIND_CP_PEER_URLS`. Empty / a missing index →
    /// catch-up disabled for that peer (logged loudly — a stranded peer is an
    /// operator-visible problem, not a silent strand).
    peer_urls: []const []const u8,
    /// Page-pinning bound: max wall-clock per-transfer duration
    /// (`REWIND_SNAPSHOT_XFER_MAX_MS`). Read once at init.
    xfer_max_ms: i64 = 10 * 60 * 1000,

    queue: std.ArrayListUnmanaged(Job) = .empty,
    queue_mutex: std.Thread.Mutex = .{},
    wake: std.Thread.ResetEvent = .{},
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    /// Completed move-push jobs, drained by the worker tick
    /// (`drainSnapshotPushes`) to respond to the parked CP-trigger entity.
    /// Cross-thread (mutex): the driver thread pushes here, the worker drains —
    /// the established `proxy_engine` `ProxyResultInbox` seam (a transient
    /// message queue carrying an Entity handle, NOT per-entity side storage).
    completions: std.ArrayListUnmanaged(PushCompletion) = .empty,
    completions_mutex: std.Thread.Mutex = .{},

    /// Two job flavors share this one off-loop streaming driver:
    ///   - `catchup`: internally triggered (matched+1<first_index), pushes to an
    ///     in-cluster peer (`REWIND_PEER_URLS`), clears the bridge in-flight mark,
    ///     retries forever.
    ///   - `push`: CP-triggered (a tenant move), pushes to an arbitrary dest URL
    ///     in `merge` mode, responds once to the parked `entity` via `completions`.
    pub const Kind = enum { catchup, push };

    /// Thread → worker handoff for a finished move-push.
    pub const PushCompletion = struct {
        entity: rove.Entity,
        /// HTTP status from the dest (0 = transport failure → caller maps 502).
        status: u16,
    };

    pub const Job = struct {
        kind: Kind = .catchup,
        gid: u64 = 0,
        peer: u64 = 0,
        index: u64 = 0,
        term: u64 = 0,
        /// Owned dup of the tenant id (catchup: copied from the bridge's borrowed
        /// `GroupSig.id_str`; push: from the request header). Freed after run.
        id_str: []u8,
        // ── push-only ──
        /// The parked CP-trigger entity to respond to on completion.
        entity: rove.Entity = rove.Entity.nil,
        /// Owned dest base URL (push only); freed after run.
        dest_url: ?[]u8 = null,
        mode: snapshot_sink_mod.Mode = .replace,
    };

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        tenant: *tenant_mod.Tenant,
        bridge: *bridge_mod.Bridge,
        move_secret: ?[]const u8,
        peer_urls: []const []const u8,
    ) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .tenant = tenant,
            .bridge = bridge,
            .move_secret = move_secret,
            .peer_urls = peer_urls,
            .xfer_max_ms = readXferMaxMs(),
        };
        return self;
    }

    pub fn start(self: *Self) !void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    pub fn shutdown(self: *Self) void {
        self.stop.store(true, .release);
        self.wake.set();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *Self) void {
        // Caller must have shut down by here. Free any jobs the thread never
        // reached + (catchup) clear their in-flight marks so a restart re-triggers.
        // Undrained push jobs strand their parked entity — it's reaped on worker
        // teardown (the move's CP call times out), so no completion is posted.
        for (self.queue.items) |*job| {
            switch (job.kind) {
                .catchup => self.bridge.clearSnapshotCatchup(job.gid, job.peer),
                .push => if (job.dest_url) |u| self.allocator.free(u),
            }
            self.allocator.free(job.id_str);
        }
        self.queue.deinit(self.allocator);
        self.completions.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Poll loop → thread: enqueue a job. Takes ownership of `job.id_str`.
    pub fn enqueue(self: *Self, job: Job) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        try self.queue.append(self.allocator, job);
        self.wake.set();
    }

    /// Worker handler → thread: enqueue a CP-triggered move-push. Dups `tenant`
    /// + `dest_url` into owned job storage (freed after the job runs). The reply
    /// to `entity` is posted to `completions` on completion.
    pub fn enqueuePush(
        self: *Self,
        entity: rove.Entity,
        tenant: []const u8,
        dest_url: []const u8,
        mode: snapshot_sink_mod.Mode,
    ) !void {
        const id = try self.allocator.dupe(u8, tenant);
        errdefer self.allocator.free(id);
        const url = try self.allocator.dupe(u8, dest_url);
        errdefer self.allocator.free(url);
        try self.enqueue(.{
            .kind = .push,
            .id_str = id,
            .entity = entity,
            .dest_url = url,
            .mode = mode,
        });
    }

    /// Thread → worker: take all finished move-push completions. The worker tick
    /// (`drainSnapshotPushes`) matches each `entity` to its parked request.
    pub fn drainPushCompletions(self: *Self, out: *std.ArrayListUnmanaged(PushCompletion)) !void {
        self.completions_mutex.lock();
        defer self.completions_mutex.unlock();
        try out.appendSlice(self.allocator, self.completions.items);
        self.completions.clearRetainingCapacity();
    }

    pub fn postCompletion(self: *Self, entity: rove.Entity, status: u16) void {
        self.completions_mutex.lock();
        defer self.completions_mutex.unlock();
        // Best-effort: an OOM here drops the completion → the parked entity's
        // CP call times out (operator-visible) rather than corrupting state.
        self.completions.append(self.allocator, .{ .entity = entity, .status = status }) catch
            std.log.warn("v2 snapshot-push: completion inbox OOM; parked move request will time out", .{});
    }

    fn popOne(self: *Self) ?Job {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    fn threadMain(self: *Self) void {
        while (!self.stop.load(.acquire)) {
            self.wake.wait();
            self.wake.reset();
            if (self.stop.load(.acquire)) break;
            while (self.popOne()) |job_val| {
                var job = job_val;
                self.runJob(&job);
                switch (job.kind) {
                    // Re-arm the trigger: a still-behind peer re-enqueues next tick.
                    .catchup => self.bridge.clearSnapshotCatchup(job.gid, job.peer),
                    // The completion was posted inside runPush; just free its URL.
                    .push => if (job.dest_url) |u| self.allocator.free(u),
                }
                self.allocator.free(job.id_str);
            }
        }
    }

    /// Resolve the peer's HTTP base URL (`REWIND_PEER_URLS[peer − 1]`), or null
    /// (logged loudly — a stranded peer with no reachable URL is misconfig).
    fn peerUrl(self: *Self, gid: u64, peer: u64) ?[]const u8 {
        if (peer == 0 or peer - 1 >= self.peer_urls.len) {
            std.log.warn(
                "v2 snapshot-catchup gid={d}: no REWIND_PEER_URLS entry for peer {d} " ++
                    "({d} configured) — cannot push catch-up; peer stays in StateSnapshot",
                .{ gid, peer, self.peer_urls.len },
            );
            return null;
        }
        return self.peer_urls[peer - 1];
    }

    fn runJob(self: *Self, job: *Job) void {
        switch (job.kind) {
            .catchup => self.runCatchup(job),
            .push => self.runPush(job),
        }
    }

    /// Open a held-snapshot dumper over a tenant's live manifest. `openSnapshot`
    /// captures a consistent MVCC view (read txn + a copy of the committed
    /// overlay) WITHOUT forcing a `durabilize` — no leader-poll-loop fsync
    /// contention, unlike the retired single-shot `dumpTenantBundle`. The read
    /// txn pins LMDB pages for the transfer (the deadline bounds the pinning).
    fn openDumper(self: *Self, tenant: []const u8) ?kv_mod.StreamDumper {
        const inst = (self.tenant.getInstance(tenant) catch null) orelse {
            std.log.warn("v2 snapshot-stream: no instance for {s}", .{tenant});
            return null;
        };
        return kv_mod.StreamDumper.init(self.allocator, inst.kv.manifest, inst.kv.store_id) catch |e| {
            std.log.warn("v2 snapshot-stream {s}: snapshot open failed: {s}", .{ tenant, @errorName(e) });
            return null;
        };
    }

    fn runCatchup(self: *Self, job: *Job) void {
        const a = self.allocator;
        const base = self.peerUrl(job.gid, job.peer) orelse return;
        const secret = self.move_secret orelse {
            std.log.warn("v2 snapshot-catchup gid={d} peer={d}: REWIND_MOVE_SECRET unset; cannot push", .{ job.gid, job.peer });
            return;
        };
        var dumper = self.openDumper(job.id_str) orelse return;
        defer dumper.deinit();

        const url = std.fmt.allocPrint(a, "{s}/_system/v2-snapshot-stream", .{base}) catch return;
        defer a.free(url);
        const status = self.streamUpload(url, secret, job.id_str, .replace, job.index, job.term, &dumper) catch |e| {
            switch (e) {
                // Fail loud: the page-pinning bound tripped — the tenant is too
                // large/hot for REWIND_SNAPSHOT_XFER_MAX_MS; aborting keeps the
                // leader's DB from ballooning. Retries next trigger tick.
                error.SnapshotTransferDeadline => std.log.warn(
                    "v2 snapshot-catchup gid={d} peer={d}: transfer exceeded REWIND_SNAPSHOT_XFER_MAX_MS " ++
                        "({d}ms), aborted to bound leader page-pinning; will retry", .{ job.gid, job.peer, self.xfer_max_ms }),
                else => std.log.warn("v2 snapshot-catchup gid={d} peer={d}: v2-snapshot-stream transport: {s}", .{ job.gid, job.peer, @errorName(e) }),
            }
            return;
        };
        switch (status) {
            204 => std.log.info("v2 snapshot-catchup gid={d} peer={d}: streamed catch-up to baseline {d}/{d}", .{ job.gid, job.peer, job.index, job.term }),
            // 409 = already advanced past `index` (SnapshotStale) / now leader — benign.
            409 => std.log.info("v2 snapshot-catchup gid={d} peer={d}: v2-snapshot-stream 409 (already ahead / now leader) — benign", .{ job.gid, job.peer }),
            else => std.log.warn("v2 snapshot-catchup gid={d} peer={d}: v2-snapshot-stream → {d}", .{ job.gid, job.peer, status }),
        }
    }

    /// CP-triggered move push: stream the held snapshot to `dest_url` in the
    /// job's mode (`merge` for zero-downtime), then post the dest's status to the
    /// completion inbox for the parked CP-trigger entity. Status 0 = a local /
    /// transport failure → the worker maps it to 502.
    fn runPush(self: *Self, job: *Job) void {
        const a = self.allocator;
        const dest = job.dest_url orelse {
            self.postCompletion(job.entity, 0);
            return;
        };
        const secret = self.move_secret orelse {
            std.log.warn("v2 snapshot-push tenant={s}: REWIND_MOVE_SECRET unset; cannot push", .{job.id_str});
            self.postCompletion(job.entity, 0);
            return;
        };
        var dumper = self.openDumper(job.id_str) orelse {
            self.postCompletion(job.entity, 0);
            return;
        };
        defer dumper.deinit();

        const url = std.fmt.allocPrint(a, "{s}/_system/v2-snapshot-stream", .{dest}) catch {
            self.postCompletion(job.entity, 0);
            return;
        };
        defer a.free(url);
        const status = self.streamUpload(url, secret, job.id_str, job.mode, job.index, job.term, &dumper) catch |e| {
            std.log.warn("v2 snapshot-push tenant={s} dest={s}: {s}", .{ job.id_str, dest, @errorName(e) });
            self.postCompletion(job.entity, 0);
            return;
        };
        std.log.info("v2 snapshot-push tenant={s} dest={s} → {d}", .{ job.id_str, dest, status });
        self.postCompletion(job.entity, status);
    }

    /// Stream the held snapshot to `url` (a peer/dest `/_system/v2-snapshot-stream`)
    /// as a chunked upload — the body IS the pair stream; the baseline / mode ride
    /// in headers (`.replace` carries `{index,term}`; `.merge` carries the mode and
    /// no baseline). One blocking call on this off-loop thread; libcurl pulls from
    /// the dumper at the wire's drain rate. Returns the HTTP status; errors on
    /// transport or a tripped page-pinning deadline.
    fn streamUpload(
        self: *Self,
        url: []const u8,
        secret: []const u8,
        tenant: []const u8,
        mode: snapshot_sink_mod.Mode,
        index: u64,
        term: u64,
        dumper: *kv_mod.StreamDumper,
    ) !u16 {
        const a = self.allocator;
        const idx_str = try std.fmt.allocPrint(a, "{d}", .{index});
        defer a.free(idx_str);
        const term_str = try std.fmt.allocPrint(a, "{d}", .{term});
        defer a.free(term_str);

        var headers: std.ArrayListUnmanaged(curl.Header) = .empty;
        defer headers.deinit(a);
        try headers.append(a, .{ .name = MOVE_SECRET_HEADER, .value = secret });
        try headers.append(a, .{ .name = TENANT_HEADER, .value = tenant });
        switch (mode) {
            .replace => {
                // Default mode on the dest — carries the data-free baseline.
                try headers.append(a, .{ .name = SNAP_INDEX_HEADER, .value = idx_str });
                try headers.append(a, .{ .name = SNAP_TERM_HEADER, .value = term_str });
            },
            .merge => try headers.append(a, .{ .name = SNAP_MODE_HEADER, .value = "merge" }),
        }
        try headers.append(a, .{ .name = "Content-Type", .value = "application/octet-stream" });

        var pctx: DumpProducerCtx = .{
            .dumper = dumper,
            .deadline_ms = std.time.milliTimestamp() + self.xfer_max_ms,
        };
        // curl's TOTAL-transfer timeout sits just past our deadline so OUR
        // check fires first with the page-pinning-specific message (curl is the
        // backstop for a wedged connection).
        const curl_timeout_ms: u32 = @intCast(@min(self.xfer_max_ms + 60_000, @as(i64, std.math.maxInt(u32))));
        var easy = try curl.Easy.init(a);
        defer easy.deinit();
        var resp = try easy.requestUpload(a, .{
            .method = .POST,
            .url = url,
            .headers = headers.items,
            .http_version = .h2c_prior_knowledge,
            .verify_tls = false,
            .timeout_ms = curl_timeout_ms,
        }, .{ .ctx = &pctx, .fill = &DumpProducerCtx.fill });
        defer resp.deinit(a);
        // Producer-side aborts surface as a curl error above OR a short body;
        // distinguish them from a clean non-204 so the retry is attributed.
        if (pctx.timed_out) return error.SnapshotTransferDeadline;
        if (pctx.failed) return error.SnapshotDumpFailed;
        return resp.status;
    }
};
