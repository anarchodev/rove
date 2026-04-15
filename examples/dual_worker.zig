//! `dual-worker` — de-risking spike for the shift-js shared-nothing
//! multi-worker model on rove.
//!
//! Spawns **two full rove-js worker instances** in one process, each
//! in its own thread. Both bind the same HTTP/2 port via
//! `SO_REUSEPORT`; the kernel hashes incoming connections across them.
//! Each worker owns its own:
//!
//!   - rove `Registry`
//!   - rove-io `Io` / rove-h2 `H2` instance (its own io_uring ring + fds)
//!   - `Tenant` (its own `__root__.db` sqlite connection)
//!   - per-tenant `KvStore` + `LogStore` connections (via `TenantCode` /
//!     `TenantLog` caches — every worker opens its own to avoid
//!     sharing NOMUTEX sqlite handles across threads)
//!   - qjs runtime (via the `Dispatcher`)
//!   - penalty box, proxy state, raft-pending collection
//!
//! Shared between workers (all thread-safe):
//!
//!   - the single `RaftNode` (proposes go through its MPSC queue;
//!     committedSeq/faultedSeq are atomics)
//!   - the single raft-owned `ApplyCtx` (only the raft thread touches
//!     its cached stores; workers never do)
//!   - the code-server + log-server subsystem threads (workers talk
//!     to them via their own h2 client sessions)
//!
//! The point of this binary: prove the "every worker isolated, one
//! raft thread" pattern works. **No tenant pinning** — any worker
//! handles any tenant. SQLite WAL lets multiple worker connections
//! to the same per-tenant file coexist.
//!
//! Usage:
//!     dual-worker --data-dir /tmp/dual \
//!                 --http 127.0.0.1:8200 \
//!                 --bootstrap-root-token <hex>
//!
//! Smoke test: curl against the port many times; each worker logs
//! its own id when it serves a request, so you can see the kernel
//! distributing across them.

const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const rjs = @import("rove-js");
const kv = @import("rove-kv");
const blob_mod = @import("rove-blob");
const code_mod = @import("rove-code");
const code_server = @import("rove-code-server");
const log_server = @import("rove-log-server");
const qjs = @import("rove-qjs");
const tenant_mod = @import("rove-tenant");

/// ACME handler reads+bumps `hits`. The body includes the counter
/// so the smoke test can see monotonic progress across both workers.
/// Every handler invocation ALSO runs `console.log` with the hit
/// count so the test can distribute-count by tailing per-worker logs.
const ACME_INDEX =
    \\response.status = 200;
    \\response.body = "echo\n";
;

const Cli = struct {
    http: []const u8 = "127.0.0.1:8200",
    raft_listen: []const u8 = "127.0.0.1:40200",
    data_dir: []const u8 = "/tmp/rove-dual",
    fresh: bool = false,
    bootstrap_root_token: ?[]const u8 = null,
};

fn parseCli(argv: [][:0]u8) !Cli {
    var out: Cli = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--http")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.http = argv[i];
        } else if (std.mem.eql(u8, a, "--raft-listen")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.raft_listen = argv[i];
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

const Worker = rjs.Worker(.{});

/// Per-worker state assembled on the worker thread itself. Everything
/// in here is thread-local: allocating in the worker thread keeps
/// the rove registry's allocations co-located for cache locality.
const WorkerCtx = struct {
    allocator: std.mem.Allocator,
    worker_idx: u16,
    data_dir: []const u8,
    http_addr: std.net.Address,
    raft: *kv.RaftNode,
    code_addr: std.net.Address,
    log_addr: std.net.Address,
    ready: *std.Thread.ResetEvent,
    /// Per-worker sentinel the main thread flips on SIGTERM to
    /// request graceful shutdown.
    stop: *std.atomic.Value(bool),
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
    for (&[_][]const u8{ "acme", "globex" }) |id| {
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

    while (!args.stop.load(.acquire)) {
        try worker.pollWithTimeout(1 * std.time.ns_per_ms);

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
        try rjs.flushLogs(worker);
    }

    std.log.info("worker {d}: shutting down", .{args.worker_idx});
}

fn workerThreadEntry(args: *WorkerCtx) void {
    workerMain(args) catch |err| {
        std.log.err("worker {d}: exited with error: {s}", .{ args.worker_idx, @errorName(err) });
        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        args.ready.set();
    };
}

fn raftThreadMain(node: *kv.RaftNode) void {
    node.run(null) catch |err| {
        std.log.err("raft thread: {s}", .{@errorName(err)});
    };
}

// ── Handler bootstrap (copy-pasted from js_worker) ────────────────────

fn bootstrapHandler(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    instance_id: []const u8,
    source: []const u8,
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

    var compiler = try QjsCompiler.init();
    defer compiler.deinit();

    var store = code_mod.CodeStore.init(
        allocator,
        code_kv,
        fs_store.blobStore(),
        QjsCompiler.compile,
        &compiler,
    );
    try store.putSource(rjs.DEFAULT_HANDLER_PATH, source);
    _ = try store.deploy();
}

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
        const flags: qjs.EvalFlags = if (std.mem.endsWith(u8, filename, ".mjs"))
            .{ .kind = .module }
        else
            .{};
        return self.context.compileToBytecode(source, filename, allocator, flags);
    }
};

// ── main ──────────────────────────────────────────────────────────────

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const cli = parseCli(argv) catch {
        var stderr_buf: [1024]u8 = undefined;
        var sw = std.fs.File.stderr().writer(&stderr_buf);
        try sw.interface.writeAll(
            \\usage: dual-worker [opts]
            \\  --http <host:port>            HTTP/2 listen (default 127.0.0.1:8200)
            \\  --raft-listen <host:port>     raft RPC listen (default 127.0.0.1:40200)
            \\  --data-dir <path>             per-node data dir (default /tmp/rove-dual)
            \\  --fresh                       wipe data dir before start
            \\  --bootstrap-root-token HEX    seed the root auth token
            \\
        );
        try sw.interface.flush();
        std.process.exit(2);
    };

    if (cli.fresh) std.fs.cwd().deleteTree(cli.data_dir) catch {};
    try std.fs.cwd().makePath(cli.data_dir);

    // ── One-time bootstrap: __root__ + instances + handler ────────────
    //
    // Done here (on the main thread) so the workers only have to
    // discover pre-existing state on startup. Each worker will open
    // its OWN connections to these files when it spins up.
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
            try tenant.installRootToken(t);
            std.debug.print("bootstrap: root token installed\n", .{});
        }

        try tenant.createInstance("acme");
        try tenant.createInstance("globex");
        try tenant.assignDomain("acme.test", "acme");
        try tenant.assignDomain("globex.test", "globex");

        try bootstrapHandler(allocator, cli.data_dir, "acme", ACME_INDEX);
        try bootstrapHandler(allocator, cli.data_dir, "globex", ACME_INDEX);
    }

    // ── Subsystem threads (shared across workers) ──────────────────────
    const cs_handle = try code_server.thread.spawn(allocator, cli.data_dir);
    defer cs_handle.shutdown();
    const code_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, cs_handle.port);

    const ls_handle = try log_server.thread.spawn(allocator, cli.data_dir);
    defer ls_handle.shutdown();
    const log_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, ls_handle.port);

    // ── Raft setup (single node, single raft thread, single ApplyCtx) ──
    //
    // The ApplyCtx is raft-thread-local; both workers call propose()
    // against the same RaftNode but never touch the apply-side stores.
    var apply_ctx: rjs.apply.ApplyCtx = undefined;

    const listen_addr = try parseHostPort(allocator, cli.raft_listen);
    const raft_peers = try allocator.alloc(kv.RaftPeerAddr, 1);
    defer allocator.free(raft_peers);
    raft_peers[0] = .{
        .host = try allocator.dupe(u8, "127.0.0.1"),
        .port = listen_addr.getPort(),
    };
    defer allocator.free(raft_peers[0].host);

    const raft_log_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/raft.log.db",
        .{cli.data_dir},
        0,
    );
    defer allocator.free(raft_log_path);

    const raft_node = try kv.RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = raft_peers,
        .listen_addr = listen_addr,
        .apply = .{
            .opaque_bytes = .{
                .apply_fn = rjs.apply.applyOne,
                .ctx = &apply_ctx,
            },
        },
        .raft_log_path = raft_log_path,
        .worker_count = 0,
    });
    defer raft_node.deinit();

    apply_ctx = rjs.apply.ApplyCtx.init(allocator, cli.data_dir, raft_node);
    defer apply_ctx.deinit();

    var raft_thread = try std.Thread.spawn(.{}, raftThreadMain, .{raft_node});
    raft_thread.detach();

    // ── Spawn workers ──────────────────────────────────────────────────
    const http_addr = try parseHostPort(allocator, cli.http);

    var stop_flag = std.atomic.Value(bool).init(false);

    const num_workers: u16 = 2;
    var ready_events: [2]std.Thread.ResetEvent = .{ .{}, .{} };
    var ctxs: [2]WorkerCtx = undefined;
    var threads: [2]std.Thread = undefined;

    var i: u16 = 0;
    while (i < num_workers) : (i += 1) {
        ctxs[i] = .{
            .allocator = allocator,
            .worker_idx = i,
            .data_dir = cli.data_dir,
            .http_addr = http_addr,
            .raft = raft_node,
            .code_addr = code_addr,
            .log_addr = log_addr,
            .ready = &ready_events[i],
            .stop = &stop_flag,
        };
        threads[i] = try std.Thread.spawn(.{}, workerThreadEntry, .{&ctxs[i]});
    }
    for (&ready_events) |*ev| ev.wait();

    std.debug.print(
        "dual-worker: 2 workers sharing http://{s} (SO_REUSEPORT)\n" ++
            "  data dir:   {s}\n" ++
            "  raft:       single node @ {s}\n" ++
            "  instances:  acme, globex\n",
        .{ cli.http, cli.data_dir, cli.raft_listen },
    );

    // Idle — workers run until SIGINT. A real daemon would install a
    // signal handler that flips stop_flag; for the spike we just
    // block forever and let the user Ctrl-C.
    while (true) std.Thread.sleep(1 * std.time.ns_per_s);
}
