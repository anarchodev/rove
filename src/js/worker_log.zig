//! Per-tenant log capture, batch flush, and push notification.
//!
//! Mirrors the TenantFiles helpers in `worker.zig`. Each tenant gets a
//! per-tenant `RequestIdMinter` whose chunked-reservation counter
//! persists into the tenant's app.db at `_log/next_request_seq`.
//! Opened eagerly during `Worker.create` (via `TenantLog.open` calling
//! into `openTenantLog`), freed during `Worker.destroy`.
//!
//! Periodic `flushLogs` drains the node-wide log buffer into a single
//! embedded-sidecar `.ndjson` object PUT to the configured
//! `BatchStore` (Phase 5.5 a — leader only; followers' buffer stays
//! empty because `dispatchPending` early-returns 503 on followers).
//! `pushLoop` runs on its own thread and POSTs the resulting batch
//! keys to log-server so its indexer GETs them directly rather than
//! waiting for the LIST polling cycle.
//!
//! Lives in its own file so `worker.zig` can stay focused on
//! lifecycle (init, polling, tenant-state caching, dispatch) while
//! the log-shaped logic clusters here. Same shape as
//! `worker_dispatch.zig`: every function takes `worker: anytype` so
//! the structural-typed access to Worker's fields keeps working
//! without forcing this file to depend on the comptime Worker type.

const std = @import("std");
const log_mod = @import("rove-log");
const log_server_mod = @import("rove-log-server");
const jwt_mod = @import("rove-jwt");
const blob_mod = @import("rove-blob");
const tape_mod = @import("rove-tape");
const tenant_mod = @import("rove-tenant");

const worker_mod = @import("worker.zig");
const worker_upload_checkpoint = @import("worker_upload_checkpoint.zig");
const TenantLog = worker_mod.TenantLog;

// ── Tenant-log open/free ──────────────────────────────────────────────

pub fn openTenantLog(
    worker: anytype,
    inst: *const tenant_mod.Instance,
    worker_id: u16,
) !*TenantLog {
    const allocator = worker.allocator;

    const id_copy = try allocator.dupe(u8, inst.id);
    errdefer allocator.free(id_copy);

    const tl = try allocator.create(TenantLog);
    errdefer allocator.destroy(tl);
    tl.* = .{
        .allocator = allocator,
        .instance_id = id_copy,
        .id_minter = undefined,
    };
    tl.id_minter = try log_mod.RequestIdMinter.init(
        allocator,
        worker_id,
        .{
            .seq_kv = inst.kv,
            .seq_key = "_log/next_request_seq",
        },
    );
    return tl;
}

pub fn freeTenantLog(allocator: std.mem.Allocator, tl: *TenantLog) void {
    tl.id_minter.deinit();
    allocator.free(tl.instance_id);
    allocator.destroy(tl);
}

/// Mirror of `getOrOpenTenantFiles` for the log store. Lazy-opens a
/// TenantLog for instances created at runtime so pre-minted
/// request_ids and webhook rows get matching log records.
pub fn getOrOpenTenantLog(
    worker: anytype,
    inst: *const tenant_mod.Instance,
) !*TenantLog {
    return worker.tenant_logs.getOrOpen(worker, inst);
}

// ── Tape capture ──────────────────────────────────────────────────────
//
// `tape_mod.Readset` is the per-request structural holder for the
// four channels (kv / module / fetch_responses / trigger_payload);
// the worker allocates one per dispatch, hands its pointer to the
// dispatcher via `Request.readset`, then serializes + flushes the
// non-empty channels via `captureTapes*` below.
// `Math.random` / `crypto.*` / `Date.now` no longer have dedicated
// channels (§9 + fold-in); the readset's `seed` + `timestamp_ns`
// scalars are stamped onto arenajs's per-context state by the
// dispatcher (`JS_SetRandomSeed` + `JS_SetDateNow`).

/// Maximum captured body length (request OR response). Anything
/// bigger gets truncated to this prefix and the corresponding
/// `*_truncated` flag set on the log record's tape payloads. Mirrors
/// PLAN §2.4's body-cap default.
pub const REQUEST_BODY_CAP: usize = 256 * 1024;

/// Serialize each non-empty tape into the request's `TapePayloads`,
/// owned by the caller's allocator. The bytes ride inline in the
/// next ndjson flush — no per-request S3 PUT, no separate blob
/// store.
///
/// Best-effort: on any serialize failure the channel is left empty
/// and a warning is logged. Tape capture failures must never kill
/// the request.
///
/// Pre-Phase-5.5(a-2) this function ('uploadTapes') issued one
/// content-addressed S3 PUT per channel per request through a
/// shared std.http.Client. The fanout — plus a stdlib keep-alive
/// bug that drops the OVH connection under concurrency — capped
/// tape capture at single-digit-thousand req/s. Inlining moves
/// the bytes onto the per-flush PUT path, which carries the whole
/// batch in a single request.
pub fn captureTapes(
    worker: anytype,
    readset: *tape_mod.Readset,
    request_body: []const u8,
) log_mod.TapePayloads {
    const allocator = worker.allocator;

    var payloads: log_mod.TapePayloads = .{
        .seed = readset.seed,
        .timestamp_ns = readset.timestamp_ns,
    };

    const channels = [_]struct {
        tape: *tape_mod.Tape,
        out: *[]const u8,
    }{
        .{ .tape = &readset.kv, .out = &payloads.kv_tape_bytes },
        .{ .tape = &readset.module, .out = &payloads.module_tree_bytes },
        .{ .tape = &readset.fetch_responses, .out = &payloads.fetch_responses_tape_bytes },
        .{ .tape = &readset.trigger_payload, .out = &payloads.trigger_payload_tape_bytes },
    };

    for (channels) |ch| {
        if (ch.tape.entries.items.len == 0) continue;
        const bytes = ch.tape.serialize(allocator) catch |err| {
            std.log.warn("rove-js tape serialize failed: {s}", .{@errorName(err)});
            continue;
        };
        ch.out.* = bytes;
    }

    // Request body — captured into the log record so the replay
    // shell's `request.body` is non-empty for POST / PUT requests.
    // Bodies bigger than `REQUEST_BODY_CAP` get truncated to that
    // prefix; the truncation flag is preserved so the simulator (and
    // the replay shell) know the captured bytes are a prefix.
    //
    // Response body is intentionally NOT captured: deterministic
    // replay re-produces the response by re-running the handler with
    // the same request body + tapes, so storing the original would
    // be pure duplication on every S3 batch PUT.
    if (request_body.len > 0) {
        const captured_len = @min(request_body.len, REQUEST_BODY_CAP);
        if (allocator.dupe(u8, request_body[0..captured_len])) |captured| {
            payloads.request_body_bytes = captured;
            payloads.request_body_truncated = captured_len < request_body.len;
        } else |err| {
            std.log.warn("rove-js request-body capture failed: {s}", .{@errorName(err)});
        }
    }

    return payloads;
}

/// `captureTapes` + activation-input bytes capture (effect-reification
/// Phase 2D). Used by activations whose Msg payload carries bytes the
/// handler reads as `request.activation.bytes` — today only
/// `fetch_chunk`. The activation bytes ride
/// `TapePayloads.activation_bytes` (capped at `REQUEST_BODY_CAP`,
/// mirroring the body capture). L3 (algebra): closes worklist #1 —
/// every Msg is recorded, including its bytes.
pub fn captureTapesWithActivation(
    worker: anytype,
    readset: *tape_mod.Readset,
    request_body: []const u8,
    activation_bytes: []const u8,
) log_mod.TapePayloads {
    var payloads = captureTapes(worker, readset, request_body);
    if (activation_bytes.len == 0) return payloads;
    const allocator = worker.allocator;
    const captured_len = @min(activation_bytes.len, REQUEST_BODY_CAP);
    if (allocator.dupe(u8, activation_bytes[0..captured_len])) |captured| {
        payloads.activation_bytes = captured;
        payloads.activation_bytes_truncated = captured_len < activation_bytes.len;
    } else |err| {
        std.log.warn("rove-js activation-bytes capture failed: {s}", .{@errorName(err)});
    }
    return payloads;
}

// ── Log record capture ────────────────────────────────────────────────

/// Append a log record for a request that has finished its dispatch
/// pass. Best-effort: any internal failure is logged to stderr and
/// dropped (no propagation back to the caller — the request itself
/// must not fail because logging failed). Caller passes:
///
/// - `instance_id`: tenant id (must already exist in tenant_logs).
/// - `received_ns`: wall-clock when the worker first saw the request.
/// - `console` / `exception`: ownership is TRANSFERRED. The function
///   takes them and stores them on the LogRecord. Caller must not
///   free them after a successful return.
///
/// On any error path inside captureLog, the transferred buffers ARE
/// freed by this function so the caller doesn't have to do anything
/// special. (Caller can pass `&.{}` for a borrowed empty slice safely.)
pub fn captureLog(
    worker: anytype,
    instance_id: []const u8,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    deployment_id: u64,
    received_ns: i64,
    status: u16,
    outcome: log_mod.Outcome,
    console_owned: []u8,
    exception_owned: []u8,
    tapes: log_mod.TapePayloads,
    correlation_id: ?[]const u8,
    activation: log_mod.ActivationSource,
    /// Phase 5b: the raft seq the envelope carrying this request's
    /// writeset was proposed at. Pass 0 for paths with no associated
    /// raft entry (early-error / read-only). The per-worker
    /// `flushLogs` advances `last_uploaded_seq` by `max(raft_seq)`.
    raft_seq: u64,
) void {
    captureLogWithId(
        worker,
        instance_id,
        null,
        method,
        path,
        host,
        deployment_id,
        received_ns,
        status,
        outcome,
        console_owned,
        exception_owned,
        tapes,
        correlation_id,
        activation,
        raft_seq,
    );
}

/// Same as `captureLog`, but lets the caller supply a pre-minted
/// `request_id` so the log record shares its id with the webhook rows
/// a handler may have spawned via `webhook.send`. Pass `null` to mint
/// fresh.
///
/// Takes ownership of `tapes` byte allocations on success. On
/// failure they're freed alongside `console_owned` / `exception_owned`.
pub fn captureLogWithId(
    worker: anytype,
    instance_id: []const u8,
    request_id: ?u64,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    deployment_id: u64,
    received_ns: i64,
    status: u16,
    outcome: log_mod.Outcome,
    console_owned: []u8,
    exception_owned: []u8,
    tapes: log_mod.TapePayloads,
    correlation_id: ?[]const u8,
    activation: log_mod.ActivationSource,
    raft_seq: u64,
) void {
    captureLogInner(
        worker,
        instance_id,
        request_id,
        method,
        path,
        host,
        deployment_id,
        received_ns,
        status,
        outcome,
        console_owned,
        exception_owned,
        tapes,
        correlation_id,
        activation,
        raft_seq,
    ) catch |err| {
        std.log.warn("rove-js: log capture failed for {s}: {s}", .{ instance_id, @errorName(err) });
        // The transferred buffers must still be freed.
        if (console_owned.len > 0) worker.allocator.free(console_owned);
        if (exception_owned.len > 0) worker.allocator.free(exception_owned);
        var t = tapes;
        t.deinit(worker.allocator);
    };
}

fn captureLogInner(
    worker: anytype,
    instance_id: []const u8,
    request_id: ?u64,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    deployment_id: u64,
    received_ns: i64,
    status: u16,
    outcome: log_mod.Outcome,
    console_owned: []u8,
    exception_owned: []u8,
    tapes: log_mod.TapePayloads,
    correlation_id: ?[]const u8,
    activation: log_mod.ActivationSource,
    raft_seq: u64,
) !void {
    const tl = worker.tenant_logs.get(instance_id) orelse return error.NoTenantLog;
    const allocator = worker.allocator;

    // Dupe the borrowed strings (tenant_id/method/path/host). On
    // failure the transferred buffers are freed by the outer
    // captureLog wrapper.
    const a_tenant = try allocator.dupe(u8, instance_id);
    errdefer allocator.free(a_tenant);
    const a_method = try allocator.dupe(u8, method);
    errdefer allocator.free(a_method);
    const a_path = try allocator.dupe(u8, path);
    errdefer allocator.free(a_path);
    const a_host = try allocator.dupe(u8, host);
    errdefer allocator.free(a_host);
    const a_corr: []const u8 = if (correlation_id) |c|
        if (c.len > 0) try allocator.dupe(u8, c) else ""
    else
        "";
    errdefer if (a_corr.len > 0) allocator.free(a_corr);

    const id = request_id orelse try tl.id_minter.nextRequestId();
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());

    try worker.log_buffer.append(.{
        .tenant_id = a_tenant,
        .request_id = id,
        .deployment_id = deployment_id,
        .received_ns = received_ns,
        .duration_ns = now_ns - received_ns,
        .method = a_method,
        .path = a_path,
        .host = a_host,
        .status = status,
        .outcome = outcome,
        .console = console_owned,
        .exception = exception_owned,
        .tapes = tapes,
        .correlation_id = a_corr,
        .activation = activation,
        .raft_seq = raft_seq,
    });
}

// ── Batch flush + push-to-log-server ──────────────────────────────────

/// Periodically drain the worker's node-wide log buffer into a
/// single embedded-sidecar `.ndjson` object and PUT it to the
/// configured `BatchStore` (Phase 5.5 a). Runs on the leader only
/// — followers' buffer is always empty because `dispatchPending`
/// early-returns 503 on followers. Lossy on PUT failure: records
/// already left the buffer; per `docs/logs-plan.md` §1 a node-
/// failure window may drop one batch.
///
/// Phase 5.5(a-2) interleaved-per-node flush: every record carries
/// its `tenant_id`; the indexer demuxes on read. One S3 object per
/// flush window per node regardless of tenant fan-in.
pub fn flushLogs(worker: anytype) !void {
    const allocator = worker.allocator;
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());

    if (!worker.log_buffer.shouldFlush(now_ns)) return;

    const drained = worker.log_buffer.drainRecords(allocator) catch |err| {
        std.log.warn(
            "rove-js flushLogs: drainRecords failed: {s}",
            .{@errorName(err)},
        );
        return;
    };
    const records = drained orelse return;
    defer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }

    if (!worker.raft.isLeader()) {
        std.log.warn(
            "rove-js flushLogs: dropping {d}-record batch — lost leadership mid-tick",
            .{records.len},
        );
        return;
    }

    var node_buf: [8]u8 = undefined;
    const node_id_hex = std.fmt.bufPrint(&node_buf, "{x:0>8}", .{worker.raft.config.node_id}) catch unreachable;
    const flush_unix_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));

    const batch_key_opt = log_server_mod.flush_writer.writeBatch(
        allocator,
        worker.log_batch_store,
        node_id_hex,
        records,
        flush_unix_ms,
    ) catch |err| blk: {
        std.log.warn(
            "rove-js flushLogs: writeBatch ({d} records) failed: {s}",
            .{ records.len, @errorName(err) },
        );
        break :blk null;
    };
    const batch_key = batch_key_opt orelse return;
    defer allocator.free(batch_key);

    // Push the batch key to log-server so its indexer can GET the
    // object directly (read-after-write consistent on S3 even when
    // list-after-write isn't). Fire-and-forget — if it fails, the
    // indexer's 500ms LIST polling picks the batch up on the next
    // cycle. The push just collapses the typical worst-case
    // visibility window from ~seconds to ~tens of ms.
    pushBatchKey(worker, allocator, batch_key) catch |err| {
        std.log.warn(
            "rove-js flushLogs: pushBatchKey({s}) failed: {s}",
            .{ batch_key, @errorName(err) },
        );
    };

    // Phase 5b: advance the per-worker `last_uploaded_seq` checkpoint
    // by `max(record.raft_seq)` across the drained batch. Records
    // with raft_seq == 0 (early-error / read-only / not-yet-plumbed
    // paths) are skipped so they don't reset the watermark. Failure
    // here is non-fatal — the checkpoint stays at its previous value;
    // Phase 5c's walker will re-derive + re-push the entries we
    // would've advanced past, and the indexer's
    // `INSERT OR IGNORE (tenant_id, request_id)` absorbs the
    // duplicate.
    advanceUploadCheckpoint(worker, records) catch |err| {
        std.log.warn(
            "rove-js flushLogs: advanceUploadCheckpoint failed: {s}",
            .{@errorName(err)},
        );
    };
}

/// Per-worker checkpoint advance — `worker.last_uploaded_seq =
/// max(records[].raft_seq)` if it advanced. Skips 0-seq records.
fn advanceUploadCheckpoint(
    worker: anytype,
    records: []const log_mod.LogRecord,
) !void {
    if (worker.data_dir == null) return;
    var batch_max: u64 = 0;
    for (records) |r| {
        if (r.raft_seq > batch_max) batch_max = r.raft_seq;
    }
    if (batch_max <= worker.last_uploaded_seq) return;
    try worker_upload_checkpoint.writeCheckpoint(
        worker.allocator,
        worker.data_dir.?,
        worker.log_worker_id,
        batch_max,
    );
    worker.last_uploaded_seq = batch_max;
}

/// Enqueue a freshly-PUT batch key for the push thread to ship to
/// log-server. Fast path: dupe + mutex-protected append + event set.
/// The synchronous curl POST that used to live here now happens on
/// the `pushLoop` thread, batching every key that queued up between
/// pushes into one request body.
fn pushBatchKey(
    worker: anytype,
    allocator: std.mem.Allocator,
    batch_key: []const u8,
) !void {
    if (worker.log_push_curl == null) return;
    if (worker.log_public_base) |base| {
        if (base.len == 0) return;
    } else return;
    const key_copy = try allocator.dupe(u8, batch_key);
    worker.push_queue_mutex.lock();
    defer worker.push_queue_mutex.unlock();
    worker.push_queue.append(allocator, key_copy) catch |err| {
        allocator.free(key_copy);
        return err;
    };
    worker.push_wake.set();
}

/// Cap on keys per outbound request — keeps the body bounded and
/// matches the log-server's read-buffer expectations. Above this the
/// loop sends multiple requests in sequence.
const PUSH_MAX_KEYS_PER_REQUEST: usize = 1024;

/// Background log-server push loop. Wakes on `push_wake` (set by
/// `pushBatchKey`) or every `PUSH_TICK_NS` regardless. Drains the
/// queue into a local slice, packs the keys into a newline-separated
/// body, and POSTs to `/v1/_internal/batch-pushed`. The S3 batch
/// itself was already PUT by the flusher; this thread only tells
/// log-server *that the key exists*, so failures are soft — the
/// indexer's LIST polling is the catch-up.
pub fn pushLoop(worker: anytype) void {
    const PUSH_TICK_NS: u64 = 50 * std.time.ns_per_ms;
    const allocator = worker.allocator;
    while (!worker.push_should_stop.load(.acquire)) {
        worker.push_wake.timedWait(PUSH_TICK_NS) catch {};
        worker.push_wake.reset();

        // Drain the queue into a local list under the mutex, then
        // release it before doing curl I/O. Workers append while we
        // POST; that's fine — they'll show up on the next tick.
        var drained: std.ArrayList([]u8) = .empty;
        worker.push_queue_mutex.lock();
        std.mem.swap(std.ArrayList([]u8), &drained, &worker.push_queue);
        worker.push_queue_mutex.unlock();
        if (drained.items.len == 0) continue;

        var sent: usize = 0;
        while (sent < drained.items.len) {
            const end = @min(sent + PUSH_MAX_KEYS_PER_REQUEST, drained.items.len);
            const chunk = drained.items[sent..end];
            sendPushChunk(worker, allocator, chunk) catch |err| {
                std.log.warn(
                    "rove-js push: send {d} keys failed: {s} (LIST polling will catch up)",
                    .{ chunk.len, @errorName(err) },
                );
            };
            sent = end;
        }
        for (drained.items) |k| allocator.free(k);
        drained.deinit(allocator);
    }
}

/// POST a single chunk of newline-separated batch keys.
fn sendPushChunk(
    worker: anytype,
    allocator: std.mem.Allocator,
    keys: []const []u8,
) !void {
    const easy = worker.log_push_curl orelse return;
    const log_base = worker.log_public_base orelse return;
    const secret = worker.services_jwt_secret orelse return;

    const url = try std.fmt.allocPrint(allocator, "{s}/v1/_internal/batch-pushed", .{log_base});
    defer allocator.free(url);

    // JWT is minted once per chunk (60 s exp). Reusing it across
    // multiple chunks in the same tick would be cheaper, but the
    // chunk loop almost always runs just once.
    const now_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
    const token = try jwt_mod.mint(allocator, secret, .{ .exp_ms = now_ms + 60 * 1000 });
    defer allocator.free(token);
    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_value);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    for (keys, 0..) |k, i| {
        if (i > 0) try body.append(allocator, '\n');
        try body.appendSlice(allocator, k);
    }

    const headers = [_]blob_mod.curl.Header{
        .{ .name = "Authorization", .value = auth_value },
        .{ .name = "Content-Type", .value = "text/plain" },
    };
    const use_h2c = std.mem.startsWith(u8, url, "http://");
    var resp = try easy.request(allocator, .{
        .method = .POST,
        .url = url,
        .headers = &headers,
        .body = body.items,
        .timeout_ms = 2000,
        .connect_timeout_ms = 500,
        .http_version = if (use_h2c) .h2c_prior_knowledge else .auto,
        .verify_tls = !worker.internal_insecure_tls,
    });
    defer resp.deinit(allocator);
    if (resp.status != 204) {
        std.log.warn(
            "rove-js push batch: {s} ({d} keys) → {d}",
            .{ url, keys.len, resp.status },
        );
    }
}
