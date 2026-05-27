//! rove-bodies — wire-format types for readset BodyRefs.
//!
//! Historically this module also held the per-tenant `BodyBuffer`
//! that accumulated bytes in RAM and periodically PUT to S3. As of
//! `docs/blob-coordinator-plan.md` Phase 3 (2026-05-27), body flush
//! moved to the process-global `blob.BlobCoordinator`; the only
//! survivors here are the on-wire shape (`BodyRef`, `NO_BATCH`) and
//! the leaf-key formatter (`batchKey`) that replay + upload-walker
//! still need to reconstruct S3 keys from raft entry readsets.
//!
//! Phase 5 of the plan replaces the wire format
//! `(batch_id, offset, len)` with `(object_key, offset, len)` (via
//! a version byte) and drops `batchKey` along with it.

const std = @import("std");

/// Sentinel batch_id meaning "no body" / inline path / unparked.
/// The coordinator never mints this id (its `wire_batch_id` counter
/// starts at 1 per `(tenant, worker)`); callers using BodyRef as a
/// component default rely on this sentinel.
pub const NO_BATCH: u64 = 0;

/// Range-into-S3-object pointer carried in the readset wire format.
/// Replay reconstructs the S3 key as
/// `{tenant}/readset-blobs/w{worker_id}/{batch_id:0>20}` (matching
/// the coordinator's per-(tenant, worker) backend prefix).
pub const BodyRef = struct {
    batch_id: u64,
    offset: u64,
    len: u32,
};

/// Build the S3 leaf key for batch `id`. `key_buf` must be at least
/// 21 bytes. Returns a slice into `key_buf`.
///
/// Format: zero-padded 20-digit decimal so lexical S3 LIST order
/// matches batch-id order. Same shape `log_server/flush_writer.zig`
/// uses for log batches.
pub fn batchKey(id: u64, key_buf: []u8) []u8 {
    return std.fmt.bufPrint(key_buf, "{d:0>20}", .{id}) catch unreachable;
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
