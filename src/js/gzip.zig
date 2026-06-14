//! gzip.zig — thin libz (zlib) gzip compress/decompress.
//!
//! Resident HTML documents are held gzip-compressed in worker RAM and
//! served verbatim with `Content-Encoding: gzip` (decompressed only for
//! the rare client that doesn't accept gzip). We go straight to libz
//! rather than `std.compress.flate`: Zig 0.15.x's `flate.Compress.drain`
//! has a `@panic("TODO")` in the tokenization path and corrupts payloads
//! past its lookahead window (same reason `src/log_server/flush_writer.zig`
//! uses libz). zlib is already linked into the worker.

const std = @import("std");

const c = @cImport({
    @cInclude("zlib.h");
});

pub const Error = error{ GzipInit, GzipFailed } || std.mem.Allocator.Error;

// windowBits 15 (max window) + 16 (gzip wrapper, RFC 1952) → output that
// a browser serves directly as `Content-Encoding: gzip`.
const GZIP_WINDOW_BITS: c_int = 15 + 16;

/// gzip-compress `src`; returns owned bytes. Done once per HTML doc at
/// deploy load, so favor ratio (zlib default level 6).
pub fn compress(allocator: std.mem.Allocator, src: []const u8) Error![]u8 {
    var z: c.z_stream = std.mem.zeroes(c.z_stream);
    if (c.deflateInit2_(
        &z,
        c.Z_DEFAULT_COMPRESSION,
        c.Z_DEFLATED,
        GZIP_WINDOW_BITS,
        8,
        c.Z_DEFAULT_STRATEGY,
        c.zlibVersion(),
        @sizeOf(c.z_stream),
    ) != c.Z_OK) return Error.GzipInit;
    defer _ = c.deflateEnd(&z);

    // deflateBound is a safe upper bound for a single-shot Z_FINISH, so
    // the whole input compresses in one call (no grow loop).
    const bound: usize = @intCast(c.deflateBound(&z, @intCast(src.len)));
    const out = try allocator.alloc(u8, bound);
    errdefer allocator.free(out);

    z.next_in = @constCast(src.ptr);
    z.avail_in = @intCast(src.len);
    z.next_out = out.ptr;
    z.avail_out = @intCast(out.len);
    if (c.deflate(&z, c.Z_FINISH) != c.Z_STREAM_END) return Error.GzipFailed;

    // Shrink to the actual size — these bytes stay resident for the
    // snapshot's life, so don't hold the deflateBound slack.
    const written = out.len - z.avail_out;
    return allocator.realloc(out, written);
}

/// gunzip `src` into owned bytes. `raw_len` is the exact uncompressed
/// size (we store it alongside the compressed bytes), so the output buffer
/// is sized once and inflate finishes in a single pass.
pub fn decompress(allocator: std.mem.Allocator, src: []const u8, raw_len: usize) Error![]u8 {
    var z: c.z_stream = std.mem.zeroes(c.z_stream);
    if (c.inflateInit2_(
        &z,
        GZIP_WINDOW_BITS,
        c.zlibVersion(),
        @sizeOf(c.z_stream),
    ) != c.Z_OK) return Error.GzipInit;
    defer _ = c.inflateEnd(&z);

    var out = try allocator.alloc(u8, @max(raw_len, 1));
    errdefer allocator.free(out);

    z.next_in = @constCast(src.ptr);
    z.avail_in = @intCast(src.len);
    z.next_out = out.ptr;
    z.avail_out = @intCast(out.len);

    while (true) {
        const rc = c.inflate(&z, c.Z_NO_FLUSH);
        if (rc == c.Z_STREAM_END) break;
        if (rc != c.Z_OK) return Error.GzipFailed;
        if (z.avail_out == 0) {
            // raw_len under-estimated (shouldn't happen — it's exact) —
            // grow defensively rather than truncate.
            const used = out.len;
            out = try allocator.realloc(out, out.len * 2);
            z.next_out = out.ptr + used;
            z.avail_out = @intCast(out.len - used);
        }
    }

    const written = out.len - z.avail_out;
    return allocator.realloc(out, written);
}

// ── Tests ──────────────────────────────────────────────────────────

test "gzip round-trips and produces a gzip magic header" {
    const a = std.testing.allocator;
    const original = "<!doctype html><title>hi</title>" ** 64; // ~2KB, compresses well
    const gz = try compress(a, original);
    defer a.free(gz);
    // RFC 1952 gzip magic: 0x1f 0x8b.
    try std.testing.expect(gz.len >= 2 and gz[0] == 0x1f and gz[1] == 0x8b);
    try std.testing.expect(gz.len < original.len); // actually compressed

    const back = try decompress(a, gz, original.len);
    defer a.free(back);
    try std.testing.expectEqualStrings(original, back);
}

test "gzip handles empty input" {
    const a = std.testing.allocator;
    const gz = try compress(a, "");
    defer a.free(gz);
    const back = try decompress(a, gz, 0);
    defer a.free(back);
    try std.testing.expectEqual(@as(usize, 0), back.len);
}
