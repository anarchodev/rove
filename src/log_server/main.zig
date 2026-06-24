//! `rewind-logs` — the request-log query API.
//!
//! The operator runs this binary alongside the `rewind` worker and
//! points the worker at it via `--log-public-base`. Both processes
//! share the JWT secret (`LOOP46_SERVICES_JWT_SECRET`) so tokens
//! minted at the worker's `/_system/services-token` verify here on
//! every `/v1/*` request, AND share the same batch-store +
//! blob-backend config so the standalone can index/serve what the
//! worker writes.
//!
//! Required env:
//!   LOOP46_SERVICES_JWT_SECRET   hex HMAC-SHA256 shared with the
//!                                rewind worker.
//!
//! Optional env (S3 batch store + tape blob backend):
//!   BLOB_BACKEND=s3              + S3_ENDPOINT / S3_REGION /
//!                                S3_BUCKET / AWS_ACCESS_KEY_ID /
//!                                AWS_SECRET_ACCESS_KEY (and optional
//!                                S3_KEY_PREFIX_BASE / S3_USE_TLS).
//!                                Default `fs` writes / reads under
//!                                `--data-dir/log-batches/`.
//!   LOG_S3_KEY_PREFIX            prepended to every batch-store key
//!                                when BLOB_BACKEND=s3 (default ``).
//!
//! Usage:
//!   rewind-logs --data-dir <path> --listen <host:port> \
//!                         [--tls-cert <path> --tls-key <path>] \
//!                         [--cors-origin <origin>] \
//!                         [--index-db <path>] \
//!                         [--poll-interval-ms 5000]

const std = @import("std");
const log_server = @import("rove-log-server");
const blob_mod = @import("rove-blob");
const h2 = @import("rove-h2");

var stop_flag: std.atomic.Value(bool) = .init(false);

fn handleSignal(_: c_int) callconv(.c) void {
    stop_flag.store(true, .release);
}

fn installSignalHandlers() !void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

const ENV_JWT_SECRET = "LOOP46_SERVICES_JWT_SECRET";

const Cli = struct {
    data_dir: []const u8 = "/tmp/rove-log-server",
    index_db_path: ?[]const u8 = null,
    listen: []const u8 = "127.0.0.1:0",
    tls_cert: ?[]const u8 = null,
    tls_key: ?[]const u8 = null,
    cors_origin: ?[]const u8 = null,
    poll_interval_ms: u32 = 500,
    max_connections: u32 = 64,
};

fn usage(stderr: *std.fs.File.Writer) !void {
    try stderr.interface.writeAll(
        \\usage: rewind-logs --data-dir <path>
        \\                             --listen <host:port>
        \\                             [--tls-cert <path> --tls-key <path>]
        \\                             [--cors-origin <origin>]
        \\                             [--index-db <path>]
        \\                             [--poll-interval-ms <ms>]
        \\                             [--max-connections <N>]
        \\
        \\env (required):
        \\  LOOP46_SERVICES_JWT_SECRET   hex HMAC-SHA256 shared with loop46 worker
        \\
        \\env (optional, S3 backend):
        \\  BLOB_BACKEND=s3              + S3_ENDPOINT / S3_REGION / S3_BUCKET /
        \\                                AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
        \\  LOG_S3_KEY_PREFIX            prepended to batch-store keys
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
        } else if (std.mem.eql(u8, a, "--index-db")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.index_db_path = argv[i];
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
        } else if (std.mem.eql(u8, a, "--poll-interval-ms")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.poll_interval_ms = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--max-connections")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.max_connections = try std.fmt.parseInt(u32, argv[i], 10);
        } else {
            return error.Usage;
        }
    }
    if ((out.tls_cert == null) != (out.tls_key == null)) return error.Usage;
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

    var stderr_buf: [512]u8 = undefined;
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

    // Pick the batch store backend off the same env signal. `fs` mode
    // S3-only batch store. Same connection params as the worker plus
    // an optional LOG_S3_KEY_PREFIX namespace, matching what the
    // worker's flushLogs path uses.
    const s3cfg = blob_owned.cfg;
    const key_prefix = (try blob_mod.env.envOpt(allocator, "LOG_S3_KEY_PREFIX")) orelse
        try allocator.dupe(u8, "");
    defer allocator.free(key_prefix);
    var s3_handle = try log_server.batch_store_s3.S3BatchStore.init(allocator, .{
        .endpoint = s3cfg.endpoint,
        .region = s3cfg.region,
        .bucket = s3cfg.bucket,
        .key_prefix = key_prefix,
        .access_key = s3cfg.access_key,
        .secret_key = s3cfg.secret_key,
        .use_tls = s3cfg.use_tls,
    });
    defer s3_handle.deinit();
    const batch_store: log_server.batch_store.BatchStore = s3_handle.batchStore();
    std.log.info(
        "batch backend: s3 endpoint={s} region={s} bucket={s} key_prefix='{s}'",
        .{ s3cfg.endpoint, s3cfg.region, s3cfg.bucket, key_prefix },
    );

    var tls_config: ?*h2.TlsConfig = null;
    defer if (tls_config) |c| c.destroy();
    if (cli.tls_cert) |cert| {
        tls_config = h2.TlsConfig.createFromFiles(allocator, cert, cli.tls_key.?, null) catch |err| {
            std.debug.print("error: tls: {s} (cert={s}, key={s})\n", .{ @errorName(err), cert, cli.tls_key.? });
            std.process.exit(2);
        };
        std.log.info("tls: loaded {s} + {s}", .{ cert, cli.tls_key.? });
    }

    const listen_addr = parseHostPort(allocator, cli.listen) catch |err| {
        std.debug.print("error: --listen {s}: {s}\n", .{ cli.listen, @errorName(err) });
        std.process.exit(2);
    };

    const index_db_path = if (cli.index_db_path) |p|
        try std.fmt.allocPrintSentinel(allocator, "{s}", .{p}, 0)
    else
        try std.fmt.allocPrintSentinel(allocator, "{s}/log_index.db", .{cli.data_dir}, 0);
    defer allocator.free(index_db_path);

    // Writer connection (indexer + push path); open it first so the
    // WAL/shm files exist for the reader. Reader connection serves the
    // query surface on its own handle so /list|/show|/count never wait
    // on the writer mutex mid-index. Closed after `handle.shutdown()`
    // joins both threads (defers run LIFO).
    var db = try log_server.index_db.IndexDb.open(allocator, index_db_path);
    defer db.close();
    var read_db = try log_server.index_db.IndexDb.openReader(allocator, index_db_path);
    defer read_db.close();

    const handle = try log_server.standalone.spawn(.{
        .allocator = allocator,
        .store = batch_store,
        .db = db,
        .read_db = read_db,
        .bind_addr = listen_addr,
        .max_connections = cli.max_connections,
        .tls_config = tls_config,
        .jwt_secret = jwt_secret,
        .cors_origin = cli.cors_origin,
        .poll_interval_ms = cli.poll_interval_ms,
    });
    defer handle.shutdown();

    const scheme: []const u8 = if (tls_config != null) "https" else "http";
    var stdout_buf: [128]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    try sw.interface.print("rewind-logs listening on {s}://{s} (port {d})\n", .{
        scheme, cli.listen, handle.port,
    });
    try sw.interface.flush();

    try installSignalHandlers();
    h2.TlsConfig.runReloadPoll(tls_config, &stop_flag);
}
