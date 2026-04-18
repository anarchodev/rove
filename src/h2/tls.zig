const std = @import("std");

const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/bio.h");
    @cInclude("openssl/x509.h");
    @cInclude("openssl/evp.h");
    @cInclude("openssl/pem.h");
});

// =============================================================================
// TLS config (user-facing)
// =============================================================================

pub const TlsConfig = struct {
    ssl_ctx: *c.SSL_CTX,
    allocator: std.mem.Allocator,

    /// Paths to the PEM files on disk. Owned. Null when the config
    /// was built via `create` (in-memory bytes) — file-path-based
    /// configs go through `createFromFiles` and get a non-null pair
    /// here, which is also the gate for `reloadIfChanged`.
    cert_path: ?[]u8 = null,
    key_path: ?[]u8 = null,

    /// Last-observed file mtimes. `reloadIfChanged` compares against
    /// these; only rebuilds the SSL_CTX when at least one has moved.
    cached_cert_mtime: i128 = 0,
    cached_key_mtime: i128 = 0,

    /// Serializes concurrent `reloadIfChanged` + `newSsl` callers
    /// across workers sharing one `TlsConfig`. The critical section
    /// is microseconds (pointer read + ref-bump on `newSsl`, or the
    /// swap on reload), so contention is negligible.
    mu: std.Thread.Mutex = .{},

    pub fn create(allocator: std.mem.Allocator, cert_pem: []const u8, key_pem: []const u8) !*TlsConfig {
        const ssl_ctx = try buildSslCtx(cert_pem, key_pem);

        const cfg = try allocator.create(TlsConfig);
        cfg.* = .{ .ssl_ctx = ssl_ctx, .allocator = allocator };
        return cfg;
    }

    /// Load the cert + key from files on disk and remember the paths
    /// for subsequent `reloadIfChanged` calls. Returns the current
    /// mtime in `cached_*_mtime` so the first `reloadIfChanged` after
    /// creation is a no-op (files haven't changed since we just read
    /// them).
    pub fn createFromFiles(
        allocator: std.mem.Allocator,
        cert_path: []const u8,
        key_path: []const u8,
    ) !*TlsConfig {
        const cert_stat = try std.fs.cwd().statFile(cert_path);
        const key_stat = try std.fs.cwd().statFile(key_path);

        const cert_pem = try std.fs.cwd().readFileAlloc(allocator, cert_path, 1024 * 1024);
        defer allocator.free(cert_pem);
        const key_pem = try std.fs.cwd().readFileAlloc(allocator, key_path, 1024 * 1024);
        defer allocator.free(key_pem);

        const ssl_ctx = try buildSslCtx(cert_pem, key_pem);
        errdefer c.SSL_CTX_free(ssl_ctx);

        const cert_path_copy = try allocator.dupe(u8, cert_path);
        errdefer allocator.free(cert_path_copy);
        const key_path_copy = try allocator.dupe(u8, key_path);
        errdefer allocator.free(key_path_copy);

        const cfg = try allocator.create(TlsConfig);
        cfg.* = .{
            .ssl_ctx = ssl_ctx,
            .allocator = allocator,
            .cert_path = cert_path_copy,
            .key_path = key_path_copy,
            .cached_cert_mtime = cert_stat.mtime,
            .cached_key_mtime = key_stat.mtime,
        };
        return cfg;
    }

    /// If `createFromFiles` was used and either PEM file's mtime has
    /// advanced since the last check, rebuild the SSL_CTX from the
    /// current on-disk bytes and atomically swap it in. In-flight
    /// `*SSL` instances hold their own ref on the old ctx (bumped by
    /// `SSL_new`), so the old ctx lives until all of its SSLs are
    /// freed. Returns `true` if a swap happened.
    ///
    /// Safe to call from any thread; internally locks the config's
    /// mutex. Callers should back off to every ~1s or so — stat() is
    /// cheap but still a syscall per call.
    pub fn reloadIfChanged(self: *TlsConfig) !bool {
        const cp = self.cert_path orelse return false;
        const kp = self.key_path orelse return false;

        const cert_stat = try std.fs.cwd().statFile(cp);
        const key_stat = try std.fs.cwd().statFile(kp);

        self.mu.lock();
        defer self.mu.unlock();

        if (cert_stat.mtime == self.cached_cert_mtime and
            key_stat.mtime == self.cached_key_mtime) return false;

        const cert_pem = try std.fs.cwd().readFileAlloc(self.allocator, cp, 1024 * 1024);
        defer self.allocator.free(cert_pem);
        const key_pem = try std.fs.cwd().readFileAlloc(self.allocator, kp, 1024 * 1024);
        defer self.allocator.free(key_pem);

        const new_ctx = try buildSslCtx(cert_pem, key_pem);
        const old_ctx = self.ssl_ctx;
        self.ssl_ctx = new_ctx;
        self.cached_cert_mtime = cert_stat.mtime;
        self.cached_key_mtime = key_stat.mtime;
        // Drop our own ref. SSL instances already spawned from
        // old_ctx each hold their own ref via `SSL_new`, so the ctx
        // hangs around until they all die.
        c.SSL_CTX_free(old_ctx);
        return true;
    }

    /// Hand out a fresh `*SSL` bound to the current ctx. Bumps the
    /// ctx's refcount before calling `SSL_new` so a concurrent
    /// `reloadIfChanged` can't free the ctx out from under us.
    pub fn newSsl(self: *TlsConfig) !*c.SSL {
        self.mu.lock();
        const ctx = self.ssl_ctx;
        _ = c.SSL_CTX_up_ref(ctx);
        self.mu.unlock();
        // Release our extra ref once SSL_new has taken its own (or
        // on failure). Either way, exactly one ref is consumed by
        // this call beyond what the Config still holds.
        defer c.SSL_CTX_free(ctx);

        return c.SSL_new(ctx) orelse error.SslNewFailed;
    }

    pub fn destroy(self: *TlsConfig) void {
        c.SSL_CTX_free(self.ssl_ctx);
        if (self.cert_path) |p| self.allocator.free(p);
        if (self.key_path) |p| self.allocator.free(p);
        self.allocator.destroy(self);
    }

    fn buildSslCtx(cert_pem: []const u8, key_pem: []const u8) !*c.SSL_CTX {
        const ssl_ctx = c.SSL_CTX_new(c.TLS_server_method()) orelse return error.SslCtxFailed;
        errdefer c.SSL_CTX_free(ssl_ctx);

        _ = c.SSL_CTX_set_min_proto_version(ssl_ctx, c.TLS1_2_VERSION);
        c.SSL_CTX_set_alpn_select_cb(ssl_ctx, &alpnSelectCb, null);

        const cbio = c.BIO_new_mem_buf(cert_pem.ptr, @intCast(cert_pem.len)) orelse return error.OutOfMemory;
        defer _ = c.BIO_free(cbio);
        // Full-chain PEMs contain multiple certs (leaf + issuer[+ issuers]).
        // `PEM_read_bio_X509` only reads the leaf; the rest get added via
        // `SSL_CTX_add_extra_chain_cert` in a follow-up loop.
        const cert = c.PEM_read_bio_X509(cbio, null, null, null) orelse return error.InvalidCert;
        defer c.X509_free(cert);

        if (c.SSL_CTX_use_certificate(ssl_ctx, cert) != 1)
            return error.InvalidCert;

        while (c.PEM_read_bio_X509(cbio, null, null, null)) |chain_cert| {
            if (c.SSL_CTX_add0_chain_cert(ssl_ctx, chain_cert) != 1) {
                c.X509_free(chain_cert);
                return error.InvalidCert;
            }
            // add0_chain_cert transfers ownership; don't X509_free here.
        }

        const kbio = c.BIO_new_mem_buf(key_pem.ptr, @intCast(key_pem.len)) orelse return error.OutOfMemory;
        defer _ = c.BIO_free(kbio);
        const key = c.PEM_read_bio_PrivateKey(kbio, null, null, null) orelse return error.InvalidKey;
        defer c.EVP_PKEY_free(key);

        if (c.SSL_CTX_use_PrivateKey(ssl_ctx, key) != 1)
            return error.InvalidKey;

        if (c.SSL_CTX_check_private_key(ssl_ctx) != 1)
            return error.KeyMismatch;

        return ssl_ctx;
    }

    fn alpnSelectCb(
        _: ?*c.SSL,
        out: [*c][*c]const u8,
        outlen: [*c]u8,
        in: [*c]const u8,
        inlen: c_uint,
        _: ?*anyopaque,
    ) callconv(.c) c_int {
        // Walk client ALPN list looking for "h2"
        var p = in;
        const end = in + inlen;
        while (@intFromPtr(p) < @intFromPtr(end)) {
            const len = p[0];
            p += 1;
            if (@intFromPtr(p) + len > @intFromPtr(end)) break;
            if (len == 2 and p[0] == 'h' and p[1] == '2') {
                out[0] = p;
                outlen[0] = 2;
                return c.SSL_TLSEXT_ERR_OK;
            }
            p += len;
        }
        return c.SSL_TLSEXT_ERR_NOACK;
    }
};

// =============================================================================
// Per-connection TLS state
// =============================================================================

pub const FeedResult = enum {
    need_more,
    handshake_done,
    data,
    err,
};

pub const TlsConn = struct {
    ssl: *c.SSL,
    handshake_complete: bool = false,
    allocator: std.mem.Allocator,

    pub fn create(config: *TlsConfig, allocator: std.mem.Allocator) !*TlsConn {
        const ssl = try config.newSsl();
        errdefer c.SSL_free(ssl);

        const rbio = c.BIO_new(c.BIO_s_mem()) orelse return error.OutOfMemory;
        const wbio = c.BIO_new(c.BIO_s_mem()) orelse {
            _ = c.BIO_free(rbio);
            return error.OutOfMemory;
        };
        c.SSL_set_bio(ssl, rbio, wbio); // SSL owns BIOs now
        c.SSL_set_accept_state(ssl);

        const tc = try allocator.create(TlsConn);
        tc.* = .{ .ssl = ssl, .allocator = allocator };
        return tc;
    }

    pub fn destroy(self: *TlsConn) void {
        c.SSL_free(self.ssl); // also frees BIOs
        self.allocator.destroy(self);
    }

    /// Feed raw TCP data. Returns decrypted application data (or handshake status).
    /// `decrypt_buf` is caller-provided scratch space.
    pub fn feed(self: *TlsConn, raw: []const u8, decrypt_buf: []u8) struct { result: FeedResult, out_len: u32 } {
        // Push raw TCP bytes into the read BIO
        if (raw.len > 0) {
            const rbio = c.SSL_get_rbio(self.ssl);
            const written = c.BIO_write(rbio, raw.ptr, @intCast(raw.len));
            if (written <= 0)
                return .{ .result = .err, .out_len = 0 };
        }

        var just_completed = false;

        // Drive handshake if not complete
        if (!self.handshake_complete) {
            const ret = c.SSL_do_handshake(self.ssl);
            if (ret == 1) {
                self.handshake_complete = true;
                just_completed = true;
            } else {
                const err = c.SSL_get_error(self.ssl, ret);
                if (err == c.SSL_ERROR_WANT_READ or err == c.SSL_ERROR_WANT_WRITE)
                    return .{ .result = .need_more, .out_len = 0 };
                return .{ .result = .err, .out_len = 0 };
            }
        }

        // Decrypt application data
        var total: u32 = 0;
        while (total < decrypt_buf.len) {
            const n = c.SSL_read(self.ssl, decrypt_buf[total..].ptr, @intCast(decrypt_buf.len - total));
            if (n > 0) {
                total += @intCast(n);
                continue;
            }
            const err = c.SSL_get_error(self.ssl, n);
            if (err == c.SSL_ERROR_WANT_READ or err == c.SSL_ERROR_ZERO_RETURN)
                break;
            return .{ .result = .err, .out_len = total };
        }

        const result: FeedResult = if (just_completed) .handshake_done else .data;
        return .{ .result = result, .out_len = total };
    }

    /// Encrypt plaintext for sending over TCP.
    pub fn encrypt(self: *TlsConn, plain: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const ret = c.SSL_write(self.ssl, plain.ptr, @intCast(plain.len));
        if (ret <= 0) return error.SslWriteFailed;

        // Drain write BIO → ciphertext
        const wbio = c.SSL_get_wbio(self.ssl);
        const pending: usize = @intCast(c.BIO_ctrl_pending(wbio));
        if (pending == 0) return &.{};

        const buf = try allocator.alloc(u8, pending);
        const n = c.BIO_read(wbio, buf.ptr, @intCast(pending));
        if (n <= 0) {
            allocator.free(buf);
            return error.BioReadFailed;
        }

        return buf[0..@intCast(n)];
    }

    /// Drain any pending handshake output (to send to client).
    pub fn drainOutput(self: *TlsConn, allocator: std.mem.Allocator) !?[]u8 {
        const wbio = c.SSL_get_wbio(self.ssl);
        const pending: usize = @intCast(c.BIO_ctrl_pending(wbio));
        if (pending == 0) return null;

        const buf = try allocator.alloc(u8, pending);
        const n = c.BIO_read(wbio, buf.ptr, @intCast(pending));
        if (n <= 0) {
            allocator.free(buf);
            return null;
        }

        return buf[0..@intCast(n)];
    }
};
