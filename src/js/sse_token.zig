//! `/_session/sse-token` mint endpoint (sse-plan §5.1).
//!
//! Same-origin to whatever domain the customer's app is on. Reads
//! `__Host-rove_sid` (mints if missing), then mints a JWT scoped to
//! `(tenant_id, sid)` plus the per-tier caps. The browser hands this
//! token to sse-server's EventSource open at
//! `https://sse.{public_suffix}/v1/{tenant_id}/sse?token=...`.
//!
//! Wire shape:
//!
//!   GET /_session/sse-token
//!   → 200 application/json
//!     { "token": "<JWT>", "expires_in": 3600 }
//!
//! JWT payload (HS256, signed with the cluster's
//! `LOOP46_SERVICES_JWT_SECRET`):
//!
//!   { "v": 1,
//!     "tenant_id": "<scope_id>",
//!     "sid":       "<64-hex session id>",
//!     "caps":      { "max_conns_per_session":   5,
//!                    "max_event_payload_bytes": 65536 },
//!     "exp":       <unix_ms> }
//!
//! Caps are embedded so sse-server doesn't need a callback into the
//! worker on every connect. Cap changes propagate within `TOKEN_TTL`
//! when clients refresh; for emergency tightening, revoking the
//! session itself drops the token's effective scope on next refresh.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const jwt_mod = @import("rove-jwt");

const respb = @import("response_builder.zig");
const session_mod = @import("session.zig");
const events_mod = @import("events.zig");

/// Token validity. 1 hour matches sse-plan §5.1; the client refreshes
/// before exp by re-fetching this endpoint.
pub const TOKEN_TTL_MS: i64 = 60 * 60 * 1000;

/// Match `GET /_session/sse-token` (with optional `?query`). Returns
/// true iff the endpoint matched + the response was finalized. On
/// match: response stamped (and Set-Cookie if a fresh sid was minted),
/// entity moved into `response_in`.
pub fn tryHandleSseToken(
    server: anytype,
    allocator: std.mem.Allocator,
    services_jwt_secret: ?[]const u8,
    instance_id: []const u8,
    ent: rove.Entity,
    sid_h2: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    path: []const u8,
    rh: h2.ReqHeaders,
    received_ns: i64,
) !bool {
    const qmark = std.mem.indexOfScalar(u8, path, '?');
    const path_no_q = if (qmark) |q| path[0..q] else path;
    if (!std.mem.eql(u8, path_no_q, "/_session/sse-token")) return false;

    if (!std.mem.eql(u8, method, "GET")) {
        try respb.setSimpleResponse(server, ent, sid_h2, sess, 405, "GET only\n", allocator);
        return true;
    }

    // Without the JWT secret we can't sign anything sse-server will
    // verify; surface 503 so the caller knows the platform isn't
    // wired (matches `/_system/services-token`'s posture).
    const secret = services_jwt_secret orelse {
        try respb.setSimpleResponse(server, ent, sid_h2, sess, 503, "sse-token not configured\n", allocator);
        return true;
    };

    var prng = std.Random.DefaultPrng.init(@bitCast(received_ns));
    const resolved = session_mod.resolve(rh, prng.random());

    const exp_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms) + TOKEN_TTL_MS);

    // Build the payload. Caps embedded inline (sse-plan §5.1) so the
    // sse-server connect path never has to call back to the worker.
    // v1 free-tier values; plan-tier resolution arrives with Phase 10.
    const caps = events_mod.FREE;
    const payload_json = try std.fmt.allocPrint(
        allocator,
        "{{\"v\":1,\"tenant_id\":\"{s}\",\"sid\":\"{s}\",\"caps\":{{\"max_conns_per_session\":{d},\"max_event_payload_bytes\":{d}}},\"exp\":{d}}}",
        .{
            instance_id,
            &resolved.sid,
            caps.max_concurrent_connections_per_session,
            caps.max_event_payload_bytes,
            exp_ms,
        },
    );
    defer allocator.free(payload_json);

    const token = jwt_mod.mintWithPayload(allocator, secret, payload_json) catch |err| {
        std.log.warn("sse-token mint failed: {s}", .{@errorName(err)});
        try respb.setSimpleResponse(server, ent, sid_h2, sess, 500, "mint failed\n", allocator);
        return true;
    };
    defer allocator.free(token);

    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"token\":\"{s}\",\"expires_in\":{d}}}\n",
        .{ token, @divTrunc(TOKEN_TTL_MS, 1000) },
    );
    errdefer allocator.free(body);

    const platform_cookie: ?[]u8 = if (resolved.mint_set_cookie)
        try session_mod.formatSetCookie(allocator, &resolved.sid)
    else
        null;
    defer if (platform_cookie) |pc| allocator.free(pc);

    var pairs_buf: [3]respb.RespHeaderPair = undefined;
    var n: usize = 0;
    pairs_buf[n] = .{ .name = "content-type", .value = "application/json" };
    n += 1;
    pairs_buf[n] = .{ .name = "cache-control", .value = "no-store" };
    n += 1;
    if (platform_cookie) |pc| {
        pairs_buf[n] = .{ .name = "set-cookie", .value = pc };
        n += 1;
    }
    const hdrs = try respb.packRespHeaders(allocator, pairs_buf[0..n]);

    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = 200 });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, hdrs);
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = body.ptr,
        .len = @intCast(body.len),
    });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid_h2);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);

    return true;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "tryHandleSseToken ignores non-matching paths" {
    // Pure routing test — no rove/h2 plumbing needed since the handler
    // returns false before touching `server`. We simulate a minimal
    // matcher by lifting just the path test.
    const path = "/_events";
    const qmark = std.mem.indexOfScalar(u8, path, '?');
    const path_no_q = if (qmark) |q| path[0..q] else path;
    try testing.expect(!std.mem.eql(u8, path_no_q, "/_session/sse-token"));
}

test "tryHandleSseToken matches with query string" {
    const path = "/_session/sse-token?_=1";
    const qmark = std.mem.indexOfScalar(u8, path, '?');
    const path_no_q = if (qmark) |q| path[0..q] else path;
    try testing.expect(std.mem.eql(u8, path_no_q, "/_session/sse-token"));
}

test "minted token verifies with the same secret + carries tenant_id and sid" {
    const a = testing.allocator;
    const secret = "platform-key";

    const payload = try std.fmt.allocPrint(
        a,
        "{{\"v\":1,\"tenant_id\":\"acme\",\"sid\":\"{s}\",\"caps\":{{\"max_conns_per_session\":16,\"max_event_payload_bytes\":65536}},\"exp\":{d}}}",
        .{ "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", 1_000_000_000_000 },
    );
    defer a.free(payload);

    const tok = try jwt_mod.mintWithPayload(a, secret, payload);
    defer a.free(tok);

    var buf: [512]u8 = undefined;
    const decoded = try jwt_mod.verifyAndCopyPayload(secret, tok, 999_999_999_999, &buf);
    try testing.expect(std.mem.indexOf(u8, decoded, "\"tenant_id\":\"acme\"") != null);
    try testing.expect(std.mem.indexOf(u8, decoded, "\"sid\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"") != null);
}
