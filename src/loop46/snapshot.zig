//! Phase 5.5(c) snapshot capture orchestrator.
//!
//! Walks every tenant in the leader's `ApplyCtx.kv_stores`, runs
//! `VACUUM INTO` against each per-tenant `app.db` plus the
//! singleton `__root__.db`, content-addresses the resulting files,
//! and uploads them to a `BatchStore` (typically S3 in prod, fs in
//! dev) under `cluster/snapshots/{snap_id}/...`. Writes a
//! per-snapshot manifest JSON pointing at every uploaded file.
//!
//! Designed to run on the raft thread on the leader. No global
//! write-pause: each tenant's `VACUUM INTO` takes a brief
//! per-tenant writer lock (sub-millisecond for typical kb-sized
//! app.dbs) and concurrent writes to OTHER tenants are unaffected.
//!
//! ## What this step (#70 — step 3a) ships
//!
//! - `capture()` produces a snapshot end-to-end: VACUUM, hash,
//!   PUT to BatchStore, manifest write.
//! - Always-refreshes every tenant: even dormant ones get a fresh
//!   manifest entry with `snapshot_idx = apply_position`. That's
//!   how the eventual willemt compaction floor advances past
//!   tenants that haven't been written to in a while.
//! - Always re-VACUUMs every tenant. The "by-reference reuse"
//!   optimization (manifest entry references prior snapshot's
//!   db_key when nothing changed) lands in step 3b.
//! - Doesn't touch raft log compaction yet (the
//!   `raft_begin_snapshot` / `raft_end_snapshot` calls). That
//!   wiring lands alongside step 4 (follower load + restore CLI)
//!   so the two pieces ship together.
//!
//! ## Manifest schema
//!
//! Mirrors `docs/snapshot-plan.md` §3.1. Stable v1; future schema
//! additions go behind feature fields the decoder ignores.

const std = @import("std");
const kv = @import("rove-kv");
const apply_mod = @import("rove-js").apply;
const ls = @import("rove-log-server");

pub const VERSION: u32 = 1;

pub const Error = error{
    OutOfMemory,
    Sqlite,
    Io,
    Backend,
    InvalidManifest,
};

/// One tenant's slot in the manifest.
pub const TenantEntry = struct {
    /// Allocator-owned strings — see `Manifest.deinit`.
    instance_id: []u8,
    db_key: []u8,
    db_sha256: [64]u8,
    db_size: u64,
    /// Raft index this tenant's `_apply_state` was at when
    /// captured. Always equal to `apply_position` for the always-
    /// refresh property; future per-tenant captures may diverge.
    snapshot_idx: u64,
};

/// `__root__.db` (singleton) + same shape as `TenantEntry` minus
/// the per-tenant id. Future webhooks_db lands here too.
pub const SingletonEntry = struct {
    db_key: []u8,
    db_sha256: [64]u8,
    db_size: u64,
    snapshot_idx: u64,
};

pub const Manifest = struct {
    allocator: std.mem.Allocator,
    snap_id: []u8,
    captured_at_ms: i64,
    /// `min(snapshot_idx)` across every entry — typically equal to
    /// `apply_position` (always-refresh). The willemt compaction
    /// floor must not advance past this value.
    willemt_compaction_floor: u64,
    /// Raft term at capture time. Followers verify on load to
    /// reject snapshots from a term they haven't seen.
    willemt_term: u64,
    tenants: []TenantEntry,
    /// Null when this node has never seen a root_writeset apply
    /// (test fixtures). Production always has root.
    root_db: ?SingletonEntry,

    pub fn deinit(self: *Manifest) void {
        const a = self.allocator;
        a.free(self.snap_id);
        for (self.tenants) |*t| {
            a.free(t.instance_id);
            a.free(t.db_key);
        }
        a.free(self.tenants);
        if (self.root_db) |*r| a.free(r.db_key);
        self.* = undefined;
    }
};

/// Result of `capture` — the new snapshot's id + the bytes of the
/// manifest object that landed in the snapshot store. Caller can
/// log the id, hand the manifest to a follower, etc.
pub const Captured = struct {
    snap_id: []u8,
    manifest_key: []u8,
    manifest_bytes: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Captured) void {
        self.allocator.free(self.snap_id);
        self.allocator.free(self.manifest_key);
        self.allocator.free(self.manifest_bytes);
        self.* = undefined;
    }
};

/// Capture a snapshot end-to-end. The caller threads the
/// just-promoted `apply_position` (current willemt commit idx) and
/// `willemt_term`; both end up in the manifest so a follower's
/// load path can reject mismatches and so the compaction floor is
/// recorded.
///
/// `tmp_dir` is where intermediate VACUUM outputs land before
/// upload. Caller picks (typically `{data_dir}/.snapshot-stage/`);
/// each capture creates a per-snap_id subdir inside, deletes it
/// at the end. Files there must NOT collide across concurrent
/// captures — the snap_id namespace gives that property.
pub fn capture(
    allocator: std.mem.Allocator,
    apply_ctx: *apply_mod.ApplyCtx,
    snapshot_store: ls.batch_store.BatchStore,
    tmp_dir: []const u8,
    apply_position: u64,
    willemt_term: u64,
) !Captured {
    const snap_id = try mintSnapId(allocator);
    errdefer allocator.free(snap_id);

    // Stage dir lives at `{tmp_dir}/{snap_id}/` so a crash mid-
    // capture leaves an isolated, identifiable directory the next
    // run (or a janitor) can clean up.
    const stage = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_dir, snap_id });
    defer allocator.free(stage);
    std.fs.cwd().makePath(stage) catch return Error.Io;
    defer std.fs.cwd().deleteTree(stage) catch {};

    var tenants: std.ArrayListUnmanaged(TenantEntry) = .empty;
    errdefer freeTenantList(allocator, &tenants);

    // ── Per-tenant captures ─────────────────────────────────────
    var it = apply_ctx.kv_stores.iterator();
    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        const store = entry.value_ptr.*;

        // VACUUM INTO `{stage}/{id}.db`, then read + sha + put.
        const tmp_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/{s}.db",
            .{ stage, id },
            0,
        );
        defer allocator.free(tmp_path);

        store.vacuumInto(tmp_path) catch return Error.Sqlite;

        const captured = try uploadDbFile(
            allocator,
            snapshot_store,
            tmp_path,
            try snapshotKey(allocator, snap_id, id),
        );

        const id_copy = try allocator.dupe(u8, id);
        errdefer allocator.free(id_copy);
        try tenants.append(allocator, .{
            .instance_id = id_copy,
            .db_key = captured.key,
            .db_sha256 = captured.sha256_hex,
            .db_size = captured.size,
            .snapshot_idx = apply_position,
        });
    }

    // ── Root db (singleton) ─────────────────────────────────────
    var root_entry: ?SingletonEntry = null;
    errdefer if (root_entry) |*r| allocator.free(r.db_key);
    if (apply_ctx.root_store) |root_store| {
        const tmp_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/__root__.db",
            .{stage},
            0,
        );
        defer allocator.free(tmp_path);
        root_store.vacuumInto(tmp_path) catch return Error.Sqlite;

        const root_key = try std.fmt.allocPrint(
            allocator,
            "cluster/snapshots/{s}/__root__.db",
            .{snap_id},
        );
        const captured = try uploadDbFile(
            allocator,
            snapshot_store,
            tmp_path,
            root_key,
        );
        root_entry = .{
            .db_key = captured.key,
            .db_sha256 = captured.sha256_hex,
            .db_size = captured.size,
            .snapshot_idx = apply_position,
        };
    }

    // ── Manifest ────────────────────────────────────────────────
    const captured_at_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
    const tenant_slice = try tenants.toOwnedSlice(allocator);
    var manifest = Manifest{
        .allocator = allocator,
        .snap_id = try allocator.dupe(u8, snap_id),
        .captured_at_ms = captured_at_ms,
        .willemt_compaction_floor = apply_position,
        .willemt_term = willemt_term,
        .tenants = tenant_slice,
        .root_db = root_entry,
    };
    defer manifest.deinit();

    const manifest_bytes = try encodeManifest(allocator, &manifest);
    errdefer allocator.free(manifest_bytes);

    const manifest_key = try std.fmt.allocPrint(
        allocator,
        "cluster/snapshots/{s}/manifest.json",
        .{snap_id},
    );
    errdefer allocator.free(manifest_key);

    snapshot_store.put(manifest_key, manifest_bytes) catch return Error.Backend;

    return .{
        .allocator = allocator,
        .snap_id = snap_id,
        .manifest_key = manifest_key,
        .manifest_bytes = manifest_bytes,
    };
}

/// 26-char ULID-ish stamp: `{ms_since_epoch_hex:0>14}{random_hex:12}`.
/// Sortable by creation time, unique under concurrent calls. Caller
/// frees.
fn mintSnapId(allocator: std.mem.Allocator) ![]u8 {
    const ms_now: u64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
    const r: u64 = std.crypto.random.int(u64);
    return std.fmt.allocPrint(allocator, "{x:0>14}{x:0>12}", .{ ms_now, r & 0xFFFFFFFFFFFF });
}

fn snapshotKey(
    allocator: std.mem.Allocator,
    snap_id: []const u8,
    instance_id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "cluster/snapshots/{s}/{s}/app.db",
        .{ snap_id, instance_id },
    );
}

const UploadResult = struct {
    key: []u8,
    sha256_hex: [64]u8,
    size: u64,
};

/// Read the file at `tmp_path`, sha256-hash + size + PUT to the
/// snapshot store at `key`. The caller-supplied `key` is moved
/// into the result (caller frees on success / errdefer on
/// failure). The on-disk file isn't deleted here — the per-snap
/// stage directory is deleted as a unit by `capture`'s defer.
fn uploadDbFile(
    allocator: std.mem.Allocator,
    snapshot_store: ls.batch_store.BatchStore,
    tmp_path: [:0]const u8,
    key: []u8,
) !UploadResult {
    errdefer allocator.free(key);

    const bytes = std.fs.cwd().readFileAlloc(allocator, tmp_path, std.math.maxInt(usize)) catch
        return Error.Io;
    defer allocator.free(bytes);

    snapshot_store.put(key, bytes) catch return Error.Backend;

    var sha_hex: [64]u8 = undefined;
    sha256Hex(bytes, &sha_hex);

    return .{ .key = key, .sha256_hex = sha_hex, .size = bytes.len };
}

fn sha256Hex(bytes: []const u8, out: *[64]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

fn freeTenantList(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(TenantEntry)) void {
    for (list.items) |*t| {
        allocator.free(t.instance_id);
        allocator.free(t.db_key);
    }
    list.deinit(allocator);
}

// ── Manifest JSON ──────────────────────────────────────────────────

pub fn encodeManifest(
    allocator: std.mem.Allocator,
    m: *const Manifest,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);

    try w.print(
        "{{\"v\":{d},\"snap_id\":\"{s}\",\"captured_at_ms\":{d},\"willemt_compaction_floor\":{d},\"willemt_term\":{d},",
        .{ VERSION, m.snap_id, m.captured_at_ms, m.willemt_compaction_floor, m.willemt_term },
    );
    try w.writeAll("\"tenants\":{");
    for (m.tenants, 0..) |t, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonString(&w, t.instance_id);
        try w.print(
            ":{{\"db_key\":\"{s}\",\"db_sha256\":\"{s}\",\"db_size\":{d},\"snapshot_idx\":{d}}}",
            .{ t.db_key, t.db_sha256, t.db_size, t.snapshot_idx },
        );
    }
    try w.writeAll("}");
    if (m.root_db) |r| {
        try w.print(
            ",\"root_db\":{{\"db_key\":\"{s}\",\"db_sha256\":\"{s}\",\"db_size\":{d},\"snapshot_idx\":{d}}}",
            .{ r.db_key, r.db_sha256, r.db_size, r.snapshot_idx },
        );
    }
    try w.writeByte('}');
    return buf.toOwnedSlice(allocator);
}

pub fn decodeManifest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error!Manifest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
        return Error.InvalidManifest;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return Error.InvalidManifest,
    };

    const v = jsonInt(obj.get("v")) orelse return Error.InvalidManifest;
    if (v != @as(i64, @intCast(VERSION))) return Error.InvalidManifest;

    const snap_id_str = jsonString(obj.get("snap_id")) orelse return Error.InvalidManifest;
    const snap_id = try allocator.dupe(u8, snap_id_str);
    errdefer allocator.free(snap_id);

    const captured_at_ms = jsonInt(obj.get("captured_at_ms")) orelse return Error.InvalidManifest;
    const floor = jsonInt(obj.get("willemt_compaction_floor")) orelse return Error.InvalidManifest;
    const term = jsonInt(obj.get("willemt_term")) orelse return Error.InvalidManifest;
    if (floor < 0 or term < 0) return Error.InvalidManifest;

    const tenants_val = obj.get("tenants") orelse return Error.InvalidManifest;
    const tenants_obj = switch (tenants_val) {
        .object => |o| o,
        else => return Error.InvalidManifest,
    };

    var tenants: std.ArrayListUnmanaged(TenantEntry) = .empty;
    errdefer freeTenantList(allocator, &tenants);
    var t_it = tenants_obj.iterator();
    while (t_it.next()) |kv_pair| {
        const id_copy = try allocator.dupe(u8, kv_pair.key_ptr.*);
        errdefer allocator.free(id_copy);
        const e = try parseEntry(allocator, kv_pair.value_ptr.*);
        try tenants.append(allocator, .{
            .instance_id = id_copy,
            .db_key = e.db_key,
            .db_sha256 = e.db_sha256,
            .db_size = e.db_size,
            .snapshot_idx = e.snapshot_idx,
        });
    }

    var root_db: ?SingletonEntry = null;
    if (obj.get("root_db")) |rv| {
        const e = try parseEntry(allocator, rv);
        root_db = .{
            .db_key = e.db_key,
            .db_sha256 = e.db_sha256,
            .db_size = e.db_size,
            .snapshot_idx = e.snapshot_idx,
        };
    }

    return .{
        .allocator = allocator,
        .snap_id = snap_id,
        .captured_at_ms = captured_at_ms,
        .willemt_compaction_floor = @intCast(floor),
        .willemt_term = @intCast(term),
        .tenants = try tenants.toOwnedSlice(allocator),
        .root_db = root_db,
    };
}

const ParsedEntry = struct {
    db_key: []u8,
    db_sha256: [64]u8,
    db_size: u64,
    snapshot_idx: u64,
};

fn parseEntry(allocator: std.mem.Allocator, val: std.json.Value) Error!ParsedEntry {
    const o = switch (val) {
        .object => |o| o,
        else => return Error.InvalidManifest,
    };
    const key = jsonString(o.get("db_key")) orelse return Error.InvalidManifest;
    const sha = jsonString(o.get("db_sha256")) orelse return Error.InvalidManifest;
    const size = jsonInt(o.get("db_size")) orelse return Error.InvalidManifest;
    const idx = jsonInt(o.get("snapshot_idx")) orelse return Error.InvalidManifest;
    if (sha.len != 64 or size < 0 or idx < 0) return Error.InvalidManifest;

    const key_copy = try allocator.dupe(u8, key);
    errdefer allocator.free(key_copy);
    var sha_arr: [64]u8 = undefined;
    @memcpy(&sha_arr, sha[0..64]);
    return .{
        .db_key = key_copy,
        .db_sha256 = sha_arr,
        .db_size = @intCast(size),
        .snapshot_idx = @intCast(idx),
    };
}

fn jsonInt(v: ?std.json.Value) ?i64 {
    if (v == null) return null;
    return switch (v.?) {
        .integer => |i| i,
        else => null,
    };
}

fn jsonString(v: ?std.json.Value) ?[]const u8 {
    if (v == null) return null;
    return switch (v.?) {
        .string => |s| s,
        else => null,
    };
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
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{b}),
            else => try w.writeByte(b),
        }
    }
    try w.writeByte('"');
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn tmpPath(buf: *[96]u8, tag: []const u8) []const u8 {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    return std.fmt.bufPrint(buf, "/tmp/rove-snap-{s}-{x}", .{ tag, seed }) catch unreachable;
}

fn noopApply(_: u64, _: []const u8, _: ?*anyopaque) void {}

test "encode + decode manifest round-trips with one tenant" {
    var m = Manifest{
        .allocator = testing.allocator,
        .snap_id = try testing.allocator.dupe(u8, "0123456789abcdef0123456789ab"),
        .captured_at_ms = 1700000000000,
        .willemt_compaction_floor = 42,
        .willemt_term = 7,
        .tenants = blk: {
            var slice = try testing.allocator.alloc(TenantEntry, 1);
            slice[0] = .{
                .instance_id = try testing.allocator.dupe(u8, "acme"),
                .db_key = try testing.allocator.dupe(u8, "cluster/snapshots/X/acme/app.db"),
                .db_sha256 = @splat('a'),
                .db_size = 1024,
                .snapshot_idx = 42,
            };
            break :blk slice;
        },
        .root_db = .{
            .db_key = try testing.allocator.dupe(u8, "cluster/snapshots/X/__root__.db"),
            .db_sha256 = @splat('b'),
            .db_size = 2048,
            .snapshot_idx = 42,
        },
    };
    defer m.deinit();

    const bytes = try encodeManifest(testing.allocator, &m);
    defer testing.allocator.free(bytes);

    var back = try decodeManifest(testing.allocator, bytes);
    defer back.deinit();

    try testing.expectEqualStrings(m.snap_id, back.snap_id);
    try testing.expectEqual(@as(u64, 42), back.willemt_compaction_floor);
    try testing.expectEqual(@as(u64, 7), back.willemt_term);
    try testing.expectEqual(@as(usize, 1), back.tenants.len);
    try testing.expectEqualStrings("acme", back.tenants[0].instance_id);
    try testing.expectEqual(@as(u64, 1024), back.tenants[0].db_size);
    try testing.expect(back.root_db != null);
    try testing.expectEqual(@as(u64, 2048), back.root_db.?.db_size);
}

test "decode rejects wrong version" {
    const bad = "{\"v\":99,\"snap_id\":\"x\",\"captured_at_ms\":1,\"willemt_compaction_floor\":0,\"willemt_term\":0,\"tenants\":{}}";
    try testing.expectError(Error.InvalidManifest, decodeManifest(testing.allocator, bad));
}

test "capture: end-to-end against FsBatchStore round-trips a tenant db" {
    const allocator = testing.allocator;

    var path_buf: [96]u8 = undefined;
    const root_path = tmpPath(&path_buf, "ctx");
    defer std.fs.cwd().deleteTree(root_path) catch {};
    try std.fs.cwd().makePath(root_path);

    // Plant a `__root__.db` so ApplyCtx can lazy-open it.
    {
        const root_db_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/__root__.db",
            .{root_path},
            0,
        );
        defer allocator.free(root_db_path);
        const root_kv = try kv.KvStore.open(allocator, root_db_path);
        root_kv.close();
    }

    // Stand up a minimal raft node so ApplyCtx.init has something
    // to point at.
    const raft_log_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/raft.log.db",
        .{root_path},
        0,
    );
    defer allocator.free(raft_log_path);
    const peers = [_]kv.RaftPeerAddr{.{ .host = "127.0.0.1", .port = 39800 }};
    const node = try kv.RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39800),
        .apply = .{ .opaque_bytes = .{ .apply_fn = noopApply, .ctx = null } },
        .raft_log_path = raft_log_path,
    });
    defer node.deinit();

    // Tenant `acme` with one row.
    const acme_dir = try std.fmt.allocPrint(allocator, "{s}/acme", .{root_path});
    defer allocator.free(acme_dir);
    try std.fs.cwd().makePath(acme_dir);
    const acme_db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/app.db",
        .{acme_dir},
        0,
    );
    defer allocator.free(acme_db_path);
    {
        const acme_kv = try kv.KvStore.open(allocator, acme_db_path);
        defer acme_kv.close();
        try acme_kv.put("hello", "world");
        try acme_kv.setLastAppliedRaftIdx(99);
    }

    var apply_ctx = apply_mod.ApplyCtx.init(allocator, root_path, node);
    defer apply_ctx.deinit();
    // Trigger lazy-open so kv_stores has acme + root_store is set.
    _ = try apply_ctx.getKv("acme");
    _ = try apply_ctx.getRootKv();

    // Snapshot store + tmp stage dir.
    const store_dir = try std.fmt.allocPrint(allocator, "{s}/.snapshots", .{root_path});
    defer allocator.free(store_dir);
    const stage_dir = try std.fmt.allocPrint(allocator, "{s}/.stage", .{root_path});
    defer allocator.free(stage_dir);

    const store = try ls.batch_store_fs.FsBatchStore.init(allocator, store_dir);
    defer store.deinit();

    var captured = try capture(
        allocator,
        &apply_ctx,
        store.batchStore(),
        stage_dir,
        100,
        7,
    );
    defer captured.deinit();

    // Manifest landed under the right key + parses as expected.
    const fetched = try store.batchStore().get(captured.manifest_key, allocator);
    defer allocator.free(fetched);
    var m = try decodeManifest(allocator, fetched);
    defer m.deinit();
    try testing.expectEqual(@as(u64, 100), m.willemt_compaction_floor);
    try testing.expectEqual(@as(u64, 7), m.willemt_term);
    try testing.expectEqual(@as(usize, 1), m.tenants.len);
    try testing.expectEqualStrings("acme", m.tenants[0].instance_id);
    try testing.expectEqual(@as(u64, 100), m.tenants[0].snapshot_idx);
    try testing.expect(m.root_db != null);

    // The acme db file was actually uploaded to the store and is a
    // valid SQLite db with the row we inserted.
    const acme_bytes = try store.batchStore().get(m.tenants[0].db_key, allocator);
    defer allocator.free(acme_bytes);
    try testing.expect(acme_bytes.len > 0);
    try testing.expectEqual(m.tenants[0].db_size, acme_bytes.len);

    // Re-open the captured bytes (write to a temp file, open as
    // KvStore, verify the row survived VACUUM INTO).
    const restore_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/restore.db",
        .{root_path},
        0,
    );
    defer allocator.free(restore_path);
    {
        const f = try std.fs.cwd().createFile(restore_path, .{ .mode = 0o600 });
        defer f.close();
        try f.writeAll(acme_bytes);
    }
    const restored = try kv.KvStore.open(allocator, restore_path);
    defer restored.close();
    const v = try restored.get("hello");
    defer allocator.free(v);
    try testing.expectEqualStrings("world", v);
    try testing.expectEqual(@as(u64, 99), try restored.lastAppliedRaftIdx());
}
