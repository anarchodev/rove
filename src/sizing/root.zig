// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The sizing chain — one derivation from the receiver's buffer down to what
//! one activation may put on a raft entry, and one arithmetic for "how many
//! bytes will this put on the wire".
//!
//! Five layers used to measure the same quantity in four different units.
//! Batch admission summed raw `key.len + value.len`; `Bridge.propose`
//! compared the ENCODED envelope; the writeset's exact `encodedSize` was
//! computed and ignored; and three separate hand-picked `FRAMING` constants
//! stand in for the difference. A layer that DECIDES and a layer that
//! REFUSES must not compare different numbers to the same limit — that is how
//! a reserve larger than a whole entry can sit in the admission path with
//! every test green.
//!
//! Two things live here so that cannot recur:
//!
//! 1. **One unit.** `writeOpBytes` / `writeSetBytes` / `writeSetEnvelopeBytes`
//!    / `entryBytes` are the encoders' own arithmetic, stated once. A caller
//!    that wants "bytes on the wire" calls these; nobody approximates.
//!    Each is bound to its encoder by a round-trip test in the module that
//!    owns the encoder, so a layout change fails the build here.
//!
//! 2. **One derivation.** `RECV_BUF_SIZE` → frame → message → entry →
//!    per-activation budgets → the batch's admission reserve, each computed
//!    from the one above and comptime-asserted. A change anywhere fails the
//!    build rather than surfacing as a co-tenant's election storm.
//!
//! ## The four scopes
//!
//! They are all "bytes" and they are not interchangeable:
//!
//! - **message** — one raft message on the coalesced transport. Bounded by
//!   the receiver's fixed recv buffer; above it there is nowhere to put the
//!   bytes, so the sender drops rather than tears the connection down.
//! - **entry** — one raft log entry, i.e. one envelope. One entry per
//!   message, so this is the message minus raft-rs's protobuf framing.
//! - **batch** — the activations one `dispatchOnce` tick coalesces for one
//!   tenant. A batch is exactly ONE entry: the activations share a
//!   `TrackedTxn` whose writeset commits all-or-nothing, so it cannot be
//!   split across entries the way `proposeMulti` splits an inner list.
//! - **activation** — one handler run. Its writes and the readset recording
//!   its reads both ride the batch's entry.
//!
//! The budgets below partition the ENTRY between those last two: what one
//! activation may spend (`ACTIVATION_RESERVE`) and what the entry keeps free
//! so a second can join it (`BATCH_ROOM_MIN`). The rule they serve — never put
//! a message on the wire we know a priori cannot be received — and why the
//! readset is what yields when both halves cannot fit, are in
//! `docs/architecture/consensus-and-storage.md` under the entry size ceiling.

const std = @import("std");
const reserved = @import("rove-reserved");

// ── the wire chain ───────────────────────────────────────────────────────

/// The receiver's fixed per-connection recv buffer. THE number the whole
/// chain hangs off: nothing fragments, so a frame above this cannot be
/// reassembled at all. `src/kv/raft_net.zig` allocates against it and
/// asserts it matches.
pub const RECV_BUF_SIZE: usize = 512 * 1024;

/// `src/kv/raft_rpc.zig`'s frame header (`[len:u32][crc:u32]`).
pub const RPC_HEADER_BYTES: usize = 8;
/// The coalesced frame's prefix before the records: `[version:u8][count:u32]`.
pub const FRAME_PREFIX_BYTES: usize = 5;
/// Per-record header inside a coalesced frame:
/// `[group_id:u64][epoch:u64][len:u32]`.
pub const RECORD_HDR_BYTES: usize = 20;
/// Reserve for the protobuf framing raft-rs wraps an entry in on its way to
/// a message — a handful of varint fields. Deliberately fat: it is the one
/// term in this chain we do not encode ourselves.
pub const PROTO_HEADROOM: usize = 4096;

pub const MAX_FRAME_BODY: usize = RECV_BUF_SIZE - RPC_HEADER_BYTES - FRAME_PREFIX_BYTES;
pub const MAX_MESSAGE_BYTES: usize = MAX_FRAME_BODY - RECORD_HDR_BYTES;
pub const MAX_ENTRY_BYTES: usize = MAX_MESSAGE_BYTES - PROTO_HEADROOM;

comptime {
    // entry ≤ message ≤ frame body ≤ the receiver's buffer. A broken link
    // here surfaces as a torn peer connection under load, which reads as an
    // election storm and not as a size bug — so fail the build instead.
    std.debug.assert(MAX_ENTRY_BYTES < MAX_MESSAGE_BYTES);
    std.debug.assert(MAX_MESSAGE_BYTES + RECORD_HDR_BYTES <= MAX_FRAME_BODY);
    std.debug.assert(MAX_FRAME_BODY + RPC_HEADER_BYTES + FRAME_PREFIX_BYTES <= RECV_BUF_SIZE);
}

// ── the encoders' arithmetic ─────────────────────────────────────────────
//
// Each constant names the layout it comes from. The owning module asserts
// its encoder agrees (`writeset.zig`, `envelope_codec.zig`, `tape/root.zig`),
// so these cannot drift from the bytes actually written.

/// `kv/envelope_codec.zig`: `[type:u8][id_len:u16]` before the id.
pub const ENVELOPE_HDR_BYTES: usize = 3;
/// `kv/envelope_codec.zig` writeset payload: `[ws_len:u32][rs_len:u32]`.
pub const WS_PAYLOAD_HDR_BYTES: usize = 8;
/// `kv/writeset.zig`: the leading `[op_count:u32]`.
pub const WS_COUNT_BYTES: usize = 4;
/// `kv/writeset.zig` per op: `[op:u8][key_len:u32][value_len:u32]`. A delete
/// writes a zero value length, so it costs the same framing as a put.
pub const WS_OP_BYTES: usize = 9;
/// `tape/root.zig` `encodeReadsetList`: the leading `[count:u32]`.
pub const RS_LIST_COUNT_BYTES: usize = 4;
/// `tape/root.zig` `encodeReadsetList` per blob: `[len:u32]`.
pub const RS_BLOB_HDR_BYTES: usize = 4;
/// `kv/envelope_codec.zig` `encodeMulti`: `[type:u8][id_len:u16][count:u8]`.
pub const MULTI_HDR_BYTES: usize = 4;
/// `kv/envelope_codec.zig` `encodeMulti` per inner: `[len:u32]`.
pub const MULTI_INNER_HDR_BYTES: usize = 4;

/// The longest tenant id an envelope carries (`rove-instance-id`'s
/// `MAX_INSTANCE_ID_LEN`, asserted against the spec in `raft_propose.zig`).
/// Stated rather than imported so this stays a two-import leaf.
pub const MAX_ENVELOPE_ID_BYTES: usize = 64;

/// What one `kv.set` / `kv.delete` puts on the wire. THE unit the write
/// budget is denominated in: an op is never just its key and value, and a
/// budget that ignores the framing is one an entry can still overflow
/// (1000 ops hid 9 KB from admission before this).
pub fn writeOpBytes(key_len: usize, value_len: usize) usize {
    return WS_OP_BYTES + key_len + value_len;
}

/// An encoded writeset, given the summed `writeOpBytes` of its ops.
pub fn writeSetBytes(op_bytes: usize) usize {
    return WS_COUNT_BYTES + op_bytes;
}

/// An encoded `rs_bytes` section, given the blob count and their summed
/// lengths.
pub fn readsetListBytes(blob_count: usize, blob_bytes: usize) usize {
    if (blob_count == 0) return 0; // `encodeReadsetList` returns empty
    return RS_LIST_COUNT_BYTES + blob_count * RS_BLOB_HDR_BYTES + blob_bytes;
}

/// A type-0 writeset envelope, whole.
pub fn writeSetEnvelopeBytes(id_len: usize, ws_bytes: usize, rs_bytes: usize) usize {
    return ENVELOPE_HDR_BYTES + id_len + WS_PAYLOAD_HDR_BYTES + ws_bytes + rs_bytes;
}

/// A type-2 root writeset envelope (no id, no readset section).
pub fn rootEnvelopeBytes(ws_bytes: usize) usize {
    return ENVELOPE_HDR_BYTES + ws_bytes;
}

/// What `proposeMulti` puts on the wire for `inner_count` inner envelopes of
/// `inner_bytes` total. A lone inner is proposed bare — no multi wrapper —
/// which is the common case and worth not over-charging.
pub fn entryBytes(inner_count: usize, inner_bytes: usize) usize {
    if (inner_count == 0) return 0;
    if (inner_count == 1) return inner_bytes;
    return MULTI_HDR_BYTES + inner_count * MULTI_INNER_HDR_BYTES + inner_bytes;
}

/// The framing a SIDE envelope adds to the batch's entry beyond its own
/// writeset ops: the multi inner header plus the envelope header. Charged to
/// the activation that opens the side writeset, so the activation's write
/// budget covers every byte it puts on the entry — including the ones an
/// admin handler's cross-tenant trampoline appends at propose time, which
/// batch admission cannot otherwise see.
pub fn sideEnvelopeFramingBytes(id_len: usize) usize {
    return MULTI_INNER_HDR_BYTES + ENVELOPE_HDR_BYTES + id_len +
        WS_PAYLOAD_HDR_BYTES + WS_COUNT_BYTES;
}

// ── the partition ────────────────────────────────────────────────────────

/// The exact framing an entry spends before any activation's bytes: the multi
/// wrapper and its first inner header, the anchor envelope's header and id,
/// the writeset payload header and op count, the readset list count.
const ENTRY_FRAMING_EXACT: usize =
    MULTI_HDR_BYTES + MULTI_INNER_HDR_BYTES +
    ENVELOPE_HDR_BYTES + MAX_ENVELOPE_ID_BYTES +
    WS_PAYLOAD_HDR_BYTES + WS_COUNT_BYTES + RS_LIST_COUNT_BYTES;

/// What the accounting reserves for that framing. Deliberately above the
/// exact figure: the privileged write path charges a side envelope's framing
/// per WRITE rather than per envelope (it cannot see which write opened one),
/// so the activation's charged total can run one framing past its budget
/// before the next write is refused. The slack absorbs that, and any future
/// term of the same order, instead of making the partition brittle to a byte.
pub const ENTRY_FIXED_BYTES: usize = 1024;

/// What all the activations of one batch may spend between them.
pub const BATCH_PAYLOAD_MAX: usize = MAX_ENTRY_BYTES - ENTRY_FIXED_BYTES;

/// What an entry keeps free so a SECOND activation can join the batch.
///
/// Batching is a stated policy, not a side effect of one constant happening
/// to be smaller than another. This is the policy: a batch admits another
/// activation while the entry still holds a worst-case one, so coalescing is
/// available to the ordinary small-write activation (hundreds fit here) and
/// unavailable to an activation already near its own budget — which would
/// have to ride its own entry anyway.
///
/// It cannot be large while the write budget is: two worst-case activations
/// can never share one entry when either may spend most of it. The room
/// widens on its own if the value cap — and with it the write budget —
/// is renumbered down.
pub const BATCH_ROOM_MIN: usize = 32 * 1024;

/// The readset room every activation is GUARANTEED, whatever else is already
/// in the batch. An activation joining an emptier batch gets more — the
/// propose site cuts the raft copy down to the room the entry actually has
/// (`tape`'s `serializeForEntry`) — but never less than this, because
/// admission reserved it.
pub const READSET_RESERVE: usize =
    BATCH_PAYLOAD_MAX - reserved.KV_WRITE_BYTES_MAX - RS_BLOB_HDR_BYTES - BATCH_ROOM_MIN;

/// What ONE activation may add to the batch's entry: its whole write budget
/// (wire-measured, so the op framing and any side-envelope framing are
/// inside it) plus the readset it is guaranteed. THE admission reserve —
/// the batch stops admitting once the entry no longer holds this.
///
/// Reserving the worst case is what makes the propose-time `EntryTooLarge`
/// backstop unreachable from the dispatch path: an activation admitted here
/// can spend its entire budget and still fit, so a refusal at propose would
/// only ever punish requests that did nothing wrong.
pub const ACTIVATION_RESERVE: usize =
    reserved.KV_WRITE_BYTES_MAX + RS_BLOB_HDR_BYTES + READSET_RESERVE;

comptime {
    // 1. The kv rules are satisfiable together: a value the guard calls legal
    //    must be writable, under a legal key, by an activation that has
    //    written nothing else. The KEY and the op's own framing count too, so
    //    equality here would make the stated value cap unreachable.
    std.debug.assert(writeOpBytes(reserved.KV_KEY_MAX, reserved.KV_VAL_MAX) <=
        reserved.KV_WRITE_BYTES_MAX);
    // 2. The budgets PARTITION the entry. Reads plus writes plus framing for
    //    one activation fit one entry by construction. Two budgets sized
    //    independently against the same entry do not compose: the activation
    //    passes every call-site guard and is refused at propose, after doing
    //    all the work.
    std.debug.assert(ENTRY_FIXED_BYTES + ACTIVATION_RESERVE + BATCH_ROOM_MIN <=
        MAX_ENTRY_BYTES);
    // 3. Batching is possible at all: the room left after a worst-case
    //    activation must hold a real second one, not a rounding error.
    std.debug.assert(BATCH_ROOM_MIN >= 16 * 1024);
    // 4. The readset an activation is guaranteed is worth having. Too small
    //    and the trim becomes the binding constraint on every read-heavy
    //    activation instead of a backstop.
    std.debug.assert(READSET_RESERVE >= 64 * 1024);
    // 5. The framing reserve covers the framing, plus the overshoot the
    //    per-write charge on the privileged path can produce.
    std.debug.assert(ENTRY_FRAMING_EXACT +
        sideEnvelopeFramingBytes(MAX_ENVELOPE_ID_BYTES) <= ENTRY_FIXED_BYTES);
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the chain lands where the transport says it does" {
    // Not a tautology: these are the numbers every producer-side budget is
    // sized against, so a silent change to one of the terms above should
    // fail here rather than in a follower's recv path.
    try testing.expectEqual(@as(usize, 524275), MAX_FRAME_BODY);
    try testing.expectEqual(@as(usize, 524255), MAX_MESSAGE_BYTES);
    try testing.expectEqual(@as(usize, 520159), MAX_ENTRY_BYTES);
}

test "the partition lands where the numbers say it does" {
    // Pinned so a change to any input shows up as a changed number in review,
    // rather than as a quietly different batching or elision regime. With the
    // write budget at 400 KiB of a 520 KiB entry, the readset's guaranteed
    // room is what pays for it — that is the cost the value cap imposes, made
    // visible.
    try testing.expectEqual(@as(usize, 519_135), BATCH_PAYLOAD_MAX);
    try testing.expectEqual(@as(usize, 76_763), READSET_RESERVE);
    try testing.expectEqual(@as(usize, 486_367), ACTIVATION_RESERVE);
}

test "a worst-case activation plus the batch's room is exactly one entry" {
    try testing.expect(ENTRY_FIXED_BYTES + ACTIVATION_RESERVE + BATCH_ROOM_MIN <= MAX_ENTRY_BYTES);
    // And the reserve is not the whole entry. A reserve at or above the
    // entry makes the admission test true at zero accumulated bytes, which
    // silently collapses every batch to one request.
    try testing.expect(ACTIVATION_RESERVE < MAX_ENTRY_BYTES);
}

test "a lone inner is proposed bare, several ride a multi" {
    try testing.expectEqual(@as(usize, 100), entryBytes(1, 100));
    try testing.expectEqual(@as(usize, MULTI_HDR_BYTES + 2 * MULTI_INNER_HDR_BYTES + 200), entryBytes(2, 200));
    try testing.expectEqual(@as(usize, 0), entryBytes(0, 0));
}

test "an empty readset list is empty, not a bare count" {
    // `encodeReadsetList` returns `&.{}` for zero blobs; charging 4 bytes
    // for it would make the accounting disagree with the encoder on every
    // non-handler propose.
    try testing.expectEqual(@as(usize, 0), readsetListBytes(0, 0));
    try testing.expectEqual(@as(usize, 4 + 4 + 50), readsetListBytes(1, 50));
}
