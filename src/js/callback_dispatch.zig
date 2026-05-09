//! Callback dispatch — invokes the tenant's `onResult` handler after
//! the webhook-server finishes a webhook attempt (delivered or
//! terminally failed).
//!
//! Envelope-5 apply (Phase 5.5 d) writes `_callback/{id}` receipts
//! into the tenant's app.db when delivery completes. This phase,
//! driven from the worker
//! poll loop on the raft leader, scans those receipts, resolves the
//! customer's `on_result` handler path to bytecode, and invokes it
//! with a synthetic event object. Each tenant's successful invocations
//! (plus the receipt deletes) commit atomically in one SQLite txn and
//! propose through raft as a single writeset — same at-least-once /
//! deterministic-replay envelope as an HTTP-driven handler.
//!
//! ## Contract with the handler
//!
//! The callback handler is an ES module with a `default` export that
//! takes one argument — the event:
//!
//! ```js
//! // stripe/charge_result.mjs
//! export default function (event) {
//!   // event.webhookId  - id returned from webhook.send
//!   // event.outcome    - "delivered" | "failed"
//!   // event.attempts   - number
//!   // event.context    - whatever was passed to webhook.send
//!   // event.response   - { status, body, truncated } (delivered only)
//!   // event.error      - error name string           (failed only)
//!   if (event.outcome === "delivered") {
//!     kv.set(`charges/${event.context.chargeId}`, event.response.body);
//!   }
//! }
//! ```
//!
//! The handler may call `kv.*` and `webhook.send` — its writes go into
//! the same tenant batch txn as the receipt delete and replicate
//! through raft together. If the handler throws or hits its budget,
//! the savepoint rolls back and the receipt is KEPT for retry, so a
//! fixed redeploy picks up the backlog automatically. If the envelope
//! is malformed or the handler path is unknown, the receipt is
//! DROPPED with a warning (otherwise it'd accumulate forever).
//!
//! ## Leader + worker gating
//!
//! The caller is expected to invoke this only on the raft leader and
//! typically only from one worker index (e.g. worker 0) so two
//! threads on the same node don't race on the same receipt. As a
//! safety net, the full invoke+delete happens inside one SQLite
//! tenant txn, so a second worker hitting the same tenant mid-pass
//! gets SQLITE_BUSY and skips cleanly.

const std = @import("std");
const kv_mod = @import("rove-kv");
const tape_mod = @import("rove-tape");
const tenant_mod = @import("rove-tenant");
const schedule_server_mod = @import("rove-schedule-server");
const webhook_server_mod = @import("rove-webhook-server");

const dispatcher_mod = @import("dispatcher.zig");
const worker_mod = @import("worker.zig");
const sse_dispatch = @import("sse_dispatch.zig");
const raft_propose = @import("raft_propose.zig");

const Request = dispatcher_mod.Request;
const Budget = dispatcher_mod.Budget;

/// Default per-tenant cap per pass. Generous at 32 — a tenant with
/// more pending callbacks than this per tick is almost certainly
/// backlogged from a prior outage and will drain over subsequent
/// ticks. Small enough to keep one tenant from starving others.
pub const DEFAULT_MAX_PER_TENANT: u32 = 32;

/// One pass over every known tenant's `_callback/*` rows on the raft
/// leader. Returns the number of receipts visited (visited includes
/// both delivered and kept-for-retry).
pub fn dispatchCallbacks(worker: anytype, max_per_tenant: u32) !usize {
    if (!worker.raft.isLeader()) return 0;

    var total: usize = 0;
    var it = worker.tenant_files_map.iterator();
    while (it.next()) |entry| {
        const tc = entry.value_ptr.*;
        if (tc.current_deployment_id == 0) continue; // no code → nothing callable
        const inst_opt = worker.tenant.getInstance(tc.instance_id) catch |err| {
            std.log.warn(
                "rove-js callbacks: getInstance({s}) failed: {s}",
                .{ tc.instance_id, @errorName(err) },
            );
            continue;
        };
        const inst = inst_opt orelse continue;

        const n = drainTenantCallbacks(worker, tc, inst, max_per_tenant) catch |err| {
            std.log.warn(
                "rove-js callbacks: tenant {s}: {s}",
                .{ inst.id, @errorName(err) },
            );
            continue;
        };
        total += n;
    }
    return total;
}

fn drainTenantCallbacks(
    worker: anytype,
    tc: *worker_mod.TenantFiles,
    inst: *const tenant_mod.Instance,
    max_per_tenant: u32,
) !usize {
    const allocator = worker.allocator;

    // Cheap peek first — no write txn if there's nothing to do.
    var scan = try inst.kv.prefix("_callback/", "", max_per_tenant);
    defer scan.deinit();
    if (scan.entries.len == 0) return 0;

    var txn = try inst.kv.beginTrackedImmediate();
    txn.open() catch |err| {
        if (err == kv_mod.KvError.Conflict) return 0; // another worker got here first
        return err;
    };
    // Track whether we've committed; on error path we must roll back.
    var committed = false;
    errdefer if (!committed) {
        txn.rollback() catch {};
    };

    var writeset = kv_mod.WriteSet.init(allocator);
    defer writeset.deinit();

    // Per-batch SSE emit accumulator (sse-plan §3.2). Callbacks can
    // call `events.emit` to fan a webhook response back to the user's
    // browser (the Stripe-style RPC-via-notifications recipe in
    // docs/notifications.md §2). Same lifecycle as worker_dispatch's
    // pending_emits: appended via DispatchState.emit_buffer, fired
    // fire-and-forget at sse-server after raft commits the writeset.
    var pending_emits: std.ArrayListUnmanaged(sse_dispatch.EmitEntry) = .empty;
    defer {
        for (pending_emits.items) |*e| e.deinit(allocator);
        pending_emits.deinit(allocator);
    }

    // http.send / http.cancel from inside an on_result callback —
    // sagas, retries, chained workflows. Same lifecycle as the
    // worker_dispatch accumulators.
    var pending_schedules: std.ArrayListUnmanaged(schedule_server_mod.ScheduleRow) = .empty;
    defer {
        for (pending_schedules.items) |*r| r.deinit(allocator);
        pending_schedules.deinit(allocator);
    }
    var pending_cancels: std.ArrayListUnmanaged(schedule_server_mod.CancelTarget) = .empty;
    defer {
        for (pending_cancels.items) |*t| t.deinit(allocator);
        pending_cancels.deinit(allocator);
    }

    var visited: usize = 0;
    for (scan.entries) |row| {
        visited += 1;
        _ = runOneCallback(worker, tc, inst, &txn, &writeset, &pending_emits, &pending_schedules, &pending_cancels, row.key, row.value) catch |err| {
            std.log.warn(
                "rove-js callbacks: {s}/{s}: {s} (kept for retry)",
                .{ inst.id, row.key, @errorName(err) },
            );
            // savepoint (if any) was already rolled back inside
            // runOneCallback. The outer tenant txn stays healthy.
            continue;
        };
    }

    const batch_seq = txn.txn_seq;
    const has_writes = writeset.ops.items.len > 0;
    const has_schedules = pending_schedules.items.len > 0;
    const has_cancels = pending_cancels.items.len > 0;
    const needs_propose = has_writes or has_schedules or has_cancels;
    if (!needs_propose) {
        // Every callback failed or was a no-op (no writes, no
        // http.send / http.cancel queued). Release the txn without
        // proposing.
        txn.rollback() catch {};
        committed = true;
        // Read-only batch: emits (if any) fire immediately — no raft
        // hop to wait for. Same posture as worker_dispatch.
        fireEmitsIfWired(worker, inst.id, &pending_emits);
        return visited;
    }

    try txn.commit();
    committed = true;

    // Empty webhooks slice — callbacks don't fire webhook.send (it's
    // a future-tightening; today the customer routes through
    // http.send directly). The proposeBatchAndWebhooks shape handles
    // any subset of writes + schedules + cancels in one envelope.
    _ = raft_propose.proposeBatchAndWebhooks(
        worker,
        &writeset,
        &.{},
        pending_schedules.items,
        pending_cancels.items,
        inst.id,
    ) catch |err| {
        // Local writes already committed; compensating rollback
        // via the undo log mirrors the HTTP dispatch fault path.
        inst.kv.undoTxn(batch_seq) catch |undo_err| {
            std.log.err(
                "rove-js callbacks: undoTxn after propose error failed: {s}",
                .{@errorName(undo_err)},
            );
        };
        return err;
    };

    // Raft accepted the batch on this node — fire emits at sse-server.
    fireEmitsIfWired(worker, inst.id, &pending_emits);

    return visited;
}

/// Fire-and-forget the merged callback-batch emits at sse-server.
/// No-op when worker isn't configured for SSE delivery or the batch
/// is empty. Mirrors worker_dispatch.fireEmitsIfWired.
fn fireEmitsIfWired(
    worker: anytype,
    tenant_id: []const u8,
    pending_emits: *std.ArrayListUnmanaged(sse_dispatch.EmitEntry),
) void {
    if (pending_emits.items.len == 0) return;
    const easy = worker.sse_curl orelse return;
    const base = worker.sse_public_base orelse return;
    const tok = worker.sse_internal_token orelse return;
    if (base.len == 0 or tok.len == 0) return;
    sse_dispatch.fireBatch(
        worker.allocator,
        easy,
        base,
        tok,
        tenant_id,
        // No batch-level request_id breadcrumb in the callback path
        // (callbacks are platform-driven, not tied to one request).
        // sse-server doesn't depend on this field; 0 is fine.
        0,
        pending_emits.items,
        worker.sse_insecure_tls,
    );
}

/// Outcome of `runOneCallback` from the caller's point of view. Used
/// only internally by tests — `drainTenantCallbacks` just cares about
/// whether writeset.ops grew.
pub const CallbackOutcome = enum {
    /// Receipt queued for delete + handler writes captured.
    delivered,
    /// Envelope was bad / handler missing; receipt queued for drop
    /// with a warning so it doesn't re-run forever.
    dropped,
    /// Handler ran but threw / timed out / hit a kv error. Receipt
    /// left in place for the next tick to retry.
    kept,
};

fn runOneCallback(
    worker: anytype,
    tc: *worker_mod.TenantFiles,
    inst: *const tenant_mod.Instance,
    txn: *kv_mod.KvStore.TrackedTxn,
    writeset: *kv_mod.WriteSet,
    pending_emits: *std.ArrayListUnmanaged(sse_dispatch.EmitEntry),
    pending_schedules: *std.ArrayListUnmanaged(schedule_server_mod.ScheduleRow),
    pending_cancels: *std.ArrayListUnmanaged(schedule_server_mod.CancelTarget),
    receipt_key: []const u8,
    envelope_bytes: []const u8,
) !CallbackOutcome {
    const allocator = worker.allocator;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, envelope_bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        std.log.warn(
            "rove-js callbacks: {s}/{s}: malformed envelope; dropping",
            .{ inst.id, receipt_key },
        );
        try dropReceipt(txn, writeset, receipt_key);
        return .dropped;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            std.log.warn(
                "rove-js callbacks: {s}/{s}: envelope not a JSON object; dropping",
                .{ inst.id, receipt_key },
            );
            try dropReceipt(txn, writeset, receipt_key);
            return .dropped;
        },
    };

    const on_result: []const u8 = switch (obj.get("on_result") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => {
            // No callback path on the envelope — apply-side bug; drop
            // rather than loop forever.
            std.log.warn(
                "rove-js callbacks: {s}/{s}: no on_result; dropping",
                .{ inst.id, receipt_key },
            );
            try dropReceipt(txn, writeset, receipt_key);
            return .dropped;
        },
    };

    const bytecode_opt = findCallbackBytecode(tc, on_result) catch |err| {
        std.log.warn(
            "rove-js callbacks: {s}/{s}: handler '{s}' resolve error: {s} (kept)",
            .{ inst.id, receipt_key, on_result, @errorName(err) },
        );
        return .kept;
    };
    const bytecode = bytecode_opt orelse {
        std.log.warn(
            "rove-js callbacks: {s}/{s}: handler '{s}' not in current deployment; dropping",
            .{ inst.id, receipt_key, on_result },
        );
        try dropReceipt(txn, writeset, receipt_key);
        return .dropped;
    };

    const body = try buildCallbackBody(allocator, parsed.value);
    defer allocator.free(body);

    try txn.savepoint();

    const request_id: u64 = blk: {
        const tl = worker.tenant_logs.get(inst.id) orelse break :blk 0;
        break :blk tl.id_minter.nextRequestId() catch 0;
    };

    var tapes = worker_mod.RequestTapes.init(allocator);
    defer tapes.deinit();

    const received_ns: i64 = @intCast(std.time.nanoTimestamp());

    // Build the synthesized path `/` + on_result so any code that
    // peeks at `request.path` sees a sane string.
    const synthetic_path = try std.fmt.allocPrint(allocator, "/{s}", .{on_result});
    defer allocator.free(synthetic_path);

    const request: Request = .{
        .method = "POST",
        .path = synthetic_path,
        .body = body,
        .query = null,
        .kv_tape = &tapes.kv,
        .date_tape = &tapes.date,
        .math_random_tape = &tapes.math_random,
        .crypto_random_tape = &tapes.crypto_random,
        .module_tape = &tapes.module,
        .prng_seed = @bitCast(received_ns),
        .request_id = request_id,
        .platform = inst.platform,
        // Callbacks are platform-driven (webhook-server fired the
        // webhook, success/failure routes back through this dispatch);
        // they share the customer's email bucket via the same limiter.
        .limiter = &worker.limiter,
        .instance_id = inst.id,
        .emit_buffer = pending_emits,
        .pending_schedules = pending_schedules,
        .pending_cancels = pending_cancels,
    };

    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = worker.dispatcher.run(
        inst.kv,
        txn,
        writeset,
        bytecode,
        &tc.bytecodes,
        &tc.source_hashes,
        tc.triggers,
        request,
        &budget,
    ) catch |err| {
        txn.rollbackTo() catch {};
        std.log.warn(
            "rove-js callbacks: {s}/{s} handler run failed: {s} (kept)",
            .{ inst.id, receipt_key, @errorName(err) },
        );
        return .kept;
    };
    defer resp.deinit(allocator);

    if (worker.dispatcher.last_kv_error != null) {
        worker.dispatcher.last_kv_error = null;
        txn.rollbackTo() catch {};
        std.log.warn(
            "rove-js callbacks: {s}/{s} handler hit kv error (kept)",
            .{ inst.id, receipt_key },
        );
        return .kept;
    }

    if (resp.exception.len > 0) {
        txn.rollbackTo() catch {};
        std.log.warn(
            "rove-js callbacks: {s}/{s} handler threw: {s} (kept)",
            .{ inst.id, receipt_key, resp.exception },
        );
        return .kept;
    }

    // Success: release the savepoint and queue the receipt delete.
    txn.release() catch |err| {
        std.log.warn(
            "rove-js callbacks: {s}/{s} release failed: {s} (kept)",
            .{ inst.id, receipt_key, @errorName(err) },
        );
        return .kept;
    };
    try txn.delete(receipt_key);
    try writeset.addDelete(receipt_key);
    return .delivered;
}

/// Direct lookup in the tenant's bytecode map. No walk-up — the
/// customer named the callback path explicitly, so "nearest ancestor
/// index" would silently run the wrong handler. Tries `.mjs` first
/// (the modern path), then `.js`.
fn findCallbackBytecode(
    tc: *const worker_mod.TenantFiles,
    on_result: []const u8,
) !?[]u8 {
    // Forbid absolute paths / parent-escape. The webhook-server
    // produces envelopes from what `webhook.send` accepted, but
    // defense in depth is cheap.
    if (on_result.len == 0) return null;
    if (on_result[0] == '/') return null;
    if (std.mem.indexOf(u8, on_result, "..") != null) return null;

    var buf: [256]u8 = undefined;
    const mjs = std.fmt.bufPrint(&buf, "{s}.mjs", .{on_result}) catch return null;
    if (tc.bytecodes.get(mjs)) |bc| return bc;
    const js = std.fmt.bufPrint(&buf, "{s}.js", .{on_result}) catch return null;
    if (tc.bytecodes.get(js)) |bc| return bc;
    return null;
}

/// Build the dispatcher's POST body — `{fn: "default", args: [event]}`
/// — from the parsed envelope. Keys in the outer envelope are
/// snake_case (as written by envelope-5 apply); the event object
/// exposed to JS uses camelCase, matching PLAN §2.6.
fn buildCallbackBody(
    allocator: std.mem.Allocator,
    envelope: std.json.Value,
) ![]u8 {
    const obj = switch (envelope) {
        .object => |o| o,
        else => return error.InvalidEnvelope,
    };

    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
    const w = &aw.writer;

    try w.writeAll("{\"fn\":\"default\",\"args\":[{");
    var first = true;
    for (FIELD_MAP) |fm| {
        const v = obj.get(fm.src) orelse continue;
        if (v == .null) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("\"");
        try w.writeAll(fm.dst);
        try w.writeAll("\":");
        try std.json.Stringify.value(v, .{}, w);
    }
    try w.writeAll("}]}");
    return aw.toOwnedSlice();
}

// Maps fields from either envelope flavor (legacy webhook
// envelope-5 or new schedule envelope-9) into the camelCase event
// the handler sees. A given receipt will only carry fields from one
// flavor; the other flavor's fields silently skip.
//
// Schedule envelope-9 fields (id, ok, status, version, body) ride
// through with the same name they have on the receipt — they're
// already snake-case-clean.
const FIELD_MAP = [_]struct { src: []const u8, dst: []const u8 }{
    // Legacy webhook envelope-5 only:
    .{ .src = "webhook_id", .dst = "webhookId" },
    .{ .src = "attempts", .dst = "attempts" },
    .{ .src = "response", .dst = "response" },
    // Schedule envelope-9 only:
    .{ .src = "id", .dst = "id" },
    .{ .src = "ok", .dst = "ok" },
    .{ .src = "status", .dst = "status" },
    .{ .src = "version", .dst = "version" },
    .{ .src = "body", .dst = "body" },
    // Both flavors:
    .{ .src = "outcome", .dst = "outcome" },
    .{ .src = "context", .dst = "context" },
    .{ .src = "error", .dst = "error" },
};

/// Queue a receipt delete in both local txn + raft writeset.
fn dropReceipt(
    txn: *kv_mod.KvStore.TrackedTxn,
    writeset: *kv_mod.WriteSet,
    receipt_key: []const u8,
) !void {
    try txn.delete(receipt_key);
    try writeset.addDelete(receipt_key);
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "buildCallbackBody: delivered envelope → camelCase event" {
    const envelope_bytes =
        \\{
        \\  "webhook_id": "abc123",
        \\  "on_result": "stripe/charge_result",
        \\  "outcome": "delivered",
        \\  "attempts": 2,
        \\  "context": {"chargeId": "c_1"},
        \\  "response": {"status": 200, "body": "ok", "truncated": false}
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, envelope_bytes, .{});
    defer parsed.deinit();

    const body = try buildCallbackBody(testing.allocator, parsed.value);
    defer testing.allocator.free(body);

    // Re-parse to check structure without depending on key order.
    var out = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer out.deinit();
    try testing.expectEqualStrings("default", out.value.object.get("fn").?.string);
    const args = out.value.object.get("args").?.array;
    try testing.expectEqual(@as(usize, 1), args.items.len);
    const event = args.items[0].object;
    try testing.expectEqualStrings("abc123", event.get("webhookId").?.string);
    try testing.expectEqualStrings("delivered", event.get("outcome").?.string);
    try testing.expectEqual(@as(i64, 2), event.get("attempts").?.integer);
    try testing.expectEqualStrings("c_1", event.get("context").?.object.get("chargeId").?.string);
    try testing.expectEqual(@as(i64, 200), event.get("response").?.object.get("status").?.integer);
    try testing.expect(event.get("on_result") == null); // stays on server side
}

test "buildCallbackBody: failed envelope → error field passthrough" {
    const envelope_bytes =
        \\{
        \\  "webhook_id": "xyz",
        \\  "on_result": "my/handler",
        \\  "outcome": "failed",
        \\  "attempts": 10,
        \\  "context": null,
        \\  "error": "Timeout"
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, envelope_bytes, .{});
    defer parsed.deinit();

    const body = try buildCallbackBody(testing.allocator, parsed.value);
    defer testing.allocator.free(body);

    var out = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer out.deinit();
    const event = out.value.object.get("args").?.array.items[0].object;
    try testing.expectEqualStrings("failed", event.get("outcome").?.string);
    try testing.expectEqualStrings("Timeout", event.get("error").?.string);
    try testing.expect(event.get("response") == null);
    // Null `context` from the envelope should be dropped so the JS
    // side sees `event.context === undefined`, not `null`. (Either
    // is acceptable; dropping keeps the event payload small.)
    try testing.expect(event.get("context") == null);
}

test "buildCallbackBody: schedule envelope-9 → camelCase event with id/ok/status/version/body" {
    const envelope_bytes =
        \\{
        \\  "id": "sched-abc",
        \\  "on_result": "stripe_done",
        \\  "ok": true,
        \\  "status": 200,
        \\  "version": 3,
        \\  "context": {"orderId": "o-42"},
        \\  "body": "{\"forwarded\":true}",
        \\  "error": null
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, envelope_bytes, .{});
    defer parsed.deinit();

    const body = try buildCallbackBody(testing.allocator, parsed.value);
    defer testing.allocator.free(body);

    var out = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer out.deinit();
    const event = out.value.object.get("args").?.array.items[0].object;
    try testing.expectEqualStrings("sched-abc", event.get("id").?.string);
    try testing.expectEqual(true, event.get("ok").?.bool);
    try testing.expectEqual(@as(i64, 200), event.get("status").?.integer);
    try testing.expectEqual(@as(i64, 3), event.get("version").?.integer);
    try testing.expectEqualStrings("{\"forwarded\":true}", event.get("body").?.string);
    try testing.expectEqualStrings("o-42", event.get("context").?.object.get("orderId").?.string);
    // No webhook fields leaked through.
    try testing.expect(event.get("webhookId") == null);
    try testing.expect(event.get("attempts") == null);
    try testing.expect(event.get("response") == null);
    try testing.expect(event.get("on_result") == null); // server-side only
    try testing.expect(event.get("error") == null); // null in envelope → dropped
}

test "findCallbackBytecode: exact .mjs match wins over .js" {
    var tc: worker_mod.TenantFiles = .{
        .allocator = testing.allocator,
        .instance_id = @constCast(""),
        .app_kv = undefined,
        .blob_backend = undefined,
        .manifest_backend = undefined,
        .current_deployment_id = 1,
        .bytecodes = .empty,
        .source_hashes = .empty,
        .statics = .empty,
        .triggers = &.{},
    };
    defer tc.bytecodes.deinit(testing.allocator);

    try tc.bytecodes.put(testing.allocator, "stripe/charge_result.mjs", @constCast("MJS"));
    try tc.bytecodes.put(testing.allocator, "stripe/charge_result.js", @constCast("JS"));

    const bc = (try findCallbackBytecode(&tc, "stripe/charge_result")).?;
    try testing.expectEqualStrings("MJS", bc);
}

test "findCallbackBytecode: falls back to .js when no .mjs" {
    var tc: worker_mod.TenantFiles = .{
        .allocator = testing.allocator,
        .instance_id = @constCast(""),
        .app_kv = undefined,
        .blob_backend = undefined,
        .manifest_backend = undefined,
        .current_deployment_id = 1,
        .bytecodes = .empty,
        .source_hashes = .empty,
        .statics = .empty,
        .triggers = &.{},
    };
    defer tc.bytecodes.deinit(testing.allocator);

    try tc.bytecodes.put(testing.allocator, "my/cb.js", @constCast("JS"));

    const bc = (try findCallbackBytecode(&tc, "my/cb")).?;
    try testing.expectEqualStrings("JS", bc);
}

test "findCallbackBytecode: rejects absolute + parent-escape paths" {
    var tc: worker_mod.TenantFiles = .{
        .allocator = testing.allocator,
        .instance_id = @constCast(""),
        .app_kv = undefined,
        .blob_backend = undefined,
        .manifest_backend = undefined,
        .current_deployment_id = 1,
        .bytecodes = .empty,
        .source_hashes = .empty,
        .statics = .empty,
        .triggers = &.{},
    };
    defer tc.bytecodes.deinit(testing.allocator);

    try tc.bytecodes.put(testing.allocator, "/absolute.mjs", @constCast("MJS"));
    try tc.bytecodes.put(testing.allocator, "../escape.mjs", @constCast("MJS"));

    try testing.expect((try findCallbackBytecode(&tc, "/absolute")) == null);
    try testing.expect((try findCallbackBytecode(&tc, "../escape")) == null);
    try testing.expect((try findCallbackBytecode(&tc, "")) == null);
}

test "findCallbackBytecode: miss returns null" {
    var tc: worker_mod.TenantFiles = .{
        .allocator = testing.allocator,
        .instance_id = @constCast(""),
        .app_kv = undefined,
        .blob_backend = undefined,
        .manifest_backend = undefined,
        .current_deployment_id = 1,
        .bytecodes = .empty,
        .source_hashes = .empty,
        .statics = .empty,
        .triggers = &.{},
    };
    defer tc.bytecodes.deinit(testing.allocator);

    try testing.expect((try findCallbackBytecode(&tc, "never/here")) == null);
}
