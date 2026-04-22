//! `files-server-standalone` — spawns the rove-files-server thread
//! and idles until SIGINT. Exists so the end-to-end smoke test can
//! drive it from curl without standing up a full js-worker.
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

    // Standalone: one process, a handful of clients at most. Default
    // to 32 concurrent connections — plenty of headroom for smoke
    // tests and manual pokes. No raft here — standalone mode writes
    // locally only (no cluster to replicate to).
    const handle = try cs.thread.spawn(allocator, cli.data_dir, 32, null);
    defer handle.shutdown();

    // Print the bound port on a predictable line so the smoke test
    // can scrape it from stdout without racing stderr log output.
    var stdout_buf: [64]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    try sw.interface.print("listening on port {d}\n", .{handle.port});
    try sw.interface.flush();

    // Block forever. SIGTERM / SIGINT causes the process to exit;
    // the `defer handle.shutdown()` signals the thread to unwind
    // cleanly (it checks the atomic flag between poll ticks).
    while (true) {
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}
