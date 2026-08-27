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
//! get(d, key: Key) GetResult              // value (owned) | absent | thrown
//!                                         //   — the delegate records/tapes/
//!                                         //   folds internally
//! release(d, bytes) void                  // free a get() result
//! put(d, ctx, key: Key, value) bool       // false = a JS exception is pending
//! del(d, ctx, key: Key) bool              //   (trigger rejection, …)
//! prefix(d, scan: Scan) ?Page             // null = storage error → JS null;
//!                                         //   Page has .entries ([]{key,value})
//!                                         //   and deinit(). Row keys come back
//!                                         //   STORED; `scan.visible(k)` is the
//!                                         //   caller's spelling.
//! ```
//!
//! `Key` carries both spellings because a rooted binding has two, and the rule
//! for choosing is a LAYER rule: **`stored` for everything at or below
//! persistence** (the store, the writeset, the entry byte budget, and the kv
//! TAPE — its storage-modeling entries feed replay overlays verbatim, so they
//! are keyed the way the store is), **`named` for the handler surface and
//! what derives from it** (the digest, trigger and subscription matching,
//! refusal verdicts and their tape entries, harness assertions). Anything
//! RENDERED for the person who named the key strips the root at the
//! presentation seam (`reserved.userNamedKey`). Resolving once here rather
//! than in each delegate is what keeps three engines from drifting into three
//! resolutions.
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

/// A key in both of its spellings, because a rooted binding has two and every
/// consumer wants a specific one.
///
/// The split is not a detail of the rooting — it is the rule for using it, and
/// it is a LAYER rule: **everything at or below persistence uses `stored`;
/// the handler surface and what derives from it uses `named`.**
///
///   `named`   interaction digest, trigger matching, subscription matching,
///             refusal messages and refusal tape entries, harness assertions
///             — all of these are about a key the handler chose, and a
///             trigger registered at `orders/` must fire for
///             `kv.set("orders/1")` whatever root the row lands under.
///   `stored`  the store, the writeset (it rides the raft entry), the entry
///             byte budget, and the TAPE's storage-modeling entries (gets,
///             prefix requests and rows) — the tape is the store's stand-in
///             during replay, so its keys are the store's. A tape key
///             rendered for a person strips the root at the presentation
///             seam (`reserved.userNamedKey`).
///
/// Passing both rather than resolving inside each delegate keeps ONE
/// implementation of the resolution — three delegates each doing their own is
/// the writer/reader prefix-depth split, which this codebase has paid for. The
/// cost is a wider delegate contract, and that is the right trade: the two
/// spellings are explicit at every call site instead of implied.
///
/// The two are the same slice under `.raw` for everything but `_config/`.
pub const Key = struct {
    named: []const u8,
    stored: []const u8,
};

/// A `kv.prefix` request, in both spellings, plus what a delegate needs to put
/// a row key back into the caller's spelling.
///
/// A scan is the asymmetry a get/set pair does not have: the prefix and cursor
/// go DOWN resolved, and row keys come back UP in whatever form storage holds.
/// The tape wants them exactly so (store-spelled, like every storage-modeling
/// entry); a delegate that surfaces the scan in the CALLER's spelling — the
/// digest's rows-fold, a harness assertion — has to un-root each row itself,
/// and `visible` is how.
pub const Scan = struct {
    prefix: Key,
    cursor: Key,
    limit: u32,
    /// The binding's root, so a delegate can un-map. Empty under `.raw`.
    root: []const u8,

    /// A stored row key in the spelling the caller paged with. Returns the key
    /// unchanged when it does not carry the root, which under `.user` cannot
    /// happen — the scan is bounded by the root — and under `.raw` is every
    /// key.
    pub fn visible(self: Scan, stored: []const u8) []const u8 {
        if (self.root.len == 0) return stored;
        if (!std.mem.startsWith(u8, stored, self.root)) return stored;
        return stored[self.root.len..];
    }
};

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

/// The keyspace a `Kv` instantiation is rooted in — the whole of what
/// separates the capability a handler holds from the one the engine keeps.
///
/// Two instantiations of the identical code, differing only here. Which one an
/// activation is handed is decided when its activation object is assembled,
/// from the module path (`builtin_modules.isBuiltinPath`), and that decision is
/// the entire access-control mechanism: a handler cannot reach an engine key
/// because the object it holds is rooted elsewhere, not because a predicate
/// refuses it (`docs/architecture/package-isolation.md`, not installing is the
/// denial).
///
/// Per-*activation* is the correct granularity for a GRANT even though it is
/// the wrong granularity for a check — a package executing inside a customer
/// activation is indistinguishable from the handler at call time, which is why
/// nothing here consults who is calling.
pub const Root = enum {
    /// Every key reroots under `reserved.USER_KEY_ROOT`, with no exception.
    /// The engine keyspace is not refused, it is unnameable.
    user,
    /// Storage as it lies. Held by baked `__system/` activations and by the
    /// natives that implement narrower capabilities (`config`) over it.
    raw,

    fn prefix(comptime self: Root) []const u8 {
        return switch (self) {
            .user => guards.reserved.USER_KEY_ROOT,
            .raw => "",
        };
    }
};

pub fn Kv(comptime q: type, comptime D: type, comptime root: Root) type {
    return struct {
        const js_undefined = Vals(q).js_undefined;
        const js_null = Vals(q).js_null;
        const js_exception = Vals(q).js_exception;
        const key_root = root.prefix();

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

            // No hidden-keyspace check. A scoped read of an engine namespace
            // is not answered "absent" as a policy — it lands inside the
            // caller's own root, where the row genuinely is absent unless the
            // caller put it there. The engine keyspace is not concealed from
            // this binding; it is unreachable through it.
            var skey_buf: [guards.reserved.STORAGE_KEY_MAX]u8 = undefined;
            const skey = storageKey(d, &skey_buf, key) orelse return js_null;

            switch (d.get(.{ .named = key, .stored = skey })) {
                .value => |v| {
                    defer d.release(v);
                    return q.JS_NewStringLen(ctx, v.ptr, v.len);
                },
                .absent => return js_null,
                .thrown => return js_exception,
            }
        }

        /// `config.get(name)` → the deploy-time config value, or null — the
        /// only door to the `_config/` namespace (rove#830: handlers stop
        /// knowing it is a kv prefix).
        ///
        /// A read-only kv get underneath, which is a requirement rather than
        /// a convenience: the read rides the ordinary kv tape entry and
        /// digest fold, so replay covers it for free — a config read that
        /// became its own effect kind would need its own tape treatment.
        ///
        /// The name resolves independently of this instantiation's root:
        /// NAMED is `_config/{name}` (what the digest folds and a divergence
        /// message shows), STORED is `reserved.configStorageKey` of it — the
        /// deployment that shipped the config (`d.configScope()`; 0, the
        /// authored-world scope, resolves to the visible spelling). Code and
        /// config therefore switch on the same `_deploy/current` flip, and a
        /// handler cannot name another deployment's rows: whatever `name`
        /// contains is appended AFTER the scope segment.
        ///
        /// Write access does not exist here or anywhere reachable: under
        /// `.user` a literal `kv.set("_config/…")` reroots into the caller's
        /// own keyspace, so the deploy tree stays the single source of truth.
        pub fn jsConfigGet(
            ctx: ?*q.JSContext,
            _: q.JSValue,
            argc: c_int,
            argv: [*c]q.JSValue,
        ) callconv(.c) q.JSValue {
            if (argc < 1) return js_undefined;
            const d = D.fromCtx(ctx);

            const name = coerce(d, ctx, argv[0]) catch return js_exception;
            defer d.allocator().free(name);

            var named_buf: [guards.reserved.CONFIG_STORAGE_KEY_MAX]u8 = undefined;
            const named = std.fmt.bufPrint(&named_buf, "{s}{s}", .{
                guards.reserved.CONFIG_PREFIX, name,
            }) catch return js_null; // longer than any deployable config path
            var skey_buf: [guards.reserved.CONFIG_STORAGE_KEY_MAX]u8 = undefined;
            const skey = guards.reserved.configStorageKey(&skey_buf, d.configScope(), named) orelse
                return js_null;

            switch (d.get(.{ .named = named, .stored = skey })) {
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
            const exempt = d.isExempt(key);
            if (d.decides() and !exempt) {
                if (guards.checkKvWrite(key, value, d.writeBudget())) |refusal| {
                    d.recordRefusal(.set, key, refusal);
                    return throwRefusal(d, ctx, refusal, key);
                }
            }

            // Rules judge the key a handler NAMED; storage takes the key it
            // resolves to, so a write and a read of the same name reach the
            // same row. Only the mirror writes `_config/` in production, but
            // an asymmetry here is the kind that surfaces years later as a
            // config write nobody can find.
            var skey_buf: [guards.reserved.STORAGE_KEY_MAX]u8 = undefined;
            const skey = storageKey(d, &skey_buf, key) orelse return js_exception;

            if (!d.put(ctx, .{ .named = key, .stored = skey }, value)) return js_exception;
            // Spend the activation's budget only on a write that HAPPENED: a
            // refused or failed one costs nothing, or a handler could be
            // starved by writes that never reached the entry. Charged on the
            // key that rides the entry, which is the resolved one.
            // An exempt key is not a customer write, so it does not spend the
            // customer's allowance either — charging it would let harness
            // scaffolding starve the handler it is scaffolding. The check-skip
            // and the charge-skip are the same statement; splitting them is
            // what let this hide behind the reserved rule's ordering.
            if (!exempt) d.noteWrite(guards.kvWriteCost(skey.len, value.len));
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
            const exempt = d.isExempt(key);
            if (d.decides() and !exempt) {
                if (guards.checkKvWrite(key, null, d.writeBudget())) |refusal| {
                    d.recordRefusal(.delete, key, refusal);
                    return throwRefusal(d, ctx, refusal, key);
                }
            }

            var skey_buf: [guards.reserved.STORAGE_KEY_MAX]u8 = undefined;
            const skey = storageKey(d, &skey_buf, key) orelse return js_exception;

            if (!d.del(ctx, .{ .named = key, .stored = skey })) return js_exception;
            // A delete is an op with a key and no value — it rides the entry
            // like any other.
            if (!exempt) d.noteWrite(guards.kvWriteCost(skey.len, 0));
            return js_undefined;
        }

        /// Where the key a caller NAMED actually lives.
        ///
        /// Under `.user` this is the whole of the scoping rule and it has no
        /// exceptions: every key reroots, so there is no spelling that escapes
        /// the root and nothing to enumerate. An exception here would be a key
        /// the handler could name outside its own keyspace, which is exactly
        /// the property the root exists to remove.
        ///
        /// Under `.raw` there is NO resolution: storage as it lies, literally.
        /// The one logical→physical mapping that used to live here — config's
        /// deployment scoping — belongs to `jsConfigGet` now, the door that
        /// owns the visible spelling. Keeping a resolution inside `.raw`
        /// would double-scope the config INSTALLER, whose rows arrive
        /// already deployment-scoped from the deploy thread and must land
        /// verbatim.
        ///
        /// Returns null only when the resolved key would not fit `buf`;
        /// callers size it `reserved.STORAGE_KEY_MAX`.
        fn storageKey(d: D, buf: []u8, key: []const u8) ?[]const u8 {
            if (comptime root == .user) {
                // An exempt key is not a customer write — the delegate has
                // said so — and so is not the caller's to have rerooted. The
                // offline engines' store facade (`__rove_store/`) addresses
                // OTHER stores through this binding, and rooting those would
                // point them at a namespace inside the caller's own. This is
                // an engine-declared exemption, not a spelling that escapes
                // the rule: the worker returns false unconditionally, so
                // production has no such key.
                if (d.isExempt(key)) return key;
                return std.fmt.bufPrint(buf, "{s}{s}", .{ key_root, key }) catch null;
            }
            return key;
        }

        /// The inverse of `storageKey` for a key STORAGE produced — used on the
        /// scan path, the one place resolved keys travel back to the caller.
        ///
        /// A scan is the asymmetry that a get/set pair does not have: the key
        /// goes down resolved and comes back up in whatever form storage holds.
        /// Leaving it resolved is the writer/reader prefix-depth split this
        /// codebase has paid for before — the caller pages with a cursor it was
        /// handed, so a key returned in one depth and accepted in another
        /// silently truncates the scan rather than failing it.
        ///
        /// A row that does not carry the root cannot be addressed by the caller
        /// and is skipped; under `.user` a scan is bounded by the root, so that
        /// is unreachable rather than merely unlikely.
        /// `eff_root` is empty when the scan was not rooted — a `.raw`
        /// binding, or an exempt prefix, whose rows are addressed exactly as
        /// storage holds them.
        fn visibleKey(eff_root: []const u8, stored: []const u8) ?[]const u8 {
            if (eff_root.len == 0) return stored;
            if (!std.mem.startsWith(u8, stored, eff_root)) return null;
            return stored[eff_root.len..];
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

            // A scan resolves the same way a get does, and a scoped scan is
            // bounded by its root. (Config has no scan: `config.get` is the
            // whole door, and under `.user` a `kv.prefix("_config/")` pages
            // the handler's own keyspace like any other spelling.)
            //
            // There is no hidden-row filtering here and no page refilling.
            // A scoped scan cannot reach an engine key: the key is not removed
            // from the range, it was never in it. That is the difference
            // between a boundary drawn by the shape of the capability and one
            // policed on every row — the second needed a refill loop, because
            // a run of hidden rows longer than a page reads as end-of-data to
            // the documented paging idiom (`handler-shape.md` §5.7).
            // A scan whose prefix the delegate calls exempt is not rooted —
            // the offline facade addresses other stores through this binding —
            // so it must not be un-rooted on the way out either. Deriving the
            // effective root once, here, is what keeps the two directions from
            // disagreeing: the earlier version rooted neither and un-rooted
            // both, which dropped every facade row and read as an empty page.
            const eff_root: []const u8 = if (comptime root == .raw)
                ""
            else if (d.isExempt(prefix))
                ""
            else
                key_root;

            var spfx_buf: [guards.reserved.STORAGE_KEY_MAX]u8 = undefined;
            const spfx = storageKey(d, &spfx_buf, prefix) orelse return js_null;

            // The cursor is a key the CALLER was handed, so it comes back in
            // the visible spelling and has to be resolved like any other key
            // before storage compares it. An empty cursor means "from the
            // start" and stays empty — resolving it would name the root, which
            // is not a row. Getting this wrong is the writer/reader
            // prefix-depth split: the scan still returns a first page, then
            // pages that silently repeat or skip.
            var scur_buf: [guards.reserved.STORAGE_KEY_MAX]u8 = undefined;
            const scur = if (cursor.len == 0)
                cursor
            else
                storageKey(d, &scur_buf, cursor) orelse return js_null;

            var page = d.prefix(.{
                .prefix = .{ .named = prefix, .stored = spfx },
                .cursor = .{ .named = cursor, .stored = scur },
                .limit = limit,
                .root = eff_root,
            }) orelse return js_null;
            defer page.deinit();

            const arr = q.JS_NewArray(ctx);
            var n: u32 = 0;
            for (page.entries) |e| {
                // Hand back the spelling the caller uses, so the key it pages
                // with next is one this same call would accept.
                const vkey = visibleKey(eff_root, e.key) orelse continue;
                const obj = q.JS_NewObject(ctx);
                _ = q.JS_SetPropertyStr(ctx, obj, "key", q.JS_NewStringLen(ctx, vkey.ptr, vkey.len));
                _ = q.JS_SetPropertyStr(ctx, obj, "value", q.JS_NewStringLen(ctx, e.value.ptr, e.value.len));
                _ = q.JS_SetPropertyUint32(ctx, arr, n, obj);
                n += 1;
            }
            return arr;
        }
    };
}

/// `tag(key, value)` — the common binding for the tag surface. The
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

/// The offline engines' shred state, shared because it was identical.
///
/// The sim and the browser arena both need `shredKey` and its
/// `destroy` to behave exactly as they do in the worker — validate, count
/// against the cap, return the same refusals — while performing no
/// sealing at all: they run against a recorded tape, and the arena holds
/// no key material by design (PLAN §2.7 locks no client-side key
/// distribution).
///
/// That made two byte-identical delegates in two engines. Divergence
/// between them would be invisible until a handler behaved differently
/// under replay than in production, which is the whole failure this
/// binding layer exists to prevent — so there is one copy.
///
/// Container-level state, like the engines' own tag lists beside it: each
/// runs a single activation at a time, and the two never link together
/// (one is native, the other wasm).
pub const OfflineShred = struct {
    var identity: ?[]u8 = null;
    var destroys: usize = 0;

    pub fn set(id: []const u8) bool {
        const dup = std.heap.c_allocator.dupe(u8, id) catch return false;
        if (identity) |old| std.heap.c_allocator.free(old);
        identity = dup;
        return true;
    }

    pub fn destroyCount() usize {
        return destroys;
    }

    /// Counted and validated, never performed — see the type's doc.
    pub fn destroy() bool {
        destroys += 1;
        return true;
    }

    /// Per-activation state, cleared where the engines clear their tags.
    pub fn reset() void {
        if (identity) |old| std.heap.c_allocator.free(old);
        identity = null;
        destroys = 0;
    }
};

test "the offline shred state resets per activation, not per process" {
    // A destroy count carried across runs would make the cap refuse in
    // replay what production allowed — the exact cross-engine divergence
    // this binding layer exists to prevent. The worker keeps the count on
    // the activation's own cell; the offline engines reset here.
    OfflineShred.reset();
    try std.testing.expectEqual(@as(usize, 0), OfflineShred.destroyCount());
    _ = OfflineShred.destroy();
    _ = OfflineShred.destroy();
    try std.testing.expectEqual(@as(usize, 2), OfflineShred.destroyCount());
    OfflineShred.reset();
    try std.testing.expectEqual(@as(usize, 0), OfflineShred.destroyCount());
}

test "the offline shred state re-scopes rather than accumulating" {
    // An activation has exactly one identity: naming a second replaces
    // the first, matching the worker's cell.
    OfflineShred.reset();
    try std.testing.expect(OfflineShred.set("u_first"));
    try std.testing.expect(OfflineShred.set("u_second"));
    OfflineShred.reset();
}

/// `shredKey(id)` — the common binding for the per-identity
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

        /// `shredKey.destroy(id)` — erase this identity's key.
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
