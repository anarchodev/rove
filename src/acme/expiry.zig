// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! When a certificate stops being usable.
//!
//! The issuer needs this to answer "does this host need a certificate?" — a
//! question that has two answers, not one: the host has none, or the one it has
//! is about to expire. Treating only the first as "needs a cert" means a
//! certificate is issued once and then serves until it dies.
//!
//! It also makes restoring certificates safe. A restored certificate that has
//! already expired is worse than no certificate at all: it satisfies "this host
//! has a cert", so issuance never runs, and the host serves TLS with something
//! no client will accept.

const std = @import("std");

pub const Error = error{
    /// No PEM certificate block, or the base64 body is malformed.
    MalformedPem,
    /// The DER parsed as something that is not a certificate we can read.
    MalformedCertificate,
};

const BEGIN = "-----BEGIN CERTIFICATE-----";
const END = "-----END CERTIFICATE-----";

/// Seconds since the Unix epoch after which `cert_pem`'s FIRST certificate is
/// no longer valid. A PEM chain lists the leaf first, and the leaf is what
/// expires soonest and what a client rejects — the intermediates outlive it.
pub fn notAfter(allocator: std.mem.Allocator, cert_pem: []const u8) !i64 {
    const der = try firstBlockDer(allocator, cert_pem);
    defer allocator.free(der);

    const cert = std.crypto.Certificate{ .buffer = der, .index = 0 };
    const parsed = cert.parse() catch return Error.MalformedCertificate;
    return @intCast(parsed.validity.not_after);
}

/// True when the certificate is expired, or expires within `window_s`.
/// Renewing early is the point: a certificate that expires tomorrow is not
/// usable in any operational sense, because the issuance it needs may itself
/// fail and want retries.
pub fn needsRenewal(
    allocator: std.mem.Allocator,
    cert_pem: []const u8,
    now_s: i64,
    window_s: i64,
) bool {
    // Unreadable is treated as "needs renewal" deliberately: a certificate we
    // cannot parse is one we cannot vouch for, and re-issuing is cheap next to
    // serving something broken.
    const expires = notAfter(allocator, cert_pem) catch return true;
    return expires <= now_s + window_s;
}

/// Decode the first PEM certificate block to DER. Caller owns the result.
fn firstBlockDer(allocator: std.mem.Allocator, pem: []const u8) ![]u8 {
    const begin = std.mem.indexOf(u8, pem, BEGIN) orelse return Error.MalformedPem;
    const body_start = begin + BEGIN.len;
    const end = std.mem.indexOfPos(u8, pem, body_start, END) orelse return Error.MalformedPem;

    // Strip the line breaks PEM wraps at 64 columns (and any \r from a CRLF
    // file) before decoding — the base64 alphabet does not include them.
    var b64: std.ArrayList(u8) = .empty;
    defer b64.deinit(allocator);
    for (pem[body_start..end]) |ch| {
        if (ch == '\n' or ch == '\r' or ch == ' ' or ch == '\t') continue;
        try b64.append(allocator, ch);
    }

    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(b64.items) catch return Error.MalformedPem;
    const der = try allocator.alloc(u8, len);
    errdefer allocator.free(der);
    decoder.decode(der, b64.items) catch return Error.MalformedPem;
    return der;
}

/// A real certificate and its true expiry, for tests — here rather than
/// duplicated per module because a hand-rolled PEM would only prove that the
/// parser agrees with whatever we invented. Generated with
/// `openssl req -x509 -days 90`; `openssl x509 -enddate` reports
/// Oct 28 16:28:15 2026 GMT, which is the epoch second below.
pub const testdata = struct {
    pub const cert_pem = @embedFile("testdata/expiry_fixture.pem");
    pub const not_after: i64 = 1793204895;
};

// ── tests ────────────────────────────────────────────────────────────

const fixture = testdata.cert_pem;
const FIXTURE_NOT_AFTER: i64 = testdata.not_after;

test "notAfter reads the certificate's real expiry" {
    const got = try notAfter(std.testing.allocator, fixture);
    try std.testing.expectEqual(FIXTURE_NOT_AFTER, got);
}

test "notAfter tolerates CRLF and surrounding text" {
    // Certificates arrive from an ACME server and from operator uploads; both
    // can carry CRLF or a chain preceded by commentary.
    const a = std.testing.allocator;
    var crlf: std.ArrayList(u8) = .empty;
    defer crlf.deinit(a);
    try crlf.appendSlice(a, "issued by the test CA\n");
    for (fixture) |ch| {
        if (ch == '\n') try crlf.appendSlice(a, "\r\n") else try crlf.append(a, ch);
    }
    try std.testing.expectEqual(FIXTURE_NOT_AFTER, try notAfter(a, crlf.items));
}

test "notAfter reads the LEAF of a chain, not a later certificate" {
    // The leaf expires first and is what a client rejects; a chain that also
    // carries a long-lived intermediate must not report the intermediate's
    // date. Two copies of the fixture stand in for leaf + intermediate — the
    // property under test is "first block wins", and a second block with a
    // DIFFERENT date would only prove the same thing if the parser were
    // already correct.
    const a = std.testing.allocator;
    var chain: std.ArrayList(u8) = .empty;
    defer chain.deinit(a);
    try chain.appendSlice(a, fixture);
    try chain.appendSlice(a, fixture);
    try std.testing.expectEqual(FIXTURE_NOT_AFTER, try notAfter(a, chain.items));
}

test "needsRenewal: inside the window, outside it, and already expired" {
    const a = std.testing.allocator;
    const day = std.time.s_per_day;
    // Comfortably before expiry, with a 30-day window → no.
    try std.testing.expect(!needsRenewal(a, fixture, FIXTURE_NOT_AFTER - 60 * day, 30 * day));
    // Inside the window → yes, even though the cert is still valid right now.
    // This is the renewal case: valid, but not for long enough.
    try std.testing.expect(needsRenewal(a, fixture, FIXTURE_NOT_AFTER - 10 * day, 30 * day));
    // Already expired → yes.
    try std.testing.expect(needsRenewal(a, fixture, FIXTURE_NOT_AFTER + day, 30 * day));
    // Exactly at expiry counts as needing renewal (`<=`), not as fine.
    try std.testing.expect(needsRenewal(a, fixture, FIXTURE_NOT_AFTER, 0));
}

test "an unreadable certificate needs renewal rather than passing silently" {
    const a = std.testing.allocator;
    try std.testing.expect(needsRenewal(a, "not a pem at all", 0, 0));
    try std.testing.expect(needsRenewal(a, BEGIN ++ "\n!!!not base64!!!\n" ++ END, 0, 0));
    try std.testing.expectError(Error.MalformedPem, notAfter(a, "no pem here"));
}
