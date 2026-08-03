// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `rewind` — the OIDC customer CLI (docs/architecture/cli-and-deploy.md §6 + Track 3). The
//! customer-shippable twin of `rewind-ops`: it carries an OIDC session, never
//! a platform secret. Auth is the GATEWAY / session-bearer model — `login`
//! runs the RFC 8628 device grant against the IdP, exchanges the resulting
//! id_token for a dashboard RP session (POST /v1/cli/exchange), and stores the
//! session cookie. `deploy` / `release` / `status` present that cookie to the
//! SAME ownership-gated dashboard endpoints a browser uses — no new authority
//! surface (the server proves ownership; the CLI holds no cap).
//!
//! Transport is TLS + a curl cookie jar (vs. rewind-ops' h2c-to-internal).
//! Shared bundle/JSON/process plumbing comes from common.zig. std-only.
//!
//! Config resolves OS env first, then a config file: --env <file> if given,
//! else ~/.config/rewind/config ($XDG_CONFIG_HOME/rewind/config), KEY=VALUE
//! lines. Keys: REWIND_ADMIN_URL (dashboard origin), REWIND_IDP_URL (the IdP
//! origin), REWIND_CLIENT_ID (default admin-dashboard), REWIND_SESSION
//! (cookie-jar path, default ~/.config/rewind/rewind.session).
//! REWIND_REGISTRY_URL — the @rewind package registry origin, consulted only
//! when a bundle's manifest.json declares `dependencies` (P-CLI, rove#122).
//! REWIND_ROOT_TOKEN — headless auth: present the operator root token as a
//! Bearer instead of the interactive OIDC session (CI / automation / smokes;
//! deploy/release/CP accept it). For self-hosted clusters with a private CA /
//! split-horizon DNS: REWIND_CACERT (curl --cacert) and REWIND_RESOLVE (curl
//! --resolve entries, comma-separated host:port:addr).

const std = @import("std");
const c = @import("common.zig");
const packages = @import("packages.zig");
const replay = @import("rove-replay");
const build_options = @import("build_options");

// libc: pin the process timezone. `setenv` writes the `TZ` env; `tzset`
// applies it to the timezone state `localtime_r` (quickjs-ng's date impl)
// reads. Called once at startup to pin TZ=UTC.
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn tzset() void;

const DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code";

const Cfg = struct {
    env: c.Env,
    admin_url: []const u8,
    idp_url: []const u8,
    client_id: []const u8,
    session_file: []const u8,
    cacert: ?[]const u8,
    resolves: [][]const u8, // curl --resolve entries
    /// The `@rewind` package registry origin (`REWIND_REGISTRY_URL`), for a
    /// bundle that declares `dependencies`. Optional — a package-free deploy
    /// never touches it; required (with a clear error) once deps are declared.
    registry_url: ?[]const u8,
    /// Operator root token (`REWIND_ROOT_TOKEN`) for HEADLESS auth — CI /
    /// automation / smokes, where the interactive OIDC `login` flow isn't
    /// available. When set, the session-bearing verbs (deploy/release/CP)
    /// present it as `Authorization: Bearer …` instead of the cookie jar (the
    /// deploy + release doors accept it). Unset → the normal OIDC session.
    root_token: ?[]const u8,
};

fn cfgVar(env: *const c.Env, a: std.mem.Allocator, name: []const u8) ?[]const u8 {
    // OS env wins over the file (so a customer can override per-invocation).
    if (std.process.getEnvVarOwned(a, name) catch null) |v| {
        if (v.len != 0) return v;
    }
    return env.get(name);
}

fn loadCfg(gpa: std.mem.Allocator, a: std.mem.Allocator, env_path: ?[]const u8) Cfg {
    const env = c.loadEnv(gpa, env_path);
    const admin = cfgVar(&env, a, "REWIND_ADMIN_URL") orelse
        c.fatal("missing REWIND_ADMIN_URL (the dashboard origin, e.g. https://app.example.com)", .{});
    const idp = cfgVar(&env, a, "REWIND_IDP_URL") orelse
        c.fatal("missing REWIND_IDP_URL (the IdP origin, e.g. https://auth.example.com)", .{});
    const client = cfgVar(&env, a, "REWIND_CLIENT_ID") orelse "admin-dashboard";
    const session = cfgVar(&env, a, "REWIND_SESSION") orelse defaultSessionPath(a);

    var resolves = std.ArrayList([]const u8){};
    if (cfgVar(&env, a, "REWIND_RESOLVE")) |csv| {
        var it = std.mem.splitScalar(u8, csv, ',');
        while (it.next()) |e| {
            const t = std.mem.trim(u8, e, " \t");
            if (t.len != 0) resolves.append(a, t) catch c.oom();
        }
    }
    return .{
        .env = env,
        .admin_url = std.mem.trimRight(u8, admin, "/"),
        .idp_url = std.mem.trimRight(u8, idp, "/"),
        .client_id = client,
        .session_file = session,
        .cacert = cfgVar(&env, a, "REWIND_CACERT"),
        .resolves = resolves.items,
        .registry_url = if (cfgVar(&env, a, "REWIND_REGISTRY_URL")) |u| std.mem.trimRight(u8, u, "/") else null,
        .root_token = cfgVar(&env, a, "REWIND_ROOT_TOKEN"),
    };
}

fn defaultSessionPath(a: std.mem.Allocator) []const u8 {
    const home = std.process.getEnvVarOwned(a, "HOME") catch return "rewind.session";
    const dir = std.fs.path.join(a, &.{ home, ".config", "rewind" }) catch return "rewind.session";
    std.fs.cwd().makePath(dir) catch {};
    return std.fs.path.join(a, &.{ dir, "rewind.session" }) catch "rewind.session";
}

/// The customer CLI's default config path: $XDG_CONFIG_HOME/rewind/config (or
/// ~/.config/rewind/config), KEY=VALUE lines (same format as --env). Falls back
/// to the shared operator default (rove/prod.env, ./.env.prod) when absent.
/// An explicit --env <file> overrides this.
fn defaultConfigPath(a: std.mem.Allocator) ?[]const u8 {
    const base = (std.process.getEnvVarOwned(a, "XDG_CONFIG_HOME") catch null) orelse blk: {
        const home = std.process.getEnvVarOwned(a, "HOME") catch return c.defaultEnvPath(a);
        break :blk std.fs.path.join(a, &.{ home, ".config" }) catch return c.defaultEnvPath(a);
    };
    const cand = std.fs.path.join(a, &.{ base, "rewind", "config" }) catch return c.defaultEnvPath(a);
    std.fs.cwd().access(cand, .{}) catch return c.defaultEnvPath(a);
    return cand;
}

// ── transport: TLS curl with a cookie jar ─────────────────────────────────

/// One HTTP call against `url`. `use_jar` reads + writes the session cookie
/// jar (so `login` persists the sid and later verbs replay it). `https` picks
/// --http2 (TLS) vs --http2-prior-knowledge (h2c); plaintext is only for a
/// self-hosted h2c front. Body streams over stdin.
fn httpCall(
    a: std.mem.Allocator,
    cfg: *const Cfg,
    method: []const u8,
    url: []const u8,
    headers: []const c.Header,
    body: ?[]const u8,
    use_jar: bool,
    timeout_s: u32,
) c.Resp {
    var args = std.ArrayList([]const u8){};
    const push = struct {
        fn p(l: *std.ArrayList([]const u8), al: std.mem.Allocator, s: []const u8) void {
            l.append(al, s) catch c.oom();
        }
    }.p;
    push(&args, a, "curl");
    push(&args, a, "-sS");
    push(&args, a, "--max-time");
    push(&args, a, std.fmt.allocPrint(a, "{d}", .{timeout_s}) catch c.oom());
    push(&args, a, "-w");
    push(&args, a, "\n%{http_code}");
    if (std.mem.startsWith(u8, url, "https://")) {
        push(&args, a, "--http2");
    } else {
        push(&args, a, "--http2-prior-knowledge");
    }
    if (cfg.cacert) |ca| {
        push(&args, a, "--cacert");
        push(&args, a, ca);
    }
    for (cfg.resolves) |r| {
        push(&args, a, "--resolve");
        push(&args, a, r);
    }
    if (use_jar) {
        if (cfg.root_token) |tok| {
            // Headless auth: the operator root token as a Bearer, in place of
            // the interactive OIDC cookie (REWIND_ROOT_TOKEN).
            push(&args, a, "-H");
            push(&args, a, std.fmt.allocPrint(a, "Authorization: Bearer {s}", .{tok}) catch c.oom());
        } else {
            push(&args, a, "--cookie");
            push(&args, a, cfg.session_file);
            push(&args, a, "--cookie-jar");
            push(&args, a, cfg.session_file);
        }
    }
    push(&args, a, "-X");
    push(&args, a, method);
    push(&args, a, url);
    for (headers) |h| {
        push(&args, a, "-H");
        push(&args, a, std.fmt.allocPrint(a, "{s}: {s}", .{ h.name, h.value }) catch c.oom());
    }
    if (body != null) {
        push(&args, a, "--data-binary");
        push(&args, a, "@-");
    }
    return c.run(a, args.items, body);
}

const FORM = c.Header{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" };
const JSON_CT = c.Header{ .name = "Content-Type", .value = "application/json" };

// ── verbs ─────────────────────────────────────────────────────────────────

/// `rewind login` — device grant → approve → token → exchange → session.
fn cmdLogin(a: std.mem.Allocator, cfg: *const Cfg) void {
    // 1. Ask the IdP for a device_code + user_code.
    const da_body = std.fmt.allocPrint(a, "client_id={s}&scope=openid", .{cfg.client_id}) catch c.oom();
    const da_url = std.fmt.allocPrint(a, "{s}/device_authorization", .{cfg.idp_url}) catch c.oom();
    const da = httpCall(a, cfg, "POST", da_url, &.{FORM}, da_body, false, 30);
    if (da.code != 200) c.fatal("device_authorization failed: {d} {s}", .{ da.code, c.trunc(da.body) });
    const device_code = c.extractField(a, da.body, "device_code") orelse
        c.fatal("device_authorization: no device_code: {s}", .{c.trunc(da.body)});
    const user_code = c.extractField(a, da.body, "user_code") orelse "?";
    const verify_uri = c.extractField(a, da.body, "verification_uri") orelse cfg.idp_url;
    var interval_s: u32 = 5;
    if (c.extractField(a, da.body, "interval")) |iv| {
        interval_s = std.fmt.parseInt(u32, iv, 10) catch 5;
    }

    std.debug.print(
        \\
        \\To finish signing in, visit:
        \\    {s}
        \\and enter the code:   {s}
        \\
        \\Waiting for approval…
        \\
    , .{ verify_uri, user_code });

    // 2. Poll /token until approved (or denied/expired).
    const tok_url = std.fmt.allocPrint(a, "{s}/token", .{cfg.idp_url}) catch c.oom();
    const tok_body = std.fmt.allocPrint(a, "grant_type={s}&device_code={s}&client_id={s}", .{
        DEVICE_GRANT, device_code, cfg.client_id,
    }) catch c.oom();
    var id_token: ?[]const u8 = null;
    var waited: u32 = 0;
    const max_wait: u32 = 600;
    while (waited < max_wait) {
        const r = httpCall(a, cfg, "POST", tok_url, &.{FORM}, tok_body, false, 30);
        if (r.code == 200) {
            id_token = c.extractField(a, r.body, "id_token") orelse
                c.fatal("token: 200 but no id_token: {s}", .{c.trunc(r.body)});
            break;
        }
        const err = c.extractField(a, r.body, "error") orelse "";
        if (std.mem.eql(u8, err, "authorization_pending")) {
            // keep waiting
        } else if (std.mem.eql(u8, err, "slow_down")) {
            interval_s += 5;
        } else if (std.mem.eql(u8, err, "access_denied")) {
            c.fatal("login denied at the confirm page", .{});
        } else if (std.mem.eql(u8, err, "expired_token")) {
            c.fatal("the code expired — run `rewind login` again", .{});
        } else {
            c.fatal("token poll failed: {d} {s}", .{ r.code, c.trunc(r.body) });
        }
        std.Thread.sleep(@as(u64, interval_s) * std.time.ns_per_s);
        waited += interval_s;
    }
    const idt = id_token orelse c.fatal("login timed out waiting for approval", .{});

    // 3. Exchange the id_token for a dashboard RP session (cookie → jar).
    const ex_url = std.fmt.allocPrint(a, "{s}/v1/cli/exchange", .{cfg.admin_url}) catch c.oom();
    var ex_body = std.ArrayList(u8){};
    ex_body.appendSlice(a, "{\"id_token\":") catch c.oom();
    c.writeJsonString(&ex_body, a, idt);
    ex_body.append(a, '}') catch c.oom();
    const ex = httpCall(a, cfg, "POST", ex_url, &.{JSON_CT}, ex_body.items, true, 30);
    if (ex.code != 200 and ex.code != 202) {
        c.fatal("exchange failed: {d} {s}", .{ ex.code, c.trunc(ex.body) });
    }

    // 4. Poll /_rp/poll until the (async JWKS) verify writes the session.
    const poll_url = std.fmt.allocPrint(a, "{s}/_rp/poll", .{cfg.admin_url}) catch c.oom();
    var tries: u32 = 0;
    while (tries < 60) : (tries += 1) {
        const r = httpCall(a, cfg, "GET", poll_url, &.{}, null, true, 15);
        if (r.code == 200 and std.mem.indexOf(u8, r.body, "\"authed\":true") != null) {
            std.debug.print("signed in — session stored at {s}\n", .{cfg.session_file});
            return;
        }
        std.Thread.sleep(250 * std.time.ns_per_ms);
    }
    c.fatal("exchange accepted but the session never finalized (JWKS verify)", .{});
}

/// `rewind status` — whoami over the stored session.
fn cmdStatus(a: std.mem.Allocator, cfg: *const Cfg) void {
    const url = std.fmt.allocPrint(a, "{s}/v1/session", .{cfg.admin_url}) catch c.oom();
    const r = httpCall(a, cfg, "GET", url, &.{}, null, true, 15);
    if (r.code == 401) c.fatal("not signed in — run `rewind login`", .{});
    if (r.code != 200) c.fatal("status failed: {d} {s}", .{ r.code, c.trunc(r.body) });
    std.debug.print("{s}\n", .{r.body});
}

/// One deploy sub-request over the session cookie, retrying on a not-leader
/// 421/503 (the front may route to a follower). Returns the 200 Resp or fatals.
fn deployStep(a: std.mem.Allocator, cfg: *const Cfg, sub: []const u8, body: []const u8, label: []const u8) c.Resp {
    const url = std.fmt.allocPrint(a, "{s}/v1/deploy/{s}", .{ cfg.admin_url, sub }) catch c.oom();
    var attempt: usize = 0;
    while (attempt < 6) : (attempt += 1) {
        const r = httpCall(a, cfg, "POST", url, &.{JSON_CT}, body, true, 120);
        if (r.code == 200) return r;
        if (r.code == 401) c.fatal("not signed in — run `rewind login`", .{});
        if (r.code == 403) c.fatal("you don't own this instance", .{});
        if (r.code != 421 and r.code != 503) c.fatal("deploy {s} failed: {d} {s}", .{ label, r.code, c.trunc(r.body) });
        std.Thread.sleep(2 * std.time.ns_per_s);
    }
    c.fatal("deploy {s}: no leader after retries", .{label});
}

/// PUT a static's raw bytes to /v1/upload (streamed to S3) over the session
/// cookie, retrying on a not-leader 421/503.
fn uploadStep(a: std.mem.Allocator, cfg: *const Cfg, upath: []const u8, body: []const u8, label: []const u8) c.Resp {
    const url = std.fmt.allocPrint(a, "{s}{s}", .{ cfg.admin_url, upath }) catch c.oom();
    var attempt: usize = 0;
    while (attempt < 6) : (attempt += 1) {
        const r = httpCall(a, cfg, "PUT", url, &.{}, body, true, 180);
        if (r.code == 200) return r;
        if (r.code == 401) c.fatal("not signed in — run `rewind login`", .{});
        if (r.code == 403) c.fatal("you don't own this instance", .{});
        if (r.code != 421 and r.code != 503) c.fatal("upload {s} failed: {d} {s}", .{ label, r.code, c.trunc(r.body) });
        std.Thread.sleep(2 * std.time.ns_per_s);
    }
    c.fatal("upload {s}: no leader after retries", .{label});
}

/// `rewind deploy <tenant> <bundle> [--release]` — per-file workspace deploy.
/// A bundle whose `manifest.json` declares `dependencies` resolves them
/// against the `@rewind` registry and stages the resolved package graph
/// (P-CLI, rove#122); a package-free bundle takes the plain path.
/// Auth-requiring verbs (deploy/release/rollback/…) need EITHER a root token
/// (headless / operator) or an interactive login session. With neither, the
/// transport silently sends an empty cookie jar and the server bounces a bare
/// 401 → the misleading "not signed in — run rewind login", even when the real
/// cause is a config that never loaded (classically: `--env` placed AFTER the
/// command, where it is silently ignored — it is a GLOBAL flag). Fail here,
/// up front, naming both causes, instead of after a confusing round-trip.
fn requireAuth(cfg: *const Cfg) void {
    if (cfg.root_token != null) return;
    if (std.fs.accessAbsolute(cfg.session_file, .{})) |_| return else |_| {}
    c.fatal(
        \\no credentials — this command needs a root token or a login session, and neither is set.
        \\  • operators: put REWIND_ROOT_TOKEN in a config file and pass it as a GLOBAL flag BEFORE the command:
        \\      rewind --env <file> deploy <tenant> <bundle>
        \\    (a `--env` placed AFTER the command is silently ignored — it is global, not per-command.)
        \\  • interactive: run `rewind login` first (session file: {s}).
    , .{cfg.session_file});
}

fn cmdDeploy(a: std.mem.Allocator, cfg: *const Cfg, tenant: []const u8, bundle: []const u8, release: bool) void {
    requireAuth(cfg);
    const b = c.classify(a, bundle);
    if (b.skipped.len != 0) {
        std.debug.print("  ! skipping (non-deployable): ", .{});
        for (b.skipped, 0..) |s, i| std.debug.print("{s}{s}", .{ if (i != 0) ", " else "", s });
        std.debug.print("\n", .{});
    }
    if (b.handlers.len == 0 and b.statics.len == 0) c.fatal("bundle {s} has nothing to publish", .{bundle});
    std.debug.print("bundle: {d} handler(s), {d} static(s)\n", .{ b.handlers.len, b.statics.len });

    // Package graph: the bundle's declared `dependencies`, plus the auto-pin
    // of undeclared @rewind/* imports the handlers actually use.
    const declared = readBundleDependencies(a, bundle);
    const deps = augmentDependencies(a, declared, b.handlers);

    _ = deployStep(a, cfg, "reset", c.tenantBody(a, tenant), "reset");

    // With packages: resolve → stage every package file (stage-only, order
    // free) → cut carries the lockfile resolution; the deploy app compiles
    // each package as a batch (dependency-ordered) and links the handlers
    // against the pinned graph, all server-side at cut.
    var cut_body: []const u8 = c.tenantBody(a, tenant);
    if (deps.len != 0) {
        var rr = registryResolve(a, cfg, deps);
        packages.topoSort(&rr.res) catch c.fatal("resolved packages form a dependency cycle", .{});
        stagePackages(a, cfg, tenant, &rr.res);
        const lock = packages.emitResolution(a, &rr.res) catch c.oom();
        cut_body = cutBody(a, tenant, lock);
        writeLockfile(bundle, rr.body);
        std.debug.print("resolved {d} package(s) against the registry\n", .{rr.res.packages.len});
    }

    for (b.handlers) |h| {
        _ = deployStep(a, cfg, "file", c.fileBodyHandler(a, tenant, h), h.path);
    }
    for (b.statics) |s| _ = uploadStep(a, cfg, c.uploadPath(a, tenant, s), s.bytes, s.path);
    const cut = deployStep(a, cfg, "cut", cut_body, "cut");
    const dep_id = c.extractDepId(a, cut.body) orelse c.fatal("cut: 200 but no dep_id: {s}", .{cut.body});
    std.debug.print("deployment staged: {s} ({d} file(s)) — NOT released\n", .{ dep_id, b.handlers.len + b.statics.len });
    if (release) cmdRelease(a, cfg, tenant, dep_id);
}

/// Read the bundle's `manifest.json` `dependencies` map (absent file → none).
fn readBundleDependencies(a: std.mem.Allocator, bundle: []const u8) []const packages.Dependency {
    const path = std.fs.path.join(a, &.{ bundle, "manifest.json" }) catch c.oom();
    const bytes = std.fs.cwd().readFileAlloc(a, path, 1 << 20) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => c.fatal("read {s}: {s}", .{ path, @errorName(err) }),
    };
    return packages.readDependencies(a, bytes) catch |err|
        c.fatal("manifest.json dependencies: {s}", .{@errorName(err)});
}

/// The asymmetric auto-pin: scan handler sources for `@scope/pkg` imports and
/// fold undeclared ones into `declared`. An undeclared `@rewind/*` import is
/// auto-added (range `"*"` — resolved to latest; the lockfile then pins the
/// exact version); an undeclared THIRD-PARTY import is fatal (it must be
/// declared in manifest.json). Declared specs pass through untouched.
fn augmentDependencies(a: std.mem.Allocator, declared: []const packages.Dependency, handlers: []const c.Handler) []const packages.Dependency {
    var out = std.ArrayList(packages.Dependency){};
    out.appendSlice(a, declared) catch c.oom();
    var have = std.StringHashMap(void).init(a);
    for (declared) |d| have.put(d.spec, {}) catch c.oom();
    for (handlers) |h| {
        const specs = packages.extractPackageImports(a, h.source) catch c.oom();
        for (specs) |spec| {
            if (have.contains(spec)) continue;
            have.put(spec, {}) catch c.oom();
            if (std.mem.startsWith(u8, spec, "@rewind/")) {
                out.append(a, .{ .spec = spec, .range = "*" }) catch c.oom();
                std.debug.print("  auto-pinned {s} (undeclared @rewind import)\n", .{spec});
            } else {
                c.fatal("handler {s} imports undeclared third-party package `{s}` — add it to manifest.json `dependencies`", .{ h.path, spec });
            }
        }
    }
    return out.items;
}

const ResolveResult = struct {
    res: packages.Resolution,
    body: []const u8, // the raw `/v1/resolve` response → the bundle's rewind.lock
};

/// Resolve the bundle's declared `dependencies` against the `@rewind` registry
/// (`POST {registry}/v1/resolve`, public — no session). Returns the parsed,
/// arena-owned resolution + the raw body (for the lockfile). Fatals on a
/// missing registry URL or an unresolvable/bad response.
fn registryResolve(a: std.mem.Allocator, cfg: *const Cfg, deps: []const packages.Dependency) ResolveResult {
    const base = cfg.registry_url orelse c.fatal(
        "this bundle declares `dependencies` but REWIND_REGISTRY_URL is unset — point it at your @rewind registry origin",
        .{},
    );
    const req = packages.buildResolveRequest(a, deps, &.{}) catch c.oom();
    const url = std.fmt.allocPrint(a, "{s}/v1/resolve", .{base}) catch c.oom();
    const r = httpCall(a, cfg, "POST", url, &.{JSON_CT}, req, false, 60);
    if (r.code == 422) c.fatal("registry could not resolve dependencies: {s}", .{c.trunc(r.body)});
    if (r.code != 200) c.fatal("registry resolve failed: {d} {s}", .{ r.code, c.trunc(r.body) });
    const res = packages.parseResolveResponse(a, r.body) catch |err| switch (err) {
        error.Unresolved => c.fatal("registry could not resolve dependencies: {s}", .{c.trunc(r.body)}),
        else => c.fatal("registry resolve: bad response ({s}): {s}", .{ @errorName(err), c.trunc(r.body) }),
    };
    return .{ .res = res, .body = r.body };
}

/// Fetch a package source blob by content hash (`GET {registry}/v1/blobs/…`,
/// public). Fatals on non-200.
fn registryBlob(a: std.mem.Allocator, cfg: *const Cfg, hash: []const u8) []const u8 {
    const base = cfg.registry_url.?; // checked in registryResolve
    const url = std.fmt.allocPrint(a, "{s}/v1/blobs/{s}", .{ base, hash }) catch c.oom();
    const r = httpCall(a, cfg, "GET", url, &.{}, null, false, 60);
    if (r.code != 200) c.fatal("registry blob {s}: {d} {s}", .{ hash, r.code, c.trunc(r.body) });
    return r.body;
}

/// Stage every resolved package's files: fetch each source from the
/// registry, POST `/v1/deploy/pkgfile` (stage-only — no compile, no
/// resolution: the deploy app batch-compiles each package at cut, so
/// upload order carries no meaning). The response's `source_hex` is the
/// server-authoritative content address; the registry's `source_hash` is
/// only the blob-lookup key (nothing verifies they coincide today — that
/// is #205's merkle identity work).
fn stagePackages(a: std.mem.Allocator, cfg: *const Cfg, tenant: []const u8, res: *const packages.Resolution) void {
    for (res.packages) |p| {
        for (p.files) |f| {
            const source = registryBlob(a, cfg, f.source_hash);
            const body = pkgfileBody(a, tenant, p.pkg_hash, f.path, source);
            const r = deployStep(a, cfg, "pkgfile", body, f.path);
            _ = c.extractField(a, r.body, "source_hex") orelse c.fatal("pkgfile {s}: no source_hex: {s}", .{ f.path, c.trunc(r.body) });
        }
    }
}

/// `{"tenant","pkg_hash","path","source","resolution":<raw json>}` for
/// `/v1/deploy/pkgfile`.
/// `{"tenant","pkg_hash","path","source"}` for `/v1/deploy/pkgfile`
/// (stage-only; the package compiles as a batch at cut).
fn pkgfileBody(a: std.mem.Allocator, tenant: []const u8, pkg_hash: []const u8, path: []const u8, source: []const u8) []const u8 {
    var out = std.ArrayList(u8){};
    out.appendSlice(a, "{\"tenant\":") catch c.oom();
    c.writeJsonString(&out, a, tenant);
    out.appendSlice(a, ",\"pkg_hash\":") catch c.oom();
    c.writeJsonString(&out, a, pkg_hash);
    out.appendSlice(a, ",\"path\":") catch c.oom();
    c.writeJsonString(&out, a, path);
    out.appendSlice(a, ",\"source\":") catch c.oom();
    c.writeJsonString(&out, a, source);
    out.append(a, '}') catch c.oom();
    return out.items;
}

/// `{"tenant","resolution":<raw json>}` for `/v1/deploy/cut` (the files-less
/// lockfile skeleton; the deploy app joins staged rows).
fn cutBody(a: std.mem.Allocator, tenant: []const u8, resolution: []const u8) []const u8 {
    var out = std.ArrayList(u8){};
    out.appendSlice(a, "{\"tenant\":") catch c.oom();
    c.writeJsonString(&out, a, tenant);
    out.appendSlice(a, ",\"resolution\":") catch c.oom();
    out.appendSlice(a, resolution) catch c.oom();
    out.append(a, '}') catch c.oom();
    return out.items;
}

/// Persist the registry's resolution verbatim as the bundle's `rewind.lock`
/// (the hash-locked graph, for the record / future reuse). Best-effort — a
/// write failure warns but doesn't fail the deploy.
fn writeLockfile(bundle: []const u8, body: []const u8) void {
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/rewind.lock", .{bundle}) catch return;
    const f = std.fs.cwd().createFile(path, .{}) catch |err| {
        std.debug.print("  ! could not write {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };
    defer f.close();
    f.writeAll(body) catch {};
}

/// `rewind release <tenant> <dep_id_hex>` — flip the live pointer.
///
/// Two auth-shaped paths:
///   - Root token (operator/headless): worker-native `POST /_system/release`
///     (root-bearer-gated, `src/js/worker_system.zig`; the front forwards
///     `/_system/*` transparently). The admin app's release route can't serve
///     an operator: its M2M path list is exact-match (this path is dynamic)
///     and `publishRelease` requires `auth.sub`, so a root bearer 401s there.
///   - Session (customer): the admin app's ownership-gated
///     `POST /v1/instances/{id}/release`.
fn cmdRelease(a: std.mem.Allocator, cfg: *const Cfg, tenant: []const u8, dep_id: []const u8) void {
    // dep_id rides the wire as a HEX STRING, not a JSON number: dep_ids are
    // sha256-derived u64 (> 2^53), so a JSON number would lose precision at
    // JSON.parse / JS_ToFloat64 and release the wrong (rounded) manifest.
    const dep_num = std.fmt.parseInt(u64, dep_id, 16) catch c.fatal("bad dep_id {s} (want hex)", .{dep_id});

    if (cfg.root_token != null) {
        // `/_system/release` parses `dep_id` natively as a u64 (no JS f64
        // round-trip), so the JSON NUMBER is the correct wire form here.
        // A follower 421s (the release proposes through the tenant's raft
        // group) and a settling group 503s — retry like deployStep.
        const body = std.fmt.allocPrint(
            a,
            "{{\"tenant_id\":\"{s}\",\"dep_id\":{d}}}",
            .{ tenant, dep_num },
        ) catch c.oom();
        const url = std.fmt.allocPrint(a, "{s}/_system/release", .{cfg.admin_url}) catch c.oom();
        var attempt: usize = 0;
        while (attempt < 6) : (attempt += 1) {
            const r = httpCall(a, cfg, "POST", url, &.{JSON_CT}, body, true, 30);
            if (r.code == 204) {
                std.debug.print("released {s} @ {s}\n", .{ tenant, dep_id });
                return;
            }
            if (r.code == 401) c.fatal("root token rejected by /_system/release (token drift?)", .{});
            if (r.code == 404) c.fatal("release failed: unknown tenant {s}", .{tenant});
            if (r.code != 421 and r.code != 503) c.fatal("release failed: {d} {s}", .{ r.code, c.trunc(r.body) });
            std.Thread.sleep(2 * std.time.ns_per_s);
        }
        c.fatal("release {s}: no leader after retries", .{tenant});
    }
    // REST route: POST /v1/instances/{id}/release {"dep_id":"<hex>"} (admin app's
    // ROUTES table). Keep dep_id a hex string so it never round-trips through an
    // f64 — a JSON number lands in publishRelease's lossy number branch → 400
    // "must be a positive integer".
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"dep_id\":") catch c.oom();
    c.writeJsonString(&body, a, dep_id);
    body.append(a, '}') catch c.oom();
    const url = std.fmt.allocPrint(a, "{s}/v1/instances/{s}/release", .{ cfg.admin_url, tenant }) catch c.oom();
    const r = httpCall(a, cfg, "POST", url, &.{JSON_CT}, body.items, true, 30);
    if (r.code == 401) c.fatal("not signed in — run `rewind login`", .{});
    if (r.code == 403) c.fatal("you don't own {s} (system tenants are operator-only — use rewind-ops)", .{tenant});
    if (r.code != 202) c.fatal("release failed: {d} {s}", .{ r.code, c.trunc(r.body) });
    std.debug.print("released {s} @ {s}\n", .{ tenant, dep_id });
}

// ── CP / operator verbs (over the session cookie) ──────────────────────────
//
// These hit the `__admin__` dashboard's CP chokepoint (`/v1/cp/*`), which is
// is_root-gated: the worker attaches the move-secret at the internal door, so
// the CLI carries NO platform secret — only the operator's OIDC session. Body
// shapes mirror the CP `/_control/*` routes (see `src/cli/ops.zig`).

/// One CP control op → `{admin}/v1/cp/{sub}`, retrying on a not-leader
/// 421/503 (or a 502 door-transient while the CP leader settles). Returns the
/// final Resp; the caller interprets the status (e.g. provision treats 409 as
/// idempotent-OK). Fatals on auth failures. Relies on the admin app's
/// `onFetchResult` relaying the real upstream status.
fn cpOp(a: std.mem.Allocator, cfg: *const Cfg, sub: []const u8, body: []const u8, timeout_s: u32) c.Resp {
    const url = std.fmt.allocPrint(a, "{s}/v1/cp/{s}", .{ cfg.admin_url, sub }) catch c.oom();
    var attempt: usize = 0;
    while (attempt < 6) : (attempt += 1) {
        const r = httpCall(a, cfg, "POST", url, &.{JSON_CT}, body, true, timeout_s);
        if (r.code == 401) c.fatal("not signed in — run `rewind login`", .{});
        if (r.code == 403) c.fatal("operator-only — `rewind {s}` needs an operator (is_root) session", .{sub});
        if (r.code != 421 and r.code != 503 and r.code != 502) return r;
        std.Thread.sleep(2 * std.time.ns_per_s);
    }
    c.fatal("cp {s}: no CP leader after retries", .{sub});
}

/// `rewind provision <tenant> [--cluster C] [--host H]` — create+place a tenant.
fn cmdProvision(a: std.mem.Allocator, cfg: *const Cfg, tenant: []const u8, cluster: []const u8, host: ?[]const u8) void {
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"tenant\":") catch c.oom();
    c.writeJsonString(&body, a, tenant);
    body.appendSlice(a, ",\"cluster\":") catch c.oom();
    c.writeJsonString(&body, a, cluster);
    if (host) |h| {
        body.appendSlice(a, ",\"host\":") catch c.oom();
        c.writeJsonString(&body, a, h);
    }
    body.append(a, '}') catch c.oom();
    const r = cpOp(a, cfg, "provision", body.items, 60);
    switch (r.code) {
        200, 204 => std.debug.print("provisioned {s} on {s}{s}\n", .{ tenant, cluster, if (host) |h| std.fmt.allocPrint(a, " (host {s})", .{h}) catch "" else "" }),
        409 => std.debug.print("{s} already placed (ok) — use `rewind move` to relocate\n", .{tenant}),
        else => c.fatal("provision {s}: {d} {s}", .{ tenant, r.code, c.trunc(r.body) }),
    }
}

/// `rewind host add <host> <tenant>` — map a domain → tenant (CP index + alias).
fn cmdHostAdd(a: std.mem.Allocator, cfg: *const Cfg, host: []const u8, tenant: []const u8) void {
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"host\":") catch c.oom();
    c.writeJsonString(&body, a, host);
    body.appendSlice(a, ",\"tenant\":") catch c.oom();
    c.writeJsonString(&body, a, tenant);
    body.append(a, '}') catch c.oom();
    const r = cpOp(a, cfg, "host", body.items, 30);
    if (r.code != 200 and r.code != 204) c.fatal("host map {s} → {s}: {d} {s}", .{ host, tenant, r.code, c.trunc(r.body) });
    std.debug.print("host {s} → {s}\n", .{ host, tenant });
}

/// `rewind plan set <tenant> <plan>` — set a tenant's opaque plan/limits blob.
fn cmdPlanSet(a: std.mem.Allocator, cfg: *const Cfg, tenant: []const u8, plan: []const u8) void {
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"tenant\":") catch c.oom();
    c.writeJsonString(&body, a, tenant);
    body.appendSlice(a, ",\"plan\":") catch c.oom();
    c.writeJsonString(&body, a, plan);
    body.append(a, '}') catch c.oom();
    const r = cpOp(a, cfg, "plan", body.items, 30);
    if (r.code != 200 and r.code != 204) c.fatal("plan {s}: {d} {s}", .{ tenant, r.code, c.trunc(r.body) });
    std.debug.print("plan set for {s}: {s}\n", .{ tenant, plan });
}

/// `rewind move <tenant> <cluster> [--live] --yes` — relocate a tenant. Guarded
/// by --yes (it repoints live routing). `--live` picks the zero-downtime move.
fn cmdMove(a: std.mem.Allocator, cfg: *const Cfg, tenant: []const u8, cluster: []const u8, live: bool, yes: bool) void {
    if (!yes) c.fatal("move repoints live routing for {s} → {s}. Re-run with --yes to confirm.", .{ tenant, cluster });
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"tenant\":") catch c.oom();
    c.writeJsonString(&body, a, tenant);
    body.appendSlice(a, ",\"cluster\":") catch c.oom();
    c.writeJsonString(&body, a, cluster);
    if (live) body.appendSlice(a, ",\"live\":true") catch c.oom();
    body.append(a, '}') catch c.oom();
    // A large tenant can take a while to stream, hence the long deadline.
    const r = cpOp(a, cfg, "move", body.items, 3600);
    if (r.code != 200 and r.code != 204) c.fatal("move {s} → {s}: {d} {s}", .{ tenant, cluster, r.code, c.trunc(r.body) });
    std.debug.print("moved {s} → {s}{s}\n", .{ tenant, cluster, if (live) " (live)" else "" });
}

/// `rewind route <host>` — resolve a host → tenant/cluster (CP read).
fn cmdRoute(a: std.mem.Allocator, cfg: *const Cfg, host: []const u8) void {
    const url = std.fmt.allocPrint(a, "{s}/v1/cp/route?host={s}", .{ cfg.admin_url, host }) catch c.oom();
    const r = httpCall(a, cfg, "GET", url, &.{}, null, true, 15);
    if (r.code == 401) c.fatal("not signed in — run `rewind login`", .{});
    if (r.code == 403) c.fatal("operator-only — this needs an operator (is_root) session", .{});
    if (r.code == 404) c.fatal("route: host {s} maps to no tenant / unplaced", .{host});
    if (r.code != 200) c.fatal("route {s}: {d} {s}", .{ host, r.code, c.trunc(r.body) });
    std.debug.print("{s}\n", .{r.body});
}

/// `rewind deployments <tenant>` — list the release history + the live pointer
/// (GET /v1/history/{tenant}). The `dep_id-hex` shown is what `rewind release` /
/// `rewind rollback` take.
fn cmdDeployments(a: std.mem.Allocator, cfg: *const Cfg, tenant: []const u8) void {
    const url = std.fmt.allocPrint(a, "{s}/v1/history/{s}", .{ cfg.admin_url, tenant }) catch c.oom();
    const r = httpCall(a, cfg, "GET", url, &.{}, null, true, 15);
    if (r.code == 401) c.fatal("not signed in — run `rewind login`", .{});
    if (r.code == 403) c.fatal("not your instance (or not an operator)", .{});
    if (r.code == 404) c.fatal("deployments: {s} not found", .{tenant});
    if (r.code != 200) c.fatal("deployments {s}: {d} {s}", .{ tenant, r.code, c.trunc(r.body) });

    const parsed = std.json.parseFromSlice(std.json.Value, a, r.body, .{}) catch {
        std.debug.print("{s}\n", .{r.body}); // never hide data if the shape drifts
        return;
    };
    const root = parsed.value;
    if (root != .object) {
        std.debug.print("{s}\n", .{r.body});
        return;
    }
    const cur_hex = if (root.object.get("current_hex")) |v| (if (v == .string) v.string else "—") else "—";
    std.debug.print("tenant: {s}   live: {s}\n", .{ tenant, cur_hex });
    const rels = root.object.get("releases");
    if (rels == null or rels.? != .array or rels.?.array.items.len == 0) {
        std.debug.print("  (no releases yet)\n", .{});
        return;
    }
    std.debug.print("releases (newest first) — dep_id-hex | dep | ts_ms | live\n", .{});
    for (rels.?.array.items) |it| {
        if (it != .object) continue;
        const dep_hex = if (it.object.get("dep_hex")) |v| (if (v == .string) v.string else "?") else "?";
        const dep_id: i64 = if (it.object.get("dep_id")) |v| (if (v == .integer) v.integer else 0) else 0;
        const ts: i64 = if (it.object.get("ts_ms")) |v| (if (v == .integer) v.integer else 0) else 0;
        const is_live = if (it.object.get("live")) |v| (v == .bool and v.bool) else false;
        std.debug.print("  {s}  {d}  {d}  {s}\n", .{ dep_hex, dep_id, ts, if (is_live) "← LIVE" else "" });
    }
}

// ── replay: pull a recorded request + re-execute it natively ─────

/// `rewind logs <tenant> [--limit N] [--after CURSOR]` — list recorded request
/// summaries (GET /v1/logs/{tenant}/list). Prints the log-server's JSON
/// verbatim (it is already the LLM-/operator-friendly artifact); the operator
/// picks a `request_id` for `rewind pull`.
fn cmdLogs(a: std.mem.Allocator, cfg: *const Cfg, tenant: []const u8, limit: ?[]const u8, after: ?[]const u8) void {
    var url = std.ArrayList(u8){};
    url.appendSlice(a, std.fmt.allocPrint(a, "{s}/v1/logs/{s}/list", .{ cfg.admin_url, tenant }) catch c.oom()) catch c.oom();
    var sep: u8 = '?';
    if (limit) |l| {
        url.append(a, sep) catch c.oom();
        sep = '&';
        url.appendSlice(a, std.fmt.allocPrint(a, "limit={s}", .{l}) catch c.oom()) catch c.oom();
    }
    if (after) |cur| {
        url.append(a, sep) catch c.oom();
        url.appendSlice(a, std.fmt.allocPrint(a, "after={s}", .{cur}) catch c.oom()) catch c.oom();
    }
    const r = httpCall(a, cfg, "GET", url.items, &.{}, null, true, 30);
    if (r.code == 401) c.fatal("not signed in — run `rewind login`", .{});
    if (r.code == 403) c.fatal("operator-only — log read needs an operator (is_root) session", .{});
    if (r.code == 404) c.fatal("logs: {s} not found", .{tenant});
    if (r.code != 200) c.fatal("logs {s}: {d} {s}", .{ tenant, r.code, c.trunc(r.body) });
    std.debug.print("{s}\n", .{r.body});
}

/// `rewind pull <tenant> <req_id> [-o FILE]` — fetch the recorded request
/// (record + inline tapes via /v1/logs/{tenant}/show/{id}) and its deployment's
/// handler sources (/v1/sources/{tenant}/{dep_hex}), and write a self-contained
/// fixture JSON that `rewind replay` re-executes offline forever.
fn cmdPull(a: std.mem.Allocator, cfg: *const Cfg, tenant: []const u8, req_id: []const u8, out_file: ?[]const u8) void {
    // 1. the record (with inline tapes).
    const surl = std.fmt.allocPrint(a, "{s}/v1/logs/{s}/show/{s}", .{ cfg.admin_url, tenant, req_id }) catch c.oom();
    const sr = httpCall(a, cfg, "GET", surl, &.{}, null, true, 30);
    if (sr.code == 401) c.fatal("not signed in — run `rewind login`", .{});
    if (sr.code == 403) c.fatal("operator-only — log read needs an operator (is_root) session", .{});
    if (sr.code == 404) c.fatal("pull: request {s} not found for {s}", .{ req_id, tenant });
    if (sr.code != 200) c.fatal("pull show {s}: {d} {s}", .{ req_id, sr.code, c.trunc(sr.body) });

    const rec_p = std.json.parseFromSlice(std.json.Value, a, sr.body, .{}) catch
        c.fatal("pull: record JSON did not parse", .{});
    if (rec_p.value != .object) c.fatal("pull: record is not an object", .{});
    // `/show` wraps the record as `{"record": {...}}` (standalone.zig); unwrap
    // to the inner object (tolerate a bare record too).
    const rec_val: std.json.Value = blk: {
        if (rec_p.value.object.get("record")) |inner| {
            if (inner == .object) break :blk inner;
        }
        break :blk rec_p.value;
    };
    const rec = rec_val.object;
    const dep_id = jStr(rec_val, "deployment_id") orelse
        c.fatal("pull: record has no deployment_id", .{});
    const dep_hex = if (std.mem.startsWith(u8, dep_id, "dep_")) dep_id["dep_".len..] else dep_id;

    // 2. the deployment's handler sources.
    const srcurl = std.fmt.allocPrint(a, "{s}/v1/sources/{s}/{s}", .{ cfg.admin_url, tenant, dep_hex }) catch c.oom();
    const srr = httpCall(a, cfg, "GET", srcurl, &.{}, null, true, 60);
    if (srr.code != 200) c.fatal("pull sources {s}: {d} {s}", .{ dep_hex, srr.code, c.trunc(srr.body) });
    const src_p = std.json.parseFromSlice(std.json.Value, a, srr.body, .{}) catch
        c.fatal("pull: sources JSON did not parse", .{});
    const entries = if (src_p.value == .object) src_p.value.object.get("entries") else null;

    // 3. compose the fixture.
    const tapes_v = rec.get("tapes");
    const tapes: ?std.json.ObjectMap = if (tapes_v) |t| (if (t == .object) t.object else null) else null;

    var buf = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &buf);
    const w = &aw.writer;
    w.writeAll("{\"request_id\":") catch c.oom();
    emitStr(w, jStr(rec_val, "request_id") orelse req_id);
    w.writeAll(",\"tenant\":") catch c.oom();
    emitStr(w, tenant);
    w.writeAll(",\"deployment_id\":") catch c.oom();
    emitStr(w, dep_id);
    w.writeAll(",\"activation\":") catch c.oom();
    emitStr(w, jStr(rec_val, "activation") orelse "inbound");
    w.writeAll(",\"entry\":\"index.mjs\",\"request\":{\"method\":") catch c.oom();
    emitStr(w, jStr(rec_val, "method") orelse "GET");
    w.writeAll(",\"path\":") catch c.oom();
    emitStr(w, jStr(rec_val, "path") orelse "/");
    w.writeAll(",\"host\":") catch c.oom();
    emitStr(w, jStr(rec_val, "host") orelse "");
    w.writeAll("},\"recorded\":{\"status\":") catch c.oom();
    w.print("{d}", .{jInt(rec_val, "status") orelse 0}) catch c.oom();
    w.writeAll(",\"console\":") catch c.oom();
    emitStr(w, jStr(rec_val, "console") orelse "");
    w.writeAll(",\"exception\":") catch c.oom();
    emitStr(w, jStr(rec_val, "exception") orelse "");
    w.writeAll("}") catch c.oom();

    // tape scalars + channels (the record nests them under `tapes`).
    if (tapes) |t| {
        if (jStrM(t, "seed")) |s| {
            w.writeAll(",\"seed\":") catch c.oom();
            emitStr(w, s);
        }
        if (jStrM(t, "timestamp_ns")) |s| {
            w.writeAll(",\"timestamp_ns\":") catch c.oom();
            emitStr(w, s);
        }
        if (t.get("js_engine_version")) |jv| if (jv == .integer) {
            w.print(",\"js_engine_version\":{d}", .{jv.integer}) catch c.oom();
        };
        // The resolved export ({on} / onFetch*) — so an overridden callback
        // replays under its actual export, not the conventional one (G3).
        if (jStrM(t, "export")) |s| {
            w.writeAll(",\"export\":") catch c.oom();
            emitStr(w, s);
        }
        w.writeAll(",\"tapes\":{") catch c.oom();
        var first = true;
        // record-field → fixture-field remap; only emit present, non-null blobs.
        const map = [_][2][]const u8{
            .{ "kv_tape_b64", "kv_b64" },
            .{ "module_tree_b64", "module_b64" },
            .{ "request_reads_tape_b64", "request_reads_b64" },
            .{ "request_body_b64", "request_body_b64" },
            // Non-inbound activations: the fetch result + the threaded ctx
            // envelope + the activation Msg payload (a ws_message frame)
            // (replay-and-sim.md §4). Carried so a pulled callback fixture is
            // replayable, not just inbound.
            .{ "fetch_responses_tape_b64", "fetch_responses_b64" },
            .{ "trigger_payload_tape_b64", "trigger_payload_b64" },
            .{ "activation_bytes_b64", "activation_bytes_b64" },
        };
        for (map) |m| {
            if (jStrM(t, m[0])) |b64| {
                if (!first) w.writeByte(',') catch c.oom();
                first = false;
                emitStr(w, m[1]);
                w.writeByte(':') catch c.oom();
                emitStr(w, b64);
            }
        }
        w.writeAll("}") catch c.oom();
    }

    // sources: embed the door's entries array verbatim (root.run reads
    // path/kind/source). Absent ⇒ empty — replay then fails loud on entry.
    w.writeAll(",\"sources\":") catch c.oom();
    if (entries) |e| {
        std.json.Stringify.value(e, .{}, w) catch c.oom();
    } else {
        w.writeAll("[]") catch c.oom();
    }
    w.writeAll("}") catch c.oom();
    buf = aw.toArrayList();

    // Transcode the captured record (base64 tapes) into the ONE editable format
    // — a declarative `world.json` that `rewind replay` (fail) and `rewind sim`
    // (resolve) both consume. The wire/tape form never reaches a human.
    var world = std.ArrayList(u8){};
    replay.exportFixture(a, buf.items, &world) catch |e|
        c.fatal("pull: transcode to world failed: {s}", .{@errorName(e)});

    if (out_file) |path| {
        std.fs.cwd().writeFile(.{ .sub_path = path, .data = world.items }) catch |e|
            c.fatal("pull: write {s}: {s}", .{ path, @errorName(e) });
        std.debug.print("wrote world → {s}  ({s}, dep {s})\n", .{ path, req_id, dep_hex });
    } else {
        std.debug.print("{s}\n", .{world.items});
    }
}

/// `rewind replay <world.json> [--source-dir DIR] [-o FILE]`
/// — re-materialise a recorded request natively (links the arenajs replay
/// engine; no Node/WASM/network) and emit the LLM-JSON result. Replay and sim
/// are the SAME engine over the SAME format (the declarative world `pull`
/// writes). KV reads resolve by KEY (order-independent, closed world: a key not
/// in the map is not_found) with a write-through overlay, so re-execution is
/// faithful to the JS yet robust to benign reordering; `--source-dir` swaps in
/// working-tree source ("does my change still behave the same on the real
/// inputs?"). Faithfulness is the output-level `status_match` + the effect log.
fn cmdReplay(a: std.mem.Allocator, world_path: []const u8, source_dir: ?[]const u8, out_file: ?[]const u8, update: bool) void {
    const bytes = std.fs.cwd().readFileAlloc(a, world_path, 64 << 20) catch |e|
        c.fatal("replay: read {s}: {s}", .{ world_path, @errorName(e) });
    var out = std.ArrayList(u8){};
    replay.runWorld(a, bytes, source_dir, &out) catch |e| switch (e) {
        error.EntrySourceMissing => c.fatal("replay: the world has no entry source (index.mjs) — re-pull, or pass --source-dir", .{}),
        error.BadFixture => c.fatal("replay: world JSON is malformed", .{}),
        error.ArenaInit => c.fatal("replay: JS engine failed to initialise", .{}),
        else => c.fatal("replay: {s}", .{@errorName(e)}),
    };
    doOutput(a, "replay", world_path, out.items, out_file, update);
}

/// `rewind sim <world.json> [--source-dir DIR] [-o FILE]`
/// — run a DECLARATIVE world (an authored fixture, not a captured tape) through
/// the same engine. The world is a plain JSON document (request surface, a
/// key→value KV map, seed/now); reads resolve order-independently against a
/// **closed world** — a key not in the map is `not_found`. Same offline path as
/// `replay` — no dashboard / IdP / network.
fn cmdSim(a: std.mem.Allocator, world_path: []const u8, source_dir: ?[]const u8, out_file: ?[]const u8, update: bool) void {
    const bytes = std.fs.cwd().readFileAlloc(a, world_path, 64 << 20) catch |e|
        c.fatal("sim: read {s}: {s}", .{ world_path, @errorName(e) });
    var out = std.ArrayList(u8){};
    replay.runWorld(a, bytes, source_dir, &out) catch |e| switch (e) {
        error.EntrySourceMissing => c.fatal("sim: the world has no entry source ('{s}') — add it under \"sources\", or pass --source-dir", .{"index.mjs"}),
        error.BadFixture => c.fatal("sim: world JSON is malformed", .{}),
        error.ArenaInit => c.fatal("sim: JS engine failed to initialise", .{}),
        else => c.fatal("sim: {s}", .{@errorName(e)}),
    };
    doOutput(a, "sim", world_path, out.items, out_file, update);
}

/// Shared tail for `sim`/`replay`: `--update` snapshots the bundle's facets as
/// `expected` back into the world file (golden regen; no fail-exit). Otherwise
/// emit the bundle (stdout or -o) and exit non-zero on a failed `expected`.
fn doOutput(a: std.mem.Allocator, verb: []const u8, world_path: []const u8, bundle: []const u8, out_file: ?[]const u8, update: bool) void {
    if (update) {
        replay.updateExpected(a, world_path, bundle) catch |e|
            c.fatal("{s}: --update failed: {s}", .{ verb, @errorName(e) });
        std.debug.print("updated expected → {s}\n", .{world_path});
        return;
    }
    if (out_file) |path| {
        std.fs.cwd().writeFile(.{ .sub_path = path, .data = bundle }) catch |e|
            c.fatal("{s}: write {s}: {s}", .{ verb, path, @errorName(e) });
        std.debug.print("wrote {s} result → {s}\n", .{ verb, path });
    } else {
        const stdout = std.fs.File.stdout();
        stdout.writeAll(bundle) catch {};
        stdout.writeAll("\n") catch {};
    }
    // A failed `expected` assertion → non-zero exit (CI-usable).
    if (std.mem.indexOf(u8, bundle, "\"verify\":{\"pass\":false") != null) std.process.exit(1);
}

/// `rewind export-fixture <pulled-fixture.json> [-o world.json]` — transcode a
/// captured recording (a `rewind pull` fixture) into an editable, offline,
/// fail-loud declarative sim **world** that `rewind sim` reproduces. Offline.
/// Faithful for inbound + wake_batch + send_callback activations; warns on
/// the rest (the pulled fixture lacks the streamed fetch-result surface —
/// replay-and-sim.md §5).
fn cmdExportFixture(a: std.mem.Allocator, fixture_path: []const u8, out_file: ?[]const u8) void {
    const bytes = std.fs.cwd().readFileAlloc(a, fixture_path, 64 << 20) catch |e|
        c.fatal("export-fixture: read {s}: {s}", .{ fixture_path, @errorName(e) });
    const activation = replay.exportFixtureActivation(a, bytes);
    if (!replay.exportFixtureIsFaithful(activation)) {
        std.debug.print(
            "export-fixture: warning: activation '{s}' does not transcode faithfully — the pulled fixture carries no fetch-result surface for it, so the world will be incomplete (replay-and-sim.md §5 G1/G3)\n",
            .{activation},
        );
    }
    var out = std.ArrayList(u8){};
    replay.exportFixture(a, bytes, &out) catch |e| switch (e) {
        error.BadFixture => c.fatal("export-fixture: fixture JSON is malformed", .{}),
        else => c.fatal("export-fixture: {s}", .{@errorName(e)}),
    };
    if (out_file) |path| {
        std.fs.cwd().writeFile(.{ .sub_path = path, .data = out.items }) catch |e|
            c.fatal("export-fixture: write {s}: {s}", .{ path, @errorName(e) });
        std.debug.print("wrote world → {s}\n", .{path});
    } else {
        const stdout = std.fs.File.stdout();
        stdout.writeAll(out.items) catch {};
    }
}

/// `rewind test [dir] [--source-dir DIR] [--update]` — run every
/// `{dir}/_tests/*.mjs` through the JS saga test library (`rewind:test`),
/// offline. Each test body runs on a harness reactor and drives the sim engine
/// via `simulate()`; assertions stream back per file. Handler code a test
/// simulates resolves from `--source-dir` (default: `dir`) unless the scenario
/// declares its own `sourceDir`. `--update` rebaselines snapshots. Exits
/// non-zero if any assertion fails or a file aborts (CI-usable).
fn cmdTest(a: std.mem.Allocator, dir: []const u8, source_dir: ?[]const u8, update: bool) void {
    // Resolve the app's declared @rewind/* deps from the embedded first-party
    // set so handler package imports resolve offline (no per-scenario inlining).
    // Built once here; merged into every scenario's world by the harness.
    var fp_specs = std.ArrayList([]const u8){};
    for (readBundleDependencies(a, dir)) |d| {
        if (std.mem.startsWith(u8, d.spec, "@rewind/")) fp_specs.append(a, d.spec) catch c.oom();
    }
    var fp_storage: replay.FirstPartyGraph = undefined;
    const fp: ?*const replay.FirstPartyGraph = if (fp_specs.items.len == 0) null else blk: {
        fp_storage = replay.buildFirstParty(a, fp_specs.items) catch |e| switch (e) {
            error.UnknownFirstParty => c.fatal("test: manifest.json declares an @rewind/* dependency that is not a known first-party package", .{}),
            else => c.fatal("test: first-party resolve: {s}", .{@errorName(e)}),
        };
        break :blk &fp_storage;
    };

    const report = replay.runTests(a, dir, .{
        .update = update,
        // An explicit --source-dir overrides a world's inline sources; `dir` is
        // the fallback for worlds that declare neither sourceDir nor sources.
        .source_dir = source_dir,
        .base_dir = dir,
        .first_party = fp,
    }) catch |e| switch (e) {
        error.NoTestsDir => c.fatal("test: no _tests/ directory under '{s}'", .{dir}),
        error.ArenaInit => c.fatal("test: JS engine failed to initialise", .{}),
        else => c.fatal("test: {s}", .{@errorName(e)}),
    };

    if (report.files.len == 0) {
        std.debug.print("test: no _tests/*.mjs files under '{s}'\n", .{dir});
        return;
    }

    var total_pass: usize = 0;
    var total_fail: usize = 0;
    var files_failed: usize = 0;
    for (report.files) |f| {
        const p = f.passed();
        const fl = f.failed();
        total_pass += p;
        total_fail += fl;
        const file_ok = f.ok();
        if (!file_ok) files_failed += 1;
        std.debug.print("{s} {s}\n", .{ if (file_ok) "PASS" else "FAIL", f.path });
        for (f.asserts) |as_| {
            const name = jsonField(a, as_.json, "name") orelse "?";
            if (as_.pass) {
                std.debug.print("  ✓ {s}\n", .{name});
            } else {
                const detail = jsonField(a, as_.json, "detail") orelse "";
                std.debug.print("  ✗ {s}  {s}\n", .{ name, detail });
            }
        }
        if (!f.completed) std.debug.print(
            "  ⚠ file aborted before completion (uncaught error, rc={d}) — run it directly to see the throw\n",
            .{f.rc},
        );
    }

    std.debug.print(
        "\n{d} file(s): {d} passed, {d} failed ({d} file(s) with failures)\n",
        .{ report.files.len, total_pass, total_fail, files_failed },
    );
    if (!report.ok()) std.process.exit(1);
}

/// Pull one top-level field out of a small assertion JSON as its serialized
/// text (a string field comes back unquoted; objects/scalars as-is). Best-effort
/// for the human report — returns null when absent or on a parse error.
fn jsonField(a: std.mem.Allocator, json: []const u8, key: []const u8) ?[]const u8 {
    const p = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return null;
    if (p.value != .object) return null;
    const v = p.value.object.get(key) orelse return null;
    return switch (v) {
        .string => v.string,
        .null => null,
        else => std.json.Stringify.valueAlloc(a, v, .{}) catch null,
    };
}

fn emitStr(w: *std.Io.Writer, s: []const u8) void {
    std.json.Stringify.value(s, .{}, w) catch c.oom();
}
fn jStrM(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}
fn jInt(v: std.json.Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .integer) f.integer else null;
}

// ── manifest-driven publish ───────

fn jStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}
fn jBool(v: std.json.Value, key: []const u8, dflt: bool) bool {
    if (v != .object) return dflt;
    const f = v.object.get(key) orelse return dflt;
    return if (f == .bool) f.bool else dflt;
}
fn inList(list: [][]const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// `rewind publish [--apps-dir D] [--only ...] [--include-examples] [--no-release]`
/// — read `{apps-dir}/manifest.json` and drive provision + host-map + deploy +
/// release for each first-party tenant. The typed twin of
/// `scripts/ops/publish_firstparty.py`, over the session cookie (no operator secret).
fn cmdPublish(a: std.mem.Allocator, cfg: *const Cfg, apps_dir: []const u8, only: [][]const u8, include_examples: bool, no_release: bool) void {
    const mpath = std.fs.path.join(a, &.{ apps_dir, "manifest.json" }) catch c.oom();
    const bytes = std.fs.cwd().readFileAlloc(a, mpath, 4 << 20) catch |e|
        c.fatal("read {s}: {s}", .{ mpath, @errorName(e) });
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch |e|
        c.fatal("parse {s}: {s}", .{ mpath, @errorName(e) });
    const root = parsed.value;
    if (root != .object) c.fatal("manifest.json: top level is not an object", .{});

    var def_cluster: []const u8 = "prod";
    var def_release: bool = true;
    if (root.object.get("defaults")) |d| {
        if (jStr(d, "cluster")) |cstr| def_cluster = cstr;
        def_release = jBool(d, "release", true);
    }
    const tenants = root.object.get("tenants") orelse c.fatal("manifest.json: no `tenants` array", .{});
    if (tenants != .array) c.fatal("manifest.json: `tenants` is not an array", .{});

    var published: usize = 0;
    for (tenants.array.items) |t| {
        if (t != .object) continue;
        const id = jStr(t, "tenant") orelse {
            std.debug.print("· skipping a tenant entry with no `tenant` id\n", .{});
            continue;
        };
        const dir = jStr(t, "dir") orelse id;
        const kind = jStr(t, "kind") orelse "operator";
        const cluster = jStr(t, "cluster") orelse def_cluster;
        const do_provision = jBool(t, "provision", true);
        const do_release = jBool(t, "release", def_release);

        const selected = if (only.len != 0)
            inList(only, id)
        else
            (!std.mem.eql(u8, kind, "example") or include_examples);
        if (!selected) {
            std.debug.print("· skip {s} ({s})\n", .{ id, kind });
            continue;
        }

        var hosts = std.ArrayList([]const u8){};
        if (t.object.get("hosts")) |h| if (h == .array) {
            for (h.array.items) |hv| if (hv == .string) hosts.append(a, hv.string) catch c.oom();
        };

        const bundle = std.fs.path.join(a, &.{ apps_dir, dir }) catch c.oom();
        std.debug.print("\n▶ {s}  (dir {s}, cluster {s})\n", .{ id, dir, cluster });
        if (do_provision) cmdProvision(a, cfg, id, cluster, if (hosts.items.len > 0) hosts.items[0] else null);
        if (hosts.items.len > 1) for (hosts.items[1..]) |hh| cmdHostAdd(a, cfg, hh, id);
        cmdDeploy(a, cfg, id, bundle, do_release and !no_release);
        published += 1;
    }
    std.debug.print("\npublish complete — {d} tenant(s) processed\n", .{published});
}

const USAGE =
    \\rewind — the rewind.js customer CLI (OIDC session auth).
    \\
    \\Usage:
    \\  rewind [--env <file>] login
    \\  rewind [--env <file>] status
    \\  rewind [--env <file>] deploy <tenant> <bundle-dir> [--release]
    \\  rewind [--env <file>] release <tenant> <dep_id-hex>
    \\  rewind [--env <file>] rollback <tenant> <dep_id-hex>
    \\  rewind [--env <file>] deployments <tenant>
    \\  rewind [--env <file>] logs <tenant> [--limit N] [--after CURSOR]
    \\  rewind [--env <file>] pull <tenant> <req_id> [-o FILE]
    \\  rewind [--env <file>] replay <world.json> [--source-dir DIR] [--update] [-o FILE]
    \\  rewind sim <world.json> [--source-dir DIR] [--update] [-o FILE]
    \\  rewind test [dir] [--source-dir DIR] [--update]
    \\  rewind export-fixture <base64-record.json> [-o world.json]
    \\  rewind [--env <file>] publish [--apps-dir D] [--only t1,t2] [--include-examples] [--no-release]
    \\  rewind [--env <file>] provision <tenant> [--cluster C] [--host H]
    \\  rewind [--env <file>] host add <host> <tenant>
    \\  rewind [--env <file>] plan set <tenant> <plan>
    \\  rewind [--env <file>] move <tenant> <cluster> [--live] --yes
    \\  rewind [--env <file>] route <host>
    \\
    \\Operator verbs (provision/host/plan/move/route, and publish/deployments for
    \\any tenant) need an operator (is_root) session; deploy/release/rollback work
    \\for any tenant you own. No platform secret is ever held by the CLI — the
    \\worker attaches it at the internal door.
    \\
    \\Config — OS env first, then a file: --env <file>, else ~/.config/rewind/config
    \\(KEY=VALUE lines):
    \\  REWIND_ADMIN_URL   dashboard origin (e.g. https://app.example.com)
    \\  REWIND_IDP_URL     IdP origin (e.g. https://auth.example.com)
    \\  REWIND_CLIENT_ID   OAuth client id (default: admin-dashboard)
    \\  REWIND_SESSION     cookie-jar path (default: ~/.config/rewind/rewind.session)
    \\  REWIND_CACERT      curl --cacert (private CA)
    \\  REWIND_RESOLVE     curl --resolve entries, comma-separated
    \\
;

pub fn main() void {
    // Pin the process timezone to UTC before any JS reactor initializes, so the
    // sim's local-time Date methods (getHours / getTimezoneOffset / toString)
    // match production — prod servers run UTC. quickjs-ng's date impl goes
    // through libc `localtime_r`, which reads the `TZ` env; set it + `tzset()`
    // so handler time is UTC regardless of the developer's host TZ (issue #53).
    _ = setenv("TZ", "UTC", 1);
    tzset();

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const argv = std.process.argsAlloc(a) catch c.oom();
    var i: usize = 1;
    var env_path: ?[]const u8 = defaultConfigPath(a);
    // Optional leading --env <file>.
    if (i < argv.len and std.mem.eql(u8, argv[i], "--env")) {
        if (i + 1 >= argv.len) c.fatal("--env needs a path", .{});
        env_path = argv[i + 1];
        i += 2;
    }
    if (i >= argv.len) {
        std.debug.print("{s}", .{USAGE});
        std.process.exit(2);
    }
    const verb = argv[i];
    i += 1;

    if (std.mem.eql(u8, verb, "help") or std.mem.eql(u8, verb, "--help") or
        std.mem.eql(u8, verb, "-h"))
    {
        std.debug.print("{s}", .{USAGE});
        return;
    }
    if (std.mem.eql(u8, verb, "version") or std.mem.eql(u8, verb, "--version") or
        std.mem.eql(u8, verb, "-V"))
    {
        std.debug.print("rewind {s}\n", .{build_options.version});
        return;
    }
    const known = std.mem.eql(u8, verb, "login") or std.mem.eql(u8, verb, "status") or
        std.mem.eql(u8, verb, "deploy") or std.mem.eql(u8, verb, "release") or
        std.mem.eql(u8, verb, "rollback") or std.mem.eql(u8, verb, "deployments") or
        std.mem.eql(u8, verb, "publish") or std.mem.eql(u8, verb, "provision") or
        std.mem.eql(u8, verb, "host") or std.mem.eql(u8, verb, "plan") or
        std.mem.eql(u8, verb, "move") or std.mem.eql(u8, verb, "route") or
        std.mem.eql(u8, verb, "logs") or std.mem.eql(u8, verb, "pull") or
        std.mem.eql(u8, verb, "replay") or std.mem.eql(u8, verb, "sim") or
        std.mem.eql(u8, verb, "test") or std.mem.eql(u8, verb, "export-fixture");
    if (!known) {
        std.debug.print("rewind: unknown command '{s}'\n\n{s}", .{ verb, USAGE });
        std.process.exit(2);
    }

    const rest = argv[i..];

    // `replay` is fully offline (no dashboard / IdP) — handle it before
    // loadCfg so it never demands REWIND_ADMIN_URL / REWIND_IDP_URL.
    if (std.mem.eql(u8, verb, "replay")) {
        if (rest.len < 1) c.fatal("replay needs <fixture> [--source-dir DIR] [--update] [-o FILE]", .{});
        var source_dir: ?[]const u8 = null;
        var out_file: ?[]const u8 = null;
        var update = false;
        var j: usize = 1;
        while (j < rest.len) : (j += 1) {
            if (std.mem.eql(u8, rest[j], "--source-dir")) {
                if (j + 1 >= rest.len) c.fatal("--source-dir needs a path", .{});
                source_dir = rest[j + 1];
                j += 1;
            } else if (std.mem.eql(u8, rest[j], "--update")) {
                update = true;
            } else if (std.mem.eql(u8, rest[j], "-o")) {
                if (j + 1 >= rest.len) c.fatal("-o needs a path", .{});
                out_file = rest[j + 1];
                j += 1;
            } else c.fatal("replay: unknown option '{s}'", .{rest[j]});
        }
        cmdReplay(a, rest[0], source_dir, out_file, update);
        return;
    }

    // `sim` is offline too — a declarative world through the same engine.
    if (std.mem.eql(u8, verb, "sim")) {
        if (rest.len < 1) c.fatal("sim needs <world.json> [--source-dir DIR] [--update] [-o FILE]", .{});
        var source_dir: ?[]const u8 = null;
        var out_file: ?[]const u8 = null;
        var update = false;
        var j: usize = 1;
        while (j < rest.len) : (j += 1) {
            if (std.mem.eql(u8, rest[j], "--source-dir")) {
                if (j + 1 >= rest.len) c.fatal("--source-dir needs a path", .{});
                source_dir = rest[j + 1];
                j += 1;
            } else if (std.mem.eql(u8, rest[j], "--update")) {
                update = true;
            } else if (std.mem.eql(u8, rest[j], "-o")) {
                if (j + 1 >= rest.len) c.fatal("-o needs a path", .{});
                out_file = rest[j + 1];
                j += 1;
            } else c.fatal("sim: unknown option '{s}'", .{rest[j]});
        }
        cmdSim(a, rest[0], source_dir, out_file, update);
        return;
    }

    // `test` is offline — the JS saga test runner (harness + sim reactors).
    if (std.mem.eql(u8, verb, "test")) {
        var dir: []const u8 = ".";
        var source_dir: ?[]const u8 = null;
        var update = false;
        var got_dir = false;
        var j: usize = 0;
        while (j < rest.len) : (j += 1) {
            if (std.mem.eql(u8, rest[j], "--source-dir")) {
                if (j + 1 >= rest.len) c.fatal("--source-dir needs a path", .{});
                source_dir = rest[j + 1];
                j += 1;
            } else if (std.mem.eql(u8, rest[j], "--update")) {
                update = true;
            } else if (std.mem.startsWith(u8, rest[j], "-")) {
                c.fatal("test: unknown option '{s}'", .{rest[j]});
            } else if (!got_dir) {
                dir = rest[j];
                got_dir = true;
            } else c.fatal("test: unexpected argument '{s}'", .{rest[j]});
        }
        cmdTest(a, dir, source_dir, update);
        return;
    }

    // `export-fixture` is offline — a pure transcode of a pulled fixture.
    if (std.mem.eql(u8, verb, "export-fixture")) {
        if (rest.len < 1) c.fatal("export-fixture needs <pulled-fixture.json> [-o world.json]", .{});
        var out_file: ?[]const u8 = null;
        var j: usize = 1;
        while (j < rest.len) : (j += 1) {
            if (std.mem.eql(u8, rest[j], "-o")) {
                if (j + 1 >= rest.len) c.fatal("-o needs a path", .{});
                out_file = rest[j + 1];
                j += 1;
            } else c.fatal("export-fixture: unknown option '{s}'", .{rest[j]});
        }
        cmdExportFixture(a, rest[0], out_file);
        return;
    }

    var cfg = loadCfg(gpa, a, env_path);
    defer cfg.env.deinit();
    if (std.mem.eql(u8, verb, "login")) {
        cmdLogin(a, &cfg);
    } else if (std.mem.eql(u8, verb, "status")) {
        cmdStatus(a, &cfg);
    } else if (std.mem.eql(u8, verb, "deploy")) {
        if (rest.len < 2) c.fatal("deploy needs <tenant> <bundle-dir>", .{});
        var release = false;
        for (rest[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--release")) {
                release = true;
            } else if (std.mem.eql(u8, arg, "--env")) {
                c.fatal("--env is a GLOBAL flag — put it BEFORE the command: rewind --env <file> deploy <tenant> <bundle>", .{});
            } else {
                c.fatal("deploy: unknown option '{s}' (want [--release]; --env goes before the command)", .{arg});
            }
        }
        cmdDeploy(a, &cfg, rest[0], rest[1], release);
    } else if (std.mem.eql(u8, verb, "release") or std.mem.eql(u8, verb, "rollback")) {
        if (rest.len < 2) c.fatal("{s} needs <tenant> <dep_id-hex>", .{verb});
        cmdRelease(a, &cfg, rest[0], rest[1]);
    } else if (std.mem.eql(u8, verb, "deployments")) {
        if (rest.len < 1) c.fatal("deployments needs <tenant>", .{});
        cmdDeployments(a, &cfg, rest[0]);
    } else if (std.mem.eql(u8, verb, "publish")) {
        var apps_dir: []const u8 = ".";
        var include_examples = false;
        var no_release = false;
        var only = std.ArrayList([]const u8){};
        var j: usize = 0;
        while (j < rest.len) : (j += 1) {
            const arg = rest[j];
            if (std.mem.eql(u8, arg, "--apps-dir")) {
                if (j + 1 >= rest.len) c.fatal("--apps-dir needs a path", .{});
                apps_dir = rest[j + 1];
                j += 1;
            } else if (std.mem.eql(u8, arg, "--only")) {
                if (j + 1 >= rest.len) c.fatal("--only needs a comma-separated list", .{});
                var it = std.mem.splitScalar(u8, rest[j + 1], ',');
                while (it.next()) |tname| {
                    const tt = std.mem.trim(u8, tname, " \t");
                    if (tt.len != 0) only.append(a, tt) catch c.oom();
                }
                j += 1;
            } else if (std.mem.eql(u8, arg, "--include-examples")) {
                include_examples = true;
            } else if (std.mem.eql(u8, arg, "--no-release")) {
                no_release = true;
            } else c.fatal("publish: unknown option '{s}'", .{arg});
        }
        cmdPublish(a, &cfg, apps_dir, only.items, include_examples, no_release);
    } else if (std.mem.eql(u8, verb, "provision")) {
        if (rest.len < 1) c.fatal("provision needs <tenant> [--cluster C] [--host H]", .{});
        const tenant = rest[0];
        var cluster: []const u8 = "prod";
        var host: ?[]const u8 = null;
        var j: usize = 1;
        while (j < rest.len) : (j += 1) {
            if (std.mem.eql(u8, rest[j], "--cluster")) {
                if (j + 1 >= rest.len) c.fatal("--cluster needs a value", .{});
                cluster = rest[j + 1];
                j += 1;
            } else if (std.mem.eql(u8, rest[j], "--host")) {
                if (j + 1 >= rest.len) c.fatal("--host needs a value", .{});
                host = rest[j + 1];
                j += 1;
            } else c.fatal("provision: unknown option '{s}'", .{rest[j]});
        }
        cmdProvision(a, &cfg, tenant, cluster, host);
    } else if (std.mem.eql(u8, verb, "host")) {
        if (rest.len < 3 or !std.mem.eql(u8, rest[0], "add"))
            c.fatal("usage: rewind host add <host> <tenant>", .{});
        cmdHostAdd(a, &cfg, rest[1], rest[2]);
    } else if (std.mem.eql(u8, verb, "plan")) {
        if (rest.len < 3 or !std.mem.eql(u8, rest[0], "set"))
            c.fatal("usage: rewind plan set <tenant> <plan>", .{});
        cmdPlanSet(a, &cfg, rest[1], rest[2]);
    } else if (std.mem.eql(u8, verb, "move")) {
        if (rest.len < 2) c.fatal("move needs <tenant> <cluster> --yes [--live]", .{});
        var live = false;
        var yes = false;
        for (rest[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--live")) live = true
            else if (std.mem.eql(u8, arg, "--yes")) yes = true
            else c.fatal("move: unknown option '{s}'", .{arg});
        }
        cmdMove(a, &cfg, rest[0], rest[1], live, yes);
    } else if (std.mem.eql(u8, verb, "route")) {
        if (rest.len < 1) c.fatal("route needs <host>", .{});
        cmdRoute(a, &cfg, rest[0]);
    } else if (std.mem.eql(u8, verb, "logs")) {
        if (rest.len < 1) c.fatal("logs needs <tenant> [--limit N] [--after CURSOR]", .{});
        var limit: ?[]const u8 = null;
        var after: ?[]const u8 = null;
        var j: usize = 1;
        while (j < rest.len) : (j += 1) {
            if (std.mem.eql(u8, rest[j], "--limit")) {
                if (j + 1 >= rest.len) c.fatal("--limit needs a value", .{});
                limit = rest[j + 1];
                j += 1;
            } else if (std.mem.eql(u8, rest[j], "--after")) {
                if (j + 1 >= rest.len) c.fatal("--after needs a value", .{});
                after = rest[j + 1];
                j += 1;
            } else c.fatal("logs: unknown option '{s}'", .{rest[j]});
        }
        cmdLogs(a, &cfg, rest[0], limit, after);
    } else if (std.mem.eql(u8, verb, "pull")) {
        if (rest.len < 2) c.fatal("pull needs <tenant> <req_id> [-o FILE]", .{});
        var out_file: ?[]const u8 = null;
        var j: usize = 2;
        while (j < rest.len) : (j += 1) {
            if (std.mem.eql(u8, rest[j], "-o")) {
                if (j + 1 >= rest.len) c.fatal("-o needs a path", .{});
                out_file = rest[j + 1];
                j += 1;
            } else c.fatal("pull: unknown option '{s}'", .{rest[j]});
        }
        cmdPull(a, &cfg, rest[0], rest[1], out_file);
    } else unreachable; // verb validated above (replay handled before loadCfg)
}

test {
    // Pull the CLI's unit-tested modules into this test root so
    // `zig build test` (via the `cli_tests` step) runs them.
    _ = @import("packages.zig");
    _ = @import("common.zig");
}
