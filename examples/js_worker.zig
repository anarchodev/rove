//! `js-worker` — end-to-end smoke test for the rove-js worker with
//! raft replication AND per-tenant code loading from `rove-code-cli`.
//!
//! ## What this binary demonstrates
//!
//! Single-node raft cluster. Two tenants (`acme`, `globex`) each with
//! their own SQLite files under `{data_dir}/{id}/`:
//!
//!   /tmp/rove-js-data/
//!     __root__.db                  tenant metadata (domain → instance)
//!     raft.log.db                  shared raft log (node-scoped)
//!     acme/
//!       app.db                     acme's handler state
//!       code.db                    acme's code index (deployments)
//!       code-blobs/                acme's source + bytecode blobs
//!     globex/
//!       app.db
//!       code.db
//!       code-blobs/
//!
//! The handler source for each tenant is bootstrapped from inline
//! snippets via direct `rove-code` calls (so the smoke test is a
//! single-binary flow). In a real deployment you'd `rove-code-cli
//! upload` + `deploy` separately and the worker would discover the
//! new bytecode via `refreshDeployments` polling.
//!
//! acme's handler is a hit counter; globex's handler echoes the path.
//! Curl with different `Host:` headers shows the two tenants running
//! completely different code against completely isolated state.
//!
//! Known session-7 limitations still in effect:
//!   - Single-node raft. Multi-node bringup is task #35.
//!   - Poll loop uses a crude `sleep(1ms)` when parked entries are
//!     waiting. Task #33.
//!   - No startup undo sweep for orphan kv_undo entries. Task #34.

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

const Cli = struct {
    node_id: u32 = 0,
    /// Comma-separated `host:port` list. Position determines node_id.
    peers: []const u8 = "127.0.0.1:40100",
    /// `host:port` this node listens on for raft RPCs. Must match the
    /// peers entry at index `node_id`.
    listen: []const u8 = "127.0.0.1:40100",
    /// HTTP/2 listen address.
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

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const cli = parseCli(argv) catch {
        var stderr_buf: [1024]u8 = undefined;
        var sw = std.fs.File.stderr().writer(&stderr_buf);
        try sw.interface.writeAll(
            \\usage: js-worker [opts]
            \\  --node-id <n>           index into --peers (default 0)
            \\  --peers <h:p,h:p,...>   raft peer list (default 127.0.0.1:40100)
            \\  --listen <host:port>    raft RPC listen (default 127.0.0.1:40100)
            \\  --http <host:port>      HTTP/2 listen (default 127.0.0.1:8082)
            \\  --data-dir <path>       per-node data dir (default /tmp/rove-js-data)
            \\  --fresh                 wipe data dir before start
            \\  --bootstrap-root-token HEX   seed the root auth token at startup
            \\
        );
        try sw.interface.flush();
        std.process.exit(2);
    };

    if (cli.fresh) {
        std.fs.cwd().deleteTree(cli.data_dir) catch {};
    }
    try std.fs.cwd().makePath(cli.data_dir);

    var reg = try rove.Registry.init(allocator, .{
        .max_entities = 4096,
        .deferred_queue_capacity = 1024,
    });
    defer reg.deinit();

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
    try tenant.assignDomain("acme.test", "acme");
    try tenant.assignDomain("globex.test", "globex");
    try tenant.assignDomain("penalty.test", "penalty");

    // Bootstrap handler code on EVERY node. The bytecode is content-
    // addressed and the deploy is local-deterministic, so all nodes
    // independently end up with the same hashes — no replication
    // needed for code in M1. (Real production: a code-server pushes
    // deployments to every worker. Out of scope here.)
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

    // ── Raft setup ─────────────────────────────────────────────────────
    //
    // ApplyCtx is raft-thread-local: it owns its own per-tenant sqlite
    // connections, opened lazily on follower applies. These are
    // DISTINCT from any worker's connections, so the raft thread and
    // the worker thread never share a NOMUTEX sqlite connection.
    //
    // Chicken-and-egg: ApplyCtx needs a `*RaftNode`, RaftNode needs
    // an apply ctx pointer. Workaround: construct RaftNode first with
    // a sentinel ctx, then once init returns patch the real ctx's
    // `raft` field and swap the callback pointer before spawning the
    // raft thread. (Same pattern as before, just without the extra
    // `log_lookup` patch.)
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
    });
    defer raft_node.deinit();

    apply_ctx = rjs.apply.ApplyCtx.init(allocator, cli.data_dir, raft_node);
    defer apply_ctx.deinit();

    // ── Code-server + log-server threads ──────────────────────────────
    //
    // Spawn both subsystem threads BEFORE the worker so the worker
    // can open client connections to them during startup. Each owns
    // its own rove context (registry + io_uring + h2 server) and
    // binds to a loopback TCP ephemeral port. The worker talks to
    // them as two independent HTTP/2 clients.
    const cs_handle = try code_server.thread.spawn(allocator, cli.data_dir);
    defer cs_handle.shutdown();
    const code_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, cs_handle.port);

    const ls_handle = try log_server.thread.spawn(allocator, cli.data_dir);
    defer ls_handle.shutdown();
    const log_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, ls_handle.port);

    // ── HTTP/2 worker ──────────────────────────────────────────────────

    const http_addr = try parseHostPort(allocator, cli.http);
    const Worker = rjs.Worker(.{});
    const worker = try Worker.create(allocator, &reg, .{
        .tenant = &tenant,
        .raft = raft_node,
        .addr = http_addr,
        .io_opts = .{ .max_connections = 256, .buf_count = 256, .buf_size = 16384 },
        .code_addr = code_addr,
        .log_addr = log_addr,
    });
    defer worker.destroy();

    // Now spawn the raft thread.
    var raft_thread = try std.Thread.spawn(.{}, raftThreadMain, .{raft_node});
    raft_thread.detach();

    std.debug.print(
        "rove-js worker node {d} listening on http://{s} (h2c)\n" ++
            "  data dir:   {s}\n" ++
            "  raft:       node {d} of {d} @ {s}\n" ++
            "  peers:      {s}\n" ++
            "  instances:  acme (counter), globex (echo), penalty (while(true))\n" ++
            "  domains:    acme.test, globex.test, penalty.test\n",
        .{ cli.node_id, cli.http, cli.data_dir, cli.node_id, peers.len, cli.listen, cli.peers },
    );

    while (true) {
        // Always use a bounded-wait poll. The worker has multiple
        // pieces of background state that need periodic attention
        // regardless of incoming I/O:
        //   - parked raft entries (drainRaftPending)
        //   - deployment refresh deadlines (refreshDeployments)
        //   - buffered log records waiting on a flush threshold (flushLogs)
        // The cheapest correct shape is: every poll has a deadline,
        // the loop body runs at least that often, and idle CPU stays
        // negligible because each tick is microseconds.
        try worker.pollWithTimeout(100 * std.time.ns_per_ms);

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
}

fn raftThreadMain(node: *kv.RaftNode) void {
    node.run(null) catch |err| {
        std.log.err("raft thread exited: {s}", .{@errorName(err)});
    };
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
