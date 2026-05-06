//! `log-server-standalone` — Phase 5.5 (a) step 2 entry point.
//!
//! Spawns the indexer thread + h2 query API together. Loopback-only;
//! TLS + JWT-handoff land in step 6 when the server moves to its own
//! subdomain.
//!
//! Usage:
//!     log-server-standalone \
//!         --batch-store-dir <path> \
//!         --index-db <path> \
//!         [--listen 127.0.0.1:0] \
//!         [--poll-interval-ms 5000]
//!
//! Prints `listening on port {N}` on a stable line so the smoke test
//! can scrape it from stdout without racing log output.

const std = @import("std");
const log_server = @import("rove-log-server");

const Cli = struct {
    batch_store_dir: []const u8 = "/tmp/rove-log-store",
    index_db_path: ?[]const u8 = null,
    listen_host: []const u8 = "127.0.0.1",
    listen_port: u16 = 0,
    poll_interval_ms: u32 = 5_000,
};

fn parseCli(argv: [][:0]u8) !Cli {
    var out: Cli = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--batch-store-dir")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.batch_store_dir = argv[i];
        } else if (std.mem.eql(u8, a, "--index-db")) {
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
            \\    --batch-store-dir <path> \
            \\    --index-db <path> \
            \\    [--listen 127.0.0.1:0] \
            \\    [--poll-interval-ms 5000]
            \\
        );
        try sw.interface.flush();
        std.process.exit(2);
    };

    std.fs.cwd().makePath(cli.batch_store_dir) catch {};

    const fs_store = try log_server.batch_store.FilesystemBatchStore.init(
        allocator,
        cli.batch_store_dir,
    );
    defer fs_store.deinit();

    const default_db_path = try std.fmt.allocPrint(
        allocator,
        "{s}/log_index.db",
        .{cli.batch_store_dir},
    );
    defer allocator.free(default_db_path);
    const db_path_str = cli.index_db_path orelse default_db_path;
    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}", .{db_path_str}, 0);
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
        .store = fs_store.batchStore(),
        .db = db,
        .bind_addr = bind_addr,
        .poll_interval_ms = cli.poll_interval_ms,
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
