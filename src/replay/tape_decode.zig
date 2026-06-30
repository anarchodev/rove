//! Focused decoder for the RTAP per-`Tape` wire format (Phase 2 §2c).
//!
//! `rewind pull` writes the recorded request's tape channels as base64 blobs
//! (`record.tapes.{kv,module,request_reads}_tape_b64`); `rewind replay` decodes
//! the three channels it needs to drive the native replay host + rebuild the
//! request. This is a deliberately small, version-guarded reader rather than a
//! link against `rove-tape` (which would drag rove-log + rove-blob + libcurl
//! into the otherwise-lean CLI). It mirrors `src/tape/root.zig`'s
//! `encodeEntry` / per-`Tape` `serialize` exactly; the VERSION guard fails loud
//! if that format ever moves so this copy can't silently mis-decode.

const std = @import("std");

pub const MAGIC: u32 = 0x52544150; // 'R' 'T' 'A' 'P'
pub const VERSION: u16 = 5; // src/tape/root.zig:82 (per-Tape)

pub const Channel = enum(u16) {
    kv = 0,
    module = 1,
    fetch_responses = 2,
    trigger_payload = 3,
    request_reads = 4,
};

pub const KvOp = enum(u8) { get = 0, set = 1, delete = 2, prefix = 3 };
pub const KvOutcome = enum(u8) { ok = 0, not_found = 1, err = 2 };

/// One kv tape entry. For `prefix`, `value` is empty and `results` holds the
/// returned pairs; otherwise `results` is empty and `value` is the read/written
/// bytes. All slices borrow the input `bytes` (no copy).
pub const KvEntry = struct {
    op: KvOp,
    outcome: KvOutcome,
    key: []const u8,
    value: []const u8 = "",
    results: []const KvPair = &.{},
};
pub const KvPair = struct { key: []const u8, value: []const u8 };

pub const ModuleEntry = struct { specifier: []const u8, source_hash_hex: []const u8 };

pub const RequestReadKind = enum(u8) {
    header_names = 0,
    header_value = 1,
    body_read = 2,
    ip_masked = 3,
    ip_raw = 4,
};
pub const RequestReadEntry = struct {
    kind: RequestReadKind,
    name: []const u8,
    value: []const u8,
};

pub const Error = error{ BadMagic, BadVersion, ChannelMismatch, Truncated, BadEnum, OutOfMemory };

/// A cursor over one channel's entries, in recorded order. The replay host
/// advances it as the handler reads; `next()` yields the entry bytes to verify
/// + serve. Generic over the per-channel decode fn.
const Reader = struct {
    bytes: []const u8,
    cur: usize,
    remaining: u32,
    channel: Channel,

    fn init(bytes: []const u8, want: Channel) Error!Reader {
        if (bytes.len < 12) return Error.Truncated;
        if (std.mem.readInt(u32, bytes[0..4], .big) != MAGIC) return Error.BadMagic;
        if (std.mem.readInt(u16, bytes[4..6], .big) != VERSION) return Error.BadVersion;
        const ch = std.meta.intToEnum(Channel, std.mem.readInt(u16, bytes[6..8], .big)) catch
            return Error.BadEnum;
        if (ch != want) return Error.ChannelMismatch;
        return .{
            .bytes = bytes,
            .cur = 12,
            .remaining = std.mem.readInt(u32, bytes[8..12], .big),
            .channel = want,
        };
    }

    /// The next entry's raw bytes (the `[len][entry]` framing stripped), or null
    /// when the channel is exhausted.
    fn nextRaw(self: *Reader) Error!?[]const u8 {
        if (self.remaining == 0) return null;
        if (self.cur + 4 > self.bytes.len) return Error.Truncated;
        const len = std.mem.readInt(u32, self.bytes[self.cur..][0..4], .big);
        self.cur += 4;
        if (self.cur + len > self.bytes.len) return Error.Truncated;
        const entry = self.bytes[self.cur .. self.cur + len];
        self.cur += len;
        self.remaining -= 1;
        return entry;
    }
};

fn readLenPrefixed(bytes: []const u8, cur: *usize) Error![]const u8 {
    if (cur.* + 4 > bytes.len) return Error.Truncated;
    const len = std.mem.readInt(u32, bytes[cur.*..][0..4], .big);
    cur.* += 4;
    if (cur.* + len > bytes.len) return Error.Truncated;
    const out = bytes[cur.* .. cur.* + len];
    cur.* += len;
    return out;
}

// ── public decoders: one slice of entries per channel ──────────────────────

/// Decode the kv channel into an ordered slice. Slices borrow `bytes`; the
/// returned slice + any `results` slabs are owned by `a`.
pub fn decodeKv(a: std.mem.Allocator, bytes: []const u8) Error![]KvEntry {
    var r = try Reader.init(bytes, .kv);
    var out = std.ArrayList(KvEntry){};
    errdefer out.deinit(a);
    while (try r.nextRaw()) |e| {
        if (e.len < 2) return Error.Truncated;
        const op = std.meta.intToEnum(KvOp, e[0]) catch return Error.BadEnum;
        const outcome = std.meta.intToEnum(KvOutcome, e[1]) catch return Error.BadEnum;
        var cur: usize = 2;
        const key = try readLenPrefixed(e, &cur);
        if (op == .prefix) {
            _ = try readLenPrefixed(e, &cur); // cursor
            if (cur + 8 > e.len) return Error.Truncated;
            cur += 4; // limit
            const count = std.mem.readInt(u32, e[cur..][0..4], .big);
            cur += 4;
            const slab = try a.alloc(KvPair, count);
            for (slab) |*p| {
                p.key = try readLenPrefixed(e, &cur);
                p.value = try readLenPrefixed(e, &cur);
            }
            try out.append(a, .{ .op = .prefix, .outcome = outcome, .key = key, .results = slab });
        } else {
            const value = try readLenPrefixed(e, &cur);
            try out.append(a, .{ .op = op, .outcome = outcome, .key = key, .value = value });
        }
    }
    return out.toOwnedSlice(a);
}

pub fn decodeModule(a: std.mem.Allocator, bytes: []const u8) Error![]ModuleEntry {
    var r = try Reader.init(bytes, .module);
    var out = std.ArrayList(ModuleEntry){};
    errdefer out.deinit(a);
    while (try r.nextRaw()) |e| {
        var cur: usize = 0;
        const spec = try readLenPrefixed(e, &cur);
        const hash = try readLenPrefixed(e, &cur);
        try out.append(a, .{ .specifier = spec, .source_hash_hex = hash });
    }
    return out.toOwnedSlice(a);
}

pub fn decodeRequestReads(a: std.mem.Allocator, bytes: []const u8) Error![]RequestReadEntry {
    var r = try Reader.init(bytes, .request_reads);
    var out = std.ArrayList(RequestReadEntry){};
    errdefer out.deinit(a);
    while (try r.nextRaw()) |e| {
        if (e.len < 1) return Error.Truncated;
        const kind = std.meta.intToEnum(RequestReadKind, e[0]) catch return Error.BadEnum;
        var cur: usize = 1;
        const name = try readLenPrefixed(e, &cur);
        const value = try readLenPrefixed(e, &cur);
        try out.append(a, .{ .kind = kind, .name = name, .value = value });
    }
    return out.toOwnedSlice(a);
}

// ── tests: build bytes per the encodeEntry format, decode, assert ──────────

const testing = std.testing;

fn putHeader(buf: *std.ArrayList(u8), a: std.mem.Allocator, ch: Channel, count: u32) !void {
    var h: [12]u8 = undefined;
    std.mem.writeInt(u32, h[0..4], MAGIC, .big);
    std.mem.writeInt(u16, h[4..6], VERSION, .big);
    std.mem.writeInt(u16, h[6..8], @intFromEnum(ch), .big);
    std.mem.writeInt(u32, h[8..12], count, .big);
    try buf.appendSlice(a, &h);
}
fn putLen(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    var l: [4]u8 = undefined;
    std.mem.writeInt(u32, &l, @intCast(s.len), .big);
    try buf.appendSlice(a, &l);
    try buf.appendSlice(a, s);
}
/// frame one entry payload as [len][payload]
fn putEntry(buf: *std.ArrayList(u8), a: std.mem.Allocator, payload: []const u8) !void {
    var l: [4]u8 = undefined;
    std.mem.writeInt(u32, &l, @intCast(payload.len), .big);
    try buf.appendSlice(a, &l);
    try buf.appendSlice(a, payload);
}

test "decodeKv: get + set in order" {
    const a = testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    try putHeader(&buf, a, .kv, 2);
    // entry 0: get "user" ok -> "ada"
    var e0 = std.ArrayList(u8){};
    defer e0.deinit(a);
    try e0.append(a, @intFromEnum(KvOp.get));
    try e0.append(a, @intFromEnum(KvOutcome.ok));
    try putLen(&e0, a, "user");
    try putLen(&e0, a, "ada");
    try putEntry(&buf, a, e0.items);
    // entry 1: set "seen" ok -> "ada"
    var e1 = std.ArrayList(u8){};
    defer e1.deinit(a);
    try e1.append(a, @intFromEnum(KvOp.set));
    try e1.append(a, @intFromEnum(KvOutcome.ok));
    try putLen(&e1, a, "seen");
    try putLen(&e1, a, "ada");
    try putEntry(&buf, a, e1.items);

    const entries = try decodeKv(a, buf.items);
    defer a.free(entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(KvOp.get, entries[0].op);
    try testing.expectEqualStrings("user", entries[0].key);
    try testing.expectEqualStrings("ada", entries[0].value);
    try testing.expectEqual(KvOp.set, entries[1].op);
    try testing.expectEqualStrings("seen", entries[1].key);
}

test "decodeRequestReads: header_value entry" {
    const a = testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    try putHeader(&buf, a, .request_reads, 1);
    var e0 = std.ArrayList(u8){};
    defer e0.deinit(a);
    try e0.append(a, @intFromEnum(RequestReadKind.header_value));
    try putLen(&e0, a, "content-type");
    try putLen(&e0, a, "application/json");
    try putEntry(&buf, a, e0.items);

    const entries = try decodeRequestReads(a, buf.items);
    defer a.free(entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(RequestReadKind.header_value, entries[0].kind);
    try testing.expectEqualStrings("content-type", entries[0].name);
    try testing.expectEqualStrings("application/json", entries[0].value);
}

test "version + channel guards fail loud" {
    const a = testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    try putHeader(&buf, a, .kv, 0);
    // corrupt the version
    std.mem.writeInt(u16, buf.items[4..6], VERSION + 1, .big);
    try testing.expectError(Error.BadVersion, decodeKv(a, buf.items));
    // fix version, ask for the wrong channel
    std.mem.writeInt(u16, buf.items[4..6], VERSION, .big);
    try testing.expectError(Error.ChannelMismatch, decodeModule(a, buf.items));
}
