//! `files-server-standalone` — spawns the rove-files-server thread
//! and idles until SIGINT. Exists so the end-to-end smoke test can
//! drive it from curl without standing up a full js-worker.
//!
//! Required env:
//!   FILES_JWT_SECRET     hex-encoded HMAC-SHA256 secret used to
//!                        verify the `Authorization: Bearer <jwt>`
//!                        on every request. Must match what the
//!                        smoke driver uses to mint test tokens.
//!
//! Usage:
//!     files-server-standalone --data-dir <path>

const std = @import("std");
const cs = @import("rove-files-server");

const Cli = struct {
    data_dir: []const u8 = "/tmp/rove-files-thread",
};

fn parseCli(argv: [][:0]u8) !Cli {
    var out: Cli = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--data-dir")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.data_dir = argv[i];
        } else {
            return error.Usage;
        }
    }
    return out;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const cli = parseCli(argv) catch {
        var stderr_buf: [256]u8 = undefined;
        var sw = std.fs.File.stderr().writer(&stderr_buf);
        try sw.interface.writeAll(
            \\usage: files-server-standalone --data-dir <path>
            \\
        );
        try sw.interface.flush();
        std.process.exit(2);
    };

    std.fs.cwd().makePath(cli.data_dir) catch {};

    // JWT secret (hex). The standalone refuses any request whose
    // bearer doesn't verify against this; the smoke mints test
    // tokens with the matching value.
    const jwt_secret_hex = std.process.getEnvVarOwned(allocator, "FILES_JWT_SECRET") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.debug.print("error: FILES_JWT_SECRET not set\n", .{});
            std.process.exit(2);
        },
        else => return err,
    };
    defer allocator.free(jwt_secret_hex);
    if (jwt_secret_hex.len == 0 or jwt_secret_hex.len % 2 != 0) {
        std.debug.print("error: FILES_JWT_SECRET must be even-length hex\n", .{});
        std.process.exit(2);
    }
    const jwt_secret = try allocator.alloc(u8, jwt_secret_hex.len / 2);
    defer allocator.free(jwt_secret);
    _ = std.fmt.hexToBytes(jwt_secret, jwt_secret_hex) catch {
        std.debug.print("error: FILES_JWT_SECRET is not valid hex\n", .{});
        std.process.exit(2);
    };

    // Loopback h2c (no TLS) for the smoke driver. Production wires
    // this through loop46 which provides a TlsConfig.
    const handle = try cs.thread.spawn(.{
        .allocator = allocator,
        .data_dir = cli.data_dir,
        .blob_cfg = .fs,
        .bind_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
        .jwt_secret = jwt_secret,
        .max_connections = 32,
    });
    defer handle.shutdown();

    var stdout_buf: [64]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    try sw.interface.print("listening on port {d}\n", .{handle.port});
    try sw.interface.flush();

    while (true) {
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}
