//! rewind — the V2 single-node worker binary (docs/v2-build-order.md
//! §Phase 2 "a v2 worker binary"). Named for the product (rewind.js) that
//! V2 is the engine for; it is the V2 counterpart of V1's `loop46`.
//!
//! It wires the reused rove-js worker stack (h2 + arenajs/qjs dispatcher +
//! blob/tenant/deploy) onto the V2 per-tenant raft **bridge** instead of
//! V1's cluster-wide `kv.Cluster` + willemt raft thread:
//!
//!   bridge.initSingleNode → setLeaderSkip → startPump   (the pump thread)
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
const ADMIN_API_DOMAIN = "admin.localhost";
const ADMIN_ROOT_TOKEN = "rewindtestroottokenpadding0123456789abcd";

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
        .admin_api_domain = ADMIN_API_DOMAIN,
        .rate_limit_caps = .{},
        .compile_fn = QjsCompiler.compile,
        .compile_ctx = &compiler,
        .log_batch_store = args.log_batch_store,
        .data_dir = args.data_dir,
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
        rjs.drainSpools(worker);
        try rjs.sweepParkedContinuations(worker);
        try rjs.serviceParkedStreams(worker);
        try rjs.cleanupResponses(worker);
        rjs.sweepCronSubscriptions(worker);
        rjs.sweepOwedRetries(worker);
        rjs.sweepDurableWakes(worker);
        rjs.serviceSubscriptionFires(worker);
        rjs.drainPendingBoundResumes(worker);
        rjs.serviceFetchEvents(worker);
    }
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
    node_tenant.root_token_secret = ADMIN_ROOT_TOKEN;

    // The V2 per-tenant raft bridge + its pump thread. Leader-skip: the
    // worker owns the speculative overlay.
    const bridge = try Bridge.initSingleNode(allocator, data_dir);
    defer bridge.deinit();
    bridge.setLeaderSkip();
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
        .ready = &ready,
    };
    var th = try std.Thread.spawn(.{}, workerThreadEntry, .{&ctx});
    ready.wait();
    std.log.info("rewind: listening on 0.0.0.0:{d} (data_dir={s})", .{ port, data_dir });

    while (!stop_flag.load(.acquire)) std.Thread.sleep(100 * std.time.ns_per_ms);
    th.join();
    std.log.info("rewind: shut down", .{});
}
