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
//! - 2D: fetch-chunk   → `FetchChunk`
//!                       (fetch-A bytes get taped here — closes the
//!                       algebra §7 worklist #1 untaped-chunk bug;
//!                       Phase 5 PR-1 collapsed FetchDone / FetchPipeDone
//!                       into the single FetchChunk variant with a
//!                       `final` flag carrying terminal info)
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
const components_mod = @import("../components.zig");

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

/// Inbound HTTP request activation. **Dispatch stays entity-driven
/// through `h2.request_out` → `worker_dispatch.dispatchOnce`** — the
/// reference path the algebra calls out (`docs/effect-algebra.md` §6
/// rule 1 + `effect-reification-plan.md` invariant 1: H2 stays
/// byte-identical until Phase 3's reconciler is proven). The variant
/// exists for completeness of the Msg union over `ActivationSource`
/// (the compile-time contract — adding an `ActivationSource` entry
/// without a `Msg` variant is a build break, see `Msg` doc).
/// Payload is empty by design today: nothing currently enqueues an
/// `Inbound` Msg. Phase 3 unifies — when h2 entities migrate onto
/// the reconciler, the `Inbound` payload grows the entity handle
/// + request metadata needed for replay-from-MsgQueue.
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
/// Phase 2B migrates the cron + boot drain to push these payloads onto
/// `MsgQueue`; Phase 2C migrates the kv-react direct-enqueue site to
/// the same path. Owns its strings; `deinit` is called by
/// `MsgQueue.deinit` (drop-on-shutdown) and by the dispatch path after
/// the fire completes.
pub const SubscriptionFire = struct {
    /// Source-of-fire discriminant + per-source payload. Mirrors
    /// `worker.SubscriptionFireSource` but lives in the effect module
    /// so the algebra surface doesn't reach back into the dispatch
    /// internals.
    pub const Source = union(enum) {
        cron: struct { fired_at_ns: i64 },
        kv: struct {
            /// Owned by the parent `SubscriptionFire`; freed in `deinit`.
            key: []u8,
            op: u8,
        },
        boot: struct { deployment_id: u64 },
    };

    /// Allocator-owned. The producer dupes onto the message; the
    /// consumer's dispatch path borrows during the fire and the
    /// message's `deinit` frees after.
    tenant_id: []u8,
    subscription_name: []u8,
    module_path: []u8,
    source: Source,

    pub fn deinit(self: *SubscriptionFire, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.subscription_name);
        allocator.free(self.module_path);
        switch (self.source) {
            .kv => |kv_src| if (kv_src.key.len > 0) allocator.free(kv_src.key),
            else => {},
        }
        self.* = undefined;
    }
};

/// `http.fetch` `on_chunk` activation (primitive-gaps §2.3).
/// FetchPool libcurl → `enqueueFetchEventForTenant` → MsgQueue →
/// dispatch fires `on_chunk` activation. The chunk bytes get taped
/// via `TapePayloads.activation_bytes` (closes algebra §7 worklist
/// #1). Phase 5 PR-1 collapsed the prior `FetchDone` / `FetchPipeDone`
/// terminal variants into this single tag: `UpstreamFetchEvent.final`
/// is `true` on the last event for any fetch and carries the
/// terminal `status` / `ok` / `body_truncated` fields.
pub const FetchChunk = components_mod.UpstreamFetchEvent;

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
    // Phase 5 PR-1: UpstreamFetchEvent's `kind` enum collapsed; the
    // single-event default is `final=false, seq=0` (a non-terminal
    // first chunk).
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
    // SubscriptionFire owns strings; build/free explicitly so the
    // test exercises the real payload shape, not a placeholder.
    var sf: SubscriptionFire = .{
        .tenant_id = try testing.allocator.dupe(u8, "t"),
        .subscription_name = try testing.allocator.dupe(u8, "s"),
        .module_path = try testing.allocator.dupe(u8, "m"),
        .source = .{ .cron = .{ .fired_at_ns = 0 } },
    };
    defer sf.deinit(testing.allocator);

    inline for (@typeInfo(ActivationSource).@"enum".fields) |f| {
        const tag: ActivationSource = @enumFromInt(f.value);
        const m: Msg = switch (tag) {
            .inbound => .{ .inbound = .{} },
            .send_callback => .{ .send_callback = .{} },
            .timer => .{ .timer = .{} },
            .disconnect => .{ .disconnect = .{} },
            .kv_wake => .{ .kv_wake = .{} },
            .wake_batch => .{ .wake_batch = .{} },
            .subscription_fire => .{ .subscription_fire = sf },
            .fetch_chunk => .{ .fetch_chunk = .{} },
        };
        try testing.expectEqual(tag, m.kind());
    }
}
