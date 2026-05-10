//! `files-server-standalone` — the production deploy artifact for
//! `rove-files-server`. After Phase 5.5(e) Task #62 the loop46 worker
//! no longer spawns files-server in-process; the operator runs this
//! binary alongside `loop46 worker` and points the worker at it via
//! `--files-public-base`. Both processes share the same JWT secret
//! (`LOOP46_SERVICES_JWT_SECRET`) so tokens minted at the worker's
//! `/_system/services-token` verify here on every request.
//!
//! Required env:
//!   LOOP46_SERVICES_JWT_SECRET   hex-encoded HMAC-SHA256 secret
//!                                shared with the loop46 worker.
//!
//! Optional env (S3 blob backend):
//!   BLOB_BACKEND=s3              + S3_ENDPOINT / S3_REGION /
//!                                S3_BUCKET / AWS_ACCESS_KEY_ID /
//!                                AWS_SECRET_ACCESS_KEY (and optional
//!                                S3_KEY_PREFIX_BASE / S3_USE_TLS).
//!                                Default `fs` reads / writes per
//!                                tenant under `--data-dir`.
//!
//! Usage:
//!   files-server-standalone --data-dir <path> --listen <host:port> \
//!                           [--tls-cert <path> --tls-key <path>] \
//!                           [--cors-origin <origin>]

const std = @import("std");
const cs = @import("rove-files-server");
const blob_mod = @import("rove-blob");
const h2 = @import("rove-h2");
const kv = @import("rove-kv");

const ENV_JWT_SECRET = "LOOP46_SERVICES_JWT_SECRET";

/// Maximum number of `--bootstrap-kv` pairs accepted on the command
/// line. Plenty for typical platform-config use (resend_key,
/// platform_email_from, etc.).
const MAX_BOOTSTRAP_KV: usize = 32;

const Cli = struct {
    data_dir: []const u8 = "/tmp/rove-files-thread",
    listen: []const u8 = "127.0.0.1:0",
    tls_cert: ?[]const u8 = null,
    tls_key: ?[]const u8 = null,
    cors_origin: ?[]const u8 = null,
    max_connections: u32 = 64,
    /// Cluster leader's admin-host URL (e.g.
    /// `https://app.loop46.localhost:8197`). When set, files-server
    /// runs the platform-deploy bootstrap on startup: it ensures the
    /// `__admin__` and `__replay__` tenants have a deployment in S3
    /// and POSTs `/_system/release` to the leader so the
    /// `_deploy/current` pointer lands via raft. Idempotent on warm
    /// S3.
    leader_url: ?[]const u8 = null,
    /// Repeatable `--bootstrap-kv key=value` pairs pushed into
    /// `__admin__/app.db` via the worker's `/_system/admin-kv`
    /// endpoint at platform-bootstrap time. Replaces the worker's
    /// old per-node `--bootstrap-kv` flag (which bypassed raft and
    /// produced inconsistent state across nodes). Requires
    /// `--leader-url`.
    bootstrap_kv: [MAX_BOOTSTRAP_KV][]const u8 = undefined,
    bootstrap_kv_count: usize = 0,

    // ── files-server-OWN raft cluster (production.md #1.0/#1.4) ──
    //
    // Independent from the loop46 worker raft cluster. files-server
    // replicas form their own consensus: manifests live in a
    // raft-replicated KvStore here, durability is via quorum (no S3
    // backstop needed for correctness), DR via a learner replica.
    //
    // Single-node degenerate cluster (--peers <single-self>) is fine
    // for dev. Production wants ≥3 voters + 1 learner.
    //
    // Wire shape: comma-separated `host:port[:voter|:learner]`. Same
    // format the loop46 worker uses; default voter when no mode
    // suffix.
    //
    // Default node_id 0 + a single-self peer entry lets the existing
    // smoke harness keep working (it currently doesn't pass raft
    // args).
    raft_enabled: bool = false,
    raft_node_id: u32 = 0,
    raft_peers: []const u8 = "",
    raft_listen: []const u8 = "",
    raft_election_timeout_ms: u32 = 1000,
    raft_heartbeat_ms: u32 = 200,
    raft_snapshot_interval_ms: u32 = 0,
};

fn usage(stderr: *std.fs.File.Writer) !void {
    try stderr.interface.writeAll(
        \\usage: files-server-standalone --data-dir <path>
        \\                               --listen <host:port>
        \\                               [--tls-cert <path> --tls-key <path>]
        \\                               [--cors-origin <origin>]
        \\                               [--max-connections <N>]
        \\                               [--leader-url <admin-host-url>]
        \\
        \\env (required):
        \\  LOOP46_SERVICES_JWT_SECRET   hex HMAC-SHA256 shared with loop46 worker
        \\  S3_ENDPOINT, S3_REGION, S3_BUCKET, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
        \\
        \\When --leader-url is set, files-server runs a one-time platform-deploy
        \\bootstrap before serving: it ensures __admin__ and __replay__ have a
        \\deployment in S3 and POSTs /_system/release to the leader so the
        \\_deploy/current pointer lands via raft. Idempotent on warm S3.
        \\
    );
    try stderr.interface.flush();
}

fn parseCli(argv: [][:0]u8) !Cli {
    var out: Cli = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--data-dir")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.data_dir = argv[i];
        } else if (std.mem.eql(u8, a, "--listen")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.listen = argv[i];
        } else if (std.mem.eql(u8, a, "--tls-cert")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.tls_cert = argv[i];
        } else if (std.mem.eql(u8, a, "--tls-key")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.tls_key = argv[i];
        } else if (std.mem.eql(u8, a, "--cors-origin")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.cors_origin = argv[i];
        } else if (std.mem.eql(u8, a, "--max-connections")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.max_connections = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--leader-url")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.leader_url = argv[i];
        } else if (std.mem.eql(u8, a, "--bootstrap-kv")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            if (out.bootstrap_kv_count >= MAX_BOOTSTRAP_KV) return error.Usage;
            out.bootstrap_kv[out.bootstrap_kv_count] = argv[i];
            out.bootstrap_kv_count += 1;
        } else if (std.mem.eql(u8, a, "--raft-node-id")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.raft_node_id = try std.fmt.parseInt(u32, argv[i], 10);
            out.raft_enabled = true;
        } else if (std.mem.eql(u8, a, "--raft-peers")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.raft_peers = argv[i];
            out.raft_enabled = true;
        } else if (std.mem.eql(u8, a, "--raft-listen")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.raft_listen = argv[i];
            out.raft_enabled = true;
        } else if (std.mem.eql(u8, a, "--raft-election-timeout-ms")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.raft_election_timeout_ms = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--raft-heartbeat-ms")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.raft_heartbeat_ms = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--raft-snapshot-interval-ms")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.raft_snapshot_interval_ms = try std.fmt.parseInt(u32, argv[i], 10);
        } else {
            return error.Usage;
        }
    }
    if ((out.tls_cert == null) != (out.tls_key == null)) return error.Usage;
    if (out.raft_enabled) {
        if (out.raft_peers.len == 0) {
            std.debug.print("error: --raft-peers required when raft is enabled\n", .{});
            return error.Usage;
        }
        if (out.raft_listen.len == 0) {
            std.debug.print("error: --raft-listen required when raft is enabled\n", .{});
            return error.Usage;
        }
    }
    return out;
}

/// Parse a `--raft-peers` entry. Same `host:port[:voter|:learner]`
/// shape the loop46 worker uses. See
/// `src/loop46/main.zig::parsePeerEntry` for the canonical impl.
fn parsePeerList(allocator: std.mem.Allocator, peers_str: []const u8) ![]kv.RaftPeerAddr {
    var count: usize = 1;
    for (peers_str) |b| if (b == ',') { count += 1; };
    const out = try allocator.alloc(kv.RaftPeerAddr, count);
    errdefer allocator.free(out);

    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, peers_str, ',');
    while (it.next()) |entry| : (idx += 1) {
        // Try `host:port:mode` first; fall back to `host:port`.
        const last_colon = std.mem.lastIndexOfScalar(u8, entry, ':') orelse return error.MalformedPeer;
        const tail = entry[last_colon + 1 ..];
        if (std.fmt.parseInt(u16, tail, 10)) |port| {
            const host = try allocator.dupe(u8, entry[0..last_colon]);
            out[idx] = .{ .host = host, .port = port, .mode = .voter };
        } else |_| {
            const mode: kv.RaftPeerMode = if (std.mem.eql(u8, tail, "voter"))
                .voter
            else if (std.mem.eql(u8, tail, "learner"))
                .learner
            else
                return error.MalformedPeer;
            const head = entry[0..last_colon];
            const port_colon = std.mem.lastIndexOfScalar(u8, head, ':') orelse return error.MalformedPeer;
            const port = try std.fmt.parseInt(u16, head[port_colon + 1 ..], 10);
            const host = try allocator.dupe(u8, head[0..port_colon]);
            out[idx] = .{ .host = host, .port = port, .mode = mode };
        }
    }
    return out;
}

fn parseHostPort(allocator: std.mem.Allocator, hp: []const u8) !std.net.Address {
    const colon = std.mem.lastIndexOfScalar(u8, hp, ':') orelse return error.MalformedHostPort;
    const host = hp[0..colon];
    const port = try std.fmt.parseInt(u16, hp[colon + 1 ..], 10);
    if (std.mem.eql(u8, host, "localhost")) {
        return std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    }
    const host_z = try allocator.dupeZ(u8, host);
    defer allocator.free(host_z);
    return try std.net.Address.parseIp(host_z, port);
}

fn loadJwtSecret(allocator: std.mem.Allocator) ![]u8 {
    const hex = std.process.getEnvVarOwned(allocator, ENV_JWT_SECRET) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.debug.print("error: {s} not set\n", .{ENV_JWT_SECRET});
            std.process.exit(2);
        },
        else => return err,
    };
    defer allocator.free(hex);
    if (hex.len == 0 or hex.len % 2 != 0) {
        std.debug.print("error: {s} must be even-length hex\n", .{ENV_JWT_SECRET});
        std.process.exit(2);
    }
    const bytes = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(bytes);
    _ = std.fmt.hexToBytes(bytes, hex) catch {
        std.debug.print("error: {s} is not valid hex\n", .{ENV_JWT_SECRET});
        std.process.exit(2);
    };
    return bytes;
}

/// Raft thread entry. Drives willemt + the periodic snapshot tick.
/// Stops when `stop_flag` flips. Same shape as
/// `loop46/main.zig::raftThreadMain` but for the files-server
/// cluster.
fn raftThreadMain(
    cluster: *kv.Cluster,
    stop_flag: *std.atomic.Value(bool),
    snapshot_interval_ms: u32,
) void {
    var tick_state: kv.Cluster.TickState = .{};
    const tick_cfg: kv.Cluster.TickConfig = .{
        .interval_ns = @as(i64, snapshot_interval_ms) * std.time.ns_per_ms,
    };

    while (!stop_flag.load(.acquire) and !cluster.raft.stopping.load(.acquire)) {
        const now_ns: i64 = @intCast(std.time.nanoTimestamp());
        cluster.raft.tick(now_ns) catch |err| {
            std.log.warn("files-server raft: tick failed: {s}", .{@errorName(err)});
        };

        if (snapshot_interval_ms > 0) {
            const out = cluster.tickSnapshot(&tick_state, tick_cfg, now_ns) catch |err| blk: {
                std.log.warn("files-server raft: snapshot tick failed: {s}", .{@errorName(err)});
                break :blk null;
            };
            if (out) |t| {
                std.log.info(
                    "files-server snapshot tick apply_position={d} stamped_stores={d} duration_ms={d}",
                    .{ t.apply_position, t.stamped_stores, t.duration_ms },
                );
            }
        }

        std.Thread.sleep(std.time.ns_per_ms);
    }
    cluster.raft.drainPending(2 * std.time.ns_per_s) catch {};
}

fn loadBlobBackend(allocator: std.mem.Allocator) !blob_mod.BlobBackendOwned {
    return blob_mod.env.loadFromEnv(allocator) catch |err| switch (err) {
        blob_mod.env.LoadError.OutOfMemory => return error.OutOfMemory,
        else => |e| {
            const name = blob_mod.env.errorEnvName(e) orelse "<unknown>";
            std.debug.print(
                "error: S3 blob backend requires {s} to be set\n",
                .{name},
            );
            std.process.exit(2);
        },
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var stderr_buf: [256]u8 = undefined;
    var stderr_w = std.fs.File.stderr().writer(&stderr_buf);
    const cli = parseCli(argv) catch {
        usage(&stderr_w) catch {};
        std.process.exit(2);
    };

    std.fs.cwd().makePath(cli.data_dir) catch {};

    const jwt_secret = try loadJwtSecret(allocator);
    defer allocator.free(jwt_secret);

    var blob_owned = try loadBlobBackend(allocator);
    defer blob_owned.deinit(allocator);

    var tls_config: ?*h2.TlsConfig = null;
    defer if (tls_config) |c| c.destroy();
    if (cli.tls_cert) |cert| {
        tls_config = h2.TlsConfig.createFromFiles(allocator, cert, cli.tls_key.?) catch |err| {
            std.debug.print("error: tls: {s} (cert={s}, key={s})\n", .{ @errorName(err), cert, cli.tls_key.? });
            std.process.exit(2);
        };
        std.log.info("tls: loaded {s} + {s}", .{ cert, cli.tls_key.? });
    }

    const listen_addr = parseHostPort(allocator, cli.listen) catch |err| {
        std.debug.print("error: --listen {s}: {s}\n", .{ cli.listen, @errorName(err) });
        std.process.exit(2);
    };

    // ── Optional raft cluster (production.md #1.0/#1.4) ───────
    //
    // When --raft-* args are passed, files-server-standalone
    // brings up its OWN raft consensus group (independent of the
    // loop46 worker cluster). Manifests will eventually move into
    // raft-replicated KvStores managed via this Cluster — for now
    // it stands up alongside the existing HTTP path but doesn't
    // yet feed manifest writes through it. See
    // docs/raft-kv-design.md for the consolidation plan.
    var cluster_opt: ?*kv.Cluster = null;
    var raft_log_path_buf: ?[:0]u8 = null;
    defer if (raft_log_path_buf) |p| allocator.free(p);
    var peers_owned: ?[]kv.RaftPeerAddr = null;
    defer if (peers_owned) |p| {
        for (p) |peer| allocator.free(peer.host);
        allocator.free(p);
    };
    if (cli.raft_enabled) {
        raft_log_path_buf = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/raft.log.db",
            .{cli.data_dir},
            0,
        );
        const raft_listen_addr = parseHostPort(allocator, cli.raft_listen) catch |err| {
            std.debug.print("error: --raft-listen {s}: {s}\n", .{ cli.raft_listen, @errorName(err) });
            std.process.exit(2);
        };
        peers_owned = try parsePeerList(allocator, cli.raft_peers);

        cluster_opt = kv.Cluster.init(.{
            .allocator = allocator,
            .data_dir = cli.data_dir,
            .raft = .{
                .node_id = cli.raft_node_id,
                .peers = peers_owned.?,
                .listen_addr = raft_listen_addr,
                .raft_log_path = raft_log_path_buf,
                .election_timeout_ms = cli.raft_election_timeout_ms,
                .request_timeout_ms = cli.raft_heartbeat_ms,
            },
        }) catch |err| {
            std.debug.print("error: cluster init failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        std.log.info(
            "files-server: raft enabled — node {d}, peers {s}, listen {s}",
            .{ cli.raft_node_id, cli.raft_peers, cli.raft_listen },
        );
    }
    defer if (cluster_opt) |c| c.deinit();

    // ── Raft thread (only when --raft-* args set) ─────────────
    var raft_stop: std.atomic.Value(bool) = .init(false);
    var raft_thread: ?std.Thread = null;
    defer if (raft_thread) |t| t.join();
    if (cluster_opt) |cluster| {
        raft_thread = try std.Thread.spawn(.{}, raftThreadMain, .{ cluster, &raft_stop, cli.raft_snapshot_interval_ms });
    }
    defer raft_stop.store(true, .release);

    const handle = try cs.thread.spawn(.{
        .allocator = allocator,
        .data_dir = cli.data_dir,
        .blob_cfg = blob_owned.cfg,
        .bind_addr = listen_addr,
        .tls_config = tls_config,
        .jwt_secret = jwt_secret,
        .cors_origin = cli.cors_origin,
        .max_connections = cli.max_connections,
        .cluster = cluster_opt,
    });
    defer handle.shutdown();

    const scheme: []const u8 = if (tls_config != null) "https" else "http";
    var stdout_buf: [128]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    try sw.interface.print("files-server-standalone listening on {s}://{s} (port {d})\n", .{
        scheme, cli.listen, handle.port,
    });
    try sw.interface.flush();

    // Platform-deploy bootstrap: ensure __admin__ and __replay__ have
    // a deployment in S3 + a `_deploy/current` pointer in the
    // cluster's app.db. Idempotent — a warm S3 + healthy cluster
    // boils down to two HEADs and two release POSTs that the worker
    // applies as no-ops. Skipped when --leader-url isn't set so the
    // operator can run files-server in a "deploy server only, no
    // cluster behind it" mode for development.
    if (cli.leader_url) |leader_url| {
        cs.bootstrap.bootstrapPlatformDeployments(
            allocator,
            blob_owned.cfg,
            cli.data_dir,
            leader_url,
            jwt_secret,
            cli.bootstrap_kv[0..cli.bootstrap_kv_count],
        ) catch |err| {
            std.log.err(
                "files-server bootstrap failed: {s} (leader_url={s})",
                .{ @errorName(err), leader_url },
            );
            std.process.exit(2);
        };
    } else {
        if (cli.bootstrap_kv_count > 0) {
            std.log.warn("files-server: --bootstrap-kv set but --leader-url is not; admin-kv push skipped", .{});
        }
        std.log.info("files-server: --leader-url not set, skipping platform-deploy bootstrap", .{});
    }

    while (true) {
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}
