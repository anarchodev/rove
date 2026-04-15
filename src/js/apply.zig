//! Apply callback for the worker's raft state machine.
//!
//! ## Wire format
//!
//! Every envelope the worker proposes is:
//!
//!   `[1B type][2B id_len BE][id bytes][payload]`
//!
//! `type=0` → writeset (payload is `WriteSet.encode` bytes)
//! `type=1` → log batch (payload is `LogStore.drainBatch` bytes)
//!
//! The `id` is the tenant `instance_id`. `id_len` caps at 64KB. The
//! trailing `payload` is whatever the dispatch callback for that
//! type knows how to decode.
//!
//! ## Dispatch by type
//!
//! - **type=0 writeset**: leader-skips (because the worker's open
//!   `TrackedTxn` already wrote locally), follower replays through
//!   `kv.applyEncodedWriteSet` against the apply context's own
//!   per-tenant kv store.
//! - **type=1 log batch**: ALSO leader-skips — the worker h2 thread
//!   is the sole writer to its own log.db on the leader, and running
//!   this apply there would race on the same NOMUTEX sqlite
//!   connection. Followers see this as the only code path writing
//!   log.db, so their raft thread is safely the sole writer.
//!
//! ## Threading model — strict isolation from worker state
//!
//! `applyOne` runs on the raft thread. It must NOT reach into any
//! worker's per-tenant state — doing so would share NOMUTEX sqlite
//! connections between the raft thread and worker threads, which is
//! undefined behavior per sqlite's threading docs.
//!
//! Instead, `ApplyCtx` owns ITS OWN per-tenant store map (`kv_stores`
//! and `log_stores`), opened lazily on first apply for each tenant.
//! These connections are raft-thread-local and never touched by any
//! worker. They point at the same sqlite files the workers use, but
//! via independent connections — WAL mode handles the coexistence.
//!
//! On the leader, both apply paths short-circuit via the leader-skip,
//! so the raft-thread-owned connections stay idle. Cost of an idle
//! cached connection is a pair of fds per tenant; acceptable.
//!
//! On followers, the raft thread is the only thread that writes
//! tenant state, so there is no contention to coordinate with.

const std = @import("std");
const kv = @import("rove-kv");
const log_mod = @import("rove-log");
const blob_mod = @import("rove-blob");

pub const Error = error{
    Truncated,
    UnknownInstance,
    UnknownEnvelopeType,
    ApplyFailed,
};

pub const MAX_ID_LEN: usize = 256;

/// worker_id used for the raft-thread's own LogStore connections.
/// Must not collide with any real worker's `worker_id` (which come
/// from `raft.config.node_id`). We reserve the top bit — any worker
/// using node_id >= 0x8000 would collide, but node ids that big are
/// already out of range for a willemt cluster.
pub const APPLY_WORKER_ID: u16 = 0xFFFF;

/// Internal bundle of the three things needed to run a per-tenant
/// log_store write on the raft thread: the sqlite connection, the
/// blob backend, and the LogStore wrapping them. All three are
/// allocated together, freed together.
const RaftLogHandle = struct {
    kv_store: *kv.KvStore,
    blob_backend: blob_mod.FilesystemBlobStore,
    store: log_mod.LogStore,
};

pub const EnvelopeType = enum(u8) {
    writeset = 0,
    log_batch = 1,
};

/// Build a writeset envelope. `id_len` and `id` plus a leading type=0
/// byte; payload is the writeset bytes.
pub fn encodeWriteSetEnvelope(
    allocator: std.mem.Allocator,
    id: []const u8,
    ws_bytes: []const u8,
) ![]u8 {
    return encodeTyped(allocator, .writeset, id, ws_bytes);
}

/// Build a log batch envelope. type=1 + id + batch bytes.
pub fn encodeLogBatchEnvelope(
    allocator: std.mem.Allocator,
    id: []const u8,
    batch_bytes: []const u8,
) ![]u8 {
    return encodeTyped(allocator, .log_batch, id, batch_bytes);
}

fn encodeTyped(
    allocator: std.mem.Allocator,
    t: EnvelopeType,
    id: []const u8,
    payload: []const u8,
) ![]u8 {
    if (id.len > MAX_ID_LEN) return error.OutOfMemory;
    const total = 1 + 2 + id.len + payload.len;
    const out = try allocator.alloc(u8, total);
    out[0] = @intFromEnum(t);
    std.mem.writeInt(u16, out[1..3], @intCast(id.len), .big);
    @memcpy(out[3 .. 3 + id.len], id);
    @memcpy(out[3 + id.len ..], payload);
    return out;
}

pub const Envelope = struct {
    type: EnvelopeType,
    instance_id: []const u8,
    payload: []const u8,
};

/// Decode an envelope. Slices into the input buffer; valid until the
/// caller drops `payload`.
pub fn decodeEnvelope(payload: []const u8) Error!Envelope {
    if (payload.len < 3) return Error.Truncated;
    const type_byte = payload[0];
    const t = std.meta.intToEnum(EnvelopeType, type_byte) catch
        return Error.UnknownEnvelopeType;
    const id_len = std.mem.readInt(u16, payload[1..3], .big);
    if (payload.len < 3 + @as(usize, id_len)) return Error.Truncated;
    return .{
        .type = t,
        .instance_id = payload[3 .. 3 + id_len],
        .payload = payload[3 + id_len ..],
    };
}

/// Apply callback context — self-owning, raft-thread-local.
///
/// Holds lazy per-tenant sqlite connections that are opened on first
/// apply for each instance and cached for subsequent applies. These
/// are DISTINCT from any worker's connections; they exist solely for
/// the raft thread's use.
///
/// On the leader path, both `applyWriteSet` and `applyLogBatch`
/// short-circuit via `raft.isLeader()`, so the cached stores stay
/// idle — workers wrote locally via their own connections, and the
/// raft thread just advances `committed_seq`. The caches come alive
/// on followers, where the raft thread is the sole writer.
///
/// Lifecycle: construct before starting the raft thread, `deinit`
/// after the raft thread has stopped. The caches are grown only by
/// the raft thread itself (via `applyOne`), so no locking is needed.
pub const ApplyCtx = struct {
    allocator: std.mem.Allocator,
    /// Root data dir. Per-tenant stores live at
    /// `{data_dir}/{id}/{app,log}.db` + `log-blobs/`.
    data_dir: []const u8,
    /// Used for the leader-skip check on both envelope types.
    raft: *kv.RaftNode,
    /// Lazy per-tenant KvStore cache (instance_id → *KvStore). Keys
    /// are owned copies of the instance id.
    kv_stores: std.StringHashMapUnmanaged(*kv.KvStore),
    /// Lazy per-tenant log handle cache (instance_id → *RaftLogHandle).
    /// Keys are owned copies of the instance id.
    log_stores: std.StringHashMapUnmanaged(*RaftLogHandle),

    pub fn init(
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        raft: *kv.RaftNode,
    ) ApplyCtx {
        return .{
            .allocator = allocator,
            .data_dir = data_dir,
            .raft = raft,
            .kv_stores = .empty,
            .log_stores = .empty,
        };
    }

    pub fn deinit(self: *ApplyCtx) void {
        var kv_it = self.kv_stores.iterator();
        while (kv_it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.*.close();
        }
        self.kv_stores.deinit(self.allocator);

        var log_it = self.log_stores.iterator();
        while (log_it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            const h = e.value_ptr.*;
            h.store.deinit();
            h.blob_backend.deinit();
            h.kv_store.close();
            self.allocator.destroy(h);
        }
        self.log_stores.deinit(self.allocator);
    }

    /// Lazily open this tenant's app.db kv store. The returned
    /// pointer is owned by the context and stable for the lifetime
    /// of the context.
    fn getKv(self: *ApplyCtx, instance_id: []const u8) !*kv.KvStore {
        if (self.kv_stores.get(instance_id)) |existing| return existing;

        const path = try std.fmt.allocPrintSentinel(
            self.allocator,
            "{s}/{s}/app.db",
            .{ self.data_dir, instance_id },
            0,
        );
        defer self.allocator.free(path);

        const store = try kv.KvStore.open(self.allocator, path);
        errdefer store.close();

        const id_copy = try self.allocator.dupe(u8, instance_id);
        errdefer self.allocator.free(id_copy);

        try self.kv_stores.put(self.allocator, id_copy, store);
        return store;
    }

    /// Lazily open this tenant's log.db + log-blobs/ and wrap them
    /// in a LogStore. Pointer is owned by the context.
    fn getLog(self: *ApplyCtx, instance_id: []const u8) !*log_mod.LogStore {
        if (self.log_stores.get(instance_id)) |existing| return &existing.store;

        const inst_dir = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ self.data_dir, instance_id },
        );
        defer self.allocator.free(inst_dir);
        std.fs.cwd().makePath(inst_dir) catch {};

        const log_db_path = try std.fmt.allocPrintSentinel(
            self.allocator,
            "{s}/log.db",
            .{inst_dir},
            0,
        );
        defer self.allocator.free(log_db_path);

        const log_blob_dir = try std.fmt.allocPrint(
            self.allocator,
            "{s}/log-blobs",
            .{inst_dir},
        );
        defer self.allocator.free(log_blob_dir);

        const kv_store = try kv.KvStore.open(self.allocator, log_db_path);
        errdefer kv_store.close();

        const handle = try self.allocator.create(RaftLogHandle);
        errdefer self.allocator.destroy(handle);
        handle.kv_store = kv_store;
        handle.blob_backend = try blob_mod.FilesystemBlobStore.open(self.allocator, log_blob_dir);
        errdefer handle.blob_backend.deinit();
        handle.store = try log_mod.LogStore.init(
            self.allocator,
            handle.kv_store,
            handle.blob_backend.blobStore(),
            APPLY_WORKER_ID,
        );
        errdefer handle.store.deinit();

        const id_copy = try self.allocator.dupe(u8, instance_id);
        errdefer self.allocator.free(id_copy);

        try self.log_stores.put(self.allocator, id_copy, handle);
        return &handle.store;
    }
};

/// The function rove-kv's `RaftNode` calls for every committed entry
/// in `.opaque_bytes` apply mode. Dispatches on envelope type byte.
pub fn applyOne(
    _: u64, // entry_idx — we don't track per-row seq in M1
    payload: []const u8,
    ctx_opaque: ?*anyopaque,
) void {
    const ctx: *ApplyCtx = @ptrCast(@alignCast(ctx_opaque.?));

    const env = decodeEnvelope(payload) catch |err| {
        std.log.warn("rove-js apply: envelope decode failed: {s}", .{@errorName(err)});
        return;
    };

    switch (env.type) {
        .writeset => applyWriteSet(ctx, env),
        .log_batch => applyLogBatch(ctx, env),
    }
}

fn applyWriteSet(ctx: *ApplyCtx, env: Envelope) void {
    // Leader-skip: workers already wrote through their own
    // connections before proposing. On the leader, apply is a no-op
    // beyond advancing `committed_seq` (done by the caller).
    if (ctx.raft.isLeader()) return;

    const store = ctx.getKv(env.instance_id) catch |err| {
        std.log.warn(
            "rove-js apply: getKv({s}) failed: {s}",
            .{ env.instance_id, @errorName(err) },
        );
        return;
    };

    kv.applyEncodedWriteSet(store, 0, env.payload) catch |err| {
        std.log.warn(
            "rove-js apply: writeset failed for {s}: {s}",
            .{ env.instance_id, @errorName(err) },
        );
    };
}

fn applyLogBatch(ctx: *ApplyCtx, env: Envelope) void {
    // Leader-skip for the same reason as writesets: on the leader,
    // the worker h2 thread is the sole writer to log.db via its own
    // connection, and running apply on the raft thread would race
    // two NOMUTEX sqlite connections on the same file. Followers
    // don't serve requests, so the raft thread is the sole writer
    // to log.db on followers.
    if (ctx.raft.isLeader()) return;

    const store = ctx.getLog(env.instance_id) catch |err| {
        std.log.warn(
            "rove-js apply: getLog({s}) failed: {s}",
            .{ env.instance_id, @errorName(err) },
        );
        return;
    };

    store.applyBatch(env.payload) catch |err| {
        std.log.warn(
            "rove-js apply: log batch apply failed for {s}: {s}",
            .{ env.instance_id, @errorName(err) },
        );
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "writeset envelope encode/decode round trip" {
    const id = "acme";
    const ws = "ws bytes here";
    const enc = try encodeWriteSetEnvelope(testing.allocator, id, ws);
    defer testing.allocator.free(enc);

    const dec = try decodeEnvelope(enc);
    try testing.expectEqual(EnvelopeType.writeset, dec.type);
    try testing.expectEqualStrings(id, dec.instance_id);
    try testing.expectEqualStrings(ws, dec.payload);
}

test "log batch envelope encode/decode round trip" {
    const id = "acme";
    const batch = "log batch bytes";
    const enc = try encodeLogBatchEnvelope(testing.allocator, id, batch);
    defer testing.allocator.free(enc);

    const dec = try decodeEnvelope(enc);
    try testing.expectEqual(EnvelopeType.log_batch, dec.type);
    try testing.expectEqualStrings(id, dec.instance_id);
    try testing.expectEqualStrings(batch, dec.payload);
}

test "decodeEnvelope rejects truncated input" {
    try testing.expectError(Error.Truncated, decodeEnvelope(""));
    try testing.expectError(Error.Truncated, decodeEnvelope(&[_]u8{0x00}));
    try testing.expectError(Error.Truncated, decodeEnvelope(&[_]u8{ 0x00, 0x00 }));
    // type=0, id_len=5 but no id bytes
    try testing.expectError(
        Error.Truncated,
        decodeEnvelope(&[_]u8{ 0x00, 0x00, 0x05 }),
    );
}

test "decodeEnvelope rejects unknown type" {
    try testing.expectError(
        Error.UnknownEnvelopeType,
        decodeEnvelope(&[_]u8{ 0xFF, 0x00, 0x00 }),
    );
}

test "decodeEnvelope handles empty payload" {
    const enc = try encodeWriteSetEnvelope(testing.allocator, "x", "");
    defer testing.allocator.free(enc);
    const dec = try decodeEnvelope(enc);
    try testing.expectEqual(EnvelopeType.writeset, dec.type);
    try testing.expectEqualStrings("x", dec.instance_id);
    try testing.expectEqualStrings("", dec.payload);
}
