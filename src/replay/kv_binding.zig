// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The offline engine's delegate behind the common kv binding
//! (`rove-binding`) — the same native `kv.get/set/delete/prefix` the worker
//! registers, installed over arenajs's replay kv object at reactor base
//! setup (`mod_loader.simSetup`).
//!
//! Storage stays exactly where it was: the delegate dispatches through the
//! registered replay-host vtable (`host.setHost`'s mirror), the same
//! indirection arenajs's own kv binding used — so the run host (`host.zig`,
//! closed-world map) and the rewind-test harness host (`harness.zig`, which
//! re-takes the vtable around nested sim runs) both keep serving without
//! knowing the JS surface changed. What DID change is everything above the
//! vtable: coercion, its TypeError, the guard call, the refusal shapes and
//! the result shaping are now the binding's — one implementation with the
//! worker.
//!
//! The per-request JS wrapper (`epilogue.zig`) still runs its own guard
//! calls ahead of this binding for now — double enforcement, same verdicts
//! by the differential test — because the wrapper's trigger chains must stay
//! ORDERED after the guard the way the worker's delegate orders them; they
//! move into this delegate when the wrapper is retired. What this
//! installation already closes: module top-level code (which runs before the
//! per-request wrapper exists) used to see arenajs's guard-free kv — now it
//! sees the guarded binding, like prod's top-level does.

const std = @import("std");
const binding = @import("rove-binding");
const c = @import("qjs_c.zig").c;
const host = @import("host.zig");
const decode = @import("tape_decode.zig");

/// Keys the binding's guards do not judge, because they are not customer
/// writes (the JS evaluator's `isExempt` parameter, stated natively):
///
///   - the harness store namespace — `platform.scope/root` facade keys and
///     the sim's own bookkeeping (`system_recorders.js` NS_STORE);
///   - the parked-output sentinel the epilogue writes through the restored
///     native (`host.OUTPUT_KEY`);
///   - the `_sub/dirty/` markers the epilogue's subscription hook injects
///     via the captured native — the worker's equivalent injection
///     (markSubscriptionsDirty) writes the txn directly, below its binding.
///
/// Reachability note: per-request customer code cannot reach this door — the
/// epilogue's kv wrapper guards `_sub/`-spoofing in JS before the native is
/// called, and the namespace/output keys are filtered there too. Module
/// TOP-LEVEL code can (no wrapper exists yet) — which is narrower than what
/// it had before this binding existed (arenajs's kv object, no guards on any
/// key), and closes entirely when the wrapper's duties move into this
/// delegate.
const STORE_NS = "__rove_store/";

fn exempt(key: []const u8) bool {
    return std.mem.startsWith(u8, key, STORE_NS) or
        std.mem.eql(u8, key, host.OUTPUT_KEY) or
        std.mem.startsWith(u8, key, "_sub/dirty/");
}

pub const OfflineKv = struct {
    ctx: ?*c.JSContext,

    pub fn fromCtx(ctx: ?*c.JSContext) OfflineKv {
        return .{ .ctx = ctx };
    }

    pub fn allocator(_: OfflineKv) std.mem.Allocator {
        return std.heap.c_allocator;
    }

    /// The offline engines have no baked platform modules; nothing that runs
    /// here is `__system/`-trusted.
    pub fn isSystemModule(_: OfflineKv) bool {
        return false;
    }

    pub fn isExempt(_: OfflineKv, key: []const u8) bool {
        return exempt(key);
    }

    fn vtable(self: OfflineKv) ?*const host.ReplayHost {
        _ = self;
        return host.active_vtable;
    }

    /// "tape not installed" / responder-error → the same InternalError family
    /// arenajs's binding raised, so a failure stays legible rather than
    /// becoming a silent absent.
    fn throwHostError(self: OfflineKv, comptime what: []const u8, rc: c_int) void {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "kv.{s}: replay host error (rc={d})", .{ what, rc }) catch "kv: replay host error";
        _ = c.JS_ThrowInternalError(self.ctx, "%s", msg.ptr);
    }

    pub fn get(self: OfflineKv, key: []const u8) binding.GetResult {
        const vt = self.vtable() orelse {
            self.throwHostError("get", 1);
            return .thrown;
        };
        const responder = vt.kv_get orelse {
            self.throwHostError("get", 1);
            return .thrown;
        };
        var outcome: c_int = 0;
        var val: [*c]u8 = null;
        var val_len: c_int = 0;
        const rc = responder(key.ptr, @intCast(key.len), &outcome, &val, &val_len, host.active_user);
        if (rc != 0) {
            if (val != null) std.c.free(val);
            self.throwHostError("get", rc);
            return .thrown;
        }
        switch (@as(decode.KvOutcome, @enumFromInt(outcome))) {
            .ok => {
                // An empty value's buffer is freed here (release() frees by
                // pointer only when the slice is non-empty).
                if (val == null or val_len == 0) {
                    if (val != null) std.c.free(val);
                    return .{ .value = "" };
                }
                return .{ .value = val[0..@intCast(val_len)] };
            },
            .not_found => {
                if (val != null) std.c.free(val);
                return .absent;
            },
            .err => {
                // A recorded failure replays as the failure (arenajs's
                // "recorded failure" spelling).
                if (val != null) std.c.free(val);
                _ = c.JS_ThrowInternalError(self.ctx, "kv.get: recorded failure");
                return .thrown;
            },
        }
    }

    pub fn release(_: OfflineKv, bytes: []const u8) void {
        // Responder buffers are malloc'd by the host (`host.dupC` contract);
        // an empty value never allocated.
        if (bytes.len > 0) std.c.free(@constCast(bytes.ptr));
    }

    pub fn put(self: OfflineKv, _: ?*c.JSContext, key: []const u8, value: []const u8) bool {
        const vt = self.vtable() orelse {
            self.throwHostError("set", 1);
            return false;
        };
        const responder = vt.kv_set orelse {
            self.throwHostError("set", 1);
            return false;
        };
        var outcome: c_int = 0;
        const rc = responder(key.ptr, @intCast(key.len), value.ptr, @intCast(value.len), &outcome, host.active_user);
        if (rc != 0) {
            self.throwHostError("set", rc);
            return false;
        }
        if (outcome == @intFromEnum(decode.KvOutcome.err)) {
            _ = c.JS_ThrowInternalError(self.ctx, "kv.set: recorded failure");
            return false;
        }
        return true;
    }

    pub fn del(self: OfflineKv, _: ?*c.JSContext, key: []const u8) bool {
        const vt = self.vtable() orelse {
            self.throwHostError("delete", 1);
            return false;
        };
        const responder = vt.kv_delete orelse {
            self.throwHostError("delete", 1);
            return false;
        };
        var outcome: c_int = 0;
        const rc = responder(key.ptr, @intCast(key.len), &outcome, host.active_user);
        if (rc != 0) {
            self.throwHostError("delete", rc);
            return false;
        }
        if (outcome == @intFromEnum(decode.KvOutcome.err)) {
            _ = c.JS_ThrowInternalError(self.ctx, "kv.delete: recorded failure");
            return false;
        }
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

    /// The responder returns the page as JSON (`host.zig` builds it; arenajs
    /// parsed it with JS_ParseJSON). The binding shapes the JS array itself,
    /// so parse it here — the rows are what the closed-world map answered.
    pub fn prefix(self: OfflineKv, p: []const u8, cursor: []const u8, limit: u32) ?Page {
        const vt = self.vtable() orelse return null;
        const responder = vt.kv_prefix orelse return null;
        var outcome: c_int = 0;
        var json: [*c]u8 = null;
        var json_len: c_int = 0;
        const rc = responder(
            p.ptr,
            @intCast(p.len),
            cursor.ptr,
            @intCast(cursor.len),
            @intCast(limit),
            &outcome,
            &json,
            &json_len,
            host.active_user,
        );
        if (rc != 0 or json == null) {
            if (json != null) std.c.free(json);
            return null;
        }
        const bytes: []const u8 = json[0..@intCast(json_len)];
        const parsed = std.json.parseFromSlice([]Row, std.heap.c_allocator, bytes, .{}) catch {
            std.c.free(json);
            return null;
        };
        return .{ .parsed = parsed, .json_ptr = json, .entries = parsed.value };
    }
};

const B = binding.Kv(c, OfflineKv);

/// `__rove_poison(what)` — the epilogue's divergence verdict, as a native so
/// the flag lives on the HOST (post-run reportable, interrupt-visible), not
/// in catchable JS. Calling it never throws: the whole point is that a
/// divergence is not an exception a handler can swallow — the read returns
/// absent, this records the verdict, and the uncatchable interrupt brakes
/// the run. A handler calling it directly only poisons its own run.
fn jsPoison(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const undef = c.JSValue{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
    if (argc < 1) {
        host.poisonActive("an input");
        return undef;
    }
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, argv[0]);
    if (cstr == null) {
        host.poisonActive("an input");
        return undef;
    }
    defer c.JS_FreeCString(ctx, cstr);
    host.poisonActive(@as([*]const u8, @ptrCast(cstr))[0..len]);
    return undef;
}

/// Replace arenajs's replay kv object with the common binding. Called from
/// the reactor base-setup hook, after `arena_install_replay_bindings` (which
/// still owns the module loader and the crypto surface).
pub fn installKv(ctx: ?*c.JSContext) c_int {
    const g = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, g);
    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "get", c.JS_NewCFunction2(ctx, B.jsKvGet, "get", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "set", c.JS_NewCFunction2(ctx, B.jsKvSet, "set", 2, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "delete", c.JS_NewCFunction2(ctx, B.jsKvDelete, "delete", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "prefix", c.JS_NewCFunction2(ctx, B.jsKvPrefix, "prefix", 3, c.JS_CFUNC_generic, 0));
    if (c.JS_SetPropertyStr(ctx, g, "kv", obj) < 0) return -1;
    _ = c.JS_SetPropertyStr(ctx, g, "__rove_poison", c.JS_NewCFunction2(ctx, jsPoison, "__rove_poison", 1, c.JS_CFUNC_generic, 0));
    return 0;
}
