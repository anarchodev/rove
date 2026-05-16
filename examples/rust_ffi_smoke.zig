//! Drives the vendored Rust staticlib at examples/rust_ffi_smoke/.
//! Step 1 of the V2 raft-rs vendoring spike (docs/v2-vendoring-spike.md):
//! prove that `cargo build → linkSystemLibrary` works end-to-end before
//! committing to vendoring raft-rs's full dep tree.

const std = @import("std");

const c = @cImport({
    @cInclude("rust_ffi_smoke.h");
});

fn sumCallback(ctx: ?*anyopaque, value: u32) callconv(.c) i32 {
    const total: *u64 = @ptrCast(@alignCast(ctx.?));
    total.* += value;
    return 0;
}

pub fn main() !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const w = &stdout_writer.interface;

    const sum = c.rust_ffi_smoke_add(17, 25);
    try w.print("rust_ffi_smoke_add(17, 25) = {d}\n", .{sum});
    std.debug.assert(sum == 42);

    const ver = c.rust_ffi_smoke_version();
    try w.print("rust_ffi_smoke_version()  = {s}\n", .{std.mem.span(ver)});

    var total: u64 = 0;
    const rc = c.rust_ffi_smoke_fire(10, &total, sumCallback);
    try w.print("rust_ffi_smoke_fire(10, _, sum) → rc={d}, total={d}\n", .{ rc, total });
    std.debug.assert(rc == 0);
    std.debug.assert(total == 45); // 0+1+...+9

    try w.print("ok\n", .{});
    try w.flush();
}
