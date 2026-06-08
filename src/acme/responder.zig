//! Dedicated HTTP/1.1 :80 responder for ACME HTTP-01 challenges.
//!
//! Deliberately tiny and isolated from the h2 stack (auth-domain-plan
//! §3.2): a blocking accept loop on its own thread, an in-memory
//! `token → keyAuthorization` map, and exactly one route —
//! `GET /.well-known/acme-challenge/{token}` → the key authorization.
//! No TLS, no nghttp2, no OpenSSL. Everything else is 404.
//!
//! The ACME client publishes a token before asking the CA to
//! validate and clears it after; only the leader's client populates
//! the map (see src/loop46 orchestration). Graceful shutdown polls a
//! shared stop flag so `accept` never wedges teardown.

const std = @import("std");
const posix = std.posix;

pub const Responder = struct {
    allocator: std.mem.Allocator,
    mu: std.Thread.Mutex = .{},
    tokens: std.StringHashMapUnmanaged([]u8) = .{},
    stop: *std.atomic.Value(bool),
    port: u16,
    thread: ?std.Thread = null,
    listen_fd: posix.socket_t = -1,

    pub fn init(
        allocator: std.mem.Allocator,
        stop: *std.atomic.Value(bool),
        port: u16,
    ) Responder {
        return .{ .allocator = allocator, .stop = stop, .port = port };
    }

    /// Publish `token → keyauth`. Overwrites a prior value for the
    /// same token. Both are copied.
    pub fn put(self: *Responder, token: []const u8, keyauth: []const u8) !void {
        const k = try self.allocator.dupe(u8, token);
        errdefer self.allocator.free(k);
        const v = try self.allocator.dupe(u8, keyauth);
        errdefer self.allocator.free(v);
        self.mu.lock();
        defer self.mu.unlock();
        const gop = try self.tokens.getOrPut(self.allocator, k);
        if (gop.found_existing) {
            self.allocator.free(k);
            self.allocator.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = k;
        }
        gop.value_ptr.* = v;
    }

    /// Copy out the key-authorization for `token` (owned; caller frees), or
    /// null if not published. For deployments where the `:80` challenge is
    /// served by a *separate* front door that reads this in-memory map (the V2
    /// CP issuer) instead of this struct's built-in accept loop — the map +
    /// `put`/`remove` are reused without ever `start()`ing the socket.
    pub fn getOwned(self: *Responder, a: std.mem.Allocator, token: []const u8) ?[]u8 {
        self.mu.lock();
        defer self.mu.unlock();
        const v = self.tokens.get(token) orelse return null;
        return a.dupe(u8, v) catch null;
    }

    pub fn remove(self: *Responder, token: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.tokens.fetchRemove(token)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    /// Bind + spawn the accept loop. Caller `join`s at shutdown
    /// (after flipping `stop`).
    pub fn start(self: *Responder) !void {
        const fd = try posix.socket(
            posix.AF.INET,
            posix.SOCK.STREAM,
            posix.IPPROTO.TCP,
        );
        errdefer posix.close(fd);
        try posix.setsockopt(
            fd,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            &std.mem.toBytes(@as(c_int, 1)),
        );
        const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, self.port);
        try posix.bind(fd, &addr.any, addr.getOsSockLen());
        try posix.listen(fd, 64);
        self.listen_fd = fd;
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    pub fn join(self: *Responder) void {
        if (self.thread) |t| t.join();
        if (self.listen_fd != -1) posix.close(self.listen_fd);
        self.mu.lock();
        var it = self.tokens.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.tokens.deinit(self.allocator);
        self.mu.unlock();
    }

    fn loop(self: *Responder) void {
        var pfd = [_]posix.pollfd{.{
            .fd = self.listen_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        while (!self.stop.load(.acquire)) {
            // 500 ms timeout → shutdown is responsive without a
            // self-connect trick.
            const n = posix.poll(&pfd, 500) catch continue;
            if (n == 0) continue;
            const conn = posix.accept(self.listen_fd, null, null, 0) catch continue;
            self.handle(conn);
            posix.close(conn);
        }
    }

    fn handle(self: *Responder, conn: posix.socket_t) void {
        var buf: [2048]u8 = undefined;
        const n = posix.read(conn, &buf) catch return;
        if (n == 0) return;
        const req = buf[0..n];
        // First line: METHOD SP path SP HTTP/x
        const line_end = std.mem.indexOfScalar(u8, req, '\r') orelse req.len;
        const line = req[0..line_end];
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const method = it.next() orelse return;
        const path = it.next() orelse return;

        const prefix = "/.well-known/acme-challenge/";
        if (std.mem.eql(u8, method, "GET") and
            std.mem.startsWith(u8, path, prefix))
        {
            const token = path[prefix.len..];
            self.mu.lock();
            const ka = self.tokens.get(token);
            std.log.info("acme-responder: challenge {s} → {s}", .{
                token, if (ka != null) "HIT" else "MISS",
            });
            // Copy out under lock so the socket write doesn't hold it.
            var stackbuf: [512]u8 = undefined;
            const body: ?[]const u8 = if (ka) |v| blk: {
                if (v.len > stackbuf.len) break :blk null;
                @memcpy(stackbuf[0..v.len], v);
                break :blk stackbuf[0..v.len];
            } else null;
            self.mu.unlock();
            if (body) |b| {
                writeAll(conn, "HTTP/1.1 200 OK\r\nContent-Type: " ++
                    "application/octet-stream\r\nConnection: close\r\n" ++
                    "Content-Length: ");
                var lb: [20]u8 = undefined;
                const ls = std.fmt.bufPrint(&lb, "{d}", .{b.len}) catch return;
                writeAll(conn, ls);
                writeAll(conn, "\r\n\r\n");
                writeAll(conn, b);
                return;
            }
        }
        writeAll(conn, "HTTP/1.1 404 Not Found\r\nConnection: close\r\n" ++
            "Content-Length: 0\r\n\r\n");
    }

    fn writeAll(conn: posix.socket_t, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const w = posix.write(conn, bytes[off..]) catch return;
            if (w == 0) return;
            off += w;
        }
    }
};

test "responder serves a published token, 404s otherwise" {
    const a = std.testing.allocator;
    var stop = std.atomic.Value(bool).init(false);
    var r = Responder.init(a, &stop, 0); // port 0 → ephemeral
    try r.start();
    defer {
        stop.store(true, .release);
        r.join();
    }
    // Discover the bound port.
    var sa: posix.sockaddr.in = undefined;
    var slen: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(r.listen_fd, @ptrCast(&sa), &slen);
    const port = std.mem.bigToNative(u16, sa.port);

    try r.put("tok123", "tok123.thumbprint");

    const do_get = struct {
        fn f(p: u16, path: []const u8, out: []u8) ![]u8 {
            const s = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
            defer posix.close(s);
            const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, p);
            try posix.connect(s, &addr.any, addr.getOsSockLen());
            var rb: [256]u8 = undefined;
            const req = try std.fmt.bufPrint(&rb, "GET {s} HTTP/1.1\r\nHost: x\r\n\r\n", .{path});
            _ = try posix.write(s, req);
            var total: usize = 0;
            while (total < out.len) {
                const n = try posix.read(s, out[total..]);
                if (n == 0) break; // server sent Connection: close
                total += n;
            }
            return out[0..total];
        }
    }.f;

    var ob: [512]u8 = undefined;
    const hit = try do_get(port, "/.well-known/acme-challenge/tok123", &ob);
    try std.testing.expect(std.mem.indexOf(u8, hit, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, hit, "tok123.thumbprint") != null);

    var ob2: [512]u8 = undefined;
    const miss = try do_get(port, "/.well-known/acme-challenge/nope", &ob2);
    try std.testing.expect(std.mem.indexOf(u8, miss, "404") != null);
}
