//! HTTP-level admin authentication helpers shared by the dispatch
//! and `/_system/*` paths in worker.zig.
//!
//! Two equally-valid mechanisms:
//!   - `Authorization: Bearer <token>` — root token or per-instance
//!     bearer token. Validated via `tenant.authenticate`.
//!   - `Cookie: rove_session=<id>` — session cookie minted by
//!     `/v1/login`. Validated via `tenant.authenticateSession`.
//!
//! Cookie wins when both are present (matches what browsers do
//! automatically; bearer is the explicit-API path).

const std = @import("std");
const h2 = @import("rove-h2");
const tenant_mod = @import("rove-tenant");

const respb = @import("response_builder.zig");

/// Name of the admin session cookie. Single hard-coded identifier —
/// don't scatter the string elsewhere.
pub const ADMIN_SESSION_COOKIE: []const u8 = "rove_session";

/// Extract the bearer token from the `authorization` header.
/// Returns null if the header is absent, the scheme isn't `Bearer`,
/// or the token is empty. Header name is lowercase per HTTP/2 rules.
pub fn extractBearerToken(hdrs: h2.ReqHeaders) ?[]const u8 {
    const value = respb.findHeader(hdrs, "authorization") orelse return null;
    const prefix = "Bearer ";
    if (value.len <= prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix)) return null;
    const token = value[prefix.len..];
    if (token.len == 0) return null;
    return token;
}

/// Find `name` inside the request's Cookie header. Returns the raw
/// value (trimmed of surrounding whitespace) or null if missing.
pub fn findCookie(hdrs: h2.ReqHeaders, name: []const u8) ?[]const u8 {
    const value = respb.findHeader(hdrs, "cookie") orelse return null;
    var rest = value;
    while (rest.len > 0) {
        while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t' or rest[0] == ';')) {
            rest = rest[1..];
        }
        if (rest.len == 0) break;
        const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const segment = rest[0..end];
        if (std.mem.indexOfScalar(u8, segment, '=')) |eq| {
            const k = segment[0..eq];
            const v = segment[eq + 1 ..];
            if (std.mem.eql(u8, k, name)) {
                // Cookies may be quoted — strip one pair if present.
                if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') {
                    return v[1 .. v.len - 1];
                }
                return v;
            }
        }
        rest = rest[end..];
    }
    return null;
}

/// Try to authenticate an admin request using either a session cookie
/// or an Authorization: Bearer header (in that order). Cookie wins if
/// both are present. Returns the resolved AuthContext or null.
pub fn extractAdminAuth(
    tenant: *tenant_mod.Tenant,
    hdrs: h2.ReqHeaders,
) !?tenant_mod.AuthContext {
    if (findCookie(hdrs, ADMIN_SESSION_COOKIE)) |cookie_val| {
        if (try tenant.authenticateSession(cookie_val)) |ctx| return ctx;
    }
    if (extractBearerToken(hdrs)) |token| {
        return try tenant.authenticate(token);
    }
    return null;
}
