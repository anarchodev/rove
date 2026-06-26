//! Dedicated operator-metrics HTTP/1.1 listener.
//!
//! A minimal HTTP/1.1 server that serves the latest Prometheus-text snapshot on
//! a loopback port, INDEPENDENT of the worker's io_uring/h2 request path. Two
//! reasons it is its own thread + socket rather than a route on the h2c data
//! port (:8443):
//!
//!   1. **Scrapable.** The worker data port is h2c-only (`accept_http1=false`);
//!      stock Prometheus/Alloy speak HTTP/1.1 and cannot scrape h2c. A dedicated
//!      h1 endpoint is the standard operator-metrics shape (etcd/TiKV/Go svcs).
//!   2. **Available exactly when you need it.** Operator metrics must answer
//!      *while the main request path is wedged* — that is the incident you are
//!      debugging. Running on a separate thread + socket, serving only a
//!      pre-rendered buffer, keeps `/metrics` responsive even if the h2 stack
//!      is stuck.
//!
//! This component touches NO live worker state: the worker thread renders the
//! Prometheus text (`worker_dispatch.buildMetricsText`, on the only thread that
//! may read that state) and `publish()`es the bytes here under a short mutex;
//! the listener thread only ever copies + writes those bytes. Bind it to
//! 127.0.0.1 — there is no auth (network isolation is the auth, Prometheus
//! convention); the node-local Alloy scrapes it.

const std = @import("std");
const posix = std.posix;

pub const MetricsServer = struct {
    allocator: std.mem.Allocator,
    listen_fd: posix.socket_t,
    thread: std.Thread = undefined,
    started: bool = false,
    stop: std.atomic.Value(bool) = .init(false),

    /// Guards `body` only — held for the memcpy in `publish` and the snapshot
    /// copy in `serve`. Never held across a socket write (the listener copies
    /// out, then writes), so a slow scraper can't stall the worker's publish.
    mu: std.Thread.Mutex = .{},
    body: std.ArrayListUnmanaged(u8) = .empty,

    /// Bind 127.0.0.1:`addr`, listen, and spawn the serving thread. Returns an
    /// error if the bind/listen fails — the caller treats metrics as optional
    /// (logs and runs without it). `addr` MUST be loopback (no auth here).
    pub fn init(allocator: std.mem.Allocator, addr: std.net.Address) !*MetricsServer {
        const fd = try posix.socket(
            addr.any.family,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
            0,
        );
        errdefer posix.close(fd);
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(fd, &addr.any, addr.getOsSockLen());
        try posix.listen(fd, 8);

        const self = try allocator.create(MetricsServer);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .listen_fd = fd };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        self.started = true;
        return self;
    }

    /// Replace the served snapshot. Called on the WORKER thread with freshly
    /// rendered Prometheus text; copies it under the mutex. On OOM the previous
    /// snapshot is kept (a stale scrape beats a torn one).
    pub fn publish(self: *MetricsServer, text: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        const old_len = self.body.items.len;
        self.body.clearRetainingCapacity();
        self.body.appendSlice(self.allocator, text) catch {
            // Couldn't grow — drop this update, keep nothing partial. (Capacity
            // for a typical snapshot is reached once and retained, so OOM here
            // is near-impossible after the first publish.)
            self.body.clearRetainingCapacity();
            _ = old_len;
        };
    }

    pub fn deinit(self: *MetricsServer) void {
        self.stop.store(true, .release);
        // Unblock the accept() in `run`: shut down + close the listen fd. The
        // thread sees the accept error + the stop flag and returns.
        posix.shutdown(self.listen_fd, .both) catch {};
        posix.close(self.listen_fd);
        if (self.started) self.thread.join();
        self.body.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn run(self: *MetricsServer) void {
        var scratch: std.ArrayListUnmanaged(u8) = .empty;
        defer scratch.deinit(self.allocator);
        while (!self.stop.load(.acquire)) {
            const conn = posix.accept(self.listen_fd, null, null, posix.SOCK.CLOEXEC) catch {
                if (self.stop.load(.acquire)) return;
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            };
            self.serve(conn, &scratch);
            posix.close(conn);
        }
    }

    fn serve(self: *MetricsServer, conn: posix.socket_t, scratch: *std.ArrayListUnmanaged(u8)) void {
        // We only need the request line; a bounded single read suffices for the
        // single-client, GET-only contract (Prometheus sends a tiny request).
        var req: [2048]u8 = undefined;
        const n = posix.read(conn, &req) catch return;
        if (n == 0) return;
        const want_metrics = std.mem.startsWith(u8, req[0..n], "GET /metrics") or
            std.mem.startsWith(u8, req[0..n], "GET / ");
        if (!want_metrics) {
            writeAll(conn, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            return;
        }

        // Snapshot the body under the lock, release, then write — never hold the
        // mutex across the socket write (decouples a slow scraper from publish).
        scratch.clearRetainingCapacity();
        self.mu.lock();
        const copy_ok = blk: {
            scratch.appendSlice(self.allocator, self.body.items) catch break :blk false;
            break :blk true;
        };
        self.mu.unlock();
        if (!copy_ok) {
            writeAll(conn, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            return;
        }

        var hdr: [160]u8 = undefined;
        const head = std.fmt.bufPrint(
            &hdr,
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{scratch.items.len},
        ) catch return;
        writeAll(conn, head);
        writeAll(conn, scratch.items);
    }
};

fn writeAll(fd: posix.socket_t, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const w = posix.write(fd, data[off..]) catch return;
        if (w == 0) return;
        off += w;
    }
}

// ── tests ──────────────────────────────────────────────────────────────
const testing = std.testing;

test "metrics server serves the published snapshot over HTTP/1.1" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0); // ephemeral
    const srv = MetricsServer.init(testing.allocator, addr) catch |e| {
        // No socket in the sandbox → skip rather than fail.
        if (e == error.PermissionDenied or e == error.AccessDenied) return error.SkipZigTest;
        return e;
    };
    defer srv.deinit();

    // Discover the bound port.
    var bound: std.net.Address = undefined;
    var slen: posix.socklen_t = @sizeOf(std.net.Address);
    try posix.getsockname(srv.listen_fd, &bound.any, &slen);

    srv.publish("rove_test_metric 42\n");

    const stream = try std.net.tcpConnectToAddress(bound);
    defer stream.close();
    try stream.writeAll("GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n");
    // The server writes the head and body as separate writes and closes the
    // connection (`Connection: close`); read to EOF rather than assuming one
    // read() returns the whole response (it commonly returns just the head).
    var resp: std.ArrayListUnmanaged(u8) = .empty;
    defer resp.deinit(testing.allocator);
    var buf: [512]u8 = undefined;
    while (true) {
        const n = try stream.read(&buf);
        if (n == 0) break;
        try resp.appendSlice(testing.allocator, buf[0..n]);
    }
    try testing.expect(std.mem.indexOf(u8, resp.items, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, resp.items, "rove_test_metric 42") != null);
}
