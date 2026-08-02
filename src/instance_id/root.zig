//! The instance-id spec: what a tenant id may be, and how it maps to a
//! subdomain of the platform zone.
//!
//! Two independent processes read this rule and must agree, which is why it
//! is a leaf module rather than a function in either of them:
//!
//!   - the **worker** resolves an inbound `{id}.{public_suffix}` Host to a
//!     local instance with no stored alias (`rove-tenant`'s `resolveDomain`);
//!   - the **control plane** validates the id when a tenant is provisioned,
//!     and resolves the same wildcard when the front door asks it who owns a
//!     host (`/_cp/route`).
//!
//! A customer id therefore has to be a legal DNS label *and* must not claim a
//! platform-looking subdomain — if the CP accepted an id the worker's
//! wildcard would not resolve, provisioning would report success and the
//! tenant would be unreachable.

const std = @import("std");

/// Reserved tenant id for the admin/control instance — the one instance
/// whose handler holds the `platform.*` capability.
pub const ADMIN_INSTANCE_ID = "__admin__";

/// Reserved tenant id for the tape-replay browser page, reached via the
/// `replay.{public_suffix}` host alias.
pub const REPLAY_INSTANCE_ID = "__replay__";

/// Reserved tenant id for the OIDC identity provider, reached via the
/// `auth.{system_suffix}` host alias.
pub const AUTH_INSTANCE_ID = "__auth__";

/// Platform-reserved tenant ids (the `__name__` form). Exempt from the
/// DNS-label spec below — they are internal singletons that never resolve as
/// a public subdomain. Customers cannot create them: the `__…__` form fails
/// DNS validation (underscores), and only these exact ids are exempted.
pub const RESERVED_INSTANCE_IDS = [_][]const u8{
    ADMIN_INSTANCE_ID,
    REPLAY_INSTANCE_ID,
    AUTH_INSTANCE_ID,
};

/// Upper bound on any instance id, including the `__…__` platform ids.
/// Sizes the key buffers that embed an id.
pub const MAX_INSTANCE_ID_LEN: usize = 64;

/// A DNS host label is capped at 63 octets, and a customer id serves as a
/// `{id}.<zone>` subdomain.
pub const MAX_DNS_LABEL_LEN: usize = 63;

/// Subdomain labels reserved away from customer instance ids. Because an id
/// auto-routes as `{id}.<platform-zone>`, a customer who provisioned
/// `auth`/`api`/… would claim a platform-looking subdomain on our own zone —
/// so we deny these at provisioning, pre-customer, while it's free to do so
/// (docs/architecture/format-versioning.md §7.7). Curated platform-product +
/// infra labels; extend as new platform surfaces appear. NOT generic business
/// words (blog/shop/docs/…) — those stay available to customers. All
/// lowercase (ids are already lowercased by the DNS check), so an exact match
/// suffices.
const RESERVED_SUBDOMAIN_LABELS = [_][]const u8{
    // platform product surfaces
    "admin",  "api",      "app",      "account", "accounts", "auth",
    "billing","console",  "dashboard","login",   "logout",   "signup",
    "register",
    // brand / ops
    "rewind", "ops",      "internal", "system",  "status",
    // well-known infra / RFC-ish
    "www",    "mail",     "smtp",     "imap",    "pop",      "ftp",
    "sftp",   "ssh",      "ns",       "ns1",     "ns2",      "mx",
    "dns",    "cdn",      "static",   "assets",  "media",    "blob",
    "proxy",  "gateway",  "vpn",      "ssl",     "tls",
    "webhook","webhooks", "email",    "ws",      "wss",      "autoconfig",
    "autodiscover",
    // NOTE: the ACME http-01 / dns-01 challenge label is `_acme-challenge`
    // (leading `_` → already an invalid instance id); bare `acme` is left
    // available so it doesn't collide with the `acme` example-tenant used
    // throughout the test + smoke suite.
};

/// Why an id was rejected. Carried out to the caller so a provisioning
/// surface can tell the customer which rule they hit — "that name is
/// reserved" and "no underscores" are different fixes, and a bare 400 makes
/// the dashboard guess.
pub const Reject = enum {
    empty,
    too_long,
    bad_char,
    hyphen_edge,
    reserved_label,

    /// A customer-facing one-liner. Phrased as the rule, not the violation,
    /// so it reads the same whether it lands in a CLI or a form field.
    pub fn message(self: Reject) []const u8 {
        return switch (self) {
            .empty => "name is required",
            .too_long => "name must be at most 63 characters",
            .bad_char => "name may use only lowercase letters, digits and hyphens",
            .hyphen_edge => "name must not start or end with a hyphen",
            .reserved_label => "that name is reserved",
        };
    }
};

/// Check an instance id against the spec: `^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`
/// and not a reserved subdomain label. Returns null when the id is
/// acceptable, else the rule it broke.
///
/// Lowercase only (DNS is case-insensitive), no `_` (invalid in DNS host
/// labels), no leading/trailing hyphen, ≤63 octets. This is the strictest
/// plausible spec, locked pre-customer; loosening later is always safe,
/// tightening is not (docs/architecture/format-versioning.md §7.4).
/// Platform-reserved `__…__` ids are exempted.
pub fn check(id: []const u8) ?Reject {
    if (id.len == 0) return .empty;
    for (RESERVED_INSTANCE_IDS) |r| {
        if (std.mem.eql(u8, id, r)) return null;
    }
    if (id.len > MAX_DNS_LABEL_LEN) return .too_long;
    for (id, 0..) |b, i| {
        const ok = (b >= 'a' and b <= 'z') or
            (b >= '0' and b <= '9') or
            b == '-';
        if (!ok) return .bad_char;
        // No leading or trailing hyphen.
        if (b == '-' and (i == 0 or i == id.len - 1)) return .hyphen_edge;
    }
    // Reserve platform/infra subdomain labels — a customer must not be able
    // to become `auth.<zone>` / `api.<zone>` / … via the wildcard route.
    if (isReservedSubdomainLabel(id)) return .reserved_label;
    return null;
}

/// `check` reduced to a predicate, for callers with nothing to report.
pub fn isValid(id: []const u8) bool {
    return check(id) == null;
}

fn isReservedSubdomainLabel(id: []const u8) bool {
    for (RESERVED_SUBDOMAIN_LABELS) |r| {
        if (std.mem.eql(u8, id, r)) return true;
    }
    return false;
}

/// The instance id implied by `host` under the wildcard pattern
/// `{id}.{suffix}`, or null when the host doesn't match it. Does NOT check
/// that the id is valid or that such an instance exists — that is the
/// caller's job, and the two answers differ: the worker asks whether it holds
/// the instance, the CP asks whether the tenant is placed.
///
/// Single-label only: `a.b.{suffix}` does not match, so a deeper subdomain
/// stays available for an explicit alias.
pub fn wildcardLabel(host: []const u8, suffix: []const u8) ?[]const u8 {
    if (suffix.len == 0) return null;
    if (host.len <= suffix.len + 1) return null;
    const dot_before = host.len - suffix.len - 1;
    if (host[dot_before] != '.') return null;
    if (!std.mem.eql(u8, host[dot_before + 1 ..], suffix)) return null;
    const sub = host[0..dot_before];
    if (std.mem.indexOfScalar(u8, sub, '.') != null) return null;
    return sub;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "check accepts DNS-label-safe ids" {
    try testing.expect(check("acme") == null);
    try testing.expect(check("a") == null);
    try testing.expect(check("my-app-2") == null);
    try testing.expect(check("0") == null);
    try testing.expect(check("a" ** MAX_DNS_LABEL_LEN) == null);
}

test "check rejects each rule with the rule it broke" {
    try testing.expectEqual(Reject.empty, check("").?);
    try testing.expectEqual(Reject.too_long, check("a" ** (MAX_DNS_LABEL_LEN + 1)).?);
    try testing.expectEqual(Reject.bad_char, check("Acme").?); // uppercase
    try testing.expectEqual(Reject.bad_char, check("my_app").?); // underscore
    try testing.expectEqual(Reject.bad_char, check("a.b").?); // dot
    try testing.expectEqual(Reject.hyphen_edge, check("-acme").?);
    try testing.expectEqual(Reject.hyphen_edge, check("acme-").?);
    try testing.expectEqual(Reject.reserved_label, check("auth").?);
    try testing.expectEqual(Reject.reserved_label, check("www").?);
}

test "check exempts the platform singletons and nothing else" {
    try testing.expect(check(ADMIN_INSTANCE_ID) == null);
    try testing.expect(check(REPLAY_INSTANCE_ID) == null);
    try testing.expect(check(AUTH_INSTANCE_ID) == null);
    // A customer cannot mint their own `__…__` id.
    try testing.expectEqual(Reject.bad_char, check("__other__").?);
}

test "every Reject has a message" {
    inline for (@typeInfo(Reject).@"enum".fields) |f| {
        const r: Reject = @enumFromInt(f.value);
        try testing.expect(r.message().len > 0);
    }
}

test "wildcardLabel splits {id}.{suffix} and only that" {
    try testing.expectEqualStrings("acme", wildcardLabel("acme.rewindjs.app", "rewindjs.app").?);
    // Not the pattern.
    try testing.expect(wildcardLabel("rewindjs.app", "rewindjs.app") == null);
    // A bare dot yields no label: the length guard rejects it before `sub`
    // could come back empty, so callers never have to test for that.
    try testing.expect(wildcardLabel(".rewindjs.app", "rewindjs.app") == null);
    try testing.expect(wildcardLabel("acme.example.com", "rewindjs.app") == null);
    try testing.expect(wildcardLabel("acmerewindjs.app", "rewindjs.app") == null);
    // Multi-label subdomains stay available for explicit aliases.
    try testing.expect(wildcardLabel("a.b.rewindjs.app", "rewindjs.app") == null);
    // No suffix configured → wildcard disabled.
    try testing.expect(wildcardLabel("acme.rewindjs.app", "") == null);
}

test "an unconfigured suffix cannot swallow a host" {
    // Guards the `suffix.len == 0` early return: without it every host would
    // match, and an empty label would resolve as a tenant.
    try testing.expect(wildcardLabel("anything", "") == null);
    try testing.expect(wildcardLabel("a.b", "") == null);
}
