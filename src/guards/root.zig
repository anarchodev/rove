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

/// The size-cap messages, exported so a TAPED refusal (outcome-replay: the
/// capture said no, replay throws the recorded code without re-deciding) can
/// be re-materialized with the same text the live refusal carried.
pub const kv_key_too_large_message = kvTooLargeMessage("key", reserved.KV_KEY_MAX);
pub const kv_value_too_large_message = kvTooLargeMessage("value", reserved.KV_VAL_MAX);

fn kvTooLargeMessage(comptime which: []const u8, comptime limit: usize) []const u8 {
    return std.fmt.comptimePrint("kv: {s} exceeds the {d}-byte limit", .{ which, limit });
}

/// The worker's `kv.set` / `kv.delete` gate. `value` is null for a delete.
/// `is_system_module` exempts the platform's own baked modules from the
/// reserved-prefix rule — they write those namespaces by design.
///
/// ORDER IS CONTRACT: reserved, then key size, then value size. A key that
/// breaks two rules must report the same one in every engine.
pub fn checkKvWrite(key: []const u8, value: ?[]const u8, is_system_module: bool) Verdict {
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
    const v = checkKvWrite(long_reserved, "v", false).?;
    try testing.expectEqualStrings(kv_reserved_code, v.code);
}

test "kv: a system module writes reserved keys, and still cannot exceed the caps" {
    try testing.expect(checkKvWrite("_sched/by_id/x", "v", true) == null);
    // The exemption is for the NAMESPACE, not the size — a baked module
    // writing 2 MiB would still break the stream frame.
    const big = "x" ** (reserved.KV_VAL_MAX + 1);
    try testing.expectEqualStrings(kv_value_too_large_code, checkKvWrite("k", big, true).?.code);
}

test "kv: shim-writable prefixes pass for a customer, other reserved ones do not" {
    for (reserved.SHIM_WRITABLE_PREFIXES) |p| {
        var buf: [64]u8 = undefined;
        const k = try std.fmt.bufPrint(&buf, "{s}x", .{p});
        try testing.expect(checkKvWrite(k, "v", false) == null);
    }
    try testing.expect(checkKvWrite("_secret/x", "v", false) != null);
    try testing.expect(checkKvWrite("orders/1", "v", false) == null);
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


