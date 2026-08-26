// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
const std = @import("std");

pub const entity_mod = @import("entity.zig");
pub const row_mod = @import("row.zig");
pub const collection_mod = @import("collection.zig");
pub const registry_mod = @import("registry.zig");
pub const fat_mod = @import("fat.zig");
pub const world_mod = @import("world.zig");

pub const Entity = entity_mod.Entity;
pub const Row = row_mod.Row;
pub const Collection = collection_mod.Collection;
pub const Registry = registry_mod.Registry;
pub const FatRegistry = fat_mod.FatRegistry;
pub const effectiveAlign = collection_mod.effectiveAlign;
pub const World = world_mod.World;
pub const Part = world_mod.Part;
pub const CollDecl = world_mod.CollDecl;
pub const CollKind = world_mod.CollKind;

/// The world the program's root module declared, or null — the
/// `std_options` idiom. A binary on the fat model declares its world
/// ONCE at root scope (`pub const rove_world = rove.World(.{ .parts =
/// ... })`); layers consult this instead of threading component lists
/// through every boundary. Library test builds have no declaring root
/// and see null — explicit `World(...)` construction remains the path
/// for tests' mini-worlds.
pub const declared_world: ?type = if (@hasDecl(@import("root"), "rove_world"))
    @import("root").rove_world
else
    null;

/// Make the process's stderr/stdout non-blocking so `std.log` writes on a
/// single-threaded poll loop can NEVER wedge it on a backpressured log
/// sink. Every rove serving binary (front / worker / cp) runs its poll
/// loop on one thread and logs via `std.log` → stderr; in prod stderr →
/// journald, which rate-limits / stalls on slow disk, and a BLOCKING
/// write() there freezes the whole process — every tenant — until the
/// sink drains (root-caused from a front wedge: poll thread stuck in
/// anon_pipe_write, the per-request access log the volume trigger). With
/// O_NONBLOCK a write under backpressure returns EAGAIN, which `std.log`
/// swallows — the line drops instead of freezing the serving thread, and
/// a dropped log line always beats a frozen edge. Call once at startup.
/// Best-effort: a fcntl failure just leaves the fd blocking (no regression).
pub fn logNonBlocking() void {
    for ([_]std.posix.fd_t{ std.posix.STDERR_FILENO, std.posix.STDOUT_FILENO }) |fd| {
        const cur = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch continue;
        var o: std.posix.O = @bitCast(@as(u32, @truncate(cur)));
        o.NONBLOCK = true;
        _ = std.posix.fcntl(fd, std.posix.F.SETFL, @as(u32, @bitCast(o))) catch {};
    }
}

test {
    _ = entity_mod;
    _ = row_mod;
    _ = collection_mod;
    _ = registry_mod;
    _ = fat_mod;
    _ = world_mod;
    _ = @import("axes_spike.zig");
}
