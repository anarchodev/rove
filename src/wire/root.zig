// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! rove-wire — the CP↔worker wire contracts, each with ONE encode/decode
//! pair shared by every sender and the receiver.
//!
//! Why this module exists (docs/defect-patterns.md class 3): the
//! `/_system/v2-attach` envelope used to exist only as parallel header
//! lists — one in `cp/move.zig`, one in `cp/reconciler.zig`, constants in
//! `js/v2_move.zig`, and four Python copies. Adding a field meant editing
//! every sender; a sender that missed it did not fail — the receiver
//! defaulted, and the storage-incarnation field reaching one sender out of
//! three turned a membership backfill into a node serving an empty tenant.
//! Here the envelope is a struct; a new field is added once, the encoder
//! emits it everywhere, and the decoder decides its absent-semantics in
//! exactly one place — with required fields failing the decode rather than
//! defaulting.

const std = @import("std");
const blob = @import("rove-blob");
const curl = blob.curl;

// ── Header names ──────────────────────────────────────────────────────
// Lowercase (HTTP/2 wire form); libcurl sends names verbatim and HTTP
// headers are case-insensitive, so one spelling serves both directions.

pub const TENANT = "x-rewind-tenant";
pub const INCARNATION = "x-rewind-incarnation";
/// The tenant's keyring root secret, 64 lowercase hex, minted ONCE at
/// birth. Present only on a birth attach; see `AttachEnvelope.secret`.
pub const KEYRING_SECRET = "x-rewind-keyring-secret";
pub const PLAN = "x-rewind-plan";
/// RETIRED (with the buffered bundle path + the atomic baseline attach): a
/// joiner is born EMPTY and its state arrives raft-natively — log
/// replication, or the streamed catch-up whose END_STREAM install carries
/// the baseline. The names are kept only so the decoder can REJECT a stale
/// sender loudly instead of silently birthing a group it thinks is at a
/// baseline it never installed.
pub const BASELINE_INDEX = "x-rewind-baseline-index";
pub const BASELINE_TERM = "x-rewind-baseline-term";
pub const EPOCH = "x-rewind-epoch";
pub const JOIN_AS_LEARNER = "x-rewind-join-as-learner";
pub const VOTERS = "x-rewind-voters";
pub const LEARNERS = "x-rewind-learners";
pub const PEER_ADDRS = "x-rewind-peer-addrs";

/// Wire spelling of "this tenant is on the legacy name-keyed storage
/// layout". An explicit token rather than an empty header value, because
/// the curl sender serializes headers as `"{name}: {value}"` and libcurl
/// treats a header line with an empty value as REMOVAL — an empty-valued
/// header would silently vanish from the wire, and an ABSENT header must
/// stay meaningful (it is a decode error: the sender bypassed the
/// encoder). Cannot collide with a real incarnation: tokens are minted as
/// lowercase hex, and 'l'/'g'/'y' are not hex digits.
pub const INCARNATION_LEGACY = "legacy";

/// Sanity cap on voter/learner id-list length, matching the worker's
/// fixed parse buffers. Clusters are small by construction (cold-multi).
pub const MAX_MEMBER_IDS = 16;

// ── v2-attach: envelope ───────────────────────────────────────────────

/// Every field of the `/_system/v2-attach` envelope. The move secret is
/// NOT here — it is transport auth, checked before dispatch, not part of
/// the attach payload.
pub const AttachEnvelope = struct {
    tenant: []const u8,
    /// Storage-incarnation MARKER spelling: the token, or "" for legacy
    /// (`rove-tenant`'s `Incarnation.marker()`). Required — the encoder
    /// always emits it (as `INCARNATION_LEGACY` when empty) and the
    /// decoder rejects an absent header.
    incarnation: []const u8,
    /// Opaque plan blob; rides provision/move attaches. Absent → receiver
    /// leaves the tenant on the free tier until a live push (non-fatal).
    plan: ?[]const u8 = null,
    /// Birth epoch. Absent → receiver defaults to 1 (provision/move
    /// attaches don't send it).
    epoch: ?u64 = null,
    /// Join an existing group as a non-voting learner (reconciler adds
    /// learner-first). Encoded only when true; absent → false.
    join_as_learner: bool = false,
    /// ConfState / birth-voter set (cluster node-set SSOT). Absent → the
    /// receiver falls back to its env (`REWIND_VOTERS`).
    voters: ?[]const u64 = null,
    learners: ?[]const u64 = null,
    /// Genesis §4d attach-carry: `id@addr,…` of the existing members so a
    /// joiner can ACK the leader. Absent/empty on static clusters.
    peer_addrs: ?[]const u8 = null,
    /// The tenant's keyring root secret as 64 lowercase hex — the HKDF
    /// root whose destruction is the tenant-level (C1) shred.
    ///
    /// Sent ONLY on a birth attach, where one minter fanning the same
    /// bytes to every birth node is what makes the secret agree
    /// cluster-wide; nodes minting independently would key one tenant's
    /// data differently per node, which is a correctness fault rather
    /// than a leak.
    ///
    /// A repair or move attach sends NOTHING here, and that is not an
    /// omission. The CP has no durable copy to resend: storing a key in
    /// the directory would put key material in a raft log, where a
    /// destroyed key stays legible forever and shredding defeats itself
    /// one level down. A late-joining node is meant to get the keyring
    /// from a peer as KEK-sealed ciphertext instead, which is the same
    /// operation as an ordinary shard update (`js/keyring_shard.zig`).
    ///
    /// That pull does not exist yet — the transport is push-only, so
    /// today a node that missed pushes stays short. It is not silent:
    /// such a node measures itself against the minted watermark, finds
    /// itself incomplete, and answers `unverified` rather than reporting
    /// erasure it cannot stand behind (`src/keyring/`).
    secret: ?[]const u8 = null,
};

/// Encoded attach headers. `headers` (and every formatted value in it)
/// lives in `arena`; `deinit` frees the lot.
pub const EncodedAttach = struct {
    arena: std.heap.ArenaAllocator,
    headers: []curl.Header,

    pub fn deinit(self: *EncodedAttach) void {
        self.arena.deinit();
    }
};

/// THE attach encoder — every Zig sender goes through here (the Python
/// smokes' mirror is `smoke_lib_v2.attach_join`).
pub fn encodeAttach(gpa: std.mem.Allocator, env: AttachEnvelope) !EncodedAttach {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var hs: std.ArrayListUnmanaged(curl.Header) = .empty;
    try hs.append(a, .{ .name = TENANT, .value = env.tenant });
    try hs.append(a, .{
        .name = INCARNATION,
        .value = if (env.incarnation.len == 0) INCARNATION_LEGACY else env.incarnation,
    });
    if (env.plan) |p| try hs.append(a, .{ .name = PLAN, .value = p });
    if (env.epoch) |e|
        try hs.append(a, .{ .name = EPOCH, .value = try std.fmt.allocPrint(a, "{d}", .{e}) });
    if (env.join_as_learner)
        try hs.append(a, .{ .name = JOIN_AS_LEARNER, .value = "1" });
    if (env.voters) |v|
        try hs.append(a, .{ .name = VOTERS, .value = try joinIds(a, v) });
    if (env.learners) |l|
        try hs.append(a, .{ .name = LEARNERS, .value = try joinIds(a, l) });
    if (env.peer_addrs) |pa| if (pa.len != 0)
        try hs.append(a, .{ .name = PEER_ADDRS, .value = pa });
    if (env.secret) |sec| try hs.append(a, .{ .name = KEYRING_SECRET, .value = sec });

    return .{ .arena = arena, .headers = try hs.toOwnedSlice(a) };
}

pub const AttachDecodeError = error{
    MissingTenant,
    MissingIncarnation,
    /// A baseline header on an attach — the atomic baseline attach is
    /// RETIRED (a joiner is born empty; the streamed catch-up installs the
    /// baseline). A sender still sending one predates the retirement and
    /// must fail loudly, not birth a group it believes is at a baseline
    /// that was never installed.
    BaselineRetired,
    MalformedEpoch,
    MalformedVoters,
    MalformedLearners,
    /// Present but not 64 lowercase hex. Never treated as absent: a
    /// birth that silently dropped the secret would stand the tenant up
    /// with no keyring, and nothing downstream would notice until a
    /// seal needed a key that no node had.
    MalformedKeyringSecret,
};

/// Decoded attach envelope. Slices borrow the request's header storage
/// (valid for the handler's lifetime); id lists live in the inline
/// buffers, read via `voters()` / `learners()`.
pub const DecodedAttach = struct {
    tenant: []const u8,
    /// MARKER spelling: the token, or "" for legacy (the wire's
    /// `INCARNATION_LEGACY` is translated back here).
    incarnation: []const u8,
    plan: ?[]const u8,
    /// Header absent → 1 (provision/move attaches don't send it).
    epoch: u64,
    join_as_learner: bool,
    peer_addrs: ?[]const u8,
    /// Decoded keyring root secret, or null on a repair/move attach.
    secret: ?[32]u8,
    voters_buf: [MAX_MEMBER_IDS]u64,
    voters_len: ?u8,
    learners_buf: [MAX_MEMBER_IDS]u64,
    learners_len: ?u8,

    /// null = header absent (env / membership-neutral fallback at the
    /// receiver); non-null = the sender's explicit set.
    pub fn voters(self: *const DecodedAttach) ?[]const u64 {
        const n = self.voters_len orelse return null;
        return self.voters_buf[0..n];
    }

    pub fn learners(self: *const DecodedAttach) ?[]const u64 {
        const n = self.learners_len orelse return null;
        return self.learners_buf[0..n];
    }
};

/// THE attach decoder. `headers` is anything with
/// `get(name: []const u8) ?[]const u8` (the worker wraps its h2 header
/// lookup). Required fields error instead of defaulting; a malformed
/// value NEVER collapses to "absent" — and a RETIRED field (the baseline
/// pair) is a loud decode error, never ignored: a sender still shipping it
/// believes in an install that will not happen.
pub fn decodeAttach(headers: anytype) AttachDecodeError!DecodedAttach {
    const tenant = headers.get(TENANT) orelse return error.MissingTenant;
    const inc_wire = headers.get(INCARNATION) orelse return error.MissingIncarnation;
    const incarnation = if (std.mem.eql(u8, inc_wire, INCARNATION_LEGACY)) "" else inc_wire;

    if (headers.get(BASELINE_INDEX) != null or headers.get(BASELINE_TERM) != null)
        return error.BaselineRetired;

    const epoch: u64 = if (headers.get(EPOCH)) |s|
        std.fmt.parseInt(u64, std.mem.trim(u8, s, " "), 10) catch return error.MalformedEpoch
    else
        1;

    const join_as_learner = if (headers.get(JOIN_AS_LEARNER)) |s|
        std.mem.eql(u8, std.mem.trim(u8, s, " "), "1")
    else
        false;

    var out: DecodedAttach = .{
        .tenant = tenant,
        .incarnation = incarnation,
        .plan = headers.get(PLAN),
        .epoch = epoch,
        .join_as_learner = join_as_learner,
        .peer_addrs = headers.get(PEER_ADDRS),
        .secret = null,
        .voters_buf = undefined,
        .voters_len = null,
        .learners_buf = undefined,
        .learners_len = null,
    };
    if (headers.get(KEYRING_SECRET)) |hex| {
        var raw: [32]u8 = undefined;
        if (hex.len != 64) return error.MalformedKeyringSecret;
        _ = std.fmt.hexToBytes(&raw, hex) catch return error.MalformedKeyringSecret;
        out.secret = raw;
    }
    if (headers.get(VOTERS)) |s|
        out.voters_len = parseIds(s, &out.voters_buf) catch return error.MalformedVoters;
    if (headers.get(LEARNERS)) |s|
        out.learners_len = parseIds(s, &out.learners_buf) catch return error.MalformedLearners;
    return out;
}

/// Human-facing message for a rejected attach — names the header and, for
/// the retired absent-incarnation convention, its replacement (loud
/// retirement: every defect that announced itself cost minutes).
pub fn attachDecodeMessage(e: AttachDecodeError) []const u8 {
    return switch (e) {
        error.MissingTenant => "missing " ++ TENANT ++ "\n",
        error.MalformedKeyringSecret => "malformed " ++ KEYRING_SECRET ++ " — must be exactly 64 lowercase hex characters\n",
        error.MissingIncarnation => "missing " ++ INCARNATION ++ " — required since rove#363; a legacy name-keyed tenant sends the value '" ++ INCARNATION_LEGACY ++ "', never an absent header\n",
        error.BaselineRetired => "attach carries no baseline - a joiner is born empty and its state arrives raft-natively (v2-snapshot-stream / log replication)\n",
        error.MalformedEpoch => "malformed " ++ EPOCH ++ "\n",
        error.MalformedVoters => "malformed " ++ VOTERS ++ "\n",
        error.MalformedLearners => "malformed " ++ LEARNERS ++ "\n",
    };
}

// ── v2-applied-baseline: leader's baseline + membership + incarnation ─

/// The `/_system/v2-applied-baseline` reply: everything a joiner must be
/// born with, read from the leader in ONE call so the pieces can't
/// disagree. Every field is REQUIRED — `parseAppliedBaseline` has no
/// per-field defaults, so a field the leader stops sending is a parse
/// error at the reconciler, not a zero that silently mis-births the
/// joiner. (`ignore_unknown_fields` stays on: ADDING a field is
/// compatible; dropping one is loud.)
pub const AppliedBaseline = struct {
    index: u64,
    term: u64,
    epoch: u64,
    voters: []const u64,
    learners: []const u64,
    /// MARKER spelling: token, or "" for legacy.
    incarnation: []const u8,
};

pub fn encodeAppliedBaseline(a: std.mem.Allocator, ab: AppliedBaseline) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    var w = buf.writer(a);
    try w.print("{{\"index\":{d},\"term\":{d},\"epoch\":{d},\"voters\":[", .{ ab.index, ab.term, ab.epoch });
    for (ab.voters, 0..) |v, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", v });
    try w.writeAll("],\"learners\":[");
    for (ab.learners, 0..) |l, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", l });
    // The incarnation is minted lowercase-hex and validated on entry, so
    // it never needs JSON escaping.
    try w.print("],\"incarnation\":\"{s}\"}}\n", .{ab.incarnation});
    return buf.toOwnedSlice(a);
}

pub fn parseAppliedBaseline(
    a: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(AppliedBaseline) {
    return std.json.parseFromSlice(AppliedBaseline, a, bytes, .{ .ignore_unknown_fields = true });
}

// ── id-list helpers (the one join/parse pair) ─────────────────────────
// Public: every id-list that crosses a wire (attach ConfState, streamed-
// snapshot ConfState) formats and parses through this ONE pair.

pub fn joinIds(a: std.mem.Allocator, ids: []const u64) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    for (ids, 0..) |id, i| {
        if (i != 0) try buf.append(a, ',');
        try buf.writer(a).print("{d}", .{id});
    }
    return buf.toOwnedSlice(a);
}

/// Parse `1,2,3` into `buf`; returns the count. An EMPTY string is zero
/// ids (a present-but-empty header is an explicit empty set).
pub fn parseIds(s: []const u8, buf: *[MAX_MEMBER_IDS]u64) !u8 {
    var n: u8 = 0;
    var it = std.mem.tokenizeScalar(u8, s, ',');
    while (it.next()) |tok| {
        if (n >= MAX_MEMBER_IDS) return error.TooMany;
        buf[n] = try std.fmt.parseInt(u64, std.mem.trim(u8, tok, " "), 10);
        n += 1;
    }
    return n;
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

/// Test double for the receiver's header lookup.
const FakeHeaders = struct {
    entries: []const curl.Header,
    pub fn get(self: FakeHeaders, name: []const u8) ?[]const u8 {
        for (self.entries) |h|
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

test "attach: a birth secret round-trips as raw bytes" {
    const hex = "00112233445566778899aabbccddeeff" ++ "ffeeddccbbaa99887766554433221100";
    var enc = try encodeAttach(testing.allocator, .{
        .tenant = "acme",
        .incarnation = "deadbeef01234567",
        .secret = hex,
    });
    defer enc.deinit();
    const dec = try decodeAttach(FakeHeaders{ .entries = enc.headers });
    const got = dec.secret orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u8, 0x00), got[0]);
    try testing.expectEqual(@as(u8, 0xff), got[15]);
    try testing.expectEqual(@as(u8, 0x00), got[31]);
}

test "attach: no secret is the normal case, not a malformed one" {
    // A move or repair attach carries none — the destination's keyring
    // arrives from a peer as sealed ciphertext. Decoding must not invent
    // one, and must not fail.
    var enc = try encodeAttach(testing.allocator, .{
        .tenant = "acme",
        .incarnation = "deadbeef01234567",
    });
    defer enc.deinit();
    const fh = FakeHeaders{ .entries = enc.headers };
    const dec = try decodeAttach(fh);
    try testing.expect(dec.secret == null);
    try testing.expect(fh.get(KEYRING_SECRET) == null);
}

test "attach: a malformed secret is refused, never read as absent" {
    // Silently dropping it would birth the tenant with no keyring, and
    // nothing downstream would notice until a seal needed a key no node
    // has — at which point the only repair is re-provisioning.
    const cases = [_][]const u8{
        "",
        "abcd",
        "0" ** 63,
        "0" ** 65,
        "g" ** 64,
    };
    for (cases) |bad| {
        const hs = [_]curl.Header{
            .{ .name = TENANT, .value = "acme" },
            .{ .name = INCARNATION, .value = INCARNATION_LEGACY },
            .{ .name = KEYRING_SECRET, .value = bad },
        };
        try testing.expectError(
            error.MalformedKeyringSecret,
            decodeAttach(FakeHeaders{ .entries = &hs }),
        );
    }
}

test "attach: encode→decode round-trips every field" {
    var enc = try encodeAttach(testing.allocator, .{
        .tenant = "acme",
        .incarnation = "deadbeef01234567",
        .plan = "{\"tier\":\"pro\"}",
        .epoch = 3,
        .join_as_learner = true,
        .voters = &.{ 1, 2, 3 },
        .learners = &.{4},
        .peer_addrs = "2@10.0.0.2:4001",
    });
    defer enc.deinit();

    const dec = try decodeAttach(FakeHeaders{ .entries = enc.headers });
    try testing.expectEqualStrings("acme", dec.tenant);
    try testing.expectEqualStrings("deadbeef01234567", dec.incarnation);
    try testing.expectEqualStrings("{\"tier\":\"pro\"}", dec.plan.?);
    try testing.expectEqual(@as(u64, 3), dec.epoch);
    try testing.expect(dec.join_as_learner);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, dec.voters().?);
    try testing.expectEqualSlices(u64, &.{4}, dec.learners().?);
    try testing.expectEqualStrings("2@10.0.0.2:4001", dec.peer_addrs.?);
}

test "attach: legacy incarnation rides the wire as an explicit token" {
    var enc = try encodeAttach(testing.allocator, .{ .tenant = "old", .incarnation = "" });
    defer enc.deinit();
    // On the wire: the sentinel (an empty header value would be DROPPED by
    // libcurl's header-list serialization).
    const fh = FakeHeaders{ .entries = enc.headers };
    try testing.expectEqualStrings(INCARNATION_LEGACY, fh.get(INCARNATION).?);
    // Decoded: back to the marker spelling.
    const dec = try decodeAttach(fh);
    try testing.expectEqualStrings("", dec.incarnation);
    // Minimal attach carries nothing else.
    try testing.expect(dec.plan == null and dec.voters() == null);
    try testing.expectEqual(@as(u64, 1), dec.epoch);
}

test "attach: a RETIRED baseline header is a loud decode error" {
    // Either header alone suffices — a pre-retirement sender is refused
    // before any instance/group side-effect, not silently birthed empty at a
    // baseline it thinks was installed.
    const base = [_]curl.Header{
        .{ .name = TENANT, .value = "acme" },
        .{ .name = INCARNATION, .value = INCARNATION_LEGACY },
    };
    {
        const hdrs = base ++ [_]curl.Header{.{ .name = BASELINE_INDEX, .value = "42" }};
        try testing.expectError(error.BaselineRetired, decodeAttach(FakeHeaders{ .entries = &hdrs }));
    }
    {
        const hdrs = base ++ [_]curl.Header{.{ .name = BASELINE_TERM, .value = "7" }};
        try testing.expectError(error.BaselineRetired, decodeAttach(FakeHeaders{ .entries = &hdrs }));
    }
}

test "attach: an ABSENT incarnation header is a decode error, never legacy" {
    const hdrs = [_]curl.Header{.{ .name = TENANT, .value = "acme" }};
    try testing.expectError(
        error.MissingIncarnation,
        decodeAttach(FakeHeaders{ .entries = &hdrs }),
    );
}

test "attach: malformed values are errors, not absent-field fallbacks" {
    const base = [_]curl.Header{
        .{ .name = TENANT, .value = "acme" },
        .{ .name = INCARNATION, .value = INCARNATION_LEGACY },
    };
    {
        const hdrs = base ++ [_]curl.Header{.{ .name = VOTERS, .value = "1,x" }};
        try testing.expectError(error.MalformedVoters, decodeAttach(FakeHeaders{ .entries = &hdrs }));
    }
    {
        const hdrs = base ++ [_]curl.Header{.{ .name = EPOCH, .value = "" }};
        try testing.expectError(error.MalformedEpoch, decodeAttach(FakeHeaders{ .entries = &hdrs }));
    }
}

test "applied-baseline: encode→parse round-trips; a missing field is an error" {
    const a = testing.allocator;
    const json = try encodeAppliedBaseline(a, .{
        .index = 10,
        .term = 2,
        .epoch = 4,
        .voters = &.{ 1, 2 },
        .learners = &.{},
        .incarnation = "cafe0123",
    });
    defer a.free(json);
    var parsed = try parseAppliedBaseline(a, json);
    defer parsed.deinit();
    try testing.expectEqual(@as(u64, 10), parsed.value.index);
    try testing.expectEqualSlices(u64, &.{ 1, 2 }, parsed.value.voters);
    try testing.expectEqual(@as(usize, 0), parsed.value.learners.len);
    try testing.expectEqualStrings("cafe0123", parsed.value.incarnation);

    // A field the sender stops emitting is a PARSE ERROR at the receiver,
    // not a zero — the silent-default failure mode this pair exists to kill.
    try testing.expectError(
        error.MissingField,
        parseAppliedBaseline(a, "{\"index\":1,\"term\":1,\"epoch\":1,\"voters\":[],\"learners\":[]}"),
    );
    // An unknown ADDED field stays compatible.
    var fwd = try parseAppliedBaseline(a,
        \\{"index":1,"term":1,"epoch":1,"voters":[1],"learners":[],"incarnation":"","future":true}
    );
    fwd.deinit();
}
