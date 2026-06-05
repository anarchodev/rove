//! Decisive reproduction probe for the "empty-bundle race" suspected in the
//! Phase-7 slice-(b) smoke (project_v2_zero_downtime_move memory).
//!
//! CONCLUSION (2026-06-05): NOT a kvexp bug. This probe ran 0 hits across
//! 63,000 iterations (probe A single-threaded + probe B with a background
//! thread hammering `durabilize`), so `KvStore.dumpTenantBundle`'s
//! commit→durabilize→snapshot visibility is correct and `openSnapshot` is
//! robust to a concurrent durabilize. The original "16-byte bundle" was below
//! the 21-byte minimum (a truncated transfer, not an empty snapshot); a
//! follow-up HTTP check fetched the bundle 600× (small 33-byte + large 42 KB
//! multi-frame) with zero truncation. The one observed failure was a
//! non-reproducible transient, and a corrupt bundle is caught safely at the
//! destination's `loadTenantBundle` (the move aborts — no data loss). Kept as
//! a regression guard for the bundle path.
//!
//! Does `KvStore.dumpTenantBundle` ever miss a write committed (via an
//! immediate `TrackedTxn`) right before it — at the kvstore/kvexp level, no
//! HTTP/raft/worker threads?
//!
//!   zig build v2-bundle-repro -Doptimize=ReleaseFast
//!   ./zig-out/bin/v2-bundle-repro [iters=3000]
//!
//! Probe A — faithful COLD START: a FRESH manifest each iteration (mirrors a
//!   fresh `rewind` process), attach one sibling store (lazy-created on first
//!   write), immediate TrackedTxn commit, then dumpTenantBundle the same
//!   instant. Assert n_pairs == 1. O(iters).
//! Probe B — CONCURRENCY: one manifest, one store, a background thread
//!   hammering `durabilize(0)`, while the main thread overwrites the key +
//!   dumps in a tight loop. Tests whether a dump can race a concurrent
//!   overlay handoff (openSnapshot vs durabilize).

const std = @import("std");
const kv = @import("raft-kv");
const kvexp = @import("kvexp");

const KvStore = kv.KvStore;
const MAP_SIZE: usize = 256 * 1024 * 1024;

fn bundleNPairs(store: *KvStore, a: std.mem.Allocator) !u64 {
    const bundle = try store.dumpTenantBundle(a);
    defer a.free(bundle);
    var stream = std.io.fixedBufferStream(bundle);
    const hdr = try kvexp.peekTenantBundle(stream.reader());
    return hdr.n_pairs;
}

/// Probe A — fresh manifest per iteration (cold start).
fn probeA(a: std.mem.Allocator, iters: u64) !u64 {
    var hits: u64 = 0;
    var i: u64 = 0;
    while (i < iters) : (i += 1) {
        var pbuf: [80]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&pbuf, "/tmp/v2br-A-{d}-{d}.kv", .{ std.os.linux.getpid(), i });
        std.fs.cwd().deleteFile(path) catch {};
        var manifest: kvexp.Manifest = undefined;
        try manifest.init(a, path, .{ .max_map_size = MAP_SIZE });

        const store = try KvStore.attach(a, &manifest, kv.hashStoreId("movetenant"), null);
        var txn = try store.beginTrackedImmediate();
        try txn.put("k", "v");
        try txn.commit();
        const n = try bundleNPairs(store, a);
        if (n != 1) {
            hits += 1;
            std.debug.print("  A HIT iter={d} n_pairs={d}\n", .{ i, n });
        }
        store.close();
        manifest.deinit();
        std.fs.cwd().deleteFile(path) catch {};
        if (i % 500 == 0) std.debug.print("  A progress {d}/{d} (hits={d})\n", .{ i, iters, hits });
    }
    return hits;
}

const Durabilizer = struct {
    manifest: *kvexp.Manifest,
    stop: std.atomic.Value(bool) = .init(false),
    fn run(self: *Durabilizer) void {
        while (!self.stop.load(.acquire)) self.manifest.durabilize(0) catch {};
    }
};

/// Probe B — one store, concurrent durabilize.
fn probeB(a: std.mem.Allocator, iters: u64) !u64 {
    var pbuf: [80]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&pbuf, "/tmp/v2br-B-{d}.kv", .{std.os.linux.getpid()});
    std.fs.cwd().deleteFile(path) catch {};
    var manifest: kvexp.Manifest = undefined;
    try manifest.init(a, path, .{ .max_map_size = MAP_SIZE });
    defer {
        manifest.deinit();
        std.fs.cwd().deleteFile(path) catch {};
    }
    const store = try KvStore.attach(a, &manifest, kv.hashStoreId("movetenant"), null);
    defer store.close();

    var d = Durabilizer{ .manifest = &manifest };
    const th = try std.Thread.spawn(.{}, Durabilizer.run, .{&d});
    defer {
        d.stop.store(true, .release);
        th.join();
    }

    var hits: u64 = 0;
    var i: u64 = 0;
    while (i < iters) : (i += 1) {
        var vbuf: [24]u8 = undefined;
        const v = try std.fmt.bufPrint(&vbuf, "v{d}", .{i});
        var txn = try store.beginTrackedImmediate();
        try txn.put("k", v);
        try txn.commit();
        const n = try bundleNPairs(store, a);
        if (n != 1) {
            hits += 1;
            std.debug.print("  B HIT iter={d} n_pairs={d}\n", .{ i, n });
        }
        if (i % 5000 == 0) std.debug.print("  B progress {d}/{d} (hits={d})\n", .{ i, iters, hits });
    }
    return hits;
}

pub fn main() !void {
    const a = std.heap.c_allocator;
    var args = std.process.args();
    _ = args.next();
    const iters: u64 = if (args.next()) |s| try std.fmt.parseInt(u64, s, 10) else 3000;

    std.debug.print("probe A (fresh manifest per iter, {d} iters)...\n", .{iters});
    const a_hits = try probeA(a, iters);
    std.debug.print("  A: {d} empty-bundle hits / {d}\n", .{ a_hits, iters });

    const b_iters = iters * 20;
    std.debug.print("probe B (concurrent durabilize, {d} iters)...\n", .{b_iters});
    const b_hits = try probeB(a, b_iters);
    std.debug.print("  B: {d} empty-bundle hits / {d}\n", .{ b_hits, b_iters });

    if (a_hits == 0 and b_hits == 0) {
        std.debug.print("\nNO REPRO single-process — the race is NOT at the kvstore/kvexp level.\n", .{});
    } else {
        std.debug.print("\nREPRO at kvstore/kvexp level (A={d} B={d}) — fix belongs in kvexp.\n", .{ a_hits, b_hits });
    }
}
