//! libcurl multi-interface engine — Phase 1 of `docs/curl-multi-plan.md`.
//!
//! One `Multi` handle drives many concurrent `Transfer`s on a single
//! thread. This file declares the surface; no production consumer
//! exists yet (Phase 2 migrates `http.fetch` off `Easy + FetchPool`).
//!
//! ## Why two driver shapes
//!
//! - **`Multi.poll(timeout_ms)`** — wraps `curl_multi_poll +
//!   curl_multi_perform`. Self-contained: libcurl internally polls
//!   the fds it owns and advances all transfers. Used by the test
//!   driver `runDriver` and any caller that doesn't already own an
//!   event loop. The simple path.
//! - **`Multi.socketAction(fd, ev_bits)`** — wraps
//!   `curl_multi_socket_action`. Event-driven: the application's
//!   event loop watches the fds libcurl asks for (via the
//!   `CURLMOPT_SOCKETFUNCTION` callback) and calls this on
//!   readiness. The production path Phase 2's `FetchEngine` wires
//!   to epoll.
//!
//! Both paths share the `drainCompleted` step that fires per-transfer
//! `on_done` callbacks.
//!
//! ## Lifecycle
//!
//! ```
//! var multi = try Multi.init(allocator);
//! defer multi.deinit();
//!
//! const t = try Transfer.init(allocator, .{
//!     .url = "http://127.0.0.1:8080/echo",
//! }, onDone, &my_ctx);
//! try multi.add(t);
//!
//! while (multi.transfers.count() > 0) {
//!     _ = try multi.poll(100);
//!     _ = multi.drainCompleted();
//! }
//! ```
//!
//! `Transfer` ownership transfers to `Multi` on `add`. The
//! `on_done` callback receives the still-owned transfer; the Multi
//! removes + frees it after the callback returns.

const std = @import("std");

const c = @cImport({
    @cInclude("curl/curl.h");
});

pub const Error = error{
    CurlInitFailed,
    CurlMultiFailed,
    CurlCallFailed,
    OutOfMemory,
};

pub const Method = enum { GET, POST, PUT, HEAD, DELETE };

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// One outbound request descriptor. Same shape as `blob/curl.zig`'s
/// `Request` — duplicated here so this file can stand alone and so
/// the surfaces evolve independently (the multi engine may grow
/// fields like `on_chunk` for streaming bodies that don't fit the
/// blocking Easy path).
pub const Request = struct {
    method: Method = .GET,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = &.{},
    timeout_ms: u32 = 15_000,
    connect_timeout_ms: u32 = 5_000,
    verify_tls: bool = true,
};

/// Result handed to the `on_done` callback when a transfer completes.
/// `body` + `headers` are owned by the Transfer for the duration of
/// the callback; the callback dupes anything it wants to keep.
pub const Result = struct {
    /// True iff libcurl's perform completed without a transport
    /// error. Non-2xx HTTP status is still `ok = true` — interpret
    /// `status` separately.
    ok: bool,
    /// `CURLE_*` code. `CURLE_OK == 0`. Inspect on `ok = false` to
    /// distinguish timeout from DNS from connect failure etc.
    /// `c_uint` matches libcurl's `CURLcode` enum width.
    curl_code: c_uint,
    /// HTTP response status. Zero if the transfer never reached a
    /// status (e.g., DNS failure).
    status: u16,
    /// Response body bytes — borrowed from the Transfer. Dup before
    /// the callback returns if retention is needed.
    body: []const u8,
    /// Response headers — borrowed from the Transfer.
    headers: []const Header,
};

// Per-transfer completion callback type is inlined at every use site
// rather than declared as a top-level `const DoneFn = *const fn(...)`
// because aliasing a function pointer that takes `*Transfer` while
// `Transfer` carries a field of that pointer type creates a
// dependency loop in Zig 0.15.x's type resolution. The signature is
// `(*Transfer, Result, ?*anyopaque) void`.

/// Mid-PUT/POST body upload cursor — same shape as `blob/curl.zig`.
const BodyCursor = struct {
    src: []const u8,
    off: usize = 0,
};

/// One in-flight transfer — wraps a `CURL*` easy handle plus the
/// response-capture state. Owned by `Multi` after `add`. Freed via
/// `deinit` once it has been removed from the multi handle and the
/// `on_done` callback has run.
pub const Transfer = struct {
    allocator: std.mem.Allocator,
    handle: *c.CURL,
    /// libcurl writes the most recent transport error here via
    /// `CURLOPT_ERRORBUFFER`. Lives for the Transfer's lifetime.
    err_buf: [c.CURL_ERROR_SIZE]u8,
    /// Upload cursor for PUT/POST; `src.len == 0` for other methods.
    body_cursor: BodyCursor,
    /// Response body accumulator (Phase 1: whole-body capture; Phase
    /// 2 can grow a streaming variant).
    resp_body: std.ArrayListUnmanaged(u8),
    /// Captured response headers (name + value both allocator-owned).
    resp_headers: std.ArrayListUnmanaged(Header),
    /// Header-list passed to CURLOPT_HTTPHEADER; freed in deinit.
    req_headers_slist: ?*c.curl_slist,
    /// Nul-terminated URL copy libcurl keeps a reference to.
    url_z: [:0]u8,
    /// Caller-supplied terminal callback + ctx.
    on_done: *const fn (*Transfer, Result, ?*anyopaque) void,
    user_ctx: ?*anyopaque,
    /// Set by Transfer callbacks on alloc failure; surfaced on
    /// completion as `Result{ok=false, curl_code=CURLE_OUT_OF_MEMORY}`.
    alloc_failed: bool,
    /// Optional per-writeback streaming hook. When non-null,
    /// `writeBodyCb` forwards each writeback to this fn instead of
    /// appending to `resp_body` (which stays empty). Returns true to
    /// continue, false to abort the transfer (libcurl surfaces this
    /// as `CURLE_WRITE_ERROR` in the Result). Phase 2's `FetchEngine`
    /// uses this to drive per-chunk event emission.
    on_chunk: ?*const fn (bytes: []const u8, ctx: ?*anyopaque) bool,
    /// Optional per-header-line streaming hook. When non-null,
    /// `writeHeaderCb` forwards each raw libcurl-delivered line
    /// (`Name: value\r\n` + the status line + blank terminator) to
    /// this fn instead of parsing into `resp_headers`. Used by the
    /// streaming consumer that wants the raw block to parse on its
    /// own schedule.
    on_header_line: ?*const fn (line: []const u8, ctx: ?*anyopaque) void,

    pub fn init(
        allocator: std.mem.Allocator,
        req: Request,
        on_done: *const fn (*Transfer, Result, ?*anyopaque) void,
        user_ctx: ?*anyopaque,
    ) Error!*Transfer {
        const handle = c.curl_easy_init() orelse return Error.CurlInitFailed;
        errdefer c.curl_easy_cleanup(handle);

        const self = try allocator.create(Transfer);
        errdefer allocator.destroy(self);

        const url_z = try allocator.dupeZ(u8, req.url);
        errdefer allocator.free(url_z);

        var slist: ?*c.curl_slist = null;
        errdefer if (slist != null) c.curl_slist_free_all(slist);
        for (req.headers) |h| {
            const line = try std.fmt.allocPrintSentinel(
                allocator, "{s}: {s}", .{ h.name, h.value }, 0,
            );
            defer allocator.free(line);
            slist = c.curl_slist_append(slist, line.ptr);
        }

        self.* = .{
            .allocator = allocator,
            .handle = handle,
            .err_buf = std.mem.zeroes([c.CURL_ERROR_SIZE]u8),
            .body_cursor = .{ .src = req.body },
            .resp_body = .empty,
            .resp_headers = .empty,
            .req_headers_slist = slist,
            .url_z = url_z,
            .on_done = on_done,
            .user_ctx = user_ctx,
            .alloc_failed = false,
            .on_chunk = null,
            .on_header_line = null,
        };

        // Wire opts. The CURLOPT calls don't fail for the kinds of
        // opts we pass here (string + int + fn pointer); ignore rc.
        _ = c.curl_easy_setopt(handle, c.CURLOPT_URL, url_z.ptr);
        _ = c.curl_easy_setopt(handle, c.CURLOPT_ERRORBUFFER, &self.err_buf);
        _ = c.curl_easy_setopt(handle, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
        _ = c.curl_easy_setopt(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
        _ = c.curl_easy_setopt(handle, c.CURLOPT_TIMEOUT_MS, @as(c_long, req.timeout_ms));
        _ = c.curl_easy_setopt(handle, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, req.connect_timeout_ms));
        const verify_long: c_long = if (req.verify_tls) 1 else 0;
        _ = c.curl_easy_setopt(handle, c.CURLOPT_SSL_VERIFYPEER, verify_long);
        _ = c.curl_easy_setopt(handle, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, if (req.verify_tls) 2 else 0));

        switch (req.method) {
            .GET => _ = c.curl_easy_setopt(handle, c.CURLOPT_HTTPGET, @as(c_long, 1)),
            .POST => {
                _ = c.curl_easy_setopt(handle, c.CURLOPT_POST, @as(c_long, 1));
                _ = c.curl_easy_setopt(handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(req.body.len)));
                _ = c.curl_easy_setopt(handle, c.CURLOPT_READFUNCTION, @as(*const fn (*anyopaque, usize, usize, *anyopaque) callconv(.c) usize, &readBodyCb));
                _ = c.curl_easy_setopt(handle, c.CURLOPT_READDATA, @as(*anyopaque, @ptrCast(&self.body_cursor)));
            },
            .PUT => {
                _ = c.curl_easy_setopt(handle, c.CURLOPT_UPLOAD, @as(c_long, 1));
                _ = c.curl_easy_setopt(handle, c.CURLOPT_INFILESIZE_LARGE, @as(c.curl_off_t, @intCast(req.body.len)));
                _ = c.curl_easy_setopt(handle, c.CURLOPT_READFUNCTION, @as(*const fn (*anyopaque, usize, usize, *anyopaque) callconv(.c) usize, &readBodyCb));
                _ = c.curl_easy_setopt(handle, c.CURLOPT_READDATA, @as(*anyopaque, @ptrCast(&self.body_cursor)));
            },
            .HEAD => _ = c.curl_easy_setopt(handle, c.CURLOPT_NOBODY, @as(c_long, 1)),
            .DELETE => _ = c.curl_easy_setopt(handle, c.CURLOPT_CUSTOMREQUEST, "DELETE"),
        }

        if (slist != null) {
            _ = c.curl_easy_setopt(handle, c.CURLOPT_HTTPHEADER, slist);
        }

        if (req.method != .HEAD) {
            _ = c.curl_easy_setopt(handle, c.CURLOPT_WRITEFUNCTION, @as(*const fn (*anyopaque, usize, usize, *anyopaque) callconv(.c) usize, &writeBodyCb));
            _ = c.curl_easy_setopt(handle, c.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(self)));
        }
        _ = c.curl_easy_setopt(handle, c.CURLOPT_HEADERFUNCTION, @as(*const fn (*anyopaque, usize, usize, *anyopaque) callconv(.c) usize, &writeHeaderCb));
        _ = c.curl_easy_setopt(handle, c.CURLOPT_HEADERDATA, @as(*anyopaque, @ptrCast(self)));

        return self;
    }

    /// Streaming variant — same wiring as `init` but installs the
    /// per-writeback `on_chunk` + per-header-line `on_header_line`
    /// hooks. Used by Phase 2's `FetchEngine` to drive per-chunk
    /// event emission for `http.fetch` `stream: true` and to
    /// route the raw header block to the consumer's own parser.
    /// The `Result.body` / `.headers` passed to `on_done` will be
    /// empty for streaming transfers (the bytes already flowed
    /// through `on_chunk`); the consumer composes its own terminal
    /// signaling.
    pub fn initStreaming(
        allocator: std.mem.Allocator,
        req: Request,
        on_chunk: *const fn (bytes: []const u8, ctx: ?*anyopaque) bool,
        on_header_line: *const fn (line: []const u8, ctx: ?*anyopaque) void,
        on_done: *const fn (*Transfer, Result, ?*anyopaque) void,
        user_ctx: ?*anyopaque,
    ) Error!*Transfer {
        const self = try Transfer.init(allocator, req, on_done, user_ctx);
        self.on_chunk = on_chunk;
        self.on_header_line = on_header_line;
        return self;
    }

    /// Free every resource the transfer owns. Caller must have
    /// already removed it from the parent Multi (`Multi.remove` or
    /// completion through `drainCompleted`).
    pub fn deinit(self: *Transfer) void {
        c.curl_easy_cleanup(self.handle);
        if (self.req_headers_slist != null) c.curl_slist_free_all(self.req_headers_slist);
        self.allocator.free(self.url_z);
        self.resp_body.deinit(self.allocator);
        for (self.resp_headers.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.resp_headers.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn statusCode(self: *const Transfer) u16 {
        var st: c_long = 0;
        _ = c.curl_easy_getinfo(self.handle, c.CURLINFO_RESPONSE_CODE, &st);
        return @intCast(@max(st, 0));
    }
};

/// `curl_multi` handle plus the active-transfers map. Single-threaded
/// — libcurl multi handles are not thread-safe. Callers that need
/// concurrency across threads run multiple Multi instances (one per
/// thread).
pub const Multi = struct {
    allocator: std.mem.Allocator,
    handle: *c.CURLM,
    /// Active transfers, keyed by `@intFromPtr(transfer.handle)` so
    /// we can look up by the `CURL*` `curl_multi_info_read` returns.
    transfers: std.AutoHashMapUnmanaged(usize, *Transfer),

    pub fn init(allocator: std.mem.Allocator) Error!*Multi {
        const handle = c.curl_multi_init() orelse return Error.CurlInitFailed;
        errdefer _ = c.curl_multi_cleanup(handle);

        const self = try allocator.create(Multi);
        self.* = .{
            .allocator = allocator,
            .handle = handle,
            .transfers = .empty,
        };
        return self;
    }

    /// Tear down. Any still-attached transfers are removed +
    /// destroyed without firing their `on_done` callbacks (shutdown
    /// path; callbacks are best-effort completion signaling, not
    /// cleanup hooks). Callers that want orderly drain finish
    /// in-flight transfers first.
    pub fn deinit(self: *Multi) void {
        var it = self.transfers.valueIterator();
        while (it.next()) |tp| {
            _ = c.curl_multi_remove_handle(self.handle, tp.*.handle);
            tp.*.deinit();
        }
        self.transfers.deinit(self.allocator);
        _ = c.curl_multi_cleanup(self.handle);
        self.allocator.destroy(self);
    }

    /// Take ownership of `transfer` + add it to the multi handle.
    /// libcurl starts driving it immediately on the next `poll` /
    /// `socketAction` call.
    pub fn add(self: *Multi, transfer: *Transfer) Error!void {
        try self.transfers.put(self.allocator, @intFromPtr(transfer.handle), transfer);
        errdefer _ = self.transfers.remove(@intFromPtr(transfer.handle));
        const rc = c.curl_multi_add_handle(self.handle, transfer.handle);
        if (rc != c.CURLM_OK) return Error.CurlMultiFailed;
    }

    /// Cancel an in-flight transfer + destroy it WITHOUT firing
    /// `on_done`. Caller's view: the transfer never completed (the
    /// cooperative-cancel posture from curl-multi-plan §5
    /// invariant 3). Cleanup is synchronous.
    pub fn cancel(self: *Multi, transfer: *Transfer) void {
        const key = @intFromPtr(transfer.handle);
        if (self.transfers.remove(key)) {
            _ = c.curl_multi_remove_handle(self.handle, transfer.handle);
            transfer.deinit();
        }
    }

    /// Blocking-poll driver: wait up to `timeout_ms` for activity,
    /// then advance all transfers. Returns the libcurl-reported
    /// still-running count. Use this from a dedicated driver
    /// thread that has no other event loop (test path,
    /// `runDriver`).
    ///
    /// Phase 2's `FetchEngine` uses `socketAction` instead so its
    /// epoll loop integrates with the wakeup eventfd.
    pub fn poll(self: *Multi, timeout_ms: c_int) Error!c_int {
        var numfds: c_int = 0;
        const wait_rc = c.curl_multi_poll(self.handle, null, 0, timeout_ms, &numfds);
        if (wait_rc != c.CURLM_OK) return Error.CurlMultiFailed;
        var still_running: c_int = 0;
        const perf_rc = c.curl_multi_perform(self.handle, &still_running);
        if (perf_rc != c.CURLM_OK) return Error.CurlMultiFailed;
        return still_running;
    }

    /// Wake the engine thread out of `poll` from another thread.
    /// Wraps `curl_multi_wakeup` (libcurl 7.68+). Used by
    /// `FetchEngine` so cross-thread `submit` / `cancel` get
    /// picked up immediately instead of waiting for the poll
    /// timeout to elapse. Async-signal-safe per libcurl docs.
    pub fn wakeup(self: *Multi) Error!void {
        const rc = c.curl_multi_wakeup(self.handle);
        if (rc != c.CURLM_OK) return Error.CurlMultiFailed;
    }

    /// Event-driven entry — Phase 2's `FetchEngine` wires this with
    /// epoll. `fd == CURL_SOCKET_TIMEOUT` (`-1`) means "the timer
    /// fired"; otherwise `fd` must be an fd libcurl asked us to
    /// watch (via the SOCKETFUNCTION callback) and `ev_bits` is
    /// `CURL_CSELECT_IN | CURL_CSELECT_OUT | CURL_CSELECT_ERR`.
    pub fn socketAction(
        self: *Multi,
        fd: c.curl_socket_t,
        ev_bits: c_int,
    ) Error!c_int {
        var still_running: c_int = 0;
        const rc = c.curl_multi_socket_action(self.handle, fd, ev_bits, &still_running);
        if (rc != c.CURLM_OK) return Error.CurlMultiFailed;
        return still_running;
    }

    /// Drain completed transfers from `curl_multi_info_read`. For
    /// each, fires the per-transfer `on_done` callback, removes it
    /// from the multi handle, and destroys it. Returns the number
    /// of transfers completed. Safe (and cheap) to call any time;
    /// returns 0 when nothing is ready.
    pub fn drainCompleted(self: *Multi) usize {
        var n: usize = 0;
        while (true) {
            var msgs_left: c_int = 0;
            const msg = c.curl_multi_info_read(self.handle, &msgs_left);
            if (msg == null) break;
            if (msg.*.msg != c.CURLMSG_DONE) continue;
            const handle = msg.*.easy_handle orelse continue;
            const code = msg.*.data.result;
            const key = @intFromPtr(handle);
            const transfer = self.transfers.get(key) orelse continue;

            const result: Result = .{
                .ok = (code == c.CURLE_OK) and !transfer.alloc_failed,
                .curl_code = code,
                .status = transfer.statusCode(),
                .body = transfer.resp_body.items,
                .headers = transfer.resp_headers.items,
            };

            // Remove from the multi BEFORE firing on_done so a
            // callback that re-enters Multi (e.g., submitting a
            // follow-up transfer) sees consistent state.
            _ = c.curl_multi_remove_handle(self.handle, handle);
            _ = self.transfers.remove(key);
            transfer.on_done(transfer, result, transfer.user_ctx);
            transfer.deinit();
            n += 1;
        }
        return n;
    }
};

/// Convenience driver: poll + drain in a loop until `stop_flag` is
/// set. Used by Phase 1 tests and any single-purpose driver thread
/// that doesn't need to integrate with an external event loop.
/// Phase 2's `FetchEngine` runs its own loop instead.
pub fn runDriver(
    multi: *Multi,
    stop_flag: *std.atomic.Value(bool),
) Error!void {
    while (!stop_flag.load(.acquire)) {
        _ = try multi.poll(100);
        _ = multi.drainCompleted();
    }
}

// ── C callbacks ─────────────────────────────────────────────────────────

fn writeBodyCb(
    ptr: *anyopaque,
    size: usize,
    nmemb: usize,
    userdata: *anyopaque,
) callconv(.c) usize {
    const transfer: *Transfer = @ptrCast(@alignCast(userdata));
    const total = size * nmemb;
    if (total == 0) return 0;
    const bytes = @as([*]const u8, @ptrCast(ptr))[0..total];
    // Streaming variant: forward to caller's on_chunk; their return
    // controls libcurl (true → consume, false → abort with
    // CURLE_WRITE_ERROR).
    if (transfer.on_chunk) |cb| {
        const cont = cb(bytes, transfer.user_ctx);
        return if (cont) total else 0;
    }
    // Whole-body variant (Phase 1 default): append to resp_body for
    // surfacing in `Result.body` on completion.
    transfer.resp_body.appendSlice(transfer.allocator, bytes) catch {
        transfer.alloc_failed = true;
        // Return short — libcurl reads this as a write error and
        // sets CURLE_WRITE_ERROR, which we surface via the result.
        return 0;
    };
    return total;
}

fn writeHeaderCb(
    ptr: *anyopaque,
    size: usize,
    nmemb: usize,
    userdata: *anyopaque,
) callconv(.c) usize {
    const transfer: *Transfer = @ptrCast(@alignCast(userdata));
    const total = size * nmemb;
    if (total == 0) return 0;
    const raw = @as([*]const u8, @ptrCast(ptr))[0..total];
    // Streaming variant: hand the caller the raw line and skip our
    // parse + accumulate. Status line + blank terminator are
    // included — the caller's parser handles the colon-less ones.
    if (transfer.on_header_line) |cb| {
        cb(raw, transfer.user_ctx);
        return total;
    }
    // Trim trailing CRLF, then split on first ':'. Status line +
    // separator line are skipped (they have no ':' between
    // header-name-like text and a value).
    var line = raw;
    while (line.len > 0 and (line[line.len - 1] == '\n' or line[line.len - 1] == '\r'))
        line = line[0 .. line.len - 1];
    if (line.len == 0) return total;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return total;
    if (colon == 0) return total;
    var value_start = colon + 1;
    while (value_start < line.len and (line[value_start] == ' ' or line[value_start] == '\t'))
        value_start += 1;
    const name = line[0..colon];
    const value = line[value_start..];
    const name_dup = transfer.allocator.dupe(u8, name) catch {
        transfer.alloc_failed = true;
        return 0;
    };
    errdefer transfer.allocator.free(name_dup);
    const value_dup = transfer.allocator.dupe(u8, value) catch {
        transfer.alloc_failed = true;
        transfer.allocator.free(name_dup);
        return 0;
    };
    errdefer transfer.allocator.free(value_dup);
    transfer.resp_headers.append(transfer.allocator, .{ .name = name_dup, .value = value_dup }) catch {
        transfer.alloc_failed = true;
        transfer.allocator.free(name_dup);
        transfer.allocator.free(value_dup);
        return 0;
    };
    return total;
}

fn readBodyCb(
    ptr: *anyopaque,
    size: usize,
    nmemb: usize,
    userdata: *anyopaque,
) callconv(.c) usize {
    const cursor: *BodyCursor = @ptrCast(@alignCast(userdata));
    const want = size * nmemb;
    const remaining = cursor.src.len - cursor.off;
    const n = @min(want, remaining);
    if (n == 0) return 0;
    const dst = @as([*]u8, @ptrCast(ptr))[0..n];
    @memcpy(dst, cursor.src[cursor.off .. cursor.off + n]);
    cursor.off += n;
    return n;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Minimal in-process HTTP/1.1 echo server for tests. Binds to a
/// random localhost port (`127.0.0.1:0`), accepts up to `max_conns`
/// connections, and replies to every request with a canned body.
/// Single-threaded accept loop on a spawned thread.
const TestEcho = struct {
    listener: std.net.Server,
    port: u16,
    thread: std.Thread,
    stop: std.atomic.Value(bool),
    body: []const u8,

    fn start(allocator: std.mem.Allocator, body: []const u8) !*TestEcho {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        var listener = try addr.listen(.{ .reuse_address = true });
        errdefer listener.deinit();
        const bound = listener.listen_address;
        const port: u16 = switch (bound.any.family) {
            std.posix.AF.INET => std.mem.bigToNative(u16, bound.in.sa.port),
            else => return error.UnexpectedAddrFamily,
        };

        const self = try allocator.create(TestEcho);
        self.* = .{
            .listener = listener,
            .port = port,
            .thread = undefined,
            .stop = .init(false),
            .body = body,
        };
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
        return self;
    }

    fn stopAndJoin(self: *TestEcho, allocator: std.mem.Allocator) void {
        self.stop.store(true, .release);
        // Self-connect to break the accept call. listen_address is
        // the bound 127.0.0.1:port we already know.
        const wake_addr = std.net.Address.parseIp("127.0.0.1", self.port) catch {
            self.thread.join();
            self.listener.deinit();
            allocator.destroy(self);
            return;
        };
        if (std.net.tcpConnectToAddress(wake_addr)) |stream| {
            stream.close();
        } else |_| {}
        self.thread.join();
        self.listener.deinit();
        allocator.destroy(self);
    }

    fn runLoop(self: *TestEcho) void {
        while (!self.stop.load(.acquire)) {
            const conn = self.listener.accept() catch return;
            defer conn.stream.close();
            if (self.stop.load(.acquire)) return;
            // Read the request — just enough to know it's complete.
            // We read until we see "\r\n\r\n" or hit a hard cap;
            // we don't parse method/path because the echo replies
            // identically to everything.
            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                const n = conn.stream.read(buf[total..]) catch return;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
            }
            // Reply.
            var hdr_buf: [128]u8 = undefined;
            const hdr = std.fmt.bufPrint(
                &hdr_buf,
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n",
                .{self.body.len},
            ) catch return;
            conn.stream.writeAll(hdr) catch return;
            conn.stream.writeAll(self.body) catch return;
        }
    }
};

const TestCollector = struct {
    allocator: std.mem.Allocator,
    completed: usize = 0,
    last_status: u16 = 0,
    last_body: std.ArrayListUnmanaged(u8) = .empty,
    last_ok: bool = false,
    last_curl_code: c_uint = 0,
    last_content_type: ?[]u8 = null,

    fn deinit(self: *TestCollector) void {
        self.last_body.deinit(self.allocator);
        if (self.last_content_type) |s| self.allocator.free(s);
    }

    fn onDone(transfer: *Transfer, result: Result, ctx: ?*anyopaque) void {
        _ = transfer;
        const self: *TestCollector = @ptrCast(@alignCast(ctx.?));
        self.completed += 1;
        self.last_status = result.status;
        self.last_ok = result.ok;
        self.last_curl_code = result.curl_code;
        self.last_body.clearRetainingCapacity();
        self.last_body.appendSlice(self.allocator, result.body) catch {};
        if (self.last_content_type) |s| {
            self.allocator.free(s);
            self.last_content_type = null;
        }
        for (result.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
                self.last_content_type = self.allocator.dupe(u8, h.value) catch null;
                break;
            }
        }
    }
};

const ConcurrentCollector = struct {
    allocator: std.mem.Allocator,
    statuses: std.ArrayListUnmanaged(u16) = .empty,
    bodies: std.ArrayListUnmanaged([]u8) = .empty,

    fn deinit(self: *ConcurrentCollector) void {
        for (self.bodies.items) |b| self.allocator.free(b);
        self.bodies.deinit(self.allocator);
        self.statuses.deinit(self.allocator);
    }

    fn onDone(transfer: *Transfer, result: Result, ctx: ?*anyopaque) void {
        _ = transfer;
        const self: *ConcurrentCollector = @ptrCast(@alignCast(ctx.?));
        const body_dup = self.allocator.dupe(u8, result.body) catch return;
        self.statuses.append(self.allocator, result.status) catch {
            self.allocator.free(body_dup);
            return;
        };
        self.bodies.append(self.allocator, body_dup) catch {
            self.allocator.free(body_dup);
            _ = self.statuses.pop();
        };
    }
};

test "Multi: single GET round-trip" {
    const allocator = testing.allocator;
    const echo = try TestEcho.start(allocator, "hello multi");
    defer echo.stopAndJoin(allocator);

    var multi = try Multi.init(allocator);
    defer multi.deinit();

    var collector: TestCollector = .{ .allocator = allocator };
    defer collector.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/echo", .{echo.port});
    defer allocator.free(url);
    const t = try Transfer.init(allocator, .{
        .method = .GET,
        .url = url,
        .timeout_ms = 5_000,
    }, &TestCollector.onDone, &collector);
    try multi.add(t);

    // Drive until completion or deadline.
    const deadline_ns = std.time.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (collector.completed == 0 and std.time.nanoTimestamp() < deadline_ns) {
        _ = try multi.poll(50);
        _ = multi.drainCompleted();
    }

    try testing.expectEqual(@as(usize, 1), collector.completed);
    try testing.expect(collector.last_ok);
    try testing.expectEqual(@as(c_uint, c.CURLE_OK), collector.last_curl_code);
    try testing.expectEqual(@as(u16, 200), collector.last_status);
    try testing.expectEqualStrings("hello multi", collector.last_body.items);
    try testing.expect(collector.last_content_type != null);
    try testing.expectEqualStrings("text/plain", collector.last_content_type.?);
}

test "Multi: N concurrent GETs on one handle complete" {
    const allocator = testing.allocator;
    const echo = try TestEcho.start(allocator, "concurrent");
    defer echo.stopAndJoin(allocator);

    var multi = try Multi.init(allocator);
    defer multi.deinit();

    var collector: ConcurrentCollector = .{ .allocator = allocator };
    defer collector.deinit();

    const N: usize = 16;
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{echo.port});
    defer allocator.free(url);
    for (0..N) |_| {
        const t = try Transfer.init(allocator, .{
            .method = .GET,
            .url = url,
            .timeout_ms = 5_000,
        }, &ConcurrentCollector.onDone, &collector);
        try multi.add(t);
    }

    const deadline_ns = std.time.nanoTimestamp() + 10 * std.time.ns_per_s;
    while (collector.statuses.items.len < N and std.time.nanoTimestamp() < deadline_ns) {
        _ = try multi.poll(50);
        _ = multi.drainCompleted();
    }

    try testing.expectEqual(N, collector.statuses.items.len);
    for (collector.statuses.items) |s| try testing.expectEqual(@as(u16, 200), s);
    for (collector.bodies.items) |b| try testing.expectEqualStrings("concurrent", b);
}

test "Multi: cancel removes transfer without firing on_done" {
    const allocator = testing.allocator;
    // Use a destination that will hang (an unconnectable address)
    // so we can race the cancel against an in-flight transfer.
    // 127.0.0.1:1 — nothing listens there; libcurl will be in
    // connect-wait when we cancel.
    var multi = try Multi.init(allocator);
    defer multi.deinit();

    var collector: TestCollector = .{ .allocator = allocator };
    defer collector.deinit();

    const t = try Transfer.init(allocator, .{
        .method = .GET,
        .url = "http://127.0.0.1:1/",
        .timeout_ms = 30_000,
        .connect_timeout_ms = 30_000,
    }, &TestCollector.onDone, &collector);
    try multi.add(t);

    // Give libcurl one drive tick so the transfer is mid-connect.
    _ = try multi.poll(20);
    try testing.expectEqual(@as(u32, 1), multi.transfers.count());

    multi.cancel(t);
    try testing.expectEqual(@as(u32, 0), multi.transfers.count());
    // Drain shouldn't find anything.
    try testing.expectEqual(@as(usize, 0), multi.drainCompleted());
    try testing.expectEqual(@as(usize, 0), collector.completed);
}

test "runDriver: cooperative shutdown via stop_flag" {
    const allocator = testing.allocator;
    const echo = try TestEcho.start(allocator, "driven");
    defer echo.stopAndJoin(allocator);

    var multi = try Multi.init(allocator);
    defer multi.deinit();

    var collector: TestCollector = .{ .allocator = allocator };
    defer collector.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{echo.port});
    defer allocator.free(url);
    const t = try Transfer.init(allocator, .{
        .url = url,
        .timeout_ms = 5_000,
    }, &TestCollector.onDone, &collector);
    try multi.add(t);

    var stop: std.atomic.Value(bool) = .init(false);
    const drv = try std.Thread.spawn(.{}, struct {
        fn run(m: *Multi, s: *std.atomic.Value(bool)) void {
            runDriver(m, s) catch |err| std.log.warn(
                "curl_multi runDriver test: {s}", .{@errorName(err)},
            );
        }
    }.run, .{ multi, &stop });

    const deadline_ns = std.time.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (collector.completed == 0 and std.time.nanoTimestamp() < deadline_ns) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    stop.store(true, .release);
    drv.join();

    try testing.expectEqual(@as(usize, 1), collector.completed);
    try testing.expectEqual(@as(u16, 200), collector.last_status);
    try testing.expectEqualStrings("driven", collector.last_body.items);
}
