// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! rove-binding — the common JS↔Zig binding for the handler-facing surfaces,
//! stated once and registered by every native engine.
//!
//! `rove-guards` made the CHECKS one authority; this module makes the whole
//! binding one implementation: JSValue→bytes coercion (and its TypeError),
//! the guard call, the refusal throw, and the shape of the result are the
//! COMMON work — identical by construction in every engine that registers
//! these functions. What genuinely differs per engine is behind a comptime
//! **delegate**: where bytes land, where reads come from, how effects and
//! tape entries are recorded. Comptime rather than a vtable, so the worker's
//! hot path monomorphizes with zero dispatch cost.
//!
//! ## Why the module is generic over `q` (the quickjs C import) too
//!
//! Each engine owns exactly one `@cImport` of the quickjs headers — a second
//! import of the same header mints incompatible opaque types — and the
//! engines do not even link the same artifact: the worker links arenajs's
//! `arenajs` (trace off), the offline engines link `arenajs-replay`. A hard
//! import here would both clash types at every seam and drag the wrong
//! static library into whoever imports this module. So the binding takes the
//! engine's own import instance as `q` and touches C only through it; this
//! module links nothing.
//!
//! A generic-only module contributes no tests when compiled standalone, so
//! the behavioural tests live where a real QJS is linked: `rove-js`'s
//! `kv_binding_test.zig` instantiates `Kv` with a mock delegate over a real
//! context and asserts the customer-visible contract.
//!
//! ## The delegate contract (duck-typed, checked at instantiation)
//!
//! ```
//! fromCtx(ctx: ?*q.JSContext) D          // recover engine state (ctx opaque, …)
//! allocator(d) std.mem.Allocator          // for coercion buffers + messages
//! isSystemModule(d) bool                  // the guard's namespace exemption
//! isExempt(d, key) bool                   // key is NOT a customer write —
//!                                         //   skip every check (the offline
//!                                         //   engines' harness namespace +
//!                                         //   output sentinel; the worker
//!                                         //   returns false: its platform
//!                                         //   writers bypass the binding
//!                                         //   entirely). Same parameter the
//!                                         //   JS-side __kvGuardWrite takes.
//! get(d, key) GetResult                   // value (owned) | absent | thrown
//!                                         //   — the delegate records/tapes/
//!                                         //   folds internally
//! release(d, bytes) void                  // free a get() result
//! put(d, ctx, key, value) bool            // false = a JS exception is pending
//! del(d, ctx, key) bool                   //   (trigger rejection, …)
//! prefix(d, p, cursor, limit) ?Page       // null = storage error → JS null;
//!                                         //   Page has .entries ([]{key,value})
//!                                         //   and deinit()
//! ```
//!
//! `put`/`del` take the context because an engine's post-write machinery may
//! run JS (the worker's kv-trigger chains); `get`/`prefix` deliberately do
//! not. Storage errors inside a delegate are the delegate's to surface the
//! way its engine does (the worker parks them on `pending_kv_error` and the
//! call returns undefined/null — a read must never throw).

const std = @import("std");
const guards = @import("rove-guards");

/// kv.prefix page bounds — prod's, and therefore everyone's: an omitted or
/// non-positive limit defaults to 100, any request is capped at 1000. The
/// native replay host (`src/replay/host.zig`) and the browser arena's wasm
/// host encode the same numbers; this is the binding-side statement of them.
pub const KV_PREFIX_DEFAULT: u32 = 100;
pub const KV_PREFIX_MAX: u32 = 1000;

/// A read's classification, delegate → binding. The worker classifies
/// `{value, absent}` (its storage errors park on the dispatch state and read
/// as absent — a read never throws in prod); an offline engine adds `thrown`
/// for a recorded failure it has already raised on the context. The
/// captured-divergence direction (the poison classification) extends this
/// union rather than adding a read path — see the engine-parity epic.
pub const GetResult = union(enum) {
    value: []const u8,
    absent,
    thrown,
};

pub fn Kv(comptime q: type, comptime D: type) type {
    return struct {
        // quickjs.h defines JS_UNDEFINED etc. as compound-literal macros the
        // C translator cannot expand; reconstruct them. The layout is stable
        // in non-NaN-boxing mode (our Linux x86_64 builds).
        inline fn mkVal(tag: i64, val: i32) q.JSValue {
            return .{ .u = .{ .int32 = val }, .tag = tag };
        }
        const js_undefined: q.JSValue = mkVal(q.JS_TAG_UNDEFINED, 0);
        const js_null: q.JSValue = mkVal(q.JS_TAG_NULL, 0);
        const js_exception: q.JSValue = mkVal(q.JS_TAG_EXCEPTION, 0);

        /// JSValue → owned bytes via the engine allocator, no type
        /// restriction — `kv.get({})` reads the key `"[object Object]"`,
        /// which is long-standing observable behaviour on the read path.
        fn coerce(d: D, ctx: ?*q.JSContext, val: q.JSValue) ![]u8 {
            var len: usize = 0;
            const cstr = q.JS_ToCStringLen(ctx, &len, val);
            if (cstr == null) return error.JsException;
            defer q.JS_FreeCString(ctx, cstr);
            const out = try d.allocator().alloc(u8, len);
            if (len > 0) @memcpy(out, @as([*]const u8, @ptrCast(cstr))[0..len]);
            return out;
        }

        /// Coercion for WRITE inputs: primitives only. A string, number,
        /// boolean, or bigint has one faithful, deterministic string form; an
        /// object/array/typed array would silently mangle ("[object Object]",
        /// a Uint8Array's "1,2,3") and null/undefined at a write site is a
        /// handler bug — all throw TypeError instead of corrupting the
        /// durable store (docs/decisions.md §4.11). The message is the
        /// contract and comes from `rove-guards`, the same authority the
        /// JS-side engines render it from.
        fn coerceWriteArg(
            d: D,
            ctx: ?*q.JSContext,
            val: q.JSValue,
            comptime what: []const u8,
        ) ![]u8 {
            if (q.JS_IsUndefined(val) or q.JS_IsNull(val) or q.JS_IsObject(val)) {
                // comptimePrint re-materializes the guards message as a
                // sentinel-terminated array for the C fmt parameter.
                _ = q.JS_ThrowTypeError(ctx, std.fmt.comptimePrint(
                    "{s}",
                    .{comptime guards.coercionMessage("kv", what)},
                ));
                return error.JsException;
            }
            return coerce(d, ctx, val);
        }

        /// Throw `Error{message, code}` — the branchable shape every kv
        /// refusal has (`err.code === "reserved_key"` etc.).
        fn throwKvError(ctx: ?*q.JSContext, message: []const u8, code: []const u8) q.JSValue {
            const err = q.JS_NewError(ctx);
            if (q.JS_IsException(err)) return err;
            _ = q.JS_SetPropertyStr(ctx, err, "message", q.JS_NewStringLen(ctx, message.ptr, message.len));
            _ = q.JS_SetPropertyStr(ctx, err, "code", q.JS_NewStringLen(ctx, code.ptr, code.len));
            return q.JS_Throw(ctx, err);
        }

        /// Raise a `rove-guards` verdict. The reserved-key message names the
        /// offending key, so the verdict carries an empty message and the
        /// text is formatted here; every other message is a constant the
        /// guards module owns.
        fn throwRefusal(d: D, ctx: ?*q.JSContext, refusal: guards.Refusal, key: []const u8) q.JSValue {
            if (refusal.message.len > 0) return throwKvError(ctx, refusal.message, refusal.code);
            const msg = std.fmt.allocPrint(
                d.allocator(),
                comptime guards.kvReservedMessageFmt(),
                .{key},
            ) catch return q.JS_ThrowOutOfMemory(ctx);
            defer d.allocator().free(msg);
            return throwKvError(ctx, msg, guards.kv_reserved_code);
        }

        pub fn jsKvGet(
            ctx: ?*q.JSContext,
            _: q.JSValue,
            argc: c_int,
            argv: [*c]q.JSValue,
        ) callconv(.c) q.JSValue {
            if (argc < 1) return js_undefined;
            const d = D.fromCtx(ctx);

            const key = coerce(d, ctx, argv[0]) catch return js_exception;
            defer d.allocator().free(key);

            switch (d.get(key)) {
                .value => |v| {
                    defer d.release(v);
                    return q.JS_NewStringLen(ctx, v.ptr, v.len);
                },
                .absent => return js_null,
                .thrown => return js_exception,
            }
        }

        pub fn jsKvSet(
            ctx: ?*q.JSContext,
            _: q.JSValue,
            argc: c_int,
            argv: [*c]q.JSValue,
        ) callconv(.c) q.JSValue {
            if (argc < 2) return js_undefined;
            const d = D.fromCtx(ctx);

            const key = coerceWriteArg(d, ctx, argv[0], "key") catch return js_exception;
            defer d.allocator().free(key);
            const value = coerceWriteArg(d, ctx, argv[1], "value") catch return js_exception;
            defer d.allocator().free(value);

            // ONE call, here, for every engine that registers this binding.
            // The rule order is part of the contract and lives in the guards
            // module, not at any call site. An exempt key is not a customer
            // write at all and skips the table, exactly as the JS evaluator's
            // isExempt parameter does.
            if (!d.isExempt(key)) {
                if (guards.checkKvWrite(key, value, d.isSystemModule())) |refusal| {
                    return throwRefusal(d, ctx, refusal, key);
                }
            }

            if (!d.put(ctx, key, value)) return js_exception;
            return js_undefined;
        }

        pub fn jsKvDelete(
            ctx: ?*q.JSContext,
            _: q.JSValue,
            argc: c_int,
            argv: [*c]q.JSValue,
        ) callconv(.c) q.JSValue {
            if (argc < 1) return js_undefined;
            const d = D.fromCtx(ctx);

            const key = coerceWriteArg(d, ctx, argv[0], "key") catch return js_exception;
            defer d.allocator().free(key);

            // Same rules, same authority — null value: a delete has none to
            // size-check.
            if (!d.isExempt(key)) {
                if (guards.checkKvWrite(key, null, d.isSystemModule())) |refusal| {
                    return throwRefusal(d, ctx, refusal, key);
                }
            }

            if (!d.del(ctx, key)) return js_exception;
            return js_undefined;
        }

        /// `kv.prefix(prefix, cursor?, limit?)` → `[ { key, value }, ... ]`
        /// `cursor` is the last key from a previous page ("" / omitted /
        /// null = from the start); keys strictly greater are returned.
        pub fn jsKvPrefix(
            ctx: ?*q.JSContext,
            _: q.JSValue,
            argc: c_int,
            argv: [*c]q.JSValue,
        ) callconv(.c) q.JSValue {
            if (argc < 1) return js_undefined;
            const d = D.fromCtx(ctx);

            const prefix = coerce(d, ctx, argv[0]) catch return js_exception;
            defer d.allocator().free(prefix);

            const cursor = if (argc >= 2 and !q.JS_IsUndefined(argv[1]) and !q.JS_IsNull(argv[1]))
                coerce(d, ctx, argv[1]) catch return js_exception
            else
                d.allocator().dupe(u8, "") catch return js_exception;
            defer d.allocator().free(cursor);

            const limit: u32 = if (argc >= 3 and !q.JS_IsUndefined(argv[2]) and !q.JS_IsNull(argv[2])) blk: {
                var n: i32 = 0;
                _ = q.JS_ToInt32(ctx, &n, argv[2]);
                if (n <= 0) break :blk KV_PREFIX_DEFAULT;
                break :blk @min(@as(u32, @intCast(n)), KV_PREFIX_MAX);
            } else KV_PREFIX_DEFAULT;

            var page = d.prefix(prefix, cursor, limit) orelse return js_null;
            defer page.deinit();

            const arr = q.JS_NewArray(ctx);
            for (page.entries, 0..) |e, i| {
                const obj = q.JS_NewObject(ctx);
                _ = q.JS_SetPropertyStr(ctx, obj, "key", q.JS_NewStringLen(ctx, e.key.ptr, e.key.len));
                _ = q.JS_SetPropertyStr(ctx, obj, "value", q.JS_NewStringLen(ctx, e.value.ptr, e.value.len));
                _ = q.JS_SetPropertyUint32(ctx, arr, @intCast(i), obj);
            }
            return arr;
        }
    };
}
