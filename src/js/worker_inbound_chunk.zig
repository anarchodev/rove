//! Gap 2.4 (`docs/inbound-chunk-plan.md` S2 + the chunk-tape follow-up):
//! streaming inbound body → per-chunk `onChunk` activations.
//!
//! One `Job` per body-carrying request whose module routes to `onChunk`
//! (cache yes/unknown). It is the worker-side `h2.BodySink` consumer —
//! the sibling of `blob_receive.Job`, but SAME-THREAD: the h2 poll loop
//! and the worker dispatch loop are one thread per worker, so the sink
//! callbacks mutate the job directly with no locks and no job thread.
//!
//! Two phases:
//! - **Accumulating** (total ≤ cap): bytes append and are pre-repaid via
//!   `drained()` immediately — the flow-control window stays open and
//!   RAM is bounded by the cap. END_STREAM here ⇒ the single-fire case
//!   (`seq 0, done = true`, whole body).
//! - **Firing** (total crossed the cap): bytes append but are repaid
//!   only as their fire's activation resolves — the client's send rate
//!   throttles to the handler's commit rate (the blob.receive
//!   backpressure story, reused).
//!
//! Fires are PREPARED eagerly (arrival-time slicing into ≤
//! MAX_FIRE_BYTES payloads) so the chunk-tape durability gate pipelines:
//! the pump submits every prepared > inline-threshold payload to the
//! blob coordinator as soon as it exists, and durability resolves WHILE
//! earlier fires execute — the per-fire S3 round-trip amortizes across
//! the queue instead of serializing (the fetch-chunk spool posture).
//!
//! Ordering / read-your-writes is collection membership: the pump fires
//! fire K+1 only when the entity is back in `parked_continuations`,
//! which a writing chunk reaches only at raft commit.

const std = @import("std");

/// Per-fire payload bound. Queued arrivals concatenate/slice into
/// fires up to this size.
pub const MAX_FIRE_BYTES: usize = 256 * 1024;

const Chunk = struct {
    bytes: []u8,
    /// Bytes already consumed into prepared fires (a single push can be
    /// far larger than MAX_FIRE_BYTES — the h2 `.hold` handover at
    /// sink-attach delivers everything buffered so far as ONE push).
    consumed: usize = 0,
    /// Flow-control window to repay when this chunk's LAST slice's
    /// fire resolves. 0 for bytes accepted during the accumulating
    /// phase (pre-repaid).
    repay: u32,
};

/// Durability-park state for one prepared fire's payload (the
/// resume-fire twin of the dispatch body-gate). Payloads ≤ the inline
/// tape threshold skip the park entirely (`.inline_ok`).
pub const CoordState = enum { inline_ok, unsubmitted, pending, resolved, failed };

/// One ready-to-dispatch fire: a sliced payload plus its durability
/// park. Owned by `Job.prepared`.
pub const Prepared = struct {
    bytes: []u8,
    repay: u32 = 0,
    done: bool = false,
    coord: CoordState = .unsubmitted,
    /// Coordinator durability key (valid from `.pending`).
    wid: u8 = 0,
    seq: u64 = 0,
    /// Materialized wire BodyRef (valid when `.resolved`); plain ints
    /// so this file stays import-free.
    batch_id: u64 = 0,
    ref_offset: u64 = 0,
    ref_len: u32 = 0,
};

pub const Job = struct {
    allocator: std.mem.Allocator,
    /// Two owners: the h2 sink reference and the worker's job map.
    refs: u32 = 2,

    /// Plan body cap — the accumulate→firing switch point.
    cap: u64,
    /// Inline tape threshold (REQUEST_BODY_CAP, injected by the worker
    /// layer so this file stays import-free): prepared payloads at or
    /// under it skip the durability park (the raft entry's fsync is
    /// the durability substrate, same as the classic inline path).
    inline_threshold: usize,

    chunks: std.ArrayListUnmanaged(Chunk) = .empty,
    /// Total bytes accepted from the wire.
    total: u64 = 0,
    /// True once `total` crossed `cap` — per-chunk dispatch mode.
    firing: bool = false,
    eof: bool = false,
    aborted: bool = false,

    /// Ready-to-dispatch fires, in order. Head = index 0. The head is
    /// popped only AFTER its dispatch (`fireDispatched`); a
    /// dispatched-but-not-yet-popped head is marked by
    /// `head_dispatched` (its bytes may still be borrowed by tape
    /// capture later in the dispatching walk — `lastFired` retains
    /// them until the NEXT pop).
    prepared: std.ArrayListUnmanaged(Prepared) = .empty,
    head_dispatched: bool = false,
    /// The previously-popped fire — retained one step so borrowed
    /// `Request.body` slices outlive the whole dispatching walk.
    last_fired: ?Prepared = null,

    /// Dispatch-side bookkeeping (worker thread only).
    next_seq: u32 = 0,
    fired_offset: u64 = 0,
    final_fired: bool = false,
    final_prepared: bool = false,
    first_fired: bool = false,
    /// Probe miss (`no_onchunk`) on a complete ≤cap body: the head
    /// payload re-dispatches as a classic `.inbound` instead.
    classic_fallback: bool = false,
    /// Dispatch-dead (terminal sent / 413 / fallback consumed): sink
    /// pushes drain so the closing stream can't wedge; nothing fires.
    dead: bool = false,

    /// Window bytes whose fire resolved but aren't reported to h2 yet.
    unrepaid: u32 = 0,
    /// Accumulator `sinkDrained` hands to h2 (h2 repays exactly this).
    drained_pending: u32 = 0,

    pub fn create(allocator: std.mem.Allocator, cap: u64, inline_threshold: usize) error{OutOfMemory}!*Job {
        const self = try allocator.create(Job);
        self.* = .{ .allocator = allocator, .cap = cap, .inline_threshold = inline_threshold };
        return self;
    }

    pub fn unref(self: *Job) void {
        self.refs -= 1;
        if (self.refs > 0) return;
        for (self.chunks.items) |ch| self.allocator.free(ch.bytes);
        self.chunks.deinit(self.allocator);
        for (self.prepared.items) |p| self.allocator.free(p.bytes);
        self.prepared.deinit(self.allocator);
        if (self.last_fired) |lf| self.allocator.free(lf.bytes);
        self.allocator.destroy(self);
    }

    /// Mark dispatch-dead: drop queued payloads, pre-repay everything
    /// so the stream can't wedge on a shut window while it closes.
    /// The CALLER releases any `.pending` coordinator submissions
    /// first (this file has no coordinator access).
    pub fn kill(self: *Job) void {
        self.dead = true;
        for (self.chunks.items) |ch| {
            self.drained_pending +%= ch.repay;
            self.allocator.free(ch.bytes);
        }
        self.chunks.clearRetainingCapacity();
        for (self.prepared.items) |p| {
            self.drained_pending +%= p.repay;
            self.allocator.free(p.bytes);
        }
        self.prepared.clearRetainingCapacity();
        self.head_dispatched = false;
        self.drained_pending +%= self.unrepaid;
        self.unrepaid = 0;
    }

    // ── BodySink (h2 poll thread == this worker's thread) ──────────

    fn sinkPush(self: *Job, bytes: []const u8) bool {
        if (self.aborted) return false;
        if (self.dead) {
            // Nothing will fire; keep the window open so the close
            // handshake isn't wedged behind un-consumed DATA.
            self.drained_pending +%= @intCast(bytes.len);
            return true;
        }
        const copy = self.allocator.dupe(u8, bytes) catch return false;
        const was_firing = self.firing;
        self.total += bytes.len;
        if (!self.firing and self.total > self.cap) self.firing = true;
        // Bytes accepted while accumulating are pre-repaid (window
        // stays open; RAM bounded by cap). Once firing, repay rides
        // the fire's resolution.
        var repay: u32 = 0;
        if (was_firing) {
            repay = @intCast(bytes.len);
        } else {
            self.drained_pending +%= @intCast(bytes.len);
        }
        self.chunks.append(self.allocator, .{ .bytes = copy, .repay = repay }) catch {
            self.allocator.free(copy);
            return false;
        };
        return true;
    }

    fn sinkFinish(self: *Job) void {
        self.eof = true;
    }

    fn sinkAbort(self: *Job) void {
        self.aborted = true;
    }

    fn sinkDrained(self: *Job) u32 {
        const d = self.drained_pending;
        self.drained_pending = 0;
        return d;
    }

    // ── Dispatch-side fire pipeline (worker thread) ─────────────────

    /// Anything fire-able now or later?
    pub fn fireReady(self: *const Job) bool {
        if (self.dead or self.aborted or self.final_fired) return false;
        if (!self.firing and !self.eof) return false; // accumulating
        return self.prepared.items.len > 0 or self.chunks.items.len > 0 or
            (self.eof and !self.final_prepared);
    }

    /// Arrival-time slicing: drain queued chunk bytes into prepared
    /// fires of ≤ MAX_FIRE_BYTES. Runs every pump tick (and before a
    /// dispatch-walk fire) regardless of in-flight state, so the
    /// durability gate downstream pipelines. While accumulating
    /// (≤ cap, no EOF) nothing is prepared — the single-fire rule.
    /// Returns false only on OOM (retry next tick).
    pub fn prepareFires(self: *Job) bool {
        if (self.dead or self.aborted) return true;
        if (!self.firing and !self.eof) return true; // still accumulating
        while (self.chunks.items.len > 0) {
            // Plan one fire: whole chunks while under the bound, plus
            // a partial slice of an oversized one.
            var take_n: usize = 0;
            var take_bytes: usize = 0;
            var take_repay: u32 = 0;
            var partial: usize = 0;
            for (self.chunks.items) |ch| {
                const remaining = ch.bytes.len - ch.consumed;
                if (take_bytes + remaining > MAX_FIRE_BYTES) {
                    partial = MAX_FIRE_BYTES - take_bytes;
                    take_bytes += partial;
                    break;
                }
                take_n += 1;
                take_bytes += remaining;
                take_repay +%= ch.repay;
            }
            const buf = self.allocator.alloc(u8, take_bytes) catch return false;
            var off: usize = 0;
            for (self.chunks.items[0..take_n]) |ch| {
                const rest = ch.bytes[ch.consumed..];
                @memcpy(buf[off .. off + rest.len], rest);
                off += rest.len;
            }
            if (partial > 0) {
                const ch = &self.chunks.items[take_n];
                @memcpy(buf[off .. off + partial], ch.bytes[ch.consumed .. ch.consumed + partial]);
            }
            self.prepared.append(self.allocator, .{
                .bytes = buf,
                .repay = take_repay,
                .coord = if (take_bytes <= self.inline_threshold) .inline_ok else .unsubmitted,
            }) catch {
                self.allocator.free(buf);
                return false;
            };
            // Commit the consumption only after the append succeeded.
            for (self.chunks.items[0..take_n]) |ch| self.allocator.free(ch.bytes);
            if (partial > 0) self.chunks.items[take_n].consumed += partial;
            self.chunks.replaceRangeAssumeCapacity(0, take_n, &.{});
        }
        // EOF: stamp `done` on the newest prepared fire, or emit the
        // empty final fire if everything already fired/prepared.
        if (self.eof and !self.final_prepared) {
            if (self.prepared.items.len > 0) {
                self.prepared.items[self.prepared.items.len - 1].done = true;
                self.final_prepared = true;
            } else {
                const empty = self.allocator.alloc(u8, 0) catch return false;
                self.prepared.append(self.allocator, .{
                    .bytes = empty,
                    .done = true,
                    .coord = .inline_ok,
                }) catch {
                    self.allocator.free(empty);
                    return false;
                };
                self.final_prepared = true;
            }
        }
        return true;
    }

    /// The head fire, if it exists and hasn't been dispatched.
    pub fn head(self: *Job) ?*Prepared {
        if (self.head_dispatched) return null;
        if (self.prepared.items.len == 0) return null;
        return &self.prepared.items[0];
    }

    /// The head was dispatched: advance seq/offset, move its window
    /// repay onto `unrepaid`, retain its payload one step (borrowed
    /// `Request.body` slices outlive the dispatching walk).
    pub fn fireDispatched(self: *Job) void {
        if (self.head_dispatched) return; // idempotent
        if (self.prepared.items.len == 0) return;
        const h = self.prepared.items[0];
        self.head_dispatched = true;
        self.fired_offset += h.bytes.len;
        self.next_seq += 1;
        self.first_fired = true;
        if (h.done) self.final_fired = true;
        self.unrepaid +%= h.repay;
    }

    /// The dispatched head's activation fully resolved (entity parked
    /// again / terminal): release its window and pop it.
    pub fn repayResolved(self: *Job) void {
        self.drained_pending +%= self.unrepaid;
        self.unrepaid = 0;
        if (self.head_dispatched) {
            if (self.last_fired) |lf| self.allocator.free(lf.bytes);
            self.last_fired = self.prepared.orderedRemove(0);
            self.head_dispatched = false;
        }
    }
};

/// The `h2.BodySink`-shaped vtable adapter (field shapes match
/// `h2.BodySink`; `worker.zig` constructs the real one).
pub const Sink = struct {
    pub fn push(ctx: *anyopaque, bytes: []const u8) bool {
        const self: *Job = @ptrCast(@alignCast(ctx));
        return self.sinkPush(bytes);
    }
    pub fn finish(ctx: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(ctx));
        self.sinkFinish();
    }
    pub fn abort(ctx: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(ctx));
        self.sinkAbort();
    }
    pub fn drained(ctx: *anyopaque) u32 {
        const self: *Job = @ptrCast(@alignCast(ctx));
        return self.sinkDrained();
    }
    pub fn release(ctx: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(ctx));
        self.unref();
    }
};

test "job: accumulate → single-fire prepare" {
    const a = std.testing.allocator;
    const j = try Job.create(a, 1024, 16 * 1024);
    defer j.unref(); // worker ref
    defer j.unref(); // sink ref (test holds both)
    try std.testing.expect(j.sinkPush("hello "));
    try std.testing.expect(j.sinkPush("world"));
    try std.testing.expect(j.prepareFires());
    try std.testing.expect(j.head() == null); // accumulating, no EOF
    try std.testing.expectEqual(@as(u32, 11), j.sinkDrained()); // pre-repaid
    j.sinkFinish();
    try std.testing.expect(j.fireReady());
    try std.testing.expect(j.prepareFires());
    const h = j.head().?;
    try std.testing.expectEqualStrings("hello world", h.bytes);
    try std.testing.expect(h.done);
    try std.testing.expectEqual(CoordState.inline_ok, h.coord);
    j.fireDispatched();
    try std.testing.expect(j.final_fired);
    try std.testing.expect(j.head() == null);
    j.repayResolved();
    try std.testing.expectEqual(@as(u32, 0), j.sinkDrained());
}

test "job: cap crossover pipelines prepared fires with repay-on-resolve" {
    const a = std.testing.allocator;
    const j = try Job.create(a, 8, 4); // inline threshold 4 to exercise .unsubmitted
    defer j.unref();
    defer j.unref();
    try std.testing.expect(j.sinkPush("12345678")); // == cap: accumulating
    try std.testing.expect(!j.firing);
    try std.testing.expect(j.sinkPush("9abc")); // crosses cap
    try std.testing.expect(j.firing);
    try std.testing.expectEqual(@as(u32, 12), j.sinkDrained()); // pre-repaid
    try std.testing.expect(j.sinkPush("tail")); // firing-mode: repay rides the fire
    try std.testing.expect(j.prepareFires());
    // All queued bytes prepare into ONE ≤256K fire, > inline threshold.
    const h = j.head().?;
    try std.testing.expectEqualStrings("12345678" ++ "9abc" ++ "tail", h.bytes);
    try std.testing.expectEqual(CoordState.unsubmitted, h.coord);
    try std.testing.expect(!h.done);
    j.fireDispatched();
    try std.testing.expect(j.head() == null); // dispatched, not popped
    try std.testing.expectEqual(@as(u32, 0), j.sinkDrained());
    // More bytes arrive WHILE the fire is in flight — they prepare
    // immediately (the pipelining property).
    try std.testing.expect(j.sinkPush("more!"));
    try std.testing.expect(j.prepareFires());
    try std.testing.expectEqual(@as(usize, 2), j.prepared.items.len);
    j.repayResolved(); // head resolved → repay "tail", pop
    try std.testing.expectEqual(@as(u32, 4), j.sinkDrained());
    const h2 = j.head().?;
    try std.testing.expectEqualStrings("more!", h2.bytes);
    j.sinkFinish();
    try std.testing.expect(j.prepareFires());
    try std.testing.expect(j.prepared.items[j.prepared.items.len - 1].done);
    j.fireDispatched();
    j.repayResolved();
    try std.testing.expectEqual(@as(u32, 5), j.sinkDrained()); // "more!"
    try std.testing.expect(j.final_fired);
}

test "job: kill drains everything" {
    const a = std.testing.allocator;
    const j = try Job.create(a, 4, 16 * 1024);
    defer j.unref();
    defer j.unref();
    try std.testing.expect(j.sinkPush("123456")); // crosses cap (accumulate-accepted)
    try std.testing.expect(j.sinkPush("78")); // firing-mode
    _ = j.sinkDrained();
    try std.testing.expect(j.prepareFires());
    j.kill();
    try std.testing.expectEqual(@as(u32, 2), j.sinkDrained()); // "78" released
    try std.testing.expect(j.sinkPush("more")); // post-kill pushes pass through
    try std.testing.expectEqual(@as(u32, 4), j.sinkDrained());
    try std.testing.expect(!j.fireReady());
}
