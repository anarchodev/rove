//! Native UTF-8 transcode for `TextEncoder` / `TextDecoder`
//! (`_system.textcodec.*`).
//!
//! The original pure-JS shim decoded byte-by-byte with
//! `s += String.fromCharCode(b)` — ~N string reallocations of
//! intermediate garbage, which a no-reclaim bump arena counts in
//! full: a ~139 KB decode exhausted the (then 4 MiB) request arena.
//! Natively both directions are a single conversion: QuickJS strings
//! construct FROM UTF-8 (`JS_NewStringLen`) and convert TO UTF-8
//! (`JS_ToCStringLen`), so decode/encode are one allocation each,
//! O(1) garbage, and multi-MB payloads cost what they weigh.
//!
//! The WHATWG-shaped class shells (label validation, `fatal`,
//! BufferSource normalization) stay in `globals/textcodec.js`; only
//! the byte work lives here.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;

const globals = @import("../globals.zig");

const js_exception = globals.js_exception;

/// `_system.textcodec.encode(str)` → Uint8Array (UTF-8 bytes).
/// The shim coerces to string first; quickjs-ng's conversion handles
/// surrogate pairs (lone surrogates become U+FFFD, matching the
/// WHATWG encoder's replacement behavior).
pub fn jsTextEncode(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1 or !c.JS_IsString(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "textcodec.encode: expected a string");
        return js_exception;
    }
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, argv[0]);
    if (cstr == null) return js_exception;
    defer c.JS_FreeCString(ctx, cstr);
    return c.JS_NewUint8ArrayCopy(ctx, @ptrCast(cstr), len);
}

/// `_system.textcodec.decode(u8, fatal)` → string.
///
/// Valid UTF-8 (the overwhelmingly common case) is one
/// `JS_NewStringLen` — no copy beyond the string itself. Invalid
/// input: `fatal` throws `TypeError` (same message the JS shim
/// used); lenient substitutes U+FFFD per invalid sequence via a
/// one-pass Zig sanitize, then converts the (now valid) buffer.
/// Validating ourselves matters: `JS_NewStringLen` on malformed
/// UTF-8 falls back to latin-1 byte semantics, which is neither
/// WHATWG behavior.
pub fn jsTextDecode(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (argc < 1) {
        _ = c.JS_ThrowTypeError(ctx, "textcodec.decode: expected a Uint8Array");
        return js_exception;
    }
    var byte_len: usize = 0;
    const buf_ptr = c.JS_GetUint8Array(ctx, &byte_len, argv[0]);
    if (buf_ptr == null) {
        const pending = c.JS_GetException(ctx);
        c.JS_FreeValue(ctx, pending);
        _ = c.JS_ThrowTypeError(ctx, "textcodec.decode: expected a Uint8Array");
        return js_exception;
    }
    const bytes = buf_ptr[0..byte_len];
    if (bytes.len == 0) return c.JS_NewStringLen(ctx, "", 0);

    if (std.unicode.utf8ValidateSlice(bytes)) {
        return c.JS_NewStringLen(ctx, bytes.ptr, bytes.len);
    }

    const fatal = argc >= 2 and c.JS_ToBool(ctx, argv[1]) != 0;
    if (fatal) {
        _ = c.JS_ThrowTypeError(ctx, "TextDecoder: malformed utf-8");
        return js_exception;
    }

    const sanitized = sanitizeUtf8(state.allocator, bytes) catch {
        _ = c.JS_ThrowTypeError(ctx, "textcodec.decode: out of memory");
        return js_exception;
    };
    defer state.allocator.free(sanitized);
    return c.JS_NewStringLen(ctx, sanitized.ptr, sanitized.len);
}

const REPLACEMENT = "\xef\xbf\xbd"; // U+FFFD as UTF-8

/// Replace every invalid sequence with U+FFFD (one replacement per
/// rejected lead byte — same looseness as the retired JS shim; the
/// WHATWG maximal-subpart refinement is not load-bearing for any
/// in-tree consumer). Caller frees.
fn sanitizeUtf8(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    // Valid input never grows; each invalid byte adds ≤ 3 bytes.
    try out.ensureTotalCapacity(allocator, bytes.len + 16);
    var i: usize = 0;
    while (i < bytes.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.appendSlice(allocator, REPLACEMENT);
            i += 1;
            continue;
        };
        if (i + seq_len > bytes.len or
            !std.unicode.utf8ValidateSlice(bytes[i .. i + seq_len]))
        {
            try out.appendSlice(allocator, REPLACEMENT);
            i += 1;
            continue;
        }
        try out.appendSlice(allocator, bytes[i .. i + seq_len]);
        i += seq_len;
    }
    return out.toOwnedSlice(allocator);
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "sanitizeUtf8 passes valid input through and substitutes invalid bytes" {
    const valid = "héllo wörld ✓";
    const s1 = try sanitizeUtf8(testing.allocator, valid);
    defer testing.allocator.free(s1);
    try testing.expectEqualStrings(valid, s1);

    // Lone continuation byte + truncated 3-byte lead at end.
    const bad = "ok\x80then\xe2\x82";
    const s2 = try sanitizeUtf8(testing.allocator, bad);
    defer testing.allocator.free(s2);
    try testing.expectEqualStrings("ok\xef\xbf\xbdthen\xef\xbf\xbd\xef\xbf\xbd", s2);
    try testing.expect(std.unicode.utf8ValidateSlice(s2));

    // UTF-8-encoded surrogate (invalid per RFC 3629).
    const surrogate = "\xed\xa0\x80";
    const s3 = try sanitizeUtf8(testing.allocator, surrogate);
    defer testing.allocator.free(s3);
    try testing.expect(std.unicode.utf8ValidateSlice(s3));
}
