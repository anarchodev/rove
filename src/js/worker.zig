//! `rove-js` worker — HTTP/2 server that runs a JS handler per request.
//!
//! `Worker(Options)` is a comptime-parameterized type that composes
//! `rove-h2` with a user-supplied `request_row` fragment. The fragment
//! is merged into h2's internal `StreamBaseRow` plus rove-js's own
//! `RaftWait` component, so per-request application state (session,
//! auth context, tape handles, ...) travels with the entity through
//! `request_out → raft_pending → response_in → response_out` without
//! rove-js or rove-h2 needing to know about user components. Library
//! composition follows the rove-library principle: never reach into
//! the inner library's collections, always thread user fragments
//! through the outer library's options.
//!
//! ## Request lifecycle
//!
//! ```
//! h2.request_out  ── dispatchPending ──▶  raft_pending (if writes)
//!                                     │
//!                                     └▶  h2.response_in (no writes)
//!
//! raft_pending    ── drainRaftPending ──▶  h2.response_in
//!                                      ── or 503 on fault/timeout ──▶
//! ```
//!
//! `dispatchPending` runs the handler, stamps response components onto
//! the entity, and either (a) moves it directly to `response_in` if no
//! writes were captured, or (b) sets `RaftWait{seq, deadline}` + kicks
//! off a raft propose + moves to `raft_pending`. `drainRaftPending`
//! polls each parked entity's seq against `raft.committedSeq()` and
//! `raft.faultedSeq()`, moving committed entities onward; this is the
//! shift-js "pending" collection pattern, replacing the synchronous
//! spin-wait that session 4 shipped as a placeholder.
//!
//! Parking means multiple requests can be in-flight through raft
//! simultaneously — the h2 poll loop no longer blocks waiting for a
//! commit. Concurrent requests are the whole reason this collection
//! exists.
//!
//! M1 scope: one hard-coded handler source per worker. Reading the
//! source from a files-server, route tables, and per-route bytecode
//! caching land once the worker's code-client is designed alongside
//! the files-server's HTTP/2 surface.
//!
//! The dispatch systems are plain functions, not methods — they take
//! `*Worker(...)` and are called by the user's poll loop between
//! `worker.poll(...)` and `reg.flush()`. Keeping systems outside the
//! Worker type mirrors shift-js's linear dispatch-is-a-phase pattern
//! and matches the rove-library "systems are pure" principle.

const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");
const qjs = @import("rove-qjs");
const kv_mod = @import("rove-kv");
const blob_mod = @import("rove-blob");
const files_mod = @import("rove-files");
const log_mod = @import("rove-log");
const log_server_mod = @import("rove-log-server");
const tape_mod = @import("rove-tape");
const tenant_mod = @import("rove-tenant");

const dispatcher_mod = @import("dispatcher.zig");
const globals = @import("globals.zig");
const apply_mod = @import("apply.zig");
const raft_propose = @import("raft_propose.zig");
const respb = @import("response_builder.zig");
const auth = @import("auth.zig");
const dispatch = @import("worker_dispatch.zig");
const panic_mod = @import("panic.zig");
const penalty_mod = @import("penalty.zig");
const limiter_mod = @import("limiter.zig");
const router_mod = @import("router.zig");
const reserved = @import("reserved.zig");
const release_table_mod = @import("release_table.zig");
const deployment_loader_mod = @import("deployment_loader.zig");
const Dispatcher = dispatcher_mod.Dispatcher;
const Request = dispatcher_mod.Request;

/// Per-request raft-wait state. Stamped onto the entity before it
/// parks in `raft_pending`, read by `drainRaftPending` each tick to
/// decide whether the request has committed, faulted, or timed out.
///
/// ## Flow
///
/// The dispatcher commits the TrackedTxn on the local tenant store
/// BEFORE parking — the writes are durable and the write lock is
/// released immediately, so other concurrent requests on the same
/// tenant can proceed. The raft propose happens in parallel to the
/// parking. On fault or timeout, `drainRaftPending` uses
/// `store.undoTxn(txn_seq)` to walk the kv_undo log and
/// compensating-rollback the writes that were already committed
/// locally. This is the pattern rove-kv's TrackedTxn + undo log was
/// built for.
///
/// Fields:
/// - `seq`: raft-side sequence from `raft.highWatermark()+1`, tracked
///   by `committedSeq()` / `faultedSeq()`.
/// - `txn_seq`: kv-side sequence from `beginTrackedImmediate`, used
///   as the key to `undoTxn` on fault or timeout.
/// - `deadline_ns`: absolute `std.time.nanoTimestamp()` deadline.
/// - `store`: pointer to the tenant's KvStore (for the undoTxn call).
pub const RaftWait = struct {
    seq: u64 = 0,
    txn_seq: u64 = 0,
    deadline_ns: i64 = 0,
    store: ?*kv_mod.KvStore = null,
};

/// Default handler entry path. Each tenant's deployment must have a
/// file at this path — it's the script the worker runs per request.
/// Name of the single handler file the old single-bytecode path
/// expected, kept as a constant for the smoke-test bootstrap that
/// publishes one `index.js` per tenant. The request router now picks
/// any file in the deployment (see `router.zig`), so this constant is
/// only a convenience for tools that want to know where the root entry
/// point lives by default.
pub const DEFAULT_HANDLER_PATH = "index.js";

/// Tick-local scratch list of tenants that refused `BEGIN IMMEDIATE`
/// with `SQLITE_BUSY` during the current tick. Owned by the caller
/// (the worker main loop), cleared at the top of each tick, passed
/// by-pointer into `dispatchOnce` so a blocked tenant doesn't get
/// picked as anchor again until the tick ends and the list is
/// cleared.
///
/// Bounded at 32 — far above the realistic handful-of-tenants-per-
/// tick workloads we've measured. `append` returns `error.Overflow`
/// if the cap is exceeded; `dispatchOnce` treats that as "stop for
/// now, try again next tick".
pub const BlockedTenants = struct {
    items: [32]*const tenant_mod.Instance = undefined,
    len: usize = 0,

    pub fn clear(self: *BlockedTenants) void {
        self.len = 0;
    }

    pub fn slice(self: *const BlockedTenants) []const *const tenant_mod.Instance {
        return self.items[0..self.len];
    }

    pub fn append(self: *BlockedTenants, inst: *const tenant_mod.Instance) !void {
        if (self.len >= self.items.len) return error.Overflow;
        self.items[self.len] = inst;
        self.len += 1;
    }
};


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
fn triggerPathToPrefix(path: []const u8) ?[]const u8 {
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

/// Reloaded by `applyPendingReleases` whenever the dashboard / CLI
/// pushes a new deployment id into the process-wide `ReleaseTable`
/// via `/_system/release`.
pub const TenantFiles = struct {
    allocator: std.mem.Allocator,
    /// Owned copy of the instance id. Used as the key in the worker's
    /// `tenant_files_map` map; owning it here keeps that map's lifetime
    /// self-contained.
    instance_id: []u8,
    /// Borrowed pointer to the tenant's app.db — used to read
    /// `_deploy/current` (set by the release POST, replicated via
    /// envelope 0). Phase 5.5(e) F2-storage retired the per-tenant
    /// `files.db` on the worker entirely; the worker never opens
    /// files-server's local working tree.
    app_kv: *kv_mod.KvStore,
    /// Owned blob backend for the file-blobs (source + bytecode bytes).
    /// With `.fs` config: opens at `{inst.dir}/file-blobs/`. With
    /// `.s3`: shares the bucket with every other tenant on this node,
    /// scoped by key prefix `{base}{inst.id}/file-blobs/`.
    blob_backend: blob_mod.BlobBackend,
    /// Owned blob backend for per-deployment manifest JSON. Same fs/
    /// s3 picker as `blob_backend`, just a different per-tenant
    /// subdir (`deployments/`). Files-server writes here at deploy
    /// time; the worker reads here on `applyPendingReleases`.
    manifest_backend: blob_mod.BlobBackend,
    /// Deployment id we last loaded. `0` = no deployment observed yet.
    current_deployment_id: u64,
    /// All handler bytecodes from the active deployment, keyed by the
    /// full deployment path (e.g. `"index.js"`, `"api/users/index.js"`).
    /// Both keys and values are owned by `allocator`.
    bytecodes: std.StringHashMapUnmanaged([]u8),
    /// Source-blob hash hex (64 chars) per handler path. Parallel to
    /// `bytecodes` and refreshed alongside it. Read by the QuickJS
    /// module loader to populate the per-request module-resolution
    /// tape — replay needs the source hash to fetch the same bytes
    /// from the file blob store. Owns its own key copies (allocator-
    /// duped from manifest entries) so it can be torn down
    /// independently of `bytecodes`.
    source_hashes: std.StringHashMapUnmanaged([64]u8),
    /// Static files in the active deployment, keyed by the stored path
    /// (e.g. `"_static/index.html"`). Keys and `StaticEntry.content_type`
    /// are owned by `allocator`; bytes are fetched from `blob_backend`
    /// on demand.
    statics: std.StringHashMapUnmanaged(StaticEntry),
    /// Trigger registry derived from manifest entries matching
    /// `_triggers/.../index.{mjs,js}`. Sorted by prefix length
    /// **descending** so a forward scan visits innermost (most-specific)
    /// triggers first — natural for AFTER chain (innermost-first); the
    /// BEFORE chain reverses (outermost-first). See PLAN §2.5 for the
    /// tree-traversal-order rationale.
    triggers: []TriggerEntry,
    /// One-shot prefetched manifest bytes from the worker's
    /// cold-start batch fetch (production.md #1.4). Consumed and
    /// freed on the first `reloadDeployment(dep_id)` call whose
    /// dep_id matches. Lets startup load every tenant's manifest
    /// from one HTTP roundtrip instead of N. Null when no
    /// prefetch was wired or this tenant wasn't in the batch.
    prefetched_manifest: ?PrefetchedManifest,
    /// Raw manifest bytes for `current_deployment_id`. Populated
    /// in `reloadDeployment` after successful decode (transfers
    /// ownership from the prefetch slot or the per-tenant fetch
    /// result). Re-released callers (`handleRelease`) check this
    /// on dep_id match + re-decode locally, skipping the HTTP
    /// roundtrip. Cleared + re-populated on every successful
    /// reloadDeployment with a different dep_id; freed at
    /// teardown.
    current_manifest_bytes: ?[]u8,

    pub fn open(worker: anytype, inst: *const tenant_mod.Instance) !*TenantFiles {
        return openTenantFiles(worker, inst);
    }

    pub fn free(allocator: std.mem.Allocator, tc: *TenantFiles) void {
        freeTenantFiles(allocator, tc);
    }
};

/// Worker never uploads code, so the `CompileFn` it passes into
/// `FileStore.init` just errors out — making accidental put-source
/// calls impossible to ignore.
fn stubCompile(
    _: ?*anyopaque,
    _: []const u8,
    _: [:0]const u8,
    _: std.mem.Allocator,
) anyerror![]u8 {
    return error.CompileNotSupportedOnWorker;
}

/// Per-tenant log state held by the worker — currently just the
/// per-tenant `RequestIdMinter`. Opened eagerly in `Worker.create`,
/// closed in `Worker.destroy`.
///
/// The in-memory record buffer that used to live here has moved to
/// the worker-wide `log_buffer: NodeLogBuffer` (one buffer per node,
/// not per tenant), since every flush combines all tenants' records
/// into one batch anyway. See `docs/logs-plan.md` §3.1 / §6.9.
pub const TenantLog = struct {
    allocator: std.mem.Allocator,
    instance_id: []u8,
    id_minter: log_mod.RequestIdMinter,

    pub fn open(worker: anytype, inst: *const tenant_mod.Instance) !*TenantLog {
        return openTenantLog(worker, inst, worker.log_worker_id);
    }

    pub fn free(allocator: std.mem.Allocator, tl: *TenantLog) void {
        freeTenantLog(allocator, tl);
    }
};

/// Cache wrapper around `StringHashMapUnmanaged(*Entry)` that drives
/// the lifecycle through `Entry.open(worker, inst)` and `Entry.free(
/// allocator, *Entry)`. `TenantFiles` and `TenantLog` had eight
/// near-identical helpers (open / free / destroyAll / getOrOpen × 2);
/// only open and free are domain-specific, so this generic absorbs
/// destroyAll and getOrOpen.
fn TenantMap(comptime Entry: type) type {
    return struct {
        const Self = @This();

        map: std.StringHashMapUnmanaged(*Entry) = .empty,

        pub const empty: Self = .{};

        /// Free every entry and the map's internal storage.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.clearAllEntries(allocator);
            self.map.deinit(allocator);
        }

        /// Free every entry but keep the map's internal capacity. Used
        /// by `Worker.create`'s errdefer path so a failure mid-eager-
        /// open clears the entries it created without preempting the
        /// final `deinit` that fires from `Worker.destroy`.
        pub fn clearAllEntries(self: *Self, allocator: std.mem.Allocator) void {
            var it = self.map.iterator();
            while (it.next()) |entry| Entry.free(allocator, entry.value_ptr.*);
            self.map.clearRetainingCapacity();
        }

        /// Eagerly insert an already-opened entry. Worker.create uses
        /// this to prefill the map; the entry's owned `instance_id`
        /// becomes the map key (its lifetime matches the entry's).
        pub fn put(self: *Self, allocator: std.mem.Allocator, entry: *Entry) !void {
            try self.map.put(allocator, entry.instance_id, entry);
        }

        /// Lookup-or-lazy-open: if the map already has an entry for
        /// `inst`, return it. Otherwise open via `Entry.open`, cache,
        /// and return. On a failed `put`, frees the just-opened entry.
        pub fn getOrOpen(
            self: *Self,
            worker: anytype,
            inst: *const tenant_mod.Instance,
        ) !*Entry {
            if (self.map.get(inst.id)) |e| return e;
            const opened = try Entry.open(worker, inst);
            self.map.put(worker.allocator, opened.instance_id, opened) catch |err| {
                Entry.free(worker.allocator, opened);
                return err;
            };
            return opened;
        }

        pub fn get(self: *const Self, id: []const u8) ?*Entry {
            return self.map.get(id);
        }

        pub fn iterator(self: *Self) std.StringHashMapUnmanaged(*Entry).Iterator {
            return self.map.iterator();
        }
    };
}

pub const Options = struct {
    /// Application-specific components to attach to every request entity.
    /// Merged into h2's `StreamBaseRow` alongside rove-js's own
    /// `RaftWait` component. User fragments survive the whole lifecycle
    /// because every h2 stream collection (and rove-js's `raft_pending`)
    /// uses the merged row.
    request_row: type = rove.Row(&.{}),
    /// Application-specific components on h2 connections. Pass-through
    /// to `rove-h2`.
    connection_row: type = rove.Row(&.{}),
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

pub const WorkerConfig = struct {
    /// Tenant resolver. Every request's `:authority` header is looked
    /// up here to find the owning instance; the handler's `kv.*` global
    /// then talks to that instance's dedicated `KvStore` file. Requests
    /// whose authority doesn't resolve get a 404. Owned by the caller.
    tenant: *tenant_mod.Tenant,
    /// Raft node for write replication. All writes captured during a
    /// handler are proposed through this node; the worker blocks until
    /// the proposal commits or faults before sending the response.
    /// Owned by the caller — the worker does NOT drive `run()` on it,
    /// the caller spawns the raft thread. In M1 this is a single-node
    /// cluster (auto-leader). Multi-node arrives later.
    raft: *kv_mod.RaftNode,
    /// Listen address passed through to rove-io.
    addr: std.net.Address,
    /// rove-io options (ring size, buffer pool). Defaults are sensible.
    io_opts: rio.IoOptions = .{},
    /// rove-h2 options (window sizes, limits).
    h2_opts: h2.H2Options = .{},
    /// Upper bound on how long a parked raft proposal can wait before
    /// we compensate-rollback and return 503. See `RaftWait` docs.
    commit_wait_timeout_ns: u64 = 2 * std.time.ns_per_s,
    /// Process-wide `tenant_id → released_dep_id` table the worker
    /// reads on every dispatch tick. The dashboard / CLI POST to
    /// `/_system/release` after each successful files-server deploy
    /// stamps the new id here; `applyPendingReleases` triggers the
    /// reload. When null, releases never reach the worker — useful
    /// only for tests that pre-load every deployment at startup.
    release_table: ?*release_table_mod.ReleaseTable = null,
    /// Phase 5.5(a) Step B / Phase 5.5(e) Step F1 — HMAC-SHA256
    /// secret used to sign JWTs minted at `/_system/services-token`.
    /// The standalone log-server + files-server (separate threads /
    /// processes, addressable at `log_public_base` + `files_public_base`)
    /// verify the same JWT on every request. Borrowed; the caller
    /// keeps the bytes alive for the worker's lifetime. When null,
    /// `/_system/services-token` returns 503.
    services_jwt_secret: ?[]const u8 = null,
    /// Public origin the dashboard uses to reach the log-server.
    /// Returned in the `/_system/services-token` response. Borrowed.
    log_public_base: ?[]const u8 = null,
    /// Public origin the dashboard / CLI uses to reach files-server.
    /// Returned in the `/_system/services-token` response. Borrowed.
    files_public_base: ?[]const u8 = null,
    /// Origin the worker uses to deliver `events.emit` payloads to
    /// the sse-server's `POST /v1/emit`. Plain http://host:port for
    /// loopback dev, https://sse.{public_suffix} in production.
    /// Borrowed; null disables the worker → sse-server POST path.
    sse_public_base: ?[]const u8 = null,
    /// Shared bearer the worker stamps in `Authorization: Bearer ...`
    /// on every emit POST. Must match the value sse-server is started
    /// with in `SSE_INTERNAL_TOKEN`. Borrowed; null disables the path.
    sse_internal_token: ?[]const u8 = null,
    /// Skip TLS peer verification on the worker → sse-server emit
    /// POST. Set true in dev / smoke clusters where sse-server uses
    /// a self-signed cert that's not in the worker's system CA
    /// bundle. Production must leave this false.
    sse_insecure_tls: bool = false,
    /// Origin allowed to call `/_system/*` with CORS. When set, the
    /// worker answers browser preflight (OPTIONS) requests from this
    /// origin and stamps `Access-Control-Allow-*` headers onto every
    /// `/_system/*` response. Unset disables CORS entirely — admin UI
    /// callers must then be same-origin. The string is borrowed; the
    /// caller keeps it alive for the worker's lifetime.
    admin_origin: ?[]const u8 = null,
    /// Base domain for the per-tenant admin API. When set, any
    /// request whose Host is `admin_api_domain` exactly (scope =
    /// `__admin__`) or `{id}.{admin_api_domain}` (scope = `{id}`)
    /// runs the `__admin__` tenant's deployed handler with `kv`
    /// rebound to the scope's store. Root bearer token required.
    /// Borrowed; caller keeps it alive for the worker's lifetime.
    admin_api_domain: ?[]const u8 = null,
    /// Upper 16 bits of every `request_id` this worker's tenants
    /// mint. Must be unique per Worker instance within one process
    /// — if two workers on the same node both use the same id,
    /// their captured log records will collide on `nextRequestId`.
    /// When null, falls back to `raft.config.node_id`, which is
    /// correct for the single-worker-per-process case but wrong for
    /// multi-worker.
    log_worker_id: ?u16 = null,
    /// Per-(instance, action) rate limit caps. v1 uses a single
    /// tier — operator can tune via CLI flags before launch.
    /// Phase 10 will branch on instance plan tier.
    rate_limit_caps: limiter_mod.RateLimitCaps = .{},
    /// JS → bytecode compiler used by the signup path to deploy
    /// starter content for a freshly-created instance. When null,
    /// signup still creates the instance but skips the deploy, so
    /// the tenant's `{id}.loop46.me` returns 503 until the customer
    /// pushes their own code. The embedding binary is expected to
    /// wire a real QuickJS compiler through here in production.
    compile_fn: ?files_mod.CompileFn = null,
    /// Opaque pointer handed back to `compile_fn`. Per-thread —
    /// each worker thread typically gets its own compiler instance
    /// because QuickJS runtimes aren't shareable across threads.
    compile_ctx: ?*anyopaque = null,
    /// S3 blob backend each `TenantFiles` / `TenantLog` opens. One
    /// bucket across all tenants on the node, scoped per-tenant by
    /// key prefix `{base}{instance_id}/{subdir}/`. Owned by the
    /// caller — backend strings (endpoint, region, etc.) must outlive
    /// the worker's `create` call (S3BlobStore.init dupes them, so
    /// afterwards they can be freed).
    blob_backend: blob_mod.BackendConfig,
    /// When set, manifest reads route through a colocated files-server
    /// over HTTP/2 instead of S3 (production.md #1.4 step 4 —
    /// manifests live in raft-replicated KV inside the files-server
    /// cluster, not S3). The S3 `blob_backend` above stays in use
    /// for file-blobs (content-addressed bytecode + static asset
    /// bytes); only the per-tenant manifest_backend swaps storage
    /// layer. Null (default) keeps the legacy S3-direct manifest
    /// path. Borrowed; the loop46 binary owns the storage for the
    /// process lifetime.
    manifest_http: ?ManifestHttpConfig = null,
    /// Cold-start manifest prefetch results, keyed by tenant id.
    /// When the operator wires `manifest_http` and runs the bulk
    /// fetch at startup, the resulting bytes land here. Each
    /// tenant's `TenantFiles.open` consumes its entry on first
    /// reload + frees the bytes. Ownership of the map + every
    /// key + value transfers to the Worker on `create`. Null
    /// skips the prefetch path; per-tenant fetch via
    /// `manifest_http` (or S3 fallback) still works.
    manifest_prefetch: ?std.StringHashMapUnmanaged(PrefetchedManifest) = null,
    /// Pre-built libcurl Easy handle the worker's per-tenant
    /// manifest backends share. Ownership transfers to the
    /// Worker on `create`. Sharing one Easy across cold-start
    /// prefetch + every per-tenant manifest fetch keeps libcurl's
    /// connection + TLS-session cache warm across the whole
    /// worker lifetime — the only way for per-release manifest
    /// fetches to land in single-digit milliseconds.
    manifest_easy: ?*blob_mod.curl.Easy = null,
    /// Phase 5.5 (a) — `BatchStore` the worker flushes log batches
    /// into. loop46 always supplies one — S3 if env wired, in-memory
    /// otherwise. Required because `flushLogs` shouldn't have to
    /// reason about a missing observability backend.
    log_batch_store: log_server_mod.batch_store.BatchStore,
};

pub const dispatchOnce = dispatch.dispatchOnce;

pub fn Worker(comptime opts: Options) type {
    // rove-js contributes `RaftWait` to every request entity so we can
    // park entities in `raft_pending` without allocating side state.
    // No proxy components anymore — Phase 5.5 retired all `/_system/*`
    // proxies (logs Step B, files Step F1) in favor of standalone
    // services on their own subdomains.
    const merged_request_row = rove.Row(&.{RaftWait}).merge(opts.request_row);

    const H2Type = h2.H2(.{
        .request_row = merged_request_row,
        .connection_row = opts.connection_row,
        .client = true,
    });

    const StreamRow = H2Type.StreamRow;
    const StreamColl = rove.Collection(StreamRow, .{});

    return struct {
        const Self = @This();

        pub const H2 = H2Type;
        pub const RequestRow = StreamRow;

        allocator: std.mem.Allocator,
        reg: *rove.Registry,
        h2: *H2Type,
        /// Entities waiting on raft commit. Stored on the Worker (not
        /// inside h2) because this is rove-js state, not h2 state.
        /// Uses the same row as every other h2 stream collection so
        /// moves in and out preserve every component.
        raft_pending: StreamColl,
        dispatcher: Dispatcher,
        tenant: *tenant_mod.Tenant,
        raft: *kv_mod.RaftNode,
        /// Per-tenant code state. Keyed by instance id (the string the
        /// `TenantFiles` owns internally — the map slot's key points at
        /// that allocation, so lifetimes line up).
        tenant_files_map: TenantMap(TenantFiles),
        /// Per-tenant log state. Same lifetime + key-stability story
        /// as `tenant_files_map`. Opened eagerly alongside it. Holds
        /// each tenant's `RequestIdMinter`; the in-memory record
        /// buffer is `log_buffer` (per-node, not per-tenant).
        tenant_logs: TenantMap(TenantLog),
        /// Per-node in-memory `LogRecord` buffer. Every tenant's
        /// dispatch tick appends here; `flushLogs` drains the whole
        /// buffer into one combined batch per flush window. Replaces
        /// the per-tenant `LogStore.buffer` from before Phase 5.5(a-2).
        log_buffer: log_mod.NodeLogBuffer,
        /// Circuit breaker for handlers that blow past their CPU
        /// budget. A tenant with `kill_threshold` interrupts inside a
        /// single `window_ns` gets bounced with 503 for
        /// `open_duration_ns` — protecting the shared h2 thread from a
        /// runaway stored procedure. Auto-releases on redeploy.
        penalty_box: penalty_mod.PenaltyBox,
        /// Per-instance × per-action token-bucket limits. Single tier
        /// in v1 (`limiter_mod.defaultCaps()`); Phase 10 will branch
        /// on plan. Customer-tenant traffic checks the `request`
        /// bucket before dispatch and gets 429 + Retry-After when
        /// exhausted; admin requests bypass the check entirely.
        /// `email.send` from a handler checks the `email` bucket and
        /// throws a catchable JS Error{code:"rate_limited"} when
        /// exhausted.
        limiter: limiter_mod.RateLimiter,
        commit_wait_timeout_ns: u64,
        /// Borrowed from `WorkerConfig.release_table`. See the config
        /// field for semantics. Null disables the push surface entirely.
        release_table: ?*release_table_mod.ReleaseTable,
        /// Borrowed from `WorkerConfig.admin_origin`. See the config
        /// field for semantics. Null when CORS is disabled.
        admin_origin: ?[]const u8,
        /// Borrowed from `WorkerConfig.admin_api_domain`. Hostname
        /// that hosts the admin API + dashboard. Null disables admin
        /// routing entirely. Cross-tenant scoping uses the
        /// `X-Rove-Scope: <id>` header on this host.
        admin_api_domain: ?[]const u8,
        /// Upper 16 bits every `RequestIdMinter.nextRequestId()`
        /// minted by this worker stamps onto ids so they don't
        /// collide with other workers' ids. Copied from
        /// `WorkerConfig.log_worker_id` (or the raft node id as a
        /// fallback).
        log_worker_id: u16,
        /// Compile callback used by signup to deploy starter content.
        /// Borrowed from `WorkerConfig.compile_fn` / `compile_ctx`.
        compile_fn: ?files_mod.CompileFn,
        compile_ctx: ?*anyopaque,
        /// Picks fs vs s3 for every per-tenant blob backend this
        /// worker opens. Borrowed from `WorkerConfig.blob_backend`.
        blob_backend_cfg: blob_mod.BackendConfig,
        /// Borrowed from `WorkerConfig.manifest_http`. When set,
        /// `openTenantFiles` opens an HTTP-backed manifest_backend
        /// instead of S3 — see the field doc on WorkerConfig.
        manifest_http: ?ManifestHttpConfig,
        /// Cold-start manifest prefetch — see `WorkerConfig`. The
        /// map's keys + values are worker-owned; openTenantFiles
        /// consumes (fetchRemove) per tenant and frees on use.
        /// At Worker.deinit any leftover entries are freed.
        manifest_prefetch: ?std.StringHashMapUnmanaged(PrefetchedManifest),
        /// Shared libcurl handle for every per-tenant manifest
        /// HttpBlobStore on this worker. Created at `create` when
        /// `manifest_http` is wired; null otherwise. libcurl
        /// caches connections + TLS sessions per-handle, so
        /// sharing across tenants keeps the connection warm
        /// across per-tenant manifest fetches (release handler,
        /// dispatch tick reload). Without sharing, each tenant's
        /// own Easy paid a fresh TLS handshake on first call.
        /// Concurrent calls serialize through libcurl's internal
        /// mutex; the worker's dispatch loop is single-threaded
        /// so this never contends.
        manifest_easy: ?*blob_mod.curl.Easy,
        /// Phase 5.5 (a) — store the worker flushes log batches into.
        /// Lives for the worker's full lifetime; loop46 picks S3 vs
        /// in-memory at startup.
        log_batch_store: log_server_mod.batch_store.BatchStore,
        /// Phase 5.5(a) Step B / Phase 5.5(e) Step F1 — JWT secret +
        /// public origins for the standalone services. Returned to the
        /// dashboard via `/_system/services-token`.
        services_jwt_secret: ?[]const u8,
        log_public_base: ?[]const u8,
        files_public_base: ?[]const u8,
        /// SSE delivery wiring (sse-plan §3.2). `sse_curl` is a
        /// libcurl handle owned by the worker, lazily created on
        /// `create` when both `sse_public_base` and
        /// `sse_internal_token` are set. Null disables the
        /// fire-and-forget POST path entirely; emits then live only
        /// in the legacy `_events/{sid}/...` rows.
        sse_public_base: ?[]const u8,
        sse_internal_token: ?[]const u8,
        sse_insecure_tls: bool,
        sse_curl: ?*blob_mod.curl.Easy,

        /// Background log flusher — owns its own thread, sleeps on
        /// `flusher_wake` between ticks, drains the worker's
        /// `log_buffer` via `flushLogs`, and PUTs each batch into
        /// `log_batch_store`. Decouples request latency from S3 RTT:
        /// the dispatch path's `captureLog` is now a mutex-protected
        /// ArrayList.append, with the multi-millisecond S3 round-
        /// trip happening asynchronously on this thread. `null` when
        /// the worker is configured without a log backend.
        flusher_thread: ?std.Thread = null,
        flusher_should_stop: std.atomic.Value(bool) = .init(false),
        flusher_wake: std.Thread.ResetEvent = .{},

        /// Background deployment loader (see
        /// `src/js/deployment_loader.zig`). The hot path enqueues
        /// loads here; the loader thread runs `reloadDeployment`
        /// off the dispatch loop so no request thread blocks on
        /// network I/O. Null when the worker was started without
        /// the loader wired (unit-test paths that don't need it).
        deployment_loader: ?*deployment_loader_mod.DeploymentLoader = null,

        /// Heap-allocate a worker, construct the inner `H2` (which in
        /// turn constructs its own `Io`), and eagerly open a
        /// `TenantFiles` for every instance currently registered with
        /// the tenant. Tenants that have no deployment yet get a
        /// `TenantFiles` with `handler_bytecode = null` — requests
        /// hitting them return 503 until a deploy lands.
        ///
        /// All tenants must exist BEFORE the raft thread starts, so
        /// create the worker after the tenant bootstrap but before
        /// spawning the raft thread. Dynamic tenant creation
        /// (lazy-open from the dispatch path) is a future session.
        pub fn create(
            allocator: std.mem.Allocator,
            reg: *rove.Registry,
            config: WorkerConfig,
        ) !*Self {
            const server = try H2Type.create(
                reg,
                allocator,
                config.addr,
                config.io_opts,
                config.h2_opts,
            );
            errdefer server.destroy();

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .reg = reg,
                .h2 = server,
                .raft_pending = try StreamColl.init(allocator),
                .dispatcher = try Dispatcher.init(allocator),
                .tenant = config.tenant,
                .raft = config.raft,
                .tenant_files_map = .empty,
                .tenant_logs = .empty,
                .log_buffer = log_mod.NodeLogBuffer.init(allocator),
                .penalty_box = penalty_mod.PenaltyBox.init(allocator, .{}),
                .limiter = limiter_mod.RateLimiter.init(allocator, config.rate_limit_caps),
                .commit_wait_timeout_ns = config.commit_wait_timeout_ns,
                .release_table = config.release_table,
                .admin_origin = config.admin_origin,
                .admin_api_domain = config.admin_api_domain,
                .log_worker_id = config.log_worker_id orelse @intCast(config.raft.config.node_id),
                .compile_fn = config.compile_fn,
                .compile_ctx = config.compile_ctx,
                .blob_backend_cfg = config.blob_backend,
                .manifest_http = config.manifest_http,
                .manifest_prefetch = config.manifest_prefetch,
                .manifest_easy = config.manifest_easy,
                .log_batch_store = config.log_batch_store,
                .services_jwt_secret = config.services_jwt_secret,
                .log_public_base = config.log_public_base,
                .files_public_base = config.files_public_base,
                .sse_public_base = config.sse_public_base,
                .sse_internal_token = config.sse_internal_token,
                .sse_insecure_tls = config.sse_insecure_tls,
                .sse_curl = blk: {
                    if (config.sse_public_base == null or config.sse_internal_token == null) break :blk null;
                    break :blk blob_mod.curl.Easy.init(allocator) catch |err| {
                        std.log.warn("rove-js: sse libcurl init failed: {s}; emit POST disabled", .{@errorName(err)});
                        break :blk null;
                    };
                },
            };
            errdefer self.raft_pending.deinit();
            errdefer self.tenant_files_map.clearAllEntries(allocator);
            errdefer self.tenant_logs.clearAllEntries(allocator);

            reg.registerCollection(&self.raft_pending);

            // Eagerly open code AND log state for every known tenant.
            // The tenant registry's instances map was populated by
            // the caller before this create() call; we iterate it
            // once and open both per-tenant stores.
            var it = config.tenant.instances.iterator();
            while (it.next()) |entry| {
                const inst = entry.value_ptr.*;
                try self.tenant_files_map.put(allocator, try TenantFiles.open(self, inst));
                try self.tenant_logs.put(allocator, try TenantLog.open(self, inst));
            }

            self.flusher_thread = try std.Thread.spawn(.{}, flusherLoop, .{self});

            // Spin up the deployment loader. The hot path enqueues
            // here when a new release pointer is observed; the
            // loader thread runs `reloadDeployment` off the dispatch
            // loop. Failure to init is non-fatal — falls back to
            // the synchronous reload in `applyPendingReleases`.
            const loader = deployment_loader_mod.DeploymentLoader.init(
                allocator,
                @as(?*anyopaque, @ptrCast(self)),
                deploymentLoadFn,
            ) catch |err| blk: {
                std.log.warn(
                    "rove-js: deployment loader init failed: {s} — falling back to synchronous reload",
                    .{@errorName(err)},
                );
                break :blk null;
            };
            if (loader) |l| {
                l.start() catch |err| {
                    std.log.warn(
                        "rove-js: deployment loader start failed: {s}",
                        .{@errorName(err)},
                    );
                    l.deinit();
                    self.deployment_loader = null;
                };
                self.deployment_loader = l;
            }

            return self;
        }

        /// `DeploymentLoader.LoadFn` thunk. Casts the opaque
        /// worker pointer back to `*Self`, looks up the
        /// requested tenant's `TenantFiles`, and runs
        /// `reloadDeployment` on the loader thread. Errors are
        /// logged + swallowed; a failed load is retried on the
        /// next release that targets this tenant.
        fn deploymentLoadFn(
            ctx_opaque: ?*anyopaque,
            tenant_id: []const u8,
            dep_id: u64,
        ) anyerror!void {
            const worker: *Self = @ptrCast(@alignCast(ctx_opaque.?));
            const tc = worker.tenant_files_map.get(tenant_id) orelse return;
            if (tc.current_deployment_id == dep_id) return; // already loaded
            try reloadDeployment(tc, dep_id);
        }

        /// Background log-flusher loop. Wakes every
        /// `FLUSHER_TICK_NS` (50 ms — matches the existing periodic
        /// scheduler default) OR immediately when `flusher_wake` is
        /// signalled. Calls `flushLogs(self)` which checks the node-
        /// wide `log_buffer` against its thresholds (count / bytes /
        /// time) and, when crossed, drains + PUTs through
        /// `log_batch_store`. The S3 RTT happens entirely on this
        /// thread — the dispatch path stays free of synchronous
        /// network I/O.
        ///
        /// Exits when `flusher_should_stop` flips true. We deliberately
        /// do NOT do a final blocking drain on shutdown — the last
        /// partial batch is best-effort, and a graceful stop must not
        /// block the worker process on a multi-second S3 PUT (which
        /// would in turn block whatever supervisor is waiting on the
        /// child). This matches the stated lossy-on-node-failure
        /// semantics in `docs/logs-plan.md`: in-flight log records
        /// can be lost on shutdown.
        fn flusherLoop(self: *Self) void {
            const FLUSHER_TICK_NS: u64 = 50 * std.time.ns_per_ms;
            while (!self.flusher_should_stop.load(.acquire)) {
                _ = flushLogs(self) catch |err| {
                    std.log.warn("rove-js flusher: flushLogs failed: {s}", .{@errorName(err)});
                };
                self.flusher_wake.timedWait(FLUSHER_TICK_NS) catch {};
                self.flusher_wake.reset();
            }
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            // Stop the deployment loader FIRST — it holds
            // `TenantFiles` pointers via the load thunk and we
            // want it quiesced before we free the tenant map.
            if (self.deployment_loader) |loader| {
                loader.shutdown();
                loader.deinit();
                self.deployment_loader = null;
            }
            // Signal the flusher thread to stop, wake it, and join.
            // The flusher's only blocking call is libcurl's
            // `curl_easy_perform`, which is bounded by `Easy`'s
            // 15 s `CURLOPT_TIMEOUT_MS` — so join can never wait
            // longer than one in-flight PUT plus the libcurl
            // ceiling. No detach / leak path needed.
            if (self.flusher_thread) |t| {
                self.flusher_should_stop.store(true, .release);
                self.flusher_wake.set();
                t.join();
                self.flusher_thread = null;
            }
            self.limiter.deinit();
            self.penalty_box.deinit();
            self.tenant_logs.deinit(allocator);
            self.log_buffer.deinit();
            self.tenant_files_map.deinit(allocator);
            // Free any prefetch entries the worker never consumed
            // (tenants for which `openTenantFiles` ran without
            // hitting the prefetch — e.g. concurrent
            // createInstance during boot, or tenants the bulk
            // fetch couldn't cover).
            if (self.manifest_prefetch) |*map| {
                var pit = map.iterator();
                while (pit.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*.bytes);
                }
                map.deinit(allocator);
            }
            self.raft_pending.deinit();
            self.dispatcher.deinit();
            if (self.sse_curl) |easy| easy.deinit();
            if (self.manifest_easy) |easy| easy.deinit();
            self.h2.destroy();
            allocator.destroy(self);
        }

        /// Forward to the h2 poll loop. Exposed so callers don't have to
        /// reach into `worker.h2` for the common case.
        pub fn poll(self: *Self, min_complete: u32) !void {
            try self.h2.poll(min_complete);
        }

        /// Forward to h2's bounded-wait poll. Use this when there's
        /// external state needing periodic attention (parked entities
        /// in `raft_pending`, deployment refresh deadlines, etc.) so
        /// the loop neither blocks indefinitely nor spins at 100% CPU.
        pub fn pollWithTimeout(self: *Self, timeout_ns: u64) !void {
            try self.h2.pollWithTimeout(timeout_ns);
        }

        /// Trampoline for `platform.instances.deployStarter(name)`.
        /// Wired into the admin-handler request via
        /// `Request.deploy_starter` + `.deploy_starter_ctx`. The
        /// pair lets globals.zig invoke this without depending on
        /// the generic `Worker(opts)` type — the caller passes the
        /// `*anyopaque` it received as `ctx`, we cast back to
        /// `*Self`, and run starter-deploy with envelope-0 propose
        /// for the `_deploy/current` release pointer.
        ///
        /// Returns `error.InstanceNotFound` if `target_id` doesn't
        /// resolve, `error.CompileFnUnavailable` if this worker has
        /// no compile callback wired (library mode). Other errors
        /// propagate from `deployStarterContent`.
        pub fn deployStarterTrampoline(
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            target_id: []const u8,
        ) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const inst_opt = self.tenant.getInstance(target_id) catch
                return error.InstanceNotFound;
            const inst = inst_opt orelse return error.InstanceNotFound;
            const compile_fn = self.compile_fn orelse
                return error.CompileFnUnavailable;

            // `deployStarterContent` writes the manifest JSON to the
            // tenant's `deployments/` BlobBackend on disk, then
            // stages `_deploy/current = 1` into `release_ws`. We
            // commit that write locally + propose envelope 0 so
            // followers see the release pointer too.
            var release_ws = kv_mod.WriteSet.init(allocator);
            defer release_ws.deinit();
            try deployStarterContent(
                allocator,
                inst.dir,
                inst.id,
                self.blob_backend_cfg,
                compile_fn,
                self.compile_ctx,
                &release_ws,
            );

            var txn = try inst.kv.beginTrackedImmediate();
            errdefer txn.rollback() catch {};
            for (release_ws.ops.items) |op| switch (op) {
                .put => |p| try txn.put(p.key, p.value),
                .delete => |d| try txn.delete(d.key),
            };
            try txn.commit();

            _ = raft_propose.proposeWriteSet(self, &release_ws, target_id) catch |err| {
                std.log.warn(
                    "deployStarter: propose envelope 0 for {s} _deploy/current failed: {s}",
                    .{ target_id, @errorName(err) },
                );
            };
            inst.kv.commitTxn(txn.txn_seq) catch |err| {
                std.log.warn(
                    "deployStarter: commitTxn for {s} failed: {s}",
                    .{ target_id, @errorName(err) },
                );
            };
        }

    };
}

// ── Per-tenant code loading ───────────────────────────────────────────
//
// These helpers open a tenant's blob backends (`{inst.dir}/file-blobs/`
// for source + bytecode bytes, `{inst.dir}/deployments/` for manifest
// JSON) and load the active deployment from the tenant's app.db
// `_deploy/current` pointer. Called eagerly during `Worker.create` for
// every registered instance, and by `applyPendingReleases` whenever
// the dashboard / CLI pushes a new release into the `ReleaseTable`.

/// Open (or re-use) a tenant code state. Allocates a `*TenantFiles`
/// and attempts to load the current deployment's handler bytecode.
/// If the tenant has no deployment yet, the `handler_bytecode` stays
/// `null` and requests against this tenant return 503.
///
/// Also runs `recoverOrphans(0)` on the tenant's APP store — any
/// `kv_undo` rows surviving from a previous run are orphans from a
/// crash between local commit and raft commit (or from a drain that
/// didn't get to call `commitTxn`). Rolling them back restores the
/// tenant to a pre-crash-consistent state before the worker starts
/// serving requests. Safe on a clean restart: `kv_undo` is empty and
/// `recoverOrphans` is a no-op.
fn openTenantFiles(worker: anytype, inst: *const tenant_mod.Instance) !*TenantFiles {
    const allocator = worker.allocator;

    // Startup orphan sweep on the tenant's APP store. This belongs
    // here (not in rove-tenant) because it's specifically about the
    // raft-vs-local-commit durability pattern that rove-js drives —
    // rove-tenant just opens the store. A future files-server or
    // log-server with its own durability layer would run its own
    // sweep against its own stores.
    inst.kv.recoverOrphans(0) catch |err| {
        std.log.warn(
            "rove-js: recoverOrphans({s}) failed: {s}",
            .{ inst.id, @errorName(err) },
        );
    };

    var blob_backend = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        worker.blob_backend_cfg,
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
    var manifest_backend = if (worker.manifest_http) |mh|
        try blob_mod.BlobBackend.openHttp(allocator, .{
            .base_url = mh.base_url,
            .instance_id = inst.id,
            .mint_jwt = mh.mint_jwt,
            .mint_ctx = mh.mint_ctx,
            // Shared Easy across all per-tenant manifest backends
            // on this worker — see `Worker.manifest_easy`. Falls
            // back to per-tenant Easy when shared init failed at
            // Worker.create.
            .easy = worker.manifest_easy,
            .ca_bundle_path = mh.ca_bundle_path,
            .verify_tls = mh.verify_tls,
        })
    else
        try blob_mod.BlobBackend.openPerTenant(
            allocator,
            worker.blob_backend_cfg,
            inst.id,
            "deployments",
        );
    errdefer manifest_backend.deinit();

    const id_copy = try allocator.dupe(u8, inst.id);
    errdefer allocator.free(id_copy);

    const tc = try allocator.create(TenantFiles);
    errdefer allocator.destroy(tc);
    // Pull this tenant's prefetched manifest (if any) — transfer
    // ownership of the bytes from the worker's prefetch map to
    // `tc`. fetchRemove returns the entry's key + value pair;
    // we own the value bytes from here and free the key (the
    // map's key was a copy of the tenant id, not the same alloc
    // as `id_copy` above).
    var prefetched: ?PrefetchedManifest = null;
    if (worker.manifest_prefetch) |*map| {
        if (map.fetchRemove(inst.id)) |kv| {
            allocator.free(kv.key);
            prefetched = kv.value;
        }
    }
    errdefer if (prefetched) |p| allocator.free(p.bytes);

    tc.* = .{
        .allocator = allocator,
        .instance_id = id_copy,
        .app_kv = inst.kv,
        .blob_backend = blob_backend,
        .manifest_backend = manifest_backend,
        .current_deployment_id = 0,
        .bytecodes = .empty,
        .source_hashes = .empty,
        .statics = .empty,
        .triggers = &.{},
        .prefetched_manifest = prefetched,
        .current_manifest_bytes = null,
    };

    // Best-effort initial load. Read `_deploy/current` from the
    // tenant's app.db (set by release POST + replicated via raft);
    // load that manifest from manifest_backend. If absent or
    // unreachable, log and leave `bytecodes` empty — requests get
    // 503 until either the dashboard pushes a release or the
    // periodic reload retry succeeds.
    //
    // Any error besides NoDeployment / InvalidManifest used to
    // crash the worker. That's the wrong tradeoff: a transient
    // network hiccup against the colocated files-server (rc=35
    // connection-reset, Sqlite contention on a shared backend
    // during cold-start burst) shouldn't take down the whole
    // worker thread + every tenant on it. We absorb the failure
    // here and let the next release POST / reload tick retry.
    reloadAllBytecodes(tc) catch |err| switch (err) {
        error.NoDeployment => {
            std.log.info(
                "rove-js: tenant {s} has no deployment yet — 503 until one lands",
                .{tc.instance_id},
            );
        },
        else => {
            std.log.warn(
                "rove-js: tenant {s} initial manifest load failed: {s} — 503 until next reload tick",
                .{ tc.instance_id, @errorName(err) },
            );
        },
    };

    return tc;
}

fn freeTenantFiles(allocator: std.mem.Allocator, tc: *TenantFiles) void {
    freeBytecodes(tc);
    freeSourceHashes(tc);
    freeStatics(tc);
    freeTriggers(tc);
    tc.manifest_backend.deinit();
    tc.blob_backend.deinit();
    if (tc.prefetched_manifest) |p| allocator.free(p.bytes);
    if (tc.current_manifest_bytes) |b| allocator.free(b);
    allocator.free(tc.instance_id);
    allocator.destroy(tc);
}

/// Lookup-or-lazy-open: if the worker already has a TenantFiles for
/// `inst`, return it. Otherwise open a fresh one, cache it, and return.
/// Callers fall through to 500 on failure — propagates errors up.
pub fn getOrOpenTenantFiles(
    worker: anytype,
    inst: *const tenant_mod.Instance,
) !*TenantFiles {
    return worker.tenant_files_map.getOrOpen(worker, inst);
}

// ── Per-tenant log loading ────────────────────────────────────────────
//
// Mirrors the TenantFiles helpers above. Each tenant gets a
// per-tenant `RequestIdMinter` whose chunked-reservation counter
// persists into the tenant's app.db at `_log/next_request_seq`.
// Opened eagerly during `Worker.create`; freed during
// `Worker.destroy`.

fn openTenantLog(
    worker: anytype,
    inst: *const tenant_mod.Instance,
    worker_id: u16,
) !*TenantLog {
    const allocator = worker.allocator;

    const id_copy = try allocator.dupe(u8, inst.id);
    errdefer allocator.free(id_copy);

    const tl = try allocator.create(TenantLog);
    errdefer allocator.destroy(tl);
    tl.* = .{
        .allocator = allocator,
        .instance_id = id_copy,
        .id_minter = undefined,
    };
    tl.id_minter = try log_mod.RequestIdMinter.init(
        allocator,
        worker_id,
        .{
            .seq_kv = inst.kv,
            .seq_key = "_log/next_request_seq",
        },
    );
    return tl;
}

fn freeTenantLog(allocator: std.mem.Allocator, tl: *TenantLog) void {
    tl.id_minter.deinit();
    allocator.free(tl.instance_id);
    allocator.destroy(tl);
}

/// Mirror of `getOrOpenTenantFiles` for the log store. Lazy-opens a
/// TenantLog for instances created at runtime so pre-minted
/// request_ids and webhook rows get matching log records.
pub fn getOrOpenTenantLog(
    worker: anytype,
    inst: *const tenant_mod.Instance,
) !*TenantLog {
    return worker.tenant_logs.getOrOpen(worker, inst);
}

/// Append a log record for a request that has finished its dispatch
/// pass. Best-effort: any internal failure is logged to stderr and
/// dropped (no propagation back to the caller — the request itself
/// must not fail because logging failed). Caller passes:
///
/// - `instance_id`: tenant id (must already exist in tenant_logs).
/// - `received_ns`: wall-clock when the worker first saw the request.
/// - `console` / `exception`: ownership is TRANSFERRED. The function
///   takes them and stores them on the LogRecord. Caller must not
///   free them after a successful return.
///
/// On any error path inside captureLog, the transferred buffers ARE
/// freed by this function so the caller doesn't have to do anything
/// special. (Caller can pass `&.{}` for a borrowed empty slice safely.)
/// Holder for the four per-request tapes the dispatcher captures. All
/// fields are owned; `deinit` frees every entry's backing storage. The
/// worker allocates a `RequestTapes` per dispatch, passes its tape
/// pointers to the dispatcher via the `Request`, then serializes +
/// uploads each non-empty tape after `run` returns.
pub const RequestTapes = struct {
    kv: tape_mod.Tape,
    date: tape_mod.Tape,
    math_random: tape_mod.Tape,
    crypto_random: tape_mod.Tape,
    module: tape_mod.Tape,

    pub fn init(allocator: std.mem.Allocator) RequestTapes {
        return .{
            .kv = tape_mod.Tape.init(allocator, .kv),
            .date = tape_mod.Tape.init(allocator, .date),
            .math_random = tape_mod.Tape.init(allocator, .math_random),
            .crypto_random = tape_mod.Tape.init(allocator, .crypto_random),
            .module = tape_mod.Tape.init(allocator, .module),
        };
    }

    pub fn deinit(self: *RequestTapes) void {
        self.kv.deinit();
        self.date.deinit();
        self.math_random.deinit();
        self.crypto_random.deinit();
        self.module.deinit();
    }
};

/// Maximum captured body length (request OR response). Anything
/// bigger gets truncated to this prefix and the corresponding
/// `*_truncated` flag set on the log record's tape payloads. Mirrors
/// PLAN §2.4's body-cap default.
pub const REQUEST_BODY_CAP: usize = 256 * 1024;
pub const RESPONSE_BODY_CAP: usize = 256 * 1024;

/// Serialize each non-empty tape into the request's `TapePayloads`,
/// owned by the caller's allocator. The bytes ride inline in the
/// next ndjson flush — no per-request S3 PUT, no separate blob
/// store.
///
/// Best-effort: on any serialize failure the channel is left empty
/// and a warning is logged. Tape capture failures must never kill
/// the request.
///
/// Pre-Phase-5.5(a-2) this function ('uploadTapes') issued one
/// content-addressed S3 PUT per channel per request through a
/// shared std.http.Client. The fanout — plus a stdlib keep-alive
/// bug that drops the OVH connection under concurrency — capped
/// tape capture at single-digit-thousand req/s. Inlining moves
/// the bytes onto the per-flush PUT path, which carries the whole
/// batch in a single request.
pub fn captureTapes(
    worker: anytype,
    tapes: *RequestTapes,
    request_body: []const u8,
    response_body: []const u8,
) log_mod.TapePayloads {
    const allocator = worker.allocator;

    var payloads: log_mod.TapePayloads = .{};

    const channels = [_]struct {
        tape: *tape_mod.Tape,
        out: *[]const u8,
    }{
        .{ .tape = &tapes.kv, .out = &payloads.kv_tape_bytes },
        .{ .tape = &tapes.date, .out = &payloads.date_tape_bytes },
        .{ .tape = &tapes.math_random, .out = &payloads.math_random_tape_bytes },
        .{ .tape = &tapes.crypto_random, .out = &payloads.crypto_random_tape_bytes },
        .{ .tape = &tapes.module, .out = &payloads.module_tree_bytes },
    };

    for (channels) |ch| {
        if (ch.tape.entries.items.len == 0) continue;
        const bytes = ch.tape.serialize(allocator) catch |err| {
            std.log.warn("rove-js tape serialize failed: {s}", .{@errorName(err)});
            continue;
        };
        ch.out.* = bytes;
    }

    // Request body — captured into the log record so the replay
    // shell's `request.body` is non-empty for POST / PUT requests.
    // Bodies bigger than `REQUEST_BODY_CAP` get truncated to that
    // prefix; the truncation flag is preserved so the simulator (and
    // the replay shell) know the captured bytes are a prefix.
    if (request_body.len > 0) {
        const captured_len = @min(request_body.len, REQUEST_BODY_CAP);
        if (allocator.dupe(u8, request_body[0..captured_len])) |captured| {
            payloads.request_body_bytes = captured;
            payloads.request_body_truncated = captured_len < request_body.len;
        } else |err| {
            std.log.warn("rove-js request-body capture failed: {s}", .{@errorName(err)});
        }
    }

    // Response body — same capture pattern. Captured AFTER content-
    // type sniffing / JSON serialization (the worker has already
    // turned `resp.body` into the bytes that go out on the wire).
    if (response_body.len > 0) {
        const captured_len = @min(response_body.len, RESPONSE_BODY_CAP);
        if (allocator.dupe(u8, response_body[0..captured_len])) |captured| {
            payloads.response_body_bytes = captured;
            payloads.response_body_truncated = captured_len < response_body.len;
        } else |err| {
            std.log.warn("rove-js response-body capture failed: {s}", .{@errorName(err)});
        }
    }

    return payloads;
}

pub fn captureLog(
    worker: anytype,
    instance_id: []const u8,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    deployment_id: u64,
    received_ns: i64,
    status: u16,
    outcome: log_mod.Outcome,
    console_owned: []u8,
    exception_owned: []u8,
    tapes: log_mod.TapePayloads,
) void {
    captureLogWithId(
        worker,
        instance_id,
        null,
        method,
        path,
        host,
        deployment_id,
        received_ns,
        status,
        outcome,
        console_owned,
        exception_owned,
        tapes,
    );
}

/// Same as `captureLog`, but lets the caller supply a pre-minted
/// `request_id` so the log record shares its id with the webhook rows
/// a handler may have spawned via `webhook.send`. Pass `null` to mint
/// fresh.
///
/// Takes ownership of `tapes` byte allocations on success. On
/// failure they're freed alongside `console_owned` / `exception_owned`.
pub fn captureLogWithId(
    worker: anytype,
    instance_id: []const u8,
    request_id: ?u64,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    deployment_id: u64,
    received_ns: i64,
    status: u16,
    outcome: log_mod.Outcome,
    console_owned: []u8,
    exception_owned: []u8,
    tapes: log_mod.TapePayloads,
) void {
    captureLogInner(
        worker,
        instance_id,
        request_id,
        method,
        path,
        host,
        deployment_id,
        received_ns,
        status,
        outcome,
        console_owned,
        exception_owned,
        tapes,
    ) catch |err| {
        std.log.warn("rove-js: log capture failed for {s}: {s}", .{ instance_id, @errorName(err) });
        // The transferred buffers must still be freed.
        if (console_owned.len > 0) worker.allocator.free(console_owned);
        if (exception_owned.len > 0) worker.allocator.free(exception_owned);
        var t = tapes;
        t.deinit(worker.allocator);
    };
}

fn captureLogInner(
    worker: anytype,
    instance_id: []const u8,
    request_id: ?u64,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    deployment_id: u64,
    received_ns: i64,
    status: u16,
    outcome: log_mod.Outcome,
    console_owned: []u8,
    exception_owned: []u8,
    tapes: log_mod.TapePayloads,
) !void {
    const tl = worker.tenant_logs.get(instance_id) orelse return error.NoTenantLog;
    const allocator = worker.allocator;

    // Dupe the borrowed strings (tenant_id/method/path/host). On
    // failure the transferred buffers are freed by the outer
    // captureLog wrapper.
    const a_tenant = try allocator.dupe(u8, instance_id);
    errdefer allocator.free(a_tenant);
    const a_method = try allocator.dupe(u8, method);
    errdefer allocator.free(a_method);
    const a_path = try allocator.dupe(u8, path);
    errdefer allocator.free(a_path);
    const a_host = try allocator.dupe(u8, host);
    errdefer allocator.free(a_host);

    const id = request_id orelse try tl.id_minter.nextRequestId();
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());

    try worker.log_buffer.append(.{
        .tenant_id = a_tenant,
        .request_id = id,
        .deployment_id = deployment_id,
        .received_ns = received_ns,
        .duration_ns = now_ns - received_ns,
        .method = a_method,
        .path = a_path,
        .host = a_host,
        .status = status,
        .outcome = outcome,
        .console = console_owned,
        .exception = exception_owned,
        .tapes = tapes,
    });
}

/// Periodically drain the worker's node-wide log buffer into a
/// single embedded-sidecar `.ndjson` object and PUT it to the
/// configured `BatchStore` (Phase 5.5 a). Runs on the leader only
/// — followers' buffer is always empty because `dispatchPending`
/// early-returns 503 on followers. Lossy on PUT failure: records
/// already left the buffer; per `docs/logs-plan.md` §1 a node-
/// failure window may drop one batch.
///
/// Phase 5.5(a-2) interleaved-per-node flush: every record carries
/// its `tenant_id`; the indexer demuxes on read. One S3 object per
/// flush window per node regardless of tenant fan-in.
pub fn flushLogs(worker: anytype) !void {
    const allocator = worker.allocator;
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());

    if (!worker.log_buffer.shouldFlush(now_ns)) return;

    const drained = worker.log_buffer.drainRecords(allocator) catch |err| {
        std.log.warn(
            "rove-js flushLogs: drainRecords failed: {s}",
            .{@errorName(err)},
        );
        return;
    };
    const records = drained orelse return;
    defer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }

    if (!worker.raft.isLeader()) {
        std.log.warn(
            "rove-js flushLogs: dropping {d}-record batch — lost leadership mid-tick",
            .{records.len},
        );
        return;
    }

    var node_buf: [8]u8 = undefined;
    const node_id_hex = std.fmt.bufPrint(&node_buf, "{x:0>8}", .{worker.raft.config.node_id}) catch unreachable;
    const flush_unix_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));

    log_server_mod.flush_writer.writeBatch(
        allocator,
        worker.log_batch_store,
        node_id_hex,
        records,
        flush_unix_ms,
    ) catch |err| {
        std.log.warn(
            "rove-js flushLogs: writeBatch ({d} records) failed: {s}",
            .{ records.len, @errorName(err) },
        );
    };
}

/// Free every key + bytecode value in `tc.bytecodes` and clear the map.
/// Used both on teardown and before atomically swapping in a newly
/// loaded deployment.
fn freeBytecodes(tc: *TenantFiles) void {
    var it = tc.bytecodes.iterator();
    while (it.next()) |e| {
        tc.allocator.free(e.key_ptr.*);
        tc.allocator.free(e.value_ptr.*);
    }
    tc.bytecodes.deinit(tc.allocator);
    tc.bytecodes = .empty;
}

/// Free the keys in `tc.source_hashes` and clear the map. Values are
/// `[64]u8` by-value, no separate free needed.
fn freeSourceHashes(tc: *TenantFiles) void {
    var it = tc.source_hashes.iterator();
    while (it.next()) |e| tc.allocator.free(e.key_ptr.*);
    tc.source_hashes.deinit(tc.allocator);
    tc.source_hashes = .empty;
}

/// Free every key + StaticEntry.content_type in `tc.statics` and clear
/// the map. Paired with `freeBytecodes` for deployment teardown.
fn freeStatics(tc: *TenantFiles) void {
    var it = tc.statics.iterator();
    while (it.next()) |e| {
        tc.allocator.free(e.key_ptr.*);
        tc.allocator.free(e.value_ptr.*.content_type);
    }
    tc.statics.deinit(tc.allocator);
    tc.statics = .empty;
}

/// Free every owned slice in `tc.triggers` and clear the array.
/// Paired with `freeBytecodes` / `freeStatics` for deployment teardown.
fn freeTriggers(tc: *TenantFiles) void {
    for (tc.triggers) |*e| {
        tc.allocator.free(e.prefix);
        tc.allocator.free(e.module_path);
    }
    tc.allocator.free(tc.triggers);
    tc.triggers = &.{};
}

/// Read the tenant's current deployment manifest, fetch every handler
/// entry's bytecode blob, stage every static entry's metadata, and
/// atomically swap both maps on the tenant. Returns `error.NoDeployment`
/// when no deploy has been made yet — soft failure the caller treats
/// as "leave the maps empty".
fn reloadAllBytecodes(tc: *TenantFiles) !void {
    // Read the release pointer from the tenant's app.db. Set by
    // /_system/release (replicated through raft envelope 0); absent
    // for tenants that haven't been released yet.
    const cur_bytes = tc.app_kv.get("_deploy/current") catch |err| switch (err) {
        error.NotFound => return error.NoDeployment,
        else => return err,
    };
    defer tc.allocator.free(cur_bytes);
    const dep_id = std.fmt.parseInt(u64, cur_bytes, 16) catch return error.NoDeployment;
    return reloadDeployment(tc, dep_id);
}

/// Pull a specific deployment manifest from the per-tenant
/// `deployments/` BlobBackend, fetch every referenced bytecode, and
/// atomically swap the maps on `tc`. Used by `reloadAllBytecodes`
/// (cold start / restart) and by `applyPendingReleases` (the
/// dashboard pushed a new release).
fn reloadDeployment(tc: *TenantFiles, dep_id: u64) !void {
    // Three-tier source for the manifest bytes:
    //   1. Already-cached `current_manifest_bytes` matching this
    //      dep_id — re-decode locally, no I/O. Common when the
    //      release handler is doing a re-release of the same
    //      dep_id (e.g. the bench's warmup phase).
    //   2. One-shot prefetch from cold-start. Transfer ownership
    //      out of the prefetch slot.
    //   3. Per-tenant HTTP / S3 fetch via manifest_backend.
    var json_bytes: []u8 = undefined;
    var bytes_taken_from_cache = false;
    if (tc.current_manifest_bytes) |cached| {
        if (tc.current_deployment_id == dep_id) {
            json_bytes = try tc.allocator.dupe(u8, cached);
            bytes_taken_from_cache = true;
        }
    }
    if (!bytes_taken_from_cache) {
        var owned_by_prefetch = false;
        if (tc.prefetched_manifest) |p| {
            tc.prefetched_manifest = null;
            if (p.dep_id == dep_id) {
                json_bytes = p.bytes;
                owned_by_prefetch = true;
            } else {
                tc.allocator.free(p.bytes);
            }
        }
        if (!owned_by_prefetch) {
            var key_buf: [25]u8 = undefined;
            const key = files_mod.manifest_json.manifestKey(&key_buf, dep_id);
            json_bytes = tc.manifest_backend.blobStore().get(key, tc.allocator) catch |err| switch (err) {
                error.NotFound => return error.NoDeployment,
                else => return err,
            };
        }
    }
    // After the swap below, `json_bytes` becomes the new
    // `current_manifest_bytes`. We can't free here. The OLD
    // current_manifest_bytes (if any) frees just before the swap.
    var json_bytes_consumed = false;
    errdefer if (!json_bytes_consumed) tc.allocator.free(json_bytes);

    var manifest = files_mod.manifest_json.decode(tc.allocator, json_bytes) catch
        return error.InvalidManifest;
    defer manifest.deinit();

    const bs = tc.blob_backend.blobStore();

    // Build the new maps in locals before swapping, so if any fetch
    // fails mid-way the tenant keeps serving the old deployment.
    var next_bc: std.StringHashMapUnmanaged([]u8) = .empty;
    errdefer {
        var it = next_bc.iterator();
        while (it.next()) |e| {
            tc.allocator.free(e.key_ptr.*);
            tc.allocator.free(e.value_ptr.*);
        }
        next_bc.deinit(tc.allocator);
    }

    var next_source_hashes: std.StringHashMapUnmanaged([64]u8) = .empty;
    errdefer {
        var it = next_source_hashes.iterator();
        while (it.next()) |e| tc.allocator.free(e.key_ptr.*);
        next_source_hashes.deinit(tc.allocator);
    }

    var next_statics: std.StringHashMapUnmanaged(StaticEntry) = .empty;
    errdefer {
        var it = next_statics.iterator();
        while (it.next()) |e| {
            tc.allocator.free(e.key_ptr.*);
            tc.allocator.free(e.value_ptr.*.content_type);
        }
        next_statics.deinit(tc.allocator);
    }

    var next_triggers: std.ArrayList(TriggerEntry) = .empty;
    errdefer {
        for (next_triggers.items) |*e| {
            tc.allocator.free(e.prefix);
            tc.allocator.free(e.module_path);
        }
        next_triggers.deinit(tc.allocator);
    }

    for (manifest.entries) |entry| {
        const path_copy = try tc.allocator.dupe(u8, entry.path);
        errdefer tc.allocator.free(path_copy);
        switch (entry.kind) {
            .handler => {
                const bytecode = try bs.get(&entry.bytecode_hex, tc.allocator);
                errdefer tc.allocator.free(bytecode);
                try next_bc.put(tc.allocator, path_copy, bytecode);

                // Mirror the path → source-hash mapping so the per-
                // request module loader can stamp `appendModule(name,
                // source_hash)` on each successful import. Owns its
                // own key copy.
                const sh_key = try tc.allocator.dupe(u8, entry.path);
                errdefer tc.allocator.free(sh_key);
                try next_source_hashes.put(tc.allocator, sh_key, entry.source_hex);

                // If this handler also matches the trigger path
                // convention (`_triggers/<.../>index.{mjs,js}`), index
                // it in the trigger registry. The bytecode lookup at
                // fire time uses the same path key in `bytecodes`.
                if (triggerPathToPrefix(entry.path)) |derived_prefix| {
                    if (isReservedTriggerPrefix(derived_prefix)) {
                        std.log.warn(
                            "rove-js: tenant {s} trigger {s} rejected — prefix '{s}' overlaps a platform namespace",
                            .{ tc.instance_id, entry.path, derived_prefix },
                        );
                        return error.ReservedTriggerPrefix;
                    }
                    const prefix_copy = try tc.allocator.dupe(u8, derived_prefix);
                    errdefer tc.allocator.free(prefix_copy);
                    const module_copy = try tc.allocator.dupe(u8, entry.path);
                    errdefer tc.allocator.free(module_copy);
                    try next_triggers.append(tc.allocator, .{
                        .prefix = prefix_copy,
                        .module_path = module_copy,
                    });
                }
            },
            .static => {
                const ct_copy = try tc.allocator.dupe(u8, entry.content_type);
                errdefer tc.allocator.free(ct_copy);
                try next_statics.put(tc.allocator, path_copy, .{
                    .content_type = ct_copy,
                    .hash_hex = entry.source_hex,
                });
            },
        }
    }

    // Sort triggers by prefix length descending (longest/innermost
    // first). AFTER chain iterates forward; BEFORE chain iterates
    // reverse. See the field doc on TenantFiles.triggers.
    const triggers_slice = try next_triggers.toOwnedSlice(tc.allocator);
    errdefer {
        for (triggers_slice) |*e| {
            tc.allocator.free(e.prefix);
            tc.allocator.free(e.module_path);
        }
        tc.allocator.free(triggers_slice);
    }
    std.mem.sort(TriggerEntry, triggers_slice, {}, struct {
        fn lessThan(_: void, a: TriggerEntry, b: TriggerEntry) bool {
            return a.prefix.len > b.prefix.len;
        }
    }.lessThan);

    // Swap.
    freeBytecodes(tc);
    freeSourceHashes(tc);
    freeStatics(tc);
    freeTriggers(tc);
    if (tc.current_manifest_bytes) |old| tc.allocator.free(old);
    tc.bytecodes = next_bc;
    tc.source_hashes = next_source_hashes;
    tc.statics = next_statics;
    tc.triggers = triggers_slice;
    tc.current_manifest_bytes = json_bytes;
    json_bytes_consumed = true;
    tc.current_deployment_id = manifest.id;

    std.log.info(
        "rove-js: tenant {s} loaded deployment {d} ({d} handler(s), {d} static(s), {d} trigger(s))",
        .{ tc.instance_id, manifest.id, tc.bytecodes.count(), tc.statics.count(), tc.triggers.len },
    );
}

/// Walk every open tenant once per tick. For each, look up the latest
/// released dep_id in the process-wide `ReleaseTable`; if it's newer
/// than what the worker has cached, reload the bytecodes from this
/// tenant's local files.db.
///
/// The push that populates the table comes from `/_system/release`
/// (POST), driven by the dashboard / CLI right after a successful
/// files-server deploy. Without the push, this is a no-op — there's
/// no polling fallback. A new leader / restarted worker will have
/// already loaded the latest deployment during `Worker.create`'s
/// eager open, so the no-push baseline is "what was on disk at
/// startup" rather than "nothing".
pub fn applyPendingReleases(worker: anytype) !void {
    const table = worker.release_table orelse return;
    var it = worker.tenant_files_map.iterator();
    while (it.next()) |entry| {
        const tc = entry.value_ptr.*;
        const released = table.get(tc.instance_id) orelse continue;
        if (released == tc.current_deployment_id) continue;

        // Hot path stays free of network I/O. Hand the load off
        // to the background DeploymentLoader thread; it fetches
        // the manifest + bytecodes + mirrors `_config/*` and
        // swaps `tc`'s state when the load completes. The
        // dispatch thread that ran this comparison just keeps
        // moving — no synchronous reload here.
        //
        // Fallback: with no loader wired (unit-test FakeWorker,
        // some smokes), run the load synchronously on this
        // thread. Behavior matches the pre-loader build.
        if (@hasField(@TypeOf(worker.*), "deployment_loader") and
            worker.deployment_loader != null)
        {
            worker.deployment_loader.?.enqueue(tc.instance_id, released) catch |err| {
                std.log.warn(
                    "rove-js release: enqueue load {s}/{d} failed: {s}",
                    .{ tc.instance_id, released, @errorName(err) },
                );
            };
        } else {
            reloadDeployment(tc, released) catch |err| {
                std.log.warn(
                    "rove-js release: tenant {s} reload to {d} failed: {s}",
                    .{ tc.instance_id, released, @errorName(err) },
                );
            };
        }
    }
}

// ── Dispatch system ───────────────────────────────────────────────────
//
// `dispatchOnce` processes a SINGLE tenant's batch per call. The
// caller (the worker poll loop) calls it in a loop, flushing between
// iterations so the ECS removes processed entities from `request_out`.
// Each call:
//
//   1. Walks `request_out.entitySlice()` once.
//   2. Short-circuits (not-leader, `/_system/*`, unknown tenant,
//      missing deployment, router / penalty failures) finalize inline
//      — `setSimpleResponse` + move to `response_in`.
//   3. The first handler-bound entity establishes the anchor tenant;
//      opens `beginTrackedImmediate` + a `WriteSet`. Subsequent
//      handler entities are run under `SAVEPOINT h → dispatcher.run
//      → RELEASE h` (or `ROLLBACK TO h` on error) if they match the
//      anchor, and skipped this pass if they don't.
//   4. After the walk, commits once and proposes a single merged
//      writeset (if any writes). All successful entities land in
//      `raft_pending` with the shared raft seq; read-only batches
//      skip raft and land in `response_in`.
//   5. Returns the number of entities moved out of `request_out`.
//
// This amortizes WAL fsync across multiple handlers per tick — the
// dominant per-tenant bottleneck identified in the Stage 0 profile.
// Per-handler isolation is preserved: a JS exception or CPU-budget
// kill in handler #5 only rolls back its savepoint, the rest commit.
//
// Skipped entities (different tenant than this tick's anchor) stay in
// `request_out`; the caller's next `dispatchOnce` call picks a fresh
// anchor from whoever is still there. Stage 3 will add a
// blocked-tenant set so a SQLITE_BUSY anchor doesn't block other
// tenants within a single tick.

/// Process one tenant's batch of requests from `request_out`. Returns
/// the number of entities moved out of `request_out` (to
/// `response_in` or `raft_pending`). Zero means the
/// collection has no work the caller can make progress on — either
/// `request_out` is empty, or all remaining handler entities target
/// tenants in `blocked`.
///
/// The caller MUST flush between calls so the next call sees a
/// drained `request_out`, and MUST clear `blocked` at the top of
/// each tick so a tenant that happened to be BUSY this tick gets a
/// fresh chance next tick.
///
/// `blocked` is any value with `.slice()` returning a slice of
/// `*const tenant_mod.Instance` and a fallible `append(*const
/// tenant_mod.Instance)` (e.g. `std.BoundedArray`). When
/// `beginTrackedImmediate` surfaces `error.Conflict` (SQLite
/// `SQLITE_BUSY` — set `busy_timeout=0` on app.db connections or you
/// will wait instead), the current anchor candidate is appended; the
/// linear walk then ignores that tenant's entities for the rest of
/// this call and the calls that follow within the tick.

/// Iterate `raft_pending`, check each entity's `RaftWait.seq` against
/// the raft node's committed and faulted watermarks. Committed
/// entries just drain to `response_in` — the local writes already
/// happened in `dispatchPending` before parking, so there's nothing
/// more to do here. Faulted or timed-out entries invoke
/// `store.undoTxn(txn_seq)` to compensating-rollback the already-
/// committed local writes via the kv_undo log, overwrite the response
/// with 503, and move. Caller must follow with a `reg.flush()`.
///
/// **Iteration order is REVERSE.** kv_undo entries record pre-images
/// relative to the state each txn observed, so when two concurrent
/// same-tenant txns both need compensating rollback, the later one
/// must be undone first (its pre-image is the earlier one's post).
/// Because `beginTrackedImmediate` serializes the begin→commit window
/// per tenant, entries park into `raft_pending` in txn_seq order;
/// reverse index iteration = reverse txn_seq order per tenant. Cross-
/// tenant interleaving is safe — their kv_undo tables are disjoint.
pub fn drainRaftPending(worker: anytype) !void {
    const server = worker.h2;
    const allocator = worker.allocator;

    const committed = worker.raft.committedSeq();
    const faulted = worker.raft.faultedSeq();
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());

    const entities = worker.raft_pending.entitySlice();
    const waits = worker.raft_pending.column(RaftWait);
    const resp_bodies = worker.raft_pending.column(h2.RespBody);

    var i: usize = entities.len;
    while (i > 0) {
        i -= 1;
        const ent = entities[i];
        const wait = waits[i];
        const resp_body = resp_bodies[i];

        if (committed >= wait.seq) {
            // Happy path: raft committed, local writes already durable.
            // Drop the per-txn undo row now that the write is proven
            // durable — otherwise it would survive in kv_undo as an
            // "orphan" and get rolled back by the next startup sweep,
            // silently corrupting state.
            if (wait.store) |store| {
                store.commitTxn(wait.txn_seq) catch |err| switch (err) {
                    // Per-tenant app.db connections run with
                    // busy_timeout=0 (so the dispatcher's BEGIN IMMEDIATE
                    // surfaces BUSY immediately for the anchor-skip
                    // dance); a different worker holding the writer lock
                    // briefly is expected contention, not a broken
                    // invariant. Leave the entity in raft_pending and
                    // try again on the next tick — the undo row is
                    // harmless to leave around for a few ms.
                    error.Conflict => continue,
                    else => panic_mod.invariantViolated(
                        "drainRaftPending.commitTxn",
                        "txn_seq={d} err={s}",
                        .{ wait.txn_seq, @errorName(err) },
                    ),
                };
            }
            try server.reg.move(ent, &worker.raft_pending, &server.response_in);
            continue;
        }

        const is_faulted = faulted > 0 and faulted >= wait.seq;
        const is_timed_out = now_ns >= wait.deadline_ns;
        if (!is_faulted and !is_timed_out) continue; // still waiting

        // Fault / timeout: compensating-rollback via undoTxn. The
        // local writes from the handler were already committed to
        // SQLite, so we walk the kv_undo log to restore the pre-images.
        // Reverse iteration ensures correct ordering for same-tenant
        // stacks of faulted writes.
        if (wait.store) |store| {
            store.undoTxn(wait.txn_seq) catch |err| switch (err) {
                // Same reasoning as the commitTxn branch: another worker
                // briefly holds the writer lock; defer this entity to
                // the next tick instead of aborting.
                error.Conflict => continue,
                else => panic_mod.invariantViolated(
                    "drainRaftPending.undoTxn",
                    "txn_seq={d} err={s}",
                    .{ wait.txn_seq, @errorName(err) },
                ),
            };
        }

        const old_body_ptr: ?[*]u8 = resp_body.data;
        const old_body_len: u32 = resp_body.len;
        try respb.overwrite503InPending(worker, ent, allocator);
        if (old_body_ptr) |p| allocator.free(p[0..old_body_len]);

        try server.reg.move(ent, &worker.raft_pending, &server.response_in);
    }
}

pub const proposeWriteSet = raft_propose.proposeWriteSet;
pub const proposeRootWriteSet = raft_propose.proposeRootWriteSet;


/// Destroy entities sitting in `response_out` (h2 has finished
/// flushing them to the wire). Same pattern as the echo example's
/// `cleanupResponses`.
pub fn cleanupResponses(worker: anytype) !void {
    const server = worker.h2;
    const entities = server.response_out.entitySlice();
    for (entities) |ent| {
        try server.reg.destroy(ent);
    }
}

// ── Helpers ────────────────────────────────────────────────────────────

pub fn hostOnly(authority: []const u8) []const u8 {
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return authority;
    return authority[0..colon];
}

/// Look up handler bytecode for `module_base`, walking up the module
/// tree if the exact path isn't deployed. So `tenant/instance/acme/index`
/// falls back through `tenant/instance/index` → `tenant/index` →
/// `index`, whichever exists first. This lets a single deployed file
/// (`index.js` or `tenant/index.mjs`) catch every sub-path below it,
/// which is exactly what the admin handler needs — one JS module
/// does its own path-based dispatch.
pub fn findBytecode(
    tc: *const TenantFiles,
    module_base: []const u8,
    allocator: std.mem.Allocator,
) !?[]u8 {
    var cur: []const u8 = module_base;
    var cur_owned: ?[]u8 = null;
    defer if (cur_owned) |o| allocator.free(o);

    while (true) {
        const mjs_key = try std.fmt.allocPrint(allocator, "{s}.mjs", .{cur});
        defer allocator.free(mjs_key);
        const js_key = try std.fmt.allocPrint(allocator, "{s}.js", .{cur});
        defer allocator.free(js_key);
        if (tc.bytecodes.get(mjs_key)) |bc| return bc;
        if (tc.bytecodes.get(js_key)) |bc| return bc;

        // At the root? Done — nothing matched.
        if (std.mem.eql(u8, cur, "index")) return null;

        // Walk up. cur is always of the form ".../X/index". Drop "X"
        // to get the parent's index: ".../index".
        const trailing_idx = std.mem.lastIndexOfScalar(u8, cur, '/') orelse return null;
        const before_segment = std.mem.lastIndexOfScalar(u8, cur[0..trailing_idx], '/');
        const new_cur = if (before_segment) |ps|
            try std.fmt.allocPrint(allocator, "{s}/index", .{cur[0..ps]})
        else
            try allocator.dupe(u8, "index");
        if (cur_owned) |o| allocator.free(o);
        cur_owned = new_cur;
        cur = new_cur;
    }
}

test "triggerPathToPrefix: catch-all" {
    try std.testing.expectEqualStrings("", triggerPathToPrefix("_triggers/index.mjs").?);
    try std.testing.expectEqualStrings("", triggerPathToPrefix("_triggers/index.js").?);
}

test "triggerPathToPrefix: single segment" {
    try std.testing.expectEqualStrings("users/", triggerPathToPrefix("_triggers/users/index.mjs").?);
    try std.testing.expectEqualStrings("users/", triggerPathToPrefix("_triggers/users/index.js").?);
}

test "triggerPathToPrefix: nested segments" {
    try std.testing.expectEqualStrings("users/sessions/", triggerPathToPrefix("_triggers/users/sessions/index.mjs").?);
    try std.testing.expectEqualStrings("a/b/c/d/", triggerPathToPrefix("_triggers/a/b/c/d/index.mjs").?);
}

test "triggerPathToPrefix: non-trigger paths return null" {
    // Not under _triggers/.
    try std.testing.expectEqual(@as(?[]const u8, null), triggerPathToPrefix("index.mjs"));
    try std.testing.expectEqual(@as(?[]const u8, null), triggerPathToPrefix("users/index.mjs"));
    try std.testing.expectEqual(@as(?[]const u8, null), triggerPathToPrefix("_static/index.html"));
    // Under _triggers/ but not an index file (helper module imported by a trigger).
    try std.testing.expectEqual(@as(?[]const u8, null), triggerPathToPrefix("_triggers/users/lib.mjs"));
    try std.testing.expectEqual(@as(?[]const u8, null), triggerPathToPrefix("_triggers/users/sessions/util.mjs"));
    // Wrong extension.
    try std.testing.expectEqual(@as(?[]const u8, null), triggerPathToPrefix("_triggers/users/index.ts"));
}

// `isReservedTriggerPrefix` tests live alongside the helper in reserved.zig.

pub const ADMIN_SESSION_COOKIE = auth.ADMIN_SESSION_COOKIE;

// ── Starter content ────────────────────────────────────────────────
//
// Embedded in the binary so a freshly-created tenant answers 200 on
// `/` the moment signup completes. Intentionally tiny — the point is
// to prove the deploy pipeline works end-to-end, not to ship a
// template. The customer replaces these as soon as they push their
// own code through the files API.

const STARTER_INDEX_MJS =
    \\// This is your Loop46 handler. It runs as a pure function of
    \\// (request, kv) — no fetch, no setTimeout, no async IO. All
    \\// outbound effects go through webhook.send / email.send. See
    \\// the docs at https://loop46.me/docs for the full story.
    \\//
    \\// The current request is available on the `request` global
    \\// (request.method, request.path, request.body, request.query).
    \\// Return a string (or an object — we'll JSON.stringify it).
    \\export default function () {
    \\  const count = parseInt(kv.get("_starter_hits") ?? "0", 10) + 1;
    \\  kv.set("_starter_hits", String(count));
    \\  return {
    \\    message: "Your Loop46 API is live",
    \\    path: request.path,
    \\    hits: count,
    \\  };
    \\}
;

const STARTER_STATIC_INDEX_HTML =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<title>Your Loop46 app</title>
    \\<meta name="viewport" content="width=device-width,initial-scale=1">
    \\<style>
    \\  body { font: 15px system-ui, sans-serif; max-width: 640px; margin: 4rem auto; padding: 0 1rem; color: #222; }
    \\  h1 { margin-bottom: 0.25rem; }
    \\  code { background: #f1f1f1; padding: 0.1em 0.3em; border-radius: 3px; }
    \\  ul { padding-left: 1.25rem; }
    \\</style>
    \\</head>
    \\<body>
    \\<h1>Your Loop46 app is live 🎉</h1>
    \\<p>This static page came from <code>_static/index.html</code>. Everything else routes through <code>index.mjs</code>.</p>
    \\<h2>Next steps</h2>
    \\<ul>
    \\  <li>Visit your dashboard at <a href="https://app.loop46.me">app.loop46.me</a> to edit code and browse your KV</li>
    \\  <li>Edit <code>index.mjs</code> to handle routes</li>
    \\  <li>Drop static assets under <code>_static/</code> — images, CSS, SPAs, anything</li>
    \\  <li>Use <code>webhook.send</code> and <code>email.send</code> for outbound effects</li>
    \\</ul>
    \\</body>
    \\</html>
;

/// Write the initial deployment for a freshly-created instance. Opens
/// its own short-lived kv + blob-store connections, pushes the two
/// starter files through FileStore (which compiles + blob-addresses
/// them), and commits a deployment row. Closes everything on the way
/// out — the main worker and files-server lazy-open their own
/// connections later, so we're not holding onto any state that would
/// conflict.
/// Drop the starter content into the freshly-created tenant's
/// working tree, encode the resulting manifest as JSON, write it to
/// the per-tenant `deployments/` BlobBackend, and stage a `_deploy/
/// current = 1` write into `release_ws` so the caller can propose
/// it through raft alongside the rest of the signup writeset.
/// Phase 5.5(e) F2-storage retired the per-tenant files writeset
/// (envelope 3); the runtime release pointer rides envelope 0 with
/// the rest of the customer kv writes.
fn deployStarterContent(
    allocator: std.mem.Allocator,
    inst_dir: []const u8,
    inst_id: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    compile_fn: files_mod.CompileFn,
    compile_ctx: ?*anyopaque,
    release_ws: *kv_mod.WriteSet,
) !void {
    const files_db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/files.db",
        .{inst_dir},
        0,
    );
    defer allocator.free(files_db_path);

    const files_kv = try kv_mod.KvStore.open(allocator, files_db_path);
    defer files_kv.close();

    var blob_backend = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        blob_cfg,
        inst_id,
        "file-blobs",
    );
    defer blob_backend.deinit();

    var store = files_mod.FileStore.init(
        allocator,
        files_kv,
        blob_backend.blobStore(),
        compile_fn,
        compile_ctx,
    );

    try store.putSource("index.mjs", STARTER_INDEX_MJS);
    try store.putStatic("_static/index.html", STARTER_STATIC_INDEX_HTML, "text/html; charset=utf-8");

    const cur = try store.currentDeploymentId();
    const next_id = cur + 1;

    const entries = try store.assembleManifest();
    defer store.freeEntries(entries);

    const json_bytes = try files_mod.manifest_json.encode(allocator, next_id, entries);
    defer allocator.free(json_bytes);

    var manifest_be = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        blob_cfg,
        inst_id,
        "deployments",
    );
    defer manifest_be.deinit();

    var key_buf: [25]u8 = undefined;
    const key = files_mod.manifest_json.manifestKey(&key_buf, next_id);
    try manifest_be.blobStore().put(key, json_bytes);

    try store.setCurrentDeploymentId(next_id);

    // Stage `_deploy/current = next_id` so the caller's raft propose
    // sees it. Followers' apply path commits it into their copies of
    // the tenant's app.db; the worker's TenantFiles eager-open then
    // reads it on first request and loads the manifest from
    // manifest_backend (shared via fs/s3 between leader + followers).
    var hex_buf: [16]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x:0>16}", .{next_id}) catch unreachable;
    try release_ws.addPut("_deploy/current", hex);
}

// ── Tests ──────────────────────────────────────────────────────────────
//
// Worker-level integration tests that don't need the full h2 stack.
// Anything that requires opening a listening socket lives in the
// binary's smoke test instead — these tests cover the lifecycle hooks
// that don't depend on h2.

const testing = std.testing;

test "openTenantFiles runs the orphan sweep on startup" {
    // Simulates the crash recovery scenario:
    //   1. A previous worker run did `beginTrackedImmediate` + put + commit
    //      (the local SQLite txn is durable, the kv_undo row exists).
    //   2. The previous worker crashed before calling commitTxn — so the
    //      kv_undo row never got dropped.
    //   3. New worker starts, openTenantFiles runs, recoverOrphans(0)
    //      walks kv_undo and rolls back the orphan write.
    //
    // This is the durability hole #34 was tracking. Without the sweep,
    // the orphan write would remain visible in the tenant store even
    // though raft never committed it — split-brain across nodes.

    const allocator = testing.allocator;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/rove-js-sweep-{x}", .{seed});
    defer allocator.free(tmp_dir);
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const root_path = try std.fmt.allocPrintSentinel(allocator, "{s}/__root__.db", .{tmp_dir}, 0);
    defer allocator.free(root_path);
    const root_kv = try kv_mod.KvStore.open(allocator, root_path);
    defer root_kv.close();

    const tenant = try tenant_mod.Tenant.create(allocator, root_kv, tmp_dir);
    defer tenant.destroy();

    try tenant.createInstance("acme");
    const inst = tenant.instances.get("acme").?;

    // Plant an orphan: tracked txn + commit + skip commitTxn.
    {
        var txn = try inst.kv.beginTrackedImmediate();
        try txn.put("orphan-key", "orphan-value");
        try txn.commit();
        // Intentionally NOT calling inst.kv.commitTxn(txn.txn_seq) —
        // this is what a crash between local commit and raft commit
        // would leave behind.
    }

    // Forward write is currently visible (the orphan).
    const before = try inst.kv.get("orphan-key");
    allocator.free(before);

    // Simulate worker startup: openTenantFiles runs the sweep.
    const FakeWorker = struct {
        allocator: std.mem.Allocator,
        blob_backend_cfg: blob_mod.BackendConfig = .{ .endpoint = "x.invalid", .region = "x", .bucket = "x", .access_key = "x", .secret_key = "x" },
        manifest_http: ?ManifestHttpConfig = null,
        manifest_prefetch: ?std.StringHashMapUnmanaged(PrefetchedManifest) = null,
        manifest_easy: ?*blob_mod.curl.Easy = null,
    };
    var fake = FakeWorker{ .allocator = allocator };
    const tc = try openTenantFiles(&fake, inst);
    defer freeTenantFiles(allocator, tc);

    // After the sweep, the orphan write is gone.
    try testing.expectError(error.NotFound, inst.kv.get("orphan-key"));
}

test "commitTxn drops the undo row so the next sweep is a no-op" {
    // Inverse of the first test: a write that DID get the commitTxn
    // call should survive across a Worker.create / openTenantFiles
    // cycle. Proves the happy-path GC actually clears the undo row.
    const allocator = testing.allocator;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/rove-js-commit-{x}", .{seed});
    defer allocator.free(tmp_dir);
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const root_path = try std.fmt.allocPrintSentinel(allocator, "{s}/__root__.db", .{tmp_dir}, 0);
    defer allocator.free(root_path);
    const root_kv = try kv_mod.KvStore.open(allocator, root_path);
    defer root_kv.close();

    const tenant = try tenant_mod.Tenant.create(allocator, root_kv, tmp_dir);
    defer tenant.destroy();

    try tenant.createInstance("acme");
    const inst = tenant.instances.get("acme").?;

    {
        var txn = try inst.kv.beginTrackedImmediate();
        try txn.put("durable-key", "durable-value");
        try txn.commit();
        try inst.kv.commitTxn(txn.txn_seq); // happy-path GC
    }

    // Worker startup runs the sweep; should NOT touch durable-key.
    const FakeWorker = struct {
        allocator: std.mem.Allocator,
        blob_backend_cfg: blob_mod.BackendConfig = .{ .endpoint = "x.invalid", .region = "x", .bucket = "x", .access_key = "x", .secret_key = "x" },
        manifest_http: ?ManifestHttpConfig = null,
        manifest_prefetch: ?std.StringHashMapUnmanaged(PrefetchedManifest) = null,
        manifest_easy: ?*blob_mod.curl.Easy = null,
    };
    var fake = FakeWorker{ .allocator = allocator };
    const tc = try openTenantFiles(&fake, inst);
    defer freeTenantFiles(allocator, tc);

    const v = try inst.kv.get("durable-key");
    defer allocator.free(v);
    try testing.expectEqualStrings("durable-value", v);
}

test "captureLog appends a record to the worker's node-wide buffer" {
    // Verifies the captureLog helper end to end: build a fake worker
    // with a real TenantLog open against a temp dir, call captureLog,
    // then read the record back out of the worker's log_buffer.
    // Mirrors the dispatchPending capture path without spinning up
    // h2 or raft.
    const allocator = testing.allocator;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/rove-js-logcap-{x}", .{seed});
    defer allocator.free(tmp_dir);
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const root_path = try std.fmt.allocPrintSentinel(allocator, "{s}/__root__.db", .{tmp_dir}, 0);
    defer allocator.free(root_path);
    const root_kv = try kv_mod.KvStore.open(allocator, root_path);
    defer root_kv.close();

    const tenant = try tenant_mod.Tenant.create(allocator, root_kv, tmp_dir);
    defer tenant.destroy();

    try tenant.createInstance("acme");
    const inst = tenant.instances.get("acme").?;

    const FakeWorker = struct {
        allocator: std.mem.Allocator,
        tenant_logs: std.StringHashMapUnmanaged(*TenantLog),
        log_buffer: log_mod.NodeLogBuffer,
    };
    var fake = FakeWorker{
        .allocator = allocator,
        .tenant_logs = .empty,
        .log_buffer = log_mod.NodeLogBuffer.init(allocator),
    };
    defer fake.tenant_logs.deinit(allocator);
    defer fake.log_buffer.deinit();

    const tl = try openTenantLog(&fake, inst, 7);
    defer freeTenantLog(allocator, tl);
    try fake.tenant_logs.put(allocator, tl.instance_id, tl);

    // Capture a single log record (the worker would do this from
    // dispatchPending). Empty owned slices for console + exception.
    const empty: []u8 = &.{};
    captureLog(
        &fake,
        "acme",
        "GET",
        "/test",
        "acme.test",
        42,
        1_000_000_000,
        200,
        .ok,
        empty,
        empty,
        .{},
    );

    try testing.expectEqual(@as(usize, 1), fake.log_buffer.buffer.items.len);
    const buffered = &fake.log_buffer.buffer.items[0];
    try testing.expectEqual(@as(u64, 200), @as(u64, buffered.status));
    try testing.expectEqualStrings("/test", buffered.path);
    try testing.expectEqual(@as(u64, 42), buffered.deployment_id);
    try testing.expectEqual(log_mod.Outcome.ok, buffered.outcome);
}

