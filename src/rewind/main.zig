//! rewind — the V2 single-node worker binary (v2-build-order
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

/// Parse a `u16` port from `name`, falling back to `default` when unset or
/// malformed. `0` is a valid value (disables the listener at the call site).
fn parsePortEnv(name: []const u8, default: u16) u16 {
    const s = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(u16, s, 10) catch default;
}

/// V2 on-promotion recovery hook — closes the two failover-recovery gaps the
/// smoke audit surfaced (`leader_failover_smoke_v2` / `durable_wake_smoke_v2`).
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
/// V1's `loop46` drove this off a single node-wide `was_leader` edge; V2
/// leadership is per-group, so the edge is per-tenant. The deployment reload is
/// per promoted tenant; the watermark sweeps are partition-wide + idempotent
/// (the per-group propose gate inside each no-ops tenants this node does not
/// lead), so they run once per tick whenever any promotion landed — matching
/// V1's once-per-edge semantics.
/// DP apply observer (`bridge.setApplyObserver`): fired on the pump thread once
/// per committed PUT on a FOLLOWER (the leader's apply is skipped). Detects the
/// replicated `_deploy/current` marker and enqueues a load so the follower
/// tracks the tenant's current deployment continuously — see
/// `DeploymentCache.enqueueDeployment` for why. `ctx` is `*NodeState`.
///
/// `id_str` is the tenant the writeset TARGETED — for a release published
/// through the admin batch (a `multi` cross-tenant inner) that is the
/// release's target tenant, NOT the admin anchor whose group carried the
/// entry, so it must come from the observer (the old `idStrForGid(gid)`
/// lookup resolved the anchor and enqueued the wrong tenant's deployment).
/// Borrowed for the call; the loader dups it. Empty for root writesets
/// (no `_deploy/current` key there — the key check filters them).
fn onDeployApply(ctx: *anyopaque, gid: u64, id_str: []const u8, key: []const u8, value: []const u8) void {
    _ = gid;
    if (!std.mem.eql(u8, key, "_deploy/current")) return;
    if (id_str.len == 0) return;
    const node: *rjs.NodeState = @ptrCast(@alignCast(ctx));
    const dep_id = std.fmt.parseInt(u64, value, 16) catch return;
    node.deploy.enqueueDeployment(id_str, dep_id);
}

/// Poll-loop hook: move the pump's queued snapshot catch-up jobs onto the
/// background `SnapshotCatchupThread` (raft-native-alignment Phase 1). Cheap —
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
        catchup.enqueue(.{ .gid = j.gid, .peer = j.peer, .index = j.index, .term = j.term, .id_str = id_dup }) catch {
            worker.allocator.free(id_dup);
            worker.raft.clearSnapshotCatchup(j.gid, j.peer);
        };
    }
}

fn runPromotionHook(worker: anytype, worker_idx: usize) void {
    var buf: [64][]const u8 = undefined;
    const n = worker.raft.drainPromotions(&buf);
    if (n == 0) return;
    for (buf[0..n]) |tenant_id| {
        worker.node.deploy.enqueueCurrentDeployment(tenant_id);
    }
    // Worker-0-only for the boot-subscription sweep (avoids duplicate enqueues
    // across a node's workers); rewind runs a single worker, but keep the gate
    // for forward-compat. The wake sweep is partitioned by
    // `hash(tenant) % N_inboxes`, so every worker covers its own slice exactly
    // once and it runs unconditionally. (The owed retry sweep retired with
    // durable-wake-plan P5(a) — webhook recovery is a durable wake now.)
    if (worker_idx == 0) rjs.sweepBootSubscriptions(worker);
    rjs.sweepDurableWakesOnPromotion(worker);
}

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

    // Background compile+stage thread for `/_system/deploy`
    // (docs/plans/rewind-cli-plan.md §4 — files-server dissolution). Owns its
    // own QuickJS runtime so it never races the poll-loop compiler.
    try worker.startDeployThread();

    // Out-of-band snapshot catch-up driver (raft-native-alignment Phase 1):
    // the pump's `snapshotTriggerTick` queues a `(gid, peer)` for any peer in
    // `StateSnapshot`; this thread dumps the leader's store + pushes
    // `v2-load-replace` + `v2-apply-snapshot` to the peer, off the poll loop.
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
    // raft Phase 2.5: the same off-loop driver also runs CP-triggered move
    // pushes (`/_system/v2-snapshot-push` → `armSnapshotPush` enqueues here).
    worker.snapshot_push_driver = catchup;

    std.log.info("rewind worker {d}: ready (SO_REUSEPORT)", .{args.worker_idx});
    args.ready.set();

    var blocked_tenants: rjs.BlockedTenants = .{};
    // Render + publish the operator-metrics snapshot to the loopback HTTP/1.1
    // listener every ~2s (cheap; the listener serves the latest — a few seconds
    // stale is nothing for a 60s scrape). `last_metrics_ns = 0` makes the first
    // iteration publish immediately. The render MUST run on this thread:
    // buildMetricsText reads live h2/dispatch + raft state only it may touch.
    var last_metrics_ns: i64 = 0;
    // Deploy capability is bootstrapped explicitly via `POST /_system/reset`
    // (rewind-cli-plan §4) — the operator/harness deploys the baked `__admin__`
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
        runPromotionHook(worker, args.worker_idx);
        drainSnapshotCatchupJobs(worker, catchup);
        try rjs.drainForwardPending(worker);
        // raft Phase 2.5: finalize completed streamed-snapshot transfers
        // (install the baseline + respond) parked in `snapshot_streams`, and
        // respond to parked CP-triggered move pushes as the driver finishes them.
        try rjs.drainSnapshotStreams(worker);
        try rjs.drainSnapshotPushes(worker, catchup);
        rjs.drainSpools(worker);
        try rjs.sweepParkedContinuations(worker);
        // Gap 2.4 (docs/architecture/effects-and-handlers.md): fire the next staged
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
/// or trip on its lease/txn state mid-mutation — the intermittent
/// `Sqlite` pump panic the failover smoke caught once apply failures
/// became fatal. Each resolved id instead gets a PUMP-OWNED sibling
/// handle attached into the SAME manifest at the SAME store id: the
/// underlying store state (kvexp `TenantState` — overlay, LMDB, lease)
/// is per store-id and internally locked, so the data stays unified
/// (the worker serves exactly what the pump applies — the Phase-5
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
        const h = kv.KvStore.attachSibling(
            self.allocator,
            self.tenant.root,
            kv.hashStoreId(id_str),
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
/// present (that's the legacy multi-node path, kept until Phase 3 deletes it).
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
    const colon = std.mem.lastIndexOfScalar(u8, t, ':') orelse return error.BadRaftAddr;
    const port = try std.fmt.parseInt(u16, t[colon + 1 ..], 10);
    const listen_addr = try std.net.Address.parseIp(t[0..colon], port);
    return Genesis{
        .node_id = node_id,
        .listen_addr = listen_addr,
        .listen_str = try a.dupe(u8, t),
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
    const first_arg = arg_it.next();
    // `rewind --version` dumps the format-version registry and exits
    // (`docs/plans/format-versioning-audit.md` §3.8). Done before any data-dir
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

    // Peer HTTP base URLs indexed by raft id − 1 (the worker analog of CP's
    // `REWIND_CP_PEER_URLS`): the leader-push target for the out-of-band
    // snapshot catch-up driver (raft-native-alignment Phase 1). DISTINCT from
    // `REWIND_PEERS` (the raft transport `host:port`s); these are the workers'
    // HTTP `/_system/` listen origins. Unset (single-node) → catch-up disabled.
    const peer_urls = try parseUrlList(allocator, std.posix.getenv("REWIND_PEER_URLS") orelse "");
    defer freeUrlList(allocator, peer_urls);

    // Step 3 (step3-auth-plan.md A2/A3): wire the `rewind-logs.internal`
    // fetch-engine door so the `__admin__` chokepoint reads tenant logs with a
    // worker-minted, tenant-scoped `logs-read` token. The secret is the SAME
    // hex `LOOP46_SERVICES_JWT_SECRET` the log-server verifies with (hex-decoded
    // to raw HMAC bytes here, matching the log-server). Both optional: unset →
    // the door is disabled (`error.LogsDoorUnconfigured`).
    const services_jwt_secret: ?[]const u8 = blk: {
        const hex = std.posix.getenv("LOOP46_SERVICES_JWT_SECRET") orelse break :blk null;
        if (hex.len == 0 or hex.len % 2 != 0) {
            std.log.err("rewind: LOOP46_SERVICES_JWT_SECRET must be even-length hex", .{});
            std.process.exit(2);
        }
        const bytes = try allocator.alloc(u8, hex.len / 2);
        _ = std.fmt.hexToBytes(bytes, hex) catch {
            std.log.err("rewind: LOOP46_SERVICES_JWT_SECRET is not valid hex", .{});
            std.process.exit(2);
        };
        break :blk bytes;
    };
    defer if (services_jwt_secret) |s| allocator.free(s);
    // Worker's internal-plane view of the standalone log-server (no trailing
    // slash, e.g. `http://127.0.0.1:9000`). Env memory lives for the process,
    // so no dup/free.
    const log_internal_base: ?[]const u8 = std.posix.getenv("REWIND_LOG_INTERNAL_BASE");

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

    // Pump-side store handles (two-handle model — see `PumpStores`).
    // Declared BEFORE the bridge so its deinit (LIFO) runs AFTER
    // `bridge.deinit` joins the pump thread — the resolver's handles
    // must outlive every pump-thread apply.
    var pump_stores = PumpStores{ .allocator = allocator, .tenant = node_tenant };
    defer pump_stores.deinit();

    // The V2 per-tenant raft bridge + its pump thread. Leader-skip: the
    // worker owns the speculative overlay. Single node by default; a
    // multi-node (Phase 5 HA) node is configured by env — this node's
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
        // seeded with the statically-configured peers — so today's behavior is
        // unchanged, but attach / conf-change can teach it nodes beyond the
        // static set, and Phase 3 can drop the static seed entirely.
        b.enablePeerRegistry() catch return error.OutOfMemory;
        for (mn.peers, 0..) |p, i| try b.learnPeer(@intCast(i + 1), p.host, p.port);
        break :blk b;
    } else try Bridge.initSingleNode(allocator, data_dir);
    defer bridge.deinit();
    bridge.setWorkerOverlay();
    // Full-HA store unification (Phase 5): a FOLLOWER has no worker serving
    // this tenant, so its replicated writes must land in the SAME store a
    // worker WOULD serve from — the same manifest + store id the tenant's
    // `inst.kv` serves, via the pump's OWN sibling handle (two-handle
    // model, see `PumpStores`) — so a follower promoted to leader after a
    // failover serves the data it replicated, without the pump ever
    // touching the worker handle's txn state. Set BEFORE startPump so the
    // first replicated entry already routes here.
    bridge.setStoreResolver(.{ .ctx = &pump_stores, .func = PumpStores.resolve });
    // Auto-demote policy (conf_change Phase 2): a far-behind, presumed-dead
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
    // (docs/plans/raft-best-practices.md "how to size election/heartbeat").
    if (std.posix.getenv("REWIND_RAFT_TICK_MS")) |v| {
        if (std.fmt.parseInt(i64, v, 10)) |ms| {
            if (ms > 0) {
                bridge.node.tick_interval_ns = ms * std.time.ns_per_ms;
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
    try bridge.startPump();

    // Per-tenant request-log / tape batches → S3. The only tape-query surface,
    // `rewind-logs`, reads S3-only (its indexer LISTs + serves
    // `/v1/{tenant}/list` + `/show`), so a local `FsBatchStore` would be
    // unreadable by it — writer (fs) and reader (S3) never met, which is why
    // captured tapes could never be queried back out for replay. Build the
    // batch store from the SAME S3 connection params as the blob backend (rove
    // blob is S3-only), plus an optional `LOG_S3_KEY_PREFIX` so log batches can
    // sit under a named prefix; both sides default to "" and so agree. The
    // worker's single background flusher thread serializes all PUTs through
    // this store's one libcurl handle (rewind runs a single worker — see
    // below; a multi-worker node would need a per-flusher handle).
    const log_key_prefix = (try blob_mod.env.envOpt(allocator, "LOG_S3_KEY_PREFIX")) orelse
        try allocator.dupe(u8, "");
    defer allocator.free(log_key_prefix);
    const log_s3 = try log_server.batch_store_s3.S3BatchStore.init(allocator, .{
        .endpoint = blob_owned.cfg.endpoint,
        .region = blob_owned.cfg.region,
        .bucket = blob_owned.cfg.bucket,
        .key_prefix = log_key_prefix,
        .access_key = blob_owned.cfg.access_key,
        .secret_key = blob_owned.cfg.secret_key,
        .use_tls = blob_owned.cfg.use_tls,
    });
    defer log_s3.deinit();
    const log_batch_store = log_s3.batchStore();

    // Process-shared node state (tenant resolver, deployment cache, blob
    // coordinator, msg router, builtin modules).
    var node_state = try rjs.NodeState.init(allocator, node_tenant, blob_owned.cfg, bridge);
    defer node_state.deinit();
    // Step 3: hand the node the credential + base for the `rewind-logs.internal`
    // door (borrowed; both outlive node_state per defer ordering above).
    node_state.services_jwt_secret = services_jwt_secret;
    node_state.log_internal_base = log_internal_base;
    // Step 3 B4: the `rewind-cp.internal` door — the move-secret (already read
    // for the move surface) + a CP base (the first configured CP node; the CP
    // forwards control writes to its leader). Both borrowed (env / cp_urls live
    // for the process). Either unset → the CP door is disabled.
    node_state.move_secret = move_secret;
    node_state.cp_internal_base = if (cp_urls.len > 0) cp_urls[0] else null;
    node_state.wireInternal();
    try node_state.deploy.startDeploymentLoader();
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
    // Async serve-or-forward engine. rewind runs a single worker (idx 0).
    try node_state.startProxyEngine(1);
    try node_state.blob_coord.start(1);

    // One worker thread bound to the listen port (SO_REUSEPORT-ready).
    const addr = try std.net.Address.parseIp("0.0.0.0", port);

    // Dedicated loopback HTTP/1.1 operator-metrics listener — separate from the
    // h2c data port (:8443) so stock Prometheus/Alloy can scrape it (they can't
    // speak h2c), and so `/metrics` stays answerable when the main h2 path is
    // wedged. Bound to 127.0.0.1 (node-local Alloy scrapes; network isolation is
    // the auth). `REWIND_METRICS_PORT=0` disables it; default 9110.
    const metrics_srv: ?*rjs.MetricsServer = blk: {
        const ms_port = parsePortEnv("REWIND_METRICS_PORT", 9110);
        if (ms_port == 0) break :blk null;
        const ms_addr = std.net.Address.parseIp("127.0.0.1", ms_port) catch break :blk null;
        const srv = rjs.MetricsServer.init(allocator, ms_addr) catch |err| {
            std.log.warn("rewind: operator metrics listener disabled — bind 127.0.0.1:{d} failed ({s})", .{ ms_port, @errorName(err) });
            break :blk null;
        };
        std.log.info("rewind: operator metrics on http://127.0.0.1:{d}/metrics", .{ms_port});
        break :blk srv;
    };
    defer if (metrics_srv) |m| m.deinit();

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
        .peer_urls = peer_urls,
        .ready = &ready,
        .metrics = metrics_srv,
    };
    var th = try std.Thread.spawn(.{}, workerThreadEntry, .{&ctx});
    ready.wait();
    std.log.info("rewind: listening on 0.0.0.0:{d} (data_dir={s}, admin_domain={s})", .{ port, data_dir, admin_api_domain });

    while (!stop_flag.load(.acquire)) std.Thread.sleep(100 * std.time.ns_per_ms);
    th.join();
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
