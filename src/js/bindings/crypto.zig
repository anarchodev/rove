//! Core `crypto.*` JS bindings: randomness + hashing.
//!
//! Randomness draws from arenajs's per-context xorshift64star via
//! `JS_FillRandomBytes` — seeded once per request from `readset.seed`
//! in `globals.installRequest` (§9 seed-not-draws). Replay reproduces
//! the same byte sequence by reseeding the PRNG with the captured
//! request's seed; no per-draw tape entries. Hashes are pure (no
//! readset capture needed) and use Zig std.crypto — no OpenSSL.
//!
//! The OpenSSL-backed signature surfaces live in sibling modules:
//! `crypto_jose.zig` (RSA/ECDSA JWS verify + OIDC keys) and
//! `crypto_ecdsa.zig` (raw-key ECDSA for atproto/did:key), with shared
//! EVP mechanism in `crypto_util.zig`.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;

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

    // `docs/primitive-gaps.md` §9 — bytes come from arenajs's per-
    // request xorshift64star state (seeded once per request via
    // JS_SetRandomSeed). Same PRNG Math.random draws from, so replay
    // reproduces by re-seeding with the recorded request seed. No
    // tape entry — the seed scalar on the readset header is the
    // entire "tape" for random.
    _ = state;
    c.JS_FillRandomBytes(ctx, buf_ptr, byte_len);
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
    var raw: [16]u8 = undefined;
    // §9: bytes from arenajs's per-request PRNG, same stream as
    // Math.random + crypto.*. Replay reproduces by re-seeding.
    c.JS_FillRandomBytes(ctx, &raw, raw.len);
    // RFC 4122 v4: set the version and variant bits.
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;

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
/// bytes drawn from the per-context PRNG (xorshift64star, seeded
/// once per request from `readset.seed`). Replay reproduces the
/// same sequence by reseeding before the handler runs (§9
/// seed-not-draws — no per-draw tape entries).
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

    // §9: same xorshift64star state as Math.random.
    c.JS_FillRandomBytes(ctx, bytes.ptr, bytes.len);

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
