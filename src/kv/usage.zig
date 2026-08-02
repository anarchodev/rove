// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Per-tenant stored-byte accounting for the customer-controlled object
//! pools — `app-blobs/` (runtime `blob.*` writes) and `file-blobs/`
//! (deploy-time statics). The number the storage quota is enforced against
//! (docs/architecture/control-plane.md).
//!
//! ## Why the fold lives in the apply path
//!
//! Two properties decide where this can live, and only the apply path has
//! both.
//!
//! **Exact under concurrent writers.** A read-modify-write counter in a
//! handler loses increments: two activations on different nodes read the
//! same total, each proposes its own successor, and raft orders them so the
//! later one wins. The loss is not incidental — a tenant can force it by
//! issuing writes in parallel. Apply is the tenant raft group's
//! serialization point: every node applies the same ops in the same order,
//! so a fold performed here is exact and identical everywhere.
//!
//! **Not writable by the tenant.** `_usage/` is outside
//! `SHIM_WRITABLE_PREFIXES` (`src/js/reserved.zig`), so customer and shim JS
//! get `reserved_key` on any write to it. Only platform Zig — which bypasses
//! the JS bindings — puts rows here. A counter kept under a shim-writable
//! prefix like `_blob/` could be zeroed by the tenant it meters.
//!
//! ## The fold
//!
//! Each stored object contributes one row, `{ROW_PREFIX}{pool}/{hash}`, whose
//! value is its length in decimal ASCII. The total in `TOTAL_KEY` moves only
//! when a row APPEARS or DISAPPEARS — never on a rewrite of an existing row.
//! That existence test is what makes the fold idempotent, and it has to be:
//! the leader applies a writeset speculatively and then applies the committed
//! entry for the same ops, and a re-delivered entry may be applied again.
//! Keying on the delta instead would double-count both.
//!
//! Rows are per-pool because the same bytes stored in both pools are two
//! objects in the bucket and cost twice. Dedup within a pool falls out of
//! content addressing: the row key IS the content hash, so re-storing bytes
//! that are already there rewrites a row and moves nothing.

const std = @import("std");
const kvstore = @import("kvstore.zig");

/// Prefix for the per-object rows. Fully reserved against customer writes.
pub const ROW_PREFIX = "_usage/blob/";

/// The tenant's total stored bytes across both pools — the scalar
/// `max_stored_bytes` is checked against.
pub const TOTAL_KEY = "_usage/blob_bytes";

/// Longest decimal u64 (`18446744073709551615`).
const MAX_DECIMAL_LEN = 20;

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

/// Build the row key for one stored object. `buf` must hold
/// `ROW_PREFIX.len + 5 + hash.len`.
pub fn rowKey(buf: []u8, pool: Pool, hash: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ ROW_PREFIX, pool.segment(), hash }) catch
        unreachable;
}

/// True when `key` is one of the per-object rows the fold reacts to. The
/// total itself is deliberately NOT a row — folding it would recurse.
pub fn isObjectRow(key: []const u8) bool {
    return std.mem.startsWith(u8, key, ROW_PREFIX);
}

/// Parse a row value (decimal ASCII bytes). A malformed row contributes
/// nothing rather than poisoning the total — the row is platform-written, so
/// a bad parse means a bug on our side, and skipping keeps the total
/// monotone-honest while the loud path stays the caller's log line.
pub fn parseLen(value: []const u8) ?u64 {
    if (value.len == 0 or value.len > MAX_DECIMAL_LEN) return null;
    return std.fmt.parseInt(u64, value, 10) catch null;
}

/// How the fold writes back — the two apply paths use different write
/// flavours and the fold has to match the one it is folding into.
pub const Mode = enum {
    /// `applyEncoded`: inside the caller's open begin/commit.
    txn,
    /// `applyEncodedDirect`: the consensus apply path, which bypasses the
    /// speculative txn chain.
    direct,
};

fn readTotal(kv: *kvstore.KvStore) u64 {
    const raw = kv.get(TOTAL_KEY) catch return 0;
    defer kv.allocator.free(raw);
    return parseLen(raw) orelse 0;
}

fn writeTotal(kv: *kvstore.KvStore, mode: Mode, total: u64) !void {
    var buf: [MAX_DECIMAL_LEN]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{total}) catch unreachable;
    switch (mode) {
        .txn => try kv.put(TOTAL_KEY, s),
        .direct => try kv.applyPut(TOTAL_KEY, s),
    }
}

/// True when `key` already holds a value in `kv`.
fn rowExists(kv: *kvstore.KvStore, key: []const u8) bool {
    const raw = kv.get(key) catch return false;
    kv.allocator.free(raw);
    return true;
}

/// Fold a PUT into the total: an object row that did not already exist adds
/// its length. A rewrite of an existing row moves nothing, which is what
/// makes replaying the same entry safe.
pub fn observePut(
    kv: *kvstore.KvStore,
    mode: Mode,
    key: []const u8,
    value: []const u8,
) !void {
    if (!isObjectRow(key)) return;
    if (rowExists(kv, key)) return;
    const len = parseLen(value) orelse return;
    try writeTotal(kv, mode, readTotal(kv) +| len);
}

/// Fold a DELETE into the total: a row that existed gives its length back.
/// Deprovision drops the whole store, so this is for the partial paths — a
/// single object removed while the tenant lives on.
pub fn observeDelete(kv: *kvstore.KvStore, mode: Mode, key: []const u8) !void {
    if (!isObjectRow(key)) return;
    const raw = kv.get(key) catch return;
    defer kv.allocator.free(raw);
    const len = parseLen(raw) orelse return;
    try writeTotal(kv, mode, readTotal(kv) -| len);
}

/// The tenant's total stored bytes. Zero when nothing has been stored (or
/// the row is unreadable) — the quota check treats that as "no usage yet",
/// never as "unmetered".
pub fn storedBytes(kv: *kvstore.KvStore) u64 {
    return readTotal(kv);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "usage: isObjectRow separates rows from the total" {
    try testing.expect(isObjectRow(ROW_PREFIX ++ "app/" ++ "a" ** 64));
    try testing.expect(isObjectRow(ROW_PREFIX ++ "file/" ++ "b" ** 64));
    // The total must not fold into itself.
    try testing.expect(!isObjectRow(TOTAL_KEY));
    try testing.expect(!isObjectRow("_blob/owed/abc"));
    try testing.expect(!isObjectRow("media/1"));
}

test "usage: rowKey is per-pool so the same bytes in both pools are two rows" {
    var a_buf: [128]u8 = undefined;
    var f_buf: [128]u8 = undefined;
    const hash = "c" ** 64;
    const app = rowKey(&a_buf, .app, hash);
    const file = rowKey(&f_buf, .file, hash);
    try testing.expect(!std.mem.eql(u8, app, file));
    try testing.expect(isObjectRow(app));
    try testing.expect(isObjectRow(file));
    try testing.expectEqualStrings("_usage/blob/app/" ++ "c" ** 64, app);
}

test "usage: parseLen rejects what would poison the total" {
    try testing.expectEqual(@as(?u64, 0), parseLen("0"));
    try testing.expectEqual(@as(?u64, 4096), parseLen("4096"));
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), parseLen("18446744073709551615"));
    try testing.expectEqual(@as(?u64, null), parseLen(""));
    try testing.expectEqual(@as(?u64, null), parseLen("-1"));
    try testing.expectEqual(@as(?u64, null), parseLen("12x"));
    try testing.expectEqual(@as(?u64, null), parseLen(" 12"));
    // One digit past u64 — rejected rather than wrapped.
    try testing.expectEqual(@as(?u64, null), parseLen("184467440737095516150"));
}
