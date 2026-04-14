//! Maelstrom adapter for rove-kv linearizability testing.
//!
//! Reads line-delimited Maelstrom JSON messages on stdin, handles the
//! `lin-kv` workload + a custom `raft_frame` message type used for
//! peer-to-peer raft transport. Peer network traffic flows entirely
//! through Maelstrom's simulated network, so fault injection (partitions,
//! crashes) actually affects consensus.
//!
//! Usage:
//!
//!   ./zig-out/bin/kv-maelstrom   # invoked per node by the maelstrom runner
//!
//!   maelstrom test -w lin-kv \
//!       --bin ./zig-out/bin/kv-maelstrom \
//!       --node-count 3 \
//!       --time-limit 30 \
//!       --concurrency 4n \
//!       --rate 100
//!
//!   maelstrom test -w lin-kv \
//!       --bin ./zig-out/bin/kv-maelstrom \
//!       --node-count 3 \
//!       --time-limit 30 \
//!       --nemesis partition \
//!       --nemesis-interval 3

const std = @import("std");
const posix = std.posix;
const rove_kv = @import("rove-kv");
const raft_node_mod = rove_kv.raft_node;
const raft_net_mod = rove_kv.raft_net;

const RaftNode = rove_kv.RaftNode;
const Transport = rove_kv.raft_node.Transport;
const PeerAddr = rove_kv.RaftPeerAddr;

// ── Maelstrom transport ─────────────────────────────────────────────────
//
// Implements the raft Transport vtable by serializing raft frames into
// Maelstrom JSON messages of type `raft_frame`. Writes go to stdout
// (guarded by a mutex because willemt callbacks can fire from within
// onRecvFrame). Inbound frames are dispatched by the main loop when it
// sees a raft_frame message and calls `RaftNode.onRecvFrame` directly —
// the transport's job on recv is just to not-get-in-the-way.

const MaelstromTransport = struct {
    allocator: std.mem.Allocator,
    /// Our Maelstrom node id, e.g. "n1".
    my_id: []const u8,
    /// All Maelstrom node ids in cluster order. `node_ids[i]` is the
    /// string id corresponding to integer peer_id `i`. Borrowed from the
    /// Adapter which owns the backing storage.
    node_ids: [][]const u8,
    /// Guards stdout writes and the encoding scratch buffer. Willemt
    /// callbacks can fire from several places in a tick and they all
    /// ultimately call through send().
    stdout_mu: std.Thread.Mutex = .{},
    stdout: *std.fs.File.Writer,
    /// Monotonically increasing message id for outbound messages.
    msg_id: std.atomic.Value(u64) = .init(1),

    fn nextMsgId(self: *MaelstromTransport) u64 {
        return self.msg_id.fetchAdd(1, .monotonic);
    }

    // Vtable impls ────────────────────────────────────────────────────

    fn send(ptr: *anyopaque, peer_id: u32, frame: []const u8) anyerror!void {
        const self: *MaelstromTransport = @ptrCast(@alignCast(ptr));
        if (peer_id >= self.node_ids.len) return error.InvalidPeerId;
        const dest = self.node_ids[peer_id];

        // Base64-encode the binary frame.
        const encoder = std.base64.standard.Encoder;
        const encoded_len = encoder.calcSize(frame.len);
        const encoded = try self.allocator.alloc(u8, encoded_len);
        defer self.allocator.free(encoded);
        _ = encoder.encode(encoded, frame);

        self.stdout_mu.lock();
        defer self.stdout_mu.unlock();

        const w = &self.stdout.interface;
        try w.print(
            \\{{"src":"{s}","dest":"{s}","body":{{"type":"raft_frame","msg_id":{d},"data":"{s}"}}}}
            ++ "\n",
            .{ self.my_id, dest, self.nextMsgId(), encoded },
        );
        try w.flush();
    }

    fn tick(_: *anyopaque, _: i64) anyerror!void {
        // No-op. The main loop drives RaftNode.tick directly; our
        // transport's tick has nothing to pump because reads come from
        // stdin (handled in the main loop, not here) and writes happen
        // synchronously in send().
    }

    fn addPeer(_: *anyopaque, _: u32, _: PeerAddr) anyerror!void {
        // Maelstrom clusters are fixed-membership for the lin-kv
        // workload; dynamic reconfiguration isn't exercised. No-op.
    }

    fn removePeer(_: *anyopaque, _: u32) void {}

    fn isPeerConfigured(ptr: *anyopaque, peer_id: u32) bool {
        const self: *MaelstromTransport = @ptrCast(@alignCast(ptr));
        return peer_id < self.node_ids.len;
    }

    const vtable: Transport.VTable = .{
        .send = send,
        .tick = tick,
        .add_peer = addPeer,
        .remove_peer = removePeer,
        .is_peer_configured = isPeerConfigured,
    };

    fn asTransport(self: *MaelstromTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

// ── Adapter state ───────────────────────────────────────────────────────

/// A client request that has been proposed to raft and is waiting for
/// `committedSeq() >= seq` (reply) or `faultedSeq() >= seq` (error).
/// Owned by the adapter; looked up by seq from applyOpaque and from the
/// post-tick sweep that fails out faulted proposals.
const PendingReply = struct {
    client: []u8, // owned dest string, freed on completion
    msg_id: i64,
    kind: Kind,

    const Kind = enum { write, cas };
};

const Adapter = struct {
    allocator: std.mem.Allocator,
    arena_scratch: std.heap.ArenaAllocator,

    stdin: *std.fs.File.Reader,
    stdout: *std.fs.File.Writer,
    stderr: *std.fs.File.Writer,

    node_ids_owned: [][]u8, // backing strings
    node_ids: [][]const u8, // view the transport uses
    my_id_str: []u8, // owned
    my_index: u32 = 0,

    transport: MaelstromTransport = undefined,
    node: ?*RaftNode = null,

    /// Monotonic seq allocator for propose() calls. Maelstrom's main
    /// loop is single-threaded so plain increment is fine, but we keep
    /// it atomic for safety.
    next_seq: std.atomic.Value(u64) = .init(1),

    /// Pending client replies, keyed by proposal seq. When a seq commits
    /// (applyOpaque fires) we send the reply and remove from here. When a
    /// seq faults (faultedSeq advances past it) the post-tick sweep
    /// replaces the pending entry with an error reply.
    pending_replies: std.AutoHashMap(u64, PendingReply) = undefined,

    /// Highest seq we've already swept for faults. Monotonic; only used
    /// by `sweepFaulted` to avoid re-walking the pending_replies map
    /// when nothing has changed.
    last_faulted_sweep: u64 = 0,

    fn allocSeq(self: *Adapter) u64 {
        return self.next_seq.fetchAdd(1, .monotonic);
    }

    fn log(self: *Adapter, comptime fmt: []const u8, args: anytype) void {
        const w = &self.stderr.interface;
        w.print(fmt ++ "\n", args) catch return;
        w.flush() catch return;
    }

    fn writeJson(self: *Adapter, comptime fmt: []const u8, args: anytype) !void {
        self.transport.stdout_mu.lock();
        defer self.transport.stdout_mu.unlock();
        const w = &self.stdout.interface;
        try w.print(fmt ++ "\n", args);
        try w.flush();
    }
};

// ── Main loop ───────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdout_buf: [64 * 1024]u8 = undefined;
    var stderr_buf: [4 * 1024]u8 = undefined;

    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);

    var adapter: Adapter = .{
        .allocator = allocator,
        .arena_scratch = std.heap.ArenaAllocator.init(allocator),
        .stdin = &stdin_reader,
        .stdout = &stdout_writer,
        .stderr = &stderr_writer,
        .node_ids_owned = &.{},
        .node_ids = &.{},
        .my_id_str = &.{},
        .pending_replies = std.AutoHashMap(u64, PendingReply).init(allocator),
    };
    defer {
        adapter.arena_scratch.deinit();
        if (adapter.node) |n| n.deinit();
        for (adapter.node_ids_owned) |s| allocator.free(s);
        allocator.free(adapter.node_ids_owned);
        allocator.free(adapter.node_ids);
        allocator.free(adapter.my_id_str);
        // Free any leaked pending-reply client strings.
        var it = adapter.pending_replies.iterator();
        while (it.next()) |kv| allocator.free(kv.value_ptr.client);
        adapter.pending_replies.deinit();
        if (global_kv_initialized) {
            global_kv.deinit();
            global_kv_initialized = false;
        }
    }
    adapter.transport = .{
        .allocator = allocator,
        .my_id = "",
        .node_ids = &.{},
        .stdout = &stdout_writer,
    };

    adapter.log("kv-maelstrom: starting", .{});

    const r = &stdin_reader.interface;
    const stdin_fd = std.fs.File.stdin().handle;

    // Main loop: poll stdin non-blocking with a short timeout so raft
    // ticks run even when no client traffic is arriving. When data is
    // ready we drain as many complete lines as the buffer holds, then
    // tick; otherwise we just tick on timeout.
    var pfds: [1]posix.pollfd = .{.{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 }};

    while (true) {
        _ = adapter.arena_scratch.reset(.retain_capacity);

        const poll_rc = posix.poll(&pfds, 5) catch |err| {
            adapter.log("kv-maelstrom: poll error: {s}", .{@errorName(err)});
            break;
        };
        if (poll_rc > 0 and (pfds[0].revents & (posix.POLL.IN | posix.POLL.HUP)) != 0) {
            // Drain as many complete lines as are already buffered.
            // takeDelimiter returns null on HUP with no remaining bytes,
            // which we treat as clean EOF.
            while (true) {
                const maybe_line = r.takeDelimiter('\n') catch |err| switch (err) {
                    error.StreamTooLong => {
                        adapter.log("kv-maelstrom: line too long, dropping", .{});
                        break;
                    },
                    error.ReadFailed => {
                        adapter.log("kv-maelstrom: stdin closed", .{});
                        return;
                    },
                };
                const line = maybe_line orelse return; // EOF
                if (line.len == 0) continue;
                handleLine(&adapter, line) catch |err| {
                    adapter.log("kv-maelstrom: handleLine error: {s}", .{@errorName(err)});
                };
                // Only keep draining if another line is already in the
                // buffer — bufferedEnd > seek means there's more data.
                if (r.bufferedLen() == 0) break;
            }
        }

        if (adapter.node) |n| {
            n.tick(@intCast(std.time.nanoTimestamp())) catch |err| {
                adapter.log("kv-maelstrom: tick error: {s}", .{@errorName(err)});
            };
            sweepFaulted(&adapter) catch {};
        }
    }
}

fn handleLine(adapter: *Adapter, line: []const u8) !void {
    const arena = adapter.arena_scratch.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});

    const body = parsed.object.get("body") orelse return error.MissingBody;
    const body_obj = body.object;
    const type_val = body_obj.get("type") orelse return error.MissingType;
    const msg_type = type_val.string;

    if (std.mem.eql(u8, msg_type, "init")) {
        try handleInit(adapter, parsed);
        return;
    }

    // All other message types require the node to exist.
    if (adapter.node == null) {
        adapter.log("kv-maelstrom: got {s} before init", .{msg_type});
        return;
    }

    // Client request forwarding: if we're not the leader and we know who
    // is, rewrite `dest` to the leader and re-emit on our stdout. The
    // leader processes and replies directly to the client. Only applies
    // to lin-kv client requests, not raft frames.
    if (std.mem.eql(u8, msg_type, "read") or
        std.mem.eql(u8, msg_type, "write") or
        std.mem.eql(u8, msg_type, "cas"))
    {
        const node = adapter.node.?;
        if (!node.isLeader()) {
            const leader = node.leaderId();
            if (leader >= 0 and leader < adapter.node_ids.len and
                @as(usize, @intCast(leader)) != adapter.my_index)
            {
                try forwardToLeader(adapter, line, adapter.node_ids[@intCast(leader)]);
                return;
            }
            // No known leader — fall through to the handler which will
            // reject with "not leader".
        }
    }

    if (std.mem.eql(u8, msg_type, "raft_frame")) {
        try handleRaftFrame(adapter, parsed);
    } else if (std.mem.eql(u8, msg_type, "read")) {
        try handleRead(adapter, parsed);
    } else if (std.mem.eql(u8, msg_type, "write")) {
        try handleWrite(adapter, parsed);
    } else if (std.mem.eql(u8, msg_type, "cas")) {
        try handleCas(adapter, parsed);
    } else {
        adapter.log("kv-maelstrom: unknown type '{s}'", .{msg_type});
    }
}

/// Forward the raw JSON `line` to the leader by rewriting its `dest`
/// field in place. Preserves `src` so the leader's reply goes straight
/// to the original client.
fn forwardToLeader(adapter: *Adapter, line: []const u8, leader_id: []const u8) !void {
    // Parse once more, rebuild the JSON with a replaced dest. We keep
    // src and body intact. std.json.Value.object.put mutates in place
    // so we can re-stringify via std.json.Stringify.
    const arena = adapter.arena_scratch.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    var obj = parsed.object;
    try obj.put("dest", .{ .string = leader_id });
    const fixed = std.json.Value{ .object = obj };

    adapter.transport.stdout_mu.lock();
    defer adapter.transport.stdout_mu.unlock();
    const w = &adapter.stdout.interface;
    try std.json.Stringify.value(fixed, .{}, w);
    try w.writeByte('\n');
    try w.flush();
}

fn handleInit(adapter: *Adapter, parsed: std.json.Value) !void {
    const body = parsed.object.get("body").?.object;
    const src = parsed.object.get("src").?.string;
    const node_id_str = body.get("node_id").?.string;
    const node_ids_val = body.get("node_ids").?.array;
    const msg_id = if (body.get("msg_id")) |v| v.integer else 0;

    // Copy ids into long-lived storage.
    const n = node_ids_val.items.len;
    const owned = try adapter.allocator.alloc([]u8, n);
    errdefer adapter.allocator.free(owned);
    const views = try adapter.allocator.alloc([]const u8, n);
    errdefer adapter.allocator.free(views);

    for (node_ids_val.items, 0..) |v, i| {
        owned[i] = try adapter.allocator.dupe(u8, v.string);
        views[i] = owned[i];
    }
    adapter.node_ids_owned = owned;
    adapter.node_ids = views;

    adapter.my_id_str = try adapter.allocator.dupe(u8, node_id_str);
    adapter.my_index = blk: {
        for (views, 0..) |id, i| {
            if (std.mem.eql(u8, id, node_id_str)) break :blk @intCast(i);
        }
        return error.SelfNotInNodeIds;
    };

    adapter.log(
        "kv-maelstrom: init as {s} (index {d}, {d} nodes)",
        .{ node_id_str, adapter.my_index, n },
    );

    // Build the peer list for RaftNode. Addresses are dummies since the
    // Maelstrom transport doesn't use them, but the peer count has to
    // match for quorum math.
    const peers_cfg = try adapter.arena_scratch.allocator().alloc(PeerAddr, n);
    for (peers_cfg, 0..) |*p, i| {
        p.* = .{ .host = "127.0.0.1", .port = @intCast(40000 + i) };
    }

    // Wire the transport.
    adapter.transport.my_id = adapter.my_id_str;
    adapter.transport.node_ids = adapter.node_ids;

    const cfg: raft_node_mod.Config = .{
        .node_id = adapter.my_index,
        .peers = peers_cfg,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 40000),
        .apply = .{ .opaque_bytes = .{ .apply_fn = applyOpaque, .ctx = adapter } },
        .election_timeout_ms = 1000,
        .request_timeout_ms = 250,
    };

    adapter.node = try RaftNode.initWithTransport(
        adapter.allocator,
        cfg,
        adapter.transport.asTransport(),
    );

    // init_ok reply.
    try adapter.writeJson(
        \\{{"src":"{s}","dest":"{s}","body":{{"type":"init_ok","in_reply_to":{d}}}}}
    , .{ adapter.my_id_str, src, msg_id });
}

fn handleRaftFrame(adapter: *Adapter, parsed: std.json.Value) !void {
    const body = parsed.object.get("body").?.object;
    const src = parsed.object.get("src").?.string;
    const data_b64 = body.get("data").?.string;

    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(data_b64);
    const buf = try adapter.arena_scratch.allocator().alloc(u8, decoded_len);
    try decoder.decode(buf, data_b64);

    // Resolve src Maelstrom id → integer peer_id.
    const from_id: u32 = blk: {
        for (adapter.node_ids, 0..) |id, i| {
            if (std.mem.eql(u8, id, src)) break :blk @intCast(i);
        }
        adapter.log("kv-maelstrom: raft_frame from unknown peer '{s}'", .{src});
        return;
    };

    // We're handed the bytes INCLUDING the raft_rpc frame header (length
    // + CRC + payload). RaftNode.onRecvFrame wants just the payload —
    // i.e., what the existing `processFrames` passes to `on_recv`. Strip
    // the header here. Skip the CRC check: Maelstrom's transport is
    // lossless-or-partitioned, so if bytes arrived they're intact.
    const raft_rpc = rove_kv.raft_rpc;
    if (buf.len < raft_rpc.HEADER_SIZE) return;
    const payload_len = raft_rpc.frameLen(buf[0..raft_rpc.HEADER_SIZE]);
    const total: usize = raft_rpc.HEADER_SIZE + payload_len;
    if (buf.len < total) return;
    const payload = buf[raft_rpc.HEADER_SIZE..total];

    adapter.node.?.onRecvFrame(from_id, payload);
}

// ── lin-kv workload ─────────────────────────────────────────────────────
//
// Maelstrom's lin-kv sends `read`/`write`/`cas` with integer keys and
// integer values. We serialize key and value as JSON strings via the
// opaque_bytes path — each proposed entry's payload is
//   `[1B op][8B key LE][8B value LE]`
// where op = 1 for write, 2 for cas (we currently handle only write;
// cas is approximated as a read-then-write since we don't have MVCC).
//
// In-memory KV is a simple AutoHashMap(u64, u64) on the adapter. The
// apply_fn copies each committed write into the map on every node.

const OpWrite: u8 = 1;
const OpCas: u8 = 2;

pub const CasOutcome = enum { ok, precondition_failed, key_not_found };

var global_kv_mu: std.Thread.Mutex = .{};
var global_kv: std.AutoHashMap(u64, u64) = undefined;
var global_kv_initialized: bool = false;

/// Maps `seq` → `CasOutcome` for cas proposals that have committed but
/// whose reply hasn't been sent yet. Populated in applyOpaque, drained
/// in handleCas. Single-threaded access from the main loop; no mutex
/// needed. Lives on the adapter (see Adapter.pending_cas).
fn ensureKvInit(allocator: std.mem.Allocator) void {
    if (!global_kv_initialized) {
        global_kv = std.AutoHashMap(u64, u64).init(allocator);
        global_kv_initialized = true;
    }
}

fn applyOpaque(_: u64, payload: []const u8, ctx: ?*anyopaque) void {
    const adapter: *Adapter = @ptrCast(@alignCast(ctx.?));
    ensureKvInit(adapter.allocator);
    if (payload.len < 1) return;
    const op = payload[0];

    var committed_seq: u64 = 0;
    var op_seq: u64 = 0;
    var cas_outcome: ?CasOutcome = null;

    global_kv_mu.lock();
    defer global_kv_mu.unlock();

    switch (op) {
        OpWrite => {
            if (payload.len < 1 + 8 + 8 + 8) return;
            const key = std.mem.readInt(u64, payload[1..9], .little);
            const value = std.mem.readInt(u64, payload[9..17], .little);
            op_seq = std.mem.readInt(u64, payload[17..25], .little);
            global_kv.put(key, value) catch return;
            committed_seq = op_seq;
        },
        OpCas => {
            if (payload.len < 1 + 8 + 8 + 8 + 8) return;
            const key = std.mem.readInt(u64, payload[1..9], .little);
            const expected = std.mem.readInt(u64, payload[9..17], .little);
            const new_value = std.mem.readInt(u64, payload[17..25], .little);
            op_seq = std.mem.readInt(u64, payload[25..33], .little);

            const outcome: CasOutcome = blk: {
                const entry = global_kv.getEntry(key) orelse break :blk .key_not_found;
                if (entry.value_ptr.* != expected) break :blk .precondition_failed;
                entry.value_ptr.* = new_value;
                break :blk .ok;
            };
            cas_outcome = outcome;
            committed_seq = op_seq;
        },
        else => {},
    }

    // If this node is the one that accepted the client's request, we have
    // a PendingReply keyed by op_seq — fire it now.
    if (committed_seq == 0) return;
    const entry = adapter.pending_replies.fetchRemove(committed_seq) orelse return;
    sendCompletion(adapter, entry.value, cas_outcome) catch |err| {
        adapter.log("kv-maelstrom: send completion failed: {s}", .{@errorName(err)});
    };
}

/// Send the final client reply for a committed write/cas proposal and
/// free the pending-reply record's owned client string.
fn sendCompletion(adapter: *Adapter, reply: PendingReply, cas_outcome: ?CasOutcome) !void {
    defer adapter.allocator.free(reply.client);
    switch (reply.kind) {
        .write => {
            try adapter.writeJson(
                \\{{"src":"{s}","dest":"{s}","body":{{"type":"write_ok","in_reply_to":{d}}}}}
            , .{ adapter.my_id_str, reply.client, reply.msg_id });
        },
        .cas => {
            const outcome = cas_outcome orelse .ok;
            switch (outcome) {
                .ok => try adapter.writeJson(
                    \\{{"src":"{s}","dest":"{s}","body":{{"type":"cas_ok","in_reply_to":{d}}}}}
                , .{ adapter.my_id_str, reply.client, reply.msg_id }),
                .precondition_failed => try adapter.writeJson(
                    \\{{"src":"{s}","dest":"{s}","body":{{"type":"error","in_reply_to":{d},"code":22,"text":"precondition failed"}}}}
                , .{ adapter.my_id_str, reply.client, reply.msg_id }),
                .key_not_found => try adapter.writeJson(
                    \\{{"src":"{s}","dest":"{s}","body":{{"type":"error","in_reply_to":{d},"code":20,"text":"key not found"}}}}
                , .{ adapter.my_id_str, reply.client, reply.msg_id }),
            }
        },
    }
}

/// After each tick, walk pending_replies and fail out any whose seq has
/// fallen into the faulted range. Uses `last_faulted_sweep` as a
/// high-water mark so repeated calls are cheap when nothing has changed.
fn sweepFaulted(adapter: *Adapter) !void {
    const node = adapter.node orelse return;
    const faulted = node.faultedSeq();
    if (faulted == 0 or faulted == adapter.last_faulted_sweep) return;
    adapter.last_faulted_sweep = faulted;

    // Collect keys to remove; removing while iterating is fragile.
    var to_remove: std.ArrayList(u64) = .empty;
    defer to_remove.deinit(adapter.allocator);

    var it = adapter.pending_replies.iterator();
    while (it.next()) |kv| {
        if (kv.key_ptr.* <= faulted and kv.key_ptr.* > node.committedSeq()) {
            try to_remove.append(adapter.allocator, kv.key_ptr.*);
        }
    }

    for (to_remove.items) |seq| {
        const entry = adapter.pending_replies.fetchRemove(seq) orelse continue;
        defer adapter.allocator.free(entry.value.client);
        adapter.writeJson(
            \\{{"src":"{s}","dest":"{s}","body":{{"type":"error","in_reply_to":{d},"code":14,"text":"faulted"}}}}
        , .{ adapter.my_id_str, entry.value.client, entry.value.msg_id }) catch {};
    }
}

fn handleRead(adapter: *Adapter, parsed: std.json.Value) !void {
    const src = parsed.object.get("src").?.string;
    const body = parsed.object.get("body").?.object;
    const msg_id = body.get("msg_id").?.integer;
    const key = @as(u64, @intCast(body.get("key").?.integer));

    const node = adapter.node.?;
    // Linearizable reads require the leader lease. On a follower or on
    // a leader that's lost contact with a majority, reject — Maelstrom
    // will retry against a different node.
    if (!node.isLeasedLeader(@intCast(std.time.nanoTimestamp()))) {
        try adapter.writeJson(
            \\{{"src":"{s}","dest":"{s}","body":{{"type":"error","in_reply_to":{d},"code":11,"text":"not leader"}}}}
        , .{ adapter.my_id_str, src, msg_id });
        return;
    }

    ensureKvInit(adapter.allocator);
    global_kv_mu.lock();
    const value_opt = global_kv.get(key);
    global_kv_mu.unlock();

    if (value_opt) |value| {
        try adapter.writeJson(
            \\{{"src":"{s}","dest":"{s}","body":{{"type":"read_ok","in_reply_to":{d},"value":{d}}}}}
        , .{ adapter.my_id_str, src, msg_id, value });
    } else {
        try adapter.writeJson(
            \\{{"src":"{s}","dest":"{s}","body":{{"type":"error","in_reply_to":{d},"code":20,"text":"key not found"}}}}
        , .{ adapter.my_id_str, src, msg_id });
    }
}

fn handleWrite(adapter: *Adapter, parsed: std.json.Value) !void {
    const src = parsed.object.get("src").?.string;
    const body = parsed.object.get("body").?.object;
    const msg_id = body.get("msg_id").?.integer;
    const key = @as(u64, @intCast(body.get("key").?.integer));
    const value = @as(u64, @intCast(body.get("value").?.integer));

    const node = adapter.node.?;
    if (!node.isLeader()) {
        try adapter.writeJson(
            \\{{"src":"{s}","dest":"{s}","body":{{"type":"error","in_reply_to":{d},"code":11,"text":"not leader"}}}}
        , .{ adapter.my_id_str, src, msg_id });
        return;
    }

    const seq = adapter.allocSeq();

    // Wire format: [op=1][8 key LE][8 value LE][8 seq LE]. The seq
    // suffix is so applyOpaque can locate the matching PendingReply
    // without extra state beyond the raft entry itself.
    var payload: [1 + 8 + 8 + 8]u8 = undefined;
    payload[0] = OpWrite;
    std.mem.writeInt(u64, payload[1..9], key, .little);
    std.mem.writeInt(u64, payload[9..17], value, .little);
    std.mem.writeInt(u64, payload[17..25], seq, .little);

    // Register the pending reply BEFORE proposing, so if the commit
    // lands quickly (on this very tick) applyOpaque can find it.
    const client_owned = try adapter.allocator.dupe(u8, src);
    errdefer adapter.allocator.free(client_owned);
    try adapter.pending_replies.put(seq, .{
        .client = client_owned,
        .msg_id = msg_id,
        .kind = .write,
    });

    node.propose(seq, &payload) catch |err| {
        _ = adapter.pending_replies.remove(seq);
        adapter.allocator.free(client_owned);
        try adapter.writeJson(
            \\{{"src":"{s}","dest":"{s}","body":{{"type":"error","in_reply_to":{d},"code":14,"text":"propose failed: {s}"}}}}
        , .{ adapter.my_id_str, src, msg_id, @errorName(err) });
        return;
    };
    // Reply is fire-and-forget from here — applyOpaque or sweepFaulted
    // will complete it later.
}

fn handleCas(adapter: *Adapter, parsed: std.json.Value) !void {
    const src = parsed.object.get("src").?.string;
    const body = parsed.object.get("body").?.object;
    const msg_id = body.get("msg_id").?.integer;
    const key = @as(u64, @intCast(body.get("key").?.integer));
    const from_val = @as(u64, @intCast(body.get("from").?.integer));
    const to_val = @as(u64, @intCast(body.get("to").?.integer));

    const node = adapter.node.?;
    if (!node.isLeader()) {
        try adapter.writeJson(
            \\{{"src":"{s}","dest":"{s}","body":{{"type":"error","in_reply_to":{d},"code":11,"text":"not leader"}}}}
        , .{ adapter.my_id_str, src, msg_id });
        return;
    }

    const seq = adapter.allocSeq();

    // Payload: [op=2][8 key LE][8 expected LE][8 new LE][8 seq LE]
    var payload: [1 + 8 + 8 + 8 + 8]u8 = undefined;
    payload[0] = OpCas;
    std.mem.writeInt(u64, payload[1..9], key, .little);
    std.mem.writeInt(u64, payload[9..17], from_val, .little);
    std.mem.writeInt(u64, payload[17..25], to_val, .little);
    std.mem.writeInt(u64, payload[25..33], seq, .little);

    const client_owned = try adapter.allocator.dupe(u8, src);
    errdefer adapter.allocator.free(client_owned);
    try adapter.pending_replies.put(seq, .{
        .client = client_owned,
        .msg_id = msg_id,
        .kind = .cas,
    });

    node.propose(seq, &payload) catch |err| {
        _ = adapter.pending_replies.remove(seq);
        adapter.allocator.free(client_owned);
        try adapter.writeJson(
            \\{{"src":"{s}","dest":"{s}","body":{{"type":"error","in_reply_to":{d},"code":14,"text":"propose failed: {s}"}}}}
        , .{ adapter.my_id_str, src, msg_id, @errorName(err) });
        return;
    };
}
