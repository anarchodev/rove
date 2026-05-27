//! Deploy-time `_config/` file → kv mirror.
//!
//! Walks a deployment's manifest for paths matching
//! `_config/{...}.json`, fetches each blob from the per-tenant
//! file-blobs backend, and stages writes to the customer's app.db at
//! `_config/{path_without_.json}`. Stale rows present in kv but not
//! in the new manifest are staged for deletion so the file tree is
//! the authoritative source.
//!
//! Wired into the release POST (worker_dispatch.handleRelease): the
//! mirror runs in the same TrackedTxn + WriteSet that flips
//! `_deploy/current`, so config and release pointer commit atomically
//! locally and replicate together via raft envelope 0.
//!
//! Customers cannot write `_config/*` from handlers — the prefix is
//! reserved (see reserved.zig). Handlers read via `kv.get("_config/...")`.
//! Libraries that read config wrap the lookup in `lib.fromConfig(name)`
//! (see oauth.js, sessions.js).

const std = @import("std");
const kv_mod = @import("raft-kv");
const blob_mod = @import("rove-blob");
const files_mod = @import("rove-files");
const manifest_json = files_mod.manifest_json;

const CONFIG_PREFIX = "_config/";
const JSON_SUFFIX = ".json";

/// Maximum bytes for a single `_config/*.json` file. Matches the
/// files-server upload cap (per-file 64 KB), so a config file
/// that uploaded successfully always mirrors successfully — but
/// stating it explicitly here means a future upload-cap bump
/// doesn't silently inflate per-tenant raft envelope sizes.
/// Real-world configs are <1 KB; the headroom is for jwks caches,
/// large allow-lists, etc.
pub const MAX_CONFIG_BYTES: usize = 64 * 1024;

pub const Error = error{
    Blob,
    Kv,
    ConfigTooLarge,
    OutOfMemory,
};

pub const Stats = struct {
    put_count: usize = 0,
    delete_count: usize = 0,
};

/// Stage put/delete operations for `_config/**/*.json` entries in
/// `manifest` against `kv`. Caller commits the txn and proposes the
/// writeset to raft.
///
/// `file_blobs` is the per-tenant file-blobs BlobStore (vtable form;
/// caller obtains via `BlobBackend.openPerTenant(..., "file-blobs")`
/// then `blobStore()`).
pub fn mirrorConfigToKv(
    allocator: std.mem.Allocator,
    manifest: manifest_json.Manifest,
    file_blobs: blob_mod.BlobStore,
    kv: *kv_mod.KvStore,
    txn: *kv_mod.TrackedTxn,
    writeset: *kv_mod.WriteSet,
) Error!Stats {
    var stats: Stats = .{};

    // Build the set of kv keys this manifest WILL produce so we can
    // diff against existing rows.
    var wanted: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = wanted.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        wanted.deinit(allocator);
    }

    // Pass 1 — PUT every config file from the manifest.
    for (manifest.entries) |entry| {
        const kv_key_opt = mapPathToKey(allocator, entry.path) catch return Error.OutOfMemory;
        const kv_key = kv_key_opt orelse continue;
        // Only static blobs are config; a handler under `_config/`
        // would be a category error but skip rather than reject so
        // a misnamed file doesn't break the deploy.
        if (entry.kind != .static) {
            allocator.free(kv_key);
            continue;
        }

        const bytes = file_blobs.get(&entry.source_hex, allocator) catch {
            allocator.free(kv_key);
            return Error.Blob;
        };
        defer allocator.free(bytes);

        if (bytes.len > MAX_CONFIG_BYTES) {
            std.log.warn(
                "config_mirror: {s} is {d} bytes, exceeds {d}-byte cap",
                .{ entry.path, bytes.len, MAX_CONFIG_BYTES },
            );
            allocator.free(kv_key);
            return Error.ConfigTooLarge;
        }

        txn.put(kv_key, bytes) catch {
            allocator.free(kv_key);
            return Error.Kv;
        };
        writeset.addPut(kv_key, bytes) catch {
            allocator.free(kv_key);
            return Error.OutOfMemory;
        };
        wanted.put(allocator, kv_key, {}) catch {
            allocator.free(kv_key);
            return Error.OutOfMemory;
        };
        stats.put_count += 1;
    }

    // Pass 2 — DELETE existing `_config/` rows the new manifest
    // doesn't claim. Snapshot the keys first (rather than delete
    // during iteration) so we don't fight the cursor.
    var stale: std.ArrayList([]u8) = .empty;
    defer {
        for (stale.items) |k| allocator.free(k);
        stale.deinit(allocator);
    }

    var cursor: []const u8 = "";
    var cursor_buf: ?[]u8 = null;
    defer if (cursor_buf) |b| allocator.free(b);

    while (true) {
        var range = kv.prefix(CONFIG_PREFIX, cursor, 256) catch return Error.Kv;
        defer range.deinit();
        if (range.entries.len == 0) break;

        for (range.entries) |row| {
            if (!wanted.contains(row.key)) {
                const owned = allocator.dupe(u8, row.key) catch return Error.OutOfMemory;
                stale.append(allocator, owned) catch {
                    allocator.free(owned);
                    return Error.OutOfMemory;
                };
            }
        }

        if (range.entries.len < 256) break;
        const last_key = range.entries[range.entries.len - 1].key;
        if (cursor_buf) |b| allocator.free(b);
        cursor_buf = allocator.dupe(u8, last_key) catch return Error.OutOfMemory;
        cursor = cursor_buf.?;
    }

    for (stale.items) |key| {
        txn.delete(key) catch return Error.Kv;
        writeset.addDelete(key) catch return Error.OutOfMemory;
        stats.delete_count += 1;
    }

    return stats;
}

/// Map a manifest path to a kv key, or null if the path isn't a
/// config file. `_config/oauth/google.json` → `_config/oauth/google`.
/// Files under `_config/` without `.json` suffix are skipped (allows
/// READMEs / other docs to live in the directory without becoming
/// config rows).
fn mapPathToKey(allocator: std.mem.Allocator, path: []const u8) error{OutOfMemory}!?[]u8 {
    if (!std.mem.startsWith(u8, path, CONFIG_PREFIX)) return null;
    if (!std.mem.endsWith(u8, path, JSON_SUFFIX)) return null;
    const trimmed = path[0 .. path.len - JSON_SUFFIX.len];
    return try allocator.dupe(u8, trimmed);
}

// ── Tests ──

const testing = std.testing;

/// Tiny in-memory BlobStore for tests — keyed by hex string.
const FakeBlobStore = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged([]u8) = .empty,

    fn deinit(self: *FakeBlobStore) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    fn put(self: *FakeBlobStore, key: []const u8, bytes: []const u8) !void {
        const k_owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k_owned);
        const v_owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(v_owned);
        try self.map.put(self.allocator, k_owned, v_owned);
    }

    fn store(self: *FakeBlobStore) blob_mod.BlobStore {
        return .{
            .ptr = self,
            .vtable = &.{
                .put = vtPut,
                .get = vtGet,
                .exists = vtExists,
                .delete = vtDelete,
            },
        };
    }

    fn vtPut(ptr: *anyopaque, key: []const u8, bytes: []const u8) anyerror!void {
        const self: *FakeBlobStore = @ptrCast(@alignCast(ptr));
        return self.put(key, bytes);
    }

    fn vtGet(ptr: *anyopaque, key: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *FakeBlobStore = @ptrCast(@alignCast(ptr));
        const v = self.map.get(key) orelse return blob_mod.Error.NotFound;
        return allocator.dupe(u8, v);
    }

    fn vtExists(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self: *FakeBlobStore = @ptrCast(@alignCast(ptr));
        return self.map.contains(key);
    }

    fn vtDelete(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *FakeBlobStore = @ptrCast(@alignCast(ptr));
        if (self.map.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }
};

test "mapPathToKey: matches _config/*.json" {
    const allocator = testing.allocator;

    const k1 = (try mapPathToKey(allocator, "_config/oauth/google.json")).?;
    defer allocator.free(k1);
    try testing.expectEqualStrings("_config/oauth/google", k1);

    const k2 = (try mapPathToKey(allocator, "_config/sessions/default.json")).?;
    defer allocator.free(k2);
    try testing.expectEqualStrings("_config/sessions/default", k2);
}

test "mapPathToKey: rejects non-config paths" {
    const allocator = testing.allocator;
    try testing.expect((try mapPathToKey(allocator, "index.mjs")) == null);
    try testing.expect((try mapPathToKey(allocator, "config/oauth.json")) == null); // no underscore
    try testing.expect((try mapPathToKey(allocator, "_config/oauth/README")) == null); // no .json
    try testing.expect((try mapPathToKey(allocator, "_config/oauth/notes.md")) == null);
}

test "mirrorConfigToKv: writes new rows + drops stale rows" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(data_dir_path);

    const db_path = try std.fs.path.joinZ(allocator, &.{ data_dir_path, "app.db" });
    defer allocator.free(db_path);

    var kv = try kv_mod.KvStore.open(allocator, db_path);
    defer kv.close();

    var fake = FakeBlobStore{ .allocator = allocator };
    defer fake.deinit();
    const blobs = fake.store();

    // Pre-existing _config row that the new deploy will REMOVE.
    {
        var seed_txn = try kv.beginTrackedImmediate();
        errdefer seed_txn.rollback() catch {};
        try seed_txn.put("_config/oauth/old_provider", "{\"stale\":true}");
        try seed_txn.commit();
    }

    // Stage two new config files into the blob store and build a
    // matching manifest.
    const google_json = "{\"client_id\":\"google.example\"}";
    const sessions_json = "{\"cookie_name\":\"session\"}";
    var google_hex: [64]u8 = undefined;
    var sessions_hex: [64]u8 = undefined;
    try writeBlob(&fake, google_json, &google_hex);
    try writeBlob(&fake, sessions_json, &sessions_hex);

    var entries = [_]files_mod.FileStore.Entry{
        .{
            .path = try allocator.dupe(u8, "_config/oauth/google.json"),
            .kind = .static,
            .content_type = try allocator.dupe(u8, "application/json"),
            .source_hex = google_hex,
            .bytecode_hex = std.mem.zeroes([64]u8),
        },
        .{
            .path = try allocator.dupe(u8, "_config/sessions/default.json"),
            .kind = .static,
            .content_type = try allocator.dupe(u8, "application/json"),
            .source_hex = sessions_hex,
            .bytecode_hex = std.mem.zeroes([64]u8),
        },
    };
    defer for (entries) |e| {
        allocator.free(e.path);
        allocator.free(e.content_type);
    };
    const manifest: manifest_json.Manifest = .{
        .id = 7,
        .entries = &entries,
        .allocator = allocator,
    };

    var txn = try kv.beginTrackedImmediate();
    errdefer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();

    const stats = try mirrorConfigToKv(allocator, manifest, blobs, kv, &txn, &ws);
    try testing.expectEqual(@as(usize, 2), stats.put_count);
    try testing.expectEqual(@as(usize, 1), stats.delete_count);

    try txn.commit();

    // Verify the new rows landed and the stale row is gone.
    const got_google = try kv.get("_config/oauth/google");
    defer allocator.free(got_google);
    try testing.expectEqualStrings(google_json, got_google);

    const got_sessions = try kv.get("_config/sessions/default");
    defer allocator.free(got_sessions);
    try testing.expectEqualStrings(sessions_json, got_sessions);

    try testing.expectError(error.NotFound, kv.get("_config/oauth/old_provider"));
}

test "mirrorConfigToKv: re-running with same manifest is idempotent" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(data_dir_path);

    const db_path = try std.fs.path.joinZ(allocator, &.{ data_dir_path, "app.db" });
    defer allocator.free(db_path);

    var kv = try kv_mod.KvStore.open(allocator, db_path);
    defer kv.close();

    var fake = FakeBlobStore{ .allocator = allocator };
    defer fake.deinit();
    const blobs = fake.store();

    const json_bytes = "{\"client_id\":\"x\"}";
    var hex: [64]u8 = undefined;
    try writeBlob(&fake, json_bytes, &hex);

    var entries = [_]files_mod.FileStore.Entry{
        .{
            .path = try allocator.dupe(u8, "_config/oauth/google.json"),
            .kind = .static,
            .content_type = try allocator.dupe(u8, "application/json"),
            .source_hex = hex,
            .bytecode_hex = std.mem.zeroes([64]u8),
        },
    };
    defer for (entries) |e| {
        allocator.free(e.path);
        allocator.free(e.content_type);
    };
    const manifest: manifest_json.Manifest = .{
        .id = 1,
        .entries = &entries,
        .allocator = allocator,
    };

    {
        var txn = try kv.beginTrackedImmediate();
        errdefer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(allocator);
        defer ws.deinit();
        _ = try mirrorConfigToKv(allocator, manifest, blobs, kv, &txn, &ws);
        try txn.commit();
    }

    var txn = try kv.beginTrackedImmediate();
    errdefer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    const stats = try mirrorConfigToKv(allocator, manifest, blobs, kv, &txn, &ws);
    try txn.commit();

    try testing.expectEqual(@as(usize, 1), stats.put_count);
    try testing.expectEqual(@as(usize, 0), stats.delete_count);
}

test "mirrorConfigToKv: rejects oversized config file" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(data_dir_path);

    const db_path = try std.fs.path.joinZ(allocator, &.{ data_dir_path, "app.db" });
    defer allocator.free(db_path);

    var kv = try kv_mod.KvStore.open(allocator, db_path);
    defer kv.close();

    var fake = FakeBlobStore{ .allocator = allocator };
    defer fake.deinit();
    const blobs = fake.store();

    // 65 KB blob — one byte over the cap.
    const bloated = try allocator.alloc(u8, MAX_CONFIG_BYTES + 1);
    defer allocator.free(bloated);
    @memset(bloated, '{');
    var hex: [64]u8 = undefined;
    try writeBlob(&fake, bloated, &hex);

    var entries = [_]files_mod.FileStore.Entry{
        .{
            .path = try allocator.dupe(u8, "_config/oauth/google.json"),
            .kind = .static,
            .content_type = try allocator.dupe(u8, "application/json"),
            .source_hex = hex,
            .bytecode_hex = std.mem.zeroes([64]u8),
        },
    };
    defer for (entries) |e| {
        allocator.free(e.path);
        allocator.free(e.content_type);
    };
    const manifest: manifest_json.Manifest = .{
        .id = 1,
        .entries = &entries,
        .allocator = allocator,
    };

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    try testing.expectError(
        Error.ConfigTooLarge,
        mirrorConfigToKv(allocator, manifest, blobs, kv, &txn, &ws),
    );
}

test "mirrorConfigToKv: ignores handler files even under _config/" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(data_dir_path);

    const db_path = try std.fs.path.joinZ(allocator, &.{ data_dir_path, "app.db" });
    defer allocator.free(db_path);

    var kv = try kv_mod.KvStore.open(allocator, db_path);
    defer kv.close();

    var fake = FakeBlobStore{ .allocator = allocator };
    defer fake.deinit();
    const blobs = fake.store();

    var entries = [_]files_mod.FileStore.Entry{
        .{
            .path = try allocator.dupe(u8, "_config/weird.json"),
            .kind = .handler, // category error — skipped
            .content_type = try allocator.dupe(u8, ""),
            .source_hex = std.mem.zeroes([64]u8),
            .bytecode_hex = std.mem.zeroes([64]u8),
        },
    };
    defer for (entries) |e| {
        allocator.free(e.path);
        allocator.free(e.content_type);
    };
    const manifest: manifest_json.Manifest = .{
        .id = 1,
        .entries = &entries,
        .allocator = allocator,
    };

    var txn = try kv.beginTrackedImmediate();
    errdefer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    const stats = try mirrorConfigToKv(allocator, manifest, blobs, kv, &txn, &ws);
    try txn.commit();

    try testing.expectEqual(@as(usize, 0), stats.put_count);
}

fn writeBlob(fake: *FakeBlobStore, bytes: []const u8, hex_out: *[64]u8) !void {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    hex_out.* = std.fmt.bytesToHex(hash, .lower);
    try fake.put(hex_out, bytes);
}
