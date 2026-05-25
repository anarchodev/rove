//! effect.Cmd — Cmd-runtime vocabulary (`docs/effect-algebra.md` §2.4).
//!
//! A `Cmd` is an output the handler emits via its return — a
//! commit-gated, recorded action the engine carries out after the Model
//! write of the same activation commits (L4 — every Cmd is commit-gated).
//!
//! Phase 4.1 (this file's current scope, `docs/effect-reification-plan.md`
//! §6 Phase 4.1): the typed union backed by an exhaustive `interpretCmd`
//! switch + `BufferedCmds` wrapping the per-unit list. Every buffered
//! release point used to be a hand-rolled per-kind helper:
//!
//!   - `firePendingKvWakes` (broadcast to subscribed streams + kv-react)
//!   - `transferStagedChunks` (commit-gated stream output)
//!   - `mark_draining` flag flip (terminal close after chunks land)
//!
//! `interpretCmd` collapses those into one switch site. Adding a new
//! Cmd kind = adding a variant to the union; the compiler refuses to
//! build until `interpretCmd` handles it. That's the contract the
//! plan has been promising since Phase 1.
//!
//! Not yet shipped (deferred):
//!
//!   - `kv_write` as a routed-through-interpretCmd Cmd. Today's
//!     writeset is the kv_write payload de-facto; routing kv.set/delete
//!     emissions through interpretCmd touches every binding call site.
//!     Phase 4.1.2.
//!   - `respond` Cmd: gate H2 response stamping on commit. Touches the
//!     drainEntityArm H2 reference path; the invariant 1 byte-identical
//!     gate makes this a separate phase (4.1.3). The respond_chunk
//!     variant exists in this file but has no producer today.
//!   - `conn_write` Cmd: held outbound write half. Producer is inbound
//!     WebSocket which isn't built (per `docs/curl-multi-plan.md` §6
//!     Phase 4 deferral). interpretCmd panics if it ever lands here.

const std = @import("std");
const kv_mod = @import("rove-kv");
const rove = @import("rove");
const globals_mod = @import("../globals.zig");
const components_mod = @import("../components.zig");

/// Output the handler emits to its return. Released by the
/// reconciler's commit arm (`Continuation.releaseOnCommit` →
/// `interpretCmd` per Cmd) — never before. Discarded on the fault
/// arm (`BufferedCmds.deinit` walks per-variant `deinit`).
pub const Cmd = union(enum) {
    /// Broadcast a kv-write event to subscribed streams (the §4.6
    /// fan-out) AND fold-in the kv-react subscription origins for
    /// this tenant. Allocator-owned `key`. The unit's tenant_id is
    /// passed alongside (not on the Cmd) — every Cmd in one
    /// unit's BufferedCmds shares the same tenant.
    kv_wake_broadcast: KvWakeOp,

    /// Append a chunk of bytes to a destination entity's
    /// `StreamChunks` queue (Phase 4.0.b commit-gated stream
    /// output). The entity is in `h2.stream_data_out`; if it's
    /// been moved/destroyed in the interim (client disconnect
    /// race), the bytes free via this Cmd's deinit (the chunk
    /// reached no socket — "writes committed, no chunk on the wire"
    /// per `streaming-model.md` §2's disconnect-race posture).
    stream_chunk: StreamChunkOut,

    /// Flip a destination entity's `StreamDraining.is_draining`
    /// flag to true. Used by the terminal+writes arm so the
    /// chunks-empty + draining close sequence starts AFTER raft
    /// commits (closes the pre-commit `markStreamDraining` leak
    /// Phase 4.0.b documented).
    stream_close: StreamCloseSignal,

    /// Phase 4.1 (next): submit an `http.fetch` to the FetchEngine
    /// on commit. Closes the marker-commit race that forced
    /// `webhook.send` to drop its inline fetch: stage the
    /// PendingFetch on the parked unit; on raft commit, interpretCmd
    /// hands it to the engine; on fault, the PendingFetch frees
    /// with the unit. Variant declared now (lands the typed slot
    /// for the buffered-vs-engine routing); producer wiring is
    /// Phase 4.1's race-fix half.
    http_fetch: globals_mod.PendingFetch,

    /// Connection-actor frame write — paired with `inbound_frame`
    /// Msg origin on one `Continuation` (the duplex effect, see
    /// `docs/connection-actor-plan.md`). Not built (gap 2.5 closed
    /// the read half; the write half lives with inbound-WS server,
    /// which is a separate plan). interpretCmd panics if it ever
    /// gets one (proves nothing produces this today).
    conn_write: FrameOut,

    /// Discard-arm: free every owned resource. Called per-Cmd from
    /// `BufferedCmds.deinit` on the fault path.
    pub fn deinit(self: *Cmd, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .kv_wake_broadcast => |*w| w.deinit(allocator),
            .stream_chunk => |sc| if (sc.bytes.len > 0) allocator.free(sc.bytes),
            .stream_close => {},
            .http_fetch => |*pf| pf.deinit(allocator),
            .conn_write => |*fo| fo.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// kv-write event for the §4.6 wake fan-out. Allocator-owned key.
pub const KvWakeOp = struct {
    key: []u8,
    /// 'p' (put) or 'd' (delete). One ASCII byte mirrors the raft
    /// envelope's encoding so cross-worker decode is trivial.
    op: u8,

    pub fn deinit(self: *KvWakeOp, allocator: std.mem.Allocator) void {
        if (self.key.len > 0) allocator.free(self.key);
        self.* = undefined;
    }
};

/// Stream-output Cmd: the bytes to append + the destination entity.
pub const StreamChunkOut = struct {
    /// Entity in `h2.stream_data_out` whose `StreamChunks` queue
    /// receives the chunk. A `rove.Entity` is just `{index, gen}`
    /// — opaque and trivially copyable.
    stream_entity: rove.Entity,
    /// Allocator-owned chunk bytes. Transferred into `StreamChunks`
    /// via `tryAppend` on commit; freed on cap-overflow or on the
    /// disconnect-race path (entity moved before commit).
    bytes: []u8,
};

/// `stream_close` Cmd payload. Carries the destination entity so
/// `interpretCmd` can find the `StreamDraining` component.
pub const StreamCloseSignal = struct {
    stream_entity: rove.Entity,
};

/// Connection-actor write payload. Placeholder shape; the producer
/// (inbound-WS server) doesn't exist yet.
pub const FrameOut = struct {
    bytes: []u8 = &.{},
    pub fn deinit(self: *FrameOut, allocator: std.mem.Allocator) void {
        if (self.bytes.len > 0) allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Buffered Cmds parked on a `Continuation` until raft commit.
/// Wrapper around an `ArrayListUnmanaged(Cmd)` that exposes the two
/// release paths:
///
///   - `releaseAll` (commit arm) — interpretCmd each in order,
///     then free the list backing storage. The Cmds' owned slices
///     are consumed (either transferred to the target or freed by
///     interpretCmd on a transfer-time error).
///   - `deinit` (fault arm — also the structural deinit called by
///     `Continuation`'s rove-component deinit on shutdown) — walk
///     each Cmd's `deinit` to free owned slices, then free the list.
///
/// The two paths are mutually exclusive: after `releaseAll`, the
/// struct is reset to `.empty` so a follow-up structural `deinit`
/// from the parent unit's destroy is a no-op.
pub const BufferedCmds = struct {
    items: std.ArrayListUnmanaged(Cmd) = .empty,

    /// Fault-arm discard: free each Cmd's owned resources + the
    /// list. Idempotent (empty list → no-op).
    pub fn deinit(self: *BufferedCmds, allocator: std.mem.Allocator) void {
        for (self.items.items) |*c| c.deinit(allocator);
        self.items.deinit(allocator);
        self.* = .{};
    }

    /// Append a Cmd, taking ownership of any allocator-owned
    /// payload fields. Caller-side ownership transfers in on
    /// success; on `error.OutOfMemory` the Cmd stays with the
    /// caller (caller frees).
    pub fn append(
        self: *BufferedCmds,
        allocator: std.mem.Allocator,
        cmd: Cmd,
    ) error{OutOfMemory}!void {
        try self.items.append(allocator, cmd);
    }

    /// Commit-arm release: `interpretCmd` each Cmd in order, then
    /// free the list backing storage (NOT each Cmd's owned slices
    /// — those were consumed by interpretCmd). Resets to `.empty`
    /// so the parent unit's structural deinit no-ops.
    ///
    /// `worker: anytype` — interpretCmd reads `worker.h2`,
    /// `worker.allocator`, `worker.node.broadcastKvWake` /
    /// `node.fetch_engine`, so the host worker type plumbs through
    /// structurally. Same `anytype` pattern every worker-side
    /// system uses.
    pub fn releaseAll(
        self: *BufferedCmds,
        worker: anytype,
        tenant_id: []const u8,
    ) void {
        for (self.items.items) |cmd| interpretCmd(cmd, worker, tenant_id);
        self.items.deinit(worker.allocator);
        self.* = .{};
    }
};

/// The exhaustive switch over `Cmd` — Phase 4.1's compile-time
/// contract. Adding a variant to `Cmd` is a compile error until
/// this fn handles it (no `else` arm).
///
/// Consumes the Cmd's owned slices on success (transfers them to
/// the target component / engine). On transfer error (entity moved,
/// engine full, etc.) the bytes are freed inline so the caller
/// doesn't double-free.
pub fn interpretCmd(
    cmd: Cmd,
    worker: anytype,
    tenant_id: []const u8,
) void {
    const allocator = worker.allocator;
    switch (cmd) {
        .kv_wake_broadcast => |w| {
            worker.node.broadcastKvWake(tenant_id, w.key, w.op);
            // Broadcast just reads the key; release it after.
            allocator.free(w.key);
        },
        .stream_chunk => |sc| {
            const server = worker.h2;
            const chunks_ptr = server.reg.get(
                sc.stream_entity,
                &server.stream_data_out,
                components_mod.StreamChunks,
            ) catch {
                std.log.info(
                    "rove-js interpretCmd stream_chunk: entity moved/destroyed; discarding chunk (tenant={s})",
                    .{tenant_id},
                );
                if (sc.bytes.len > 0) allocator.free(sc.bytes);
                return;
            };
            chunks_ptr.tryAppend(allocator, sc.bytes) catch |err| {
                std.log.warn(
                    "rove-js interpretCmd stream_chunk: tryAppend failed: {s}",
                    .{@errorName(err)},
                );
                // tryAppend's error path frees the bytes; nothing more.
            };
        },
        .stream_close => |sce| {
            const server = worker.h2;
            const drain_ptr = server.reg.get(
                sce.stream_entity,
                &server.stream_data_out,
                components_mod.StreamDraining,
            ) catch return; // entity gone — nothing to flip
            drain_ptr.is_draining = true;
        },
        .http_fetch => |pf| {
            const engine = worker.node.fetch_engine orelse {
                var pfm = pf;
                pfm.deinit(allocator);
                return;
            };
            engine.submit(pf) catch |err| {
                std.log.warn(
                    "rove-js interpretCmd http_fetch: submit failed: {s}",
                    .{@errorName(err)},
                );
                var pfm = pf;
                pfm.deinit(allocator);
            };
        },
        .conn_write => |fo| {
            // Producer for this variant is inbound WebSocket
            // server, which is a separate plan. Reaching this arm
            // means a producer was added without wiring an
            // interpreter — exactly the contract failure the
            // typed-switch is supposed to catch at COMPILE time,
            // but a runtime panic here is the second line of
            // defense.
            var fom = fo;
            fom.deinit(allocator);
            std.debug.panic(
                "interpretCmd: conn_write Cmd reached the interpreter but no inbound-WS producer is built yet — see docs/curl-multi-plan.md §6 Phase 4",
                .{},
            );
        },
    }
}

test {
    _ = Cmd;
    _ = BufferedCmds;
    _ = interpretCmd;
}
