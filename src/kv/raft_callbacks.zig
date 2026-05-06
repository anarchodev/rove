//! willemt C callbacks + their helpers. Pure FFI glue: each callback
//! casts the udata back to `*RaftNode`, reads/mutates fields, and
//! returns a C status.
//!
//! Wired at init time in `raft_node.zig` via `c.raft_set_callbacks`.
//! No callback holds state of its own — RaftNode owns everything; the
//! callbacks just act on it through the udata pointer.

const std = @import("std");
const raft_node_mod = @import("raft_node.zig");
const raft_rpc = @import("raft_rpc.zig");
const writeset = @import("writeset.zig");
const snapshot = @import("raft_snapshot.zig");

const c = raft_node_mod.c;

const RaftNode = raft_node_mod.RaftNode;

fn ctxFrom(udata: ?*anyopaque) *RaftNode {
    return @ptrCast(@alignCast(udata.?));
}

pub fn cbSendRequestVote(
    raft: ?*c.raft_server_t,
    udata: ?*anyopaque,
    node: ?*c.raft_node_t,
    msg: [*c]c.msg_requestvote_t,
) callconv(.c) c_int {
    _ = raft;
    const self = ctxFrom(udata);
    const peer_id: u32 = @intCast(c.raft_node_get_id(node));
    const frame = raft_rpc.encodeVoteReq(self.allocator, .{
        .term = @intCast(msg.*.term),
        .candidate_id = @intCast(msg.*.candidate_id),
        .last_log_idx = @intCast(msg.*.last_log_idx),
        .last_log_term = @intCast(msg.*.last_log_term),
    }) catch return -1;
    defer self.allocator.free(frame);
    self.transport.send(peer_id, frame) catch {};
    return 0;
}

pub fn cbSendAppendEntries(
    raft: ?*c.raft_server_t,
    udata: ?*anyopaque,
    node: ?*c.raft_node_t,
    msg: [*c]c.msg_appendentries_t,
) callconv(.c) c_int {
    _ = raft;
    const self = ctxFrom(udata);
    const peer_id: u32 = @intCast(c.raft_node_get_id(node));

    // Translate willemt entries → raft_rpc.Entry slice.
    const n_entries: usize = @intCast(msg.*.n_entries);
    var entries_buf: [16]raft_rpc.Entry = undefined;

    var entries_slice: []raft_rpc.Entry = if (n_entries == 0)
        &.{}
    else if (n_entries <= entries_buf.len)
        entries_buf[0..n_entries]
    else blk: {
        // Tiny static fast path; for huge batches fall back to alloc.
        const heap = self.allocator.alloc(raft_rpc.Entry, n_entries) catch return -1;
        break :blk heap;
    };
    defer if (n_entries > entries_buf.len) self.allocator.free(entries_slice);

    var i: usize = 0;
    while (i < n_entries) : (i += 1) {
        const e = &msg.*.entries[i];
        const data_len: usize = @intCast(e.*.data.len);
        const data_ptr: [*]u8 = @ptrCast(e.*.data.buf);
        entries_slice[i] = .{
            .term = @intCast(e.*.term),
            .id = @intCast(e.*.id),
            .type = @intCast(e.*.type),
            .data = data_ptr[0..data_len],
        };
    }

    const frame = raft_rpc.encodeAppendReq(self.allocator, .{
        .term = @intCast(msg.*.term),
        .prev_log_idx = @intCast(msg.*.prev_log_idx),
        .prev_log_term = @intCast(msg.*.prev_log_term),
        .leader_commit = @intCast(msg.*.leader_commit),
        .entries = entries_slice,
    }) catch return -1;
    defer self.allocator.free(frame);
    self.transport.send(peer_id, frame) catch {};
    return 0;
}

pub fn cbSendSnapshot(
    raft: ?*c.raft_server_t,
    udata: ?*anyopaque,
    node: ?*c.raft_node_t,
) callconv(.c) c_int {
    _ = raft;
    const self = ctxFrom(udata);
    const peer_id: u32 = @intCast(c.raft_node_get_id(node));

    const snap_idx: u64 = @intCast(c.raft_get_snapshot_last_idx(self.raft));
    const snap_term: u64 = @intCast(c.raft_get_snapshot_last_term(self.raft));

    const frame = snapshot.buildSnapOffer(self, snap_term, snap_idx, self.snapshot_seq) catch return -1;
    defer self.allocator.free(frame);
    self.transport.send(peer_id, frame) catch {};
    return 0;
}

pub fn cbApplyLog(
    raft: ?*c.raft_server_t,
    udata: ?*anyopaque,
    entry: [*c]c.raft_entry_t,
    entry_idx: c.raft_index_t,
) callconv(.c) c_int {
    const self = ctxFrom(udata);

    // Membership entries: willemt handles its own internal node-table
    // updates synchronously inside `raft_offer_log` (commit time isn't
    // when willemt records the change — offer time is). We mirror the
    // mutation into RaftNet from cbLogOffer / cbLogPop, NOT here. This
    // callback is just a no-op for membership types so that willemt's
    // commit accounting still works.
    if (entry.*.type != c.RAFT_LOGTYPE_NORMAL) {
        self.committed_idx.store(@intCast(entry_idx), .release);
        return 0;
    }

    const data_len: usize = @intCast(entry.*.data.len);
    const data_ptr: [*]const u8 = @ptrCast(entry.*.data.buf);
    const envelope = data_ptr[0..data_len];

    // Walk the batch envelope. See module doc for layout.
    if (envelope.len < 4) return 0;
    const count = std.mem.readInt(u32, envelope[0..4], .big);
    var pos: usize = 4;

    const is_leader = c.raft_is_leader(raft) != 0;
    var max_seq_this_batch: u64 = 0;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos + 8 + 4 > envelope.len) return -1;
        const seq = std.mem.readInt(u64, envelope[pos..][0..8], .big);
        pos += 8;
        const body_len = std.mem.readInt(u32, envelope[pos..][0..4], .big);
        pos += 4;
        if (pos + body_len > envelope.len) return -1;
        const body = envelope[pos..][0..body_len];
        pos += body_len;

        switch (self.config.apply) {
            .opaque_bytes => |ob| ob.apply_fn(@intCast(entry_idx), body, ob.ctx),
            .kv => |kv_cfg| {
                // Leader skips the apply — workers wrote locally in the
                // txn that assigned the seq, BEFORE proposing. Followers
                // replay the write-set into their own KvStore.
                if (!is_leader) {
                    // .kv apply mode predates the snapshot model;
                    // pass null `apply_idx` so the per-store
                    // `_apply_state` stamp doesn't fire. Phase
                    // 5.5(c)'s snapshot model only targets
                    // `.opaque_bytes`.
                    writeset.applyEncoded(kv_cfg.store, seq, body, null) catch |err| {
                        std.log.warn(
                            "raft_node: follower apply failed at idx={d} seq={d}: {s}",
                            .{ entry_idx, seq, @errorName(err) },
                        );
                        return -1;
                    };
                }
            },
        }

        if (seq > max_seq_this_batch) max_seq_this_batch = seq;
    }

    // Advance committed_seq to the largest seq we saw in this batch.
    var old = self.committed_seq.load(.monotonic);
    while (max_seq_this_batch > old) {
        if (self.committed_seq.cmpxchgWeak(old, max_seq_this_batch, .release, .monotonic)) |actual| {
            old = actual;
        } else break;
    }

    self.committed_idx.store(@intCast(entry_idx), .release);

    // Drain the WAL passively after each committed batch. With batching in
    // place (P1.6), this runs at the batch cadence — orders of magnitude
    // lower than the raw worker-commit rate — so the probe cost is bounded
    // even under hot write loads.
    //
    // Only meaningful in kv-apply mode. PASSIVE never blocks readers;
    // a non-zero `log_pages - ckpt_pages` just means a reader is holding
    // frames and we'll reclaim them next time.
    if (self.config.apply == .kv) {
        const result = self.config.apply.kv.store.checkpointV2() catch {
            return 0; // best-effort; failure here doesn't fail the apply
        };
        self.last_wal_log_pages = result.log_pages;
    }

    return 0;
}

// ── Membership change application (offer/pop time) ────────────────────

/// Mirror an ADD_NODE entry into RaftNet. Payload format matches what
/// `proposeAddNode` builds: `[4B node_id][4B IPv4][2B port]`. Called from
/// `cbLogOffer` when the entry is offered (leader or follower) and from
/// `cbLogPop` when a REMOVE_NODE entry is truncated.
fn offerAddNode(self: *RaftNode, entry: [*c]c.raft_entry_t) !void {
    if (entry.*.data.len < raft_node_mod.MEMBERSHIP_ADD_PAYLOAD_LEN) return error.Truncated;
    const buf: [*]const u8 = @ptrCast(entry.*.data.buf);
    const node_id = std.mem.readInt(u32, buf[0..4], .big);
    const ip0 = buf[4];
    const ip1 = buf[5];
    const ip2 = buf[6];
    const ip3 = buf[7];
    const port = std.mem.readInt(u16, buf[8..10], .big);

    var host_buf: [16]u8 = undefined;
    const host = std.fmt.bufPrint(&host_buf, "{d}.{d}.{d}.{d}", .{ ip0, ip1, ip2, ip3 }) catch return error.Truncated;

    if (node_id != self.config.node_id) {
        self.transport.addPeer(node_id, .{ .host = host, .port = port }) catch |err| {
            std.log.warn("raft_node: addPeer({d}) failed: {s}", .{ node_id, @errorName(err) });
            return err;
        };
    }
}

/// Mirror a REMOVE_NODE entry into RaftNet. Payload format: `[4B node_id]`.
/// Called from `cbLogOffer` and from `cbLogPop` when an ADD_NODE entry is
/// truncated.
fn offerRemoveNode(self: *RaftNode, entry: [*c]c.raft_entry_t) void {
    if (entry.*.data.len < raft_node_mod.MEMBERSHIP_REMOVE_PAYLOAD_LEN) return;
    const buf: [*]const u8 = @ptrCast(entry.*.data.buf);
    const node_id = std.mem.readInt(u32, buf[0..4], .big);
    if (node_id == self.config.node_id) return;
    self.transport.removePeer(node_id);
}

/// willemt calls this for every config-change log entry to learn which
/// node id the entry refers to. Used internally for raft_offer_log,
/// raft_apply_entry, and raft_pop_log to update willemt's own node table.
pub fn cbLogGetNodeId(
    _: ?*c.raft_server_t,
    _: ?*anyopaque,
    entry: [*c]c.raft_entry_t,
    _: c.raft_index_t,
) callconv(.c) c.raft_node_id_t {
    if (entry.*.data.len < 4 or entry.*.data.buf == null) return -1;
    const buf: [*]const u8 = @ptrCast(entry.*.data.buf);
    const node_id = std.mem.readInt(u32, buf[0..4], .big);
    return @intCast(node_id);
}

pub fn cbPersistVote(_: ?*c.raft_server_t, udata: ?*anyopaque, vote: c.raft_node_id_t) callconv(.c) c_int {
    const self = ctxFrom(udata);
    if (self.raft_log) |rl| {
        const term: u64 = @intCast(c.raft_get_current_term(self.raft));
        rl.saveState(term, @intCast(vote)) catch return -1;
    }
    return 0;
}

pub fn cbPersistTerm(_: ?*c.raft_server_t, udata: ?*anyopaque, term: c.raft_term_t, vote: c.raft_node_id_t) callconv(.c) c_int {
    const self = ctxFrom(udata);
    if (self.raft_log) |rl| {
        rl.saveState(@intCast(term), @intCast(vote)) catch return -1;
    }
    return 0;
}

/// Take ownership of the entry payload by copying it into a fresh allocation
/// and overwriting `entry->data.buf`. The copy is freed in log_pop / log_poll
/// / log_clear. If persistence is enabled and we're not replaying a restored
/// entry, append to the RaftLog as well.
///
/// For membership entries (ADD_NODE / REMOVE_NODE), also mirror the change
/// into RaftNet's peer table at offer time. willemt does its own offer-time
/// update of its internal node table; we keep RaftNet in sync so that the
/// new peer can be dialed BEFORE the membership entry commits (the entry
/// can't commit until the peer acks, so RaftNet must be ready first).
pub fn cbLogOffer(
    _: ?*c.raft_server_t,
    udata: ?*anyopaque,
    entry: [*c]c.raft_entry_t,
    entry_idx: c.raft_index_t,
) callconv(.c) c_int {
    const self = ctxFrom(udata);
    if (entry.*.data.len == 0 or entry.*.data.buf == null) return 0;
    const len: usize = @intCast(entry.*.data.len);
    const copy = self.allocator.alloc(u8, len) catch return -1;
    const src: [*]const u8 = @ptrCast(entry.*.data.buf);
    @memcpy(copy, src[0..len]);
    entry.*.data.buf = @ptrCast(copy.ptr);

    if (self.raft_log) |rl| {
        if (!self.replaying) {
            rl.append(
                @intCast(entry_idx),
                @intCast(entry.*.term),
                copy,
            ) catch {
                self.allocator.free(copy);
                entry.*.data.buf = null;
                entry.*.data.len = 0;
                return -1;
            };
        }
    }

    // Mirror membership changes into RaftNet at offer time.
    switch (entry.*.type) {
        c.RAFT_LOGTYPE_ADD_NODE => offerAddNode(self, entry) catch return -1,
        c.RAFT_LOGTYPE_REMOVE_NODE => offerRemoveNode(self, entry),
        else => {},
    }
    return 0;
}

fn freeEntryData(self: *RaftNode, entry: [*c]c.raft_entry_t) void {
    if (entry.*.data.buf == null or entry.*.data.len == 0) return;
    const len: usize = @intCast(entry.*.data.len);
    const ptr: [*]u8 = @ptrCast(entry.*.data.buf);
    self.allocator.free(ptr[0..len]);
    entry.*.data.buf = null;
    entry.*.data.len = 0;
}

pub fn cbLogPop(_: ?*c.raft_server_t, udata: ?*anyopaque, entry: [*c]c.raft_entry_t, entry_idx: c.raft_index_t) callconv(.c) c_int {
    const self = ctxFrom(udata);
    if (self.raft_log) |rl| {
        // Pop removes the newest entry (truncation on conflict). Keep
        // entries strictly below entry_idx.
        rl.truncateAfter(@intCast(entry_idx - 1)) catch return -1;
    }

    // Undo any RaftNet mutation we made at offer time. Reverses the
    // direction of the entry: a truncated ADD becomes a removePeer, a
    // truncated REMOVE becomes an addPeer (we have the addr from the
    // payload).
    switch (entry.*.type) {
        c.RAFT_LOGTYPE_ADD_NODE => offerRemoveNode(self, entry),
        c.RAFT_LOGTYPE_REMOVE_NODE => offerAddNode(self, entry) catch {},
        else => {},
    }

    freeEntryData(self, entry);
    return 0;
}

pub fn cbLogPoll(_: ?*c.raft_server_t, udata: ?*anyopaque, entry: [*c]c.raft_entry_t, entry_idx: c.raft_index_t) callconv(.c) c_int {
    const self = ctxFrom(udata);
    if (self.raft_log) |rl| {
        // Poll removes the oldest entry (compaction). Delete entries
        // with index <= entry_idx.
        rl.truncateBefore(@intCast(entry_idx)) catch return -1;
    }
    freeEntryData(self, entry);
    return 0;
}

pub fn cbLogClear(_: ?*c.raft_server_t, udata: ?*anyopaque, entry: [*c]c.raft_entry_t, _: c.raft_index_t) callconv(.c) c_int {
    // log_clear fires on raft_clear() — only used at shutdown in our flow.
    // Do NOT touch the RaftLog: the persisted entries should survive for
    // the next restart. Just free the in-memory copy.
    freeEntryData(ctxFrom(udata), entry);
    return 0;
}
