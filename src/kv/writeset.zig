// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Write-set: a batch of KV operations proposed as a single raft entry.
//!
//! Port of shift-js's raft_write_set_t model. The leader writes each op to
//! its LOCAL KvStore (outside this module — the worker does it in its txn),
//! then submits the write-set as a raft entry. Followers receive the
//! replicated entry and replay the ops against their own KvStore — see
//! `applyEncoded` / `applyEncodedDirect` below.
//!
//! Wire format:
//!
//!   [4B op_count]
//!   per op:
//!     [1B type][4B klen][klen bytes key][4B vlen][vlen bytes value]
//!
//! Op types: 1 = PUT, 2 = DELETE. DELETE has vlen = 0.

const std = @import("std");
const kvstore = @import("kvstore.zig");
const usage = @import("usage.zig");

pub const OpType = enum(u8) {
    put = 1,
    delete = 2,
};

pub const Op = union(OpType) {
    put: struct { key: []const u8, value: []const u8 },
    delete: struct { key: []const u8 },
};

pub const DecodeError = error{
    Truncated,
    UnknownOpType,
};

/// Mutable builder. `addPut` / `addDelete` copy the input bytes into
/// allocator-owned storage that `deinit` frees — this lets callers compose
/// a write-set from short-lived stack buffers without worrying about
/// lifetimes.
pub const WriteSet = struct {
    allocator: std.mem.Allocator,
    ops: std.ArrayList(Op),
    /// Storage for key/value bytes we've copied in. Freed on deinit.
    owned: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator) WriteSet {
        return .{
            .allocator = allocator,
            .ops = .empty,
            .owned = .empty,
        };
    }

    pub fn deinit(self: *WriteSet) void {
        for (self.owned.items) |buf| self.allocator.free(buf);
        self.owned.deinit(self.allocator);
        self.ops.deinit(self.allocator);
    }

    /// Truncate back to a caller-captured (ops_len, owned_len)
    /// boundary, freeing the truncated copies — the arena-OOM retry
    /// discards ONLY the doomed attempt's contribution (the writeset
    /// is shared across a batch; a wholesale clear would eat sibling
    /// handlers' ops).
    pub fn truncateTo(self: *WriteSet, ops_len: usize, owned_len: usize) void {
        var i = self.owned.items.len;
        while (i > owned_len) : (i -= 1) {
            self.allocator.free(self.owned.items[i - 1]);
        }
        self.owned.shrinkRetainingCapacity(owned_len);
        self.ops.shrinkRetainingCapacity(ops_len);
    }

    pub fn addPut(self: *WriteSet, key: []const u8, value: []const u8) !void {
        const k = try self.copyBytes(key);
        errdefer self.popOwned();
        const v = try self.copyBytes(value);
        errdefer self.popOwned();
        try self.ops.append(self.allocator, .{ .put = .{ .key = k, .value = v } });
    }

    pub fn addDelete(self: *WriteSet, key: []const u8) !void {
        const k = try self.copyBytes(key);
        errdefer self.popOwned();
        try self.ops.append(self.allocator, .{ .delete = .{ .key = k } });
    }

    /// True iff the writeset has a `put` or `delete` op targeting
    /// exactly `key`. The capture-side "minimal read set" gate
    /// (`docs/effect-algebra.md`) uses this to decide whether a kv.get
    /// is a foreign read (record) or an own-read (skip; replay will
    /// resolve from its own writeset overlay).
    ///
    /// Linear scan; the typical writeset is single-digit ops, and
    /// the call lives on the capture-time kv.get path which itself
    /// touches the LMDB read txn. Trading a small linear scan for a
    /// tape-size reduction; revisit if writesets routinely grow
    /// past dozens of ops.
    pub fn containsKey(self: *const WriteSet, key: []const u8) bool {
        for (self.ops.items) |op| {
            const op_key = switch (op) {
                .put => |p| p.key,
                .delete => |d| d.key,
            };
            if (std.mem.eql(u8, op_key, key)) return true;
        }
        return false;
    }

    fn copyBytes(self: *WriteSet, src: []const u8) ![]u8 {
        const dst = try self.allocator.alloc(u8, src.len);
        errdefer self.allocator.free(dst);
        @memcpy(dst, src);
        try self.owned.append(self.allocator, dst);
        return dst;
    }

    fn popOwned(self: *WriteSet) void {
        const last = self.owned.pop() orelse return;
        self.allocator.free(last);
    }

    /// Number of bytes `encodeInto` will write for the current contents.
    pub fn encodedSize(self: *const WriteSet) usize {
        var n: usize = 4; // op_count
        for (self.ops.items) |op| {
            switch (op) {
                .put => |p| n += 1 + 4 + p.key.len + 4 + p.value.len,
                .delete => |d| n += 1 + 4 + d.key.len + 4 + 0,
            }
        }
        return n;
    }

    /// Encode into a fresh owned buffer. Caller frees.
    pub fn encode(self: *const WriteSet, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, self.encodedSize());
        encodeInto(self, buf);
        return buf;
    }

    fn encodeInto(self: *const WriteSet, buf: []u8) void {
        var pos: usize = 0;
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(self.ops.items.len), .big);
        pos += 4;

        for (self.ops.items) |op| {
            switch (op) {
                .put => |p| {
                    buf[pos] = @intFromEnum(OpType.put);
                    pos += 1;
                    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(p.key.len), .big);
                    pos += 4;
                    @memcpy(buf[pos..][0..p.key.len], p.key);
                    pos += p.key.len;
                    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(p.value.len), .big);
                    pos += 4;
                    @memcpy(buf[pos..][0..p.value.len], p.value);
                    pos += p.value.len;
                },
                .delete => |d| {
                    buf[pos] = @intFromEnum(OpType.delete);
                    pos += 1;
                    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(d.key.len), .big);
                    pos += 4;
                    @memcpy(buf[pos..][0..d.key.len], d.key);
                    pos += d.key.len;
                    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
                    pos += 4;
                },
            }
        }
    }
};

/// Decode and apply an encoded write-set payload against `kv`, using `seq`
/// for every PUT. Wraps the ops in a single begin/commit transaction. On
/// error, rolls back (on a best-effort basis) and returns the error.
///
/// No allocation: keys/values are borrowed by pointer straight out
/// of `payload` into the kvexp txn (which copies them into its
/// overlay on `put`), safe because `payload` outlives the txn here.
pub fn applyEncoded(
    kv: *kvstore.KvStore,
    seq: u64,
    payload: []const u8,
) !void {
    var r: Reader = .{ .data = payload, .pos = 0 };
    const op_count = try r.u32be();

    try kv.begin();
    errdefer kv.rollback() catch {};

    var i: u32 = 0;
    while (i < op_count) : (i += 1) {
        const type_byte = try r.byte();
        const key_len = try r.u32be();
        const key = try r.bytes(key_len);
        const val_len = try r.u32be();
        const value = try r.bytes(val_len);

        const op_type = std.meta.intToEnum(OpType, type_byte) catch return DecodeError.UnknownOpType;
        switch (op_type) {
            .put => try kv.putSeq(key, value, seq),
            .delete => try kv.delete(key),
        }
    }

    try kv.commit();
}

/// `applyEncoded` for the CONSENSUS APPLY path: routes every op through
/// the chain-bypassing authoritative writes (`KvStore.applyPut` /
/// `applyDelete`) instead of the speculative txn machinery. A follower
/// applying a committed entry must not sequence behind — or fail on —
/// the tenant's open local txn chain (`NotChainHead`); the entry is
/// already the cluster's truth. `seq` is accepted for signature
/// symmetry; kvexp does not persist a per-op seq.
pub fn applyEncodedDirect(
    kv: *kvstore.KvStore,
    seq: u64,
    payload: []const u8,
) !void {
    _ = seq;
    var r: Reader = .{ .data = payload, .pos = 0 };
    const op_count = try r.u32be();

    var i: u32 = 0;
    while (i < op_count) : (i += 1) {
        const type_byte = try r.byte();
        const key_len = try r.u32be();
        const key = try r.bytes(key_len);
        const val_len = try r.u32be();
        const value = try r.bytes(val_len);

        const op_type = std.meta.intToEnum(OpType, type_byte) catch return DecodeError.UnknownOpType;
        switch (op_type) {
            .put => try kv.applyPut(key, value),
            .delete => try kv.applyDelete(key),
        }
    }
}

/// Scan an encoded writeset for a PUT op against `key` and return
/// its value, or null if no such op (or the op is a delete). Read-
/// only — does not commit, does not allocate. Returned slice points
/// into `payload`; caller must copy if it needs to outlive the
/// payload buffer.
///
/// Used by follower-side apply paths that need to react to specific
/// keys without re-iterating the whole apply. The decoder bails
/// silently on truncation (returning null) — the apply path itself
/// rejects malformed writesets loudly, so by the time this runs
/// the payload has been validated.
pub fn scanPutValue(payload: []const u8, key: []const u8) ?[]const u8 {
    var r: Reader = .{ .data = payload, .pos = 0 };
    const op_count = r.u32be() catch return null;
    var i: u32 = 0;
    while (i < op_count) : (i += 1) {
        const type_byte = r.byte() catch return null;
        const key_len = r.u32be() catch return null;
        const k = r.bytes(key_len) catch return null;
        const val_len = r.u32be() catch return null;
        const v = r.bytes(val_len) catch return null;

        const op_type = std.meta.intToEnum(OpType, type_byte) catch return null;
        if (op_type == .put and std.mem.eql(u8, k, key)) return v;
    }
    return null;
}

/// Decode an encoded writeset payload into its ops, appending to
/// `out`. Key/value slices BORROW into `payload` (valid as long as
/// it is) — zero-copy, like `scanPutValue`. The apply path already
/// rejected malformed payloads loudly before any consumer of this
/// runs; truncation/bad-type returns the error after a partial fill
/// (callers may treat best-effort). Used to decode replicated writeset
/// bytes back into ops (e.g. the apply observer's per-put notification).
pub fn decodeOps(
    payload: []const u8,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(Op),
) !void {
    var r: Reader = .{ .data = payload, .pos = 0 };
    const op_count = try r.u32be();
    var i: u32 = 0;
    while (i < op_count) : (i += 1) {
        const type_byte = try r.byte();
        const key_len = try r.u32be();
        const k = try r.bytes(key_len);
        const val_len = try r.u32be();
        const v = try r.bytes(val_len);
        const op_type = std.meta.intToEnum(OpType, type_byte) catch
            return DecodeError.UnknownOpType;
        switch (op_type) {
            .put => try out.append(allocator, .{ .put = .{ .key = k, .value = v } }),
            .delete => try out.append(allocator, .{ .delete = .{ .key = k } }),
        }
    }
}

const Reader = struct {
    data: []const u8,
    pos: usize,

    fn remaining(self: *const Reader) usize {
        return self.data.len - self.pos;
    }

    fn byte(self: *Reader) DecodeError!u8 {
        if (self.remaining() < 1) return DecodeError.Truncated;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }

    fn u32be(self: *Reader) DecodeError!u32 {
        if (self.remaining() < 4) return DecodeError.Truncated;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    fn bytes(self: *Reader, n: u32) DecodeError![]const u8 {
        if (self.remaining() < n) return DecodeError.Truncated;
        const slice = self.data[self.pos..][0..n];
        self.pos += n;
        return slice;
    }
};

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Which write path a test is standing in for.
const Path = enum {
    /// The LEADER: the worker writes rows straight into its speculative
    /// overlay and proposes. Under `worker_overlay` the leader then SKIPS the
    /// store apply, so the writeset never runs through `applyEncoded*` here.
    leader_overlay,
    /// A FOLLOWER: no worker, no overlay — the committed entry is written by
    /// the apply path.
    follower_apply,
};

const Row = struct { pool: usage.Pool, hash: []const u8, len: []const u8 };

fn writeRows(kv: *kvstore.KvStore, path: Path, rows: []const Row) !void {
    var ws = WriteSet.init(testing.allocator);
    defer ws.deinit();
    var key_buf: [usage.ROW_KEY_MAX]u8 = undefined;
    for (rows) |r| {
        const key = usage.rowKey(&key_buf, r.pool, r.hash);
        switch (path) {
            // The overlay write the worker performs before proposing.
            .leader_overlay => try kv.put(key, r.len),
            .follower_apply => try ws.addPut(key, r.len),
        }
    }
    if (path == .follower_apply) {
        const encoded = try ws.encode(testing.allocator);
        defer testing.allocator.free(encoded);
        try applyEncodedDirect(kv, 1, encoded);
    }
}

test "usage: leader overlay and follower apply agree on the total" {
    // The property a derived total has and a stored one does not. Under
    // `worker_overlay` the leader skips the store apply, so anything computed
    // inside the apply path exists on followers only. Summing rows on read is
    // what makes both roles answer the same.
    const allocator = testing.allocator;
    const rows = [_]Row{
        .{ .pool = .app, .hash = "a" ** 64, .len = "1000" },
        .{ .pool = .file, .hash = "b" ** 64, .len = "2000" },
        .{ .pool = .app, .hash = "c" ** 64, .len = "37" },
    };

    var lp_buf: [96]u8 = undefined;
    const lp = tmpDbPath(&lp_buf, "ws-usage-leader");
    defer cleanupDb(lp);
    var leader = try kvstore.KvStore.open(allocator, lp);
    defer leader.close();
    try writeRows(leader, .leader_overlay, &rows);

    var fp_buf: [96]u8 = undefined;
    const fp = tmpDbPath(&fp_buf, "ws-usage-follower");
    defer cleanupDb(fp);
    var follower = try kvstore.KvStore.open(allocator, fp);
    defer follower.close();
    try writeRows(follower, .follower_apply, &rows);

    try testing.expectEqual(@as(u64, 3037), usage.storedBytes(leader));
    try testing.expectEqual(usage.storedBytes(leader), usage.storedBytes(follower));
}

test "usage: the total is order-independent and re-application is inert" {
    const allocator = testing.allocator;
    var path_buf: [96]u8 = undefined;
    const path = tmpDbPath(&path_buf, "ws-usage-order");
    defer cleanupDb(path);
    var kv = try kvstore.KvStore.open(allocator, path);
    defer kv.close();

    const forward = [_]Row{
        .{ .pool = .app, .hash = "a" ** 64, .len = "10" },
        .{ .pool = .app, .hash = "b" ** 64, .len = "20" },
    };
    const backward = [_]Row{
        .{ .pool = .app, .hash = "b" ** 64, .len = "20" },
        .{ .pool = .app, .hash = "a" ** 64, .len = "10" },
    };
    try writeRows(kv, .follower_apply, &forward);
    try testing.expectEqual(@as(u64, 30), usage.storedBytes(kv));

    // Concurrent writers touch DIFFERENT keys, so interleaving and apply
    // order cannot lose an increment — and a re-delivered entry re-writes
    // rows that are already there.
    try writeRows(kv, .follower_apply, &backward);
    try writeRows(kv, .leader_overlay, &forward);
    try testing.expectEqual(@as(u64, 30), usage.storedBytes(kv));
}

test "usage: content addressing dedups, and the pools do not" {
    const allocator = testing.allocator;
    var path_buf: [96]u8 = undefined;
    const path = tmpDbPath(&path_buf, "ws-usage-pools");
    defer cleanupDb(path);
    var kv = try kvstore.KvStore.open(allocator, path);
    defer kv.close();

    // Same bytes stored twice in one pool: one object, counted once.
    const hash = "b" ** 64;
    try writeRows(kv, .follower_apply, &[_]Row{
        .{ .pool = .app, .hash = hash, .len = "512" },
        .{ .pool = .app, .hash = hash, .len = "512" },
    });
    try testing.expectEqual(@as(u64, 512), usage.storedBytes(kv));

    // Same bytes deployed as a static AND stored via blob.put: two objects in
    // the bucket, so they cost twice.
    try writeRows(kv, .follower_apply, &[_]Row{.{ .pool = .file, .hash = hash, .len = "512" }});
    try testing.expectEqual(@as(u64, 1024), usage.storedBytes(kv));
    try testing.expectEqual(@as(u64, 512), usage.storedBytesIn(kv, .app));
    try testing.expectEqual(@as(u64, 512), usage.storedBytesIn(kv, .file));
}

test "usage: deleting a row gives its bytes back" {
    const allocator = testing.allocator;
    var path_buf: [96]u8 = undefined;
    const path = tmpDbPath(&path_buf, "ws-usage-del");
    defer cleanupDb(path);
    var kv = try kvstore.KvStore.open(allocator, path);
    defer kv.close();

    try writeRows(kv, .follower_apply, &[_]Row{
        .{ .pool = .app, .hash = "c" ** 64, .len = "4096" },
        .{ .pool = .app, .hash = "d" ** 64, .len = "1" },
    });
    try testing.expectEqual(@as(u64, 4097), usage.storedBytes(kv));

    var key_buf: [usage.ROW_KEY_MAX]u8 = undefined;
    const key = usage.rowKey(&key_buf, .app, "c" ** 64);
    var ws = WriteSet.init(allocator);
    defer ws.deinit();
    try ws.addDelete(key);
    const encoded = try ws.encode(allocator);
    defer allocator.free(encoded);
    try applyEncodedDirect(kv, 1, encoded);
    try testing.expectEqual(@as(u64, 1), usage.storedBytes(kv));

    // Deleting an absent row is a no-op, not an underflow.
    try applyEncodedDirect(kv, 1, encoded);
    try testing.expectEqual(@as(u64, 1), usage.storedBytes(kv));
}

test "usage: ordinary customer writes are not rows" {
    const allocator = testing.allocator;
    var path_buf: [96]u8 = undefined;
    const path = tmpDbPath(&path_buf, "ws-usage-inert");
    defer cleanupDb(path);
    var kv = try kvstore.KvStore.open(allocator, path);
    defer kv.close();

    var ws = WriteSet.init(allocator);
    defer ws.deinit();
    try ws.addPut("media/1", "9999");
    // A shim-writable marker beside the meter — customer-reachable, and
    // deliberately not part of the accounting.
    try ws.addPut("_blob/owed/" ++ "e" ** 64, "9999");
    const encoded = try ws.encode(allocator);
    defer allocator.free(encoded);
    try applyEncodedDirect(kv, 1, encoded);
    try testing.expectEqual(@as(u64, 0), usage.storedBytes(kv));
}

test "usage: the sum pages through more rows than one scan page" {
    const allocator = testing.allocator;
    var path_buf: [96]u8 = undefined;
    const path = tmpDbPath(&path_buf, "ws-usage-page");
    defer cleanupDb(path);
    var kv = try kvstore.KvStore.open(allocator, path);
    defer kv.close();

    // 600 rows > the 512-row scan page: a sum that stopped at the first page
    // would silently under-report, which is the direction that matters for a
    // quota.
    var key_buf: [usage.ROW_KEY_MAX]u8 = undefined;
    var hash_buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 600) : (i += 1) {
        _ = std.fmt.bufPrint(&hash_buf, "{x:0>64}", .{i}) catch unreachable;
        const key = usage.rowKey(&key_buf, .app, &hash_buf);
        try kv.put(key, "10");
    }
    try testing.expectEqual(@as(u64, 6000), usage.storedBytes(kv));
}

test "encode/decode round trip via KvStore" {
    const allocator = testing.allocator;

    var ws = WriteSet.init(allocator);
    defer ws.deinit();

    try ws.addPut("alpha", "one");
    try ws.addPut("bravo", "two");
    try ws.addDelete("charlie");

    const encoded = try ws.encode(allocator);
    defer allocator.free(encoded);

    // Apply to a throwaway KvStore, then read the results back.
    var path_buf: [96]u8 = undefined;
    const path = tmpDbPath(&path_buf, "ws-test");
    defer cleanupDb(path);

    var kv = try kvstore.KvStore.open(allocator, path);
    defer kv.close();

    // Pre-populate "charlie" so the delete has something to remove.
    try kv.put("charlie", "gone");

    try applyEncoded(kv, 7, encoded);

    const a = try kv.get("alpha");
    defer allocator.free(a);
    try testing.expectEqualStrings("one", a);

    const b = try kv.get("bravo");
    defer allocator.free(b);
    try testing.expectEqualStrings("two", b);

    try testing.expectError(kvstore.Error.NotFound, kv.get("charlie"));
    // Under kvexp there is no per-row seq column; the engine doesn't
    // persist `applyEncoded`'s seq argument, so there's nothing to assert
    // about it here. The behavioral assertions on the key state above are
    // what matter.
}

test "containsKey: matches put + delete ops, misses absent keys" {
    const allocator = testing.allocator;
    var ws = WriteSet.init(allocator);
    defer ws.deinit();

    try testing.expect(!ws.containsKey("k1"));

    try ws.addPut("k1", "v1");
    try ws.addPut("k2", "v2");
    try ws.addDelete("k3");

    try testing.expect(ws.containsKey("k1"));
    try testing.expect(ws.containsKey("k2"));
    try testing.expect(ws.containsKey("k3"));
    try testing.expect(!ws.containsKey("k4"));
    try testing.expect(!ws.containsKey(""));
    // Prefix match should NOT trigger; exact match only.
    try testing.expect(!ws.containsKey("k"));
    try testing.expect(!ws.containsKey("k1x"));
}

test "decode rejects truncated payload" {
    const allocator = testing.allocator;

    // op_count=1, partial op header.
    var buf = [_]u8{ 0, 0, 0, 1, @intFromEnum(OpType.put), 0, 0 };

    var path_buf: [96]u8 = undefined;
    const path = tmpDbPath(&path_buf, "ws-trunc");
    defer cleanupDb(path);

    var kv = try kvstore.KvStore.open(allocator, path);
    defer kv.close();

    try testing.expectError(DecodeError.Truncated, applyEncoded(kv, 1, &buf));
}

fn tmpDbPath(buf: *[96]u8, tag: []const u8) [:0]const u8 {
    const ts = std.time.nanoTimestamp();
    const seed: u64 = @truncate(@as(u128, @bitCast(ts)));
    return std.fmt.bufPrintZ(buf, "/tmp/rove-{s}-{x}.db", .{ tag, seed }) catch unreachable;
}

fn cleanupDb(path: [:0]const u8) void {
    std.fs.cwd().deleteFile(path) catch {};
    var wal_buf: [128]u8 = undefined;
    var shm_buf: [128]u8 = undefined;
    const wal = std.fmt.bufPrint(&wal_buf, "{s}-wal", .{path}) catch return;
    const shm = std.fmt.bufPrint(&shm_buf, "{s}-shm", .{path}) catch return;
    std.fs.cwd().deleteFile(wal) catch {};
    std.fs.cwd().deleteFile(shm) catch {};
}
