//! `sse-server-standalone` — runs the centralized SSE notification
//! service as a separate process. See `docs/sse-plan.md`.
//!
//! Required env:
//!   LOOP46_SERVICES_JWT_SECRET   hex HMAC-SHA256 shared with the
//!                                worker (it mints EventSource tokens
//!                                at `/_session/sse-token`; we verify
//!                                them on each connect).
//!   SSE_INTERNAL_TOKEN           shared secret for the worker →
//!                                sse-server emit POST. Sent by the
//!                                worker as `Authorization: Bearer ...`.
//!
//! Usage:
//!   sse-server-standalone --listen <host:port>
//!                         [--tls-cert <path> --tls-key <path>]
//!                         [--max-connections <N>]
//!                         [--max-connections-per-tenant <N>]

const std = @import("std");
const sse_server = @import("rove-sse-server");
const h2 = @import("rove-h2");

const ENV_JWT_SECRET = "LOOP46_SERVICES_JWT_SECRET";
const ENV_INTERNAL_TOKEN = "SSE_INTERNAL_TOKEN";

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

const Cli = struct {
    listen: []const u8 = "127.0.0.1:0",
    tls_cert: ?[]const u8 = null,
    tls_key: ?[]const u8 = null,
    max_connections: u32 = 1024,
    max_connections_per_tenant: u32 = 1_000,
};

fn usage(stderr: *std.fs.File.Writer) !void {
    try stderr.interface.writeAll(
        \\usage: sse-server-standalone --listen <host:port>
        \\                             [--tls-cert <path> --tls-key <path>]
        \\                             [--max-connections <N>]
        \\                             [--max-connections-per-tenant <N>]
        \\
        \\env (required):
        \\  LOOP46_SERVICES_JWT_SECRET   hex HMAC-SHA256 shared with worker
        \\  SSE_INTERNAL_TOKEN           shared bearer for worker → emit POST
        \\
    );
    try stderr.interface.flush();
}

fn parseCli(argv: [][:0]u8) !Cli {
    var out: Cli = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--listen")) {
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
        } else if (std.mem.eql(u8, a, "--max-connections")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.max_connections = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--max-connections-per-tenant")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.max_connections_per_tenant = try std.fmt.parseInt(u32, argv[i], 10);
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

fn loadInternalToken(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, ENV_INTERNAL_TOKEN) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.debug.print("error: {s} not set\n", .{ENV_INTERNAL_TOKEN});
            std.process.exit(2);
        },
        else => return err,
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

    const jwt_secret = try loadJwtSecret(allocator);
    defer allocator.free(jwt_secret);

    const internal_token = try loadInternalToken(allocator);
    defer allocator.free(internal_token);

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

    const handle = try sse_server.standalone.spawn(.{
        .allocator = allocator,
        .bind_addr = listen_addr,
        .max_connections = cli.max_connections,
        .max_connections_per_tenant = cli.max_connections_per_tenant,
        .tls_config = tls_config,
        .jwt_secret = jwt_secret,
        .internal_token = internal_token,
    });
    defer handle.shutdown();

    const scheme: []const u8 = if (tls_config != null) "https" else "http";
    var stdout_buf: [128]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    try sw.interface.print("sse-server-standalone listening on {s}://{s} (port {d})\n", .{
        scheme, cli.listen, handle.port,
    });
    try sw.interface.flush();

    try installSignalHandlers();
    h2.TlsConfig.runReloadPoll(tls_config, &stop_flag);
}
