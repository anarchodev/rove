//! Blob upload sessions — `docs/blob-storage-plan.md` P2.
//!
//! A session accumulates bytes across the activations of ONE held
//! chain (`blob.write(bytes)` per activation — typically a streamed
//! `on.fetch`'s chunk resumes) and `blob.seal` turns the accumulated
//! buffer into a single content-addressed PUT through the P1 signing
//! door. Connection-scoped by construction: keyed on
//! `(tenant_id, correlation_id)`, the chain's stable identity.
//!
//! ## P2 shape: bounded single-PUT, not multipart
//!
//! Sessions are a capped RAM buffer (`MAX_SESSION_BYTES`, 64 MiB —
//! above Synapse's 50 MB default media cap, so the reference Matrix
//! deployment fits) sealed with ONE ordinary PUT. S3 multipart
//! (unbounded size, part ETags, temp-key copies, abort lifecycles)
//! is deliberately deferred until a real >cap workload exists
//! ([[feedback_model_simplicity_safety]] — ship one safe semantic).
//! Because nothing reaches S3 before `seal`, abandonment is pure RAM
//! release: a dead chain's session is swept by TTL, no remote state
//! to abort (effect-algebra L2 abandon semantics for free).
//!
//! ## Durability contract
//!
//! `seal` carries NO owed-marker (unlike `blob.put`): the PUT result
//! resumes the held chain at the customer's `{to}` export, and the
//! customer's own kv index write — made after observing `ok` — is
//! the durability commit point. A crash in between means the client
//! saw a failure and re-uploads; content-addressing makes the retry
//! idempotent.
//!
//! ## Why bindings mutate sessions directly (no commit-gate seam)
//!
//! `kv.*`-style rollback isn't needed: a faulted activation kills
//! its held chain (Erlang posture — no resume after a throw), so
//! partially-written session state is unreachable afterward and the
//! TTL sweep reclaims it. Registry `create` is immediate and `seal`
//! uses `destroyImmediate`, so binding-time mutation has no
//! flush-ordering hazards.

const std = @import("std");
const rove = @import("rove");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// The special origin the `blob.*` shims fetch. Lives here (leaf
/// module) so both the fetch engine (which rewrites + signs it) and
/// the seal binding (which constructs the PUT natively) can name it
/// without an import cycle.
pub const BLOB_ORIGIN_PREFIX = "http://rove-blob.internal/";

/// Hard per-session byte cap. 64 MiB covers the reference Matrix
/// media deployment (Synapse default 50 MB) with headroom; raising
/// it is a knob, removing it is the deferred multipart phase.
pub const MAX_SESSION_BYTES: usize = 64 * 1024 * 1024;

/// Concurrent open sessions per tenant. Worst-case per-tenant RAM is
/// `MAX_SESSION_BYTES * MAX_SESSIONS_PER_TENANT`.
pub const MAX_SESSIONS_PER_TENANT: u32 = 2;

/// Idle TTL — a session untouched this long is presumed abandoned
/// (its chain died without sealing) and swept.
pub const IDLE_TTL_NS: i64 = 120 * std.time.ns_per_s;

pub const Error = error{
    /// No request/chain identity to key the session on.
    NoChain,
    /// `seal` (or a write) with no open session for this chain.
    NoSession,
    SessionTooLarge,
    TooManySessions,
    OutOfMemory,
};

/// One open upload session. Component on the worker's
/// `blob_sessions` collection.
pub const Session = struct {
    tenant_id: []u8,
    correlation_id: []u8,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Incremental content hash — updated per `write` so `seal`
    /// never pays a full-buffer hash on the worker thread at once.
    hasher: Sha256,
    last_touch_ns: i64,

    pub fn deinit(allocator: std.mem.Allocator, items: []Session) void {
        for (items) |*item| {
            allocator.free(item.tenant_id);
            allocator.free(item.correlation_id);
            item.buf.deinit(allocator);
        }
    }
};

/// Append bytes to this chain's session, creating it on first write.
/// Returns the session's total byte count after the append.
pub fn write(
    allocator: std.mem.Allocator,
    reg: anytype,
    coll: anytype,
    tenant_id: []const u8,
    corr: []const u8,
    bytes: []const u8,
    now_ns: i64,
) Error!u64 {
    if (corr.len == 0 or tenant_id.len == 0) return Error.NoChain;

    if (findSession(coll, tenant_id, corr) == null) {
        var tenant_count: u32 = 0;
        for (coll.column(Session)) |*s| {
            if (std.mem.eql(u8, s.tenant_id, tenant_id)) tenant_count += 1;
        }
        if (tenant_count >= MAX_SESSIONS_PER_TENANT) return Error.TooManySessions;

        const t_dup = allocator.dupe(u8, tenant_id) catch return Error.OutOfMemory;
        errdefer allocator.free(t_dup);
        const c_dup = allocator.dupe(u8, corr) catch return Error.OutOfMemory;
        errdefer allocator.free(c_dup);
        const ent = reg.create(coll) catch return Error.OutOfMemory;
        reg.set(ent, coll, Session, .{
            .tenant_id = t_dup,
            .correlation_id = c_dup,
            .buf = .empty,
            .hasher = Sha256.init(.{}),
            .last_touch_ns = now_ns,
        }) catch {
            reg.destroyImmediate(ent) catch {};
            return Error.OutOfMemory;
        };
    }

    // Re-find after a possible create (column slices can move on
    // append) — the pointer is only used within this call.
    const s = findSession(coll, tenant_id, corr) orelse return Error.NoSession;
    if (s.buf.items.len + bytes.len > MAX_SESSION_BYTES) return Error.SessionTooLarge;
    s.buf.appendSlice(allocator, bytes) catch return Error.OutOfMemory;
    s.hasher.update(bytes);
    s.last_touch_ns = now_ns;
    return s.buf.items.len;
}

/// A finalized session: the content hash plus the accumulated bytes,
/// ownership transferred to the caller (who hands them to the seal
/// PUT's PendingFetch).
pub const Sealed = struct {
    hash_hex: [64]u8,
    body: []u8,
};

/// Finalize this chain's session: produce the sha256, hand the
/// buffer out, destroy the session entity. A second `seal` (or a
/// `write` after `seal`) finds no session and errors.
pub fn seal(
    allocator: std.mem.Allocator,
    reg: anytype,
    coll: anytype,
    tenant_id: []const u8,
    corr: []const u8,
) Error!Sealed {
    if (corr.len == 0 or tenant_id.len == 0) return Error.NoChain;
    const ents = coll.entitySlice();
    const sessions = coll.column(Session);
    for (ents, sessions) |ent, *s| {
        if (!std.mem.eql(u8, s.tenant_id, tenant_id)) continue;
        if (!std.mem.eql(u8, s.correlation_id, corr)) continue;

        var digest: [32]u8 = undefined;
        s.hasher.final(&digest);
        var hash_hex: [64]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (digest, 0..) |b, i| {
            hash_hex[i * 2] = hex_chars[b >> 4];
            hash_hex[i * 2 + 1] = hex_chars[b & 0x0f];
        }
        const body = s.buf.toOwnedSlice(allocator) catch return Error.OutOfMemory;
        // Component deinit frees tenant/corr and the (now-empty) buf.
        reg.destroyImmediate(ent) catch {};
        return .{ .hash_hex = hash_hex, .body = body };
    }
    return Error.NoSession;
}

/// Reap sessions whose chain died without sealing. Cheap when the
/// collection is empty (the overwhelmingly common case); O(open
/// sessions) otherwise — never O(tenants).
pub fn sweepBlobSessions(worker: anytype) void {
    const ents = worker.blob_sessions.entitySlice();
    if (ents.len == 0) return;
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const allocator = worker.allocator;

    var stale: std.ArrayListUnmanaged(rove.Entity) = .empty;
    defer stale.deinit(allocator);
    const sessions = worker.blob_sessions.column(Session);
    for (ents, sessions) |ent, *s| {
        if (now_ns - s.last_touch_ns > IDLE_TTL_NS) {
            std.log.warn(
                "rove-js blob-session: sweeping idle session tenant={s} bytes={d} (chain died unsealed)",
                .{ s.tenant_id, s.buf.items.len },
            );
            stale.append(allocator, ent) catch return;
        }
    }
    for (stale.items) |ent| worker.h2.reg.destroyImmediate(ent) catch {};
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn findSession(coll: anytype, tenant_id: []const u8, corr: []const u8) ?*Session {
    for (coll.column(Session)) |*s| {
        if (std.mem.eql(u8, s.tenant_id, tenant_id) and
            std.mem.eql(u8, s.correlation_id, corr)) return s;
    }
    return null;
}

const TestRow = rove.Row(&.{Session});
const TestColl = rove.Collection(TestRow, .{});

test "blob session write/seal round-trip matches one-shot sha256" {
    var reg = try rove.Registry.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();
    var coll = try TestColl.init(testing.allocator);
    defer coll.deinit();
    reg.registerCollection(&coll);

    _ = try write(testing.allocator, &reg, &coll, "t1", "c1", "hello ", 1);
    const total = try write(testing.allocator, &reg, &coll, "t1", "c1", "world", 2);
    try testing.expectEqual(@as(u64, 11), total);

    const sealed = try seal(testing.allocator, &reg, &coll, "t1", "c1");
    defer testing.allocator.free(sealed.body);
    try testing.expectEqualStrings("hello world", sealed.body);

    var digest: [32]u8 = undefined;
    Sha256.hash("hello world", &digest, .{});
    var expect_hex: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        expect_hex[i * 2] = hex_chars[b >> 4];
        expect_hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    try testing.expectEqualSlices(u8, &expect_hex, &sealed.hash_hex);

    // Session is gone: a second seal errors, a write starts fresh.
    try testing.expectError(Error.NoSession, seal(testing.allocator, &reg, &coll, "t1", "c1"));
    try testing.expectEqual(@as(usize, 0), coll.entitySlice().len);
}

test "blob session per-tenant cap + isolation" {
    var reg = try rove.Registry.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();
    var coll = try TestColl.init(testing.allocator);
    defer coll.deinit();
    reg.registerCollection(&coll);

    _ = try write(testing.allocator, &reg, &coll, "t1", "c1", "a", 1);
    _ = try write(testing.allocator, &reg, &coll, "t1", "c2", "b", 1);
    try testing.expectError(
        Error.TooManySessions,
        write(testing.allocator, &reg, &coll, "t1", "c3", "c", 1),
    );
    // A different tenant is unaffected; existing sessions still accept.
    _ = try write(testing.allocator, &reg, &coll, "t2", "c1", "d", 1);
    _ = try write(testing.allocator, &reg, &coll, "t1", "c1", "aa", 2);

    // Sessions are tenant-isolated even on equal correlation ids.
    const s1 = try seal(testing.allocator, &reg, &coll, "t1", "c1");
    defer testing.allocator.free(s1.body);
    try testing.expectEqualStrings("aaa", s1.body);
    const s2 = try seal(testing.allocator, &reg, &coll, "t2", "c1");
    defer testing.allocator.free(s2.body);
    try testing.expectEqualStrings("d", s2.body);

    const rest = try seal(testing.allocator, &reg, &coll, "t1", "c2");
    defer testing.allocator.free(rest.body);
}

test "blob session size cap" {
    var reg = try rove.Registry.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();
    var coll = try TestColl.init(testing.allocator);
    defer coll.deinit();
    reg.registerCollection(&coll);

    const chunk = try testing.allocator.alloc(u8, MAX_SESSION_BYTES);
    defer testing.allocator.free(chunk);
    @memset(chunk, 'x');
    _ = try write(testing.allocator, &reg, &coll, "t1", "c1", chunk, 1);
    try testing.expectError(
        Error.SessionTooLarge,
        write(testing.allocator, &reg, &coll, "t1", "c1", "y", 2),
    );
    const sealed = try seal(testing.allocator, &reg, &coll, "t1", "c1");
    testing.allocator.free(sealed.body);
}
