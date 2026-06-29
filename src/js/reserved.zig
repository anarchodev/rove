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
//!   the ENTIRE leading-`_` keyspace is platform-reserved against customer
//!   writes, EXCEPT the `SHIM_WRITABLE_PREFIXES` the JS shims must write
//!   from ordinary handler context. Reserving the whole namespace (rather
//!   than an enumerated list) is the pre-customer lock-in fix: any NEW
//!   platform `_…/` key family is safe to introduce later without
//!   colliding with customer data (docs/plans/format-versioning-audit.md §7.1).
//!   Customers get the entire non-`_` keyspace. Reads are NOT guarded
//!   (`_config/` is a documented customer-readable namespace). Platform Zig
//!   writers bypass `jsKvSet` and write via `state.txn.put` directly, and
//!   `__system/` modules bypass via `is_system_module`, so this check fires
//!   only on customer (or shim) JS through `kv.set`.

const std = @import("std");

/// Reserved key prefixes used by both checks below. Keep in sync with
/// the platform writers that own each namespace:
///   `_app/`             → reserved for the app manifest of a
///                         distributable (marketplace) app: deploy-time
///                         metadata + install-time config *schema*
///                         (distinct from `_config/`, which holds config
///                         *values*). An author-declared
///                         `_app/manifest.json` in the customer tree
///                         mirrors here on release (sibling of the
///                         `_config/` mirror); the *derived* capability
///                         set (the effect verbs a deployment uses, a
///                         byproduct of §6 export-coverage validation)
///                         lands beside it. Consumer (install flow /
///                         grant gate) is post-launch — this only claims
///                         the namespace now so apps deployed today are
///                         born-distributable. See
///                         `docs/handler-shape.md` §8 and
///                         `project_self_host_marketplace`.
///   `_audit/`           → reserved for future audit log
///   `_config/`          → file-tree-mirrored library config (deploy
///                         pipeline writes; handlers read via
///                         `kv.get`). Source of truth is
///                         `_config/{lib}/{name}.json` in the
///                         customer's tree; mirror runs on release.
///   `_deploy/`          → reserved for future deploy metadata in app.db
///   `_callback/`        → retired receipt prefix (Option (b)
///                         resolves sends via in-memory Completions
///                         + `_send/proof/`, not `_callback/` rows).
///                         Stays reserved so customer JS can't spoof
///                         a legacy receipt key.
///   `_log/`             → per-tenant log metadata in app.db. Today
///                         only `_log/next_request_seq` lives here
///                         (Phase 5.5 a, A4 — moved off log.db so
///                         the worker can drop log.db opens entirely).
///   `_magic/`           → magic-link tokens (root.db only, but list-wide)
///   `_triggers/`        → trigger module bytecode (manifest, not app.db)
///   `_sessions/`        → reserved for future platform session storage
///
/// Used only by `isReservedTriggerPrefix` (the deploy-load trigger guard).
/// The customer-WRITE guard no longer pivots on this enumerated list — it
/// reserves the whole leading-`_` keyspace minus `SHIM_WRITABLE_PREFIXES`
/// (see below). This list stays as the catalog of *known* platform-owned
/// namespaces for the bidirectional trigger-prefix collision check.
pub const PLATFORM_KV_PREFIXES = [_][]const u8{
    "_app/",
    "_audit/",
    "_config/",
    "_deploy/",
    "_callback/",
    "_log/",
    "_magic/",
    "_triggers/",
    "_sessions/",
};

/// Leading-`_` prefixes that platform JS *shims* write into a tenant's own
/// store from ordinary (non-`__system/`) handler context. These CANNOT be
/// denied to `kv.set` without breaking the shim itself, so they are the
/// explicit exception to the blanket leading-`_` reservation.
///
/// They are "platform-managed but not platform-reserved": a customer that
/// writes one of these in their OWN store only corrupts their own durability
/// markers (a per-tenant self-footgun — no cross-tenant or platform-integrity
/// impact, since every store is per-tenant). Fully closing that footgun would
/// require a privileged write binding the shims capture pre-`_harden`
/// (docs/plans/format-versioning-audit.md §7.1 option (a)); deferred.
///
/// Enumerated by auditing every `kv.set`/`kv.delete` in `globals/*.js`
/// (their default config paths). Keep in sync when a shim adds a `_`-prefix:
///   `_send/`  — webhook.send durability marker (globals/webhook.js)
///   `_blob/`  — blob.put durability marker (globals/blob.js)
///   `_sched/` — durable scheduler queue, by_id + by_time (globals/scheduler.js)
///   `_seg/`   — append-only segment streams (globals/segments.js)
///   `_oidc/`  — OIDC provider state: session/keyset/code/at/rt/device
///               (globals/oidc.js, provider() defaults)
///   `_rp/`    — OIDC relying-party state: state/sess/jwks (globals/oidc.js)
/// (`_admin/operator/` is READ-only from shims — the is_root allowlist,
/// seeded out-of-band via rewind-ops — so it stays fully reserved.)
pub const SHIM_WRITABLE_PREFIXES = [_][]const u8{
    "_send/",
    "_blob/",
    "_sched/",
    "_seg/",
    "_oidc/",
    "_rp/",
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

/// Customer `kv.set` / `kv.delete` target lands in the platform-reserved
/// keyspace: any key with a leading `_`, EXCEPT the `SHIM_WRITABLE_PREFIXES`
/// the JS shims must write from handler context. Customers own the entire
/// non-`_` keyspace. Reserving the whole `_` namespace (vs. an enumerated
/// list) is what lets the platform claim new `_…/` key families later
/// without colliding with customer data. Platform Zig writes bypass these JS
/// bindings (`state.txn`/`state.writeset` directly) and `__system/` modules
/// bypass via `is_system_module`, so this only fires on customer/shim JS.
pub fn isCustomerWriteReserved(key: []const u8) bool {
    if (key.len == 0 or key[0] != '_') return false;
    for (SHIM_WRITABLE_PREFIXES) |p| {
        if (std.mem.startsWith(u8, key, p)) return false;
    }
    return true;
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
    try std.testing.expect(isReservedTriggerPrefix("_app/"));
    try std.testing.expect(isReservedTriggerPrefix("_audit/"));
    try std.testing.expect(isReservedTriggerPrefix("_callback/"));
    try std.testing.expect(isReservedTriggerPrefix("_config/"));
    try std.testing.expect(isReservedTriggerPrefix("_log/"));
    try std.testing.expect(isReservedTriggerPrefix("_sessions/"));
    try std.testing.expect(isReservedTriggerPrefix("_triggers/"));
    // `_send/` is NOT reserved post-Phase-5-PR-3 — webhook.send (JS
    // shim) writes the marker as ordinary customer-tenant kv.
    try std.testing.expect(!isReservedTriggerPrefix("_send/"));
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

test "isCustomerWriteReserved: known platform prefixes blocked" {
    try std.testing.expect(isCustomerWriteReserved("_app/manifest"));
    try std.testing.expect(isCustomerWriteReserved("_callback/xyz"));
    try std.testing.expect(isCustomerWriteReserved("_audit/anything"));
    try std.testing.expect(isCustomerWriteReserved("_config/oauth/google"));
    try std.testing.expect(isCustomerWriteReserved("_log/next_request_seq"));
    try std.testing.expect(isCustomerWriteReserved("_magic/token"));
    try std.testing.expect(isCustomerWriteReserved("_triggers/users/index.mjs"));
    try std.testing.expect(isCustomerWriteReserved("_deploy/current"));
    // `_admin/` is read-only from shims (is_root allowlist) → reserved.
    try std.testing.expect(isCustomerWriteReserved("_admin/operator/abc"));
}

test "isCustomerWriteReserved: whole leading-_ keyspace reserved" {
    // The pre-customer lock-in fix: ANY leading-`_` key not in the
    // shim-writable allowlist is reserved, including ones with no platform
    // owner today (so we can claim them later). Retired prefixes
    // (`_events/`, `_outbox/`, `_dlq/`) and bare `_foo` are now reserved.
    try std.testing.expect(isCustomerWriteReserved("_events/sid/0001"));
    try std.testing.expect(isCustomerWriteReserved("_outbox/abc"));
    try std.testing.expect(isCustomerWriteReserved("_dlq/abc"));
    try std.testing.expect(isCustomerWriteReserved("_outbox_inflight/abc"));
    try std.testing.expect(isCustomerWriteReserved("_my_data"));
    try std.testing.expect(isCustomerWriteReserved("_"));
    try std.testing.expect(isCustomerWriteReserved("_anything/at/all"));
}

test "isCustomerWriteReserved: shim-writable prefixes allowed" {
    // The JS shims write these from customer handler context, so they
    // must remain writable through `kv.set` (see SHIM_WRITABLE_PREFIXES).
    try std.testing.expect(!isCustomerWriteReserved("_send/owed/abc"));
    try std.testing.expect(!isCustomerWriteReserved("_blob/owed/deadbeef"));
    try std.testing.expect(!isCustomerWriteReserved("_sched/by_id/abc"));
    try std.testing.expect(!isCustomerWriteReserved("_sched/by_time/000/abc"));
    try std.testing.expect(!isCustomerWriteReserved("_seg/room/h/0001"));
    try std.testing.expect(!isCustomerWriteReserved("_oidc/session/sid"));
    try std.testing.expect(!isCustomerWriteReserved("_rp/sess/sid"));
}

test "isCustomerWriteReserved: customer (non-_) keys allowed" {
    try std.testing.expect(!isCustomerWriteReserved(""));
    try std.testing.expect(!isCustomerWriteReserved("users/alice"));
    try std.testing.expect(!isCustomerWriteReserved("my_audit/"));
    try std.testing.expect(!isCustomerWriteReserved("orders/123"));
}
