//! `_system.blob.*` native bindings — `docs/blob-storage-plan.md` P1.
//!
//! Only one verb lives natively: `presign`. It is the single blob
//! verb a customer categorically cannot compose in JS — it requires
//! the platform-held S3 signing keys. Everything else (`put` / `get`
//! / the owed-marker durability composition) is readable JavaScript
//! in `globals/blob.js`, riding the fetch engine's
//! `rove-blob.internal` trusted door (`fetch_engine.zig`
//! `rewriteAndSignBlobFetch`).
//!
//! Determinism: the presigned URL embeds a timestamp. We derive it
//! from the activation's TAPED clock (`readset.timestamp_ns` — the
//! same scalar that pins `Date.now()`), never the wall clock, so
//! replay reproduces the URL bit-for-bit. The TTL window is anchored
//! to handler-visible time, which is what the author reasons about
//! anyway.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;
const blob_mod = @import("rove-blob");

const globals = @import("../globals.zig");

const js_exception = globals.js_exception;

/// Default + max TTL for presigned URLs. SigV4 caps expiry at 7
/// days; we default to 5 minutes (the deployment-statics redirect
/// path uses 1 hour — callers pick per use).
const PRESIGN_DEFAULT_TTL_SECS: u32 = 300;
const PRESIGN_MAX_TTL_SECS: u32 = 604_800;

/// `_system.blob.presign(hash, ttl_secs?, content_type?)` → URL
/// string. Presigned GET against the calling tenant's
/// `{key_prefix_base}{instance_id}/app-blobs/{hash}` key.
pub fn jsBlobPresign(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);

    if (argc < 1 or !c.JS_IsString(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "blob.url requires a hash string");
        return js_exception;
    }
    var hash_len: usize = 0;
    const hash_c = c.JS_ToCStringLen(ctx, &hash_len, argv[0]);
    if (hash_c == null) return js_exception;
    defer c.JS_FreeCString(ctx, hash_c);
    const hash = @as([*]const u8, @ptrCast(hash_c))[0..hash_len];
    if (!isSha256HexLower(hash)) {
        _ = c.JS_ThrowTypeError(ctx, "blob.url: hash must be 64 lowercase hex chars");
        return js_exception;
    }

    var ttl_secs: u32 = PRESIGN_DEFAULT_TTL_SECS;
    if (argc >= 2 and !c.JS_IsUndefined(argv[1]) and !c.JS_IsNull(argv[1])) {
        var ttl_i: i32 = 0;
        if (c.JS_ToInt32(ctx, &ttl_i, argv[1]) != 0) return js_exception;
        if (ttl_i < 1 or ttl_i > PRESIGN_MAX_TTL_SECS) {
            _ = c.JS_ThrowTypeError(ctx, "blob.url: ttl must be 1..604800 seconds");
            return js_exception;
        }
        ttl_secs = @intCast(ttl_i);
    }

    var ct_c: [*c]const u8 = null;
    defer if (ct_c != null) c.JS_FreeCString(ctx, ct_c);
    var content_type: ?[]const u8 = null;
    if (argc >= 3 and c.JS_IsString(argv[2])) {
        var ct_len: usize = 0;
        ct_c = c.JS_ToCStringLen(ctx, &ct_len, argv[2]);
        if (ct_c == null) return js_exception;
        content_type = @as([*]const u8, @ptrCast(ct_c))[0..ct_len];
    }

    const cfg = state.blob_cfg orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.url: blob storage backend is not configured");
        return js_exception;
    };
    if (cfg.endpoint.len == 0 or state.instance_id.len == 0) {
        _ = c.JS_ThrowTypeError(ctx, "blob.url: blob storage backend is not configured");
        return js_exception;
    }

    // Taped clock: the activation's pinned timestamp, same scalar
    // that drives Date.now(). Unit-test dispatches without a readset
    // fall back to the wall clock (nothing to replay there).
    const epoch_secs: i64 = if (state.readset) |rs|
        @divTrunc(rs.timestamp_ns, std.time.ns_per_s)
    else
        std.time.timestamp();
    var ts_buf: [16]u8 = undefined;
    blob_mod.sigv4.formatAmzDate(&ts_buf, epoch_secs);

    const a = state.allocator;
    const path = std.fmt.allocPrint(
        a,
        "/{s}/{s}{s}/app-blobs/{s}",
        .{ cfg.bucket, cfg.key_prefix_base, state.instance_id, hash },
    ) catch {
        state.pending_kv_error = error.OutOfMemory;
        return js_exception;
    };
    defer a.free(path);

    const scheme = if (cfg.use_tls) "https" else "http";
    const url = blob_mod.sigv4.presignGet(a, scheme, .{
        .method = "GET",
        .path = path,
        .host = cfg.endpoint,
        .access_key = cfg.access_key,
        .secret_key = cfg.secret_key,
        .region = cfg.region,
        .service = "s3",
        .timestamp = &ts_buf,
        .expires_secs = ttl_secs,
        .response_content_type = content_type,
    }) catch {
        _ = c.JS_ThrowTypeError(ctx, "blob.url: presign failed");
        return js_exception;
    };
    defer a.free(url);

    return c.JS_NewStringLen(ctx, url.ptr, url.len);
}

/// Same validator as the fetch engine's trusted door — exactly 64
/// lowercase hex chars.
fn isSha256HexLower(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |b| {
        const ok = (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f');
        if (!ok) return false;
    }
    return true;
}
