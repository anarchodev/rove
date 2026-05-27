//! `s3-throughput-bench` — measure how many concurrent PUT-ers it
//! takes to saturate the S3 link, isolated from the rest of the
//! stack. Sweep concurrency × object-size to find the knee where
//! more threads stop buying bandwidth and start buying queueing.
//!
//! Each thread loops: acquire Easy from EasyPool → PUT a payload of
//! the configured size → release → repeat. After all threads finish,
//! reports aggregate MB/s + per-PUT p50/p90/p99/p99.9/max.
//!
//! Configuration (same env vars as `s3-blob-smoke`):
//!   S3_ENDPOINT           hostname only, no scheme
//!   S3_REGION             SigV4 signing region
//!   S3_BUCKET             bucket name
//!   S3_KEY_PREFIX         optional prefix prepended to every key
//!   AWS_ACCESS_KEY_ID
//!   AWS_SECRET_ACCESS_KEY
//!
//! Bench knobs (positional args):
//!   $1 concurrency        threads, default 16
//!   $2 size_bytes         payload bytes per PUT (accepts K/M suffix),
//!                         default 65536
//!   $3 puts_per_thread    PUTs each thread issues, default 50
//!
//! Bench knobs (env vars):
//!   ROVE_S3_POOL_SIZE     EasyPool depth — MUST be >= concurrency or
//!                         threads will serialize on pool acquire.
//!                         Bench warns and exits non-zero if too small.
//!   PREFIX_MODE           "per-thread" (default) or "shared". OVH /
//!                         S3 generally shard rate limits by key
//!                         prefix; per-thread prefixes spread load,
//!                         shared concentrates it on one prefix
//!                         partition.
//!   TRACE                 "1" to print one line per PUT
//!                         (`TRACE t{tid} i{i} lat_ms=NNN`) so you
//!                         can see warm-up curves. Useful at K=1 to
//!                         check whether TLS handshake amortizes
//!                         across sequential PUTs (libcurl connection
//!                         reuse): if PUT 1 is ~3-10× slower than
//!                         PUT 2+, keep-alive is working; if every
//!                         PUT is the same, we pay per-request TLS.
//!
//! Example sweep (run from a shell loop):
//!
//!   export S3_ENDPOINT=s3.gra.io.cloud.ovh.net S3_REGION=gra \
//!          S3_BUCKET=loop46-bench AWS_ACCESS_KEY_ID=... \
//!          AWS_SECRET_ACCESS_KEY=...
//!   for K in 1 2 4 8 16 32 64 128; do
//!     for S in 16K 64K 256K 1M 4M 16M; do
//!       ROVE_S3_POOL_SIZE=$K ./zig-out/bin/s3-throughput-bench $K $S 50
//!     done
//!   done
//!
//! Objects are NOT deleted after the bench — keys carry a run-id and
//! the expectation is that the bucket has a lifecycle rule that
//! expires `bench/*` after a day. The deletes would themselves
//! consume request budget and pollute the timing.

const std = @import("std");
const blob = @import("rove-blob");

pub const std_options: std.Options = .{ .log_level = .warn };

const ENV_ENDPOINT = "S3_ENDPOINT";
const ENV_REGION = "S3_REGION";
const ENV_BUCKET = "S3_BUCKET";
const ENV_KEY_PREFIX = "S3_KEY_PREFIX";
const ENV_AK = "AWS_ACCESS_KEY_ID";
const ENV_SK = "AWS_SECRET_ACCESS_KEY";
const ENV_POOL_SIZE = "ROVE_S3_POOL_SIZE";
const ENV_PREFIX_MODE = "PREFIX_MODE";
const ENV_TRACE = "TRACE";

const ThreadCtx = struct {
    // Per-thread S3BlobStore. The store wraps the *process-wide*
    // EasyPool (defaultPool), so K stores ≠ K pools — they all share
    // the same handle pool. The reason for one-store-per-thread is
    // BlobStore.put rejects `/` in keys (validateKey defends against
    // path traversal); slashes are only permitted in the per-store
    // `key_prefix` config. So each thread's prefix hierarchy lives
    // in its own store's prefix, and the actual key passed to put()
    // is a flat decimal index.
    store: *blob.S3BlobStore,
    thread_id: u32,
    puts: u32,
    payload: []const u8,
    // Latencies in ns, slot per PUT. UINT64_MAX sentinel for errors so
    // the percentile sort can drop them.
    latencies_ns: []u64,
    errors: *std.atomic.Value(u64),
    trace: bool,
};

fn workerFn(ctx: *ThreadCtx) void {
    var key_buf: [32]u8 = undefined;
    for (0..ctx.puts) |i| {
        const key = std.fmt.bufPrint(&key_buf, "{d}", .{i}) catch unreachable;
        const t0 = std.time.nanoTimestamp();
        ctx.store.blobStore().put(key, ctx.payload) catch {
            _ = ctx.errors.fetchAdd(1, .monotonic);
            ctx.latencies_ns[i] = std.math.maxInt(u64);
            continue;
        };
        const t1 = std.time.nanoTimestamp();
        const dt = if (t1 > t0) @as(u64, @intCast(t1 - t0)) else 0;
        ctx.latencies_ns[i] = dt;
        if (ctx.trace) {
            // Single line per PUT — stderr to avoid interleaving with
            // the RESULT line on stdout. Sequential per thread by
            // construction; tools can sort by t/i if multi-thread.
            std.debug.print("TRACE t{d} i{d} lat_ms={d}\n", .{
                ctx.thread_id, i, dt / std.time.ns_per_ms,
            });
        }
    }
}

fn getenvRequired(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.debug.print("missing required env: {s}\n", .{name});
            std.process.exit(1);
        },
        else => return err,
    };
}

fn getenvOpt(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => err,
    };
}

/// Parse "65536", "64K", "1M", "16M". Case-insensitive suffix.
fn parseSize(s: []const u8) !usize {
    if (s.len == 0) return error.InvalidSize;
    var end = s.len;
    var mult: usize = 1;
    const last = std.ascii.toLower(s[s.len - 1]);
    switch (last) {
        'k' => {
            mult = 1024;
            end -= 1;
        },
        'm' => {
            mult = 1024 * 1024;
            end -= 1;
        },
        'g' => {
            mult = 1024 * 1024 * 1024;
            end -= 1;
        },
        else => {},
    }
    const n = try std.fmt.parseInt(usize, s[0..end], 10);
    return n * mult;
}

fn percentile(sorted: []const u64, p: f64) u64 {
    if (sorted.len == 0) return 0;
    const idx_f: f64 = @floatFromInt(sorted.len - 1);
    const idx: usize = @intFromFloat(idx_f * p);
    return sorted[idx];
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ── parse args ────────────────────────────────────────────────────
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const concurrency: u32 = if (args.len > 1) try std.fmt.parseInt(u32, args[1], 10) else 16;
    const size_bytes: usize = if (args.len > 2) try parseSize(args[2]) else 64 * 1024;
    const puts_per_thread: u32 = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 50;
    if (concurrency == 0 or puts_per_thread == 0 or size_bytes == 0) {
        std.debug.print("concurrency, size_bytes, puts_per_thread must all be > 0\n", .{});
        std.process.exit(1);
    }

    // ── env ───────────────────────────────────────────────────────────
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

    const base_prefix_owned = try getenvOpt(allocator, ENV_KEY_PREFIX);
    defer if (base_prefix_owned) |p| allocator.free(p);
    const base_prefix: []const u8 = base_prefix_owned orelse "";

    const prefix_mode_owned = try getenvOpt(allocator, ENV_PREFIX_MODE);
    defer if (prefix_mode_owned) |p| allocator.free(p);
    const shared_prefix = if (prefix_mode_owned) |m| std.mem.eql(u8, m, "shared") else false;

    const trace_owned = try getenvOpt(allocator, ENV_TRACE);
    defer if (trace_owned) |p| allocator.free(p);
    const trace = if (trace_owned) |m| std.mem.eql(u8, m, "1") else false;

    // Pool-size sanity: EasyPool.acquire blocks when exhausted, so a
    // concurrency that exceeds pool size silently caps. Bench refuses
    // to lie about its result.
    const pool_env = try getenvOpt(allocator, ENV_POOL_SIZE);
    defer if (pool_env) |p| allocator.free(p);
    const pool_size: u32 = if (pool_env) |p| try std.fmt.parseInt(u32, std.mem.trim(u8, p, &std.ascii.whitespace), 10) else 64;
    if (concurrency > pool_size) {
        std.debug.print(
            "concurrency={d} > pool_size={d} — set ROVE_S3_POOL_SIZE={d} or bench will serialize\n",
            .{ concurrency, pool_size, concurrency },
        );
        std.process.exit(1);
    }

    // ── per-thread stores ─────────────────────────────────────────────
    // Each thread owns its own S3BlobStore so its prefix-hierarchy
    // can sit in `key_prefix`. The handles all share the process-wide
    // EasyPool. Prefix shapes:
    //   per-thread mode: bench/{run}/t{tid}/  → each thread on its own
    //                    OVH partition prefix
    //   shared mode:     bench/{run}/shared/  → every thread under one
    //                    partition prefix (exposes prefix-level
    //                    serialization; the 409 OperationAborted class
    //                    of bug we hit before)
    const run_id: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const stores = try allocator.alloc(blob.S3BlobStore, concurrency);
    defer {
        for (stores) |*s| s.deinit();
        allocator.free(stores);
    }
    for (0..concurrency) |i| {
        var prefix_buf: [256]u8 = undefined;
        const prefix = if (shared_prefix)
            try std.fmt.bufPrint(&prefix_buf, "{s}bench/{x}/shared/t{d}-", .{ base_prefix, run_id, i })
        else
            try std.fmt.bufPrint(&prefix_buf, "{s}bench/{x}/t{d}/", .{ base_prefix, run_id, i });
        stores[i] = blob.S3BlobStore.init(allocator, .{
            .endpoint = endpoint,
            .region = region,
            .bucket = bucket,
            .key_prefix = prefix,
            .access_key = ak,
            .secret_key = sk,
        }) catch |err| {
            std.debug.print("S3BlobStore.init[{d}] failed: {s}\n", .{ i, @errorName(err) });
            std.process.exit(1);
        };
    }

    // ── payload ───────────────────────────────────────────────────────
    // Pseudo-random bytes so any compression on the wire doesn't lie
    // about the link's actual throughput.
    const payload = try allocator.alloc(u8, size_bytes);
    defer allocator.free(payload);
    {
        var rng = std.Random.DefaultPrng.init(0xdeadbeef);
        rng.random().bytes(payload);
    }

    // ── per-thread state ──────────────────────────────────────────────
    const total_puts: usize = @as(usize, concurrency) * @as(usize, puts_per_thread);
    const all_latencies = try allocator.alloc(u64, total_puts);
    defer allocator.free(all_latencies);
    @memset(all_latencies, 0);

    var errors: std.atomic.Value(u64) = .init(0);
    const ctxs = try allocator.alloc(ThreadCtx, concurrency);
    defer allocator.free(ctxs);
    const threads = try allocator.alloc(std.Thread, concurrency);
    defer allocator.free(threads);

    for (0..concurrency) |i| {
        const lo = i * puts_per_thread;
        const hi = lo + puts_per_thread;
        ctxs[i] = .{
            .store = &stores[i],
            .thread_id = @intCast(i),
            .puts = puts_per_thread,
            .payload = payload,
            .latencies_ns = all_latencies[lo..hi],
            .errors = &errors,
            .trace = trace,
        };
    }

    // ── header ────────────────────────────────────────────────────────
    std.debug.print(
        "s3-throughput-bench: endpoint={s} bucket={s} concurrency={d} size={d} puts/thread={d} prefix_mode={s} run_id={x}\n",
        .{ endpoint, bucket, concurrency, size_bytes, puts_per_thread, if (shared_prefix) "shared" else "per-thread", run_id },
    );

    // ── go ────────────────────────────────────────────────────────────
    const wall_start = std.time.nanoTimestamp();
    for (0..concurrency) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerFn, .{&ctxs[i]});
    }
    for (threads) |t| t.join();
    const wall_end = std.time.nanoTimestamp();

    // ── stats ─────────────────────────────────────────────────────────
    const errs = errors.load(.monotonic);
    const ok_count = total_puts - errs;
    const wall_ns: u64 = @intCast(wall_end - wall_start);
    const wall_secs: f64 = @as(f64, @floatFromInt(wall_ns)) / 1e9;
    const bytes_ok: u64 = @as(u64, @intCast(ok_count)) * @as(u64, @intCast(size_bytes));
    const mb_per_s = @as(f64, @floatFromInt(bytes_ok)) / wall_secs / 1e6;
    const rps = @as(f64, @floatFromInt(ok_count)) / wall_secs;

    // Filter errors (sentinel) before sorting for percentiles.
    var ok_lat = try allocator.alloc(u64, ok_count);
    defer allocator.free(ok_lat);
    var w: usize = 0;
    for (all_latencies) |l| {
        if (l != std.math.maxInt(u64)) {
            ok_lat[w] = l;
            w += 1;
        }
    }
    std.mem.sort(u64, ok_lat, {}, comptime std.sort.asc(u64));

    const p50 = percentile(ok_lat, 0.50);
    const p90 = percentile(ok_lat, 0.90);
    const p99 = percentile(ok_lat, 0.99);
    const p999 = percentile(ok_lat, 0.999);
    const max_lat = if (ok_lat.len > 0) ok_lat[ok_lat.len - 1] else 0;

    std.debug.print(
        "RESULT  K={d:>3}  size={d:>9}  puts={d:>5}  ok={d:>5}  err={d}  wall={d:.3}s  rps={d:>7.1}  MB/s={d:>7.2}  p50={d:>5}ms  p90={d:>5}ms  p99={d:>5}ms  p99.9={d:>5}ms  max={d:>5}ms\n",
        .{
            concurrency,
            size_bytes,
            puts_per_thread,
            ok_count,
            errs,
            wall_secs,
            rps,
            mb_per_s,
            p50 / std.time.ns_per_ms,
            p90 / std.time.ns_per_ms,
            p99 / std.time.ns_per_ms,
            p999 / std.time.ns_per_ms,
            max_lat / std.time.ns_per_ms,
        },
    );

    if (errs > 0) std.process.exit(2);
}
