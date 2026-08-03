// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Per-tenant stored-byte accounting for the customer-controlled object
//! pools — `app-blobs/` (runtime `blob.*` writes) and `file-blobs/`
//! (deploy-time statics). The number the storage quota is enforced against
//! (docs/architecture/control-plane.md).
//!
//! ## Rows are stored; the total is derived. Never the other way round.
//!
//! Each stored object contributes one row, `{ROW_PREFIX}{pool}/{hash}`, whose
//! value is its length in decimal ASCII. There is no stored total. Asking for
//! the total sums the rows.
//!
//! That asymmetry is forced by how a committed entry applies. Under
//! `worker_overlay` — the mode the worker's bridge runs in — the LEADER skips
//! the store apply entirely: the worker already wrote the entry into its own
//! speculative overlay before proposing, and commits that overlay when the
//! watermark advances. Only FOLLOWERS run the writeset through the apply path.
//! So a value derived at apply time exists on followers and not on the leader,
//! and the two diverge silently. Anything that must be identical on every node
//! has to travel IN the writeset, which means it has to be something a writer
//! computes, not something an applier folds.
//!
//! A total computed by a writer is the other trap: two activations on
//! different nodes read the same total, each proposes its successor, raft
//! orders them, and the later one wins — losing an increment. A tenant can
//! force that by issuing writes in parallel, which turns a rounding error into
//! a way to store past a quota. Deriving the total from rows sidesteps both:
//! rows are keyed by content hash, so concurrent writers touch DIFFERENT keys
//! and nothing is lost no matter how the writes interleave or in what order
//! they apply.
//!
//! Dedup falls out of the same property — the row key IS the content hash, so
//! re-storing bytes that are already there rewrites a row and changes nothing.
//! Rows are per-pool because the same bytes in `app-blobs/` and `file-blobs/`
//! are two objects in the bucket and cost twice.
//!
//! ## Cost
//!
//! `storedBytes` is a prefix scan, O(objects). That is the price of not
//! storing a derived value, and it is paid on blob writes (where the quota is
//! checked), not on the request hot path. For scale: the heaviest tenant in
//! production holds a few hundred objects. A tenant large enough for the scan
//! to matter wants the total cached in its worker slot and invalidated on any
//! row write — the rows stay the source of truth either way.
//!
//! ## Tamper
//!
//! `_usage/` is outside `SHIM_WRITABLE_PREFIXES` (`src/js/reserved.zig`), so
//! customer and shim JS get `reserved_key` on any write to it, and only
//! platform Zig — which bypasses the JS bindings — writes rows. The `_blob/`
//! durability markers beside it are deliberately shim-writable; a meter cannot
//! be.

const std = @import("std");
const kvstore = @import("kvstore.zig");

/// Prefix for the per-object rows. Fully reserved against customer writes.
pub const ROW_PREFIX = "_usage/blob/";

/// Longest decimal u64 (`18446744073709551615`).
const MAX_DECIMAL_LEN = 20;

/// Rows read per `prefix` page while summing.
const SCAN_PAGE: u32 = 512;

/// Which pool an object row belongs to. Both are customer-controlled and
/// both count against the same total; the split exists so a per-pool figure
/// stays derivable, and so teardown can walk one pool at a time.
pub const Pool = enum {
    /// Runtime `blob.*` writes — `{tenant}/app-blobs/`.
    app,
    /// Deploy-time statics — `{tenant}/file-blobs/`.
    file,

    pub fn segment(self: Pool) []const u8 {
        return switch (self) {
            .app => "app/",
            .file => "file/",
        };
    }
};

/// Bytes needed by `rowKey` for a sha256-hex object.
pub const ROW_KEY_MAX = ROW_PREFIX.len + "file/".len + 64;

/// Build the row key for one stored object.
pub fn rowKey(buf: []u8, pool: Pool, hash: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ ROW_PREFIX, pool.segment(), hash }) catch
        unreachable;
}

/// True when `key` is one of the per-object rows.
pub fn isObjectRow(key: []const u8) bool {
    return std.mem.startsWith(u8, key, ROW_PREFIX);
}

/// Parse a row value (decimal ASCII bytes). A malformed row contributes
/// nothing rather than poisoning the sum — rows are platform-written, so a bad
/// parse is a bug on our side, and skipping keeps the total honest while the
/// loud path stays the caller's log line.
pub fn parseLen(value: []const u8) ?u64 {
    if (value.len == 0 or value.len > MAX_DECIMAL_LEN) return null;
    return std.fmt.parseInt(u64, value, 10) catch null;
}

/// Format a row value for `bytes`. The returned slice points into `buf`.
pub fn formatLen(buf: []u8, bytes: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{bytes}) catch unreachable;
}

/// Sum one pool's rows, or every pool when `pool` is null.
fn sum(kv: *kvstore.KvStore, pool: ?Pool) u64 {
    var scan_prefix_buf: [ROW_KEY_MAX]u8 = undefined;
    const scan_prefix = if (pool) |p|
        std.fmt.bufPrint(&scan_prefix_buf, "{s}{s}", .{ ROW_PREFIX, p.segment() }) catch unreachable
    else
        ROW_PREFIX;

    var total: u64 = 0;
    var cursor_buf: [ROW_KEY_MAX]u8 = undefined;
    var cursor: []const u8 = "";
    while (true) {
        var page = kv.prefix(scan_prefix, cursor, SCAN_PAGE) catch return total;
        defer page.deinit();
        if (page.entries.len == 0) return total;
        for (page.entries) |e| {
            total +|= parseLen(e.value) orelse 0;
        }
        const last = page.entries[page.entries.len - 1].key;
        if (last.len > cursor_buf.len) return total;
        @memcpy(cursor_buf[0..last.len], last);
        cursor = cursor_buf[0..last.len];
        if (page.entries.len < SCAN_PAGE) return total;
    }
}

/// The tenant's total stored bytes across both customer pools — the scalar
/// `max_stored_bytes` is checked against. Zero when nothing has been stored,
/// which the quota check reads as "no usage yet", never as "unmetered".
pub fn storedBytes(kv: *kvstore.KvStore) u64 {
    return sum(kv, null);
}

/// One pool's stored bytes. For reporting and teardown; enforcement uses the
/// combined `storedBytes`.
pub fn storedBytesIn(kv: *kvstore.KvStore, pool: Pool) u64 {
    return sum(kv, pool);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "usage: isObjectRow matches rows and nothing else" {
    try testing.expect(isObjectRow(ROW_PREFIX ++ "app/" ++ "a" ** 64));
    try testing.expect(isObjectRow(ROW_PREFIX ++ "file/" ++ "b" ** 64));
    try testing.expect(!isObjectRow("_blob/owed/abc"));
    try testing.expect(!isObjectRow("_usage_other"));
    try testing.expect(!isObjectRow("media/1"));
}

test "usage: rowKey is per-pool so the same bytes in both pools are two rows" {
    var a_buf: [ROW_KEY_MAX]u8 = undefined;
    var f_buf: [ROW_KEY_MAX]u8 = undefined;
    const hash = "c" ** 64;
    const app = rowKey(&a_buf, .app, hash);
    const file = rowKey(&f_buf, .file, hash);
    try testing.expect(!std.mem.eql(u8, app, file));
    try testing.expectEqualStrings("_usage/blob/app/" ++ "c" ** 64, app);
    try testing.expectEqualStrings("_usage/blob/file/" ++ "c" ** 64, file);
}

test "usage: parseLen rejects what would poison the sum" {
    try testing.expectEqual(@as(?u64, 0), parseLen("0"));
    try testing.expectEqual(@as(?u64, 4096), parseLen("4096"));
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), parseLen("18446744073709551615"));
    try testing.expectEqual(@as(?u64, null), parseLen(""));
    try testing.expectEqual(@as(?u64, null), parseLen("-1"));
    try testing.expectEqual(@as(?u64, null), parseLen("12x"));
    try testing.expectEqual(@as(?u64, null), parseLen(" 12"));
    try testing.expectEqual(@as(?u64, null), parseLen("184467440737095516150"));
}

test "usage: formatLen round-trips through parseLen" {
    var buf: [MAX_DECIMAL_LEN]u8 = undefined;
    for ([_]u64{ 0, 1, 4096, std.math.maxInt(u64) }) |n| {
        try testing.expectEqual(@as(?u64, n), parseLen(formatLen(&buf, n)));
    }
}
