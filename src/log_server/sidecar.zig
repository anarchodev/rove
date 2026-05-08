//! Sidecar / ndjson wire format for the S3-direct logs path
//! (Phase 5.5 a). Worker writes a `.ndjson.gz` payload + an `.idx.json`
//! sidecar per flush; log-server reads the sidecar to populate
//! `log_index.db` without touching the payload until a click-through.
//!
//! See `docs/logs-plan.md` §2.3 for the schema. v1 reads + writes a
//! flat JSON object with a per-record `records` array. v2 will switch
//! to a more compact format if profiling says JSON parse cost matters
//! at scale; deferred per §6.2.

const std = @import("std");

/// Wire-format version. Bumped when the on-disk schema changes
/// in a backward-incompatible way; readers reject unknown versions.
pub const VERSION: u32 = 1;

/// One indexed row in a sidecar. Mirrors what `log_index.db`'s
/// `log_index` table stores per record. Owned strings are duplicated
/// on parse so the caller can free the source bytes immediately.
///
/// Phase 5.5(a-2) interleaved layout: each row carries its own
/// `tenant_id` so a single per-node sidecar can index records
/// belonging to many tenants. The indexer demuxes on this when
/// populating `log_index.db`.
pub const Record = struct {
    tenant_id: []const u8,
    request_id: u64,
    received_ns: i64,
    duration_ns: i64,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    status: u16,
    /// One of `ok | fault | timeout | handler_error | kv_error |
    /// no_deployment | unknown_domain` (mirrors `log_mod.Outcome`).
    /// Stored as a string in JSON so the sidecar is human-readable.
    outcome: []const u8,
    deployment_id: u64,
    /// Byte offset into the (decompressed) `.ndjson` payload where
    /// this record's line begins. The dashboard issues a ranged GET
    /// `[offset, offset+length)` to fetch one record without
    /// materializing the whole batch.
    offset: u64,
    length: u32,

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.method);
        allocator.free(self.path);
        allocator.free(self.host);
        allocator.free(self.outcome);
        self.* = undefined;
    }
};

/// Top-level sidecar shape. `records` is ordered by ascending
/// `received_ns`, matching the order of lines in the payload.
/// Records may belong to many tenants; each carries its `tenant_id`.
pub const IdxFile = struct {
    node_id: []const u8,
    batch_id: []const u8,
    /// S3 / batch-store key the payload lives at. Encoded so the
    /// `_logs/{node_id}/{batch_id}.ndjson` lookup doesn't need the
    /// indexer to recompose it.
    ndjson_key: []const u8,
    ndjson_size: u64,
    /// Hex-encoded SHA-256 of the payload bytes. Lets the indexer
    /// detect partial-upload corruption before inserting.
    ndjson_sha256: []const u8,
    first_received_ns: i64,
    last_received_ns: i64,
    records: []Record,

    pub fn deinit(self: *IdxFile, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.batch_id);
        allocator.free(self.ndjson_key);
        allocator.free(self.ndjson_sha256);
        for (self.records) |*r| r.deinit(allocator);
        allocator.free(self.records);
        self.* = undefined;
    }
};

pub const ParseError = error{
    InvalidJson,
    InvalidVersion,
    MissingField,
    OutOfMemory,
};

/// Parse a sidecar JSON blob into a `IdxFile`. Returned strings are
/// allocator-owned; caller deinits.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) ParseError!IdxFile {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch return ParseError.InvalidJson;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return ParseError.InvalidJson,
    };

    const v: i64 = switch (obj.get("v") orelse return ParseError.MissingField) {
        .integer => |i| i,
        else => return ParseError.InvalidVersion,
    };
    if (v != @as(i64, VERSION)) return ParseError.InvalidVersion;

    var out: IdxFile = undefined;
    out.node_id = try dupeStr(allocator, obj, "node_id");
    errdefer allocator.free(out.node_id);
    out.batch_id = try dupeStr(allocator, obj, "batch_id");
    errdefer allocator.free(out.batch_id);
    out.ndjson_key = try dupeStr(allocator, obj, "ndjson_key");
    errdefer allocator.free(out.ndjson_key);
    out.ndjson_size = try getInt(obj, "ndjson_size");
    out.ndjson_sha256 = try dupeStr(allocator, obj, "ndjson_sha256");
    errdefer allocator.free(out.ndjson_sha256);
    out.first_received_ns = @intCast(try getInt(obj, "first_received_ns"));
    out.last_received_ns = @intCast(try getInt(obj, "last_received_ns"));

    const records_val = obj.get("records") orelse return ParseError.MissingField;
    const records_arr = switch (records_val) {
        .array => |a| a,
        else => return ParseError.InvalidJson,
    };

    out.records = allocator.alloc(Record, records_arr.items.len) catch
        return ParseError.OutOfMemory;
    var filled: usize = 0;
    errdefer {
        for (out.records[0..filled]) |*r| r.deinit(allocator);
        allocator.free(out.records);
    }
    for (records_arr.items) |item| {
        const ro = switch (item) {
            .object => |o| o,
            else => return ParseError.InvalidJson,
        };
        out.records[filled] = .{
            .tenant_id = try dupeStr(allocator, ro, "tenant_id"),
            .request_id = try getInt(ro, "request_id"),
            .received_ns = @intCast(try getInt(ro, "received_ns")),
            .duration_ns = @intCast(try getInt(ro, "duration_ns")),
            .method = try dupeStr(allocator, ro, "method"),
            .path = try dupeStr(allocator, ro, "path"),
            .host = try dupeStr(allocator, ro, "host"),
            .status = @intCast(try getInt(ro, "status")),
            .outcome = try dupeStr(allocator, ro, "outcome"),
            .deployment_id = try getInt(ro, "deployment_id"),
            .offset = try getInt(ro, "offset"),
            .length = @intCast(try getInt(ro, "length")),
        };
        filled += 1;
    }
    return out;
}

/// Serialize an `IdxFile` back to JSON bytes. Caller frees the result.
pub fn encode(allocator: std.mem.Allocator, idx: *const IdxFile) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
    const w = &aw.writer;

    try w.writeAll("{\"v\":1,\"node_id\":");
    try writeJsonString(w, idx.node_id);
    try w.writeAll(",\"batch_id\":");
    try writeJsonString(w, idx.batch_id);
    try w.writeAll(",\"ndjson_key\":");
    try writeJsonString(w, idx.ndjson_key);
    try w.print(",\"ndjson_size\":{d}", .{idx.ndjson_size});
    try w.writeAll(",\"ndjson_sha256\":");
    try writeJsonString(w, idx.ndjson_sha256);
    try w.print(",\"first_received_ns\":{d},\"last_received_ns\":{d}", .{
        idx.first_received_ns,
        idx.last_received_ns,
    });
    try w.writeAll(",\"records\":[");
    for (idx.records, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"tenant_id\":");
        try writeJsonString(w, r.tenant_id);
        try w.print(",\"request_id\":{d},\"received_ns\":{d},\"duration_ns\":{d},\"method\":", .{
            r.request_id,
            r.received_ns,
            r.duration_ns,
        });
        try writeJsonString(w, r.method);
        try w.writeAll(",\"path\":");
        try writeJsonString(w, r.path);
        try w.writeAll(",\"host\":");
        try writeJsonString(w, r.host);
        try w.print(",\"status\":{d},\"outcome\":", .{r.status});
        try writeJsonString(w, r.outcome);
        try w.print(",\"deployment_id\":{d},\"offset\":{d},\"length\":{d}}}", .{
            r.deployment_id,
            r.offset,
            r.length,
        });
    }
    try w.writeAll("]}");
    return aw.toOwnedSlice();
}

fn dupeStr(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    name: []const u8,
) ParseError![]u8 {
    const v = obj.get(name) orelse return ParseError.MissingField;
    const s = switch (v) {
        .string => |x| x,
        else => return ParseError.InvalidJson,
    };
    return allocator.dupe(u8, s) catch ParseError.OutOfMemory;
}

fn getInt(obj: std.json.ObjectMap, name: []const u8) ParseError!u64 {
    const v = obj.get(name) orelse return ParseError.MissingField;
    return switch (v) {
        .integer => |i| @intCast(i),
        else => ParseError.InvalidJson,
    };
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

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "encode → parse round-trip" {
    const a = testing.allocator;
    var records = [_]Record{
        .{
            .tenant_id = "acme",
            .request_id = 1,
            .received_ns = 1_000_000_000,
            .duration_ns = 3_000_000,
            .method = "GET",
            .path = "/api/foo",
            .host = "acme.test",
            .status = 200,
            .outcome = "ok",
            .deployment_id = 7,
            .offset = 0,
            .length = 412,
        },
        .{
            .tenant_id = "globex",
            .request_id = 2,
            .received_ns = 1_000_001_000,
            .duration_ns = 4_000_000,
            .method = "POST",
            .path = "/users",
            .host = "globex.test",
            .status = 500,
            .outcome = "handler_error",
            .deployment_id = 7,
            .offset = 412,
            .length = 380,
        },
    };
    const idx = IdxFile{
        .node_id = "00000001",
        .batch_id = "00000000000000000001-0001730764800000",
        .ndjson_key = "_logs/00000001/00000000000000000001-0001730764800000.ndjson",
        .ndjson_size = 84321,
        .ndjson_sha256 = "deadbeef",
        .first_received_ns = 1_000_000_000,
        .last_received_ns = 1_000_001_000,
        .records = &records,
    };
    const bytes = try encode(a, &idx);
    defer a.free(bytes);

    var parsed = try parse(a, bytes);
    defer parsed.deinit(a);

    try testing.expectEqualStrings("00000001", parsed.node_id);
    try testing.expectEqual(@as(usize, 2), parsed.records.len);
    try testing.expectEqualStrings("acme", parsed.records[0].tenant_id);
    try testing.expectEqualStrings("globex", parsed.records[1].tenant_id);
    try testing.expectEqual(@as(u64, 1), parsed.records[0].request_id);
    try testing.expectEqualStrings("/api/foo", parsed.records[0].path);
    try testing.expectEqualStrings("handler_error", parsed.records[1].outcome);
    try testing.expectEqual(@as(u32, 380), parsed.records[1].length);
}

test "parse rejects wrong version" {
    const a = testing.allocator;
    try testing.expectError(ParseError.InvalidVersion, parse(a, "{\"v\":99}"));
}

test "parse rejects malformed JSON" {
    const a = testing.allocator;
    try testing.expectError(ParseError.InvalidJson, parse(a, "not json at all"));
}

test "parse rejects missing required fields" {
    const a = testing.allocator;
    try testing.expectError(ParseError.MissingField, parse(a, "{\"v\":1}"));
}
