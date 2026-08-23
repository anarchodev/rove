// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Storage namespace — which generation of the object store a cluster may see.
//!
//! `key_prefix_base` scopes a bucket to a deployment (staging vs prod). The
//! namespace segment scopes it to one LIFETIME of that deployment, and exists
//! because those are different things.
//!
//! Every id the platform mints counts up from state inside a tenant's app.db —
//! `_log/next_request_seq` for request ids, the deployment sequence for
//! `deployments/e{bc_version}/{dep_id:020d}.json`. A cold bring-up wipes that state, so the
//! counters restart at zero. The object store is NOT wiped alongside it: S3 has
//! no delete-by-prefix (deleting means LIST + DeleteObjects over every key),
//! and the blobs are the deployed code. So without a namespace the new
//! lifetime re-issues ids over keys the previous one already wrote, and its
//! records are silently adopted into an older history.
//!
//! Bumping the segment at genesis gives the new lifetime a key space that
//! cannot collide, while leaving the old one readable for forensics. Nothing
//! is deleted; the new cluster simply cannot see it.
//!
//! The marker is a single object at `{key_prefix_base}_namespace`,
//! deliberately OUTSIDE the segment it names so it survives every bump. Its
//! body is the segment: a decimal generation, or empty for the original
//! un-segmented layout. Services resolve it before opening any store and
//! REFUSE to start without one — a missing marker means this store's identity
//! is unknown, and guessing at it is the whole failure this prevents.

const std = @import("std");

/// Key of the marker object, relative to `key_prefix_base`.
pub const MARKER_KEY = "_namespace";

/// A generation is a decimal count; this bounds a malformed marker before it
/// reaches the key builder.
pub const MAX_SEGMENT_LEN = 20;

pub const Error = error{
    /// No marker object. The store's generation is unknown — callers must
    /// refuse rather than assume, since assuming is what silently merges two
    /// lifetimes into one key space.
    MarkerMissing,
    /// Marker present but not a decimal generation (or too long).
    MalformedSegment,
};

/// Validate a segment read off the wire. Empty is legal and names the
/// original, un-segmented layout — the one a store already carrying data had
/// before it was ever namespaced.
pub fn validate(segment: []const u8) Error!void {
    if (segment.len > MAX_SEGMENT_LEN) return Error.MalformedSegment;
    for (segment) |ch| {
        if (ch < '0' or ch > '9') return Error.MalformedSegment;
    }
}

/// The effective key prefix for `segment`: the base itself when the segment is
/// empty, else `{base}{segment}/`. Every per-tenant store hangs off the
/// result, so applying it once at startup namespaces file-blobs, log-blobs,
/// deployments and the body pool together. Caller owns the result.
pub fn apply(
    allocator: std.mem.Allocator,
    key_prefix_base: []const u8,
    segment: []const u8,
) ![]u8 {
    try validate(segment);
    if (segment.len == 0) return allocator.dupe(u8, key_prefix_base);
    return std.fmt.allocPrint(allocator, "{s}{s}/", .{ key_prefix_base, segment });
}

/// The generation after `segment` — what a cold bring-up moves to. The
/// un-segmented layout counts as generation 0, so the first bump is `1`.
/// Caller owns the result.
pub fn next(allocator: std.mem.Allocator, segment: []const u8) ![]u8 {
    try validate(segment);
    const current: u64 = if (segment.len == 0)
        0
    else
        std.fmt.parseInt(u64, segment, 10) catch return Error.MalformedSegment;
    return std.fmt.allocPrint(allocator, "{d}", .{current + 1});
}

/// What an operator has to run when the marker is missing. Services print
/// this instead of a bare error, because the fix is one command and the wrong
/// guess is unrecoverable.
pub const MISSING_MARKER_HINT =
    "no storage-namespace marker in the object store.\n" ++
    "  An existing store that predates namespacing adopts its current layout:\n" ++
    "      rewind-ops storage-namespace --adopt\n" ++
    "  A cold bring-up onto a store that already holds data takes a fresh one:\n" ++
    "      rewind-ops storage-namespace --bump\n" ++
    "  Refusing to start rather than guess: guessing merges two cluster\n" ++
    "  lifetimes into one key space (docs/architecture/deployment-and-logs.md,\n" ++
    "  the storage-namespace section).";

// ── tests ────────────────────────────────────────────────────────────

test "apply: empty segment is the original layout, verbatim" {
    const a = std.testing.allocator;
    const got = try apply(a, "prod/", "");
    defer a.free(got);
    try std.testing.expectEqualStrings("prod/", got);
}

test "apply: a generation becomes its own path segment" {
    const a = std.testing.allocator;
    const got = try apply(a, "prod/", "3");
    defer a.free(got);
    try std.testing.expectEqualStrings("prod/3/", got);
}

test "apply: an empty base still namespaces" {
    // `S3_KEY_PREFIX_BASE` is optional; a bucket dedicated to one deployment
    // leaves it empty, and the generation must still separate lifetimes.
    const a = std.testing.allocator;
    const got = try apply(a, "", "2");
    defer a.free(got);
    try std.testing.expectEqualStrings("2/", got);
}

test "apply: generations cannot collide with each other" {
    // The property the whole mechanism rests on: no two generations share a
    // key, so an id re-issued after a wipe lands somewhere new.
    const a = std.testing.allocator;
    const one = try apply(a, "prod/", "1");
    defer a.free(one);
    const two = try apply(a, "prod/", "2");
    defer a.free(two);
    try std.testing.expect(!std.mem.startsWith(u8, one, two));
    try std.testing.expect(!std.mem.startsWith(u8, two, one));
}

test "apply: a generation never contains the un-segmented layout's keys" {
    // Generation 0 (empty segment) is a PREFIX of every later generation's
    // keys in the string sense, so a LIST of the base still sees them all —
    // but no bumped generation's key can equal an un-segmented one, because
    // `{base}{n}/…` always carries the `{n}/` segment.
    const a = std.testing.allocator;
    const legacy = try apply(a, "prod/", "");
    defer a.free(legacy);
    const bumped = try apply(a, "prod/", "1");
    defer a.free(bumped);
    try std.testing.expect(!std.mem.eql(u8, legacy, bumped));
    try std.testing.expectEqualStrings("prod/1/", bumped);
}

test "next: the un-segmented layout is generation zero" {
    const a = std.testing.allocator;
    const got = try next(a, "");
    defer a.free(got);
    try std.testing.expectEqualStrings("1", got);
}

test "next: counts up" {
    const a = std.testing.allocator;
    const got = try next(a, "9");
    defer a.free(got);
    try std.testing.expectEqualStrings("10", got);
}

test "validate: rejects anything that is not a decimal generation" {
    try std.testing.expectError(Error.MalformedSegment, validate("1a"));
    try std.testing.expectError(Error.MalformedSegment, validate("../"));
    try std.testing.expectError(Error.MalformedSegment, validate("-1"));
    try std.testing.expectError(Error.MalformedSegment, validate("1/2"));
    try std.testing.expectError(Error.MalformedSegment, validate("a" ** (MAX_SEGMENT_LEN + 1)));
    try validate("");
    try validate("12345");
}

test "apply: refuses to build a key from a malformed segment" {
    // A segment reaching the key builder unvalidated could escape the
    // namespace entirely (`../`), which would defeat the isolation.
    const a = std.testing.allocator;
    try std.testing.expectError(Error.MalformedSegment, apply(a, "prod/", "../"));
}
