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
//!   - per-tenant `KvStore` + `LogStore` (every worker opens its own
//!     — NOMUTEX sqlite connections cannot be shared across threads)
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
const files_mod = @import("rove-files");
const files_server = @import("rove-files-server");
const log_server = @import("rove-log-server");
const webhook_server_mod = @import("rove-webhook-server");
const qjs = @import("rove-qjs");
const tenant_mod = @import("rove-tenant");
const h2_mod = @import("rove-h2");
const cli_mod = @import("cli.zig");
const tls_dev = @import("tls_dev.zig");
const seed_mod = @import("seed.zig");
const restore_cli = @import("restore_cli.zig");
const snapshot_cli = @import("snapshot_cli.zig");
const snapshot_mod = @import("snapshot.zig");

// Demo + benchmark tenants used to live inline as Zig string literals
// here. They now live as real `.mjs` files under
// `examples/loop46-demo-tenants/` and are provisioned via
// `loop46 seed --manifest examples/loop46-demo-tenants.json`. The
// worker discovers them on disk at startup; nothing about the demo
// set is hard-coded in this binary anymore.

/// JS source for the admin handler. Deployed to `__admin__` at
/// bootstrap. Each RPC function is a named export; the UI calls them
/// by name (`?fn=listInstance` or `POST {fn:"listInstance",args:[...]}`).
///
/// Reads platform-level state (instances, domains) via the
/// `platform.root.*` globals, which are only installed on the admin
/// handler (gated by `Instance.platform` being non-null). Writes go
/// through the same primitives but aren't replicated through raft
/// yet (single-node admin writes only) — multi-node correctness for
/// admin-handler writes is a follow-up; signup-driven instance
/// creation already goes through the replicated Zig-native path.
///
/// The KV RPCs (`listKv`, `setKv`, etc.) still operate on whatever
/// store the dispatcher selected — admin's own app.db by default,
/// the target tenant's app.db under `X-Rove-Scope: <id>`.
///
/// Status on error flows through the ambient `response` global;
/// non-200 return values use the `{ error }` shape as the body.
const ADMIN_HANDLER_SRC = @embedFile("admin_handler_mjs");

/// Admin's request-time auth middleware. Runs before every dispatch
/// to admin's bundle (default export AND named-export RPCs). Reads
/// the session cookie (or Authorization: Bearer for the dashboard's
/// bootstrap-token sign-in path), looks up the row in admin's app.db
/// or the root_token/{hash} entry in root.db, and either sets
/// `request.auth = {is_root: ...}` or short-circuits with 401.
///
/// Pre-auth paths (signup / magic redeem / login / logout) skip the
/// gate entirely — those endpoints exist precisely so an unauthed
/// caller can become authed.
const ADMIN_MIDDLEWARE_SRC = @embedFile("admin_middleware_mjs");


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
        const colon = std.mem.lastIndexOfScalar(u8, entry, ':') orelse return error.MalformedPeer;
        const host = try allocator.dupe(u8, entry[0..colon]);
        errdefer allocator.free(host);
        const port = try std.fmt.parseInt(u16, entry[colon + 1 ..], 10);
        out[idx] = .{ .host = host, .port = port };
    }
    return out;
}

// ── Blob backend env wiring ───────────────────────────────────────────
//
// The blob backend is picked at startup from env. With `BLOB_BACKEND=s3`
// every per-tenant file-blobs / log-blobs handle in this process opens
// against the configured S3 bucket (path-style, key-prefixed by
// `{tenant}/{subdir}/`); without it (or `BLOB_BACKEND=fs`) the existing
// on-disk layout is used. The string allocations live for the process'
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

pub fn loadBlobBackend(allocator: std.mem.Allocator) !BlobBackendOwned {
    return blob_mod.env.loadFromEnv(allocator) catch |err| switch (err) {
        blob_mod.env.LoadError.UnknownBackend => failExit(
            "loop46: BLOB_BACKEND must be \"fs\" or \"s3\"\n",
            .{},
        ),
        blob_mod.env.LoadError.OutOfMemory => return error.OutOfMemory,
        else => |e| {
            const name = blob_mod.env.errorEnvName(e) orelse "<unknown>";
            failExit(
                "loop46: BLOB_BACKEND=s3 requires {s} to be set\n",
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
    admin_origin: ?[]const u8,
    admin_api_domain: ?[]const u8,
    public_suffix: ?[]const u8,
    rate_limit_caps: rjs.RateLimitCaps,
    /// Per-worker QuickJS compiler used by the signup endpoint to
    /// bytecode-compile starter handler content. Runtimes can't be
    /// shared across threads, so each worker owns its own.
    /// Initialized at the top of `workerMain` and destroyed at exit.
    compiler: *QjsCompiler,
    /// Process-wide push-release table. Every worker thread shares
    /// the same instance; the system-route handler at
    /// `/_system/release` writes into it after admin-authed POSTs and
    /// each worker's dispatch tick reads it via
    /// `applyPendingReleases`. Phase 5.5(e) F2 replaced the legacy
    /// `refreshDeployments` polling loop.
    release_table: *rjs.ReleaseTable,
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

    // Per-worker tenant. Opens its OWN connection to __root__.db.
    // Multiple connections to the same sqlite file are fine in WAL
    // mode, and each worker's connection respects the NOMUTEX
    // "one thread per connection" rule because it's created here.
    const root_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/__root__.db",
        .{args.data_dir},
        0,
    );
    defer allocator.free(root_path);
    const root_kv = try kv.KvStore.open(allocator, root_path);
    defer root_kv.close();

    const tenant = try tenant_mod.Tenant.createWithCounters(
        allocator,
        root_kv,
        args.data_dir,
        args.seq_counters,
    );
    defer tenant.destroy();
    try tenant.setPublicSuffix(args.public_suffix);

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
    const discovered_ids = try discoverTenantIds(allocator, args.data_dir);
    defer {
        for (discovered_ids) |id| allocator.free(id);
        allocator.free(discovered_ids);
    }
    for (discovered_ids) |id| {
        try tenant.createInstance(id);
        if (tenant.instances.get(id)) |inst| inst.kv.setBusyTimeout(0);
    }

    const worker = try Worker.create(allocator, &reg, .{
        .tenant = tenant,
        .raft = args.raft,
        .addr = args.http_addr,
        .io_opts = .{
            .max_connections = 4096,
            .buf_count = 1024,
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
        .admin_origin = args.admin_origin,
        .admin_api_domain = args.admin_api_domain,
        .log_worker_id = args.worker_idx,
        .release_table = args.release_table,
        .rate_limit_caps = args.rate_limit_caps,
        .compile_fn = QjsCompiler.compile,
        .compile_ctx = args.compiler,
        .blob_backend = args.blob_backend_cfg,
        .log_batch_store = args.log_batch_store,
    });
    defer worker.destroy();

    std.log.info("worker {d}: ready, listening on same port via SO_REUSEPORT", .{args.worker_idx});
    args.ready.set();

    // Scratch list of tenants that returned SQLITE_BUSY on BEGIN
    // IMMEDIATE during THIS tick. Cleared at the top of each tick so
    // a tenant temporarily held by another worker gets a fresh
    // chance next tick. Bounded at 32 — well above the realistic
    // handful-of-tenants-per-tick workloads we've measured.
    var blocked_tenants: rjs.BlockedTenants = .{};

    // Per-worker SSE retention sweep timer. Wall-clock relative to the
    // last sweep; not synchronized across workers — overshoot is fine
    // because the sweep is leader-gated and idempotent.
    var next_sse_sweep_ns: i64 = @as(i64, @intCast(std.time.nanoTimestamp())) + rjs.SSE_SWEEP_INTERVAL_NS;

    while (!stop_flag.load(.acquire)) {
        // Bounded-wait poll. The worker has multiple pieces of
        // background state that need periodic attention regardless of
        // incoming I/O:
        //   - parked raft entries (drainRaftPending)
        //   - released deployments pushed via `/_system/release`
        //     (applyPendingReleases — Phase 5.5(e) F2 retired the
        //     2-second `refreshDeployments` polling loop)
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

        // Drain request_out one tenant-batch at a time. Each call
        // processes at most one tenant's requests; the flush between
        // calls is what lets the next call see a smaller request_out
        // and pick a fresh anchor tenant. A BUSY anchor this tick is
        // remembered in `blocked_tenants` so subsequent calls skip it
        // and try different tenants.
        blocked_tenants.clear();
        while (true) {
            const processed = try rjs.dispatchOnce(worker, &blocked_tenants);
            try reg.flush();
            if (processed == 0) break;
        }
        try rjs.drainRaftPending(worker);
        try reg.flush();
        // SSE: drive connected EventSource clients off newly-emitted
        // _events/{sid}/... rows. Runs after drainRaftPending so any
        // dirty marks set during this tick's commits are visible.
        try rjs.pumpEvents(worker);
        try reg.flush();
        // SSE: scrub the per-tenant connection table for any h2
        // entities that just landed in response_out (client
        // disconnect, transport error). MUST run before
        // cleanupResponses or the records would point at destroyed
        // entities next tick.
        try rjs.cleanupClosedSseConnections(worker);
        try rjs.cleanupResponses(worker);
        try reg.flush();
        try rjs.applyPendingReleases(worker);

        // Webhook callback dispatch: on the raft leader, worker 0
        // scans every tenant's `_callback/*` rows left by the
        // webhook-server's envelope-5 apply and invokes the customer's
        // `onResult` handler in its own transaction. Gated to worker 0
        // so two threads on
        // the same node don't race on the same receipt — the inner
        // SQLite txn would serialize them anyway via SQLITE_BUSY,
        // but pinning avoids the wasted turnaround.
        if (args.worker_idx == 0) {
            _ = rjs.dispatchCallbacks(worker, rjs.CALLBACK_DEFAULT_MAX_PER_TENANT) catch |err| {
                std.log.warn("worker {d}: dispatchCallbacks: {s}", .{ args.worker_idx, @errorName(err) });
            };
        }

        // Best-effort log batch flush: drains each tenant's in-memory
        // buffer if any threshold (count/bytes/time) has been crossed
        // and proposes through raft (leader) or writes locally
        // (follower).
        try rjs.flushLogs(worker);

        // SSE retention sweep — leader-only inside sweepEvents.
        // Worker 0 runs it (matches the dispatchCallbacks pinning
        // above for the same reason: avoid two workers racing on the
        // same tenant txn). Per-tenant work is bounded so this never
        // stalls the worker.
        const now_ns: i64 = @intCast(std.time.nanoTimestamp());
        if (args.worker_idx == 0 and now_ns >= next_sse_sweep_ns) {
            _ = rjs.sweepEvents(worker) catch |err| {
                std.log.warn("worker {d}: sweepEvents: {s}", .{ args.worker_idx, @errorName(err) });
            };
            next_sse_sweep_ns = now_ns + rjs.SSE_SWEEP_INTERVAL_NS;
        }
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
    apply_ctx: *rjs.apply.ApplyCtx,
    /// Null disables the periodic capture. The standalone CLI
    /// `loop46 snapshot` still works against the same data dir.
    snapshot_state: ?*snapshot_mod.RaftCaptureState = null,
    snapshot_store: ?log_server.batch_store.BatchStore = null,
    snapshot_tmp_dir: ?[]const u8 = null,
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

        // Periodic snapshot capture. Only fires when the operator
        // wired --snapshot-interval-ms. NONBLOCKING_APPLY in the
        // begin/end pair lets willemt continue accepting committed
        // entries logically; on a single thread they queue until
        // capture returns, which is fine for low-tenant-count
        // clusters. High scale needs a dedicated snapshot thread —
        // a future step.
        if (args.snapshot_state) |state| {
            const store = args.snapshot_store.?;
            const tmp = args.snapshot_tmp_dir.?;
            const out = snapshot_mod.tickRaftCapture(
                state,
                now_ns,
                args.node,
                args.apply_ctx,
                store,
                tmp,
            ) catch |err| blk: {
                std.log.warn("snapshot tick failed: {s}", .{@errorName(err)});
                break :blk null;
            };
            if (out) |captured| {
                var c = captured;
                std.log.info(
                    "snapshot captured {s} (manifest_key={s})",
                    .{ c.snap_id, c.manifest_key },
                );
                c.deinit();
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

    const dev_mode = std.mem.eql(u8, cmd, "dev");
    const worker_mode = std.mem.eql(u8, cmd, "worker");

    if (!dev_mode and !worker_mode) {
        std.debug.print("error: unknown subcommand '{s}'\n\n", .{cmd});
        try cli_mod.printUsage();
        std.process.exit(2);
    }

    const cli = cli_mod.parseAndFinalize(allocator, sub_args, dev_mode) catch |err| {
        if (err == error.Usage) {
            try cli_mod.printUsage();
        } else {
            std.debug.print("error: cli: {s}\n", .{@errorName(err)});
        }
        std.process.exit(2);
    };
    if (cli.dev) {
        std.log.info("dev: admin = {s}", .{cli.admin_origin.?});
        std.log.info("dev: customer instances = https://*.{s}:{d}", .{
            cli.public_suffix.?,
            cli_mod.portFromAddr(cli.http) orelse 8443,
        });
    }

    return .{ .run = cli };
}

/// One-time bootstrap on the main thread before any worker / raft /
/// subsystem thread starts. Opens root.db, ensures __admin__ exists,
/// applies any `--bootstrap-kv key=value` entries to admin's app.db,
/// deploys the embedded admin UI bundle, and prewarms every existing
/// tenant's app.db + log.db so the WAL-mode upgrade is committed
/// before workers race to open them. Each worker opens its own
/// connections to these files later.
fn bootstrapTenants(
    allocator: std.mem.Allocator,
    cli: cli_mod.Cli,
    blob_cfg: blob_mod.BackendConfig,
) !void {
    const root_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/__root__.db",
        .{cli.data_dir},
        0,
    );
    defer allocator.free(root_path);
    const root_kv = try kv.KvStore.open(allocator, root_path);
    defer root_kv.close();

    const tenant = try tenant_mod.Tenant.create(allocator, root_kv, cli.data_dir);
    defer tenant.destroy();

    if (cli.bootstrap_root_token) |t| {
        tenant.installRootToken(t) catch |err| {
            failExit("bootstrap: installRootToken failed: {s}\n", .{@errorName(err)});
        };
        std.debug.print("bootstrap: root token installed\n", .{});
    }

    // __admin__ is created first so session / magic / resend-key
    // operations (which live in its app.db) have a place to land
    // before any other bootstrap step runs. See `src/tenant/root.zig`.
    try tenant.createInstance("__admin__");

    // Generic config bootstrap: every `--bootstrap-kv key=value`
    // arg writes to admin's app.db under the given key. Zig knows
    // nothing about the keys — admin's JS handler reads whatever
    // it cares about via kv.get with whatever fallback default
    // it wants (e.g. `kv.get("platform_email_from") ||
    // "noreply@loop46.me"`).
    if (cli.bootstrap_kv_count > 0) {
        const admin_inst = (tenant.getInstance(tenant_mod.ADMIN_INSTANCE_ID) catch |err| {
            failExit("bootstrap: lookup __admin__ failed: {s}\n", .{@errorName(err)});
        }).?;
        for (cli.bootstrap_kv[0..cli.bootstrap_kv_count]) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse
                failExit("bootstrap-kv: expected key=value, got '{s}'\n", .{pair});
            const key = pair[0..eq];
            const value = pair[eq + 1 ..];
            if (key.len == 0)
                failExit("bootstrap-kv: empty key in '{s}'\n", .{pair});
            if (std.mem.indexOfScalar(u8, key, 0) != null or
                std.mem.indexOfScalar(u8, value, 0) != null)
            {
                failExit("bootstrap-kv: key/value contains NUL byte (key='{s}')\n", .{key});
            }
            admin_inst.kv.put(key, value) catch |err| {
                failExit("bootstrap-kv: write {s} failed: {s}\n", .{ key, @errorName(err) });
            };
        }
        std.debug.print(
            "bootstrap: wrote {d} kv pair(s) into __admin__/app.db\n",
            .{cli.bootstrap_kv_count},
        );
    }

    // Always-deploy: the embedded admin UI bundle. Demo + benchmark
    // tenants get provisioned by `loop46 seed --manifest ...` (out
    // of band of this binary). The worker discovers them on disk.
    try bootstrapHandler(allocator, cli.data_dir, blob_cfg, "__admin__", &ADMIN_DEPLOY_FILES);

    // __replay__ — platform tenant for the tape-replay browser page
    // (PLAN §10.12). Lives at `replay.{public_suffix}` via an
    // explicit domain alias; resolveDomain's alias path wins over
    // the wildcard so a customer signup for the name "replay"
    // (already blocked at the JS layer's RESERVED_NAMES, defense in
    // depth) couldn't squat the host even if it slipped through.
    // The deployed bundle is a static-only placeholder for now —
    // the actual iframe + stubs library lands as a follow-up deploy
    // through the existing files API.
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
    try bootstrapHandler(allocator, cli.data_dir, blob_cfg, tenant_mod.REPLAY_INSTANCE_ID, &REPLAY_DEPLOY_FILES);

    // Prewarm __admin__ + every disk-discovered tenant's app.db +
    // log.db on the main thread so the WAL-mode transition is
    // committed before workers race to open them. Without this,
    // `--workers 8` occasionally kills a worker with
    // `error: JournalMode` because two openers try to upgrade
    // journal_mode=WAL at the same time. `__replay__` is bootstrap-
    // created above but isn't in the explicit list — discoverTenantIds
    // picks it up like any other on-disk tenant.
    const prewarm_ids = try discoverTenantIds(allocator, cli.data_dir);
    defer {
        for (prewarm_ids) |id| allocator.free(id);
        allocator.free(prewarm_ids);
    }
    try prewarmTenantDbs(allocator, cli.data_dir, &.{tenant_mod.ADMIN_INSTANCE_ID});
    try prewarmTenantDbs(allocator, cli.data_dir, prewarm_ids);
}

/// Owned strings produced by `resolveTls` when `--dev` auto-discovers
/// cert/key paths. Lives in main()'s frame so the buffers survive
/// past `resolveTls`'s return; cleaned up via `deinit` at exit.
const TlsResources = struct {
    cert: ?[]u8 = null,
    key: ?[]u8 = null,
    dir: ?[]u8 = null,

    fn deinit(self: *TlsResources, allocator: std.mem.Allocator) void {
        if (self.cert) |s| allocator.free(s);
        if (self.key) |s| allocator.free(s);
        if (self.dir) |s| allocator.free(s);
    }
};

/// Build the `TlsConfig` for the worker pool. Both `--tls-cert` and
/// `--tls-key` must be set together, or both absent. When `--dev` is
/// set AND neither flag was passed, auto-discover the default cert +
/// key produced by `scripts/rove-dev-setup.sh` (or bootstrap via
/// mkcert on first run); the resulting owned path strings live in
/// `owned` so the caller's defer can free them. Returns null for
/// plaintext (no TLS configured).
fn resolveTls(
    allocator: std.mem.Allocator,
    cli: cli_mod.Cli,
    owned: *TlsResources,
) !?*h2_mod.TlsConfig {
    var cert_path = cli.tls_cert;
    var key_path = cli.tls_key;
    const explicit = cert_path != null or key_path != null;

    if ((cert_path != null and key_path == null) or
        (cert_path == null and key_path != null))
    {
        failExit("error: --tls-cert and --tls-key must be set together\n", .{});
    }

    if (!explicit and cli.dev) {
        const paths = tls_dev.defaultDevTlsPaths(allocator) catch |err|
            failExit("error: --dev: cannot resolve default TLS paths: {s}\n", .{@errorName(err)});
        owned.cert = paths.cert;
        owned.key = paths.key;
        owned.dir = paths.dir;
        // First run: cert missing → bootstrap via mkcert. After
        // initDevTls returns the files exist; if it doesn't, it exits
        // the process itself (mkcert missing, etc.) so we never reach
        // the next line on a real failure.
        if (!tls_dev.devTlsPathsExist(paths.cert, paths.key)) {
            try tls_dev.initDevTls(allocator, paths);
        } else {
            std.log.info("--dev: TLS cert at {s}", .{paths.dir});
        }
        cert_path = paths.cert;
        key_path = paths.key;
    }

    if (cert_path == null) return null;

    const cfg = h2_mod.TlsConfig.createFromFiles(
        allocator,
        cert_path.?,
        key_path.?,
    ) catch |err| failExit(
        "error: tls: {s} (cert={s}, key={s})\n",
        .{ @errorName(err), cert_path.?, key_path.? },
    );
    std.log.info("tls: loaded {s} + {s}", .{ cert_path.?, key_path.? });
    return cfg;
}

/// Block the main thread until SIGINT/SIGTERM flips `stop_flag`. 50ms
/// poll granularity is invisible to shutdown perception and costs
/// nothing. If TLS is on, the main thread also stat()s the PEM files
/// once per second — the sidecar (scripts/rove-lego-renew.sh)
/// rewrites these whenever lego renews, and workers pick up the new
/// cert on the next TLS accept.
fn runUntilStopped(tls_config: ?*h2_mod.TlsConfig) void {
    const reload_interval_ticks: u64 = 20; // 20 × 50ms = 1s
    var tick: u64 = 0;
    while (!stop_flag.load(.acquire)) {
        std.Thread.sleep(50 * std.time.ns_per_ms);
        tick += 1;
        if (tls_config) |cfg| {
            if (tick % reload_interval_ticks == 0) {
                const changed = cfg.reloadIfChanged() catch |err| blk: {
                    std.log.warn("tls: reloadIfChanged failed: {s}", .{@errorName(err)});
                    break :blk false;
                };
                if (changed) std.log.info("tls: cert/key reloaded", .{});
            }
        }
    }
}

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
        webhook_server_mod.ssrf.dev_allow_loopback = true;
        webhook_server_mod.http_client.dev_allow_plaintext = true;
        std.log.warn("*** --dev-webhook-unsafe enabled: webhook.send may target loopback over http:// — DEV ONLY ***", .{});
    }

    try installSignalHandlers();

    // Pick fs vs s3 from env. Strings live in `blob_owned` for the
    // entire process — every per-tenant backend the workers / apply
    // / files-server / log-server open borrows from `blob_owned.cfg`.
    var blob_owned = try loadBlobBackend(allocator);
    defer blob_owned.deinit(allocator);
    switch (blob_owned.cfg) {
        .fs => std.log.info("blob backend: fs ({s})", .{cli.data_dir}),
        .s3 => |s| std.log.info(
            "blob backend: s3 endpoint={s} region={s} bucket={s} key_prefix_base='{s}' use_tls={}",
            .{ s.endpoint, s.region, s.bucket, s.key_prefix_base, s.use_tls },
        ),
    }

    try bootstrapTenants(allocator, cli, blob_owned.cfg);

    // ── Log batch store (Phase 5.5 a) ─────────────────────────────────
    //
    // Worker's `flushLogs` writes here when configured. The store is
    // an `S3BatchStore` that talks real S3 via the sigv4 helpers
    // shared with `rove-blob`. Reuses the same env vars as
    // BLOB_BACKEND=s3 (S3_ENDPOINT / S3_REGION / S3_BUCKET /
    // AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY) plus an optional
    // `LOG_S3_KEY_PREFIX` so log batches can sit under a named prefix
    // alongside other tenant-scoped artifacts in the same bucket.
    //
    // The batch store is shared with the standalone log-server
    // process (Task #61): the worker writes batches via flushLogs;
    // the standalone's indexer polls + serves them. Both processes
    // must point at the same physical store. Two backends:
    //   - `BLOB_BACKEND=s3` → both open S3BatchStore against the
    //     same bucket + LOG_S3_KEY_PREFIX namespace.
    //   - `BLOB_BACKEND=fs` (default) → FsBatchStore at
    //     `{data_dir}/log-batches/`. Worker and standalone share
    //     the data_dir (or an NFS mount of it) so PUT-then-LIST
    //     round-trips across processes.
    var log_fs_handle: ?*log_server.batch_store_fs.FsBatchStore = null;
    defer if (log_fs_handle) |h| h.deinit();
    var log_s3_handle: ?*log_server.batch_store_s3.S3BatchStore = null;
    defer if (log_s3_handle) |h| h.deinit();
    var log_batch_store: log_server.batch_store.BatchStore = undefined;
    switch (blob_owned.cfg) {
        .fs => {
            const fs_dir = try std.fmt.allocPrint(allocator, "{s}/log-batches", .{cli.data_dir});
            defer allocator.free(fs_dir);
            log_fs_handle = try log_server.batch_store_fs.FsBatchStore.init(allocator, fs_dir);
            log_batch_store = log_fs_handle.?.batchStore();
            std.log.info("log backend: fs at {s}", .{fs_dir});
        },
        .s3 => |s3cfg| {
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
            log_batch_store = log_s3_handle.?.batchStore();
            std.log.info(
                "log backend: s3 endpoint={s} region={s} bucket={s} key_prefix='{s}'",
                .{ s3cfg.endpoint, s3cfg.region, s3cfg.bucket, key_prefix },
            );
        },
    }

    // ── Raft setup ─────────────────────────────────────────────────────
    //
    // ApplyCtx is raft-thread-local: it owns its own per-tenant sqlite
    // connections, opened lazily on follower applies. These are
    // DISTINCT from any worker's connections, so the raft thread and
    // the worker threads never share a NOMUTEX sqlite connection.
    var apply_ctx: rjs.apply.ApplyCtx = undefined;

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

    const raft_node = try kv.RaftNode.init(allocator, .{
        .node_id = cli.node_id,
        .peers = peers,
        .listen_addr = listen_addr,
        .apply = .{
            .opaque_bytes = .{
                .apply_fn = rjs.apply.applyOne,
                .ctx = &apply_ctx,
            },
        },
        // Phase 5.5(c) step C — wire willemt's send_snapshot
        // callback so a far-behind follower's catch-up surfaces
        // as an actionable log line instead of silent log-replay
        // loops. Future automation: send SNAP_OFFER + follower
        // auto-restore.
        .needs_snapshot = snapshot_mod.logNeedsSnapshot,
        .needs_snapshot_ctx = null,
        .raft_log_path = raft_log_path,
        .worker_count = 0,
        .propose_linger_ns = cli.propose_linger_us * std.time.ns_per_us,
    });
    defer raft_node.deinit();

    apply_ctx = rjs.apply.ApplyCtx.init(allocator, cli.data_dir, raft_node);
    defer apply_ctx.deinit();

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
    var snap_fs: ?*log_server.batch_store_fs.FsBatchStore = null;
    defer if (snap_fs) |h| h.deinit();
    var snap_s3: ?*log_server.batch_store_s3.S3BatchStore = null;
    defer if (snap_s3) |h| h.deinit();
    var snap_store: ?log_server.batch_store.BatchStore = null;
    var snap_tmp: ?[]u8 = null;
    defer if (snap_tmp) |s| allocator.free(s);
    if (cli.snapshot_interval_ms > 0) {
        snap_tmp = try std.fmt.allocPrint(allocator, "{s}/.snapshot-stage", .{cli.data_dir});
        switch (blob_owned.cfg) {
            .fs => {
                const dir = try std.fmt.allocPrint(allocator, "{s}/.snapshots", .{cli.data_dir});
                defer allocator.free(dir);
                snap_fs = try log_server.batch_store_fs.FsBatchStore.init(allocator, dir);
                snap_store = snap_fs.?.batchStore();
                std.log.info("snapshot store: fs at {s} (interval {d}ms)", .{ dir, cli.snapshot_interval_ms });
            },
            .s3 => |s3cfg| {
                const env = blob_mod.env;
                const key_prefix = (try env.envOpt(allocator, "SNAPSHOT_S3_KEY_PREFIX")) orelse
                    try allocator.dupe(u8, "");
                defer allocator.free(key_prefix);
                snap_s3 = try log_server.batch_store_s3.S3BatchStore.init(allocator, .{
                    .endpoint = s3cfg.endpoint,
                    .region = s3cfg.region,
                    .bucket = s3cfg.bucket,
                    .key_prefix = key_prefix,
                    .access_key = s3cfg.access_key,
                    .secret_key = s3cfg.secret_key,
                    .use_tls = s3cfg.use_tls,
                });
                snap_store = snap_s3.?.batchStore();
                std.log.info(
                    "snapshot store: s3 endpoint={s} bucket={s} key_prefix='{s}' (interval {d}ms)",
                    .{ s3cfg.endpoint, s3cfg.bucket, key_prefix, cli.snapshot_interval_ms },
                );
            },
        }
        snap_state = .{
            .allocator = allocator,
            .interval_ns = @as(i64, cli.snapshot_interval_ms) * std.time.ns_per_ms,
        };
    }

    var raft_thread_args = RaftThreadArgs{
        .node = raft_node,
        .apply_ctx = &apply_ctx,
        .snapshot_state = if (snap_state) |*s| s else null,
        .snapshot_store = snap_store,
        .snapshot_tmp_dir = snap_tmp,
        .stop = &stop_flag,
    };
    var raft_thread = try std.Thread.spawn(.{}, raftThreadMain, .{&raft_thread_args});
    defer raft_thread.join();

    // ── TLS resolution (shared across the worker + standalone
    //    services. Production wildcard cert covers `app.`, `logs.`,
    //    `files.` subdomains).
    var tls_owned: TlsResources = .{};
    defer tls_owned.deinit(allocator);
    const tls_config = try resolveTls(allocator, cli, &tls_owned);

    // ── HMAC secret used by the standalone services (log-server
    //    in-process for now, files-server out-of-process post Task #62)
    //    to verify JWTs minted at `/_system/services-token`.
    //    `LOOP46_SERVICES_JWT_SECRET` (hex-encoded) is the operator's
    //    way to pin a known value across both the worker process and
    //    the external `files-server-standalone` it runs alongside.
    //    Without the env, we generate a random secret per process —
    //    fine for in-process subsystems, useless to a separately-
    //    deployed standalone (its tokens won't verify, by design).
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

    // ── External services ─────────────────────────────────────────────
    //
    // After Tasks #61 + #62, files-server and log-server run as
    // separate operator-deployed processes; loop46 only carries the
    // worker, raft, and webhook-server threads. The two URL fields
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

    // ── Webhook-server thread (Phase 5.5 d) ───────────────────────────
    //
    // Leader-pinned poll loop reading `{data_dir}/webhooks.db`. The
    // dispatcher's `webhook.send` calls accumulate into a per-batch
    // webhook list which rides atomically with the writeset via the
    // type-7 multi-envelope; this thread reads the resulting rows
    // and POSTs them.
    const webhook_handle = try webhook_server_mod.thread.spawn(.{
        .allocator = allocator,
        .data_dir = cli.data_dir,
        .raft = raft_node,
    });
    defer webhook_handle.join();
    defer webhook_handle.signalStop();

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

    // One ReleaseTable per process. The main thread allocates it once;
    // every worker borrows the same pointer. Writes happen from the
    // `/_system/release` system handler (admin-authed POST) on
    // whichever worker took the request; reads happen from every
    // worker's `applyPendingReleases` once per tick.
    var release_table = rjs.ReleaseTable.init(allocator);
    defer release_table.deinit();

    var i: u16 = 0;
    while (i < num_workers) : (i += 1) {
        ctxs[i] = .{
            .allocator = allocator,
            .worker_idx = i,
            .data_dir = cli.data_dir,
            .http_addr = http_addr,
            .raft = raft_node,
            .services_jwt_secret = &services_jwt_secret,
            .log_public_base = log_public_base,
            .files_public_base = files_public_base,
            .admin_origin = cli.admin_origin,
            .admin_api_domain = cli.admin_api_domain,
            .public_suffix = cli.public_suffix,
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
            .release_table = &release_table,
            .blob_backend_cfg = blob_owned.cfg,
            .tls_config = tls_config,
            .seq_counters = &seq_counters,
            .log_batch_store = log_batch_store,
            .ready = &ready_events[i],
        };
        threads[i] = try std.Thread.spawn(.{}, workerThreadEntry, .{&ctxs[i]});
    }
    for (ready_events) |*ev| ev.wait();

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

/// Compile `source` (or pass-through for static) for an instance and
/// publish it as the current deployment through that tenant's file
/// store. Mirrors what `rove-files-cli upload + deploy` would do
/// externally; kept inline so the smoke test is a single binary.
pub const DeployFile = struct {
    path: []const u8,
    content: []const u8,
    /// null → handler source (compile to bytecode). Non-null → static
    /// file served verbatim with this content-type.
    content_type: ?[]const u8 = null,
};

pub fn bootstrapHandler(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    instance_id: []const u8,
    files: []const DeployFile,
) !void {
    const inst_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, instance_id });
    defer allocator.free(inst_dir);
    try std.fs.cwd().makePath(inst_dir);

    const files_db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/files.db", .{inst_dir}, 0);
    defer allocator.free(files_db_path);

    const files_blob_dir = try std.fmt.allocPrint(allocator, "{s}/file-blobs", .{inst_dir});
    defer allocator.free(files_blob_dir);

    const files_kv = try kv.KvStore.open(allocator, files_db_path);
    defer files_kv.close();
    var fs_store = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        blob_cfg,
        files_blob_dir,
        instance_id,
        "file-blobs",
    );
    defer fs_store.deinit();

    // Real qjs compile so the stored bytecode is real.
    var compiler = try QjsCompiler.init();
    defer compiler.deinit();

    var store = files_mod.FileStore.init(
        allocator,
        files_kv,
        fs_store.blobStore(),
        QjsCompiler.compile,
        &compiler,
    );

    for (files) |f| {
        if (f.content_type) |ct| {
            try store.putStatic(f.path, f.content, ct);
        } else {
            try store.putSource(f.path, f.content);
        }
    }

    // Phase 5.5(e) F2-storage — assemble the manifest, JSON-encode,
    // write it to the per-tenant `deployments/` BlobBackend, then
    // bump the local files.db next-id counter. The release pointer
    // (`_deploy/current` in the tenant's app.db) is set further down
    // in `bootstrapTenants` so the worker eagerly loads this
    // bootstrap deployment on first openTenantFiles().
    const cur = try store.currentDeploymentId();
    const next_id = cur + 1;

    const entries = try store.assembleManifest();
    defer store.freeEntries(entries);

    const json_bytes = try files_mod.manifest_json.encode(allocator, next_id, entries);
    defer allocator.free(json_bytes);

    const manifest_dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}/deployments", .{ data_dir, instance_id });
    defer allocator.free(manifest_dir_path);
    var manifest_be = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        blob_cfg,
        manifest_dir_path,
        instance_id,
        "deployments",
    );
    defer manifest_be.deinit();

    var key_buf: [25]u8 = undefined;
    const key = files_mod.manifest_json.manifestKey(&key_buf, next_id);
    try manifest_be.blobStore().put(key, json_bytes);

    try store.setCurrentDeploymentId(next_id);

    // Write the release pointer so the worker eager-opens this deploy.
    const app_db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/app.db", .{inst_dir}, 0);
    defer allocator.free(app_db_path);
    const app_kv = try kv.KvStore.open(allocator, app_db_path);
    defer app_kv.close();
    var current_buf: [16]u8 = undefined;
    const current_hex = try std.fmt.bufPrint(&current_buf, "{x:0>16}", .{next_id});
    try app_kv.put("_deploy/current", current_hex);
}

// The admin UI bundle is embedded into the binary so a fresh start
// ships with a functioning login page at app.loop46.me. Each file
// becomes a `_static/<path>` entry in __admin__'s initial deployment.
const ADMIN_UI_INDEX_HTML = @embedFile("admin_ui_index_html");
const ADMIN_UI_APP_JS = @embedFile("admin_ui_app_js");
const ADMIN_UI_API_JS = @embedFile("admin_ui_api_js");
const ADMIN_UI_APP_CSS = @embedFile("admin_ui_app_css");
const ADMIN_UI_PAGE_LOGIN = @embedFile("admin_ui_page_login");
const ADMIN_UI_PAGE_INSTANCES = @embedFile("admin_ui_page_instances");
const ADMIN_UI_PAGE_INSTANCE = @embedFile("admin_ui_page_instance");
const ADMIN_UI_CODEMIRROR = @embedFile("admin_ui_codemirror");

const ADMIN_DEPLOY_FILES = [_]DeployFile{
    .{ .path = "index.mjs", .content = ADMIN_HANDLER_SRC },
    .{ .path = "_middlewares/index.mjs", .content = ADMIN_MIDDLEWARE_SRC },
    .{ .path = "_static/index.html", .content = ADMIN_UI_INDEX_HTML, .content_type = "text/html; charset=utf-8" },
    .{ .path = "_static/app.js", .content = ADMIN_UI_APP_JS, .content_type = "application/javascript" },
    .{ .path = "_static/api.js", .content = ADMIN_UI_API_JS, .content_type = "application/javascript" },
    .{ .path = "_static/app.css", .content = ADMIN_UI_APP_CSS, .content_type = "text/css" },
    .{ .path = "_static/pages/login.js", .content = ADMIN_UI_PAGE_LOGIN, .content_type = "application/javascript" },
    .{ .path = "_static/pages/instances.js", .content = ADMIN_UI_PAGE_INSTANCES, .content_type = "application/javascript" },
    .{ .path = "_static/pages/instance.js", .content = ADMIN_UI_PAGE_INSTANCE, .content_type = "application/javascript" },
    .{ .path = "_static/codemirror.mjs", .content = ADMIN_UI_CODEMIRROR, .content_type = "application/javascript" },
};

// __replay__ tenant bundle. Static-only — the shell uses postMessage
// to receive the bundle from the dashboard (no worker round-trips
// from this origin), parses captured tapes in JS, and runs the
// handler in a sandboxed iframe with stubbed Loop46 globals.
const REPLAY_INDEX_HTML = @embedFile("replay_index_html");
const REPLAY_APP_JS = @embedFile("replay_app_js");

const REPLAY_DEPLOY_FILES = [_]DeployFile{
    .{ .path = "_static/index.html", .content = REPLAY_INDEX_HTML, .content_type = "text/html; charset=utf-8" },
    .{ .path = "_static/app.js", .content = REPLAY_APP_JS, .content_type = "application/javascript" },
};

/// Walk `<data_dir>/*` and return every subdirectory containing an
/// `app.db` — i.e. every tenant the worker should know about. Skips
/// `__admin__` since that's always created fresh by the worker (its
/// kv aliases the root store, so the on-disk dir is not the source of
/// truth for its existence). Caller owns the returned slice + the
/// id strings inside it.
fn discoverTenantIds(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |id| allocator.free(id);
        list.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir(data_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return list.toOwnedSlice(allocator),
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, tenant_mod.ADMIN_INSTANCE_ID)) continue;
        const probe = try std.fmt.allocPrint(allocator, "{s}/{s}/app.db", .{ data_dir, entry.name });
        defer allocator.free(probe);
        std.fs.cwd().access(probe, .{}) catch continue;
        const id = try allocator.dupe(u8, entry.name);
        try list.append(allocator, id);
    }
    return list.toOwnedSlice(allocator);
}

/// Open + close each tenant's `app.db` and `log.db` once from the
/// main thread so the `PRAGMA journal_mode=WAL` transition is
/// committed to disk BEFORE any workers race to open them. Concurrent
/// WAL-mode transitions from multiple openers can fail with a
/// `JournalMode` error under load (the brief exclusive lock SQLite
/// needs can't be re-entered while another opener holds it), which
/// we observed at `--workers 8`. Prewarming fixes it once and for
/// all: subsequent openers see the existing WAL mode and skip the
/// transition.
fn prewarmTenantDbs(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    tenant_ids: []const []const u8,
) !void {
    for (tenant_ids) |id| {
        const inst_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, id });
        defer allocator.free(inst_dir);
        try std.fs.cwd().makePath(inst_dir);

        const app_db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/app.db", .{inst_dir}, 0);
        defer allocator.free(app_db_path);
        const app_kv = try kv.KvStore.open(allocator, app_db_path);
        app_kv.close();

        const log_db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/log.db", .{inst_dir}, 0);
        defer allocator.free(log_db_path);
        const log_kv = try kv.KvStore.open(allocator, log_db_path);
        log_kv.close();
    }
}

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

