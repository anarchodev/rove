//! Raft membership + log-inspection surface for the data-plane `Node` — the
//! pump-side twins of the bridge's ControlCmd relay (campaign / transfer /
//! conf-change / conf-state / voter-progress / log reads / local-snapshot
//! install). Method bodies for `node_core.zig`'s `Node`; `node.zig` re-exports
//! them via `Node`. Imports `node_core.zig` for the types — never `node.zig`.

const raft = @import("raft_rs_zig");

const core = @import("node_core.zig");
const Node = core.Node;
const Error = core.Error;

/// Force this node to start an election for `tenant_id`'s group
/// (multi-node bootstrap / test convenience). Production failover does
/// not need this — a follower whose leader goes silent campaigns on its
/// own election timeout via `tickGroups`.
pub fn campaign(self: *Node, tenant_id: u64) Error!void {
    try self.mgr.campaign(tenant_id);
}

/// Graceful pre-shutdown leadership handoff for `tenant_id`'s group: if
/// this node leads it, transfer leadership to the most caught-up follower
/// so a rolling restart costs ~one heartbeat instead of a full election
/// timeout. Returns the transferee node id, or null if this node does not
/// lead the group / is the sole voter / the group is unknown. Pump-thread
/// only (drives the Manager). No-op on a group this node has not created.
pub fn transferLeadershipAway(self: *Node, tenant_id: u64) ?u64 {
    if (self.groups.get(tenant_id) == null) return null;
    return self.mgr.transferLeadershipAway(tenant_id);
}

/// Propose a membership change on `tenant_id`'s group (leader-gated +
/// quorum-guarded in the FFI). The committed change applies + persists via
/// the pump apply path. Pump-thread only.
/// `context` rides the committed conf-change entry (the joining node's
/// transport address) so every replica learns id→addr via the
/// conf-change observer as the change applies. Empty = no context.
pub fn proposeConfChange(self: *Node, tenant_id: u64, node_id: u64, change: raft.Manager.ConfChange, context: []const u8) Error!void {
    return self.mgr.proposeConfChange(tenant_id, node_id, change, context);
}

/// Install the committed-conf-change observer on this node's manager (see
/// `raft.Manager.setConfChangeObserver`). `obs` is caller-owned + must
/// outlive the node. Call before the pump starts.
pub fn setConfChangeObserver(self: *Node, obs: *const raft.Manager.ConfChangeObserver) void {
    self.mgr.setConfChangeObserver(obs);
}

/// Read `tenant_id`'s current membership into the caller's buffers; null for
/// an unknown group. Pump-thread only (reads the Manager).
pub fn confState(self: *Node, tenant_id: u64, voters_buf: []u64, learners_buf: []u64) ?raft.Manager.ConfStateView {
    return self.mgr.confState(tenant_id, voters_buf, learners_buf);
}

/// Per-peer replication progress on `tenant_id`'s group from the LEADER's
/// view: fills `ids`/`matched`/`active` (same length) with each peer voter's
/// raft id, `matched` index, and `recent_active`, and returns `{len,
/// leader_last}`. Null on a follower / unknown group (only the leader tracks
/// peer progress) — the reconciler's "is node N a CAUGHT-UP member" signal,
/// which conf_state alone can't give (a phantom voter shows in `voters` with
/// `matched=0`). Pump-thread only (reads the Manager).
pub const VoterProgressRaw = struct { len: usize, leader_last: u64 };
pub fn voterProgress(self: *Node, tenant_id: u64, ids: []u64, matched: []u64, active: []u8) ?VoterProgressRaw {
    var out_scratch: [32]raft.Manager.VoterProgress = undefined;
    const cap = @min(@min(ids.len, matched.len), @min(active.len, out_scratch.len));
    const view = self.mgr.voterProgress(tenant_id, ids, matched, active, out_scratch[0..cap]) orelse return null;
    return .{ .len = view.peers.len, .leader_last = view.leader_last };
}

/// The term of the log entry at `index` on `tenant_id`'s group, or `null` when
/// no term is resolvable (compacted / beyond the log / unknown group) — DISTINCT
/// from a genuine term of 0 at the genesis index. The leader reports
/// `term(applied)` so a returning learner's promote-back baseline matches its
/// log. Pump-thread only.
/// Diagnostic: read this node's raft LOG entry at `index` into `buf` (the
/// replicated log content — distinct from the served store; settles an
/// orphaned fold vs divergent logs). Null on unknown group / no entry / buf
/// too small. Pump-thread only (the Manager + raft_log are pump-owned).
pub fn logEntry(self: *Node, tenant_id: u64, index: u64, buf: []u8) ?raft.Manager.LogEntry {
    return self.mgr.logEntry(tenant_id, index, buf);
}

pub fn logTerm(self: *Node, tenant_id: u64, index: u64) ?u64 {
    return self.mgr.logTerm(tenant_id, index);
}

/// This group's local raft last log index (any replica, not leader-gated) —
/// the reconciler's learner→promote catch-up signal. 0 on unknown group.
pub fn lastIndex(self: *Node, tenant_id: u64) u64 {
    return self.mgr.lastIndex(tenant_id) orelse 0;
}

/// This group's first (uncompacted) local raft log index (any replica) — the
/// low end of the promotion-time LogRecord walker's `[first..last]` range.
/// 0 on unknown group.
pub fn firstIndex(self: *Node, tenant_id: u64) u64 {
    return self.mgr.firstIndex(tenant_id) orelse 0;
}

/// Peer ids in `StateSnapshot` on this (leader) node for `tenant_id` — peers
/// that fell below the compaction floor and need an out-of-band catch-up
/// (the snapshot-free `snapshotCb` parks them here). Writes into `ids`,
/// returns the populated prefix, or null if not leader / unknown group. The
/// snapshot-trigger tick polls this over led groups. Pump-thread only.
pub fn snapshotPendingPeers(self: *Node, tenant_id: u64, ids: []u64) ?[]u64 {
    return self.mgr.snapshotPendingPeers(tenant_id, ids);
}

/// This group's out-of-band catch-up / move BASELINE index: the durable folded
/// watermark (`slot.durabilized_idx`), NOT the live `applied_idx`.
///
/// The baseline ships alongside a `StreamDumper.openSnapshot` dump whose content
/// is the COMMITTED/folded overlay — everything up to `durabilized_idx`. The
/// baseline index MUST NOT exceed that: the receiver's `apply_local_snapshot`
/// fast-forwards `committed` to the baseline, and any write above what the
/// snapshot actually contains is then ≤ its commit / below `first_index`, so it
/// never replays → a PERMANENT store fork at an agreed log index (the 2026-06-20
/// prod `__auth__` divergence; `docs/architecture/consensus-robustness.md` RC-1).
///
/// `applied_idx` is WRONG here: under `worker_overlay` a skipped own-propose
/// bumps `applied_idx` while its store write still sits in the worker's open txn
/// (folded only on `noteWorkerCommitted`), so `applied_idx > durabilized_idx` (the
/// snapshot content). Shipping `applied_idx` over-claims past the snapshot.
///
/// `durabilized_idx` is still a SAFE baseline for the tail to replicate:
/// mechanism-A compaction truncates to `durabilized_idx − snapshot_grace`
/// (`durabilizeTick`), so `durabilized_idx` sits `snapshot_grace` entries ABOVE
/// the leader's first (compacted) index — the member born here starts at an entry
/// the leader still holds. (The floor is `durabilized − grace`, so the durable
/// watermark sits ABOVE it, not below.) 0 on unknown group, and 0 for a fresh group with
/// nothing folded yet — the trigger skips index 0, correctly deferring catch-up
/// until a consistent snapshot exists. Pump-thread only (reads pump-owned slot).
pub fn baselineIndex(self: *Node, tenant_id: u64) u64 {
    const slot = self.groups.get(tenant_id) orelse return 0;
    return slot.durabilized_idx;
}

/// Diagnostic: this group's RAW live apply watermark (`slot.applied_idx`) on
/// THIS node — the highest committed entry the pump has applied. The gap
/// `applied_idx − durabilized_idx` is the worker-overlay fold lag (the RC-1
/// window). 0 on unknown group. Pump-thread only.
pub fn appliedRaw(self: *Node, tenant_id: u64) u64 {
    const slot = self.groups.get(tenant_id) orelse return 0;
    return slot.applied_idx;
}

/// Diagnostic: this group's durable folded watermark (`slot.durabilized_idx`)
/// on THIS node — what `openSnapshot` content reflects. 0 on unknown group.
/// Pump-thread only. (Same value `baselineIndex` ships; named for the readout.)
pub fn durabilizedRaw(self: *Node, tenant_id: u64) u64 {
    const slot = self.groups.get(tenant_id) orelse return 0;
    return slot.durabilized_idx;
}

/// This group's migration epoch on this node — the value the transport
/// stamps on every outbound raft message for the group (`mgr.groupEpoch`,
/// see the SendCtx stamping in `flushOutbound`). A node joining an existing
/// group MUST birth its local group at the SAME epoch, or the leader's
/// messages (stamped with the leader's epoch) are FENCED at the receiver and
/// silently dropped — the join never completes. Genesis groups born via
/// `ensureGroup` are epoch 0 (e.g. the bootstrap `__admin__` root group);
/// provisioned/attached groups are epoch 1; a moved group is higher. So the
/// join must read this and pass it to `v2-attach` rather than assume 1.
/// 0 on unknown group. Pump-thread only.
pub fn groupEpoch(self: *Node, tenant_id: u64) u64 {
    return self.mgr.groupEpoch(tenant_id);
}

/// Install a DATA-FREE snapshot baseline at {index, term} into `tenant_id`'s
/// LOCAL group (conf_change promote-back). The node must be a below-floor
/// learner; the KV state for `index` must already be loaded out-of-band (the
/// move bundle). Fast-forwards the raft log baseline so the leader can
/// replicate the tail and the node can be promoted back. Pump-thread only.
pub fn applyLocalSnapshot(self: *Node, tenant_id: u64, index: u64, term: u64, voters: ?[]const u64, learners: ?[]const u64) Error!void {
    try self.mgr.applyLocalSnapshot(tenant_id, index, term, voters, learners);
    // A2: the baseline fast-forwarded the raft LOG to `index` and the KV state
    // for `index` is already in the store (the out-of-band bundle). Stamp the
    // store's DURABLE applied watermark to `index` as well — otherwise a crash
    // in the rejoin window recovers a store BELOW the raft baseline while the
    // WAL no longer holds entries ≤ index (compacted below the baseline) → the
    // gap between the store watermark and the raft baseline is unrecoverable
    // (lost coverage / divergence). Synchronous, not deferred to
    // durabilizeTick, so the watermark is durable before this returns; stamping
    // the store at/ahead of the (not-yet-durable) raft snapshot errs safe — a
    // store AHEAD of raft only re-applies idempotently on recovery, a store
    // BEHIND raft loses data. For a data-free baseline the overlay is empty, so
    // durabilize() just writes the watermark.
    const slot = self.groups.get(tenant_id) orelse return; // just installed ⇒ present
    if (index > slot.durabilized_idx) {
        const store = self.storeFor(slot, slot.id_str) orelse return Error.UnroutedApply;
        try store.setLastAppliedRaftIdx(index);
        if (index > slot.applied_idx) slot.applied_idx = index;
        slot.durabilized_idx = index;
    }
}


