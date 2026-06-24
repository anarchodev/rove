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
const static_cache = @import("static_cache.zig");

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
    // Observability: every 5xx that flows through the canned-response
    // chokepoint gets a journald line (these otherwise only land on the
    // tenant tape via captureLog, invisible to an operator tailing the
    // worker journal — the empty-body deploy-500 hunt that motivated this).
    // body_len==0 is flagged because a bodyless 5xx tells the operator
    // nothing on its own.
    if (status_code >= 500) {
        std.log.warn("rove-5xx: status={d} body_len={d} (canned response on send path)", .{ status_code, body_len });
    }
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status_code });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, hdrs);
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = body_ptr, .len = body_len });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

/// Overwrite an entity in `request_out` with a `421 Misdirected
/// Request` body. Used when a raft propose fails before the entity
/// gets parked — the txn ROLLED BACK, nothing entered the log, so
/// re-executing the request elsewhere is safe. 421 is the
/// retry-SAFE signal the front door's leader discovery keys on
/// (`front: proxyToCluster`); the ambiguous post-propose failures
/// (`overwrite503InPending` — commit-wait fault/timeout, leadership
/// loss) stay 503 and are deliberately NOT retried by the front
/// door, because their entry may still commit under a new leader
/// and a blind retry double-executes the handler.
/// Frees any body the handler wrote before stamping the new one.
/// Does NOT move into response_in — caller orchestrates that.
pub fn overwriteWith421(
    server: anytype,
    ent: rove.Entity,
    allocator: std.mem.Allocator,
    old_body_ptr: ?[*]u8,
    old_body_len: u32,
) !void {
    if (old_body_ptr) |p| allocator.free(p[0..old_body_len]);
    const body = try allocator.dupe(u8, "write not accepted here (rolled back); retry against the cluster leader\n");
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = 421 });
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = body.ptr,
        .len = @intCast(body.len),
    });
}

/// Overwrite a parked entity's response with a 503. This is the
/// AMBIGUOUS failure (commit-wait fault/timeout, leadership-loss
/// sweep): the entry was proposed and may still commit under a new
/// leader, so this 503 must never be auto-retried by the platform —
/// see `overwriteWith421` for the retry-safe sibling. Caller is
/// responsible for freeing the old body (done in `drainRaftPending`
/// where the column access lives). Handler-cmds Phase 5: takes the
/// owning collection explicitly — the worker has three sibling
/// raft-pending collections now (response / cont / stream), each
/// reachable via its own pointer.
pub fn overwrite503InPending(
    worker: anytype,
    coll: anytype,
    ent: rove.Entity,
    allocator: std.mem.Allocator,
) !void {
    const body = try allocator.dupe(u8, "raft commit failed\n");
    try worker.reg.set(ent, coll, h2.Status, .{ .code = 503 });
    try worker.reg.set(ent, coll, h2.RespBody, .{
        .data = body.ptr,
        .len = @intCast(body.len),
    });
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

/// Like `setSystemResponse`, but stages the response components
/// on the entity WITHOUT moving it to `response_in`. The caller
/// then attaches a `RaftWait` component and moves the entity to
/// `worker.raft_pending`. Used by handlers that want the
/// dispatch / drain machinery to deliver the response only after
/// raft has committed the proposed writeset.
pub fn stageSystemResponse(
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
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status_code });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, resp_hdrs);
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = copy.ptr, .len = @intCast(copy.len) });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
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

/// 421 not-leader response, stamping `x-rewind-leader: <raft-id>` when
/// `leader_id` is non-zero (the front maps the id to a serving origin and
/// redirects there — critical for a non-replayable request, which can't be
/// re-aimed and would otherwise bounce 421→503 until a replayable request
/// re-learns the leader). `leader_id == 0` (unknown leader: mid-election /
/// no contact) omits the header — the front then forgets its stale hint and
/// re-scans. Shared by the customer dispatch gate and the move/v2-kv gates.
pub fn setNotLeaderResponse(
    server: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    allocator: std.mem.Allocator,
    body: []const u8,
    leader_id: u64,
) !void {
    const copy = try allocator.dupe(u8, body);
    var hdrs: h2.RespHeaders = .{ .fields = null, .count = 0 };
    if (leader_id != 0) {
        const id_str = try std.fmt.allocPrint(allocator, "{d}", .{leader_id});
        defer allocator.free(id_str);
        hdrs = try packRespHeaders(allocator, &.{.{ .name = "x-rewind-leader", .value = id_str }});
    }
    try finalizeResponse(server, ent, sid, sess, 421, hdrs, copy.ptr, @intCast(copy.len));
}

// ── Static file dispatch ──────────────────────────────────────────────

/// A static matched but its bytes aren't resident in the LRU — the caller
/// streams it from the tenant's file-blobs via the `__system/static` builtin
/// (engine-fired, hash injected). `content_type` borrows the snapshot entry
/// (valid for the pinned-snapshot request lifetime); the caller builds the
/// `etag` from `hash_hex`.
pub const StreamStatic = struct {
    hash_hex: [files_mod.HASH_HEX_LEN]u8,
    content_type: []const u8,
};

/// Result of a static-file lookup/serve attempt. `miss` means the
/// caller should fall through to handler routing; `stream_static` means
/// the bytes weren't in the LRU and must stream via `__system/static`.
pub const StaticOutcome = union(enum) {
    served: u16,
    stream_static: StreamStatic,
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
        if (try serveStaticByKey(server, allocator, ent, sid, sess, tc, key, rh, is_head)) |oc| {
            return oc;
        }
        return .miss;
    }

    // Exact match: `_static/<rel>`.
    if (std.fmt.bufPrint(&key_buf, "_static/{s}", .{rel})) |k| {
        if (try serveStaticByKey(server, allocator, ent, sid, sess, tc, k, rh, is_head)) |oc| {
            return oc;
        }
    } else |_| {}

    // `.html` suffix: `_static/<rel>.html`.
    if (std.fmt.bufPrint(&key_buf, "_static/{s}.html", .{rel})) |k| {
        if (try serveStaticByKey(server, allocator, ent, sid, sess, tc, k, rh, is_head)) |oc| {
            return oc;
        }
    } else |_| {}

    // Directory index: `_static/<rel>/index.html`.
    if (std.fmt.bufPrint(&key_buf, "_static/{s}/index.html", .{rel})) |k| {
        if (try serveStaticByKey(server, allocator, ent, sid, sess, tc, k, rh, is_head)) |oc| {
            return oc;
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
) !?StaticOutcome {
    const entry = tc.snap.statics.get(key) orelse return null;

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
        try emitStatic304(server, allocator, ent, sid, sess, etag);
        return .{ .served = 304 };
    }

    // EVERY static — incl. `text/html` — is served at its stable, MUTABLE
    // friendly path (no 302 to `/_assets/{hash}`): a redirect rebases a
    // document's origin AND an ES module's base URL, breaking relative
    // imports (`./api.js`). Stable mutable path ⇒ ETag + revalidate (the
    // etag short-circuits to a 304 above).
    //
    // LRU hit → serve the bytes inline (a pure memory copy under the cache
    // lock; the dispatch thread never blocks on storage). Identity encoding
    // (the LRU holds raw bytes); a CF edge / the browser caches via the ETag.
    if (static_cache.instance()) |sc| {
        if (try sc.getCopy(&entry.hash_hex, allocator)) |hit| {
            const body: []const u8 = if (is_head) &[_]u8{} else hit.bytes;
            // content-type from the manifest entry (authoritative) — the LRU
            // stores only bytes.
            try serveInline(server, allocator, ent, sid, sess, entry.content_type, etag, STATIC_REVALIDATE_CACHE_CONTROL, null, false, body, is_head);
            return .{ .served = 200 };
        }
    }

    // LRU miss (cold / evicted / oversized) → stream it from the tenant's
    // own file-blobs via the `__system/static` builtin. NEVER a redirect
    // (would rebase relative imports) and NEVER a blocking read here (the
    // builtin's fetch runs on the FetchPool thread).
    return .{ .stream_static = .{ .hash_hex = entry.hash_hex, .content_type = entry.content_type } };
}

/// Cache-Control for statics served at their stable, MUTABLE friendly path
/// (every kind now — HTML/JS/CSS/…): the path→bytes mapping changes per
/// deploy, so revalidate every load. The strong ETag (= content hash) makes
/// the revalidation a cheap 304 when unchanged, and lets a CF edge cache it.
const STATIC_REVALIDATE_CACHE_CONTROL = "public, max-age=0, must-revalidate";

/// Cache-Control for content-addressed `/_assets/{hash}` responses:
/// immutable, cache for a year, never revalidate.
const IMMUTABLE_CACHE_CONTROL = "public, max-age=31536000, immutable";

/// Emit a 200 with `body` (omitted for HEAD, but the headers match GET).
/// `body` is referenced, not copied — it must outlive the response (the
/// caller's per-request allocator owns it).
fn serveInline(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    content_type: []const u8,
    etag: []const u8,
    cache_control: []const u8,
    /// Non-null → emit `content-encoding` (e.g. "gzip" for the stored,
    /// pre-compressed HTML served verbatim).
    content_encoding: ?[]const u8,
    /// Emit `vary: accept-encoding` so a shared cache keys gzip vs.
    /// identity correctly (set for HTML, whichever encoding this response
    /// uses; not for single-representation `/_assets`).
    vary_accept_encoding: bool,
    body: []const u8,
    is_head: bool,
) !void {
    var pairs: [5]RespHeaderPair = undefined;
    var n: usize = 0;
    if (content_type.len != 0) {
        pairs[n] = .{ .name = "content-type", .value = content_type };
        n += 1;
    }
    pairs[n] = .{ .name = "etag", .value = etag };
    n += 1;
    pairs[n] = .{ .name = "cache-control", .value = cache_control };
    n += 1;
    if (content_encoding) |ce| {
        pairs[n] = .{ .name = "content-encoding", .value = ce };
        n += 1;
    }
    if (vary_accept_encoding) {
        pairs[n] = .{ .name = "vary", .value = "accept-encoding" };
        n += 1;
    }
    const hdrs = try packRespHeaders(allocator, pairs[0..n]);
    // The response path reads but never mutates the body; constCast is
    // safe (callers own immutable LRU copies / resident snapshot bytes).
    try finalizeResponse(
        server,
        ent,
        sid,
        sess,
        200,
        hdrs,
        if (is_head) null else @constCast(body.ptr),
        if (is_head) 0 else @intCast(body.len),
    );
}

/// Serve `/_assets/{hash}` — a content-addressed, immutable static. The
/// hash must belong to the pinned deployment (gate via `statics_by_hash`).
/// LRU hit → inline (non-blocking). LRU miss → 302 to a presigned S3 URL
/// (the browser fetches; the dispatch thread never does a blocking read).
/// Returns the status, or null if the path isn't a well-formed asset hash
/// (so the caller can fall through to normal routing).
pub fn serveAssetByHash(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tc: anytype,
    path: []const u8,
    rh: h2.ReqHeaders,
    is_head: bool,
) !?u16 {
    const prefix = "/_assets/";
    const qmark = std.mem.indexOfScalar(u8, path, '?');
    const path_no_q = if (qmark) |q| path[0..q] else path;
    if (!std.mem.startsWith(u8, path_no_q, prefix)) return null;
    const hash = path_no_q[prefix.len..];
    if (hash.len != files_mod.HASH_HEX_LEN) return null;
    for (hash) |c| if (!std.ascii.isHex(c)) return null;

    // Gate: only serve hashes this deployment actually references.
    const content_type = (tc.snap.statics_by_hash.get(hash)) orelse {
        try finalizeResponse(server, ent, sid, sess, 404, .{ .fields = null, .count = 0 }, null, 0);
        return 404;
    };

    // Strong ETag = the hash. Immutable, so revalidation is rare, but
    // honor If-None-Match anyway (a cheap 304).
    var etag_buf: [files_mod.HASH_HEX_LEN + 2]u8 = undefined;
    etag_buf[0] = '"';
    @memcpy(etag_buf[1 .. 1 + files_mod.HASH_HEX_LEN], hash[0..files_mod.HASH_HEX_LEN]);
    etag_buf[1 + files_mod.HASH_HEX_LEN] = '"';
    const etag = etag_buf[0..];
    const inm = findHeader(rh, "if-none-match");
    if (inm != null and etagMatches(inm.?, etag)) {
        try emitStatic304(server, allocator, ent, sid, sess, etag);
        return 304;
    }

    // LRU hit → serve the bytes inline (copied into the request
    // allocator, so the response owns them). Non-blocking.
    if (static_cache.instance()) |sc| {
        if (try sc.getCopy(hash, allocator)) |hit| {
            // content-type from the snapshot's statics_by_hash (the gate
            // above) — the LRU stores only bytes.
            try serveInline(server, allocator, ent, sid, sess, content_type, etag, IMMUTABLE_CACHE_CONTROL, null, false, hit.bytes, is_head);
            return 200;
        }
    }

    // LRU miss → 302 to a presigned S3 URL (browser fetches; the
    // dispatch thread never blocks on a read). Weaker (~1h) caching for
    // this one cold asset until it's prewarmed again.
    const presign_expires_secs: u32 = 3600;
    const url = (tc.slot.blob_backend.presignGet(
        hash[0..files_mod.HASH_HEX_LEN],
        presign_expires_secs,
        content_type,
        allocator,
    ) catch |err| {
        std.log.warn("rove-js: asset presign for {s} failed: {s}", .{ hash, @errorName(err) });
        return err;
    }) orelse {
        std.log.err("rove-js: asset presign for {s} returned null", .{hash});
        return error.PresignNotSupported;
    };
    defer allocator.free(url);
    try emitStaticRedirectWithEtag(server, allocator, ent, sid, sess, url, etag, presign_expires_secs);
    return 302;
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

/// Write a 304 Not Modified for a successful If-None-Match. ETag is
/// echoed so subsequent revalidations work; cache-control matches
/// today's static posture (revalidate every time, but the etag
/// short-circuits the body fetch). No content-type — RFC 9110 §15.4.5
/// "If a 304 response indicates an entity ... the response MUST NOT
/// include other than headers already listed".
fn emitStatic304(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    etag: []const u8,
) !void {
    const hdrs = try packRespHeaders(allocator, &.{
        .{ .name = "etag", .value = etag },
        .{ .name = "cache-control", .value = "public, max-age=0, must-revalidate" },
    });
    try finalizeResponse(server, ent, sid, sess, 304, hdrs, null, 0);
}

/// Write a 302 Found redirecting to a presigned S3 URL. The browser
/// follows the Location and fetches the bytes directly from S3.
/// Etag is echoed so the next request's If-None-Match still works
/// (the browser caches the redirect's headers alongside the
/// resolved body). `redirect_max_age` matches the signed URL's TTL
/// so cached redirects don't outlive their signature.
fn emitStaticRedirectWithEtag(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    location: []const u8,
    etag: []const u8,
    redirect_max_age: u32,
) !void {
    var cc_buf: [64]u8 = undefined;
    const cc = std.fmt.bufPrint(&cc_buf, "public, max-age={d}", .{redirect_max_age}) catch unreachable;
    const hdrs = try packRespHeaders(allocator, &.{
        .{ .name = "location", .value = location },
        .{ .name = "etag", .value = etag },
        .{ .name = "cache-control", .value = cc },
    });
    try finalizeResponse(server, ent, sid, sess, 302, hdrs, null, 0);
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
    const entry = tc.snap.statics.get("_static/_404.html") orelse return false;
    const bytes = tc.slot.blob_backend.blobStore().get(&entry.hash_hex, allocator) catch |err| {
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
