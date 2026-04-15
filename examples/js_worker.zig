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
//!   - the code-server + log-server subsystem threads
//!
//! Per-worker (thread-local):
//!   - rove `Registry`, rove-io `Io`, rove-h2 `H2`
//!   - per-worker `Tenant` with its own `__root__.db` sqlite connection
//!   - per-tenant `KvStore` + `LogStore` (every worker opens its own
//!     — NOMUTEX sqlite connections cannot be shared across threads)
//!   - qjs `Dispatcher` (its own arena + snapshot)
//!   - penalty box, proxy state, raft-pending collection
//!
//! ## Data layout
//!
//!   {data_dir}/
//!     __root__.db                  tenant metadata (domain → instance)
//!     raft.log.db                  shared raft log (node-scoped)
//!     acme/
//!       app.db                     acme's handler state
//!       code.db                    acme's code index (deployments)
//!       code-blobs/                acme's source + bytecode blobs
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
const code_mod = @import("rove-code");
const code_server = @import("rove-code-server");
const log_server = @import("rove-log-server");
const qjs = @import("rove-qjs");
const tenant_mod = @import("rove-tenant");

const ACME_INDEX =
    \\const count = parseInt(kv.get("hits") ?? "0", 10) + 1;
    \\kv.set("hits", String(count));
    \\response.status = 200;
    \\response.body = "acme hit count: " + count + " (path=" + request.path + ")\n";
;

/// Second route under acme — proves the filesystem router picks a
/// non-default file based on URL path. `/api` → `api/index.js`.
const ACME_API_INDEX =
    \\response.status = 200;
    \\response.body = "acme api: method=" + request.method + " path=" + request.path + "\n";
;

/// Third route under acme — a real ES module with `?fn=` function
/// dispatch. `/users?fn=greet` calls `greet(request)` and returns
/// its result object as the HTTP response.
const ACME_USERS_MJS =
    \\export function greet(req) {
    \\    return { status: 200, body: "mjs greet: path=" + req.path + "\n" };
    \\}
    \\export async function slow(req) {
    \\    const v = await Promise.resolve("async " + req.path);
    \\    return { status: 202, body: v + "\n" };
    \\}
;

const GLOBEX_HANDLER =
    \\response.status = 200;
    \\response.body = "globex: you hit " + request.path + " at " + Date.now() + "\n";
;

/// Intentionally runaway — used by scripts/penalty_smoke.sh to prove
/// the interrupt handler + penalty-box pair actually protects the
/// worker from a badly-behaved tenant. Every request hits the 10ms CPU
/// budget and returns 504; after `kill_threshold` (default 3) kills the
/// tenant gets dropped into the penalty box and subsequent requests
/// short-circuit to 503 without ever entering qjs.
const PENALTY_HANDLER =
    \\while (true) {}
;

/// Read-only KV benchmark tenant. Reads a pre-seeded key on every
/// request and never writes, so requests never propose through raft
/// and never dirty any WAL. The tenant's `app.db` is primed at
/// bootstrap with `greeting = "hello"` so the read is a real hit, not
/// a miss.
const READONLY_HANDLER =
    \\response.status = 200;
    \\response.body = "readonly: " + (kv.get("greeting") ?? "(unset)") + "\n";
;

/// Write benchmark handler. Used by the `write0..write7` tenants to
/// measure how the writer-lock ceiling on a single `app.db` scales
/// when the same workload is sharded across independent tenants.
/// Same shape as `ACME_INDEX` (kv.get + kv.set on `hits`), just with
/// a different response body for observability.
const WRITE_BENCH_HANDLER =
    \\const count = parseInt(kv.get("hits") ?? "0", 10) + 1;
    \\kv.set("hits", String(count));
    \\response.status = 200;
    \\response.body = "wbench: " + count + "\n";
;

/// Number of `writeN` benchmark tenants spun up at startup. Each has
/// its own `app.db` and therefore its own SQLite WAL writer lock —
/// concurrent writes to different tenants do NOT serialize against
/// each other. Benching against all of them in parallel shows the
/// system's aggregate write throughput under a realistic multi-tenant
/// shape.
const NUM_WRITE_TENANTS: usize = 8;

const TENANT_IDS = [_][]const u8{
    "acme",     "globex",   "penalty",  "readonly",
    "write0",   "write1",   "write2",   "write3",
    "write4",   "write5",   "write6",   "write7",
};

comptime {
    // Keep TENANT_IDS and NUM_WRITE_TENANTS in lockstep so bootstrap
    // and workerMain iterate the same set.
    std.debug.assert(TENANT_IDS.len == 4 + NUM_WRITE_TENANTS);
}

const Cli = struct {
    node_id: u32 = 0,
    /// Comma-separated `host:port` list. Position determines node_id.
    peers: []const u8 = "127.0.0.1:40100",
    /// `host:port` this node listens on for raft RPCs. Must match the
    /// peers entry at index `node_id`.
    listen: []const u8 = "127.0.0.1:40100",
    /// HTTP/2 listen address (all workers share this via SO_REUSEPORT).
    http: []const u8 = "127.0.0.1:8082",
    /// Per-node data directory. Each node MUST have a unique dir.
    data_dir: []const u8 = "/tmp/rove-js-data",
    /// If true, wipe the data dir before starting (smoke-test mode).
    fresh: bool = false,
    /// Hex-encoded 256-bit root token. When set, the worker installs
    /// it into the tenant root store at startup; any subsequent
    /// `/_system/*` request must carry this token in an
    /// `Authorization: Bearer <hex>` header.
    bootstrap_root_token: ?[]const u8 = null,
    /// Number of worker threads. Each owns its own Registry/Io/H2/
    /// Tenant/Dispatcher and binds the same HTTP/2 port via
    /// SO_REUSEPORT. Default 1 (backward-compatible with the smoke
    /// scripts). Increase to scale dispatch throughput across cores.
    workers: u16 = 1,
    /// Raft proposal linger budget, in microseconds. Hold pending
    /// proposals up to this long so the raft thread can pack more
    /// into a single `raft_log.db` commit + fsync. Under heavy write
    /// load at multi-worker scale, the raft thread's per-tick fsync
    /// is the single hard ceiling on write throughput — every
    /// writeset funnels through one raft log regardless of how many
    /// dispatch workers are running. Trading a few hundred µs of
    /// commit latency for a 3–5× write throughput lift is usually
    /// worth it. 0 disables linger (every tick commits whatever it
    /// has). Mapped directly to `RaftNodeConfig.propose_linger_ns`
    /// at init time.
    propose_linger_us: u64 = 0,
};

fn parseCli(argv: [][:0]u8) !Cli {
    var out: Cli = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--node-id")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.node_id = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--peers")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.peers = argv[i];
        } else if (std.mem.eql(u8, a, "--listen")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.listen = argv[i];
        } else if (std.mem.eql(u8, a, "--http")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.http = argv[i];
        } else if (std.mem.eql(u8, a, "--data-dir")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.data_dir = argv[i];
        } else if (std.mem.eql(u8, a, "--fresh")) {
            out.fresh = true;
        } else if (std.mem.eql(u8, a, "--bootstrap-root-token")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.bootstrap_root_token = argv[i];
        } else if (std.mem.eql(u8, a, "--workers")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.workers = try std.fmt.parseInt(u16, argv[i], 10);
            if (out.workers == 0) return error.Usage;
        } else if (std.mem.eql(u8, a, "--propose-linger-us")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.propose_linger_us = try std.fmt.parseInt(u64, argv[i], 10);
        } else {
            return error.Usage;
        }
    }
    return out;
}

fn parseHostPort(allocator: std.mem.Allocator, hp: []const u8) !std.net.Address {
    const colon = std.mem.lastIndexOfScalar(u8, hp, ':') orelse return error.MalformedHostPort;
    const host = hp[0..colon];
    const port = try std.fmt.parseInt(u16, hp[colon + 1 ..], 10);
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
    code_addr: std.net.Address,
    log_addr: std.net.Address,
    /// Main thread blocks on these until every worker has bound its
    /// h2 listener — this is what `SO_REUSEPORT` needs before requests
    /// can hit any of them.
    ready: *std.Thread.ResetEvent,
};

fn workerMain(args: *WorkerCtx) !void {
    const allocator = args.allocator;

    // Per-worker rove registry. Every entity, every collection, every
    // deferred-op queue is owned by this registry and only touched by
    // this thread.
    var reg = try rove.Registry.init(allocator, .{
        .max_entities = 4096,
        .deferred_queue_capacity = 1024,
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

    var tenant = try tenant_mod.Tenant.init(allocator, root_kv, args.data_dir);
    defer tenant.deinit();

    // The main thread already created the instances + assigned domains
    // in the shared __root__.db before spawning us. We just need to
    // promote them into THIS worker's in-memory cache so `Worker.create`
    // can open their per-tenant stores eagerly.
    for (TENANT_IDS) |id| {
        try tenant.createInstance(id);
    }

    const worker = try Worker.create(allocator, &reg, .{
        .tenant = &tenant,
        .raft = args.raft,
        .addr = args.http_addr,
        .io_opts = .{
            .max_connections = 128,
            .buf_count = 128,
            .buf_size = 16384,
            .reuseport = true,
        },
        .code_addr = args.code_addr,
        .log_addr = args.log_addr,
        .log_worker_id = args.worker_idx,
    });
    defer worker.destroy();

    std.log.info("worker {d}: ready, listening on same port via SO_REUSEPORT", .{args.worker_idx});
    args.ready.set();

    while (!stop_flag.load(.acquire)) {
        // Bounded-wait poll. The worker has multiple pieces of
        // background state that need periodic attention regardless of
        // incoming I/O:
        //   - parked raft entries (drainRaftPending)
        //   - deployment refresh deadlines (refreshDeployments)
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

        // Code-server proxy: maintain the upstream session, forward
        // any parked /_system/code/* requests, map upstream responses
        // back onto their server-side peers. Order matters — ingest
        // before flush (so a connection that just came up is usable
        // in the same tick), and drain after flush (so responses
        // that came back in the same tick flow onward).
        try rjs.connectProxies(worker);
        try rjs.ingestProxyConnects(worker);
        try reg.flush();
        try rjs.flushProxyPending(worker);
        try reg.flush();
        try rjs.drainProxyResponses(worker);
        try reg.flush();

        try rjs.dispatchPending(worker);
        try reg.flush();
        try rjs.drainRaftPending(worker);
        try reg.flush();
        try rjs.cleanupResponses(worker);
        try reg.flush();
        try rjs.refreshDeployments(worker);
        // Best-effort log batch flush: drains each tenant's in-memory
        // buffer if any threshold (count/bytes/time) has been crossed
        // and proposes through raft (leader) or writes locally
        // (follower).
        try rjs.flushLogs(worker);
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

fn raftThreadMain(node: *kv.RaftNode) void {
    node.run(null) catch |err| {
        std.log.err("raft thread exited: {s}", .{@errorName(err)});
    };
}

// ── main ──────────────────────────────────────────────────────────────

pub fn main() !void {
    // c_allocator (glibc malloc) — NOT DebugAllocator. The latter
    // spends ~20% of CPU in stack-trace capture per alloc even in
    // ReleaseFast. See memory `feedback_zig_*` / session-9 notes.
    const allocator = std.heap.c_allocator;

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const cli = parseCli(argv) catch {
        var stderr_buf: [1024]u8 = undefined;
        var sw = std.fs.File.stderr().writer(&stderr_buf);
        try sw.interface.writeAll(
            \\usage: js-worker [opts]
            \\  --node-id <n>               index into --peers (default 0)
            \\  --peers <h:p,h:p,...>       raft peer list (default 127.0.0.1:40100)
            \\  --listen <host:port>        raft RPC listen (default 127.0.0.1:40100)
            \\  --http <host:port>          HTTP/2 listen (default 127.0.0.1:8082)
            \\  --data-dir <path>           per-node data dir (default /tmp/rove-js-data)
            \\  --fresh                     wipe data dir before start
            \\  --bootstrap-root-token HEX  seed the root auth token at startup
            \\  --workers <n>               number of worker threads (default 1)
            \\  --propose-linger-us <n>     raft proposal linger budget in µs (default 0 = off)
            \\
        );
        try sw.interface.flush();
        std.process.exit(2);
    };

    if (cli.fresh) {
        std.fs.cwd().deleteTree(cli.data_dir) catch {};
    }
    try std.fs.cwd().makePath(cli.data_dir);

    try installSignalHandlers();

    // ── One-time bootstrap: __root__ + instances + handler ────────────
    //
    // Done on the main thread so the workers only have to discover
    // pre-existing state on startup. Each worker will open its OWN
    // connections to these files when it spins up.
    {
        const root_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/__root__.db",
            .{cli.data_dir},
            0,
        );
        defer allocator.free(root_path);
        const root_kv = try kv.KvStore.open(allocator, root_path);
        defer root_kv.close();

        var tenant = try tenant_mod.Tenant.init(allocator, root_kv, cli.data_dir);
        defer tenant.deinit();

        if (cli.bootstrap_root_token) |t| {
            tenant.installRootToken(t) catch |err| {
                std.debug.print("bootstrap: installRootToken failed: {s}\n", .{@errorName(err)});
                std.process.exit(2);
            };
            std.debug.print("bootstrap: root token installed\n", .{});
        }

        try tenant.createInstance("acme");
        try tenant.createInstance("globex");
        try tenant.createInstance("penalty");
        try tenant.createInstance("readonly");
        try tenant.assignDomain("acme.test", "acme");
        try tenant.assignDomain("globex.test", "globex");
        try tenant.assignDomain("penalty.test", "penalty");
        try tenant.assignDomain("readonly.test", "readonly");

        // Write benchmark tenants — each one gets its own app.db and
        // therefore its own WAL writer lock, so parallel load across
        // them bypasses the per-tenant write ceiling.
        var wi: usize = 0;
        while (wi < NUM_WRITE_TENANTS) : (wi += 1) {
            var id_buf: [16]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buf, "write{d}", .{wi});
            var dom_buf: [32]u8 = undefined;
            const dom = try std.fmt.bufPrint(&dom_buf, "write{d}.test", .{wi});
            try tenant.createInstance(id);
            try tenant.assignDomain(dom, id);
        }

        // Bootstrap handler code on EVERY node. The bytecode is
        // content-addressed and the deploy is local-deterministic, so
        // all nodes independently end up with the same hashes — no
        // replication needed for code in M1.
        try bootstrapHandler(allocator, cli.data_dir, "acme", &.{
            .{ .path = "index.js", .source = ACME_INDEX },
            .{ .path = "api/index.js", .source = ACME_API_INDEX },
            .{ .path = "users/index.mjs", .source = ACME_USERS_MJS },
        });
        try bootstrapHandler(allocator, cli.data_dir, "globex", &.{
            .{ .path = "index.js", .source = GLOBEX_HANDLER },
        });
        try bootstrapHandler(allocator, cli.data_dir, "penalty", &.{
            .{ .path = "index.js", .source = PENALTY_HANDLER },
        });
        try bootstrapHandler(allocator, cli.data_dir, "readonly", &.{
            .{ .path = "index.js", .source = READONLY_HANDLER },
        });
        wi = 0;
        while (wi < NUM_WRITE_TENANTS) : (wi += 1) {
            var id_buf: [16]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buf, "write{d}", .{wi});
            try bootstrapHandler(allocator, cli.data_dir, id, &.{
                .{ .path = "index.js", .source = WRITE_BENCH_HANDLER },
            });
        }

        // Seed the readonly tenant's app.db with a value the handler
        // can read. Opens a throwaway kv connection directly to the
        // per-tenant app.db file; the workers will open their own
        // connections at startup and see this row via WAL.
        try seedReadonlyTenant(allocator, cli.data_dir);

        // Prewarm every tenant's app.db + log.db on the main thread
        // so the WAL-mode transition is committed before workers race
        // to open them. Without this, `--workers 8` occasionally kills
        // a worker with `error: JournalMode` because two openers try
        // to upgrade journal_mode=WAL at the same time.
        try prewarmTenantDbs(allocator, cli.data_dir);
    }

    // ── Subsystem threads (shared across workers) ──────────────────────
    //
    // Spawn BEFORE the workers so the workers can open client
    // connections to them during startup. Each owns its own rove
    // context (registry + io_uring + h2 server) and binds to a
    // loopback TCP ephemeral port.
    const cs_handle = try code_server.thread.spawn(allocator, cli.data_dir);
    defer cs_handle.shutdown();
    const code_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, cs_handle.port);

    const ls_handle = try log_server.thread.spawn(allocator, cli.data_dir);
    defer ls_handle.shutdown();
    const log_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, ls_handle.port);

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
        .raft_log_path = raft_log_path,
        .worker_count = 0,
        .propose_linger_ns = cli.propose_linger_us * std.time.ns_per_us,
    });
    defer raft_node.deinit();

    apply_ctx = rjs.apply.ApplyCtx.init(allocator, cli.data_dir, raft_node);
    defer apply_ctx.deinit();

    var raft_thread = try std.Thread.spawn(.{}, raftThreadMain, .{raft_node});
    raft_thread.detach();

    // ── Spawn worker threads ───────────────────────────────────────────
    const http_addr = try parseHostPort(allocator, cli.http);

    const ctxs = try allocator.alloc(WorkerCtx, cli.workers);
    defer allocator.free(ctxs);
    const threads = try allocator.alloc(std.Thread, cli.workers);
    defer allocator.free(threads);
    const ready_events = try allocator.alloc(std.Thread.ResetEvent, cli.workers);
    defer allocator.free(ready_events);
    for (ready_events) |*ev| ev.* = .{};

    var i: u16 = 0;
    while (i < cli.workers) : (i += 1) {
        ctxs[i] = .{
            .allocator = allocator,
            .worker_idx = i,
            .data_dir = cli.data_dir,
            .http_addr = http_addr,
            .raft = raft_node,
            .code_addr = code_addr,
            .log_addr = log_addr,
            .ready = &ready_events[i],
        };
        threads[i] = try std.Thread.spawn(.{}, workerThreadEntry, .{&ctxs[i]});
    }
    for (ready_events) |*ev| ev.wait();

    std.debug.print(
        "rove-js worker node {d} listening on http://{s} (h2c)\n" ++
            "  workers:    {d} (SO_REUSEPORT)\n" ++
            "  data dir:   {s}\n" ++
            "  raft:       node {d} of {d} @ {s}\n" ++
            "  peers:      {s}\n" ++
            "  instances:  acme (counter), globex (echo), penalty (while(true))\n" ++
            "  domains:    acme.test, globex.test, penalty.test\n",
        .{ cli.node_id, cli.http, cli.workers, cli.data_dir, cli.node_id, peers.len, cli.listen, cli.peers },
    );

    // Block until SIGINT/SIGTERM flips stop_flag, then join workers.
    // 50ms poll granularity is invisible to shutdown perception and
    // costs nothing.
    while (!stop_flag.load(.acquire)) {
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    std.log.info("js-worker: shutdown requested, joining {d} worker(s)", .{cli.workers});
    for (threads) |t| t.join();
    std.log.info("js-worker: bye", .{});

    // Skip the teardown chain. The raft thread is detached and still
    // inside `node.run()`; running `raft_node.deinit()` out from under
    // it would segfault. Subsystem threads (code-server, log-server)
    // would also need a join story before it's safe to free their
    // handles. The pragmatic answer is `_exit(0)` — same as nginx,
    // envoy, etc.: the kernel reclaims memory + fds + sockets in one
    // shot and we avoid re-implementing a clean teardown graph for
    // every subsystem.
    std.process.exit(0);
}

/// Compile `source` for an instance and publish it as the current
/// deployment through that tenant's code store. Mirrors what
/// `rove-code-cli upload index.js && rove-code-cli deploy` would do
/// externally; kept inline so the smoke test is a single binary.
const HandlerFile = struct { path: []const u8, source: []const u8 };

fn bootstrapHandler(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    instance_id: []const u8,
    files: []const HandlerFile,
) !void {
    const inst_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, instance_id });
    defer allocator.free(inst_dir);
    try std.fs.cwd().makePath(inst_dir);

    const code_db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/code.db", .{inst_dir}, 0);
    defer allocator.free(code_db_path);

    const code_blob_dir = try std.fmt.allocPrint(allocator, "{s}/code-blobs", .{inst_dir});
    defer allocator.free(code_blob_dir);

    const code_kv = try kv.KvStore.open(allocator, code_db_path);
    defer code_kv.close();
    var fs_store = try blob_mod.FilesystemBlobStore.open(allocator, code_blob_dir);
    defer fs_store.deinit();

    // Real qjs compile so the stored bytecode is real.
    var compiler = try QjsCompiler.init();
    defer compiler.deinit();

    var store = code_mod.CodeStore.init(
        allocator,
        code_kv,
        fs_store.blobStore(),
        QjsCompiler.compile,
        &compiler,
    );

    for (files) |f| try store.putSource(f.path, f.source);
    _ = try store.deploy();
}

/// Pre-seed the readonly tenant's per-tenant `app.db` with a row the
/// benchmark handler reads. Opens a throwaway direct kv connection,
/// writes one row, closes it. The workers open their own connections
/// later and see this row via SQLite WAL.
fn seedReadonlyTenant(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
) !void {
    const inst_dir = try std.fmt.allocPrint(allocator, "{s}/readonly", .{data_dir});
    defer allocator.free(inst_dir);
    try std.fs.cwd().makePath(inst_dir);

    const app_db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/app.db",
        .{inst_dir},
        0,
    );
    defer allocator.free(app_db_path);

    const app_kv = try kv.KvStore.open(allocator, app_db_path);
    defer app_kv.close();
    try app_kv.put("greeting", "hello");
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
) !void {
    for (TENANT_IDS) |id| {
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

/// Inline qjs compile hook — identical to the one in code_cli.zig.
/// Duplicating it here keeps the smoke test self-contained; the
/// production path reuses code_cli's helper.
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
        // Treat `.mjs` files as ES modules; everything else compiles
        // as a plain script. Extension is the source of truth — the
        // rove-code-cli rewrite will apply the same rule.
        const kind: qjs.EvalFlags = if (std.mem.endsWith(u8, filename, ".mjs"))
            .{ .kind = .module }
        else
            .{};
        return self.context.compileToBytecode(source, filename, allocator, kind);
    }
};
