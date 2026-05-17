//! In-process dispatch of internal-pool schedules (http-send-plan §3.2).
//!
//! The optimization that makes `webhook.loop46.com` (and any other
//! customer call to `{id}.{public_suffix}`) cheap. Instead of going
//! out via libcurl + cluster ingress + h2 + worker-side dispatch on
//! the target node, we synthesize a `Request` from the schedule row
//! and run `worker.dispatcher.run` directly against the target
//! tenant's bytecode + kv.
//!
//! ## Per-tenant batching
//!
//! A pass scans the internal pool once, resolves each row's *target*
//! tenant (the `{id}` the URL routes to — NOT the schedule's owner
//! `tenant_id`), groups contiguous same-target rows, and runs each
//! group through the shared `tenant_batch.drainTenantBatch` skeleton:
//! ONE tracked txn for the target tenant, every row's handler under a
//! per-row savepoint accumulating into one shared writeset + Cmd
//! buffers, then ONE `proposeMulti` carrying every row's
//! schedule_complete + the merged writeset + recursive upserts/
//! cancels. This is the same skeleton + propose path
//! `callback_dispatch` uses; the internal path was the last one still
//! doing per-row txn + per-row propose.
//!
//! ## Two-pool contract
//!
//! Apply-time stamping (in `applyScheduleUpsertBatch`) routes rows
//! whose URL parses as `{id}.{public_suffix}` AND `{id}` exists in
//! `__root__.db` into the internal pool — `is_internal=true`. This
//! phase drains that pool. Failed routing (target tenant not hosted
//! on this node, or no handler at the URL's path) explicitly demotes
//! the row to the external pool via envelope-11; the libcurl
//! scheduler thread fires it via cluster ingress instead. No
//! timeouts, no implicit fallback — the demote is the only path
//! from internal to external. (A handler that runs but throws / hits
//! its budget is NOT demoted — it completes `.failed`, same as the
//! libcurl path capturing a 5xx.)
//!
//! ## Leader + worker gating
//!
//! Same pattern as `dispatchCallbacks`: leader-only + worker 0 only,
//! enforced by the caller in `loop46/main.zig`.
//!
//! ## In-flight set
//!
//! In-memory `StringHashMap` of `{tenant_id}\x00{id}` keys. A row is
//! marked inflight for the whole pass (scan → propose) so the next
//! tick doesn't re-pick a row whose envelope hasn't applied yet.
//! Caller owns the map; we mutate it and clear on demote.

const std = @import("std");
const kv_mod = @import("rove-kv");
const tape_mod = @import("rove-tape");
const tenant_mod = @import("rove-tenant");
const schedule_server = @import("rove-schedule-server");

const apply_mod = @import("apply.zig");
const dispatcher_mod = @import("dispatcher.zig");
const router_mod = @import("router.zig");
const worker_mod = @import("worker.zig");
const sse_dispatch = @import("sse_dispatch.zig");
const raft_propose = @import("raft_propose.zig");
const tenant_batch = @import("tenant_batch.zig");

const Request = dispatcher_mod.Request;
const Budget = dispatcher_mod.Budget;

/// Cap on rows dispatched per tick. Same posture as the libcurl
/// scheduler thread's `MAX_PER_PASS=64` — enough to drain a
/// reasonable burst, small enough that one tenant can't starve
/// the dispatch loop for inbound h2 traffic.
pub const DEFAULT_MAX_PER_PASS: u32 = 32;

/// One pass over the internal pool. Returns the number of rows the
/// pass attempted (in-process success, completed-failed, demoted, or
/// skipped due to inflight).
///
/// `store` is a per-worker schedules.db connection (lazy-opened by
/// the caller). `in_flight` is the per-worker inflight set; caller
/// owns its lifetime + clears it on leader-demote.
pub fn dispatchInternalSchedules(
    worker: anytype,
    store: *schedule_server.ScheduleStore,
    in_flight: *std.StringHashMapUnmanaged(u64),
    max_per_pass: u32,
) !usize {
    const allocator = worker.allocator;
    if (!worker.raft.isLeader()) {
        // Lost leadership — drop all gating. Any locally-committed-
        // but-unconfirmed work either reconciles via the engine undo
        // log or legitimately re-fires on the new leader (the
        // at-least-once contract); a future leader-acquired pass
        // starts fresh.
        var it = in_flight.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        in_flight.clearRetainingCapacity();
        return 0;
    }

    // Release rows whose schedule_complete / demote has now COMMITTED
    // (committedSeq = "visible on all nodes"): only then is the row no
    // longer "due", so only then is forgetting it safe. Rows still
    // pending apply (seq > committedSeq) stay gated and are skipped
    // below — this closes the propose→apply re-dispatch window that
    // made recursive / under-load schedules re-fire and compound.
    const visible = worker.raft.committedSeq();
    {
        var evict: std.ArrayListUnmanaged([]const u8) = .empty;
        defer evict.deinit(allocator);
        var it = in_flight.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* <= visible) evict.append(allocator, e.key_ptr.*) catch {};
        }
        for (evict.items) |k| {
            if (in_flight.fetchRemove(k)) |kv| allocator.free(kv.key);
        }
    }

    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const ready = try store.dueInternalRows(allocator, now_ns, max_per_pass);
    defer {
        for (ready) |*r| {
            var x = r.*;
            x.deinit(allocator);
        }
        allocator.free(ready);
    }
    if (ready.len == 0) return 0;

    const Routable = struct {
        stored: *const schedule_server.StoredSchedule,
        target_id: []const u8,
        /// Owned in_flight key; rides until `gateInflight` either
        /// hands it to `in_flight` (proposed) or frees it (retry).
        probe: []u8,
    };

    var dispatched: usize = 0;

    const suffix = worker.node.tenant.publicSuffix() orelse {
        std.log.warn("internal-schedules: no public_suffix; demoting pass", .{});
        for (ready) |*stored| {
            const probe = try buildInflightKey(allocator, stored.row.tenant_id, stored.row.id);
            if (in_flight.contains(probe)) {
                allocator.free(probe);
                continue;
            }
            const dseq = proposeDemote(worker, stored) catch 0;
            gateInflight(in_flight, allocator, probe, dseq);
            dispatched += 1;
        }
        return dispatched;
    };

    // A row whose completion is still in flight (in `in_flight`, its
    // seq > committedSeq) is SKIPPED — re-dispatching before that
    // commit is the compounding bug. Unroutable → demote. The owned
    // `probe` rides the Routable until gated.
    var routable: std.ArrayListUnmanaged(Routable) = .empty;
    defer routable.deinit(allocator);
    for (ready) |*stored| {
        const probe = try buildInflightKey(allocator, stored.row.tenant_id, stored.row.id);
        if (in_flight.contains(probe)) {
            allocator.free(probe);
            continue;
        }
        const row = &stored.row;
        var tid: ?[]const u8 = null;
        if (schedule_server.internal_routing.parseInstanceId(row.url, suffix)) |id| {
            tid = id;
        } else if (schedule_server.internal_routing.targetHost(row.url)) |host| {
            if (worker.node.tenant.resolveDomain(host) catch null) |inst| tid = inst.id;
        }
        if (tid) |t| {
            routable.append(allocator, .{ .stored = stored, .target_id = t, .probe = probe }) catch |e| {
                allocator.free(probe);
                return e;
            };
        } else {
            std.log.warn(
                "internal-schedules: {s}/{s}: URL {s} doesn't route internal; demoting",
                .{ row.tenant_id, row.id, row.url },
            );
            const dseq = proposeDemote(worker, stored) catch 0;
            gateInflight(in_flight, allocator, probe, dseq);
            dispatched += 1;
        }
    }
    if (routable.items.len == 0) return dispatched;

    // Sort by target tenant so contiguous slices fall out of one
    // pass (mirrors dispatchCallbacks' grouping).
    std.sort.pdq(Routable, routable.items, {}, struct {
        fn lt(_: void, a: Routable, b: Routable) bool {
            return std.mem.lessThan(u8, a.target_id, b.target_id);
        }
    }.lt);

    // Parallel scratch of just the stored pointers — the skeleton
    // iterates a row slice; we hand it contiguous per-target slices.
    const stored_ptrs = try allocator.alloc(*const schedule_server.StoredSchedule, routable.items.len);
    defer allocator.free(stored_ptrs);
    for (routable.items, 0..) |r, i| stored_ptrs[i] = r.stored;

    var gi: usize = 0;
    while (gi < routable.items.len) {
        var gj = gi + 1;
        while (gj < routable.items.len and
            std.mem.eql(u8, routable.items[gj].target_id, routable.items[gi].target_id)) : (gj += 1)
        {}
        const grp = routable.items[gi..gj];
        const target_id = grp[0].target_id;
        const group = stored_ptrs[gi..gj];
        gi = gj;

        // Resolve the target tenant once for the whole group.
        const slot = worker.node.tenant_files_map.get(target_id) orelse {
            for (grp) |r| {
                const dseq = proposeDemote(worker, r.stored) catch 0;
                gateInflight(in_flight, allocator, r.probe, dseq);
                dispatched += 1;
            }
            continue;
        };
        const snap = slot.pinCurrent() orelse {
            for (grp) |r| {
                const dseq = proposeDemote(worker, r.stored) catch 0;
                gateInflight(in_flight, allocator, r.probe, dseq);
                dispatched += 1;
            }
            continue;
        };
        const tc = worker_mod.TenantFiles{ .slot = slot, .snap = snap };
        defer tc.release();
        const inst = (worker.node.tenant.getInstance(target_id) catch null) orelse {
            for (grp) |r| {
                const dseq = proposeDemote(worker, r.stored) catch 0;
                gateInflight(in_flight, allocator, r.probe, dseq);
                dispatched += 1;
            }
            continue;
        };

        var pol = InternalPolicy{ .allocator = allocator, .target_id = target_id };
        defer pol.deinit();
        const n = tenant_batch.drainTenantBatch(worker, tc, inst, group, group.len, &pol) catch |err| {
            std.log.warn(
                "internal-schedules: tenant {s} batch: {s}",
                .{ target_id, @errorName(err) },
            );
            // Nothing durably proposed for this group → free probes;
            // rows stay due and retry next pass.
            for (grp) |r| allocator.free(r.probe);
            continue;
        };
        // pol.proposed_seq carries every row's schedule_complete (0 if
        // the skeleton took the no-propose path → nothing completed;
        // retry). Gate each row until that seq commits.
        for (grp) |r| gateInflight(in_flight, allocator, r.probe, pol.proposed_seq);
        dispatched += n;
    }
    return dispatched;
}

/// Gate a dispatched row: hand its `probe` to `in_flight` keyed by
/// the raft seq its completion/demote rode, so the row is NOT
/// re-dispatched until `committedSeq()` reaches that seq (eviction at
/// the top of `dispatchInternalSchedules`). seq 0 ⇒ nothing durable
/// was proposed → free the probe so the row retries next pass. `put`
/// OOM also frees → retry. Never leaks, never double-frees (callers
/// only gate rows not already in `in_flight`, and `dueInternalRows`
/// yields distinct rows, so the key is always a fresh insert).
fn gateInflight(
    in_flight: *std.StringHashMapUnmanaged(u64),
    allocator: std.mem.Allocator,
    probe: []u8,
    seq: u64,
) void {
    if (seq == 0) {
        allocator.free(probe);
        return;
    }
    in_flight.put(allocator, probe, seq) catch allocator.free(probe);
}

fn buildInflightKey(allocator: std.mem.Allocator, tenant_id: []const u8, id: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, tenant_id.len + 1 + id.len);
    @memcpy(buf[0..tenant_id.len], tenant_id);
    buf[tenant_id.len] = 0;
    @memcpy(buf[tenant_id.len + 1 ..], id);
    return buf;
}

/// Internal-schedule policy for `tenant_batch.drainTenantBatch`.
/// **Stateful** — accumulates one encoded `schedule_complete`
/// envelope per processed row across the tenant batch, so it is
/// passed by pointer and its methods take `*InternalPolicy`.
///
/// Error semantics differ from the callback policy: a handler that
/// throws / times out / hits a kv error is NOT propagated as
/// keep-for-retry. It is caught here, its per-row savepoint is rolled
/// back, and a `.failed` completion is recorded so the schedule does
/// not re-fire forever (matching the old per-row `proposeResult`).
/// Only genuine infra failures (savepoint/release, OOM building the
/// completion) propagate → the skeleton's keep-for-retry path.
const InternalPolicy = struct {
    allocator: std.mem.Allocator,
    target_id: []const u8,
    /// Encoded schedule_complete envelopes, one per processed row.
    /// Ownership moves into the inner-list in `propose`; `deinit`
    /// frees whatever's left (the propose-not-reached path).
    completes: std.ArrayListUnmanaged([]u8) = .empty,
    delivered: usize = 0,
    failed: usize = 0,
    /// Raft seq the batch's multi-envelope (all schedule_completes +
    /// writeset + recursive upserts/cancels) was proposed at. 0 until
    /// `propose` runs. The caller gates every row of this batch in
    /// `in_flight` keyed by this seq, releasing only once
    /// `committedSeq()` reaches it.
    proposed_seq: u64 = 0,

    fn deinit(self: *InternalPolicy) void {
        for (self.completes.items) |c| self.allocator.free(c);
        self.completes.deinit(self.allocator);
    }

    /// Record a schedule_complete envelope for `stored`'s outcome.
    /// Genuine infra errors (encode OOM) propagate to the skeleton.
    fn recordComplete(
        self: *InternalPolicy,
        stored: *const schedule_server.StoredSchedule,
        outcome: schedule_server.Outcome,
        status: u16,
        body: []const u8,
        errmsg: []const u8,
    ) !void {
        const env: schedule_server.CompleteEnvelope = .{
            .tenant_id = stored.row.tenant_id,
            .id = stored.row.id,
            .version_at_fire = stored.version,
            .outcome = outcome,
            .status = status,
            .response_headers_json = "",
            .response_body = body,
            .error_message = errmsg,
        };
        const payload = try schedule_server.encodeComplete(self.allocator, &env);
        defer self.allocator.free(payload);
        const cenv = try apply_mod.encodeScheduleCompleteEnvelope(
            self.allocator,
            stored.row.tenant_id,
            payload,
        );
        errdefer self.allocator.free(cenv);
        try self.completes.append(self.allocator, cenv);
        if (outcome == .delivered) {
            self.delivered += 1;
        } else {
            self.failed += 1;
        }
    }

    pub fn runOne(
        self: *InternalPolicy,
        worker: anytype,
        tc: anytype,
        inst: *const tenant_mod.Instance,
        txn: anytype,
        ws: anytype,
        pe: anytype,
        ps: anytype,
        pc: anytype,
        stored: *const schedule_server.StoredSchedule,
    ) !void {
        const allocator = self.allocator;
        const row = &stored.row;

        const uri = std.Uri.parse(row.url) catch
            return self.recordComplete(stored, .failed, 400, "", "bad url");
        const url_path: []const u8 = switch (uri.path) {
            .raw => |p| p,
            .percent_encoded => |p| p,
        };
        const route_path = if (url_path.len == 0) "/" else url_path;
        var route = try router_mod.resolveRoute(allocator, route_path);
        defer route.deinit();

        const bytecode = (try worker_mod.findBytecode(tc, route.module_base, allocator)) orelse
            // No handler at this path → 404 completion (NOT demote:
            // it routed to a real tenant, just no module). Same shape
            // libcurl would have produced.
            return self.recordComplete(stored, .failed, 404, "", "no handler at path");

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
            // Option B (auth-domain-plan §4.7): routed authority
            // verbatim so host-relative handlers see the exact issuer.
            .host = schedule_server.internal_routing.targetAuthority(row.url) orelse "",
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
            .emit_buffer = pe,
            .pending_schedules = ps,
            .pending_cancels = pc,
        };

        // Per-row savepoint: a failing row rolls back ONLY its own
        // writes; prior rows in the tenant batch stay intact.
        // savepoint/release failure is infra → propagate.
        try txn.savepoint();

        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = worker.dispatcher.run(
            inst.kv,
            txn,
            ws,
            bytecode,
            &tc.snap.bytecodes,
            &tc.snap.source_hashes,
            tc.snap.triggers,
            request,
            &budget,
        ) catch |err| {
            txn.rollbackTo() catch {};
            return self.recordComplete(
                stored,
                .failed,
                if (err == dispatcher_mod.DispatchError.Interrupted) 504 else 500,
                "",
                @errorName(err),
            );
        };
        defer resp.deinit(allocator);

        if (worker.dispatcher.last_kv_error != null) {
            worker.dispatcher.last_kv_error = null;
            txn.rollbackTo() catch {};
            return self.recordComplete(stored, .failed, 500, "", "kv error");
        }
        if (resp.exception.len > 0) {
            txn.rollbackTo() catch {};
            return self.recordComplete(stored, .failed, 500, "", resp.exception);
        }

        // Keep this row's writes in the shared batch txn.
        try txn.release();

        const status: u16 = @intCast(@max(0, @min(resp.status, 65535)));
        const body_capped = if (resp.body.len > row.max_body_bytes)
            resp.body[0..row.max_body_bytes]
        else
            resp.body;
        const outcome: schedule_server.Outcome = if (status >= 200 and status < 300)
            .delivered
        else
            .failed;
        // Per-row observability line — same phrasing as the pre-
        // batching path so operator log-greps / smokes that match
        // "dispatched in-process to {target} status=" keep working.
        std.log.info(
            "internal-schedules: {s}/{s}: dispatched in-process to {s} status={d} outcome={s}",
            .{ row.tenant_id, row.id, self.target_id, status, @tagName(outcome) },
        );
        try self.recordComplete(stored, outcome, status, body_capped, "");
    }

    pub fn needsPropose(self: *InternalPolicy, ws: anytype, ps: anytype, pc: anytype) bool {
        // A fired schedule MUST be marked complete even with an empty
        // writeset, so any recorded completion forces a propose.
        return self.completes.items.len > 0 or
            ws.ops.items.len > 0 or
            ps.items.len > 0 or
            pc.items.len > 0;
    }

    pub fn propose(
        self: *InternalPolicy,
        worker: anytype,
        inst: *const tenant_mod.Instance,
        ws: anytype,
        ps: anytype,
        pc: anytype,
    ) !void {
        _ = inst;
        const allocator = self.allocator;
        var inner: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (inner.items) |e| allocator.free(e);
            inner.deinit(allocator);
        }
        // Reserve so completes move infallibly (no double-free path).
        try inner.ensureTotalCapacity(allocator, self.completes.items.len + 3);

        // Writeset first — proposeMulti's chunk-0 convention.
        if (ws.ops.items.len > 0) {
            const wb = try ws.encode(allocator);
            defer allocator.free(wb);
            inner.appendAssumeCapacity(try apply_mod.encodeWriteSetEnvelope(allocator, self.target_id, wb));
        }
        // Move every per-row completion in; ownership → inner.
        for (self.completes.items) |c| inner.appendAssumeCapacity(c);
        self.completes.clearRetainingCapacity();
        // Recursive http.send / http.cancel queued by the handlers.
        if (ps.items.len > 0) {
            const p = try schedule_server.encodeUpsertBatch(allocator, ps.items);
            defer allocator.free(p);
            inner.appendAssumeCapacity(try apply_mod.encodeScheduleUpsertEnvelope(allocator, p));
        }
        if (pc.items.len > 0) {
            const p = try schedule_server.encodeCancelBatch(allocator, pc.items);
            defer allocator.free(p);
            inner.appendAssumeCapacity(try apply_mod.encodeScheduleCancelEnvelope(allocator, p));
        }

        std.log.info(
            "internal-schedules: tenant {s} batch: delivered={d} failed={d} inners={d}",
            .{ self.target_id, self.delivered, self.failed, inner.items.len },
        );
        self.proposed_seq = try raft_propose.proposeMulti(worker, inner.items);
    }
};

/// Build envelope-11 (schedule_demote) and propose. The row stays
/// in schedules.db; apply flips is_internal=false; the libcurl
/// scheduler thread picks it up next poll (woken by the env-11
/// apply-side wake).
fn proposeDemote(worker: anytype, stored: *const schedule_server.StoredSchedule) !u64 {
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
    return seq;
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
