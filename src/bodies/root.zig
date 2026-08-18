// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! rove-bodies — the readset's pointer into the cross-tenant body pool.
//!
//! A body over the inline cap is not copied onto the readset: the entry
//! keeps a `BodyRef` and the bytes stay in the pool object the blob
//! coordinator wrote (the blob coordinator / chunk spool,
//! `docs/architecture/routing-and-ingress.md`). This module is where
//! that pointer's shape lives, so tape capture, replay, and the log
//! server's body door all name the same thing.
//!
//! A pool object is **content-addressed**: its key is derived from the
//! bytes it holds, not from a counter. Naming it from a counter makes
//! uniqueness a coordination problem across nodes, and a counter that is
//! not actually coordinated is silent cross-tenant corruption — two
//! nodes mint the same id, the second PUT overwrites the first, and the
//! loser's reference resolves to another tenant's bytes with both writes
//! having succeeded. `blob.pool_object` is the format's authority and
//! carries the full rationale; everything here is a re-export of it, so
//! there is one definition rather than a copy per consumer.
//!
//! A reference carries what its key needs — the seal stamp and the
//! digest — so a holder rebuilds the key without a lookup.

const blob_mod = @import("rove-blob");

/// The pool object format: key, header, seal/validate/resolve.
/// `src/blob/pool_object.zig` — it lives in `rove-blob` because the
/// coordinator is its producer and this module already depends on that
/// one, so that is the only home both sides can reach.
pub const pool_object = blob_mod.pool_object;

/// Range-into-a-pool-object pointer carried in the readset wire format:
/// `{written_unix_ms, digest, offset, len}`. `BodyRef.none` (and the
/// `carried` shape, which keeps only a length) names no object — the
/// inline path, a content-addressed reference, or a body never parked.
pub const BodyRef = pool_object.Ref;

/// `_pool/{written_unix_ms:0>13}-{digest_hex}` — the object key a
/// `BodyRef` names. `BodyRef.key` is the method form.
pub const poolKey = pool_object.formatKey;
/// Buffer size `poolKey` needs.
pub const POOL_KEY_LEN = pool_object.KEY_LEN;
/// The write time a key encodes, for a sweep holding only the listing.
/// Null for a foreign object under the prefix, which is skipped rather
/// than aged.
pub const poolKeyWrittenMs = pool_object.keyWrittenMs;

test {
    _ = pool_object;
}

// ── Tests ──────────────────────────────────────────────────────────

const std = @import("std");
const testing = std.testing;

test "BodyRef: the no-object sentinel is distinguishable from a real ref" {
    try testing.expect(BodyRef.none.isNone());
    try testing.expect(!(BodyRef{
        .written_unix_ms = 1_700_000_000_000,
        .digest = [_]u8{0xAB} ** pool_object.DIGEST_LEN,
        .offset = 32,
        .len = 8,
    }).isNone());
}

test "BodyRef: a ref rebuilds its own object key without a lookup" {
    const ref: BodyRef = .{
        .written_unix_ms = 1_700_000_000_123,
        .digest = [_]u8{0x01} ** pool_object.DIGEST_LEN,
        .offset = 64,
        .len = 16,
    };
    var buf: [POOL_KEY_LEN]u8 = undefined;
    const key = ref.key(&buf);
    try testing.expectEqualStrings(
        "_pool/1700000000123-01010101010101010101010101010101",
        key,
    );
    // Round-trips: a sweep reading the listing recovers the stamp it
    // ages the object by.
    try testing.expectEqual(ref.written_unix_ms, poolKeyWrittenMs(key).?);
}
