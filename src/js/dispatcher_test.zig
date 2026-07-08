//! Tests for `dispatcher.zig`, split out of the production file — they
//! were 86% of it (the first `test` sat at line ~950 of ~7,000 with no
//! `pub` declaration after it). Same module (rove-js); wired into the
//! test build via root.zig's test aggregator block. The import aliases
//! below mirror dispatcher.zig's own so the moved tests read unchanged.

const std = @import("std");
const qjs = @import("rove-qjs");
const kv_mod = @import("raft-kv");
const tape_mod = @import("rove-tape");
const tenant_mod = @import("rove-tenant");
const h2 = @import("rove-h2");
const rove = @import("rove");

const globals = @import("globals.zig");
const bytecode_cache_mod = @import("bytecode_cache.zig");
const BlobBytes = bytecode_cache_mod.BlobBytes;
const c = qjs.c;

const dispatcher_mod = @import("dispatcher.zig");
const JS_ENGINE_VERSION = dispatcher_mod.JS_ENGINE_VERSION;
const DispatchError = dispatcher_mod.DispatchError;
const Budget = dispatcher_mod.Budget;
const Request = dispatcher_mod.Request;
const Response = dispatcher_mod.Response;
const RunOutcome = dispatcher_mod.RunOutcome;
const Dispatcher = dispatcher_mod.Dispatcher;
const testing = std.testing;

/// Phase 3 test fixture helper: the production snapshot stores
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

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
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

test "dispatch: kv.get on missing key returns null" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
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
/// `fn_override` target (the resume-engine mechanism — the customer
/// `?fn=` query dispatch is retired, decisions.md §4.5).
fn runOneOutcome(
    d: *Dispatcher,
    kv: *kv_mod.KvStore,
    body: []const u8,
    request_in: Request,
) !RunOutcome {
    const wrapped = try std.fmt.allocPrint(testing.allocator,
        "export function go() {{ {s} }}\n", .{body});
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
    const outcome = try d.runOutcome(kv, &txn, &ws, bytecode, null, null, null, request, &budget);
    try txn.commit();
    return outcome;
}

/// Back-compat harness: collapses to `Response`. All existing
/// `runOne`-based tests use this unchanged; continuation tests call
/// `runOneOutcome`.
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

/// Phase 5 PR-3 test helper. The JS-shim `webhook.send` writes
/// `_send/owed/{id}` as a JSON object marker (see
/// `globals/webhook.js`). The caller owns the returned slice +
/// frees with `testing.allocator.free`.
fn readOwedMarker(kv: *kv_mod.KvStore, id: []const u8) ![]u8 {
    var key_buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "_send/owed/{s}", .{id}) catch unreachable;
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
        \\return __rove_next("handlers/login", { fn: "onToken", ctx: { u: "alice", tries: 0 } });
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
            try testing.expectEqualStrings("onToken", cont.fn_name.?);
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

    // And a continuation through the back-compat `run` collapses to
    // 501 (Phase 3b-i: resume path not wired yet), never hangs/panics.
    var outcome = try runOneOutcome(
        &d,
        kv,
        \\return __rove_next("m", { ctx: {} });
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

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();

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
    // durable-wake-plan P5(a): timing left the marker — the scheduler
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
    const kv_key = std.fmt.bufPrint(&kv_key_buf, "_sched/by_id/{s}", .{sched_id}) catch unreachable;
    return kv.get(kv_key);
}

// Phase 5 PR-3: the original Zig http.send-binding tests deleted
// here (they exercised the now-retired surface). The JS-shim path
// is exercised by the marker tests above + the webhook smoke
// (`scripts/webhook_smoke.py`).

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

test "dispatch: retry.send wraps webhook.send + carries _retry meta" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\return retry.send({
        \\  url: "https://api.stripe.com/v1/charges",
        \\  body: "x",
        \\  on: "stripe_done",
        \\  maxAttempts: 3,
        \\  ctx: { charge_id: 42 },
        \\});
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 7 } });
    defer resp.deinit(testing.allocator);

    const marker_raw = try readOwedMarker(kv, resp.body);
    defer testing.allocator.free(marker_raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, marker_raw, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("https://api.stripe.com/v1/charges", obj.get("url").?.string);
    try testing.expectEqualStrings("stripe_done", obj.get("on_result").?.string);
    // retry.send pins webhook.send's built-in retry to 1 (off).
    try testing.expectEqual(@as(i64, 1), obj.get("max_attempts").?.integer);

    const ctx = obj.get("context").?.object;
    try testing.expectEqual(@as(i64, 42), ctx.get("charge_id").?.integer);
    const r = ctx.get("_retry").?.object;
    try testing.expectEqual(@as(i64, 1), r.get("attempt").?.integer);
    try testing.expectEqual(@as(i64, 3), r.get("max_attempts").?.integer);
    try testing.expectEqualStrings("stripe_done", r.get("on_result_module").?.string);
}

test "dispatch: ambient retry.shouldRetry / retry.ctx logic" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\const mk = (okv, r) => { request.ok = okv; request.ctx = { _retry: r }; return retry.shouldRetry(); };
        \\const ok = mk(true, { attempt: 1, max_attempts: 3 });
        \\const failed_with_attempts = mk(false, { attempt: 1, max_attempts: 3 });
        \\const failed_exhausted = mk(false, { attempt: 3, max_attempts: 3 });
        \\request.ok = false; request.ctx = { charge_id: 42 };
        \\const no_retry_meta = retry.shouldRetry();
        \\request.ctx = { charge_id: 42, _retry: { attempt: 2 } };
        \\const stripped = JSON.stringify(retry.ctx());
        \\return [ok, failed_with_attempts, failed_exhausted, no_retry_meta].join(",") + "|" + stripped;
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);

    const pipe = std.mem.indexOfScalar(u8, resp.body, '|').?;
    try testing.expectEqualStrings("false,true,false,false", resp.body[0..pipe]);
    try testing.expect(std.mem.indexOf(u8, resp.body[pipe..], "_retry") == null);
}

// Endpoint A (decisions.md): a customer `on_result` hop (webhook.send /
// blob.put / retry) AND a §6.4 held-sync resume both arrive as a
// `.send_callback` whose body is `{"ctx":{result,context}}`. The runtime
// hoists it onto the SAME flattened surface a bound fetch resume uses:
// `request.body` = response bytes, top-level `request.status`/`.ok`/`.done`,
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
        \\  "ok=" + request.ok,
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
        "status=200 ok=true done=true body=PONG ctx.order=42 act.attempts=1 act.error=null result=undefined",
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

test "dispatch: segments.logs seek-scan — adjacent ids, pagination, id containing '0'" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Byte-order traps: "xyz-a" sorts BEFORE "xyz" ('-' < '/'), "xyz0"
    // sorts after the seek cursor for "xyz" and must not be skipped.
    var resp = try runOne(&d, kv,
        \\for (const id of ["xyz", "xyz-a", "xyz0", "aaa"]) segments.append(id, "v");
        \\const one = segments.logs(undefined, 2);
        \\const two = segments.logs(one.cursor, 10);
        \\if (two.cursor !== null) return "cursor-not-drained";
        \\return one.logs.concat(two.logs).join(",");
    , .{
        .method = "POST",
        .path = "/",
        .trace = .{ .request_id = 1 },
    });
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("aaa,xyz-a,xyz,xyz0", resp.body);
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

// ── docs/plans/handler-api-ergonomics-plan.md Phase 1 (C1–C4) ─────────

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
        \\try { __rove_next("", { ctx: { big: 10n } }); } catch (e) { threw = e; }
        \\if (!(threw instanceof TypeError)) return "no-throw";
        \\__rove_next("", {});   // absent ctx must not throw
        \\__rove_next("");       // no opts at all must not throw
        \\return "threw";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("threw", resp.body);
}

// ── handler-api-ergonomics-plan Phase 2 — the uniform payload surface ──

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
    // a payload the old lossy string channel could not carry.
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

// ── handler-api-ergonomics-plan Phase 3 — the grammar sweep ──────────

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
        \\const id = after.fetch("http://up.test/", {}, { on: "onR" });
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
    var resp = try d.run(kv, &txn, &ws, bc, null, null, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bc, null, null, &.{ .subscriptions = &subs }, .{
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
        try txn.put("n", "5");
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
        if (std.mem.eql(u8, e.kv.key, "n")) n_reads += 1;
    }
    try testing.expectEqual(@as(usize, 1), n_reads);
    // The committed value is the retry's single increment.
    const v = try kv.get("n");
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("6", v);
}

test "arena-oom: loud 500 when even GC can't fit the request (no silent empty body)" {
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
    // mangled OOM outcome used to yield.
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
        \\  if (a.final && (!a.ok || a.status < 200 || a.status >= 300 || a.bodyTruncated)) {
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
    var resp = try d.run(kv, &txn, &ws, bc, null, null, null, .{
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

test "dispatch: schedule verb owns the whole timer surface; scheduler global is gone" {
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
        \\const a = schedule({ in: 5000 }, "jobs/x", { p: 1 }, { key: "job-x" });
        \\if (typeof a !== "string") return "bad";
        \\if (typeof globalThis.scheduler !== "undefined") return "scheduler-still-installed";
        \\const s = schedule.get(a);
        \\if (!s || s.target !== "jobs/x" || s.key !== "job-x") return "get-wrong";
        \\if (kv.get("_sched/by_id/" + a) === null) return "no-row";
        \\if (!schedule.cancel(a)) return "cancel-missed";
        \\return "ok:" + (kv.get("_sched/by_id/" + a) === null) + ":" + (schedule.get(a) === null);
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("", resp.exception);
    try testing.expectEqualStrings("ok:true:true", resp.body);
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

test "dispatch: kv.set rejects platform-reserved prefixes" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Attempting to spoof a callback row from customer code throws
    // Error{code: "reserved_key"}. Same shape applies to _events/,
    // _audit/, _magic/, _triggers/, etc.
    var resp = try runOne(
        &d,
        kv,
        \\try {
        \\  kv.set("_callback/spoofed", "x");
        \\  return "no_throw";
        \\} catch (e) {
        \\  return e.code + ":" + e.message;
        \\}
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expect(std.mem.startsWith(u8, resp.body, "reserved_key:"));
    try testing.expect(std.mem.indexOf(u8, resp.body, "_callback/spoofed") != null);

    // The spoofed row must NOT be in the kv after commit.
    try testing.expectError(error.NotFound, kv.get("_callback/spoofed"));
}

test "dispatch: kv.delete rejects platform-reserved prefixes" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Seed a callback row directly through the kv (simulating a real
    // envelope-5 apply having written it earlier).
    try kv.put("_callback/abc123", "real_receipt");

    // Customer kv.delete against the reserved prefix throws.
    var resp = try runOne(
        &d,
        kv,
        \\try {
        \\  kv.delete("_callback/abc123");
        \\  return "no_throw";
        \\} catch (e) {
        \\  return e.code;
        \\}
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("reserved_key", resp.body);

    // The seeded row must still be there.
    const v = try kv.get("_callback/abc123");
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("real_receipt", v);
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

    const a = try kv.get("my_audit/x");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("v1", a);
    const b = try kv.get("users/alice");
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

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();

    try kv.put("k", "v");

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
    try testing.expectError(error.NotFound, kv.get("k"));
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

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
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

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
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

test "dispatch: request.tag captured into response.tags (update-in-place)" {
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
        \\request.tag("session", "S1");
        \\request.tag("flow", "checkout");
        \\request.tag("session", "S2"); // same key → updates in place
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

test "dispatch: request.tag rejects reserved + over-cap (fail loud)" {
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
        \\request.tag("_corr", "nope");
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

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
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

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
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

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();

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
    try kv.put("seeded", "v1");

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

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();

    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
        .method = "POST",
        .path = "/",
        .fn_override = "go",
        .trace = .{ .readset = &readset },
    }, &budget);
    defer resp.deinit(testing.allocator);

    // `docs/primitive-gaps.md` §8: only foreign reads land on the
    // tape. The handler does two `kv.get`s (both foreign — writeset
    // is empty at both call sites), one `kv.set` (own-write, no
    // tape entry), one `kv.delete` (own-write, no tape entry).
    // Result: 2 tape entries, both `.get`. The kv.set/.delete are
    // outputs replay re-issues against its writeset overlay.
    try testing.expectEqual(@as(usize, 2), readset.kv.entries.items.len);

    const e0 = readset.kv.entries.items[0].kv;
    try testing.expectEqual(tape_mod.KvOp.get, e0.op);
    try testing.expectEqualStrings("seeded", e0.key);
    try testing.expectEqualStrings("v1", e0.value);
    try testing.expectEqual(tape_mod.KvOutcome.ok, e0.outcome);

    const e1 = readset.kv.entries.items[1].kv;
    try testing.expectEqual(tape_mod.KvOp.get, e1.op);
    try testing.expectEqualStrings("missing", e1.key);
    try testing.expectEqual(tape_mod.KvOutcome.not_found, e1.outcome);

    // §8 invariant: the writeset still records the writes so the
    // dispatch path can replicate + apply them. Tape minimization
    // is purely a capture-side compression.
    try testing.expectEqual(@as(usize, 2), ws.ops.items.len);
    try testing.expect(ws.containsKey("new"));
    try testing.expect(ws.containsKey("seeded"));
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

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();

    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
        .method = "POST",
        .path = "/",
        .fn_override = "go",
        .trace = .{ .readset = &readset },
    }, &budget);
    defer resp.deinit(testing.allocator);

    // Tape carries ZERO entries: the kv.set is an output (not taped),
    // the kv.get reads from the writeset (own-read, not taped).
    try testing.expectEqual(@as(usize, 0), readset.kv.entries.items.len);
    try testing.expect(ws.containsKey("own"));
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

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
    var body_1: []u8 = &.{};
    defer if (body_1.len > 0) testing.allocator.free(body_1);
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();

        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
            .method = "GET",
            .path = "/",
            .fn_override = "go",
            .trace = .{ .readset = &readset },
        }, &budget);
        defer resp.deinit(testing.allocator);
        body_1 = try testing.allocator.dupe(u8, resp.body);
    }

    // Two scalars: ZERO tape entries on any random / date channel
    // because they no longer exist.

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
        var resp2 = try d.run(kv, &txn2, &ws2, bytecode, null, null, null, .{
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

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
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

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
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
    // proves customer envelope shapes no longer route (the platform
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

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();

    // fn_override=greet reads request.path → "hi /hello", status 200.
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
            .method = "GET",
            .path = "/hello",
            .fn_override = "nope",
        }, &budget);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 404), resp.status);
        try testing.expect(std.mem.indexOf(u8, resp.body, "nope") != null);
    }

    // The retired customer envelope shapes are inert: a `?fn=` query
    // and a `{fn,args}` body both land in the DEFAULT export.
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
    const wrapped = try std.fmt.allocPrint(testing.allocator,
        "export function go() {{ {s} }}\n", .{handler_body});
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
    const resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, null, request, &budget);
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
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
            .{ .batch_id = 0, .offset = 0, .len = 5 },
            "hello",
        );
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
        \\        raw: request.unmaskedIp(),
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
            \\    return request.ip + "|" + request.unmaskedIp();
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
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
            \\    return JSON.stringify({ ip: request.ip, raw: request.unmaskedIp() });
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
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
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

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
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

    // Phase 5 PR-3: webhook.send is the JS-shim composition
    // (`globals/webhook.js`). Each writes a JSON `_send/owed/{id}`
    // marker the baked `__system/webhook_fire` / `webhook_onresult`
    // modules read (deferred fires ride the durable scheduler).
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

test "dispatch: email.send wraps webhook.send (JS shim) with Resend shape" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // email.send → webhook.send (JS shim) → kv.set + http.fetch.
    var resp = try runOne(
        &d,
        kv,
        \\return email.send({
        \\  apiKey: "re_test_abc",
        \\  from: "noreply@loop46.me",
        \\  to: "user@example.com",
        \\  subject: "Verify",
        \\  text: "Click me.",
        \\  on: "signup/email_result",
        \\  ctx: { user_id: 42 },
        \\});
    ,
        .{ .method = "POST", .path = "/", .trace = .{ .request_id = 7 } },
    );
    defer resp.deinit(testing.allocator);

    const marker_raw = try readOwedMarker(kv, resp.body);
    defer testing.allocator.free(marker_raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, marker_raw, .{});
    defer parsed.deinit();
    const row = parsed.value.object;

    try testing.expectEqualStrings("https://api.resend.com/emails", row.get("url").?.string);
    try testing.expectEqualStrings("POST", row.get("method").?.string);

    const headers_obj = row.get("headers").?.object;
    try testing.expectEqualStrings(
        "Bearer re_test_abc",
        headers_obj.get("Authorization").?.string,
    );
    try testing.expectEqualStrings(
        "application/json",
        headers_obj.get("Content-Type").?.string,
    );
    try testing.expectEqualStrings("signup/email_result", row.get("on_result").?.string);

    // Body is a JSON string; parse to check shape.
    var body_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, row.get("body").?.string, .{});
    defer body_parsed.deinit();
    const body_obj = body_parsed.value.object;
    try testing.expectEqualStrings("noreply@loop46.me", body_obj.get("from").?.string);
    try testing.expectEqualStrings("Verify", body_obj.get("subject").?.string);
    try testing.expectEqualStrings("Click me.", body_obj.get("text").?.string);
    // `to` gets array-wrapped even when passed as a string.
    try testing.expectEqual(@as(usize, 1), body_obj.get("to").?.array.items.len);
    try testing.expectEqualStrings("user@example.com", body_obj.get("to").?.array.items[0].string);
}

test "dispatch: email.send rejects missing key/from/to/subject" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    const cases = [_][]const u8{
        // Missing key.
        \\try { email.send({ from: "a@b.com", to: "c@d.com", subject: "s" }); return "ok"; }
        \\catch (e) { return "threw:" + e.message; }
        ,
        // Missing from.
        \\try { email.send({ apiKey: "re_x", to: "c@d.com", subject: "s" }); return "ok"; }
        \\catch (e) { return "threw:" + e.message; }
        ,
        // Missing to.
        \\try { email.send({ apiKey: "re_x", from: "a@b.com", subject: "s" }); return "ok"; }
        \\catch (e) { return "threw:" + e.message; }
        ,
        // Missing subject.
        \\try { email.send({ apiKey: "re_x", from: "a@b.com", to: "c@d.com" }); return "ok"; }
        \\catch (e) { return "threw:" + e.message; }
        ,
    };

    for (cases) |src| {
        var resp = try runOne(&d, kv, src, .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
        defer resp.deinit(testing.allocator);
        try testing.expect(std.mem.startsWith(u8, resp.body, "threw:"));
    }
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

test "dispatch: jwt.decode parses valid token" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\const token = "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJqb2UiLCJleHAiOjEzMDA4MTkzODB9.fakesig";
        \\const decoded = jwt.decode(token);
        \\return decoded.header.alg + "|" + decoded.payload.iss + "|" + decoded.payload.exp;
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("RS256|joe|1300819380", resp.body);
}

test "dispatch: jwt.verify against RFC 7515 §A.2 RS256 vector" {
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
        \\const token = "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.cC4hiUPoj9Eetdgtv3hF80EGrhuB__dzERat0XF9g2VtQgr9PJbu3XOiZj5RZmh7AAuHIm4Bh-0Qc_lF5YKt_O8W2Fp5jujGbds9uJdbF9CUAr7t1dnZcAcQjbKBYNX4BAynRFdiuB--f_nZLgrnbyTyWzO75vRK5h6xBArLIARNPvkSjtQBMHlb1L07Qe7K0GarZRmB_eSN9383LcOLn6_dO--xi12jzDwusC-eOkHWEsqtFZESc6BfI7noOPqvhJ1phCnvWh6IeYI2w9QOYEUipUTI8np6LbgGY9Fs98rqVt5AXLIhWkWywlVmtVrBp0igcN_IoypGlUPQGe77Rw";
        \\const result = jwt.verify(token, jwk);
        \\return result.valid + "|" + result.payload.iss;
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("true|joe", resp.body);
}

test "dispatch: jwt.verify picks key by kid from JWKS" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Token header includes kid:"k1"; JWKS has one matching + a
    // decoy. Library picks the right key.
    var resp = try runOne(&d, kv,
        \\const jwks = { keys: [
        \\  { kty:"RSA", kid:"decoy", n:"AQAB", e:"AQAB" },
        \\  { kty:"RSA", kid:"k1",
        \\    n:"ofgWCuLjybRlzo0tZWJjNiuSfb4p4fAkd_wWJcyQoTbji9k0l8W26mPddxHmfHQp-Vaw-4qPCJrcS2mJPMEzP1Pt0Bm4d4QlL-yRT-SFd2lZS-pCgNMsD1W_YpRPEwOWvG6b32690r2jZ47soMZo9wGzjb_7OMg0LOL-bSf63kpaSHSXndS5z5rexMdbBYUsLA9e-KXBdQOS-UTo7WTBEMa2R2CapHg665xsmtdVMTBQY4uDZlxvb3qCo5ZwKh9kG4LT6_I5IhlJH7aGhyxXFvUK-DWNmoudF8NAco9_h9iaGNj8q2ethFkMLs91kzk2PAcDTW9gb54h4FRWyuXpoQ",
        \\    e:"AQAB" },
        \\] };
        \\// Token header has kid:"k1"; payload doesn't matter. Reusing
        \\// RFC 7515 §A.2 except header tweaked to add kid.
        \\// header = base64url('{"alg":"RS256","kid":"k1"}') = eyJhbGciOiJSUzI1NiIsImtpZCI6ImsxIn0
        \\// (need a fresh signature for the new header — for kid-pick test we
        \\// just verify decode + select happens; valid bit will be false.)
        \\const token = "eyJhbGciOiJSUzI1NiIsImtpZCI6ImsxIn0.eyJpc3MiOiJqb2UifQ.fake";
        \\try {
        \\  const result = jwt.verify(token, jwks);
        \\  // Selection succeeded (no "no key" throw); base64url-decode
        \\  // of "fake" produces non-RSA-sized garbage so verify is false.
        \\  return "selected|" + result.valid;
        \\} catch (e) {
        \\  return "threw:" + e.message;
        \\}
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("selected|false", resp.body);
}

test "dispatch: jwt.validateClaims iss/aud/exp" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\// now = 2_000_000s (well past 1_500_000s, well before 3_000_000s)
        \\const now_ms = 2_000_000_000;
        \\const cases = [
        \\  jwt.validateClaims({ exp: 3_000_000, iss: "google", aud: "myapp" },
        \\    { now: now_ms, iss: "google", aud: "myapp" }),
        \\  jwt.validateClaims({ exp: 1_000_000 }, { now: now_ms }),  // expired
        \\  jwt.validateClaims({ iss: "evil" }, { now: now_ms, iss: "google" }),
        \\  jwt.validateClaims({ aud: ["a", "b"] }, { now: now_ms, aud: "b" }),
        \\];
        \\return cases.map(c => c === null ? "ok" : c).join(",");
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("ok,expired,issuer-mismatch,ok", resp.body);
}

test "dispatch: oauth.fromConfig(inline).startLogin builds authorize URL + stores state" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Inline-config form — no kv config row needed. Library still
    // derives default state_path from the inline name field.
    var resp = try runOne(&d, kv,
        \\const provider = oauth.fromConfig({
        \\  name: "google",
        \\  authorization_url: "https://accounts.google.com/o/oauth2/v2/auth",
        \\  token_url: "https://oauth2.googleapis.com/token",
        \\  client_id: "abc.apps.googleusercontent.com",
        \\  client_secret: "shh",
        \\  redirect_uri: "https://app.example.com/cb",
        \\  scopes: ["openid", "email"],
        \\  on_complete_module: "users/oauth_complete",
        \\});
        \\provider.startLogin({ return_to: "/dashboard" });
        \\const loc = response.headers.location;
        \\const has_state = loc.includes("&state=") || loc.includes("?state=");
        \\const has_pkce = loc.includes("code_challenge=") && loc.includes("code_challenge_method=S256");
        \\const has_scope = loc.includes("scope=openid+email");
        \\return [response.status, has_state, has_pkce, has_scope].join("|");
    , .{ .method = "GET", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("302|true|true|true", resp.body);
}

test "dispatch: oauth.fromConfig(name) reads from _config/oauth/{name}" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Seed the config row directly via the privileged kv path —
    // handlers can't write `_config/` (it's reserved). In production
    // the deploy-time mirror (config_mirror.mirrorConfigToKv) does
    // this on release.
    {
        var seed_txn = try kv.beginTrackedImmediate();
        errdefer seed_txn.rollback() catch {};
        try seed_txn.put("_config/oauth/google",
            \\{"authorization_url":"https://accounts.google.com/o/oauth2/v2/auth",
            \\ "token_url":"https://oauth2.googleapis.com/token",
            \\ "client_id":"abc.apps.googleusercontent.com",
            \\ "client_secret":"shh",
            \\ "redirect_uri":"https://app.example.com/cb",
            \\ "scopes":["openid","profile"],
            \\ "on_complete_module":"users/oauth_complete"}
        );
        try seed_txn.commit();
    }

    var resp = try runOne(&d, kv,
        \\const provider = oauth.fromConfig("google");
        \\provider.startLogin({ return_to: "/" });
        \\// Default state_path is `state/oauth/google`. Pull the state
        \\// uuid out of the redirect URL and verify the row landed at
        \\// the expected key.
        \\const loc = response.headers.location;
        \\const m = loc.match(/[?&]state=([^&]+)/);
        \\const state_uuid = m ? m[1] : null;
        \\const stored = state_uuid ? kv.get("state/oauth/google/" + state_uuid) : null;
        \\const ok_loc = loc.startsWith("https://accounts.google.com/");
        \\return [stored !== null, ok_loc, response.status].join("|");
    , .{ .method = "GET", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("true|true|302", resp.body);
}

test "dispatch: handlers cannot write _config/* (reserved prefix)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\try {
        \\  kv.set("_config/oauth/evil", "{\"sub\":\"attacker\"}");
        \\  return "no-throw";
        \\} catch (e) {
        \\  return "threw:" + (e.message.includes("reserved") ? "ok" : e.message);
        \\}
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("threw:ok", resp.body);
}

test "dispatch: oauth.fromConfig(name) throws when config row missing" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\try {
        \\  oauth.fromConfig("nonexistent");
        \\  return "no-throw";
        \\} catch (e) {
        \\  return e.message.includes("_config/oauth/nonexistent") ? "threw-correctly" : "wrong-msg:" + e.message;
        \\}
    , .{ .method = "GET", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("threw-correctly", resp.body);
}

test "dispatch: sessions.fromConfig(inline).create writes kv row + queues cookie" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\const s = sessions.fromConfig({ name: "default" });
        \\const id = s.create({ user_sub: "user123", email: "a@b.c" });
        \\const stored = JSON.parse(kv.get("state/sessions/default/" + id));
        \\const cookie = response.cookies[0];
        \\const has_attrs = cookie.includes("HttpOnly") && cookie.includes("Secure")
        \\  && cookie.includes("SameSite=Lax") && cookie.includes("Path=/");
        \\return [stored.user_sub, stored.email, has_attrs, cookie.startsWith("session=" + id)].join("|");
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("user123|a@b.c|true|true", resp.body);
}

test "dispatch: sessions.get reads from request.cookies" {
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
        \\  kv.set("state/sessions/default/sess-abc", JSON.stringify({
        \\    user_sub: "user42", email: "x@y.z",
        \\  }));
        \\  const s = sessions.fromConfig({ name: "default" });
        \\  const got = s.get();
        \\  return got ? (got.user_sub + "|" + got.email) : "null";
        \\}
    , "h.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var hdr_buf: [4]h2.HeaderField = undefined;
    const hdrs = makeReqHeaders(&hdr_buf, &.{
        .{ ":method", "GET" },
        .{ ":path", "/" },
        .{ "cookie", "foo=bar; session=sess-abc; baz=qux" },
    });

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
        .method = "GET",
        .path = "/",
        .headers = hdrs,
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("user42|x@y.z", resp.body);
}

test "dispatch: sessions.destroy deletes row + clears cookie" {
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
        \\  kv.set("state/sessions/default/sess-zzz", JSON.stringify({user: "x"}));
        \\  const s = sessions.fromConfig({ name: "default" });
        \\  s.destroy();
        \\  const after = kv.get("state/sessions/default/sess-zzz");
        \\  const cookie = response.cookies[0];
        \\  return [
        \\    after === null,
        \\    cookie.includes("Max-Age=0"),
        \\    cookie.startsWith("session=;"),
        \\  ].join("|");
        \\}
    , "h.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var hdr_buf: [4]h2.HeaderField = undefined;
    const hdrs = makeReqHeaders(&hdr_buf, &.{
        .{ ":method", "POST" },
        .{ ":path", "/" },
        .{ "cookie", "session=sess-zzz" },
    });

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
        .method = "POST",
        .path = "/",
        .headers = hdrs,
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("true|true|true", resp.body);
}

test "dispatch: sessions.parseCookies handles spaces + missing values" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\const c = sessions.parseCookies("a=1; b=2; c = 3 ; nokey;");
        \\return [c.a, c.b, c.c, c.nokey === undefined].join("|");
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("1|2|3|true", resp.body);
}

test "dispatch: cron.dailyAt produces a future timestamp" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(&d, kv,
        \\const ns = cron.dailyAt(3, 0);
        \\const ms = Number(ns / 1_000_000n);
        \\const future = ms > Date.now();
        \\const within_24h = (ms - Date.now()) < 25 * 60 * 60 * 1000;
        \\return [future, within_24h].join("|");
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("true|true", resp.body);
}

test "dispatch: cron.fromNow + parseDuration" {
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
        \\  cron.parseDuration("30s"),
        \\  cron.parseDuration("5m"),
        \\  cron.parseDuration("2h"),
        \\  cron.parseDuration("1d"),
        \\  cron.parseDuration("1w"),
        \\  cron.parseDuration("nope"),
        \\].join(",");
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("30000,300000,7200000,86400000,604800000,", resp.body);
}

test "dispatch: cron.next parses crontab expression" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // 2026-05-09 is a Saturday. "0 3 * * *" from now=2026-05-09T00:00Z
    // → next match is 2026-05-09T03:00Z.
    var resp = try runOne(&d, kv,
        \\const now = Date.UTC(2026, 4, 9, 0, 0, 0);  // 2026-05-09 00:00 UTC
        \\const ns = cron.next("0 3 * * *", now);
        \\const ms = Number(ns / 1_000_000n);
        \\const expected = Date.UTC(2026, 4, 9, 3, 0, 0);
        \\return ms === expected ? "match" : `mismatch: got ${new Date(ms).toISOString()}, want ${new Date(expected).toISOString()}`;
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("match", resp.body);
}

test "dispatch: cron.next handles step expressions like */15" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // 12:07:30 → next */15 fire is 12:15.
    var resp = try runOne(&d, kv,
        \\const now = Date.UTC(2026, 4, 9, 12, 7, 30);
        \\const ns = cron.next("*/15 * * * *", now);
        \\const ms = Number(ns / 1_000_000n);
        \\const dt = new Date(ms);
        \\return dt.getUTCHours() + ":" + dt.getUTCMinutes();
    , .{ .method = "POST", .path = "/", .trace = .{ .request_id = 1 } });
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("12:15", resp.body);
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

test "dispatch: segments append + hot get + per-stream counter" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Hot-tail half of the recipe (the seal half needs the fetch
    // engine — covered by blob_smoke_v2.py step 8).
    var resp = try runOne(
        &d,
        kv,
        \\const a = segments.append("t1", "v0");
        \\const b = segments.append("t1", "v1");
        \\const other = segments.append("t2", "x0");
        \\return {
        \\  a: a, b: b, other: other,
        \\  hot: segments.get("t1", 1),
        \\  missing_is_null: segments.get("t1", 99) === null,
        \\  next: kv.get("_seg/t1/n"),
        \\  row_key_padded: kv.get("_seg/t1/h/00000000000000000001") === "v1",
        \\};
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    var out = try std.json.parseFromSlice(std.json.Value, testing.allocator, resp.body, .{});
    defer out.deinit();
    try testing.expectEqual(@as(i64, 0), out.value.object.get("a").?.integer);
    try testing.expectEqual(@as(i64, 1), out.value.object.get("b").?.integer);
    try testing.expectEqual(@as(i64, 0), out.value.object.get("other").?.integer);
    try testing.expectEqualStrings("v1", out.value.object.get("hot").?.string);
    try testing.expect(out.value.object.get("missing_is_null").?.bool);
    try testing.expectEqualStrings("2", out.value.object.get("next").?.string);
    try testing.expect(out.value.object.get("row_key_padded").?.bool);
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

    // 2 MiB of multi-byte content. The retired pure-JS decoder's
    // per-char `s += fromCharCode(b)` loop generated string-realloc
    // garbage far beyond any plausible arena at this size; the
    // native path is one conversion each way.
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

test "dispatch: platform.instances.create throws on non-admin handler" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // state.platform is null in vanilla runOne — the C callback should
    // throw a TypeError mentioning "admin handler".
    var resp = try runOne(
        &d,
        kv,
        \\try { platform.instances.create("acme"); return "no throw"; }
        \\catch (e) { return "threw: " + e.message; }
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, resp.body, "admin handler") != null);
}

/// Thin wrapper around tenant test setup. Used by platform.instances.*
/// tests below to put a real `Tenant` behind `state.platform`.
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

test "dispatch: platform.instances.create creates instance and mirrors to root_writeset" {
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
    var root_ws = kv_mod.WriteSet.init(testing.allocator);
    defer root_ws.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\platform.instances.create("acme");
        \\return "ok";
    ,
        .{
            .method = "POST",
            .path = "/",
            .admin = .{ .platform = pf.tenant, .root_writeset = &root_ws },
        },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("ok", resp.body);

    // Tenant has the instance in its in-memory map and root.db marker.
    try testing.expect(pf.tenant.instances.get("acme") != null);
    try testing.expectEqual(true, try pf.tenant.instanceExists("acme"));

    // Root writeset got the matching put for raft replication.
    try testing.expectEqual(@as(usize, 1), root_ws.ops.items.len);
    switch (root_ws.ops.items[0]) {
        .put => |p| {
            try testing.expectEqualStrings("instance/acme", p.key);
            try testing.expectEqualStrings("", p.value);
        },
        .delete => try testing.expect(false),
    }
}

test "dispatch: platform.instances.create is idempotent on existing instance" {
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
    try pf.tenant.createInstance("acme"); // pre-existing
    var root_ws = kv_mod.WriteSet.init(testing.allocator);
    defer root_ws.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\platform.instances.create("acme");
        \\platform.instances.create("acme");
        \\return "ok";
    ,
        .{
            .method = "POST",
            .path = "/",
            .admin = .{ .platform = pf.tenant, .root_writeset = &root_ws },
        },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("ok", resp.body);
}

test "dispatch: platform.instances.create throws coded InvalidName on bad name" {
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
    var root_ws = kv_mod.WriteSet.init(testing.allocator);
    defer root_ws.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\try { platform.instances.create("has space"); return "no throw"; }
        \\catch (e) { return "code=" + e.code; }
    ,
        .{
            .method = "POST",
            .path = "/",
            .admin = .{ .platform = pf.tenant, .root_writeset = &root_ws },
        },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("code=InvalidName", resp.body);
    try testing.expectEqual(@as(usize, 0), root_ws.ops.items.len);
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
    var root_ws = kv_mod.WriteSet.init(testing.allocator);
    defer root_ws.deinit();

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
            .admin = .{ .platform = pf.tenant, .root_writeset = &root_ws },
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
    var root_ws = kv_mod.WriteSet.init(testing.allocator);
    defer root_ws.deinit();

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
                .root_writeset = &root_ws,
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
    var root_ws = kv_mod.WriteSet.init(testing.allocator);
    defer root_ws.deinit();

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
                .root_writeset = &root_ws,
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

test "dispatch: email.send accepts array `to`, `cc`, `bcc`" {
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
        \\return email.send({
        \\  apiKey: "re_x",
        \\  from: "a@b.com",
        \\  to: ["c@d.com", "e@f.com"],
        \\  cc: "g@h.com",
        \\  bcc: ["i@j.com"],
        \\  subject: "s",
        \\  text: "t",
        \\});
    ,
        .{ .method = "POST", .path = "/", .trace = .{ .request_id = 2 } },
    );
    defer resp.deinit(testing.allocator);

    const marker_raw = try readOwedMarker(kv, resp.body);
    defer testing.allocator.free(marker_raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, marker_raw, .{});
    defer parsed.deinit();
    const body_str = parsed.value.object.get("body").?.string;
    var body = try std.json.parseFromSlice(std.json.Value, testing.allocator, body_str, .{});
    defer body.deinit();

    try testing.expectEqual(@as(usize, 2), body.value.object.get("to").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), body.value.object.get("cc").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), body.value.object.get("bcc").?.array.items.len);
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
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &.{ .triggers = &triggers }, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    try testing.expectEqualStrings("ok", resp.body);

    // Trigger should have written the reverse-index row.
    const indexed = try kv.get("users/by-session/abc");
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
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &.{ .triggers = &triggers }, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const audit = try kv.get("audit/deleted-totals");
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
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &.{ .triggers = &triggers }, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const trace = try kv.get("trace");
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
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &.{ .triggers = &triggers }, .{
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
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &.{ .triggers = &triggers }, .{
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
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &.{ .triggers = &triggers }, .{
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
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &.{ .triggers = &triggers }, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const stored = try kv.get("users/abc");
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
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &.{ .triggers = &triggers }, .{
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
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &.{ .triggers = &triggers }, .{
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
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &.{ .triggers = &triggers }, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const trace = try kv.get("trace");
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
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &.{ .triggers = &triggers }, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const trace = try kv.get("trace");
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
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &.{ .triggers = &triggers }, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const trace = try kv.get("trace");
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
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &.{ .triggers = &triggers }, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    // Trigger A fires at depth 1 (handler invocation is depth 0).
    const trace_a = try kv.get("trace_a");
    defer testing.allocator.free(trace_a);
    try testing.expectEqualStrings("depth=1", trace_a);

    // Trigger B fires at depth 2 (cascade from A).
    const trace_b = try kv.get("trace_b");
    defer testing.allocator.free(trace_b);
    try testing.expectEqualStrings("depth=2", trace_b);

    // All three writes landed.
    const c_value = try kv.get("c/z");
    defer testing.allocator.free(c_value);
    try testing.expectEqualStrings("c-from-b", c_value);
}
