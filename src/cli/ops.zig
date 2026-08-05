// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `rewind-ops` — the platform/operator CLI (docs/architecture/cli-and-deploy.md §2–§3,
//! §6). The privileged half of the split: every verb here carries an operator
//! secret (root token → workers + deploy app; REWIND_MOVE_SECRET → CP control,
//! which also propagates the worker domain alias). Never shipped to
//! customers — the OIDC-scoped tenant verbs live in the separate `rewind`
//! binary (built when the __auth__ IdP lands; both reuse `common.zig`).
//!
//! Verbs:
//!   bootstrap                       provision __admin__ via the CP + reset —
//!                                   first-time bring-up of a virgin cluster.
//!   reset                           POST {worker}/_system/reset — (re)deploy the
//!                                   baked __admin__ deploy app (break-glass).
//!   deploy <tenant> <bundle> [--release]   classify + POST to the standing app.
//!   release <tenant> <dep_id_hex>   flip _deploy/current (leader-aware retry).
//!   provision <tenant> [--cluster C] [--host H]   create+place a tenant (CP).
//!
//!   CP control verbs (provision / delete / move / host add / plan set) go
//!   through the `__admin__` chokepoint by default: the worker attaches the
//!   move-secret at the `rewind-cp.internal` door, so this shell needs only
//!   REWIND_ROOT_TOKEN, and the action lands as a replayable admin record.
//!   `--direct` posts at the CP instead — needs REWIND_MOVE_SECRET here and
//!   leaves NO record. For a broken/undeployed admin app (and for `bootstrap`,
//!   which provisions `__admin__` itself and so cannot route through it).
//!   delete <tenant> --yes           deprovision: unroute + tear down the group (CP).
//!   move <tenant> <cluster> --yes                 relocate a tenant (zero-downtime) (CP).
//!   host add <host> <tenant>        map a domain → tenant (CP index; CP pushes the worker alias).
//!   plan set <tenant> <plan>        set a tenant's plan/limits blob (CP).
//!   seed-packages                   publish the first-party @rewind/* set into the registry (genesis).
//!   status <host>                   resolve a host → tenant/cluster/nodes + plan.
//!
//! Config: operator env file (default ~/.config/rove/prod.env, then ./.env.prod,
//! --env override; OS env overlays). Vars: REWIND_ROOT_TOKEN, REWIND_ADMIN_DOMAIN,
//! REWIND_REGISTRY_DOMAIN (seed-packages), ROVE_WORKER_URLS, ROVE_CLUSTER,
//! ROVE_PUBLISH_SSH?, ROVE_CP_URL_INTERNAL, REWIND_MOVE_SECRET.

const std = @import("std");
const c = @import("common.zig");
const storage_namespace = @import("storage_namespace.zig");

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

/// POST a CP control op through the `__admin__` CHOKEPOINT rather than at the
/// control plane directly (`docs/architecture/control-plane.md`; rove#414).
///
/// The dashboard has always driven control ops this way — `handleCpPost` in the
/// admin app relays any `_control/*` op through the `rewind-cp.internal` door,
/// which the worker opens only for `__admin__` and only with the move-secret it
/// attaches itself. This routes the CLI through the same door, for two reasons:
///
///   1. **The operator shell stops holding the move-secret.** That was already
///      the stated posture in the admin app ("operators drive CP control ops
///      through the dashboard, NOT by holding the move-secret on a shell"); the
///      CLI was the one caller that did not honour it.
///   2. **The action becomes a recorded activation.** A direct CP POST runs no
///      handler, so it produces no log record and cannot be replayed — the
///      operator plane had no audit trail at all. Through the chokepoint it is
///      an ordinary `__admin__` request: logged, taped, digested.
///
/// Tries each worker in turn like `cmdReset` — the admin group is leader-gated,
/// and a follower answers with a redirect/5xx rather than acting.
fn cpOpViaAdmin(
    a: std.mem.Allocator,
    env: *const c.Env,
    op: []const u8,
    body: []const u8,
    timeout_s: u32,
) c.Resp {
    const headers = authHeaders(a, env);
    const path = std.fmt.allocPrint(a, "/v1/cp/{s}", .{op}) catch oom();
    var last: ?c.Resp = null;
    for (c.workerUrls(env, a)) |w| {
        const r = c.workerPost(a, env, w, path, headers, body, timeout_s);
        // 2xx is the op's own answer; a 4xx that is not the leader-gate is the
        // CP's verdict (e.g. 409 already-placed) and must NOT be retried
        // elsewhere, or a second node re-runs a non-idempotent op.
        if (r.code >= 200 and r.code < 500 and r.code != 404) return r;
        last = r;
        std.debug.print("  cp/{s} via {s}: {d} {s} (trying next)\n", .{ op, w, r.code, c.trunc(r.body) });
    }
    const r = last orelse fatal("cp/{s}: no worker answered", .{op});
    // Every worker 404'd: the deployed `__admin__` app has no `/v1/cp/:op`
    // route. The BAKED genesis app does not — the chokepoint exists only once
    // the real dashboard is deployed. Fail loud with the way out rather than
    // silently falling back to the direct path, which would quietly put the
    // move-secret back on this shell and drop the record.
    if (r.code == 404) {
        fatal(
            "cp/{s}: the deployed __admin__ app has no /v1/cp/ route (the baked genesis app does not).\n" ++
                "  Deploy the dashboard, or re-run with --direct (needs REWIND_MOVE_SECRET; leaves no record).",
            .{op},
        );
    }
    return r;
}

/// A CP control op: through the `__admin__` chokepoint by default, at the CP
/// directly when `direct` is set.
///
/// `direct` is NOT a convenience. It is required for the two cases the
/// chokepoint structurally cannot serve:
///
///   - **bootstrap / genesis**, where the op being run IS `provision __admin__`
///     — there is no admin app to route through yet (`cmdGenesis`);
///   - **break-glass**, where the admin app is down or mis-deployed and the
///     operator still has to move or delete a tenant.
///
/// Both need `REWIND_MOVE_SECRET`; the default path does not.
fn cpOp(
    a: std.mem.Allocator,
    env: *const c.Env,
    op: []const u8,
    body: []const u8,
    timeout_s: u32,
    direct: bool,
) c.Resp {
    if (direct) return c.cpPost(a, env, std.fmt.allocPrint(a, "/_control/{s}", .{op}) catch oom(), body, timeout_s);
    return cpOpViaAdmin(a, env, op, body, timeout_s);
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
    // cut a release. Each request is small; a single mega-POST would
    // base64-buffer the whole bundle in the deploy app's JS heap and OOM
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

/// POST /_control/delete {tenant}. Deprovision: the CP withdraws the tenant's
/// directory rows (unroutable from that moment, name freed) and tears its raft
/// group down on every node. 204 = gone; 502 = unrouted but not fully torn
/// down, so re-run. Destroys the tenant's data — gated behind `--yes`.
fn cmdDelete(a: std.mem.Allocator, env: *const c.Env, tenant: []const u8, yes: bool, direct: bool) void {
    if (!yes) fatal("delete {s}: refusing without --yes (this destroys the tenant)", .{tenant});
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"tenant\":") catch oom();
    c.writeJsonString(&body, a, tenant);
    body.append(a, '}') catch oom();
    const r = cpOp(a, env, "delete", body.items, 120, direct);
    switch (r.code) {
        204 => std.debug.print("deleted {s} — unroutable, rows withdrawn, group evicted\n", .{tenant}),
        502 => fatal("delete {s}: unroutable but NOT fully torn down — re-run `delete` ({s})", .{ tenant, c.trunc(r.body) }),
        else => fatal("delete {s}: {d} {s}", .{ tenant, r.code, c.trunc(r.body) }),
    }
}

/// POST /_control/provision {tenant, cluster, host?}. 200 = placed (the body
/// reports the host it answers on; 204 is the same outcome from a CP that
/// couldn't build the report), 409 = already placed. A 4xx carries
/// `{"error": reason}` naming the rule the id broke.
fn cmdProvision(a: std.mem.Allocator, env: *const c.Env, tenant: []const u8, cluster: []const u8, host: ?[]const u8, direct: bool) void {
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
    const r = cpOp(a, env, "provision", body.items, 60, direct);
    switch (r.code) {
        200 => std.debug.print("provisioned {s} on {s} — {s}\n", .{ tenant, cluster, c.trunc(r.body) }),
        204 => std.debug.print("provisioned {s} on {s}{s}\n", .{ tenant, cluster, if (host) |h| std.fmt.allocPrint(a, " (host {s})", .{h}) catch "" else "" }),
        409 => std.debug.print("{s} already placed (409) — use `move` to relocate\n", .{tenant}),
        else => fatal("provision {s}: {d} {s}", .{ tenant, r.code, c.trunc(r.body) }),
    }
}

fn cmdBootstrap(a: std.mem.Allocator, env: *const c.Env) void {
    const cluster = env.get("ROVE_CLUSTER") orelse "prod";
    // Structurally DIRECT: the op being run IS `provision __admin__`, so there
    // is no admin app to route the chokepoint through yet (rove#414).
    cmdProvision(a, env, "__admin__", cluster, env.require("REWIND_ADMIN_DOMAIN"), true);
    _ = cmdReset(a, env);
    std.debug.print("bootstrap complete — deploy capability live; publish with `rewind-ops deploy`\n", .{});
}

// ── genesis package seed ────────────────────────────────────────────────────
// The first-party @rewind/* set must exist in the `registry` tenant before any
// consumer deploys — otherwise the auth→oidc→registry-package→registry-needs-
// publishing bootstrap cycle can never start. Run once, after the registry
// tenant is provisioned + its app deployed.
//
// The registry is a normal tenant with no platform.auth.checkRootToken, and at
// genesis there is no OIDC IdP to log into. So this authenticates publish via a
// seeded operator-token hash: kv-put sha256(root_token) into the registry's own
// kv (its middleware grants is_root to a Bearer that hashes to it), then POST
// each package SOURCE to /v1/packages with the root token as Bearer. The
// registry hashes + writes each package with its OWN code — one canonical
// pkg_hash implementation, zero cross-publisher divergence. Source-only: each
// consumer compiles the package at its own deploy (the B path).

const SeedPkg = struct {
    spec: []const u8,
    source: []const u8,
    dep_jwt: bool = false, // imports @rewind/jwt (frozen to jwt's pkg_hash at publish)
};

const SEED_VERSION = "1.0.0"; // genesis versions are immutable once seeded
const REGISTRY_TENANT = "registry";

// LEAVES-FIRST: @rewind/jwt has no intra-set dependency and MUST publish before
// oauth/oidc (the only two that import it), so the registry can freeze their dep
// to jwt's concrete pkg_hash. The other nine are independent leaves (any order).
const SEED_PACKAGES = [_]SeedPkg{
    .{ .spec = "@rewind/jwt", .source = @embedFile("pkg_jwt") },
    .{ .spec = "@rewind/cron", .source = @embedFile("pkg_cron") },
    .{ .spec = "@rewind/email", .source = @embedFile("pkg_email") },
    .{ .spec = "@rewind/sessions", .source = @embedFile("pkg_sessions") },
    .{ .spec = "@rewind/retry", .source = @embedFile("pkg_retry") },
    .{ .spec = "@rewind/activitypub", .source = @embedFile("pkg_activitypub") },
    .{ .spec = "@rewind/users", .source = @embedFile("pkg_users") },
    .{ .spec = "@rewind/segments", .source = @embedFile("pkg_segments") },
    .{ .spec = "@rewind/schedule", .source = @embedFile("pkg_schedule") },
    .{ .spec = "@rewind/browser", .source = @embedFile("pkg_browser") },
    .{ .spec = "@rewind/oauth", .source = @embedFile("pkg_oauth"), .dep_jwt = true },
    .{ .spec = "@rewind/oidc", .source = @embedFile("pkg_oidc"), .dep_jwt = true },
};

fn sha256Hex(a: std.mem.Allocator, s: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(s, &digest, .{});
    const hex = a.alloc(u8, 64) catch oom();
    const lut = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = lut[byte >> 4];
        hex[i * 2 + 1] = lut[byte & 0xf];
    }
    return hex;
}

fn cmdSeedPackages(a: std.mem.Allocator, env: *const c.Env) void {
    const rt = env.require("REWIND_ROOT_TOKEN");
    const reg_host = env.require("REWIND_REGISTRY_DOMAIN");

    // 1. Seed the operator-token hash so the registry accepts our Bearer.
    std.debug.print("[1/2] seed operator-token hash → {s}\n", .{REGISTRY_TENANT});
    cmdKvPut(a, env, REGISTRY_TENANT, "_optoken/publish_sha256", sha256Hex(a, rt));

    // 2. Publish the first-party set, leaves-first, routed by the registry Host.
    const headers = a.alloc(Header, 3) catch oom();
    headers[0] = .{ .name = "Host", .value = reg_host };
    headers[1] = .{ .name = "Authorization", .value = std.fmt.allocPrint(a, "Bearer {s}", .{rt}) catch oom() };
    headers[2] = .{ .name = "Content-Type", .value = "application/json" };

    std.debug.print("[2/2] publish {d} first-party packages (leaves-first)\n", .{SEED_PACKAGES.len});
    for (SEED_PACKAGES) |pkg| publishPackage(a, env, headers, pkg);
    std.debug.print("genesis package seed complete — {d} packages live in {s}\n", .{ SEED_PACKAGES.len, REGISTRY_TENANT });
}

fn publishPackage(a: std.mem.Allocator, env: *const c.Env, headers: []const Header, pkg: SeedPkg) void {
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"spec\":") catch oom();
    c.writeJsonString(&body, a, pkg.spec);
    body.appendSlice(a, ",\"version\":\"" ++ SEED_VERSION ++ "\",\"files\":[{\"path\":\"index.mjs\",\"source\":") catch oom();
    c.writeJsonString(&body, a, pkg.source);
    body.appendSlice(a, "}]") catch oom();
    if (pkg.dep_jwt) body.appendSlice(a, ",\"dependencies\":{\"@rewind/jwt\":\"" ++ SEED_VERSION ++ "\"}") catch oom();
    body.append(a, '}') catch oom();

    const workers = c.workerUrls(env, a);
    var attempt: usize = 0;
    while (attempt < 6) : (attempt += 1) {
        for (workers) |w| {
            const r = c.workerPost(a, env, w, "/v1/packages", headers, body.items, 60);
            // 201 = created, 200 = idempotent re-publish (identical content). Both OK.
            if (r.code == 200 or r.code == 201) {
                std.debug.print("  published {s}@{s} → {d}\n", .{ pkg.spec, SEED_VERSION, r.code });
                return;
            }
            // 409 = this version already holds DIFFERENT bytes — a frozen-identity
            // violation (someone changed a lib's source). Never retry; the operator
            // must reconcile (bump the version or restore the bytes).
            if (r.code == 409) fatal("publish {s}@{s}: 409 conflict — version already holds different content: {s}", .{ pkg.spec, SEED_VERSION, c.trunc(r.body) });
            std.debug.print("  publish {s} via {s}: {d} {s} (trying next)\n", .{ pkg.spec, w, r.code, c.trunc(r.body) });
        }
        std.Thread.sleep(2 * std.time.ns_per_s);
    }
    fatal("publish '{s}' failed on every worker after retries", .{pkg.spec});
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
/// 5xx while the group forms + elects). 200/204 = placed, 409 = already placed
/// (idempotent).
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
            200, 204 => {
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
fn cmdMove(a: std.mem.Allocator, env: *const c.Env, tenant: []const u8, cluster: []const u8, yes: bool, direct: bool) void {
    if (!yes) fatal("move repoints live routing for {s} → {s}. Re-run with --yes to confirm.", .{ tenant, cluster });
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"tenant\":") catch oom();
    c.writeJsonString(&body, a, tenant);
    body.appendSlice(a, ",\"cluster\":") catch oom();
    c.writeJsonString(&body, a, cluster);
    body.append(a, '}') catch oom();
    const r = cpOp(a, env, "move", body.items, 3600, direct);
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
/// host→tenant end-to-end — no second operator secret
/// (docs/architecture/auth-consolidation.md B3). A 503 means the alias didn't land (tenant
/// unplaced / no reachable leader) — provision the tenant first, then retry.
fn cmdHostAdd(a: std.mem.Allocator, env: *const c.Env, host: []const u8, tenant: []const u8, direct: bool) void {
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"host\":") catch oom();
    c.writeJsonString(&body, a, host);
    body.appendSlice(a, ",\"tenant\":") catch oom();
    c.writeJsonString(&body, a, tenant);
    body.append(a, '}') catch oom();

    const r = cpOp(a, env, "host", body.items, 30, direct);
    if (r.code != 200 and r.code != 204) fatal("host map {s}: {d} {s}", .{ host, r.code, c.trunc(r.body) });
    std.debug.print("host {s} → {s} (CP directory + worker alias)\n", .{ host, tenant });
}

/// POST /_control/plan {tenant, plan} — set the tenant's opaque plan/limits blob.
fn cmdPlan(a: std.mem.Allocator, env: *const c.Env, tenant: []const u8, plan: []const u8, direct: bool) void {
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"tenant\":") catch oom();
    c.writeJsonString(&body, a, tenant);
    body.appendSlice(a, ",\"plan\":") catch oom();
    c.writeJsonString(&body, a, plan);
    body.append(a, '}') catch oom();
    const r = cpOp(a, env, "plan", body.items, 30, direct);
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
    \\rewind-ops — platform/operator CLI (docs/architecture/cli-and-deploy.md)
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
    \\  rewind-ops delete <tenant> --yes             deprovision a tenant (CP: unroute, drop rows, evict the group)
    \\  rewind-ops kv-put <tenant> <key> [value]     seed a system kv key (move-secret; operator/OIDC bootstrap)
    \\  rewind-ops seed-packages                     publish the first-party @rewind/* set into the registry (genesis)
    \\  rewind-ops status <host>                      resolve a host → tenant/cluster/plan
    \\  rewind-ops storage-namespace [--adopt|--bump|--print-prefix]  show/set the object store's generation
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
    /// Break-glass: talk to the control plane directly instead of through the
    /// `__admin__` chokepoint. Needs REWIND_MOVE_SECRET on this shell and leaves
    /// NO record of the action (rove#414) — for a broken or undeployed admin
    /// app, not for convenience.
    direct: bool = false,
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
            // Tolerated no-op: the move is always zero-downtime. Accepted
            // so old invocations don't error.
        } else if (std.mem.eql(u8, arg, "--direct")) {
            flags.direct = true;
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
        cmdProvision(a, &env, p[0], cluster, flags.host, flags.direct);
    } else if (std.mem.eql(u8, cmd, "delete")) {
        // The verb was documented in the usage text and implemented, but never
        // dispatched — `rewind-ops delete` fell through to "unknown command"
        // from the commit that added it. Wired here because this change routes
        // it through the chokepoint and a deprovision that cannot be invoked
        // has no audit trail worth arguing about.
        if (p.len < 1) fatal("delete needs <tenant>", .{});
        cmdDelete(a, &env, p[0], flags.yes, flags.direct);
    } else if (std.mem.eql(u8, cmd, "move")) {
        if (p.len < 2) fatal("move needs <tenant> <cluster>", .{});
        cmdMove(a, &env, p[0], p[1], flags.yes, flags.direct);
    } else if (std.mem.eql(u8, cmd, "host")) {
        if (p.len < 1) fatal("host needs a subcommand: add <host> <tenant>", .{});
        if (std.mem.eql(u8, p[0], "add")) {
            if (p.len < 3) fatal("host add needs <host> <tenant>", .{});
            cmdHostAdd(a, &env, p[1], p[2], flags.direct);
        } else if (std.mem.eql(u8, p[0], "rm")) {
            fatal("host rm: no CP delete primitive yet (only setHost) — see plan §2", .{});
        } else fatal("unknown host subcommand '{s}' (want: add)", .{p[0]});
    } else if (std.mem.eql(u8, cmd, "plan")) {
        if (p.len < 1 or !std.mem.eql(u8, p[0], "set")) fatal("plan needs: set <tenant> <plan>", .{});
        if (p.len < 3) fatal("plan set needs <tenant> <plan>", .{});
        cmdPlan(a, &env, p[1], p[2], flags.direct);
    } else if (std.mem.eql(u8, cmd, "kv-put")) {
        if (p.len < 2) fatal("kv-put needs <tenant> <key> [value] (value defaults to empty)", .{});
        cmdKvPut(a, &env, p[0], p[1], if (p.len >= 3) p[2] else "");
    } else if (std.mem.eql(u8, cmd, "seed-packages")) {
        cmdSeedPackages(a, &env);
    } else if (std.mem.eql(u8, cmd, "storage-namespace")) {
        var mode: storage_namespace.Mode = .show;
        for (p) |arg| {
            if (std.mem.eql(u8, arg, "--adopt")) mode = .adopt;
            if (std.mem.eql(u8, arg, "--bump")) mode = .bump;
            if (std.mem.eql(u8, arg, "--print-prefix")) mode = .print_prefix;
        }
        storage_namespace.cmd(a, &env, mode);
    } else if (std.mem.eql(u8, cmd, "status")) {
        if (p.len < 1) fatal("status needs <host>", .{});
        cmdStatus(a, &env, p[0]);
    } else if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
        std.debug.print("{s}", .{usage});
    } else {
        fatal("unknown command '{s}'\n{s}", .{ cmd, usage });
    }
}
