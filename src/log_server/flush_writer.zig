//! Flush writer — turns a batch of `LogRecord`s into the on-bucket
//! shape (`_logs/{node}/{batch}.ndjson` with the index sidecar
//! embedded as a fixed-size header prefix) and PUTs it into a
//! `BatchStore` as a single object.
//!
//! Wire format (Phase 5.5(a-3)):
//!
//!   [4 bytes]  sidecar_size_le  — u32, little-endian
//!   [N bytes]  sidecar JSON     — same shape as the old `.idx.json`
//!                                 minus `ndjson_key` (now self-
//!                                 referential)
//!   [M bytes]  concatenated raw-deflate frames
//!                                — one self-terminating frame per
//!                                  record, BFINAL=1; record offsets
//!                                  in the sidecar are file-relative
//!                                  (i.e. include `4 + sidecar_size`)
//!
//! One PUT per flush replaces the previous ndjson + .idx.json pair.
//! The orphan-on-crash story is bounded by the BatchStore's atomic
//! semantics — partial PUTs surface as 4xx/5xx and the in-memory
//! records are dropped per the lossy-on-failure semantics in
//! `docs/logs-plan.md`.
//!
//! The writer is allocator-agnostic + stateless; one call per flush.

const std = @import("std");
const log_mod = @import("rove-log");
const batch_store_mod = @import("batch_store.zig");
const sidecar = @import("sidecar.zig");
const c = @cImport({
    @cInclude("zlib.h");
});

pub const Error = error{
    InvalidRecord,
    Io,
    OutOfMemory,
    WriteFailed,
};

/// Build + PUT a batch as a single embedded-sidecar object.
/// `records` are NOT consumed (caller deinits); their `[]const u8`
/// fields must outlive this call.
///
/// Object layout: `[u32 LE sidecar_size][sidecar JSON][raw-deflate frames]`.
/// One PUT to `_logs/{node_id}/{batch_id}.ndjson`; no separate sidecar
/// object. Record offsets in the sidecar JSON are frame-relative
/// (i.e. into the deflate-frames region only); the indexer adds
/// `4 + sidecar_size` when populating `log_index` so /show's stored
/// offset is file-relative.
///
/// `node_id_hex` is the raft node id zero-padded to u32 hex (8 chars).
/// `flush_unix_ns` is nanos-since-epoch at flush time and is the PRIMARY
/// sort component of the batch_id (see below) — the indexer's per-node
/// catch-up cursor is a lexical `start-after` over these keys, so the
/// key MUST sort in flush order or a late batch is skipped forever.
/// Caller frees the returned `[]u8` (the batch's S3 key, e.g.
/// `_logs/{node_hex}/{batch_id}.ndjson`). Returns null if the batch
/// was empty. The key is the same value just PUT into `store` — the
/// caller can push it to log-server (`/v1/_internal/batch-pushed`)
/// so the LOCAL node's indexer fetches it directly; the poll path is
/// still the cross-node completeness guarantee (log-servers don't share
/// the index), which is exactly why the key must be poll-sound.
pub fn writeBatch(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    node_id_hex: []const u8,
    records: []const log_mod.LogRecord,
    flush_unix_ns: i64,
) Error!?[]u8 {
    if (records.len == 0) return null;

    // Per `docs/logs-plan.md` §2.2: records ordered by ascending
    // received_ns. The buffer is appended in dispatch order, which
    // IS receive order for a single worker thread, so sorting is
    // normally a no-op. Sort defensively in case a future code path
    // appends out of order.
    const sorted = allocator.dupe(log_mod.LogRecord, records) catch return Error.OutOfMemory;
    defer allocator.free(sorted);
    std.mem.sort(log_mod.LogRecord, sorted, {}, lessByReceivedNs);

    // ── frames region (concatenated raw-deflate frames) ──────────
    var frames = std.ArrayList(u8).empty;
    defer frames.deinit(allocator);

    const idx_records = allocator.alloc(sidecar.Record, sorted.len) catch
        return Error.OutOfMemory;
    defer allocator.free(idx_records);

    // Flatten all records' tags into one borrowed `sidecar.Tag` buffer
    // so each sidecar Record can point at its sub-slice (the sidecar
    // Tag type mirrors `log_mod.Tag` but is a distinct type; the bytes
    // are borrowed from the LogRecord and live until `sidecar.encode`
    // below). One alloc instead of per-record.
    var total_tags: usize = 0;
    for (sorted) |r| total_tags += r.tags.len;
    const all_tags = allocator.alloc(sidecar.Tag, total_tags) catch return Error.OutOfMemory;
    defer allocator.free(all_tags);
    var tag_cursor: usize = 0;

    // Per-record JSON scratch buffer. Reused across records;
    // grows to the largest record's size and stays there for the
    // lifetime of writeBatch.
    var json_scratch: std.ArrayList(u8) = .empty;
    defer json_scratch.deinit(allocator);

    // Reusable deflate stream — initialized once, reset between
    // records, freed at the end. Per-record `deflateInit2_` +
    // `deflateEnd` was ~35% of leader CPU under sharded write
    // load (most of it `__memset_avx2` zeroing the ~270 KB state
    // each call); `deflateReset` reuses that allocation.
    var deflater: DeflateStream = .{};
    try deflater.init();
    defer deflater.deinit();

    for (sorted, 0..) |r, i| {
        json_scratch.clearRetainingCapacity();
        encodeRecordJson(allocator, &json_scratch, &r) catch return Error.OutOfMemory;
        const offset = frames.items.len;
        try deflater.appendFrame(allocator, &frames, json_scratch.items);
        const length = frames.items.len - offset;
        const tags_start = tag_cursor;
        for (r.tags) |t| {
            all_tags[tag_cursor] = .{ .key = t.key, .value = t.value };
            tag_cursor += 1;
        }
        idx_records[i] = .{
            .tenant_id = r.tenant_id,
            .request_id = r.request_id,
            .received_ns = r.received_ns,
            .duration_ns = r.duration_ns,
            .method = r.method,
            .path = r.path,
            .host = r.host,
            .status = r.status,
            .outcome = outcomeName(r.outcome),
            .deployment_id = r.deployment_id,
            .correlation_id = r.correlation_id,
            .tags = all_tags[tags_start..tag_cursor],
            .offset = offset,
            .length = @intCast(length),
        };
    }

    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(frames.items, &sha, .{});
    const sha_hex = bytesToHex(allocator, sha[0..]) catch return Error.OutOfMemory;
    defer allocator.free(sha_hex);

    // batch_id = `{flush_unix_ns:020d}-{first_request_id:020d}`.
    //
    // FLUSH TIME FIRST — this is load-bearing for the indexer's poll
    // path. Batches are per-NODE (multi-tenant) but `request_id` is
    // per-TENANT (`_log/next_request_seq`), so a request-id-first key
    // is NOT monotonic across tenants: a brand-new tenant's first
    // request (id 1) sorts before a busy tenant's id 84, and the
    // per-node lexical `start-after` cursor that has advanced past 84
    // would skip the late id-1 batch forever (it never re-LISTs keys
    // below the cursor). The flusher runs sequentially per node, so the
    // wall-clock ns at flush time IS monotonic across all tenants and
    // survives process restarts (unlike a volatile in-RAM counter), so
    // a later flush always sorts after an earlier one. `request_id` is
    // a deterministic tiebreaker for the (practically impossible)
    // same-ns case. Cast to u64 — `{d:0>N}` prepends `+` for signed
    // positive ints, which would corrupt the lexical key; negative
    // timestamps are nonsensical (nanos since 1970).
    const flush_ns_u: u64 = @intCast(@max(flush_unix_ns, 0));
    const batch_id = std.fmt.allocPrint(
        allocator,
        "{d:0>20}-{d:0>20}",
        .{ flush_ns_u, sorted[0].request_id },
    ) catch return Error.OutOfMemory;
    defer allocator.free(batch_id);

    const obj_key = std.fmt.allocPrint(
        allocator,
        "_logs/{s}/{s}.ndjson",
        .{ node_id_hex, batch_id },
    ) catch return Error.OutOfMemory;
    // NOT freed on the happy path — returned to caller. Caller owns
    // it from here.
    errdefer allocator.free(obj_key);

    const idx_file = sidecar.IdxFile{
        .node_id = node_id_hex,
        .batch_id = batch_id,
        .ndjson_size = frames.items.len,
        .ndjson_sha256 = sha_hex,
        .first_received_ns = sorted[0].received_ns,
        .last_received_ns = sorted[sorted.len - 1].received_ns,
        .records = idx_records,
    };
    const sidecar_bytes = sidecar.encode(allocator, &idx_file) catch return Error.OutOfMemory;
    defer allocator.free(sidecar_bytes);

    // Final object: [u32 LE sidecar_size][sidecar JSON][frames].
    const sidecar_size = std.math.cast(u32, sidecar_bytes.len) orelse return Error.WriteFailed;
    const total_len = 4 + sidecar_bytes.len + frames.items.len;
    const obj = allocator.alloc(u8, total_len) catch return Error.OutOfMemory;
    defer allocator.free(obj);
    std.mem.writeInt(u32, obj[0..4], sidecar_size, .little);
    @memcpy(obj[4 .. 4 + sidecar_bytes.len], sidecar_bytes);
    @memcpy(obj[4 + sidecar_bytes.len ..], frames.items);

    store.put(obj_key, obj) catch return Error.Io;
    return obj_key;
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

fn activationName(a: log_mod.ActivationSource) []const u8 {
    return switch (a) {
        .inbound => "inbound",
        .send_callback => "send_callback",
        .timer => "timer",
        .disconnect => "disconnect",
        .kv_wake => "kv_wake",
        .wake_batch => "wake_batch",
        .subscription_fire => "subscription_fire",
        .fetch_chunk => "fetch_chunk",
        .durable_wake => "durable_wake",
        .ws_message => "ws_message",
        .inbound_headers => "inbound_headers",
        .inbound_chunk => "inbound_chunk",
    };
}

/// Emit one record as a single JSON object (no trailing newline —
/// the per-record deflate framing replaces ndjson line framing).
/// Schema mirrors what `log_server/thread.zig`'s `writeRecordJson`
/// produces, plus the request_id rendered as a u64 integer.
fn encodeRecordJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    r: *const log_mod.LogRecord,
) !void {
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const w = &aw.writer;
    try w.writeAll("{\"tenant_id\":");
    try writeJsonString(w, r.tenant_id);
    // Customer-visible ids are the opaque prefixed form (§7.5); the
    // dashboard fetches this record JSON verbatim via `/show`. Internal
    // u64s stay in the sidecar/index. Prefix+hex is alnum — no escaping.
    var rid_buf: [log_mod.PREFIXED_ID_BUF]u8 = undefined;
    var dep_buf: [log_mod.PREFIXED_ID_BUF]u8 = undefined;
    const rid = log_mod.formatPrefixedId(&rid_buf, log_mod.REQUEST_ID_PREFIX, r.request_id);
    const dep = log_mod.formatPrefixedId(&dep_buf, log_mod.DEPLOYMENT_ID_PREFIX, r.deployment_id);
    try w.print(
        ",\"request_id\":\"{s}\",\"deployment_id\":\"{s}\",\"received_ns\":{d},\"duration_ns\":{d},\"status\":{d},\"outcome\":",
        .{ rid, dep, r.received_ns, r.duration_ns, r.status },
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
    try w.writeAll(",\"correlation_id\":");
    try writeJsonString(w, r.correlation_id);
    try w.writeAll(",\"tags\":");
    try writeTags(w, r.tags);
    try w.writeAll(",\"activation\":");
    try writeJsonString(w, activationName(r.activation));
    try w.writeAll(",\"tapes\":");
    try writeTapePayloads(allocator, w, &r.tapes);
    try w.writeAll("}");
}

/// Reusable raw-deflate stream. The zlib state allocation (~270 KB
/// for `windowBits=15`) lives for the lifetime of the stream; each
/// `appendFrame` resets the state and emits a self-terminating
/// frame. Concatenating multiple frames in one buffer is fine
/// because the sidecar's `(offset, length)` per record bounds each
/// Range GET to exactly one frame.
///
/// Uses libz directly — Zig 0.15.x stdlib's `flate.Compress.drain`
/// has `@panic("TODO")` in the tokenization path and only works on
/// inputs smaller than the lookahead window. Real log-batch records
/// (with inline base64 tape bytes) are well above that.
const DeflateStream = struct {
    z: c.z_stream = std.mem.zeroes(c.z_stream),

    /// Init in-place. zlib stores a back-pointer to the `z_stream`
    /// inside its internal `state`, so the `z_stream` address must
    /// be stable from `init` through `deinit` — returning by value
    /// would invalidate that pointer when the caller moves the
    /// returned struct.
    fn init(self: *DeflateStream) Error!void {
        self.z = std.mem.zeroes(c.z_stream);
        // windowBits = -15 selects raw deflate (no zlib / gzip
        // header or trailer). Level 1 = fastest compression.
        if (c.deflateInit2_(
            &self.z,
            1,
            c.Z_DEFLATED,
            -15,
            8,
            c.Z_DEFAULT_STRATEGY,
            c.zlibVersion(),
            @sizeOf(c.z_stream),
        ) != c.Z_OK) return Error.Io;
    }

    fn deinit(self: *DeflateStream) void {
        _ = c.deflateEnd(&self.z);
    }

    fn appendFrame(
        self: *DeflateStream,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        src: []const u8,
    ) !void {
        // `deflateReset` clears stream-position counters and frees
        // any leftover dynamic-header state from the previous
        // frame WITHOUT reallocating the ~270 KB internal buffers.
        if (c.deflateReset(&self.z) != c.Z_OK) return Error.Io;

        self.z.next_in = @constCast(src.ptr);
        self.z.avail_in = @intCast(src.len);

        // Worst-case bound: src + 5 bytes per 16 KB block + 6 bytes
        // overhead. zlib's `deflateBound` computes it for us.
        const upper_bound: usize = c.deflateBound(&self.z, @intCast(src.len));
        const start_len = out.items.len;
        try out.ensureUnusedCapacity(allocator, upper_bound);
        out.items.len = start_len + upper_bound;
        self.z.next_out = out.items[start_len..].ptr;
        self.z.avail_out = @intCast(upper_bound);

        const rc = c.deflate(&self.z, c.Z_FINISH);
        if (rc != c.Z_STREAM_END) return Error.Io;

        const written = upper_bound - self.z.avail_out;
        out.items.len = start_len + written;
    }
};

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

/// Emit user tags as a JSON object `{"k":"v",...}` (`{}` when empty).
fn writeTags(w: *std.Io.Writer, tags: []const log_mod.Tag) !void {
    try w.writeByte('{');
    for (tags, 0..) |t, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonString(w, t.key);
        try w.writeByte(':');
        try writeJsonString(w, t.value);
    }
    try w.writeByte('}');
}

/// Emit `tapes` as `{name_b64: "<base64>", ...}`. Empty channels
/// emit `null` (not the empty string) so consumers can distinguish
/// "no capture" from "captured zero bytes." `*_body_truncated`
/// flags are only emitted alongside the body fields, matching the
/// pre-refactor schema.
fn writeTapePayloads(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    t: *const log_mod.TapePayloads,
) !void {
    try w.writeByte('{');
    // `docs/primitive-gaps.md` §9 + fold-in: per-request scalars
    // used at capture time. Replay reseeds the per-context PRNG
    // with `seed` and pins `Date.now()` to
    // `@divTrunc(timestamp_ns, ns_per_ms)` so `Math.random` /
    // `crypto.*` / `Date.now()` / `new Date()` reproduce the
    // captured sequences — no per-draw or per-call tape entries.
    //
    // Both emitted as JSON strings so the consumer can BigInt()
    // them without precision loss: production values derive from
    // wall-clock ns (~1.7e18) which overflows JS's f64 Number at
    // 2^53. JSON.parse → Number truncates the low bits; reading a
    // string + BigInt() is precise.
    try w.print("\"seed\":\"{d}\",\"timestamp_ns\":\"{d}\"", .{ t.seed, t.timestamp_ns });
    // The JS engine version that ran the request (`format-versioning-audit.md`
    // §4). A small u16 — safe as a plain JSON number. The replay driver reads
    // it to fetch the matching engine WASM (a no-op today: one engine, so the
    // bundled engine always matches; the stamp keeps old requests attributable).
    try w.print(",\"js_engine_version\":{d}", .{t.js_engine_version});
    try writeBytesField(allocator, w, "kv_tape_b64", t.kv_tape_bytes, false);
    try writeBytesField(allocator, w, "module_tree_b64", t.module_tree_bytes, false);
    try writeBytesField(allocator, w, "fetch_responses_tape_b64", t.fetch_responses_tape_bytes, false);
    try writeBytesField(allocator, w, "trigger_payload_tape_b64", t.trigger_payload_tape_bytes, false);
    try writeBytesField(allocator, w, "request_reads_tape_b64", t.request_reads_tape_bytes, false);
    try writeBytesField(allocator, w, "request_body_b64", t.request_body_bytes, false);
    try w.writeAll(",\"request_body_truncated\":");
    try w.writeAll(if (t.request_body_truncated) "true" else "false");
    try writeBytesField(allocator, w, "activation_bytes_b64", t.activation_bytes, false);
    try w.writeAll(",\"activation_bytes_truncated\":");
    try w.writeAll(if (t.activation_bytes_truncated) "true" else "false");
    // Resolved export ({to} / onFetch*) — a plain name, emitted only when set
    // (replay uses it verbatim so an overridden callback replays faithfully).
    if (t.export_name.len != 0) {
        try w.writeAll(",\"export\":");
        try writeJsonString(w, t.export_name);
    }
    // Response body is intentionally NOT serialized — replay
    // re-produces it deterministically; storing it would just
    // bloat every S3 batch PUT.
    try w.writeByte('}');
}

fn writeBytesField(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    name: []const u8,
    bytes: []const u8,
    first: bool,
) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(name);
    try w.writeAll("\":");
    if (bytes.len == 0) {
        try w.writeAll("null");
        return;
    }
    const enc_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const buf = try allocator.alloc(u8, enc_len);
    defer allocator.free(buf);
    const out = std.base64.standard.Encoder.encode(buf, bytes);
    try w.writeByte('"');
    try w.writeAll(out);
    try w.writeByte('"');
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


fn makeRecord(allocator: std.mem.Allocator, id: u64, path: []const u8) !log_mod.LogRecord {
    return .{
        .tenant_id = try allocator.dupe(u8, "acme"),
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
        // Non-zero engine stamp so the served-JSON assertion below proves
        // the replay-critical field is emitted (§4).
        .tapes = .{ .js_engine_version = 1 },
    };
}

test "writeBatch emits one object with embedded sidecar + frames" {
    const a = testing.allocator;
    const m = try batch_store_mod.MemoryBatchStore.init(a);
    defer m.deinit();
    const store = m.batchStore();

    var r0 = try makeRecord(a, 1, "/a");
    defer r0.deinit(a);
    var r1 = try makeRecord(a, 2, "/b");
    defer r1.deinit(a);
    const records = [_]log_mod.LogRecord{ r0, r1 };

    // Flush-time-first key: `_logs/{node}/{flush_ns:020}-{first_req_id:020}`.
    const returned_key = (try writeBatch(a, store, "00000001", &records, 1730764800000000000)).?;
    defer a.free(returned_key);
    try testing.expectEqualStrings(
        "_logs/00000001/01730764800000000000-00000000000000000001.ndjson",
        returned_key,
    );

    // Single object exists at the .ndjson key — no separate .idx.json.
    const obj_key = "_logs/00000001/01730764800000000000-00000000000000000001.ndjson";
    const obj = try store.get(obj_key, a);
    defer a.free(obj);

    // Confirm there's no separate sidecar object.
    const list = try store.list("", "", 16, a);
    defer batch_store_mod.freeListResult(a, list);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings(obj_key, list[0]);

    // Header layout: [u32 LE sidecar_size][sidecar JSON][frames].
    try testing.expect(obj.len >= 4);
    const sidecar_size = std.mem.readInt(u32, obj[0..4], .little);
    try testing.expect(4 + sidecar_size <= obj.len);

    var idx = try sidecar.parse(a, obj[4 .. 4 + sidecar_size]);
    defer idx.deinit(a);

    try testing.expectEqualStrings("acme", idx.records[0].tenant_id);
    try testing.expectEqualStrings("00000001", idx.node_id);
    try testing.expectEqual(@as(usize, 2), idx.records.len);
    try testing.expectEqual(@as(u64, 1), idx.records[0].request_id);
    try testing.expectEqual(@as(u64, 2), idx.records[1].request_id);

    const frames = obj[4 + sidecar_size ..];
    try testing.expectEqual(idx.ndjson_size, frames.len);

    // Range-read using the sidecar offsets returns one self-contained
    // deflate frame per record. Decompress the first one and check
    // the JSON shape — proves the wire format round-trips end-to-end.
    {
        const frame = frames[idx.records[0].offset .. idx.records[0].offset + idx.records[0].length];
        var z: c.z_stream = std.mem.zeroes(c.z_stream);
        try testing.expectEqual(@as(c_int, c.Z_OK), c.inflateInit2_(&z, -15, c.zlibVersion(), @sizeOf(c.z_stream)));
        defer _ = c.inflateEnd(&z);
        z.next_in = @constCast(frame.ptr);
        z.avail_in = @intCast(frame.len);
        var out_buf: [4096]u8 = undefined;
        z.next_out = &out_buf;
        z.avail_out = out_buf.len;
        const rc = c.inflate(&z, c.Z_FINISH);
        try testing.expectEqual(@as(c_int, c.Z_STREAM_END), rc);
        const written = out_buf.len - z.avail_out;
        const json = out_buf[0..written];
        try testing.expect(std.mem.startsWith(u8, json, "{\"tenant_id\":"));
        try testing.expect(std.mem.endsWith(u8, json, "}"));
        // Customer-visible ids are the opaque prefixed form (§7.5), not
        // bare integers; the replay-critical engine stamp is present (§4).
        try testing.expect(std.mem.indexOf(u8, json, "\"request_id\":\"req_0000000000000001\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"deployment_id\":\"dep_0000000000000001\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"js_engine_version\":1") != null);
    }

    // Sha256 in sidecar matches the frames-region bytes.
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(frames, &sha, .{});
    const expected_hex = try bytesToHex(a, sha[0..]);
    defer a.free(expected_hex);
    try testing.expectEqualStrings(expected_hex, idx.ndjson_sha256);
}

test "writeBatch key sorts by flush time, not request_id (poll-cursor monotonicity)" {
    const a = testing.allocator;
    const m = try batch_store_mod.MemoryBatchStore.init(a);
    defer m.deinit();
    const store = m.batchStore();

    // A busy tenant flushes request_id 84 first…
    var hi = try makeRecord(a, 84, "/hi");
    defer hi.deinit(a);
    const k_busy = (try writeBatch(a, store, "00000001", &.{hi}, 1000)).?;
    defer a.free(k_busy);

    // …then a brand-new tenant flushes request_id 1 LATER (higher ns).
    var lo = try makeRecord(a, 1, "/lo");
    defer lo.deinit(a);
    const k_new = (try writeBatch(a, store, "00000001", &.{lo}, 2000)).?;
    defer a.free(k_new);

    // The later flush MUST sort after the earlier one despite its far
    // lower request_id — otherwise the per-node `start-after` cursor that
    // advanced past k_busy would never re-LIST k_new and the new tenant's
    // record would be invisible forever. This is the regression the
    // flush-time-first key prevents.
    try testing.expect(std.mem.lessThan(u8, k_busy, k_new));
}

test "writeBatch with empty records is a no-op (no PUTs)" {
    const a = testing.allocator;
    const m = try batch_store_mod.MemoryBatchStore.init(a);
    defer m.deinit();
    const store = m.batchStore();

    const k = try writeBatch(a, store, "00000001", &.{}, 0);
    try testing.expect(k == null);

    const list = try store.list("", "", 16, a);
    defer batch_store_mod.freeListResult(a, list);
    try testing.expectEqual(@as(usize, 0), list.len);
}

test "writeBatch sorts records by received_ns before encoding" {
    const a = testing.allocator;
    const m = try batch_store_mod.MemoryBatchStore.init(a);
    defer m.deinit();
    const store = m.batchStore();

    // Submit records in reverse order of received_ns.
    var hi = try makeRecord(a, 5, "/late");
    hi.received_ns = 9000;
    defer hi.deinit(a);
    var lo = try makeRecord(a, 6, "/early");
    lo.received_ns = 1000;
    defer lo.deinit(a);
    const records = [_]log_mod.LogRecord{ hi, lo };

    const k = (try writeBatch(a, store, "00000001", &records, 1730764800000000000)).?;
    defer a.free(k);

    // batch_id = `{flush_ns:020}-{first_request_id:020}`; the request_id
    // tiebreaker is the first record AFTER the received_ns sort → request_id=6.
    const obj = try store.get("_logs/00000001/01730764800000000000-00000000000000000006.ndjson", a);
    defer a.free(obj);
    const sidecar_size = std.mem.readInt(u32, obj[0..4], .little);
    var idx = try sidecar.parse(a, obj[4 .. 4 + sidecar_size]);
    defer idx.deinit(a);

    try testing.expectEqual(@as(i64, 1000), idx.first_received_ns);
    try testing.expectEqual(@as(i64, 9000), idx.last_received_ns);
    try testing.expectEqual(@as(u64, 6), idx.records[0].request_id);
    try testing.expectEqual(@as(u64, 5), idx.records[1].request_id);
}
