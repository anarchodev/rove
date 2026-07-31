//! Node origin parsing — the single definition of what the fleet can dial.
//!
//! An origin is `[scheme://]host[:port][/path]`, e.g. `http://10.99.0.1:8443`.
//! Two components share this: the CP accepts origins into the directory
//! (`REWIND_CLUSTERS`), and the front door dials them. They must agree, or
//! the CP replicates an origin the fronts cannot use and the failure only
//! surfaces at dial time, one hop away from the operator who typed it.
//!
//! Hosts MUST be IP literals. A hostname is REJECTED, not resolved:
//! `std.net.getAddressList` is a blocking DNS call and the front dials on
//! the :443 poll loop, which must never block (a slow resolver would stall
//! accept/TLS for every tenant). Production uses vRack private IPs.
//!
//! Every failure returns a distinct error and nothing is logged here — the
//! caller owns the operator message, and an error-level log in a leaf makes
//! the path untestable (Zig's test runner counts `.err` as a failure).

const std = @import("std");

pub const Error = error{
    /// No host in the origin — empty, or nothing before the port/path.
    OriginEmpty,
    /// The host is not an IP literal. Named for the operator-facing case:
    /// a hostname where an IP was required.
    HostnameOriginUnsupported,
    /// The `:port` suffix is not a u16.
    OriginBadPort,
};

/// Port assumed when an origin carries none. The workers' h2c port is
/// explicit in every real origin; this only keeps a bare IP parseable.
pub const DEFAULT_PORT: u16 = 80;

/// Parse an origin into a dialable address.
///
/// IPv6 note: the port split takes the LAST `:`, so a bare IPv6 literal
/// (`::1`) does not round-trip and a bracketed one (`[::1]:8443`) is not
/// unwrapped — both are rejected as non-IP-literal. Origins are IPv4 in
/// every deployment today; `parseIpv6WithPort` is the change to make if
/// that stops being true, and it belongs here rather than in either caller.
pub fn parse(origin: []const u8) Error!std.net.Address {
    var rest = origin;
    if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |i| rest = rest[0..i];
    if (rest.len == 0) return Error.OriginEmpty;

    var host: []const u8 = rest;
    var port: u16 = DEFAULT_PORT;
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |i| {
        host = rest[0..i];
        port = std.fmt.parseInt(u16, rest[i + 1 ..], 10) catch
            return Error.OriginBadPort;
    }
    if (host.len == 0) return Error.OriginEmpty;

    return std.net.Address.parseIp(host, port) catch
        return Error.HostnameOriginUnsupported;
}

/// True when `origin` is dialable. For validation sites that only need the
/// verdict (config parsing) rather than the address.
pub fn isValid(origin: []const u8) bool {
    _ = parse(origin) catch return false;
    return true;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "parse: IP literals, scheme and path stripping, default port" {
    try testing.expectEqual(@as(u16, 8443), (try parse("http://10.99.0.1:8443")).getPort());
    try testing.expectEqual(@as(u16, 8443), (try parse("10.99.0.1:8443")).getPort());
    try testing.expectEqual(@as(u16, 8443), (try parse("http://10.99.0.1:8443/_system/health")).getPort());
    try testing.expectEqual(DEFAULT_PORT, (try parse("10.99.0.1")).getPort());
    try testing.expectEqual(@as(u16, 18092), (try parse("https://127.0.0.1:18092")).getPort());
}

test "parse: every failure is a distinct error" {
    // A hostname is a config error, not a DNS lookup.
    try testing.expectError(error.HostnameOriginUnsupported, parse("http://worker-1.internal:8443"));
    try testing.expectError(error.HostnameOriginUnsupported, parse("http://localhost:8443"));
    try testing.expectError(error.HostnameOriginUnsupported, parse("worker-1"));

    // Malformed port — distinct from the hostname case, so the operator
    // is not told to fix the wrong half of the string.
    try testing.expectError(error.OriginBadPort, parse("http://10.99.0.1:https"));
    try testing.expectError(error.OriginBadPort, parse("10.99.0.1:99999")); // > u16
    try testing.expectError(error.OriginBadPort, parse("10.99.0.1:"));

    // Nothing to dial.
    try testing.expectError(error.OriginEmpty, parse(""));
    try testing.expectError(error.OriginEmpty, parse("http://"));
    try testing.expectError(error.OriginEmpty, parse("http:///path"));
    try testing.expectError(error.OriginEmpty, parse(":8443"));
}

test "parse: IPv6 is not supported, and says so consistently" {
    // Documented limitation, asserted so a future IPv6 change is a
    // deliberate edit here rather than a surprise at dial time. Both forms
    // land on the same error: a bare `::1` splits at its LAST colon, so the
    // host is `::` (not an IP literal) and the port happens to parse as 1 —
    // the failure is the host, not the port.
    try testing.expectError(error.HostnameOriginUnsupported, parse("[::1]:8443"));
    try testing.expectError(error.HostnameOriginUnsupported, parse("::1"));
}

test "isValid mirrors parse" {
    try testing.expect(isValid("http://10.99.0.1:8443"));
    try testing.expect(isValid("10.0.0.1"));
    try testing.expect(!isValid("http://localhost:8443"));
    try testing.expect(!isValid(""));
}
