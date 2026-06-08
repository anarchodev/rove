//! rewind — the V2 single-node worker binary (docs/v2-build-order.md
//! §Phase 2 "a v2 worker binary"). Named for the product (rewind.js) that
//! V2 is the engine for; it is the V2 counterpart of V1's `loop46`.
//!
//! It wires the reused rove-js worker stack (h2 + arenajs/qjs dispatcher +
//! blob/tenant/deploy) onto the V2 per-tenant raft **bridge** instead of
//! V1's cluster-wide `kv.Cluster` + willemt raft thread:
//!
//!   bridge.initSingleNode → setWorkerOverlay → startPump   (the pump thread)
//!   NodeState.init(tenant, blob_cfg, bridge)             (shared node state)
//!   Worker.create(.{ .raft = bridge, … })                (one worker thread)
//!
//! Single node: the bridge is leader of every tenant group, leader-skip
//! apply means the worker's `TrackedTxn.commit` is the durable write, and
//! the worker parks `RaftWait{group_id, seq}` polling the per-tenant
//! watermark. Multi-node/HA is Phase 5; this is the mobility-path slice.

const std = @import("std");
const rove = @import("rove");
const rjs = @import("rove-js");
const bridge_mod = @import("bridge");
const kv = @import("raft-kv");
const h2_mod = @import("rove-h2");
const blob_mod = @import("rove-blob");
const tenant_mod = @import("rove-tenant");
const qjs = @import("rove-qjs");
const log_server = @import("rove-log-server");
const files_mod = @import("rove-files");

const Bridge = bridge_mod.Bridge;
const Worker = rjs.Worker(.{});

/// 2e smoke: the host the admin surface answers on + the root bearer.
/// Overridable via env (`REWIND_ADMIN_DOMAIN` / `REWIND_ROOT_TOKEN`) so a
/// two-cluster Phase-3 deployment can give each cluster a DISTINCT admin
/// domain — the front-door routing proof keys off "Host matches this
/// cluster's admin domain → 204, else mismatch" (two_cluster_smoke.py).
const DEFAULT_ADMIN_API_DOMAIN = "admin.localhost";
const DEFAULT_ADMIN_ROOT_TOKEN = "rewindtestroottokenpadding0123456789abcd";

// ── Signal-driven shutdown ────────────────────────────────────────────
var stop_flag: std.atomic.Value(bool) = .init(false);

fn handleSignal(_: c_int) callconv(.c) void {
    stop_flag.store(true, .release);
}

fn installSignalHandlers() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

// ── Per-worker QuickJS compiler (mirrors loop46/main.zig) ─────────────
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

// ── Worker thread ─────────────────────────────────────────────────────
const WorkerCtx = struct {
    allocator: std.mem.Allocator,
    worker_idx: u16,
    http_addr: std.net.Address,
    raft: *Bridge,
    node: *rjs.NodeState,
    log_batch_store: log_server.batch_store.BatchStore,
    data_dir: []const u8,
    admin_api_domain: []const u8,
    move_secret: ?[]const u8,
    cluster_id: ?[]const u8,
    cp_urls: []const []const u8,
    ready: *std.Thread.ResetEvent,
};

fn workerThreadEntry(args: *WorkerCtx) void {
    workerMain(args) catch |err| {
        std.log.err("rewind worker {d} exited: {s}", .{ args.worker_idx, @errorName(err) });
    };
}

fn workerMain(args: *WorkerCtx) !void {
    const allocator = args.allocator;

    var compiler = try QjsCompiler.init();
    defer compiler.deinit();

    var reg = try rove.Registry.init(allocator, .{
        .max_entities = 65536,
        .deferred_queue_capacity = 4096,
    });
    defer reg.deinit();

    const worker = try Worker.create(allocator, &reg, .{
        .node = args.node,
        .raft = args.raft,
        .addr = args.http_addr,
        .io_opts = .{
            .max_connections = 4096,
            .buf_count = 4096,
            .buf_size = 16384,
            .listen_backlog = 4096,
            .reuseport = true,
        },
        .h2_opts = .{
            .max_concurrent_streams = 512,
            .initial_window_size = 1024 * 1024,
            .max_frame_size = 16384,
            .tls_config = null,
        },
        .log_worker_id = args.worker_idx,
        .admin_api_domain = args.admin_api_domain,
        .rate_limit_caps = .{},
        .compile_fn = QjsCompiler.compile,
        .compile_ctx = &compiler,
        .log_batch_store = args.log_batch_store,
        .data_dir = args.data_dir,
        .move_secret = args.move_secret,
        .cluster_id = args.cluster_id,
        .cp_urls = args.cp_urls,
    });
    defer worker.destroy();

    std.log.info("rewind worker {d}: ready (SO_REUSEPORT)", .{args.worker_idx});
    args.ready.set();

    var blocked_tenants: rjs.BlockedTenants = .{};
    while (!stop_flag.load(.acquire)) {
        worker.pollWithTimeout(1 * std.time.ns_per_ms) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };

        try rjs.drainBodyPending(worker);
        try rjs.drainFetchPendingDurability(worker);
        _ = try rjs.dispatchOnce(worker, &blocked_tenants);
        try rjs.drainRaftPending(worker);
        try rjs.drainForwardPending(worker);
        rjs.drainSpools(worker);
        try rjs.sweepParkedContinuations(worker);
        try rjs.serviceParkedStreams(worker);
        // docs/websocket-plan.md §4.5/§5 (piece D): dispatch inbound WS
        // frames (h2 `ws_message_out`) to the held chain's `onMessage` /
        // `onDisconnect` and lower outbound `stream.write`s to `ws_send_in`.
        // Writing frames stage commit-gated sends (drained on the next
        // tick's `drainRaftPending`); read-only frames emit inline.
        try rjs.serviceWsMessages(worker);
        try rjs.cleanupResponses(worker);
        rjs.sweepCronSubscriptions(worker);
        rjs.sweepOwedRetries(worker);
        rjs.sweepDurableWakes(worker);
        rjs.serviceSubscriptionFires(worker);
        rjs.drainPendingBoundResumes(worker);
        rjs.serviceFetchEvents(worker);
    }
}

// ── Full-HA follower-apply store resolver ─────────────────────────────

/// `bridge.StoreResolver.func`: resolve the worker's per-tenant serving
/// store (`inst.kv`) for a follower's replicated apply, provisioning the
/// instance on first sight. Runs on the pump thread; `Tenant` is internally
/// locked (`maps_mutex`), so on-demand provisioning is safe alongside the
/// worker thread. `gid` is unused — the worker keys its instance store on
/// the tenant id string the envelope carries. Returns null only on a
/// provisioning failure (surfaced by the apply round as `UnknownGroup`).
fn resolveTenantStore(ctx: *anyopaque, gid: u64, id_str: []const u8) ?*kv.KvStore {
    _ = gid;
    const tenant: *tenant_mod.Tenant = @ptrCast(@alignCast(ctx));
    if (tenant.getInstance(id_str) catch null) |inst| return inst.kv;
    tenant.createInstance(id_str) catch return null;
    const inst = (tenant.getInstance(id_str) catch null) orelse return null;
    return inst.kv;
}

// ── Multi-node (Phase 5) config ───────────────────────────────────────

/// Parsed multi-node bridge config (Phase 5 HA), owned for the lifetime of
/// the `initMultiNode` call. `null` when this is a single-node deployment.
const MultiNode = struct {
    node_id: u64,
    voters: []u64,
    peers: []bridge_mod.PeerAddr,
    /// Backing storage for the peer host slices (`host:port` left of `:`).
    peer_bufs: [][]u8,
    listen_addr: std.net.Address,
    listen_str: []u8,

    fn deinit(self: *const MultiNode, a: std.mem.Allocator) void {
        a.free(self.voters);
        a.free(self.peers);
        for (self.peer_bufs) |b| a.free(b);
        a.free(self.peer_bufs);
        a.free(self.listen_str);
    }
};

/// Build multi-node config from env, or return null if `REWIND_NODE_ID` is
/// unset (single-node). Required together:
///   - `REWIND_NODE_ID`   this node's 1-based raft id (∈ the voter set).
///   - `REWIND_VOTERS`    comma-separated voter ids, e.g. `1,2,3`.
///   - `REWIND_PEERS`     comma-separated raft transport `host:port`s,
///                        indexed by raft id − 1 (peer i ⇒ raft id i+1).
///                        These are the cross-node consensus ports, DISTINCT
///                        from the HTTP listen port (argv[2]).
/// The listen address is `peers[node_id − 1]`. Errors on malformed /
/// inconsistent config (a misconfigured cluster must fail loud at startup).
fn parseMultiNode(a: std.mem.Allocator) !?MultiNode {
    const node_id_s = std.posix.getenv("REWIND_NODE_ID") orelse return null;
    const voters_s = std.posix.getenv("REWIND_VOTERS") orelse return error.MissingVoters;
    const peers_s = std.posix.getenv("REWIND_PEERS") orelse return error.MissingPeers;

    const node_id = try std.fmt.parseInt(u64, std.mem.trim(u8, node_id_s, " \t"), 10);

    var voters: std.ArrayListUnmanaged(u64) = .empty;
    errdefer voters.deinit(a);
    var vit = std.mem.tokenizeScalar(u8, voters_s, ',');
    while (vit.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (t.len == 0) continue;
        try voters.append(a, try std.fmt.parseInt(u64, t, 10));
    }
    if (voters.items.len == 0) return error.MissingVoters;

    var peers: std.ArrayListUnmanaged(bridge_mod.PeerAddr) = .empty;
    errdefer peers.deinit(a);
    var peer_bufs: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (peer_bufs.items) |b| a.free(b);
        peer_bufs.deinit(a);
    }
    var pit = std.mem.tokenizeScalar(u8, peers_s, ',');
    while (pit.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (t.len == 0) continue;
        const colon = std.mem.lastIndexOfScalar(u8, t, ':') orelse return error.BadPeer;
        const host = try a.dupe(u8, t[0..colon]);
        errdefer a.free(host);
        const port = try std.fmt.parseInt(u16, t[colon + 1 ..], 10);
        try peer_bufs.append(a, host);
        try peers.append(a, .{ .host = host, .port = port });
    }
    if (node_id == 0 or node_id > peers.items.len) return error.BadNodeId;

    const listen = peers.items[node_id - 1];
    const listen_addr = try std.net.Address.parseIp(listen.host, listen.port);
    const listen_str = try std.fmt.allocPrint(a, "{s}:{d}", .{ listen.host, listen.port });

    return MultiNode{
        .node_id = node_id,
        .voters = try voters.toOwnedSlice(a),
        .peers = try peers.toOwnedSlice(a),
        .peer_bufs = try peer_bufs.toOwnedSlice(a),
        .listen_addr = listen_addr,
        .listen_str = listen_str,
    };
}

/// Parse a `;`/`,`-separated list of origins into an owned, owned-element
/// slice (a single URL → a one-element list; empty input → empty slice).
fn parseUrlList(a: std.mem.Allocator, config: []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (list.items) |u| a.free(u);
        list.deinit(a);
    }
    var it = std.mem.tokenizeAny(u8, config, ";,");
    while (it.next()) |raw| {
        const url = std.mem.trim(u8, raw, " \t\r\n");
        if (url.len == 0) continue;
        try list.append(a, try a.dupe(u8, url));
    }
    return list.toOwnedSlice(a);
}

fn freeUrlList(a: std.mem.Allocator, urls: []const []const u8) void {
    for (urls) |u| a.free(u);
    a.free(urls);
}

// ── main ──────────────────────────────────────────────────────────────
pub fn main() !void {
    // rove uses libc malloc globally (multiraft-scaling-learnings §3.6 —
    // GPA's global mutex is the wall under multi-raft).
    const allocator = std.heap.c_allocator;

    installSignalHandlers();

    var arg_it = std.process.args();
    _ = arg_it.next(); // argv[0]
    const data_dir = arg_it.next() orelse "/tmp/rewind-data";
    const port_str = arg_it.next() orelse "8080";
    const port = try std.fmt.parseInt(u16, port_str, 10);

    try std.fs.cwd().makePath(data_dir);

    const admin_api_domain = std.posix.getenv("REWIND_ADMIN_DOMAIN") orelse DEFAULT_ADMIN_API_DOMAIN;
    const admin_root_token = std.posix.getenv("REWIND_ROOT_TOKEN") orelse DEFAULT_ADMIN_ROOT_TOKEN;
    // V2 Phase 4 — shared secret for the cluster-internal tenant-move
    // surface (`/_system/v2-*`). The front door presents it as
    // `X-Rewind-Move-Secret`. Unset → the move surface is disabled.
    const move_secret = std.posix.getenv("REWIND_MOVE_SECRET");
    // V2 Phase 7 — serve-or-forward: this cluster's id + the control-plane
    // base URL. Set together; either unset → a local tenant miss 404s (no
    // forwarding). A DP that can't serve a tenant locally asks the CP who
    // owns it and forwards there.
    const cluster_id = std.posix.getenv("REWIND_CLUSTER_ID");
    // A LIST of CP node URLs (HA): `REWIND_CP_URL` accepts `;`/`,`-separated
    // origins (a single URL is just a one-element list). The worker tries each
    // until one answers, so a CP node failure never breaks serve-or-forward.
    const cp_urls = try parseUrlList(allocator, std.posix.getenv("REWIND_CP_URL") orelse "");
    defer freeUrlList(allocator, cp_urls);

    // Blob backend (fs or s3) — process-wide, env-selected.
    var blob_owned = try blob_mod.env.loadFromEnv(allocator);
    defer blob_owned.deinit(allocator);

    // Node-wide root store + seq counters + tenant registry. In V2 the
    // worker opens the root store directly (no cluster.openRoot).
    const root_kv = try kv.KvStore.openClusterOwned(allocator, data_dir, "cluster.kv", "__root__");
    var seq_counters = kv.SeqCounterRegistry.init(allocator);
    defer seq_counters.deinit();
    const node_tenant = try tenant_mod.Tenant.createWithCounters(allocator, root_kv, data_dir, &seq_counters);
    defer node_tenant.destroy();
    try node_tenant.createInstance(tenant_mod.ADMIN_INSTANCE_ID);
    // 2e exit-smoke wiring: a root bearer so `/_system/admin-kv` (the
    // built-in envelope-0 write path) is reachable, exercising propose →
    // bridge commit → worker txn.commit end to end on a single node.
    node_tenant.root_token_secret = admin_root_token;
    // Wildcard tenant routing: `REWIND_PUBLIC_SUFFIX=<suffix>` lets the worker
    // resolve `{instance_id}.{suffix}` → that instance without an explicit
    // `domain/` alias (the V1 `rewindjsapp.localhost` pattern). The front routes
    // the host to this cluster via the CP directory; the worker then resolves
    // the proxied host locally. Unset = wildcard disabled (explicit aliases only).
    if (std.posix.getenv("REWIND_PUBLIC_SUFFIX")) |suffix| {
        if (suffix.len > 0) try node_tenant.setPublicSuffix(suffix);
    }

    // The V2 per-tenant raft bridge + its pump thread. Leader-skip: the
    // worker owns the speculative overlay. Single node by default; a
    // multi-node (Phase 5 HA) node is configured by env — this node's
    // 1-based raft id, the voter set, and the per-node raft transport
    // addresses (distinct from the HTTP port). See `parseMultiNode`.
    const bridge = if (try parseMultiNode(allocator)) |mn| blk: {
        defer mn.deinit(allocator);
        std.log.info("rewind: multi-node id={d} voters={d} listen={s}", .{ mn.node_id, mn.voters.len, mn.listen_str });
        break :blk try Bridge.initMultiNode(allocator, data_dir, mn.node_id, mn.voters, mn.listen_addr, mn.peers);
    } else try Bridge.initSingleNode(allocator, data_dir);
    defer bridge.deinit();
    bridge.setWorkerOverlay();
    // Full-HA store unification (Phase 5): a FOLLOWER has no worker serving
    // this tenant, so its replicated writes must land in the SAME store a
    // worker WOULD serve from — the tenant's `inst.kv`, provisioned on
    // demand — so a follower promoted to leader after a failover serves the
    // data it replicated. Wire the pump's follower-apply at the node tenant
    // (set BEFORE startPump so the first replicated entry already routes
    // here). On a single node this is never consulted (the sole voter leads
    // every group → leader-skip), so it is a no-op there.
    bridge.setStoreResolver(.{ .ctx = node_tenant, .func = resolveTenantStore });
    try bridge.startPump();

    // Per-tenant request-log batches → fs (S3 in prod via BLOB_BACKEND).
    const log_fs = try log_server.batch_store_fs.FsBatchStore.init(allocator, data_dir);
    defer log_fs.deinit();
    const log_batch_store = log_fs.batchStore();

    // Process-shared node state (tenant resolver, deployment cache, blob
    // coordinator, msg router, builtin modules).
    var node_state = try rjs.NodeState.init(allocator, node_tenant, blob_owned.cfg, bridge);
    defer node_state.deinit();
    node_state.wireInternal();
    try node_state.deploy.startDeploymentLoader();
    try node_state.startFetchEngine();
    // Async serve-or-forward engine. rewind runs a single worker (idx 0).
    try node_state.startProxyEngine(1);
    try node_state.blob_coord.start(1);

    // One worker thread bound to the listen port (SO_REUSEPORT-ready).
    const addr = try std.net.Address.parseIp("0.0.0.0", port);
    var ready = std.Thread.ResetEvent{};
    var ctx = WorkerCtx{
        .allocator = allocator,
        .worker_idx = 0,
        .http_addr = addr,
        .raft = bridge,
        .node = &node_state,
        .log_batch_store = log_batch_store,
        .data_dir = data_dir,
        .admin_api_domain = admin_api_domain,
        .move_secret = move_secret,
        .cluster_id = cluster_id,
        .cp_urls = cp_urls,
        .ready = &ready,
    };
    var th = try std.Thread.spawn(.{}, workerThreadEntry, .{&ctx});
    ready.wait();
    std.log.info("rewind: listening on 0.0.0.0:{d} (data_dir={s}, admin_domain={s})", .{ port, data_dir, admin_api_domain });

    while (!stop_flag.load(.acquire)) std.Thread.sleep(100 * std.time.ns_per_ms);
    th.join();
    std.log.info("rewind: shut down", .{});
}
