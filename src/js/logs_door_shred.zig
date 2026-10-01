// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The serve-side gate: a record leaves the platform OPENED, or it does
//! not leave at all (the serve-side shred gate,
//! `docs/architecture/deployment-and-logs.md`).
//!
//! ## Why the tape holds ciphertext in the first place
//!
//! A value sealed under a per-identity key (`shredKey`) is
//! sealed at the WRITE boundary, so the ciphertext propagates by itself
//! into the writeset, the raft entry, the LMDB page, the readset and the
//! tape. That is the whole mechanism — no container below the write
//! boundary has to know an identity exists. Opening before the tape
//! append would put plaintext on the tape and defeat it.
//!
//! So the tape is ciphertext, and something has to open it on the way
//! out. This is that something.
//!
//! ## Why HERE, and not in the log-server
//!
//! Every consumer of a record — the dashboard, the replay viewer, the
//! `rewind` CLI, the `@rewind/browser` shim — reaches it through the
//! worker's `rewind-logs.internal` door. And the worker is the only
//! process that holds both the tenant's keys and the completeness
//! watermark that says whether a miss means anything. A reader with the
//! keyring but not the watermark can only guess, and the guess it would
//! make — "no key, therefore erased" — is the worst answer available.
//!
//! ## The three answers, and why the third is the point
//!
//! - **opened** — the key is here. The value is replaced with plaintext,
//!   which is also what makes the interaction digest recomputable: the
//!   digest folds the value the handler READ, so replay has to see the
//!   same plaintext or every sealed read reads as a divergence.
//! - **shredded** — the key is genuinely gone and this node holds
//!   everything it should, so absence is authoritative. The value stays
//!   sealed and the downstream transcode reports the erasure precisely
//!   (`src/replay/export_fixture.zig`, the `sealed` refusal).
//! - **unverified** — this node is short of key material and cannot tell
//!   the two apart. The WHOLE response is refused. Serving it would let
//!   a downstream reader report an erasure that never happened, which is
//!   a lie about the one thing customers are promised.
//!
//! ## Why a byte scan and not a JSON round-trip
//!
//! The response shapes differ per route (`list`, `show`, `window`,
//! `saga`, `session`, `seam`), and re-stringifying every record to reach
//! one field would cost the whole document on every dashboard poll. The
//! field is found by scanning for the literal `"kv_tape_b64"`, which is
//! exact rather than heuristic: JSON escapes a quote inside a string as
//! `\"`, so the unescaped byte sequence cannot occur inside any string
//! value — including a customer-controlled tag or path. It is a field
//! name or it is nothing.

const std = @import("std");
const tape_mod = @import("rove-tape");
const keyring_mod = @import("rove-keyring");
const seal_mod = keyring_mod.seal;

pub const Opened = keyring_mod.keyspace.Opened;

/// The JSON field carrying one activation's kv tape, base64-encoded.
/// Written by `src/log_server/flush_writer.zig`; the same spelling is
/// what the log-server's own readers use.
const FIELD = "\"kv_tape_b64\"";

/// How a caller resolves one stored value. Type-erased so the transform
/// is testable without a keyring, a node, or a cluster — the tests below
/// drive every branch through a fake.
pub const Resolver = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, value: []const u8) anyerror!Opened,
};

pub const Error = error{
    /// This node cannot vouch for its key material, so it will not serve
    /// a record whose sealed values it merely failed to open.
    KeyMaterialUnverified,
};

/// Open every sealed kv value in a logs-door response body.
///
/// Returns null when nothing changed — the overwhelmingly common case
/// (no tenant using `shredKey`, or none of these records read a
/// sealed value), and the case that must stay free.
///
/// Returns `error.KeyMaterialUnverified` when any sealed value resolves
/// to `.unverified`. That is deliberately all-or-nothing: a partially
/// opened response is one a reader would take at face value.
pub fn openResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    resolver: Resolver,
) (Error || std.mem.Allocator.Error)!?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var changed = false;

    var copied: usize = 0; // everything before this is already in `out`
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, body, search, FIELD)) |at| {
        const span = switch (fieldValue(body, at)) {
            .span => |sp| sp,
            // An empty channel, or a shape this did not write. Nothing to
            // open either way.
            .absent => {
                search = at + FIELD.len;
                continue;
            },
            // A field whose value has no end — a body truncated at the
            // response cap will do it. There is a tape here and we cannot
            // see all of it, so we cannot say it holds nothing sealed.
            .malformed => return Error.KeyMaterialUnverified,
        };
        search = span.end;

        const rewritten = try openTapeField(allocator, body[span.start..span.end], resolver);
        const new_b64 = rewritten orelse continue;
        defer allocator.free(new_b64);

        try out.appendSlice(allocator, body[copied..span.start]);
        try out.appendSlice(allocator, new_b64);
        copied = span.end;
        changed = true;
    }

    if (!changed) {
        out.deinit(allocator);
        return null;
    }
    try out.appendSlice(allocator, body[copied..]);
    return try out.toOwnedSlice(allocator);
}

/// The base64 run of `"kv_tape_b64": "…"`, given the offset of the field
/// name.
///
/// Base64 has no escape sequences, so the value ends at the first `"` —
/// no string-unescaping pass is needed or wanted.
///
/// `absent` and `malformed` are kept apart deliberately. A `null` value
/// (the channel was empty) is nothing to open; a string that never
/// closes is a tape we cannot see all of, and treating that as "nothing
/// sealed here" would serve ciphertext.
const FieldValue = union(enum) {
    span: struct { start: usize, end: usize },
    absent,
    malformed,
};

fn fieldValue(body: []const u8, name_at: usize) FieldValue {
    return fieldValueAfter(body, name_at + FIELD.len);
}

/// `fieldValue` for any field: `after` is the offset just past the name.
fn fieldValueAfter(body: []const u8, after: usize) FieldValue {
    var i = after;
    while (i < body.len and isJsonSpace(body[i])) i += 1;
    if (i >= body.len) return .malformed;
    if (body[i] != ':') return .absent;
    i += 1;
    while (i < body.len and isJsonSpace(body[i])) i += 1;
    if (i >= body.len) return .malformed;
    if (body[i] != '"') return .absent; // `null`, or a shape we did not write
    i += 1;
    const start = i;
    const end = std.mem.indexOfScalarPos(u8, body, start, '"') orelse return .malformed;
    return .{ .span = .{ .start = start, .end = end } };
}

fn isJsonSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// One tape field: decode, open what is sealed, re-encode. Null when the
/// tape holds nothing sealed, or when it is not one this build can read.
fn openTapeField(
    allocator: std.mem.Allocator,
    b64: []const u8,
    resolver: Resolver,
) (Error || std.mem.Allocator.Error)!?[]u8 {
    const dec = std.base64.standard.Decoder;
    // Bytes we cannot decode are bytes we cannot inspect, and a tape we
    // cannot inspect might hold a sealed value — which a reader would
    // then report as an erasure. Refuse rather than pass it through.
    const raw_len = dec.calcSizeForSlice(b64) catch return Error.KeyMaterialUnverified;
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    dec.decode(raw, b64) catch return Error.KeyMaterialUnverified;

    // Cheap filter before the parse: a sealed value BEGINS with the seal
    // marker, so a tape without that byte anywhere holds nothing sealed.
    // A false positive (a `kv.prefix` limit of 0xFFFFFFFF would do it)
    // costs one parse and nothing else.
    if (std.mem.indexOfScalar(u8, raw, seal_mod.SEAL_MARKER) == null) return null;

    // Past the filter there IS something marker-shaped in here, so a
    // tape this build cannot read is one it cannot clear either. Refusing
    // costs a stale-wire-version record its logs view; passing it through
    // would let a reader call a live identity erased, which is the
    // failure this whole mechanism exists to prevent.
    var parsed = tape_mod.parse(allocator, raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return Error.KeyMaterialUnverified,
    };
    defer parsed.deinit();
    if (parsed.channel != .kv) return Error.KeyMaterialUnverified;

    // Opened plaintext outlives the entries that point at it and is
    // freed in one go once re-encoded.
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var opened_any = false;
    for (parsed.entries) |*e| switch (e.*) {
        .kv => |*k| {
            if (try openInPlace(sa, &k.value, resolver)) opened_any = true;
            // `results` is `[]const KvPair` over a heap slab the parsed
            // tape owns; the pair bytes point into its backing buffer.
            // Both stay valid — only which bytes a pair NAMES changes.
            const rows: []tape_mod.KvPair = @constCast(k.results);
            for (rows) |*row| {
                if (try openInPlace(sa, &row.value, resolver)) opened_any = true;
            }
        },
        else => {},
    };
    if (!opened_any) return null;

    const bytes = try tape_mod.serializeEntries(allocator, parsed.channel, parsed.entries);
    defer allocator.free(bytes);

    const enc = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(bytes.len));
    errdefer allocator.free(out);
    _ = enc.encode(out, bytes);
    return out;
}

/// Resolve one value, replacing it with plaintext when this node holds
/// the key. Returns whether it changed.
///
/// A `.shredded` value is LEFT SEALED on purpose. It is the erasure, and
/// the downstream transcode is what turns it into a refusal that names
/// the reason — this layer must not flatten it into an empty string or a
/// missing entry, either of which replays as a value the live run never
/// saw.
fn openInPlace(
    scratch: std.mem.Allocator,
    value: *[]const u8,
    resolver: Resolver,
) (Error || std.mem.Allocator.Error)!bool {
    if (!seal_mod.isSealed(value.*)) return false;
    const res = resolver.open(resolver.ctx, scratch, value.*) catch return Error.KeyMaterialUnverified;
    switch (res) {
        .opened => |plain| {
            value.* = plain;
            return true;
        },
        .shredded => return false,
        // Both mean "this node cannot stand behind an answer". `.plaintext`
        // is unreachable — we only ask about sealed values — but a
        // resolver that said it would be claiming the seal marker was a
        // false positive, which is exactly the unverifiable case.
        .unverified, .plaintext => return Error.KeyMaterialUnverified,
    }
}

// ── sealed payloads on the record's tapes ────────────────────────────
//
// A payload small enough to ride a tape inline is sealed in place the same
// way a pool body is — under a data key of its own, wrapped for the tenant
// or the identity the activation named — with the wrap on the entry beside
// it (`body_key`). So the payload-carrying tapes a record carries are
// opened here on the way out, exactly as the kv tape is.

/// The record fields whose tapes carry payloads. Written by
/// `src/log_server/flush_writer.zig`.
const PAYLOAD_FIELDS = [_][]const u8{
    "\"trigger_payload_tape_b64\"",
    "\"fetch_responses_tape_b64\"",
    "\"activation_tape_b64\"",
    "\"random_tape_b64\"",
};

/// Open every sealed inline payload in a logs-door response, and strip
/// every wrap — an opened entry's, and a pool entry's too, whose bytes the
/// body route opens on its own. The wrap never leaves this door.
///
/// Per entry:
/// - **opened** — the plaintext replaces the ciphertext.
/// - **shredded** — the bytes are DROPPED, leaving the entry's recorded
///   length and no payload: the unretained shape every reader already
///   reports as a payload that was not kept, rather than serving ciphertext
///   as if it were the body.
/// - **unverified** — the whole response is refused, as for a kv value.
///
/// Null when nothing changed.
pub fn openPayloadTapes(
    allocator: std.mem.Allocator,
    body: []const u8,
    resolver: BodyResolver,
) (Error || std.mem.Allocator.Error)!?[]u8 {
    // Edits in document order, whichever field they belong to.
    const Edit = struct { start: usize, end: usize, b64: []u8 };
    var edits: std.ArrayListUnmanaged(Edit) = .empty;
    defer {
        for (edits.items) |e| allocator.free(e.b64);
        edits.deinit(allocator);
    }
    for (PAYLOAD_FIELDS) |name| {
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, body, search, name)) |at| {
            const span = switch (fieldValueAfter(body, at + name.len)) {
                .span => |sp| sp,
                .absent => {
                    search = at + name.len;
                    continue;
                },
                .malformed => return Error.KeyMaterialUnverified,
            };
            search = span.end;
            const rewritten = try openPayloadField(allocator, body[span.start..span.end], resolver);
            const b64 = rewritten orelse continue;
            errdefer allocator.free(b64);
            try edits.append(allocator, .{ .start = span.start, .end = span.end, .b64 = b64 });
        }
    }
    if (edits.items.len == 0) return null;
    std.mem.sort(Edit, edits.items, {}, struct {
        fn lt(_: void, x: Edit, y: Edit) bool {
            return x.start < y.start;
        }
    }.lt);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var copied: usize = 0;
    for (edits.items) |e| {
        try out.appendSlice(allocator, body[copied..e.start]);
        try out.appendSlice(allocator, e.b64);
        copied = e.end;
    }
    try out.appendSlice(allocator, body[copied..]);
    return try out.toOwnedSlice(allocator);
}

/// One payload tape: decode, open or strip every wrapped entry, re-encode.
/// Null when no entry carries a wrap.
fn openPayloadField(
    allocator: std.mem.Allocator,
    b64: []const u8,
    resolver: BodyResolver,
) (Error || std.mem.Allocator.Error)!?[]u8 {
    const dec = std.base64.standard.Decoder;
    // A tape this cannot inspect might carry a sealed payload a reader would
    // then take for the real one. Refuse, as for the kv tape.
    const raw_len = dec.calcSizeForSlice(b64) catch return Error.KeyMaterialUnverified;
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    dec.decode(raw, b64) catch return Error.KeyMaterialUnverified;
    var parsed = tape_mod.parse(allocator, raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return Error.KeyMaterialUnverified,
    };
    defer parsed.deinit();

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var changed = false;
    for (parsed.entries) |*e| {
        const slots: struct { bytes: *[]const u8, key: *[]const u8 } = switch (e.*) {
            .trigger_payload => |*t| .{ .bytes = &t.inline_bytes, .key = &t.body_key },
            .fetch_responses => |*f| .{ .bytes = &f.inline_bytes, .key = &f.body_key },
            .activation => |*a| .{ .bytes = &a.inline_bytes, .key = &a.body_key },
            .random => |*r| .{ .bytes = &r.inline_bytes, .key = &r.body_key },
            else => continue,
        };
        if (slots.key.len == 0) continue;
        changed = true;
        if (slots.bytes.len > 0) {
            const res = resolver.open(resolver.ctx, sa, slots.bytes.*, slots.key.*) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return Error.KeyMaterialUnverified,
            };
            slots.bytes.* = switch (res) {
                .opened => |p| p,
                .shredded => "",
                .unverified, .plaintext => return Error.KeyMaterialUnverified,
            };
        }
        slots.key.* = "";
    }
    if (!changed) return null;

    const bytes = try tape_mod.serializeEntries(allocator, parsed.channel, parsed.entries);
    defer allocator.free(bytes);
    const enc = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

// ── pool bodies ──────────────────────────────────────────────────────
//
// A body spilled to the cross-tenant pool is sealed under a data key of
// its own, and that key — wrapped under key material a destroy can reach
// — rides the tape entry that references it (`rove-keyring`'s
// `body_seal`). The log-server's body route holds no keys, so it answers
// with the ciphertext AND the wrap, and this is where the pair becomes
// plaintext, stays gone, or is refused — the same three answers as a kv
// value, for the same reason.

/// The body route's wrap field. Written only by the log-server's body
/// route (`src/log_server/standalone.zig`); exact for the reason `FIELD`
/// is — an unescaped quote cannot occur inside a JSON string.
const BODY_KEY_FIELD = "\"body_key_b64\"";

/// How a caller opens one pool body with its wrap.
pub const BodyResolver = struct {
    ctx: *anyopaque,
    open: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        sealed_body: []const u8,
        wrap: []const u8,
    ) anyerror!Opened,
};

pub const BodyError = error{
    /// The body's key is destroyed and this node holds everything it
    /// should, so the absence is authoritative. The door answers 410 —
    /// the same "the bytes are no longer there" a swept pool object
    /// gets, which is what an erasure is.
    Erased,
};

/// Open the pool body in a body-route response, if it carries a wrap.
///
/// Returns null when there is no wrap (a carried, content-addressed or
/// pre-sealing body — the response is already plaintext), or the
/// rewritten response `{"source","len","bytes_b64"}` with the plaintext
/// and its true length. The wrap never leaves this door.
pub fn openBodyResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    resolver: BodyResolver,
) (Error || BodyError || std.mem.Allocator.Error)!?[]u8 {
    if (std.mem.indexOf(u8, body, BODY_KEY_FIELD) == null) return null;

    // Past the filter there IS a wrap, so a response this cannot parse is
    // ciphertext it cannot open — refused, never passed through.
    const Shape = struct {
        source: []const u8,
        bytes_b64: []const u8,
        body_key_b64: []const u8,
    };
    var parsed = std.json.parseFromSlice(Shape, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return Error.KeyMaterialUnverified,
    };
    defer parsed.deinit();
    const v = parsed.value;

    const dec = std.base64.standard.Decoder;
    const sealed = try decodeAllocOrRefuse(allocator, dec, v.bytes_b64);
    defer allocator.free(sealed);
    const wrap = try decodeAllocOrRefuse(allocator, dec, v.body_key_b64);
    defer allocator.free(wrap);

    const res = resolver.open(resolver.ctx, allocator, sealed, wrap) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A wrap or body that fails to authenticate under the key this
        // node holds is not an erasure — it is bytes this node cannot
        // stand behind.
        else => return Error.KeyMaterialUnverified,
    };
    const plain = switch (res) {
        .opened => |p| p,
        .shredded => return BodyError.Erased,
        // `.plaintext` would mean a wrap that names nothing — the same
        // unverifiable case as for a kv value.
        .unverified, .plaintext => return Error.KeyMaterialUnverified,
    };
    defer allocator.free(plain);

    const enc = std.base64.standard.Encoder;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, enc.calcSize(plain.len) + 96);
    // `source` is one of the resolver's own verdict names, so it is
    // re-emitted verbatim once shown to need no escaping.
    for (v.source) |ch| if (!std.ascii.isAlphabetic(ch)) return Error.KeyMaterialUnverified;
    try out.print(allocator, "{{\"source\":\"{s}\",\"len\":{d},\"bytes_b64\":\"", .{ v.source, plain.len });
    const at = out.items.len;
    try out.resize(allocator, at + enc.calcSize(plain.len));
    _ = enc.encode(out.items[at..], plain);
    try out.appendSlice(allocator, "\"}\n");
    return try out.toOwnedSlice(allocator);
}

fn decodeAllocOrRefuse(
    allocator: std.mem.Allocator,
    dec: std.base64.Base64Decoder,
    b64: []const u8,
) (Error || std.mem.Allocator.Error)![]u8 {
    const n = dec.calcSizeForSlice(b64) catch return Error.KeyMaterialUnverified;
    const out = try allocator.alloc(u8, n);
    errdefer allocator.free(out);
    dec.decode(out, b64) catch return Error.KeyMaterialUnverified;
    return out;
}

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

/// A resolver with no keys in it: every sealed value is answered from a
/// table keyed by the ciphertext's first payload byte, so each branch of
/// the gate is reachable without a keyring, a node, or a cluster.
const FakeKeys = struct {
    /// What to answer for every sealed value. `plain` is the substitute
    /// when the answer is `.opened`.
    answer: std.meta.Tag(Opened),
    plain: []const u8 = "",
    calls: usize = 0,

    fn openFn(ctx: *anyopaque, allocator: std.mem.Allocator, value: []const u8) anyerror!Opened {
        _ = value;
        const self: *FakeKeys = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return switch (self.answer) {
            .opened => .{ .opened = try allocator.dupe(u8, self.plain) },
            .plaintext => .plaintext,
            .shredded => .shredded,
            .unverified => .unverified,
        };
    }

    fn resolver(self: *FakeKeys) Resolver {
        return .{ .ctx = self, .open = &openFn };
    }
};

/// A value that `isSealed` accepts — the marker plus enough bytes that
/// nothing here mistakes it for a truncated one. It is never actually
/// opened: the fake answers by fiat.
fn sealedBytes(buf: []u8) []const u8 {
    buf[0] = seal_mod.SEAL_MARKER;
    for (buf[1..], 0..) |*b, i| b.* = @intCast(i % 251);
    return buf;
}

fn kvTapeB64(a: std.mem.Allocator, entries: []const tape_mod.Entry.KvEntry) ![]u8 {
    var wrapped = try a.alloc(tape_mod.Entry, entries.len);
    defer a.free(wrapped);
    for (entries, 0..) |e, i| wrapped[i] = .{ .kv = e };
    const bytes = try tape_mod.serializeEntries(a, .kv, wrapped);
    defer a.free(bytes);
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

fn bodyWith(a: std.mem.Allocator, b64: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        a,
        "{{\"records\":[{{\"path\":\"/x\",\"tapes\":{{\"kv_tape_b64\":\"{s}\",\"kv_write_keys_b64\":null}}}}]}}",
        .{b64},
    );
}

/// Decode the one kv tape in a response body back to its entries.
fn tapeOf(a: std.mem.Allocator, body: []const u8) !tape_mod.ParsedTape {
    const span = fieldValue(body, std.mem.indexOf(u8, body, FIELD).?).span;
    const b64 = body[span.start..span.end];
    const dec = std.base64.standard.Decoder;
    const raw = try a.alloc(u8, try dec.calcSizeForSlice(b64));
    defer a.free(raw);
    try dec.decode(raw, b64);
    return tape_mod.parse(a, raw);
}

test "an opened value replaces the ciphertext, so the digest can be recomputed" {
    const a = testing.allocator;
    var sealed_buf: [64]u8 = undefined;
    const b64 = try kvTapeB64(a, &.{
        .{ .op = .get, .outcome = .ok, .key = "card", .value = sealedBytes(&sealed_buf) },
    });
    defer a.free(b64);
    const body = try bodyWith(a, b64);
    defer a.free(body);

    var fake: FakeKeys = .{ .answer = .opened, .plain = "4111-1111" };
    const out = (try openResponse(a, body, fake.resolver())).?;
    defer a.free(out);

    var parsed = try tapeOf(a, out);
    defer parsed.deinit();
    // The interaction digest folds the value the handler READ
    // (`tape/interaction_digest.zig` kvRead), so a replay served
    // ciphertext would diverge on every sealed read. Plaintext here is
    // what makes the recomputed digest comparable at all.
    try testing.expectEqualStrings("4111-1111", parsed.entries[0].kv.value);
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "a shredded value stays SEALED — the erasure is the downstream reader's to report" {
    // Flattening it here (to empty, or by dropping the entry) would
    // replay as a value the live run never saw. The transcode is what
    // turns a still-sealed value into a refusal naming the reason.
    const a = testing.allocator;
    var sealed_buf: [64]u8 = undefined;
    const sealed = sealedBytes(&sealed_buf);
    const b64 = try kvTapeB64(a, &.{
        .{ .op = .get, .outcome = .ok, .key = "card", .value = sealed },
    });
    defer a.free(b64);
    const body = try bodyWith(a, b64);
    defer a.free(body);

    var fake: FakeKeys = .{ .answer = .shredded };
    // Nothing changed, so nothing is rewritten — the body is served
    // verbatim and the marker survives to the transcode.
    try testing.expect((try openResponse(a, body, fake.resolver())) == null);
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "an unverified node refuses the WHOLE response rather than reporting an erasure" {
    const a = testing.allocator;
    var sealed_buf: [64]u8 = undefined;
    const b64 = try kvTapeB64(a, &.{
        .{ .op = .get, .outcome = .ok, .key = "card", .value = sealedBytes(&sealed_buf) },
    });
    defer a.free(b64);
    const body = try bodyWith(a, b64);
    defer a.free(body);

    var fake: FakeKeys = .{ .answer = .unverified };
    try testing.expectError(
        Error.KeyMaterialUnverified,
        openResponse(a, body, fake.resolver()),
    );
}

test "one unverified value poisons a response whose other values opened" {
    // Partial opening is the failure this is all-or-nothing to avoid: a
    // reader takes what it is given at face value, and a record that is
    // plaintext everywhere except one row reads as one erasure rather
    // than as a node that cannot answer.
    const a = testing.allocator;
    var s1: [64]u8 = undefined;
    var s2: [64]u8 = undefined;
    const b64 = try kvTapeB64(a, &.{
        .{ .op = .get, .outcome = .ok, .key = "a", .value = sealedBytes(&s1) },
        .{ .op = .get, .outcome = .ok, .key = "b", .value = sealedBytes(&s2) },
    });
    defer a.free(b64);
    const body = try bodyWith(a, b64);
    defer a.free(body);

    const Mixed = struct {
        n: usize = 0,
        fn openFn(ctx: *anyopaque, allocator: std.mem.Allocator, value: []const u8) anyerror!Opened {
            _ = value;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.n += 1;
            if (self.n == 1) return .{ .opened = try allocator.dupe(u8, "fine") };
            return .unverified;
        }
    };
    var mixed: Mixed = .{};
    try testing.expectError(
        Error.KeyMaterialUnverified,
        openResponse(a, body, .{ .ctx = &mixed, .open = &Mixed.openFn }),
    );
}

test "prefix rows are opened too — a page short by one row is not a page" {
    const a = testing.allocator;
    var sealed_buf: [64]u8 = undefined;
    const rows = [_]tape_mod.KvPair{
        .{ .key = "u/1", .value = "plain" },
        .{ .key = "u/2", .value = sealedBytes(&sealed_buf) },
    };
    const b64 = try kvTapeB64(a, &.{
        .{ .op = .prefix, .outcome = .ok, .key = "u/", .value = "", .cursor = "", .limit = 10, .results = &rows },
    });
    defer a.free(b64);
    const body = try bodyWith(a, b64);
    defer a.free(body);

    var fake: FakeKeys = .{ .answer = .opened, .plain = "opened-row" };
    const out = (try openResponse(a, body, fake.resolver())).?;
    defer a.free(out);

    var parsed = try tapeOf(a, out);
    defer parsed.deinit();
    const got = parsed.entries[0].kv.results;
    try testing.expectEqualStrings("plain", got[0].value);
    try testing.expectEqualStrings("opened-row", got[1].value);
    // Only the sealed row was asked about; a plaintext row never reaches
    // the keyring at all.
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "a body with nothing sealed is not rewritten at all" {
    // The path every tenant not using `shredKey` takes, which is
    // to say almost every response. It must not pay for a re-encode.
    const a = testing.allocator;
    const b64 = try kvTapeB64(a, &.{
        .{ .op = .get, .outcome = .ok, .key = "k", .value = "v" },
    });
    defer a.free(b64);
    const body = try bodyWith(a, b64);
    defer a.free(body);

    var fake: FakeKeys = .{ .answer = .unverified };
    try testing.expect((try openResponse(a, body, fake.resolver())) == null);
    try testing.expectEqual(@as(usize, 0), fake.calls);
}

test "every record in a multi-record response is opened, not just the first" {
    const a = testing.allocator;
    var s1: [64]u8 = undefined;
    var s2: [64]u8 = undefined;
    const t1 = try kvTapeB64(a, &.{.{ .op = .get, .outcome = .ok, .key = "a", .value = sealedBytes(&s1) }});
    defer a.free(t1);
    const t2 = try kvTapeB64(a, &.{.{ .op = .get, .outcome = .ok, .key = "b", .value = sealedBytes(&s2) }});
    defer a.free(t2);
    const body = try std.fmt.allocPrint(
        a,
        "{{\"records\":[{{\"tapes\":{{\"kv_tape_b64\":\"{s}\"}}}},{{\"tapes\":{{\"kv_tape_b64\":\"{s}\"}}}}]}}",
        .{ t1, t2 },
    );
    defer a.free(body);

    var fake: FakeKeys = .{ .answer = .opened, .plain = "P" };
    const out = (try openResponse(a, body, fake.resolver())).?;
    defer a.free(out);
    try testing.expectEqual(@as(usize, 2), fake.calls);
    // Both spans were replaced, and the surrounding JSON is intact.
    try testing.expect(std.mem.startsWith(u8, out, "{\"records\":["));
    try testing.expect(std.mem.endsWith(u8, out, "}]}"));
    var it = std.mem.splitSequence(u8, out, FIELD);
    _ = it.next();
    try testing.expect(it.next() != null);
    try testing.expect(it.next() != null);
}

test "a null tape field is left alone" {
    const a = testing.allocator;
    const body = "{\"records\":[{\"tapes\":{\"kv_tape_b64\":null}}]}";
    var fake: FakeKeys = .{ .answer = .unverified };
    try testing.expect((try openResponse(a, body, fake.resolver())) == null);
    try testing.expectEqual(@as(usize, 0), fake.calls);
}

test "the field name cannot be forged from a customer-controlled string" {
    // The whole licence for scanning bytes instead of parsing JSON: a
    // quote inside a JSON string is escaped, so the unescaped sequence
    // this looks for is a field name or it is nothing. A tag or path
    // holding the literal text reaches us with backslashes in it.
    const a = testing.allocator;
    const body =
        "{\"records\":[{\"path\":\"/\\\"kv_tape_b64\\\": \\\"AAAA\\\"\",\"tapes\":{}}]}";
    var fake: FakeKeys = .{ .answer = .unverified };
    try testing.expect((try openResponse(a, body, fake.resolver())) == null);
    try testing.expectEqual(@as(usize, 0), fake.calls);
}

test "whitespace between the field name and its value is tolerated" {
    const a = testing.allocator;
    var sealed_buf: [64]u8 = undefined;
    const b64 = try kvTapeB64(a, &.{
        .{ .op = .get, .outcome = .ok, .key = "k", .value = sealedBytes(&sealed_buf) },
    });
    defer a.free(b64);
    const body = try std.fmt.allocPrint(a, "{{\"kv_tape_b64\" : \"{s}\"}}", .{b64});
    defer a.free(body);

    var fake: FakeKeys = .{ .answer = .opened, .plain = "x" };
    const out = (try openResponse(a, body, fake.resolver())).?;
    defer a.free(out);
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "a truncated tape field refuses — it is not 'nothing sealed here'" {
    // A response cut at the fetch cap ends mid-base64. The field is there
    // and its value is not, so the gate cannot say the tape holds nothing
    // sealed — and a reader told that would call a live identity erased.
    const a = testing.allocator;
    var fake: FakeKeys = .{ .answer = .opened, .plain = "x" };
    const body = "{\"records\":[{\"tapes\":{\"kv_tape_b64\":\"UlRBUAAJAAAAAAAB";
    try testing.expectError(
        Error.KeyMaterialUnverified,
        openResponse(a, body, fake.resolver()),
    );
    try testing.expectEqual(@as(usize, 0), fake.calls);
}

test "a tape carrying the marker that this build cannot parse refuses" {
    // Same rule one level down. Past the cheap filter there is something
    // marker-shaped in the bytes; a tape we cannot decode is one we
    // cannot clear.
    const a = testing.allocator;
    const enc = std.base64.standard.Encoder;
    // Valid base64, not a tape — no RTAP magic — but with the marker in it.
    const junk = [_]u8{ 0x01, 0x02, seal_mod.SEAL_MARKER, 0x03, 0x04, 0x05 };
    const b64 = try a.alloc(u8, enc.calcSize(junk.len));
    defer a.free(b64);
    _ = enc.encode(b64, &junk);
    const body = try bodyWith(a, b64);
    defer a.free(body);

    var fake: FakeKeys = .{ .answer = .opened, .plain = "x" };
    try testing.expectError(
        Error.KeyMaterialUnverified,
        openResponse(a, body, fake.resolver()),
    );
}

test "a field name at the very end of a body is malformed, not absent" {
    const a = testing.allocator;
    var fake: FakeKeys = .{ .answer = .unverified };
    try testing.expectError(
        Error.KeyMaterialUnverified,
        openResponse(a, "{\"tapes\":{\"kv_tape_b64\"", fake.resolver()),
    );
}

// ── pool-body tests ──────────────────────────────────────────────────

const body_seal = keyring_mod.body_seal;
const crypt = @import("rove-crypt");

/// Opens with one fixed key, or answers by fiat — every branch of the
/// body gate without a keyring.
const FakeBodyKeys = struct {
    key: crypt.Key = [_]u8{0x44} ** crypt.KEY_LEN,
    answer: std.meta.Tag(Opened) = .opened,

    fn openFn(ctx: *anyopaque, allocator: std.mem.Allocator, sealed: []const u8, wrap: []const u8) anyerror!Opened {
        const self: *FakeBodyKeys = @ptrCast(@alignCast(ctx));
        return switch (self.answer) {
            .opened => .{ .opened = try body_seal.open(allocator, sealed, wrap, self.key) },
            .plaintext => .plaintext,
            .shredded => .shredded,
            .unverified => .unverified,
        };
    }

    fn resolver(self: *FakeBodyKeys) BodyResolver {
        return .{ .ctx = self, .open = &openFn };
    }
};

/// The body route's answer for a sealed pool body, as the log-server
/// writes it.
fn sealedBodyResponse(a: std.mem.Allocator, keys: *const FakeBodyKeys, plain: []const u8) ![]u8 {
    var s = try body_seal.seal(a, plain, keys.key, crypt.TENANT_REF, 1);
    defer s.deinit(a);
    const enc = std.base64.standard.Encoder;
    const b = try a.alloc(u8, enc.calcSize(s.body.len));
    defer a.free(b);
    _ = enc.encode(b, s.body);
    const k = try a.alloc(u8, enc.calcSize(s.wrapped_key.len));
    defer a.free(k);
    _ = enc.encode(k, &s.wrapped_key);
    return std.fmt.allocPrint(
        a,
        "{{\"source\":\"pool\",\"len\":{d},\"bytes_b64\":\"{s}\",\"body_key_b64\":\"{s}\"}}\n",
        .{ s.body.len, b, k },
    );
}

test "a sealed pool body leaves the door as plaintext, with its true length and no wrap" {
    const a = testing.allocator;
    var keys: FakeBodyKeys = .{};
    const resp = try sealedBodyResponse(a, &keys, "the request body");
    defer a.free(resp);

    const out = (try openBodyResponse(a, resp, keys.resolver())).?;
    defer a.free(out);
    try testing.expectEqualStrings(
        "{\"source\":\"pool\",\"len\":16,\"bytes_b64\":\"dGhlIHJlcXVlc3QgYm9keQ==\"}\n",
        out,
    );
    // The wrap is key material. It never leaves this process.
    try testing.expect(std.mem.indexOf(u8, out, BODY_KEY_FIELD) == null);
}

test "a body with no wrap passes through untouched" {
    var keys: FakeBodyKeys = .{};
    const resp = "{\"source\":\"carried\",\"len\":2,\"bytes_b64\":\"aGk=\"}\n";
    try testing.expect((try openBodyResponse(testing.allocator, resp, keys.resolver())) == null);
}

test "an erased body is reported as erased, never served as ciphertext" {
    const a = testing.allocator;
    var keys: FakeBodyKeys = .{ .answer = .shredded };
    const resp = try sealedBodyResponse(a, &keys, "secret");
    defer a.free(resp);
    try testing.expectError(BodyError.Erased, openBodyResponse(a, resp, keys.resolver()));
}

test "a node short of key material refuses rather than reporting an erasure" {
    const a = testing.allocator;
    var keys: FakeBodyKeys = .{ .answer = .unverified };
    const resp = try sealedBodyResponse(a, &keys, "secret");
    defer a.free(resp);
    try testing.expectError(Error.KeyMaterialUnverified, openBodyResponse(a, resp, keys.resolver()));
}

test "a wrap the held key does not open is refused, not called erased" {
    // Wrong key material is not a destroyed key: reporting it as an
    // erasure would be a lie about the one promise this gate keeps.
    const a = testing.allocator;
    var sealer: FakeBodyKeys = .{};
    const resp = try sealedBodyResponse(a, &sealer, "secret");
    defer a.free(resp);
    var other: FakeBodyKeys = .{ .key = [_]u8{0x55} ** crypt.KEY_LEN };
    try testing.expectError(Error.KeyMaterialUnverified, openBodyResponse(a, resp, other.resolver()));
}

test "a wrapped response this cannot parse is refused, not passed through" {
    var keys: FakeBodyKeys = .{};
    const truncated = "{\"source\":\"pool\",\"len\":9,\"bytes_b64\":\"AAAA\",\"body_key_b64\":\"AA";
    try testing.expectError(
        Error.KeyMaterialUnverified,
        openBodyResponse(testing.allocator, truncated, keys.resolver()),
    );
}

// ── payload-tape tests ───────────────────────────────────────────────

/// A record whose trigger_payload tape carries one entry, as the flush
/// writes it.
fn recordWithTrigger(a: std.mem.Allocator, body_ref: @import("rove-bodies").BodyRef, inline_bytes: []const u8, wrap: []const u8) ![]u8 {
    var t = tape_mod.Tape.init(a, .trigger_payload);
    defer t.deinit();
    try t.appendTriggerPayload(body_ref, inline_bytes, wrap);
    const raw = try t.serialize(a);
    defer a.free(raw);
    const enc = std.base64.standard.Encoder;
    const b64 = try a.alloc(u8, enc.calcSize(raw.len));
    defer a.free(b64);
    _ = enc.encode(b64, raw);
    return std.fmt.allocPrint(a, "{{\"record\":{{\"tapes\":{{\"trigger_payload_tape_b64\":\"{s}\"}}}}}}", .{b64});
}

fn triggerOf(a: std.mem.Allocator, body: []const u8) !tape_mod.ParsedTape {
    const name = PAYLOAD_FIELDS[0];
    const at = std.mem.indexOf(u8, body, name).?;
    const span = fieldValueAfter(body, at + name.len).span;
    const b64 = body[span.start..span.end];
    const dec = std.base64.standard.Decoder;
    const raw = try a.alloc(u8, try dec.calcSizeForSlice(b64));
    defer a.free(raw);
    try dec.decode(raw, b64);
    return tape_mod.parse(a, raw);
}

test "a sealed inline body is opened on the record's tape, and its wrap stripped" {
    const a = testing.allocator;
    var keys: FakeBodyKeys = .{};
    var s = try body_seal.seal(a, "the small body", keys.key, crypt.TENANT_REF, 1);
    defer s.deinit(a);
    const bodies = @import("rove-bodies");
    const rec = try recordWithTrigger(a, bodies.BodyRef.carried(14), s.body, &s.wrapped_key);
    defer a.free(rec);

    const out = (try openPayloadTapes(a, rec, keys.resolver())).?;
    defer a.free(out);
    var parsed = try triggerOf(a, out);
    defer parsed.deinit();
    const e = parsed.entries[0].trigger_payload;
    try testing.expectEqualStrings("the small body", e.inline_bytes);
    try testing.expectEqualStrings("", e.body_key);
}

test "an erased inline body leaves as its length and no bytes, never as ciphertext" {
    const a = testing.allocator;
    var keys: FakeBodyKeys = .{ .answer = .shredded };
    var s = try body_seal.seal(a, "secret", keys.key, crypt.refForSlot(9), 1);
    defer s.deinit(a);
    const bodies = @import("rove-bodies");
    const rec = try recordWithTrigger(a, bodies.BodyRef.carried(6), s.body, &s.wrapped_key);
    defer a.free(rec);

    const out = (try openPayloadTapes(a, rec, keys.resolver())).?;
    defer a.free(out);
    var parsed = try triggerOf(a, out);
    defer parsed.deinit();
    const e = parsed.entries[0].trigger_payload;
    // The unretained shape: every reader reports it as a payload not kept.
    try testing.expectEqual(@as(usize, 0), e.inline_bytes.len);
    try testing.expectEqual(@as(u32, 6), e.body_ref.len);
    try testing.expectEqualStrings("", e.body_key);
}

test "a node short of key material refuses a record with a sealed payload" {
    const a = testing.allocator;
    var keys: FakeBodyKeys = .{ .answer = .unverified };
    var s = try body_seal.seal(a, "secret", keys.key, crypt.TENANT_REF, 1);
    defer s.deinit(a);
    const bodies = @import("rove-bodies");
    const rec = try recordWithTrigger(a, bodies.BodyRef.carried(6), s.body, &s.wrapped_key);
    defer a.free(rec);
    try testing.expectError(Error.KeyMaterialUnverified, openPayloadTapes(a, rec, keys.resolver()));
}

test "a pool entry's wrap is stripped without opening anything" {
    // Its bytes are in the pool, reached through the body route, which opens
    // them there. The record's copy of the wrap is key material all the same.
    const a = testing.allocator;
    var keys: FakeBodyKeys = .{ .answer = .unverified }; // would refuse if asked
    const bodies = @import("rove-bodies");
    const ref: bodies.BodyRef = .{
        .written_unix_ms = 1_700_000_000_000,
        .digest = [_]u8{7} ** bodies.pool_object.DIGEST_LEN,
        .offset = 0,
        .len = 70_000,
    };
    const rec = try recordWithTrigger(a, ref, "", "a-wrap");
    defer a.free(rec);
    const out = (try openPayloadTapes(a, rec, keys.resolver())).?;
    defer a.free(out);
    var parsed = try triggerOf(a, out);
    defer parsed.deinit();
    try testing.expectEqualStrings("", parsed.entries[0].trigger_payload.body_key);
    try testing.expectEqual(@as(u32, 70_000), parsed.entries[0].trigger_payload.body_ref.len);
}

test "a record with no wrapped payload passes through untouched" {
    const a = testing.allocator;
    var keys: FakeBodyKeys = .{};
    const bodies = @import("rove-bodies");
    const rec = try recordWithTrigger(a, bodies.BodyRef.carried(2), "hi", "");
    defer a.free(rec);
    try testing.expect((try openPayloadTapes(a, rec, keys.resolver())) == null);
}
