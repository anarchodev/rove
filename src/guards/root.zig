// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! rove-guards — the handler-facing checks, as ONE authority for every engine.
//!
//! Given the same inputs, every engine that runs a customer handler must
//! behave the same, which means they must run the same checks. Every NATIVE
//! engine — the worker and the sim/replay driver — now calls the Zig here
//! through the common binding (`rove-binding`), one implementation. The one
//! engine that cannot is the browser WASM arena: its host half is
//! JavaScript, so until the wasm is built in-tree from arenajs C + rove Zig
//! the check has to EXECUTE in JS there.
//!
//! So there are two evaluators, and this module owns both:
//!
//!   - `check*()` — the rules in Zig, called from the common binding.
//!   - `emitJs()`  — the same rules rendered as JavaScript, generated into
//!     `src/replay/js/guards.generated.js` for the ARENA's prelude
//!     (`scripts/ops/gen_replay_prelude.py`).
//!
//! Be precise about what that does and does not buy. Every CONSTANT and every
//! MESSAGE has one home here, so a cap, a prefix or a wording cannot drift —
//! that is what actually broke three times (`_export/` reached one engine and
//! not another, #499; the arena had no kv guards at all, #502; its tag-cap
//! message differed from the other two, #505). The control flow, though, is
//! still expressed twice: once as Zig branches, once as an emitted JS
//! template. Two statements of one rule is exactly the shape that drifts.
//!
//! What keeps them honest is `differential_test.zig` in `rove-js`: it evals
//! the emitted JS in QJS and asserts, over a corpus of inputs, that both
//! evaluators return the same verdict. A structural guarantee would be
//! better; a behavioural one that runs in the gate is what is available
//! without building a rule interpreter, and it tests the thing that matters
//! (the answers) rather than the shape.
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

// ── the JS interpreter of the same table ─────────────────────────────────

/// Render the rules as JavaScript, for the engines that must evaluate them
/// in JS because their storage seam cannot carry a refusal.
///
/// Generated into `src/replay/js/guards.generated.js` by `zig build
/// gen-guards` and committed, so the Python that composes the browser
/// arena's prelude can splice it without running Zig. A test asserts the
/// committed file still matches this function, which is what stops the
/// generated copy from becoming a third statement of the rules.
pub fn emitJs(w: anytype) !void {
    try w.writeAll(
        \\// GENERATED by `zig build gen-guards` from src/guards/root.zig — do not edit.
        \\//
        \\// The handler-facing checks, rendered for the engines that must run
        \\// them in JS: their storage seam (`host.zig`'s kv_set) has no way to
        \\// report a refusal, so a Zig verdict cannot become a thrown error
        \\// there. Same table as the worker evaluates — see rove-guards.
        \\//
        \\// Byte lengths, not code units: `__utf8Len` counts what the worker
        \\// counts, so a multi-byte key hits the same cap in every engine.
        \\
    );
    try w.print(
        \\const __GUARD_SHIM_WRITABLE = [
    , .{});
    for (reserved.SHIM_WRITABLE_PREFIXES, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("\"{s}\"", .{p});
    }
    try w.writeAll("];\n");
    try w.print(
        \\const __KV_KEY_MAX = {d}, __KV_VAL_MAX = {d};
        \\const __TAG_MAX = {d}, __TAG_KEY_MAX = {d}, __TAG_VAL_MAX = {d};
        \\
    , .{ reserved.KV_KEY_MAX, reserved.KV_VAL_MAX, reserved.TAG_MAX, reserved.TAG_KEY_MAX, reserved.TAG_VAL_MAX });
    try w.writeAll(
        \\const __utf8Len = (s) => { s = String(s == null ? "" : s); let n = 0; for (let i = 0; i < s.length; i++) { let cp = s.charCodeAt(i); if (cp >= 0xD800 && cp <= 0xDBFF) { const lo = i + 1 < s.length ? s.charCodeAt(i + 1) : 0; if (lo >= 0xDC00 && lo <= 0xDFFF) { cp = 0x10000; i++; } } if (cp < 0x80) n += 1; else if (cp < 0x800) n += 2; else if (cp < 0x10000) n += 3; else n += 4; } return n; };
        \\const __kvErr = (message, code) => { const e = new Error(message); e.code = code; return e; };
        \\const __kvReserved = (k) => { if (k.length === 0 || k[0] !== "_") return false; for (const p of __GUARD_SHIM_WRITABLE) if (k.startsWith(p)) return false; return true; };
        \\const __kvCoerce = (x, what) => { if (x === null || x === undefined || typeof x === "object" || typeof x === "function") throw new TypeError("kv: " + what +
    );
    try w.writeAll("\" must be a string (or number/boolean/bigint); JSON.stringify objects explicitly\"); return String(x); };\n");
    try w.print(
        \\const __kvGuardWrite = (k, hasVal, val, isExempt) => {{
        \\  const ks = __kvCoerce(k, "key");
        \\  const vs = hasVal ? __kvCoerce(val, "value") : "";
        \\  if (!(isExempt && isExempt(ks))) {{
        \\    if (__kvReserved(ks)) throw __kvErr("kv: '" + ks + "' is in a platform-reserved prefix", "{s}");
        \\    if (__utf8Len(ks) > __KV_KEY_MAX) throw __kvErr("{s}", "{s}");
        \\    if (hasVal && __utf8Len(vs) > __KV_VAL_MAX) throw __kvErr("{s}", "{s}");
        \\  }}
        \\  return ks;
        \\}};
        \\
    , .{
        kv_reserved_code,
        kvTooLargeMessage("key", reserved.KV_KEY_MAX),   kv_key_too_large_code,
        kvTooLargeMessage("value", reserved.KV_VAL_MAX), kv_value_too_large_code,
    });
    try w.print(
        \\const __tagGuardPair = (k, v, argc) => {{
        \\  if (argc < 2 || typeof k !== "string" || typeof v !== "string") throw new TypeError("{s}");
        \\  if (__utf8Len(k) < 1 || __utf8Len(k) > __TAG_KEY_MAX) throw new TypeError("{s}");
        \\  if (k[0] === "_") throw new TypeError("{s}");
        \\  if (!/^[a-z0-9_]+$/.test(k)) throw new TypeError("{s}");
        \\  if (__utf8Len(v) < 1 || __utf8Len(v) > __TAG_VAL_MAX) throw new TypeError("{s}");
        \\  for (let i = 0; i < v.length; i++) if (v.charCodeAt(i) < 0x20) throw new TypeError("{s}");
        \\}};
        \\const __tagGuardCapacity = (count) => {{ if (count >= __TAG_MAX) throw new TypeError("{s}"); }};
        \\
    , .{
        tag_args_message,
        tagLenMessage("key", reserved.TAG_KEY_MAX),
        tag_reserved_message,
        tag_charset_message,
        tagLenMessage("value", reserved.TAG_VAL_MAX),
        tag_control_message,
        tagCapacityMessage(),
    });
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

test "emitJs renders every message the Zig evaluator produces" {
    // The two interpreters read one table, so this asserts they agree on the
    // customer-visible half — every string the evaluator can return must
    // appear in the JS, or an engine would report something the worker never
    // says.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try emitJs(buf.writer(testing.allocator));
    const js = buf.items;

    for ([_][]const u8{
        kv_reserved_code,
        kv_key_too_large_code,
        kv_value_too_large_code,
        kvTooLargeMessage("key", reserved.KV_KEY_MAX),
        kvTooLargeMessage("value", reserved.KV_VAL_MAX),
        tag_args_message,
        tagLenMessage("key", reserved.TAG_KEY_MAX),
        tag_reserved_message,
        tag_charset_message,
        tagLenMessage("value", reserved.TAG_VAL_MAX),
        tag_control_message,
        tagCapacityMessage(),
        "is in a platform-reserved prefix",
        "must be a string (or number/boolean/bigint)",
    }) |needle| {
        try testing.expect(std.mem.indexOf(u8, js, needle) != null);
    }
    // And the data the rules read.
    for (reserved.SHIM_WRITABLE_PREFIXES) |p| {
        var q: [64]u8 = undefined;
        try testing.expect(std.mem.indexOf(u8, js, try std.fmt.bufPrint(&q, "\"{s}\"", .{p})) != null);
    }
}

