//! `deployment_cache.zig` — per-tenant deployment cache subsystem.
//!
//! Extracted from `worker.zig` (Phase C of the NodeState decomposition).
//! Owns the `TenantSlot` type family (`TenantFilesSnapshot` / `TenantSlot`
//! / `TenantFiles`), the manifest-fetch config types, the deployment
//! discovery/snapshot-build helpers, and the `DeploymentCache` struct +
//! its loader thunk. Depends only on leaf modules — no import of
//! `worker.zig` (the slot no longer carries a `*NodeState` back-pointer,
//! and the slot cache is a plain map, not the shared `TenantMap`
//! generic). `worker.zig` re-exports the public types for existing
//! callers.

const std = @import("std");
const kv_mod = @import("raft-kv");
const blob_mod = @import("rove-blob");
const files_mod = @import("rove-files");
const tenant_mod = @import("rove-tenant");
const globals = @import("globals.zig");
const config_mirror = @import("config_mirror.zig");
const raft_propose = @import("raft_propose.zig");
const reserved = @import("reserved.zig");
const bytecode_cache_mod = @import("bytecode_cache.zig");
const deployment_loader_mod = @import("deployment_loader.zig");
const msg_router_mod = @import("msg_router.zig");

const BlobBytes = bytecode_cache_mod.BlobBytes;
const BytecodeCache = bytecode_cache_mod.BytecodeCache;
const MsgRouter = msg_router_mod.MsgRouter;
const testing = std.testing;

/// Metadata about a static file in the active deployment. Bytes are
/// not cached — the dispatcher fetches them from the blob store on hit.
/// `hash_hex` is both the content address and the strong ETag.
pub const StaticEntry = struct {
    content_type: []u8, // owned, may be empty
    hash_hex: [files_mod.HASH_HEX_LEN]u8,
};

/// Per-tenant code state held by the worker. Owns its own KvStore,
/// BlobStore, and cached bytecode for the tenant's active handler.
/// `TriggerEntry` is defined in globals.zig (lives next to the
/// dispatch state that consumes it during kv.set / kv.delete fire).
/// Re-exported here for convenience — `worker.TriggerEntry` reads
/// naturally next to `worker.TenantFiles`.
pub const TriggerEntry = globals.TriggerEntry;

/// Returns the kv key prefix this manifest path registers as a trigger
/// for, or null if the path isn't a trigger module entry. The path IS
/// the prefix (PLAN §2.5):
///   `_triggers/index.mjs`               → `""`        (catch-all)
///   `_triggers/users/index.mjs`         → `"users/"`
///   `_triggers/users/sessions/index.mjs` → `"users/sessions/"`
/// `.js` is accepted alongside `.mjs` for symmetry with handler routing.
pub fn triggerPathToPrefix(path: []const u8) ?[]const u8 {
    const TR = "_triggers/";
    if (!std.mem.startsWith(u8, path, TR)) return null;
    const rest = path[TR.len..];

    // `_triggers/index.mjs` / `_triggers/index.js` → catch-all.
    if (std.mem.eql(u8, rest, "index.mjs")) return "";
    if (std.mem.eql(u8, rest, "index.js")) return "";

    // `<prefix>/index.mjs` → `<prefix>/`.
    if (std.mem.endsWith(u8, rest, "/index.mjs")) {
        return rest[0 .. rest.len - "index.mjs".len];
    }
    if (std.mem.endsWith(u8, rest, "/index.js")) {
        return rest[0 .. rest.len - "index.js".len];
    }
    // Anything else under `_triggers/` (helper modules, non-index files)
    // isn't itself a trigger entry point — it's just bytecode the
    // trigger module may import.
    return null;
}

/// Re-export so callers reading worker.zig find the trigger guard
/// without leaving the file. See `reserved.zig` for the prefix list
/// and the customer-write guard counterpart.
const isReservedTriggerPrefix = reserved.isReservedTriggerPrefix;

/// Parse a `_subscriptions/<name>/<file>` deployment path into its
/// name + file-kind. Mirror of `triggerPathToPrefix` for Gap 2.1:
///
///   `_subscriptions/cleanup/index.mjs`  → `{name: "cleanup", kind: .handler}`
///   `_subscriptions/cleanup/index.js`   → `{name: "cleanup", kind: .handler}`
///   `_subscriptions/cleanup/spec.json`  → `{name: "cleanup", kind: .spec}`
///   `_subscriptions/cleanup/helper.mjs` → null (non-index helper modules are not subscriptions themselves)
///   anything else                        → null
///
/// Returned `name` slice borrows from `path`; valid as long as the
/// caller holds `path`. Subscription names must match
/// `[A-Za-z0-9_-]+` and be 1–64 chars; out-of-range returns null
/// so a misnamed file is treated as "not a subscription entry."
fn subscriptionPathParts(path: []const u8) ?struct {
    name: []const u8,
    kind: SubscriptionFileKind,
} {
    const PREFIX = "_subscriptions/";
    if (!std.mem.startsWith(u8, path, PREFIX)) return null;
    const rest = path[PREFIX.len..];

    // Split on the first `/` to get the name segment.
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const name = rest[0..slash];
    const tail = rest[slash + 1 ..];

    if (name.len == 0 or name.len > 64) return null;
    for (name) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '-' or ch == '_';
        if (!ok) return null;
    }

    if (std.mem.eql(u8, tail, "index.mjs") or std.mem.eql(u8, tail, "index.js"))
        return .{ .name = name, .kind = .handler };
    if (std.mem.eql(u8, tail, "spec.json"))
        return .{ .name = name, .kind = .spec };
    return null;
}

const SubscriptionFileKind = enum { handler, spec };

/// JSON shape of `_subscriptions/<name>/spec.json`. Parsed flat
/// then dispatched on `kind` to populate the typed
/// `SubscriptionEntry.Spec`. Unknown kinds + missing required
/// fields fail the deploy.
const SubscriptionSpecJson = struct {
    kind: []const u8,
    /// Required for kind=cron. Milliseconds between fires. Must be
    /// >= 1000 (one second). For complex schedules (e.g. "daily at
    /// 3am"), customers compose via
    /// `http.send({fire_at_ns: cron.next(...)})`.
    interval_ms: ?i64 = null,
    /// Required for kind=kv.
    prefix: ?[]const u8 = null,
};

/// Build the deployment's subscription registry from the manifest.
/// Walks once to collect handler + spec.json paths under
/// `_subscriptions/<name>/`, then pairs them: every spec.json must
/// have a matching handler (else `error.SubscriptionMissingHandler`);
/// missing spec.json on a handler is allowed (the handler is a
/// regular module under that path — the index.mjs convention is
/// what makes it a *subscription*).
///
/// Spec JSON is fetched fresh from the blob store on each reload —
/// this is deploy-time work; the fetch cost is bounded by the
/// number of subscriptions per tenant (small) and amortizes against
/// the per-deploy snapshot rebuild.
fn discoverSubscriptions(
    allocator: std.mem.Allocator,
    manifest: files_mod.manifest_json.Manifest,
    bs: anytype,
) ![]globals.SubscriptionEntry {
    var handler_paths: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer handler_paths.deinit(allocator);
    var spec_hashes: std.StringHashMapUnmanaged([files_mod.HASH_HEX_LEN]u8) = .empty;
    defer spec_hashes.deinit(allocator);

    for (manifest.entries) |entry| {
        const parts = subscriptionPathParts(entry.path) orelse continue;
        switch (parts.kind) {
            .handler => {
                if (entry.kind != .handler) {
                    std.log.warn(
                        "rove-js: subscription path `{s}` is not a handler entry — skipping",
                        .{entry.path},
                    );
                    continue;
                }
                try handler_paths.put(allocator, parts.name, entry.path);
            },
            .spec => {
                if (entry.kind != .static) {
                    std.log.warn(
                        "rove-js: subscription spec `{s}` must be a static file — skipping",
                        .{entry.path},
                    );
                    continue;
                }
                try spec_hashes.put(allocator, parts.name, entry.source_hex);
            },
        }
    }

    if (spec_hashes.count() == 0) return &.{};

    var out: std.ArrayList(globals.SubscriptionEntry) = .empty;
    errdefer {
        for (out.items) |*e| e.deinit(allocator);
        out.deinit(allocator);
    }

    var it = spec_hashes.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const hash = e.value_ptr.*;

        const handler_path = handler_paths.get(name) orelse {
            std.log.err(
                "rove-js: subscription `{s}` has spec.json but no index.mjs/index.js handler",
                .{name},
            );
            return error.SubscriptionMissingHandler;
        };

        const spec_bytes = bs.get(&hash, allocator) catch |err| {
            std.log.err(
                "rove-js: subscription `{s}` spec.json fetch failed: {s}",
                .{ name, @errorName(err) },
            );
            return error.SubscriptionSpecFetch;
        };
        defer allocator.free(spec_bytes);

        const parsed = std.json.parseFromSlice(
            SubscriptionSpecJson,
            allocator,
            spec_bytes,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            std.log.err(
                "rove-js: subscription `{s}` spec.json parse failed: {s}",
                .{ name, @errorName(err) },
            );
            return error.SubscriptionSpecInvalidJson;
        };
        defer parsed.deinit();

        const spec_typed = try translateSpec(allocator, name, parsed.value);

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const module_path_copy = try allocator.dupe(u8, handler_path);
        errdefer allocator.free(module_path_copy);

        try out.append(allocator, .{
            .name = name_copy,
            .module_path = module_path_copy,
            .spec = spec_typed,
        });
    }

    return out.toOwnedSlice(allocator);
}

/// Convert the JSON-shape spec into the typed tagged-union. The
/// returned `Spec` owns any inner allocations (allocator-duped
/// strings); caller must `deinit` on error paths.
fn translateSpec(
    allocator: std.mem.Allocator,
    name: []const u8,
    raw: SubscriptionSpecJson,
) !globals.SubscriptionEntry.Spec {
    if (std.mem.eql(u8, raw.kind, "cron")) {
        const interval_ms = raw.interval_ms orelse {
            std.log.err("rove-js: subscription `{s}` kind=cron missing `interval_ms` field", .{name});
            return error.SubscriptionSpecMissingField;
        };
        if (interval_ms < 1000) {
            std.log.err(
                "rove-js: subscription `{s}` kind=cron has sub-second interval_ms={d} (minimum 1000)",
                .{ name, interval_ms },
            );
            return error.SubscriptionSpecMissingField;
        }
        return .{ .cron = .{ .interval_ms = interval_ms } };
    }
    if (std.mem.eql(u8, raw.kind, "kv")) {
        const prefix = raw.prefix orelse {
            std.log.err("rove-js: subscription `{s}` kind=kv missing `prefix` field", .{name});
            return error.SubscriptionSpecMissingField;
        };
        if (prefix.len == 0) {
            std.log.err("rove-js: subscription `{s}` kind=kv has empty prefix", .{name});
            return error.SubscriptionSpecMissingField;
        }
        return .{ .kv = .{ .prefix = try allocator.dupe(u8, prefix) } };
    }
    if (std.mem.eql(u8, raw.kind, "boot")) {
        return .boot;
    }
    std.log.err("rove-js: subscription `{s}` has unknown kind `{s}`", .{ name, raw.kind });
    return error.SubscriptionSpecUnknownKind;
}

test "subscriptionPathParts: handler + spec + rejects" {
    {
        const r = subscriptionPathParts("_subscriptions/cleanup/index.mjs").?;
        try std.testing.expectEqualStrings("cleanup", r.name);
        try std.testing.expectEqual(SubscriptionFileKind.handler, r.kind);
    }
    {
        const r = subscriptionPathParts("_subscriptions/jobs-q/spec.json").?;
        try std.testing.expectEqualStrings("jobs-q", r.name);
        try std.testing.expectEqual(SubscriptionFileKind.spec, r.kind);
    }
    {
        const r = subscriptionPathParts("_subscriptions/foo/index.js").?;
        try std.testing.expectEqualStrings("foo", r.name);
        try std.testing.expectEqual(SubscriptionFileKind.handler, r.kind);
    }
    // Non-index helper module: not a subscription entry-point.
    try std.testing.expectEqual(@as(@TypeOf(subscriptionPathParts("")), null), subscriptionPathParts("_subscriptions/foo/helper.mjs"));
    // Bad name characters.
    try std.testing.expectEqual(@as(@TypeOf(subscriptionPathParts("")), null), subscriptionPathParts("_subscriptions/has space/index.mjs"));
    // Not under _subscriptions/.
    try std.testing.expectEqual(@as(@TypeOf(subscriptionPathParts("")), null), subscriptionPathParts("foo/bar/index.mjs"));
    // Too-long name.
    var buf: [200]u8 = undefined;
    @memset(&buf, 'x');
    const long_name = buf[0..70];
    const long_path = try std.fmt.allocPrint(std.testing.allocator, "_subscriptions/{s}/index.mjs", .{long_name});
    defer std.testing.allocator.free(long_path);
    try std.testing.expectEqual(@as(@TypeOf(subscriptionPathParts("")), null), subscriptionPathParts(long_path));
}

/// Reloaded by the background `DeploymentLoader` thread whenever a
/// release lands (operator path: __admin__'s `publishRelease` RPC;
/// platform-bootstrap path: `/_system/release`). The proposing
/// trampoline enqueues the loader inline on the leader; followers
/// pick up the enqueue from `apply.zig`'s `_deploy/current` detector.
/// Immutable per-deployment-version snapshot. Refcounted; freed when
/// the last reference drops (slot reload + any in-flight request).
///
/// Phase 2 of `docs/deployment-snapshots-plan.md`: snapshot pinning
/// guarantees a request sees one deployment version completely or
/// another completely, never a mid-reload mix.
pub const TenantFilesSnapshot = struct {
    allocator: std.mem.Allocator,
    /// Borrowed pointer to the node-wide content-addressed cache.
    /// Snapshot `deinit` releases every bytecode lease through it.
    /// Always non-null in production — `reloadDeployment` is the
    /// only constructor and it pulls the cache from `slot.bytecode_cache`,
    /// which `openTenantSlotNode` always sets.
    cache: *BytecodeCache,
    /// Deployment id this snapshot represents. Equal to the
    /// `_deploy/current` hex value at the moment the loader built it.
    deployment_id: u64,
    /// All handler bytecodes from this deployment, keyed by full
    /// deployment path. Keys are allocator-owned; values are leases
    /// into the node-wide `BytecodeCache` (Phase 3) — snapshot
    /// `deinit` releases each via `cache.release`.
    bytecodes: std.StringHashMapUnmanaged(*BlobBytes),
    /// Source-blob hash hex (64 chars) per handler path. Parallel to
    /// `bytecodes`. Read by the QuickJS module loader for per-request
    /// module-resolution tapes.
    source_hashes: std.StringHashMapUnmanaged([64]u8),
    /// Static files keyed by stored path; bytes fetched on demand
    /// from the slot's `blob_backend`.
    statics: std.StringHashMapUnmanaged(StaticEntry),
    /// Trigger registry. Sorted descending by prefix length so a
    /// forward scan visits innermost (most-specific) triggers first.
    triggers: []TriggerEntry,
    /// Subscription registry (Gap 2.1) — chain origins that fire
    /// without an inbound request. Built from
    /// `_subscriptions/<name>/{spec.json,index.mjs}` manifest pairs.
    /// Default empty for snapshots that pre-date subscription
    /// discovery; only the deploy-loader populates it.
    subscriptions: []globals.SubscriptionEntry = &.{},
    /// Raw manifest bytes for this deployment. Re-released callers
    /// re-decode locally on dep_id match, skipping a fetch.
    manifest_bytes: []u8,
    /// References to this snapshot. Starts at 1 (slot's reference).
    /// Per-request retain++ at dispatch entry; release-- on response.
    /// Reload swaps the slot pointer and drops the slot's reference.
    refcount: std.atomic.Value(u32),

    pub fn retain(self: *TenantFilesSnapshot) void {
        _ = self.refcount.fetchAdd(1, .acquire);
    }

    pub fn release(self: *TenantFilesSnapshot) void {
        if (self.refcount.fetchSub(1, .release) == 1) {
            self.deinit();
        }
    }

    fn deinit(self: *TenantFilesSnapshot) void {
        const allocator = self.allocator;
        var bc_it = self.bytecodes.iterator();
        while (bc_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            self.cache.release(entry.value_ptr.*);
        }
        self.bytecodes.deinit(allocator);
        var sh_it = self.source_hashes.iterator();
        while (sh_it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.source_hashes.deinit(allocator);
        var st_it = self.statics.iterator();
        while (st_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*.content_type);
        }
        self.statics.deinit(allocator);
        for (self.triggers) |t| {
            allocator.free(t.prefix);
            allocator.free(t.module_path);
        }
        allocator.free(self.triggers);
        for (self.subscriptions) |*s| {
            // Cast away const for the deinit call; the slice is
            // allocator-owned at this point (no aliases reach this
            // path — Phase B's snapshot-build hands ownership to
            // the snapshot, the swap drops the old, and `deinit`
            // is the sole site that frees).
            const mut: *globals.SubscriptionEntry = @constCast(s);
            mut.deinit(allocator);
        }
        if (self.subscriptions.len > 0) allocator.free(self.subscriptions);
        allocator.free(self.manifest_bytes);
        allocator.destroy(self);
    }
};

/// Per-tenant slot. Persists across deployments; lifetime = tenant
/// lifetime. Owns the per-tenant blob backends and points at the
/// current `*TenantFilesSnapshot` via an atomic pointer.
///
/// Reload semantics: the loader builds a new snapshot fully, then
/// `atomicStore`s onto `current` (release ordering), then drops the
/// old snapshot's lease. In-flight requests that pinned the old
/// snapshot keep it alive until they release.
pub const TenantSlot = struct {
    allocator: std.mem.Allocator,
    /// Owned copy of the instance id; key in NodeState's slot map.
    instance_id: []u8,
    /// Borrowed pointer to the tenant's app.db (for `_deploy/current`
    /// reads and customer kv ops).
    app_kv: *kv_mod.KvStore,
    /// Borrowed process raft node. The loader's `reloadDeployment`
    /// uses it to leader-gate + propose the `_config/**.json` mirror
    /// (auth-domain-plan §9: the release/loader path must mirror
    /// per-deploy config to kv — fixes the `7eb70ed` regression).
    /// Optional/`null` only in unit-test slot literals — a slot with
    /// no raft handle just skips the config mirror.
    raft: ?*kv_mod.RaftNode = null,
    /// Borrowed pointer to the node-wide content-addressed bytecode
    /// cache. Set by `openTenantSlotNode`; `reloadAllBytecodes` builds
    /// each snapshot's lease set through it. Optional only in unit-test
    /// slot literals. (Phase A of the TenantSlot/DeploymentCache split:
    /// replaces the former `node: *NodeState` god-pointer — a slot now
    /// borrows only the two subsystems it actually uses, `bytecode_cache`
    /// + `router`, decoupling it from NodeState entirely.)
    bytecode_cache: ?*BytecodeCache = null,
    /// Borrowed pointer to the node's async-activation router. Set by
    /// `openTenantSlotNode`; used for cross-thread boot-subscription
    /// firing (Gap 2.1 Phase D boot firing →
    /// `router.enqueueSubscriptionFireForTenant`). Optional only in
    /// unit-test slot literals.
    router: ?*MsgRouter = null,
    /// Owned blob backend for file-blobs (source + bytecode bytes).
    blob_backend: blob_mod.BlobBackend,
    /// Owned blob backend for per-deployment manifest JSON.
    manifest_backend: blob_mod.BlobBackend,
    /// One-shot prefetched manifest from the cold-start batch fetch.
    /// Drained on the first reload that matches its dep_id.
    prefetched_manifest: ?PrefetchedManifest,
    /// Atomic pointer to the current snapshot. Null until first load.
    current: std.atomic.Value(?*TenantFilesSnapshot),
    /// Serializes `pinCurrent` (load + retain) against `reloadDeployment`
    /// (swap + release-old). Without this, a dispatcher could load
    /// the old pointer, the loader could swap-and-release it to
    /// refcount 0, and the dispatcher's retain would touch freed
    /// memory. Held only across the two-instruction critical sections
    /// — reload's manifest fetch / decode / fetch-bytecodes still
    /// runs unlocked.
    pin_lock: std.Thread.Mutex = .{},

    /// §2.6 durable scheduled wake: this tenant's single next-fire
    /// timestamp (absolute wall-clock ns), or 0 for "no wake pending."
    /// The engine's only durable-wake state — the queue/ordering lives
    /// in the `scheduler` JS lib's `_sched/` kv (`docs/durable-wake-plan.md`).
    /// Written only by the baked `__system/scheduler_tick` via
    /// `__rove_set_wake` (steady state, on the partition-owner worker)
    /// and by the post-commit bootstrap hook (P2, on the committing
    /// worker — possibly a *different* worker), so the slot is atomic.
    /// Read by `durable_wake.sweepDurableWakes` (1 Hz, partition-owner
    /// worker). Volatile — reconstructed on leadership gain by
    /// `sweepDurableWakesOnPromotion`.
    next_wake_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    /// Lower the next-fire watermark to `when_ns` iff it's sooner than
    /// the current pending wake (or there is none). `when_ns == 0`
    /// clears the wake. Used by the post-commit bootstrap hook (P2):
    /// a freshly-committed `_sched/by_time` entry only ever needs to
    /// pull the watermark *earlier*; `scheduler_tick` recomputes the
    /// exact min when it next fires. Monotone-min so concurrent
    /// committing workers converge without a lock.
    pub fn lowerWake(self: *TenantSlot, when_ns: i64) void {
        if (when_ns == 0) return;
        while (true) {
            const cur = self.next_wake_ns.load(.acquire);
            if (cur != 0 and cur <= when_ns) return; // already sooner-or-equal
            if (self.next_wake_ns.cmpxchgWeak(cur, when_ns, .acq_rel, .acquire) == null) return;
        }
    }

    /// `DispatchState.set_wake` trampoline (ctx = `*TenantSlot`). The
    /// baked `__system/scheduler_tick`'s `__rove_set_wake(whenNs)`
    /// lands here and stores the exact next-fire watermark `tick`
    /// computed from committed `_sched/by_time` state. Passing the
    /// slot pointer as the trampoline ctx keeps this lock-free and
    /// works regardless of which worker hosts the tick (the slot is
    /// node-shared); the redundant `tenant_id` arg is ignored.
    pub fn setWakeTrampoline(ctx: *anyopaque, tenant_id: []const u8, when_ns: i64) void {
        _ = tenant_id;
        const self: *TenantSlot = @ptrCast(@alignCast(ctx));
        self.next_wake_ns.store(when_ns, .release);
    }

    // Note: no `open`/`free` lifecycle wrappers here. Slots are opened
    // via `DeploymentCache.getOrOpenTenantSlot` (which open-codes the
    // unlocked-open + re-check race) and freed via `freeTenantSlot`.
    // The old `TenantMap` `Entry.open`/`Entry.free` convention no
    // longer applies — the slot cache is a plain map.

    /// Try to pin the current snapshot for a request. Returns null
    /// if no deployment has loaded yet. Caller MUST `snap.release()`
    /// when done (typically at response time, after the raft drain
    /// for write requests).
    pub fn pinCurrent(self: *TenantSlot) ?*TenantFilesSnapshot {
        self.pin_lock.lock();
        defer self.pin_lock.unlock();
        const snap = self.current.load(.acquire) orelse return null;
        snap.retain();
        return snap;
    }

    /// Current snapshot's `deployment_id`, or 0 if no snapshot is
    /// loaded. Lock-free single-load; doesn't retain. Use for log
    /// records / metrics where we just want the value, not access.
    pub fn currentDeploymentId(self: *TenantSlot) u64 {
        const snap = self.current.load(.acquire) orelse return 0;
        return snap.deployment_id;
    }
};

/// Per-request view: slot pointer plus a pinned snapshot. Captured
/// at dispatch entry (`slot.pinCurrent()`), released after the
/// response moves to `response_in` (post-raft-drain for writes).
/// Field accesses pass through: `tc.slot.X` for tenant-lifetime
/// fields (app_kv, blob_backend, etc.); `tc.snap.X` for deployment-
/// version fields (bytecodes, statics, triggers).
pub const TenantFiles = struct {
    slot: *TenantSlot,
    snap: *TenantFilesSnapshot,

    pub fn release(self: TenantFiles) void {
        self.snap.release();
    }

    /// Open is no longer a thing — slots are opened, snapshots are
    /// loaded by the deployment loader. Kept as a compile error to
    /// surface old call sites that need updating.
    pub fn open(_: anytype, _: anytype) noreturn {
        @compileError("TenantFiles is a view; use `slot.pinCurrent()` to construct one");
    }

    pub fn free(_: std.mem.Allocator, _: *TenantFiles) noreturn {
        @compileError("TenantFiles is a view; release via `tc.release()`");
    }
};

/// One pre-fetched manifest from the cold-start bulk fetch.
/// Owned bytes; freed by the worker after consumption (or at
/// shutdown if never consumed).
pub const PrefetchedManifest = struct {
    dep_id: u64,
    bytes: []u8,
};

/// Configuration for routing manifest reads through a files-server
/// cluster over HTTP/2 instead of fetching from S3 directly. Set
/// on `WorkerConfig.manifest_http` to opt in. See production.md
/// #1.4 step 4.
pub const ManifestHttpConfig = struct {
    /// Origin like `https://files.loop46.localhost:9090`. Borrowed;
    /// HttpBlobStore dupes internally so the caller can free
    /// after `Worker.create` returns.
    base_url: []const u8,
    /// Per-fetch JWT minter. Loop46 typically wires this to a
    /// closure over its `services_jwt_secret`. Borrowed.
    mint_jwt: blob_mod.http_blob.MintJwtFn,
    mint_ctx: ?*anyopaque = null,
    /// Optional CA bundle path for self-signed dev certs. Borrowed.
    ca_bundle_path: ?[]const u8 = null,
    /// Production: true. Dev / smoke against self-signed cert: false.
    verify_tls: bool = true,
};

/// Manifest-prefetch slot map. Keys + value bytes are allocator-owned;
/// consumed at TenantFiles.open time (`fetchRemove` transfers ownership
/// out). Kept on NodeState so cold-start prefetch persists across the
/// transition from "main spawns workers" to "each worker boots".
pub const ManifestPrefetchMap = std.StringHashMapUnmanaged(PrefetchedManifest);

/// Per-tenant deployment cache subsystem — the tenant-slot map, the
/// node-wide content-addressed bytecode cache, the single
/// deployment-loader thread, and the manifest-fetch config. Extracted
/// from NodeState (Phase B of the TenantSlot/DeploymentCache split).
///
/// Borrows the handles it needs rather than the whole node: `tenant`,
/// `raft`, and `blob_backend_cfg` are captured at `init`; `router` is
/// wired post-init via `NodeState.wireInternal` (it's a self-pointer
/// into NodeState, which can't be taken during the by-value `init`).
/// Keeping the dependency surface narrow is what lets Phase C relocate
/// this + the TenantSlot family into their own module without a cycle
/// back to NodeState.
pub const DeploymentCache = struct {
    allocator: std.mem.Allocator,

    /// Shared tenant resolver. Borrowed; owned by `main.zig`.
    tenant: *tenant_mod.Tenant,

    /// Process raft node (= `cluster.raft`). Borrowed; owned by
    /// `main.zig`. Copied into each `TenantSlot` so `reloadDeployment`
    /// can leader-gate + propose the `_config/**.json` mirror.
    raft: *kv_mod.RaftNode,

    /// Process-wide blob backend config consumed by `openTenantSlotNode`
    /// when opening each tenant's file-blob + manifest backends.
    blob_backend_cfg: blob_mod.BackendConfig,

    /// Borrowed pointer to the node's async-activation router. Stamped
    /// onto each `TenantSlot.router` at open time for boot-subscription
    /// firing. Wired post-init (`NodeState.wireInternal`) because it's a
    /// self-pointer into NodeState; null only before wiring / in unit
    /// contexts.
    router: ?*MsgRouter = null,

    /// Per-tenant slot cache, keyed by instance id (the slot's owned
    /// `instance_id`). `tenant_files_lock` guards inserts; the
    /// TenantSlot entries' deployment-version content is served via an
    /// atomic-pointer-swapped `TenantFilesSnapshot` (phase 2 of
    /// `docs/deployment-snapshots-plan.md`), so reload no longer races
    /// with the dispatcher.
    ///
    /// A plain map (not the `TenantMap` lifecycle generic): slot
    /// open/free is open-coded in `getOrOpenTenantSlot` /
    /// `freeTenantSlot` because opening a slot does blob/libcurl I/O
    /// that must run *without* holding `tenant_files_lock` (the generic
    /// `getOrOpen` can't express that unlocked-open + re-check race).
    /// So this consumer only ever uses get/put/iterate/deinit —
    /// `TenantMap`'s `getOrOpen` convention buys it nothing.
    tenant_files_map: std.StringHashMapUnmanaged(*TenantSlot) = .empty,
    tenant_files_lock: std.Thread.Mutex = .{},

    /// Phase 3 of `docs/deployment-snapshots-plan.md`: content-
    /// addressed cache of bytecode blobs shared across every tenant
    /// snapshot on this node. Loader does `acquire(hash)` per
    /// manifest entry; only fetches the misses. Cross-tenant blob
    /// sharing falls out automatically. Snapshot `deinit` releases
    /// leases through this cache.
    bytecode_cache: BytecodeCache,

    /// Single deployment loader thread for the whole process.
    /// `_deploy/current` changes from any worker / apply path enqueue
    /// here; one reload reaches every worker. Allocated in
    /// `startDeploymentLoader`; the load function thunk is
    /// `deploymentLoadFnNode`.
    deployment_loader: ?*deployment_loader_mod.DeploymentLoader = null,

    /// Process-wide manifest-fetch config consumed by
    /// `openTenantSlotNode`. Shared pointers (libcurl Easy, prefetch
    /// map) live for the lifetime of the cache.
    manifest_http: ?ManifestHttpConfig = null,
    manifest_easy: ?*blob_mod.curl.Easy = null,
    manifest_prefetch: ?ManifestPrefetchMap = null,

    pub fn init(
        allocator: std.mem.Allocator,
        tenant: *tenant_mod.Tenant,
        raft: *kv_mod.RaftNode,
        blob_backend_cfg: blob_mod.BackendConfig,
    ) DeploymentCache {
        return .{
            .allocator = allocator,
            .tenant = tenant,
            .raft = raft,
            .blob_backend_cfg = blob_backend_cfg,
            .bytecode_cache = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *DeploymentCache) void {
        if (self.deployment_loader) |l| {
            l.shutdown();
            l.deinit();
            self.deployment_loader = null;
        }
        // Free every slot, then the map's internal storage. The map
        // key is each slot's owned `instance_id`, freed by
        // `freeTenantSlot`, so `map.deinit` (which only releases the
        // hashmap's arrays) must run after — and we must not touch keys
        // once freed.
        {
            var it = self.tenant_files_map.iterator();
            while (it.next()) |entry| freeTenantSlot(self.allocator, entry.value_ptr.*);
            self.tenant_files_map.deinit(self.allocator);
        }
        // Bytecode cache must die AFTER every slot — slots release
        // their snapshots' leases through the cache on free. Once the
        // slots are freed above, every snapshot the node ever held has
        // dropped its slot reference. In-flight pinned requests should
        // already be drained by the worker shutdown path; any surviving
        // entry trips the assert in `BytecodeCache.deinit`.
        self.bytecode_cache.deinit();
        if (self.manifest_prefetch) |*map| {
            var it = map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*.bytes);
            }
            map.deinit(self.allocator);
            self.manifest_prefetch = null;
        }
    }

    /// Spawn the single deployment loader thread. Idempotent. Called
    /// once from `main.zig` after the cache is wired; the loader's thunk
    /// casts `ctx_opaque` back to `*DeploymentCache`.
    pub fn startDeploymentLoader(self: *DeploymentCache) !void {
        if (self.deployment_loader != null) return;
        const loader = try deployment_loader_mod.DeploymentLoader.init(
            self.allocator,
            @as(?*anyopaque, @ptrCast(self)),
            deploymentLoadFnNode,
        );
        errdefer loader.deinit();
        try loader.start();
        self.deployment_loader = loader;
    }

    /// Lookup-or-lazy-open under `tenant_files_lock`.
    /// Idempotent: concurrent callers may race on `openTenantSlotNode`
    /// (slow, runs unlocked); the loser frees its in-flight slot and
    /// returns the winner's.
    pub fn getOrOpenTenantSlot(
        self: *DeploymentCache,
        inst: *const tenant_mod.Instance,
    ) !*TenantSlot {
        // Fast path: already cached.
        self.tenant_files_lock.lock();
        if (self.tenant_files_map.get(inst.id)) |existing| {
            self.tenant_files_lock.unlock();
            return existing;
        }
        self.tenant_files_lock.unlock();

        // Slow path: open without holding the lock (libcurl + blob
        // backend init may do I/O). Re-check under the lock before
        // inserting — another worker may have raced ahead.
        const opened = try openTenantSlotNode(self, inst);
        errdefer freeTenantSlot(self.allocator, opened);

        self.tenant_files_lock.lock();
        defer self.tenant_files_lock.unlock();
        if (self.tenant_files_map.get(inst.id)) |winner| {
            // Lost the race; drop our duplicate and use the winner.
            freeTenantSlot(self.allocator, opened);
            return winner;
        }
        try self.tenant_files_map.put(self.allocator, opened.instance_id, opened);
        return opened;
    }

    /// Cold-start eager-open: walk every known tenant, populate the
    /// map, enqueue the loader to fetch every deployment in parallel.
    /// Called once from `main.zig` after the loader is up. Returns the
    /// count of tenants opened.
    pub fn eagerOpenTenants(self: *DeploymentCache) !usize {
        var count: usize = 0;
        var it = self.tenant.instances.iterator();
        while (it.next()) |entry| {
            const inst = entry.value_ptr.*;
            const slot = try self.getOrOpenTenantSlot(inst);
            count += 1;
            // Enqueue a deployment load for any tenant whose
            // `_deploy/current` is set.
            if (self.deployment_loader) |l| {
                const cur_bytes = slot.app_kv.get("_deploy/current") catch continue;
                defer self.allocator.free(cur_bytes);
                const dep_id = std.fmt.parseInt(u64, cur_bytes, 16) catch continue;
                if (dep_id == 0) continue;
                l.enqueue(slot.instance_id, dep_id) catch |err| {
                    std.log.warn(
                        "rove-js: cold-start enqueue {s}/{d} failed: {s}",
                        .{ slot.instance_id, dep_id, @errorName(err) },
                    );
                };
            }
        }
        return count;
    }
};

/// Loader thunk for the single per-process loader. `ctx_opaque` is a
/// `*DeploymentCache`. Looks up the tenant's TenantSlot (skip if
/// absent), short-circuits when the current snapshot already has this
/// dep_id (content-addressed: same id ⇒ same content), and calls
/// `reloadDeployment` otherwise. Phase 2: readers either see the old
/// snapshot or the new one, never a half-written mix.
fn deploymentLoadFnNode(
    ctx_opaque: ?*anyopaque,
    tenant_id: []const u8,
    dep_id: u64,
) anyerror!void {
    const dc: *DeploymentCache = @ptrCast(@alignCast(ctx_opaque.?));
    dc.tenant_files_lock.lock();
    const slot_opt = dc.tenant_files_map.get(tenant_id);
    dc.tenant_files_lock.unlock();
    const slot = slot_opt orelse blk: {
        // Runtime-created tenant (signup, admin createInstance):
        // the apply.zig enqueue fires before any request has
        // lazy-opened the slot. Open it here so the snapshot
        // lands; otherwise the first request to the new tenant
        // 503s until the next reload event.
        const inst_opt = dc.tenant.getInstance(tenant_id) catch null;
        const inst = inst_opt orelse return; // tenant not on this node
        break :blk dc.getOrOpenTenantSlot(inst) catch |err| {
            std.log.warn(
                "rove-js: lazy slot-open for runtime tenant {s} failed: {s}",
                .{ tenant_id, @errorName(err) },
            );
            return;
        };
    };
    // Content-addressed dep_ids: same id ⇒ same content. Skip the
    // re-fetch + snapshot rebuild when the current snapshot already
    // matches.
    if (slot.currentDeploymentId() == dep_id) return;
    try reloadDeployment(slot, dep_id);
}

/// Open (or re-use) a tenant code state. Allocates a `*TenantFiles`
/// and attempts to load the current deployment's handler bytecode.
/// If the tenant has no deployment yet, the `handler_bytecode` stays
/// `null` and requests against this tenant return 503.
///
/// (No startup orphan sweep: kvexp has no `kv_undo` table — a
/// pre-quorum crash loses the volatile speculative overlay, so
/// there are no orphan rows to recover. The pre-kvexp SQLite sweep
/// was removed.)
fn openTenantSlotNode(dc: *DeploymentCache, inst: *const tenant_mod.Instance) !*TenantSlot {
    const allocator = dc.allocator;

    // (No startup orphan sweep: kvexp has no kv_undo table — a
    // pre-quorum crash loses the volatile speculative overlay, so
    // there are no orphan rows to recover. The pre-kvexp SQLite
    // sweep was removed.)

    var blob_backend = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        dc.blob_backend_cfg,
        inst.id,
        "file-blobs",
    );
    errdefer blob_backend.deinit();

    // Production.md #1.4 step 4 — when manifest_http is wired, open
    // an HTTP-backed manifest_backend that fetches manifests from a
    // colocated files-server cluster (where they live in raft-
    // replicated KV). Otherwise fall back to S3-direct, which still
    // works as long as files-server's bootstrap path keeps the dual
    // S3 PUT alive. The S3 PUT goes away once every loop46 worker
    // in the deployment uses the HTTP backend.
    var manifest_backend = if (dc.manifest_http) |mh|
        try blob_mod.BlobBackend.openHttp(allocator, .{
            .base_url = mh.base_url,
            .instance_id = inst.id,
            .mint_jwt = mh.mint_jwt,
            .mint_ctx = mh.mint_ctx,
            // Shared Easy across all per-tenant manifest backends
            // on this node — see `DeploymentCache.manifest_easy`. Falls
            // back to per-tenant Easy when shared init failed.
            .easy = dc.manifest_easy,
            .ca_bundle_path = mh.ca_bundle_path,
            .verify_tls = mh.verify_tls,
        })
    else
        try blob_mod.BlobBackend.openPerTenant(
            allocator,
            dc.blob_backend_cfg,
            inst.id,
            "deployments",
        );
    errdefer manifest_backend.deinit();

    const id_copy = try allocator.dupe(u8, inst.id);
    errdefer allocator.free(id_copy);

    const slot = try allocator.create(TenantSlot);
    errdefer allocator.destroy(slot);
    // Pull this tenant's prefetched manifest (if any) — transfer
    // ownership of the bytes from the worker's prefetch map to
    // `slot`. fetchRemove returns the entry's key + value pair;
    // we own the value bytes from here and free the key (the
    // map's key was a copy of the tenant id, not the same alloc
    // as `id_copy` above).
    var prefetched: ?PrefetchedManifest = null;
    if (dc.manifest_prefetch) |*map| {
        if (map.fetchRemove(inst.id)) |kv| {
            allocator.free(kv.key);
            prefetched = kv.value;
        }
    }
    errdefer if (prefetched) |p| allocator.free(p.bytes);

    slot.* = .{
        .allocator = allocator,
        .instance_id = id_copy,
        .app_kv = inst.kv,
        .raft = dc.raft,
        .bytecode_cache = &dc.bytecode_cache,
        .router = dc.router,
        .blob_backend = blob_backend,
        .manifest_backend = manifest_backend,
        .prefetched_manifest = prefetched,
        .current = .{ .raw = null },
    };

    // Best-effort initial load. Read `_deploy/current` from the
    // tenant's app.db (set by release POST + replicated via raft);
    // load that manifest from manifest_backend. If absent or
    // unreachable, log and leave `bytecodes` empty — requests get
    // 503 until either the dashboard pushes a release or the
    // periodic reload retry succeeds.
    //
    // Cold-start "implicit deploy" semantics: the synchronous
    // reload that used to run here is gone. Each tenant's
    // initial deployment load now goes through the same
    // background `DeploymentLoader` path runtime releases use
    // (`Worker.create` enqueues every tenant after the open
    // loop). The hot request path stays free of network I/O at
    // cold-start, just like everywhere else.
    //
    // Until the loader catches up, the tenant has no snapshot;
    // requests against it return 503. The customer observes
    // "loading" via SSE (future) or by polling. For tenants with
    // no `_deploy/current` set, the loader skips and the tenant
    // stays at 503 forever (until a real release POST sets the
    // pointer).
    return slot;
}

fn freeTenantSlot(allocator: std.mem.Allocator, slot: *TenantSlot) void {
    // Drop the slot's reference to the current snapshot (if any).
    // In-flight pinned references keep the old snapshot alive until
    // they release.
    if (slot.current.load(.acquire)) |snap| {
        // Atomically clear so nobody else can pin after teardown.
        slot.current.store(null, .release);
        snap.release();
    }
    slot.manifest_backend.deinit();
    slot.blob_backend.deinit();
    if (slot.prefetched_manifest) |p| allocator.free(p.bytes);
    allocator.free(slot.instance_id);
    allocator.destroy(slot);
}

/// Read the tenant's current deployment manifest, fetch every handler
/// entry's bytecode blob, stage every static entry's metadata, and
/// build + swap an immutable snapshot onto `slot.current`. Returns
/// `error.NoDeployment` when no deploy has been made yet — soft
/// failure the caller treats as "leave the slot snapshotless".
fn reloadAllBytecodes(slot: *TenantSlot) !void {
    // Read the release pointer from the tenant's app.db. Set by
    // /_system/release (replicated through raft envelope 0); absent
    // for tenants that haven't been released yet.
    const cur_bytes = slot.app_kv.get("_deploy/current") catch |err| switch (err) {
        error.NotFound => return error.NoDeployment,
        else => return err,
    };
    defer slot.allocator.free(cur_bytes);
    const dep_id = std.fmt.parseInt(u64, cur_bytes, 16) catch return error.NoDeployment;
    return reloadDeployment(slot, dep_id);
}

/// Stage the manifest's `_config/**.json` into the tenant's app.db
/// (local commit) and propose it as an envelope-0 writeset so
/// followers replicate. Skips the raft entry when nothing changed
/// (the common case — most tenants ship no `_config/`). Caller
/// leader-gates this; see the call site in `reloadDeployment`.
fn mirrorDeployConfig(
    allocator: std.mem.Allocator,
    slot: *TenantSlot,
    raft: *kv_mod.RaftNode,
    manifest: files_mod.manifest_json.Manifest,
    file_blobs: blob_mod.BlobStore,
) !void {
    var txn = try slot.app_kv.beginTrackedImmediate();
    errdefer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    const stats = try config_mirror.mirrorConfigToKv(
        allocator,
        manifest,
        file_blobs,
        slot.app_kv,
        &txn,
        &ws,
    );
    if (stats.put_count == 0 and stats.delete_count == 0) {
        txn.rollback() catch {};
        return; // no `_config/*` churn → don't burn a raft entry
    }
    try txn.commit();
    // config-mirror is a non-handler producer (cold-start /
    // deployment-loader thread); no dispatched-handler readset to
    // attach.
    if (raft_propose.proposeWriteSet(
        .{ .allocator = allocator, .raft = raft },
        &ws,
        slot.instance_id,
        "",
    )) |_| {} else |err| {
        // Local commit is already durable on the leader; followers
        // re-derive on their next reload. Log, don't fail the deploy.
        std.log.warn(
            "config mirror: propose {s} failed: {s}",
            .{ slot.instance_id, @errorName(err) },
        );
    }
}

/// Pull a specific deployment manifest from the per-tenant
/// `deployments/` BlobBackend, fetch every referenced bytecode, and
/// build a new `TenantFilesSnapshot` that we atomic-swap onto
/// `slot.current`. The old snapshot's slot-reference drops, but
/// pinned in-flight readers keep it alive until they release. Used
/// by `reloadAllBytecodes` (cold start / restart) and by the
/// background `DeploymentLoader` thread (a release landed).
fn reloadDeployment(slot: *TenantSlot, dep_id: u64) !void {
    const allocator = slot.allocator;
    // Two-tier source for the manifest bytes:
    //   1. One-shot prefetch from cold-start. Transfer ownership
    //      out of the prefetch slot when the dep_id matches.
    //   2. Per-tenant HTTP / S3 fetch via manifest_backend.
    //
    // dep_ids are content-addressed (truncated sha-256, see
    // `files_mod.manifest_json.computeDeploymentId`), so reaching
    // this function with `dep_id == slot.currentDeploymentId()` is
    // already filtered out in `deploymentLoadFnNode`. No in-function
    // cached-bytes short-circuit needed.
    var json_bytes: []u8 = undefined;
    var owned_by_prefetch = false;
    if (slot.prefetched_manifest) |p| {
        slot.prefetched_manifest = null;
        if (p.dep_id == dep_id) {
            json_bytes = p.bytes;
            owned_by_prefetch = true;
        } else {
            allocator.free(p.bytes);
        }
    }
    if (!owned_by_prefetch) {
        var key_buf: [25]u8 = undefined;
        const key = files_mod.manifest_json.manifestKey(&key_buf, dep_id);
        json_bytes = slot.manifest_backend.blobStore().get(key, allocator) catch |err| switch (err) {
            error.NotFound => return error.NoDeployment,
            else => return err,
        };
    }
    var json_bytes_consumed = false;
    errdefer if (!json_bytes_consumed) allocator.free(json_bytes);

    var manifest = files_mod.manifest_json.decode(allocator, json_bytes) catch
        return error.InvalidManifest;
    defer manifest.deinit();

    const bs = slot.blob_backend.blobStore();

    // Mirror `_config/**.json` → tenant kv (auth-domain-plan §9: the
    // release/loader path MUST mirror per-deploy user config; fixes
    // the `7eb70ed` regression where this promise was made but never
    // wired). Leader-gated + proposed exactly like `_deploy/current`:
    // the leader writes locally + proposes an envelope-0 writeset
    // (leader-skip on apply), so followers receive `_config/*` purely
    // via that raft apply and their own (non-leader) reloadDeployment
    // correctly skips it. Best-effort — a failure logs and still lets
    // the deployment load (missing config is visible + self-heals on
    // the next reload).
    if (slot.raft) |raft| {
        if (raft.isLeader()) {
            mirrorDeployConfig(allocator, slot, raft, manifest, bs) catch |err|
                std.log.warn(
                    "reloadDeployment: config mirror {s}/{d} failed: {s}",
                    .{ slot.instance_id, dep_id, @errorName(err) },
                );
        }
    }

    // Build the new maps in locals before installing, so if any fetch
    // fails mid-way the slot keeps serving the old deployment.
    //
    // Phase 3: bytecode values are leases (`*BlobBytes`) into the
    // node-wide `BytecodeCache`. The errdefer releases each partial
    // lease so a mid-build fetch failure doesn't leak refcount on
    // any cache entry we already touched (either reused or fresh-
    // inserted).
    const cache: *BytecodeCache = slot.bytecode_cache orelse return error.SlotNotOpenedThroughNode;
    var next_bc: std.StringHashMapUnmanaged(*BlobBytes) = .empty;
    errdefer {
        var it = next_bc.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            cache.release(e.value_ptr.*);
        }
        next_bc.deinit(allocator);
    }

    var next_source_hashes: std.StringHashMapUnmanaged([64]u8) = .empty;
    errdefer {
        var it = next_source_hashes.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        next_source_hashes.deinit(allocator);
    }

    var next_statics: std.StringHashMapUnmanaged(StaticEntry) = .empty;
    errdefer {
        var it = next_statics.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*.content_type);
        }
        next_statics.deinit(allocator);
    }

    var next_triggers: std.ArrayList(TriggerEntry) = .empty;
    errdefer {
        for (next_triggers.items) |*e| {
            allocator.free(e.prefix);
            allocator.free(e.module_path);
        }
        next_triggers.deinit(allocator);
    }

    for (manifest.entries) |entry| {
        const path_copy = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(path_copy);
        switch (entry.kind) {
            .handler => {
                // Phase 3 diff-fetch: try the cache first; only the
                // misses hit S3. Two tenants with the same bytecode
                // hash share one cache entry — the second tenant's
                // load sees the existing `*BlobBytes` and just bumps
                // refcount.
                const bb: *BlobBytes = if (cache.acquire(&entry.bytecode_hex)) |hit| hit else blk: {
                    const bytes = try bs.get(&entry.bytecode_hex, allocator);
                    errdefer allocator.free(bytes);
                    break :blk try cache.insert(&entry.bytecode_hex, bytes);
                };
                errdefer cache.release(bb);
                try next_bc.put(allocator, path_copy, bb);

                // Mirror the path → source-hash mapping so the per-
                // request module loader can stamp `appendModule(name,
                // source_hash)` on each successful import. Owns its
                // own key copy.
                const sh_key = try allocator.dupe(u8, entry.path);
                errdefer allocator.free(sh_key);
                try next_source_hashes.put(allocator, sh_key, entry.source_hex);

                // If this handler also matches the trigger path
                // convention (`_triggers/<.../>index.{mjs,js}`), index
                // it in the trigger registry. The bytecode lookup at
                // fire time uses the same path key in `bytecodes`.
                if (triggerPathToPrefix(entry.path)) |derived_prefix| {
                    if (isReservedTriggerPrefix(derived_prefix)) {
                        std.log.warn(
                            "rove-js: tenant {s} trigger {s} rejected — prefix '{s}' overlaps a platform namespace",
                            .{ slot.instance_id, entry.path, derived_prefix },
                        );
                        return error.ReservedTriggerPrefix;
                    }
                    const prefix_copy = try allocator.dupe(u8, derived_prefix);
                    errdefer allocator.free(prefix_copy);
                    const module_copy = try allocator.dupe(u8, entry.path);
                    errdefer allocator.free(module_copy);
                    try next_triggers.append(allocator, .{
                        .prefix = prefix_copy,
                        .module_path = module_copy,
                    });
                }
            },
            .static => {
                const ct_copy = try allocator.dupe(u8, entry.content_type);
                errdefer allocator.free(ct_copy);
                try next_statics.put(allocator, path_copy, .{
                    .content_type = ct_copy,
                    .hash_hex = entry.source_hex,
                });
            },
        }
    }

    // Sort triggers by prefix length descending (longest/innermost
    // first). AFTER chain iterates forward; BEFORE chain iterates
    // reverse. See TenantFilesSnapshot.triggers.
    const triggers_slice = try next_triggers.toOwnedSlice(allocator);
    errdefer {
        for (triggers_slice) |*e| {
            allocator.free(e.prefix);
            allocator.free(e.module_path);
        }
        allocator.free(triggers_slice);
    }
    std.mem.sort(TriggerEntry, triggers_slice, {}, struct {
        fn lessThan(_: void, a: TriggerEntry, b: TriggerEntry) bool {
            return a.prefix.len > b.prefix.len;
        }
    }.lessThan);

    // Gap 2.1 Phase B: discover subscription chain origins from
    // `_subscriptions/<name>/{index.mjs,spec.json}` manifest pairs.
    // Failures abort the deploy (consistent with the trigger
    // discovery posture above — a misconfigured subscription is a
    // load-time error, not a silent skip).
    const subscriptions_slice = try discoverSubscriptions(allocator, manifest, bs);
    errdefer {
        for (subscriptions_slice) |*s| {
            const mut: *globals.SubscriptionEntry = @constCast(s);
            mut.deinit(allocator);
        }
        if (subscriptions_slice.len > 0) allocator.free(subscriptions_slice);
    }

    // Build the new immutable snapshot. Refcount starts at 1 (the
    // slot's reference).
    const new_snap = try allocator.create(TenantFilesSnapshot);
    errdefer allocator.destroy(new_snap);
    new_snap.* = .{
        .allocator = allocator,
        .cache = cache,
        .deployment_id = manifest.id,
        .bytecodes = next_bc,
        .source_hashes = next_source_hashes,
        .statics = next_statics,
        .triggers = triggers_slice,
        .subscriptions = subscriptions_slice,
        .manifest_bytes = json_bytes,
        .refcount = .{ .raw = 1 },
    };
    json_bytes_consumed = true;

    // Atomic swap under `pin_lock` so any concurrent `pinCurrent`
    // either retains the OLD snapshot before swap (refcount goes
    // 1→2→1 across loader's release) or sees the NEW pointer
    // entirely. Without the lock, a load + retain pair could
    // straddle the swap+release and touch freed memory.
    slot.pin_lock.lock();
    const old_snap = slot.current.swap(new_snap, .acq_rel);
    slot.pin_lock.unlock();
    // Release-after-unlock is safe: the OLD pointer is no longer
    // reachable via `slot.current`, so no new pin can find it.
    // Pre-swap pins already retained.
    if (old_snap) |old| old.release();

    std.log.info(
        "rove-js: tenant {s} loaded deployment {d} ({d} handler(s), {d} static(s), {d} trigger(s), {d} subscription(s))",
        .{ slot.instance_id, manifest.id, new_snap.bytecodes.count(), new_snap.statics.count(), new_snap.triggers.len, new_snap.subscriptions.len },
    );

    // Gap 2.1 Phase D: enqueue boot subscriptions that haven't
    // yet fired against THIS deployment_id. Leader-only — boot
    // is "once per deployment activation across the cluster," not
    // "once per node." Followers see the `_boot_fired/<dep_id>`
    // marker via the leader's raft propose and skip on their own
    // reload.
    if (slot.raft) |raft| {
        if (raft.isLeader()) {
            enqueueBootSubscriptions(slot, new_snap) catch |err|
                std.log.warn(
                    "rove-js: tenant {s} boot enqueue: {s}",
                    .{ slot.instance_id, @errorName(err) },
                );
        }
    }
}

/// Gap 2.1 Phase D: leader-side scan of new snapshot's `.boot`
/// subscriptions; enqueue each one that hasn't fired yet (no
/// `_boot_fired/<dep_id>` marker in tenant kv). The actual firing
/// runs on a worker that drains the cross-thread inbox.
///
/// Idempotency contract: the `_boot_fired/<dep_id>` marker is
/// injected into the handler's writeset BEFORE the handler runs
/// (`worker_streaming.zig:1105`) so marker + handler effects
/// commit atomically through raft. A crash before commit leaves
/// nothing applied — next reload sees no marker, refires once.
/// A crash after commit leaves marker + handler effects both
/// applied — next reload skips. Single-fire semantics; no
/// "fired-but-not-marked" window.
pub fn enqueueBootSubscriptions(slot: *TenantSlot, snap: *TenantFilesSnapshot) !void {
    const router = slot.router orelse return; // unit-test slot: no router, no enqueue
    for (snap.subscriptions) |sub| {
        if (sub.spec != .boot) continue;

        var key_buf: [64]u8 = undefined;
        const marker_key = try std.fmt.bufPrint(&key_buf, "_boot_fired/{d}", .{snap.deployment_id});
        const existing = slot.app_kv.get(marker_key) catch |err| switch (err) {
            error.NotFound => null,
            else => {
                std.log.warn(
                    "rove-js boot ({s}/{s}): marker check failed: {s}",
                    .{ slot.instance_id, sub.name, @errorName(err) },
                );
                continue;
            },
        };
        if (existing) |e| {
            slot.allocator.free(e);
            continue; // already fired for this deployment
        }

        std.log.info(
            "rove-js boot enqueue: tenant={s} subscription={s} deployment={d}",
            .{ slot.instance_id, sub.name, snap.deployment_id },
        );

        // Push to the node-wide inbox; hash-routed to one of the
        // local workers. The worker's `drainSubFireInbox` moves the
        // message onto an `effect.SubscriptionFire` payload (via
        // `effect.enqueueMsg`) and `dispatchSubscriptionFires` fires
        // it on the next tick.
        router.enqueueSubscriptionFireForTenant(.{
            .tenant_id = slot.instance_id,
            .subscription_name = sub.name,
            .module_path = sub.module_path,
            .source = .{ .boot = .{ .deployment_id = snap.deployment_id } },
        }) catch |err| {
            std.log.warn(
                "rove-js boot enqueue ({s}/{s}): {s}",
                .{ slot.instance_id, sub.name, @errorName(err) },
            );
        };
    }
}
