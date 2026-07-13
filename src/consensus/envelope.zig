//! Raft-log envelope codec — the typed byte blob that travels through
//! a tenant's raft group and is decoded at apply time (`node.zig`).
//!
//! The byte layout (`[1B type][2B id_len BE][id][payload]`, the multi
//! wrapper, and the readset-framed type-0 `WriteSetPayload`) lives ONCE
//! in `src/kv/envelope_codec.zig` (std-only, re-exported by `kvlimbs`);
//! this file delegates those primitives and layers the consensus-spine
//! additions on top: the origin-identity `EntryFrame` and the typed
//! `Type` enum whose decode rejects unknown slots loudly. A worker
//! propose (encoded via `apply.zig` → the same codec) applies unchanged
//! on any follower by construction — there is no second implementation
//! to hold in sync.

const std = @import("std");
const codec = @import("kvlimbs").envelope_codec;

/// Single-sourced from the shared codec (enforced on encode only; see
/// its doc there). One value for every encoder — worker and spine.
pub const MAX_ID_LEN: usize = codec.MAX_ID_LEN;

pub const Error = error{
    Truncated,
    IdTooLong,
    UnknownEnvelopeType,
    NestedMulti,
    /// A raft entry did not start with the `ENTRY_FRAME_MAGIC` byte —
    /// every entry is origin-framed at propose, so a bare envelope in
    /// the log is a producer bug (or an unframed entry from an incompatible
    /// format, which a data-dir wipe removes).
    BadEntryFrame,
    OutOfMemory,
};

// ── Entry frame (origin identity) ─────────────────────────────────────
//
// Every proposed raft entry is wrapped in a fixed 17-byte frame BEFORE
// the envelope:
//
//     [1B ENTRY_FRAME_MAGIC][8B origin LE][8B seq LE][envelope bytes]
//
// `origin` is the proposing bridge's per-boot random id and `seq` its
// per-tenant propose ticket — together the entry's IDENTITY. The apply
// path uses them to (a) bind a committed entry to the exact local
// propose awaiting it (the bridge advances `committed_seq` only for
// `origin == its own id`, never by FIFO position — a resurrected
// old-term entry committing after re-election can no longer mis-credit
// a different propose's waiter), and (b) key the worker-overlay store
// skip on true provenance ("THIS node's worker wrote this entry and its
// txn is still live"), not on currently-being-leader — a freshly-elected
// leader catching up on another proposer's entries must WRITE them.
// A random per-boot origin (not the node id) also fences a restarted
// node's WAL replay from colliding with the new incarnation's seqs.
// `origin = 0, seq = 0` marks a hookless propose (tests, bare nodes):
// it matches no bridge, so it is never skipped and never advances a
// watermark.

/// First byte of every framed entry. Deliberately outside the envelope
/// `Type` range (0..=2) so a missing frame fails loud (`BadEntryFrame`)
/// instead of mis-decoding.
pub const ENTRY_FRAME_MAGIC: u8 = 0xF7;

/// Bytes of the frame header preceding the envelope.
pub const ENTRY_FRAME_LEN: usize = 1 + 8 + 8;

pub const EntryFrame = struct {
    /// Proposing bridge's per-boot random id (0 = hookless propose).
    origin: u64,
    /// Proposer's per-tenant seq ticket (0 = hookless propose).
    seq: u64,
    /// The framed envelope bytes; borrows the input.
    env_bytes: []const u8,
};

/// Wrap an encoded envelope in the entry frame. Caller owns the result.
pub fn encodeEntryFrame(
    allocator: std.mem.Allocator,
    origin: u64,
    seq: u64,
    env_bytes: []const u8,
) Error![]u8 {
    const out = allocator.alloc(u8, ENTRY_FRAME_LEN + env_bytes.len) catch return Error.OutOfMemory;
    out[0] = ENTRY_FRAME_MAGIC;
    std.mem.writeInt(u64, out[1..9], origin, .little);
    std.mem.writeInt(u64, out[9..17], seq, .little);
    @memcpy(out[ENTRY_FRAME_LEN..], env_bytes);
    return out;
}

/// Decode the entry frame. `env_bytes` aliases `bytes`. The magic
/// check precedes the length check so an unframed envelope of any
/// length reports `BadEntryFrame`, not `Truncated`.
pub fn decodeEntryFrame(bytes: []const u8) Error!EntryFrame {
    if (bytes.len == 0) return Error.Truncated;
    if (bytes[0] != ENTRY_FRAME_MAGIC) return Error.BadEntryFrame;
    if (bytes.len < ENTRY_FRAME_LEN) return Error.Truncated;
    return .{
        .origin = std.mem.readInt(u64, bytes[1..9], .little),
        .seq = std.mem.readInt(u64, bytes[9..17], .little),
        .env_bytes = bytes[ENTRY_FRAME_LEN..],
    };
}

/// Envelope type byte (wire-frozen numbering). Only the live variants
/// below decode; `decode` rejects any other byte — including the
/// reserved/retired slots 3..=11 — as `UnknownEnvelopeType`, so a stale or
/// unexpected entry surfaces loudly instead of mis-applying.
pub const Type = enum(u8) {
    /// Per-tenant writeset. `id` = tenant store id; payload = the readset-
    /// framed `WriteSetPayload` (the `writeset.WriteSet.encode` bytes plus
    /// an optional readset section).
    writeset = 0,
    /// Multi-envelope wrapper. `id` empty; payload =
    /// `[u8 count]([u32 len LE][inner_envelope]){count}`. Inner
    /// envelopes apply in order; nesting panics (`NestedMulti`).
    multi = 1,
    /// Root writeset — applied to the node-wide `__root__` store.
    /// Producer is the control plane (provisionInstance / admin);
    /// `node.zig`'s apply path routes it to the `__root__` store.
    root_writeset = 2,
};

pub const Envelope = struct {
    type: Type,
    /// Tenant store id for `writeset`; empty for `multi` / `root_writeset`.
    /// Borrowed slice into the decoded buffer.
    id: []const u8,
    /// Borrowed slice into the decoded buffer.
    payload: []const u8,
};

/// Decode the `[1B type][2B id_len BE][id][payload]` header (shared
/// codec) and map the raw type byte onto the typed enum — a retired /
/// unknown slot is `UnknownEnvelopeType`. Returned slices alias
/// `bytes`; valid only while `bytes` lives.
pub fn decode(bytes: []const u8) Error!Envelope {
    const raw = try codec.decodeEnvelope(bytes);
    const t = std.meta.intToEnum(Type, raw.type) catch return Error.UnknownEnvelopeType;
    return .{
        .type = t,
        .id = raw.id,
        .payload = raw.payload,
    };
}

fn encodeTyped(
    allocator: std.mem.Allocator,
    t: Type,
    id: []const u8,
    payload: []const u8,
) Error![]u8 {
    return codec.encodeEnvelope(allocator, @intFromEnum(t), id, payload);
}

/// Type-0 readset-framed payload — single-sourced from the shared codec
/// (`[u32 LE ws_len][ws_bytes][u32 LE rs_len][rs_bytes]`; see the doc
/// there). Re-exported so the spine's apply path (`node.zig`) keeps its
/// natural import.
pub const WriteSetPayload = codec.WriteSetPayload;
pub const decodeWriteSetPayload = codec.decodeWriteSetPayload;
pub const encodeWriteSetPayload = codec.encodeWriteSetPayload;

/// Build a type-0 writeset envelope. `ws_bytes` is the output of
/// `writeset.WriteSet.encode`; it is wrapped in the readset-framed payload
/// (empty readset) so the bytes are wire-identical to a worker propose.
/// Caller owns the returned slice.
pub fn encodeWriteSet(
    allocator: std.mem.Allocator,
    id: []const u8,
    ws_bytes: []const u8,
) Error![]u8 {
    const payload = try encodeWriteSetPayload(allocator, ws_bytes, "");
    defer allocator.free(payload);
    return encodeTyped(allocator, .writeset, id, payload);
}

/// Build a type-2 root writeset envelope (no per-tenant id).
pub fn encodeRootWriteSet(
    allocator: std.mem.Allocator,
    ws_bytes: []const u8,
) Error![]u8 {
    return encodeTyped(allocator, .root_writeset, "", ws_bytes);
}

/// Build a type-1 multi wrapper carrying `inner` already-encoded
/// envelopes (shared codec; `codec.ENVELOPE_TYPE_MULTI` == `Type.multi`).
/// Inner envelopes must not themselves be type-1 (`NestedMulti`).
/// Caller owns the returned slice.
pub fn encodeMulti(
    allocator: std.mem.Allocator,
    inner: []const []const u8,
) Error![]u8 {
    return codec.encodeMulti(allocator, inner);
}

/// Decode the inner-envelope byte slices from a `multi` payload (i.e.
/// `Envelope.payload` where `type == .multi`). Returned slices alias
/// `payload`; caller frees only the outer `[][]const u8` with
/// `allocator.free`.
pub const decodeMultiInner = codec.decodeMultiInner;

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "entry frame round-trips and rejects unframed/truncated bytes" {
    const a = testing.allocator;
    const env = try encodeWriteSet(a, "t", "WS");
    defer a.free(env);

    const framed = try encodeEntryFrame(a, 0xDEAD_BEEF, 42, env);
    defer a.free(framed);
    const f = try decodeEntryFrame(framed);
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF), f.origin);
    try testing.expectEqual(@as(u64, 42), f.seq);
    try testing.expectEqualSlices(u8, env, f.env_bytes);
    // The framed envelope still decodes.
    const dec = try decode(f.env_bytes);
    try testing.expectEqual(Type.writeset, dec.type);

    // A bare (unframed) envelope fails loud — type byte 0 is not the magic.
    try testing.expectError(Error.BadEntryFrame, decodeEntryFrame(env));
    try testing.expectError(Error.Truncated, decodeEntryFrame(framed[0..10]));
}

test "writeset envelope round-trips (readset-framed payload)" {
    const a = testing.allocator;
    const env = try encodeWriteSet(a, "tenant-42", "WSBYTES");
    defer a.free(env);

    const dec = try decode(env);
    try testing.expectEqual(Type.writeset, dec.type);
    try testing.expectEqualStrings("tenant-42", dec.id);
    // The payload is the readset frame; the writeset bytes ride inside it
    // (empty readset) — wire-identical to a worker propose.
    const wp = try decodeWriteSetPayload(dec.payload);
    try testing.expectEqualStrings("WSBYTES", wp.ws_bytes);
    try testing.expectEqual(@as(usize, 0), wp.rs_bytes.len);
}

test "writeset payload carries a non-empty readset" {
    const a = testing.allocator;
    const payload = try encodeWriteSetPayload(a, "WS", "READSET");
    defer a.free(payload);
    const wp = try decodeWriteSetPayload(payload);
    try testing.expectEqualStrings("WS", wp.ws_bytes);
    try testing.expectEqualStrings("READSET", wp.rs_bytes);
}

test "root writeset envelope round-trips with empty id" {
    const a = testing.allocator;
    const env = try encodeRootWriteSet(a, "ROOT");
    defer a.free(env);

    const dec = try decode(env);
    try testing.expectEqual(Type.root_writeset, dec.type);
    try testing.expectEqualStrings("", dec.id);
    try testing.expectEqualStrings("ROOT", dec.payload);
}

test "multi wrapper round-trips and unwraps inner envelopes in order" {
    const a = testing.allocator;
    const e0 = try encodeWriteSet(a, "t0", "first");
    defer a.free(e0);
    const e1 = try encodeWriteSet(a, "t1", "second");
    defer a.free(e1);

    const multi = try encodeMulti(a, &.{ e0, e1 });
    defer a.free(multi);

    const outer = try decode(multi);
    try testing.expectEqual(Type.multi, outer.type);

    const inner = try decodeMultiInner(a, outer.payload);
    defer a.free(inner);
    try testing.expectEqual(@as(usize, 2), inner.len);

    const d0 = try decode(inner[0]);
    try testing.expectEqualStrings("t0", d0.id);
    try testing.expectEqualStrings("first", (try decodeWriteSetPayload(d0.payload)).ws_bytes);
    const d1 = try decode(inner[1]);
    try testing.expectEqualStrings("t1", d1.id);
    try testing.expectEqualStrings("second", (try decodeWriteSetPayload(d1.payload)).ws_bytes);
}

test "decode rejects a retired/unknown type byte" {
    // Type 8 is a reserved/retired slot (a former schedule envelope); must surface loudly.
    var buf = [_]u8{ 8, 0, 0 };
    try testing.expectError(Error.UnknownEnvelopeType, decode(&buf));
}

test "decode rejects truncated headers" {
    try testing.expectError(Error.Truncated, decode(&[_]u8{ 0, 0 }));
    // id_len says 5 but no id bytes follow.
    try testing.expectError(Error.Truncated, decode(&[_]u8{ 0, 0, 5 }));
}

test "encode rejects an over-long id" {
    const a = testing.allocator;
    const big = [_]u8{'x'} ** (MAX_ID_LEN + 1);
    try testing.expectError(Error.IdTooLong, encodeWriteSet(a, &big, "x"));
}
