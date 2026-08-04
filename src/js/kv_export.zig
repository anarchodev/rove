// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Serializing a tenant's KV into content-addressed export parts (rove#340).
//!
//! The customer-data export is a SET of parts plus a manifest, never one
//! object: `blob.write` caps a chain at 64 MiB while a tenant may hold a
//! plan's whole `max_kv_bytes`, so the store is walked in cursor-bounded
//! slices and each slice becomes its own content-addressed object.
//!
//! ## Why the values never reach JS
//!
//! The obvious shape — a JS job looping `kv.prefix("", cursor, 1000)` and
//! putting each page — records the ENTIRE store onto the request tape:
//! `kv.prefix` is tape-captured with its inputs AND its full result list, so
//! the tenant would pay its log-ingest budget to export its own data, S3
//! would grow by a second copy, and a large tenant would trip the `log_bytes`
//! limiter and 429 its own export mid-run. That is rove#391's defect at
//! export scale.
//!
//! So the values are never handed to a handler. The export runs as a Cmd
//! against an internal door (the `blob.receive` pattern — engine-side
//! streaming into content-addressed storage), and the handler observes only
//! the DESCRIPTOR the terminal activation carries: `{hash, bytes,
//! next_cursor, done}`. That descriptor is an input and is taped, but it is a
//! cursor and a digest — bounded, and independent of how much data moved.
//! Nothing is elided and no capture rule is bent: there is simply no bulk
//! input to record.
//!
//! ## Format
//!
//! One JSON object per line (`{"key":…,"value":…}`), keys in store order.
//! Line-delimited so a part is streamable and resumable, and so a truncated
//! part is detectable at the line boundary rather than silently short.

const std = @import("std");
const kvstore = @import("raft-kv").kvstore;

/// Scan pages this many entries at a time. The store's own page cap, not a
/// tuning knob the caller picks: a bigger page buys nothing (the byte budget
/// below is what actually bounds a part) and a smaller one costs round trips.
const SCAN_PAGE: u32 = 1000;

/// The job's own bookkeeping prefix. Excluded from its own export — the
/// record mutates as the export proceeds, so including it would capture a
/// self-referential value that is stale by the time the part is sealed.
/// Everything else, including other platform-reserved namespaces, IS
/// exported: which of those are meaningful to a customer is an import-side
/// question, and dropping them here would silently lose data the tenant owns.
pub const EXPORT_STATE_PREFIX = "_export/";

pub const Part = struct {
    /// JSONL bytes for this slice. Caller owns.
    bytes: []u8,
    /// Where the next slice resumes — the last key written. Empty when
    /// `done`. Borrowed from `bytes`' allocator; caller owns.
    next_cursor: []u8,
    /// Entries serialized into this part.
    entries: u64,
    /// True when the walk reached the end of the store, so this is the last
    /// part and `next_cursor` is meaningless.
    done: bool,

    pub fn deinit(self: *Part, a: std.mem.Allocator) void {
        a.free(self.bytes);
        a.free(self.next_cursor);
        self.* = undefined;
    }
};

/// Serialize one part: entries from `cursor` (exclusive) onward, stopping
/// once the encoded bytes reach `max_bytes` or the store ends.
///
/// `max_bytes` is a floor-not-ceiling budget — the part stops at the first
/// entry that CROSSES it, so a part may exceed the budget by at most one
/// entry. Truncating an entry instead would produce a part that cannot be
/// parsed back, and splitting one across parts would make each part
/// individually invalid; overshooting by one bounded entry keeps every part a
/// self-contained, parseable document.
pub fn buildPart(
    a: std.mem.Allocator,
    store: *kvstore.KvStore,
    cursor: []const u8,
    max_bytes: usize,
) !Part {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    var scan_cursor = try a.dupe(u8, cursor);
    defer a.free(scan_cursor);
    var last_key: []u8 = try a.dupe(u8, "");
    defer a.free(last_key);
    var entries: u64 = 0;
    var done = false;
    var budget_hit = false;

    outer: while (true) {
        var page = try store.prefix("", scan_cursor, SCAN_PAGE);
        defer page.deinit();
        if (page.entries.len == 0) {
            done = true;
            break;
        }
        const short_page = page.entries.len < SCAN_PAGE;

        for (page.entries) |e| {
            // Advance the cursor over EVERY key, including skipped ones —
            // the cursor is a position in the store, not in the output, so a
            // skipped key must still be passed or the next page re-reads it.
            const k = try a.dupe(u8, e.key);
            a.free(last_key);
            last_key = k;

            if (!std.mem.startsWith(u8, e.key, EXPORT_STATE_PREFIX)) {
                try appendJsonLine(a, &out, e.key, e.value);
                entries += 1;
            }

            // Checked per ENTRY, not per page: at page granularity a part
            // could overshoot the budget by a whole page rather than by the
            // single entry that crossed it.
            if (out.items.len >= max_bytes) {
                budget_hit = true;
                break :outer;
            }
        }

        const advanced = try a.dupe(u8, last_key);
        a.free(scan_cursor);
        scan_cursor = advanced;

        // Short page ⇒ the store ended inside it.
        if (short_page) {
            done = true;
            break;
        }
    }
    // A part that stopped on the budget is never the last one, even if the
    // page it stopped in was short — the remaining entries of that page have
    // not been written yet.
    if (budget_hit) done = false;

    const next_cursor = if (done) try a.dupe(u8, "") else try a.dupe(u8, last_key);
    errdefer a.free(next_cursor);

    return .{
        .bytes = try out.toOwnedSlice(a),
        .next_cursor = next_cursor,
        .entries = entries,
        .done = done,
    };
}

/// `{"key":"…","value":"…"}\n` with both fields JSON-escaped.
fn appendJsonLine(
    a: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
    value: []const u8,
) !void {
    try out.appendSlice(a, "{\"key\":");
    try appendJsonString(a, out, key);
    try out.appendSlice(a, ",\"value\":");
    try appendJsonString(a, out, value);
    try out.appendSlice(a, "}\n");
}

/// Byte-level JSON string escape. Values are arbitrary customer bytes, so
/// this escapes the two structural characters, the C0 range, and DEL —
/// anything else rides verbatim (the reader is a JSON parser, and rove's
/// strings are already UTF-8 by the codec).
fn appendJsonString(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(a, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
            var buf: [6]u8 = undefined;
            const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch unreachable;
            try out.appendSlice(a, esc);
        },
        else => try out.append(a, ch),
    };
    try out.append(a, '"');
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn openTempStore(a: std.mem.Allocator, buf: *[64]u8) !*kvstore.KvStore {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const path = try std.fmt.bufPrintZ(buf, "/tmp/rove-kvexport-{x}.db", .{seed});
    return try kvstore.KvStore.open(a, path);
}

/// Walk a store to exhaustion the way the durable job does — issue a part,
/// resume from its cursor — and return every line in order.
fn drainParts(
    a: std.mem.Allocator,
    store: *kvstore.KvStore,
    max_bytes: usize,
    out_parts: *usize,
) ![]u8 {
    var all: std.ArrayList(u8) = .empty;
    errdefer all.deinit(a);
    var cursor = try a.dupe(u8, "");
    defer a.free(cursor);
    out_parts.* = 0;
    while (true) {
        var part = try buildPart(a, store, cursor, max_bytes);
        defer part.deinit(a);
        try all.appendSlice(a, part.bytes);
        out_parts.* += 1;
        if (part.done) break;
        a.free(cursor);
        cursor = try a.dupe(u8, part.next_cursor);
        // A part that is not `done` must advance, or the job loops forever.
        try testing.expect(part.next_cursor.len > 0);
        try testing.expect(out_parts.* < 100);
    }
    return all.toOwnedSlice(a);
}

test "kv export: a multi-part walk covers every key exactly once, in order" {
    const a = testing.allocator;
    var buf: [64]u8 = undefined;
    const store = try openTempStore(a, &buf);
    defer {
        store.close();
        std.fs.cwd().deleteFile(std.mem.sliceTo(&buf, 0)) catch {};
    }

    // Enough entries that a small budget forces several parts.
    var i: usize = 0;
    while (i < 250) : (i += 1) {
        var kb: [32]u8 = undefined;
        const k = try std.fmt.bufPrint(&kb, "k/{d:0>4}", .{i});
        try store.put(k, "v");
    }

    var parts: usize = 0;
    const joined = try drainParts(a, store, 512, &parts);
    defer a.free(joined);

    try testing.expect(parts > 1); // the budget really did split the walk

    // Every key, exactly once, in store order — the property that makes the
    // export a faithful copy rather than an approximate one.
    var lines = std.mem.tokenizeScalar(u8, joined, '\n');
    var seen: usize = 0;
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(
            struct { key: []const u8, value: []const u8 },
            a,
            line,
            .{},
        );
        defer parsed.deinit();
        var kb: [32]u8 = undefined;
        const want = try std.fmt.bufPrint(&kb, "k/{d:0>4}", .{seen});
        try testing.expectEqualStrings(want, parsed.value.key);
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 250), seen);
}

test "kv export: the job's own bookkeeping is excluded, everything else is not" {
    const a = testing.allocator;
    var buf: [64]u8 = undefined;
    const store = try openTempStore(a, &buf);
    defer {
        store.close();
        std.fs.cwd().deleteFile(std.mem.sliceTo(&buf, 0)) catch {};
    }

    try store.put("_export/job-1", "{\"state\":\"running\"}");
    try store.put("_sched/by_id/abc", "{}"); // platform, but the tenant's data
    try store.put("customer/key", "value");

    var parts: usize = 0;
    const joined = try drainParts(a, store, 1 << 20, &parts);
    defer a.free(joined);

    try testing.expect(std.mem.indexOf(u8, joined, "customer/key") != null);
    // Other reserved namespaces ride along: which of them an IMPORT should
    // replay is a question for the import side, and dropping them here would
    // silently lose state the tenant owns.
    try testing.expect(std.mem.indexOf(u8, joined, "_sched/by_id/abc") != null);
    // The job's own record is self-referential and stale by seal time.
    try testing.expect(std.mem.indexOf(u8, joined, "_export/job-1") == null);
}

test "kv export: a skipped key still advances the cursor" {
    // Regression: the cursor is a position in the STORE, not in the output.
    // Advancing it only over emitted keys makes a page that ends in skipped
    // keys re-read them forever.
    const a = testing.allocator;
    var buf: [64]u8 = undefined;
    const store = try openTempStore(a, &buf);
    defer {
        store.close();
        std.fs.cwd().deleteFile(std.mem.sliceTo(&buf, 0)) catch {};
    }

    try store.put("a/key", "v");
    // Sorts last, so the final page ends on an excluded key.
    try store.put("_export/zzz", "x");
    try store.put("zzz/last", "v");

    var parts: usize = 0;
    const joined = try drainParts(a, store, 1 << 20, &parts);
    defer a.free(joined);
    try testing.expect(std.mem.indexOf(u8, joined, "a/key") != null);
    try testing.expect(std.mem.indexOf(u8, joined, "zzz/last") != null);
}

test "kv export: a JSON line escapes structural bytes and control characters" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendJsonLine(a, &out, "k\"1", "a\nb\\c\x01");
    try testing.expectEqualStrings(
        "{\"key\":\"k\\\"1\",\"value\":\"a\\nb\\\\c\\u0001\"}\n",
        out.items,
    );
    // Every part must parse as a document, so the escaping has to survive a
    // real parser — not just look right.
    const parsed = try std.json.parseFromSlice(
        struct { key: []const u8, value: []const u8 },
        a,
        std.mem.trimRight(u8, out.items, "\n"),
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("k\"1", parsed.value.key);
    try testing.expectEqualStrings("a\nb\\c\x01", parsed.value.value);
}
