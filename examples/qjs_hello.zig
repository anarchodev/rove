//! `qjs-hello` — runs a JS snippet through rove-qjs and prints the
//! result. The minimum-viable demonstration that the Phase 0 module is
//! usable end-to-end.
//!
//! Usage:
//!     zig build qjs-hello
//!     zig-out/bin/qjs-hello                     # runs a built-in snippet
//!     zig-out/bin/qjs-hello "2 ** 10"           # runs your own
//!     echo "Math.sqrt(2)" | zig-out/bin/qjs-hello -  # stdin
//!
//! When snapshot/restore lands (next phase 0 session), this same binary
//! gains a `--snapshot` flag that reuses a frozen context across calls.
//! Right now each invocation is one-shot.

const std = @import("std");
const qjs = @import("rove-qjs");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const default_src = "const greet = n => `hello, ${n}!`; greet('rove-qjs')";

    var owned_src: ?[]u8 = null;
    defer if (owned_src) |s| allocator.free(s);

    const source: []const u8 = if (args.len < 2) blk: {
        break :blk default_src;
    } else if (std.mem.eql(u8, args[1], "-")) blk: {
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
        const r = &stdin_reader.interface;
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(allocator);
        while (true) {
            const maybe_line = r.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => break,
                error.ReadFailed => break,
            };
            const line = maybe_line orelse break;
            try list.appendSlice(allocator, line);
            try list.append(allocator, '\n');
        }
        const copy = try list.toOwnedSlice(allocator);
        owned_src = copy;
        break :blk copy;
    } else args[1];

    var rt = try qjs.Runtime.init();
    defer rt.deinit();

    var ctx = try rt.newContext();
    defer ctx.deinit();

    var result = ctx.eval(source, "qjs-hello.js", .{}) catch |err| switch (err) {
        error.JsException => {
            const msg = try ctx.takeExceptionMessage(allocator);
            defer allocator.free(msg);
            var stderr_buf: [1024]u8 = undefined;
            var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
            const w = &stderr_writer.interface;
            try w.print("qjs-hello: JS exception: {s}\n", .{msg});
            try w.flush();
            std.process.exit(1);
        },
        else => return err,
    };
    defer result.deinit();

    const out = try result.toOwnedString(allocator);
    defer allocator.free(out);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const w = &stdout_writer.interface;
    try w.print("{s}\n", .{out});
    try w.flush();
}
