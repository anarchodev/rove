//! rove-js `effect/` — the four primitives of `docs/effect-algebra.md`
//! as concrete code artifacts, per `docs/effect-reification-plan.md`.
//!
//! After full reification, a named effect (`http.send`, streaming, a
//! subscription) becomes a *declaration* — one `Cmd` variant, one `Msg`
//! variant, and a transport — with replay, backpressure,
//! durability-gating and failure-discard inherited from the four
//! primitives (the Model, the Continuation, Msg origins, Cmd runtimes).
//!
//! Phase 1-2 shipped; Phase 3.0 (this PR) lands the Continuation
//! vocabulary. Current contents:
//!
//! - `effect.Msg` (`msg.zig`) — Msg-origin tagged union over the
//!   existing `log_mod.ActivationSource`; per-variant payloads
//!   fleshed for the migrated origins (cron/boot/kv-react → 2B/2C,
//!   outbound HTTP → 2D). Inbound stays a placeholder pending
//!   Phase 3.X.
//! - `effect.Cmd` (`cmd.zig`) — Cmd-runtime union with the §3.2
//!   variant set. Payloads are placeholder structs that Phase 4
//!   (`interpretCmd`) flesh out.
//! - `effect.MsgQueue` + `effect.MsgInbox` + `enqueueMsg` +
//!   `freeOwnedMsg` (`queue.zig`) — in-thread + cross-thread Msg
//!   ingress, Phase 2A-2E.
//! - `effect.Continuation` + `Disposition` + `WakeKey`
//!   (`continuation.zig`) — Phase 3.0: comptime-generic
//!   commit-gated parked-unit primitive. No migration yet; Phases
//!   3.1-3.5 move existing parked sites (ParkedUnit, the three
//!   raft_pending_* siblings, parked_continuations, stream_*) onto
//!   it. See `docs/effect-reification-plan.md` Phase 3 sub-plan.
//!
//! Coming next:
//!
//! - Phase 3.1+: migrate parked sites onto Continuation; H2 reference
//!   path is the dragon (3.2) — byte-identical, gated by perf.
//! - Phase 4: `interpretCmd` + the commit-gated buffer on Continuation;
//!   forces the streaming-pre-commit decision (algebra worklist #2).
//! - Phase 5: delete `SendDispatch` + ship `webhook.send.js` /
//!   `email.send.js` durability-as-JS-shim per
//!   `project_durability_as_js_shim`.

pub const cmd = @import("cmd.zig");
pub const msg = @import("msg.zig");
pub const queue = @import("queue.zig");
pub const continuation = @import("continuation.zig");

pub const Cmd = cmd.Cmd;
pub const Msg = msg.Msg;
pub const ActivationSource = msg.ActivationSource;
pub const MsgQueue = queue.MsgQueue;
pub const MsgInbox = queue.MsgInbox;
pub const enqueueMsg = queue.enqueueMsg;
pub const freeOwnedMsg = queue.freeOwnedMsg;
pub const Continuation = continuation.Continuation;
pub const Disposition = continuation.Disposition;
pub const WakeKey = continuation.WakeKey;
pub const Watermarks = continuation.Watermarks;
pub const SweepClass = continuation.SweepClass;
pub const classify = continuation.classify;
pub const SharedTxnPool = continuation.SharedTxnPool;
pub const CommitOutcome = continuation.CommitOutcome;
pub const RollbackOutcome = continuation.RollbackOutcome;

test {
    _ = cmd;
    _ = msg;
    _ = queue;
    _ = continuation;
}
