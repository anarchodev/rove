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
    /// Slots 4 / 5 / 6 (`webhook_enqueue_batch`,
    /// `webhook_complete`, `webhook_retry_schedule`) retired with
    /// the rove-webhook-server module. webhook.send is now a JS
    /// polyfill on top of http.send (envelope 8 / 9 / 10). The
    /// decoder rejects type=4/5/6 with `UnknownEnvelopeType` so
    /// any old log entries from the pre-retirement window trip the
    /// apply panic at startup — deliberate; the migration window
    /// predates 1.0.
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
    /// Lazy cluster-wide schedule store handle for `type=8/9/10/11`
    /// applies (http.send / docs/http-send-plan.md). Opens
    /// `{data_dir}/schedules.db` on first schedule envelope. Single
    /// store per node, raft-replicated to identical state, applied
    /// on both leader and follower.
    schedules_store: ?*schedule_server.ScheduleStore = null,
    /// Wake signal for the leader-pinned scheduler thread.
    /// Set by loop46/main.zig once the
    /// scheduler thread spawns. Envelope-8 apply fires it when the
    /// batch contains at least one external row; envelope-11
    /// (demote) always fires it (the row just landed in the
    /// external pool). Envelope-9 / 10 don't fire it — completes /
    /// cancels reduce work, not add it.
    schedule_wake: ?*std.Thread.ResetEvent = null,
    /// Wake signal for the in-process worker phase
    /// (`dispatchInternalSchedules`). Symmetric to `schedule_wake`
    /// but fires when a batch contains at least one internal row.
    /// Worker phase runs on the dispatch loop, so this is mostly an
    /// optimization — without it the next dispatch tick (sub-ms
    /// later) would pick the row up anyway. Mainly useful when the
    /// worker is idle (no inbound h2 traffic) and the dispatch loop
    /// is blocked in `io.poll`.
    worker_phase_wake: ?*std.Thread.ResetEvent = null,
    /// Cluster's public suffix (e.g. `loop46.me`). Used at
    /// envelope-8 apply to stamp `is_internal` on schedule rows
    /// whose URL targets `{id}.{public_suffix}` AND `{id}` has an
    /// existence marker in `__root__.db` (http-send-plan §3.2).
    /// Null / empty disables the stamping; rows stay
    /// `is_internal=false` and route through the libcurl scheduler
    /// thread. Borrowed; the loop46 binary owns the storage for
    /// the process lifetime.
    public_suffix: ?[]const u8 = null,

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
        if (self.schedules_store) |s| {
            s.close();
            self.allocator.destroy(s);
        }
    }

    /// Lazily open the cluster-wide `schedules.db`. Returned pointer is
    /// owned by the context and stable for its lifetime. Reached on
    /// both leader and follower because envelope types 8/9/10/11
    /// don't leader-skip.
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
        .schedule_demote => applyScheduleDemote(ctx, env),
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

    // Internal-target stamping (plan §3.2). Each node runs the same
    // detection against the same root-store membership + same suffix,
    // so all replicas agree on `is_internal` for every row. Rows
    // whose URL host is `{id}.{public_suffix}` AND `{id}` exists in
    // __root__.db get `is_internal=true` and land in the internal
    // pool (drained by `dispatchInternalSchedules`); everyone else
    // lands in the external pool (drained by the libcurl scheduler
    // thread). Track which pool got contributions so we only wake
    // the consumer that has new work.
    var has_external = false;
    var has_internal = false;
    for (rows) |*r| {
        r.is_internal = detectInternalTarget(ctx, r.url);
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
/// best-effort. False negative cost: one extra libcurl roundtrip.
/// False positive cost: dispatching against a non-existent tenant
/// (the worker phase rejects gracefully + the row falls back).
fn detectInternalTarget(ctx: *ApplyCtx, url: []const u8) bool {
    const suffix = ctx.public_suffix orelse return false;
    if (suffix.len == 0) return false;
    const id = schedule_server.internal_routing.parseInstanceId(url, suffix) orelse return false;
    const root = ctx.getRootKv() catch return false;
    var key_buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "instance/{s}", .{id}) catch return false;
    const v = root.get(key) catch |err| switch (err) {
        error.NotFound => return false,
        else => return false,
    };
    ctx.allocator.free(v);
    return true;
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

/// http.send envelope-11 apply (schedule_demote). Plan §3.2: the
/// worker phase gave up on serving this internal-pool row in-process
/// (target tenant not hosted on this node). Flip `is_internal=false`
/// so the libcurl thread can fire it. Wakes the scheduler thread —
/// the row just became eligible for `dueRows`. Idempotent on missing
/// row + on already-external row.
fn applyScheduleDemote(ctx: *ApplyCtx, env: Envelope) void {
    std.debug.assert(env.instance_id.len == 0);

    var target = schedule_server.decodeDemote(ctx.allocator, env.payload) catch |err|
        panic_mod.invariantViolated(
            "applyScheduleDemote.decode",
            "err={s}",
            .{@errorName(err)},
        );
    defer target.deinit(ctx.allocator);

    const store = ctx.getSchedules() catch |err| panic_mod.invariantViolated(
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

    // The row just transitioned to the external pool — let the
    // libcurl thread know without waiting out the next poll.
    if (ctx.schedule_wake) |w| w.set();
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

