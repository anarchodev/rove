//! Response assembly helpers — header packing, CORS, canned status
//! responses, and the static-file serving subsystem.
//!
//! Most public setters take `server: anytype`. The expected shape is
//! a `Worker.h2` value with `reg`, `request_out`, and `response_in`
//! fields — the worker.zig caller passes `worker.h2` directly. Static
//! serving additionally needs a `*TenantFiles` for the lookup tables
//! and blob backend.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const files_mod = @import("rove-files");

const dispatcher_mod = @import("dispatcher.zig");

// ── Header lookup ─────────────────────────────────────────────────────

/// Linear scan over an `h2.ReqHeaders` for a lowercase name.
pub fn findHeader(hdrs: h2.ReqHeaders, name: []const u8) ?[]const u8 {
    if (hdrs.fields == null) return null;
    const fields = hdrs.fields.?[0..hdrs.count];
    for (fields) |f| {
        const fname = f.name[0..f.name_len];
        if (std.mem.eql(u8, fname, name)) {
            return f.value[0..f.value_len];
        }
    }
    return null;
}

// ── Header packing ────────────────────────────────────────────────────

/// One (name, value) entry destined for an `h2.RespHeaders` field
/// array. The string slices must outlive the call to `packRespHeaders`
/// — typically they're either string literals or owned by the same
/// allocator the caller passes in.
pub const RespHeaderPair = struct { name: []const u8, value: []const u8 };

/// Static CORS headers that accompany every cross-origin admin
/// response. The dynamic `access-control-allow-origin` is prepended
/// separately by callers since its value (the configured admin
/// origin) is per-request.
pub const CORS_FIXED_HEADERS = [_]RespHeaderPair{
    .{ .name = "access-control-allow-credentials", .value = "true" },
    .{ .name = "vary", .value = "origin" },
    .{ .name = "access-control-expose-headers", .value = "content-type" },
};

/// Extra CORS headers emitted only on OPTIONS preflight responses.
pub const CORS_PREFLIGHT_HEADERS = [_]RespHeaderPair{
    .{ .name = "access-control-allow-methods", .value = "GET, POST, DELETE, OPTIONS" },
    .{ .name = "access-control-allow-headers", .value = "authorization, content-type" },
    .{ .name = "access-control-max-age", .value = "600" },
};

/// Pack a flat list of header pairs into an `h2.RespHeaders`,
/// allocating one combined buffer for the field array + name/value
/// bytes so the h2 writer can free everything in one call. Returns an
/// empty (null-fields) header set when `pairs` is empty, saving an
/// allocation on the same-origin user-traffic path.
pub fn packRespHeaders(
    allocator: std.mem.Allocator,
    pairs: []const RespHeaderPair,
) !h2.RespHeaders {
    if (pairs.len == 0) return .{ .fields = null, .count = 0 };

    const fields_size = pairs.len * @sizeOf(h2.HeaderField);
    var strbuf_size: usize = 0;
    for (pairs) |p| strbuf_size += p.name.len + p.value.len;

    const total = fields_size + strbuf_size;
    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);

    const fields_ptr: [*]h2.HeaderField = @ptrCast(@alignCast(buf.ptr));
    var off: usize = fields_size;
    for (pairs, 0..) |p, i| {
        const name_start = off;
        @memcpy(buf[off .. off + p.name.len], p.name);
        off += p.name.len;
        const value_start = off;
        @memcpy(buf[off .. off + p.value.len], p.value);
        off += p.value.len;
        fields_ptr[i] = .{
            .name = buf[name_start..].ptr,
            .name_len = @intCast(p.name.len),
            .value = buf[value_start..].ptr,
            .value_len = @intCast(p.value.len),
        };
    }

    return .{
        .fields = fields_ptr,
        .count = @intCast(pairs.len),
        ._buf = buf.ptr,
        ._buf_len = @intCast(buf.len),
    };
}

/// Append the standard CORS envelope (origin + 3 fixed headers, plus 3
/// preflight headers when `preflight` is true) to `pairs` starting at
/// `n.*`. No-op when `cors_origin` is null. Caller must size `pairs`
/// for at least 7 additional entries.
pub fn appendCorsHeaders(
    pairs: []RespHeaderPair,
    n: *usize,
    cors_origin: ?[]const u8,
    preflight: bool,
) void {
    const origin = cors_origin orelse return;
    pairs[n.*] = .{ .name = "access-control-allow-origin", .value = origin };
    n.* += 1;
    for (CORS_FIXED_HEADERS) |hdr| {
        pairs[n.*] = hdr;
        n.* += 1;
    }
    if (preflight) for (CORS_PREFLIGHT_HEADERS) |hdr| {
        pairs[n.*] = hdr;
        n.* += 1;
    };
}

pub fn buildSystemRespHeaders(
    allocator: std.mem.Allocator,
    cors_origin: ?[]const u8,
    preflight: bool,
    content_type: ?[]const u8,
) !h2.RespHeaders {
    var pairs: [8]RespHeaderPair = undefined;
    var n: usize = 0;
    appendCorsHeaders(&pairs, &n, cors_origin, preflight);
    if (content_type) |ct| {
        pairs[n] = .{ .name = "content-type", .value = ct };
        n += 1;
    }
    return packRespHeaders(allocator, pairs[0..n]);
}

/// Assemble a handler-response `RespHeaders` carrying optional CORS
/// (admin host only), an optional platform-managed `set-cookie`
/// (currently the `__Host-rove_sid` mint from session.zig), one
/// `set-cookie` per `set_cookies` entry the handler pushed, and any
/// handler-defined custom headers. All inputs have already been
/// sanitized by the dispatcher (or constructed locally for the
/// platform cookie).
pub fn buildHandlerRespHeaders(
    allocator: std.mem.Allocator,
    cors_origin: ?[]const u8,
    platform_set_cookie: ?[]const u8,
    set_cookies: []const []const u8,
    content_type: ?[]const u8,
    custom_headers: []const dispatcher_mod.ResponseHeader,
) !h2.RespHeaders {
    const cors_count: usize = if (cors_origin != null) 4 else 0;
    const ct_count: usize = if (content_type != null) 1 else 0;
    const platform_count: usize = if (platform_set_cookie != null) 1 else 0;
    const total = cors_count + ct_count + platform_count + set_cookies.len + custom_headers.len;
    if (total == 0) return .{ .fields = null, .count = 0 };

    const pairs = try allocator.alloc(RespHeaderPair, total);
    defer allocator.free(pairs);
    var n: usize = 0;
    appendCorsHeaders(pairs, &n, cors_origin, false);
    if (content_type) |ct| {
        pairs[n] = .{ .name = "content-type", .value = ct };
        n += 1;
    }
    if (platform_set_cookie) |pc| {
        pairs[n] = .{ .name = "set-cookie", .value = pc };
        n += 1;
    }
    for (set_cookies) |cookie| {
        pairs[n] = .{ .name = "set-cookie", .value = cookie };
        n += 1;
    }
    for (custom_headers) |hdr| {
        pairs[n] = .{ .name = hdr.name, .value = hdr.value };
        n += 1;
    }
    return packRespHeaders(allocator, pairs[0..n]);
}

// ── Response setters ──────────────────────────────────────────────────

/// Stamp the six request_out components of a complete response and
/// move the entity into response_in. Consolidates the ritual that
/// every canned-response setter needs.
pub fn finalizeResponse(
    server: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status_code: u16,
    hdrs: h2.RespHeaders,
    body_ptr: ?[*]u8,
    body_len: u32,
) !void {
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status_code });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, hdrs);
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = body_ptr, .len = body_len });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

/// Overwrite an entity in `request_out` with a 503 body. Used when a
/// raft propose fails before the entity gets parked. Frees any body
/// the handler wrote before stamping the new one. Does NOT move into
/// response_in — caller orchestrates that.
pub fn overwriteWith503(
    server: anytype,
    ent: rove.Entity,
    allocator: std.mem.Allocator,
    old_body_ptr: ?[*]u8,
    old_body_len: u32,
) !void {
    if (old_body_ptr) |p| allocator.free(p[0..old_body_len]);
    const body = try allocator.dupe(u8, "write replication failed\n");
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = 503 });
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = body.ptr,
        .len = @intCast(body.len),
    });
}

/// Overwrite a parked entity's response with a 503. Caller is
/// responsible for freeing the old body (done in `drainRaftPending`
/// where the column access lives).
pub fn overwrite503InPending(
    worker: anytype,
    ent: rove.Entity,
    allocator: std.mem.Allocator,
) !void {
    const body = try allocator.dupe(u8, "raft commit failed\n");
    try worker.reg.set(ent, &worker.raft_pending, h2.Status, .{ .code = 503 });
    try worker.reg.set(ent, &worker.raft_pending, h2.RespBody, .{
        .data = body.ptr,
        .len = @intCast(body.len),
    });
}

/// Write a canned `500 Internal Server Error` response onto an entity
/// and queue its move to `response_in`.
pub fn setErrorResponse(
    server: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
) !void {
    try finalizeResponse(server, ent, sid, sess, 500, .{ .fields = null, .count = 0 }, null, 0);
}

/// Write a canned status + body response, allocating an h2-owned copy
/// of `body`.
pub fn setSimpleResponse(
    server: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status_code: u16,
    body: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const copy = try allocator.dupe(u8, body);
    try finalizeResponse(
        server,
        ent,
        sid,
        sess,
        status_code,
        .{ .fields = null, .count = 0 },
        copy.ptr,
        @intCast(copy.len),
    );
}

/// Like `setSimpleResponse`, but stamps CORS response headers when
/// `cors_origin` is non-null and an optional `Content-Type`. Use in
/// the `/_system/*` branch so admin UI responses carry the right
/// headers without the caller hand-assembling `RespHeaders`.
pub fn setSystemResponse(
    server: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status_code: u16,
    body: []const u8,
    allocator: std.mem.Allocator,
    cors_origin: ?[]const u8,
    content_type: ?[]const u8,
) !void {
    const copy = try allocator.dupe(u8, body);
    const resp_hdrs = try buildSystemRespHeaders(allocator, cors_origin, false, content_type);
    try finalizeResponse(server, ent, sid, sess, status_code, resp_hdrs, copy.ptr, @intCast(copy.len));
}

/// Same as `setSystemResponse` but takes ownership of `body` (no
/// extra dupe). Frees on response completion via the same h2 path.
pub fn setSystemResponseOwned(
    server: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status_code: u16,
    body: []u8,
    allocator: std.mem.Allocator,
    cors_origin: ?[]const u8,
    content_type: ?[]const u8,
) !void {
    const resp_hdrs = try buildSystemRespHeaders(allocator, cors_origin, false, content_type);
    try finalizeResponse(server, ent, sid, sess, status_code, resp_hdrs, body.ptr, @intCast(body.len));
}

/// 429 response with a `Retry-After: <sec>` header. Body text mentions
/// the wait time so curl-style clients without header inspection still
/// get the hint.
pub fn setRateLimitedResponse(
    server: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    allocator: std.mem.Allocator,
    retry_after_sec: u32,
) !void {
    const body = try std.fmt.allocPrint(
        allocator,
        "rate limit exceeded, retry after {d}s\n",
        .{retry_after_sec},
    );
    const ra_str = try std.fmt.allocPrint(allocator, "{d}", .{retry_after_sec});
    defer allocator.free(ra_str);
    const hdrs = try packRespHeaders(allocator, &.{
        .{ .name = "retry-after", .value = ra_str },
    });
    try finalizeResponse(server, ent, sid, sess, 429, hdrs, body.ptr, @intCast(body.len));
}

// ── Static file dispatch ──────────────────────────────────────────────

/// Result of a static-file lookup/serve attempt. `miss` means the
/// caller should fall through to handler routing.
pub const StaticOutcome = union(enum) {
    served: u16,
    miss: void,
};

/// Try to serve `path` from the tenant's `_static/*` set. Returns the
/// status code if we took the response (200, 304, or 301 for trailing-
/// slash canonicalization) or `.miss` when nothing matched. Caller
/// gates on `method` being `GET` or `HEAD`. For `HEAD`, response
/// headers (content-type, etag, cache-control) match what `GET`
/// would emit; the body is omitted, per RFC 9110 §9.3.2.
pub fn tryServeStatic(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tc: anytype,
    method: []const u8,
    path: []const u8,
    rh: h2.ReqHeaders,
) !StaticOutcome {
    const is_head = std.mem.eql(u8, method, "HEAD");
    const qmark = std.mem.indexOfScalar(u8, path, '?');
    const path_no_q = if (qmark) |q| path[0..q] else path;
    if (path_no_q.len == 0 or path_no_q[0] != '/') return .miss;

    // Trailing-slash canonicalization: redirect `/foo/` → `/foo` (not
    // `/` itself). Applies on GET and HEAD; API clients using
    // trailing-slash conventions on POST/etc aren't redirected.
    if (path_no_q.len > 1 and path_no_q[path_no_q.len - 1] == '/') {
        var canon_buf: [files_mod.MAX_PATH_LEN + 16]u8 = undefined;
        var stripped: []const u8 = path_no_q;
        while (stripped.len > 1 and stripped[stripped.len - 1] == '/') {
            stripped = stripped[0 .. stripped.len - 1];
        }
        // Preserve the original query string on the redirect target.
        const loc = if (qmark) |q|
            std.fmt.bufPrint(&canon_buf, "{s}?{s}", .{ stripped, path[q + 1 ..] }) catch return .miss
        else
            stripped;
        try emitStaticRedirect(server, allocator, ent, sid, sess, loc);
        return .{ .served = 301 };
    }

    const rel = path_no_q[1..];

    var key_buf: [8 + files_mod.MAX_PATH_LEN + 16]u8 = undefined;
    if (rel.len == 0) {
        const key = std.fmt.bufPrint(&key_buf, "_static/index.html", .{}) catch return .miss;
        if (try serveStaticByKey(server, allocator, ent, sid, sess, tc, key, rh, is_head)) |st| {
            return .{ .served = st };
        }
        return .miss;
    }

    // Exact match: `_static/<rel>`.
    if (std.fmt.bufPrint(&key_buf, "_static/{s}", .{rel})) |k| {
        if (try serveStaticByKey(server, allocator, ent, sid, sess, tc, k, rh, is_head)) |st| {
            return .{ .served = st };
        }
    } else |_| {}

    // `.html` suffix: `_static/<rel>.html`.
    if (std.fmt.bufPrint(&key_buf, "_static/{s}.html", .{rel})) |k| {
        if (try serveStaticByKey(server, allocator, ent, sid, sess, tc, k, rh, is_head)) |st| {
            return .{ .served = st };
        }
    } else |_| {}

    // Directory index: `_static/<rel>/index.html`.
    if (std.fmt.bufPrint(&key_buf, "_static/{s}/index.html", .{rel})) |k| {
        if (try serveStaticByKey(server, allocator, ent, sid, sess, tc, k, rh, is_head)) |st| {
            return .{ .served = st };
        }
    } else |_| {}

    return .miss;
}

/// Return the status code if `key` is present and we wrote a response,
/// or null if the key isn't in the static map.
fn serveStaticByKey(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tc: anytype,
    key: []const u8,
    rh: h2.ReqHeaders,
    is_head: bool,
) !?u16 {
    const entry = tc.statics.get(key) orelse return null;

    // Build the strong ETag value (`"<hex>"`) once; shared by 200 and 304.
    var etag_buf: [files_mod.HASH_HEX_LEN + 2]u8 = undefined;
    etag_buf[0] = '"';
    @memcpy(etag_buf[1 .. 1 + files_mod.HASH_HEX_LEN], &entry.hash_hex);
    etag_buf[1 + files_mod.HASH_HEX_LEN] = '"';
    const etag = etag_buf[0..];

    // If-None-Match: a comma-separated list of quoted tags (or `*`).
    // Match = any one of them equals our etag.
    const inm = findHeader(rh, "if-none-match");
    if (inm != null and etagMatches(inm.?, etag)) {
        try emitStaticResponse(
            server,
            allocator,
            ent,
            sid,
            sess,
            304,
            "",
            "",
            etag,
        );
        return 304;
    }

    const bytes = tc.blob_backend.blobStore().get(&entry.hash_hex, allocator) catch |err| {
        std.log.warn(
            "rove-js: static blob fetch for {s} failed: {s}",
            .{ key, @errorName(err) },
        );
        return err;
    };
    // HEAD: emit the same headers GET would, but no body. Per RFC
    // 9110 §9.3.2 "the server SHOULD send the same header fields
    // in response to a HEAD request as it would have sent if the
    // request method had been GET". Browsers + curl handle absent
    // content-length on HTTP/2 fine (END_STREAM marks body end).
    if (is_head) {
        defer allocator.free(bytes);
        try emitStaticResponse(
            server,
            allocator,
            ent,
            sid,
            sess,
            200,
            "",
            entry.content_type,
            etag,
        );
        return 200;
    }
    try emitStaticResponse(
        server,
        allocator,
        ent,
        sid,
        sess,
        200,
        bytes,
        entry.content_type,
        etag,
    );
    return 200;
}

/// True if `inm` (If-None-Match header value) contains a tag equal to
/// `etag`. Handles comma-separated lists and the `*` wildcard.
pub fn etagMatches(inm: []const u8, etag: []const u8) bool {
    var rest = inm;
    while (rest.len > 0) {
        while (rest.len > 0 and (rest[0] == ' ' or rest[0] == ',' or rest[0] == '\t')) {
            rest = rest[1..];
        }
        if (rest.len == 0) break;
        if (rest[0] == '*') return true;
        // Find the next comma or end.
        const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
        var tag = rest[0..end];
        // Trim trailing whitespace.
        while (tag.len > 0 and (tag[tag.len - 1] == ' ' or tag[tag.len - 1] == '\t')) {
            tag = tag[0 .. tag.len - 1];
        }
        // Strip a weak prefix (`W/`) if present — for static we only
        // emit strong tags, but a client may be comparing weakly.
        if (tag.len >= 2 and tag[0] == 'W' and tag[1] == '/') tag = tag[2..];
        if (std.mem.eql(u8, tag, etag)) return true;
        rest = rest[end..];
        if (rest.len > 0) rest = rest[1..]; // skip the comma
    }
    return false;
}

/// Write a 200/304 static response. Body is duped into the response
/// entity (so caller's `bytes` can be freed by its allocator immediately
/// after). Passes an empty body for 304.
fn emitStaticResponse(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status_code: u16,
    body: []const u8,
    content_type: []const u8,
    etag: []const u8,
) !void {
    const hdrs = try buildStaticRespHeaders(allocator, content_type, etag);
    var body_ptr: ?[*]u8 = null;
    var body_len: u32 = 0;
    if (body.len > 0) {
        const copy = try allocator.dupe(u8, body);
        body_ptr = copy.ptr;
        body_len = @intCast(copy.len);
    }
    try finalizeResponse(server, ent, sid, sess, status_code, hdrs, body_ptr, body_len);
}

fn buildStaticRespHeaders(
    allocator: std.mem.Allocator,
    content_type: []const u8,
    etag: []const u8,
) !h2.RespHeaders {
    var pairs: [3]RespHeaderPair = undefined;
    var n: usize = 0;
    if (content_type.len > 0) {
        pairs[n] = .{ .name = "content-type", .value = content_type };
        n += 1;
    }
    pairs[n] = .{ .name = "etag", .value = etag };
    n += 1;
    pairs[n] = .{ .name = "cache-control", .value = "public, max-age=0, must-revalidate" };
    n += 1;
    return packRespHeaders(allocator, pairs[0..n]);
}

/// If the tenant has `_static/_404.html`, emit it as a 404 response
/// with its stored content-type (no ETag — error bodies shouldn't be
/// cached). Returns `true` when served, `false` when there's no such
/// static so the caller can fall back to the built-in text body.
pub fn serveConvention404(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tc: anytype,
) !bool {
    const entry = tc.statics.get("_static/_404.html") orelse return false;
    const bytes = tc.blob_backend.blobStore().get(&entry.hash_hex, allocator) catch |err| {
        std.log.warn("rove-js: _404.html blob fetch failed: {s}", .{@errorName(err)});
        return false;
    };

    const hdrs: h2.RespHeaders = if (entry.content_type.len == 0)
        .{ .fields = null, .count = 0 }
    else
        try packRespHeaders(allocator, &.{
            .{ .name = "content-type", .value = entry.content_type },
        });

    try finalizeResponse(server, ent, sid, sess, 404, hdrs, bytes.ptr, @intCast(bytes.len));
    return true;
}

/// Write a 301 redirect response. `location` is duped into the response
/// header buffer so the caller doesn't need to keep it alive.
fn emitStaticRedirect(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    location: []const u8,
) !void {
    const hdrs = try packRespHeaders(allocator, &.{
        .{ .name = "location", .value = location },
    });
    try finalizeResponse(server, ent, sid, sess, 301, hdrs, null, 0);
}

// ── Tests ─────────────────────────────────────────────────────────────

test "etagMatches: single tag" {
    try std.testing.expect(etagMatches("\"abc\"", "\"abc\""));
    try std.testing.expect(!etagMatches("\"abc\"", "\"xyz\""));
}

test "etagMatches: weak prefix stripped" {
    try std.testing.expect(etagMatches("W/\"abc\"", "\"abc\""));
}

test "etagMatches: comma list" {
    try std.testing.expect(etagMatches("\"xyz\", \"abc\", \"qqq\"", "\"abc\""));
    try std.testing.expect(!etagMatches("\"xyz\", \"qqq\"", "\"abc\""));
}

test "etagMatches: wildcard" {
    try std.testing.expect(etagMatches("*", "\"anything\""));
    try std.testing.expect(etagMatches("\"a\", *", "\"b\""));
}

test "etagMatches: empty or whitespace only" {
    try std.testing.expect(!etagMatches("", "\"abc\""));
    try std.testing.expect(!etagMatches("   ", "\"abc\""));
}
