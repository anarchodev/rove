// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `http.fetch` / `http.cancelFetch` (transient streaming HTTP —
//! upstream streaming, `docs/architecture/routing-and-ingress.md`) JS
//! bindings.
//!
//! Durability is composed in JS by `globals/webhook.js` (kv.set
//! marker → http.fetch → baked `__system/webhook_onresult` shim →
//! optional `__rove_next` to customer `on_result`), not by a durable
//! Zig primitive (see the reified primitives in
//! `docs/architecture/effects-and-handlers.md` for the locked design).
//!
//!   http.fetch — transient, best-effort, fire-immediately. No
//!     raft involvement; the fetch-pool thread issues libcurl as
//!     soon as the binding accumulates it; no retry on crash. One
//!     callback (`on_chunk`); one knob (`stream: bool`) for
//!     "give me only the first chunk" (default) vs. "deliver
//!     every chunk as it arrives."
//!
//! The customer-facing API:
//!
//!   const fetch_id = http.fetch({
//!     url, method?, headers?, body?, timeout_ms?,
//!     on_chunk,                                       // required
//!     stream?,                                        // default false
//!     max_response_chunk_bytes?, max_total_response_bytes?, ctx?,
//!   });
//!   http.cancelFetch({ id });
//!
//! `_system.http.fetch` (`jsHttpFetch`) is the INTERNAL outbound
//! primitive (no customer `http.fetch` spelling). The two public
//! outbound surfaces compose over it: `on.fetch` (`jsOnFetch`,
//! connection-scoped, binds to the held chain) and `webhook.send`
//! (the JS shim, durable + connectionless). Plain
//! `_system.http.fetch` is the always-unbound Pattern-A transport the
//! webhook/email shims use.
//!
//! See the design docs for full semantics. This file is the
//! C-level glue; argument validation + accumulator append + nothing
//! else.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;

const globals = @import("../globals.zig");
const limiter = @import("../limiter.zig");
const kv_export = @import("../kv_export.zig");
const builtin_modules = @import("../builtin_modules.zig");
const log_mod = @import("rove-log");

const js_undefined = globals.js_undefined;
const js_exception = globals.js_exception;

/// Cap on the customer-supplied fetch id width for `http.cancelFetch`.
/// 1-256 utf8 bytes; matches the platform-derived id's actual shape
/// (sha256 hex = 64 chars; randomUUID = 36 chars) with headroom.
const FETCH_ID_MAX_LEN: usize = 256;

/// The platform's internal-door TLD. Effect verbs that lower to a fetch at
/// a platform-internal origin (`blob.*` → `rove-blob.internal` /
/// `rove-compose.internal`; `platform.*` → `rove-blob-read`/`rove-stage`/
/// `rove-compile.internal`; `browser`/logs → `rewind-logs.internal`) are
/// storage / control-plane I/O, NOT third-party egress — the fetch engine
/// rewrites these hosts to S3/internal targets. The outbound plan-rate
/// meters third-party egress, so these are exempt. One suffix rule covers
/// every current and future internal door; a customer can't reach a third
/// party through a `.internal` host, so exempting it opens no bypass.
const INTERNAL_DOOR_TLD = ".internal";

/// True when `url`'s host is a platform-internal door (`*.internal`).
fn targetsInternalDoor(url: []const u8) bool {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return false;
    const after = url[scheme + 3 ..];
    const host_end = std.mem.indexOfAny(u8, after, "/:?#") orelse after.len;
    return std.mem.endsWith(u8, after[0..host_end], INTERNAL_DOOR_TLD);
}

/// The decision behind `exportDoorAllowed`, split out so it is testable
/// without a JS context — the throw needs one, the policy does not.
fn exportDoorRefused(url: []const u8, is_system_module: bool) bool {
    return kv_export.isExportUrl(url) and !is_system_module;
}

/// Refuse a CUSTOMER-issued fetch at the kv-export door (rove#494).
///
/// Most `*.internal` origins are the lowering target of a customer verb —
/// `blob.*` reaches `rove-blob.internal`, a static serve reaches
/// `rove-static.internal` — so customer code names them by construction, and
/// each is guarded on its own terms (the blob door verifies a PUT body
/// against the hash it is stored under).
///
/// The kv-export door is not one of those. It has no customer spelling: the
/// `@rewind/export` verb writes a durable marker and arms a wake, and only
/// the baked `__system/export_run` issues the Cmd. Naming it from a handler
/// is therefore always illegitimate — and it matters, because the engine
/// rewrites that Cmd into a PUT flagged for the UNMETERED `exports/` pool
/// (rove#429). The cursor is caller-chosen, so a handler looping over
/// cursors mints a distinct part per call (different page boundary ⇒
/// different bytes ⇒ different hash) and `max_stored_bytes` stops bounding
/// anything.
///
/// Note the direction, because the sibling bug ran the other way:
/// RESTRICTING an action to the platform is sound, since the flag is
/// engine-set and a customer cannot claim it. EXEMPTING the platform from a
/// limit is not, because the platform re-issues work on the customer's
/// behalf and the evidence it was ever admitted is customer data (rove#336).
fn exportDoorAllowed(ctx: ?*c.JSContext, state: *globals.DispatchState, url: []const u8) bool {
    if (!exportDoorRefused(url, state.is_system_module)) return true;

    const msg = "this door is not callable from handler code";
    const err = c.JS_NewError(ctx);
    if (c.JS_IsException(err)) return false; // OOM building the Error — pending
    _ = c.JS_SetPropertyStr(ctx, err, "message", c.JS_NewStringLen(ctx, msg.ptr, msg.len));
    const code = "door_forbidden";
    _ = c.JS_SetPropertyStr(ctx, err, "code", c.JS_NewStringLen(ctx, code.ptr, code.len));
    _ = c.JS_Throw(ctx, err);
    std.log.warn(
        "rove-js: tenant={s} named the kv-export door from handler code — refused",
        .{state.instance_id},
    );
    return false;
}

/// Enforce the per-tenant OUTBOUND plan-rate at the fetch chokepoint.
/// Returns true when the fetch may proceed; on bucket exhaustion it
/// throws `Error{code:"rate_limited"}` into `ctx` and returns false (the
/// caller returns `js_exception`).
///
/// This is THE outbound-quota enforcement point (the outbound-boundary
/// rule, docs/architecture/privileged-surface.md). Every customer-initiated
/// third-party egress — `after.fetch`, `http.subscribe`, and the immediate
/// fire of `webhook.send` / `email.send` (which compose over the internal
/// fetch primitive) — funnels through these natives, so a tenant-pinnable
/// email/webhook package can't bypass the limit by not calling some
/// email-specific native. Enforcing at the native (not in a JS shim) is
/// what makes the plan quota un-bypassable.
///
/// ONE carve-out, correct by construction: fetches to platform-internal
/// doors (`*.internal`) are storage / control-plane I/O, not third-party
/// egress (`targetsInternalDoor`). A tenant cannot reach a third party
/// through a `.internal` host, so exempting them opens no bypass.
///
/// Being a baked `__system/*` module is NOT a carve-out, though it reads
/// like one: the exemption was written for a webhook RETRY, which re-issues
/// an already-admitted send — but `is_system_module` is set from the module
/// path (`worker_fire.zig`'s `isBuiltinPath`), so it is equally true of a
/// FIRST fire the tenant armed itself. Both `webhook.send({at})` and a
/// hand-written `_send/`+`_sched/` row pair (both prefixes are
/// customer-writable by design — `src/reserved/root.zig`'s `SHIM_WRITABLE_PREFIXES`)
/// arrive here as platform delivery, so the exemption made the whole quota
/// opt-in: a tenant bypassed it by deferring. Nothing at this seam can tell
/// an admitted send from an invented one, because the marker is customer
/// data — so every third-party egress is charged to the tenant that owns
/// the activation, retries included. `scripts/smoke/outbound_gate_smoke_v2.py`
/// holds the three paths that must all refuse.
///
/// A refused retry is not a lost send: `__system/webhook_fire` catches the
/// refusal and lets its already-armed watchdog re-fire (an UNCAUGHT throw
/// there would roll back the entry's own cleanup and re-fire at 1 Hz).
///
/// Fails OPEN on limiter OOM (same posture as the inbound request-rate
/// check in `worker_dispatch.zig`).
fn outboundRateOk(ctx: ?*c.JSContext, state: *globals.DispatchState, url: []const u8) bool {
    if (targetsInternalDoor(url)) return true; // internal storage/CP I/O — exempt
    const lim = state.limiter orelse return true; // test paths
    if (state.instance_id.len == 0) return true;

    // Admission before rate: a tenant whose plan grants no third-party
    // egress is refused permanently, so it must not consume a burst token
    // or read as a throttle the caller should retry.
    if (!state.plan_rate.outbound_enabled) {
        lim.outbound_disabled_refusals += 1;
        return throwOutboundDisabled(ctx, state);
    }

    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const allowed = lim.check(state.instance_id, .outbound, state.plan_rate, state.plan_gen, now_ns) catch |err| {
        std.log.warn("rove-js: limiter.check outbound for {s} failed: {s} — fail open", .{ state.instance_id, @errorName(err) });
        return true;
    };
    if (!allowed) {
        return throwOutboundLimited(ctx, state, lim, .outbound, "rate_limited", "outbound rate limit exceeded");
    }
    // The day-scale sustained ceiling (the spam bound — see
    // `limiter.Action.outbound_sustained`). Checked AFTER the burst bucket:
    // on a sustained refusal one burst token was consumed for nothing, which
    // is harmless (the burst bucket refills in seconds; the send was refused
    // either way). Saturation is an incident signal — distinct error code +
    // the `sustained_trips` counter.
    const sustained_ok = lim.check(state.instance_id, .outbound_sustained, state.plan_rate, state.plan_gen, now_ns) catch |err| {
        std.log.warn("rove-js: limiter.check outbound_sustained for {s} failed: {s} — fail open", .{ state.instance_id, @errorName(err) });
        return true;
    };
    if (!sustained_ok) {
        lim.sustained_trips += 1;
        std.log.warn("rove-js: OUTBOUND SUSTAINED CEILING tripped by {s} — day-scale budget exhausted", .{state.instance_id});
        return throwOutboundLimited(ctx, state, lim, .outbound_sustained, "outbound_sustained_limited", "sustained outbound budget exhausted");
    }
    return true;
}

/// Throw the plan-admission refusal: this tenant's plan grants no
/// third-party egress at all.
///
/// Deliberately NOT shaped like the rate refusals below — it carries no
/// Retry-After, because there is no delay after which the answer changes.
/// Telling a caller to retry a permanent refusal is how a `retry` wrapper
/// turns one refusal into an infinite loop, and how an operator reading the
/// logs sees congestion where there is a policy.
fn throwOutboundDisabled(ctx: ?*c.JSContext, state: *globals.DispatchState) bool {
    const msg = "outbound HTTP is not enabled for this tenant's plan";
    const err = c.JS_NewError(ctx);
    if (c.JS_IsException(err)) return false; // OOM building the Error — pending
    _ = c.JS_SetPropertyStr(ctx, err, "message", c.JS_NewStringLen(ctx, msg.ptr, msg.len));
    const code = "outbound_not_enabled";
    _ = c.JS_SetPropertyStr(ctx, err, "code", c.JS_NewStringLen(ctx, code.ptr, code.len));
    _ = c.JS_Throw(ctx, err);
    std.log.warn(
        "rove-js: outbound refused for {s} — plan grants no third-party egress",
        .{state.instance_id},
    );
    return false;
}

/// Throw the outbound-refusal Error (`{message, code}` with a Retry-After
/// figure in the message). Shared by the burst and sustained refusals so
/// the two differ only in `code` — which is what a caller alerts on.
fn throwOutboundLimited(
    ctx: ?*c.JSContext,
    state: *globals.DispatchState,
    lim: *limiter.RateLimiter,
    action: limiter.Action,
    code: []const u8,
    what: []const u8,
) bool {
    const retry_after = lim.retryAfterSeconds(state.instance_id, action);
    const msg = std.fmt.allocPrintSentinel(
        state.allocator,
        "{s}, retry after {d}s",
        .{ what, retry_after },
        0,
    ) catch {
        _ = c.JS_ThrowOutOfMemory(ctx);
        return false;
    };
    defer state.allocator.free(msg);

    const err = c.JS_NewError(ctx);
    if (c.JS_IsException(err)) return false; // OOM building the Error — pending
    _ = c.JS_SetPropertyStr(ctx, err, "message", c.JS_NewStringLen(ctx, msg.ptr, msg.len));
    _ = c.JS_SetPropertyStr(ctx, err, "code", c.JS_NewStringLen(ctx, code.ptr, code.len));
    _ = c.JS_Throw(ctx, err);
    return false;
}

// ── http.fetch / http.cancelFetch — transient streaming HTTP ─────────────

/// `http.fetch(opts) -> fetch_id` — transient streaming HTTP.
pub fn jsHttpFetch(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (argc < 1 or !c.JS_IsObject(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "http.fetch requires an options object");
        return js_exception;
    }
    const opts = argv[0];

    var row = buildFetchRow(ctx, state, opts) catch |err| switch (err) {
        error.JsException => return js_exception,
        else => {
            state.pending_kv_error = err;
            return js_exception;
        },
    };
    // Outbound plan-rate — checked after the row is built (reuses row.url)
    // but before it is accumulated, so a rejected send has no side effect.
    if (!exportDoorAllowed(ctx, state, row.url) or !outboundRateOk(ctx, state, row.url)) {
        row.deinit(state.allocator);
        return js_exception;
    }
    // Plain `http.fetch` is the always-unbound Pattern-A transient —
    // its `on_chunk` module fires as a separate chain (never binds the
    // calling chain; binding is `on.fetch`'s job). The success seam
    // (`worker_dispatch.zig`) leaves `bind = false` for a
    // non-`connection_scoped` fetch.
    state.http_fetch_index += 1;
    // Build the id JS string NOW — `appendPendingFetch` transfers
    // ownership of `row.id` into the PendingFetch and clears the
    // carrier's copy, so reading `row.id` afterward yields an
    // empty slice. `JS_NewStringLen` copies the bytes, so `res`
    // is independent of `row`'s subsequent fate.
    const res = c.JS_NewStringLen(ctx, row.id.ptr, row.id.len);
    // Accumulate into the per-DispatchState pending-fetches list.
    // The worker's batch-finalize phase flushes the list to
    // NodeState.fetch_pending; the fetch-pool thread drains that
    // queue and fires libcurl. If the handler throws / faults before
    // flush, DispatchState's deinit frees the entries — no orphan
    // fetches.
    appendPendingFetch(state, &row) catch |err| {
        // Allocator failure on the dupe/append; tear down `row`
        // (still allocator-owned by this fn) + the id string, and
        // surface as a JS exception.
        c.JS_FreeValue(ctx, res);
        row.deinit(state.allocator);
        state.pending_kv_error = err;
        return js_exception;
    };
    // `appendPendingFetch` transferred ownership of every owned
    // slice on `row` into the PendingFetch (or, on the null-
    // accumulator path, left them for this `deinit` to free).
    row.deinit(state.allocator);
    return res;
}

/// `__rove.fetch(opts)` — gated twin of `_system.http.fetch` for baked
/// `__system/` modules. Baked modules eval
/// AFTER the `_harden.js` `delete globalThis._system` step, so they
/// can't reach `_system.http`; this persistent, `is_system_module`-gated
/// op (in the `__rove.*` holder, same posture as `__rove.wake.set`) is
/// how `__system/webhook_fire` issues the retry/scheduled-fire fetch.
pub fn jsSystemFetch(
    ctx: ?*c.JSContext,
    this: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (!state.is_system_module) {
        _ = c.JS_ThrowTypeError(ctx, "__rove.fetch is not available to customer code");
        return js_exception;
    }
    return jsHttpFetch(ctx, this, argc, argv);
}

/// Transfer `BuiltFetch`'s owned slices into a `PendingFetch`
/// appended to `state.pending_fetches.*`. Dups `tenant_id` (which
/// `BuiltFetch` doesn't carry — it's implicit on the binding
/// side). On allocator failure, returns OutOfMemory; caller
/// frees the source `row` (the dups that DID succeed get freed
/// by the partial-rollback below).
fn appendPendingFetch(state: *globals.DispatchState, row: *BuiltFetch) !void {
    const a = state.allocator;
    // Fold BEFORE the accumulator check below: issuing the fetch is what the
    // handler did, and it got an id back either way. Whether a transport
    // ultimately fires it — a connection-scoped `after.fetch` is dropped at
    // the success seam — is a platform decision downstream of the handler, and
    // a replay's recorder sees the issue, not the drop. Folding only the
    // queued ones would make prod and replay disagree about identical
    // handler behaviour.
    if (globals.digestBegin(state)) |start| {
        var dg = start;
        dg.fetch(row.method, row.url, row.body);
        globals.digestCommit(state, dg);
    }
    // If the caller didn't provide a fetch accumulator (test
    // paths, anonymous dispatch), the fetch is dropped — the
    // binding still returns an id so the customer's code sees
    // success, but no transport will fire.
    const out = state.pending_fetches orelse return;

    const tid_dup = try a.dupe(u8, state.instance_id);
    errdefer a.free(tid_dup);

    try out.ensureUnusedCapacity(a, 1);
    out.appendAssumeCapacity(.{
        .tenant_id = tid_dup,
        .id = row.id,
        .url = row.url,
        .method = row.method,
        .headers_json = row.headers_json,
        .body = row.body,
        .timeout_ms = row.timeout_ms,
        .on_chunk_module = row.on_chunk_module,
        .ctx_json = row.ctx_json,
        .stream = row.stream,
        .relay = row.relay,
        .max_response_chunk_bytes = row.max_response_chunk_bytes,
        .max_total_response_bytes = row.max_total_response_bytes,
        .held = row.held,
        // `bind` is COMPUTED at the handler-success seam
        // (`worker_dispatch.zig`: only `connection_scoped` on.fetch
        // binds).
        .bind = false,
        .bound_send_id = row.bound_send_id,
        .name = row.name,
        .connection_scoped = row.connection_scoped,
    });
    // Ownership transferred — clear the carrier's slices so its
    // deinit is a no-op.
    row.id = &.{};
    row.url = &.{};
    row.method = &.{};
    row.headers_json = &.{};
    row.body = &.{};
    row.on_chunk_module = &.{};
    row.ctx_json = &.{};
    row.bound_send_id = &.{};
    row.name = &.{};
}

/// `_system.on.fetch(url, opts?)` — connection-scoped outbound
/// (`docs/handler-shape.md` §2.3). `opts.on` selects the bound export —
/// the SAME key the customer writes on `after.fetch` (the shim passes it
/// through; no wire respelling). Issues an
/// HTTP request whose result wakes THIS connection: chunks resume the
/// held chain's `{on}` export (default `onFetchChunk`). Connection-only
/// — if the activation doesn't end up holding the socket the fetch is
/// INERT (dropped at the success seam, no unbound fire); connectionless
/// outbound is `webhook.send`. The transient twin of `webhook.send`;
/// composes over the same fetch primitive as `http.fetch` but always
/// binds-or-drops, so `on_chunk` (the unbound module path) is unused.
pub fn jsOnFetch(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (argc < 1 or !c.JS_IsString(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "after.fetch(url, opts?) requires a url string");
        return js_exception;
    }
    // `opts` (arg1) is optional; the field readers need a real object
    // (reading a prop off `undefined` throws), so substitute a fresh
    // empty object when absent.
    const made_opts = !(argc >= 2 and c.JS_IsObject(argv[1]));
    const opts: c.JSValue = if (made_opts) c.JS_NewObject(ctx) else argv[1];
    defer if (made_opts) c.JS_FreeValue(ctx, opts);

    var row = buildOnFetchRow(ctx, state, argv[0], opts) catch |err| switch (err) {
        error.JsException => return js_exception,
        else => {
            state.pending_kv_error = err;
            return js_exception;
        },
    };
    if (!exportDoorAllowed(ctx, state, row.url) or !outboundRateOk(ctx, state, row.url)) {
        row.deinit(state.allocator);
        return js_exception;
    }
    state.http_fetch_index += 1;
    // Customer-visible: the opaque `ftch_<hex>` form (§7.5) — the SAME
    // string `request.fetchId` carries, so equality comparison works
    // across the return value and the resume surface
    // (decisions.md §4.9). Engine-internal keys (msg
    // router, S3 upload) keep the bare hex.
    std.debug.assert(row.id.len <= 64);
    var fid_buf: [log_mod.FETCH_ID_PREFIX.len + 64]u8 = undefined;
    @memcpy(fid_buf[0..log_mod.FETCH_ID_PREFIX.len], log_mod.FETCH_ID_PREFIX);
    @memcpy(fid_buf[log_mod.FETCH_ID_PREFIX.len..][0..row.id.len], row.id);
    const res = c.JS_NewStringLen(ctx, &fid_buf, log_mod.FETCH_ID_PREFIX.len + row.id.len);
    // Captured before append blanks the carrier below.
    const had_on = row.name.len > 0;
    const streamed = row.stream;
    appendPendingFetch(state, &row) catch |err| {
        c.JS_FreeValue(ctx, res);
        row.deinit(state.allocator);
        state.pending_kv_error = err;
        return js_exception;
    };
    row.deinit(state.allocator);
    // Promise form (`held.zig`): a bare NON-STREAMED `after.fetch(url)`
    // on a held connection resolves once with the whole buffered
    // response (`{status, bytes, text, headers?, truncated}`). `{on}`
    // keeps the export flow (transitional — slated for removal once the
    // apps migrate to `await`), and so does `stream: true`: a promise
    // settles once, so a chunked fetch keeps its per-event export
    // defaults (`onFetchChunk`/`onFetchDone`) and the id return the
    // spool handlers key their accumulators by. The fetch id still
    // rides the promise as `.fetchId` for `after.cancel`.
    promise_blk: {
        if (had_on or streamed) break :promise_blk;
        const promises = state.host_promises orelse break :promise_blk;
        const fetches = state.pending_fetches orelse break :promise_blk;
        if (fetches.items.len == 0) break :promise_blk;
        var funcs: [2]c.JSValue = undefined;
        const promise = c.JS_NewPromiseCapability(ctx, &funcs);
        if (c.JS_IsException(promise)) break :promise_blk;
        promises.append(state.allocator, .{ .resolve = funcs[0], .reject = funcs[1] }) catch {
            c.JS_FreeValue(ctx, funcs[0]);
            c.JS_FreeValue(ctx, funcs[1]);
            c.JS_FreeValue(ctx, promise);
            break :promise_blk;
        };
        fetches.items[fetches.items.len - 1].promise_idx = @intCast(promises.items.len - 1);
        // The Fetch-API shape (rove#930): the engine runs AUTO mode for the
        // promise form — settle at completion under the chunk cap, else at
        // headers with chunk pulls. `capBytes` rides the promise so the
        // shim's `r.text()` collector knows where its rejection line is.
        fetches.items[fetches.items.len - 1].auto = true;
        _ = c.JS_SetPropertyStr(ctx, promise, "capBytes", c.JS_NewInt64(ctx, @intCast(fetches.items[fetches.items.len - 1].max_response_chunk_bytes)));
        _ = c.JS_SetPropertyStr(ctx, promise, "fetchId", res); // consumes res
        return promise;
    }
    return res;
}

/// Build a `BuiltFetch` for `on.fetch`: `url` is a positional string
/// (arg0, not `opts.url`); the shared transport fields come from `opts`;
/// `opts.on` (the customer's `{on}` key, unchanged) selects the bound
/// export via `name`. `connection_scoped = true`,
/// `on_chunk` empty (a connection-scoped fetch never fires unbound).
fn buildOnFetchRow(
    ctx: ?*c.JSContext,
    state: *globals.DispatchState,
    url_val: c.JSValue,
    opts: c.JSValue,
) !BuiltFetch {
    const a = state.allocator;
    var fetched: FetchExtracted = .{};
    errdefer fetched.deinit(a);

    fetched.id = try deriveFetchIdHex(a, state.request_id, state.http_fetch_index);
    {
        var len: usize = 0;
        const cstr = c.JS_ToCStringLen(ctx, &len, url_val);
        if (cstr == null) return error.JsException;
        defer c.JS_FreeCString(ctx, cstr);
        fetched.url = try a.dupe(u8, @as([*]const u8, @ptrCast(cstr))[0..len]);
    }
    fetched.method = try dupeJsString(ctx, a, opts, "method", "GET");
    fetched.body = try dupeJsStringOrBytes(ctx, a, opts, "body", "");
    fetched.headers_json = try dupeJsObjectAsJson(ctx, a, opts, "headers", "{}");
    fetched.ctx_json = try dupeJsObjectAsJson(ctx, a, opts, "ctx", "null");
    // Connection-scoped fetches always bind-or-drop, so the unbound
    // `on_chunk` module path is never consulted — leave it empty.
    fetched.on_chunk_module = try a.dupe(u8, "");
    fetched.bound_send_id = try a.dupe(u8, "");
    // `{on}` → the bound-export override (`name`). Empty = default
    // `onFetchChunk`.
    fetched.name = try dupeJsString(ctx, a, opts, "on", "");
    if (fetched.name.?.len > 0 and !isValidExportName(fetched.name.?)) {
        _ = c.JS_ThrowTypeError(
            ctx,
            "after.fetch: `on` must be a JS identifier (alphanumeric/underscore/$, first char non-digit)",
        );
        return error.JsException;
    }

    const stream = try getBoolField(ctx, opts, "stream", false);
    // The CAS→connection relay (rove#441): honored by the engine only
    // for a bound streaming read of a content-addressed door
    // (`rove-static.internal` / `rove-blob.internal` GET); inert on
    // any other fetch shape, so passing it costs nothing and grants
    // nothing.
    const relay = try getBoolField(ctx, opts, "relay", false);
    const timeout_ms_i32 = try getIntField(ctx, opts, "timeout_ms", 30_000);
    const max_chunk_i32 = try getIntField(ctx, opts, "max_response_chunk_bytes", 256 * 1024);
    const max_total_i64 = try getInt64Field(ctx, opts, "max_total_response_bytes", 50 * 1024 * 1024);

    const row: BuiltFetch = .{
        .id = fetched.id.?,
        .url = fetched.url.?,
        .method = fetched.method.?,
        .headers_json = fetched.headers_json.?,
        .body = fetched.body.?,
        .timeout_ms = @intCast(@max(timeout_ms_i32, 1)),
        .on_chunk_module = fetched.on_chunk_module.?,
        .ctx_json = fetched.ctx_json.?,
        .stream = stream,
        .relay = relay,
        .max_response_chunk_bytes = @intCast(@max(max_chunk_i32, 1)),
        .max_total_response_bytes = if (max_total_i64 < 1) 1 else @intCast(max_total_i64),
        .bound_send_id = fetched.bound_send_id.?,
        .name = fetched.name.?,
        .connection_scoped = true,
    };
    fetched = .{}; // ownership transferred
    return row;
}

/// `http.cancelFetch({id})` — cancel a not-yet-completed fetch.
/// Forwards to `FetchEngine.cancel` via the `cancel_fetch`
/// trampoline. Cooperative: a chunk already in-flight at the
/// engine level may still land in `on_chunk` after the cancel
/// returns; the customer's chain ctx is the place to track "we
/// moved on" (the cooperative-cancel invariant for outbound fetch —
/// `docs/architecture/configuration-and-network.md`).
pub fn jsHttpCancelFetch(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (argc < 1 or !c.JS_IsObject(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "http.cancelFetch requires an options object with `id`");
        return js_exception;
    }
    const opts = argv[0];
    const id_v = c.JS_GetPropertyStr(ctx, opts, "id");
    defer c.JS_FreeValue(ctx, id_v);
    if (!c.JS_IsString(id_v)) {
        _ = c.JS_ThrowTypeError(ctx, "http.cancelFetch: `id` must be a string");
        return js_exception;
    }
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, id_v);
    if (cstr == null) return js_exception;
    defer c.JS_FreeCString(ctx, cstr);
    if (len == 0 or len > FETCH_ID_MAX_LEN) {
        _ = c.JS_ThrowRangeError(ctx, "http.cancelFetch: `id` must be 1-256 utf8 bytes");
        return js_exception;
    }
    // Accept the customer-visible `ftch_`-prefixed form (what
    // after.fetch() returns); the engine keys fetches by bare hex.
    var id_slice = @as([*]const u8, @ptrCast(cstr))[0..len];
    if (std.mem.startsWith(u8, id_slice, log_mod.FETCH_ID_PREFIX)) {
        id_slice = id_slice[log_mod.FETCH_ID_PREFIX.len..];
    }
    if (state.cancel_fetch) |fn_ptr| {
        const fn_ctx = state.worker_ctx orelse return js_undefined;
        fn_ptr(fn_ctx, id_slice);
    }
    // Engine null (test paths / non-worker dispatch) → silent
    // no-op; the JS side expects this.
    return js_undefined;
}

// ── http.subscribe / http.cancelSubscription — held subscription ──────

/// `http.subscribe(opts) -> subscription_id` — held outbound
/// subscription (outbound fetch / libcurl multi,
/// `docs/architecture/configuration-and-network.md`; the held-transfer
/// slot of the four-primitive effect model, `docs/effect-algebra.md`).
///
/// Same options shape as `http.fetch` minus `timeout_ms` (held
/// transfers don't time out — they end on cancel or upstream close)
/// and `stream` (always true: held transfers stream by definition).
/// The `on_chunk` handler fires per upstream writeback as
/// `fetch_chunk` activations, terminating with `final: true,
/// ok: false` when the upstream closes — the customer's handler
/// interprets that as "subscription ended; reconnect if desired."
///
/// Returns the subscription id. Pair with
/// `http.cancelSubscription({ id })` to stop the transfer; cancel
/// is cooperative — a chunk already in flight may still land in
/// `on_chunk` after the cancel returns.
pub fn jsHttpSubscribe(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (argc < 1 or !c.JS_IsObject(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "http.subscribe requires an options object");
        return js_exception;
    }
    const opts = argv[0];

    var row = buildFetchRow(ctx, state, opts) catch |err| switch (err) {
        error.JsException => return js_exception,
        else => {
            state.pending_kv_error = err;
            return js_exception;
        },
    };
    if (!exportDoorAllowed(ctx, state, row.url) or !outboundRateOk(ctx, state, row.url)) {
        row.deinit(state.allocator);
        return js_exception;
    }
    // Held subscriptions are always streaming + don't time out.
    // Force the shape so the customer's `timeout_ms` / `stream`
    // options can't accidentally weaken the contract.
    row.stream = true;
    row.timeout_ms = 0;
    row.held = true;

    state.http_fetch_index += 1;
    // Customer-visible id: the same `ftch_<hex>` form as after.fetch's
    // return and activation.fetchId (§7.5 — ONE id spelling on every
    // surface, so it correlates with the chunk activations).
    // cancelSubscription strips the prefix on the way back in.
    var sid_buf: [log_mod.FETCH_ID_PREFIX.len + 64]u8 = undefined;
    @memcpy(sid_buf[0..log_mod.FETCH_ID_PREFIX.len], log_mod.FETCH_ID_PREFIX);
    @memcpy(sid_buf[log_mod.FETCH_ID_PREFIX.len..][0..row.id.len], row.id);
    const res = c.JS_NewStringLen(ctx, &sid_buf, log_mod.FETCH_ID_PREFIX.len + row.id.len);
    appendPendingFetch(state, &row) catch |err| {
        c.JS_FreeValue(ctx, res);
        row.deinit(state.allocator);
        state.pending_kv_error = err;
        return js_exception;
    };
    row.deinit(state.allocator);
    return res;
}

/// `http.cancelSubscription({id})` — cancel a held subscription.
/// Identical wiring to `http.cancelFetch` (the engine cancel path
/// is the same machinery for both kinds); the separate name is for
/// customer-facing clarity.
pub fn jsHttpCancelSubscription(
    ctx: ?*c.JSContext,
    self: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    return jsHttpCancelFetch(ctx, self, argc, argv);
}

/// Local carrier for a just-built fetch. `deinit` frees every owned slice.
const BuiltFetch = struct {
    id: []u8,
    url: []u8,
    method: []u8,
    headers_json: []u8,
    body: []u8,
    timeout_ms: u32,
    /// `on_chunk` module path. Required by `buildFetchRow` — the
    /// chunk callback is the only path (no `on_done` / `pipe_to`).
    /// Allocator-owned.
    on_chunk_module: []u8,
    /// Threaded forward to each activation as `request.ctx`. JSON
    /// string; "null" when omitted.
    ctx_json: []u8,
    /// `stream: false` (default) → fire exactly one `on_chunk` event
    /// with `final: true` (up to `max_response_chunk_bytes` of body;
    /// cap-overflow sets `body_truncated`). `stream: true` → fire one
    /// event per upstream writeback, last carrying `final: true`.
    stream: bool,
    /// The CAS→connection relay flag (rove#441) — see
    /// `PendingFetch.relay` for the full contract. Threaded through
    /// verbatim; the engine decides applicability.
    relay: bool = false,
    max_response_chunk_bytes: u32,
    max_total_response_bytes: u64,
    /// Held-transfer flag (outbound fetch / libcurl multi,
    /// `docs/architecture/configuration-and-network.md`): set true by
    /// `jsHttpSubscribe`; false for `jsHttpFetch`. Threaded into
    /// the `PendingFetch` the engine reads.
    held: bool = false,
    /// Cross-worker held state (`docs/architecture/effects-and-handlers.md`):
    /// webhook.send shim passes the send_id (the `_send/owed/{id}` suffix) so the
    /// FetchEngine's chunk router can consult `bound_send_owners` to
    /// route the callback to the cont's owning worker. Platform-only
    /// (the webhook.send JS shim sets it); customers don't reach
    /// for this option directly. Empty / null when the caller is
    /// plain `http.fetch` (no held-sync attachment).
    bound_send_id: []u8 = &.{},
    /// Customer-facing override for the bound-fetch dispatch
    /// target. Empty (default) → chunks dispatch to the
    /// `onFetchChunk` named export. Non-empty → chunks dispatch
    /// to the export named here. Lets multi-bind handlers split
    /// per-fetch logic into distinct exports without a
    /// switch(request.fetchId) at the top of one shared handler.
    /// Allocator-owned dupe.
    name: []u8 = &.{},
    /// True ⇒ this fetch was issued via
    /// `on.fetch` — a CONNECTION trigger. Connection-scoped by
    /// construction: it binds to the held chain (chunks → `{on}` /
    /// `onFetchChunk`) when the activation holds the socket, and is
    /// INERT (dropped, no unbound fire) when it doesn't — the model's
    /// "all `on.*` are for the current connection; connectionless
    /// outbound is `webhook.send`" rule (`docs/handler-shape.md` §2.4).
    /// Plain `http.fetch` leaves this false (fires unbound when not
    /// held).
    connection_scoped: bool = false,

    fn deinit(self: *BuiltFetch, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.url);
        allocator.free(self.method);
        allocator.free(self.headers_json);
        allocator.free(self.body);
        allocator.free(self.on_chunk_module);
        allocator.free(self.ctx_json);
        if (self.bound_send_id.len > 0) allocator.free(self.bound_send_id);
        if (self.name.len > 0) allocator.free(self.name);
        self.* = undefined;
    }
};

/// Build + validate the fetch options object → owned `BuiltFetch`.
/// `on_chunk` is required. `stream: bool` (default false) selects
/// single-chunk vs streaming delivery.
fn buildFetchRow(
    ctx: ?*c.JSContext,
    state: *globals.DispatchState,
    opts: c.JSValue,
) !BuiltFetch {
    const a = state.allocator;
    var fetched: FetchExtracted = .{};
    errdefer fetched.deinit(a);

    fetched.id = try deriveFetchIdHex(a, state.request_id, state.http_fetch_index);
    fetched.url = try dupeJsString(ctx, a, opts, "url", null);
    fetched.method = try dupeJsString(ctx, a, opts, "method", "GET");
    fetched.body = try dupeJsStringOrBytes(ctx, a, opts, "body", "");
    fetched.headers_json = try dupeJsObjectAsJson(ctx, a, opts, "headers", "{}");
    fetched.ctx_json = try dupeJsObjectAsJson(ctx, a, opts, "ctx", "null");
    fetched.on_chunk_module = try dupeJsString(ctx, a, opts, "on_chunk", "");
    // Platform-internal `bound_send_id` option used by the
    // `webhook.send` JS shim. Empty when absent — customers' plain
    // `http.fetch` never sets this.
    fetched.bound_send_id = try dupeJsString(ctx, a, opts, "bound_send_id", "");
    // Customer-facing `name:` override — see BuiltFetch.name. Empty
    // = use the default `onFetchChunk` export.
    fetched.name = try dupeJsString(ctx, a, opts, "name", "");
    if (fetched.name.?.len > 0) {
        if (!isValidExportName(fetched.name.?)) {
            _ = c.JS_ThrowTypeError(
                ctx,
                "http.fetch: `name` must be a JS identifier (alphanumeric/underscore/$, first char non-digit)",
            );
            return error.JsException;
        }
    }

    if (fetched.on_chunk_module.?.len == 0) {
        _ = c.JS_ThrowTypeError(ctx, "http.fetch: `on_chunk` (module path) is required");
        return error.JsException;
    }

    // A fetch result dispatches its `on_chunk` module with `is_system_module`
    // set from the module PATH, so a tenant that can name a baked module here
    // runs it privileged with a ctx it chose — the result-route twin of the
    // wake gate (rove#639; `isResultTargetable`). Refused at the ISSUE site, so
    // the caller gets a JS exception on the line that named the target, rather
    // than a silent drop when the result lands an activation later.
    //
    // System-issued fetches are exempt: `__rove.fetch` is already
    // `is_system_module`-gated, and the baked modules chain among themselves
    // (`webhook_fire` → `webhook_onresult`, `export_run` → itself).
    if (!state.is_system_module and
        builtin_modules.isBuiltinPath(fetched.on_chunk_module.?) and
        !builtin_modules.isResultTargetable(fetched.on_chunk_module.?))
    {
        _ = c.JS_ThrowTypeError(
            ctx,
            "http.fetch: `on_chunk` may not name a platform `__system/` module",
        );
        return error.JsException;
    }

    const stream = try getBoolField(ctx, opts, "stream", false);
    const timeout_ms_i32 = try getIntField(ctx, opts, "timeout_ms", 30_000);
    const max_chunk_i32 = try getIntField(ctx, opts, "max_response_chunk_bytes", 256 * 1024);
    const max_total_i64 = try getInt64Field(ctx, opts, "max_total_response_bytes", 50 * 1024 * 1024);

    const row: BuiltFetch = .{
        .id = fetched.id.?,
        .url = fetched.url.?,
        .method = fetched.method.?,
        .headers_json = fetched.headers_json.?,
        .body = fetched.body.?,
        .timeout_ms = @intCast(@max(timeout_ms_i32, 1)),
        .on_chunk_module = fetched.on_chunk_module.?,
        .ctx_json = fetched.ctx_json.?,
        .stream = stream,
        .max_response_chunk_bytes = @intCast(@max(max_chunk_i32, 1)),
        .max_total_response_bytes = if (max_total_i64 < 1) 1 else @intCast(max_total_i64),
        .bound_send_id = fetched.bound_send_id.?,
        .name = fetched.name.?,
    };
    fetched = .{}; // ownership transferred
    return row;
}

/// JS-identifier validator. Used to gate the customer-supplied
/// `name:` on http.fetch so a stray space or colon doesn't end up as
/// the resume export name (`fn_override`) and silently mis-dispatch.
/// Pub: `blob.seal`'s binding validates its `to` the same way.
pub fn isValidExportName(s: []const u8) bool {
    if (s.len == 0) return false;
    const first = s[0];
    if (!std.ascii.isAlphabetic(first) and first != '_' and first != '$') return false;
    for (s[1..]) |b| {
        if (!std.ascii.isAlphanumeric(b) and b != '_' and b != '$') return false;
    }
    return true;
}

const FetchExtracted = struct {
    id: ?[]u8 = null,
    url: ?[]u8 = null,
    method: ?[]u8 = null,
    headers_json: ?[]u8 = null,
    body: ?[]u8 = null,
    ctx_json: ?[]u8 = null,
    on_chunk_module: ?[]u8 = null,
    bound_send_id: ?[]u8 = null,
    name: ?[]u8 = null,

    fn deinit(self: *FetchExtracted, a: std.mem.Allocator) void {
        if (self.id) |s| a.free(s);
        if (self.url) |s| a.free(s);
        if (self.method) |s| a.free(s);
        if (self.headers_json) |s| a.free(s);
        if (self.body) |s| a.free(s);
        if (self.ctx_json) |s| a.free(s);
        if (self.on_chunk_module) |s| a.free(s);
        if (self.bound_send_id) |s| a.free(s);
        if (self.name) |s| a.free(s);
    }
};

/// Hex(sha256(u64-le(request_id) || u32-le("FTCH") || u32-le(fetch_index))).
/// 64 chars; stable per-replay. The "FTCH" tag is the literal
/// string `"FTCH"` (4 ASCII bytes); it stays fixed so fetch ids
/// remain deterministic across replay.
pub fn deriveFetchIdHex(a: std.mem.Allocator, request_id: u64, fetch_index: u32) ![]u8 {
    var input: [16]u8 = undefined;
    std.mem.writeInt(u64, input[0..8], request_id, .little);
    @memcpy(input[8..12], "FTCH");
    std.mem.writeInt(u32, input[12..16], fetch_index, .little);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&input, &digest, .{});
    const out = try a.alloc(u8, 64);
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out;
}

// ── Generic JS-property extraction helpers ─────────────────────────────

fn dupeJsString(
    ctx: ?*c.JSContext,
    a: std.mem.Allocator,
    obj: c.JSValue,
    name: [:0]const u8,
    default_str: ?[]const u8,
) ![]u8 {
    const v = c.JS_GetPropertyStr(ctx, obj, name.ptr);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v)) {
        if (default_str) |d| return try a.dupe(u8, d);
        return error.JsException;
    }
    if (!c.JS_IsString(v)) return error.JsException;
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, v);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    return try a.dupe(u8, @as([*]const u8, @ptrCast(cstr))[0..len]);
}

/// Like `dupeJsString`, but also accepts a Uint8Array. Fetch bodies
/// must carry binary payloads losslessly (`blob.put` media bytes);
/// routing raw bytes through a JS string would UTF-8-mangle them.
/// String values keep `dupeJsString`'s UTF-8-bytes semantics.
fn dupeJsStringOrBytes(
    ctx: ?*c.JSContext,
    a: std.mem.Allocator,
    obj: c.JSValue,
    name: [:0]const u8,
    default_str: ?[]const u8,
) ![]u8 {
    const v = c.JS_GetPropertyStr(ctx, obj, name.ptr);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v)) {
        if (default_str) |d| return try a.dupe(u8, d);
        return error.JsException;
    }
    if (c.JS_IsString(v)) {
        var len: usize = 0;
        const cstr = c.JS_ToCStringLen(ctx, &len, v);
        if (cstr == null) return error.JsException;
        defer c.JS_FreeCString(ctx, cstr);
        return try a.dupe(u8, @as([*]const u8, @ptrCast(cstr))[0..len]);
    }
    var byte_len: usize = 0;
    const buf_ptr = c.JS_GetUint8Array(ctx, &byte_len, v);
    if (buf_ptr == null) {
        // JS_GetUint8Array may have set a pending exception — clear
        // it so our own TypeError below is the one that surfaces.
        const pending = c.JS_GetException(ctx);
        c.JS_FreeValue(ctx, pending);
        _ = c.JS_ThrowTypeError(ctx, "fetch: `body` must be a string or Uint8Array");
        return error.JsException;
    }
    return try a.dupe(u8, buf_ptr[0..byte_len]);
}

fn dupeJsObjectAsJson(
    ctx: ?*c.JSContext,
    a: std.mem.Allocator,
    obj: c.JSValue,
    name: [:0]const u8,
    default_json: []const u8,
) ![]u8 {
    const v = c.JS_GetPropertyStr(ctx, obj, name.ptr);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v)) return try a.dupe(u8, default_json);
    if (c.JS_IsNull(v)) return try a.dupe(u8, "null");
    const s = c.JS_JSONStringify(ctx, v, js_undefined, js_undefined);
    if (c.JS_IsException(s) or c.JS_IsUndefined(s)) {
        c.JS_FreeValue(ctx, s);
        return error.JsException;
    }
    defer c.JS_FreeValue(ctx, s);
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, s);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    return try a.dupe(u8, @as([*]const u8, @ptrCast(cstr))[0..len]);
}

fn getIntField(
    ctx: ?*c.JSContext,
    obj: c.JSValue,
    name: [:0]const u8,
    default_val: i32,
) !i32 {
    const v = c.JS_GetPropertyStr(ctx, obj, name.ptr);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v)) return default_val;
    var out: i32 = 0;
    if (c.JS_ToInt32(ctx, &out, v) < 0) return error.JsException;
    return out;
}

fn getInt64Field(
    ctx: ?*c.JSContext,
    obj: c.JSValue,
    name: [:0]const u8,
    default_val: i64,
) !i64 {
    const v = c.JS_GetPropertyStr(ctx, obj, name.ptr);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v)) return default_val;
    var out: i64 = 0;
    if (c.JS_ToInt64(ctx, &out, v) < 0) return error.JsException;
    return out;
}

fn getBoolField(
    ctx: ?*c.JSContext,
    obj: c.JSValue,
    name: [:0]const u8,
    default_val: bool,
) !bool {
    const v = c.JS_GetPropertyStr(ctx, obj, name.ptr);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v)) return default_val;
    const r = c.JS_ToBool(ctx, v);
    if (r < 0) return error.JsException;
    return r != 0;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "exportDoorAllowed: the kv-export door is the one internal door a handler may not name" {
    // The predicate half, asserted without a JS context: everything that is
    // not the export door passes through untouched, so this gate can never
    // become a general internal-door ban. `blob.*` and a static serve reach
    // their doors from ordinary handler code and must keep doing so — the
    // failure mode of over-tightening here is silent, since it looks like
    // storage being broken rather than a policy being applied.
    try testing.expect(!kv_export.isExportUrl("http://rove-blob.internal/deadbeef"));
    try testing.expect(!kv_export.isExportUrl("http://rove-static.internal/abc"));
    try testing.expect(!kv_export.isExportUrl("http://rove-compose.internal/sid"));
    try testing.expect(!kv_export.isExportUrl("https://api.example.com/x"));
    // And the door itself, which only `__system/export_run` may issue.
    try testing.expect(kv_export.isExportUrl("http://rove-kvexport.internal/"));

    // The gate keys on the module, and `is_system_module` is engine-set from
    // the module path — a handler cannot claim it. This is the RESTRICTING
    // direction, which is why keying on it is sound here (rove#494) and was
    // not at the quota gate (rove#336).
    try testing.expect(exportDoorRefused("http://rove-kvexport.internal/", false));
    try testing.expect(!exportDoorRefused("http://rove-kvexport.internal/", true));
    // Every other door stays reachable from handler code either way.
    try testing.expect(!exportDoorRefused("http://rove-blob.internal/deadbeef", false));
    try testing.expect(!exportDoorRefused("https://api.example.com/x", false));
}

test "targetsInternalDoor: platform-internal hosts are exempt, third parties are not" {
    // Internal doors (blob / compose / platform / logs) — the outbound
    // plan-rate must NOT meter these (storage / control-plane I/O).
    try testing.expect(targetsInternalDoor("http://rove-blob.internal/deadbeef"));
    try testing.expect(targetsInternalDoor("http://rove-compose.internal/sid"));
    try testing.expect(targetsInternalDoor("http://rove-blob-read.internal/id/blob/h"));
    try testing.expect(targetsInternalDoor("http://rove-compile.internal/"));
    try testing.expect(targetsInternalDoor("http://rewind-logs.internal/v1/t/x"));
    try testing.expect(targetsInternalDoor("https://x.internal:8080/p?q=1")); // port + query
    // Third-party egress — metered.
    try testing.expect(!targetsInternalDoor("https://api.resend.com/emails"));
    try testing.expect(!targetsInternalDoor("https://hooks.example.com/notify"));
    // Not fooled by a path/query segment that merely contains ".internal".
    try testing.expect(!targetsInternalDoor("https://evil.com/.internal/x"));
    try testing.expect(!targetsInternalDoor("https://evil.com/?h=.internal"));
    // A host that merely ends in the literal ".internal" label still matches
    // (that IS the rule) — but a look-alike TLD like ".internalx" does not.
    try testing.expect(!targetsInternalDoor("http://host.internalx/y"));
    // Malformed / no scheme → not internal (metered, fail toward enforcing).
    try testing.expect(!targetsInternalDoor("rove-blob.internal/x"));
    try testing.expect(!targetsInternalDoor(""));
}

test "deriveFetchIdHex: stable across calls with same inputs" {
    const a = testing.allocator;
    const f1 = try deriveFetchIdHex(a, 42, 0);
    defer a.free(f1);
    const f2 = try deriveFetchIdHex(a, 42, 0);
    defer a.free(f2);
    try testing.expectEqualStrings(f1, f2);
    try testing.expectEqual(@as(usize, 64), f1.len);

    const f3 = try deriveFetchIdHex(a, 42, 1);
    defer a.free(f3);
    try testing.expect(!std.mem.eql(u8, f1, f3));
}
