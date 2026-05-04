//! Platform-managed session cookie. Eagerly minted on every JS-handler
//! request that doesn't already carry one. Exposed to handlers as
//! `request.session.id`. Defines the SSE event-routing identity per
//! `docs/sse-plan.md` §1.
//!
//! ## Cookie shape
//!
//! Name `__Host-rove_sid`, value 64 hex chars (256 bits CSPRNG).
//! Attributes: `HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/`,
//! `Max-Age=31536000`. The `__Host-` prefix is browser-enforced —
//! browsers refuse to set cookies with that prefix unless `Secure`
//! is present, no `Domain=` attribute is given, and `Path=/`. So the
//! prefix catches misconfiguration at the browser, not just on our
//! end. It also forbids cross-host send: a tenant-A cookie is never
//! sent to tenant-B, providing free defense-in-depth on top of the
//! structural per-tenant-app.db isolation that the SSE pump already
//! enforces.
//!
//! ## Mint policy
//!
//! Static-asset and `/_system/*` paths short-circuit before this
//! function is called, so they don't pollute. Any handler-dispatch
//! path or `/_events` connect that doesn't see `__Host-rove_sid` in
//! the request gets a fresh sid minted and `Set-Cookie` appended.
//!
//! ## Why no validation table
//!
//! The cookie value IS the id. There's no server-side row to look up
//! — the customer gets a stable id and is responsible for binding it
//! to their own user identity (e.g. `kv.set("sessions/" + sid +
//! "/user", userId)`). Cross-tenant integrity is enforced
//! structurally; cookie-value uniqueness is by 256-bit randomness.

const std = @import("std");
const h2 = @import("rove-h2");

const respb = @import("response_builder.zig");
const auth = @import("auth.zig");

/// Cookie name, including the `__Host-` prefix.
pub const COOKIE_NAME: []const u8 = "__Host-rove_sid";

/// Length of a session id on the wire (hex characters). 256 bits of
/// randomness encoded as 64 lowercase hex.
pub const SID_LEN: usize = 64;

/// Wire `Set-Cookie` value when minting a fresh sid. Concrete
/// attributes are documented at the top of the file. The actual
/// emitted header is `__Host-rove_sid={64hex}; ...`; this constant
/// holds the suffix only — see `formatSetCookie`.
const COOKIE_ATTRS: []const u8 =
    "; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=31536000";

pub const Resolved = struct {
    sid: [SID_LEN]u8,
    /// True when the request arrived without `__Host-rove_sid` and we
    /// just minted a fresh value. Caller appends a `Set-Cookie` to
    /// the response (see `formatSetCookie`). False when the request
    /// already carried a valid cookie — no `Set-Cookie` needed.
    mint_set_cookie: bool,
};

/// Read `__Host-rove_sid` from the request; if absent or malformed,
/// mint a fresh 64-hex sid from `rng` and signal the caller to set a
/// cookie on the response.
pub fn resolve(hdrs: ?h2.ReqHeaders, rng: std.Random) Resolved {
    if (hdrs) |h| {
        if (auth.findCookie(h, COOKIE_NAME)) |existing| {
            if (existing.len == SID_LEN and isAllHex(existing)) {
                var out: [SID_LEN]u8 = undefined;
                @memcpy(&out, existing);
                return .{ .sid = out, .mint_set_cookie = false };
            }
            // Malformed cookie — re-mint. Treat the stale value as
            // never having existed; we can't invalidate the bad one
            // (no validation table) but a fresh `Set-Cookie` will
            // overwrite it on the client.
        }
    }

    var raw: [SID_LEN / 2]u8 = undefined;
    rng.bytes(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    return .{ .sid = hex, .mint_set_cookie = true };
}

/// Format the wire `Set-Cookie` value (just the value, not the
/// `set-cookie:` header name) for a freshly-minted sid. Allocator
/// owns the returned slice.
pub fn formatSetCookie(allocator: std.mem.Allocator, sid: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}={s}{s}",
        .{ COOKIE_NAME, sid, COOKIE_ATTRS },
    );
}

fn isAllHex(s: []const u8) bool {
    for (s) |b| {
        const ok = (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f');
        if (!ok) return false;
    }
    return true;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "resolve: mints when no cookie header" {
    var prng = std.Random.DefaultPrng.init(0xdead_beef);
    const r = resolve(null, prng.random());
    try testing.expect(r.mint_set_cookie);
    try testing.expectEqual(SID_LEN, r.sid.len);
    try testing.expect(isAllHex(&r.sid));
}

test "resolve: mints when cookie absent" {
    var prng = std.Random.DefaultPrng.init(1);
    var fields = [_]h2.HeaderField{
        .{
            .name = "cookie".ptr,
            .name_len = "cookie".len,
            .value = "other=value".ptr,
            .value_len = @intCast("other=value".len),
        },
    };
    const hdrs = h2.ReqHeaders{
        .fields = @ptrCast(&fields),
        .count = fields.len,
    };
    const r = resolve(hdrs, prng.random());
    try testing.expect(r.mint_set_cookie);
}

test "resolve: returns existing valid cookie" {
    var prng = std.Random.DefaultPrng.init(2);
    const known = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    var cookie_hdr_buf: [128]u8 = undefined;
    const cookie_value = std.fmt.bufPrint(&cookie_hdr_buf, "{s}={s}", .{ COOKIE_NAME, known }) catch unreachable;
    var fields = [_]h2.HeaderField{
        .{
            .name = "cookie".ptr,
            .name_len = "cookie".len,
            .value = cookie_value.ptr,
            .value_len = @intCast(cookie_value.len),
        },
    };
    const hdrs = h2.ReqHeaders{
        .fields = @ptrCast(&fields),
        .count = fields.len,
    };
    const r = resolve(hdrs, prng.random());
    try testing.expect(!r.mint_set_cookie);
    try testing.expectEqualSlices(u8, known, &r.sid);
}

test "resolve: re-mints when cookie has wrong length" {
    var prng = std.Random.DefaultPrng.init(3);
    var cookie_hdr_buf: [128]u8 = undefined;
    const cookie_value = std.fmt.bufPrint(&cookie_hdr_buf, "{s}=tooshort", .{COOKIE_NAME}) catch unreachable;
    var fields = [_]h2.HeaderField{
        .{
            .name = "cookie".ptr,
            .name_len = "cookie".len,
            .value = cookie_value.ptr,
            .value_len = @intCast(cookie_value.len),
        },
    };
    const hdrs = h2.ReqHeaders{
        .fields = @ptrCast(&fields),
        .count = fields.len,
    };
    const r = resolve(hdrs, prng.random());
    try testing.expect(r.mint_set_cookie);
}

test "resolve: re-mints when cookie has non-hex char" {
    var prng = std.Random.DefaultPrng.init(4);
    const bad = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeZ";
    var cookie_hdr_buf: [128]u8 = undefined;
    const cookie_value = std.fmt.bufPrint(&cookie_hdr_buf, "{s}={s}", .{ COOKIE_NAME, bad }) catch unreachable;
    var fields = [_]h2.HeaderField{
        .{
            .name = "cookie".ptr,
            .name_len = "cookie".len,
            .value = cookie_value.ptr,
            .value_len = @intCast(cookie_value.len),
        },
    };
    const hdrs = h2.ReqHeaders{
        .fields = @ptrCast(&fields),
        .count = fields.len,
    };
    const r = resolve(hdrs, prng.random());
    try testing.expect(r.mint_set_cookie);
}

test "formatSetCookie: includes name + sid + attrs" {
    const sid = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const out = try formatSetCookie(testing.allocator, sid);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.startsWith(u8, out, COOKIE_NAME ++ "="));
    try testing.expect(std.mem.indexOf(u8, out, sid) != null);
    try testing.expect(std.mem.indexOf(u8, out, "HttpOnly") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Secure") != null);
    try testing.expect(std.mem.indexOf(u8, out, "SameSite=Lax") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Path=/") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Max-Age=31536000") != null);
    // No Domain= attribute — required by __Host- prefix.
    try testing.expect(std.mem.indexOf(u8, out, "Domain=") == null);
}
