//! `owed-recovery-scan-bench` — Option (b) increment 3(b) measurement
//! (docs/http-send-plan.md §15; task #8). The USER-DEFERRED question:
//! how expensive is reconstructing the in-flight/recovery set at
//! restart by scanning `_send/owed/` across all tenants — i.e. which
//! recovery strategy wins:
//!
//!   (a) lazy recover-on-tenant-open   — per-tenant `_send/owed/`
//!       prefix scan at first app.db touch (cost = cold-first-touch
//!       latency, concurrent with traffic).
//!   (b) one-time boot-scan-to-seed    — scan every tenant once at
//!       boot, single-threaded, before workers start.
//!   (c) snapshot-the-set              — zero scan; the set is its
//!       own snapshot component.
//!
//! WHY THIS HARNESS IS FAITHFUL (the `project_kv_read_txn_per_op`
//! lesson — never conclude from the wrong workload):
//!
//!  - It drives the REAL recovery path: `KvStore.attach` +
//!    `KvStore.prefix("_send/owed/")` against a shared
//!    `kvexp.Manifest`, exactly what a reconstruction pass calls. Not
//!    a synthetic LMDB cursor loop.
//!  - It REOPENS the manifest from disk between populate and scan, so
//!    `Manifest.init`'s "openDbi every durably-registered tenant from
//!    _stores" loop (manifest.zig:521-540) — the O(N_tenants) boot
//!    cost we ALREADY pay today, independent of Option (b) — is
//!    included and reported SEPARATELY as the baseline. The decision
//!    metric is scan_total : init_baseline, not scan_total alone.
//!  - `KvStore.prefix` with no active txn goes through
//!    `manifest.acquire` (the DBI resolution that touches the global
//!    `Manifest.dbis_lock` — the convoy that is invisible in cycles
//!    profiles and only matters under concurrency). Boot-scan (b) is
//!    single-threaded → NO convoy by construction. The only convoy-
//!    relevant delta is (a)'s ONE extra acquire per tenant *lifetime*
//!    at first touch, concurrent with traffic — and the steady-state
//!    baseline already does an acquire PER REQUEST, so a once-per-
//!    tenant extra is dominated. A concurrent lock profile is only
//!    worth running if (a) and (b) land close here.
//!
//!  - Two owed distributions, because the realistic and pessimal
//!    costs differ structurally:
//!      realistic — almost every tenant has ZERO in-flight owed
//!        (steady state: sends resolve in well under a second; at any
//!        crash instant the owed-without-proof count is tiny). But
//!        recovery STILL must seek `_send/owed/` in every tenant and
//!        find nothing — the dominant cost is N empty prefix-seeks,
//!        not the rare matches.
//!      pessimal  — every tenant has an owed-without-proof plus an
//!        owed-with-proof (the proof must be skipped) — the upper
//!        bound.
//!
//! Microbench, in-language, per reference_bench_harness_direction.
//! Run: `zig build owed-recovery-scan-bench` (ReleaseFast — see
//! reference_benchmarking; a debug build's numbers are meaningless).

const std = @import("std");
const kv = @import("rove-kv");
const kvexp = @import("kvexp");

const KvStore = kv.KvStore;
const hashStoreId = kv.hashStoreId;

const OWED_PREFIX = "_send/owed/";
const PROOF_PREFIX = "_send/proof/";

/// ~ a real `send_outbox.OwedSend` encoding (url+method+headers+body+
/// context+on_result+3 ints). The scan cost is dominated by key
/// count / B-tree depth / seek, not value size, but use a realistic
/// value so we don't measure a tiny-value best case.
const OWED_VAL_LEN = 384;
/// `_send/proof/` is small (ok/status/body/err — typically tiny).
const PROOF_VAL_LEN = 48;
/// Realistic app.db is not empty: give the B-tree real depth so the
/// `_send/owed/` MDB_SET_RANGE seek isn't an empty-tree best case.
const APP_KEYS_PER_TENANT = 256;
const APP_VAL_LEN = 64;

const Mode = enum { realistic, pessimal };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var out_buf: [4096]u8 = undefined;
    var out_w = std.fs.File.stdout().writer(&out_buf);
    const w = &out_w.interface;

    const n_list = [_]u32{ 100, 1000, 5000 };

    try w.print(
        "owed-recovery-scan-bench — Option (b) 3(b)\n" ++
            "  app_keys/tenant={d} owed_val={d}B  (init_baseline = the openDbi-all-\n" ++
            "  tenants boot cost we ALREADY pay, manifest.zig:521)\n\n",
        .{ APP_KEYS_PER_TENANT, OWED_VAL_LEN },
    );
    try w.print(
        "{s:>6} {s:>10} {s:>11} {s:>13} {s:>12} {s:>11} {s:>9} {s:>10}\n",
        .{ "N", "mode", "init_ms", "scan_tot_ms", "per_tnt_us", "tnt/s", "owed", "scan:init" },
    );
    try w.print("{s}\n", .{"-" ** 90});
    try out_w.interface.flush();

    for (n_list) |n| {
        for ([_]Mode{ .realistic, .pessimal }) |mode| {
            try runOne(a, w, &out_w, n, mode);
        }
    }

    try w.print(
        "\nnote: boot-scan (b) is single-threaded → no dbis_lock convoy by\n" ++
            "construction. (a) lazy-on-open adds ONE acquire per tenant lifetime\n" ++
            "at first touch (vs the per-REQUEST acquire already in steady state).\n" ++
            "Decision metric is scan:init — if boot-scan ≪ the init we already\n" ++
            "pay, (b) is effectively free relative to boot.\n",
        .{},
    );
    try out_w.interface.flush();
}

fn runOne(
    a: std.mem.Allocator,
    w: *std.Io.Writer,
    out_w: anytype,
    n: u32,
    mode: Mode,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/cluster.kv", .{dir_path}, 0);
    defer a.free(path);

    // ── populate ──────────────────────────────────────────────────
    var manifest: kvexp.Manifest = undefined;
    try manifest.init(a, path, .{});

    var val_buf: [OWED_VAL_LEN]u8 = undefined;
    @memset(&val_buf, 'x');
    var key_buf: [64]u8 = undefined;

    var t: u32 = 0;
    while (t < n) : (t += 1) {
        const sid = try std.fmt.bufPrint(&key_buf, "tenant-{d}", .{t});
        const store = try KvStore.attach(a, &manifest, hashStoreId(sid), null);
        defer store.close();

        var j: u32 = 0;
        while (j < APP_KEYS_PER_TENANT) : (j += 1) {
            var kb: [32]u8 = undefined;
            const k = try std.fmt.bufPrint(&kb, "app/{d:0>6}", .{j});
            try store.put(k, val_buf[0..APP_VAL_LEN]);
        }

        // owed distribution. realistic: 5% of tenants carry 2 owed-
        // without-proof; the other 95% carry none (the dominant
        // empty-seek case). pessimal: every tenant carries 1 owed-
        // without-proof AND 1 owed-WITH-proof (proof must be skipped).
        const owed_here: u32 = switch (mode) {
            .realistic => if (t % 20 == 0) 2 else 0,
            .pessimal => 1,
        };
        var o: u32 = 0;
        while (o < owed_here) : (o += 1) {
            var ob: [48]u8 = undefined;
            const ok = try std.fmt.bufPrint(&ob, OWED_PREFIX ++ "{d:0>6}", .{o});
            try store.put(ok, val_buf[0..OWED_VAL_LEN]);
        }
        if (mode == .pessimal) {
            // one resolved send: owed + proof both present → recovery
            // must read the owed, then find the proof, then skip it.
            var ob: [48]u8 = undefined;
            const ok = try std.fmt.bufPrint(&ob, OWED_PREFIX ++ "resolved", .{});
            try store.put(ok, val_buf[0..OWED_VAL_LEN]);
            var pb: [48]u8 = undefined;
            const pk = try std.fmt.bufPrint(&pb, PROOF_PREFIX ++ "resolved", .{});
            try store.put(pk, val_buf[0..PROOF_VAL_LEN]);
        }
    }
    try manifest.durabilize(0);
    manifest.deinit();

    // ── reopen: the REAL boot path (openDbi every tenant from
    //    _stores). This is the O(N) cost paid today regardless of
    //    Option (b) — the baseline the scan is judged against. ──────
    var init_timer = try std.time.Timer.start();
    try manifest.init(a, path, .{});
    const init_ns = init_timer.read();
    defer manifest.deinit();

    // ── boot-scan: reconstruct the set exactly as recovery would ──
    var owed_unproven: u64 = 0;
    var scan_timer = try std.time.Timer.start();
    t = 0;
    while (t < n) : (t += 1) {
        const sid = try std.fmt.bufPrint(&key_buf, "tenant-{d}", .{t});
        const store = try KvStore.attach(a, &manifest, hashStoreId(sid), null);
        defer store.close();

        var rr = try store.prefix(OWED_PREFIX, "", 10_000);
        defer rr.deinit();
        for (rr.entries) |e| {
            // recovery decision: owed is live iff no matching proof.
            const id = e.key[OWED_PREFIX.len..];
            var pkb: [64]u8 = undefined;
            const pk = try std.fmt.bufPrint(&pkb, PROOF_PREFIX ++ "{s}", .{id});
            const proven = blk: {
                const g = store.get(pk) catch break :blk false;
                a.free(g);
                break :blk true;
            };
            if (!proven) owed_unproven += 1;
        }
    }
    const scan_ns = scan_timer.read();

    // ── single cold-tenant marginal: (a) lazy-on-open's added
    //    first-touch latency for a tenant whose store handle is
    //    fresh this measurement. ─────────────────────────────────
    const cold_sid = try std.fmt.bufPrint(&key_buf, "tenant-{d}", .{n / 2});
    const cold_store = try KvStore.attach(a, &manifest, hashStoreId(cold_sid), null);
    defer cold_store.close();
    var cold_timer = try std.time.Timer.start();
    var cold_rr = try cold_store.prefix(OWED_PREFIX, "", 10_000);
    const cold_ns = cold_timer.read();
    cold_rr.deinit();

    const init_ms = @as(f64, @floatFromInt(init_ns)) / 1e6;
    const scan_ms = @as(f64, @floatFromInt(scan_ns)) / 1e6;
    const per_tnt_us = (@as(f64, @floatFromInt(scan_ns)) / @as(f64, @floatFromInt(n))) / 1e3;
    const tnt_per_s = @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(scan_ns)) / 1e9);
    const ratio = if (init_ns == 0) 0 else scan_ms / init_ms;

    try w.print(
        "{d:>6} {s:>10} {d:>10.2} {d:>13.2} {d:>12.2} {d:>11.0} {d:>9} {d:>9.2}x  (cold1={d:.1}us)\n",
        .{ n, @tagName(mode), init_ms, scan_ms, per_tnt_us, tnt_per_s, owed_unproven, ratio, @as(f64, @floatFromInt(cold_ns)) / 1e3 },
    );
    try out_w.interface.flush();
}
