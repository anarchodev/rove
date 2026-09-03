// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Held requests — a handler that returned to the host with a promise
//! pending on a host operation (`await after.ms(...)`), its request
//! arena kept alive across activations and re-entered when the
//! operation completes (arenajs requests-as-objects, `qjs.snap`).
//!
//! The scope line is the effect algebra's: only SAME-CONNECTION wakes
//! are promises (`docs/effect-algebra.md`, the current-connection vs
//! connectionless axis) — a connectionless callback may fire after the
//! connection, node, or process is gone, so it stays a named export.
//!
//! Nothing here changes durability: a resume is an activation like any
//! other, its writes go through the same txn and its Cmds wait for the
//! same commit. What changes is the dispatch TARGET (settle a promise
//! in a kept arena instead of re-invoking an export with a threaded
//! ctx) and the arena's LIFETIME (the entity's `HeldRequest` component
//! frees it when the entity releases).
//!
//! Values never cross requests: every `JSValue` below lives in the held
//! request's memory and is dereferenced only while that request is
//! entered, never after its arena is freed.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;
const log_mod = @import("rove-log");

/// A promise the host settles. The pair are the capability's resolving
/// functions, kept Zig-side by index (`PendingWakeReg.promise_idx`).
pub const HostPromise = struct {
    resolve: c.JSValue,
    reject: c.JSValue,
};

/// A fired `after.ms`/`after.kv` arm to settle: resolve resolver `idx`
/// with its wake entry — the same `{kind, prefix?, firedAt}` shape
/// `request.activation.wakes[]` carries, derived from the recorded
/// batch, so a replayer reconstructs the value from the tape.
pub const SettleWake = struct {
    idx: u32,
    kind: enum { timer, kv },
    prefix: []const u8 = "",
    fired_at_ms: i64,
};

/// A bound fetch's event to settle — the Fetch-API shape (rove#930).
/// `phase` picks the resolve value:
///   - `.whole`   — the buffered path (content-length ≤ chunk cap): the
///     fetch promise resolves once with the complete raw response
///     `{status, headers?, bytes, complete: true}`; the shim's `r.text()`
///     is then an already-resolved microtask.
///   - `.headers` — the streamed path's settle-at-headers: the fetch
///     promise resolves `{status, headers?, complete: false}`; the body
///     arrives through chunk pulls.
///   - `.chunk` / `.done` — settle the outstanding CHUNK PULL
///     (`_system.held.nextFetchChunk`) with an iterator result
///     (`{value:{bytes,text}, done:false}` / `{done:true}`), the
///     `request.messages` pattern per fetch.
/// `status` alone is the success contract (no derived `ok`). `reject`
/// non-null rejects the addressed resolver instead.
pub const SettleFetch = struct {
    idx: u32,
    phase: enum { whole, headers, chunk, done } = .whole,
    status: u16 = 0,
    bytes: []const u8 = "",
    headers_json: []const u8 = "",
    truncated: bool = false,
    reject: ?[]const u8 = null,
};

/// The next connection input for a handler iterating `request.messages`
/// or `request.chunks` (`for await`): a WS frame resolves the pull promise with
/// `{value: {opcode, bytes, text}, done: false}`; end-of-input
/// (client close) resolves `{done: true}` so the loop exits and the
/// handler runs on to its terminal return.
pub const SettleInput = struct {
    idx: u32,
    payload: union(enum) {
        frame: struct { opcode: u8, bytes: []const u8 },
        /// A streamed inbound body chunk (rove#931): the body crossed
        /// the size cap, so `default` runs held and `request.chunks`
        /// pulls it chunk by chunk — resolves
        /// `{value: {bytes, text}, done: false}`.
        chunk: []const u8,
        eof,
    },
};

/// What a resume does to the held handler: which host promises it
/// settles, and how.
pub const Settle = union(enum) {
    /// Fired `after.*` arms, in the batch's deterministic order.
    wakes: []const SettleWake,
    /// A bound fetch completed (or must be refused).
    fetch: SettleFetch,
    /// The next `request.messages` pull (`held.SettleInput`).
    input: SettleInput,
};

/// The dispatcher's answer when the handler is awaiting the host.
pub const HeldOutcome = struct {
    /// The detached request arena. `runOutcome` fills it after the
    /// run — the once-path cannot detach while its state still points
    /// into the arena.
    req: ?qjs.snap.HeldRequest = null,
    /// The handler's outer promise (the export's return value). Its
    /// settlement ends the hold. One reference, owned by the host for
    /// the life of the arena; freed with it, never individually.
    outer: c.JSValue,
    /// Host promises created THIS activation, in creation order —
    /// `PendingWakeReg.promise_idx` indexes here. Allocator-owned.
    resolvers: []HostPromise,
    /// The resolver awaiting the next connection input (`request.
    /// messages` pull) — at most one outstanding per activation.
    input_promise: ?u32 = null,
    /// The resolver awaiting the next STREAMED-FETCH chunk
    /// (`_system.held.nextFetchChunk(fetchId)` — the per-fetch
    /// `request.messages` pattern, rove#930). At most one outstanding
    /// per activation; the id names which fetch's chunk settles it.
    /// Bytes allocator-owned (duped from the JS argument).
    fetch_pull: ?FetchPull = null,
    /// `tag(k,v)` set during the activation — survives the hold the
    /// way a continuation's tags survive a `next()`.
    tags: []log_mod.Tag = &.{},

    pub fn deinit(self: *HeldOutcome, allocator: std.mem.Allocator) void {
        if (self.resolvers.len > 0) allocator.free(self.resolvers);
        if (self.fetch_pull) |fp| {
            if (fp.id.len > 0) allocator.free(fp.id);
            self.fetch_pull = null;
        }
        for (self.tags) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        if (self.tags.len > 0) allocator.free(self.tags);
        self.* = undefined;
    }
};

/// An outstanding streamed-fetch chunk pull: which fetch, and the
/// resolver its next chunk (or `{done:true}`) settles.
pub const FetchPull = struct {
    /// The fetch id (allocator-owned dupe).
    id: []u8 = &.{},
    idx: u32 = 0,
};

/// What a resume needs from the park. The worker keeps it on the held
/// entity (`components.HeldRequest`).
pub const HeldState = struct {
    req: qjs.snap.HeldRequest,
    outer: c.JSValue,
    resolvers: []const HostPromise,
};

/// The message a rejected second concurrent `request.messages` pull
/// carries — the iterator hands out one pending step at a time.
pub const INPUT_ALREADY_PULLED = "request input is already being awaited (one pull at a time)";

/// The defined failure when a handler parks on nothing the host owns —
/// a promise the platform can never settle (`docs/handler-shape.md`, a
/// park must be resumable).
pub const NO_WAKE_SOURCE = "handler awaited a promise no host operation will settle (held with no wake source)";
