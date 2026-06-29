//! `rewind-ops` — the platform/operator CLI (docs/plans/rewind-cli-plan.md §2–§3,
//! §6). The privileged half of the split: every verb here carries an operator
//! secret (root token → workers + deploy app; REWIND_MOVE_SECRET → CP control,
//! which now also propagates the worker domain alias). Never shipped to
//! customers — the OIDC-scoped tenant verbs live in the separate `rewind`
//! binary (built when the __auth__ IdP lands; both reuse `common.zig`).
//!
//! Verbs (audited against the live server primitives, not just the old script):
//!   bootstrap                       provision __admin__ via the CP + reset —
//!                                   first-time bring-up of a virgin cluster.
//!   reset                           POST {worker}/_system/reset — (re)deploy the
//!                                   baked __admin__ deploy app (break-glass).
//!   deploy <tenant> <bundle> [--release]   classify + POST to the standing app.
//!   release <tenant> <dep_id_hex>   flip _deploy/current (leader-aware retry).
//!   provision <tenant> [--cluster C] [--host H]   create+place a tenant (CP).
//!   move <tenant> <cluster> --yes                 relocate a tenant (zero-downtime) (CP).
//!   host add <host> <tenant>        map a domain → tenant (CP index; CP pushes the worker alias).
//!   plan set <tenant> <plan>        set a tenant's plan/limits blob (CP).
//!   status <host>                   resolve a host → tenant/cluster/nodes + plan.
//!
//! Config: operator env file (default ~/.config/rove/prod.env, then ./.env.prod,
//! --env override; OS env overlays). Vars: REWIND_ROOT_TOKEN, REWIND_ADMIN_DOMAIN,
//! ROVE_WORKER_URLS, ROVE_CLUSTER, ROVE_PUBLISH_SSH?, ROVE_CP_URL_INTERNAL,
//! REWIND_MOVE_SECRET.

const std = @import("std");
const c = @import("common.zig");

const Header = c.Header;
const fatal = c.fatal;
const oom = c.oom;

// ── headers ───────────────────────────────────────────────────────────────

/// Root bearer + admin Host + JSON — for worker /_system/* and the deploy app.
fn authHeaders(a: std.mem.Allocator, env: *const c.Env) []const Header {
    const rt = env.require("REWIND_ROOT_TOKEN");
    const admin = env.require("REWIND_ADMIN_DOMAIN");
    const hs = a.alloc(Header, 3) catch oom();
    hs[0] = .{ .name = "Host", .value = admin };
    hs[1] = .{ .name = "Authorization", .value = std.fmt.allocPrint(a, "Bearer {s}", .{rt}) catch oom() };
    hs[2] = .{ .name = "Content-Type", .value = "application/json" };
    return hs;
}

// ── content verbs (workers, root) ───────────────────────────────────────────

/// POST /_system/reset on each worker until one accepts (leader-gated). Returns dep_id.
fn cmdReset(a: std.mem.Allocator, env: *const c.Env) []const u8 {
    const headers = authHeaders(a, env);
    for (c.workerUrls(env, a)) |w| {
        const r = c.workerPost(a, env, w, "/_system/reset", headers, null, 60);
        if (r.code == 200) {
            const dep = c.extractDepId(a, r.body) orelse fatal("reset: 200 but no dep_id: {s}", .{r.body});
            std.debug.print("reset: deploy app live on __admin__ — dep_id={s}\n", .{dep});
            return dep;
        }
        std.debug.print("  reset via {s}: {d} {s} (trying next)\n", .{ w, r.code, c.trunc(r.body) });
    }
    fatal("/_system/reset failed on every worker", .{});
}

fn cmdDeploy(a: std.mem.Allocator, env: *const c.Env, tenant: []const u8, bundle_path: []const u8, release: bool) void {
    const b = c.classify(a, bundle_path);
    if (b.skipped.len != 0) {
        std.debug.print("  ! skipping (build source / non-deployable): ", .{});
        for (b.skipped, 0..) |s, i| std.debug.print("{s}{s}", .{ if (i != 0) ", " else "", s });
        std.debug.print("\n", .{});
    }
    if (b.handlers.len == 0 and b.statics.len == 0) fatal("bundle {s} has nothing to publish", .{bundle_path});
    std.debug.print("bundle: {d} handler(s), {d} static(s)\n", .{ b.handlers.len, b.statics.len });

    const headers = authHeaders(a, env);
    // Per-file WORKSPACE deploy: reset the workspace → upload each file →
    // cut a release. Each request is small; the old single mega-POST
    // base64-buffered the whole bundle in the deploy app's JS heap and OOM'd
    // on any real static-bearing bundle.
    _ = deployPost(a, env, "/v1/deploy/reset", headers, c.tenantBody(a, tenant), "reset");
    for (b.handlers) |h| {
        _ = deployPost(a, env, "/v1/deploy/file", headers, c.fileBodyHandler(a, tenant, h), h.path);
    }
    // Statics STREAM straight to S3 (raw bytes → PUT /v1/upload) — no buffering.
    for (b.statics) |s| {
        _ = uploadStatic(a, env, c.uploadPath(a, tenant, s), headers, s.bytes, s.path);
    }
    const cut = deployPost(a, env, "/v1/deploy/cut", headers, c.tenantBody(a, tenant), "cut");
    const dep_id = c.extractDepId(a, cut.body) orelse fatal("cut: 200 but no dep_id: {s}", .{cut.body});
    std.debug.print("deployment staged: {s} ({d} file(s)) — NOT released\n", .{ dep_id, b.handlers.len + b.statics.len });
    if (release) cmdRelease(a, env, tenant, dep_id);
}

/// POST a deploy sub-request to the standing app, leader-retrying across the
/// workers (a non-leader 421/503s). Returns the 200 Resp or fatals after
/// retries. `label` names the step in errors (path / "reset" / "cut").
fn deployPost(a: std.mem.Allocator, env: *const c.Env, sub: []const u8, headers: []const c.Header, body: []const u8, label: []const u8) c.Resp {
    const workers = c.workerUrls(env, a);
    var attempt: usize = 0;
    while (attempt < 6) : (attempt += 1) {
        for (workers) |w| {
            const r = c.workerPost(a, env, w, sub, headers, body, 120);
            if (r.code == 200) return r;
            std.debug.print("  {s} via {s}: {d} {s} (trying next)\n", .{ label, w, r.code, c.trunc(r.body) });
        }
        std.Thread.sleep(2 * std.time.ns_per_s);
    }
    fatal("deploy step '{s}' failed on every worker", .{label});
}

/// PUT a static's raw bytes to /v1/upload (streamed to S3), leader-retrying.
fn uploadStatic(a: std.mem.Allocator, env: *const c.Env, upath: []const u8, headers: []const c.Header, body: []const u8, label: []const u8) c.Resp {
    const workers = c.workerUrls(env, a);
    var attempt: usize = 0;
    while (attempt < 6) : (attempt += 1) {
        for (workers) |w| {
            const url = std.fmt.allocPrint(a, "{s}{s}", .{ w, upath }) catch oom();
            const r = c.call(a, env, "PUT", url, headers, body, 180);
            if (r.code == 200) return r;
            std.debug.print("  upload {s} via {s}: {d} {s} (trying next)\n", .{ label, w, r.code, c.trunc(r.body) });
        }
        std.Thread.sleep(2 * std.time.ns_per_s);
    }
    fatal("upload '{s}' failed on every worker", .{label});
}

/// Flip _deploy/current via /_system/release. Leader-gated → 6× round-robin retry.
fn cmdRelease(a: std.mem.Allocator, env: *const c.Env, tenant: []const u8, dep_id: []const u8) void {
    const headers = authHeaders(a, env);
    const dep_num = std.fmt.parseInt(u64, dep_id, 16) catch fatal("bad dep_id {s} (want hex)", .{dep_id});
    const body = std.fmt.allocPrint(a, "{{\"tenant_id\":\"{s}\",\"dep_id\":{d}}}", .{ tenant, dep_num }) catch oom();
    const workers = c.workerUrls(env, a);
    var attempt: usize = 0;
    while (attempt < 6) : (attempt += 1) {
        for (workers) |w| {
            const r = c.workerPost(a, env, w, "/_system/release", headers, body, 30);
            if (r.code == 204) {
                std.debug.print("released {s} @ {s}\n", .{ tenant, dep_id });
                return;
            }
            std.debug.print("  release via {s}: {d} (retrying)\n", .{ w, r.code });
        }
        std.Thread.sleep(2 * std.time.ns_per_s);
    }
    fatal("release flip failed on every worker after retries", .{});
}

/// PUT a system KV key via the worker's move-secret-gated `/_system/v2-kv`
/// (leader-gated → 6× round-robin retry). The bootstrap seam for operator
/// allowlist + OIDC RP config: those keys grant access, so there's no
/// operator-gated endpoint to write them through (chicken-and-egg) — the
/// move-secret is the out-of-band authority, same surface a tenant move uses.
fn cmdKvPut(a: std.mem.Allocator, env: *const c.Env, tenant: []const u8, key: []const u8, value: []const u8) void {
    const ms = env.require("REWIND_MOVE_SECRET");
    const headers = [_]Header{
        .{ .name = "X-Rewind-Move-Secret", .value = ms },
        .{ .name = "Content-Type", .value = "application/json" },
    };
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"tenant\":") catch oom();
    c.writeJsonString(&body, a, tenant);
    body.appendSlice(a, ",\"key\":") catch oom();
    c.writeJsonString(&body, a, key);
    body.appendSlice(a, ",\"value\":") catch oom();
    c.writeJsonString(&body, a, value);
    body.appendSlice(a, "}") catch oom();

    const workers = c.workerUrls(env, a);
    var attempt: usize = 0;
    while (attempt < 6) : (attempt += 1) {
        for (workers) |w| {
            const r = c.workerPost(a, env, w, "/_system/v2-kv", &headers, body.items, 30);
            if (r.code == 200 or r.code == 204) {
                std.debug.print("kv-put {s} [{s}] → {d}\n", .{ tenant, key, r.code });
                return;
            }
            std.debug.print("  kv-put via {s}: {d} {s} (trying next)\n", .{ w, r.code, c.trunc(r.body) });
        }
        std.Thread.sleep(2 * std.time.ns_per_s);
    }
    fatal("kv-put '{s}' failed on every worker after retries", .{key});
}

// ── placement / routing verbs (CP, move-secret) ─────────────────────────────

/// POST /_control/provision {tenant, cluster, host?}. 204 = placed, 409 = already.
fn cmdProvision(a: std.mem.Allocator, env: *const c.Env, tenant: []const u8, cluster: []const u8, host: ?[]const u8) void {
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"tenant\":") catch oom();
    c.writeJsonString(&body, a, tenant);
    body.appendSlice(a, ",\"cluster\":") catch oom();
    c.writeJsonString(&body, a, cluster);
    if (host) |h| {
        body.appendSlice(a, ",\"host\":") catch oom();
        c.writeJsonString(&body, a, h);
    }
    body.append(a, '}') catch oom();
    const r = c.cpPost(a, env, "/_control/provision", body.items, 60);
    switch (r.code) {
        204 => std.debug.print("provisioned {s} on {s}{s}\n", .{ tenant, cluster, if (host) |h| std.fmt.allocPrint(a, " (host {s})", .{h}) catch "" else "" }),
        409 => std.debug.print("{s} already placed (409) — use `move` to relocate\n", .{tenant}),
        else => fatal("provision {s}: {d} {s}", .{ tenant, r.code, c.trunc(r.body) }),
    }
}

fn cmdBootstrap(a: std.mem.Allocator, env: *const c.Env) void {
    const cluster = env.get("ROVE_CLUSTER") orelse "prod";
    cmdProvision(a, env, "__admin__", cluster, env.require("REWIND_ADMIN_DOMAIN"));
    _ = cmdReset(a, env);
    std.debug.print("bootstrap complete — deploy capability live; publish with `rewind-ops deploy`\n", .{});
}

// ── genesis: cold bring-up of a virgin cluster (cold-multi) ──

const GenNode = struct {
    id: u64,
    raft_addr: []const u8,
    cp_raft_addr: []const u8 = "",
    http_url: []const u8 = "",
};

/// Parse `ROVE_GENESIS_NODES` — `id=raft_addr[,cp_raft_addr[,http_url]]`,
/// `;`-separated, one per node. `raft_addr` is the worker raft transport addr;
/// `cp_raft_addr` the CP directory-group transport addr; `http_url` the worker
/// HTTP origin. cp_raft/http are optional but recommended (the reconciler carries
/// raft_addr on conf-changes; http_url feeds out-of-band catch-up).
fn parseGenesisNodes(a: std.mem.Allocator, spec: []const u8) []GenNode {
    var list = std.ArrayList(GenNode){};
    var it = std.mem.tokenizeScalar(u8, spec, ';');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse
            fatal("bad ROVE_GENESIS_NODES entry '{s}' (want id=raft_addr[,cp_raft[,http]])", .{entry});
        const id = std.fmt.parseInt(u64, std.mem.trim(u8, entry[0..eq], " \t"), 10) catch
            fatal("bad node id in '{s}'", .{entry});
        // splitScalar (NOT tokenizeScalar): the fields are POSITIONAL
        // (raft, cp_raft, http), so an empty middle — `id=raft,,http`, giving an
        // http_url without a cp_raft_addr — must keep its slot, not collapse.
        var f = std.mem.splitScalar(u8, entry[eq + 1 ..], ',');
        const raft = f.next() orelse "";
        if (std.mem.trim(u8, raft, " \t").len == 0) fatal("node {d}: missing raft_addr", .{id});
        const cp_raft = f.next() orelse "";
        const http = f.next() orelse "";
        list.append(a, .{
            .id = id,
            .raft_addr = std.mem.trim(u8, raft, " \t"),
            .cp_raft_addr = std.mem.trim(u8, cp_raft, " \t"),
            .http_url = std.mem.trim(u8, http, " \t"),
        }) catch oom();
    }
    if (list.items.len == 0) fatal("ROVE_GENESIS_NODES is empty", .{});
    return list.items;
}

/// POST /_control/node-address {cluster,id,raft_addr,cp_raft_addr?,http_url?},
/// retrying — this ALSO gates on the CP directory group having elected a leader
/// (the write only commits on the leader), so it is the cluster's first
/// liveness checkpoint in a cold bring-up.
fn registerNodeAddr(a: std.mem.Allocator, env: *const c.Env, cluster: []const u8, n: GenNode) void {
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"cluster\":") catch oom();
    c.writeJsonString(&body, a, cluster);
    body.appendSlice(a, std.fmt.allocPrint(a, ",\"id\":{d},\"raft_addr\":", .{n.id}) catch oom()) catch oom();
    c.writeJsonString(&body, a, n.raft_addr);
    if (n.cp_raft_addr.len > 0) {
        body.appendSlice(a, ",\"cp_raft_addr\":") catch oom();
        c.writeJsonString(&body, a, n.cp_raft_addr);
    }
    if (n.http_url.len > 0) {
        body.appendSlice(a, ",\"http_url\":") catch oom();
        c.writeJsonString(&body, a, n.http_url);
    }
    body.append(a, '}') catch oom();

    var attempt: u32 = 0;
    while (attempt < 60) : (attempt += 1) {
        const r = c.cpPost(a, env, "/_control/node-address", body.items, 15);
        if (r.code == 204) {
            std.debug.print("  node {d} → {s} registered\n", .{ n.id, n.raft_addr });
            return;
        }
        std.debug.print("  node {d} register: {d} {s} (CP leader settling, retrying)\n", .{ n.id, r.code, c.trunc(r.body) });
        std.Thread.sleep(2 * std.time.ns_per_s);
    }
    fatal("node {d} address registration failed — CP directory group has no leader? (check rewind-cp logs)", .{n.id});
}

/// POST /_control/provision, retrying (a fresh cold-multi attach can transiently
/// 5xx while the group forms + elects). 204 = placed, 409 = already placed (idempotent).
fn provisionRetry(a: std.mem.Allocator, env: *const c.Env, tenant: []const u8, cluster: []const u8, host: ?[]const u8) void {
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"tenant\":") catch oom();
    c.writeJsonString(&body, a, tenant);
    body.appendSlice(a, ",\"cluster\":") catch oom();
    c.writeJsonString(&body, a, cluster);
    if (host) |h| {
        body.appendSlice(a, ",\"host\":") catch oom();
        c.writeJsonString(&body, a, h);
    }
    body.append(a, '}') catch oom();
    var attempt: u32 = 0;
    while (attempt < 30) : (attempt += 1) {
        const r = c.cpPost(a, env, "/_control/provision", body.items, 60);
        switch (r.code) {
            204 => {
                std.debug.print("  provisioned {s} on {s}\n", .{ tenant, cluster });
                return;
            },
            409 => {
                std.debug.print("  {s} already placed (409, ok)\n", .{tenant});
                return;
            },
            else => std.debug.print("  provision {s}: {d} {s} (retrying)\n", .{ tenant, r.code, c.trunc(r.body) }),
        }
        std.Thread.sleep(2 * std.time.ns_per_s);
    }
    fatal("provision {s} failed after retries", .{tenant});
}

/// Count elements in a compact-JSON `"key":[…]` array (the worker emits no
/// spaces). Returns 0 for an absent or empty array.
fn countJsonArray(body: []const u8, key: []const u8) usize {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":[", .{key}) catch return 0;
    defer std.heap.page_allocator.free(needle);
    const start = std.mem.indexOf(u8, body, needle) orelse return 0;
    const arr = body[start + needle.len ..];
    const end = std.mem.indexOfScalar(u8, arr, ']') orelse return 0;
    const inner = std.mem.trim(u8, arr[0..end], " ");
    if (inner.len == 0) return 0;
    var n: usize = 1;
    for (inner) |ch| {
        if (ch == ',') n += 1;
    }
    return n;
}

/// Poll the workers' leader-gated `/_system/v2-member-status?tenant=` (move-secret)
/// until the group reports `want` voters. Under cold-multi the group is born with
/// the full voter set, so this confirms formation (≈instant) rather than waiting
/// on a grow. Followers 409/421; the leader 200s.
fn waitVoters(a: std.mem.Allocator, env: *const c.Env, tenant: []const u8, want: usize, timeout_s: i64) void {
    const ms = env.require("REWIND_MOVE_SECRET");
    const headers = [_]Header{.{ .name = "X-Rewind-Move-Secret", .value = ms }};
    const path = std.fmt.allocPrint(a, "/_system/v2-member-status?tenant={s}", .{tenant}) catch oom();
    const deadline = std.time.timestamp() + timeout_s;
    var last: usize = 0;
    while (std.time.timestamp() < deadline) {
        for (c.workerUrls(env, a)) |w| {
            const url = std.fmt.allocPrint(a, "{s}{s}", .{ w, path }) catch oom();
            const r = c.call(a, env, "GET", url, &headers, null, 10);
            if (r.code == 200) {
                const v = countJsonArray(r.body, "voters");
                if (v != last) {
                    std.debug.print("  {s}: voters={d}/{d}\n", .{ tenant, v, want });
                    last = v;
                }
                if (v >= want) {
                    std.debug.print("  {s} converged to {d} voters ✓\n", .{ tenant, want });
                    return;
                }
            }
        }
        std.Thread.sleep(2 * std.time.ns_per_s);
    }
    fatal("{s} did not form with {d} voters within {d}s — check the cold-multi worker env (REWIND_VOTERS/REWIND_PEERS set on all nodes?) and the worker logs", .{ tenant, want, timeout_s });
}

/// Cold bring-up of a virgin/wiped cluster (cold-multi). Assumes the binaries are
/// already launched on the cold-multi env (workers + CP carry the full static
/// voter set REWIND_VOTERS/REWIND_PEERS + REWIND_CP_VOTERS/_PEERS; reconciler
/// OFF). This drives the operator-side sequence:
///   1. register every node's transport address (gates on the CP directory leader,
///      and seeds the registry for later DR-learner adds / moves),
///   2. provision __admin__ (born {1,2,3} cold-multi, elects on its own),
///   3. confirm __admin__ formed with all N voters,
///   4. deploy the baked __admin__ app (reset) → deploy-capable.
fn cmdGenesis(a: std.mem.Allocator, env: *const c.Env, cluster: []const u8) void {
    const spec = env.get("ROVE_GENESIS_NODES") orelse
        fatal("genesis needs ROVE_GENESIS_NODES (\"id=raft_addr[,cp_raft[,http]];…\")", .{});
    const nodes = parseGenesisNodes(a, spec);
    std.debug.print("genesis: cold bring-up of {d}-node cluster '{s}' (cold-multi)\n", .{ nodes.len, cluster });

    std.debug.print("[1/4] register node addresses (also waits for the CP directory leader)\n", .{});
    for (nodes) |n| registerNodeAddr(a, env, cluster, n);

    std.debug.print("[2/4] provision __admin__ (born {{1,2,3}} cold-multi)\n", .{});
    provisionRetry(a, env, "__admin__", cluster, env.require("REWIND_ADMIN_DOMAIN"));

    std.debug.print("[3/4] confirm __admin__ formed with {d} voters\n", .{nodes.len});
    waitVoters(a, env, "__admin__", nodes.len, 120);

    std.debug.print("[4/4] deploy the baked __admin__ app (reset)\n", .{});
    _ = cmdReset(a, env);

    std.debug.print("\ngenesis complete — {d}-node cluster '{s}' is up and deploy-capable.\n", .{ nodes.len, cluster });
    std.debug.print("  next: provision tenants (`rewind-ops provision <t> --host <h>`) +\n", .{});
    std.debug.print("        publish bundles (`rewind-ops deploy <t> <bundle> --release`).\n", .{});
}

/// POST /_control/move {tenant, cluster}. Guarded by --yes (the riskiest verb —
/// it repoints live routing). The move is zero-downtime (the source serves
/// throughout); a large tenant can take a while to stream, hence the long CP
/// deadline.
fn cmdMove(a: std.mem.Allocator, env: *const c.Env, tenant: []const u8, cluster: []const u8, yes: bool) void {
    if (!yes) fatal("move repoints live routing for {s} → {s}. Re-run with --yes to confirm.", .{ tenant, cluster });
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"tenant\":") catch oom();
    c.writeJsonString(&body, a, tenant);
    body.appendSlice(a, ",\"cluster\":") catch oom();
    c.writeJsonString(&body, a, cluster);
    body.append(a, '}') catch oom();
    const r = c.cpPost(a, env, "/_control/move", body.items, 3600);
    if (r.code == 200 or r.code == 204) {
        std.debug.print("moved {s} → {s}\n", .{ tenant, cluster });
    } else {
        fatal("move {s} → {s}: {d} {s}", .{ tenant, cluster, r.code, c.trunc(r.body) });
    }
}

/// Map a host → tenant. ONE move-secret-gated call: the CP records the
/// directory index (front routing) AND propagates the worker `__root__/domain`
/// alias to the tenant's serving cluster (`/_system/v2-domain`), so a worker
/// recognizes the custom host on direct/relayed requests. The CP owns
/// host→tenant end-to-end now — no second operator secret (`ADMIN_OPS_SECRET`
/// retired, step3-auth-plan.md B3). A 503 means the alias didn't land (tenant
/// unplaced / no reachable leader) — provision the tenant first, then retry.
fn cmdHostAdd(a: std.mem.Allocator, env: *const c.Env, host: []const u8, tenant: []const u8) void {
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"host\":") catch oom();
    c.writeJsonString(&body, a, host);
    body.appendSlice(a, ",\"tenant\":") catch oom();
    c.writeJsonString(&body, a, tenant);
    body.append(a, '}') catch oom();

    const r = c.cpPost(a, env, "/_control/host", body.items, 30);
    if (r.code != 200 and r.code != 204) fatal("host map {s}: {d} {s}", .{ host, r.code, c.trunc(r.body) });
    std.debug.print("host {s} → {s} (CP directory + worker alias)\n", .{ host, tenant });
}

/// POST /_control/plan {tenant, plan} — set the tenant's opaque plan/limits blob.
fn cmdPlan(a: std.mem.Allocator, env: *const c.Env, tenant: []const u8, plan: []const u8) void {
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"tenant\":") catch oom();
    c.writeJsonString(&body, a, tenant);
    body.appendSlice(a, ",\"plan\":") catch oom();
    c.writeJsonString(&body, a, plan);
    body.append(a, '}') catch oom();
    const r = c.cpPost(a, env, "/_control/plan", body.items, 30);
    if (r.code == 200 or r.code == 204) {
        std.debug.print("plan set for {s}: {s}\n", .{ tenant, plan });
    } else {
        fatal("plan {s}: {d} {s}", .{ tenant, r.code, c.trunc(r.body) });
    }
}

/// Resolve a HOST → tenant/cluster/nodes (CP /_cp/route) + the tenant's plan
/// (/_cp/plan). Host-keyed because that's the CP's read surface; the current
/// dep_id + release history aren't exposed yet (see plan §4.2 follow-up).
fn cmdStatus(a: std.mem.Allocator, env: *const c.Env, host: []const u8) void {
    const route_path = std.fmt.allocPrint(a, "/_cp/route?host={s}", .{host}) catch oom();
    const r = c.cpGet(a, env, route_path, 15);
    if (r.code == 404) fatal("status: host {s} maps to no tenant / unplaced", .{host});
    if (r.code != 200) fatal("status {s}: {d} {s}", .{ host, r.code, c.trunc(r.body) });

    const tenant = c.extractField(a, r.body, "tenant") orelse "?";
    const cluster = c.extractField(a, r.body, "cluster") orelse "?";
    const moving = c.extractField(a, r.body, "moving") orelse "false";
    std.debug.print("host:    {s}\n", .{host});
    std.debug.print("tenant:  {s}\n", .{tenant});
    std.debug.print("cluster: {s}  (moving={s})\n", .{ cluster, moving });
    std.debug.print("route:   {s}\n", .{r.body});

    const plan_path = std.fmt.allocPrint(a, "/_cp/plan?tenant={s}", .{tenant}) catch oom();
    const pr = c.cpGet(a, env, plan_path, 15);
    std.debug.print("plan:    {s}\n", .{if (pr.code == 200) pr.body else "(free tier / unset)"});
    std.debug.print("note:    current dep_id + release history have no read endpoint yet (plan §4.2)\n", .{});
}

// ── arg parsing + dispatch ──────────────────────────────────────────────────

const usage =
    \\rewind-ops — platform/operator CLI (docs/plans/rewind-cli-plan.md)
    \\
    \\usage:
    \\  rewind-ops genesis [--cluster C]              cold bring-up from empty (needs ROVE_GENESIS_NODES)
    \\  rewind-ops node-addr <cluster> <id> <raft_addr> [cp_raft_addr] [http_url]   register a node's transport address
    \\  rewind-ops bootstrap                          provision __admin__ + reset (cluster already up)
    \\  rewind-ops reset                              (re)deploy the baked __admin__ deploy app
    \\  rewind-ops deploy <tenant> <bundle> [--release]   publish a bundle through the app
    \\  rewind-ops release <tenant> <dep_id_hex>      flip _deploy/current live
    \\  rewind-ops provision <tenant> [--cluster C] [--host H]   create+place a tenant
    \\  rewind-ops move <tenant> <cluster> --yes                 relocate a tenant (zero-downtime)
    \\  rewind-ops host add <host> <tenant>           map a domain → tenant
    \\  rewind-ops plan set <tenant> <plan>           set a tenant's plan/limits blob
    \\  rewind-ops kv-put <tenant> <key> [value]     seed a system kv key (move-secret; operator/OIDC bootstrap)
    \\  rewind-ops status <host>                      resolve a host → tenant/cluster/plan
    \\
    \\options:
    \\  --env <path>   operator env file (default ~/.config/rove/prod.env, then ./.env.prod)
    \\
;

const Flags = struct {
    env_path: ?[]const u8 = null,
    cluster: ?[]const u8 = null,
    host: ?[]const u8 = null,
    release: bool = false,
    yes: bool = false,
};

pub fn main() void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const argv = std.process.argsAlloc(a) catch oom();
    if (argv.len < 2) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }

    var flags = Flags{};
    var pos = std.ArrayList([]const u8){};
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--env")) {
            i += 1;
            if (i >= argv.len) fatal("--env needs a path", .{});
            flags.env_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--cluster")) {
            i += 1;
            if (i >= argv.len) fatal("--cluster needs a value", .{});
            flags.cluster = argv[i];
        } else if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= argv.len) fatal("--host needs a value", .{});
            flags.host = argv[i];
        } else if (std.mem.eql(u8, arg, "--release")) {
            flags.release = true;
        } else if (std.mem.eql(u8, arg, "--live")) {
            // Tolerated no-op: the move is always zero-downtime now (the
            // brief-pause variant was retired). Accepted so old invocations
            // don't error.
        } else if (std.mem.eql(u8, arg, "--yes")) {
            flags.yes = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else {
            pos.append(a, arg) catch oom();
        }
    }
    if (flags.env_path == null) flags.env_path = c.defaultEnvPath(a);

    var env = c.loadEnv(gpa, flags.env_path);
    defer env.deinit();
    const p = pos.items;
    const cmd = argv[1];

    if (std.mem.eql(u8, cmd, "reset")) {
        _ = cmdReset(a, &env);
    } else if (std.mem.eql(u8, cmd, "bootstrap")) {
        cmdBootstrap(a, &env);
    } else if (std.mem.eql(u8, cmd, "genesis")) {
        const cluster = flags.cluster orelse env.get("ROVE_CLUSTER") orelse "prod";
        cmdGenesis(a, &env, cluster);
    } else if (std.mem.eql(u8, cmd, "node-addr")) {
        if (p.len < 3) fatal("node-addr needs <cluster> <id> <raft_addr> [cp_raft_addr] [http_url]", .{});
        const id = std.fmt.parseInt(u64, p[1], 10) catch fatal("node-addr: bad id '{s}'", .{p[1]});
        registerNodeAddr(a, &env, p[0], .{
            .id = id,
            .raft_addr = p[2],
            .cp_raft_addr = if (p.len >= 4) p[3] else "",
            .http_url = if (p.len >= 5) p[4] else "",
        });
    } else if (std.mem.eql(u8, cmd, "deploy")) {
        if (p.len < 2) fatal("deploy needs <tenant> <bundle>", .{});
        cmdDeploy(a, &env, p[0], p[1], flags.release);
    } else if (std.mem.eql(u8, cmd, "release")) {
        if (p.len < 2) fatal("release needs <tenant> <dep_id_hex>", .{});
        cmdRelease(a, &env, p[0], p[1]);
    } else if (std.mem.eql(u8, cmd, "provision")) {
        if (p.len < 1) fatal("provision needs <tenant>", .{});
        const cluster = flags.cluster orelse env.get("ROVE_CLUSTER") orelse "prod";
        cmdProvision(a, &env, p[0], cluster, flags.host);
    } else if (std.mem.eql(u8, cmd, "move")) {
        if (p.len < 2) fatal("move needs <tenant> <cluster>", .{});
        cmdMove(a, &env, p[0], p[1], flags.yes);
    } else if (std.mem.eql(u8, cmd, "host")) {
        if (p.len < 1) fatal("host needs a subcommand: add <host> <tenant>", .{});
        if (std.mem.eql(u8, p[0], "add")) {
            if (p.len < 3) fatal("host add needs <host> <tenant>", .{});
            cmdHostAdd(a, &env, p[1], p[2]);
        } else if (std.mem.eql(u8, p[0], "rm")) {
            fatal("host rm: no CP delete primitive yet (only setHost) — see plan §2", .{});
        } else fatal("unknown host subcommand '{s}' (want: add)", .{p[0]});
    } else if (std.mem.eql(u8, cmd, "plan")) {
        if (p.len < 1 or !std.mem.eql(u8, p[0], "set")) fatal("plan needs: set <tenant> <plan>", .{});
        if (p.len < 3) fatal("plan set needs <tenant> <plan>", .{});
        cmdPlan(a, &env, p[1], p[2]);
    } else if (std.mem.eql(u8, cmd, "kv-put")) {
        if (p.len < 2) fatal("kv-put needs <tenant> <key> [value] (value defaults to empty)", .{});
        cmdKvPut(a, &env, p[0], p[1], if (p.len >= 3) p[2] else "");
    } else if (std.mem.eql(u8, cmd, "status")) {
        if (p.len < 1) fatal("status needs <host>", .{});
        cmdStatus(a, &env, p[0]);
    } else if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
        std.debug.print("{s}", .{usage});
    } else {
        fatal("unknown command '{s}'\n{s}", .{ cmd, usage });
    }
}
