// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `zig build gen-guards` — write the JS interpreter of the shared rules.
//!
//! The offline engines evaluate the rules in JS, and the Python that composes
//! the browser arena's prelude cannot run Zig comptime, so the emitted text is
//! committed. `epilogue.zig` asserts the committed file still matches
//! `emitJs`, which is what keeps the artifact from becoming a third statement
//! of the rules rather than a rendering of the one.

const std = @import("std");
const guards = @import("rove-guards");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    if (args.len < 2) return error.MissingOutputPath;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try guards.emitJs(buf.writer(a));

    const f = try std.fs.cwd().createFile(args[1], .{});
    defer f.close();
    try f.writeAll(buf.items);
}
