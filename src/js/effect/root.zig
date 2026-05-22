//! rove-js `effect/` — the four primitives of `docs/effect-algebra.md`
//! as concrete code artifacts, per `docs/effect-reification-plan.md`.
//!
//! After full reification, a named effect (`http.send`, streaming, a
//! subscription) becomes a *declaration* — one `Cmd` variant, one `Msg`
//! variant, and a transport — with replay, backpressure,
//! durability-gating and failure-discard inherited from the four
//! primitives (the Model, the Continuation, Msg origins, Cmd runtimes).
//!
//! Phase 1 (this directory's current scope): **the two vocabularies.**
//!
//! - `effect.Msg`  — Msg-origin tag (§2.3); aliases the existing
//!                   `log_mod.ActivationSource` until Phase 2 widens it
//!                   to a payload-carrying tagged union.
//! - `effect.Cmd`  — Cmd-runtime tag (§2.4); declared with the §3.2
//!                   variant set so Phase 4's `interpretCmd` has a
//!                   target type. No consumer exists yet — the file is
//!                   intentionally type-only.
//!
//! Phase 1 is mechanical consolidation only — no behavior change, no
//! call-site migration. Subsequent phases land in this directory:
//!
//! - Phase 2: `msg.zig` grows `MsgQueue` + `enqueueMsg`; per-origin PRs
//!   migrate `subscription_fire_pending`, `fetch_event_pending`, the
//!   cross-thread `SubscriptionFireInbox` + `FetchChunkInbox` onto one
//!   ingress with taping built in.
//! - Phase 3: `continuation.zig` lands with `Continuation` Row +
//!   `reconcile` system, generalizing today's `ParkedUnit` +
//!   `drainRaftPending` (the dragon — H2-reference-first).
//! - Phase 4: `cmd.zig` grows `interpretCmd`; the effect buffer moves
//!   onto `Continuation`; release becomes commit-gated by construction.
//! - Phase 5: `SendDispatch` + `FetchPool` shrink to transport only;
//!   `http.send` + `http.fetch` unify into one Cmd variant.

pub const cmd = @import("cmd.zig");
pub const msg = @import("msg.zig");

pub const Cmd = cmd.Cmd;
pub const Msg = msg.Msg;
pub const ActivationSource = msg.ActivationSource;

test {
    _ = cmd;
    _ = msg;
}
