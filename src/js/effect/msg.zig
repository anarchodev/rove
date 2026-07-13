//! effect.Msg — Msg-origin vocabulary (`docs/effect-algebra.md` §2.3).
//!
//! Every input to a handler activation IS a Msg.
//! `log_mod.ActivationSource` (10-variant enum at `src/log/root.zig:58`)
//! enumerates the kinds for tape serialization; `effect.Msg` is the
//! in-memory tagged union whose tag IS that enum. The two stay in
//! lockstep — adding a new origin variant means adding to
//! `ActivationSource` (the wire-stable enum used by `LogRecord`) and
//! adding the matching `Msg` variant here.
//!
//! L3 (algebra): every Msg is a recorded (taped) input. `enqueueMsg`
//! (in `queue.zig`) is the single tape-emitting ingress; an origin that
//! routes through it gets taping as a property of the primitive.
//!
//! **Note (tape format):** the on-disk `LogRecord` carries
//! `ActivationSource` as the activation tag — that wire format is
//! stable. `Msg.kind()` projects to it.

const std = @import("std");
const log_mod = @import("rove-log");
const components_mod = @import("../components.zig");

/// The 10-variant activation tag — wire-stable on the tape. The `Msg`
/// union's tag IS this enum.
pub const ActivationSource = log_mod.ActivationSource;

// ── Per-variant payload placeholders ────────────────────────────
//
// Empty `struct {}` payloads keep the union a valid tagged union for
// origins that don't route a payload through the Msg queue. Origins
// that do enqueue carry a concrete payload; the doc comment on each
// placeholder notes the origin's current shape.

/// Inbound HTTP request activation. **Dispatch stays entity-driven
/// through `h2.request_out` → `worker_dispatch.dispatchOnce`** — the
/// reference path, kept byte-identical (`docs/decisions.md` §3.2).
/// The variant exists for completeness of the Msg union over
/// `ActivationSource` (the compile-time contract — adding an
/// `ActivationSource` entry without a `Msg` variant is a build break,
/// see `Msg` doc). Payload is empty by design: nothing enqueues an
/// `Inbound` Msg.
pub const Inbound = struct {};

/// Chained-dispatch activation — the customer's handler is being
/// invoked as a follow-up via `__rove_next` from another handler.
/// Producers: the `webhook.send.js` shim's onresult handler returns
/// `__rove_next(customer_on_result, {ctx: result})` from a
/// `fetch_chunk` activation; the fetch's `.continuation` arm enqueues
/// one of these.
///
/// The wire-stable enum tag is `.send_callback`, but the activation
/// surface is general — "your handler runs because a previous handler
/// chained to you".
///
/// Customer-facing shape (`fireChainedActivation` surfaces it):
/// `request.activation.kind === "send_callback"`, the cont's
/// `ctx_json` rides as `request.body = {"ctx": <ctx>}` (same shape
/// as fireSubscriptionActivation's body so the customer's
/// JSON.parse pattern is uniform across origin kinds).
pub const SendCallback = struct {
    /// Owning tenant. Allocator-owned when non-empty; freed by
    /// `deinit` on drop / drop-on-shutdown.
    tenant_id: []u8 = &.{},
    /// Module path of the customer's next-hop handler. Allocator-owned.
    module_path: []u8 = &.{},
    /// Cont's `ctx` JSON (the second arg to `__rove_next`).
    /// Allocator-owned; "null" when omitted.
    ctx_json: []u8 = &.{},
    /// Optional named-export selector (the `fn` field on the cont
    /// descriptor). Null = default export.
    fn_name: ?[]u8 = null,
    /// Inherit the originating chain's correlation_id so replay UX
    /// groups the parent fetch + this chained hop. Null = generate
    /// a fresh one at dispatch time.
    correlation_id: ?[]u8 = null,

    pub fn deinit(self: *SendCallback, allocator: std.mem.Allocator) void {
        if (self.tenant_id.len > 0) allocator.free(self.tenant_id);
        if (self.module_path.len > 0) allocator.free(self.module_path);
        if (self.ctx_json.len > 0) allocator.free(self.ctx_json);
        if (self.fn_name) |fn_n| allocator.free(fn_n);
        if (self.correlation_id) |c| allocator.free(c);
        self.* = undefined;
    }
};

/// Held-stream timer wake (`streaming-handlers-plan` §4.5). The
/// `serviceParkedStreams` sweep detects timer expiry and resumes the
/// stream directly.
pub const Timer = struct {};

/// Held-stream client disconnect (`streaming-handlers-plan` §4.4).
/// h2 detects FIN/RST and `cleanupResponses` fires one final
/// activation.
pub const Disconnect = struct {};

/// Inbound WebSocket frame (`docs/architecture/websockets.md`). NOT routed
/// through this Msg queue — `serviceWsMessages` drains the h2
/// `ws_message_out` collection directly each tick and runs `onMessage`
/// in-line. This empty payload exists solely to satisfy the
/// `union(ActivationSource)` exhaustiveness contract (the §4 compiler
/// check below); there is no producer enqueuing `.ws_message` Msgs.
pub const WsMessage = struct {};

/// Single-key kv-wake. Kept on the enum so old tapes decode;
/// `wake_batch` is the live shape.
pub const KvWake = struct {};

/// Batched kv-wake (`streaming-handlers-plan` §9.4 + primitive-gaps
/// §2.2). `PendingWakes` ring → temporal-order batch on stream resume.
pub const WakeBatch = struct {};

/// Subscription chain origin — kv-react (primitive-gaps §2.1;
/// decisions §4.13). Recurrence is a `durable_wake`, not a
/// subscription fire.
pub const SubscriptionFire = struct {};
// ^ Empty placeholder: kv-react rides the durable dirty-marker path
// (write-time `_sub/dirty/{name}` marker → post-commit pending set →
// drainPendingSubscriptionFires), not this queue. The variant stays
// for the Msg-over-ActivationSource exhaustiveness contract (same
// posture as Inbound / Timer / KvWake).

/// `http.fetch` `on_chunk` activation (primitive-gaps §2.3).
/// FetchPool libcurl → `enqueueFetchEventForTenant` → MsgQueue →
/// dispatch fires `on_chunk` activation. The chunk bytes get taped
/// via `TapePayloads.activation_bytes`. One tag covers terminal
/// events too: `UpstreamFetchEvent.final` is `true` on the last event
/// for any fetch and carries the terminal `status` / `ok` /
/// `body_truncated` fields.
pub const FetchChunk = components_mod.UpstreamFetchEvent;

/// Durable scheduled-wake activation (`docs/primitive-gaps.md` §2.6 +
/// `docs/architecture/effects-and-handlers.md`). Produced by the baked
/// `__system/scheduler_tick`'s `__rove_fire_wake` fan-out: one of
/// these per due `_sched/by_time` entry, enqueued for the entry's
/// owning tenant. The dispatch path (`fireDurableWakeActivation`)
/// injects `cleanup_keys` as deletes into the target handler's
/// writeset BEFORE running it, so the entry's removal commits
/// atomically with the handler's effects (exactly-once on the normal
/// path; a crash between fire and commit leaves the keys for a
/// boot/promotion re-fire — the at-least-once *firing* contract).
///
/// Customer-facing shape (`fireDurableWakeActivation` surfaces it):
/// `request.activation = { kind: "durable_wake", id, key,
/// scheduled_at_ns, msg }`, where `msg` is the parsed `msg_json`.
/// Owns its strings; `deinit` is called by `MsgQueue.deinit`
/// (drop-on-shutdown) and by the dispatch path after the fire.
pub const DurableWake = struct {
    /// Owning tenant. Allocator-owned.
    tenant_id: []u8,
    /// Target handler module path (the scheduler entry's `target`),
    /// same shape as `__rove_next` / a subscription module path.
    module_path: []u8,
    /// Stable scheduler id (`base64url(sha256(key))` or a uuid).
    id: []u8,
    /// Idempotency key, or null when `at()` was called without one.
    key: ?[]u8 = null,
    /// The customer `msg`, JSON-serialized ("null" when omitted).
    msg_json: []u8,
    /// Absolute scheduled fire time (ns). Surfaces as
    /// `request.activation.scheduled_at_ns`.
    scheduled_at_ns: i64,
    /// The fired entry's `_sched/` keys (by_id + by_time), deleted in
    /// the dispatched activation's own writeset. The JS lib owns the
    /// key format (`scheduler_tick` passes the exact keys), so the
    /// engine never reconstructs the padded-timestamp shape. Owned
    /// slice of owned slices.
    cleanup_keys: [][]u8,

    pub fn deinit(self: *DurableWake, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.module_path);
        allocator.free(self.id);
        if (self.key) |k| allocator.free(k);
        allocator.free(self.msg_json);
        for (self.cleanup_keys) |k| allocator.free(k);
        allocator.free(self.cleanup_keys);
        self.* = undefined;
    }
};

/// The tagged union over the wire-stable activation tag. The tag IS
/// `ActivationSource` so `@as(ActivationSource, msg)` is the
/// projection to the tape's representation.
pub const Msg = union(ActivationSource) {
    inbound: Inbound,
    send_callback: SendCallback,
    timer: Timer,
    disconnect: Disconnect,
    kv_wake: KvWake,
    wake_batch: WakeBatch,
    subscription_fire: SubscriptionFire,
    fetch_chunk: FetchChunk,
    durable_wake: DurableWake,
    ws_message: WsMessage,
    /// Headers-first inbound (§3.5). Dispatched inline from
    /// `dispatchOnce` (the entity IS the queue position) — nothing
    /// enqueues this variant; it exists because the union is tagged
    /// by the wire enum.
    inbound_headers: Inbound,
    /// Streaming inbound body chunk (gap 2.4). Entity-driven like
    /// `inbound`/`inbound_headers` — the chunk bytes ride the held
    /// entity's component, never this queue; the variant exists
    /// because the union is tagged by the wire enum.
    inbound_chunk: Inbound,

    /// Project to the tape's wire-stable activation tag.
    pub fn kind(self: Msg) ActivationSource {
        return @as(ActivationSource, self);
    }
};

test "Msg.kind projects to ActivationSource tag" {
    const testing = std.testing;
    const m: Msg = .{ .timer = .{} };
    try testing.expectEqual(ActivationSource.timer, m.kind());

    const m2: Msg = .{ .fetch_chunk = .{} };
    try testing.expectEqual(ActivationSource.fetch_chunk, m2.kind());
    // UpstreamFetchEvent's single-event default is `final=false,
    // seq=0` (a non-terminal first chunk).
    try testing.expect(!m2.fetch_chunk.final);
    try testing.expectEqual(@as(u32, 0), m2.fetch_chunk.seq);
}

test "Msg covers every ActivationSource variant exhaustively" {
    // Compile-time check: every variant of ActivationSource has a
    // matching Msg variant. If a future PR adds an enum variant
    // without a Msg payload, the `inline for` over the enum fields
    // forces an exhaustive switch and the build fails — the first
    // slice of the §4 six-question contract enforced by the
    // compiler.
    const testing = std.testing;
    // SendCallback + DurableWake own strings; build/free explicitly
    // so the test exercises the real payload shapes, not placeholders.

    var sc: SendCallback = .{
        .tenant_id = try testing.allocator.dupe(u8, "t"),
        .module_path = try testing.allocator.dupe(u8, "hooks/onDelivered"),
        .ctx_json = try testing.allocator.dupe(u8, "{\"ok\":true}"),
    };
    defer sc.deinit(testing.allocator);

    var dw: DurableWake = .{
        .tenant_id = try testing.allocator.dupe(u8, "t"),
        .module_path = try testing.allocator.dupe(u8, "jobs/reminder"),
        .id = try testing.allocator.dupe(u8, "abc"),
        .key = null,
        .msg_json = try testing.allocator.dupe(u8, "null"),
        .scheduled_at_ns = 0,
        .cleanup_keys = try testing.allocator.alloc([]u8, 0),
    };
    defer dw.deinit(testing.allocator);

    inline for (@typeInfo(ActivationSource).@"enum".fields) |f| {
        const tag: ActivationSource = @enumFromInt(f.value);
        const m: Msg = switch (tag) {
            .inbound => .{ .inbound = .{} },
            .send_callback => .{ .send_callback = sc },
            .timer => .{ .timer = .{} },
            .disconnect => .{ .disconnect = .{} },
            .kv_wake => .{ .kv_wake = .{} },
            .wake_batch => .{ .wake_batch = .{} },
            .subscription_fire => .{ .subscription_fire = .{} },
            .fetch_chunk => .{ .fetch_chunk = .{} },
            .durable_wake => .{ .durable_wake = dw },
            .ws_message => .{ .ws_message = .{} },
            .inbound_headers => .{ .inbound_headers = .{} },
            .inbound_chunk => .{ .inbound_chunk = .{} },
        };
        try testing.expectEqual(tag, m.kind());
    }
}
