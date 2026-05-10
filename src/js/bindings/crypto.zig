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
