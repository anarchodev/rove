//! `log-server-standalone` — Phase 5.5 (a) entry point.
//!
//! Spawns the indexer thread + h2 query API together. Loopback-only;
//! TLS + JWT-handoff land in step 6 when the server moves to its own
//! subdomain.
//!
//! Storage is S3 — there is no longer a filesystem backend. The
//! standalone reads its S3 config entirely from env (matches the
//! BLOB_BACKEND=s3 vars used elsewhere) and exits with a clear
//! message if anything's missing. The smoke driver sources `.env`
//! before spawning.
//!
//! Required env (batch store + tape blob backend):
//!   S3_ENDPOINT          hostname (no scheme)
//!   S3_REGION            sigv4 signing region
//!   S3_BUCKET            bucket name
//!   AWS_ACCESS_KEY_ID
//!   AWS_SECRET_ACCESS_KEY
//!
//! Optional env:
//!   LOG_S3_KEY_PREFIX    prefix prepended to every batch-store key
//!                        (sidecars + ndjson; default ``)
//!   S3_KEY_PREFIX_BASE   prefix prepended to every per-tenant
//!                        BlobBackend key (`{base}{tenant}/log-blobs/{hash}`).
//!                        Must match the worker's `S3_KEY_PREFIX_BASE`
//!                        so the standalone reads from the same keys
//!                        the worker writes. Default ``.
//!   S3_USE_TLS           `0` / `false` to drop to http (DEV ONLY,
//!                        for local MinIO smoke)
//!
//! CLI flags:
//!   --index-db <path>    where local SQLite index lives
//!                        (default /tmp/log-server-index.db)
//!   --listen host:port   bind address (default 127.0.0.1:0)
//!   --poll-interval-ms N indexer cadence (default 5000)
//!
//! Prints `listening on port {N}` on a stable line so the smoke can
//! scrape it from stdout without racing log output.

const std = @import("std");
const log_server = @import("rove-log-server");
const blob_mod = @import("rove-blob");

const Cli = struct {
    index_db_path: []const u8 = "/tmp/log-server-index.db",
    listen_host: []const u8 = "127.0.0.1",
    listen_port: u16 = 0,
    poll_interval_ms: u32 = 5_000,
};

fn parseCli(argv: [][:0]u8) !Cli {
    var out: Cli = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--index-db")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.index_db_path = argv[i];
        } else if (std.mem.eql(u8, a, "--listen")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            const arg = argv[i];
            const colon = std.mem.lastIndexOfScalar(u8, arg, ':') orelse return error.Usage;
            out.listen_host = arg[0..colon];
            out.listen_port = try std.fmt.parseInt(u16, arg[colon + 1 ..], 10);
        } else if (std.mem.eql(u8, a, "--poll-interval-ms")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.poll_interval_ms = try std.fmt.parseInt(u32, argv[i], 10);
        } else {
            return error.Usage;
        }
    }
    return out;
}

fn envRequired(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.debug.print(
                "log-server-standalone: missing required env var: {s}\n",
                .{name},
            );
            std.process.exit(2);
        },
        else => err,
    };
}

fn envOpt(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => err,
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const cli = parseCli(argv) catch {
        var stderr_buf: [512]u8 = undefined;
        var sw = std.fs.File.stderr().writer(&stderr_buf);
        try sw.interface.writeAll(
            \\usage: log-server-standalone \
            \\    [--index-db /path/to/log_index.db] \
            \\    [--listen 127.0.0.1:0] \
            \\    [--poll-interval-ms 5000]
            \\
            \\Required env: S3_ENDPOINT S3_REGION S3_BUCKET
            \\              AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
            \\Optional env: LOG_S3_KEY_PREFIX S3_USE_TLS
            \\
        );
        try sw.interface.flush();
        std.process.exit(2);
    };

    const endpoint = try envRequired(allocator, "S3_ENDPOINT");
    defer allocator.free(endpoint);
    const region = try envRequired(allocator, "S3_REGION");
    defer allocator.free(region);
    const bucket = try envRequired(allocator, "S3_BUCKET");
    defer allocator.free(bucket);
    const access_key = try envRequired(allocator, "AWS_ACCESS_KEY_ID");
    defer allocator.free(access_key);
    const secret_key = try envRequired(allocator, "AWS_SECRET_ACCESS_KEY");
    defer allocator.free(secret_key);
    const key_prefix = (try envOpt(allocator, "LOG_S3_KEY_PREFIX")) orelse
        try allocator.dupe(u8, "");
    defer allocator.free(key_prefix);
    // Optional. Empty default means tape blobs sit at
    // `{tenant}/log-blobs/{hash}` (matches the worker default).
    const blob_key_prefix_base = (try envOpt(allocator, "S3_KEY_PREFIX_BASE")) orelse
        try allocator.dupe(u8, "");
    defer allocator.free(blob_key_prefix_base);
    const use_tls = blk: {
        const v = (try envOpt(allocator, "S3_USE_TLS")) orelse break :blk true;
        defer allocator.free(v);
        if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false")) break :blk false;
        break :blk true;
    };

    const s3 = try log_server.batch_store_s3.S3BatchStore.init(allocator, .{
        .endpoint = endpoint,
        .region = region,
        .bucket = bucket,
        .key_prefix = key_prefix,
        .access_key = access_key,
        .secret_key = secret_key,
        .use_tls = use_tls,
    });
    defer s3.deinit();

    // Same S3 connection params as the batch store; differs only in
    // the per-tenant key prefix scheme (BlobBackend.openPerTenant
    // builds it lazily). Threaded into standalone.spawn so the blob
    // route opens a per-tenant BlobBackend on first request.
    const blob_backend_cfg: blob_mod.BackendConfig = .{ .s3 = .{
        .endpoint = endpoint,
        .region = region,
        .bucket = bucket,
        .key_prefix_base = blob_key_prefix_base,
        .access_key = access_key,
        .secret_key = secret_key,
        .use_tls = use_tls,
    } };

    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}", .{cli.index_db_path}, 0);
    defer allocator.free(db_path);

    var db = try log_server.index_db.IndexDb.open(allocator, db_path);
    defer db.close();

    const ip = parseIp4(cli.listen_host) catch {
        std.debug.print("error: --listen host must be an IPv4 dotted quad\n", .{});
        std.process.exit(2);
    };
    const bind_addr = std.net.Address.initIp4(ip, cli.listen_port);

    const handle = try log_server.standalone.spawn(.{
        .allocator = allocator,
        .store = s3.batchStore(),
        .db = db,
        .bind_addr = bind_addr,
        .poll_interval_ms = cli.poll_interval_ms,
        .blob_backend_cfg = blob_backend_cfg,
    });
    defer handle.shutdown();

    var stdout_buf: [128]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    try sw.interface.print("listening on port {d}\n", .{handle.port});
    try sw.interface.flush();

    while (true) std.Thread.sleep(1 * std.time.ns_per_s);
}

fn parseIp4(host: []const u8) ![4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, host, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return error.InvalidIp;
        out[i] = try std.fmt.parseInt(u8, part, 10);
    }
    if (i != 4) return error.InvalidIp;
    return out;
}
