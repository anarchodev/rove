//! Background snapshot catch-up driver — the worker-thread half of the
//! raft-native alignment arc's Phase 1 (native trigger + out-of-band data,
//! `docs/raft-native-alignment.md`).
//!
//! The pump's `snapshotTriggerTick` detects a peer raft holds in
//! `ProgressState::Snapshot` (it fell below the leader's compacted first_index
//! under mechanism-A compaction) and enqueues a `(gid, peer, baseline)` job on
//! the bridge. The poll loop drains that queue (`drainSnapshotCatchupJobs`) and
//! hands each job to THIS thread, so the heavy work — a full store-bundle dump
//! plus two blocking HTTP POSTs — runs off BOTH the pump (shared multi-raft) and
//! the customer poll loop. Per job it:
//!   1. dumps the leader's tenant store via a private sibling handle (two-handle
//!      model — never the worker's own txn-stateful handle);
//!   2. `POST /_system/v2-load-replace` the bundle to the peer (replace-load);
//!   3. `POST /_system/v2-apply-snapshot {index, term}` to install the data-free
//!      raft baseline on the peer.
//! The peer's `match` then advances past the leader's first_index, raft clears
//! `StateSnapshot`, and the tail replicates normally. This is exactly the
//! `promote_back` sequence (steps 3+4), now auto-orchestrated by the native
//! trigger instead of a CP/smoke operator.
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
                    "v2-load-replace / v2-apply-snapshot is gated; cannot push",
                .{ job.gid, job.peer },
            );
            return;
        };

        // 1. Dump the leader's tenant store via a PRIVATE sibling handle (the
        //    two-handle model — never the worker's txn-stateful handle). A read
        //    txn under LMDB MVCC is safe concurrent with the poll loop.
        const inst = (self.tenant.getInstance(job.id_str) catch null) orelse {
            std.log.warn("v2 snapshot-catchup gid={d} peer={d}: no instance for {s}", .{ job.gid, job.peer, job.id_str });
            return;
        };
        const h = kv_mod.KvStore.attachSibling(a, inst.kv, kv_mod.hashStoreId(job.id_str), inst.kv.counter) catch |e| {
            std.log.warn("v2 snapshot-catchup gid={d} peer={d}: attachSibling failed: {s}", .{ job.gid, job.peer, @errorName(e) });
            return;
        };
        defer h.close();
        const bundle = h.dumpTenantBundle(a) catch |e| {
            std.log.warn("v2 snapshot-catchup gid={d} peer={d}: dump failed: {s}", .{ job.gid, job.peer, @errorName(e) });
            return;
        };
        defer a.free(bundle);

        // 2. Replace-load the bundle on the peer.
        const lr = self.post(base, "/_system/v2-load-replace", secret, bundle, job.id_str) catch |e| {
            std.log.warn("v2 snapshot-catchup gid={d} peer={d}: v2-load-replace transport: {s}", .{ job.gid, job.peer, @errorName(e) });
            return;
        };
        if (lr != 204) {
            std.log.warn("v2 snapshot-catchup gid={d} peer={d}: v2-load-replace → {d}", .{ job.gid, job.peer, lr });
            return;
        }

        // 3. Install the data-free raft baseline {index, term} on the peer.
        const snap_body = std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\",\"index\":{d},\"term\":{d}}}", .{ job.id_str, job.index, job.term }) catch return;
        defer a.free(snap_body);
        const as = self.post(base, "/_system/v2-apply-snapshot", secret, snap_body, null) catch |e| {
            std.log.warn("v2 snapshot-catchup gid={d} peer={d}: v2-apply-snapshot transport: {s}", .{ job.gid, job.peer, @errorName(e) });
            return;
        };
        switch (as) {
            204 => std.log.info(
                "v2 snapshot-catchup gid={d} peer={d}: caught up to baseline {d}/{d} (out-of-band)",
                .{ job.gid, job.peer, job.index, job.term },
            ),
            // 409 = the peer already advanced past `index` via replication in the
            // window (SnapshotStale) or became the leader — benign, it's no longer
            // behind. Anything else is a real failure (retried next trigger tick).
            409 => std.log.info("v2 snapshot-catchup gid={d} peer={d}: apply-snapshot 409 (already ahead / now leader) — benign", .{ job.gid, job.peer }),
            else => std.log.warn("v2 snapshot-catchup gid={d} peer={d}: v2-apply-snapshot → {d}", .{ job.gid, job.peer, as }),
        }
    }

    /// One blocking POST to a peer's `/_system/*` (h2c, move-secret-gated). Like
    /// the move forward-stream this is an internal low-rate path, not a hot path.
    /// `tenant_hdr` (non-null) adds `X-Rewind-Tenant` (load-replace keys the
    /// tenant by header, apply-snapshot by body). Returns the HTTP status.
    fn post(self: *Self, base: []const u8, path: []const u8, secret: []const u8, body: []const u8, tenant_hdr: ?[]const u8) !u16 {
        const a = self.allocator;
        const url = try std.fmt.allocPrint(a, "{s}{s}", .{ base, path });
        defer a.free(url);

        var headers: std.ArrayListUnmanaged(curl.Header) = .empty;
        defer headers.deinit(a);
        try headers.append(a, .{ .name = MOVE_SECRET_HEADER, .value = secret });
        try headers.append(a, .{ .name = "Content-Type", .value = "application/octet-stream" });
        if (tenant_hdr) |t| try headers.append(a, .{ .name = TENANT_HEADER, .value = t });

        var easy = try curl.Easy.init(a);
        defer easy.deinit();
        var resp = try easy.request(a, .{
            .method = .POST,
            .url = url,
            .headers = headers.items,
            .body = body,
            .http_version = .h2c_prior_knowledge,
            .verify_tls = false,
        });
        defer resp.deinit(a);
        return resp.status;
    }
};
