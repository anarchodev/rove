//! Promotion-time LogRecord rebuild — recover request logs that die
//! in a leader's RAM when it crashes between propose and flush.
//!
//! The leader's `flushLogs` pipeline is best-effort early visibility:
//! it drains the in-memory `log_buffer` into an ndjson batch and PUTs
//! it to S3, unordered against raft commit. A leader that crashes
//! after proposing a writeset but before flushing loses those buffered
//! records from RAM — the followers hold the replicated raft entries
//! (KV state is safe), but no LogRecord ever reaches S3, so the
//! request vanishes from the customer's logs.
//!
//! This module derives LogRecords from raft entries on demand. Every
//! type-0 (`writeset`) / type-1 (`multi`) entry carries the dispatch's
//! readset as its `rs_bytes` section, and each readset blob carries a
//! trailing `LogHeader` (`src/tape/root.zig`) precisely so any node can
//! rebuild the customer LogRecord from the raft entry alone. A
//! freshly-promoted leader walks its group's entries from a durable
//! resume mark, hydrates the missing LogRecords, and appends them to
//! the normal `log_buffer` → `flushLogs` path.
//!
//! Idempotency: the log indexer's `(tenant_id, request_id)` INSERT OR
//! IGNORE makes a re-uploaded record (one the dead leader had in fact
//! already flushed) harmless — so the resume mark can safely lag.
//!
//! ## The durability boundary (`docs/architecture/deployment-and-logs.md`)
//!
//! The walker rebuilds only from raft entries, and a raft entry exists
//! iff a writeset committed. So the recoverable set is exactly the
//! requests that **persisted writes** — a read-only request (or a
//! writing request that crashed pre-quorum) leaves no entry and its log
//! is dropped on a pre-flush failover. That is the intended contract:
//! a request whose writes persist has a log record that survives
//! failover; read-only visibility is best-effort.
//!
//! ## Framing
//!
//! This module is framing-agnostic: callers hand it the raft entry's
//! `env_bytes` (the `[type][id_len][id][payload]` envelope, already
//! unwrapped from the consensus `EntryFrame`) plus the entry's `seq`.
//! The per-group promotion driver (`worker.zig`) owns the
//! `EntryFrame` decode + the raft-log walk.

const std = @import("std");
const apply_mod = @import("apply.zig");
const tape_mod = @import("rove-tape");
const log_mod = @import("rove-log");

/// Max raft entries a promotion catch-up processes per driver tick.
/// Bounds per-tick work so a fresh leader with a long backlog to
/// re-derive doesn't stall the pump (each entry read is a pump control
/// op). The next tick resumes where this one stopped.
pub const WALKER_BATCH_CAP: u64 = 256;

/// Decode a raft entry's envelope bytes into zero-or-more LogRecords.
/// `env_bytes` is the entry's envelope (post-`EntryFrame`); `raft_seq`
/// is the entry's proposer seq, stamped onto each rebuilt record for
/// the flush checkpoint's `max(record.raft_seq)`.
///
/// Returns an owned slice; each LogRecord owns its `[]const u8` fields
/// (caller `deinit`s each + frees the outer slice).
///
/// Skips entries / readset blobs that carry no per-request log record:
///   - type-0 with empty `rs_bytes` (non-handler producer: ACME,
///     secondary inners of a batched propose, root_writeset)
///   - a readset blob with no `LogHeader`
///   - type-2 `root_writeset` (no per-tenant id, no LogHeader)
///
/// Recurses into type-1 `multi` envelopes (walks every inner).
pub fn hydrateRecordsFromEnvelope(
    allocator: std.mem.Allocator,
    env_bytes: []const u8,
    raft_seq: u64,
) ![]log_mod.LogRecord {
    var records: std.ArrayListUnmanaged(log_mod.LogRecord) = .empty;
    errdefer {
        for (records.items) |*r| r.deinit(allocator);
        records.deinit(allocator);
    }

    // Walk every writeset envelope (top-level or unwrapped from a
    // multi) via the shared `apply_mod.forEachWriteSetEnvelope` tree
    // walker — root_writeset envelopes carry no per-request LogHeader
    // and are skipped there.
    const Visitor = struct {
        a: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(log_mod.LogRecord),
        raft_seq: u64,
        pub fn visitWriteSet(v: @This(), instance_id: []const u8, payload: []const u8) !void {
            try hydrateWriteSetEnvelope(v.a, v.out, instance_id, payload, v.raft_seq);
        }
    };
    try apply_mod.forEachWriteSetEnvelope(
        allocator,
        env_bytes,
        Visitor{ .a = allocator, .out = &records, .raft_seq = raft_seq },
    );
    return records.toOwnedSlice(allocator);
}

fn hydrateWriteSetEnvelope(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(log_mod.LogRecord),
    instance_id: []const u8,
    payload: []const u8,
    raft_seq: u64,
) !void {
    const ws_payload = apply_mod.decodeWriteSetPayload(payload) catch return;
    if (ws_payload.rs_bytes.len == 0) return;

    var parsed_list = tape_mod.parseReadsetList(allocator, ws_payload.rs_bytes) catch return;
    defer parsed_list.deinit(allocator);

    for (parsed_list.blobs) |rs_blob| {
        const parsed = tape_mod.parseReadset(rs_blob) catch continue;
        const lh = parsed.log_header orelse continue;
        const record = try buildLogRecord(
            allocator,
            instance_id,
            raft_seq,
            lh,
            parsed.seed,
            parsed.timestamp_ns,
            parsed.blobs,
        );
        // buildLogRecord's errdefer already freed a partial record on
        // failure; the append either succeeds or the caller's outer
        // errdefer cleans up everything already added.
        try out.append(allocator, record);
    }
}

/// Materialize one `LogRecord` from a parsed `LogHeader` + the
/// per-channel tape blobs. Strings + channel blobs are copied so the
/// record owns its memory and is safe to enqueue into `NodeLogBuffer`
/// (the source blobs alias the raft entry bytes, which the caller does
/// not keep alive past the walk).
///
/// `console` / `exception` are handler stdout — NOT carried in the
/// LogHeader (`src/log/root.zig`), so rebuilt records leave both empty;
/// the customer log line still shows method / path / status / outcome /
/// timing, and replay recovers console from the tape channels.
fn buildLogRecord(
    allocator: std.mem.Allocator,
    instance_id: []const u8,
    raft_seq: u64,
    lh: log_mod.LogHeader,
    seed: u64,
    timestamp_ns: i64,
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
    const console: []u8 = &.{};
    const exception: []u8 = &.{};
    const correlation_id: []const u8 = if (lh.correlation_id.len > 0)
        try allocator.dupe(u8, lh.correlation_id)
    else
        "";
    errdefer if (correlation_id.len > 0) allocator.free(correlation_id);

    var tapes: log_mod.TapePayloads = .{
        .seed = seed,
        .timestamp_ns = timestamp_ns,
    };
    errdefer tapes.deinit(allocator);
    const kv_idx: usize = @intFromEnum(tape_mod.Channel.kv);
    const module_idx: usize = @intFromEnum(tape_mod.Channel.module);
    const fetch_idx: usize = @intFromEnum(tape_mod.Channel.fetch_responses);
    const trigger_idx: usize = @intFromEnum(tape_mod.Channel.trigger_payload);
    const request_reads_idx: usize = @intFromEnum(tape_mod.Channel.request_reads);
    tapes.kv_tape_bytes = try allocator.dupe(u8, channel_blobs[kv_idx]);
    tapes.module_tree_bytes = try allocator.dupe(u8, channel_blobs[module_idx]);
    tapes.fetch_responses_tape_bytes = try allocator.dupe(u8, channel_blobs[fetch_idx]);
    tapes.trigger_payload_tape_bytes = try allocator.dupe(u8, channel_blobs[trigger_idx]);
    tapes.request_reads_tape_bytes = try allocator.dupe(u8, channel_blobs[request_reads_idx]);

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

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn buildSampleReadset(allocator: std.mem.Allocator, lh: log_mod.LogHeader) ![]u8 {
    var rs = tape_mod.Readset.init(allocator, 1_700_000_000_000_000_000, 0xAB);
    defer rs.deinit();
    try rs.kv.appendKv(.get, "k", "v", .ok);
    try rs.module.appendModule("./h.js", "a" ** 64);
    return rs.serialize(allocator, lh);
}

const sample_lh: log_mod.LogHeader = .{
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

fn freeRecords(a: std.mem.Allocator, records: []log_mod.LogRecord) void {
    for (records) |*r| {
        var rr = r.*;
        rr.deinit(a);
    }
    a.free(records);
}

test "hydrate: single type-0 envelope → one LogRecord" {
    const a = testing.allocator;
    const rs_blob = try buildSampleReadset(a, sample_lh);
    defer a.free(rs_blob);
    const rs_list = try tape_mod.encodeReadsetList(a, &.{rs_blob});
    defer a.free(rs_list);

    const env = try apply_mod.encodeWriteSetEnvelope(a, "acme", "", rs_list);
    defer a.free(env);

    const records = try hydrateRecordsFromEnvelope(a, env, 17);
    defer freeRecords(a, records);

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
    // kv + module channels carried through.
    try testing.expect(r.tapes.kv_tape_bytes.len > 0);
    try testing.expect(r.tapes.module_tree_bytes.len > 0);
}

test "hydrate: type-1 multi wrapping two writesets → two LogRecords" {
    const a = testing.allocator;

    const rs_blob = try buildSampleReadset(a, sample_lh);
    defer a.free(rs_blob);
    const rs_list = try tape_mod.encodeReadsetList(a, &.{rs_blob});
    defer a.free(rs_list);

    const env0 = try apply_mod.encodeWriteSetEnvelope(a, "acme", "", rs_list);
    defer a.free(env0);
    const env1 = try apply_mod.encodeWriteSetEnvelope(a, "beta", "", rs_list);
    defer a.free(env1);
    const multi = try apply_mod.encodeMultiEnvelope(a, &.{ env0, env1 });
    defer a.free(multi);

    const records = try hydrateRecordsFromEnvelope(a, multi, 99);
    defer freeRecords(a, records);

    try testing.expectEqual(@as(usize, 2), records.len);
    try testing.expectEqualStrings("acme", records[0].tenant_id);
    try testing.expectEqualStrings("beta", records[1].tenant_id);
    try testing.expectEqual(@as(u64, 99), records[0].raft_seq);
    try testing.expectEqual(@as(u64, 99), records[1].raft_seq);
}

test "hydrate: type-0 with empty rs_bytes → no records" {
    const a = testing.allocator;
    // A writeset envelope with an empty readset list (non-handler
    // producer — e.g. an ACME cert marker rides no LogHeader).
    const env = try apply_mod.encodeWriteSetEnvelope(a, "acme", "", "");
    defer a.free(env);

    const records = try hydrateRecordsFromEnvelope(a, env, 3);
    defer freeRecords(a, records);
    try testing.expectEqual(@as(usize, 0), records.len);
}

test "hydrate: root_writeset (type-2) is skipped" {
    const a = testing.allocator;
    const env = try apply_mod.encodeRootWriteSetEnvelope(a, "root-bytes");
    defer a.free(env);

    const records = try hydrateRecordsFromEnvelope(a, env, 5);
    defer freeRecords(a, records);
    try testing.expectEqual(@as(usize, 0), records.len);
}
