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
    /// `Transfer-Encoding: chunked` present; the body is chunk-framed (no
    /// `Content-Length`) and decoded by `decodeChunked`.
    chunked: bool,
    /// `Expect: 100-continue` present — the client is waiting for a `100
    /// Continue` interim response before it sends the body.
    expect_continue: bool,
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
    var expect_continue = false;
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
        } else if (std.ascii.eqlIgnoreCase(name, "expect")) {
            if (std.ascii.indexOfIgnoreCase(value, "100-continue") != null) expect_continue = true;
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
        .expect_continue = expect_continue,
        .keep_alive = keep_alive,
        .head_len = term + 4,
    } };
}

// ── Chunked transfer-encoding decode ─────────────────────────────────────

pub const ChunkStatus = enum {
    /// The chunked body isn't complete yet — read more, then resume from the
    /// returned `consumed` offset (the start of the first not-yet-complete
    /// chunk). Bytes appended to `out` so far are kept across calls.
    need_more,
    /// The terminating zero-chunk (+ optional trailers) was consumed; `out`
    /// holds the assembled body and `consumed` is the total input bytes used.
    complete,
    /// Malformed chunk framing (bad size line, missing CRLF) — 400.
    malformed,
    /// The assembled body exceeded `max_body` — 413.
    too_large,
};

pub const ChunkResult = struct { status: ChunkStatus, consumed: usize = 0 };

/// Incrementally decode a chunked message body. `input` is the bytes after the
/// request head (starting at the first chunk-size line); `pos` is where to
/// resume (0 on the first call, the previous `.need_more` `consumed` after).
/// Fully-decoded chunk payloads are appended to `out` (caller keeps it across
/// calls, so consumed chunks are never re-scanned — O(n) total). Chunk
/// extensions (`;ext`) and trailers are tolerated and discarded.
pub fn decodeChunked(
    input: []const u8,
    pos: usize,
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    max_body: usize,
) ChunkResult {
    var i = pos;
    while (true) {
        const nl = std.mem.indexOfPos(u8, input, i, "\r\n") orelse
            return .{ .status = .need_more, .consumed = i };
        const size_line = input[i..nl];
        // A chunk size may carry `;chunk-ext` — only the hex prefix matters.
        const hex_end = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
        const hex = std.mem.trim(u8, size_line[0..hex_end], " \t");
        if (hex.len == 0) return .{ .status = .malformed };
        const size = std.fmt.parseInt(usize, hex, 16) catch return .{ .status = .malformed };
        const data_start = nl + 2;

        if (size == 0) {
            // Last chunk: skip any trailer header lines up to the empty line
            // that terminates the message.
            var j = data_start;
            while (true) {
                const tnl = std.mem.indexOfPos(u8, input, j, "\r\n") orelse
                    return .{ .status = .need_more, .consumed = i };
                if (tnl == j) return .{ .status = .complete, .consumed = j + 2 };
                j = tnl + 2;
            }
        }

        // Need the chunk data plus its trailing CRLF before consuming it.
        if (data_start + size + 2 > input.len) return .{ .status = .need_more, .consumed = i };
        if (input[data_start + size] != '\r' or input[data_start + size + 1] != '\n')
            return .{ .status = .malformed };
        if (out.items.len + size > max_body) return .{ .status = .too_large };
        out.appendSlice(a, input[data_start .. data_start + size]) catch
            return .{ .status = .too_large };
        i = data_start + size + 2;
    }
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

// ── Chunked streaming response (SSE, ReadableStream, proxied stream) ──────
//
// A streaming response whose length isn't known up front: emit the head with
// `Transfer-Encoding: chunked` (no Content-Length), then each body piece as a
// chunk, then the zero-terminator. Unlike `writeResponse`, the connection stays
// open and keep-alive survives (chunked delimits the body).

/// The terminating zero-chunk that ends a chunked response body.
pub const CHUNK_TERMINATOR = "0\r\n\r\n";

/// Serialize the head of a chunked streaming response (status line + headers +
/// `Transfer-Encoding: chunked`, no body). Caller-set framing headers
/// (`Content-Length` / `Connection` / `Transfer-Encoding`) are dropped — the
/// serializer owns framing.
pub fn writeStreamHead(
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    status: u16,
    headers: []const RespHeader,
) !void {
    var lb: [4]u8 = undefined;
    const code = std.fmt.bufPrint(&lb, "{d}", .{status}) catch unreachable;
    try out.appendSlice(a, "HTTP/1.1 ");
    try out.appendSlice(a, code);
    try out.append(a, ' ');
    try out.appendSlice(a, reasonPhrase(status));
    try out.appendSlice(a, "\r\n");
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-length") or
            std.ascii.eqlIgnoreCase(h.name, "connection") or
            std.ascii.eqlIgnoreCase(h.name, "transfer-encoding")) continue;
        try out.appendSlice(a, h.name);
        try out.appendSlice(a, ": ");
        try out.appendSlice(a, h.value);
        try out.appendSlice(a, "\r\n");
    }
    try out.appendSlice(a, "Transfer-Encoding: chunked\r\n\r\n");
}

/// Serialize one non-empty chunk: `<hex-size>\r\n<data>\r\n`. (A zero-length
/// chunk would prematurely terminate the body — callers skip empty pieces and
/// end the stream with `CHUNK_TERMINATOR`.)
pub fn writeChunk(out: *std.ArrayList(u8), a: std.mem.Allocator, data: []const u8) !void {
    var hb: [16]u8 = undefined;
    const hex = std.fmt.bufPrint(&hb, "{x}", .{data.len}) catch unreachable;
    try out.appendSlice(a, hex);
    try out.appendSlice(a, "\r\n");
    try out.appendSlice(a, data);
    try out.appendSlice(a, "\r\n");
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
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
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

test "http1: Expect: 100-continue detected" {
    var store: [MAX_HEADERS]Header = undefined;
    const r = try parse("POST / HTTP/1.1\r\nHost: h\r\nExpect: 100-continue\r\nContent-Length: 3\r\n\r\nabc", &store);
    try testing.expect(r.head.expect_continue);
    const r2 = try parse("POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nabc", &store);
    try testing.expect(!r2.head.expect_continue);
}

test "http1: decodeChunked assembles a complete body" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    // "Wikipedia in\r\n\r\nchunks." classic example, two data chunks + zero.
    const body = "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n";
    const r = decodeChunked(body, 0, &out, a, 1 << 20);
    try testing.expectEqual(ChunkStatus.complete, r.status);
    try testing.expectEqual(body.len, r.consumed);
    try testing.expectEqualStrings("Wikipedia", out.items);
}

test "http1: decodeChunked resumes across partial reads (O(n), no re-scan)" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const full = "3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n";
    // First read: only the first chunk + part of the second size line.
    const r1 = decodeChunked(full[0..8], 0, &out, a, 1 << 20); // "3\r\nabc\r\n"
    try testing.expectEqual(ChunkStatus.need_more, r1.status);
    try testing.expectEqualStrings("abc", out.items);
    // Resume from where it stopped with the full buffer.
    const r2 = decodeChunked(full, r1.consumed, &out, a, 1 << 20);
    try testing.expectEqual(ChunkStatus.complete, r2.status);
    try testing.expectEqualStrings("abcdef", out.items);
    try testing.expectEqual(full.len, r2.consumed);
}

test "http1: decodeChunked tolerates chunk extensions + trailers" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const body = "4;name=value\r\nbody\r\n0\r\nX-Trailer: y\r\n\r\n";
    const r = decodeChunked(body, 0, &out, a, 1 << 20);
    try testing.expectEqual(ChunkStatus.complete, r.status);
    try testing.expectEqualStrings("body", out.items);
    try testing.expectEqual(body.len, r.consumed);
}

test "http1: decodeChunked enforces max_body (413)" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const body = "5\r\nhello\r\n0\r\n\r\n";
    const r = decodeChunked(body, 0, &out, a, 4); // body is 5 bytes, cap 4
    try testing.expectEqual(ChunkStatus.too_large, r.status);
}

test "http1: decodeChunked rejects a bad size line (400)" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const r = decodeChunked("zz\r\nabc\r\n0\r\n\r\n", 0, &out, a, 1 << 20);
    try testing.expectEqual(ChunkStatus.malformed, r.status);
}

test "http1: writeStreamHead emits chunked TE, no content-length" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeStreamHead(&out, a, 200, &.{
        .{ .name = "Content-Type", .value = "text/event-stream" },
        .{ .name = "Content-Length", .value = "5" }, // must be dropped
    });
    const s = out.items;
    try testing.expect(std.mem.startsWith(u8, s, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, s, "Content-Type: text/event-stream\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Transfer-Encoding: chunked\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Content-Length") == null);
    try testing.expect(std.mem.endsWith(u8, s, "\r\n\r\n"));
}

test "http1: writeChunk frames a piece, terminator ends the body" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeChunk(&out, a, "data: hi\n\n"); // 10 bytes → 0xa
    try out.appendSlice(a, CHUNK_TERMINATOR);
    try testing.expectEqualStrings("a\r\ndata: hi\n\n\r\n0\r\n\r\n", out.items);
    // Round-trips through the decoder.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    const r = decodeChunked(out.items, 0, &body, a, 1 << 20);
    try testing.expectEqual(ChunkStatus.complete, r.status);
    try testing.expectEqualStrings("data: hi\n\n", body.items);
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
