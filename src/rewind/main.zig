// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! rewind — the V2 worker binary (v2-build-order
//! §Phase 2 "a v2 worker binary"). Named for the product (rewind.js) that
//! V2 is the engine for.
//!
//! It wires the rove-js worker stack (h2 + arenajs/qjs dispatcher +
//! blob/tenant/deploy) onto the per-tenant raft **bridge**:
//!
//!   bridge.initSingleNode → setWorkerOverlay → startPump   (the pump thread)
//!   NodeState.init(tenant, blob_cfg, bridge)             (shared node state)
//!   Worker.create(.{ .raft = bridge, … })                (per worker thread)
//!
//! `REWIND_WORKERS` sets the thread count (default 1). The model is
//! shared-nothing: each worker opens its own io_uring ring and its own
//! `SO_REUSEPORT` listen socket, and the kernel hashes inbound
//! connections across them — there is no shared ring. What the workers
//! borrow, and what guarantees each piece under N threads, is the
//! "What N worker threads share" section of `src/js/worker.zig`.
//!
//! Single node: the bridge is leader of every tenant group, leader-skip
//! apply means the worker's `TrackedTxn.commit` is the durable write, and
//! the worker parks `RaftWait{group_id, seq}` polling the per-tenant
//! watermark.

const std = @import("std");
const rove = @import("rove");
const rjs = @import("rove-js");
const boot = @import("rove-boot");
const jwt = @import("rove-jwt");
const bridge_mod = @import("bridge");
const kv = @import("raft-kv");
const h2_mod = @import("rove-h2");
/// rove-io reached through rove-js, which already depends on it — the worker
/// binary needs only the `IoOptions` type, not a direct module edge.
const rio = rjs.io;
const blob_mod = @import("rove-blob");
const tenant_mod = @import("rove-tenant");
const qjs = @import("rove-qjs");
const log_server = @import("rove-log-server");
const log_mod = @import("rove-log");
const files_mod = @import("rove-files");
const version_registry = @import("version.zig");

const Bridge = bridge_mod.Bridge;
const Worker = rjs.Worker(.{});

/// The host the admin surface answers on. Overridable via env
/// (`REWIND_ADMIN_DOMAIN`) so a two-cluster deployment can give each
/// cluster a DISTINCT admin domain — the front-door routing proof keys
/// off "Host matches this cluster's admin domain → 204, else mismatch"
/// (two_cluster_smoke.py).
const DEFAULT_ADMIN_API_DOMAIN = "admin.localhost";
/// NOT a usable default — a tripwire. The boot path (`main`) refuses to
/// start when `REWIND_ROOT_TOKEN` is unset, empty, or equal to this, so
/// a misconfigured node can never silently serve the admin surface on a
/// known token. Smokes set `REWIND_ROOT_TOKEN` to their own value.
const DEFAULT_ADMIN_ROOT_TOKEN = "rewindtestroottokenpadding0123456789abcd";

// ── Signal-driven shutdown ────────────────────────────────────────────
var stop_flag: std.atomic.Value(bool) = .init(false);

// SIGINT/SIGTERM → stop_flag wiring lives in rove-boot (shared by all four binaries).

// ── Per-worker QuickJS compiler ───────────────────────────────────────
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
/// rove-io options for a public serving thread. `buf_count * buf_size` is
/// allocated up front, so this is ~67 MB of recv buffers per thread — the cost
/// of serving at full rate.
const PUBLIC_IO_OPTS: rio.IoOptions = .{
    .max_connections = 4096,
    .buf_count = 4096,
    .buf_size = 16384,
    .listen_backlog = 4096,
    .reuseport = true,
};

/// rove-io options for the private loopback listener. Deliberately ~64× smaller
/// than `PUBLIC_IO_OPTS`: the buffer pool is allocated eagerly, so copying the
/// serving profile would add ~67 MB of resident memory per node for a socket
/// that carries a deploy every few minutes. `reuseport` is off because exactly
/// one thread binds this address.
///
/// The trade this makes explicit: the private plane cannot absorb a large
/// parallel blob upload the way the public one can. That is the right shape for
/// a break-glass and bootstrap path, and it is a choice rather than an
/// inheritance.
const PRIVATE_IO_OPTS: rio.IoOptions = .{
    .max_connections = 64,
    .buf_count = 256,
    .buf_size = 16384,
    .listen_backlog = 64,
    .reuseport = false,
};

/// Default port for the private loopback deploy listener. Adjacent to the
/// metrics range (9110-9113) because it is the same kind of surface: bound to
/// 127.0.0.1, restricted by the OS rather than by a credential check.
/// `REWIND_DEPLOY_PRIVATE_PORT=0` disables it, which also removes the only way
/// to present the root bearer to the publish door.
const DEPLOY_PRIVATE_PORT: u16 = 9120;

const WorkerCtx = struct {
    allocator: std.mem.Allocator,
    worker_idx: u16,
    http_addr: std.net.Address,
    /// Which plane this thread's listener serves. Exactly one thread may be
    /// `.private` — the loopback-bound listener the publish door accepts the
    /// root bearer on. Everything else shares the public SO_REUSEPORT socket.
    plane: rjs.deploy_door.Plane = .public,
    /// rove-io options for this thread's ring. The private listener takes a
    /// much smaller buffer pool than a serving thread — see `PRIVATE_IO_OPTS`.
    io_opts: rio.IoOptions,
    /// Set by the thread if it died instead of reaching `ready`. Read once,
    /// after the startup barrier.
    failed: std.atomic.Value(bool) = .{ .raw = false },
    raft: *Bridge,
    node: *rjs.NodeState,
    log_batch_store: log_server.batch_store.BatchStore,
    data_dir: []const u8,
    admin_api_domain: []const u8,
    move_secret: ?[]const u8,
    /// Cluster KEK for per-tenant keyrings (`REWIND_KEYRING_KEK`).
    keyring_kek: ?[]const u8,
    cluster_id: ?[]const u8,
    cp_urls: []const []const u8,
    /// Worker→log-server batch-push base (`REWIND_LOG_PUBLIC_BASE`, default the
    /// internal base). Null disables push; the log-server's LIST poll is the
    /// catch-up. Enables the worker's batch-pushed fast-path (off the main loop,
    /// on the dedicated push thread).
    /// Worker→log-server push fan-out targets (`REWIND_LOG_PUSH_BASES`, a list;
    /// default the single `log_public_base`). Empty disables push. The push
    /// thread POSTs each flushed batch key to every base; per-target failure is
    /// soft (that node's S3 LIST poll is the catch-up). Borrowed.
    log_push_bases: []const []const u8,
    /// Services-JWT HMAC secret the push thread mints its bearer token with
    /// (the log-server verifies the same secret). Distinct from
    /// `node_state.services_jwt_secret` (the door-read copy) — the worker config
    /// needs its own, or `sendPushChunk` short-circuits and push never fires.
    services_jwt_secret: ?[]const u8,
    /// Peer HTTP base URLs indexed by raft id − 1 (`REWIND_PEER_URLS`) — the
    /// leader-push target for the out-of-band snapshot catch-up driver. Empty
    /// (single-node / unset) → the catch-up thread logs + no-ops any job.
    peer_urls: []const []const u8,
    ready: *std.Thread.ResetEvent,
    /// Dedicated loopback HTTP/1.1 operator-metrics listener
    /// (`REWIND_METRICS_PORT`). The worker thread renders the Prometheus
    /// snapshot every few seconds and `publish`es it here. Null = disabled
    /// (port 0, or the bind failed — metrics are optional).
    metrics: ?*rjs.MetricsServer = null,
};

/// On-promotion recovery hook for two failover-recovery cases
/// (`leader_failover_smoke_v2` / `durable_wake_smoke_v2`).
/// When this node wins leadership of a tenant's raft group (a follower→leader
/// edge the bridge pump publishes via `drainPromotions`), the freshly-promoted
/// leader must:
///   1. Load the tenant's current deployment — `_deploy/current` replicated
///      while we were a follower, but the loader only enqueues inline at
///      release time on the *original* leader, so without this the new leader
///      serves 503 until a re-release.
///   2. Reconstruct the volatile scheduler / owed-retry watermarks the old
///      leader held in RAM (`next_wake_ns` and the owed-retry sweep baseline
///      are never raft-replicated) — otherwise durable scheduled wakes that
///      came due during the handover never fire on the new leader.
///
/// Leadership is per-group, so the promotion edge is per-tenant. The deployment
/// reload is per promoted tenant; the watermark sweeps are partition-wide +
/// idempotent (the per-group propose gate inside each no-ops tenants this node
/// does not lead), so they run once per tick whenever any promotion landed.
/// Apply observer (`bridge.setApplyObserver`): fired on the pump thread once
/// per committed PUT on a non-proposing node (the proposing worker's apply is
/// skipped — its effects run inline at propose/commit time). Two branches:
///
/// 1. `_deploy/current` — enqueues a deployment load so a follower tracks the
///    tenant's current deployment continuously (see
///    `DeploymentCache.enqueueDeployment`).
/// 2. `_sched/by_time/{when}/{id}` — arms the tenant's durable-wake watermark
///    when THIS node leads the tenant's group. This is the cross-node half of
///    the cross-tenant schedule fix: a `platform.scope(t).kv` sched write
///    rides the admin batch's target envelope, whose commit arm runs on the
///    ADMIN group's leader — a different node than the target's group leader
///    whenever leaderships diverge. The proposing-node half is
///    `Cmd.target_sched_wake` (`worker_dispatch.appendTargetSchedWakeCmds` →
///    `noteCommittedSchedWrites`). Leadership-gated because the watermark is
///    leader-local state — lowering it on a non-leader would make the steady
///    sweep busy-fire a tick that can never commit there. Catch-up re-applies
///    of old sched rows may lower spuriously; the resulting `scheduler_tick`
///    re-derives the true min and re-raises (self-correcting, same posture as
///    `noteCommittedSchedWrites`). The no-leader-anywhere case (hibernated
///    group) is covered by `sweepDurableWakesOnPromotion` on the next
///    election.
///
/// `id_str` is the tenant the writeset TARGETED — for a release or a
/// cross-tenant sched write riding the admin batch (a `multi` cross-tenant
/// inner) that is the TARGET tenant, NOT the admin anchor whose group carried
/// the entry, so it must come from the observer, not a `idStrForGid(gid)`
/// lookup (which resolves the anchor, not the target tenant).
/// Borrowed for the call; the loader dups it. Empty for root writesets
/// (no `_deploy/current` or `_sched/` keys there — the checks filter them).
fn onDeployApply(ctx: *anyopaque, gid: u64, id_str: []const u8, op: bridge_mod.ApplyOp, key: []const u8, value: []const u8, origin: bool) void {
    _ = gid;
    // Only puts carry effects here. A DELETE of `_deploy/current` (a tenant
    // being torn down) has no dep to enqueue — dropping the release pointer
    // is the point; a `_sched/by_time` delete never needs to RAISE the
    // watermark (the next tick re-derives the min from committed rows).
    if (op != .put) return;
    if (id_str.len == 0) return;
    const node: *rjs.NodeState = @ptrCast(@alignCast(ctx));
    if (std.mem.eql(u8, key, "_deploy/current")) {
        // Fires on BOTH halves — replicated applies and this node's own
        // propose (`origin`). The release flip is an activation now
        // (rove#719): there is no door left to nudge the loader on the
        // proposing node, so the origin-side observer IS that nudge. The
        // enqueue is per-tenant dedup'd, so the door-era double (propose
        // side + follower apply) stays as harmless as it was.
        const dep_id = std.fmt.parseInt(u64, value, 16) catch return;
        node.deploy.enqueueDeployment(id_str, dep_id);
        return;
    }
    // Everything below is the REPLICATED-apply half of an exactly-once
    // pair: the proposing side already did this work inline, so its own
    // entries are done (`ApplyObserver.origin`).
    if (origin) return;
    // `_keys/dead/{slot}` — an identity's key destroyed. Every node does
    // the same local work: evict now so a read stops resolving, and queue
    // the shard rewrite because this is the pump thread and it may not
    // fsync.
    //
    // The proposing node did this inline at the destroy (its own entries
    // return above on `origin`), so between the two halves every node acts
    // exactly once.
    if (rjs.keyring.keyspace.parseDeadSlot(key)) |key_slot| {
        if (node.deploy.tenant_files_map.get(id_str)) |slot| {
            if (slot.keys) |keys| keys.evictAndQueue(key_slot);
        }
        return;
    }
    if (rjs.durable_wake.parseByTimeWhenNs(key)) |when_ns| {
        // The bridge mutex is NOT held during node.pump()'s apply (commit
        // hooks re-acquire it — bridge_pump.zig), so these bridge queries
        // are safe from the observer.
        const tgid = node.raft.gidForTenant(id_str) orelse return;
        if (!node.raft.isLeaderOf(tgid)) return;
        // Hold the slot lock across get+lowerWake so a concurrent
        // `evictTenant` can't free the slot between them.
        node.deploy.tenant_files_lock.lock();
        defer node.deploy.tenant_files_lock.unlock();
        const slot = node.deploy.tenant_files_map.get(id_str) orelse return;
        slot.lowerWake(when_ns);
    }
}

/// Poll-loop hook: move the pump's queued snapshot catch-up jobs onto the
/// background `SnapshotCatchupThread`. Cheap —
/// drains the bridge queue (resolving each gid's tenant id) and hands off the
/// heavy store-dump + HTTP push to the thread. The borrowed `id_str` is duped
/// into the owned job before enqueue. On an enqueue failure (OOM) the in-flight
/// mark is cleared so the pump re-triggers next tick rather than stranding.
fn drainSnapshotCatchupJobs(worker: anytype, catchup: *rjs.SnapshotCatchupThread) void {
    var buf: [16]bridge_mod.SnapshotCatchup = undefined;
    const n = worker.raft.drainSnapshotCatchup(&buf);
    for (buf[0..n]) |j| {
        const id_dup = worker.allocator.dupe(u8, j.id_str) catch {
            worker.raft.clearSnapshotCatchup(j.gid, j.peer);
            continue;
        };
        catchup.enqueue(.{
            .gid = j.gid,
            .peer = j.peer,
            .index = j.index,
            .term = j.term,
            .voters_buf = j.voters_buf,
            .voters_len = j.voters_len,
            .learners_buf = j.learners_buf,
            .learners_len = j.learners_len,
            .id_str = id_dup,
        }) catch {
            worker.allocator.free(id_dup);
            worker.raft.clearSnapshotCatchup(j.gid, j.peer);
        };
    }
}

/// `last_sweep_gen` is this worker's own view of
/// `NodeState.promotion_sweep_gen`, hence the pointer — see the relay note
/// below.
fn runPromotionHook(worker: anytype, last_sweep_gen: *u64) void {
    var buf: [64]bridge_mod.Promotion = undefined;
    const n = worker.raft.drainPromotions(&buf);
    for (buf[0..n]) |promo| {
        worker.node.deploy.enqueueCurrentDeployment(promo.id_str);
        // Seed the promotion-time LogRecord catch-up for this group — walk
        // its live raft log to recover records a crashed prior leader
        // buffered but never flushed (rove #77;
        // docs/architecture/deployment-and-logs.md).
        worker.log_walker.seed(worker.allocator, worker.raft, promo.gid);
    }
    // Relay the edge to every worker: `drainPromotions` is single-consumer,
    // so one worker takes every promotion, while the sweeps below cover
    // only that worker's `hash(tenant) % N_inboxes` slice. `promotionSweepDue`
    // carries the reasoning.
    if (rjs.promotionSweepDue(&worker.node.promotion_sweep_gen, n, last_sweep_gen)) {
        rjs.sweepDurableWakesOnPromotion(worker);
        rjs.sweepDirtySubscriptionsOnPromotion(worker);
    }
    // Advance any open catch-up cursors (bounded per tick) — runs every tick,
    // not just on a fresh edge, so a long backlog drains across ticks.
    worker.log_walker.drive(worker);
}

fn workerThreadEntry(args: *WorkerCtx) void {
    workerMain(args) catch |err| {
        std.log.err("rewind worker {d} exited: {s}", .{ args.worker_idx, @errorName(err) });
        args.failed.store(true, .release);
        // Release the startup barrier even on failure. The parent waits on
        // every worker's `ready`, so a thread that dies before signalling —
        // a port already bound is the ordinary way — would otherwise hang the
        // process at startup with no output after the last worker's line.
        // Signalling lets the parent decide: a public worker is fatal, the
        // private listener is optional.
        args.ready.set();
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
        .plane = args.plane,
        .io_opts = args.io_opts,
        .h2_opts = .{
            .max_concurrent_streams = 512,
            .initial_window_size = 1024 * 1024,
            .max_frame_size = 16384,
            .tls_config = null,
            // blob-storage-plan §3.5.1: emit body-carrying requests at
            // the HEADERS frame so the worker can dispatch from headers
            // alone (`onHeaders` / `blob.receive`) instead of buffering
            // first. drainRequestReceiving in the tick loop is the
            // disposition point.
            .headers_first = true,
            // architecture/websockets.md: WS arrives from the front as RFC 8441
            // Extended CONNECT streams on the pooled h2c conns;
            // `serviceWsMessages` dispositions `ws_connect_out`
            // (tenant + leadership at tunnel-open, BEFORE the 200).
            .extended_connect = true,
            // The worker is h2c-ONLY: h1 (and h1-WS) termination is the
            // front's job alone; an h1-looking first read closes. The
            // h1 codec lives on in rove-h2 for the front + examples.
            .accept_http1 = false,
            .websocket_upgrades = false,
        },
        // Request-id minter identity. Passing the worker index ALONE left every
        // node minting as worker 0 while each kept its own node-local counter,
        // so a tenant's leadership moving between nodes re-issued ids the
        // previous leader had already handed out (rove#281). Pack the node id
        // in too. Refusing to start beats minting colliding ids: a collision is
        // a record that is indexed nowhere and can never be replayed.
        .minter_id = blk: {
            const node_id: u64 = if (std.posix.getenv("REWIND_NODE_ID")) |v|
                std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10) catch {
                    std.debug.print("error: REWIND_NODE_ID is not a number\n", .{});
                    std.process.exit(2);
                }
            else
                1; // single-node: the only minter, so any stable identity works.
            break :blk log_mod.MinterId.init(node_id, args.worker_idx) catch {
                std.debug.print(
                    "error: REWIND_NODE_ID={d} / worker index {d} do not fit a minter identity " ++
                        "(node 1-255, worker 0-255). Request ids would collide across minters.\n",
                    .{ node_id, args.worker_idx },
                );
                std.process.exit(2);
            };
        },
        // Operational log-flush cadence overrides (null → module defaults).
        .log_flush_interval_ns = blk: {
            const s = std.posix.getenv("REWIND_LOG_FLUSH_INTERVAL_MS") orelse break :blk null;
            const ms = std.fmt.parseInt(i64, s, 10) catch break :blk null;
            break :blk ms * std.time.ns_per_ms;
        },
        .log_flush_threshold_records = blk: {
            const s = std.posix.getenv("REWIND_LOG_FLUSH_RECORDS") orelse break :blk null;
            break :blk std.fmt.parseInt(u32, s, 10) catch null;
        },
        .admin_api_domain = args.admin_api_domain,
        .rate_limit_caps = .{},
        .compile_fn = QjsCompiler.compile,
        .compile_ctx = &compiler,
        .log_batch_store = args.log_batch_store,
        .data_dir = args.data_dir,
        .move_secret = args.move_secret,
        .keyring_kek = args.keyring_kek,
        .peer_urls = args.peer_urls,
        .cluster_id = args.cluster_id,
        .cp_urls = args.cp_urls,
        .log_push_bases = args.log_push_bases,
        .services_jwt_secret = args.services_jwt_secret,
    });
    defer worker.destroy();

    // Background compile+stage thread for the publish path — driven by the
    // `__admin__` app's `/v1/deploy/*` routes through the `platform.*`
    // trusted-door primitives (docs/architecture/cli-and-deploy.md §4.2). Owns
    // its own QuickJS runtime so it never races the poll-loop compiler.
    try worker.startDeployThread();

    // Out-of-band snapshot catch-up driver: the pump's
    // `snapshotTriggerTick` queues a `(gid, peer)` for any peer in
    // `StateSnapshot`; this thread dumps the leader's store + streams it to
    // the peer's `v2-snapshot-stream` (baseline + ConfState in headers),
    // off the poll loop.
    const catchup = try rjs.SnapshotCatchupThread.init(
        allocator,
        args.node.tenant,
        args.raft,
        args.move_secret,
        args.peer_urls,
    );
    defer catchup.deinit();
    try catchup.start();
    defer catchup.shutdown();
    // The same off-loop driver also runs CP-triggered move
    // pushes (`/_system/v2-snapshot-push` → `armSnapshotPush` enqueues here).
    worker.snapshot_push_driver = catchup;

    std.log.info("rewind worker {d}: ready ({s})", .{
        args.worker_idx,
        switch (args.plane) {
            .public => "SO_REUSEPORT",
            .private => "loopback, private plane",
        },
    });
    args.ready.set();

    var blocked_tenants: rjs.BlockedTenants = .{};
    // This worker's view of `NodeState.promotion_sweep_gen`. Seeded from
    // the live value so a worker that starts late doesn't replay every
    // promotion the node has already swept.
    var last_sweep_gen: u64 = worker.node.promotion_sweep_gen.load(.acquire);
    // Render + publish the operator-metrics snapshot to the loopback HTTP/1.1
    // listener every ~2s (cheap; the listener serves the latest — a few seconds
    // stale is nothing for a 60s scrape). `last_metrics_ns = 0` makes the first
    // iteration publish immediately. The render MUST run on this thread:
    // buildMetricsText reads live h2/dispatch + raft state only it may touch.
    var last_metrics_ns: i64 = 0;
    // Deploy capability is bootstrapped explicitly via `POST /_system/reset`
    // (docs/architecture/cli-and-deploy.md §4) — the operator/harness deploys the baked `__admin__`
    // app once, then publishes the full admin + customers THROUGH it. The same
    // endpoint is break-glass (re-run to recover a bricked control tenant). No
    // auto-deploy-on-boot magic.
    while (!stop_flag.load(.acquire)) {
        worker.pollWithTimeout(1 * std.time.ns_per_ms) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };

        try rjs.drainRequestReceiving(worker);
        try rjs.drainBodyPending(worker);
        try rjs.drainFetchPendingDurability(worker);
        _ = try rjs.dispatchOnce(worker, &blocked_tenants);
        try rjs.drainRaftPending(worker);
        runPromotionHook(worker, &last_sweep_gen);
        drainSnapshotCatchupJobs(worker, catchup);
        try rjs.drainForwardPending(worker);
        // Finalize completed streamed-snapshot transfers
        // (install the baseline + respond) parked in `snapshot_streams`, and
        // respond to parked CP-triggered move pushes as the driver finishes them.
        try rjs.drainSnapshotStreams(worker);
        try rjs.drainSnapshotPushes(worker, catchup);
        rjs.drainSpools(worker);
        // CAS→connection relay (`docs/architecture/routing-and-ingress.md`):
        // append relayed static/blob bytes straight onto their held
        // streams and re-inject relay terminals into the bound dispatch.
        rjs.drainRelay(worker);
        try rjs.sweepParkedContinuations(worker);
        // docs/architecture/effects-and-handlers.md: fire the next staged
        // inbound body chunk into each held `onChunk` chain. Runs after
        // drainRaftPending so a writing chunk's committed entity is back
        // in parked_continuations (the pump's readiness signal) within
        // the same tick.
        rjs.pumpInboundChunks(worker);
        try rjs.serviceParkedStreams(worker);
        // docs/architecture/websockets.md (piece D): dispatch inbound WS
        // frames (h2 `ws_message_out`) to the held chain's `onMessage` /
        // `onDisconnect` and lower outbound `stream.write`s to `ws_send_in`.
        // Writing frames stage commit-gated sends; the per-connection
        // input gate queues frames arriving behind an in-flight commit
        // (strict reply ordering + read-your-writes) and flushes them
        // here once `drainRaftPending` (above, same tick) released the
        // committed unit's reply frames. Read-only frames emit inline.
        try rjs.serviceWsMessages(worker);
        try rjs.cleanupResponses(worker);
        rjs.sweepBlobSessions(worker);
        rjs.sweepDurableWakes(worker);
        rjs.serviceSubscriptionFires(worker);
        rjs.drainPendingBoundResumes(worker);
        rjs.serviceFetchEvents(worker);

        if (args.metrics) |ms| {
            const now_ns: i64 = @intCast(std.time.nanoTimestamp());
            if (now_ns - last_metrics_ns > 2 * std.time.ns_per_s) {
                last_metrics_ns = now_ns;
                if (rjs.buildMetricsText(args.allocator, worker)) |txt| {
                    ms.publish(txt);
                    args.allocator.free(txt);
                } else |_| {}
                // The render runs on the serving thread, so its cost is
                // request latency; it measures well under 1ms, and this
                // tripwire keeps that claim honest if the text ever grows
                // an expensive section.
                const render_us = @divTrunc(@as(i64, @intCast(std.time.nanoTimestamp())) - now_ns, std.time.ns_per_us);
                if (render_us > 1000)
                    std.log.warn("metrics render took {d}us at={d}", .{ render_us, std.time.milliTimestamp() });
            }
        }
    }
}

// ── Full-HA follower-apply store resolver (two-handle model) ──────────

/// Pump-side store handles — the TWO-HANDLE model. The pump must NEVER
/// use the worker's per-tenant `KvStore` handles: a handle carries
/// per-batch txn state (`active_txn`), so sharing one across the pump
/// and worker threads let a follower-apply land its writes INSIDE the
/// worker's concurrently-open speculative txn (silent corruption: the
/// replicated entry's data then rode the worker txn's commit/rollback)
/// or trip on its lease/txn state mid-mutation. Each resolved id instead
/// gets a PUMP-OWNED sibling
/// handle attached into the SAME manifest at the SAME store id: the
/// underlying store state (kvexp `TenantState` — overlay, LMDB, lease)
/// is per store-id and internally locked, so the data stays unified
/// (the worker serves exactly what the pump applies — the
/// store-unification requirement) while the per-handle txn state stays
/// private to the pump. Cross-handle writes serialize on kvexp's
/// blocking per-store lease.
///
/// All fields are pump-thread-only after init (the resolver runs
/// exclusively on the pump thread; boot recovery runs before the pump
/// thread starts, on the boot thread, which is the same exclusivity).
const PumpStores = struct {
    allocator: std.mem.Allocator,
    tenant: *tenant_mod.Tenant,
    /// id_str (owned dup) → pump-owned sibling handle.
    map: std.StringHashMapUnmanaged(*kv.KvStore) = .empty,
    /// Pump-owned sibling of the node-wide `__root__` store.
    root_handle: ?*kv.KvStore = null,
    /// `Tenant.deletionGen` at the last (re)build of `map`. A handle cached
    /// before a deprovision is attached at the DELETED lifetime's store id
    /// under the same name, so applies for the reborn tenant would land in
    /// the predecessor's store while the serving side reads the new one
    /// (#534). Deletes are rare and re-attach is one map insert, so the map
    /// is simply dropped whenever the generation moves.
    deletion_gen: u64 = 0,

    fn deinit(self: *PumpStores) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.close();
            self.allocator.free(e.key_ptr.*);
        }
        self.map.deinit(self.allocator);
        if (self.root_handle) |h| h.close();
    }

    /// `bridge.StoreResolver.func`: resolve the pump's handle for a
    /// replicated apply, provisioning the worker-side instance on first
    /// sight (so blob dirs + the serving handle exist the moment a
    /// request lands). `gid` is unused — stores key on the tenant id
    /// string the envelope carries. Per the `StoreResolver` contract
    /// the EMPTY id resolves the node-wide root store (`__root__`) —
    /// the target of `platform.root.*` root-writeset inners riding an
    /// admin batch. Returns null only on a provisioning failure
    /// (surfaced by the apply round as `UnroutedApply`).
    fn resolve(ctx: *anyopaque, gid: u64, id_str: []const u8) ?*kv.KvStore {
        _ = gid;
        const self: *PumpStores = @ptrCast(@alignCast(ctx));
        // Revalidate against deprovisions (see `deletion_gen`). The root
        // handle stays — `__root__`'s store id never changes.
        const gen = self.tenant.deletionGen();
        if (gen != self.deletion_gen) {
            var it = self.map.iterator();
            while (it.next()) |e| {
                e.value_ptr.*.close();
                self.allocator.free(e.key_ptr.*);
            }
            self.map.clearRetainingCapacity();
            self.deletion_gen = gen;
        }
        if (id_str.len == 0) {
            if (self.root_handle) |h| return h;
            const h = kv.KvStore.attachSibling(
                self.allocator,
                self.tenant.root,
                kv.hashStoreId("__root__"),
                null,
            ) catch return null;
            self.root_handle = h;
            return h;
        }
        if (self.map.get(id_str)) |h| return h;
        // Provision the worker-side instance first (idempotent;
        // `Tenant` is internally locked, so this is safe alongside the
        // worker thread), then attach the pump's own sibling handle —
        // sharing the instance's seq counter so write-version minting
        // stays globally monotonic across both handles.
        self.tenant.createInstance(id_str) catch return null;
        const inst = (self.tenant.getInstance(id_str) catch null) orelse return null;
        // `inst.storage.storeId()`, never a fresh hash of the name: the
        // instance's store is keyed by (id, incarnation), so re-hashing the
        // id here would open the PREVIOUS tenant-lifetime's store and apply
        // writesets into it while the dispatcher reads the current one (#357).
        const h = kv.KvStore.attachSibling(
            self.allocator,
            self.tenant.root,
            inst.storage.storeId(),
            inst.kv.counter,
        ) catch return null;
        const key = self.allocator.dupe(u8, id_str) catch {
            h.close();
            return null;
        };
        self.map.put(self.allocator, key, h) catch {
            self.allocator.free(key);
            h.close();
            return null;
        };
        return h;
    }
};

// ── Multi-node config ─────────────────────────────────────────────────

/// Parsed multi-node bridge config (HA) — the shared
/// `consensus/cluster_config.zig` parser under the worker's `REWIND_`
/// env prefix (`REWIND_NODE_ID` / `REWIND_VOTERS` / `REWIND_PEERS`; the
/// raft ports are DISTINCT from the HTTP listen port, argv[2]). `null`
/// when this is a single-node deployment.
const MultiNode = bridge_mod.cluster_config.MultiNode;

fn parseMultiNode(a: std.mem.Allocator) !?MultiNode {
    return bridge_mod.cluster_config.fromEnv(a, "REWIND_");
}

/// Genesis first-boot config (consensus-and-storage.md "Cluster genesis &
/// membership", genesis): this node's
/// own raft id + its raft listen `host:port`, and NOTHING else — no voter set,
/// no peer list. The node boots self-only (a transport with a `PeerRegistry`,
/// groups born `{self}`) and is grown into the cluster by the CP via conf-change.
///   - `REWIND_NODE_ID`    this node's 1-based raft id.
///   - `REWIND_RAFT_ADDR`  this node's raft transport `host:port` (an IP literal;
///                         DISTINCT from the HTTP listen port, argv[2]).
/// Returns null (→ fall through to the static multi-node / single-node paths)
/// when either is unset, OR when a static `REWIND_VOTERS`/`REWIND_PEERS` is also
/// present (that's the static multi-node path).
const Genesis = struct {
    node_id: u64,
    listen_addr: std.net.Address,
    listen_str: []u8,
    fn deinit(self: *const Genesis, a: std.mem.Allocator) void {
        a.free(self.listen_str);
    }
};

fn parseGenesis(a: std.mem.Allocator) !?Genesis {
    const node_id_s = std.posix.getenv("REWIND_NODE_ID") orelse return null;
    const raft_addr_s = std.posix.getenv("REWIND_RAFT_ADDR") orelse return null;
    if (std.posix.getenv("REWIND_VOTERS") != null or std.posix.getenv("REWIND_PEERS") != null)
        return null;
    const node_id = try std.fmt.parseInt(u64, std.mem.trim(u8, node_id_s, " \t"), 10);
    if (node_id == 0) return error.BadNodeId;
    const t = std.mem.trim(u8, raft_addr_s, " \t");
    const hp = bridge_mod.cluster_config.splitHostPort(t) catch return error.BadRaftAddr;
    const listen_addr = try std.net.Address.parseIp(hp.host, hp.port);
    return Genesis{
        .node_id = node_id,
        .listen_addr = listen_addr,
        .listen_str = try a.dupe(u8, t),
    };
}

/// Parse a `;`/`,`-separated list of origins into an owned, owned-element
/// slice (a single URL → a one-element list; empty input → empty slice).
const parseUrlList = boot.parseUrlList;
const freeUrlList = boot.freeUrlList;

// ── main ──────────────────────────────────────────────────────────────
pub fn main() !void {
    // rove uses libc malloc globally (multiraft-scaling-learnings §3.6 —
    // GPA's global mutex is the wall under multi-raft).
    const allocator = std.heap.c_allocator;

    boot.installSignalHandlers(&stop_flag);

    var arg_it = std.process.args();
    _ = arg_it.next(); // argv[0]
    const first_arg = arg_it.next();
    // `rewind --version` dumps the format-version registry and exits
    // (`docs/architecture/format-versioning.md` §3.8). Done before any data-dir
    // / port handling so it works with no environment set up.
    if (first_arg) |a| {
        if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "version")) {
            var stdout_buf: [4096]u8 = undefined;
            var sw = std.fs.File.stdout().writer(&stdout_buf);
            try version_registry.dump(&sw.interface);
            try sw.interface.flush();
            return;
        }
    }
    // Logging must never block the poll loop: on a backpressured log sink
    // (journald rate-limit / slow disk) a BLOCKING std.log write() on the
    // single serving thread freezes the whole worker — every tenant —
    // until it drains. O_NONBLOCK drops the line instead. See
    // `rove.logNonBlocking` (root-caused from the front wedge). After the
    // --version path so that output flushes normally.
    rove.logNonBlocking();

    const data_dir = first_arg orelse "/tmp/rewind-data";
    const port_str = arg_it.next() orelse "8080";
    const port = try std.fmt.parseInt(u16, port_str, 10);

    try std.fs.cwd().makePath(data_dir);

    const admin_api_domain = std.posix.getenv("REWIND_ADMIN_DOMAIN") orelse DEFAULT_ADMIN_API_DOMAIN;
    // The root token gates the admin/`__root__` surface (`/_system/admin-kv`,
    // `platform.root.*`). Refuse to boot on an unset, empty, or default token:
    // a silent fallback to the compiled-in test value would leave the admin
    // surface wide open on a misconfigured node. The constant below is a
    // tripwire, never a usable default — every deployment (and every smoke,
    // via `REWIND_ROOT_TOKEN`) must set a strong, unique value.
    const admin_root_token = blk: {
        const t = std.posix.getenv("REWIND_ROOT_TOKEN") orelse {
            std.log.err("rewind: REWIND_ROOT_TOKEN is not set — refusing to boot. " ++
                "Set it to a strong, unique secret (the admin/root surface must " ++
                "never run on an unset or default token).", .{});
            return error.RootTokenNotConfigured;
        };
        if (t.len == 0 or std.mem.eql(u8, t, DEFAULT_ADMIN_ROOT_TOKEN)) {
            std.log.err("rewind: REWIND_ROOT_TOKEN is empty or equals the compiled-in " ++
                "default — refusing to boot. Set it to a strong, unique secret.", .{});
            return error.RootTokenInsecure;
        }
        break :blk t;
    };
    // Test-only outbound escape hatch for smoke topologies whose
    // upstream echo tenants live on loopback over plaintext h2c.
    // Relaxes ONLY the loopback block + the TLS-always rule on
    // customer `http.fetch`; the metadata range (169.254/16) and the
    // rest of the blocklist stay enforced. NEVER set in production —
    // a malicious handler could probe the host's own services.
    if (std.posix.getenv("REWIND_UNSAFE_OUTBOUND")) |v| {
        if (std.mem.eql(u8, v, "1")) {
            rjs.ssrf.test_allow_loopback = true;
            rjs.ssrf.test_allow_plaintext = true;
            std.log.warn(
                "rewind: REWIND_UNSAFE_OUTBOUND=1 — outbound loopback block + TLS-always DISABLED (test topologies only; never production)",
                .{},
            );
        }
    }
    // Shared secret for the cluster-internal tenant-move
    // surface (`/_system/v2-*`). The front door presents it as
    // `X-Rewind-Move-Secret`. Unset → the move surface is disabled.
    const move_secret = std.posix.getenv("REWIND_MOVE_SECRET");
    // Cluster key-encryption key for per-tenant keyrings. The SAME value
    // on every node of a cluster: a sealed keyring shard is portable
    // ciphertext only because its file key derives from this plus the
    // tenant id, which is what lets replication ship bytes verbatim.
    //
    // Read from the environment and never written to disk by this
    // process. It DOES reach disk by deployment, though: the fleet ships
    // node secrets as a 0600 systemd `EnvironmentFile`, so this sits on
    // the same disk as the keyring ciphertext it protects, alongside the
    // root token and the move secret.
    //
    // So a recovered disk yields both halves, and destroying a departed
    // node's copy is a KEK-rotation question — `key_version` in the
    // ciphertext envelope exists for exactly that — rather than
    // something the seal settles on its own. Protecting this key alone
    // would be theatre while the root token sits beside it granting live
    // cluster access; the layer that actually closes it is full-disk
    // encryption, which covers the WAL and the LMDB stores too.
    //
    // Unset → the keyring surface is disabled (404), which is the
    // pre-rollout state.
    //
    // EMPTY is treated as unset, not as a key. A rendered env file that
    // failed to resolve the secret emits `REWIND_KEYRING_KEK=` rather
    // than omitting the line, and an empty ikm is a key everyone knows —
    // it would seal every keyring in the fleet under a value with no
    // entropy while looking configured. Disabled-and-obvious beats
    // enabled-and-worthless.
    const keyring_kek = blk: {
        const v = std.posix.getenv("REWIND_KEYRING_KEK") orelse break :blk null;
        if (v.len == 0) {
            std.log.warn(
                "rewind: REWIND_KEYRING_KEK is set but EMPTY — keyring surface stays " ++
                    "disabled; the env render probably could not resolve the secret",
                .{},
            );
            break :blk null;
        }
        break :blk v;
    };
    // Serve-or-forward: this cluster's id + the control-plane
    // base URL. Set together; either unset → a local tenant miss 404s (no
    // forwarding). A DP that can't serve a tenant locally asks the CP who
    // owns it and forwards there.
    const cluster_id = std.posix.getenv("REWIND_CLUSTER_ID");
    // A LIST of CP node URLs (HA): `REWIND_CP_URL` accepts `;`/`,`-separated
    // origins (a single URL is just a one-element list). The worker tries each
    // until one answers, so a CP node failure never breaks serve-or-forward.
    const cp_urls = try parseUrlList(allocator, std.posix.getenv("REWIND_CP_URL") orelse "");
    defer freeUrlList(allocator, cp_urls);

    // Peer HTTP base URLs indexed by raft id − 1 (the worker analog of CP's
    // `REWIND_CP_PEER_URLS`): the leader-push target for the out-of-band
    // snapshot catch-up driver. DISTINCT from
    // `REWIND_PEERS` (the raft transport `host:port`s); these are the workers'
    // HTTP `/_system/` listen origins. Unset (single-node) → catch-up disabled.
    const peer_urls = try parseUrlList(allocator, std.posix.getenv("REWIND_PEER_URLS") orelse "");
    defer freeUrlList(allocator, peer_urls);

    // docs/architecture/auth-consolidation.md A2/A3: wire the `rewind-logs.internal`
    // fetch-engine door so the `__admin__` chokepoint reads tenant logs with a
    // worker-minted, tenant-scoped `logs-read` token. The secret is the SAME
    // hex `LOOP46_SERVICES_JWT_SECRET` the log-server verifies with (hex-decoded
    // to raw HMAC bytes here, matching the log-server). Both optional: unset →
    // the door is disabled (`error.LogsDoorUnconfigured`).
    // Unset disables the door; MALFORMED is fatal — a worker minting tokens
    // with a key the log-server cannot verify would fail every logs read at
    // request time instead of at boot. The jwt module reports which way the
    // hex is wrong; naming the env var is this binary's job.
    const services_jwt_secret: ?[]const u8 =
        jwt.loadSecretFromEnvOpt(allocator, "LOOP46_SERVICES_JWT_SECRET") catch |e| switch (e) {
            error.SecretHexOddLength => {
                std.log.err("LOOP46_SERVICES_JWT_SECRET must be even-length hex", .{});
                std.process.exit(2);
            },
            error.SecretHexInvalid => {
                std.log.err("LOOP46_SERVICES_JWT_SECRET is not valid hex", .{});
                std.process.exit(2);
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
    defer if (services_jwt_secret) |s| allocator.free(s);
    // Worker's internal-plane view of the standalone log-server (no trailing
    // slash, e.g. `http://127.0.0.1:9000`). Env memory lives for the process,
    // so no dup/free.
    const log_internal_base: ?[]const u8 = std.posix.getenv("REWIND_LOG_INTERNAL_BASE");
    // Push target for the worker→log-server batch fast-path. For the single
    // cluster-scoped log-server (docs/architecture/deployment-and-logs.md) this
    // is the same address as the query door, so it defaults to the internal
    // base — setting REWIND_LOG_INTERNAL_BASE enables push too. Unset both →
    // push disabled, poll is the only path. (NB: a single base is only coherent
    // for ONE shared log-server; N independent per-node indexers would need
    // fan-out, not a single base — see the deployment notes.)
    const log_public_base: ?[]const u8 = std.posix.getenv("REWIND_LOG_PUBLIC_BASE") orelse log_internal_base;

    // Worker→log-server push fan-out targets. Multi-node prod runs ONE
    // per-node log-server indexer per node (loopback `:8444`), and a log query
    // can land on any node's `__admin__` leader → its LOCAL indexer. So the
    // worker pushes each flushed batch key to ALL nodes' log-servers; a node
    // that misses the push still catches up via its S3 LIST poll (~5 s), so a
    // per-target failure is soft. `REWIND_LOG_PUSH_BASES` is a `,`/`;`-list of
    // internal origins (e.g. `http://10.0.0.1:8444,http://10.0.0.2:8444,…`),
    // reachable on the private plane (the log-servers must bind it, not
    // loopback). Unset → fall back to the single `log_public_base`
    // (dev + single-node push-to-local); both empty → push disabled, poll-only.
    const log_push_bases: []const []const u8 = blk: {
        const env = std.posix.getenv("REWIND_LOG_PUSH_BASES") orelse "";
        if (env.len > 0) break :blk try parseUrlList(allocator, env);
        if (log_public_base) |b| {
            const one = try allocator.alloc([]const u8, 1);
            one[0] = try allocator.dupe(u8, b);
            break :blk one;
        }
        break :blk &.{};
    };
    defer if (log_push_bases.len > 0) freeUrlList(allocator, log_push_bases);

    // Blob backend (fs or s3) — process-wide, env-selected.
    var blob_owned = try blob_mod.env.loadFromEnv(allocator);
    defer blob_owned.deinit(allocator);

    // Scope every store to the object store's current generation before any
    // of them is opened. A wipe of `data_dir` resets the id counters that
    // name keys under this prefix, so a cluster that guessed its generation
    // would re-issue ids over a previous lifetime's keys — refuse instead.
    const ns_segment = blob_mod.namespace_store.resolve(allocator, blob_owned.cfg) catch |err| {
        if (err == blob_mod.namespace.Error.MarkerMissing) {
            std.debug.print("error: {s}\n", .{blob_mod.namespace.MISSING_MARKER_HINT});
            std.process.exit(2);
        }
        return err;
    };
    defer allocator.free(ns_segment);
    _ = try blob_owned.applyNamespace(allocator, ns_segment);

    // Node-wide root store + seq counters + tenant registry. The
    // worker opens the root store directly.
    const root_kv = try kv.KvStore.openClusterOwned(allocator, data_dir, "cluster.kv", "__root__");
    var seq_counters = kv.SeqCounterRegistry.init(allocator);
    defer seq_counters.deinit();
    const node_tenant = try tenant_mod.Tenant.createWithCounters(allocator, root_kv, data_dir, &seq_counters);
    defer node_tenant.destroy();
    try node_tenant.createInstance(tenant_mod.ADMIN_INSTANCE_ID);
    // A root bearer so `/_system/admin-kv` (the
    // built-in envelope-0 write path) is reachable, exercising propose →
    // bridge commit → worker txn.commit end to end on a single node.
    node_tenant.root_token_secret = admin_root_token;
    // Wildcard tenant routing: `REWIND_PUBLIC_SUFFIX=<suffix>` lets the worker
    // resolve `{instance_id}.{suffix}` → that instance without an explicit
    // `domain/` alias. The front routes
    // the host to this cluster via the CP directory; the worker then resolves
    // the proxied host locally. Unset = wildcard disabled (explicit aliases only).
    if (std.posix.getenv("REWIND_PUBLIC_SUFFIX")) |suffix| {
        if (suffix.len > 0) try node_tenant.setPublicSuffix(suffix);
    }

    // Pump-side store handles (two-handle model — see `PumpStores`).
    // Declared BEFORE the bridge so its deinit (LIFO) runs AFTER
    // `bridge.deinit` joins the pump thread — the resolver's handles
    // must outlive every pump-thread apply.
    var pump_stores = PumpStores{ .allocator = allocator, .tenant = node_tenant };
    defer pump_stores.deinit();

    // The V2 per-tenant raft bridge + its pump thread. Leader-skip: the
    // worker owns the speculative overlay. Single node by default; a
    // multi-node (HA) node is configured by env — this node's
    // 1-based raft id, the voter set, and the per-node raft transport
    // addresses (distinct from the HTTP port). See `parseMultiNode`.
    const bridge = if (try parseGenesis(allocator)) |g| blk: {
        defer g.deinit(allocator);
        std.log.info("rewind: genesis node id={d} raft_addr={s}", .{ g.node_id, g.listen_str });
        // Self-only boot: a transport with an (empty) PeerRegistry already its
        // resolver; groups born {self}, grown by the CP via conf-change.
        break :blk try Bridge.initGenesis(allocator, data_dir, g.node_id, g.listen_addr);
    } else if (try parseMultiNode(allocator)) |mn| blk: {
        defer mn.deinit(allocator);
        std.log.info("rewind: multi-node id={d} voters={d} listen={s}", .{ mn.node_id, mn.voters.len, mn.listen_str });
        const b = try Bridge.initMultiNode(allocator, data_dir, mn.node_id, mn.voters, mn.listen_addr, mn.peers);
        // Route peer addressing through the runtime registry (genesis §3.3),
        // seeded with the statically-configured peers — so attach / conf-change
        // can teach it nodes beyond the static set.
        b.enablePeerRegistry() catch return error.OutOfMemory;
        for (mn.peers, 0..) |p, i| try b.learnPeer(@intCast(i + 1), p.host, p.port);
        break :blk b;
    } else try Bridge.initSingleNode(allocator, data_dir);
    defer bridge.deinit();
    bridge.setWorkerOverlay();
    // Full-HA store unification: a FOLLOWER has no worker serving
    // this tenant, so its replicated writes must land in the SAME store a
    // worker WOULD serve from — the same manifest + store id the tenant's
    // `inst.kv` serves, via the pump's OWN sibling handle (two-handle
    // model, see `PumpStores`) — so a follower promoted to leader after a
    // failover serves the data it replicated, without the pump ever
    // touching the worker handle's txn state. Set BEFORE startPump so the
    // first replicated entry already routes here.
    bridge.setStoreResolver(.{ .ctx = &pump_stores, .func = PumpStores.resolve });
    // Auto-demote policy: a far-behind, presumed-dead
    // voter is demoted to a learner so it stops pinning the WAL-compaction
    // floor. Defaults are baked into Node; env overrides tune the lag threshold
    // (entries; 0 disables) and the evaluation cadence (ms). Set before
    // startPump (the pump owns the Node thereafter).
    if (std.posix.getenv("REWIND_AUTO_DEMOTE_LAG")) |v| {
        bridge.node.auto_demote_lag = std.fmt.parseInt(u64, v, 10) catch bridge.node.auto_demote_lag;
        std.log.info("rewind: auto-demote lag threshold = {d} entries{s}", .{ bridge.node.auto_demote_lag, if (bridge.node.auto_demote_lag == 0) " (disabled)" else "" });
    }
    if (std.posix.getenv("REWIND_AUTO_DEMOTE_MS")) |v| {
        if (std.fmt.parseInt(i64, v, 10)) |ms| bridge.node.auto_demote_interval_ns = ms * std.time.ns_per_ms else |_| {}
    }
    // Mechanism-A compaction catch-up buffer (entries kept below the durable
    // apply watermark; see node.zig DEFAULT_SNAPSHOT_GRACE). A peer further back
    // than this trips StateSnapshot → out-of-band catch-up. Smokes set it low to
    // force the snapshot path; prod leaves the default. Set before startPump.
    if (std.posix.getenv("REWIND_SNAPSHOT_GRACE")) |v| {
        bridge.node.snapshot_grace = std.fmt.parseInt(u64, v, 10) catch bridge.node.snapshot_grace;
        std.log.info("rewind: snapshot grace buffer = {d} entries", .{bridge.node.snapshot_grace});
    }
    // Raft logical-tick cadence (ms). The wall-clock election timeout is
    // `election_tick × this` (see node.zig DEFAULT_TICK_NS); the default
    // preserves the historical ~1ms cadence. Raise it once a soak has measured
    // the broadcast-time + pause-jitter tail it must clear
    // (docs/architecture/raft-best-practices.md "how to size election/heartbeat").
    if (std.posix.getenv("REWIND_RAFT_TICK_MS")) |v| {
        if (std.fmt.parseInt(i64, v, 10)) |ms| {
            if (ms > 0) {
                bridge.node.setTickInterval(ms * std.time.ns_per_ms);
                std.log.info("rewind: raft tick interval = {d}ms (election timeout ≈ election_tick × {d}ms)", .{ ms, ms });
            }
        } else |_| {}
    }
    // Boot-time group recovery: re-stand-up the tenant raft groups this node
    // persisted (its node-local manifest) so a restarted node rejoins its
    // groups and catches up to the live state — the leader replicates the
    // missing tail once the pump starts. BEFORE startPump (group lifecycle is
    // single-threaded until the pump owns the Manager), mirroring the CP
    // directory's boot `ensureGroup` scan. No-op on a fresh data dir.
    const recovered = bridge.recoverGroups();
    if (recovered > 0) std.log.info("rewind: recovered {d} tenant group(s) at boot", .{recovered});
    // WAL sync mode: async (default — the flusher thread keeps the fsync
    // out of the pump cycle) or `inline` (the operator rollback lever;
    // re-serializes heartbeats behind the fsync).
    if (std.posix.getenv("REWIND_WAL_SYNC_MODE")) |v| {
        if (std.mem.eql(u8, v, "inline")) {
            bridge.inline_fsync = true;
            std.log.info("rewind: WAL sync mode = inline (async flusher disabled)", .{});
        }
    }
    try bridge.startPump();

    // Per-tenant request-log / tape batches → S3. The only tape-query surface,
    // `rewind-logs`, reads S3-only (its indexer LISTs + serves
    // `/v1/{tenant}/list` + `/show`), so a local `FsBatchStore` would be
    // unreadable by it — an fs writer and an S3 reader would never meet,
    // leaving captured tapes unqueryable for replay. Build the
    // batch store from the SAME S3 connection params as the blob backend (rove
    // blob is S3-only), plus an optional `LOG_S3_KEY_PREFIX` so log batches can
    // sit under a named prefix; both sides default to "" and so agree. The
    // worker's single background flusher thread serializes all PUTs through
    // this store's one libcurl handle (rewind runs a single worker — see
    // below; a multi-worker node would need a per-flusher handle).
    const log_s3 = try log_server.batch_store_s3.S3BatchStore.fromBlobCfg(allocator, blob_owned.cfg, ns_segment);
    defer log_s3.deinit();
    const log_batch_store = log_s3.batchStore();

    // Process-shared node state (tenant resolver, deployment cache, blob
    // coordinator, msg router, builtin modules).
    var node_state = try rjs.NodeState.init(allocator, node_tenant, blob_owned.cfg, bridge);
    defer node_state.deinit();
    // Hand the node the credential + base for the `rewind-logs.internal`
    // door (borrowed; both outlive node_state per defer ordering above).
    node_state.services_jwt_secret = services_jwt_secret;
    node_state.log_internal_base = log_internal_base;
    // The `rewind-cp.internal` door — the move-secret (already read
    // for the move surface) + a CP base (the first configured CP node; the CP
    // forwards control writes to its leader). Both borrowed (env / cp_urls live
    // for the process). Either unset → the CP door is disabled.
    node_state.move_secret = move_secret;
    node_state.cp_internal_base = if (cp_urls.len > 0) cp_urls[0] else null;
    node_state.wireInternal();
    // Per-tenant keyrings need the cluster KEK and the node's data dir.
    // Both null on a cluster that has not turned crypto-shredding on,
    // which leaves every slot without a keyring — and therefore
    // answering `unverified` for any key, never inventing an erasure.
    node_state.deploy.keyring_kek = keyring_kek;
    node_state.deploy.data_dir = data_dir;
    try node_state.deploy.startDeploymentLoader();

    // The shared keyring-pool refill driver. A pool is per tenant, so an
    // owned thread each would scale threads with tenants; this small
    // worker set turns the crank for all of them, keeping minted slots
    // ahead of demand so binding an identity never waits on consensus.
    // Idle when no tenant has a pool, which is every cluster that has
    // not turned crypto-shredding on.
    var keyring_driver: rjs.keyring_pool.RefillDriver = undefined;
    try keyring_driver.start(allocator, &node_state.deploy);
    defer keyring_driver.deinit();
    // Continuous follower deployment loading: fire on every committed
    // `_deploy/current` write so a FOLLOWER loads each deployment as it
    // replicates (the loader is otherwise only enqueued inline at release time
    // on the original leader). Then a promoted follower already serves the
    // handler — and the on-promotion durable-wake sweep finds a loaded
    // deployment. Set after the loader exists; safe to set post-`startPump`
    // because no tenant group exists yet at this point in boot (the first
    // provision/apply comes from the CP/clients much later), so `notifyApply`
    // never reads `apply_observer` during this set. On the GROUP LEADER the
    // apply is leader-skipped (no `notifyApply`), so this fires only on
    // followers — exactly where the inline release enqueue never ran.
    bridge.setApplyObserver(.{ .ctx = &node_state, .func = onDeployApply });
    // Cold-start: eagerly open every known tenant and enqueue its current
    // deployment load, so the loader-thread prewarm (resident, compressed
    // HTML) runs at boot. The apply-observer above only fires while the
    // raft log still re-applies `_deploy/current` during catch-up — once
    // the log is compacted past that entry, a restarted node would never
    // load the deployment (503 forever, with no blocking serve fallback to
    // mask it). Reading the committed marker straight from app.db here is
    // the durable trigger. Idempotent (the loader content-address-dedups).
    const eager = node_state.deploy.eagerOpenTenants() catch |err| blk: {
        std.log.warn("rewind: cold-start eager-open failed: {s}", .{@errorName(err)});
        break :blk 0;
    };
    if (eager > 0) std.log.info("rewind: cold-start opened {d} tenant(s) for deployment load", .{eager});
    try node_state.startFetchEngine();

    // Worker threads, shared-nothing: each opens its own io_uring ring and
    // its own `SO_REUSEPORT` listen socket on `addr`, and the kernel hashes
    // inbound connections across them. Sized once here because the
    // per-worker-indexed subsystems below (proxy result inboxes, blob
    // coordinator queues) allocate one slot per worker and a worker's slot
    // index is its routing identity for the life of the process
    // (`msg_router.zig`).
    // The private loopback listener occupies a worker slot like any other
    // thread, so it comes out of the SAME budget rather than being added on top
    // of it. `MinterId` partitions request ids as 8 bits node + 8 bits worker
    // and hard-errors past index 255, and the per-worker-sized subsystems take
    // a `u8` count — so `public + private` is what must fit, not `public`.
    //
    // When the budget is already full, the public count gives up the slot. A
    // node with 254 serving threads instead of 255 is a non-event; a node that
    // silently lost its break-glass listener is an operator debugging a
    // rejected root token at the worst possible moment.
    const private_port = boot.parsePortEnv("REWIND_DEPLOY_PRIVATE_PORT", DEPLOY_PRIVATE_PORT);
    const want_private = private_port != 0;
    const requested_workers = boot.parseWorkerCountEnv("REWIND_WORKERS", 1);
    const worker_count = if (want_private and requested_workers >= boot.MAX_WORKERS) blk: {
        std.log.warn(
            "REWIND_WORKERS={d} leaves no slot for the private deploy listener; " ++
                "serving with {d} worker(s) so the loopback listener keeps its slot",
            .{ requested_workers, boot.MAX_WORKERS - 1 },
        );
        break :blk boot.MAX_WORKERS - 1;
    } else requested_workers;

    // One slot per thread, private included. Sizing these from `worker_count`
    // alone would leave the private worker indexing one past the end of both
    // arrays: the proxy inboxes bounds-check and would silently DROP its
    // results, and `blob_coord`'s `durableSeq` / `bodyRef` guard only with
    // `std.debug.assert`, which ReleaseFast removes — an out-of-bounds read in
    // the build production runs.
    const total_workers = worker_count + @intFromBool(want_private);
    try node_state.startProxyEngine(total_workers);
    try node_state.blob_coord.start(@intCast(total_workers));

    const addr = try std.net.Address.parseIp("0.0.0.0", port);
    // Loopback by construction: the OS, not a header or a peer-address
    // heuristic, is what makes this plane private. The publish door accepts the
    // platform-wide root bearer only on a request that arrived here.
    const private_addr = try std.net.Address.parseIp("127.0.0.1", private_port);

    // Dedicated loopback HTTP/1.1 operator-metrics listener — separate from the
    // h2c data port (:8443) so stock Prometheus/Alloy can scrape it (they can't
    // speak h2c), and so `/metrics` stays answerable when the main h2 path is
    // wedged. Bound to 127.0.0.1 (node-local Alloy scrapes; network isolation is
    // the auth). `REWIND_METRICS_PORT=0` disables it; default 9110.
    const metrics_srv: ?*rjs.MetricsServer =
        boot.metricsFromEnv(allocator, "REWIND_METRICS_PORT", boot.METRICS_PORT_WORKER, "rewind");
    defer if (metrics_srv) |m| m.deinit();

    const readies = try allocator.alloc(std.Thread.ResetEvent, total_workers);
    defer allocator.free(readies);
    for (readies) |*ev| ev.* = .{};
    const ctxs = try allocator.alloc(WorkerCtx, total_workers);
    defer allocator.free(ctxs);
    const threads = try allocator.alloc(std.Thread, total_workers);
    defer allocator.free(threads);

    for (ctxs, threads, readies, 0..) |*ctx, *th, *ready, i| {
        ctx.* = .{
            .allocator = allocator,
            .worker_idx = @intCast(i),
            // The last slot is the private listener when one is configured;
            // every other slot shares the public SO_REUSEPORT socket.
            .http_addr = if (want_private and i == total_workers - 1) private_addr else addr,
            .plane = if (want_private and i == total_workers - 1) .private else .public,
            .io_opts = if (want_private and i == total_workers - 1) PRIVATE_IO_OPTS else PUBLIC_IO_OPTS,
            .raft = bridge,
            .node = &node_state,
            .log_batch_store = log_batch_store,
            .data_dir = data_dir,
            .admin_api_domain = admin_api_domain,
            .move_secret = move_secret,
            .keyring_kek = keyring_kek,
            .cluster_id = cluster_id,
            .cp_urls = cp_urls,
            .log_push_bases = log_push_bases,
            .services_jwt_secret = services_jwt_secret,
            .peer_urls = peer_urls,
            .ready = ready,
            // The metrics render reads live h2 + dispatch state only its
            // own thread may touch, so exactly one worker publishes. The
            // figures it cannot see from there are already node-wide
            // atomics on `NodeState` / `Bridge`.
            .metrics = if (i == 0) metrics_srv else null,
        };
        th.* = try std.Thread.spawn(.{}, workerThreadEntry, .{ctx});
    }
    // Every worker, not just the first: a partially-ready start would
    // accept connections into a worker that has not opened its stores.
    for (readies) |*ev| ev.wait();

    // A public serving thread that could not start is fatal — the node would
    // silently serve at a fraction of its configured capacity, which reads as
    // a performance mystery rather than a failure. The private listener is
    // optional in the same sense the metrics listener is: its port may already
    // be held by another node on this box, and losing it costs break-glass
    // access, not service. Losing it is loud here AND at the door, which
    // refuses the root bearer on every remaining listener.
    var private_up = want_private;
    for (ctxs) |*ctx| {
        if (!ctx.failed.load(.acquire)) continue;
        if (ctx.plane == .private) {
            private_up = false;
        } else {
            std.log.err("rewind: worker {d} failed to start; refusing to serve degraded", .{ctx.worker_idx});
            return error.WorkerStartFailed;
        }
    }
    std.log.info(
        "rewind: listening on 0.0.0.0:{d} with {d} worker(s) (data_dir={s}, admin_domain={s})",
        .{ port, worker_count, data_dir, admin_api_domain },
    );
    if (private_up) {
        std.log.info(
            "rewind: private deploy listener on http://127.0.0.1:{d} (root bearer accepted here only)",
            .{private_port},
        );
    } else if (want_private) {
        std.log.warn(
            "rewind: private deploy listener on 127.0.0.1:{d} did not start " ++
                "(port already in use?) — the publish door will refuse the root bearer",
            .{private_port},
        );
    } else {
        std.log.warn(
            "rewind: no private deploy listener (REWIND_DEPLOY_PRIVATE_PORT=0) — " ++
                "the publish door will refuse the root bearer on every listener",
            .{},
        );
    }

    while (!stop_flag.load(.acquire)) std.Thread.sleep(100 * std.time.ns_per_ms);
    // Join ALL workers before the leadership handoff below — a group
    // handed off while a worker is still dispatching for it would serve
    // the tail of a batch it no longer leads.
    for (threads) |th| th.join();
    // Graceful leadership handoff: BEFORE tearing the pump down, hand every
    // group this node leads to a caught-up follower so a rolling restart (the
    // `/deploy` path) costs ~one heartbeat per group instead of a full
    // election timeout. The pump still runs here (it lives in this scope and
    // is stopped only by the `bridge.stopPump` below), so it drives the
    // resulting MsgTimeoutNow → step-down readies and republishes `is_leader`.
    // Wait a bounded window for the handoffs to land. Single-node returns 0
    // and skips the wait.
    const handed_off = bridge.transferAllLeadership();
    if (handed_off > 0) {
        std.log.info("rewind: handed off leadership of {d} group(s); draining", .{handed_off});
        var spins: usize = 0;
        while (bridge.leadsAnyGroup() and spins < 200) : (spins += 1)
            std.Thread.sleep(10 * std.time.ns_per_ms); // up to ~2s grace
    }
    // Teardown order: the pump fires the deploy apply observer into
    // `node_state` (`setApplyObserver` above), but `node_state`'s defer —
    // declared after the bridge — deinits BEFORE `bridge.deinit` joins the
    // pump in the LIFO unwind. A follower applying `_deploy/current` in
    // that window dereferences a freed NodeState. Stop the pump first
    // (idempotent — `bridge.deinit`'s own `stopPump` becomes a no-op),
    // mirroring the CP's documented pump-before-observer-target ordering.
    bridge.stopPump();
    std.log.info("rewind: shut down", .{});
}

test {
    // Test discovery: Zig compiles tests only from files a test build
    // reaches, and importing a file for its declarations does not reach it.
    // `scripts/ops/test_reachability_lint.py` fails when one is missing here.
    _ = @import("version.zig");
}
