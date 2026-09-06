// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Tests for `dispatcher.zig`, split out of the production file — they
//! were 86% of it (the first `test` sat at line ~950 of ~7,000 with no
//! `pub` declaration after it). Same module (rove-js); wired into the
//! test build via root.zig's test aggregator block. The import aliases
//! below mirror dispatcher.zig's own so the moved tests read unchanged.

const std = @import("std");
const qjs = @import("rove-qjs");
const kv_mod = @import("raft-kv");
const tape_mod = @import("rove-tape");
const bodies_mod = @import("rove-bodies");
const tenant_mod = @import("rove-tenant");
const h2 = @import("rove-h2");
const rove = @import("rove");

const globals = @import("globals.zig");
const limiter_mod = @import("limiter.zig");
const bytecode_cache_mod = @import("bytecode_cache.zig");
const BlobBytes = bytecode_cache_mod.BlobBytes;
const c = qjs.c;

const dispatcher_mod = @import("dispatcher.zig");
const reserved = @import("rove-reserved");
const JS_ENGINE_VERSION = dispatcher_mod.JS_ENGINE_VERSION;
const DispatchError = dispatcher_mod.DispatchError;
const Budget = dispatcher_mod.Budget;
const Request = dispatcher_mod.Request;
const Response = dispatcher_mod.Response;
const RunOutcome = dispatcher_mod.RunOutcome;
const Dispatcher = dispatcher_mod.Dispatcher;
const testing = std.testing;

/// Test fixture helper: the production snapshot stores
/// bytecodes as `*BlobBytes` leases into the node-wide cache, but
/// tests run without a NodeState. Each `put` heap-allocates a
/// `BlobBytes` wrapper that aliases the caller's already-allocated
/// bytecode slice (the test already has a `defer allocator.free(bc)`
/// for the bytes themselves); `deinitTestBytecodes` frees the
/// wrappers.
fn putTestBytecode(
    map: *std.StringHashMapUnmanaged(*BlobBytes),
    key: []const u8,
    bc: []const u8,
) !void {
    const bb = try testing.allocator.create(BlobBytes);
    bb.* = .{
        .bytes = @constCast(bc),
        .hash_hex = [_]u8{'0'} ** 64,
        .refcount = .{ .raw = 1 },
    };
    try map.put(testing.allocator, key, bb);
}

fn deinitTestBytecodes(map: *std.StringHashMapUnmanaged(*BlobBytes)) void {
    var it = map.iterator();
    while (it.next()) |e| testing.allocator.destroy(e.value_ptr.*);
    map.deinit(testing.allocator);
}

fn openTempKv(allocator: std.mem.Allocator, buf: *[64]u8) !*kv_mod.KvStore {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const path = try std.fmt.bufPrintZ(buf, "/tmp/rove-js-disp-{x}.db", .{seed});
    return try kv_mod.KvStore.open(allocator, path);
}

/// The store-side spelling of a key a handler NAMES.
///
/// These tests seed and inspect the store DIRECTLY, and a handler's `kv.*`
/// resolves under `reserved.USER_KEY_ROOT` before it reaches storage — so a
/// test that seeds `"k"` and a handler that names `"k"` are talking about
/// different rows unless the test resolves too. JS source inside a test stays
/// in the handler's spelling; only the Zig side of the seam resolves.
///
/// Spelled through the constant rather than a literal so a change of root
/// carries these with it instead of leaving them asserting a stale depth.
inline fn uk(comptime named: []const u8) []const u8 {
    return reserved.USER_KEY_ROOT ++ named;
}

fn cleanupTempKv(buf: *[64]u8) void {
    const path_slice = std.mem.sliceTo(buf, 0);
    std.fs.cwd().deleteFile(path_slice) catch {};
}

test "dispatch: simple response write-back" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\response.status = 201;
        \\return "hi " + request.path;
    ,
        .{ .method = "GET", .path = "/hello" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 201), resp.status);
    try testing.expectEqualStrings("hi /hello", resp.body);
    try testing.expectEqualStrings("", resp.exception);
}

test "dispatch: the cap set is selected by code origin (customer vs baked __system/)" {
    // The grant decision (#753 phase A): a customer activation's object has
    // the customer template as its prototype — `kv` reachable — while a
    // baked `__system/` activation receives the system set, where `kv` is
    // absent (not own, not inherited; the rooted grant is the one kv a
    // baked module holds). Asserted through the real dispatch path, so the
    // selection in `installRequest` is what is being tested, not the
    // templates alone.
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var customer = try runOne(
        &d,
        kv,
        \\const a = arguments[0];
        \\return JSON.stringify({
        \\  kv: typeof a.kv,
        \\  sys: typeof a.__system,
        \\  proto: Object.getPrototypeOf(a) === globalThis.__rove.caps,
        \\});
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer customer.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "{\"kv\":\"object\",\"sys\":\"undefined\",\"proto\":true}",
        customer.body,
    );

    // The baked activation holds the grant and it WORKS: a raw round-trip
    // through `__system.rootKv`, whose spelling storage takes literally —
    // no user-root reroot (the row is verified back through the raw door).
    var system = try runOne(
        &d,
        kv,
        \\const a = arguments[0];
        \\a.__system.rootKv.set("_probe/raw", "1");
        \\return JSON.stringify({
        \\  kv: typeof a.kv,
        \\  next: typeof a.next,
        \\  proto: Object.getPrototypeOf(a) === globalThis.__rove.capsSystem,
        \\  raw: a.__system.rootKv.get("_probe/raw"),
        \\});
    ,
        .{ .method = "GET", .path = "/", .is_system_module = true },
    );
    defer system.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "{\"kv\":\"undefined\",\"next\":\"function\",\"proto\":true,\"raw\":\"1\"}",
        system.body,
    );
}

test "dispatch: kv.get on missing key returns null" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\const v = kv.get("nope");
        \\return String(v);
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("null", resp.body);
}

/// Test harness: wrap a statement-level snippet in a named export
/// named `go`, compile as .mjs, dispatch via the internal
/// `fn_override` target (the resume-engine mechanism — customer
/// `?fn=` query dispatch is not a selector, decisions.md §4.5).
fn runOneOutcome(
    d: *Dispatcher,
    kv: *kv_mod.KvStore,
    body: []const u8,
    request_in: Request,
) !RunOutcome {
    const wrapped = try std.fmt.allocPrint(testing.allocator, "export function go() {{ {s} }}\n", .{body});
    defer testing.allocator.free(wrapped);

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(wrapped, "h.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(bytecode);

    var txn = try kv.beginTrackedImmediate();
    errdefer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();

    // If the caller didn't name a target, route to our wrapper export.
    var request = request_in;
    if (request.fn_override == null) request.fn_override = "go";

    var budget = Budget.fromNow(Budget.default_duration_ns);
    const outcome = try d.runOutcome(kv, &txn, &ws, bytecode, null, null, null, null, 0, request, &budget);
    try txn.commit();
    return outcome;
}

/// Harness that collapses to `Response`. `runOne`-based tests use
/// this; continuation tests call `runOneOutcome`.
fn runOne(
    d: *Dispatcher,
    kv: *kv_mod.KvStore,
    body: []const u8,
    request_in: Request,
) !Response {
    var outcome = try runOneOutcome(d, kv, body, request_in);
    switch (outcome) {
        .terminal => |r| return r,
        .continuation => |*cont| {
            cont.deinit(testing.allocator);
            @panic("runOne: handler returned a continuation; use runOneOutcome");
        },
        .stream => |*s| {
            s.deinit(testing.allocator);
            @panic("runOne: handler returned a stream; use runOneOutcome");
        },
        .no_onheaders => @panic("runOne: no_onheaders outside an inbound_headers dispatch"),
        .no_onchunk => @panic("runOne: no_onchunk outside an inbound_chunk dispatch"),
    }
}

test "dispatch: scope_kv (baked) speaks the named view — user rows rooted, engine rows raw, raw writes refused" {
    // The named-view mapping is the module's whole job (the successor of
    // the scoped door's `SCOPE_RAW_PREFIXES` rule): a key the caller names
    // resolves the way the target handler's own kv does — under the user
    // root, except the engine-written rows. A mapping bug here is the
    // writer/reader prefix-depth split, which only ever surfaces as an
    // empty page far from the cause — so the real embedded source is
    // exercised against real storage.
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    // Storage as it lies: a customer row under the user root, an engine
    // row that never carried one.
    try kv.put(uk("orders/1"), "A");
    try kv.put("_deploy/current", "0abc");

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var qctx = try rt.newContext();
    defer qctx.deinit();
    const bytecode = try qctx.compileToBytecode(@embedFile("builtin_scope_kv_mjs"), "scope_kv.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(bytecode);

    const run = struct {
        fn go(dd: *Dispatcher, store: *kv_mod.KvStore, bc: []const u8, body: []const u8) !Response {
            var txn = try store.beginTrackedImmediate();
            errdefer txn.rollback() catch {};
            var ws = kv_mod.WriteSet.init(testing.allocator);
            defer ws.deinit();
            var budget = Budget.fromNow(Budget.default_duration_ns);
            const outcome = try dd.runOutcome(store, &txn, &ws, bc, null, null, null, null, 0, .{
                .method = "POST",
                .path = "/__system/scope_kv",
                .body = body,
                .is_system_module = true,
                .activation = .{ .platform_dispatch = .{ .actor = .system } },
            }, &budget);
            try txn.commit();
            switch (outcome) {
                .terminal => |r| return r,
                else => @panic("scope_kv returned a non-terminal outcome"),
            }
        }
    }.go;

    var resp = try run(&d, kv, bytecode,
        \\{"ctx":{"gets":["orders/1","_deploy/current"],"prefixes":[{"prefix":""}],"pairs":[{"key":"note","value":"n"}]}}
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), resp.status);
    // Both gets answered — the named row through the root, the engine row raw.
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"orders/1\":\"A\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"_deploy/current\":\"0abc\"") != null);
    // The "" scan pages the USER keyspace: rows come back in the named
    // spelling, and the engine row was never in the range.
    try testing.expect(std.mem.indexOf(u8, resp.body, "_user/") == null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"key\":\"orders/1\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"key\":\"_deploy/current\"") == null);
    // The write landed under the user root, where the target's own handler
    // reads it.
    const wrote = try kv.get(uk("note"));
    defer testing.allocator.free(wrote);
    try testing.expectEqualStrings("n", wrote);

    // A write that names an engine row is refused before anything lands.
    var refused = try run(&d, kv, bytecode,
        \\{"ctx":{"pairs":[{"key":"_deploy/current","value":"clobber"}]}}
    );
    defer refused.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 400), refused.status);
    const cur = try kv.get("_deploy/current");
    defer testing.allocator.free(cur);
    try testing.expectEqualStrings("0abc", cur);
}

/// Test helper. The JS-shim `webhook.send` writes
/// `_send/owed/{id}` as a JSON object marker (see
/// `globals/webhook.js`). The caller owns the returned slice +
/// frees with `testing.allocator.free`.
fn readOwedMarker(kv: *kv_mod.KvStore, id: []const u8) ![]u8 {
    var key_buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, reserved.USER_KEY_ROOT ++ "_send/owed/{s}", .{id}) catch unreachable;
    return kv.get(key);
}

test "dispatch: next(...) return is classified as a continuation" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var outcome = try runOneOutcome(
        &d,
        kv,
        \\return next("handlers/login", { u: "alice", tries: 0 });
    ,
        .{ .method = "GET", .path = "/" },
    );
    switch (outcome) {
        .terminal => return error.TestExpectedContinuation,
        .stream => |*s| {
            s.deinit(testing.allocator);
            return error.TestExpectedContinuation;
        },
        .continuation => |*cont| {
            defer cont.deinit(testing.allocator);
            try testing.expectEqualStrings("handlers/login", cont.path);
            // The public `next(target, ctx)` targets the conventional
            // export (no `fn` — that native option has no public caller).
            try testing.expect(cont.fn_name == null);
            // ctx is JSON-serialized verbatim.
            try testing.expect(std.mem.indexOf(u8, cont.ctx_json, "\"u\":\"alice\"") != null);
            try testing.expect(std.mem.indexOf(u8, cont.ctx_json, "\"tries\":0") != null);
        },
        .no_onheaders, .no_onchunk => return error.TestExpectedContinuation,
    }
}

test "dispatch: ordinary return stays terminal (trampoline does not engage)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Verbatim pre-trampoline behavior: a normal value is the body.
    var r = try runOne(&d, kv, "return \"hi\";", .{ .method = "GET", .path = "/" });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 200), r.status);
    try testing.expectEqualStrings("hi", r.body);

    // And a continuation through the collapsing `run` path yields
    // 501 (that path has no resume wiring), never hangs/panics.
    var outcome = try runOneOutcome(
        &d,
        kv,
        \\return next("m", {});
    ,
        .{ .method = "GET", .path = "/" },
    );
    switch (outcome) {
        .terminal => return error.TestExpectedContinuation,
        .stream => |*s| {
            s.deinit(testing.allocator);
            return error.TestExpectedContinuation;
        },
        .continuation => |*cont| cont.deinit(testing.allocator),
        .no_onheaders, .no_onchunk => return error.TestExpectedContinuation,
    }
}

test "dispatch: kv.set + kv.get round trip" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var r1 = try runOne(
        &d,
        kv,
        \\kv.set("name", "rove");
        \\return "ok";
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer r1.deinit(testing.allocator);

    // First request committed the txn, so the write is durable.
    // Second request observes it.
    var r2 = try runOne(
        &d,
        kv,
        \\return kv.get("name");
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer r2.deinit(testing.allocator);

    try testing.expectEqualStrings("rove", r2.body);
}

/// Run `body` as a handler for a tenant whose plan is `caps`, with a real
/// limiter wired. The outbound gate reads `state.plan_rate` and keys its
/// buckets off `state.instance_id` (which comes from `plan.storage.id`), so
/// both have to be present or the gate short-circuits open and the test
/// proves nothing.
fn runWithPlan(
    d: *Dispatcher,
    kv: *kv_mod.KvStore,
    lim: *limiter_mod.RateLimiter,
    caps: limiter_mod.RateLimitCaps,
    body: []const u8,
) !Response {
    return runOne(d, kv, body, .{
        .method = "POST",
        .path = "/",
        .trace = .{ .request_id = 11 },
        .plan = .{
            .limiter = lim,
            .storage = .{ .id = "acme", .incarnation = .legacy },
            .plan_rate = caps,
        },
    });
}

test "dispatch: a plan without outbound refuses third-party egress, by code" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var lim = limiter_mod.RateLimiter.init(testing.allocator, .{});
    defer lim.deinit();

    // The refusal is permanent, so it carries its own code rather than the
    // rate-limit one: a caller (or a `retry` wrapper) must be able to tell
    // "wait and it will work" from "it will never work".
    var resp = try runWithPlan(&d, kv, &lim, .{ .outbound_enabled = false },
        \\try {
        \\  webhook.send("https://api.example.com/hook", { body: "x" });
        \\  return "sent";
        \\} catch (e) { return "refused:" + e.code; }
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("refused:outbound_not_enabled", resp.body);
    try testing.expectEqual(@as(u64, 1), lim.outbound_disabled_refusals);
}

// The other half of the gate — that `*.internal` doors stay open for a
// tenant with no outbound budget — cannot be written here: the doors are
// reachable only through `_system.*`, which `_harden.js` deletes from
// customer scope, so a handler in this harness has no way to name one.
// `outbound_gate_smoke_v2.py` covers it against a real worker, where
// `blob.*` lowers to the door the way it does in production.

test "dispatch: a plan WITH outbound still sends (the gate is not a wall)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var lim = limiter_mod.RateLimiter.init(testing.allocator, .{});
    defer lim.deinit();

    var resp = try runWithPlan(&d, kv, &lim, .{ .outbound_enabled = true },
        \\try {
        \\  webhook.send("https://api.example.com/hook", { body: "x" });
        \\  return "sent";
        \\} catch (e) { return "refused:" + e.code; }
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("sent", resp.body);
    try testing.expectEqual(@as(u64, 0), lim.outbound_disabled_refusals);
}

test "dispatch: webhook.send writes _send/owed/{id} marker (immediate fire path)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\const id = webhook.send("https://api.stripe.com/v1/charges", { body: "x" });
        \\return id;
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 7 } });
    defer resp.deinit(testing.allocator);

    const marker_raw = try readOwedMarker(kv, resp.body);
    defer testing.allocator.free(marker_raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, marker_raw, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("https://api.stripe.com/v1/charges", obj.get("url").?.string);
    try testing.expectEqualStrings("POST", obj.get("method").?.string);
    try testing.expectEqualStrings("x", obj.get("body").?.string);
    try testing.expectEqual(@as(i64, 0), obj.get("attempts").?.integer);
    // The record version the baked readers switch on
    // (`format-versioning.md` §1f). Asserted here because a declared
    // constant is not a stamped marker: this is the only thing that
    // proves the value written actually carries `v`.
    try testing.expectEqual(@as(i64, 1), obj.get("v").?.integer);
    // Timing left the marker — the scheduler
    // entry under key `_send/{id}` is the durable next-fire authority.
    try testing.expectEqual(@as(?std.json.Value, null), obj.get("next_at_ns"));

    // The immediate path arms a crash-recovery watchdog wake aimed at
    // the baked `__system/webhook_fire`. Schedule id =
    // base64url-no-pad(sha256("_send/" + id)) (schedule's opts.key
    // opts.key recipe).
    const sched_raw = try readSchedByKey(kv, resp.body);
    defer testing.allocator.free(sched_raw);
    var sched = try std.json.parseFromSlice(std.json.Value, testing.allocator, sched_raw, .{});
    defer sched.deinit();
    try testing.expectEqualStrings("__system/webhook_fire", sched.value.object.get("target").?.string);
}

/// Read the `_sched/by_id/` record for webhook.send's scheduler entry
/// (idempotency key `_send/{id}`): schedule id = base64url-no-pad of
/// sha256 of the key — the same recipe `scheduler.at` applies to
/// `opts.key`.
fn readSchedByKey(kv: *kv_mod.KvStore, send_id: []const u8) ![]u8 {
    var key_buf: [256]u8 = undefined;
    const sched_key = std.fmt.bufPrint(&key_buf, "_send/{s}", .{send_id}) catch unreachable;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(sched_key, &digest, .{});
    var id_buf: [43]u8 = undefined;
    const sched_id = std.base64.url_safe_no_pad.Encoder.encode(&id_buf, &digest);
    var kv_key_buf: [300]u8 = undefined;
    const kv_key = std.fmt.bufPrint(&kv_key_buf, reserved.USER_KEY_ROOT ++ "_sched/by_id/{s}", .{sched_id}) catch unreachable;
    return kv.get(kv_key);
}

// The JS-shim `webhook.send` path is exercised by the marker tests
// above + the webhook smoke (`scripts/webhook_smoke.py`).

test "dispatch: webhook.send with handle derives a stable id; same handle overwrites the marker" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Same key → same id → last-write-wins on `_send/owed/{id}`.
    var resp = try runOne(&d, kv,
        \\const id1 = webhook.send("https://x/", { key: "reminder-foo" });
        \\const id2 = webhook.send("https://y/", { key: "reminder-foo", in: "24h" });
        \\return id1 + "|" + id2;
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);

    // Same id twice — sha256(handle) is deterministic on input.
    const sep = std.mem.indexOfScalar(u8, resp.body, '|').?;
    try testing.expectEqualStrings(resp.body[0..sep], resp.body[sep + 1 ..]);

    const marker_raw = try readOwedMarker(kv, resp.body[0..sep]);
    defer testing.allocator.free(marker_raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, marker_raw, .{});
    defer parsed.deinit();
    // The second write (scheduled fire) won.
    try testing.expectEqualStrings("https://y/", parsed.value.object.get("url").?.string);
}

// Endpoint A (decisions.md): a customer `on_result` hop (webhook.send /
// blob.put / retry) AND a §6.4 held-sync resume both arrive as a
// `.send_callback` whose body is `{"ctx":{result,context}}`. The runtime
// hoists it onto the SAME flattened surface a bound fetch resume uses:
// `request.body` = response bytes, top-level `request.status`/`.done`
// (`status` is the single success signal; no `request.ok`),
// the THREADED ctx (the echoed `context`) on `request.ctx` (bare), and the
// per-delivery metadata on `request.activation.*`. There is NO
// `request.result` and no positional `outcome`.
test "dispatch: connectionless on_result presents the flattened result surface (no request.result)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\return [
        \\  "status=" + request.status,
        \\  "done=" + request.done,
        \\  "body=" + request.text,
        \\  "ctx.order=" + request.ctx.order,
        \\  "act.attempts=" + request.activation.attempts,
        \\  "act.error=" + request.activation.error,
        \\  "result=" + (typeof request.result),
        \\].join(" ");
    , .{
        .method = "POST",
        .path = "/_result",
        .activation = .send_callback,
        .trace = .{ .request_id = 1 },
        .body =
        \\{"ctx":{"result":{"id":"abc","ok":true,"status":200,"body":"PONG","headers":{},"body_truncated":false,"attempts":1,"error":null},"context":{"order":42}}}
        ,
    });
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings(
        "status=200 done=true body=PONG ctx.order=42 act.attempts=1 act.error=null result=undefined",
        resp.body,
    );
}

// The hoist fires only on a result DELIVERY — a `.send_callback` body that
// is NOT `{"ctx":{result,…}}` (e.g. webhook_onresult's own bookkeeping
// self-hop, `{"ctx":{id,…}}` with no `result` object) is left untouched:
// `request.status` stays undefined and the raw body survives.
test "dispatch: send_callback without a result object lifts the whole envelope ctx" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\return "status=" + request.status + " id=" + request.ctx.id +
        \\  " note=" + request.ctx.note + " body=" + typeof request.body;
    , .{
        .method = "POST",
        .path = "/_result",
        .activation = .send_callback,
        .trace = .{ .request_id = 1 },
        .body =
        \\{"ctx":{"id":"send-7","note":"self-hop"}}
        ,
    });
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("status=undefined id=send-7 note=self-hop body=undefined", resp.body);
}

test "dispatch: request.session.id surfaces resolved sid" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    const known: [64]u8 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".*;
    var resp = try runOne(
        &d,
        kv,
        \\return request.session.id;
    ,
        .{ .method = "GET", .path = "/", .session_id = known },
    );
    defer resp.deinit(testing.allocator);

    // Customer-visible: the opaque `sess_<64hex>` prefixed form (§7.5).
    try testing.expectEqualStrings("sess_" ++ known, resp.body);
}

test "dispatch: request.session is null when no sid resolved" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\return String(request.session);
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("null", resp.body);
}

// ── docs/decisions.md §4.11 (fail-loud sweep) ─────────

test "dispatch: Uint8Array return ships raw bytes, not JSON (C1)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\return new Uint8Array([104, 105, 0, 255]);
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualSlices(u8, &[_]u8{ 104, 105, 0, 255 }, resp.body);
}

test "dispatch: kv.set rejects object/array/bytes/null values fail-loud (C2)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\const bad = [{ a: 1 }, [1, 2], new Uint8Array([1, 2, 3]), null, undefined];
        \\for (const v of bad) {
        \\  let threw = null;
        \\  try { kv.set("k", v); } catch (e) { threw = e; }
        \\  if (!(threw instanceof TypeError)) return "no-throw: " + String(v);
        \\}
        \\if (kv.get("k") !== null) return "wrote-anyway";
        \\let kthrew = null;
        \\try { kv.set({ oops: 1 }, "v"); } catch (e) { kthrew = e; }
        \\if (!(kthrew instanceof TypeError)) return "key-no-throw";
        \\let dthrew = null;
        \\try { kv.delete({ oops: 1 }); } catch (e) { dthrew = e; }
        \\if (!(dthrew instanceof TypeError)) return "delete-no-throw";
        \\return "all-threw";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("all-threw", resp.body);
}

test "dispatch: kv.set still accepts number/boolean/bigint primitives (C2)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\kv.set("count", 5);
        \\kv.set("flag", true);
        \\kv.set("big", 9007199254740993n);
        \\return kv.get("count") + "|" + kv.get("flag") + "|" + kv.get("big");
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("5|true|9007199254740993", resp.body);
}

test "dispatch: webhook.send rejects a non-string body (C3)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\let threw = null;
        \\try {
        \\  webhook.send("https://x.test/hook", { body: new Uint8Array([1, 2]) });
        \\} catch (e) { threw = e; }
        \\return threw instanceof TypeError ? "threw" : "no-throw";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("threw", resp.body);
}

test "dispatch: next({ctx}) with unserializable ctx throws, absent ctx stays legal (C4)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\let threw = null;
        \\try { next("", { big: 10n }); } catch (e) { threw = e; }
        \\if (!(threw instanceof TypeError)) return "no-throw";
        \\next("", {});   // ctx present-but-empty must not throw
        \\next("");       // same-module, empty ctx must not throw
        \\return "threw";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("threw", resp.body);
}

// ── decisions.md §4.11 — the uniform payload surface ──

test "dispatch: request.bytes/.text/.json on plain inbound (§2.2)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\const b = request.bytes;
        \\if (!(b instanceof Uint8Array)) return "not-bytes";
        \\if (request.text !== '{"a":1}') return "text-mismatch: " + request.text;
        \\if (request.json.a !== 1) return "json-mismatch";
        \\if (typeof request.body !== "undefined") return "body-not-retired";
        \\return "ok:" + b.length;
    ,
        .{ .method = "POST", .path = "/", .body = "{\"a\":1}" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("ok:7", resp.body);
}

test "dispatch: invalid UTF-8 inbound text reads lenient U+FFFD, bytes stay raw (C6)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\const cp = request.text.charCodeAt(2).toString(16);
        \\return request.text.length + ":" + cp + ":" + request.bytes[2];
    ,
        .{ .method = "POST", .path = "/", .body = "hi\xffbye" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    // 6 chars with a U+FFFD at index 2; the raw byte stays 0xff (255).
    try testing.expectEqualStrings("6:fffd:255", resp.body);
}

test "dispatch: send_callback body_b64 → byte-true request.bytes (§2.2)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    // body_b64 "aAD_" = bytes [0x68, 0x00, 0xff] (base64url, no pad) —
    // a payload a lossy string channel could not carry.
    var resp = try runOne(&d, kv,
        \\const b = request.bytes;
        \\if (!(b instanceof Uint8Array)) return "not-bytes";
        \\if (b.length !== 3 || b[0] !== 104 || b[1] !== 0 || b[2] !== 255) return "bytes-wrong";
        \\if (typeof request.body !== "undefined") return "body-not-retired";
        \\if (request.text.length !== 3) return "text-wrong";
        \\return "ok:" + request.status + ":" + request.ctx.o;
    , .{
        .method = "POST",
        .path = "/_result",
        .activation = .send_callback,
        .trace = .{ .request_id = 1 },
        .body =
        \\{"ctx":{"result":{"id":"abc","ok":true,"status":200,"body_b64":"aAD_","body":"h","headers":{},"body_truncated":false,"attempts":1,"error":null},"context":{"o":1}}}
        ,
    });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("ok:200:1", resp.body);
}

test "dispatch: send_callback legacy body-only envelope still yields bytes (§2.2)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(&d, kv,
        \\const b = request.bytes;
        \\if (!(b instanceof Uint8Array) || b.length !== 4) return "bytes-wrong";
        \\if (typeof request.body !== "undefined") return "body-not-retired";
        \\return "ok:" + request.text;
    , .{
        .method = "POST",
        .path = "/_result",
        .activation = .send_callback,
        .trace = .{ .request_id = 1 },
        .body =
        \\{"ctx":{"result":{"id":"abc","ok":true,"status":200,"body":"PONG","headers":{},"body_truncated":false,"attempts":1,"error":null},"context":null}}
        ,
    });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("ok:PONG", resp.body);
}

test "dispatch: no payload surface on a durable_wake activation (§2.2)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    // A wake's Request.body is internal plumbing (or empty) — it must
    // NOT leak through the payload surface.
    var resp = try runOne(&d, kv,
        \\return [typeof request.bytes, typeof request.text, typeof request.json].join(",");
    , .{
        .method = "POST",
        .path = "/_wake",
        .activation = .{ .durable_wake = .{ .id = "sched1", .scheduled_at_ns = 1, .msg_json = "null" } },
        .trace = .{ .request_id = 1 },
    });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("undefined,undefined,undefined", resp.body);
}

test "dispatch: ws_message frame payload on request.bytes/.text (§2.2)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var outcome = try runOneOutcome(&d, kv,
        \\const b = request.bytes;
        \\if (!(b instanceof Uint8Array) || b.length !== 5) return "bytes-wrong";
        \\if (request.text !== "hello") return "text-wrong";
        \\if (request.activation.data !== "hello") return "data-wrong";
        \\return "ok";
    , .{
        .method = "GET",
        .path = "/_ws",
        .activation = .{ .ws_message = .{ .opcode = 1, .data = "hello" } },
        .trace = .{ .request_id = 1 },
    });
    switch (outcome) {
        .terminal => |*r| {
            defer r.deinit(testing.allocator);
            try testing.expectEqualStrings("", r.exception);
            try testing.expectEqualStrings("ok", r.body);
        },
        .continuation => |*cont| {
            cont.deinit(testing.allocator);
            return error.TestExpectedTerminal;
        },
        .stream => |*s| {
            s.deinit(testing.allocator);
            return error.TestExpectedTerminal;
        },
        .no_onheaders, .no_onchunk => return error.TestExpectedTerminal,
    }
}

// ── decisions.md §4.11 — the grammar sweep ──────────

test "dispatch: after.fetch returns a ftch_-prefixed id (§2.3/§2.4)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\const id = after.fetch("http://up.test/", { on: "onR" });
        \\if (typeof id !== "string" || !id.startsWith("ftch_")) return "new-bad:" + id;
        \\if (typeof after.ms !== "function" || typeof after.kv !== "function") return "no-after";
        \\if (typeof globalThis.on !== "undefined") return "on-alias-still-installed";
        \\return "ok";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("ok", resp.body);
}

test "dispatch: customer JS reaches the blob door directly, leaving no platform record" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    // `blob.put` composes a durable `_blob/owed/{hash}` marker and only THEN
    // fires the signed PUT through `rove-blob.internal`. Nothing binds the two:
    // the fetch engine decides the door by URL prefix alone, and the public
    // fetch verb puts no host restriction on a customer-supplied URL. So a
    // handler can write its own `app-blobs/` prefix with the marker absent —
    // which is why per-tenant byte accounting cannot be derived from the
    // marker, and a quota cannot be enforced in the shim.
    var resp = try runOne(
        &d,
        kv,
        \\const hash = crypto.sha256("smuggled");
        \\after.fetch("http://rove-blob.internal/" + hash, { method: "PUT", body: "smuggled" });
        \\return kv.get("_blob/owed/" + hash) === null ? "no-marker" : "marker";
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("no-marker", resp.body);
}

test "dispatch: webhook.send(url, {on, ctx}) canonical form writes the marker (§2.3)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\const id = webhook.send("https://t.example/hook", {
        \\  body: "x", on: "hooks/onDone", ctx: { a: 1 }, key: "h-canon",
        \\});
        \\return id;
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    const marker = try readOwedMarker(kv, resp.body);
    defer testing.allocator.free(marker);
    try testing.expect(std.mem.indexOf(u8, marker, "\"on_result\":\"hooks/onDone\"") != null);
    try testing.expect(std.mem.indexOf(u8, marker, "\"context\":{\"a\":1}") != null);
    try testing.expect(std.mem.indexOf(u8, marker, "\"url\":\"https://t.example/hook\"") != null);
}

test "PROBE after.cancel" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(&d, kv,
        \\try { after.cancel("ftch_00aabb"); return "ok"; } catch (e) { return "threw: " + e.message; }
    , .{ .method = "POST", .path = "/" });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("ok", resp.body);
}

test "kv subscriptions: the fire activation surfaces name + source {kind:kv, prefix} (no key/op)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bc = try ctx.compileToBytecode(
        \\export function onSubscription() {
        \\  const a = request.activation;
        \\  return JSON.stringify({
        \\    kind: a.kind, name: a.name,
        \\    srcKind: a.source.kind, prefix: a.source.prefix,
        \\    key: a.source.key === undefined, op: a.source.op === undefined,
        \\  });
        \\}
    , "sub.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(bc);

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bc, null, null, null, null, 0, .{
        .method = "POST",
        .path = "/_subscriptions/orders-react/index",
        .fn_override = "onSubscription",
        .activation = .{ .subscription_fire = .{
            .name = "orders-react",
            .source = .{ .kv = .{ .prefix = "orders/" } },
        } },
        .trace = .{ .request_id = 1 },
    }, &budget);
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings(
        \\{"kind":"subscription_fire","name":"orders-react","srcKind":"kv","prefix":"orders/","key":true,"op":true}
    , resp.body);
}

test "kv subscriptions: watched-prefix writes inject ONE durable dirty marker (coalesced, atomic, recursion-guarded)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bc = try ctx.compileToBytecode(
        \\export function go() {
        \\  kv.set("orders/1", "a");
        \\  kv.set("orders/2", "b");   // same sub - marker deduped
        \\  kv.set("other/1", "c");    // unwatched - no marker
        \\  kv.delete("orders/1");     // deletes trigger too (already marked)
        \\  return "ok";
        \\}
    , "s.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(bc);

    const prefix_owned = try testing.allocator.dupe(u8, "orders/");
    defer testing.allocator.free(prefix_owned);
    const name_owned = try testing.allocator.dupe(u8, "orders-react");
    defer testing.allocator.free(name_owned);
    const mod_owned = try testing.allocator.dupe(u8, "_subscriptions/orders-react/index.mjs");
    defer testing.allocator.free(mod_owned);
    const subs = [_]globals.SubscriptionEntry{.{
        .name = name_owned,
        .module_path = mod_owned,
        .spec = .{ .kv = .{ .prefix = prefix_owned } },
    }};

    var txn = try kv.beginTrackedImmediate();
    var txn_done = false;
    defer if (!txn_done) txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bc, null, null, null, &.{ .subscriptions = &subs }, 0, .{
        .method = "POST",
        .path = "/",
        .fn_override = "go",
        .trace = .{ .request_id = 1 },
    }, &budget);
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try txn.commit();
    txn_done = true;

    // The durable marker landed (value = the watched prefix)...
    const marker = try kv.get("_sub/dirty/orders-react");
    defer testing.allocator.free(marker);
    try testing.expectEqualStrings("orders/", marker);
    // ...exactly ONCE in the writeset despite three matching ops (the
    // activation-level dedup), atomic with the writes it announces.
    var marker_puts: usize = 0;
    for (ws.ops.items) |op| switch (op) {
        .put => |pp| {
            if (std.mem.startsWith(u8, pp.key, "_sub/dirty/")) marker_puts += 1;
        },
        .delete => {},
    };
    try testing.expectEqual(@as(usize, 1), marker_puts);
}

test "arena-oom retry: churny handler succeeds under GC re-execution" {
    // This test provokes arena exhaustion on purpose; the retry path warns by
    // design. The test runner captures warnings and reports them as failures,
    // so an expected-failure test would fail for doing its job. Errors still
    // surface.
    const prev_log = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log;

    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.initWithSizes(testing.allocator, .{ .request_size = 8 * 1024 * 1024 });
    defer d.deinit();

    // Seed a counter the handler increments BEFORE churning: proves the
    // GC rerun reads the ORIGINAL value (savepoint dropped attempt 1's
    // staged write — read-your-writes across attempts would yield 7).
    {
        var txn = try kv.beginTrackedImmediate();
        try txn.put(uk("n"), "5");
        try txn.commit();
    }

    var rs = tape_mod.Readset.init(testing.allocator, 1_700_000_000_000_000_000, 42);
    defer rs.deinit();
    rs.js_engine_version = qjs.JS_ENGINE_VERSION;

    var resp = try runOne(&d, kv,
        \\const n = parseInt(kv.get("n") ?? "0", 10) + 1;
        \\kv.set("n", String(n));
        \\let s = "";
        \\for (let i = 0; i < 32; i++) { s = "x".repeat(1 << 19) + i; }
        \\return "n=" + n + " len=" + s.length;
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1, .readset = &rs } });
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("n=6 len=524290", resp.body);
    try testing.expect(d.last_arena_gc_retry);
    try testing.expectEqual(qjs.snap.ReqMode.gc, d.last_arena_mode);
    // The engine word carries the regime for replay (high bit); the
    // version bits stay intact. The doomed attempt's kv-tape entries
    // were discarded: exactly ONE recorded read of "n" (the retry's).
    try testing.expect(rs.js_engine_version & qjs.ENGINE_ARENA_GC_BIT != 0);
    try testing.expectEqual(qjs.JS_ENGINE_VERSION, rs.js_engine_version & qjs.ENGINE_VERSION_MASK);
    var n_reads: usize = 0;
    for (rs.kv.entries.items) |e| {
        if (std.mem.eql(u8, e.kv.key, "_user/n")) n_reads += 1;
    }
    try testing.expectEqual(@as(usize, 1), n_reads);
    // The committed value is the retry's single increment.
    const v = try kv.get(uk("n"));
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("6", v);
}

test "arena-oom: loud 500 when even GC can't fit the request (no silent empty body)" {
    // Provokes arena exhaustion on purpose; that path warns by design and the
    // runner reports captured warnings as failures. Errors still surface.
    const prev_log = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log;

    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.initWithSizes(testing.allocator, .{ .request_size = 8 * 1024 * 1024 });
    defer d.deinit();

    // Peak LIVE set (all 32 × 512 KiB strings held at once) = 16 MiB >
    // the 8 MiB arena — the churny reassign trick wouldn't help (GC's
    // ceiling is peak live). Bump OOMs → GC retry OOMs too → must fail
    // LOUD (a 500 with an exception), never the silent empty 200 a
    // mangled OOM outcome would otherwise yield.
    var resp = try runOne(&d, kv,
        \\const a = [];
        \\for (let i = 0; i < 32; i++) a.push("x".repeat(1 << 19));
        \\return "len=" + a.length;
    , .{ .method = "POST", .path = "/" });
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 500), resp.status);
    try testing.expect(resp.exception.len > 0);
    try testing.expect(std.mem.indexOf(u8, resp.exception, "exhausted") != null);
    try testing.expectEqualStrings("", resp.body); // not a silent partial
    // The GC retry was attempted (and also OOM'd).
    try testing.expect(d.last_arena_gc_retry);
}

test "static onChunk: a failed upstream read fails loud (502), never a silent 200" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    // The static.mjs onChunk guard (the audit fix): a terminal fetch event
    // reporting failure MUST 502 on the first (head-not-yet-committed)
    // chunk, not serve a well-formed 200 for a broken/missing blob.
    const bc = try ctx.compileToBytecode(
        \\export function onChunk() {
        \\  const a = request.activation;
        \\  if (a.final && (a.status < 200 || a.status >= 300 || a.bodyTruncated)) {
        \\    if (a.seq === 0) { response.status = 502; return "static asset read failed (status " + a.status + ")"; }
        \\    throw new Error("static read failed mid-stream");
        \\  }
        \\  response.status = 200; stream.start();
        \\  if (a.bytes && a.bytes.length) stream.write(a.bytes);
        \\  if (a.final) return "";
        \\  return next();
        \\}
    , "s.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(bc);

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);

    // A missing blob: the single terminal event is ok:false, status 404,
    // seq 0 — the head hasn't been committed, so a clean 502 is possible.
    var resp = try d.run(kv, &txn, &ws, bc, null, null, null, null, 0, .{
        .method = "GET",
        .path = "/",
        .fn_override = "onChunk",
        .activation = .{ .fetch_chunk = .{ .final = true, .terminal_ok = false, .terminal_status = 404, .seq = 0 } },
        .trace = .{ .request_id = 1 },
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 502), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "read failed") != null);
    try testing.expectEqualStrings("", resp.exception);
}

test "arena-oom retry: the worker's churny hint skips the doomed bump attempt" {
    // This test provokes arena exhaustion on purpose; the retry path warns by
    // design. The test runner captures warnings and reports them as failures,
    // so an expected-failure test would fail for doing its job. Errors still
    // surface.
    const prev_log = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log;

    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.initWithSizes(testing.allocator, .{ .request_size = 8 * 1024 * 1024 });
    defer d.deinit();
    var resp = try runOne(&d, kv,
        \\let s = "";
        \\for (let i = 0; i < 32; i++) { s = "x".repeat(1 << 19) + i; }
        \\return "len=" + s.length;
    , .{ .method = "POST", .path = "/", .arena_mode = .gc });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("len=524290", resp.body);
    try testing.expect(!d.last_arena_gc_retry);
    try testing.expectEqual(qjs.snap.ReqMode.gc, d.last_arena_mode);
}

test "arena-oom retry: an immediate side effect vetoes re-execution" {
    // Provokes arena exhaustion on purpose; that path warns by design and the
    // runner reports captured warnings as failures. Errors still surface.
    const prev_log = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log;

    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.initWithSizes(testing.allocator, .{ .request_size = 8 * 1024 * 1024 });
    defer d.deinit();
    // after.cancel fires the cancel_fetch trampoline path — an
    // immediate worker-side effect (raises side_effects_flag even when
    // the test harness wires no trampoline). The subsequent OOM must
    // NOT retry: re-execution would double the effect.
    var resp = try runOne(&d, kv,
        \\after.cancel("ftch_00aabb");
        \\let s = "";
        \\for (let i = 0; i < 32; i++) { s = "x".repeat(1 << 19) + i; }
        \\return "unreachable " + s.length;
    , .{ .method = "POST", .path = "/" });
    defer resp.deinit(testing.allocator);
    try testing.expect(resp.exception.len > 0);
    try testing.expect(!d.last_arena_gc_retry);
    try testing.expectEqual(qjs.snap.ReqMode.bump, d.last_arena_mode);
}

test "dispatch: console quartet lands level-prefixed lines in the request log" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(&d, kv,
        \\console.log("plain", 1);
        \\console.warn("careful");
        \\console.error("boom", 2);
        \\console.info("fyi");
        \\console.debug("wire");
        \\return "ok";
    , .{ .method = "POST", .path = "/" });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("ok", resp.body);
    try testing.expect(std.mem.indexOf(u8, resp.console, "plain 1") != null);
    try testing.expect(std.mem.indexOf(u8, resp.console, "[warn] careful") != null);
    try testing.expect(std.mem.indexOf(u8, resp.console, "[error] boom 2") != null);
    try testing.expect(std.mem.indexOf(u8, resp.console, "[info] fyi") != null);
    try testing.expect(std.mem.indexOf(u8, resp.console, "[debug] wire") != null);
}

test "dispatch: console JSON-stringifies non-strings (never [object Object])" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    // The formatter contract (globals/console.js `fmt`, mirrored by the sim
    // epilogue's `__fmtLog` — the consolefmt fixture pins the SAME strings):
    // strings pass through; objects/arrays/numbers/null JSON-stringify;
    // undefined/functions/circulars fall back to String(x).
    var resp = try runOne(&d, kv,
        \\console.log({ a: 1 }, [1, 2], 42, null, undefined);
        \\const c = {}; c.self = c;
        \\console.log(c);
        \\console.warn({ retry: true });
        \\console.error();
        \\return "ok";
    , .{ .method = "POST", .path = "/" });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expect(std.mem.indexOf(u8, resp.console, "{\"a\":1} [1,2] 42 null undefined\n") != null);
    // circular → String(x) fallback (the one place [object Object] remains)
    try testing.expect(std.mem.indexOf(u8, resp.console, "[object Object]\n") != null);
    try testing.expect(std.mem.indexOf(u8, resp.console, "[warn] {\"retry\":true}\n") != null);
    try testing.expect(std.mem.indexOf(u8, resp.console, "[error]\n") != null);
}

test "dispatch: durable_wake payload reads as request.ctx ONLY (one-ctx §2.4)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(&d, kv,
        \\return JSON.stringify([request.ctx, typeof request.activation.msg,
        \\  typeof request.activation.scheduledAtNs, typeof request.activation.scheduled_at_ns]);
    , .{
        .method = "POST",
        .path = "/_wake",
        .activation = .{ .durable_wake = .{ .id = "s1", .scheduled_at_ns = 7, .msg_json = "{\"a\":2}" } },
        .trace = .{ .request_id = 1 },
    });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("[{\"a\":2},\"undefined\",\"number\",\"undefined\"]", resp.body);
}

test "dispatch: a customer write to a platform NAME lands in the customer's keyspace" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Spoofing a callback row used to throw `Error{code:"reserved_key"}`. It
    // cannot be spoofed now for a better reason: the handler's kv is rooted, so
    // the name reaches a row of the handler's own and the platform's row of that
    // name is not addressable at all. Nothing is refused, and nothing needs to
    // be — which is the whole of what the reserved-prefix rule was for.
    var resp = try runOne(
        &d,
        kv,
        \\try {
        \\  kv.set("_callback/spoofed", "x");
        \\  return "ok:" + kv.get("_callback/spoofed");
        \\} catch (e) {
        \\  return e.code + ":" + e.message;
        \\}
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("ok:x", resp.body);

    // The platform's row of that name was never touched — different key.
    try testing.expectError(error.NotFound, kv.get("_callback/spoofed"));
    const own = try kv.get(uk("_callback/spoofed"));
    defer testing.allocator.free(own);
    try testing.expectEqualStrings("x", own);
}
test "dispatch: a customer delete of a platform NAME cannot reach the platform's row" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // The engine's row, planted below the binding the way platform Zig writes.
    try kv.put("_callback/real", "engine");

    var resp = try runOne(
        &d,
        kv,
        \\try {
        \\  kv.delete("_callback/real");
        \\  return "deleted";
        \\} catch (e) {
        \\  return e.code;
        \\}
    ,
        .{ .method = "DELETE", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    // The delete succeeds — against a row in the handler's own keyspace, which
    // did not exist. The engine's row survives, which is the property that used
    // to need a predicate on every write.
    try testing.expectEqualStrings("deleted", resp.body);
    const engine = try kv.get("_callback/real");
    defer testing.allocator.free(engine);
    try testing.expectEqualStrings("engine", engine);
}
test "dispatch: kv.set into customer namespace still works" {
    // Regression: the reserved-prefix guard must not catch normal
    // customer keys that happen to share a prefix substring (e.g.
    // "my_audit/" should not collide with "_audit/").
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var r1 = try runOne(
        &d,
        kv,
        \\kv.set("my_audit/x", "v1");
        \\kv.set("users/alice", "v2");
        \\return "ok";
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer r1.deinit(testing.allocator);
    try testing.expectEqualStrings("ok", r1.body);

    const a = try kv.get(uk("my_audit/x"));
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("v1", a);
    const b = try kv.get(uk("users/alice"));
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("v2", b);
}

test "dispatch: kv.delete removes key" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    try kv.put(uk("k"), "v");

    var r1 = try runOne(
        &d,
        kv,
        \\kv.delete("k");
        \\return "ok";
    ,
        .{ .method = "DELETE", .path = "/" },
    );
    defer r1.deinit(testing.allocator);

    // After commit, the key is gone.
    try testing.expectError(error.NotFound, kv.get(uk("k")));
}

test "dispatch: request.host is exposed verbatim from :authority" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\return request.host;
    ,
        .{ .method = "GET", .path = "/", .host = "app.loop46.localhost:8198" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("app.loop46.localhost:8198", resp.body);
}

test "dispatch: read-your-writes within one handler works via TrackedTxn" {
    // The TrackedTxn opens a SQLite transaction, writes go through it
    // (visible to subsequent reads from the same connection), and
    // commit fires after the handler returns. Inside the handler,
    // kv.set is immediately observable to kv.get.
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\kv.set("x", "fresh");
        \\return kv.get("x");
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("fresh", resp.body);
}

test "dispatch: console.log captured into response.console" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\console.log("hello", "world");
        \\console.log("line2");
        \\return "x";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("hello world\nline2\n", resp.console);
}

test "dispatch: tag captured into response.tags (update-in-place)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\arguments[0].tag("session", "S1");
        \\arguments[0].tag("flow", "checkout");
        \\arguments[0].tag("session", "S2"); // same key → updates in place
        \\return "x";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), resp.tags.len);
    var saw_session = false;
    var saw_flow = false;
    for (resp.tags) |t| {
        if (std.mem.eql(u8, t.key, "session")) {
            try testing.expectEqualStrings("S2", t.value);
            saw_session = true;
        }
        if (std.mem.eql(u8, t.key, "flow")) {
            try testing.expectEqualStrings("checkout", t.value);
            saw_flow = true;
        }
    }
    try testing.expect(saw_session and saw_flow);
}

test "dispatch: Trace.parent_saga seeds the reserved _parent tag alongside user tags" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    // FOUR user tags — the full quota. The engine tag is stamped after
    // the handler runs, so it must never consume a customer slot (a
    // quota throw here would be prod-only AND engine-divergent: the
    // sim never seeds a parent).
    var resp = try runOne(
        &d,
        kv,
        \\arguments[0].tag("flow", "checkout");
        \\arguments[0].tag("a", "1");
        \\arguments[0].tag("b", "2");
        \\arguments[0].tag("c", "3");
        \\return "x";
    ,
        .{ .method = "GET", .path = "/", .trace = .{ .parent_saga = "corr-armed-me" } },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), resp.tags.len);
    var saw_parent = false;
    var saw_flow = false;
    for (resp.tags) |t| {
        if (std.mem.eql(u8, t.key, "_parent")) {
            try testing.expectEqualStrings("corr-armed-me", t.value);
            saw_parent = true;
        }
        if (std.mem.eql(u8, t.key, "flow")) saw_flow = true;
    }
    try testing.expect(saw_parent and saw_flow);
}

test "dispatch: a forged/oversized parent_saga is dropped, never stamped" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    const big = "x" ** 300;
    var resp = try runOne(
        &d,
        kv,
        \\return "x";
    ,
        .{ .method = "GET", .path = "/", .trace = .{ .parent_saga = big } },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), resp.tags.len);

    var resp2 = try runOne(
        &d,
        kv,
        \\return "x";
    ,
        .{ .method = "GET", .path = "/", .trace = .{ .parent_saga = "bad\x01ctl" } },
    );
    defer resp2.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), resp2.tags.len);
}

test "dispatch: tag rejects reserved + over-cap (fail loud)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    // A reserved `_`-prefixed key throws → the handler exception is
    // surfaced on the Response (caught, not a crash).
    var resp = try runOne(
        &d,
        kv,
        \\arguments[0].tag("_saga", "nope");
        \\return "x";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expect(resp.exception.len > 0);
}

test "dispatch: response.headers emitted, reserved names filtered, custom CT overrides auto-json" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Handler sets: one safe header, one reserved name (dropped),
    // one pseudo-header (dropped), content-type override.
    var resp = try runOne(
        &d,
        kv,
        \\response.headers = {
        \\  "X-Request-Id": "abc123",
        \\  "Set-Cookie": "evil=1",              // reserved → dropped
        \\  ":status": "999",                    // pseudo → dropped
        \\  "content-type": "application/xml",   // overrides auto json
        \\};
        \\return { shape: "object, triggers body_is_json" };
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    var saw_request_id = false;
    var saw_content_type_override = false;
    for (resp.headers) |h| {
        if (std.mem.eql(u8, h.name, "x-request-id")) {
            saw_request_id = true;
            try testing.expectEqualStrings("abc123", h.value);
        }
        if (std.mem.eql(u8, h.name, "content-type")) {
            saw_content_type_override = true;
            try testing.expectEqualStrings("application/xml", h.value);
        }
        // Reserved names must not appear.
        try testing.expect(!std.mem.eql(u8, h.name, "set-cookie"));
        try testing.expect(!std.mem.eql(u8, h.name, ":status"));
    }
    try testing.expect(saw_request_id);
    try testing.expect(saw_content_type_override);
    // body_is_json should be suppressed when handler set content-type.
    try testing.expect(!resp.body_is_json);
}

test "dispatch: response.headers empty → no custom headers on Response" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\return "hi";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), resp.headers.len);
}

test "dispatch: response.cookies surface on Response.set_cookies, Domain stripped" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\response.cookies.push("session=abc; Path=/; Domain=loop46.me; HttpOnly");
        \\response.cookies.push("flag=on; Secure");
        \\return "ok";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), resp.set_cookies.len);
    try testing.expectEqualStrings("session=abc; Path=/; HttpOnly", resp.set_cookies[0]);
    try testing.expectEqualStrings("flag=on; Secure", resp.set_cookies[1]);
}

test "dispatch: malformed bytecode surfaces in exception field" {
    // Compile errors happen at upload time in production (rove-files-cli
    // calls compileToBytecode, which returns JsException on bad source),
    // not in the dispatcher. The dispatcher's job is to gracefully
    // handle malformed bytecode at runtime — version skew, corruption,
    // a wrong file type, etc. Pass random bytes and verify the
    // JS_ReadObject failure lands in resp.exception.
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();

    const garbage = [_]u8{ 0xff, 0x00, 0xde, 0xad, 0xbe, 0xef };
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(
        kv,
        &txn,
        &ws,
        &garbage,
        null,
        null,
        null,
        null,
        0,
        .{ .method = "GET", .path = "/" },
        &budget,
    );
    defer resp.deinit(testing.allocator);

    try testing.expect(resp.exception.len > 0);
}

test "dispatch: runtime throw leaves exception + partial response" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\throw new Error("boom");
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, resp.exception, "boom") != null);
}

test "dispatch: per-store isolation by passing different kv per run" {
    // Two independent stores, one dispatcher. The worker swaps the
    // tenant store per request; this test proves the dispatcher path
    // honors that.
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    const kv_a = try openTempKv(testing.allocator, &buf_a);
    const kv_b = try openTempKv(testing.allocator, &buf_b);
    defer {
        kv_a.close();
        kv_b.close();
        cleanupTempKv(&buf_a);
        cleanupTempKv(&buf_b);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var r1 = try runOne(
        &d,
        kv_a,
        \\kv.set("name", "alice");
        \\return "ok";
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer r1.deinit(testing.allocator);

    // kv_b never received the write.
    var r2 = try runOne(
        &d,
        kv_b,
        \\return String(kv.get("name"));
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer r2.deinit(testing.allocator);
    try testing.expectEqualStrings("null", r2.body);

    var r3 = try runOne(
        &d,
        kv_a,
        \\return kv.get("name");
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer r3.deinit(testing.allocator);
    try testing.expectEqualStrings("alice", r3.body);
}

test "dispatch: kv tape captures foreign gets only (§8 minimal read set)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    // Seed a key so the handler can observe both .ok and .not_found.
    try kv.put(uk("seeded"), "v1");

    // Tape-only test: seed value irrelevant (no Math.random/crypto in
    // the handler), timestamp 0 is fine.
    var readset = tape_mod.Readset.init(testing.allocator, 0, 0);
    defer readset.deinit();

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export function go() {
        \\    const v = kv.get("seeded");
        \\    const missing = kv.get("missing");
        \\    kv.set("new", v + "!");
        \\    kv.delete("seeded");
        \\    return String(missing);
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();

    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
        .method = "POST",
        .path = "/",
        .fn_override = "go",
        .trace = .{ .readset = &readset },
    }, &budget);
    defer resp.deinit(testing.allocator);

    // The read-taping contract (`docs/architecture/effects-and-handlers.md`,
    // readset replication): only foreign reads land on the
    // tape. The handler does two `kv.get`s (both foreign — writeset
    // is empty at both call sites), one `kv.set` (own-write, no
    // tape entry), one `kv.delete` (own-write, no tape entry).
    // Result: 2 tape entries, both `.get`. The kv.set/.delete are
    // outputs replay re-issues against its writeset overlay.
    try testing.expectEqual(@as(usize, 2), readset.kv.entries.items.len);

    const e0 = readset.kv.entries.items[0].kv;
    try testing.expectEqual(tape_mod.KvOp.get, e0.op);
    try testing.expectEqualStrings("_user/seeded", e0.key);
    try testing.expectEqualStrings("v1", e0.value);
    try testing.expectEqual(tape_mod.KvOutcome.ok, e0.outcome);

    const e1 = readset.kv.entries.items[1].kv;
    try testing.expectEqual(tape_mod.KvOp.get, e1.op);
    try testing.expectEqualStrings("_user/missing", e1.key);
    try testing.expectEqual(tape_mod.KvOutcome.not_found, e1.outcome);

    // Read-taping invariant: the writeset still records the writes so the
    // dispatch path can replicate + apply them. Tape minimization
    // is purely a capture-side compression.
    try testing.expectEqual(@as(usize, 2), ws.ops.items.len);
    // The WRITESET and the TAPE both hold resolved keys — the writeset rides
    // the raft entry, and the tape's read entries feed replay overlays
    // verbatim, so the two agree with the store by construction.
    try testing.expect(ws.containsKey(uk("new")));
    try testing.expect(ws.containsKey(uk("seeded")));
}

test "dispatch: kv tape skips own-reads (§8 minimal read set)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var readset = tape_mod.Readset.init(testing.allocator, 0, 0);
    defer readset.deinit();

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    // Handler writes a key, then reads it back. The read is an
    // OWN-read (the value lives in the activation's own writeset),
    // reproducible by replay re-running the handler against its
    // overlay — so no tape entry needed.
    const bytecode = try ctx.compileToBytecode(
        \\export function go() {
        \\    kv.set("own", "hello");
        \\    const v = kv.get("own");
        \\    return v;
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();

    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
        .method = "POST",
        .path = "/",
        .fn_override = "go",
        .trace = .{ .readset = &readset },
    }, &budget);
    defer resp.deinit(testing.allocator);

    // Tape carries ZERO entries: the kv.set is an output (not taped),
    // the kv.get reads from the writeset (own-read, not taped).
    try testing.expectEqual(@as(usize, 0), readset.kv.entries.items.len);
    try testing.expect(ws.containsKey(uk("own")));
}

test "dispatch: a batch-mate's write is a FOREIGN read for the next activation (rove#532)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export function first() {
        \\    kv.set("count", "1");
        \\    return "a";
        \\}
        \\export function second() {
        \\    const v = kv.get("count");
        \\    kv.set("count", "2");
        \\    return String(v);
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    // ONE txn + ONE writeset across both runs — the worker's batch shape
    // (several same-tenant activations share them; one raft `multi` entry).
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();

    var rs1 = tape_mod.Readset.init(testing.allocator, 0, 0);
    defer rs1.deinit();
    var budget1 = Budget.fromNow(Budget.default_duration_ns);
    var r1 = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
        .method = "POST",
        .path = "/",
        .fn_override = "first",
        .trace = .{ .readset = &rs1 },
    }, &budget1);
    defer r1.deinit(testing.allocator);

    var rs2 = tape_mod.Readset.init(testing.allocator, 0, 0);
    defer rs2.deinit();
    var budget2 = Budget.fromNow(Budget.default_duration_ns);
    var r2 = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
        .method = "POST",
        .path = "/",
        .fn_override = "second",
        .trace = .{ .readset = &rs2 },
    }, &budget2);
    defer r2.deinit(testing.allocator);

    // The second activation read the first's write through the shared txn.
    try testing.expectEqualStrings("1", r2.body);

    // Its record replays ALONE, so that read is FOREIGN and must be taped —
    // eliding it against the shared batch writeset left the record
    // unreplayable (rove#532: the value exists nowhere the replay can
    // reach; the host-side poison fires "read by the handler but not on
    // the capture tape").
    try testing.expectEqual(@as(usize, 1), rs2.kv.entries.items.len);
    const e = rs2.kv.entries.items[0].kv;
    try testing.expectEqual(tape_mod.KvOp.get, e.op);
    try testing.expectEqualStrings("_user/count", e.key);
    try testing.expectEqualStrings("1", e.value);
    try testing.expectEqual(tape_mod.KvOutcome.ok, e.outcome);

    // The first activation taped nothing (it only wrote), and the batch
    // writeset holds both activations' writes for replication.
    try testing.expectEqual(@as(usize, 0), rs1.kv.entries.items.len);
    try testing.expectEqual(@as(usize, 2), ws.ops.items.len);
}

test "dispatch: Date.now + Math.random + crypto.* are seed/timestamp-only" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    // §9 + fold-in: every non-deterministic source in the handler
    // is reduced to two scalars in the readset header.
    //  - `seed` → arenajs's per-context xorshift64star
    //  - `timestamp_ns` → arenajs's per-context `date_now_pinned`
    //    (Date.now() and new Date() (no args) return the same
    //    `@divTrunc(timestamp_ns, ns_per_ms)` for every call in
    //    one request, same posture as Cloudflare Workers /
    //    Lambda SnapStart)
    // No dedicated tape channels for any of them.
    const fixed_ts: i64 = 1_700_000_000_000_000_000; // arbitrary, in ns
    var readset = tape_mod.Readset.init(testing.allocator, fixed_ts, 42);
    defer readset.deinit();

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export function go() {
        \\    const t1 = Date.now();
        \\    const t2 = Date.now();
        \\    const t3 = (new Date()).getTime();
        \\    const r1 = Math.random();
        \\    const r2 = Math.random();
        \\    const buf = new Uint8Array(4);
        \\    crypto.getRandomValues(buf);
        \\    const id = crypto.randomUUID();
        \\    return String(t1) + "|" + t2 + "|" + t3 + "|" + r1 + "|" + r2 + "|" + id;
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var body_1: []u8 = &.{};
    defer if (body_1.len > 0) testing.allocator.free(body_1);
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();

        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
            .method = "GET",
            .path = "/",
            .fn_override = "go",
            .trace = .{ .readset = &readset },
        }, &budget);
        defer resp.deinit(testing.allocator);
        body_1 = try testing.allocator.dupe(u8, resp.body);
    }

    // Two scalars: ZERO tape entries on any random / date channel —
    // those channels don't exist.

    // Date.now is pinned. Both `Date.now()` calls AND
    // `(new Date()).getTime()` should return the same ms scalar
    // derived from `timestamp_ns`.
    const expected_ms = @divTrunc(fixed_ts, std.time.ns_per_ms);
    var ms_buf: [32]u8 = undefined;
    const expected_ms_s = try std.fmt.bufPrint(&ms_buf, "{d}", .{expected_ms});
    // Body is `{t1}|{t2}|{t3}|...`. Each of the three time slots
    // should be exactly the pinned ms string.
    var it = std.mem.splitScalar(u8, body_1, '|');
    const got_t1 = it.next().?;
    const got_t2 = it.next().?;
    const got_t3 = it.next().?;
    try testing.expectEqualStrings(expected_ms_s, got_t1);
    try testing.expectEqualStrings(expected_ms_s, got_t2);
    try testing.expectEqualStrings(expected_ms_s, got_t3);

    // Same seed + same timestamp → bit-identical output sequence
    // (no need to strip a prefix anymore — every field is now
    // deterministic).
    var readset2 = tape_mod.Readset.init(testing.allocator, fixed_ts, 42);
    defer readset2.deinit();

    var body_2: []u8 = &.{};
    defer if (body_2.len > 0) testing.allocator.free(body_2);
    {
        var txn2 = try kv.beginTrackedImmediate();
        defer txn2.rollback() catch {};
        var ws2 = kv_mod.WriteSet.init(testing.allocator);
        defer ws2.deinit();
        var budget2 = Budget.fromNow(Budget.default_duration_ns);
        var resp2 = try d.run(kv, &txn2, &ws2, bytecode, null, null, null, null, 0, .{
            .method = "GET",
            .path = "/",
            .fn_override = "go",
            .trace = .{ .readset = &readset2 },
        }, &budget2);
        defer resp2.deinit(testing.allocator);
        body_2 = try testing.allocator.dupe(u8, resp2.body);
    }

    try testing.expectEqualStrings(body_1, body_2);
}

test "dispatch: tight loop hits budget and returns Interrupted" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    // Compile a handler that runs forever.
    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        "export function go() { while (true) {} }",
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();

    // 5ms budget so the test is fast but the interrupt handler has
    // plenty of ticks to observe.
    var budget = Budget.fromNow(5 * std.time.ns_per_ms);
    const started: i64 = @intCast(std.time.nanoTimestamp());
    const result = d.run(
        kv,
        &txn,
        &ws,
        bytecode,
        null,
        null,
        null,
        null,
        0,
        .{ .method = "GET", .path = "/", .fn_override = "go" },
        &budget,
    );
    const elapsed_ns: i64 = @as(i64, @intCast(std.time.nanoTimestamp())) - started;

    try testing.expectError(DispatchError.Interrupted, result);
    try testing.expect(budget.tick_count > 0);
    // Should not run much longer than the budget — generous ceiling for
    // CI jitter.
    try testing.expect(elapsed_ns < 500 * std.time.ns_per_ms);
}

test "dispatch: short handler does not trip budget" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\return "fast";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("fast", resp.body);
}

test "dispatch: .mjs module + internal fn_override dispatch" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    // Compile a tiny module with two exports plus a default that
    // proves customer envelope shapes don't route (the platform
    // invokes only the conventional export when nothing overrides).
    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export function greet() {
        \\    return "hi " + request.path;
        \\}
        \\export function shout() {
        \\    response.status = 201;
        \\    return ("HI " + request.path).toUpperCase();
        \\}
        \\export default function () {
        \\    return "default-ran";
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // fn_override=greet reads request.path → "hi /hello", status 200.
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
            .method = "GET",
            .path = "/hello",
            .fn_override = "greet",
        }, &budget);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 200), resp.status);
        try testing.expectEqualStrings("hi /hello", resp.body);
    }

    // fn_override=shout → "HI /HELLO", status 201 via response global.
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
            .method = "GET",
            .path = "/hello",
            .fn_override = "shout",
        }, &budget);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 201), resp.status);
        try testing.expectEqualStrings("HI /HELLO", resp.body);
    }

    // Unknown override → 404 with a descriptive body.
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
            .method = "GET",
            .path = "/hello",
            .fn_override = "nope",
        }, &budget);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 404), resp.status);
        try testing.expect(std.mem.indexOf(u8, resp.body, "nope") != null);
    }

    // The customer envelope shapes are inert: a `?fn=` query
    // and a `{fn,args}` body both land in the DEFAULT export.
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
            .method = "POST",
            .path = "/hello",
            .query = "fn=shout&args=%5B%22x%22%5D",
            .body = "{\"fn\":\"greet\",\"args\":[\"x\"]}",
        }, &budget);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 200), resp.status);
        try testing.expectEqualStrings("default-ran", resp.body);
    }
}

// Helper: drive a dispatch where a `_middlewares/index.mjs` is
// present alongside the handler. Bytecodes share the per-tenant
// StringHashMap shape the worker uses in production.
fn runWithMiddleware(
    d: *Dispatcher,
    kv: *kv_mod.KvStore,
    handler_body: []const u8,
    middleware_src: []const u8,
    request_in: Request,
) !Response {
    const wrapped = try std.fmt.allocPrint(testing.allocator, "export function go() {{ {s} }}\n", .{handler_body});
    defer testing.allocator.free(wrapped);

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    const handler_bc = try ctx.compileToBytecode(wrapped, "h.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);
    const mw_bc = try ctx.compileToBytecode(middleware_src, "_middlewares/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(mw_bc);

    var bytecodes: std.StringHashMapUnmanaged(*BlobBytes) = .empty;
    defer deinitTestBytecodes(&bytecodes);
    try putTestBytecode(&bytecodes, "_middlewares/index.mjs", mw_bc);

    var txn = try kv.beginTrackedImmediate();
    errdefer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();

    var request = request_in;
    if (request.fn_override == null) request.fn_override = "go";

    var budget = Budget.fromNow(Budget.default_duration_ns);
    const resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, null, null, 0, request, &budget);
    try txn.commit();
    return resp;
}

test "dispatch: middleware that returns undefined → handler runs" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runWithMiddleware(
        &d,
        kv,
        \\return "handler-ran";
    ,
        \\export function before() {
        \\    // implicit undefined → continue
        \\}
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("handler-ran", resp.body);
}

test "dispatch: middleware receives the activation object" {
    // The WORKER's middleware call arity, which nothing covered. Both
    // `_middlewares` fixtures under src/replay/testdata are capability-free,
    // and those run on the sim/replay driver anyway — so when
    // `runMiddleware` still called `before` with zero arguments, a tenant
    // whose middleware destructured `kv` threw on every request and the gate
    // stayed green. Destructure a capability here, or this test cannot fail
    // for the reason it exists.
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runWithMiddleware(
        &d,
        kv,
        \\return "ok:" + request.auth.seen;
    ,
        \\export function before({ kv }) {
        \\    kv.set("mw/seen", "yes");
        \\    request.auth = { seen: kv.get("mw/seen") };
        \\}
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("ok:yes", resp.body);
}

test "dispatch: middleware mutation of request.auth flows to handler" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runWithMiddleware(
        &d,
        kv,
        \\return "is_root=" + (request.auth && request.auth.is_root ? "yes" : "no");
    ,
        \\export function before() {
        \\    request.auth = { is_root: true };
        \\}
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("is_root=yes", resp.body);
}

test "dispatch: middleware short-circuits with response when before returns a value" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runWithMiddleware(
        &d,
        kv,
        \\return "handler-ran";
    ,
        \\export function before() {
        \\    response.status = 401;
        \\    return { error: "no" };
        \\}
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 401), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"no\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "handler-ran") == null);
}

test "dispatch: middleware throw surfaces as 500 with exception" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runWithMiddleware(
        &d,
        kv,
        \\return "should-not-run";
    ,
        \\export function before() { throw new Error("nope"); }
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, resp.exception, "nope") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "should-not-run") == null);
}

test "dispatch: middleware without `before` export → 500" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Module exports something else, not `before`. Operator-visible 500
    // rather than silent skip.
    var resp = try runWithMiddleware(
        &d,
        kv,
        \\return "handler-ran";
    ,
        \\export function notBefore() { return "wrong"; }
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 500), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "before") != null);
}

test "dispatch: middleware applies to fn_override named-export dispatch too" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Important property: middleware fires before *any* dispatch,
    // including the internal named-export (fn_override) resume path.
    // Without this admin's named-export resumes would bypass the auth
    // gate entirely.
    var resp = try runWithMiddleware(
        &d,
        kv,
        \\return "handler-ran";
    ,
        \\export function before() {
        \\    response.status = 401;
        \\    return { error: "blocked" };
        \\}
    ,
        .{ .method = "GET", .path = "/", .fn_override = "go" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 401), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"blocked\"") != null);
}

test "dispatch: missing fn defaults to `default` export, called with no args" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export default function () {
        \\    return "hi from default at " + request.path;
        \\}
        \\export function other() {
        \\    return "should not be called";
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // GET with no query at all → default export, no args.
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
            .method = "GET",
            .path = "/landing",
        }, &budget);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 200), resp.status);
        try testing.expectEqualStrings("hi from default at /landing", resp.body);
    }

    // GET with query that has no fn= → still default.
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
            .method = "GET",
            .path = "/x",
            .query = "page=2&sort=desc",
        }, &budget);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 200), resp.status);
        try testing.expectEqualStrings("hi from default at /x", resp.body);
    }
}

test "dispatch: no fn and no default export → 404" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export function only_named() { return "x"; }
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 404), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "default") != null);
}

test "dispatch: POST with non-envelope JSON body invokes default, body in request.body" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export default function () {
        \\    const parsed = request.json;
        \\    return "got name=" + parsed.name;
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
        .method = "POST",
        .path = "/",
        .body = "{\"name\":\"alice\"}",
    }, &budget);
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 200), resp.status);
    try testing.expectEqualStrings("got name=alice", resp.body);
}

test "dispatch: a {fn,args} POST body is opaque payload — default export runs" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export function greet(who) {
        \\    return "hi " + who;
        \\}
        \\export default function () {
        \\    // The retired envelope is just a body now — visible,
        \\    // never interpreted (decisions.md §4.5).
        \\    return "default saw " + request.json.fn;
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
        .method = "POST",
        .path = "/",
        .body = "{\"fn\":\"greet\",\"args\":[\"world\"]}",
    }, &budget);
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 200), resp.status);
    try testing.expectEqualStrings("default saw greet", resp.body);
}

// ── request.headers + request.cookies ─────────────────────────────────

/// Build a fake ReqHeaders from a slice of (name, value) pairs.
/// The strings are borrowed — caller keeps them alive for the test.
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

test "dispatch: request.headers exposes named headers, filters pseudo-headers" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export default function () {
        \\    const h = request.headers;
        \\    return JSON.stringify({
        \\        ua: h["user-agent"] ?? null,
        \\        sig: h["x-slack-signature"] ?? null,
        \\        method_pseudo: h[":method"] ?? null,
        \\        path_pseudo: h[":path"] ?? null,
        \\    });
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var hdr_buf: [8]h2.HeaderField = undefined;
    const hdrs = makeReqHeaders(&hdr_buf, &.{
        .{ ":method", "GET" },
        .{ ":path", "/" },
        .{ "user-agent", "smoke/1" },
        .{ "x-slack-signature", "v0=abc" },
    });

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
        .method = "GET",
        .path = "/",
        .headers = hdrs,
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    try testing.expectEqualStrings(
        "{\"ua\":\"smoke/1\",\"sig\":\"v0=abc\",\"method_pseudo\":null,\"path_pseudo\":null}",
        resp.body,
    );
}

test "dispatch: request.headers missing → empty object, missing key → undefined" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export default function () {
        \\    const h = request.headers;
        \\    return JSON.stringify({
        \\        type: typeof h,
        \\        keys: Object.keys(h).length,
        \\        missing: h["x-not-set"] === undefined,
        \\    });
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    // No headers field — exercises the null path.
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    try testing.expectEqualStrings(
        "{\"type\":\"object\",\"keys\":0,\"missing\":true}",
        resp.body,
    );
}

// ── read-taped request surface (`request_reads` channel) ─────────────

/// Count `request_reads` entries matching (kind, name).
fn countReads(rs: *const tape_mod.Readset, kind: tape_mod.RequestReadKind, name: []const u8) usize {
    var n: usize = 0;
    for (rs.request_reads.entries.items) |e| {
        const r = e.request_reads;
        if (r.kind == kind and std.mem.eql(u8, r.name, name)) n += 1;
    }
    return n;
}

/// The recorded value for the FIRST `request_reads` entry matching
/// (kind, name), or null.
fn readValue(rs: *const tape_mod.Readset, kind: tape_mod.RequestReadKind, name: []const u8) ?[]const u8 {
    for (rs.request_reads.entries.items) |e| {
        const r = e.request_reads;
        if (r.kind == kind and std.mem.eql(u8, r.name, name)) return r.value;
    }
    return null;
}

test "dispatch: request_reads — values recorded only on read, repeat reads dedupe" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export default function () {
        \\    // Read ONE header, three times. x-slack-signature stays unread.
        \\    const a = request.headers["user-agent"];
        \\    const b = request.headers["user-agent"];
        \\    const c = request.headers["user-agent"];
        \\    return a + b + c;
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var hdr_buf: [8]h2.HeaderField = undefined;
    const hdrs = makeReqHeaders(&hdr_buf, &.{
        .{ ":method", "GET" },
        .{ "user-agent", "smoke/1" },
        .{ "x-slack-signature", "v0=abc" },
    });

    var readset = tape_mod.Readset.init(testing.allocator, 0, 0);
    defer readset.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
        .method = "GET",
        .path = "/",
        .headers = hdrs,
        .trace = .{ .readset = &readset },
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    // The names list is recorded once, eagerly, with all non-pseudo
    // names in wire order; values only for what was read — and only
    // once despite three reads.
    try testing.expectEqual(@as(usize, 1), countReads(&readset, .header_names, ""));
    try testing.expectEqualStrings(
        "[\"user-agent\",\"x-slack-signature\"]",
        readValue(&readset, .header_names, "").?,
    );
    try testing.expectEqual(@as(usize, 1), countReads(&readset, .header_value, "user-agent"));
    try testing.expectEqualStrings("smoke/1", readValue(&readset, .header_value, "user-agent").?);
    try testing.expectEqual(@as(usize, 0), countReads(&readset, .header_value, "x-slack-signature"));
}

test "dispatch: request_reads — Object.keys records no values, JSON.stringify records all" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var hdr_buf: [8]h2.HeaderField = undefined;
    const hdrs = makeReqHeaders(&hdr_buf, &.{
        .{ "user-agent", "smoke/1" },
        .{ "accept", "*/*" },
    });

    // Object.keys: observes the name SET, fires no getters.
    {
        const bytecode = try ctx.compileToBytecode(
            \\export default function () {
            \\    return Object.keys(request.headers).join(",");
            \\}
        ,
            "h.mjs",
            testing.allocator,
            .{ .kind = .module },
        );
        defer testing.allocator.free(bytecode);

        var readset = tape_mod.Readset.init(testing.allocator, 0, 0);
        defer readset.deinit();
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
            .method = "GET",
            .path = "/",
            .headers = hdrs,
            .trace = .{ .readset = &readset },
        }, &budget);
        defer resp.deinit(testing.allocator);

        try testing.expectEqualStrings("user-agent,accept", resp.body);
        try testing.expectEqual(@as(usize, 1), countReads(&readset, .header_names, ""));
        try testing.expectEqual(@as(usize, 0), countReads(&readset, .header_value, "user-agent"));
        try testing.expectEqual(@as(usize, 0), countReads(&readset, .header_value, "accept"));
    }

    // JSON.stringify: fires every getter — every value records,
    // which is exactly right (the handler really did read them all).
    {
        const bytecode = try ctx.compileToBytecode(
            \\export default function () {
            \\    return JSON.stringify(request.headers);
            \\}
        ,
            "h.mjs",
            testing.allocator,
            .{ .kind = .module },
        );
        defer testing.allocator.free(bytecode);

        var readset = tape_mod.Readset.init(testing.allocator, 0, 0);
        defer readset.deinit();
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
            .method = "GET",
            .path = "/",
            .headers = hdrs,
            .trace = .{ .readset = &readset },
        }, &budget);
        defer resp.deinit(testing.allocator);

        try testing.expectEqual(@as(usize, 1), countReads(&readset, .header_value, "user-agent"));
        try testing.expectEqual(@as(usize, 1), countReads(&readset, .header_value, "accept"));
    }
}

test "dispatch: request_reads — cookies access records the whole cookie header once" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export default function () {
        \\    const c1 = request.cookies;
        \\    const c2 = request.cookies;
        \\    return JSON.stringify({
        \\        sid: c1.sid,
        \\        theme: c1.theme,
        \\        same: c1 === c2,
        \\    });
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var hdr_buf: [4]h2.HeaderField = undefined;
    const hdrs = makeReqHeaders(&hdr_buf, &.{
        .{ "cookie", "sid=abc; theme=dark" },
    });

    var readset = tape_mod.Readset.init(testing.allocator, 0, 0);
    defer readset.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
        .method = "GET",
        .path = "/",
        .headers = hdrs,
        .trace = .{ .readset = &readset },
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "{\"sid\":\"abc\",\"theme\":\"dark\",\"same\":true}",
        resp.body,
    );
    // One header_value{cookie} entry: the cookies access IS a cookie-
    // header read; the self-replaced object makes the second access
    // free (and identity-stable).
    try testing.expectEqual(@as(usize, 1), countReads(&readset, .header_value, "cookie"));
    try testing.expectEqualStrings(
        "sid=abc; theme=dark",
        readValue(&readset, .header_value, "cookie").?,
    );
}

test "dispatch: request_reads — body flag set on read (incl. empty body), absent when unread" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Reads the body (non-empty).
    {
        const bytecode = try ctx.compileToBytecode(
            \\export default function () { return "len=" + request.text.length; }
        ,
            "h.mjs",
            testing.allocator,
            .{ .kind = .module },
        );
        defer testing.allocator.free(bytecode);

        var readset = tape_mod.Readset.init(testing.allocator, 0, 0);
        defer readset.deinit();
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
            .method = "POST",
            .path = "/",
            .body = "hello",
            .trace = .{ .readset = &readset },
        }, &budget);
        defer resp.deinit(testing.allocator);

        try testing.expectEqualStrings("len=5", resp.body);
        try testing.expect(readset.body_read);
        try testing.expectEqual(@as(usize, 1), countReads(&readset, .body_read, ""));
    }

    // Reads an EMPTY body — still a recorded fact ("read an empty
    // body" vs "never looked" are different replay inputs).
    {
        const bytecode = try ctx.compileToBytecode(
            \\export default function () { return "len=" + request.text.length; }
        ,
            "h.mjs",
            testing.allocator,
            .{ .kind = .module },
        );
        defer testing.allocator.free(bytecode);

        var readset = tape_mod.Readset.init(testing.allocator, 0, 0);
        defer readset.deinit();
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
            .method = "GET",
            .path = "/",
            .trace = .{ .readset = &readset },
        }, &budget);
        defer resp.deinit(testing.allocator);

        try testing.expectEqualStrings("len=0", resp.body);
        try testing.expect(readset.body_read);
    }

    // Never touches the body — flag stays false, nothing recorded,
    // and elideUnreadBody drops any trigger_payload reference.
    {
        const bytecode = try ctx.compileToBytecode(
            \\export default function () { return "no-body-read"; }
        ,
            "h.mjs",
            testing.allocator,
            .{ .kind = .module },
        );
        defer testing.allocator.free(bytecode);

        var readset = tape_mod.Readset.init(testing.allocator, 0, 0);
        defer readset.deinit();
        try readset.trigger_payload.appendTriggerPayload(
            bodies_mod.BodyRef.carried(5),
            "hello",
        );
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
            .method = "POST",
            .path = "/",
            .body = "hello",
            .trace = .{ .readset = &readset },
        }, &budget);
        defer resp.deinit(testing.allocator);

        try testing.expect(!readset.body_read);
        try testing.expectEqual(@as(usize, 0), countReads(&readset, .body_read, ""));
        readset.elideUnreadBody();
        try testing.expectEqual(@as(usize, 0), readset.trigger_payload.entries.items.len);
    }
}

test "dispatch: request.ip masked, unmaskedIp() raw, IP transport headers stripped" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export default function () {
        \\    return JSON.stringify({
        \\        ip: request.ip,
        \\        raw: arguments[0].unmaskedIp(),
        \\        xff: request.headers["x-forwarded-for"] === undefined,
        \\        keys: Object.keys(request.headers).join(","),
        \\    });
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Spoof-shaped XFF: client-sent junk on the left, the edge-
    // appended (trusted) entry rightmost.
    var hdr_buf: [8]h2.HeaderField = undefined;
    const hdrs = makeReqHeaders(&hdr_buf, &.{
        .{ "user-agent", "smoke/1" },
        .{ "x-forwarded-for", "198.51.100.7, 203.0.113.9" },
        .{ "x-real-ip", "203.0.113.9" },
        .{ "forwarded", "for=203.0.113.9" },
    });

    var readset = tape_mod.Readset.init(testing.allocator, 0, 0);
    defer readset.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
        .method = "GET",
        .path = "/",
        .headers = hdrs,
        .trace = .{ .readset = &readset },
    }, &budget);
    defer resp.deinit(testing.allocator);

    // Masked = rightmost XFF entry with the last octet zeroed; raw =
    // the rightmost entry verbatim; the transport headers themselves
    // are invisible (stripped from both the object and the name set).
    try testing.expectEqualStrings(
        "{\"ip\":\"203.0.113.0\",\"raw\":\"203.0.113.9\",\"xff\":true,\"keys\":\"user-agent\"}",
        resp.body,
    );
    try testing.expectEqualStrings("203.0.113.0", readValue(&readset, .ip_masked, "").?);
    try testing.expectEqualStrings("203.0.113.9", readValue(&readset, .ip_raw, "").?);
    try testing.expectEqualStrings("[\"user-agent\"]", readValue(&readset, .header_names, "").?);
}

test "dispatch: request.ip prefers cf-connecting-ip; IPv6 masks to /48; absent → null" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // cf-connecting-ip (IPv6) wins over XFF; /48 mask.
    {
        const bytecode = try ctx.compileToBytecode(
            \\export default function () {
            \\    return request.ip + "|" + arguments[0].unmaskedIp();
            \\}
        ,
            "h.mjs",
            testing.allocator,
            .{ .kind = .module },
        );
        defer testing.allocator.free(bytecode);

        var hdr_buf: [4]h2.HeaderField = undefined;
        const hdrs = makeReqHeaders(&hdr_buf, &.{
            .{ "cf-connecting-ip", "2001:db8:85a3:8d3:1319:8a2e:370:7348" },
            .{ "x-forwarded-for", "203.0.113.9" },
        });

        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
            .method = "GET",
            .path = "/",
            .headers = hdrs,
        }, &budget);
        defer resp.deinit(testing.allocator);

        try testing.expectEqualStrings(
            "2001:db8:85a3::|2001:db8:85a3:8d3:1319:8a2e:370:7348",
            resp.body,
        );
    }

    // No IP transport headers at all → both surfaces null, and the
    // null read is itself recorded (replay must reproduce it).
    {
        const bytecode = try ctx.compileToBytecode(
            \\export default function () {
            \\    return JSON.stringify({ ip: request.ip, raw: arguments[0].unmaskedIp() });
            \\}
        ,
            "h.mjs",
            testing.allocator,
            .{ .kind = .module },
        );
        defer testing.allocator.free(bytecode);

        var hdr_buf: [2]h2.HeaderField = undefined;
        const hdrs = makeReqHeaders(&hdr_buf, &.{
            .{ "user-agent", "smoke/1" },
        });

        var readset = tape_mod.Readset.init(testing.allocator, 0, 0);
        defer readset.deinit();
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
            .method = "GET",
            .path = "/",
            .headers = hdrs,
            .trace = .{ .readset = &readset },
        }, &budget);
        defer resp.deinit(testing.allocator);

        try testing.expectEqualStrings("{\"ip\":null,\"raw\":null}", resp.body);
        try testing.expectEqualStrings("", readValue(&readset, .ip_masked, "").?);
        try testing.expectEqualStrings("", readValue(&readset, .ip_raw, "").?);
    }
}

test "dispatch: duplicate header names — last value wins through the getters" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export default function () {
        \\    return request.headers["x-dup"] + "|" + Object.keys(request.headers).join(",");
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var hdr_buf: [4]h2.HeaderField = undefined;
    const hdrs = makeReqHeaders(&hdr_buf, &.{
        .{ "x-dup", "first" },
        .{ "accept", "*/*" },
        .{ "x-dup", "second" },
    });

    var readset = tape_mod.Readset.init(testing.allocator, 0, 0);
    defer readset.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
        .method = "GET",
        .path = "/",
        .headers = hdrs,
        .trace = .{ .readset = &readset },
    }, &budget);
    defer resp.deinit(testing.allocator);

    // Last value wins; enumeration keeps the FIRST occurrence's slot;
    // the names list is deduped the same way.
    try testing.expectEqualStrings("second|x-dup,accept", resp.body);
    try testing.expectEqualStrings("second", readValue(&readset, .header_value, "x-dup").?);
    try testing.expectEqualStrings("[\"x-dup\",\"accept\"]", readValue(&readset, .header_names, "").?);
}

test "dispatch: request.cookies parses RFC 6265 cookie header" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export default function () {
        \\    const c = request.cookies;
        \\    return JSON.stringify({
        \\        sess: c["sid"] ?? null,
        \\        ab: c["ab"] ?? null,
        \\        missing: c["nope"] ?? null,
        \\    });
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var hdr_buf: [4]h2.HeaderField = undefined;
    const hdrs = makeReqHeaders(&hdr_buf, &.{
        .{ "cookie", "sid=abc123; ab=  spaced  ; bare" },
    });

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
        .method = "GET",
        .path = "/",
        .headers = hdrs,
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    // `bare` (no `=`) is dropped; whitespace around the value is
    // trimmed (matches browser / Express / Hono cookie parsers).
    try testing.expectEqualStrings(
        "{\"sess\":\"abc123\",\"ab\":\"spaced\",\"missing\":null}",
        resp.body,
    );
}

test "dispatch: request.cookies empty when no cookie header" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export default function () {
        \\    return JSON.stringify({
        \\        type: typeof request.cookies,
        \\        keys: Object.keys(request.cookies).length,
        \\    });
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var hdr_buf: [4]h2.HeaderField = undefined;
    const hdrs = makeReqHeaders(&hdr_buf, &.{
        .{ "user-agent", "smoke/1" },
    });

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
        .method = "GET",
        .path = "/",
        .headers = hdrs,
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    try testing.expectEqualStrings(
        "{\"type\":\"object\",\"keys\":0}",
        resp.body,
    );
}

test "dispatch: async module handler gets unwrapped" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export async function fetchLike() {
        \\    const v = await Promise.resolve("async " + request.path);
        \\    response.status = 202;
        \\    return v;
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, null, 0, .{
        .method = "GET",
        .path = "/x",
        .fn_override = "fetchLike",
    }, &budget);
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 202), resp.status);
    try testing.expectEqualStrings("async /x", resp.body);
}

test "dispatch: request object fields populated" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\return request.method + " " + request.path + " " + request.text;
    ,
        .{ .method = "PUT", .path = "/x", .body = "payload" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("PUT /x payload", resp.body);
}

test "dispatch: request.query exposes raw query string" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // The query string is opaque payload — `runOne` dispatches via
    // fn_override, not the query. We check the full query round-trips
    // verbatim to `request.query`.
    var resp = try runOne(
        &d,
        kv,
        \\return String(request.query);
    ,
        .{ .method = "GET", .path = "/", .query = "q=go&name=alice&tags=x%20y" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("q=go&name=alice&tags=x%20y", resp.body);
}

test "dispatch: webhook.send (JS shim) writes _send/owed/{id} markers" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // webhook.send is the JS-shim composition (`globals/webhook.js`).
    // Each writes a JSON `_send/owed/{id}` marker the baked
    // `__system/webhook_fire` / `webhook_onresult` modules read
    // (deferred fires ride the durable scheduler).
    var resp = try runOne(
        &d,
        kv,
        \\const id1 = webhook.send("https://example.test/a", {
        \\  body: "one",
        \\  on: "cb/a",
        \\  ctx: { x: 1 },
        \\});
        \\const id2 = webhook.send("https://example.test/b", {
        \\  method: "GET",
        \\});
        \\return id1 + "|" + id2;
    ,
        .{ .method = "GET", .path = "/hook", .trace = .{ .request_id = 0xdeadbeef } },
    );
    defer resp.deinit(testing.allocator);

    const sep = std.mem.indexOfScalar(u8, resp.body, '|').?;
    const id1 = resp.body[0..sep];
    const id2 = resp.body[sep + 1 ..];

    const m1_raw = try readOwedMarker(kv, id1);
    defer testing.allocator.free(m1_raw);
    var p1 = try std.json.parseFromSlice(std.json.Value, testing.allocator, m1_raw, .{});
    defer p1.deinit();
    const o1 = p1.value.object;
    try testing.expectEqualStrings("https://example.test/a", o1.get("url").?.string);
    try testing.expectEqualStrings("POST", o1.get("method").?.string);
    try testing.expectEqualStrings("one", o1.get("body").?.string);
    try testing.expectEqualStrings("cb/a", o1.get("on_result").?.string);
    const ctx_obj = o1.get("context").?.object;
    try testing.expectEqual(@as(i64, 1), ctx_obj.get("x").?.integer);

    const m2_raw = try readOwedMarker(kv, id2);
    defer testing.allocator.free(m2_raw);
    var p2 = try std.json.parseFromSlice(std.json.Value, testing.allocator, m2_raw, .{});
    defer p2.deinit();
    const o2 = p2.value.object;
    try testing.expectEqualStrings("https://example.test/b", o2.get("url").?.string);
    try testing.expectEqualStrings("GET", o2.get("method").?.string);
}

test "dispatch: webhook.send rejects missing url" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\try {
        \\  webhook.send();
        \\  return "ok";
        \\} catch (e) {
        \\  return "threw:" + e.message;
        \\}
    ,
        .{ .method = "GET", .path = "/", .trace = .{ .request_id = 1 } },
    );
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, resp.body, "threw:"));
}

test "dispatch: btoa + atob round-trip" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\const enc = btoa("hello world");
        \\const dec = atob(enc);
        \\return enc + "|" + dec;
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("aGVsbG8gd29ybGQ=|hello world", resp.body);
}

test "dispatch: base64url round-trip + RFC test vector" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // RFC 4648 §10 test vectors:
    //   "f"      → "Zg"     (no padding)
    //   "fo"     → "Zm8"
    //   "foo"    → "Zm9v"
    //   "foob"   → "Zm9vYg"
    //   "fooba"  → "Zm9vYmE"
    //   "foobar" → "Zm9vYmFy"
    var resp = try runOne(&d, kv,
        \\const cases = ["f","fo","foo","foob","fooba","foobar"];
        \\const out = cases.map(s => base64url.encode(new TextEncoder().encode(s)));
        \\return out.join("|");
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("Zg|Zm8|Zm9v|Zm9vYg|Zm9vYmE|Zm9vYmFy", resp.body);
}

test "dispatch: base64url decode handles padded + URL-safe input" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        // "test_+/=" round-trips through both alphabets — input is
        // standard with padding, decode tolerates it.
        \\const bytes = base64url.decode("Zm9v");
        \\const text = new TextDecoder().decode(bytes);
        \\return text;
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("foo", resp.body);
}

test "dispatch: hex round-trip" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\const bytes = new Uint8Array([0xde, 0xad, 0xbe, 0xef]);
        \\const enc = hex.encode(bytes);
        \\const dec = hex.decode(enc);
        \\return enc + "|" + (dec[0] === 0xde && dec[3] === 0xef);
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("deadbeef|true", resp.body);
}

test "dispatch: URLSearchParams parse + read" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\const p = new URLSearchParams("?code=abc&state=xyz&scope=read+write");
        \\return p.get("code") + "|" + p.get("scope") + "|" + p.has("missing");
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("abc|read write|false", resp.body);
}

test "dispatch: URLSearchParams build + toString round-trip" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\const p = new URLSearchParams();
        \\p.set("client_id", "abc 123");
        \\p.set("scope", "read");
        \\p.append("scope", "write");
        \\return p.toString();
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    // 'set' replaces all existing entries with the same name (so
    // first scope=read becomes the lone scope), then append adds
    // scope=write after it.
    try testing.expectEqualStrings("client_id=abc+123&scope=read&scope=write", resp.body);
}

test "dispatch: URLSearchParams getAll for repeated keys" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\const p = new URLSearchParams("scope=a&scope=b&scope=c");
        \\return p.getAll("scope").join(",");
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("a,b,c", resp.body);
}

test "dispatch: crypto.verifyRsa accepts RFC 7515 §A.2 RS256 test vector" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // RFC 7515 Appendix A.2 — "Example JWS Using RSASSA-PKCS1-v1_5
    // SHA-256". Public key JWK + JWS signing input + signature, all
    // base64url-encoded as the RFC publishes them.
    var resp = try runOne(&d, kv,
        \\const jwk = {
        \\  kty: "RSA",
        \\  n: "ofgWCuLjybRlzo0tZWJjNiuSfb4p4fAkd_wWJcyQoTbji9k0l8W26mPddxHmfHQp-Vaw-4qPCJrcS2mJPMEzP1Pt0Bm4d4QlL-yRT-SFd2lZS-pCgNMsD1W_YpRPEwOWvG6b32690r2jZ47soMZo9wGzjb_7OMg0LOL-bSf63kpaSHSXndS5z5rexMdbBYUsLA9e-KXBdQOS-UTo7WTBEMa2R2CapHg665xsmtdVMTBQY4uDZlxvb3qCo5ZwKh9kG4LT6_I5IhlJH7aGhyxXFvUK-DWNmoudF8NAco9_h9iaGNj8q2ethFkMLs91kzk2PAcDTW9gb54h4FRWyuXpoQ",
        \\  e: "AQAB",
        \\};
        \\const signing_input = "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ";
        \\const sig_b64 = "cC4hiUPoj9Eetdgtv3hF80EGrhuB__dzERat0XF9g2VtQgr9PJbu3XOiZj5RZmh7AAuHIm4Bh-0Qc_lF5YKt_O8W2Fp5jujGbds9uJdbF9CUAr7t1dnZcAcQjbKBYNX4BAynRFdiuB--f_nZLgrnbyTyWzO75vRK5h6xBArLIARNPvkSjtQBMHlb1L07Qe7K0GarZRmB_eSN9383LcOLn6_dO--xi12jzDwusC-eOkHWEsqtFZESc6BfI7noOPqvhJ1phCnvWh6IeYI2w9QOYEUipUTI8np6LbgGY9Fs98rqVt5AXLIhWkWywlVmtVrBp0igcN_IoypGlUPQGe77Rw";
        \\const data = new TextEncoder().encode(signing_input);
        \\const sig = base64url.decode(sig_b64);
        \\return String(crypto.verifyRsa(jwk, "sha256", data, sig));
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("true", resp.body);
}

test "dispatch: crypto.verifyRsa rejects tampered signature" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\const jwk = {
        \\  kty: "RSA",
        \\  n: "ofgWCuLjybRlzo0tZWJjNiuSfb4p4fAkd_wWJcyQoTbji9k0l8W26mPddxHmfHQp-Vaw-4qPCJrcS2mJPMEzP1Pt0Bm4d4QlL-yRT-SFd2lZS-pCgNMsD1W_YpRPEwOWvG6b32690r2jZ47soMZo9wGzjb_7OMg0LOL-bSf63kpaSHSXndS5z5rexMdbBYUsLA9e-KXBdQOS-UTo7WTBEMa2R2CapHg665xsmtdVMTBQY4uDZlxvb3qCo5ZwKh9kG4LT6_I5IhlJH7aGhyxXFvUK-DWNmoudF8NAco9_h9iaGNj8q2ethFkMLs91kzk2PAcDTW9gb54h4FRWyuXpoQ",
        \\  e: "AQAB",
        \\};
        \\// Same signing input + signature, but flip a payload byte:
        \\const signing_input = "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJtYWxsb3J5LA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ";
        \\const sig_b64 = "cC4hiUPoj9Eetdgtv3hF80EGrhuB__dzERat0XF9g2VtQgr9PJbu3XOiZj5RZmh7AAuHIm4Bh-0Qc_lF5YKt_O8W2Fp5jujGbds9uJdbF9CUAr7t1dnZcAcQjbKBYNX4BAynRFdiuB--f_nZLgrnbyTyWzO75vRK5h6xBArLIARNPvkSjtQBMHlb1L07Qe7K0GarZRmB_eSN9383LcOLn6_dO--xi12jzDwusC-eOkHWEsqtFZESc6BfI7noOPqvhJ1phCnvWh6IeYI2w9QOYEUipUTI8np6LbgGY9Fs98rqVt5AXLIhWkWywlVmtVrBp0igcN_IoypGlUPQGe77Rw";
        \\const data = new TextEncoder().encode(signing_input);
        \\const sig = base64url.decode(sig_b64);
        \\return String(crypto.verifyRsa(jwk, "sha256", data, sig));
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("false", resp.body);
}

test "dispatch: crypto.verifyRsa rejects missing jwk.n / wrong kty" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\const data = new TextEncoder().encode("hi");
        \\const sig = new Uint8Array(0);
        \\const tries = [
        \\  () => crypto.verifyRsa({ kty: "EC", n: "x", e: "y" }, "sha256", data, sig),
        \\  () => crypto.verifyRsa({ kty: "RSA" }, "sha256", data, sig),
        \\  () => crypto.verifyRsa({ kty: "RSA", n: "x", e: "y" }, "md5", data, sig),
        \\];
        \\const out = tries.map(fn => { try { fn(); return "ok"; } catch (e) { return "threw"; } });
        \\return out.join(",");
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("threw,threw,threw", resp.body);
}

test "dispatch: crypto.verifyEcdsa accepts RFC 7515 §A.3 ES256 test vector" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // RFC 7515 Appendix A.3 — "Example JWS Using ECDSA P-256 SHA-256".
    // JWK + signing input + 64-byte raw R||S signature, all base64url
    // as the RFC publishes them.
    var resp = try runOne(&d, kv,
        \\const jwk = {
        \\  kty: "EC",
        \\  crv: "P-256",
        \\  x: "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU",
        \\  y: "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0",
        \\};
        \\const signing_input = "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ";
        \\const sig_b64 = "DtEhU3ljbEg8L38VWAfUAqOyKAM6-Xx-F4GawxaepmXFCgfTjDxw5djxLa8ISlSApmWQxfKTUJqPP3-Kg6NU1Q";
        \\const data = new TextEncoder().encode(signing_input);
        \\const sig = base64url.decode(sig_b64);
        \\return String(crypto.verifyEcdsa(jwk, "sha256", data, sig));
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("true", resp.body);
}

test "dispatch: crypto.verifyEcdsa rejects tampered signature" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\const jwk = {
        \\  kty: "EC", crv: "P-256",
        \\  x: "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU",
        \\  y: "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0",
        \\};
        \\const signing_input = "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ";
        \\// Flip the last bit of the signature.
        \\const sig = base64url.decode("DtEhU3ljbEg8L38VWAfUAqOyKAM6-Xx-F4GawxaepmXFCgfTjDxw5djxLa8ISlSApmWQxfKTUJqPP3-Kg6NU1Q");
        \\sig[sig.length - 1] ^= 0x01;
        \\const data = new TextEncoder().encode(signing_input);
        \\return String(crypto.verifyEcdsa(jwk, "sha256", data, sig));
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("false", resp.body);
}

test "dispatch: crypto.verifyEcdsa rejects wrong sig length / unsupported curve" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\const data = new TextEncoder().encode("hi");
        \\const tries = [
        \\  // Wrong sig length for P-256 (need 64 bytes).
        \\  () => crypto.verifyEcdsa(
        \\    { kty: "EC", crv: "P-256", x: "AA", y: "AA" },
        \\    "sha256", data, new Uint8Array(32),
        \\  ),
        \\  // Unsupported curve.
        \\  () => crypto.verifyEcdsa(
        \\    { kty: "EC", crv: "P-128", x: "AA", y: "AA" },
        \\    "sha256", data, new Uint8Array(64),
        \\  ),
        \\  // Wrong kty.
        \\  () => crypto.verifyEcdsa(
        \\    { kty: "RSA", crv: "P-256", x: "AA", y: "AA" },
        \\    "sha256", data, new Uint8Array(64),
        \\  ),
        \\];
        \\const out = tries.map(fn => { try { fn(); return "ok"; } catch (e) { return "threw"; } });
        \\return out.join(",");
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("threw,threw,threw", resp.body);
}

test "dispatch: crypto.ecdsa keygen→sign→verify roundtrip (secp256k1)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Exercises the full JS boundary: crypto.js shim → _system.crypto
    // → OpenSSL, on atproto's primary curve. Proves wiring + that a
    // fresh signature is low-S (ecdsaVerify rejects high-S).
    var resp = try runOne(&d, kv,
        \\const { privateKey, publicKey } = crypto.ecdsaGenerateKey("secp256k1");
        \\const msg = new TextEncoder().encode("atproto signed commit");
        \\const sig = crypto.ecdsaSign("secp256k1", privateKey, msg);
        \\const ok = crypto.ecdsaVerify("secp256k1", publicKey, msg, sig);
        \\const bad = crypto.ecdsaVerify("secp256k1", publicKey,
        \\  new TextEncoder().encode("tampered"), sig);
        \\return `${privateKey.length},${publicKey.length},${sig.length},${ok},${bad}`;
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("32,33,64,true,false", resp.body);
}

test "dispatch: a handler's _config/ write cannot reach real config" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Real config, as the deploy mirror writes it: under the deployment that
    // shipped it, below the binding.
    try kv.put("_config/oauth/google", "{\"sub\":\"real\"}");

    // The handler's write no longer throws — it lands in the handler's own
    // keyspace. What protects the atomic code+config switch is not a refusal
    // any more; it is that a rooted capability cannot name the config row at
    // all. Reaching real config is the `config` capability's job (rove#830).
    var resp = try runOne(&d, kv,
        \\kv.set("_config/oauth/google", "{\"sub\":\"attacker\"}");
        \\return "wrote";
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("wrote", resp.body);

    // The deploy-time row is untouched.
    const real = try kv.get("_config/oauth/google");
    defer testing.allocator.free(real);
    try testing.expectEqualStrings("{\"sub\":\"real\"}", real);
}
test "dispatch: PKCE-style flow uses sha256 + hex.decode + base64url.encode" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // RFC 7636 §B test vector:
    //   verifier   = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    //   challenge  = base64url(sha256(verifier))
    //              = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    var resp = try runOne(&d, kv,
        \\const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        \\const sha_hex = crypto.sha256(verifier);
        \\const sha_bytes = hex.decode(sha_hex);
        \\const challenge = base64url.encode(sha_bytes);
        \\return challenge;
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", resp.body);
}

test "dispatch: crypto.hmacSha256 matches RFC 4231 test vector (string inputs)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // RFC 4231 test case 1:
    //   key  = 0x0b * 20  →  "" * 20
    //   data = "Hi There"
    //   expected = b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7
    var resp = try runOne(
        &d,
        kv,
        \\const key = "\x0b".repeat(20);
        \\return crypto.hmacSha256(key, "Hi There");
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    try testing.expectEqualStrings(
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
        resp.body,
    );
}

test "dispatch: crypto.hmacSha256 accepts Uint8Array inputs" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Same RFC 4231 test case 1, both args as Uint8Array. Uses the
    // polyfilled TextEncoder to build UTF-8 bytes.
    var resp = try runOne(
        &d,
        kv,
        \\const key = new Uint8Array(20).fill(0x0b);
        \\const data = new TextEncoder().encode("Hi There");
        \\return crypto.hmacSha256(key, data);
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
        resp.body,
    );
}

test "dispatch: TextEncoder/TextDecoder round-trip multi-byte UTF-8" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Includes 1-, 2-, 3-byte UTF-8 codepoints to exercise the
    // polyfill branches. (4-byte needs surrogate pairs which
    // JSON.stringify escapes — tested via a smaller surrogate case
    // below.)
    var resp = try runOne(
        &d,
        kv,
        \\const s = "hi ★ € 世";
        \\const bytes = new TextEncoder().encode(s);
        \\const back = new TextDecoder().decode(bytes);
        \\return {
        \\  byte_count: bytes.length,
        \\  first_byte: bytes[0],
        \\  round_trip_ok: back === s,
        \\  echo: back,
        \\};
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    var out = try std.json.parseFromSlice(std.json.Value, testing.allocator, resp.body, .{});
    defer out.deinit();
    try testing.expectEqual(@as(i64, 'h'), out.value.object.get("first_byte").?.integer);
    try testing.expect(out.value.object.get("round_trip_ok").?.bool);
    try testing.expectEqualStrings("hi ★ € 世", out.value.object.get("echo").?.string);
}

test "dispatch: TextDecoder handles MB-scale payloads (native transcode, no per-char garbage)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // 2 MiB of multi-byte content. A per-char `s += fromCharCode(b)`
    // JS decoder loop would generate string-realloc garbage far beyond
    // any plausible arena at this size; the native path is one
    // conversion each way.
    var resp = try runOne(
        &d,
        kv,
        \\let unit = "abcdefé★0123456789";
        \\let s = unit;
        \\while (s.length < 2 * 1024 * 1024) s += s;
        \\const bytes = new TextEncoder().encode(s);
        \\const back = new TextDecoder().decode(bytes);
        \\return { len: s.length, byte_len: bytes.length, round_trip_ok: back === s };
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    var out = try std.json.parseFromSlice(std.json.Value, testing.allocator, resp.body, .{});
    defer out.deinit();
    try testing.expect(out.value.object.get("round_trip_ok").?.bool);
    try testing.expect(out.value.object.get("byte_len").?.integer > 2 * 1024 * 1024);
}

test "dispatch: TextDecoder malformed input — U+FFFD lenient, TypeError fatal" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\const bad = new Uint8Array([0x6f, 0x6b, 0x80, 0x21]); // "ok" <cont-byte> "!"
        \\const lenient = new TextDecoder().decode(bad);
        \\let fatal_threw = false;
        \\try { new TextDecoder("utf-8", { fatal: true }).decode(bad); }
        \\catch (e) { fatal_threw = e instanceof TypeError; }
        \\return {
        \\  lenient_ok: lenient === "ok�!",
        \\  fatal_threw: fatal_threw,
        \\};
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    var out = try std.json.parseFromSlice(std.json.Value, testing.allocator, resp.body, .{});
    defer out.deinit();
    try testing.expect(out.value.object.get("lenient_ok").?.bool);
    try testing.expect(out.value.object.get("fatal_threw").?.bool);
}

test "dispatch: crypto.hmacSha256 throws on missing args" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\try { crypto.hmacSha256("one"); return "no throw"; }
        \\catch (e) { return "threw: " + e.message; }
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, resp.body, "threw:"));
}

test "dispatch: crypto.randomBytes returns Uint8Array of requested length" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\const a = crypto.randomBytes(32);
        \\const b = crypto.randomBytes(0);
        \\return {
        \\  ctor_a: a.constructor.name,
        \\  len_a: a.length,
        \\  ctor_b: b.constructor.name,
        \\  len_b: b.length,
        \\};
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    var out = try std.json.parseFromSlice(std.json.Value, testing.allocator, resp.body, .{});
    defer out.deinit();
    try testing.expectEqualStrings("Uint8Array", out.value.object.get("ctor_a").?.string);
    try testing.expectEqual(@as(i64, 32), out.value.object.get("len_a").?.integer);
    try testing.expectEqualStrings("Uint8Array", out.value.object.get("ctor_b").?.string);
    try testing.expectEqual(@as(i64, 0), out.value.object.get("len_b").?.integer);
}

test "dispatch: crypto.randomBytes rejects out-of-range n" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // -1 → RangeError; 65537 → RangeError. Both must throw and the
    // catch produces a string starting "threw:".
    const cases = [_][]const u8{
        \\try { crypto.randomBytes(-1); return "no throw"; }
        \\catch (e) { return "threw: " + e.message; }
        ,
        \\try { crypto.randomBytes(65537); return "no throw"; }
        \\catch (e) { return "threw: " + e.message; }
        ,
    };
    for (cases) |src| {
        var resp = try runOne(&d, kv, src, .{ .method = "GET", .path = "/" });
        defer resp.deinit(testing.allocator);
        try testing.expect(std.mem.startsWith(u8, resp.body, "threw:"));
    }
}

test "dispatch: crypto.sha256 matches empty-string test vector" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // SHA-256 of "" = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    var resp = try runOne(
        &d,
        kv,
        \\return crypto.sha256("");
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        resp.body,
    );
}

test "dispatch: crypto.sha256 string and Uint8Array agree" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\const s = crypto.sha256("Hi There");
        \\const b = crypto.sha256(new TextEncoder().encode("Hi There"));
        \\return s === b ? "match:" + s : "mismatch";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, resp.body, "match:"));
}

test "dispatch: crypto.sha256 throws on missing arg" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\try { crypto.sha256(); return "no throw"; }
        \\catch (e) { return "threw: " + e.message; }
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, resp.body, "threw:"));
}

/// Find the taped kv entry for `key`, or null. Cross-store reads ride the kv
/// channel under `__rove_store/{tag}/` (globals_platform.zig).
fn tapedKv(rs: *tape_mod.Readset, key: []const u8) ?tape_mod.Entry.KvEntry {
    for (rs.kv.entries.items) |e| {
        if (std.mem.eql(u8, e.kv.key, key)) return e.kv;
    }
    return null;
}

/// Thin wrapper around tenant test setup. Used by the platform tests below
/// to put a real `Tenant` behind `state.platform`.
const PlatformFixture = struct {
    allocator: std.mem.Allocator,
    tmp_dir: []u8,
    root_kv: *kv_mod.KvStore,
    tenant: *tenant_mod.Tenant,

    fn init(allocator: std.mem.Allocator) !PlatformFixture {
        const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
        const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/rove-js-disp-pf-{x}", .{seed});
        errdefer allocator.free(tmp_dir);
        std.fs.cwd().deleteTree(tmp_dir) catch {};
        try std.fs.cwd().makePath(tmp_dir);
        const root_path = try std.fmt.allocPrintSentinel(allocator, "{s}/__root__.db", .{tmp_dir}, 0);
        defer allocator.free(root_path);
        const root_kv = try kv_mod.KvStore.open(allocator, root_path);
        errdefer root_kv.close();
        const tenant = try tenant_mod.Tenant.create(allocator, root_kv, tmp_dir);
        return .{ .allocator = allocator, .tmp_dir = tmp_dir, .root_kv = root_kv, .tenant = tenant };
    }

    fn deinit(self: *PlatformFixture) void {
        self.tenant.destroy();
        self.root_kv.close();
        std.fs.cwd().deleteTree(self.tmp_dir) catch {};
        self.allocator.free(self.tmp_dir);
    }
};

test "dispatch: platform.root + scope reads are taped under __rove_store/, keyed by store" {
    // #410: a cross-store read returns data to the handler, so it is an input
    // and must be recorded — the first input class that leaves the activation's
    // own tenant. The kv channel is tenant-implicit, so the STORE rides as a
    // key prefix, in the layout the offline facade already resolves against.
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var pf = try PlatformFixture.init(testing.allocator);
    defer pf.deinit();
    try pf.tenant.createInstance("acme");
    try pf.tenant.root.put("account/acme", "ROOTVAL");
    const inst = (try pf.tenant.getInstance("acme")).?;
    // Seeded at the STORE depth: `platform.scope(id).kv` answers what a handler
    // of `id` sees, so it resolves under the root like that handler's own kv.
    try inst.kv.put(uk("profile"), "SCOPEDVAL");
    try inst.kv.put(uk("p/1"), "one");

    var rs = tape_mod.Readset.init(testing.allocator, 1_700_000_000_000_000_000, 42);
    defer rs.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\const s = platform.scope("acme");
        \\return [
        \\  platform.root.get("account/acme"),
        \\  s.kv.get("profile"),
        \\  s.kv.prefix("p/", null, 10).map((e) => e.key + "=" + e.value).join(","),
        \\  String(platform.root.get("account/ghost")),
        \\].join("|");
    ,
        .{
            .method = "GET",
            .path = "/",
            .trace = .{ .readset = &rs },
            .admin = .{ .platform = pf.tenant },
        },
    );
    defer resp.deinit(testing.allocator);
    // The handler still sees exactly what it saw before — taping is additive.
    try testing.expectEqualStrings("ROOTVAL|SCOPEDVAL|p/1=one|null", resp.body);

    // Root read → the `r` namespace.
    const root_hit = tapedKv(&rs, "__rove_store/r/account/acme") orelse
        return error.RootReadNotTaped;
    try testing.expectEqual(tape_mod.KvOp.get, root_hit.op);
    try testing.expectEqual(tape_mod.KvOutcome.ok, root_hit.outcome);
    try testing.expectEqualStrings("ROOTVAL", root_hit.value);

    // Scoped read → the `i/{id}` namespace, so two instances can't collide.
    const scoped_hit = tapedKv(&rs, "__rove_store/i/acme/profile") orelse
        return error.ScopedReadNotTaped;
    try testing.expectEqualStrings("SCOPEDVAL", scoped_hit.value);

    // A not_found is recorded as such — replay must reproduce the null, or a
    // handler's `if (!x)` branch diverges.
    const missing = tapedKv(&rs, "__rove_store/r/account/ghost") orelse
        return error.MissingReadNotTaped;
    try testing.expectEqual(tape_mod.KvOutcome.not_found, missing.outcome);

    // The prefix scan records the namespaced prefix AND namespaced row keys —
    // the row keys are what seed the transcoded world's map, so an un-namespaced
    // row would land in the TENANT's keyspace offline.
    const scan = tapedKv(&rs, "__rove_store/i/acme/p/") orelse
        return error.ScopedPrefixNotTaped;
    try testing.expectEqual(tape_mod.KvOp.prefix, scan.op);
    try testing.expectEqual(@as(usize, 1), scan.results.len);
    try testing.expectEqualStrings("__rove_store/i/acme/p/1", scan.results[0].key);
    try testing.expectEqualStrings("one", scan.results[0].value);

    // Nothing leaked into the tenant's own keyspace: every entry is namespaced.
    for (rs.kv.entries.items) |e| {
        try testing.expect(std.mem.startsWith(u8, e.kv.key, "__rove_store/"));
    }
}

test "dispatch: a platform write obeys the same kv rules a customer write does" {
    // The privileged surface writes the target writeset directly rather
    // than through `rove-binding`, so it has its own call into the one
    // authority (`rove-guards`). Its bytes ride the SAME raft entry as the
    // batch, which is why the size caps and the activation's write budget
    // apply here unchanged — the only exemption the surface needs is WHICH
    // keys it may name, never how much one entry may carry. (The former
    // vehicle, `platform.root.set`, is gone — root writes are dispatched
    // activations so the scope write is the surface under test.)
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var pf = try PlatformFixture.init(testing.allocator);
    defer pf.deinit();
    try pf.tenant.createInstance("acme");
    // A no-op scope-write trampoline: the guards under test run BEFORE the
    // caps trampoline fires, so accepting silently is exactly the harness
    // this needs — the assertions are on the refusal codes alone.
    const Noop = struct {
        var sink: u8 = 0;
        fn tramp(ctx_: *anyopaque, alloc_: std.mem.Allocator, target: []const u8, op: globals.ScopeKvOp, key: []const u8, value: []const u8) anyerror!void {
            _ = ctx_;
            _ = alloc_;
            _ = target;
            _ = op;
            _ = key;
            _ = value;
        }
    };

    var resp = try runOne(
        &d,
        kv,
        \\const s = platform.scope("acme");
        \\// The exemption that survives: an admin handler names reserved keys.
        \\let reserved_ok = "yes";
        \\try { s.kv.set("_deploy/current", "rel-1"); }
        \\catch (e) { reserved_ok = e.code; }
        \\// The rules that apply regardless: the value cap, then the budget.
        \\let oversize = "none";
        \\try { s.kv.set("k", "x".repeat(400 * 1024)); }
        \\catch (e) { oversize = e.code; }
        \\let budget = "none";
        \\try { for (let i = 0; i < 5; i++) s.kv.set("b/" + i, "y".repeat(100 * 1024)); }
        \\catch (e) { budget = e.code; }
        \\return reserved_ok + "|" + oversize + "|" + budget;
    ,
        .{
            .method = "GET",
            .path = "/",
            .admin = .{ .platform = pf.tenant, .platform_caps = .{
                .ctx = @ptrCast(&Noop.sink),
                .scope_kv_write = &Noop.tramp,
            } },
        },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("yes|value_too_large|writes_too_large", resp.body);
}
test "dispatch: a platform-bound handler cannot reach the root bearer, and the tape records only the verdict" {
    // The invariant behind the credential rule (docs/decisions.md §4.6b): on a
    // replay platform a handler-readable input is a RECORDED input, so the
    // operator credential must not be reachable at all. Two halves, both
    // asserted here because either one alone leaks: the header is absent from
    // `request.headers`, AND the readset carries no `authorization` entry —
    // only the boolean verdict.
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var pf = try PlatformFixture.init(testing.allocator);
    defer pf.deinit();
    const token = "a" ** 64;
    pf.tenant.root_token_secret = token;

    var rs = tape_mod.Readset.init(testing.allocator, 1_700_000_000_000_000_000, 42);
    defer rs.deinit();

    const bearer = "Bearer " ++ token;
    var fields = [_]h2.HeaderField{
        .{
            .name = "authorization".ptr,
            .name_len = "authorization".len,
            .value = bearer.ptr,
            .value_len = @intCast(bearer.len),
        },
        .{
            .name = "content-type".ptr,
            .name_len = "content-type".len,
            .value = "application/json".ptr,
            .value_len = @intCast("application/json".len),
        },
    };
    const hdrs = h2.ReqHeaders{ .fields = @ptrCast(&fields), .count = fields.len };

    var resp = try runOne(
        &d,
        kv,
        // `Object.keys` sees the enumerable header set — so this also proves the
        // stripped name never reaches enumeration, not merely the getter.
        \\return JSON.stringify({
        \\  authVisible: Object.keys(request.headers).indexOf("authorization") !== -1,
        \\  authValue: String(request.headers["authorization"]),
        \\  otherVisible: Object.keys(request.headers).indexOf("content-type") !== -1,
        \\  isRoot: request.rewind.isRoot,
        \\});
    ,
        .{
            .method = "POST",
            .path = "/",
            .headers = hdrs,
            .trace = .{ .readset = &rs },
            .admin = .{ .platform = pf.tenant },
        },
    );
    defer resp.deinit(testing.allocator);

    // The credential is gone from the handler surface; an ordinary header is
    // untouched (the strip is scoped, not a blanket header purge).
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"authVisible\":false") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"authValue\":\"undefined\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"otherVisible\":true") != null);
    // ...and the verdict still comes out right, computed from the wire header
    // the handler can no longer see.
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"isRoot\":true") != null);

    // The tape half. Nothing anywhere in request_reads may carry the token —
    // not as a header value, not as a name — and the verdict must be present as
    // its own kind.
    var saw_verdict = false;
    for (rs.request_reads.entries.items) |e| {
        const rr = e.request_reads;
        try testing.expect(std.mem.indexOf(u8, rr.value, token) == null);
        try testing.expect(!std.mem.eql(u8, rr.name, "authorization"));
        if (rr.kind == .root_verdict) {
            saw_verdict = true;
            try testing.expectEqualStrings("1", rr.value);
        }
    }
    try testing.expect(saw_verdict);
}

test "dispatch: a non-platform handler still reads its own authorization header" {
    // The strip is scoped to platform-bound handlers. A customer tenant's
    // bearer is its own application's auth, on its own tape — §4.6's accepted
    // posture, and not this rule's business.
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var fields = [_]h2.HeaderField{.{
        .name = "authorization".ptr,
        .name_len = "authorization".len,
        .value = "Bearer customer-token".ptr,
        .value_len = @intCast("Bearer customer-token".len),
    }};
    const hdrs = h2.ReqHeaders{ .fields = @ptrCast(&fields), .count = fields.len };

    var resp = try runOne(
        &d,
        kv,
        \\return String(request.headers["authorization"]) + "|" + String(request.rewind);
    ,
        .{ .method = "POST", .path = "/", .headers = hdrs },
    );
    defer resp.deinit(testing.allocator);
    // Readable — and `request.rewind` doesn't exist off a platform-bound
    // handler, so there is no verdict surface to probe either.
    try testing.expectEqualStrings("Bearer customer-token|undefined", resp.body);
}

/// Stub for `platform.instances.deployStarter`'s trampoline. Records
/// the `target_id` it was called with and optionally fails with a
/// pre-set error. Matches the `Request.deploy_starter` signature.
const DeployStarterRecorder = struct {
    allocator: std.mem.Allocator,
    last_target_id: ?[]u8 = null,
    return_error: ?anyerror = null,
    call_count: u32 = 0,

    fn deinit(self: *DeployStarterRecorder) void {
        if (self.last_target_id) |s| self.allocator.free(s);
    }

    fn trampoline(
        ctx: *anyopaque,
        _: std.mem.Allocator,
        target_id: []const u8,
    ) anyerror!void {
        const self: *DeployStarterRecorder = @ptrCast(@alignCast(ctx));
        self.call_count += 1;
        if (self.last_target_id) |old| {
            self.allocator.free(old);
            self.last_target_id = null;
        }
        self.last_target_id = self.allocator.dupe(u8, target_id) catch null;
        if (self.return_error) |err| return err;
    }
};

test "dispatch: platform.instances.deployStarter throws on non-admin handler" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\try { platform.instances.deployStarter("acme"); return "no throw"; }
        \\catch (e) { return "threw: " + e.message; }
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, resp.body, "admin handler") != null);
}

test "dispatch: platform.instances.deployStarter throws when trampoline not configured" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var pf = try PlatformFixture.init(testing.allocator);
    defer pf.deinit();

    // Admin platform set, but no deploy_starter fn pointer (test path
    // / library mode without a worker). Should throw a clear error
    // rather than silently no-op.
    var resp = try runOne(
        &d,
        kv,
        \\try { platform.instances.deployStarter("acme"); return "no throw"; }
        \\catch (e) { return "threw: " + e.message; }
    ,
        .{
            .method = "POST",
            .path = "/",
            .admin = .{ .platform = pf.tenant },
        },
    );
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, resp.body, "not configured") != null);
}

test "dispatch: platform.instances.deployStarter invokes trampoline with name" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var pf = try PlatformFixture.init(testing.allocator);
    defer pf.deinit();

    var rec = DeployStarterRecorder{ .allocator = testing.allocator };
    defer rec.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\platform.instances.deployStarter("acme");
        \\return "ok";
    ,
        .{
            .method = "POST",
            .path = "/",
            .admin = .{
                .platform = pf.tenant,
                .platform_caps = .{
                    .ctx = &rec,
                    .deploy_starter = &DeployStarterRecorder.trampoline,
                },
            },
        },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("ok", resp.body);
    try testing.expectEqual(@as(u32, 1), rec.call_count);
    try testing.expectEqualStrings("acme", rec.last_target_id.?);
}

test "dispatch: platform.instances.deployStarter throws coded InstanceNotFound" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var pf = try PlatformFixture.init(testing.allocator);
    defer pf.deinit();

    var rec = DeployStarterRecorder{
        .allocator = testing.allocator,
        .return_error = error.InstanceNotFound,
    };
    defer rec.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\try { platform.instances.deployStarter("missing"); return "no throw"; }
        \\catch (e) { return "code=" + e.code; }
    ,
        .{
            .method = "POST",
            .path = "/",
            .admin = .{
                .platform = pf.tenant,
                .platform_caps = .{
                    .ctx = &rec,
                    .deploy_starter = &DeployStarterRecorder.trampoline,
                },
            },
        },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("code=InstanceNotFound", resp.body);
}

// ── Triggers (PLAN §2.5) ──────────────────────────────────────────────

test "trigger: afterPut fires after a kv.set inside the handler" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    // Two modules: handler at index.mjs writes a session;
    // trigger at _triggers/users/sessions/index.mjs maintains
    // a reverse index `users/by-session/{sid} -> user_id`.
    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("users/sessions/abc", JSON.stringify({ user_id: "u42" }));
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export function afterPut(event) {
        \\  const sess = JSON.parse(event.value);
        \\  const sid = event.key.split('/').pop();
        \\  kv.set("users/by-session/" + sid, sess.user_id);
        \\}
    , "_triggers/users/sessions/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged(*BlobBytes) = .empty;
    defer deinitTestBytecodes(&bytecodes);
    try putTestBytecode(&bytecodes, "_triggers/users/sessions/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("users/sessions/"),
        .module_path = @constCast("_triggers/users/sessions/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, null, &.{ .triggers = &triggers }, 0, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    try testing.expectEqualStrings("ok", resp.body);

    // Trigger should have written the reverse-index row.
    const indexed = try kv.get(uk("users/by-session/abc"));
    defer testing.allocator.free(indexed);
    try testing.expectEqualStrings("u42", indexed);
}

test "trigger: afterDelete fires with previousValue" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("orders/o1", JSON.stringify({ total: 100 }));
        \\  kv.delete("orders/o1");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export function afterDelete(event) {
        \\  if (event.previousValue) {
        \\    const order = JSON.parse(event.previousValue);
        \\    kv.set("audit/deleted-totals", String(order.total));
        \\  }
        \\}
    , "_triggers/orders/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged(*BlobBytes) = .empty;
    defer deinitTestBytecodes(&bytecodes);
    try putTestBytecode(&bytecodes, "_triggers/orders/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("orders/"),
        .module_path = @constCast("_triggers/orders/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, null, &.{ .triggers = &triggers }, 0, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const audit = try kv.get(uk("audit/deleted-totals"));
    defer testing.allocator.free(audit);
    try testing.expectEqualStrings("100", audit);
}

test "trigger: tree-traversal order — outer + inner both fire on AFTER" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Write to users/sessions/abc → matches both
    // _triggers/users/index.mjs AND _triggers/users/sessions/index.mjs.
    // Each appends its name to a marker key so we can verify both fired
    // and in the right order (innermost-first for AFTER).
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("users/sessions/abc", "v");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const inner_bc = try ctx.compileToBytecode(
        \\export function afterPut(event) {
        \\  const cur = kv.get("trace") || "";
        \\  kv.set("trace", cur + "inner;");
        \\}
    , "_triggers/users/sessions/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(inner_bc);

    const outer_bc = try ctx.compileToBytecode(
        \\export function afterPut(event) {
        \\  const cur = kv.get("trace") || "";
        \\  kv.set("trace", cur + "outer;");
        \\}
    , "_triggers/users/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(outer_bc);

    var bytecodes: std.StringHashMapUnmanaged(*BlobBytes) = .empty;
    defer deinitTestBytecodes(&bytecodes);
    try putTestBytecode(&bytecodes, "_triggers/users/sessions/index.mjs", inner_bc);
    try putTestBytecode(&bytecodes, "_triggers/users/index.mjs", outer_bc);

    // Sorted longest-first → forward iteration is innermost-first.
    const triggers = [_]globals.TriggerEntry{
        .{ .prefix = @constCast("users/sessions/"), .module_path = @constCast("_triggers/users/sessions/index.mjs") },
        .{ .prefix = @constCast("users/"), .module_path = @constCast("_triggers/users/index.mjs") },
    };

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, null, &.{ .triggers = &triggers }, 0, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const trace = try kv.get(uk("trace"));
    defer testing.allocator.free(trace);
    // AFTER chain fires innermost-first per PLAN §2.5.
    try testing.expectEqualStrings("inner;outer;", trace);
}

test "trigger: cascade depth limit halts runaway recursion" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Trigger that writes another key that matches itself → infinite
    // cascade. The depth cap must throw and abort the handler.
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("loop/0", "x");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export function afterPut(event) {
        \\  const n = parseInt(event.key.split('/').pop()) + 1;
        \\  kv.set("loop/" + n, "x");
        \\}
    , "_triggers/loop/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged(*BlobBytes) = .empty;
    defer deinitTestBytecodes(&bytecodes);
    try putTestBytecode(&bytecodes, "_triggers/loop/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("loop/"),
        .module_path = @constCast("_triggers/loop/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, null, &.{ .triggers = &triggers }, 0, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    // Handler doesn't catch → throw bubbles up, populates exception.
    try testing.expect(resp.exception.len > 0);
    try testing.expect(std.mem.indexOf(u8, resp.exception, "depth") != null);
}

test "trigger: platform-key writes do not fire customer triggers" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Customer's catch-all trigger would fire on every write, BUT
    // `_callback/...` is a platform key — the fire-time guard skips
    // dispatch so the customer's afterPut never sees system writes.
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("_callback/sys-write", "x");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export default function (event) {
        \\  kv.set("seen/" + event.key, "1");
        \\}
    , "_triggers/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged(*BlobBytes) = .empty;
    defer deinitTestBytecodes(&bytecodes);
    try putTestBytecode(&bytecodes, "_triggers/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast(""),
        .module_path = @constCast("_triggers/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, null, &.{ .triggers = &triggers }, 0, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    // Trigger SHOULD NOT have written `seen/_callback/sys-write`.
    try testing.expectError(error.NotFound, kv.get("seen/_callback/sys-write"));
}

test "trigger: beforePut throw is catchable in handler with code='trigger_rejected'" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Handler tries to write a session with no user_id; trigger rejects.
    // Handler catches and reports the error code.
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  try {
        \\    kv.set("users/sessions/abc", JSON.stringify({}));
        \\    return "should not reach";
        \\  } catch (e) {
        \\    return "code=" + e.code + " msg=" + e.message;
        \\  }
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export function beforePut(event) {
        \\  const sess = JSON.parse(event.value);
        \\  if (!sess.user_id) throw new Error("session missing user_id");
        \\}
    , "_triggers/users/sessions/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged(*BlobBytes) = .empty;
    defer deinitTestBytecodes(&bytecodes);
    try putTestBytecode(&bytecodes, "_triggers/users/sessions/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("users/sessions/"),
        .module_path = @constCast("_triggers/users/sessions/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, null, &.{ .triggers = &triggers }, 0, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    // code=trigger_rejected, message="<trigger_path>: <original>"
    try testing.expect(std.mem.indexOf(u8, resp.body, "code=trigger_rejected") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "session missing user_id") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "_triggers/users/sessions/index.mjs") != null);

    // The rejected write should NOT be in kv.
    try testing.expectError(error.NotFound, kv.get("users/sessions/abc"));
}

test "trigger: beforePut return-value mutates the written value" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Trigger lowercases the value before storage.
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("users/abc", "ALICE");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export function beforePut(event) {
        \\  return event.value.toLowerCase();
        \\}
    , "_triggers/users/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged(*BlobBytes) = .empty;
    defer deinitTestBytecodes(&bytecodes);
    try putTestBytecode(&bytecodes, "_triggers/users/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("users/"),
        .module_path = @constCast("_triggers/users/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, null, &.{ .triggers = &triggers }, 0, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const stored = try kv.get(uk("users/abc"));
    defer testing.allocator.free(stored);
    try testing.expectEqualStrings("alice", stored);
}

test "trigger: beforePut throw rolls back trigger-internal writes (the audit gotcha)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Documents the gotcha: a BEFORE that writes an audit row and then
    // throws does NOT keep the audit row — it gets rolled back with
    // the originating write. Customer must use afterPut for "log
    // every accepted write" and the handler itself for "log every
    // rejected attempt." See PLAN §2.5 implementation notes.
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  try { kv.set("orders/o1", "{}"); } catch (e) {}
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export function beforePut(event) {
        \\  kv.set("audit/last-attempt", event.key);
        \\  throw new Error("nope");
        \\}
    , "_triggers/orders/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged(*BlobBytes) = .empty;
    defer deinitTestBytecodes(&bytecodes);
    try putTestBytecode(&bytecodes, "_triggers/orders/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("orders/"),
        .module_path = @constCast("_triggers/orders/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, null, &.{ .triggers = &triggers }, 0, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    // Both the originating write AND the trigger's audit write are
    // rolled back by the inner savepoint (audit gotcha).
    try testing.expectError(error.NotFound, kv.get("orders/o1"));
    try testing.expectError(error.NotFound, kv.get("audit/last-attempt"));
}

test "trigger: afterPut throw is catchable AND rolls back the originating write" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Handler sets a key, AFTER throws, handler catches. Per PLAN
    // §2.5 the originating write must be rolled back even though
    // the handler caught the exception (inner savepoint covers
    // BEFORE+write+AFTER).
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  try {
        \\    kv.set("orders/o1", "{}");
        \\    return "no throw";
        \\  } catch (e) {
        \\    return "caught: code=" + e.code;
        \\  }
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export function afterPut(event) {
        \\  throw new Error("after rejected");
        \\}
    , "_triggers/orders/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged(*BlobBytes) = .empty;
    defer deinitTestBytecodes(&bytecodes);
    try putTestBytecode(&bytecodes, "_triggers/orders/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("orders/"),
        .module_path = @constCast("_triggers/orders/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, null, &.{ .triggers = &triggers }, 0, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    try testing.expectEqualStrings("caught: code=trigger_rejected", resp.body);

    // Originating write rolled back via inner savepoint.
    try testing.expectError(error.NotFound, kv.get("orders/o1"));
}

test "trigger: BEFORE chain runs outermost-first (broad validates before narrow)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Two BEFORE triggers: outer + inner. Each appends to a marker.
    // BEFORE chain should fire outermost-first (opposite of AFTER).
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("users/sessions/abc", "v");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const inner_bc = try ctx.compileToBytecode(
        \\export function beforePut(event) {
        \\  const cur = kv.get("trace") || "";
        \\  kv.set("trace", cur + "inner;");
        \\}
    , "_triggers/users/sessions/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(inner_bc);

    const outer_bc = try ctx.compileToBytecode(
        \\export function beforePut(event) {
        \\  const cur = kv.get("trace") || "";
        \\  kv.set("trace", cur + "outer;");
        \\}
    , "_triggers/users/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(outer_bc);

    var bytecodes: std.StringHashMapUnmanaged(*BlobBytes) = .empty;
    defer deinitTestBytecodes(&bytecodes);
    try putTestBytecode(&bytecodes, "_triggers/users/sessions/index.mjs", inner_bc);
    try putTestBytecode(&bytecodes, "_triggers/users/index.mjs", outer_bc);

    // Sorted longest-first → reverse iteration is outermost-first
    // (correct for BEFORE chain).
    const triggers = [_]globals.TriggerEntry{
        .{ .prefix = @constCast("users/sessions/"), .module_path = @constCast("_triggers/users/sessions/index.mjs") },
        .{ .prefix = @constCast("users/"), .module_path = @constCast("_triggers/users/index.mjs") },
    };

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, null, &.{ .triggers = &triggers }, 0, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const trace = try kv.get(uk("trace"));
    defer testing.allocator.free(trace);
    // BEFORE: outer first, then inner. (AFTER would be inner;outer; — see earlier test.)
    try testing.expectEqualStrings("outer;inner;", trace);
}

test "trigger: default export is the catchall when no named export matches" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Trigger only exports `default`. Should fire for both put and
    // delete (and both before+after if they're not separately named).
    // Test: put + delete + verify default ran twice with the right
    // event.op + event.timing values.
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("orders/o1", "{}");
        \\  kv.delete("orders/o1");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export default function (event) {
        \\  const cur = kv.get("trace") || "";
        \\  kv.set("trace", cur + event.timing + ":" + event.op + ";");
        \\}
    , "_triggers/orders/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged(*BlobBytes) = .empty;
    defer deinitTestBytecodes(&bytecodes);
    try putTestBytecode(&bytecodes, "_triggers/orders/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("orders/"),
        .module_path = @constCast("_triggers/orders/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, null, &.{ .triggers = &triggers }, 0, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const trace = try kv.get(uk("trace"));
    defer testing.allocator.free(trace);
    // put fires before+after (catchall handles both); then delete
    // fires before+after. AFTER innermost-first, BEFORE outermost-first
    // — but only one trigger here, so order is: before:put, after:put,
    // before:delete, after:delete.
    try testing.expectEqualStrings("before:put;after:put;before:delete;after:delete;", trace);
}

test "trigger: BEFORE sees previousValue on update" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Handler puts twice. Trigger captures (previousValue, value) on
    // each put so we can verify the second one saw the first's bytes
    // as previousValue.
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("docs/d1", "v1");
        \\  kv.set("docs/d1", "v2");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export function beforePut(event) {
        \\  const cur = kv.get("trace") || "";
        \\  const prev = event.previousValue === null ? "<null>" : event.previousValue;
        \\  kv.set("trace", cur + prev + "->" + event.value + ";");
        \\}
    , "_triggers/docs/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged(*BlobBytes) = .empty;
    defer deinitTestBytecodes(&bytecodes);
    try putTestBytecode(&bytecodes, "_triggers/docs/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("docs/"),
        .module_path = @constCast("_triggers/docs/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, null, &.{ .triggers = &triggers }, 0, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const trace = try kv.get(uk("trace"));
    defer testing.allocator.free(trace);
    // First put: previousValue is null (no existing key). Second put:
    // previousValue is "v1" (the just-written first value, visible
    // via TrackedTxn read-your-writes).
    try testing.expectEqualStrings("<null>->v1;v1->v2;", trace);
}

test "trigger: well-bounded cascade (depth 2, no runaway)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Handler writes A; A's afterPut writes B (different prefix,
    // different trigger); B's afterPut writes C (no matching trigger,
    // chain ends). Verify event.depth reflects the cascade level.
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("a/x", "a-value");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const a_trigger_bc = try ctx.compileToBytecode(
        \\export function afterPut(event) {
        \\  kv.set("trace_a", "depth=" + event.depth);
        \\  kv.set("b/y", "b-from-a");
        \\}
    , "_triggers/a/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(a_trigger_bc);

    const b_trigger_bc = try ctx.compileToBytecode(
        \\export function afterPut(event) {
        \\  kv.set("trace_b", "depth=" + event.depth);
        \\  kv.set("c/z", "c-from-b");  // no matching trigger, chain ends
        \\}
    , "_triggers/b/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(b_trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged(*BlobBytes) = .empty;
    defer deinitTestBytecodes(&bytecodes);
    try putTestBytecode(&bytecodes, "_triggers/a/index.mjs", a_trigger_bc);
    try putTestBytecode(&bytecodes, "_triggers/b/index.mjs", b_trigger_bc);

    const triggers = [_]globals.TriggerEntry{
        .{ .prefix = @constCast("a/"), .module_path = @constCast("_triggers/a/index.mjs") },
        .{ .prefix = @constCast("b/"), .module_path = @constCast("_triggers/b/index.mjs") },
    };

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, null, &.{ .triggers = &triggers }, 0, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    // Trigger A fires at depth 1 (handler invocation is depth 0).
    const trace_a = try kv.get(uk("trace_a"));
    defer testing.allocator.free(trace_a);
    try testing.expectEqualStrings("depth=1", trace_a);

    // Trigger B fires at depth 2 (cascade from A).
    const trace_b = try kv.get(uk("trace_b"));
    defer testing.allocator.free(trace_b);
    try testing.expectEqualStrings("depth=2", trace_b);

    // All three writes landed.
    const c_value = try kv.get(uk("c/z"));
    defer testing.allocator.free(c_value);
    try testing.expectEqualStrings("c-from-b", c_value);
}

test "interaction digest: folds reads, writes and the response as they happen" {
    // The digest is what makes "the handler executed the same" checkable
    // rather than assumed. These assertions are about the PROPERTIES a
    // fidelity check needs — that behaviour changes move it and incidental
    // things do not — rather than about any particular hash value, which
    // lives in the shared vectors (src/tape/testdata/digest_vectors.json).
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    {
        var txn = try kv.beginTrackedImmediate();
        try txn.put(uk("n"), "5");
        try txn.commit();
    }

    const src =
        \\const n = parseInt(kv.get("n") ?? "0", 10) + 1;
        \\kv.set("seen", String(n));
        \\return "n=" + n;
    ;

    var rs = tape_mod.Readset.init(testing.allocator, 1_700_000_000_000_000_000, 42);
    defer rs.deinit();
    var resp = try runOne(&d, kv, src, .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1, .readset = &rs } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);

    // A run that touched kv and produced a response has a digest.
    try testing.expect(rs.interaction_digest != 0);

    // The same handler over the same state digests identically — the property
    // a replay depends on. (Fresh kv value so the read sees "5" again.)
    {
        var txn = try kv.beginTrackedImmediate();
        try txn.put(uk("n"), "5");
        try txn.commit();
    }
    var rs2 = tape_mod.Readset.init(testing.allocator, 1_700_000_000_000_000_000, 42);
    defer rs2.deinit();
    var resp2 = try runOne(&d, kv, src, .{ .method = "POST", .path = "/", .trace = .{ .request_id = 2, .readset = &rs2 } });
    defer resp2.deinit(testing.allocator);
    try testing.expectEqual(rs.interaction_digest, rs2.interaction_digest);

    // A handler that writes a DIFFERENT value digests differently, even though
    // it reads the same key and returns the same body — the case an
    // output-only or status-only check misses.
    {
        var txn = try kv.beginTrackedImmediate();
        try txn.put(uk("n"), "5");
        try txn.commit();
    }
    var rs3 = tape_mod.Readset.init(testing.allocator, 1_700_000_000_000_000_000, 42);
    defer rs3.deinit();
    var resp3 = try runOne(&d, kv,
        \\const n = parseInt(kv.get("n") ?? "0", 10) + 1;
        \\kv.set("seen", "different");
        \\return "n=" + n;
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 3, .readset = &rs3 } });
    defer resp3.deinit(testing.allocator);
    try testing.expectEqualStrings(resp.body, resp3.body); // same response
    try testing.expect(rs.interaction_digest != rs3.interaction_digest); // different behaviour
}

test "interaction digest: a THROWN handler closes on its real 500, not (200, \"\")" {
    // #459. The throw is captured into `pending.exception` while status stays
    // 200 and body stays empty — the real 500 + `handler threw: …` body is
    // composed downstream. Closing the digest on `pending` directly meant every
    // failed request folded `(200, "")`: two handlers that failed DIFFERENTLY
    // digested identically, and a replay that faithfully reproduced the 500
    // computed a different hash and was reported as diverged.
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Two handlers that read the same state and then fail in DIFFERENT ways.
    const boom =
        \\throw new Error("boom");
    ;
    const other =
        \\throw new TypeError("a different failure");
    ;

    var rs_a = tape_mod.Readset.init(testing.allocator, 1_700_000_000_000_000_000, 42);
    defer rs_a.deinit();
    var resp_a = try runOne(&d, kv, boom, .{ .method = "GET", .path = "/", .trace = .{ .request_id = 1, .readset = &rs_a } });
    defer resp_a.deinit(testing.allocator);
    try testing.expect(resp_a.exception.len > 0);

    var rs_b = tape_mod.Readset.init(testing.allocator, 1_700_000_000_000_000_000, 42);
    defer rs_b.deinit();
    var resp_b = try runOne(&d, kv, other, .{ .method = "GET", .path = "/", .trace = .{ .request_id = 2, .readset = &rs_b } });
    defer resp_b.deinit(testing.allocator);
    try testing.expect(resp_b.exception.len > 0);

    // A failed run still closes its digest.
    try testing.expect(rs_a.interaction_digest != 0);
    // …and the two failures are DISTINGUISHABLE. This is the assertion that
    // fails when the closing element is `(200, "")` for both.
    try testing.expect(rs_a.interaction_digest != rs_b.interaction_digest);

    // The same failure twice digests identically — the property a replay
    // depends on, and the reason the fix must be deterministic rather than
    // merely different.
    var rs_c = tape_mod.Readset.init(testing.allocator, 1_700_000_000_000_000_000, 42);
    defer rs_c.deinit();
    var resp_c = try runOne(&d, kv, boom, .{ .method = "GET", .path = "/", .trace = .{ .request_id = 3, .readset = &rs_c } });
    defer resp_c.deinit(testing.allocator);
    try testing.expectEqual(rs_a.interaction_digest, rs_c.interaction_digest);

    // A THROWN run digests differently from a SUCCEEDING one whose body is the
    // thrown one's text — i.e. the status is folded too, not just the body.
    var rs_d = tape_mod.Readset.init(testing.allocator, 1_700_000_000_000_000_000, 42);
    defer rs_d.deinit();
    var resp_d = try runOne(&d, kv, "return \"handler threw: Error: boom\\n\";", .{ .method = "GET", .path = "/", .trace = .{ .request_id = 4, .readset = &rs_d } });
    defer resp_d.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp_d.exception);
    try testing.expect(rs_a.interaction_digest != rs_d.interaction_digest);
}

var digest_noop_sink: u8 = 0;
fn digestNoopScopeWrite(ctx_: *anyopaque, alloc_: std.mem.Allocator, target: []const u8, op: globals.ScopeKvOp, key: []const u8, value: []const u8) anyerror!void {
    _ = ctx_;
    _ = alloc_;
    _ = target;
    _ = op;
    _ = key;
    _ = value;
}

test "interaction digest: the privileged surface moves it, and a same-response admin run is not mistaken for identical" {
    // #413. Before this, `platform.*` was invisible to the digest: two admin
    // runs that read DIFFERENT tenants' state, or published DIFFERENT
    // deployments, digested identically as long as the response matched — so
    // the one standing check on admin replay fidelity could not see the half of
    // the surface that only admin handlers use.
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var pf = try PlatformFixture.init(testing.allocator);
    defer pf.deinit();
    try pf.tenant.createInstance("acme");
    try pf.tenant.createInstance("other");
    (try pf.tenant.getInstance("acme")).?.kv.put("profile", "A") catch {};
    (try pf.tenant.getInstance("other")).?.kv.put("profile", "A") catch {};

    // Same value in both stores, so the RESPONSE is byte-identical and only the
    // store read apart tells the two runs apart.
    const src_acme =
        \\return platform.scope("acme").kv.get("profile");
    ;
    const src_other =
        \\return platform.scope("other").kv.get("profile");
    ;

    const run = struct {
        fn go(dd: *Dispatcher, k: *kv_mod.KvStore, pfx: *PlatformFixture, src: []const u8, rid: u64, out: *u64) !Response {
            const rs = try testing.allocator.create(tape_mod.Readset);
            rs.* = tape_mod.Readset.init(testing.allocator, 1_700_000_000_000_000_000, 42);
            defer {
                out.* = rs.interaction_digest;
                rs.deinit();
                testing.allocator.destroy(rs);
            }
            return runOne(dd, k, src, .{
                .method = "GET",
                .path = "/",
                .trace = .{ .request_id = rid, .readset = rs },
                .admin = .{ .platform = pfx.tenant, .platform_caps = .{
                    .ctx = @ptrCast(@constCast(&digest_noop_sink)),
                    .scope_kv_write = &digestNoopScopeWrite,
                } },
            });
        }
    }.go;

    var dg_acme: u64 = 0;
    var r1 = try run(&d, kv, &pf, src_acme, 1, &dg_acme);
    defer r1.deinit(testing.allocator);
    var dg_acme2: u64 = 0;
    var r2 = try run(&d, kv, &pf, src_acme, 2, &dg_acme2);
    defer r2.deinit(testing.allocator);
    var dg_other: u64 = 0;
    var r3 = try run(&d, kv, &pf, src_other, 3, &dg_other);
    defer r3.deinit(testing.allocator);

    try testing.expect(dg_acme != 0);
    // Identical behaviour → identical digest (the property replay depends on).
    try testing.expectEqual(dg_acme, dg_acme2);
    // Byte-identical response, DIFFERENT store read → different digest. This is
    // the case a status-only or response-only check misses entirely.
    try testing.expectEqualStrings(r1.body, r3.body);
    try testing.expect(dg_acme != dg_other);

    // A WRITE op moves it too, and its ARGUMENTS show: two scope writes that
    // differ only in the target must not digest alike. (`instances.create`,
    // the old vehicle, is gone — root writes are dispatched activations,
    // . The scope write folds op + target + key the same way and
    // needs only the no-op caps trampoline.)
    var dg_c1: u64 = 0;
    var p1 = try run(&d, kv, &pf,
        \\platform.scope("acme").kv.set("probe", "1");
        \\return "ok";
    , 4, &dg_c1);
    defer p1.deinit(testing.allocator);
    var dg_c2: u64 = 0;
    var p2 = try run(&d, kv, &pf,
        \\platform.scope("other").kv.set("probe", "1");
        \\return "ok";
    , 5, &dg_c2);
    defer p2.deinit(testing.allocator);
    try testing.expectEqualStrings("ok", p1.body);
    try testing.expectEqualStrings(p1.body, p2.body);
    try testing.expect(dg_c1 != 0);
    try testing.expect(dg_c1 != dg_c2);
}

test "interaction digest: effects move it, and a same-response handler is not mistaken for identical" {
    // Before the effect hooks existed, a handler whose only effect was an
    // outbound send digested as if it had merely responded — the digest would
    // have reported "identical" for two handlers that behaved differently,
    // which is worse than reporting nothing.
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    const base =
        \\response.status = 200;
        \\return "same";
    ;
    const with_timer =
        \\after.ms(5000, { on: "onWake" });
        \\response.status = 200;
        \\return "same";
    ;
    const with_other_timer =
        \\after.ms(9000, { on: "onWake" });
        \\response.status = 200;
        \\return "same";
    ;

    var d1 = tape_mod.Readset.init(testing.allocator, 1_700_000_000_000_000_000, 42);
    defer d1.deinit();
    var r1 = try runOne(&d, kv, base, .{ .method = "GET", .path = "/", .trace = .{ .request_id = 1, .readset = &d1 } });
    defer r1.deinit(testing.allocator);

    var d2 = tape_mod.Readset.init(testing.allocator, 1_700_000_000_000_000_000, 42);
    defer d2.deinit();
    var r2 = try runOne(&d, kv, with_timer, .{ .method = "GET", .path = "/", .trace = .{ .request_id = 2, .readset = &d2 } });
    defer r2.deinit(testing.allocator);

    var d3 = tape_mod.Readset.init(testing.allocator, 1_700_000_000_000_000_000, 42);
    defer d3.deinit();
    var r3 = try runOne(&d, kv, with_other_timer, .{ .method = "GET", .path = "/", .trace = .{ .request_id = 3, .readset = &d3 } });
    defer r3.deinit(testing.allocator);

    // All three respond identically; only the effects differ.
    try testing.expectEqualStrings("same", r1.body);
    try testing.expectEqualStrings("same", r2.body);
    try testing.expectEqualStrings("same", r3.body);

    try testing.expect(d1.interaction_digest != d2.interaction_digest); // arming an effect shows
    try testing.expect(d2.interaction_digest != d3.interaction_digest); // its ARGUMENTS show too
}
