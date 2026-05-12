//! `js-worker` — the production rove-js worker binary.
//!
//! Shared-nothing multi-worker model (promoted from the `dual-worker`
//! spike, 2026-04-14). A configurable number of worker threads each
//! own their own `Registry` / `Io` / `H2` / `Tenant` / `Dispatcher`,
//! all bound to the same HTTP/2 port via `SO_REUSEPORT`. The kernel
//! hashes incoming connections across workers. **Any worker handles
//! any tenant** — there is no tenant pinning.
//!
//! Shared between workers (all thread-safe):
//!   - the single `RaftNode` (proposes go through its MPSC queue;
//!     committedSeq/faultedSeq are atomics)
//!   - the single raft-owned `ApplyCtx` (only the raft thread touches
//!     its cached stores; workers never do)
//!   - the files-server + log-server subsystem threads
//!
//! Per-worker (thread-local):
//!   - rove `Registry`, rove-io `Io`, rove-h2 `H2`
//!   - per-worker `Tenant` with its own `__root__.db` sqlite connection
//!   - per-tenant `KvStore` + `RequestIdMinter` (every worker opens
//!     its own — NOMUTEX sqlite connections cannot be shared across
//!     threads). One node-wide `NodeLogBuffer` per worker for the
//!     interleaved log batches.
//!   - qjs `Dispatcher` (its own arena + snapshot)
//!   - penalty box, raft-pending collection
//!
//! ## Data layout
//!
//!   {data_dir}/
//!     __root__.db                  tenant metadata (domain → instance)
//!     raft.log.db                  shared raft log (node-scoped)
//!     acme/
//!       app.db                     acme's handler state
//!       files.db                    acme's code index (deployments)
//!       file-blobs/                acme's source + bytecode blobs
//!       log.db                     acme's request log index
//!       log-blobs/                 acme's request log blobs
//!     globex/
//!       ...
//!     penalty/
//!       ...
//!
//! acme is a hit counter; globex echoes the path; penalty is an
//! intentional `while(true) {}` that exercises the CPU-budget
//! interrupt + penalty box.
//!
//! ## Shutdown
//!
//! SIGINT/SIGTERM flip an atomic stop flag. Workers check it on every
//! poll loop iteration and exit cleanly. `io_uring_enter` returning
//! `error.SignalInterrupt` is tolerated — we just fall through to the
//! flag check. Main thread joins all worker threads before returning.

const std = @import("std");
const rove = @import("rove");
const rjs = @import("rove-js");
const kv = @import("rove-kv");
const blob_mod = @import("rove-blob");
const jwt_mod = @import("rove-jwt");
const files_mod = @import("rove-files");
const files_server = @import("rove-files-server");
const log_server = @import("rove-log-server");
const schedule_server_mod = @import("rove-schedule-server");
const qjs = @import("rove-qjs");
const tenant_mod = @import("rove-tenant");
const h2_mod = @import("rove-h2");
const cli_mod = @import("cli.zig");
const seed_mod = @import("seed.zig");
const restore_cli = @import("restore_cli.zig");
const snapshot_cli = @import("snapshot_cli.zig");
const promote_cli = @import("promote_cli.zig");
const snapshot_mod = @import("snapshot.zig");

// Demo + benchmark tenants used to live inline as Zig string literals
// here. They now live as real `.mjs` files under
// `examples/loop46-demo-tenants/` and are provisioned via
// `loop46 seed --manifest examples/loop46-demo-tenants.json`. The
// worker discovers them on disk at startup; nothing about the demo
// set is hard-coded in this binary anymore.

// Phase 5.5(e) step 3 — admin + replay JS source + UI bytecode now
// live in `src/files_server/bootstrap.zig` (along with the deploy
// machinery that ships them to S3). The worker doesn't need the
// source bytes; it loads bytecodes from the cluster's shared S3
// blob backend at runtime, same as any customer tenant.

/// Print a startup error to stderr and exit with code 2 (matching the
/// CLI parser's `error.Usage` convention so a wrapping shell script
/// can distinguish user-facing config failures from crashes).
fn failExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(2);
}

fn parseHostPort(allocator: std.mem.Allocator, hp: []const u8) !std.net.Address {
    const colon = std.mem.lastIndexOfScalar(u8, hp, ':') orelse return error.MalformedHostPort;
    const host = hp[0..colon];
    const port = try std.fmt.parseInt(u16, hp[colon + 1 ..], 10);

    // Special-case "localhost" so --dev defaults like `--http localhost:8443`
    // work without needing DNS resolution. RFC 6761 specifies localhost
    // always means loopback. IPv4 only — workers don't bind v6 by default.
    if (std.mem.eql(u8, host, "localhost")) {
        return std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    }

    const host_z = try allocator.dupeZ(u8, host);
    defer allocator.free(host_z);
    return try std.net.Address.parseIp(host_z, port);
}

/// Parse a peer-list entry into `(host, port, mode)`.
///
/// Wire format: `host:port[:mode]` where `mode` is
/// `voter` (default) or `learner` (non-voting; see
/// `docs/production.md` #1.2). Examples:
///
///   `127.0.0.1:40100`            → host=127.0.0.1, port=40100, voter
///   `127.0.0.1:40100:voter`      → same
///   `dr.example.com:40100:learner` → learner / non-voting
///
/// IPv6 host:port forms (`[::1]:40100`) aren't supported; rove-h2
/// is IPv4-only at the listen layer anyway.
fn parsePeerEntry(entry: []const u8) !struct {
    host_end: usize,
    port: u16,
    mode: kv.RaftPeerMode,
} {
    // Split on `:` from the right so `host:port:mode` works without
    // confusing colons inside `host` (we don't actually allow them,
    // but doing it right is cheap).
    const last_colon = std.mem.lastIndexOfScalar(u8, entry, ':') orelse return error.MalformedPeer;
    const tail = entry[last_colon + 1 ..];

    // If `tail` parses as an integer, the entry is `host:port` with
    // no mode suffix → default voter. Otherwise treat `tail` as the
    // mode and re-split for port.
    if (std.fmt.parseInt(u16, tail, 10)) |port| {
        return .{ .host_end = last_colon, .port = port, .mode = .voter };
    } else |_| {
        const mode: kv.RaftPeerMode = if (std.mem.eql(u8, tail, "voter"))
            .voter
        else if (std.mem.eql(u8, tail, "learner"))
            .learner
        else
            return error.MalformedPeer;

        const head = entry[0..last_colon];
        const port_colon = std.mem.lastIndexOfScalar(u8, head, ':') orelse return error.MalformedPeer;
        const port = try std.fmt.parseInt(u16, head[port_colon + 1 ..], 10);
        return .{ .host_end = port_colon, .port = port, .mode = mode };
    }
}

fn parsePeerList(allocator: std.mem.Allocator, peers_str: []const u8) ![]kv.RaftPeerAddr {
    var count: usize = 1;
    for (peers_str) |b| {
        if (b == ',') count += 1;
    }

    const out = try allocator.alloc(kv.RaftPeerAddr, count);
    errdefer allocator.free(out);

    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, peers_str, ',');
    while (it.next()) |entry| : (idx += 1) {
        const parsed = try parsePeerEntry(entry);
        const host = try allocator.dupe(u8, entry[0..parsed.host_end]);
        errdefer allocator.free(host);
        out[idx] = .{ .host = host, .port = parsed.port, .mode = parsed.mode };
    }
    return out;
}

// ── Blob backend env wiring ───────────────────────────────────────────
//
// The blob backend is picked at startup from env. With `BLOB_BACKEND=s3`
// every per-tenant file-blobs / log-blobs handle in this process opens
// against the configured S3 bucket (path-style, key-prefixed by
// `{tenant}/{subdir}/`). The string allocations live for the process'
// lifetime — `BlobBackendOwned.deinit` frees them on shutdown. The
// loader itself lives in `rove-blob/env.zig` so the standalone
// services share the same env-var contract.

pub const BlobBackendOwned = blob_mod.BlobBackendOwned;

/// Operator-supplied HMAC secret (hex) for `/_system/services-token`.
/// When set, the worker AND every standalone service must read the
/// same value so JWTs verify across processes. Without it, the
/// worker generates a random per-process secret — useful only for
/// in-process subsystems.
pub const ENV_SERVICES_JWT_SECRET = "LOOP46_SERVICES_JWT_SECRET";

/// Operator-supplied root bearer token (the `Authorization: Bearer
/// <hex>` value the dashboard / files-server-standalone present
/// against `/_system/*` for admin auth). Read at worker startup,
/// stored on the per-worker Tenant, validated by `tenant.authenticate`
/// via constant-time compare. No SQLite write — every node reads the
/// same env value, so cluster-wide consistency is automatic.
/// Operators rotate the token by restarting the workers with a new
/// env value.
pub const ENV_ROOT_TOKEN = "LOOP46_ROOT_TOKEN";

pub fn loadBlobBackend(allocator: std.mem.Allocator) !BlobBackendOwned {
    return blob_mod.env.loadFromEnv(allocator) catch |err| switch (err) {
        blob_mod.env.LoadError.OutOfMemory => return error.OutOfMemory,
        else => |e| {
            const name = blob_mod.env.errorEnvName(e) orelse "<unknown>";
            failExit(
                "loop46: S3 blob backend requires {s} to be set\n",
                .{name},
            );
        },
    };
}

// ── Signal-driven shutdown ────────────────────────────────────────────
//
// sigaction handler has to be signal-safe; it only stores into an
// atomic. The main thread polls it and the worker threads check it
// on every poll-loop iteration.

var stop_flag: std.atomic.Value(bool) = .init(false);

fn handleSignal(_: c_int) callconv(.c) void {
    stop_flag.store(true, .release);
}

fn installSignalHandlers() !void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

// ── Worker thread ─────────────────────────────────────────────────────

const Worker = rjs.Worker(.{});

/// Per-worker state assembled on the worker thread itself. Everything
/// in here is thread-local: allocating on the worker thread keeps the
/// rove registry's allocations co-located for cache locality.
const WorkerCtx = struct {
    allocator: std.mem.Allocator,
    worker_idx: u16,
    data_dir: []const u8,
    http_addr: std.net.Address,
    raft: *kv.RaftNode,
    /// Shared cluster — every worker pulls its root + per-tenant
    /// KvStore handles from here. kvexp's manifest is thread-safe
    /// (per-store locks, sharded page cache), so one handle is
    /// safe to share across all workers.
    cluster: *kv.Cluster,
    /// Phase 5.5(a) Step B — JWT secret shared with the standalone
    /// services (log-server, files-server). Worker mints tokens at
    /// `/_system/services-token` after admin auth; each service
    /// verifies on every request. Generated once per process; lives
    /// in the main thread; workers borrow.
    services_jwt_secret: []const u8,
    /// Public origin the dashboard uses to reach the log-server
    /// process. Returned in the `/_system/services-token` response.
    /// Borrowed. Null when the operator hasn't wired one (yet) —
    /// `/_system/services-token` returns 503 in that case.
    log_public_base: ?[]const u8,
    /// Public origin the dashboard / CLI uses to reach the files-server
    /// process. Borrowed. Null when the operator hasn't wired one
    /// (yet) — `/_system/services-token` returns 503 in that case so
    /// the dashboard can surface a clear error instead of silently
    /// failing on the next files-server fetch.
    files_public_base: ?[]const u8,
    /// Production.md #1.4 step 4 — when non-null, the worker's
    /// per-tenant `manifest_backend` reads via HTTP from this
    /// base URL (a colocated files-server cluster) instead of
    /// going to S3 directly. Borrowed; main thread owns the
    /// allocation.
    files_internal_base: ?[]const u8,
    files_internal_insecure_tls: bool,
    /// Origin the worker uses for the worker → sse-server emit POST
    /// (sse-plan §3.2). Null disables the path; emits stay in the
    /// legacy `_events/{sid}/...` rows + worker pump until the
    /// migration's step 7 cutover.
    sse_public_base: ?[]const u8,
    /// Shared bearer the worker stamps on each emit POST. Borrowed
    /// from an env-loaded slice that lives for the worker's lifetime.
    sse_internal_token: ?[]const u8,
    /// Skip TLS peer verification on the emit POST. Smoke-only; when
    /// `LOOP46_SSE_INSECURE_TLS=1` in env, sse-server uses a
    /// self-signed cert outside the system CA bundle.
    sse_insecure_tls: bool,
    admin_origin: ?[]const u8,
    admin_api_domain: ?[]const u8,
    public_suffix: ?[]const u8,
    rate_limit_caps: rjs.RateLimitCaps,
    /// Operator-supplied root bearer token (`LOOP46_ROOT_TOKEN`
    /// env). Borrowed from the main thread's frame which holds the
    /// env-allocated slice for the process lifetime. When null, no
    /// root auth is configured — every `/_system/*` request that
    /// requires admin auth returns 401.
    root_token_secret: ?[]const u8,
    /// Per-worker QuickJS compiler used by the signup endpoint to
    /// bytecode-compile starter handler content. Runtimes can't be
    /// shared across threads, so each worker owns its own.
    /// Initialized at the top of `workerMain` and destroyed at exit.
    compiler: *QjsCompiler,
    /// Picks fs vs s3 for every per-tenant blob backend the worker
    /// opens. Borrowed from the main thread's `BlobBackendOwned`,
    /// which keeps the underlying strings alive for the worker's
    /// lifetime. Identical across all workers.
    blob_backend_cfg: blob_mod.BackendConfig,
    /// Shared TlsConfig (or null for plaintext h2c). When present,
    /// all workers hand it to their h2 session on accept. Lives in
    /// the main thread; workers borrow.
    tls_config: ?*h2_mod.TlsConfig,
    /// Shared across all workers — every per-tenant `app.db` `KvStore`
    /// opens with a counter from this registry so seq allocation
    /// stays globally monotonic.
    seq_counters: *kv.SeqCounterRegistry,
    /// Phase 5.5 (a). Borrowed from main thread. Same `BatchStore`
    /// shared by every worker thread + the standalone log-server
    /// thread (concurrent put is supported by both backends —
    /// `S3BatchStore` uses a process-wide HTTP client,
    /// `MemoryBatchStore` uses a mutex). Lives for the worker's
    /// full lifetime.
    log_batch_store: log_server.batch_store.BatchStore,
    /// Main thread blocks on these until every worker has bound its
    /// h2 listener — this is what `SO_REUSEPORT` needs before requests
    /// can hit any of them.
    ready: *std.Thread.ResetEvent,
    /// Per-thread schedules.db connection used by worker 0's
    /// `dispatchInternalSchedules` (http-send-plan §3.2). Lazy-opened
    /// on the worker thread (NOMUTEX + WAL means each consumer gets
    /// its own handle); only worker 0 ever reads this slot. Other
    /// workers leave it null.
    internal_schedules_store: ?*schedule_server_mod.ScheduleStore = null,
    /// In-memory inflight set for the in-process schedule dispatch.
    /// Owned by worker 0's thread frame (allocated on stack in
    /// `workerMain`). Other workers leave null.
    internal_schedules_inflight: ?*std.StringHashMapUnmanaged(void) = null,
    /// Worker thread publishes its `DeploymentLoader` pointer here
    /// after `Worker.create`. Main reads it (after `ready.set()`)
    /// and stamps onto `ApplyCtx.deployment_loader` so the apply
    /// thread's follower-side `_deploy/current` detection can
    /// enqueue. Worker 0 only — the field exists on every WorkerCtx
    /// but only worker 0's slot is read. The remaining workers'
    /// loaders catch up on next request to that tenant when they
    /// see the new `_deploy/current` value through their own dispatch.
    /// (Multi-worker fan-out is a follow-up.)
    deployment_loader_publish: ?*rjs.DeploymentLoader = null,
};

fn workerMain(args: *WorkerCtx) !void {
    const allocator = args.allocator;

    // Per-worker QuickJS compiler. Initialized on THIS thread so the
    // runtime + context pointers are thread-local per QuickJS's own
    // rules. Used by the signup endpoint to compile starter content.
    var compiler = try QjsCompiler.init();
    defer compiler.deinit();
    args.compiler = &compiler;

    // Per-worker rove registry. Every entity, every collection, every
    // deferred-op queue is owned by this registry and only touched by
    // this thread.
    var reg = try rove.Registry.init(allocator, .{
        .max_entities = 65536,
        .deferred_queue_capacity = 4096,
    });
    defer reg.deinit();

    // Per-worker tenant. Under the kvexp cutover, every worker
    // shares the cluster's single root handle — kvexp's manifest
    // is thread-safe (per-store locks + sharded page cache), so a
    // single `*KvStore` pointer is safe to use from many threads
    // concurrently. No standalone open here; no `close` here
    // either (the cluster owns the handle's lifetime).
    const root_kv = try args.cluster.openRoot();

    const tenant = try tenant_mod.Tenant.createWithCounters(
        allocator,
        root_kv,
        args.data_dir,
        args.seq_counters,
    );
    defer tenant.destroy();
    try tenant.setPublicSuffix(args.public_suffix);
    tenant.root_token_secret = args.root_token_secret;

    // The main thread created __admin__ + the root token + any
    // pre-seeded tenants before spawning us. Promote them into THIS
    // worker's in-memory cache so `Worker.create` can open their
    // per-tenant stores eagerly. __admin__ is always present;
    // additional tenants are discovered by walking the data dir.
    //
    // For the per-tenant `app.db` stores we also set `busy_timeout=0`
    // so BEGIN IMMEDIATE returns SQLITE_BUSY immediately instead of
    // blocking up to 5s. The batched dispatcher handles that: it
    // records the tenant as blocked for this tick and moves on to
    // pick a different anchor. The WAL-transition race startup
    // happens via the main thread's `prewarmTenantDbs`, so worker
    // opens never need the original 5s wait anymore.
    try tenant.createInstance(tenant_mod.ADMIN_INSTANCE_ID);
    // Skip the busy_timeout=0 hack on __admin__ — its kv ALIASES to
    // the root store, and root.db needs normal busy handling so
    // concurrent bootstrap writes across workers (marker + domain
    // updates) serialize instead of racing to SQLITE_BUSY.
    // Discover the tenants the seed (or a previous worker run)
    // registered: under the kvexp consolidation they live as
    // `instance/{id}` rows in the root store, not as
    // `{data_dir}/{id}/app.db` files on disk.
    var instance_list = try tenant.listInstances(std.math.maxInt(u32));
    defer instance_list.deinit();
    for (instance_list.ids) |id| {
        if (std.mem.eql(u8, id, tenant_mod.ADMIN_INSTANCE_ID)) continue;
        try tenant.createInstance(id);
    }

    // Production.md #1.4 step 4 — wire the HTTP-backed manifest
    // fetcher when the operator pointed us at a files-server
    // cluster. The mint closure runs per fetch; cost is one HMAC-
    // SHA256 (microseconds), dominated by the network roundtrip.
    // Token expiry is 5 minutes — same default loop46 hands the
    // dashboard at /_system/services-token, so no second secret to
    // manage.
    const ManifestMintCtx = struct {
        secret: []const u8,
        fn mint(ctx_opaque: ?*anyopaque, allocator_inner: std.mem.Allocator) anyerror![]u8 {
            const ctx: *@This() = @ptrCast(@alignCast(ctx_opaque.?));
            const exp_ms: i64 = @as(i64, @intCast(@divFloor(std.time.milliTimestamp(), 1))) + 5 * 60 * 1000;
            return jwt_mod.mint(allocator_inner, ctx.secret, .{ .exp_ms = exp_ms });
        }
    };
    var manifest_mint_ctx = ManifestMintCtx{ .secret = args.services_jwt_secret };
    const manifest_http: ?rjs.ManifestHttpConfig = if (args.files_internal_base) |base|
        .{
            .base_url = base,
            .mint_jwt = ManifestMintCtx.mint,
            .mint_ctx = &manifest_mint_ctx,
            .ca_bundle_path = null,
            .verify_tls = !args.files_internal_insecure_tls,
        }
    else
        null;

    // Build a shared libcurl Easy handle FIRST when manifest_http
    // is wired — used by both the cold-start batch fetch AND
    // every per-tenant manifest backend the worker creates after.
    // Connection cache + TLS-session resumption are per-handle
    // in libcurl; sharing one handle keeps the worker → files-
    // server connection warm across all manifest reads (cold-
    // start prefetch, per-release config-mirror fetch, dispatch
    // tick reload). Ownership transfers to Worker.create.
    const manifest_easy: ?*blob_mod.curl.Easy = if (manifest_http != null)
        try blob_mod.curl.Easy.init(allocator)
    else
        null;
    errdefer if (manifest_easy) |e| e.deinit();

    // Cold-start manifest prefetch — one HTTP roundtrip pulls
    // every tenant's manifest from files-server in a single batch.
    // Without this, each per-tenant `openTenantFiles` would issue
    // its own GET, hammering files-server's accept queue at scale
    // (the 10k bench tipped over with `AcceptFailed` before this
    // path landed).
    //
    // No fallback: if the bulk fetch fails (files-server down,
    // partition, transient TLS hiccup), retry with exponential
    // backoff. The worker can't usefully serve traffic without
    // manifests; falling back to per-tenant fetch reintroduces
    // the connection-storm bug class we're avoiding here. Block
    // until the bulk fetch succeeds.
    const manifest_prefetch_opt: ?std.StringHashMapUnmanaged(rjs.PrefetchedManifest) = if (manifest_http) |mh|
        try prefetchManifestsWithRetry(allocator, &mh, manifest_easy, tenant)
    else
        null;

    const worker = try Worker.create(allocator, &reg, .{
        .tenant = tenant,
        .raft = args.raft,
        .addr = args.http_addr,
        .io_opts = .{
            .max_connections = 4096,
            // Each in-flight recv consumes one buffer from this pool.
            // With a connection burst (e.g. the bench's warmup spawning
            // hundreds of curls in close succession) the in-flight
            // count peaks well above what a tenant's steady-state
            // request rate suggests. 4096 leaves plenty of headroom
            // before the kernel returns -ENOBUFS on recv (which is
            // also now handled gracefully — see readsTriage).
            .buf_count = 4096,
            .buf_size = 16384,
            .listen_backlog = 4096,
            .reuseport = true,
        },
        .h2_opts = .{
            .max_concurrent_streams = 512,
            .initial_window_size = 1024 * 1024,
            .max_frame_size = 16384,
            .tls_config = args.tls_config,
        },
        .services_jwt_secret = args.services_jwt_secret,
        .log_public_base = args.log_public_base,
        .files_public_base = args.files_public_base,
        .sse_public_base = args.sse_public_base,
        .sse_internal_token = args.sse_internal_token,
        .sse_insecure_tls = args.sse_insecure_tls,
        .admin_origin = args.admin_origin,
        .admin_api_domain = args.admin_api_domain,
        .log_worker_id = args.worker_idx,
        .rate_limit_caps = args.rate_limit_caps,
        .compile_fn = QjsCompiler.compile,
        .compile_ctx = args.compiler,
        .blob_backend = args.blob_backend_cfg,
        .manifest_http = manifest_http,
        .manifest_prefetch = manifest_prefetch_opt,
        .manifest_easy = manifest_easy,
        .log_batch_store = args.log_batch_store,
    });
    defer worker.destroy();

    // Publish the worker's DeploymentLoader pointer for main to
    // wire into ApplyCtx (follower-side `_deploy/current` apply
    // path). Set before `ready.set()` so main can read it
    // immediately after the wait returns. Worker 0 only — main
    // currently uses just this slot; other workers' loaders are
    // independent (see WorkerCtx.deployment_loader_publish docs).
    @atomicStore(?*rjs.DeploymentLoader, &args.deployment_loader_publish, worker.deployment_loader, .release);

    std.log.info("worker {d}: ready, listening on same port via SO_REUSEPORT", .{args.worker_idx});
    args.ready.set();

    // Scratch list of tenants that returned SQLITE_BUSY on BEGIN
    // IMMEDIATE during THIS tick. Cleared at the top of each tick so
    // a tenant temporarily held by another worker gets a fresh
    // chance next tick. Bounded at 32 — well above the realistic
    // handful-of-tenants-per-tick workloads we've measured.
    var blocked_tenants: rjs.BlockedTenants = .{};

    // Worker-0 lazy state for in-process schedule dispatch
    // (http-send-plan §3.2). Other workers skip — the phase is
    // gated to worker 0 so only one thread on this node makes
    // dispatch decisions for the internal pool.
    var internal_sched_store: ?schedule_server_mod.ScheduleStore = null;
    defer if (internal_sched_store) |*s| s.close();
    var internal_sched_inflight: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = internal_sched_inflight.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        internal_sched_inflight.deinit(allocator);
    }
    if (args.worker_idx == 0) {
        const sched_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/schedules.db",
            .{args.data_dir},
            0,
        );
        defer allocator.free(sched_path);
        internal_sched_store = try schedule_server_mod.ScheduleStore.open(allocator, sched_path);
        args.internal_schedules_store = &internal_sched_store.?;
        args.internal_schedules_inflight = &internal_sched_inflight;
    }

    while (!stop_flag.load(.acquire)) {
        // Bounded-wait poll. The worker has multiple pieces of
        // background state that need periodic attention regardless of
        // incoming I/O:
        //   - parked raft entries (drainRaftPending)
        //   - buffered log records waiting on a flush threshold (flushLogs)
        // The cheapest correct shape is: every poll has a deadline,
        // the loop body runs at least that often, idle CPU stays
        // negligible because each tick is microseconds.
        //
        // `error.SignalInterrupt` is not fatal — it just means SIGINT
        // or SIGTERM arrived during `io_uring_enter`. Fall through to
        // the stop-flag check at the top of the loop.
        worker.pollWithTimeout(1 * std.time.ns_per_ms) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };


        // No /_system/* proxies on the worker anymore — the dashboard
        // hits the standalone services directly (logs.{suffix},
        // files.{suffix}). Phase 5.5(a) Step B / Phase 5.5(e) F1.

        blocked_tenants.clear();
        while (true) {
            const processed = try rjs.dispatchOnce(worker, &blocked_tenants);
            try reg.flush();
            if (processed == 0) break;
        }
        try rjs.drainRaftPending(worker);
        try reg.flush();
        try rjs.cleanupResponses(worker);
        try reg.flush();

        // Schedule callback dispatch: on the raft leader, worker 0
        // scans every tenant's `_callback/*` rows left by the
        // schedule-server's envelope-9 apply and invokes the
        // customer's `on_result` handler in its own transaction.
        // Gated to worker 0 so two threads on the same node don't
        // race on the same receipt — the inner SQLite txn would
        // serialize them anyway via SQLITE_BUSY, but pinning avoids
        // the wasted turnaround.
        if (args.worker_idx == 0) {
            if (args.internal_schedules_store) |sched_store| {
                _ = rjs.dispatchCallbacks(worker, sched_store, rjs.CALLBACK_DEFAULT_MAX_PER_TENANT) catch |err| {
                    std.log.warn("worker {d}: dispatchCallbacks: {s}", .{ args.worker_idx, @errorName(err) });
                };
            }

            // Internal-pool schedule dispatch (http-send-plan §3.2):
            // grab `is_internal=true` rows whose target tenant is
            // hosted on this node and run the handler in-process.
            // Rows we can't serve locally get demoted via envelope-11
            // so the libcurl scheduler thread fires them via cluster
            // ingress instead. Same worker-0 + leader gating as the
            // callback path above.
            if (args.internal_schedules_store) |sched_store| {
                _ = rjs.dispatchInternalSchedules(
                    worker,
                    sched_store,
                    args.internal_schedules_inflight.?,
                    rjs.INTERNAL_SCHEDULES_DEFAULT_MAX_PER_PASS,
                ) catch |err| {
                    std.log.warn(
                        "worker {d}: dispatchInternalSchedules: {s}",
                        .{ args.worker_idx, @errorName(err) },
                    );
                };
            }
        }

        // Log batch flush moved to a background thread spawned in
        // Worker.create — the dispatch loop stays free of S3 RTT.
        // See `Worker.flusherLoop` in src/js/worker.zig.
    }

    std.log.info("worker {d}: shutting down", .{args.worker_idx});
}

fn workerThreadEntry(args: *WorkerCtx) void {
    workerMain(args) catch |err| {
        std.log.err("worker {d}: exited with error: {s}", .{ args.worker_idx, @errorName(err) });
        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        // Release the main thread if we died before reaching the
        // `ready.set()` line — otherwise main would block forever.
        args.ready.set();
        // Flip stop_flag so the surviving workers don't keep running
        // on their own while main thinks everything is fine.
        stop_flag.store(true, .release);
    };
}

/// Args bundled for the raft thread. The loop ticks willemt + an
/// optional periodic snapshot (Phase 5.5(c) step B). Snapshot work
/// runs synchronously between `raft.beginSnapshotOpaque` /
/// `endSnapshotOpaque` so the on-disk log gets compacted past
/// each snapshot's floor — without that bracketing, captures land
/// in S3 / fs but the willemt log keeps growing forever.
const RaftThreadArgs = struct {
    node: *kv.RaftNode,
    cluster: *kv.Cluster,
    /// Null disables the periodic compaction tick. The standalone
    /// CLI `loop46 snapshot` still works against the same data
    /// dir for operator-on-demand DR captures.
    snapshot_state: ?*snapshot_mod.RaftCaptureState = null,
    stop: *std.atomic.Value(bool),
};

fn raftThreadMain(args: *RaftThreadArgs) void {
    runRaftLoop(args) catch |err| {
        std.log.err("raft thread exited: {s}", .{@errorName(err)});
    };
}

fn runRaftLoop(args: *RaftThreadArgs) !void {
    while (!args.node.stopping.load(.acquire) and !args.stop.load(.acquire)) {
        const now_ns: i64 = @intCast(std.time.nanoTimestamp());
        try args.node.tick(now_ns);

        // Periodic log compaction tick. Only fires when the
        // operator wired --snapshot-interval-ms. Per
        // docs/production.md #1.1: this is stamp-and-compact,
        // NOT byte capture — no S3 work, no manifest, no VACUUM
        // INTO. Pass duration scales linearly with active tenant
        // count at ~1ms/tenant; well under the heartbeat budget
        // for realistic clusters. High scale (>10k tenants) may
        // eventually want chunked stamping with willemt yield
        // points; not needed today.
        if (args.snapshot_state) |state| {
            const out = snapshot_mod.tickRaftCapture(
                state,
                now_ns,
                args.cluster,
            ) catch |err| blk: {
                std.log.warn("snapshot tick failed: {s}", .{@errorName(err)});
                break :blk null;
            };
            if (out) |tick| {
                // Stable, parseable shape for
                // scripts/snapshot_scalability_bench.sh — keep
                // the field names + ordering. `apply_position`
                // is the new compaction floor. Per #1.5 there's
                // no per-tenant stamp loop anymore, so the old
                // `stamped_tenants` / `stamped_root` fields
                // dropped.
                std.log.info(
                    "snapshot tick apply_position={d} duration_ms={d}",
                    .{ tick.apply_position, tick.duration_ms },
                );
            }
        }

        std.Thread.sleep(std.time.ns_per_ms);
    }
    try args.node.drainPending(2 * std.time.ns_per_s);
}

// ── main ──────────────────────────────────────────────────────────────

const SubcommandResult = union(enum) {
    /// Help/seed/usage error already handled — caller should return.
    handled,
    /// `dev` or `worker` mode with a parsed CLI ready to drive.
    run: cli_mod.Cli,
};

/// Process argv: dispatch help / seed, validate the subcommand, and
/// parse the CLI for dev/worker modes. Calls `std.process.exit(2)`
/// directly on usage errors (matching the existing convention so a
/// wrapping shell can distinguish user-facing config failures from
/// crashes).
fn dispatchSubcommand(
    allocator: std.mem.Allocator,
    argv: []const [:0]u8,
) !SubcommandResult {
    if (argv.len < 2) {
        try cli_mod.printUsage();
        std.process.exit(2);
    }

    const cmd = argv[1];
    const sub_args = argv[2..];

    if (std.mem.eql(u8, cmd, "help") or
        std.mem.eql(u8, cmd, "--help") or
        std.mem.eql(u8, cmd, "-h"))
    {
        try cli_mod.printUsage();
        return .handled;
    }

    if (std.mem.eql(u8, cmd, "seed")) {
        seed_mod.runSeed(allocator, sub_args) catch |err| {
            if (err == error.Usage) {
                try cli_mod.printUsage();
            } else {
                std.debug.print("error: seed: {s}\n", .{@errorName(err)});
            }
            std.process.exit(2);
        };
        return .handled;
    }

    if (std.mem.eql(u8, cmd, "snapshot")) {
        snapshot_cli.runSnapshot(allocator, sub_args) catch |err| {
            if (err == error.Usage) {
                std.debug.print(
                    \\usage: loop46 snapshot --data-dir <path>
                    \\                       [--snapshot-dir <path>]
                    \\                       [--apply-position <N>]
                    \\                       [--willemt-term <N>]
                    \\
                    \\Walks {{data_dir}}/* for tenant subdirs, VACUUM-INTOs each
                    \\app.db + __root__.db, sha256s + uploads to a BatchStore
                    \\(BLOB_BACKEND=fs|s3, with optional SNAPSHOT_S3_KEY_PREFIX
                    \\for s3 namespacing), writes a manifest under
                    \\cluster/snapshots/{{snap_id}}/manifest.json. Operator can
                    \\later restore via loop46 restore-from-snapshot --snap-id ...
                    \\
                , .{});
            } else {
                std.debug.print("error: snapshot: {s}\n", .{@errorName(err)});
            }
            std.process.exit(2);
        };
        return .handled;
    }

    if (std.mem.eql(u8, cmd, "restore-from-snapshot")) {
        restore_cli.runRestore(allocator, sub_args) catch |err| {
            if (err == error.Usage) {
                std.debug.print(
                    \\usage: loop46 restore-from-snapshot --snap-id <id>
                    \\                                    --data-dir <path>
                    \\                                    [--snapshot-dir <path>]
                    \\
                    \\With BLOB_BACKEND=fs (default) the snapshot store reads
                    \\from --snapshot-dir (defaults to {{data_dir}}/.snapshots).
                    \\With BLOB_BACKEND=s3 the standard S3 env vars apply, plus
                    \\optional SNAPSHOT_S3_KEY_PREFIX for bucket namespacing.
                    \\
                , .{});
            } else {
                std.debug.print("error: restore-from-snapshot: {s}\n", .{@errorName(err)});
            }
            std.process.exit(2);
        };
        return .handled;
    }

    if (std.mem.eql(u8, cmd, "promote-learner")) {
        promote_cli.runPromote(allocator, sub_args) catch |err| {
            if (err == error.Usage) {
                std.debug.print(
                    \\usage: loop46 promote-learner --data-dir <path>
                    \\
                    \\Lost-quorum recovery: wipes the raft log at <path> so a
                    \\subsequent worker boot with `--peers <self>:<port>:voter`
                    \\elects itself as a 1-node cluster. App.db state is
                    \\preserved. See production.md #1.2 for the design.
                    \\
                , .{});
            } else {
                std.debug.print("error: promote-learner: {s}\n", .{@errorName(err)});
            }
            std.process.exit(2);
        };
        return .handled;
    }

    if (!std.mem.eql(u8, cmd, "worker")) {
        std.debug.print("error: unknown subcommand '{s}'\n\n", .{cmd});
        try cli_mod.printUsage();
        std.process.exit(2);
    }

    const cli = cli_mod.parseAndFinalize(allocator, sub_args) catch |err| {
        if (err == error.Usage) {
            try cli_mod.printUsage();
        } else {
            std.debug.print("error: cli: {s}\n", .{@errorName(err)});
        }
        std.process.exit(2);
    };

    return .{ .run = cli };
}

/// One-time bootstrap on the main thread before any worker / raft /
/// subsystem thread starts. Opens root.db, ensures __admin__ exists,
/// applies any `--bootstrap-kv key=value` entries to admin's store,
/// and creates admin/replay tenants. Runs before the cluster comes
/// up, so it opens `cluster.kv` directly via `openClusterOwned`;
/// when the cluster boots later, it sees the same stores at the same
/// hashed store ids.
fn bootstrapTenants(
    allocator: std.mem.Allocator,
    cli: cli_mod.Cli,
) !void {
    const root_kv = try kv.KvStore.openClusterOwned(allocator, cli.data_dir, "cluster.kv", "__root__");
    defer root_kv.close();

    const tenant = try tenant_mod.Tenant.create(allocator, root_kv, cli.data_dir);
    defer tenant.destroy();

    // Phase 5.5(e) step 3 — admin and replay deploys are owned by
    // files-server-standalone now. The worker creates the per-node
    // tenant rows in __root__.db so the dispatcher can route to
    // them, but the bytecodes + manifest + `_deploy/current` arrive
    // via files-server's bootstrap (S3 PUTs + raft-replicated
    // /_system/release POST). Until that lands the admin/replay
    // tenants return 503 ("no deployment yet") on every request —
    // expected steady state for a fresh cluster between worker boot
    // and files-server's first call.

    try tenant.createInstance("__admin__");
    try tenant.createInstance(tenant_mod.REPLAY_INSTANCE_ID);
    if (cli.public_suffix) |ps| {
        const replay_host = try std.fmt.allocPrint(allocator, "replay.{s}", .{ps});
        defer allocator.free(replay_host);
        tenant.assignDomain(replay_host, tenant_mod.REPLAY_INSTANCE_ID) catch |err| {
            failExit(
                "bootstrap: assignDomain {s} -> __replay__ failed: {s}\n",
                .{ replay_host, @errorName(err) },
            );
        };
    }

    // Prewarm __admin__ + every disk-discovered tenant's app.db +
    // log.db on the main thread so the WAL-mode transition is
    // committed before workers race to open them. Without this,
    // `--workers 8` occasionally kills a worker with
    // `error: JournalMode` because two openers try to upgrade
    // journal_mode=WAL at the same time. `__replay__` is bootstrap-
    // created above but isn't in the explicit list — discoverTenantIds
    // Under the kvexp cutover the WAL-mode prewarm dance is
    // unnecessary — there are no per-tenant SQLite files to
    // upgrade. The cluster's manifest creates per-tenant stores
    // lazily inside `cluster.kv` on first `openStore`.
}

/// Build the `TlsConfig` for the worker pool. Both `--tls-cert` and
/// `--tls-key` are required. Operators provision certs out-of-band
/// (Let's Encrypt via lego, internal PKI, etc.); the worker reads
/// the PEM files and reloads them when their mtime changes (see
/// `runUntilStopped`).
fn resolveTls(
    allocator: std.mem.Allocator,
    cli: cli_mod.Cli,
) !*h2_mod.TlsConfig {
    const cert_path = cli.tls_cert orelse failExit(
        "error: --tls-cert is required\n",
        .{},
    );
    const key_path = cli.tls_key orelse failExit(
        "error: --tls-key is required\n",
        .{},
    );

    const cfg = h2_mod.TlsConfig.createFromFiles(
        allocator,
        cert_path,
        key_path,
    ) catch |err| failExit(
        "error: tls: {s} (cert={s}, key={s})\n",
        .{ @errorName(err), cert_path, key_path },
    );
    std.log.info("tls: loaded {s} + {s}", .{ cert_path, key_path });
    return cfg;
}

/// Block the main thread until SIGINT/SIGTERM flips `stop_flag`. The
/// stat()-and-reload polling that picks up a renewed cert is in
/// `h2.TlsConfig.runReloadPoll` — shared across all four binaries so
/// they all get the same renewal behavior from the same code.
fn runUntilStopped(tls_config: ?*h2_mod.TlsConfig) void {
    h2_mod.TlsConfig.runReloadPoll(tls_config, &stop_flag);
}

/// Keep `std.log.info` calls live in ReleaseFast so operators can
/// see startup banners + per-PUT diagnostics without rebuilding at
/// ReleaseSafe (which is ~3× slower and unfit for the production
/// path). `.warn` and `.err` stay enabled at every optimize level.
pub const std_options: std.Options = .{ .log_level = .info };

pub fn main() !void {
    // c_allocator (glibc malloc) — NOT DebugAllocator. The latter
    // spends ~20% of CPU in stack-trace capture per alloc even in
    // ReleaseFast. See memory `feedback_zig_*` / session-9 notes.
    const allocator = std.heap.c_allocator;

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const cli = switch (try dispatchSubcommand(allocator, argv)) {
        .handled => return,
        .run => |c| c,
    };

    // Resolve workers=0 → online CPU count (minus one for the raft thread).
    const num_workers: u16 = if (cli.workers == 0) blk: {
        const cpus = std.Thread.getCpuCount() catch 4;
        break :blk @intCast(@max(1, cpus -| 1));
    } else cli.workers;

    if (cli.fresh) {
        std.fs.cwd().deleteTree(cli.data_dir) catch {};
    }
    try std.fs.cwd().makePath(cli.data_dir);

    if (cli.dev_webhook_unsafe) {
        schedule_server_mod.ssrf.test_allow_loopback = true;
        schedule_server_mod.thread.test_allow_plaintext = true;
        std.log.warn("*** --dev-webhook-unsafe enabled: http.send may target loopback over http:// — DEV ONLY ***", .{});
    }

    try installSignalHandlers();

    // S3 blob backend config. Strings live in `blob_owned` for the
    // entire process — every per-tenant backend the workers / apply
    // / files-server / log-server open borrows from `blob_owned.cfg`.
    var blob_owned = try loadBlobBackend(allocator);
    defer blob_owned.deinit(allocator);
    {
        const s = blob_owned.cfg;
        std.log.info(
            "blob backend: s3 endpoint={s} region={s} bucket={s} key_prefix_base='{s}' use_tls={}",
            .{ s.endpoint, s.region, s.bucket, s.key_prefix_base, s.use_tls },
        );
    }

    try bootstrapTenants(allocator, cli);

    // ── Log batch store (Phase 5.5 a) ─────────────────────────────────
    //
    // Worker's `flushLogs` writes here. Same connection params as the
    // blob backend plus an optional `LOG_S3_KEY_PREFIX` so log batches
    // can sit under a named prefix alongside tenant-scoped artifacts.
    // Shared with the standalone log-server process (Task #61): worker
    // writes batches; standalone's indexer polls + serves them.
    var log_s3_handle: *log_server.batch_store_s3.S3BatchStore = undefined;
    defer log_s3_handle.deinit();
    var log_batch_store: log_server.batch_store.BatchStore = undefined;
    {
        const s3cfg = blob_owned.cfg;
        const env = blob_mod.env;
        const key_prefix = (try env.envOpt(allocator, "LOG_S3_KEY_PREFIX")) orelse
            try allocator.dupe(u8, "");
        defer allocator.free(key_prefix);
        log_s3_handle = try log_server.batch_store_s3.S3BatchStore.init(allocator, .{
            .endpoint = s3cfg.endpoint,
            .region = s3cfg.region,
            .bucket = s3cfg.bucket,
            .key_prefix = key_prefix,
            .access_key = s3cfg.access_key,
            .secret_key = s3cfg.secret_key,
            .use_tls = s3cfg.use_tls,
        });
        log_batch_store = log_s3_handle.batchStore();
        std.log.info(
            "log backend: s3 endpoint={s} region={s} bucket={s} key_prefix='{s}'",
            .{ s3cfg.endpoint, s3cfg.region, s3cfg.bucket, key_prefix },
        );
    }

    // ── Boot-time snap-catchup install ────────────────────────────────
    //
    // If a previous boot's `SnapReceiver` staged a snapshot bundle
    // and exited (production.md #1.1 step 3, follower half), the
    // staged dir is on disk under `{data_dir}/.snap-in-{snap_id}/`
    // with an `_install_meta.json` marker. Install it BEFORE the
    // raft layer comes up so the catchup is invisible to the
    // outside world — when we return from this block, data_dir is
    // already at the leader's `snap_last_idx` and the raft init
    // below picks up from there.
    //
    // The post-init `raft_load_snapshot` call (further down) tells
    // willemt to treat the current on-disk state as a snapshot at
    // `(snap_last_term, snap_last_idx)`, truncating the local log.
    const staged_install: ?snapshot_mod.StagedInstall = snapshot_mod.installStagedSnapshotIfPresent(allocator, cli.data_dir) catch |err| blk: {
        std.log.warn(
            "loop46: boot-time staged-snapshot install failed: {s}; continuing with on-disk state as-is",
            .{@errorName(err)},
        );
        break :blk null;
    };

    // ── Cluster + apply setup ─────────────────────────────────────────
    //
    // The shared `kv.Cluster` library owns the raft node, the apply
    // dispatch table, per-store cache (lazy-opened on first follower
    // apply), and `__root__.db`. Loop46-specific apply state lives in
    // `Loop46Ctx`, threaded through `Cluster.Config.user_ctx`. The
    // per-store cache uses filename `"app.db"` to preserve the
    // pre-Cluster on-disk layout (raft-kv-design.md migration step 4,
    // approach A′ — filename config, no file renames).
    //
    // Per-tenant SQLite connections live in `cluster.stores` and are
    // raft-thread-local; workers keep their own per-tenant connections
    // for dispatch, so the raft thread and worker threads never share
    // a NOMUTEX sqlite connection.
    var loop46_ctx = rjs.apply.Loop46Ctx.init(allocator);
    defer loop46_ctx.deinit();
    // Internal-target stamping for envelope-8 (http-send-plan §3.2).
    loop46_ctx.public_suffix = cli.public_suffix;

    const peers = try parsePeerList(allocator, cli.peers);
    defer {
        for (peers) |p| allocator.free(p.host);
        allocator.free(peers);
    }
    const listen_addr = try parseHostPort(allocator, cli.listen);

    const raft_log_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/raft.log.db",
        .{cli.data_dir},
        0,
    );
    defer allocator.free(raft_log_path);

    // Build the URL prefix peers should GET against this node when
    // they need a snapshot. `cli.http` is `host:port` (e.g.
    // `127.0.0.1:8470`); the prefix is `https://host:port`. Lives in
    // a heap-allocated buffer the snapshot_ctx points into for the
    // process lifetime (RaftNode never restarts under us, so no
    // shutdown lifecycle to manage).
    const snap_url_prefix = try std.fmt.allocPrint(
        allocator,
        "https://{s}",
        .{cli.http},
    );
    defer allocator.free(snap_url_prefix);
    var needs_snapshot_ctx = snapshot_mod.NeedsSnapshotCtx{
        .http_url_prefix = snap_url_prefix,
    };

    // Load the shared services-JWT secret BEFORE raft_node init so
    // SnapReceiver can borrow a pointer into the same backing array
    // that the worker threads later read. (Originally set up after
    // raft_node init alongside the worker-spawn block; moved up
    // because the receiver registers as a raft callback that needs
    // the secret to mint the bearer token for the inter-peer
    // snapshot fetch.)
    var services_jwt_secret: [32]u8 = undefined;
    if (try blob_mod.env.envOpt(allocator, ENV_SERVICES_JWT_SECRET)) |hex| {
        defer allocator.free(hex);
        if (hex.len != services_jwt_secret.len * 2) failExit(
            "loop46: {s} must be {d} hex chars (got {d})\n",
            .{ ENV_SERVICES_JWT_SECRET, services_jwt_secret.len * 2, hex.len },
        );
        _ = std.fmt.hexToBytes(&services_jwt_secret, hex) catch failExit(
            "loop46: {s} is not valid hex\n",
            .{ENV_SERVICES_JWT_SECRET},
        );
        std.log.info("services-jwt-secret: loaded from {s}", .{ENV_SERVICES_JWT_SECRET});
    } else {
        std.crypto.random.bytes(&services_jwt_secret);
        std.log.info(
            "services-jwt-secret: generated per-process (set {s} to share with external services)",
            .{ENV_SERVICES_JWT_SECRET},
        );
    }

    var snap_receiver = snapshot_mod.SnapReceiver{
        .allocator = allocator,
        .data_dir = cli.data_dir,
        .services_jwt_secret = &services_jwt_secret,
    };

    const cluster = try kv.Cluster.init(.{
        .allocator = allocator,
        .data_dir = cli.data_dir,
        .user_ctx = @ptrCast(&loop46_ctx),
        .raft = .{
            .node_id = cli.node_id,
            .peers = peers,
            .listen_addr = listen_addr,
            // Phase 5.5(c) step C / production.md #1.1 step 3 — when
            // willemt fires `send_snapshot`, mint a snap_id and push
            // a `snap_fetch_offer` frame to the peer carrying the URL
            // this node will serve the bundle at. Receiver side's
            // `on_snap_fetch_offer` runs the fetcher thread.
            .needs_snapshot = snapshot_mod.sendSnapshotFetchOffer,
            .needs_snapshot_ctx = @ptrCast(&needs_snapshot_ctx),
            .raft_log_path = raft_log_path,
            .propose_linger_ns = cli.propose_linger_us * std.time.ns_per_us,
            .election_timeout_ms = cli.election_timeout_ms,
            .request_timeout_ms = cli.request_timeout_ms,
        },
    });
    defer cluster.deinit();
    const raft_node = cluster.raft;
    // The snap-fetch-offer receiver wiring isn't part of
    // RaftBootConfig yet; set it directly on the raft node post-init.
    raft_node.config.on_snap_fetch_offer = snapshot_mod.SnapReceiver.onSnapFetchOffer;
    raft_node.config.on_snap_fetch_offer_ctx = @ptrCast(&snap_receiver);

    // Register loop46's envelope handlers with the cluster. Library
    // defaults handle types 0 + 1 (writeset, multi); we override
    // type 0 because loop46's writeset has follower-side post-
    // processing (deployment-loader enqueue on `_deploy/current`).
    // Type 1 (multi) uses the library default — the multi-envelope
    // wire shape matches.
    try cluster.registerEnvelope(0, .{ .apply = rjs.apply.applyWriteSet, .leader_skip = true });
    try cluster.registerEnvelope(2, .{ .apply = rjs.apply.applyRootWriteSet, .leader_skip = true });
    try cluster.registerEnvelope(8, .{ .apply = rjs.apply.applyScheduleUpsertBatch, .leader_skip = false });
    try cluster.registerEnvelope(9, .{ .apply = rjs.apply.applyScheduleComplete, .leader_skip = false });
    try cluster.registerEnvelope(10, .{ .apply = rjs.apply.applyScheduleCancelBatch, .leader_skip = false });
    try cluster.registerEnvelope(11, .{ .apply = rjs.apply.applyScheduleDemote, .leader_skip = false });

    // Tell willemt about the just-installed staged snapshot, if any.
    // The on-disk app.dbs reflect state through `snap_last_idx`;
    // calling `raft_load_snapshot` makes raft's view match. Without
    // this, willemt would try to replay log entries it doesn't have
    // (the leader compacted past them — that's why it sent us the
    // snapshot in the first place).
    if (staged_install) |inst| {
        raft_node.loadSnapshot(inst.snap_last_idx, inst.snap_last_term) catch |err| {
            std.log.err(
                "loop46: raft_load_snapshot after staged install failed: {s} (snap_last_idx={d} snap_last_term={d})",
                .{ @errorName(err), inst.snap_last_idx, inst.snap_last_term },
            );
            failExit("loop46: cannot continue with inconsistent raft state\n", .{});
        };
        std.log.info(
            "loop46: staged snapshot installed and raft_load_snapshot called (snap_last_idx={d} snap_last_term={d})",
            .{ inst.snap_last_idx, inst.snap_last_term },
        );
    }

    // ── Optional periodic snapshot (Phase 5.5(c) step B) ──────────────
    //
    // Off by default. When `--snapshot-interval-ms` is set we open a
    // BatchStore (fs or s3 via BLOB_BACKEND), allocate a per-raft-thread
    // capture state, and the raft loop fires `snapshot.tickRaftCapture`
    // each interval. The capture wraps in `raft.beginSnapshotOpaque` /
    // `endSnapshotOpaque` so willemt actually compacts the on-disk log
    // past each pass — without that bracketing, periodic captures
    // would land in S3 / fs but the raft log would grow forever.
    var snap_state: ?snapshot_mod.RaftCaptureState = null;
    defer if (snap_state) |*s| s.deinit();
    if (cli.snapshot_interval_ms > 0) {
        snap_state = .{
            .interval_ns = @as(i64, cli.snapshot_interval_ms) * std.time.ns_per_ms,
        };
        std.log.info(
            "snapshot: stamp-and-compact tick enabled (interval {d}ms)",
            .{cli.snapshot_interval_ms},
        );
    }

    var raft_thread_args = RaftThreadArgs{
        .node = raft_node,
        .cluster = cluster,
        .snapshot_state = if (snap_state) |*s| s else null,
        .stop = &stop_flag,
    };
    var raft_thread = try std.Thread.spawn(.{}, raftThreadMain, .{&raft_thread_args});
    defer raft_thread.join();

    // ── TLS resolution (shared across the worker + standalone
    //    services. Production wildcard cert covers `app.`, `logs.`,
    //    `files.` subdomains).
    const tls_config = try resolveTls(allocator, cli);

    // `services_jwt_secret` was loaded earlier (above the raft_node
    // init) so SnapReceiver could borrow into it. The block that
    // used to live here moved up unchanged; this comment marks where
    // it WAS so future readers don't double-load.

    // Root bearer token for `/_system/*` admin auth. Owned slice
    // lives for the rest of main()'s frame (and therefore the
    // process); per-worker `Tenant` borrows.
    const root_token_secret: ?[]const u8 = try blob_mod.env.envOpt(allocator, ENV_ROOT_TOKEN);
    defer if (root_token_secret) |s| allocator.free(s);
    if (root_token_secret) |s| {
        if (s.len < 32) failExit(
            "loop46: {s} must be at least 32 chars (got {d}) — generate via `head -c32 /dev/urandom | xxd -p`\n",
            .{ ENV_ROOT_TOKEN, s.len },
        );
        std.log.info("root-token: loaded from {s}", .{ENV_ROOT_TOKEN});
    } else {
        std.log.info(
            "root-token: {s} unset; /_system/* admin auth will reject every bearer (only files-server cap-JWT path will work)",
            .{ENV_ROOT_TOKEN},
        );
    }

    // ── External services ─────────────────────────────────────────────
    //
    // After Tasks #61 + #62, files-server and log-server run as
    // separate operator-deployed processes; loop46 only carries the
    // worker, raft, and schedule-server threads. The two URL fields
    // below are what `/_system/services-token` returns to the
    // dashboard so it knows where to fetch + log queries land.

    // ── log-server (Phase 5.5(a) Step B + Task #61 split) ─────────────
    //
    // Log-server now runs as a separate `log-server-standalone`
    // process. The worker only writes batches into the shared
    // `log_batch_store` (fs or s3); the standalone's indexer reads
    // them and serves the dashboard's `/v1/{tenant}/...` queries.
    // Operator wires `--log-public-base` and `LOOP46_SERVICES_JWT_SECRET`
    // so the worker's `/_system/services-token` returns a usable URL
    // and the standalone's JWT verifier accepts the minted tokens.
    const log_public_base: ?[]u8 = if (cli.log_public_base) |s|
        try allocator.dupe(u8, s)
    else if (cli.public_suffix) |suffix|
        try std.fmt.allocPrint(allocator, "https://logs.{s}", .{suffix})
    else
        null;
    defer if (log_public_base) |s| allocator.free(s);

    // ── files-server (Phase 5.5(e) F1 + Task #62 split) ───────────────
    //
    // Files-server now runs as a separate `files-server-standalone`
    // process. The operator launches it independently and tells the
    // worker where to find it via `--files-public-base`; both
    // processes must agree on `LOOP46_SERVICES_JWT_SECRET` so the
    // worker's `/_system/services-token` mints tokens that the
    // standalone verifies. Without `--files-public-base` the worker
    // still boots, but `/_system/services-token` returns 503 for the
    // `files_url` field — useful for nodes that don't expose the
    // dashboard.
    const files_public_base: ?[]u8 = if (cli.files_public_base) |s|
        try allocator.dupe(u8, s)
    else if (cli.public_suffix) |suffix|
        try std.fmt.allocPrint(allocator, "https://files.{s}", .{suffix})
    else
        null;
    defer if (files_public_base) |s| allocator.free(s);

    // ── sse-server (sse-plan §3.2) ────────────────────────────────────
    //
    // Operator deploys `sse-server-standalone` and points the worker
    // at it via `--sse-public-base` (or auto-derived from
    // `--public-suffix`). `SSE_INTERNAL_TOKEN` env carries the shared
    // bearer the worker stamps on each emit POST; sse-server is
    // launched with the same value. Either piece missing → the
    // worker → sse-server POST path stays disabled, emits live in
    // the legacy `_events/{sid}/...` rows, and the existing
    // `/_events` worker route serves them. Cutover lands in plan §7
    // step 7.
    const sse_public_base: ?[]u8 = if (cli.sse_public_base) |s|
        try allocator.dupe(u8, s)
    else if (cli.public_suffix) |suffix|
        try std.fmt.allocPrint(allocator, "https://sse.{s}", .{suffix})
    else
        null;
    defer if (sse_public_base) |s| allocator.free(s);

    const sse_internal_token: ?[]u8 = std.process.getEnvVarOwned(allocator, "SSE_INTERNAL_TOKEN") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (sse_internal_token) |s| allocator.free(s);

    // LOOP46_SSE_INSECURE_TLS=1 → worker's libcurl emit POST skips
    // TLS peer verification. Smoke-only; production must leave it
    // unset so the system CA bundle is enforced.
    const sse_insecure_tls: bool = blk: {
        const v = std.process.getEnvVarOwned(allocator, "LOOP46_SSE_INSECURE_TLS") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk false,
            else => return err,
        };
        defer allocator.free(v);
        break :blk std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true");
    };

    // ── Schedule-server thread (http-send-plan §5) ────────────────────
    //
    // Leader-pinned poll loop reading `{data_dir}/schedules.db`. The
    // dispatcher's `http.send` calls accumulate into a per-batch
    // schedule list which rides atomically with the writeset via the
    // type-7 multi-envelope; this thread reads the resulting rows and
    // fires them over libcurl. Apply-side wake fires on env-8 / env-11
    // so deliveries ship within an apply tick instead of waiting out
    // the next-due-or-poll deadline.
    const schedule_handle = try schedule_server_mod.thread.spawn(.{
        .allocator = allocator,
        .data_dir = cli.data_dir,
        .raft = raft_node,
    });
    defer schedule_handle.join();
    defer schedule_handle.signalStop();
    loop46_ctx.schedule_wake = &schedule_handle.wake;

    // ── Spawn worker threads ───────────────────────────────────────────
    const http_addr = try parseHostPort(allocator, cli.http);

    const ctxs = try allocator.alloc(WorkerCtx, num_workers);
    defer allocator.free(ctxs);
    const threads = try allocator.alloc(std.Thread, num_workers);
    defer allocator.free(threads);
    const ready_events = try allocator.alloc(std.Thread.ResetEvent, num_workers);
    defer allocator.free(ready_events);
    for (ready_events) |*ev| ev.* = .{};

    // Shared seq-counter registry. Every per-tenant `app.db` KvStore
    // opened by any worker draws from this, so concurrent worker
    // threads allocating new seqs for the same tenant never collide.
    var seq_counters = kv.SeqCounterRegistry.init(allocator);
    defer seq_counters.deinit();

    var i: u16 = 0;
    while (i < num_workers) : (i += 1) {
        ctxs[i] = .{
            .allocator = allocator,
            .worker_idx = i,
            .data_dir = cli.data_dir,
            .http_addr = http_addr,
            .raft = raft_node,
            .cluster = cluster,
            .services_jwt_secret = &services_jwt_secret,
            .log_public_base = log_public_base,
            .files_public_base = files_public_base,
            .files_internal_base = cli.files_internal_base,
            .files_internal_insecure_tls = cli.files_internal_insecure_tls,
            .sse_public_base = sse_public_base,
            .sse_internal_token = sse_internal_token,
            .sse_insecure_tls = sse_insecure_tls,
            .admin_origin = cli.admin_origin,
            .admin_api_domain = cli.admin_api_domain,
            .public_suffix = cli.public_suffix,
            .root_token_secret = root_token_secret,
            .rate_limit_caps = .{
                .request_capacity = cli.rate_limit_request_capacity,
                .request_refill_per_sec = cli.rate_limit_request_refill,
                .email_capacity = cli.rate_limit_email_capacity,
                .email_refill_per_sec = cli.rate_limit_email_refill,
            },
            // The worker thread allocates its QjsCompiler on its own
            // stack (QuickJS runtime pointers have thread affinity)
            // and fills this field before `Worker.create`. The main
            // thread never dereferences it.
            .compiler = undefined,
            .blob_backend_cfg = blob_owned.cfg,
            .tls_config = tls_config,
            .seq_counters = &seq_counters,
            .log_batch_store = log_batch_store,
            .ready = &ready_events[i],
        };
        threads[i] = try std.Thread.spawn(.{}, workerThreadEntry, .{&ctxs[i]});
    }
    for (ready_events) |*ev| ev.wait();

    // Wire worker 0's DeploymentLoader into ApplyCtx so the apply
    // thread can enqueue on follower-side `_deploy/current` writes.
    // Atomic read pairs with the worker thread's release-store
    // before `ready.set()`. Other workers' loaders are independent;
    // multi-worker fan-out is a follow-up.
    loop46_ctx.deployment_loader = @atomicLoad(?*rjs.DeploymentLoader, &ctxs[0].deployment_loader_publish, .acquire);

    std.debug.print(
        "loop46 worker node {d} listening on http://{s}\n" ++
            "  workers:        {d} (SO_REUSEPORT)\n" ++
            "  data dir:       {s}\n" ++
            "  raft:           node {d} of {d} @ {s}\n" ++
            "  peers:          {s}\n" ++
            "  admin host:     {s}\n" ++
            "  public suffix:  {s}\n",
        .{
            cli.node_id,
            cli.http,
            num_workers,
            cli.data_dir,
            cli.node_id,
            peers.len,
            cli.listen,
            cli.peers,
            cli.admin_api_domain orelse "(disabled)",
            cli.public_suffix orelse "(disabled)",
        },
    );

    runUntilStopped(tls_config);
    std.log.info("js-worker: shutdown requested, joining {d} worker(s)", .{num_workers});
    for (threads) |t| t.join();
    std.log.info("js-worker: bye", .{});

    // Skip the teardown chain. The raft thread is detached and still
    // inside `node.run()`; running `raft_node.deinit()` out from under
    // it would segfault. Subsystem threads (files-server, log-server)
    // would also need a join story before it's safe to free their
    // handles. The pragmatic answer is `_exit(0)` — same as nginx,
    // envoy, etc.: the kernel reclaims memory + fds + sockets in one
    // shot and we avoid re-implementing a clean teardown graph for
    // every subsystem.
    std.process.exit(0);
}

/// Retrying wrapper around `prefetchManifests`. Exponential backoff
/// 1s → 2s → 4s → 8s → 16s → 32s, capped at 32s thereafter. No
/// fallback to per-tenant fetch — the prefetch IS the way. If the
/// batch endpoint is unreachable, the worker can't usefully serve
/// any tenant's traffic, so block until it comes back.
///
/// In practice the only realistic failure modes are: files-server
/// hasn't finished booting yet (one or two retries), files-server
/// is being rolled, TLS misconfiguration. The first two recover
/// on their own; the third needs operator intervention regardless.
fn prefetchManifestsWithRetry(
    allocator: std.mem.Allocator,
    mh: *const rjs.ManifestHttpConfig,
    shared_easy: ?*blob_mod.curl.Easy,
    tenant_registry: *tenant_mod.Tenant,
) !std.StringHashMapUnmanaged(rjs.PrefetchedManifest) {
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        const result = prefetchManifests(allocator, mh, shared_easy, tenant_registry) catch |err| {
            const backoff_ms: u64 = std.math.shl(u64, 1000, @min(attempt, 5));
            std.log.warn(
                "loop46: manifest prefetch attempt {d} failed: {s} — retry in {d}ms",
                .{ attempt + 1, @errorName(err), backoff_ms },
            );
            std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
            continue;
        };
        if (attempt > 0) std.log.info(
            "loop46: manifest prefetch succeeded on attempt {d}",
            .{attempt + 1},
        );
        return result;
    }
}

/// Cold-start manifest prefetch (production.md #1.4 step 4). One
/// HTTP batch fetch pulls every tenant's deployment manifest from
/// files-server in one roundtrip. Returns a map of tenant_id →
/// PrefetchedManifest (keys + value bytes both owned). Worker.create
/// takes ownership; `openTenantFiles` consumes per-tenant entries.
///
/// Tenants without a `_deploy/current` (no real deploy yet) are
/// skipped — they wouldn't have a manifest in the cluster store.
/// Per-tenant errors during the gather phase are skipped silently;
/// they'll fall back to per-tenant fetch on the worker side.
fn prefetchManifests(
    allocator: std.mem.Allocator,
    mh: *const rjs.ManifestHttpConfig,
    shared_easy: ?*blob_mod.curl.Easy,
    tenant_registry: *tenant_mod.Tenant,
) !std.StringHashMapUnmanaged(rjs.PrefetchedManifest) {

    // Phase 1: gather (tenant_id, dep_id) pairs by reading
    // `_deploy/current` from each tenant's app.db. Skip ones
    // without a current pointer.
    var tenants: std.ArrayList(blob_mod.http_blob.BatchTenant) = .empty;
    defer tenants.deinit(allocator);

    var it = tenant_registry.instances.iterator();
    while (it.next()) |entry| {
        const inst = entry.value_ptr.*;
        // Skip __admin__ — its kv aliases root, no manifest
        // path makes sense for it. Same skip discoverTenantIds
        // does.
        if (std.mem.eql(u8, inst.id, tenant_mod.ADMIN_INSTANCE_ID)) continue;

        const cur_bytes = inst.kv.get("_deploy/current") catch |err| switch (err) {
            error.NotFound => continue,
            else => continue,
        };
        defer allocator.free(cur_bytes);
        const dep_id = std.fmt.parseInt(u64, cur_bytes, 16) catch continue;

        try tenants.append(allocator, .{ .id = inst.id, .dep_id = dep_id });
    }

    if (tenants.items.len == 0) return .empty;

    // Phase 2: one HTTP batch call.
    var http_be = try blob_mod.HttpBlobStore.init(allocator, .{
        .base_url = mh.base_url,
        .instance_id = "_batch", // unused — fetchBatch builds URL from base_url alone
        .mint_jwt = mh.mint_jwt,
        .mint_ctx = mh.mint_ctx,
        // Borrow the shared Easy so the cold-start TLS handshake
        // primes the connection cache the per-tenant manifest
        // backends will reuse.
        .easy = shared_easy,
        .ca_bundle_path = mh.ca_bundle_path,
        .verify_tls = mh.verify_tls,
    });
    defer http_be.deinit();

    const t_start = std.time.milliTimestamp();
    const rows = try blob_mod.http_blob.fetchBatch(&http_be, allocator, tenants.items);
    defer allocator.free(rows); // entries' id + manifest moved into the map below
    const t_ms = std.time.milliTimestamp() - t_start;

    // Phase 3: build the result map. Move owned ids + manifests
    // out of `rows` into the map; entries with `manifest = null`
    // (cluster store miss) get freed here so the worker doesn't
    // see them.
    var map: std.StringHashMapUnmanaged(rjs.PrefetchedManifest) = .empty;
    errdefer {
        var mit = map.iterator();
        while (mit.next()) |me| {
            allocator.free(me.key_ptr.*);
            allocator.free(me.value_ptr.*.bytes);
        }
        map.deinit(allocator);
    }

    var ok: usize = 0;
    var miss: usize = 0;
    // We need the dep_id we asked for to stash on the entry —
    // fetchBatch returns ids but not dep_ids (the request order
    // is what carries that). Build an id → dep_id sidetable.
    var dep_for: std.StringHashMapUnmanaged(u64) = .empty;
    defer dep_for.deinit(allocator);
    for (tenants.items) |t| try dep_for.put(allocator, t.id, t.dep_id);

    for (rows) |row| {
        if (row.manifest) |bytes| {
            const dep_id = dep_for.get(row.id) orelse {
                allocator.free(row.id);
                allocator.free(bytes);
                continue;
            };
            try map.put(allocator, row.id, .{ .dep_id = dep_id, .bytes = bytes });
            ok += 1;
        } else {
            allocator.free(row.id);
            miss += 1;
        }
    }

    std.log.info(
        "loop46: manifest prefetch — {d} tenants, {d} hits, {d} misses, {d}ms",
        .{ tenants.items.len, ok, miss, t_ms },
    );
    return map;
}

/// Walk `<data_dir>/*` and return every subdirectory containing an
/// `app.db` — i.e. every tenant the worker should know about. Skips
/// `__admin__` since that's always created fresh by the worker (its
/// kv aliases the root store, so the on-disk dir is not the source of
/// truth for its existence). Caller owns the returned slice + the
/// id strings inside it.
/// Open + close each tenant's `app.db` and `log.db` once from the
/// main thread so the `PRAGMA journal_mode=WAL` transition is
/// committed to disk BEFORE any workers race to open them. Concurrent
/// WAL-mode transitions from multiple openers can fail with a
/// `JournalMode` error under load (the brief exclusive lock SQLite
/// needs can't be re-entered while another opener holds it), which
/// we observed at `--workers 8`. Prewarming fixes it once and for
/// all: subsequent openers see the existing WAL mode and skip the
/// transition.
/// Inline qjs compile hook — identical to the one in files_cli.zig.
/// Duplicating it here keeps the smoke test self-contained; the
/// production path reuses files_cli's helper.
const QjsCompiler = struct {
    runtime: qjs.Runtime,
    context: qjs.Context,

    fn init() !QjsCompiler {
        var rt = try qjs.Runtime.init();
        errdefer rt.deinit();
        const ctx = try rt.newContext();
        return .{ .runtime = rt, .context = ctx };
    }

    fn deinit(self: *QjsCompiler) void {
        self.context.deinit();
        self.runtime.deinit();
    }

    fn compile(
        ctx_opaque: ?*anyopaque,
        source: []const u8,
        filename: [:0]const u8,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const self: *QjsCompiler = @ptrCast(@alignCast(ctx_opaque.?));
        const kind: qjs.EvalFlags = if (files_mod.isJsModule(filename))
            .{ .kind = .module }
        else
            .{};
        return self.context.compileToBytecode(source, filename, allocator, kind);
    }
};

