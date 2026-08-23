// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
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
//! Also home to the handler-facing LIMITS every engine must agree on (the kv
//! byte caps, the `request.tag` bounds). They sit in this leaf for the same
//! reason the prefixes do: the offline engines have to read them without
//! importing the stack that gives them meaning, and a number transcribed into
//! three preludes is three numbers waiting to disagree.
//!
//! - `isCustomerWriteReserved` (runtime guard on `kv.set` / `kv.delete`):
//!   the ENTIRE leading-`_` keyspace is platform-reserved against customer
//!   writes, EXCEPT the `SHIM_WRITABLE_PREFIXES` the JS shims must write
//!   from ordinary handler context. Reserving the whole namespace (rather
//!   than an enumerated list) means any NEW platform `_…/` key family is
//!   safe to introduce later without colliding with customer data
//!   (docs/architecture/format-versioning.md §7.1).
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
///   `_dispatch/`        → `platform.dispatch` owed markers
///                         (`_dispatch/owed/{id}`) + their scheduler
///                         idempotency keys. Shim-writable — see
///                         `SHIM_WRITABLE_PREFIXES`.
///   `_callback/`        → reserved receipt prefix (sends resolve via
///                         in-memory Completions + `_send/proof/`, not
///                         `_callback/` rows). Stays reserved so customer
///                         JS can't spoof a receipt key.
///   `_keys/`            → crypto-shredding: the slot counter
///                         (`_keys/next_slot`), identity→slot bindings
///                         (`_keys/bind/`) and destroy tombstones
///                         (`_keys/dead/`). A tenant that could write
///                         here could hand itself another identity's
///                         key, or forge an erasure it never performed.
///   `_log/`             → per-tenant log metadata in app.db. Today
///                         only `_log/next_request_seq` lives here
///                         (in app.db, not log.db, so the worker opens
///                         no log.db).
///   `_magic/`           → magic-link tokens (root.db only, but list-wide)
///   `_triggers/`        → trigger module bytecode (manifest, not app.db)
///   `_sessions/`        → reserved for future platform session storage
///   `_usage/`           → per-tenant stored-byte accounting: one row per
///                         stored object plus the folded total
///                         (`src/kv/usage.zig`). Written ONLY by platform
///                         Zig at apply time. It must stay outside
///                         `SHIM_WRITABLE_PREFIXES` below — this is the
///                         number the storage quota is enforced against, so
///                         a tenant that could write it could zero its own
///                         meter.
///
/// Used only by `isReservedTriggerPrefix` (the deploy-load trigger guard).
/// The customer-WRITE guard does not pivot on this enumerated list — it
/// reserves the whole leading-`_` keyspace minus `SHIM_WRITABLE_PREFIXES`
/// (see below). This list is the catalog of *known* platform-owned
/// namespaces for the bidirectional trigger-prefix collision check.
pub const PLATFORM_KV_PREFIXES = [_][]const u8{
    "_app/",
    "_audit/",
    "_config/",
    "_deploy/",
    "_dispatch/",
    "_callback/",
    "_keys/",
    "_log/",
    "_magic/",
    "_triggers/",
    "_sessions/",
    "_usage/",
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
/// (docs/architecture/format-versioning.md §7.1 option (a)); deferred.
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
    // `@rewind/export` writes the export job's marker from handler context,
    // the same way `webhook.send` writes `_send/owed/`. A tenant can
    // therefore alter its OWN export bookkeeping — identical posture to
    // `_sched/` and `_send/`, and `__system/export_run` treats the record
    // defensively (unparseable ⇒ drop the chain rather than re-fire).
    "_export/",
    // `platform.dispatch`'s owed marker (globals/platform.js) — the same
    // posture as `_send/`: platform-managed, written from handler context by
    // the shim, and only ever the dispatching tenant's own bookkeeping.
    "_dispatch/",
    "_send/",
    "_blob/",
    "_sched/",
    "_seg/",
    "_oidc/",
    "_rp/",
};

/// The config namespace, as a HANDLER names it: `_config/oauth/default`.
pub const CONFIG_PREFIX = "_config/";

/// Longest storage key `configStorageKey` can produce for a legal config key —
/// the visible key plus `{dep_id:016x}/`.
pub const CONFIG_STORAGE_KEY_MAX = KV_KEY_MAX + 17;

/// `key` is one a handler names in the config namespace.
pub fn isConfigKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, CONFIG_PREFIX);
}

/// Where a config key LIVES, given the deployment whose activation is asking.
///
/// A handler names config by its deployed path (`_config/oauth/default`);
/// storage holds it under the deployment that shipped it
/// (`_config/{dep_id:016x}/oauth/default`). The indirection exists so code and
/// config switch at the same instant: `dep_id` is a content hash, so those rows
/// are immutable and write-once, the mirror that produces them is order-free
/// and idempotent, and the single-key `_deploy/current` flip is what makes a
/// deployment's config visible — atomically, and in both directions, including
/// a rollback and a deploy that REMOVES a key.
///
/// Flattening config into one shared mutable namespace is what made those three
/// cases race, and the failure was asymmetric: new code against old config
/// throws out of `fromConfig` ("config not found … Did you deploy the file?"),
/// while old code against new config ignores the keys it does not know.
///
/// `dep_id == 0` means "no deployment" — an authored world in the offline sim
/// or the replay arena, which has no release to scope by. Those read and write
/// the visible key unchanged, so a seeded world behaves as the handler wrote
/// it. Returns null if the result would not fit `buf`.
pub fn configStorageKey(buf: []u8, dep_id: u64, visible: []const u8) ?[]const u8 {
    if (dep_id == 0 or !isConfigKey(visible)) return visible;
    const rest = visible[CONFIG_PREFIX.len..];
    return std.fmt.bufPrint(buf, "{s}{x:0>16}/{s}", .{ CONFIG_PREFIX, dep_id, rest }) catch null;
}

/// The platform namespaces a handler cannot SEE — not merely cannot write.
///
/// A key here is engine bookkeeping that no handler has business observing:
/// the storage meter the quota is enforced against, the crypto slot counter,
/// receipt and token prefixes reserved so customer JS cannot forge one. They
/// are invisible rather than refused, because that is the honest description
/// of what they are: engine state that happens to live in the same store, not
/// keys of the tenant's that are locked.
///
/// The invariant this buys: **an engine write to a key no handler can observe
/// needs no activation and no log record**, because nothing a handler sees
/// ever moved. That is what lets `_usage/` and `_keys/next_slot` stay engine
/// writes while every handler-visible namespace gets an activation behind it.
/// Reads are recorded, so the converse matters too — a readable meter would
/// put a platform billing number in the customer's own tape, which redaction
/// cannot fix (a redacted input replays differently).
///
/// NOT here, deliberately: `_config/` and `_deploy/` (documented
/// customer-readable — their writers owe an activation instead), and every
/// `SHIM_WRITABLE_PREFIXES` entry (the tenant's own durability markers).
pub const ENGINE_ONLY_PREFIXES = [_][]const u8{
    "_usage/",
    "_keys/",
    "_callback/",
    "_magic/",
    "_triggers/",
    "_sessions/",
    "_log/",
};

/// `key` is engine-only: a handler read must behave as though it is absent.
pub fn isEngineOnly(key: []const u8) bool {
    if (key.len == 0 or key[0] != '_') return false;
    for (ENGINE_ONLY_PREFIXES) |p| {
        if (std.mem.startsWith(u8, key, p)) return true;
    }
    return false;
}

/// A scan at `prefix` can reach engine-only keys without being inside one —
/// `""`, `"_"`, `"_u"`. Such a scan has to skip them AND keep filling its
/// page, or a run of hidden rows longer than the page truncates the
/// customer's scan: the documented idiom pages until a page comes back empty
/// (`handler-shape.md` §5.7), so an all-hidden page reads as "end of data"
/// and everything after it is silently lost.
pub fn scanSpansEngineOnly(prefix: []const u8) bool {
    for (ENGINE_ONLY_PREFIXES) |p| {
        if (std.mem.startsWith(u8, p, prefix)) return true;
    }
    return false;
}

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
    // `_send/` is NOT reserved — webhook.send (JS shim) writes the
    // marker as ordinary customer-tenant kv.
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
    // Crypto-shredding state. A handler that could write these could
    // rebind itself onto another identity's key (`_keys/bind/`), forge
    // an erasure (`_keys/dead/`), or hand itself a slot range
    // (`_keys/next_slot`).
    try std.testing.expect(isCustomerWriteReserved("_keys/next_slot"));
    try std.testing.expect(isCustomerWriteReserved("_keys/bind/0011223344556677"));
    try std.testing.expect(isCustomerWriteReserved("_keys/dead/0000000000001001"));
    // `_admin/` is read-only from shims (is_root allowlist) → reserved.
    try std.testing.expect(isCustomerWriteReserved("_admin/operator/abc"));
}

test "isCustomerWriteReserved: the storage meter is not writable by what it meters" {
    // `_usage/` holds the stored-byte rows + the folded total the storage
    // quota is checked against (`src/kv/usage.zig`). A tenant able to write
    // it could zero its own meter, so — unlike the `_blob/` durability
    // markers beside it — this one must never join SHIM_WRITABLE_PREFIXES.
    try std.testing.expect(isCustomerWriteReserved("_usage/blob_bytes"));
    try std.testing.expect(isCustomerWriteReserved("_usage/blob/app/" ++ "a" ** 64));
    try std.testing.expect(isCustomerWriteReserved("_usage/blob/file/" ++ "b" ** 64));
    for (SHIM_WRITABLE_PREFIXES) |p| {
        try std.testing.expect(!std.mem.startsWith(u8, "_usage/", p));
    }
}

test "isCustomerWriteReserved: whole leading-_ keyspace reserved" {
    // ANY leading-`_` key not in the shim-writable allowlist is reserved,
    // including ones with no platform owner today (so we can claim them
    // later). Prefixes like `_events/`, `_outbox/`, `_dlq/` and bare `_foo`
    // are reserved too.
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

/// The customer-facing kv write caps, in BYTES.
///
/// They live in this leaf because they are a CONTRACT — "a key is at most
/// 256 bytes" is something a handler author reads and every engine must
/// agree on — while their physical justification is the snapshot stream's
/// frame bounds (`kv/snapshot_stream.zig`). The worker enforces them at the
/// native; the offline engines enforce them in JS through the shared guard
/// (`src/replay/js/kv_guards.js`), which reads these values generated into
/// its prelude rather than transcribing them.
///
/// `src/js/globals.zig` holds a test binding these to the stream constants,
/// so raising the frame bound without raising the contract (or the reverse)
/// fails the build rather than surfacing as one engine refusing a write
/// another accepted. Conservative by design: these can be RAISED later
/// without breaking anyone, never lowered.
pub const KV_KEY_MAX: usize = 256;

/// Longest `request.shredKey(id)` identity, in bytes.
///
/// A CONTRACT like the kv caps beside it: every engine must agree on what
/// a handler may pass, or a handler is refused by one and accepted by
/// another. Sized so the identity plus its `_keys/bind/` prefix fits
/// `KV_KEY_MAX` with room to spare — though what actually lands in the
/// key is a fixed-width HMAC of the identity, never the identity itself,
/// so this bounds what a handler may HOLD rather than what is stored.
///
/// Conservative on purpose: raising it later breaks nobody, lowering it
/// breaks handlers that already shipped.
pub const SHRED_KEY_MAX: usize = 128;

/// How many identities one activation may destroy.
///
/// A safety bound, not a resource one — erasure is free in storage terms
/// and permanent in every other. The cap exists because a handler-facing
/// destroy means a loop with a bug can erase customer data irreversibly,
/// and nothing downstream can undo it. Small enough that a runaway loop
/// stops immediately; large enough for the real case of one person
/// holding a handful of related identities.
///
/// Distinct from the cap on NEW identities (#609), which is a resource
/// bound: minting is a permanent commitment no cleanup reclaims, while
/// destroying reclaims nothing and commits nothing.
///
/// Per activation rather than per tenant per hour because that needs no
/// durable counter and still bounds the failure that matters — a handler
/// iterating a list it should not have.
pub const SHRED_DESTROY_MAX_PER_ACTIVATION: usize = 8;

/// Marks a kv value that is SEALED under a per-identity key.
///
/// A CONTRACT, and it lives here for the same reason the kv caps do:
/// every engine must agree on it, and the offline engines must be able to
/// recognise a sealed value WITHOUT linking the crypto primitive. The
/// browser arena deliberately does not link `rove-crypt` at all — PLAN
/// §2.7 locks no client-side key distribution — so it can recognise one
/// and refuse, but never open it.
///
/// `0xFF` specifically because it is not a legal byte in UTF-8, nor in
/// the WTF-8 a lone surrogate produces. Customer values reach the engine
/// through `JS_ToCStringLen` and so are UTF-8, which makes the test exact
/// rather than probabilistic — and means no value already stored can
/// collide with it.
///
/// Platform values are NOT UTF-8 and may legitimately begin with this
/// byte. They are never sealed and never tested: every one lives under a
/// reserved `_` prefix, which customer keys cannot use.
pub const SEAL_MARKER: u8 = 0xFF;

/// Is this a sealed customer value? Only meaningful for customer keys.
///
/// Ask this where the value's RAW BYTES are still in hand — the store, or
/// a tape being transcoded. Do not ask it downstream of any text decode:
/// the property that makes the marker unambiguous is that it is not legal
/// UTF-8, and every offline path decodes tape values as text, so the byte
/// does not survive. JSON turns it into a different code point and
/// `TextDecoder` turns it into U+FFFD, both silently.
///
/// That is not a limitation to work around — it is why the decision about
/// a sealed value is made once, by whoever serves the record, and never
/// re-derived by a reader further down.
pub fn isSealedValue(value: []const u8) bool {
    return value.len > 0 and value[0] == SEAL_MARKER;
}
/// 384 KiB, and the ceiling above it is not storage but REPLICATION: a write
/// rides one raft entry, one entry rides one raft message, and a message above
/// the receiver's fixed buffer cannot be delivered at all
/// (`consensus/transport.zig` `MAX_ENTRY_BYTES`, asserted against this
/// constant in `src/js/raft_propose.zig`). A value the guard admits must be
/// one a follower can receive — otherwise the platform accepts a write at the
/// call site and fails it during replication, which is a fault where a rule
/// belongs.
///
/// Sized to leave the shipped `blob.write` recipe intact: its inline append
/// cap is 256 KiB, which base64-encodes to ~342 KiB in one row.
pub const KV_VAL_MAX: usize = 384 * 1024;

/// What ONE ACTIVATION may write, in ops and in WIRE BYTES.
///
/// The reason is the same ceiling the value cap derives from: an activation's
/// writes ride one raft entry, together with the readset recording its reads.
/// A per-VALUE cap does not bound that — a thousand legal values do not fit —
/// so the budget is stated per activation, refused at the call site with a
/// code, and sized so an activation that stays inside it can always be
/// replicated:
///
///     writes + reads + framing < one raft entry
///
/// `rove-sizing` holds that partition and asserts it, so the two halves
/// cannot be sized independently against the same entry.
///
/// The unit is what the op puts ON THE WIRE — its key, its value, and the
/// nine bytes of writeset framing every op carries (`sizing.writeOpBytes`) —
/// not the key and value alone. A budget denominated in anything but the
/// bytes it is protecting is one the entry can still overflow: at the op
/// cap, framing alone is 9 KB the guard would not see.
///
/// The shape follows the transactional stores this competes with: Deno KV
/// caps an atomic operation at 1000 mutations or 800 KiB, whichever comes
/// first; DynamoDB at 100 items; Durable Objects at 128 pairs per `put()`.
/// A handler with more work than one budget continues in a NEW activation
/// (`next()` — `docs/handler-shape.md`), which keeps each activation a
/// bounded, replayable unit instead of growing the entry.
///
/// Held above `KV_VAL_MAX + KV_KEY_MAX` plus one op's framing, because the
/// two rules have to be satisfiable together: a value the guard calls legal
/// must be writable — under its key — by a handler that has written nothing
/// else. (The key is why this is not simply equal to the value cap: a
/// max-size value under a max-size key spends both.) The balanced split this
/// wants — value 128 KiB (what Durable Objects promises), writes 256 KiB,
/// reads 128 KiB — needs `blob.write`'s inline append to stop putting up to
/// 256 KiB (≈342 KiB base64) in a single kv row and spill to a `{ref}` row
/// instead, which is what `docs/architecture/blob-write-recipes.md` says
/// those rows are for. Until then the value cap is the floor under this
/// number, and the read budget is what pays for it.
pub const KV_WRITES_MAX: u32 = 1000;
pub const KV_WRITE_BYTES_MAX: usize = 400 * 1024;

/// `request.tag` limits — the low-cardinality index tags a handler may set.
///
/// Same reason the kv caps are here: a handler author reads "at most 4 tags"
/// as a contract, and three engines have to agree on it. `src/log/root.zig`
/// owns the storage-side meaning (`MAX_TAGS` et al) and a test in
/// `globals_request.zig` binds the two.
pub const TAG_MAX: usize = 4;
pub const TAG_KEY_MAX: usize = 32;
pub const TAG_VAL_MAX: usize = 64;

/// The capability names — the ambient globals that REACH OUTSIDE the module
/// and therefore arrive as part of the activation object rather than as free
/// variables (`docs/architecture/package-isolation.md`, the classification
/// rule; tracker #753).
///
/// Here for the same reason the caps and tag limits above are: three engines
/// have to agree, and the worker, the offline replay driver and the browser
/// arena each build the activation object separately. A name added to one
/// engine's list and not the others is a capability that is passable in one
/// place and not another — which reads as a handler bug, far from the cause.
///
/// The pure and web-platform names (`crypto`, `console`, `time`,
/// `base64url`, `hex`, `atob`/`btoa`, `TextEncoder`/`TextDecoder`,
/// `URLSearchParams`) stay ambient and are deliberately absent.
///
/// `src/js/globals.zig`'s capability-template test asserts the RUNTIME
/// template against this list by identity, so a name here that no shim
/// installs fails the build rather than yielding an undefined member.
pub const CAPABILITY_NAMES = [_][]const u8{
    "after",
    "blob",
    "http",
    "kv",
    "next",
    "platform",
    "stream",
    "webhook",
};

/// The capability list as a JS object-literal body (`a, b, c,`), for the
/// engines that build their activation object by evaluating source.
pub fn capabilityLiteralBody() []const u8 {
    comptime {
        var out: []const u8 = "";
        for (CAPABILITY_NAMES) |n| out = out ++ n ++ ", ";
        return out;
    }
}

test "isEngineOnly: engine namespaces are hidden, customer keys are not" {
    try std.testing.expect(isEngineOnly("_usage/blob/deadbeef"));
    try std.testing.expect(isEngineOnly("_keys/next_slot"));
    try std.testing.expect(isEngineOnly("_callback/abc"));
    try std.testing.expect(isEngineOnly("_log/next_request_seq"));
    try std.testing.expect(!isEngineOnly("users/1"));
    try std.testing.expect(!isEngineOnly(""));
    // A customer key that merely LOOKS like one: the match is on the
    // namespace, not on the substring.
    try std.testing.expect(!isEngineOnly("my_usage/x"));
}

test "isEngineOnly: handler-readable platform namespaces stay visible" {
    // `_config/` is documented customer-readable and `_deploy/` is read by
    // the tenant — their writers owe an activation instead of hiding.
    try std.testing.expect(!isEngineOnly("_config/mail/default.json"));
    try std.testing.expect(!isEngineOnly("_deploy/current"));
    // Shim-writable durability markers are the tenant's own.
    for (SHIM_WRITABLE_PREFIXES) |sp| try std.testing.expect(!isEngineOnly(sp));
}

test "scanSpansEngineOnly: only an ancestor of a hidden namespace spans it" {
    try std.testing.expect(scanSpansEngineOnly("")); // the full scan
    try std.testing.expect(scanSpansEngineOnly("_"));
    try std.testing.expect(scanSpansEngineOnly("_u"));
    try std.testing.expect(scanSpansEngineOnly("_usage/")); // itself
    // The common case: an ordinary customer prefix pays nothing.
    try std.testing.expect(!scanSpansEngineOnly("users/"));
    try std.testing.expect(!scanSpansEngineOnly("_send/"));
    try std.testing.expect(!scanSpansEngineOnly("_config/"));
    // Deeper than the namespace is inside it, not spanning it — the scan is
    // wholly hidden and the binding answers empty without touching storage.
    try std.testing.expect(!scanSpansEngineOnly("_usage/blob/"));
    try std.testing.expect(isEngineOnly("_usage/blob/"));
}

test "configStorageKey: a handler's name resolves under its own deployment" {
    var buf: [CONFIG_STORAGE_KEY_MAX]u8 = undefined;
    try std.testing.expectEqualStrings(
        "_config/000000000000002a/oauth/default",
        configStorageKey(&buf, 42, "_config/oauth/default").?,
    );
    // Two deployments name the same config path and do not collide — which is
    // what lets the pointer flip be the transaction.
    try std.testing.expectEqualStrings(
        "_config/00000000000000ff/oauth/default",
        configStorageKey(&buf, 255, "_config/oauth/default").?,
    );
}

test "configStorageKey: no deployment, or not config, passes through" {
    var buf: [CONFIG_STORAGE_KEY_MAX]u8 = undefined;
    // An authored world in the sim or the replay arena has no release to scope
    // by, so a seeded key reads back exactly as it was written.
    try std.testing.expectEqualStrings("_config/oauth/default", configStorageKey(&buf, 0, "_config/oauth/default").?);
    // Everything outside the namespace is untouched at any deployment.
    try std.testing.expectEqualStrings("users/1", configStorageKey(&buf, 42, "users/1").?);
    try std.testing.expectEqualStrings("_send/owed/x", configStorageKey(&buf, 42, "_send/owed/x").?);
}

test "configStorageKey: a key too long for the buffer is refused, not truncated" {
    var small: [8]u8 = undefined;
    try std.testing.expect(configStorageKey(&small, 42, "_config/oauth/default") == null);
}
