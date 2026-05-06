//! `loop46` CLI: argv parsing, defaults, usage printing.
//!
//! Three entry points consumed by `main`:
//!   - `parseAndFinalize(args, dev)` — full pipeline from argv to a ready Cli
//!   - `printUsage()` — write USAGE to stderr (called from main on error/help)
//!   - `defaultLoop46DataDir(allocator)` — also used by `tls_dev`

const std = @import("std");

pub const MAX_BOOTSTRAP_KV: usize = 32;

pub const Cli = struct {
    node_id: u32 = 0,
    /// Comma-separated `host:port` list. Position determines node_id.
    peers: []const u8 = "127.0.0.1:40100",
    /// `host:port` this node listens on for raft RPCs. Must match the
    /// peers entry at index `node_id`.
    listen: []const u8 = "127.0.0.1:40100",
    /// HTTP/2 listen address (all workers share this via SO_REUSEPORT).
    http: []const u8 = "127.0.0.1:8082",
    /// Per-node data directory. Each node MUST have a unique dir.
    data_dir: []const u8 = "/tmp/rove-js-data",
    /// If true, wipe the data dir before starting (smoke-test mode).
    fresh: bool = false,
    /// Hex-encoded 256-bit root token. When set, the worker installs
    /// it into the tenant root store at startup; any subsequent
    /// `/_system/*` request must carry this token in an
    /// `Authorization: Bearer <hex>` header.
    bootstrap_root_token: ?[]const u8 = null,
    /// Generic seed-into-admin's-app.db config pairs. Each pair is
    /// the raw `key=value` argv string; bootstrap splits at the
    /// first `=` and writes to admin's kv before workers start
    /// serving. Replaces the older typed flags
    /// (`--bootstrap-resend-key`, `--platform-email-from`) so Zig
    /// no longer enumerates which config keys exist — admin's JS
    /// handler reads whatever it cares about via `kv.get`.
    bootstrap_kv: [MAX_BOOTSTRAP_KV][]const u8 = undefined,
    bootstrap_kv_count: usize = 0,
    /// Number of worker threads. Each owns its own Registry/Io/H2/
    /// Tenant/Dispatcher and binds the same HTTP/2 port via
    /// SO_REUSEPORT. Defaults to the number of online CPUs.
    workers: u16 = 0,
    /// Origin allowed to call `/_system/*` with CORS. When set, the
    /// worker responds to preflight (OPTIONS) requests from this
    /// origin and adds `Access-Control-Allow-*` headers to all
    /// `/_system/*` responses. Required for the browser admin UI in
    /// dev (typically `http://localhost:5173`) and prod (e.g.
    /// `https://admin.example.com`). Unset = no CORS, and the admin
    /// UI must be served same-origin or go through a proxy.
    admin_origin: ?[]const u8 = null,
    /// Hostname of the admin API + dashboard. Auto-derived to
    /// `app.{public_suffix}` when only `--public-suffix` is passed
    /// (the common case); this flag is the escape hatch for serving
    /// admin on a non-`app.` host.
    ///
    /// When set, any request whose Host matches `admin_api_domain`
    /// runs the `__admin__` tenant's handler. `kv` defaults to
    /// `__admin__`'s own app.db; an `X-Rove-Scope: <id>` header
    /// rebinds `kv` onto `<id>`'s store for cross-tenant browsing.
    /// Requires a root bearer token (or session cookie minted via
    /// `/v1/login`).
    admin_api_domain: ?[]const u8 = null,
    /// Wildcard customer-app suffix. Enables `{id}.{public_suffix}` →
    /// instance `{id}` resolution without needing `assignDomain` per
    /// tenant. Explicit domain aliases still win.
    ///
    /// Also drives the default `admin_api_domain` (`app.{public_suffix}`).
    /// Example: `--public-suffix loop46.me` →
    /// admin at `app.loop46.me`, customers at `{id}.loop46.me`.
    public_suffix: ?[]const u8 = null,
    /// TLS certificate path (PEM, full chain). When both this and
    /// `tls_key` are set, the `--http` listener speaks HTTPS (h2 over
    /// TLS) instead of plaintext h2c. Changes to either file on disk
    /// are picked up on a periodic mtime check, so cert renewal by a
    /// sidecar (e.g. scripts/rove-lego-renew.sh) reloads in-process
    /// without a restart.
    tls_cert: ?[]const u8 = null,
    /// TLS private key path (PEM). See `tls_cert`.
    tls_key: ?[]const u8 = null,
    /// Raft proposal linger budget, in microseconds. Hold pending
    /// proposals up to this long so the raft thread can pack more
    /// into a single `raft_log.db` commit + fsync. Under heavy write
    /// load at multi-worker scale, the raft thread's per-tick fsync
    /// is the single hard ceiling on write throughput — every
    /// writeset funnels through one raft log regardless of how many
    /// dispatch workers are running. Trading a few hundred µs of
    /// commit latency for a 3–5× write throughput lift is usually
    /// worth it. 0 disables linger (every tick commits whatever it
    /// has). Mapped directly to `RaftNodeConfig.propose_linger_ns`
    /// at init time.
    propose_linger_us: u64 = 500,
    /// How often each tenant's `deployment/current` is polled for
    /// changes. Low values make new deploys visible fast (good for
    /// tests); high values reduce per-tenant kv work. Mapped onto
    /// `WorkerConfig.refresh_interval_ns`. 0 means "every tick".
    refresh_interval_ms: u32 = 2000,
    /// **DEV-ONLY.** Relax the outbox drainer's SSRF block on
    /// loopback (`127/8`, `::1`) and accept `http://` webhook URLs.
    /// Intended for local smoke tests against an on-box HTTP echo
    /// server. Never set this in production — it lets a malicious
    /// customer handler probe localhost and leaks request bodies
    /// over plaintext. Startup emits a loud warning when enabled.
    dev_webhook_unsafe: bool = false,
    /// Phase 5.5 (d), step 4. `drainer` (default) keeps the legacy
    /// per-tenant `_outbox/{id}` + drainer-thread path intact.
    /// `direct` switches `webhook.send` to the new path: per-batch
    /// accumulator → multi-envelope (writeset + webhook batch) →
    /// raft → webhook-server thread. Both modes coexist during
    /// rollout; step 5 makes `direct` the only option.
    webhook_path: []const u8 = "drainer",
    /// **Local-dev convenience flag.** When set, the worker uses
    /// mkcert-issued TLS at the platform-default loop46 data dir
    /// (see `defaultDevTlsPaths`). On first run, if the cert is
    /// missing, the binary auto-bootstraps via mkcert (registers
    /// the local CA, generates the cert, symlinks the rootCA path)
    /// and continues. mkcert must be installed; missing → fail
    /// loudly with install hints. Per the "h2+TLS everywhere even
    /// in dev" stake-in-the-ground, `--dev` mode does NOT fall back
    /// to plaintext h2c — it's TLS or fail.
    ///
    /// Has no effect in production — explicit `--tls-cert` /
    /// `--tls-key` always win, and the unset case (no `--dev`)
    /// keeps the existing plaintext h2c behavior used by the
    /// smoke scripts.
    dev: bool = false,
    /// Per-(instance, action) rate limit caps. Defaults match
    /// `limiter.RateLimitCaps`'s defaults; flags below let
    /// operators tune them at launch + smoke tests dial them
    /// down to small values to provoke 429s in a few requests.
    rate_limit_request_capacity: u32 = 100,
    rate_limit_request_refill: u32 = 50,
    rate_limit_email_capacity: u32 = 10,
    rate_limit_email_refill: u32 = 1,
};

pub fn parseCli(args: []const [:0]u8) !Cli {
    var out: Cli = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--node-id")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.node_id = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--peers")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.peers = args[i];
        } else if (std.mem.eql(u8, a, "--listen")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.listen = args[i];
        } else if (std.mem.eql(u8, a, "--http")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.http = args[i];
        } else if (std.mem.eql(u8, a, "--data-dir")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.data_dir = args[i];
        } else if (std.mem.eql(u8, a, "--fresh")) {
            out.fresh = true;
        } else if (std.mem.eql(u8, a, "--bootstrap-root-token")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.bootstrap_root_token = args[i];
        } else if (std.mem.eql(u8, a, "--bootstrap-kv")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            if (out.bootstrap_kv_count >= MAX_BOOTSTRAP_KV) {
                std.debug.print(
                    "error: too many --bootstrap-kv flags (max {d})\n",
                    .{MAX_BOOTSTRAP_KV},
                );
                return error.Usage;
            }
            // The argv slice survives for the lifetime of the binary;
            // store the raw `key=value` string and split at use site.
            out.bootstrap_kv[out.bootstrap_kv_count] = args[i];
            out.bootstrap_kv_count += 1;
        } else if (std.mem.eql(u8, a, "--workers")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.workers = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, a, "--admin-origin")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.admin_origin = args[i];
        } else if (std.mem.eql(u8, a, "--admin-api-domain")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.admin_api_domain = args[i];
        } else if (std.mem.eql(u8, a, "--public-suffix")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.public_suffix = args[i];
        } else if (std.mem.eql(u8, a, "--tls-cert")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.tls_cert = args[i];
        } else if (std.mem.eql(u8, a, "--tls-key")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.tls_key = args[i];
        } else if (std.mem.eql(u8, a, "--propose-linger-us")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.propose_linger_us = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--refresh-interval-ms")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.refresh_interval_ms = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--dev-webhook-unsafe")) {
            out.dev_webhook_unsafe = true;
        } else if (std.mem.eql(u8, a, "--webhook-path")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.webhook_path = args[i];
            if (!std.mem.eql(u8, out.webhook_path, "drainer") and
                !std.mem.eql(u8, out.webhook_path, "direct"))
            {
                std.debug.print(
                    "error: --webhook-path must be 'drainer' or 'direct' (got '{s}')\n",
                    .{out.webhook_path},
                );
                return error.Usage;
            }
        } else if (std.mem.eql(u8, a, "--rate-limit-request-capacity")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.rate_limit_request_capacity = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--rate-limit-request-refill")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.rate_limit_request_refill = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--rate-limit-email-capacity")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.rate_limit_email_capacity = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--rate-limit-email-refill")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.rate_limit_email_refill = try std.fmt.parseInt(u32, args[i], 10);
        } else {
            return error.Usage;
        }
    }
    return out;
}

/// Resolve the default loop46 data directory for the current OS.
/// Mirrors mkcert's convention so devs who already know mkcert
/// recognize the layout.
///
///   Linux:   ${XDG_DATA_HOME:-$HOME/.local/share}/loop46
///   macOS:   $HOME/Library/Application Support/loop46
///   other:   XDG default (best effort)
///
/// Returned slice is owned by the caller.
pub fn defaultLoop46DataDir(allocator: std.mem.Allocator) ![]u8 {
    const builtin = @import("builtin");
    const home = std.posix.getenv("HOME") orelse "";

    if (builtin.os.tag == .macos) {
        return std.fmt.allocPrint(allocator, "{s}/Library/Application Support/loop46", .{home});
    }

    if (std.posix.getenv("XDG_DATA_HOME")) |xdg| {
        if (xdg.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/loop46", .{xdg});
        }
    }
    return std.fmt.allocPrint(allocator, "{s}/.local/share/loop46", .{home});
}

/// Read or generate a 64-hex-char dev root token. First call writes
/// 32 random bytes hex-encoded to `<dir>/dev-root-token` (mode 0600);
/// subsequent calls read the same file so the operator's curl /
/// browser sessions keep working across worker restarts. Delete the
/// file to "rotate." Returned slice is owned by the caller.
fn resolveDevRootToken(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/dev-root-token", .{dir});
    defer allocator.free(path);

    // Try existing file first.
    if (std.fs.cwd().readFileAlloc(allocator, path, 256)) |existing| {
        defer allocator.free(existing);
        const trimmed = std.mem.trim(u8, existing, " \t\r\n");
        // Sanity bounds: 32-128 ASCII chars per the bootstrap-root-token
        // contract. If the file is corrupt, regenerate rather than fail.
        if (trimmed.len >= 32 and trimmed.len <= 128) {
            return try allocator.dupe(u8, trimmed);
        }
    } else |_| {}

    // Generate 32 random bytes → 64 hex chars.
    var bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    const hex_chars = "0123456789abcdef";
    const hex = try allocator.alloc(u8, 64);
    errdefer allocator.free(hex);
    for (bytes, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0xf];
    }

    // Ensure dir exists, then write with mode 0600 so other local users
    // can't curl-as-admin against this dev box.
    std.fs.cwd().makePath(dir) catch {};
    const file = try std.fs.cwd().createFile(path, .{ .mode = 0o600 });
    defer file.close();
    try file.writeAll(hex);

    std.log.info("--dev: generated root token, saved to {s} (mode 0600)", .{path});
    return hex;
}

/// Extract the port from a "host:port" string. Returns null if
/// missing or malformed; caller falls back to a sensible default.
pub fn portFromAddr(addr: []const u8) ?u16 {
    const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return null;
    return std.fmt.parseInt(u16, addr[colon + 1 ..], 10) catch null;
}

/// Run after `parseCli`: apply the `--dev` preset (when active), then
/// derive any cli fields the operator left implicit. Each step is a
/// no-op when the corresponding flag was passed explicitly — explicit
/// flags always win.
///
/// `--dev` preset (sets only what makes dev convenient):
///   --public-suffix       → "loop46.localhost"
///   --bootstrap-root-token → read or generate at
///                            <loop46-data-dir>/dev-root-token
///   --admin-origin        → "https://<admin-api-domain>:<port-from-http>"
///
/// Always-on derivations (apply in dev and prod):
///   --admin-api-domain    → "app.{public_suffix}"
///                            (skipped when public_suffix is also unset)
///
/// Mirrors production's `*.loop46.me` layout exactly: admin at
/// `app.loop46.localhost`, customer instances at
/// `{id}.loop46.localhost`. A single 3-label wildcard SAN
/// `*.loop46.localhost` covers both. Per RFC 6761 any subdomain of
/// `localhost` resolves to loopback so no /etc/hosts edits are
/// needed. `app` is in the signup reserved-name list so customers
/// can't claim it as their instance name.
pub fn finalizeCli(allocator: std.mem.Allocator, cli: *Cli) !void {
    if (cli.dev) {
        if (cli.public_suffix == null) {
            cli.public_suffix = "loop46.localhost";
        }
        if (cli.bootstrap_root_token == null) {
            const dir = try defaultLoop46DataDir(allocator);
            defer allocator.free(dir);
            cli.bootstrap_root_token = try resolveDevRootToken(allocator, dir);
        }
    } else {
        // Worker mode requires --public-suffix. Without it, wildcard
        // customer-subdomain resolution is disabled and admin_api_domain
        // can't auto-default to `app.{ps}` either — the worker would
        // listen but be unreachable for any HTTP traffic that hasn't
        // been hand-aliased into root.db. Fail fast so the operator
        // learns about the misconfig at startup, not via empty
        // 404s after a deploy.
        if (cli.public_suffix == null) {
            std.debug.print(
                "error: --public-suffix is required in worker mode " ++
                    "(without it, customer subdomains cannot resolve and " ++
                    "admin_api_domain cannot default to app.{{public-suffix}}).\n" ++
                    "       pass e.g. --public-suffix loop46.me, or use " ++
                    "`loop46 dev` for local quickstart defaults.\n",
                .{},
            );
            return error.Usage;
        }
    }

    if (cli.admin_api_domain == null) {
        if (cli.public_suffix) |ps| {
            cli.admin_api_domain = try std.fmt.allocPrint(
                allocator,
                "app.{s}",
                .{ps},
            );
        }
    }

    if (cli.dev and cli.admin_origin == null and cli.admin_api_domain != null) {
        const port = portFromAddr(cli.http) orelse 8443;
        cli.admin_origin = try std.fmt.allocPrint(
            allocator,
            "https://{s}:{d}",
            .{ cli.admin_api_domain.?, port },
        );
    }
}

pub const USAGE =
    \\usage: loop46 <command> [opts]
    \\
    \\commands:
    \\  dev                         start a local-quickstart worker (TLS via mkcert,
    \\                              dev defaults, persistent root token under
    \\                              the loop46 data dir)
    \\  worker                      start a worker with explicit flags (production)
    \\  seed                        provision tenants from a JSON manifest into
    \\                              an offline data dir (one-shot, run before
    \\                              `loop46 worker`)
    \\  help                        print this message
    \\
    \\seed flags:
    \\  --data-dir <path>           target data dir (will be created if missing)
    \\  --manifest <path>           JSON manifest listing tenants + their files
    \\
    \\common worker flags:
    \\  --node-id <n>               index into --peers (default 0)
    \\  --peers <h:p,h:p,...>       raft peer list (default 127.0.0.1:40100)
    \\  --listen <host:port>        raft RPC listen (default 127.0.0.1:40100)
    \\  --http <host:port>          HTTP/2 listen (default 127.0.0.1:8082)
    \\  --data-dir <path>           per-node data dir (default /tmp/rove-js-data)
    \\  --fresh                     wipe data dir before start
    \\  --bootstrap-root-token HEX  seed the root auth token at startup
    \\  --bootstrap-kv key=value    seed a kv pair into __admin__/app.db at
    \\                              startup. Repeatable. Admin's JS handler
    \\                              reads these via kv.get; well-known keys
    \\                              (defined by admin's deployed bundle, not
    \\                              this binary) include resend_key and
    \\                              platform_email_from.
    \\  --public-suffix <domain>    customer wildcard suffix (e.g. loop46.me).
    \\                              admin host derives to app.<suffix> unless
    \\                              --admin-api-domain overrides
    \\  --tls-cert <path>           PEM cert for h2 TLS (with --tls-key)
    \\  --tls-key  <path>           PEM key  for h2 TLS (with --tls-cert)
    \\  --workers <n>               number of worker threads (default 0 = nCPU - 1)
    \\  --propose-linger-us <n>     raft proposal linger budget in µs (default 500)
    \\  --dev-webhook-unsafe        DEV ONLY: allow http:// + loopback webhook targets
    \\
;

pub fn printUsage() !void {
    var stderr_buf: [1024]u8 = undefined;
    var sw = std.fs.File.stderr().writer(&stderr_buf);
    try sw.interface.writeAll(USAGE);
    try sw.interface.flush();
}

pub fn parseAndFinalize(allocator: std.mem.Allocator, args: []const [:0]u8, dev: bool) !Cli {
    var cli = try parseCli(args);
    cli.dev = dev;
    try finalizeCli(allocator, &cli);
    return cli;
}
