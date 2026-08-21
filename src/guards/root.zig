// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! rove-guards — the handler-facing checks, as ONE authority for every engine.
//!
//! Given the same inputs, every engine that runs a customer handler must
//! behave the same, which means they must run the same checks. EVERY engine
//! now calls the Zig here through the common binding (`rove-binding`) — the
//! worker and the sim/replay driver natively, and the browser WASM arena via
//! the in-tree build (`zig build wasm-arena`, rove Zig linked into arenajs's
//! wasm). There is exactly ONE evaluator of these rules; the JS rendering
//! (`emitJs`) and the differential test that held it to the Zig are gone
//! with the last JS consumer.
//!
//! ## What is NOT here, on purpose
//!
//! Where a check is invoked, and what happens after it passes. The worker
//! writes a raft writeset and fires triggers; the sim appends to an effect
//! log; the arena writes an overlay. Those are genuinely different and stay
//! per-engine — this module answers "is this allowed", never "what now".
//!
//! Coercion of a JS value to a string is also per-engine, since it needs a
//! JSContext. Its MESSAGE is here, because the message is contract.

const std = @import("std");
/// Re-exported so the binding can name the shared keyspace rules without
/// taking its own dependency on the module, the same way it names
/// `guards.WriteBudget`.
pub const reserved = @import("rove-reserved");
const sizing = @import("rove-sizing");

/// Which JS constructor an engine throws. The distinction is customer-visible
/// (`e instanceof TypeError`), so it belongs to the rule, not to the caller.
pub const Throw = enum { type_error, err };

/// A refused operation, fully described. `code` is empty for the TypeErrors,
/// which carry no `err.code` in any engine today.
pub const Refusal = struct {
    throw: Throw,
    code: []const u8,
    message: []const u8,
};

/// null = allowed.
pub const Verdict = ?Refusal;

/// The one kind of check that cannot be a pure predicate over bytes, because
/// only the engine's JS layer can see the value's type. Exported so every
/// engine raises identical text.
pub fn coercionMessage(comptime surface: []const u8, comptime what: []const u8) []const u8 {
    return surface ++ ": " ++ what ++ " must be a string (or number/boolean/bigint); JSON.stringify objects explicitly";
}

// ── the table ────────────────────────────────────────────────────────────
//
// Each entry is a constraint plus the refusal it produces. Adding a rule here
// adds it to every engine at once; that is the entire point.


fn utf8Len(s: []const u8) usize {
    return s.len; // already bytes on the Zig side
}

// ── kv ───────────────────────────────────────────────────────────────────

pub const kv_reserved_code = "reserved_key";
pub const kv_key_too_large_code = "key_too_large";
pub const kv_value_too_large_code = "value_too_large";
/// The per-activation write budget (`reserved.KV_WRITES_MAX` /
/// `KV_WRITE_BYTES_MAX`). Distinct from the per-value cap: these say the
/// ACTIVATION has written as much as one raft entry can carry, and the way
/// past them is another activation (`next()`), not a smaller value.
pub const kv_too_many_writes_code = "too_many_writes";
pub const kv_writes_too_large_code = "writes_too_large";

/// The size-cap messages, exported so a TAPED refusal (outcome-replay: the
/// capture said no, replay throws the recorded code without re-deciding) can
/// be re-materialized with the same text the live refusal carried.
pub const kv_key_too_large_message = kvTooLargeMessage("key", reserved.KV_KEY_MAX);
pub const kv_value_too_large_message = kvTooLargeMessage("value", reserved.KV_VAL_MAX);
pub const kv_too_many_writes_message = std.fmt.comptimePrint(
    "kv: this activation has made {d} writes, its limit — continue the work in " ++
        "a new activation (after.ms + next())",
    .{reserved.KV_WRITES_MAX},
);
pub const kv_writes_too_large_message = std.fmt.comptimePrint(
    "kv: this activation's writes exceed {d} bytes — continue the work in a " ++
        "new activation (after.ms + next())",
    .{reserved.KV_WRITE_BYTES_MAX},
);

/// What one activation has written so far: its own `kv.set` / `kv.delete`
/// calls, measured in the bytes they put on the raft entry — key, value and
/// the writeset framing every op carries (`sizing.writeOpBytes`). Measuring
/// the wire is the point twice over:
///
///   - "Its own" — writes are accumulated into a batch writeset shared with
///     other activations, so the budget is measured from this activation's
///     slice of it and a busy neighbour can never spend someone else's
///     allowance.
///   - "Wire bytes" — the budget exists to keep the entry deliverable, so it
///     has to count what the entry carries. A side envelope's framing is
///     charged here too (`sizing.sideEnvelopeFramingBytes`), which is what
///     lets batch admission see bytes that are only appended at propose.
pub const WriteBudget = struct {
    ops: u32 = 0,
    bytes: usize = 0,
};

/// What one `kv.set` / `kv.delete` costs the activation's write budget: the
/// bytes it puts on the raft entry — key, value, and the writeset framing
/// every op carries.
///
/// THE single answer, because two layers ask it: `checkKvWrite` judging
/// `spent + this write`, and the binding charging the write that happened. A
/// check and a charge that compute it separately drift by exactly the term
/// one of them forgets, and the drift shows up as a budget that admits more
/// than the entry holds.
pub fn kvWriteCost(key_len: usize, value_len: usize) usize {
    return sizing.writeOpBytes(key_len, value_len);
}

fn kvTooLargeMessage(comptime which: []const u8, comptime limit: usize) []const u8 {
    return std.fmt.comptimePrint("kv: {s} exceeds the {d}-byte limit", .{ which, limit });
}

/// The worker's `kv.set` / `kv.delete` gate. `value` is null for a delete.
/// `is_system_module` exempts the platform's own baked modules from the
/// reserved-prefix rule — they write those namespaces by design.
///
/// ORDER IS CONTRACT: reserved, then key size, then value size, then the
/// activation's write budget. A key that breaks two rules must report the
/// same one in every engine — and the budget comes last so a write that is
/// individually illegal says so, rather than being blamed on the activation's
/// total.
///
/// `spent` is what this activation has written BEFORE this call; the budget
/// rules judge `spent + this write`.
pub fn checkKvWrite(
    key: []const u8,
    value: ?[]const u8,
    is_system_module: bool,
    spent: WriteBudget,
) Verdict {
    if (!is_system_module and reserved.isCustomerWriteReserved(key)) {
        return .{ .throw = .err, .code = kv_reserved_code, .message = "" };
    }
    if (utf8Len(key) > reserved.KV_KEY_MAX) {
        return .{
            .throw = .err,
            .code = kv_key_too_large_code,
            .message = kvTooLargeMessage("key", reserved.KV_KEY_MAX),
        };
    }
    if (value) |v| {
        if (utf8Len(v) > reserved.KV_VAL_MAX) {
            return .{
                .throw = .err,
                .code = kv_value_too_large_code,
                .message = kvTooLargeMessage("value", reserved.KV_VAL_MAX),
            };
        }
    }
    // The activation's own budget. A system module writes the platform's
    // namespaces but rides the same entry as anything else, so it is NOT
    // exempt here — the exemption above is about WHICH keys may be written,
    // never about how much can be replicated at once.
    if (spent.ops >= reserved.KV_WRITES_MAX) {
        return .{
            .throw = .err,
            .code = kv_too_many_writes_code,
            .message = kv_too_many_writes_message,
        };
    }
    const this_write = kvWriteCost(utf8Len(key), if (value) |v| utf8Len(v) else 0);
    if (spent.bytes + this_write > reserved.KV_WRITE_BYTES_MAX) {
        return .{
            .throw = .err,
            .code = kv_writes_too_large_code,
            .message = kv_writes_too_large_message,
        };
    }
    return null;
}

/// The read half of the reserved-keyspace rule: `true` when a handler read of
/// `key` must behave as though the key is absent.
///
/// A read is HIDDEN, not refused, where a write is refused, not ignored. The
/// asymmetry is deliberate. A write that silently did nothing is a bug the
/// handler cannot see, so it must throw; a read of a namespace that is not the
/// tenant's is honestly empty, and answering "absent" is the only answer that
/// does not itself disclose the namespace. `is_system_module` exempts the
/// platform's baked modules, which read these by design.
pub fn kvReadHidden(key: []const u8, is_system_module: bool) bool {
    return !is_system_module and reserved.isEngineOnly(key);
}

/// A scan at `prefix` is entirely inside an engine-only namespace, so it has
/// nothing visible to return and must not touch storage at all.
pub fn kvScanAllHidden(prefix: []const u8, is_system_module: bool) bool {
    return !is_system_module and reserved.isEngineOnly(prefix);
}

/// A scan at `prefix` can reach engine-only keys, so it must filter them out
/// and keep refilling its page. See `reserved.scanSpansEngineOnly` for why
/// filtering alone is not enough.
pub fn kvScanFilters(prefix: []const u8, is_system_module: bool) bool {
    return !is_system_module and reserved.scanSpansEngineOnly(prefix);
}

/// One row of a filtered scan: skip it, or hand it to the handler.
pub fn kvRowHidden(key: []const u8) bool {
    return reserved.isEngineOnly(key);
}

/// The reserved-key message names the offending key, so it is formatted by
/// the caller rather than carried on the verdict. Kept here so the wording
/// has one home.
pub fn kvReservedMessageFmt() []const u8 {
    return "kv: '{s}' is in a platform-reserved prefix";
}

// ── request.tag ──────────────────────────────────────────────────────────

fn tagLenMessage(comptime what: []const u8, comptime max: usize) []const u8 {
    return std.fmt.comptimePrint("request.tag: {s} length must be 1..{d} bytes", .{ what, max });
}

pub const tag_reserved_message = "request.tag: keys starting with '_' are reserved";
pub const tag_charset_message = "request.tag: key must match [a-z0-9_]";
pub const tag_control_message = "request.tag: value must not contain control characters";
pub const tag_args_message = "request.tag(key, value) requires two string arguments";

fn tagCapacityMessage() []const u8 {
    return std.fmt.comptimePrint("request.tag: too many tags (max {d} per request)", .{reserved.TAG_MAX});
}

/// One (key, value) pair. Capacity is separate because whether a call adds or
/// replaces is engine state.
pub fn checkTagPair(key: []const u8, value: []const u8) Verdict {
    if (key.len < 1 or utf8Len(key) > reserved.TAG_KEY_MAX) {
        return .{ .throw = .type_error, .code = "", .message = tagLenMessage("key", reserved.TAG_KEY_MAX) };
    }
    if (key[0] == '_') {
        return .{ .throw = .type_error, .code = "", .message = tag_reserved_message };
    }
    for (key) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_';
        if (!ok) return .{ .throw = .type_error, .code = "", .message = tag_charset_message };
    }
    if (value.len < 1 or utf8Len(value) > reserved.TAG_VAL_MAX) {
        return .{ .throw = .type_error, .code = "", .message = tagLenMessage("value", reserved.TAG_VAL_MAX) };
    }
    for (value) |ch| {
        if (ch < 0x20) return .{ .throw = .type_error, .code = "", .message = tag_control_message };
    }
    return null;
}

/// Called only when a call would ADD a tag; re-tagging an existing key
/// updates in place and is always allowed.
pub fn checkTagCapacity(count: usize) Verdict {
    if (count >= reserved.TAG_MAX) {
        return .{ .throw = .type_error, .code = "", .message = tagCapacityMessage() };
    }
    return null;
}

pub const shred_key_args_message = "request.shredKey(id) requires a string argument";
pub const shred_key_control_message = "request.shredKey: id must not contain control characters";

fn shredKeyLenMessage() []const u8 {
    return std.fmt.comptimePrint(
        "request.shredKey: id length must be 1..{d} bytes",
        .{reserved.SHRED_KEY_MAX},
    );
}

/// One `request.shredKey(id)` identity.
///
/// Deliberately permissive about CONTENT: the engine never learns that an
/// identity is a person, and the id is an opaque name the tenant chooses.
/// Constraining its shape beyond length and control characters would be
/// the engine modelling data subjects, which is exactly what this design
/// avoids having to do.
///
/// Empty is refused rather than treated as "no identity". A handler that
/// computed an empty id — a missing cookie, an unparsed token — means to
/// scope the activation and got nothing; silently falling back to the
/// tenant key would downgrade erasure from per-identity to per-tenant at
/// the moment the customer is least able to notice.
pub fn checkShredKey(id: []const u8) Verdict {
    if (id.len < 1 or id.len > reserved.SHRED_KEY_MAX) {
        return .{ .throw = .type_error, .code = "", .message = shredKeyLenMessage() };
    }
    for (id) |ch| {
        if (ch < 0x20 or ch == 0x7f) {
            return .{ .throw = .type_error, .code = "", .message = shred_key_control_message };
        }
    }
    return null;
}

test "the destroy cap refuses at the limit, never truncates" {
    // A handler that asked to erase more than the cap must not be left
    // guessing which of its calls took effect — none of them can be
    // undone.
    const max = reserved.SHRED_DESTROY_MAX_PER_ACTIVATION;
    try std.testing.expect(checkShredDestroyCap(0) == null);
    try std.testing.expect(checkShredDestroyCap(max - 1) == null);
    try std.testing.expect(checkShredDestroyCap(max) != null);
    try std.testing.expect(checkShredDestroyCap(max + 99) != null);
}

test "the destroy cap is a SAFETY bound, and small" {
    // Not a resource bound — erasure reclaims rather than commits. It is
    // small because the failure it guards against is a handler looping
    // over a list it should not have, and every iteration is permanent.
    try std.testing.expect(reserved.SHRED_DESTROY_MAX_PER_ACTIVATION >= 1);
    try std.testing.expect(reserved.SHRED_DESTROY_MAX_PER_ACTIVATION <= 32);
}

test "shredKey: an empty id is refused, never read as 'no identity'" {
    // A handler that computed an empty id — a missing cookie, an unparsed
    // token — meant to scope the activation and got nothing. Falling back
    // to the tenant key would silently downgrade erasure from
    // per-identity to per-tenant at the worst possible moment.
    try std.testing.expect(checkShredKey("") != null);
}

test "shredKey: length is bounded, and the bound is the shared contract" {
    const max = reserved.SHRED_KEY_MAX;
    const ok = [_]u8{'a'} ** max;
    try std.testing.expect(checkShredKey(&ok) == null);
    const too_long = [_]u8{'a'} ** (max + 1);
    try std.testing.expect(checkShredKey(&too_long) != null);
}

test "shredKey: control characters are refused" {
    try std.testing.expect(checkShredKey("u_1\n") != null);
    try std.testing.expect(checkShredKey("u_1\x00") != null);
    try std.testing.expect(checkShredKey("u_1\x7f") != null);
}

test "shredKey: the id's CONTENT is the tenant's business, not the engine's" {
    // The engine never learns that an identity is a person — it is an
    // opaque name the tenant chooses and can destroy. Constraining its
    // shape further would be the engine modelling data subjects, which
    // is precisely what this design exists to avoid.
    try std.testing.expect(checkShredKey("u_7f3a9c") == null);
    try std.testing.expect(checkShredKey("customer@example.com") == null);
    try std.testing.expect(checkShredKey("order:1234/line:7") == null);
    try std.testing.expect(checkShredKey("日本語") == null);
}

pub const shred_destroy_args_message = "request.shredKey.destroy(id) requires a string argument";

fn shredDestroyCapMessage() []const u8 {
    return std.fmt.comptimePrint(
        "request.shredKey.destroy: too many identities destroyed in one activation (max {d})",
        .{reserved.SHRED_DESTROY_MAX_PER_ACTIVATION},
    );
}

/// The per-activation destroy cap.
///
/// Checked BEFORE the destroy, and refused loudly rather than truncated:
/// a handler that asked to erase more than this must not be left guessing
/// which of its calls took effect, because none of them can be undone.
pub fn checkShredDestroyCap(count: usize) Verdict {
    if (count >= reserved.SHRED_DESTROY_MAX_PER_ACTIVATION) {
        return .{ .throw = .type_error, .code = "", .message = shredDestroyCapMessage() };
    }
    return null;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "kv: order is contract — reserved before size" {
    // A key that is both reserved AND oversized must report `reserved_key`,
    // because that is what the worker reported before this table existed and
    // what the offline engines report today. Order is the part of a rule set
    // most easily lost in a rewrite, and it is customer-visible.
    const long_reserved = "_secret/" ++ ("k" ** 300);
    const v = checkKvWrite(long_reserved, "v", false, .{}).?;
    try testing.expectEqualStrings(kv_reserved_code, v.code);
}

test "kv: a system module writes reserved keys, and still cannot exceed the caps" {
    try testing.expect(checkKvWrite("_sched/by_id/x", "v", true, .{}) == null);
    // The exemption is for the NAMESPACE, not the size — a baked module
    // writing 2 MiB would still break the stream frame.
    const big = "x" ** (reserved.KV_VAL_MAX + 1);
    try testing.expectEqualStrings(kv_value_too_large_code, checkKvWrite("k", big, true, .{}).?.code);
}

test "kv: the activation's write budget is judged last, and only after the write's own rules" {
    // Order is contract. A write that is individually illegal must say so —
    // blaming the activation's total for an oversized value would send a
    // handler looking in the wrong place.
    const spent_full: WriteBudget = .{ .ops = reserved.KV_WRITES_MAX, .bytes = reserved.KV_WRITE_BYTES_MAX };
    const big = "x" ** (reserved.KV_VAL_MAX + 1);
    try testing.expectEqualStrings(kv_value_too_large_code, checkKvWrite("k", big, false, spent_full).?.code);
    try testing.expectEqualStrings(kv_reserved_code, checkKvWrite("_secret/k", "v", false, spent_full).?.code);
}

test "kv: the write budget refuses on ops and on bytes, and a fresh activation is clear" {
    // The count half.
    try testing.expectEqualStrings(
        kv_too_many_writes_code,
        checkKvWrite("k", "v", false, .{ .ops = reserved.KV_WRITES_MAX }).?.code,
    );
    try testing.expect(checkKvWrite("k", "v", false, .{ .ops = reserved.KV_WRITES_MAX - 1 }) == null);

    // The byte half judges `spent + this write`, so the boundary is exact:
    // the write that lands ON the cap is allowed, the one that crosses it is
    // not. The write costs what it puts on the wire — key, value AND the
    // op's framing — so a budget stated in key+value alone would admit this
    // one and overflow the entry.
    const v = "y" ** 1024;
    const cost = sizing.writeOpBytes(1, v.len);
    try testing.expectEqual(@as(usize, 1 + v.len + sizing.WS_OP_BYTES), cost);
    const at = reserved.KV_WRITE_BYTES_MAX - cost;
    try testing.expect(checkKvWrite("k", v, false, .{ .bytes = at }) == null);
    try testing.expectEqualStrings(
        kv_writes_too_large_code,
        checkKvWrite("k", v, false, .{ .bytes = at + 1 }).?.code,
    );

    // A delete costs its key and its framing, not a value.
    try testing.expect(checkKvWrite("k", null, false, .{
        .bytes = reserved.KV_WRITE_BYTES_MAX - sizing.writeOpBytes(1, 0),
    }) == null);
    try testing.expectEqualStrings(kv_writes_too_large_code, checkKvWrite("k", null, false, .{
        .bytes = reserved.KV_WRITE_BYTES_MAX - sizing.writeOpBytes(1, 0) + 1,
    }).?.code);

    // And a system module is exempt from the NAMESPACE rule, never from this:
    // it rides the same entry as anything else.
    try testing.expectEqualStrings(
        kv_too_many_writes_code,
        checkKvWrite("_sched/x", "v", true, .{ .ops = reserved.KV_WRITES_MAX }).?.code,
    );
}

test "kv: shim-writable prefixes pass for a customer, other reserved ones do not" {
    for (reserved.SHIM_WRITABLE_PREFIXES) |p| {
        var buf: [64]u8 = undefined;
        const k = try std.fmt.bufPrint(&buf, "{s}x", .{p});
        try testing.expect(checkKvWrite(k, "v", false, .{}) == null);
    }
    try testing.expect(checkKvWrite("_secret/x", "v", false, .{}) != null);
    try testing.expect(checkKvWrite("orders/1", "v", false, .{}) == null);
}

test "tag: every rule, in the worker's order" {
    try testing.expect(checkTagPair("order", "123") == null);
    try testing.expectEqualStrings(
        "request.tag: key length must be 1..32 bytes",
        checkTagPair("k" ** 33, "v").?.message,
    );
    try testing.expectEqualStrings(tag_reserved_message, checkTagPair("_x", "v").?.message);
    try testing.expectEqualStrings(tag_charset_message, checkTagPair("Order", "v").?.message);
    try testing.expectEqualStrings(
        "request.tag: value length must be 1..64 bytes",
        checkTagPair("k", "v" ** 65).?.message,
    );
    try testing.expectEqualStrings(tag_control_message, checkTagPair("k", "a\x01b").?.message);
    // A key that is both reserved-prefixed and mis-charactered reports the
    // underscore rule, matching the order above.
    try testing.expectEqualStrings(tag_reserved_message, checkTagPair("_A", "v").?.message);
}

test "tag: capacity refuses only at the cap" {
    try testing.expect(checkTagCapacity(reserved.TAG_MAX - 1) == null);
    try testing.expectEqualStrings(
        "request.tag: too many tags (max 4 per request)",
        checkTagCapacity(reserved.TAG_MAX).?.message,
    );
}



test "kv: a legal value under a legal key is writable by a fresh activation" {
    // The two rules have to be satisfiable together, framing included — a
    // value the guard calls legal that no handler can actually write is a cap
    // the platform states and refuses to honour. `rove-sizing` asserts the
    // arithmetic; this is the same claim through the surface that enforces it.
    const k = "k" ** reserved.KV_KEY_MAX;
    const v = "v" ** reserved.KV_VAL_MAX;
    try testing.expect(checkKvWrite(k, v, false, .{}) == null);
}

test "kv: the check and the charge are the same function" {
    // The budget is judged in one place and spent in another (`rove-binding`'s
    // `noteWrite`, the privileged path's `notePlatformWrite`). If they compute
    // the cost separately they drift by whatever one of them forgets, and the
    // drift is invisible until an entry the budget admitted cannot be
    // replicated. Both call this.
    try testing.expectEqual(@as(usize, 9 + 3 + 5), kvWriteCost(3, 5));
    const at = reserved.KV_WRITE_BYTES_MAX - kvWriteCost(3, 5);
    try testing.expect(checkKvWrite("abc", "defgh", false, .{ .bytes = at }) == null);
    try testing.expectEqualStrings(
        kv_writes_too_large_code,
        checkKvWrite("abc", "defgh", false, .{ .bytes = at + 1 }).?.code,
    );
}
