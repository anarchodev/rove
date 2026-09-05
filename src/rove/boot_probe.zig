// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! boot-probe — what a registry COMMITS at init, before any entity
//! exists. Prints VmRSS before and after `FatRegistry.init` for a
//! worker-shaped registry (max_entities = 65536, a ~1.3KB shadow struct
//! — the rewind-worker universe's measured Fat size). Run via
//! `zig build boot-probe`. The delta is boot cost per worker thread;
//! prod runs several.
const std = @import("std");
const rove = @import("root.zig");

// A shadow struct the size of the rewind-worker universe's (measured
// 1312B); the component split is irrelevant to the boot commit.
const Big = struct { bytes: [1296]u8 = [_]u8{0} ** 1296 };
const Small = struct { v: u32 = 0 };
const Universe = rove.Row(&.{ Big, Small });
const Reg = rove.fat_mod.FatRegistry(Universe);

fn statusKib(key: []const u8) !u64 {
    var buf: [4096]u8 = undefined;
    const f = try std.fs.openFileAbsolute("/proc/self/status", .{});
    defer f.close();
    const n = try f.readAll(&buf);
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, key)) {
            var toks = std.mem.tokenizeAny(u8, line[key.len..], " \t");
            return try std.fmt.parseInt(u64, toks.next().?, 10);
        }
    }
    return error.NoSuchField;
}

fn rssKib() !u64 {
    return statusKib("VmRSS:");
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const before = try rssKib();
    var reg = try Reg.init(alloc, .{ .max_entities = 65536 });
    defer reg.deinit();
    const after_init = try rssKib();

    // Then a realistic working set: 1024 live entities, each parking
    // its big component into the shadow.
    var coll = try rove.Collection(rove.Row(&.{Small}), .{}).init(alloc);
    defer coll.deinit();
    reg.registerCollection(&coll, 1);
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        const e = try reg.create(&coll);
        (try reg.getFat(e, Big)).bytes[0] = 1;
    }
    const after_use = try rssKib();

    const huge = statusKib("RssAnon:") catch 0;
    std.debug.print(
        "boot-probe  shadow struct {d} B x 65536\n" ++
            "  RSS before init : {d:>8} KiB\n" ++
            "  RSS after init  : {d:>8} KiB   (+{d} KiB committed at boot)\n" ++
            "  RSS after 1024 live entities: {d:>8} KiB   (+{d} KiB for use; RssAnon {d} KiB)\n",
        .{ @sizeOf(Reg.Fat), before, after_init, after_init - before, after_use, after_use - after_init, huge },
    );
}
