// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The pump's hibernating active set — the per-node group-id worklists plus
//! the dedup-append invariant that keeps each gid on each list at most once.
//!
//! `Node` drives per-tenant raft groups but only ticks a HIBERNATING subset
//! (`multiraft-scaling-learnings §3.1`): a group idle for `hibernate_ns` drops
//! out and is no longer ticked, so pump cost is O(active), not O(all groups).
//! Four gid worklists back that machine, and each pairs with a per-slot bool so
//! a gid is enqueued at most once:
//!
//!   - `active`      — ticked every cycle          ⇄ `SlotHib.in_active`
//!   - `dirty`       — committed-not-durabilized    ⇄ `SlotHib.in_dirty`
//!   - `persist_ack` — awaiting the post-fsync ack  ⇄ `SlotHib.in_persist_ack`
//!   - `woke_scratch`— per-cycle drain scratch (no dedup bit; cleared each cycle)
//!
//! The append-guard ("append + set the bit iff the bit is clear") is the subtle
//! half — a missed guard double-enqueues a gid and corrupts the O(active)
//! accounting — so it lives in ONE place here (`enqueue`, via the `add*`
//! wrappers). The paired clear is a bare `slot.hib.in_* = false` at the bulk
//! sweep/drain sites in `node.zig`, where the list removal it accompanies lives.
//!
//! This file must not `@import("node.zig")` (that file is a build-module root —
//! importing it back is the root-import trap): the helpers take the slot as
//! `anytype`, reaching `slot.hib.*` structurally, and `Node` embeds `ActiveSet`
//! + `TenantSlot` embeds `SlotHib`, never the reverse.

const std = @import("std");

const List = std.ArrayListUnmanaged(u64);

/// Per-`TenantSlot` hibernation state — the fields the active-set machine reads
/// and writes on an individual group. Embedded as `TenantSlot.hib`.
pub const SlotHib = struct {
    /// Wall-clock deadline past which this group is considered idle and swept
    /// out of the active tick set. Refreshed by `bumpActive` on every propose +
    /// non-heartbeat inbound step (NOT on heartbeats). 0 = never bumped (a fresh
    /// slot not yet active).
    active_until_ns: i64 = 0,
    /// Dedup bit for `ActiveSet.active` (ticked each pump cycle): lets the
    /// active append happen at most once and the sweep drop it.
    in_active: bool = false,
    /// Pinned ALWAYS-active (never hibernated). The control-plane directory
    /// group sets this: it must keep ticking so a follower runs its election
    /// timer and re-elects on leader death — a directory read never proposes, so
    /// a hibernated directory group would never wake to re-elect. One
    /// always-ticking group is O(1), unlike the K-tenant data groups.
    pinned: bool = false,
    /// Dedup bit for `ActiveSet.dirty` (committed since last durabilize), so
    /// `applyEntry` enqueues the slot at most once.
    in_dirty: bool = false,
    /// Dedup bit for `ActiveSet.persist_ack` (a `processReady` ran whose
    /// buffered writes await the next fsync's `onPersist` ack), so the pump
    /// enqueues the slot at most once per ack round.
    in_persist_ack: bool = false,
    /// The WAL-flusher request seq that covers this group's latest append
    /// (async-fsync mode): `ackCovered` fires `onPersist` only once the
    /// flusher's completed seq reaches it. Re-stamped on every appending
    /// cycle, so an ack can never assert bytes a later append left
    /// un-fsynced. Unused in the inline (test) flush path.
    persist_seq: u64 = 0,
    /// Wall-clock at which this group was first observed leaderless (this node
    /// not the leader AND `leaderId == 0`) while in the active set; 0 while a
    /// leader is known. `escalateLeaderless` arms it and, once the group has
    /// stayed leaderless past `Node.leaderless_escalate_ns`, FORCE-campaigns
    /// (`mgr.campaignForce`) — the TiKV wake-to-elect recovery for a hard
    /// (SIGKILL) leader loss, where a hibernated survivor's normal pre-vote is
    /// ignored by peers still inside their `check_quorum` lease. Reset to `now`
    /// after each force so the escalation re-arms (a cooldown), and to 0 the
    /// moment a leader appears.
    leaderless_since_ns: i64 = 0,
    /// The last non-zero leader id observed for this group while it had one
    /// (this node's own id when it led). Lets `escalateLeaderless` tell a
    /// group that just LOST a live leader (the leaderless-edge worth
    /// forensics — see the log there) from one that was born/woken leaderless.
    /// Cleared once the edge is logged.
    last_seen_leader: u64 = 0,
};

/// The four per-node gid worklists the pump drains each cycle. Embedded as
/// `Node.active_set`; the tuning knobs (`hibernate_ns`, `leaderless_escalate_ns`,
/// `auto_demote_*`) stay on `Node` — they are externally tuned (tests +
/// `rewind-worker` config) and are policy, not this structure's storage.
pub const ActiveSet = struct {
    /// Group ids ticked every pump cycle — the HIBERNATING active set. A group
    /// enters via `bumpActive` (propose / formation / non-heartbeat step) and
    /// leaves when its `active_until_ns` passes (`sweepHibernated`). NOT
    /// pre-seeded with every created group: an idle group is not ticked, so pump
    /// cost is O(active), not O(all groups) — the multiraft-scaling-learnings
    /// §3.1 win at K = thousands.
    active: List = .empty,
    /// Groups whose `processReady` buffered writes this (or a previous) cycle and
    /// now await the post-fsync `mgr.onPersist` ack — the async-append handshake
    /// (raft only counts this node's entries toward the commit quorum once acked,
    /// and the persistence-asserting messages stay stashed until then). Deduped
    /// via `SlotHib.in_persist_ack`; retained across a failed flush so the ack
    /// retries after the next successful one. Pump-thread only.
    persist_ack: List = .empty,
    /// Gids with committed-but-not-yet-durabilized writes (`applied_idx >
    /// durabilized_idx`). Enqueued by `applyEntry`, drained by `durabilizeTick` —
    /// so durabilize cost is O(dirty), not O(all groups). All dirty groups are
    /// durabilized together each tick so the shared WAL can be compacted to a
    /// floor (their commits interleave in the one WAL).
    dirty: List = .empty,
    /// Scratch for draining the transport's woke-group list each pump cycle (the
    /// gids that received a non-heartbeat message → `bumpActive`). Owned; reused
    /// to avoid per-cycle allocation. No dedup bit — cleared every cycle.
    woke_scratch: List = .empty,

    pub fn deinit(self: *ActiveSet, a: std.mem.Allocator) void {
        self.active.deinit(a);
        self.persist_ack.deinit(a);
        self.dirty.deinit(a);
        self.woke_scratch.deinit(a);
    }

    /// THE dedup-append invariant, in one place: append `gid` to `list` and set
    /// the guard bit `in` — but only if the bit is clear, so a gid rides the list
    /// at most once. On allocation failure the bit stays clear (set only after a
    /// successful append), so a retry re-attempts cleanly; the caller decides
    /// whether that failure is fatal (`bumpActive`) or best-effort (`markDirty`).
    fn enqueue(list: *List, in: *bool, gid: u64, a: std.mem.Allocator) error{OutOfMemory}!void {
        if (in.*) return;
        try list.append(a, gid);
        in.* = true;
    }

    /// Add `gid`'s slot to `active`, guarded by `slot.hib.in_active`.
    pub fn addActive(self: *ActiveSet, slot: anytype, gid: u64, a: std.mem.Allocator) error{OutOfMemory}!void {
        return enqueue(&self.active, &slot.hib.in_active, gid, a);
    }

    /// Add `gid`'s slot to `dirty`, guarded by `slot.hib.in_dirty`.
    pub fn addDirty(self: *ActiveSet, slot: anytype, gid: u64, a: std.mem.Allocator) error{OutOfMemory}!void {
        return enqueue(&self.dirty, &slot.hib.in_dirty, gid, a);
    }

    /// Add `gid`'s slot to `persist_ack`, guarded by `slot.hib.in_persist_ack`.
    pub fn addPersistAck(self: *ActiveSet, slot: anytype, gid: u64, a: std.mem.Allocator) error{OutOfMemory}!void {
        return enqueue(&self.persist_ack, &slot.hib.in_persist_ack, gid, a);
    }
};
