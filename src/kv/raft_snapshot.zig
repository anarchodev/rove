//! Snapshot subsystem for `RaftNode` — delta-based catchup, not full
//! state transfer.
//!
//! On the leader:
//!   1. Periodically, `maybeSnapshot` calls `raft_begin_snapshot` and
//!      records `snapshot_seq = committed_seq`. `raft_end_snapshot`
//!      compacts willemt's log (via log_poll callbacks).
//!   2. The current KV database IS the snapshot — no extra copy.
//! On a far-behind follower:
//!   1. willemt's `send_snapshot` callback fires on the leader.
//!   2. Leader sends SNAP_OFFER (lightweight metadata).
//!   3. Follower replies with SNAP_REQ carrying its own `kv.maxSeq()`.
//!   4. Leader queries `kv.delta(after_seq, snapshot_seq)` and sends
//!      SNAP_DATA with the missing rows.
//!   5. Follower calls `kv.putSeq` for each row, then
//!      `raft_begin_load_snapshot` / `raft_end_load_snapshot`.
//!
//! Only meaningful in `.kv` apply mode — needs a KvStore for delta
//! queries on the leader and snapshot install on the follower.

const std = @import("std");
const raft_rpc = @import("raft_rpc.zig");
const kvstore_mod = @import("kvstore.zig");
const raft_node_mod = @import("raft_node.zig");

const c = @cImport({
    @cInclude("stddef.h");
    @cInclude("raft.h");
});

const RaftNode = raft_node_mod.RaftNode;

/// Time between periodic snapshot attempts on the leader. Matches shift-js.
pub const SNAPSHOT_INTERVAL_NS: i64 = 500 * std.time.ns_per_ms;

const SNAP_OFFER_TYPE: u8 = @intFromEnum(raft_rpc.MsgType.snap_offer);
const SNAP_REQ_TYPE: u8 = @intFromEnum(raft_rpc.MsgType.snap_req);
const SNAP_DATA_TYPE: u8 = @intFromEnum(raft_rpc.MsgType.snap_data);

/// Run periodically from `tick` on the leader. If enough time has
/// passed and there's a commit to snapshot, compact the raft log.
pub fn maybeSnapshot(self: *RaftNode, now_ns: i64) void {
    if (now_ns - self.last_snapshot_attempt_ns < SNAPSHOT_INTERVAL_NS) return;
    self.last_snapshot_attempt_ns = now_ns;

    if (c.raft_snapshot_is_in_progress(self.raft) != 0) return;
    const commit_idx = c.raft_get_commit_idx(self.raft);
    const snap_last = c.raft_get_snapshot_last_idx(self.raft);
    if (commit_idx <= snap_last) return;

    doSnapshot(self);
}

/// Force a snapshot attempt right now, regardless of the periodic
/// timer. Exposed for tests and for callers that want explicit
/// control over compaction.
pub fn triggerSnapshot(self: *RaftNode) void {
    if (!self.isLeader()) return;
    if (self.config.apply != .kv) return;
    if (c.raft_snapshot_is_in_progress(self.raft) != 0) return;
    const commit_idx = c.raft_get_commit_idx(self.raft);
    const snap_last = c.raft_get_snapshot_last_idx(self.raft);
    if (commit_idx <= snap_last) return;
    doSnapshot(self);
}

fn doSnapshot(self: *RaftNode) void {
    // RAFT_SNAPSHOT_NONBLOCKING_APPLY keeps applies running while we
    // snapshot. Matches shift-js.
    if (c.raft_begin_snapshot(self.raft, c.RAFT_SNAPSHOT_NONBLOCKING_APPLY) != 0) return;

    // Record the seq boundary for delta catchups.
    const cs = self.committed_seq.load(.acquire);
    if (cs > 0) self.snapshot_seq = cs;

    // Checkpoint the KV WAL so the database on disk reflects everything
    // up to this seq. (`kv_checkpoint` is passive — doesn't block
    // readers.) Best-effort — a failed checkpoint isn't fatal.
    switch (self.config.apply) {
        .kv => |kv_cfg| kv_cfg.store.checkpoint() catch {},
        else => {},
    }

    _ = c.raft_end_snapshot(self.raft);
}

// ── Snapshot wire format helpers ───────────────────────────────────

/// Build a framed SNAP_OFFER for the given metadata. Caller frees.
/// Frame layout: `[HEADER][1B type][8B term][8B idx][8B snapshot_seq]`.
pub fn buildSnapOffer(self: *RaftNode, term: u64, idx: u64, snap_seq: u64) ![]u8 {
    const payload_len: u32 = 1 + 8 + 8 + 8;
    const total: usize = raft_rpc.HEADER_SIZE + payload_len;
    const buf = try self.allocator.alloc(u8, total);
    std.mem.writeInt(u32, buf[0..4], payload_len, .big);
    var pos: usize = raft_rpc.HEADER_SIZE;
    buf[pos] = SNAP_OFFER_TYPE;
    pos += 1;
    std.mem.writeInt(u64, buf[pos..][0..8], term, .big);
    pos += 8;
    std.mem.writeInt(u64, buf[pos..][0..8], idx, .big);
    pos += 8;
    std.mem.writeInt(u64, buf[pos..][0..8], snap_seq, .big);
    raft_rpc.finalizeFrame(buf);
    return buf;
}

/// Frame layout: `[HEADER][1B type][8B my_max_seq]`.
pub fn buildSnapReq(self: *RaftNode, my_max_seq: u64) ![]u8 {
    const payload_len: u32 = 1 + 8;
    const total: usize = raft_rpc.HEADER_SIZE + payload_len;
    const buf = try self.allocator.alloc(u8, total);
    std.mem.writeInt(u32, buf[0..4], payload_len, .big);
    var pos: usize = raft_rpc.HEADER_SIZE;
    buf[pos] = SNAP_REQ_TYPE;
    pos += 1;
    std.mem.writeInt(u64, buf[pos..][0..8], my_max_seq, .big);
    raft_rpc.finalizeFrame(buf);
    return buf;
}

/// Build a framed SNAP_DATA containing delta rows in (after_seq, through].
/// Returns null if the delta is empty.
/// Frame layout: `[HEADER][1B type][8B term][8B idx][4B count][rows...]`.
pub fn buildSnapData(
    self: *RaftNode,
    kv: *kvstore_mod.KvStore,
    term: u64,
    idx: u64,
    after_seq: u64,
    through_seq: u64,
) !?[]u8 {
    var delta = try kv.delta(after_seq, through_seq);
    defer delta.deinit();
    if (delta.entries.len == 0) return null;

    var entries_size: u32 = 0;
    for (delta.entries) |e| {
        entries_size += 4 + @as(u32, @intCast(e.key.len)) +
            4 + @as(u32, @intCast(e.value.len)) + 8;
    }

    const payload_len: u32 = 1 + 8 + 8 + 4 + entries_size;
    const total: usize = raft_rpc.HEADER_SIZE + payload_len;
    const buf = try self.allocator.alloc(u8, total);
    std.mem.writeInt(u32, buf[0..4], payload_len, .big);
    var pos: usize = raft_rpc.HEADER_SIZE;
    buf[pos] = SNAP_DATA_TYPE;
    pos += 1;
    std.mem.writeInt(u64, buf[pos..][0..8], term, .big);
    pos += 8;
    std.mem.writeInt(u64, buf[pos..][0..8], idx, .big);
    pos += 8;
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(delta.entries.len), .big);
    pos += 4;

    for (delta.entries) |e| {
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(e.key.len), .big);
        pos += 4;
        @memcpy(buf[pos..][0..e.key.len], e.key);
        pos += e.key.len;
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(e.value.len), .big);
        pos += 4;
        @memcpy(buf[pos..][0..e.value.len], e.value);
        pos += e.value.len;
        std.mem.writeInt(u64, buf[pos..][0..8], e.seq, .big);
        pos += 8;
    }
    raft_rpc.finalizeFrame(buf);
    return buf;
}

/// Apply a received SNAP_DATA payload (bytes after the 1-byte type).
/// On success, installs the snapshot into willemt via
/// `raft_begin/end_load_snapshot` and rehydrates node membership.
pub fn applySnapData(
    self: *RaftNode,
    kv: *kvstore_mod.KvStore,
    payload: []const u8,
) !void {
    if (payload.len < 8 + 8 + 4) return error.Truncated;
    var pos: usize = 0;
    const snap_term = std.mem.readInt(u64, payload[pos..][0..8], .big);
    pos += 8;
    const snap_idx = std.mem.readInt(u64, payload[pos..][0..8], .big);
    pos += 8;
    const count = std.mem.readInt(u32, payload[pos..][0..4], .big);
    pos += 4;

    try kv.begin();
    errdefer kv.rollback() catch {};

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos + 4 > payload.len) return error.Truncated;
        const klen = std.mem.readInt(u32, payload[pos..][0..4], .big);
        pos += 4;
        if (pos + klen > payload.len) return error.Truncated;
        const key = payload[pos..][0..klen];
        pos += klen;
        if (pos + 4 > payload.len) return error.Truncated;
        const vlen = std.mem.readInt(u32, payload[pos..][0..4], .big);
        pos += 4;
        if (pos + vlen > payload.len) return error.Truncated;
        const value = payload[pos..][0..vlen];
        pos += vlen;
        if (pos + 8 > payload.len) return error.Truncated;
        const entry_seq = std.mem.readInt(u64, payload[pos..][0..8], .big);
        pos += 8;

        try kv.putSeq(key, value, entry_seq);
    }

    try kv.commit();

    // Install the snapshot into willemt.
    if (c.raft_begin_load_snapshot(self.raft, @intCast(snap_term), @intCast(snap_idx)) == 0) {
        // Mark every configured node active + voting, matching
        // raft_thread.c:649-658.
        var nid: u32 = 0;
        while (nid < self.config.peers.len) : (nid += 1) {
            const node = c.raft_get_node(self.raft, @intCast(nid));
            if (node) |n| {
                c.raft_node_set_active(n, 1);
                c.raft_node_set_voting_committed(n, 1);
                c.raft_node_set_addition_committed(n, 1);
            }
        }
        _ = c.raft_end_load_snapshot(self.raft);
    }
}
