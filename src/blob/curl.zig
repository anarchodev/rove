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
    /// Response headers, name+value allocator-owned. Captured for
    /// every method (ACME is header-driven: `Replay-Nonce` on every
    /// POST, `Location` for account/order URLs). Existing callers
    /// (S3) simply ignore this. Use `header()` for a case-insensitive
    /// lookup of the last occurrence.
    headers: []Header = &.{},

    /// Case-insensitive lookup (HTTP header names are case-insensitive;
    /// returns the last match — fine for the single-valued headers
    /// ACME reads).
    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        var i: usize = self.headers.len;
        while (i > 0) {
            i -= 1;
            if (std.ascii.eqlIgnoreCase(self.headers[i].name, name))
                return self.headers[i].value;
        }
        return null;
    }

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        if (self.body) |b| allocator.free(b);
        for (self.headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(self.headers);
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
    /// Set by `EasyPool.init` when this handle is part of a pool.
    /// `EasyPool.release` reads it back to find the handle's slot
    /// without a linear scan. Standalone Easies (not from a pool)
    /// leave this null.
    pool_index: ?u16 = null,

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
        // A UA-less client is a latent bug against strict peers (ACME
        // CAs reject "no User-Agent" with 400 malformed). A caller
        // that adds its own `User-Agent:` header still overrides this.
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_USERAGENT, "rove");

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

        // Response-header capture (always — cheap; ACME needs it,
        // S3 ignores it).
        var hdr_list: std.ArrayListUnmanaged(Header) = .empty;
        errdefer {
            for (hdr_list.items) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            hdr_list.deinit(allocator);
        }
        var hdr_ctx: HeaderCtx = .{ .allocator = allocator, .list = &hdr_list };
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_HEADERFUNCTION, @as(*const fn (*anyopaque, usize, usize, *anyopaque) callconv(.c) usize, &headerResp));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_HEADERDATA, @as(*anyopaque, @ptrCast(&hdr_ctx)));

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
        if (hdr_ctx.alloc_failed) return Error.OutOfMemory;

        var status_long: c_long = 0;
        _ = c.curl_easy_getinfo(self.handle, c.CURLINFO_RESPONSE_CODE, &status_long);
        const status: u16 = @intCast(@max(status_long, 0));

        const body_owned: ?[]u8 = if (req.method == .HEAD) blk: {
            resp_buf.deinit(allocator);
            break :blk null;
        } else try resp_buf.toOwnedSlice(allocator);

        return .{
            .status = status,
            .body = body_owned,
            .headers = try hdr_list.toOwnedSlice(allocator),
        };
    }
};

/// Process-wide pool of libcurl `Easy` handles, reused across every
/// `S3BlobStore` / `HttpBlobStore` in the process. Replaces the
/// previous one-Easy-per-store pattern: at scale that put a separate
/// keep-alive TCP+TLS connection in flight for every per-tenant
/// store × every worker thread × every backend (file-blobs + manifest
/// + log-blobs), which blew the FD count and the per-connection
/// libcurl/BoringSSL state into the 8-GB-per-worker range at 1k
/// active tenants.
///
/// Now: one fixed-size pool of N handles. Any caller `acquire()`s a
/// handle (blocking on a condvar when the pool is exhausted), runs
/// one request, `release()`s it back. N is the maximum number of
/// concurrent in-flight S3 requests this process will pipeline.
///
/// Default size is 64 (overridable via `ROVE_S3_POOL_SIZE`). That's
/// large enough to cover the bursty fan-out of the cluster-wide
/// snapshot tick + the worker-side deployment_loader prefetch, small
/// enough that 64 × per-Easy memory stays in the low MB.
pub const EasyPool = struct {
    allocator: std.mem.Allocator,
    handles: []*Easy,
    /// Stack of free indices into `handles`. `free_top` points one
    /// past the last free entry (free_top == 0 → pool exhausted).
    free_stack: []u16,
    free_top: u16,
    mu: std.Thread.Mutex = .{},
    cv: std.Thread.Condition = .{},

    pub fn init(allocator: std.mem.Allocator, size: u16) Error!*EasyPool {
        std.debug.assert(size > 0);
        const self = try allocator.create(EasyPool);
        errdefer allocator.destroy(self);

        const handles = try allocator.alloc(*Easy, size);
        errdefer allocator.free(handles);
        const free_stack = try allocator.alloc(u16, size);
        errdefer allocator.free(free_stack);

        var built: u16 = 0;
        errdefer {
            var i: u16 = 0;
            while (i < built) : (i += 1) handles[i].deinit();
        }
        while (built < size) : (built += 1) {
            handles[built] = try Easy.init(allocator);
            handles[built].pool_index = built;
            free_stack[built] = built;
        }

        self.* = .{
            .allocator = allocator,
            .handles = handles,
            .free_stack = free_stack,
            .free_top = size,
        };
        return self;
    }

    pub fn deinit(self: *EasyPool) void {
        for (self.handles) |e| e.deinit();
        self.allocator.free(self.handles);
        self.allocator.free(self.free_stack);
        const a = self.allocator;
        a.destroy(self);
    }

    /// Block until a handle is free, then return it. Caller MUST
    /// pair every `acquire` with `release`.
    pub fn acquire(self: *EasyPool) *Easy {
        self.mu.lock();
        defer self.mu.unlock();
        while (self.free_top == 0) self.cv.wait(&self.mu);
        self.free_top -= 1;
        const idx = self.free_stack[self.free_top];
        return self.handles[idx];
    }

    pub fn release(self: *EasyPool, easy: *Easy) void {
        const idx = easy.pool_index orelse @panic("EasyPool.release: Easy not from a pool");
        self.mu.lock();
        defer self.mu.unlock();
        std.debug.assert(self.free_top < self.handles.len);
        self.free_stack[self.free_top] = idx;
        self.free_top += 1;
        self.cv.signal();
    }
};

/// Process-wide default pool, lazily initialized on first call. Size
/// controlled by the `ROVE_S3_POOL_SIZE` environment variable; 64 if
/// unset.
var default_pool_done: std.atomic.Value(bool) = .init(false);
var default_pool_mu: std.Thread.Mutex = .{};
var default_pool: ?*EasyPool = null;
var default_pool_err: ?anyerror = null;

fn defaultPoolSize() u16 {
    const env_str = std.posix.getenv("ROVE_S3_POOL_SIZE") orelse return 64;
    const trimmed = std.mem.trim(u8, env_str, " \t\n");
    const parsed = std.fmt.parseInt(u16, trimmed, 10) catch {
        std.log.warn("rove-blob: invalid ROVE_S3_POOL_SIZE={s}, using default 64", .{trimmed});
        return 64;
    };
    if (parsed == 0) {
        std.log.warn("rove-blob: ROVE_S3_POOL_SIZE=0 invalid, using default 64", .{});
        return 64;
    }
    return parsed;
}

/// Return the process-wide default pool. Caller may use a custom
/// pool instead (passed in via API where supported); the default
/// keeps the common case zero-config.
pub fn defaultPool() Error!*EasyPool {
    if (default_pool_done.load(.acquire)) {
        if (default_pool) |p| return p;
        return default_pool_err.? catch Error.CurlInitFailed;
    }
    default_pool_mu.lock();
    defer default_pool_mu.unlock();
    if (default_pool_done.load(.acquire)) {
        if (default_pool) |p| return p;
        return default_pool_err.? catch Error.CurlInitFailed;
    }
    globalInit();
    if (EasyPool.init(std.heap.c_allocator, defaultPoolSize())) |pool| {
        default_pool = pool;
    } else |err| {
        default_pool_err = err;
    }
    default_pool_done.store(true, .release);
    if (default_pool) |p| return p;
    return Error.CurlInitFailed;
}

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

const HeaderCtx = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(Header),
    alloc_failed: bool = false,
};

/// CURLOPT_HEADERFUNCTION: one call per header line, including the
/// `HTTP/x NNN` status line and the terminating blank line (and one
/// such block per intermediate response on redirects/100-continue).
/// We keep only `Name: value` lines; the status line (no colon) and
/// blank lines are skipped. Last-occurrence wins via `Response.header`.
fn headerResp(ptr: *anyopaque, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
    const ctx: *HeaderCtx = @ptrCast(@alignCast(userdata));
    const n = size * nmemb;
    if (ctx.alloc_failed) return n; // keep consuming; fail at the call site
    const src: [*]const u8 = @ptrCast(ptr);
    const line = std.mem.trimRight(u8, src[0..n], "\r\n");
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return n;
    const name = std.mem.trim(u8, line[0..colon], " \t");
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
    if (name.len == 0) return n;
    const name_copy = ctx.allocator.dupe(u8, name) catch {
        ctx.alloc_failed = true;
        return n;
    };
    const value_copy = ctx.allocator.dupe(u8, value) catch {
        ctx.allocator.free(name_copy);
        ctx.alloc_failed = true;
        return n;
    };
    ctx.list.append(ctx.allocator, .{ .name = name_copy, .value = value_copy }) catch {
        ctx.allocator.free(name_copy);
        ctx.allocator.free(value_copy);
        ctx.alloc_failed = true;
        return n;
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
