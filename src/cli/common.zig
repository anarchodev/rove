//! Shared infrastructure for the rewind operator CLIs (`rewind-ops` now; the
//! OIDC-scoped customer `rewind` later). The split is by credential/audience
//! (docs/rewind-cli-plan.md §6): platform verbs that carry root +
//! move-secret + ops-secret live in `rewind-ops`; tenant verbs that carry an
//! OIDC session will live in `rewind`. This module is the credential-agnostic
//! core both reuse: operator env loader, curl/ssh transport, JSON helpers, and
//! the bundle classifier. std-only — no rove modules, no system libs.

const std = @import("std");

pub const Resp = struct { code: u32, body: []u8 };
pub const Header = struct { name: []const u8, value: []const u8 };

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("rewind: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn oom() noreturn {
    fatal("out of memory", .{});
}

pub fn trunc(s: []const u8) []const u8 {
    return s[0..@min(s.len, 200)];
}

// ── config ──────────────────────────────────────────────────────────────

pub const Env = struct {
    map: std.StringHashMap([]const u8),
    arena: std.heap.ArenaAllocator,

    pub fn get(self: *const Env, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn require(self: *const Env, key: []const u8) []const u8 {
        return self.map.get(key) orelse fatal("missing required config var: {s}", .{key});
    }

    pub fn deinit(self: *Env) void {
        self.arena.deinit();
    }
};

/// The operator env vars the CLIs overlay from the OS environment (so they
/// override the file, and smokes can run without a file).
const OVERLAY_VARS = [_][]const u8{
    "REWIND_ROOT_TOKEN", "REWIND_ADMIN_DOMAIN", "ROVE_WORKER_URLS",
    "ROVE_PUBLISH_SSH",  "ROVE_CP_URL_INTERNAL", "REWIND_MOVE_SECRET",
    "ADMIN_OPS_SECRET",  "ROVE_CLUSTER",
};

/// Default operator env path: $XDG_CONFIG_HOME/rove/prod.env (or
/// ~/.config/rove/prod.env), legacy fallback ./.env.prod.
pub fn defaultEnvPath(arena: std.mem.Allocator) ?[]const u8 {
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
    std.fs.cwd().access(".env.prod", .{}) catch return null;
    return arena.dupe(u8, ".env.prod") catch null;
}

/// Load the env file (if present) then overlay matching OS env vars. Every
/// stored value is owned by the returned Env's arena.
pub fn loadEnv(gpa: std.mem.Allocator, env_path: ?[]const u8) Env {
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
    for (OVERLAY_VARS) |k| {
        if (std.process.getEnvVarOwned(a, k) catch null) |v| {
            map.put(a.dupe(u8, k) catch oom(), v) catch oom();
        }
    }
    return .{ .map = map, .arena = arena };
}

pub fn workerUrls(env: *const Env, a: std.mem.Allocator) [][]const u8 {
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

// ── transport (curl, optionally ssh-wrapped) ──────────────────────────────

/// Build the curl argv (incl. "curl"). `h2` adds --http2-prior-knowledge
/// (V2 is h2c everywhere — workers AND the CP). `with_stdin` adds
/// `--data-binary @-` so the body streams over stdin (works through ssh too).
pub fn curlArgv(
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
pub fn shellQuote(a: std.mem.Allocator, word: []const u8) []const u8 {
    var out = std.ArrayList(u8){};
    out.append(a, '\'') catch oom();
    for (word) |c| {
        if (c == '\'') out.appendSlice(a, "'\\''") catch oom() else out.append(a, c) catch oom();
    }
    out.append(a, '\'') catch oom();
    return out.items;
}

/// Wrap curl argv for the configured transport: direct, or `ssh <target>
/// "<curl shell string>"` when ROVE_PUBLISH_SSH is set+non-empty.
pub fn transportArgv(a: std.mem.Allocator, env: *const Env, curl_args: [][]const u8) [][]const u8 {
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

/// Spawn `argv`, optionally feed `stdin_data` (via a writer thread to dodge a
/// pipe deadlock on large bodies), capture stdout, and split the trailing
/// `\n<http_code>` that `-w` appended.
pub fn run(a: std.mem.Allocator, argv: [][]const u8, stdin_data: ?[]const u8) Resp {
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
    const nl = std.mem.lastIndexOfScalar(u8, body, '\n') orelse return .{ .code = 0, .body = body };
    const code = std.fmt.parseInt(u32, std.mem.trim(u8, body[nl + 1 ..], " \t\r"), 10) catch 0;
    return .{ .code = code, .body = body[0..nl] };
}

/// POST/GET an absolute URL (h2c, transport-wrapped). Body optional.
pub fn call(
    a: std.mem.Allocator,
    env: *const Env,
    method: []const u8,
    url: []const u8,
    headers: []const Header,
    body: ?[]const u8,
    timeout_s: u32,
) Resp {
    const curl = curlArgv(a, method, url, headers, true, body != null, timeout_s);
    return run(a, transportArgv(a, env, curl), body);
}

/// POST to a worker path (joins {worker}{path}).
pub fn workerPost(a: std.mem.Allocator, env: *const Env, worker: []const u8, path: []const u8, headers: []const Header, body: ?[]const u8, timeout_s: u32) Resp {
    const url = std.fmt.allocPrint(a, "{s}{s}", .{ worker, path }) catch oom();
    return call(a, env, "POST", url, headers, body, timeout_s);
}

/// POST to the CP control plane (move-secret header). Returns the response.
pub fn cpPost(a: std.mem.Allocator, env: *const Env, path: []const u8, body: []const u8, timeout_s: u32) Resp {
    const cp = env.get("ROVE_CP_URL_INTERNAL") orelse fatal("this command needs ROVE_CP_URL_INTERNAL", .{});
    const ms = env.require("REWIND_MOVE_SECRET");
    const headers = [_]Header{
        .{ .name = "X-Rewind-Move-Secret", .value = ms },
        .{ .name = "Content-Type", .value = "application/json" },
    };
    const url = std.fmt.allocPrint(a, "{s}{s}", .{ cp, path }) catch oom();
    return call(a, env, "POST", url, &headers, body, timeout_s);
}

/// GET a CP read path (no auth — internal CP reads). `path` includes the query.
pub fn cpGet(a: std.mem.Allocator, env: *const Env, path: []const u8, timeout_s: u32) Resp {
    const cp = env.get("ROVE_CP_URL_INTERNAL") orelse fatal("this command needs ROVE_CP_URL_INTERNAL", .{});
    const url = std.fmt.allocPrint(a, "{s}{s}", .{ cp, path }) catch oom();
    return call(a, env, "GET", url, &.{}, null, timeout_s);
}

// ── JSON ──────────────────────────────────────────────────────────────────

pub fn writeJsonString(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) void {
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

/// Pull a string field's value out of a flat JSON object without a full parse.
/// Handles `"key":"value"` and `"key":bareword`. Returns an arena-owned copy.
pub fn extractField(a: std.mem.Allocator, body: []const u8, key: []const u8) ?[]const u8 {
    const needle = std.fmt.allocPrint(a, "\"{s}\"", .{key}) catch oom();
    const ki = std.mem.indexOf(u8, body, needle) orelse return null;
    var i = ki + needle.len;
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '"')) : (i += 1) {}
    const start = i;
    while (i < body.len and body[i] != '"' and body[i] != ',' and body[i] != '}') : (i += 1) {}
    if (i == start) return null;
    return a.dupe(u8, std.mem.trim(u8, body[start..i], " ")) catch oom();
}

pub fn extractDepId(a: std.mem.Allocator, body: []const u8) ?[]const u8 {
    return extractField(a, body, "dep_id");
}

// ── bundle classification (mirrors publish_tenant.py) ──────────────────────

pub const Handler = struct { path: []const u8, source: []const u8 };
pub const Static = struct { path: []const u8, content_type: []const u8, b64: []const u8 };
pub const Bundle = struct { handlers: []Handler, statics: []Static, skipped: [][]const u8 };

pub fn contentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const map = .{
        .{ ".mjs", "text/javascript; charset=utf-8" }, .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".html", "text/html; charset=utf-8" },       .{ ".css", "text/css; charset=utf-8" },
        .{ ".json", "application/json" },               .{ ".svg", "image/svg+xml" },
        .{ ".wasm", "application/wasm" },               .{ ".png", "image/png" },
        .{ ".ico", "image/x-icon" },                    .{ ".woff2", "font/woff2" },
    };
    inline for (map) |pair| {
        if (std.mem.eql(u8, ext, pair[0])) return pair[1];
    }
    return "application/octet-stream";
}

pub fn classify(a: std.mem.Allocator, bundle_path: []const u8) Bundle {
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
pub fn deployBody(a: std.mem.Allocator, tenant: []const u8, b: Bundle) []const u8 {
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
