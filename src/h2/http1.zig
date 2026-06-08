//! HTTP/1.1 codec for the rove-h2 edge listener (docs/v2-edge-http1-ingress.md).
//!
//! Phase 1: the pure, I/O-free parser + serializer. `parseHead` turns an
//! accumulated request buffer into a `Head` (request line + headers + the body
//! framing it implies); `writeResponse` serializes a status + headers + body
//! into HTTP/1.1 bytes. No sockets, no entities, no allocation in the parser —
//! Phase 2 wires this into `root.zig`'s connection / request-entity plumbing.
//!
//! Scope (per the design doc): request/response with `Content-Length` bodies +
//! keep-alive. Chunked transfer-encoding is detected (so Phase 2 can 411/handle
//! it) but not decoded here yet (Phase 4). No pipelining.

const std = @import("std");

/// Bounds — coherent with the gap #1 body cap philosophy: refuse to buffer an
/// unbounded request head. (The body cap is enforced separately, by plan.)
pub const MAX_HEAD_BYTES: usize = 64 * 1024;
pub const MAX_HEADERS: usize = 100;

pub const Header = struct {
    /// Borrowed from the input buffer. Name is NOT lowercased here (HTTP/1
    /// names are case-insensitive); Phase 2 lowercases when it builds the
    /// h2-style `ReqHeaders` so downstream matching stays uniform.
    name: []const u8,
    value: []const u8,
};

/// A fully-parsed request head. All slices borrow from the buffer passed to
/// `parseHead`; valid only while that buffer lives.
pub const Head = struct {
    method: []const u8,
    /// The request-target (origin-form `/path?query`), used verbatim as `:path`.
    target: []const u8,
    /// Minor version: 1 for HTTP/1.1, 0 for HTTP/1.0.
    minor: u8,
    headers: []const Header,
    /// `Host:` value (→ `:authority`), or null if absent (a hard error for
    /// HTTP/1.1, which the caller surfaces as 400).
    host: ?[]const u8,
    /// `Content-Length`, or null if absent (⇒ no body, unless `chunked`).
    content_length: ?usize,
    /// `Transfer-Encoding: chunked` present (Phase 4 decodes it; until then the
    /// caller 411s).
    chunked: bool,
    /// Effective connection persistence (HTTP/1.1 keep-alive default unless
    /// `Connection: close`; HTTP/1.0 close default unless `Connection: keep-alive`).
    keep_alive: bool,
    /// Bytes consumed by the head (through the terminating CRLFCRLF); the body
    /// begins at `buf[head_len..]`.
    head_len: usize,
};

pub const ParseError = error{
    /// The head exceeded `MAX_HEAD_BYTES` (or too many headers) — 431/400.
    HeadTooLarge,
    /// Malformed request line / header — 400.
    Malformed,
    /// Not HTTP/1.x (e.g. an HTTP/2 preface) — the caller routes elsewhere.
    NotHttp1,
};

pub const ParseResult = union(enum) {
    /// The buffer doesn't yet contain a full head (no CRLFCRLF); read more.
    need_more,
    /// A complete head; storage in `headers_out` is filled to `head.headers`.
    head: Head,
};

/// Try to parse a request head from `buf`. Header storage is written into
/// `headers_out` (caller-owned, e.g. a `[MAX_HEADERS]Header` on the stack); the
/// returned `Head.headers` slices into it. Returns `.need_more` until the head
/// is complete. Does not allocate.
pub fn parseHead(buf: []const u8, headers_out: []Header) ParseError!ParseResult {
    const term = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse {
        if (buf.len > MAX_HEAD_BYTES) return ParseError.HeadTooLarge;
        return .need_more;
    };
    const head_bytes = buf[0 .. term + 4];
    if (head_bytes.len > MAX_HEAD_BYTES) return ParseError.HeadTooLarge;

    var lines = std.mem.splitSequence(u8, buf[0..term], "\r\n");

    // Request line: METHOD SP target SP HTTP/1.x
    const req_line = lines.next() orelse return ParseError.Malformed;
    var rl = std.mem.tokenizeScalar(u8, req_line, ' ');
    const method = rl.next() orelse return ParseError.Malformed;
    const target = rl.next() orelse return ParseError.Malformed;
    const version = rl.next() orelse return ParseError.Malformed;
    if (rl.next() != null) return ParseError.Malformed; // trailing junk
    if (!std.mem.startsWith(u8, version, "HTTP/1.")) return ParseError.NotHttp1;
    const minor: u8 = switch (version["HTTP/1.".len..].len) {
        1 => switch (version["HTTP/1.".len]) {
            '0' => 0,
            '1' => 1,
            else => return ParseError.Malformed,
        },
        else => return ParseError.Malformed,
    };
    if (method.len == 0 or target.len == 0) return ParseError.Malformed;

    var n: usize = 0;
    var host: ?[]const u8 = null;
    var content_length: ?usize = null;
    var chunked = false;
    var conn_close = false;
    var conn_keep_alive = false;

    while (lines.next()) |line| {
        if (line.len == 0) continue; // tolerate a stray blank
        if (n >= headers_out.len or n >= MAX_HEADERS) return ParseError.HeadTooLarge;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return ParseError.Malformed;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (name.len == 0) return ParseError.Malformed;
        headers_out[n] = .{ .name = name, .value = value };
        n += 1;

        if (std.ascii.eqlIgnoreCase(name, "host")) {
            host = value;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return ParseError.Malformed;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            // Last token decides; we only care whether chunked is present.
            if (std.ascii.indexOfIgnoreCase(value, "chunked") != null) chunked = true;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (std.ascii.indexOfIgnoreCase(value, "close") != null) conn_close = true;
            if (std.ascii.indexOfIgnoreCase(value, "keep-alive") != null) conn_keep_alive = true;
        }
    }

    const keep_alive = if (minor >= 1) !conn_close else conn_keep_alive;

    return .{ .head = .{
        .method = method,
        .target = target,
        .minor = minor,
        .headers = headers_out[0..n],
        .host = host,
        .content_length = content_length,
        .chunked = chunked,
        .keep_alive = keep_alive,
        .head_len = term + 4,
    } };
}

/// A response header to emit. Hop-by-hop framing headers
/// (`Content-Length` / `Connection` / `Transfer-Encoding`) are set by the
/// serializer, so callers must NOT include them here.
pub const RespHeader = struct { name: []const u8, value: []const u8 };

/// Serialize an HTTP/1.1 response into `out`. Sets `Content-Length` from
/// `body.len` and `Connection` from `keep_alive`. Caller owns `out`.
pub fn writeResponse(
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    status: u16,
    headers: []const RespHeader,
    body: []const u8,
    keep_alive: bool,
) !void {
    var lb: [4]u8 = undefined;
    const code = std.fmt.bufPrint(&lb, "{d}", .{status}) catch unreachable;
    try out.appendSlice(a, "HTTP/1.1 ");
    try out.appendSlice(a, code);
    try out.append(a, ' ');
    try out.appendSlice(a, reasonPhrase(status));
    try out.appendSlice(a, "\r\n");
    for (headers) |h| {
        // Skip framing headers a caller shouldn't set — we own them.
        if (std.ascii.eqlIgnoreCase(h.name, "content-length") or
            std.ascii.eqlIgnoreCase(h.name, "connection") or
            std.ascii.eqlIgnoreCase(h.name, "transfer-encoding")) continue;
        try out.appendSlice(a, h.name);
        try out.appendSlice(a, ": ");
        try out.appendSlice(a, h.value);
        try out.appendSlice(a, "\r\n");
    }
    var clb: [20]u8 = undefined;
    const cl = std.fmt.bufPrint(&clb, "{d}", .{body.len}) catch unreachable;
    try out.appendSlice(a, "Content-Length: ");
    try out.appendSlice(a, cl);
    try out.appendSlice(a, "\r\nConnection: ");
    try out.appendSlice(a, if (keep_alive) "keep-alive" else "close");
    try out.appendSlice(a, "\r\n\r\n");
    try out.appendSlice(a, body);
}

/// A minimal status→reason map. Clients ignore the phrase, so unknown codes get
/// a generic class phrase rather than a table of every code.
pub fn reasonPhrase(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        411 => "Length Required",
        413 => "Payload Too Large",
        421 => "Misdirected Request",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => switch (status / 100) {
            1 => "Informational",
            2 => "OK",
            3 => "Redirect",
            4 => "Client Error",
            else => "Server Error",
        },
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn parse(buf: []const u8, store: []Header) ParseError!ParseResult {
    return parseHead(buf, store);
}

test "http1: parse a simple GET" {
    var store: [MAX_HEADERS]Header = undefined;
    const req = "GET /path?q=1 HTTP/1.1\r\nHost: acme.com\r\nAccept: */*\r\n\r\n";
    const r = try parse(req, &store);
    const h = r.head;
    try testing.expectEqualStrings("GET", h.method);
    try testing.expectEqualStrings("/path?q=1", h.target);
    try testing.expectEqual(@as(u8, 1), h.minor);
    try testing.expectEqualStrings("acme.com", h.host.?);
    try testing.expect(h.content_length == null);
    try testing.expect(!h.chunked);
    try testing.expect(h.keep_alive); // 1.1 default
    try testing.expectEqual(req.len, h.head_len);
    try testing.expectEqual(@as(usize, 2), h.headers.len);
}

test "http1: POST with content-length frames the body" {
    var store: [MAX_HEADERS]Header = undefined;
    const req = "POST /hook HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello";
    const r = try parse(req, &store);
    const h = r.head;
    try testing.expectEqualStrings("POST", h.method);
    try testing.expectEqual(@as(usize, 5), h.content_length.?);
    // body begins right after the head.
    try testing.expectEqualStrings("hello", req[h.head_len..]);
}

test "http1: partial head → need_more" {
    var store: [MAX_HEADERS]Header = undefined;
    const r = try parse("GET / HTTP/1.1\r\nHost: h\r\n", &store);
    try testing.expect(r == .need_more);
}

test "http1: keep-alive semantics by version + Connection" {
    var store: [MAX_HEADERS]Header = undefined;
    {
        const r = try parse("GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n", &store);
        try testing.expect(!r.head.keep_alive);
    }
    {
        const r = try parse("GET / HTTP/1.0\r\nHost: h\r\n\r\n", &store);
        try testing.expect(!r.head.keep_alive); // 1.0 default close
    }
    {
        const r = try parse("GET / HTTP/1.0\r\nHost: h\r\nConnection: keep-alive\r\n\r\n", &store);
        try testing.expect(r.head.keep_alive);
    }
}

test "http1: chunked detected" {
    var store: [MAX_HEADERS]Header = undefined;
    const r = try parse("POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n", &store);
    try testing.expect(r.head.chunked);
}

test "http1: h2 preface is NotHttp1" {
    var store: [MAX_HEADERS]Header = undefined;
    try testing.expectError(ParseError.NotHttp1, parse("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", &store));
}

test "http1: malformed request line" {
    var store: [MAX_HEADERS]Header = undefined;
    try testing.expectError(ParseError.Malformed, parse("GET\r\nHost: h\r\n\r\n", &store));
    try testing.expectError(ParseError.Malformed, parse("GET / HTTP/1.1 extra\r\nHost: h\r\n\r\n", &store));
}

test "http1: serialize a response (framing headers owned by serializer)" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeResponse(&out, a, 200, &.{
        .{ .name = "Content-Type", .value = "text/plain" },
        .{ .name = "Content-Length", .value = "999" }, // must be ignored
    }, "hi", true);
    const s = out.items;
    try testing.expect(std.mem.startsWith(u8, s, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, s, "Content-Type: text/plain\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Content-Length: 2\r\n") != null); // body len, not 999
    try testing.expect(std.mem.indexOf(u8, s, "Content-Length: 999") == null);
    try testing.expect(std.mem.indexOf(u8, s, "Connection: keep-alive\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, s, "\r\n\r\nhi"));
}

test "http1: serialize close + unknown status reason class" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeResponse(&out, a, 599, &.{}, "", false);
    try testing.expect(std.mem.startsWith(u8, out.items, "HTTP/1.1 599 Server Error\r\n"));
    try testing.expect(std.mem.indexOf(u8, out.items, "Connection: close\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "Content-Length: 0\r\n") != null);
}
