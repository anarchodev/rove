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

/// One custom-domain cert: its own `SSL_CTX` (built by `buildSslCtx`,
/// so it inherits the ALPN-h2 cb + TLS1.2-min like the default ctx)
/// plus the on-disk mtimes that drive per-host reload.
const HostEntry = struct {
    ctx: *c.SSL_CTX,
    cert_mtime: i128,
    key_mtime: i128,
};

pub const TlsConfig = struct {
    /// The default / fallback context, built from `--tls-cert`/`--tls-key`
    /// (the wildcard). Serves every connection whose SNI is absent or
    /// not in `host_store` — i.e. unchanged behavior for the common
    /// case. The servername callback only ever *overrides* this.
    ssl_ctx: *c.SSL_CTX,
    allocator: std.mem.Allocator,

    /// Custom-domain certs, keyed by exact SNI host. Read on every
    /// handshake (servername cb, worker threads — hot path), written
    /// only by the main-thread reload poll → `RwLock`, not `mu`.
    /// Keys + entry ctxs are owned. Empty (and `custom_cert_dir`
    /// null) ⇒ this whole subsystem is inert and TLS behaves exactly
    /// as before Phase 2c.
    host_store: std.StringHashMapUnmanaged(HostEntry) = .{},
    store_rw: std.Thread.RwLock = .{},
    /// `{dir}/{host}/{cert,key}.pem`. Owned. Null ⇒ no custom certs.
    custom_cert_dir: ?[]u8 = null,
    /// Operator mTLS (§3.5): PEM CA path. When non-null, EVERY ctx —
    /// the default and every per-host store entry — requires a client
    /// cert chaining to this CA (`SSL_VERIFY_PEER |
    /// FAIL_IF_NO_PEER_CERT`). Owned. Null ⇒ no client-cert demand,
    /// behavior identical to pre-2d.
    client_ca_path: ?[]u8 = null,

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
        const ssl_ctx = try buildSslCtx(cert_pem, key_pem, null);

        const cfg = try allocator.create(TlsConfig);
        cfg.* = .{ .ssl_ctx = ssl_ctx, .allocator = allocator };
        installServernameCb(ssl_ctx, cfg);
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
        client_ca_path: ?[]const u8,
    ) !*TlsConfig {
        const cert_stat = try std.fs.cwd().statFile(cert_path);
        const key_stat = try std.fs.cwd().statFile(key_path);

        const cert_pem = try std.fs.cwd().readFileAlloc(allocator, cert_path, 1024 * 1024);
        defer allocator.free(cert_pem);
        const key_pem = try std.fs.cwd().readFileAlloc(allocator, key_path, 1024 * 1024);
        defer allocator.free(key_pem);

        const ssl_ctx = try buildSslCtx(cert_pem, key_pem, client_ca_path);
        errdefer c.SSL_CTX_free(ssl_ctx);

        const cert_path_copy = try allocator.dupe(u8, cert_path);
        errdefer allocator.free(cert_path_copy);
        const key_path_copy = try allocator.dupe(u8, key_path);
        errdefer allocator.free(key_path_copy);
        const ca_copy: ?[]u8 = if (client_ca_path) |p|
            try allocator.dupe(u8, p)
        else
            null;
        errdefer if (ca_copy) |p| allocator.free(p);

        const cfg = try allocator.create(TlsConfig);
        cfg.* = .{
            .ssl_ctx = ssl_ctx,
            .allocator = allocator,
            .cert_path = cert_path_copy,
            .key_path = key_path_copy,
            .client_ca_path = ca_copy,
            .cached_cert_mtime = cert_stat.mtime,
            .cached_key_mtime = key_stat.mtime,
        };
        installServernameCb(ssl_ctx, cfg);
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

        const new_ctx = try buildSslCtx(cert_pem, key_pem, self.client_ca_path);
        // The servername cb is registered per-ctx; the rebuilt default
        // ctx needs it re-installed or SNI override stops working
        // after the first wildcard-cert renewal.
        installServernameCb(new_ctx, self);
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

    /// Block the calling thread until `stop_flag` flips, periodically
    /// calling `reloadIfChanged` on `tls_config` (when non-null) so a
    /// cert renewed on disk (e.g. by lego/certbot rewriting the PEM
    /// symlinks) gets picked up without restarting the process.
    ///
    /// Poll granularity is 50 ms, reload cadence is 1 s — cheap enough
    /// to keep running unconditionally, fast enough to surface a fresh
    /// cert within one renewal-tick. Doubles as the "block until
    /// SIGTERM" primitive each binary's main needs anyway, so the four
    /// loop46/files-server/log-server/sse-server entry points all hand
    /// off to this after their listeners are up.
    pub fn runReloadPoll(
        tls_config: ?*TlsConfig,
        stop_flag: *std.atomic.Value(bool),
    ) void {
        const reload_interval_ticks: u64 = 20; // 20 × 50ms = 1s
        var tick: u64 = 0;
        while (!stop_flag.load(.acquire)) {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            tick += 1;
            if (tls_config) |cfg| {
                if (tick % reload_interval_ticks == 0) {
                    const changed = cfg.reloadIfChanged() catch |err| blk: {
                        std.log.warn("tls: reloadIfChanged failed: {s}", .{@errorName(err)});
                        break :blk false;
                    };
                    if (changed) std.log.info("tls: cert/key reloaded", .{});
                    // Independent of the default-cert reload above
                    // (which no-ops for in-memory configs): pick up
                    // newly-issued / renewed per-host custom certs.
                    cfg.reloadCustomCerts();
                }
            }
        }
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
        {
            self.store_rw.lock();
            var it = self.host_store.iterator();
            while (it.next()) |e| {
                c.SSL_CTX_free(e.value_ptr.ctx);
                self.allocator.free(e.key_ptr.*);
            }
            self.host_store.deinit(self.allocator);
            self.store_rw.unlock();
        }
        if (self.custom_cert_dir) |p| self.allocator.free(p);
        if (self.client_ca_path) |p| self.allocator.free(p);
        if (self.cert_path) |p| self.allocator.free(p);
        if (self.key_path) |p| self.allocator.free(p);
        self.allocator.destroy(self);
    }

    /// Point the per-host store at `{dir}/{host}/{cert,key}.pem` and
    /// do an initial load. Idempotent; safe before listeners are up.
    /// When never called, `host_store` stays empty and TLS behaves
    /// exactly as it did pre-Phase-2c (default ctx for every conn).
    pub fn setCustomCertDir(self: *TlsConfig, dir: []const u8) !void {
        if (self.custom_cert_dir) |old| self.allocator.free(old);
        self.custom_cert_dir = try self.allocator.dupe(u8, dir);
        self.reloadCustomCerts();
    }

    /// Rescan `custom_cert_dir`: build a fresh `SSL_CTX` for any new
    /// host dir, rebuild one whose cert/key mtime moved, drop entries
    /// whose dir vanished. Error-tolerant by contract — it runs from
    /// the reload poll, so a single malformed host must not abort the
    /// sweep or kill the poll. Never returns an error.
    pub fn reloadCustomCerts(self: *TlsConfig) void {
        const dir = self.custom_cert_dir orelse return;
        self.reloadCustomCertsImpl(dir) catch |err|
            std.log.warn("tls: custom-cert rescan failed: {s}", .{@errorName(err)});
    }

    fn reloadCustomCertsImpl(self: *TlsConfig, dir: []const u8) !void {
        var seen: std.StringHashMapUnmanaged(void) = .{};
        defer seen.deinit(self.allocator);

        var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return, // dir not created yet — fine
            else => return err,
        };
        defer d.close();

        var it = d.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            const host = entry.name;

            var cbuf: [std.fs.max_path_bytes]u8 = undefined;
            var kbuf: [std.fs.max_path_bytes]u8 = undefined;
            const cpath = std.fmt.bufPrint(&cbuf, "{s}/{s}/cert.pem", .{ dir, host }) catch continue;
            const kpath = std.fmt.bufPrint(&kbuf, "{s}/{s}/key.pem", .{ dir, host }) catch continue;

            const cst = std.fs.cwd().statFile(cpath) catch continue; // no cert.pem yet
            const kst = std.fs.cwd().statFile(kpath) catch continue;

            try seen.put(self.allocator, host, {});

            // Up-to-date already? (read lock — cheap, off the write path)
            {
                self.store_rw.lockShared();
                const cur = self.host_store.get(host);
                self.store_rw.unlockShared();
                if (cur) |e| {
                    if (e.cert_mtime == cst.mtime and e.key_mtime == kst.mtime) continue;
                }
            }

            // Build the new ctx OUTSIDE the lock (slow: file IO + parse).
            const cpem = std.fs.cwd().readFileAlloc(self.allocator, cpath, 1024 * 1024) catch continue;
            defer self.allocator.free(cpem);
            const kpem = std.fs.cwd().readFileAlloc(self.allocator, kpath, 1024 * 1024) catch continue;
            defer self.allocator.free(kpem);
            const new_ctx = buildSslCtx(cpem, kpem, self.client_ca_path) catch |err| {
                std.log.warn("tls: custom host {s}: bad cert/key: {s}", .{ host, @errorName(err) });
                continue;
            };

            self.store_rw.lock();
            const gop = self.host_store.getOrPut(self.allocator, host) catch {
                self.store_rw.unlock();
                c.SSL_CTX_free(new_ctx);
                continue;
            };
            var old_ctx: ?*c.SSL_CTX = null;
            if (gop.found_existing) {
                old_ctx = gop.value_ptr.ctx;
            } else {
                gop.key_ptr.* = self.allocator.dupe(u8, host) catch {
                    _ = self.host_store.remove(host);
                    self.store_rw.unlock();
                    c.SSL_CTX_free(new_ctx);
                    continue;
                };
            }
            gop.value_ptr.* = .{ .ctx = new_ctx, .cert_mtime = cst.mtime, .key_mtime = kst.mtime };
            self.store_rw.unlock();
            // Drop the store's old ref. Any in-flight handshake that
            // already did SSL_set_SSL_CTX holds its own ref (that call
            // up-refs), so the ctx survives until those conns die —
            // same discipline as reloadIfChanged for the default ctx.
            if (old_ctx) |o| c.SSL_CTX_free(o);
            std.log.info("tls: custom host {s} loaded", .{host});
        }

        // Sweep: drop entries whose host dir disappeared.
        self.store_rw.lock();
        var rm: std.ArrayListUnmanaged([]const u8) = .{};
        defer rm.deinit(self.allocator);
        var sit = self.host_store.iterator();
        while (sit.next()) |e| {
            if (!seen.contains(e.key_ptr.*)) rm.append(self.allocator, e.key_ptr.*) catch {};
        }
        for (rm.items) |key| {
            if (self.host_store.fetchRemove(key)) |kv| {
                c.SSL_CTX_free(kv.value.ctx);
                self.allocator.free(kv.key);
            }
        }
        self.store_rw.unlock();
    }

    /// Register the SNI servername callback on `ctx` (per-ctx, so it
    /// must be re-applied whenever the default ctx is rebuilt). `cfg`
    /// is passed as the callback arg — a stable `*TlsConfig`.
    fn installServernameCb(ctx: *c.SSL_CTX, cfg: *TlsConfig) void {
        // SSL_CTX_set_tlsext_servername_{callback,arg} are macros over
        // SSL_CTX_callback_ctrl / SSL_CTX_ctrl; translate-c can't see
        // macros, so call the underlying ctrls with the stable tls1.h
        // command numbers (unchanged across OpenSSL 1.1.x / 3.x).
        const SSL_CTRL_SET_TLSEXT_SERVERNAME_CB: c_int = 53;
        const SSL_CTRL_SET_TLSEXT_SERVERNAME_ARG: c_int = 54;
        _ = c.SSL_CTX_callback_ctrl(
            ctx,
            SSL_CTRL_SET_TLSEXT_SERVERNAME_CB,
            @ptrCast(&servernameCb),
        );
        _ = c.SSL_CTX_ctrl(
            ctx,
            SSL_CTRL_SET_TLSEXT_SERVERNAME_ARG,
            0,
            cfg,
        );
    }

    /// Runs during ClientHello on the default ctx. If the SNI host is
    /// in the store, switch this connection to that host's ctx (its
    /// cert + chain + key). `SSL_set_SSL_CTX` up-refs the new ctx, so
    /// holding the read lock only across the lookup+switch is enough:
    /// a concurrent rescan can't free the ctx mid-switch (writer is
    /// excluded), and afterwards the SSL owns its own ref. No SNI, or
    /// unknown host → leave the default ctx (serves the wildcard).
    fn servernameCb(ssl: ?*c.SSL, al: ?*c_int, arg: ?*anyopaque) callconv(.c) c_int {
        _ = al;
        const cfg: *TlsConfig = @ptrCast(@alignCast(arg orelse return c.SSL_TLSEXT_ERR_OK));
        const s = ssl orelse return c.SSL_TLSEXT_ERR_OK;
        // TLSEXT_NAMETYPE_host_name == 0 (tls1.h; not a translate-c
        // macro). Returns NULL when the client sent no SNI.
        const name = c.SSL_get_servername(s, 0) orelse return c.SSL_TLSEXT_ERR_OK;
        const host = std.mem.span(name);

        cfg.store_rw.lockShared();
        defer cfg.store_rw.unlockShared();
        if (cfg.host_store.get(host)) |entry| {
            _ = c.SSL_set_SSL_CTX(s, entry.ctx);
        }
        return c.SSL_TLSEXT_ERR_OK;
    }

    fn buildSslCtx(
        cert_pem: []const u8,
        key_pem: []const u8,
        client_ca_path: ?[]const u8,
    ) !*c.SSL_CTX {
        const ssl_ctx = c.SSL_CTX_new(c.TLS_server_method()) orelse return error.SslCtxFailed;
        errdefer c.SSL_CTX_free(ssl_ctx);

        _ = c.SSL_CTX_set_min_proto_version(ssl_ctx, c.TLS1_2_VERSION);
        c.SSL_CTX_set_alpn_select_cb(ssl_ctx, &alpnSelectCb, null);

        // Operator mTLS (§3.5). Applied uniformly here so the default
        // ctx and every per-host store ctx demand a client cert via
        // the one code path. Connections without a cert, or with one
        // not chaining to this CA, fail the handshake (bad_certificate
        // / unknown_ca) before any application code runs.
        if (client_ca_path) |ca| {
            var pbuf: [std.fs.max_path_bytes]u8 = undefined;
            if (ca.len >= pbuf.len) return error.InvalidClientCa;
            @memcpy(pbuf[0..ca.len], ca);
            pbuf[ca.len] = 0;
            if (c.SSL_CTX_load_verify_locations(ssl_ctx, &pbuf, null) != 1)
                return error.InvalidClientCa;
            c.SSL_CTX_set_verify(
                ssl_ctx,
                c.SSL_VERIFY_PEER | c.SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
                null,
            );
        }

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
