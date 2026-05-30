//! rove-bodies — wire-format types for readset BodyRefs.
//!
//! Historically this module also held the per-tenant `BodyBuffer`
//! that accumulated bytes in RAM and periodically PUT to S3. As of
//! `docs/streaming-model.md §7` Phase 3 (2026-05-27), body flush
//! moved to the process-global `blob.BlobCoordinator`; the only
//! survivors here are the on-wire shape (`BodyRef`, `NO_BATCH`) and
//! the leaf-key formatter (`batchKey`) that replay + upload-walker
//! still need to reconstruct S3 keys from raft entry readsets.
//!
//! Phase 5 (2026-05-27): the coordinator collapsed per-(tenant,
//! worker) lanes into a single cross-tenant `_pool/` prefix, and
//! `batch_id` became globally unique via raft reservation. The wire
//! `BodyRef` shape is `{batch_id, offset, len}`; it resolves to one
//! key template — `{key_prefix_base}_pool/{batch_id:0>20}`, a
//! cross-tenant pool under one backend prefix.
//!
//! Use `poolKey` to format a pool leaf; `batchKey` is the generic
//! zero-padded formatter it builds on.

const std = @import("std");

/// Sentinel batch_id meaning "no body" / inline path / unparked.
/// The coordinator's reservation provider floors the first reserved
/// id at 1 (`max(stored, prev_end, 1)`), and the local-mode counter
/// starts at 1, so this sentinel is never minted by either path.
pub const NO_BATCH: u64 = 0;

/// Range-into-S3-object pointer carried in the readset wire format.
/// Wire shape is fixed `{u64 batch_id, u64 offset, u32 len}`; the
/// readset's version byte selects the key template (see file
/// header).
pub const BodyRef = struct {
    batch_id: u64,
    offset: u64,
    len: u32,
};

/// Build the S3 leaf key for batch `id` — the `{batch_id:0>20}`
/// portion only. The backend's prefix supplies the rest. `key_buf`
/// must be at least 20 bytes. Returns a slice into `key_buf`.
///
/// Format: zero-padded 20-digit decimal so lexical S3 LIST order
/// matches batch-id order. Same shape `log_server/flush_writer.zig`
/// uses for log batches.
pub fn batchKey(id: u64, key_buf: []u8) []u8 {
    return std.fmt.bufPrint(key_buf, "{d:0>20}", .{id}) catch unreachable;
}

/// Build the full v5 pool key `_pool/{batch_id:0>20}` for callers
/// that need to S3-LIST or GC against the cross-tenant pool. `key_buf`
/// must be at least 26 bytes. Returns a slice into `key_buf`.
pub fn poolKey(id: u64, key_buf: []u8) []u8 {
    return std.fmt.bufPrint(key_buf, "_pool/{d:0>20}", .{id}) catch unreachable;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "BodyRef sentinel: NO_BATCH is reserved" {
    const sentinel: BodyRef = .{ .batch_id = NO_BATCH, .offset = 0, .len = 0 };
    try testing.expectEqual(@as(u64, 0), sentinel.batch_id);
}

test "batchKey: zero-padded for lexical S3 LIST order" {
    var b1: [21]u8 = undefined;
    var b2: [21]u8 = undefined;
    var b3: [21]u8 = undefined;
    try testing.expectEqualStrings("00000000000000000001", batchKey(1, &b1));
    try testing.expectEqualStrings("00000000000000000042", batchKey(42, &b2));
    try testing.expectEqualStrings("18446744073709551615", batchKey(std.math.maxInt(u64), &b3));
}

test "poolKey: full v5 leaf includes _pool/ prefix" {
    var b1: [26]u8 = undefined;
    try testing.expectEqualStrings("_pool/00000000000000000001", poolKey(1, &b1));
    var b2: [26]u8 = undefined;
    try testing.expectEqualStrings("_pool/00000000000000000042", poolKey(42, &b2));
}
