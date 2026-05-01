//! Leader-side batching of in-flight proposals.
//!
//! Once per tick, `drainAndSubmitProposals` pulls everything from the
//! MPSC `queue` into `drain_buf`, sorts by seq, packs the eligible
//! prefix (seq ≤ safeSeq) into one or more raft log entries, and
//! submits them via `c.raft_recv_entry`. Anything past the safe
//! cutoff stays in `drain_buf` for a future tick.
//!
//! When `config.propose_linger_ns > 0` the submit step is held back
//! until either the oldest pending proposal has waited that long, or
//! the buffer hits `propose_linger_max_batch`. This amortizes the
//! per-tick `raft_recv_entry → SQLite COMMIT → fsync` across more
//! proposals under write-heavy load, at the cost of a few hundred µs
//! of latency.

const std = @import("std");
const raft_node_mod = @import("raft_node.zig");

const RaftNode = raft_node_mod.RaftNode;
const c = raft_node_mod.c;
const SEQ_PREFIX_LEN = raft_node_mod.SEQ_PREFIX_LEN;

/// Upper bound on how many write-sets we pack into a single raft log entry.
/// Matches shift-js's `batch_max_entries` default. Above this we split the
/// remainder across additional raft entries in the same tick.
const BATCH_MAX_ENTRIES: usize = 256;

/// Leader-only: drain the MPSC queue into drain_buf, sort by seq, pack
/// every entry with seq ≤ safe_seq into one or more batch envelopes,
/// submit each as a single raft log entry, and leave the rest buffered
/// for a future tick.
pub fn drainAndSubmitProposals(self: *RaftNode) !void {
    const was_empty = self.drain_buf.items.len == 0;
    while (self.queue.pop()) |framed| {
        try self.drain_buf.append(self.allocator, framed);
    }
    if (self.drain_buf.items.len == 0) {
        self.linger_start_ns = 0;
        return;
    }

    // Linger gate: hold small batches until either the time cap or
    // the size cap fires. If linger is disabled (the default) this
    // block is a no-op.
    if (self.config.propose_linger_ns > 0) {
        if (was_empty) {
            self.linger_start_ns = std.time.nanoTimestamp();
        }
        const now = std.time.nanoTimestamp();
        const waited_ns: i128 = now - self.linger_start_ns;
        const batch_full = self.drain_buf.items.len >= self.config.propose_linger_max_batch;
        const time_up = waited_ns >= @as(i128, @intCast(self.config.propose_linger_ns));
        if (!batch_full and !time_up) {
            return;
        }
    }

    const Helper = struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            const a_seq = std.mem.readInt(u64, a[0..8], .big);
            const b_seq = std.mem.readInt(u64, b[0..8], .big);
            return a_seq < b_seq;
        }
    };
    std.mem.sort([]u8, self.drain_buf.items, {}, Helper.lessThan);

    const safe = self.safeSeq();

    // Find the eligible prefix.
    var eligible: usize = 0;
    while (eligible < self.drain_buf.items.len) : (eligible += 1) {
        const framed = self.drain_buf.items[eligible];
        const seq = std.mem.readInt(u64, framed[0..8], .big);
        if (seq > safe) break;
    }
    if (eligible == 0) return;

    // Pack eligible entries into batches of up to BATCH_MAX_ENTRIES
    // each, one raft_recv_entry per batch.
    var packed_start: usize = 0;
    while (packed_start < eligible) {
        const batch_end = @min(packed_start + BATCH_MAX_ENTRIES, eligible);
        const batch_slice = self.drain_buf.items[packed_start..batch_end];

        const envelope = try packBatch(self, batch_slice);
        defer self.allocator.free(envelope);

        var entry = std.mem.zeroes(c.msg_entry_t);
        entry.type = c.RAFT_LOGTYPE_NORMAL;
        entry.data.buf = @ptrCast(envelope.ptr);
        entry.data.len = @intCast(envelope.len);
        var resp = std.mem.zeroes(c.msg_entry_response_t);
        _ = c.raft_recv_entry(self.raft, &entry, &resp);

        // The queue slots we packed are no longer needed — cbLogOffer
        // has already copied `envelope` into its own allocation for
        // willemt's in-memory log.
        for (batch_slice) |framed| self.allocator.free(framed);

        packed_start = batch_end;
    }

    // Shift the tail down over the packed prefix.
    const remaining = self.drain_buf.items.len - eligible;
    if (remaining > 0) {
        std.mem.copyForwards(
            []u8,
            self.drain_buf.items[0..remaining],
            self.drain_buf.items[eligible..],
        );
    }
    self.drain_buf.shrinkRetainingCapacity(remaining);
    // If we emptied drain_buf the linger window is closed; a future
    // non-empty pull will open a fresh window. If items remain
    // (non-eligible leftovers blocked by safeSeq) we keep the
    // existing window so they don't wait an extra linger cycle.
    if (remaining == 0) self.linger_start_ns = 0;
}

/// Encode the given sorted queue entries as a batch envelope. Caller
/// frees the returned slice. Each input is `[8B seq][body]`.
fn packBatch(self: *RaftNode, entries: []const []u8) ![]u8 {
    // Size: [4B count] + per entry [8B seq][4B body_len][body]
    var size: usize = 4;
    for (entries) |framed| {
        const body_len = framed.len - SEQ_PREFIX_LEN;
        size += 8 + 4 + body_len;
    }

    const buf = try self.allocator.alloc(u8, size);
    std.mem.writeInt(u32, buf[0..4], @intCast(entries.len), .big);
    var pos: usize = 4;

    for (entries) |framed| {
        const seq_bytes = framed[0..SEQ_PREFIX_LEN];
        const body = framed[SEQ_PREFIX_LEN..];

        @memcpy(buf[pos..][0..8], seq_bytes);
        pos += 8;
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(body.len), .big);
        pos += 4;
        @memcpy(buf[pos..][0..body.len], body);
        pos += body.len;
    }
    return buf;
}
