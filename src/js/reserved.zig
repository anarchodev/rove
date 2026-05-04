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
//!   no business writing into `_outbox/`, `_events/`, `_callback/`, etc.
//!   — those are platform-write-only. Platform writes (e.g.
//!   `webhook.send` writing `_outbox/{id}`) bypass `jsKvSet` and write
//!   directly via `state.txn.put`, so this check catches only the
//!   spoofing path through `kv.set`.

const std = @import("std");

/// Reserved key prefixes used by both checks below. Keep in sync with
/// the platform writers that own each namespace:
///   `_audit/`           → reserved for future audit log
///   `_deploy/`          → reserved for future deploy metadata in app.db
///   `_outbox/`          → webhook.send writes here (drainer reads)
///   `_outbox_inflight/` → webhook drainer's lease parking spot
///   `_dlq/`             → terminal-failed webhook envelopes
///   `_callback/`        → webhook drainer writes; dispatchCallbacks reads
///   `_magic/`           → magic-link tokens (root.db only, but list-wide)
///   `_triggers/`        → trigger module bytecode (manifest, not app.db)
///   `_events/`          → SSE event rows (events.emit writes)
///   `_sessions/`        → reserved for future platform session storage
pub const PLATFORM_KV_PREFIXES = [_][]const u8{
    "_audit/",
    "_deploy/",
    "_outbox/",
    "_outbox_inflight/",
    "_dlq/",
    "_callback/",
    "_magic/",
    "_triggers/",
    "_events/",
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
    try std.testing.expect(isReservedTriggerPrefix("_outbox/"));
    try std.testing.expect(isReservedTriggerPrefix("_events/"));
    try std.testing.expect(isReservedTriggerPrefix("_sessions/"));
    try std.testing.expect(isReservedTriggerPrefix("_triggers/"));
}

test "isReservedTriggerPrefix: descendant of platform prefix blocked" {
    try std.testing.expect(isReservedTriggerPrefix("_outbox/specific_id"));
    try std.testing.expect(isReservedTriggerPrefix("_events/sid/0001-000001"));
}

test "isReservedTriggerPrefix: ancestor catching platform prefix blocked" {
    // `_aud` would catch writes to `_audit/foo`.
    try std.testing.expect(isReservedTriggerPrefix("_aud"));
    // `_o` would catch writes to `_outbox/...`, `_outbox_inflight/...`.
    try std.testing.expect(isReservedTriggerPrefix("_o"));
    // `_` alone catches everything under any platform prefix.
    try std.testing.expect(isReservedTriggerPrefix("_"));
}

test "isReservedTriggerPrefix: deeper-than-platform blocked (would catch system writes)" {
    try std.testing.expect(isReservedTriggerPrefix("_audit/secrets/"));
    try std.testing.expect(isReservedTriggerPrefix("_outbox/specific_id"));
}

test "isCustomerWriteReserved: platform prefixes blocked" {
    try std.testing.expect(isCustomerWriteReserved("_outbox/abc"));
    try std.testing.expect(isCustomerWriteReserved("_events/sid/0001-000001"));
    try std.testing.expect(isCustomerWriteReserved("_callback/xyz"));
    try std.testing.expect(isCustomerWriteReserved("_dlq/abc"));
    try std.testing.expect(isCustomerWriteReserved("_audit/anything"));
    try std.testing.expect(isCustomerWriteReserved("_magic/token"));
}

test "isCustomerWriteReserved: customer keys allowed" {
    try std.testing.expect(!isCustomerWriteReserved(""));
    try std.testing.expect(!isCustomerWriteReserved("users/alice"));
    try std.testing.expect(!isCustomerWriteReserved("my_outbox/x"));
    try std.testing.expect(!isCustomerWriteReserved("orders/123"));
    // Single-leading-underscore keys without trailing slash aren't
    // reserved (only the prefixes that include `/` are).
    try std.testing.expect(!isCustomerWriteReserved("_my_data"));
}

test "isCustomerWriteReserved: exact prefix without trailing key part is blocked" {
    // The prefix itself counts as a write into the namespace.
    try std.testing.expect(isCustomerWriteReserved("_outbox/"));
}
