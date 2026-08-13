// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The browser replay arena's compiled surface — rove's Zig, linked INTO the
//! arenajs wasm (the engine-parity epic's in-tree build). arenajs's reactor
//! calls `rove_arena_install` from its base setup (behind ROVE_ARENA), the
//! same seam the native engines use (`mod_loader.simSetup`), so the arena
//! runs the SAME compiled `rove-binding` + `rove-guards` the worker and the
//! sim run — the last JS evaluator of the rules dies with this module.
//!
//! Storage stays the wasm host's: the delegate calls the same
//! `_arena_host_kv_*` responders arenajs's own kv binding called (EM_JS,
//! implemented in the embedding page's JS — Module.tapes + the write
//! overlay). What moves in-module:
//!
//!   - coercion + guards + refusal shapes + result shaping (the binding);
//!   - effect entries + the prefix rows-fold (binding.Effects — identical
//!     shapes to the native offline delegate's);
//!   - outcome-replay: `decides()` reads the epilogue's
//!     `globalThis.__rove_captured`, taped refusals come from
//!     `globalThis.__rove_refusals` (the epilogue bakes the map);
//!   - the POISON flag — module-linear-memory Zig state, unreachable from
//!     VM JS (a handler can no longer clear its own divergence verdict) —
//!     plus the interrupt brake: arenajs's runtime polls
//!     `rove_arena_interrupted()`, which trips on poison or the CPU budget
//!     (the arena's missing budget, rove#452);
//!   - `request.tag` (binding.Tag) and the `__rove_park_output` /
//!     `__rove_poison` / `__rove_divergence` natives.
//!
//! Per-run state (tags, poison, deadline) resets in `rove_arena_run_begin`,
//! which arenajs calls at every run entry.

const std = @import("std");
const binding = @import("rove-binding");

const c = @cImport({
    @cInclude("quickjs.h");
});

// ── the wasm host responders (EM_JS in qjs-arena-replay-bindings.c) ──────

extern fn _arena_host_kv_get(key: [*c]const u8, key_len: c_int, out_outcome: [*c]c_int, out_val: [*c][*c]u8, out_val_len: [*c]c_int) c_int;
extern fn _arena_host_kv_set(key: [*c]const u8, key_len: c_int, val: [*c]const u8, val_len: c_int, out_outcome: [*c]c_int) c_int;
extern fn _arena_host_kv_delete(key: [*c]const u8, key_len: c_int, out_outcome: [*c]c_int) c_int;
extern fn _arena_host_kv_prefix(prefix: [*c]const u8, prefix_len: c_int, cursor: [*c]const u8, cursor_len: c_int, limit: c_int, out_outcome: [*c]c_int, out_json: [*c][*c]u8, out_json_len: [*c]c_int) c_int;

/// Emscripten's monotonic clock (ms) — the budget's time source.
extern fn emscripten_get_now() f64;

const FX = binding.Effects(c);

/// The harness/store namespace — the same carve-out every offline engine
/// makes (`system_recorders.js` NS_STORE): facade keys are never customer
/// writes and never recorded.
const STORE_NS = "__rove_store/";
const OUTPUT_KEY = "__replay_output__";

fn exempt(key: []const u8) bool {
    return std.mem.startsWith(u8, key, STORE_NS);
}

// ── per-run state (module linear memory — outside the VM) ────────────────

/// First divergence verdict, or null. Host-side on purpose: nothing a
/// handler runs can read or clear it; the epilogue parks it post-run via
/// `__rove_divergence()` and the interrupt brakes on it.
var poison_msg: [512]u8 = undefined;
var poison_len: usize = 0;

/// CPU budget deadline (emscripten_get_now ms); 0 = disarmed. Armed per run
/// from `budget_ms`.
var deadline_ms: f64 = 0;
var budget_ms: f64 = 30_000; // generous default: a browser step-debug run is interactive

const TagPair = struct { key: []u8, value: []u8 };
var tag_list: std.ArrayList(TagPair) = .empty;

/// Called by arenajs at every run entry (arena_run / arena_run_module).
export fn rove_arena_run_begin() void {
    poison_len = 0;
    deadline_ms = if (budget_ms > 0) emscripten_get_now() + budget_ms else 0;
    for (tag_list.items) |t| {
        std.heap.c_allocator.free(t.key);
        std.heap.c_allocator.free(t.value);
    }
    tag_list.clearRetainingCapacity();
}

/// The runtime's interrupt poll: non-zero = uncatchable unwind. Poison is
/// the divergence brake (the run is fiction from the verdict on); the
/// deadline is the arena's CPU budget (rove#452 — a runaway handler used to
/// hang the browser replay where prod and the sim 504).
export fn rove_arena_interrupted() c_int {
    if (poison_len > 0) return 1;
    if (deadline_ms > 0 and emscripten_get_now() >= deadline_ms) return 1;
    return 0;
}

/// Embedder knob (cwrap-exported): ms of CPU per run; <=0 disarms.
export fn rove_arena_set_budget_ms(ms: f64) void {
    budget_ms = ms;
}

fn poison(what: []const u8) void {
    if (poison_len > 0) return; // first verdict wins
    const msg = std.fmt.bufPrint(
        &poison_msg,
        "REPLAY DIVERGENCE: {s} was read by the handler but is not on the capture tape — the handler observed an input the original run never read",
        .{what},
    ) catch blk: {
        const fallback = "REPLAY DIVERGENCE: an off-tape read";
        @memcpy(poison_msg[0..fallback.len], fallback);
        break :blk poison_msg[0..fallback.len];
    };
    poison_len = msg.len;
}

// ── VM-global lookups (the epilogue's per-run knobs) ─────────────────────

/// `globalThis.__rove_captured` — outcome-replay mode. Absent/false =
/// authored (decide live).
fn isCaptured(ctx: ?*c.JSContext) bool {
    const g = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, g);
    const v = c.JS_GetPropertyStr(ctx, g, "__rove_captured");
    defer c.JS_FreeValue(ctx, v);
    return c.JS_ToBool(ctx, v) != 0;
}

/// `globalThis.__rove_refusals["s"/"d" ++ key]` → the taped refusal CODE.
/// Returned as an owned dupe (the JS string is freed here).
fn tapedRefusalLookup(ctx: ?*c.JSContext, op_ch: u8, key: []const u8) ?[]const u8 {
    const g = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, g);
    const map = c.JS_GetPropertyStr(ctx, g, "__rove_refusals");
    defer c.JS_FreeValue(ctx, map);
    if (c.JS_IsObject(map) == false) return null;
    var kbuf: [300]u8 = undefined;
    if (key.len + 2 > kbuf.len) return null;
    kbuf[0] = op_ch;
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = 0;
    const v = c.JS_GetPropertyStr(ctx, map, @ptrCast(&kbuf));
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsString(v) == false) return null;
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, v);
    if (cstr == null) return null;
    defer c.JS_FreeCString(ctx, cstr);
    return std.heap.c_allocator.dupe(u8, @as([*]const u8, @ptrCast(cstr))[0..len]) catch null;
}

// ── the kv delegate ──────────────────────────────────────────────────────

pub const ArenaKv = struct {
    ctx: ?*c.JSContext,

    pub fn fromCtx(ctx: ?*c.JSContext) ArenaKv {
        return .{ .ctx = ctx };
    }

    pub fn allocator(_: ArenaKv) std.mem.Allocator {
        return std.heap.c_allocator;
    }

    /// The arena runs no baked platform modules.
    pub fn isSystemModule(_: ArenaKv) bool {
        return false;
    }

    pub fn isExempt(_: ArenaKv, key: []const u8) bool {
        return exempt(key);
    }

    pub fn decides(self: ArenaKv) bool {
        return !isCaptured(self.ctx);
    }

    /// NOTE the binding treats the returned slice as borrowed for the
    /// duration of the throw — it is an owned dupe leaked to c_allocator
    /// per hit; refusal replays are rare and runs are short-lived.
    pub fn tapedRefusal(self: ArenaKv, op: binding.WriteOp, key: []const u8) ?[]const u8 {
        return tapedRefusalLookup(self.ctx, switch (op) {
            .set => 's',
            .delete => 'd',
        }, key);
    }

    /// The arena produces no tapes.
    pub fn recordRefusal(_: ArenaKv, _: binding.WriteOp, _: []const u8, _: anytype) void {}

    pub fn get(self: ArenaKv, key: []const u8) binding.GetResult {
        var outcome: c_int = 0;
        var val: [*c]u8 = null;
        var val_len: c_int = 0;
        const rc = _arena_host_kv_get(key.ptr, @intCast(key.len), &outcome, &val, &val_len);
        const facade = exempt(key);
        if (rc != 0) {
            if (val != null) std.c.free(val);
            // No entry for this key: authored-absent shape in both modes; a
            // CAPTURED world also records the divergence verdict host-side
            // (the poison model — nothing thrown, nothing catchable).
            if (isCaptured(self.ctx)) poison(key);
            if (!facade) FX.read(self.ctx, key, null);
            return .absent;
        }
        switch (outcome) {
            0 => {
                if (val == null or val_len == 0) {
                    if (val != null) std.c.free(val);
                    if (!facade) FX.read(self.ctx, key, "");
                    return .{ .value = "" };
                }
                const v: []const u8 = val[0..@intCast(val_len)];
                if (!facade) FX.read(self.ctx, key, v);
                return .{ .value = v };
            },
            1 => {
                if (val != null) std.c.free(val);
                if (!facade) FX.read(self.ctx, key, null);
                return .absent;
            },
            else => {
                // A recorded failure replays as the failure.
                if (val != null) std.c.free(val);
                _ = c.JS_ThrowInternalError(self.ctx, "kv.get: recorded failure");
                return .thrown;
            },
        }
    }

    pub fn release(_: ArenaKv, bytes: []const u8) void {
        if (bytes.len > 0) std.c.free(@constCast(bytes.ptr));
    }

    pub fn put(self: ArenaKv, _: ?*c.JSContext, key: []const u8, value: []const u8) bool {
        var outcome: c_int = 0;
        const rc = _arena_host_kv_set(key.ptr, @intCast(key.len), value.ptr, @intCast(value.len), &outcome);
        if (rc != 0) {
            _ = c.JS_ThrowInternalError(self.ctx, "kv.set: replay host error");
            return false;
        }
        if (outcome == 2) {
            _ = c.JS_ThrowInternalError(self.ctx, "kv.set: recorded failure");
            return false;
        }
        if (!exempt(key)) FX.write(self.ctx, key, value);
        return true;
    }

    pub fn del(self: ArenaKv, _: ?*c.JSContext, key: []const u8) bool {
        var outcome: c_int = 0;
        const rc = _arena_host_kv_delete(key.ptr, @intCast(key.len), &outcome);
        if (rc != 0) {
            _ = c.JS_ThrowInternalError(self.ctx, "kv.delete: replay host error");
            return false;
        }
        if (outcome == 2) {
            _ = c.JS_ThrowInternalError(self.ctx, "kv.delete: recorded failure");
            return false;
        }
        if (!exempt(key)) FX.del(self.ctx, key);
        return true;
    }

    const Row = struct { key: []const u8, value: []const u8 };

    pub const Page = struct {
        parsed: std.json.Parsed([]Row),
        json_ptr: [*c]u8,
        entries: []Row,

        pub fn deinit(self: *Page) void {
            self.parsed.deinit();
            std.c.free(self.json_ptr);
        }
    };

    /// The wasm host reconstructs the page (recorded rows ∪ the write
    /// overlay — arenajs#1); rows the handler observes have harness keys
    /// stripped, and the scan records `count` + `rowsFold` like every
    /// engine.
    pub fn prefix(self: ArenaKv, p: []const u8, cursor: []const u8, limit: u32) ?Page {
        var outcome: c_int = 0;
        var json: [*c]u8 = null;
        var json_len: c_int = 0;
        const rc = _arena_host_kv_prefix(p.ptr, @intCast(p.len), cursor.ptr, @intCast(cursor.len), @intCast(limit), &outcome, &json, &json_len);
        if (rc != 0 or json == null) {
            if (json != null) std.c.free(json);
            return null;
        }
        const bytes: []const u8 = json[0..@intCast(json_len)];
        var parsed = std.json.parseFromSlice([]Row, std.heap.c_allocator, bytes, .{}) catch {
            std.c.free(json);
            return null;
        };
        if (exempt(p)) {
            return .{ .parsed = parsed, .json_ptr = json, .entries = parsed.value };
        }
        var n: usize = 0;
        for (parsed.value) |row| {
            if (std.mem.startsWith(u8, row.key, STORE_NS)) continue;
            parsed.value[n] = row;
            n += 1;
        }
        const rows = parsed.value[0..n];
        FX.prefixScan(self.ctx, std.heap.c_allocator, p, rows);
        return .{ .parsed = parsed, .json_ptr = json, .entries = rows };
    }
};

// ── the tag delegate ─────────────────────────────────────────────────────

pub const ArenaTag = struct {
    ctx: ?*c.JSContext,

    pub fn fromCtx(ctx: ?*c.JSContext) ArenaTag {
        return .{ .ctx = ctx };
    }

    pub fn allocator(_: ArenaTag) std.mem.Allocator {
        return std.heap.c_allocator;
    }

    pub fn tagCount(_: ArenaTag) usize {
        return tag_list.items.len;
    }

    pub fn tagUpdate(self: ArenaTag, key: []const u8, val: []const u8) bool {
        for (tag_list.items) |*t| {
            if (std.mem.eql(u8, t.key, key)) {
                const new_v = std.heap.c_allocator.dupe(u8, val) catch return true;
                std.heap.c_allocator.free(t.value);
                t.value = new_v;
                FX.tag(self.ctx, key, val);
                return true;
            }
        }
        return false;
    }

    pub fn tagAppend(self: ArenaTag, key: []const u8, val: []const u8) bool {
        const k = std.heap.c_allocator.dupe(u8, key) catch return false;
        const v = std.heap.c_allocator.dupe(u8, val) catch {
            std.heap.c_allocator.free(k);
            return false;
        };
        tag_list.append(std.heap.c_allocator, .{ .key = k, .value = v }) catch {
            std.heap.c_allocator.free(k);
            std.heap.c_allocator.free(v);
            return false;
        };
        FX.tag(self.ctx, key, val);
        return true;
    }
};

// ── natives ──────────────────────────────────────────────────────────────

const B = binding.Kv(c, ArenaKv);
const T = binding.Tag(c, ArenaTag);

fn undef() c.JSValue {
    // NaN-boxed JS_MKVAL(JS_TAG_UNDEFINED, 0).
    return (@as(u64, @as(u32, @bitCast(@as(i32, c.JS_TAG_UNDEFINED)))) << 32);
}

/// `__rove_poison(what)` — the divergence verdict, flag in MODULE memory
/// (unreachable from VM JS). Never throws.
fn jsPoison(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) {
        poison("an input");
        return undef();
    }
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, argv[0]);
    if (cstr == null) {
        poison("an input");
        return undef();
    }
    defer c.JS_FreeCString(ctx, cstr);
    poison(@as([*]const u8, @ptrCast(cstr))[0..len]);
    return undef();
}

/// `__rove_divergence()` → the verdict string, or null. The epilogue parks
/// it; the shell reads it from the parked output.
fn jsDivergence(ctx: ?*c.JSContext, _: c.JSValue, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
    if (poison_len == 0) {
        // NaN-boxed JS_NULL.
        return (@as(u64, @as(u32, @bitCast(@as(i32, c.JS_TAG_NULL)))) << 32);
    }
    return c.JS_NewStringLen(ctx, &poison_msg, poison_len);
}

/// `__rove_park_output(json)` — the run-output side channel, through the
/// host's kv_set with the sentinel key (the write overlay holds it; the
/// shell reads it back). Not a customer kv write: through the guarded
/// binding the sentinel would be refused like prod refuses it.
fn jsParkOutput(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return undef();
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, argv[0]);
    if (cstr == null) return undef();
    defer c.JS_FreeCString(ctx, cstr);
    var outcome: c_int = 0;
    _ = _arena_host_kv_set(OUTPUT_KEY.ptr, @intCast(OUTPUT_KEY.len), @ptrCast(cstr), @intCast(len), &outcome);
    return undef();
}

/// arenajs's base setup calls this (ROVE_ARENA): install the common binding
/// over the wasm host + the arena natives. The same registration seam the
/// native engines use.
export fn rove_arena_install(ctx: ?*c.JSContext) c_int {
    const g = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, g);
    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "get", c.JS_NewCFunction2(ctx, B.jsKvGet, "get", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "set", c.JS_NewCFunction2(ctx, B.jsKvSet, "set", 2, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "delete", c.JS_NewCFunction2(ctx, B.jsKvDelete, "delete", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "prefix", c.JS_NewCFunction2(ctx, B.jsKvPrefix, "prefix", 3, c.JS_CFUNC_generic, 0));
    if (c.JS_SetPropertyStr(ctx, g, "kv", obj) < 0) return -1;
    _ = c.JS_SetPropertyStr(ctx, g, "__rove_request_tag", c.JS_NewCFunction2(ctx, T.jsRequestTag, "__rove_request_tag", 2, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, g, "__rove_poison", c.JS_NewCFunction2(ctx, jsPoison, "__rove_poison", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, g, "__rove_divergence", c.JS_NewCFunction2(ctx, jsDivergence, "__rove_divergence", 0, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, g, "__rove_park_output", c.JS_NewCFunction2(ctx, jsParkOutput, "__rove_park_output", 1, c.JS_CFUNC_generic, 0));
    return 0;
}
