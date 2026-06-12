//! rove-ssrf — SSRF blocklist + test-only safety overrides for
//! outbound HTTP from customer handlers.
//!
//! Imported by `js/fetch_engine.zig` (the curl_multi engine that
//! handles `http.fetch` / `http.subscribe` / the `webhook.send` JS
//! shim's transport — `checkUrl` is its per-attempt gate) and by
//! `rewind/main.zig` (the `REWIND_UNSAFE_OUTBOUND=1` env flips the
//! test overrides for smoke topologies).
//!
//! The rule: if ANY address a hostname resolves to lives inside one
//! of the blocked CIDRs, refuse to connect. Prevents a malicious (or
//! misconfigured) customer handler from exfiltrating local services,
//! cloud metadata, or other tenants through the platform's outbound
//! credentials. Called at least once per delivery attempt;
//! PLAN §2.6 calls for re-resolution on every retry (DNS rebinding
//! defense).
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
    BadUrl,
    UnsupportedScheme,
    PlaintextBlocked,
};

/// **TEST-ONLY** escape hatch that skips the loopback (127/8) and
/// IPv6 `::1` blocks so an end-to-end smoke can point a webhook at
/// an on-box echo server. **Never set in production** — enabling
/// this would let a malicious customer handler probe the host's own
/// services. The EC2-metadata link-local range (169.254.0.0/16) is
/// still blocked unconditionally. Set via the worker's
/// `REWIND_UNSAFE_OUTBOUND=1` env (smoke topologies); no config-file
/// path.
pub var test_allow_loopback: bool = false;

/// **TEST-ONLY** escape hatch that lets the curl engine talk to
/// `http://` URLs (in addition to `https://`). Paired with
/// `test_allow_loopback` under the worker's `REWIND_UNSAFE_OUTBOUND=1`
/// env so smokes can point at on-box echo servers. **Never set in
/// production** — plaintext outbound leaks request bodies on any
/// intermediate hop. Read by `fetch_engine.zig` to flip
/// `verify_tls` on libcurl.
pub var test_allow_plaintext: bool = false;

/// A customer-supplied outbound URL that passed the policy gate.
/// `host` is a slice into the caller's URL (brackets stripped for an
/// IPv6 literal); `addresses[0..address_count]` is the FULL vetted
/// resolution set the caller MUST pin the connection to
/// (CURLOPT_RESOLVE) so a second DNS answer can't land somewhere the
/// gate never approved (rebinding defense). The whole set is pinned —
/// not just the first address — so curl keeps its normal
/// multi-address connect fallback (e.g. a v6-resolving name whose
/// server only binds v4). `host_is_literal` means the host was a
/// literal IP — no DNS, so no pin needed.
pub const MAX_PIN_ADDRS = 8;

pub const CheckedUrl = struct {
    addresses: [MAX_PIN_ADDRS]std.net.Address,
    address_count: u8,
    host: []const u8,
    port: u16,
    host_is_literal: bool,
};

/// The scheme + host/port half of `checkUrl`: validates the scheme
/// policy (https-only outside the `test_allow_plaintext` hatch) and
/// extracts the host WITHOUT resolving it. `host` is a slice into the
/// caller's URL (IPv6 brackets stripped). Used directly by callers
/// that pin the connect address themselves and so never consult DNS
/// (the fetch engine's tenant door); `checkUrl` layers resolution +
/// the blocklist on top.
pub const ParsedUrl = struct {
    host: []const u8,
    port: u16,
};

pub fn parseUrl(url: []const u8) !ParsedUrl {
    const uri = std.Uri.parse(url) catch return Error.BadUrl;

    var default_port: u16 = undefined;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        default_port = 443;
    } else if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) {
        if (!test_allow_plaintext) return Error.PlaintextBlocked;
        default_port = 80;
    } else {
        return Error.UnsupportedScheme;
    }

    const host_component = uri.host orelse return Error.EmptyHost;
    var host = switch (host_component) {
        .raw, .percent_encoded => |s| s,
    };
    // std.Uri keeps an IPv6 literal's brackets; strip for parse/resolve.
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']')
        host = host[1 .. host.len - 1];
    if (host.len == 0) return Error.EmptyHost;

    return .{ .host = host, .port = uri.port orelse default_port };
}

/// The full outbound policy gate for one customer-supplied URL
/// (`http.fetch` and everything shimmed over it). Enforces, in order:
///   1. scheme is `https` (or `http` only under the test-only
///      `test_allow_plaintext` escape hatch) — anything else
///      (`file:`, `gopher:`, …) is `UnsupportedScheme`;
///   2. a non-empty host;
///   3. every address the host resolves to clears the blocklist
///      (`resolveSafe` — re-resolved on every attempt per PLAN §2.6).
/// Fail-closed: a host we can't parse or resolve is an error, never
/// a pass-through. Percent-encoded hosts are deliberately NOT decoded
/// — they fail resolution and are rejected (curl would decode them,
/// so passing them through unchecked would be a smuggling vector).
pub fn checkUrl(allocator: std.mem.Allocator, url: []const u8) !CheckedUrl {
    const parsed = try parseUrl(url);
    const host = parsed.host;
    const port = parsed.port;

    var out: CheckedUrl = .{
        .addresses = undefined,
        .address_count = 0,
        .host = host,
        .port = port,
        .host_is_literal = false,
    };

    // Literal-IP fast path: no DNS, one address, no pin needed.
    if (std.net.Address.parseIp(host, port)) |addr| {
        if (isBlocked(addr)) return Error.BlockedAddress;
        out.addresses[0] = addr;
        out.address_count = 1;
        out.host_is_literal = true;
        return out;
    } else |_| {}

    var list = std.net.getAddressList(allocator, host, port) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return Error.UnresolvableHost,
    };
    defer list.deinit();
    if (list.addrs.len == 0) return Error.UnresolvableHost;

    // Reject if ANY address is blocked (a host must not smuggle a
    // private address into the record set alongside a public one);
    // keep up to MAX_PIN_ADDRS vetted addresses for the pin.
    for (list.addrs) |a| {
        if (isBlocked(a)) return Error.BlockedAddress;
        if (out.address_count < MAX_PIN_ADDRS) {
            out.addresses[out.address_count] = a;
            out.address_count += 1;
        }
    }
    return out;
}

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
    if (a == 127) return !test_allow_loopback;
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
        return !test_allow_loopback;
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
        "10.0.0.1",        "10.255.255.255",  "127.0.0.1",      "127.1.2.3",
        "169.254.169.254", "172.16.0.1",      "172.31.255.254", "192.168.1.1",
        "192.168.254.1",   "100.64.0.1",      "0.0.0.0",        "224.0.0.1",
        "239.255.255.255", "255.255.255.255", "198.18.0.1",     "198.51.100.1",
    };
    for (blocked) |s| {
        const addr = try std.net.Address.parseIp4(s, 0);
        try testing.expect(isBlocked(addr));
    }
}

test "isBlocked v4: public addresses pass" {
    const allowed = [_][]const u8{
        "8.8.8.8",        "1.1.1.1",     "172.15.0.1", "192.169.0.1",
        "100.63.255.255", "100.128.0.1", "54.210.1.1",
    };
    for (allowed) |s| {
        const addr = try std.net.Address.parseIp4(s, 0);
        try testing.expect(!isBlocked(addr));
    }
}

test "isBlocked v6: loopback + link-local + ULA" {
    const blocked = [_][]const u8{
        "::1",              "::",              "fe80::1", "fc00::1", "fd12:3456::1", "ff02::1",
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

test "checkUrl: scheme policy" {
    // Non-http(s) schemes are rejected outright — curl must never see
    // a file:/gopher:/ftp: URL from a handler.
    try testing.expectError(Error.UnsupportedScheme, checkUrl(testing.allocator, "file:///etc/passwd"));
    try testing.expectError(Error.UnsupportedScheme, checkUrl(testing.allocator, "gopher://8.8.8.8/x"));
    try testing.expectError(Error.UnsupportedScheme, checkUrl(testing.allocator, "ftp://8.8.8.8/x"));
    // Plaintext http is blocked unless the test escape hatch is set.
    try testing.expectError(Error.PlaintextBlocked, checkUrl(testing.allocator, "http://8.8.8.8/x"));
    try testing.expectError(Error.BadUrl, checkUrl(testing.allocator, "not a url"));
}

test "parseUrl: scheme policy + host/port extraction, no resolution" {
    // Same scheme taxonomy as checkUrl (it IS checkUrl's first half).
    try testing.expectError(Error.UnsupportedScheme, parseUrl("file:///etc/passwd"));
    try testing.expectError(Error.PlaintextBlocked, parseUrl("http://example.com/"));
    try testing.expectError(Error.BadUrl, parseUrl("not a url"));

    // Host/port extraction — note the host is NOT resolved or
    // blocklist-checked here (a name that would never resolve parses
    // fine; the tenant door pins its own address, checkUrl resolves).
    const p = try parseUrl("https://b.rewindjs.test/path?q=1");
    try testing.expectEqualStrings("b.rewindjs.test", p.host);
    try testing.expectEqual(@as(u16, 443), p.port);

    const with_port = try parseUrl("https://B.Example.COM:8443/");
    try testing.expectEqualStrings("B.Example.COM", with_port.host);
    try testing.expectEqual(@as(u16, 8443), with_port.port);

    // IPv6 brackets stripped, as in checkUrl.
    const v6 = try parseUrl("https://[2001:db8::1]:9443/");
    try testing.expectEqualStrings("2001:db8::1", v6.host);
    try testing.expectEqual(@as(u16, 9443), v6.port);
}

test "checkUrl: literal-IP policy + ports" {
    const ok = try checkUrl(testing.allocator, "https://8.8.8.8/path?q=1");
    try testing.expect(ok.host_is_literal);
    try testing.expectEqual(@as(u16, 443), ok.port);
    try testing.expectEqualStrings("8.8.8.8", ok.host);

    const with_port = try checkUrl(testing.allocator, "https://1.1.1.1:8443/");
    try testing.expectEqual(@as(u16, 8443), with_port.port);

    try testing.expectError(Error.BlockedAddress, checkUrl(testing.allocator, "https://127.0.0.1/"));
    try testing.expectError(Error.BlockedAddress, checkUrl(testing.allocator, "https://169.254.169.254/latest/meta-data/"));
    try testing.expectError(Error.BlockedAddress, checkUrl(testing.allocator, "https://10.1.2.3:8080/"));
    // Userinfo must not confuse host extraction.
    try testing.expectError(Error.BlockedAddress, checkUrl(testing.allocator, "https://public.example@127.0.0.1/"));
    // IPv6 literals, bracketed per RFC 3986.
    try testing.expectError(Error.BlockedAddress, checkUrl(testing.allocator, "https://[::1]/"));
    try testing.expectError(Error.BlockedAddress, checkUrl(testing.allocator, "https://[fd00::1]:8443/"));
    const v6ok = try checkUrl(testing.allocator, "https://[2001:4860:4860::8888]/");
    try testing.expect(v6ok.host_is_literal);
    try testing.expectEqualStrings("2001:4860:4860::8888", v6ok.host);
}

test "checkUrl: test_allow hatches" {
    test_allow_plaintext = true;
    test_allow_loopback = true;
    defer {
        test_allow_plaintext = false;
        test_allow_loopback = false;
    }
    const loop = try checkUrl(testing.allocator, "http://127.0.0.1:18443/echo");
    try testing.expect(loop.host_is_literal);
    try testing.expectEqual(@as(u16, 18443), loop.port);
    // Metadata range stays blocked even under the hatches.
    try testing.expectError(Error.BlockedAddress, checkUrl(testing.allocator, "http://169.254.169.254/"));
}
