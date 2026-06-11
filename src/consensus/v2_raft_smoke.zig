//! V2 Phase-0 exit test (v2-build-order): prove the fetched
//! raft-rs-zig substrate is callable from inside rove — create a Manager,
//! stand up a single-voter group, and drive it to leader. This is the
//! build-integration milestone (cargo → link → FFI works end to end); the
//! per-tenant data plane is Phase 1. Modeled on raft-rs-zig's src/main.zig.

const std = @import("std");
const raft = @import("raft_rs_zig");

fn applyNoop(
    _: ?*anyopaque,
    _: u64,
    _: u64,
    _: u64,
    _: [*c]const u8,
    _: usize,
) callconv(.c) void {}

test "raft-rs-zig: single-voter group elects a leader from inside rove" {
    var mgr = try raft.Manager.init();
    defer mgr.deinit();

    const gid: u64 = 1;
    const st = try raft.MemStorage.init(std.testing.allocator, &.{1});
    try mgr.createGroup(gid, 1, raft.manager.storage_vtable, st);
    try mgr.campaign(gid);

    var buf: [16]u64 = undefined;
    var pump: u32 = 0;
    while (!mgr.isLeader(gid) and pump < 100) : (pump += 1) {
        mgr.tickAll();
        const ready = mgr.pollReady(&buf);
        for (ready) |g| try mgr.processReady(g, applyNoop, null);
    }
    try std.testing.expect(mgr.isLeader(gid));

    try mgr.destroyGroup(gid);
}
