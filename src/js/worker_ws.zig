//! Inbound WebSocket worker seam (docs/websocket-plan.md §4.5/§5, piece D).
//! Extracted from `worker_streaming.zig` — same `worker: anytype`
//! structural-typing shape; the commit-gated write path reuses
//! `worker_streaming.StreamResumeStage` + `proposeForgetfulWrites`.
//!
//! A held WebSocket connection is a parked continuation chain (it lives in
//! `parked_continuations`, located by conn entity via `ws_conns`).
//! The h2 transport surfaces each complete inbound data frame on the
//! `ws_message_out` collection (Session = conn, WsMeta.opcode, ReqBody =
//! payload); `serviceWsMessages` drains it once per tick and dispatches each
//! frame to the tenant's `onMessage` export (client-close opcode 8 →
//! `onDisconnect`). Outbound `stream.write`s lower to `ws_send_in` entities —
//! inline for read-only frames, commit-gated `ws_send` Cmds for writing frames
//! (batch-of-1 durability). This is additive on the STABLE transport
//! collections — no new collection, no transport change.
//!
//! §4.5 strict reply ordering — the per-connection INPUT GATE: while a
//! writing frame's forgetful unit awaits raft (`WsConnState.gate_seq`),
//! newly-arriving frames for that connection queue instead of activating.
//! `flushWsGates` re-opens the gate once the seq committed AND the unit
//! was released (its reply frames are in `ws_send_in`), then dispatches
//! the queue in arrival order. Two guarantees fall out: replies on one
//! socket are in message order across the durability boundary, and frame
//! K+1 reads frame K's writes (it only activates post-commit — the
//! read-your-writes the DO input gate provides).

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const kv_mod = @import("raft-kv");
const log_mod = @import("rove-log");
const tape_mod = @import("rove-tape");

const dispatcher_mod = @import("dispatcher.zig");
const router_mod = @import("router.zig");
const components_mod = @import("components.zig");
const effect_mod = @import("effect/root.zig");
const panic_mod = @import("panic.zig");
const Request = dispatcher_mod.Request;

const worker_mod = @import("worker.zig");
const worker_streaming = @import("worker_streaming.zig");
const captureLogWithId = worker_mod.captureLogWithId;
const resolveDeployment = worker_mod.resolveDeployment;
const StreamResumeStage = worker_streaming.StreamResumeStage;
const proposeForgetfulWrites = worker_streaming.proposeForgetfulWrites;

/// Drain the conn-state index of any entry whose connection has died without
/// a Close frame (abrupt client RST/EOF — the transport reaps the conn but
/// emits no opcode-8 message). Fire `onDisconnect` on each orphaned chain,
/// then tear it down. Cheap when the map is empty (one length check). Run at
/// the top of `serviceWsMessages` so a dead idle conn doesn't leak its chain.
fn sweepStaleWsChains(worker: anytype) void {
    if (worker.ws_conns.count() == 0) return;
    const server = worker.h2;
    // Collect stale conns first — can't mutate the map mid-iteration.
    var stale: [128]rove.Entity = undefined;
    var n: usize = 0;
    {
        var it = worker.ws_conns.iterator();
        while (it.next()) |entry| {
            if (n >= stale.len) break;
            if (server.reg.isStale(entry.key_ptr.*)) {
                stale[n] = entry.key_ptr.*;
                n += 1;
            }
        }
    }
    for (stale[0..n]) |conn_ent| {
        if (worker.ws_conns.get(conn_ent)) |st| {
            fireWsDisconnect(worker, st.chain);
        }
        tearDownWsChain(worker, conn_ent);
    }
}

/// Destroy a held WS chain entity + drop its conn-state entry (freeing any
/// gated frames still queued — the socket is closing; they can never be
/// replied to). Idempotent — a no-op when the conn isn't mapped. The
/// entity's `ChainContext` / `StreamChain` owned slices free via component
/// deinit on destroy.
fn tearDownWsChain(worker: anytype, conn_ent: rove.Entity) void {
    const st = worker.ws_conns.getPtr(conn_ent) orelse return;
    for (st.queue.items) |f| {
        if (f.payload.len > 0) worker.allocator.free(f.payload);
    }
    st.queue.deinit(worker.allocator);
    worker.h2.reg.destroy(st.chain) catch {};
    _ = worker.ws_conns.remove(conn_ent);
}

/// Routing for a WS identity entity, transport-agnostic: an Extended-CONNECT
/// stream's identity entity (h2, `wsStreamRouting` — websocket-plan §8.5) or
/// an h1 ws-mode conn entity (`wsConnRouting`).
fn wsRouting(server: anytype, ent: rove.Entity) ?struct { authority: []const u8, path: []const u8 } {
    if (server.wsStreamRouting(ent)) |r| return .{ .authority = r.authority, .path = r.path };
    if (server.wsConnRouting(ent)) |r| return .{ .authority = r.authority, .path = r.path };
    return null;
}

/// websocket-plan §8.5: disposition pending Extended-CONNECT tunnels BEFORE
/// any 200 reaches the front — unknown tenant/host → 404; not the tenant's
/// leader → 421 (the front re-aims at the next node, the same contract as
/// request routing; this fixes the h1-direct flaw where the 101 always
/// succeeded and the first frame failed). Accepting wires the stream into
/// `ws_message_out` / `ws_send_in`; the chain itself establishes lazily on
/// the first frame (`establishWsChain`), same as h1.
fn serviceWsConnects(worker: anytype) void {
    const server = worker.h2;
    const ents = server.ws_connect_out.entitySlice();
    if (ents.len == 0) return;
    // Snapshot — accept/reject mutate the collection.
    var buf: [64]rove.Entity = undefined;
    var n: usize = 0;
    for (ents) |ent| {
        if (n >= buf.len) break;
        buf[n] = ent;
        n += 1;
    }
    for (buf[0..n]) |ent| {
        const routing = wsRouting(server, ent) orelse {
            server.wsConnectReject(ent, 400);
            continue;
        };
        const host = worker_mod.hostOnly(routing.authority);
        const inst = (worker.node.tenant.resolveDomain(host) catch null) orelse {
            server.wsConnectReject(ent, 404);
            continue;
        };
        _ = inst;
        if (!worker.raft.isLeader()) {
            server.wsConnectReject(ent, 421);
            continue;
        }
        if (server.wsConnectAccept(ent) != .ok) {
            // Stream died between emit and now; nothing to clean.
            continue;
        }
    }
}

/// Establish the held chain for a new WS connection on its first inbound
/// frame: resolve the tenant (from the upgrade Host) + handler module (from
/// the upgrade path), mint a per-connection correlation id, create the parked
/// continuation entity carrying the chain identity, and index it by conn.
/// Returns the chain entity, or an error if routing/tenant/module can't be
/// resolved (the caller closes the socket).
fn establishWsChain(worker: anytype, conn_ent: rove.Entity) !rove.Entity {
    const allocator = worker.allocator;
    const server = worker.h2;
    const routing = wsRouting(server, conn_ent) orelse return error.WsConnGone;
    const host = worker_mod.hostOnly(routing.authority);
    const inst = (worker.node.tenant.resolveDomain(host) catch return error.WsResolveFailed) orelse
        return error.WsNoTenant;

    var route = router_mod.resolveRoute(allocator, routing.path) catch return error.WsRouteFailed;
    defer route.deinit();

    // Validate the module resolves to a deployment + bytecode now (and
    // capture deployment_id for the chain). Each frame re-pins via
    // `resolveDeployment` so this is a fail-fast + identity stamp.
    var dep = try resolveDeployment(worker, allocator, inst.id, route.module_base);
    defer dep.tc.release();

    // Per-connection correlation id (16-hex of a fresh request_id), stable
    // across the connection's frames — mirrors the inbound mint.
    const request_id: u64 = blk: {
        const tl = worker.tenant_logs.get(inst.id) orelse break :blk 0;
        break :blk tl.id_minter.nextRequestId() catch 0;
    };
    var corr_buf: [16]u8 = undefined;
    const corr = std.fmt.bufPrint(&corr_buf, "{x:0>16}", .{request_id}) catch unreachable;

    const ent = try server.reg.create(&worker.parked_continuations);
    errdefer server.reg.destroy(ent) catch {};
    try server.reg.set(ent, &worker.parked_continuations, h2.Session, .{ .entity = conn_ent });
    // Each dup's errdefer is block-scoped so it fires ONLY if the `set` that
    // transfers ownership into the entity component fails. Once `set` succeeds
    // and the block exits normally, the dup is owned by the component (freed by
    // the entity-destroy errdefer above via the component's deinit) — no
    // double-free on a later failure (`put`, etc.).
    {
        const tid_dup = try allocator.dupe(u8, inst.id);
        errdefer allocator.free(tid_dup);
        const corr_dup = try allocator.dupe(u8, corr);
        errdefer allocator.free(corr_dup);
        try server.reg.set(ent, &worker.parked_continuations, components_mod.ChainContext, .{
            .tenant_id = tid_dup,
            .correlation_id = corr_dup,
            .deployment_id = dep.tc.snap.deployment_id,
        });
    }
    {
        const mod_dup = try allocator.dupe(u8, route.module_base);
        errdefer allocator.free(mod_dup);
        const ctx_dup = try allocator.dupe(u8, "{}");
        errdefer allocator.free(ctx_dup);
        try server.reg.set(ent, &worker.parked_continuations, components_mod.StreamChain, .{
            .module_path = mod_dup,
            .ctx_json = ctx_dup,
            .activation_count = 0,
        });
    }
    // A WS chain is a parked continuation that waits on the NEXT FRAME — not a
    // §6.4 deadline and not an `on.*` wake. `sweepParkedContinuations` treats
    // any entry with `now_ns >= deadline_ns` as deadline-expired, so set the
    // deadline to "never" (the default 0 would tear the chain down on the very
    // next tick). The default `StreamWakes` (interval_ms 0, empty ring) already
    // makes it non-wake-due, so the sweep skips WS chains entirely; frame
    // arrival (`serviceWsMessages`) is their only resume source.
    try server.reg.set(ent, &worker.parked_continuations, components_mod.ContDescriptor, .{
        .deadline_ns = std.math.maxInt(i64),
    });
    try worker.ws_conns.put(allocator, conn_ent, .{ .chain = ent });
    return ent;
}

/// Arm the §4.5 input gate: `seq` is the writing frame's forgetful-unit
/// propose; frames arriving for this connection queue until it resolves.
/// The deadline mirrors the unit's own `commit_wait_timeout_ns` so a unit
/// reaped without advancing either watermark (leadership-loss sweep)
/// can't wedge the connection.
fn armWsGate(worker: anytype, conn_ent: rove.Entity, tenant_id: []const u8, seq: u64) void {
    const st = worker.ws_conns.getPtr(conn_ent) orelse return;
    st.gate_seq = seq;
    st.gate_gid = worker.raft.gidForTenant(tenant_id) orelse 0;
    st.gate_deadline_ns = @as(i64, @intCast(std.time.nanoTimestamp())) +
        @as(i64, @intCast(worker.commit_wait_timeout_ns));
}

/// True while any forgetful `ParkedUnit` still holds `seq` — i.e. the
/// drain hasn't released (or has Conflict-deferred) that propose's
/// buffered Cmds yet. The gate must wait for the UNIT, not just the
/// commit watermark: `committedSeq` advances on the pump thread, so it
/// can lead the drain within a tick — opening the gate on the watermark
/// alone would let a queued frame's inline reply ship before the gated
/// frame's commit-released reply frames reach `ws_send_in`. A destroyed-
/// but-unflushed unit still shows in the column (deferred destroy) —
/// that errs one tick conservative, never early.
fn parkedUnitHoldsSeq(worker: anytype, seq: u64) bool {
    for (worker.parked_units.column(worker_mod.ParkedUnit)) |*u| {
        if (u.seq == seq) return true;
    }
    return false;
}

/// §4.5 input-gate pump, run once per tick (after `drainRaftPending` in
/// the worker tick, so a commit observed here has already released its
/// unit's reply frames). For each gated connection: fault/timeout →
/// Close + teardown (the gated write's replies were discarded — the
/// connection can't be resumed honestly); committed + unit released →
/// open the gate and dispatch the queued frames in arrival order until
/// either the queue drains or a writing frame re-arms the gate.
fn flushWsGates(worker: anytype) void {
    if (worker.ws_conns.count() == 0) return;
    var pending: [128]rove.Entity = undefined;
    var n: usize = 0;
    {
        var it = worker.ws_conns.iterator();
        while (it.next()) |entry| {
            if (n >= pending.len) break;
            if (entry.value_ptr.gate_seq == 0 and entry.value_ptr.queue.items.len == 0) continue;
            pending[n] = entry.key_ptr.*;
            n += 1;
        }
    }
    if (n == 0) return;
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    outer: for (pending[0..n]) |conn_ent| {
        var st = worker.ws_conns.getPtr(conn_ent) orelse continue;
        if (st.gate_seq != 0) {
            const committed = worker.raft.committedSeq(st.gate_gid);
            const faulted = worker.raft.faultedSeq(st.gate_gid);
            if (faulted >= st.gate_seq or now_ns >= st.gate_deadline_ns) {
                std.log.warn("rove-js ws: gated seq={d} faulted/timed out; closing conn", .{st.gate_seq});
                effect_mod.cmd.emitWsSend(worker, .{ .conn_entity = conn_ent, .opcode = 8, .bytes = &.{} }) catch {};
                tearDownWsChain(worker, conn_ent);
                continue;
            }
            if (committed < st.gate_seq or parkedUnitHoldsSeq(worker, st.gate_seq)) continue;
            st.gate_seq = 0;
            st.gate_gid = 0;
            st.gate_deadline_ns = 0;
        }
        while (st.queue.items.len != 0) {
            const f = st.queue.orderedRemove(0);
            defer if (f.payload.len > 0) worker.allocator.free(f.payload);
            if (worker.h2.reg.isStale(conn_ent)) {
                // Conn died while frames were queued — replies are
                // undeliverable; the next sweep would fire onDisconnect,
                // but the chain is right here: do it now.
                fireWsDisconnect(worker, st.chain);
                tearDownWsChain(worker, conn_ent);
                continue :outer;
            }
            if (f.opcode == 8) {
                fireWsDisconnect(worker, st.chain);
                tearDownWsChain(worker, conn_ent);
                continue :outer;
            }
            fireWsMessage(worker, st.chain, conn_ent, f.opcode, f.payload);
            // fireWsMessage may have torn the chain down (terminal /
            // error) or re-armed the gate (writing frame) — re-resolve.
            st = worker.ws_conns.getPtr(conn_ent) orelse continue :outer;
            if (st.gate_seq != 0) continue :outer;
        }
    }
}

/// Drain `ws_message_out` once per tick: dispatch each inbound WS data frame
/// to the held chain's `onMessage`, route a client close (opcode 8) to
/// `onDisconnect`, and reap chains whose conn vanished. Gated by `count()==0`
/// so the no-WS hot path pays nothing.
pub fn serviceWsMessages(worker: anytype) !void {
    serviceWsConnects(worker);
    sweepStaleWsChains(worker);
    flushWsGates(worker);

    const server = worker.h2;
    if (server.ws_message_out.entitySlice().len == 0) return;

    // Snapshot (ment, conn, opcode, payload) up front — processing creates /
    // destroys entities, so the columns aren't stable across the loop. The
    // payload borrows `ReqBody.data`, valid until `ment` is destroyed; destroy
    // is queued (flushed after this fn) so the borrow holds for the whole loop.
    const Pending = struct { ment: rove.Entity, conn: rove.Entity, opcode: u8, payload: []const u8 };
    var buf: [256]Pending = undefined;
    var n: usize = 0;
    {
        const ents = server.ws_message_out.entitySlice();
        const sessions = server.ws_message_out.column(h2.Session);
        const metas = server.ws_message_out.column(h2.WsMeta);
        const bodies = server.ws_message_out.column(h2.ReqBody);
        for (ents, sessions, metas, bodies) |ent, sess, meta, body| {
            if (n >= buf.len) break;
            const payload: []const u8 = if (body.data) |d| d[0..body.len] else &.{};
            buf[n] = .{ .ment = ent, .conn = sess.entity, .opcode = meta.opcode, .payload = payload };
            n += 1;
        }
    }

    for (buf[0..n]) |p| {
        if (server.reg.isStale(p.conn)) {
            // Conn already gone — reap any chain (no onDisconnect: the socket
            // is dead, and an abrupt close is swept above). Drop the message.
            tearDownWsChain(worker, p.conn);
            server.reg.destroy(p.ment) catch {};
            continue;
        }
        // §4.5 input gate: while a writing frame's commit is in flight (or
        // earlier frames are still queued — order is sacred), this frame
        // queues instead of activating. Opcode 8 queues too, so a close
        // behind queued data frames fires onDisconnect only after they run.
        if (worker.ws_conns.getPtr(p.conn)) |st| {
            if (st.gate_seq != 0 or st.queue.items.len != 0) {
                const copy: []u8 = if (p.payload.len > 0)
                    worker.allocator.dupe(u8, p.payload) catch {
                        // OOM on the queue copy — can't preserve order, so
                        // fail the connection loudly rather than drop a frame.
                        effect_mod.cmd.emitWsSend(worker, .{ .conn_entity = p.conn, .opcode = 8, .bytes = &.{} }) catch {};
                        tearDownWsChain(worker, p.conn);
                        server.reg.destroy(p.ment) catch {};
                        continue;
                    }
                else
                    &.{};
                st.queue.append(worker.allocator, .{ .opcode = p.opcode, .payload = copy }) catch {
                    if (copy.len > 0) worker.allocator.free(copy);
                    effect_mod.cmd.emitWsSend(worker, .{ .conn_entity = p.conn, .opcode = 8, .bytes = &.{} }) catch {};
                    tearDownWsChain(worker, p.conn);
                };
                server.reg.destroy(p.ment) catch {};
                continue;
            }
        }
        if (p.opcode == 8) {
            // Client close → onDisconnect (best-effort), then tear down.
            if (worker.ws_conns.get(p.conn)) |st| {
                fireWsDisconnect(worker, st.chain);
            }
            tearDownWsChain(worker, p.conn);
            server.reg.destroy(p.ment) catch {};
            continue;
        }
        // Data frame (text/binary) → find-or-establish the chain, run onMessage.
        const chain_ent = if (worker.ws_conns.get(p.conn)) |st|
            st.chain
        else
            establishWsChain(worker, p.conn) catch |err| {
                std.log.warn("rove-js ws: establish chain failed: {s}; closing conn", .{@errorName(err)});
                // Couldn't bind a tenant/module — send a Close so the client
                // sees a clean shutdown rather than a hang.
                effect_mod.cmd.emitWsSend(worker, .{ .conn_entity = p.conn, .opcode = 8, .bytes = &.{} }) catch {};
                server.reg.destroy(p.ment) catch {};
                continue;
            };
        fireWsMessage(worker, chain_ent, p.conn, p.opcode, p.payload);
        server.reg.destroy(p.ment) catch {};
    }
}

/// Run one inbound WS frame's `onMessage` activation against the held chain.
/// Structural sibling of `fireDisconnectActivation` — reads the chain identity
/// off `parked_continuations`, re-pins the deployment, synthesizes a `{ctx}`
/// request with the `.ws_message` activation (opcode + data surface as
/// `request.activation`), runs the handler, then ships its `stream.write`
/// frames to `ws_send_in` (inline if read-only, commit-gated if it wrote).
/// `next()` keeps the chain parked (threading the new ctx); a terminal return
/// closes the socket + tears the chain down.
fn fireWsMessage(
    worker: anytype,
    chain_ent: rove.Entity,
    conn_ent: rove.Entity,
    opcode: u8,
    payload: []const u8,
) void {
    const allocator = worker.allocator;
    const server = worker.h2;
    const chain_ctx = server.reg.get(chain_ent, &worker.parked_continuations, components_mod.ChainContext) catch return;
    const chain_st = server.reg.get(chain_ent, &worker.parked_continuations, components_mod.StreamChain) catch return;

    const path = chain_st.module_path;
    var p = worker_streaming.firePrep(worker, chain_ctx.tenant_id, path, "ws-message") orelse {
        effect_mod.cmd.emitWsSend(worker, .{ .conn_entity = conn_ent, .opcode = 8, .bytes = &.{} }) catch {};
        tearDownWsChain(worker, conn_ent);
        return;
    };
    defer p.deinit(allocator);
    const tc = p.dep.tc;

    const body = std.fmt.allocPrint(allocator, "{{\"ctx\":{s}}}", .{chain_st.ctx_json}) catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{path}) catch return;
    defer allocator.free(spath);

    // `stream.write` accumulators (bytes + parallel opcode), wired so the
    // handler's frames are captured for lowering to `ws_send_in`.
    var stream_chunks: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (stream_chunks.items) |ch| allocator.free(ch);
        stream_chunks.deinit(allocator);
    }
    var chunk_opcodes: std.ArrayListUnmanaged(u8) = .empty;
    defer chunk_opcodes.deinit(allocator);

    const request: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        .activation = .{ .ws_message = .{ .opcode = opcode, .data = payload } },
        .trace = .{ .readset = &p.readset, .request_id = p.request_id, .correlation_id = chain_ctx.correlation_id },
        .plan = .{ .limiter = &worker.limiter, .instance_id = p.dep.inst.id, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = p.dep.inst.platform },
        .effects = .{
            .pending_stream_chunks = &stream_chunks,
            .pending_stream_chunk_opcodes = &chunk_opcodes,
        },
    };
    var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
    const run_oc = worker.dispatcher.runOutcome(
        p.dep.inst.kv,
        p.txn,
        &p.ws,
        p.dep.bc,
        &tc.snap.bytecodes,
        &tc.snap.source_hashes,
        tc.snap.triggers,
        request,
        &budget,
    ) catch {
        p.txn.rollback() catch {};
        p.txn_done = true;
        captureLogWithId(worker, chain_ctx.tenant_id, p.request_id, "POST", path, "", tc.snap.deployment_id, p.now_ns, 500, .handler_error, &.{}, &.{}, .{}, chain_ctx.correlation_id, .ws_message, 0);
        effect_mod.cmd.emitWsSend(worker, .{ .conn_entity = conn_ent, .opcode = 8, .bytes = &.{} }) catch {};
        tearDownWsChain(worker, conn_ent);
        return;
    };

    var oc = run_oc;
    switch (oc) {
        .terminal => |*r| {
            defer r.deinit(allocator);
            if (r.exception.len > 0) {
                p.txn.rollback() catch {};
                p.txn_done = true;
                captureLogWithId(worker, chain_ctx.tenant_id, p.request_id, "POST", path, "", tc.snap.deployment_id, p.now_ns, 500, .handler_error, r.console, r.exception, .{}, chain_ctx.correlation_id, .ws_message, 0);
                r.console = &.{};
                r.exception = &.{};
                effect_mod.cmd.emitWsSend(worker, .{ .conn_entity = conn_ent, .opcode = 8, .bytes = &.{} }) catch {};
                tearDownWsChain(worker, conn_ent);
                return;
            }
            const lh = worker_streaming.fireLogHeader(p.request_id, tc.snap.deployment_id, @intCast(@max(@min(r.status, 599), 100)), .ws_message, path, chain_ctx.correlation_id);
            const fw_seq = shipWsFrames(worker, conn_ent, &stream_chunks, &chunk_opcodes, &p.ws, p.txn, &p.txn_owned, chain_ctx.tenant_id, &p.readset, lh, true) catch |perr| {
                std.log.warn("rove-js ws-message (terminal+writes): propose failed: {s}", .{@errorName(perr)});
                p.txn_done = true;
                captureLogWithId(worker, chain_ctx.tenant_id, p.request_id, "POST", path, "", tc.snap.deployment_id, p.now_ns, 500, .fault, &.{}, &.{}, .{}, chain_ctx.correlation_id, .ws_message, 0);
                tearDownWsChain(worker, conn_ent);
                return;
            };
            p.txn_done = true;
            const st: u16 = @intCast(@max(@min(r.status, 599), 100));
            captureLogWithId(worker, chain_ctx.tenant_id, p.request_id, "POST", path, "", tc.snap.deployment_id, p.now_ns, st, .ok, r.console, r.exception, .{}, chain_ctx.correlation_id, .ws_message, fw_seq);
            r.console = &.{};
            r.exception = &.{};
            tearDownWsChain(worker, conn_ent);
        },
        .continuation => |*cval| {
            const lh = worker_streaming.fireLogHeader(p.request_id, tc.snap.deployment_id, 200, .ws_message, path, chain_ctx.correlation_id);
            const fw_seq = shipWsFrames(worker, conn_ent, &stream_chunks, &chunk_opcodes, &p.ws, p.txn, &p.txn_owned, chain_ctx.tenant_id, &p.readset, lh, false) catch |perr| {
                std.log.warn("rove-js ws-message (next+writes): propose failed: {s}", .{@errorName(perr)});
                p.txn_done = true;
                cval.deinit(allocator);
                captureLogWithId(worker, chain_ctx.tenant_id, p.request_id, "POST", path, "", tc.snap.deployment_id, p.now_ns, 500, .fault, &.{}, &.{}, .{}, chain_ctx.correlation_id, .ws_message, 0);
                effect_mod.cmd.emitWsSend(worker, .{ .conn_entity = conn_ent, .opcode = 8, .bytes = &.{} }) catch {};
                tearDownWsChain(worker, conn_ent);
                return;
            };
            p.txn_done = true;
            // next(): keep the chain parked; thread the new ctx forward.
            if (chain_st.ctx_json.len > 0) allocator.free(chain_st.ctx_json);
            chain_st.ctx_json = cval.ctx_json;
            cval.ctx_json = &.{};
            chain_st.activation_count += 1;
            cval.deinit(allocator);
            // §4.5 input gate: this frame's output is commit-gated (real
            // writes, or the read-only speculation barrier) — close the
            // gate so later frames queue behind it in arrival order.
            if (fw_seq != 0) armWsGate(worker, conn_ent, chain_ctx.tenant_id, fw_seq);
            captureLogWithId(worker, chain_ctx.tenant_id, p.request_id, "POST", path, "", tc.snap.deployment_id, p.now_ns, 200, .ok, &.{}, &.{}, .{}, chain_ctx.correlation_id, .ws_message, fw_seq);
        },
        .stream => |*s2| {
            // A streamed-response descriptor from a WS frame is out of scope
            // (the connection IS the stream): roll back, close, tear down.
            s2.deinit(allocator);
            p.txn.rollback() catch {};
            p.txn_done = true;
            captureLogWithId(worker, chain_ctx.tenant_id, p.request_id, "POST", path, "", tc.snap.deployment_id, p.now_ns, 501, .handler_error, &.{}, &.{}, .{}, chain_ctx.correlation_id, .ws_message, 0);
            effect_mod.cmd.emitWsSend(worker, .{ .conn_entity = conn_ent, .opcode = 8, .bytes = &.{} }) catch {};
            tearDownWsChain(worker, conn_ent);
        },
        // Only `.inbound_headers` / `.inbound_chunk` activations
        // produce these; WS frames never dispatch as one. Defined
        // failure: close + tear down.
        .no_onheaders, .no_onchunk => {
            p.txn.rollback() catch {};
            p.txn_done = true;
            captureLogWithId(worker, chain_ctx.tenant_id, p.request_id, "POST", path, "", tc.snap.deployment_id, p.now_ns, 500, .handler_error, &.{}, &.{}, .{}, chain_ctx.correlation_id, .ws_message, 0);
            effect_mod.cmd.emitWsSend(worker, .{ .conn_entity = conn_ent, .opcode = 8, .bytes = &.{} }) catch {};
            tearDownWsChain(worker, conn_ent);
        },
    }
}

/// Ship the frames an `onMessage` produced to `ws_send_in`. Read-only frames
/// emit inline (committed now). A writing frame stages its frames (+ a
/// trailing Close when `close`) as commit-gated `ws_send` Cmds via
/// `proposeForgetfulWrites`, so they reach the wire only after the writeset
/// commits (batch-of-1 durability). Consumes both lists; on the write path
/// transfers the txn to the parked unit (clears `txn_owned`). Returns the
/// propose seq (0 on the read-only path).
fn shipWsFrames(
    worker: anytype,
    conn_ent: rove.Entity,
    chunks: *std.ArrayListUnmanaged([]u8),
    opcodes: *std.ArrayListUnmanaged(u8),
    writeset: *const kv_mod.WriteSet,
    txn: *kv_mod.KvStore.TrackedTxn,
    txn_owned: *bool,
    tenant_id: []const u8,
    readset: *const tape_mod.Readset,
    log_header: log_mod.LogHeader,
    close: bool,
) !u64 {
    const allocator = worker.allocator;
    if (writeset.ops.items.len == 0) {
        // Read-only frame: try the inline fast path — commit now, emit now.
        // `Conflict` here is kvexp `NotChainHead`: the txn READ a chain
        // predecessor's still-uncommitted overlay (`saw_speculation`), so
        // the frames were computed on un-durable state. That is the
        // idiom-0 read-side hazard (worker_dispatch.zig:707) in WS form —
        // fall through to the commit-gated path below, which proposes an
        // empty-writeset BARRIER and ships the frames only once the chain
        // commits. Reachable only when the txn was opened on a read that
        // crossed an in-flight write from another producer (the §4.5
        // input gate already serializes this connection's own writes).
        if (txn.commit()) |_| {
            for (chunks.items, 0..) |bytes, i| {
                const op: u8 = if (i < opcodes.items.len) opcodes.items[i] else 1;
                effect_mod.cmd.emitWsSend(worker, .{ .conn_entity = conn_ent, .opcode = op, .bytes = bytes }) catch {
                    if (bytes.len > 0) allocator.free(bytes);
                };
            }
            chunks.clearRetainingCapacity(); // ownership transferred (or freed on error)
            opcodes.clearRetainingCapacity();
            if (close) {
                effect_mod.cmd.emitWsSend(worker, .{ .conn_entity = conn_ent, .opcode = 8, .bytes = &.{} }) catch {};
            }
            return 0;
        } else |e| switch (e) {
            error.Conflict => {}, // speculation barrier below
            else => panic_mod.invariantViolated(
                "fireWsMessage.commit(read-only)",
                "err={s}",
                .{@errorName(e)},
            ),
        }
    }
    // Commit-gated path: real writes, or the read-only speculation barrier.
    var stage: StreamResumeStage = .{
        .entity = rove.Entity.nil,
        .ws_conn = conn_ent,
        .mark_draining = close,
    };
    stage.chunks = chunks.*;
    chunks.* = .empty;
    stage.ws_opcodes = opcodes.*;
    opcodes.* = .empty;
    defer {
        for (stage.chunks.items) |c| allocator.free(c);
        stage.chunks.deinit(allocator);
        stage.ws_opcodes.deinit(allocator);
    }
    const seq = proposeForgetfulWrites(worker, writeset, txn, tenant_id, &stage, null, readset, log_header) catch |err| {
        txn_owned.* = false; // helper rolled back + destroyed the txn
        return err;
    };
    txn_owned.* = false;
    return seq;
}

/// Run an `onDisconnect` activation for a held WS chain (client close or conn
/// death). Mirrors `fireDisconnectActivation` but reads the chain off
/// `parked_continuations` and never ships output (the socket is gone / the
/// transport already echoed the Close). Writes commit asynchronously via
/// `proposeForgetfulWrites` so cleanup side effects still land. The caller
/// tears the chain down afterward.
fn fireWsDisconnect(worker: anytype, chain_ent: rove.Entity) void {
    const allocator = worker.allocator;
    const server = worker.h2;
    const chain_ctx = server.reg.get(chain_ent, &worker.parked_continuations, components_mod.ChainContext) catch return;
    const chain_st = server.reg.get(chain_ent, &worker.parked_continuations, components_mod.StreamChain) catch return;

    const path = chain_st.module_path;
    var p = worker_streaming.firePrep(worker, chain_ctx.tenant_id, path, "ws-disconnect") orelse return;
    defer p.deinit(allocator);
    const tc = p.dep.tc;

    const body = std.fmt.allocPrint(allocator, "{{\"ctx\":{s}}}", .{chain_st.ctx_json}) catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{path}) catch return;
    defer allocator.free(spath);

    const request: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        .activation = .disconnect,
        .trace = .{ .readset = &p.readset, .request_id = p.request_id, .correlation_id = chain_ctx.correlation_id },
        .plan = .{ .limiter = &worker.limiter, .instance_id = p.dep.inst.id, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = p.dep.inst.platform },
    };
    var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
    const run_oc = worker.dispatcher.runOutcome(
        p.dep.inst.kv,
        p.txn,
        &p.ws,
        p.dep.bc,
        &tc.snap.bytecodes,
        &tc.snap.source_hashes,
        tc.snap.triggers,
        request,
        &budget,
    ) catch {
        p.txn.rollback() catch {};
        p.txn_done = true;
        captureLogWithId(worker, chain_ctx.tenant_id, p.request_id, "POST", path, "", tc.snap.deployment_id, p.now_ns, 500, .handler_error, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect, 0);
        return;
    };

    const wrote = p.ws.ops.items.len > 0;
    var oc = run_oc;
    // The handler's return shape is moot — the socket is gone. Deinit
    // whatever it produced; commit any writes (async, nobody waits).
    switch (oc) {
        .terminal => |*r| r.deinit(allocator),
        .continuation => |*cval| cval.deinit(allocator),
        .stream => |*s2| s2.deinit(allocator),
        .no_onheaders, .no_onchunk => {},
    }
    if (wrote) {
        const lh = worker_streaming.fireLogHeader(p.request_id, tc.snap.deployment_id, 200, .disconnect, path, chain_ctx.correlation_id);
        _ = proposeForgetfulWrites(worker, &p.ws, p.txn, chain_ctx.tenant_id, null, null, &p.readset, lh) catch |perr| {
            std.log.warn("rove-js ws-disconnect: propose failed: {s}", .{@errorName(perr)});
            p.txn_owned = false;
            p.txn_done = true;
            captureLogWithId(worker, chain_ctx.tenant_id, p.request_id, "POST", path, "", tc.snap.deployment_id, p.now_ns, 500, .fault, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect, 0);
            return;
        };
        p.txn_owned = false;
        p.txn_done = true;
        captureLogWithId(worker, chain_ctx.tenant_id, p.request_id, "POST", path, "", tc.snap.deployment_id, p.now_ns, 200, .ok, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect, 0);
        return;
    }
    p.txn.commit() catch |e| switch (e) {
        // kvexp NotChainHead: a read crossed an in-flight predecessor's
        // overlay. onDisconnect ships nothing (the socket is gone), so a
        // speculative read-only txn has nothing to gate — just roll it
        // back; nothing durable is lost.
        error.Conflict => p.txn.rollback() catch {},
        else => panic_mod.invariantViolated(
            "fireWsDisconnect.commit",
            "err={s}",
            .{@errorName(e)},
        ),
    };
    p.txn_done = true;
    captureLogWithId(worker, chain_ctx.tenant_id, p.request_id, "POST", path, "", tc.snap.deployment_id, p.now_ns, 200, .ok, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect, 0);
}
