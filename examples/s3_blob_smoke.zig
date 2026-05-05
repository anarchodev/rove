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
    const exists0 = bs.exists(key) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "exists(missing) failed: {s}", .{@errorName(err)}) catch "exists failed";
        fail(msg);
    };
    if (exists0) fail("exists(missing) returned true — key collision?");
    try out.writeAll("ok  exists(missing) → false\n");
    try out.flush();

    // ── 2. put a known payload ────────────────────────────────────────
    const payload = "hello from rove-blob s3 smoke\nbinary too: \x00\x01\x02\xff";
    bs.put(key, payload) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "put failed: {s}", .{@errorName(err)}) catch "put failed";
        fail(msg);
    };
    try out.writeAll("ok  put\n");
    try out.flush();

    // ── 3. exists after put → true ────────────────────────────────────
    const exists1 = bs.exists(key) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "exists(after put) failed: {s}", .{@errorName(err)}) catch "exists failed";
        fail(msg);
    };
    if (!exists1) fail("exists(after put) returned false");
    try out.writeAll("ok  exists(after put) → true\n");
    try out.flush();

    // ── 4. get → byte-identical ───────────────────────────────────────
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
    try out.print("ok  get → {d} bytes byte-identical\n", .{got.len});
    try out.flush();

    // ── 5. idempotent put: overwrite with new value ───────────────────
    const payload2 = "overwritten — second put";
    bs.put(key, payload2) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "put(overwrite) failed: {s}", .{@errorName(err)}) catch "put failed";
        fail(msg);
    };
    const got2 = try bs.get(key, allocator);
    defer allocator.free(got2);
    if (!std.mem.eql(u8, got2, payload2)) fail("get after overwrite returned stale payload");
    try out.writeAll("ok  put overwrites + get returns new value\n");
    try out.flush();

    // ── 6. delete + verify gone ───────────────────────────────────────
    bs.delete(key) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "delete failed: {s}", .{@errorName(err)}) catch "delete failed";
        fail(msg);
    };
    const exists2 = try bs.exists(key);
    if (exists2) fail("exists(after delete) returned true");
    try out.writeAll("ok  delete\n");
    try out.flush();

    // ── 7. delete on missing key is idempotent ────────────────────────
    bs.delete(key) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "delete(missing) failed: {s}", .{@errorName(err)}) catch "delete failed";
        fail(msg);
    };
    try out.writeAll("ok  delete(missing) idempotent\n");
    try out.flush();

    try out.writeAll("\nPASS s3-blob smoke\n");
    try out.flush();
}
