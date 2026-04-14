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
//! source from a code-server, route tables, and per-route bytecode
//! caching land once the worker's code-client is designed alongside
//! the code-server's HTTP/2 surface.
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
const code_mod = @import("rove-code");
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

/// Default interval between deployment refresh checks. Each tick the
/// worker may check one tenant's `deployment/current` to see if it
/// advanced and reload the handler bytecode if so.
pub const DEFAULT_REFRESH_INTERVAL_NS: i64 = 2 * std.time.ns_per_s;

/// Per-tenant code state held by the worker. Owns its own KvStore,
/// BlobStore, and cached bytecode for the tenant's active handler.
/// Refreshed periodically via `refreshDeployments` when the tenant's
/// `deployment/current` advances.
pub const TenantCode = struct {
    allocator: std.mem.Allocator,
    /// Owned copy of the instance id. Used as the key in the worker's
    /// `tenant_codes` map; owning it here keeps that map's lifetime
    /// self-contained.
    instance_id: []u8,
    /// Owned tenant code index (SQLite at `{inst.dir}/code.db`).
    code_kv: *kv_mod.KvStore,
    /// Owned blob backend at `{inst.dir}/code-blobs/`.
    blob_backend: blob_mod.FilesystemBlobStore,
    /// rove-code wrapper over `code_kv` + `blob_backend`. Compile hook
    /// is a stub — the worker only reads, never uploads.
    store: code_mod.CodeStore,
    /// Deployment id we last loaded. `0` = no deployment observed yet.
    current_deployment_id: u64,
    /// All handler bytecodes from the active deployment, keyed by the
    /// full deployment path (e.g. `"index.js"`, `"api/users/index.js"`).
    /// Both keys and values are owned by `allocator`. The worker
    /// request router picks which key to look up per request; an
    /// empty map means no deployment has been loaded yet, and every
    /// request hitting this tenant returns 503 until one lands.
    bytecodes: std.StringHashMapUnmanaged([]u8),
    /// When the next refresh check is allowed (absolute
    /// `std.time.nanoTimestamp()`). `refreshDeployments` skips tenants
    /// whose deadline hasn't passed yet so we don't hammer the code
    /// store on every tick.
    next_refresh_ns: i64,
};

/// Worker never uploads code, so the `CompileFn` it passes into
/// `CodeStore.init` just errors out — making accidental put-source
/// calls impossible to ignore.
fn stubCompile(
    _: ?*anyopaque,
    _: []const u8,
    _: [:0]const u8,
    _: std.mem.Allocator,
) anyerror![]u8 {
    return error.CompileNotSupportedOnWorker;
}

/// Per-tenant log state held by the worker. Mirrors `TenantCode`'s
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
    /// Address of the in-process rove-code-server thread. When set,
    /// the worker opens an HTTP/2 client connection at startup and
    /// proxies any request whose path starts with `/_system/code/`
    /// to this address. When null, `/_system/code/*` requests return
    /// 503 (feature disabled).
    code_addr: ?std.net.Address = null,
};

/// Cross-reference component used by the `/_system/code/*` proxy.
/// Lives on server-side entities parked in `code_proxy_inflight`; the
/// `client` field points at the client-side entity that was submitted
/// into rove-h2's `client_request_in`. On each tick we scan
/// `client_response_out`, match each client entity back to its server
/// peer via this field, and copy the upstream response onto the
/// server entity before delivering it to the downstream user.
pub const ProxyPeer = struct { client: rove.Entity };

pub fn Worker(comptime opts: Options) type {
    // rove-js contributes `RaftWait` to every request entity so we can
    // park entities in `raft_pending` without allocating side state.
    // Also `ProxyPeer` so `/_system/code/*` requests can carry the
    // cross-reference to their in-flight upstream client entity
    // through the parking collections.
    const merged_request_row = rove.Row(&.{ RaftWait, ProxyPeer }).merge(opts.request_row);

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
        /// Server-side entities whose path started with `/_system/code/`
        /// and which haven't yet been forwarded to the code thread.
        /// Live here from dispatchPending exit until the proxy layer's
        /// flush system submits the corresponding client request.
        code_proxy_pending: StreamColl,
        /// Forwarded to the code thread, waiting for the upstream
        /// response to land in rove-h2's `client_response_out`. Each
        /// entity here carries a valid `ProxyPeer.client` pointing at
        /// the in-flight client-side entity.
        code_proxy_inflight: StreamColl,
        /// Session handle for the current connection to the code
        /// thread. Nil until `_client_connect_out` fires for the
        /// first time; then rewritten each reconnect. The proxy's
        /// flush system checks `isStale` before forwarding so a
        /// disconnected upstream doesn't send requests into the void.
        code_session: rove.Entity = rove.Entity.nil,
        /// Connect target for the code thread, held so the reconnect
        /// system can re-issue a connect without needing the caller's
        /// original address. Populated from `WorkerConfig.code_addr`.
        code_addr: ?std.net.Address = null,
        /// True while a connect entity is live in h2's connect
        /// pipeline so we don't stack up redundant attempts.
        code_connecting: bool = false,
        dispatcher: Dispatcher,
        tenant: *tenant_mod.Tenant,
        raft: *kv_mod.RaftNode,
        /// Per-tenant code state. Keyed by instance id (the string the
        /// `TenantCode` owns internally — the map slot's key points at
        /// that allocation, so lifetimes line up).
        tenant_codes: std.StringHashMapUnmanaged(*TenantCode),
        /// Per-tenant log state. Same lifetime + key-stability story
        /// as `tenant_codes`. Opened eagerly alongside it. The worker's
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

        /// Heap-allocate a worker, construct the inner `H2` (which in
        /// turn constructs its own `Io`), and eagerly open a
        /// `TenantCode` for every instance currently registered with
        /// the tenant. Tenants that have no deployment yet get a
        /// `TenantCode` with `handler_bytecode = null` — requests
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
                .code_proxy_pending = try StreamColl.init(allocator),
                .code_proxy_inflight = try StreamColl.init(allocator),
                .code_addr = config.code_addr,
                .dispatcher = Dispatcher.init(allocator),
                .tenant = config.tenant,
                .raft = config.raft,
                .tenant_codes = .empty,
                .tenant_logs = .empty,
                .penalty_box = penalty_mod.PenaltyBox.init(allocator, .{}),
                .commit_wait_timeout_ns = config.commit_wait_timeout_ns,
                .refresh_interval_ns = config.refresh_interval_ns,
            };
            errdefer self.raft_pending.deinit();
            errdefer self.code_proxy_pending.deinit();
            errdefer self.code_proxy_inflight.deinit();
            errdefer destroyAllTenantCodes(self);
            errdefer destroyAllTenantLogs(self);

            reg.registerCollection(&self.raft_pending);
            reg.registerCollection(&self.code_proxy_pending);
            reg.registerCollection(&self.code_proxy_inflight);

            // Eagerly open code AND log state for every known tenant.
            // The tenant registry's instances map was populated by
            // the caller before this create() call; we iterate it
            // once and open both per-tenant stores.
            const worker_id: u16 = @intCast(config.raft.config.node_id);
            var it = config.tenant.instances.iterator();
            while (it.next()) |entry| {
                const inst = entry.value_ptr.*;
                const tc = try openTenantCode(self, inst);
                try self.tenant_codes.put(self.allocator, tc.instance_id, tc);
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
            destroyAllTenantCodes(self);
            self.tenant_codes.deinit(allocator);
            self.code_proxy_inflight.deinit();
            self.code_proxy_pending.deinit();
            self.raft_pending.deinit();
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

        /// Function-pointer lookup that `apply.ApplyCtx.log_lookup`
        /// can call back into. The caller passes a `*Self` as the
        /// opaque ctx (set up via `apply_ctx.log_lookup_ctx = worker`).
        /// We cast it back here and resolve the tenant id to the
        /// per-tenant LogStore. Returns null if the tenant has no log
        /// state — the apply callback then drops the batch with a
        /// warning.
        pub fn logLookup(ctx: ?*anyopaque, instance_id: []const u8) ?*log_mod.LogStore {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            const tl = self.tenant_logs.get(instance_id) orelse return null;
            return &tl.store;
        }
    };
}

// ── Per-tenant code loading ───────────────────────────────────────────
//
// These helpers open a tenant's code store (`{inst.dir}/code.db` +
// `{inst.dir}/code-blobs/`) and load the active handler bytecode.
// Called eagerly during `Worker.create` for every registered instance,
// and by `refreshDeployments` when a tenant's `deployment/current`
// advances.

/// Open (or re-use) a tenant code state. Allocates a `*TenantCode`
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
fn openTenantCode(worker: anytype, inst: *const tenant_mod.Instance) !*TenantCode {
    const allocator = worker.allocator;

    // Startup orphan sweep on the tenant's APP store. This belongs
    // here (not in rove-tenant) because it's specifically about the
    // raft-vs-local-commit durability pattern that rove-js drives —
    // rove-tenant just opens the store. A future code-server or
    // log-server with its own durability layer would run its own
    // sweep against its own stores.
    inst.kv.recoverOrphans(0) catch |err| {
        std.log.warn(
            "rove-js: recoverOrphans({s}) failed: {s}",
            .{ inst.id, @errorName(err) },
        );
    };

    const code_db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/code.db",
        .{inst.dir},
        0,
    );
    defer allocator.free(code_db_path);

    const code_blob_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/code-blobs",
        .{inst.dir},
    );
    defer allocator.free(code_blob_dir);

    const code_kv = try kv_mod.KvStore.open(allocator, code_db_path);
    errdefer code_kv.close();

    var blob_backend = try blob_mod.FilesystemBlobStore.open(allocator, code_blob_dir);
    errdefer blob_backend.deinit();

    const id_copy = try allocator.dupe(u8, inst.id);
    errdefer allocator.free(id_copy);

    const tc = try allocator.create(TenantCode);
    errdefer allocator.destroy(tc);
    tc.* = .{
        .allocator = allocator,
        .instance_id = id_copy,
        .code_kv = code_kv,
        .blob_backend = blob_backend,
        .store = undefined, // filled after we have a stable `tc` pointer
        .current_deployment_id = 0,
        .bytecodes = .empty,
        .next_refresh_ns = 0,
    };
    tc.store = code_mod.CodeStore.init(
        allocator,
        tc.code_kv,
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

fn freeTenantCode(allocator: std.mem.Allocator, tc: *TenantCode) void {
    freeBytecodes(tc);
    tc.blob_backend.deinit();
    tc.code_kv.close();
    allocator.free(tc.instance_id);
    allocator.destroy(tc);
}

fn destroyAllTenantCodes(worker: anytype) void {
    var it = worker.tenant_codes.iterator();
    while (it.next()) |entry| freeTenantCode(worker.allocator, entry.value_ptr.*);
    worker.tenant_codes.clearRetainingCapacity();
}

// ── Per-tenant log loading ────────────────────────────────────────────
//
// Mirrors the TenantCode helpers above. Each tenant gets a `log.db` +
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
fn freeBytecodes(tc: *TenantCode) void {
    var it = tc.bytecodes.iterator();
    while (it.next()) |e| {
        tc.allocator.free(e.key_ptr.*);
        tc.allocator.free(e.value_ptr.*);
    }
    tc.bytecodes.deinit(tc.allocator);
    tc.bytecodes = .empty;
}

/// Read the tenant's current deployment manifest, fetch every entry's
/// bytecode blob, and atomically swap the tenant's `bytecodes` map.
/// Returns `error.NoDeployment` if no deploy has been made yet — soft
/// failure the caller treats as "leave the map empty".
fn reloadAllBytecodes(tc: *TenantCode) !void {
    var manifest = tc.store.loadCurrentDeployment() catch |err| switch (err) {
        error.NotFound => return error.NoDeployment,
        else => return err,
    };
    defer manifest.deinit();

    const bs = tc.blob_backend.blobStore();

    // Build the new map in a local before swapping, so if any fetch
    // fails mid-way the tenant keeps serving the old deployment.
    var next: std.StringHashMapUnmanaged([]u8) = .empty;
    errdefer {
        var it = next.iterator();
        while (it.next()) |e| {
            tc.allocator.free(e.key_ptr.*);
            tc.allocator.free(e.value_ptr.*);
        }
        next.deinit(tc.allocator);
    }

    for (manifest.entries) |entry| {
        const path_copy = try tc.allocator.dupe(u8, entry.path);
        errdefer tc.allocator.free(path_copy);
        const bytecode = try bs.get(&entry.bytecode_hex, tc.allocator);
        errdefer tc.allocator.free(bytecode);
        try next.put(tc.allocator, path_copy, bytecode);
    }

    // Swap.
    freeBytecodes(tc);
    tc.bytecodes = next;
    tc.current_deployment_id = manifest.id;

    std.log.info(
        "rove-js: tenant {s} loaded deployment {d} ({d} file(s))",
        .{ tc.instance_id, manifest.id, manifest.entries.len },
    );
}

/// Check each tenant's `deployment/current`; if it advanced since the
/// last observed id, reload the handler bytecode. Respects per-tenant
/// `next_refresh_ns` deadlines so we don't hammer the store on every
/// tick. Called from the main poll loop alongside `dispatchPending`.
pub fn refreshDeployments(worker: anytype) !void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    var it = worker.tenant_codes.iterator();
    while (it.next()) |entry| {
        const tc = entry.value_ptr.*;
        if (now_ns < tc.next_refresh_ns) continue;
        tc.next_refresh_ns = now_ns + worker.refresh_interval_ns;

        // Peek at deployment/current without loading the full manifest —
        // if the id hasn't changed we skip the work.
        const cur_bytes = tc.code_kv.get("deployment/current") catch |err| switch (err) {
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
// `dispatchPending` is a plain function because systems in rove are
// pure: they iterate one collection, queue deferred ops, and return.
// The caller owns the flush boundary. This mirrors the shape of
// `processRequests` in `examples/h2_echo_server.zig`.

/// Iterate `request_out`, run the handler for each pending request,
/// stamp the response components onto the entity, and either (a) move
/// it straight to `response_in` (no writes — nothing to replicate) or
/// (b) propose the writeset through raft and park the entity in
/// `raft_pending` with a `RaftWait` component. The caller must follow
/// this with a `reg.flush()`. Per-tick companion: `drainRaftPending`.
pub fn dispatchPending(worker: anytype) !void {
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
    // client retries against the leader. This keeps logs clean
    // (only the leader generates log records, and it can replicate
    // them through raft to every node), avoids split-brain on reads,
    // and matches the locked-in "no follower-originated logs" rule.
    const is_leader = worker.raft.isLeader();

    for (entities, sids, sessions, req_hdrs, req_bodies) |ent, sid, sess, rh, rb| {
        if (!is_leader) {
            try setSimpleResponse(server, ent, sid, sess, 503, "not leader; retry against the cluster leader\n", allocator);
            continue;
        }

        // Captured at the top of the iteration so duration_ns reflects
        // total time-in-worker, not just handler time.
        const received_ns: i64 = @intCast(std.time.nanoTimestamp());

        const method = findHeader(rh, ":method") orelse "GET";
        const path = findHeader(rh, ":path") orelse "/";
        const authority = findHeader(rh, ":authority") orelse "";
        const body: []const u8 = if (rb.data) |p| p[0..rb.len] else "";

        // `/_system/*` is reserved for the infrastructure plane.
        // Neither tenant resolution nor the JS dispatcher ever sees
        // these paths — they get parked for proxying to the
        // appropriate in-process subsystem after auth passes.
        // Handlers cannot emit `/_system/` URLs to the router,
        // cannot resolve a domain to them, and cannot even observe
        // that they exist.
        if (std.mem.startsWith(u8, path, "/_system/")) {
            // Auth gate — required for every system endpoint.
            const token = extractBearerToken(rh) orelse {
                try setSimpleResponse(server, ent, sid, sess, 401, "missing bearer token\n", allocator);
                continue;
            };
            const auth_ctx = worker.tenant.authenticate(token) catch |err| {
                std.log.warn("rove-js: authenticate failed: {s}", .{@errorName(err)});
                try setSimpleResponse(server, ent, sid, sess, 500, "auth check failed\n", allocator);
                continue;
            };
            if (auth_ctx == null) {
                try setSimpleResponse(server, ent, sid, sess, 401, "invalid bearer token\n", allocator);
                continue;
            }

            // Parse out the instance id from the path so we can check
            // tenant-level access. All system paths share the shape
            // `/_system/{subsystem}/{instance_id}/{rest}`.
            const sys_rest = path["/_system/".len..];
            const sub_slash = std.mem.indexOfScalar(u8, sys_rest, '/') orelse {
                try setSimpleResponse(server, ent, sid, sess, 404, "malformed system path\n", allocator);
                continue;
            };
            const subsystem = sys_rest[0..sub_slash];
            const after_sub = sys_rest[sub_slash + 1 ..];
            const inst_slash = std.mem.indexOfScalar(u8, after_sub, '/');
            const sys_instance_id = if (inst_slash) |s| after_sub[0..s] else after_sub;
            if (sys_instance_id.len == 0) {
                try setSimpleResponse(server, ent, sid, sess, 404, "missing instance id\n", allocator);
                continue;
            }
            const allowed = worker.tenant.canAccessInstance(auth_ctx.?, sys_instance_id) catch false;
            if (!allowed) {
                try setSimpleResponse(server, ent, sid, sess, 403, "forbidden\n", allocator);
                continue;
            }

            if (std.mem.eql(u8, subsystem, "code")) {
                if (worker.code_addr == null) {
                    try setSimpleResponse(server, ent, sid, sess, 503, "code subsystem disabled\n", allocator);
                    continue;
                }
                try server.reg.set(ent, &server.request_out, ProxyPeer, .{ .client = rove.Entity.nil });
                try server.reg.move(ent, &server.request_out, &worker.code_proxy_pending);
                continue;
            }

            // Reserved subsystem (e.g. `log`) — wired up in a later
            // slice. Returning 501 tells the CLI the endpoint exists
            // but isn't implemented yet, distinct from a 404 which
            // would look like a URL typo.
            try setSimpleResponse(server, ent, sid, sess, 501, "system endpoint not implemented\n", allocator);
            continue;
        }

        // Strip the optional ":port" suffix — Host headers carry it in
        // dev (e.g. `localhost:8082`) but domain records are indexed by
        // the bare hostname.
        const host = hostOnly(authority);

        const resolved = worker.tenant.resolveDomain(host) catch |err| {
            std.log.warn("rove-js: tenant.resolveDomain({s}) failed: {s}", .{ host, @errorName(err) });
            try setSimpleResponse(server, ent, sid, sess, 500, "tenant resolution failed\n", allocator);
            // Pre-resolution failure: no tenant_id, can't append to
            // any tenant's log. Documented gap; stderr captures it.
            continue;
        };
        if (resolved == null) {
            try setSimpleResponse(server, ent, sid, sess, 404, "unknown domain\n", allocator);
            // Same: unknown tenant, no log home.
            continue;
        }

        // Look up per-tenant code state. If the tenant has no deployment
        // yet, return 503 with a clear "no deployment" message.
        const tc = worker.tenant_codes.get(resolved.?.id) orelse {
            std.log.warn("rove-js: tenant {s} has no code state", .{resolved.?.id});
            try setSimpleResponse(server, ent, sid, sess, 500, "tenant code state missing\n", allocator);
            captureLog(worker, resolved.?.id, method, path, host, 0, received_ns, 500, .handler_error, &.{}, &.{}, .{});
            continue;
        };
        if (tc.bytecodes.count() == 0) {
            try setSimpleResponse(server, ent, sid, sess, 503, "no deployment for this tenant\n", allocator);
            captureLog(worker, resolved.?.id, method, path, host, 0, received_ns, 503, .no_deployment, &.{}, &.{}, .{});
            continue;
        }

        // Resolve URL path → deployment module base via the filesystem
        // router, then look up the corresponding bytecode. Try `.mjs`
        // first (the preferred shape; supports `?fn=` function dispatch),
        // then `.js` (legacy global-script shape).
        var route = router_mod.resolveRoute(allocator, path) catch |err| {
            std.log.warn("rove-js router failed: {s}", .{@errorName(err)});
            try setErrorResponse(server, ent, sid, sess);
            captureLog(worker, resolved.?.id, method, path, host, tc.current_deployment_id, received_ns, 500, .handler_error, &.{}, &.{}, .{});
            continue;
        };
        defer route.deinit();

        const mjs_key = try std.fmt.allocPrint(allocator, "{s}.mjs", .{route.module_base});
        defer allocator.free(mjs_key);
        const js_key = try std.fmt.allocPrint(allocator, "{s}.js", .{route.module_base});
        defer allocator.free(js_key);
        const bytecode = tc.bytecodes.get(mjs_key) orelse tc.bytecodes.get(js_key) orelse {
            try setSimpleResponse(server, ent, sid, sess, 404, "not found\n", allocator);
            captureLog(worker, resolved.?.id, method, path, host, tc.current_deployment_id, received_ns, 404, .handler_error, &.{}, &.{}, .{});
            continue;
        };

        // Circuit breaker: if this tenant has tripped the penalty
        // box, short-circuit with 503 without touching qjs. Saves the
        // wall-clock budget for well-behaved tenants.
        if (worker.penalty_box.isBoxed(resolved.?.id, tc.current_deployment_id, received_ns)) {
            try setSimpleResponse(server, ent, sid, sess, 503, "tenant temporarily disabled (cpu budget)\n", allocator);
            captureLog(worker, resolved.?.id, method, path, host, tc.current_deployment_id, received_ns, 503, .timeout, &.{}, &.{}, .{});
            continue;
        }

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
            // Derive a per-request seed from the request_id space so
            // the PRNG stream is deterministic under replay. `received_ns`
            // alone is enough for now; Phase 5 can stamp the stable
            // request_id in here once it's available pre-dispatch.
            .prng_seed = @bitCast(received_ns),
        };

        // Open a tracked txn on the tenant store — `BEGIN IMMEDIATE`
        // so concurrent writers on this tenant serialize cleanly.
        // Every exit path from this block must either commit or
        // rollback the txn.
        var txn = resolved.?.kv.beginTrackedImmediate() catch |err| {
            std.log.warn("rove-js beginTrackedImmediate({s}) failed: {s}", .{ resolved.?.id, @errorName(err) });
            try setSimpleResponse(server, ent, sid, sess, 500, "txn begin failed\n", allocator);
            captureLog(worker, resolved.?.id, method, path, host, tc.current_deployment_id, received_ns, 500, .kv_error, &.{}, &.{}, .{});
            continue;
        };

        var writeset = kv_mod.WriteSet.init(allocator);
        defer writeset.deinit();

        var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
        var resp = worker.dispatcher.run(
            resolved.?.kv,
            &txn,
            &writeset,
            bytecode,
            request,
            &budget,
        ) catch |err| {
            std.log.warn("rove-js dispatch failed: {s}", .{@errorName(err)});
            txn.rollback() catch {};
            const outcome: log_mod.Outcome = if (err == dispatcher_mod.DispatchError.Interrupted)
                .timeout
            else
                .handler_error;
            const status: u16 = if (err == dispatcher_mod.DispatchError.Interrupted) 504 else 500;
            if (err == dispatcher_mod.DispatchError.Interrupted) {
                try setSimpleResponse(server, ent, sid, sess, 504, "handler exceeded cpu budget\n", allocator);
                worker.penalty_box.recordKill(
                    resolved.?.id,
                    tc.current_deployment_id,
                    received_ns,
                ) catch |pe| std.log.warn("rove-js penalty recordKill failed: {s}", .{@errorName(pe)});
            } else {
                try setErrorResponse(server, ent, sid, sess);
            }
            captureLog(worker, resolved.?.id, method, path, host, tc.current_deployment_id, received_ns, status, outcome, &.{}, &.{}, .{});
            continue;
        };
        // Defer is structured so that whatever's STILL in resp.console
        // / resp.exception at end-of-iteration gets freed. The success
        // path detaches them by clearing to `&.{}` after transferring
        // ownership into a LogRecord.
        defer {
            if (resp.console.len > 0) allocator.free(resp.console);
            if (resp.exception.len > 0) allocator.free(resp.exception);
        }

        // Surfaced kv errors from inside the JS callbacks (e.g. SQLITE
        // errors that couldn't throw cleanly out of a callconv(.c)
        // function) mean the txn is in a bad state. Roll back and 500.
        if (worker.dispatcher.last_kv_error != null) {
            std.log.warn("rove-js handler kv error: {s}", .{@errorName(worker.dispatcher.last_kv_error.?)});
            txn.rollback() catch {};
            try setSimpleResponse(server, ent, sid, sess, 500, "kv error during handler\n", allocator);
            captureLog(worker, resolved.?.id, method, path, host, tc.current_deployment_id, received_ns, 500, .kv_error, &.{}, &.{}, .{});
            continue;
        }

        // Stamp response components onto the entity. These ride along
        // through `raft_pending` → `response_in` without rewrites.
        // RespBody owns the body pointer once set; the `resp.body = &.{}`
        // below makes sure `resp.deinit` doesn't double-free.
        const body_ptr: ?[*]u8 = if (resp.body.len > 0) resp.body.ptr else null;
        const body_len: u32 = @intCast(resp.body.len);
        resp.body = &.{};

        const status_code: u16 = @intCast(@max(@min(resp.status, 599), 100));

        try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status_code });
        try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{
            .fields = null,
            .count = 0,
        });
        try server.reg.set(ent, &server.request_out, h2.RespBody, .{
            .data = body_ptr,
            .len = body_len,
        });
        try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
        try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
        try server.reg.set(ent, &server.request_out, h2.Session, sess);

        // Read-only handlers never need to touch raft, and their commit
        // releases the empty txn cheaply.
        if (writeset.ops.items.len == 0) {
            var ok = true;
            txn.commit() catch |err| {
                std.log.warn("rove-js commit (read-only) failed: {s}", .{@errorName(err)});
                txn.rollback() catch {};
                try overwriteWith503(server, ent, allocator, body_ptr, body_len);
                ok = false;
            };
            try server.reg.move(ent, &server.request_out, &server.response_in);

            // Transfer console + exception ownership into the log
            // record; clear the slices so the defer doesn't double-free.
            const console_owned = resp.console;
            const exception_owned = resp.exception;
            resp.console = &.{};
            resp.exception = &.{};
            const refs_ro = uploadTapes(worker, resolved.?.id, &tapes);
            captureLog(
                worker,
                resolved.?.id,
                method,
                path,
                host,
                tc.current_deployment_id,
                received_ns,
                if (ok) status_code else 503,
                if (ok) .ok else .kv_error,
                console_owned,
                exception_owned,
                refs_ro,
            );
            continue;
        }

        // Writes present: commit locally FIRST (releasing the write
        // lock so other concurrent requests on this tenant can
        // proceed), then propose through raft and park. If raft
        // commits, the parked entity just drains onward — writes are
        // already durable. If raft faults or we time out, the undo
        // log lets us compensating-rollback in `drainRaftPending` via
        // `store.undoTxn(txn_seq)`. This is the pattern rove-kv's
        // TrackedTxn + kv_undo was built for.
        const txn_seq = txn.txn_seq;
        txn.commit() catch |err| {
            std.log.warn("rove-js txn commit failed: {s}", .{@errorName(err)});
            // Commit failure is terminal for this request — the txn
            // is already rolled back by SQLite on commit error, and
            // we can't replay from the writeset since it's the same
            // thing that just failed. Respond 500.
            try overwriteWith503(server, ent, allocator, body_ptr, body_len);
            try server.reg.move(ent, &server.request_out, &server.response_in);
            const console_owned_a = resp.console;
            const exception_owned_a = resp.exception;
            resp.console = &.{};
            resp.exception = &.{};
            const refs_a = uploadTapes(worker, resolved.?.id, &tapes);
            captureLog(worker, resolved.?.id, method, path, host, tc.current_deployment_id, received_ns, 503, .kv_error, console_owned_a, exception_owned_a, refs_a);
            continue;
        };

        const seq = proposeWriteSet(worker, &writeset, resolved.?.id) catch |err| {
            std.log.warn("rove-js raft propose failed: {s}", .{@errorName(err)});
            // The writes are already committed locally; compensating
            // rollback via undoTxn, then 503 so the client retries.
            resolved.?.kv.undoTxn(txn_seq) catch |undo_err| {
                std.log.err("rove-js undoTxn failed after propose error: {s}", .{@errorName(undo_err)});
            };
            try overwriteWith503(server, ent, allocator, body_ptr, body_len);
            try server.reg.move(ent, &server.request_out, &server.response_in);
            const console_owned_b = resp.console;
            const exception_owned_b = resp.exception;
            resp.console = &.{};
            resp.exception = &.{};
            const refs_b = uploadTapes(worker, resolved.?.id, &tapes);
            captureLog(worker, resolved.?.id, method, path, host, tc.current_deployment_id, received_ns, 503, .fault, console_owned_b, exception_owned_b, refs_b);
            continue;
        };

        const deadline_ns: i64 = @intCast(std.time.nanoTimestamp() + @as(i128, @intCast(worker.commit_wait_timeout_ns)));
        try server.reg.set(ent, &server.request_out, RaftWait, .{
            .seq = seq,
            .txn_seq = txn_seq,
            .deadline_ns = deadline_ns,
            .store = resolved.?.kv,
        });

        try server.reg.move(ent, &server.request_out, &worker.raft_pending);

        // Write-success path: log at propose-time per the planning
        // decision ("best-effort, log shows what we attempted"). If
        // the parked request later faults in drainRaftPending, the
        // mismatch between this `outcome=.ok` log entry and the actual
        // 503 returned to the client is documented.
        const console_owned_c = resp.console;
        const exception_owned_c = resp.exception;
        resp.console = &.{};
        resp.exception = &.{};
        const refs_c = uploadTapes(worker, resolved.?.id, &tapes);
        captureLog(worker, resolved.?.id, method, path, host, tc.current_deployment_id, received_ns, status_code, .ok, console_owned_c, exception_owned_c, refs_c);
    }
}

// ── /_system/code/* proxy ─────────────────────────────────────────────
//
// The worker runs both a server-side h2 (accepting user traffic) and
// a client-side h2 (forwarding to the in-process code-server thread)
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

/// Ensure a live upstream session exists (or is being established).
/// Called once per poll-loop tick before the other proxy systems.
pub fn connectCodeServer(worker: anytype) !void {
    const addr = worker.code_addr orelse return;
    const server = worker.h2;
    const reg = server.reg;

    const session_live = !worker.reg.isStale(worker.code_session);
    if (session_live or worker.code_connecting) return;

    const conn = try reg.create(&server.client_connect_in);
    try reg.set(conn, &server.client_connect_in, h2.ConnectTarget, .{ .addr = addr });
    worker.code_connecting = true;
    std.log.info("rove-js: connecting to code server at {any}", .{addr});
}

/// Drain `client_connect_out` + `client_connect_errors` — both flip
/// the "connecting" flag back off. On success we remember the new
/// session entity so `flushCodeProxyPending` can bind client
/// requests to it; on failure we just log and wait for the next
/// `connectCodeServer` tick to re-arm.
pub fn ingestCodeConnects(worker: anytype) !void {
    const server = worker.h2;
    const reg = server.reg;

    {
        const ents = server.client_connect_out.entitySlice();
        for (ents) |ent| {
            const sess = try reg.get(ent, &server.client_connect_out, h2.Session);
            worker.code_session = sess.entity;
            worker.code_connecting = false;
            std.log.info("rove-js: code server connected (session={d})", .{sess.entity.index});
            try reg.destroy(ent);
        }
    }
    {
        const ents = server.client_connect_errors.entitySlice();
        for (ents) |ent| {
            worker.code_connecting = false;
            const io = reg.get(ent, &server.client_connect_errors, h2.H2IoResult) catch null;
            const err_code: i32 = if (io) |i| i.err else -1;
            std.log.warn("rove-js: code server connect failed: {d}", .{err_code});
            try reg.destroy(ent);
        }
    }
}

/// Forward any parked `/_system/code/*` requests to the code server.
/// Each pending entity gets a fresh client-side entity built from its
/// method/path/headers/body; the server entity gains a ProxyPeer
/// back-reference and moves to `code_proxy_inflight`.
pub fn flushCodeProxyPending(worker: anytype) !void {
    const server = worker.h2;
    const reg = server.reg;
    const allocator = worker.allocator;

    if (worker.reg.isStale(worker.code_session)) return;
    const upstream_session = worker.code_session;

    const entities = worker.code_proxy_pending.entitySlice();
    // Iterate a copy of the slice because `reg.move` mutates the
    // pending collection and invalidates `entitySlice()` positions.
    const snapshot = try allocator.dupe(rove.Entity, entities);
    defer allocator.free(snapshot);

    for (snapshot) |server_ent| {
        const rh = try worker.reg.get(server_ent, &worker.code_proxy_pending, h2.ReqHeaders);
        const rb = try worker.reg.get(server_ent, &worker.code_proxy_pending, h2.ReqBody);

        // Build a fresh header array for the client request. The
        // `:path` pseudo-header is rewritten from
        // `/_system/code/...` to just `/...` so the code-server's
        // routes (`/{instance_id}/upload`, etc.) match. All other
        // fields pass through verbatim.
        const header_fields = forwardHeaders(allocator, rh.*) catch |err| {
            std.log.warn("rove-js proxy: forwardHeaders failed: {s}", .{@errorName(err)});
            const body = try allocator.dupe(u8, "internal proxy error\n");
            try setProxyFault(server, server_ent, &worker.code_proxy_pending, 500, body);
            try worker.reg.move(server_ent, &worker.code_proxy_pending, &server.response_in);
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
        try reg.set(client_ent, &server.client_request_in, h2.ReqHeaders, .{
            .fields = header_fields.ptr,
            .count = @intCast(header_fields.len),
        });
        try reg.set(client_ent, &server.client_request_in, h2.ReqBody, .{
            .data = body_copy,
            .len = body_len,
        });

        // Cross-reference from the server entity → client entity.
        try worker.reg.set(server_ent, &worker.code_proxy_pending, ProxyPeer, .{ .client = client_ent });
        try worker.reg.move(server_ent, &worker.code_proxy_pending, &worker.code_proxy_inflight);
    }
}

/// Map upstream responses back onto their server-side peers. Each
/// client entity in `client_response_out` must have a matching server
/// entity in `code_proxy_inflight` with `ProxyPeer.client == this`.
/// Orphan client entities (no match) are logged + destroyed; they
/// indicate a race where the server entity got timed out separately
/// but should not happen in the current M1 code (no proxy timeout).
pub fn drainCodeProxyResponses(worker: anytype) !void {
    const server = worker.h2;
    const reg = server.reg;
    const allocator = worker.allocator;

    const client_ents = server.client_response_out.entitySlice();
    if (client_ents.len == 0) return;

    const inflight_ents = worker.code_proxy_inflight.entitySlice();
    const peers = worker.code_proxy_inflight.column(ProxyPeer);

    // Snapshot the inflight slice so `reg.move` calls below don't
    // invalidate index positions mid-loop.
    const client_snapshot = try allocator.dupe(rove.Entity, client_ents);
    defer allocator.free(client_snapshot);

    for (client_snapshot) |client_ent| {
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
            continue;
        }

        const ust = try reg.get(client_ent, &server.client_response_out, h2.Status);
        const urb = try reg.get(client_ent, &server.client_response_out, h2.RespBody);
        const uio = try reg.get(client_ent, &server.client_response_out, h2.H2IoResult);

        if (uio.err != 0) {
            // Upstream error → 502. Mirrors shift-h2 proxy behavior.
            std.log.warn("rove-js proxy: upstream error {d} → 502", .{uio.err});
            const body = try allocator.dupe(u8, "bad gateway\n");
            try setProxyFault(server, server_ent, &worker.code_proxy_inflight, 502, body);
            try worker.reg.move(server_ent, &worker.code_proxy_inflight, &server.response_in);
            try reg.destroy(client_ent);
            continue;
        }

        // Copy upstream status.
        try worker.reg.set(server_ent, &worker.code_proxy_inflight, h2.Status, .{ .code = ust.code });

        // Copy upstream body. The bytes live in rove-h2's buffer pool
        // on the client side — dup them so ownership transfer to the
        // server-side RespBody component is clean and the h2 layer
        // can reclaim its buffer.
        var body_copy: ?[*]u8 = null;
        var body_len: u32 = 0;
        if (urb.data != null and urb.len > 0) {
            const buf = try allocator.alloc(u8, urb.len);
            @memcpy(buf, urb.data.?[0..urb.len]);
            body_copy = buf.ptr;
            body_len = urb.len;
        }
        try worker.reg.set(server_ent, &worker.code_proxy_inflight, h2.RespBody, .{ .data = body_copy, .len = body_len });
        try worker.reg.set(server_ent, &worker.code_proxy_inflight, h2.RespHeaders, .{ .fields = null, .count = 0 });
        try worker.reg.set(server_ent, &worker.code_proxy_inflight, h2.H2IoResult, .{ .err = 0 });

        try worker.reg.move(server_ent, &worker.code_proxy_inflight, &server.response_in);
        try reg.destroy(client_ent);
    }
}

/// Prefix stripped off every `/_system/code/` proxy forward before the
/// request is handed to rove-h2's client side. The remainder
/// (`{instance_id}/{op}[/{tail...}]`) matches the code-server thread's
/// routing shape directly, so no further rewriting is needed.
const SYSTEM_CODE_PREFIX: []const u8 = "/_system/code";

/// Duplicate the request headers, rewriting `:path` to strip the
/// `/_system/code` prefix. `:authority` is left alone — the code
/// server doesn't care what host name the caller used. Fields are
/// allocated on `allocator` and owned by the returned slice; rove-h2
/// frees them when the request finishes.
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
            if (std.mem.startsWith(u8, value_slice, SYSTEM_CODE_PREFIX)) {
                value_slice = value_slice[SYSTEM_CODE_PREFIX.len..];
                if (value_slice.len == 0) value_slice = "/";
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
) !void {
    try server.reg.set(ent, src_coll, h2.Status, .{ .code = status });
    try server.reg.set(ent, src_coll, h2.RespHeaders, .{ .fields = null, .count = 0 });
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

test "openTenantCode runs the orphan sweep on startup" {
    // Simulates the crash recovery scenario:
    //   1. A previous worker run did `beginTrackedImmediate` + put + commit
    //      (the local SQLite txn is durable, the kv_undo row exists).
    //   2. The previous worker crashed before calling commitTxn — so the
    //      kv_undo row never got dropped.
    //   3. New worker starts, openTenantCode runs, recoverOrphans(0)
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

    // Simulate worker startup: openTenantCode runs the sweep.
    const FakeWorker = struct { allocator: std.mem.Allocator };
    var fake = FakeWorker{ .allocator = allocator };
    const tc = try openTenantCode(&fake, inst);
    defer freeTenantCode(allocator, tc);

    // After the sweep, the orphan write is gone.
    try testing.expectError(error.NotFound, inst.kv.get("orphan-key"));
}

test "commitTxn drops the undo row so the next sweep is a no-op" {
    // Inverse of the first test: a write that DID get the commitTxn
    // call should survive across a Worker.create / openTenantCode
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
    const tc = try openTenantCode(&fake, inst);
    defer freeTenantCode(allocator, tc);

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
