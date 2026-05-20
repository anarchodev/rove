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
pub const StreamChunks = struct {
    queue: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(allocator: std.mem.Allocator, items: []StreamChunks) void {
        for (items) |*item| {
            for (item.queue.items) |chunk| allocator.free(chunk);
            item.queue.deinit(allocator);
            item.* = .{};
        }
    }
};

/// Wake registrations + outstanding match for a held stream. The
/// `kv_prefixes` slice is rewritten on every `__rove_stream(...)`
/// return; `pending_wake` is set by `drainKvWakeInbox` when an
/// apply-thread broadcast matches one of those prefixes.
/// `next_wake_ns == maxInt(i64)` is the "no timer pending"
/// sentinel; we never compare against it as an active deadline.
pub const StreamWakes = struct {
    interval_ms: i64 = 0,
    next_wake_ns: i64 = std.math.maxInt(i64),
    kv_prefixes: [][]u8 = &.{},
    pending_wake: ?PendingKvWake = null,

    pub fn deinit(allocator: std.mem.Allocator, items: []StreamWakes) void {
        for (items) |*item| {
            for (item.kv_prefixes) |p| allocator.free(p);
            if (item.kv_prefixes.len > 0) allocator.free(item.kv_prefixes);
            if (item.pending_wake) |*w| w.deinit(allocator);
            item.* = .{};
        }
    }
};

/// One pending kv-write match destined for the next activation of a
/// streaming chain. Allocator-owned `key`; `op` is `'p'`
/// (put) or `'d'` (delete). v1 keeps "most recent wins" (Phase 3
/// posture); the wake-accumulator §9.4 batching is later.
///
/// Logically a sub-component of `StreamWakes`; broken out as its
/// own type so it can have its own deinit without nesting struct
/// methods.
pub const PendingKvWake = struct {
    key: []u8,
    op: u8,

    pub fn deinit(self: *PendingKvWake, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        self.* = undefined;
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

test "StreamWakes deinit frees kv_prefixes spine + entries + pending_wake key" {
    const a = testing.allocator;
    const prefixes = try a.alloc([]u8, 2);
    prefixes[0] = try a.dupe(u8, "orders/");
    prefixes[1] = try a.dupe(u8, "alerts/");
    var items = [_]StreamWakes{.{
        .interval_ms = 200,
        .next_wake_ns = 1_500_000_000,
        .kv_prefixes = prefixes,
        .pending_wake = .{ .key = try a.dupe(u8, "orders/u/12"), .op = 'p' },
    }};
    StreamWakes.deinit(a, &items);
    try testing.expectEqual(@as(usize, 0), items[0].kv_prefixes.len);
    try testing.expectEqual(@as(?PendingKvWake, null), items[0].pending_wake);
}
