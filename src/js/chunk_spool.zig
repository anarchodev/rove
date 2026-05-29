//! `docs/chunk-spool-plan.md` — per-fetch chunk spool.
//!
//! Decouples bound-fetch chunk *arrival* (producer rate, set by the
//! upstream) from chunk *consumption* (the held chain's raft commit
//! cadence). Arriving `UpstreamFetchEvent`s for a bound fetch land in
//! the matching spool; the consumer (`worker_streaming.dispatchSpoolHead`
//! / `drainSpools`) pops the head once the held entity is back in a
//! receivable collection.
//!
//! This file is the platform-internal DATA STRUCTURE only — pure
//! storage with no worker / resume-engine coupling (so it stays free
//! of the comptime Worker type and avoids an import cycle). The
//! push/pop/dispatch/read-back policy lives in `worker_streaming.zig`.
//!
//! Phase 3: a FIFO with a K-deep RAM window. Entries within K of the
//! head keep their inline `bytes`; entries pushed beyond K have their
//! inline bytes evicted (freed) — the coordinator copy
//! (`coord_worker_id`/`coord_seq`, submitted by the producer in Phase
//! 1) is the durable ground truth, and the consumer reads evicted
//! bytes back via `coord.readBody` when the entry finally reaches the
//! head. This bounds the spool's inline RAM at ~K chunks regardless
//! of how far the consumer falls behind the producer.

const std = @import("std");
const components_mod = @import("components.zig");

const UpstreamFetchEvent = components_mod.UpstreamFetchEvent;

/// One spooled chunk. Wraps the carry-through `UpstreamFetchEvent`
/// (which already owns its `bytes`, `fetch_headers`, `name`,
/// `fetch_id`, … and carries the Phase 1 coord pointer) plus the
/// eviction marker.
pub const SpoolEntry = struct {
    event: UpstreamFetchEvent,
    /// True once the inline `event.bytes` have been freed to honour
    /// the K-window (`event.bytes` is then `&.{}`). The bytes are
    /// re-read from the coordinator at dispatch via
    /// `event.coord_worker_id` / `event.coord_seq`. Distinct from an
    /// empty `bytes` slice, which is a legitimate value (e.g. the
    /// final-empty terminal event of a stream) and is never evicted.
    evicted: bool = false,
};

/// Per-fetch FIFO of pending bound-fetch chunk events for one held
/// chain. Heap-allocated and stored as `*ChunkSpool` in the worker's
/// `bound_fetch_spools` map so the pointer stays stable across map
/// rehashes.
pub const ChunkSpool = struct {
    /// Pending chunks ordered by arrival, which equals `seq`
    /// ascending: libcurl delivers a transfer's bytes in order and
    /// the single owner-worker Msg queue preserves that order. Head
    /// is `entries.items[0]` — the next chunk to dispatch. A
    /// dispatched entry's event is consumed (freed) by the resume
    /// engine's `deinitItem`; entries still pending at drop time are
    /// freed by `deinit`.
    entries: std.ArrayListUnmanaged(SpoolEntry) = .empty,

    pub fn isEmpty(self: *const ChunkSpool) bool {
        return self.entries.items.len == 0;
    }

    pub fn len(self: *const ChunkSpool) usize {
        return self.entries.items.len;
    }

    /// Append a chunk to the tail, then enforce the K-deep window:
    /// if the spool now holds more than `window_depth` entries, evict
    /// the just-pushed (tail-most, last-to-be-consumed) entry's inline
    /// bytes — but only when the producer submitted them to the
    /// coordinator (so they can be read back) and the entry isn't the
    /// terminal one (cheaper to keep the final chunk inline). This
    /// keeps the `window_depth` entries nearest the head warm for
    /// fast dispatch while bounding inline RAM.
    ///
    /// On success ownership of `ev`'s slices transfers into the spool;
    /// on error the caller retains ownership and must `deinitItem`.
    pub fn push(
        self: *ChunkSpool,
        allocator: std.mem.Allocator,
        ev: UpstreamFetchEvent,
        window_depth: usize,
    ) !void {
        try self.entries.append(allocator, .{ .event = ev });
        if (self.entries.items.len > window_depth) {
            const last = &self.entries.items[self.entries.items.len - 1];
            if (last.event.coord_submitted and !last.evicted and !last.event.final) {
                if (last.event.bytes.len > 0) allocator.free(last.event.bytes);
                last.event.bytes = &.{};
                last.evicted = true;
            }
        }
    }

    /// Borrow the head entry without removing it. Null when empty.
    pub fn head(self: *ChunkSpool) ?*SpoolEntry {
        if (self.entries.items.len == 0) return null;
        return &self.entries.items[0];
    }

    /// Detach + return the head event, shifting the remaining entries
    /// down. Caller takes ownership of the returned event's slices.
    /// Asserts the spool is non-empty. (The `evicted` flag is dropped
    /// — the caller materializes bytes before calling this.)
    pub fn popHead(self: *ChunkSpool) UpstreamFetchEvent {
        std.debug.assert(self.entries.items.len > 0);
        const entry = self.entries.orderedRemove(0);
        return entry.event;
    }

    /// Sum of inline bytes currently held across all entries — the
    /// spool's live RAM footprint for chunk payloads. Used by the
    /// per-worker spool-RAM metric.
    pub fn inlineBytes(self: *const ChunkSpool) usize {
        var total: usize = 0;
        for (self.entries.items) |*e| {
            if (!e.evicted) total += e.event.bytes.len;
        }
        return total;
    }

    /// Free every still-pending entry + the backing list.
    pub fn deinit(self: *ChunkSpool, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*e| UpstreamFetchEvent.deinitItem(&e.event, allocator);
        self.entries.deinit(allocator);
    }
};

fn makeChunk(a: std.mem.Allocator, seq: u32, submitted: bool) !UpstreamFetchEvent {
    var ev: UpstreamFetchEvent = .{ .seq = seq, .bind = true, .coord_submitted = submitted, .coord_seq = seq };
    ev.fetch_id = try a.dupe(u8, "fid");
    ev.bytes = try a.dupe(u8, "chunk-bytes");
    return ev;
}

test "ChunkSpool push/head/pop FIFO order" {
    const a = std.testing.allocator;
    var sp: ChunkSpool = .{};
    defer sp.deinit(a);

    try std.testing.expect(sp.isEmpty());

    var s: u32 = 0;
    while (s < 3) : (s += 1) {
        try sp.push(a, try makeChunk(a, s, true), 8); // window large → no evict
    }
    try std.testing.expectEqual(@as(usize, 3), sp.len());
    try std.testing.expectEqual(@as(u32, 0), sp.head().?.event.seq);

    var h0 = sp.popHead();
    UpstreamFetchEvent.deinitItem(&h0, a);
    try std.testing.expectEqual(@as(u32, 1), sp.head().?.event.seq);
    try std.testing.expectEqual(@as(usize, 2), sp.len());
}

test "ChunkSpool evicts inline bytes beyond the K-window" {
    const a = std.testing.allocator;
    var sp: ChunkSpool = .{};
    defer sp.deinit(a);

    const K: usize = 2;
    // Push 5 submitted chunks with window depth 2.
    var s: u32 = 0;
    while (s < 5) : (s += 1) {
        try sp.push(a, try makeChunk(a, s, true), K);
    }
    try std.testing.expectEqual(@as(usize, 5), sp.len());

    // Entries 0,1 (nearest head) keep inline bytes; 2,3,4 evicted.
    try std.testing.expect(!sp.entries.items[0].evicted);
    try std.testing.expect(!sp.entries.items[1].evicted);
    try std.testing.expect(sp.entries.items[2].evicted);
    try std.testing.expect(sp.entries.items[3].evicted);
    try std.testing.expect(sp.entries.items[4].evicted);

    // Inline RAM bounded to the 2 in-window chunks.
    try std.testing.expectEqual(@as(usize, 2 * "chunk-bytes".len), sp.inlineBytes());
}

test "ChunkSpool never evicts un-submitted chunks" {
    const a = std.testing.allocator;
    var sp: ChunkSpool = .{};
    defer sp.deinit(a);

    // coord_submitted = false → can't be read back → must stay inline.
    var s: u32 = 0;
    while (s < 4) : (s += 1) {
        try sp.push(a, try makeChunk(a, s, false), 1);
    }
    for (sp.entries.items) |*e| try std.testing.expect(!e.evicted);
    try std.testing.expectEqual(@as(usize, 4 * "chunk-bytes".len), sp.inlineBytes());
}

test "ChunkSpool empty deinit is benign" {
    const a = std.testing.allocator;
    var sp: ChunkSpool = .{};
    try std.testing.expect(sp.isEmpty());
    sp.deinit(a);
}
