//! Background snapshot catch-up driver — the worker-thread half of the
//! raft-native alignment arc's Phase 1 (native trigger + out-of-band data,
//! `docs/raft-native-alignment.md`).
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
const kv_mod = @import("raft-kv");
const tenant_mod = @import("rove-tenant");
const blob_mod = @import("rove-blob");
const bridge_mod = @import("bridge");
const curl = blob_mod.curl;

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

    pub const Job = struct {
        gid: u64,
        peer: u64,
        index: u64,
        term: u64,
        /// Owned dup of the tenant id (the poll-loop drain copies the bridge's
        /// borrowed `GroupSig.id_str`). Freed after the job runs.
        id_str: []u8,
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
        // reached + clear their in-flight marks so a restart re-triggers.
        for (self.queue.items) |*job| {
            self.bridge.clearSnapshotCatchup(job.gid, job.peer);
            self.allocator.free(job.id_str);
        }
        self.queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Poll loop → thread: enqueue a job. Takes ownership of `job.id_str`.
    pub fn enqueue(self: *Self, job: Job) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        try self.queue.append(self.allocator, job);
        self.wake.set();
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
                // Re-arm the trigger: a still-behind peer re-enqueues next tick.
                self.bridge.clearSnapshotCatchup(job.gid, job.peer);
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
        const a = self.allocator;
        const base = self.peerUrl(job.gid, job.peer) orelse return;
        const secret = self.move_secret orelse {
            std.log.warn(
                "v2 snapshot-catchup gid={d} peer={d}: REWIND_MOVE_SECRET unset — the peer's " ++
                    "v2-snapshot-stream is gated; cannot push",
                .{ job.gid, job.peer },
            );
            return;
        };
        const inst = (self.tenant.getInstance(job.id_str) catch null) orelse {
            std.log.warn("v2 snapshot-catchup gid={d} peer={d}: no instance for {s}", .{ job.gid, job.peer, job.id_str });
            return;
        };

        // Open a held-snapshot dumper over the leader's live tenant manifest.
        // `openSnapshot` captures a consistent MVCC view (read txn + a copy of
        // the committed overlay) WITHOUT forcing a `durabilize` — no
        // leader-poll-loop fsync contention, unlike the retired single-shot
        // `dumpTenantBundle`. The read txn pins LMDB pages for the transfer's
        // lifetime (the page-pinning cost the transfer deadline bounds).
        var dumper = kv_mod.StreamDumper.init(a, inst.kv.manifest, inst.kv.store_id) catch |e| {
            std.log.warn("v2 snapshot-catchup gid={d} peer={d}: snapshot open failed: {s}", .{ job.gid, job.peer, @errorName(e) });
            return;
        };
        defer dumper.deinit();

        const status = self.streamUpload(base, secret, job, &dumper) catch |e| {
            switch (e) {
                // Fail loud: the page-pinning bound tripped. The tenant is too
                // large/hot to transfer within REWIND_SNAPSHOT_XFER_MAX_MS;
                // aborting keeps the leader's DB from ballooning. Retries next
                // trigger tick — raise the knob (or investigate) if it recurs.
                error.SnapshotTransferDeadline => std.log.warn(
                    "v2 snapshot-catchup gid={d} peer={d}: transfer exceeded REWIND_SNAPSHOT_XFER_MAX_MS " ++
                        "({d}ms) and was aborted to bound leader page-pinning; will retry next tick",
                    .{ job.gid, job.peer, self.xfer_max_ms },
                ),
                else => std.log.warn(
                    "v2 snapshot-catchup gid={d} peer={d}: v2-snapshot-stream transport: {s}",
                    .{ job.gid, job.peer, @errorName(e) },
                ),
            }
            return;
        };
        switch (status) {
            204 => std.log.info(
                "v2 snapshot-catchup gid={d} peer={d}: streamed catch-up to baseline {d}/{d}",
                .{ job.gid, job.peer, job.index, job.term },
            ),
            // 409 = the peer already advanced past `index` via replication in the
            // window (SnapshotStale) or became the leader — benign, no longer
            // behind. Anything else is a real failure (retried next trigger tick).
            409 => std.log.info("v2 snapshot-catchup gid={d} peer={d}: v2-snapshot-stream 409 (already ahead / now leader) — benign", .{ job.gid, job.peer }),
            else => std.log.warn("v2 snapshot-catchup gid={d} peer={d}: v2-snapshot-stream → {d}", .{ job.gid, job.peer, status }),
        }
    }

    /// Stream the held snapshot to the peer's `/_system/v2-snapshot-stream` as a
    /// chunked upload — the body is the pure pair stream, the data-free baseline
    /// `{tenant, index, term}` rides in headers (one call, vs the retired
    /// v2-load-replace + v2-apply-snapshot pair). One blocking call on this
    /// off-loop thread; libcurl pulls from the dumper at the wire's drain rate.
    /// Returns the HTTP status; errors on transport or mid-stream dump failure.
    fn streamUpload(self: *Self, base: []const u8, secret: []const u8, job: *Job, dumper: *kv_mod.StreamDumper) !u16 {
        const a = self.allocator;
        const url = try std.fmt.allocPrint(a, "{s}/_system/v2-snapshot-stream", .{base});
        defer a.free(url);
        const idx_str = try std.fmt.allocPrint(a, "{d}", .{job.index});
        defer a.free(idx_str);
        const term_str = try std.fmt.allocPrint(a, "{d}", .{job.term});
        defer a.free(term_str);

        var headers: std.ArrayListUnmanaged(curl.Header) = .empty;
        defer headers.deinit(a);
        try headers.append(a, .{ .name = MOVE_SECRET_HEADER, .value = secret });
        try headers.append(a, .{ .name = TENANT_HEADER, .value = job.id_str });
        try headers.append(a, .{ .name = SNAP_INDEX_HEADER, .value = idx_str });
        try headers.append(a, .{ .name = SNAP_TERM_HEADER, .value = term_str });
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
