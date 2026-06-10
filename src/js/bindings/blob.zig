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
const blob_sessions = @import("../blob_sessions.zig");
const blob_receive = @import("../blob_receive.zig");
const http_b = @import("http.zig");

const globals = @import("../globals.zig");

const js_exception = globals.js_exception;
const js_undefined = globals.js_undefined;

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

// ── P2: upload sessions (`docs/blob-storage-plan.md` §3.4) ─────────

/// `_system.blob.write(bytes)` → total session bytes. Appends to
/// this chain's upload session (created on first write) via the
/// worker trampoline. Direct mutation is safe without a commit
/// gate: a faulted activation kills its chain, so an orphaned
/// session is unreachable and TTL-swept (`blob_sessions.zig` header).
pub fn jsBlobWrite(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    const write_fn = state.blob_write orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.write: not supported in this context");
        return js_exception;
    };
    if (argc < 1) {
        _ = c.JS_ThrowTypeError(ctx, "blob.write requires (bytes)");
        return js_exception;
    }

    var cstr: [*c]const u8 = null;
    defer if (cstr != null) c.JS_FreeCString(ctx, cstr);
    const bytes = extractBytes(ctx, argv[0], &cstr) orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.write: bytes must be a string or Uint8Array");
        return js_exception;
    };

    const total = write_fn(
        state.blob_session_ctx.?,
        state.instance_id,
        state.correlation_id,
        bytes,
    ) catch |err| {
        _ = switch (err) {
            error.SessionTooLarge => c.JS_ThrowTypeError(ctx, "blob.write: session exceeds the 64 MiB cap"),
            error.TooManySessions => c.JS_ThrowTypeError(ctx, "blob.write: too many open sessions for this tenant"),
            error.NoChain => c.JS_ThrowTypeError(ctx, "blob.write: no request chain to key the session on"),
            else => c.JS_ThrowTypeError(ctx, "blob.write: out of memory"),
        };
        return js_exception;
    };
    return c.JS_NewInt64(ctx, @intCast(total));
}

/// `_system.blob.seal(to, content_type?)` → hash hex. Finalizes the chain's
/// session: takes the buffer + sha256 from the trampoline and
/// appends a natively-built `connection_scoped` PendingFetch — a PUT
/// through the `rove-blob.internal` door — to the activation's
/// pending-fetches accumulator. The EXISTING handler-success seam
/// then bind-or-drops it exactly like an `on.fetch`: held ⇒ the PUT
/// result resumes this chain at the `to` export (with
/// `request.ctx.hash`); not held ⇒ inert (bytes freed, nothing
/// promised) — the same scope semantics as every `on.*` verb.
pub fn jsBlobSeal(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    const seal_fn = state.blob_seal orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.seal: not supported in this context");
        return js_exception;
    };
    const fetches = state.pending_fetches orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.seal: no connection context for the seal result");
        return js_exception;
    };
    if (argc < 1 or !c.JS_IsString(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "blob.seal requires a `to` export name");
        return js_exception;
    }

    var to_len: usize = 0;
    const to_c = c.JS_ToCStringLen(ctx, &to_len, argv[0]);
    if (to_c == null) return js_exception;
    defer c.JS_FreeCString(ctx, to_c);
    const to = @as([*]const u8, @ptrCast(to_c))[0..to_len];
    if (!http_b.isValidExportName(to)) {
        _ = c.JS_ThrowTypeError(ctx, "blob.seal: `to` must be a JS identifier");
        return js_exception;
    }

    var ct_c: [*c]const u8 = null;
    defer if (ct_c != null) c.JS_FreeCString(ctx, ct_c);
    var content_type: ?[]const u8 = null;
    if (argc >= 2 and c.JS_IsString(argv[1])) {
        var ct_len: usize = 0;
        ct_c = c.JS_ToCStringLen(ctx, &ct_len, argv[1]);
        if (ct_c == null) return js_exception;
        const ct = @as([*]const u8, @ptrCast(ct_c))[0..ct_len];
        if (!isSafeHeaderValue(ct)) {
            _ = c.JS_ThrowTypeError(ctx, "blob.seal: content_type contains invalid characters");
            return js_exception;
        }
        content_type = ct;
    }

    const sealed = seal_fn(
        state.blob_session_ctx.?,
        state.instance_id,
        state.correlation_id,
    ) catch |err| {
        _ = switch (err) {
            error.NoSession => c.JS_ThrowTypeError(ctx, "blob.seal: no open session (nothing written, or already sealed)"),
            error.NoChain => c.JS_ThrowTypeError(ctx, "blob.seal: no request chain"),
            else => c.JS_ThrowTypeError(ctx, "blob.seal: out of memory"),
        };
        return js_exception;
    };
    // From here the sealed body is ours until appended; free on any
    // error path.
    var body_owned: ?[]u8 = sealed.body;
    defer if (body_owned) |b| state.allocator.free(b);

    const a = state.allocator;
    const fetch_id = http_b.deriveFetchIdHex(a, state.request_id, state.http_fetch_index) catch {
        _ = c.JS_ThrowTypeError(ctx, "blob.seal: out of memory");
        return js_exception;
    };
    state.http_fetch_index += 1;
    var id_owned: ?[]u8 = fetch_id;
    defer if (id_owned) |s| a.free(s);

    var built: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (built.items) |s| a.free(s);
        built.deinit(a);
    }
    const url = dupePrint(a, &built, "{s}{s}", .{ blob_sessions.BLOB_ORIGIN_PREFIX, &sealed.hash_hex }) orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.seal: out of memory");
        return js_exception;
    };
    const method = dupePrint(a, &built, "PUT", .{}) orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.seal: out of memory");
        return js_exception;
    };
    const headers_json = if (content_type) |ct|
        dupePrint(a, &built, "{{\"content-type\":\"{s}\"}}", .{ct}) orelse {
            _ = c.JS_ThrowTypeError(ctx, "blob.seal: out of memory");
            return js_exception;
        }
    else
        dupePrint(a, &built, "{{}}", .{}) orelse {
            _ = c.JS_ThrowTypeError(ctx, "blob.seal: out of memory");
            return js_exception;
        };
    const ctx_json = dupePrint(a, &built, "{{\"hash\":\"{s}\"}}", .{&sealed.hash_hex}) orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.seal: out of memory");
        return js_exception;
    };
    const on_chunk = dupePrint(a, &built, "", .{}) orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.seal: out of memory");
        return js_exception;
    };
    const bound_send_id = dupePrint(a, &built, "", .{}) orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.seal: out of memory");
        return js_exception;
    };
    const tenant_dup = dupePrint(a, &built, "{s}", .{state.instance_id}) orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.seal: out of memory");
        return js_exception;
    };
    const name_dup = dupePrint(a, &built, "{s}", .{to}) orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.seal: out of memory");
        return js_exception;
    };

    fetches.append(a, .{
        .tenant_id = tenant_dup,
        .id = id_owned.?,
        .url = url,
        .method = method,
        .headers_json = headers_json,
        .body = body_owned.?,
        // Generous: a 64 MiB body on a slow uplink. The engine's
        // terminal event fires either way.
        .timeout_ms = 300_000,
        .on_chunk_module = on_chunk,
        .ctx_json = ctx_json,
        .stream = false,
        .max_response_chunk_bytes = 64 * 1024,
        .max_total_response_bytes = 1024 * 1024,
        .name = name_dup,
        .bound_send_id = bound_send_id,
        .connection_scoped = true,
    }) catch {
        _ = c.JS_ThrowTypeError(ctx, "blob.seal: out of memory");
        return js_exception;
    };
    // Everything transferred into the PendingFetch — disarm the
    // cleanup defers.
    built.clearRetainingCapacity();
    body_owned = null;
    id_owned = null;

    // The hash is known synchronously (incremental hasher) — return
    // it so the handler can use it immediately; the `to` resume also
    // receives it as `request.ctx.hash` (the seal PUT's ctx_json).
    return c.JS_NewStringLen(ctx, &sealed.hash_hex, 64);
}

/// `_system.blob.receive(to)` — `docs/blob-storage-plan.md` §3.5
/// (P3): pipe the inbound body socket → tenant-prefix S3 multipart
/// with ZERO chunk Msgs. Only callable from an `onHeaders`
/// activation (the body is still at the door); at most once per
/// activation (a receive consumes THE body). Appends a
/// `connection_scoped` PendingFetch through the
/// `rove-receive.internal` door — the EXISTING handler-success seam
/// bind-or-drops it exactly like `blob.seal`'s PUT: held (`next()`)
/// ⇒ the worker arms the upload driver at the commit point and the
/// completion event resumes this chain at `to` with
/// `request.ctx = {hash, len}`; not held ⇒ inert (nothing promised,
/// the stream stays held and the response flips it to discard).
pub fn jsBlobReceive(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (!state.allow_blob_receive) {
        _ = c.JS_ThrowTypeError(ctx, "blob.receive: only callable from an onHeaders activation");
        return js_exception;
    }
    if (state.blob_receive_used) {
        _ = c.JS_ThrowTypeError(ctx, "blob.receive: already called for this request (one inbound body)");
        return js_exception;
    }
    const fetches = state.pending_fetches orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.receive: no connection context");
        return js_exception;
    };
    const ent = state.activation_entity orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.receive: no held socket on this activation");
        return js_exception;
    };
    if (argc < 1 or !c.JS_IsString(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "blob.receive requires a `to` export name");
        return js_exception;
    }

    var to_len: usize = 0;
    const to_c = c.JS_ToCStringLen(ctx, &to_len, argv[0]);
    if (to_c == null) return js_exception;
    defer c.JS_FreeCString(ctx, to_c);
    const to = @as([*]const u8, @ptrCast(to_c))[0..to_len];
    if (!http_b.isValidExportName(to)) {
        _ = c.JS_ThrowTypeError(ctx, "blob.receive: `to` must be a JS identifier");
        return js_exception;
    }

    const a = state.allocator;
    const fetch_id = http_b.deriveFetchIdHex(a, state.request_id, state.http_fetch_index) catch {
        _ = c.JS_ThrowTypeError(ctx, "blob.receive: out of memory");
        return js_exception;
    };
    state.http_fetch_index += 1;
    var id_owned: ?[]u8 = fetch_id;
    defer if (id_owned) |s| a.free(s);

    var built: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (built.items) |s| a.free(s);
        built.deinit(a);
    }
    const url = dupePrint(a, &built, "{s}{d}.{d}", .{
        blob_receive.RECEIVE_ORIGIN_PREFIX, ent.index, ent.generation,
    }) orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.receive: out of memory");
        return js_exception;
    };
    const method = dupePrint(a, &built, "PUT", .{}) orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.receive: out of memory");
        return js_exception;
    };
    const headers_json = dupePrint(a, &built, "{{}}", .{}) orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.receive: out of memory");
        return js_exception;
    };
    const ctx_json = dupePrint(a, &built, "{{}}", .{}) orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.receive: out of memory");
        return js_exception;
    };
    const empty1 = dupePrint(a, &built, "", .{}) orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.receive: out of memory");
        return js_exception;
    };
    const empty2 = dupePrint(a, &built, "", .{}) orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.receive: out of memory");
        return js_exception;
    };
    const empty3 = dupePrint(a, &built, "", .{}) orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.receive: out of memory");
        return js_exception;
    };
    const tenant_dup = dupePrint(a, &built, "{s}", .{state.instance_id}) orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.receive: out of memory");
        return js_exception;
    };
    const name_dup = dupePrint(a, &built, "{s}", .{to}) orelse {
        _ = c.JS_ThrowTypeError(ctx, "blob.receive: out of memory");
        return js_exception;
    };

    fetches.append(a, .{
        .tenant_id = tenant_dup,
        .id = id_owned.?,
        .url = url,
        .method = method,
        .headers_json = headers_json,
        .body = empty1,
        .timeout_ms = 0,
        .on_chunk_module = empty2,
        .ctx_json = ctx_json,
        .stream = false,
        .max_response_chunk_bytes = 64 * 1024,
        .max_total_response_bytes = 1024 * 1024,
        .name = name_dup,
        .bound_send_id = empty3,
        .connection_scoped = true,
    }) catch {
        _ = c.JS_ThrowTypeError(ctx, "blob.receive: out of memory");
        return js_exception;
    };
    built.clearRetainingCapacity();
    id_owned = null;
    state.blob_receive_used = true;

    return js_undefined;
}

/// Append-or-null print helper: dupes the formatted string and
/// tracks it in `built` so one defer frees every not-yet-transferred
/// piece on the error paths.
fn dupePrint(
    a: std.mem.Allocator,
    built: *std.ArrayListUnmanaged([]u8),
    comptime fmt: []const u8,
    args: anytype,
) ?[]u8 {
    const s = std.fmt.allocPrint(a, fmt, args) catch return null;
    built.append(a, s) catch {
        a.free(s);
        return null;
    };
    return s;
}

/// Read a JS value as bytes: string (UTF-8) or Uint8Array. Mirrors
/// crypto.zig's extractKeyOrDataBytes.
fn extractBytes(
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
        const pending = c.JS_GetException(ctx);
        c.JS_FreeValue(ctx, pending);
        return null;
    }
    return buf_ptr[0..byte_len];
}

/// Conservative header-value check for the signed-through
/// content-type: printable ASCII, no quotes/backslashes (it is
/// interpolated into a JSON string literal).
fn isSafeHeaderValue(s: []const u8) bool {
    if (s.len == 0 or s.len > 256) return false;
    for (s) |b| {
        if (b < 0x20 or b > 0x7e or b == '"' or b == '\\') return false;
    }
    return true;
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
