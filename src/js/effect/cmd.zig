//! effect.Cmd — Cmd-runtime vocabulary (`docs/effect-algebra.md` §2.4).
//!
//! A `Cmd` is an output the handler emits via its return — a
//! commit-gated, recorded action the engine carries out after the Model
//! write of the same activation commits (L4 — every Cmd is commit-gated).
//!
//! Phase 4.1, shipped 2026-05-24 (the plan doc is folded into
//! `docs/decisions.md` §3.2 + `docs/architecture/effects-and-handlers.md`):
//! the typed union backed by an exhaustive `interpretCmd`
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
//! Live variants today: `kv_wake_broadcast`, `stream_chunk`,
//! `stream_close`, `http_fetch`, `respond`. The 4.1.3 Option-2
//! atomic flip shipped `respond`; every site that parks an entity in
//! raft_pending_X emits one. `http_fetch` Phase 4.1.2 closes the
//! marker-commit race — the barrier + write-path branches in
//! `worker_dispatch.finalizeBatch` stage one Cmd.http_fetch per
//! PendingFetch issued from a read- or write-path handler, so
//! `interpretCmd` submits to the FetchEngine strictly after the
//! batch commits. Future variants (e.g. `kv_write` routing,
//! `conn_write` for inbound-WS) get added when their producer
//! ships — adding the union arm before the producer is the
//! `respond_deferred` failure mode the Phase 4.1 reframe ruled out.

const std = @import("std");
const kv_mod = @import("raft-kv");
const rove = @import("rove");
const h2 = @import("rove-h2");
const globals_mod = @import("../globals.zig");
const components_mod = @import("../components.zig");
const blob_receive_mod = @import("../blob_receive.zig");
const deploy_thread_mod = @import("../deploy_thread.zig");

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

    /// Phase 4.1.2: submit an `http.fetch` to the FetchEngine on
    /// commit. Closes the marker-commit race that forced
    /// `webhook.send` to drop its inline fetch — the parked unit
    /// owns the PendingFetch until raft commits the writeset, then
    /// `interpretCmd` hands it to the engine; on fault, the
    /// PendingFetch frees with the unit. Producer is
    /// `worker_dispatch.finalizeBatch` (both barrier + write paths
    /// stage one per `batch_pending_fetches` item).
    http_fetch: globals_mod.PendingFetch,

    /// Phase 4.1.3: H2 response stamping deferred to commit time.
    /// Carries the h2 response payload (Status / RespHeaders /
    /// RespBody / H2IoResult) plus the entity reference + the
    /// source/dest collection enum so `interpretCmd` can stamp the
    /// components on the entity AND move it to its commit
    /// destination in one go.
    ///
    /// Session + StreamId stay stamped early (at handler-success
    /// time) because the fault arm of `drainEntityArm` needs them
    /// to ship a 503 — those identity components don't change
    /// across the success/fault split, so deferring them would
    /// force the fault arm to set them too.
    ///
    /// Producer: `worker_dispatch.finalizeBatch`'s write +
    /// barrier paths emit one Cmd.respond per success entity,
    /// staged on the parked_units unit's BufferedCmds (alongside
    /// kv_wake_broadcast + stream_chunk). The entity itself sits in
    /// `raft_pending_{response,cont,stream}` with default-value h2
    /// payload components; `interpretCmd` stamps the real values
    /// at commit time + moves to dest. Fault arm
    /// (`drainEntityArm` fault branch) stamps Status=503 +
    /// canned-body RespBody as today; the entity's RespHeaders
    /// stays empty on fault (was the handler's leaked headers
    /// pre-4.1.3 — arguably more correct).
    respond: RespondOut,

    /// architecture/websockets.md (piece D): emit one outbound WebSocket frame
    /// on commit. Created an entity in `h2.ws_send_in` (Session = the
    /// conn, WsMeta.opcode, ReqBody = bytes) that `consumeWsSends`
    /// RFC-6455-frames on the next h2 poll. Commit-gated so a frame
    /// produced by a WRITING `onMessage` reaches the wire only after
    /// its writeset commits (the batch-of-1 durability rule —
    /// `streaming-model.md` §2 applied to WS). If the conn died before
    /// commit (client vanished), the bytes free here — "writes
    /// committed, no frame on the wire," the same disconnect-race
    /// posture as `stream_chunk`. Producer: `fireWsMessage`'s write arm
    /// (read-only frames emit `ws_send_in` inline — no commit to wait
    /// on). Supersedes the withdrawn `conn_write` Cmd reservation.
    ws_send: WsSendOut,

    /// Discard-arm: free every owned resource. Called per-Cmd from
    /// `BufferedCmds.deinit` on the fault path.
    pub fn deinit(self: *Cmd, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .kv_wake_broadcast => |*w| w.deinit(allocator),
            .stream_chunk => |sc| if (sc.bytes.len > 0) allocator.free(sc.bytes),
            .stream_close => {},
            .http_fetch => |*pf| pf.deinit(allocator),
            .respond => |*ro| ro.deinit(allocator),
            .ws_send => |wo| if (wo.bytes.len > 0) allocator.free(wo.bytes),
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

/// `ws_send` Cmd payload — one outbound WebSocket frame to emit on
/// commit. `conn_entity` is the h2 connection (the `Session.entity`
/// shared by every `ws_message_out` / `ws_send_in` entity for that
/// socket); `opcode` is the RFC 6455 data/control opcode (1 = text,
/// 2 = binary, 8 = close); `bytes` is the allocator-owned frame
/// payload (empty for a close). Transferred into a fresh `ws_send_in`
/// entity on commit; freed if the conn is gone (disconnect race).
pub const WsSendOut = struct {
    conn_entity: rove.Entity,
    opcode: u8,
    bytes: []u8,
};

/// `respond` Cmd payload — Phase 4.1.3's commit-arm entity move
/// for an H2 response entity. The h2 payload components (Status /
/// RespHeaders / RespBody / H2IoResult) are already stamped on
/// the entity at handler-success time (`worker_dispatch.zig` per
/// success); this Cmd just routes the post-commit `reg.move` from
/// `raft_pending_X` → the per-success destination through
/// `interpretCmd` instead of inline in `drainEntityArm`'s commit
/// arm. The architectural value is the exhaustive-switch
/// contract: every buffered entity-state-transition kind now has
/// a typed Cmd variant + interpretCmd arm.
///
/// (Earlier 4.1.3 draft also DEFERRED the component stamping into
/// the Cmd payload. That broke the read-only fast path — which
/// stamps + moves the entity inline without producing a Cmd, so
/// h2 ended up shipping with Status=0 default values. Restricting
/// the Cmd to the move-only shape avoids that footgun; the
/// payload-deferral can be revisited if commit-time component
/// stamping becomes valuable for a specific reason.)
pub const RespondOut = struct {
    entity: rove.Entity,
    /// Which raft_pending_X collection the entity is in NOW. The
    /// interpreter's `reg.move` source.
    source: SourceColl,
    /// Where the entity moves on commit. One of the three per-
    /// source destinations enumerated in `DestColl`.
    dest: DestColl,

    /// Three raft_pending_* siblings → three source enums. The
    /// `drainEntityArm` calls in `drainRaftPending` walk each of
    /// these collections per tick; this enum is how a Cmd.respond
    /// names which one the entity is currently in.
    pub const SourceColl = enum {
        raft_pending_response,
        raft_pending_cont,
        raft_pending_stream,
    };

    /// Per-source destination: response → h2.response_in (h2 ships
    /// from here); cont → worker.parked_continuations (held-sync
    /// awaits resume); stream → h2.stream_response_in (h2's
    /// streaming pipeline takes over).
    pub const DestColl = enum {
        response_in,
        parked_continuations,
        stream_response_in,
    };

    pub fn deinit(self: *RespondOut, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // Move-only Cmd; no owned payload to free. The h2
        // components on the entity are freed when the entity
        // destroys (via the component types' own deinit) — same
        // ownership chain pre-4.1.3.
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
    /// `worker.allocator`, `worker.node.router.broadcastKvWake` /
    /// `node.fetch_engine`, so the host worker type plumbs through
    /// structurally. Same `anytype` pattern every worker-side
    /// system uses.
    /// `write_version` is the tenant store's §8.4 write clock sampled
    /// once post-commit by the caller (the leader commit arm) and
    /// stamped onto every `kv_wake_broadcast` so `matchEventsToWakes`
    /// can gate `on.kv` watches. `maxInt` = fire-always sentinel.
    pub fn releaseAll(
        self: *BufferedCmds,
        worker: anytype,
        tenant_id: []const u8,
        write_version: u64,
    ) void {
        for (self.items.items) |cmd| interpretCmd(cmd, worker, tenant_id, write_version);
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
    write_version: u64,
) void {
    const allocator = worker.allocator;
    switch (cmd) {
        .kv_wake_broadcast => |w| {
            worker.node.router.broadcastKvWake(tenant_id, w.key, w.op, write_version);
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
            // Trusted internal doors (blob.receive / platform.compile /
            // stampManifest) never reach libcurl — route to the worker-local
            // subsystem. ONE partition for every submit site (worker.zig).
            if (worker.tryDoorFetch(pf)) return;
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
        .respond => |ro| {
            // Resolve source + dest collection pointers from the
            // enum. Each branch is a single typed pointer; the
            // chain below uses anytype on `reg.set` / `reg.move`
            // so we don't need to make the pointer types match.
            switch (ro.source) {
                .raft_pending_response => stampAndMoveRespond(
                    worker,
                    ro,
                    &worker.raft_pending_response,
                ),
                .raft_pending_cont => stampAndMoveRespond(
                    worker,
                    ro,
                    &worker.raft_pending_cont,
                ),
                .raft_pending_stream => stampAndMoveRespond(
                    worker,
                    ro,
                    &worker.raft_pending_stream,
                ),
            }
        },
        .ws_send => |wo| {
            const server = worker.h2;
            // The conn may have died during the commit-wait window
            // (client RST/EOF); drop the frame + free its bytes — the
            // socket is gone, "writes committed, no frame on the wire."
            if (server.reg.isStale(wo.conn_entity)) {
                if (wo.bytes.len > 0) allocator.free(wo.bytes);
                return;
            }
            emitWsSend(worker, wo) catch |err| {
                std.log.warn(
                    "rove-js interpretCmd ws_send: emit failed: {s}; dropping frame (tenant={s})",
                    .{ @errorName(err), tenant_id },
                );
                if (wo.bytes.len > 0) allocator.free(wo.bytes);
            };
        },
    }
}

/// Create one `ws_send_in` entity from a `ws_send` Cmd. The bytes
/// transfer into the entity's `ReqBody` (freed by `consumeWsSends` →
/// `reg.destroy` after the frame ships). On any `set` failure the
/// partial entity is destroyed and the error propagates so the caller
/// frees the bytes (the entity never reached a state where it owns
/// them). Shared by the commit arm here and the read-only inline path
/// in `fireWsMessage`.
pub fn emitWsSend(worker: anytype, wo: WsSendOut) !void {
    const server = worker.h2;
    const ent = try server.reg.create(&server.ws_send_in);
    errdefer server.reg.destroy(ent) catch {};
    try server.reg.set(ent, &server.ws_send_in, h2.Session, .{ .entity = wo.conn_entity });
    try server.reg.set(ent, &server.ws_send_in, h2.WsMeta, .{ .opcode = wo.opcode });
    const data: ?[*]u8 = if (wo.bytes.len > 0) wo.bytes.ptr else null;
    try server.reg.set(ent, &server.ws_send_in, h2.ReqBody, .{ .data = data, .len = @intCast(wo.bytes.len) });
}

/// `respond` interpreter shared body. Stamps the four payload
/// components on the entity in `source_coll`, then moves to the
/// dest collection chosen per `ro.dest`. Helper exists so each
/// `source` switch arm can pass a concrete (typed) collection
/// pointer without `interpretCmd` itself growing nine-way nested
/// switches.
fn stampAndMoveRespond(worker: anytype, ro: RespondOut, source_coll: anytype) void {
    const server = worker.h2;
    // Move-only: the h2 response components are already stamped
    // on the entity in `source_coll` (at handler-success time in
    // `worker_dispatch`). Just route the entity to its commit
    // destination. The `parked_continuations` collection lives on
    // `worker`, not `worker.h2`; the others live on h2.
    switch (ro.dest) {
        .response_in => server.reg.move(ro.entity, source_coll, &server.response_in) catch |err|
            std.log.warn("interpretCmd respond: move→response_in: {s}", .{@errorName(err)}),
        .parked_continuations => server.reg.move(ro.entity, source_coll, &worker.parked_continuations) catch |err|
            std.log.warn("interpretCmd respond: move→parked_continuations: {s}", .{@errorName(err)}),
        .stream_response_in => server.reg.move(ro.entity, source_coll, &server.stream_response_in) catch |err|
            std.log.warn("interpretCmd respond: move→stream_response_in: {s}", .{@errorName(err)}),
    }
}

test {
    _ = Cmd;
    _ = BufferedCmds;
    _ = interpretCmd;
}
