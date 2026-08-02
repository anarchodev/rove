// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Static multi-node raft bootstrap config, parsed from the environment.
//!
//! The worker (`rewind-worker`, env prefix `REWIND_`) and the control
//! plane (`rewind-cp`, prefix `REWIND_CP_`) form their clusters from the
//! same three variables; only the prefix differs. A bug in voter-set /
//! peer-index parsing is a split-brain or wrong-listen-address hazard,
//! so the parser lives ONCE here rather than as a hand-mirrored copy per
//! binary. Required together (`fromEnv` returns null when `{p}NODE_ID`
//! is unset — the single-node deployment):
//!
//!   - `{prefix}NODE_ID`  this node's 1-based raft id (∈ the voter set).
//!   - `{prefix}VOTERS`   comma-separated voter ids, e.g. `1,2,3`.
//!   - `{prefix}PEERS`    comma-separated raft transport `host:port`s,
//!                        indexed by raft id − 1 (peer i ⇒ raft id i+1).
//!                        These are the cross-node consensus ports,
//!                        DISTINCT from the binary's HTTP listen port.
//!
//! The node's own raft listen address is `peers[node_id − 1]`. Errors
//! loud on malformed / inconsistent config — a misconfigured cluster
//! must fail at startup, not elect strangely later.

const std = @import("std");
const transport_mod = @import("transport.zig");

pub const PeerAddr = transport_mod.PeerAddr;

pub const Error = error{
    MissingVoters,
    MissingPeers,
    BadPeer,
    BadNodeId,
    BadAddr,
    Overflow,
    InvalidCharacter,
    InvalidIPAddressFormat,
    OutOfMemory,
};

/// A `host:port` split on the LAST colon (hosts are IP literals /
/// hostnames; the port is mandatory). Slices borrow the input.
pub const HostPort = struct { host: []const u8, port: u16 };

pub fn splitHostPort(t: []const u8) Error!HostPort {
    const colon = std.mem.lastIndexOfScalar(u8, t, ':') orelse return Error.BadAddr;
    const port = std.fmt.parseInt(u16, t[colon + 1 ..], 10) catch return Error.BadAddr;
    return .{ .host = t[0..colon], .port = port };
}

/// Parsed multi-node bridge config, owned for the lifetime of the
/// `Bridge.initMultiNode` call (the node/transport dupes what it keeps,
/// so callers free this right after).
pub const MultiNode = struct {
    node_id: u64,
    voters: []u64,
    peers: []PeerAddr,
    /// Backing storage for the peer host slices (`host:port` left of `:`).
    peer_bufs: [][]u8,
    listen_addr: std.net.Address,
    listen_str: []u8,

    pub fn deinit(self: *const MultiNode, a: std.mem.Allocator) void {
        a.free(self.voters);
        a.free(self.peers);
        for (self.peer_bufs) |b| a.free(b);
        a.free(self.peer_bufs);
        a.free(self.listen_str);
    }
};

/// Build the multi-node config from `{env_prefix}NODE_ID` / `VOTERS` /
/// `PEERS`, or return null if `{env_prefix}NODE_ID` is unset
/// (single-node). See the file header for the variable contract.
pub fn fromEnv(a: std.mem.Allocator, comptime env_prefix: []const u8) Error!?MultiNode {
    const node_id_s = std.posix.getenv(env_prefix ++ "NODE_ID") orelse return null;
    const voters_s = std.posix.getenv(env_prefix ++ "VOTERS") orelse return Error.MissingVoters;
    const peers_s = std.posix.getenv(env_prefix ++ "PEERS") orelse return Error.MissingPeers;

    const node_id = try std.fmt.parseInt(u64, std.mem.trim(u8, node_id_s, " \t"), 10);

    var voters: std.ArrayListUnmanaged(u64) = .empty;
    errdefer voters.deinit(a);
    var vit = std.mem.tokenizeScalar(u8, voters_s, ',');
    while (vit.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (t.len == 0) continue;
        try voters.append(a, try std.fmt.parseInt(u64, t, 10));
    }
    if (voters.items.len == 0) return Error.MissingVoters;

    var peers: std.ArrayListUnmanaged(PeerAddr) = .empty;
    errdefer peers.deinit(a);
    var peer_bufs: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (peer_bufs.items) |b| a.free(b);
        peer_bufs.deinit(a);
    }
    var pit = std.mem.tokenizeScalar(u8, peers_s, ',');
    while (pit.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (t.len == 0) continue;
        const hp = splitHostPort(t) catch return Error.BadPeer;
        const host = try a.dupe(u8, hp.host);
        errdefer a.free(host);
        try peer_bufs.append(a, host);
        try peers.append(a, .{ .host = host, .port = hp.port });
    }
    if (node_id == 0 or node_id > peers.items.len) return Error.BadNodeId;

    const listen = peers.items[node_id - 1];
    const listen_addr = try std.net.Address.parseIp(listen.host, listen.port);
    const listen_str = try std.fmt.allocPrint(a, "{s}:{d}", .{ listen.host, listen.port });

    return MultiNode{
        .node_id = node_id,
        .voters = try voters.toOwnedSlice(a),
        .peers = try peers.toOwnedSlice(a),
        .peer_bufs = try peer_bufs.toOwnedSlice(a),
        .listen_addr = listen_addr,
        .listen_str = listen_str,
    };
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "splitHostPort: splits on the LAST colon, rejects portless input" {
    const hp = try splitHostPort("10.0.0.1:9001");
    try testing.expectEqualStrings("10.0.0.1", hp.host);
    try testing.expectEqual(@as(u16, 9001), hp.port);
    try testing.expectError(Error.BadAddr, splitHostPort("nohost"));
    try testing.expectError(Error.BadAddr, splitHostPort("h:notaport"));
}

test "fromEnv: null without {prefix}NODE_ID; loud on partial config" {
    // The test process doesn't carry ROVE_TEST_CLUSTERCFG_* vars, so the
    // unset-prefix path returns null.
    try testing.expect((try fromEnv(testing.allocator, "ROVE_TEST_CLUSTERCFG_")) == null);
}
