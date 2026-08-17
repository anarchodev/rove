// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Seam interference — the key-set half of the saga viewer's
//! "who touched what I touched" question (`docs/architecture/deployment-and-logs.md`,
//! the saga window). A seam is the open tape interval between two of a
//! saga's hops; a foreign activation in it is *interacting* when its
//! write set intersects the saga's read set (they changed what the next
//! hop read — the "I read 5, who wrote 5?" blame) or its read set
//! intersects the saga's write set (they observed what the previous hop
//! wrote). Everything here is pure: key-set extraction from a kv tape
//! and the two intersection directions. The HTTP orchestration (record
//! fetch, candidate scan, caps) lives in `standalone.zig`.

const std = @import("std");
const tape_mod = @import("rove-tape");
const log_mod = @import("rove-log");

/// Cap on keys per extracted set. A handler doing thousands of kv ops
/// still probes on its first `KEY_CAP` distinct keys; `truncated` says
/// so — the response surfaces it, never a silent cap.
pub const KEY_CAP: usize = 512;

/// The three key sets one activation's kv tape yields. All keys are
/// deduplicated and allocator-owned.
pub const KeySets = struct {
    allocator: std.mem.Allocator,
    /// Exact keys read (`kv.get`).
    reads: [][]u8 = &.{},
    /// Prefixes scanned (`kv.prefix`) — a read of every key under them.
    read_prefixes: [][]u8 = &.{},
    /// Keys written (`kv.set` / `kv.delete`).
    writes: [][]u8 = &.{},
    /// A set hit `KEY_CAP` — the probe is partial.
    truncated: bool = false,

    pub fn deinit(self: *KeySets) void {
        for (self.reads) |k| self.allocator.free(k);
        self.allocator.free(self.reads);
        for (self.read_prefixes) |k| self.allocator.free(k);
        self.allocator.free(self.read_prefixes);
        for (self.writes) |k| self.allocator.free(k);
        self.allocator.free(self.writes);
        self.* = undefined;
    }
};

/// Deduplicating bounded accumulator for one key set.
const SetBuilder = struct {
    seen: std.StringHashMapUnmanaged(void) = .empty,
    list: std.ArrayListUnmanaged([]u8) = .empty,
    truncated: bool = false,

    fn add(self: *SetBuilder, allocator: std.mem.Allocator, key: []const u8) !void {
        if (self.seen.contains(key)) return;
        if (self.list.items.len >= KEY_CAP) {
            self.truncated = true;
            return;
        }
        const owned = try allocator.dupe(u8, key);
        errdefer allocator.free(owned);
        try self.seen.put(allocator, owned, {});
        try self.list.append(allocator, owned);
    }

    fn finish(self: *SetBuilder, allocator: std.mem.Allocator) ![][]u8 {
        self.seen.deinit(allocator);
        return self.list.toOwnedSlice(allocator);
    }

    fn abort(self: *SetBuilder, allocator: std.mem.Allocator) void {
        for (self.list.items) |k| allocator.free(k);
        self.list.deinit(allocator);
        self.seen.deinit(allocator);
    }
};

/// Extract one activation's key sets. READS come from the kv tape (the
/// record's `tapes.kv_tape_b64`, already base64-decoded; null = no
/// capture); WRITES come from the record's write-key list
/// (`tapes.kv_write_keys_b64` — `log.encodeKeyList`; empty = wrote
/// nothing or the record predates the field). The two are separate
/// sources by construction: `kv.set` is a TEA output and never enters
/// the tape. Caveat inherited from read-taping: a read of a key this
/// SAME activation already wrote is elided from its tape (read-your-
/// write needs no replay input), so self-written-then-read keys appear
/// only in `writes` — which is the side the seam scan wants them on.
pub fn extractKeySets(
    allocator: std.mem.Allocator,
    kv_tape_bytes: ?[]const u8,
    write_keys: []const []const u8,
) !KeySets {
    var reads: SetBuilder = .{};
    errdefer reads.abort(allocator);
    var prefixes: SetBuilder = .{};
    errdefer prefixes.abort(allocator);
    var writes: SetBuilder = .{};
    errdefer writes.abort(allocator);

    if (kv_tape_bytes) |bytes| {
        var parsed = try tape_mod.parse(allocator, bytes);
        defer parsed.deinit();
        for (parsed.entries) |e| {
            switch (e) {
                .kv => |kv| switch (kv.op) {
                    .get => try reads.add(allocator, kv.key),
                    .prefix => try prefixes.add(allocator, kv.key),
                    // Defensive: nothing writes set/delete tape entries
                    // today (writes are outputs) — fold them into the
                    // write set rather than dropping them if one ever
                    // appears.
                    .set, .delete => try writes.add(allocator, kv.key),
                },
                else => {},
            }
        }
    }
    for (write_keys) |k| try writes.add(allocator, k);

    const truncated = reads.truncated or prefixes.truncated or writes.truncated;
    return .{
        .allocator = allocator,
        .reads = try reads.finish(allocator),
        .read_prefixes = try prefixes.finish(allocator),
        .writes = try writes.finish(allocator),
        .truncated = truncated,
    };
}

/// The two seam-relevant blobs of one record's stored JSON (`/show`'s
/// verbatim body). Null fields mean "not captured" — a record that
/// can't be probed on that side, which callers must surface, never
/// treat as "no keys". Owned; `deinit` frees.
pub const RecordBlobs = struct {
    kv_tape: ?[]u8 = null,
    write_keys_blob: ?[]u8 = null,

    pub fn deinit(self: *RecordBlobs, allocator: std.mem.Allocator) void {
        if (self.kv_tape) |b| allocator.free(b);
        if (self.write_keys_blob) |b| allocator.free(b);
        self.* = .{};
    }
};

pub fn blobsFromRecordJson(allocator: std.mem.Allocator, record_json: []const u8) !RecordBlobs {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, record_json, .{}) catch
        return error.BadRecordJson;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadRecordJson,
    };
    const tapes = switch (obj.get("tapes") orelse return RecordBlobs{}) {
        .object => |o| o,
        else => return RecordBlobs{},
    };
    var out: RecordBlobs = .{};
    errdefer out.deinit(allocator);
    out.kv_tape = try b64Field(allocator, tapes, "kv_tape_b64");
    out.write_keys_blob = try b64Field(allocator, tapes, "kv_write_keys_b64");
    return out;
}

fn b64Field(allocator: std.mem.Allocator, tapes: std.json.ObjectMap, name: []const u8) !?[]u8 {
    const b64 = switch (tapes.get(name) orelse return null) {
        .string => |s| s,
        else => return null, // JSON null = no capture
    };
    const dec_len = std.base64.standard.Decoder.calcSizeForSlice(b64) catch
        return error.BadRecordJson;
    const out = try allocator.alloc(u8, dec_len);
    errdefer allocator.free(out);
    std.base64.standard.Decoder.decode(out, b64) catch return error.BadRecordJson;
    return out;
}

/// Decode a record's write-key list (empty when absent). Returned keys
/// BORROW the blob; caller frees only the outer slice.
pub fn decodeWriteKeys(allocator: std.mem.Allocator, blob: ?[]const u8) ![][]const u8 {
    const b = blob orelse return try allocator.alloc([]const u8, 0);
    return log_mod.decodeKeyList(allocator, b) catch error.BadRecordJson;
}

/// The candidate's WRITES that the target saga read — exact-key hits
/// plus writes landing under a scanned prefix. Returned keys BORROW
/// the candidate's `KeySets`; capped by `out_cap` (caller announces
/// truncation via the returned `truncated`).
pub const Matches = struct {
    keys: [][]const u8,
    truncated: bool,

    pub fn deinit(self: *Matches, allocator: std.mem.Allocator) void {
        allocator.free(self.keys);
    }
};

pub fn writesMatching(
    allocator: std.mem.Allocator,
    candidate: *const KeySets,
    target: *const KeySets,
    out_cap: usize,
) !Matches {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var truncated = false;
    outer: for (candidate.writes) |w| {
        const hit = blk: {
            for (target.reads) |r| {
                if (std.mem.eql(u8, w, r)) break :blk true;
            }
            for (target.read_prefixes) |p| {
                if (std.mem.startsWith(u8, w, p)) break :blk true;
            }
            break :blk false;
        };
        if (!hit) continue;
        if (out.items.len >= out_cap) {
            truncated = true;
            break :outer;
        }
        try out.append(allocator, w);
    }
    return .{ .keys = try out.toOwnedSlice(allocator), .truncated = truncated };
}

/// The candidate's READS that observed the target saga's writes: exact
/// reads of a written key, plus a scanned prefix any written key lands
/// under (the scan saw the write). Prefix hits report the prefix — that
/// is what the candidate actually asked for.
pub fn readsMatching(
    allocator: std.mem.Allocator,
    candidate: *const KeySets,
    target: *const KeySets,
    out_cap: usize,
) !Matches {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var truncated = false;
    for (candidate.reads) |r| {
        const hit = blk: {
            for (target.writes) |w| {
                if (std.mem.eql(u8, r, w)) break :blk true;
            }
            break :blk false;
        };
        if (!hit) continue;
        if (out.items.len >= out_cap) {
            truncated = true;
            break;
        }
        try out.append(allocator, r);
    }
    if (!truncated) for (candidate.read_prefixes) |p| {
        const hit = blk: {
            for (target.writes) |w| {
                if (std.mem.startsWith(u8, w, p)) break :blk true;
            }
            break :blk false;
        };
        if (!hit) continue;
        if (out.items.len >= out_cap) {
            truncated = true;
            break;
        }
        try out.append(allocator, p);
    };
    return .{ .keys = try out.toOwnedSlice(allocator), .truncated = truncated };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn buildKvTape(allocator: std.mem.Allocator, ops: []const struct { op: tape_mod.KvOp, key: []const u8 }) ![]u8 {
    var t = tape_mod.Tape.init(allocator, .kv);
    defer t.deinit();
    for (ops) |o| switch (o.op) {
        .prefix => try t.appendKvPrefix(o.key, "", 10, &.{}, .ok),
        else => try t.appendKv(o.op, o.key, "v", .ok),
    };
    return t.serialize(allocator);
}

test "extractKeySets: reads from the tape, writes from the key list, dedup" {
    const a = testing.allocator;
    const bytes = try buildKvTape(a, &.{
        .{ .op = .get, .key = "cart/1" },
        .{ .op = .get, .key = "cart/1" }, // dup read
        .{ .op = .prefix, .key = "items/" },
    });
    defer a.free(bytes);

    var ks = try extractKeySets(a, bytes, &.{ "cart/1", "tmp/x", "tmp/x" });
    defer ks.deinit();
    try testing.expectEqual(@as(usize, 1), ks.reads.len);
    try testing.expectEqualStrings("cart/1", ks.reads[0]);
    try testing.expectEqual(@as(usize, 1), ks.read_prefixes.len);
    try testing.expectEqualStrings("items/", ks.read_prefixes[0]);
    try testing.expectEqual(@as(usize, 2), ks.writes.len);
    try testing.expect(!ks.truncated);

    // No tape (unprobeable read side) still yields the writes.
    var wo = try extractKeySets(a, null, &.{"k"});
    defer wo.deinit();
    try testing.expectEqual(@as(usize, 0), wo.reads.len);
    try testing.expectEqual(@as(usize, 1), wo.writes.len);
}

test "writesMatching: exact hit + under-prefix hit, misses stay out" {
    const a = testing.allocator;
    const target_bytes = try buildKvTape(a, &.{
        .{ .op = .get, .key = "cart/1" },
        .{ .op = .prefix, .key = "items/" },
    });
    defer a.free(target_bytes);

    var cand = try extractKeySets(a, null, &.{ "cart/1", "items/42", "other/z" });
    defer cand.deinit();
    var target = try extractKeySets(a, target_bytes, &.{});
    defer target.deinit();

    var m = try writesMatching(a, &cand, &target, 32);
    defer m.deinit(a);
    try testing.expectEqual(@as(usize, 2), m.keys.len);
    try testing.expectEqualStrings("cart/1", m.keys[0]);
    try testing.expectEqualStrings("items/42", m.keys[1]);
    try testing.expect(!m.truncated);
}

test "readsMatching: mirror direction, prefix reported as the prefix" {
    const a = testing.allocator;
    const cand_bytes = try buildKvTape(a, &.{
        .{ .op = .get, .key = "cart/1" },
        .{ .op = .prefix, .key = "cart/" },
        .{ .op = .get, .key = "unrelated" },
    });
    defer a.free(cand_bytes);

    var cand = try extractKeySets(a, cand_bytes, &.{});
    defer cand.deinit();
    var target = try extractKeySets(a, null, &.{"cart/1"});
    defer target.deinit();

    var m = try readsMatching(a, &cand, &target, 32);
    defer m.deinit(a);
    try testing.expectEqual(@as(usize, 2), m.keys.len);
    try testing.expectEqualStrings("cart/1", m.keys[0]);
    try testing.expectEqualStrings("cart/", m.keys[1]);
}

test "blobsFromRecordJson: present, null, and absent fields; write keys decode" {
    const a = testing.allocator;
    const bytes = try buildKvTape(a, &.{.{ .op = .get, .key = "k" }});
    defer a.free(bytes);
    const wk = try log_mod.encodeKeyList(a, &.{ "w1", "w2" });
    defer a.free(wk);

    const tape_enc = try a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    defer a.free(tape_enc);
    _ = std.base64.standard.Encoder.encode(tape_enc, bytes);
    const wk_enc = try a.alloc(u8, std.base64.standard.Encoder.calcSize(wk.len));
    defer a.free(wk_enc);
    _ = std.base64.standard.Encoder.encode(wk_enc, wk);

    const json = try std.fmt.allocPrint(
        a,
        "{{\"tapes\":{{\"kv_tape_b64\":\"{s}\",\"kv_write_keys_b64\":\"{s}\"}}}}",
        .{ tape_enc, wk_enc },
    );
    defer a.free(json);

    var blobs = try blobsFromRecordJson(a, json);
    defer blobs.deinit(a);
    try testing.expectEqualSlices(u8, bytes, blobs.kv_tape.?);
    const keys = try decodeWriteKeys(a, blobs.write_keys_blob);
    defer a.free(keys);
    try testing.expectEqual(@as(usize, 2), keys.len);
    try testing.expectEqualStrings("w1", keys[0]);

    var none = try blobsFromRecordJson(a, "{\"tapes\":{\"kv_tape_b64\":null}}");
    defer none.deinit(a);
    try testing.expect(none.kv_tape == null);
    try testing.expect(none.write_keys_blob == null);
    var empty = try blobsFromRecordJson(a, "{}");
    defer empty.deinit(a);
    try testing.expect(empty.kv_tape == null);
    const nokeys = try decodeWriteKeys(a, null);
    defer a.free(nokeys);
    try testing.expectEqual(@as(usize, 0), nokeys.len);
    try testing.expectError(error.BadRecordJson, blobsFromRecordJson(a, "not json"));
}
