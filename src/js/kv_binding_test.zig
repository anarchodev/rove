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
const reserved = guards.reserved;

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

    /// Plant a row the way ENGINE ZIG does — straight into storage, below the
    /// binding, so it carries no root. This is what `_usage/` and `_keys/`
    /// actually look like: rows a handler's capability cannot address.
    fn plant(self: *MockState, key: []const u8, value: []const u8) !void {
        try self.map.put(self.a, try self.a.dupe(u8, key), try self.a.dupe(u8, value));
    }

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

    pub fn get(self: MockKv, k: binding.Key) binding.GetResult {
        const key = k.stored;
        const v = self.st.map.get(key) orelse return .absent;
        return .{ .value = self.st.a.dupe(u8, v) catch return .absent };
    }

    pub fn release(self: MockKv, bytes: []const u8) void {
        self.st.a.free(bytes);
    }

    pub fn put(self: MockKv, _: ?*c.JSContext, k: binding.Key, value: []const u8) bool {
        const key = k.stored;
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

    pub fn del(self: MockKv, _: ?*c.JSContext, k: binding.Key) bool {
        const key = k.stored;
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

    pub fn prefix(self: MockKv, req: binding.Scan) ?Page {
        const p = req.prefix.stored;
        const cursor = req.cursor.stored;
        const limit = req.limit;
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

const B = binding.Kv(c, MockKv, .user);
const BRaw = binding.Kv(c, MockKv, .raw);

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
/// The `.raw` instantiation — what a baked `__system/` activation holds, and
/// what a narrow capability (`config`) is implemented over. Installed as
/// `rawkv` so one context can exercise both roots side by side, which is the
/// only way to state what actually differs between them.
fn installRawKv(ctx: qjs.Context) void {
    const g = c.JS_GetGlobalObject(ctx.raw);
    defer c.JS_FreeValue(ctx.raw, g);
    const obj = c.JS_NewObject(ctx.raw);
    _ = c.JS_SetPropertyStr(ctx.raw, obj, "get", c.JS_NewCFunction2(ctx.raw, BRaw.jsKvGet, "get", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx.raw, obj, "set", c.JS_NewCFunction2(ctx.raw, BRaw.jsKvSet, "set", 2, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx.raw, obj, "prefix", c.JS_NewCFunction2(ctx.raw, BRaw.jsKvPrefix, "prefix", 3, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx.raw, g, "rawkv", obj);
}

fn installConfig(ctx: qjs.Context) void {
    const g = c.JS_GetGlobalObject(ctx.raw);
    defer c.JS_FreeValue(ctx.raw, g);
    const obj = c.JS_NewObject(ctx.raw);
    // Off the USER binding on purpose: the door must escape the root without
    // being an escape hatch, so the root the binding carries must not matter.
    _ = c.JS_SetPropertyStr(ctx.raw, obj, "get", c.JS_NewCFunction2(ctx.raw, B.jsConfigGet, "get", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx.raw, g, "config", obj);
}

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
    try expectEval(ctx, a, "__t(() => kv.set('k', {a:1}))", "TypeError||kv: value must be a string (or number/boolean/bigint); JSON.stringify objects explicitly");
    try expectEval(ctx, a, "__t(() => kv.set({}, 'v'))", "TypeError||kv: key must be a string (or number/boolean/bigint); JSON.stringify objects explicitly");
    try expectEval(ctx, a, "__t(() => kv.set('k', null))", "TypeError||kv: value must be a string (or number/boolean/bigint); JSON.stringify objects explicitly");
    try expectEval(ctx, a, "__t(() => kv.set('k', undefined))", "TypeError||kv: value must be a string (or number/boolean/bigint); JSON.stringify objects explicitly");
    try expectEval(ctx, a, "__t(() => kv.delete(null))", "TypeError||kv: key must be a string (or number/boolean/bigint); JSON.stringify objects explicitly");
    // Primitives coerce and store.
    try expectEval(ctx, a, "__t(() => kv.set('n', 42))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.get('n'))", "ok:\"42\"");
    try expectEval(ctx, a, "__t(() => kv.set('b', true))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.get('b'))", "ok:\"true\"");

    // ── guard refusals: shape, code, and order ──
    // No reserved-prefix refusal: a leading-`_` name is an ordinary key inside
    // the caller's own root (the dedicated case below states why).
    try expectEval(ctx, a, "__t(() => kv.set('_secret/x', 'v'))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.delete('_secret/x'))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.set('_send/owed/abc', 'v'))", "ok:null"); // shim-writable
    try expectEval(ctx, a, "__t(() => kv.set('K'.repeat(257), 'v'))", "Error|key_too_large|kv: key exceeds the 256-byte limit");
    try expectEval(ctx, a, "__t(() => kv.set('K'.repeat(256), 'v'))", "ok:null"); // boundary
    try expectEval(ctx, a, "__t(() => kv.set('big', 'x'.repeat((384 * 1024) + 1)))", "Error|value_too_large|kv: value exceeds the 393216-byte limit");
    // Order is contract: a key breaking the reserved rule AND the size cap
    // reports reserved_key.
    // A long leading-`_` key reports its SIZE — there is no reserved rule left
    // to report first, so the order-is-contract case is now key-size-then-value.
    try expectEval(ctx, a, "__t(() => kv.set('_secret/' + 'k'.repeat(300), 'v'))", "Error|key_too_large|kv: key exceeds the 256-byte limit");

    // ── the system-module exemption: namespace only, never the caps ──
    st.system_module = true;
    try expectEval(ctx, a, "__t(() => kv.set('_sched/by_id/x', 'v'))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.set('k', 'x'.repeat((384 * 1024) + 1)))", "Error|value_too_large|kv: value exceeds the 393216-byte limit");
    st.system_module = false;

    // ── the per-key exemption: NOT a customer write, EVERY check skipped ──
    // (the offline engines' harness namespace / output sentinel — unlike the
    // system-module exemption, the caps are skipped too, because the key is
    // not subject to the customer contract at all)
    st.exempt_prefix = "__h/";
    try expectEval(ctx, a, "__t(() => kv.set('__h/_secret-ish', 'x'.repeat((1 << 20) + 1)))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.delete('__h/_secret-ish'))", "ok:null");
    // …and a non-matching key is still a customer write.
    try expectEval(ctx, a, "__t(() => kv.set('_secret/y', 'v'))", "ok:null");
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
    // The delegate receives the cursor RESOLVED — it is a storage argument,
    // and the caller paged with the visible spelling the binding handed back.
    try testing.expectEqualStrings(
        reserved.USER_KEY_ROOT ++ "p/1",
        st.last_cursor[0..st.last_cursor_len],
    );
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
    try expectEval(ctx, a, "__t(() => kv.set('orders/fine', 'v'))", "Error|reserved_key|kv: 'orders/fine' is in a platform-reserved prefix");
    // A RETIRED code (rule gone from today's table) still throws, code
    // verbatim, with the generic capture message.
    st.taped_refusal_code = "some_retired_rule";
    try expectEval(ctx, a, "__t(() => kv.set('orders/fine', 'v'))", "Error|some_retired_rule|kv: 'orders/fine' was refused at capture");
    st.taped_refusal_key = "";
    // In captured mode (decides = false) the rules are not consulted at all:
    // a write with no taped refusal succeeded at capture and must succeed
    // here, whatever today's table says.
    // Contrasted against a rule that still EXISTS — the reserved-prefix rule
    // is gone, so a leading-`_` key no longer distinguishes the two modes.
    st.decide = false;
    try expectEval(ctx, a, "__t(() => kv.set('captured-ok', 'x'.repeat(2 * 1024 * 1024)))", "ok:null");
    // The captured write CHARGED the activation — it happened. Clear it, or the
    // budget rule fires before the value rule this case is contrasting.
    st.write_ops = 0;
    st.write_bytes = 0;
    st.decide = true;
    try expectEval(
        ctx,
        a,
        "__t(() => kv.set('captured-ok', 'x'.repeat(2 * 1024 * 1024)))",
        "Error|value_too_large|" ++ guards.kv_value_too_large_message,
    );
    // …and a LIVE refusal is offered to the delegate for taping.
    try testing.expectEqualStrings("captured-ok", st.recorded_refusal_key[0..st.recorded_refusal_key_len]);
    try testing.expectEqualStrings("value_too_large", st.recorded_refusal_code);
}

test "kv binding: a handler cannot address the engine keyspace" {
    // The property this replaces: the engine namespaces used to be READ-HIDDEN
    // by a predicate consulted on every get and scan. They are not hidden now —
    // they are unreachable. A handler's capability is rooted at
    // `reserved.USER_KEY_ROOT`, so `_usage/blob/aaa` names a row inside the
    // handler's OWN keyspace and the engine's row of that name is not in the
    // range at all. Nothing is refused and nothing is filtered; there is simply
    // no spelling that arrives there.
    //
    // The consequence worth pinning: the whole leading-`_` keyspace is the
    // customer's again, and it no longer costs a predicate to say so.
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

    // Engine rows, planted below the binding the way platform Zig writes them.
    try st.plant("_usage/blob/aaa", "1");
    try st.plant("_usage/blob/bbb", "2");
    try st.plant("_keys/next_slot", "9");

    // ── the engine's rows are not reachable by naming them ──
    try expectEval(ctx, a, "__t(() => kv.get('_usage/blob/aaa'))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.get('_keys/next_slot'))", "ok:null");

    // ── and naming one is an ordinary write into the handler's own keyspace,
    //    not a refusal. `reserved_key` has no remaining producer here.
    try expectEval(ctx, a, "__t(() => kv.set('_usage/blob/aaa', 'mine'))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.get('_usage/blob/aaa'))", "ok:\"mine\"");

    // The engine's row is untouched by that write — different key, same name.
    try testing.expectEqualStrings("1", st.map.get("_usage/blob/aaa").?);
    try testing.expectEqualStrings(
        "mine",
        st.map.get(reserved.USER_KEY_ROOT ++ "_usage/blob/aaa").?,
    );

    // ── a catch-all scan sees the handler's rows and no engine row, with no
    //    filtering and no refill: they were never in the scanned range. This is
    //    what retires `scanSpansEngineOnly` and `kvPrefixFiltered` — a run of
    //    engine rows can no longer truncate a customer's page, because there is
    //    no run of them to skip.
    try expectEval(ctx, a, "__t(() => kv.set('users/1', 'alice'))", "ok:null");
    try expectEval(
        ctx,
        a,
        "__t(() => kv.prefix('').map(r => r.key).sort().join(','))",
        "ok:\"_usage/blob/aaa,users/1\"",
    );
}
test "config.get is the door: deployment-scoped, read-only, root-independent" {
    // Config is deployment-scoped storage: `config.get("oauth/google")` reads
    // the row the CURRENT deployment shipped, so code and config switch
    // together and a rollback is a pointer flip rather than a race
    // (rove#830 — the only door to `_config/`).
    //
    // The door resolves independently of the binding's root: it is
    // instantiated here off the `.user` binding — the handler's own — and
    // still reaches config, while the same spelling through `kv.*` stays an
    // ordinary key in the handler's keyspace. That is the design: `_config/`
    // is not refused, it is unnameable; the door is the one spelling that
    // means config, and it cannot write.
    const a = testing.allocator;

    var st = MockState{ .a = a };
    defer st.deinit();

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    c.JS_SetContextOpaque(ctx.raw, &st);
    installKv(ctx);
    installRawKv(ctx);
    installConfig(ctx);
    {
        const ready = try evalStr(ctx, a, PROBE);
        defer a.free(ready);
    }

    // Two deployments ship the same config path with different content — the
    // ordinary case of editing `_config/oauth/google.json`. Seeded as the
    // deploy thread's installer writes them: under the deployment, not over
    // each other.
    try st.plant("_config/0000000000000001/oauth/google", "one");
    try st.plant("_config/0000000000000002/oauth/google", "two");

    // ── the deployment decides what the name means ──
    st.config_scope = 1;
    try expectEval(ctx, a, "__t(() => config.get('oauth/google'))", "ok:\"one\"");
    st.config_scope = 2;
    try expectEval(ctx, a, "__t(() => config.get('oauth/google'))", "ok:\"two\"");

    // A deployment that shipped no such config reads absent — the honest
    // answer, and what makes a `fromConfig` wrapper throw its own message
    // rather than silently serving another deployment's value.
    st.config_scope = 3;
    try expectEval(ctx, a, "__t(() => config.get('oauth/google'))", "ok:null");

    // Scope 0 is the authored-world scope: the name resolves to its visible
    // spelling, which is how a sim world seeds config without knowing
    // deployment ids exist.
    try st.plant("_config/authored/flag", "on");
    st.config_scope = 0;
    try expectEval(ctx, a, "__t(() => config.get('authored/flag'))", "ok:\"on\"");

    // ── the same spelling through kv is just a key of the handler's own ──
    st.config_scope = 1;
    try expectEval(ctx, a, "__t(() => kv.get('_config/oauth/google'))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.set('_config/oauth/google', 'mine'))", "ok:null");
    try expectEval(ctx, a, "__t(() => kv.get('_config/oauth/google'))", "ok:\"mine\"");
    // …and it lands beside the handler's other rows, nowhere near config.
    try testing.expectEqualStrings(
        "mine",
        st.map.get(reserved.USER_KEY_ROOT ++ "_config/oauth/google").?,
    );
    // The real row never moved.
    try testing.expectEqualStrings("one", st.map.get("_config/0000000000000001/oauth/google").?);

    // ── the raw binding reads storage as it lies: no resolution ──
    // (The config installer's rows arrive already deployment-scoped, so a
    // resolving raw door would double-scope them.)
    try expectEval(ctx, a, "__t(() => rawkv.get('_config/0000000000000002/oauth/google'))", "ok:\"two\"");
    try expectEval(ctx, a, "__t(() => rawkv.get('_config/oauth/google'))", "ok:null");
}
