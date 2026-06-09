//! Raw-key ECDSA bindings for atproto / did:key (`project_fediverse_libs`).
//!
//! Policy distinct from the JOSE surface (`crypto_jose.zig`): raw 32-byte
//! private scalars + compressed SEC1 public points (the bytes did:key /
//! did:plc carry), secp256k1 *or* P-256, SHA-256 digest, 64-byte compact
//! R‖S signatures, and **low-S enforced both ways** (the atproto data
//! model rejects malleable high-S sigs). Curve order N and floor(N/2) are
//! hardcoded 32-byte big-endian so low-S normalization needs no
//! <openssl/ec.h>. The OpenSSL mechanism (scalar/point → EVP_PKEY, R‖S ↔
//! DER, digest-verify) is shared via `crypto_util`.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;

const globals = @import("../globals.zig");
const cu = @import("crypto_util.zig");
const ssl = cu.ssl;

const js_exception = globals.js_exception;

const SignCurve = struct {
    ossl: [:0]const u8,
    /// Subgroup order N, big-endian.
    n: [32]u8,
    /// floor(N/2): s is low-S iff s ≤ this.
    half: [32]u8,
};

fn signCurveForName(name: []const u8) ?SignCurve {
    if (std.mem.eql(u8, name, "secp256k1")) return .{
        .ossl = "secp256k1",
        .n = .{
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
            0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
            0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
        },
        .half = .{
            0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0x5D, 0x57, 0x6E, 0x73, 0x57, 0xA4, 0x50, 0x1D,
            0xDF, 0xE9, 0x2F, 0x46, 0x68, 0x1B, 0x20, 0xA0,
        },
    };
    if (std.mem.eql(u8, name, "P-256")) return .{
        .ossl = "P-256",
        .n = .{
            0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84,
            0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
        },
        .half = .{
            0x7F, 0xFF, 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00,
            0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xDE, 0x73, 0x73, 0x02, 0x49, 0xA0, 0xD0, 0x83,
            0x87, 0xDC, 0xE5, 0x61, 0x7E, 0x31, 0x92, 0xA8,
        },
    };
    return null;
}

/// Big-endian compare of two 32-byte integers. -1 / 0 / 1.
fn be32Cmp(a: *const [32]u8, b: *const [32]u8) i8 {
    for (a, b) |x, y| {
        if (x < y) return -1;
        if (x > y) return 1;
    }
    return 0;
}

/// out = a - b, big-endian, caller guarantees a ≥ b.
fn be32Sub(out: *[32]u8, a: *const [32]u8, b: *const [32]u8) void {
    var borrow: u16 = 0;
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        const d = @as(i16, a[i]) - @as(i16, b[i]) - @as(i16, @intCast(borrow));
        if (d < 0) {
            out[i] = @intCast(d + 256);
            borrow = 1;
        } else {
            out[i] = @intCast(d);
            borrow = 0;
        }
    }
}

/// `crypto.ecdsaGenerateKey(curve)` →
/// `{ privateKey: Uint8Array(32), publicKey: Uint8Array(33) }`.
/// `publicKey` is the compressed SEC1 point (0x02|0x03 ‖ X) — the form
/// did:key / did:plc multibase-encode.
pub fn jsCryptoEcdsaGenerateKey(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.ecdsaGenerateKey requires (curve)");
        return js_exception;
    }
    var name_len: usize = 0;
    const name_c = c.JS_ToCStringLen(ctx, &name_len, argv[0]);
    if (name_c == null) return js_exception;
    defer c.JS_FreeCString(ctx, name_c);
    const curve = signCurveForName(name_c[0..name_len]) orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.ecdsaGenerateKey: curve must be secp256k1 or P-256");
        return js_exception;
    };

    var params: [2]ssl.OSSL_PARAM = .{
        ssl.OSSL_PARAM_construct_utf8_string("group", @constCast(curve.ossl.ptr), curve.ossl.len),
        ssl.OSSL_PARAM_construct_end(),
    };
    const pctx = ssl.EVP_PKEY_CTX_new_from_name(null, "EC", null);
    if (pctx == null) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.ecdsaGenerateKey: ctx alloc failed");
        return js_exception;
    }
    defer ssl.EVP_PKEY_CTX_free(pctx);
    var pkey: ?*ssl.EVP_PKEY = null;
    if (ssl.EVP_PKEY_keygen_init(pctx) <= 0 or
        ssl.EVP_PKEY_CTX_set_params(pctx, &params) <= 0 or
        ssl.EVP_PKEY_generate(pctx, &pkey) <= 0 or pkey == null)
    {
        _ = c.JS_ThrowInternalError(ctx, "crypto.ecdsaGenerateKey: keygen failed");
        return js_exception;
    }
    defer ssl.EVP_PKEY_free(pkey);

    // Private scalar + public affine coords, each left-padded to 32.
    var d_bn: ?*ssl.BIGNUM = null;
    var x_bn: ?*ssl.BIGNUM = null;
    var y_bn: ?*ssl.BIGNUM = null;
    defer if (d_bn != null) ssl.BN_free(d_bn);
    defer if (x_bn != null) ssl.BN_free(x_bn);
    defer if (y_bn != null) ssl.BN_free(y_bn);
    if (ssl.EVP_PKEY_get_bn_param(pkey, "priv", &d_bn) != 1 or
        ssl.EVP_PKEY_get_bn_param(pkey, "qx", &x_bn) != 1 or
        ssl.EVP_PKEY_get_bn_param(pkey, "qy", &y_bn) != 1)
    {
        _ = c.JS_ThrowInternalError(ctx, "crypto.ecdsaGenerateKey: param export failed");
        return js_exception;
    }
    var priv: [32]u8 = undefined;
    var x: [32]u8 = undefined;
    if (ssl.BN_bn2binpad(d_bn, &priv, 32) != 32 or ssl.BN_bn2binpad(x_bn, &x, 32) != 32) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.ecdsaGenerateKey: scalar encode failed");
        return js_exception;
    }
    var pubpt: [33]u8 = undefined;
    pubpt[0] = if (ssl.BN_is_odd(y_bn) == 1) 0x03 else 0x02;
    @memcpy(pubpt[1..], &x);

    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "privateKey", c.JS_NewUint8ArrayCopy(ctx, &priv, 32));
    _ = c.JS_SetPropertyStr(ctx, obj, "publicKey", c.JS_NewUint8ArrayCopy(ctx, &pubpt, 33));
    return obj;
}

/// `crypto.ecdsaSign(curve, privateKey, data)` → `Uint8Array(64)`.
/// SHA-256 over `data`, compact raw R‖S, low-S normalized.
pub fn jsCryptoEcdsaSign(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 3) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.ecdsaSign requires (curve, privateKey, data)");
        return js_exception;
    }
    var name_len: usize = 0;
    const name_c = c.JS_ToCStringLen(ctx, &name_len, argv[0]);
    if (name_c == null) return js_exception;
    defer c.JS_FreeCString(ctx, name_c);
    const curve = signCurveForName(name_c[0..name_len]) orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.ecdsaSign: curve must be secp256k1 or P-256");
        return js_exception;
    };
    var priv_len: usize = 0;
    const priv_ptr = c.JS_GetUint8Array(ctx, &priv_len, argv[1]);
    if (priv_ptr == null) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.ecdsaSign: privateKey must be a Uint8Array");
        return js_exception;
    }
    var data_len: usize = 0;
    const data_ptr = c.JS_GetUint8Array(ctx, &data_len, argv[2]);
    if (data_ptr == null) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.ecdsaSign: data must be a Uint8Array");
        return js_exception;
    }

    const pkey = cu.ecKeypairFromScalar(curve.ossl, priv_ptr[0..priv_len]) catch {
        _ = c.JS_ThrowTypeError(ctx, "crypto.ecdsaSign: invalid private key");
        return js_exception;
    };
    defer ssl.EVP_PKEY_free(pkey);

    const md_ctx = ssl.EVP_MD_CTX_new();
    if (md_ctx == null) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.ecdsaSign: EVP_MD_CTX_new failed");
        return js_exception;
    }
    defer ssl.EVP_MD_CTX_free(md_ctx);
    var der: [80]u8 = undefined;
    var der_len: usize = der.len;
    if (ssl.EVP_DigestSignInit(md_ctx, null, ssl.EVP_sha256(), null, pkey) <= 0 or
        ssl.EVP_DigestSign(md_ctx, &der, &der_len, data_ptr, data_len) <= 0)
    {
        _ = c.JS_ThrowInternalError(ctx, "crypto.ecdsaSign: signing failed");
        return js_exception;
    }

    var r: [32]u8 = undefined;
    var s: [32]u8 = undefined;
    cu.parseEcdsaSigDer(der[0..der_len], &r, &s) catch {
        _ = c.JS_ThrowInternalError(ctx, "crypto.ecdsaSign: DER parse failed");
        return js_exception;
    };
    // Low-S: if s > N/2, replace with N - s.
    if (be32Cmp(&s, &curve.half) == 1) {
        var lo: [32]u8 = undefined;
        be32Sub(&lo, &curve.n, &s);
        s = lo;
    }
    var out: [64]u8 = undefined;
    @memcpy(out[0..32], &r);
    @memcpy(out[32..], &s);
    return c.JS_NewUint8ArrayCopy(ctx, &out, 64);
}

/// `crypto.ecdsaVerify(curve, publicKey, data, sig)` → bool.
/// `publicKey` is a SEC1 point (33-byte compressed or 65 uncompressed);
/// `sig` is compact raw R‖S (64 bytes). High-S signatures are rejected
/// (return `false`) per the atproto data model.
pub fn jsCryptoEcdsaVerify(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 4) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.ecdsaVerify requires (curve, publicKey, data, sig)");
        return js_exception;
    }
    var name_len: usize = 0;
    const name_c = c.JS_ToCStringLen(ctx, &name_len, argv[0]);
    if (name_c == null) return js_exception;
    defer c.JS_FreeCString(ctx, name_c);
    const curve = signCurveForName(name_c[0..name_len]) orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.ecdsaVerify: curve must be secp256k1 or P-256");
        return js_exception;
    };
    var pub_len: usize = 0;
    const pub_ptr = c.JS_GetUint8Array(ctx, &pub_len, argv[1]);
    if (pub_ptr == null) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.ecdsaVerify: publicKey must be a Uint8Array");
        return js_exception;
    }
    var data_len: usize = 0;
    const data_ptr = c.JS_GetUint8Array(ctx, &data_len, argv[2]);
    if (data_ptr == null) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.ecdsaVerify: data must be a Uint8Array");
        return js_exception;
    }
    var sig_len: usize = 0;
    const sig_ptr = c.JS_GetUint8Array(ctx, &sig_len, argv[3]);
    if (sig_ptr == null) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.ecdsaVerify: sig must be a Uint8Array");
        return js_exception;
    }
    if (sig_len != 64) return globals.js_false;

    // Enforce low-S before touching OpenSSL — a high-S sig is invalid
    // under atproto regardless of whether it verifies mathematically.
    var s: [32]u8 = undefined;
    @memcpy(&s, sig_ptr[32..64]);
    if (be32Cmp(&s, &curve.half) == 1) return globals.js_false;

    const pkey = cu.ecPubKeyFromPoint(curve.ossl, pub_ptr[0..pub_len]) catch {
        _ = c.JS_ThrowTypeError(ctx, "crypto.ecdsaVerify: invalid public key");
        return js_exception;
    };
    defer ssl.EVP_PKEY_free(pkey);

    var der_buf: [80]u8 = undefined;
    const der = cu.encodeEcdsaSigDer(&der_buf, sig_ptr[0..32], sig_ptr[32..64]) catch {
        _ = c.JS_ThrowInternalError(ctx, "crypto.ecdsaVerify: DER encoding failed");
        return js_exception;
    };
    const ok = cu.evpDigestVerify(ssl.EVP_sha256(), pkey, data_ptr[0..data_len], der) catch {
        _ = c.JS_ThrowInternalError(ctx, "crypto.ecdsaVerify: verify failed");
        return js_exception;
    };
    return if (ok) globals.js_true else globals.js_false;
}

const testing = std.testing;

test "ecdsa raw-key roundtrip (secp256k1 + P-256), low-S enforced" {
    const a = testing.allocator;
    inline for (.{ "secp256k1", "P-256" }) |cn| {
        const curve = signCurveForName(cn).?;
        // Keygen via the same OSSL path the binding uses.
        var params: [2]ssl.OSSL_PARAM = .{
            ssl.OSSL_PARAM_construct_utf8_string("group", @constCast(curve.ossl.ptr), curve.ossl.len),
            ssl.OSSL_PARAM_construct_end(),
        };
        const pctx = ssl.EVP_PKEY_CTX_new_from_name(null, "EC", null).?;
        defer ssl.EVP_PKEY_CTX_free(pctx);
        var pk: ?*ssl.EVP_PKEY = null;
        try testing.expect(ssl.EVP_PKEY_keygen_init(pctx) > 0);
        try testing.expect(ssl.EVP_PKEY_CTX_set_params(pctx, &params) > 0);
        try testing.expect(ssl.EVP_PKEY_generate(pctx, &pk) > 0);
        defer ssl.EVP_PKEY_free(pk);

        var d_bn: ?*ssl.BIGNUM = null;
        var x_bn: ?*ssl.BIGNUM = null;
        var y_bn: ?*ssl.BIGNUM = null;
        defer ssl.BN_free(d_bn);
        defer ssl.BN_free(x_bn);
        defer ssl.BN_free(y_bn);
        try testing.expect(ssl.EVP_PKEY_get_bn_param(pk, "priv", &d_bn) == 1);
        try testing.expect(ssl.EVP_PKEY_get_bn_param(pk, "qx", &x_bn) == 1);
        try testing.expect(ssl.EVP_PKEY_get_bn_param(pk, "qy", &y_bn) == 1);
        var priv: [32]u8 = undefined;
        var x: [32]u8 = undefined;
        _ = ssl.BN_bn2binpad(d_bn, &priv, 32);
        _ = ssl.BN_bn2binpad(x_bn, &x, 32);
        var pubpt: [33]u8 = undefined;
        pubpt[0] = if (ssl.BN_is_odd(y_bn) == 1) 0x03 else 0x02;
        @memcpy(pubpt[1..], &x);

        // Sign → parse DER → low-S → verify with the helper path.
        const msg = "atproto commit signing input bytes";
        const signer = try cu.ecKeypairFromScalar(curve.ossl, &priv);
        defer ssl.EVP_PKEY_free(signer);
        const mctx = ssl.EVP_MD_CTX_new().?;
        defer ssl.EVP_MD_CTX_free(mctx);
        var der: [80]u8 = undefined;
        var dl: usize = der.len;
        try testing.expect(ssl.EVP_DigestSignInit(mctx, null, ssl.EVP_sha256(), null, signer) > 0);
        try testing.expect(ssl.EVP_DigestSign(mctx, &der, &dl, msg, msg.len) > 0);
        var r: [32]u8 = undefined;
        var s: [32]u8 = undefined;
        try cu.parseEcdsaSigDer(der[0..dl], &r, &s);
        if (be32Cmp(&s, &curve.half) == 1) {
            var lo: [32]u8 = undefined;
            be32Sub(&lo, &curve.n, &s);
            s = lo;
        }
        try testing.expect(be32Cmp(&s, &curve.half) != 1); // now low-S

        var sig: [64]u8 = undefined;
        @memcpy(sig[0..32], &r);
        @memcpy(sig[32..], &s);
        const vk = try cu.ecPubKeyFromPoint(curve.ossl, &pubpt);
        defer ssl.EVP_PKEY_free(vk);
        var vder: [80]u8 = undefined;
        const ds = try cu.encodeEcdsaSigDer(&vder, sig[0..32], sig[32..64]);
        try testing.expect(try cu.evpDigestVerify(ssl.EVP_sha256(), vk, msg, ds));

        // Tampered message must fail.
        const bad = "atproto commit signing input bytez";
        try testing.expect(!(try cu.evpDigestVerify(ssl.EVP_sha256(), vk, bad, ds)));
        _ = a;
    }
}
