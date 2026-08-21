// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The common kv binding's customer-visible contract, on a real QJS.
//!
//! `rove-binding` is generic over the engine's quickjs import and its
//! delegate, so it contributes no tests standalone; this instantiates it with
//! a mock delegate here in rove-js — where a real QJS is linked — and asserts
//! the COMMON half: coercion and its TypeError, the guard refusals (shape,
//! code, order), result shaping, argc short-circuits, and the prefix
//! cursor/limit defaulting. The worker delegate's half (txn/writeset/tape/
//! digest) is covered by the worker's own tests and the conformance corpus.

const std = @import("std");
const qjs = @import("rove-qjs");
const binding = @import("rove-binding");
const guards = binding.guards;

const c = qjs.c;
const testing = std.testing;

const MockState = struct {
    a: std.mem.Allocator,
    map: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    system_module: bool = false,
    exempt_prefix: []const u8 = "",
    fail_prefix: bool = false,
    /// The activation's spent write budget, charged by the binding.
    write_ops: u32 = 0,
    write_bytes: usize = 0,
    /// Outcome-replay knobs: `decide` false = captured mode (rules skipped);
    /// a taped refusal replays for exactly this key ("set" op).
    decide: bool = true,
    /// The deployment the mock activation runs under (0 = an authored world).
    config_scope: u64 = 0,
    taped_refusal_key: []const u8 = "",
    taped_refusal_code: []const u8 = "",
    /// The last refusal the binding asked to record (op char + code).
    recorded_refusal_key: [512]u8 = undefined,
    recorded_refusal_key_len: usize = 0,
    recorded_refusal_code: []const u8 = "",
    last_prefix: [64]u8 = undefined,
    last_prefix_len: usize = 0,
    last_cursor: [64]u8 = undefined,
    last_cursor_len: usize = 0,
    last_limit: u32 = 0,

    fn deinit(self: *MockState) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.a.free(e.key_ptr.*);
            self.a.free(e.value_ptr.*);
        }
        self.map.deinit(self.a);
    }
};

const MockKv = struct {
    st: *MockState,

    pub fn fromCtx(ctx: ?*c.JSContext) MockKv {
        return .{ .st = @ptrCast(@alignCast(c.JS_GetContextOpaque(ctx).?)) };
    }

    pub fn allocator(self: MockKv) std.mem.Allocator {
        return self.st.a;
    }

    pub fn isSystemModule(self: MockKv) bool {
        return self.st.system_module;
    }

    pub fn isExempt(self: MockKv, key: []const u8) bool {
        return self.st.exempt_prefix.len > 0 and
            std.mem.startsWith(u8, key, self.st.exempt_prefix);
    }

    /// The activation's spent write budget, on the mock's own state — the
    /// binding charges it through `noteWrite`, so these cases exercise the
    /// same accounting the worker and the offline engines use.
    pub fn writeBudget(self: MockKv) guards.WriteBudget {
        return .{ .ops = self.st.write_ops, .bytes = self.st.write_bytes };
    }

    pub fn noteWrite(self: MockKv, bytes: usize) void {
        self.st.write_ops += 1;
        self.st.write_bytes += bytes;
    }

    pub fn configScope(self: MockKv) u64 {
        return self.st.config_scope;
    }

    pub fn decides(self: MockKv) bool {
        return self.st.decide;
    }

    pub fn tapedRefusal(self: MockKv, op: binding.WriteOp, key: []const u8) ?[]const u8 {
        if (op != .set) return null;
        if (self.st.taped_refusal_key.len == 0 or !std.mem.eql(u8, key, self.st.taped_refusal_key)) return null;
        return self.st.taped_refusal_code;
    }

    pub fn recordRefusal(self: MockKv, _: binding.WriteOp, key: []const u8, refusal: anytype) void {
        const st = self.st;
        @memcpy(st.recorded_refusal_key[0..key.len], key);
        st.recorded_refusal_key_len = key.len;
        st.recorded_refusal_code = refusal.code;
    }

    pub fn get(self: MockKv, key: []const u8) binding.GetResult {
        const v = self.st.map.get(key) orelse return .absent;
        return .{ .value = self.st.a.dupe(u8, v) catch return .absent };
    }

    pub fn release(self: MockKv, bytes: []const u8) void {
        self.st.a.free(bytes);
    }

    pub fn put(self: MockKv, _: ?*c.JSContext, key: []const u8, value: []const u8) bool {
        const st = self.st;
        const vdup = st.a.dupe(u8, value) catch return true;
        if (st.map.getEntry(key)) |e| {
            st.a.free(e.value_ptr.*);
            e.value_ptr.* = vdup;
            return true;
        }
        const kdup = st.a.dupe(u8, key) catch {
            st.a.free(vdup);
            return true;
        };
        st.map.put(st.a, kdup, vdup) catch {
            st.a.free(kdup);
            st.a.free(vdup);
        };
        return true;
    }

    pub fn del(self: MockKv, _: ?*c.JSContext, key: []const u8) bool {
        const st = self.st;
        if (st.map.fetchSwapRemove(key)) |kv| {
            st.a.free(kv.key);
            st.a.free(kv.value);
        }
        return true;
    }

    const Pair = struct { key: []const u8, value: []const u8 };

    pub const Page = struct {
        a: std.mem.Allocator,
        entries: []Pair,

        pub fn deinit(self: *Page) void {
            self.a.free(self.entries);
        }
    };

    pub fn prefix(self: MockKv, p: []const u8, cursor: []const u8, limit: u32) ?Page {
        const st = self.st;
        @memcpy(st.last_prefix[0..p.len], p);
        st.last_prefix_len = p.len;
        @memcpy(st.last_cursor[0..cursor.len], cursor);
        st.last_cursor_len = cursor.len;
        st.last_limit = limit;
        if (st.fail_prefix) return null;

        var list: std.ArrayList(Pair) = .empty;
        var it = st.map.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            if (!std.mem.startsWith(u8, k, p)) continue;
            if (cursor.len != 0 and std.mem.order(u8, k, cursor) != .gt) continue;
            list.append(st.a, .{ .key = k, .value = e.value_ptr.* }) catch return null;
        }
        std.mem.sort(Pair, list.items, {}, struct {
            fn lt(_: void, x: Pair, y: Pair) bool {
                return std.mem.order(u8, x.key, y.key) == .lt;
            }
        }.lt);
        list.shrinkRetainingCapacity(@min(list.items.len, limit));
        return .{ .a = st.a, .entries = list.toOwnedSlice(st.a) catch return null };
    }
};

const B = binding.Kv(c, MockKv);

fn evalStr(ctx: qjs.Context, a: std.mem.Allocator, src: []const u8) ![]u8 {
    // JS_Eval requires a NUL-terminated buffer in addition to the length.
    const src_z = try a.dupeZ(u8, src);
    defer a.free(src_z);
    var v = try ctx.eval(src_z, "kv-binding-test.js", .{});
    defer v.deinit();
    return v.toOwnedString(a);
}

fn expectEval(ctx: qjs.Context, a: std.mem.Allocator, src: []const u8, want: []const u8) !void {
    const got = try evalStr(ctx, a, src);
    defer a.free(got);
    try testing.expectEqualStrings(want, got);
}

/// The probe: run a thunk, report "ok:<json>" or "<class>|<code>|<message>" —
/// the same verdict spelling the guards differential test uses, so the two
/// suites read alike.
const PROBE =
    \\globalThis.__t = (f) => {
    \\  try { const v = f(); return "ok:" + JSON.stringify(v === undefined ? null : v); }
    \\  catch (e) { return (e instanceof TypeError ? "TypeError" : "Error") + "|" + (e.code || "") + "|" + e.message; }
    \\};
    \\"ready"
;

/// Register the binding as the global `kv`, the way an engine does.
fn installKv(ctx: qjs.Context) void {
    const g = c.JS_GetGlobalObject(ctx.raw);
    defer c.JS_FreeValue(ctx.raw, g);
    const obj = c.JS_NewObject(ctx.raw);
    _ = c.JS_SetPropertyStr(ctx.raw, obj, "get", c.JS_NewCFunction2(ctx.raw, B.jsKvGet, "get", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx.raw, obj, "set", c.JS_NewCFunction2(ctx.raw, B.jsKvSet, "set", 2, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx.raw, obj, "delete", c.JS_NewCFunction2(ctx.raw, B.jsKvDelete, "delete", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx.raw, obj, "prefix", c.JS_NewCFunction2(ctx.raw, B.jsKvPrefix, "prefix", 3, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx.raw, g, "kv", obj);
}

test "kv binding: coercion, guards, shaping, paging — the common contract" {
    const a = testing.allocator;

    var st = MockState{ .a = a };
    defer st.deinit();

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    c.JS_SetContextOpaque(ctx.raw, &st);

    installKv(ctx);
    {
        const ready = try evalStr(ctx, a, PROBE);
        defer a.free(ready);
    }

    // ── reads ──
    // Absent → null; the read path coerces ANY key via ToString (kv.get({})
    // reads "[object Object]") — long-standing observable behaviour.
    try expectEval(ctx, a, "__t(() => kv.get('missing'))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.set('[object Object]', 'objval'))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.get({}))", "ok:\"objval\"");

    // ── write coercion: primitives only, TypeError otherwise ──
    try expectEval(ctx, a, "__t(() => kv.set('k', {a:1}))",
        "TypeError||kv: value must be a string (or number/boolean/bigint); JSON.stringify objects explicitly");
    try expectEval(ctx, a, "__t(() => kv.set({}, 'v'))",
        "TypeError||kv: key must be a string (or number/boolean/bigint); JSON.stringify objects explicitly");
    try expectEval(ctx, a, "__t(() => kv.set('k', null))",
        "TypeError||kv: value must be a string (or number/boolean/bigint); JSON.stringify objects explicitly");
    try expectEval(ctx, a, "__t(() => kv.set('k', undefined))",
        "TypeError||kv: value must be a string (or number/boolean/bigint); JSON.stringify objects explicitly");
    try expectEval(ctx, a, "__t(() => kv.delete(null))",
        "TypeError||kv: key must be a string (or number/boolean/bigint); JSON.stringify objects explicitly");
    // Primitives coerce and store.
    try expectEval(ctx, a, "__t(() => kv.set('n', 42))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.get('n'))", "ok:\"42\"");
    try expectEval(ctx, a, "__t(() => kv.set('b', true))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.get('b'))", "ok:\"true\"");

    // ── guard refusals: shape, code, and order ──
    try expectEval(ctx, a, "__t(() => kv.set('_secret/x', 'v'))",
        "Error|reserved_key|kv: '_secret/x' is in a platform-reserved prefix");
    try expectEval(ctx, a, "__t(() => kv.delete('_secret/x'))",
        "Error|reserved_key|kv: '_secret/x' is in a platform-reserved prefix");
    try expectEval(ctx, a, "__t(() => kv.set('_send/owed/abc', 'v'))", "ok:null"); // shim-writable
    try expectEval(ctx, a, "__t(() => kv.set('K'.repeat(257), 'v'))",
        "Error|key_too_large|kv: key exceeds the 256-byte limit");
    try expectEval(ctx, a, "__t(() => kv.set('K'.repeat(256), 'v'))", "ok:null"); // boundary
    try expectEval(ctx, a, "__t(() => kv.set('big', 'x'.repeat((384 * 1024) + 1)))",
        "Error|value_too_large|kv: value exceeds the 393216-byte limit");
    // Order is contract: a key breaking the reserved rule AND the size cap
    // reports reserved_key.
    try expectEval(ctx, a, "__t(() => kv.set('_secret/' + 'k'.repeat(300), 'v'))",
        "Error|reserved_key|kv: '_secret/" ++ "k" ** 300 ++ "' is in a platform-reserved prefix");

    // ── the system-module exemption: namespace only, never the caps ──
    st.system_module = true;
    try expectEval(ctx, a, "__t(() => kv.set('_sched/by_id/x', 'v'))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.set('k', 'x'.repeat((384 * 1024) + 1)))",
        "Error|value_too_large|kv: value exceeds the 393216-byte limit");
    st.system_module = false;

    // ── the per-key exemption: NOT a customer write, EVERY check skipped ──
    // (the offline engines' harness namespace / output sentinel — unlike the
    // system-module exemption, the caps are skipped too, because the key is
    // not subject to the customer contract at all)
    st.exempt_prefix = "__h/";
    try expectEval(ctx, a, "__t(() => kv.set('__h/_secret-ish', 'x'.repeat((1 << 20) + 1)))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.delete('__h/_secret-ish'))", "ok:null");
    // …and a non-matching key is still a customer write.
    try expectEval(ctx, a, "__t(() => kv.set('_secret/y', 'v'))",
        "Error|reserved_key|kv: '_secret/y' is in a platform-reserved prefix");
    st.exempt_prefix = "";

    // ── argc short-circuits: undefined, nothing stored, nothing thrown ──
    try expectEval(ctx, a, "__t(() => kv.get())", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.set('only-key'))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.get('only-key'))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.delete())", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.prefix())", "ok:null");

    // A fresh activation's write budget. The sections above deliberately
    // write past `KV_WRITE_BYTES_MAX` while probing the size caps — in
    // production each of those would be its own activation, and the budget is
    // per activation (`guards.WriteBudget`). Its own coverage is below.
    st.write_ops = 0;
    st.write_bytes = 0;

    // ── prefix: shape, defaulting, capping, cursor ──
    try expectEval(ctx, a, "__t(() => { kv.set('p/1','a'); kv.set('p/2','b'); kv.set('q/1','z'); return 0; })", "ok:0");
    try expectEval(ctx, a, "__t(() => kv.prefix('p/'))", "ok:[{\"key\":\"p/1\",\"value\":\"a\"},{\"key\":\"p/2\",\"value\":\"b\"}]");
    try testing.expectEqual(@as(u32, 100), st.last_limit); // omitted → default
    try testing.expectEqual(@as(usize, 0), st.last_cursor_len);
    try expectEval(ctx, a, "__t(() => kv.prefix('p/', 'p/1', 5000).length)", "ok:1");
    try testing.expectEqual(@as(u32, 1000), st.last_limit); // capped
    try testing.expectEqualStrings("p/1", st.last_cursor[0..st.last_cursor_len]);
    try expectEval(ctx, a, "__t(() => kv.prefix('p/', null, -3).length)", "ok:2");
    try testing.expectEqual(@as(u32, 100), st.last_limit); // non-positive → default
    // Storage error → null, not a throw (a read never throws).
    st.fail_prefix = true;
    try expectEval(ctx, a, "__t(() => kv.prefix('p/'))", "ok:null");
    st.fail_prefix = false;

    // ── delete round-trip ──
    try expectEval(ctx, a, "__t(() => kv.delete('p/1'))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.get('p/1'))", "ok:null");

    // ── the per-activation write budget ──
    // Both halves refuse with a code, and neither is the value cap: these say
    // the ACTIVATION is full, and the way past them is `next()`.
    st.write_ops = 0;
    st.write_bytes = 0;
    try expectEval(ctx, a, "__t(() => { for (let i = 0; i < 5; i++) kv.set('b/' + i, 'x'.repeat(100 * 1024)); return 0; })", "Error|writes_too_large|kv: this activation's writes exceed 409600 bytes — continue the work in a new activation (after.ms + next())");
    // A refused write charges nothing, so a SMALL write after it still fits.
    try expectEval(ctx, a, "__t(() => kv.set('b/small', 'v'))", "ok:null");
    st.write_ops = 0;
    st.write_bytes = 0;
    // The count half, with tiny values so bytes stay nowhere near the cap.
    try expectEval(ctx, a, "__t(() => { for (let i = 0; i < 1001; i++) kv.set('c/' + i, 'v'); return 0; })", "Error|too_many_writes|kv: this activation has made 1000 writes, its limit — continue the work in a new activation (after.ms + next())");
    st.write_ops = 0;
    st.write_bytes = 0;

    // ── outcome-replay (captured worlds) ──
    // A taped refusal replays verbatim, before any rule runs — even for a
    // key today's rules would ALLOW.
    st.taped_refusal_key = "orders/fine";
    st.taped_refusal_code = "reserved_key";
    try expectEval(ctx, a, "__t(() => kv.set('orders/fine', 'v'))",
        "Error|reserved_key|kv: 'orders/fine' is in a platform-reserved prefix");
    // A RETIRED code (rule gone from today's table) still throws, code
    // verbatim, with the generic capture message.
    st.taped_refusal_code = "some_retired_rule";
    try expectEval(ctx, a, "__t(() => kv.set('orders/fine', 'v'))",
        "Error|some_retired_rule|kv: 'orders/fine' was refused at capture");
    st.taped_refusal_key = "";
    // In captured mode (decides = false) the rules are not consulted at all:
    // a write with no taped refusal succeeded at capture and must succeed
    // here, whatever today's table says.
    st.decide = false;
    try expectEval(ctx, a, "__t(() => kv.set('_secret/captured-ok', 'v'))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.get('_secret/captured-ok'))", "ok:\"v\"");
    st.decide = true;
    try expectEval(ctx, a, "__t(() => kv.set('_secret/captured-ok', 'v'))",
        "Error|reserved_key|kv: '_secret/captured-ok' is in a platform-reserved prefix");
    // …and a LIVE refusal is offered to the delegate for taping.
    try testing.expectEqualStrings("_secret/captured-ok", st.recorded_refusal_key[0..st.recorded_refusal_key_len]);
    try testing.expectEqualStrings("reserved_key", st.recorded_refusal_code);
}

test "kv binding: the engine-only keyspace is invisible to a handler" {
    const a = testing.allocator;

    var st = MockState{ .a = a };
    defer st.deinit();

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    c.JS_SetContextOpaque(ctx.raw, &st);
    installKv(ctx);
    {
        const ready = try evalStr(ctx, a, PROBE);
        defer a.free(ready);
    }

    // Seed the way the platform does — engine Zig bypasses these bindings, so
    // the test wears the system-module badge to plant the same rows.
    st.system_module = true;
    for ([_][]const u8{
        "__t(() => kv.set('_usage/blob/aaa', '1'))",
        "__t(() => kv.set('_usage/blob/bbb', '2'))",
        "__t(() => kv.set('_usage/blob/ccc', '3'))",
        "__t(() => kv.set('_keys/next_slot', '9'))",
        "__t(() => kv.set('_config/mail.json', 'cfg'))",
        "__t(() => kv.set('users/1', 'alice'))",
    }) |src| try expectEval(ctx, a, src, "ok:null");
    st.system_module = false;

    // ── get: hidden is ABSENT, not refused ──
    // A refusal would disclose the namespace it is protecting, and a write
    // that silently did nothing is a bug while a read of someone else's
    // keyspace is honestly empty.
    try expectEval(ctx, a, "__t(() => kv.get('_usage/blob/aaa'))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.get('_keys/next_slot'))", "ok:null");
    // Handler-readable platform namespaces are untouched.
    try expectEval(ctx, a, "__t(() => kv.get('_config/mail.json'))", "ok:\"cfg\"");
    try expectEval(ctx, a, "__t(() => kv.get('users/1'))", "ok:\"alice\"");

    // ── a scan wholly inside a hidden namespace never reaches storage ──
    st.last_limit = 0;
    try expectEval(ctx, a, "__t(() => kv.prefix('_usage/'))", "ok:[]");
    try testing.expectEqual(@as(u32, 0), st.last_limit); // the delegate was never called

    // ── a spanning scan filters AND REFILLS ──
    // This is the case a naive filter gets wrong. At limit 2 the first two
    // pages are entirely hidden rows; filtering alone would hand the handler
    // an empty array, and the documented idiom stops on an empty page — so a
    // tenant with a few hundred meter rows would silently lose everything
    // sorted after them. The scan must keep going until the page is full.
    try expectEval(ctx, a, "__t(() => kv.prefix('', '', 2))",
        "ok:[{\"key\":\"_config/mail.json\",\"value\":\"cfg\"},{\"key\":\"users/1\",\"value\":\"alice\"}]");

    // ── the system-module exemption: the platform's own modules still see ──
    st.system_module = true;
    try expectEval(ctx, a, "__t(() => kv.get('_keys/next_slot'))", "ok:\"9\"");
    try expectEval(ctx, a, "__t(() => kv.prefix('_usage/').length)", "ok:3");
    st.system_module = false;

    // ── a captured world replays the read that happened ──
    // `decides()` false means the rules are not consulted, exactly as on the
    // write path: a tape recorded before the namespace was hidden must replay
    // as captured rather than as today's table would answer.
    st.decide = false;
    try expectEval(ctx, a, "__t(() => kv.get('_keys/next_slot'))", "ok:\"9\"");
    st.decide = true;
    try expectEval(ctx, a, "__t(() => kv.get('_keys/next_slot'))", "ok:null");
}
