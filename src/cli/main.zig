//! `rewind` — the operator CLI (docs/rewind-cli-plan.md §2–§3, §6). A thin,
//! typed, single-binary client for the tenant-operations the old
//! `scripts/publish_tenant.py` welded together. Transport is the proven one
//! (plan §3): shell out to `curl` (HTTP/2 prior-knowledge), wrapped in
//! `ssh <host> curl …` when `ROVE_PUBLISH_SSH` is set so the private-plane
//! reachability is identical to the script. std-only — no rove modules, no
//! raft/cargo linkage.
//!
//! Commands:
//!   rewind reset                         POST {worker}/_system/reset — (re)deploy
//!                                        the baked __admin__ deploy app (root).
//!                                        Bootstrap+break-glass of deploy capability
//!                                        on an ALREADY-provisioned cluster.
//!   rewind bootstrap                     provision __admin__ via the CP + reset —
//!                                        first-time bring-up of a virgin cluster.
//!   rewind deploy <tenant> <bundle>      classify the bundle, POST it to the
//!         [--release]                    standing __admin__ deploy app (root),
//!                                        print the dep_id; --release flips it live.
//!   rewind release <tenant> <dep_id>     flip _deploy/current (leader-aware retry).
//!
//! Config: an operator env file (KEY=VALUE), default ~/.config/rove/prod.env
//! (legacy fallback ./.env.prod), overridable with --env. OS environment
//! variables of the same name override the file (so smokes can run without a
//! file). Vars: REWIND_ROOT_TOKEN, REWIND_ADMIN_DOMAIN, ROVE_WORKER_URLS
//! (comma list), ROVE_PUBLISH_SSH (optional), ROVE_CP_URL_INTERNAL +
//! REWIND_MOVE_SECRET (bootstrap only).

const std = @import("std");

const Resp = struct { code: u32, body: []u8 };

const Env = struct {
    map: std.StringHashMap([]const u8),
    arena: std.heap.ArenaAllocator,

    fn get(self: *const Env, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    fn require(self: *const Env, key: []const u8) []const u8 {
        return self.map.get(key) orelse fatal("missing required config var: {s}", .{key});
    }

    fn deinit(self: *Env) void {
        self.arena.deinit();
    }
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("rewind: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

// ── config ────────────────────────────────────────────────────────────────

/// Default operator env path: $XDG_CONFIG_HOME/rove/prod.env (or
/// ~/.config/rove/prod.env), legacy fallback ./.env.prod — mirrors
/// publish_tenant.py's `default_env_file`.
fn defaultEnvPath(arena: std.mem.Allocator) ?[]const u8 {
    const xdg = std.process.getEnvVarOwned(arena, "XDG_CONFIG_HOME") catch null;
    const base = xdg orelse blk: {
        const home = std.process.getEnvVarOwned(arena, "HOME") catch return cwdFallback(arena);
        break :blk std.fs.path.join(arena, &.{ home, ".config" }) catch return null;
    };
    const cand = std.fs.path.join(arena, &.{ base, "rove", "prod.env" }) catch return null;
    std.fs.cwd().access(cand, .{}) catch return cwdFallback(arena);
    return cand;
}

fn cwdFallback(arena: std.mem.Allocator) ?[]const u8 {
    const legacy = ".env.prod";
    std.fs.cwd().access(legacy, .{}) catch return null;
    return arena.dupe(u8, legacy) catch null;
}

/// Load the env file (if present) then overlay matching OS env vars. Every
/// stored value is owned by the arena.
fn loadEnv(gpa: std.mem.Allocator, env_path: ?[]const u8) Env {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    var map = std.StringHashMap([]const u8).init(gpa);

    if (env_path) |path| {
        const bytes = std.fs.cwd().readFileAlloc(a, path, 4 << 20) catch |err| blk: {
            std.debug.print("rewind: note: env file {s} not read ({s}); using OS env only\n", .{ path, @errorName(err) });
            break :blk "";
        };
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            map.put(a.dupe(u8, key) catch oom(), a.dupe(u8, val) catch oom()) catch oom();
        }
    }

    // OS env overrides the file for the vars we care about.
    for ([_][]const u8{
        "REWIND_ROOT_TOKEN", "REWIND_ADMIN_DOMAIN", "ROVE_WORKER_URLS",
        "ROVE_PUBLISH_SSH",  "ROVE_CP_URL_INTERNAL", "REWIND_MOVE_SECRET",
        "ROVE_CLUSTER",
    }) |k| {
        if (std.process.getEnvVarOwned(a, k) catch null) |v| {
            map.put(a.dupe(u8, k) catch oom(), v) catch oom();
        }
    }

    return .{ .map = map, .arena = arena };
}

fn oom() noreturn {
    fatal("out of memory", .{});
}

fn workerUrls(env: *const Env, a: std.mem.Allocator) [][]const u8 {
    const csv = env.require("ROVE_WORKER_URLS");
    var list = std.ArrayList([]const u8){};
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |u| {
        const t = std.mem.trim(u8, u, " \t");
        if (t.len != 0) list.append(a, t) catch oom();
    }
    if (list.items.len == 0) fatal("ROVE_WORKER_URLS is empty", .{});
    return list.items;
}

// ── transport (curl, optionally ssh-wrapped) ───────────────────────────────

const Header = struct { name: []const u8, value: []const u8 };

/// Build the curl argv (incl. "curl"). `h2` adds --http2-prior-knowledge
/// (workers speak h2c; the CP does not). `with_stdin` adds `--data-binary @-`
/// so the body streams over stdin (works through ssh too). Caller owns nothing
/// (all from `a`, an arena).
fn curlArgv(
    a: std.mem.Allocator,
    method: []const u8,
    url: []const u8,
    headers: []const Header,
    h2: bool,
    with_stdin: bool,
    timeout_s: u32,
) [][]const u8 {
    var args = std.ArrayList([]const u8){};
    const push = struct {
        fn p(list: *std.ArrayList([]const u8), alloc: std.mem.Allocator, s: []const u8) void {
            list.append(alloc, s) catch oom();
        }
    }.p;
    push(&args, a, "curl");
    push(&args, a, "-sS");
    push(&args, a, "--max-time");
    push(&args, a, std.fmt.allocPrint(a, "{d}", .{timeout_s}) catch oom());
    push(&args, a, "-w");
    push(&args, a, "\n%{http_code}");
    if (h2) push(&args, a, "--http2-prior-knowledge");
    push(&args, a, "-X");
    push(&args, a, method);
    push(&args, a, url);
    for (headers) |hdr| {
        push(&args, a, "-H");
        push(&args, a, std.fmt.allocPrint(a, "{s}: {s}", .{ hdr.name, hdr.value }) catch oom());
    }
    if (with_stdin) {
        push(&args, a, "--data-binary");
        push(&args, a, "@-");
    }
    return args.items;
}

/// POSIX single-quote a shell word.
fn shellQuote(a: std.mem.Allocator, word: []const u8) []const u8 {
    var out = std.ArrayList(u8){};
    out.append(a, '\'') catch oom();
    for (word) |c| {
        if (c == '\'') {
            out.appendSlice(a, "'\\''") catch oom();
        } else {
            out.append(a, c) catch oom();
        }
    }
    out.append(a, '\'') catch oom();
    return out.items;
}

/// Wrap curl argv for the configured transport: direct, or `ssh <target>
/// "<curl shell string>"` when ROVE_PUBLISH_SSH is set.
fn transportArgv(a: std.mem.Allocator, env: *const Env, curl_args: [][]const u8) [][]const u8 {
    const ssh_target = env.get("ROVE_PUBLISH_SSH");
    if (ssh_target == null or ssh_target.?.len == 0) return curl_args;

    var remote = std.ArrayList(u8){};
    for (curl_args, 0..) |arg, i| {
        if (i != 0) remote.append(a, ' ') catch oom();
        remote.appendSlice(a, shellQuote(a, arg)) catch oom();
    }
    var argv = std.ArrayList([]const u8){};
    argv.append(a, "ssh") catch oom();
    argv.append(a, "-o") catch oom();
    argv.append(a, "BatchMode=yes") catch oom();
    argv.append(a, ssh_target.?) catch oom();
    argv.append(a, remote.items) catch oom();
    return argv.items;
}

fn writeStdin(file: std.fs.File, data: []const u8) void {
    defer file.close();
    file.writeAll(data) catch {};
}

/// Spawn `argv`, optionally feed `stdin_data` (via a writer thread to avoid a
/// pipe deadlock on large bodies), capture stdout, and split the trailing
/// `\n<http_code>` that `-w` appended.
fn run(a: std.mem.Allocator, argv: [][]const u8, stdin_data: ?[]const u8) Resp {
    var child = std.process.Child.init(argv, a);
    child.stdin_behavior = if (stdin_data != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    child.spawn() catch |err| fatal("spawn {s} failed: {s}", .{ argv[0], @errorName(err) });

    var writer: ?std.Thread = null;
    if (stdin_data) |d| {
        const f = child.stdin.?;
        child.stdin = null; // writer thread owns + closes it; keep wait() off it
        writer = std.Thread.spawn(.{}, writeStdin, .{ f, d }) catch |err|
            fatal("stdin thread failed: {s}", .{@errorName(err)});
    }

    var out = std.ArrayList(u8){};
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = child.stdout.?.read(&buf) catch break;
        if (n == 0) break;
        out.appendSlice(a, buf[0..n]) catch oom();
    }
    if (writer) |t| t.join();
    _ = child.wait() catch |err| fatal("wait {s} failed: {s}", .{ argv[0], @errorName(err) });

    const body = out.items;
    const nl = std.mem.lastIndexOfScalar(u8, body, '\n') orelse
        return .{ .code = 0, .body = body };
    const code = std.fmt.parseInt(u32, std.mem.trim(u8, body[nl + 1 ..], " \t\r"), 10) catch 0;
    return .{ .code = code, .body = body[0..nl] };
}

/// POST to a worker (h2c) and return the response. Body is optional.
fn workerPost(
    a: std.mem.Allocator,
    env: *const Env,
    worker: []const u8,
    path: []const u8,
    headers: []const Header,
    body: ?[]const u8,
    timeout_s: u32,
) Resp {
    const url = std.fmt.allocPrint(a, "{s}{s}", .{ worker, path }) catch oom();
    const curl = curlArgv(a, "POST", url, headers, true, body != null, timeout_s);
    return run(a, transportArgv(a, env, curl), body);
}

// ── JSON ────────────────────────────────────────────────────────────────

fn writeJsonString(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) void {
    out.append(a, '"') catch oom();
    for (s) |c| switch (c) {
        '"' => out.appendSlice(a, "\\\"") catch oom(),
        '\\' => out.appendSlice(a, "\\\\") catch oom(),
        '\n' => out.appendSlice(a, "\\n") catch oom(),
        '\r' => out.appendSlice(a, "\\r") catch oom(),
        '\t' => out.appendSlice(a, "\\t") catch oom(),
        else => if (c < 0x20) {
            out.appendSlice(a, std.fmt.allocPrint(a, "\\u{x:0>4}", .{c}) catch oom()) catch oom();
        } else out.append(a, c) catch oom(),
    };
    out.append(a, '"') catch oom();
}

/// Pull a hex `dep_id` out of a `{"ok":true,"dep_id":"<hex>"}` body without a
/// full JSON parse (the only field we need).
fn extractDepId(a: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const key = "\"dep_id\"";
    const ki = std.mem.indexOf(u8, body, key) orelse return null;
    var i = ki + key.len;
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '"')) : (i += 1) {}
    const start = i;
    while (i < body.len and body[i] != '"' and body[i] != ',' and body[i] != '}') : (i += 1) {}
    if (i == start) return null;
    return a.dupe(u8, std.mem.trim(u8, body[start..i], " ")) catch oom();
}

// ── bundle classification (mirrors publish_tenant.py / the old classify) ────

const Handler = struct { path: []const u8, source: []const u8 };
const Static = struct { path: []const u8, content_type: []const u8, b64: []const u8 };

const Bundle = struct {
    handlers: []Handler,
    statics: []Static,
    skipped: [][]const u8,
};

fn contentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const map = .{
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".svg", "image/svg+xml" },
        .{ ".wasm", "application/wasm" },
        .{ ".png", "image/png" },
        .{ ".ico", "image/x-icon" },
        .{ ".woff2", "font/woff2" },
    };
    inline for (map) |pair| {
        if (std.mem.eql(u8, ext, pair[0])) return pair[1];
    }
    return "application/octet-stream";
}

fn classify(a: std.mem.Allocator, bundle_path: []const u8) Bundle {
    var dir = std.fs.cwd().openDir(bundle_path, .{ .iterate = true }) catch |err|
        fatal("{s}: not a readable directory ({s})", .{ bundle_path, @errorName(err) });
    defer dir.close();

    var handlers = std.ArrayList(Handler){};
    var statics = std.ArrayList(Static){};
    var skipped = std.ArrayList([]const u8){};

    var walker = dir.walk(a) catch oom();
    defer walker.deinit();
    while (walker.next() catch |err| fatal("walk {s}: {s}", .{ bundle_path, @errorName(err) })) |entry| {
        if (entry.kind != .file) continue;
        // entry.path is OS-separated; normalize to posix '/'.
        const rel = a.dupe(u8, entry.path) catch oom();
        std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');

        const full = std.fs.path.join(a, &.{ bundle_path, entry.path }) catch oom();
        const bytes = std.fs.cwd().readFileAlloc(a, full, 64 << 20) catch |err|
            fatal("read {s}: {s}", .{ full, @errorName(err) });

        if (std.mem.startsWith(u8, rel, "_static/") or std.mem.startsWith(u8, rel, "_config/")) {
            const enc = std.base64.standard.Encoder;
            const b64 = a.alloc(u8, enc.calcSize(bytes.len)) catch oom();
            _ = enc.encode(b64, bytes);
            statics.append(a, .{ .path = rel, .content_type = contentType(rel), .b64 = b64 }) catch oom();
        } else if (std.mem.eql(u8, rel, "codemirror-entry.mjs")) {
            skipped.append(a, rel) catch oom();
        } else if (std.mem.endsWith(u8, rel, ".mjs")) {
            handlers.append(a, .{ .path = rel, .source = bytes }) catch oom();
        } else {
            skipped.append(a, rel) catch oom();
        }
    }
    // Deterministic order (walk order is arbitrary).
    std.mem.sort(Handler, handlers.items, {}, struct {
        fn lt(_: void, x: Handler, y: Handler) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    std.mem.sort(Static, statics.items, {}, struct {
        fn lt(_: void, x: Static, y: Static) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    return .{ .handlers = handlers.items, .statics = statics.items, .skipped = skipped.items };
}

/// Encode the deploy-app wire body: {tenant, handlers:[{path,source}],
/// statics:[{path,content_type,b64}]}.
fn deployBody(a: std.mem.Allocator, tenant: []const u8, b: Bundle) []const u8 {
    var out = std.ArrayList(u8){};
    out.appendSlice(a, "{\"tenant\":") catch oom();
    writeJsonString(&out, a, tenant);
    out.appendSlice(a, ",\"handlers\":[") catch oom();
    for (b.handlers, 0..) |h, i| {
        if (i != 0) out.append(a, ',') catch oom();
        out.appendSlice(a, "{\"path\":") catch oom();
        writeJsonString(&out, a, h.path);
        out.appendSlice(a, ",\"source\":") catch oom();
        writeJsonString(&out, a, h.source);
        out.append(a, '}') catch oom();
    }
    out.appendSlice(a, "],\"statics\":[") catch oom();
    for (b.statics, 0..) |s, i| {
        if (i != 0) out.append(a, ',') catch oom();
        out.appendSlice(a, "{\"path\":") catch oom();
        writeJsonString(&out, a, s.path);
        out.appendSlice(a, ",\"content_type\":") catch oom();
        writeJsonString(&out, a, s.content_type);
        out.appendSlice(a, ",\"b64\":") catch oom();
        writeJsonString(&out, a, s.b64);
        out.append(a, '}') catch oom();
    }
    out.appendSlice(a, "]}") catch oom();
    return out.items;
}

// ── commands ────────────────────────────────────────────────────────────

fn authHeaders(a: std.mem.Allocator, env: *const Env) []const Header {
    const rt = env.require("REWIND_ROOT_TOKEN");
    const admin = env.require("REWIND_ADMIN_DOMAIN");
    const hs = a.alloc(Header, 3) catch oom();
    hs[0] = .{ .name = "Host", .value = admin };
    hs[1] = .{ .name = "Authorization", .value = std.fmt.allocPrint(a, "Bearer {s}", .{rt}) catch oom() };
    hs[2] = .{ .name = "Content-Type", .value = "application/json" };
    return hs;
}

/// POST /_system/reset on each worker until one accepts (leader-gated → a
/// follower 503s). Returns the deployed dep_id.
fn cmdReset(a: std.mem.Allocator, env: *const Env) []const u8 {
    const headers = authHeaders(a, env);
    for (workerUrls(env, a)) |w| {
        const r = workerPost(a, env, w, "/_system/reset", headers, null, 60);
        if (r.code == 200) {
            const dep = extractDepId(a, r.body) orelse fatal("reset: 200 but no dep_id: {s}", .{r.body});
            std.debug.print("reset: deploy app live on __admin__ — dep_id={s}\n", .{dep});
            return dep;
        }
        std.debug.print("  reset via {s}: {d} {s} (trying next)\n", .{ w, r.code, trunc(r.body) });
    }
    fatal("/_system/reset failed on every worker", .{});
}

/// Provision a tenant via the CP control plane (X-Rewind-Move-Secret). 204 =
/// placed, 409 = already placed (both fine).
fn cpProvision(a: std.mem.Allocator, env: *const Env, tenant: []const u8, host: []const u8) void {
    const cp = env.get("ROVE_CP_URL_INTERNAL") orelse fatal("bootstrap needs ROVE_CP_URL_INTERNAL", .{});
    const ms = env.require("REWIND_MOVE_SECRET");
    const cluster = env.get("ROVE_CLUSTER") orelse "prod";
    const headers = [_]Header{
        .{ .name = "X-Rewind-Move-Secret", .value = ms },
        .{ .name = "Content-Type", .value = "application/json" },
    };
    // {tenant, cluster, host} — host populates the CP host→tenant index so the
    // front door can route the tenant's domain (CP §handleProvision).
    const body = std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\",\"cluster\":\"{s}\",\"host\":\"{s}\"}}", .{ tenant, cluster, host }) catch oom();
    const url = std.fmt.allocPrint(a, "{s}/_control/provision", .{cp}) catch oom();
    // V2 control plane + workers are h2c (prior-knowledge) — same as the workers.
    const curl = curlArgv(a, "POST", url, &headers, true, true, 30);
    const r = run(a, transportArgv(a, env, curl), body);
    switch (r.code) {
        204 => std.debug.print("provisioned {s}\n", .{tenant}),
        409 => std.debug.print("{s} already placed (409) — continuing\n", .{tenant}),
        else => fatal("provision {s}: {d} {s}", .{ tenant, r.code, trunc(r.body) }),
    }
}

fn cmdBootstrap(a: std.mem.Allocator, env: *const Env) void {
    cpProvision(a, env, "__admin__", env.require("REWIND_ADMIN_DOMAIN"));
    _ = cmdReset(a, env);
    std.debug.print("bootstrap complete — deploy capability live; publish apps with `rewind deploy`\n", .{});
}

/// POST the classified bundle to the standing __admin__ deploy app. Deploy is
/// not raft-gated (blob + manifest PUTs are S3, any node), so any worker that
/// answers 200 is fine.
fn cmdDeploy(a: std.mem.Allocator, env: *const Env, tenant: []const u8, bundle_path: []const u8, release: bool) void {
    const b = classify(a, bundle_path);
    if (b.skipped.len != 0) {
        std.debug.print("  ! skipping (build source / non-deployable): ", .{});
        for (b.skipped, 0..) |s, i| std.debug.print("{s}{s}", .{ if (i != 0) ", " else "", s });
        std.debug.print("\n", .{});
    }
    if (b.handlers.len == 0 and b.statics.len == 0) fatal("bundle {s} has nothing to publish", .{bundle_path});
    std.debug.print("bundle: {d} handler(s), {d} static(s)\n", .{ b.handlers.len, b.statics.len });

    const body = deployBody(a, tenant, b);
    const headers = authHeaders(a, env);
    var dep: ?[]const u8 = null;
    for (workerUrls(env, a)) |w| {
        const r = workerPost(a, env, w, "/", headers, body, 120);
        if (r.code == 200) {
            dep = extractDepId(a, r.body) orelse fatal("deploy: 200 but no dep_id: {s}", .{r.body});
            break;
        }
        std.debug.print("  deploy via {s}: {d} {s} (trying next)\n", .{ w, r.code, trunc(r.body) });
    }
    const dep_id = dep orelse fatal("deploy failed on every worker", .{});
    std.debug.print("deployment staged: {s} ({d} file(s)) — NOT released\n", .{ dep_id, b.handlers.len + b.statics.len });

    if (release) cmdRelease(a, env, tenant, dep_id);
}

/// Flip _deploy/current via /_system/release. Leader-gated → 6× round-robin
/// retry while group leadership settles (transient 503/421 are normal).
fn cmdRelease(a: std.mem.Allocator, env: *const Env, tenant: []const u8, dep_id: []const u8) void {
    const headers = authHeaders(a, env);
    // /_system/release wants the dep_id as a NUMBER; dep_id is hex from the app.
    const dep_num = std.fmt.parseInt(u64, dep_id, 16) catch fatal("bad dep_id {s}", .{dep_id});
    const body = std.fmt.allocPrint(a, "{{\"tenant_id\":\"{s}\",\"dep_id\":{d}}}", .{ tenant, dep_num }) catch oom();
    const workers = workerUrls(env, a);
    var attempt: usize = 0;
    while (attempt < 6) : (attempt += 1) {
        for (workers) |w| {
            const r = workerPost(a, env, w, "/_system/release", headers, body, 30);
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

fn trunc(s: []const u8) []const u8 {
    return s[0..@min(s.len, 200)];
}

// ── arg parsing + dispatch ──────────────────────────────────────────────

const usage =
    \\rewind — operator CLI (docs/rewind-cli-plan.md)
    \\
    \\usage:
    \\  rewind reset                              (re)deploy the baked __admin__ deploy app
    \\  rewind bootstrap                          provision __admin__ + reset (virgin cluster)
    \\  rewind deploy <tenant> <bundle> [--release]   publish a bundle through the app
    \\  rewind release <tenant> <dep_id_hex>      flip _deploy/current live
    \\
    \\options:
    \\  --env <path>     operator env file (default ~/.config/rove/prod.env, then ./.env.prod)
    \\
;

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

    // Pull out --env and collect positionals + flags.
    var env_path: ?[]const u8 = null;
    var release = false;
    var pos = std.ArrayList([]const u8){};
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--env")) {
            i += 1;
            if (i >= argv.len) fatal("--env needs a path", .{});
            env_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--release")) {
            release = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else {
            pos.append(a, arg) catch oom();
        }
    }
    if (env_path == null) env_path = defaultEnvPath(a);

    var env = loadEnv(gpa, env_path);
    defer env.deinit();

    const cmd = argv[1];
    if (std.mem.eql(u8, cmd, "reset")) {
        _ = cmdReset(a, &env);
    } else if (std.mem.eql(u8, cmd, "bootstrap")) {
        cmdBootstrap(a, &env);
    } else if (std.mem.eql(u8, cmd, "deploy")) {
        if (pos.items.len < 2) fatal("deploy needs <tenant> <bundle>", .{});
        cmdDeploy(a, &env, pos.items[0], pos.items[1], release);
    } else if (std.mem.eql(u8, cmd, "release")) {
        if (pos.items.len < 2) fatal("release needs <tenant> <dep_id_hex>", .{});
        cmdRelease(a, &env, pos.items[0], pos.items[1]);
    } else if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
        std.debug.print("{s}", .{usage});
    } else {
        fatal("unknown command '{s}'\n{s}", .{ cmd, usage });
    }
}
