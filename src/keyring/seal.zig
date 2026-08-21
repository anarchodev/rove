// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Sealing a kv value, and telling a sealed one from a plaintext one.
//!
//! Sealing at the WRITE BOUNDARY is what gives every container below it
//! identity granularity for free: the ciphertext propagates by itself
//! into the writeset, the raft entry, the WAL record, the LMDB page, the
//! readset, the tape, the log record and every backup. None of them
//! needs to know an identity exists.
//!
//! ## How a reader tells the two apart
//!
//! It cannot be inferred from the envelope. `crypt.peek` will happily
//! parse any bytes that begin with the algorithm id, and a customer
//! value that did so would be read as a sealed blob whose key is missing
//! — that is, as ERASED. Silently reporting live data as erased is the
//! worst failure this whole design has, so the discriminator has to be
//! something a plaintext value provably cannot be.
//!
//! It is `0xFF`. Customer values reach the engine through
//! `JS_ToCStringLen`, so they are UTF-8, and `0xFF` is not a legal byte
//! in UTF-8 — nor in the WTF-8 a lone surrogate produces. So a leading
//! `0xFF` cannot occur in a plaintext value, which makes the test exact
//! rather than probabilistic, and needs no migration: no value already
//! in any store can collide with it.
//!
//! Platform values are NOT UTF-8 (`_keys/next_slot` is raw little-endian
//! u64s, and its first byte can certainly be `0xFF`). They are never
//! sealed and never tested: every one of them lives under a reserved
//! `_` prefix, which customer keys cannot use.
//!
//! ## What is sealed, and what is not
//!
//! Only values written by an activation that named an identity, and only
//! under customer keys. Whole values only — the engine does not parse
//! them, and a row mixing two identities is one the customer splits into
//! two rows.
//!
//! KEY NAMES stay plaintext. Range scans are over keys, so sealing them
//! would cost the scan surface entirely. The gap that leaves is closed by
//! convention rather than by the engine: the identity token should be an
//! opaque surrogate, so a surviving key name identifies nobody once its
//! key is destroyed.

const std = @import("std");
const crypt = @import("rove-crypt");
const reserved = @import("rove-reserved");

/// Marks a sealed value. Defined in `rove-reserved` with the other
/// cross-engine contracts, so the offline engines can recognise a sealed
/// value without linking the crypto primitive — the browser arena does
/// not link it at all.
pub const SEAL_MARKER: u8 = reserved.SEAL_MARKER;

/// Bytes a seal adds: the marker plus the envelope's own overhead.
pub const OVERHEAD: usize = 1 + crypt.OVERHEAD;

/// Key generation stamped into every seal. One today; `key_version`
/// exists so a KEK rotation can roll it without stranding stored bytes.
pub const KEY_VERSION: u32 = 1;

/// Does this value carry a seal?
///
/// Only meaningful for CUSTOMER keys. A platform value is raw bytes and
/// may legitimately begin with `0xFF`; callers must not ask about one.
pub fn isSealed(value: []const u8) bool {
    return reserved.isSealedValue(value);
}

/// Seal `plaintext` under `key`, naming `slot` so a reader can find the
/// key again without holding any identifier. Caller frees.
pub fn seal(
    allocator: std.mem.Allocator,
    plaintext: []const u8,
    key: crypt.Key,
    slot: u64,
    key_version: u32,
) ![]u8 {
    const out = try allocator.alloc(u8, 1 + crypt.sealedLen(plaintext.len));
    errdefer allocator.free(out);
    out[0] = SEAL_MARKER;
    try crypt.seal(out[1..], plaintext, key, crypt.refForSlot(slot), key_version);
    return out;
}

/// The slot a sealed value names, or null when it is not sealed.
pub fn slotOf(value: []const u8) ?u64 {
    if (!isSealed(value)) return null;
    const hdr = crypt.peek(value[1..]) catch return null;
    return crypt.slotForRef(hdr.key_ref);
}

/// Open a sealed value. Caller frees.
pub fn open(allocator: std.mem.Allocator, value: []const u8, key: crypt.Key) ![]u8 {
    if (!isSealed(value)) return error.NotSealed;
    return crypt.openAlloc(allocator, value[1..], key);
}

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

const TEST_KEY: crypt.Key = [_]u8{0x42} ** crypt.KEY_LEN;

test "a sealed value round-trips and names its slot" {
    const sealed = try seal(testing.allocator, "hello", TEST_KEY, 4097, 1);
    defer testing.allocator.free(sealed);
    try testing.expect(isSealed(sealed));
    try testing.expectEqual(@as(?u64, 4097), slotOf(sealed));
    const plain = try open(testing.allocator, sealed, TEST_KEY);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("hello", plain);
}

test "no plaintext customer value can be mistaken for a sealed one" {
    // The discriminator has to be EXACT, not probabilistic: a plaintext
    // value read as a sealed blob whose key is missing would be reported
    // as erased, which is the worst failure available here.
    //
    // Customer values arrive through `JS_ToCStringLen`, so they are
    // UTF-8, and 0xFF is not a legal byte in UTF-8 or in the WTF-8 a
    // lone surrogate produces.
    const cases = [_][]const u8{
        "",
        "hello",
        "{\"n\":42}",
        "日本語",
        "\u{FFFD}",
        &[_]u8{0x01} ** 64, // starts with the ALG id — the trap
        &[_]u8{0xF4, 0x8F, 0xBF, 0xBF}, // highest legal UTF-8 sequence
    };
    for (cases) |v| try testing.expect(!isSealed(v));

    // And the byte itself never appears at the head of any UTF-8 encoding.
    var buf: [4]u8 = undefined;
    var cp: u21 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        if (cp >= 0xD800 and cp <= 0xDFFF) continue; // surrogates
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        try testing.expect(buf[0] != SEAL_MARKER);
        _ = n;
    }
}

test "opening with the wrong key fails rather than returning garbage" {
    const sealed = try seal(testing.allocator, "secret", TEST_KEY, 7, 1);
    defer testing.allocator.free(sealed);
    const other: crypt.Key = [_]u8{0x99} ** crypt.KEY_LEN;
    try testing.expectError(crypt.Error.AuthFailed, open(testing.allocator, sealed, other));
}

test "a truncated or non-sealed value is refused, never guessed at" {
    try testing.expectError(error.NotSealed, open(testing.allocator, "plain", TEST_KEY));
    try testing.expectError(error.NotSealed, open(testing.allocator, "", TEST_KEY));
    // Marker present but nothing behind it.
    try testing.expectError(crypt.Error.Truncated, open(testing.allocator, &[_]u8{SEAL_MARKER}, TEST_KEY));
    try testing.expectEqual(@as(?u64, null), slotOf(&[_]u8{SEAL_MARKER}));
}

test "the seal's cost is stated where a caller can see it" {
    // Per-value, so a tenant with many tiny rows pays proportionally more
    // than one with few large ones.
    try testing.expectEqual(@as(usize, 1 + crypt.OVERHEAD), OVERHEAD);
    const sealed = try seal(testing.allocator, "x", TEST_KEY, 1, 1);
    defer testing.allocator.free(sealed);
    try testing.expectEqual(1 + OVERHEAD, sealed.len);
}
