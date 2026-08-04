// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Platform-reserved HTTP header names — the header analogue of
//! `reserved.zig`'s kv-key reservation. Three lists, one theme: what a handler
//! must not be able to reach. Two reserved *prefixes* (below), the IP-transport
//! headers (`STRIPPED_IP_HEADERS`), and the platform credentials
//! (`PLATFORM_CREDENTIAL_HEADERS`). The last two exist because on a replay
//! platform a handler-readable input is a RECORDED input, and read-taping
//! cannot redact — so the surface is minimized instead.
//!
//! Two prefixes are reserved for platform use and must never be a
//! customer-observable or customer-settable contract:
//!
//!   - `x-rewind-*`        — the internal control-plane / worker wire:
//!                           tenant id, move-secret, snapshot baseline
//!                           (index/term/epoch), raft membership, dest
//!                           node (see `snapshot_catchup.zig`,
//!                           `cp/main.zig`). These ride between binaries;
//!                           a customer handler has no business reading or
//!                           forging them.
//!   - `x-rove-internal-*` — reserved now so future internal headers have
//!                           a namespace to grow into without colliding
//!                           with anything a customer already set.
//!
//! The reservation is enforced in BOTH directions:
//!   - stripped from inbound `request.headers` (globals.zig installHeaders),
//!     so a customer/attacker can't read internal topology or spoof a
//!     header that some internal endpoint might trust (confused-deputy);
//!   - rejected from customer response headers (response_building.zig
//!     isEmittableHeaderName), so a handler can't leak/forge them downstream.
//!
//! `x-rove-correlation-id` is deliberately NOT reserved — it is the one
//! intentionally customer-facing tracing header (read inbound to seed the
//! chain correlation id). Note the `x-rove-internal-` prefix does not match
//! it, so it stays visible.
//!
//! Pre-launch reservation: claiming these prefixes now (before customers can
//! depend on reading/setting them) is free; reclaiming them later is not.

const std = @import("std");

/// Header-name prefixes reserved for the platform. Compared
/// case-insensitively; inbound HTTP/2 names are already lowercase, but
/// customer-set response header names can be any case.
pub const RESERVED_HEADER_PREFIXES = [_][]const u8{
    "x-rewind-",
    "x-rove-internal-",
};

/// True when `name` falls under a platform-reserved header prefix. Used by
/// the inbound header installer (skip) and the response header gate (reject).
pub fn isReservedInternalHeader(name: []const u8) bool {
    for (RESERVED_HEADER_PREFIXES) |p| {
        if (name.len >= p.len and std.ascii.eqlIgnoreCase(name[0..p.len], p)) {
            return true;
        }
    }
    return false;
}

/// The IP-transport headers hidden from `request.headers`. The client IP
/// is personal data under GDPR; it is reachable ONLY via `request.ip`
/// (masked) / `request.unmaskedIp()` (raw — the deliberate, taped
/// escalation). Hiding the raw headers is what makes that friction real:
/// read-taping can't redact (a redacted input breaks replay determinism),
/// so the surface is minimized instead. Enforced by the worker's inbound
/// header installer (globals.zig) and mirrored by the sim's
/// authored-header hygiene (src/replay/root.zig) — one list, no drift.
pub const STRIPPED_IP_HEADERS = [_][]const u8{
    "x-forwarded-for",
    "x-real-ip",
    "cf-connecting-ip",
    "forwarded",
};

/// Headers carrying a PLATFORM credential, hidden from `request.headers` on a
/// platform-bound handler (`state.platform != null` — the `__admin__` tenant).
/// The operator root token arrives here, and a handler-readable input is a
/// RECORDED input: the header getter tapes the value it returns
/// (`globals_request.zig` `jsHeaderGetter` → `request_reads`), so a handler
/// that reads it puts a platform-wide credential in the replay archive.
/// Read-taping can't redact (a redacted input breaks replay determinism), so
/// the surface is minimized instead — the same lever, and for the same reason,
/// as `STRIPPED_IP_HEADERS` above.
///
/// What replaces it is the VERDICT, not the value: `request.rewind.isRoot`,
/// computed by the engine (which already holds both the header and the
/// secret) and taped as `RequestReadKind.root_verdict`. Unlike the IP there is
/// no escalation rung, because nothing legitimately consumes the raw bearer —
/// so the credential never becomes a JS string at all.
///
/// Scoped to platform-bound handlers on purpose: a CUSTOMER tenant's
/// `authorization` header is its own application's auth, its own tape, and its
/// own controller responsibility (`docs/decisions.md`, GDPR-safe request
/// capture). This list is about the platform's credential on the platform's
/// tape.
pub const PLATFORM_CREDENTIAL_HEADERS = [_][]const u8{
    "authorization",
};

/// True when `name` (already-lowercase wire form) carries a platform
/// credential and must be hidden from a platform-bound handler.
pub fn isPlatformCredentialHeader(name: []const u8) bool {
    for (PLATFORM_CREDENTIAL_HEADERS) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

/// True when `name` (already-lowercase wire form) is an IP-transport
/// header hidden from the handler surface.
pub fn isStrippedIpHeader(name: []const u8) bool {
    for (STRIPPED_IP_HEADERS) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

test "isReservedInternalHeader: x-rewind-* reserved (any case)" {
    try std.testing.expect(isReservedInternalHeader("x-rewind-tenant"));
    try std.testing.expect(isReservedInternalHeader("x-rewind-move-secret"));
    try std.testing.expect(isReservedInternalHeader("X-Rewind-Snapshot-Index"));
    try std.testing.expect(isReservedInternalHeader("x-rewind-")); // bare prefix
}

test "isReservedInternalHeader: x-rove-internal-* reserved (any case)" {
    try std.testing.expect(isReservedInternalHeader("x-rove-internal-foo"));
    try std.testing.expect(isReservedInternalHeader("X-Rove-Internal-Bar"));
}

test "isReservedInternalHeader: customer-facing + ordinary headers allowed" {
    // The one intentionally customer-facing tracing header stays visible.
    try std.testing.expect(!isReservedInternalHeader("x-rove-correlation-id"));
    try std.testing.expect(!isReservedInternalHeader("X-Rove-Correlation-Id"));
    // Ordinary headers.
    try std.testing.expect(!isReservedInternalHeader("content-type"));
    try std.testing.expect(!isReservedInternalHeader("authorization"));
    try std.testing.expect(!isReservedInternalHeader("x-custom-header"));
    // A customer header that merely mentions "rewind" but isn't the prefix.
    try std.testing.expect(!isReservedInternalHeader("my-x-rewind-thing"));
    try std.testing.expect(!isReservedInternalHeader(""));
}

test "isPlatformCredentialHeader: authorization only, exact match" {
    try std.testing.expect(isPlatformCredentialHeader("authorization"));
    // Exact wire-form match — inbound HTTP/2 names are already lowercase, so
    // there is no case folding to do and no prefix to widen.
    try std.testing.expect(!isPlatformCredentialHeader("proxy-authorization"));
    try std.testing.expect(!isPlatformCredentialHeader("authorization-scheme"));
    try std.testing.expect(!isPlatformCredentialHeader("content-type"));
    try std.testing.expect(!isPlatformCredentialHeader(""));
}

test "isPlatformCredentialHeader is orthogonal to the other two lists" {
    // The strip is scoped to platform-bound handlers, so `authorization` must
    // stay OUT of the unconditional lists — a customer tenant reads its own
    // bearer as before.
    try std.testing.expect(!isReservedInternalHeader("authorization"));
    try std.testing.expect(!isStrippedIpHeader("authorization"));
}
