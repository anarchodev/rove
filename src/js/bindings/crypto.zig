//! `crypto.*` JS bindings exposed to handler code.
//!
//! All randomness draws from `state.prng` (per-request) and is taped
//! through `state.crypto_random_tape` when set, so replay reproduces
//! the same byte sequence. Hashes are pure (no tape capture needed).

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;

const ssl = @cImport({
    @cInclude("openssl/evp.h");
    @cInclude("openssl/rsa.h");
    @cInclude("openssl/bn.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/core_names.h");
    @cInclude("openssl/param_build.h");
    @cInclude("openssl/pem.h");
    @cInclude("openssl/bio.h");
});

const globals = @import("../globals.zig");

const js_exception = globals.js_exception;

pub fn jsCryptoGetRandomValues(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_exception;
    const state = globals.getState(ctx);

    // The Web Crypto API expects a typed array. We reach into the
    // ArrayBuffer directly via JS_GetArrayBuffer. Non-typed-array
    // inputs get rejected with an exception.
    var byte_len: usize = 0;
    const buf_ptr = c.JS_GetUint8Array(ctx, &byte_len, argv[0]);
    if (buf_ptr == null) return js_exception;

    const bytes = buf_ptr[0..byte_len];
    state.prng.random().bytes(bytes);
    if (state.crypto_random_tape) |t| t.appendCryptoRandom(bytes) catch {};
    // Spec says return the input typed array.
    return c.JS_DupValue(ctx, argv[0]);
}

/// `crypto.hmacSha256(key, data)` → hex string (64 chars).
///
/// Both arguments accept either a JS string (UTF-8 bytes) or a
/// Uint8Array. Deterministic — does NOT tape-capture (HMAC of known
/// inputs is a pure function, so replay reproduces the same digest).
///
/// PLAN §2.6: we keep `webhook.send` vendor-neutral and expose this
/// as the primitive customers compose into Stripe-Signature,
/// Slack X-Slack-Signature, AWS SigV4 derivations, etc.
pub fn jsCryptoHmacSha256(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 2) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.hmacSha256 requires (key, data)");
        return js_exception;
    }

    var key_cstr: [*c]const u8 = null;
    defer if (key_cstr != null) c.JS_FreeCString(ctx, key_cstr);
    var data_cstr: [*c]const u8 = null;
    defer if (data_cstr != null) c.JS_FreeCString(ctx, data_cstr);

    const key_bytes = extractKeyOrDataBytes(ctx, argv[0], &key_cstr) orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.hmacSha256: key must be a string or Uint8Array");
        return js_exception;
    };
    const data_bytes = extractKeyOrDataBytes(ctx, argv[1], &data_cstr) orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.hmacSha256: data must be a string or Uint8Array");
        return js_exception;
    };

    var digest: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&digest, data_bytes, key_bytes);

    var out: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return c.JS_NewStringLen(ctx, &out, 64);
}

/// Read a JS value as a byte slice. Tries string first (common path
/// for HMAC over request bodies), falls back to Uint8Array (for
/// binary secrets / pre-hashed data). Returns null if neither.
///
/// When the string path is taken, `cstr_out` gets the JS_ToCStringLen
/// pointer that the caller must free via `JS_FreeCString`.
fn extractKeyOrDataBytes(
    ctx: ?*c.JSContext,
    val: c.JSValue,
    cstr_out: *[*c]const u8,
) ?[]const u8 {
    if (c.JS_IsString(val)) {
        var len: usize = 0;
        const cstr = c.JS_ToCStringLen(ctx, &len, val);
        if (cstr == null) return null;
        cstr_out.* = cstr;
        return @as([*]const u8, @ptrCast(cstr))[0..len];
    }
    var byte_len: usize = 0;
    const buf_ptr = c.JS_GetUint8Array(ctx, &byte_len, val);
    if (buf_ptr == null) {
        // JS_GetUint8Array may have set a pending exception — clear
        // it so we can throw our own message above.
        const pending = c.JS_GetException(ctx);
        c.JS_FreeValue(ctx, pending);
        return null;
    }
    return buf_ptr[0..byte_len];
}

pub fn jsCryptoRandomUuid(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    _: c_int,
    _: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);

    var raw: [16]u8 = undefined;
    state.prng.random().bytes(&raw);
    // RFC 4122 v4: set the version and variant bits.
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;

    // Capture the raw bytes on the crypto tape so the replay source
    // can reconstruct the same UUID without knowing the formatting.
    if (state.crypto_random_tape) |t| t.appendCryptoRandom(&raw) catch {};

    var out: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var oi: usize = 0;
    for (raw, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[oi] = '-';
            oi += 1;
        }
        out[oi] = hex[b >> 4];
        out[oi + 1] = hex[b & 0x0f];
        oi += 2;
    }
    return c.JS_NewStringLen(ctx, &out, 36);
}

/// `crypto.randomBytes(n) → Uint8Array` — n cryptographically random
/// bytes drawn from the per-request PRNG. Tape-backed: bytes are
/// recorded on `crypto_random_tape` so replay produces the same
/// sequence.
///
/// `n` must be a non-negative integer ≤ 65536 (Web Crypto's typical
/// per-call cap). Throws RangeError otherwise.
pub fn jsCryptoRandomBytes(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.randomBytes requires (n)");
        return js_exception;
    }
    const state = globals.getState(ctx);

    var n_i32: i32 = 0;
    if (c.JS_ToInt32(ctx, &n_i32, argv[0]) != 0) return js_exception;
    if (n_i32 < 0 or n_i32 > 65536) {
        _ = c.JS_ThrowRangeError(ctx, "crypto.randomBytes: n must be in [0, 65536]");
        return js_exception;
    }

    const n: usize = @intCast(n_i32);
    const bytes = state.allocator.alloc(u8, n) catch {
        _ = c.JS_ThrowOutOfMemory(ctx);
        return js_exception;
    };
    defer state.allocator.free(bytes);

    state.prng.random().bytes(bytes);
    if (state.crypto_random_tape) |t| t.appendCryptoRandom(bytes) catch {};

    return c.JS_NewUint8ArrayCopy(ctx, bytes.ptr, bytes.len);
}

/// `crypto.sha256(data) → hex string` (64 chars).
///
/// `data` accepts a JS string (UTF-8 bytes) or a Uint8Array. Pure
/// deterministic — no tape capture (replay reproduces the same digest
/// from the same input).
pub fn jsCryptoSha256(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.sha256 requires (data)");
        return js_exception;
    }

    var data_cstr: [*c]const u8 = null;
    defer if (data_cstr != null) c.JS_FreeCString(ctx, data_cstr);

    const data_bytes = extractKeyOrDataBytes(ctx, argv[0], &data_cstr) orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.sha256: data must be a string or Uint8Array");
        return js_exception;
    };

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data_bytes, &digest, .{});

    var out: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return c.JS_NewStringLen(ctx, &out, 64);
}

/// `crypto.verifyRsa(jwk, alg, data, sig) → bool`
///
/// Verify an RSA-PKCS#1 v1.5 signature using OpenSSL. Used by
/// customer JS to validate OIDC id_tokens (JWS RS256/RS384/RS512).
///
/// Arguments:
///   - `jwk`:  JS object with at least `{kty:"RSA", n:base64url,
///             e:base64url}`. The provider's JWKS endpoint returns
///             this shape directly. Other JWK fields (alg, kid, use)
///             are ignored — the algorithm is taken from the `alg`
///             argument, not the JWK.
///   - `alg`:  "sha256" / "sha384" / "sha512" (case-insensitive).
///   - `data`: Uint8Array. For JWS, this is `header_b64 || "." || payload_b64`
///             (UTF-8 bytes, no decoding).
///   - `sig`:  Uint8Array of the raw signature bytes (caller already
///             base64url-decoded the third JWS segment).
///
/// Returns `true` on a valid signature, `false` on a verification
/// failure (signature doesn't match). Throws on malformed inputs.
///
/// Does NOT validate JWT claims (iss / aud / exp / iat / nbf) — the
/// caller is responsible for those after the cryptographic verify
/// passes.
pub fn jsCryptoVerifyRsa(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 4) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyRsa requires (jwk, alg, data, sig)");
        return js_exception;
    }

    const state = globals.getState(ctx);
    const allocator = state.allocator;

    if (!c.JS_IsObject(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyRsa: `jwk` must be an object");
        return js_exception;
    }

    // Read jwk.kty + .n + .e.
    const kty = jsObjStringField(ctx, allocator, argv[0], "kty") catch {
        return js_exception;
    } orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyRsa: jwk.kty missing");
        return js_exception;
    };
    defer allocator.free(kty);
    if (!std.mem.eql(u8, kty, "RSA")) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyRsa: only RSA kty supported");
        return js_exception;
    }
    const n_b64_opt = jsObjStringField(ctx, allocator, argv[0], "n") catch return js_exception;
    const n_b64 = n_b64_opt orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyRsa: jwk.n missing");
        return js_exception;
    };
    defer allocator.free(n_b64);
    const e_b64_opt = jsObjStringField(ctx, allocator, argv[0], "e") catch return js_exception;
    const e_b64 = e_b64_opt orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyRsa: jwk.e missing");
        return js_exception;
    };
    defer allocator.free(e_b64);

    const n_bytes = base64urlDecode(allocator, n_b64) catch {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyRsa: jwk.n is not valid base64url");
        return js_exception;
    };
    defer allocator.free(n_bytes);
    const e_bytes = base64urlDecode(allocator, e_b64) catch {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyRsa: jwk.e is not valid base64url");
        return js_exception;
    };
    defer allocator.free(e_bytes);

    // Algorithm name → EVP_MD.
    var alg_cstr_opt: [*c]const u8 = null;
    defer if (alg_cstr_opt != null) c.JS_FreeCString(ctx, alg_cstr_opt);
    var alg_len: usize = 0;
    alg_cstr_opt = c.JS_ToCStringLen(ctx, &alg_len, argv[1]);
    if (alg_cstr_opt == null) return js_exception;
    const alg = @as([*]const u8, @ptrCast(alg_cstr_opt))[0..alg_len];
    const md = mdForAlg(alg) orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyRsa: alg must be sha256 / sha384 / sha512");
        return js_exception;
    };

    // data + sig bytes.
    var data_len: usize = 0;
    const data_ptr = c.JS_GetUint8Array(ctx, &data_len, argv[2]);
    if (data_ptr == null) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyRsa: data must be a Uint8Array");
        return js_exception;
    }
    var sig_len: usize = 0;
    const sig_ptr = c.JS_GetUint8Array(ctx, &sig_len, argv[3]);
    if (sig_ptr == null) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyRsa: sig must be a Uint8Array");
        return js_exception;
    }

    // Build EVP_PKEY from (n, e) via OSSL_PARAM. OpenSSL 3.x path —
    // RSA_new + RSA_set0_key + EVP_PKEY_assign_RSA is deprecated.
    const n_bn = ssl.BN_bin2bn(n_bytes.ptr, @intCast(n_bytes.len), null);
    if (n_bn == null) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyRsa: BN_bin2bn(n) failed");
        return js_exception;
    }
    defer ssl.BN_free(n_bn);
    const e_bn = ssl.BN_bin2bn(e_bytes.ptr, @intCast(e_bytes.len), null);
    if (e_bn == null) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyRsa: BN_bin2bn(e) failed");
        return js_exception;
    }
    defer ssl.BN_free(e_bn);

    const bld = ssl.OSSL_PARAM_BLD_new();
    if (bld == null) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyRsa: OSSL_PARAM_BLD_new failed");
        return js_exception;
    }
    defer ssl.OSSL_PARAM_BLD_free(bld);
    if (ssl.OSSL_PARAM_BLD_push_BN(bld, "n", n_bn) == 0 or
        ssl.OSSL_PARAM_BLD_push_BN(bld, "e", e_bn) == 0)
    {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyRsa: OSSL_PARAM_BLD_push_BN failed");
        return js_exception;
    }
    const params = ssl.OSSL_PARAM_BLD_to_param(bld);
    if (params == null) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyRsa: OSSL_PARAM_BLD_to_param failed");
        return js_exception;
    }
    defer ssl.OSSL_PARAM_free(params);

    const pkey_ctx = ssl.EVP_PKEY_CTX_new_from_name(null, "RSA", null);
    if (pkey_ctx == null) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyRsa: EVP_PKEY_CTX_new_from_name failed");
        return js_exception;
    }
    defer ssl.EVP_PKEY_CTX_free(pkey_ctx);
    if (ssl.EVP_PKEY_fromdata_init(pkey_ctx) <= 0) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyRsa: EVP_PKEY_fromdata_init failed");
        return js_exception;
    }
    var pkey: ?*ssl.EVP_PKEY = null;
    if (ssl.EVP_PKEY_fromdata(pkey_ctx, &pkey, ssl.EVP_PKEY_PUBLIC_KEY, params) <= 0 or pkey == null) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyRsa: EVP_PKEY_fromdata failed");
        return js_exception;
    }
    defer ssl.EVP_PKEY_free(pkey);

    const md_ctx = ssl.EVP_MD_CTX_new();
    if (md_ctx == null) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyRsa: EVP_MD_CTX_new failed");
        return js_exception;
    }
    defer ssl.EVP_MD_CTX_free(md_ctx);

    if (ssl.EVP_DigestVerifyInit(md_ctx, null, md, null, pkey) <= 0) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyRsa: EVP_DigestVerifyInit failed");
        return js_exception;
    }
    if (ssl.EVP_DigestVerifyUpdate(md_ctx, data_ptr, data_len) <= 0) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyRsa: EVP_DigestVerifyUpdate failed");
        return js_exception;
    }
    const rc = ssl.EVP_DigestVerifyFinal(md_ctx, sig_ptr, sig_len);
    // 1 = valid, 0 = invalid signature, <0 = error. We surface the
    // last as the same `false` JS result — customer can't act on it
    // any differently than an invalid signature, and OpenSSL's error
    // queue would already have logged. (Matches Web Crypto's
    // SubtleCrypto.verify() shape: the promise resolves to false on
    // both invalid + error.)
    return if (rc == 1) globals.js_true else globals.js_false;
}

/// `crypto.verifyEcdsa(jwk, alg, data, sig) → bool`
///
/// Verify a JWS-style ECDSA signature using OpenSSL. Used by
/// customer JS to validate OIDC id_tokens signed with ES256 / ES384
/// / ES512 — Apple's "Sign in with Apple", AWS Cognito, Cloudflare
/// Access, modern OIDC providers.
///
/// Arguments:
///   - `jwk`:  JS object `{kty:"EC", crv, x:base64url, y:base64url}`.
///             `crv` must be "P-256", "P-384", or "P-521".
///   - `alg`:  "sha256" / "sha384" / "sha512" (case-insensitive).
///             Should match the curve (P-256→sha256, P-384→sha384,
///             P-521→sha512) per JWA — we don't enforce, OpenSSL
///             will fail-verify on a real mismatch.
///   - `data`: Uint8Array (JWS signing input: `header_b64.payload_b64`
///             UTF-8 bytes).
///   - `sig`:  Uint8Array of the JWS signature — RAW R||S
///             concatenation (64 bytes for P-256, 96 for P-384, 132
///             for P-521). NOT DER-encoded; the JWS spec mandates
///             raw, OpenSSL wants DER, so this binding does the
///             conversion internally.
///
/// Returns `true` on a valid signature, `false` on a verification
/// failure. Throws on malformed inputs (bad curve name, wrong sig
/// length for the curve, missing fields).
///
/// Does NOT validate JWT claims (iss / aud / exp / iat / nbf) — the
/// caller is responsible for those after the cryptographic verify
/// passes.
pub fn jsCryptoVerifyEcdsa(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 4) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa requires (jwk, alg, data, sig)");
        return js_exception;
    }

    const state = globals.getState(ctx);
    const allocator = state.allocator;

    if (!c.JS_IsObject(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: `jwk` must be an object");
        return js_exception;
    }

    const kty_opt = jsObjStringField(ctx, allocator, argv[0], "kty") catch return js_exception;
    const kty = kty_opt orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: jwk.kty missing");
        return js_exception;
    };
    defer allocator.free(kty);
    if (!std.mem.eql(u8, kty, "EC")) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: only EC kty supported");
        return js_exception;
    }

    const crv_opt = jsObjStringField(ctx, allocator, argv[0], "crv") catch return js_exception;
    const crv = crv_opt orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: jwk.crv missing");
        return js_exception;
    };
    defer allocator.free(crv);
    const curve = curveForName(crv) orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: jwk.crv must be P-256 / P-384 / P-521");
        return js_exception;
    };

    const x_opt = jsObjStringField(ctx, allocator, argv[0], "x") catch return js_exception;
    const x_b64 = x_opt orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: jwk.x missing");
        return js_exception;
    };
    defer allocator.free(x_b64);
    const y_opt = jsObjStringField(ctx, allocator, argv[0], "y") catch return js_exception;
    const y_b64 = y_opt orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: jwk.y missing");
        return js_exception;
    };
    defer allocator.free(y_b64);

    const x_bytes = base64urlDecode(allocator, x_b64) catch {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: jwk.x is not valid base64url");
        return js_exception;
    };
    defer allocator.free(x_bytes);
    const y_bytes = base64urlDecode(allocator, y_b64) catch {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: jwk.y is not valid base64url");
        return js_exception;
    };
    defer allocator.free(y_bytes);

    // JWA leftpads x and y to coord_size; some JWKs in the wild
    // emit shorter values when leading bytes are zero. Accept ≤
    // coord_size (we'll left-pad ourselves below); reject >.
    if (x_bytes.len > curve.coord_size or y_bytes.len > curve.coord_size) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: jwk.x or jwk.y too large for curve");
        return js_exception;
    }

    // Algorithm name → EVP_MD.
    var alg_cstr_opt: [*c]const u8 = null;
    defer if (alg_cstr_opt != null) c.JS_FreeCString(ctx, alg_cstr_opt);
    var alg_len: usize = 0;
    alg_cstr_opt = c.JS_ToCStringLen(ctx, &alg_len, argv[1]);
    if (alg_cstr_opt == null) return js_exception;
    const alg = @as([*]const u8, @ptrCast(alg_cstr_opt))[0..alg_len];
    const md = mdForAlg(alg) orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: alg must be sha256 / sha384 / sha512");
        return js_exception;
    };

    var data_len: usize = 0;
    const data_ptr = c.JS_GetUint8Array(ctx, &data_len, argv[2]);
    if (data_ptr == null) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: data must be a Uint8Array");
        return js_exception;
    }
    var sig_len: usize = 0;
    const sig_ptr = c.JS_GetUint8Array(ctx, &sig_len, argv[3]);
    if (sig_ptr == null) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: sig must be a Uint8Array");
        return js_exception;
    }

    // JWS signature is raw R||S, each component coord_size bytes.
    const expected_sig_len = curve.coord_size * 2;
    if (sig_len != expected_sig_len) {
        _ = c.JS_ThrowTypeError(
            ctx,
            "crypto.verifyEcdsa: sig length doesn't match curve (R||S concatenation expected)",
        );
        return js_exception;
    }

    // Build uncompressed public-key point: 0x04 || X || Y, with X
    // and Y left-zero-padded to coord_size.
    const point_len = 1 + curve.coord_size * 2;
    const point = allocator.alloc(u8, point_len) catch {
        _ = c.JS_ThrowOutOfMemory(ctx);
        return js_exception;
    };
    defer allocator.free(point);
    point[0] = 0x04;
    @memset(point[1 .. 1 + curve.coord_size], 0);
    @memcpy(point[1 + curve.coord_size - x_bytes.len ..][0..x_bytes.len], x_bytes);
    @memset(point[1 + curve.coord_size .. point_len], 0);
    @memcpy(point[point_len - y_bytes.len ..][0..y_bytes.len], y_bytes);

    // Build EVP_PKEY via fromdata with group + uncompressed pub key.
    const bld = ssl.OSSL_PARAM_BLD_new();
    if (bld == null) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyEcdsa: OSSL_PARAM_BLD_new failed");
        return js_exception;
    }
    defer ssl.OSSL_PARAM_BLD_free(bld);
    if (ssl.OSSL_PARAM_BLD_push_utf8_string(bld, "group", curve.ossl_name.ptr, curve.ossl_name.len) == 0 or
        ssl.OSSL_PARAM_BLD_push_octet_string(bld, "pub", point.ptr, point_len) == 0)
    {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyEcdsa: OSSL_PARAM_BLD_push failed");
        return js_exception;
    }
    const params = ssl.OSSL_PARAM_BLD_to_param(bld);
    if (params == null) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyEcdsa: OSSL_PARAM_BLD_to_param failed");
        return js_exception;
    }
    defer ssl.OSSL_PARAM_free(params);

    const pkey_ctx = ssl.EVP_PKEY_CTX_new_from_name(null, "EC", null);
    if (pkey_ctx == null) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyEcdsa: EVP_PKEY_CTX_new_from_name failed");
        return js_exception;
    }
    defer ssl.EVP_PKEY_CTX_free(pkey_ctx);
    if (ssl.EVP_PKEY_fromdata_init(pkey_ctx) <= 0) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyEcdsa: EVP_PKEY_fromdata_init failed");
        return js_exception;
    }
    var pkey: ?*ssl.EVP_PKEY = null;
    if (ssl.EVP_PKEY_fromdata(pkey_ctx, &pkey, ssl.EVP_PKEY_PUBLIC_KEY, params) <= 0 or pkey == null) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyEcdsa: EVP_PKEY_fromdata failed");
        return js_exception;
    }
    defer ssl.EVP_PKEY_free(pkey);

    // JWS sig is raw R||S, OpenSSL EVP_DigestVerify expects DER.
    // We hand-build the DER (SEQUENCE { INTEGER r, INTEGER s }) to
    // avoid pulling in <openssl/ecdsa.h> + <openssl/ec.h>, both of
    // which cascade into header-macro translation errors with our
    // toolchain. ASN.1 DER for ECDSA-SIG is short + fully spec'd.
    // Worst-case length for P-521: 1+2+138 = 141 bytes; 256 buffer
    // covers all curves with margin.
    var der_buf: [256]u8 = undefined;
    const der_len = encodeEcdsaSigDer(
        &der_buf,
        sig_ptr[0..curve.coord_size],
        (sig_ptr + curve.coord_size)[0..curve.coord_size],
    ) catch {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyEcdsa: DER encoding failed");
        return js_exception;
    };

    const md_ctx = ssl.EVP_MD_CTX_new();
    if (md_ctx == null) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyEcdsa: EVP_MD_CTX_new failed");
        return js_exception;
    }
    defer ssl.EVP_MD_CTX_free(md_ctx);

    if (ssl.EVP_DigestVerifyInit(md_ctx, null, md, null, pkey) <= 0) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyEcdsa: EVP_DigestVerifyInit failed");
        return js_exception;
    }
    if (ssl.EVP_DigestVerifyUpdate(md_ctx, data_ptr, data_len) <= 0) {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyEcdsa: EVP_DigestVerifyUpdate failed");
        return js_exception;
    }
    const rc = ssl.EVP_DigestVerifyFinal(md_ctx, der_len.ptr, der_len.len);
    return if (rc == 1) globals.js_true else globals.js_false;
}

/// Build the DER encoding of an ECDSA-SIG into `out`. Input is the
/// raw R || S concatenation per JWS — this function handles the
/// ASN.1 INTEGER rules: strip leading zeros from each component,
/// then prepend a 0x00 if the high bit of the first remaining byte
/// is set (so the integer stays positive). Returns the number of
/// bytes written. Returns error.BufferTooSmall when `out.len`
/// can't hold the result (callers size at 256).
fn encodeEcdsaSigDer(out: []u8, r: []const u8, s: []const u8) ![]const u8 {
    const r_int = trimToInteger(r);
    const s_int = trimToInteger(s);
    // Each INTEGER: 1 (tag) + 1 (len, all real-world ECDSA fits in
    // a single length byte ≤127) + r_int.payload.len + extra-zero
    // prefix if needed.
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

const Curve = struct {
    ossl_name: []const u8,
    coord_size: usize,
};

fn curveForName(name: []const u8) ?Curve {
    if (std.mem.eql(u8, name, "P-256")) return .{ .ossl_name = "P-256", .coord_size = 32 };
    if (std.mem.eql(u8, name, "P-384")) return .{ .ossl_name = "P-384", .coord_size = 48 };
    if (std.mem.eql(u8, name, "P-521")) return .{ .ossl_name = "P-521", .coord_size = 66 };
    return null;
}

fn mdForAlg(alg: []const u8) ?*const ssl.EVP_MD {
    if (std.ascii.eqlIgnoreCase(alg, "sha256")) return ssl.EVP_sha256();
    if (std.ascii.eqlIgnoreCase(alg, "sha384")) return ssl.EVP_sha384();
    if (std.ascii.eqlIgnoreCase(alg, "sha512")) return ssl.EVP_sha512();
    return null;
}

/// Read a string property off a JS object and dupe to allocator-owned
/// bytes. Returns null when the property is absent / null / undefined;
/// returns error.JsException when the property exists but isn't a
/// string (sets the QJS exception slot).
fn jsObjStringField(
    ctx: ?*c.JSContext,
    a: std.mem.Allocator,
    obj: c.JSValue,
    name: [:0]const u8,
) !?[]u8 {
    const v = c.JS_GetPropertyStr(ctx, obj, name.ptr);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v) or c.JS_IsNull(v)) return null;
    if (!c.JS_IsString(v)) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyRsa: jwk field must be a string");
        return error.JsException;
    }
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, v);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    return try a.dupe(u8, @as([*]const u8, @ptrCast(cstr))[0..len]);
}

/// Decode URL-safe base64 (no padding) to bytes. Tolerates standard
/// alphabet (+/) on input too. Used to unpack JWK n/e fields.
fn base64urlDecode(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
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

// =============================================================================
// OIDC RS256 key custody (auth-domain-plan §4.7 fork A: HYBRID).
//
// Generation + signing are Zig/OpenSSL; the RSA private key is handed
// to JS only as an opaque PKCS#8 PEM string it stores in kv and passes
// back verbatim — JS never does private-key math. (Implementation
// refinement of §4.7's "by kid" phrasing: a pure binding with no kv
// coupling; the IdP JS keeps the opaque blob.)
// =============================================================================

const B64URL = std.base64.url_safe_no_pad;

fn b64urlEnc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, B64URL.Encoder.calcSize(bytes.len));
    _ = B64URL.Encoder.encode(out, bytes);
    return out;
}

fn bioDrain(allocator: std.mem.Allocator, bio: *ssl.BIO) ![]u8 {
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

/// An RSA-2048 keypair. `priv_pem` is the opaque blob the IdP stores.
const RsaKey = struct {
    pkey: *ssl.EVP_PKEY,

    fn generate() !RsaKey {
        const ty: [*c]const u8 = "RSA";
        const pkey = ssl.EVP_PKEY_Q_keygen(null, null, ty, @as(usize, 2048)) orelse
            return error.RsaKeygen;
        return .{ .pkey = pkey };
    }

    fn fromPem(pem: []const u8) !RsaKey {
        const bio = ssl.BIO_new_mem_buf(pem.ptr, @intCast(pem.len)) orelse
            return error.OutOfMemory;
        defer _ = ssl.BIO_free(bio);
        const pkey = ssl.PEM_read_bio_PrivateKey(bio, null, null, null) orelse
            return error.RsaBadPem;
        return .{ .pkey = pkey };
    }

    fn deinit(self: *RsaKey) void {
        ssl.EVP_PKEY_free(self.pkey);
    }

    fn privatePem(self: *const RsaKey, allocator: std.mem.Allocator) ![]u8 {
        const bio = ssl.BIO_new(ssl.BIO_s_mem()) orelse return error.OutOfMemory;
        defer _ = ssl.BIO_free(bio);
        if (ssl.PEM_write_bio_PrivateKey(bio, self.pkey, null, null, 0, null, null) != 1)
            return error.RsaPemWrite;
        return bioDrain(allocator, bio);
    }

    fn bnParam(self: *const RsaKey, allocator: std.mem.Allocator, name: [*c]const u8) ![]u8 {
        var bn: ?*ssl.BIGNUM = null;
        if (ssl.EVP_PKEY_get_bn_param(self.pkey, name, &bn) != 1 or bn == null)
            return error.RsaParam;
        defer ssl.BN_free(bn);
        const len = ssl.BN_num_bytes(bn);
        if (len <= 0) return error.RsaParam;
        const buf = try allocator.alloc(u8, @intCast(len));
        errdefer allocator.free(buf);
        if (ssl.BN_bn2bin(bn, buf.ptr) != len) return error.RsaParam;
        return buf;
    }

    /// Public JWK members (n,e base64url) + RFC 7638 kid. Caller frees.
    const Jwk = struct {
        n: []u8,
        e: []u8,
        kid: []u8,
        fn deinit(self: *Jwk, a: std.mem.Allocator) void {
            a.free(self.n);
            a.free(self.e);
            a.free(self.kid);
        }
    };

    fn publicJwk(self: *const RsaKey, allocator: std.mem.Allocator) !Jwk {
        const n_raw = try self.bnParam(allocator, "n");
        defer allocator.free(n_raw);
        const e_raw = try self.bnParam(allocator, "e");
        defer allocator.free(e_raw);
        const n_b64 = try b64urlEnc(allocator, n_raw);
        errdefer allocator.free(n_b64);
        const e_b64 = try b64urlEnc(allocator, e_raw);
        errdefer allocator.free(e_b64);
        // RFC 7638: members in lexicographic order, no whitespace.
        const canon = try std.fmt.allocPrint(
            allocator,
            "{{\"e\":\"{s}\",\"kty\":\"RSA\",\"n\":\"{s}\"}}",
            .{ e_b64, n_b64 },
        );
        defer allocator.free(canon);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(canon, &digest, .{});
        const kid = try b64urlEnc(allocator, &digest);
        return .{ .n = n_b64, .e = e_b64, .kid = kid };
    }

    /// RS256 (RSASSA-PKCS1-v1_5 + SHA-256 — the EVP default for RSA).
    /// Returns base64url(signature). Caller frees.
    fn signRs256(self: *const RsaKey, allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
        const mdctx = ssl.EVP_MD_CTX_new() orelse return error.OutOfMemory;
        defer ssl.EVP_MD_CTX_free(mdctx);
        if (ssl.EVP_DigestSignInit(mdctx, null, ssl.EVP_sha256(), null, self.pkey) != 1)
            return error.RsaSign;
        var siglen: usize = 0;
        if (ssl.EVP_DigestSign(mdctx, null, &siglen, msg.ptr, msg.len) != 1)
            return error.RsaSign;
        const sig = try allocator.alloc(u8, siglen);
        defer allocator.free(sig);
        if (ssl.EVP_DigestSign(mdctx, sig.ptr, &siglen, msg.ptr, msg.len) != 1)
            return error.RsaSign;
        return b64urlEnc(allocator, sig[0..siglen]);
    }
};

/// `crypto.oidcGenerateKey()` → `{ priv, jwk:{kty,n,e,alg,use,kid}, kid }`.
/// `priv` is an opaque PKCS#8 PEM the IdP stores in kv and never parses.
pub fn jsCryptoOidcGenerateKey(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    _: c_int,
    _: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const allocator = globals.getState(ctx).allocator;
    var key = RsaKey.generate() catch {
        _ = c.JS_ThrowTypeError(ctx, "crypto.oidcGenerateKey: keygen failed");
        return js_exception;
    };
    defer key.deinit();
    const pem = key.privatePem(allocator) catch return js_exception;
    defer allocator.free(pem);
    var jwk = key.publicJwk(allocator) catch return js_exception;
    defer jwk.deinit(allocator);

    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "priv", c.JS_NewStringLen(ctx, pem.ptr, pem.len));
    _ = c.JS_SetPropertyStr(ctx, obj, "kid", c.JS_NewStringLen(ctx, jwk.kid.ptr, jwk.kid.len));
    const jwk_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, jwk_obj, "kty", c.JS_NewStringLen(ctx, "RSA", 3));
    _ = c.JS_SetPropertyStr(ctx, jwk_obj, "alg", c.JS_NewStringLen(ctx, "RS256", 5));
    _ = c.JS_SetPropertyStr(ctx, jwk_obj, "use", c.JS_NewStringLen(ctx, "sig", 3));
    _ = c.JS_SetPropertyStr(ctx, jwk_obj, "n", c.JS_NewStringLen(ctx, jwk.n.ptr, jwk.n.len));
    _ = c.JS_SetPropertyStr(ctx, jwk_obj, "e", c.JS_NewStringLen(ctx, jwk.e.ptr, jwk.e.len));
    _ = c.JS_SetPropertyStr(ctx, jwk_obj, "kid", c.JS_NewStringLen(ctx, jwk.kid.ptr, jwk.kid.len));
    _ = c.JS_SetPropertyStr(ctx, obj, "jwk", jwk_obj);
    return obj;
}

/// `crypto.oidcSign(priv_pem, signing_input)` → base64url(RS256 sig).
pub fn jsCryptoOidcSign(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 2) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.oidcSign requires (priv_pem, signing_input)");
        return js_exception;
    }
    const allocator = globals.getState(ctx).allocator;
    var pem_len: usize = 0;
    const pem_c = c.JS_ToCStringLen(ctx, &pem_len, argv[0]);
    if (pem_c == null) return js_exception;
    defer c.JS_FreeCString(ctx, pem_c);
    var msg_len: usize = 0;
    const msg_c = c.JS_ToCStringLen(ctx, &msg_len, argv[1]);
    if (msg_c == null) return js_exception;
    defer c.JS_FreeCString(ctx, msg_c);

    var key = RsaKey.fromPem(pem_c[0..pem_len]) catch {
        _ = c.JS_ThrowTypeError(ctx, "crypto.oidcSign: bad private PEM");
        return js_exception;
    };
    defer key.deinit();
    const sig = key.signRs256(allocator, msg_c[0..msg_len]) catch {
        _ = c.JS_ThrowTypeError(ctx, "crypto.oidcSign: sign failed");
        return js_exception;
    };
    defer allocator.free(sig);
    return c.JS_NewStringLen(ctx, sig.ptr, sig.len);
}

test "RSA keygen → RS256 sign verifies; JWK + kid well-formed" {
    const a = std.testing.allocator;
    var k = try RsaKey.generate();
    defer k.deinit();

    const pem = try k.privatePem(a);
    defer a.free(pem);
    try std.testing.expect(std.mem.indexOf(u8, pem, "PRIVATE KEY") != null);

    const sig_b64 = try k.signRs256(a, "oidc id_token signing input");
    defer a.free(sig_b64);
    const sig = try base64urlDecode(a, sig_b64);
    defer a.free(sig);
    // Verify with OpenSSL directly (proves the sig is real RS256).
    const mdctx = ssl.EVP_MD_CTX_new().?;
    defer ssl.EVP_MD_CTX_free(mdctx);
    try std.testing.expect(ssl.EVP_DigestVerifyInit(mdctx, null, ssl.EVP_sha256(), null, k.pkey) == 1);
    const msg = "oidc id_token signing input";
    try std.testing.expect(ssl.EVP_DigestVerify(mdctx, sig.ptr, sig.len, msg, msg.len) == 1);

    var jwk = try k.publicJwk(a);
    defer jwk.deinit(a);
    try std.testing.expect(jwk.n.len > 300); // 2048-bit modulus, b64url
    try std.testing.expectEqualStrings("AQAB", jwk.e); // 65537
    try std.testing.expectEqual(@as(usize, 43), jwk.kid.len); // sha256 b64url

    // PEM round-trips and yields the same public JWK (same key).
    var k2 = try RsaKey.fromPem(pem);
    defer k2.deinit();
    var jwk2 = try k2.publicJwk(a);
    defer jwk2.deinit(a);
    try std.testing.expectEqualStrings(jwk.kid, jwk2.kid);
}
