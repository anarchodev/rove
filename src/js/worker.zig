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
const tape_mod = @import("rove-tape");
const tenant_mod = @import("rove-tenant");

const dispatcher_mod = @import("dispatcher.zig");
const apply_mod = @import("apply.zig");
const penalty_mod = @import("penalty.zig");
const router_mod = @import("router.zig");
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
    /// Owned blob backend at `{inst.dir}/file-blobs/`.
    blob_backend: blob_mod.FilesystemBlobStore,
    /// rove-files wrapper over `files_kv` + `blob_backend`. Compile hook
    /// is a stub — the worker only reads, never uploads.
    store: files_mod.FileStore,
    /// Deployment id we last loaded. `0` = no deployment observed yet.
    current_deployment_id: u64,
    /// All handler bytecodes from the active deployment, keyed by the
    /// full deployment path (e.g. `"index.js"`, `"api/users/index.js"`).
    /// Both keys and values are owned by `allocator`.
    bytecodes: std.StringHashMapUnmanaged([]u8),
    /// Static files in the active deployment, keyed by the stored path
    /// (e.g. `"_static/index.html"`). Keys and `StaticEntry.content_type`
    /// are owned by `allocator`; bytes are fetched from `blob_backend`
    /// on demand.
    statics: std.StringHashMapUnmanaged(StaticEntry),
    /// When the next refresh check is allowed (absolute
    /// `std.time.nanoTimestamp()`). `refreshDeployments` skips tenants
    /// whose deadline hasn't passed yet so we don't hammer the code
    /// store on every tick.
    next_refresh_ns: i64,
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
    blob_backend: blob_mod.FilesystemBlobStore,
    store: log_mod.LogStore,
};

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
};

/// Cross-reference component used by the `/_system/*` proxy. Lives
/// on server-side entities parked in each subsystem's `inflight`
/// collection; the `client` field points at the client-side entity
/// that was submitted into rove-h2's `client_request_in`. On each
/// tick we scan `client_response_out`, match each client entity
/// back to its server peer via this field, and copy the upstream
/// response onto the server entity before delivering it to the
/// downstream user.
pub const ProxyPeer = struct { client: rove.Entity };

/// Tag applied to every client-side entity the worker submits so
/// `ingestProxyConnects` and `drainProxyResponses` can route each
/// entity back to its originating subsystem without scanning.
/// `.none` is the default for non-proxy client entities (tests /
/// future uses) and is a no-op sentinel.
pub const ProxyTag = struct {
    kind: enum(u8) { none = 0, code = 1, log = 2 } = .none,
};

/// Per-subsystem proxy state. The worker holds one of these for
/// `code` and one for `log`; the proxy systems below take a
/// `*ProxySubsystem` argument instead of reaching into fields by
/// name, so adding a third subsystem later is a matter of
/// constructing a third instance and tagging its client entities.
pub fn ProxySubsystem(comptime StreamCollT: type) type {
    return struct {
        const Self = @This();
        pending: StreamCollT,
        inflight: StreamCollT,
        session: rove.Entity = rove.Entity.nil,
        addr: ?std.net.Address = null,
        connecting: bool = false,
        tag: ProxyTag,

        pub fn init(allocator: std.mem.Allocator, tag: ProxyTag, addr: ?std.net.Address) !Self {
            return .{
                .pending = try StreamCollT.init(allocator),
                .inflight = try StreamCollT.init(allocator),
                .addr = addr,
                .tag = tag,
            };
        }

        pub fn deinit(self: *Self) void {
            self.inflight.deinit();
            self.pending.deinit();
        }
    };
}

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
        tenant_files_map: std.StringHashMapUnmanaged(*TenantFiles),
        /// Per-tenant log state. Same lifetime + key-stability story
        /// as `tenant_files_map`. Opened eagerly alongside it. The worker's
        /// dispatch path appends LogRecords into each tenant's
        /// `store.buffer`; `flushLogs` drains and proposes batches.
        tenant_logs: std.StringHashMapUnmanaged(*TenantLog),
        /// Circuit breaker for handlers that blow past their CPU
        /// budget. A tenant with `kill_threshold` interrupts inside a
        /// single `window_ns` gets bounced with 503 for
        /// `open_duration_ns` — protecting the shared h2 thread from a
        /// runaway stored procedure. Auto-releases on redeploy.
        penalty_box: penalty_mod.PenaltyBox,
        commit_wait_timeout_ns: u64,
        refresh_interval_ns: i64,
        /// Borrowed from `WorkerConfig.admin_origin`. See the config
        /// field for semantics. Null when CORS is disabled.
        admin_origin: ?[]const u8,
        /// Borrowed from `WorkerConfig.admin_api_domain`. Null
        /// disables admin subdomain routing entirely.
        admin_api_domain: ?[]const u8,

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
                .commit_wait_timeout_ns = config.commit_wait_timeout_ns,
                .refresh_interval_ns = config.refresh_interval_ns,
                .admin_origin = config.admin_origin,
                .admin_api_domain = config.admin_api_domain,
            };
            errdefer self.raft_pending.deinit();
            errdefer self.code_proxy.deinit();
            errdefer self.log_proxy.deinit();
            errdefer destroyAllTenantFiles(self);
            errdefer destroyAllTenantLogs(self);

            reg.registerCollection(&self.raft_pending);
            reg.registerCollection(&self.code_proxy.pending);
            reg.registerCollection(&self.code_proxy.inflight);
            reg.registerCollection(&self.log_proxy.pending);
            reg.registerCollection(&self.log_proxy.inflight);

            // Eagerly open code AND log state for every known tenant.
            // The tenant registry's instances map was populated by
            // the caller before this create() call; we iterate it
            // once and open both per-tenant stores.
            const worker_id: u16 = config.log_worker_id orelse @intCast(config.raft.config.node_id);
            var it = config.tenant.instances.iterator();
            while (it.next()) |entry| {
                const inst = entry.value_ptr.*;
                const tc = try openTenantFiles(self, inst);
                try self.tenant_files_map.put(self.allocator, tc.instance_id, tc);
                const tl = try openTenantLog(self, inst, worker_id);
                try self.tenant_logs.put(self.allocator, tl.instance_id, tl);
            }

            return self;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            self.penalty_box.deinit();
            destroyAllTenantLogs(self);
            self.tenant_logs.deinit(allocator);
            destroyAllTenantFiles(self);
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

    var blob_backend = try blob_mod.FilesystemBlobStore.open(allocator, files_blob_dir);
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
        .statics = .empty,
        .next_refresh_ns = 0,
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
    freeStatics(tc);
    tc.blob_backend.deinit();
    tc.files_kv.close();
    allocator.free(tc.instance_id);
    allocator.destroy(tc);
}

fn destroyAllTenantFiles(worker: anytype) void {
    var it = worker.tenant_files_map.iterator();
    while (it.next()) |entry| freeTenantFiles(worker.allocator, entry.value_ptr.*);
    worker.tenant_files_map.clearRetainingCapacity();
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

    var blob_backend = try blob_mod.FilesystemBlobStore.open(allocator, log_blob_dir);
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
    tl.store = try log_mod.LogStore.init(allocator, tl.log_kv, tl.blob_backend.blobStore(), worker_id);
    return tl;
}

fn freeTenantLog(allocator: std.mem.Allocator, tl: *TenantLog) void {
    tl.store.deinit();
    tl.blob_backend.deinit();
    tl.log_kv.close();
    allocator.free(tl.instance_id);
    allocator.destroy(tl);
}

fn destroyAllTenantLogs(worker: anytype) void {
    var it = worker.tenant_logs.iterator();
    while (it.next()) |entry| freeTenantLog(worker.allocator, entry.value_ptr.*);
    worker.tenant_logs.clearRetainingCapacity();
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

    pub fn init(allocator: std.mem.Allocator) RequestTapes {
        return .{
            .kv = tape_mod.Tape.init(allocator, .kv),
            .date = tape_mod.Tape.init(allocator, .date),
            .math_random = tape_mod.Tape.init(allocator, .math_random),
            .crypto_random = tape_mod.Tape.init(allocator, .crypto_random),
        };
    }

    pub fn deinit(self: *RequestTapes) void {
        self.kv.deinit();
        self.date.deinit();
        self.math_random.deinit();
        self.crypto_random.deinit();
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
fn uploadTapes(
    worker: anytype,
    instance_id: []const u8,
    tapes: *RequestTapes,
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

    return refs;
}

fn captureLog(
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
    captureLogInner(
        worker,
        instance_id,
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

    const id = try tl.store.nextRequestId();
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

/// Periodically drain each tenant's log buffer into a batch and ship
/// it. Runs on the leader only (followers' buffers are always empty
/// because `dispatchPending` early-returns 503 on followers).
///
/// On the leader, the flush is a two-step write:
///
/// 1. Propose the batch envelope through raft so followers replicate.
/// 2. Apply the batch to the leader's OWN log.db directly, on the h2
///    thread. The apply callback skips on the leader (see
///    `applyLogBatch` in apply.zig) precisely so the h2 thread can be
///    the sole writer to the leader's log.db connection — required
///    because rove-kv opens its SQLite connections with
///    `SQLITE_OPEN_NOMUTEX` and a multi-thread shared connection
///    would corrupt state.
///
/// If propose fails, we still write locally — the records are
/// best-effort observability, and a leader-only view is better than
/// nothing. Defensive: if leadership flipped mid-tick we drop the
/// orphan buffer entirely (no propose, no local write) to honor the
/// "no follower-originated logs" rule.
pub fn flushLogs(worker: anytype) !void {
    const allocator = worker.allocator;
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const is_leader = worker.raft.isLeader();

    var it = worker.tenant_logs.iterator();
    while (it.next()) |entry| {
        const tl = entry.value_ptr.*;
        if (!tl.store.shouldFlush(now_ns)) continue;

        const batch = (tl.store.drainBatch(allocator) catch |err| {
            std.log.warn("rove-js flushLogs: drainBatch({s}) failed: {s}", .{ tl.instance_id, @errorName(err) });
            continue;
        }) orelse continue;
        defer allocator.free(batch);

        if (!is_leader) {
            // Leadership flipped between dispatchPending (when the
            // records were appended) and this flush. Drop the batch —
            // the new leader will produce its own logs for any
            // requests it handles. Per the "best-effort + no
            // follower-originated logs" rules.
            std.log.warn(
                "rove-js flushLogs: dropping {d}-byte batch for {s} — lost leadership mid-tick",
                .{ batch.len, tl.instance_id },
            );
            continue;
        }

        const envelope = apply_mod.encodeLogBatchEnvelope(allocator, tl.instance_id, batch) catch |err| {
            std.log.warn("rove-js flushLogs: envelope encode failed: {s}", .{@errorName(err)});
            // Local write still useful even if envelope fails.
            tl.store.applyBatch(batch) catch {};
            continue;
        };
        defer allocator.free(envelope);

        const seq = worker.raft.highWatermark() + 1;
        worker.raft.propose(seq, envelope) catch |err| {
            std.log.warn(
                "rove-js flushLogs: raft propose failed for {s}: {s} — local-only write",
                .{ tl.instance_id, @errorName(err) },
            );
        };

        // Local apply on the h2 thread. Single-writer to leader's
        // log.db — see the doc comment above + `applyLogBatch`.
        tl.store.applyBatch(batch) catch |err| {
            std.log.warn(
                "rove-js flushLogs: local applyBatch({s}) failed: {s}",
                .{ tl.instance_id, @errorName(err) },
            );
        };
    }
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

    var next_statics: std.StringHashMapUnmanaged(StaticEntry) = .empty;
    errdefer {
        var it = next_statics.iterator();
        while (it.next()) |e| {
            tc.allocator.free(e.key_ptr.*);
            tc.allocator.free(e.value_ptr.*.content_type);
        }
        next_statics.deinit(tc.allocator);
    }

    for (manifest.entries) |entry| {
        const path_copy = try tc.allocator.dupe(u8, entry.path);
        errdefer tc.allocator.free(path_copy);
        switch (entry.kind) {
            .handler => {
                const bytecode = try bs.get(&entry.bytecode_hex, tc.allocator);
                errdefer tc.allocator.free(bytecode);
                try next_bc.put(tc.allocator, path_copy, bytecode);
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

    // Swap.
    freeBytecodes(tc);
    freeStatics(tc);
    tc.bytecodes = next_bc;
    tc.statics = next_statics;
    tc.current_deployment_id = manifest.id;

    std.log.info(
        "rove-js: tenant {s} loaded deployment {d} ({d} handler(s), {d} static(s))",
        .{ tc.instance_id, manifest.id, tc.bytecodes.count(), tc.statics.count() },
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
pub fn dispatchOnce(worker: anytype, blocked: anytype) !usize {
    const server = worker.h2;
    const allocator = worker.allocator;

    const entities = server.request_out.entitySlice();
    const sids = server.request_out.column(h2.StreamId);
    const sessions = server.request_out.column(h2.Session);
    const req_hdrs = server.request_out.column(h2.ReqHeaders);
    const req_bodies = server.request_out.column(h2.ReqBody);

    // Leader-only request handling. Followers serve no client traffic
    // — they just replicate the leader's raft entries. Any request
    // that lands on a follower is bounced with 503 + a hint so the
    // client retries against the leader.
    const is_leader = worker.raft.isLeader();

    // Batch state. Set lazily on the first handler-bound request we
    // see; subsequent requests in the same walk that target a
    // different tenant are left in request_out for a future
    // dispatchOnce call to pick up.
    var anchor: ?*const tenant_mod.Instance = null;
    var txn: ?kv_mod.KvStore.TrackedTxn = null;
    var writeset = kv_mod.WriteSet.init(allocator);
    defer writeset.deinit();

    // Successful handlers awaiting the shared commit + final move.
    // Owns `console_owned` / `exception_owned` until they transfer
    // into a log record after commit.
    const SuccessRec = struct {
        ent: rove.Entity,
        sid: h2.StreamId,
        sess: h2.Session,
        status_code: u16,
        body_ptr: ?[*]u8,
        body_len: u32,
        console_owned: []u8,
        exception_owned: []u8,
        method: []const u8,
        path: []const u8,
        host: []const u8,
        deployment_id: u64,
        received_ns: i64,
        tape_refs: log_mod.TapeRefs,
    };
    var successes: std.ArrayList(SuccessRec) = .empty;
    defer {
        for (successes.items) |*s| {
            if (s.console_owned.len > 0) allocator.free(s.console_owned);
            if (s.exception_owned.len > 0) allocator.free(s.exception_owned);
        }
        successes.deinit(allocator);
    }

    var processed: usize = 0;

    for (entities, sids, sessions, req_hdrs, req_bodies) |ent, sid, sess, rh, rb| {
        if (!is_leader) {
            try setSimpleResponse(server, ent, sid, sess, 503, "not leader; retry against the cluster leader\n", allocator);
            processed += 1;
            continue;
        }

        const received_ns: i64 = @intCast(std.time.nanoTimestamp());

        const method = findHeader(rh, ":method") orelse "GET";
        const path = findHeader(rh, ":path") orelse "/";
        const authority = findHeader(rh, ":authority") orelse "";
        const body: []const u8 = if (rb.data) |p| p[0..rb.len] else "";

        // `/_system/*` — CORS gate, then auth + proxy routing.
        if (std.mem.startsWith(u8, path, "/_system/")) {
            // Every /_system/* response carries CORS headers when the
            // worker has an admin origin configured. Browsers enforce
            // the origin match on their side against
            // `Access-Control-Allow-Origin`, so stamping headers even
            // on requests without an Origin is harmless and keeps the
            // response path simple.
            const cors_origin = worker.admin_origin;

            // Preflight: browser sends OPTIONS before the real request
            // to discover allowed methods/headers. Answer 204 with the
            // preflight-specific CORS headers and never touch auth —
            // preflights don't carry the bearer token.
            if (std.mem.eql(u8, method, "OPTIONS")) {
                if (cors_origin) |o| {
                    const req_origin = findHeader(rh, "origin") orelse "";
                    if (req_origin.len == 0 or !std.mem.eql(u8, req_origin, o)) {
                        try setSystemResponse(server, ent, sid, sess, 403, "cors origin not allowed\n", allocator, null, null);
                    } else {
                        const hdrs = try buildSystemRespHeaders(allocator, o, true, null);
                        try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = 204 });
                        try server.reg.set(ent, &server.request_out, h2.RespHeaders, hdrs);
                        try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = null, .len = 0 });
                        try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
                        try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
                        try server.reg.set(ent, &server.request_out, h2.Session, sess);
                        try server.reg.move(ent, &server.request_out, &server.response_in);
                    }
                } else {
                    try setSimpleResponse(server, ent, sid, sess, 405, "OPTIONS not supported\n", allocator);
                }
                processed += 1;
                continue;
            }

            const token = extractBearerToken(rh) orelse {
                try setSystemResponse(server, ent, sid, sess, 401, "missing bearer token\n", allocator, cors_origin, null);
                processed += 1;
                continue;
            };
            const auth_ctx = worker.tenant.authenticate(token) catch |err| {
                std.log.warn("rove-js: authenticate failed: {s}", .{@errorName(err)});
                try setSystemResponse(server, ent, sid, sess, 500, "auth check failed\n", allocator, cors_origin, null);
                processed += 1;
                continue;
            };
            if (auth_ctx == null) {
                try setSystemResponse(server, ent, sid, sess, 401, "invalid bearer token\n", allocator, cors_origin, null);
                processed += 1;
                continue;
            }

            // Strip `?query=string` off the path before routing. The
            // remaining `/_system/*` subsystems (log, code proxies)
            // forward the whole `:path` downstream; query parsing
            // happens in the subsystem thread, not here.
            const qmark = std.mem.indexOfScalar(u8, path, '?');
            const path_no_q = if (qmark) |q| path[0..q] else path;

            const sys_rest = path_no_q["/_system/".len..];
            const sub_slash = std.mem.indexOfScalar(u8, sys_rest, '/') orelse {
                try setSystemResponse(server, ent, sid, sess, 404, "malformed system path\n", allocator, cors_origin, null);
                processed += 1;
                continue;
            };
            const subsystem = sys_rest[0..sub_slash];
            const after_sub = sys_rest[sub_slash + 1 ..];

            // `/_system/tenant/*` and `/_system/kv/*` used to be
            // Zig-native endpoints. They moved to the `__admin__` JS
            // handler (see memory/project_admin_ui_plan.md). Callers
            // should now target `{id}.api.loop46.com/kv` etc.
            //
            // `/_system/log/*` and `/_system/files/*` remain native:
            //   - log queries poll frequently for live-tail and would
            //     meta-log themselves through the JS handler.
            //   - code uploads are byte-heavy and fit the existing
            //     subsystem thread better.

            const inst_slash = std.mem.indexOfScalar(u8, after_sub, '/');
            const sys_instance_id = if (inst_slash) |s| after_sub[0..s] else after_sub;
            if (sys_instance_id.len == 0) {
                try setSystemResponse(server, ent, sid, sess, 404, "missing instance id\n", allocator, cors_origin, null);
                processed += 1;
                continue;
            }
            const allowed = worker.tenant.canAccessInstance(auth_ctx.?, sys_instance_id) catch false;
            if (!allowed) {
                try setSystemResponse(server, ent, sid, sess, 403, "forbidden\n", allocator, cors_origin, null);
                processed += 1;
                continue;
            }

            if (std.mem.eql(u8, subsystem, "files")) {
                if (worker.code_proxy.addr == null) {
                    try setSystemResponse(server, ent, sid, sess, 503, "files subsystem disabled\n", allocator, cors_origin, null);
                    processed += 1;
                    continue;
                }
                try server.reg.set(ent, &server.request_out, ProxyPeer, .{ .client = rove.Entity.nil });
                try server.reg.move(ent, &server.request_out, &worker.code_proxy.pending);
                processed += 1;
                continue;
            }
            if (std.mem.eql(u8, subsystem, "log")) {
                if (worker.log_proxy.addr == null) {
                    try setSystemResponse(server, ent, sid, sess, 503, "log subsystem disabled\n", allocator, cors_origin, null);
                    processed += 1;
                    continue;
                }
                try server.reg.set(ent, &server.request_out, ProxyPeer, .{ .client = rove.Entity.nil });
                try server.reg.move(ent, &server.request_out, &worker.log_proxy.pending);
                processed += 1;
                continue;
            }

            try setSystemResponse(server, ent, sid, sess, 501, "system endpoint not implemented\n", allocator, cors_origin, null);
            processed += 1;
            continue;
        }

        const host = hostOnly(authority);

        // Resolve (handler, scope) for this request. For normal user
        // traffic both come from `resolveDomain(host)` — handler runs
        // against its own KV. For admin requests
        // (`{id}.{admin_api_domain}` or the bare admin_api_domain),
        // the `__admin__` tenant's handler runs against the target
        // scope's KV. Admin requests require a root bearer token.
        const admin_scope_opt: ?[]const u8 =
            if (worker.admin_api_domain) |pat| matchAdminSubdomain(host, pat) else null;
        const is_admin_request = admin_scope_opt != null;

        var handler_inst: *const tenant_mod.Instance = undefined;
        var scope_inst: *const tenant_mod.Instance = undefined;

        if (is_admin_request) {
            // Preflight: browser sends OPTIONS before the real admin
            // API call. Answer 204 with CORS preflight headers; skip
            // auth (preflights don't carry the bearer token).
            if (std.mem.eql(u8, method, "OPTIONS")) {
                if (worker.admin_origin) |o| {
                    const req_origin = findHeader(rh, "origin") orelse "";
                    if (req_origin.len == 0 or !std.mem.eql(u8, req_origin, o)) {
                        try setSystemResponse(server, ent, sid, sess, 403, "cors origin not allowed\n", allocator, null, null);
                    } else {
                        const hdrs = try buildSystemRespHeaders(allocator, o, true, null);
                        try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = 204 });
                        try server.reg.set(ent, &server.request_out, h2.RespHeaders, hdrs);
                        try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = null, .len = 0 });
                        try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
                        try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
                        try server.reg.set(ent, &server.request_out, h2.Session, sess);
                        try server.reg.move(ent, &server.request_out, &server.response_in);
                    }
                } else {
                    try setSimpleResponse(server, ent, sid, sess, 405, "OPTIONS not supported\n", allocator);
                }
                processed += 1;
                continue;
            }

            const admin_cors = worker.admin_origin;
            const token = extractBearerToken(rh) orelse {
                try setSystemResponse(server, ent, sid, sess, 401, "missing bearer token\n", allocator, admin_cors, null);
                processed += 1;
                continue;
            };
            const ctx_opt = worker.tenant.authenticate(token) catch |err| blk: {
                std.log.warn("rove-js: admin authenticate failed: {s}", .{@errorName(err)});
                break :blk null;
            };
            if (ctx_opt == null or !ctx_opt.?.is_root) {
                try setSystemResponse(server, ent, sid, sess, 401, "invalid bearer token\n", allocator, admin_cors, null);
                processed += 1;
                continue;
            }

            const admin_opt = worker.tenant.getInstance(tenant_mod.ADMIN_INSTANCE_ID) catch null;
            if (admin_opt == null) {
                try setSystemResponse(server, ent, sid, sess, 503, "admin tenant not provisioned\n", allocator, admin_cors, null);
                processed += 1;
                continue;
            }
            handler_inst = admin_opt.?;

            const scope_id = admin_scope_opt.?;
            if (scope_id.len == 0) {
                // Bare admin domain: scope is the admin tenant itself
                // (so `kv.*` reads/writes the root store directly).
                scope_inst = handler_inst;
            } else {
                const s_opt = worker.tenant.getInstance(scope_id) catch |err| blk: {
                    std.log.warn("rove-js: admin getInstance({s}) failed: {s}", .{ scope_id, @errorName(err) });
                    break :blk null;
                };
                if (s_opt == null) {
                    try setSystemResponse(server, ent, sid, sess, 404, "unknown instance\n", allocator, admin_cors, null);
                    processed += 1;
                    continue;
                }
                scope_inst = s_opt.?;
            }
        } else {
            const r = worker.tenant.resolveDomain(host) catch |err| {
                std.log.warn("rove-js: tenant.resolveDomain({s}) failed: {s}", .{ host, @errorName(err) });
                try setSimpleResponse(server, ent, sid, sess, 500, "tenant resolution failed\n", allocator);
                processed += 1;
                continue;
            };
            if (r == null) {
                try setSimpleResponse(server, ent, sid, sess, 404, "unknown domain\n", allocator);
                processed += 1;
                continue;
            }
            handler_inst = r.?;
            scope_inst = r.?;
        }

        // Lazy-open: instances created at runtime aren't in the map yet.
        // On first hit, open TenantFiles and cache. Failure here is a
        // real error (corrupt store / disk) — 500.
        const tc = worker.tenant_files_map.get(handler_inst.id) orelse blk: {
            const opened = openTenantFiles(worker, handler_inst) catch |err| {
                std.log.warn("rove-js: lazy openTenantFiles({s}) failed: {s}", .{ handler_inst.id, @errorName(err) });
                try setSimpleResponse(server, ent, sid, sess, 500, "tenant code state missing\n", allocator);
                captureLog(worker, scope_inst.id, method, path, host, 0, received_ns, 500, .handler_error, &.{}, &.{}, .{});
                processed += 1;
                continue;
            };
            worker.tenant_files_map.put(worker.allocator, opened.instance_id, opened) catch |err| {
                std.log.warn("rove-js: lazy tenant_files_map.put failed: {s}", .{@errorName(err)});
                freeTenantFiles(worker.allocator, opened);
                try setSimpleResponse(server, ent, sid, sess, 500, "tenant code state missing\n", allocator);
                captureLog(worker, scope_inst.id, method, path, host, 0, received_ns, 500, .handler_error, &.{}, &.{}, .{});
                processed += 1;
                continue;
            };
            break :blk opened;
        };
        if (tc.current_deployment_id == 0) {
            try setSimpleResponse(server, ent, sid, sess, 503, "no deployment for this tenant\n", allocator);
            captureLog(worker, scope_inst.id, method, path, host, 0, received_ns, 503, .no_deployment, &.{}, &.{}, .{});
            processed += 1;
            continue;
        }

        // Static-first dispatch: GET requests for paths that map onto a
        // `_static/*` manifest entry get served natively here — no JS
        // context, no budget, no tape capture. On a miss we fall
        // through to handler resolution below. Admin requests also
        // pass through so the admin UI is dogfooded via `_static/*`.
        if (std.mem.eql(u8, method, "GET")) {
            const static_outcome = try tryServeStatic(
                server,
                allocator,
                ent,
                sid,
                sess,
                tc,
                path,
                rh,
            );
            switch (static_outcome) {
                .served => |status| {
                    captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, status, .ok, &.{}, &.{}, .{});
                    processed += 1;
                    continue;
                },
                .miss => {},
            }
        }

        var route = router_mod.resolveRoute(allocator, path) catch |err| {
            std.log.warn("rove-js router failed: {s}", .{@errorName(err)});
            try setErrorResponse(server, ent, sid, sess);
            captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, 500, .handler_error, &.{}, &.{}, .{});
            processed += 1;
            continue;
        };
        defer route.deinit();

        const bytecode = (try findBytecode(tc, route.module_base, allocator)) orelse {
            // Convention 404: serve `_static/_404.html` if the tenant
            // has it. Otherwise fall back to the built-in text body.
            if (!try serveConvention404(server, allocator, ent, sid, sess, tc)) {
                try setSimpleResponse(server, ent, sid, sess, 404, "not found\n", allocator);
            }
            captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, 404, .handler_error, &.{}, &.{}, .{});
            processed += 1;
            continue;
        };

        if (worker.penalty_box.isBoxed(handler_inst.id, tc.current_deployment_id, received_ns)) {
            try setSimpleResponse(server, ent, sid, sess, 503, "tenant temporarily disabled (cpu budget)\n", allocator);
            captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, 503, .timeout, &.{}, &.{}, .{});
            processed += 1;
            continue;
        }

        // This is a handler-bound request. Either establish the
        // tick's anchor tenant (open the batch txn) or — if an anchor
        // already exists and this entity targets a different tenant
        // (or the tenant was marked busy earlier this tick) — skip it,
        // leaving it in request_out for a future dispatchOnce call.
        if (anchor) |a| {
            if (a != scope_inst) continue;
        } else {
            // Already proven BUSY earlier this tick? Skip.
            var skip_blocked = false;
            for (blocked.slice()) |b| {
                if (b == scope_inst) {
                    skip_blocked = true;
                    break;
                }
            }
            if (skip_blocked) continue;

            var new_txn = scope_inst.kv.beginTrackedImmediate() catch |err| {
                std.log.warn("rove-js beginTrackedImmediate({s}) failed: {s}", .{ scope_inst.id, @errorName(err) });
                try setSimpleResponse(server, ent, sid, sess, 500, "txn begin failed\n", allocator);
                captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, 500, .kv_error, &.{}, &.{}, .{});
                processed += 1;
                continue;
            };
            // Eagerly open the underlying SQLite txn so SQLITE_BUSY
            // surfaces HERE — if another worker holds RESERVED on
            // this tenant's app.db we note the tenant as blocked for
            // the remainder of this tick and skip past it to try a
            // different anchor (Stage 3: cross-tenant scheduling on
            // contention).
            new_txn.open() catch |err| {
                if (err == kv_mod.KvError.Conflict) {
                    blocked.append(scope_inst) catch {
                        // blocked list is bounded; overflow means this
                        // tick has already tried more tenants than we
                        // budgeted for. Leave the entity in place and
                        // return what we've processed so far — next
                        // tick gets a fresh blocked list.
                        return processed;
                    };
                    continue;
                }
                std.log.warn("rove-js open tracked txn ({s}) failed: {s}", .{ scope_inst.id, @errorName(err) });
                try setSimpleResponse(server, ent, sid, sess, 500, "txn open failed\n", allocator);
                captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, 500, .kv_error, &.{}, &.{}, .{});
                processed += 1;
                continue;
            };
            txn = new_txn;
            anchor = scope_inst;
        }

        // At this point `anchor` is set and equals `scope_inst`, and
        // `txn` is open. Run the handler under its own savepoint so a
        // JS exception or CPU-budget kill rolls back only this handler's
        // writes without poisoning the rest of the batch.
        var tapes = RequestTapes.init(allocator);
        defer tapes.deinit();

        const request: Request = .{
            .method = method,
            .path = path,
            .body = body,
            .query = route.query,
            .kv_tape = &tapes.kv,
            .date_tape = &tapes.date,
            .math_random_tape = &tapes.math_random,
            .crypto_random_tape = &tapes.crypto_random,
            .prng_seed = @bitCast(received_ns),
        };

        txn.?.savepoint() catch |err| {
            std.log.warn("rove-js savepoint({s}) failed: {s}", .{ scope_inst.id, @errorName(err) });
            try setSimpleResponse(server, ent, sid, sess, 500, "savepoint failed\n", allocator);
            captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, 500, .kv_error, &.{}, &.{}, .{});
            processed += 1;
            continue;
        };

        var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
        var resp = worker.dispatcher.run(
            scope_inst.kv,
            &txn.?,
            &writeset,
            bytecode,
            &tc.bytecodes,
            request,
            &budget,
        ) catch |err| {
            txn.?.rollbackTo() catch {};
            const outcome: log_mod.Outcome = if (err == dispatcher_mod.DispatchError.Interrupted)
                .timeout
            else
                .handler_error;
            const status: u16 = if (err == dispatcher_mod.DispatchError.Interrupted) 504 else 500;
            if (err == dispatcher_mod.DispatchError.Interrupted) {
                try setSimpleResponse(server, ent, sid, sess, 504, "handler exceeded cpu budget\n", allocator);
                worker.penalty_box.recordKill(
                    handler_inst.id,
                    tc.current_deployment_id,
                    received_ns,
                ) catch |pe| std.log.warn("rove-js penalty recordKill failed: {s}", .{@errorName(pe)});
            } else {
                try setErrorResponse(server, ent, sid, sess);
            }
            captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, status, outcome, &.{}, &.{}, .{});
            processed += 1;
            continue;
        };
        // `resp.console` / `resp.exception` are freed here unless we
        // transfer them into a SuccessRec below.
        defer {
            if (resp.console.len > 0) allocator.free(resp.console);
            if (resp.exception.len > 0) allocator.free(resp.exception);
        }

        if (worker.dispatcher.last_kv_error != null) {
            std.log.warn("rove-js handler kv error: {s}", .{@errorName(worker.dispatcher.last_kv_error.?)});
            worker.dispatcher.last_kv_error = null;
            txn.?.rollbackTo() catch {};
            try setSimpleResponse(server, ent, sid, sess, 500, "kv error during handler\n", allocator);
            captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, 500, .kv_error, &.{}, &.{}, .{});
            processed += 1;
            continue;
        }

        txn.?.release() catch |err| {
            std.log.warn("rove-js release savepoint failed: {s}", .{@errorName(err)});
            try setSimpleResponse(server, ent, sid, sess, 500, "kv release failed\n", allocator);
            captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, 500, .kv_error, &.{}, &.{}, .{});
            processed += 1;
            continue;
        };

        // Stamp response components on the entity. They ride through
        // `raft_pending` → `response_in` (or straight to `response_in`
        // for pure-read batches) without rewrites. The entity stays
        // in `request_out` until the shared commit completes below.
        const body_ptr: ?[*]u8 = if (resp.body.len > 0) resp.body.ptr else null;
        const body_len: u32 = @intCast(resp.body.len);
        resp.body = &.{};
        const status_code: u16 = @intCast(@max(@min(resp.status, 599), 100));

        // Admin-subdomain responses carry CORS headers so the browser
        // UI on a different origin can read them. Non-admin user
        // traffic is same-origin (it's their tenant's own domain) and
        // gets empty RespHeaders (plus any Set-Cookies the handler
        // pushed via `response.cookies`).
        const handler_cors = if (is_admin_request) worker.admin_origin else null;
        const handler_resp_hdrs: h2.RespHeaders = try buildHandlerRespHeaders(
            allocator,
            handler_cors,
            resp.set_cookies,
        );
        try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status_code });
        try server.reg.set(ent, &server.request_out, h2.RespHeaders, handler_resp_hdrs);
        try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = body_ptr, .len = body_len });
        try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
        try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
        try server.reg.set(ent, &server.request_out, h2.Session, sess);

        // Upload tapes now — blob-addressed and idempotent, so storing
        // them before commit is safe even if the batch later rolls
        // back. The refs get carried into the log record after commit.
        const tape_refs = uploadTapes(worker, scope_inst.id, &tapes);

        const console_owned = resp.console;
        const exception_owned = resp.exception;
        resp.console = &.{};
        resp.exception = &.{};

        try successes.append(allocator, .{
            .ent = ent,
            .sid = sid,
            .sess = sess,
            .status_code = status_code,
            .body_ptr = body_ptr,
            .body_len = body_len,
            .console_owned = console_owned,
            .exception_owned = exception_owned,
            .method = method,
            .path = path,
            .host = host,
            .deployment_id = tc.current_deployment_id,
            .received_ns = received_ns,
            .tape_refs = tape_refs,
        });
    }

    // End of walk. If no anchor was opened we're done — all processing
    // was short-circuit (failed) paths.
    if (anchor == null) return processed;

    const anchor_id = anchor.?.id;
    const store = anchor.?.kv;
    const batch_seq = txn.?.txn_seq;
    const has_writes = writeset.ops.items.len > 0;

    // Commit the shared batch txn. A commit failure means SQLite has
    // already rolled back everything — downgrade every success to 503.
    txn.?.commit() catch |err| {
        std.log.warn("rove-js txn commit (batch, tenant={s}) failed: {s}", .{ anchor_id, @errorName(err) });
        for (successes.items) |*s| {
            overwriteWith503(server, s.ent, allocator, s.body_ptr, s.body_len) catch {};
            server.reg.move(s.ent, &server.request_out, &server.response_in) catch {};
            const console_owned = s.console_owned;
            const exception_owned = s.exception_owned;
            s.console_owned = &.{};
            s.exception_owned = &.{};
            captureLog(worker, anchor_id, s.method, s.path, s.host, s.deployment_id, s.received_ns, 503, .kv_error, console_owned, exception_owned, s.tape_refs);
            processed += 1;
        }
        successes.clearRetainingCapacity();
        return processed;
    };

    if (!has_writes) {
        // Pure read-only batch: no raft hop.
        for (successes.items) |*s| {
            server.reg.move(s.ent, &server.request_out, &server.response_in) catch {};
            const console_owned = s.console_owned;
            const exception_owned = s.exception_owned;
            s.console_owned = &.{};
            s.exception_owned = &.{};
            captureLog(worker, anchor_id, s.method, s.path, s.host, s.deployment_id, s.received_ns, s.status_code, .ok, console_owned, exception_owned, s.tape_refs);
            processed += 1;
        }
        successes.clearRetainingCapacity();
        return processed;
    }

    // Writes present: propose the merged writeset once for the whole
    // batch. On propose failure, compensating-rollback via undoTxn and
    // downgrade every success to 503.
    const seq = proposeWriteSet(worker, &writeset, anchor_id) catch |err| {
        std.log.warn("rove-js raft propose (batch, tenant={s}) failed: {s}", .{ anchor_id, @errorName(err) });
        store.undoTxn(batch_seq) catch |undo_err| {
            std.log.err("rove-js undoTxn failed after propose error: {s}", .{@errorName(undo_err)});
        };
        for (successes.items) |*s| {
            overwriteWith503(server, s.ent, allocator, s.body_ptr, s.body_len) catch {};
            server.reg.move(s.ent, &server.request_out, &server.response_in) catch {};
            const console_owned = s.console_owned;
            const exception_owned = s.exception_owned;
            s.console_owned = &.{};
            s.exception_owned = &.{};
            captureLog(worker, anchor_id, s.method, s.path, s.host, s.deployment_id, s.received_ns, 503, .fault, console_owned, exception_owned, s.tape_refs);
            processed += 1;
        }
        successes.clearRetainingCapacity();
        return processed;
    };

    const deadline_ns: i64 = @intCast(std.time.nanoTimestamp() + @as(i128, @intCast(worker.commit_wait_timeout_ns)));
    for (successes.items) |*s| {
        try server.reg.set(s.ent, &server.request_out, RaftWait, .{
            .seq = seq,
            .txn_seq = batch_seq,
            .deadline_ns = deadline_ns,
            .store = store,
        });
        try server.reg.move(s.ent, &server.request_out, &worker.raft_pending);

        const console_owned = s.console_owned;
        const exception_owned = s.exception_owned;
        s.console_owned = &.{};
        s.exception_owned = &.{};
        captureLog(worker, anchor_id, s.method, s.path, s.host, s.deployment_id, s.received_ns, s.status_code, .ok, console_owned, exception_owned, s.tape_refs);
        processed += 1;
    }
    successes.clearRetainingCapacity();
    return processed;
}

// ── /_system/files/* proxy ─────────────────────────────────────────────
//
// The worker runs both a server-side h2 (accepting user traffic) and
// a client-side h2 (forwarding to the in-process files-server thread)
// on the same `H2` instance — `H2(.{ .client = true })` makes both
// sets of collections live together. The proxy systems below mirror
// shift-h2's `examples/h2c_proxy.c`:
//
//   1. `connectCodeServer` — if the upstream session is nil and no
//      connect is in flight, create a new connect entity. h2 will
//      populate `client_connect_out` or `client_connect_errors`.
//   2. `ingestCodeConnects` — drain `client_connect_out` (store the
//      session entity on the worker) and `client_connect_errors`
//      (log + rearm connect). Destroy the connect entities.
//   3. `flushCodeProxyPending` — for each server entity in
//      `code_proxy_pending`, if the upstream session is live, build
//      a client request entity with the same method/path/headers/
//      body, stamp a `ProxyPeer.client` cross-ref on the server
//      entity, move to `code_proxy_inflight`.
//   4. `drainCodeProxyResponses` — scan `client_response_out`; for
//      each client entity find its matching server entity in
//      `code_proxy_inflight` via the peer back-reference, copy the
//      upstream status+headers+body onto the server entity, move to
//      `response_in`, destroy the client entity.
//
// Reconnect is driven by (1). Any request arriving during a
// disconnected window stays in `code_proxy_pending` until the new
// session is up — clients observe this as latency, not failure.

/// Ensure each proxy subsystem has a live upstream session (or is
/// establishing one). Called once per poll-loop tick before the
/// other proxy systems.
pub fn connectProxies(worker: anytype) !void {
    try connectOne(worker, &worker.code_proxy, "code");
    try connectOne(worker, &worker.log_proxy, "log");
}

fn connectOne(
    worker: anytype,
    ps: anytype,
    name: []const u8,
) !void {
    const addr = ps.addr orelse return;
    const server = worker.h2;
    const reg = server.reg;

    const session_live = !worker.reg.isStale(ps.session);
    if (session_live or ps.connecting) return;

    const conn = try reg.create(&server.client_connect_in);
    try reg.set(conn, &server.client_connect_in, h2.ConnectTarget, .{ .addr = addr });
    try reg.set(conn, &server.client_connect_in, ProxyTag, ps.tag);
    ps.connecting = true;
    std.log.info("rove-js: connecting to {s} server at {any}", .{ name, addr });
}

/// Drain `client_connect_out` + `client_connect_errors`. Each
/// entity carries a `ProxyTag` set at connect time, which we use
/// to route the new session back to the right subsystem.
pub fn ingestProxyConnects(worker: anytype) !void {
    const server = worker.h2;
    const reg = server.reg;

    {
        const ents = server.client_connect_out.entitySlice();
        // Snapshot because the loop destroys entities.
        const snap = try worker.allocator.dupe(rove.Entity, ents);
        defer worker.allocator.free(snap);

        for (snap) |ent| {
            const sess = try reg.get(ent, &server.client_connect_out, h2.Session);
            const tag = reg.get(ent, &server.client_connect_out, ProxyTag) catch null;
            const kind = if (tag) |t| t.kind else .none;
            switch (kind) {
                .code => {
                    worker.code_proxy.session = sess.entity;
                    worker.code_proxy.connecting = false;
                    std.log.info("rove-js: files-server connected (session={d})", .{sess.entity.index});
                },
                .log => {
                    worker.log_proxy.session = sess.entity;
                    worker.log_proxy.connecting = false;
                    std.log.info("rove-js: log server connected (session={d})", .{sess.entity.index});
                },
                .none => std.log.warn("rove-js: untagged proxy connect succeeded", .{}),
            }
            try reg.destroy(ent);
        }
    }
    {
        const ents = server.client_connect_errors.entitySlice();
        const snap = try worker.allocator.dupe(rove.Entity, ents);
        defer worker.allocator.free(snap);

        for (snap) |ent| {
            const tag = reg.get(ent, &server.client_connect_errors, ProxyTag) catch null;
            const kind = if (tag) |t| t.kind else .none;
            switch (kind) {
                .code => worker.code_proxy.connecting = false,
                .log => worker.log_proxy.connecting = false,
                .none => {},
            }
            const io = reg.get(ent, &server.client_connect_errors, h2.H2IoResult) catch null;
            const err_code: i32 = if (io) |i| i.err else -1;
            std.log.warn("rove-js: {any} proxy connect failed: {d}", .{ kind, err_code });
            try reg.destroy(ent);
        }
    }
}

/// Forward parked proxy requests for every subsystem with a live
/// upstream session.
pub fn flushProxyPending(worker: anytype) !void {
    try flushOne(worker, &worker.code_proxy);
    try flushOne(worker, &worker.log_proxy);
}

fn flushOne(
    worker: anytype,
    ps: anytype,
) !void {
    const server = worker.h2;
    const reg = server.reg;
    const allocator = worker.allocator;

    if (worker.reg.isStale(ps.session)) return;
    const upstream_session = ps.session;

    const entities = ps.pending.entitySlice();
    const snapshot = try allocator.dupe(rove.Entity, entities);
    defer allocator.free(snapshot);

    for (snapshot) |server_ent| {
        const rh = try worker.reg.get(server_ent, &ps.pending, h2.ReqHeaders);
        const rb = try worker.reg.get(server_ent, &ps.pending, h2.ReqBody);

        // Rewrite `:path` by stripping the `/_system/{subsystem}`
        // prefix so the subsystem's routes match. `forwardHeaders`
        // handles this for both subsystems — same rule applies.
        const header_fields = forwardHeaders(allocator, rh.*) catch |err| {
            std.log.warn("rove-js proxy: forwardHeaders failed: {s}", .{@errorName(err)});
            const body = try allocator.dupe(u8, "internal proxy error\n");
            try setProxyFault(server, server_ent, &ps.pending, 500, body, allocator, worker.admin_origin);
            try worker.reg.move(server_ent, &ps.pending, &server.response_in);
            continue;
        };

        var body_copy: ?[*]u8 = null;
        var body_len: u32 = 0;
        if (rb.data != null and rb.len > 0) {
            const buf = try allocator.alloc(u8, rb.len);
            @memcpy(buf, rb.data.?[0..rb.len]);
            body_copy = buf.ptr;
            body_len = rb.len;
        }

        const client_ent = try reg.create(&server.client_request_in);
        try reg.set(client_ent, &server.client_request_in, h2.Session, .{ .entity = upstream_session });
        try reg.set(client_ent, &server.client_request_in, ProxyTag, ps.tag);
        try reg.set(client_ent, &server.client_request_in, h2.ReqHeaders, .{
            .fields = header_fields.ptr,
            .count = @intCast(header_fields.len),
        });
        try reg.set(client_ent, &server.client_request_in, h2.ReqBody, .{
            .data = body_copy,
            .len = body_len,
        });

        try worker.reg.set(server_ent, &ps.pending, ProxyPeer, .{ .client = client_ent });
        try worker.reg.move(server_ent, &ps.pending, &ps.inflight);
    }
}

/// Map upstream responses back onto server-side peers. Uses
/// `ProxyTag` on the client entity to route to the right inflight
/// collection in O(1).
pub fn drainProxyResponses(worker: anytype) !void {
    const server = worker.h2;
    const reg = server.reg;
    const allocator = worker.allocator;

    const client_ents = server.client_response_out.entitySlice();
    if (client_ents.len == 0) return;

    const client_snapshot = try allocator.dupe(rove.Entity, client_ents);
    defer allocator.free(client_snapshot);

    for (client_snapshot) |client_ent| {
        const tag = reg.get(client_ent, &server.client_response_out, ProxyTag) catch null;
        const kind = if (tag) |t| t.kind else .none;

        switch (kind) {
            .code => try mapOneResponse(worker, &worker.code_proxy, client_ent),
            .log => try mapOneResponse(worker, &worker.log_proxy, client_ent),
            .none => {
                std.log.warn("rove-js proxy: untagged upstream response", .{});
                try reg.destroy(client_ent);
            },
        }
    }
}

fn mapOneResponse(
    worker: anytype,
    ps: anytype,
    client_ent: rove.Entity,
) !void {
    const server = worker.h2;
    const reg = server.reg;
    const allocator = worker.allocator;

    const inflight_ents = ps.inflight.entitySlice();
    const peers = ps.inflight.column(ProxyPeer);
    var server_ent: rove.Entity = rove.Entity.nil;
    for (inflight_ents, peers) |cand, p| {
        if (p.client.index == client_ent.index and p.client.generation == client_ent.generation) {
            server_ent = cand;
            break;
        }
    }
    if (server_ent.index == 0 and server_ent.generation == 0) {
        std.log.warn("rove-js proxy: orphan upstream response", .{});
        try reg.destroy(client_ent);
        return;
    }

    const ust = try reg.get(client_ent, &server.client_response_out, h2.Status);
    const urb = try reg.get(client_ent, &server.client_response_out, h2.RespBody);
    const uio = try reg.get(client_ent, &server.client_response_out, h2.H2IoResult);

    if (uio.err != 0) {
        std.log.warn("rove-js proxy: upstream error {d} → 502", .{uio.err});
        const body = try allocator.dupe(u8, "bad gateway\n");
        try setProxyFault(server, server_ent, &ps.inflight, 502, body, allocator, worker.admin_origin);
        try worker.reg.move(server_ent, &ps.inflight, &server.response_in);
        try reg.destroy(client_ent);
        return;
    }

    try worker.reg.set(server_ent, &ps.inflight, h2.Status, .{ .code = ust.code });

    var body_copy: ?[*]u8 = null;
    var body_len: u32 = 0;
    if (urb.data != null and urb.len > 0) {
        const buf = try allocator.alloc(u8, urb.len);
        @memcpy(buf, urb.data.?[0..urb.len]);
        body_copy = buf.ptr;
        body_len = urb.len;
    }
    try worker.reg.set(server_ent, &ps.inflight, h2.RespBody, .{ .data = body_copy, .len = body_len });
    const resp_hdrs: h2.RespHeaders = if (worker.admin_origin) |o|
        try buildSystemRespHeaders(allocator, o, false, null)
    else
        .{ .fields = null, .count = 0 };
    try worker.reg.set(server_ent, &ps.inflight, h2.RespHeaders, resp_hdrs);
    try worker.reg.set(server_ent, &ps.inflight, h2.H2IoResult, .{ .err = 0 });

    try worker.reg.move(server_ent, &ps.inflight, &server.response_in);
    try reg.destroy(client_ent);
}

/// Duplicate the request headers, rewriting `:path` to strip the
/// `/_system/{subsystem}` prefix so downstream subsystem routes
/// (`/{instance_id}/upload`, `/{instance_id}/list`, etc.) match. The
/// prefix is two segments: `/_system` + `/code` or `/log`. We walk
/// past the first two `/`s. `:authority` is left alone — subsystems
/// don't care what host name the caller used. Fields are allocated
/// on `allocator` and owned by the returned slice; rove-h2 frees
/// them when the request finishes.
fn forwardHeaders(
    allocator: std.mem.Allocator,
    rh: h2.ReqHeaders,
) ![]h2.HeaderField {
    if (rh.fields == null or rh.count == 0) return &.{};
    const fields = rh.fields.?[0..rh.count];
    const out = try allocator.alloc(h2.HeaderField, fields.len);
    for (fields, 0..) |f, i| {
        const name = try allocator.alloc(u8, f.name_len);
        @memcpy(name, f.name[0..f.name_len]);

        var value_slice: []const u8 = f.value[0..f.value_len];
        if (f.name_len == 5 and std.mem.eql(u8, name, ":path")) {
            if (std.mem.startsWith(u8, value_slice, "/_system/")) {
                // Find the second '/' after "/_system/" to strip
                // `/{subsystem}` as well.
                const after_sys = value_slice["/_system/".len..];
                if (std.mem.indexOfScalar(u8, after_sys, '/')) |slash| {
                    value_slice = after_sys[slash..];
                    if (value_slice.len == 0) value_slice = "/";
                }
            }
        }

        const value = try allocator.alloc(u8, value_slice.len);
        @memcpy(value, value_slice);
        out[i] = .{
            .name = name.ptr,
            .name_len = f.name_len,
            .value = value.ptr,
            .value_len = @intCast(value_slice.len),
        };
    }
    return out;
}

fn setProxyFault(
    server: anytype,
    ent: rove.Entity,
    src_coll: anytype,
    status: u16,
    body: []u8,
    allocator: std.mem.Allocator,
    cors_origin: ?[]const u8,
) !void {
    try server.reg.set(ent, src_coll, h2.Status, .{ .code = status });
    const resp_hdrs: h2.RespHeaders = if (cors_origin) |o|
        try buildSystemRespHeaders(allocator, o, false, null)
    else
        .{ .fields = null, .count = 0 };
    try server.reg.set(ent, src_coll, h2.RespHeaders, resp_hdrs);
    try server.reg.set(ent, src_coll, h2.RespBody, .{ .data = body.ptr, .len = @intCast(body.len) });
    try server.reg.set(ent, src_coll, h2.H2IoResult, .{ .err = 0 });
}

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
        const rb = resp_bodies[i];

        if (committed >= wait.seq) {
            // Happy path: raft committed, local writes already durable.
            // Drop the per-txn undo row now that the write is proven
            // durable — otherwise it would survive in kv_undo as an
            // "orphan" and get rolled back by the next startup sweep,
            // silently corrupting state.
            if (wait.store) |store| {
                store.commitTxn(wait.txn_seq) catch |err| {
                    std.log.warn(
                        "rove-js drain: commitTxn(txn_seq={d}) failed: {s}",
                        .{ wait.txn_seq, @errorName(err) },
                    );
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
            store.undoTxn(wait.txn_seq) catch |err| {
                std.log.err(
                    "rove-js drain: undoTxn(txn_seq={d}) failed: {s}",
                    .{ wait.txn_seq, @errorName(err) },
                );
            };
        }

        const old_body_ptr: ?[*]u8 = rb.data;
        const old_body_len: u32 = rb.len;
        try overwrite503InPending(worker, ent, allocator);
        if (old_body_ptr) |p| allocator.free(p[0..old_body_len]);

        try server.reg.move(ent, &worker.raft_pending, &server.response_in);
    }
}

/// Encode the writeset + envelope, propose through raft, and return
/// the assigned seq. The caller parks the entity in `raft_pending`
/// with a `RaftWait{seq}` component; `drainRaftPending` then observes
/// `raft.committedSeq()` advancing past the stamp and releases the
/// entity downstream. No spinning here — the h2 poll loop stays hot.
fn proposeWriteSet(
    worker: anytype,
    writeset: *const kv_mod.WriteSet,
    instance_id: []const u8,
) !u64 {
    const allocator = worker.allocator;

    const ws_bytes = try writeset.encode(allocator);
    defer allocator.free(ws_bytes);

    const envelope = try apply_mod.encodeWriteSetEnvelope(allocator, instance_id, ws_bytes);
    defer allocator.free(envelope);

    const seq = worker.raft.highWatermark() + 1;
    try worker.raft.propose(seq, envelope);
    return seq;
}

/// Overwrite an entity in `request_out` with a 503 body. Used when a
/// raft propose fails before the entity gets parked. Frees any body
/// the handler wrote before stamping the new one.
fn overwriteWith503(
    server: anytype,
    ent: rove.Entity,
    allocator: std.mem.Allocator,
    old_body_ptr: ?[*]u8,
    old_body_len: u32,
) !void {
    if (old_body_ptr) |p| allocator.free(p[0..old_body_len]);
    const body = try allocator.dupe(u8, "write replication failed\n");
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = 503 });
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = body.ptr,
        .len = @intCast(body.len),
    });
}

/// Overwrite a parked entity's response with a 503. Caller is
/// responsible for freeing the old body (done in `drainRaftPending`
/// where the column access lives).
fn overwrite503InPending(
    worker: anytype,
    ent: rove.Entity,
    allocator: std.mem.Allocator,
) !void {
    const body = try allocator.dupe(u8, "raft commit failed\n");
    try worker.reg.set(ent, &worker.raft_pending, h2.Status, .{ .code = 503 });
    try worker.reg.set(ent, &worker.raft_pending, h2.RespBody, .{
        .data = body.ptr,
        .len = @intCast(body.len),
    });
}

/// Write a canned `500 Internal Server Error` response onto an entity
/// and queue its move to `response_in`.
fn setErrorResponse(
    server: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
) !void {
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = 500 });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{ .fields = null, .count = 0 });
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = null, .len = 0 });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

/// Build a `RespHeaders` from a mix of CORS + optional content-type,
/// packed into a single allocation compatible with `RespHeaders.deinit`
/// (fields array at the start, followed by name/value bytes — same
/// layout `hdrFinalize` produces in rove-h2).
///
/// - `cors_origin`: when set, stamps `Access-Control-Allow-Origin`
///   + `-Allow-Credentials` + `Vary: origin` + `-Expose-Headers`.
/// - `preflight`: only meaningful with cors_origin; adds `-Allow-
///   Methods`, `-Allow-Headers`, `-Max-Age` for a 204 preflight.
/// - `content_type`: when set, adds a `Content-Type` header.
///
/// Returns an empty `RespHeaders` when everything is null.
fn buildSystemRespHeaders(
    allocator: std.mem.Allocator,
    cors_origin: ?[]const u8,
    preflight: bool,
    content_type: ?[]const u8,
) !h2.RespHeaders {
    const Pair = struct { name: []const u8, value: []const u8 };
    var pairs_buf: [8]Pair = undefined;
    var n: usize = 0;
    if (cors_origin) |o| {
        pairs_buf[n] = .{ .name = "access-control-allow-origin", .value = o };
        n += 1;
        pairs_buf[n] = .{ .name = "access-control-allow-credentials", .value = "true" };
        n += 1;
        pairs_buf[n] = .{ .name = "vary", .value = "origin" };
        n += 1;
        pairs_buf[n] = .{ .name = "access-control-expose-headers", .value = "content-type" };
        n += 1;
        if (preflight) {
            pairs_buf[n] = .{ .name = "access-control-allow-methods", .value = "GET, POST, DELETE, OPTIONS" };
            n += 1;
            pairs_buf[n] = .{ .name = "access-control-allow-headers", .value = "authorization, content-type" };
            n += 1;
            pairs_buf[n] = .{ .name = "access-control-max-age", .value = "600" };
            n += 1;
        }
    }
    if (content_type) |ct| {
        pairs_buf[n] = .{ .name = "content-type", .value = ct };
        n += 1;
    }

    if (n == 0) return .{ .fields = null, .count = 0 };

    const pairs = pairs_buf[0..n];
    const fields_size = n * @sizeOf(h2.HeaderField);
    var strbuf_size: usize = 0;
    for (pairs) |p| strbuf_size += p.name.len + p.value.len;

    const total = fields_size + strbuf_size;
    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);

    const fields_ptr: [*]h2.HeaderField = @ptrCast(@alignCast(buf.ptr));
    var off: usize = fields_size;
    for (pairs, 0..) |p, i| {
        const name_start = off;
        @memcpy(buf[off .. off + p.name.len], p.name);
        off += p.name.len;
        const value_start = off;
        @memcpy(buf[off .. off + p.value.len], p.value);
        off += p.value.len;
        fields_ptr[i] = .{
            .name = buf[name_start..].ptr,
            .name_len = @intCast(p.name.len),
            .value = buf[value_start..].ptr,
            .value_len = @intCast(p.value.len),
        };
    }

    return .{
        .fields = fields_ptr,
        .count = @intCast(n),
        ._buf = buf.ptr,
        ._buf_len = @intCast(buf.len),
    };
}

/// Assemble a handler-response `RespHeaders` carrying optional CORS
/// (admin subdomains only) and a `set-cookie` header per entry in
/// `set_cookies`. Each cookie has already been sanitized by the
/// dispatcher — this function is purely a mechanical packer.
///
/// Returns an empty `RespHeaders` when there's nothing to emit (no
/// CORS, no cookies), saving an allocation on the common
/// same-origin user-traffic path.
fn buildHandlerRespHeaders(
    allocator: std.mem.Allocator,
    cors_origin: ?[]const u8,
    set_cookies: []const []const u8,
) !h2.RespHeaders {
    const cors_fields: usize = if (cors_origin != null) 4 else 0;
    const total_fields = cors_fields + set_cookies.len;
    if (total_fields == 0) return .{ .fields = null, .count = 0 };

    const fields_size = total_fields * @sizeOf(h2.HeaderField);
    var strbuf_size: usize = 0;
    if (cors_origin) |o| {
        strbuf_size += "access-control-allow-origin".len + o.len;
        strbuf_size += "access-control-allow-credentials".len + "true".len;
        strbuf_size += "vary".len + "origin".len;
        strbuf_size += "access-control-expose-headers".len + "content-type".len;
    }
    for (set_cookies) |cookie| strbuf_size += "set-cookie".len + cookie.len;

    const total = fields_size + strbuf_size;
    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);

    const fields_ptr: [*]h2.HeaderField = @ptrCast(@alignCast(buf.ptr));
    var off: usize = fields_size;
    var i: usize = 0;

    const writePair = struct {
        fn call(
            b: []u8,
            off_p: *usize,
            fp: [*]h2.HeaderField,
            idx: *usize,
            name: []const u8,
            value: []const u8,
        ) void {
            const name_start = off_p.*;
            @memcpy(b[off_p.* .. off_p.* + name.len], name);
            off_p.* += name.len;
            const value_start = off_p.*;
            @memcpy(b[off_p.* .. off_p.* + value.len], value);
            off_p.* += value.len;
            fp[idx.*] = .{
                .name = b[name_start..].ptr,
                .name_len = @intCast(name.len),
                .value = b[value_start..].ptr,
                .value_len = @intCast(value.len),
            };
            idx.* += 1;
        }
    }.call;

    if (cors_origin) |o| {
        writePair(buf, &off, fields_ptr, &i, "access-control-allow-origin", o);
        writePair(buf, &off, fields_ptr, &i, "access-control-allow-credentials", "true");
        writePair(buf, &off, fields_ptr, &i, "vary", "origin");
        writePair(buf, &off, fields_ptr, &i, "access-control-expose-headers", "content-type");
    }
    for (set_cookies) |cookie| {
        writePair(buf, &off, fields_ptr, &i, "set-cookie", cookie);
    }

    return .{
        .fields = fields_ptr,
        .count = @intCast(total_fields),
        ._buf = buf.ptr,
        ._buf_len = @intCast(buf.len),
    };
}

// ── Static dispatch ────────────────────────────────────────────────────

/// Result of a static-file lookup/serve attempt. `miss` means the
/// caller should fall through to handler routing.
pub const StaticOutcome = union(enum) {
    served: u16,
    miss: void,
};

/// Try to serve `path` from the tenant's `_static/*` set. Returns the
/// status code if we took the response (200, 304, or 301 for trailing-
/// slash canonicalization) or `.miss` when nothing matched. Only called
/// on `GET`; the caller enforces the method gate.
fn tryServeStatic(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tc: *TenantFiles,
    path: []const u8,
    rh: h2.ReqHeaders,
) !StaticOutcome {
    const qmark = std.mem.indexOfScalar(u8, path, '?');
    const path_no_q = if (qmark) |q| path[0..q] else path;
    if (path_no_q.len == 0 or path_no_q[0] != '/') return .miss;

    // Trailing-slash canonicalization: redirect `/foo/` → `/foo` (not
    // `/` itself). Only on GET, by design, so API clients using
    // trailing-slash conventions on POST aren't surprised.
    if (path_no_q.len > 1 and path_no_q[path_no_q.len - 1] == '/') {
        var canon_buf: [files_mod.MAX_PATH_LEN + 16]u8 = undefined;
        var stripped: []const u8 = path_no_q;
        while (stripped.len > 1 and stripped[stripped.len - 1] == '/') {
            stripped = stripped[0 .. stripped.len - 1];
        }
        // Preserve the original query string on the redirect target.
        const loc = if (qmark) |q|
            std.fmt.bufPrint(&canon_buf, "{s}?{s}", .{ stripped, path[q + 1 ..] }) catch return .miss
        else
            stripped;
        try emitStaticRedirect(server, allocator, ent, sid, sess, loc);
        return .{ .served = 301 };
    }

    const rel = path_no_q[1..];

    var key_buf: [8 + files_mod.MAX_PATH_LEN + 16]u8 = undefined;
    if (rel.len == 0) {
        const key = std.fmt.bufPrint(&key_buf, "_static/index.html", .{}) catch return .miss;
        if (try serveStaticByKey(server, allocator, ent, sid, sess, tc, key, rh)) |st| {
            return .{ .served = st };
        }
        return .miss;
    }

    // Exact match: `_static/<rel>`.
    if (std.fmt.bufPrint(&key_buf, "_static/{s}", .{rel})) |k| {
        if (try serveStaticByKey(server, allocator, ent, sid, sess, tc, k, rh)) |st| {
            return .{ .served = st };
        }
    } else |_| {}

    // `.html` suffix: `_static/<rel>.html`.
    if (std.fmt.bufPrint(&key_buf, "_static/{s}.html", .{rel})) |k| {
        if (try serveStaticByKey(server, allocator, ent, sid, sess, tc, k, rh)) |st| {
            return .{ .served = st };
        }
    } else |_| {}

    // Directory index: `_static/<rel>/index.html`.
    if (std.fmt.bufPrint(&key_buf, "_static/{s}/index.html", .{rel})) |k| {
        if (try serveStaticByKey(server, allocator, ent, sid, sess, tc, k, rh)) |st| {
            return .{ .served = st };
        }
    } else |_| {}

    return .miss;
}

/// Return the status code if `key` is present and we wrote a response,
/// or null if the key isn't in the static map.
fn serveStaticByKey(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tc: *TenantFiles,
    key: []const u8,
    rh: h2.ReqHeaders,
) !?u16 {
    const entry = tc.statics.get(key) orelse return null;

    // Build the strong ETag value (`"<hex>"`) once; shared by 200 and 304.
    var etag_buf: [files_mod.HASH_HEX_LEN + 2]u8 = undefined;
    etag_buf[0] = '"';
    @memcpy(etag_buf[1 .. 1 + files_mod.HASH_HEX_LEN], &entry.hash_hex);
    etag_buf[1 + files_mod.HASH_HEX_LEN] = '"';
    const etag = etag_buf[0..];

    // If-None-Match: a comma-separated list of quoted tags (or `*`).
    // Match = any one of them equals our etag.
    const inm = findHeader(rh, "if-none-match");
    if (inm != null and etagMatches(inm.?, etag)) {
        try emitStaticResponse(
            server,
            allocator,
            ent,
            sid,
            sess,
            304,
            "",
            "",
            etag,
        );
        return 304;
    }

    const bytes = tc.blob_backend.blobStore().get(&entry.hash_hex, allocator) catch |err| {
        std.log.warn(
            "rove-js: static blob fetch for {s} failed: {s}",
            .{ key, @errorName(err) },
        );
        return err;
    };
    try emitStaticResponse(
        server,
        allocator,
        ent,
        sid,
        sess,
        200,
        bytes,
        entry.content_type,
        etag,
    );
    return 200;
}

/// True if `inm` (If-None-Match header value) contains a tag equal to
/// `etag`. Handles comma-separated lists and the `*` wildcard.
fn etagMatches(inm: []const u8, etag: []const u8) bool {
    var rest = inm;
    while (rest.len > 0) {
        while (rest.len > 0 and (rest[0] == ' ' or rest[0] == ',' or rest[0] == '\t')) {
            rest = rest[1..];
        }
        if (rest.len == 0) break;
        if (rest[0] == '*') return true;
        // Find the next comma or end.
        const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
        var tag = rest[0..end];
        // Trim trailing whitespace.
        while (tag.len > 0 and (tag[tag.len - 1] == ' ' or tag[tag.len - 1] == '\t')) {
            tag = tag[0 .. tag.len - 1];
        }
        // Strip a weak prefix (`W/`) if present — for static we only
        // emit strong tags, but a client may be comparing weakly.
        if (tag.len >= 2 and tag[0] == 'W' and tag[1] == '/') tag = tag[2..];
        if (std.mem.eql(u8, tag, etag)) return true;
        rest = rest[end..];
        if (rest.len > 0) rest = rest[1..]; // skip the comma
    }
    return false;
}

/// Write a 200/304 static response. Body is duped into the response
/// entity (so caller's `bytes` can be freed by its allocator immediately
/// after). Passes an empty body for 304.
fn emitStaticResponse(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status_code: u16,
    body: []const u8,
    content_type: []const u8,
    etag: []const u8,
) !void {
    const hdrs = try buildStaticRespHeaders(allocator, content_type, etag);
    var body_ptr: ?[*]u8 = null;
    var body_len: u32 = 0;
    if (body.len > 0) {
        const copy = try allocator.dupe(u8, body);
        body_ptr = copy.ptr;
        body_len = @intCast(copy.len);
    }

    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status_code });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, hdrs);
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = body_ptr,
        .len = body_len,
    });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

fn buildStaticRespHeaders(
    allocator: std.mem.Allocator,
    content_type: []const u8,
    etag: []const u8,
) !h2.RespHeaders {
    const Pair = struct { name: []const u8, value: []const u8 };
    var pairs: [3]Pair = undefined;
    var n: usize = 0;
    if (content_type.len > 0) {
        pairs[n] = .{ .name = "content-type", .value = content_type };
        n += 1;
    }
    pairs[n] = .{ .name = "etag", .value = etag };
    n += 1;
    pairs[n] = .{ .name = "cache-control", .value = "public, max-age=0, must-revalidate" };
    n += 1;

    const fields_size = n * @sizeOf(h2.HeaderField);
    var strbuf_size: usize = 0;
    for (pairs[0..n]) |p| strbuf_size += p.name.len + p.value.len;

    const buf = try allocator.alloc(u8, fields_size + strbuf_size);
    errdefer allocator.free(buf);

    const fields_ptr: [*]h2.HeaderField = @ptrCast(@alignCast(buf.ptr));
    var off: usize = fields_size;
    for (pairs[0..n], 0..) |p, i| {
        const name_start = off;
        @memcpy(buf[off .. off + p.name.len], p.name);
        off += p.name.len;
        const value_start = off;
        @memcpy(buf[off .. off + p.value.len], p.value);
        off += p.value.len;
        fields_ptr[i] = .{
            .name = buf[name_start..].ptr,
            .name_len = @intCast(p.name.len),
            .value = buf[value_start..].ptr,
            .value_len = @intCast(p.value.len),
        };
    }

    return .{
        .fields = fields_ptr,
        .count = @intCast(n),
        ._buf = buf.ptr,
        ._buf_len = @intCast(buf.len),
    };
}

/// If the tenant has `_static/_404.html`, emit it as a 404 response
/// with its stored content-type (no ETag — error bodies shouldn't be
/// cached). Returns `true` when served, `false` when there's no such
/// static so the caller can fall back to the built-in text body.
fn serveConvention404(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tc: *TenantFiles,
) !bool {
    const entry = tc.statics.get("_static/_404.html") orelse return false;
    const bytes = tc.blob_backend.blobStore().get(&entry.hash_hex, allocator) catch |err| {
        std.log.warn("rove-js: _404.html blob fetch failed: {s}", .{@errorName(err)});
        return false;
    };

    // Minimal header set — just the content-type. No caching hints for
    // error responses.
    const Pair = struct { name: []const u8, value: []const u8 };
    var pairs: [1]Pair = undefined;
    var n: usize = 0;
    if (entry.content_type.len > 0) {
        pairs[n] = .{ .name = "content-type", .value = entry.content_type };
        n += 1;
    }
    const hdrs: h2.RespHeaders = if (n == 0)
        .{ .fields = null, .count = 0 }
    else blk: {
        const fields_size = n * @sizeOf(h2.HeaderField);
        var strbuf_size: usize = 0;
        for (pairs[0..n]) |p| strbuf_size += p.name.len + p.value.len;
        const buf = try allocator.alloc(u8, fields_size + strbuf_size);
        const fields_ptr: [*]h2.HeaderField = @ptrCast(@alignCast(buf.ptr));
        var off: usize = fields_size;
        for (pairs[0..n], 0..) |p, i| {
            const name_start = off;
            @memcpy(buf[off .. off + p.name.len], p.name);
            off += p.name.len;
            const value_start = off;
            @memcpy(buf[off .. off + p.value.len], p.value);
            off += p.value.len;
            fields_ptr[i] = .{
                .name = buf[name_start..].ptr,
                .name_len = @intCast(p.name.len),
                .value = buf[value_start..].ptr,
                .value_len = @intCast(p.value.len),
            };
        }
        break :blk .{
            .fields = fields_ptr,
            .count = @intCast(n),
            ._buf = buf.ptr,
            ._buf_len = @intCast(buf.len),
        };
    };

    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = 404 });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, hdrs);
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = bytes.ptr,
        .len = @intCast(bytes.len),
    });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
    return true;
}

/// Write a 301 redirect response. `location` is duped into the response
/// header buffer so the caller doesn't need to keep it alive.
fn emitStaticRedirect(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    location: []const u8,
) !void {
    const fields_size = @sizeOf(h2.HeaderField);
    const name_len: usize = "location".len;
    const buf = try allocator.alloc(u8, fields_size + name_len + location.len);
    errdefer allocator.free(buf);

    const fields_ptr: [*]h2.HeaderField = @ptrCast(@alignCast(buf.ptr));
    @memcpy(buf[fields_size .. fields_size + name_len], "location");
    @memcpy(buf[fields_size + name_len ..][0..location.len], location);
    fields_ptr[0] = .{
        .name = buf[fields_size..].ptr,
        .name_len = @intCast(name_len),
        .value = buf[fields_size + name_len ..].ptr,
        .value_len = @intCast(location.len),
    };

    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = 301 });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{
        .fields = fields_ptr,
        .count = 1,
        ._buf = buf.ptr,
        ._buf_len = @intCast(buf.len),
    });
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = null, .len = 0 });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

/// Like `setSimpleResponse`, but stamps CORS response headers when
/// `cors_origin` is non-null and an optional `Content-Type`. Use in
/// the `/_system/*` branch so admin UI responses carry the right
/// headers without the caller hand-assembling `RespHeaders`.
fn setSystemResponse(
    server: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status_code: u16,
    body: []const u8,
    allocator: std.mem.Allocator,
    cors_origin: ?[]const u8,
    content_type: ?[]const u8,
) !void {
    const copy = try allocator.dupe(u8, body);
    const resp_hdrs = try buildSystemRespHeaders(allocator, cors_origin, false, content_type);
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status_code });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, resp_hdrs);
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = copy.ptr,
        .len = @intCast(copy.len),
    });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

/// Write a canned status + body response, allocating an h2-owned copy
/// of `body`.
fn setSimpleResponse(
    server: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status_code: u16,
    body: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const copy = try allocator.dupe(u8, body);
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status_code });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{ .fields = null, .count = 0 });
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = copy.ptr,
        .len = @intCast(copy.len),
    });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

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

fn hostOnly(authority: []const u8) []const u8 {
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
fn findBytecode(
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

/// Match `host` against the admin API domain pattern. Returns:
///   - `null`            — host is not an admin request
///   - `""`              — host is exactly `pattern` (bare admin API)
///   - `"acme"`          — host is `acme.{pattern}` (scope = acme)
/// `host` is the hostname without any port (see `hostOnly`). Matching
/// is case-sensitive; Hosts on the wire are already lower-cased by
/// HTTP/2 header rules.
fn matchAdminSubdomain(host: []const u8, pattern: []const u8) ?[]const u8 {
    if (pattern.len == 0) return null;
    if (std.mem.eql(u8, host, pattern)) return "";
    if (host.len <= pattern.len + 1) return null;
    const dot_before = host.len - pattern.len - 1;
    if (host[dot_before] != '.') return null;
    if (!std.mem.eql(u8, host[dot_before + 1 ..], pattern)) return null;
    return host[0..dot_before];
}

test "matchAdminSubdomain" {
    try std.testing.expectEqual(@as(?[]const u8, null), matchAdminSubdomain("acme.test", "api.loop46.com"));
    try std.testing.expectEqualStrings("", matchAdminSubdomain("api.loop46.com", "api.loop46.com").?);
    try std.testing.expectEqualStrings("acme", matchAdminSubdomain("acme.api.loop46.com", "api.loop46.com").?);
    try std.testing.expectEqualStrings("__admin__", matchAdminSubdomain("__admin__.api.loop46.com", "api.loop46.com").?);
    // Non-match: wrong suffix.
    try std.testing.expectEqual(@as(?[]const u8, null), matchAdminSubdomain("acme.api.other.com", "api.loop46.com"));
    // Non-match: empty pattern guards.
    try std.testing.expectEqual(@as(?[]const u8, null), matchAdminSubdomain("anything", ""));
}

fn findHeader(hdrs: h2.ReqHeaders, name: []const u8) ?[]const u8 {
    if (hdrs.fields == null) return null;
    const fields = hdrs.fields.?[0..hdrs.count];
    for (fields) |f| {
        const fname = f.name[0..f.name_len];
        if (std.mem.eql(u8, fname, name)) {
            return f.value[0..f.value_len];
        }
    }
    return null;
}

/// Extract the bearer token from the `authorization` header.
/// Returns null if the header is absent, the scheme isn't `Bearer`,
/// or the token is empty. Header name is lowercase per HTTP/2 rules.
fn extractBearerToken(hdrs: h2.ReqHeaders) ?[]const u8 {
    const value = findHeader(hdrs, "authorization") orelse return null;
    const prefix = "Bearer ";
    if (value.len <= prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix)) return null;
    const token = value[prefix.len..];
    if (token.len == 0) return null;
    return token;
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

    var tenant = try tenant_mod.Tenant.init(allocator, root_kv, tmp_dir);
    defer tenant.deinit();

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
    const FakeWorker = struct { allocator: std.mem.Allocator };
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

    var tenant = try tenant_mod.Tenant.init(allocator, root_kv, tmp_dir);
    defer tenant.deinit();

    try tenant.createInstance("acme");
    const inst = tenant.instances.get("acme").?;

    {
        var txn = try inst.kv.beginTrackedImmediate();
        try txn.put("durable-key", "durable-value");
        try txn.commit();
        try inst.kv.commitTxn(txn.txn_seq); // happy-path GC
    }

    // Worker startup runs the sweep; should NOT touch durable-key.
    const FakeWorker = struct { allocator: std.mem.Allocator };
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

    var tenant = try tenant_mod.Tenant.init(allocator, root_kv, tmp_dir);
    defer tenant.deinit();

    try tenant.createInstance("acme");
    const inst = tenant.instances.get("acme").?;

    // Construct a TenantLog directly (no Worker involved).
    const tl_dir = try std.fmt.allocPrint(allocator, "{s}/log-test", .{tmp_dir});
    defer allocator.free(tl_dir);

    const FakeWorker = struct {
        allocator: std.mem.Allocator,
        tenant_logs: std.StringHashMapUnmanaged(*TenantLog),
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

test "etagMatches: single tag" {
    try std.testing.expect(etagMatches("\"abc\"", "\"abc\""));
    try std.testing.expect(!etagMatches("\"abc\"", "\"xyz\""));
}

test "etagMatches: weak prefix stripped" {
    try std.testing.expect(etagMatches("W/\"abc\"", "\"abc\""));
}

test "etagMatches: comma list" {
    try std.testing.expect(etagMatches("\"xyz\", \"abc\", \"qqq\"", "\"abc\""));
    try std.testing.expect(!etagMatches("\"xyz\", \"qqq\"", "\"abc\""));
}

test "etagMatches: wildcard" {
    try std.testing.expect(etagMatches("*", "\"anything\""));
    try std.testing.expect(etagMatches("\"a\", *", "\"b\""));
}

test "etagMatches: empty or whitespace only" {
    try std.testing.expect(!etagMatches("", "\"abc\""));
    try std.testing.expect(!etagMatches("   ", "\"abc\""));
}
