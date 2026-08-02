// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The `ControlCmd` relay — the worker→pump control-command path split out of
//! `bridge.zig`. The raft Manager is pump-thread-only, so every group
//! lifecycle / introspection op the worker needs (create/destroy group,
//! transfer leadership, conf-change, conf-state, log/index reads, epoch) is a
//! BLOCKING RPC to the pump: the wrapper builds a `ControlCmd`, `runControl`
//! enqueues it + waits, and `drainControl` executes it on the pump thread via
//! `self.node.*` (the Manager). Every function takes `self: anytype` for
//! structural access to the Bridge; `bridge.zig` re-exports the wrappers so
//! `bridge.createGroupEpoch(...)` still resolves.

const std = @import("std");
const raft = @import("raft_rs_zig");
const Error = @import("bridge_error.zig").Error;

pub const ControlCmd = struct {
    const Kind = enum { create_group_epoch, destroy_group, transfer_all_leadership, transfer_leadership, propose_conf_change, conf_state, voter_progress, apply_local_snapshot, log_term, last_index, first_index, baseline_index, applied_raw, durabilized_raw, log_entry, group_epoch };
    kind: Kind,
    gid: u64,
    /// Borrowed from the gid's `GroupSig.id_str` (pointer-stable); used by
    /// `create_group_epoch` to open the tenant's group store.
    id_str: []const u8 = &.{},
    epoch: u64 = 0,
    /// `create_group_epoch`: birth the group with THIS node as a learner
    /// (joining an existing group) rather than a voter — see node.createGroupCore.
    as_learner: bool = false,
    /// `propose_conf_change`: the raft node id to change + the op (0 add_voter /
    /// 1 remove / 2 add_learner — matches `raft.Manager.ConfChange`).
    node_id: u64 = 0,
    cc_type: u8 = 0,
    /// `propose_conf_change`: the entry context replicated with the committed
    /// change (the changing node's transport address), so every replica learns
    /// id→addr via the conf-change observer on apply. Aliases the caller's slice
    /// — valid because `runControl` blocks until the pump drains the cmd. Empty
    /// for a remove/demote or a still-static cluster.
    cc_context: []const u8 = &.{},
    /// `apply_local_snapshot`: the baseline {index, term} to install.
    /// `log_term` / `log_entry`: `snap_index` is the query index, `snap_term` the
    /// result term.
    snap_index: u64 = 0,
    snap_term: u64 = 0,
    /// `log_entry` (diagnostic): caller buffer (in) for the entry's data + the
    /// bytes written (out). `lt_ok` flags a resolved entry.
    entry_buf: ?[]u8 = null,
    entry_len: usize = 0,
    /// `apply_local_snapshot` (membership SSOT): the source leader's
    /// ConfState the baseline carries, so a joiner learns its membership from the
    /// snapshot. Null → keep the group's current membership (membership-neutral
    /// promote-back). Borrowed from the caller stack for the call.
    snap_voters: ?[]const u64 = null,
    snap_learners: ?[]const u64 = null,
    /// `create_group_epoch` (cluster node-set SSOT): the initial voter
    /// set a FRESH group is born with, supplied by the control plane (the cluster
    /// node set) instead of the node's static `REWIND_VOTERS`. Null → `self.voters`.
    /// Borrowed from the caller stack for the blocking call.
    birth_voters: ?[]const u64 = null,
    /// `conf_state`: caller buffers to fill + the counts written back.
    cs_voters: []u64 = &.{},
    cs_learners: []u64 = &.{},
    cs_voters_len: usize = 0,
    cs_learners_len: usize = 0,
    cs_ok: bool = false,
    /// `voter_progress`: caller buffers (parallel: id/matched/active) filled by
    /// the pump from the leader's per-peer view; len + leader_last written back.
    vp_ids: []u64 = &.{},
    vp_matched: []u64 = &.{},
    vp_active: []u8 = &.{},
    vp_len: usize = 0,
    vp_leader_last: u64 = 0,
    vp_ok: bool = false,
    /// `log_term`: true iff a term was resolvable at the index (distinguishes a
    /// genuine term of 0 from "unknown group / compacted / beyond log").
    lt_ok: bool = false,
    /// Result, written by the pump before signaling `done`.
    err: ?Error = null,
    /// `transfer_all_leadership` writes the number of groups it handed off here.
    count: usize = 0,
    done: std.Thread.ResetEvent = .{},
};

pub fn createGroupEpoch(self: anytype, gid: u64, epoch: u64, birth_voters: ?[]const u64) Error!void {
    const sig = self.sigFor(gid) orelse return Error.UnknownTenant;
    var cmd: ControlCmd = .{ .kind = .create_group_epoch, .gid = gid, .id_str = sig.id_str, .epoch = epoch, .birth_voters = birth_voters };
    return runControl(self, &cmd);
}

/// Create `gid`'s group at `epoch` AND install a data-free raft baseline at
/// {index, term} in the SAME pump op — atomic, so the fresh group is never
/// reachable at last_index 0 (where a leader heartbeat carrying commit > 0
/// would trip raft's commit_to fatal!). The reconciler bootstrap path: the
/// kvexp state for `index` must already be loaded into the store. `index` 0
/// behaves exactly like `createGroupEpoch` (no baseline). `as_learner` births
/// the group with this node as a non-voting learner (joining an existing
/// group via the reconciler's learner-first path) — see node.createGroupCore.
/// `voters`/`learners` (membership SSOT): the source leader's
/// ConfState the installed baseline carries, so the joining node learns its
/// real membership from the snapshot rather than the static voter set. Null →
/// membership-neutral (the born/current prs). The supplied membership MUST
/// contain this node (`Error.SelfNotInConfState` otherwise — the leader must
/// have conf-change-added it first).
pub fn createGroupAtBaseline(self: anytype, gid: u64, epoch: u64, index: u64, term: u64, as_learner: bool, voters: ?[]const u64, learners: ?[]const u64) Error!void {
    const sig = self.sigFor(gid) orelse return Error.UnknownTenant;
    // BIRTH the group with the baseline's membership (`birth_voters = voters`),
    // not just the post-birth snapshot ConfState (`snap_voters`). Without this
    // the group is born via the `self.voters` FALLBACK first and the snapshot
    // only corrects it afterwards — benign on a static cluster (self.voters is
    // the full set) but FATAL on a genesis node, whose self.voters is `{self}`:
    // it births a rogue sole-self group (auto-campaign + a half-init group that
    // errors → double-free crash) before the snapshot can fix it. Born with the
    // real membership directly, the fallback is never taken (matches the
    // no-baseline `createGroupEpoch` path, which already births with `voters`).
    var cmd: ControlCmd = .{ .kind = .create_group_epoch, .gid = gid, .id_str = sig.id_str, .epoch = epoch, .snap_index = index, .snap_term = term, .as_learner = as_learner, .birth_voters = voters, .snap_voters = voters, .snap_learners = learners };
    return runControl(self, &cmd);
}

/// Destroy a tenant's raft group + reclaim its WAL on the pump thread
/// (move source cleanup). Blocks until done.
pub fn destroyGroup(self: anytype, gid: u64) Error!void {
    var cmd: ControlCmd = .{ .kind = .destroy_group, .gid = gid };
    return runControl(self, &cmd);
}

/// Graceful shutdown: hand off leadership of every group this node leads
/// to a caught-up follower BEFORE stopping the pump, so a rolling restart
/// (the `/deploy` path) costs ~one heartbeat per led group instead of a
/// full election timeout. Runs on the pump thread (control cmd). Returns
/// the number of groups handed off. No-op returning 0 on a single-node
/// deployment (the sole voter leads everything with no follower to hand to)
/// or if the pump is already stopped. The caller should then poll
/// `leadsAnyGroup` for a bounded grace window so the `MsgTimeoutNow` →
/// new-leader round-trips land while the pump is still running.
pub fn transferAllLeadership(self: anytype) usize {
    if (self.node.isSingleNode()) return 0;
    var cmd: ControlCmd = .{ .kind = .transfer_all_leadership, .gid = 0 };
    runControl(self, &cmd) catch return 0;
    return cmd.count;
}

/// Diagnostic/test: force a leadership handoff of ONE group to its most
/// caught-up follower (no-op if this node is not its leader). Returns 1 if a
/// handoff was initiated, else 0. Drives the churn soak's leadership flips.
pub fn transferLeadership(self: anytype, gid: u64) usize {
    if (self.node.isSingleNode()) return 0;
    var cmd: ControlCmd = .{ .kind = .transfer_leadership, .gid = gid };
    runControl(self, &cmd) catch return 0;
    return cmd.count;
}

/// Operator-triggered membership change on `gid`'s group:
/// `cc_type` 0 = add voter / promote, 1 = remove, 2 = add learner / demote.
/// Runs on the pump (the only Manager toucher); leader-gated + quorum-guarded
/// in the FFI (`Error.NotLeader` / `Error.ConfChangeQuorumGuard`). The
/// committed change applies + persists durably via the apply path.
/// `context` (the changing node's transport address) rides the committed
/// conf-change so every replica learns id→addr via the conf-change observer
/// on apply — the address propagates through the log like the membership.
/// Empty for a remove/demote / still-static cluster.
pub fn proposeConfChange(self: anytype, gid: u64, node_id: u64, cc_type: u8, context: []const u8) Error!void {
    var cmd: ControlCmd = .{ .kind = .propose_conf_change, .gid = gid, .node_id = node_id, .cc_type = cc_type, .cc_context = context };
    return runControl(self, &cmd);
}

pub const ConfStateView = struct { voters: []const u64, learners: []const u64 };

/// Read `gid`'s current membership into the caller's buffers (slices into
/// them on success). Runs a pump-thread control cmd. Null for an unknown
/// group or if the pump is down.
pub fn confState(self: anytype, gid: u64, voters_buf: []u64, learners_buf: []u64) ?ConfStateView {
    var cmd: ControlCmd = .{ .kind = .conf_state, .gid = gid, .cs_voters = voters_buf, .cs_learners = learners_buf };
    runControl(self, &cmd) catch return null;
    if (!cmd.cs_ok) return null;
    return .{ .voters = voters_buf[0..cmd.cs_voters_len], .learners = learners_buf[0..cmd.cs_learners_len] };
}

pub const VoterProgressView = struct { len: usize, leader_last: u64 };

/// Per-peer replication progress on `gid`'s group from the LEADER's view:
/// fills the parallel `ids`/`matched`/`active` buffers (same length) and
/// returns `{len, leader_last}`. Null on a follower / unknown group / pump
/// down. The reconciler's "is node N a caught-up member" truth signal
/// (conf_state alone lies — a phantom voter has `matched=0`). Control cmd.
pub fn voterProgress(self: anytype, gid: u64, ids: []u64, matched: []u64, active: []u8) ?VoterProgressView {
    var cmd: ControlCmd = .{ .kind = .voter_progress, .gid = gid, .vp_ids = ids, .vp_matched = matched, .vp_active = active };
    runControl(self, &cmd) catch return null;
    if (!cmd.vp_ok) return null;
    return .{ .len = cmd.vp_len, .leader_last = cmd.vp_leader_last };
}

/// The term of the log entry at `index` on `gid`'s group, or `null` when no
/// term is resolvable — compacted / beyond the log / unknown group / pump
/// down. A leader reports `term(applied)` for a returning learner's
/// promote-back baseline. `null` is DISTINCT from a genuine term of 0 (the
/// genesis index), so a caller never stamps a fake 0 into a baseline.
/// Pump-thread control cmd.
pub fn logTerm(self: anytype, gid: u64, index: u64) ?u64 {
    var cmd: ControlCmd = .{ .kind = .log_term, .gid = gid, .snap_index = index };
    runControl(self, &cmd) catch return null;
    return if (cmd.lt_ok) cmd.snap_term else null;
}

pub const LogEntry = struct { term: u64, data: []const u8 };

/// Diagnostic: read the raft LOG entry at `index` for `gid` into `buf` (the
/// replicated log content). Null on unknown group / no entry / buf too small.
/// `data` slices into `buf`. Pump op.
pub fn logEntry(self: anytype, gid: u64, index: u64, buf: []u8) ?LogEntry {
    var cmd: ControlCmd = .{ .kind = .log_entry, .gid = gid, .snap_index = index, .entry_buf = buf };
    runControl(self, &cmd) catch return null;
    if (!cmd.lt_ok) return null;
    return .{ .term = cmd.snap_term, .data = buf[0..cmd.entry_len] };
}

/// This group's local raft last log index (any replica) — the reconciler's
/// learner→promote catch-up signal. Pump op (the Manager is pump-only). 0 on
/// unknown group / pump failure.
pub fn lastIndex(self: anytype, gid: u64) u64 {
    var cmd: ControlCmd = .{ .kind = .last_index, .gid = gid };
    runControl(self, &cmd) catch return 0;
    return cmd.snap_index;
}

/// This group's first (uncompacted) local raft log index — the lowest index
/// still recoverable from the live log. The promotion-time LogRecord walker
/// (`docs/architecture/deployment-and-logs.md`) walks `[firstIndex..lastIndex]`
/// on leader promotion. Pump op. 0 on unknown group / pump failure.
pub fn firstIndex(self: anytype, gid: u64) u64 {
    var cmd: ControlCmd = .{ .kind = .first_index, .gid = gid };
    runControl(self, &cmd) catch return 0;
    return cmd.snap_index;
}

/// This group's LIVE applied index on the leader (`slot.applied_idx`) — the
/// out-of-band baseline a new member is born at. Always >= the leader's first
/// (compacted) log index, so the baseline points at an entry the leader still
/// holds (unlike the durabilized store watermark, which lags under churn).
/// Pump op. 0 on unknown group / pump failure.
pub fn baselineIndex(self: anytype, gid: u64) u64 {
    var cmd: ControlCmd = .{ .kind = .baseline_index, .gid = gid };
    runControl(self, &cmd) catch return 0;
    return cmd.snap_index;
}

/// Diagnostic: this node's RAW apply watermark for `gid` (`slot.applied_idx`).
pub fn appliedRaw(self: anytype, gid: u64) u64 {
    var cmd: ControlCmd = .{ .kind = .applied_raw, .gid = gid };
    runControl(self, &cmd) catch return 0;
    return cmd.snap_index;
}

/// Diagnostic: this node's durable folded watermark for `gid`.
pub fn durabilizedRaw(self: anytype, gid: u64) u64 {
    var cmd: ControlCmd = .{ .kind = .durabilized_raw, .gid = gid };
    runControl(self, &cmd) catch return 0;
    return cmd.snap_index;
}

/// This group's migration epoch on the leader — a joining node must birth its
/// local group at this exact epoch or the leader's messages are fenced out.
/// Pump op. 0 on unknown group / pump failure (also the genuine genesis epoch,
/// which is correct — a genesis group IS epoch 0).
pub fn groupEpoch(self: anytype, gid: u64) u64 {
    var cmd: ControlCmd = .{ .kind = .group_epoch, .gid = gid };
    runControl(self, &cmd) catch return 0;
    return cmd.snap_index;
}

/// Install a DATA-FREE snapshot baseline at {index, term} into `gid`'s LOCAL
/// group (conf_change promote-back). The node must be a below-floor learner;
/// the KV state for `index` must already be loaded out-of-band (the move
/// bundle). Fast-forwards the raft log baseline so the leader can replicate
/// the tail and the node can be promoted back. Pump-thread control cmd.
/// `Error.NotLeader` if this node leads the group; `Error.SnapshotStale` if
/// `index` is not ahead of committed.
pub fn applyLocalSnapshot(self: anytype, gid: u64, index: u64, term: u64, voters: ?[]const u64, learners: ?[]const u64) Error!void {
    var cmd: ControlCmd = .{ .kind = .apply_local_snapshot, .gid = gid, .snap_index = index, .snap_term = term, .snap_voters = voters, .snap_learners = learners };
    return runControl(self, &cmd);
}

/// Enqueue a control command for the pump thread and block until it
/// runs. Requires the pump thread (the only `Manager` toucher) to be
/// live; the move path always runs under `startPump`.
fn runControl(self: anytype, cmd: *ControlCmd) Error!void {
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pump_thread == null) return Error.PumpNotRunning;
        self.control_inbox.append(self.allocator, cmd) catch return Error.OutOfMemory;
    }
    cmd.done.wait();
    if (cmd.err) |e| return e;
}

/// Drain + execute queued control commands on the pump thread. Run
/// from `pumpOnce` with the bridge mutex NOT held (the node ops
/// re-enter via the commit hook). Returns true if any ran.
pub fn drainControl(self: anytype) bool {
    var batch: [16]*ControlCmd = undefined;
    var n: usize = 0;
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (n < batch.len and self.control_inbox.items.len > 0) {
            batch[n] = self.control_inbox.orderedRemove(0);
            n += 1;
        }
    }
    for (batch[0..n]) |cmd| {
        cmd.err = switch (cmd.kind) {
            .create_group_epoch => blk: {
                // INVARIANT (enforced both ends): a baseline at index>0 MUST
                // carry a real term. A term-0 baseline makes raft-rs's restore
                // fast-forward commit_to past an empty log → fatal!. The producer
                // (v2-applied-baseline) refuses to emit one (409); refuse to
                // install one too rather than silently birthing a crash-prone group.
                if (cmd.snap_index > 0 and cmd.snap_term == 0) {
                    std.log.err("v2 bridge: refusing term-0 baseline for gid {d} at index {d}", .{ cmd.gid, cmd.snap_index });
                    break :blk Error.InvalidBaseline;
                }
                _ = self.node.createGroupAtEpoch(cmd.gid, cmd.id_str, cmd.epoch, cmd.as_learner, cmd.birth_voters) catch |e| break :blk e;
                // Atomic baseline (createGroupAtBaseline): install the data-free
                // snapshot in the SAME pump op as group creation so the fresh
                // group is never observable at last_index 0 between creation and
                // baseline. Without this, a leader heartbeat carrying commit > 0
                // can reach the empty group first and trip raft's commit_to
                // fatal! (to_commit out of range [last_index 0]). If the install
                // fails, TEAR THE HALF-BORN GROUP DOWN — leaving it live at
                // last_index 0 is the exact window this path exists to close
                // (a labeled break is not an error return, so errdefer won't
                // fire here; roll back explicitly).
                if (cmd.snap_index > 0) {
                    self.node.applyLocalSnapshot(cmd.gid, cmd.snap_index, cmd.snap_term, cmd.snap_voters, cmd.snap_learners) catch |e| {
                        self.node.destroyGroupAndReclaim(cmd.gid) catch |de|
                            std.log.err("v2 bridge: rollback of half-born gid {d} failed: {s}", .{ cmd.gid, @errorName(de) });
                        break :blk e;
                    };
                }
                break :blk null;
            },
            .destroy_group => blk: {
                self.node.destroyGroupAndReclaim(cmd.gid) catch |e| break :blk e;
                break :blk null;
            },
            .propose_conf_change => blk: {
                self.node.proposeConfChange(cmd.gid, cmd.node_id, @enumFromInt(cmd.cc_type), cmd.cc_context) catch |e| break :blk e;
                break :blk null;
            },
            .conf_state => blk: {
                if (self.node.confState(cmd.gid, cmd.cs_voters, cmd.cs_learners)) |cs| {
                    cmd.cs_voters_len = cs.voters.len;
                    cmd.cs_learners_len = cs.learners.len;
                    cmd.cs_ok = true;
                }
                break :blk null;
            },
            .voter_progress => blk: {
                if (self.node.voterProgress(cmd.gid, cmd.vp_ids, cmd.vp_matched, cmd.vp_active)) |vp| {
                    cmd.vp_len = vp.len;
                    cmd.vp_leader_last = vp.leader_last;
                    cmd.vp_ok = true;
                }
                break :blk null;
            },
            .log_entry => blk: {
                if (cmd.entry_buf) |buf| {
                    if (self.node.logEntry(cmd.gid, cmd.snap_index, buf)) |e| {
                        cmd.snap_term = e.term;
                        cmd.entry_len = e.data.len;
                        cmd.lt_ok = true;
                    }
                }
                break :blk null;
            },
            .log_term => blk: {
                if (self.node.logTerm(cmd.gid, cmd.snap_index)) |t| {
                    cmd.snap_term = t;
                    cmd.lt_ok = true;
                }
                break :blk null;
            },
            .last_index => blk: {
                cmd.snap_index = self.node.lastIndex(cmd.gid);
                break :blk null;
            },
            .first_index => blk: {
                cmd.snap_index = self.node.firstIndex(cmd.gid);
                break :blk null;
            },
            .baseline_index => blk: {
                cmd.snap_index = self.node.baselineIndex(cmd.gid);
                break :blk null;
            },
            .applied_raw => blk: {
                cmd.snap_index = self.node.appliedRaw(cmd.gid);
                break :blk null;
            },
            .durabilized_raw => blk: {
                cmd.snap_index = self.node.durabilizedRaw(cmd.gid);
                break :blk null;
            },
            .group_epoch => blk: {
                cmd.snap_index = self.node.groupEpoch(cmd.gid);
                break :blk null;
            },
            .apply_local_snapshot => blk: {
                self.node.applyLocalSnapshot(cmd.gid, cmd.snap_index, cmd.snap_term, cmd.snap_voters, cmd.snap_learners) catch |e| break :blk e;
                break :blk null;
            },
            .transfer_all_leadership => blk: {
                // Graceful shutdown: hand off leadership of every group
                // this node currently leads. Snapshot the led gids under
                // the lock (reading each `is_leader` atomic, like
                // `leadsAnyGroup`), then release it before driving the
                // Manager — `transferLeadershipAway` is pump-side and
                // takes no bridge lock.
                var gids: std.ArrayListUnmanaged(u64) = .empty;
                defer gids.deinit(self.allocator);
                {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    var it = self.groups.iterator();
                    while (it.next()) |entry| {
                        if (entry.value_ptr.*.is_leader.load(.acquire))
                            gids.append(self.allocator, entry.key_ptr.*) catch {};
                    }
                }
                cmd.count = 0;
                for (gids.items) |gid| {
                    if (self.node.transferLeadershipAway(gid) != null) cmd.count += 1;
                }
                break :blk null;
            },
            .transfer_leadership => blk: {
                // Diagnostic/test: force a leadership handoff of ONE group to
                // its most caught-up follower (no-op if not the leader). Used by
                // the churn soak to flip leadership under in-flight writes.
                cmd.count = if (self.node.transferLeadershipAway(cmd.gid) != null) 1 else 0;
                break :blk null;
            },
        };
        cmd.done.set();
    }
    return n > 0;
}
