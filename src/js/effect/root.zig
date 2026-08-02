// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! rove-js `effect/` — the four primitives of `docs/effect-algebra.md`
//! as concrete code artifacts, per `docs/architecture/effects-and-handlers.md`.
//!
//! In this model, a named effect (`http.send`, streaming, a
//! subscription) is a *declaration* — one `Cmd` variant, one `Msg`
//! variant, and a transport — with replay, backpressure,
//! durability-gating and failure-discard inherited from the four
//! primitives (the Model, the Continuation, Msg origins, Cmd runtimes).
//!
//! Contents:
//!
//! - `effect.Msg` (`msg.zig`) — Msg-origin tagged union over
//!   `log_mod.ActivationSource`; per-variant payloads for the origins
//!   that route through the Msg queue, empty placeholders for the rest.
//! - `effect.Cmd` (`cmd.zig`) — Cmd-runtime union with the §3.2
//!   variant set, interpreted by `interpretCmd`.
//! - `effect.MsgQueue` + `effect.MsgInbox` + `enqueueMsg` +
//!   `freeOwnedMsg` (`queue.zig`) — in-thread + cross-thread Msg
//!   ingress.
//! - `effect.Continuation` + `Disposition` + `WakeKey`
//!   (`continuation.zig`) — comptime-generic commit-gated parked-unit
//!   primitive over parked sites (ParkedUnit, the three
//!   raft_pending_* siblings, parked_continuations, stream_*). See
//!   the reified primitives in `docs/architecture/effects-and-handlers.md`.

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
pub const reconcile = continuation.reconcile;
pub const SharedTxnPool = continuation.SharedTxnPool;
pub const CommitOutcome = continuation.CommitOutcome;
pub const RollbackOutcome = continuation.RollbackOutcome;

test {
    _ = cmd;
    _ = msg;
    _ = queue;
    _ = continuation;
}
