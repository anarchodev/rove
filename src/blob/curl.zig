//! Thin libcurl wrapper for the S3 blob + batch stores.
//!
//! Replaces `std.http.Client` for outbound S3 calls. We hit three
//! distinct stdlib bugs in 0.15.x — HEAD with response_writer
//! stalls 60s, HEAD without writes to a `@constCast` const and
//! segfaults under release-mode optimization, no application-level
//! timeouts so a stuck TCP socket parks the caller for the kernel
//! retransmit timer (~15 min) — and the stdlib HTTP API is moving
//! around enough version-to-version that we'd hit more. libcurl
//! has been doing this correctly for 25 years; the surface we need
//! is small (PUT, GET full, GET range, HEAD, DELETE, LIST as GET
//! with query) and SigV4 stays where it is — we hand libcurl
//! pre-signed headers.
//!
//! Each `Easy` owns one `CURL` handle. Reuse keeps TCP+TLS warm
//! across calls (curl honors HTTP keep-alive on its own); single
//! handle is NOT thread-safe so each owner needs its own. The S3
//! blob store + batch store keep one handle each, used from
//! whichever thread happens to be flushing — the worker side
//! serializes flushes through a single background thread already.

const std = @import("std");

const c = @cImport({
    @cInclude("curl/curl.h");
});

pub const Error = error{
    CurlInitFailed,
    CurlCallFailed,
    OutOfMemory,
};

pub const Method = enum {
    GET,
    PUT,
    POST,
    HEAD,
    DELETE,
};

/// HTTP version selector. Default `auto` lets libcurl pick: HTTP/1.1
/// for plain HTTP, ALPN-negotiated HTTP/2 (or fallback) for HTTPS.
/// `h2c_prior_knowledge` forces cleartext HTTP/2 — needed when
/// talking to a server that's h2-only on a plaintext port (like
/// `sse-server-standalone` running without TLS).
pub const HttpVersion = enum {
    auto,
    h2c_prior_knowledge,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Response = struct {
    status: u16,
    /// Response body bytes, owned by the caller's allocator. `null`
    /// for HEAD responses (libcurl drops the body, we never
    /// allocate). For other methods this is always non-null even on
    /// non-2xx — error bodies are useful for diagnostics.
    body: ?[]u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        if (self.body) |b| allocator.free(b);
        self.* = undefined;
    }
};

pub const Request = struct {
    method: Method,
    url: []const u8,
    headers: []const Header = &.{},
    /// Request body. Only meaningful for PUT / POST. For GET / HEAD
    /// / DELETE pass an empty slice.
    body: []const u8 = &.{},
    /// Optional `Range:` header value (e.g. `"bytes=0-1023"`). Set
    /// on GET when the caller wants a partial fetch.
    range: ?[]const u8 = null,
    /// Total per-call deadline. Counts handshake + send + recv.
    /// Default 15 s — generous enough for our largest PUT (~8 MB
    /// compressed log batch) at 1 MB/s minimum throughput plus
    /// handshake overhead, tight enough that a stuck connection
    /// fails fast and logs the warning instead of papering over a
    /// degraded link. The kernel's 15-minute TCP retransmit timer
    /// is now never reachable. Bench / smoke callers can override.
    timeout_ms: u32 = 15_000,
    /// Connect-only deadline. Caps how long we spend on DNS + TCP +
    /// TLS handshake before giving up. 5 s tolerates real-world
    /// latency without papering over a misconfigured endpoint.
    connect_timeout_ms: u32 = 5_000,
    /// HTTP version. `auto` (default) keeps the existing S3 behavior
    /// — libcurl picks based on URL + ALPN. Callers talking to an
    /// h2-only server on a plaintext port set `h2c_prior_knowledge`.
    http_version: HttpVersion = .auto,
    /// TLS peer verification. Default on. Smokes / dev clusters with
    /// self-signed certs (sse-server in the browser-in-the-loop
    /// smoke, for instance) flip this to false. Production must
    /// leave it on; a misconfigured CA bundle will surface as a
    /// connection error rather than silently MITM-able traffic.
    verify_tls: bool = true,
};

pub const Easy = struct {
    allocator: std.mem.Allocator,
    handle: *c.CURL,
    /// Buffer holding the most recent error message libcurl wrote
    /// via `CURLOPT_ERRORBUFFER`. Lives for the Easy's lifetime.
    err_buf: [c.CURL_ERROR_SIZE]u8 = std.mem.zeroes([c.CURL_ERROR_SIZE]u8),
    /// libcurl easy handles are NOT thread-safe — concurrent
    /// `curl_easy_perform` calls on the same handle return the
    /// "easy handle already used in multi handle" error and corrupt
    /// state. We have call sites where one Easy backs multiple
    /// threads (the standalone log-server's indexer poller + h2
    /// query thread share an S3BatchStore), so the handle goes
    /// behind a mutex. For single-threaded callers (the worker's
    /// background flusher) the mutex acquire is uncontested and
    /// adds nothing measurable.
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) Error!*Easy {
        const handle = c.curl_easy_init() orelse return Error.CurlInitFailed;
        errdefer c.curl_easy_cleanup(handle);

        const self = try allocator.create(Easy);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .handle = handle };

        // Hand libcurl our error buffer so its messages survive past
        // the perform() return.
        _ = c.curl_easy_setopt(handle, c.CURLOPT_ERRORBUFFER, &self.err_buf);
        // Don't follow redirects — S3 doesn't redirect on the API
        // path and a redirect from a malicious / proxied endpoint
        // shouldn't change which URL we signed.
        _ = c.curl_easy_setopt(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
        // Connection reuse — keep the TLS session warm.
        _ = c.curl_easy_setopt(handle, c.CURLOPT_TCP_KEEPALIVE, @as(c_long, 1));
        return self;
    }

    pub fn deinit(self: *Easy) void {
        c.curl_easy_cleanup(self.handle);
        const a = self.allocator;
        a.destroy(self);
    }

    /// Issue one request synchronously. The returned `Response.body`
    /// is allocator-owned (caller calls `Response.deinit`).
    pub fn request(self: *Easy, allocator: std.mem.Allocator, req: Request) Error!Response {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Reset per-call settings while keeping the underlying TCP
        // connection cache. Without this we'd inherit the previous
        // request's CUSTOMREQUEST / NOBODY / UPLOAD flags, which
        // breaks HEAD-after-GET cases.
        c.curl_easy_reset(self.handle);
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_ERRORBUFFER, &self.err_buf);
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_TCP_KEEPALIVE, @as(c_long, 1));

        // URL needs a NUL-terminated C string. Stack buffer is fine
        // for our paths (S3 keys never exceed a few KB even with
        // long prefixes).
        const url_z = try allocator.dupeZ(u8, req.url);
        defer allocator.free(url_z);
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_URL, url_z.ptr);

        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_TIMEOUT_MS, @as(c_long, req.timeout_ms));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, req.connect_timeout_ms));

        switch (req.http_version) {
            .auto => {},
            .h2c_prior_knowledge => {
                _ = c.curl_easy_setopt(
                    self.handle,
                    c.CURLOPT_HTTP_VERSION,
                    @as(c_long, c.CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE),
                );
            },
        }

        if (!req.verify_tls) {
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 0));
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 0));
        }

        switch (req.method) {
            .GET => {
                _ = c.curl_easy_setopt(self.handle, c.CURLOPT_HTTPGET, @as(c_long, 1));
            },
            .HEAD => {
                _ = c.curl_easy_setopt(self.handle, c.CURLOPT_NOBODY, @as(c_long, 1));
            },
            .PUT => {
                _ = c.curl_easy_setopt(self.handle, c.CURLOPT_UPLOAD, @as(c_long, 1));
                _ = c.curl_easy_setopt(self.handle, c.CURLOPT_INFILESIZE_LARGE, @as(c.curl_off_t, @intCast(req.body.len)));
            },
            .POST => {
                _ = c.curl_easy_setopt(self.handle, c.CURLOPT_POST, @as(c_long, 1));
                _ = c.curl_easy_setopt(self.handle, c.CURLOPT_POSTFIELDSIZE_LARGE, @as(c.curl_off_t, @intCast(req.body.len)));
            },
            .DELETE => {
                _ = c.curl_easy_setopt(self.handle, c.CURLOPT_CUSTOMREQUEST, "DELETE");
            },
        }

        // Headers list. libcurl wants `Name: value` strings.
        var slist: ?*c.curl_slist = null;
        defer if (slist != null) c.curl_slist_free_all(slist);
        for (req.headers) |h| {
            const line = try std.fmt.allocPrintSentinel(allocator, "{s}: {s}", .{ h.name, h.value }, 0);
            defer allocator.free(line);
            slist = c.curl_slist_append(slist, line.ptr);
        }
        if (req.range) |r| {
            const line = try std.fmt.allocPrintSentinel(allocator, "Range: {s}", .{r}, 0);
            defer allocator.free(line);
            slist = c.curl_slist_append(slist, line.ptr);
        }
        if (slist != null) {
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_HTTPHEADER, slist);
        }

        // Request body — fed back via CURLOPT_READFUNCTION so we
        // don't have to copy. Position tracked in a `BodyCursor`
        // that read_cb advances.
        var body_cursor: BodyCursor = .{ .src = req.body };
        if (req.method == .PUT or req.method == .POST) {
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_READFUNCTION, @as(*const fn (*anyopaque, usize, usize, *anyopaque) callconv(.c) usize, &readBody));
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_READDATA, @as(*anyopaque, @ptrCast(&body_cursor)));
        }

        // Response body capture. HEAD skips this — libcurl drops the
        // body anyway via NOBODY.
        var resp_buf: std.ArrayList(u8) = .empty;
        errdefer resp_buf.deinit(allocator);
        var write_ctx: WriteCtx = .{ .allocator = allocator, .buf = &resp_buf };
        if (req.method != .HEAD) {
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_WRITEFUNCTION, @as(*const fn (*anyopaque, usize, usize, *anyopaque) callconv(.c) usize, &writeResp));
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&write_ctx)));
        }

        const rc = c.curl_easy_perform(self.handle);
        if (rc != c.CURLE_OK) {
            std.log.warn("curl: {s} {s} failed: rc={d} msg={s}", .{
                @tagName(req.method),
                req.url,
                rc,
                std.mem.sliceTo(&self.err_buf, 0),
            });
            // resp_buf is freed by the errdefer above on return.
            // Do NOT call deinit here — that would double-free.
            return Error.CurlCallFailed;
        }

        if (write_ctx.alloc_failed) {
            // Same as above: errdefer frees resp_buf on return.
            return Error.OutOfMemory;
        }

        var status_long: c_long = 0;
        _ = c.curl_easy_getinfo(self.handle, c.CURLINFO_RESPONSE_CODE, &status_long);
        const status: u16 = @intCast(@max(status_long, 0));

        const body_owned: ?[]u8 = if (req.method == .HEAD) blk: {
            resp_buf.deinit(allocator);
            break :blk null;
        } else try resp_buf.toOwnedSlice(allocator);

        return .{ .status = status, .body = body_owned };
    }
};

const BodyCursor = struct {
    src: []const u8,
    pos: usize = 0,
};

fn readBody(ptr: *anyopaque, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
    const cursor: *BodyCursor = @ptrCast(@alignCast(userdata));
    const dst: [*]u8 = @ptrCast(ptr);
    const want = size * nmemb;
    const remaining = cursor.src.len - cursor.pos;
    const n = @min(want, remaining);
    if (n > 0) {
        @memcpy(dst[0..n], cursor.src[cursor.pos..][0..n]);
        cursor.pos += n;
    }
    return n;
}

const WriteCtx = struct {
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    alloc_failed: bool = false,
};

fn writeResp(ptr: *anyopaque, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
    const ctx: *WriteCtx = @ptrCast(@alignCast(userdata));
    if (ctx.alloc_failed) return 0;
    const src: [*]const u8 = @ptrCast(ptr);
    const n = size * nmemb;
    ctx.buf.appendSlice(ctx.allocator, src[0..n]) catch {
        ctx.alloc_failed = true;
        return 0;
    };
    return n;
}

// curl_global_init is best-effort idempotent within libcurl, but
// the docs say to call once before any threads. The blob/log
// modules call this before constructing the first Easy.
var global_init_done: std.atomic.Value(bool) = .init(false);
var global_init_mutex: std.Thread.Mutex = .{};

pub fn globalInit() void {
    if (global_init_done.load(.acquire)) return;
    global_init_mutex.lock();
    defer global_init_mutex.unlock();
    if (global_init_done.load(.acquire)) return;
    _ = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
    global_init_done.store(true, .release);
}
