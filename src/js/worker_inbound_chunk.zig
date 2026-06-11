//! Gap 2.4 (`docs/inbound-chunk-plan.md` S2): streaming inbound body →
//! per-chunk `onChunk` activations.
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
//! Ordering / read-your-writes is collection membership: the pump fires
//! chunk K+1 only when the entity is back in `parked_continuations`,
//! which a writing chunk reaches only at raft commit.

const std = @import("std");

/// Per-fire coalesce bound. Queued chunks concatenate into one
/// activation up to this size — fewer activations under backpressure,
/// and each fire's payload stays within the tape's activation_bytes
/// inline cap (256 KB) so replay sees the exact bytes.
pub const MAX_FIRE_BYTES: usize = 256 * 1024;

const Chunk = struct {
    bytes: []u8,
    /// Bytes already consumed into earlier fires (a single push can be
    /// far larger than MAX_FIRE_BYTES — the h2 `.hold` handover at
    /// sink-attach delivers everything buffered so far as ONE push —
    /// so staging slices big chunks instead of firing them whole).
    consumed: usize = 0,
    /// Flow-control window to repay when this chunk's LAST slice
    /// fires. 0 for bytes accepted during the accumulating phase
    /// (pre-repaid).
    repay: u32,
};

pub const Job = struct {
    allocator: std.mem.Allocator,
    /// Two owners: the h2 sink reference and the worker's job map.
    refs: u32 = 2,

    /// Plan body cap — the accumulate→firing switch point.
    cap: u64,

    chunks: std.ArrayListUnmanaged(Chunk) = .empty,
    /// Total bytes accepted from the wire.
    total: u64 = 0,
    /// True once `total` crossed `cap` — per-chunk dispatch mode.
    firing: bool = false,
    eof: bool = false,
    aborted: bool = false,

    /// Dispatch-side bookkeeping (worker thread only).
    next_seq: u32 = 0,
    fired_offset: u64 = 0,
    /// The final (`done = true`) fire has been dispatched.
    final_fired: bool = false,
    /// The first fire was staged through `dispatchOnce` (probe ran).
    first_fired: bool = false,
    /// Probe miss (`no_onchunk`) on a complete ≤cap body: the staged
    /// payload re-dispatches as a classic `.inbound` instead.
    classic_fallback: bool = false,
    /// The job is finished as far as dispatch goes (terminal sent /
    /// 413 / fallback consumed); sink pushes drain to keep the
    /// connection from wedging, nothing fires.
    dead: bool = false,

    /// Staged payload for the CURRENT fire — owned here, borrowed by
    /// the dispatch as `Request.body`; freed when the next stage
    /// replaces it or the job deinits.
    staged: ?[]u8 = null,
    staged_repay: u32 = 0,
    staged_done: bool = false,
    /// False while `staged` awaits its dispatch. A staged fire can be
    /// skipped between staging and dispatch (anchor mismatch, busy
    /// tenant, a transient txn conflict on the resume path) — the next
    /// attempt MUST re-dispatch the same staged payload, never stage
    /// past it (that silently drops bytes while keeping seqs
    /// contiguous — the exact bug the first smoke run caught).
    staged_consumed: bool = true,

    /// Window bytes whose fire resolved but aren't reported to h2 yet.
    unrepaid: u32 = 0,
    /// Accumulator `sinkDrained` hands to h2 (h2 repays exactly this).
    drained_pending: u32 = 0,

    pub fn create(allocator: std.mem.Allocator, cap: u64) error{OutOfMemory}!*Job {
        const self = try allocator.create(Job);
        self.* = .{ .allocator = allocator, .cap = cap };
        return self;
    }

    pub fn unref(self: *Job) void {
        self.refs -= 1;
        if (self.refs > 0) return;
        for (self.chunks.items) |ch| self.allocator.free(ch.bytes);
        self.chunks.deinit(self.allocator);
        if (self.staged) |s| self.allocator.free(s);
        self.allocator.destroy(self);
    }

    /// Mark dispatch-dead: drop queued payloads, pre-repay everything
    /// so the stream can't wedge on a shut window while it closes.
    pub fn kill(self: *Job) void {
        self.dead = true;
        for (self.chunks.items) |ch| {
            self.drained_pending +%= ch.repay;
            self.allocator.free(ch.bytes);
        }
        self.chunks.clearRetainingCapacity();
        self.drained_pending +%= self.unrepaid;
        self.unrepaid = 0;
        if (self.staged) |s| {
            self.drained_pending +%= self.staged_repay;
            self.allocator.free(s);
            self.staged = null;
            self.staged_repay = 0;
        }
    }

    // ── BodySink (h2 poll thread == this worker's thread) ──────────

    pub fn sink(self: *Job) Sink {
        return .{ .ctx = self };
    }

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

    // ── Dispatch-side staging (worker thread) ──────────────────────

    /// A fire is ready: either data is queued, or EOF landed and the
    /// final (`done`) fire hasn't gone out. While accumulating, only
    /// EOF triggers (the single-fire rule); in firing mode any queued
    /// data fires.
    pub fn fireReady(self: *const Job) bool {
        if (self.dead or self.aborted or self.final_fired) return false;
        if (!self.firing) return self.eof;
        return self.chunks.items.len > 0 or self.eof;
    }

    /// Coalesce queued chunks (≤ MAX_FIRE_BYTES) into `staged` and
    /// stamp the per-fire fields. Returns false on OOM. The PRIOR
    /// staged payload (already dispatched — its bytes may have been
    /// borrowed as `Request.body` through the whole activation) is
    /// freed here, not in `fireDispatched`.
    pub fn stageFire(self: *Job) bool {
        // Never stage past an undispatched fire.
        std.debug.assert(self.staged == null or self.staged_consumed);
        if (self.staged) |s| {
            self.allocator.free(s);
            self.staged = null;
        }
        // Plan the take: whole chunks while under the bound, plus a
        // partial slice of the next one if it alone exceeds the
        // remaining budget (the `.hold` handover at sink-attach can be
        // one giant push). A chunk's window repay rides its LAST slice.
        var take_n: usize = 0; // fully-consumed chunks
        var take_bytes: usize = 0;
        var take_repay: u32 = 0;
        var partial: usize = 0; // bytes taken from chunks[take_n]
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
            self.allocator.free(ch.bytes);
        }
        if (partial > 0) {
            const ch = &self.chunks.items[take_n];
            @memcpy(buf[off .. off + partial], ch.bytes[ch.consumed .. ch.consumed + partial]);
            ch.consumed += partial;
        }
        self.chunks.replaceRangeAssumeCapacity(0, take_n, &.{});
        self.staged = buf;
        self.staged_repay = take_repay;
        self.staged_done = self.eof and self.chunks.items.len == 0;
        self.staged_consumed = false;
        return true;
    }

    /// The staged fire was dispatched: advance seq/offset, move its
    /// window repay onto `unrepaid` (reported once the activation
    /// resolves — the pump repays when the entity is parked again).
    /// `staged` is NOT freed here — the payload may still be borrowed
    /// (tape capture, classic fallback); the next `stageFire` or the
    /// job's deinit reclaims it.
    pub fn fireDispatched(self: *Job) void {
        const s = self.staged orelse return;
        if (self.staged_consumed) return; // idempotent
        self.staged_consumed = true;
        self.fired_offset += s.len;
        self.next_seq += 1;
        self.first_fired = true;
        if (self.staged_done) self.final_fired = true;
        self.unrepaid +%= self.staged_repay;
        self.staged_repay = 0;
    }

    /// The prior fire resolved (entity parked again / terminal):
    /// release its window.
    pub fn repayResolved(self: *Job) void {
        self.drained_pending +%= self.unrepaid;
        self.unrepaid = 0;
    }
};

/// The `h2.BodySink`-shaped vtable adapter. Kept separate from h2's
/// type to avoid importing h2 here; `worker.zig` adapts it (the field
/// shapes match `h2.BodySink`).
pub const Sink = struct {
    ctx: *Job,

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

test "job: accumulate → single-fire staging" {
    const a = std.testing.allocator;
    const j = try Job.create(a, 1024);
    defer j.unref(); // worker ref
    defer j.unref(); // sink ref (test holds both)
    j.refs += 0;
    try std.testing.expect(j.sinkPush("hello "));
    try std.testing.expect(j.sinkPush("world"));
    try std.testing.expect(!j.fireReady()); // accumulating, no EOF
    // Accumulating bytes are pre-repaid.
    try std.testing.expectEqual(@as(u32, 11), j.sinkDrained());
    j.sinkFinish();
    try std.testing.expect(j.fireReady());
    try std.testing.expect(j.stageFire());
    try std.testing.expectEqualStrings("hello world", j.staged.?);
    try std.testing.expect(j.staged_done);
    j.fireDispatched();
    try std.testing.expect(j.final_fired);
    try std.testing.expect(!j.fireReady());
    // No firing-mode bytes → nothing to repay.
    j.repayResolved();
    try std.testing.expectEqual(@as(u32, 0), j.sinkDrained());
}

test "job: cap crossover flips to firing with repay-on-resolve" {
    const a = std.testing.allocator;
    const j = try Job.create(a, 8);
    defer j.unref();
    defer j.unref();
    try std.testing.expect(j.sinkPush("12345678")); // == cap: still accumulating
    try std.testing.expect(!j.firing);
    try std.testing.expect(j.sinkPush("9abc")); // crosses cap
    try std.testing.expect(j.firing);
    // Pre-repaid: both pushes were accepted before/at the flip ("9abc"
    // crossed the cap itself, so it was accepted in accumulate mode).
    try std.testing.expectEqual(@as(u32, 12), j.sinkDrained());
    try std.testing.expect(j.sinkPush("tail")); // firing-mode bytes: repay rides the fire
    try std.testing.expectEqual(@as(u32, 0), j.sinkDrained());
    try std.testing.expect(j.fireReady());
    try std.testing.expect(j.stageFire());
    try std.testing.expectEqualStrings("12345678" ++ "9abc" ++ "tail", j.staged.?);
    try std.testing.expect(!j.staged_done); // no EOF yet
    j.fireDispatched();
    try std.testing.expectEqual(@as(u32, 0), j.sinkDrained()); // not yet resolved
    j.repayResolved();
    try std.testing.expectEqual(@as(u32, 4), j.sinkDrained()); // "tail"
    j.sinkFinish();
    try std.testing.expect(j.fireReady()); // empty final fire
    try std.testing.expect(j.stageFire());
    try std.testing.expectEqual(@as(usize, 0), j.staged.?.len);
    try std.testing.expect(j.staged_done);
    j.fireDispatched();
    try std.testing.expect(j.final_fired);
}

test "job: kill drains everything" {
    const a = std.testing.allocator;
    const j = try Job.create(a, 4);
    defer j.unref();
    defer j.unref();
    try std.testing.expect(j.sinkPush("123456")); // crosses cap (accumulate-accepted)
    try std.testing.expect(j.sinkPush("78")); // firing-mode
    _ = j.sinkDrained();
    j.kill();
    try std.testing.expectEqual(@as(u32, 2), j.sinkDrained()); // "78" released
    try std.testing.expect(j.sinkPush("more")); // post-kill pushes pass through
    try std.testing.expectEqual(@as(u32, 4), j.sinkDrained());
    try std.testing.expect(!j.fireReady());
}
