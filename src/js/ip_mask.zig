// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Client-IP masking for the `request.ip` surface — the ONE mask rule,
//! shared by the worker's request installer (`globals.zig`) and the sim's
//! world build (`src/replay/root.zig`, which derives the masked channel
//! from an authored ip so the two surfaces can't drift). `request.ip` is
//! the masked form; `unmaskedIp()` is the deliberate raw
//! escalation (see `globals.zig` for the GDPR rationale).

const std = @import("std");

/// Mask an IP string into `buf`: IPv4 → last octet zeroed
/// (`a.b.c.0`); IPv6 → first three groups kept (/48), remainder
/// compressed to `::` (`2001:db8:85a3::`). Returns null when the
/// input parses as neither — a malformed transport header yields no
/// masked IP rather than leaking unparsed text.
pub fn maskIp(buf: *[64]u8, raw: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, raw, ':') == null) {
        // IPv4: validate via the std parser, then rewrite the last
        // octet textually.
        _ = std.net.Ip4Address.parse(raw, 0) catch return null;
        const last_dot = std.mem.lastIndexOfScalar(u8, raw, '.') orelse return null;
        return std.fmt.bufPrint(buf, "{s}.0", .{raw[0..last_dot]}) catch null;
    }
    // IPv6 (possibly with a zone or v4-mapped tail — the std parser
    // handles the grammar; we only need the first 48 bits).
    const addr = std.net.Ip6Address.parse(raw, 0) catch return null;
    const b: [16]u8 = addr.sa.addr;
    const g0 = (@as(u16, b[0]) << 8) | b[1];
    const g1 = (@as(u16, b[2]) << 8) | b[3];
    const g2 = (@as(u16, b[4]) << 8) | b[5];
    return std.fmt.bufPrint(buf, "{x}:{x}:{x}::", .{ g0, g1, g2 }) catch null;
}

test "maskIp: v4 zeroes the last octet" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("203.0.113.0", maskIp(&buf, "203.0.113.9").?);
}

test "maskIp: v6 keeps the /48" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "2001:db8:85a3::",
        maskIp(&buf, "2001:0db8:85a3:0000:0000:8a2e:0370:7334").?,
    );
}

test "maskIp: malformed input yields null" {
    var buf: [64]u8 = undefined;
    try std.testing.expect(maskIp(&buf, "not-an-ip") == null);
    try std.testing.expect(maskIp(&buf, "") == null);
}
