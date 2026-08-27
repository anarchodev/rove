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
    var i = name_at + FIELD.len;
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
