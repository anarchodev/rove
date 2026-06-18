//! `rewind` — the OIDC customer CLI (rewind-cli-plan §6 + Track 3). The
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
//! Config (OS env, or a --env file): REWIND_ADMIN_URL (dashboard origin),
//! REWIND_IDP_URL (the IdP origin), REWIND_CLIENT_ID (default admin-dashboard),
//! REWIND_SESSION (cookie-jar path, default ~/.config/rove/rewind.session).
//! For self-hosted clusters with a private CA / split-horizon DNS:
//! REWIND_CACERT (curl --cacert) and REWIND_RESOLVE (curl --resolve entries,
//! comma-separated host:port:addr).

const std = @import("std");
const c = @import("common.zig");

const DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code";

const Cfg = struct {
    env: c.Env,
    admin_url: []const u8,
    idp_url: []const u8,
    client_id: []const u8,
    session_file: []const u8,
    cacert: ?[]const u8,
    resolves: [][]const u8, // curl --resolve entries
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
    };
}

fn defaultSessionPath(a: std.mem.Allocator) []const u8 {
    const home = std.process.getEnvVarOwned(a, "HOME") catch return "rewind.session";
    const dir = std.fs.path.join(a, &.{ home, ".config", "rove" }) catch return "rewind.session";
    std.fs.cwd().makePath(dir) catch {};
    return std.fs.path.join(a, &.{ dir, "rewind.session" }) catch "rewind.session";
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
        push(&args, a, "--cookie");
        push(&args, a, cfg.session_file);
        push(&args, a, "--cookie-jar");
        push(&args, a, cfg.session_file);
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
fn cmdDeploy(a: std.mem.Allocator, cfg: *const Cfg, tenant: []const u8, bundle: []const u8, release: bool) void {
    const b = c.classify(a, bundle);
    if (b.skipped.len != 0) {
        std.debug.print("  ! skipping (non-deployable): ", .{});
        for (b.skipped, 0..) |s, i| std.debug.print("{s}{s}", .{ if (i != 0) ", " else "", s });
        std.debug.print("\n", .{});
    }
    if (b.handlers.len == 0 and b.statics.len == 0) c.fatal("bundle {s} has nothing to publish", .{bundle});
    std.debug.print("bundle: {d} handler(s), {d} static(s)\n", .{ b.handlers.len, b.statics.len });

    // reset workspace → handlers (JSON) + statics (streamed raw PUT) → cut.
    _ = deployStep(a, cfg, "reset", c.tenantBody(a, tenant), "reset");
    for (b.handlers) |h| _ = deployStep(a, cfg, "file", c.fileBodyHandler(a, tenant, h), h.path);
    for (b.statics) |s| _ = uploadStep(a, cfg, c.uploadPath(a, tenant, s), s.bytes, s.path);
    const cut = deployStep(a, cfg, "cut", c.tenantBody(a, tenant), "cut");
    const dep_id = c.extractDepId(a, cut.body) orelse c.fatal("cut: 200 but no dep_id: {s}", .{cut.body});
    std.debug.print("deployment staged: {s} ({d} file(s)) — NOT released\n", .{ dep_id, b.handlers.len + b.statics.len });
    if (release) cmdRelease(a, cfg, tenant, dep_id);
}

/// `rewind release <tenant> <dep_id_hex>` — flip the live pointer via the
/// ownership-gated publishRelease RPC.
fn cmdRelease(a: std.mem.Allocator, cfg: *const Cfg, tenant: []const u8, dep_id: []const u8) void {
    const dep_num = std.fmt.parseInt(u64, dep_id, 16) catch c.fatal("bad dep_id {s} (want hex)", .{dep_id});
    var body = std.ArrayList(u8){};
    body.appendSlice(a, "{\"fn\":\"publishRelease\",\"args\":[") catch c.oom();
    c.writeJsonString(&body, a, tenant);
    body.appendSlice(a, std.fmt.allocPrint(a, ",{d}]}}", .{dep_num}) catch c.oom()) catch c.oom();
    const url = std.fmt.allocPrint(a, "{s}/", .{cfg.admin_url}) catch c.oom();
    const r = httpCall(a, cfg, "POST", url, &.{JSON_CT}, body.items, true, 30);
    if (r.code == 401) c.fatal("not signed in — run `rewind login`", .{});
    if (r.code == 403) c.fatal("you don't own {s}", .{tenant});
    if (r.code != 202) c.fatal("release failed: {d} {s}", .{ r.code, c.trunc(r.body) });
    std.debug.print("released {s} @ {s}\n", .{ tenant, dep_id });
}

const USAGE =
    \\rewind — the rewind.js customer CLI (OIDC session auth).
    \\
    \\Usage:
    \\  rewind [--env <file>] login
    \\  rewind [--env <file>] status
    \\  rewind [--env <file>] deploy <tenant> <bundle-dir> [--release]
    \\  rewind [--env <file>] release <tenant> <dep_id-hex>
    \\
    \\Config (OS env or the --env file):
    \\  REWIND_ADMIN_URL   dashboard origin (e.g. https://app.example.com)
    \\  REWIND_IDP_URL     IdP origin (e.g. https://auth.example.com)
    \\  REWIND_CLIENT_ID   OAuth client id (default: admin-dashboard)
    \\  REWIND_SESSION     cookie-jar path (default: ~/.config/rove/rewind.session)
    \\  REWIND_CACERT      curl --cacert (private CA)
    \\  REWIND_RESOLVE     curl --resolve entries, comma-separated
    \\
;

pub fn main() void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const argv = std.process.argsAlloc(a) catch c.oom();
    var i: usize = 1;
    var env_path: ?[]const u8 = c.defaultEnvPath(a);
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
    const known = std.mem.eql(u8, verb, "login") or std.mem.eql(u8, verb, "status") or
        std.mem.eql(u8, verb, "deploy") or std.mem.eql(u8, verb, "release");
    if (!known) {
        std.debug.print("rewind: unknown command '{s}'\n\n{s}", .{ verb, USAGE });
        std.process.exit(2);
    }

    var cfg = loadCfg(gpa, a, env_path);
    defer cfg.env.deinit();

    if (std.mem.eql(u8, verb, "login")) {
        cmdLogin(a, &cfg);
    } else if (std.mem.eql(u8, verb, "status")) {
        cmdStatus(a, &cfg);
    } else if (std.mem.eql(u8, verb, "deploy")) {
        if (i + 1 >= argv.len) c.fatal("deploy needs <tenant> <bundle-dir>", .{});
        const tenant = argv[i];
        const bundle = argv[i + 1];
        var release = false;
        for (argv[i + 2 ..]) |arg| {
            if (std.mem.eql(u8, arg, "--release")) release = true;
        }
        cmdDeploy(a, &cfg, tenant, bundle, release);
    } else if (std.mem.eql(u8, verb, "release")) {
        if (i + 1 >= argv.len) c.fatal("release needs <tenant> <dep_id-hex>", .{});
        cmdRelease(a, &cfg, argv[i], argv[i + 1]);
    } else unreachable; // verb validated above
}
