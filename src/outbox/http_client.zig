//! Outbound HTTP client for the webhook drainer.
//!
//! Wraps `std.http.Client` with an SSRF pre-check (see `ssrf.zig`)
//! and a bounded response body capture.
//!
//! Caveats (tracked for slice 3c hardening):
//! - `std.http.Client` re-resolves DNS internally, so the SSRF check is
//!   technically racy against a rebinding attack. We resolve + check
//!   first to catch the common case; full pinning needs a custom
//!   connector. Per PLAN §2.6 we also re-resolve on each retry, which
//!   bounds the window.
//! - Timeouts are best-effort via TCP keepalive / default socket opts.
//!   A genuinely stalled peer can block the drainer thread. Stricter
//!   enforcement lands alongside a multi-threaded drainer.
//! - TLS always on — we reject non-`https://` URLs outright. Customer
//!   webhook endpoints must use TLS.

const std = @import("std");
const ssrf = @import("ssrf.zig");

/// Cap on captured response body. PLAN §2.6 default. Anything past
/// this gets dropped and the response is flagged `truncated=true`.
pub const MAX_BODY_BYTES: usize = 256 * 1024;

/// **DEV-ONLY** escape hatch that accepts `http://` webhook URLs in
/// addition to `https://`. **Never set in production** — plaintext
/// delivery leaks request bodies on any intermediate hop. Paired
/// with `ssrf.dev_allow_loopback` so a smoke test can hit a local
/// echo server; both flip together under js-worker's
/// `--dev-webhook-unsafe` CLI flag.
pub var dev_allow_plaintext: bool = false;

pub const DeliverError = error{
    BlockedAddress,
    UnresolvableHost,
    InvalidUrl,
    InvalidMethod,
    HttpsRequired,
    Network,
    Tls,
    WriteFailed,
    ReadFailed,
    Timeout,
    OutOfMemory,
};

pub const Request = struct {
    url: []const u8,
    method: []const u8,
    /// Extra headers. `User-Agent`, `Content-Length`, `Host` are stamped
    /// by the client — don't set them here.
    headers: []const std.http.Header = &.{},
    body: []const u8 = "",
    /// Total wall-clock cap for the request. Not strictly enforced yet
    /// (see caveats in module doc). Still recorded so the drainer's
    /// retry logic can honor it in slice 3c.
    timeout_ms: u32 = 30_000,
};

pub const Response = struct {
    status: u16,
    body: []u8,
    truncated: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub fn deliver(allocator: std.mem.Allocator, req: Request) DeliverError!Response {
    const uri = std.Uri.parse(req.url) catch return DeliverError.InvalidUrl;
    const is_https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    const is_http = std.ascii.eqlIgnoreCase(uri.scheme, "http");
    if (!is_https and !(is_http and dev_allow_plaintext)) return DeliverError.HttpsRequired;
    const host = switch (uri.host orelse return DeliverError.InvalidUrl) {
        .raw => |h| h,
        .percent_encoded => |h| h,
    };
    const port: u16 = uri.port orelse (if (is_https) @as(u16, 443) else @as(u16, 80));

    // Pre-resolve + SSRF check. This isn't strictly atomic with the
    // client's own resolution below, but catches the common case and
    // the retry-time re-check narrows the window further.
    _ = ssrf.resolveSafe(allocator, host, port) catch |err| switch (err) {
        error.BlockedAddress => return DeliverError.BlockedAddress,
        error.EmptyHost => return DeliverError.InvalidUrl,
        error.OutOfMemory => return DeliverError.OutOfMemory,
        else => return DeliverError.UnresolvableHost,
    };

    const method = parseMethod(req.method) orelse return DeliverError.InvalidMethod;

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Response body capture — `std.Io.Writer` backed by an ArrayList,
    // bounded at MAX_BODY_BYTES. Anything past the cap is silently
    // dropped; `truncated=true` flags that.
    var body_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body_buf.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &body_buf);

    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .method = method,
        .payload = if (req.body.len > 0) req.body else null,
        .extra_headers = req.headers,
        .response_writer = &aw.writer,
        .redirect_behavior = @enumFromInt(3),
    }) catch |err| return mapFetchError(err);

    const body_owned = aw.toOwnedSlice() catch return DeliverError.OutOfMemory;
    const truncated = body_owned.len >= MAX_BODY_BYTES;
    const out_bytes = if (truncated) blk: {
        const shrunk = allocator.realloc(body_owned, MAX_BODY_BYTES) catch body_owned;
        break :blk shrunk;
    } else body_owned;

    return .{
        .status = @intFromEnum(result.status),
        .body = out_bytes,
        .truncated = truncated,
        .allocator = allocator,
    };
}

/// Collapse std.http.Client's wide error set down to our DeliverError.
/// OOM / read/write/tls get their own codes; everything else is
/// "network-ish" so the retry logic can treat it uniformly.
fn mapFetchError(err: anyerror) DeliverError {
    return switch (err) {
        error.OutOfMemory => DeliverError.OutOfMemory,
        error.WriteFailed => DeliverError.WriteFailed,
        error.ReadFailed => DeliverError.ReadFailed,
        error.TlsInitializationFailed, error.TlsFailure, error.TlsAlert => DeliverError.Tls,
        else => DeliverError.Network,
    };
}

fn parseMethod(s: []const u8) ?std.http.Method {
    if (std.ascii.eqlIgnoreCase(s, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(s, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(s, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(s, "PATCH")) return .PATCH;
    if (std.ascii.eqlIgnoreCase(s, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(s, "HEAD")) return .HEAD;
    if (std.ascii.eqlIgnoreCase(s, "OPTIONS")) return .OPTIONS;
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "deliver: rejects http:// URLs" {
    try testing.expectError(DeliverError.HttpsRequired, deliver(testing.allocator, .{
        .url = "http://example.com/",
        .method = "GET",
    }));
}

test "deliver: blocks loopback literal" {
    try testing.expectError(DeliverError.BlockedAddress, deliver(testing.allocator, .{
        .url = "https://127.0.0.1/",
        .method = "GET",
    }));
    try testing.expectError(DeliverError.BlockedAddress, deliver(testing.allocator, .{
        .url = "https://169.254.169.254/latest/meta-data/",
        .method = "GET",
    }));
}

test "deliver: rejects malformed URL" {
    try testing.expectError(DeliverError.InvalidUrl, deliver(testing.allocator, .{
        .url = "not a url",
        .method = "GET",
    }));
}
