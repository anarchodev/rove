//! Response building — turning the handler's JS return value + the
//! ambient `response` global into owned response bytes/metadata.
//!
//! Extracted from `dispatcher.zig`. Pure JS→Zig conversion + header /
//! cookie vetting; no `Dispatcher` state, no `PendingResponse` (the
//! caller passes the out-params). The module loader + the streaming
//! finalization stay in `dispatcher.zig`.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;

const globals = @import("globals.zig");
const reserved_headers = @import("reserved_headers.zig");
const request_mod = @import("request.zig");
const ResponseHeader = request_mod.ResponseHeader;

pub const Unwrapped = struct {
    val: c.JSValue,
    rejected: bool,
    /// Caller is responsible for freeing `val` iff this is true (the
    /// promise-fulfilled path gives us a new reference).
    owns: bool,
};

pub fn unwrapPromise(ctx: *c.JSContext, v: c.JSValue) Unwrapped {
    const st = c.JS_PromiseState(ctx, v);
    if (st == c.JS_PROMISE_FULFILLED) {
        const r = c.JS_PromiseResult(ctx, v);
        return .{ .val = r, .rejected = false, .owns = true };
    }
    if (st == c.JS_PROMISE_REJECTED) {
        const r = c.JS_PromiseResult(ctx, v);
        return .{ .val = r, .rejected = true, .owns = true };
    }
    // Not a promise, or still pending (shouldn't happen after pumpJobs).
    return .{ .val = v, .rejected = false, .owns = false };
}

/// Convert the handler's return value to bytes:
///   - string       → raw string (no JSON quoting); `is_json_out` = false
///   - undefined/null → empty body; `is_json_out` = false
///   - anything else → `JSON.stringify(ret)`; `is_json_out` = true
pub fn bodyFromReturn(
    allocator: std.mem.Allocator,
    ctx: *c.JSContext,
    ret: c.JSValue,
    body_out: *[]u8,
    is_json_out: *bool,
) error{OutOfMemory}!void {
    is_json_out.* = false;
    if (c.JS_IsUndefined(ret) or c.JS_IsNull(ret)) return;
    if (c.JS_IsString(ret)) {
        body_out.* = jsValueToOwned(allocator, ctx, ret) catch return error.OutOfMemory;
        return;
    }
    // JSON.stringify via the C API.
    const json = c.JS_JSONStringify(ctx, ret, globals.js_undefined, globals.js_undefined);
    defer c.JS_FreeValue(ctx, json);
    if (c.JS_IsException(json) or c.JS_IsUndefined(json)) return;
    body_out.* = jsValueToOwned(allocator, ctx, json) catch return error.OutOfMemory;
    is_json_out.* = true;
}

/// Pull status + cookies + custom headers off the ambient `response`
/// global. Body is NOT read from here — it always comes from the
/// return value.
///
/// - `response.status` → `status_out`
/// - `response.cookies` (array of strings) → `cookies_out`, each
///   sanitized via `sanitizeSetCookie`
/// - `response.headers` (object, string→string) → `headers_out`,
///   filtered to reject pseudo-headers (`:xxx`), hop-by-hop names,
///   and `set-cookie` (cookies go through the dedicated array so
///   sanitization fires). Names are lowercased to match HTTP/2.
pub fn extractResponseMetadata(
    allocator: std.mem.Allocator,
    ctx: *c.JSContext,
    status_out: *i32,
    cookies_out: *std.ArrayList([]u8),
    headers_out: *std.ArrayList(ResponseHeader),
) error{OutOfMemory}!void {
    const global_obj = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global_obj);
    const resp_val = c.JS_GetPropertyStr(ctx, global_obj, "response");
    defer c.JS_FreeValue(ctx, resp_val);
    if (c.JS_IsUndefined(resp_val) or c.JS_IsNull(resp_val)) return;

    const status_val = c.JS_GetPropertyStr(ctx, resp_val, "status");
    defer c.JS_FreeValue(ctx, status_val);
    if (!c.JS_IsUndefined(status_val) and !c.JS_IsNull(status_val)) {
        _ = c.JS_ToInt32(ctx, status_out, status_val);
    }

    // ── response.cookies ────────────────────────────────────────
    const cookies_val = c.JS_GetPropertyStr(ctx, resp_val, "cookies");
    defer c.JS_FreeValue(ctx, cookies_val);
    if (!c.JS_IsUndefined(cookies_val) and !c.JS_IsNull(cookies_val) and c.JS_IsArray(cookies_val)) {
        const len_val = c.JS_GetPropertyStr(ctx, cookies_val, "length");
        defer c.JS_FreeValue(ctx, len_val);
        var n: u32 = 0;
        _ = c.JS_ToUint32(ctx, &n, len_val);
        // Hard cap — a pathological handler pushing thousands of
        // cookies would blow up the HPACK table on every proxy hop.
        const cap: u32 = @min(n, 32);

        var i: u32 = 0;
        while (i < cap) : (i += 1) {
            const elem = c.JS_GetPropertyUint32(ctx, cookies_val, i);
            defer c.JS_FreeValue(ctx, elem);
            if (!c.JS_IsString(elem)) continue;
            var raw_len: usize = 0;
            const cstr = c.JS_ToCStringLen(ctx, &raw_len, elem);
            if (cstr == null) continue;
            defer c.JS_FreeCString(ctx, cstr);
            if (raw_len == 0) continue;
            const raw = @as([*]const u8, @ptrCast(cstr))[0..raw_len];
            const sanitized = try sanitizeSetCookie(allocator, raw);
            if (sanitized.len == 0) {
                allocator.free(sanitized);
                continue;
            }
            cookies_out.append(allocator, sanitized) catch |err| {
                allocator.free(sanitized);
                return err;
            };
        }
    }

    // ── response.headers ────────────────────────────────────────
    //
    // Object keys become header names (lowercased); string values
    // become header values. Disallowed names are silently dropped —
    // handler bugs shouldn't 500 the request. Hard cap 32 for the
    // same HPACK reason as cookies.
    const headers_val = c.JS_GetPropertyStr(ctx, resp_val, "headers");
    defer c.JS_FreeValue(ctx, headers_val);
    if (c.JS_IsUndefined(headers_val) or c.JS_IsNull(headers_val) or !c.JS_IsObject(headers_val)) return;

    var prop_enum: [*c]c.JSPropertyEnum = null;
    var prop_count: u32 = 0;
    const flags: c_int = c.JS_GPN_STRING_MASK | c.JS_GPN_ENUM_ONLY;
    if (c.JS_GetOwnPropertyNames(ctx, &prop_enum, &prop_count, headers_val, flags) < 0) return;
    defer c.js_free(ctx, prop_enum);

    const hdr_cap: u32 = @min(prop_count, 32);
    var hi: u32 = 0;
    while (hi < hdr_cap) : (hi += 1) {
        const atom = prop_enum[hi].atom;
        defer c.JS_FreeAtom(ctx, atom);
        const name_cstr = c.JS_AtomToCString(ctx, atom);
        if (name_cstr == null) continue;
        defer c.JS_FreeCString(ctx, name_cstr);
        const raw_name = std.mem.span(name_cstr);
        if (!isEmittableHeaderName(raw_name)) continue;

        const val = c.JS_GetProperty(ctx, headers_val, atom);
        defer c.JS_FreeValue(ctx, val);
        if (!c.JS_IsString(val)) continue;
        var val_len: usize = 0;
        const val_cstr = c.JS_ToCStringLen(ctx, &val_len, val);
        if (val_cstr == null) continue;
        defer c.JS_FreeCString(ctx, val_cstr);
        const raw_val = @as([*]const u8, @ptrCast(val_cstr))[0..val_len];
        if (!isCleanHeaderValue(raw_val)) continue;

        const name_owned = try allocator.alloc(u8, raw_name.len);
        errdefer allocator.free(name_owned);
        for (raw_name, 0..) |b, i| name_owned[i] = std.ascii.toLower(b);

        const val_owned = try allocator.alloc(u8, raw_val.len);
        errdefer allocator.free(val_owned);
        @memcpy(val_owned, raw_val);

        headers_out.append(allocator, .{ .name = name_owned, .value = val_owned }) catch |err| {
            allocator.free(name_owned);
            allocator.free(val_owned);
            return err;
        };
    }
}

/// Reject HTTP/2 pseudo-headers, hop-by-hop names, and the names
/// we manage ourselves (cookies go through a sanitized pipeline,
/// content-length is computed from the body). Case-insensitive.
fn isEmittableHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == ':') return false; // HTTP/2 pseudo-header
    for (name) |b| {
        // RFC 7230 token chars — be liberal, reject obvious garbage.
        if (b <= 0x20 or b == 0x7f) return false;
    }
    const reserved = [_][]const u8{
        "connection",      "transfer-encoding", "upgrade",
        "keep-alive",      "te",                "trailer",
        "proxy-authenticate", "proxy-authorization",
        "set-cookie",      "content-length",
    };
    for (reserved) |n| {
        if (std.ascii.eqlIgnoreCase(name, n)) return false;
    }
    // Platform-reserved internal header prefixes (`x-rewind-*`,
    // `x-rove-internal-*`) — a customer handler must not emit these
    // downstream. See `reserved_headers.zig`.
    if (reserved_headers.isReservedInternalHeader(name)) return false;
    return true;
}

test "isEmittableHeaderName rejects platform-reserved internal prefixes" {
    // Hop-by-hop / platform-managed (pre-existing).
    try testing.expect(!isEmittableHeaderName("set-cookie"));
    try testing.expect(!isEmittableHeaderName("content-length"));
    // Platform-reserved internal header prefixes — a handler can't emit them.
    try testing.expect(!isEmittableHeaderName("x-rewind-tenant"));
    try testing.expect(!isEmittableHeaderName("X-Rewind-Move-Secret"));
    try testing.expect(!isEmittableHeaderName("x-rove-internal-foo"));
    // Ordinary + the one customer-facing tracing header stay emittable.
    try testing.expect(isEmittableHeaderName("content-type"));
    try testing.expect(isEmittableHeaderName("x-custom"));
    try testing.expect(isEmittableHeaderName("x-rove-correlation-id"));
}

/// Header values must not contain CR / LF (header-injection) or NUL.
/// Everything else is opaque to us.
fn isCleanHeaderValue(value: []const u8) bool {
    for (value) |b| {
        if (b == '\r' or b == '\n' or b == 0) return false;
    }
    return true;
}

/// Return an owned copy of `raw` with any `Domain=...` attribute
/// stripped. Attribute matching is case-insensitive on the name and
/// tolerant of surrounding whitespace. Everything else (name=value,
/// Path, HttpOnly, Secure, SameSite, Max-Age, Expires, ...) is
/// preserved in order.
///
/// **Why**: a customer handler writing
/// `Set-Cookie: foo=bar; Domain=loop46.me` would push the cookie
/// onto the parent domain, where a different tenant's handler would
/// read it. The PSL entry at the browser level blocks this too, but
/// server-side stripping is the authoritative defense and the one
/// thing we control (PSL propagation can lag by browser version).
///
/// If `raw` is already Domain-free, the output is byte-identical.
pub fn sanitizeSetCookie(
    allocator: std.mem.Allocator,
    raw: []const u8,
) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // A Set-Cookie value is `name=value` followed by zero or more
    // `; attr[=val]` segments. Split on `;`, keep the first segment
    // verbatim, filter `Domain` from the rest.
    var it = std.mem.splitScalar(u8, raw, ';');
    var first = true;
    while (it.next()) |raw_seg| {
        const seg = std.mem.trim(u8, raw_seg, " \t");
        if (first) {
            // Preserve the cookie's name=value as-is (caller already
            // built it); trim only leading/trailing whitespace.
            try buf.appendSlice(allocator, seg);
            first = false;
            continue;
        }
        if (seg.len == 0) continue; // `foo=bar;;baz` → drop empty
        const eq = std.mem.indexOfScalar(u8, seg, '=');
        const attr_name = if (eq) |e| seg[0..e] else seg;
        const attr_trim = std.mem.trim(u8, attr_name, " \t");
        if (std.ascii.eqlIgnoreCase(attr_trim, "domain")) continue;
        try buf.appendSlice(allocator, "; ");
        try buf.appendSlice(allocator, seg);
    }
    return buf.toOwnedSlice(allocator);
}

pub fn jsValueToOwned(
    allocator: std.mem.Allocator,
    ctx: *c.JSContext,
    val: c.JSValue,
) error{ OutOfMemory, JsException }![]u8 {
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, val);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    const out = try allocator.alloc(u8, len);
    if (len > 0) @memcpy(out, @as([*]const u8, @ptrCast(cstr))[0..len]);
    return out;
}

const testing = std.testing;

test "sanitizeSetCookie strips Domain attribute" {
    const a = testing.allocator;

    // Basic: Domain stripped, other attrs preserved.
    {
        const out = try sanitizeSetCookie(a, "foo=bar; Path=/; Domain=loop46.me; HttpOnly");
        defer a.free(out);
        try testing.expectEqualStrings("foo=bar; Path=/; HttpOnly", out);
    }
    // Case-insensitive attribute name.
    {
        const out = try sanitizeSetCookie(a, "sid=abc; domain=foo.com; SameSite=Lax");
        defer a.free(out);
        try testing.expectEqualStrings("sid=abc; SameSite=Lax", out);
    }
    {
        const out = try sanitizeSetCookie(a, "sid=abc; DOMAIN=x.y.z; Secure");
        defer a.free(out);
        try testing.expectEqualStrings("sid=abc; Secure", out);
    }
    // No Domain = pass-through (only whitespace normalization).
    {
        const out = try sanitizeSetCookie(a, "a=b; Path=/; HttpOnly");
        defer a.free(out);
        try testing.expectEqualStrings("a=b; Path=/; HttpOnly", out);
    }
    // Leading/trailing spaces around attrs are trimmed on rewrite.
    {
        const out = try sanitizeSetCookie(a, "k=v;   Domain=foo  ;Path=/");
        defer a.free(out);
        try testing.expectEqualStrings("k=v; Path=/", out);
    }
    // Domain as the only attribute leaves only name=value.
    {
        const out = try sanitizeSetCookie(a, "k=v; Domain=loop46.me");
        defer a.free(out);
        try testing.expectEqualStrings("k=v", out);
    }
    // Flag-only attribute (no `=`) named "domain" still stripped.
    {
        const out = try sanitizeSetCookie(a, "k=v; Domain; HttpOnly");
        defer a.free(out);
        try testing.expectEqualStrings("k=v; HttpOnly", out);
    }
    // Value containing `=` (cookie value has embedded equals) preserved.
    {
        const out = try sanitizeSetCookie(a, "token=a=b=c; Domain=x; Secure");
        defer a.free(out);
        try testing.expectEqualStrings("token=a=b=c; Secure", out);
    }
    // Empty segment dropped without crashing.
    {
        const out = try sanitizeSetCookie(a, "k=v;;;Domain=x;;Path=/;;");
        defer a.free(out);
        try testing.expectEqualStrings("k=v; Path=/", out);
    }
}
