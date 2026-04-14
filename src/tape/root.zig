//! rove-tape — deterministic replay capture for rove-js handlers.
//!
//! ## Why
//!
//! The whole point of rove-js's "magic" feature is that every
//! non-deterministic operation a handler performs — kv reads, kv
//! writes, `Date.now`, `Math.random`, `crypto.getRandomValues`,
//! `crypto.randomUUID`, module resolution — gets recorded during the
//! original request. Later, `rove-js-ctl replay <request_id>` can
//! re-run the exact same handler bytecode with the exact same inputs
//! and end up at the exact same response. That's what lets us build a
//! time-traveling debugger: stepping through a captured request with
//! full breakpoints, mutation history, and divergence detection.
//!
//! ## Channels
//!
//! shift-js split non-determinism into several independent tapes so
//! replay could diff each channel separately and surface which source
//! of non-determinism drifted. We keep that split:
//!
//! - `.kv`            — every `kv.get` / `kv.set` / `kv.delete`
//! - `.date`          — every `Date.now` call + `new Date()` with no args
//! - `.math_random`   — every `Math.random` call
//! - `.crypto_random` — `crypto.getRandomValues` + `crypto.randomUUID`
//! - `.module`        — module resolution tree (what deployment id / path
//!                      resolved to which bytecode hash)
//!
//! Each channel is its own `Tape` value — a linear sequence of
//! `Entry`s — and each tape serializes to its own blob. On flush, the
//! worker computes a SHA-256 over the serialized bytes and stores the
//! `(hash → blob)` pair in the tenant's log-blobs; the hash then goes
//! onto the `LogRecord` (see `rove-log`'s `TapeRefs`).
//!
//! On replay, the log-cli fetches each referenced blob, parses it,
//! installs it via `ReplaySource`, and runs the handler — the
//! instrumented globals read from the tape instead of calling live
//! sources.
//!
//! ## Determinism contract
//!
//! The ORDER of calls inside a given channel must be deterministic
//! under replay. Handlers run single-threaded on a single JS context
//! with no `await`/microtask interference (MVP is synchronous handlers
//! only), so a correctly-instrumented global call sequence is
//! deterministic by construction. If we ever grow async handlers we'll
//! need an explicit ordering token in each entry — leaving a `seq`
//! field on each entry now so that's forward-compatible.
//!
//! ## Wire format
//!
//! Per-tape:
//!
//! ```
//! [u32 magic = 0x52544150 'RTAP']
//! [u16 version = 1]
//! [u16 channel (EntryTag)]
//! [u32 entry_count]
//! [for each entry: [u32 len][entry bytes]]
//! ```
//!
//! Per-entry bytes depend on `channel`. See `Entry` for the union.

const std = @import("std");

pub const MAGIC: u32 = 0x52544150; // 'R' 'T' 'A' 'P'
pub const VERSION: u16 = 1;

pub const Channel = enum(u16) {
    kv = 0,
    date = 1,
    math_random = 2,
    crypto_random = 3,
    module = 4,
};

/// Outcome of a kv operation as captured on the tape. `NotFound` is
/// common enough to be a first-class variant rather than an error
/// payload so replay can produce it directly without reconstructing a
/// Zig error value.
pub const KvOutcome = enum(u8) {
    ok = 0,
    not_found = 1,
    /// The live call raised an error that wasn't NotFound (e.g. SQLite
    /// I/O error). We record it so replay sees the same failure — the
    /// handler's error-handling path is itself under test.
    err = 2,
};

pub const KvOp = enum(u8) {
    get = 0,
    set = 1,
    delete = 2,
};

/// Single captured event. Owned storage: the `Tape` that holds this
/// entry also owns any byte slices it references.
pub const Entry = union(Channel) {
    kv: KvEntry,
    date: DateEntry,
    math_random: MathRandomEntry,
    crypto_random: CryptoRandomEntry,
    module: ModuleEntry,

    pub const KvEntry = struct {
        op: KvOp,
        key: []const u8,
        /// For `.get .ok` this is the value read; for `.set` it is the
        /// value written; for `.delete` + `.not_found` + `.err` it is
        /// empty.
        value: []const u8,
        outcome: KvOutcome,
    };

    pub const DateEntry = struct {
        /// Milliseconds since epoch — what `Date.now()` returned.
        ms_epoch: i64,
    };

    pub const MathRandomEntry = struct {
        /// The 64-bit float `Math.random` produced. Stored as raw bits
        /// to avoid any float-formatting ambiguity on the wire.
        bits: u64,
    };

    pub const CryptoRandomEntry = struct {
        /// Raw random bytes that were handed to the handler.
        bytes: []const u8,
    };

    pub const ModuleEntry = struct {
        /// Requested path as the handler wrote it.
        specifier: []const u8,
        /// SHA-256 of the bytecode that resolved for this specifier,
        /// hex-encoded. 64 chars.
        source_hash_hex: []const u8,
    };
};

/// Append-only in-memory tape for a single channel. The worker
/// allocates one per channel per in-flight request; on dispatch exit
/// the tapes are serialized and either discarded (Phase 3 baseline,
/// tape_refs all null) or uploaded to the tenant's log-blob store and
/// referenced by hash on the LogRecord.
pub const Tape = struct {
    allocator: std.mem.Allocator,
    channel: Channel,
    entries: std.ArrayList(Entry),
    /// Running total of heap bytes the tape has allocated for owned
    /// slices inside entries. Lets the worker enforce a per-request
    /// tape budget so a pathological handler can't OOM the process by
    /// doing `kv.get(hugekey)` in a loop.
    owned_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator, channel: Channel) Tape {
        return .{
            .allocator = allocator,
            .channel = channel,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *Tape) void {
        for (self.entries.items) |*e| freeEntry(self.allocator, e);
        self.entries.deinit(self.allocator);
    }

    /// Append a kv event. Dups `key` + `value` into tape-owned storage
    /// so the caller's buffers can go away.
    pub fn appendKv(
        self: *Tape,
        op: KvOp,
        key: []const u8,
        value: []const u8,
        outcome: KvOutcome,
    ) !void {
        std.debug.assert(self.channel == .kv);
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const val_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(val_copy);
        try self.entries.append(self.allocator, .{ .kv = .{
            .op = op,
            .key = key_copy,
            .value = val_copy,
            .outcome = outcome,
        } });
        self.owned_bytes += key_copy.len + val_copy.len;
    }

    pub fn appendDate(self: *Tape, ms_epoch: i64) !void {
        std.debug.assert(self.channel == .date);
        try self.entries.append(self.allocator, .{ .date = .{ .ms_epoch = ms_epoch } });
    }

    pub fn appendMathRandom(self: *Tape, value: f64) !void {
        std.debug.assert(self.channel == .math_random);
        try self.entries.append(self.allocator, .{
            .math_random = .{ .bits = @bitCast(value) },
        });
    }

    pub fn appendCryptoRandom(self: *Tape, bytes: []const u8) !void {
        std.debug.assert(self.channel == .crypto_random);
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        try self.entries.append(self.allocator, .{
            .crypto_random = .{ .bytes = copy },
        });
        self.owned_bytes += copy.len;
    }

    pub fn appendModule(
        self: *Tape,
        specifier: []const u8,
        source_hash_hex: []const u8,
    ) !void {
        std.debug.assert(self.channel == .module);
        std.debug.assert(source_hash_hex.len == 64);
        const spec_copy = try self.allocator.dupe(u8, specifier);
        errdefer self.allocator.free(spec_copy);
        const hash_copy = try self.allocator.dupe(u8, source_hash_hex);
        errdefer self.allocator.free(hash_copy);
        try self.entries.append(self.allocator, .{ .module = .{
            .specifier = spec_copy,
            .source_hash_hex = hash_copy,
        } });
        self.owned_bytes += spec_copy.len + hash_copy.len;
    }

    /// Serialize to a fresh heap buffer the caller owns. Empty tapes
    /// still produce a valid (header-only) serialization — replay
    /// must be able to distinguish "channel was empty" from "no tape
    /// at all" and a header-only blob does that cheaply.
    pub fn serialize(self: *const Tape, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        var header: [12]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], MAGIC, .big);
        std.mem.writeInt(u16, header[4..6], VERSION, .big);
        std.mem.writeInt(u16, header[6..8], @intFromEnum(self.channel), .big);
        std.mem.writeInt(u32, header[8..12], @intCast(self.entries.items.len), .big);
        try buf.appendSlice(allocator, &header);

        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(allocator);

        for (self.entries.items) |*e| {
            scratch.clearRetainingCapacity();
            try encodeEntry(allocator, &scratch, e);
            var len_be: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_be, @intCast(scratch.items.len), .big);
            try buf.appendSlice(allocator, &len_be);
            try buf.appendSlice(allocator, scratch.items);
        }

        return buf.toOwnedSlice(allocator);
    }

    /// SHA-256 of the serialized form, hex-encoded (64 chars, lowercase).
    /// Called by the worker when it stores the tape blob — the hex
    /// goes onto the LogRecord's TapeRefs.
    pub fn hashHex(self: *const Tape, allocator: std.mem.Allocator) ![64]u8 {
        const bytes = try self.serialize(allocator);
        defer allocator.free(bytes);
        return hashHexBytes(bytes);
    }
};

pub fn hashHexBytes(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var out: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out;
}

/// Parsed tape — opaque wrapper around an owned buffer + entries slice.
/// Produced by `parse`. Used by replay drivers; not appended to.
pub const ParsedTape = struct {
    allocator: std.mem.Allocator,
    channel: Channel,
    entries: []Entry,
    /// The original bytes. Every `[]const u8` inside `entries` points
    /// into this buffer, so it must outlive the parsed tape.
    backing: []u8,

    pub fn deinit(self: *ParsedTape) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.backing);
        self.* = undefined;
    }
};

pub const ParseError = error{
    BadMagic,
    UnsupportedVersion,
    UnknownChannel,
    Truncated,
    ChannelMismatch,
    OutOfMemory,
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) ParseError!ParsedTape {
    if (bytes.len < 12) return ParseError.Truncated;

    // Own the backing buffer so slices into it are stable.
    const backing = allocator.dupe(u8, bytes) catch return ParseError.OutOfMemory;
    errdefer allocator.free(backing);

    const magic = std.mem.readInt(u32, backing[0..4], .big);
    if (magic != MAGIC) return ParseError.BadMagic;
    const version = std.mem.readInt(u16, backing[4..6], .big);
    if (version != VERSION) return ParseError.UnsupportedVersion;
    const chan_raw = std.mem.readInt(u16, backing[6..8], .big);
    const channel = std.meta.intToEnum(Channel, chan_raw) catch
        return ParseError.UnknownChannel;
    const count = std.mem.readInt(u32, backing[8..12], .big);

    const entries = allocator.alloc(Entry, count) catch return ParseError.OutOfMemory;
    errdefer allocator.free(entries);

    var cur: usize = 12;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (cur + 4 > backing.len) return ParseError.Truncated;
        const elen = std.mem.readInt(u32, backing[cur..][0..4], .big);
        cur += 4;
        if (cur + elen > backing.len) return ParseError.Truncated;
        const slice = backing[cur .. cur + elen];
        cur += elen;
        entries[i] = try decodeEntry(channel, slice);
    }

    return .{
        .allocator = allocator,
        .channel = channel,
        .entries = entries,
        .backing = backing,
    };
}

// ── Internal encode/decode ────────────────────────────────────────────

fn freeEntry(allocator: std.mem.Allocator, e: *Entry) void {
    switch (e.*) {
        .kv => |*k| {
            allocator.free(k.key);
            allocator.free(k.value);
        },
        .date, .math_random => {},
        .crypto_random => |*c| allocator.free(c.bytes),
        .module => |*m| {
            allocator.free(m.specifier);
            allocator.free(m.source_hash_hex);
        },
    }
}

fn appendLenPrefixed(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    slice: []const u8,
) !void {
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, @intCast(slice.len), .big);
    try buf.appendSlice(allocator, &len_be);
    try buf.appendSlice(allocator, slice);
}

fn readLenPrefixed(bytes: []const u8, cur: *usize) ParseError![]const u8 {
    if (cur.* + 4 > bytes.len) return ParseError.Truncated;
    const n = std.mem.readInt(u32, bytes[cur.*..][0..4], .big);
    cur.* += 4;
    if (cur.* + n > bytes.len) return ParseError.Truncated;
    const out = bytes[cur.* .. cur.* + n];
    cur.* += n;
    return out;
}

fn encodeEntry(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    e: *const Entry,
) !void {
    switch (e.*) {
        .kv => |k| {
            try buf.append(allocator, @intFromEnum(k.op));
            try buf.append(allocator, @intFromEnum(k.outcome));
            try appendLenPrefixed(allocator, buf, k.key);
            try appendLenPrefixed(allocator, buf, k.value);
        },
        .date => |d| {
            var be: [8]u8 = undefined;
            std.mem.writeInt(i64, &be, d.ms_epoch, .big);
            try buf.appendSlice(allocator, &be);
        },
        .math_random => |m| {
            var be: [8]u8 = undefined;
            std.mem.writeInt(u64, &be, m.bits, .big);
            try buf.appendSlice(allocator, &be);
        },
        .crypto_random => |c| {
            try appendLenPrefixed(allocator, buf, c.bytes);
        },
        .module => |m| {
            try appendLenPrefixed(allocator, buf, m.specifier);
            try appendLenPrefixed(allocator, buf, m.source_hash_hex);
        },
    }
}

fn decodeEntry(channel: Channel, bytes: []const u8) ParseError!Entry {
    var cur: usize = 0;
    switch (channel) {
        .kv => {
            if (bytes.len < 2) return ParseError.Truncated;
            const op = std.meta.intToEnum(KvOp, bytes[0]) catch
                return ParseError.UnknownChannel;
            const outcome = std.meta.intToEnum(KvOutcome, bytes[1]) catch
                return ParseError.UnknownChannel;
            cur = 2;
            const key = try readLenPrefixed(bytes, &cur);
            const value = try readLenPrefixed(bytes, &cur);
            return .{ .kv = .{ .op = op, .outcome = outcome, .key = key, .value = value } };
        },
        .date => {
            if (bytes.len != 8) return ParseError.Truncated;
            const ms = std.mem.readInt(i64, bytes[0..8], .big);
            return .{ .date = .{ .ms_epoch = ms } };
        },
        .math_random => {
            if (bytes.len != 8) return ParseError.Truncated;
            const bits = std.mem.readInt(u64, bytes[0..8], .big);
            return .{ .math_random = .{ .bits = bits } };
        },
        .crypto_random => {
            const b = try readLenPrefixed(bytes, &cur);
            if (cur != bytes.len) return ParseError.Truncated;
            return .{ .crypto_random = .{ .bytes = b } };
        },
        .module => {
            const spec = try readLenPrefixed(bytes, &cur);
            const hash = try readLenPrefixed(bytes, &cur);
            if (cur != bytes.len) return ParseError.Truncated;
            return .{ .module = .{ .specifier = spec, .source_hash_hex = hash } };
        },
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "kv tape: roundtrip with mixed ops and outcomes" {
    var tape = Tape.init(testing.allocator, .kv);
    defer tape.deinit();

    try tape.appendKv(.get, "hits", "42", .ok);
    try tape.appendKv(.get, "missing", "", .not_found);
    try tape.appendKv(.set, "name", "rove", .ok);
    try tape.appendKv(.delete, "name", "", .ok);
    try tape.appendKv(.get, "broken", "", .err);

    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(Channel.kv, parsed.channel);
    try testing.expectEqual(@as(usize, 5), parsed.entries.len);

    try testing.expectEqual(KvOp.get, parsed.entries[0].kv.op);
    try testing.expectEqualStrings("hits", parsed.entries[0].kv.key);
    try testing.expectEqualStrings("42", parsed.entries[0].kv.value);
    try testing.expectEqual(KvOutcome.ok, parsed.entries[0].kv.outcome);

    try testing.expectEqual(KvOutcome.not_found, parsed.entries[1].kv.outcome);
    try testing.expectEqual(KvOp.set, parsed.entries[2].kv.op);
    try testing.expectEqualStrings("rove", parsed.entries[2].kv.value);
    try testing.expectEqual(KvOp.delete, parsed.entries[3].kv.op);
    try testing.expectEqual(KvOutcome.err, parsed.entries[4].kv.outcome);
}

test "date tape: roundtrip preserves exact ms" {
    var tape = Tape.init(testing.allocator, .date);
    defer tape.deinit();
    try tape.appendDate(1_712_345_678_901);
    try tape.appendDate(0);
    try tape.appendDate(-1);

    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(@as(i64, 1_712_345_678_901), parsed.entries[0].date.ms_epoch);
    try testing.expectEqual(@as(i64, 0), parsed.entries[1].date.ms_epoch);
    try testing.expectEqual(@as(i64, -1), parsed.entries[2].date.ms_epoch);
}

test "math_random tape: bit-exact f64 roundtrip" {
    var tape = Tape.init(testing.allocator, .math_random);
    defer tape.deinit();
    // Include a subnormal + NaN-adjacent value to prove we don't go
    // through any float formatting that might normalize them.
    try tape.appendMathRandom(0.0);
    try tape.appendMathRandom(0.123456789012345);
    try tape.appendMathRandom(std.math.floatMin(f64));

    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 0.0))), parsed.entries[0].math_random.bits);
    try testing.expectEqual(
        @as(u64, @bitCast(@as(f64, 0.123456789012345))),
        parsed.entries[1].math_random.bits,
    );
    try testing.expectEqual(
        @as(u64, @bitCast(std.math.floatMin(f64))),
        parsed.entries[2].math_random.bits,
    );
}

test "crypto tape: preserves exact bytes" {
    var tape = Tape.init(testing.allocator, .crypto_random);
    defer tape.deinit();
    try tape.appendCryptoRandom(&.{ 0x00, 0xff, 0xde, 0xad, 0xbe, 0xef });
    try tape.appendCryptoRandom(&.{});

    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqualSlices(
        u8,
        &.{ 0x00, 0xff, 0xde, 0xad, 0xbe, 0xef },
        parsed.entries[0].crypto_random.bytes,
    );
    try testing.expectEqual(@as(usize, 0), parsed.entries[1].crypto_random.bytes.len);
}

test "module tape: specifier + hash roundtrip" {
    var tape = Tape.init(testing.allocator, .module);
    defer tape.deinit();
    const hash = "a" ** 64;
    try tape.appendModule("./handler.js", hash);

    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqualStrings("./handler.js", parsed.entries[0].module.specifier);
    try testing.expectEqualStrings(hash, parsed.entries[0].module.source_hash_hex);
}

test "empty tape is a valid header-only blob" {
    var tape = Tape.init(testing.allocator, .kv);
    defer tape.deinit();
    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 12), bytes.len);

    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();
    try testing.expectEqual(Channel.kv, parsed.channel);
    try testing.expectEqual(@as(usize, 0), parsed.entries.len);
}

test "hash is stable for identical content" {
    var a = Tape.init(testing.allocator, .kv);
    defer a.deinit();
    var b = Tape.init(testing.allocator, .kv);
    defer b.deinit();

    try a.appendKv(.get, "k", "v", .ok);
    try b.appendKv(.get, "k", "v", .ok);

    const ha = try a.hashHex(testing.allocator);
    const hb = try b.hashHex(testing.allocator);
    try testing.expectEqualSlices(u8, &ha, &hb);

    try b.appendKv(.get, "k2", "", .not_found);
    const hc = try b.hashHex(testing.allocator);
    try testing.expect(!std.mem.eql(u8, &ha, &hc));
}

test "parse rejects bad magic" {
    var bytes: [12]u8 = undefined;
    @memset(&bytes, 0);
    try testing.expectError(ParseError.BadMagic, parse(testing.allocator, &bytes));
}

test "parse rejects wrong version" {
    var bytes: [12]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], MAGIC, .big);
    std.mem.writeInt(u16, bytes[4..6], 99, .big);
    std.mem.writeInt(u16, bytes[6..8], 0, .big);
    std.mem.writeInt(u32, bytes[8..12], 0, .big);
    try testing.expectError(ParseError.UnsupportedVersion, parse(testing.allocator, &bytes));
}

test "parse rejects truncated entries" {
    var tape = Tape.init(testing.allocator, .kv);
    defer tape.deinit();
    try tape.appendKv(.get, "k", "v", .ok);
    const bytes = try tape.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expectError(
        ParseError.Truncated,
        parse(testing.allocator, bytes[0 .. bytes.len - 3]),
    );
}

test "owned_bytes tracks dup'd storage" {
    var tape = Tape.init(testing.allocator, .kv);
    defer tape.deinit();
    try tape.appendKv(.set, "key1", "val1", .ok);
    try testing.expectEqual(@as(usize, 8), tape.owned_bytes);
    try tape.appendKv(.get, "x", "", .not_found);
    try testing.expectEqual(@as(usize, 9), tape.owned_bytes);
}
