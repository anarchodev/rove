// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Privileged platform surface — `platform.root.*` and `platform.scope(id)`
//! bindings, split out of globals.zig. Installed ONLY for the `__admin__`
//! handler tenant (gated on `state.platform` in installRequest), these give
//! the admin JS handler raw reads/writes against the platform root store and
//! scoped per-instance kv, plus instance/release provisioning.
//!
//! Kept apart from the customer-facing kv surface (globals_kv.zig) so the
//! privileged path is legible on its own. The shared `DispatchState`,
//! `getState`, `c`, the js-value constants, and the kv arg/size/reserved
//! helpers stay in globals.zig and come back via the `globals_mod` alias
//! (the two files import each other).

const std = @import("std");
const qjs = @import("rove-qjs");
const tenant_mod = @import("rove-tenant");
const rove = @import("rove");
const reserved = @import("reserved.zig");

const c = qjs.c;

const globals_mod = @import("globals.zig");
const DispatchState = globals_mod.DispatchState;
const getState = globals_mod.getState;
const ScopeKvOp = globals_mod.ScopeKvOp;
const js_exception = globals_mod.js_exception;
const js_undefined = globals_mod.js_undefined;
const js_null = globals_mod.js_null;
const valueToOwnedString = globals_mod.valueToOwnedString;
const kvWriteArgToOwnedString = globals_mod.kvWriteArgToOwnedString;
const kvSizeViolation = globals_mod.kvSizeViolation;
const throwKvTooLarge = globals_mod.throwKvTooLarge;
const throwReservedKey = globals_mod.throwReservedKey;
const KvSizeViolation = globals_mod.KvSizeViolation;

// ── platform.root.* (admin singleton only) ────────────────────────
//
// Only installed when the handler-tenant is `__admin__` — gated on
// `state.platform` being non-null in `installRequest`. Provides raw
// access to the platform root store for the admin JS handler's
// instance / domain / user / account reads. Writes currently land
// locally on the leader only (no raft propagation of root writes
// from JS handlers yet); multi-node correctness for admin-handler
// writes is follow-up work. Signup + other platform-level writes
// go through the Zig-native HTTP endpoints, which DO replicate.

pub fn jsPlatformRootGet(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);
    const tenant = state.platform orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    };

    const key = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(key);

    const value = tenant.root.get(key) catch |err| switch (err) {
        error.NotFound => return js_null,
        else => {
            state.pending_kv_error = err;
            return js_null;
        },
    };
    defer state.allocator.free(value);
    return c.JS_NewStringLen(ctx, value.ptr, value.len);
}

pub fn jsPlatformRootSet(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 2) return js_undefined;
    const state = getState(ctx);
    const tenant = state.platform orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    };

    const key = kvWriteArgToOwnedString(state, ctx, argv[0], "key") catch return js_exception;
    defer state.allocator.free(key);
    const val = kvWriteArgToOwnedString(state, ctx, argv[1], "value") catch return js_exception;
    defer state.allocator.free(val);

    tenant.root.put(key, val) catch |err| {
        state.pending_kv_error = err;
    };
    // Mirror the write into the root writeset so the worker can
    // propose it through raft. Admin handlers ALWAYS have this
    // set (dispatcher init checks `platform != null`), so an unset
    // field here means someone built a DispatchState by hand.
    if (state.root_writeset) |ws| {
        ws.addPut(key, val) catch |err| {
            state.pending_kv_error = err;
        };
    }
    return js_undefined;
}

pub fn jsPlatformRootDelete(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);
    const tenant = state.platform orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    };

    const key = kvWriteArgToOwnedString(state, ctx, argv[0], "key") catch return js_exception;
    defer state.allocator.free(key);

    tenant.root.delete(key) catch |err| switch (err) {
        error.NotFound => {
            // Still propagate the delete to followers so their state
            // converges — a key that's missing locally might exist
            // on other nodes if propose ordering skewed. The follower
            // `applyEncodedWriteSet` treats NotFound as a no-op.
        },
        else => {
            state.pending_kv_error = err;
            return js_undefined;
        },
    };
    if (state.root_writeset) |ws| {
        ws.addDelete(key) catch |err| {
            state.pending_kv_error = err;
        };
    }
    return js_undefined;
}

pub fn jsPlatformRootPrefix(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);
    const tenant = state.platform orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    };

    const prefix_str = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(prefix_str);

    const cursor_str = if (argc >= 2 and !c.JS_IsUndefined(argv[1]) and !c.JS_IsNull(argv[1]))
        valueToOwnedString(state, ctx, argv[1]) catch return js_exception
    else
        state.allocator.dupe(u8, "") catch return js_exception;
    defer state.allocator.free(cursor_str);

    const ROOT_PREFIX_MAX: u32 = 1000;
    const ROOT_PREFIX_DEFAULT: u32 = 100;
    const limit: u32 = if (argc >= 3 and !c.JS_IsUndefined(argv[2]) and !c.JS_IsNull(argv[2])) blk: {
        var n: i32 = 0;
        _ = c.JS_ToInt32(ctx, &n, argv[2]);
        if (n <= 0) break :blk ROOT_PREFIX_DEFAULT;
        break :blk @min(@as(u32, @intCast(n)), ROOT_PREFIX_MAX);
    } else ROOT_PREFIX_DEFAULT;

    var scan = tenant.root.prefix(prefix_str, cursor_str, limit) catch |err| {
        state.pending_kv_error = err;
        return js_null;
    };
    defer scan.deinit();

    const arr = c.JS_NewArray(ctx);
    for (scan.entries, 0..) |e, i| {
        const obj = c.JS_NewObject(ctx);
        _ = c.JS_SetPropertyStr(ctx, obj, "key", c.JS_NewStringLen(ctx, e.key.ptr, e.key.len));
        _ = c.JS_SetPropertyStr(ctx, obj, "value", c.JS_NewStringLen(ctx, e.value.ptr, e.value.len));
        _ = c.JS_SetPropertyUint32(ctx, arr, @intCast(i), obj);
    }
    return arr;
}

/// The operator-root check does NOT live here. A native taking the bearer
/// would mean the handler holds the token, and a handler-held value arrives
/// via `request.headers` — which the read-recorder TAPES. The verdict is
/// computed in the engine and surfaces as `request.rewind.isRoot`
/// (`globals_request.zig` `jsIsRootGetter`); the header itself is stripped on
/// a platform-bound handler (`reserved_headers.zig`
/// PLATFORM_CREDENTIAL_HEADERS). See `docs/architecture/control-plane.md` for
/// the audit line and `docs/decisions.md` for the surface-minimization rule.

/// `platform.instances.create(name)` — admin-only. Creates the
/// instance directory, opens its app.db, writes the local
/// `instance/{name}` marker, and mirrors the marker into the root
/// writeset for raft replication. Idempotent: re-creating an already
/// existing instance is a no-op (matches the underlying
/// `tenant.createInstance`).
///
/// Throws `Error{code:"InvalidName"}` if the name fails validation
/// (empty, too long, bad characters). Other errors land in
/// `state.pending_kv_error` and surface as a 5xx.
pub fn jsPlatformInstancesCreate(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) {
        _ = c.JS_ThrowTypeError(ctx, "platform.instances.create requires (name)");
        return js_exception;
    }
    const state = getState(ctx);
    const tenant = state.platform orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    };

    const name = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(name);

    tenant.createInstance(name) catch |err| switch (err) {
        error.InvalidInstanceId => {
            const err_obj = c.JS_NewError(ctx);
            if (c.JS_IsException(err_obj)) return err_obj;
            _ = c.JS_SetPropertyStr(ctx, err_obj, "message",
                c.JS_NewStringLen(ctx, "invalid instance name", "invalid instance name".len));
            _ = c.JS_SetPropertyStr(ctx, err_obj, "code",
                c.JS_NewStringLen(ctx, "InvalidName", "InvalidName".len));
            return c.JS_Throw(ctx, err_obj);
        },
        else => {
            state.pending_kv_error = err;
            return js_undefined;
        },
    };

    if (state.root_writeset) |ws| {
        var key_buf: [16 + tenant_mod.MAX_INSTANCE_ID_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "instance/{s}", .{name}) catch
            unreachable; // name was validated by createInstance above
        ws.addPut(key, "") catch |err| {
            state.pending_kv_error = err;
        };
    }
    return js_undefined;
}

/// `platform.instances.usage(name)` — admin-only. This node's KV
/// footprint for one instance: `{usedBytes, durableBytes,
/// overlayBytes, entries}`. `usedBytes` (durable LMDB pages +
/// committed overlay) is the same conservative figure the plan cap
/// (`max_kv_bytes`) is enforced against and the `kv_store_used_bytes`
/// gauge exports, so the dashboard renders exactly what enforcement
/// reads. O(1) — an mdb_stat, no scan. Untaped, like every
/// `platform.*` read. Throws `Error{code:"InstanceNotFound"}` for an
/// unknown instance. Values are JS numbers — exact far beyond any
/// sellable ceiling.
pub fn jsPlatformInstancesUsage(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) {
        _ = c.JS_ThrowTypeError(ctx, "platform.instances.usage requires (name)");
        return js_exception;
    }
    const state = getState(ctx);
    if (state.platform == null) {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    }

    const name = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(name);

    const inst = scopeResolve(state, name) orelse return jsThrowInstanceNotFound(ctx);
    const u = inst.kv.usage() catch |err| {
        state.pending_kv_error = err;
        return js_null;
    };

    const obj = c.JS_NewObject(ctx);
    if (c.JS_IsException(obj)) return obj;
    _ = c.JS_SetPropertyStr(ctx, obj, "usedBytes", c.JS_NewFloat64(ctx, @floatFromInt(u.durable_bytes + u.overlay_bytes)));
    _ = c.JS_SetPropertyStr(ctx, obj, "durableBytes", c.JS_NewFloat64(ctx, @floatFromInt(u.durable_bytes)));
    _ = c.JS_SetPropertyStr(ctx, obj, "overlayBytes", c.JS_NewFloat64(ctx, @floatFromInt(u.overlay_bytes)));
    _ = c.JS_SetPropertyStr(ctx, obj, "entries", c.JS_NewFloat64(ctx, @floatFromInt(u.durable_entries)));
    return obj;
}

/// `platform.instances.deployStarter(name)` — admin-only. Writes
/// the embedded starter content (`index.mjs` + `_static/index.html`)
/// into the target instance's `file-blobs/` + writes a manifest
/// JSON to `deployments/`, then proposes `_deploy/current = 1`
/// through raft so followers see the active deployment.
///
/// Sealed primitive: starter content is platform-baked
/// (`STARTER_INDEX_MJS` / `STARTER_STATIC_INDEX_HTML` in worker.zig),
/// not customer-supplied. A general `platform.deploy(name, files)`
/// is deferred until concrete demand (e.g. a libraries marketplace)
/// — see PLAN §10.
///
/// Throws `Error{code:"InstanceNotFound"}` if `name` doesn't resolve.
/// Throws `TypeError` when called outside an admin handler or before
/// the worker has wired the deploy trampoline (test path).
pub fn jsPlatformInstancesDeployStarter(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) {
        _ = c.JS_ThrowTypeError(ctx, "platform.instances.deployStarter requires (name)");
        return js_exception;
    }
    const state = getState(ctx);
    if (state.platform == null) {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    }
    const caps = state.platform_caps orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform.instances.deployStarter is not configured (no compile callback)");
        return js_exception;
    };
    const fn_ptr = caps.deploy_starter orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform.instances.deployStarter is not configured (no compile callback)");
        return js_exception;
    };
    const fn_ctx = caps.ctx;

    const name = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(name);

    fn_ptr(fn_ctx, state.allocator, name) catch |err| switch (err) {
        error.InstanceNotFound => {
            const err_obj = c.JS_NewError(ctx);
            if (c.JS_IsException(err_obj)) return err_obj;
            _ = c.JS_SetPropertyStr(ctx, err_obj, "message",
                c.JS_NewStringLen(ctx, "instance not found", "instance not found".len));
            _ = c.JS_SetPropertyStr(ctx, err_obj, "code",
                c.JS_NewStringLen(ctx, "InstanceNotFound", "InstanceNotFound".len));
            return c.JS_Throw(ctx, err_obj);
        },
        else => {
            state.pending_kv_error = err;
            return js_undefined;
        },
    };
    return js_undefined;
}

/// `platform.releases.publish(tenant_id, dep_id)` — admin-only.
/// Stamps `_deploy/current = hex(dep_id)` on the target tenant's
/// app.db, proposes envelope-0 through raft (no spin / no
/// blocking on consensus), and enqueues the deployment loader
/// so it starts fetching dep_id's manifest + bytecodes
/// immediately. Returns `undefined` once the local commit +
/// raft queue insert + loader enqueue are done — typically
/// sub-millisecond.
///
/// Customer-visible effect: a release POST returns in <10ms.
/// Raft consensus + bytecode load run async on the background
/// loader + raft threads. Eventually (SSE work — future) the
/// customer gets a completion event.
///
/// Throws `Error{code:"InstanceNotFound"}` when `tenant_id`
/// doesn't resolve. Throws `TypeError` when called outside an
/// admin handler.
pub fn jsPlatformReleasesPublish(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 2) {
        _ = c.JS_ThrowTypeError(ctx, "platform.releases.publish requires (tenant_id, dep_id)");
        return js_exception;
    }
    const state = getState(ctx);
    if (state.platform == null) {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    }
    const caps = state.platform_caps orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform.releases.publish is not configured on this worker");
        return js_exception;
    };
    const fn_ptr = caps.release_publish orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform.releases.publish is not configured on this worker");
        return js_exception;
    };
    const fn_ctx = caps.ctx;

    const tenant_id = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(tenant_id);

    // dep_id is a sha256-derived u64 (computeDeploymentId), routinely > 2^53, so
    // a JS number loses precision (JS_ToFloat64). Prefer a HEX STRING — parsed to
    // an exact u64 here; the number path handles small-id callers, where
    // precision isn't at risk.
    var dep_id: u64 = undefined;
    if (c.JS_IsString(argv[1])) {
        const s = valueToOwnedString(state, ctx, argv[1]) catch return js_exception;
        defer state.allocator.free(s);
        dep_id = std.fmt.parseInt(u64, s, 16) catch {
            _ = c.JS_ThrowRangeError(ctx, "platform.releases.publish: dep_id string must be a hex u64");
            return js_exception;
        };
        if (dep_id < 1) {
            _ = c.JS_ThrowRangeError(ctx, "platform.releases.publish: dep_id must be a positive integer");
            return js_exception;
        }
    } else {
        var dep_id_f64: f64 = 0;
        if (c.JS_ToFloat64(ctx, &dep_id_f64, argv[1]) < 0) return js_exception;
        if (dep_id_f64 < 1 or dep_id_f64 > @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
            _ = c.JS_ThrowRangeError(ctx, "platform.releases.publish: dep_id must be a positive integer");
            return js_exception;
        }
        dep_id = @intFromFloat(dep_id_f64);
    }

    fn_ptr(fn_ctx, state.allocator, tenant_id, dep_id) catch |err| switch (err) {
        error.InstanceNotFound => {
            const err_obj = c.JS_NewError(ctx);
            if (c.JS_IsException(err_obj)) return err_obj;
            _ = c.JS_SetPropertyStr(ctx, err_obj, "message",
                c.JS_NewStringLen(ctx, "instance not found", "instance not found".len));
            _ = c.JS_SetPropertyStr(ctx, err_obj, "code",
                c.JS_NewStringLen(ctx, "InstanceNotFound", "InstanceNotFound".len));
            return c.JS_Throw(ctx, err_obj);
        },
        else => {
            state.pending_kv_error = err;
            return js_undefined;
        },
    };
    return js_undefined;
}

// ── platform.scope(id).kv.* (admin singleton only) ────────────────
//
// Explicit, additive cross-tenant accessor.
// `platform.scope("acme").kv.get/prefix` read the target store
// directly; `.set/.delete` go through the worker trampoline
// (per-call txn + envelope-0 propose, the `handleAdminKv` shape). A
// dedicated accessor rather than rebinding the global `kv` keeps "who
// is the principal" separate from "which store" so auth stays
// expressible in a scoped dispatch — the scoped cross-tenant write
// (`docs/architecture/auth-and-domains.md`). Gated on `state.platform != null` like the
// rest of `platform.*`. Unknown instance → a coded `InstanceNotFound`
// JS error so the admin handler can map it to 404.

fn jsThrowInstanceNotFound(ctx: ?*c.JSContext) c.JSValue {
    const err_obj = c.JS_NewError(ctx);
    if (c.JS_IsException(err_obj)) return err_obj;
    _ = c.JS_SetPropertyStr(ctx, err_obj, "message", c.JS_NewStringLen(ctx, "instance not found", "instance not found".len));
    _ = c.JS_SetPropertyStr(ctx, err_obj, "code", c.JS_NewStringLen(ctx, "InstanceNotFound", "InstanceNotFound".len));
    return c.JS_Throw(ctx, err_obj);
}

/// Read the `_scope_id` the `platform.scope(id)` factory stamped on
/// the returned `.kv` object (`this_val` for these methods). Caller
/// owns the returned slice.
fn scopeIdFromThis(state: *DispatchState, ctx: ?*c.JSContext, this: c.JSValue) ![]u8 {
    const v = c.JS_GetPropertyStr(ctx, this, "_scope_id");
    defer c.JS_FreeValue(ctx, v);
    return valueToOwnedString(state, ctx, v);
}

fn scopeResolve(state: *DispatchState, id: []const u8) ?*const tenant_mod.Instance {
    const tenant = state.platform orelse return null;
    const inst_opt = tenant.getInstance(id) catch return null;
    return inst_opt;
}

pub fn jsPlatformScope(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) {
        _ = c.JS_ThrowTypeError(ctx, "platform.scope requires (instance_id)");
        return js_exception;
    }
    const state = getState(ctx);
    if (state.platform == null) {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    }
    const id = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(id);
    if (id.len == 0) {
        _ = c.JS_ThrowTypeError(ctx, "platform.scope: instance_id must be non-empty");
        return js_exception;
    }
    // Resolve eagerly so `platform.scope("ghost")` throws at the
    // call site (→ admin handler 404).
    if (scopeResolve(state, id) == null) return jsThrowInstanceNotFound(ctx);

    const kv_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, kv_obj, "_scope_id", c.JS_NewStringLen(ctx, id.ptr, id.len));
    _ = c.JS_SetPropertyStr(ctx, kv_obj, "get", c.JS_NewCFunction2(ctx, jsScopeKvGet, "get", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, kv_obj, "prefix", c.JS_NewCFunction2(ctx, jsScopeKvPrefix, "prefix", 3, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, kv_obj, "set", c.JS_NewCFunction2(ctx, jsScopeKvSet, "set", 2, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, kv_obj, "delete", c.JS_NewCFunction2(ctx, jsScopeKvDelete, "delete", 1, c.JS_CFUNC_generic, 0));
    // Cross-tenant blob access (the blob twin of scope().kv). `_scope_id` lets
    // the platform.js shim form scoped `blob.get` reads + `blob.receive`
    // streamed writes; there is no native sync `put` — cross-tenant writes
    // stream via `scope(t).blob.receive` (the S3 sink).
    const blob_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, blob_obj, "_scope_id", c.JS_NewStringLen(ctx, id.ptr, id.len));

    const scope_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, scope_obj, "kv", kv_obj);
    _ = c.JS_SetPropertyStr(ctx, scope_obj, "blob", blob_obj);
    // `scope_obj.deploy.stampManifest` is added by the platform.js shim — it
    // lowers to a bound on.fetch (the staging barrier), not a native sync
    // call, so it can resume the held chain only once staging is durable.
    return scope_obj;
}

fn jsScopeKvGet(
    ctx: ?*c.JSContext,
    this: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);
    const id = scopeIdFromThis(state, ctx, this) catch return js_exception;
    defer state.allocator.free(id);
    const inst = scopeResolve(state, id) orelse return jsThrowInstanceNotFound(ctx);

    const key = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(key);

    const value = inst.kv.get(key) catch |err| switch (err) {
        error.NotFound => return js_null,
        else => {
            state.pending_kv_error = err;
            return js_null;
        },
    };
    defer state.allocator.free(value);
    return c.JS_NewStringLen(ctx, value.ptr, value.len);
}

fn jsScopeKvPrefix(
    ctx: ?*c.JSContext,
    this: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);
    const id = scopeIdFromThis(state, ctx, this) catch return js_exception;
    defer state.allocator.free(id);
    const inst = scopeResolve(state, id) orelse return jsThrowInstanceNotFound(ctx);

    const prefix_str = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(prefix_str);
    const cursor_str = if (argc >= 2 and !c.JS_IsUndefined(argv[1]) and !c.JS_IsNull(argv[1]))
        valueToOwnedString(state, ctx, argv[1]) catch return js_exception
    else
        state.allocator.dupe(u8, "") catch return js_exception;
    defer state.allocator.free(cursor_str);

    const SCOPE_PREFIX_MAX: u32 = 1000;
    const SCOPE_PREFIX_DEFAULT: u32 = 100;
    const limit: u32 = if (argc >= 3 and !c.JS_IsUndefined(argv[2]) and !c.JS_IsNull(argv[2])) blk: {
        var n: i32 = 0;
        _ = c.JS_ToInt32(ctx, &n, argv[2]);
        if (n <= 0) break :blk SCOPE_PREFIX_DEFAULT;
        break :blk @min(@as(u32, @intCast(n)), SCOPE_PREFIX_MAX);
    } else SCOPE_PREFIX_DEFAULT;

    var scan = inst.kv.prefix(prefix_str, cursor_str, limit) catch |err| {
        state.pending_kv_error = err;
        return js_null;
    };
    defer scan.deinit();

    const arr = c.JS_NewArray(ctx);
    for (scan.entries, 0..) |e, i| {
        const obj = c.JS_NewObject(ctx);
        _ = c.JS_SetPropertyStr(ctx, obj, "key", c.JS_NewStringLen(ctx, e.key.ptr, e.key.len));
        _ = c.JS_SetPropertyStr(ctx, obj, "value", c.JS_NewStringLen(ctx, e.value.ptr, e.value.len));
        _ = c.JS_SetPropertyUint32(ctx, arr, @intCast(i), obj);
    }
    return arr;
}

fn scopeKvWrite(
    ctx: ?*c.JSContext,
    this: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
    op: ScopeKvOp,
) c.JSValue {
    const state = getState(ctx);
    if (state.platform == null) {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    }
    const min_args: c_int = if (op == .put) 2 else 1;
    if (argc < min_args) return js_undefined;

    const caps = state.platform_caps orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform.scope().kv writes are not configured on this worker");
        return js_exception;
    };
    const fn_ptr = caps.scope_kv_write orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform.scope().kv writes are not configured on this worker");
        return js_exception;
    };
    const fn_ctx = caps.ctx;

    const id = scopeIdFromThis(state, ctx, this) catch return js_exception;
    defer state.allocator.free(id);
    const key = kvWriteArgToOwnedString(state, ctx, argv[0], "key") catch return js_exception;
    defer state.allocator.free(key);
    const val = if (op == .put) blk: {
        break :blk kvWriteArgToOwnedString(state, ctx, argv[1], "value") catch return js_exception;
    } else state.allocator.dupe(u8, "") catch return js_exception;
    defer state.allocator.free(val);

    // Self-scope (the scope target IS the dispatching tenant, e.g. __admin__
    // deploying ITSELF via handleWsReset's `scope(__admin__).kv.delete`): route
    // through THIS dispatch's writeset like other platform writers, NOT the
    // cross-tenant trampoline. The trampoline opens a second TrackedTxn on a
    // store this dispatch already holds the single-writer lease for, so
    // `ensureOpen`'s `tryAcquire` returns null → Error.Conflict → KvFailed (the
    // __admin__ deploy-reset wedge). Riding the dispatch writeset also commits
    // atomically with the handler's own batch.
    if (std.mem.eql(u8, id, state.instance_id)) {
        // Write to BOTH the dispatch's speculative overlay (`state.txn`) and
        // the writeset — exactly as `jsKvSet`/`jsKvDelete` do. `state.txn` is
        // the local durability + read-your-write overlay AND what marks the
        // batch dirty so `finalizeBatch` proposes it; the writeset is the raft
        // payload for followers. BOTH are required: writing only the writeset
        // would leave a standalone self-scope write out of the overlay, so the
        // dispatch would look clean, the 2xx would be released, and the write
        // would be silently dropped (never locally durable, never proposed).
        // `state.txn` is THIS dispatch's already-open txn, so there is no
        // second `beginTrackedImmediate` acquire — avoiding the trampoline
        // double-acquire wedge.
        switch (op) {
            .put => {
                state.txn.put(key, val) catch |err| {
                    state.pending_kv_error = err;
                    return js_undefined;
                };
                state.writeset.addPut(key, val) catch |err| {
                    state.pending_kv_error = err;
                };
            },
            .delete => {
                state.txn.delete(key) catch |err| {
                    state.pending_kv_error = err;
                    return js_undefined;
                };
                state.writeset.addDelete(key) catch |err| {
                    state.pending_kv_error = err;
                };
            },
        }
        return js_undefined;
    }

    fn_ptr(fn_ctx, state.allocator, id, op, key, val) catch |err| switch (err) {
        error.InstanceNotFound => return jsThrowInstanceNotFound(ctx),
        else => {
            state.pending_kv_error = err;
            return js_undefined;
        },
    };
    return js_undefined;
}

fn jsScopeKvSet(
    ctx: ?*c.JSContext,
    this: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    return scopeKvWrite(ctx, this, argc, argv, .put);
}

fn jsScopeKvDelete(
    ctx: ?*c.JSContext,
    this: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    return scopeKvWrite(ctx, this, argc, argv, .delete);
}
