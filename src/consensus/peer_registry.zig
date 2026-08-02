// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! An in-memory raft node id → transport address map, fed by the control
//! plane (attach / conf-change carry the joining node's address; the
//! directory node-address registry is the durable source) and consulted
//! by the transport to dial a peer it learned at runtime rather than
//! from static config (consensus-and-storage.md "Cluster genesis &
//! membership", peer-address resolution). One per worker / CP process,
//! shared by every raft group (all groups on a cluster ride the same
//! physical nodes). Self-contained — nothing here touches `Node`; the
//! Bridge owns an instance and injects it into the Transport.

const std = @import("std");
const transport_mod = @import("transport.zig");
const cluster_config = @import("cluster_config.zig");

pub const PeerAddr = transport_mod.PeerAddr;
pub const PeerResolver = transport_mod.PeerResolver;

pub const Error = error{
    /// A `host:port` with no colon or an unparseable port (`learnAddr`).
    BadConfig,
    OutOfMemory,
};

/// **Insert-only.** A node id's address is learned once and never
/// freed/moved (re-IP is out of scope for v1, §7), so a host slice handed
/// out by `resolve` stays valid after the brief lookup lock is dropped —
/// the transport copies it into a `std.net.Address` synchronously inside
/// `queueOut`. Heap-allocated so its address is stable for the
/// `PeerResolver.ctx` it hands the transport.
pub const PeerRegistry = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    map: std.AutoHashMapUnmanaged(u64, Entry) = .empty,

    const Entry = struct { host: []u8, port: u16 };

    pub fn create(allocator: std.mem.Allocator) Error!*PeerRegistry {
        const self = allocator.create(PeerRegistry) catch return Error.OutOfMemory;
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *PeerRegistry) void {
        const a = self.allocator;
        var it = self.map.valueIterator();
        while (it.next()) |e| a.free(e.host);
        self.map.deinit(a);
        a.destroy(self);
    }

    /// Learn `node_id → host:port` (insert-only — a repeat for a known id is
    /// ignored). Thread-safe; callable from the worker's h2 handler thread while
    /// the pump thread resolves.
    pub fn learn(self: *PeerRegistry, node_id: u64, host: []const u8, port: u16) Error!void {
        if (node_id == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.contains(node_id)) return;
        const h = self.allocator.dupe(u8, host) catch return Error.OutOfMemory;
        errdefer self.allocator.free(h);
        self.map.put(self.allocator, node_id, .{ .host = h, .port = port }) catch return Error.OutOfMemory;
    }

    /// Parse `host:port` and learn it (the wire form the CP carries).
    pub fn learnAddr(self: *PeerRegistry, node_id: u64, addr: []const u8) Error!void {
        const hp = cluster_config.splitHostPort(addr) catch return Error.BadConfig;
        return self.learn(node_id, hp.host, hp.port);
    }

    /// The `PeerResolver` view to hand the transport. `ctx` is `self`, whose
    /// address is stable (heap-allocated).
    pub fn resolver(self: *PeerRegistry) PeerResolver {
        return .{ .ctx = self, .resolveFn = resolveImpl };
    }

    fn resolveImpl(ctx: ?*anyopaque, node_id: u64) ?PeerAddr {
        const self: *PeerRegistry = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        const e = self.map.get(node_id) orelse return null;
        // host stays valid past the unlock (insert-only); the transport copies
        // it synchronously in queueOut.
        return .{ .host = e.host, .port = e.port };
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "PeerRegistry: learn / resolve / insert-only / learnAddr parsing" {
    const a = testing.allocator;
    const reg = try PeerRegistry.create(a);
    defer reg.destroy();

    const r = reg.resolver();

    // unknown id → null
    try testing.expect(r.resolve(7) == null);

    // learn + resolve
    try reg.learn(2, "10.0.0.2", 9001);
    {
        const pa = r.resolve(2).?;
        try testing.expectEqualStrings("10.0.0.2", pa.host);
        try testing.expectEqual(@as(u16, 9001), pa.port);
    }

    // insert-only: a repeat for a known id is ignored (re-IP is out of scope)
    try reg.learn(2, "10.9.9.9", 1);
    {
        const pa = r.resolve(2).?;
        try testing.expectEqualStrings("10.0.0.2", pa.host);
        try testing.expectEqual(@as(u16, 9001), pa.port);
    }

    // learnAddr parses host:port (the wire form the CP carries)
    try reg.learnAddr(3, "192.168.1.5:7000");
    {
        const pa = r.resolve(3).?;
        try testing.expectEqualStrings("192.168.1.5", pa.host);
        try testing.expectEqual(@as(u16, 7000), pa.port);
    }

    // malformed addr → BadConfig; id 0 ignored
    try testing.expectError(error.BadConfig, reg.learnAddr(4, "no-colon"));
    try testing.expectError(error.BadConfig, reg.learnAddr(4, "h:notaport"));
    try reg.learn(0, "x", 1); // no-op, no entry
    try testing.expect(r.resolve(0) == null);
}
