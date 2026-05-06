//! SSRF blocklist for outbound webhook delivery.
//!
//! The rule: if ANY address a hostname resolves to lives inside one
//! of the blocked CIDRs, refuse to connect. Prevents a malicious (or
//! misconfigured) customer handler from exfiltrating local services,
//! cloud metadata, or other tenants through the platform's outbound
//! credentials.
//!
//! Called at least once per delivery attempt. PLAN §2.6 calls for
//! re-resolution on every retry — DNS rebinding defense.
//!
//! Blocked ranges (IPv4):
//!   0.0.0.0/8         — "this network"
//!   10.0.0.0/8        — RFC 1918 private
//!   100.64.0.0/10     — carrier-grade NAT
//!   127.0.0.0/8       — loopback
//!   169.254.0.0/16    — link-local (inc. 169.254.169.254 EC2 metadata)
//!   172.16.0.0/12     — RFC 1918 private
//!   192.0.0.0/24      — IETF protocol assignments
//!   192.0.2.0/24      — TEST-NET-1
//!   192.168.0.0/16    — RFC 1918 private
//!   198.18.0.0/15     — benchmarking
//!   198.51.100.0/24   — TEST-NET-2
//!   203.0.113.0/24    — TEST-NET-3
//!   224.0.0.0/4       — multicast
//!   240.0.0.0/4       — reserved
//!   255.255.255.255/32 — broadcast
//!
//! Blocked ranges (IPv6):
//!   ::/128           — unspecified
//!   ::1/128          — loopback
//!   fc00::/7         — unique local
//!   fe80::/10        — link-local
//!   ff00::/8         — multicast
//!   ::ffff:0:0/96    — IPv4-mapped (re-check against v4 rules)

const std = @import("std");

pub const Error = error{
    BlockedAddress,
    UnresolvableHost,
    EmptyHost,
};

/// **DEV-ONLY** escape hatch that skips the loopback (127/8) and IPv6
/// `::1` blocks so a local smoke test can point a webhook at an
/// on-box echo server. **Never set in production** — enabling this
/// would let a malicious customer handler probe the host's own
/// services. The EC2-metadata link-local range (169.254.0.0/16) is
/// still blocked unconditionally. Set via the js-worker
/// `--dev-webhook-unsafe` CLI flag; there is no config-file path.
pub var dev_allow_loopback: bool = false;

/// Look up every address `host` resolves to on `port`, bail out if
/// any hits the blocklist. Returns the first safe address (caller
/// uses it for the connection) so the subsequent dial can't land on a
/// different resolution than the one we approved.
pub fn resolveSafe(allocator: std.mem.Allocator, host: []const u8, port: u16) !std.net.Address {
    if (host.len == 0) return Error.EmptyHost;

    // Fast path: if the host is a literal IP, skip DNS and just check.
    if (std.net.Address.parseIp(host, port)) |addr| {
        if (isBlocked(addr)) return Error.BlockedAddress;
        return addr;
    } else |_| {}

    var list = std.net.getAddressList(allocator, host, port) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return Error.UnresolvableHost,
    };
    defer list.deinit();
    if (list.addrs.len == 0) return Error.UnresolvableHost;

    // Reject if ANY address is blocked — prevents a host from smuggling
    // a loopback address into an A/AAAA record alongside a real one.
    for (list.addrs) |a| if (isBlocked(a)) return Error.BlockedAddress;
    return list.addrs[0];
}

pub fn isBlocked(addr: std.net.Address) bool {
    return switch (addr.any.family) {
        std.posix.AF.INET => isBlockedV4(@bitCast(std.mem.bigToNative(u32, addr.in.sa.addr))),
        std.posix.AF.INET6 => isBlockedV6(&addr.in6.sa.addr),
        else => true, // unknown family → block
    };
}

fn isBlockedV4(ip: u32) bool {
    // Extract octets for legibility.
    const a: u8 = @intCast((ip >> 24) & 0xff);
    const b: u8 = @intCast((ip >> 16) & 0xff);
    const c: u8 = @intCast((ip >> 8) & 0xff);
    _ = c;

    // 0.0.0.0/8
    if (a == 0) return true;
    // 10.0.0.0/8
    if (a == 10) return true;
    // 100.64.0.0/10  — CGNAT (100.64 – 100.127)
    if (a == 100 and (b >= 64 and b <= 127)) return true;
    // 127.0.0.0/8 — loopback (dev flag can unblock this only)
    if (a == 127) return !dev_allow_loopback;
    // 169.254.0.0/16 (link-local + metadata)
    if (a == 169 and b == 254) return true;
    // 172.16.0.0/12 (172.16 – 172.31)
    if (a == 172 and (b >= 16 and b <= 31)) return true;
    // 192.0.0.0/24 and 192.0.2.0/24 (TEST-NET-1)
    if (a == 192 and b == 0) return true;
    // 192.168.0.0/16
    if (a == 192 and b == 168) return true;
    // 198.18.0.0/15 — benchmarking
    if (a == 198 and (b == 18 or b == 19)) return true;
    // 198.51.100.0/24 — TEST-NET-2
    if (a == 198 and b == 51) return true;
    // 203.0.113.0/24 — TEST-NET-3
    if (a == 203 and b == 0) return true;
    // 224.0.0.0/4 — multicast (224 – 239)
    if (a >= 224 and a <= 239) return true;
    // 240.0.0.0/4 — reserved / broadcast (240 – 255)
    if (a >= 240) return true;
    return false;
}

fn isBlockedV6(addr: *const [16]u8) bool {
    // ::1 and ::
    var all_zero_but_last: bool = true;
    for (addr[0..15]) |b| if (b != 0) {
        all_zero_but_last = false;
        break;
    };
    if (all_zero_but_last) {
        // `::` (unspecified) is always blocked. `::1` (loopback) is
        // blocked unless the dev flag is set — same semantics as 127/8.
        const is_loopback = addr[15] == 1;
        if (!is_loopback) return true;
        return !dev_allow_loopback;
    }

    // ::ffff:0:0/96 — IPv4-mapped. Re-check against v4 rules.
    const is_mapped = std.mem.eql(u8, addr[0..10], &[_]u8{0} ** 10) and
        addr[10] == 0xff and addr[11] == 0xff;
    if (is_mapped) {
        const v4: u32 = (@as(u32, addr[12]) << 24) | (@as(u32, addr[13]) << 16) |
            (@as(u32, addr[14]) << 8) | @as(u32, addr[15]);
        return isBlockedV4(v4);
    }

    // fc00::/7 — unique local (first byte high 7 bits == 1111110)
    if ((addr[0] & 0xfe) == 0xfc) return true;
    // fe80::/10 — link-local (first 10 bits == 1111111010)
    if (addr[0] == 0xfe and (addr[1] & 0xc0) == 0x80) return true;
    // ff00::/8 — multicast
    if (addr[0] == 0xff) return true;

    return false;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "isBlocked v4: RFC 1918 + loopback + metadata" {
    const blocked = [_][]const u8{
        "10.0.0.1", "10.255.255.255", "127.0.0.1", "127.1.2.3",
        "169.254.169.254", "172.16.0.1", "172.31.255.254",
        "192.168.1.1", "192.168.254.1", "100.64.0.1", "0.0.0.0",
        "224.0.0.1", "239.255.255.255", "255.255.255.255",
        "198.18.0.1", "198.51.100.1",
    };
    for (blocked) |s| {
        const addr = try std.net.Address.parseIp4(s, 0);
        try testing.expect(isBlocked(addr));
    }
}

test "isBlocked v4: public addresses pass" {
    const allowed = [_][]const u8{
        "8.8.8.8", "1.1.1.1", "172.15.0.1", "192.169.0.1",
        "100.63.255.255", "100.128.0.1", "54.210.1.1",
    };
    for (allowed) |s| {
        const addr = try std.net.Address.parseIp4(s, 0);
        try testing.expect(!isBlocked(addr));
    }
}

test "isBlocked v6: loopback + link-local + ULA" {
    const blocked = [_][]const u8{
        "::1", "::", "fe80::1", "fc00::1", "fd12:3456::1", "ff02::1",
        "::ffff:127.0.0.1", "::ffff:10.0.0.1",
    };
    for (blocked) |s| {
        const addr = try std.net.Address.parseIp6(s, 0);
        try testing.expect(isBlocked(addr));
    }
}

test "isBlocked v6: public addresses pass" {
    const allowed = [_][]const u8{
        "2001:4860:4860::8888", "2606:4700:4700::1111",
        "::ffff:8.8.8.8",
    };
    for (allowed) |s| {
        const addr = try std.net.Address.parseIp6(s, 0);
        try testing.expect(!isBlocked(addr));
    }
}

test "resolveSafe: literal-IP fast path" {
    const a = try resolveSafe(testing.allocator, "8.8.8.8", 443);
    try testing.expectEqual(std.posix.AF.INET, @as(u32, a.any.family));
    try testing.expectError(Error.BlockedAddress, resolveSafe(testing.allocator, "127.0.0.1", 443));
    try testing.expectError(Error.BlockedAddress, resolveSafe(testing.allocator, "169.254.169.254", 443));
    try testing.expectError(Error.EmptyHost, resolveSafe(testing.allocator, "", 443));
}
