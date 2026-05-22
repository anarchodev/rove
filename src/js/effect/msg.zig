//! effect.Msg — Msg-origin vocabulary (`docs/effect-algebra.md` §2.3).
//!
//! Every input to a handler activation IS a Msg. Today's
//! `log_mod.ActivationSource` (10-variant enum at `src/log/root.zig:58`)
//! enumerates the kinds for tape serialization; `effect.Msg` is the
//! in-memory tagged union whose tag IS that enum. The two stay in
//! lockstep — adding a new origin variant means adding to
//! `ActivationSource` (the wire-stable enum used by `LogRecord`) and
//! adding the matching `Msg` variant here.
//!
//! Phase 2A (this file's current scope): declare the union with
//! placeholder payload structs. Per-origin migration PRs (2B–2F) flesh
//! out the variant payloads as each origin moves onto `enqueueMsg`:
//!
//! - 2B: cron / boot   → `SubscriptionFire`
//! - 2C: kv-react      → `SubscriptionFire` (same variant, kv source)
//! - 2D: fetch-chunk   → `FetchChunk` + `FetchDone` + `FetchPipeDone`
//!                       (fetch-A bytes get taped here — closes the
//!                       algebra §7 worklist #1 untaped-chunk bug)
//! - 2E: send-callback → `SendCallback`
//! - 2F: inbound-HTTP  → `Inbound` (last; reference path)
//!
//! L3 (algebra): every Msg is a recorded (taped) input. `enqueueMsg`
//! (in `queue.zig`) is the single tape-emitting ingress; when an origin
//! migrates to it, taping becomes a property of the primitive.
//!
//! **Note (no tape-format change):** the on-disk `LogRecord` continues
//! to carry `ActivationSource` as the activation tag — that wire format
//! is stable. `Msg.kind()` projects to it.

const std = @import("std");
const log_mod = @import("rove-log");

/// The 10-variant activation tag — wire-stable on the tape. The `Msg`
/// union's tag IS this enum.
pub const ActivationSource = log_mod.ActivationSource;

// ── Per-variant payload placeholders ────────────────────────────
//
// Phase 2A declarations: empty `struct {}` so the union is a valid
// tagged union today. Per-origin migration PRs (2B–2F) replace each
// placeholder with the concrete payload that origin currently routes
// through its bespoke enqueue helper (the existing types are listed in
// the doc comment on each placeholder for reference).

/// Inbound HTTP request activation (Phase 2F — the reference path).
/// Today: entity-staged on `h2.request_out` with no Msg per se; the
/// 2F migration adds the variant payload referencing the entity / its
/// request body slice.
pub const Inbound = struct {};

/// `http.send` `on_result` callback (Phase 2E). Today: the
/// `send_dispatch.Completion` thread → `callback_dispatch.zig` path
/// builds the receipt JSON and synthesizes a request — 2E refactors
/// that into a `Msg.send_callback` with the receipt as payload.
pub const SendCallback = struct {};

/// Held-stream timer wake (`streaming-handlers-plan` §4.5). Today:
/// `serviceParkedStreams` sweep detects timer expiry and resumes the
/// stream directly. 2F-equivalent (the streaming origins migrate
/// alongside inbound-HTTP).
pub const Timer = struct {};

/// Held-stream client disconnect (`streaming-handlers-plan` §4.4).
/// Today: h2 detects FIN/RST and `cleanupResponses` fires one final
/// activation. Same migration cluster as Timer / Inbound.
pub const Disconnect = struct {};

/// Legacy single-key kv-wake (pre-§9.4). Today: apply.zig's writeset
/// hook fired per matching put/delete. Retained on the enum so old
/// tapes decode; `wake_batch` is the live shape and is what 2C
/// migrates.
pub const KvWake = struct {};

/// Batched kv-wake (`streaming-handlers-plan` §9.4 + primitive-gaps
/// §2.2). Today: `PendingWakes` ring → temporal-order batch on stream
/// resume. Migrates alongside the streaming origins.
pub const WakeBatch = struct {};

/// Subscription chain origin — cron / kv-react / boot (primitive-gaps
/// §2.1). Today: `enqueueSubscriptionFireForTenant` (cross-thread) →
/// `SubscriptionFireInbox` → drained into `subscription_fire_pending`.
/// Phase 2B (cron + boot) and 2C (kv-react) replace the path with
/// `enqueueMsg(.{ .subscription_fire = ... })`. The variant payload
/// will reference / subsume `worker.SubscriptionFireQueueInput` +
/// `worker.SubscriptionFireSource`.
pub const SubscriptionFire = struct {};

/// `http.fetch` Pattern A `on_chunk` activation (primitive-gaps §2.3).
/// Today: `FetchPool` libcurl → `enqueueFetchEventForTenant` →
/// `FetchChunkInbox` → drained into `fetch_event_pending`. Phase 2D
/// migrates this to `enqueueMsg(.{ .fetch_chunk = ... })` AND tapes
/// the chunk bytes — fixing the algebra §7 worklist #1 untaped-chunk
/// bug. The variant payload will reference / subsume
/// `components.UpstreamFetchEvent` (its chunk-bearing variant).
pub const FetchChunk = struct {};

/// Terminal of a Pattern-A `on_chunk` fetch. Today: same path as
/// `FetchChunk`. Phase 2D migrates alongside it.
pub const FetchDone = struct {};

/// Terminal of a Pattern-B `pipe_to` fetch. Today: same path. Phase 2D
/// migrates alongside the rest. (`pipe_to` itself has no Msg-into-handler
/// for the chunks — it bypasses the handler by design, algebra §3 row
/// "fetch B"; only this terminal is a Msg.)
pub const FetchPipeDone = struct {};

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
    fetch_done: FetchDone,
    fetch_pipe_done: FetchPipeDone,

    /// Project to the tape's wire-stable activation tag.
    pub fn kind(self: Msg) ActivationSource {
        return @as(ActivationSource, self);
    }
};

test "Msg.kind projects to ActivationSource tag" {
    const testing = std.testing;
    const m: Msg = .{ .subscription_fire = .{} };
    try testing.expectEqual(ActivationSource.subscription_fire, m.kind());

    const m2: Msg = .{ .fetch_chunk = .{} };
    try testing.expectEqual(ActivationSource.fetch_chunk, m2.kind());
}

test "Msg covers every ActivationSource variant exhaustively" {
    // Compile-time check: every variant of ActivationSource has a
    // matching Msg variant. If a future PR adds an enum variant
    // without a Msg payload, the `inline for` over the enum fields
    // forces an exhaustive switch and the build fails — the first
    // slice of the §4 six-question contract enforced by the
    // compiler.
    const testing = std.testing;
    inline for (@typeInfo(ActivationSource).@"enum".fields) |f| {
        const tag: ActivationSource = @enumFromInt(f.value);
        const m: Msg = switch (tag) {
            .inbound => .{ .inbound = .{} },
            .send_callback => .{ .send_callback = .{} },
            .timer => .{ .timer = .{} },
            .disconnect => .{ .disconnect = .{} },
            .kv_wake => .{ .kv_wake = .{} },
            .wake_batch => .{ .wake_batch = .{} },
            .subscription_fire => .{ .subscription_fire = .{} },
            .fetch_chunk => .{ .fetch_chunk = .{} },
            .fetch_done => .{ .fetch_done = .{} },
            .fetch_pipe_done => .{ .fetch_pipe_done = .{} },
        };
        try testing.expectEqual(tag, m.kind());
    }
}
