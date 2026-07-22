//! Customer-facing kv surface — the `kv.get/set/delete/prefix` bindings
//! split out of globals.zig, plus the `markSubscriptionsDirty` hook that
//! arms kv-react subscriptions on every write.
//!
//! Kept apart from the privileged `platform.*` path (globals_platform.zig)
//! so the surface a customer handler can reach is legible on its own. The
//! shared `DispatchState`, `getState`, `c`, the js-value constants, and the
//! kv arg/size/reserved-key helpers stay in globals.zig and come back via
//! the `globals_mod` alias (the two files import each other).

const std = @import("std");
const qjs = @import("rove-qjs");
const kv_mod = @import("raft-kv");
const rove = @import("rove");
const reserved = @import("reserved.zig");
const td = @import("trigger_dispatch.zig");
const tape_mod = @import("rove-tape");

const c = qjs.c;

const globals_mod = @import("globals.zig");
const DispatchState = globals_mod.DispatchState;
const getState = globals_mod.getState;
const js_exception = globals_mod.js_exception;
const js_undefined = globals_mod.js_undefined;
const js_null = globals_mod.js_null;
const js_true = globals_mod.js_true;
const js_false = globals_mod.js_false;
const valueToOwnedString = globals_mod.valueToOwnedString;
const kvWriteArgToOwnedString = globals_mod.kvWriteArgToOwnedString;
const kvSizeViolation = globals_mod.kvSizeViolation;
const throwKvTooLarge = globals_mod.throwKvTooLarge;
const throwReservedKey = globals_mod.throwReservedKey;
const KvSizeViolation = globals_mod.KvSizeViolation;

pub fn jsKvGet(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);

    const key_str = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(key_str);

    // The minimal readset (`docs/architecture/effects-and-handlers.md`,
    // readset replication). A `kv.get(k)`
    // where `k` is in this activation's own writeset reads a value
    // the activation itself produced, reproducible by replay re-
    // running the handler against its own overlay. Only FOREIGN
    // reads (keys NOT in the writeset) carry replay information,
    // so only those make it onto the tape. Saves tape size + S3
    // bytes per request without losing replay determinism.
    const skip_tape = state.writeset.containsKey(key_str);

    const value = state.kv.get(key_str) catch |err| switch (err) {
        error.NotFound => {
            if (!skip_tape) if (state.readset) |rs| rs.kv.appendKv(.get, key_str, "", .not_found) catch {};
            return js_null;
        },
        else => {
            state.pending_kv_error = err;
            if (!skip_tape) if (state.readset) |rs| rs.kv.appendKv(.get, key_str, "", .err) catch {};
            return js_null;
        },
    };
    defer state.allocator.free(value);

    if (!skip_tape) if (state.readset) |rs| rs.kv.appendKv(.get, key_str, value, .ok) catch {};
    return c.JS_NewStringLen(ctx, value.ptr, value.len);
}

/// durable-kv-subscriptions: a successful customer write under a
/// watched subscription prefix injects the durable dirty marker
/// (`_sub/dirty/{name}` → the watched prefix) into THIS activation's
/// txn + writeset — atomic with the triggering write, which is the
/// whole at-least-once guarantee (a commit either carries both or
/// neither; there is no window where the write is durable but the owed
/// fire isn't). The marker key is one-per-subscription, so N matching
/// writes coalesce at the storage level; `subs_marked` also dedups the
/// redundant rewrites within one activation. `_sub/`-keys themselves
/// never re-trigger (recursion guard — the fire's own marker delete
/// must not re-arm it).
fn markSubscriptionsDirty(state: *DispatchState, key: []const u8) void {
    if (state.subscriptions.len == 0) return;
    if (std.mem.startsWith(u8, key, "_sub/")) return;
    for (state.subscriptions, 0..) |sub, i| {
        const prefix = switch (sub.spec) {
            .kv => |k| k.prefix,
        };
        if (!std.mem.startsWith(u8, key, prefix)) continue;
        if (i < 64) {
            const bit = @as(u64, 1) << @intCast(i);
            if (state.subs_marked & bit != 0) continue;
            state.subs_marked |= bit;
        }
        const mkey = std.fmt.allocPrint(state.allocator, "_sub/dirty/{s}", .{sub.name}) catch |err| {
            state.pending_kv_error = err;
            return;
        };
        defer state.allocator.free(mkey);
        state.txn.put(mkey, prefix) catch |err| {
            state.pending_kv_error = err;
            return;
        };
        state.writeset.addPut(mkey, prefix) catch |err| {
            state.pending_kv_error = err;
            return;
        };
    }
}

pub fn jsKvSet(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 2) return js_undefined;
    const state = getState(ctx);

    const key_str = kvWriteArgToOwnedString(state, ctx, argv[0], "key") catch return js_exception;
    defer state.allocator.free(key_str);
    const val_str = kvWriteArgToOwnedString(state, ctx, argv[1], "value") catch return js_exception;
    defer state.allocator.free(val_str);

    // Reject writes into platform-reserved namespaces. Platform writers
    // (http.send → `_send/owed/` marker, etc.) bypass jsKvSet and write
    // through state.txn / state.writeset directly, so this guard only
    // fires when customer JS tries to spoof a platform key.
    // `__system/` built-in modules (the webhook shim's onresult
    // handler) are platform-trusted and bypass the check — they need
    // to write `_send/owed/{id}` markers.
    if (!state.is_system_module and reserved.isCustomerWriteReserved(key_str)) {
        return throwReservedKey(ctx, key_str);
    }

    // Reject oversized writes fail-fast with a clean error (see KV_KEY_MAX /
    // KV_VAL_MAX). Applies to system writes too — anything over the kvexp cap
    // fails at snapshot regardless, so checking early can't break a working
    // path, only surface the failure cleanly.
    if (kvSizeViolation(key_str.len, val_str.len)) |which| {
        return throwKvTooLarge(ctx, which);
    }

    // The minimal readset (`docs/architecture/effects-and-handlers.md`):
    // kv.set is an OUTPUT, not an
    // input. Replay re-runs the handler and re-issues the write
    // (against its writeset overlay); the value is a pure function
    // of the recorded foreign reads + the pinned bytecode hash.
    // Nothing about a write is a replay input, so it isn't taped.

    // Fast path: no triggers match → write directly, no savepoint, no
    // previousValue lookup, no chain machinery — no added cost over a
    // plain write.
    if (!td.anyTriggerMatches(state, key_str)) {
        state.txn.put(key_str, val_str) catch |err| {
            state.pending_kv_error = err;
            return js_undefined;
        };
        state.writeset.addPut(key_str, val_str) catch |err| {
            state.pending_kv_error = err;
        };
        markSubscriptionsDirty(state, key_str);
        return js_undefined;
    }

    // Slow path: there's at least one matching trigger. Fetch the
    // previousValue, open an inner savepoint, run BEFORE chain
    // (with possible value mutation), do the write, run AFTER chain.
    // Throw anywhere → rollback the savepoint and rethrow as
    // `Error{ code: "trigger_rejected" }`.
    var prev_owned: ?[]u8 = null;
    defer if (prev_owned) |p| state.allocator.free(p);
    if (state.kv.get(key_str)) |bytes| {
        prev_owned = bytes;
    } else |err| switch (err) {
        error.NotFound => {},
        else => {
            state.pending_kv_error = err;
            return js_undefined;
        },
    }

    state.txn.savepoint() catch |err| {
        state.pending_kv_error = err;
        return js_undefined;
    };

    // `cur_value` starts as the original `val_str` (borrowed). If a
    // BEFORE trigger returns a string, the chain helper allocates a
    // fresh buffer, points `cur_value` at it, and tracks ownership
    // via `cur_owned` so we can free it before returning.
    var cur_owned: ?[]u8 = null;
    defer if (cur_owned) |o| state.allocator.free(o);
    var cur_value: ?[]const u8 = val_str;
    if (td.runBeforeChain(state, ctx, key_str, .put, &cur_value, &cur_owned, prev_owned)) |trigger_path| {
        td.rollbackInnerSavepoint(state);
        return td.rethrowAsTriggerRejected(state, ctx, trigger_path);
    }

    const write_value: []const u8 = cur_value.?;

    state.txn.put(key_str, write_value) catch |err| {
        state.pending_kv_error = err;
        td.rollbackInnerSavepoint(state);
        return js_undefined;
    };
    state.writeset.addPut(key_str, write_value) catch |err| {
        state.pending_kv_error = err;
    };
    markSubscriptionsDirty(state, key_str);

    if (td.runAfterChain(state, ctx, key_str, .put, write_value, prev_owned)) |trigger_path| {
        td.rollbackInnerSavepoint(state);
        return td.rethrowAsTriggerRejected(state, ctx, trigger_path);
    }

    state.txn.release() catch |err| {
        state.pending_kv_error = err;
    };
    return js_undefined;
}

pub fn jsKvDelete(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);

    const key_str = kvWriteArgToOwnedString(state, ctx, argv[0], "key") catch return js_exception;
    defer state.allocator.free(key_str);

    // Same reserved-namespace guard as jsKvSet — see the comment there.
    // `__system/` built-ins bypass.
    if (!state.is_system_module and reserved.isCustomerWriteReserved(key_str)) {
        return throwReservedKey(ctx, key_str);
    }

    // Reject an over-long key (no value to check on delete). A key over the
    // cap can't exist (puts are capped), so this is mostly contract hygiene.
    if (kvSizeViolation(key_str.len, null)) |which| {
        return throwKvTooLarge(ctx, which);
    }

    // Fast path mirrors jsKvSet — no triggers means no savepoint, no
    // previousValue lookup, no chain machinery. kv.delete
    // (like kv.set) is an OUTPUT and isn't taped — replay re-runs
    // the handler against its overlay.
    if (!td.anyTriggerMatches(state, key_str)) {
        state.txn.delete(key_str) catch |err| {
            state.pending_kv_error = err;
            return js_undefined;
        };
        state.writeset.addDelete(key_str) catch |err| {
            state.pending_kv_error = err;
        };
        markSubscriptionsDirty(state, key_str);
        return js_undefined;
    }

    var prev_owned: ?[]u8 = null;
    defer if (prev_owned) |p| state.allocator.free(p);
    if (state.kv.get(key_str)) |bytes| {
        prev_owned = bytes;
    } else |err| switch (err) {
        error.NotFound => {},
        else => {
            state.pending_kv_error = err;
            return js_undefined;
        },
    }

    state.txn.savepoint() catch |err| {
        state.pending_kv_error = err;
        return js_undefined;
    };

    // BEFORE chain: deletes don't carry a value, so cur_value stays
    // null (the helper passes that through to event.value as JS null,
    // and ignores any string return from a beforeDelete handler).
    var cur_owned: ?[]u8 = null;
    defer if (cur_owned) |o| state.allocator.free(o);
    var cur_value: ?[]const u8 = null;
    if (td.runBeforeChain(state, ctx, key_str, .delete, &cur_value, &cur_owned, prev_owned)) |trigger_path| {
        td.rollbackInnerSavepoint(state);
        return td.rethrowAsTriggerRejected(state, ctx, trigger_path);
    }

    state.txn.delete(key_str) catch |err| {
        state.pending_kv_error = err;
        td.rollbackInnerSavepoint(state);
        return js_undefined;
    };
    state.writeset.addDelete(key_str) catch |err| {
        state.pending_kv_error = err;
    };
    markSubscriptionsDirty(state, key_str);

    if (td.runAfterChain(state, ctx, key_str, .delete, null, prev_owned)) |trigger_path| {
        td.rollbackInnerSavepoint(state);
        return td.rethrowAsTriggerRejected(state, ctx, trigger_path);
    }

    state.txn.release() catch |err| {
        state.pending_kv_error = err;
    };
    return js_undefined;
}


/// `kv.prefix(prefix, cursor?, limit?)` → `[ { key, value }, ... ]`
///
/// Prefix scan exposed to handlers. `cursor` is the last key from a
/// previous page (pass "" to start). `limit` defaults to 100, capped
/// at 1000 — this is an admin/introspection surface, not a hot read
/// path, so we err on the side of small pages. Reads go directly
/// through `state.kv`; writes from the same handler are visible here
/// because the underlying SQLite connection sees its own uncommitted
/// txn state.
///
/// Tape-captured via `appendKvPrefix` — the captured entry holds the
/// inputs (prefix/cursor/limit) AND the full result list, so the
/// replay shell's `kv.prefix` stub can return the same rows without
/// reaching live KV state.
pub fn jsKvPrefix(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);

    const prefix_str = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(prefix_str);

    const cursor_str = if (argc >= 2 and !c.JS_IsUndefined(argv[1]) and !c.JS_IsNull(argv[1]))
        valueToOwnedString(state, ctx, argv[1]) catch return js_exception
    else
        state.allocator.dupe(u8, "") catch return js_exception;
    defer state.allocator.free(cursor_str);

    const KV_PREFIX_MAX: u32 = 1000;
    const KV_PREFIX_DEFAULT: u32 = 100;
    const limit: u32 = if (argc >= 3 and !c.JS_IsUndefined(argv[2]) and !c.JS_IsNull(argv[2])) blk: {
        var n: i32 = 0;
        _ = c.JS_ToInt32(ctx, &n, argv[2]);
        if (n <= 0) break :blk KV_PREFIX_DEFAULT;
        break :blk @min(@as(u32, @intCast(n)), KV_PREFIX_MAX);
    } else KV_PREFIX_DEFAULT;

    var scan = state.kv.prefix(prefix_str, cursor_str, limit) catch |err| {
        state.pending_kv_error = err;
        // Capture the failure path too — replay needs to surface the
        // same null return, otherwise a defensive `if (page === null)`
        // branch in the handler would diverge.
        if (state.readset) |rs| rs.kv.appendKvPrefix(prefix_str, cursor_str, limit, &.{}, .err) catch {};
        return js_null;
    };
    defer scan.deinit();

    if (state.readset) |rs| {
        // Convert `kv.PrefixScan.entries` (rove-kv's shape) into the
        // tape's `KvPair`s. Both are the same `(key, value)` pair, but
        // they belong to different modules so we materialize the
        // bridge on the stack. `appendKvPrefix` dups everything into
        // tape storage, so the lifetime of `pairs` and `scan` doesn't
        // need to extend past this call.
        var stack_pairs: [256]tape_mod.KvPair = undefined;
        const heap_pairs: ?[]tape_mod.KvPair = if (scan.entries.len <= stack_pairs.len)
            null
        else
            state.allocator.alloc(tape_mod.KvPair, scan.entries.len) catch null;
        defer if (heap_pairs) |h| state.allocator.free(h);
        const pairs: []tape_mod.KvPair = if (heap_pairs) |h| h else stack_pairs[0..scan.entries.len];
        // Minimal read set (mirrors the kv.get `skip_tape` gate): a row whose
        // key is in this activation's own writeset is a read-your-write, not a
        // foreign read. Keep it OUT of the taped readset — replay reproduces it
        // by re-executing the handler's own write, then reconstructs the scan
        // from the map. This keeps the readset disjoint from the writeset, so a
        // refactored read of such a key can't be served a stale write value.
        var np: usize = 0;
        for (scan.entries) |e| {
            if (state.writeset.containsKey(e.key)) continue;
            pairs[np] = .{ .key = e.key, .value = e.value };
            np += 1;
        }
        rs.kv.appendKvPrefix(prefix_str, cursor_str, limit, pairs[0..np], .ok) catch {};
    }

    const arr = c.JS_NewArray(ctx);
    for (scan.entries, 0..) |e, i| {
        const obj = c.JS_NewObject(ctx);
        _ = c.JS_SetPropertyStr(ctx, obj, "key", c.JS_NewStringLen(ctx, e.key.ptr, e.key.len));
        _ = c.JS_SetPropertyStr(ctx, obj, "value", c.JS_NewStringLen(ctx, e.value.ptr, e.value.len));
        _ = c.JS_SetPropertyUint32(ctx, arr, @intCast(i), obj);
    }
    return arr;
}
