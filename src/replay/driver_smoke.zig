// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! End-to-end native driver smoke. Drives `runWorld` — the ONE
//! replay/sim engine — over declarative worlds on the real arenajs link, no
//! cluster. Scenarios: an inbound request (kv.get + kv.set + console + response)
//! and a non-inbound `fetch_chunk` callback (ctx + flattened fetch result).
//! Asserts the emitted bundle reproduces the response, console, and write-set.
//!
//! `multi` argv proves the RESETTABLE runtime: three worlds run back-to-back in
//! ONE process (inbound user=ada → fetch_chunk → inbound user=bob) and each
//! bundle is correct AND isolated — run 3 sees `bob`, never the `ada` from run 1
//! (the request arena is wiped between runs). This is the `simulate()` primitive
//! the scenario driver + JS test runner fold over.
//! Build/run: `zig build replay-driver-smoke`.

const std = @import("std");
const root = @import("root.zig");

const HANDLER =
    \\export default function () {
    \\  const u = kv.get('user');
    \\  kv.set('seen', u);
    \\  console.log('hello ' + u);
    \\  return { status: 200, body: 'hi ' + u };
    \\}
;

const FETCH_HANDLER =
    \\export function onFetchResult() {
    \\  response.status = request.status;
    \\  return {
    \\    upstreamStatus: request.status,
    \\    done: request.done,
    \\    fetchId: request.fetchId,
    \\    ctxAttempt: request.ctx.attempt,
    \\    bodyLen: request.body.length,
    \\  };
    \\}
;

fn check(out: []const u8, need: []const []const u8, forbid: []const []const u8, label: []const u8) void {
    var ok = true;
    for (need) |n| if (std.mem.indexOf(u8, out, n) == null) {
        std.debug.print("{s} MISSING: {s}\n", .{ label, n });
        ok = false;
    };
    for (forbid) |f| if (std.mem.indexOf(u8, out, f) != null) {
        std.debug.print("{s} LEAKED (should be absent): {s}\n", .{ label, f });
        ok = false;
    };
    if (!ok) {
        std.debug.print("{s} FAIL\n", .{label});
        std.process.exit(1);
    }
    std.debug.print("{s} OK\n", .{label});
}

/// Run one inbound world for `user`. `forbid` asserts strings that must NOT
/// appear in this bundle — used by `multi` to prove a later run doesn't leak an
/// earlier run's KV through the (reset) request arena.
fn runInboundUser(a: std.mem.Allocator, user: []const u8, forbid: []const []const u8, label: []const u8) !void {
    var world = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &world);
    const w = &aw.writer;
    try w.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"inbound\",");
    try w.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/hello\",\"host\":\"ex.test\"},");
    try w.writeAll("\"kv\":{\"user\":");
    try std.json.Stringify.value(user, .{}, w);
    try w.writeAll("},\"seed\":42,");
    try w.writeAll("\"expected\":{\"response\":{\"status\":200}},");
    try w.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(HANDLER, .{}, w);
    try w.writeAll("}]}");
    world = aw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.runWorld(a, world.items, null, &out);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(out.items);
    try stdout.writeAll("\n");

    var need_buf: [6][]const u8 = undefined;
    need_buf[0] = "\"verify\":{\"pass\":true";
    need_buf[1] = "\"kind\":\"write\"";
    need_buf[2] = "\"key\":\"seen\"";
    need_buf[3] = try std.fmt.allocPrint(a, "\"value\":\"{s}\"", .{user});
    need_buf[4] = try std.fmt.allocPrint(a, "hello {s}", .{user});
    need_buf[5] = "\"ok\":true";
    check(out.items, &need_buf, forbid, label);
}

fn runInbound(a: std.mem.Allocator) !void {
    try runInboundUser(a, "ada", &.{}, "DRIVER SMOKE");
}

fn runFetchChunk(a: std.mem.Allocator) !void {
    var world = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &world);
    const w = &aw.writer;
    // `captured: true` — this world stands in for a transcoded capture (the
    // handler reads the driver-only `request.body`, retired on authored worlds).
    try w.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"fetch_chunk\",\"export\":\"onFetchResult\",\"captured\":true,");
    try w.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/\",\"host\":\"\",");
    try w.writeAll("\"status\":502,\"done\":true,\"fetchId\":\"ftch_1\",\"body\":\"boom\"},");
    try w.writeAll("\"ctx\":{\"attempt\":2},\"seed\":1,");
    try w.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(FETCH_HANDLER, .{}, w);
    try w.writeAll("}]}");
    world = aw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.runWorld(a, world.items, null, &out);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("FETCH_CHUNK: ");
    try stdout.writeAll(out.items);
    try stdout.writeAll("\n");
    check(out.items, &.{
        "\"upstreamStatus\":502", "\"ctxAttempt\":2", "\"bodyLen\":4",
        "\"done\":true", "\"ok\":true",
    }, &.{}, "FETCH_CHUNK SCENARIO");
}

/// Prove the resettable runtime: three worlds through ONE process. Run 3 must
/// see `bob` and NOT leak `ada` from run 1 — the request arena is wiped between
/// runs, so no KV / allocation crosses. This is the multi-shot `runWorld` the
/// scenario driver + JS test runner depend on.
fn runMulti(a: std.mem.Allocator) !void {
    try runInboundUser(a, "ada", &.{}, "MULTI run1 (inbound ada)");
    try runFetchChunk(a);
    try runInboundUser(a, "bob", &.{"ada"}, "MULTI run3 (inbound bob, no ada leak)");
    std.debug.print("MULTI OK — resettable runtime: 3 runs, 1 process, isolated\n", .{});
}

/// Reads a channel the capture never recorded (`request.ip` on a captured
/// world with no ip on tape), inside a try/catch that would have swallowed
/// the old thrown REPLAY DIVERGENCE. Under the poison model nothing is
/// thrown — the read returns the authored-absent shape (null) and the
/// verdict lands on the host — so `probe` must be "null", never "caught".
const POISON_SWALLOW_HANDLER =
    \\export default function () {
    \\  let probe = "unread";
    \\  try { probe = String(request.ip); } catch (e) { probe = "caught"; }
    \\  return { probe };
    \\}
;

/// Same off-tape read, then an infinite loop — the run is fiction from the
/// divergence on, and the poisoned interrupt must brake it (uncatchably)
/// without waiting for the 5 s CPU budget or reporting its 504 shape.
const POISON_BRAKE_HANDLER =
    \\export default function () {
    \\  try { String(request.ip); } catch (_) {}
    \\  for (;;) {}
    \\}
;

fn runPoison(a: std.mem.Allocator) !void {
    // (a) swallow-proof: the run completes; the verdict survives post-run.
    var world = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &world);
    const w = &aw.writer;
    try w.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"inbound\",\"captured\":true,");
    try w.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/\",\"host\":\"ex.test\"},\"seed\":1,");
    try w.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(POISON_SWALLOW_HANDLER, .{}, w);
    try w.writeAll("}]}");
    world = aw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.runWorld(a, world.items, null, &out);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("POISON_SWALLOW: ");
    try stdout.writeAll(out.items);
    try stdout.writeAll("\n");
    check(out.items, &.{
        "\"divergence\":", "request.ip", "\"ok\":false",
    }, &.{ "caught", "exceeded cpu budget" }, "POISON SWALLOW (verdict survives a try/catch)");

    // (b) the brake: a poisoned run must not burn the whole CPU budget.
    var world2 = std.ArrayList(u8){};
    var aw2 = std.Io.Writer.Allocating.fromArrayList(a, &world2);
    const w2 = &aw2.writer;
    try w2.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"inbound\",\"captured\":true,");
    try w2.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/\",\"host\":\"ex.test\"},\"seed\":1,");
    try w2.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(POISON_BRAKE_HANDLER, .{}, w2);
    try w2.writeAll("}]}");
    world2 = aw2.toArrayList();

    const started_ns = std.time.nanoTimestamp();
    var out2 = std.ArrayList(u8){};
    try root.runWorld(a, world2.items, null, &out2);
    const elapsed_ns = std.time.nanoTimestamp() - started_ns;
    try stdout.writeAll("POISON_BRAKE: ");
    try stdout.writeAll(out2.items);
    try stdout.writeAll("\n");
    check(out2.items, &.{
        "\"divergence\":", "request.ip", "\"ok\":false",
    }, &.{"exceeded cpu budget"}, "POISON BRAKE (uncatchable interrupt, not the 504)");
    // Well under the 5 s budget: the poison poll fires on loop back-edges.
    if (elapsed_ns >= 4 * std.time.ns_per_s) {
        std.debug.print("POISON BRAKE FAIL: took {d} ms — the budget braked it, not the poison\n", .{@divTrunc(elapsed_ns, std.time.ns_per_ms)});
        std.process.exit(1);
    }
    std.debug.print("POISON OK — off-tape reads poison, survive catch, and brake\n", .{});
}

/// Outcome-replay (the engine-parity epic's #516): a captured world throws
/// the refusals its tape recorded and decides NOTHING itself. Two probes:
/// `taped` writes a key today's rules ALLOW but the capture refused — must
/// throw the recorded code; `evolved` writes a key today's rules REFUSE but
/// the capture allowed (no refusal entry) — must succeed, because the tape
/// is faithful to the rules that were live when it was cut.
const REFUSAL_HANDLER =
    \\export default function () {
    \\  const cap = (fn) => { try { fn(); return "ok"; } catch (e) { return (e.code || "?") + "|" + e.message; } };
    \\  const taped = cap(() => kv.set("orders/fine", "v"));
    \\  const evolved = cap(() => kv.set("_secret/allowed-at-capture", "v"));
    \\  const readback = kv.get("_secret/allowed-at-capture");
    \\  return { taped, evolved, readback };
    \\}
;

fn runRefusals(a: std.mem.Allocator) !void {
    var world = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &world);
    const w = &aw.writer;
    try w.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"inbound\",\"captured\":true,");
    try w.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/\",\"host\":\"ex.test\"},\"seed\":1,");
    try w.writeAll("\"kv_refusals\":[{\"op\":\"set\",\"key\":\"orders/fine\",\"code\":\"reserved_key\"}],");
    try w.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(REFUSAL_HANDLER, .{}, w);
    try w.writeAll("}]}");
    world = aw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.runWorld(a, world.items, null, &out);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("REFUSALS: ");
    try stdout.writeAll(out.items);
    try stdout.writeAll("\n");
    check(out.items, &.{
        "\"taped\":\"reserved_key|kv: 'orders/fine' is in a platform-reserved prefix\"",
        "\"evolved\":\"ok\"",
        "\"readback\":\"v\"",
        "\"ok\":true",
    }, &.{"divergence"}, "REFUSAL OUTCOME-REPLAY (taped refusal throws; capture-allowed write proceeds)");
    std.debug.print("REFUSALS OK — captured replay throws the tape's verdicts and re-decides nothing\n", .{});
}

/// The kv budget's read side (rove#430 §3): a captured world whose record
/// says a read's value was ELIDED must refuse the run, not answer it. The
/// closed world's miss rule would say `not_found` — a plausible absence where
/// the live handler read real data, and exactly the shape (#214) that makes a
/// replay lie. Both spellings are probed: a `get` and a `prefix` page.
const ELIDED_HANDLER =
    \\export default function () {
    \\  const v = kv.get("big/blob");
    \\  const page = kv.prefix("feed/", null, 100);
    \\  return { got: v === null ? "absent" : "value", rows: page.length };
    \\}
;

fn runElided(a: std.mem.Allocator) !void {
    var world = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &world);
    const w = &aw.writer;
    try w.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"inbound\",\"captured\":true,");
    try w.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/\",\"host\":\"ex.test\"},\"seed\":1,");
    // A row the map DOES hold under the elided prefix: proof that refusing
    // beats serving the short page the map could reconstruct.
    try w.writeAll("\"kv\":{\"feed/1\":\"kept\"},");
    try w.writeAll("\"kv_elided\":[{\"op\":\"get\",\"key\":\"big/blob\",\"bytes\":900000},");
    try w.writeAll("{\"op\":\"prefix\",\"key\":\"feed/\",\"bytes\":400000}],");
    try w.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(ELIDED_HANDLER, .{}, w);
    try w.writeAll("}]}");
    world = aw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.runWorld(a, world.items, null, &out);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("ELIDED: ");
    try stdout.writeAll(out.items);
    try stdout.writeAll("\n");
    check(out.items, &.{
        "\"divergence\":", "big/blob", "elided", "\"ok\":false",
    }, &.{"exceeded cpu budget"}, "ELIDED READ (a dropped value refuses the run, never answers it)");
    std.debug.print("ELIDED OK — an elided read refuses instead of replaying as absent\n", .{});
}

const SEALED_HANDLER =
    \\export default function () {
    \\  const v = kv.get("card");
    \\  return { got: v === null ? "absent" : v };
    \\}
;

/// A value still SEALED when replay meets it must refuse the run, never be
/// served.
///
/// Serving it would hand the handler ciphertext — a plausible string where
/// the live run saw plaintext — and the divergence would surface as a
/// mismatched output rather than as what it is.
///
/// The world holds the value with its `0xFF` marker, which is what every
/// engine recognises: the marker is not a legal UTF-8 byte, so no plaintext
/// customer value can carry it, and the offline engines can spot one without
/// linking the crypto primitive at all (the browser arena does not link it).
fn runSealed(a: std.mem.Allocator) !void {
    var world = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &world);
    const w = &aw.writer;
    try w.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"inbound\",\"captured\":true,");
    try w.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/\",\"host\":\"ex.test\"},\"seed\":1,");
    // A sealed value CANNOT be carried in the world itself: the world is
    // JSON, JSON strings are Unicode text, and the `0xFF` marker has no
    // representation there — the same property that makes the marker
    // unambiguous makes it unencodable. So the transcode classifies it,
    // and what reaches the world is the refusal, flagged `sealed` to
    // distinguish "the key was destroyed" from "the budget dropped it".
    try w.writeAll("\"kv_elided\":[{\"op\":\"get\",\"key\":\"card\",\"bytes\":41,\"sealed\":true}],");
    try w.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(SEALED_HANDLER, .{}, w);
    try w.writeAll("}]}");
    world = aw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.runWorld(a, world.items, null, &out);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("SEALED: ");
    try stdout.writeAll(out.items);
    try stdout.writeAll("\n");
    check(out.items, &.{
        "\"divergence\":", "card", "shredKey", "\"ok\":false",
    }, &.{"exceeded cpu budget"}, "SEALED READ (a sealed value refuses the run, never serves ciphertext)");
    std.debug.print("SEALED OK — a sealed value refuses instead of replaying as ciphertext\n", .{});
}

/// A handler whose CUMULATIVE allocation (~256 MiB) far exceeds the sim's
/// 100 MiB request arena while its peak live set stays ~1 MiB — it can only
/// complete because the GC arena reclaims the dead strings mid-run. Same shape
/// as prod's own bump/GC discriminator (`snap.zig`), the churn prod's bump→GC
/// retry absorbs; the sim runs GC always, so it completes offline.
const CHURNY_HANDLER =
    \\export default function () {
    \\  let s = "";
    \\  for (let i = 0; i < 256; i++) { s = "x".repeat(1 << 20) + i; }
    \\  return "len=" + s.length;
    \\}
;

/// GC-always: the churny handler completes under GC whether or
/// not the world carries the `arena_gc` regime stamp — the stamp no longer
/// gates the allocator mode — and a normal world afterwards still succeeds
/// (GC does not wedge or leak across the reactor's per-run resets).
fn runArenaGc(a: std.mem.Allocator) !void {
    // Stamped churny world: completes under GC.
    var world = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &world);
    const w = &aw.writer;
    try w.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"inbound\",");
    try w.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/churn\",\"host\":\"ex.test\"},");
    try w.writeAll("\"seed\":7,\"arena_gc\":true,");
    try w.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(CHURNY_HANDLER, .{}, w);
    try w.writeAll("}]}");
    world = aw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.runWorld(a, world.items, null, &out);
    check(out.items, &.{"len=1048579"}, &.{}, "ARENA_GC (stamped churny world completes under GC)");

    // Same execution WITHOUT the stamp: also completes — GC is unconditional,
    // so an authored (unstamped) churny handler is no longer a false OOM.
    var world2 = std.ArrayList(u8){};
    var aw2 = std.Io.Writer.Allocating.fromArrayList(a, &world2);
    const w2 = &aw2.writer;
    try w2.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"inbound\",");
    try w2.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/churn\",\"host\":\"ex.test\"},");
    try w2.writeAll("\"seed\":7,");
    try w2.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(CHURNY_HANDLER, .{}, w2);
    try w2.writeAll("}]}");
    world2 = aw2.toArrayList();
    var out2 = std.ArrayList(u8){};
    try root.runWorld(a, world2.items, null, &out2);
    check(out2.items, &.{"len=1048579"}, &.{}, "ARENA_GC (unstamped churny world also completes under GC)");

    // And a normal world afterwards proves GC neither wedges nor leaks across runs.
    try runInboundUser(a, "eve", &.{}, "ARENA_GC (normal run after churn)");
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Scenario selected by argv. `fetch` = the non-inbound callback; `multi` =
    // several worlds in ONE process (proves the resettable runtime); default =
    // the single inbound scenario.
    const args = try std.process.argsAlloc(a);
    if (args.len > 1 and std.mem.eql(u8, args[1], "fetch")) {
        try runFetchChunk(a);
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "multi")) {
        try runMulti(a);
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "arena-gc")) {
        try runArenaGc(a);
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "poison")) {
        try runPoison(a);
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "refusals")) {
        try runRefusals(a);
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "elided")) {
        try runElided(a);
        try runSealed(a);
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "packages")) {
        try runPackages(a);
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "oauthjwt")) {
        try runOauthJwt(a);
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "cronpkg")) {
        try runCronPkg(a);
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "leafpkgs")) {
        try runLeafPkgs(a);
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "morepkgs")) {
        try runMorePkgs(a);
        return;
    }
    try runInbound(a);
}

/// The rest of the lifted libs (P-Lift, rove#123): users (object-literal leaf),
/// oidc (object-literal → nested `@rewind/jwt`, the 1300-line one), and the
/// IIFE-wrapped schedule (callable) / segments / browser. A consumer imports
/// all five and checks each resolved + loaded with its surface intact. oidc's
/// jwt dep is nested (private, via oidc's `imports`), exercising encapsulation
/// on a big real lib.
fn runMorePkgs(a: std.mem.Allocator) !void {
    const U = "7" ** 64;
    const O = "8" ** 64;
    const SC = "9" ** 64;
    const SE = "a" ** 64;
    const BR = "d" ** 64;
    const JW = "e" ** 64; // oidc's nested jwt
    const HANDLER_SRC =
        \\import users from '@rewind/users';
        \\import oidc from '@rewind/oidc';
        \\import schedule from '@rewind/schedule';
        \\import segments from '@rewind/segments';
        \\import browser from '@rewind/browser';
        \\export default function () {
        \\  return { status: 200, body: {
        \\    usersOk: typeof users === 'object' && typeof users.create === 'function',
        \\    oidcOk: typeof oidc === 'object' && typeof oidc.rp === 'function',
        \\    scheduleOk: typeof schedule === 'function',
        \\    segmentsOk: typeof segments === 'object' && typeof segments.append === 'function',
        \\    browserOk: typeof browser === 'object' && typeof browser.act === 'function',
        \\  } };
        \\}
    ;

    var world = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &world);
    const w = &aw.writer;
    try w.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"inbound\",");
    try w.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/\",\"host\":\"ex.test\"},\"seed\":1,");
    try w.writeAll("\"expected\":{\"response\":{\"status\":200}},");
    try w.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(HANDLER_SRC, .{}, w);
    try w.writeAll("}],");
    try w.print("\"app_imports\":{{\"@rewind/users\":\"{s}\",\"@rewind/oidc\":\"{s}\",\"@rewind/schedule\":\"{s}\",\"@rewind/segments\":\"{s}\",\"@rewind/browser\":\"{s}\"}},", .{ U, O, SC, SE, BR });
    try w.writeAll("\"packages\":[");
    // users (leaf)
    try w.print("{{\"spec\":\"@rewind/users\",\"version\":\"1.0.0\",\"pkg_hash\":\"{s}\",\"files\":{{\"index.mjs\":", .{U});
    try std.json.Stringify.value(@as([]const u8, @embedFile("pkg_users")), .{}, w);
    try w.writeAll("}},");
    // oidc → nested @rewind/jwt (private, via its imports)
    try w.print("{{\"spec\":\"@rewind/oidc\",\"version\":\"1.0.0\",\"pkg_hash\":\"{s}\",\"imports\":{{\"@rewind/jwt\":\"{s}\"}},\"files\":{{\"index.mjs\":", .{ O, JW });
    try std.json.Stringify.value(@as([]const u8, @embedFile("pkg_oidc")), .{}, w);
    try w.writeAll("}},");
    // schedule (IIFE callable), segments (IIFE), browser (IIFE)
    try w.print("{{\"spec\":\"@rewind/schedule\",\"version\":\"1.0.0\",\"pkg_hash\":\"{s}\",\"files\":{{\"index.mjs\":", .{SC});
    try std.json.Stringify.value(@as([]const u8, @embedFile("pkg_schedule")), .{}, w);
    try w.writeAll("}},");
    try w.print("{{\"spec\":\"@rewind/segments\",\"version\":\"1.0.0\",\"pkg_hash\":\"{s}\",\"files\":{{\"index.mjs\":", .{SE});
    try std.json.Stringify.value(@as([]const u8, @embedFile("pkg_segments")), .{}, w);
    try w.writeAll("}},");
    try w.print("{{\"spec\":\"@rewind/browser\",\"version\":\"1.0.0\",\"pkg_hash\":\"{s}\",\"files\":{{\"index.mjs\":", .{BR});
    try std.json.Stringify.value(@as([]const u8, @embedFile("pkg_browser")), .{}, w);
    try w.writeAll("}},");
    // jwt (the nested dep oidc imports)
    try w.print("{{\"spec\":\"@rewind/jwt\",\"version\":\"1.0.0\",\"pkg_hash\":\"{s}\",\"files\":{{\"index.mjs\":", .{JW});
    try std.json.Stringify.value(@as([]const u8, @embedFile("pkg_jwt")), .{}, w);
    try w.writeAll("}}]}");
    world = aw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.runWorld(a, world.items, null, &out);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("MORE_PKGS: ");
    try stdout.writeAll(out.items);
    try stdout.writeAll("\n");
    check(out.items, &.{
        "\"usersOk\":true", "\"oidcOk\":true", "\"scheduleOk\":true",
        "\"segmentsOk\":true", "\"browserOk\":true", "\"verify\":{\"pass\":true",
    }, &.{"\"error\":\"handler"}, "MORE PKGS SCENARIO");
}

/// The object-literal LEAF libs (P-Lift, rove#123): sessions/retry/activitypub
/// lifted `globalThis.X = { … }` → `const X = { … }; export default X`. A
/// consumer imports all three and checks each resolved + loaded with its
/// surface intact — the mechanical repeat of the jwt shape, proving the batch
/// conversion didn't break the modules (syntax / undefined top-level ref).
fn runLeafPkgs(a: std.mem.Allocator) !void {
    const S_HASH = "4" ** 64;
    const R_HASH = "5" ** 64;
    const AP_HASH = "6" ** 64;
    const EM_HASH = "f" ** 64;
    const S_SRC = @embedFile("pkg_sessions");
    const R_SRC = @embedFile("pkg_retry");
    const AP_SRC = @embedFile("pkg_activitypub");
    const EM_SRC = @embedFile("pkg_email");
    const LEAF_HANDLER =
        \\import sessions from '@rewind/sessions';
        \\import retry from '@rewind/retry';
        \\import activitypub from '@rewind/activitypub';
        \\import email from '@rewind/email';
        \\export default function () {
        \\  return { status: 200, body: {
        \\    sessionsOk: typeof sessions === 'object' && typeof sessions.fromConfig === 'function',
        \\    retryOk: typeof retry === 'object' && typeof retry.send === 'function' && typeof retry.again === 'function',
        \\    apOk: typeof activitypub === 'object' && typeof activitypub.fromConfig === 'function',
        \\    emailOk: typeof email === 'object' && typeof email.send === 'function',
        \\  } };
        \\}
    ;

    var world = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &world);
    const w = &aw.writer;
    try w.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"inbound\",");
    try w.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/\",\"host\":\"ex.test\"},\"seed\":1,");
    try w.writeAll("\"expected\":{\"response\":{\"status\":200}},");
    try w.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(LEAF_HANDLER, .{}, w);
    try w.writeAll("}],");
    try w.print("\"app_imports\":{{\"@rewind/sessions\":\"{s}\",\"@rewind/retry\":\"{s}\",\"@rewind/activitypub\":\"{s}\",\"@rewind/email\":\"{s}\"}},", .{ S_HASH, R_HASH, AP_HASH, EM_HASH });
    try w.writeAll("\"packages\":[");
    try w.print("{{\"spec\":\"@rewind/sessions\",\"version\":\"1.0.0\",\"pkg_hash\":\"{s}\",\"files\":{{\"index.mjs\":", .{S_HASH});
    try std.json.Stringify.value(S_SRC, .{}, w);
    try w.writeAll("}},");
    try w.print("{{\"spec\":\"@rewind/retry\",\"version\":\"1.0.0\",\"pkg_hash\":\"{s}\",\"files\":{{\"index.mjs\":", .{R_HASH});
    try std.json.Stringify.value(R_SRC, .{}, w);
    try w.writeAll("}},");
    try w.print("{{\"spec\":\"@rewind/activitypub\",\"version\":\"1.0.0\",\"pkg_hash\":\"{s}\",\"files\":{{\"index.mjs\":", .{AP_HASH});
    try std.json.Stringify.value(AP_SRC, .{}, w);
    try w.writeAll("}},");
    try w.print("{{\"spec\":\"@rewind/email\",\"version\":\"1.0.0\",\"pkg_hash\":\"{s}\",\"files\":{{\"index.mjs\":", .{EM_HASH});
    try std.json.Stringify.value(EM_SRC, .{}, w);
    try w.writeAll("}}]}");
    world = aw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.runWorld(a, world.items, null, &out);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("LEAF_PKGS: ");
    try stdout.writeAll(out.items);
    try stdout.writeAll("\n");
    check(out.items, &.{
        "\"sessionsOk\":true", "\"retryOk\":true", "\"apOk\":true", "\"emailOk\":true", "\"verify\":{\"pass\":true",
    }, &.{"\"error\":\"handler"}, "LEAF PKGS SCENARIO");
}

/// The IIFE-wrapped conversion shape (P-Lift, rove#123): `@rewind/cron` was an
/// ambient global wrapped in an IIFE (to keep its top-level locals out of the
/// base-snapshot's global scope); lifted to a module, the IIFE drops and module
/// scope takes over. Proves the lifted module resolves + runs offline and its
/// static helpers (module-level `_cronHelpers` over the ambient `time` global)
/// still work. Real embedded lifted source.
fn runCronPkg(a: std.mem.Allocator) !void {
    const CRON_HASH = "3" ** 64;
    const CRON_SRC = @embedFile("pkg_cron");
    const CRON_HANDLER =
        \\import cron from '@rewind/cron';
        \\export default function () {
        \\  return { status: 200, body: {
        \\    isFunc: typeof cron === 'function',
        \\    hasNext: typeof cron.next === 'function',
        \\    parseDur: cron.parseDuration('2h'),
        \\    dailyAtOk: cron.dailyAt(3, 0) > 0n,
        \\    hourlyOk: cron.hourly() > 0n,
        \\  } };
        \\}
    ;

    var world = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &world);
    const w = &aw.writer;
    try w.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"inbound\",");
    try w.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/\",\"host\":\"ex.test\"},\"seed\":1,\"now_ms\":1700000000000,");
    try w.writeAll("\"expected\":{\"response\":{\"status\":200}},");
    try w.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(CRON_HANDLER, .{}, w);
    try w.writeAll("}],");
    try w.print("\"app_imports\":{{\"@rewind/cron\":\"{s}\"}},", .{CRON_HASH});
    try w.writeAll("\"packages\":[");
    try w.print("{{\"spec\":\"@rewind/cron\",\"version\":\"1.0.0\",\"pkg_hash\":\"{s}\",\"files\":{{\"index.mjs\":", .{CRON_HASH});
    try std.json.Stringify.value(CRON_SRC, .{}, w);
    try w.writeAll("}}]}");
    world = aw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.runWorld(a, world.items, null, &out);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("CRON_PKG: ");
    try stdout.writeAll(out.items);
    try stdout.writeAll("\n");
    // The IIFE lib lifted to a module: callable, static helpers work over the
    // ambient `time` global (parseDuration("2h") = 7200000).
    check(out.items, &.{
        "\"isFunc\":true", "\"hasNext\":true", "\"parseDur\":7200000",
        "\"dailyAtOk\":true", "\"hourlyOk\":true", "\"verify\":{\"pass\":true",
    }, &.{"\"error\":\"handler"}, "CRON PKG SCENARIO");
}

/// The first REAL intra-set package dependency (P-Lift, rove#123): the lifted
/// `@rewind/oauth` package `import`s the lifted `@rewind/jwt` package (nested /
/// private — reachable only through oauth, not on the app surface) and calls
/// `jwt.verify` from `oauth.verifyIdToken`. A malformed token drives
/// `jwt.verify` to throw, and oauth surfaces jwt's error text — proving the
/// dep graph resolved AND jwt executed inside the encapsulated importer. The
/// package sources are the REAL embedded lifted libs, not synthetic stubs.
fn runOauthJwt(a: std.mem.Allocator) !void {
    const JWT_HASH = "1" ** 64;
    const OAUTH_HASH = "2" ** 64;
    const JWT_SRC = @embedFile("pkg_jwt");
    const OAUTH_SRC = @embedFile("pkg_oauth");
    const OAUTH_HANDLER =
        \\import oauth from '@rewind/oauth';
        \\export default function () {
        \\  kv.set('cache/oauth/test/jwks', JSON.stringify({ keys: [{ kty: 'RSA', kid: 'k1' }] }));
        \\  const r = oauth.verifyIdToken('not-a-jwt', {
        \\    issuer: 'https://issuer.test', client_id: 'client-x',
        \\    jwks_uri: 'https://jwks.test', cache_path: 'cache/oauth/test',
        \\  });
        \\  return { status: 200, body: r };
        \\}
    ;

    var world = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &world);
    const w = &aw.writer;
    try w.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"inbound\",");
    try w.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/\",\"host\":\"ex.test\"},\"seed\":1,");
    try w.writeAll("\"expected\":{\"response\":{\"status\":200}},");
    try w.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(OAUTH_HANDLER, .{}, w);
    try w.writeAll("}],");
    // The app imports ONLY oauth; jwt is nested (private) via oauth's imports.
    try w.print("\"app_imports\":{{\"@rewind/oauth\":\"{s}\"}},", .{OAUTH_HASH});
    try w.writeAll("\"packages\":[");
    try w.print("{{\"spec\":\"@rewind/oauth\",\"version\":\"1.0.0\",\"pkg_hash\":\"{s}\",\"imports\":{{\"@rewind/jwt\":\"{s}\"}},\"files\":{{\"index.mjs\":", .{ OAUTH_HASH, JWT_HASH });
    try std.json.Stringify.value(OAUTH_SRC, .{}, w);
    try w.writeAll("}},");
    try w.print("{{\"spec\":\"@rewind/jwt\",\"version\":\"1.0.0\",\"pkg_hash\":\"{s}\",\"files\":{{\"index.mjs\":", .{JWT_HASH});
    try std.json.Stringify.value(JWT_SRC, .{}, w);
    try w.writeAll("}}]}");
    world = aw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.runWorld(a, world.items, null, &out);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("OAUTH_JWT: ");
    try stdout.writeAll(out.items);
    try stdout.writeAll("\n");
    // oauth loaded (its `import @rewind/jwt` resolved) AND jwt.verify ran — the
    // error text is jwt's, surfaced through oauth's encapsulated dep. (`"ok"`
    // appears twice in the bundle — the handler result `body:{"ok":false,…}`
    // and the run's own top-level `"ok":true`; assert the former's shape.)
    check(out.items, &.{
        "\"body\":{\"ok\":false,\"error\":\"verify: jwt.verify: malformed token\"}",
        "\"verify\":{\"pass\":true",
    }, &.{"\"claims\""}, "OAUTH->JWT SCENARIO");
}

/// Multi-version package encapsulation offline (issue #50), mirroring
/// scripts/smoke/pm_deploy_smoke.py: the app pins @rewind/jwt@1.9 and imports
/// @rewind/oidc@2.0, which pins its OWN @rewind/jwt@1.4. The app must see
/// jwt19 while the encapsulated oidc sees jwt14 — proving the sim resolves
/// per-importer through the shared PackageResolver, exactly as deploy does.
fn runPackages(a: std.mem.Allocator) !void {
    const JWT19 = "b" ** 64;
    const JWT14 = "c" ** 64;
    const OIDC = "a" ** 64;
    const PKG_HANDLER =
        \\import { v as jwtv } from '@rewind/jwt';
        \\import { jwtv as oidcJwt } from '@rewind/oidc';
        \\export default function () {
        \\  return { status: 200, body: { app: jwtv, oidc: oidcJwt } };
        \\}
    ;
    const JWT19_SRC = "export const v = 'jwt19';";
    const JWT14_SRC = "export const v = 'jwt14';";
    const OIDC_SRC = "import { v } from '@rewind/jwt'; export const jwtv = v;";

    var world = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &world);
    const w = &aw.writer;
    try w.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"inbound\",");
    try w.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/\",\"host\":\"ex.test\"},\"seed\":1,");
    try w.writeAll("\"expected\":{\"response\":{\"status\":200}},");
    try w.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(PKG_HANDLER, .{}, w);
    try w.writeAll("}],");
    // App pins jwt 1.9; oidc pins its own jwt 1.4.
    try w.print("\"app_imports\":{{\"@rewind/oidc\":\"{s}\",\"@rewind/jwt\":\"{s}\"}},", .{ OIDC, JWT19 });
    try w.writeAll("\"packages\":[");
    try w.print("{{\"spec\":\"@rewind/jwt\",\"version\":\"1.9.0\",\"pkg_hash\":\"{s}\",\"files\":{{\"index.mjs\":", .{JWT19});
    try std.json.Stringify.value(JWT19_SRC, .{}, w);
    try w.writeAll("}},");
    try w.print("{{\"spec\":\"@rewind/jwt\",\"version\":\"1.4.0\",\"pkg_hash\":\"{s}\",\"files\":{{\"index.mjs\":", .{JWT14});
    try std.json.Stringify.value(JWT14_SRC, .{}, w);
    try w.writeAll("}},");
    try w.print("{{\"spec\":\"@rewind/oidc\",\"version\":\"2.0.0\",\"pkg_hash\":\"{s}\",\"imports\":{{\"@rewind/jwt\":\"{s}\"}},\"files\":{{\"index.mjs\":", .{ OIDC, JWT14 });
    try std.json.Stringify.value(OIDC_SRC, .{}, w);
    try w.writeAll("}}]}");
    world = aw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.runWorld(a, world.items, null, &out);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("PACKAGES: ");
    try stdout.writeAll(out.items);
    try stdout.writeAll("\n");
    // The app sees jwt 1.9; the encapsulated oidc sees its own jwt 1.4.
    check(out.items, &.{
        "\"app\":\"jwt19\"", "\"oidc\":\"jwt14\"",
        "\"verify\":{\"pass\":true", "\"ok\":true",
    }, &.{"jwt14\",\"oidc\":\"jwt19"}, "PACKAGES SCENARIO");
}
