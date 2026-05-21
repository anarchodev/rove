//! Apply callback for the worker's raft state machine.
//!
//! ## Wire format
//!
//! Every envelope the worker proposes is:
//!
//!   `[1B type][2B id_len BE][id bytes][payload]`
//!
//! `type=0` → per-tenant writeset (payload is `WriteSet.encode` bytes,
//!           target store = `{data_dir}/{id}/app.db`)
//! `type=2` → ROOT writeset (payload is `WriteSet.encode` bytes,
//!           target store = `{data_dir}/__root__.db`, id_len must
//!           be 0 — the envelope carries no per-tenant id)
//!
//! Types 1 (`log_batch`) and 3 (`files_writeset`) were retired in
//! Phase 5.5 (a) and 5.5 (e) F2-storage respectively. Log records
//! flow worker → S3 (sidecar + ndjson) directly; per-tenant
//! manifests live in a per-tenant `deployments/` BlobBackend, with
//! the runtime release pointer riding envelope 0 in the customer's
//! own app.db. The decoder rejects both values as
//! `UnknownEnvelopeType` so any stale entry in an old raft log
//! surfaces loudly instead of silently mis-applying.
//!
//! The `id` is the tenant `instance_id`. `id_len` caps at 64KB. The
//! trailing `payload` is whatever the dispatch callback for that
//! type knows how to decode.
//!
//! ## Dispatch by type
//!
//! - **type=0 writeset**: leader-skips (because the worker's open
//!   `TrackedTxn` already wrote locally), follower replays through
//!   `kv.applyEncodedWriteSet` against the apply context's own
//!   per-tenant kv store.
//!
//! ## Threading model — strict isolation from worker state
//!
//! `applyOne` runs on the raft thread. It must NOT reach into any
//! worker's per-tenant state — doing so would share NOMUTEX sqlite
//! connections between the raft thread and worker threads, which is
//! undefined behavior per sqlite's threading docs.
//!
//! Instead, `ApplyCtx` owns ITS OWN per-tenant store map (`kv_stores`),
//! opened lazily on first apply for each tenant. These connections
//! are raft-thread-local and never touched by any worker. They point
//! at the same sqlite files the workers use, but via independent
//! connections — WAL mode handles the coexistence.
//!
//! On the leader, the writeset apply short-circuits via the
//! leader-skip, so the raft-thread-owned connections stay idle. Cost
//! of an idle cached connection is a pair of fds per tenant;
//! acceptable.
//!
//! On followers, the raft thread is the only thread that writes
//! tenant state, so there is no contention to coordinate with.

const std = @import("std");
const kv = @import("rove-kv");
const panic_mod = @import("panic.zig");
const deployment_loader_mod = @import("deployment_loader.zig");
const send_dispatch_mod = @import("send_dispatch.zig");
const worker_mod = @import("worker.zig");

pub const Error = error{
    Truncated,
    UnknownInstance,
    UnknownEnvelopeType,
    ApplyFailed,
    NestedMulti,
};

pub const MAX_ID_LEN: usize = 256;

pub const EnvelopeType = enum(u8) {
    writeset = 0,
    /// Phase 5.5 (d) — multi-envelope wrapper. Payload is
    /// `[u8 count][u32 inner_len][inner_envelope_bytes]{count}` where
    /// each inner envelope is a complete `[type][id_len][id][payload]`
    /// blob. Inner envelopes apply in order; nesting (a `multi` inside
    /// a `multi`) panics. The standard envelope `instance_id` is empty
    /// for type=1 — per-inner-envelope ids carry the real targets.
    /// Numbered to match `kv.cluster.ENVELOPE_TYPE_MULTI` for the
    /// migration toward the shared Cluster library (raft-kv-design.md
    /// step 4). The previous value (7) is retired with the rest of
    /// the pre-migration types below.
    multi = 1,
    root_writeset = 2,
    // RETIRED SLOTS (not enum variants ⇒ `decodeEnvelope` rejects
    // them as `UnknownEnvelopeType`, so any stale raft-log entry
    // trips the apply panic at startup instead of silently
    // mis-applying — deliberate; every migration window predates 1.0):
    //   3        files_writeset (Phase 5.5(e) F2-storage; manifests
    //            now in a per-tenant deployments/ BlobBackend,
    //            `_deploy/current` rides envelope 0).
    //   4/5/6    webhook_{enqueue_batch,complete,retry_schedule}
    //            (rove-webhook-server retired; webhook.send is a JS
    //            polyfill over http.send).
    //   7        old `multi` pre-renumber (now type 1).
    //   8/9/10/11 schedule_{upsert,complete,cancel,demote} — RETIRED
    //            Option (b) 5b-2: the central schedule subsystem is
    //            dissolved; http.send writes per-tenant
    //            `_send/owed/`+`_send/proof/` riding envelope 0,
    //            fired/resolved by the per-node leader-local
    //            SendDispatch (no schedules.db, no leader-pinned
    //            schedule-server thread, no env-9 callback rows).
};

/// Build a writeset envelope. `id_len` and `id` plus a leading type=0
/// byte; payload is the writeset bytes.
pub fn encodeWriteSetEnvelope(
    allocator: std.mem.Allocator,
    id: []const u8,
    ws_bytes: []const u8,
) ![]u8 {
    return encodeTyped(allocator, .writeset, id, ws_bytes);
}

/// Build a root writeset envelope. type=2, no per-tenant id (id_len=0).
/// Applied to `{data_dir}/__root__.db` on followers. Used for writes
/// that update platform-level tables (tenant registry, domain
/// mappings) — signup's `tenant.createInstance` and the admin JS
/// handler's `platform.root.set/delete` collect their ops here.
pub fn encodeRootWriteSetEnvelope(
    allocator: std.mem.Allocator,
    ws_bytes: []const u8,
) ![]u8 {
    return encodeTyped(allocator, .root_writeset, "", ws_bytes);
}


/// Build a multi-envelope wrapper (type=7) carrying `inner` as already-
/// encoded inner envelopes. The wrapper's `instance_id` is empty;
/// real targets live on each inner envelope's id.
///
/// Inner envelopes must NOT themselves be type=7. The apply path
/// panics on nested multi to keep the recursion bounded.
///
/// Wire format (after the standard `[1B type=7][2B id_len=0]` header):
///   `[u8 count][ [u32 len][len bytes inner_envelope] ]{count}`
pub fn encodeMultiEnvelope(
    allocator: std.mem.Allocator,
    inner: []const []const u8,
) ![]u8 {
    if (inner.len > 0xff) return error.OutOfMemory;
    var inner_total: usize = 0;
    for (inner) |b| inner_total += 4 + b.len;
    const payload_len = 1 + inner_total;
    const total = 3 + payload_len;
    const out = try allocator.alloc(u8, total);
    out[0] = @intFromEnum(EnvelopeType.multi);
    std.mem.writeInt(u16, out[1..3], 0, .big);
    out[3] = @intCast(inner.len);
    var pos: usize = 4;
    for (inner) |b| {
        std.mem.writeInt(u32, out[pos..][0..4], @intCast(b.len), .little);
        pos += 4;
        @memcpy(out[pos..][0..b.len], b);
        pos += b.len;
    }
    return out;
}

/// Decode the inner-envelope byte slices from a type=7 wrapper's
/// payload (i.e., `Envelope.payload` for an envelope whose type is
/// `multi`). Returned slices alias the caller's payload buffer; do
/// not free individually. Caller frees the outer slice with
/// `allocator.free`.
pub fn decodeMultiInner(
    allocator: std.mem.Allocator,
    payload: []const u8,
) ![][]const u8 {
    if (payload.len < 1) return Error.Truncated;
    const count = payload[0];
    const out = try allocator.alloc([]const u8, count);
    errdefer allocator.free(out);
    var pos: usize = 1;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (payload.len < pos + 4) return Error.Truncated;
        const len = std.mem.readInt(u32, payload[pos..][0..4], .little);
        pos += 4;
        if (payload.len < pos + len) return Error.Truncated;
        out[i] = payload[pos .. pos + len];
        pos += len;
    }
    return out;
}

fn encodeTyped(
    allocator: std.mem.Allocator,
    t: EnvelopeType,
    id: []const u8,
    payload: []const u8,
) ![]u8 {
    if (id.len > MAX_ID_LEN) return error.OutOfMemory;
    const total = 1 + 2 + id.len + payload.len;
    const out = try allocator.alloc(u8, total);
    out[0] = @intFromEnum(t);
    std.mem.writeInt(u16, out[1..3], @intCast(id.len), .big);
    @memcpy(out[3 .. 3 + id.len], id);
    @memcpy(out[3 + id.len ..], payload);
    return out;
}

pub const Envelope = struct {
    type: EnvelopeType,
    instance_id: []const u8,
    payload: []const u8,
};

/// Decode an envelope. Slices into the input buffer; valid until the
/// caller drops `payload`.
pub fn decodeEnvelope(payload: []const u8) Error!Envelope {
    if (payload.len < 3) return Error.Truncated;
    const type_byte = payload[0];
    const t = std.meta.intToEnum(EnvelopeType, type_byte) catch
        return Error.UnknownEnvelopeType;
    const id_len = std.mem.readInt(u16, payload[1..3], .big);
    if (payload.len < 3 + @as(usize, id_len)) return Error.Truncated;
    return .{
        .type = t,
        .instance_id = payload[3 .. 3 + id_len],
        .payload = payload[3 + id_len ..],
    };
}

/// Loop46-specific apply state — auxiliary fields the library's
/// `kv.Cluster` doesn't know about. The cluster handles raft + per-
/// store cache + global_apply_idx + root_store; this struct carries
/// what's left over:
///
///   - `schedules_store` — singleton `schedules.db` handle. Custom
///     ScheduleStore type wraps a KvStore with typed queries; can't
///     route through `cluster.openStore` which returns raw `*KvStore`.
///   - Scheduler-wake signals (`schedule_wake`, `worker_phase_wake`)
///     for the libcurl scheduler thread and the worker-phase dispatch
///     loop respectively.
///   - `public_suffix` for `is_internal` tenant detection at
///     `applyScheduleUpsertBatch` time.
///   - `deployment_loader` for the follower-side `_deploy/current`
///     post-write hook in `applyWriteSet`.
///
/// Stash a pointer to this in `Cluster.Config.user_ctx`; handlers
/// cast back via `loop46Ctx(user_ctx)`.
pub const Loop46Ctx = struct {
    allocator: std.mem.Allocator,
    worker_phase_wake: ?*std.Thread.ResetEvent = null,
    public_suffix: ?[]const u8 = null,
    deployment_loader: ?*deployment_loader_mod.DeploymentLoader = null,
    /// Option (b) FORK-6' (4b-iv): the leader-local in-flight set's
    /// FOLLOWER feed. `applyWriteSet` is `leader_skip=true` → runs
    /// exactly on followers; it classifies the committed writeset's
    /// `_send/*` ops and enqueues arm/resolve here so every node
    /// keeps `armed` warm for instant failover (vs the 0.9–2.2 s/10k
    /// cold reconstruction). Null until `main.zig` wires it; null ⇒
    /// no follower feed (leader still fed worker-side via 4b-ii).
    send_dispatch: ?*send_dispatch_mod.SendDispatch = null,
    /// streaming-handlers-plan §4.6: pointer to the process-wide
    /// `NodeState` so `applyWriteSet` can broadcast kv-write events
    /// to every worker's `KvWakeInbox` after a follower-side apply.
    /// Borrowed; null on test paths that don't run the full worker
    /// stack. Type-erased to `*anyopaque` because `NodeState` is
    /// inside the rove-js module and apply.zig is part of the same
    /// module — the cast is local.
    node_state: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) Loop46Ctx {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Loop46Ctx) void {
        // `schedules_store` is owned by the caller (main.zig opens it
        // once and threads the pointer in). We just borrow.
        _ = self;
    }

};

fn loop46Ctx(user_ctx: ?*anyopaque) *Loop46Ctx {
    return @ptrCast(@alignCast(user_ctx orelse panic_mod.invariantViolated(
        "apply: missing user_ctx",
        "expected *Loop46Ctx",
        .{},
    )));
}

// ── Envelope handlers (library `ApplyFn` signature) ──────────────────
//
// Each handler is registered via `cluster.registerEnvelope(type, ...)`
// in loop46/main.zig. The library handles the global apply filter,
// envelope decode, leader_skip check, and multi-envelope unwrap; these
// handlers only see envelopes their type was registered for. The
// returned `ApplyError` (rare — these handlers panic on most errors)
// surfaces back to library which panics at `applyCallback`. Hot path
// is panic-free; errors here are invariant violations.

/// Per-tenant writeset (envelope type=0). Registered with
/// `leader_skip = true` — the worker already wrote locally via its
/// own TrackedTxn before proposing, so this only runs on followers.
/// Library attaches a store handle for `env.id` (hashed via
/// `kvstore.hashStoreId`) inside the cluster's node-wide kvexp
/// manifest at `{data_dir}/cluster.kv`.
pub fn applyWriteSet(
    cluster: *kv.Cluster,
    env: kv.Envelope,
    entry_idx: u64,
    inside_multi: bool,
    user_ctx: ?*anyopaque,
) kv.ClusterApplyError!void {
    _ = entry_idx;
    _ = inside_multi;

    const store = cluster.openStore(env.id) catch |err| switch (err) {
        error.OutOfMemory => return kv.ClusterApplyError.OutOfMemory,
        else => return kv.ClusterApplyError.Sqlite,
    };

    kv.applyEncodedWriteSet(store, 0, env.payload) catch |err| panic_mod.invariantViolated(
        "applyWriteSet.applyEncodedWriteSet",
        "tenant={s} err={s}",
        .{ env.id, @errorName(err) },
    );

    // Follower-side release propagation: if this writeset stamped
    // `_deploy/current`, the leader just published a new release for
    // this tenant. Enqueue the deployment loader so the follower's
    // worker has the new bytecode ready when traffic arrives. The
    // payload is `{N:0>16}` hex (16 chars); anything else is a
    // pre-existing kv write happening to use the same key (shouldn't
    // happen but we tolerate it by silently ignoring).
    const ctx = loop46Ctx(user_ctx);

    // Option (b) FORK-6' (4b-iv): follower feed for the leader-local
    // in-flight set. This runs on FOLLOWERS (applyWriteSet is
    // leader_skip=true) — the leader is fed worker-side at commit
    // (4b-ii). Classify this committed writeset's `_send/*` ops and
    // enqueue arm/resolve so the follower keeps `armed` warm for
    // instant failover. Cheap (dupe+mutex+wake on the thread-safe
    // queue; the SendDispatch thread drains, ungated). Best-effort:
    // classify/enqueue failure logs and the cold-start boot-scan
    // safety-net re-derives on a later promotion — no silent loss.
    if (ctx.send_dispatch) |sd| {
        var intents: std.ArrayListUnmanaged(send_dispatch_mod.SendIntent) = .empty;
        defer intents.deinit(ctx.allocator);
        send_dispatch_mod.classifyPayload(env.payload, ctx.allocator, &intents) catch {};
        for (intents.items) |it| switch (it) {
            .arm => |v| sd.enqueueArm(v.id, env.id, v.owed) catch |e|
                std.log.warn("applyWriteSet: send-dispatch arm {s}/{s}: {s}", .{ env.id, v.id, @errorName(e) }),
            .resolve => |rid| sd.enqueueResolve(rid) catch |e|
                std.log.warn("applyWriteSet: send-dispatch resolve {s}/{s}: {s}", .{ env.id, rid, @errorName(e) }),
        };
    }

    if (ctx.deployment_loader) |loader| {
        if (kv.scanWriteSetPutValue(env.payload, "_deploy/current")) |hex_bytes| {
            const dep_id = std.fmt.parseInt(u64, hex_bytes, 16) catch return;
            loader.enqueue(env.id, dep_id) catch |err| std.log.warn(
                "applyWriteSet: deployment loader enqueue {s}/{d} failed: {s}",
                .{ env.id, dep_id, @errorName(err) },
            );
        }
    }

    // streaming-handlers-plan §4.6: kv-write wake fan-out (follower
    // path). Decode the just-applied writeset's ops and broadcast
    // each `put`/`delete` to every worker's `KvWakeInbox`. The
    // worker's tick drain scans its stream-pipeline collections for
    // prefix matches and pushes a `WakeEntry` onto the §9.4
    // `pending_wakes` ring; the next `serviceParkedStreams` pass
    // fires `resumeStream(.wake_batch)` which drains the ring.
    // Best-effort: a per-event decode/push failure logs and we
    // continue — §9.4 "spurious + overflow" allows dropped wakes
    // (handler refetches authoritative state on its next run when
    // `lost_oldest > 0`).
    //
    // The leader-skipped property of `applyWriteSet` means this
    // hook only fires on followers; the leader-side mirror lives
    // in `worker_dispatch.zig`'s `finalizeBatch` (eager-fire on
    // local commit). Both paths broadcast to the SAME registry, so
    // single-node deployments and cross-node deployments converge
    // on identical wake semantics.
    if (ctx.node_state) |opaque_node| {
        var ops: std.ArrayListUnmanaged(kv.WriteSetOp) = .empty;
        defer ops.deinit(ctx.allocator);
        kv.decodeWriteSetOps(env.payload, ctx.allocator, &ops) catch |derr| {
            std.log.warn(
                "applyWriteSet: kv-wake decode tenant={s}: {s}; skipping wake fan-out",
                .{ env.id, @errorName(derr) },
            );
            return;
        };
        const ns: *worker_mod.NodeState = @ptrCast(@alignCast(opaque_node));
        var fired: usize = 0;
        for (ops.items) |op| switch (op) {
            .put => |p| {
                ns.broadcastKvWake(env.id, p.key, 'p');
                fired += 1;
            },
            .delete => |d| {
                ns.broadcastKvWake(env.id, d.key, 'd');
                fired += 1;
            },
        };
        if (fired > 0) {
            std.log.info(
                "rove-js kv-wake apply: tenant={s} fanned out {d} op(s) on follower",
                .{ env.id, fired },
            );
        }
    }
}

/// Root writeset (envelope type=2). Registered with
/// `leader_skip = true` — same model as the per-tenant writeset: the
/// worker (signup / admin handler `platform.root.*`) wrote to
/// `__root__.db` locally before proposing, so this only runs on
/// followers. Library opens via `cluster.openRoot()`.
pub fn applyRootWriteSet(
    cluster: *kv.Cluster,
    env: kv.Envelope,
    entry_idx: u64,
    inside_multi: bool,
    user_ctx: ?*anyopaque,
) kv.ClusterApplyError!void {
    _ = entry_idx;
    _ = inside_multi;
    _ = user_ctx;
    std.debug.assert(env.id.len == 0);

    const store = cluster.openRoot() catch |err| switch (err) {
        error.OutOfMemory => return kv.ClusterApplyError.OutOfMemory,
        else => return kv.ClusterApplyError.Sqlite,
    };

    kv.applyEncodedWriteSet(store, 0, env.payload) catch |err| panic_mod.invariantViolated(
        "applyRootWriteSet.applyEncodedWriteSet",
        "err={s}",
        .{@errorName(err)},
    );
}


// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "writeset envelope encode/decode round trip" {
    const id = "acme";
    const ws = "ws bytes here";
    const enc = try encodeWriteSetEnvelope(testing.allocator, id, ws);
    defer testing.allocator.free(enc);

    const dec = try decodeEnvelope(enc);
    try testing.expectEqual(EnvelopeType.writeset, dec.type);
    try testing.expectEqualStrings(id, dec.instance_id);
    try testing.expectEqualStrings(ws, dec.payload);
}

test "root writeset envelope encode/decode round trip" {
    const ws = "root ws bytes";
    const enc = try encodeRootWriteSetEnvelope(testing.allocator, ws);
    defer testing.allocator.free(enc);

    const dec = try decodeEnvelope(enc);
    try testing.expectEqual(EnvelopeType.root_writeset, dec.type);
    try testing.expectEqualStrings("", dec.instance_id);
    try testing.expectEqualStrings(ws, dec.payload);
}

test "decodeEnvelope rejects truncated input" {
    try testing.expectError(Error.Truncated, decodeEnvelope(""));
    try testing.expectError(Error.Truncated, decodeEnvelope(&[_]u8{0x00}));
    try testing.expectError(Error.Truncated, decodeEnvelope(&[_]u8{ 0x00, 0x00 }));
    // type=0, id_len=5 but no id bytes
    try testing.expectError(
        Error.Truncated,
        decodeEnvelope(&[_]u8{ 0x00, 0x00, 0x05 }),
    );
}

test "decodeEnvelope rejects unknown type" {
    try testing.expectError(
        Error.UnknownEnvelopeType,
        decodeEnvelope(&[_]u8{ 0xFF, 0x00, 0x00 }),
    );
}

test "decodeEnvelope handles empty payload" {
    const enc = try encodeWriteSetEnvelope(testing.allocator, "x", "");
    defer testing.allocator.free(enc);
    const dec = try decodeEnvelope(enc);
    try testing.expectEqual(EnvelopeType.writeset, dec.type);
    try testing.expectEqualStrings("x", dec.instance_id);
    try testing.expectEqualStrings("", dec.payload);
}

test "multi envelope wraps + unwraps several inner envelopes" {
    const a = testing.allocator;
    const inner_ws = try encodeWriteSetEnvelope(a, "acme", "ws bytes");
    defer a.free(inner_ws);
    const inner_root = try encodeRootWriteSetEnvelope(a, "root bytes");
    defer a.free(inner_root);

    const wrapped = try encodeMultiEnvelope(a, &.{ inner_ws, inner_root });
    defer a.free(wrapped);

    const outer = try decodeEnvelope(wrapped);
    try testing.expectEqual(EnvelopeType.multi, outer.type);
    try testing.expectEqualStrings("", outer.instance_id);

    const inner = try decodeMultiInner(a, outer.payload);
    defer a.free(inner);
    try testing.expectEqual(@as(usize, 2), inner.len);

    const e0 = try decodeEnvelope(inner[0]);
    try testing.expectEqual(EnvelopeType.writeset, e0.type);
    try testing.expectEqualStrings("acme", e0.instance_id);
    try testing.expectEqualStrings("ws bytes", e0.payload);

    const e1 = try decodeEnvelope(inner[1]);
    try testing.expectEqual(EnvelopeType.root_writeset, e1.type);
    try testing.expectEqualStrings("", e1.instance_id);
    try testing.expectEqualStrings("root bytes", e1.payload);
}

test "multi envelope with empty inner list" {
    const a = testing.allocator;
    const wrapped = try encodeMultiEnvelope(a, &.{});
    defer a.free(wrapped);
    const outer = try decodeEnvelope(wrapped);
    try testing.expectEqual(EnvelopeType.multi, outer.type);
    const inner = try decodeMultiInner(a, outer.payload);
    defer a.free(inner);
    try testing.expectEqual(@as(usize, 0), inner.len);
}

test "decodeMultiInner rejects truncated payload" {
    const a = testing.allocator;
    try testing.expectError(Error.Truncated, decodeMultiInner(a, ""));
    // count=1 but no length prefix
    try testing.expectError(Error.Truncated, decodeMultiInner(a, &[_]u8{1}));
    // count=1, length=10 but only 4 bytes follow
    try testing.expectError(
        Error.Truncated,
        decodeMultiInner(a, &[_]u8{ 1, 10, 0, 0, 0, 'a', 'b', 'c', 'd' }),
    );
}

