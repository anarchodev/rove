//! `rewind-ops` — the platform/operator CLI (docs/rewind-cli-plan.md §2–§3,
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
//!   move <tenant> <cluster> [--live] --yes        relocate a tenant (CP).
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

    const body = c.deployBody(a, tenant, b);
    const headers = authHeaders(a, env);
    var dep: ?[]const u8 = null;
    // POST /v1/deploy — the one deploy path (rewind-cli-plan Track 0). The
    // baked genesis bootstrap app is path-agnostic; the standing web/admin app
    // OWNS /v1/deploy (root-token M2M gate), so deploys work in both worlds.
    for (c.workerUrls(env, a)) |w| {
        const r = c.workerPost(a, env, w, "/v1/deploy", headers, body, 120);
        if (r.code == 200) {
            dep = c.extractDepId(a, r.body) orelse fatal("deploy: 200 but no dep_id: {s}", .{r.body});
            break;
        }
        std.debug.print("  deploy via {s}: {d} {s} (trying next)\n", .{ w, r.code, c.trunc(r.body) });
    }
    const dep_id = dep orelse fatal("deploy failed on every worker", .{});
    std.debug.print("deployment staged: {s} ({d} file(s)) — NOT released\n", .{ dep_id, b.handlers.len + b.statics.len });
    if (release) cmdRelease(a, env, tenant, dep_id);
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

/// POST /_control/move|move-live {tenant, cluster}. Guarded by --yes (the
/// riskiest verb — it repoints live routing).
fn cmdMove(a: std.mem.Allocator, env: *const c.Env, tenant: []const u8, cluster: []const u8, live: bool, yes: bool) void {
    if (!yes) fatal("move repoints live routing for {s} → {s}. Re-run with --yes to confirm.", .{ tenant, cluster });
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"tenant\":") catch oom();
    c.writeJsonString(&body, a, tenant);
    body.appendSlice(a, ",\"cluster\":") catch oom();
    c.writeJsonString(&body, a, cluster);
    body.append(a, '}') catch oom();
    const path = if (live) "/_control/move-live" else "/_control/move";
    const r = c.cpPost(a, env, path, body.items, 120);
    if (r.code == 200 or r.code == 204) {
        std.debug.print("moved {s} → {s}{s}\n", .{ tenant, cluster, if (live) " (live)" else "" });
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
    \\rewind-ops — platform/operator CLI (docs/rewind-cli-plan.md)
    \\
    \\usage:
    \\  rewind-ops bootstrap                          provision __admin__ + reset (virgin cluster)
    \\  rewind-ops reset                              (re)deploy the baked __admin__ deploy app
    \\  rewind-ops deploy <tenant> <bundle> [--release]   publish a bundle through the app
    \\  rewind-ops release <tenant> <dep_id_hex>      flip _deploy/current live
    \\  rewind-ops provision <tenant> [--cluster C] [--host H]   create+place a tenant
    \\  rewind-ops move <tenant> <cluster> [--live] --yes        relocate a tenant
    \\  rewind-ops host add <host> <tenant>           map a domain → tenant
    \\  rewind-ops plan set <tenant> <plan>           set a tenant's plan/limits blob
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
    live: bool = false,
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
            flags.live = true;
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
        cmdMove(a, &env, p[0], p[1], flags.live, flags.yes);
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
    } else if (std.mem.eql(u8, cmd, "status")) {
        if (p.len < 1) fatal("status needs <host>", .{});
        cmdStatus(a, &env, p[0]);
    } else if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
        std.debug.print("{s}", .{usage});
    } else {
        fatal("unknown command '{s}'\n{s}", .{ cmd, usage });
    }
}
