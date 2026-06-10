//! `s3-blob-smoke` — exercise `S3BlobStore` against any
//! S3-compatible endpoint (default config targets OVH Object
//! Storage). Pure round-trip test: put → exists → get → delete.
//!
//! Configuration via env vars (no secrets on the CLI):
//!
//!   S3_ENDPOINT      hostname only, no scheme
//!                    e.g. s3.gra.io.cloud.ovh.net
//!   S3_REGION        SigV4 signing region; must match the endpoint
//!                    e.g. gra
//!   S3_BUCKET        bucket name (path-style addressing)
//!   S3_KEY_PREFIX    optional prefix prepended to every key
//!                    (default empty); useful to simulate per-tenant
//!                    scoping
//!   AWS_ACCESS_KEY_ID
//!   AWS_SECRET_ACCESS_KEY
//!
//! Usage:
//!
//!   export S3_ENDPOINT=s3.gra.io.cloud.ovh.net
//!   export S3_REGION=gra
//!   export S3_BUCKET=loop46-smoke
//!   export AWS_ACCESS_KEY_ID=...
//!   export AWS_SECRET_ACCESS_KEY=...
//!   ./zig-out/bin/s3-blob-smoke
//!
//! Exits 0 on full success, prints "PASS"; exits 1 on any failure
//! and prints diagnostics to stderr.

const std = @import("std");
const blob = @import("rove-blob");

/// Default log level — show warn/err so init / wire failures emit
/// the specific reason instead of just the bubbled error name.
pub const std_options: std.Options = .{
    .log_level = .warn,
};

const ENV_ENDPOINT = "S3_ENDPOINT";
const ENV_REGION = "S3_REGION";
const ENV_BUCKET = "S3_BUCKET";
const ENV_KEY_PREFIX = "S3_KEY_PREFIX";
const ENV_AK = "AWS_ACCESS_KEY_ID";
const ENV_SK = "AWS_SECRET_ACCESS_KEY";

fn elapsedMs(start_ns: i128) u64 {
    const now = std.time.nanoTimestamp();
    const d = if (now > start_ns) now - start_ns else 0;
    return @intCast(@divFloor(d, std.time.ns_per_ms));
}

fn elapsedMsSince(start_ns: i128) u64 {
    return elapsedMs(start_ns);
}

fn fail(msg: []const u8) noreturn {
    var buf: [1024]u8 = undefined;
    var sw = std.fs.File.stderr().writer(&buf);
    sw.interface.writeAll(msg) catch {};
    sw.interface.writeAll("\n") catch {};
    sw.interface.flush() catch {};
    std.process.exit(1);
}

fn getenvRequired(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const v = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "missing required env: {s}", .{name}) catch "env missing";
            fail(msg);
        },
        else => return err,
    };
    return v;
}

fn getenvOpt(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => err,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const endpoint = try getenvRequired(allocator, ENV_ENDPOINT);
    defer allocator.free(endpoint);
    const region = try getenvRequired(allocator, ENV_REGION);
    defer allocator.free(region);
    const bucket = try getenvRequired(allocator, ENV_BUCKET);
    defer allocator.free(bucket);
    const ak = try getenvRequired(allocator, ENV_AK);
    defer allocator.free(ak);
    const sk = try getenvRequired(allocator, ENV_SK);
    defer allocator.free(sk);

    const key_prefix_owned = try getenvOpt(allocator, ENV_KEY_PREFIX);
    defer if (key_prefix_owned) |p| allocator.free(p);
    const key_prefix: []const u8 = key_prefix_owned orelse "";

    var stdout_buf: [1024]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    const out = &sw.interface;
    try out.print(
        "s3-blob-smoke: endpoint={s} region={s} bucket={s} key_prefix='{s}'\n",
        .{ endpoint, region, bucket, key_prefix },
    );
    try out.flush();

    // Timer base for "ms since start" prefixes — easy way to spot
    // slow first-request paths in the smoke log without paying for
    // a structured-logger.
    const start_ns = std.time.nanoTimestamp();

    var store = blob.S3BlobStore.init(allocator, .{
        .endpoint = endpoint,
        .region = region,
        .bucket = bucket,
        .key_prefix = key_prefix,
        .access_key = ak,
        .secret_key = sk,
    }) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "init failed: {s}", .{@errorName(err)}) catch "init failed";
        fail(msg);
    };
    defer store.deinit();

    const bs = store.blobStore();

    // Random key so concurrent runs don't trample each other.
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var key_buf: [80]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "rove-smoke-{x}", .{seed});

    // ── 1. exists on missing key → false ──────────────────────────────
    var t = std.time.nanoTimestamp();
    try out.print("[+{d:>6}ms] →  exists(missing) ...\n", .{elapsedMs(start_ns)});
    try out.flush();
    const exists0 = bs.exists(key) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "exists(missing) failed: {s}", .{@errorName(err)}) catch "exists failed";
        fail(msg);
    };
    if (exists0) fail("exists(missing) returned true — key collision?");
    try out.print("[+{d:>6}ms] ok  exists(missing) → false ({d}ms)\n", .{ elapsedMs(start_ns), elapsedMsSince(t) });
    try out.flush();

    // ── 2. put a known payload ────────────────────────────────────────
    t = std.time.nanoTimestamp();
    try out.print("[+{d:>6}ms] →  put ...\n", .{elapsedMs(start_ns)});
    try out.flush();
    const payload = "hello from rove-blob s3 smoke\nbinary too: \x00\x01\x02\xff";
    bs.put(key, payload) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "put failed: {s}", .{@errorName(err)}) catch "put failed";
        fail(msg);
    };
    try out.print("[+{d:>6}ms] ok  put ({d}ms)\n", .{ elapsedMs(start_ns), elapsedMsSince(t) });
    try out.flush();

    // ── 3. exists after put → true ────────────────────────────────────
    t = std.time.nanoTimestamp();
    try out.print("[+{d:>6}ms] →  exists(after put) ...\n", .{elapsedMs(start_ns)});
    try out.flush();
    const exists1 = bs.exists(key) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "exists(after put) failed: {s}", .{@errorName(err)}) catch "exists failed";
        fail(msg);
    };
    if (!exists1) fail("exists(after put) returned false");
    try out.print("[+{d:>6}ms] ok  exists(after put) → true ({d}ms)\n", .{ elapsedMs(start_ns), elapsedMsSince(t) });
    try out.flush();

    // ── 4. get → byte-identical ───────────────────────────────────────
    t = std.time.nanoTimestamp();
    try out.print("[+{d:>6}ms] →  get ...\n", .{elapsedMs(start_ns)});
    try out.flush();
    const got = bs.get(key, allocator) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "get failed: {s}", .{@errorName(err)}) catch "get failed";
        fail(msg);
    };
    defer allocator.free(got);
    if (!std.mem.eql(u8, got, payload)) {
        var ebuf: [1024]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&ebuf);
        try ew.interface.print(
            "get returned {d} bytes but expected {d}; first 64: {s}\n",
            .{ got.len, payload.len, got[0..@min(got.len, 64)] },
        );
        try ew.interface.flush();
        std.process.exit(1);
    }
    try out.print("[+{d:>6}ms] ok  get → {d} bytes byte-identical ({d}ms)\n", .{ elapsedMs(start_ns), got.len, elapsedMsSince(t) });
    try out.flush();

    // ── 5. idempotent put: overwrite with new value ───────────────────
    t = std.time.nanoTimestamp();
    try out.print("[+{d:>6}ms] →  put (overwrite) ...\n", .{elapsedMs(start_ns)});
    try out.flush();
    const payload2 = "overwritten — second put";
    bs.put(key, payload2) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "put(overwrite) failed: {s}", .{@errorName(err)}) catch "put failed";
        fail(msg);
    };
    const got2 = try bs.get(key, allocator);
    defer allocator.free(got2);
    if (!std.mem.eql(u8, got2, payload2)) fail("get after overwrite returned stale payload");
    try out.print("[+{d:>6}ms] ok  put overwrites + get returns new value ({d}ms)\n", .{ elapsedMs(start_ns), elapsedMsSince(t) });
    try out.flush();

    // ── 6. delete + verify gone ───────────────────────────────────────
    t = std.time.nanoTimestamp();
    try out.print("[+{d:>6}ms] →  delete ...\n", .{elapsedMs(start_ns)});
    try out.flush();
    bs.delete(key) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "delete failed: {s}", .{@errorName(err)}) catch "delete failed";
        fail(msg);
    };
    const exists2 = try bs.exists(key);
    if (exists2) fail("exists(after delete) returned true");
    try out.print("[+{d:>6}ms] ok  delete ({d}ms)\n", .{ elapsedMs(start_ns), elapsedMsSince(t) });
    try out.flush();

    // ── 7. delete on missing key is idempotent ────────────────────────
    t = std.time.nanoTimestamp();
    try out.print("[+{d:>6}ms] →  delete (missing) ...\n", .{elapsedMs(start_ns)});
    try out.flush();
    bs.delete(key) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "delete(missing) failed: {s}", .{@errorName(err)}) catch "delete failed";
        fail(msg);
    };
    try out.print("[+{d:>6}ms] ok  delete(missing) idempotent ({d}ms)\n", .{ elapsedMs(start_ns), elapsedMsSince(t) });
    try out.flush();

    // ── 8. multipart upload round-trip (blob-storage-plan §3.5 A) ────
    // create → 2 parts (5 MiB + tail) → complete → get byte-identical
    // → server-side copy to a content-addressed key → delete both →
    // abort path. Also proves the 200-with-<Error>-body detection and
    // the signed x-amz-copy-source against a real endpoint.
    {
        t = std.time.nanoTimestamp();
        try out.print("[+{d:>6}ms] →  multipart create ...\n", .{elapsedMs(start_ns)});
        try out.flush();
        const mp_key = "smoke-multipart-tmp";
        const upload_id = store.createMultipartUpload(mp_key, "application/octet-stream", allocator) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "multipart create failed: {s}", .{@errorName(err)}) catch "create failed";
            fail(msg);
        };
        defer allocator.free(upload_id);
        try out.print("[+{d:>6}ms] ok  create → UploadId {d} chars ({d}ms)\n", .{ elapsedMs(start_ns), upload_id.len, elapsedMsSince(t) });
        try out.flush();

        // Part 1: exactly the 5 MiB minimum, patterned so corruption
        // or reordering shows in the byte-compare. Part 2: small tail
        // (the last part may be any size).
        const part1 = try allocator.alloc(u8, blob.S3BlobStore.MULTIPART_MIN_PART_BYTES);
        defer allocator.free(part1);
        for (part1, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
        const part2 = "tail-part-after-five-mib";

        t = std.time.nanoTimestamp();
        try out.print("[+{d:>6}ms] →  upload part 1 (5 MiB) + part 2 ...\n", .{elapsedMs(start_ns)});
        try out.flush();
        const etag1 = store.uploadPart(mp_key, upload_id, 1, part1, allocator) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "uploadPart 1 failed: {s}", .{@errorName(err)}) catch "part failed";
            fail(msg);
        };
        defer allocator.free(etag1);
        const etag2 = store.uploadPart(mp_key, upload_id, 2, part2, allocator) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "uploadPart 2 failed: {s}", .{@errorName(err)}) catch "part failed";
            fail(msg);
        };
        defer allocator.free(etag2);
        try out.print("[+{d:>6}ms] ok  parts uploaded ({d}ms)\n", .{ elapsedMs(start_ns), elapsedMsSince(t) });
        try out.flush();

        t = std.time.nanoTimestamp();
        try out.print("[+{d:>6}ms] →  complete + verify ...\n", .{elapsedMs(start_ns)});
        try out.flush();
        store.completeMultipartUpload(mp_key, upload_id, &.{ etag1, etag2 }) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "complete failed: {s}", .{@errorName(err)}) catch "complete failed";
            fail(msg);
        };
        const assembled = bs.get(mp_key, allocator) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "get(multipart) failed: {s}", .{@errorName(err)}) catch "get failed";
            fail(msg);
        };
        defer allocator.free(assembled);
        if (assembled.len != part1.len + part2.len) fail("multipart object length mismatch");
        if (!std.mem.eql(u8, assembled[0..part1.len], part1)) fail("multipart part 1 bytes mismatch");
        if (!std.mem.eql(u8, assembled[part1.len..], part2)) fail("multipart part 2 bytes mismatch");
        try out.print("[+{d:>6}ms] ok  complete + get → {d} bytes byte-identical ({d}ms)\n", .{ elapsedMs(start_ns), assembled.len, elapsedMsSince(t) });
        try out.flush();

        t = std.time.nanoTimestamp();
        try out.print("[+{d:>6}ms] →  server-side copy → content-addressed key ...\n", .{elapsedMs(start_ns)});
        try out.flush();
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(assembled, &digest, .{});
        const hash_hex = std.fmt.bytesToHex(digest, .lower);
        const final_key = try std.fmt.allocPrint(allocator, "smoke-multipart-{s}", .{&hash_hex});
        defer allocator.free(final_key);
        store.copyObject(mp_key, final_key) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "copyObject failed: {s}", .{@errorName(err)}) catch "copy failed";
            fail(msg);
        };
        const copied = bs.get(final_key, allocator) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "get(copied) failed: {s}", .{@errorName(err)}) catch "get failed";
            fail(msg);
        };
        defer allocator.free(copied);
        if (!std.mem.eql(u8, copied, assembled)) fail("copied object bytes mismatch");
        bs.delete(mp_key) catch {};
        bs.delete(final_key) catch {};
        try out.print("[+{d:>6}ms] ok  copy + verify + cleanup ({d}ms)\n", .{ elapsedMs(start_ns), elapsedMsSince(t) });
        try out.flush();

        // Abort path: create a fresh upload and abandon it.
        t = std.time.nanoTimestamp();
        try out.print("[+{d:>6}ms] →  abort ...\n", .{elapsedMs(start_ns)});
        try out.flush();
        const abort_id = store.createMultipartUpload(mp_key, null, allocator) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "create(for abort) failed: {s}", .{@errorName(err)}) catch "create failed";
            fail(msg);
        };
        defer allocator.free(abort_id);
        store.abortMultipartUpload(mp_key, abort_id) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "abort failed: {s}", .{@errorName(err)}) catch "abort failed";
            fail(msg);
        };
        try out.print("[+{d:>6}ms] ok  abort ({d}ms)\n", .{ elapsedMs(start_ns), elapsedMsSince(t) });
        try out.flush();
    }

    try out.writeAll("\nPASS s3-blob smoke\n");
    try out.flush();
}
