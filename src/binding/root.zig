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
//! decides(d) bool                         // false = a CAPTURED world in
//!                                         //   outcome-replay: the rules are
//!                                         //   not re-decided at all — a
//!                                         //   write with no taped refusal
//!                                         //   proceeds, so rule evolution
//!                                         //   cannot manufacture a false
//!                                         //   divergence. Live/authored
//!                                         //   engines return true.
//! tapedRefusal(d, op, key) ?[]const u8    // the refusal CODE the capture
//!                                         //   recorded for this write, or
//!                                         //   null. Checked before the
//!                                         //   rules; a hit replays the
//!                                         //   refusal verbatim.
//! writeBudget(d) guards.WriteBudget      // what THIS ACTIVATION has already
//!                                         //   written (ops + key/value
//!                                         //   bytes). Per activation, never
//!                                         //   per batch: writes accumulate
//!                                         //   into a shared writeset, and a
//!                                         //   busy neighbour must not spend
//!                                         //   this handler's allowance.
//! noteWrite(d, bytes) void                // a write HAPPENED — charge it
//!                                          (`guards.kvWriteCost` bytes, the
//!                                          same figure the check judged).
//!                                         //   Called only after the
//!                                         //   delegate's put/del succeeds,
//!                                         //   so a refused or failed write
//!                                         //   costs nothing.
//! recordRefusal(d, op, key, refusal) void // a live refusal happened — tape
//!                                         //   it (the worker) or ignore it
//!                                         //   (engines that produce no
//!                                         //   tapes). Best-effort.
//! configScope(d) u64                      // the deployment this activation
//!                                         //   runs under, for resolving the
//!                                         //   `_config/` namespace; 0 = an
//!                                         //   authored world with no release
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
/// Re-exported so a delegate in another module can name `guards.WriteBudget`
/// without taking its own dependency on the guards module.
pub const guards = @import("rove-guards");

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

/// Which write surface a refusal belongs to, for taping and replaying it —
/// mirrors the tape's `KvOp` without importing the tape module here.
pub const WriteOp = enum { set, delete };

/// quickjs.h defines JS_UNDEFINED etc. as compound-literal macros the C
/// translator cannot expand; reconstruct them per import instance, branching
/// on the value REPRESENTATION: 64-bit builds carry the {u, tag} struct,
/// 32-bit builds (the wasm arena) NaN-box JSValue into a u64
/// (JS_MKVAL: tag << 32 | (u32)val).
fn Vals(comptime q: type) type {
    return struct {
        inline fn mkVal(tag: i64, val: i32) q.JSValue {
            return switch (@typeInfo(q.JSValue)) {
                .int => (@as(u64, @intCast(@as(u32, @bitCast(@as(i32, @intCast(tag)))))) << 32) |
                    @as(u64, @as(u32, @bitCast(val))),
                else => .{ .u = .{ .int32 = val }, .tag = tag },
            };
        }
        const js_undefined: q.JSValue = mkVal(q.JS_TAG_UNDEFINED, 0);
        const js_null: q.JSValue = mkVal(q.JS_TAG_NULL, 0);
        const js_exception: q.JSValue = mkVal(q.JS_TAG_EXCEPTION, 0);
    };
}

pub fn Kv(comptime q: type, comptime D: type) type {
    return struct {
        const js_undefined = Vals(q).js_undefined;
        const js_null = Vals(q).js_null;
        const js_exception = Vals(q).js_exception;

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

        /// Replay a refusal the CAPTURE recorded (outcome-replay). The code
        /// is the contract a handler branches on; the message is
        /// re-materialized from the current wording for the codes we know,
        /// and a generic sentence for a code whose rule has since been
        /// retired — the code survives verbatim either way, which is what
        /// keeps an old tape's `catch (e) { if (e.code === …) }` path
        /// faithful under rule evolution.
        fn throwTapedRefusal(d: D, ctx: ?*q.JSContext, code: []const u8, key: []const u8) q.JSValue {
            if (std.mem.eql(u8, code, guards.kv_reserved_code)) {
                return throwRefusal(d, ctx, .{ .throw = .err, .code = guards.kv_reserved_code, .message = "" }, key);
            }
            if (std.mem.eql(u8, code, guards.kv_key_too_large_code)) {
                return throwKvError(ctx, guards.kv_key_too_large_message, code);
            }
            if (std.mem.eql(u8, code, guards.kv_value_too_large_code)) {
                return throwKvError(ctx, guards.kv_value_too_large_message, code);
            }
            const msg = std.fmt.allocPrint(
                d.allocator(),
                "kv: '{s}' was refused at capture",
                .{key},
            ) catch return q.JS_ThrowOutOfMemory(ctx);
            defer d.allocator().free(msg);
            return throwKvError(ctx, msg, code);
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

            // The engine-only keyspace is INVISIBLE, not refused
            // (`guards.kvReadHidden`) — so the read answers absent without
            // reaching storage, and nothing about it enters the readset or
            // the digest. Gated on `decides()` like the write table: a
            // captured world replays the read that happened, not the read
            // today's rules would allow.
            if (d.decides() and guards.kvReadHidden(key, d.isSystemModule())) return js_null;

            // `_config/` resolves under the asking activation's deployment.
            var skey_buf: [guards.reserved.CONFIG_STORAGE_KEY_MAX]u8 = undefined;
            const skey = storageKey(d, &skey_buf, key) orelse return js_null;

            switch (d.get(skey)) {
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

            // A refusal the capture recorded replays verbatim, before any
            // rule runs — and when the delegate does not DECIDE (a captured
            // world in outcome-replay), the table is not consulted at all: a
            // write with no taped refusal succeeded at capture and must
            // succeed here, whatever today's rules would say.
            if (d.tapedRefusal(.set, key)) |code| {
                return throwTapedRefusal(d, ctx, code, key);
            }
            // ONE call, here, for every engine that registers this binding.
            // The rule order is part of the contract and lives in the guards
            // module, not at any call site. An exempt key is not a customer
            // write at all and skips the table, exactly as the JS evaluator's
            // isExempt parameter does.
            if (d.decides() and !d.isExempt(key)) {
                if (guards.checkKvWrite(key, value, d.isSystemModule(), d.writeBudget())) |refusal| {
                    d.recordRefusal(.set, key, refusal);
                    return throwRefusal(d, ctx, refusal, key);
                }
            }

            // Rules judge the key a handler NAMED; storage takes the key it
            // resolves to, so a write and a read of the same name reach the
            // same row. Only the mirror writes `_config/` in production, but
            // an asymmetry here is the kind that surfaces years later as a
            // config write nobody can find.
            var skey_buf: [guards.reserved.CONFIG_STORAGE_KEY_MAX]u8 = undefined;
            const skey = storageKey(d, &skey_buf, key) orelse return js_exception;

            if (!d.put(ctx, skey, value)) return js_exception;
            // Spend the activation's budget only on a write that HAPPENED: a
            // refused or failed one costs nothing, or a handler could be
            // starved by writes that never reached the entry. Charged on the
            // key that rides the entry, which is the resolved one.
            d.noteWrite(guards.kvWriteCost(skey.len, value.len));
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

            if (d.tapedRefusal(.delete, key)) |code| {
                return throwTapedRefusal(d, ctx, code, key);
            }
            // Same rules, same authority — null value: a delete has none to
            // size-check.
            if (d.decides() and !d.isExempt(key)) {
                if (guards.checkKvWrite(key, null, d.isSystemModule(), d.writeBudget())) |refusal| {
                    d.recordRefusal(.delete, key, refusal);
                    return throwRefusal(d, ctx, refusal, key);
                }
            }

            var skey_buf: [guards.reserved.CONFIG_STORAGE_KEY_MAX]u8 = undefined;
            const skey = storageKey(d, &skey_buf, key) orelse return js_exception;

            if (!d.del(ctx, skey)) return js_exception;
            // A delete is an op with a key and no value — it rides the entry
            // like any other.
            d.noteWrite(guards.kvWriteCost(skey.len, 0));
            return js_undefined;
        }

        /// Where a `_config/` key LIVES for the activation doing the asking.
        ///
        /// A handler names config by its deployed path; storage holds it under
        /// the deployment that shipped it, so code and config switch at the
        /// same instant (`reserved.configStorageKey`). The rule is shared and
        /// the deployment id is the engine's, which is why this sits in the
        /// binding rather than in four delegates: the spelling a handler uses
        /// must not depend on which engine is running it.
        ///
        /// Returns the key unchanged for everything that is not config, and
        /// for an authored world with no release (`configScope() == 0`).
        fn storageKey(d: D, buf: []u8, key: []const u8) ?[]const u8 {
            if (!guards.reserved.isConfigKey(key)) return key;
            return guards.reserved.configStorageKey(buf, d.configScope(), key);
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

            // Two hidden-aware paths before the plain one. A scan wholly
            // inside an engine-only namespace has nothing visible to return
            // and must not touch storage; a scan that merely SPANS one has to
            // filter AND refill (`reserved.scanSpansEngineOnly`). Every other
            // scan — the overwhelming majority, any prefix that is not an
            // ancestor of a platform namespace — takes the plain path below
            // and pays nothing.
            if (d.decides() and guards.kvScanAllHidden(prefix, d.isSystemModule())) {
                return q.JS_NewArray(ctx);
            }
            if (d.decides() and guards.kvScanFilters(prefix, d.isSystemModule())) {
                return kvPrefixFiltered(d, ctx, prefix, cursor, limit);
            }

            // A scan of the config namespace resolves the same way a get
            // does, so `kv.prefix("_config/")` sees this deployment's rows and
            // not every deployment's.
            var spfx_buf: [guards.reserved.CONFIG_STORAGE_KEY_MAX]u8 = undefined;
            const spfx = storageKey(d, &spfx_buf, prefix) orelse return js_null;

            var page = d.prefix(spfx, cursor, limit) orelse return js_null;
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

        /// `kv.prefix` over a range that contains engine-only keys: skip them,
        /// and keep scanning until the page is full or storage runs out.
        ///
        /// Refilling is the whole point. Filtering a single page would let a
        /// run of hidden rows longer than one page come back EMPTY, and the
        /// documented paging idiom stops on an empty page
        /// (`handler-shape.md` §5.7) — so a tenant with a few hundred meter
        /// rows would see its own scan end early and silently lose everything
        /// sorted after them.
        ///
        /// Each iteration is a separate delegate scan, so it is a separate
        /// taped read; the loop lives in the shared binding precisely so every
        /// engine performs the identical sequence and replay reconstructs it.
        fn kvPrefixFiltered(
            d: D,
            ctx: ?*q.JSContext,
            prefix: []const u8,
            cursor: []const u8,
            limit: u32,
        ) q.JSValue {
            const arr = q.JS_NewArray(ctx);
            var n: u32 = 0;
            // Advances past the last row EXAMINED, hidden rows included, so
            // each pass starts strictly later than the one before and the
            // loop terminates.
            var cur: []u8 = d.allocator().dupe(u8, cursor) catch return js_exception;
            defer d.allocator().free(cur);

            while (n < limit) {
                var page = d.prefix(prefix, cur, limit) orelse return js_null;
                const fetched = page.entries.len;
                var last: ?[]const u8 = null;
                for (page.entries) |e| {
                    if (n >= limit) break;
                    last = e.key;
                    if (guards.kvRowHidden(e.key)) continue;
                    const obj = q.JS_NewObject(ctx);
                    _ = q.JS_SetPropertyStr(ctx, obj, "key", q.JS_NewStringLen(ctx, e.key.ptr, e.key.len));
                    _ = q.JS_SetPropertyStr(ctx, obj, "value", q.JS_NewStringLen(ctx, e.value.ptr, e.value.len));
                    _ = q.JS_SetPropertyUint32(ctx, arr, n, obj);
                    n += 1;
                }
                // Dup before the page's storage goes away.
                const advanced: ?[]u8 = if (last) |l|
                    (d.allocator().dupe(u8, l) catch {
                        page.deinit();
                        return js_exception;
                    })
                else
                    null;
                page.deinit();
                // A short page means storage is exhausted — there is nothing
                // left to refill from, however many rows were filtered.
                if (fetched < limit) {
                    if (advanced) |a| d.allocator().free(a);
                    break;
                }
                if (advanced) |a| {
                    d.allocator().free(cur);
                    cur = a;
                } else break;
            }
            return arr;
        }
    };
}

/// `request.tag(key, value)` — the common binding for the tag surface. The
/// arity/type gate, the pair rules, and the capacity rule (checked only when
/// a call would ADD — re-tagging updates in place, which is engine state and
/// why the guards module splits them) run here, once, in the contract's
/// order. The delegate carries the engine's tag storage and its recording:
///
/// ```
/// fromCtx(ctx) D
/// allocator(d) std.mem.Allocator
/// tagCount(d) usize                       // distinct keys so far
/// tagUpdate(d, key, value) bool           // true = key existed, updated
/// tagAppend(d, key, value) bool           // false = engine failure, a JS
///                                         //   exception is pending
/// ```
pub fn Tag(comptime q: type, comptime D: type) type {
    return struct {
        const js_undefined = Vals(q).js_undefined;
        const js_exception = Vals(q).js_exception;

        pub fn jsRequestTag(
            ctx: ?*q.JSContext,
            _: q.JSValue,
            argc: c_int,
            argv: [*c]q.JSValue,
        ) callconv(.c) q.JSValue {
            const d = D.fromCtx(ctx);
            if (argc < 2 or !q.JS_IsString(argv[0]) or !q.JS_IsString(argv[1])) {
                _ = q.JS_ThrowTypeError(ctx, std.fmt.comptimePrint("{s}", .{guards.tag_args_message}));
                return js_exception;
            }
            const key = coerceVal(d, ctx, argv[0]) catch return js_exception;
            defer d.allocator().free(key);
            const val = coerceVal(d, ctx, argv[1]) catch return js_exception;
            defer d.allocator().free(val);

            // Every pair rule, in the contract's order, from rove-guards.
            if (guards.checkTagPair(key, val)) |refusal| {
                _ = q.JS_ThrowTypeError(ctx, refusal.message.ptr);
                return js_exception;
            }

            if (d.tagUpdate(key, val)) return js_undefined;

            if (guards.checkTagCapacity(d.tagCount())) |refusal| {
                _ = q.JS_ThrowTypeError(ctx, refusal.message.ptr);
                return js_exception;
            }
            if (!d.tagAppend(key, val)) return js_exception;
            return js_undefined;
        }

        fn coerceVal(d: D, ctx: ?*q.JSContext, val: q.JSValue) ![]u8 {
            var len: usize = 0;
            const cstr = q.JS_ToCStringLen(ctx, &len, val);
            if (cstr == null) return error.JsException;
            defer q.JS_FreeCString(ctx, cstr);
            const out = try d.allocator().alloc(u8, len);
            if (len > 0) @memcpy(out, @as([*]const u8, @ptrCast(cstr))[0..len]);
            return out;
        }
    };
}

/// `request.shredKey(id)` — the common binding for the per-identity
/// erasure surface.
///
/// Scopes the whole ACTIVATION: every kv value the handler writes, the
/// readset it rides, the tape and the log record all seal under the key
/// this names, so a later `shredKey` destroy takes all of them together.
/// Calling it again replaces the scope rather than adding one — an
/// activation has exactly one identity, and the per-call override is a
/// separate argument on the write itself, not a second scope here.
///
/// **Late binding is the normal case, and works.** The identity is
/// usually unknown until a cookie is parsed or a token verified, and kv
/// writes stage in the request transaction and commit when the handler
/// returns — so the seal applies at commit under whatever identity was
/// set by then. There is no headers callback and none is needed: the
/// response reaches the wire only after the activation's writes commit.
///
/// The delegate carries the engine's activation state:
///
/// ```
/// fromCtx(ctx) D
/// allocator(d) std.mem.Allocator
/// setShredKey(d, id) bool                 // false = engine failure, a JS
///                                         //   exception is pending
/// ```
pub fn ShredKey(comptime q: type, comptime D: type) type {
    return struct {
        const js_undefined = Vals(q).js_undefined;
        const js_exception = Vals(q).js_exception;

        pub fn jsRequestShredKey(
            ctx: ?*q.JSContext,
            _: q.JSValue,
            argc: c_int,
            argv: [*c]q.JSValue,
        ) callconv(.c) q.JSValue {
            const d = D.fromCtx(ctx);
            if (argc < 1 or !q.JS_IsString(argv[0])) {
                _ = q.JS_ThrowTypeError(ctx, std.fmt.comptimePrint("{s}", .{guards.shred_key_args_message}));
                return js_exception;
            }
            const id = coerceId(d, ctx, argv[0]) catch return js_exception;
            defer d.allocator().free(id);

            if (guards.checkShredKey(id)) |refusal| {
                _ = q.JS_ThrowTypeError(ctx, refusal.message.ptr);
                return js_exception;
            }
            if (!d.setShredKey(id)) return js_exception;
            return js_undefined;
        }

        /// `request.shredKey.destroy(id)` — erase this identity's key.
        ///
        /// Permanent, and unrecoverable by construction: every byte
        /// sealed under it becomes unreadable everywhere at once,
        /// including in backups. That is the point, and it is why this is
        /// a sub-verb of `shredKey` rather than a separate name — a
        /// reader at the call site should see which noun is being
        /// destroyed.
        ///
        /// Capped per activation. Not for resource reasons — erasure
        /// reclaims rather than commits — but because a handler-facing
        /// destroy means a loop with a bug erases customer data nothing
        /// can restore. Refused loudly at the cap rather than truncated:
        /// a handler that asked for more must not be left guessing which
        /// of its calls took effect.
        ///
        /// ```
        /// destroyCount(d) usize                   // destroys so far this activation
        /// destroyShredKey(d, id) bool             // false = engine failure, JS exception pending
        /// ```
        pub fn jsShredKeyDestroy(
            ctx: ?*q.JSContext,
            _: q.JSValue,
            argc: c_int,
            argv: [*c]q.JSValue,
        ) callconv(.c) q.JSValue {
            const d = D.fromCtx(ctx);
            if (argc < 1 or !q.JS_IsString(argv[0])) {
                _ = q.JS_ThrowTypeError(ctx, std.fmt.comptimePrint("{s}", .{guards.shred_destroy_args_message}));
                return js_exception;
            }
            const id = coerceId(d, ctx, argv[0]) catch return js_exception;
            defer d.allocator().free(id);

            // Same identity rules as scoping: one name, one set of rules.
            if (guards.checkShredKey(id)) |refusal| {
                _ = q.JS_ThrowTypeError(ctx, refusal.message.ptr);
                return js_exception;
            }
            // Checked BEFORE the destroy — a refusal after the fact would
            // be a refusal of something that already happened.
            if (guards.checkShredDestroyCap(d.destroyCount())) |refusal| {
                _ = q.JS_ThrowTypeError(ctx, refusal.message.ptr);
                return js_exception;
            }
            if (!d.destroyShredKey(id)) return js_exception;
            return js_undefined;
        }

        fn coerceId(d: D, ctx: ?*q.JSContext, val: q.JSValue) ![]u8 {
            var len: usize = 0;
            const cstr = q.JS_ToCStringLen(ctx, &len, val);
            if (cstr == null) return error.JsException;
            defer q.JS_FreeCString(ctx, cstr);
            const out = try d.allocator().alloc(u8, len);
            if (len > 0) @memcpy(out, @as([*]const u8, @ptrCast(cstr))[0..len]);
            return out;
        }
    };
}

/// The offline engines' effect-log helpers, shared by every delegate that
/// records into the epilogue's `globalThis.__rove_effects` (the native
/// sim/replay delegate and the wasm arena's): entries are pushed through the
/// PATCHED push so the interaction digest folds at the same points JS pushes
/// fold, and the entry shapes are the cross-engine contract (conformance
/// compares them field-strict). The worker records nothing here — its
/// effects are the readset tape + digest folds on its own delegate.
pub fn Effects(comptime q: type) type {
    return struct {
        const digest_mod = @import("interaction-digest");

        fn newStr(ctx: ?*q.JSContext, s: []const u8) q.JSValue {
            return q.JS_NewStringLen(ctx, s.ptr, s.len);
        }

        /// Push one entry through `__rove_effects`' patched push. Consumes
        /// `obj`. Best-effort: with no effect sink installed (a bare run)
        /// the entry is dropped.
        pub fn push(ctx: ?*q.JSContext, obj: q.JSValue) void {
            const g = q.JS_GetGlobalObject(ctx);
            defer q.JS_FreeValue(ctx, g);
            const arr = q.JS_GetPropertyStr(ctx, g, "__rove_effects");
            defer q.JS_FreeValue(ctx, arr);
            if (!q.JS_IsObject(arr)) {
                q.JS_FreeValue(ctx, obj);
                return;
            }
            const pushfn = q.JS_GetPropertyStr(ctx, arr, "push");
            defer q.JS_FreeValue(ctx, pushfn);
            var argv = [1]q.JSValue{obj};
            const r = q.JS_Call(ctx, pushfn, arr, 1, &argv);
            if (q.JS_IsException(r)) {
                // A throwing push must not fail the kv op — clear + continue.
                const ex = q.JS_GetException(ctx);
                q.JS_FreeValue(ctx, ex);
            }
            q.JS_FreeValue(ctx, r);
            q.JS_FreeValue(ctx, obj);
        }

        /// A present read carries its value (the digest folds the real
        /// bytes, like the worker's foldRead); an absent read OMITS the
        /// field rather than spelling it "".
        pub fn read(ctx: ?*q.JSContext, key: []const u8, value: ?[]const u8) void {
            const o = q.JS_NewObject(ctx);
            _ = q.JS_SetPropertyStr(ctx, o, "kind", newStr(ctx, "read"));
            _ = q.JS_SetPropertyStr(ctx, o, "key", newStr(ctx, key));
            _ = q.JS_SetPropertyStr(ctx, o, "present", Vals(q).mkVal(q.JS_TAG_BOOL, @intFromBool(value != null)));
            if (value) |v| _ = q.JS_SetPropertyStr(ctx, o, "value", newStr(ctx, v));
            push(ctx, o);
        }

        pub fn write(ctx: ?*q.JSContext, key: []const u8, value: []const u8) void {
            const o = q.JS_NewObject(ctx);
            _ = q.JS_SetPropertyStr(ctx, o, "kind", newStr(ctx, "write"));
            _ = q.JS_SetPropertyStr(ctx, o, "key", newStr(ctx, key));
            _ = q.JS_SetPropertyStr(ctx, o, "value", newStr(ctx, value));
            push(ctx, o);
        }

        pub fn del(ctx: ?*q.JSContext, key: []const u8) void {
            const o = q.JS_NewObject(ctx);
            _ = q.JS_SetPropertyStr(ctx, o, "kind", newStr(ctx, "delete"));
            _ = q.JS_SetPropertyStr(ctx, o, "key", newStr(ctx, key));
            push(ctx, o);
        }

        pub fn tag(ctx: ?*q.JSContext, key: []const u8, value: []const u8) void {
            const o = q.JS_NewObject(ctx);
            _ = q.JS_SetPropertyStr(ctx, o, "kind", newStr(ctx, "tag"));
            _ = q.JS_SetPropertyStr(ctx, o, "key", newStr(ctx, key));
            _ = q.JS_SetPropertyStr(ctx, o, "value", newStr(ctx, value));
            push(ctx, o);
        }

        /// `count` + `rowsFold` (`key=<valuehash>;` per row IN ORDER,
        /// lowercase hex) — the same accumulator the worker folds
        /// (globals_kv.foldPrefix), over the rows the handler observes.
        pub fn prefixScan(ctx: ?*q.JSContext, a: std.mem.Allocator, p: []const u8, entries: anytype) void {
            var acc: std.ArrayList(u8) = .empty;
            defer acc.deinit(a);
            var acc_ok = true;
            for (entries) |e| {
                acc.writer(a).print("{s}={x};", .{ e.key, digest_mod.foldValue(e.value) }) catch {
                    acc_ok = false;
                    break;
                };
            }
            if (!acc_ok) return;
            var fold_buf: [16]u8 = undefined;
            const fold_hex = std.fmt.bufPrint(&fold_buf, "{x}", .{digest_mod.foldValue(acc.items)}) catch return;
            const o = q.JS_NewObject(ctx);
            _ = q.JS_SetPropertyStr(ctx, o, "kind", newStr(ctx, "read"));
            _ = q.JS_SetPropertyStr(ctx, o, "op", newStr(ctx, "prefix"));
            _ = q.JS_SetPropertyStr(ctx, o, "key", newStr(ctx, p));
            _ = q.JS_SetPropertyStr(ctx, o, "count", Vals(q).mkVal(q.JS_TAG_INT, @intCast(entries.len)));
            _ = q.JS_SetPropertyStr(ctx, o, "rowsFold", newStr(ctx, fold_hex));
            push(ctx, o);
        }
    };
}
