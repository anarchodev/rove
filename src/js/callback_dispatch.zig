//! Callback dispatch — invokes the tenant's `on_result` handler
//! after the schedule-server finishes an http.send attempt
//! (delivered or terminally failed).
//!
//! Envelope-9 apply stashes the delivered callback event in the
//! cluster-wide schedule store at `c/{tenant_id}/{id}` (alongside the
//! schedule rows at `s/{tenant_id}/{id}`). This phase, driven from
//! the worker poll loop on the raft leader, scans the `c/` prefix
//! ONCE per tick, groups the rows by tenant, and invokes the
//! customer's `on_result` handler with the event JSON in
//! `request.body`. Each tenant's successful invocations + the
//! companion `c/` row delete (via envelope-10 cancel) commit
//! atomically in one tenant txn + one multi-envelope propose.
//!
//! The legacy `_callback/{id}` rows in the tenant's own app.db
//! retired with #52 — at 1k+ tenants the per-tick fan-out SELECT
//! across every tenant's app.db took longer than the dispatch
//! tick budget. The centralized `c/` prefix is one prefix scan
//! regardless of tenant count.
//!
//! ## Contract with the handler
//!
//! The callback handler is an ES module — same shape as any other
//! HTTP handler in the tenant. The event JSON arrives in
//! `request.body`:
//!
//! ```js
//! // stripe_done.mjs
//! export default function () {
//!   const event = JSON.parse(request.body);
//!   // event.id       - schedule id returned from http.send
//!   // event.ok       - bool
//!   // event.status   - HTTP status code
//!   // event.body     - response body string
//!   // event.context  - whatever was passed to http.send
//!   // event.error    - error string ("" / null on success)
//!   if (event.ok) {
//!     kv.set(`charges/${event.context.charge_id}`, event.body);
//!   }
//! }
//! ```
//!
//! When the schedule was queued with `on_result.fn` set, the
//! synthesized callback request also carries `?fn={fn}&args={...}`
//! so a named export is invoked with positional args; event JSON
//! still arrives via `request.body`.
//!
//! The handler may call `kv.*` / `http.send` / `events.emit` —
//! its writes go into the same tenant batch txn as the receipt
//! delete and replicate through raft together. If the handler
//! throws or hits its budget, the savepoint rolls back and the
//! receipt is KEPT for retry, so a fixed redeploy picks up the
//! backlog automatically. If the envelope is malformed or the
//! handler path is unknown, the receipt is DROPPED with a warning
//! (otherwise it'd accumulate forever).
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

const dispatcher_mod = @import("dispatcher.zig");
const worker_mod = @import("worker.zig");
const sse_dispatch = @import("sse_dispatch.zig");
const raft_propose = @import("raft_propose.zig");
const tenant_batch = @import("tenant_batch.zig");

const Request = dispatcher_mod.Request;
const Budget = dispatcher_mod.Budget;

/// Per-pass cap on rows fetched from the shared `c/` prefix. Bounds
/// the dispatch tick's wall time at high callback volumes; the
/// remainder catches up on subsequent ticks.
pub const DEFAULT_MAX_PER_TENANT: u32 = 32;

/// Process up to `max_per_tenant * N_tenants_with_pending` rows from
/// `schedules.db c/` in one pass. Returns the total number of rows
/// visited (delivered + kept-for-retry). Caller passes the per-node
/// `ScheduleStore` (same handle `dispatchInternalSchedules` uses);
/// the dispatch tick is gated to worker 0 on the leader by the
/// caller.
pub fn dispatchCallbacks(
    worker: anytype,
    schedules_store: *schedule_server_mod.ScheduleStore,
    max_per_tenant: u32,
) !usize {
    if (!worker.raft.isLeader()) return 0;

    const allocator = worker.allocator;

    // Cluster-wide single scan of the callback prefix. Replaces the
    // previous per-tenant fan-out (one SELECT per tenant per tick).
    // Cap is intentionally generous — at 32 rows × 1k pending tenants
    // we'd visit 32k rows / tick, but realistic platforms see far
    // fewer pending callbacks at any instant.
    const CAP: usize = 4096;
    var rows = schedules_store.dueCallbackRows(allocator, CAP) catch |err| {
        std.log.warn("rove-js callbacks: dueCallbackRows: {s}", .{@errorName(err)});
        return 0;
    };
    defer {
        for (rows) |*r| r.deinit(allocator);
        allocator.free(rows);
    }
    if (rows.len == 0) return 0;

    // Group rows by tenant. Sort by tenant_id so contiguous slices
    // per tenant fall out of one pass.
    std.sort.pdq(@TypeOf(rows[0]), rows, {}, struct {
        fn lt(_: void, a: @TypeOf(rows[0]), b: @TypeOf(rows[0])) bool {
            return std.mem.lessThan(u8, a.tenant_id, b.tenant_id);
        }
    }.lt);

    var total: usize = 0;
    var start: usize = 0;
    while (start < rows.len) {
        var end = start + 1;
        while (end < rows.len and std.mem.eql(u8, rows[end].tenant_id, rows[start].tenant_id)) : (end += 1) {}
        defer start = end;

        const tenant_id = rows[start].tenant_id;
        const slice = rows[start..end];

        const slot = worker.node.tenant_files_map.get(tenant_id) orelse {
            // Tenant was deleted between schedule-fire and now; drop
            // the callback rows so they don't accumulate forever.
            for (slice) |r| {
                schedules_store.applyCancel(r.tenant_id, r.id) catch |err| {
                    std.log.warn(
                        "rove-js callbacks: orphan-cleanup {s}/{s}: {s}",
                        .{ r.tenant_id, r.id, @errorName(err) },
                    );
                };
            }
            continue;
        };
        const snap = slot.pinCurrent() orelse {
            // Tenant has no current deployment; the handler isn't
            // available. Drop rather than retry forever.
            for (slice) |r| {
                schedules_store.applyCancel(r.tenant_id, r.id) catch {};
            }
            continue;
        };
        const tc = worker_mod.TenantFiles{ .slot = slot, .snap = snap };
        defer tc.release();
        const inst_opt = worker.node.tenant.getInstance(tenant_id) catch |err| {
            std.log.warn("rove-js callbacks: getInstance({s}): {s}", .{ tenant_id, @errorName(err) });
            continue;
        };
        const inst = inst_opt orelse continue;

        const n = drainTenantCallbacks(worker, tc, inst, slice, @intCast(@min(slice.len, max_per_tenant))) catch |err| {
            std.log.warn("rove-js callbacks: tenant {s}: {s}", .{ inst.id, @errorName(err) });
            continue;
        };
        total += n;
    }
    return total;
}

/// Callback-path policy for `tenant_batch.drainTenantBatch`: bind the
/// shared per-tenant batch skeleton to the callback row shape, the
/// proposeBatch tail, and the writeset/schedules/cancels "needs
/// propose" predicate. Stateless.
const CallbackPolicy = struct {
    pub fn runOne(
        _: *CallbackPolicy,
        worker: anytype,
        tc: anytype,
        inst: *const tenant_mod.Instance,
        txn: anytype,
        ws: anytype,
        pe: anytype,
        ps: anytype,
        pc: anytype,
        row: schedule_server_mod.ScheduleStore.CallbackRow,
    ) !void {
        // savepoint (if any) is rolled back inside runOneCallback on
        // failure; the outer tenant txn stays healthy. The skeleton
        // logs + keeps-for-retry on the propagated error.
        _ = try runOneCallback(worker, tc, inst, txn, ws, pe, ps, pc, row.id, row.payload);
    }

    pub fn needsPropose(_: *CallbackPolicy, ws: anytype, ps: anytype, pc: anytype) bool {
        return ws.ops.items.len > 0 or ps.items.len > 0 or pc.items.len > 0;
    }

    pub fn propose(
        _: *CallbackPolicy,
        worker: anytype,
        inst: *const tenant_mod.Instance,
        ws: anytype,
        ps: anytype,
        pc: anytype,
    ) !void {
        // proposeBatch wraps writes + schedules + cancels into one
        // multi-envelope (or proposes bare when only one bucket has
        // content). undoTxn-on-failure lives in the skeleton.
        _ = try raft_propose.proposeBatch(worker, ws, ps.items, pc.items, inst.id);
    }
};

/// Per-tenant callback drain. The txn / accumulator / read-only-fast-
/// path / commit-propose-undo / emit-fire discipline now lives in
/// `tenant_batch.drainTenantBatch`; this binds it to the callback
/// row + proposeBatch tail. Behavior is unchanged from the
/// pre-extraction inline version.
fn drainTenantCallbacks(
    worker: anytype,
    tc: worker_mod.TenantFiles,
    inst: *const tenant_mod.Instance,
    rows: []schedule_server_mod.ScheduleStore.CallbackRow,
    max_per_tenant: u32,
) !usize {
    var pol = CallbackPolicy{};
    return tenant_batch.drainTenantBatch(worker, tc, inst, rows, max_per_tenant, &pol);
}

// (fireEmitsIfWired removed — emit-firing now lives in
//  tenant_batch.zig, shared across the batched-dispatch paths.)

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
    tc: worker_mod.TenantFiles,
    inst: *const tenant_mod.Instance,
    txn: *kv_mod.KvStore.TrackedTxn,
    writeset: *kv_mod.WriteSet,
    pending_emits: *std.ArrayListUnmanaged(sse_dispatch.EmitEntry),
    pending_schedules: *std.ArrayListUnmanaged(schedule_server_mod.ScheduleRow),
    pending_cancels: *std.ArrayListUnmanaged(schedule_server_mod.CancelTarget),
    callback_id: []const u8,
    envelope_bytes: []const u8,
) !CallbackOutcome {
    const allocator = worker.allocator;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, envelope_bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        std.log.warn(
            "rove-js callbacks: {s}/{s}: malformed envelope; dropping",
            .{ inst.id, callback_id },
        );
        try queueCancelDrop(allocator, pending_cancels, inst.id, callback_id);
        return .dropped;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            std.log.warn(
                "rove-js callbacks: {s}/{s}: envelope not a JSON object; dropping",
                .{ inst.id, callback_id },
            );
            try queueCancelDrop(allocator, pending_cancels, inst.id, callback_id);
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
                .{ inst.id, callback_id },
            );
            try queueCancelDrop(allocator, pending_cancels, inst.id, callback_id);
            return .dropped;
        },
    };

    const bytecode_opt = findCallbackBytecode(tc, on_result) catch |err| {
        std.log.warn(
            "rove-js callbacks: {s}/{s}: handler '{s}' resolve error: {s} (kept)",
            .{ inst.id, callback_id, on_result, @errorName(err) },
        );
        return .kept;
    };
    const bytecode = bytecode_opt orelse {
        std.log.warn(
            "rove-js callbacks: {s}/{s}: handler '{s}' not in current deployment; dropping",
            .{ inst.id, callback_id, on_result },
        );
        try queueCancelDrop(allocator, pending_cancels, inst.id, callback_id);
        return .dropped;
    };

    const body = try buildCallbackEvent(allocator, parsed.value);
    defer allocator.free(body);

    // Optional named-export dispatch. When the receipt carries
    // `on_result_fn`, we synthesize a `?fn={fn}&args={...}` query
    // so parseDispatch routes to the named export with positional
    // args. Empty `on_result_fn` falls through to today's default-
    // export-with-no-args behavior.
    const synthetic_query = try buildSyntheticQuery(allocator, obj);
    defer if (synthetic_query) |q| allocator.free(q);

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
        .query = synthetic_query,
        .kv_tape = &tapes.kv,
        .date_tape = &tapes.date,
        .math_random_tape = &tapes.math_random,
        .crypto_random_tape = &tapes.crypto_random,
        .module_tape = &tapes.module,
        .prng_seed = @bitCast(received_ns),
        .request_id = request_id,
        .platform = inst.platform,
        // Callbacks are platform-driven (schedule-server fired the
        // http.send, success/failure routes back through this dispatch);
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
        &tc.snap.bytecodes,
        &tc.snap.source_hashes,
        tc.snap.triggers,
        request,
        &budget,
    ) catch |err| {
        txn.rollbackTo() catch {};
        std.log.warn(
            "rove-js callbacks: {s}/{s} handler run failed: {s} (kept)",
            .{ inst.id, callback_id, @errorName(err) },
        );
        return .kept;
    };
    defer resp.deinit(allocator);

    // on_result outcome — the callback path otherwise logs only
    // failures, which hides "ran fine but the handler reports a
    // problem in its body" (e.g. an RP completion that rejects an
    // id_token). One info line per invocation; cheap, and the
    // breadcrumb the next investigator needs.
    std.log.info(
        "rove-js callbacks: {s}/{s} module={s} status={d} body={s}",
        .{
            inst.id,
            callback_id,
            on_result,
            resp.status,
            resp.body[0..@min(resp.body.len, 160)],
        },
    );

    if (worker.dispatcher.last_kv_error != null) {
        worker.dispatcher.last_kv_error = null;
        txn.rollbackTo() catch {};
        std.log.warn(
            "rove-js callbacks: {s}/{s} handler hit kv error (kept)",
            .{ inst.id, callback_id },
        );
        return .kept;
    }

    if (resp.exception.len > 0) {
        txn.rollbackTo() catch {};
        std.log.warn(
            "rove-js callbacks: {s}/{s} handler threw: {s} (kept)",
            .{ inst.id, callback_id, resp.exception },
        );
        return .kept;
    }

    // Success: release the savepoint and queue an envelope-10 cancel
    // for the `c/{tenant}/{id}` row in schedules.db. The handler's
    // writeset commits below; the cancel rides alongside in the
    // multi-envelope propose.
    txn.release() catch |err| {
        std.log.warn(
            "rove-js callbacks: {s}/{s} release failed: {s} (kept)",
            .{ inst.id, callback_id, @errorName(err) },
        );
        return .kept;
    };
    try queueCancelDrop(allocator, pending_cancels, inst.id, callback_id);
    return .delivered;
}

/// Append an envelope-10 cancel target for `(tenant_id, callback_id)`.
/// The applyCancel path deletes both `s/{tenant}/{id}` (no-op when
/// the schedule already fired) and `c/{tenant}/{id}` (the cleanup
/// we want here). Uses the pending_cancels accumulator's allocator;
/// the deferred deinit at drainTenantCallbacks level owns the dupes.
fn queueCancelDrop(
    allocator: std.mem.Allocator,
    pending_cancels: *std.ArrayListUnmanaged(schedule_server_mod.CancelTarget),
    tenant_id: []const u8,
    callback_id: []const u8,
) !void {
    const t_copy = try allocator.dupe(u8, tenant_id);
    errdefer allocator.free(t_copy);
    const i_copy = try allocator.dupe(u8, callback_id);
    errdefer allocator.free(i_copy);
    try pending_cancels.append(allocator, .{ .tenant_id = t_copy, .id = i_copy });
}

/// Direct lookup in the tenant's bytecode map. No walk-up — the
/// customer named the callback path explicitly, so "nearest ancestor
/// index" would silently run the wrong handler. Tries `.mjs` first
/// (the modern path), then `.js`.
fn findCallbackBytecode(
    tc: worker_mod.TenantFiles,
    on_result: []const u8,
) !?[]u8 {
    // Forbid absolute paths / parent-escape. The http.send binding
    // already validates `on_result.module`, but defense in depth
    // is cheap.
    if (on_result.len == 0) return null;
    if (on_result[0] == '/') return null;
    if (std.mem.indexOf(u8, on_result, "..") != null) return null;

    var buf: [256]u8 = undefined;
    const mjs = std.fmt.bufPrint(&buf, "{s}.mjs", .{on_result}) catch return null;
    if (tc.snap.bytecodes.get(mjs)) |bc| return bc;
    const js = std.fmt.bufPrint(&buf, "{s}.js", .{on_result}) catch return null;
    if (tc.snap.bytecodes.get(js)) |bc| return bc;
    return null;
}

/// Build the dispatcher's POST body — `{fn: "default", args: [event]}`
/// — from the parsed envelope. Keys in the outer envelope are
/// snake_case (as written by envelope-5/9 apply); the event object
/// the handler sees uses camelCase, matching PLAN §2.6.
///
/// The returned bytes are the request body — a JSON object whose
/// fields are the camelCased translations of the envelope. The
/// dispatcher's `parseDispatch` (no `fn` key in the JSON object)
/// falls through to the query-string path, picks the default export,
/// invokes it with no JS args. The customer's handler reads the
/// event via the global `request.body`:
///
/// ```js
/// export default function () {
///   const event = JSON.parse(request.body);
///   // ...
/// }
/// ```
///
/// Same shape as a regular HTTP handler — no special on_result
/// signature.
fn buildCallbackEvent(
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

    try w.writeAll("{");
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
    try w.writeAll("}");
    return aw.toOwnedSlice();
}

/// Build a synthesized query string for the callback request when
/// the receipt carries `on_result_fn`. Returns null when the
/// receipt has no fn (use the default-export-with-no-args path).
/// Format: `fn={name}` or `fn={name}&args={url-encoded-json}`.
/// Returned slice is allocator-owned.
fn buildSyntheticQuery(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
) !?[]const u8 {
    const fn_v = obj.get("on_result_fn") orelse return null;
    const fn_name = switch (fn_v) {
        .string => |s| s,
        else => return null,
    };
    if (fn_name.len == 0) return null;

    const args_v = obj.get("on_result_args");
    if (args_v == null or args_v.? == .null) {
        // Just `?fn={name}` — handler called with no JS args.
        return try std.fmt.allocPrint(allocator, "fn={s}", .{fn_name});
    }
    // Re-stringify the args array (it's already JSON in the
    // receipt, but obj.get returns the parsed Value; serialize
    // back to text). Then URL-encode minimally — `args=` is what
    // `parseDispatch` expects to decode via decodePercent.
    var args_text: std.ArrayList(u8) = .empty;
    defer args_text.deinit(allocator);
    {
        // Inner scope so the writer's internal buffer is synced
        // back into `args_text` BEFORE we read `args_text.items`.
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &args_text);
        defer args_text = aw.toArrayList();
        try std.json.Stringify.value(args_v.?, .{}, &aw.writer);
    }
    const encoded = try urlEncode(allocator, args_text.items);
    defer allocator.free(encoded);
    return try std.fmt.allocPrint(allocator, "fn={s}&args={s}", .{ fn_name, encoded });
}

/// Minimal URL encoder for the args JSON. Escapes everything that
/// isn't unreserved per RFC 3986. Allocator-owned return.
fn urlEncode(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (src) |b| {
        const unreserved = (b >= 'A' and b <= 'Z') or
            (b >= 'a' and b <= 'z') or
            (b >= '0' and b <= '9') or
            b == '-' or b == '_' or b == '.' or b == '~';
        if (unreserved) {
            try out.append(allocator, b);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[b >> 4]);
            try out.append(allocator, hex[b & 0x0f]);
        }
    }
    return out.toOwnedSlice(allocator);
}

// Maps schedule envelope-9 receipt fields into the event the
// handler sees. Schedule fields are already snake-case-clean, so
// the source and destination names match. The `outcome` field
// isn't in envelope-9 (replaced by `ok` bool) but stays in the
// map — apply could add it back without a callback-dispatch
// change, and dropping unknown fields is cheap.
const FIELD_MAP = [_]struct { src: []const u8, dst: []const u8 }{
    .{ .src = "id", .dst = "id" },
    .{ .src = "ok", .dst = "ok" },
    .{ .src = "status", .dst = "status" },
    .{ .src = "version", .dst = "version" },
    .{ .src = "body", .dst = "body" },
    .{ .src = "context", .dst = "context" },
    .{ .src = "error", .dst = "error" },
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "buildCallbackEvent: failed envelope → error field passthrough" {
    const envelope_bytes =
        \\{
        \\  "id": "x",
        \\  "on_result": "my/handler",
        \\  "ok": false,
        \\  "status": 0,
        \\  "version": 1,
        \\  "body": "",
        \\  "context": null,
        \\  "error": "Timeout"
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, envelope_bytes, .{});
    defer parsed.deinit();

    const body = try buildCallbackEvent(testing.allocator, parsed.value);
    defer testing.allocator.free(body);

    var event = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer event.deinit();
    const obj = event.value.object;
    try testing.expect(!obj.get("ok").?.bool);
    try testing.expectEqualStrings("Timeout", obj.get("error").?.string);
    // Null `context` from the envelope is dropped so the handler sees
    // `event.context === undefined`, not `null`.
    try testing.expect(obj.get("context") == null);
    // on_result is server-side; never leaked into the event.
    try testing.expect(obj.get("on_result") == null);
}

test "buildCallbackEvent: schedule envelope-9 → camelCase event with id/ok/status/version/body" {
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

    const body = try buildCallbackEvent(testing.allocator, parsed.value);
    defer testing.allocator.free(body);

    var event = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer event.deinit();
    const obj = event.value.object;
    try testing.expectEqualStrings("sched-abc", obj.get("id").?.string);
    try testing.expectEqual(true, obj.get("ok").?.bool);
    try testing.expectEqual(@as(i64, 200), obj.get("status").?.integer);
    try testing.expectEqual(@as(i64, 3), obj.get("version").?.integer);
    try testing.expectEqualStrings("{\"forwarded\":true}", obj.get("body").?.string);
    try testing.expectEqualStrings("o-42", obj.get("context").?.object.get("orderId").?.string);
    // No webhook fields leaked through.
    try testing.expect(obj.get("webhookId") == null);
    try testing.expect(obj.get("attempts") == null);
    try testing.expect(obj.get("response") == null);
    try testing.expect(obj.get("on_result") == null); // server-side only
    try testing.expect(obj.get("error") == null); // null in envelope → dropped
}

test "buildSyntheticQuery: receipt without on_result_fn returns null" {
    const a = testing.allocator;
    const receipt =
        \\{ "id": "x", "on_result": "stripe_done", "ok": true }
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, receipt, .{});
    defer parsed.deinit();
    const q = try buildSyntheticQuery(a, parsed.value.object);
    try testing.expect(q == null);
}

test "buildSyntheticQuery: receipt with on_result_fn (no args) emits ?fn=" {
    const a = testing.allocator;
    const receipt =
        \\{ "id": "x", "on_result": "stripe", "on_result_fn": "handleCharge", "ok": true }
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, receipt, .{});
    defer parsed.deinit();
    const q = (try buildSyntheticQuery(a, parsed.value.object)).?;
    defer a.free(q);
    try testing.expectEqualStrings("fn=handleCharge", q);
}

test "buildSyntheticQuery: receipt with on_result_fn + on_result_args emits ?fn=&args=" {
    const a = testing.allocator;
    const receipt =
        \\{ "id": "x", "on_result": "stripe", "on_result_fn": "handleCharge",
        \\  "on_result_args": [42, "subscription"], "ok": true }
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, receipt, .{});
    defer parsed.deinit();
    const q = (try buildSyntheticQuery(a, parsed.value.object)).?;
    defer a.free(q);
    // args are url-encoded JSON: [42,"subscription"] →
    // %5B42%2C%22subscription%22%5D
    try testing.expectEqualStrings("fn=handleCharge&args=%5B42%2C%22subscription%22%5D", q);
}

// Phase 2 test fixture: build a `TenantFiles` view from a stack
// `TenantSlot` + `TenantFilesSnapshot`. The refcount stays at 1 (no
// retain/release in tests since we don't atomic-swap or pin); the
// caller frees the maps it added directly.
fn testTenantFilesView(
    slot: *worker_mod.TenantSlot,
    snap: *worker_mod.TenantFilesSnapshot,
) worker_mod.TenantFiles {
    return .{ .slot = slot, .snap = snap };
}

test "findCallbackBytecode: exact .mjs match wins over .js" {
    var slot: worker_mod.TenantSlot = .{
        .allocator = testing.allocator,
        .instance_id = @constCast(""),
        .app_kv = undefined,
        .blob_backend = undefined,
        .manifest_backend = undefined,
        .prefetched_manifest = null,
        .current = .{ .raw = null },
    };
    var snap: worker_mod.TenantFilesSnapshot = .{
        .allocator = testing.allocator,
        .deployment_id = 1,
        .bytecodes = .empty,
        .source_hashes = .empty,
        .statics = .empty,
        .triggers = &.{},
        .manifest_bytes = &.{},
        .refcount = .{ .raw = 1 },
    };
    defer snap.bytecodes.deinit(testing.allocator);

    try snap.bytecodes.put(testing.allocator, "stripe/charge_result.mjs", @constCast("MJS"));
    try snap.bytecodes.put(testing.allocator, "stripe/charge_result.js", @constCast("JS"));

    const tc = testTenantFilesView(&slot, &snap);
    const bc = (try findCallbackBytecode(tc, "stripe/charge_result")).?;
    try testing.expectEqualStrings("MJS", bc);
}

test "findCallbackBytecode: falls back to .js when no .mjs" {
    var slot: worker_mod.TenantSlot = .{
        .allocator = testing.allocator,
        .instance_id = @constCast(""),
        .app_kv = undefined,
        .blob_backend = undefined,
        .manifest_backend = undefined,
        .prefetched_manifest = null,
        .current = .{ .raw = null },
    };
    var snap: worker_mod.TenantFilesSnapshot = .{
        .allocator = testing.allocator,
        .deployment_id = 1,
        .bytecodes = .empty,
        .source_hashes = .empty,
        .statics = .empty,
        .triggers = &.{},
        .manifest_bytes = &.{},
        .refcount = .{ .raw = 1 },
    };
    defer snap.bytecodes.deinit(testing.allocator);

    try snap.bytecodes.put(testing.allocator, "my/cb.js", @constCast("JS"));

    const tc = testTenantFilesView(&slot, &snap);
    const bc = (try findCallbackBytecode(tc, "my/cb")).?;
    try testing.expectEqualStrings("JS", bc);
}

test "findCallbackBytecode: rejects absolute + parent-escape paths" {
    var slot: worker_mod.TenantSlot = .{
        .allocator = testing.allocator,
        .instance_id = @constCast(""),
        .app_kv = undefined,
        .blob_backend = undefined,
        .manifest_backend = undefined,
        .prefetched_manifest = null,
        .current = .{ .raw = null },
    };
    var snap: worker_mod.TenantFilesSnapshot = .{
        .allocator = testing.allocator,
        .deployment_id = 1,
        .bytecodes = .empty,
        .source_hashes = .empty,
        .statics = .empty,
        .triggers = &.{},
        .manifest_bytes = &.{},
        .refcount = .{ .raw = 1 },
    };
    defer snap.bytecodes.deinit(testing.allocator);

    try snap.bytecodes.put(testing.allocator, "/absolute.mjs", @constCast("MJS"));
    try snap.bytecodes.put(testing.allocator, "../escape.mjs", @constCast("MJS"));

    const tc = testTenantFilesView(&slot, &snap);
    try testing.expect((try findCallbackBytecode(tc, "/absolute")) == null);
    try testing.expect((try findCallbackBytecode(tc, "../escape")) == null);
    try testing.expect((try findCallbackBytecode(tc, "")) == null);
}

test "findCallbackBytecode: miss returns null" {
    var slot: worker_mod.TenantSlot = .{
        .allocator = testing.allocator,
        .instance_id = @constCast(""),
        .app_kv = undefined,
        .blob_backend = undefined,
        .manifest_backend = undefined,
        .prefetched_manifest = null,
        .current = .{ .raw = null },
    };
    var snap: worker_mod.TenantFilesSnapshot = .{
        .allocator = testing.allocator,
        .deployment_id = 1,
        .bytecodes = .empty,
        .source_hashes = .empty,
        .statics = .empty,
        .triggers = &.{},
        .manifest_bytes = &.{},
        .refcount = .{ .raw = 1 },
    };
    defer snap.bytecodes.deinit(testing.allocator);

    const tc = testTenantFilesView(&slot, &snap);
    try testing.expect((try findCallbackBytecode(tc, "never/here")) == null);
}
