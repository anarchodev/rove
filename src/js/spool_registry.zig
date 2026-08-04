// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `SpoolRegistry` — the bound-fetch / chunk-spool state grouped out of the
//! `Worker` god-struct. Holds the three key-owning hash maps (bound-fetch
//! entity index, per-fetch chunk spools, bound-send entity index), the
//! deferred coordinator-release queue, and the K-window depth + diagnostic
//! peaks. Driven by `worker_streaming.zig`.
//!
//! Its `deinit` frees all three hash maps' allocator-owned keys in ONE place,
//! making the "every key in every map is freed on shutdown" invariant local +
//! auditable (it was three separate blocks interleaved with non-spool teardown
//! in `Worker.deinit`).

const std = @import("std");
const rove = @import("rove");
const blob_mod = @import("rove-blob");
const chunk_spool_mod = @import("chunk_spool.zig");
const msg_router_mod = @import("msg_router.zig");

/// Per-fetch FIFO of relay items drained off the worker's `RelayInbox`
/// (the CAS→connection relay, `docs/architecture/routing-and-ingress.md`)
/// and not yet applied to the held stream. Strictly ordered: byte runs
/// append in arrival order; the terminal event is always last and is
/// re-injected into the normal bound dispatch only once the backlog's
/// bytes are gone. `head` avoids O(n) pop-front; the buffer compacts
/// whenever it fully drains (steady-state: every tick).
pub const RelayBacklog = struct {
    items: std.ArrayListUnmanaged(msg_router_mod.RelayItem) = .empty,
    head: usize = 0,

    pub fn headItem(self: *RelayBacklog) ?*msg_router_mod.RelayItem {
        if (self.head >= self.items.items.len) return null;
        return &self.items.items[self.head];
    }

    /// Pop the head (caller takes ownership). Asserts non-empty.
    pub fn popHead(self: *RelayBacklog) msg_router_mod.RelayItem {
        const item = self.items.items[self.head];
        self.head += 1;
        if (self.head >= self.items.items.len) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        }
        return item;
    }

    pub fn isEmpty(self: *const RelayBacklog) bool {
        return self.head >= self.items.items.len;
    }

    pub fn append(self: *RelayBacklog, allocator: std.mem.Allocator, item: msg_router_mod.RelayItem) !void {
        try self.items.append(allocator, item);
    }

    pub fn deinit(self: *RelayBacklog, allocator: std.mem.Allocator) void {
        for (self.items.items[self.head..]) |*it| it.deinit(allocator);
        self.items.deinit(allocator);
        self.* = .{};
    }
};

/// Default K, the per-fetch RAM window depth (chunks within K of a spool's
/// head keep their inline bytes; deeper chunks evict + read back from the
/// coordinator). Overridable via `ROVE_BOUND_FETCH_SPOOL_DEPTH`.
pub const DEFAULT_BOUND_FETCH_SPOOL_DEPTH: usize = 4;

/// A deferred `coord.release(worker_id, seq)` retried by `drainSpools` until
/// the coordinator's durableSeq advances past it.
pub const CoordPendingRelease = struct { queue_id: blob_mod.coordinator.QueueId, seq: u64 };

pub const SpoolRegistry = struct {
    /// Bound-fetch registry: `fetch_id` → the held chain entity. Keys are
    /// allocator-owned `fetch_id` dupes. Entity handles are stable across
    /// `reg.move` (rove principle #8), so a cont→stream transition keeps the
    /// entry valid.
    bound_fetch_entities: std.StringHashMapUnmanaged(rove.Entity) = .empty,
    /// Per-fetch chunk spool, keyed by `fetch_id` (sibling to
    /// `bound_fetch_entities`). Decouples chunk arrival from the held chain's
    /// raft-commit cadence. Heap-allocated `*ChunkSpool` for pointer stability
    /// across rehash; keys are allocator-owned dupes.
    bound_fetch_spools: std.StringHashMapUnmanaged(*chunk_spool_mod.ChunkSpool) = .empty,
    /// Worker-local mirror of NodeState's `bound_send_owners`: `send_id` → the
    /// parked cont entity, for O(1) resume lookup. Keys allocator-owned.
    bound_send_entities: std.StringHashMapUnmanaged(rove.Entity) = .empty,
    /// Deferred coord releases for consumed/dropped bound chunks; retried by
    /// `drainSpools` each tick. Lossy-on-shutdown. Worker-thread only.
    coord_pending_releases: std.ArrayListUnmanaged(CoordPendingRelease) = .empty,
    /// Per-fetch relay backlogs (the CAS→connection relay), keyed by
    /// `fetch_id` like the two bound-fetch maps above. Heap-allocated for
    /// pointer stability across rehash; keys are allocator-owned dupes.
    /// Driven by `worker_streaming.drainRelay`.
    relay_backlogs: std.StringHashMapUnmanaged(*RelayBacklog) = .empty,
    /// K, the per-fetch RAM window depth.
    bound_fetch_spool_depth: usize = DEFAULT_BOUND_FETCH_SPOOL_DEPTH,
    /// Peak `inlineBytes()` summed across live spools. Diagnostic, never reset.
    bound_fetch_spool_inline_bytes_peak: usize = 0,
    /// Peak total queued entries across live spools — how far the upstream
    /// producer ran ahead of the raft-rate consumer. Never reset.
    bound_fetch_spool_depth_peak: usize = 0,
    /// Count of spool-head chunks whose evicted inline bytes were read back
    /// from the coordinator at dispatch. Never reset.
    bound_fetch_spool_readback_total: u64 = 0,
    /// Count of spooled-but-unconsumed chunks discarded by `dropSpool` on
    /// cancel/disconnect. Never reset.
    bound_fetch_spool_dropped_total: u64 = 0,

    /// Free every allocator-owned key in the three maps + each live spool +
    /// the deferred-release queue. Best-effort drain at shutdown (lossy on
    /// still-queued chunks/releases, same posture as the log flusher).
    pub fn deinit(self: *SpoolRegistry, allocator: std.mem.Allocator) void {
        {
            var it = self.bound_fetch_entities.iterator();
            while (it.next()) |entry| allocator.free(entry.key_ptr.*);
            self.bound_fetch_entities.deinit(allocator);
        }
        {
            var it = self.bound_fetch_spools.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit(allocator);
                allocator.destroy(entry.value_ptr.*);
                allocator.free(entry.key_ptr.*);
            }
            self.bound_fetch_spools.deinit(allocator);
        }
        self.coord_pending_releases.deinit(allocator);
        {
            var it = self.bound_send_entities.iterator();
            while (it.next()) |entry| allocator.free(entry.key_ptr.*);
            self.bound_send_entities.deinit(allocator);
        }
        {
            var it = self.relay_backlogs.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit(allocator);
                allocator.destroy(entry.value_ptr.*);
                allocator.free(entry.key_ptr.*);
            }
            self.relay_backlogs.deinit(allocator);
        }
    }
};

test "RelayBacklog: FIFO order, head compaction, deinit frees the tail" {
    const a = std.testing.allocator;
    var bl: RelayBacklog = .{};
    defer bl.deinit(a);

    try std.testing.expect(bl.isEmpty());
    try bl.append(a, .{
        .fetch_id = try a.dupe(u8, "f1"),
        .payload = .{ .bytes = try a.dupe(u8, "aaaa") },
    });
    try bl.append(a, .{
        .fetch_id = try a.dupe(u8, "f1"),
        .payload = .{ .bytes = try a.dupe(u8, "bb") },
    });
    try std.testing.expect(!bl.isEmpty());

    var first = bl.popHead();
    try std.testing.expectEqualStrings("aaaa", first.payload.bytes);
    first.deinit(a);

    // One item left; popping it compacts the buffer back to empty.
    var second = bl.popHead();
    try std.testing.expectEqualStrings("bb", second.payload.bytes);
    second.deinit(a);
    try std.testing.expect(bl.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), bl.head);
    try std.testing.expectEqual(@as(usize, 0), bl.items.items.len);

    // Leave one item queued — deinit (the defer above) must free it.
    try bl.append(a, .{
        .fetch_id = try a.dupe(u8, "f1"),
        .payload = .{ .bytes = try a.dupe(u8, "leftover") },
    });
}
