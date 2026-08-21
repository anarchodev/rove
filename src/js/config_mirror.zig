// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
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
const reserved = @import("rove-reserved");

const CONFIG_PREFIX = reserved.CONFIG_PREFIX;
const JSON_SUFFIX = ".json";

/// Maximum bytes for a single `_config/*.json` file. The mirror rides
/// a per-tenant raft envelope, so this is a consensus-cost bound, not a
/// storage one: an oversized config file is skipped with a warning
/// rather than inflating every follower's log entry.
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
/// caller obtains via `TenantStorage.openBackend(..., "file-blobs")`
/// then `blobStore()`).
pub fn mirrorConfigToKv(
    allocator: std.mem.Allocator,
    dep_id: u64,
    manifest: manifest_json.Manifest,
    file_blobs: blob_mod.BlobStore,
    kv: *kv_mod.KvStore,
    txn: *kv_mod.TrackedTxn,
    writeset: *kv_mod.WriteSet,
) Error!Stats {
    var stats: Stats = .{};

    // PUT every config file from the manifest, under THIS deployment.
    //
    // There is no stale-row pass, and its absence is the point. Rows are
    // keyed by `dep_id`, which is a content hash, so a row is immutable and
    // another deployment's rows are not stale — they belong to that
    // deployment. Deleting rows the new manifest did not claim is what made a
    // key REMOVAL race: the delete landed while the previous deployment's code
    // was still live and still reading the key.
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

        var skey_buf: [reserved.CONFIG_STORAGE_KEY_MAX]u8 = undefined;
        const skey = reserved.configStorageKey(&skey_buf, dep_id, kv_key) orelse {
            allocator.free(kv_key);
            return Error.ConfigTooLarge;
        };

        // Already there with these bytes: skip. The row is immutable, so a
        // re-mirror of the same deployment has nothing to say — and that is
        // what makes running this twice, out of order, or on a follower cost
        // nothing. Without the skip every reload re-proposes an identical
        // entry for any tenant that ships config.
        if (kv.get(skey)) |existing| {
            defer allocator.free(existing);
            if (std.mem.eql(u8, existing, bytes)) {
                allocator.free(kv_key);
                continue;
            }
        } else |_| {}

        txn.put(skey, bytes) catch {
            allocator.free(kv_key);
            return Error.Kv;
        };
        writeset.addPut(skey, bytes) catch {
            allocator.free(kv_key);
            return Error.OutOfMemory;
        };
        allocator.free(kv_key);
        stats.put_count += 1;
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

/// One config row as the deploy path hands it to a tenant: the storage key
/// (already deployment-scoped) and its bytes.
pub const Pair = struct {
    key: []u8,
    value: []u8,

    pub fn deinit(self: *Pair, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
        self.* = undefined;
    }
};

pub fn freePairs(allocator: std.mem.Allocator, pairs: []Pair) void {
    for (pairs) |*pr| pr.deinit(allocator);
    allocator.free(pairs);
}

/// Collect a deployment's config rows WITHOUT writing them.
///
/// Same selection, same cap and same deployment-scoped key as
/// `mirrorConfigToKv` — one rule, because two places now need these rows and
/// a second copy of "which entries are config" is how the two would drift.
/// This one exists for the deploy path, which reads the blobs off the poll
/// loop and then hands the rows to the tenant to write in its own scope.
///
/// Caller frees with `freePairs`.
pub fn collectConfigPairs(
    allocator: std.mem.Allocator,
    dep_id: u64,
    manifest: manifest_json.Manifest,
    file_blobs: blob_mod.BlobStore,
) Error![]Pair {
    var out: std.ArrayListUnmanaged(Pair) = .empty;
    errdefer {
        for (out.items) |*pr| pr.deinit(allocator);
        out.deinit(allocator);
    }

    for (manifest.entries) |entry| {
        const kv_key_opt = mapPathToKey(allocator, entry.path) catch return Error.OutOfMemory;
        const kv_key = kv_key_opt orelse continue;
        defer allocator.free(kv_key);
        if (entry.kind != .static) continue;

        const bytes = file_blobs.get(&entry.source_hex, allocator) catch return Error.Blob;
        errdefer allocator.free(bytes);
        if (bytes.len > MAX_CONFIG_BYTES) {
            allocator.free(bytes);
            std.log.warn(
                "config_mirror: {s} is {d} bytes, exceeds {d}-byte cap",
                .{ entry.path, bytes.len, MAX_CONFIG_BYTES },
            );
            return Error.ConfigTooLarge;
        }

        var skey_buf: [reserved.CONFIG_STORAGE_KEY_MAX]u8 = undefined;
        const skey = reserved.configStorageKey(&skey_buf, dep_id, kv_key) orelse {
            allocator.free(bytes);
            return Error.ConfigTooLarge;
        };
        const skey_owned = allocator.dupe(u8, skey) catch {
            allocator.free(bytes);
            return Error.OutOfMemory;
        };
        out.append(allocator, .{ .key = skey_owned, .value = bytes }) catch {
            allocator.free(skey_owned);
            allocator.free(bytes);
            return Error.OutOfMemory;
        };
    }
    return out.toOwnedSlice(allocator) catch Error.OutOfMemory;
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

    // A row from a PREVIOUS deployment. It must survive: that deployment's
    // code may still be serving until the pointer flips, and deleting rows the
    // new manifest does not claim is exactly what made a config-key removal
    // race the release.
    {
        var seed_txn = try kv.beginTrackedImmediate();
        errdefer seed_txn.rollback() catch {};
        try seed_txn.put("_config/0000000000000006/oauth/old_provider", "{\"stale\":true}");
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

    var entries = [_]files_mod.Entry{
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

    const stats = try mirrorConfigToKv(allocator, 7, manifest, blobs, kv, &txn, &ws);
    try testing.expectEqual(@as(usize, 2), stats.put_count);
    try testing.expectEqual(@as(usize, 0), stats.delete_count);

    try txn.commit();

    // The new rows land under THIS deployment.
    const got_google = try kv.get("_config/0000000000000007/oauth/google");
    defer allocator.free(got_google);
    try testing.expectEqualStrings(google_json, got_google);

    const got_sessions = try kv.get("_config/0000000000000007/sessions/default");
    defer allocator.free(got_sessions);
    try testing.expectEqualStrings(sessions_json, got_sessions);

    // …and the previous deployment's row is untouched. Its code may still be
    // running; only the `_deploy/current` flip decides which set is visible.
    const got_old = try kv.get("_config/0000000000000006/oauth/old_provider");
    defer allocator.free(got_old);
    try testing.expectEqualStrings("{\"stale\":true}", got_old);
}

test "mirrorConfigToKv: two deployments of the same config path coexist" {
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

    // Same path, different content — which is the realistic deploy: an edit
    // to `_config/oauth/google.json`. Under one shared namespace the second
    // overwrites the first and the switch is not atomic with the code's.
    const v1 = "{\"client_id\":\"one\"}";
    const v2 = "{\"client_id\":\"two\"}";
    for ([_]struct { dep: u64, body: []const u8 }{
        .{ .dep = 1, .body = v1 },
        .{ .dep = 2, .body = v2 },
    }) |step| {
        var hex: [64]u8 = undefined;
        try writeBlob(&fake, step.body, &hex);
        var entries = [_]files_mod.Entry{.{
            .path = try allocator.dupe(u8, "_config/oauth/google.json"),
            .kind = .static,
            .content_type = try allocator.dupe(u8, "application/json"),
            .source_hex = hex,
            .bytecode_hex = std.mem.zeroes([64]u8),
        }};
        defer for (entries) |e| {
            allocator.free(e.path);
            allocator.free(e.content_type);
        };
        const manifest: manifest_json.Manifest = .{ .id = step.dep, .entries = &entries, .allocator = allocator };

        var txn = try kv.beginTrackedImmediate();
        errdefer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(allocator);
        defer ws.deinit();
        _ = try mirrorConfigToKv(allocator, step.dep, manifest, blobs, kv, &txn, &ws);
        try txn.commit();
    }

    // Both readable at once. `_deploy/current` alone decides which a handler
    // sees, so code and config switch in the same instant — including on a
    // rollback to deployment 1.
    const got1 = try kv.get("_config/0000000000000001/oauth/google");
    defer allocator.free(got1);
    try testing.expectEqualStrings(v1, got1);
    const got2 = try kv.get("_config/0000000000000002/oauth/google");
    defer allocator.free(got2);
    try testing.expectEqualStrings(v2, got2);
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

    var entries = [_]files_mod.Entry{
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
        _ = try mirrorConfigToKv(allocator, 1, manifest, blobs, kv, &txn, &ws);
        try txn.commit();
    }

    var txn = try kv.beginTrackedImmediate();
    errdefer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    const stats = try mirrorConfigToKv(allocator, 1, manifest, blobs, kv, &txn, &ws);
    try txn.commit();

    // Nothing to say: the row is immutable and already present, so a re-mirror
    // writes NOTHING and its caller burns no raft entry. That is what makes
    // running this twice, out of order, or on a follower cost nothing — and it
    // is why the mirror needs no atomicity with the release.
    try testing.expectEqual(@as(usize, 0), stats.put_count);
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

    var entries = [_]files_mod.Entry{
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
        mirrorConfigToKv(allocator, 1, manifest, blobs, kv, &txn, &ws),
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

    var entries = [_]files_mod.Entry{
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
    const stats = try mirrorConfigToKv(allocator, 1, manifest, blobs, kv, &txn, &ws);
    try txn.commit();

    try testing.expectEqual(@as(usize, 0), stats.put_count);
}

fn writeBlob(fake: *FakeBlobStore, bytes: []const u8, hex_out: *[64]u8) !void {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    hex_out.* = std.fmt.bytesToHex(hash, .lower);
    try fake.put(hex_out, bytes);
}

test "collectConfigPairs: the rows a deploy hands the tenant, deployment-scoped" {
    const allocator = testing.allocator;
    var fake = FakeBlobStore{ .allocator = allocator };
    defer fake.deinit();
    const blobs = fake.store();

    const body = "{\"client_id\":\"g\"}";
    var hex: [64]u8 = undefined;
    try writeBlob(&fake, body, &hex);

    var entries = [_]files_mod.Entry{
        .{
            .path = try allocator.dupe(u8, "_config/oauth/google.json"),
            .kind = .static,
            .content_type = try allocator.dupe(u8, "application/json"),
            .source_hex = hex,
            .bytecode_hex = std.mem.zeroes([64]u8),
        },
        // Not config: a handler, and a static outside the namespace. Both are
        // skipped by the SAME rule the loader-side mirror uses, which is why
        // the selection lives in one function.
        .{
            .path = try allocator.dupe(u8, "index.mjs"),
            .kind = .handler,
            .content_type = try allocator.dupe(u8, "text/javascript"),
            .source_hex = hex,
            .bytecode_hex = std.mem.zeroes([64]u8),
        },
        .{
            .path = try allocator.dupe(u8, "_static/logo.svg"),
            .kind = .static,
            .content_type = try allocator.dupe(u8, "image/svg+xml"),
            .source_hex = hex,
            .bytecode_hex = std.mem.zeroes([64]u8),
        },
    };
    defer for (entries) |e| {
        allocator.free(e.path);
        allocator.free(e.content_type);
    };
    const manifest: manifest_json.Manifest = .{ .id = 9, .entries = &entries, .allocator = allocator };

    const pairs = try collectConfigPairs(allocator, 9, manifest, blobs);
    defer freePairs(allocator, pairs);

    try testing.expectEqual(@as(usize, 1), pairs.len);
    try testing.expectEqualStrings("_config/0000000000000009/oauth/google", pairs[0].key);
    try testing.expectEqualStrings(body, pairs[0].value);
}
