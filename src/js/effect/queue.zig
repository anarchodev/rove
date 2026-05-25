//! effect.MsgQueue — the single Msg ingress
//! (`docs/effect-algebra.md` §2.3; `docs/effect-reification-plan.md`
//! Phase 2 §3.4).
//!
//! The pre-Phase-2 world had each origin staging into its own area:
//! two rove collections (`subscription_fire_pending`,
//! `fetch_event_pending`) plus two cross-thread inboxes
//! (`SubscriptionFireInbox`, `FetchChunkInbox`) plus the implicit h2
//! `request_out`. Phase 2 collapses them into **one** in-thread
//! ingress (`MsgQueue`) fed from one cross-thread inbox (`MsgInbox`)
//! per worker so:
//!
//! 1. Backpressure is a property of the primitive (the queue cap;
//!    `error.Full` + `overflow_count` on overflow, surfaced on
//!    `/_system/metrics` the same way `dropped_chunks` /
//!    `lost_oldest` already are).
//! 2. The dispatch loop is one `for (queue.drain()) |msg| ...`
//!    instead of N per-origin sweeps.
//!
//! Migrated origins today: `subscription_fire` (kv-react / cron /
//! boot — `worker_streaming.zig`), `fetch_chunk`, `send_callback`.
//! `inbound` stays entity-driven through H2 (Phase 3's reconciler
//! scope) — it has a Msg variant for type-system parity but no
//! `enqueueMsg` path. `timer` / `disconnect` / `kv_wake` /
//! `wake_batch` are dispatcher-internal control variants with no
//! owned bytes (see `freeOwnedMsg` below).
//!
//! ## Taping
//!
//! Algebra L3 ("every Msg is a recorded input") is satisfied by
//! per-dispatch-site taping via `captureTapesForChain*` — the
//! existing inbound-HTTP tape mechanism (kv/date/random/module
//! channels plus activation_bytes for chunk variants). The
//! pre-handler hook contemplated in early drafts wasn't needed:
//! post-handler taping records the same bytes the handler observed
//! and meets the audit's "taped per fire" check
//! (`docs/effect-algebra.md` §5).
//!
//! ## Ownership model
//!
//! Variants that own allocator-backed bytes (`subscription_fire`,
//! `fetch_chunk`, `send_callback`) carry their own `deinit` (called
//! by `freeOwnedMsg` on drop-on-shutdown / overflow-drop). Adding a
//! new payload-owning variant requires an arm in `freeOwnedMsg`
//! (compile-time exhaustive) — the testing allocator's leak
//! detection in `MsgQueue: SubscriptionFire payload freed on
//! shutdown deinit` catches a missed arm.

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
        .fetch_chunk => |*ev| components_mod.UpstreamFetchEvent.deinitItem(ev, allocator),
        .send_callback => |*sc| sc.deinit(allocator),
        // No-owned-bytes variants. Phase 2E declares an Inbound
        // payload as a placeholder; dispatch for inbound stays
        // entity-driven through H2 (Phase 3's reconciler scope),
        // so no enqueueMsg path exists for it yet.
        .inbound,
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

/// The single in-thread Msg ingress. **L3 (algebra)** is satisfied
/// by per-dispatch-site taping (`captureTapesForChain*`) — see the
/// top-of-file Taping section.
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
