//! JOSE / OIDC crypto bindings: RSA + ECDSA JWS signature verification
//! and OIDC RS256 key custody. The *policy* here is JOSE's: variable
//! digest from the `alg` argument, JWK key inputs, curves P-256/384/521,
//! and **no low-S enforcement** (JOSE doesn't require it). The OpenSSL
//! mechanism (EC point → EVP_PKEY, R‖S → DER, digest-verify) is shared
//! via `crypto_util`. Kept separate from the raw-key ECDSA surface
//! (`crypto_ecdsa.zig`) so neither surface's policy shifts the other's.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;

const globals = @import("../globals.zig");
const cu = @import("crypto_util.zig");
const ssl = cu.ssl;

const js_exception = globals.js_exception;

/// JOSE curve table: OpenSSL group name + JWS coordinate size. (No
/// low-S metadata — JOSE doesn't normalize S; see `crypto_ecdsa.zig`'s
/// `SignCurve` for the atproto path that does.)
const Curve = struct {
    ossl_name: []const u8,
    coord_size: usize,
};

fn curveForName(name: []const u8) ?Curve {
    if (std.mem.eql(u8, name, "P-256")) return .{ .ossl_name = "P-256", .coord_size = 32 };
    if (std.mem.eql(u8, name, "P-384")) return .{ .ossl_name = "P-384", .coord_size = 48 };
    if (std.mem.eql(u8, name, "P-521")) return .{ .ossl_name = "P-521", .coord_size = 66 };
    if (std.mem.eql(u8, name, "secp256k1")) return .{ .ossl_name = "secp256k1", .coord_size = 32 };
    return null;
}

/// `crypto.verifyRsa(jwk, alg, data, sig) → bool`
///
/// Verify an RSA-PKCS#1 v1.5 signature using OpenSSL. Used by customer
/// JS to validate OIDC id_tokens (JWS RS256/RS384/RS512).
///
/// Arguments:
///   - `jwk`:  `{kty:"RSA", n:base64url, e:base64url}` (JWKS shape).
///   - `alg`:  "sha256" / "sha384" / "sha512" (case-insensitive).
///   - `data`: Uint8Array — for JWS, `header_b64 || "." || payload_b64`.
///   - `sig`:  Uint8Array of the raw signature (third JWS segment,
///             base64url-decoded by the caller).
///
/// Returns `true`/`false`. Does NOT validate JWT claims (iss/aud/exp/…).
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
    const kty = cu.jsObjStringField(ctx, allocator, argv[0], "kty") catch {
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
    const n_b64_opt = cu.jsObjStringField(ctx, allocator, argv[0], "n") catch return js_exception;
    const n_b64 = n_b64_opt orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyRsa: jwk.n missing");
        return js_exception;
    };
    defer allocator.free(n_b64);
    const e_b64_opt = cu.jsObjStringField(ctx, allocator, argv[0], "e") catch return js_exception;
    const e_b64 = e_b64_opt orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyRsa: jwk.e missing");
        return js_exception;
    };
    defer allocator.free(e_b64);

    const n_bytes = cu.base64urlDecode(allocator, n_b64) catch {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyRsa: jwk.n is not valid base64url");
        return js_exception;
    };
    defer allocator.free(n_bytes);
    const e_bytes = cu.base64urlDecode(allocator, e_b64) catch {
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
    const md = cu.mdForAlg(alg) orelse {
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

    const ok = cu.evpDigestVerify(md, pkey.?, data_ptr[0..data_len], sig_ptr[0..sig_len]) catch {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyRsa: verify failed");
        return js_exception;
    };
    return if (ok) globals.js_true else globals.js_false;
}

/// `crypto.verifyEcdsa(jwk, alg, data, sig) → bool`
///
/// Verify a JWS-style ECDSA signature (ES256/384/512) using OpenSSL.
///
/// Arguments:
///   - `jwk`:  `{kty:"EC", crv, x:base64url, y:base64url}`; `crv` ∈
///             {P-256, P-384, P-521}.
///   - `alg`:  "sha256" / "sha384" / "sha512" (case-insensitive).
///   - `data`: Uint8Array (JWS signing input).
///   - `sig`:  Uint8Array — raw R‖S (64/96/132 bytes), NOT DER; this
///             binding converts to DER internally.
///
/// Returns `true`/`false`. Does NOT validate JWT claims. Does NOT
/// enforce low-S (JOSE permits high-S; the atproto surface differs).
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

    const kty_opt = cu.jsObjStringField(ctx, allocator, argv[0], "kty") catch return js_exception;
    const kty = kty_opt orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: jwk.kty missing");
        return js_exception;
    };
    defer allocator.free(kty);
    if (!std.mem.eql(u8, kty, "EC")) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: only EC kty supported");
        return js_exception;
    }

    const crv_opt = cu.jsObjStringField(ctx, allocator, argv[0], "crv") catch return js_exception;
    const crv = crv_opt orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: jwk.crv missing");
        return js_exception;
    };
    defer allocator.free(crv);
    const curve = curveForName(crv) orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: jwk.crv must be P-256 / P-384 / P-521");
        return js_exception;
    };

    const x_opt = cu.jsObjStringField(ctx, allocator, argv[0], "x") catch return js_exception;
    const x_b64 = x_opt orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: jwk.x missing");
        return js_exception;
    };
    defer allocator.free(x_b64);
    const y_opt = cu.jsObjStringField(ctx, allocator, argv[0], "y") catch return js_exception;
    const y_b64 = y_opt orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: jwk.y missing");
        return js_exception;
    };
    defer allocator.free(y_b64);

    const x_bytes = cu.base64urlDecode(allocator, x_b64) catch {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: jwk.x is not valid base64url");
        return js_exception;
    };
    defer allocator.free(x_bytes);
    const y_bytes = cu.base64urlDecode(allocator, y_b64) catch {
        _ = c.JS_ThrowTypeError(ctx, "crypto.verifyEcdsa: jwk.y is not valid base64url");
        return js_exception;
    };
    defer allocator.free(y_bytes);

    // JWA leftpads x and y to coord_size; some JWKs in the wild emit
    // shorter values when leading bytes are zero. Accept ≤ coord_size
    // (we left-pad below); reject >.
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
    const md = cu.mdForAlg(alg) orelse {
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

    // Build uncompressed public-key point: 0x04 || X || Y, X and Y
    // left-zero-padded to coord_size.
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

    const pkey = cu.ecPubKeyFromPoint(curve.ossl_name, point) catch {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyEcdsa: public key build failed");
        return js_exception;
    };
    defer ssl.EVP_PKEY_free(pkey);

    // JWS sig is raw R||S; OpenSSL EVP_DigestVerify wants DER. Worst-case
    // length for P-521: 1+2+138 = 141 bytes; 256 buffer covers all curves.
    var der_buf: [256]u8 = undefined;
    const der = cu.encodeEcdsaSigDer(
        &der_buf,
        sig_ptr[0..curve.coord_size],
        (sig_ptr + curve.coord_size)[0..curve.coord_size],
    ) catch {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyEcdsa: DER encoding failed");
        return js_exception;
    };

    const ok = cu.evpDigestVerify(md, pkey, data_ptr[0..data_len], der) catch {
        _ = c.JS_ThrowInternalError(ctx, "crypto.verifyEcdsa: verify failed");
        return js_exception;
    };
    return if (ok) globals.js_true else globals.js_false;
}

// =============================================================================
// OIDC RS256 key custody (auth-domain-plan §4.7 fork A: HYBRID).
//
// Generation + signing are Zig/OpenSSL; the RSA private key is handed to
// JS only as an opaque PKCS#8 PEM string it stores in kv and passes back
// verbatim — JS never does private-key math.
// =============================================================================

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
        return cu.bioDrain(allocator, bio);
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
        const n_b64 = try cu.b64urlEnc(allocator, n_raw);
        errdefer allocator.free(n_b64);
        const e_b64 = try cu.b64urlEnc(allocator, e_raw);
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
        const kid = try cu.b64urlEnc(allocator, &digest);
        return .{ .n = n_b64, .e = e_b64, .kid = kid };
    }

    /// RS256 (RSASSA-PKCS1-v1_5 + SHA-256). Returns base64url(sig).
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
        return cu.b64urlEnc(allocator, sig[0..siglen]);
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

const testing = std.testing;

test "RSA keygen → RS256 sign verifies; JWK + kid well-formed" {
    const a = testing.allocator;
    var k = try RsaKey.generate();
    defer k.deinit();

    const pem = try k.privatePem(a);
    defer a.free(pem);
    try testing.expect(std.mem.indexOf(u8, pem, "PRIVATE KEY") != null);

    const sig_b64 = try k.signRs256(a, "oidc id_token signing input");
    defer a.free(sig_b64);
    const sig = try cu.base64urlDecode(a, sig_b64);
    defer a.free(sig);
    // Verify with OpenSSL directly (proves the sig is real RS256).
    const mdctx = ssl.EVP_MD_CTX_new().?;
    defer ssl.EVP_MD_CTX_free(mdctx);
    try testing.expect(ssl.EVP_DigestVerifyInit(mdctx, null, ssl.EVP_sha256(), null, k.pkey) == 1);
    const msg = "oidc id_token signing input";
    try testing.expect(ssl.EVP_DigestVerify(mdctx, sig.ptr, sig.len, msg, msg.len) == 1);

    var jwk = try k.publicJwk(a);
    defer jwk.deinit(a);
    try testing.expect(jwk.n.len > 300); // 2048-bit modulus, b64url
    try testing.expectEqualStrings("AQAB", jwk.e); // 65537
    try testing.expectEqual(@as(usize, 43), jwk.kid.len); // sha256 b64url

    // PEM round-trips and yields the same public JWK (same key).
    var k2 = try RsaKey.fromPem(pem);
    defer k2.deinit();
    var jwk2 = try k2.publicJwk(a);
    defer jwk2.deinit(a);
    try testing.expectEqualStrings(jwk.kid, jwk2.kid);
}
