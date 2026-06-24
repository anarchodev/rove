//! JS engine version — the replay-critical identity of the interpreter
//! that ran a request (`docs/format-versioning-audit.md` §4).
//!
//! ## Why this exists
//!
//! Tapes are engine-agnostic *data*; the engine is the *interpreter*.
//! Replay must re-run an old request on the *same* JS engine that
//! produced it — an arenajs/quickjs behavior change (a numeric edge,
//! an `Intl` tweak, a bytecode change) would make an old tape diverge
//! under a newer engine. So every request is stamped with the engine
//! version that executed it (into the `LogRecord` + the replicated
//! readset header), and a future replay driver fetches the matching
//! engine WASM by that version (Phase 3, post-GA — deferred until the
//! first semantics-affecting bump, at which point selection stops being
//! a no-op).
//!
//! ## The integer
//!
//! `JS_ENGINE_VERSION` is a small monotonic `u16`, NOT the arenajs
//! commit hash (unwieldy + unordered). Bump it by one whenever we adopt
//! an arenajs build whose *observable semantics or emitted bytecode*
//! could change replay. Pure performance / build-hygiene pin moves do
//! NOT bump it. Keep the version→commit map below current with every
//! bump so an old stamp is forever attributable to a concrete engine.
//!
//! ## Bump SOP (what counts as "semantics-affecting")
//!
//! Bump if the new arenajs pin changes ANY of:
//!   - numeric/string formatting or parsing observable to a handler
//!     (`Number.prototype.toString`, `JSON.stringify` rounding, `Intl`,
//!     `Date` formatting, regex semantics);
//!   - the bytecode the compiler emits for the same source (so cached
//!     bytecode-hash → behavior mapping shifts);
//!   - `Math.random` / PRNG sequence for a given seed, or the per-context
//!     time/random plumbing rove relies on (`JS_SetRandomSeed`,
//!     `JS_SetDateNow`);
//!   - any builtin's result for inputs a handler could feed it.
//! Do NOT bump for: allocator/arena internals, perf, GC, build flags,
//! or changes provably unreachable from handler-observable output.
//!
//! ## version → arenajs commit
//!
//!   1 → arenajs#15e77d1… (the pin at `build.zig.zon` as of the
//!        format-versioning freeze, 2026-06-23). The first and, until a
//!        semantics-affecting bump, only engine version — so replay
//!        engine selection is a no-op today.

/// Current JS engine version. Stamped into every request's `LogRecord`
/// and replicated readset header. See the bump SOP above before changing.
pub const JS_ENGINE_VERSION: u16 = 1;
