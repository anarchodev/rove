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
//! The handler may call `kv.*` / `http.send` —
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

const dispatcher_mod = @import("dispatcher.zig");
const worker_mod = @import("worker.zig");
const raft_propose = @import("raft_propose.zig");
const tenant_batch = @import("tenant_batch.zig");
const send_outbox = @import("send_outbox.zig");
const send_dispatch = @import("send_dispatch.zig");

const Request = dispatcher_mod.Request;
const Budget = dispatcher_mod.Budget;

/// Per-tenant per-pass cap on completions resolved from
/// `SendDispatch.drainCompletion()`. Bounds the resolution tick's
/// wall time at high send volumes; the remainder catches up on
/// subsequent ticks.
pub const DEFAULT_MAX_PER_TENANT: u32 = 32;

// (fireEmitsIfWired removed — emit-firing now lives in
//  tenant_batch.zig, shared across the batched-dispatch paths.)

// ── Option (b): the leader-worker resolution phase ──────────────────
//
// 7-A: the dissolved schedule.db's work-queue role. Input is
// `SendDispatch.drainCompletion()` (the old schedules.db `c/`-row
// dispatchCallbacks scan is retired — deleted in 5b-2-c). §6.4
// Part-B continuation peel resumes parked continuations bound to a
// completion before the per-tenant batch txn opens.

/// `tenant_batch.drainTenantBatch` policy for the resolution phase.
/// Resolution closes via the `_send/proof/` commit → 4b-ii →
/// `resolve` (no schedules.db / no env-10 coupling). It captures
/// each row's outcome: `.kept`/`.dropped` ids are accumulated so the
/// phase can `enqueueRequeue` them (cross-thread → SendDispatch
/// thread → `resolving→completed`, re-pushed next tick — the
/// at-least-once retry the old `c/`-row gave). `.delivered` ⇒ proof
/// written ⇒ removed via the 4b-ii feed (nothing to do here).
/// Borrowed `{tenant_id, id, payload}` row view passed to
/// `drainTenantBatch`. Replaces the deleted
/// `schedule_server.ScheduleStore.CallbackRow` (5b-2-d) — fields
/// borrow the owning `send_dispatch.Completion`'s memory, so there
/// is no per-row deinit (the phase frees the Completions in bulk).
const CompletionRow = struct {
    tenant_id: []const u8,
    id: []const u8,
    payload: []const u8,
};

const SendCompletionPolicy = struct {
    /// Borrowed row.id slices for `.kept`/`.dropped` (valid until the
    /// phase frees the Completions, after it drains `requeued`).
    requeued: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn runOne(
        self: *SendCompletionPolicy,
        worker: anytype,
        tc: anytype,
        inst: *const tenant_mod.Instance,
        txn: anytype,
        ws: anytype,
        row: CompletionRow,
    ) !void {
        const oc = try runOneCallback(worker, tc, inst, txn, ws, row.id, row.payload);
        switch (oc) {
            .delivered => {}, // proof written → 4b-ii feed → resolve
            .kept, .dropped => try self.requeued.append(worker.allocator, row.id),
        }
    }

    pub fn needsPropose(_: *SendCompletionPolicy, ws: anytype) bool {
        return ws.ops.items.len > 0;
    }

    pub fn propose(
        _: *SendCompletionPolicy,
        worker: anytype,
        inst: *const tenant_mod.Instance,
        ws: anytype,
    ) !void {
        // The on_result handler's writes + Seam-A `_send/proof/`
        // commit in one batch; parkSendOps gates the proof on commit
        // → 4b-ii → resolve.
        const seq = try raft_propose.proposeBatch(worker, ws, inst.id);
        worker_mod.parkSendOps(worker, seq, inst.id, ws) catch |perr|
            std.log.warn("rove-js sendcompl parkSendOps (tenant={s}): {s}", .{ inst.id, @errorName(perr) });
        worker_mod.parkKvWakes(worker, seq, inst.id, ws) catch |perr|
            std.log.warn("rove-js sendcompl parkKvWakes (tenant={s}): {s}", .{ inst.id, @errorName(perr) });
    }
};

/// Leader-worker resolution drain (7-A). Caller pins to worker 0 on
/// the leader; the leader gate is here. Drains `SendDispatch`
/// completions, groups by tenant, and runs each through the
/// per-tenant batch machinery (`runOneCallback`/`drainTenantBatch`).
/// `.kept`/`.dropped` (incl. tenant-not-loaded / batch error) →
/// `enqueueRequeue` (retry). Returns rows processed.
pub fn dispatchSendCompletions(
    worker: anytype,
    sd: *send_dispatch.SendDispatch,
    max_per_tenant: u32,
) !usize {
    if (!worker.raft.isLeader()) return 0;
    const a = worker.allocator;

    const CAP: usize = 4096;
    var comps: std.ArrayListUnmanaged(send_dispatch.Completion) = .empty;
    defer {
        for (comps.items) |*c| c.deinit(a);
        comps.deinit(a);
    }
    while (comps.items.len < CAP) {
        const c = sd.drainCompletion() orelse break;
        comps.append(a, c) catch {
            var cc = c;
            cc.deinit(a);
            break;
        };
    }
    if (comps.items.len == 0) return 0;
    std.log.info("rove-js sendpath: dispatchSendCompletions drained={d}", .{comps.items.len});

    std.sort.pdq(send_dispatch.Completion, comps.items, {}, struct {
        fn lt(_: void, x: send_dispatch.Completion, y: send_dispatch.Completion) bool {
            return std.mem.lessThan(u8, x.tenant_id, y.tenant_id);
        }
    }.lt);

    var total: usize = 0;
    var start: usize = 0;
    while (start < comps.items.len) {
        var end = start + 1;
        while (end < comps.items.len and std.mem.eql(u8, comps.items[end].tenant_id, comps.items[start].tenant_id)) : (end += 1) {}
        defer start = end;

        const tenant_id = comps.items[start].tenant_id;
        const group = comps.items[start..end];

        // Tenant not loaded / no current deployment / unknown:
        // requeue the whole group (retry when the deploy lands —
        // at-least-once; the entries sit in `resolving`, requeue
        // moves them back to `completed` for re-push).
        const slot = worker.node.tenant_files_map.get(tenant_id) orelse {
            for (group) |g| sd.enqueueRequeue(g.callback_id) catch {};
            continue;
        };
        const snap = slot.pinCurrent() orelse {
            for (group) |g| sd.enqueueRequeue(g.callback_id) catch {};
            continue;
        };
        const tc = worker_mod.TenantFiles{ .slot = slot, .snap = snap };
        defer tc.release();
        const inst_opt = worker.node.tenant.getInstance(tenant_id) catch {
            for (group) |g| sd.enqueueRequeue(g.callback_id) catch {};
            continue;
        };
        const inst = inst_opt orelse {
            for (group) |g| sd.enqueueRequeue(g.callback_id) catch {};
            continue;
        };

        // §6.4 Part-B peel: resume parked continuations bound to a
        // completion before the per-tenant batch txn opens.
        // A completion whose send is bound to a parked continuation
        // on THIS worker resolves by resuming it (flush the held
        // socket), NOT by running on_result. resumeBoundContinuation
        // opens its own txn → must run BEFORE drainTenantBatch's
        // per-tenant batch txn (double-BEGIN deadlock class). Resumed
        // sends are resolved with a STANDALONE `_send/proof/` propose
        // (the new-path analogue of the old env-10 cancel-drop:
        // durable so a future leader's boot-scan skips owed-with-proof
        // — §6.4 is moot-on-loss, a stray re-fire would just hit a
        // dead socket → f&f-proof self-resolve) + an explicit
        // enqueueResolve (this standalone propose bypasses the
        // worker-side parkSendOps 4b-ii feed). Survivors swap-compact
        // to the front for the on_result path below.
        var proof_ws = kv_mod.WriteSet.init(a);
        defer proof_ws.deinit();
        var resumed_ids: std.ArrayListUnmanaged([]const u8) = .empty;
        defer resumed_ids.deinit(a);
        var rest: usize = 0;
        var ci: usize = 0;
        while (ci < group.len) : (ci += 1) {
            const g = group[ci];
            const resumed = blk: {
                var parsed = std.json.parseFromSlice(std.json.Value, a, g.receipt, .{
                    .ignore_unknown_fields = true,
                    .allocate = .alloc_always,
                }) catch break :blk false;
                defer parsed.deinit();
                const obj = switch (parsed.value) {
                    .object => |o| o,
                    else => break :blk false,
                };
                const event = buildCallbackEvent(a, parsed.value) catch break :blk false;
                defer a.free(event);
                const matched = worker_mod.resumeBoundContinuation(worker, inst.id, g.callback_id, event);
                std.log.info("rove-js sendpath: sendcompl §6.4 resume id={s} matched={}", .{ g.callback_id, matched });
                if (!matched) break :blk false;
                // Resumed: stage the durable proof (borrows obj
                // strings — encode before `parsed.deinit`). callback_id
                // borrowed from `comps` (freed at fn end, after the
                // standalone propose + enqueueResolve below).
                const enc = (proofFromReceipt(obj)).encode(a) catch break :blk true;
                defer a.free(enc);
                var kbuf: [send_outbox.KEY_BUF]u8 = undefined;
                proof_ws.addPut(send_outbox.proofKey(&kbuf, g.callback_id), enc) catch {};
                resumed_ids.append(a, g.callback_id) catch {};
                break :blk true;
            };
            if (!resumed) {
                // SWAP (not copy): every Completion stays in the
                // backing array exactly once so the caller's bulk
                // deinit frees each exactly once (resumed ones live
                // in group[rest..], still owned, freed there).
                if (rest != ci) std.mem.swap(send_dispatch.Completion, &group[rest], &group[ci]);
                rest += 1;
            }
        }
        if (proof_ws.ops.items.len > 0) {
            if (raft_propose.proposeBatch(worker, &proof_ws, inst.id)) |_| {
                for (resumed_ids.items) |id| sd.enqueueResolve(id) catch {};
            } else |e| std.log.warn(
                "rove-js sendcompl: §6.4 proof propose ({s}): {s} (left for recovery)",
                .{ inst.id, @errorName(e) },
            );
        }
        if (rest == 0) continue;
        const survivors = group[0..rest];

        const rows = a.alloc(CompletionRow, survivors.len) catch {
            for (survivors) |g| sd.enqueueRequeue(g.callback_id) catch {};
            continue;
        };
        defer a.free(rows);
        for (survivors, 0..) |g, i| rows[i] = .{ .tenant_id = g.tenant_id, .id = g.callback_id, .payload = g.receipt };

        var pol = SendCompletionPolicy{};
        defer pol.requeued.deinit(a);
        const n = tenant_batch.drainTenantBatch(worker, tc, inst, rows, @min(rows.len, max_per_tenant), &pol) catch |err| {
            std.log.warn("rove-js sendcompl: tenant {s}: {s}", .{ inst.id, @errorName(err) });
            for (group) |g| sd.enqueueRequeue(g.callback_id) catch {};
            continue;
        };
        for (pol.requeued.items) |id| sd.enqueueRequeue(id) catch |e|
            std.log.warn("rove-js sendcompl: requeue {s}: {s}", .{ id, @errorName(e) });
        total += n;
    }
    return total;
}

/// Outcome of `runOneCallback`. `SendCompletionPolicy.runOne`
/// switches on it: `.delivered` ⇒ the `_send/proof/` write committed
/// (4b-ii feed → `resolve` closes the send, nothing more to do);
/// `.kept`/`.dropped` ⇒ `enqueueRequeue` (retry next tick — Option
/// (b) at-least-once).
pub const CallbackOutcome = enum {
    /// `_send/proof/{id}` staged + handler writes captured (on the
    /// fire-and-forget path, proof only). Commit closes the send.
    delivered,
    /// Envelope was bad / handler missing — proof NOT written;
    /// requeued (a redeploy that adds the handler picks it up).
    dropped,
    /// Handler ran but threw / timed out / hit a kv error. Proof NOT
    /// written; requeued for the next tick to retry.
    kept,
};

fn runOneCallback(
    worker: anytype,
    tc: worker_mod.TenantFiles,
    inst: *const tenant_mod.Instance,
    txn: *kv_mod.KvStore.TrackedTxn,
    writeset: *kv_mod.WriteSet,
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
            return .dropped;
        },
    };

    const on_result: []const u8 = switch (obj.get("on_result") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => {
            // Option (b) FIRE-AND-FORGET: no on_result handler — the
            // send is resolved by recording its outcome. Identical
            // Seam-A `_send/proof/` the on_result success path writes;
            // its commit → 4b-ii feed → `resolve` closes it.
            // (runOneCallback can't reuse the handler path here, but
            // the proof write is the same.) On kv failure: `.kept` →
            // requeued, retried.
            writeSendProof(allocator, txn, writeset, callback_id, obj) catch |err| {
                std.log.warn(
                    "rove-js sendcompl: {s}/{s} fire-and-forget proof: {s} (kept)",
                    .{ inst.id, callback_id, @errorName(err) },
                );
                return .kept;
            };
            return .delivered;
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

    // Success: release the savepoint. The handler's writeset (+ the
    // `_send/proof/` write below) commits in the multi-envelope
    // propose; the proof's commit → 4b-ii feed → `resolve` closes
    // the send (Option (b) — no schedules.db cancel).
    txn.release() catch |err| {
        std.log.warn(
            "rove-js callbacks: {s}/{s} release failed: {s} (kept)",
            .{ inst.id, callback_id, @errorName(err) },
        );
        return .kept;
    };
    // Option-(b) increment 3(a) / FORK-2 Seam A: the send's result is
    // now durably delivered to the customer's on_result. Only NOW is
    // an on_result send "proven done" — recording proof at envelope-9
    // send-completion instead would let a crash between completion and
    // this commit silently drop the result delivery (Meaning-1
    // violation). Write `_send/proof/{id}` into THIS batch's writeset
    // so it commits atomically (envelope-0) with the handler effects +
    // the `c/` cancel-drop; `callback_id` == send id == the
    // `_send/owed/{id}` id. Proof presence ⇒ Option-(b) recovery may
    // GC the owed row + skip re-fire. Inert until recovery consumes it
    // (increment 4) — additive. On failure: keep the receipt so the
    // next tick retries — no-silent-loss; the callback re-runs under
    // the existing at-least-once semantic.
    writeSendProof(allocator, txn, writeset, callback_id, obj) catch |err| {
        std.log.warn(
            "rove-js callbacks: {s}/{s} send-proof write failed: {s} (kept)",
            .{ inst.id, callback_id, @errorName(err) },
        );
        return .kept;
    };
    return .delivered;
}

/// Build `send_outbox.Proof` from the callback `receipt` (the
/// envelope-9 JSON: `{ id, on_result, ok, status, body, error, ... }`,
/// docs/http-send-plan.md §8) and write `_send/proof/{callback_id}`
/// into the callback batch's txn + raft writeset — the same worker-
/// side platform-direct-write pattern increment 2's `writeOwedMarker`
/// uses. Tolerant decode: any missing/mistyped receipt field falls
/// back to the failure-shaped default (ok=false / status=0 / "") so a
/// malformed receipt still records *a* terminal proof rather than
/// looping recovery forever. `txn.put` / `addPut` copy key+value, so
/// the stack key buffer + freed `enc` are safe.
/// Tolerant `_send/proof/` payload from a receipt object — shared by
/// the Seam-A on_result path (`writeSendProof`) and the §6.4 resumed-
/// continuation resolution (5a standalone proof propose). Borrows the
/// receipt's string slices (valid for the caller's parse scope).
fn proofFromReceipt(receipt: std.json.ObjectMap) send_outbox.Proof {
    return .{
        .ok = switch (receipt.get("ok") orelse std.json.Value{ .null = {} }) {
            .bool => |b| b,
            else => false,
        },
        .status = switch (receipt.get("status") orelse std.json.Value{ .null = {} }) {
            .integer => |i| if (i >= 0 and i <= std.math.maxInt(u16)) @intCast(i) else 0,
            else => 0,
        },
        .body = switch (receipt.get("body") orelse std.json.Value{ .null = {} }) {
            .string => |s| s,
            else => "",
        },
        .err = switch (receipt.get("error") orelse std.json.Value{ .null = {} }) {
            .string => |s| s,
            else => "",
        },
    };
}

fn writeSendProof(
    allocator: std.mem.Allocator,
    txn: *kv_mod.KvStore.TrackedTxn,
    writeset: *kv_mod.WriteSet,
    callback_id: []const u8,
    receipt: std.json.ObjectMap,
) !void {
    const proof = proofFromReceipt(receipt);
    const enc = try proof.encode(allocator);
    defer allocator.free(enc);
    var kbuf: [send_outbox.KEY_BUF]u8 = undefined;
    const key = send_outbox.proofKey(&kbuf, callback_id);
    try txn.put(key, enc);
    try writeset.addPut(key, enc);
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
