// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The kv-keyspace contract every engine must agree on: the handler-facing
//! LIMITS (the kv byte caps, the `tag` bounds), the user root every
//! handler-named key resolves under, and the config storage-key rule.
//!
//! They sit in this leaf because the offline engines have to read them
//! without importing the stack that gives them meaning, and a number
//! transcribed into three preludes is three numbers waiting to disagree.
//!
//! What used to live here — the reserved-prefix lists and the four
//! predicates that policed them (`isCustomerWriteReserved`, `isEngineOnly`,
//! `scanSpansEngineOnly`, `isReservedTriggerPrefix`) — is retired (#862).
//! The boundary they enforced is now structural: a handler's capability is
//! rooted (`USER_KEY_ROOT`), so the engine keyspace is not refused, it is
//! UNNAMEABLE, and a predicate consulted on every write has nothing left to
//! decide (`docs/architecture/package-isolation.md`, not installing is the
//! denial). The raw door keeps its own gate (`rootKvGate`), which is a
//! per-activation check on a capability, not a keyspace scan.

const std = @import("std");


/// The config namespace, as a HANDLER names it: `_config/oauth/default`.
pub const CONFIG_PREFIX = "_config/";

/// Longest storage key `configStorageKey` can produce for a legal config key —
/// the visible key plus `{dep_id:016x}/`.
pub const CONFIG_STORAGE_KEY_MAX = KV_KEY_MAX + 17;

/// The root every handler-named key resolves under.
///
/// A handler names `orders/42`; storage holds `_user/orders/42`, and it never
/// learns the difference. Engine bookkeeping lives outside this root, so a
/// handler cannot *name* an engine key — the boundary is the shape of the
/// capability it was handed, not a predicate consulted on every write
/// (`docs/architecture/package-isolation.md`, not installing is the denial).
///
/// The leading `_` matters: it keeps the root outside the keyspace reachable
/// from inside it, so a handler cannot address its own root and `_user/`
/// cannot nest into itself.
pub const USER_KEY_ROOT = "_user/";

/// `KV_KEY_MAX` is LOGICAL — it bounds the key a handler NAMES, and the root
/// is invisible to it, so the root costs the handler nothing. This is what a
/// resolved key can reach: the largest root plus the largest legal name.
/// Config's `{dep_id:016x}/` insert is the other resolution and is measured
/// the same way, so a buffer sized to this holds either.
pub const STORAGE_KEY_MAX = KV_KEY_MAX + @max(USER_KEY_ROOT.len, 17);

/// A STORE-spelled key back in the spelling the handler named — the one
/// inverse of the root, for the presentation seams.
///
/// Everything at or below persistence carries the root: the store, the
/// writeset, and the kv TAPE (whose storage-modeling entries feed replay
/// overlays verbatim, so they are keyed the way the store is). The named
/// spelling exists only at the handler surface, in matching and the digest,
/// and in anything RENDERED for the person who wrote `kv.get("orders/42")` —
/// a seam view, a divergence message, a transcoded world. Those render
/// through this function, so the root never leaks into prose and there is
/// exactly one strip per seam instead of a per-consumer spelling rule.
///
/// A key outside the root passes through unchanged: engine keys (a system
/// activation's raw writes, the offline harness's `__rove_store/` facade)
/// have no named spelling other than themselves.
pub fn userNamedKey(stored: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, stored, USER_KEY_ROOT)) return stored;
    return stored[USER_KEY_ROOT.len..];
}

test "userNamedKey strips exactly the user root" {
    try std.testing.expectEqualStrings("orders/42", userNamedKey("_user/orders/42"));
    // The root does not nest: one strip is the whole inverse.
    try std.testing.expectEqualStrings("_user/x", userNamedKey("_user/_user/x"));
    // Engine keys and facade keys are their own spelling.
    try std.testing.expectEqualStrings("_deploy/current", userNamedKey("_deploy/current"));
    try std.testing.expectEqualStrings("__rove_store/r/x", userNamedKey("__rove_store/r/x"));
    try std.testing.expectEqualStrings("", userNamedKey(""));
}

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

/// Longest `shredKey(id)` identity, in bytes.
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

/// `tag` limits — the low-cardinality index tags a handler may set.
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
    "config",
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

/// Capabilities in the CUSTOMER set only. A baked `__system/` activation's
/// template (`SYSTEM_CAPABILITY_NAMES`) omits them:
///
///   - `kv` — a baked module holds ONE kv, the storage-rooted `rootKv`
///     (#848), and spells the user root explicitly when it wants a row a
///     handler named. Handing both spellings to one module is the
///     writer/reader prefix-depth hazard: the same row nameable at two
///     depths, and the mismatch surfaces as a scan that silently misses.
///
/// Every name here must also appear in `CAPABILITY_NAMES` — the comptime
/// derivation below fails the build otherwise, so this list cannot drift
/// into naming a capability that does not exist.
pub const CUSTOMER_ONLY_CAPABILITY_NAMES = [_][]const u8{
    "kv",
};

/// The capability set a baked `__system/` activation receives instead of the
/// customer one — selected by code origin when the activation object is
/// assembled (`package-isolation.md`: which set an activation holds is
/// decided at assembly; not installing is the denial). Derived, not
/// restated: `CAPABILITY_NAMES` minus `CUSTOMER_ONLY_CAPABILITY_NAMES`.
pub const SYSTEM_CAPABILITY_NAMES = blk: {
    var count: usize = 0;
    for (CAPABILITY_NAMES) |n| {
        if (!nameInList(n, &CUSTOMER_ONLY_CAPABILITY_NAMES)) count += 1;
    }
    // Every customer-only name must subtract a real member, or the list
    // names a capability that does not exist.
    if (count != CAPABILITY_NAMES.len - CUSTOMER_ONLY_CAPABILITY_NAMES.len)
        @compileError("CUSTOMER_ONLY_CAPABILITY_NAMES has a name not in CAPABILITY_NAMES");
    var out: [count][]const u8 = undefined;
    var i: usize = 0;
    for (CAPABILITY_NAMES) |n| {
        if (!nameInList(n, &CUSTOMER_ONLY_CAPABILITY_NAMES)) {
            out[i] = n;
            i += 1;
        }
    }
    break :blk out;
};

fn nameInList(name: []const u8, list: []const []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// `SYSTEM_CAPABILITY_NAMES` as a JS object-literal body, the system-set
/// twin of `capabilityLiteralBody`.
pub fn systemCapabilityLiteralBody() []const u8 {
    comptime {
        var out: []const u8 = "";
        for (SYSTEM_CAPABILITY_NAMES) |n| out = out ++ n ++ ", ";
        return out;
    }
}

/// Members of the activation object that are sourced from `request` rather
/// than from a global — the three effects that hid on a documented data
/// shape (`docs/architecture/package-isolation.md` §3.4):
///
///   - `tag`        writes the durable, OTel-exported log record against a
///                  SHARED 4-slot budget that throws on over-cap, so a
///                  package can exhaust it and make the handler's own call
///                  fail;
///   - `unmaskedIp` the deliberate escalation past `request.ip`'s masking;
///   - `shredKey`   sets the activation's crypto-shred identity, and
///                  REPLACES rather than adds — so a package can silently
///                  re-file the handler's writes under another erasure
///                  identity.
///
/// They are reachable ONLY on the activation object (#849) — `request` is a
/// data shape and carries no effects. Their natives ignore the receiver
/// (`binding.Tag`/`ShredKey` resolve state from the context), so where the
/// function object is exposed binds nothing.
/// NUL-terminated: the worker hands these straight to `JS_SetPropertyStr`,
/// which takes a C string.
pub const REQUEST_EFFECT_NAMES = [_][:0]const u8{
    "tag",
    "unmaskedIp",
    "shredKey",
};

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
