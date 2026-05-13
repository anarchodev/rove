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
const schedule_server = @import("rove-schedule-server");
const panic_mod = @import("panic.zig");
const deployment_loader_mod = @import("deployment_loader.zig");

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
    /// Type 3 (`files_writeset`) was retired in Phase 5.5(e)
    /// F2-storage. Manifests live in a per-tenant `deployments/`
    /// BlobBackend (shared via fs/s3 between leader + followers);
    /// the runtime release pointer (`_deploy/current` in the
    /// tenant's app.db) rides envelope 0 alongside the customer's
    /// own kv writes. The decoder rejects type=3 with
    /// `UnknownEnvelopeType` so any old log entries from a
    /// pre-F2-storage deploy will trip the apply panic at startup
    /// — that's deliberate; the migration window predates 1.0.
    /// Slots 4 / 5 / 6 (`webhook_enqueue_batch`,
    /// `webhook_complete`, `webhook_retry_schedule`) retired with
    /// the rove-webhook-server module. webhook.send is now a JS
    /// polyfill on top of http.send (envelope 8 / 9 / 10). The
    /// decoder rejects type=4/5/6 with `UnknownEnvelopeType` so
    /// any old log entries from the pre-retirement window trip the
    /// apply panic at startup — deliberate; the migration window
    /// predates 1.0. Slot 7 (`multi` pre-renumber) is also retired
    /// here; the new value lives at type 1.
    /// http.send (docs/http-send-plan.md). Payload is a
    /// `schedule_server.encodeUpsertBatch` blob; apply UPSERTs each
    /// row into `{data_dir}/schedules.db`, bumping `version` on
    /// existing rows. Applied on both leader and follower (the
    /// dispatcher proposes without pre-writing).
    schedule_upsert = 8,
    /// http.send completion. Payload is a
    /// `schedule_server.encodeComplete` blob; apply checks
    /// `version_at_fire` matches the row's current `version`. On
    /// match, writes `_callback/{id}` into the tenant's app.db and
    /// DELETEs from schedules.db. On mismatch, the envelope is
    /// silently dropped (the row was overwritten while firing —
    /// plan §7). Applied on both leader and follower.
    schedule_complete = 9,
    /// http.cancel. Payload is a `schedule_server.encodeCancelBatch`
    /// blob; apply DELETEs each `(tenant_id, id)` from
    /// schedules.db. Idempotent (missing row is a no-op). Applied
    /// on both leader and follower.
    schedule_cancel = 10,
    /// Internal-pool → external-pool transfer (plan §3.2). The
    /// worker phase couldn't serve an `is_internal=true` row
    /// in-process and is asking apply to flip `is_internal=false`
    /// so the libcurl thread can fire it. Payload is one
    /// `schedule_server.DemoteTarget` (tenant_id, id). Idempotent:
    /// missing row or already-external row is a no-op. Applied on
    /// both leader and follower.
    schedule_demote = 11,
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

/// Build a schedule_upsert envelope (type=8). `payload` is a
/// `schedule_server.encodeUpsertBatch` blob. instance_id is empty —
/// schedules.db is cluster-wide; per-row tenant scoping rides in
/// the payload.
pub fn encodeScheduleUpsertEnvelope(
    allocator: std.mem.Allocator,
    payload: []const u8,
) ![]u8 {
    return encodeTyped(allocator, .schedule_upsert, "", payload);
}

/// Build a schedule_complete envelope (type=9). `instance_id` is
/// the tenant id whose app.db will receive the `_callback/{id}`
/// write on a version match.
pub fn encodeScheduleCompleteEnvelope(
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
    payload: []const u8,
) ![]u8 {
    return encodeTyped(allocator, .schedule_complete, tenant_id, payload);
}

/// Build a schedule_cancel envelope (type=10). `payload` is a
/// `schedule_server.encodeCancelBatch` blob. instance_id is empty —
/// per-target tenant scoping rides in the payload.
pub fn encodeScheduleCancelEnvelope(
    allocator: std.mem.Allocator,
    payload: []const u8,
) ![]u8 {
    return encodeTyped(allocator, .schedule_cancel, "", payload);
}

/// Build a schedule_demote envelope (type=11). `payload` is one
/// `schedule_server.encodeDemote` blob. instance_id is empty —
/// the tenant scoping rides in the payload tuple.
pub fn encodeScheduleDemoteEnvelope(
    allocator: std.mem.Allocator,
    payload: []const u8,
) ![]u8 {
    return encodeTyped(allocator, .schedule_demote, "", payload);
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
    /// Lazy schedules.db handle. Opens on first envelope-8/9/10/11
    /// apply.
    schedules_store: ?*schedule_server.ScheduleStore = null,
    schedule_wake: ?*std.Thread.ResetEvent = null,
    worker_phase_wake: ?*std.Thread.ResetEvent = null,
    public_suffix: ?[]const u8 = null,
    deployment_loader: ?*deployment_loader_mod.DeploymentLoader = null,

    pub fn init(allocator: std.mem.Allocator) Loop46Ctx {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Loop46Ctx) void {
        // `schedules_store` is owned by the caller (main.zig opens it
        // once and threads the pointer in). We just borrow.
        _ = self;
    }

    /// Return the process-shared schedule store. Set once at startup
    /// in main.zig before any envelope-8/9/10/11 applies can fire.
    /// `data_dir` is accepted (and unused) so the call site doesn't
    /// have to change.
    fn getSchedules(self: *Loop46Ctx, data_dir: []const u8) !*schedule_server.ScheduleStore {
        _ = data_dir;
        return self.schedules_store orelse panic_mod.invariantViolated(
            "apply.getSchedules",
            "schedules_store not set on Loop46Ctx",
            .{},
        );
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
    if (ctx.deployment_loader) |loader| {
        if (kv.scanWriteSetPutValue(env.payload, "_deploy/current")) |hex_bytes| {
            const dep_id = std.fmt.parseInt(u64, hex_bytes, 16) catch return;
            loader.enqueue(env.id, dep_id) catch |err| std.log.warn(
                "applyWriteSet: deployment loader enqueue {s}/{d} failed: {s}",
                .{ env.id, dep_id, @errorName(err) },
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

/// http.send envelope-8 apply (schedule_upsert). UPSERTs each row
/// into `schedules.db` (bumping `version` on existing rows) and
/// wakes the leader-pinned scheduler thread when wired.
/// http.send envelope-8 apply (schedule_upsert). UPSERTs each row
/// into `schedules.db` (bumping `version` on existing rows) and
/// wakes the leader-pinned scheduler thread when wired. Applied on
/// both leader and follower (`leader_skip = false`).
pub fn applyScheduleUpsertBatch(
    cluster: *kv.Cluster,
    env: kv.Envelope,
    entry_idx: u64,
    inside_multi: bool,
    user_ctx: ?*anyopaque,
) kv.ClusterApplyError!void {
    _ = entry_idx;
    _ = inside_multi;
    std.debug.assert(env.id.len == 0);

    const ctx = loop46Ctx(user_ctx);
    const store = ctx.getSchedules(cluster.data_dir) catch |err| panic_mod.invariantViolated(
        "applyScheduleUpsertBatch.getSchedules",
        "err={s}",
        .{@errorName(err)},
    );

    const rows = schedule_server.decodeUpsertBatch(ctx.allocator, env.payload) catch |err|
        panic_mod.invariantViolated(
            "applyScheduleUpsertBatch.decode",
            "err={s}",
            .{@errorName(err)},
        );
    defer {
        for (rows) |*r| r.deinit(ctx.allocator);
        ctx.allocator.free(rows);
    }

    // Internal-target stamping (plan §3.2). Each node runs the same
    // detection against the same root-store membership + same suffix,
    // so all replicas agree on `is_internal` for every row.
    var has_external = false;
    var has_internal = false;
    for (rows) |*r| {
        r.is_internal = detectInternalTarget(cluster, ctx, r.url);
        if (r.is_internal) has_internal = true else has_external = true;
    }

    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    store.applyUpsertBatch(rows, now_ns) catch |err| panic_mod.invariantViolated(
        "applyScheduleUpsertBatch.apply",
        "err={s}",
        .{@errorName(err)},
    );

    if (has_external) if (ctx.schedule_wake) |w| w.set();
    if (has_internal) if (ctx.worker_phase_wake) |w| w.set();
}

/// True when `url` parses as `{id}.{public_suffix}` AND `{id}` has a
/// registered existence marker in __root__.db. Returns false when
/// `public_suffix` isn't wired (CLI smokes, single-tenant dev) — that's
/// the "not running on a cluster" path where every URL is external.
/// Also returns false on parse / membership errors: detection is
/// best-effort.
fn detectInternalTarget(cluster: *kv.Cluster, ctx: *Loop46Ctx, url: []const u8) bool {
    const suffix = ctx.public_suffix orelse return false;
    if (suffix.len == 0) return false;
    const id = schedule_server.internal_routing.parseInstanceId(url, suffix) orelse return false;
    const root = cluster.openRoot() catch return false;
    var key_buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "instance/{s}", .{id}) catch return false;
    const v = root.get(key) catch |err| switch (err) {
        error.NotFound => return false,
        else => return false,
    };
    ctx.allocator.free(v);
    return true;
}

/// http.send envelope-9 apply (schedule_complete). On version match,
/// stashes a callback row in schedules.db's `c/{tenant_id}/{id}` and
/// DELETEs the schedule row. Stale envelopes (superseded fires)
/// silently dropped. Applied on both leader and follower.
pub fn applyScheduleComplete(
    cluster: *kv.Cluster,
    env: kv.Envelope,
    entry_idx: u64,
    inside_multi: bool,
    user_ctx: ?*anyopaque,
) kv.ClusterApplyError!void {
    _ = entry_idx;
    _ = inside_multi;

    const tenant_id = env.id;
    const ctx = loop46Ctx(user_ctx);

    var complete = schedule_server.decodeComplete(ctx.allocator, env.payload) catch |err|
        panic_mod.invariantViolated(
            "applyScheduleComplete.decode",
            "err={s}",
            .{@errorName(err)},
        );
    defer complete.deinit(ctx.allocator);

    const store = ctx.getSchedules(cluster.data_dir) catch |err| panic_mod.invariantViolated(
        "applyScheduleComplete.getSchedules",
        "err={s}",
        .{@errorName(err)},
    );

    var existing_opt = store.get(tenant_id, complete.id) catch |err|
        panic_mod.invariantViolated(
            "applyScheduleComplete.get",
            "tenant={s} err={s}",
            .{ tenant_id, @errorName(err) },
        );

    if (existing_opt) |*existing| {
        defer existing.deinit(ctx.allocator);

        if (existing.version != complete.version_at_fire) return;

        if (existing.row.on_result_module.len > 0) {
            const event_json = buildScheduleCallbackJson(
                ctx.allocator,
                &complete,
                existing,
            ) catch |err| panic_mod.invariantViolated(
                "applyScheduleComplete.buildCallback",
                "err={s}",
                .{@errorName(err)},
            );
            defer ctx.allocator.free(event_json);

            store.addPendingCallback(tenant_id, complete.id, event_json) catch |err|
                panic_mod.invariantViolated(
                    "applyScheduleComplete.addPendingCallback",
                    "tenant={s} err={s}",
                    .{ tenant_id, @errorName(err) },
                );
        }
    }

    _ = store.applyComplete(tenant_id, complete.id, complete.version_at_fire) catch |err|
        panic_mod.invariantViolated(
            "applyScheduleComplete.applyComplete",
            "err={s}",
            .{@errorName(err)},
        );
}

/// http.cancel envelope-10 apply (schedule_cancel). DELETEs each
/// `(tenant_id, id)` from schedules.db. Idempotent. Applied on both
/// leader and follower.
pub fn applyScheduleCancelBatch(
    cluster: *kv.Cluster,
    env: kv.Envelope,
    entry_idx: u64,
    inside_multi: bool,
    user_ctx: ?*anyopaque,
) kv.ClusterApplyError!void {
    _ = entry_idx;
    _ = inside_multi;
    std.debug.assert(env.id.len == 0);

    const ctx = loop46Ctx(user_ctx);
    const targets = schedule_server.decodeCancelBatch(ctx.allocator, env.payload) catch |err|
        panic_mod.invariantViolated(
            "applyScheduleCancelBatch.decode",
            "err={s}",
            .{@errorName(err)},
        );
    defer {
        for (targets) |*t| t.deinit(ctx.allocator);
        ctx.allocator.free(targets);
    }

    const store = ctx.getSchedules(cluster.data_dir) catch |err| panic_mod.invariantViolated(
        "applyScheduleCancelBatch.getSchedules",
        "err={s}",
        .{@errorName(err)},
    );

    for (targets) |t| {
        store.applyCancel(t.tenant_id, t.id) catch |err|
            panic_mod.invariantViolated(
                "applyScheduleCancelBatch.applyCancel",
                "tenant={s} id={s} err={s}",
                .{ t.tenant_id, t.id, @errorName(err) },
            );
    }
}

/// http.send envelope-11 apply (schedule_demote). Flips
/// `is_internal=false` so the libcurl scheduler thread can fire the
/// row. Idempotent. Applied on both leader and follower.
pub fn applyScheduleDemote(
    cluster: *kv.Cluster,
    env: kv.Envelope,
    entry_idx: u64,
    inside_multi: bool,
    user_ctx: ?*anyopaque,
) kv.ClusterApplyError!void {
    _ = entry_idx;
    _ = inside_multi;
    std.debug.assert(env.id.len == 0);

    const ctx = loop46Ctx(user_ctx);
    var target = schedule_server.decodeDemote(ctx.allocator, env.payload) catch |err|
        panic_mod.invariantViolated(
            "applyScheduleDemote.decode",
            "err={s}",
            .{@errorName(err)},
        );
    defer target.deinit(ctx.allocator);

    const store = ctx.getSchedules(cluster.data_dir) catch |err| panic_mod.invariantViolated(
        "applyScheduleDemote.getSchedules",
        "err={s}",
        .{@errorName(err)},
    );

    store.applyDemote(target.tenant_id, target.id) catch |err|
        panic_mod.invariantViolated(
            "applyScheduleDemote.applyDemote",
            "tenant={s} id={s} err={s}",
            .{ target.tenant_id, target.id, @errorName(err) },
        );

    if (ctx.schedule_wake) |w| w.set();
}

/// Build the `_callback/{id}` JSON event for an http.send delivery.
/// Schema (docs/http-send-plan.md §8):
///   { id, on_result, ok, status, body, error, context, version }
///
/// `ok` is `status >= 200 and status < 300 and error.len == 0` — the
/// dispatch consumer in `callback_dispatch.zig` parses with
/// `ignore_unknown_fields = true`, so customer JS sees this verbatim.
/// `version` rides through so customers can branch on "this is a
/// retry of a superseded fire" if they care.
fn buildScheduleCallbackJson(
    allocator: std.mem.Allocator,
    complete: *const schedule_server.CompleteEnvelope,
    stored: *const schedule_server.StoredSchedule,
) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
    const w = &aw.writer;

    const ok = complete.outcome == .delivered and
        complete.status >= 200 and
        complete.status < 300 and
        complete.error_message.len == 0;

    try w.writeAll("{\"id\":\"");
    try writeJsonString(w, complete.id);
    try w.writeAll("\",\"on_result\":");
    if (stored.row.on_result_module.len == 0) {
        try w.writeAll("null");
    } else {
        try w.writeByte('"');
        try writeJsonString(w, stored.row.on_result_module);
        try w.writeByte('"');
    }
    // on_result_fn / on_result_args ride alongside the module name
    // so callback_dispatch can synthesize a `?fn=&args=` query
    // string for the callback request. Empty fn = use the module's
    // default export with no JS args (today's behavior).
    if (stored.row.on_result_fn.len > 0) {
        try w.writeAll(",\"on_result_fn\":\"");
        try writeJsonString(w, stored.row.on_result_fn);
        try w.writeByte('"');
    }
    if (stored.row.on_result_args_json.len > 0) {
        try w.writeAll(",\"on_result_args\":");
        try w.writeAll(stored.row.on_result_args_json);
    }
    try w.print(",\"ok\":{},\"status\":{d},\"version\":{d},\"context\":", .{
        ok,
        complete.status,
        complete.version_at_fire,
    });
    if (stored.row.context_json.len == 0) {
        try w.writeAll("null");
    } else {
        try w.writeAll(stored.row.context_json);
    }

    try w.writeAll(",\"body\":\"");
    try writeJsonString(w, complete.response_body);
    try w.writeAll("\",\"error\":");
    if (complete.error_message.len == 0) {
        try w.writeAll("null");
    } else {
        try w.writeByte('"');
        try writeJsonString(w, complete.error_message);
        try w.writeByte('"');
    }
    try w.writeByte('}');
    return aw.toOwnedSlice();
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |b| switch (b) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{b}),
        else => try w.writeByte(b),
    };
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

test "schedule_upsert envelope encode/decode round trip" {
    const a = testing.allocator;
    const enc = try encodeScheduleUpsertEnvelope(a, "fake upsert bytes");
    defer a.free(enc);
    const dec = try decodeEnvelope(enc);
    try testing.expectEqual(EnvelopeType.schedule_upsert, dec.type);
    try testing.expectEqualStrings("", dec.instance_id);
    try testing.expectEqualStrings("fake upsert bytes", dec.payload);
}

test "schedule_complete envelope encode/decode round trip" {
    const a = testing.allocator;
    const enc = try encodeScheduleCompleteEnvelope(a, "acme", "fake complete bytes");
    defer a.free(enc);
    const dec = try decodeEnvelope(enc);
    try testing.expectEqual(EnvelopeType.schedule_complete, dec.type);
    try testing.expectEqualStrings("acme", dec.instance_id);
    try testing.expectEqualStrings("fake complete bytes", dec.payload);
}

test "schedule_cancel envelope encode/decode round trip" {
    const a = testing.allocator;
    const enc = try encodeScheduleCancelEnvelope(a, "fake cancel bytes");
    defer a.free(enc);
    const dec = try decodeEnvelope(enc);
    try testing.expectEqual(EnvelopeType.schedule_cancel, dec.type);
    try testing.expectEqualStrings("", dec.instance_id);
    try testing.expectEqualStrings("fake cancel bytes", dec.payload);
}

test "schedule_demote envelope encode/decode round trip" {
    const a = testing.allocator;
    const enc = try encodeScheduleDemoteEnvelope(a, "fake demote bytes");
    defer a.free(enc);
    const dec = try decodeEnvelope(enc);
    try testing.expectEqual(EnvelopeType.schedule_demote, dec.type);
    try testing.expectEqualStrings("", dec.instance_id);
    try testing.expectEqualStrings("fake demote bytes", dec.payload);
}

test "buildScheduleCallbackJson delivered shape" {
    const a = testing.allocator;
    var stored: schedule_server.StoredSchedule = .{
        .row = .{
            .tenant_id = "acme",
            .id = "reminder-1",
            .fire_at_ns = 0,
            .url = "https://x/",
            .method = "POST",
            .headers_json = "{}",
            .body = "",
            .timeout_ms = 30_000,
            .max_body_bytes = 256 * 1024,
            .on_result_module = "stripe_response",
            .context_json = "{\"order\":\"o-42\"}",
            .is_internal = false,
        },
        .version = 3,
        .inflight_until_ns = 0,
        .created_at_ns = 0,
    };
    const complete: schedule_server.CompleteEnvelope = .{
        .tenant_id = "acme",
        .id = "reminder-1",
        .version_at_fire = 3,
        .outcome = .delivered,
        .status = 200,
        .response_headers_json = "{}",
        .response_body = "{\"id\":\"ch_123\"}",
        .error_message = "",
    };
    const json = try buildScheduleCallbackJson(a, &complete, &stored);
    defer a.free(json);

    // Spot-check field shape — `ignore_unknown_fields:true` consumer
    // tolerates ordering, so just look for substrings.
    try testing.expect(std.mem.indexOf(u8, json, "\"id\":\"reminder-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"on_result\":\"stripe_response\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"status\":200") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"version\":3") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"context\":{\"order\":\"o-42\"}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"body\":\"{\\\"id\\\":\\\"ch_123\\\"}\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"error\":null") != null);
    // No on_result_fn / on_result_args fields when stored row had
    // empty defaults — keeps the JSON tight when fn dispatch isn't used.
    try testing.expect(std.mem.indexOf(u8, json, "\"on_result_fn\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"on_result_args\"") == null);
}

test "buildScheduleCallbackJson includes on_result_fn + on_result_args when set" {
    const a = testing.allocator;
    var stored: schedule_server.StoredSchedule = .{
        .row = .{
            .tenant_id = "acme",
            .id = "x",
            .fire_at_ns = 0,
            .url = "https://x/",
            .method = "POST",
            .headers_json = "{}",
            .body = "",
            .timeout_ms = 30_000,
            .max_body_bytes = 256 * 1024,
            .on_result_module = "stripe",
            .on_result_fn = "handleCharge",
            .on_result_args_json = "[42,\"subscription\"]",
            .context_json = "null",
            .is_internal = false,
        },
        .version = 1,
        .inflight_until_ns = 0,
        .created_at_ns = 0,
    };
    const complete: schedule_server.CompleteEnvelope = .{
        .tenant_id = "acme",
        .id = "x",
        .version_at_fire = 1,
        .outcome = .delivered,
        .status = 200,
        .response_headers_json = "",
        .response_body = "ok",
        .error_message = "",
    };
    const json = try buildScheduleCallbackJson(a, &complete, &stored);
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"on_result\":\"stripe\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"on_result_fn\":\"handleCharge\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"on_result_args\":[42,\"subscription\"]") != null);
}

test "buildScheduleCallbackJson failed shape carries error string + ok=false" {
    const a = testing.allocator;
    var stored: schedule_server.StoredSchedule = .{
        .row = .{
            .tenant_id = "acme",
            .id = "x",
            .fire_at_ns = 0,
            .url = "https://x/",
            .method = "POST",
            .headers_json = "{}",
            .body = "",
            .timeout_ms = 30_000,
            .max_body_bytes = 256 * 1024,
            .on_result_module = "h",
            .context_json = "null",
            .is_internal = false,
        },
        .version = 1,
        .inflight_until_ns = 0,
        .created_at_ns = 0,
    };
    const complete: schedule_server.CompleteEnvelope = .{
        .tenant_id = "acme",
        .id = "x",
        .version_at_fire = 1,
        .outcome = .failed,
        .status = 0,
        .response_headers_json = "",
        .response_body = "",
        .error_message = "tls: handshake failed",
    };
    const json = try buildScheduleCallbackJson(a, &complete, &stored);
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"ok\":false") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"error\":\"tls: handshake failed\"") != null);
}

test "multi envelope wraps + unwraps several inner envelopes" {
    const a = testing.allocator;
    const inner_ws = try encodeWriteSetEnvelope(a, "acme", "ws bytes");
    defer a.free(inner_ws);
    const inner_sched = try encodeScheduleUpsertEnvelope(a, "sched bytes");
    defer a.free(inner_sched);

    const wrapped = try encodeMultiEnvelope(a, &.{ inner_ws, inner_sched });
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
    try testing.expectEqual(EnvelopeType.schedule_upsert, e1.type);
    try testing.expectEqualStrings("", e1.instance_id);
    try testing.expectEqualStrings("sched bytes", e1.payload);
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

