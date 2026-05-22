//! effect.MsgQueue — the single Msg ingress
//! (`docs/effect-algebra.md` §2.3; `docs/effect-reification-plan.md`
//! Phase 2 §3.4).
//!
//! Today every Msg origin has its own bespoke staging area: two rove
//! ECS collections (`subscription_fire_pending`, `fetch_event_pending`)
//! plus two cross-thread inboxes (`SubscriptionFireInbox`,
//! `FetchChunkInbox`) plus the implicit h2 `request_out`. The Phase 2
//! plan §3.4 collapses all of these into **one** ingress so:
//!
//! 1. Backpressure is a property of the primitive (the queue cap).
//! 2. Taping is a property of the primitive — `enqueueMsg` tapes
//!    unconditionally so no Msg can reach a handler without recording
//!    it (algebra L3 — closes worklist #1, the fetch-A untaped-chunk
//!    bug).
//! 3. The dispatch loop is one `for (queue.drain()) |msg| ...` instead
//!    of N per-origin sweeps.
//!
//! Phase 2A (this file's current scope): declare the primitive. **No
//! origin migrates yet.** The tape hook in `enqueueMsg` is a TODO that
//! each per-origin migration PR (2B–2F) wires in for its payload kind
//! (cron / boot / kv-react / fetch / send-callback / inbound).
//!
//! ## Ownership model
//!
//! Phase 2A holds `Msg` values by-value with no allocator-owned
//! fields (the variant payloads are empty placeholders today). When a
//! per-origin migration adds owned fields to its variant payload, that
//! PR is responsible for adding `deinit` discipline so dropped-on-
//! overflow messages free their bytes — `MsgQueue.deinit` must walk
//! the items, the variant must carry an allocator, etc. The pattern
//! to follow is `ParkedUnit.deinit` in `worker.zig:174` (the existing
//! commit-gated unit also lives in a rove collection and owns its
//! send-ops + kv-wakes).
//!
//! ## Backpressure
//!
//! Phase 2A returns `error.Full` on overflow + increments
//! `overflow_count`. Per-origin migration may switch to oldest-drop
//! (the §9.4 wake-ring pattern) for lossy-tolerant origins, or
//! retain blocking semantics — that choice rides with the origin's
//! migration PR.

const std = @import("std");
const msg_mod = @import("msg.zig");

const Msg = msg_mod.Msg;

/// Bounded FIFO of `Msg`s awaiting dispatch into handler activations.
///
/// **One queue per worker thread.** Cross-thread origins (cron / boot
/// / fetch / send-callback today) hash-route to the destination
/// worker's `NodeState` ingress; the destination worker drains its
/// ingress into its `MsgQueue` from its own thread (single-producer
/// for the queue itself, mirroring how
/// `SubscriptionFireInbox.drainInto` works today).
pub const MsgQueue = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Msg) = .empty,
    cap: usize,
    /// Cumulative count of `enqueueMsg` calls that hit the cap and
    /// returned `error.Full`. Per-origin migration surfaces this in
    /// the metrics endpoint the same way `dropped_chunks` /
    /// `lost_oldest` already do for the streaming primitives.
    overflow_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, cap: usize) MsgQueue {
        return .{ .allocator = allocator, .cap = cap };
    }

    pub fn deinit(self: *MsgQueue) void {
        // Variants that own bytes get their deinit called here on
        // drop-on-shutdown. Variants whose payload is by-value (no
        // owned fields) fall through the `else` arm. Add new
        // payload-owning variants to this switch when their
        // per-origin migration lands; the compiler enforces
        // exhaustiveness so a forgotten arm is a build break.
        for (self.items.items) |*m| switch (m.*) {
            .subscription_fire => |*sf| sf.deinit(self.allocator),
            // Phase 2A placeholders: empty payloads, no owned bytes.
            // Phase 2C+ wires kv-react (still .subscription_fire);
            // 2D-2F fill these in with their own deinit.
            .inbound,
            .send_callback,
            .timer,
            .disconnect,
            .kv_wake,
            .wake_batch,
            .fetch_chunk,
            .fetch_done,
            .fetch_pipe_done,
            => {},
        };
        self.items.deinit(self.allocator);
    }

    pub fn len(self: *const MsgQueue) usize {
        return self.items.items.len;
    }

    pub fn isEmpty(self: *const MsgQueue) bool {
        return self.items.items.len == 0;
    }

    /// Pop the front-most Msg. Returns `null` on empty.
    pub fn dequeue(self: *MsgQueue) ?Msg {
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }
};

/// The single Msg ingress.
///
/// **Phase 2 invariant — L3 (algebra):** every Msg is recorded
/// (taped) before it can reach a handler. The tape hook is wired in
/// the per-origin migration PRs (2B–2F) — each one's contract:
/// before `queue.items.append`, tape the payload's recordable bytes
/// (kv keys/values, fetch chunk bytes, callback receipts, …) into
/// the tenant log's `TapePayloads`. When all five origins are
/// migrated, the fetch-A untaped-chunk bug
/// (`docs/effect-algebra.md` §7 worklist #1) is structurally
/// unconstructible because there is no other ingress.
///
/// Phase 2A is the declaration; no origin currently calls this.
pub fn enqueueMsg(queue: *MsgQueue, msg: Msg) !void {
    if (queue.items.items.len >= queue.cap) {
        queue.overflow_count += 1;
        return error.Full;
    }
    // TODO Phase 2B+: tape the payload here, per variant kind. The
    // per-origin migration PR owns the tape integration for its
    // variant. See `effect-reification-plan.md` Phase 2 step list +
    // file-level doc on L3.
    try queue.items.append(queue.allocator, msg);
}

// ── tests ───────────────────────────────────────────────────────

test "MsgQueue: enqueue + dequeue FIFO order" {
    const testing = std.testing;
    var q = MsgQueue.init(testing.allocator, 4);
    defer q.deinit();

    try enqueueMsg(&q, .{ .timer = .{} });
    try enqueueMsg(&q, .{ .fetch_chunk = .{} });
    try enqueueMsg(&q, .{ .send_callback = .{} });
    try testing.expectEqual(@as(usize, 3), q.len());

    try testing.expectEqual(msg_mod.ActivationSource.timer, q.dequeue().?.kind());
    try testing.expectEqual(msg_mod.ActivationSource.fetch_chunk, q.dequeue().?.kind());
    try testing.expectEqual(msg_mod.ActivationSource.send_callback, q.dequeue().?.kind());
    try testing.expectEqual(@as(?Msg, null), q.dequeue());
}

test "MsgQueue: SubscriptionFire payload freed on shutdown deinit" {
    const testing = std.testing;
    var q = MsgQueue.init(testing.allocator, 4);
    // No defer q.deinit() — calling it manually below to exercise
    // the drop-on-shutdown path on a non-empty queue.

    const sf: msg_mod.SubscriptionFire = .{
        .tenant_id = try testing.allocator.dupe(u8, "acme"),
        .subscription_name = try testing.allocator.dupe(u8, "cron-sub"),
        .module_path = try testing.allocator.dupe(u8, "_subscriptions/cron-sub/index.mjs"),
        .source = .{ .cron = .{ .fired_at_ns = 42 } },
    };
    try enqueueMsg(&q, .{ .subscription_fire = sf });
    try testing.expectEqual(@as(usize, 1), q.len());

    // deinit must free the SubscriptionFire's owned strings — the
    // testing allocator panics on leak if the variant-deinit arm is
    // missed.
    q.deinit();
}

test "MsgQueue: backpressure — error.Full + overflow_count increments" {
    const testing = std.testing;
    var q = MsgQueue.init(testing.allocator, 2);
    defer q.deinit();

    try enqueueMsg(&q, .{ .timer = .{} });
    try enqueueMsg(&q, .{ .timer = .{} });

    // At cap: next enqueue must fail loud + bump the counter.
    try testing.expectError(error.Full, enqueueMsg(&q, .{ .timer = .{} }));
    try testing.expectEqual(@as(u64, 1), q.overflow_count);

    try testing.expectError(error.Full, enqueueMsg(&q, .{ .timer = .{} }));
    try testing.expectEqual(@as(u64, 2), q.overflow_count);

    // After a dequeue makes room, enqueue succeeds again.
    _ = q.dequeue();
    try enqueueMsg(&q, .{ .disconnect = .{} });
    try testing.expectEqual(@as(usize, 2), q.len());
}

test "MsgQueue: isEmpty + dequeue on empty" {
    const testing = std.testing;
    var q = MsgQueue.init(testing.allocator, 4);
    defer q.deinit();

    try testing.expect(q.isEmpty());
    try testing.expectEqual(@as(?Msg, null), q.dequeue());
    try enqueueMsg(&q, .{ .inbound = .{} });
    try testing.expect(!q.isEmpty());
}
