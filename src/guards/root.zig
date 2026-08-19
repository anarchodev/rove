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
const reserved = @import("rove-reserved");

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
/// calls, keys and values summed. "Its own" is the point — writes are
/// accumulated into a batch writeset shared with other activations, so the
/// budget is measured from this activation's slice of it and a busy neighbour
/// can never spend someone else's allowance.
pub const WriteBudget = struct {
    ops: u32 = 0,
    bytes: usize = 0,
};

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
    const this_write = utf8Len(key) + if (value) |v| utf8Len(v) else 0;
    if (spent.bytes + this_write > reserved.KV_WRITE_BYTES_MAX) {
        return .{
            .throw = .err,
            .code = kv_writes_too_large_code,
            .message = kv_writes_too_large_message,
        };
    }
    return null;
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
    // not.
    const v = "y" ** 1024;
    const at = reserved.KV_WRITE_BYTES_MAX - v.len - 1;
    try testing.expect(checkKvWrite("k", v, false, .{ .bytes = at }) == null);
    try testing.expectEqualStrings(
        kv_writes_too_large_code,
        checkKvWrite("k", v, false, .{ .bytes = at + 1 }).?.code,
    );

    // A delete costs its key, not a value.
    try testing.expect(checkKvWrite("k", null, false, .{ .bytes = reserved.KV_WRITE_BYTES_MAX - 2 }) == null);

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


