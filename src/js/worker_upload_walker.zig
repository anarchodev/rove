//! Promotion-time tape upload walker
//! (`docs/readset-replication-plan.md` Phase 5c).
//!
//! When a node loses leadership pre-flush, its in-memory
//! `NodeLogBuffer` dies with the process. Followers see the raft
//! entries replicated (the writeset applied to local kvexp + the
//! readset list, with each entry's `LogHeader`, validated at apply
//! time) but never produce LogRecords for them. Customer-facing
//! replay shows a gap for the request that crashed the worker —
//! exact failure mode Phase 5 closes.
//!
//! This module derives LogRecords from raft entries on demand. The
//! walker reads each raft entry's framed `[u64 seq BE][envelope]`,
//! decodes type-0 (`writeset`) and type-1 (`multi` wrapping
//! type-0/2 inners), parses each readset blob's `LogHeader` and tape
//! channels via `tape_mod.parseReadset`, and builds a LogRecord
//! ready for the existing log_buffer + flushLogs pipeline. Indexer
//! idempotency on `(tenant_id, request_id)` absorbs any duplicate
//! against a record the original leader had already pushed.

const std = @import("std");
const apply_mod = @import("apply.zig");
const tape_mod = @import("rove-tape");
const log_mod = @import("rove-log");

/// Max raft entries the walker processes per flusher tick. Caps
/// per-tick latency so a long catch-up (e.g., fresh leader with
/// hundreds of thousands of entries to re-derive) doesn't starve
/// the rest of the flusher's work. The next tick picks up where
/// this one left off via `worker.upload_walker_idx`.
pub const WALKER_BATCH_CAP: u64 = 256;

/// Decode a raft entry's framed payload into zero-or-more
/// LogRecords. `framed` is the raw bytes from `RaftLog.get(idx).data`
/// (8-byte BE seq prefix + envelope).
///
/// Returns an owned slice; each LogRecord's `[]const u8` fields are
/// allocator-owned (caller `deinit`s each + frees the outer slice).
///
/// Skips entries that don't carry per-request log records:
///   - rs_bytes empty (non-handler producer: ACME, secondary inners
///     of a batched propose, root_writeset)
///   - Readset blob carries no `LogHeader` (slice 5a's null sentinel,
///     or paths that didn't stamp one)
///   - type-2 `root_writeset` (no per-tenant id, no LogHeader)
///
/// Recurses into type-1 `multi` envelopes (walks every inner).
pub fn hydrateRecordsFromRaftEntry(
    allocator: std.mem.Allocator,
    framed: []const u8,
) ![]log_mod.LogRecord {
    if (framed.len < 8) return &.{};
    const raft_seq = std.mem.readInt(u64, framed[0..8], .big);
    const env_bytes = framed[8..];

    var records: std.ArrayListUnmanaged(log_mod.LogRecord) = .empty;
    errdefer {
        for (records.items) |*r| r.deinit(allocator);
        records.deinit(allocator);
    }

    try hydrateInto(allocator, &records, env_bytes, raft_seq);
    return records.toOwnedSlice(allocator);
}

fn hydrateInto(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(log_mod.LogRecord),
    env_bytes: []const u8,
    raft_seq: u64,
) !void {
    const env = apply_mod.decodeEnvelope(env_bytes) catch return;
    switch (env.type) {
        .writeset => try hydrateWriteSetEnvelope(allocator, out, env, raft_seq),
        .multi => {
            const inner_slice = apply_mod.decodeMultiInner(allocator, env.payload) catch return;
            defer allocator.free(inner_slice);
            for (inner_slice) |inner| {
                try hydrateInto(allocator, out, inner, raft_seq);
            }
        },
        .root_writeset => {
            // No per-tenant id, no per-request LogHeader — platform-
            // level writes (ACME cert renewal, signup's
            // `platform.root.*`). Customer log surface doesn't show
            // these.
        },
    }
}

fn hydrateWriteSetEnvelope(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(log_mod.LogRecord),
    env: apply_mod.Envelope,
    raft_seq: u64,
) !void {
    const payload = apply_mod.decodeWriteSetPayload(env.payload) catch return;
    if (payload.rs_bytes.len == 0) return;

    var parsed_list = tape_mod.parseReadsetList(allocator, payload.rs_bytes) catch return;
    defer parsed_list.deinit(allocator);

    for (parsed_list.blobs) |rs_blob| {
        const parsed = tape_mod.parseReadset(rs_blob) catch continue;
        const lh = parsed.log_header orelse continue;
        const record = try buildLogRecord(allocator, env.instance_id, raft_seq, lh, parsed.blobs);
        // On allocation failure inside buildLogRecord, errdefer in
        // the helper already freed the partial record's allocated
        // fields; the append below either succeeds or the outer
        // errdefer cleans up everything we did add.
        try out.append(allocator, record);
    }
}

/// Materialize a single `LogRecord` from a parsed `LogHeader` plus
/// the per-channel tape blobs. Strings are dup'd; channel blobs are
/// copied into freshly-allocated `[]u8` so the record owns its
/// memory and is safe to enqueue into `NodeLogBuffer`.
///
/// `request_body_bytes` + `activation_bytes` are NOT hydrated yet
/// — the BodyRefs in the trigger_payload + fetch_responses channels
/// would need a BlobStore fetch round-trip
/// (`docs/readset-replication-plan.md` Phase 5c-1). For now they're
/// left empty; replay still has the structural tape entries to
/// re-execute against, and the customer log surface shows method /
/// path / status / outcome without the inline body bytes.
fn buildLogRecord(
    allocator: std.mem.Allocator,
    instance_id: []const u8,
    raft_seq: u64,
    lh: log_mod.LogHeader,
    channel_blobs: [tape_mod.READSET_CHANNEL_COUNT][]const u8,
) !log_mod.LogRecord {
    const tenant_id = try allocator.dupe(u8, instance_id);
    errdefer allocator.free(tenant_id);
    const method = try allocator.dupe(u8, lh.method);
    errdefer allocator.free(method);
    const path = try allocator.dupe(u8, lh.path);
    errdefer allocator.free(path);
    const host = try allocator.dupe(u8, lh.host);
    errdefer allocator.free(host);
    // console + exception are handler stdout — not carried in the
    // LogHeader (slice 5a doc). Rebuilt records leave both empty;
    // customers recover console via tape replay if needed.
    const console: []u8 = &.{};
    const exception: []u8 = &.{};
    const correlation_id: []const u8 = if (lh.correlation_id.len > 0)
        try allocator.dupe(u8, lh.correlation_id)
    else
        "";
    errdefer if (correlation_id.len > 0) allocator.free(correlation_id);

    // Channel blobs aliasing into `parsed_list.blobs` aliases into
    // the raft entry bytes. The caller doesn't keep those alive past
    // this fn — dup each into the record.
    var tapes: log_mod.TapePayloads = .{};
    errdefer tapes.deinit(allocator);
    const kv_idx: usize = @intFromEnum(tape_mod.Channel.kv);
    const date_idx: usize = @intFromEnum(tape_mod.Channel.date);
    const math_idx: usize = @intFromEnum(tape_mod.Channel.math_random);
    const crypto_idx: usize = @intFromEnum(tape_mod.Channel.crypto_random);
    const module_idx: usize = @intFromEnum(tape_mod.Channel.module);
    const fetch_idx: usize = @intFromEnum(tape_mod.Channel.fetch_responses);
    const trigger_idx: usize = @intFromEnum(tape_mod.Channel.trigger_payload);
    tapes.kv_tape_bytes = try allocator.dupe(u8, channel_blobs[kv_idx]);
    tapes.date_tape_bytes = try allocator.dupe(u8, channel_blobs[date_idx]);
    tapes.math_random_tape_bytes = try allocator.dupe(u8, channel_blobs[math_idx]);
    tapes.crypto_random_tape_bytes = try allocator.dupe(u8, channel_blobs[crypto_idx]);
    tapes.module_tree_bytes = try allocator.dupe(u8, channel_blobs[module_idx]);
    tapes.fetch_responses_tape_bytes = try allocator.dupe(u8, channel_blobs[fetch_idx]);
    tapes.trigger_payload_tape_bytes = try allocator.dupe(u8, channel_blobs[trigger_idx]);

    return .{
        .tenant_id = tenant_id,
        .request_id = lh.request_id,
        .deployment_id = lh.deployment_id,
        .received_ns = 0,
        .duration_ns = lh.duration_ns,
        .method = method,
        .path = path,
        .host = host,
        .status = lh.status,
        .outcome = lh.outcome,
        .console = console,
        .exception = exception,
        .tapes = tapes,
        .correlation_id = correlation_id,
        .activation = lh.activation,
        .raft_seq = raft_seq,
    };
}

/// Process up to `WALKER_BATCH_CAP` raft entries starting at
/// `worker.upload_walker_idx + 1`, hydrating any per-request
/// LogRecords whose seq exceeds `worker.last_uploaded_seq` and
/// appending them to the worker's `log_buffer`. The next
/// `flushLogs` drains the buffer + advances the checkpoint, the
/// indexer's `INSERT OR IGNORE (tenant_id, request_id)` dedups any
/// record the original leader already pushed.
///
/// Gated to the leader's first worker (`log_worker_id == 0`) so
/// multiple workers on the same node don't multiply the dedupe
/// load. The walker is otherwise idempotent: each `worker.upload_walker_idx`
/// advance is monotonic, and re-running across a process restart
/// just rescans from `idx = 1` (cheap on small logs; bounded by
/// the per-tick cap).
pub fn walkAndUploadCatchup(worker: anytype) !void {
    // Only the leader pushes log records. Followers' flushLogs
    // early-returns on `!isLeader`, so any records the walker
    // appended there would just sit in the buffer until the worker
    // either becomes leader or shuts down (the buffer drops them
    // on shutdown).
    if (!worker.raft.isLeader()) return;
    // Single designated walker per node — `log_worker_id == 0` is
    // the first worker thread. Other workers on the same node
    // skip; the indexer's idempotency would absorb the duplicates
    // but the extra raft_log GETs + per-record alloc work is pure
    // waste.
    if (worker.log_worker_id != 0) return;

    const last_idx = worker.raft.raftLogLastIndex() catch |err| {
        std.log.warn(
            "rove-js upload walker: raftLogLastIndex failed: {s}",
            .{@errorName(err)},
        );
        return;
    };
    if (last_idx <= worker.upload_walker_idx) return;

    const allocator = worker.allocator;
    var processed: u64 = 0;
    var idx: u64 = worker.upload_walker_idx + 1;
    const stop_at: u64 = @min(last_idx, worker.upload_walker_idx + WALKER_BATCH_CAP);
    while (idx <= stop_at) : (idx += 1) {
        const entry_opt = worker.raft.getRaftEntry(idx) catch |err| {
            std.log.warn(
                "rove-js upload walker: getRaftEntry({d}) failed: {s}",
                .{ idx, @errorName(err) },
            );
            // Advance walker idx so we don't retry forever on the
            // same broken entry; the indexer's dedup absorbs the
            // single skipped record if a later catchup refers
            // back to this seq.
            worker.upload_walker_idx = idx;
            continue;
        };
        const entry = entry_opt orelse {
            // Entry truncated by snapshot or missing — skip.
            worker.upload_walker_idx = idx;
            continue;
        };
        defer allocator.free(entry.data);

        if (entry.data.len < 8) {
            worker.upload_walker_idx = idx;
            continue;
        }
        const seq = std.mem.readInt(u64, entry.data[0..8], .big);
        if (seq <= worker.last_uploaded_seq) {
            // Already covered by leader's local fast path
            // (`flushLogs` advanced `last_uploaded_seq` past this
            // entry's seq). No re-derivation needed.
            worker.upload_walker_idx = idx;
            continue;
        }

        const records = hydrateRecordsFromRaftEntry(allocator, entry.data) catch |err| {
            std.log.warn(
                "rove-js upload walker: hydrate idx={d} seq={d} failed: {s}",
                .{ idx, seq, @errorName(err) },
            );
            worker.upload_walker_idx = idx;
            continue;
        };
        defer allocator.free(records);

        for (records) |r| {
            worker.log_buffer.append(r) catch |err| {
                std.log.warn(
                    "rove-js upload walker: log_buffer.append idx={d} seq={d} tenant={s}: {s}",
                    .{ idx, seq, r.tenant_id, @errorName(err) },
                );
                // Free the unappended record; the previously-
                // appended ones in this batch are owned by the
                // buffer now.
                var rr = r;
                rr.deinit(allocator);
                continue;
            };
        }
        worker.upload_walker_idx = idx;
        processed += 1;
    }
    if (processed > 0) {
        // Wake the flusher so the new records land in S3 promptly,
        // matching the dispatch-path's priority-flush convention.
        worker.flusher_wake.set();
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn buildSampleReadset(allocator: std.mem.Allocator, lh: log_mod.LogHeader) ![]u8 {
    var rs = tape_mod.Readset.init(allocator, 1_700_000_000_000_000_000, 0xAB);
    defer rs.deinit();
    try rs.kv.appendKv(.get, "k", "v", .ok);
    try rs.module.appendModule("./h.js", "a" ** 64);
    return rs.serialize(allocator, lh);
}

test "hydrate: single type-0 entry → one LogRecord" {
    const a = testing.allocator;
    const lh: log_mod.LogHeader = .{
        .request_id = 0xCAFE,
        .deployment_id = 42,
        .duration_ns = 1234,
        .status = 200,
        .outcome = .ok,
        .activation = .inbound,
        .method = "GET",
        .path = "/x",
        .host = "acme.example",
        .correlation_id = "corr-1",
    };
    const rs_blob = try buildSampleReadset(a, lh);
    defer a.free(rs_blob);
    const rs_list = try tape_mod.encodeReadsetList(a, &.{rs_blob});
    defer a.free(rs_list);

    // Build a writeset envelope carrying the readset list.
    const env = try apply_mod.encodeWriteSetEnvelope(a, "acme", "", rs_list);
    defer a.free(env);

    // Frame with [u64 raft_seq BE][env].
    const framed = try a.alloc(u8, 8 + env.len);
    defer a.free(framed);
    std.mem.writeInt(u64, framed[0..8], 17, .big);
    @memcpy(framed[8..], env);

    const records = try hydrateRecordsFromRaftEntry(a, framed);
    defer {
        for (records) |*r| {
            var rr = r.*;
            rr.deinit(a);
        }
        a.free(records);
    }
    try testing.expectEqual(@as(usize, 1), records.len);
    const r = records[0];
    try testing.expectEqualStrings("acme", r.tenant_id);
    try testing.expectEqual(@as(u64, 0xCAFE), r.request_id);
    try testing.expectEqual(@as(u64, 42), r.deployment_id);
    try testing.expectEqual(@as(u16, 200), r.status);
    try testing.expectEqual(log_mod.Outcome.ok, r.outcome);
    try testing.expectEqual(log_mod.ActivationSource.inbound, r.activation);
    try testing.expectEqualStrings("GET", r.method);
    try testing.expectEqualStrings("/x", r.path);
    try testing.expectEqualStrings("corr-1", r.correlation_id);
    try testing.expectEqual(@as(u64, 17), r.raft_seq);
    // Tape channels round-trip through the buffer (non-empty kv +
    // module channels).
    try testing.expect(r.tapes.kv_tape_bytes.len > 0);
    try testing.expect(r.tapes.module_tree_bytes.len > 0);
}

test "hydrate: multi envelope walks inner type-0s" {
    const a = testing.allocator;
    const lh_a: log_mod.LogHeader = .{
        .request_id = 1,
        .deployment_id = 9,
        .duration_ns = 100,
        .status = 200,
        .outcome = .ok,
        .activation = .inbound,
        .method = "POST",
        .path = "/api/a",
        .host = "",
        .correlation_id = "",
    };
    const lh_b: log_mod.LogHeader = .{
        .request_id = 2,
        .deployment_id = 9,
        .duration_ns = 200,
        .status = 201,
        .outcome = .ok,
        .activation = .inbound,
        .method = "POST",
        .path = "/api/b",
        .host = "",
        .correlation_id = "",
    };
    const rs_a = try buildSampleReadset(a, lh_a);
    defer a.free(rs_a);
    const rs_b = try buildSampleReadset(a, lh_b);
    defer a.free(rs_b);

    const list_a = try tape_mod.encodeReadsetList(a, &.{rs_a});
    defer a.free(list_a);
    const list_b = try tape_mod.encodeReadsetList(a, &.{rs_b});
    defer a.free(list_b);

    const inner_a = try apply_mod.encodeWriteSetEnvelope(a, "acme", "", list_a);
    defer a.free(inner_a);
    const inner_b = try apply_mod.encodeWriteSetEnvelope(a, "globex", "", list_b);
    defer a.free(inner_b);

    const wrapped = try apply_mod.encodeMultiEnvelope(a, &.{ inner_a, inner_b });
    defer a.free(wrapped);

    const framed = try a.alloc(u8, 8 + wrapped.len);
    defer a.free(framed);
    std.mem.writeInt(u64, framed[0..8], 999, .big);
    @memcpy(framed[8..], wrapped);

    const records = try hydrateRecordsFromRaftEntry(a, framed);
    defer {
        for (records) |*r| {
            var rr = r.*;
            rr.deinit(a);
        }
        a.free(records);
    }
    try testing.expectEqual(@as(usize, 2), records.len);
    try testing.expectEqualStrings("acme", records[0].tenant_id);
    try testing.expectEqualStrings("/api/a", records[0].path);
    try testing.expectEqual(@as(u64, 999), records[0].raft_seq);
    try testing.expectEqualStrings("globex", records[1].tenant_id);
    try testing.expectEqualStrings("/api/b", records[1].path);
    try testing.expectEqual(@as(u64, 999), records[1].raft_seq);
}

test "hydrate: type-0 with empty rs_bytes → no records" {
    const a = testing.allocator;
    const env = try apply_mod.encodeWriteSetEnvelope(a, "acme", "ws", "");
    defer a.free(env);
    const framed = try a.alloc(u8, 8 + env.len);
    defer a.free(framed);
    std.mem.writeInt(u64, framed[0..8], 5, .big);
    @memcpy(framed[8..], env);

    const records = try hydrateRecordsFromRaftEntry(a, framed);
    defer a.free(records);
    try testing.expectEqual(@as(usize, 0), records.len);
}

test "hydrate: type-2 root_writeset → no records" {
    const a = testing.allocator;
    const env = try apply_mod.encodeRootWriteSetEnvelope(a, "root ws");
    defer a.free(env);
    const framed = try a.alloc(u8, 8 + env.len);
    defer a.free(framed);
    std.mem.writeInt(u64, framed[0..8], 5, .big);
    @memcpy(framed[8..], env);

    const records = try hydrateRecordsFromRaftEntry(a, framed);
    defer a.free(records);
    try testing.expectEqual(@as(usize, 0), records.len);
}

test "hydrate: readset with null LogHeader → skipped" {
    const a = testing.allocator;
    // Build a readset blob with NO LogHeader (slice 5a null sentinel).
    var rs = tape_mod.Readset.init(a, 0, 0);
    defer rs.deinit();
    const rs_blob = try rs.serialize(a, null);
    defer a.free(rs_blob);
    const list = try tape_mod.encodeReadsetList(a, &.{rs_blob});
    defer a.free(list);
    const env = try apply_mod.encodeWriteSetEnvelope(a, "acme", "", list);
    defer a.free(env);
    const framed = try a.alloc(u8, 8 + env.len);
    defer a.free(framed);
    std.mem.writeInt(u64, framed[0..8], 3, .big);
    @memcpy(framed[8..], env);

    const records = try hydrateRecordsFromRaftEntry(a, framed);
    defer a.free(records);
    try testing.expectEqual(@as(usize, 0), records.len);
}

test "hydrate: malformed framed bytes → empty (no panic)" {
    const a = testing.allocator;
    const short: [4]u8 = .{ 0, 0, 0, 1 };
    const r1 = try hydrateRecordsFromRaftEntry(a, &short);
    defer a.free(r1);
    try testing.expectEqual(@as(usize, 0), r1.len);

    // 8-byte seq + garbage payload — should NOT panic.
    var framed: [16]u8 = undefined;
    @memset(&framed, 0xFF);
    std.mem.writeInt(u64, framed[0..8], 1, .big);
    const r2 = try hydrateRecordsFromRaftEntry(a, &framed);
    defer a.free(r2);
    try testing.expectEqual(@as(usize, 0), r2.len);
}
