// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Surface tests — behavioral coverage of the whole global public API.
//!
//! Where the doc-examples lint (`doc_examples.zig`) proves the DOCS
//! run, this suite proves the SURFACE behaves: one JS test module per
//! baked shim (`surface_tests/<name>.surface.mjs`, plus `request` for
//! the per-activation Zig-built surface) exercises every public
//! method with real assertions through the real dispatcher — fresh
//! temp KV per module, `_config/*` rows seeded Zig-side exactly as a
//! deploy lands them, no cluster, no S3, no network.
//!
//! The teeth are the two-way inventory gate:
//!   - `_reflect.mjs` enumerates the LIVE surface from inside an
//!     activation (canonical name grammar documented there);
//!   - every test module reports `{covers, failures}` (terminal body,
//!     or threaded through `next({ctx})` when the module ends held);
//!   - a reflected name no test covers FAILS THE BUILD (unless it has
//!     a justified entry in `ALLOWED_UNCOVERED`), and a claimed name
//!     the reflector no longer sees FAILS THE BUILD (stale claim after
//!     a rename/retirement).
//! Adding a shim to `globals.GLOBALS_FILES` without a test module (or
//! a `_reflect.mjs` root entry) is a build failure too — the suite's
//! completeness is checked against the same list the runtime bakes.

const std = @import("std");
const qjs = @import("rove-qjs");
const kv_mod = @import("raft-kv");
const h2 = @import("rove-h2");

const dispatcher_mod = @import("dispatcher.zig");
const globals = @import("globals.zig");
const request_mod = @import("request.zig");

const testing = std.testing;

const PRELUDE = @embedFile("surface_tests/_prelude.js");
const REFLECT_SRC = @embedFile("surface_tests/_reflect.mjs");

const SurfaceTest = struct { name: []const u8, src: []const u8 };

/// One test module per GLOBALS_FILES shim + the per-activation
/// surfaces. Completeness against GLOBALS_FILES is asserted below.
const SURFACE_TESTS = [_]SurfaceTest{
    .{ .name = "kv", .src = @embedFile("surface_tests/kv.surface.mjs") },
    .{ .name = "console", .src = @embedFile("surface_tests/console.surface.mjs") },
    .{ .name = "crypto", .src = @embedFile("surface_tests/crypto.surface.mjs") },
    .{ .name = "http", .src = @embedFile("surface_tests/http.surface.mjs") },
    .{ .name = "platform", .src = @embedFile("surface_tests/platform.surface.mjs") },
    .{ .name = "base64", .src = @embedFile("surface_tests/base64.surface.mjs") },
    .{ .name = "urlsearchparams", .src = @embedFile("surface_tests/urlsearchparams.surface.mjs") },
    .{ .name = "time", .src = @embedFile("surface_tests/time.surface.mjs") },
    .{ .name = "after", .src = @embedFile("surface_tests/after.surface.mjs") },
    .{ .name = "stream", .src = @embedFile("surface_tests/stream.surface.mjs") },
    .{ .name = "next", .src = @embedFile("surface_tests/next.surface.mjs") },
    .{ .name = "webhook", .src = @embedFile("surface_tests/webhook.surface.mjs") },
    .{ .name = "textcodec", .src = @embedFile("surface_tests/textcodec.surface.mjs") },
    .{ .name = "blob", .src = @embedFile("surface_tests/blob.surface.mjs") },
    .{ .name = "request", .src = @embedFile("surface_tests/request.surface.mjs") },
};

/// Non-shim surfaces that legitimately have a test module.
const EXTRA_SURFACES = [_][]const u8{"request"};

/// Reflected names no in-process test can meaningfully cover, each
/// with the reason. An entry here is a standing admission — keep it
/// short, and prefer covering the fail-loud error contract instead.
const AllowedUncovered = struct { name: []const u8, why: []const u8 };
const ALLOWED_UNCOVERED = [_]AllowedUncovered{};

/// Config rows a deploy would land — seeded through KvStore.put, the
/// same below-the-reserved-check path the release pipeline uses. Test
/// modules exercise the kv-backed `fromConfig("default")` shape
/// against these; inline-config shapes need no seeding.
const SeedRow = struct { key: []const u8, value: []const u8 };
const SEED_ROWS = [_]SeedRow{
    .{ .key = "_config/oauth/default", .value = 
    \\{"authorization_url":"https://idp.example/authorize","token_url":"https://idp.example/token","client_id":"cid","client_secret":"sec","redirect_uri":"https://app.example/cb","on_complete_module":"onLogin","scopes":["openid"]}
    },
    .{ .key = "_config/sessions/default", .value = 
    \\{"state_path":"sess"}
    },
    .{ .key = "_config/activitypub", .value = 
    \\{"domain":"ap.example","username":"svc","verified_module":"onVerified"}
    },
    .{ .key = "_config/oidc/default", .value = 
    \\{"clients":[]}
    },
    .{ .key = "_oidc/rp/default", .value = 
    \\{"issuer":"https://idp.example","client_id":"cid","redirect_uri":"https://app.example/cb"}
    },
};

// ── Harness plumbing ────────────────────────────────────────────────

fn openTempKv(allocator: std.mem.Allocator, buf: *[64]u8) !*kv_mod.KvStore {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const path = try std.fmt.bufPrintZ(buf, "/tmp/rove-surface-{x}.db", .{seed});
    return try kv_mod.KvStore.open(allocator, path);
}

fn makeReqHeaders(buf: []h2.HeaderField, pairs: []const [2][]const u8) h2.ReqHeaders {
    std.debug.assert(buf.len >= pairs.len);
    for (pairs, 0..) |p, i| {
        buf[i] = .{
            .name = p[0].ptr,
            .name_len = @intCast(p[0].len),
            .value = p[1].ptr,
            .value_len = @intCast(p[1].len),
        };
    }
    return .{ .fields = buf.ptr, .count = @intCast(pairs.len) };
}

/// The standard request every test module runs against — rich enough
/// that the `request` surface has real values to assert on.
const STD_BODY = "{\"n\":42,\"s\":\"str\"}";
const STD_HEADER_PAIRS = [_][2][]const u8{
    .{ ":method", "POST" },
    .{ ":path", "/surface?alpha=1&beta=two" },
    .{ "content-type", "application/json" },
    .{ "cookie", "sid=abc; theme=dark" },
    .{ "x-surface", "yes" },
    .{ "user-agent", "surface/1" },
};

const Report = struct {
    covers: [][]const u8 = &.{},
    failures: [][]const u8 = &.{},
};

/// Synthetic blob backend config: presign (`blob.url`) is PURE
/// computation given a config + instance id (no network — SigV4 over
/// these strings), so supplying one turns blob.url from an
/// error-contract pin into real behavioral coverage. Values are
/// obviously fake; the tests assert URL structure + signing params.
const blob_mod = @import("rove-blob");
const TEST_BLOB_CFG: blob_mod.BackendConfig = .{
    .endpoint = "s3.test.example",
    .region = "test-1",
    .bucket = "surface-bucket",
    .key_prefix_base = "sfx/",
    .access_key = "SURFACEKEY",
    .secret_key = "surface-secret",
    .use_tls = true,
};

/// Compile and dispatch one surface module; returns the parsed report.
/// A module may end terminally (report = returned body) or held
/// (report = the `next({ctx})` ctx). Anything else is a failure.
fn runSurfaceModule(
    a: std.mem.Allocator,
    d: *dispatcher_mod.Dispatcher,
    cctx: *qjs.Context,
    kv: *kv_mod.KvStore,
    name: []const u8,
    src: []const u8,
) !Report {
    const mod_src = try std.fmt.allocPrint(a, "{s}\n{s}", .{ PRELUDE, src });
    var name_buf: [96]u8 = undefined;
    const file_name = try std.fmt.bufPrintZ(&name_buf, "{s}.surface.mjs", .{name});

    const bytecode = cctx.compileToBytecode(mod_src, file_name, a, .{ .kind = .module }) catch {
        const msg = cctx.takeExceptionMessage(a) catch null;
        std.debug.print(
            "\nsurface-tests [{s}]: does not compile: {s}\n",
            .{ name, msg orelse "(no message)" },
        );
        return error.SurfaceModuleCompileFailed;
    };

    var txn = try kv.beginTrackedImmediate();
    var txn_done = false;
    defer if (!txn_done) txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);

    var hdr_buf: [STD_HEADER_PAIRS.len]h2.HeaderField = undefined;
    const hdrs = makeReqHeaders(&hdr_buf, &STD_HEADER_PAIRS);

    const request: request_mod.Request = .{
        .method = "POST",
        .path = "/surface",
        .host = "surface.test",
        .query = "alpha=1&beta=two",
        .body = STD_BODY,
        .headers = hdrs,
        .trace = .{ .request_id = 1 },
        .plan = .{ .storage = .{ .id = "surface", .incarnation = .legacy }, .blob_cfg = &TEST_BLOB_CFG },
    };

    var outcome = d.runOutcome(kv, &txn, &ws, bytecode, null, null, null, null, request, &budget) catch |err| {
        std.debug.print("\nsurface-tests [{s}]: dispatch failed: {s}\n", .{ name, @errorName(err) });
        return error.SurfaceModuleDispatchFailed;
    };
    txn.commit() catch {};
    txn_done = true;

    const report_json: []const u8 = switch (outcome) {
        .terminal => |*r| blk: {
            defer r.deinit(testing.allocator);
            if (r.exception.len > 0) {
                std.debug.print("\nsurface-tests [{s}]: module threw: {s}\n", .{ name, r.exception });
                return error.SurfaceModuleThrew;
            }
            break :blk try a.dupe(u8, r.body);
        },
        .continuation => |*cont| blk: {
            defer cont.deinit(testing.allocator);
            break :blk try a.dupe(u8, cont.ctx_json);
        },
        .stream => |*s| {
            s.deinit(testing.allocator);
            std.debug.print("\nsurface-tests [{s}]: ended as a stream — return done() or next({{ctx: report}})\n", .{name});
            return error.SurfaceModuleBadEnding;
        },
        .no_onheaders, .no_onchunk => {
            std.debug.print("\nsurface-tests [{s}]: probe outcome — surface modules must dispatch classic inbound\n", .{name});
            return error.SurfaceModuleBadEnding;
        },
    };

    return std.json.parseFromSliceLeaky(Report, a, report_json, .{
        .ignore_unknown_fields = true,
    }) catch {
        std.debug.print(
            "\nsurface-tests [{s}]: report is not {{covers,failures}} JSON — got: {s}\n",
            .{ name, report_json[0..@min(report_json.len, 400)] },
        );
        return error.SurfaceModuleBadReport;
    };
}

const ReflectOut = struct {
    names: [][]const u8 = &.{},
    errors: [][]const u8 = &.{},
};

// ── The suite ───────────────────────────────────────────────────────

test "surface tests: one module per shim, GLOBALS_FILES completeness" {
    var failures: usize = 0;
    for (globals.GLOBALS_FILES) |g| {
        // schedule is in GLOBALS_FILES for the JSDoc lint only — it installs the
        // PRIVATE `_system.sched` (the customer verb is @rewind/schedule), so it
        // has no customer surface test / reflector entry.
        if (std.mem.eql(u8, g.name, "schedule")) continue;
        var found = false;
        for (SURFACE_TESTS) |t| {
            if (std.mem.eql(u8, t.name, g.name)) found = true;
        }
        if (!found) {
            std.debug.print(
                "\nsurface-tests: shim \"{s}\" has no surface_tests/{s}.surface.mjs module\n",
                .{ g.name, g.name },
            );
            failures += 1;
        }
        // The reflector must declare how the shim's surface reflects.
        const marker = std.fmt.allocPrint(testing.allocator, "{s}:", .{g.name}) catch unreachable;
        defer testing.allocator.free(marker);
        if (std.mem.indexOf(u8, REFLECT_SRC, marker) == null) {
            std.debug.print(
                "\nsurface-tests: shim \"{s}\" has no SHIM_ROOTS entry in _reflect.mjs\n",
                .{g.name},
            );
            failures += 1;
        }
    }
    for (SURFACE_TESTS) |t| {
        var known = false;
        for (globals.GLOBALS_FILES) |g| {
            if (std.mem.eql(u8, t.name, g.name)) known = true;
        }
        for (EXTRA_SURFACES) |e| {
            if (std.mem.eql(u8, t.name, e)) known = true;
        }
        if (!known) {
            std.debug.print(
                "\nsurface-tests: module \"{s}\" matches no shim and no EXTRA_SURFACES entry\n",
                .{t.name},
            );
            failures += 1;
        }
    }
    if (failures > 0) return error.SurfaceSuiteIncomplete;
}

test "surface tests: behavior + two-way inventory gate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var cctx = try rt.newContext();
    defer cctx.deinit();
    var d = try dispatcher_mod.Dispatcher.init(testing.allocator);
    defer d.deinit();

    var failures: usize = 0;
    var covered = std.StringHashMap(void).init(a);

    for (SURFACE_TESTS) |t| {
        // Fresh store per module — no cross-namespace state bleed.
        var kv_buf: [64]u8 = undefined;
        const kv = try openTempKv(testing.allocator, &kv_buf);
        defer {
            kv.close();
            std.fs.cwd().deleteFile(std.mem.sliceTo(&kv_buf, 0)) catch {};
        }
        for (SEED_ROWS) |row| try kv.put(row.key, row.value);

        const report = runSurfaceModule(a, &d, &cctx, kv, t.name, t.src) catch {
            failures += 1;
            continue;
        };
        for (report.failures) |f| {
            std.debug.print("\nsurface-tests [{s}] FAIL {s}\n", .{ t.name, f });
            failures += 1;
        }
        if (report.covers.len == 0) {
            std.debug.print("\nsurface-tests [{s}]: module covers nothing — a stub is not a test\n", .{t.name});
            failures += 1;
        }
        for (report.covers) |name| try covered.put(name, {});
    }

    // Reflection pass — same dispatch, same standard request.
    var kv_buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &kv_buf);
    defer {
        kv.close();
        std.fs.cwd().deleteFile(std.mem.sliceTo(&kv_buf, 0)) catch {};
    }
    for (SEED_ROWS) |row| try kv.put(row.key, row.value);

    const reflect_body = blk: {
        const bytecode = try cctx.compileToBytecode(REFLECT_SRC, "_reflect.mjs", a, .{ .kind = .module });
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
        var hdr_buf: [STD_HEADER_PAIRS.len]h2.HeaderField = undefined;
        const hdrs = makeReqHeaders(&hdr_buf, &STD_HEADER_PAIRS);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, .{
            .method = "POST",
            .path = "/surface",
            .host = "surface.test",
            .query = "alpha=1&beta=two",
            .body = STD_BODY,
            .headers = hdrs,
            .trace = .{ .request_id = 2 },
            .plan = .{ .storage = .{ .id = "surface", .incarnation = .legacy }, .blob_cfg = &TEST_BLOB_CFG },
        }, &budget);
        defer resp.deinit(testing.allocator);
        if (resp.exception.len > 0) {
            std.debug.print("\nsurface-tests: _reflect.mjs threw: {s}\n", .{resp.exception});
            return error.SurfaceReflectFailed;
        }
        break :blk try a.dupe(u8, resp.body);
    };

    const reflected = try std.json.parseFromSliceLeaky(ReflectOut, a, reflect_body, .{
        .ignore_unknown_fields = true,
    });
    for (reflected.errors) |e| {
        std.debug.print("\nsurface-tests REFLECT-ERROR: {s}\n", .{e});
        failures += 1;
    }
    // A reflector regression that quietly drops namespaces must not
    // read as "everything covered" — pin a floor well below reality.
    // (The 12 lifted @rewind/* libs are no longer ambient, so the reflected
    // surface is ~97 names; keep the floor under that with headroom.)
    if (reflected.names.len < 80) {
        std.debug.print(
            "\nsurface-tests: reflector found only {d} names — reflector regression?\n",
            .{reflected.names.len},
        );
        return error.SurfaceReflectRegression;
    }

    var reflected_set = std.StringHashMap(void).init(a);
    for (reflected.names) |n| try reflected_set.put(n, {});

    // Direction 1 — every reflected name is covered or allowed.
    var uncovered: usize = 0;
    outer: for (reflected.names) |n| {
        if (covered.contains(n)) continue;
        for (ALLOWED_UNCOVERED) |al| {
            if (std.mem.eql(u8, al.name, n)) continue :outer;
        }
        std.debug.print("\nsurface-tests: PUBLIC NAME NOT COVERED: {s}\n", .{n});
        uncovered += 1;
    }
    if (uncovered > 0) {
        std.debug.print(
            "\nsurface-tests: {d} public name(s) have no covering test — add checks (or a justified ALLOWED_UNCOVERED entry)\n",
            .{uncovered},
        );
        failures += uncovered;
    }

    // Direction 2 — every claim points at a live name (stale-claim guard),
    // and the allowlist itself doesn't outlive the surface it excuses.
    var it = covered.keyIterator();
    while (it.next()) |claim| {
        if (!reflected_set.contains(claim.*)) {
            std.debug.print("\nsurface-tests: STALE CLAIM (not on the live surface): {s}\n", .{claim.*});
            failures += 1;
        }
    }
    for (ALLOWED_UNCOVERED) |al| {
        if (!reflected_set.contains(al.name)) {
            std.debug.print("\nsurface-tests: STALE ALLOWED_UNCOVERED entry: {s} ({s})\n", .{ al.name, al.why });
            failures += 1;
        }
    }

    if (failures > 0) {
        std.debug.print("\nsurface-tests: {d} failure(s)\n", .{failures});
        return error.SurfaceTestsFailed;
    }
}
