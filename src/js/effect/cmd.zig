//! effect.Cmd — Cmd-runtime vocabulary (`docs/effect-algebra.md` §2.4).
//!
//! A `Cmd` is an output the handler emits via its return — a
//! commit-gated, recorded action the engine carries out after the Model
//! write of the same activation commits (L4 — every Cmd is commit-gated).
//! Today these flow through several bespoke side channels:
//!
//!   - kv writes via `BatchSideEffects` (`worker.zig:508`) → writeset
//!   - `http.send` / `http.fetch` via `SendDispatch` / `FetchPool`
//!   - response output via h2 `RespBody` staging + `StreamChunks`
//!   - connection-actor frames — not built (gap 2.5)
//!
//! Phase 4 of `docs/effect-reification-plan.md` introduces `interpretCmd`
//! and folds release of every Cmd onto one path — the
//! `Continuation.buffered` slot released by the reconciler on commit
//! (or discarded on fault).
//!
//! This Phase-1 file declares the union with the §3.2 variant set so
//! Phase 4 has a target type. **No consumer exists yet** — the file
//! is intentionally type-only. The variant payloads for `http_out`,
//! `respond`, and `conn_write` are empty struct placeholders that the
//! later phases fill in from the existing transport-side types.
//!
//! Note: `events.emit` (the §3.2 plan's `emit: EmitEvent` variant) was
//! retired with the platform-managed SSE pipe in streaming-handlers
//! Phase 5 (see `src/loop46/main.zig:1325-1340`). It is NOT a Cmd
//! variant — customers compose SSE on `__rove_stream` + kv-write wakes.

const std = @import("std");
const kv_mod = @import("rove-kv");

/// Output the handler emits to its return.
///
/// Variants mirror `effect-algebra.md §2.4`'s open family of Cmd
/// runtimes. The kv-write variant is the only fully-typed one in
/// Phase 1 — its target IS the Model (L1) and the existing
/// `kv_mod.WriteSet` already is the payload. The other three are
/// payload placeholders that subsequent phases flesh out.
pub const Cmd = union(enum) {
    /// Model-targeted Cmd — writeset of kv ops. The degenerate Cmd
    /// runtime: its target IS the Model (L1). Phase 4's `interpretCmd`
    /// dispatches this to the existing `proposeWriteSet` /
    /// `proposeBatch` path; the buffered slot on `Continuation`
    /// replaces the current `BatchSideEffects` accumulator.
    kv_write: kv_mod.WriteSet,

    /// Outbound HTTP — `http.send` (durable + `on_result`) and
    /// `http.fetch` (transient + chunk / pipe disposition). Phase 5
    /// collapses `SendDispatch` + `FetchPool` into one transport
    /// parameterized by `durable?` + response-disposition; until then
    /// this is a placeholder.
    http_out: HttpOut,

    /// Response output — single-write response body, or stream chunk
    /// on a held response. Phase 4 folds h2 `RespBody` + `StreamChunks`
    /// into one Cmd variant.
    respond: ResponseChunk,

    /// Connection-actor frame write — paired with `inbound_frame` Msg
    /// origin on one `Continuation` (the duplex effect, see
    /// `docs/connection-actor-plan.md`). Not built (gap 2.5); the
    /// variant exists so the union's open family is complete from day
    /// one.
    conn_write: FrameOut,
};

/// Phase 5 fills this in from `send_dispatch.OwnedIntent` +
/// `fetch_pool.PendingFetch`; the unified shape is
/// `(durable?, target, body?, response-disposition)`.
pub const HttpOut = struct {};

/// Phase 4 fills this in from h2 `RespBody` + components.StreamChunks;
/// the unified shape is one Cmd carrying the bytes to ship on the
/// held response.
pub const ResponseChunk = struct {};

/// Connection-actor work fills this in; the unified shape is one Cmd
/// carrying the frame bytes to write to the actor's held connection.
pub const FrameOut = struct {};

test {
    // Compile-only: confirm the union type-checks.
    _ = Cmd;
}
