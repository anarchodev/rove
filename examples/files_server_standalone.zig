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

const ENV_JWT_SECRET = "LOOP46_SERVICES_JWT_SECRET";

const Cli = struct {
    data_dir: []const u8 = "/tmp/rove-files-thread",
    listen: []const u8 = "127.0.0.1:0",
    tls_cert: ?[]const u8 = null,
    tls_key: ?[]const u8 = null,
    cors_origin: ?[]const u8 = null,
    max_connections: u32 = 64,
};

fn usage(stderr: *std.fs.File.Writer) !void {
    try stderr.interface.writeAll(
        \\usage: files-server-standalone --data-dir <path>
        \\                               --listen <host:port>
        \\                               [--tls-cert <path> --tls-key <path>]
        \\                               [--cors-origin <origin>]
        \\                               [--max-connections <N>]
        \\
        \\env (required):
        \\  LOOP46_SERVICES_JWT_SECRET   hex HMAC-SHA256 shared with loop46 worker
        \\
        \\env (optional, S3 blob backend):
        \\  BLOB_BACKEND=s3              + S3_ENDPOINT / S3_REGION / S3_BUCKET /
        \\                                AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
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
        blob_mod.env.LoadError.UnknownBackend => {
            std.debug.print("error: BLOB_BACKEND must be \"fs\" or \"s3\"\n", .{});
            std.process.exit(2);
        },
        blob_mod.env.LoadError.OutOfMemory => return error.OutOfMemory,
        else => |e| {
            const name = blob_mod.env.errorEnvName(e) orelse "<unknown>";
            std.debug.print(
                "error: BLOB_BACKEND=s3 requires {s} to be set\n",
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

    const handle = try cs.thread.spawn(.{
        .allocator = allocator,
        .data_dir = cli.data_dir,
        .blob_cfg = blob_owned.cfg,
        .bind_addr = listen_addr,
        .tls_config = tls_config,
        .jwt_secret = jwt_secret,
        .cors_origin = cli.cors_origin,
        .max_connections = cli.max_connections,
    });
    defer handle.shutdown();

    const scheme: []const u8 = if (tls_config != null) "https" else "http";
    var stdout_buf: [128]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    try sw.interface.print("files-server-standalone listening on {s}://{s} (port {d})\n", .{
        scheme, cli.listen, handle.port,
    });
    try sw.interface.flush();

    while (true) {
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}
