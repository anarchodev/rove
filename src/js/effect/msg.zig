//! effect.Msg — Msg-origin vocabulary (`docs/effect-algebra.md` §2.3).
//!
//! Every input to a handler activation IS a Msg. Today's
//! `log_mod.ActivationSource` (10-variant enum at `src/log/root.zig:58`)
//! already enumerates the kinds; this module is its canonical
//! single-source-of-truth alias for the `effect/` surface. Phase 2 of
//! `docs/effect-reification-plan.md` widens `Msg` into a tagged union
//! with per-kind payloads (`Request`, `FetchChunk`, `Frame`, …) when
//! origins migrate onto `MsgQueue` + `enqueueMsg`.
//!
//! L3 (algebra): every Msg is a recorded (taped) input. Phase 2's
//! `enqueueMsg` is where taping becomes a property of the primitive,
//! making the fetch-A "chunk bytes untaped" bug (algebra §7 worklist
//! #1) unconstructible.
//!
//! Phase 1 invariant — no behavior change: the underlying enum still
//! lives in `rove-log` (used by `LogRecord`'s on-disk tape format);
//! `effect.Msg` is a thin re-export so dispatch code can speak the
//! algebra's names without disturbing the tape serializer.

const std = @import("std");
const log_mod = @import("rove-log");

/// The 10-variant activation enum currently used across `worker.zig`
/// (`3247`, `3290`, `3333`, `5457`, `6846`) and `LogRecord`. Re-exported
/// here so the engine surface is `effect.ActivationSource`; Phase 2
/// retains this name as a back-compat alias once `Msg` becomes a union.
pub const ActivationSource = log_mod.ActivationSource;

/// Canonical effect-algebra `Msg` name. Currently an alias for the
/// concrete enum so Phase 1 is byte-identical; Phase 2 replaces this
/// with a tagged union whose variants carry their per-kind payloads,
/// at which point every `switch` over `Msg` becomes exhaustive over the
/// union and the §4 six-question contract is compiler-enforced for
/// every new origin.
pub const Msg = ActivationSource;

test {
    // Compile-only: confirm the re-export resolves.
    _ = Msg;
    _ = ActivationSource;
}
