//! Apply callback for the worker's raft state machine.
//!
//! ## Wire format (Phase 3 — type byte added)
//!
//! Every envelope the worker proposes is:
//!
//!   `[1B type][2B id_len BE][id bytes][payload]`
//!
//! `type=0` → writeset (existing path; payload is `WriteSet.encode` bytes)
//! `type=1` → log batch (Phase 3; payload is `LogStore.drainBatch` bytes)
//!
//! The `id` is the tenant `instance_id`. `id_len` caps at 64KB (way
//! more than `MAX_INSTANCE_ID_LEN`). The trailing `payload` is whatever
//! the dispatch callback for that type knows how to decode.
//!
//! ## Dispatch by type
//!
//! `applyOne` reads the type byte first, then routes:
//!
//! - **type=0 writeset**: leader-skips (because the dispatcher's open
//!   `TrackedTxn` already wrote locally), follower replays through
//!   `kv.applyEncodedWriteSet` against the resolved tenant store.
//! - **type=1 log batch**: NOT leader-skipped (logs are not held in any
//!   open transaction). Both leader and followers decode the batch and
//!   write each record into the tenant's local `log.db`. The log
//!   lookup is delegated to a caller-provided function pointer so this
//!   file doesn't have to know about the worker's generic type.
//!
//! ## Threading
//!
//! `applyOne` is invoked by `RaftNode`'s apply callback, which runs on
//! the raft thread. Tenant store handles are also read by the
//! dispatcher from the main h2 thread. We rely on SQLite's default
//! SERIALIZED threading mode (mutex inside the connection) for safety;
//! if we ever drop to MULTI_THREAD mode this needs revisiting.

const std = @import("std");
const kv = @import("rove-kv");
const log_mod = @import("rove-log");
const tenant_mod = @import("rove-tenant");

pub const Error = error{
    Truncated,
    UnknownInstance,
    UnknownEnvelopeType,
    ApplyFailed,
};

pub const MAX_ID_LEN: usize = 256;

pub const EnvelopeType = enum(u8) {
    writeset = 0,
    log_batch = 1,
};

/// Function the worker provides so `applyOne` can resolve a tenant
/// instance_id to the per-tenant `LogStore` without this file needing
/// to know about the `Worker(Options)` generic. Returns null if the
/// tenant doesn't have a log store yet (rare; treated as "drop the
/// batch with a warning" rather than crash).
pub const LogLookupFn = *const fn (ctx: ?*anyopaque, instance_id: []const u8) ?*log_mod.LogStore;

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

/// Apply callback context. Lives at least as long as the worker.
pub const ApplyCtx = struct {
    tenant: *tenant_mod.Tenant,
    /// Used for the leader-skip check on writeset envelopes. Log
    /// envelopes do NOT skip on the leader — see module doc.
    raft: *kv.RaftNode,
    /// Optional log-store lookup. If null, log batch envelopes are
    /// dropped with a warning. The worker sets this after `Worker.create`.
    log_lookup: ?LogLookupFn = null,
    log_lookup_ctx: ?*anyopaque = null,
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
    // Leader-skip: the h2-side TrackedTxn already holds the writes
    // and will commit them when `drainRaftPending` observes the seq
    // advance. Running the apply here would deadlock on the write lock.
    if (ctx.raft.isLeader()) return;

    const inst = ctx.tenant.instances.get(env.instance_id) orelse {
        std.log.warn(
            "rove-js apply: unknown instance {s} (was it created before the raft thread started?)",
            .{env.instance_id},
        );
        return;
    };

    kv.applyEncodedWriteSet(inst.kv, 0, env.payload) catch |err| {
        std.log.warn(
            "rove-js apply: writeset failed for {s}: {s}",
            .{ env.instance_id, @errorName(err) },
        );
    };
}

fn applyLogBatch(ctx: *ApplyCtx, env: Envelope) void {
    // Leader-skip — same reason as `applyWriteSet`. The leader's h2
    // thread is the only writer to its log.db (via captureLog +
    // flushLogs's own local applyBatch call). Running the apply here
    // on the raft thread would race against the h2 thread on the same
    // SQLite connection (kvstore opens with SQLITE_OPEN_NOMUTEX), which
    // is undefined behavior per SQLite's threading docs. Followers
    // have no h2 dispatch touching log.db (the new leader-check in
    // dispatchPending bounces them with 503 before any capture), so
    // their raft thread is safely the sole writer.
    if (ctx.raft.isLeader()) return;

    const lookup = ctx.log_lookup orelse {
        std.log.warn(
            "rove-js apply: log batch dropped — no log_lookup configured (instance={s})",
            .{env.instance_id},
        );
        return;
    };
    const store = lookup(ctx.log_lookup_ctx, env.instance_id) orelse {
        std.log.warn(
            "rove-js apply: log batch dropped — unknown instance {s}",
            .{env.instance_id},
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
