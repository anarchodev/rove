//! Shared crypto mechanism for the `crypto.*` binding surfaces.
//!
//! The JOSE/OIDC surface (`crypto_jose.zig`) and the raw-key ECDSA
//! surface (`crypto_ecdsa.zig`) differ in *policy* — curve set, digest
//! choice, low-S enforcement, key encoding — but share the same
//! OpenSSL *mechanism*: build an EVP_PKEY from EC key material, convert
//! between raw R‖S and ASN.1 DER, and run EVP digest-verify. Those live
//! here so the policy surfaces stay thin and the EVP boilerplate exists
//! once (it was hand-inlined in three verify paths before this).

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;

pub const ssl = @cImport({
    @cInclude("openssl/evp.h");
    @cInclude("openssl/rsa.h");
    @cInclude("openssl/bn.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/core_names.h");
    @cInclude("openssl/param_build.h");
    @cInclude("openssl/pem.h");
    @cInclude("openssl/bio.h");
});

// ── Digest selection ────────────────────────────────────────────────

pub fn mdForAlg(alg: []const u8) ?*const ssl.EVP_MD {
    if (std.ascii.eqlIgnoreCase(alg, "sha256")) return ssl.EVP_sha256();
    if (std.ascii.eqlIgnoreCase(alg, "sha384")) return ssl.EVP_sha384();
    if (std.ascii.eqlIgnoreCase(alg, "sha512")) return ssl.EVP_sha512();
    return null;
}

// ── EVP_PKEY construction from EC key material ──────────────────────

/// Build an EC public-key EVP_PKEY from an OpenSSL group name + a SEC1
/// point (compressed or uncompressed). Used by both verify surfaces
/// (JOSE builds the uncompressed point from JWK x/y; atproto passes the
/// did:key SEC1 bytes directly).
pub fn ecPubKeyFromPoint(group: []const u8, point: []const u8) error{Ossl}!*ssl.EVP_PKEY {
    const bld = ssl.OSSL_PARAM_BLD_new() orelse return error.Ossl;
    defer ssl.OSSL_PARAM_BLD_free(bld);
    if (ssl.OSSL_PARAM_BLD_push_utf8_string(bld, "group", group.ptr, group.len) == 0 or
        ssl.OSSL_PARAM_BLD_push_octet_string(bld, "pub", point.ptr, point.len) == 0)
        return error.Ossl;
    const params = ssl.OSSL_PARAM_BLD_to_param(bld) orelse return error.Ossl;
    defer ssl.OSSL_PARAM_free(params);
    const pctx = ssl.EVP_PKEY_CTX_new_from_name(null, "EC", null) orelse return error.Ossl;
    defer ssl.EVP_PKEY_CTX_free(pctx);
    if (ssl.EVP_PKEY_fromdata_init(pctx) <= 0) return error.Ossl;
    var pkey: ?*ssl.EVP_PKEY = null;
    if (ssl.EVP_PKEY_fromdata(pctx, &pkey, ssl.EVP_PKEY_PUBLIC_KEY, params) <= 0 or pkey == null)
        return error.Ossl;
    return pkey.?;
}

/// Build an EC keypair EVP_PKEY from a raw private scalar (OpenSSL
/// derives the public half). Used by the atproto sign path.
pub fn ecKeypairFromScalar(group: []const u8, priv: []const u8) error{Ossl}!*ssl.EVP_PKEY {
    const bld = ssl.OSSL_PARAM_BLD_new() orelse return error.Ossl;
    defer ssl.OSSL_PARAM_BLD_free(bld);
    if (ssl.OSSL_PARAM_BLD_push_utf8_string(bld, "group", group.ptr, group.len) == 0)
        return error.Ossl;
    const priv_bn = ssl.BN_bin2bn(priv.ptr, @intCast(priv.len), null) orelse return error.Ossl;
    defer ssl.BN_free(priv_bn);
    if (ssl.OSSL_PARAM_BLD_push_BN(bld, "priv", priv_bn) == 0) return error.Ossl;
    const params = ssl.OSSL_PARAM_BLD_to_param(bld) orelse return error.Ossl;
    defer ssl.OSSL_PARAM_free(params);
    const pctx = ssl.EVP_PKEY_CTX_new_from_name(null, "EC", null) orelse return error.Ossl;
    defer ssl.EVP_PKEY_CTX_free(pctx);
    if (ssl.EVP_PKEY_fromdata_init(pctx) <= 0) return error.Ossl;
    var pkey: ?*ssl.EVP_PKEY = null;
    if (ssl.EVP_PKEY_fromdata(pctx, &pkey, ssl.EVP_PKEY_KEYPAIR, params) <= 0 or pkey == null)
        return error.Ossl;
    return pkey.?;
}

// ── Digest verify ───────────────────────────────────────────────────

/// Run a one-shot EVP digest-verify: `init → update(data) → final(sig)`.
/// `sig` is whatever bytes `EVP_DigestVerifyFinal` expects for the key —
/// raw PKCS#1 v1.5 for RSA, DER `SEQUENCE{r,s}` for ECDSA. Returns true
/// iff the signature verifies; `error.Ossl` on a setup failure (which
/// callers surface as an internal error, matching the prior inline
/// paths). Replaces the verify boilerplate that was inlined in
/// verifyRsa / verifyEcdsa / ecdsaVerify.
pub fn evpDigestVerify(
    md: ?*const ssl.EVP_MD,
    pkey: *ssl.EVP_PKEY,
    data: []const u8,
    sig: []const u8,
) error{Ossl}!bool {
    const md_ctx = ssl.EVP_MD_CTX_new() orelse return error.Ossl;
    defer ssl.EVP_MD_CTX_free(md_ctx);
    if (ssl.EVP_DigestVerifyInit(md_ctx, null, md, null, pkey) <= 0) return error.Ossl;
    if (ssl.EVP_DigestVerifyUpdate(md_ctx, data.ptr, data.len) <= 0) return error.Ossl;
    // 1 = valid, 0 = invalid signature, <0 = error. Invalid + error both
    // map to `false` — a customer can't act on the distinction, and it
    // matches Web Crypto's SubtleCrypto.verify() (resolves false on both).
    return ssl.EVP_DigestVerifyFinal(md_ctx, sig.ptr, sig.len) == 1;
}

// ── ECDSA raw R‖S ↔ ASN.1 DER ───────────────────────────────────────

const TrimmedInt = struct {
    body: []const u8,
    needs_pad: bool,
};

fn trimToInteger(raw: []const u8) TrimmedInt {
    var i: usize = 0;
    while (i < raw.len and raw[i] == 0) i += 1;
    if (i == raw.len) {
        // All zeros — represent as a single 0 byte.
        return .{ .body = raw[raw.len - 1 ..], .needs_pad = false };
    }
    const trimmed = raw[i..];
    return .{ .body = trimmed, .needs_pad = (trimmed[0] & 0x80) != 0 };
}

/// Build the DER encoding of an ECDSA-SIG into `out`. Input is the raw
/// R‖S concatenation — this handles the ASN.1 INTEGER rules: strip
/// leading zeros from each component, then prepend a 0x00 if the high
/// bit of the first remaining byte is set (so the integer stays
/// positive). Returns the bytes written. `error.BufferTooSmall` when
/// `out` can't hold the result (callers size at 80/256).
///
/// Hand-built (vs <openssl/ecdsa.h>) to avoid header-macro translation
/// errors with our toolchain; ECDSA-SIG DER is short + fully spec'd.
pub fn encodeEcdsaSigDer(out: []u8, r: []const u8, s: []const u8) ![]const u8 {
    const r_int = trimToInteger(r);
    const s_int = trimToInteger(s);
    // Each INTEGER: 1 (tag) + 1 (len, all real-world ECDSA fits in a
    // single length byte ≤127) + payload + extra-zero prefix if needed.
    const r_len = r_int.body.len + @as(usize, if (r_int.needs_pad) 1 else 0);
    const s_len = s_int.body.len + @as(usize, if (s_int.needs_pad) 1 else 0);
    if (r_len > 127 or s_len > 127) return error.BufferTooSmall;

    const seq_content_len = 2 + r_len + 2 + s_len;
    // SEQUENCE length: single byte if ≤127, else 0x81 + 1 byte.
    const seq_header_len: usize = if (seq_content_len <= 127) 2 else 3;
    const total_len = seq_header_len + seq_content_len;
    if (total_len > out.len) return error.BufferTooSmall;

    var pos: usize = 0;
    out[pos] = 0x30; // SEQUENCE tag
    pos += 1;
    if (seq_content_len <= 127) {
        out[pos] = @intCast(seq_content_len);
        pos += 1;
    } else {
        out[pos] = 0x81;
        out[pos + 1] = @intCast(seq_content_len);
        pos += 2;
    }
    // R as INTEGER.
    out[pos] = 0x02; // INTEGER tag
    out[pos + 1] = @intCast(r_len);
    pos += 2;
    if (r_int.needs_pad) {
        out[pos] = 0x00;
        pos += 1;
    }
    @memcpy(out[pos .. pos + r_int.body.len], r_int.body);
    pos += r_int.body.len;
    // S as INTEGER.
    out[pos] = 0x02;
    out[pos + 1] = @intCast(s_len);
    pos += 2;
    if (s_int.needs_pad) {
        out[pos] = 0x00;
        pos += 1;
    }
    @memcpy(out[pos .. pos + s_int.body.len], s_int.body);
    pos += s_int.body.len;
    return out[0..pos];
}

/// Parse a DER `SEQUENCE { INTEGER r, INTEGER s }` (what OpenSSL's
/// EVP_DigestSign emits for ECDSA) into fixed 32-byte big-endian r/s,
/// stripping the ASN.1 sign byte and left-padding short values.
pub fn parseEcdsaSigDer(der: []const u8, r: *[32]u8, s: *[32]u8) !void {
    if (der.len < 8 or der[0] != 0x30) return error.BadDer;
    var p: usize = 2; // skip SEQ tag + (single-byte) length
    if (der[1] & 0x80 != 0) p = 2 + (der[1] & 0x7f); // long-form len
    inline for (.{ r, s }) |dst| {
        if (p + 2 > der.len or der[p] != 0x02) return error.BadDer;
        var len: usize = der[p + 1];
        p += 2;
        if (p + len > der.len) return error.BadDer;
        var body = der[p .. p + len];
        p += len;
        while (body.len > 0 and body[0] == 0x00) body = body[1..]; // sign pad
        if (body.len > 32) return error.BadDer;
        @memset(dst, 0);
        @memcpy(dst[32 - body.len ..], body);
        _ = &len;
    }
}

// ── base64url + misc ────────────────────────────────────────────────

pub const B64URL = std.base64.url_safe_no_pad;

pub fn b64urlEnc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, B64URL.Encoder.calcSize(bytes.len));
    _ = B64URL.Encoder.encode(out, bytes);
    return out;
}

/// Decode URL-safe base64 (no padding) to bytes. Tolerates the standard
/// alphabet (+/) on input too. Used to unpack JWK n/e/x/y fields.
pub fn base64urlDecode(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    // Strip whitespace + padding; build a clean string.
    var clean: std.ArrayListUnmanaged(u8) = .empty;
    defer clean.deinit(allocator);
    for (src) |b| switch (b) {
        '=', ' ', '\n', '\r', '\t' => {},
        else => try clean.append(allocator, b),
    };
    const out_len: usize = (clean.items.len * 3) / 4;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    var oi: usize = 0;
    var i: usize = 0;
    while (i + 3 < clean.items.len) : (i += 4) {
        const v0 = b64Lookup(clean.items[i]) orelse return error.InvalidBase64;
        const v1 = b64Lookup(clean.items[i + 1]) orelse return error.InvalidBase64;
        const v2 = b64Lookup(clean.items[i + 2]) orelse return error.InvalidBase64;
        const v3 = b64Lookup(clean.items[i + 3]) orelse return error.InvalidBase64;
        out[oi] = (v0 << 2) | (v1 >> 4);
        out[oi + 1] = ((v1 & 0x0f) << 4) | (v2 >> 2);
        out[oi + 2] = ((v2 & 0x03) << 6) | v3;
        oi += 3;
    }
    const tail = clean.items.len - i;
    if (tail == 2) {
        const v0 = b64Lookup(clean.items[i]) orelse return error.InvalidBase64;
        const v1 = b64Lookup(clean.items[i + 1]) orelse return error.InvalidBase64;
        out[oi] = (v0 << 2) | (v1 >> 4);
        oi += 1;
    } else if (tail == 3) {
        const v0 = b64Lookup(clean.items[i]) orelse return error.InvalidBase64;
        const v1 = b64Lookup(clean.items[i + 1]) orelse return error.InvalidBase64;
        const v2 = b64Lookup(clean.items[i + 2]) orelse return error.InvalidBase64;
        out[oi] = (v0 << 2) | (v1 >> 4);
        out[oi + 1] = ((v1 & 0x0f) << 4) | (v2 >> 2);
        oi += 2;
    } else if (tail == 1) {
        return error.InvalidBase64;
    }
    return allocator.realloc(out, oi) catch out;
}

fn b64Lookup(ch: u8) ?u8 {
    return switch (ch) {
        'A'...'Z' => ch - 'A',
        'a'...'z' => ch - 'a' + 26,
        '0'...'9' => ch - '0' + 52,
        '+', '-' => 62,
        '/', '_' => 63,
        else => null,
    };
}

/// Drain a memory BIO into an owned byte slice.
pub fn bioDrain(allocator: std.mem.Allocator, bio: *ssl.BIO) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = ssl.BIO_read(bio, &tmp, @as(c_int, tmp.len));
        if (n <= 0) break;
        try list.appendSlice(allocator, tmp[0..@intCast(n)]);
    }
    return list.toOwnedSlice(allocator);
}

/// Read a string property off a JS object and dupe to allocator-owned
/// bytes. Returns null when the property is absent / null / undefined;
/// `error.JsException` when the property exists but isn't a string
/// (sets the QJS exception slot).
pub fn jsObjStringField(
    ctx: ?*c.JSContext,
    a: std.mem.Allocator,
    obj: c.JSValue,
    name: [:0]const u8,
) !?[]u8 {
    const v = c.JS_GetPropertyStr(ctx, obj, name.ptr);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v) or c.JS_IsNull(v)) return null;
    if (!c.JS_IsString(v)) {
        _ = c.JS_ThrowTypeError(ctx, "jwk field must be a string");
        return error.JsException;
    }
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, v);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    return try a.dupe(u8, @as([*]const u8, @ptrCast(cstr))[0..len]);
}
