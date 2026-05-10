//! Cluster — multi-store raft library.
//!
//! Owns one raft group (RaftNode) and a set of named KvStores all
//! kept in sync via that group. Applications register envelope types
//! + apply functions; the library handles consensus, log compaction,
//! snapshot tick, and per-store apply-state tracking.
//!
//! ## Why this shape
//!
//! `rove-kv`'s original framing was "one KvStore + one raft group."
//! Reality diverged: Loop46's leader services many SQLite stores
//! (per-tenant `app.db`, singleton `__root__.db`, singleton
//! `schedules.db`) under one raft group. Routing between them lived
//! in Loop46-specific code (`src/js/apply.zig`'s `ApplyCtx`),
//! leaking app concerns into the library namespace.
//!
//! This module lifts the generic pieces of that pattern into the
//! library. See `docs/raft-kv-design.md` for the design discussion.
//!
//! ## What's generic vs application-specific
//!
//! Generic (handled here):
//! - Envelope wire format + decode dispatch.
//! - Built-in writeset envelope (`registerWriteSetEnvelope`):
//!   leader-skip, snapshot-replay filter, `_apply_state` stamp.
//! - Multi-envelope wrapper (`registerMultiEnvelope`): atomic
//!   apply of N inner envelopes per raft entry.
//! - Per-store cache + lazy lifecycle (`openStore` / `getStore` /
//!   `closeStore`).
//! - In-memory `last_applied_idx` mirror per store, used by the
//!   snapshot tick (#1.1) and exposed via `lastApplied`.
//!
//! Application-specific (registered via `registerEnvelope`):
//! - Custom envelope types (e.g., Loop46's schedule envelopes
//!   8/9/10/11) and their apply functions.
//! - Routing policy (which envelope hits which store, when to open
//!   per-tenant stores).
//! - Domain-specific value encodings (apps wrap KvStore in their
//!   own typed APIs).
//!
//! ## Threading
//!
//! `Cluster` lives on the raft thread. Per-store SQLite connections
//! it opens are raft-thread-local (NOMUTEX): the raft thread is the
//! only thread that touches them. Workers / dispatch threads use
//! their own per-tenant stores (separate connections to the same
//! files; SQLite WAL handles the coexistence).

const std = @import("std");
const kvstore = @import("kvstore.zig");
const writeset_mod = @import("writeset.zig");
const raft_node_mod = @import("raft_node.zig");

pub const KvStore = kvstore.KvStore;
pub const RaftNode = raft_node_mod.RaftNode;

pub const Error = error{
    Truncated,
    UnknownEnvelopeType,
    NestedMulti,
    StoreNotOpen,
    Sqlite,
    Io,
    OutOfMemory,
};

pub const MAX_ID_LEN: usize = 256;

// ── Envelope wire format ────────────────────────────────────────────
//
// Stable, library-defined: every envelope is
//
//   [1B type][2B id_len BE][id bytes][payload]
//
// Type 0 is reserved for "writeset against the store named by `id`"
// (the most common case). Type 1 is reserved for the multi-envelope
// wrapper. Types 2-255 are application-defined; applications register
// handlers via `registerEnvelope`.
//
// Pre-#1.0 Loop46 used types 0/2/7/8/9/10/11 directly; under the
// library they collapse to a smaller set:
//   type 0  → writeset (id = store_id; library-builtin)
//   type 1  → multi (library-builtin)
//   type 2+ → app-specific (Loop46 uses 2 for root_writeset,
//             8/9/10/11 for schedule envelopes)
// Apps that ship pre-launch don't need migration; on-disk shape
// is being clean-slated as part of this refactor.

pub const ENVELOPE_TYPE_WRITESET: u8 = 0;
pub const ENVELOPE_TYPE_MULTI: u8 = 1;

pub const Envelope = struct {
    type: u8,
    /// Store id when `type == ENVELOPE_TYPE_WRITESET`. For other
    /// types, application-defined (often empty for cluster-wide
    /// stores like a singleton schedules.db).
    id: []const u8,
    payload: []const u8,
};

pub fn decodeEnvelope(bytes: []const u8) Error!Envelope {
    if (bytes.len < 3) return Error.Truncated;
    const t = bytes[0];
    const id_len = std.mem.readInt(u16, bytes[1..3], .big);
    if (bytes.len < 3 + @as(usize, id_len)) return Error.Truncated;
    return .{
        .type = t,
        .id = bytes[3 .. 3 + id_len],
        .payload = bytes[3 + id_len ..],
    };
}

pub fn encodeEnvelope(
    allocator: std.mem.Allocator,
    t: u8,
    id: []const u8,
    payload: []const u8,
) ![]u8 {
    if (id.len > MAX_ID_LEN) return error.OutOfMemory;
    const total = 1 + 2 + id.len + payload.len;
    const out = try allocator.alloc(u8, total);
    out[0] = t;
    std.mem.writeInt(u16, out[1..3], @intCast(id.len), .big);
    @memcpy(out[3 .. 3 + id.len], id);
    @memcpy(out[3 + id.len ..], payload);
    return out;
}

/// Multi-envelope wrapper payload format:
///   `[u8 count][u32 inner_len LE][inner_envelope_bytes]{count}`
/// Each inner envelope is a complete `[type][id_len][id][payload]`
/// blob. Inner envelopes apply in order; nesting (a `multi` inside
/// a `multi`) panics. The outer envelope's `id` is empty.
pub fn encodeMulti(
    allocator: std.mem.Allocator,
    inner: []const []const u8,
) ![]u8 {
    if (inner.len > 0xff) return error.OutOfMemory;
    var inner_total: usize = 0;
    for (inner) |b| inner_total += 4 + b.len;
    const payload_len = 1 + inner_total;
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    payload[0] = @intCast(inner.len);
    var pos: usize = 1;
    for (inner) |b| {
        std.mem.writeInt(u32, payload[pos..][0..4], @intCast(b.len), .little);
        pos += 4;
        @memcpy(payload[pos..][0..b.len], b);
        pos += b.len;
    }
    // encodeEnvelope copies `payload` into the returned buffer.
    return encodeEnvelope(allocator, ENVELOPE_TYPE_MULTI, "", payload);
}

/// Decode the inner-envelope byte slices from a multi-envelope's
/// payload. Slices alias the input buffer; do not free individually.
pub fn decodeMultiInner(
    allocator: std.mem.Allocator,
    payload: []const u8,
) Error![][]const u8 {
    if (payload.len < 1) return Error.Truncated;
    const count = payload[0];
    const out = allocator.alloc([]const u8, count) catch return Error.OutOfMemory;
    errdefer allocator.free(out);
    var pos: usize = 1;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (payload.len < pos + 4) return Error.Truncated;
        const len = std.mem.readInt(u32, payload[pos..][0..4], .little);
        pos += 4;
        if (payload.len < pos + len) return Error.Truncated;
        out[i] = payload[pos .. pos + len];
        pos += len;
    }
    return out;
}

// ── Store layout ───────────────────────────────────────────────────
//
// Each store lives at `{data_dir}/{store_id}/store.db`. Per-tenant
// stores have id = the tenant id; singleton stores (root, schedules)
// have a chosen-by-the-application id. The library doesn't
// distinguish between the two — they're all stores under a path.

fn storePath(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    store_id: []const u8,
) ![:0]u8 {
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, store_id });
    defer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return std.fmt.allocPrintSentinel(allocator, "{s}/store.db", .{dir}, 0);
}

// ── Envelope registration ──────────────────────────────────────────

pub const ApplyError = error{
    InvalidEnvelope,
    StoreNotOpen,
    Sqlite,
    OutOfMemory,
    Io,
};

/// Application-provided apply function for an envelope type.
/// `entry_idx` is the raft log index of the committed entry.
/// `inside_multi` indicates the envelope was unwrapped from a
/// multi-envelope; handlers can use this to reject multi-only or
/// top-level-only envelopes if needed.
pub const ApplyFn = *const fn (
    cluster: *Cluster,
    env: Envelope,
    entry_idx: u64,
    inside_multi: bool,
    user_ctx: ?*anyopaque,
) ApplyError!void;

pub const EnvelopeRegistration = struct {
    apply: ApplyFn,
    /// When true, the apply function is skipped on the leader —
    /// the worker's `LeaderTxn` already wrote locally before
    /// proposing. Used for the writeset envelope; rare for app
    /// types. The library still bumps the in-memory
    /// `last_applied_idx` mirror on the leader so snapshot tick
    /// works.
    leader_skip: bool = false,
};

// ── Cluster ────────────────────────────────────────────────────────

pub const Config = struct {
    allocator: std.mem.Allocator,
    /// Root directory for all per-store data. Each store gets its
    /// own subdir at `{data_dir}/{store_id}/`. The raft log lives
    /// at `{data_dir}/raft.log.db`.
    data_dir: []const u8,
    /// Pre-constructed raft node. The cluster does not own it
    /// (so the application can wire its own listener / threading).
    /// Caller must arrange for `RaftNode` to call
    /// `Cluster.applyOne` as its opaque-bytes apply callback —
    /// `Cluster.applyCallback` is the ready-to-use function ptr.
    raft: *RaftNode,
    /// Optional user-supplied context pointer threaded through
    /// every `ApplyFn` call. Apps stash their auxiliary state
    /// here (Loop46: schedules_store, schedule_wake, etc.).
    user_ctx: ?*anyopaque = null,
};

pub const Cluster = struct {
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    raft: *RaftNode,
    user_ctx: ?*anyopaque,

    /// Lazy per-store cache (store_id → *KvStore). Keys are
    /// allocator-owned copies. Connections are raft-thread-local;
    /// see module docs.
    stores: std.StringHashMapUnmanaged(*KvStore) = .empty,

    /// In-memory mirror of every store's
    /// `_apply_state.last_applied_raft_idx`. Owns its own keys
    /// (separate allocations from `stores`'s keys) so
    /// `markApplied` (the leader-side fast path) can populate it
    /// without opening the store. See snapshot tick in
    /// `loop46/snapshot.zig`.
    apply_idx: std.StringHashMapUnmanaged(u64) = .empty,

    /// Envelope-type → handler dispatch table. 256 entries (one
    /// per byte). Library populates entries 0 + 1 in `init`
    /// (writeset + multi); applications register the rest via
    /// `registerEnvelope`.
    handlers: [256]?EnvelopeRegistration = [_]?EnvelopeRegistration{null} ** 256,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !*Cluster {
        const self = try allocator.create(Cluster);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .data_dir = cfg.data_dir,
            .raft = cfg.raft,
            .user_ctx = cfg.user_ctx,
        };
        // Built-in handlers.
        self.handlers[ENVELOPE_TYPE_WRITESET] = .{
            .apply = applyWriteSet,
            .leader_skip = true,
        };
        self.handlers[ENVELOPE_TYPE_MULTI] = .{
            .apply = applyMulti,
            .leader_skip = false,
        };
        return self;
    }

    pub fn deinit(self: *Cluster) void {
        // apply_idx owns its keys independently.
        var idx_it = self.apply_idx.iterator();
        while (idx_it.next()) |e| self.allocator.free(e.key_ptr.*);
        self.apply_idx.deinit(self.allocator);

        var s_it = self.stores.iterator();
        while (s_it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.*.close();
        }
        self.stores.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Register an apply handler for an envelope type byte. Types
    /// 0 and 1 are reserved for the library (writeset, multi);
    /// attempting to override them returns `error.OutOfMemory` as
    /// a stand-in for "reserved" (will refine when the error set
    /// is more specific).
    pub fn registerEnvelope(
        self: *Cluster,
        type_byte: u8,
        registration: EnvelopeRegistration,
    ) !void {
        if (type_byte == ENVELOPE_TYPE_WRITESET or type_byte == ENVELOPE_TYPE_MULTI) {
            return error.OutOfMemory; // "reserved" — caller picks another type byte
        }
        self.handlers[type_byte] = registration;
    }

    // ── Store lifecycle ────────────────────────────────────────

    /// Lazily open a store. Idempotent: subsequent calls return the
    /// cached pointer. Pointer is stable for the cluster's lifetime
    /// (until `closeStore` or `deinit`).
    pub fn openStore(self: *Cluster, store_id: []const u8) !*KvStore {
        if (self.stores.get(store_id)) |existing| return existing;

        const path = try storePath(self.allocator, self.data_dir, store_id);
        defer self.allocator.free(path);

        const store = try KvStore.open(self.allocator, path);
        errdefer store.close();

        const id_copy = try self.allocator.dupe(u8, store_id);
        errdefer self.allocator.free(id_copy);
        try self.stores.put(self.allocator, id_copy, store);

        // Seed the apply_idx mirror from disk if the leader-side
        // fast path hasn't already populated it.
        if (self.apply_idx.getPtr(store_id) == null) {
            const seeded = store.lastAppliedRaftIdx() catch 0;
            const idx_id = try self.allocator.dupe(u8, store_id);
            errdefer self.allocator.free(idx_id);
            try self.apply_idx.put(self.allocator, idx_id, seeded);
        }

        return store;
    }

    pub fn getStore(self: *Cluster, store_id: []const u8) ?*KvStore {
        return self.stores.get(store_id);
    }

    pub fn closeStore(self: *Cluster, store_id: []const u8) void {
        if (self.stores.fetchRemove(store_id)) |kv| {
            self.allocator.free(kv.key);
            kv.value.close();
        }
    }

    // ── Apply-state tracking ───────────────────────────────────

    /// Bump the in-memory `last_applied_idx` mirror after a
    /// successful follower apply. Expects `openStore` to have
    /// populated the entry already.
    pub fn noteApplied(self: *Cluster, store_id: []const u8, idx: u64) void {
        if (self.apply_idx.getPtr(store_id)) |slot| slot.* = idx;
    }

    /// Leader-side fast path: bump the mirror WITHOUT opening the
    /// store. The leader's worker already wrote rows via its own
    /// connection; we don't want a second writer on the same file.
    /// Snapshot tick opens the connection lazily and stamps
    /// `_apply_state` once per pass.
    pub fn markApplied(self: *Cluster, store_id: []const u8, idx: u64) !void {
        if (self.apply_idx.getPtr(store_id)) |slot| {
            slot.* = idx;
            return;
        }
        const id_copy = try self.allocator.dupe(u8, store_id);
        errdefer self.allocator.free(id_copy);
        try self.apply_idx.put(self.allocator, id_copy, idx);
    }

    /// Read the in-memory mirror. Returns null when this cluster
    /// has never seen the named store applied to.
    pub fn lastApplied(self: *const Cluster, store_id: []const u8) ?u64 {
        return self.apply_idx.get(store_id);
    }

    // ── Apply dispatch ─────────────────────────────────────────

    /// Hand-off function for `RaftNode.opaque_bytes` apply mode.
    /// Wire the pointer to your raft init's `apply.opaque_bytes
    /// .apply_fn`; the cluster pointer goes in `apply.opaque_bytes
    /// .ctx`.
    pub fn applyCallback(
        entry_idx: u64,
        bytes: []const u8,
        ctx_opaque: ?*anyopaque,
    ) void {
        const self: *Cluster = @ptrCast(@alignCast(ctx_opaque.?));
        self.applyOne(entry_idx, bytes) catch |err| {
            // Apply errors are programming bugs (envelope decode,
            // missing handler, etc.) — escalate, don't silently
            // swallow. Apps with more nuanced error categorization
            // can wrap their handlers and panic from inside.
            std.debug.panic("cluster.applyOne: {s}", .{@errorName(err)});
        };
    }

    pub fn applyOne(self: *Cluster, entry_idx: u64, bytes: []const u8) !void {
        const env = try decodeEnvelope(bytes);
        try self.dispatch(env, entry_idx, false);
    }

    fn dispatch(
        self: *Cluster,
        env: Envelope,
        entry_idx: u64,
        inside_multi: bool,
    ) !void {
        const reg = self.handlers[env.type] orelse return Error.UnknownEnvelopeType;
        if (reg.leader_skip and self.raft.isLeader()) {
            // Leader-side fast path: just bump the mirror; the
            // app already wrote locally. Note: only meaningful for
            // writeset-shaped envelopes that target a specific
            // store. Apps that set leader_skip = true for an
            // app-specific envelope take responsibility for the
            // mirror semantics.
            if (env.type == ENVELOPE_TYPE_WRITESET) {
                try self.markApplied(env.id, entry_idx);
                return;
            }
            // Other leader-skip handlers: skip silently (app
            // handler provides whatever leader-side accounting
            // is needed via its own state).
            return;
        }
        try reg.apply(self, env, entry_idx, inside_multi, self.user_ctx);
    }

    // ── Built-in: writeset envelope ────────────────────────────

    fn applyWriteSet(
        cluster: *Cluster,
        env: Envelope,
        entry_idx: u64,
        inside_multi: bool,
        _: ?*anyopaque,
    ) ApplyError!void {
        _ = inside_multi;

        // Follower path: open the target store, snapshot-replay
        // filter, then apply. Stamp `_apply_state` atomically
        // inside `applyEncodedWriteSet`.
        const store = cluster.openStore(env.id) catch |err| switch (err) {
            error.OutOfMemory => return ApplyError.OutOfMemory,
            else => return ApplyError.Sqlite,
        };

        const last = store.lastAppliedRaftIdx() catch return ApplyError.Sqlite;
        if (entry_idx <= last) return;

        writeset_mod.applyEncoded(store, 0, env.payload, entry_idx) catch
            return ApplyError.Sqlite;
        cluster.noteApplied(env.id, entry_idx);
    }

    // ── Built-in: multi-envelope wrapper ──────────────────────

    fn applyMulti(
        cluster: *Cluster,
        env: Envelope,
        entry_idx: u64,
        inside_multi: bool,
        _: ?*anyopaque,
    ) ApplyError!void {
        if (inside_multi) {
            // Nested multi-envelope. Caller's responsibility to
            // never produce one; library refuses.
            return ApplyError.InvalidEnvelope;
        }
        const inner = decodeMultiInner(cluster.allocator, env.payload) catch {
            return ApplyError.InvalidEnvelope;
        };
        defer cluster.allocator.free(inner);

        for (inner) |inner_bytes| {
            const inner_env = decodeEnvelope(inner_bytes) catch
                return ApplyError.InvalidEnvelope;
            cluster.dispatch(inner_env, entry_idx, true) catch |err| switch (err) {
                Error.UnknownEnvelopeType => return ApplyError.InvalidEnvelope,
                Error.NestedMulti => return ApplyError.InvalidEnvelope,
                else => |e| {
                    // Error.Truncated, OutOfMemory, etc. — coerce.
                    _ = e;
                    return ApplyError.InvalidEnvelope;
                },
            };
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "envelope encode + decode round-trips" {
    const out = try encodeEnvelope(testing.allocator, 7, "acme", "hello");
    defer testing.allocator.free(out);

    const env = try decodeEnvelope(out);
    try testing.expectEqual(@as(u8, 7), env.type);
    try testing.expectEqualStrings("acme", env.id);
    try testing.expectEqualStrings("hello", env.payload);
}

test "envelope decode rejects truncated payload" {
    try testing.expectError(Error.Truncated, decodeEnvelope(&[_]u8{0}));
    try testing.expectError(Error.Truncated, decodeEnvelope(&[_]u8{ 0, 0, 5 }));
}

test "multi encode + decode round-trips" {
    const e1 = try encodeEnvelope(testing.allocator, 0, "tenant_a", "payload_a");
    defer testing.allocator.free(e1);
    const e2 = try encodeEnvelope(testing.allocator, 5, "", "payload_b");
    defer testing.allocator.free(e2);

    const inners = [_][]const u8{ e1, e2 };
    const wrapped = try encodeMulti(testing.allocator, &inners);
    defer testing.allocator.free(wrapped);

    const outer = try decodeEnvelope(wrapped);
    try testing.expectEqual(@as(u8, ENVELOPE_TYPE_MULTI), outer.type);
    try testing.expectEqualStrings("", outer.id);

    const decoded = try decodeMultiInner(testing.allocator, outer.payload);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(@as(usize, 2), decoded.len);
    try testing.expectEqualSlices(u8, e1, decoded[0]);
    try testing.expectEqualSlices(u8, e2, decoded[1]);
}

test "register envelope rejects reserved types" {
    // Stub Cluster for the test — we only need handlers + raft set.
    // raft pointer can be undefined here because no apply path runs.
    var c = Cluster{
        .allocator = testing.allocator,
        .data_dir = "",
        .raft = undefined,
        .user_ctx = null,
    };

    const fake_handler: ApplyFn = struct {
        fn f(_: *Cluster, _: Envelope, _: u64, _: bool, _: ?*anyopaque) ApplyError!void {}
    }.f;

    try testing.expectError(error.OutOfMemory, c.registerEnvelope(
        ENVELOPE_TYPE_WRITESET,
        .{ .apply = fake_handler },
    ));
    try testing.expectError(error.OutOfMemory, c.registerEnvelope(
        ENVELOPE_TYPE_MULTI,
        .{ .apply = fake_handler },
    ));
    // Non-reserved type is fine.
    try c.registerEnvelope(42, .{ .apply = fake_handler });
    try testing.expect(c.handlers[42] != null);
}
