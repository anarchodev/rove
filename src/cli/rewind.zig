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

/// The subset of config a REGISTRY-ONLY command needs: the registry origin
/// plus the transport knobs curl takes. `loadCfg` fatals without
/// `REWIND_ADMIN_URL` / `REWIND_IDP_URL`, which is right for anything that
/// talks to the dashboard and wrong for `lock` — resolving a package graph is
/// a public read against the registry, and demanding dashboard credentials for
/// it is what kept the lockfile welded to `deploy`.
fn loadRegistryCfg(gpa: std.mem.Allocator, a: std.mem.Allocator, env_path: ?[]const u8) Cfg {
    const env = c.loadEnv(gpa, env_path);
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
        // Never dialled on this path: `registryResolve` passes `use_jar =
        // false` and only ever builds a `{registry}/v1/resolve` URL.
        .admin_url = "",
        .idp_url = "",
        .client_id = "",
        .session_file = "",
        .cacert = cfgVar(&env, a, "REWIND_CACERT"),
        .resolves = resolves.items,
        .registry_url = if (cfgVar(&env, a, "REWIND_REGISTRY_URL")) |u| std.mem.trimRight(u8, u, "/") else null,
        .root_token = null,
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

/// How a deploy treats the bundle's `rewind.lock`.
pub const LockMode = enum {
    /// Pin what the lock pins; resolve anything it does not; rewrite it.
    /// The default, and the reproducible one: an existing pin never moves
    /// on its own, while adding a dependency still just works.
    use,
    /// Refuse unless the lock pins exactly the declared set. For CI, where a
    /// deploy that quietly resolves a new range is the thing you are trying
    /// to catch.
    frozen,
    /// Ignore the lock and re-resolve every range. The deliberate
    /// "move the pins" path, same as `rewind lock`.
    update,
};

/// Read `<bundle>/rewind.lock` as the resolve response it is. Null when the
/// file is absent (a bundle that has never been deployed); fatal when it is
/// present and unreadable, because silently re-resolving a corrupt lock is
/// exactly the drift the lock exists to prevent.
fn readLockfile(a: std.mem.Allocator, bundle: []const u8) ?packages.Resolution {
    const path = std.fs.path.join(a, &.{ bundle, "rewind.lock" }) catch c.oom();
    const bytes = std.fs.cwd().readFileAlloc(a, path, 4 << 20) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => c.fatal("read {s}: {s}", .{ path, @errorName(err) }),
    };
    // Version before shape. A lockfile from a NEWER `rewind` is the case
    // that will actually happen here — the binary is on the customer's
    // upgrade schedule, not ours — and reading one at the old shape
    // mis-PINS a deploy instead of failing it, which is the drift the lock
    // exists to prevent (#630 made it an input, not a record).
    const v = packages.lockfileVersion(bytes) catch |err|
        c.fatal("{s} carries no readable format version ({s}) — `rewind lock {s}` rewrites it", .{ path, @errorName(err), bundle });
    if (v != packages.LOCKFILE_VERSION)
        c.fatal("{s} is v{d}; this rewind writes v{d}. Upgrade rewind, or `rewind lock {s}` to rewrite it at this version.", .{ path, v, packages.LOCKFILE_VERSION, bundle });

    return packages.parseResolveResponse(a, bytes) catch |err|
        c.fatal("{s} is not a readable lockfile ({s}) — `rewind lock {s}` rewrites it", .{ path, @errorName(err), bundle });
}

/// How a bundle's lockfile and its `manifest.json` disagree, if they do.
/// `no_lockfile` is kept distinct from "no drift": under `--frozen` there is
/// nothing to be faithful TO, which is a different complaint than a lock that
/// has fallen behind.
const LockDrift = struct {
    no_lockfile: bool = false,
    /// Declared, and the lock pins nothing for it.
    missing: []const []const u8 = &.{},
    /// Pinned, and the bundle no longer declares it.
    stale: []const []const u8 = &.{},
    /// The pins that DO line up — the `overrides` a deploy sends.
    pins: []const packages.Dependency = &.{},

    fn diverged(self: LockDrift) bool {
        return self.no_lockfile or self.missing.len != 0 or self.stale.len != 0;
    }
};

/// Compare a bundle's lockfile against the dependencies it declares. Pure —
/// no printing and no exit, so a caller publishing MANY bundles can ask about
/// every one before it decides anything.
fn lockDrift(
    a: std.mem.Allocator,
    bundle: []const u8,
    deps: []const packages.Dependency,
) LockDrift {
    var lock = readLockfile(a, bundle) orelse return .{ .no_lockfile = true };
    defer lock.deinit();

    const pinned = packages.appSurfacePins(a, &lock) catch |err|
        c.fatal("{s}/rewind.lock: {s}", .{ bundle, @errorName(err) });

    var pins = std.ArrayList(packages.Dependency){};
    var missing = std.ArrayList([]const u8){};
    for (deps) |d| {
        for (pinned) |pin| {
            if (std.mem.eql(u8, pin.spec, d.spec)) {
                pins.append(a, pin) catch c.oom();
                break;
            }
        } else missing.append(a, d.spec) catch c.oom();
    }
    var stale = std.ArrayList([]const u8){};
    for (pinned) |pin| {
        for (deps) |d| {
            if (std.mem.eql(u8, pin.spec, d.spec)) break;
        } else stale.append(a, pin.spec) catch c.oom();
    }
    return .{
        .missing = missing.items,
        .stale = stale.items,
        .pins = pins.items,
    };
}

/// Print one bundle's drift, naming the bundle. Publish walks many bundles, so
/// "the lockfile is out of date" without a name is not an actionable report.
fn reportDrift(bundle: []const u8, drift: LockDrift) void {
    if (drift.no_lockfile) {
        std.debug.print("  {s}: no rewind.lock\n", .{bundle});
        return;
    }
    if (drift.missing.len != 0) {
        std.debug.print("  {s}: not pinned by the lockfile:\n", .{bundle});
        for (drift.missing) |spec| std.debug.print("    + {s}\n", .{spec});
    }
    if (drift.stale.len != 0) {
        std.debug.print("  {s}: pinned but no longer declared:\n", .{bundle});
        for (drift.stale) |spec| std.debug.print("    - {s}\n", .{spec});
    }
}

/// The `overrides` a deploy sends: the lock's exact-version pins, narrowed to
/// the specs the bundle still declares.
///
/// Narrowing matters because a pin for a dropped dependency is not merely
/// useless — under `--frozen` it is the signal that the lock and the manifest
/// have diverged, and it must be reported rather than passed to a registry
/// that would ignore it.
fn lockPins(
    a: std.mem.Allocator,
    bundle: []const u8,
    deps: []const packages.Dependency,
    mode: LockMode,
) []const packages.Dependency {
    if (mode == .update) return &.{};
    const drift = lockDrift(a, bundle, deps);
    if (mode != .frozen) return drift.pins;
    if (drift.no_lockfile) c.fatal(
        "--frozen needs {s}/rewind.lock, and there is none — run `rewind lock {s}` first",
        .{ bundle, bundle },
    );
    if (drift.diverged()) {
        std.debug.print("rewind: the lockfile is out of date with manifest.json:\n", .{});
        reportDrift(bundle, drift);
        c.fatal("--frozen: `rewind lock {s}` to update it", .{bundle});
    }
    return drift.pins;
}

/// `rewind lock <bundle>` — resolve the bundle's package graph and write
/// `rewind.lock`, without deploying anything.
///
/// The lockfile used to be a side effect of `deploy` alone, which meant it
/// could only be refreshed by shipping. Adding an import without a deploy left
/// the lockfile behind, and the drift surfaced far away and much later: a node
/// compiling the bundle raises `could not load module '@rewind/x'`, in whatever
/// suite happened to deploy it. Resolving is a public read with no session, so
/// it has no business requiring one.
///
/// The resolution written here is the registry's response VERBATIM — the same
/// bytes `deploy` persists — so a lockfile made by either route is the same
/// lockfile.
fn cmdLock(a: std.mem.Allocator, cfg: *const Cfg, bundle: []const u8) void {
    const b = c.classify(a, bundle);
    const declared = readBundleDependencies(a, bundle);
    const deps = augmentDependencies(a, declared, b.handlers);
    if (deps.len == 0) {
        std.debug.print("bundle {s} declares no packages — no lockfile to write\n", .{bundle});
        return;
    }
    // No overrides: `lock` is the deliberate "move the pins to the newest
    // matching version" verb, which is why `deploy` does not do this.
    var rr = registryResolve(a, cfg, deps, &.{});
    packages.topoSort(&rr.res) catch c.fatal("resolved packages form a dependency cycle", .{});
    writeLockfile(bundle, rr.body);
    std.debug.print("{s}/rewind.lock: {d} package(s) pinned\n", .{ bundle, rr.res.packages.len });
    for (rr.res.packages) |pkg| {
        std.debug.print("  {s}@{s}\n", .{ pkg.spec, pkg.version });
    }
}

/// `rewind deploy <tenant> <bundle> [--release] [--frozen|--update]` — per-file
/// workspace deploy. A bundle whose `manifest.json` declares `dependencies`
/// resolves them against the `@rewind` registry and stages the resolved
/// package graph (P-CLI, rove#122); a package-free bundle takes the plain
/// path.
///
/// Resolution is pinned by the bundle's `rewind.lock` (`LockMode`). Without
/// that, a deploy re-resolves the loose ranges every time and the same commit
/// ships different package code as the registry moves under it — which is
/// incoherent on a platform that sells per-request deterministic replay, since
/// a tape pins the handler's module hashes and nothing in the repo would show
/// the change.
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

fn cmdDeploy(
    a: std.mem.Allocator,
    cfg: *const Cfg,
    tenant: []const u8,
    bundle: []const u8,
    release: bool,
    lock_mode: LockMode,
) void {
    requireAuth(cfg);
    const b = c.classify(a, bundle);
    if (b.skipped.len != 0) {
        std.debug.print("  ! skipping (non-deployable): ", .{});
        for (b.skipped, 0..) |s, i| std.debug.print("{s}{s}", .{ if (i != 0) ", " else "", s });
        std.debug.print("\n", .{});
        // A skipped `.js` is called out separately. In the mixed list above it
        // reads like a README — but it is code the developer wrote and very
        // likely expects to run, and the consequence is silent: the file is
        // absent in production with no further error. `_middlewares/index.js`
        // is the dangerous instance, since that is where auth gates live.
        var js_skipped: usize = 0;
        for (b.skipped) |s| {
            if (std.mem.endsWith(u8, s, ".js")) js_skipped += 1;
        }
        if (js_skipped != 0) {
            std.debug.print(
                "  ! {d} `.js` file(s) above are NOT deployed — handlers must be `.mjs`.\n" ++
                    "    Rename them, or they will simply be absent in production.\n",
                .{js_skipped},
            );
        }
    }
    if (b.handlers.len == 0 and b.statics.len == 0) c.fatal("bundle {s} has nothing to publish", .{bundle});
    std.debug.print("bundle: {d} handler(s), {d} static(s)\n", .{ b.handlers.len, b.statics.len });

    // Package graph: the bundle's declared `dependencies`, plus the auto-pin
    // of undeclared @rewind/* imports the handlers actually use.
    const declared = readBundleDependencies(a, bundle);
    const deps = augmentDependencies(a, declared, b.handlers);

    // Everything that can REFUSE happens before anything that MUTATES.
    //
    // `reset` clears the tenant's staged deployment, so a failure after it —
    // an out-of-date lockfile under `--frozen`, an unresolvable pin, a
    // registry outage — leaves the tenant emptied by a deploy that then
    // declined to proceed. Reading the lock and resolving the graph are both
    // pure reads, so they belong on this side of the line.
    var resolved: ?packages.Resolution = null;
    var pin_count: usize = 0;
    var lock_body: []const u8 = "";
    if (deps.len != 0) {
        const pins = lockPins(a, bundle, deps, lock_mode);
        pin_count = pins.len;
        var rr = registryResolve(a, cfg, deps, pins);
        packages.topoSort(&rr.res) catch c.fatal("resolved packages form a dependency cycle", .{});
        resolved = rr.res;
        lock_body = rr.body;
        // Say which discipline actually applied. Reporting "0/N pinned"
        // under `--update` would read as a stale lockfile rather than as the
        // deliberate re-resolve the caller asked for.
        if (lock_mode == .update) {
            std.debug.print(
                "resolved {d} package(s) — --update: every range re-resolved, rewind.lock rewritten\n",
                .{rr.res.packages.len},
            );
        } else if (pins.len == deps.len) {
            std.debug.print(
                "resolved {d} package(s) — all {d} pinned by rewind.lock\n",
                .{ rr.res.packages.len, pins.len },
            );
        } else {
            std.debug.print(
                "resolved {d} package(s) — {d}/{d} pinned by rewind.lock, {d} newly resolved\n",
                .{ rr.res.packages.len, pins.len, deps.len, deps.len - pins.len },
            );
        }
    }

    _ = deployStep(a, cfg, "reset", c.tenantBody(a, tenant), "reset");

    // With packages: stage every package file (stage-only, order free) → cut
    // carries the lockfile resolution; the deploy app compiles each package as
    // a batch (dependency-ordered) and links the handlers against the pinned
    // graph, all server-side at cut.
    var cut_body: []const u8 = c.tenantBody(a, tenant);
    if (resolved) |*res| {
        stagePackages(a, cfg, tenant, res);
        const lock = packages.emitResolution(a, res) catch c.oom();
        cut_body = cutBody(a, tenant, lock);
        writeLockfile(bundle, lock_body);
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
fn registryResolve(
    a: std.mem.Allocator,
    cfg: *const Cfg,
    deps: []const packages.Dependency,
    overrides: []const packages.Dependency,
) ResolveResult {
    const base = cfg.registry_url orelse c.fatal(
        "this bundle declares `dependencies` but REWIND_REGISTRY_URL is unset — point it at your @rewind registry origin",
        .{},
    );
    const req = packages.buildResolveRequest(a, deps, overrides) catch c.oom();
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
    // The registry's body verbatim, plus this CLI's format stamp — see
    // `packages.stampLockfile` for why the body is not re-serialized.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const stamped = packages.stampLockfile(arena.allocator(), body) catch |err| {
        std.debug.print("  ! could not stamp {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };
    const f = std.fs.cwd().createFile(path, .{}) catch |err| {
        std.debug.print("  ! could not write {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };
    defer f.close();
    f.writeAll(stamped) catch {};
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
/// Pull ONE record and transcode it to a world — the shared per-record
/// half of `pull` and `pull --saga`. Returns the world JSON (arena-owned).
fn pullWorld(a: std.mem.Allocator, cfg: *const Cfg, tenant: []const u8, req_id: []const u8) []const u8 {
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
    // The record's `_settled` engine tag — which host promise this resume's
    // settle resolved (the chain fold's settle choice). The transcode lifts
    // it onto the activation bag as `settledPromise`.
    if (rec.get("tags")) |tv| {
        if (tv == .object) {
            if (jStrM(tv.object, "_settled")) |sv| {
                w.writeAll(",\"settled_promise\":") catch c.oom();
                emitStr(w, sv);
            }
            // `_streamed` (rove#931): the inbound body streamed — the
            // transcode builds the hop-0 world with `streamedBody`.
            if (jStrM(tv.object, "_streamed")) |_| {
                w.writeAll(",\"streamed_body\":true") catch c.oom();
            }
        }
    }
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

    // 4. Out-of-line payloads. A payload over the inline cap is not on the
    // tape — the entry keeps a pointer and the bytes stay in object storage —
    // so the bundle so far names them without carrying them. Resolve each
    // through the log-server's body door and inline the bytes, or the world
    // below has to refuse an input the record could have supplied.
    const bundle = resolveBodies(a, cfg, tenant, jStr(rec_val, "request_id") orelse req_id, buf.items);

    // Transcode the captured record (base64 tapes) into the ONE editable format
    // — a declarative `world.json` that `rewind replay` (fail) and `rewind sim`
    // (resolve) both consume. The wire/tape form never reaches a human.
    var world = std.ArrayList(u8){};
    replay.exportFixture(a, bundle, &world) catch |e|
        c.fatal("pull: transcode to world failed: {s}", .{@errorName(e)});

    return world.items;
}

/// `rewind pull <tenant> <req_id> [-o FILE]` — one record → one world.
fn cmdPull(a: std.mem.Allocator, cfg: *const Cfg, tenant: []const u8, req_id: []const u8, out_file: ?[]const u8) void {
    const world = pullWorld(a, cfg, tenant, req_id);
    if (out_file) |path| {
        std.fs.cwd().writeFile(.{ .sub_path = path, .data = world }) catch |e|
            c.fatal("pull: write {s}: {s}", .{ path, @errorName(e) });
        std.debug.print("wrote world → {s}  ({s})\n", .{ path, req_id });
    } else {
        std.debug.print("{s}\n", .{world});
    }
}

/// `rewind pull <tenant> --saga <saga_id> [-o FILE]` — every hop of one
/// saga (`/v1/{tenant}/saga/{id}`, exec_seq order), each pulled and
/// transcoded, assembled into ONE chain world (`{"chain":[…]}`) that
/// `rewind replay` folds — the saga fold, the held chain's replay unit.
fn cmdPullSaga(a: std.mem.Allocator, cfg: *const Cfg, tenant: []const u8, saga_id: []const u8, out_file: ?[]const u8) void {
    var worlds = std.ArrayList([]const u8){};
    var after_seq: []const u8 = "0";
    var pages: usize = 0;
    while (true) {
        pages += 1;
        if (pages > 64) c.fatal("pull --saga: {s} exceeds 64 pages of hops — not a foldable chain", .{saga_id});
        // Through the admin door's log proxy (`/v1/logs/{tenant}/…` →
        // the log-server's `/v1/{tenant}/…` — web/admin handleLogQuery),
        // the same spelling `logs`/`pull` use.
        const url = std.fmt.allocPrint(a, "{s}/v1/logs/{s}/saga/{s}?limit=500&after_seq={s}", .{ cfg.admin_url, tenant, saga_id, after_seq }) catch c.oom();
        const r = httpCall(a, cfg, "GET", url, &.{}, null, true, 60);
        if (r.code == 401) c.fatal("not signed in — run `rewind login`", .{});
        if (r.code == 403) c.fatal("operator-only — log read needs an operator (is_root) session", .{});
        if (r.code == 404) c.fatal("pull --saga: saga {s} not found for {s}", .{ saga_id, tenant });
        if (r.code != 200) c.fatal("pull --saga {s}: {d} {s}", .{ saga_id, r.code, c.trunc(r.body) });
        const p = std.json.parseFromSlice(std.json.Value, a, r.body, .{}) catch
            c.fatal("pull --saga: response did not parse", .{});
        if (p.value != .object) c.fatal("pull --saga: response is not an object", .{});
        const o = p.value.object;
        // An unstamped hop has no tape position; a chain containing one
        // cannot be ordered, and order is the whole fold. Loud.
        if (o.get("unplaced")) |uv| {
            if (uv == .array and uv.array.items.len > 0)
                c.fatal("pull --saga: {s} has {d} unplaced hop(s) (no exec_seq) — the chain cannot be ordered", .{ saga_id, uv.array.items.len });
        }
        const hops: []const std.json.Value = blk: {
            const hv = o.get("hops") orelse break :blk &.{};
            break :blk if (hv == .array) hv.array.items else &.{};
        };
        for (hops) |hv| {
            if (hv != .object) continue;
            const rid = jStrM(hv.object, "request_id") orelse continue;
            std.debug.print("pull --saga: hop {d} ← {s}\n", .{ worlds.items.len, rid });
            worlds.append(a, pullWorld(a, cfg, tenant, rid)) catch c.oom();
        }
        // Keyset paging: follow next_cursor.exec_seq until the page is last.
        const nc = o.get("next_cursor") orelse break;
        if (nc != .object) break;
        after_seq = jStrM(nc.object, "exec_seq") orelse break;
    }
    if (worlds.items.len == 0) c.fatal("pull --saga: saga {s} has no hops", .{saga_id});
    var chain = std.ArrayList(u8){};
    replay.assembleChain(a, worlds.items, &chain) catch |e|
        c.fatal("pull --saga: chain assembly failed: {s} (see warnings above — an export-flow hop cannot fold)", .{@errorName(e)});
    if (out_file) |path| {
        std.fs.cwd().writeFile(.{ .sub_path = path, .data = chain.items }) catch |e|
            c.fatal("pull --saga: write {s}: {s}", .{ path, @errorName(e) });
        std.debug.print("wrote chain world → {s}  ({s}, {d} hops)\n", .{ path, saga_id, worlds.items.len });
    } else {
        std.debug.print("{s}\n", .{chain.items});
    }
}

/// Resolve a pulled bundle's out-of-line payloads and inline them back into it.
///
/// A recorded payload over the inline cap is not stored in the log record: the
/// entry keeps a pointer — a slice of the cross-tenant body pool, or a slice of
/// one of the tenant's content-addressed objects — and the bytes stay where
/// they already are. Offline replay can follow neither, so without this step a
/// large input replays as an EMPTY body: a missing input presenting as a
/// plausible value rather than a refusal.
///
/// Each payload is addressed by `(record, channel, RAW entry index)`, never by
/// a raw `BodyRef`: the pool is cross-tenant by construction,
/// so a door taking a caller-supplied batch and offset would let anyone past
/// the tenant gate read a neighbour's bytes by walking offsets. The server
/// derives the reference from a record this session may already read.
///
/// Best-effort by design. A door that refuses (the bytes are gone, the payload
/// was recorded as nothing, no door at all) leaves that payload out of
/// `resolved_bodies`, and the transcode then emits a world that REFUSES the
/// input instead of one that serves it empty. Returns the bundle to transcode —
/// the original when there was nothing out of line.
fn resolveBodies(
    a: std.mem.Allocator,
    cfg: *const Cfg,
    tenant: []const u8,
    request_id: []const u8,
    bundle: []const u8,
) []const u8 {
    const pending = replay.exportFixtureOutOfLine(a, bundle) catch |e| {
        std.debug.print("rewind: pull: could not scan for out-of-line payloads: {s}\n", .{@errorName(e)});
        return bundle;
    };
    if (pending.len == 0) return bundle;
    if (bundle.len == 0 or bundle[bundle.len - 1] != '}') return bundle;

    var out = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &out);
    const w = &aw.writer;
    // Splice `resolved_bodies` in ahead of the bundle's closing brace.
    w.writeAll(bundle[0 .. bundle.len - 1]) catch c.oom();
    w.writeAll(",\"resolved_bodies\":{") catch c.oom();

    // One object per channel, opened as the walk enters it — `pending` is
    // grouped by channel, so a channel is never re-entered.
    var channels_written: usize = 0;
    var open_channel: []const u8 = "";
    var unresolved: usize = 0;
    for (pending) |p| {
        const url = std.fmt.allocPrint(a, "{s}/v1/logs/{s}/body/{s}/{s}/{d}", .{
            cfg.admin_url, tenant, request_id, p.channel, p.index,
        }) catch c.oom();
        const r = httpCall(a, cfg, "GET", url, &.{}, null, true, 60);
        if (r.code != 200) {
            unresolved += 1;
            std.debug.print(
                "rewind: pull: {s}[{d}] unresolved ({d}) — replay will refuse that input, not fake it\n",
                .{ p.channel, p.index, r.code },
            );
            continue;
        }
        const dp = std.json.parseFromSlice(std.json.Value, a, r.body, .{}) catch {
            unresolved += 1;
            continue;
        };
        const b64 = jStr(dp.value, "bytes_b64") orelse {
            unresolved += 1;
            continue;
        };
        if (!std.mem.eql(u8, open_channel, p.channel)) {
            if (open_channel.len != 0) w.writeByte('}') catch c.oom();
            if (channels_written != 0) w.writeByte(',') catch c.oom();
            emitStr(w, p.channel);
            w.writeAll(":{") catch c.oom();
            open_channel = p.channel;
            channels_written += 1;
        } else {
            w.writeByte(',') catch c.oom();
        }
        w.print("\"{d}\":", .{p.index}) catch c.oom();
        emitStr(w, b64);
    }
    if (open_channel.len != 0) w.writeByte('}') catch c.oom();
    w.writeAll("}}") catch c.oom();
    out = aw.toArrayList();

    const resolved = pending.len - unresolved;
    std.debug.print("rewind: pull: resolved {d}/{d} out-of-line payload(s)\n", .{ resolved, pending.len });
    return out.items;
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

/// `rewind assemble-chain <world.json>… [-o chain.json]` — assemble
/// transcoded per-record worlds (exec_seq order) into ONE chain world the
/// fold replays (`{"chain":[…]}` → `rewind replay`). Offline. The online
/// twin is `pull --saga`, which pulls + transcodes + assembles in one verb;
/// this one serves harnesses that already hold the per-hop worlds (the
/// smoke tails compose fixtures from direct log-server reads).
fn cmdAssembleChain(a: std.mem.Allocator, world_paths: []const []const u8, out_file: ?[]const u8) void {
    if (world_paths.len == 0) c.fatal("assemble-chain: no worlds given", .{});
    var worlds = std.ArrayList([]const u8){};
    for (world_paths) |wp| {
        const bytes = std.fs.cwd().readFileAlloc(a, wp, 64 << 20) catch |e|
            c.fatal("assemble-chain: read {s}: {s}", .{ wp, @errorName(e) });
        worlds.append(a, bytes) catch c.oom();
    }
    var chain = std.ArrayList(u8){};
    replay.assembleChain(a, worlds.items, &chain) catch |e|
        c.fatal("assemble-chain: {s} (see warnings above — an export-flow hop cannot fold)", .{@errorName(e)});
    if (out_file) |path| {
        std.fs.cwd().writeFile(.{ .sub_path = path, .data = chain.items }) catch |e|
            c.fatal("assemble-chain: write {s}: {s}", .{ path, @errorName(e) });
        std.debug.print("wrote chain world → {s}  ({d} hops)\n", .{ path, world_paths.len });
    } else {
        std.debug.print("{s}\n", .{chain.items});
    }
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

/// `rewind publish [--apps-dir D] [--only ...] [--include-examples]
/// [--no-release] [--frozen|--update]` — read `{apps-dir}/manifest.json` and
/// drive provision + host-map + deploy + release for each first-party tenant.
/// The typed twin of `scripts/ops/publish_firstparty.py`, over the session
/// cookie (no operator secret).
///
/// `lock_mode` reaches every bundle. Under `--frozen` the whole selection is
/// judged first (`preflightFrozen`), so a stale lockfile on the last tenant
/// cannot be discovered after the first four have already shipped.
/// One selected tenant from the publish manifest, resolved to what the loop
/// needs. Selection is worked out ONCE and reused, so the `--frozen`
/// pre-flight and the publish itself can never disagree about which bundles
/// are in scope — a pre-flight that judged a different set than it gated
/// would be worse than none.
const PublishTarget = struct {
    id: []const u8,
    dir: []const u8,
    bundle: []const u8,
    cluster: []const u8,
    hosts: []const []const u8,
    provision: bool,
    release: bool,
};

/// Read the publish manifest and resolve the selected tenants.
fn publishTargets(
    a: std.mem.Allocator,
    apps_dir: []const u8,
    only: [][]const u8,
    include_examples: bool,
) []const PublishTarget {
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

    var out = std.ArrayList(PublishTarget){};
    for (tenants.array.items) |t| {
        if (t != .object) continue;
        const id = jStr(t, "tenant") orelse {
            std.debug.print("· skipping a tenant entry with no `tenant` id\n", .{});
            continue;
        };
        const kind = jStr(t, "kind") orelse "operator";
        const selected = if (only.len != 0)
            inList(only, id)
        else
            (!std.mem.eql(u8, kind, "example") or include_examples);
        if (!selected) {
            std.debug.print("· skip {s} ({s})\n", .{ id, kind });
            continue;
        }

        const dir = jStr(t, "dir") orelse id;
        var hosts = std.ArrayList([]const u8){};
        if (t.object.get("hosts")) |h| if (h == .array) {
            for (h.array.items) |hv| if (hv == .string) hosts.append(a, hv.string) catch c.oom();
        };
        out.append(a, .{
            .id = id,
            .dir = dir,
            .bundle = std.fs.path.join(a, &.{ apps_dir, dir }) catch c.oom(),
            .cluster = jStr(t, "cluster") orelse def_cluster,
            .hosts = hosts.items,
            .provision = jBool(t, "provision", true),
            .release = jBool(t, "release", def_release),
        }) catch c.oom();
    }
    return out.items;
}

/// `--frozen` across many bundles: judge EVERY selected bundle before any of
/// them is touched, and report all the offenders at once.
///
/// Refusing on the first offender would be the multi-bundle version of the bug
/// `cmdDeploy` just fixed — earlier tenants already provisioned and published,
/// and the operator learns about the next stale lockfile only after fixing
/// this one and re-running.
fn preflightFrozen(a: std.mem.Allocator, targets: []const PublishTarget) void {
    var offenders: usize = 0;
    for (targets) |t| {
        const b = c.classify(a, t.bundle);
        const declared = readBundleDependencies(a, t.bundle);
        const deps = augmentDependencies(a, declared, b.handlers);
        if (deps.len == 0) continue; // no packages, nothing to pin
        const drift = lockDrift(a, t.bundle, deps);
        if (!drift.diverged()) continue;
        if (offenders == 0)
            std.debug.print("rewind: --frozen — lockfiles out of date with manifest.json:\n", .{});
        reportDrift(t.bundle, drift);
        offenders += 1;
    }
    if (offenders != 0) c.fatal(
        "--frozen: {d} bundle(s) need `rewind lock <dir>` — nothing was published",
        .{offenders},
    );
}

fn cmdPublish(
    a: std.mem.Allocator,
    cfg: *const Cfg,
    apps_dir: []const u8,
    only: [][]const u8,
    include_examples: bool,
    no_release: bool,
    lock_mode: LockMode,
) void {
    const targets = publishTargets(a, apps_dir, only, include_examples);

    // Every bundle's lockfile is judged before the first tenant is touched.
    if (lock_mode == .frozen) preflightFrozen(a, targets);

    for (targets) |t| {
        std.debug.print("\n▶ {s}  (dir {s}, cluster {s})\n", .{ t.id, t.dir, t.cluster });
        if (t.provision) cmdProvision(a, cfg, t.id, t.cluster, if (t.hosts.len > 0) t.hosts[0] else null);
        if (t.hosts.len > 1) for (t.hosts[1..]) |hh| cmdHostAdd(a, cfg, hh, t.id);
        cmdDeploy(a, cfg, t.id, t.bundle, t.release and !no_release, lock_mode);
    }
    std.debug.print("\npublish complete — {d} tenant(s) processed\n", .{targets.len});
}

const USAGE =
    \\rewind — the rewind.js customer CLI (OIDC session auth).
    \\
    \\Usage:
    \\  rewind [--env <file>] login
    \\  rewind [--env <file>] status
    \\  rewind [--env <file>] deploy <tenant> <bundle-dir> [--release] [--frozen|--update]
    \\  rewind [--env <file>] lock <bundle-dir>
    \\  rewind [--env <file>] release <tenant> <dep_id-hex>
    \\  rewind [--env <file>] rollback <tenant> <dep_id-hex>
    \\  rewind [--env <file>] deployments <tenant>
    \\  rewind [--env <file>] logs <tenant> [--limit N] [--after CURSOR]
    \\  rewind [--env <file>] pull <tenant> <req_id | --saga <saga_id>> [-o FILE]
    \\  rewind [--env <file>] replay <world.json> [--source-dir DIR] [--update] [-o FILE]
    \\  rewind sim <world.json> [--source-dir DIR] [--update] [-o FILE]
    \\  rewind test [dir] [--source-dir DIR] [--update]
    \\  rewind export-fixture <base64-record.json> [-o world.json]
    \\  rewind assemble-chain <world.json>… [-o chain.json]
    \\  rewind [--env <file>] publish [--apps-dir D] [--only t1,t2] [--include-examples] [--no-release] [--frozen|--update]
    \\  rewind [--env <file>] provision <tenant> [--cluster C] [--host H]
    \\  rewind [--env <file>] host add <host> <tenant>
    \\  rewind [--env <file>] plan set <tenant> <plan>
    \\  rewind [--env <file>] move <tenant> <cluster> [--live] --yes
    \\  rewind [--env <file>] route <host>
    \\
    \\Packages resolve through the bundle's `rewind.lock`: an existing pin never
    \\moves on its own, a newly declared dependency resolves and is written back.
    \\`--frozen` refuses when the lock and manifest.json disagree (use it in CI);
    \\`--update` re-resolves every range, as `rewind lock` does. Both work on
    \\`publish` too, where `--frozen` judges every selected bundle before it
    \\touches the first one.
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
        std.mem.eql(u8, verb, "deploy") or std.mem.eql(u8, verb, "lock") or
        std.mem.eql(u8, verb, "release") or
        std.mem.eql(u8, verb, "rollback") or std.mem.eql(u8, verb, "deployments") or
        std.mem.eql(u8, verb, "publish") or std.mem.eql(u8, verb, "provision") or
        std.mem.eql(u8, verb, "host") or std.mem.eql(u8, verb, "plan") or
        std.mem.eql(u8, verb, "move") or std.mem.eql(u8, verb, "route") or
        std.mem.eql(u8, verb, "logs") or std.mem.eql(u8, verb, "pull") or
        std.mem.eql(u8, verb, "replay") or std.mem.eql(u8, verb, "sim") or
        std.mem.eql(u8, verb, "test") or std.mem.eql(u8, verb, "export-fixture") or
        std.mem.eql(u8, verb, "assemble-chain");
    if (!known) {
        std.debug.print("rewind: unknown command '{s}'\n\n{s}", .{ verb, USAGE });
        std.process.exit(2);
    }

    const rest = argv[i..];

    // `lock` talks only to the registry, so it takes the registry-only config
    // for the same reason `replay` takes none: a command should not demand
    // credentials for an origin it never dials.
    if (std.mem.eql(u8, verb, "lock")) {
        if (rest.len < 1) c.fatal("lock needs <bundle-dir>", .{});
        var lock_cfg = loadRegistryCfg(gpa, a, env_path);
        cmdLock(a, &lock_cfg, rest[0]);
        return;
    }

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

    // `assemble-chain` is offline — worlds in, one chain world out.
    if (std.mem.eql(u8, verb, "assemble-chain")) {
        if (rest.len < 2) c.fatal("assemble-chain needs <world.json> <world.json>… [-o chain.json]", .{});
        var out_file: ?[]const u8 = null;
        var paths = std.ArrayList([]const u8){};
        var j: usize = 0;
        while (j < rest.len) : (j += 1) {
            if (std.mem.eql(u8, rest[j], "-o")) {
                if (j + 1 >= rest.len) c.fatal("-o needs a path", .{});
                out_file = rest[j + 1];
                j += 1;
            } else paths.append(a, rest[j]) catch c.oom();
        }
        cmdAssembleChain(a, paths.items, out_file);
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
        var lock_mode: LockMode = .use;
        var saw_mode = false;
        for (rest[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--release")) {
                release = true;
            } else if (std.mem.eql(u8, arg, "--frozen") or std.mem.eql(u8, arg, "--update")) {
                // Mutually exclusive by meaning: one refuses to move the pins,
                // the other exists to move them. Taking the last one silently
                // would pick a behaviour the author did not ask for.
                if (saw_mode) c.fatal("deploy: --frozen and --update are mutually exclusive", .{});
                saw_mode = true;
                lock_mode = if (std.mem.eql(u8, arg, "--frozen")) .frozen else .update;
            } else if (std.mem.eql(u8, arg, "--env")) {
                c.fatal("--env is a GLOBAL flag — put it BEFORE the command: rewind --env <file> deploy <tenant> <bundle>", .{});
            } else {
                c.fatal("deploy: unknown option '{s}' (want [--release] [--frozen|--update]; --env goes before the command)", .{arg});
            }
        }
        cmdDeploy(a, &cfg, rest[0], rest[1], release, lock_mode);
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
        var lock_mode: LockMode = .use;
        var saw_mode = false;
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
            } else if (std.mem.eql(u8, arg, "--frozen") or std.mem.eql(u8, arg, "--update")) {
                if (saw_mode) c.fatal("publish: --frozen and --update are mutually exclusive", .{});
                saw_mode = true;
                lock_mode = if (std.mem.eql(u8, arg, "--frozen")) .frozen else .update;
            } else c.fatal("publish: unknown option '{s}'", .{arg});
        }
        cmdPublish(a, &cfg, apps_dir, only.items, include_examples, no_release, lock_mode);
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
        if (rest.len < 2) c.fatal("pull needs <tenant> <req_id | --saga <saga_id>> [-o FILE]", .{});
        var out_file: ?[]const u8 = null;
        var saga: ?[]const u8 = null;
        var req: ?[]const u8 = null;
        var j: usize = 1;
        while (j < rest.len) : (j += 1) {
            if (std.mem.eql(u8, rest[j], "-o")) {
                if (j + 1 >= rest.len) c.fatal("-o needs a path", .{});
                out_file = rest[j + 1];
                j += 1;
            } else if (std.mem.eql(u8, rest[j], "--saga")) {
                if (j + 1 >= rest.len) c.fatal("--saga needs a saga id", .{});
                saga = rest[j + 1];
                j += 1;
            } else if (req == null) {
                req = rest[j];
            } else c.fatal("pull: unknown option '{s}'", .{rest[j]});
        }
        if (saga) |sid| {
            cmdPullSaga(a, &cfg, rest[0], sid, out_file);
        } else if (req) |rid| {
            cmdPull(a, &cfg, rest[0], rid, out_file);
        } else c.fatal("pull needs <req_id> or --saga <saga_id>", .{});
    } else unreachable; // verb validated above (replay handled before loadCfg)
}

test {
    // Pull the CLI's unit-tested modules into this test root so
    // `zig build test` (via the `cli_tests` step) runs them.
    _ = @import("packages.zig");
    _ = @import("common.zig");
}
