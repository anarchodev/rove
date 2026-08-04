// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Activation-firer family — the `fire*Activation` entry points split out
//! of `worker_streaming.zig`.
//!
//! Each of these fires a customer handler synchronously from a `Msg`, with
//! no held socket: disconnect, subscription (cron / kv-react / boot), the
//! scheduler tick, durable-wake, chained (send_callback), blob-compose, and
//! fetch-chunk. All are thin wrappers over the shared `firePrep` + `runFire`
//! scaffold that stays in `worker_streaming.zig` (imported here as
//! `streaming`); each supplies a comptime `FinishSpec` plus the `Request` it
//! synthesizes. Writes commit asynchronously through `proposeForgetfulWrites`.
//!
//! `worker_streaming`'s Msg-ingress loop (`dispatchPendingMsgs`,
//! `serviceFetchEvents`, the subscription sweeps) calls back into these, so
//! the two files import each other — the same mutual-import shape
//! `worker_streaming` already has with `worker_ws.zig`. Every function takes
//! `worker: anytype`.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");

const dispatcher_mod = @import("dispatcher.zig");
const globals = @import("globals.zig");
const Request = dispatcher_mod.Request;
const components_mod = @import("components.zig");
const effect_mod = @import("effect/root.zig");
const builtin_modules_mod = @import("builtin_modules.zig");
const deployment_cache = @import("deployment_cache.zig");

const worker_mod = @import("worker.zig");
const worker_ws = @import("worker_ws.zig");
const dispatch = @import("worker_dispatch.zig");
const bodies_mod = @import("rove-bodies");
const ParkedUnit = worker_mod.ParkedUnit;
const resolveDeployment = worker_mod.resolveDeployment;

const streaming = @import("worker_streaming.zig");
const firePrep = streaming.firePrep;
const runFire = streaming.runFire;
const synthCtxBody = streaming.synthCtxBody;
const proposeForgetfulWrites = streaming.proposeForgetfulWrites;
const SubscriptionFireSource = streaming.SubscriptionFireSource;

pub fn fireDisconnectActivation(worker: anytype, ent: rove.Entity) void {
    const allocator = worker.allocator;
    const server = worker.h2;
    // Entity has a stream chain iff StreamChain.module_path
    // is non-empty — component presence is the membership test.
    const chain_st = server.reg.get(ent, &server.response_out, components_mod.StreamChain) catch return;
    if (chain_st.module_path.len == 0) return;
    const chain_ctx = server.reg.get(ent, &server.response_out, components_mod.ChainContext) catch return;
    std.log.info(
        "rove-js stream-disconnect: tenant={s} corr={s} activations={d}",
        .{ chain_ctx.tenant_id, chain_ctx.correlation_id orelse "(none)", chain_st.activation_count },
    );

    const path = chain_st.module_path;
    var p = firePrep(worker, chain_ctx.tenant_id, path, "stream-disconnect") orelse return;
    defer p.deinit(allocator);

    const body = synthCtxBody(allocator, chain_st.ctx_json) catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{path}) catch return;
    defer allocator.free(spath);

    const request: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        .activation = .disconnect,
        .trace = .{ .readset = &p.readset, .request_id = p.request_id, .correlation_id = chain_ctx.correlation_id },
        .plan = .{ .limiter = &worker.limiter, .storage = p.dep.inst.storage, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = p.dep.inst.platform },
    };
    // The handler's return shape is moot — the socket is closed
    // (`.drop` on both non-terminal arms). Writes still commit
    // asynchronously so observable side effects (kv
    // state, `_send/owed/*`, §4.5 wakes) materialize.
    runFire(worker, &p, request, .{
        .act = .disconnect,
        .site = "stream-disconnect",
        .on_cont = .warn,
        .on_stream = .warn,
    }, path, chain_ctx.correlation_id, chain_ctx.tenant_id, "");
}

/// Fire a subscription handler as a fresh chain
/// origin. Structural twin of `fireDisconnectActivation` (no held
/// socket, writes commit asynchronously via `proposeForgetfulWrites`)
/// but slimmer — no held stream to drain, no chunks to clean up.
///
/// **TEA framing:**
///   - **Msg**: `(subscription_fire, source)` where source is
///     one of {cron firedAt, kv key+op, boot deployment_id}.
///   - **prep**: resolveDeployment(tenant_id, module_path); mint
///     a fresh correlation_id; synthesize Request body `{ctx:{}}`.
///   - **run**: `dispatcher.runOutcome` (chain-origin txn).
///   - **apply (Cmd-list)**:
///       • terminal → propose writes (if any) + log; bytes go
///         nowhere (no socket to flush).
///       • continuation / stream → recorded + logged; ignored
///         (a subscription chain has no held socket so multi-hop
///         chains aren't expressible in v1; customer composes
///         multi-step via `http.send({on_result: ...})` which
///         routes as a `send_callback` activation, not as a held
///         continuation).
///
/// Errors return `void` — the caller is best-effort (apply-time
/// hook, boot fire). Failures log + skip the activation.
/// handler-shape.md §3: the conventional named export a `_subscriptions/`
/// fire dispatches to, by trigger source. Lets one module split its
/// boot / kv-react handling into distinct exports instead of one
/// `default` that branches on `request.activation.source.kind`.
fn subscriptionExport(source: SubscriptionFireSource) []const u8 {
    return switch (source) {
        .kv => "onSubscription",
    };
}

pub fn fireSubscriptionActivation(
    worker: anytype,
    tenant_id: []const u8,
    subscription_name: []const u8,
    module_path: []const u8,
    source: SubscriptionFireSource,
    /// durable-kv-subscriptions: the `_sub/dirty/{name}` marker this
    /// fire retires. Injected as a delete into the fire's writeset
    /// BEFORE the handler runs (the durable-wake cleanup pattern), so
    /// the clear commits atomically with the handler's effects — and
    /// same-tenant serialization makes the plain delete safe (no CAS:
    /// a later write's marker-set is ordered after this delete and
    /// re-arms).
    cleanup_key: []const u8,
) void {
    const allocator = worker.allocator;
    var p = firePrep(worker, tenant_id, module_path, "subscription-fire") orelse return;
    defer p.deinit(allocator);

    p.txn.delete(cleanup_key) catch |err| {
        std.log.warn("rove-js kv-react ({s}/{s}): marker txn.delete failed: {s}", .{ tenant_id, subscription_name, @errorName(err) });
        return; // marker survives -> sweep re-fires
    };
    p.ws.addDelete(cleanup_key) catch |err| {
        std.log.warn("rove-js kv-react ({s}/{s}): marker ws.addDelete failed: {s}", .{ tenant_id, subscription_name, @errorName(err) });
        return;
    };

    // Subscription chains start fresh — empty ctx, fresh
    // correlation_id. (The handler can pass ctx forward via its
    // own kv state if it wants persistent chain state across
    // fires; the platform doesn't carry any.)
    const body = synthCtxBody(allocator, "{}") catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{module_path}) catch return;
    defer allocator.free(spath);

    // Mint a fresh correlation_id for this chain origin. Format:
    // `sub-{name-prefix}-{request_id-hex}` — name-scoped + unique
    // enough to dedup in the replay UX. Truncated to keep length
    // bounded.
    var corr_buf: [80]u8 = undefined;
    const name_prefix_len: usize = @min(subscription_name.len, 32);
    const corr_full = std.fmt.bufPrint(
        &corr_buf,
        "sub-{s}-{x:0>16}",
        .{ subscription_name[0..name_prefix_len], p.request_id },
    ) catch corr_buf[0..0];

    // Named-export dispatch by trigger source (handler-shape.md §3):
    // a kv-react fire lands in `onSubscription`.
    // The handler never branches on `request.activation.source.kind`.
    // A missing conventional export is the fail-loud 404 backstop.
    // Recurrence (`cron(spec, target)`) names its own target via the
    // durable scheduler — not this path. First-class target
    // (decisions.md §4.5) — no synthetic query.

    // Synthesize the Request carrying the subscription source union
    // (the variant IS the activation payload).
    const req: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .fn_override = subscriptionExport(source),
        .activation = .{ .subscription_fire = .{ .name = subscription_name, .source = source } },
        .trace = .{ .readset = &p.readset, .request_id = p.request_id, .correlation_id = corr_full },
        .plan = .{ .limiter = &worker.limiter, .storage = p.dep.inst.storage, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = p.dep.inst.platform },
    };
    // The marker delete must land even for a read-only handler.
    runFire(worker, &p, req, .{
        .act = .subscription_fire,
        .site = "subscription-fire",
        .on_cont = .warn,
        .on_stream = .warn,
        .always_propose = true,
    }, module_path, corr_full, subscription_name, "");
}

/// §2.6 durable-wake: fire the baked `__system/scheduler_tick`
/// for one tenant. Structural twin of `fireSubscriptionActivation`
/// but: (1) the module is the node-level baked `__system/scheduler_tick`
/// (so `is_system_module` ⇒ it may call the capability-scoped
/// `__rove_set_wake` / `__rove_fire_wake`); (2) it installs the
/// durable-wake trampolines — `set_wake` → THIS tenant's slot,
/// `fire_wake` → the router; (3) no boot-marker injection.
/// `scheduler_tick` writes no kv of its own (the per-entry deletes
/// ride with each fired target's writeset via `__rove_fire_wake`), so
/// its writeset is normally empty → empty commit.
///
/// Fired inline by `durable_wake.sweepDurableWakes` on the
/// partition-owner worker (steady state, when `next_wake_ns` is due)
/// and by the post-commit bootstrap hook (P2). Errors log + skip —
/// the next sweep / promotion re-fires. `scheduler_tick` is our own
/// module and always returns terminal; a continuation/stream return
/// is treated as a bug (rolled back + logged).
pub fn fireSchedulerTick(worker: anytype, tenant_id: []const u8) void {
    const allocator = worker.allocator;
    const module_path = "__system/scheduler_tick";
    var p = firePrep(worker, tenant_id, module_path, "scheduler_tick") orelse return;
    defer p.deinit(allocator);

    const body = allocator.dupe(u8, "{\"ctx\":{}}") catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{module_path}) catch return;
    defer allocator.free(spath);

    var corr_buf: [48]u8 = undefined;
    const corr_full = std.fmt.bufPrint(&corr_buf, "sched-{x:0>16}", .{p.request_id}) catch corr_buf[0..0];

    const req: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        .is_system_module = builtin_modules_mod.isBuiltinPath(module_path),
        .activation = .{ .subscription_fire = .{ .name = "__scheduler_tick", .source = null } },
        .trace = .{ .readset = &p.readset, .request_id = p.request_id, .correlation_id = corr_full },
        .plan = .{ .limiter = &worker.limiter, .storage = p.dep.inst.storage, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = p.dep.inst.platform },
        .trampolines = .{
            .set_wake = &deployment_cache.TenantSlot.setWakeTrampoline,
            .set_wake_ctx = @ptrCast(p.dep.tc.slot),
            .fire_wake = &@TypeOf(worker.*).fireWakeTrampoline,
            .fire_wake_ctx = @ptrCast(worker),
        },
    };
    // `scheduler_tick` is our own module and always returns terminal;
    // a continuation/stream return is a bug (`.rollback_silent`).
    runFire(worker, &p, req, .{
        .act = .subscription_fire,
        .site = "scheduler_tick",
        .on_cont = .rollback_silent,
        .on_stream = .rollback_silent,
    }, module_path, corr_full, tenant_id, "");
}

// ── blob compose door (`docs/architecture/blob-write-recipes.md` §4) ─────────────

const COMPOSE_URL_PREFIX = "http://rove-compose.internal/";

pub fn isComposeUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, COMPOSE_URL_PREFIX);
}

/// The prompt-compose trigger: `blob.seal` emitted a post-commit fetch
/// Cmd at `rove-compose.internal/{sid}`; `tryDoorFetch` routes it here
/// instead of libcurl. Fire `__system/blob_compose` for the sealing
/// tenant with the Cmd's ctx — the builtin assembles the recipe rows
/// and hands the payload to blob.put (whose on_result flips the recipe
/// and chains to the customer's `{on}`). Deliberately moot-on-loss:
/// every failure here just logs and leaves the sealed meta row for the
/// materializer, so nothing in this function may be load-bearing.
pub fn fireBlobCompose(worker: anytype, pf_in: globals.PendingFetch) void {
    var pf = pf_in;
    defer pf.deinit(worker.allocator);
    const allocator = worker.allocator;
    const module_path = "__system/blob_compose";
    std.log.info("rove-js blob_compose: door fired tenant={s} url={s}", .{ pf.tenant_id, pf.url });

    var p = firePrep(worker, pf.tenant_id, module_path, "blob_compose") orelse return;
    defer p.deinit(allocator);

    const ctx_json = if (pf.ctx_json.len > 0) pf.ctx_json else "null";
    const body = std.fmt.allocPrint(allocator, "{{\"ctx\":{s}}}", .{ctx_json}) catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{module_path}) catch return;
    defer allocator.free(spath);

    var corr_buf: [48]u8 = undefined;
    const corr_full = std.fmt.bufPrint(&corr_buf, "compose-{x:0>16}", .{p.request_id}) catch corr_buf[0..0];

    const req: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        .is_system_module = builtin_modules_mod.isBuiltinPath(module_path),
        // durable_wake shape so the Cmd's ctx surfaces as `request.ctx`
        // in the builtin (the webhook_fire convention — subscription
        // fires carry no per-fire payload).
        .activation = .{ .durable_wake = .{
            .id = "blob_compose",
            .key = "",
            .scheduled_at_ns = 0,
            .msg_json = ctx_json,
        } },
        .trace = .{ .readset = &p.readset, .request_id = p.request_id, .correlation_id = corr_full },
        .plan = .{ .limiter = &worker.limiter, .storage = p.dep.inst.storage, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = p.dep.inst.platform },
    };
    runFire(worker, &p, req, .{
        .act = .durable_wake,
        .site = "blob_compose",
        .on_cont = .rollback_silent,
        .on_stream = .rollback_silent,
    }, module_path, corr_full, pf.tenant_id, "");
}

/// §2.6 durable-wake: dispatch one due `_sched/by_time` entry's
/// `target` handler as a `durable_wake` activation. Structural twin of
/// `fireSubscriptionActivation` but: (1) it injects the entry's
/// `cleanup_keys` as deletes into the handler's writeset BEFORE the
/// handler runs, so the entry's removal commits atomically with the
/// handler's effects (exactly-once on the normal path; a crash between
/// fire and commit leaves the keys for a boot/promotion re-fire — the
/// at-least-once *firing* contract); (2) the activation surface is
/// `request.activation = { kind:"durable_wake", id, key,
/// scheduled_at_ns, msg }`. No held socket; writes commit forgetfully.
///
/// Injecting the deletes means `wrote` is always true, so the cleanup
/// always proposes through raft even for a target that itself writes
/// nothing. Errors log + skip — the entry survives for the next
/// tick (its `_sched` keys weren't committed).
const DurableTarget = struct { module: []const u8, method: ?[]const u8 };

/// Split a durable-wake target `"module.method"` into its module path and
/// optional export (handler-shape.md §2.4). The method suffix is
/// recognized ONLY when the module part ends in `.mjs`/`.js` — so a bare
/// `"reports.mjs"` module, a slash path `"jobs/reminder"`, or a `__system/`
/// baked module stays whole (fires `default`), and only the documented
/// `"reports.mjs.weekly"` form carries an export. This rule is unambiguous
/// (a `.mjs` extension never gets mistaken for a method) and MUST match the
/// sim's `wake()` split in `src/replay/rewind_test.mjs`.
fn splitDurableTarget(target: []const u8) DurableTarget {
    const last_dot = std.mem.lastIndexOfScalar(u8, target, '.') orelse
        return .{ .module = target, .method = null };
    const head = target[0..last_dot];
    const tail = target[last_dot + 1 ..];
    if (tail.len > 0 and (std.mem.endsWith(u8, head, ".mjs") or std.mem.endsWith(u8, head, ".js")))
        return .{ .module = head, .method = tail };
    return .{ .module = target, .method = null };
}

test "splitDurableTarget: module.method only when module ends .mjs/.js" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    const expect = std.testing.expect;

    // Documented form → split.
    const a = splitDurableTarget("reports.mjs.weekly");
    try expectEqualStrings("reports.mjs", a.module);
    try expectEqualStrings("weekly", a.method.?);
    const a2 = splitDurableTarget("jobs.mjs.send");
    try expectEqualStrings("jobs.mjs", a2.module);
    try expectEqualStrings("send", a2.method.?);
    const a3 = splitDurableTarget("lib/util.js.run");
    try expectEqualStrings("lib/util.js", a3.module);
    try expectEqualStrings("run", a3.method.?);

    // Bare `.mjs` module (no method) — the extension is NOT a method.
    const b = splitDurableTarget("reports.mjs");
    try expectEqualStrings("reports.mjs", b.module);
    try expect(b.method == null);
    const b2 = splitDurableTarget("jobs/reminder.mjs");
    try expectEqualStrings("jobs/reminder.mjs", b2.module);
    try expect(b2.method == null);

    // No dot / slash path / baked system module → whole module, default.
    const c = splitDurableTarget("jobs/reminder");
    try expectEqualStrings("jobs/reminder", c.module);
    try expect(c.method == null);
    const c2 = splitDurableTarget("__system/cron_tick");
    try expectEqualStrings("__system/cron_tick", c2.module);
    try expect(c2.method == null);

    // A dotted module name that isn't `.mjs`/`.js` stays whole.
    const d = splitDurableTarget("my.config");
    try expectEqualStrings("my.config", d.module);
    try expect(d.method == null);
}

pub fn fireDurableWakeActivation(worker: anytype, dw: *effect_mod.msg.DurableWake) void {
    const allocator = worker.allocator;
    const tenant_id = dw.tenant_id;
    // A `schedule`/`cron` target may name `"module.method"` — fire the
    // named export instead of `default` (handler-shape.md §2.4).
    // Both verbs land here (`cron` re-dispatches through `schedule({in:0},
    // target)`), so this is the one split site. Mirrors the sim's `wake()`.
    const dt = splitDurableTarget(dw.module_path);
    const module_path = dt.module;
    var p = firePrep(worker, tenant_id, module_path, "durable-wake") orelse return;
    defer p.deinit(allocator);

    // The customer target reads `request.activation.msg`; also surface
    // the msg as `request.body = {"ctx": <msg>}` for uniformity with
    // the other fire paths (`JSON.parse(request.body).ctx`).
    const body = synthCtxBody(allocator, dw.msg_json) catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{module_path}) catch return;
    defer allocator.free(spath);

    // Inject the fired entry's `_sched/` deletes BEFORE the handler
    // runs — they commit atomically with the handler's effects.
    // This is why the spec sets `always_propose`: the writeset is
    // never empty, and even a continuation/stream return still
    // proposes (the cleanup must land).
    for (dw.cleanup_keys) |k| {
        p.txn.delete(k) catch |err| {
            std.log.warn("rove-js durable-wake ({s}/{s}): cleanup txn.delete failed: {s}", .{ tenant_id, dw.id, @errorName(err) });
            return;
        };
        p.ws.addDelete(k) catch |err| {
            std.log.warn("rove-js durable-wake ({s}/{s}): cleanup ws.addDelete failed: {s}", .{ tenant_id, dw.id, @errorName(err) });
            return;
        };
    }

    var corr_buf: [80]u8 = undefined;
    const id_prefix_len: usize = @min(dw.id.len, 32);
    const corr_full = std.fmt.bufPrint(&corr_buf, "wake-{s}-{x:0>16}", .{ dw.id[0..id_prefix_len], p.request_id }) catch corr_buf[0..0];

    const req: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        // `"module.method"` → fire the named export; a bare module → null
        // → the conventional `default` (rpc_dispatch.defaultExportForKind).
        .fn_override = dt.method,
        .is_system_module = builtin_modules_mod.isBuiltinPath(module_path),
        .activation = .{ .durable_wake = .{
            .id = dw.id,
            .key = dw.key,
            .scheduled_at_ns = dw.scheduled_at_ns,
            .msg_json = dw.msg_json,
        } },
        .trace = .{ .readset = &p.readset, .request_id = p.request_id, .correlation_id = corr_full },
        .plan = .{ .limiter = &worker.limiter, .storage = p.dep.inst.storage, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = p.dep.inst.platform },
    };

    var label_buf: [160]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "{s}/{s}", .{ tenant_id, dw.id }) catch tenant_id;
    runFire(worker, &p, req, .{
        .act = .durable_wake,
        .site = "durable-wake",
        .on_cont = .warn,
        .on_stream = .warn,
        .always_propose = true,
    }, module_path, corr_full, label, "");
}

/// Dispatch a chained handler activation produced by
/// `__rove_next` from a fetch handler (and from the
/// shim's onresult to invoke the customer's `on_result`). Structural
/// twin of `fireSubscriptionActivation`:
///
///   - **Msg**: `SendCallback{tenant_id, module_path, ctx_json,
///     fn_name?, correlation_id?}`.
///   - **prep**: resolve the cont's module on its tenant; build
///     `body = {"ctx":<ctx>}` (mirrors fireSubscriptionActivation
///     so customers' `JSON.parse(request.body).ctx` pattern is
///     uniform); reuse the inherited correlation_id when present
///     (replay UX groups multi-hop chains) or mint one based on
///     the request_id.
///   - **run**: `dispatcher.runOutcome`. `activation_source ==
///     .send_callback` so `request.activation.kind === "send_callback"`.
///   - **apply**: terminal → propose forgetfully; continuation /
///     stream → recorded but no held socket. Same posture as
///     subscription_fire — fire-and-forget.
///
/// No held socket. Writes commit forgetfully via
/// `proposeForgetfulWrites`. Errors return `void` (best-effort:
/// loss on crash is recovered by the producer's own retry hook —
/// the retry sweep, when a webhook leaves an `_send/owed/`
/// marker behind).
pub fn fireChainedActivation(
    worker: anytype,
    sc: *effect_mod.msg.SendCallback,
) void {
    const allocator = worker.allocator;
    const tenant_id = sc.tenant_id;
    const module_path = sc.module_path;
    var p = firePrep(worker, tenant_id, module_path, "chained-dispatch") orelse return;
    defer p.deinit(allocator);

    const ctx_src: []const u8 = if (sc.ctx_json.len > 0) sc.ctx_json else "null";
    const body = synthCtxBody(allocator, ctx_src) catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{module_path}) catch return;
    defer allocator.free(spath);

    // Inherit correlation_id when the cont carried one (chained from
    // a fetch handler — preserves the parent fetch's chain identity).
    // Otherwise mint `chain-<request_id>` so the hop self-identifies
    // in the replay tape.
    var corr_buf: [80]u8 = undefined;
    const corr_full: []const u8 = if (sc.correlation_id) |c|
        c
    else
        std.fmt.bufPrint(&corr_buf, "chain-{x:0>16}", .{p.request_id}) catch corr_buf[0..0];

    // First-class target for the named-export case (decisions.md
    // §4.5); default-export when fn_name is null/empty (parseDispatch
    // treats an empty override as unset).
    const req: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .fn_override = sc.fn_name,
        .is_system_module = builtin_modules_mod.isBuiltinPath(module_path),
        .activation = .send_callback,
        .trace = .{ .readset = &p.readset, .request_id = p.request_id, .correlation_id = corr_full },
        .plan = .{ .limiter = &worker.limiter, .storage = p.dep.inst.storage, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = p.dep.inst.platform },
    };
    // `.enqueue`: chained-from-chained re-enqueues another
    // SendCallback hop on the next tick (bounded recursion via the
    // dispatch BATCH cap), inheriting the same correlation_id.
    // `.tape = .callback`: the body envelope IS this hop's Msg — the
    // callee outcome for an on_result delivery, the bare threaded ctx
    // for an internal chained hop — recorded (with the resolved
    // export) so the activation is replayable.
    runFire(worker, &p, req, .{
        .act = .send_callback,
        .site = "chained-dispatch",
        .on_cont = .enqueue,
        .on_stream = .warn,
        .readonly_cont_commits = true,
        .tape = .callback,
    }, module_path, corr_full, module_path, "");
}

/// Dispatch one upstream fetch event as a chain activation.
/// Structural twin of `fireSubscriptionActivation` — no held socket,
/// writes commit forgetfully — but the activation source + payload
/// differ.
///
/// **TEA framing:**
///   - **Msg**: `(fetch_chunk, {seq, bytes, final, ...})` per
///     event. `final == true` marks the last event of the fetch
///     and carries terminal fields (status / ok / body_truncated);
///     intermediates have `final == false`.
///   - **prep**: resolve the `on_chunk` module on the event's
///     tenant; correlation_id `fetch-<id>` so every activation of
///     one fetch shares a chain identity; body `{ctx: <ctx_json>}`.
///   - **run**: `dispatcher.runOutcome`.
///   - **apply**: terminal → propose writes (if any) + log;
///     continuation / stream → recorded + logged + ignored (a
///     fetch chain has no held socket, same as subscription_fire).
///
/// Errors return `void` — `dispatchFetchEvents` is best-effort. An
/// event with an empty `on_chunk_module` (binding-side regression)
/// is a silent no-op.
/// Takes ownership of `event` — internal
/// defer deinits it on exit unless the gate logic parks it
/// (transferring ownership to
/// `worker.fetch_pending_durability`).
///
/// `parked_body_ref` is non-null when called from a parked
/// resume: it carries the BodyRef minted at the original
/// append site, and the gate uses it directly instead of
/// re-appending (which would mint a new batch + re-park).
/// Fresh-arrival callers pass `null`.
pub fn fireFetchEventActivation(
    worker: anytype,
    event: *components_mod.UpstreamFetchEvent,
    parked_body_ref: ?bodies_mod.BodyRef,
) void {
    // Ownership handling: deinit the event on every exit path
    // except the park branch (which transfers to
    // fetch_pending_durability).
    var parked_to_durability = false;
    defer if (!parked_to_durability)
        components_mod.UpstreamFetchEvent.deinitItem(event, worker.allocator);

    const module_path = event.on_chunk_module;
    if (module_path.len == 0) {
        std.log.warn(
            "rove-js fetch-event: fetch_id={s} has no on_chunk module; dropping",
            .{event.fetch_id},
        );
        return;
    }
    const tenant_id = event.tenant_id;
    const allocator = worker.allocator;

    var p = firePrep(worker, tenant_id, module_path, "fetch-event") orelse return;
    defer p.deinit(allocator);

    // Body `{ctx: <ctx_json>}`. `ctx_json` is the chain ctx the
    // originating `http.fetch` call passed; empty → `{}`.
    const ctx_src: []const u8 = if (event.ctx_json.len > 0) event.ctx_json else "{}";
    const body = synthCtxBody(allocator, ctx_src) catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{module_path}) catch return;
    defer allocator.free(spath);

    // Correlation: all activations of one fetch share `fetch-<id>`
    // so the replay UX groups the chunk chain with its terminal.
    var corr_buf: [80]u8 = undefined;
    const id_len: usize = @min(event.fetch_id.len, 64);
    const corr_full = std.fmt.bufPrint(
        &corr_buf,
        "fetch-{s}",
        .{event.fetch_id[0..id_len]},
    ) catch corr_buf[0..0];

    const req: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        .is_system_module = builtin_modules_mod.isBuiltinPath(module_path),
        .activation = .{ .fetch_chunk = .{
            .id = event.fetch_id,
            .seq = event.seq,
            .byte_offset = event.byte_offset,
            .bytes = event.bytes,
            .headers = event.fetch_headers,
            .final = event.final,
            .terminal_status = if (event.final) event.terminal_status else 0,
            .terminal_ok = if (event.final) event.terminal_ok else false,
            .body_truncated = if (event.final) event.body_truncated else false,
        } },
        .trace = .{ .readset = &p.readset, .request_id = p.request_id, .correlation_id = corr_full },
        .plan = .{ .limiter = &worker.limiter, .storage = p.dep.inst.storage, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = p.dep.inst.platform },
        .trampolines = .{
            // §6.4 held-sync resume hook. The baked
            // `__system/webhook_onresult` shim calls `__rove_resume_if_bound`
            // on terminal to wake any parked cont bound to this send-id.
            // Set on every fetch-event activation (the H2 path sets it
            // too, in `worker_dispatch.zig`); without this the JS builtin
            // sees a null trampoline + returns false, leaving the cont
            // parked until its 25s deadline.
            .resume_if_bound = &@TypeOf(worker.*).resumeIfBoundTrampoline,
            .resume_if_bound_ctx = @ptrCast(worker),
            .blob_write = &@TypeOf(worker.*).blobWriteTrampoline,
            .blob_seal = &@TypeOf(worker.*).blobSealTrampoline,
            .blob_session_ctx = @ptrCast(worker),
            .cancel_fetch = &@TypeOf(worker.*).cancelFetchTrampoline,
            .cancel_fetch_ctx = @ptrCast(worker),
        },
    };

    // Small fetch chunks ride inline in
    // the readset's `fetch_responses.inline_bytes` field — no
    // buffer append, no S3 PUT, handler runs immediately. The
    // raft entry's fsync IS the durability substrate (every
    // replica sees the bytes when the entry replicates).
    // Discriminator: `body_ref.batch_id == NO_BATCH` ⇒ inline.
    //
    // Larger chunks submit to the process-global blob coordinator
    // (`coord.submit` → seq) and park in `fetch_pending_durability`;
    // `drainFetchPendingDurability` re-fires the activation with the
    // materialized `BodyRef` once durable (closing the §5.1 outbound
    // unreplayability gap), then `coord.release`s the retained copy.
    //
    // The bytes still ride alongside on `activation_fetch_bytes`
    // for the handler's `request.activation.bytes` view; the
    // tape's `activation_bytes` still captures them too.
    //
    // Terminal-only events (final=true with no body bytes) still
    // capture a tape entry so the chain has the closing seq +
    // terminal status / ok / body_truncated for replay; both
    // body_ref and inline_bytes are empty.
    const FETCH_INLINE_THRESHOLD: usize = 16 * 1024;
    var body_ref: bodies_mod.BodyRef = .{ .batch_id = bodies_mod.NO_BATCH, .offset = 0, .len = 0 };
    var inline_bytes_for_tape: []const u8 = "";
    var content_hash_for_tape: []const u8 = "";
    // Only a chunk that actually carries bytes can be referenced; a
    // terminal-only event has nothing to name.
    const content_ref: ?[64]u8 = if (event.bytes.len > 0) event.content_hash else null;
    if (parked_body_ref) |saved| {
        // Resume from a previous park. The
        // body's batch was confirmed durable by
        // drainFetchPendingDurability before this re-fire; use
        // the saved ref directly + skip append. Re-appending
        // would mint a new batch and re-park.
        body_ref = saved;
    } else if (content_ref) |h| {
        // Content-addressed chunk (a `blob.get`): the bytes are ALREADY
        // durable and immutable at this tenant's `app-blobs/{h}`, so
        // recording them again would write a second permanent copy of an
        // object we already store — inline on the tape below the threshold,
        // and into the never-evicted body pool above it (rove#430, #304).
        //
        // So: reference, don't copy. `body_ref.len` still reports the chunk
        // size (the record stays a complete activation event); the payload is
        // recoverable by hash. Skipping the coordinator ALSO skips the
        // durability park — there is nothing to make durable, which removes an
        // S3 round trip from every large blob read.
        content_hash_for_tape = &h;
        body_ref = .{
            .batch_id = bodies_mod.NO_BATCH,
            .offset = 0,
            .len = @intCast(event.bytes.len),
        };
    } else if (event.bytes.len > 0 and event.bytes.len <= FETCH_INLINE_THRESHOLD) {
        // Inline fast path — no buffer append, the chunk bytes
        // ride on the tape entry directly. Raft entry fsync IS
        // the durability substrate.
        body_ref = .{
            .batch_id = bodies_mod.NO_BATCH,
            .offset = 0,
            .len = @intCast(event.bytes.len),
        };
        inline_bytes_for_tape = event.bytes;
    } else if (event.bytes.len > 0) {
        // Larger-than-threshold chunk — coord submit + park.
        // the streaming substrate (`docs/architecture/routing-and-ingress.md`):
        // submit returns a
        // seq; durability is observed via the coord's per-worker
        // HWM. Always park (no fast-durable bypass — submit is
        // strictly async, durable_seq can't have advanced past
        // this seq before the executor lands the PUT).
        if (worker.node.blob_coord.coordinator) |coord| {
            const wid = worker.coord_queue_id;
            const seq = coord.submit(wid, event.bytes) catch |err| blk: {
                std.log.warn(
                    "rove-js fetch-event: coord.submit tenant={s} bytes={d}: {s}",
                    .{ tenant_id, event.bytes.len, @errorName(err) },
                );
                break :blk @as(?u64, null);
            };
            if (seq) |s| {
                worker.fetch_pending_durability.append(worker.allocator, .{
                    .event = event.*,
                    .worker_seq = s,
                    .queue_id = wid,
                    .tenant_id_view = p.dep.inst.id,
                }) catch |err| {
                    std.log.warn(
                        "rove-js fetch-event: fetch_pending_durability.append tenant={s}: {s}",
                        .{ tenant_id, @errorName(err) },
                    );
                    return;
                };
                parked_to_durability = true;
                return;
            }
            // submit failed — fall through with empty body_ref.
            // The activation runs but the tape entry has no
            // BodyRef.
        }
    }
    // An engine-fired static chunk records no BYTES (rove#391). These chunks
    // are small, so one record per chunk rode the tape verbatim and S3 log
    // volume tracked static egress ~1:1 — the tenant paying its log-ingest
    // budget to SERVE. Nothing a replay could use is lost: the bytes are
    // immutable and content-addressed, and the inbound record they belong to
    // runs no customer code (`Outcome.static_served`).
    //
    // The activation still FIRES — only the recording is skipped. Returning
    // here instead would stop the streamer mid-asset.
    if (!event.static_serve) p.readset.fetch_responses.appendFetchResponse(
        event.fetch_id,
        event.seq,
        event.byte_offset,
        body_ref,
        event.final,
        if (event.final) event.terminal_status else 0,
        if (event.final) event.terminal_ok else false,
        if (event.final) event.body_truncated else false,
        event.fetch_headers orelse "",
        inline_bytes_for_tape,
        content_hash_for_tape,
    ) catch |err| {
        // Tape capture failures must never kill the request. Same
        // posture as `captureTapes`'s per-channel serialize
        // errors: log + skip.
        std.log.warn(
            "rove-js fetch-event: readset.fetch_responses append tenant={s} fetch_id={s}: {s}",
            .{ tenant_id, event.fetch_id, @errorName(err) },
        );
    };

    // The activation's input bytes (the upstream chunk
    // payload) get taped on `TapePayloads.activation_bytes` —
    // `runFire` captures them on every log record (`spec.tape = .activation`) so
    // replay reconstitutes the same handler invocation from the same
    // captured bytes.
    // `activation_bytes` is the SECOND copy of a chunk's payload — the
    // `fetch_responses` entry above is the first — so an engine static chunk
    // has to skip both, or the 1:1 growth this fixes just moves channels.
    // `spec.tape` is comptime, so the choice is two specialised calls rather
    // than a runtime flag.
    if (event.static_serve) {
        runFire(worker, &p, req, .{
            .act = .fetch_chunk,
            .site = "fetch-event",
            .on_cont = .enqueue,
            .on_stream = .warn,
            .readonly_cont_commits = true,
            .tape = .none,
        }, module_path, corr_full, module_path, "");
    } else {
        runFire(worker, &p, req, .{
            .act = .fetch_chunk,
            .site = "fetch-event",
            .on_cont = .enqueue,
            .on_stream = .warn,
            .readonly_cont_commits = true,
            .tape = .activation,
        }, module_path, corr_full, module_path, event.bytes);
    }
}
