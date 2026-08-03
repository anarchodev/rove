// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The `Bridge`'s pump thread — the loop that drives the per-tenant `Node`
//! forward: `pumpLoop` (thread entry) → `pumpOnce` (drain the propose inbox,
//! tick the node, refresh leadership, sweep lost leadership, service snapshot
//! catch-up), plus `snapshotTriggerTick`, `refreshLeadership`/`refreshOneLocked`,
//! and `sweepLostLeadership`. Split out of `bridge.zig`, which stays the module
//! root and re-exports these as `Bridge` methods. Every function takes
//! `self: anytype` for structural access to the Bridge — the same convention as
//! `bridge_control.zig` — so this file never imports `bridge.zig` (the
//! root-import trap; bridge.zig is `v2_bridge_mod`'s root).

const std = @import("std");
const Error = @import("bridge_error.zig").Error;

pub fn pumpLoop(self: anytype) void {
    // Stall probes: a pump pause longer than the election timeout is a
    // spurious-election trigger (ticks, heartbeat sends, and inbound
    // message steps all ride this loop), so a slow cycle and a slow
    // inter-cycle gap each warn with a wall-clock stamp. The cycle warn
    // catches in-pump stalls (the WAL fsync tail is the dominant one —
    // see the flush probe in node_pump.zig); the gap warn catches
    // scheduler starvation between cycles. The idle 1ms sleep sits well
    // under the threshold.
    var last_cycle_end: i128 = std.time.nanoTimestamp();
    while (!self.stop.load(.acquire)) {
        const cycle_start = std.time.nanoTimestamp();
        const gap_us = @divTrunc(cycle_start - last_cycle_end, std.time.ns_per_us);
        if (gap_us > 5000)
            std.log.warn("pump inter-cycle gap {d}us at={d}", .{ gap_us, std.time.milliTimestamp() });
        // A pump error is an INFALLIBILITY VIOLATION, not an operational
        // hiccup: a committed entry failed to decode/apply (raft has
        // already consumed it via advance_apply — it will never be
        // redelivered, so this replica is silently diverged from the
        // log), or the WAL fsync failed (nothing acked from here on
        // would be durable), or allocation failed on the commit path.
        // Warn-and-continue would serve a diverged replica that could
        // later win an election; die loudly instead
        // — a restart replays the WAL from the last checkpoint and
        // converges. (Tests drive `pumpOnce` directly and still see
        // error returns; boot-time recovery has its own retry-from-
        // scratch semantics in `recoverGroups`.)
        const did = self.pumpOnce() catch |e| {
            std.debug.panic("v2 bridge pump: unrecoverable apply/flush failure: {s}", .{@errorName(e)});
        };
        const cycle_us = @divTrunc(std.time.nanoTimestamp() - cycle_start, std.time.ns_per_us);
        if (cycle_us > 5000)
            std.log.warn("pump cycle took {d}us (did_work={}) at={d}", .{ cycle_us, did, std.time.milliTimestamp() });
        last_cycle_end = std.time.nanoTimestamp();
        // Idle backoff: nothing to drain and nothing committed this
        // cycle. Single-node has no election/heartbeat traffic to
        // service, so a short sleep is fine — EXCEPT while an async WAL
        // flush is outstanding: a commit is one `ackCovered` away the
        // moment the fsync lands, and the full millisecond would dominate
        // per-write latency (an fsync is typically a fraction of it). Poll
        // finely instead until the awaiting list drains.
        if (!did) {
            const awaiting = self.node.wal_flusher.started() and
                self.node.active_set.persist_ack.items.len > 0;
            std.Thread.sleep(if (awaiting) 50 * std.time.ns_per_us else 1 * std.time.ns_per_ms);
        }
    }
}

/// One drain + pump cycle. Returns true if it proposed or committed
/// anything this cycle. Pump-thread-only (touches the `Node`). Public
/// so tests can drive the bridge deterministically without the thread.
pub fn pumpOnce(self: anytype) Error!bool {
    // 1. Drain the inbox under the lock, then release it before any
    //    `node.*` call (ensureGroup/propose/pump must not run with
    //    the bridge mutex held — the commit hook re-acquires it).
    var batch: @TypeOf(self.inbox) = .empty;
    defer batch.deinit(self.allocator);
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.inbox.items.len > 0) {
            batch.appendSlice(self.allocator, self.inbox.items) catch return Error.OutOfMemory;
            self.inbox.clearRetainingCapacity();
        }
    }

    var did_work = batch.items.len > 0;

    // 1b. Service move-orchestration control ops (group create-at-
    //     epoch / destroy) on the pump thread before proposes, so an
    //     attach's group exists before any post-move write lands.
    if (self.drainControl()) did_work = true;

    // 2. Submit each drained propose to its tenant's group. Single-node:
    //    created on first sight (`ensureGroup` — the sole voter is
    //    trivially the whole group) and driven to leader. Multi-node: the
    //    group must ALREADY exist — born by the provision/move attach
    //    (`createGroupAtEpoch`) or boot recovery (`recoverGroups`); a
    //    propose NEVER births one. A propose for a locally-unknown group
    //    means this node is not (yet) a member — most dangerously a WIPED
    //    voter whose re-bootstrap is pending: lazily birthing a fresh
    //    epoch-0 group here makes the node answer `v2-confstate` 200, so
    //    the membership reconciler reads it as a hosted-but-inactive voter
    //    and holds the demote grace instead of the remove→re-add heal,
    //    while the husk fences out real replication and serves an empty
    //    store. Fault fast instead: the worker 503s and the client re-aims
    //    at a real member. If this node IS a member but not the leader,
    //    `node.propose` rejects and we fault the same way.
    for (batch.items) |item| {
        defer self.allocator.free(item.payload);
        if (!self.node.isSingleNode() and self.node.groups.get(item.gid) == null) {
            self.unhosted_propose_count +%= 1;
            if (self.unhosted_propose_count == 1 or self.unhosted_propose_count % 1000 == 0)
                std.log.warn("v2 bridge propose gid={d} ({s}): group not hosted on this node — faulted, no lazy birth on multi-node ({d} total)", .{ item.gid, item.id_str, self.unhosted_propose_count });
            self.faultTenant(item.gid);
            continue;
        }
        _ = self.node.ensureGroup(item.gid, item.id_str) catch |e| {
            std.log.warn("v2 bridge ensureGroup gid={d}: {s}", .{ item.gid, @errorName(e) });
            self.faultTenant(item.gid);
            continue;
        };
        self.node.proposeFramed(item.gid, self.origin_id, item.seq, item.payload) catch |e| {
            std.log.warn("v2 bridge propose gid={d}: {s}", .{ item.gid, @errorName(e) });
            self.faultTenant(item.gid);
        };
    }

    // 2b. Service wake requests: re-tick (`bumpActive`) any group the
    //     worker asked us to wake (a write hit a non-leader gate). Without
    //     this a hibernated group whose leader died never re-elects. Drain
    //     under the lock, bump OUTSIDE it (bumpActive mutates pump-owned
    //     node state and must not run with the bridge mutex held). Done
    //     before `node.pump()` so a woken group ticks THIS cycle.
    {
        var wakes: std.ArrayListUnmanaged(u64) = .empty;
        defer wakes.deinit(self.allocator);
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.wake_inbox.items.len > 0) {
                wakes.appendSlice(self.allocator, self.wake_inbox.items) catch {};
                self.wake_inbox.clearRetainingCapacity();
            }
        }
        if (wakes.items.len > 0) did_work = true;
        for (wakes.items) |gid| self.node.bumpActive(gid) catch |e|
            std.log.warn("v2 bridge wake gid={d}: {s}", .{ gid, @errorName(e) });
    }

    // 3. Drive one ready cycle: commits + applies + fires the commit
    //    hook (which advances committed_seq via the pending FIFO).
    const committed = self.node.pump() catch |e| {
        return e;
    };
    if (committed) did_work = true;

    // 4. Leadership-loss sweep: fault in-flight tenants this node no
    //    longer leads (an entry proposed here that will never commit
    //    locally because leadership moved). O(in-flight), bounded per
    //    cycle; the rest are swept next cycle.
    self.sweepLostLeadership();

    // 4b. Worker commit-wait timeouts, executed HERE so the fault is
    //     serialized against this thread's skip/commit decisions
    //     (see `requestFault`).
    self.drainFaultRequests();

    // 5. Publish each group's leadership for the worker thread (which
    //    must not touch the Manager). O(groups) per cycle — the same
    //    order as the active-set tick; pre-hibernation that is fine.
    self.refreshLeadership();

    // 6. Snapshot-trigger tick: detect peers in `StateSnapshot` (fell below
    //    the leader's compaction first_index under mechanism-A compaction)
    //    and enqueue an out-of-band catch-up for the worker thread. The
    //    native trigger that replaces the lockstep WAL floor.
    self.snapshotTriggerTick();

    return did_work;
}

/// How often `snapshotTriggerTick` scans the active set for `StateSnapshot`
/// peers. The in-flight dedup means a re-scan while a transfer runs is a
/// no-op, so this only bounds detection latency for a freshly-stranded peer.
const SNAPSHOT_TRIGGER_INTERVAL_NS: i64 = 100 * std.time.ns_per_ms;

/// Pump thread: over the active groups this node leads, find peers raft holds
/// in `ProgressState::Snapshot` (the snapshot-free `snapshotCb` parks a peer
/// here once it falls below the leader's compacted first_index) and enqueue an
/// out-of-band catch-up for each. The baseline {index, term} is computed HERE
/// (pump-only `baselineIndex` + `logTerm`); the worker's `SnapshotCatchupThread`
/// dumps the store + pushes it to the peer. Interval-gated; reads pump-owned
/// `node.active_set.active` + node accessors with the bridge mutex NOT held (enqueue takes
/// it internally). O(active peers).
pub fn snapshotTriggerTick(self: anytype) void {
    if (self.node.isSingleNode()) return;
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    if (now_ns - self.last_snapshot_trigger_ns < SNAPSHOT_TRIGGER_INTERVAL_NS) return;
    self.last_snapshot_trigger_ns = now_ns;
    var ids_buf: [16]u64 = undefined;
    for (self.node.active_set.active.items) |gid| {
        const peers = self.node.snapshotPendingPeers(gid, &ids_buf) orelse continue; // not leader / unknown
        if (peers.len == 0) continue;
        // Baseline the peer will install: the leader's live applied index +
        // the term of its log entry there. `logTerm` is null when the leader's
        // own log can't resolve a term (watermark drifted ahead of the log) —
        // skip this tick and retry once the log covers it, exactly as
        // `v2-applied-baseline` refuses rather than hand out a bogus term.
        const index = self.node.baselineIndex(gid);
        if (index == 0) continue; // nothing applied yet — nothing to snapshot
        const term = self.node.logTerm(gid, index) orelse continue;
        for (peers) |peer| {
            if (self.enqueueSnapshotCatchup(gid, peer, index, term)) {
                std.log.info(
                    "v2 snapshot-trigger gid={d}: peer {d} in StateSnapshot — queued out-of-band catch-up to baseline {d}/{d}",
                    .{ gid, peer, index, term },
                );
            }
        }
    }
}

/// How often `refreshLeadership` falls back to a FULL all-groups scan.
/// Leadership edges on a ticking group are caught same-cycle via the
/// active set; the full scan only bounds staleness for the rare edge
/// with no wake (e.g. a partition-heal where a hibernated old leader's
/// first post-heal message is a plain heartbeat that steps it down).
const LEADER_SCAN_INTERVAL_NS: i64 = 50 * std.time.ns_per_ms;

/// Refresh groups' `is_leader` atomics from the Manager. Per cycle this
/// covers only the node's ACTIVE set — leadership can only change when
/// a group processes ticks or messages, which (almost always — see
/// `LEADER_SCAN_INTERVAL_NS`) implies it was woken into the active set
/// earlier in the same pump cycle. A full all-groups scan runs
/// interval-gated as the staleness backstop. Scanning every registered
/// group every cycle under the bridge mutex would be an O(N_tenants)
/// per-cycle hot-path cost that nullifies hibernation's O(active) win at
/// K=thousands. Pump-thread only (reads the Manager
/// + `node.active_set.active`). The worker reads the atomics lock-free via
/// `isLeaderOf`.
pub fn refreshLeadership(self: anytype) void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const full = now_ns - self.last_leader_scan_ns >= LEADER_SCAN_INTERVAL_NS;
    if (full) self.last_leader_scan_ns = now_ns;
    self.mutex.lock();
    defer self.mutex.unlock();
    const single = self.node.isSingleNode();
    if (full) {
        var it = self.groups.iterator();
        while (it.next()) |e| {
            self.refreshOneLocked(e.value_ptr.*, e.key_ptr.*, single);
        }
    } else {
        for (self.node.active_set.active.items) |gid| {
            const sig = self.groups.get(gid) orelse continue;
            self.refreshOneLocked(sig, gid, single);
        }
    }
}

/// Refresh one group's published leadership + detect the
/// follower→leader promotion edge. Caller holds `mutex`; pump thread.
pub fn refreshOneLocked(self: anytype, sig: anytype, gid: u64, single: bool) void {
    const now = self.node.isLeader(gid);
    const promoted_edge = now and !sig.was_leader;
    // Count every false→true promotion edge (incl. single-node formation)
    // for the spurious-election metric; the reader nets out the expected
    // one-per-group baseline.
    if (promoted_edge) _ = self.leadership_acquisitions.fetchAdd(1, .monotonic);
    // false→true promotion edge: queue for the worker's on-promotion
    // recovery hook. Skipped on a single node — the sole voter leads
    // every group from creation and never fails over, so there is no
    // old-leader RAM state to reconstruct (and the leader already
    // loaded the deployment + armed watermarks inline at release).
    if (!single and promoted_edge) {
        self.promoted.append(self.allocator, sig.gid) catch {};
    }
    sig.was_leader = now;
    sig.is_leader.store(now, .release);
    sig.leader_id.store(self.node.leaderId(gid), .release);
    sig.formed.store(self.node.hasGroup(gid), .release);
}


/// Fault the in-flight proposes of any tenant this node no longer leads.
/// Snapshots ALL of `in_flight` under the lock (it is O(in-flight
/// tenants) by design — a fixed 32-slot snapshot with no cursor
/// silently never checked the tail, so a tenant beyond the first 32
/// ate the full commit-wait timeout instead of a fast 503), then
/// checks leadership + faults outside it (the Manager call +
/// `faultTenant` each take their own short critical sections).
/// `sweep_scratch` is reused across cycles to avoid per-cycle
/// allocation. Pump-thread only.
pub fn sweepLostLeadership(self: anytype) void {
    self.sweep_scratch.clearRetainingCapacity();
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.sweep_scratch.appendSlice(self.allocator, self.in_flight.items) catch return;
    }
    for (self.sweep_scratch.items) |g| {
        if (!self.node.isLeader(g)) self.faultTenant(g);
    }
}

// ── Commit hook + skip query (pump thread, via node.applyCb) ─────


