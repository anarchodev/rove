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
const proxy = @import("proxy.zig");
const dispatch = @import("worker_dispatch.zig");
const panic_mod = @import("panic.zig");
const penalty_mod = @import("penalty.zig");
const limiter_mod = @import("limiter.zig");
const router_mod = @import("router.zig");
const reserved = @import("reserved.zig");
const events_pump = @import("events_pump.zig");
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

/// Default interval between deployment refresh checks. Each tick the
/// worker may check one tenant's `deployment/current` to see if it
/// advanced and reload the handler bytecode if so.
pub const DEFAULT_REFRESH_INTERVAL_NS: i64 = 2 * std.time.ns_per_s;


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

/// Refreshed periodically via `refreshDeployments` when the tenant's
/// `deployment/current` advances.
pub const TenantFiles = struct {
    allocator: std.mem.Allocator,
    /// Owned copy of the instance id. Used as the key in the worker's
    /// `tenant_files_map` map; owning it here keeps that map's lifetime
    /// self-contained.
    instance_id: []u8,
    /// Owned tenant code index (SQLite at `{inst.dir}/files.db`).
    files_kv: *kv_mod.KvStore,
    /// Owned blob backend. With `.fs` config: opens at
    /// `{inst.dir}/file-blobs/`. With `.s3`: shares the bucket with
    /// every other tenant on this node, scoped by key prefix
    /// `{base}{inst.id}/file-blobs/`.
    blob_backend: blob_mod.BlobBackend,
    /// rove-files wrapper over `files_kv` + `blob_backend`. Compile hook
    /// is a stub — the worker only reads, never uploads.
    store: files_mod.FileStore,
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
    /// When the next refresh check is allowed (absolute
    /// `std.time.nanoTimestamp()`). `refreshDeployments` skips tenants
    /// whose deadline hasn't passed yet so we don't hammer the code
    /// store on every tick.
    next_refresh_ns: i64,
    /// Active SSE connections for this tenant. Owned `SseConnection`
    /// records — sid + h2 stream entity + cursor + last-send timestamp.
    /// Linear-scan lookup is fine at v1's per-instance caps. Populated
    /// by `events.tryHandleEvents` on connect, removed by
    /// `events_pump.cleanupClosedSseConnections` after h2 finishes.
    sse_connections: std.ArrayListUnmanaged(events_pump.SseConnection),
    /// Sids that need pump attention next tick (their `_events/{sid}/...`
    /// rows just got new entries via `events.emit`). Populated by
    /// `events_pump.markDirtyFromWriteset` after each successful commit;
    /// drained by `pumpEvents`. Hashmap keyed by allocator-owned sid
    /// strings so `getOrPut` can dedupe.
    dirty_sids: std.StringHashMapUnmanaged(void),

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

/// Per-tenant log state held by the worker. Mirrors `TenantFiles`'s
/// shape: owns its KvStore + BlobStore, wraps a rove-log `LogStore`,
/// is opened eagerly in `Worker.create` and closed in `Worker.destroy`.
///
/// The `LogStore`'s in-memory buffer accumulates `LogRecord`s as the
/// dispatch path appends them; `flushLogs` periodically drains the
/// buffer into a batch envelope and either proposes through raft (if
/// leader) or applies directly to the local log.db (if follower —
/// best-effort, no replication).
pub const TenantLog = struct {
    allocator: std.mem.Allocator,
    instance_id: []u8,
    log_kv: *kv_mod.KvStore,
    /// Owned blob backend for log batches. Same `.fs` / `.s3` switch
    /// as `TenantFiles.blob_backend`; for `.s3` the per-tenant prefix
    /// is `{base}{inst.id}/log-blobs/`.
    blob_backend: blob_mod.BlobBackend,
    store: log_mod.LogStore,

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
    /// How often `refreshDeployments` re-reads `deployment/current`
    /// per tenant.
    refresh_interval_ns: i64 = DEFAULT_REFRESH_INTERVAL_NS,
    /// Address of the in-process rove-files-server thread. When set,
    /// the worker opens an HTTP/2 client connection at startup and
    /// proxies any request whose path starts with `/_system/files/`
    /// to this address. When null, `/_system/files/*` requests return
    /// 503 (feature disabled).
    code_addr: ?std.net.Address = null,
    /// Address of the in-process rove-log-server thread. Mirror of
    /// `code_addr` for `/_system/log/*`.
    log_addr: ?std.net.Address = null,
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
    /// Upper 16 bits of every LogStore request_id this worker issues.
    /// Must be unique per Worker instance within one process — if two
    /// workers on the same node both use the same id, their captured
    /// log records will collide on `nextRequestId`. When null, falls
    /// back to `raft.config.node_id`, which is correct for the
    /// single-worker-per-process case but wrong for multi-worker.
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
    /// Picks the blob backend each `TenantFiles` / `TenantLog` opens.
    /// `.fs` keeps the on-disk layout `{inst.dir}/{file,log}-blobs/`;
    /// `.s3` shares one bucket across all tenants on the node, scoped
    /// per-tenant by key prefix `{base}{instance_id}/{subdir}/`.
    /// Owned by the caller — backend strings (endpoint, region, etc.)
    /// must outlive the worker's `create` call (S3BlobStore.init dupes
    /// them, so afterwards they can be freed).
    blob_backend: blob_mod.BackendConfig = .fs,
    /// Phase 5.5 (a) — `BatchStore` the worker flushes log batches
    /// into. Optional: when null, log records are drained from
    /// per-tenant buffers + dropped with a warning. Production wires
    /// an `S3BatchStore` here; dev paths can leave it null and skip
    /// observability.
    log_batch_store: ?log_server_mod.batch_store.BatchStore = null,
};

/// Cross-reference component used by the `/_system/*` proxy. Lives
/// on server-side entities parked in each subsystem's `inflight`
/// collection; the `client` field points at the client-side entity
/// that was submitted into rove-h2's `client_request_in`. On each
/// tick we scan `client_response_out`, match each client entity
/// back to its server peer via this field, and copy the upstream
/// response onto the server entity before delivering it to the
/// downstream user.
pub const ProxyPeer = proxy.ProxyPeer;
pub const ProxyTag = proxy.ProxyTag;
pub const ProxySubsystem = proxy.ProxySubsystem;
pub const connectProxies = proxy.connectProxies;
pub const ingestProxyConnects = proxy.ingestProxyConnects;
pub const flushProxyPending = proxy.flushProxyPending;
pub const drainProxyResponses = proxy.drainProxyResponses;
pub const dispatchOnce = dispatch.dispatchOnce;

pub fn Worker(comptime opts: Options) type {
    // rove-js contributes `RaftWait` to every request entity so we can
    // park entities in `raft_pending` without allocating side state.
    // Also `ProxyPeer` so `/_system/*` requests can carry the cross-
    // reference to their in-flight upstream client entity through
    // the parking collections, and `ProxyTag` so the connect + drain
    // systems can route each client entity back to its originating
    // subsystem in O(1) instead of scanning every inflight collection.
    const merged_request_row = rove.Row(&.{ RaftWait, ProxyPeer, ProxyTag }).merge(opts.request_row);

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
        /// `/_system/files/*` proxy state. Targets the in-process
        /// rove-files-server thread.
        code_proxy: ProxySubsystem(StreamColl),
        /// `/_system/log/*` proxy state. Targets the in-process
        /// rove-log-server thread.
        log_proxy: ProxySubsystem(StreamColl),
        dispatcher: Dispatcher,
        tenant: *tenant_mod.Tenant,
        raft: *kv_mod.RaftNode,
        /// Per-tenant code state. Keyed by instance id (the string the
        /// `TenantFiles` owns internally — the map slot's key points at
        /// that allocation, so lifetimes line up).
        tenant_files_map: TenantMap(TenantFiles),
        /// Per-tenant log state. Same lifetime + key-stability story
        /// as `tenant_files_map`. Opened eagerly alongside it. The worker's
        /// dispatch path appends LogRecords into each tenant's
        /// `store.buffer`; `flushLogs` drains and proposes batches.
        tenant_logs: TenantMap(TenantLog),
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
        refresh_interval_ns: i64,
        /// Borrowed from `WorkerConfig.admin_origin`. See the config
        /// field for semantics. Null when CORS is disabled.
        admin_origin: ?[]const u8,
        /// Borrowed from `WorkerConfig.admin_api_domain`. Hostname
        /// that hosts the admin API + dashboard. Null disables admin
        /// routing entirely. Cross-tenant scoping uses the
        /// `X-Rove-Scope: <id>` header on this host.
        admin_api_domain: ?[]const u8,
        /// Upper 16 bits every `LogStore.nextRequestId()` minted by this
        /// worker stamps onto ids so they don't collide with other
        /// workers' ids. Copied from `WorkerConfig.log_worker_id` (or the
        /// raft node id as a fallback).
        log_worker_id: u16,
        /// Compile callback used by signup to deploy starter content.
        /// Borrowed from `WorkerConfig.compile_fn` / `compile_ctx`.
        compile_fn: ?files_mod.CompileFn,
        compile_ctx: ?*anyopaque,
        /// Picks fs vs s3 for every per-tenant blob backend this
        /// worker opens. Borrowed from `WorkerConfig.blob_backend`.
        blob_backend_cfg: blob_mod.BackendConfig,
        /// Phase 5.5 (a) — store the worker flushes log batches into.
        /// Null disables the flush (records get dropped). Lives for
        /// the worker's full lifetime.
        log_batch_store: ?log_server_mod.batch_store.BatchStore,

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
                .code_proxy = try ProxySubsystem(StreamColl).init(
                    allocator,
                    .{ .kind = .code },
                    config.code_addr,
                ),
                .log_proxy = try ProxySubsystem(StreamColl).init(
                    allocator,
                    .{ .kind = .log },
                    config.log_addr,
                ),
                .dispatcher = try Dispatcher.init(allocator),
                .tenant = config.tenant,
                .raft = config.raft,
                .tenant_files_map = .empty,
                .tenant_logs = .empty,
                .penalty_box = penalty_mod.PenaltyBox.init(allocator, .{}),
                .limiter = limiter_mod.RateLimiter.init(allocator, config.rate_limit_caps),
                .commit_wait_timeout_ns = config.commit_wait_timeout_ns,
                .refresh_interval_ns = config.refresh_interval_ns,
                .admin_origin = config.admin_origin,
                .admin_api_domain = config.admin_api_domain,
                .log_worker_id = config.log_worker_id orelse @intCast(config.raft.config.node_id),
                .compile_fn = config.compile_fn,
                .compile_ctx = config.compile_ctx,
                .blob_backend_cfg = config.blob_backend,
                .log_batch_store = config.log_batch_store,
            };
            errdefer self.raft_pending.deinit();
            errdefer self.code_proxy.deinit();
            errdefer self.log_proxy.deinit();
            errdefer self.tenant_files_map.clearAllEntries(allocator);
            errdefer self.tenant_logs.clearAllEntries(allocator);

            reg.registerCollection(&self.raft_pending);
            reg.registerCollection(&self.code_proxy.pending);
            reg.registerCollection(&self.code_proxy.inflight);
            reg.registerCollection(&self.log_proxy.pending);
            reg.registerCollection(&self.log_proxy.inflight);

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

            return self;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            self.limiter.deinit();
            self.penalty_box.deinit();
            self.tenant_logs.deinit(allocator);
            self.tenant_files_map.deinit(allocator);
            self.log_proxy.deinit();
            self.code_proxy.deinit();
            self.raft_pending.deinit();
            self.dispatcher.deinit();
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
        /// `*Self`, and run the same open-files.db + FileStore +
        /// putSource + putStatic + deploy + propose dance the Zig
        /// signup path does today.
        ///
        /// Returns `error.InstanceNotFound` if `target_id` doesn't
        /// resolve, `error.CompileFnUnavailable` if this worker has
        /// no compile callback wired (library mode). Other errors
        /// propagate from `deployStarterContent` /
        /// `proposeFilesWriteSet`.
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

            var files_ws = kv_mod.WriteSet.init(allocator);
            defer files_ws.deinit();
            try deployStarterContent(
                allocator,
                inst.dir,
                inst.id,
                self.blob_backend_cfg,
                compile_fn,
                self.compile_ctx,
                &files_ws,
            );
            _ = try proposeFilesWriteSet(self, &files_ws, target_id);
        }

    };
}

// ── Per-tenant code loading ───────────────────────────────────────────
//
// These helpers open a tenant's code store (`{inst.dir}/files.db` +
// `{inst.dir}/file-blobs/`) and load the active handler bytecode.
// Called eagerly during `Worker.create` for every registered instance,
// and by `refreshDeployments` when a tenant's `deployment/current`
// advances.

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

    const files_db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/files.db",
        .{inst.dir},
        0,
    );
    defer allocator.free(files_db_path);

    const files_blob_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/file-blobs",
        .{inst.dir},
    );
    defer allocator.free(files_blob_dir);

    const files_kv = try kv_mod.KvStore.open(allocator, files_db_path);
    errdefer files_kv.close();

    var blob_backend = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        worker.blob_backend_cfg,
        files_blob_dir,
        inst.id,
        "file-blobs",
    );
    errdefer blob_backend.deinit();

    const id_copy = try allocator.dupe(u8, inst.id);
    errdefer allocator.free(id_copy);

    const tc = try allocator.create(TenantFiles);
    errdefer allocator.destroy(tc);
    tc.* = .{
        .allocator = allocator,
        .instance_id = id_copy,
        .files_kv = files_kv,
        .blob_backend = blob_backend,
        .store = undefined, // filled after we have a stable `tc` pointer
        .current_deployment_id = 0,
        .bytecodes = .empty,
        .source_hashes = .empty,
        .statics = .empty,
        .triggers = &.{},
        .next_refresh_ns = 0,
        .sse_connections = .empty,
        .dirty_sids = .empty,
    };
    tc.store = files_mod.FileStore.init(
        allocator,
        tc.files_kv,
        tc.blob_backend.blobStore(),
        stubCompile,
        null,
    );

    // Best-effort initial load. If there's no deployment yet, we log
    // and leave `bytecodes` empty. Real errors (corrupt store, I/O
    // failure) fall through as an error so the caller can decide
    // whether to proceed.
    reloadAllBytecodes(tc) catch |err| switch (err) {
        error.NoDeployment => {
            std.log.info(
                "rove-js: tenant {s} has no deployment yet — 503 until one lands",
                .{tc.instance_id},
            );
        },
        else => return err,
    };

    return tc;
}

fn freeTenantFiles(allocator: std.mem.Allocator, tc: *TenantFiles) void {
    freeBytecodes(tc);
    freeSourceHashes(tc);
    freeStatics(tc);
    freeTriggers(tc);
    // SSE connection table — entries hold no owned slices beyond the
    // record itself, so the ArrayList free covers the whole thing.
    tc.sse_connections.deinit(allocator);
    // dirty_sids holds allocator-owned sid keys — free each before the
    // hashmap teardown.
    var ds_it = tc.dirty_sids.iterator();
    while (ds_it.next()) |entry| allocator.free(entry.key_ptr.*);
    tc.dirty_sids.deinit(allocator);
    tc.blob_backend.deinit();
    tc.files_kv.close();
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
// Mirrors the TenantFiles helpers above. Each tenant gets a `log.db` +
// `log-blobs/` directory under its instance dir, and a LogStore that
// wraps both. Opened eagerly during `Worker.create`; freed during
// `Worker.destroy`. Per-record append happens during dispatchPending;
// batch flush + raft propose happens in `flushLogs`.

fn openTenantLog(
    worker: anytype,
    inst: *const tenant_mod.Instance,
    worker_id: u16,
) !*TenantLog {
    const allocator = worker.allocator;

    const log_db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/log.db",
        .{inst.dir},
        0,
    );
    defer allocator.free(log_db_path);

    const log_blob_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/log-blobs",
        .{inst.dir},
    );
    defer allocator.free(log_blob_dir);

    const log_kv = try kv_mod.KvStore.open(allocator, log_db_path);
    errdefer log_kv.close();

    // Phase 5.5 (a) A4: nextRequestSeq lives at `_log/next_request_seq`
    // in the per-tenant app.db. One-shot migration — if app.db doesn't
    // have the key yet but log.db does (worker is upgrading from a
    // pre-A4 build), copy the value across before LogStore.init reads
    // it. Otherwise the worker would mint colliding ids.
    migrateRequestSeqIfNeeded(allocator, inst.kv, log_kv) catch |err| {
        std.log.warn(
            "rove-js openTenantLog({s}): seq migration failed: {s}",
            .{ inst.id, @errorName(err) },
        );
    };

    var blob_backend = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        worker.blob_backend_cfg,
        log_blob_dir,
        inst.id,
        "log-blobs",
    );
    errdefer blob_backend.deinit();

    const id_copy = try allocator.dupe(u8, inst.id);
    errdefer allocator.free(id_copy);

    const tl = try allocator.create(TenantLog);
    errdefer allocator.destroy(tl);
    tl.* = .{
        .allocator = allocator,
        .instance_id = id_copy,
        .log_kv = log_kv,
        .blob_backend = blob_backend,
        .store = undefined,
    };
    tl.store = try log_mod.LogStore.init(
        allocator,
        tl.log_kv,
        tl.blob_backend.blobStore(),
        worker_id,
        .{
            .seq_kv = inst.kv,
            .seq_key = "_log/next_request_seq",
        },
    );
    return tl;
}

/// One-shot copy of pre-A4 `meta/next_request_seq` from log.db over to
/// `_log/next_request_seq` in app.db. Idempotent: if app.db already
/// has the key, no-op. If log.db doesn't have the legacy key either
/// (fresh tenant), no-op. Runs once per tenant per process; the cost
/// is two SQLite reads on the cold-open path.
fn migrateRequestSeqIfNeeded(
    allocator: std.mem.Allocator,
    app_kv: *kv_mod.KvStore,
    log_kv: *kv_mod.KvStore,
) !void {
    if (app_kv.get("_log/next_request_seq")) |bytes| {
        allocator.free(bytes);
        return;
    } else |err| switch (err) {
        error.NotFound => {},
        else => return err,
    }
    const legacy = log_kv.get("meta/next_request_seq") catch |err| switch (err) {
        error.NotFound => return,
        else => return err,
    };
    defer allocator.free(legacy);
    try app_kv.put("_log/next_request_seq", legacy);
}

fn freeTenantLog(allocator: std.mem.Allocator, tl: *TenantLog) void {
    tl.store.deinit();
    tl.blob_backend.deinit();
    tl.log_kv.close();
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

/// Serialize each non-empty tape, upload to the tenant's log blob
/// store keyed by hash-hex, and return a `TapeRefs` that points at
/// whichever channels actually recorded something. Empty channels
/// stay null on the refs so the log record doesn't carry noise.
///
/// Best-effort: on any serialize/upload failure for a given channel,
/// the ref for that channel is left null and a warning is logged. We
/// don't want tape capture failures to kill the request.
/// Maximum captured body length (request OR response). Anything
/// bigger gets truncated to this prefix and the corresponding
/// `*_truncated` flag set on the log record's tape refs. Mirrors
/// PLAN §2.4's body-cap default.
pub const REQUEST_BODY_CAP: usize = 256 * 1024;
pub const RESPONSE_BODY_CAP: usize = 256 * 1024;

pub fn uploadTapes(
    worker: anytype,
    instance_id: []const u8,
    tapes: *RequestTapes,
    request_body: []const u8,
    response_body: []const u8,
) log_mod.TapeRefs {
    const tl = worker.tenant_logs.get(instance_id) orelse return .{};
    const allocator = worker.allocator;
    const blob = tl.blob_backend.blobStore();

    var refs: log_mod.TapeRefs = .{};

    const channels = [_]struct {
        tape: *tape_mod.Tape,
        out: *?[64]u8,
    }{
        .{ .tape = &tapes.kv, .out = &refs.kv_tape_hex },
        .{ .tape = &tapes.date, .out = &refs.date_tape_hex },
        .{ .tape = &tapes.math_random, .out = &refs.math_random_tape_hex },
        .{ .tape = &tapes.crypto_random, .out = &refs.crypto_random_tape_hex },
        .{ .tape = &tapes.module, .out = &refs.module_tree_hex },
    };

    for (channels) |ch| {
        if (ch.tape.entries.items.len == 0) continue;
        const bytes = ch.tape.serialize(allocator) catch |err| {
            std.log.warn("rove-js tape serialize failed: {s}", .{@errorName(err)});
            continue;
        };
        defer allocator.free(bytes);
        const hash = tape_mod.hashHexBytes(bytes);
        blob.put(&hash, bytes) catch |err| {
            std.log.warn("rove-js tape blob put failed: {s}", .{@errorName(err)});
            continue;
        };
        ch.out.* = hash;
    }

    // Request body — captured to the same per-tenant log-blobs/. This
    // is what makes the replay shell's `request.body` non-empty for
    // POST / PUT requests. Bodies bigger than `REQUEST_BODY_CAP` get
    // truncated to that prefix; the truncation flag is preserved
    // through the log record so the simulator (and the replay shell)
    // know the captured bytes are a prefix.
    if (request_body.len > 0) {
        const captured_len = @min(request_body.len, REQUEST_BODY_CAP);
        const captured = request_body[0..captured_len];
        const hash = tape_mod.hashHexBytes(captured);
        if (blob.put(&hash, captured)) {
            refs.request_body_hex = hash;
            refs.request_body_truncated = captured_len < request_body.len;
        } else |err| {
            // Better to surface a missing-body in the bundle than
            // dangle a hash whose blob never landed. Replay falls
            // back to empty body.
            std.log.warn("rove-js request-body blob put failed: {s}", .{@errorName(err)});
        }
    }

    // Response body — same capture pattern as request body.
    // Captured AFTER content-type sniffing / JSON serialization (the
    // worker has already turned `resp.body` into the bytes that go
    // out on the wire). Replay UI shows these alongside the request
    // bytes so debugging "what did this request return" doesn't
    // require log scraping.
    if (response_body.len > 0) {
        const captured_len = @min(response_body.len, RESPONSE_BODY_CAP);
        const captured = response_body[0..captured_len];
        const hash = tape_mod.hashHexBytes(captured);
        if (blob.put(&hash, captured)) {
            refs.response_body_hex = hash;
            refs.response_body_truncated = captured_len < response_body.len;
        } else |err| {
            std.log.warn("rove-js response-body blob put failed: {s}", .{@errorName(err)});
        }
    }

    return refs;
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
    tape_refs: log_mod.TapeRefs,
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
        tape_refs,
    );
}

/// Same as `captureLog`, but lets the caller supply a pre-minted
/// `request_id` so the log record shares its id with the webhook rows
/// a handler may have spawned via `webhook.send`. Pass `null` to mint
/// fresh.
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
    tape_refs: log_mod.TapeRefs,
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
        tape_refs,
    ) catch |err| {
        std.log.warn("rove-js: log capture failed for {s}: {s}", .{ instance_id, @errorName(err) });
        // The transferred buffers must still be freed.
        if (console_owned.len > 0) worker.allocator.free(console_owned);
        if (exception_owned.len > 0) worker.allocator.free(exception_owned);
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
    tape_refs: log_mod.TapeRefs,
) !void {
    const tl = worker.tenant_logs.get(instance_id) orelse return error.NoTenantLog;
    const allocator = worker.allocator;

    // Dupe the borrowed strings (method/path/host). On failure the
    // transferred buffers are freed by the outer captureLog wrapper.
    const a_method = try allocator.dupe(u8, method);
    errdefer allocator.free(a_method);
    const a_path = try allocator.dupe(u8, path);
    errdefer allocator.free(a_path);
    const a_host = try allocator.dupe(u8, host);
    errdefer allocator.free(a_host);

    const id = request_id orelse try tl.store.nextRequestId();
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());

    try tl.store.append(.{
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
        .tape_refs = tape_refs,
    });
}

/// Periodically drain each tenant's log buffer into a `.ndjson`
/// payload + `.idx.json` sidecar and PUT both to the configured
/// `BatchStore` (Phase 5.5 a). Runs on the leader only — followers'
/// buffers are always empty because `dispatchPending` early-returns
/// 503 on followers. Lossy on PUT failure: records already left the
/// buffer; per `docs/logs-plan.md` §1 a node-failure window may drop
/// one batch.
///
/// `log_batch_store == null` means S3 wasn't configured at startup
/// (operator skipped the env vars). Records are drained + dropped
/// with a warning so the worker still functions for tenants that
/// only need request handling, not observability.
pub fn flushLogs(worker: anytype) !void {
    const allocator = worker.allocator;
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const is_leader = worker.raft.isLeader();

    var it = worker.tenant_logs.iterator();
    while (it.next()) |entry| {
        const tl = entry.value_ptr.*;
        if (!tl.store.shouldFlush(now_ns)) continue;
        try flushOne(worker, tl, allocator, is_leader);
    }
}

fn flushOne(
    worker: anytype,
    tl: *TenantLog,
    allocator: std.mem.Allocator,
    is_leader: bool,
) !void {
    const records_opt = tl.store.drainRecords(allocator) catch |err| {
        std.log.warn("rove-js flushLogs: drainRecords({s}) failed: {s}", .{ tl.instance_id, @errorName(err) });
        return;
    };
    const records = records_opt orelse return;
    defer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }

    if (!is_leader) {
        std.log.warn(
            "rove-js flushLogs: dropping {d}-record batch for {s} — lost leadership mid-tick",
            .{ records.len, tl.instance_id },
        );
        return;
    }

    const store = worker.log_batch_store orelse {
        std.log.warn(
            "rove-js flushLogs: no log_batch_store configured; dropping {d} records for {s}",
            .{ records.len, tl.instance_id },
        );
        return;
    };

    var node_buf: [8]u8 = undefined;
    const node_id_hex = std.fmt.bufPrint(&node_buf, "{x:0>8}", .{worker.raft.config.node_id}) catch unreachable;
    const flush_unix_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));

    log_server_mod.flush_writer.writeBatch(
        allocator,
        store,
        tl.instance_id,
        node_id_hex,
        records,
        flush_unix_ms,
    ) catch |err| {
        std.log.warn(
            "rove-js flushLogs: writeBatch({s}, {d} records) failed: {s}",
            .{ tl.instance_id, records.len, @errorName(err) },
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
    var manifest = tc.store.loadCurrentDeployment() catch |err| switch (err) {
        error.NotFound => return error.NoDeployment,
        else => return err,
    };
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
    tc.bytecodes = next_bc;
    tc.source_hashes = next_source_hashes;
    tc.statics = next_statics;
    tc.triggers = triggers_slice;
    tc.current_deployment_id = manifest.id;

    std.log.info(
        "rove-js: tenant {s} loaded deployment {d} ({d} handler(s), {d} static(s), {d} trigger(s))",
        .{ tc.instance_id, manifest.id, tc.bytecodes.count(), tc.statics.count(), tc.triggers.len },
    );
}

/// Check each tenant's `deployment/current`; if it advanced since the
/// last observed id, reload the handler bytecode. Respects per-tenant
/// `next_refresh_ns` deadlines so we don't hammer the store on every
/// tick. Called from the main poll loop alongside `dispatchPending`.
pub fn refreshDeployments(worker: anytype) !void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    var it = worker.tenant_files_map.iterator();
    while (it.next()) |entry| {
        const tc = entry.value_ptr.*;
        if (now_ns < tc.next_refresh_ns) continue;
        tc.next_refresh_ns = now_ns + worker.refresh_interval_ns;

        // Peek at deployment/current without loading the full manifest —
        // if the id hasn't changed we skip the work.
        const cur_bytes = tc.files_kv.get("deployment/current") catch |err| switch (err) {
            error.NotFound => continue, // still no deployment
            else => {
                std.log.warn(
                    "rove-js refresh: tenant {s} kv.get failed: {s}",
                    .{ tc.instance_id, @errorName(err) },
                );
                continue;
            },
        };
        defer worker.allocator.free(cur_bytes);

        const new_id = std.fmt.parseInt(u64, cur_bytes, 16) catch |err| {
            std.log.warn(
                "rove-js refresh: tenant {s} current parse failed: {s}",
                .{ tc.instance_id, @errorName(err) },
            );
            continue;
        };
        if (new_id == tc.current_deployment_id) continue;

        reloadAllBytecodes(tc) catch |err| {
            std.log.warn(
                "rove-js refresh: tenant {s} reload failed: {s}",
                .{ tc.instance_id, @errorName(err) },
            );
        };
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
//      — `setSimpleResponse` + move to `response_in` or a proxy
//      queue.
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
/// `response_in`, `raft_pending`, or a proxy queue). Zero means the
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
pub const proposeFilesWriteSet = raft_propose.proposeFilesWriteSet;
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
/// Deploy the embedded starter bundle into a freshly-created
/// instance. Writes source + static blobs to the instance's
/// file-blobs/, stamps manifest entries in files.db, and
/// commits a deployment row pointing at them.
///
/// When `replicate` is non-null, every files.db write is mirrored
/// into the writeset so the caller can propose it through raft
/// (see `proposeFilesWriteSet`). Blob bytes are written to disk
/// locally on the leader and are expected to live in a shared
/// BlobStore backend for multi-node visibility.
fn deployStarterContent(
    allocator: std.mem.Allocator,
    inst_dir: []const u8,
    inst_id: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    compile_fn: files_mod.CompileFn,
    compile_ctx: ?*anyopaque,
    replicate: ?*kv_mod.WriteSet,
) !void {
    const files_db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/files.db",
        .{inst_dir},
        0,
    );
    defer allocator.free(files_db_path);

    const files_blob_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/file-blobs",
        .{inst_dir},
    );
    defer allocator.free(files_blob_dir);

    const files_kv = try kv_mod.KvStore.open(allocator, files_db_path);
    defer files_kv.close();

    var blob_backend = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        blob_cfg,
        files_blob_dir,
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
    store.setReplicate(replicate);

    try store.putSource("index.mjs", STARTER_INDEX_MJS);
    try store.putStatic("_static/index.html", STARTER_STATIC_INDEX_HTML, "text/html; charset=utf-8");
    _ = try store.deploy();
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
        blob_backend_cfg: blob_mod.BackendConfig = .fs,
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
        blob_backend_cfg: blob_mod.BackendConfig = .fs,
    };
    var fake = FakeWorker{ .allocator = allocator };
    const tc = try openTenantFiles(&fake, inst);
    defer freeTenantFiles(allocator, tc);

    const v = try inst.kv.get("durable-key");
    defer allocator.free(v);
    try testing.expectEqualStrings("durable-value", v);
}

test "captureLog appends a record to the tenant's LogStore" {
    // Verifies the captureLog helper end to end: build a fake worker
    // with a real TenantLog open against a temp dir, call captureLog,
    // then drain + apply the buffer and read the record back. Mirrors
    // the dispatchPending capture path without spinning up h2 or raft.
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

    // Construct a TenantLog directly (no Worker involved).
    const tl_dir = try std.fmt.allocPrint(allocator, "{s}/log-test", .{tmp_dir});
    defer allocator.free(tl_dir);

    const FakeWorker = struct {
        allocator: std.mem.Allocator,
        tenant_logs: std.StringHashMapUnmanaged(*TenantLog),
        blob_backend_cfg: blob_mod.BackendConfig = .fs,
    };
    var fake = FakeWorker{
        .allocator = allocator,
        .tenant_logs = .empty,
    };
    defer fake.tenant_logs.deinit(allocator);

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

    // Buffer should hold one record.
    try testing.expectEqual(@as(usize, 1), tl.store.buffer.items.len);
    const buffered = &tl.store.buffer.items[0];
    try testing.expectEqual(@as(u64, 200), @as(u64, buffered.status));
    try testing.expectEqualStrings("acme", "acme"); // sanity
    try testing.expectEqualStrings("/test", buffered.path);
    try testing.expectEqual(@as(u64, 42), buffered.deployment_id);
    try testing.expectEqual(log_mod.Outcome.ok, buffered.outcome);

    // Drain the batch and apply it locally so we exercise the same
    // code path the leader path would after raft commit.
    const batch = (try tl.store.drainBatch(allocator)).?;
    defer allocator.free(batch);
    try tl.store.applyBatch(batch);

    // Read it back via the public LogStore API.
    var result = try tl.store.list(.{ .limit = 10 });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.records.len);
    try testing.expectEqualStrings("/test", result.records[0].path);
    try testing.expectEqual(@as(u64, 42), result.records[0].deployment_id);
    try testing.expectEqual(log_mod.Outcome.ok, result.records[0].outcome);
}

test "openTenantLog migrates legacy log.db meta/next_request_seq into app.db" {
    // Phase 5.5 (a) A4 — pre-A4 workers persisted the chunked
    // reservation at `meta/next_request_seq` in log.db. Post-A4
    // openTenantLog reads from `_log/next_request_seq` in app.db.
    // The one-shot migration in `migrateRequestSeqIfNeeded` keeps
    // ids monotonic across the upgrade.
    const allocator = testing.allocator;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/rove-js-seqmig-{x}", .{seed});
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

    // Seed the legacy key in log.db before the worker opens it.
    const log_db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/acme/log.db", .{tmp_dir}, 0);
    defer allocator.free(log_db_path);
    const log_kv_seed = try kv_mod.KvStore.open(allocator, log_db_path);
    try log_kv_seed.put("meta/next_request_seq", "00000000abcd");
    log_kv_seed.close();

    const FakeWorker = struct {
        allocator: std.mem.Allocator,
        tenant_logs: std.StringHashMapUnmanaged(*TenantLog),
        blob_backend_cfg: blob_mod.BackendConfig = .fs,
    };
    var fake = FakeWorker{ .allocator = allocator, .tenant_logs = .empty };
    defer fake.tenant_logs.deinit(allocator);

    const tl = try openTenantLog(&fake, inst, 9);
    defer freeTenantLog(allocator, tl);

    // app.db should now carry the migrated counter, and a fresh
    // mint should resume from at-or-after the legacy reservation.
    const migrated = try inst.kv.get("_log/next_request_seq");
    defer allocator.free(migrated);
    try testing.expectEqualStrings("00000000abcd", migrated);

    const id = try tl.store.nextRequestId();
    try testing.expect((id & 0xFFFFFFFFFFFF) >= 0xabcd);
}
