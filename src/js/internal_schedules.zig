//! In-process dispatch of internal-pool schedules (http-send-plan §3.2).
//!
//! The optimization that makes `webhook.loop46.com` (and any other
//! customer call to `{id}.{public_suffix}`) cheap. Instead of going
//! out via libcurl + cluster ingress + h2 + worker-side dispatch on
//! the target node, we synthesize a `Request` from the schedule row
//! and run `worker.dispatcher.run` directly against the target
//! tenant's bytecode + kv.
//!
//! ## Two-pool contract
//!
//! Apply-time stamping (in `applyScheduleUpsertBatch`) routes rows
//! whose URL parses as `{id}.{public_suffix}` AND `{id}` exists in
//! `__root__.db` into the internal pool — `is_internal=true`. This
//! phase drains that pool. Failed dispatch (target tenant not hosted
//! on this node, or no handler at the URL's path) explicitly demotes
//! the row to the external pool via envelope-11; the libcurl
//! scheduler thread fires it via cluster ingress instead. No
//! timeouts, no implicit fallback — the demote is the only path
//! from internal to external.
//!
//! ## Leader + worker gating
//!
//! Same pattern as `dispatchCallbacks`: leader-only + worker 0 only,
//! enforced by the caller in `loop46/main.zig`. The internal pool
//! has the same single-leader semantics as the external pool — only
//! the leader's worker 0 makes dispatch decisions, so we don't need
//! a SQL-level lease or cross-thread coordination.
//!
//! ## In-flight set
//!
//! In-memory `StringHashMap` of `{tenant_id}\x00{id}` keys. Marks a
//! row inflight from "scan finds it" until "envelope-9 (or env-11)
//! propose returns." Prevents the next tick from re-picking-up a
//! row whose envelope hasn't applied yet (raft commit + apply is
//! ~10-50ms; dispatch tick is sub-ms). Caller owns the map; we
//! mutate it and clear on demote.
//!
//! ## What the (target tenant's) handler can do today
//!
//! - Read + write its own kv. Writes ride envelope-0 alongside the
//!   schedule_complete envelope-9 in a multi-envelope, atomic with
//!   the schedule row delete + caller-tenant `_callback/{id}` write.
//! - Return a JS response (status, body). Captured into envelope-9
//!   exactly like the libcurl path captures an HTTP response.
//!
//! ## What it can NOT do today (5c initial scope)
//!
//! - Recursive `http.send` / `http.cancel` from within the handler.
//!   The Request's `pending_*` accumulators are null, so the bindings
//!   throw. Same restriction `dispatchCallbacks` removed in a follow-
//!   up; we'll do the same here when there's a concrete need.
//! - `events.emit`. Same reason.
//!
//! These are deliberate — `webhook.loop46.com` (the main v1 use
//! case) is read-only-on-its-own-state; the recursive surface lands
//! when a concrete customer recipe needs it.

const std = @import("std");
const kv_mod = @import("rove-kv");
const tape_mod = @import("rove-tape");
const tenant_mod = @import("rove-tenant");
const schedule_server = @import("rove-schedule-server");

const apply_mod = @import("apply.zig");
const dispatcher_mod = @import("dispatcher.zig");
const router_mod = @import("router.zig");
const worker_mod = @import("worker.zig");

const Request = dispatcher_mod.Request;
const Budget = dispatcher_mod.Budget;

/// Cap on rows dispatched per tick. Same posture as
/// `webhook_server`'s `MAX_PER_PASS=64` — enough to drain a
/// reasonable burst, small enough that one tenant can't starve
/// the dispatch loop for inbound h2 traffic.
pub const DEFAULT_MAX_PER_PASS: u32 = 32;

/// One pass over the internal pool. Returns the number of rows
/// the pass attempted to dispatch (regardless of outcome — in-process
/// success, demoted, or skipped due to inflight).
///
/// `store` is a per-worker schedules.db connection (lazy-opened by
/// the caller). `in_flight` is the per-worker inflight set; caller
/// owns its lifetime + clears it on leader-demote.
pub fn dispatchInternalSchedules(
    worker: anytype,
    store: *schedule_server.ScheduleStore,
    in_flight: *std.StringHashMapUnmanaged(void),
    max_per_pass: u32,
) !usize {
    if (!worker.raft.isLeader()) {
        // Drop in-flight bookkeeping when we're not leader — a
        // future leadership-acquired transition starts fresh.
        var it = in_flight.iterator();
        while (it.next()) |entry| worker.allocator.free(entry.key_ptr.*);
        in_flight.clearRetainingCapacity();
        return 0;
    }

    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const ready = try store.dueInternalRows(worker.allocator, now_ns, max_per_pass);
    defer {
        for (ready) |*r| {
            var x = r.*;
            x.deinit(worker.allocator);
        }
        worker.allocator.free(ready);
    }

    var dispatched: usize = 0;
    for (ready) |stored| {
        const probe = try buildInflightKey(worker.allocator, stored.row.tenant_id, stored.row.id);
        if (in_flight.contains(probe)) {
            worker.allocator.free(probe);
            continue;
        }
        try in_flight.put(worker.allocator, probe, {});
        defer {
            const removed = in_flight.fetchRemove(probe);
            if (removed) |kv| worker.allocator.free(kv.key);
        }

        runOneInternal(worker, &stored) catch |err| {
            std.log.warn(
                "internal-schedules: deliver {s}/{s}: {s}",
                .{ stored.row.tenant_id, stored.row.id, @errorName(err) },
            );
        };
        dispatched += 1;
    }
    return dispatched;
}

fn buildInflightKey(allocator: std.mem.Allocator, tenant_id: []const u8, id: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, tenant_id.len + 1 + id.len);
    @memcpy(buf[0..tenant_id.len], tenant_id);
    buf[tenant_id.len] = 0;
    @memcpy(buf[tenant_id.len + 1 ..], id);
    return buf;
}

fn runOneInternal(worker: anytype, stored: *const schedule_server.StoredSchedule) !void {
    const allocator = worker.allocator;
    const row = &stored.row;

    // 1. Parse URL → target tenant id. Must succeed since apply
    //    stamped is_internal=true; if it doesn't, the row is in
    //    the wrong pool and the only sane recovery is to demote it.
    const suffix = worker.tenant.publicSuffix() orelse {
        std.log.warn("internal-schedules: no public_suffix; demoting", .{});
        return proposeDemote(worker, stored);
    };
    const target_id = schedule_server.internal_routing.parseInstanceId(row.url, suffix) orelse {
        std.log.warn(
            "internal-schedules: {s}/{s}: URL {s} doesn't parse as internal; demoting",
            .{ row.tenant_id, row.id, row.url },
        );
        return proposeDemote(worker, stored);
    };

    // 2. Look up target tenant locally. If not hosted on this node
    //    (or no deployment yet), demote — libcurl will route through
    //    cluster ingress to whichever node hosts it.
    const tc = worker.tenant_files_map.get(target_id) orelse {
        std.log.info(
            "internal-schedules: {s}/{s}: target {s} not hosted locally; demoting",
            .{ row.tenant_id, row.id, target_id },
        );
        return proposeDemote(worker, stored);
    };
    if (tc.current_deployment_id == 0) {
        return proposeDemote(worker, stored);
    }
    const inst_opt = worker.tenant.getInstance(target_id) catch null;
    const inst = inst_opt orelse {
        return proposeDemote(worker, stored);
    };

    // 3. Resolve URL path → handler bytecode.
    const uri = std.Uri.parse(row.url) catch return proposeDemote(worker, stored);
    const url_path: []const u8 = switch (uri.path) {
        .raw => |p| p,
        .percent_encoded => |p| p,
    };
    const route_path = if (url_path.len == 0) "/" else url_path;
    var route = try router_mod.resolveRoute(allocator, route_path);
    defer route.deinit();

    const bytecode_opt = try worker_mod.findBytecode(tc, route.module_base, allocator);
    const bytecode = bytecode_opt orelse {
        // No handler at this path. Surface as a 404 to the caller's
        // on_result; same shape as libcurl would have produced if the
        // ingress routed to the same handler-less path.
        return proposeComplete(worker, stored, target_id, null, .failed, 404, "", "no handler at path");
    };

    // 4. Open a write txn against the target tenant's app.db. Mirrors
    //    the regular HTTP dispatch path. SQLITE_BUSY → another writer
    //    is mid-commit; skip this row, next tick will retry.
    var txn = inst.kv.beginTrackedImmediate() catch |err| {
        if (err == kv_mod.KvError.Conflict) return; // busy, retry next tick
        return err;
    };
    txn.open() catch |err| {
        if (err == kv_mod.KvError.Conflict) return;
        return err;
    };
    var committed = false;
    errdefer if (!committed) {
        txn.rollback() catch {};
    };

    var writeset = kv_mod.WriteSet.init(allocator);
    defer writeset.deinit();

    // 5. Synthesize Request from the schedule row.
    const request_id: u64 = blk: {
        const tl = worker.tenant_logs.get(inst.id) orelse break :blk 0;
        break :blk tl.id_minter.nextRequestId() catch 0;
    };
    var tapes = worker_mod.RequestTapes.init(allocator);
    defer tapes.deinit();

    const received_ns: i64 = @intCast(std.time.nanoTimestamp());
    const query_str: ?[]const u8 = switch (uri.query orelse std.Uri.Component{ .raw = "" }) {
        .raw => |q| if (q.len == 0) null else q,
        .percent_encoded => |q| if (q.len == 0) null else q,
    };

    const request: Request = .{
        .method = row.method,
        .path = route_path,
        .query = query_str,
        .body = row.body,
        .kv_tape = &tapes.kv,
        .date_tape = &tapes.date,
        .math_random_tape = &tapes.math_random,
        .crypto_random_tape = &tapes.crypto_random,
        .module_tape = &tapes.module,
        .prng_seed = @bitCast(received_ns),
        .request_id = request_id,
        .platform = inst.platform,
        .limiter = &worker.limiter,
        .instance_id = inst.id,
        // 5c initial scope: target handler can't recursively call
        // http.send / events.emit. Lifts when there's a concrete need.
        .pending_webhooks = null,
        .emit_buffer = null,
        .pending_schedules = null,
        .pending_cancels = null,
    };

    // 6. Run the handler. Same call shape as inbound h2 dispatch.
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = worker.dispatcher.run(
        inst.kv,
        &txn,
        &writeset,
        bytecode,
        &tc.bytecodes,
        &tc.source_hashes,
        tc.triggers,
        request,
        &budget,
    ) catch |err| {
        txn.rollback() catch {};
        committed = true; // skip the errdefer rollback
        return proposeComplete(
            worker,
            stored,
            target_id,
            null,
            .failed,
            if (err == dispatcher_mod.DispatchError.Interrupted) 504 else 500,
            "",
            @errorName(err),
        );
    };
    defer resp.deinit(allocator);

    if (worker.dispatcher.last_kv_error != null) {
        worker.dispatcher.last_kv_error = null;
        txn.rollback() catch {};
        committed = true;
        return proposeComplete(
            worker,
            stored,
            target_id,
            null,
            .failed,
            500,
            "",
            "kv error",
        );
    }

    if (resp.exception.len > 0) {
        txn.rollback() catch {};
        committed = true;
        return proposeComplete(
            worker,
            stored,
            target_id,
            null,
            .failed,
            500,
            "",
            resp.exception,
        );
    }

    // 7. Commit target's local txn (writes go to target.app.db on
    //    this node). The same writeset rides envelope-0 in the multi-
    //    envelope so other nodes apply it to their copies.
    try txn.commit();
    committed = true;

    // 8. Cap the response body at the row's max + propose.
    const status: u16 = @intCast(@max(0, @min(resp.status, 65535)));
    const body_capped = if (resp.body.len > row.max_body_bytes)
        resp.body[0..row.max_body_bytes]
    else
        resp.body;
    const outcome: schedule_server.Outcome = if (status >= 200 and status < 300)
        .delivered
    else
        .failed;

    try proposeComplete(worker, stored, target_id, &writeset, outcome, status, body_capped, "");
}

/// Build envelope-11 (schedule_demote) and propose. The row stays
/// in schedules.db; apply flips is_internal=false; the libcurl
/// scheduler thread picks it up next poll (woken by the env-11
/// apply-side wake).
fn proposeDemote(worker: anytype, stored: *const schedule_server.StoredSchedule) !void {
    const allocator = worker.allocator;
    const target: schedule_server.DemoteTarget = .{
        .tenant_id = stored.row.tenant_id,
        .id = stored.row.id,
    };
    const inner = try schedule_server.encodeDemote(allocator, &target);
    defer allocator.free(inner);
    const wrapped = try apply_mod.encodeScheduleDemoteEnvelope(allocator, inner);
    defer allocator.free(wrapped);
    const seq = worker.raft.highWatermark() + 1;
    worker.raft.propose(seq, wrapped) catch |err| {
        std.log.warn(
            "internal-schedules: {s}/{s}: propose envelope-11 failed: {s}",
            .{ stored.row.tenant_id, stored.row.id, @errorName(err) },
        );
        return err;
    };
}

/// Build envelope-9 (schedule_complete) carrying the dispatch result
/// + optional envelope-0 (target writeset). Wraps in multi when the
/// writeset is non-null and non-empty; bare envelope-9 otherwise.
fn proposeComplete(
    worker: anytype,
    stored: *const schedule_server.StoredSchedule,
    target_id: []const u8,
    writeset: ?*const kv_mod.WriteSet,
    outcome: schedule_server.Outcome,
    status: u16,
    response_body: []const u8,
    error_message: []const u8,
) !void {
    const allocator = worker.allocator;

    const env: schedule_server.CompleteEnvelope = .{
        .tenant_id = stored.row.tenant_id,
        .id = stored.row.id,
        .version_at_fire = stored.version,
        .outcome = outcome,
        .status = status,
        .response_headers_json = "",
        .response_body = response_body,
        .error_message = error_message,
    };
    const complete_payload = try schedule_server.encodeComplete(allocator, &env);
    defer allocator.free(complete_payload);
    const complete_env = try apply_mod.encodeScheduleCompleteEnvelope(
        allocator,
        stored.row.tenant_id,
        complete_payload,
    );
    defer allocator.free(complete_env);

    const has_writes = if (writeset) |ws| ws.ops.items.len > 0 else false;
    if (!has_writes) {
        const seq = worker.raft.highWatermark() + 1;
        try worker.raft.propose(seq, complete_env);
        return;
    }

    const ws_bytes = try writeset.?.encode(allocator);
    defer allocator.free(ws_bytes);
    const ws_env = try apply_mod.encodeWriteSetEnvelope(allocator, target_id, ws_bytes);
    defer allocator.free(ws_env);

    const wrapped = try apply_mod.encodeMultiEnvelope(allocator, &.{ ws_env, complete_env });
    defer allocator.free(wrapped);
    const seq = worker.raft.highWatermark() + 1;
    try worker.raft.propose(seq, wrapped);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "buildInflightKey concatenates with NUL separator" {
    const a = testing.allocator;
    const k = try buildInflightKey(a, "acme", "reminder-1");
    defer a.free(k);
    try testing.expectEqual(@as(usize, "acme".len + 1 + "reminder-1".len), k.len);
    try testing.expectEqualStrings("acme", k[0..4]);
    try testing.expectEqual(@as(u8, 0), k[4]);
    try testing.expectEqualStrings("reminder-1", k[5..]);
}
