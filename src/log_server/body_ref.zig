// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Resolve one activation's out-of-line input bytes back to bytes.
//!
//! A payload over the inline cap is not copied into the log record: the
//! record keeps a POINTER and the bytes stay where they already are. That
//! is what keeps a record cheap, and it is only honest if every pointer
//! has a reader — a reference nobody can resolve turns a record from
//! expensive-and-replayable into cheap-and-unreplayable, and the payload
//! then presents to a replay as an empty value rather than a refusal.
//! This module is that reader. It is the one place that knows all three
//! pointer shapes a tape entry can carry (`locate`), and the one place
//! that turns each into bytes (`resolve`).
//!
//! **Callers address a payload by `(record, channel, entry index)`, never
//! by a raw `BodyRef`.** That is a confinement property,
//! not a convenience. The body pool is cross-tenant by construction — one
//! object packs many tenants' bodies so the S3 request cost amortises
//! (the blob coordinator / chunk spool,
//! `docs/architecture/routing-and-ingress.md`) — so a door that accepted a
//! caller-supplied batch and offset would let anyone past the tenant gate
//! read a neighbour's bytes by walking offsets. Deriving the reference
//! server-side, from a record the caller is already entitled to read,
//! makes that request unrepresentable instead of leaving it to an
//! entitlement check to catch.
//!
//! The three shapes, and why each exists:
//!
//!   - **carried** — the bytes ride on the tape entry. At or under the
//!     inline cap the raft entry's own fsync is the durability substrate,
//!     so there is nothing to point at.
//!   - **pool** — a slice of a content-addressed `_pool/` object. Bodies
//!     that came from outside and have no other home.
//!   - **content** — a slice of one of the tenant's content-addressed
//!     objects. Bytes that are already stored, immutably, under their own
//!     hash; copying them onto the tape would write a second permanent
//!     copy of an object the tenant already pays for.

const std = @import("std");
const tape_mod = @import("rove-tape");
const bodies_mod = @import("rove-bodies");
const batch_store_mod = @import("batch_store.zig");

pub const Error = error{
    /// The record JSON did not parse, or `tapes` was not an object.
    BadRecordJson,
    /// The record carries no tape for the requested channel.
    ChannelNotCaptured,
    /// The channel has fewer entries than the requested index.
    NoSuchEntry,
    /// The entry exists but records the payload as nothing — neither
    /// bytes nor a resolvable pointer. This is the metadata-only fate,
    /// and it is reported rather than served as empty.
    NotRecorded,
    /// The referenced object is no longer in storage (evicted, or a
    /// retention window that has passed).
    Gone,
    /// The reference names more bytes than we are willing to buffer.
    TooLarge,
    /// The pointer is internally inconsistent — a slice that cannot be a
    /// slice of any object, e.g. a content reference with a hash that is
    /// not 64 hex characters.
    MalformedRef,
};

/// Ceiling on a single resolution. The inbound body cap
/// (`h2.conn_state.MAX_BODY_BYTES`) and the coordinator's per-batch cap
/// (`blob.coordinator.Config.max_batch_bytes`) are both 16 MiB, so no
/// legitimately-recorded payload exceeds this; a reference that claims
/// more is malformed, and buffering it would be the fail-loud rule's
/// inverse — an OOM instead of an error.
pub const MAX_RESOLVE_BYTES: u32 = 16 * 1024 * 1024;

/// The tape channels whose entries can carry an out-of-line payload.
/// `kv`, `module` and `request_reads` never do — their values are always
/// carried, so there is nothing here to address.
pub const Channel = enum {
    trigger_payload,
    fetch_responses,

    /// Parse the channel name as it appears in a request path. Returns
    /// null on anything else — including a channel that exists on the tape
    /// but carries no payload the door can serve (`kv`, `module`,
    /// `request_reads`, and `activation`, whose blob rides the raft entry
    /// and is never flushed), which the door reports as a malformed
    /// ADDRESS (400) rather than a missing resource (404). The split is worth keeping: 400 means the caller
    /// asked the wrong question, 404 means the question was well formed
    /// and the answer is nothing. Never a silent fallback to a default
    /// channel.
    pub fn fromPath(s: []const u8) ?Channel {
        if (std.mem.eql(u8, s, "trigger_payload")) return .trigger_payload;
        if (std.mem.eql(u8, s, "fetch_responses")) return .fetch_responses;
        return null;
    }

    /// The record's base64 field holding this channel's serialized tape
    /// (`log.TapePayloads` → `flush_writer`'s ndjson).
    pub fn recordField(self: Channel) []const u8 {
        return switch (self) {
            .trigger_payload => "trigger_payload_tape_b64",
            .fetch_responses => "fetch_responses_tape_b64",
        };
    }

    /// The matching `rove-tape` channel, for the parsed tape's own
    /// self-check.
    pub fn tapeChannel(self: Channel) tape_mod.Channel {
        return switch (self) {
            .trigger_payload => .trigger_payload,
            .fetch_responses => .fetch_responses,
        };
    }
};

/// Where one entry's bytes actually live. Borrows from the parsed tape
/// for the `carried` case, so the tape must outlive the `Ref`.
pub const Ref = union(enum) {
    /// The bytes are on the tape entry itself — nothing to fetch.
    carried: []const u8,
    /// A slice of a cross-tenant body-pool object. The ref names the
    /// object (stamp + digest) as well as the extent, so the resolver
    /// rebuilds the key without a lookup.
    pool: bodies_mod.BodyRef,
    /// A slice of one of this tenant's content-addressed objects. `hash`
    /// is 64 hex chars; the slice is `(byte_offset, len)` INTO the named
    /// object, so the reconstruction key is the triple.
    content: struct { hash: []const u8, offset: u64, len: u32 },
    /// The entry records an event that genuinely has no payload — a
    /// terminal-only fetch chunk (a transport error, a stream-mode FIN).
    /// Distinct from `Error.NotRecorded`: this is "there were no bytes",
    /// not "there were bytes and we kept none of them".
    empty,
};

/// Classify one tape entry's payload. Pure — no I/O, no allocation.
///
/// Order matters. Carried bytes win over any pointer because an entry
/// that has both is inline-with-a-length-stamp, not a reference; and the
/// content reference is checked before the pool because a content-
/// addressed chunk deliberately names no pool object (that is the whole
/// point of referencing it).
pub fn locate(entry: tape_mod.Entry) Error!Ref {
    switch (entry) {
        .trigger_payload => |t| {
            if (t.inline_bytes.len > 0) return .{ .carried = t.inline_bytes };
            if (!t.body_ref.isNone()) {
                if (t.body_ref.len > MAX_RESOLVE_BYTES) return Error.TooLarge;
                return .{ .pool = t.body_ref };
            }
            // No bytes and no pointer. A trigger_payload entry always had
            // a payload — an inbound body or a ctx envelope — so unlike a
            // fetch chunk there is no legitimate empty case here.
            return Error.NotRecorded;
        },
        .fetch_responses => |f| {
            if (f.inline_bytes.len > 0) return .{ .carried = f.inline_bytes };
            if (f.content_hash.len > 0) {
                if (f.content_hash.len != 64 or !isHex(f.content_hash))
                    return Error.MalformedRef;
                if (f.body_ref.len == 0) return Error.NotRecorded;
                if (f.body_ref.len > MAX_RESOLVE_BYTES) return Error.TooLarge;
                return .{ .content = .{
                    .hash = f.content_hash,
                    .offset = f.byte_offset,
                    .len = f.body_ref.len,
                } };
            }
            if (!f.body_ref.isNone()) {
                if (f.body_ref.len > MAX_RESOLVE_BYTES) return Error.TooLarge;
                return .{ .pool = f.body_ref };
            }
            // A terminal-only event legitimately has no bytes: it closes
            // the chain with a seq + status and nothing else. A non-zero
            // length with no home is the metadata-only fate instead — the
            // entry claims a payload it did not keep.
            if (f.body_ref.len == 0) return .empty;
            return Error.NotRecorded;
        },
        else => return Error.ChannelNotCaptured,
    }
}

// ── Key construction ───────────────────────────────────────────────────
//
// Both key families are relative to the CONTENT store's prefix — the
// `S3_KEY_PREFIX_BASE` the worker's blob backends and the body pool share
// — NOT the log store's `LOG_S3_KEY_PREFIX`. They are different prefixes
// and the door needs a handle on the former; see `Config.content_store`
// in `standalone.zig`.

/// `_pool/{written_unix_ms:0>13}-{digest_hex}` — the object a `BodyRef`
/// names. `bodies.pool_object` is the authority for the shape; the stamp
/// leads so a sweep's lexical LIST walks the pool in write order.
pub fn poolKeyBuf(ref: bodies_mod.BodyRef, buf: *[bodies_mod.POOL_KEY_LEN]u8) []const u8 {
    return ref.key(buf);
}

/// The two content-addressed homes a hash can name, in the order the
/// resolver tries them. The tape entry does not record WHICH — a chunk
/// knows it is content-addressed, not which pool it came from — so the
/// resolver probes both. That is sound rather than sloppy: both prefixes
/// are inside the one tenant's own storage, so neither outcome crosses a
/// confinement boundary, and the objects are addressed by the sha256 of
/// their own bytes, so a hash cannot name different bytes in the two.
pub const CONTENT_SUBDIRS = [_][]const u8{ "app-blobs", "file-blobs" };

/// `{tenant}/{subdir}/{hash}`. Caller supplies a buffer; the longest form
/// is bounded by the tenant id (validated upstream) plus a 64-char hash.
pub fn contentKey(
    buf: []u8,
    tenant_id: []const u8,
    subdir: []const u8,
    hash: []const u8,
) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ tenant_id, subdir, hash });
}

// ── Resolution ─────────────────────────────────────────────────────────

/// Fetch the bytes a `Ref` names. Returns owned bytes the caller frees,
/// or borrows nothing — the `carried` case is duped so every caller has
/// one ownership rule rather than two.
///
/// `store` must be prefixed at the content base (see the key-construction
/// note above). `tenant_id` scopes the content-addressed probe; it is
/// unused for a pool reference, whose key is cross-tenant by design and
/// whose confinement comes from the caller having derived it from a
/// record it may read.
pub fn resolve(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    tenant_id: []const u8,
    ref: Ref,
) ![]u8 {
    switch (ref) {
        .carried => |bytes| return allocator.dupe(u8, bytes),
        .empty => return allocator.alloc(u8, 0),
        .pool => |p| {
            var key_buf: [bodies_mod.POOL_KEY_LEN]u8 = undefined;
            const key = poolKeyBuf(p, &key_buf);
            const bytes = store.getRange(key, p.offset, p.len, allocator) catch |err| {
                return mapStoreError(err);
            };
            errdefer allocator.free(bytes);
            try requireFullSlice(bytes, p.len);
            return bytes;
        },
        .content => |c| {
            // Probe each home in turn. Only a genuine "not here" advances
            // to the next one — an I/O fault must not be reported as a
            // missing object, or an outage reads as an evicted blob.
            var last_err: anyerror = Error.Gone;
            for (CONTENT_SUBDIRS) |subdir| {
                var key_buf: [512]u8 = undefined;
                const key = contentKey(&key_buf, tenant_id, subdir, c.hash) catch
                    return Error.MalformedRef;
                if (store.getRange(key, c.offset, c.len, allocator)) |bytes| {
                    errdefer allocator.free(bytes);
                    try requireFullSlice(bytes, c.len);
                    return bytes;
                } else |err| {
                    const mapped = mapStoreError(err);
                    if (mapped != Error.Gone) return mapped;
                    last_err = mapped;
                }
            }
            return last_err;
        },
    }
}

/// A range read that comes back SHORT is `Gone`, never a success.
///
/// Object storage answers a range beyond an object's end with whatever
/// it has, so a pool object that was rewritten or truncated under us
/// returns a prefix of the payload rather than an error. Serving that
/// prefix would be the exact failure this module exists to prevent,
/// one layer down: a partial input presenting as the whole one.
fn requireFullSlice(bytes: []const u8, want: u32) Error!void {
    if (bytes.len != want) return Error.Gone;
}

/// A missing object is `Gone`, not a server fault: the reference was
/// well formed and the record was readable, so the honest report is that
/// the bytes are no longer there.
fn mapStoreError(err: anyerror) anyerror {
    return switch (err) {
        batch_store_mod.Error.NotFound => Error.Gone,
        else => err,
    };
}

fn isHex(s: []const u8) bool {
    for (s) |ch| switch (ch) {
        '0'...'9', 'a'...'f', 'A'...'F' => {},
        else => return false,
    };
    return true;
}

// ── Record → tape ──────────────────────────────────────────────────────

/// Decode one channel's serialized tape out of a record's stored JSON
/// (the body `/show` returns verbatim). Returns null when the record
/// carries no tape for that channel — which is a real answer, not an
/// error: a request with no body records no `trigger_payload`.
///
/// Caller owns the returned bytes.
pub fn tapeFromRecordJson(
    allocator: std.mem.Allocator,
    record_json: []const u8,
    channel: Channel,
) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, record_json, .{}) catch
        return Error.BadRecordJson;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return Error.BadRecordJson,
    };
    const tapes = switch (obj.get("tapes") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const b64 = switch (tapes.get(channel.recordField()) orelse return null) {
        .string => |s| s,
        else => return null, // JSON null = not captured
    };
    const dec_len = std.base64.standard.Decoder.calcSizeForSlice(b64) catch
        return Error.BadRecordJson;
    const out = try allocator.alloc(u8, dec_len);
    errdefer allocator.free(out);
    std.base64.standard.Decoder.decode(out, b64) catch return Error.BadRecordJson;
    return out;
}

/// How a payload was reached. Reported alongside the bytes so a reader
/// can distinguish "small enough to ride along" from "fetched out of the
/// pool" — and, more importantly, so a UI has something true to say when
/// resolution fails instead of rendering an empty body as if it were the
/// real one.
pub const Source = enum {
    carried,
    pool,
    content,
    empty,

    pub fn ofRef(ref: Ref) Source {
        return switch (ref) {
            .carried => .carried,
            .pool => .pool,
            .content => .content,
            .empty => .empty,
        };
    }

    pub fn name(self: Source) []const u8 {
        return @tagName(self);
    }
};

/// A resolved payload: the bytes plus the verdict on how they were found.
pub const Resolved = struct {
    bytes: []u8,
    source: Source,

    pub fn deinit(self: *Resolved, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// The whole read path, end to end: record JSON + channel + entry index →
/// bytes plus the verdict on where they came from.
///
/// This is what the door calls, and keeping it in one function is what
/// lets the door's handler stay a status-code mapping rather than a
/// second implementation of the resolution rules.
pub fn resolveFromRecord(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    tenant_id: []const u8,
    record_json: []const u8,
    channel: Channel,
    index: u32,
) !Resolved {
    const tape_bytes = (try tapeFromRecordJson(allocator, record_json, channel)) orelse
        return Error.ChannelNotCaptured;
    defer allocator.free(tape_bytes);

    var parsed = tape_mod.parse(allocator, tape_bytes) catch |err| switch (err) {
        // A tape recorded under a different layout version is not a
        // server fault and not a missing record — say so precisely.
        tape_mod.ParseError.UnsupportedVersion => return Error.BadRecordJson,
        else => return Error.BadRecordJson,
    };
    defer parsed.deinit();

    if (parsed.channel != channel.tapeChannel()) return Error.BadRecordJson;
    if (index >= parsed.entries.len) return Error.NoSuchEntry;

    const ref = try locate(parsed.entries[index]);
    return .{
        .bytes = try resolve(allocator, store, tenant_id, ref),
        .source = Source.ofRef(ref),
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// A pool-backed `BodyRef` for tests. The seed stands in for a sealed
/// object's identity, so two seeds give two distinguishable objects.
fn tPoolRef(seed: u16, offset: u32, len: u32) bodies_mod.BodyRef {
    return .{
        .written_unix_ms = 1_700_000_000_000 + @as(u64, seed),
        .digest = [_]u8{@truncate(seed)} ** bodies_mod.pool_object.DIGEST_LEN,
        .offset = offset,
        .len = len,
    };
}

/// The key `tPoolRef(seed, …)` resolves to, for seeding a store.
fn tPoolKey(buf: *[bodies_mod.POOL_KEY_LEN]u8, seed: u16) []const u8 {
    return tPoolRef(seed, 0, 0).key(buf);
}

test "Channel.fromPath: the two payload channels, and nothing else" {
    try testing.expectEqual(Channel.trigger_payload, Channel.fromPath("trigger_payload").?);
    try testing.expectEqual(Channel.fetch_responses, Channel.fromPath("fetch_responses").?);
    // A channel that exists on the tape but never carries a payload must
    // not resolve — otherwise the door offers an address with no answer.
    try testing.expect(Channel.fromPath("kv") == null);
    try testing.expect(Channel.fromPath("module") == null);
    try testing.expect(Channel.fromPath("request_reads") == null);
    try testing.expect(Channel.fromPath("") == null);
    try testing.expect(Channel.fromPath("trigger_payload/../kv") == null);
}

test "locate: carried bytes win over a length stamp" {
    const e: tape_mod.Entry = .{ .trigger_payload = .{
        .body_ref = bodies_mod.BodyRef.carried(5),
        .inline_bytes = "hello",
    } };
    const ref = try locate(e);
    try testing.expectEqualStrings("hello", ref.carried);
}

test "locate: a spilled trigger payload is a pool slice" {
    const e: tape_mod.Entry = .{ .trigger_payload = .{
        .body_ref = tPoolRef(42, 4096, 100_000),
        .inline_bytes = "",
    } };
    const ref = try locate(e);
    try testing.expect(std.meta.eql(tPoolRef(42, 4096, 100_000), ref.pool));
}

test "locate: a trigger payload with neither bytes nor pointer is NotRecorded" {
    // Never legitimate: an inbound body / ctx envelope always had bytes,
    // so an entry with none is a payload we dropped, not an empty one.
    const e: tape_mod.Entry = .{ .trigger_payload = .{
        .body_ref = bodies_mod.BodyRef.none,
        .inline_bytes = "",
    } };
    try testing.expectError(Error.NotRecorded, locate(e));
}

test "locate: a content-addressed chunk resolves by hash, not by pool" {
    const hash = "a" ** 64;
    const e: tape_mod.Entry = .{ .fetch_responses = .{
        .fetch_id = "f1",
        .seq = 2,
        .byte_offset = 8192,
        .body_ref = bodies_mod.BodyRef.carried(4096),
        .final = false,
        .terminal_status = 0,
        .terminal_ok = false,
        .body_truncated = false,
        .headers = "",
        .inline_bytes = "",
        .content_hash = hash,
    } };
    const ref = try locate(e);
    // The slice is (byte_offset, body_ref.len) into the named object —
    // the reconstruction key is the triple, so the offset comes from the
    // stream position, not from body_ref.offset.
    try testing.expectEqualStrings(hash, ref.content.hash);
    try testing.expectEqual(@as(u64, 8192), ref.content.offset);
    try testing.expectEqual(@as(u32, 4096), ref.content.len);
}

test "locate: a terminal-only fetch entry is empty, not NotRecorded" {
    const e: tape_mod.Entry = .{ .fetch_responses = .{
        .fetch_id = "f1",
        .seq = 3,
        .byte_offset = 12288,
        .body_ref = bodies_mod.BodyRef.none,
        .final = true,
        .terminal_status = 200,
        .terminal_ok = true,
        .body_truncated = false,
        .headers = "",
        .inline_bytes = "",
        .content_hash = "",
    } };
    const ref = try locate(e);
    try testing.expectEqual(Ref.empty, ref);
}

test "locate: a length with no home is the metadata-only fate, reported not served" {
    // This is the shape `worker_log.captureFetchChunkTapes` produced for a
    // large non-static chunk. Serving it as an empty body is exactly the
    // silent-wrongness the resolver exists to stop.
    const e: tape_mod.Entry = .{ .fetch_responses = .{
        .fetch_id = "f1",
        .seq = 0,
        .byte_offset = 0,
        .body_ref = bodies_mod.BodyRef.carried(65536),
        .final = false,
        .terminal_status = 0,
        .terminal_ok = false,
        .body_truncated = false,
        .headers = "",
        .inline_bytes = "",
        .content_hash = "",
    } };
    try testing.expectError(Error.NotRecorded, locate(e));
}

test "locate: a malformed content hash is refused, not probed" {
    const e: tape_mod.Entry = .{ .fetch_responses = .{
        .fetch_id = "f1",
        .seq = 0,
        .byte_offset = 0,
        .body_ref = bodies_mod.BodyRef.carried(16),
        .final = false,
        .terminal_status = 0,
        .terminal_ok = false,
        .body_truncated = false,
        .headers = "",
        .inline_bytes = "",
        .content_hash = "../../etc/passwd",
    } };
    try testing.expectError(Error.MalformedRef, locate(e));

    const bad_hex: tape_mod.Entry = .{ .fetch_responses = .{
        .fetch_id = "f1",
        .seq = 0,
        .byte_offset = 0,
        .body_ref = bodies_mod.BodyRef.carried(16),
        .final = false,
        .terminal_status = 0,
        .terminal_ok = false,
        .body_truncated = false,
        .headers = "",
        .inline_bytes = "",
        .content_hash = "z" ** 64,
    } };
    try testing.expectError(Error.MalformedRef, locate(bad_hex));
}

test "locate: a reference claiming more than the buffer ceiling is TooLarge" {
    const e: tape_mod.Entry = .{ .trigger_payload = .{
        .body_ref = tPoolRef(7, 0, MAX_RESOLVE_BYTES + 1),
        .inline_bytes = "",
    } };
    try testing.expectError(Error.TooLarge, locate(e));
}

test "poolKeyBuf: the cross-tenant pool leaf" {
    var buf: [bodies_mod.POOL_KEY_LEN]u8 = undefined;
    // Stamp first, then the digest — the ordering that lets a sweep LIST
    // lexically and stop at its horizon.
    try testing.expectEqualStrings(
        "_pool/1700000000042-2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a",
        poolKeyBuf(tPoolRef(42, 4096, 100_000), &buf),
    );
}

test "contentKey: tenant-scoped, both homes" {
    var buf: [512]u8 = undefined;
    const hash = "b" ** 64;
    try testing.expectEqualStrings(
        "acme/app-blobs/" ++ ("b" ** 64),
        try contentKey(&buf, "acme", "app-blobs", hash),
    );
    var buf2: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "acme/file-blobs/" ++ ("b" ** 64),
        try contentKey(&buf2, "acme", "file-blobs", hash),
    );
}

test "resolve: a pool slice is range-read out of the cross-tenant object" {
    const a = testing.allocator;
    var mem = try batch_store_mod.MemoryBatchStore.init(a);
    defer mem.deinit();
    const store = mem.batchStore();

    // One pool object packing two tenants' bodies back to back — the
    // arrangement that makes caller-supplied offsets unsafe.
    var key_buf: [bodies_mod.POOL_KEY_LEN]u8 = undefined;
    try store.put(tPoolKey(&key_buf, 9), "AAAAAAAAAABBBBBBBBBB");

    const mine = try resolve(a, store, "acme", .{ .pool = tPoolRef(9, 10, 10) });
    defer a.free(mine);
    try testing.expectEqualStrings("BBBBBBBBBB", mine);
}

test "resolve: a content reference falls through app-blobs to file-blobs" {
    const a = testing.allocator;
    var mem = try batch_store_mod.MemoryBatchStore.init(a);
    defer mem.deinit();
    const store = mem.batchStore();

    const hash = "c" ** 64;
    // A static serve lives in file-blobs; a blob.get lives in app-blobs.
    // The tape records neither, so the resolver must find it either way.
    try store.put("acme/file-blobs/" ++ ("c" ** 64), "0123456789abcdef");

    const bytes = try resolve(a, store, "acme", .{ .content = .{
        .hash = hash,
        .offset = 4,
        .len = 6,
    } });
    defer a.free(bytes);
    try testing.expectEqualStrings("456789", bytes);
}

test "resolve: a missing pool object is Gone, not a fault" {
    const a = testing.allocator;
    var mem = try batch_store_mod.MemoryBatchStore.init(a);
    defer mem.deinit();
    try testing.expectError(
        Error.Gone,
        resolve(a, mem.batchStore(), "acme", .{ .pool = tPoolRef(404, 0, 16) }),
    );
}

test "resolve: carried bytes are duped so callers have one ownership rule" {
    const a = testing.allocator;
    var mem = try batch_store_mod.MemoryBatchStore.init(a);
    defer mem.deinit();
    const bytes = try resolve(a, mem.batchStore(), "acme", .{ .carried = "inline!" });
    defer a.free(bytes);
    try testing.expectEqualStrings("inline!", bytes);
}

test "tapeFromRecordJson: absent tapes, null field, and a real channel" {
    const a = testing.allocator;

    // No `tapes` object at all — a real answer, not an error.
    try testing.expect((try tapeFromRecordJson(a, "{\"status\":200}", .trigger_payload)) == null);

    // Explicit JSON null = not captured.
    const nulled = try tapeFromRecordJson(
        a,
        "{\"tapes\":{\"trigger_payload_tape_b64\":null}}",
        .trigger_payload,
    );
    try testing.expect(nulled == null);

    // A real tape round-trips through base64.
    var t = tape_mod.Tape.init(a, .trigger_payload);
    defer t.deinit();
    try t.appendTriggerPayload(
        tPoolRef(3, 128, 40_000),
        "",
    );
    const raw = try t.serialize(a);
    defer a.free(raw);
    const enc = try a.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
    defer a.free(enc);
    _ = std.base64.standard.Encoder.encode(enc, raw);
    const json = try std.fmt.allocPrint(
        a,
        "{{\"tapes\":{{\"trigger_payload_tape_b64\":\"{s}\"}}}}",
        .{enc},
    );
    defer a.free(json);

    const got = (try tapeFromRecordJson(a, json, .trigger_payload)).?;
    defer a.free(got);
    try testing.expectEqualSlices(u8, raw, got);
}

test "resolveFromRecord: end to end, a spilled body comes back whole" {
    const a = testing.allocator;
    var mem = try batch_store_mod.MemoryBatchStore.init(a);
    defer mem.deinit();
    const store = mem.batchStore();

    // A 40 KB body — over the 16 KiB inline cap, so the record holds only
    // a pointer and the bytes sit in the pool behind another tenant's.
    const body = try a.alloc(u8, 40_000);
    defer a.free(body);
    for (body, 0..) |*b, i| b.* = @intCast('a' + (i % 26));
    const packed_obj = try std.mem.concat(a, u8, &.{ "NEIGHBOUR", body });
    defer a.free(packed_obj);
    var key_buf: [bodies_mod.POOL_KEY_LEN]u8 = undefined;
    try store.put(tPoolKey(&key_buf, 11), packed_obj);

    var t = tape_mod.Tape.init(a, .trigger_payload);
    defer t.deinit();
    try t.appendTriggerPayload(
        tPoolRef(11, "NEIGHBOUR".len, @intCast(body.len)),
        "",
    );
    const raw = try t.serialize(a);
    defer a.free(raw);
    const enc = try a.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
    defer a.free(enc);
    _ = std.base64.standard.Encoder.encode(enc, raw);
    const json = try std.fmt.allocPrint(
        a,
        "{{\"tapes\":{{\"trigger_payload_tape_b64\":\"{s}\"}}}}",
        .{enc},
    );
    defer a.free(json);

    var got = try resolveFromRecord(a, store, "acme", json, .trigger_payload, 0);
    defer got.deinit(a);
    try testing.expectEqualSlices(u8, body, got.bytes);
    // The verdict travels with the bytes: a reader must be able to tell a
    // payload that was fetched out of the pool from one that rode along.
    try testing.expectEqual(Source.pool, got.source);
}

test "resolveFromRecord: an index past the end is NoSuchEntry" {
    const a = testing.allocator;
    var mem = try batch_store_mod.MemoryBatchStore.init(a);
    defer mem.deinit();

    var t = tape_mod.Tape.init(a, .trigger_payload);
    defer t.deinit();
    try t.appendTriggerPayload(
        bodies_mod.BodyRef.carried(2),
        "hi",
    );
    const raw = try t.serialize(a);
    defer a.free(raw);
    const enc = try a.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
    defer a.free(enc);
    _ = std.base64.standard.Encoder.encode(enc, raw);
    const json = try std.fmt.allocPrint(
        a,
        "{{\"tapes\":{{\"trigger_payload_tape_b64\":\"{s}\"}}}}",
        .{enc},
    );
    defer a.free(json);

    try testing.expectError(
        Error.NoSuchEntry,
        resolveFromRecord(a, mem.batchStore(), "acme", json, .trigger_payload, 1),
    );
}

test "resolveFromRecord: asking for a channel the record never captured" {
    const a = testing.allocator;
    var mem = try batch_store_mod.MemoryBatchStore.init(a);
    defer mem.deinit();
    try testing.expectError(
        Error.ChannelNotCaptured,
        resolveFromRecord(a, mem.batchStore(), "acme", "{\"tapes\":{}}", .fetch_responses, 0),
    );
}
