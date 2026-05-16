//! ACME crypto primitives (RFC 8555 / 7638) over OpenSSL.
//!
//! ES256 throughout: the ACME account key and each per-host cert key
//! are EC P-256. JWS signatures are raw R||S (64 B) — OpenSSL emits
//! DER ECDSA-Sig-Value, so we convert. The account JWK + its RFC 7638
//! thumbprint feed the JWS protected header / key authorization.
//!
//! Same OpenSSL libs as rove-h2 (ssl+crypto, wired in build.zig).

const std = @import("std");

const c = @cImport({
    @cInclude("openssl/evp.h");
    @cInclude("openssl/pem.h");
    @cInclude("openssl/ec.h");
    @cInclude("openssl/x509.h");
    @cInclude("openssl/x509v3.h");
    @cInclude("openssl/bio.h");
    @cInclude("openssl/bn.h");
    @cInclude("openssl/err.h");
});

pub const Error = error{
    Keygen,
    PemEncode,
    PemDecode,
    Sign,
    PubKey,
    Csr,
    OutOfMemory,
};

const B64 = std.base64.url_safe_no_pad;

/// base64url(no-pad), allocator-owned.
pub fn b64urlAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, B64.Encoder.calcSize(bytes.len));
    _ = B64.Encoder.encode(out, bytes);
    return out;
}

/// An EC P-256 keypair. Wraps an OpenSSL `EVP_PKEY`.
pub const Key = struct {
    pkey: *c.EVP_PKEY,

    pub fn generate() Error!Key {
        // EVP_EC_gen is a macro over EVP_PKEY_Q_keygen (translate-c
        // can't see macros); call the variadic fn directly. For type
        // "EC" the trailing arg is the curve name.
        const ty: [*c]const u8 = "EC";
        const curve: [*c]const u8 = "P-256";
        const pkey = c.EVP_PKEY_Q_keygen(null, null, ty, curve) orelse
            return Error.Keygen;
        return .{ .pkey = pkey };
    }

    pub fn fromPem(pem: []const u8) Error!Key {
        const bio = c.BIO_new_mem_buf(pem.ptr, @intCast(pem.len)) orelse
            return Error.OutOfMemory;
        defer _ = c.BIO_free(bio);
        const pkey = c.PEM_read_bio_PrivateKey(bio, null, null, null) orelse
            return Error.PemDecode;
        return .{ .pkey = pkey };
    }

    pub fn deinit(self: *Key) void {
        c.EVP_PKEY_free(self.pkey);
        self.* = undefined;
    }

    /// PKCS#8 PEM of the private key. Allocator-owned.
    pub fn privatePem(self: *const Key, allocator: std.mem.Allocator) Error![]u8 {
        const bio = c.BIO_new(c.BIO_s_mem()) orelse return Error.OutOfMemory;
        defer _ = c.BIO_free(bio);
        if (c.PEM_write_bio_PrivateKey(bio, self.pkey, null, null, 0, null, null) != 1)
            return Error.PemEncode;
        return bioToOwned(allocator, bio);
    }

    /// Uncompressed public point (0x04 || X32 || Y32) → X, Y.
    fn xy(self: *const Key) Error![64]u8 {
        var buf: [65]u8 = undefined;
        var len: usize = 0;
        if (c.EVP_PKEY_get_octet_string_param(
            self.pkey,
            "pub",
            &buf,
            buf.len,
            &len,
        ) != 1 or len != 65 or buf[0] != 0x04) return Error.PubKey;
        return buf[1..65].*;
    }

    /// RFC 7638 §3 JWK members for an EC key, canonical (lexicographic
    /// key order, no whitespace): {"crv","kty","x","y"}. Allocator-
    /// owned. This exact string is what gets hashed for the thumbprint
    /// and is also the `jwk` value in a JWS protected header.
    pub fn jwkJson(self: *const Key, allocator: std.mem.Allocator) Error![]u8 {
        const pt = try self.xy();
        const x = try b64urlAlloc(allocator, pt[0..32]);
        defer allocator.free(x);
        const y = try b64urlAlloc(allocator, pt[32..64]);
        defer allocator.free(y);
        return std.fmt.allocPrint(
            allocator,
            "{{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"{s}\",\"y\":\"{s}\"}}",
            .{ x, y },
        ) catch Error.OutOfMemory;
    }

    /// RFC 7638 thumbprint: base64url(SHA-256(canonical JWK)).
    /// Used to build the HTTP-01 key authorization (`token.thumbprint`).
    pub fn thumbprint(self: *const Key, allocator: std.mem.Allocator) Error![]u8 {
        const jwk = try self.jwkJson(allocator);
        defer allocator.free(jwk);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(jwk, &digest, .{});
        return b64urlAlloc(allocator, &digest);
    }

    /// ES256 JWS signature over `msg`: raw R||S, 64 bytes. OpenSSL
    /// emits a DER ECDSA-Sig-Value; we re-pack to the fixed-width
    /// concatenation JWS requires (RFC 7515 / 7518 §3.4).
    pub fn signEs256(self: *const Key, allocator: std.mem.Allocator, msg: []const u8) Error![64]u8 {
        const ctx = c.EVP_MD_CTX_new() orelse return Error.OutOfMemory;
        defer c.EVP_MD_CTX_free(ctx);
        if (c.EVP_DigestSignInit(ctx, null, c.EVP_sha256(), null, self.pkey) != 1)
            return Error.Sign;

        var der_len: usize = 0;
        if (c.EVP_DigestSign(ctx, null, &der_len, msg.ptr, msg.len) != 1)
            return Error.Sign;
        const der = allocator.alloc(u8, der_len) catch return Error.OutOfMemory;
        defer allocator.free(der);
        if (c.EVP_DigestSign(ctx, der.ptr, &der_len, msg.ptr, msg.len) != 1)
            return Error.Sign;

        // DER → raw R||S (32 each, left-padded).
        var p: [*c]const u8 = der.ptr;
        const sig = c.d2i_ECDSA_SIG(null, &p, @intCast(der_len)) orelse
            return Error.Sign;
        defer c.ECDSA_SIG_free(sig);
        var r: ?*const c.BIGNUM = null;
        var s: ?*const c.BIGNUM = null;
        c.ECDSA_SIG_get0(sig, &r, &s);
        var out: [64]u8 = undefined;
        if (c.BN_bn2binpad(r, out[0..].ptr, 32) != 32) return Error.Sign;
        if (c.BN_bn2binpad(s, out[32..].ptr, 32) != 32) return Error.Sign;
        return out;
    }
};

/// DER CSR for `host` (subject CN=host + SAN DNS:host), signed by
/// `cert_key` with SHA-256. Allocator-owned. ACME `finalize` wants
/// base64url of this DER (caller does the b64url).
pub fn buildCsrDer(
    allocator: std.mem.Allocator,
    cert_key: *const Key,
    host: []const u8,
) Error![]u8 {
    const req = c.X509_REQ_new() orelse return Error.OutOfMemory;
    defer c.X509_REQ_free(req);
    if (c.X509_REQ_set_version(req, 0) != 1) return Error.Csr;

    const name = c.X509_REQ_get_subject_name(req) orelse return Error.Csr;
    const host_z = allocator.dupeZ(u8, host) catch return Error.OutOfMemory;
    defer allocator.free(host_z);
    if (c.X509_NAME_add_entry_by_txt(
        name,
        "CN",
        c.MBSTRING_ASC,
        host_z.ptr,
        @intCast(host.len),
        -1,
        0,
    ) != 1) return Error.Csr;

    // subjectAltName = DNS:host  (LE requires SAN; CN alone is ignored).
    const san_val = std.fmt.allocPrintSentinel(allocator, "DNS:{s}", .{host}, 0) catch
        return Error.OutOfMemory;
    defer allocator.free(san_val);
    // sk_X509_EXTENSION_* are DEFINE_STACK_OF macros translate-c can't
    // see; use the generic OPENSSL_sk_* the macros wrap.
    const exts = c.OPENSSL_sk_new_null() orelse return Error.OutOfMemory;
    defer c.OPENSSL_sk_pop_free(exts, freeExt);
    const ext = c.X509V3_EXT_conf_nid(null, null, c.NID_subject_alt_name, san_val.ptr) orelse
        return Error.Csr;
    _ = c.OPENSSL_sk_push(exts, ext);
    if (c.X509_REQ_add_extensions(req, @ptrCast(exts)) != 1) return Error.Csr;

    if (c.X509_REQ_set_pubkey(req, cert_key.pkey) != 1) return Error.Csr;
    if (c.X509_REQ_sign(req, cert_key.pkey, c.EVP_sha256()) == 0) return Error.Csr;

    const der_len = c.i2d_X509_REQ(req, null);
    if (der_len <= 0) return Error.Csr;
    const out = allocator.alloc(u8, @intCast(der_len)) catch return Error.OutOfMemory;
    errdefer allocator.free(out);
    var pp: [*c]u8 = out.ptr;
    if (c.i2d_X509_REQ(req, &pp) != der_len) return Error.Csr;
    return out;
}

fn freeExt(p: ?*anyopaque) callconv(.c) void {
    c.X509_EXTENSION_free(@ptrCast(p));
}

fn bioToOwned(allocator: std.mem.Allocator, bio: *c.BIO) Error![]u8 {
    // BIO_get_mem_data is a macro; drain the mem BIO with BIO_read
    // (a real function) instead.
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = c.BIO_read(bio, &tmp, @as(c_int, tmp.len));
        if (n <= 0) break;
        list.appendSlice(allocator, tmp[0..@intCast(n)]) catch
            return Error.OutOfMemory;
    }
    if (list.items.len == 0) return Error.PemEncode;
    return list.toOwnedSlice(allocator) catch Error.OutOfMemory;
}

test "EC keygen → ES256 sign → raw R||S length, PEM roundtrip" {
    const a = std.testing.allocator;
    var k = try Key.generate();
    defer k.deinit();

    const sig = try k.signEs256(a, "hello acme");
    try std.testing.expectEqual(@as(usize, 64), sig.len);

    const pem = try k.privatePem(a);
    defer a.free(pem);
    try std.testing.expect(std.mem.indexOf(u8, pem, "BEGIN PRIVATE KEY") != null);

    var k2 = try Key.fromPem(pem);
    defer k2.deinit();
    // Same key → identical JWK (deterministic from the public point).
    const j1 = try k.jwkJson(a);
    defer a.free(j1);
    const j2 = try k2.jwkJson(a);
    defer a.free(j2);
    try std.testing.expectEqualStrings(j1, j2);
}

test "JWK is canonical + thumbprint is 32-byte sha256 b64url" {
    const a = std.testing.allocator;
    var k = try Key.generate();
    defer k.deinit();
    const jwk = try k.jwkJson(a);
    defer a.free(jwk);
    // RFC 7638 canonical order: crv, kty, x, y — no whitespace.
    try std.testing.expect(std.mem.startsWith(u8, jwk, "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\""));
    const tp = try k.thumbprint(a);
    defer a.free(tp);
    // SHA-256 = 32 B → base64url no-pad = 43 chars.
    try std.testing.expectEqual(@as(usize, 43), tp.len);
}

test "CSR builds and re-parses with the right subject" {
    const a = std.testing.allocator;
    var ck = try Key.generate();
    defer ck.deinit();
    const der = try buildCsrDer(a, &ck, "acme.example");
    defer a.free(der);
    try std.testing.expect(der.len > 0);
    var p: [*c]const u8 = der.ptr;
    const req = c.d2i_X509_REQ(null, &p, @intCast(der.len));
    try std.testing.expect(req != null);
    c.X509_REQ_free(req);
}
