//! Write-set: a batch of KV operations proposed as a single raft entry.
//!
//! Port of shift-js's raft_write_set_t model. The leader writes each op to
//! its LOCAL KvStore (outside this module — the worker does it in its txn),
//! then submits the write-set via `RaftNode.proposeWriteSet`. Followers
//! receive the replicated entry and replay the ops against their own
//! KvStore in `RaftNode.cbApplyLog` — see `applyEncoded` below.
//!
//! Wire format (after the 8-byte seq prefix that `RaftNode` adds):
//!
//!   [4B op_count]
//!   per op:
//!     [1B type][4B klen][klen bytes key][4B vlen][vlen bytes value]
//!
//! Op types: 1 = PUT, 2 = DELETE. DELETE has vlen = 0.

const std = @import("std");
const kvstore = @import("kvstore.zig");

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
/// No allocation: keys/values are passed by pointer into `payload` directly
/// to sqlite3_bind_{text,blob} with SQLITE_STATIC, which is safe because the
/// transaction runs entirely within this function's stack frame.
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
    try testing.expectEqual(@as(u64, 7), kv.maxSeq());
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
