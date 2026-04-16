//! Raft peer transport.
//!
//! Direct liburing wrapper, one-to-one port of shift-js `raft_net.c`. Does
//! NOT layer on rove-io — raft is latency-sensitive (heartbeats, elections,
//! tiny frames) and rove-io's throughput-oriented deferred-move / buffer
//! group model doesn't pay off here. See memory/feedback_raft_net_direct_liburing.md.
//!
//! Owns its own io_uring; intended to run on a dedicated raft thread driven
//! by `RaftNode.tick`.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const raft_rpc = @import("raft_rpc.zig");

pub const RING_DEPTH: u16 = 256;
pub const RECV_BUF_SIZE: u32 = 512 * 1024;
pub const MAX_SEND_QUEUE: u32 = 1024;
pub const RECONNECT_INITIAL_NS: i64 = 100 * std.time.ns_per_ms;
pub const RECONNECT_MAX_NS: i64 = 5 * std.time.ns_per_s;

pub const PeerAddr = struct {
    host: []const u8,
    port: u16,
};

pub const RecvFn = *const fn (from_id: u32, payload: []const u8, ctx: ?*anyopaque) void;

pub const Error = error{
    PeerCountTooLarge,
    InvalidPeerId,
    SendQueueFull,
    NotConnected,
    ListenFailed,
    RingInitFailed,
    OutOfMemory,
} || std.mem.Allocator.Error || std.posix.SocketError;

// ── user_data encoding ────────────────────────────────────────────────
//
// Bits [63:56] = op type, bits [31:0] = peer index (outbound) or
// (peer_count + accepted_index).

const OpType = enum(u8) {
    accept = 1,
    connect = 2,
    recv = 3,
    send = 4,
};

fn encodeUd(op: OpType, idx: u32) u64 {
    return (@as(u64, @intFromEnum(op)) << 56) | @as(u64, idx);
}

fn decodeOp(ud: u64) OpType {
    return @enumFromInt(@as(u8, @truncate(ud >> 56)));
}

fn decodeIdx(ud: u64) u32 {
    return @truncate(ud);
}

// ── per-peer state ────────────────────────────────────────────────────

const PeerState = enum {
    disconnected,
    connecting,
    connected,
    self_slot,
    accepted_slot,
};

const SendItem = struct {
    data: []u8,
    sent: u32,
};

const Peer = struct {
    /// True if this slot represents a node that's currently part of the
    /// raft cluster. Slots beyond the initial config start out unconfigured
    /// and become configured via `addPeer` (driven by membership-change
    /// raft entries committing). Removed peers transition back to
    /// `configured = false`.
    configured: bool,

    fd: posix.socket_t,
    state: PeerState,
    addr: ?std.net.Address,

    recv_buf: []u8,
    recv_len: u32,
    recv_pending: bool,

    send_queue: [MAX_SEND_QUEUE]SendItem,
    send_head: u32,
    send_tail: u32,
    send_pending: bool,

    reconnect_at_ns: i64,

    /// For accepted (inbound) connections: the peer_id we've identified this
    /// connection as. maxInt(u32) until IDENT arrives.
    identified_as: u32,

    fn queueLen(self: *const Peer) u32 {
        return self.send_tail -% self.send_head;
    }

    fn queueFull(self: *const Peer) bool {
        return self.queueLen() >= MAX_SEND_QUEUE;
    }

    fn enqueueOwned(self: *Peer, frame: []u8) error{SendQueueFull}!void {
        if (self.queueFull()) return error.SendQueueFull;
        self.send_queue[self.send_tail % MAX_SEND_QUEUE] = .{ .data = frame, .sent = 0 };
        self.send_tail +%= 1;
    }

    fn dropSends(self: *Peer, allocator: std.mem.Allocator) void {
        while (self.send_head != self.send_tail) {
            allocator.free(self.send_queue[self.send_head % MAX_SEND_QUEUE].data);
            self.send_head +%= 1;
        }
        self.send_pending = false;
    }
};

// ── RaftNet ───────────────────────────────────────────────────────────

pub const Config = struct {
    node_id: u32,
    peers: []const PeerAddr,
    listen_addr: std.net.Address,
    on_recv: RecvFn,
    user_ctx: ?*anyopaque = null,
    /// Maximum cluster size this node will ever participate in. The peer
    /// table is allocated to this capacity at init; slots beyond
    /// `peers.len` start unconfigured and can later be filled via
    /// `addPeer` when a membership-change entry commits.
    max_nodes: u32 = 16,
};

pub const RaftNet = struct {
    allocator: std.mem.Allocator,
    node_id: u32,

    /// Outbound peers indexed by peer_id. `peers[node_id]` is a self slot.
    peers: []Peer,

    /// Accepted (inbound) connection slots. Grows on accept; never shrinks
    /// (matches shift-js). Dead slots stay with state=.disconnected.
    accepted: std.ArrayList(*Peer),

    listen_fd: posix.socket_t,
    ring: linux.IoUring,
    accept_pending: bool,

    on_recv: RecvFn,
    user_ctx: ?*anyopaque,

    pub fn init(
        allocator: std.mem.Allocator,
        cfg: Config,
    ) !*RaftNet {
        if (cfg.peers.len > std.math.maxInt(u16)) return Error.PeerCountTooLarge;
        if (cfg.peers.len > cfg.max_nodes) return Error.PeerCountTooLarge;
        if (cfg.node_id >= cfg.peers.len) return Error.InvalidPeerId;

        const self = try allocator.create(RaftNet);
        errdefer allocator.destroy(self);

        const peers = try allocator.alloc(Peer, cfg.max_nodes);
        errdefer allocator.free(peers);

        // Initialize every slot to "unconfigured". The configured ones are
        // populated below.
        for (peers, 0..) |*p, i| {
            p.* = .{
                .configured = false,
                .fd = -1,
                .state = .disconnected,
                .addr = null,
                .recv_buf = &.{},
                .recv_len = 0,
                .recv_pending = false,
                .send_queue = undefined,
                .send_head = 0,
                .send_tail = 0,
                .send_pending = false,
                .reconnect_at_ns = 0,
                .identified_as = @intCast(i),
            };
        }

        errdefer {
            for (peers[0..cfg.max_nodes]) |*p| {
                if (p.configured) {
                    if (p.recv_buf.len > 0) allocator.free(p.recv_buf);
                    if (p.fd >= 0) posix.close(p.fd);
                    p.dropSends(allocator);
                }
            }
        }

        for (cfg.peers, 0..) |peer_cfg, i| {
            const peer_id: u32 = @intCast(i);
            if (peer_id == cfg.node_id) {
                peers[peer_id].configured = true;
                peers[peer_id].state = .self_slot;
                continue;
            }
            const addr = try resolveHost(peer_cfg.host, peer_cfg.port);
            const buf = try allocator.alloc(u8, RECV_BUF_SIZE);
            peers[peer_id].configured = true;
            peers[peer_id].state = .disconnected;
            peers[peer_id].addr = addr;
            peers[peer_id].recv_buf = buf;
        }

        const listen_fd = try makeListenSocket(cfg.listen_addr);
        errdefer posix.close(listen_fd);

        var ring = linux.IoUring.init(RING_DEPTH, 0) catch return Error.RingInitFailed;
        errdefer ring.deinit();

        self.* = .{
            .allocator = allocator,
            .node_id = cfg.node_id,
            .peers = peers,
            .accepted = .empty,
            .listen_fd = listen_fd,
            .ring = ring,
            .accept_pending = false,
            .on_recv = cfg.on_recv,
            .user_ctx = cfg.user_ctx,
        };

        try self.submitAccept();
        _ = try self.ring.submit();

        return self;
    }

    pub fn deinit(self: *RaftNet) void {
        for (self.peers) |*p| {
            if (!p.configured) continue;
            if (p.fd >= 0) posix.close(p.fd);
            p.dropSends(self.allocator);
            if (p.recv_buf.len > 0) self.allocator.free(p.recv_buf);
        }
        for (self.accepted.items) |p| {
            if (p.fd >= 0) posix.close(p.fd);
            p.dropSends(self.allocator);
            if (p.recv_buf.len > 0) self.allocator.free(p.recv_buf);
            self.allocator.destroy(p);
        }
        self.accepted.deinit(self.allocator);
        self.allocator.free(self.peers);

        posix.close(self.listen_fd);
        self.ring.deinit();
        self.allocator.destroy(self);
    }

    // ── Public API ─────────────────────────────────────────────────────

    pub fn send(self: *RaftNet, peer_id: u32, frame: []const u8) Error!void {
        if (peer_id >= self.peers.len or peer_id == self.node_id) return Error.InvalidPeerId;
        const peer = &self.peers[peer_id];
        if (!peer.configured) return Error.InvalidPeerId;
        if (peer.state != .connected) return Error.NotConnected;
        if (peer.queueFull()) return Error.SendQueueFull;

        const copy = try self.allocator.alloc(u8, frame.len);
        errdefer self.allocator.free(copy);
        @memcpy(copy, frame);
        try peer.enqueueOwned(copy);

        self.submitSend(peer, peer_id) catch {};
        _ = self.ring.submit() catch {};
    }

    /// Add a new peer to the cluster's networking layer. Called by
    /// `RaftNode` when a membership-change entry commits. Allocates the
    /// peer's recv buffer and resolves the addr; on the next tick the
    /// reconnect loop will start dialing.
    pub fn addPeer(self: *RaftNet, peer_id: u32, addr: PeerAddr) !void {
        if (peer_id >= self.peers.len) return Error.InvalidPeerId;
        if (peer_id == self.node_id) return; // self can't be added; caller bug
        const peer = &self.peers[peer_id];
        if (peer.configured) return; // already added; idempotent

        const resolved = try resolveHost(addr.host, addr.port);
        const buf = try self.allocator.alloc(u8, RECV_BUF_SIZE);

        peer.* = .{
            .configured = true,
            .fd = -1,
            .state = .disconnected,
            .addr = resolved,
            .recv_buf = buf,
            .recv_len = 0,
            .recv_pending = false,
            .send_queue = undefined,
            .send_head = 0,
            .send_tail = 0,
            .send_pending = false,
            .reconnect_at_ns = 0,
            .identified_as = peer_id,
        };
    }

    /// Remove a peer from the cluster's networking layer. Tears down any
    /// live connection, frees buffers, and marks the slot as unconfigured.
    /// Idempotent.
    pub fn removePeer(self: *RaftNet, peer_id: u32) void {
        if (peer_id >= self.peers.len) return;
        if (peer_id == self.node_id) return;
        const peer = &self.peers[peer_id];
        if (!peer.configured) return;

        if (peer.fd >= 0) {
            posix.close(peer.fd);
            peer.fd = -1;
        }
        peer.dropSends(self.allocator);
        if (peer.recv_buf.len > 0) self.allocator.free(peer.recv_buf);

        peer.* = .{
            .configured = false,
            .fd = -1,
            .state = .disconnected,
            .addr = null,
            .recv_buf = &.{},
            .recv_len = 0,
            .recv_pending = false,
            .send_queue = undefined,
            .send_head = 0,
            .send_tail = 0,
            .send_pending = false,
            .reconnect_at_ns = 0,
            .identified_as = peer_id,
        };
    }

    /// True if `peer_id` is currently part of the cluster's peer table.
    /// Used by tests and by membership-change application logic.
    pub fn isPeerConfigured(self: *const RaftNet, peer_id: u32) bool {
        if (peer_id >= self.peers.len) return false;
        return self.peers[peer_id].configured;
    }

    /// Drive one tick. `now_ns` is a monotonic timestamp used for reconnect
    /// timing. If `wait` is true, blocks until at least one CQE arrives.
    pub fn tick(self: *RaftNet, now_ns: i64, wait: bool) !void {
        // Reconnect any dead outbound peers whose backoff has elapsed.
        for (self.peers, 0..) |*p, i| {
            if (!p.configured) continue;
            if (p.state != .disconnected) continue;
            if (p.addr == null) continue;
            if (now_ns < p.reconnect_at_ns) continue;
            self.submitConnect(@intCast(i)) catch {};
        }

        _ = self.ring.submit() catch {};

        // Drain completions.
        if (wait) {
            _ = self.ring.submit_and_wait(1) catch {};
        }

        var cqe_buf: [64]linux.io_uring_cqe = undefined;
        while (true) {
            const n = self.ring.copy_cqes(&cqe_buf, 0) catch 0;
            if (n == 0) break;
            for (cqe_buf[0..n]) |cqe| try self.handleCqe(cqe, now_ns);
        }

        _ = self.ring.submit() catch {};
    }

    // ── SQE submission helpers ─────────────────────────────────────────

    fn submitAccept(self: *RaftNet) !void {
        if (self.accept_pending) return;
        const sqe = try self.ring.get_sqe();
        sqe.prep_accept(self.listen_fd, null, null, posix.SOCK.NONBLOCK);
        sqe.user_data = encodeUd(.accept, 0);
        self.accept_pending = true;
    }

    fn submitRecv(self: *RaftNet, peer: *Peer, idx: u32) !void {
        if (peer.recv_pending or peer.fd < 0) return;
        const space = peer.recv_buf.len - peer.recv_len;
        if (space == 0) return;
        const sqe = try self.ring.get_sqe();
        sqe.prep_recv(peer.fd, peer.recv_buf[peer.recv_len..][0..space], 0);
        sqe.user_data = encodeUd(.recv, idx);
        peer.recv_pending = true;
    }

    fn submitSend(self: *RaftNet, peer: *Peer, idx: u32) !void {
        if (peer.send_pending or peer.fd < 0) return;
        if (peer.send_head == peer.send_tail) return;
        if (peer.state != .connected) return;

        const item = &peer.send_queue[peer.send_head % MAX_SEND_QUEUE];
        const remaining = item.data[item.sent..];
        const sqe = try self.ring.get_sqe();
        sqe.prep_send(peer.fd, remaining, linux.MSG.NOSIGNAL);
        sqe.user_data = encodeUd(.send, idx);
        peer.send_pending = true;
    }

    fn submitConnect(self: *RaftNet, peer_idx: u32) !void {
        const peer = &self.peers[peer_idx];
        const addr = peer.addr orelse return;

        const fd = posix.socket(
            addr.any.family,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            0,
        ) catch {
            peer.state = .disconnected;
            return;
        };

        // TCP_NODELAY for latency. Non-fatal on failure.
        posix.setsockopt(
            fd,
            posix.IPPROTO.TCP,
            linux.TCP.NODELAY,
            &std.mem.toBytes(@as(c_int, 1)),
        ) catch {};

        // Kick off a non-blocking connect. EINPROGRESS is expected.
        posix.connect(fd, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
            error.WouldBlock => {}, // EINPROGRESS
            else => {
                posix.close(fd);
                peer.state = .disconnected;
                return;
            },
        };

        peer.fd = fd;
        peer.state = .connecting;

        // Wait for POLLOUT — socket becomes writable when connect finishes.
        const sqe = try self.ring.get_sqe();
        sqe.prep_poll_add(fd, linux.POLL.OUT);
        sqe.user_data = encodeUd(.connect, peer_idx);
    }

    // ── CQE handling ───────────────────────────────────────────────────

    fn handleCqe(self: *RaftNet, cqe: linux.io_uring_cqe, now_ns: i64) !void {
        const op = decodeOp(cqe.user_data);
        const idx = decodeIdx(cqe.user_data);
        const res = cqe.res;

        switch (op) {
            .accept => try self.handleAccept(res),
            .connect => self.handleConnect(idx, res, now_ns),
            .recv => try self.handleRecv(idx, res, now_ns),
            .send => self.handleSend(idx, res, now_ns),
        }
    }

    fn handleAccept(self: *RaftNet, res: i32) !void {
        self.accept_pending = false;

        if (res >= 0) {
            const afd: posix.socket_t = @intCast(res);
            posix.setsockopt(
                afd,
                posix.IPPROTO.TCP,
                linux.TCP.NODELAY,
                &std.mem.toBytes(@as(c_int, 1)),
            ) catch {};

            const buf = self.allocator.alloc(u8, RECV_BUF_SIZE) catch {
                posix.close(afd);
                try self.submitAccept();
                return;
            };
            const slot = self.allocator.create(Peer) catch {
                self.allocator.free(buf);
                posix.close(afd);
                try self.submitAccept();
                return;
            };
            slot.* = .{
                .configured = true,
                .fd = afd,
                .state = .accepted_slot,
                .addr = null,
                .recv_buf = buf,
                .recv_len = 0,
                .recv_pending = false,
                .send_queue = undefined,
                .send_head = 0,
                .send_tail = 0,
                .send_pending = false,
                .reconnect_at_ns = 0,
                .identified_as = std.math.maxInt(u32),
            };
            self.accepted.append(self.allocator, slot) catch {
                self.allocator.destroy(slot);
                self.allocator.free(buf);
                posix.close(afd);
                try self.submitAccept();
                return;
            };
            const ai: u32 = @intCast(self.accepted.items.len - 1);
            try self.submitRecv(slot, @as(u32, @intCast(self.peers.len)) + ai);
        }

        try self.submitAccept();
    }

    fn handleConnect(self: *RaftNet, idx: u32, res: i32, now_ns: i64) void {
        const peer = &self.peers[idx];

        // Check SO_ERROR to see if the connect actually succeeded.
        var err: c_int = 0;
        var errlen: posix.socklen_t = @sizeOf(c_int);
        _ = linux.getsockopt(
            peer.fd,
            posix.SOL.SOCKET,
            posix.SO.ERROR,
            @ptrCast(&err),
            &errlen,
        );

        if (res < 0 or err != 0) {
            peerTeardown(self, peer, now_ns, .outbound);
            return;
        }

        peer.state = .connected;
        peer.reconnect_at_ns = 0;

        self.submitRecv(peer, idx) catch {
            peerTeardown(self, peer, now_ns, .outbound);
            return;
        };

        // Send IDENT so the peer can identify this outbound connection.
        const ident = raft_rpc.encodeIdent(self.allocator, self.node_id) catch {
            peerTeardown(self, peer, now_ns, .outbound);
            return;
        };
        peer.enqueueOwned(ident) catch {
            self.allocator.free(ident);
            peerTeardown(self, peer, now_ns, .outbound);
            return;
        };
        self.submitSend(peer, idx) catch {};
    }

    fn handleRecv(self: *RaftNet, idx: u32, res: i32, now_ns: i64) !void {
        const peer = self.peerByIdx(idx) orelse return;
        peer.recv_pending = false;

        if (res <= 0) {
            peerTeardown(self, peer, now_ns, if (idx < self.peers.len) .outbound else .inbound);
            return;
        }

        peer.recv_len += @intCast(res);
        try self.processFrames(peer, idx);

        if (peer.fd >= 0) {
            self.submitRecv(peer, idx) catch {};
        }
    }

    fn handleSend(self: *RaftNet, idx: u32, res: i32, now_ns: i64) void {
        const peer = self.peerByIdx(idx) orelse return;
        peer.send_pending = false;

        if (res <= 0) {
            peerTeardown(self, peer, now_ns, if (idx < self.peers.len) .outbound else .inbound);
            return;
        }

        if (peer.send_head == peer.send_tail) return;
        const item = &peer.send_queue[peer.send_head % MAX_SEND_QUEUE];
        item.sent += @intCast(res);
        if (item.sent >= item.data.len) {
            self.allocator.free(item.data);
            peer.send_head +%= 1;
        }

        self.submitSend(peer, idx) catch {};
    }

    // ── Frame reassembly ───────────────────────────────────────────────

    fn processFrames(self: *RaftNet, peer: *Peer, idx: u32) !void {
        while (peer.recv_len >= raft_rpc.HEADER_SIZE) {
            const header = peer.recv_buf[0..raft_rpc.HEADER_SIZE];
            const payload_len = raft_rpc.frameLen(header);
            const expected_crc = raft_rpc.frameCrc(header);
            const frame_total: u32 = @as(u32, @intCast(raft_rpc.HEADER_SIZE)) + payload_len;
            if (peer.recv_len < frame_total) break;

            const payload = peer.recv_buf[raft_rpc.HEADER_SIZE..frame_total];

            // Validate CRC before delivering the payload anywhere. A
            // mismatch means transit corruption or a buggy peer — either
            // way the connection is untrustworthy from here on.
            const actual_crc = raft_rpc.checksum(payload);
            if (actual_crc != expected_crc) {
                std.log.warn(
                    "raft_net node{d}: CRC mismatch on frame from peer idx={d} (expected {x}, got {x})",
                    .{ self.node_id, idx, expected_crc, actual_crc },
                );
                peerTeardown(self, peer, 0, if (idx < self.peers.len) .outbound else .inbound);
                return;
            }
            var handled = false;

            // Inbound peer waiting for IDENT: the first frame MUST identify
            // the sender. Consume it (not delivered to on_recv).
            if (idx >= self.peers.len and peer.identified_as == std.math.maxInt(u32)) {
                if (payload.len >= 5 and payload[0] == @intFromEnum(raft_rpc.MsgType.ident)) {
                    const sender = std.mem.readInt(u32, payload[1..5], .big);
                    if (sender < self.peers.len and sender != self.node_id) {
                        peer.identified_as = sender;
                    }
                    handled = true;
                } else {
                    // First frame wasn't IDENT — drop the connection.
                    peerTeardown(self, peer, 0, .inbound);
                    return;
                }
            }

            if (!handled) {
                const from_id: u32 = if (idx < self.peers.len) idx else peer.identified_as;
                if (from_id != std.math.maxInt(u32)) {
                    self.on_recv(from_id, payload, self.user_ctx);
                }
            }

            const remaining: u32 = peer.recv_len - frame_total;
            if (remaining > 0) {
                std.mem.copyForwards(
                    u8,
                    peer.recv_buf[0..remaining],
                    peer.recv_buf[frame_total..peer.recv_len],
                );
            }
            peer.recv_len = remaining;
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────

    fn peerByIdx(self: *RaftNet, idx: u32) ?*Peer {
        if (idx < self.peers.len) return &self.peers[idx];
        const ai = idx - @as(u32, @intCast(self.peers.len));
        if (ai >= self.accepted.items.len) return null;
        return self.accepted.items[ai];
    }
};

const Kind = enum { outbound, inbound };

fn peerTeardown(self: *RaftNet, peer: *Peer, now_ns: i64, kind: Kind) void {
    if (peer.fd >= 0) {
        posix.close(peer.fd);
        peer.fd = -1;
    }
    peer.recv_len = 0;
    peer.recv_pending = false;
    peer.send_pending = false;
    peer.dropSends(self.allocator);

    switch (kind) {
        .outbound => {
            peer.state = .disconnected;
            if (peer.reconnect_at_ns == 0) {
                peer.reconnect_at_ns = now_ns + RECONNECT_INITIAL_NS;
            } else {
                var delay: i64 = (now_ns - peer.reconnect_at_ns + RECONNECT_INITIAL_NS) * 2;
                if (delay > RECONNECT_MAX_NS) delay = RECONNECT_MAX_NS;
                peer.reconnect_at_ns = now_ns + delay;
            }
        },
        .inbound => {
            peer.state = .disconnected;
        },
    }
}

fn makeListenSocket(addr: std.net.Address) !posix.socket_t {
    const fd = try posix.socket(
        addr.any.family,
        posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
        0,
    );
    errdefer posix.close(fd);

    try posix.setsockopt(
        fd,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );

    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.listen(fd, 16);
    return fd;
}

fn resolveHost(host: []const u8, port: u16) !std.net.Address {
    if (std.net.Address.parseIp(host, port)) |a| return a else |_| {}
    var list = try std.net.getAddressList(std.heap.page_allocator, host, port);
    defer list.deinit();
    if (list.addrs.len == 0) return error.UnknownHostName;
    return list.addrs[0];
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const Captured = struct {
    mu: std.Thread.Mutex = .{},
    items: std.ArrayList(struct { from: u32, payload: []u8 }) = .empty,
    allocator: std.mem.Allocator,

    fn deinit(self: *Captured) void {
        for (self.items.items) |it| self.allocator.free(it.payload);
        self.items.deinit(self.allocator);
    }
};

fn captureRecv(from_id: u32, payload: []const u8, ctx: ?*anyopaque) void {
    const cap: *Captured = @ptrCast(@alignCast(ctx.?));
    cap.mu.lock();
    defer cap.mu.unlock();
    const copy = cap.allocator.alloc(u8, payload.len) catch return;
    @memcpy(copy, payload);
    cap.items.append(cap.allocator, .{ .from = from_id, .payload = copy }) catch {
        cap.allocator.free(copy);
    };
}

test "two RaftNets exchange a frame over loopback" {
    const allocator = testing.allocator;

    const port_a: u16 = 39301;
    const port_b: u16 = 39302;
    const addr_a = try std.net.Address.parseIp("127.0.0.1", port_a);
    const addr_b = try std.net.Address.parseIp("127.0.0.1", port_b);

    var cap_a = Captured{ .allocator = allocator };
    defer cap_a.deinit();
    var cap_b = Captured{ .allocator = allocator };
    defer cap_b.deinit();

    const peers = [_]PeerAddr{
        .{ .host = "127.0.0.1", .port = port_a },
        .{ .host = "127.0.0.1", .port = port_b },
    };

    const a = try RaftNet.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = addr_a,
        .on_recv = captureRecv,
        .user_ctx = &cap_a,
    });
    defer a.deinit();

    const b = try RaftNet.init(allocator, .{
        .node_id = 1,
        .peers = &peers,
        .listen_addr = addr_b,
        .on_recv = captureRecv,
        .user_ctx = &cap_b,
    });
    defer b.deinit();

    var sent = false;
    const deadline_ns: i128 = std.time.nanoTimestamp() + 2 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < deadline_ns) {
        const now: i64 = @intCast(std.time.nanoTimestamp());
        try a.tick(now, false);
        try b.tick(now, false);

        if (!sent and a.peers[1].state == .connected and b.peers[0].state == .connected) {
            const frame_a_to_b = try raft_rpc.encodeVoteReq(allocator, .{
                .term = 1,
                .candidate_id = 0,
                .last_log_idx = 0,
                .last_log_term = 0,
            });
            defer allocator.free(frame_a_to_b);
            try a.send(1, frame_a_to_b);

            const frame_b_to_a = try raft_rpc.encodeVoteResp(allocator, .{
                .term = 1,
                .vote_granted = 1,
            });
            defer allocator.free(frame_b_to_a);
            try b.send(0, frame_b_to_a);

            sent = true;
        }

        if (sent) {
            cap_a.mu.lock();
            const a_count = cap_a.items.items.len;
            cap_a.mu.unlock();
            cap_b.mu.lock();
            const b_count = cap_b.items.items.len;
            cap_b.mu.unlock();
            if (a_count >= 1 and b_count >= 1) break;
        }
    }

    try testing.expect(sent);
    try testing.expect(cap_a.items.items.len >= 1);
    try testing.expect(cap_b.items.items.len >= 1);

    var msg_a = try raft_rpc.decode(allocator, cap_a.items.items[0].payload);
    defer msg_a.deinit(allocator);
    try testing.expect(msg_a == .vote_resp);

    var msg_b = try raft_rpc.decode(allocator, cap_b.items.items[0].payload);
    defer msg_b.deinit(allocator);
    try testing.expect(msg_b == .vote_req);
}
