//! URL → "is this an in-cluster target?" detection (http-send-plan §3.2).
//!
//! Steady-state path: every customer's `webhook.send` routes through
//! `webhook.loop46.com`, which lives on the cluster as a system tenant.
//! Outbound libcurl + cluster ingress + a worker's h2 stack is ~10-50ms
//! that the scheduler can avoid by recognizing the target and handing
//! the row to the worker phase that hosts the tenant in-process.
//!
//! Detection is a pure function of `url`, the cluster's `public_suffix`,
//! and "does this id have an existence marker in __root__.db". All three
//! are deterministic across raft replicas, so this can run at apply
//! time without divergence — every node reaches the same `is_internal`
//! verdict for every row.
//!
//! ## What this module is NOT
//!
//! - **Not the dispatch path.** It returns the tenant id; the caller
//!   (apply for stamping; worker phase for routing) decides what to do.
//! - **Not a security gate.** Discovering that a host parses as an
//!   internal target is *informational*, not authorizing. The handler
//!   the row eventually runs against still authenticates per its own
//!   rules. SSRF + auth happen elsewhere.
//! - **Not exhaustive.** Multi-label subdomains (`api.foo.loop46.me`)
//!   are rejected — the wildcard is single-label by design (mirrors
//!   `tenant_mod.wildcardInstanceId`). Customers who want deeper
//!   nesting need an explicit `assignDomain` entry; routing those is
//!   a future hop.

const std = @import("std");

/// Extract the tenant instance id from a URL whose host matches
/// `{id}.{public_suffix}`. Returns null when:
///   - URL doesn't parse
///   - URL has no host
///   - host doesn't end in `.{public_suffix}`
///   - the implied id contains a dot (multi-label subdomain)
///   - the implied id is empty
///
/// **Does NOT validate** that the id corresponds to a real instance —
/// that's a second hop the caller does via `tenant.instanceExists`.
/// Splitting parse-vs-existence keeps this fn pure (testable without
/// a Tenant) and keeps the existence check optional for callers that
/// don't have a tenant registry handy.
///
/// Strips the port off the host before matching, so `https://acme.loop46.me:443/x`
/// works the same as `https://acme.loop46.me/x`.
pub fn parseInstanceId(url: []const u8, public_suffix: []const u8) ?[]const u8 {
    if (public_suffix.len == 0) return null;
    const uri = std.Uri.parse(url) catch return null;
    const host_raw = switch (uri.host orelse return null) {
        .raw => |h| h,
        .percent_encoded => |h| h,
    };
    const host = stripPort(host_raw);
    if (host.len <= public_suffix.len + 1) return null;
    const dot_before = host.len - public_suffix.len - 1;
    if (host[dot_before] != '.') return null;
    if (!std.ascii.eqlIgnoreCase(host[dot_before + 1 ..], public_suffix)) return null;
    const id = host[0..dot_before];
    if (id.len == 0) return null;
    if (std.mem.indexOfScalar(u8, id, '.') != null) return null;
    return id;
}

/// Port-stripped host of `url`, or null if it doesn't parse / has no
/// host. For the **explicit `assignDomain` internal path**: a system
/// tenant (`auth.{system_suffix}`, `replay.{system_suffix}`, …) is
/// NOT a `{id}.{public_suffix}` wildcard host, so `parseInstanceId`
/// correctly rejects it — the caller instead resolves this host
/// against the raft-replicated `domain/{host}` map (still
/// deterministic across replicas; that map is __root__.db state, the
/// same class of input this module's doc already sanctions). Without
/// this, `http.send` to the platform IdP (`auth.{system_suffix}`)
/// was demoted to a real outbound call, defeating §4.6's "the issuer
/// resolves cluster-local" and breaking the Fork-B RP token/jwks
/// completion in any deployment.
pub fn targetHost(url: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    const host_raw = switch (uri.host orelse return null) {
        .raw => |h| h,
        .percent_encoded => |h| h,
    };
    const h = stripPort(host_raw);
    return if (h.len == 0) null else h;
}

/// The URL's authority **verbatim** — `host` or `host:port` exactly
/// as written, userinfo stripped. Unlike `targetHost` (port-stripped,
/// for domain-map *matching*), this is what the internal-dispatch
/// path sets as the synthesized request's `:authority` so a
/// host-relative handler (the IdP's `iss`, the §4.6 self-rotate URL)
/// sees the SAME issuer the caller addressed — which, for the
/// dogfooded RP↔IdP pair, is by construction the issuer the RP
/// validates against (auth-domain-plan §4.7 "Option B"). Slice into
/// `url`; null if there's no `://` or the authority is empty.
pub fn targetAuthority(url: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[sep + 3 ..];
    var end: usize = rest.len;
    for (rest, 0..) |ch, i| {
        if (ch == '/' or ch == '?' or ch == '#') {
            end = i;
            break;
        }
    }
    var authority = rest[0..end];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
        authority = authority[at + 1 ..];
    }
    return if (authority.len == 0) null else authority;
}

/// Strip a `:port` suffix if present. Returns the host as-is when no
/// port was specified. We don't validate the port digits — Uri.parse
/// already did that; we just need the host portion for suffix matching.
fn stripPort(host: []const u8) []const u8 {
    // IPv6-literal hosts are bracketed (`[::1]:443`). Find the closing
    // bracket and treat anything after as port. For non-bracketed
    // hosts a colon at any position is a port separator.
    if (host.len > 0 and host[0] == '[') {
        if (std.mem.indexOfScalar(u8, host, ']')) |close| {
            return host[0 .. close + 1];
        }
        return host;
    }
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
        return host[0..colon];
    }
    return host;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseInstanceId matches single-label subdomain" {
    const id = parseInstanceId("https://acme.loop46.me/v1/charge", "loop46.me");
    try testing.expectEqualStrings("acme", id.?);
}

test "parseInstanceId honors port" {
    const id = parseInstanceId("https://acme.loop46.me:8443/x", "loop46.me");
    try testing.expectEqualStrings("acme", id.?);
}

test "parseInstanceId case-insensitive on suffix" {
    const id = parseInstanceId("https://acme.LOOP46.me/x", "loop46.me");
    try testing.expectEqualStrings("acme", id.?);
}

test "parseInstanceId rejects multi-label subdomain" {
    // `api.foo.loop46.me` → would imply id=`api.foo` which has a dot
    try testing.expect(parseInstanceId("https://api.foo.loop46.me/x", "loop46.me") == null);
}

test "parseInstanceId rejects bare suffix" {
    try testing.expect(parseInstanceId("https://loop46.me/x", "loop46.me") == null);
}

test "parseInstanceId rejects different domain" {
    try testing.expect(parseInstanceId("https://acme.example.com/x", "loop46.me") == null);
}

test "parseInstanceId rejects malformed url" {
    try testing.expect(parseInstanceId("not a url", "loop46.me") == null);
}

test "parseInstanceId rejects empty public_suffix" {
    try testing.expect(parseInstanceId("https://acme.loop46.me/x", "") == null);
}

test "parseInstanceId rejects empty id (`.loop46.me`)" {
    try testing.expect(parseInstanceId("https://.loop46.me/x", "loop46.me") == null);
}

test "stripPort handles bracketed ipv6" {
    try testing.expectEqualStrings("[::1]", stripPort("[::1]:443"));
    try testing.expectEqualStrings("[::1]", stripPort("[::1]"));
}

test "stripPort handles plain host with port" {
    try testing.expectEqualStrings("acme.loop46.me", stripPort("acme.loop46.me:443"));
    try testing.expectEqualStrings("acme.loop46.me", stripPort("acme.loop46.me"));
}

test "targetHost strips port + survives non-wildcard system hosts" {
    try testing.expectEqualStrings(
        "auth.rewindjscom.localhost",
        targetHost("https://auth.rewindjscom.localhost:8295/token").?);
    try testing.expectEqualStrings(
        "auth.rewindjs.com", targetHost("https://auth.rewindjs.com/token").?);
    try testing.expect(targetHost("not a url") == null);
}

test "targetAuthority keeps the port verbatim" {
    try testing.expectEqualStrings(
        "auth.rewindjscom.localhost:8295",
        targetAuthority("https://auth.rewindjscom.localhost:8295/token?x=1").?);
    try testing.expectEqualStrings(
        "auth.rewindjs.com", targetAuthority("https://auth.rewindjs.com/_oidc/rotate").?);
    try testing.expectEqualStrings(
        "h:1", targetAuthority("https://u@h:1/p").?); // userinfo stripped
    try testing.expect(targetAuthority("not a url") == null);
}
