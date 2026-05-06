//! JSON encoder / decoder for the per-deployment manifest stored in
//! S3 at `tenants/{id}/deployments/{dep_id:020d}.json`. Phase 5.5(e)
//! F2-storage replaced the per-tenant `files.db` `deployment/{id}` rows
//! with these objects in a per-tenant `deployments/` BlobBackend.
//!
//! Wire shape (also the storage shape):
//!
//! ```json
//! {
//!   "v": 1,
//!   "deployment_id": 42,
//!   "entries": [
//!     {"path": "index.mjs",         "kind": "handler",
//!      "content_type": "",
//!      "hash":          "<source-sha256>",
//!      "bytecode_hash": "<bytecode-sha256>"},
//!     {"path": "_static/index.html","kind": "static",
//!      "content_type": "text/html; charset=utf-8",
//!      "hash":          "<content-sha256>"}
//!   ]
//! }
//! ```
//!
//! Notes on the schema:
//!
//! - `hash` is the source-blob hash (handlers) or content-blob hash
//!   (statics). Kept as the historical name `hash` so the dashboard's
//!   existing reader (`web/admin/api.js`) still matches.
//! - `bytecode_hash` is required for `handler` entries (worker fetches
//!   bytecode via this hash from the file-blobs BlobBackend) and
//!   omitted for `static` entries.
//! - `content_type` is the empty string for handlers (they're served
//!   via the JS dispatcher; the wire content-type comes from the
//!   handler's response object), and the manifest-stamped MIME for
//!   statics.
//! - `v: 1` is reserved for forward-compat. Decoder rejects anything
//!   that doesn't match.

const std = @import("std");
const root = @import("root.zig");

pub const VERSION: u32 = 1;

pub const Error = error{
    InvalidManifest,
    OutOfMemory,
};

/// In-memory manifest as the worker / files-server consume it after
/// parsing. Owns its `entries` slice + each entry's `path` and
/// `content_type` allocations. Mirrors `FileStore.Manifest` so callers
/// that already accept the binary-format struct can switch over.
pub const Manifest = struct {
    id: u64,
    entries: []root.FileStore.Entry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Manifest) void {
        for (self.entries) |e| {
            self.allocator.free(e.path);
            self.allocator.free(e.content_type);
        }
        self.allocator.free(self.entries);
        self.* = undefined;
    }
};

/// Encode `entries` (with deployment id `dep_id`) into a JSON object.
/// Returns owned bytes; caller frees. Doesn't allocate per-entry —
/// writes directly into the output buffer.
pub fn encode(
    allocator: std.mem.Allocator,
    dep_id: u64,
    entries: []const root.FileStore.Entry,
) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);

    try w.print("{{\"v\":{d},\"deployment_id\":{d},\"entries\":[", .{ VERSION, dep_id });
    for (entries, 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        const kind_str: []const u8 = if (e.kind == .handler) "handler" else "static";
        try w.writeAll("{\"path\":");
        try writeJsonString(&w, e.path);
        try w.print(",\"kind\":\"{s}\",\"content_type\":", .{kind_str});
        try writeJsonString(&w, e.content_type);
        try w.print(",\"hash\":\"{s}\"", .{e.source_hex});
        if (e.kind == .handler) {
            try w.print(",\"bytecode_hash\":\"{s}\"", .{e.bytecode_hex});
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    return buf.toOwnedSlice(allocator);
}

/// Parse the JSON manifest produced by `encode`. The deployment id is
/// taken from the JSON body (`deployment_id`) rather than from the
/// caller — keeping a single source of truth so a manifest moved /
/// renamed / mis-keyed surfaces as a clear mismatch.
///
/// Returns an owned `Manifest`; caller calls `deinit`.
pub fn decode(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error!Manifest {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{},
    ) catch return Error.InvalidManifest;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return Error.InvalidManifest,
    };

    const v_val = obj.get("v") orelse return Error.InvalidManifest;
    const v_num = switch (v_val) {
        .integer => |i| i,
        else => return Error.InvalidManifest,
    };
    if (v_num != @as(i64, @intCast(VERSION))) return Error.InvalidManifest;

    const id_val = obj.get("deployment_id") orelse return Error.InvalidManifest;
    const id_i: i64 = switch (id_val) {
        .integer => |i| i,
        else => return Error.InvalidManifest,
    };
    if (id_i < 0) return Error.InvalidManifest;
    const id: u64 = @intCast(id_i);

    const entries_val = obj.get("entries") orelse return Error.InvalidManifest;
    const arr = switch (entries_val) {
        .array => |a| a,
        else => return Error.InvalidManifest,
    };

    var entries = allocator.alloc(root.FileStore.Entry, arr.items.len) catch
        return Error.OutOfMemory;
    var filled: usize = 0;
    errdefer {
        for (entries[0..filled]) |e| {
            allocator.free(e.path);
            allocator.free(e.content_type);
        }
        allocator.free(entries);
    }

    for (arr.items) |item| {
        const e_obj = switch (item) {
            .object => |o| o,
            else => return Error.InvalidManifest,
        };

        const path_val = e_obj.get("path") orelse return Error.InvalidManifest;
        const path_str = switch (path_val) {
            .string => |s| s,
            else => return Error.InvalidManifest,
        };
        const path_copy = allocator.dupe(u8, path_str) catch return Error.OutOfMemory;
        errdefer allocator.free(path_copy);

        const kind_val = e_obj.get("kind") orelse return Error.InvalidManifest;
        const kind_str = switch (kind_val) {
            .string => |s| s,
            else => return Error.InvalidManifest,
        };
        const kind: root.Kind = if (std.mem.eql(u8, kind_str, "handler"))
            .handler
        else if (std.mem.eql(u8, kind_str, "static"))
            .static
        else
            return Error.InvalidManifest;

        const ct_val = e_obj.get("content_type") orelse return Error.InvalidManifest;
        const ct_str = switch (ct_val) {
            .string => |s| s,
            else => return Error.InvalidManifest,
        };
        const ct_copy = allocator.dupe(u8, ct_str) catch return Error.OutOfMemory;
        errdefer allocator.free(ct_copy);

        const hash_val = e_obj.get("hash") orelse return Error.InvalidManifest;
        const hash_str = switch (hash_val) {
            .string => |s| s,
            else => return Error.InvalidManifest,
        };
        if (hash_str.len != root.HASH_HEX_LEN) return Error.InvalidManifest;
        var src_hex: [root.HASH_HEX_LEN]u8 = undefined;
        @memcpy(&src_hex, hash_str[0..root.HASH_HEX_LEN]);

        var bc_hex: [root.HASH_HEX_LEN]u8 = @splat(0);
        if (kind == .handler) {
            const bc_val = e_obj.get("bytecode_hash") orelse return Error.InvalidManifest;
            const bc_str = switch (bc_val) {
                .string => |s| s,
                else => return Error.InvalidManifest,
            };
            if (bc_str.len != root.HASH_HEX_LEN) return Error.InvalidManifest;
            @memcpy(&bc_hex, bc_str[0..root.HASH_HEX_LEN]);
        }

        entries[filled] = .{
            .path = path_copy,
            .kind = kind,
            .content_type = ct_copy,
            .source_hex = src_hex,
            .bytecode_hex = bc_hex,
        };
        filled += 1;
    }

    return .{ .id = id, .entries = entries, .allocator = allocator };
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |b| {
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                try w.print("\\u{x:0>4}", .{b});
            },
            else => try w.writeByte(b),
        }
    }
    try w.writeByte('"');
}

/// `{dep_id:020d}.json` — the canonical key under each tenant's
/// `deployments/` BlobBackend prefix. Stable lexicographic order ↔
/// chronological deploy order (cheap LIST for history).
pub fn manifestKey(buf: *[25]u8, dep_id: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>20}.json", .{dep_id}) catch unreachable;
}

const testing = std.testing;

test "encode + decode round-trip" {
    var entries = [_]root.FileStore.Entry{
        .{
            .path = @constCast("index.mjs"),
            .kind = .handler,
            .content_type = @constCast(""),
            .source_hex = @splat('a'),
            .bytecode_hex = @splat('b'),
        },
        .{
            .path = @constCast("_static/x.html"),
            .kind = .static,
            .content_type = @constCast("text/html; charset=utf-8"),
            .source_hex = @splat('c'),
            .bytecode_hex = @splat(0),
        },
    };

    const bytes = try encode(testing.allocator, 7, &entries);
    defer testing.allocator.free(bytes);

    var m = try decode(testing.allocator, bytes);
    defer m.deinit();

    try testing.expectEqual(@as(u64, 7), m.id);
    try testing.expectEqual(@as(usize, 2), m.entries.len);
    try testing.expectEqualStrings("index.mjs", m.entries[0].path);
    try testing.expectEqual(root.Kind.handler, m.entries[0].kind);
    try testing.expectEqualSlices(u8, &@as([root.HASH_HEX_LEN]u8, @splat('a')), &m.entries[0].source_hex);
    try testing.expectEqualSlices(u8, &@as([root.HASH_HEX_LEN]u8, @splat('b')), &m.entries[0].bytecode_hex);
    try testing.expectEqualStrings("_static/x.html", m.entries[1].path);
    try testing.expectEqual(root.Kind.static, m.entries[1].kind);
    try testing.expectEqualStrings("text/html; charset=utf-8", m.entries[1].content_type);
}

test "decode rejects wrong version" {
    const bytes = "{\"v\":99,\"deployment_id\":1,\"entries\":[]}";
    try testing.expectError(Error.InvalidManifest, decode(testing.allocator, bytes));
}

test "decode rejects missing bytecode_hash on handler" {
    const bytes = "{\"v\":1,\"deployment_id\":1,\"entries\":[" ++
        "{\"path\":\"x.mjs\",\"kind\":\"handler\",\"content_type\":\"\"," ++
        "\"hash\":\"" ++ ("a" ** 64) ++ "\"}]}";
    try testing.expectError(Error.InvalidManifest, decode(testing.allocator, bytes));
}

test "decode allows missing bytecode_hash on static" {
    const bytes = "{\"v\":1,\"deployment_id\":1,\"entries\":[" ++
        "{\"path\":\"_static/x.html\",\"kind\":\"static\",\"content_type\":\"text/html\"," ++
        "\"hash\":\"" ++ ("c" ** 64) ++ "\"}]}";
    var m = try decode(testing.allocator, bytes);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 1), m.entries.len);
    try testing.expectEqual(root.Kind.static, m.entries[0].kind);
}

test "manifestKey produces zero-padded {N:020d}.json" {
    var buf: [25]u8 = undefined;
    try testing.expectEqualStrings("00000000000000000001.json", manifestKey(&buf, 1));
    try testing.expectEqualStrings("00000000000000004242.json", manifestKey(&buf, 4242));
}
