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

/// What a resume does to the held handler: which host promise it
/// settles, and how.
pub const Settle = union(enum) {
    /// A timer arm fired: resolve resolver `idx` with `undefined`.
    timer: u32,
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
    /// `tag(k,v)` set during the activation — survives the hold the
    /// way a continuation's tags survive a `next()`.
    tags: []log_mod.Tag = &.{},

    pub fn deinit(self: *HeldOutcome, allocator: std.mem.Allocator) void {
        if (self.resolvers.len > 0) allocator.free(self.resolvers);
        for (self.tags) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        if (self.tags.len > 0) allocator.free(self.tags);
        self.* = undefined;
    }
};

/// What a resume needs from the park. The worker keeps it on the held
/// entity (`components.HeldRequest`).
pub const HeldState = struct {
    req: qjs.snap.HeldRequest,
    outer: c.JSValue,
    resolvers: []const HostPromise,
};

/// The defined failure when a handler parks on nothing the host owns —
/// a promise the platform can never settle (`docs/handler-shape.md`, a
/// park must be resumable).
pub const NO_WAKE_SOURCE = "handler awaited a promise no host operation will settle (held with no wake source)";
