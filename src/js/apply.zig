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
const webhook_server = @import("rove-webhook-server");
const schedule_server = @import("rove-schedule-server");
const panic_mod = @import("panic.zig");

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
    /// Phase 5.5 (d) — webhook enqueue batch. Payload is a
    /// `webhook_server.encodeEnqueueBatch` blob; apply INSERTs OR
    /// IGNOREs each row into `{data_dir}/webhooks.db`. Applied on both
    /// leader and follower (no leader-skip): the dispatcher proposes
    /// without pre-writing webhooks.db locally.
    webhook_enqueue_batch = 4,
    /// Phase 5.5 (d) — webhook completed. Payload is a
    /// `webhook_server.encodeComplete` blob; apply DELETEs from
    /// `webhooks.db` and writes `_callback/{id}` into the tenant's
    /// app.db. Applied on both leader and follower.
    webhook_complete = 5,
    /// Phase 5.5 (d) — webhook retry schedule. Payload is a
    /// `webhook_server.encodeRetrySchedule` blob; apply UPDATEs the
    /// row's attempts + next_attempt_at_ns in `webhooks.db`. Applied
    /// on both leader and follower.
    webhook_retry_schedule = 6,
    /// Phase 5.5 (d) — multi-envelope wrapper. Payload is
    /// `[u8 count][u32 inner_len][inner_envelope_bytes]{count}` where
    /// each inner envelope is a complete `[type][id_len][id][payload]`
    /// blob. Inner envelopes apply in order; nesting (a `multi` inside
    /// a `multi`) panics. The standard envelope `instance_id` is empty
    /// for type=7 — per-inner-envelope ids carry the real targets.
    multi = 7,
    /// http.send (docs/http-send-plan.md). Payload is a
    /// `schedule_server.encodeUpsertBatch` blob; apply UPSERTs each
    /// row into `{data_dir}/schedules.db`, bumping `version` on
    /// existing rows. Applied on both leader and follower (the
    /// dispatcher proposes without pre-writing). Transitional
    /// envelope number; collapses to 4 once webhook-server retires
    /// (plan §11 step 6).
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

/// Build a webhook enqueue batch envelope (type=4). `payload` is the
/// `webhook_server.encodeEnqueueBatch` body. instance_id is empty —
/// the webhooks store is cluster-wide, not per-tenant.
pub fn encodeWebhookEnqueueBatchEnvelope(
    allocator: std.mem.Allocator,
    payload: []const u8,
) ![]u8 {
    return encodeTyped(allocator, .webhook_enqueue_batch, "", payload);
}

/// Build a webhook-complete envelope (type=5). `instance_id` is the
/// tenant id whose app.db will receive the `_callback/{id}` write.
pub fn encodeWebhookCompleteEnvelope(
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
    payload: []const u8,
) ![]u8 {
    return encodeTyped(allocator, .webhook_complete, tenant_id, payload);
}

/// Build a webhook retry-schedule envelope (type=6). instance_id
/// empty — only webhooks.db is touched.
pub fn encodeWebhookRetryScheduleEnvelope(
    allocator: std.mem.Allocator,
    payload: []const u8,
) ![]u8 {
    return encodeTyped(allocator, .webhook_retry_schedule, "", payload);
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

/// Apply callback context — self-owning, raft-thread-local.
///
/// Holds lazy per-tenant sqlite connections that are opened on first
/// apply for each instance and cached for subsequent applies. These
/// are DISTINCT from any worker's connections; they exist solely for
/// the raft thread's use.
///
/// On the leader path, `applyWriteSet` short-circuits via
/// `raft.isLeader()`, so the cached stores stay idle — workers wrote
/// locally via their own connections, and the raft thread just
/// advances `committed_seq`. The caches come alive on followers,
/// where the raft thread is the sole writer.
///
/// Lifecycle: construct before starting the raft thread, `deinit`
/// after the raft thread has stopped. The caches are grown only by
/// the raft thread itself (via `applyOne`), so no locking is needed.
pub const ApplyCtx = struct {
    allocator: std.mem.Allocator,
    /// Root data dir. Per-tenant stores live at `{data_dir}/{id}/`.
    data_dir: []const u8,
    /// Used for the leader-skip check on every envelope type.
    raft: *kv.RaftNode,
    /// Lazy per-tenant KvStore cache (instance_id → *KvStore). Keys
    /// are owned copies of the instance id.
    kv_stores: std.StringHashMapUnmanaged(*kv.KvStore),
    /// Phase 5.5(c) — in-memory mirror of every per-tenant
    /// `_apply_state.last_applied_raft_idx` row. Seeded from disk on
    /// lazy open in `getKv`; bumped inside `applyWriteSet` after a
    /// successful apply. Used by the snapshot capture loop (next
    /// pickup) to decide whether a tenant's db needs re-VACUUM since
    /// the previous snapshot pass without a per-tenant SQLite query.
    /// Borrowed keys: each entry's key is the same allocator-owned
    /// string `kv_stores` holds, so the kv_stores map must outlive
    /// this one (deinit orders it accordingly).
    tenant_apply_idx: std.StringHashMapUnmanaged(u64) = .empty,
    /// Lazy root-store handle for `type=2 root_writeset` applies.
    /// Opens `{data_dir}/__root__.db` on first follower-side root
    /// apply. Null on the leader path (leader-skip fires before we'd
    /// open it) and on nodes that never see a root writeset.
    root_store: ?*kv.KvStore = null,
    /// In-memory mirror of `__root__.db`'s `_apply_state` row. Seeded
    /// from disk on `getRootKv`'s first call; bumped after each
    /// successful root apply. The capture loop uses this to skip
    /// re-VACUUM-ing the singleton root db when nothing has changed
    /// since the previous snapshot.
    root_apply_idx: u64 = 0,
    /// Lazy cluster-wide webhook store handle for `type=4/5/6` applies
    /// (Phase 5.5 d). Opens `{data_dir}/webhooks.db` on first webhook
    /// envelope. Unlike per-tenant stores this is shared across all
    /// tenants — there is exactly one webhooks.db per node, replicated
    /// to identical state via raft. Applied on BOTH leader and
    /// follower (no leader-skip): the proposer doesn't pre-write.
    webhooks_store: ?*webhook_server.WebhookStore = null,
    /// Wake signal for the leader-pinned webhook delivery thread. Set
    /// by `loop46/main.zig` after `webhook_server.thread.spawn`. When
    /// non-null, envelope-4 / envelope-6 apply paths fire it so the
    /// delivery loop picks the row up on the same apply tick instead
    /// of waiting out `poll_interval_ms`. Followers point at their
    /// own (idle) handle's wake — harmless: an idle thread that wakes,
    /// checks `isLeader == false`, and goes back to sleep.
    webhook_wake: ?*std.Thread.ResetEvent = null,
    /// Lazy cluster-wide schedule store handle for `type=8/9/10`
    /// applies (http.send / docs/http-send-plan.md). Opens
    /// `{data_dir}/schedules.db` on first schedule envelope. Same
    /// shape as `webhooks_store` above — single store per node,
    /// raft-replicated to identical state, applied on both leader
    /// and follower.
    schedules_store: ?*schedule_server.ScheduleStore = null,
    /// Wake signal for the leader-pinned scheduler thread. Same
    /// shape as `webhook_wake`. Set by loop46/main.zig once the
    /// scheduler thread spawns. Envelope-8 apply fires it so the
    /// scheduler picks fresh rows up on the apply tick instead of
    /// waiting out the next-due-or-poll deadline. Envelope-9 / 10
    /// don't fire it — completes / cancels reduce work, not add it.
    schedule_wake: ?*std.Thread.ResetEvent = null,

    pub fn init(
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        raft: *kv.RaftNode,
    ) ApplyCtx {
        return .{
            .allocator = allocator,
            .data_dir = data_dir,
            .raft = raft,
            .kv_stores = .empty,
        };
    }

    pub fn deinit(self: *ApplyCtx) void {
        // Drop the apply-idx mirror first — its keys are borrowed
        // from kv_stores entries that follow.
        self.tenant_apply_idx.deinit(self.allocator);

        var kv_it = self.kv_stores.iterator();
        while (kv_it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.*.close();
        }
        self.kv_stores.deinit(self.allocator);

        if (self.root_store) |s| s.close();
        if (self.webhooks_store) |s| {
            s.close();
            self.allocator.destroy(s);
        }
        if (self.schedules_store) |s| {
            s.close();
            self.allocator.destroy(s);
        }
    }

    /// Lazily open the cluster-wide `webhooks.db`. Returned pointer is
    /// owned by the context and stable for its lifetime. Reached on
    /// both leader and follower because envelope types 4/5/6 don't
    /// leader-skip.
    fn getWebhooks(self: *ApplyCtx) !*webhook_server.WebhookStore {
        if (self.webhooks_store) |existing| return existing;
        const path = try std.fmt.allocPrintSentinel(
            self.allocator,
            "{s}/webhooks.db",
            .{self.data_dir},
            0,
        );
        defer self.allocator.free(path);

        const ptr = try self.allocator.create(webhook_server.WebhookStore);
        errdefer self.allocator.destroy(ptr);
        ptr.* = try webhook_server.WebhookStore.open(self.allocator, path);
        self.webhooks_store = ptr;
        return ptr;
    }

    /// Lazily open the cluster-wide `schedules.db`. Same shape as
    /// `getWebhooks`. Reached on both leader and follower because
    /// envelope types 8/9/10 don't leader-skip.
    fn getSchedules(self: *ApplyCtx) !*schedule_server.ScheduleStore {
        if (self.schedules_store) |existing| return existing;
        const path = try std.fmt.allocPrintSentinel(
            self.allocator,
            "{s}/schedules.db",
            .{self.data_dir},
            0,
        );
        defer self.allocator.free(path);

        const ptr = try self.allocator.create(schedule_server.ScheduleStore);
        errdefer self.allocator.destroy(ptr);
        ptr.* = try schedule_server.ScheduleStore.open(self.allocator, path);
        self.schedules_store = ptr;
        return ptr;
    }

    /// Lazily open the follower's local copy of `__root__.db`. Returns
    /// the cached handle on subsequent calls. Reached on the
    /// follower path (`applyRootWriteSet` leader-skips before
    /// opening) and from the snapshot capture loop on the leader
    /// (which needs to VACUUM INTO root.db whether or not any
    /// follower-side apply has touched it).
    pub fn getRootKv(self: *ApplyCtx) !*kv.KvStore {
        if (self.root_store) |existing| return existing;
        const path = try std.fmt.allocPrintSentinel(
            self.allocator,
            "{s}/__root__.db",
            .{self.data_dir},
            0,
        );
        defer self.allocator.free(path);
        const store = try kv.KvStore.open(self.allocator, path);
        self.root_store = store;
        // Seed the in-memory mirror from disk so a node restart picks
        // up where it left off — the snapshot capture loop trusts the
        // mirror to decide whether root.db needs re-VACUUM.
        self.root_apply_idx = store.lastAppliedRaftIdx() catch 0;
        return store;
    }

    /// Lazily open this tenant's app.db kv store. The returned
    /// pointer is owned by the context and stable for the lifetime
    /// of the context. Public so the snapshot capture loop can
    /// warm the cache for tenants the apply path hasn't reached
    /// yet (e.g. dormant tenants that nonetheless need a snapshot
    /// entry per the always-refresh property).
    pub fn getKv(self: *ApplyCtx, instance_id: []const u8) !*kv.KvStore {
        if (self.kv_stores.get(instance_id)) |existing| return existing;

        // Lazy mkpath: on a follower, the per-tenant directory may
        // not exist yet. The leader's `tenant.createInstance` makes
        // it locally during signup, but followers only see the
        // resulting envelope 2 (root_writeset) — they never get a
        // signal to mkdir the per-tenant subdir. So when envelope
        // 0 lands here for a tenant whose dir doesn't exist,
        // SQLite's open fails. Make the dir on demand: it's
        // idempotent and matches the single-store-per-tenant
        // contract the worker already assumes.
        const inst_dir = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ self.data_dir, instance_id },
        );
        defer self.allocator.free(inst_dir);
        std.fs.cwd().makePath(inst_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const path = try std.fmt.allocPrintSentinel(
            self.allocator,
            "{s}/app.db",
            .{inst_dir},
            0,
        );
        defer self.allocator.free(path);

        const store = try kv.KvStore.open(self.allocator, path);
        errdefer store.close();

        const id_copy = try self.allocator.dupe(u8, instance_id);
        errdefer self.allocator.free(id_copy);

        try self.kv_stores.put(self.allocator, id_copy, store);
        // Seed the per-tenant mirror from disk. Borrowed key shares
        // the kv_stores allocation — see the field doc.
        const seeded = store.lastAppliedRaftIdx() catch 0;
        try self.tenant_apply_idx.put(self.allocator, id_copy, seeded);
        return store;
    }

    /// Bump the in-memory mirror after a successful tenant apply.
    /// Keyed by `instance_id`; expects `getKv` to have populated the
    /// entry already (which it does on first apply, since
    /// `applyWriteSet` calls `getKv` before this).
    fn noteTenantApplied(self: *ApplyCtx, instance_id: []const u8, idx: u64) void {
        if (self.tenant_apply_idx.getPtr(instance_id)) |slot| slot.* = idx;
    }

    /// Bump the in-memory root-db mirror.
    fn noteRootApplied(self: *ApplyCtx, idx: u64) void {
        self.root_apply_idx = idx;
    }

    /// Snapshot capture loop's read interface. Returns null when this
    /// node has never opened the named tenant's app.db (the in-memory
    /// mirror seeds lazily in `getKv`).
    pub fn tenantLastApplied(self: *const ApplyCtx, instance_id: []const u8) ?u64 {
        return self.tenant_apply_idx.get(instance_id);
    }

    pub fn rootLastApplied(self: *const ApplyCtx) u64 {
        return self.root_apply_idx;
    }

};

/// The function rove-kv's `RaftNode` calls for every committed entry
/// in `.opaque_bytes` apply mode. Dispatches on envelope type byte.
///
/// `entry_idx` is the raft log index of this committed entry. Phase
/// 5.5(c) snapshot model uses it as the per-store
/// `_apply_state.last_applied_raft_idx` stamp + filter so a follower
/// loaded from a snapshot at floor F can replay entries F+1..N
/// without re-applying anything already in the snapshot. Pre-snapshot
/// stores have `last_applied=0` so the filter is a no-op.
pub fn applyOne(
    entry_idx: u64,
    payload: []const u8,
    ctx_opaque: ?*anyopaque,
) void {
    const ctx: *ApplyCtx = @ptrCast(@alignCast(ctx_opaque.?));

    const env = decodeEnvelope(payload) catch |err| panic_mod.invariantViolated(
        "applyOne.decodeEnvelope",
        "err={s}",
        .{@errorName(err)},
    );

    dispatch(ctx, env, entry_idx, .top_level);
}

const NestingLevel = enum { top_level, inside_multi };

fn dispatch(ctx: *ApplyCtx, env: Envelope, entry_idx: u64, nesting: NestingLevel) void {
    switch (env.type) {
        .writeset => applyWriteSet(ctx, env, entry_idx),
        .root_writeset => applyRootWriteSet(ctx, env, entry_idx),
        .webhook_enqueue_batch => applyWebhookEnqueueBatch(ctx, env),
        .webhook_complete => applyWebhookComplete(ctx, env),
        .webhook_retry_schedule => applyWebhookRetrySchedule(ctx, env),
        .multi => {
            if (nesting == .inside_multi) panic_mod.invariantViolated(
                "applyOne.multi",
                "nested multi-envelope wrapper",
                .{},
            );
            applyMulti(ctx, env, entry_idx);
        },
        .schedule_upsert => applyScheduleUpsertBatch(ctx, env),
        .schedule_complete => applyScheduleComplete(ctx, env),
        .schedule_cancel => applyScheduleCancelBatch(ctx, env),
    }
}

fn applyWriteSet(ctx: *ApplyCtx, env: Envelope, entry_idx: u64) void {
    // Leader-skip: workers already wrote through their own
    // connections before proposing. On the leader, apply is a no-op
    // beyond advancing `committed_seq` (done by the caller).
    if (ctx.raft.isLeader()) return;

    const store = ctx.getKv(env.instance_id) catch |err| panic_mod.invariantViolated(
        "applyWriteSet.getKv",
        "tenant={s} err={s}",
        .{ env.instance_id, @errorName(err) },
    );

    // Snapshot-replay filter: if this store has already absorbed an
    // entry at this idx (via snapshot load or earlier apply), skip.
    // The stamp inside applyEncoded keeps the next write moving the
    // mark forward atomically with the writeset commit.
    const last = store.lastAppliedRaftIdx() catch |err| panic_mod.invariantViolated(
        "applyWriteSet.lastAppliedRaftIdx",
        "tenant={s} err={s}",
        .{ env.instance_id, @errorName(err) },
    );
    if (entry_idx <= last) return;

    kv.applyEncodedWriteSet(store, 0, env.payload, entry_idx) catch |err| panic_mod.invariantViolated(
        "applyWriteSet.applyEncodedWriteSet",
        "tenant={s} err={s}",
        .{ env.instance_id, @errorName(err) },
    );
    ctx.noteTenantApplied(env.instance_id, entry_idx);
}

/// Follower-only: decode the root writeset and apply it to this
/// node's copy of `__root__.db`. Leader-skip matches the per-tenant
/// path — the proposer already wrote locally before proposing, so
/// the leader's own raft-thread apply is a no-op.
fn applyRootWriteSet(ctx: *ApplyCtx, env: Envelope, entry_idx: u64) void {
    if (ctx.raft.isLeader()) return;
    std.debug.assert(env.instance_id.len == 0);

    const store = ctx.getRootKv() catch |err| panic_mod.invariantViolated(
        "applyRootWriteSet.getRootKv",
        "err={s}",
        .{@errorName(err)},
    );

    const last = store.lastAppliedRaftIdx() catch |err| panic_mod.invariantViolated(
        "applyRootWriteSet.lastAppliedRaftIdx",
        "err={s}",
        .{@errorName(err)},
    );
    if (entry_idx <= last) return;

    kv.applyEncodedWriteSet(store, 0, env.payload, entry_idx) catch |err| panic_mod.invariantViolated(
        "applyRootWriteSet.applyEncodedWriteSet",
        "err={s}",
        .{@errorName(err)},
    );
    ctx.noteRootApplied(entry_idx);
}

/// Phase 5.5 (d). No leader-skip: the dispatcher (step 4) proposes
/// envelope 4 alongside envelope 0 without pre-writing webhooks.db.
/// Both leader and follower apply against their local
/// `{data_dir}/webhooks.db`.
fn applyWebhookEnqueueBatch(ctx: *ApplyCtx, env: Envelope) void {
    std.debug.assert(env.instance_id.len == 0);

    const store = ctx.getWebhooks() catch |err| panic_mod.invariantViolated(
        "applyWebhookEnqueueBatch.getWebhooks",
        "err={s}",
        .{@errorName(err)},
    );

    const rows = webhook_server.decodeEnqueueBatch(ctx.allocator, env.payload) catch |err|
        panic_mod.invariantViolated(
            "applyWebhookEnqueueBatch.decode",
            "err={s}",
            .{@errorName(err)},
        );
    defer {
        for (rows) |*r| r.deinit(ctx.allocator);
        ctx.allocator.free(rows);
    }

    store.applyEnqueueBatch(rows) catch |err| panic_mod.invariantViolated(
        "applyWebhookEnqueueBatch.apply",
        "err={s}",
        .{@errorName(err)},
    );

    // Wake the delivery thread so it doesn't sit out the rest of its
    // poll interval. No-op when wake is unwired (test paths).
    if (ctx.webhook_wake) |w| w.set();
}

/// Phase 5.5 (d). Cross-db apply: writes `_callback/{id}` into the
/// tenant's app.db, then DELETEs the row from `webhooks.db`. Both
/// halves are idempotent (`INSERT OR REPLACE` and `DELETE … WHERE`),
/// so a partial-failure re-apply converges to the same state.
///
/// Order matters: tenant write FIRST, then webhooks delete. If we
/// crash between them, the next apply attempt re-reads the still-
/// present webhooks row and re-issues both writes.
///
/// On a fully idempotent re-apply (row already gone), we skip both
/// halves — the callback was written by the prior apply.
fn applyWebhookComplete(ctx: *ApplyCtx, env: Envelope) void {
    const tenant_id = env.instance_id;

    var complete = webhook_server.decodeComplete(ctx.allocator, env.payload) catch |err|
        panic_mod.invariantViolated(
            "applyWebhookComplete.decode",
            "err={s}",
            .{@errorName(err)},
        );
    defer complete.deinit(ctx.allocator);

    const store = ctx.getWebhooks() catch |err| panic_mod.invariantViolated(
        "applyWebhookComplete.getWebhooks",
        "err={s}",
        .{@errorName(err)},
    );

    var existing_opt = store.get(&complete.webhook_id_hex) catch |err|
        panic_mod.invariantViolated(
            "applyWebhookComplete.get",
            "err={s}",
            .{@errorName(err)},
        );
    if (existing_opt) |*existing| {
        defer existing.deinit(ctx.allocator);

        const callback_json = buildCallbackJson(
            ctx.allocator,
            &complete,
            existing,
        ) catch |err| panic_mod.invariantViolated(
            "applyWebhookComplete.buildCallback",
            "err={s}",
            .{@errorName(err)},
        );
        defer ctx.allocator.free(callback_json);

        const tenant_kv = ctx.getKv(tenant_id) catch |err|
            panic_mod.invariantViolated(
                "applyWebhookComplete.getKv",
                "tenant={s} err={s}",
                .{ tenant_id, @errorName(err) },
            );

        var key_buf: [10 + webhook_server.WEBHOOK_ID_HEX_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(
            &key_buf,
            "_callback/{s}",
            .{&complete.webhook_id_hex},
        ) catch |err| panic_mod.invariantViolated(
            "applyWebhookComplete.bufPrint",
            "err={s}",
            .{@errorName(err)},
        );
        tenant_kv.put(key, callback_json) catch |err|
            panic_mod.invariantViolated(
                "applyWebhookComplete.put",
                "tenant={s} err={s}",
                .{ tenant_id, @errorName(err) },
            );
    }

    store.applyComplete(&complete.webhook_id_hex) catch |err|
        panic_mod.invariantViolated(
            "applyWebhookComplete.delete",
            "err={s}",
            .{@errorName(err)},
        );
}

/// Phase 5.5 (d). Updates attempts + next_attempt_at_ns + clears the
/// inflight lease. Idempotent: missing row is a no-op (a racing
/// envelope 5 already won and removed it). No leader-skip.
fn applyWebhookRetrySchedule(ctx: *ApplyCtx, env: Envelope) void {
    std.debug.assert(env.instance_id.len == 0);

    const sched = webhook_server.decodeRetrySchedule(env.payload) catch |err|
        panic_mod.invariantViolated(
            "applyWebhookRetrySchedule.decode",
            "err={s}",
            .{@errorName(err)},
        );

    const store = ctx.getWebhooks() catch |err| panic_mod.invariantViolated(
        "applyWebhookRetrySchedule.getWebhooks",
        "err={s}",
        .{@errorName(err)},
    );

    store.applyRetrySchedule(
        &sched.webhook_id_hex,
        sched.attempts,
        sched.next_attempt_at_ns,
    ) catch |err| panic_mod.invariantViolated(
        "applyWebhookRetrySchedule.apply",
        "err={s}",
        .{@errorName(err)},
    );

    // Wake the delivery thread. Most retry schedules push
    // `next_attempt_at_ns` out into the future (exponential backoff),
    // so the immediate wake just lets the loop observe + return to
    // sleep — but that scan is what advances the in-flight set, and
    // some retries land with `next_attempt_at_ns ≈ now` (e.g. a peer
    // races an envelope-6 apply ahead of the leader's own attempt),
    // which we want to fire promptly.
    if (ctx.webhook_wake) |w| w.set();
}

/// Phase 5.5 (d). Multi-envelope wrapper: unwraps inner envelopes and
/// dispatches each. Inner envelopes apply in order. Nesting (multi
/// inside multi) panics in `dispatch`.
/// http.send envelope-8 apply (schedule_upsert). UPSERTs each row
/// into `schedules.db` (bumping `version` on existing rows) and
/// wakes the leader-pinned scheduler thread when wired.
fn applyScheduleUpsertBatch(ctx: *ApplyCtx, env: Envelope) void {
    std.debug.assert(env.instance_id.len == 0);

    const store = ctx.getSchedules() catch |err| panic_mod.invariantViolated(
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

    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    store.applyUpsertBatch(rows, now_ns) catch |err| panic_mod.invariantViolated(
        "applyScheduleUpsertBatch.apply",
        "err={s}",
        .{@errorName(err)},
    );

    if (ctx.schedule_wake) |w| w.set();
}

/// http.send envelope-9 apply (schedule_complete). Cross-db: on
/// version match, writes `_callback/{id}` into the tenant's app.db
/// AND deletes the row from schedules.db. On version mismatch
/// (the row was overwritten while firing — plan §7), silently
/// drops the envelope. Idempotent on missing row.
///
/// Order matters: tenant write FIRST, then schedules delete. Same
/// reasoning as `applyWebhookComplete`. Crash between them = the
/// next apply attempt re-reads the still-present schedule row and
/// re-issues both writes.
fn applyScheduleComplete(ctx: *ApplyCtx, env: Envelope) void {
    const tenant_id = env.instance_id;

    var complete = schedule_server.decodeComplete(ctx.allocator, env.payload) catch |err|
        panic_mod.invariantViolated(
            "applyScheduleComplete.decode",
            "err={s}",
            .{@errorName(err)},
        );
    defer complete.deinit(ctx.allocator);

    const store = ctx.getSchedules() catch |err| panic_mod.invariantViolated(
        "applyScheduleComplete.getSchedules",
        "err={s}",
        .{@errorName(err)},
    );

    // Pull the row to access on_result_module + context_json. The
    // version-check happens after we've read these so we don't pay
    // the JSON-build cost on a stale envelope.
    var existing_opt = store.get(tenant_id, complete.id) catch |err|
        panic_mod.invariantViolated(
            "applyScheduleComplete.get",
            "tenant={s} err={s}",
            .{ tenant_id, @errorName(err) },
        );

    if (existing_opt) |*existing| {
        defer existing.deinit(ctx.allocator);

        // Version check: the most-recently-scheduled version is
        // what fires. Stale envelopes from superseded fires are
        // silently dropped (plan §7).
        if (existing.version != complete.version_at_fire) return;

        // Skip the callback write when the customer set no
        // on_result module — fire-and-forget mode. Still falls
        // through to the schedules.db delete below.
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

            const tenant_kv = ctx.getKv(tenant_id) catch |err|
                panic_mod.invariantViolated(
                    "applyScheduleComplete.getKv",
                    "tenant={s} err={s}",
                    .{ tenant_id, @errorName(err) },
                );

            // _callback/{id} — id may be a customer handle (any
            // utf8 except NUL, up to 256 bytes) so allocate.
            const key = std.fmt.allocPrint(
                ctx.allocator,
                "_callback/{s}",
                .{complete.id},
            ) catch |err| panic_mod.invariantViolated(
                "applyScheduleComplete.allocPrint",
                "err={s}",
                .{@errorName(err)},
            );
            defer ctx.allocator.free(key);
            tenant_kv.put(key, event_json) catch |err|
                panic_mod.invariantViolated(
                    "applyScheduleComplete.put",
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
/// `(tenant_id, id)` from schedules.db. Idempotent: missing row is
/// a no-op (already fired or already cancelled — race fine).
/// Customer's on_result handler does NOT fire on cancel.
fn applyScheduleCancelBatch(ctx: *ApplyCtx, env: Envelope) void {
    std.debug.assert(env.instance_id.len == 0);

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

    const store = ctx.getSchedules() catch |err| panic_mod.invariantViolated(
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

fn applyMulti(ctx: *ApplyCtx, env: Envelope, entry_idx: u64) void {
    std.debug.assert(env.instance_id.len == 0);
    const inner = decodeMultiInner(ctx.allocator, env.payload) catch |err|
        panic_mod.invariantViolated(
            "applyMulti.decode",
            "err={s}",
            .{@errorName(err)},
        );
    defer ctx.allocator.free(inner);

    // Inner envelopes share the wrapper's raft entry idx — they
    // landed in the log atomically together, so a snapshot loaded
    // partway through the wrapper would either be missing the whole
    // multi or have it. Per-store filtering still applies inside
    // each inner dispatch.
    for (inner) |bytes| {
        const inner_env = decodeEnvelope(bytes) catch |err|
            panic_mod.invariantViolated(
                "applyMulti.decodeInner",
                "err={s}",
                .{@errorName(err)},
            );
        dispatch(ctx, inner_env, entry_idx, .inside_multi);
    }
}

/// Build the `_callback/{id}` JSON envelope written into the tenant's
/// app.db when a webhook reaches a terminal outcome. Schema:
/// webhook_id, on_result, outcome, attempts, context, plus either
/// `response` (delivered) or `error` (failed). The callback consumer
/// in `src/js/callback_dispatch.zig` parses this with
/// `ignore_unknown_fields = true`, so missing fields are tolerated.
/// (The historical drainer's `writeCallback` produced this same shape;
/// kept stable so existing customer `onResult` handlers see no change
/// across the Phase 5.5 (d) cutover.)
fn buildCallbackJson(
    allocator: std.mem.Allocator,
    complete: *const webhook_server.CompleteEnvelope,
    stored: *const webhook_server.StoredWebhook,
) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
    const w = &aw.writer;

    const outcome_str: []const u8 = switch (complete.outcome) {
        .delivered => "delivered",
        .failed => "failed",
    };

    try w.writeAll("{\"webhook_id\":\"");
    try w.writeAll(&complete.webhook_id_hex);
    try w.writeAll("\",\"on_result\":");
    if (stored.row.on_result_path.len == 0) {
        try w.writeAll("null");
    } else {
        try w.writeAll("\"");
        try writeJsonString(w, stored.row.on_result_path);
        try w.writeAll("\"");
    }
    try w.print(",\"outcome\":\"{s}\",\"attempts\":{d},\"context\":", .{
        outcome_str,
        complete.attempts,
    });
    if (stored.row.context_json.len == 0) {
        try w.writeAll("null");
    } else {
        try w.writeAll(stored.row.context_json);
    }

    switch (complete.outcome) {
        .delivered => {
            try w.print(",\"response\":{{\"status\":{d},\"body\":\"", .{complete.status});
            try writeJsonString(w, complete.response_body);
            try w.writeAll("\",\"truncated\":false}");
        },
        .failed => {
            try w.writeAll(",\"error\":\"delivery_failed\"");
        },
    }

    try w.writeAll("}");
    return aw.toOwnedSlice();
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

test "webhook_enqueue_batch envelope encode/decode round trip" {
    const a = testing.allocator;
    const inner = "fake encoded batch bytes";
    const enc = try encodeWebhookEnqueueBatchEnvelope(a, inner);
    defer a.free(enc);
    const dec = try decodeEnvelope(enc);
    try testing.expectEqual(EnvelopeType.webhook_enqueue_batch, dec.type);
    try testing.expectEqualStrings("", dec.instance_id);
    try testing.expectEqualStrings(inner, dec.payload);
}

test "webhook_complete envelope encode/decode round trip" {
    const a = testing.allocator;
    const enc = try encodeWebhookCompleteEnvelope(a, "acme", "fake complete bytes");
    defer a.free(enc);
    const dec = try decodeEnvelope(enc);
    try testing.expectEqual(EnvelopeType.webhook_complete, dec.type);
    try testing.expectEqualStrings("acme", dec.instance_id);
    try testing.expectEqualStrings("fake complete bytes", dec.payload);
}

test "webhook_retry_schedule envelope encode/decode round trip" {
    const a = testing.allocator;
    const enc = try encodeWebhookRetryScheduleEnvelope(a, "fake retry bytes");
    defer a.free(enc);
    const dec = try decodeEnvelope(enc);
    try testing.expectEqual(EnvelopeType.webhook_retry_schedule, dec.type);
    try testing.expectEqualStrings("", dec.instance_id);
    try testing.expectEqualStrings("fake retry bytes", dec.payload);
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
    const inner_wh = try encodeWebhookEnqueueBatchEnvelope(a, "wh bytes");
    defer a.free(inner_wh);

    const wrapped = try encodeMultiEnvelope(a, &.{ inner_ws, inner_wh });
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
    try testing.expectEqual(EnvelopeType.webhook_enqueue_batch, e1.type);
    try testing.expectEqualStrings("", e1.instance_id);
    try testing.expectEqualStrings("wh bytes", e1.payload);
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

test "buildCallbackJson delivered shape parses + carries fields" {
    const a = testing.allocator;
    const stored: webhook_server.StoredWebhook = .{
        .row = .{
            .webhook_id_hex = [_]u8{'a'} ** webhook_server.WEBHOOK_ID_HEX_LEN,
            .tenant_id = "acme",
            .url = "https://x.test/h",
            .method = "POST",
            .headers_json = "{}",
            .body = "",
            .max_attempts = 3,
            .timeout_ms = 1000,
            .retry_on_json = "[]",
            .context_json = "{\"chargeId\":\"ch_1\"}",
            .on_result_path = "stripe/charge_result",
            .enqueued_at_ns = 0,
        },
        .state = .pending,
        .next_attempt_at_ns = 0,
        .attempts = 1,
    };
    const complete: webhook_server.CompleteEnvelope = .{
        .webhook_id_hex = [_]u8{'a'} ** webhook_server.WEBHOOK_ID_HEX_LEN,
        .tenant_id = "acme",
        .outcome = .delivered,
        .attempts = 1,
        .status = 200,
        .response_headers_json = "{}",
        .response_body = "ok",
    };

    const json = try buildCallbackJson(a, &complete, &stored);
    defer a.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("delivered", obj.get("outcome").?.string);
    try testing.expectEqualStrings("stripe/charge_result", obj.get("on_result").?.string);
    try testing.expectEqual(@as(i64, 1), obj.get("attempts").?.integer);
    const ctx = obj.get("context").?.object;
    try testing.expectEqualStrings("ch_1", ctx.get("chargeId").?.string);
    const resp = obj.get("response").?.object;
    try testing.expectEqual(@as(i64, 200), resp.get("status").?.integer);
    try testing.expectEqualStrings("ok", resp.get("body").?.string);
}

test "buildCallbackJson failed shape carries error field" {
    const a = testing.allocator;
    const stored: webhook_server.StoredWebhook = .{
        .row = .{
            .webhook_id_hex = [_]u8{'b'} ** webhook_server.WEBHOOK_ID_HEX_LEN,
            .tenant_id = "acme",
            .url = "https://x.test/h",
            .method = "POST",
            .headers_json = "{}",
            .body = "",
            .max_attempts = 3,
            .timeout_ms = 1000,
            .retry_on_json = "[]",
            .context_json = "null",
            .on_result_path = "",
            .enqueued_at_ns = 0,
        },
        .state = .pending,
        .next_attempt_at_ns = 0,
        .attempts = 4,
    };
    const complete: webhook_server.CompleteEnvelope = .{
        .webhook_id_hex = [_]u8{'b'} ** webhook_server.WEBHOOK_ID_HEX_LEN,
        .tenant_id = "acme",
        .outcome = .failed,
        .attempts = 4,
        .status = 0,
        .response_headers_json = "",
        .response_body = "",
    };
    const json = try buildCallbackJson(a, &complete, &stored);
    defer a.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("failed", obj.get("outcome").?.string);
    try testing.expect(obj.get("on_result").? == .null);
    try testing.expectEqualStrings("delivery_failed", obj.get("error").?.string);
}
