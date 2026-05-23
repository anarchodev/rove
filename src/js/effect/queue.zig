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
const components_mod = @import("../components.zig");

const Msg = msg_mod.Msg;

/// Per-variant Msg deinit. Called on drop-on-shutdown
/// (`MsgQueue.deinit` / `MsgInbox.deinit`) and on
/// overflow-drop in `enqueueMsg`. Variants that own bytes call
/// their own deinit; variants whose payload is by-value (no
/// owned fields) fall through. Compile-time exhaustive — adding a
/// payload-owning variant without an arm here is a build break.
pub fn freeOwnedMsg(allocator: std.mem.Allocator, msg: *Msg) void {
    switch (msg.*) {
        .subscription_fire => |*sf| sf.deinit(allocator),
        .fetch_chunk, .fetch_done, .fetch_pipe_done => |*ev| {
            components_mod.UpstreamFetchEvent.deinitItem(ev, allocator);
        },
        // No-owned-bytes variants. Phase 2E declares an Inbound
        // payload as a placeholder; dispatch for inbound stays
        // entity-driven through H2 (Phase 3's reconciler scope),
        // so no enqueueMsg path exists for it yet.
        .inbound,
        .send_callback,
        .timer,
        .disconnect,
        .kv_wake,
        .wake_batch,
        => {},
    }
}

/// Bounded FIFO of `Msg`s awaiting dispatch into handler activations.
///
/// **One queue per worker thread.** Cross-thread origins (cron / boot
/// / fetch today) push to the destination worker's `MsgInbox` (below);
/// the worker drains the inbox into this queue from its own thread.
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
        for (self.items.items) |*m| freeOwnedMsg(self.allocator, m);
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

/// The single in-thread Msg ingress.
///
/// **L3 (algebra):** every Msg is recorded (taped). Phase 2A-2D's
/// pragmatic decision: each per-origin migration tapes at the
/// dispatch site via `captureTapesForChain*` (the existing inbound-
/// HTTP tape mechanism — kv/date/random/module channels plus
/// activation_bytes for chunk variants in 2D). The pre-handler
/// hook contemplated in earlier drafts was not needed — post-handler
/// taping records the same bytes the handler observed and meets the
/// audit's "taped per fire" check (`docs/effect-algebra.md` §5).
///
/// On `error.Full` the caller owns the Msg and must `freeOwnedMsg`
/// it (variant-aware free).
pub fn enqueueMsg(queue: *MsgQueue, msg: Msg) !void {
    if (queue.items.items.len >= queue.cap) {
        queue.overflow_count += 1;
        return error.Full;
    }
    try queue.items.append(queue.allocator, msg);
}

/// Cross-thread Msg ingress. **One per worker thread.** Producers
/// (cron sweeper, deployment-loader boot, the FetchPool libcurl
/// threads) push from off-worker threads; the owning worker calls
/// `drainInto` on its tick (mutex held only across the move).
///
/// Effect-reification Phase 2E: collapses the two pre-2E inboxes
/// (`SubscriptionFireInbox` + `FetchChunkInbox`) into one. Hash-
/// routing by `tenant_id` happens on the NodeState registry side
/// (see `NodeState.enqueueMsgForTenant`); this struct is the
/// per-worker mailbox the registry routes into.
///
/// Cross-thread ownership: `push` takes the Msg with already-owned
/// payload slices. On `drainInto`, ownership transfers to the
/// caller (the worker's local list; from there each Msg moves onto
/// the in-thread `MsgQueue` via `enqueueMsg`).
pub const MsgInbox = struct {
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayListUnmanaged(Msg) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MsgInbox {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MsgInbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |*m| freeOwnedMsg(self.allocator, m);
        self.items.deinit(self.allocator);
    }

    pub fn push(self: *MsgInbox, msg: Msg) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(self.allocator, msg);
    }

    /// Move all queued Msgs into the caller's local list. Inbox is
    /// empty after the call; caller owns each Msg (variant-aware
    /// `freeOwnedMsg` on drop, or moves into the in-thread MsgQueue).
    pub fn drainInto(self: *MsgInbox, out: *std.ArrayListUnmanaged(Msg)) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.items.items.len == 0) return;
        try out.appendSlice(self.allocator, self.items.items);
        self.items.clearRetainingCapacity();
    }
};

// ── tests ───────────────────────────────────────────────────────

test "MsgInbox: push from one thread + drainInto on another" {
    const testing = std.testing;
    var inbox = MsgInbox.init(testing.allocator);
    defer inbox.deinit();

    try inbox.push(.{ .timer = .{} });
    try inbox.push(.{ .disconnect = .{} });

    var local: std.ArrayListUnmanaged(Msg) = .empty;
    defer local.deinit(testing.allocator);
    try inbox.drainInto(&local);
    try testing.expectEqual(@as(usize, 2), local.items.len);
    try testing.expectEqual(msg_mod.ActivationSource.timer, local.items[0].kind());
    try testing.expectEqual(msg_mod.ActivationSource.disconnect, local.items[1].kind());

    // Inbox is now empty.
    var empty: std.ArrayListUnmanaged(Msg) = .empty;
    defer empty.deinit(testing.allocator);
    try inbox.drainInto(&empty);
    try testing.expectEqual(@as(usize, 0), empty.items.len);
}

test "MsgInbox: deinit on non-empty walks variant-aware free" {
    const testing = std.testing;
    var inbox = MsgInbox.init(testing.allocator);

    const sf: msg_mod.SubscriptionFire = .{
        .tenant_id = try testing.allocator.dupe(u8, "t"),
        .subscription_name = try testing.allocator.dupe(u8, "s"),
        .module_path = try testing.allocator.dupe(u8, "m"),
        .source = .{ .cron = .{ .fired_at_ns = 1 } },
    };
    try inbox.push(.{ .subscription_fire = sf });
    // No drain: deinit walks the items and calls freeOwnedMsg —
    // the testing allocator surfaces a leak if the SubscriptionFire
    // arm is missed.
    inbox.deinit();
}

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
