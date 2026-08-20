// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `/_system/*` operator surface — the admin/control route family split
//! out of `worker_dispatch.zig` so that file can stay focused on the
//! request hot path (`dispatchOnce` / `finalizeBatch` / `resolveRequest`).
//!
//! `tryHandleSystem` is the single entry point (called from `dispatchOnce`):
//! CORS preflight, the Prometheus `metrics` render (`buildMetricsText`,
//! re-exported from `root.zig`), raft snapshot bundling, the release POST
//! (config-mirror), reset, and admin-kv. Every function takes
//! `server`/`worker` as `anytype` — same structural-typing shape as the
//! rest of the worker_*.zig family.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const kv_mod = @import("raft-kv");
const jwt = @import("rove-jwt");
const tenant_mod = @import("rove-tenant");
const effect_mod = @import("effect/root.zig");

const respb = @import("response_builder.zig");
const auth = @import("auth.zig");
const raft_propose = @import("raft_propose.zig");
const v2_move = @import("v2_move.zig");
const worker_mod = @import("worker.zig");

const RaftWait = worker_mod.RaftWait;

/// `/_system/*` route handler — CORS preflight + `release` POST +
/// admin-kv + raft-snapshot. Returns true iff the request matched and
/// was finalized (response stamped + moved to `response_in`).
pub fn tryHandleSystem(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    path: []const u8,
    rh: h2.ReqHeaders,
    body: []const u8,
) !bool {
    if (!std.mem.startsWith(u8, path, "/_system/")) return false;

    // Every /_system/* response carries CORS headers when the worker
    // has an admin origin configured. Browsers enforce the origin
    // match on their side against `Access-Control-Allow-Origin`, so
    // stamping headers even on requests without an Origin is harmless.
    const cors_origin = worker.admin_origin;

    // Preflight: browser sends OPTIONS before the real request to
    // discover allowed methods/headers. Answer 204 with the
    // preflight-specific CORS headers and never touch auth —
    // preflights don't carry the bearer token.
    if (std.mem.eql(u8, method, "OPTIONS")) {
        if (cors_origin) |o| {
            const req_origin = respb.findHeader(rh, "origin") orelse "";
            if (req_origin.len == 0 or !std.mem.eql(u8, req_origin, o)) {
                try respb.setSystemResponse(server, ent, sid, sess, 403, "cors origin not allowed\n", allocator, null, null);
            } else {
                const hdrs = try respb.buildSystemRespHeaders(allocator, o, true, null);
                try respb.finalizeResponse(server, ent, sid, sess, 204, hdrs, null, 0);
            }
        } else {
            try respb.setSimpleResponse(server, ent, sid, sess, 405, "OPTIONS not supported\n", allocator);
        }
        return true;
    }

    // Strip `?query=string` off the path before routing.
    const qmark = std.mem.indexOfScalar(u8, path, '?');
    const path_no_q = if (qmark) |q| path[0..q] else path;
    const sys_rest = path_no_q["/_system/".len..];

    // The cluster-internal tenant-move surface (`v2-*`). It
    // carries its own `move_secret` auth (the front door holds it, not the
    // operator root bearer) and no CORS, so it short-circuits before the
    // admin-auth gate below. Disabled (404) when no move secret is set.
    if (try v2_move.tryHandleV2(server, allocator, worker, ent, sid, sess, method, sys_rest, path, rh, body)) {
        return true;
    }

    // Liveness probe for load balancers / systemd-style supervisors.
    // No auth, no leadership-aware semantics — just "this process is
    // up enough to serve the dispatch loop." Operators wanting a
    // leader-aware health check should probe `/_system/leader`
    // instead. Always 200 on a running worker; the request never
    // arrives here if the listener is wedged.
    if (std.mem.eql(u8, sys_rest, "health")) {
        try respb.setSystemResponse(server, ent, sid, sess, 200, "ok\n", allocator, cors_origin, null);
        return true;
    }

    // Per-endpoint auth. Most `/_system/*` endpoints require admin
    // auth (root bearer or session cookie); a small allow-list of
    // cluster-internal endpoints also accept a services-JWT carrying
    // the matching capability, so a peer service can push a release or
    // pull a snapshot without holding the operator's root bearer. The cap
    // alternative is gated to the exact endpoint that needs it —
    // there is no global "admin or cap" pass.
    const required_cap: ?[]const u8 = if (std.mem.eql(u8, sys_rest, "release"))
        jwt.Cap.RELEASE
    else if (std.mem.eql(u8, sys_rest, "admin-kv"))
        jwt.Cap.ADMIN_KV
    else if (std.mem.startsWith(u8, sys_rest, "raft-snapshot/"))
        jwt.Cap.RAFT_SNAPSHOT
    else
        null;

    if (!try authorizeSystemRequest(server, allocator, worker, ent, sid, sess, rh, cors_origin, required_cap)) {
        return true;
    }

    // Operator/bootstrap release endpoint. The `rewind` CLI's
    // root-token path and `rewind-ops release` POST
    // `{"tenant_id":"...","dep_id":N}` here. It is the only way to
    // publish the platform tenants (`__admin__`, `__replay__`):
    // a chicken-and-egg, since __admin__'s own handler can't be the
    // entry point until `_deploy/current` has been stamped to point
    // at __admin__'s manifest. Customer release traffic goes through
    // `__admin__`'s deployed `publishRelease` RPC instead.
    if (std.mem.eql(u8, sys_rest, "release")) {
        try handleRelease(server, allocator, worker, ent, sid, sess, method, body, cors_origin);
        return true;
    }

    // Bootstrap + break-glass (`docs/architecture/cli-and-deploy.md` §4). Root-token
    // gated, NO body: (re)deploy the BAKED `__admin__` deploy app and stamp
    // `_deploy/current`, recovering a virgin or bricked control tenant. Every
    // ARBITRARY deploy (the full admin, customers) goes THROUGH the deployed
    // app — this route only ever deploys the embedded bundle, idempotently
    // (content-addressed → same dep_id on re-run).
    if (std.mem.eql(u8, sys_rest, "reset")) {
        try handleReset(server, allocator, worker, ent, sid, sess, method, cors_origin);
        return true;
    }

    // Leader-status probe used by smokes and the operator publish path
    // to discover which node will accept release / admin-kv POSTs. The
    // tenant-routing leader-skip in dispatchOnce doesn't apply here
    // (`/_system/*` short-circuits before tenant routing), so /_system
    // probes alone can't tell leader from follower. Returns 200 on the
    // leader and 503 ("not leader; retry against the cluster leader\n")
    // on followers — same shape as the customer-tenant leader-skip
    // response so tooling can treat both the same way.
    if (std.mem.eql(u8, sys_rest, "leader")) {
        // V2 leadership is per-tenant-group; this node-wide probe reports
        // whether this node leads ANY group (readiness/serves-as-leader),
        // NOT per-tenant routing — clients still get a per-tenant 421 re-aim
        // at propose time. Single-node always 200 (preserves smoke probes).
        if (worker.raft.leadsAnyGroup()) {
            try respb.setSystemResponse(server, ent, sid, sess, 200, "leader\n", allocator, cors_origin, null);
        } else {
            try respb.setSystemResponse(server, ent, sid, sess, 503, "not leader; retry against the cluster leader\n", allocator, cors_origin, null);
        }
        return true;
    }

    // Operator metrics in Prometheus text format. Surfaces the
    // conservation-pair counters whose imbalance signals invariant
    // violations (kernel-buffer pool, h2 collection sizes, ...). Root-
    // token gated like the rest of `/_system/*`. The point of this
    // endpoint is *not* a dashboard — it's making the math visible so
    // the next investigator can read the imbalance at a glance, the
    // way the io-buffer-leak postmortem identified `consumed - returned
    // = buf_count` once the right two numbers were paired in one line.
    if (std.mem.eql(u8, sys_rest, "metrics")) {
        try handleMetrics(server, allocator, worker, ent, sid, sess, cors_origin);
        return true;
    }

    // Raft snapshot fetch — out-of-band catchup for far-behind
    // followers. Cap-gated above so any
    // peer holding the shared services JWT can pull. Streams a
    // bundle of the leader's app.dbs + __root__.db + schedules.db
    // captured via VACUUM INTO for consistency. Path:
    //   /_system/raft-snapshot/{snap_id_hex}
    if (std.mem.startsWith(u8, sys_rest, "raft-snapshot/")) {
        try handleRaftSnapshot(server, allocator, worker, ent, sid, sess, method, sys_rest, cors_origin);
        return true;
    }

    // Cluster-wide admin config push. The operator POSTs
    // `{"pairs":[{"key":"...","value":"..."},...]}` here (root bearer)
    // at platform bootstrap time so operator-supplied config lands in
    // `__admin__/app.db` via raft (envelope 0).
    if (std.mem.eql(u8, sys_rest, "admin-kv")) {
        try handleAdminKv(server, allocator, worker, ent, sid, sess, method, body, cors_origin);
        return true;
    }

    // No proxy subsystems live on the worker — the log, files, kv, and
    // tenant `/_system/*` routes are served by the standalone services
    // or the `__admin__` JS handler, not here.
    try respb.setSystemResponse(server, ent, sid, sess, 501, "system endpoint not implemented\n", allocator, cors_origin, null);
    return true;
}

/// Auth gate for `/_system/*` requests. Accepts either:
///   - admin auth: session cookie (`rove_session`) or `Authorization:
///     Bearer <root-token>`
///   - **only when `required_cap` is set**: a services-JWT signed by
///     `LOOP46_SERVICES_JWT_SECRET` whose `caps` claim contains the
///     given cap — how a peer service pushes a release or pulls a
///     snapshot without holding the operator's root bearer.
///
/// Returns true when the caller is allowed to proceed, false when
/// the response (401 / 500) has already been stamped onto the entity.
fn authorizeSystemRequest(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    rh: h2.ReqHeaders,
    cors_origin: ?[]const u8,
    required_cap: ?[]const u8,
) !bool {
    const auth_ctx = auth.extractAdminAuth(worker.node.tenant, rh) catch |err| {
        std.log.warn("rove-js: authenticate failed: {s}", .{@errorName(err)});
        try respb.setSystemResponse(server, ent, sid, sess, 500, "auth check failed\n", allocator, cors_origin, null);
        return false;
    };
    if (auth_ctx != null) return true;

    // Admin auth missing/invalid. If this endpoint accepts a cap
    // alternative, try the services-JWT.
    if (required_cap) |cap| {
        const secret = worker.services_jwt_secret;
        const token = auth.extractBearerToken(rh);
        if (secret != null and token != null) {
            const now_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
            if (jwt.verifyWithCap(secret.?, token.?, now_ms, cap)) |_| {
                return true;
            } else |_| {
                // Fall through to 401 — the cap check failed for
                // some reason (expired, wrong secret, missing cap).
            }
        }
    }

    try respb.setSystemResponse(server, ent, sid, sess, 401, "unauthenticated\n", allocator, cors_origin, null);
    return false;
}

/// Emit operator metrics in Prometheus text format. Scope is
/// conservation-pair counters — every "consumed" / "created" /
/// "submitted" counter is paired with its complementary
/// "returned" / "destroyed" / "committed" counter so the operator
/// (or the next investigator) can read the imbalance directly
/// instead of inferring it from a downstream symptom like ENOBUFS.
///
/// Names follow Prometheus conventions (snake_case, `_total` suffix
/// on counters, no suffix on gauges). Labels (`{src="..."}`) are
/// used when one logical counter has multiple sources, e.g.
/// io_recv_buffers_returned_total has `src="drain"` and
/// `src="deinit"` so the postmortem-relevant split stays visible.
///
/// Not gated behind a feature flag — the cost is one allocPrint
/// per call. The endpoint isn't scraped continuously by anything
/// today; it's a probe.
fn handleMetrics(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    cors_origin: ?[]const u8,
) !void {
    const body = try buildMetricsText(allocator, worker);
    try respb.setSystemResponseOwned(server, ent, sid, sess, 200, body, allocator, cors_origin, "text/plain; version=0.0.4");
}

/// Render the operator metrics as Prometheus text into a caller-owned buffer —
/// the shared body builder behind BOTH `/_system/metrics` (h2c, manual probe)
/// and the dedicated h1 metrics listener (`metrics_server`, the scrape target).
/// MUST run on the worker thread: it reads live per-worker h2/dispatch state and
/// shared raft state with no lock, and the worker thread is that state's only
/// writer. (The h1 listener never calls this — the worker thread renders and
/// `publish`es the bytes to it.)
pub fn buildMetricsText(allocator: std.mem.Allocator, worker: anytype) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    const w = &aw.writer;

    // io-ring + connection-depth metrics: shared formatter (rove-h2),
    // identical on the worker and the front so the two can't drift.
    try worker.h2.writeConnMetrics(w);

    // Which storage generation this process resolved at startup (the
    // storage-namespace section of `docs/architecture/deployment-and-logs.md`).
    // Scraped so a cluster whose nodes disagree — one restarted across a
    // namespace bump, say — is visible instead of silently writing two
    // histories. The marker is read once at startup, so this is exactly what
    // the process is using until it restarts.
    try w.print(
        \\# HELP storage_namespace_info the object-store key prefix this process resolved at startup. Nodes must agree.
        \\# TYPE storage_namespace_info gauge
        \\storage_namespace_info{{prefix="{s}"}} 1
        \\
    , .{worker.node.blob_backend_cfg.key_prefix_base});

    // raft-pending is worker-only (the front has no raft path) — emit it
    // separately. Sum the three siblings: "how many entities are parked
    // on raft commit," not which destination.
    try w.print(
        \\# HELP h2_raft_pending_size requests parked on raft commit.
        \\# TYPE h2_raft_pending_size gauge
        \\h2_raft_pending_size {d}
        \\
    , .{
        worker.raft_pending_response.entitySlice().len + worker.raft_pending_cont.entitySlice().len + worker.raft_pending_stream.entitySlice().len,
    });

    // ── leader/follower role ──────────────────────────────────────────
    //
    // Helps an operator scraping a fleet tell which node is leader
    // without running a separate /_system/leader probe.
    try w.print(
        \\# HELP raft_is_leader 1 if this node leads at least one tenant group, 0 otherwise (V2 leadership is per-group).
        \\# TYPE raft_is_leader gauge
        \\raft_is_leader {d}
        \\
    , .{@intFromBool(worker.raft.leadsAnyGroup())});

    // ── per-group leadership health (aggregate; no per-tenant labels) ──
    //
    // raft_groups_no_leader is THE wedge signal: groups this node neither leads
    // nor knows a leader for (leader_id=0). 0 on a healthy cluster (every
    // follower tracks its leader); a brief spike during an election; SUSTAINED
    // > 0 is the incident — both the genesis cold-multi wedge and the
    // __admin__-stuck-at-{1,2} grow wedge held no_leader > 0 for >25s. Alert on
    // duration, not the transient.
    const gc = worker.raft.groupCounts();
    try w.print(
        \\# HELP raft_groups raft groups on this node.
        \\# TYPE raft_groups gauge
        \\raft_groups {d}
        \\# HELP raft_groups_led groups this node currently leads.
        \\# TYPE raft_groups_led gauge
        \\raft_groups_led {d}
        \\# HELP raft_groups_no_leader groups this node neither leads nor knows a leader for (leader_id=0) — the wedge signal; sustained > 0 = an incident (failed election / lost quorum).
        \\# TYPE raft_groups_no_leader gauge
        \\raft_groups_no_leader {d}
        \\
    , .{ gc.total, gc.led, gc.no_leader });

    // ── raft outbound dial-mesh health (node-wide; the cross-host wedge) ──
    //
    // raftnet_peers_unreachable is THE dial-mesh wedge signal: configured peers
    // (nodes raft must SEND to) whose outbound connection is NOT established.
    // 0 on a healthy mesh; a brief spike on a dial/reconnect; SUSTAINED > 0 is
    // the incident — the cross-host genesis wedge was a zombie-connect that
    // mis-marked a dead fd, so `send` no-op'd forever (one peer permanently
    // unreachable, no quorum). Emitted as a stable series (zeros when there's
    // no transport — a single-node node has no peers to reach).
    const mesh = worker.raft.meshSnapshot();
    const mesh_configured: u32 = if (mesh) |m| m.configured else 0;
    const mesh_connected: u32 = if (mesh) |m| m.connected else 0;
    try w.print(
        \\# HELP raftnet_peers_configured non-self raft peers this node must be able to send to (the outbound mesh it should hold).
        \\# TYPE raftnet_peers_configured gauge
        \\raftnet_peers_configured {d}
        \\# HELP raftnet_peers_connected configured peers with an established outbound connection (raft can send to them).
        \\# TYPE raftnet_peers_connected gauge
        \\raftnet_peers_connected {d}
        \\# HELP raftnet_peers_unreachable configured peers with NO outbound connection (configured − connected) — the dial-mesh wedge signal; sustained > 0 = a node raft can't reach (zombie-connect / partition).
        \\# TYPE raftnet_peers_unreachable gauge
        \\raftnet_peers_unreachable {d}
        \\
    , .{ mesh_configured, mesh_connected, mesh_configured - mesh_connected });

    // ── deployment loader health ──────────────────────────────────────
    //
    // deployment_loads_retrying is the released≠serving signal: tenants
    // whose committed `_deploy/current` could not be loaded into a live
    // snapshot (S3 fetch failure, corrupt manifest object, …) and are
    // parked on the loader's backoff. 0 on a healthy node; SUSTAINED > 0
    // means some tenant serves a stale deployment or 503s while its
    // release sits committed — alert on duration, like the raft wedge
    // gauges. failures_total distinguishes a persistent failure (climbing
    // ~2/min per stuck tenant, the 30s backoff rung) from a one-off blip.
    if (worker.node.deploy.deployment_loader) |dl| {
        try w.print(
            \\# HELP deployment_load_failures_total failed deployment-load attempts (manifest/bytecode fetch or decode) since start; retries re-count.
            \\# TYPE deployment_load_failures_total counter
            \\deployment_load_failures_total {d}
            \\# HELP deployment_loads_retrying tenants whose released deployment failed to load and is parked on retry backoff — the released!=serving signal; sustained > 0 = a tenant serving stale/503 against a committed release.
            \\# TYPE deployment_loads_retrying gauge
            \\deployment_loads_retrying {d}
            \\
        , .{
            dl.failures_total.load(.monotonic),
            dl.retrying_gauge.load(.monotonic),
        });
    }

    // ── raft failover / broadcast-time observability ──────────────────
    //
    // The inputs for sizing election/heartbeat timeouts in THIS environment
    // (docs/architecture/raft-best-practices.md "how to size ..."):
    //   raft_leadership_acquisitions_total — follower→leader promotion edges.
    //     The spurious-election signal: ~1 per group at formation, then FLAT
    //     under steady load. A rising count under no real failures means the
    //     election timeout is below the pause/jitter tail — widen it.
    //   raft_heartbeat_rtt_us — measured leader↔follower round-trip
    //     (broadcastTime). The election timeout must sit well above this; mean
    //     = _sum / _count. Absent on a single-node node (no transport).
    try w.print(
        \\# HELP raft_leadership_acquisitions_total follower→leader promotion edges observed on this node (spurious-election signal; ~1/group at formation, flat after).
        \\# TYPE raft_leadership_acquisitions_total counter
        \\raft_leadership_acquisitions_total {d}
        \\
    , .{worker.raft.leadershipAcquisitions()});
    if (worker.raft.heartbeatRttSnapshot()) |rtt| {
        try w.print(
            \\# HELP raft_heartbeat_rtt_us leader↔follower heartbeat round-trip in microseconds (broadcast time; election timeout must sit well above this).
            \\
        , .{});
        try writeMicrosHistogram(w, "raft_heartbeat_rtt_us", rtt);
    }

    // ── kvexp: per-node manifest counters / histograms ────────────────
    //
    // Every KvStore on this node attaches to the same `cluster.kv`
    // manifest, so the root store's snapshot reports node-wide totals.
    // Histograms are surfaced with the `_seconds` suffix per Prometheus
    // convention (kvexp records nanoseconds internally; we convert).
    try writeKvexpMetrics(w, worker.node.tenant.root.manifestMetricsSnapshot());

    // ── per-tenant KV footprint (billing axis 1, pricing-model §2) ────
    //
    // One gauge pair per MATERIALIZED instance (a scrape must not
    // create worker-side instances, so dark tenants appear once they
    // take traffic). `used` = durable LMDB pages + committed overlay
    // bytes — the same conservative figure the write-path cap gate
    // reads, so the dashboard, the operator, and the enforcement all
    // agree on what "used" means. O(1) per instance (mdb_stat).
    {
        var ul = worker.node.tenant.listInstanceUsage() catch |err| blk: {
            std.log.warn("metrics: listInstanceUsage: {s}", .{@errorName(err)});
            break :blk tenant_mod.InstanceUsageList{ .entries = &.{}, .allocator = worker.allocator };
        };
        defer if (ul.entries.len > 0) ul.deinit();
        try w.print(
            \\# HELP kv_store_used_bytes per-instance KV footprint: durable LMDB pages + committed overlay bytes (the figure the plan cap is enforced against).
            \\# TYPE kv_store_used_bytes gauge
            \\
        , .{});
        for (ul.entries) |e| {
            try w.print("kv_store_used_bytes{{instance=\"{s}\"}} {d}\n", .{
                e.id, e.usage.durable_bytes + e.usage.overlay_bytes,
            });
        }
        try w.print(
            \\# HELP kv_store_durable_entries per-instance live key count in the durable store.
            \\# TYPE kv_store_durable_entries gauge
            \\
        , .{});
        for (ul.entries) |e| {
            try w.print("kv_store_durable_entries{{instance=\"{s}\"}} {d}\n", .{
                e.id, e.usage.durable_entries,
            });
        }
        try w.print(
            \\# HELP kv_cap_refusals_total write batches refused at the plan KV cap (tenant/figures in the paired kv-cap log line).
            \\# TYPE kv_cap_refusals_total counter
            \\kv_cap_refusals_total {d}
            \\# HELP tape_kv_elided_total kv reads whose value the per-activation tape budget dropped; those records cannot be replayed against those reads (figures in the paired warn log line).
            \\# TYPE tape_kv_elided_total counter
            \\tape_kv_elided_total {d}
            \\
        , .{
            worker.node.kv_cap_refusals.load(.monotonic),
            worker.node.tape_kv_elided.load(.monotonic),
        });
    }

    // ── the wire-limit backstop ─────────────────────────────────────────
    // Should read zero forever: the propose path refuses an oversize entry
    // before it exists. Non-zero means a producer got past that guard and a
    // group is re-emitting an entry it can never deliver.
    {
        try w.print(
            \\# HELP raft_oversize_dropped_total raft messages dropped unsent for exceeding the peer's frame limit (should be 0; a propose should have refused the entry first).
            \\# TYPE raft_oversize_dropped_total counter
            \\raft_oversize_dropped_total {d}
            \\
        , .{worker.raft.transportOversizeDropped()});
    }

    // ── abuse-gate counters ───────────────────────────────────────────
    try w.print(
        \\# HELP log_ingest_limited_total admissions 429'd by the log-byte ingest guardrail (lagging log_bytes bucket).
        \\# TYPE log_ingest_limited_total counter
        \\log_ingest_limited_total {d}
        \\# HELP outbound_sustained_trips_total refusals from the day-scale sustained outbound bucket (spam/flood incident signal; worker-local).
        \\# TYPE outbound_sustained_trips_total counter
        \\outbound_sustained_trips_total {d}
        \\# HELP outbound_not_enabled_total outbound refused because the tenant's plan grants no third-party egress (demand meeting policy: an upgrade lead or an abuser held at the door; worker-local).
        \\# TYPE outbound_not_enabled_total counter
        \\outbound_not_enabled_total {d}
        \\
    , .{
        worker.node.log_ingest_limited.load(.monotonic),
        worker.limiter.sustained_trips,
        worker.limiter.outbound_disabled_refusals,
    });

    // ── propose-pipeline histograms ──────────────────────────────────
    //
    // Two questions the operator wants answered: are we time-capped
    // or size-capped at each layer? And how many customer requests
    // ride one raft log entry?
    //
    //   dispatch_writeset_size_requests   — handler-bound requests
    //     per writeset envelope (observed at `finalizeBatch`).
    //   raft_proposal_batch_size_writesets — writesets per
    //     `raft_recv_entry` call (observed at `packBatch`).
    //   raft_proposal_linger_wait_us       — leader linger time
    //     before each pack.
    //
    // Multiplying the medians of the first two gives "customer
    // requests per raft entry". If the third is bumping the
    // `--propose-linger-us` value, the linger budget could be raised.
    try writeCountHistogram(w, "dispatch_writeset_size_requests", worker.node.dispatch_writeset_size.snapshot());
    // The per-tenant bridge has no global proposer, so there are no
    // leader-side propose-batch/linger histograms to emit here
    // (per-pump-cycle histograms on the bridge are future work).

    // cross-worker held state (`docs/architecture/effects-and-handlers.md`): routing observability.
    // cross_worker counts wake events routed to a worker different
    // from hash(tenant_id) — the cross-worker held-state path. A
    // non-zero count means the SO_REUSEPORT vs hash(tenant_id) gap is
    // being closed in practice.
    try w.print(
        \\# HELP bound_fetch_cross_worker_routes_total bound fetch chunks routed to owner worker ≠ hash(tenant_id) % N (the Phase 2A path).
        \\# TYPE bound_fetch_cross_worker_routes_total counter
        \\bound_fetch_cross_worker_routes_total {d}
        \\# HELP bound_fetch_same_worker_routes_total bound fetch chunks where owner worker == hash(tenant_id) % N (correct but doesn't exercise the bug fix).
        \\# TYPE bound_fetch_same_worker_routes_total counter
        \\bound_fetch_same_worker_routes_total {d}
        \\# HELP dispatch_lease_conflicts_total anchor selections that found the tenant's dispatch lease held by a sibling worker and served a different tenant this tick.
        \\# TYPE dispatch_lease_conflicts_total counter
        \\dispatch_lease_conflicts_total {d}
        \\# HELP dispatch_blocked_overflows_total ticks stopped early because more than 32 tenants were contending (requests deferred to the next tick, never dropped).
        \\# TYPE dispatch_blocked_overflows_total counter
        \\dispatch_blocked_overflows_total {d}
        \\
    , .{
        worker.node.router.bound_fetch_cross_worker_routes.load(.monotonic),
        worker.node.router.bound_fetch_same_worker_routes.load(.monotonic),
        worker.node.dispatch_lease_conflicts.load(.monotonic),
        worker.node.dispatch_blocked_overflows.load(.monotonic),
    });

    // blob coordinator / chunk spool (`docs/architecture/routing-and-ingress.md`): peak inline RAM held by this
    // worker's bound-fetch chunk spools. Bounded by K × chunk_size per
    // in-flight fetch — the large-body smoke asserts the watermark
    // stays under the window cap even for a multi-MB upstream body.
    // Worker-local (SO_REUSEPORT): single-worker deployments / smokes
    // read the exact value; multi-worker reads whichever worker served
    // the scrape.
    try w.print(
        \\# HELP bound_fetch_spool_inline_bytes_peak peak inline (un-evicted) bytes held across this worker's bound-fetch chunk spools.
        \\# TYPE bound_fetch_spool_inline_bytes_peak gauge
        \\bound_fetch_spool_inline_bytes_peak {d}
        \\# HELP bound_fetch_spool_readback_total spool-head chunks whose evicted bytes were read back from the coordinator at dispatch.
        \\# TYPE bound_fetch_spool_readback_total counter
        \\bound_fetch_spool_readback_total {d}
        \\# HELP bound_fetch_spool_dropped_total spooled-but-unconsumed chunks discarded on bound-fetch cancel / held-client disconnect.
        \\# TYPE bound_fetch_spool_dropped_total counter
        \\bound_fetch_spool_dropped_total {d}
        \\# HELP bound_fetch_spool_depth_peak peak queued spool entries (producer-ahead-of-consumer depth) across this worker's bound-fetch spools.
        \\# TYPE bound_fetch_spool_depth_peak gauge
        \\bound_fetch_spool_depth_peak {d}
        \\# HELP log_records_dropped_total per-request log records permanently lost in flushLogs (writeBatch failure) — lossy-on-failure by design.
        \\# TYPE log_records_dropped_total counter
        \\log_records_dropped_total {d}
        \\
    , .{
        worker.spools.bound_fetch_spool_inline_bytes_peak,
        worker.spools.bound_fetch_spool_readback_total,
        worker.spools.bound_fetch_spool_dropped_total,
        worker.spools.bound_fetch_spool_depth_peak,
        worker.log.log_records_dropped_total,
    });

    // chunk spool (`docs/architecture/routing-and-ingress.md`): live retained (sealed-but-not-
    // fully-consumed) coordinator batches. Refcount-release keeps this
    // at the live backlog.
    if (worker.node.blob_coord.coordinator) |coord| {
        try w.print(
            \\# HELP coord_retained_batches live retained (sealed, not fully consumed) blob-coordinator batches.
            \\# TYPE coord_retained_batches gauge
            \\coord_retained_batches {d}
            \\
        , .{coord.retainedBatchCount()});
    }

    // Move the writer's accumulated bytes back into the ArrayList and hand
    // ownership to the caller. `toArrayList` does NOT free the writer's buffer —
    // it hands it back to us.
    buf = aw.toArrayList();
    return try buf.toOwnedSlice(allocator);
}

/// Render a kvexp.MetricsSnapshot as Prometheus text. Counter totals
/// follow the `*_total` convention; the two duration histograms emit
/// `_bucket{le="..."}`, `_sum`, and `_count` lines in seconds.
fn writeKvexpMetrics(
    w: *std.Io.Writer,
    snap: kv_mod.KvexpMetricsSnapshot,
) !void {
    try w.print(
        \\# HELP kvexp_put_total puts applied to a tenant txn.
        \\# TYPE kvexp_put_total counter
        \\kvexp_put_total {d}
        \\# HELP kvexp_delete_total deletes applied to a tenant txn.
        \\# TYPE kvexp_delete_total counter
        \\kvexp_delete_total {d}
        \\# HELP kvexp_get_total point reads through Txn / StoreLease.
        \\# TYPE kvexp_get_total counter
        \\kvexp_get_total {d}
        \\# HELP kvexp_bytes_put_total key+value bytes appended via put.
        \\# TYPE kvexp_bytes_put_total counter
        \\kvexp_bytes_put_total {d}
        \\# HELP kvexp_create_store_total stores created (pending or durable).
        \\# TYPE kvexp_create_store_total counter
        \\kvexp_create_store_total {d}
        \\# HELP kvexp_drop_store_total stores dropped.
        \\# TYPE kvexp_drop_store_total counter
        \\kvexp_drop_store_total {d}
        \\# HELP kvexp_acquire_total blocking dispatch-lease acquires.
        \\# TYPE kvexp_acquire_total counter
        \\kvexp_acquire_total {d}
        \\# HELP kvexp_try_acquire_total non-blocking dispatch-lease attempts.
        \\# TYPE kvexp_try_acquire_total counter
        \\kvexp_try_acquire_total {d}
        \\# HELP kvexp_try_acquire_contended_total tryAcquire attempts that returned null (lock held).
        \\# TYPE kvexp_try_acquire_contended_total counter
        \\kvexp_try_acquire_contended_total {d}
        \\# HELP kvexp_txn_commit_total top-level Txn commits.
        \\# TYPE kvexp_txn_commit_total counter
        \\kvexp_txn_commit_total {d}
        \\# HELP kvexp_txn_rollback_total top-level Txn rollbacks.
        \\# TYPE kvexp_txn_rollback_total counter
        \\kvexp_txn_rollback_total {d}
        \\# HELP kvexp_savepoint_commit_total savepoint folds into parent.
        \\# TYPE kvexp_savepoint_commit_total counter
        \\kvexp_savepoint_commit_total {d}
        \\# HELP kvexp_savepoint_rollback_total savepoint drops.
        \\# TYPE kvexp_savepoint_rollback_total counter
        \\kvexp_savepoint_rollback_total {d}
        \\# HELP kvexp_txn_begin_total top-level Txns opened via beginTxn.
        \\# TYPE kvexp_txn_begin_total counter
        \\kvexp_txn_begin_total {d}
        \\# HELP kvexp_txn_commit_speculative_total commits whose reads resolved against an uncommitted chain predecessor.
        \\# TYPE kvexp_txn_commit_speculative_total counter
        \\kvexp_txn_commit_speculative_total {d}
        \\# HELP kvexp_chain_depth_sum speculative-chain depth summed across every beginTxn; divide by kvexp_txn_begin_total for the mean.
        \\# TYPE kvexp_chain_depth_sum counter
        \\kvexp_chain_depth_sum {d}
        \\# HELP kvexp_chain_depth_max deepest speculative chain ever observed at a beginTxn.
        \\# TYPE kvexp_chain_depth_max gauge
        \\kvexp_chain_depth_max {d}
        \\# HELP kvexp_durabilize_total durabilize() calls (fsync boundaries).
        \\# TYPE kvexp_durabilize_total counter
        \\kvexp_durabilize_total {d}
        \\# HELP kvexp_durabilize_failed_total durabilize() calls that returned an error (manifest is now poisoned).
        \\# TYPE kvexp_durabilize_failed_total counter
        \\kvexp_durabilize_failed_total {d}
        \\# HELP kvexp_snapshot_open_total openSnapshot() calls.
        \\# TYPE kvexp_snapshot_open_total counter
        \\kvexp_snapshot_open_total {d}
        \\# HELP kvexp_poison_total times the manifest entered the poisoned state.
        \\# TYPE kvexp_poison_total counter
        \\kvexp_poison_total {d}
        \\# HELP kvexp_active_leases dispatch leases currently outstanding.
        \\# TYPE kvexp_active_leases gauge
        \\kvexp_active_leases {d}
        \\# HELP kvexp_active_snapshots read snapshots currently open.
        \\# TYPE kvexp_active_snapshots gauge
        \\kvexp_active_snapshots {d}
        \\
    , .{
        snap.put_total,
        snap.delete_total,
        snap.get_total,
        snap.bytes_put_total,
        snap.create_store_total,
        snap.drop_store_total,
        snap.acquire_total,
        snap.try_acquire_total,
        snap.try_acquire_contended_total,
        snap.txn_commit_total,
        snap.txn_rollback_total,
        snap.savepoint_commit_total,
        snap.savepoint_rollback_total,
        snap.txn_begin_total,
        snap.txn_commit_speculative_total,
        snap.chain_depth_sum,
        snap.chain_depth_max,
        snap.durabilize_total,
        snap.durabilize_failed_total,
        snap.snapshot_open_total,
        snap.poison_total,
        snap.active_leases,
        snap.active_snapshots,
    });

    try writeKvexpHistogram(w, "kvexp_durabilize_duration_seconds", snap.durabilize_duration);
    try writeKvexpHistogram(w, "kvexp_snapshot_open_duration_seconds", snap.snapshot_open_duration);
}

fn writeKvexpHistogram(
    w: *std.Io.Writer,
    comptime name: []const u8,
    h: kv_mod.KvexpHistogramSnapshot,
) !void {
    try w.print("# TYPE " ++ name ++ " histogram\n", .{});
    const bounds = kv_mod.KvexpHistogram.bucket_bounds_nanos;
    inline for (bounds, 0..) |ns, i| {
        const seconds: f64 = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
        try w.print(name ++ "_bucket{{le=\"{d}\"}} {d}\n", .{ seconds, h.buckets[i] });
    }
    try w.print(name ++ "_bucket{{le=\"+Inf\"}} {d}\n", .{h.count});
    const sum_seconds: f64 = @as(f64, @floatFromInt(h.sum_nanos)) / 1_000_000_000.0;
    try w.print(name ++ "_sum {d}\n", .{sum_seconds});
    try w.print(name ++ "_count {d}\n", .{h.count});
}

fn writeCountHistogram(
    w: *std.Io.Writer,
    comptime name: []const u8,
    h: kv_mod.CountHistogram.Snapshot,
) !void {
    try w.print("# TYPE " ++ name ++ " histogram\n", .{});
    const bounds = kv_mod.CountHistogram.bucket_bounds;
    inline for (bounds, 0..) |b, i| {
        try w.print(name ++ "_bucket{{le=\"{d}\"}} {d}\n", .{ b, h.buckets[i] });
    }
    try w.print(name ++ "_bucket{{le=\"+Inf\"}} {d}\n", .{h.count});
    try w.print(name ++ "_sum {d}\n", .{h.sum});
    try w.print(name ++ "_count {d}\n", .{h.count});
}

fn writeMicrosHistogram(
    w: *std.Io.Writer,
    comptime name: []const u8,
    h: kv_mod.MicrosHistogram.Snapshot,
) !void {
    try w.print("# TYPE " ++ name ++ " histogram\n", .{});
    const bounds = kv_mod.MicrosHistogram.bucket_bounds_us;
    inline for (bounds, 0..) |us, i| {
        try w.print(name ++ "_bucket{{le=\"{d}\"}} {d}\n", .{ us, h.buckets[i] });
    }
    try w.print(name ++ "_bucket{{le=\"+Inf\"}} {d}\n", .{h.count});
    try w.print(name ++ "_sum {d}\n", .{h.sum_us});
    try w.print(name ++ "_count {d}\n", .{h.count});
}

/// Bundle magic + version. Wire layout produced by handleRaftSnapshot:
///
///   [8B magic "ROVSNAP1"]
///   [u32 file_count (big-endian)]
///   per file:
///     [u16 name_len (big-endian)]
///     [name_len bytes — relative path under data_dir, forward slashes]
///     [u64 file_size (big-endian)]
///     [file_size bytes — raw VACUUM-INTO'd SQLite file]
///
/// The receiver parses files in order and writes each into
/// `tmp_dir/{snap_id}/<name>` before atomic-renaming into data_dir.
const SNAP_BUNDLE_MAGIC = "ROVSNAP1";

/// Stream the leader's `cluster.kv` (the consolidated kvexp
/// manifest holding every store this node serves) as a single HTTP
/// response body so a far-behind follower can install it as its
/// new starting state — the far-behind follower catchup model, under
/// the kvexp consolidation.
///
/// Consistency model: `KvStore.dumpManifestToFile` durabilizes the
/// source manifest, opens a kvexp Snapshot, dumps it through a
/// freshly-initialized manifest at a tmp path. The result is a
/// self-contained, defragmented kvexp file the follower can adopt
/// wholesale. NOT shipped: `raft.log.db`, term/vote — those are
/// raft-layer concerns the follower manages on its own.
///
/// Bundle wire format (a single-entry framing):
///   `ROVSNAP1 [u32 file_count=1] [u16 name_len][name="cluster.kv"]
///    [u64 file_size][bytes]`
///
/// Memory cost: the dumped bytes are buffered in memory before h2
/// hands off. A streaming variant is a follow-up.
fn handleRaftSnapshot(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    sys_rest: []const u8,
    cors_origin: ?[]const u8,
) !void {
    if (!std.mem.eql(u8, method, "GET")) {
        try respb.setSystemResponse(server, ent, sid, sess, 405, "GET only\n", allocator, cors_origin, null);
        return;
    }

    // Extract `snap_id` from path (hex-encoded after "raft-snapshot/").
    // Informational only — the handler always streams the current
    // cluster.kv. The follower threads the current
    // `raft_get_snapshot_last_idx` it sees into `raft_load_snapshot`.
    const prefix = "raft-snapshot/";
    const id_str = sys_rest[prefix.len..];
    const snap_id = std.fmt.parseInt(u64, id_str, 16) catch 0;

    const data_dir = worker.node.tenant.dir;

    // Dump cluster.kv to a tmp path. dumpManifestToFile durabilizes
    // the source, opens a snapshot, and writes a fresh defragmented
    // file at the target.
    var tmp_buf: [256]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&tmp_buf, ".snap-out-{x}.kv", .{snap_id}) catch return;
    const tmp_path = try std.fs.path.join(allocator, &.{ data_dir, tmp_name });
    defer allocator.free(tmp_path);
    std.fs.cwd().deleteFile(tmp_path) catch {};
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const tmp_pathz = try allocator.dupeZ(u8, tmp_path);
    defer allocator.free(tmp_pathz);
    try worker.node.tenant.root.dumpManifestToFile(tmp_pathz);

    const bytes = std.fs.cwd().readFileAlloc(allocator, tmp_path, 1 << 32) catch return;
    defer allocator.free(bytes);

    // Frame as a single-entry bundle so the existing receiver-side
    // parser ("magic + count + [name, size, bytes]+") works
    // unchanged.
    var bundle: std.ArrayList(u8) = .empty;
    errdefer bundle.deinit(allocator);

    try bundle.appendSlice(allocator, SNAP_BUNDLE_MAGIC);
    var count_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_buf, 1, .big);
    try bundle.appendSlice(allocator, &count_buf);

    const name = "cluster.kv";
    var nl_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &nl_buf, @intCast(name.len), .big);
    try bundle.appendSlice(allocator, &nl_buf);
    try bundle.appendSlice(allocator, name);

    var sz_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &sz_buf, @intCast(bytes.len), .big);
    try bundle.appendSlice(allocator, &sz_buf);
    try bundle.appendSlice(allocator, bytes);

    std.log.info(
        "raft-snapshot: served snap_id={x} cluster.kv bytes={d}",
        .{ snap_id, bytes.len },
    );

    const body = try bundle.toOwnedSlice(allocator);
    try respb.setSystemResponseOwned(server, ent, sid, sess, 200, body, allocator, cors_origin, "application/octet-stream");
}


/// Stamp `_deploy/current = {dep_id:0>16}` on the tenant's app.db,
/// propose envelope 0, park the request on raft_pending, and
/// return 204 once raft commits (or 503 on fault/timeout). Enqueues
/// the deployment loader inline so the leader's worker starts
/// fetching bytecodes immediately; the apply path on followers
/// enqueues on its own when the writeset commits.
///
/// Platform-bootstrap only — customer release traffic goes through
/// __admin__'s deployed `publishRelease` RPC. Kept on the system
/// route because the admin handler itself can't bootstrap its own
/// `_deploy/current` (chicken-and-egg at first boot).
fn handleRelease(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    body: []const u8,
    cors_origin: ?[]const u8,
) !void {
    if (!std.mem.eql(u8, method, "POST")) {
        try respb.setSystemResponse(server, ent, sid, sess, 405, "POST only\n", allocator, cors_origin, null);
        return;
    }
    var parsed = std.json.parseFromSlice(struct {
        tenant_id: []const u8,
        dep_id: u64,
    }, allocator, body, .{ .ignore_unknown_fields = true }) catch {
        try respb.setSystemResponse(server, ent, sid, sess, 400, "expected {\"tenant_id\":\"...\",\"dep_id\":N}\n", allocator, cors_origin, null);
        return;
    };
    defer parsed.deinit();

    if (parsed.value.tenant_id.len == 0 or parsed.value.dep_id == 0) {
        try respb.setSystemResponse(server, ent, sid, sess, 400, "tenant_id required and dep_id must be > 0\n", allocator, cors_origin, null);
        return;
    }

    // Reject unknown tenants — keeps stale dashboard sessions from
    // populating the table with garbage that never matches.
    const inst_opt = worker.node.tenant.getInstance(parsed.value.tenant_id) catch null;
    const inst = inst_opt orelse {
        try respb.setSystemResponse(server, ent, sid, sess, 404, "unknown tenant\n", allocator, cors_origin, null);
        return;
    };

    // Persist the release pointer to the tenant's app.db. Stamps
    // `_deploy/current = {dep_id:016x}` and proposes through raft
    // envelope 0; followers' apply path picks it up and the worker's
    // openTenantFiles reads it on first request after a restart.
    var hex_buf: [16]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x:0>16}", .{parsed.value.dep_id}) catch unreachable;

    // Idempotent fast path: matches `releasePublishTrampoline`. If
    // the target's `_deploy/current` is already exactly `dep_id`,
    // skip the raft propose. The platform-bootstrap flow (publishing
    // __admin__ / __replay__) retries against each node in turn, so a
    // retry can land here after the first commit; without this
    // short-circuit every retry re-proposes a no-op envelope.
    //
    // With content-addressed dep_ids, "same id" genuinely means
    // "same content", so the snapshot already in place IS the right
    // one. Still enqueue the loader as belt-and-braces — if the
    // tenant's slot was lazy-opened but its snapshot never landed
    // (e.g. a deployment loader crash), this nudges another attempt.
    // The loader is per-tenant dedup'd, so an extra enqueue is cheap.
    if (inst.kv.get("_deploy/current")) |current_hex| {
        defer allocator.free(current_hex);
        const current_id = std.fmt.parseInt(u64, current_hex, 16) catch 0;
        if (current_id == parsed.value.dep_id) {
            if (worker.node.deploy.deployment_loader) |loader| {
                loader.enqueue(parsed.value.tenant_id, parsed.value.dep_id) catch |err| std.log.warn(
                    "release fast-path: loader.enqueue {s}/{d} failed: {s}",
                    .{ parsed.value.tenant_id, parsed.value.dep_id, @errorName(err) },
                );
            }
            try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, cors_origin, null);
            return;
        }
    } else |_| {}

    var txn = inst.kv.beginTrackedImmediate() catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "release txn open failed: {s}\n", .{@errorName(err)});
        try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
        return;
    };
    txn.put("_deploy/current", hex) catch |err| {
        txn.rollback() catch {};
        const msg = try std.fmt.allocPrint(allocator, "release put failed: {s}\n", .{@errorName(err)});
        try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
        return;
    };
    // Release history: per-tenant `_release/{ts_ms:020}` → `{id:016x}`.
    // Lex-ordered by timestamp (millis, zero-padded) so a reverse-
    // scan returns newest-first — what the dashboard's Deploys tab
    // needs. Same value gets written for re-releases of the same id;
    // that's fine, the customer DID hit "deploy" again. Different
    // releases get different timestamps even if content collides.
    var ts_buf: [20]u8 = undefined;
    // MUST be unsigned: `{d:0>20}` on a signed positive integer reserves a
    // sign column and emits a leading `+` ("000000+<ms>"), which is not a
    // digit — the dashboard reader's `parseInt(key.slice(9), 10)` then stops
    // at the `+` and reads ts_ms as 0. u64 formats as pure digits.
    const ts_ms: u64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
    const ts_str = std.fmt.bufPrint(&ts_buf, "{d:0>20}", .{ts_ms}) catch unreachable;
    var release_key_buf: [32]u8 = undefined;
    const release_key = std.fmt.bufPrint(&release_key_buf, "_release/{s}", .{ts_str}) catch unreachable;
    txn.put(release_key, hex) catch |err| {
        txn.rollback() catch {};
        const msg = try std.fmt.allocPrint(allocator, "release history put failed: {s}\n", .{@errorName(err)});
        try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
        return;
    };

    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    ws.addPut("_deploy/current", hex) catch |err| {
        txn.rollback() catch {};
        const msg = try std.fmt.allocPrint(allocator, "release writeset failed: {s}\n", .{@errorName(err)});
        try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
        return;
    };
    ws.addPut(release_key, hex) catch |err| {
        txn.rollback() catch {};
        const msg = try std.fmt.allocPrint(allocator, "release-history writeset failed: {s}\n", .{@errorName(err)});
        try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
        return;
    };

    // No manifest fetch + no config-mirror on this hot path.
    // The request thread never blocks on the network — release
    // just records the new pointer + proposes. The deployment
    // loader (running on a background thread) is responsible
    // for fetching the manifest, mirroring `_config/*.json`
    // entries into kv, and swapping the tenant's loaded
    // bytecodes / statics. See `worker.zig::DeploymentLoader`.
    //
    // Trade-off: `_deploy/current` and the `_config/*` mirror
    // are not atomic in raft. There is a small window
    // after release commit where `kv.fromConfig(...)` returns
    // the previous deployment's value. The window closes when
    // the loader finishes — typically ~tens-of-ms for an empty
    // manifest, ~hundreds-of-ms for one with bytecodes.
    //
    // Customer code that reads `_config/*` immediately after a
    // release must either accept eventual consistency or wait
    // on the loader's completion signal (SSE — future work).

    txn.commit() catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "release commit failed: {s}\n", .{@errorName(err)});
        try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
        return;
    };

    // Propose envelope-0 and capture the assigned seq so we can
    // park this request on raft commit. The proposeBatcher coalesces
    // any other proposals queued at the next raft tick — multiple
    // parallel release POSTs become a single consensus round.
    // handleRelease is an internal admin endpoint with no
    // dispatched-handler readset to attach.
    const seq = (raft_propose.proposeWriteSet(worker, &ws, parsed.value.tenant_id, "") catch |err| {
        // Propose failed before raft accepted it (queue full,
        // shutting down, not leader). The local write was a kvexp
        // *speculative* commit (volatile — LMDB only at raft-apply);
        // a propose that never reached raft leaves nothing durable,
        // so there is no local undo to perform (kvexp has no
        // kv_undo table). NotLeader → 421 (the retry-safe re-aim
        // status, decisions.md §10.5c) so callers hunt the leader;
        // anything else → 503 without parking; the proposer
        // invariant (kvexp volatility; `docs/architecture/consensus-robustness.md`).
        const status: u16 = if (err == error.NotLeader) 421 else 503;
        const msg = try std.fmt.allocPrint(
            allocator,
            "release propose failed: {s}\n",
            .{@errorName(err)},
        );
        try respb.setSystemResponseOwned(server, ent, sid, sess, status, msg, allocator, cors_origin, null);
        return;
    }).seq;

    // Enqueue the deployment loader directly — the leader's apply
    // path is leader-skip for envelope-0, so the apply thread won't
    // do this for us on this node. On follower nodes, apply.zig's
    // _deploy/current detector enqueues automatically when the
    // writeset commits.
    if (worker.node.deploy.deployment_loader) |loader| {
        loader.enqueue(parsed.value.tenant_id, parsed.value.dep_id) catch |err| {
            std.log.warn(
                "release: deployment loader enqueue {s}/{d} failed: {s}",
                .{ parsed.value.tenant_id, parsed.value.dep_id, @errorName(err) },
            );
        };
    }

    // Park the request on the response-sibling of raft-pending —
    // release POST is always terminal (no cont / stream).
    // drainRaftPending will:
    //   - on commit: commit the parked txn + deliver 204
    //   - on fault / timeout: roll back + deliver 503
    // The worker thread is free to dispatch the next stream
    // immediately; this is what lets proposeBatcher actually
    // batch multiple in-flight release POSTs.
    // A move-only Cmd.respond on
    // a parked_unit routes the commit-arm move through `interpretCmd
    // .respond` (matching every other entity park path). BUILD IT FIRST:
    // if its (1-slot) alloc fails after the entity is committed to
    // raft_pending_response, the commit-arm can't ship the 204 and the
    // client waits out the full RaftWait deadline for a misleading 503,
    // silently. Fail loud now while the entity is still in request_out.
    var release_cmds: effect_mod.cmd.BufferedCmds = .{};
    release_cmds.items.append(allocator, .{ .respond = .{
        .entity = ent,
        .source = .raft_pending_response,
        .dest = .response_in,
    } }) catch |err| {
        std.log.warn(
            "release: respond Cmd alloc failed (tenant={s} seq={d}): {s} — failing loud (500)",
            .{ parsed.value.tenant_id, seq, @errorName(err) },
        );
        try respb.setSimpleResponse(server, ent, sid, sess, 500, "release response dispatch alloc failed\n", allocator);
        return;
    };

    try respb.stageSystemResponse(server, ent, sid, sess, 204, "", allocator, cors_origin, null);
    const deadline_ns: i64 = @intCast(std.time.nanoTimestamp() + @as(i128, @intCast(worker.commit_wait_timeout_ns)));
    const group_id = worker.raft.gidForTenant(parsed.value.tenant_id) orelse 0;
    try server.reg.set(ent, &server.request_out, RaftWait, .{
        .group_id = group_id,
        .seq = seq,
        .deadline_ns = deadline_ns,
    });
    try server.reg.move(ent, &server.request_out, &worker.raft_pending_response);
    // Pass empty writeset — handleRelease's actual kv writes
    // (`_deploy/current`) ride on the entity's own txn in pending_txns;
    // the parked_unit here is move-routing-only.
    const empty_ws = kv_mod.WriteSet.init(allocator);
    var ws_local = empty_ws;
    defer ws_local.deinit();
    worker_mod.parkKvWakes(worker, seq, parsed.value.tenant_id, &ws_local, release_cmds) catch |perr|
        std.log.warn("release: parkKvWakes (tenant={s}) failed: {s}", .{ parsed.value.tenant_id, @errorName(perr) });
}

/// `POST /_system/reset` — bootstrap + break-glass (`docs/architecture/cli-and-deploy.md`
/// §4). Root-token gated, NO body. (Re)deploys the BAKED `__admin__` deploy app
/// + stamps `_deploy/current` via `worker.deployBakedAdmin`. Synchronous (rare,
/// operator-triggered) — runs inline on the poll loop. Returns
/// `{"ok":true,"dep_id":"<016x>"}`; 503 if this node doesn't lead `__admin__`'s
/// group (retry against the leader).
fn handleReset(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    cors_origin: ?[]const u8,
) !void {
    if (!std.mem.eql(u8, method, "POST")) {
        try respb.setSystemResponse(server, ent, sid, sess, 405, "POST only\n", allocator, cors_origin, null);
        return;
    }
    const dep_id = worker.deployBakedAdmin() catch |err| {
        const status: u16 = switch (err) {
            error.NotLeader, error.AdminNotInitialized => 503,
            else => 500,
        };
        const msg = switch (err) {
            error.NotLeader => "not leader of __admin__ group; retry against the leader\n",
            error.AdminNotInitialized => "__admin__ tenant not initialized\n",
            else => "reset failed\n",
        };
        try respb.setSystemResponse(server, ent, sid, sess, status, msg, allocator, cors_origin, null);
        return;
    };
    const body = try std.fmt.allocPrint(allocator, "{{\"ok\":true,\"dep_id\":\"{x:0>16}\"}}\n", .{dep_id});
    try respb.setSystemResponseOwned(server, ent, sid, sess, 200, body, allocator, cors_origin, "application/json");
}


/// Body shape: `{"pairs":[{"key":"<k>","value":"<v>"}, ...]}`. Writes
/// each pair into `__admin__/app.db` via a raft-replicated envelope
/// 0 writeset, so every node sees the same admin config. The operator
/// runs this at platform-bootstrap time to ship config (resend_key,
/// platform_email_from, ...) without a per-node flag.
///
/// Idempotent: re-posting the same pairs re-stamps the kv rows, so
/// re-running the seeding script with unchanged values is a no-op.
fn handleAdminKv(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    body: []const u8,
    cors_origin: ?[]const u8,
) !void {
    if (!std.mem.eql(u8, method, "POST")) {
        try respb.setSystemResponse(server, ent, sid, sess, 405, "POST only\n", allocator, cors_origin, null);
        return;
    }

    const Pair = struct { key: []const u8, value: []const u8 };
    var parsed = std.json.parseFromSlice(struct {
        pairs: []const Pair,
    }, allocator, body, .{ .ignore_unknown_fields = true }) catch {
        try respb.setSystemResponse(server, ent, sid, sess, 400, "expected {\"pairs\":[{\"key\":\"...\",\"value\":\"...\"},...]}\n", allocator, cors_origin, null);
        return;
    };
    defer parsed.deinit();

    if (parsed.value.pairs.len == 0) {
        try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, cors_origin, null);
        return;
    }

    const admin_inst_opt = worker.node.tenant.getInstance(tenant_mod.ADMIN_INSTANCE_ID) catch null;
    const admin_inst = admin_inst_opt orelse {
        try respb.setSystemResponse(server, ent, sid, sess, 503, "__admin__ tenant not initialized\n", allocator, cors_origin, null);
        return;
    };

    var txn = admin_inst.kv.beginTrackedImmediate() catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "admin-kv txn open failed: {s}\n", .{@errorName(err)});
        try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
        return;
    };
    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    for (parsed.value.pairs) |p| {
        if (p.key.len == 0) {
            txn.rollback() catch {};
            try respb.setSystemResponse(server, ent, sid, sess, 400, "empty key\n", allocator, cors_origin, null);
            return;
        }
        if (std.mem.indexOfScalar(u8, p.key, 0) != null or
            std.mem.indexOfScalar(u8, p.value, 0) != null)
        {
            txn.rollback() catch {};
            try respb.setSystemResponse(server, ent, sid, sess, 400, "key/value contains NUL\n", allocator, cors_origin, null);
            return;
        }
        txn.put(p.key, p.value) catch |err| {
            txn.rollback() catch {};
            const msg = try std.fmt.allocPrint(allocator, "admin-kv put failed: {s}\n", .{@errorName(err)});
            try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
            return;
        };
        ws.addPut(p.key, p.value) catch |err| {
            txn.rollback() catch {};
            const msg = try std.fmt.allocPrint(allocator, "admin-kv writeset failed: {s}\n", .{@errorName(err)});
            try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
            return;
        };
    }
    txn.commit() catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "admin-kv commit failed: {s}\n", .{@errorName(err)});
        try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
        return;
    };

    // Propose envelope-0 and PARK the request on raft commit — the
    // 204 must not be released at accept (the caller proceeds
    // assuming the bootstrap kv is durable; a pre-quorum fault would
    // leave it acting on a write the cluster rolled back). Mirrors the Class-B-correct release handler above:
    // drainRaftPending delivers the staged 204 at committedSeq>=seq
    // / 503 on fault/timeout. The idiom-2 park-on-commit rule
    // (`docs/architecture/consensus-robustness.md`; effect gating in
    // `docs/architecture/effects-and-handlers.md`).
    // System endpoint with no dispatched-handler readset; empty
    // rs_bytes is the right value here.
    const seq = (raft_propose.proposeWriteSet(worker, &ws, tenant_mod.ADMIN_INSTANCE_ID, "") catch |err| {
        // Synchronous propose failure (queue full / shutting down /
        // not leader). The local write was a kvexp *speculative*
        // commit (volatile — LMDB only at raft-apply); a propose
        // that never reached raft leaves nothing durable to undo
        // (kvexp has no kv_undo table). NotLeader → 421 (re-aim,
        // decisions.md §10.5c); anything else → 503 without parking;
        // the proposer invariant (kvexp volatility;
        // `docs/architecture/consensus-robustness.md`).
        const status: u16 = if (err == error.NotLeader) 421 else 503;
        const msg = try std.fmt.allocPrint(
            allocator,
            "admin-kv propose failed: {s}\n",
            .{@errorName(err)},
        );
        try respb.setSystemResponseOwned(server, ent, sid, sess, status, msg, allocator, cors_origin, null);
        return;
    }).seq;

    try respb.stageSystemResponse(server, ent, sid, sess, 204, "", allocator, cors_origin, null);
    const deadline_ns: i64 = @intCast(std.time.nanoTimestamp() + @as(i128, @intCast(worker.commit_wait_timeout_ns)));
    const group_id = worker.raft.gidForTenant(tenant_mod.ADMIN_INSTANCE_ID) orelse 0;
    try server.reg.set(ent, &server.request_out, RaftWait, .{
        .group_id = group_id,
        .seq = seq,
        .deadline_ns = deadline_ns,
    });
    // Admin kv-write is always terminal — response sibling.
    try server.reg.move(ent, &server.request_out, &worker.raft_pending_response);
    // Emit Cmd.respond on a
    // parked_unit so the commit-arm move routes through `interpretCmd
    // .respond` (matching every other entity park path). Pass empty
    // writeset — admin-kv's actual writes ride on the entity's own
    // txn in pending_txns; the parked_unit here is move-routing-only.
    var admin_cmds: effect_mod.cmd.BufferedCmds = .{};
    admin_cmds.items.append(allocator, .{ .respond = .{
        .entity = ent,
        .source = .raft_pending_response,
        .dest = .response_in,
    } }) catch {};
    const empty_ws = kv_mod.WriteSet.init(allocator);
    var ws_local = empty_ws;
    defer ws_local.deinit();
    worker_mod.parkKvWakes(worker, seq, tenant_mod.ADMIN_INSTANCE_ID, &ws_local, admin_cmds) catch |perr|
        std.log.warn("admin-kv: parkKvWakes failed: {s}", .{@errorName(perr)});
}

test "release-history key is pure digits (no sign) — regression for the i64 `+` bug" {
    // Mirrors the key construction in `handleRelease` (and the
    // `platform.releases.publish` trampoline in worker.zig). `ts_ms` MUST be
    // unsigned: `{d:0>20}` on a signed positive integer reserves a sign column
    // and emits a leading `+` ("_release/000000+<ms>"). That `+` is not a
    // digit, so the dashboard reader's `parseInt(key.slice("_release/".len),
    // 10)` stops at it and reports ts_ms = 0 for every release. Keep the type
    // u64 so the key stays lex-sortable and round-trips through parseInt.
    const ts_ms: u64 = 1783041027051;
    var ts_buf: [20]u8 = undefined;
    const ts_str = try std.fmt.bufPrint(&ts_buf, "{d:0>20}", .{ts_ms});
    var key_buf: [32]u8 = undefined;
    const release_key = try std.fmt.bufPrint(&key_buf, "_release/{s}", .{ts_str});

    // 13-digit ms → 7 leading zeros to fill the 20-wide field. No `+`.
    try std.testing.expectEqualStrings("_release/00000001783041027051", release_key);
    try std.testing.expect(std.mem.indexOfScalar(u8, release_key, '+') == null);
    // Every char after the `_release/` prefix is an ASCII digit, 20 wide …
    const suffix = release_key["_release/".len..];
    try std.testing.expectEqual(@as(usize, 20), suffix.len);
    for (suffix) |ch| try std.testing.expect(ch >= '0' and ch <= '9');
    // … and the suffix round-trips back to the original ms (what the reader does).
    try std.testing.expectEqual(ts_ms, try std.fmt.parseInt(u64, suffix, 10));
}
