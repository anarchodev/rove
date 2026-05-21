//! rove-js per-entity components.
//!
//! These types are the principle-compliant replacement for
//! `worker.parked_meta` / `worker.parked_streams_meta` /
//! `worker.pending_stream_meta` — the three entity-keyed side
//! stores `~/.claude/memory/rove-library.md` principle #2 forbids.
//! Per the refactor plan (`docs/handler-cmds-refactor-plan.md`),
//! they live as components on the entity's Row; rove's auto-deinit
//! on entity-move / entity-destroy handles cleanup structurally
//! instead of via the four manual cleanup sites
//! (`cleanupResponses`, `drainRaftPending` fault branch,
//! `drainOnLeadershipLoss`, `Worker.destroy`) the side-tables
//! require today.
//!
//! Phase 1 of the refactor (the additive dual-write) drops these
//! onto the worker's merged `request_row` so every h2 stream
//! collection + worker `parked_continuations` + `raft_pending`
//! carries them. Non-cont / non-stream entities have all-null /
//! all-default values; nobody reads them on those entities.
//! Phases 2–4 flip readers from the side stores to the components;
//! Phases 5–7 split `raft_pending` into siblings + delete the side
//! stores; Phase 8 collapses the resume engines.

const std = @import("std");
const continuation_mod = @import("bindings/continuation.zig");
const Continuation = continuation_mod.Continuation;

/// Per-chain identity carried by both cont and stream chains. The
/// inbound activation populates it on park; resume activations
/// inherit it via the entity surviving the move (principle #8).
/// Default values are sentinels for "this entity has no chain
/// context yet" — read sites must gate on the entity's collection
/// membership, not on `tenant_id.len > 0`.
pub const ChainContext = struct {
    /// Tenant id the chain is scoped to. Allocator-owned when
    /// `tenant_id.len > 0`; empty slice = uninitialized.
    tenant_id: []u8 = &.{},
    /// Per-chain correlation id. Allocator-owned when non-null.
    correlation_id: ?[]u8 = null,
    /// Deployment id active when the chain opened. Zero ⇒
    /// uninitialized; deployments use the full u64 space so zero
    /// would never be a real value on a populated entity.
    deployment_id: u64 = 0,

    pub fn deinit(allocator: std.mem.Allocator, items: []ChainContext) void {
        for (items) |*item| {
            if (item.tenant_id.len > 0) allocator.free(item.tenant_id);
            if (item.correlation_id) |c| allocator.free(c);
            item.* = .{};
        }
    }
};

/// Cont-trampoline state. Populated only on entities that returned
/// `__rove_next(...)` and are awaiting a wake (either the bound
/// `http.send` completion or the §6.4 deadline). Read sites gate
/// on the entity being in `parked_continuations` /
/// `raft_pending_cont` (Phase 5), not on `cont != null` — the
/// optional just covers "this Row carries the component but THIS
/// entity isn't in a cont chain."
pub const ContDescriptor = struct {
    /// The handler's `__rove_next` descriptor. Null when the
    /// entity has no cont attached.
    cont: ?Continuation = null,
    /// §6.4 mandatory-timeout deadline (absolute monotonic ns).
    /// Zero when `cont == null`.
    deadline_ns: i64 = 0,
    /// §6.4 binding: the single `_send/owed/{id}` this hop wrote
    /// (allocator-owned). null = deadline-only resume (no send
    /// bound, or >1 sends written — ambiguous, no implicit pick).
    bound_schedule_id: ?[]u8 = null,

    pub fn deinit(allocator: std.mem.Allocator, items: []ContDescriptor) void {
        for (items) |*item| {
            if (item.cont) |*c| c.deinit(allocator);
            if (item.bound_schedule_id) |s| allocator.free(s);
            item.* = .{};
        }
    }
};

/// Stream-chain identity + per-activation state. Populated on
/// entities holding an active `__rove_stream(...)` chain (Phase 5
/// targets: `parked_streams_active` / `parked_streams_draining` /
/// `raft_pending_stream`). The module path stays fixed across the
/// chain's lifetime; `ctx_json` is replaced on every
/// `__rove_stream(...)` return.
pub const StreamChain = struct {
    /// Module path the resume engine invokes on each wake.
    /// Allocator-owned when set; empty slice = inactive.
    module_path: []u8 = &.{},
    /// Customer ctx JSON, threaded forward into the next activation's
    /// synthesized request body. Allocator-owned.
    ctx_json: []u8 = &.{},
    /// Number of activations the chain has had so far (inbound + every
    /// wake-driven resume). Hard-capped to `MAX_STREAM_ACTIVATIONS`.
    activation_count: u32 = 0,

    pub fn deinit(allocator: std.mem.Allocator, items: []StreamChain) void {
        for (items) |*item| {
            if (item.module_path.len > 0) allocator.free(item.module_path);
            if (item.ctx_json.len > 0) allocator.free(item.ctx_json);
            item.* = .{};
        }
    }
};

/// Chunk queue waiting to be framed onto the held socket. Drained
/// one entry per worker tick by `serviceParkedStreams`; populated
/// by `__rove_stream(...)` returns. Default empty list is the
/// "no chunks queued" state; nothing distinguishes it from "no
/// stream attached" — that's the collection's job.
///
/// §9.4 write-pressure: a soft byte cap on the queue caps the
/// runtime's memory exposure to a misbehaving handler that returns
/// gigabytes of chunks. On enqueue-overflow the runtime drops the
/// excess (newest-first; the start of the stream is what the
/// customer chose to send earlier) and increments `dropped_chunks`.
/// The next activation reads `request.activation.write_pressure
/// .dropped_chunks`; the runtime resets the counter after surfacing
/// it (one-shot signal per activation).
pub const StreamChunks = struct {
    queue: std.ArrayListUnmanaged([]u8) = .empty,
    /// Running sum of `queue.items[i].len` — kept in lockstep with
    /// the queue so `tryAppend` is O(1).
    queue_bytes: usize = 0,
    /// Cumulative chunks dropped since the last surfacing. Reset
    /// to 0 after the runtime stamps it onto a Request.
    dropped_chunks: u32 = 0,

    /// Soft cap on `queue_bytes`. Conservative default; per-tenant
    /// override hook is cheap to add later. Sized for ~one MTU's
    /// worth of buffered SSE frames plus headroom — heartbeats /
    /// kv-update fanout patterns sit far below this; pathological
    /// returns hit the cap and surface via `dropped_chunks`.
    pub const QUEUE_BYTES_CAP: usize = 256 * 1024;

    /// Enqueue `chunk` (ownership transferred on success). On
    /// cap-overflow: free `chunk` and increment `dropped_chunks`
    /// — §9.4 newest-first drop posture preserves the start of
    /// stream. Returns the standard ArrayList append error only on
    /// allocator failure; cap-overflow is silently surfaced via
    /// the counter, not as an error.
    pub fn tryAppend(self: *StreamChunks, allocator: std.mem.Allocator, chunk: []u8) std.mem.Allocator.Error!void {
        if (self.queue_bytes + chunk.len > QUEUE_BYTES_CAP) {
            allocator.free(chunk);
            self.dropped_chunks +%= 1;
            return;
        }
        self.queue.append(allocator, chunk) catch |e| {
            allocator.free(chunk);
            return e;
        };
        self.queue_bytes += chunk.len;
    }

    /// Pop the oldest queued chunk + decrement `queue_bytes`.
    /// Caller takes ownership. Returns null when the queue is
    /// empty (caller decides what that means — drain-then-close
    /// fires here).
    pub fn popOldest(self: *StreamChunks) ?[]u8 {
        if (self.queue.items.len == 0) return null;
        const chunk = self.queue.orderedRemove(0);
        self.queue_bytes -= chunk.len;
        return chunk;
    }

    /// Snapshot + reset `dropped_chunks`. Called by resume engines
    /// to stamp the count onto the next activation's Request.
    pub fn takeDropped(self: *StreamChunks) u32 {
        const n = self.dropped_chunks;
        self.dropped_chunks = 0;
        return n;
    }

    pub fn deinit(allocator: std.mem.Allocator, items: []StreamChunks) void {
        for (items) |*item| {
            for (item.queue.items) |chunk| allocator.free(chunk);
            item.queue.deinit(allocator);
            item.* = .{};
        }
    }
};

/// Wake registrations + outstanding matches for a held stream. The
/// `kv_prefixes` slice is rewritten on every `__rove_stream(...)`
/// return; `pending_wakes` is the §9.4 accumulator (ring of
/// `PENDING_WAKES_CAP`, fan-in of kv + timer events; `lost_oldest`
/// exposed to the handler as rate-limit backpressure) populated by
/// `drainKvWakeInbox` (kv matches) and the per-tick timer-due
/// detection in `serviceParkedStreams` (timer fires).
/// `next_wake_ns == maxInt(i64)` is the "no timer pending"
/// sentinel; we never compare against it as an active deadline.
pub const StreamWakes = struct {
    interval_ms: i64 = 0,
    next_wake_ns: i64 = std.math.maxInt(i64),
    kv_prefixes: [][]u8 = &.{},
    pending_wakes: PendingWakes = .{},

    pub fn deinit(allocator: std.mem.Allocator, items: []StreamWakes) void {
        for (items) |*item| {
            for (item.kv_prefixes) |p| allocator.free(p);
            if (item.kv_prefixes.len > 0) allocator.free(item.kv_prefixes);
            item.pending_wakes.deinit(allocator);
            item.* = .{};
        }
    }
};

/// Gap 2.1 Phase E (refactored): a pending subscription-fire chain
/// origin awaiting dispatch on the local worker. Entities live in
/// `Worker.subscription_fire_pending`; the
/// `dispatchSubscriptionFires` system iterates that collection on
/// each tick, calls `fireSubscriptionActivation` against the
/// worker's own dispatcher, and `reg.destroy`s the entity (deferred,
/// flushed at boundary). Producers from worker threads (kv-react
/// site in `firePendingKvWakes`) `reg.create` directly; producers
/// from non-worker threads (deployment_loader for boot, cron
/// sweeper for cron) push to a thread-safe NodeState inbox that a
/// worker drains and translates into entities.
///
/// Component shape mirrors `WakeEntry` — tag enum + flat fields per
/// variant — to keep SoA storage cheap (no inline union with
/// padding). `tenant_id`/`module_path`/etc. are allocator-owned
/// when populated; default-init leaves all slices empty so a
/// destroyed-but-recycled entity is benign.
pub const SubscriptionFireDescriptor = struct {
    tenant_id: []u8 = &.{},
    subscription_name: []u8 = &.{},
    module_path: []u8 = &.{},
    source_kind: SourceKind = .cron,
    /// Set when `source_kind == .cron`. Wall-clock ns the cron
    /// match was detected; surfaces as `request.activation.source.firedAt`.
    cron_fired_at_ns: i64 = 0,
    /// Set when `source_kind == .kv`. The key whose write triggered
    /// the fire; allocator-owned when non-empty.
    kv_key: []u8 = &.{},
    /// `'p'` or `'d'`. Meaningful only when `source_kind == .kv`.
    kv_op: u8 = 0,
    /// Set when `source_kind == .boot`. The deployment_id whose
    /// activation triggered the fire (the runtime gates re-fire on
    /// `_boot_fired/<dep_id>` post-fire).
    boot_deployment_id: u64 = 0,
    /// Earned-its-keep field: retry count on transient failures.
    /// V1 doesn't retry; the field is here so adding retry doesn't
    /// re-shape the component.
    retry_count: u8 = 0,

    pub const SourceKind = enum(u8) { cron, kv, boot };

    pub fn deinit(allocator: std.mem.Allocator, items: []SubscriptionFireDescriptor) void {
        for (items) |*item| {
            if (item.tenant_id.len > 0) allocator.free(item.tenant_id);
            if (item.subscription_name.len > 0) allocator.free(item.subscription_name);
            if (item.module_path.len > 0) allocator.free(item.module_path);
            if (item.kv_key.len > 0) allocator.free(item.kv_key);
            item.* = .{};
        }
    }
};

/// Phase 7: replaces the Phase-6 `parked_streams_active` /
/// `parked_streams_draining` map split — the entity stays in h2's
/// `stream_data_out` (h2 owns the chunk-shipping pipeline, so we
/// can't move the entity to a worker-owned sibling collection),
/// and this component encodes "chunks-drain-then-close" instead.
///
/// Caveat (commit message reiterates): this is a bool flag, the
/// strictest reading of rove-library principle #1 would prefer a
/// sibling collection. The architectural constraint (h2 watches
/// its own collections, not the worker's) prevents that without
/// reshaping h2's stream pipeline — out of scope for this
/// refactor. The shift from "side-table map membership"
/// (Phase 6) to "component bool" (Phase 7) is principle-neutral;
/// the real win of this phase is the side-table deletion + the
/// structural deinit (no manual cleanup sites).
pub const StreamDraining = struct {
    is_draining: bool = false,

    pub fn deinit(_: std.mem.Allocator, _: []StreamDraining) void {}
};

/// Ring-buffer capacity for `PendingWakes` (streaming-handlers §9.4 +
/// §11.4 — K=32 starting target). Per-stream constant for now;
/// per-tenant / per-stream configurability hooks are cheap to add
/// later if benches show one stream-class wants a different K.
pub const PENDING_WAKES_CAP: usize = 32;

/// One entry in the per-stream wake accumulator. The tag picks
/// which payload field is meaningful; `kv_key` is allocator-owned
/// when `tag == .kv`. Both kv and timer wakes go through the same
/// ring so the handler sees them in temporal order on each
/// activation (`streaming-handlers-plan.md` §9.4).
pub const WakeEntry = struct {
    tag: Tag = .timer,
    /// Set when `tag == .kv`; allocator-owned. Empty slice when
    /// `tag == .timer` (the default leaves `kv_key.len == 0` so a
    /// drain consumer can branch on `entry.tag` without checking
    /// for sentinel keys).
    kv_key: []u8 = &.{},
    /// Set when `tag == .kv`. `'p'` (put) or `'d'` (delete). Zero
    /// when `tag == .timer`.
    kv_op: u8 = 0,
    /// Set on every entry — monotonic ns the wake matched. For
    /// timers this is the scheduled fire time; for kv-writes it's
    /// the apply-thread observe time. Surfaces to the handler as
    /// `wakes[i].firedAt` so it can order / dedupe across kinds.
    fired_at_ns: i64 = 0,

    pub const Tag = enum(u8) { kv, timer };

    /// Free owned slices. Safe to call on a default-init entry
    /// (`kv_key.len == 0` short-circuits).
    pub fn deinit(self: *WakeEntry, allocator: std.mem.Allocator) void {
        if (self.tag == .kv and self.kv_key.len > 0) {
            allocator.free(self.kv_key);
        }
        self.* = .{};
    }
};

/// The §9.4 per-stream wake accumulator. Bounded ring of
/// `PENDING_WAKES_CAP` entries; pushed-to on every kv-prefix match
/// (apply-thread fan-out) and every timer fire while the handler
/// is running or queued; drained as one batch by `resumeStream`
/// when the cell is free.
///
/// On ring-full, the oldest entry is dropped (its `kv_key` freed)
/// and `lost_oldest` is incremented — the rate-limit IS the ring,
/// and `lost_oldest > 0` is the signal the handler reads on the
/// next activation ("re-snapshot kv state; you missed some
/// writes"). Wraps on u32 overflow which is fine for a counter
/// that resets to 0 on every drain.
///
/// Default-init is the "empty ring" state — `len == 0`,
/// `lost_oldest == 0`, all entries inert. Safe to leave on every
/// `StreamWakes` even when the stream never uses the accumulator
/// (e.g., timer-only streams pay one extra ~1KB SoA slot).
pub const PendingWakes = struct {
    /// Ring storage. Entries between `head` and `head+len` (mod
    /// CAP) are valid; everything else is the default `.{}`.
    entries: [PENDING_WAKES_CAP]WakeEntry = [_]WakeEntry{.{}} ** PENDING_WAKES_CAP,
    /// Index of the oldest valid entry.
    head: u8 = 0,
    /// Number of valid entries currently in the ring (0..=CAP).
    len: u8 = 0,
    /// Cumulative count of entries dropped to make room since the
    /// last drain. Reset to 0 by `drainInto`. Wraps on u32
    /// overflow (saturating not needed — drain frequency caps the
    /// running total).
    lost_oldest: u32 = 0,

    /// Push an entry. On full ring, drop the oldest (freeing its
    /// `kv_key`) + bump `lost_oldest`. Takes ownership of any
    /// allocator-owned fields on `entry`.
    pub fn push(self: *PendingWakes, allocator: std.mem.Allocator, entry: WakeEntry) void {
        if (self.len == PENDING_WAKES_CAP) {
            self.entries[self.head].deinit(allocator);
            self.head = @intCast((@as(usize, self.head) + 1) % PENDING_WAKES_CAP);
            self.lost_oldest +%= 1;
        } else {
            self.len += 1;
        }
        const tail = @as(usize, self.head) + self.len - 1;
        self.entries[tail % PENDING_WAKES_CAP] = entry;
    }

    /// Drain all valid entries into an allocator-owned slice + the
    /// `lost_oldest` snapshot. Resets the ring to empty + clears
    /// `lost_oldest`. Caller owns the returned slice and every
    /// entry's `kv_key`; on success the ring no longer references
    /// them. Returns an empty slice when `len == 0` (still useful
    /// for the `lost_oldest` snapshot — a ring that overflowed
    /// completely and then was drained-but-empty still wants to
    /// report the loss).
    pub fn drainInto(
        self: *PendingWakes,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}!struct { wakes: []WakeEntry, lost_oldest: u32 } {
        const lost = self.lost_oldest;
        self.lost_oldest = 0;
        if (self.len == 0) {
            return .{ .wakes = &.{}, .lost_oldest = lost };
        }
        const out = try allocator.alloc(WakeEntry, self.len);
        var idx: usize = self.head;
        for (out) |*slot| {
            slot.* = self.entries[idx];
            self.entries[idx] = .{}; // ownership moved; clear retained ref
            idx = (idx + 1) % PENDING_WAKES_CAP;
        }
        self.head = 0;
        self.len = 0;
        return .{ .wakes = out, .lost_oldest = lost };
    }

    /// Free every retained entry. Called by `StreamWakes.deinit`.
    pub fn deinit(self: *PendingWakes, allocator: std.mem.Allocator) void {
        var idx: usize = self.head;
        var rem: u8 = self.len;
        while (rem > 0) : (rem -= 1) {
            self.entries[idx].deinit(allocator);
            idx = (idx + 1) % PENDING_WAKES_CAP;
        }
        self.head = 0;
        self.len = 0;
        self.lost_oldest = 0;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "ChainContext default-init is benign + deinit is no-op" {
    var items = [_]ChainContext{ .{}, .{}, .{} };
    ChainContext.deinit(testing.allocator, &items);
    try testing.expectEqualStrings("", items[0].tenant_id);
    try testing.expectEqual(@as(?[]u8, null), items[0].correlation_id);
    try testing.expectEqual(@as(u64, 0), items[0].deployment_id);
}

test "ChainContext deinit frees populated entry" {
    var items = [_]ChainContext{.{
        .tenant_id = try testing.allocator.dupe(u8, "acme"),
        .correlation_id = try testing.allocator.dupe(u8, "0000000000000001"),
        .deployment_id = 12345,
    }};
    ChainContext.deinit(testing.allocator, &items);
    try testing.expectEqualStrings("", items[0].tenant_id);
    try testing.expectEqual(@as(?[]u8, null), items[0].correlation_id);
    try testing.expectEqual(@as(u64, 0), items[0].deployment_id);
}

test "ContDescriptor default-init is benign + deinit is no-op" {
    var items = [_]ContDescriptor{ .{}, .{} };
    ContDescriptor.deinit(testing.allocator, &items);
    try testing.expectEqual(@as(?Continuation, null), items[0].cont);
}

test "ContDescriptor deinit frees the embedded Continuation + bound_schedule_id" {
    var items = [_]ContDescriptor{.{
        .cont = .{
            .path = try testing.allocator.dupe(u8, "feed"),
            .fn_name = null,
            .ctx_json = try testing.allocator.dupe(u8, "{}"),
        },
        .deadline_ns = 1_000_000_000,
        .bound_schedule_id = try testing.allocator.dupe(u8, "send-123"),
    }};
    ContDescriptor.deinit(testing.allocator, &items);
    try testing.expectEqual(@as(?Continuation, null), items[0].cont);
    try testing.expectEqual(@as(?[]u8, null), items[0].bound_schedule_id);
}

test "StreamChain deinit frees module_path + ctx_json" {
    var items = [_]StreamChain{.{
        .module_path = try testing.allocator.dupe(u8, "feed"),
        .ctx_json = try testing.allocator.dupe(u8, "{\"n\":3}"),
        .activation_count = 5,
    }};
    StreamChain.deinit(testing.allocator, &items);
    try testing.expectEqualStrings("", items[0].module_path);
    try testing.expectEqualStrings("", items[0].ctx_json);
}

test "StreamChunks deinit drains + frees every queued chunk" {
    const a = testing.allocator;
    var items = [_]StreamChunks{.{ .queue = .empty }};
    try items[0].queue.append(a, try a.dupe(u8, "frame1"));
    try items[0].queue.append(a, try a.dupe(u8, "frame2"));
    StreamChunks.deinit(a, &items);
    try testing.expectEqual(@as(usize, 0), items[0].queue.items.len);
}

test "StreamChunks.tryAppend tracks bytes; popOldest reverses (Gap 2.2 Phase H)" {
    const a = testing.allocator;
    var sc: StreamChunks = .{};
    defer StreamChunks.deinit(a, (&sc)[0..1]);

    try sc.tryAppend(a, try a.dupe(u8, "abc"));
    try sc.tryAppend(a, try a.dupe(u8, "defghij"));
    try testing.expectEqual(@as(usize, 10), sc.queue_bytes);
    try testing.expectEqual(@as(usize, 2), sc.queue.items.len);

    const c1 = sc.popOldest().?;
    defer a.free(c1);
    try testing.expectEqualStrings("abc", c1);
    try testing.expectEqual(@as(usize, 7), sc.queue_bytes);

    const c2 = sc.popOldest().?;
    defer a.free(c2);
    try testing.expectEqualStrings("defghij", c2);
    try testing.expectEqual(@as(usize, 0), sc.queue_bytes);

    try testing.expectEqual(@as(?[]u8, null), sc.popOldest());
}

test "StreamChunks.tryAppend drops + counts on cap overflow" {
    const a = testing.allocator;
    var sc: StreamChunks = .{};
    defer StreamChunks.deinit(a, (&sc)[0..1]);

    // Fill ~most of the cap with one big chunk.
    const big_len: usize = StreamChunks.QUEUE_BYTES_CAP - 10;
    const big = try a.alloc(u8, big_len);
    @memset(big, 'X');
    try sc.tryAppend(a, big);

    // Small chunk that fits — should succeed.
    try sc.tryAppend(a, try a.dupe(u8, "fits"));
    try testing.expectEqual(@as(u32, 0), sc.dropped_chunks);

    // Chunk that would exceed cap — should drop.
    const overflow = try a.alloc(u8, 100);
    @memset(overflow, 'Y');
    try sc.tryAppend(a, overflow);
    try testing.expectEqual(@as(u32, 1), sc.dropped_chunks);
    try testing.expectEqual(@as(usize, big_len + 4), sc.queue_bytes);
    try testing.expectEqual(@as(usize, 2), sc.queue.items.len);
}

test "StreamChunks.takeDropped snapshots + resets" {
    const a = testing.allocator;
    var sc: StreamChunks = .{};
    defer StreamChunks.deinit(a, (&sc)[0..1]);

    sc.dropped_chunks = 7;
    try testing.expectEqual(@as(u32, 7), sc.takeDropped());
    try testing.expectEqual(@as(u32, 0), sc.dropped_chunks);
    try testing.expectEqual(@as(u32, 0), sc.takeDropped());
}

test "StreamWakes deinit frees kv_prefixes spine + entries" {
    const a = testing.allocator;
    const prefixes = try a.alloc([]u8, 2);
    prefixes[0] = try a.dupe(u8, "orders/");
    prefixes[1] = try a.dupe(u8, "alerts/");
    var items = [_]StreamWakes{.{
        .interval_ms = 200,
        .next_wake_ns = 1_500_000_000,
        .kv_prefixes = prefixes,
    }};
    StreamWakes.deinit(a, &items);
    try testing.expectEqual(@as(usize, 0), items[0].kv_prefixes.len);
}

test "StreamWakes deinit drains the §9.4 PendingWakes ring (Gap 2.2 Phase A)" {
    const a = testing.allocator;
    var items = [_]StreamWakes{.{}};
    items[0].pending_wakes.push(a, .{
        .tag = .kv,
        .kv_key = try a.dupe(u8, "orders/u/12"),
        .kv_op = 'p',
        .fired_at_ns = 100,
    });
    items[0].pending_wakes.push(a, .{
        .tag = .timer,
        .fired_at_ns = 200,
    });
    StreamWakes.deinit(a, &items);
    try testing.expectEqual(@as(u8, 0), items[0].pending_wakes.len);
}

test "PendingWakes push/drain preserves temporal order" {
    const a = testing.allocator;
    var ring: PendingWakes = .{};
    defer ring.deinit(a);

    ring.push(a, .{ .tag = .kv, .kv_key = try a.dupe(u8, "k1"), .kv_op = 'p', .fired_at_ns = 1 });
    ring.push(a, .{ .tag = .timer, .fired_at_ns = 2 });
    ring.push(a, .{ .tag = .kv, .kv_key = try a.dupe(u8, "k2"), .kv_op = 'd', .fired_at_ns = 3 });

    const drained = try ring.drainInto(a);
    defer {
        for (drained.wakes) |*w| w.deinit(a);
        a.free(drained.wakes);
    }
    try testing.expectEqual(@as(usize, 3), drained.wakes.len);
    try testing.expectEqual(@as(u32, 0), drained.lost_oldest);
    try testing.expectEqual(WakeEntry.Tag.kv, drained.wakes[0].tag);
    try testing.expectEqualStrings("k1", drained.wakes[0].kv_key);
    try testing.expectEqual(WakeEntry.Tag.timer, drained.wakes[1].tag);
    try testing.expectEqual(@as(i64, 2), drained.wakes[1].fired_at_ns);
    try testing.expectEqual(WakeEntry.Tag.kv, drained.wakes[2].tag);
    try testing.expectEqualStrings("k2", drained.wakes[2].kv_key);
    try testing.expectEqual(@as(u8, 'd'), drained.wakes[2].kv_op);

    // Ring is empty after drain.
    try testing.expectEqual(@as(u8, 0), ring.len);
    try testing.expectEqual(@as(u32, 0), ring.lost_oldest);
}

test "PendingWakes drops oldest on overflow + counts lost_oldest" {
    const a = testing.allocator;
    var ring: PendingWakes = .{};
    defer ring.deinit(a);

    // Fill ring + push 5 extra; CAP+5 total → oldest 5 dropped.
    var i: usize = 0;
    while (i < PENDING_WAKES_CAP + 5) : (i += 1) {
        const key = try std.fmt.allocPrint(a, "k{d}", .{i});
        ring.push(a, .{ .tag = .kv, .kv_key = key, .kv_op = 'p', .fired_at_ns = @intCast(i) });
    }
    try testing.expectEqual(@as(u8, @intCast(PENDING_WAKES_CAP)), ring.len);
    try testing.expectEqual(@as(u32, 5), ring.lost_oldest);

    const drained = try ring.drainInto(a);
    defer {
        for (drained.wakes) |*w| w.deinit(a);
        a.free(drained.wakes);
    }
    // Oldest surviving entry is k5 (k0..k4 were dropped).
    try testing.expectEqualStrings("k5", drained.wakes[0].kv_key);
    try testing.expectEqual(@as(i64, 5), drained.wakes[0].fired_at_ns);
    // Newest entry is k{CAP+4}.
    var buf: [16]u8 = undefined;
    const expected_last = try std.fmt.bufPrint(&buf, "k{d}", .{PENDING_WAKES_CAP + 4});
    try testing.expectEqualStrings(expected_last, drained.wakes[drained.wakes.len - 1].kv_key);
    try testing.expectEqual(@as(u32, 5), drained.lost_oldest);
}

test "PendingWakes drainInto on empty ring returns empty slice + lost_oldest snapshot" {
    const a = testing.allocator;
    var ring: PendingWakes = .{};
    defer ring.deinit(a);

    // Push a single entry, drain it, then drain again on empty.
    ring.push(a, .{ .tag = .timer, .fired_at_ns = 42 });
    const first = try ring.drainInto(a);
    a.free(first.wakes);

    const second = try ring.drainInto(a);
    try testing.expectEqual(@as(usize, 0), second.wakes.len);
    try testing.expectEqual(@as(u32, 0), second.lost_oldest);
}

test "WakeEntry default-init has empty kv_key + deinit is safe" {
    const a = testing.allocator;
    var entry: WakeEntry = .{};
    entry.deinit(a);
    try testing.expectEqual(@as(usize, 0), entry.kv_key.len);
}

test "SubscriptionFireDescriptor default-init + deinit is benign" {
    const a = testing.allocator;
    var items = [_]SubscriptionFireDescriptor{ .{}, .{} };
    SubscriptionFireDescriptor.deinit(a, &items);
    try testing.expectEqual(@as(usize, 0), items[0].tenant_id.len);
    try testing.expectEqual(@as(usize, 0), items[0].kv_key.len);
}

test "SubscriptionFireDescriptor.deinit frees kv-variant slices" {
    const a = testing.allocator;
    var items = [_]SubscriptionFireDescriptor{.{
        .tenant_id = try a.dupe(u8, "acme"),
        .subscription_name = try a.dupe(u8, "process-jobs"),
        .module_path = try a.dupe(u8, "_subscriptions/process-jobs/index.mjs"),
        .source_kind = .kv,
        .kv_key = try a.dupe(u8, "jobs/42"),
        .kv_op = 'p',
    }};
    SubscriptionFireDescriptor.deinit(a, &items);
    try testing.expectEqual(@as(usize, 0), items[0].tenant_id.len);
    try testing.expectEqual(@as(usize, 0), items[0].kv_key.len);
}

test "SubscriptionFireDescriptor.deinit frees cron-variant (no kv_key)" {
    const a = testing.allocator;
    var items = [_]SubscriptionFireDescriptor{.{
        .tenant_id = try a.dupe(u8, "acme"),
        .subscription_name = try a.dupe(u8, "cleanup"),
        .module_path = try a.dupe(u8, "_subscriptions/cleanup/index.mjs"),
        .source_kind = .cron,
        .cron_fired_at_ns = 1_700_000_000_000_000_000,
    }};
    SubscriptionFireDescriptor.deinit(a, &items);
    try testing.expectEqual(@as(usize, 0), items[0].tenant_id.len);
}

test "SubscriptionFireDescriptor.deinit frees boot-variant" {
    const a = testing.allocator;
    var items = [_]SubscriptionFireDescriptor{.{
        .tenant_id = try a.dupe(u8, "acme"),
        .subscription_name = try a.dupe(u8, "migrate-v3"),
        .module_path = try a.dupe(u8, "_subscriptions/migrate-v3/index.mjs"),
        .source_kind = .boot,
        .boot_deployment_id = 12345,
    }};
    SubscriptionFireDescriptor.deinit(a, &items);
    try testing.expectEqual(@as(usize, 0), items[0].tenant_id.len);
}
