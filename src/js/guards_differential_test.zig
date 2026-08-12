// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The two evaluators of the handler-facing rules agree, on real inputs.
//!
//! `rove-guards` states each rule twice — once as Zig branches the worker
//! calls, once as an emitted JS template the offline engines evaluate. Its
//! constants and messages have one home, so those cannot drift; the control
//! flow is the part that can. This closes that by running both over a corpus
//! and comparing verdicts, which is a behavioural guarantee rather than a
//! structural one, and tests the thing that matters: the answers.
//!
//! Lives in `rove-js` because that is where QJS is already linked. It is the
//! emitted JS that runs here — not the committed generated file — so a stale
//! artifact cannot make this pass; the freshness of the committed copy is a
//! separate assertion in `epilogue.zig`.
//!
//! ## The exemption parameters are deliberately NOT compared
//!
//! Both sides take an escape hatch and they mean different things. The
//! worker's `is_system_module` exempts a baked module from the reserved
//! NAMESPACE only — a platform module writing 2 MiB still breaks the stream
//! frame, so the size caps still apply. The sim's `isExempt` covers its own
//! harness keys, which skip every check because they are not customer writes
//! at all. Those are different questions with the same shape, so this
//! compares the path both engines define identically: an ordinary customer
//! write, no exemption.

const std = @import("std");
const qjs = @import("rove-qjs");
const guards = @import("rove-guards");

const testing = std.testing;

/// A tiny harness appended to the emitted rules: reports what the JS side
/// did as a stable string, so a Zig verdict can be compared to it directly.
const PROBE =
    \\globalThis.__probe = function (kind, a, b) {
    \\  try {
    \\    if (kind === "kvset") __kvGuardWrite(a, true, b, undefined);
    \\    else if (kind === "kvdel") __kvGuardWrite(a, false, undefined, undefined);
    \\    else if (kind === "tag") __tagGuardPair(a, b, 2);
    \\    else if (kind === "cap") __tagGuardCapacity(a);
    \\    return "ok";
    \\  } catch (e) {
    \\    return (e instanceof TypeError ? "TypeError" : "Error") + "|" +
    \\           (e.code || "") + "|" + e.message;
    \\  }
    \\};
;

fn zigVerdictString(a: std.mem.Allocator, v: guards.Verdict, key: []const u8) ![]u8 {
    const r = v orelse return a.dupe(u8, "ok");
    const kind = switch (r.throw) {
        .type_error => "TypeError",
        .err => "Error",
    };
    // The reserved-key message names the key, so it is formatted at the throw
    // site in both engines rather than carried on the verdict.
    const message = if (r.message.len > 0)
        try a.dupe(u8, r.message)
    else
        try std.fmt.allocPrint(a, "kv: '{s}' is in a platform-reserved prefix", .{key});
    defer a.free(message);
    return std.fmt.allocPrint(a, "{s}|{s}|{s}", .{ kind, r.code, message });
}

fn evalStr(ctx: qjs.Context, a: std.mem.Allocator, src: []const u8) ![]u8 {
    // `JS_Eval` takes a length AND requires a NUL-terminated buffer (see
    // `compileToBytecode`'s note) — an ArrayList slice is not one, and the
    // eval fails with a bare JsException that says nothing about why.
    const src_z = try a.dupeZ(u8, src);
    defer a.free(src_z);
    var v = try ctx.eval(src_z, "guards-probe.js", .{});
    defer v.deinit();
    return v.toOwnedString(a);
}

fn jsProbe(ctx: qjs.Context, a: std.mem.Allocator, kind: []const u8, arg_a: []const u8, arg_b: []const u8) ![]u8 {
    const k = try jsonString(a, kind);
    defer a.free(k);
    const x = try jsonString(a, arg_a);
    defer a.free(x);
    const y = try jsonString(a, arg_b);
    defer a.free(y);
    const src = try std.fmt.allocPrint(a, "__probe({s}, {s}, {s})", .{ k, x, y });
    defer a.free(src);
    return evalStr(ctx, a, src);
}

fn jsonString(a: std.mem.Allocator, s: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(a, s, .{});
}

test "guards: the Zig and the emitted JS return the same verdict" {
    const a = testing.allocator;

    var js: std.ArrayList(u8) = .empty;
    defer js.deinit(a);
    try guards.emitJs(js.writer(a));
    try js.appendSlice(a, "\n");
    try js.appendSlice(a, PROBE);

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    {
        const js_z = try a.dupeZ(u8, js.items);
        defer a.free(js_z);
        var v = try ctx.eval(js_z, "guards.js", .{});
        v.deinit();
    }

    const big_key = "k" ** 300;
    const big_val = "v" ** (1024 * 1024 + 8);

    // kv: ordinary, every shim-writable prefix, a reserved one, and both caps
    // — including a key that breaks two rules, which is where an order
    // mismatch would surface.
    const kv_keys = [_][]const u8{
        "orders/1", "a", "_secret/x", "_usage/total", "_send/owed/1",
        "_export/j", "_sched/by_id/1", "_", "_x", big_key, "_secret/" ++ ("k" ** 300),
        // Multi-byte, straddling KV_KEY_MAX (256) by BYTES. This is the one
        // place the two length implementations do different work: Zig takes
        // `s.len` on the already-decoded bytes, JS re-derives via `__utf8Len`
        // over UTF-16 code units. ASCII can't tell them apart; these can.
        "é" ** 128, //         256 bytes exactly — at the cap, allowed
        "é" ** 128 ++ "a", //  257 bytes — one over, key_too_large
        "€" ** 85 ++ "a", //   256 bytes (3×85 + 1) — allowed
        "€" ** 86, //          258 bytes — over
        // Astral: one code point, TWO UTF-16 code units (a surrogate pair) —
        // `__utf8Len` must combine the pair into 4 bytes, not count 3+3.
        "🚀" ** 64, //         256 bytes — allowed
        "🚀" ** 64 ++ "x", //  257 bytes — over
    };
    for (kv_keys) |k| {
        const want = try zigVerdictString(a, guards.checkKvWrite(k, "v", false), k);
        defer a.free(want);
        const got = try jsProbe(ctx, a, "kvset", k, "v");
        defer a.free(got);
        try testing.expectEqualStrings(want, got);

        const want_del = try zigVerdictString(a, guards.checkKvWrite(k, null, false), k);
        defer a.free(want_del);
        const got_del = try jsProbe(ctx, a, "kvdel", k, "");
        defer a.free(got_del);
        try testing.expectEqualStrings(want_del, got_del);
    }

    // …and an oversized VALUE, which only the set path checks.
    {
        const want = try zigVerdictString(a, guards.checkKvWrite("k", big_val, false), "k");
        defer a.free(want);
        const got = try jsProbe(ctx, a, "kvset", "k", big_val);
        defer a.free(got);
        try testing.expectEqualStrings(want, got);
    }

    // tags: one input per rule, plus pairs that break two so the ORDER is
    // compared and not just the set of rules.
    const tag_pairs = [_][2][]const u8{
        .{ "order", "123" },
        .{ "", "v" },
        .{ "k" ** 33, "v" },
        .{ "_x", "v" },
        .{ "Order", "v" },
        .{ "has-dash", "v" },
        .{ "k", "" },
        .{ "k", "v" ** 65 },
        .{ "k", "a\x01b" },
        .{ "_A", "v" },
        .{ "_x", "v" ** 65 },
        .{ "ok", "sp ace" },
        // Multi-byte, same seam as the kv keys above. A tag KEY has a
        // [a-z0-9_] charset rule that runs AFTER the length check, so a
        // multi-byte key exercises both engines' ORDER: over-cap → length
        // wins; under-cap → charset wins. Both must agree which.
        .{ "€" ** 11, "v" }, //   key 33 bytes → length wins (before charset)
        .{ "€" ** 10, "v" }, //   key 30 bytes → passes length, charset wins
        // Tag VALUES have no charset rule, so they test the value-length
        // branch cleanly. Includes the astral/surrogate-pair case.
        .{ "ok", "€" ** 21 }, //  value 63 bytes — allowed
        .{ "ok", "€" ** 22 }, //  value 66 bytes — value length
        .{ "ok", "🚀" ** 16 }, // value 64 bytes (astral) — at cap, allowed
        .{ "ok", "🚀" ** 17 }, // value 68 bytes — over
    };
    for (tag_pairs) |p| {
        const want = try zigVerdictString(a, guards.checkTagPair(p[0], p[1]), p[0]);
        defer a.free(want);
        const got = try jsProbe(ctx, a, "tag", p[0], p[1]);
        defer a.free(got);
        try testing.expectEqualStrings(want, got);
    }

    // capacity, across the boundary
    for ([_]usize{ 0, 1, 3, 4, 5, 99 }) |n| {
        var nbuf: [8]u8 = undefined;
        const ns = try std.fmt.bufPrint(&nbuf, "{d}", .{n});
        const want = try zigVerdictString(a, guards.checkTagCapacity(n), "");
        defer a.free(want);
        const src = try std.fmt.allocPrint(a, "__probe(\"cap\", {s}, 0)", .{ns});
        defer a.free(src);
        const got = try evalStr(ctx, a, src);
        defer a.free(got);
        try testing.expectEqualStrings(want, got);
    }
}
