//! Platform-reserved HTTP header name prefixes — the header analogue of
//! `reserved.zig`'s kv-key reservation.
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
