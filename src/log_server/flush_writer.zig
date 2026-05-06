//! Flush writer — turns a batch of `LogRecord`s into the on-bucket
//! shape (`{tenant}/{node}/{batch}.ndjson` payload + matching
//! `.idx.json` sidecar) and PUTs both into a `BatchStore` (Phase 5.5
//! a, step 3).
//!
//! Used from the worker's `flushLogs` when `log.backend = s3`. The
//! ordering matters per `docs/logs-plan.md` §3.2: payload first,
//! sidecar second. A crash between the two leaves an orphan
//! `.ndjson` with no sidecar — invisible to the indexer (which only
//! keys off sidecars) and reapable by a future janitor pass.
//!
//! The writer is allocator-agnostic + stateless; one call per flush.
//! No retries here — failed PUTs surface as errors that the worker
//! logs and continues past, with the records already drained from
//! the buffer (lost). Matches the stated lossy-on-node-failure
//! semantics in `docs/logs-plan.md`.

const std = @import("std");
const log_mod = @import("rove-log");
const batch_store_mod = @import("batch_store.zig");
const sidecar = @import("sidecar.zig");

pub const Error = error{
    InvalidRecord,
    Io,
    OutOfMemory,
};

/// Build + PUT a batch's `.ndjson` payload + `.idx.json` sidecar.
/// `records` are NOT consumed (caller deinits); their `[]const u8`
/// fields must outlive this call.
///
/// `tenant_id` and `node_id` go into the keys; per the plan,
/// `node_id` is the raft node id zero-padded to u32 hex (8 chars).
/// `flush_unix_ms` is millis-since-epoch at flush time, used to
/// disambiguate batch_ids if a node's request_id allocator ever
/// resets.
pub fn writeBatch(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    tenant_id: []const u8,
    node_id_hex: []const u8,
    records: []const log_mod.LogRecord,
    flush_unix_ms: i64,
) Error!void {
    if (records.len == 0) return;

    // Per §2.3: records ordered by ascending received_ns. The buffer
    // is appended in dispatch order, which IS receive order for a
    // single worker thread, so sorting is normally a no-op. Sort
    // defensively in case future code path appends out of order.
    const sorted = allocator.dupe(log_mod.LogRecord, records) catch return Error.OutOfMemory;
    defer allocator.free(sorted);
    std.mem.sort(log_mod.LogRecord, sorted, {}, lessByReceivedNs);

    // ── ndjson payload ────────────────────────────────────────────
    var ndjson = std.ArrayList(u8).empty;
    defer ndjson.deinit(allocator);

    const idx_records = allocator.alloc(sidecar.Record, sorted.len) catch
        return Error.OutOfMemory;
    defer allocator.free(idx_records);

    for (sorted, 0..) |r, i| {
        const offset = ndjson.items.len;
        encodeRecordLine(allocator, &ndjson, &r) catch return Error.OutOfMemory;
        const length = ndjson.items.len - offset;
        idx_records[i] = .{
            .request_id = r.request_id,
            .received_ns = r.received_ns,
            .duration_ns = r.duration_ns,
            .method = r.method,
            .path = r.path,
            .host = r.host,
            .status = r.status,
            .outcome = outcomeName(r.outcome),
            .deployment_id = r.deployment_id,
            .offset = offset,
            .length = @intCast(length),
        };
    }

    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(ndjson.items, &sha, .{});
    const sha_hex = bytesToHex(allocator, sha[0..]) catch return Error.OutOfMemory;
    defer allocator.free(sha_hex);

    // batch_id = `{first_request_id:020d}-{flush_unix_ms:013d}`.
    // Cast flush_unix_ms to u64 — Zig's `{d:0>13}` formatter prepends
    // a `+` sign for signed positive integers when width-specified,
    // which would corrupt the lexical-sort key. Negative timestamps
    // are nonsensical here (millis since 1970).
    const flush_ms_u: u64 = @intCast(@max(flush_unix_ms, 0));
    const batch_id = std.fmt.allocPrint(
        allocator,
        "{d:0>20}-{d:0>13}",
        .{ sorted[0].request_id, flush_ms_u },
    ) catch return Error.OutOfMemory;
    defer allocator.free(batch_id);

    const ndjson_key = std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}.ndjson",
        .{ tenant_id, node_id_hex, batch_id },
    ) catch return Error.OutOfMemory;
    defer allocator.free(ndjson_key);

    const idx_key = std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}.idx.json",
        .{ tenant_id, node_id_hex, batch_id },
    ) catch return Error.OutOfMemory;
    defer allocator.free(idx_key);

    const idx_file = sidecar.IdxFile{
        .tenant_id = tenant_id,
        .node_id = node_id_hex,
        .batch_id = batch_id,
        .ndjson_key = ndjson_key,
        .ndjson_size = ndjson.items.len,
        .ndjson_sha256 = sha_hex,
        .first_received_ns = sorted[0].received_ns,
        .last_received_ns = sorted[sorted.len - 1].received_ns,
        .records = idx_records,
    };
    const sidecar_bytes = sidecar.encode(allocator, &idx_file) catch return Error.OutOfMemory;
    defer allocator.free(sidecar_bytes);

    // PUT order: payload first. An orphan ndjson is invisible (the
    // indexer only iterates `.idx.json`); an orphan sidecar pointing
    // at a missing payload would 404 every /show — the case we
    // mustn't ship.
    store.put(ndjson_key, ndjson.items) catch return Error.Io;
    store.put(idx_key, sidecar_bytes) catch return Error.Io;
}

fn lessByReceivedNs(_: void, a: log_mod.LogRecord, b: log_mod.LogRecord) bool {
    return a.received_ns < b.received_ns;
}

fn outcomeName(o: log_mod.Outcome) []const u8 {
    return switch (o) {
        .ok => "ok",
        .fault => "fault",
        .timeout => "timeout",
        .handler_error => "handler_error",
        .kv_error => "kv_error",
        .no_deployment => "no_deployment",
        .unknown_domain => "unknown_domain",
    };
}

/// Emit one record as a single JSON object followed by `\n` (ndjson).
/// Schema mirrors what `log_server/thread.zig`'s `writeRecordJson`
/// produces, plus the request_id rendered as a u64 integer (not the
/// hex string — readable + matches the index column type).
fn encodeRecordLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    r: *const log_mod.LogRecord,
) !void {
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const w = &aw.writer;
    try w.print(
        "{{\"request_id\":{d},\"deployment_id\":{d},\"received_ns\":{d},\"duration_ns\":{d},\"status\":{d},\"outcome\":",
        .{ r.request_id, r.deployment_id, r.received_ns, r.duration_ns, r.status },
    );
    try writeJsonString(w, outcomeName(r.outcome));
    try w.writeAll(",\"method\":");
    try writeJsonString(w, r.method);
    try w.writeAll(",\"path\":");
    try writeJsonString(w, r.path);
    try w.writeAll(",\"host\":");
    try writeJsonString(w, r.host);
    try w.writeAll(",\"console\":");
    try writeJsonString(w, r.console);
    try w.writeAll(",\"exception\":");
    try writeJsonString(w, r.exception);
    try w.writeAll(",\"tape_refs\":");
    try writeTapeRefs(w, &r.tape_refs);
    try w.writeAll("}\n");
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |b| switch (b) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{b}),
        else => try w.writeByte(b),
    };
    try w.writeByte('"');
}

fn writeTapeRefs(w: *std.Io.Writer, t: *const log_mod.TapeRefs) !void {
    try w.writeByte('{');
    try writeRefField(w, "kv_tape_hex", t.kv_tape_hex, true);
    try writeRefField(w, "date_tape_hex", t.date_tape_hex, false);
    try writeRefField(w, "math_random_tape_hex", t.math_random_tape_hex, false);
    try writeRefField(w, "crypto_random_tape_hex", t.crypto_random_tape_hex, false);
    try writeRefField(w, "module_tree_hex", t.module_tree_hex, false);
    try writeRefField(w, "request_body_hex", t.request_body_hex, false);
    try w.writeAll(",\"request_body_truncated\":");
    try w.writeAll(if (t.request_body_truncated) "true" else "false");
    try writeRefField(w, "response_body_hex", t.response_body_hex, false);
    try w.writeAll(",\"response_body_truncated\":");
    try w.writeAll(if (t.response_body_truncated) "true" else "false");
    try w.writeByte('}');
}

fn writeRefField(
    w: *std.Io.Writer,
    name: []const u8,
    value: ?[64]u8,
    first: bool,
) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(name);
    try w.writeAll("\":");
    if (value) |v| {
        try w.writeByte('"');
        try w.writeAll(&v);
        try w.writeByte('"');
    } else {
        try w.writeAll("null");
    }
}

fn bytesToHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const hex_chars = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn tempDir(allocator: std.mem.Allocator, tag: []const u8) ![]u8 {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const path = try std.fmt.allocPrint(allocator, "/tmp/rove-fw-{s}-{x}", .{ tag, seed });
    std.fs.cwd().deleteTree(path) catch {};
    try std.fs.cwd().makePath(path);
    return path;
}

fn makeRecord(allocator: std.mem.Allocator, id: u64, path: []const u8) !log_mod.LogRecord {
    return .{
        .request_id = id,
        .deployment_id = 1,
        .received_ns = @intCast(id * 1000),
        .duration_ns = 100,
        .method = try allocator.dupe(u8, "GET"),
        .path = try allocator.dupe(u8, path),
        .host = try allocator.dupe(u8, "h.test"),
        .status = 200,
        .outcome = .ok,
        .console = try allocator.dupe(u8, ""),
        .exception = try allocator.dupe(u8, ""),
    };
}

test "writeBatch puts ndjson + sidecar with correct offsets" {
    const a = testing.allocator;
    const root = try tempDir(a, "wb");
    defer {
        std.fs.cwd().deleteTree(root) catch {};
        a.free(root);
    }
    const fs = try batch_store_mod.FilesystemBatchStore.init(a, root);
    defer fs.deinit();
    const store = fs.batchStore();

    var r0 = try makeRecord(a, 1, "/a");
    defer r0.deinit(a);
    var r1 = try makeRecord(a, 2, "/b");
    defer r1.deinit(a);
    const records = [_]log_mod.LogRecord{ r0, r1 };

    try writeBatch(a, store, "acme", "00000001", &records, 1730764800000);

    // Sidecar present + parses.
    const sidecar_bytes = try store.get("acme/00000001/00000000000000000001-1730764800000.idx.json", a);
    defer a.free(sidecar_bytes);
    var idx = try sidecar.parse(a, sidecar_bytes);
    defer idx.deinit(a);

    try testing.expectEqualStrings("acme", idx.tenant_id);
    try testing.expectEqualStrings("00000001", idx.node_id);
    try testing.expectEqual(@as(usize, 2), idx.records.len);
    try testing.expectEqual(@as(u64, 1), idx.records[0].request_id);
    try testing.expectEqual(@as(u64, 2), idx.records[1].request_id);

    // Offsets line up with the ndjson layout.
    const ndjson = try store.get("acme/00000001/00000000000000000001-1730764800000.ndjson", a);
    defer a.free(ndjson);
    try testing.expectEqual(idx.ndjson_size, ndjson.len);

    // Range-read using the sidecar offsets returns the same bytes
    // for each record line.
    for (idx.records) |rec| {
        const slice = ndjson[rec.offset .. rec.offset + rec.length];
        // Last byte is '\n' (ndjson framing).
        try testing.expectEqual(@as(u8, '\n'), slice[slice.len - 1]);
    }

    // Sha256 in sidecar matches actual payload.
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(ndjson, &sha, .{});
    const expected_hex = try bytesToHex(a, sha[0..]);
    defer a.free(expected_hex);
    try testing.expectEqualStrings(expected_hex, idx.ndjson_sha256);
}

test "writeBatch with empty records is a no-op (no PUTs)" {
    const a = testing.allocator;
    const root = try tempDir(a, "empty");
    defer {
        std.fs.cwd().deleteTree(root) catch {};
        a.free(root);
    }
    const fs = try batch_store_mod.FilesystemBatchStore.init(a, root);
    defer fs.deinit();
    const store = fs.batchStore();

    try writeBatch(a, store, "acme", "00000001", &.{}, 0);

    const list = try store.list("", "", 16, a);
    defer batch_store_mod.freeListResult(a, list);
    try testing.expectEqual(@as(usize, 0), list.len);
}

test "writeBatch sorts records by received_ns before encoding" {
    const a = testing.allocator;
    const root = try tempDir(a, "sort");
    defer {
        std.fs.cwd().deleteTree(root) catch {};
        a.free(root);
    }
    const fs = try batch_store_mod.FilesystemBatchStore.init(a, root);
    defer fs.deinit();
    const store = fs.batchStore();

    // Submit records in reverse order of received_ns.
    var hi = try makeRecord(a, 5, "/late");
    hi.received_ns = 9000;
    defer hi.deinit(a);
    var lo = try makeRecord(a, 6, "/early");
    lo.received_ns = 1000;
    defer lo.deinit(a);
    const records = [_]log_mod.LogRecord{ hi, lo };

    try writeBatch(a, store, "acme", "00000001", &records, 1730764800000);

    // batch_id = first_request_id (after sort) → record at received=1000 → request_id=6.
    const sidecar_bytes = try store.get("acme/00000001/00000000000000000006-1730764800000.idx.json", a);
    defer a.free(sidecar_bytes);
    var idx = try sidecar.parse(a, sidecar_bytes);
    defer idx.deinit(a);

    try testing.expectEqual(@as(i64, 1000), idx.first_received_ns);
    try testing.expectEqual(@as(i64, 9000), idx.last_received_ns);
    try testing.expectEqual(@as(u64, 6), idx.records[0].request_id);
    try testing.expectEqual(@as(u64, 5), idx.records[1].request_id);
}
