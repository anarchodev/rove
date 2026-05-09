//! Platform-reserved kv prefixes and the two checks that share them.
//!
//! Both `worker.zig` (trigger registration guard) and `globals.zig`
//! (customer kv-write guard) need the same source-of-truth list. Lives
//! in its own module so neither has to import the other.
//!
//! Semantics differ between the two consumers:
//!
//! - `isReservedTriggerPrefix` (deploy-load guard): rejects a customer
//!   trigger whose registered prefix collides with a platform namespace
//!   in *either* direction — customer prefix starts with platform, OR
//!   platform starts with customer prefix. The catch-all `""` is
//!   allowed; the fire-time guard skips dispatch on platform keys.
//!
//! - `isCustomerWriteReserved` (runtime guard on `kv.set` / `kv.delete`):
//!   rejects any key starting with a platform prefix. Customer code has
//!   no business writing into `_callback/`, `_audit/`, etc. — those
//!   are platform-write-only. Platform writes bypass `jsKvSet` and
//!   write directly via `state.txn.put`, so this check catches only
//!   the spoofing path through `kv.set`.

const std = @import("std");

/// Reserved key prefixes used by both checks below. Keep in sync with
/// the platform writers that own each namespace:
///   `_audit/`           → reserved for future audit log
///   `_deploy/`          → reserved for future deploy metadata in app.db
///   `_callback/`        → webhook envelope-5 apply writes here;
///                         dispatchCallbacks reads + invokes onResult
///   `_log/`             → per-tenant log metadata in app.db. Today
///                         only `_log/next_request_seq` lives here
///                         (Phase 5.5 a, A4 — moved off log.db so
///                         the worker can drop log.db opens entirely).
///   `_magic/`           → magic-link tokens (root.db only, but list-wide)
///   `_triggers/`        → trigger module bytecode (manifest, not app.db)
///   `_sessions/`        → reserved for future platform session storage
///
/// `_events/` was reserved for SSE event rows under the legacy worker
/// pump; the centralized sse-server retired that storage layer
/// (sse-plan §7), so the prefix is no longer special — customer code
/// is free to use it.
pub const PLATFORM_KV_PREFIXES = [_][]const u8{
    "_audit/",
    "_deploy/",
    "_callback/",
    "_log/",
    "_magic/",
    "_triggers/",
    "_sessions/",
};

/// Customer trigger registration prefix collides with a platform
/// namespace (either direction). See `PLATFORM_KV_PREFIXES`.
pub fn isReservedTriggerPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return false; // catch-all is allowed
    for (PLATFORM_KV_PREFIXES) |p| {
        if (std.mem.startsWith(u8, prefix, p)) return true;
        if (std.mem.startsWith(u8, p, prefix)) return true;
    }
    return false;
}

/// Customer `kv.set` / `kv.delete` target lands in a platform-reserved
/// namespace. Platform writes bypass these JS bindings and reach
/// `state.txn` / `state.writeset` directly, so this only fires when
/// customer code (or buggy customer-loaded modules) tries to spoof a
/// platform key.
pub fn isCustomerWriteReserved(key: []const u8) bool {
    for (PLATFORM_KV_PREFIXES) |p| {
        if (std.mem.startsWith(u8, key, p)) return true;
    }
    return false;
}

test "isReservedTriggerPrefix: catch-all is allowed" {
    try std.testing.expect(!isReservedTriggerPrefix(""));
}

test "isReservedTriggerPrefix: customer prefixes are allowed" {
    try std.testing.expect(!isReservedTriggerPrefix("users/"));
    try std.testing.expect(!isReservedTriggerPrefix("orders/"));
    try std.testing.expect(!isReservedTriggerPrefix("a/b/c/"));
    try std.testing.expect(!isReservedTriggerPrefix("my_audit/"));
}

test "isReservedTriggerPrefix: exact platform prefix blocked" {
    try std.testing.expect(isReservedTriggerPrefix("_audit/"));
    try std.testing.expect(isReservedTriggerPrefix("_callback/"));
    try std.testing.expect(isReservedTriggerPrefix("_log/"));
    try std.testing.expect(isReservedTriggerPrefix("_sessions/"));
    try std.testing.expect(isReservedTriggerPrefix("_triggers/"));
}

test "isReservedTriggerPrefix: _events/ no longer reserved" {
    try std.testing.expect(!isReservedTriggerPrefix("_events/"));
}

test "isReservedTriggerPrefix: descendant of platform prefix blocked" {
    try std.testing.expect(isReservedTriggerPrefix("_callback/specific_id"));
    try std.testing.expect(isReservedTriggerPrefix("_audit/secrets"));
}

test "isReservedTriggerPrefix: ancestor catching platform prefix blocked" {
    // `_aud` would catch writes to `_audit/foo`.
    try std.testing.expect(isReservedTriggerPrefix("_aud"));
    // `_c` would catch writes to `_callback/...`.
    try std.testing.expect(isReservedTriggerPrefix("_c"));
    // `_` alone catches everything under any platform prefix.
    try std.testing.expect(isReservedTriggerPrefix("_"));
}

test "isReservedTriggerPrefix: deeper-than-platform blocked (would catch system writes)" {
    try std.testing.expect(isReservedTriggerPrefix("_audit/secrets/"));
    try std.testing.expect(isReservedTriggerPrefix("_callback/specific_id"));
}

test "isCustomerWriteReserved: platform prefixes blocked" {
    try std.testing.expect(isCustomerWriteReserved("_callback/xyz"));
    try std.testing.expect(isCustomerWriteReserved("_audit/anything"));
    try std.testing.expect(isCustomerWriteReserved("_log/next_request_seq"));
    try std.testing.expect(isCustomerWriteReserved("_magic/token"));
    try std.testing.expect(isCustomerWriteReserved("_triggers/users/index.mjs"));
}

test "isCustomerWriteReserved: _events/ no longer reserved" {
    try std.testing.expect(!isCustomerWriteReserved("_events/sid/0001-000001"));
}

test "isCustomerWriteReserved: customer keys allowed" {
    try std.testing.expect(!isCustomerWriteReserved(""));
    try std.testing.expect(!isCustomerWriteReserved("users/alice"));
    try std.testing.expect(!isCustomerWriteReserved("my_audit/"));
    try std.testing.expect(!isCustomerWriteReserved("orders/123"));
    // Single-leading-underscore keys without trailing slash aren't
    // reserved (only the prefixes that include `/` are).
    try std.testing.expect(!isCustomerWriteReserved("_my_data"));
    // Historical drainer prefixes are no longer reserved (Phase 5.5
    // (d) deleted the drainer; the prefix names are now free for
    // customer use).
    try std.testing.expect(!isCustomerWriteReserved("_outbox/abc"));
    try std.testing.expect(!isCustomerWriteReserved("_dlq/abc"));
    try std.testing.expect(!isCustomerWriteReserved("_outbox_inflight/abc"));
}

test "isCustomerWriteReserved: exact prefix without trailing key part is blocked" {
    // The prefix itself counts as a write into the namespace.
    try std.testing.expect(isCustomerWriteReserved("_callback/"));
}
