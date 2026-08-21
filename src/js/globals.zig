// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! JS globals installed on every request context.
//!
//! Two families of surface are installed:
//!
//!   - **Static namespaces** (`installStatic`, once into the base
//!     snapshot, shared across all requests on the thread): `kv`,
//!     `console`, `crypto`, `webhook`, `platform`, and the JS-shim
//!     helpers evaluated from `globals/*.js`.
//!   - **Per-request objects** (`installRequest`, one cursor write per
//!     request): a read-only `request` (`method`, `path`, `host`,
//!     `body`, `query`, `headers`, `cookies`, `session`, `activation`,
//!     ...) and a writable `response` (`status`, `body`, `headers`).
//!
//! State shared between the C functions and the dispatcher lives in a
//! `DispatchState` struct stashed on the context via
//! `JS_SetContextOpaque`. The C callbacks pull the state pointer out of
//! the context on every call.

const std = @import("std");
const qjs = @import("rove-qjs");
const kv_mod = @import("raft-kv");
const tape_mod = @import("rove-tape");
const log_mod = @import("rove-log");
const tenant_mod = @import("rove-tenant");
const h2 = @import("rove-h2");
const rove = @import("rove");
const limiter_mod = @import("limiter.zig");
const crypto_b = @import("bindings/crypto.zig");
const crypto_jose_b = @import("bindings/crypto_jose.zig");
const crypto_ecdsa_b = @import("bindings/crypto_ecdsa.zig");
const http_b = @import("bindings/http.zig");
const cont_b = @import("bindings/continuation.zig");
const stream_b = @import("bindings/stream.zig");
const scheduler_b = @import("bindings/scheduler.zig");
const on_b = @import("bindings/on.zig");
const blob_b = @import("bindings/blob.zig");
const blob_mod = @import("rove-blob");
const blob_sessions_mod = @import("blob_sessions.zig");
const textcodec_b = @import("bindings/textcodec.zig");
const reserved = @import("rove-reserved");
const bytecode_cache_mod = @import("bytecode_cache.zig");
const request_bindings = @import("globals_request.zig");
/// Interaction-digest folding, shared by every effect binding
/// (`src/tape/interaction_digest.zig`). Begin returns the digest so far —
/// seeded on first use, so a run with no interactions still has one — and
/// commit writes it back. Null when this activation has no readset (a
/// non-handler path), in which case the record carries no digest and its
/// replay is unverifiable rather than wrongly verified.
///
/// Folded AS the interaction happens: the order of a read against a write
/// cannot be recovered afterwards, because the two live in different
/// structures, and that order is part of what the handler did.
pub fn digestBegin(state: *DispatchState) ?tape_mod.interaction_digest.Digest {
    const rs = state.readset orelse return null;
    return .{ .h = if (rs.interaction_digest == 0)
        tape_mod.interaction_digest.Digest.init().h
    else
        rs.interaction_digest };
}

pub fn digestCommit(state: *DispatchState, d: tape_mod.interaction_digest.Digest) void {
    if (state.readset) |rs| rs.interaction_digest = d.h;
}

pub const installRequest = request_bindings.installRequest;
const platform_bindings = @import("globals_platform.zig");
const kv_bindings = @import("globals_kv.zig");

const c = qjs.c;

// Zig's @cImport can't translate quickjs-ng's designated-initializer
// macros for `JS_UNDEFINED` etc. (they trip `std.mem.zeroInit` on the
// anonymous union). Reconstruct them by hand — the layout is stable in
// non-NaN-boxing mode, which is what our Linux x86_64 build uses.
inline fn mkVal(tag: i64, val: i32) c.JSValue {
    return .{ .u = .{ .int32 = val }, .tag = tag };
}
pub const js_undefined: c.JSValue = mkVal(c.JS_TAG_UNDEFINED, 0);
pub const js_null: c.JSValue = mkVal(c.JS_TAG_NULL, 0);
pub const js_exception: c.JSValue = mkVal(c.JS_TAG_EXCEPTION, 0);
pub const js_true: c.JSValue = mkVal(c.JS_TAG_BOOL, 1);
pub const js_false: c.JSValue = mkVal(c.JS_TAG_BOOL, 0);

/// One row in a tenant's trigger registry. Built at deploy-load time
/// (worker.zig) from manifest paths matching `_triggers/.../index.{mjs,js}`.
/// `prefix` is what we match kv keys against; `module_path` is the
/// bytecode lookup key (into the deployment's bytecode map) and the
/// identity surfaced in error messages (e.g.
/// `"_triggers/users/sessions/index.mjs"`).
pub const TriggerEntry = struct {
    prefix: []u8,
    module_path: []u8,
};

/// The per-deployment hooks a dispatch consults DURING an activation
/// (both borrowed from the pinned snapshot): middleware triggers
/// (`_triggers/`, the kv.set before/after chains) and kv subscriptions
/// (`_subscriptions/`, whose watched-prefix writes inject the durable
/// `_sub/dirty/{name}` marker — durable-kv-subscriptions). Passed as
/// one optional pointer so test paths keep passing `null`.
pub const DeployHooks = struct {
    triggers: ?[]const TriggerEntry = null,
    subscriptions: []const SubscriptionEntry = &.{},
};

/// One row in a tenant's subscription registry — chain origins that
/// fire WITHOUT an inbound HTTP request. Built at deploy-load time
/// from `_subscriptions/<name>/spec.json` + `_subscriptions/<name>
/// /index.mjs` pairs. Chain origins under the four-primitive effect
/// model (`docs/effect-algebra.md`), run as streaming handlers
/// (`docs/architecture/effects-and-handlers.md`).
///
/// One kind (see `Spec` below): kv (apply-time fan-out from a
/// watched tenant prefix). Recurrence is instead the
/// `cron(spec, target)` verb over the durable scheduler; recurring
/// registrations are seeded from any handler activation (`_sched/*`
/// entries are durable kv and survive deploys). The handler is a
/// normal TEA `update`; the
/// difference is the activation source (`subscription_fire`) and
/// the absence of a held socket — `Response`/`__rove_next`/
/// `__rove_stream` returns are recorded on the tape but bytes
/// don't flush anywhere.
pub const SubscriptionEntry = struct {
    /// Human-readable name (from the directory under
    /// `_subscriptions/`). Surfaces as `request.activation.name`
    /// so handlers can self-identify and customers can debug.
    /// Allocator-owned.
    name: []u8,
    /// Bytecode lookup key into the deployment's bytecode map +
    /// identity in error messages. Always
    /// `"_subscriptions/<name>/index.mjs"` (or `.js`).
    module_path: []u8,
    /// What triggers this subscription's chain origin.
    spec: Spec,

    pub const Spec = union(enum) {
        /// Fire on any put/delete under `prefix` by ANY chain on
        /// this tenant. Mirrors the §4.6 parked-stream wake but as
        /// a chain origin (no parked stream required).
        kv: struct { prefix: []u8 },
    };

    pub fn deinit(self: *SubscriptionEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.module_path);
        switch (self.spec) {
            .kv => |kv_spec| allocator.free(kv_spec.prefix),
        }
        self.* = undefined;
    }
};

/// Write op for the `platform.scope(id).kv` cross-tenant accessor
/// trampoline. Reads (get/prefix) go direct and need no trampoline.
pub const ScopeKvOp = enum { put, delete };

/// Gap 2.3: in-memory carrier for an `http.fetch` request
/// awaiting transport. Lives on `DispatchState.pending_fetches`
/// during the handler's run; flushed to `NodeState.fetch_pending`
/// at end-of-handler; consumed by the `NodeState.fetch_pool`
/// thread which fires libcurl + delivers chunks via the
/// per-worker `fetch_chunk_inbox`.
///
/// All slices allocator-owned. Fetches are non-durable, never
/// written to kv/raft, so no wire-format codec is needed. The
/// durable sibling (`webhook.send`) lives entirely in JS shims
/// (`globals/webhook.js` + the baked `__system/webhook_onresult`
/// module) layered on top of this primitive — see the reified
/// primitives (`docs/architecture/effects-and-handlers.md`).
pub const PendingFetch = struct {
    /// The tenant that issued this fetch — needed so the fetch
    /// pool can hash-route chunks to the right worker's inbox.
    tenant_id: []u8,
    /// Deterministic fetch id (sha256 of request_id + "FTCH" +
    /// fetch_index). 64-hex chars.
    id: []u8,
    url: []u8,
    method: []u8,
    headers_json: []u8,
    body: []u8,
    timeout_ms: u32,
    /// Module path for `fetch_chunk` activations. Always set — every
    /// fetch routes its chunk events through a module path.
    on_chunk_module: []u8,
    /// Threaded forward to each activation as `request.ctx`. JSON
    /// string; "null" when omitted.
    ctx_json: []u8,
    /// `stream: false` (default) emits exactly one
    /// `fetch_chunk` event (with `final: true`, up to
    /// `max_response_chunk_bytes` of body; cap-overflow sets
    /// `body_truncated`). `stream: true` emits one event per
    /// upstream writeback (last carrying `final: true`).
    stream: bool,
    max_response_chunk_bytes: u32,
    max_total_response_bytes: u64,
    /// Held outbound subscription (gap 2.5) on the outbound fetch /
    /// libcurl-multi engine
    /// (`docs/architecture/configuration-and-network.md`). When true,
    /// the FetchEngine treats this as a
    /// long-lived transfer: no timeout, counted against the
    /// per-tenant held-subscription cap, terminal event always
    /// signals `ok=false` so the customer's handler interprets
    /// completion as "subscription ended; reconnect if you want
    /// it back." Held=false → normal `http.fetch` semantics.
    held: bool = false,

    /// The streaming substrate (`docs/architecture/routing-and-ingress.md`)
    /// + `docs/handler-shape.md` §5.5: bound fetch. When true, upstream
    /// chunks resume the
    /// **calling chain** (the entity that issued the fetch from a
    /// handler returning `next()`/`stream()`) instead of firing a
    /// separate `fetch-<id>` chain. The held client's response
    /// socket stays open across the bound fetch's lifetime; the
    /// resume engine dispatches the held module's `onFetchChunk`
    /// named export per chunk. `bind=false` → Pattern A
    /// (`fireFetchEventActivation`, separate chain, no held socket).
    /// Held state (`docs/architecture/effects-and-handlers.md`):
    /// COMPUTED at the handler-success seam (only `connection_scoped`
    /// on.fetch binds), not a JS keyword.
    bind: bool = false,
    /// This PUT carries one part of a data export, so it stores into the
    /// tenant's `exports/` pool instead of `app-blobs/` and is NOT metered
    /// against `max_stored_bytes` (rove#429).
    ///
    /// A FLAG rather than a distinct door URL, and that is the whole security
    /// argument: the blob door is reachable by ordinary customer JS (which is
    /// why #367 exists), so an `exports/`-selecting URL would be an
    /// unmetered-storage hole any handler could name. This field is written in
    /// exactly one place — the engine's own export-Cmd rewrite
    /// (`Worker.rewriteKvExport`) — and no JS option maps to it, the same
    /// posture that makes `tenant_id` and `bind` unforgeable.
    ///
    /// Unmetered because the tenant did not choose to write these bytes and
    /// cannot delete them selectively; charging them makes a tenant at its cap
    /// unable to export, which lands on exactly the customer most likely to be
    /// leaving (`docs/strategy/pricing-model.md` — axis 3 is customer-chosen
    /// storage).
    export_part: bool = false,
    /// The CAS→connection relay (`docs/architecture/routing-and-ingress.md`):
    /// when true AND the fetch is a bound streaming read of a
    /// content-addressed door (`rove-static.internal`, or a
    /// `rove-blob.internal` GET), the engine splices intermediate
    /// chunk bytes straight onto the held stream — no per-chunk
    /// activation, no per-chunk log record. Exactly two activations
    /// remain: the first event (the decider — it commits the head +
    /// `stream.start()`) and the terminal (the observer — existing
    /// error handling applies). Ignored for any other fetch shape:
    /// the engine must own BOTH ends (immutable hash-named source,
    /// held connection sink) for the no-JS pump to be sound — a
    /// customer URL would drag the SSRF gate / caps / redirect
    /// policy into the pump (rove#441, option (a)).
    relay: bool = false,
    /// Cross-worker held state
    /// (`docs/architecture/effects-and-handlers.md`): when the
    /// `webhook.send` JS shim issues an `http.fetch` to drive a
    /// held-sync send, it stamps the send_id here so the chunk
    /// router (`enqueueFetchEventForTenant`) can consult
    /// `bound_send_owners[send_id]` and route the response to the
    /// cont's owning worker. Empty for plain (non-webhook) fetches.
    /// Allocator-owned dupe.
    bound_send_id: []u8 = &.{},
    /// Customer-facing `name:` override — see
    /// `bindings/http.zig` BuiltFetch.name. Empty → dispatcher
    /// uses `onFetchChunk` (default). Non-empty → dispatcher
    /// uses the supplied identifier as the named-export target.
    /// Allocator-owned.
    name: []u8 = &.{},
    /// True ⇒ issued via `on.fetch` (a
    /// CONNECTION trigger). The success seam binds it when the
    /// activation held the socket and DROPS it (inert, no unbound fire)
    /// when it didn't — connectionless outbound is `webhook.send`
    /// (`docs/handler-shape.md` §2.4). False for plain `http.fetch`.
    connection_scoped: bool = false,

    pub fn deinit(self: *PendingFetch, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.id);
        allocator.free(self.url);
        allocator.free(self.method);
        allocator.free(self.headers_json);
        allocator.free(self.body);
        allocator.free(self.on_chunk_module);
        allocator.free(self.ctx_json);
        if (self.bound_send_id.len > 0) allocator.free(self.bound_send_id);
        if (self.name.len > 0) allocator.free(self.name);
        self.* = undefined;
    }
};

/// Admin-tenant platform-capability trampolines, bundled so they are
/// set all-or-nothing (a request either has platform caps or it does
/// not — see `worker_dispatch`'s single `platform != null` gate). The
/// worker provides concrete fns that cast `ctx` back to their specific
/// `*Worker(opts)` type, keeping that generic type out of globals.zig.
/// One shared `ctx` (the opaque worker pointer) backs all three — they
/// are always set together from the same worker. Each fn stays
/// optional so the JS callable can throw a precise "not configured"
/// error on test/misconfigured paths (and so a test can wire just one).
/// How an activation turns the identity a handler named into the slot
/// whose key its writes seal under.
///
/// A capability the WORKER supplies, for the same reason `PlatformCaps`
/// is: resolving needs the tenant's slot pool, its keyring and its raft
/// group, none of which the dispatcher knows about — and threading the
/// worker's generic type through here would drag it into every engine
/// that shares this file.
///
/// Absent on the offline engines and in unit tests, where there is no
/// key material and nothing to seal. `request.shredKey` still validates
/// and still records the identity there, so the surface behaves the same
/// everywhere; only the slot is missing.
pub const ShredCaps = struct {
    ctx: *anyopaque,
    /// Resolve `identity` to its slot for `instance_id`, binding it to a
    /// fresh one if this is the first time the tenant has named it.
    ///
    /// A new binding is APPENDED TO `writeset` rather than proposed on
    /// its own: it rides the raft entry the activation was already
    /// sending, so naming an identity costs no extra round trip and no
    /// extra fsync on the request path.
    ///
    /// It goes through `txn` as well, and the two are inseparable. The
    /// writeset is what followers apply; the txn is what this node
    /// writes. A binding that reached only one of them would leave the
    /// leader and its followers disagreeing about which slot an identity
    /// holds — and the disagreement would surface as a value that opens
    /// on one node and reads as erased on another.
    ///
    /// `error.PoolEmpty` means no minted slot is available right now —
    /// the caller surfaces it rather than sealing under something else,
    /// because every fallback available at that moment is a silent
    /// downgrade of the erasure the handler asked for.
    resolve_slot: ?*const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        instance_id: []const u8,
        identity: []const u8,
        txn: *kv_mod.TrackedTxn,
        writeset: *kv_mod.WriteSet,
    ) anyerror!u64 = null,
};

pub const PlatformCaps = struct {
    ctx: *anyopaque,
    /// `platform.instances.deployStarter(name)`: deploy the embedded
    /// starter into the target tenant's manifest_backend + propose
    /// `_deploy/current = 1` through raft envelope 0.
    deploy_starter: ?*const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        target_id: []const u8,
    ) anyerror!void = null,
    /// `platform.releases.publish(tenant_id, dep_id)`: stamp
    /// `_deploy/current = dep_id` on the target's app.db, propose
    /// envelope-0 (fire-and-forget), enqueue the deployment loader.
    release_publish: ?*const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        target_id: []const u8,
        dep_id: u64,
    ) anyerror!void = null,
    /// `platform.scope(id).kv.{set,delete}`: self-contained cross-
    /// tenant write+commit+raft-propose to the target (envelope-0),
    /// deliberately OUTSIDE the dispatch batch txn — the scoped
    /// cross-tenant write (`docs/architecture/auth-and-domains.md`).
    /// Reads go direct via `state.platform.getInstance`.
    scope_kv_write: ?*const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        target_id: []const u8,
        op: ScopeKvOp,
        key: []const u8,
        value: []const u8,
    ) anyerror!void = null,
    // (Cross-tenant blob writes use `platform.scope(t).blob.receive` — the
    // streamed S3 sink — not a cap.)
};

/// §2.6 durable-wake fan-out input: one due `_sched/by_time` entry the
/// baked `__system/scheduler_tick` hands to `__rove_fire_wake`. All
/// slices borrow into the calling JS context's strings — valid only
/// for the duration of the builtin call; the trampoline
/// (`enqueueDurableWakeForTenant`) dupes everything it keeps.
pub const FireWakeInput = struct {
    /// Owning tenant (set by the builtin from `state.instance_id`).
    tenant_id: []const u8,
    /// Target handler module path (the scheduler entry's `target`).
    target: []const u8,
    /// Stable scheduler id.
    id: []const u8,
    /// Idempotency key, or null when scheduled without one.
    key: ?[]const u8,
    /// Absolute scheduled fire time (ns).
    scheduled_at_ns: i64,
    /// Customer `msg`, JSON-encoded ("null" when omitted).
    msg_json: []const u8,
    /// The entry's `_sched/` keys to delete in the target activation's
    /// writeset (the JS lib owns the exact key format).
    cleanup_keys: []const []const u8,
    /// The saga that armed the entry (`_sched/*.armed_by`), or null
    /// when absent. Provenance for the fired activation's `_parent`
    /// record tag — the fire still roots its own saga.
    armed_by: ?[]const u8 = null,
};

/// One `on.timer(ms)` / `on.kv(prefix,{to?})`
/// registration accumulated during the body. Mirrors the
/// `pending_fetches` accumulator shape — the binding appends, the
/// worker drains at end-of-activation and arms the held entity's
/// `StreamWakes` (`docs/handler-shape.md` §2.3). A
/// connection wake; inert (the accumulator is null) on connectionless
/// activations.
pub const PendingWakeReg = struct {
    pub const Kind = enum { timer, kv };
    kind: Kind,
    /// `.timer`: wake interval in ms.
    interval_ms: i64 = 0,
    /// `.kv`: tenant-scoped key prefix to watch. Allocator-owned by the
    /// accumulator list; the worker dups what it keeps onto the entity
    /// and the list's deinit frees the rest.
    prefix: []u8 = &.{},
    /// Resume export selector ("module.method" or a bare "method"), or
    /// null → the default `onWake` export. Allocator-owned. Mirrors the
    /// `{on}` opts key — one spelling from customer surface to here.
    on: ?[]u8 = null,

    pub fn deinit(self: *PendingWakeReg, allocator: std.mem.Allocator) void {
        if (self.prefix.len > 0) allocator.free(self.prefix);
        if (self.on) |t| allocator.free(t);
        self.* = undefined;
    }
};

pub const DispatchState = struct {
    allocator: std.mem.Allocator,
    /// Per-request KV store. `kv.get("x")` reads from this handle,
    /// which is the SAME connection the `TrackedTxn` opened its
    /// transaction on, so reads see the transaction's uncommitted
    /// writes — read-your-writes works within one handler.
    kv: *kv_mod.KvStore,
    /// Open tracked transaction on `kv`. Writes from the handler go
    /// through this (for local visibility + undo) AND through the
    /// `writeset` (for raft replication). Committed or rolled back
    /// after raft reports back — see `worker.drainRaftPending`.
    txn: *kv_mod.TrackedTxn,
    /// Raft write accumulator. Shape-parallel to the `TrackedTxn`'s
    /// local writes — followers replay the encoded writeset against
    /// their tenant stores via `applyEncodedWriteSet`.
    writeset: *kv_mod.WriteSet,
    /// `writeset.ops` length when THIS activation began. The writeset is
    /// BATCH-scoped (several same-tenant activations share it, one raft
    /// `multi` entry), but a record replays one activation alone — so the
    /// read-your-write tape elision must only treat keys written at or
    /// after this baseline as own-writes. A key an earlier activation in
    /// the batch wrote is a FOREIGN read for this one; eliding it leaves
    /// the record unreplayable (rove#532).
    ws_base: usize = 0,
    /// The deployment this activation runs under — what resolves the
    /// `_config/` namespace, so code and its config switch at the same
    /// instant (`reserved.configStorageKey`). Zero means "no deployment",
    /// which is an authored world in the offline engines, never a served
    /// request: a served activation always resolved a snapshot to get its
    /// bytecode.
    deployment_id: u64 = 0,
    /// What THIS activation has written so far — ops, and key+value bytes —
    /// against `reserved.KV_WRITES_MAX` / `KV_WRITE_BYTES_MAX`. Counted here
    /// rather than derived from the writeset because the writeset is
    /// batch-scoped (see `ws_base`): the budget is one activation's, and a
    /// neighbour in the same batch must not be able to spend it. Charged only
    /// after a write succeeds, so a refusal costs nothing.
    write_ops: u32 = 0,
    write_bytes: usize = 0,
    /// Accumulated `console.log` output. Owned by the dispatcher; reset
    /// between requests.
    console: *std.ArrayList(u8),
    /// Accumulated user-defined index tags from `request.tag(k,v)`.
    /// Owned by the dispatcher (a per-dispatch buffer, like `console`);
    /// `finishResponse` moves them onto the Response/Continuation so
    /// they reach the log record even across a `next()`. Each key/value
    /// is an owned dupe; capped at `log_mod.MAX_TAGS`.
    tags: *std.ArrayList(log_mod.Tag),
    /// The activation's shred identity from `request.shredKey(id)` — the
    /// opaque name every value this activation writes seals under, so a
    /// later destroy of that name takes all of them together.
    ///
    /// A cell rather than a value because the identity is usually LATE:
    /// it is unknown until a cookie is parsed or a token verified, and kv
    /// writes stage in the request transaction and commit when the
    /// handler returns — so what matters is the id in force at commit,
    /// not at the moment of any particular write.
    ///
    /// Null means this site does not track one, which is the same
    /// null-default stance `readset` takes: production worker sites
    /// always set it, and the default exists for unit tests that
    /// exercise binding behaviour without the surrounding buffers.
    shred_key: ?*?[]u8 = null,
    /// The slot `shred_key` resolved to — the key every value this
    /// activation writes seals under. Set alongside `shred_key`, so the
    /// two never disagree about which identity is in force.
    shred_slot: ?*?u64 = null,
    /// How to resolve an identity to a slot. Null on the offline
    /// engines and in unit tests; see `ShredCaps`.
    shred: ?ShredCaps = null,
    /// This activation's tenant, for the resolve above. Empty where the
    /// site does not track one.
    shred_instance_id: []const u8 = "",
    /// Set if a kv-level error needs to bubble back to the caller after
    /// the JS runs. We can't throw from inside the C callback cleanly in
    /// all cases, so we record the first error and let the dispatcher
    /// surface it.
    pending_kv_error: ?anyerror = null,
    /// Optional captured readset. When non-null, every binding that
    /// reads non-deterministic input (`kv.get/set/delete/prefix`,
    /// `Date.now`, `Math.random`, `crypto.getRandomValues`, the QJS
    /// module loader) appends to the matching channel so a later
    /// replay can re-drive the same handler without touching live
    /// state. Production worker sites always set it
    /// (search `.readset = &tapes`); the null default is for unit
    /// tests that exercise binding behaviour without a readset buffer.
    /// See readset replication
    /// (`docs/architecture/effects-and-handlers.md`) for the
    /// cross-activation persistence story; tape channels are defined in
    /// `src/tape/root.zig:Readset`.
    readset: ?*tape_mod.Readset = null,
    /// The activation's wire headers, borrowed for the lifetime of
    /// the JS run (the h2 entity row outlives dispatch, including
    /// park/resume and chunk re-fires). The lazy `request.headers`
    /// getters and the `request.ip` / `request.unmaskedIp()` IP
    /// derivation read from here on access — recording each read
    /// into `readset.request_reads` (read-taping; see
    /// `tape.Channel.request_reads`).
    req_headers: ?h2.ReqHeaders = null,
    /// The activation's body bytes, borrowed like `req_headers`.
    /// Materialized into JS only when the handler reads
    /// `request.body`; the read flips `readset.body_read`, which is
    /// what keeps the body's tape/log reference alive
    /// (`Readset.elideUnreadBody`).
    req_body: []const u8 = "",
    // Within-activation non-determinism replay
    // (`docs/architecture/replay-and-sim.md`): arenajs's per-request
    // `xorshift64star` state (in `js_random_state_active(ctx)`) is the
    // single PRNG. The dispatcher seeds it once via `JS_SetRandomSeed`
    // in `installRequest`; Math.random + crypto.* draw from it.
    /// Per-request identifier, pre-minted by the worker. Combined with
    /// `http_fetch_index` to derive a deterministic fetch id for
    /// each `http.fetch` call.
    request_id: u64 = 0,
    /// 0-based counter of `http.fetch` calls within this handler
    /// invocation. Reset per request; combined with `request_id`
    /// + a `"FTCH"` tag to derive the platform-default `fetch_id`
    /// deterministically for replay.
    http_fetch_index: u32 = 0,
    /// Gap 2.3: per-handler accumulator for `http.fetch`
    /// calls. Caller-owned (pointer to a list the worker_dispatch
    /// allocates per handler invocation); each binding call
    /// appends a `PendingFetch`; at end-of-handler the worker
    /// flushes the list to `NodeState.fetch_pending`. List
    /// ownership stays with the caller; the caller's defer
    /// frees any leftovers on error paths (no orphan fetches).
    /// Null on test paths that don't care.
    pending_fetches: ?*std.ArrayListUnmanaged(PendingFetch) = null,
    /// Caller-owned accumulator for `on.timer`
    /// / `on.kv` registrations during this activation (same ownership
    /// model as `pending_fetches`). The `_system.on.*` bindings append;
    /// the worker arms them onto the held entity's `StreamWakes` at
    /// park time and frees the list. Null on connectionless / test
    /// paths — `on.*` is then inert (the model: connection-only wakes).
    pending_wakes: ?*std.ArrayListUnmanaged(PendingWakeReg) = null,
    /// `stream.*` effects (`docs/handler-shape.md`
    /// §2.2): true once the handler called `stream.start()` or the first
    /// `stream.write()` — the activation opens/continues a streamed
    /// response. Read by the worker post-dispatch to drive the stream-
    /// pipeline entry. Connection-only — `stream.*` is inert (and this
    /// stays false) when `pending_stream_chunks` is null.
    stream_started: bool = false,
    /// `docs/architecture/websockets.md` (piece D): true when this activation's
    /// `stream.write` output is WS frames, not a streamed HTTP response.
    /// Set by the dispatcher for `.ws_message` activations. Bypasses the
    /// stream bridge (`stream_started` → `Stream` descriptor /
    /// terminal chunk-prepend) so the chunks stay in
    /// `pending_stream_chunks` for `shipWsFrames` to lower to
    /// `ws_send_in`, and `next()` stays a plain continuation (the WS
    /// chain parks on frame arrival, not the stream pipeline).
    ws_frame_output: bool = false,
    /// Caller-owned accumulator for chunks
    /// emitted via `stream.write(chunk)` this activation (same ownership
    /// model as `pending_fetches`/`pending_wakes`). Each is an owned byte
    /// slice; the worker stages them as commit-gated `Cmd.stream_chunk`
    /// at park, then frees the list. Null on connectionless / test paths
    /// ⇒ `stream.*` is inert (the model: connection-only output).
    pending_stream_chunks: ?*std.ArrayListUnmanaged([]u8) = null,
    /// Raised by any binding that fires an IMMEDIATE worker-side
    /// effect during dispatch (blob_write/blob_seal streaming,
    /// cancel_fetch, fire_wake, resume_if_bound) — effects that are
    /// NOT commit-gated and would double on a re-execution. The
    /// arena-OOM bump→GC retry (dispatcher.runOutcome) refuses to
    /// rerun an attempt that raised this.
    side_effects_flag: ?*bool = null,
    /// The saga that ARMED this activation across the durability
    /// boundary (`Trace.parent_saga`, a durable wake's provenance —
    /// handler-shape.md §3.2). Consumed by `finishResponse`, which
    /// stamps it as the reserved `_parent` record tag AFTER the handler
    /// ran — so it never occupies the handler's `request.tag` quota and
    /// never reaches the JS surface. Null everywhere but the durable-
    /// wake fire path.
    parent_saga: ?[]const u8 = null,
    /// `docs/architecture/websockets.md`: per-chunk RFC 6455 data opcode, pushed in
    /// lockstep with `pending_stream_chunks` (1 = text, the arg was a
    /// string; 2 = binary, an ArrayBuffer/TypedArray). Non-null only on
    /// a WebSocket connection activation (the worker's `fireWsMessage`
    /// wires it); null on SSE / HTTP stream chains, where the opcode is
    /// irrelevant and chunks are plain bytes. Same caller-owned model
    /// as `pending_stream_chunks` — the worker frees both lists.
    pending_stream_chunk_opcodes: ?*std.ArrayListUnmanaged(u8) = null,
    /// Running sum of `stream.write` bytes THIS activation. Lossless
    /// stream.write throws (not drops) when a single activation's writes
    /// exceed `StreamChunks.QUEUE_HARD_CAP` — bounding per-activation memory
    /// and telling the customer loudly to paginate with `next()`. Reset per
    /// dispatch (the field is fresh on each DispatchState).
    stream_pending_bytes: usize = 0,
    /// True ⇒ the dispatched module is a `__system/`
    /// built-in (e.g. the webhook shim's `webhook_onresult.mjs`).
    /// `isCustomerWriteReserved` is skipped so the shim can write
    /// `_send/owed/{id}` markers; customer modules see false and
    /// the reserved-prefix check applies. Set by
    /// `Dispatcher.runOutcome` from `Request.is_system_module`.
    is_system_module: bool = false,
    /// Resolved session id (see `Request.session_id`). 64 lowercase hex
    /// chars when set; null in non-browser dispatch paths. Surfaced as
    /// `request.session = {id: ...}` (or `request.session = null`).
    session_id: ?[64]u8 = null,
    /// Singleton admin-capability pointer. Non-null only when the
    /// handler-tenant is `__admin__`; the dispatcher installs the
    /// `platform.*` JS globals (instance / domain / root kv access)
    /// iff this field is set. Regular tenants' handlers see
    /// `platform === undefined` in their runtime.
    platform: ?*tenant_mod.Tenant = null,
    /// Raft writeset accumulating root-store writes the admin
    /// handler makes via `platform.root.set` / `platform.root.delete`.
    /// Dispatcher creates this alongside the per-tenant writeset
    /// when `platform != null`; worker proposes it through raft as
    /// a type=2 envelope after commit so followers' copies of
    /// `__root__.db` stay in sync.
    root_writeset: ?*kv_mod.WriteSet = null,
    /// `root_writeset.ops` length when this activation began — the root
    /// twin of `ws_base` (the root writeset is batch-scoped the same way).
    root_ws_base: usize = 0,
    /// Trigger registry for the active deployment (PLAN §2.5).
    /// Sorted longest-prefix-first → forward iteration visits
    /// innermost (most-specific) triggers first; AFTER chain uses
    /// forward order, BEFORE chain reverses. Null = no triggers
    /// (test paths that don't care).
    triggers: ?[]const TriggerEntry = null,
    /// Subscription registry for the active deployment
    /// (durable-kv-subscriptions): a customer write under a watched
    /// prefix injects the durable `_sub/dirty/{name}` marker into this
    /// activation's txn+writeset, atomic with the write. Borrowed from
    /// the pinned snapshot. Empty = none (test paths).
    subscriptions: []const SubscriptionEntry = &.{},
    /// Dedup bitmask: bit i set ⇒ subscription i's dirty marker was
    /// already written by THIS activation (one marker per sub per
    /// activation regardless of how many matching writes — the
    /// writeset-level half of the coalescing). Subs past 64 skip the
    /// dedup and just rewrite (rare; same key, idempotent).
    subs_marked: u64 = 0,
    /// Per-deployment bytecode map. Same map the module loader
    /// uses for handler imports — trigger modules live in it under
    /// their `_triggers/.../index.{mjs,js}` paths. Needed by the
    /// trigger fire path to load module bytecode lazily on first
    /// fire and look up named exports.
    bytecodes: ?*const std.StringHashMapUnmanaged(*bytecode_cache_mod.BlobBytes) = null,
    /// Cascade depth: how many trigger frames are currently on the
    /// JS call stack. 0 = user-initiated write. Incremented before
    /// a trigger fires, decremented after. Throws if a fire would
    /// take it past `MAX_TRIGGER_DEPTH` (PLAN §2.5 limits).
    trigger_depth: u32 = 0,
    /// Per-request cache of trigger-module namespaces. Module
    /// top-level state (e.g. `let count = 0`) persists across fires
    /// within one handler invocation but resets between requests
    /// (the snapshot/restore wipes the runtime). Owned values must
    /// be `JS_FreeValue`'d on `deinit`.
    trigger_module_ns: std.StringHashMapUnmanaged(c.JSValue) = .empty,
    /// Per-worker rate limiter. Used at the inbound request boundary
    /// (`worker_dispatch.zig`, the `.request` action) and at the frozen
    /// outbound fetch primitive (`bindings/http.zig` `outboundRateOk`, the
    /// `.outbound` action — every customer-initiated egress). Null in test
    /// paths that don't care.
    limiter: ?*limiter_mod.RateLimiter = null,
    /// Instance id for limiter lookup. Empty when the dispatcher
    /// runs without a worker (test paths). Derived from
    /// `PlanLimits.storage` at the single dispatcher hand-off.
    instance_id: []const u8 = "",
    /// The instance's storage handle (`PlanLimits.storage`), carried so
    /// `blob.url` signs the same key the write path used. Null on paths
    /// with no storage context — presign then throws rather than signing
    /// a legacy-shaped key for a tenant that isn't on that layout (#357).
    storage: ?tenant_mod.TenantStorage = null,
    /// The node's S3 backend config (`docs/architecture/routing-and-ingress.md`),
    /// borrowed from `NodeState.blob_backend_cfg` for the
    /// `_system.blob.presign` binding (the one blob verb that needs
    /// the signing keys natively). Null on test paths without a
    /// node — presign then throws "not configured".
    blob_cfg: ?*const blob_mod.BackendConfig = null,
    /// Blob upload-session (`docs/architecture/routing-and-ingress.md`)
    /// trampolines (worker `blobWriteTrampoline` /
    /// `blobSealTrampoline`). Null where there is no worker —
    /// `blob.write` / `blob.seal` then throw.
    blob_write: ?*const fn (
        ctx: *anyopaque,
        tenant_id: []const u8,
        corr: []const u8,
        bytes: []const u8,
    ) blob_sessions_mod.Error!u64 = null,
    blob_seal: ?*const fn (
        ctx: *anyopaque,
        tenant_id: []const u8,
        corr: []const u8,
    ) blob_sessions_mod.Error!blob_sessions_mod.Sealed = null,
    blob_session_ctx: ?*anyopaque = null,
    /// Plan-resolved rate caps + plan generation for `instance_id` (from its
    /// `TenantSlot`). The `email.send` rate check sizes its bucket from these
    /// (docs/architecture/control-plane.md Lever 1). Defaults = free/default caps on paths
    /// with no resolved plan (tests, async activations).
    plan_rate: limiter_mod.RateLimitCaps = .{},
    plan_gen: u64 = 0,
    /// Gap 2.3: saga_id of the chain this handler
    /// run belongs to. `http.fetch({pipe_to})` stamps it onto the
    /// `PendingFetch` so the upstream bytes can later be routed to
    /// the held stream entity carrying the matching
    /// `ChainContext.saga_id`. Empty on test paths / when
    /// the dispatch carries no saga_id.
    saga_id: []const u8 = "",
    /// Admin-tenant platform-capability trampolines (deployStarter /
    /// releases.publish / scope().kv writes). Non-null only on admin-
    /// handler requests (gated by `platform != null` in
    /// `worker_dispatch`); customer requests have none and the JS
    /// callables reject at the gate. See `PlatformCaps`.
    platform_caps: ?PlatformCaps = null,

    /// Trampoline backing
    /// `_system.continuation.resumeIfBound(send_id, event_json)`.
    /// Worker provides a concrete fn that casts `ctx` back to its
    /// `*Worker(opts)` type and calls `worker.resumeBoundContinuation`
    /// on `(tenant_id = state.instance_id, send_id, event_json)`.
    /// Returns true when a parked continuation matched and was
    /// dispatched. Null on test paths / non-worker dispatches; the
    /// JS callable returns false in that case (no held-sync to
    /// resume).
    resume_if_bound: ?*const fn (
        ctx: *anyopaque,
        tenant_id: []const u8,
        send_id: []const u8,
        event_json: []const u8,
    ) bool = null,
    resume_if_bound_ctx: ?*anyopaque = null,

    /// Outbound fetch / libcurl multi
    /// (`docs/architecture/configuration-and-network.md`): cancel-fetch
    /// trampoline.
    /// The binding (`bindings/http.zig:jsHttpCancelFetch`) calls
    /// this to ask `FetchEngine.cancel` to drop an in-flight
    /// transfer by id. Null on test paths / non-worker dispatches;
    /// the JS callable becomes a no-op in that case.
    cancel_fetch: ?*const fn (
        ctx: *anyopaque,
        id: []const u8,
    ) void = null,
    cancel_fetch_ctx: ?*anyopaque = null,

    /// §2.6 durable-wake: trampoline backing `__rove_set_wake(when_ns)`.
    /// Sets THIS tenant's single next-fire watermark on its slot
    /// (`TenantSlot.next_wake_ns`). The worker provides a fn that casts
    /// `ctx` back to `*Worker(opts)` and stores the value on the slot
    /// for `tenant_id` (= `state.instance_id`). Capability-scoped: the
    /// `__rove_set_wake` builtin throws unless `is_system_module`, so
    /// only the baked `__system/scheduler_tick` reaches this. Null on
    /// test paths / non-worker dispatches — the builtin then no-ops.
    set_wake: ?*const fn (
        ctx: *anyopaque,
        tenant_id: []const u8,
        when_ns: i64,
    ) void = null,
    set_wake_ctx: ?*anyopaque = null,

    /// §2.6 durable-wake: trampoline backing
    /// `__rove_fire_wake(target, id, key, scheduledAtNs, msg, cleanupKeys, armedBy?)`.
    /// Enqueues one `durable_wake` activation for THIS tenant (routed
    /// to its owning worker via `enqueueDurableWakeForTenant`). The
    /// dispatch path injects `cleanup_keys` as deletes into the target
    /// handler's writeset. Same capability-scoping + null semantics as
    /// `set_wake`. Returns false when no worker is registered (the
    /// builtin surfaces that as a thrown error so a fire is never
    /// silently dropped).
    fire_wake: ?*const fn (
        ctx: *anyopaque,
        input: FireWakeInput,
    ) bool = null,
    fire_wake_ctx: ?*anyopaque = null,

    /// The entity owning the chain this dispatch runs against —
    /// what the binding registers under `fetch_id` when `bind:
    /// true`. Null when the activation has no held socket
    /// (subscription / cron / test paths); the binding
    /// rejects bind:true in that case.
    activation_entity: ?rove.Entity = null,
    /// Per-chain bound-fetch pending count snapshot — surfaced
    /// to JS as `request.fetchesPending` on onFetchChunk
    /// activations.
    activation_fetches_pending: u32 = 0,

    /// `blob.receive` (`docs/architecture/routing-and-ingress.md`) is only
    /// meaningful when the body is still at the door — set iff this
    /// dispatch is an `.inbound_headers` activation.
    allow_blob_receive: bool = false,
    /// A receive consumes THE inbound body; at most one per
    /// activation.
    blob_receive_used: bool = false,

    pub fn deinit(self: *DispatchState, ctx: ?*c.JSContext) void {
        var it = self.trigger_module_ns.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            c.JS_FreeValue(ctx, e.value_ptr.*);
        }
        self.trigger_module_ns.deinit(self.allocator);
        // Gap 2.3: `pending_fetches` is caller-owned (a
        // pointer); cleanup of accumulated entries lives at the
        // caller's defer. DispatchState only borrows.
        self.* = undefined;
    }
};

/// PLAN §2.5 cascade depth ceiling.
pub const MAX_TRIGGER_DEPTH: u32 = 8;

// ── C helpers ──────────────────────────────────────────────────────────

pub fn getState(ctx: ?*c.JSContext) *DispatchState {
    const opaque_ptr = c.JS_GetContextOpaque(ctx);
    return @ptrCast(@alignCast(opaque_ptr.?));
}

/// Convert a JS value to a Zig-owned string via the state allocator.
/// Caller frees.
pub fn valueToOwnedString(
    state: *DispatchState,
    ctx: ?*c.JSContext,
    val: c.JSValue,
) ![]u8 {
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, val);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    const out = try state.allocator.alloc(u8, len);
    if (len > 0) @memcpy(out, @as([*]const u8, @ptrCast(cstr))[0..len]);
    return out;
}

/// `valueToOwnedString` for kv WRITE inputs: primitives only. A string,
/// number, boolean, or bigint has one faithful, deterministic string
/// form; an object/array/typed array would silently mangle
/// (`"[object Object]"`, a Uint8Array's `"1,2,3"`) and null/undefined
/// at a write site is a handler bug — all throw TypeError instead of
/// corrupting the durable store
/// (docs/decisions.md §4.11). JSON encoding stays
/// the handler's explicit choice (`kv.set(k, JSON.stringify(v))`).
pub fn kvWriteArgToOwnedString(
    state: *DispatchState,
    ctx: ?*c.JSContext,
    val: c.JSValue,
    comptime what: []const u8,
) ![]u8 {
    if (c.JS_IsUndefined(val) or c.JS_IsNull(val) or c.JS_IsObject(val)) {
        _ = c.JS_ThrowTypeError(ctx, "kv: " ++ what ++
            " must be a string (or number/boolean/bigint); " ++
            "JSON.stringify objects explicitly");
        return error.JsException;
    }
    return valueToOwnedString(state, ctx, val);
}

// ── kv.* ──────────────────────────────────────────────────────────────

/// Throw `Error{message, code}` for a `rove-guards` verdict. Every kv rule's
/// wording belongs to the guards module, so this raises the text it carries
/// rather than composing its own — the reserved-key message is the one that
/// names its key, and its caller formats it from `kvReservedMessageFmt`.
pub fn throwKvError(ctx: ?*c.JSContext, message: []const u8, code: []const u8) c.JSValue {
    const err = c.JS_NewError(ctx);
    if (c.JS_IsException(err)) return err;
    _ = c.JS_SetPropertyStr(ctx, err, "message", c.JS_NewStringLen(ctx, message.ptr, message.len));
    _ = c.JS_SetPropertyStr(ctx, err, "code", c.JS_NewStringLen(ctx, code.ptr, code.len));
    return c.JS_Throw(ctx, err);
}



// ── Date.now / Math.random / crypto.* ─────────────────────────────────
//
// Within-activation non-determinism replay
// (`docs/architecture/replay-and-sim.md`): per-request non-determinism
// is collapsed to two scalars in the readset header — `seed`
// (xorshift64star PRNG) and `timestamp_ns` (Date.now / new Date()).
// Neither has a per-call tape channel. arenajs's native
// implementations service them via per-context state set by the
// dispatcher in `installRequest`:
//   - `Math.random` / crypto.* → `JS_SetRandomSeed(ctx, seed)`,
//     reading from `js_random_state_active(ctx)`. crypto.* draws
//     through `JS_FillRandomBytes`.
//   - `Date.now()` / `new Date()` (no args) → `JS_SetDateNow(ctx,
//     start_time_ms)`, reading from `ctx->date_now_pinned`. Every
//     clock read in one request returns the same value — same
//     posture as Cloudflare Workers / Lambda SnapStart.
//
// Replay reproduces by reseeding both per-context fields with the
// captured values (`arena_set_random_seed` + `arena_set_date_now`
// reactor exports for the WASM build, direct API calls for the
// server build).

// Within-activation non-determinism replay
// (`docs/architecture/replay-and-sim.md`): arenajs's native `js_math_random`
// runs against the per-request
// xorshift64star state (seeded once per request via
// `JS_SetRandomSeed` in `installRequest`). crypto.* draws from the
// same state via `JS_FillRandomBytes`. Replay reproduces by
// calling `arena_set_random_seed` with the recorded request seed
// from the readset header — no per-draw tape entries, no JS port.

// ── console.log ───────────────────────────────────────────────────────

fn jsConsoleLog(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = getState(ctx);
    const n: usize = if (argc < 0) 0 else @intCast(argc);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i > 0) state.console.append(state.allocator, ' ') catch return js_exception;
        const s = valueToOwnedString(state, ctx, argv[i]) catch return js_exception;
        defer state.allocator.free(s);
        state.console.appendSlice(state.allocator, s) catch return js_exception;
    }
    state.console.append(state.allocator, '\n') catch return js_exception;
    return js_undefined;
}

// ── Installation ──────────────────────────────────────────────────────

/// Install the pieces of the global surface that do NOT depend on a
/// per-request `DispatchState` or `Request`. Safe to call from a
/// snapshot init callback — pure, deterministic, no clocks, no
/// allocation outside the arena. The bulk of the cost of setting up a
/// JS handler context lives here (C-function bindings register atoms
/// and shape transitions), so doing it once at snapshot creation time
/// and then memcpy-restoring for each request is the whole point of
/// rove-qjs.
///
/// Installs: `kv`, `console`, `crypto`, `Date.now`, `Math.random`,
/// `webhook`, `email`. Installs `platform` on every context too —
/// the per-request `installRequest` gates it on `state.platform` so
/// callbacks reject non-admin handlers at call time.
/// Does NOT install `request`, `response`, or the context opaque —
/// see `installRequest`.
pub fn installStatic(ctx: *c.JSContext) void {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);

    // Build the fresh-namespace tree (kv, console, crypto, webhook,
    // platform/...). For nested paths the parent must already exist
    // as a JSObject, so STATIC_NAMESPACES is ordered parent-before-
    // child — the empty `platform` entry creates the holder before
    // platform.root and platform.instances populate it.
    for (STATIC_NAMESPACES) |ns| installNamespace(ctx, global, ns);

    // Extend existing intrinsics. Skipped if the intrinsic isn't
    // installed in this runtime (Dispatcher.snapshotInitFn keeps
    // the intrinsic-add minimal). Tape capture is gated on a non-
    // null DispatchState tape, so the API is stable whether we're
    // capturing or not.
    for (INTRINSIC_EXTENSIONS) |ns| extendIntrinsic(ctx, global, ns);

    // Globals attached directly to globalThis with no namespace.
    for (GLOBAL_BUILTINS) |fb| attachFn(ctx, global, fb);

    // JS-side wrappers/polyfills evaluated last so they can call
    // into the native bindings installed above. Order matters
    // because some snippets depend on globals other snippets
    // install:
    //   - textcodec.js: TextEncoder/TextDecoder. Used by base64.js
    //     + urlsearchparams.js for UTF-8 byte handling.
    //   - base64.js: atob/btoa, globalThis.base64url, globalThis.hex.
    //   - urlsearchparams.js: URLSearchParams class.
    //   - retry.js: customer-side retry helper on http.send.
    //   - webhook.js: webhook.send shim on http.send.
    //   - email.js: Resend wrapper that calls webhook.send (the shim).
    //   - kv/console/crypto/http/events/platform .js: public shims
    //     over `_system.*` (docs/architecture/builtin-libs.md Phase A).
    //     Evaluated FIRST so the dependent snippets below (jwt/oauth/
    //     oidc/sessions use `crypto`; retry/webhook/email use `http`)
    //     and customer handlers see the documented top-level names
    //     rather than the raw natives.
    evalSnippet(ctx, "kv.js", KV_JS);
    evalSnippet(ctx, "console.js", CONSOLE_JS);
    evalSnippet(ctx, "crypto.js", CRYPTO_JS);
    evalSnippet(ctx, "http.js", HTTP_JS);
    evalSnippet(ctx, "platform.js", PLATFORM_JS);
    evalSnippet(ctx, "textcodec.js", TEXTCODEC_JS);
    // request.js needs TextDecoder (above): builds the shared
    // `__rove_request_proto` whose `text`/`json` accessors derive from
    // `request.bytes` (decisions.md §4.11).
    evalSnippet(ctx, "request.js", REQUEST_JS);
    evalSnippet(ctx, "base64.js", BASE64_JS);
    evalSnippet(ctx, "urlsearchparams.js", URLSEARCHPARAMS_JS);
    evalSnippet(ctx, "time.js", TIME_JS);
    // The durable one-shot scheduler CORE — installs the private
    // `_system.sched` (not a customer global; that's the @rewind/schedule
    // package). webhook.js captures it below, before the `_harden.js`
    // `_system` delete. After base64/crypto/kv + time (its deps).
    evalSnippet(ctx, "schedule.js", SCHEDULE_JS);
    // The after.* connection wake triggers (canonical) + the on.* alias.
    evalSnippet(ctx, "after.js", AFTER_JS);
    // Connection output effects (`stream.*`).
    evalSnippet(ctx, "stream.js", STREAM_JS);
    // The public `next` disposition verb.
    evalSnippet(ctx, "next.js", NEXT_JS);
    evalSnippet(ctx, "webhook.js", WEBHOOK_JS);
    // blob depends on crypto.sha256 + http (both above) +
    // _system.blob.presign (`docs/architecture/routing-and-ingress.md`, customer blob storage).
    evalSnippet(ctx, "blob.js", BLOB_JS);

    // Reachability hardening (docs/architecture/builtin-libs.md).
    // Every native shim above captured its slice as
    // `const sys = _system.X` at eval time, so the `_system.*` objects
    // stay alive through those closures — the global holder is dead
    // weight now. Delete it so customer handler code (loaded per
    // request into the restored snapshot) cannot name the internal
    // ABI even by accident. Baked into the base snapshot: zero
    // per-request cost. NOT a privilege boundary (the natives
    // self-gate, e.g. platform.* checks state.platform) — this is API
    // hygiene: keep `_system.*` free to change. Pairs with
    // scripts/ops/globals_lint.py (catches refs in-tree; this makes the
    // global physically absent at runtime).
    evalSnippet(ctx, "_harden.js", "delete globalThis._system;");
}

const NativeFn = *const fn (
    ctx: ?*c.JSContext,
    this: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue;

const FnBinding = struct {
    name: [:0]const u8,
    cfunc: NativeFn,
    argc: c_int,
};

const NamespaceBindings = struct {
    /// Path under globalThis. Non-empty. Multi-element paths require
    /// their parent path to appear earlier in STATIC_NAMESPACES.
    path: []const [:0]const u8,
    fns: []const FnBinding,
};

const STATIC_NAMESPACES = [_]NamespaceBindings{
    // `_system` is the internal native ABI (docs/architecture/builtin-libs.md
    // Phase A). Unstable, undocumented, never referenced by customer
    // code — every public name is a doc-commented JS shim in
    // `globals/*.js` layered over `_system.*`. Empty holder so the
    // parent JSObject exists before `_system.kv` populates it (same
    // parent-before-child rule as `platform`).
    .{ .path = &.{"_system"}, .fns = &.{} },
    .{ .path = &.{ "_system", "kv" }, .fns = &.{
        .{ .name = "get", .cfunc = kv_bindings.jsKvGet, .argc = 1 },
        .{ .name = "set", .cfunc = kv_bindings.jsKvSet, .argc = 2 },
        .{ .name = "delete", .cfunc = kv_bindings.jsKvDelete, .argc = 1 },
        .{ .name = "prefix", .cfunc = kv_bindings.jsKvPrefix, .argc = 3 },
    } },
    .{ .path = &.{ "_system", "console" }, .fns = &.{
        .{ .name = "log", .cfunc = jsConsoleLog, .argc = 1 },
    } },
    // The after.* connection wake triggers. `after.ms` / `after.kv`
    // accumulate onto `DispatchState.pending_wakes`; the worker arms
    // them on the held entity at park. Inert when there's no held
    // connection (the accumulator is null).
    .{
        .path = &.{ "_system", "after" },
        .fns = &.{
            .{ .name = "timer", .cfunc = on_b.jsOnTimer, .argc = 2 },
            .{ .name = "kv", .cfunc = on_b.jsOnKv, .argc = 2 },
            // Connection-scoped outbound. Binds the
            // fetch to the held chain (chunks → `{on}`/`onFetchChunk`) when
            // held; inert when not. Lives in the http binding (composes the
            // same fetch primitive as `http.fetch`).
            .{ .name = "fetch", .cfunc = http_b.jsOnFetch, .argc = 2 },
        },
    },
    // Connection output effects. `stream.start`
    // / `stream.write` accumulate onto `DispatchState`; the worker
    // drives the stream-pipeline entry + stages chunks as commit-gated
    // `Cmd.stream_chunk` at park. Inert when there's no held connection.
    .{ .path = &.{ "_system", "stream" }, .fns = &.{
        .{ .name = "start", .cfunc = stream_b.jsStreamStart, .argc = 0 },
        .{ .name = "write", .cfunc = stream_b.jsStreamWrite, .argc = 1 },
    } },
    // Native UTF-8 transcode for TextEncoder/TextDecoder. The shim
    // classes (globals/textcodec.js) keep the WHATWG shape; byte
    // work is native so multi-MB payloads don't drown the bump
    // arena in per-char string garbage.
    .{ .path = &.{ "_system", "textcodec" }, .fns = &.{
        .{ .name = "encode", .cfunc = textcodec_b.jsTextEncode, .argc = 1 },
        .{ .name = "decode", .cfunc = textcodec_b.jsTextDecode, .argc = 2 },
    } },
    // crypto. No crypto global in qjs-ng by default, so we fabricate
    // one. hmacSha256 is the vendor-neutral primitive for building
    // Stripe / Slack / AWS style signatures (PLAN §2.6); randomBytes +
    // sha256 are what admin's JS handler composes into magic-link /
    // session token mint and hash-at-rest.
    .{
        .path = &.{ "_system", "crypto" },
        .fns = &.{
            .{ .name = "getRandomValues", .cfunc = crypto_b.jsCryptoGetRandomValues, .argc = 1 },
            .{ .name = "randomUUID", .cfunc = crypto_b.jsCryptoRandomUuid, .argc = 0 },
            .{ .name = "randomBytes", .cfunc = crypto_b.jsCryptoRandomBytes, .argc = 1 },
            .{ .name = "sha256", .cfunc = crypto_b.jsCryptoSha256, .argc = 1 },
            // Streaming sha256 over serializable midstate tokens — pure
            // functions, so an accumulation spanning activations can keep
            // its hash state in kv (`docs/architecture/blob-write-recipes.md` §3).
            .{ .name = "sha256Init", .cfunc = crypto_b.jsCryptoSha256Init, .argc = 0 },
            .{ .name = "sha256Update", .cfunc = crypto_b.jsCryptoSha256Update, .argc = 2 },
            .{ .name = "sha256Final", .cfunc = crypto_b.jsCryptoSha256Final, .argc = 1 },
            .{ .name = "hmacSha256", .cfunc = crypto_b.jsCryptoHmacSha256, .argc = 2 },
            // RSA-PKCS#1 v1.5 verify (RS256 / RS384 / RS512). Customer
            // composes JWT/OIDC verification on top — see retry.js +
            // base64url.* helpers.
            .{ .name = "verifyRsa", .cfunc = crypto_jose_b.jsCryptoVerifyRsa, .argc = 4 },
            // ECDSA verify (ES256 / ES384 / ES512). Required for Sign in
            // with Apple, AWS Cognito on EC keys, etc. Sig is JWS raw
            // R||S concatenation (the binding converts to DER internally).
            .{ .name = "verifyEcdsa", .cfunc = crypto_jose_b.jsCryptoVerifyEcdsa, .argc = 4 },
            // OIDC RS256 key custody
            // (`docs/architecture/auth-and-domains.md`): keygen + sign are
            // Zig/OpenSSL; the IdP JS holds
            // the private key only as an opaque PEM string it never
            // parses.
            .{ .name = "oidcGenerateKey", .cfunc = crypto_jose_b.jsCryptoOidcGenerateKey, .argc = 0 },
            .{ .name = "oidcSign", .cfunc = crypto_jose_b.jsCryptoOidcSign, .argc = 2 },
            // Raw-key ECDSA over secp256k1 / P-256: keygen + sign + verify
            // with SHA-256, 64-byte compact R||S, low-S enforced. The
            // primitive atproto.js builds did:key/did:plc + signed repo
            // commits on (separate from the JOSE verifyEcdsa path above).
            .{ .name = "ecdsaGenerateKey", .cfunc = crypto_ecdsa_b.jsCryptoEcdsaGenerateKey, .argc = 1 },
            .{ .name = "ecdsaSign", .cfunc = crypto_ecdsa_b.jsCryptoEcdsaSign, .argc = 3 },
            .{ .name = "ecdsaVerify", .cfunc = crypto_ecdsa_b.jsCryptoEcdsaVerify, .argc = 4 },
        },
    },
    // http.fetch / http.cancelFetch — the platform's outbound HTTP
    // primitive. Transient + best-effort; durability is composed in
    // JS by `webhook.send` (the reified primitives,
    // `docs/architecture/effects-and-handlers.md`).
    .{
        .path = &.{ "_system", "http" },
        .fns = &.{
            .{ .name = "fetch", .cfunc = http_b.jsHttpFetch, .argc = 1 },
            .{ .name = "cancelFetch", .cfunc = http_b.jsHttpCancelFetch, .argc = 1 },
            // Held outbound subscription (gap 2.5) on the outbound fetch /
            // libcurl-multi engine
            // (`docs/architecture/configuration-and-network.md`). Same engine, different
            // lifecycle: no timeout, per-tenant cap, terminal is
            // always `ok=false` ("subscription ended").
            .{ .name = "subscribe", .cfunc = http_b.jsHttpSubscribe, .argc = 1 },
            .{ .name = "cancelSubscription", .cfunc = http_b.jsHttpCancelSubscription, .argc = 1 },
        },
    },
    // Tenant blob storage (`docs/architecture/routing-and-ingress.md`). Only
    // `presign` is native (needs the platform-held signing keys);
    // `blob.put` / `blob.get` are JS compositions in globals/blob.js
    // over the fetch engine's `rove-blob.internal` trusted door.
    .{
        .path = &.{ "_system", "blob" },
        .fns = &.{
            .{ .name = "presign", .cfunc = blob_b.jsBlobPresign, .argc = 5 },
            // Upload sessions (`docs/architecture/routing-and-ingress.md`, customer blob storage).
            .{ .name = "write", .cfunc = blob_b.jsBlobWrite, .argc = 1 },
            .{ .name = "seal", .cfunc = blob_b.jsBlobSeal, .argc = 2 },
            // `blob.receive` (`docs/architecture/routing-and-ingress.md`, blob ingress):
            // headers-first inbound pipe — only callable from an
            // `onHeaders` activation.
            .{ .name = "receive", .cfunc = blob_b.jsBlobReceive, .argc = 1 },
        },
    },
    // `resumeIfBound` can't live under `_system.*` — the
    // `_harden.js` `delete globalThis._system` runs BEFORE baked modules
    // eval, so `__system/webhook_onresult.mjs` can't reach a
    // `_system.*` reference. It lives (persistent, gated) as
    // `__rove.resumeIfBound` in the `__rove.*` holder further below.
    // platform = { root, instances }. Installed on every context;
    // the C callbacks check `state.platform` and throw for non-admin
    // handlers.
    .{
        .path = &.{ "_system", "platform" },
        .fns = &.{
            // platform.scope(id) → { kv: { get, prefix, set, delete } }
            // bound to instance `id`. The explicit cross-tenant accessor.
            .{ .name = "scope", .cfunc = platform_bindings.jsPlatformScope, .argc = 1 },
        },
    },
    .{ .path = &.{ "_system", "platform", "root" }, .fns = &.{
        .{ .name = "get", .cfunc = platform_bindings.jsPlatformRootGet, .argc = 1 },
        .{ .name = "set", .cfunc = platform_bindings.jsPlatformRootSet, .argc = 2 },
        .{ .name = "delete", .cfunc = platform_bindings.jsPlatformRootDelete, .argc = 1 },
        .{ .name = "prefix", .cfunc = platform_bindings.jsPlatformRootPrefix, .argc = 3 },
    } },
    .{ .path = &.{ "_system", "platform", "instances" }, .fns = &.{
        .{ .name = "create", .cfunc = platform_bindings.jsPlatformInstancesCreate, .argc = 1 },
        .{ .name = "deployStarter", .cfunc = platform_bindings.jsPlatformInstancesDeployStarter, .argc = 1 },
        .{ .name = "usage", .cfunc = platform_bindings.jsPlatformInstancesUsage, .argc = 1 },
    } },
    .{ .path = &.{ "_system", "platform", "releases" }, .fns = &.{
        .{ .name = "publish", .cfunc = platform_bindings.jsPlatformReleasesPublish, .argc = 2 },
    } },
    // No `_system.platform.auth`: the operator-root verdict is engine-computed
    // and reaches the handler as `request.rewind.isRoot`, never as a native
    // taking the bearer. A platform credential must not be handler-readable,
    // because a handler-readable input is a recorded input
    // (`src/js/reserved_headers.zig` PLATFORM_CREDENTIAL_HEADERS).
    // The continuation primitive behind the public `next()` disposition.
    // A `_system.*` capability (deleted after base-eval): the `next.js`
    // shim captures it in a closure; baked `__system/` modules that need
    // cross-module dispatch call the public `next(target, ctx)` shim (they
    // have the ambient globals + the shim holds the captured ref), so
    // there is NO persistent bare `__rove_next`. Exempt from the
    // shim-name lint via `ns_exceptions` ("continuation" → next.js).
    .{ .path = &.{ "_system", "continuation" }, .fns = &.{
        .{ .name = "next", .cfunc = cont_b.jsNext, .argc = 2 },
    } },
    // ── `__rove.*` — the privileged-ops surface ────────────────────────
    // Persistent (NOT deleted by `_harden.js`) because badged
    // `__system/*.mjs` modules, dispatched from the snapshot AFTER the
    // delete, reach these as live globals — they can't see a shim's
    // captured closure. Every entry is `is_system_module`-gated: a
    // customer naming `__rove.X` gets a throw at call time. No
    // customer-facing shim touches this surface. See
    // `docs/architecture/privileged-surface.md`.
    .{
        .path = &.{"__rove"},
        .fns = &.{
            // §6.4 held-sync resume hook — `webhook_onresult` wakes a handler
            // parked on a synchronous `webhook.send`. Gated (see continuation.zig).
            .{ .name = "resumeIfBound", .cfunc = cont_b.jsContinuationResumeIfBound, .argc = 2 },
            // Raw privileged outbound fetch for baked delivery modules
            // (`__system/webhook_fire`); delegates to `_system.http.fetch`
            // internals so staging/commit-gating/limits are identical.
            .{ .name = "fetch", .cfunc = http_b.jsSystemFetch, .argc = 1 },
        },
    },
    // §2.6 durable-wake tick ops — only `__system/scheduler_tick` calls
    // them. `set` installs the tenant's single next-fire watermark;
    // `fire` enqueues one `durable_wake` activation per due entry. Both
    // gated (throw unless is_system_module).
    .{ .path = &.{ "__rove", "wake" }, .fns = &.{
        .{ .name = "set", .cfunc = scheduler_b.jsSetWake, .argc = 1 },
        .{ .name = "fire", .cfunc = scheduler_b.jsFireWake, .argc = 6 },
    } },
};

const INTRINSIC_EXTENSIONS = [_]NamespaceBindings{
    // Within-activation non-determinism replay
    // (`docs/architecture/replay-and-sim.md`): neither `Date.now` nor
    // `Math.random` is overridden here. arenajs's native
    // implementations run against per-context state (`date_now_pinned`
    // + `xorshift64star`), both reseeded once per request in
    // `installRequest` via `JS_SetDateNow` + `JS_SetRandomSeed`.
};

// No bare `__rove_*` globals remain. The per-tenant OUTBOUND plan-rate
// (formerly `__rove_check_email_rate`, an email-specific bare global) is
// now enforced at the frozen fetch primitive `bindings/http.zig`
// (`outboundRateOk`), covering every customer-initiated egress; every other
// privileged op reached by baked `__system/` modules lives under
// `_system.continuation.*` (the widened `next`) or the gated `__rove.*`
// holder (STATIC_NAMESPACES). See docs/architecture/privileged-surface.md
// (the outbound-boundary rule).
const GLOBAL_BUILTINS = [_]FnBinding{};

// Public shims (docs/architecture/builtin-libs.md Phase A). JSDoc-carrying
// JS over `_system.*`; this is the documentation source of truth.
const KV_JS = @embedFile("kv_js");
const CONSOLE_JS = @embedFile("console_js");
const CRYPTO_JS = @embedFile("crypto_js");
const HTTP_JS = @embedFile("http_js");
const PLATFORM_JS = @embedFile("platform_js");
const BASE64_JS = @embedFile("base64_js");
const URLSEARCHPARAMS_JS = @embedFile("urlsearchparams_js");
const TIME_JS = @embedFile("time_js");
const SCHEDULE_JS = @embedFile("schedule_js");
const AFTER_JS = @embedFile("after_js");
const STREAM_JS = @embedFile("stream_js");
const NEXT_JS = @embedFile("next_js");
const WEBHOOK_JS = @embedFile("webhook_js");
const TEXTCODEC_JS = @embedFile("textcodec_js");
const REQUEST_JS = @embedFile("request_js");
const BLOB_JS = @embedFile("blob_js");

/// (public name, embedded source) for every `globals/*.js` file. The
/// single list the Phase-A lints below pivot on: each `.src` is an
/// `@embedFile`'d const, so a build.zig embed that loses its file
/// fails to compile here; lint(c) enforces the inverse (every native
/// `_system.*` namespace has an entry) and lint(b) enforces every
/// export in `.src` carries a JSDoc block. Adding a `globals/*.js`
/// shim means adding it here too (and to build.zig + installStatic).
pub const GLOBALS_FILES = [_]struct { name: []const u8, src: []const u8 }{
    .{ .name = "kv", .src = KV_JS },
    .{ .name = "console", .src = CONSOLE_JS },
    .{ .name = "crypto", .src = CRYPTO_JS },
    .{ .name = "http", .src = HTTP_JS },
    .{ .name = "platform", .src = PLATFORM_JS },
    .{ .name = "base64", .src = BASE64_JS },
    .{ .name = "urlsearchparams", .src = URLSEARCHPARAMS_JS },
    .{ .name = "time", .src = TIME_JS },
    // schedule installs the private `_system.sched`, not a customer global;
    // kept here for the JSDoc lint (lint(b)). lint(c) pivots native→shim
    // only, so a shim without a matching native namespace is fine.
    .{ .name = "schedule", .src = SCHEDULE_JS },
    .{ .name = "after", .src = AFTER_JS },
    .{ .name = "stream", .src = STREAM_JS },
    .{ .name = "next", .src = NEXT_JS },
    .{ .name = "webhook", .src = WEBHOOK_JS },
    .{ .name = "textcodec", .src = TEXTCODEC_JS },
    .{ .name = "blob", .src = BLOB_JS },
};

fn installNamespace(ctx: *c.JSContext, global: c.JSValue, ns: NamespaceBindings) void {
    const leaf = c.JS_NewObject(ctx);
    for (ns.fns) |fb| attachFn(ctx, leaf, fb);

    // Walk to the parent of the leaf. parent starts as a fresh dup
    // so the same free-and-replace pattern works on iteration zero
    // and onwards.
    var parent = c.JS_DupValue(ctx, global);
    defer c.JS_FreeValue(ctx, parent);

    for (ns.path[0 .. ns.path.len - 1]) |seg| {
        const next = c.JS_GetPropertyStr(ctx, parent, seg.ptr);
        c.JS_FreeValue(ctx, parent);
        parent = next;
    }

    _ = c.JS_SetPropertyStr(ctx, parent, ns.path[ns.path.len - 1].ptr, leaf);
}

fn extendIntrinsic(ctx: *c.JSContext, global: c.JSValue, ns: NamespaceBindings) void {
    var target = c.JS_DupValue(ctx, global);
    defer c.JS_FreeValue(ctx, target);

    for (ns.path) |seg| {
        const next = c.JS_GetPropertyStr(ctx, target, seg.ptr);
        c.JS_FreeValue(ctx, target);
        target = next;
    }

    if (c.JS_IsUndefined(target)) return;

    for (ns.fns) |fb| attachFn(ctx, target, fb);
}

fn attachFn(ctx: *c.JSContext, target: c.JSValue, fb: FnBinding) void {
    _ = c.JS_SetPropertyStr(
        ctx,
        target,
        fb.name.ptr,
        c.JS_NewCFunction2(ctx, fb.cfunc, fb.name.ptr, fb.argc, c.JS_CFUNC_generic, 0),
    );
}

fn evalSnippet(ctx: *c.JSContext, name: [*:0]const u8, source: []const u8) void {
    const result = c.JS_Eval(ctx, source.ptr, source.len, name, c.JS_EVAL_TYPE_GLOBAL);
    c.JS_FreeValue(ctx, result);
}

/// Convenience wrapper: install everything at once. Used by tests and
/// by any caller that doesn't have a pre-built snapshot to restore
/// from (e.g. the rove-files compile-on-upload path that just needs a
/// throwaway context to compile JS to bytecode).
pub fn install(
    ctx: *c.JSContext,
    state: *DispatchState,
    request: anytype,
) void {
    installStatic(ctx);
    installRequest(ctx, state, request);
}

// ── Phase A documentation lints (docs/architecture/builtin-libs.md) ──
//
// Run under `zig build test`. (a) — "no customer code references
// `_system`" — is a repo-tree scan and lives in
// scripts/ops/globals_lint.py: a unit test can't robustly walk
// examples/ + web/ without coupling to cwd/layout. (b) and (c) are
// hermetic here — they pivot on GLOBALS_FILES + the native-binding
// arrays in this file, so they need no filesystem and fail at the
// source the moment a binding is added without its shim/doc.

/// True when the text immediately before `decl_start` (ignoring
/// trailing whitespace) closes a `/** … */` JSDoc block. Comments
/// don't nest in JS, so the nearest preceding `/*` is the opener.
fn lintPrecededByJsdoc(src: []const u8, decl_start: usize) bool {
    var i = decl_start;
    while (i > 0) : (i -= 1) {
        const ch = src[i - 1];
        if (ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') break;
    }
    if (i < 2 or src[i - 2] != '*' or src[i - 1] != '/') return false;
    const close = i - 2; // index of '*' in the closing '*/'
    const opener = std.mem.lastIndexOf(u8, src[0..close], "/*") orelse return false;
    return opener + 2 < close and src[opener + 2] == '*'; // "/**"
}

test "lint(c): every native binding has a globals/ shim (Phase A)" {
    // Documented exceptions (docs/architecture/builtin-libs.md): Date.now /
    // Math.random are INTRINSIC_EXTENSIONS (out of scope — intrinsic
    // determinism overrides). No bare `__rove_*` GLOBAL_BUILTINS remain —
    // the privileged ops live under `__rove.*` / `_system.continuation.*`,
    // and the outbound plan-rate moved to the frozen fetch primitive
    // (`bindings/http.zig`), so this list is empty.
    const builtin_exceptions = [_][]const u8{};

    // Documented namespace exceptions: `_system.continuation.next` backs
    // the public `next()` disposition (shim is next.js, not
    // continuation.js, so the shim-name pivot needs the exemption). The
    // gated `__rove.*` holder is skipped by this loop entirely (it pivots
    // on `_system.*` paths only).
    const ns_exceptions = [_][]const u8{"continuation"};

    for (STATIC_NAMESPACES) |ns| {
        // The `_system` holder itself + nested paths
        // (`_system.platform.root`) are covered by their top-level
        // shim (globals/platform.js). Pivot on the public segment.
        if (ns.path.len < 2 or !std.mem.eql(u8, ns.path[0], "_system")) continue;
        const public = ns.path[1];
        var exempt = false;
        for (ns_exceptions) |e| if (std.mem.eql(u8, e, public)) {
            exempt = true;
            break;
        };
        if (exempt) continue;
        var found = false;
        for (GLOBALS_FILES) |g| {
            if (std.mem.eql(u8, g.name, public)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print(
                "\nlint(c): native `_system.{s}` has no globals/ shim — add " ++
                    "globals/{s}.js + build.zig embed + GLOBALS_FILES entry\n",
                .{ public, public },
            );
            return error.MissingGlobalsShim;
        }
    }

    for (GLOBAL_BUILTINS) |fb| {
        var ok = false;
        for (builtin_exceptions) |e| {
            if (std.mem.eql(u8, e, fb.name)) {
                ok = true;
                break;
            }
        }
        if (ok) continue;
        for (GLOBALS_FILES) |g| {
            if (std.mem.eql(u8, g.name, fb.name)) {
                ok = true;
                break;
            }
        }
        if (!ok) {
            std.debug.print(
                "\nlint(c): GLOBAL_BUILTIN `{s}` is neither a documented " ++
                    "exception nor shimmed in globals/\n",
                .{fb.name},
            );
            return error.UndocumentedBuiltin;
        }
    }
}

test "lint(b): every globals/*.js export carries a JSDoc block (Phase A)" {
    // Heuristic, namespace + class level (the plan's accepted scope:
    // "catches *missing* ones, can't validate signatures"). A
    // `globalThis.X = Ident;` alias is documented at its definition,
    // so only `= {` / `= function` definitions and `class` decls are
    // required to carry a preceding /** … */.
    for (GLOBALS_FILES) |g| {
        const src = g.src;

        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, src, idx, "class ")) |p| {
            idx = p + 6;
            if (p + 6 >= src.len or !std.ascii.isUpper(src[p + 6])) continue;
            // `class` must open a statement: only whitespace between
            // the line start and it (else it's prose/substring).
            var only_ws = true;
            var s = p;
            while (s > 0 and src[s - 1] != '\n') : (s -= 1) {
                if (src[s - 1] != ' ' and src[s - 1] != '\t') {
                    only_ws = false;
                    break;
                }
            }
            if (!only_ws) continue;
            if (!lintPrecededByJsdoc(src, p)) {
                std.debug.print(
                    "\nlint(b): globals/{s}.js — `class` at offset {d} has " ++
                        "no preceding /** JSDoc */\n",
                    .{ g.name, p },
                );
                return error.UndocumentedExport;
            }
        }

        idx = 0;
        while (std.mem.indexOfPos(u8, src, idx, "globalThis.")) |p| {
            idx = p + 11;
            var j = p + 11;
            while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_')) : (j += 1) {}
            while (j < src.len and (src[j] == ' ' or src[j] == '\t')) : (j += 1) {}
            if (j >= src.len or src[j] != '=') continue;
            j += 1;
            while (j < src.len and (src[j] == ' ' or src[j] == '\t')) : (j += 1) {}
            if (j >= src.len) continue;
            const is_def = src[j] == '{' or std.mem.startsWith(u8, src[j..], "function");
            if (!is_def) continue; // alias / re-export
            if (!lintPrecededByJsdoc(src, p)) {
                std.debug.print(
                    "\nlint(b): globals/{s}.js — `globalThis.` export at " ++
                        "offset {d} has no preceding /** JSDoc */\n",
                    .{ g.name, p },
                );
                return error.UndocumentedExport;
            }
        }
    }
}

test "harden: _system unreachable post-installStatic, shims still bound (Phase A)" {
    // Builds the base snapshot the way a worker does (installStatic),
    // then asserts customer scope can't see `_system` while the shims
    // — which captured their `_system.X` slice in a closure before
    // the delete — are still wired. A regression here means either
    // the delete moved before the shim evals or a shim started
    // reading `_system` lazily instead of via its captured `sys`.
    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    installStatic(ctx.raw);

    const assertion =
        \\(function () {
        \\  if (typeof globalThis._system !== "undefined")
        \\    throw new Error("_system still reachable from customer scope");
        \\  if (typeof kv !== "object" || typeof kv.get !== "function")
        \\    throw new Error("kv shim broke (closure lost its _system slice)");
        \\  if (typeof crypto !== "object" || typeof crypto.sha256 !== "function")
        \\    throw new Error("crypto shim broke");
        \\  if (typeof platform !== "object" ||
        \\      typeof platform.root.get !== "function")
        \\    throw new Error("platform nested shim broke");
        \\  if (typeof webhook !== "object" || typeof webhook.send !== "function")
        \\    throw new Error("webhook shim broke (lost its captured _system.http / _system.sched)");
        \\  if (typeof schedule !== "undefined")
        \\    throw new Error("schedule leaked to customer scope (should be the private _system.sched)");
        \\  return true;
        \\})();
    ;
    var result = ctx.eval(assertion, "_harden_test.js", .{}) catch |e| {
        if (ctx.takeExceptionMessage(std.testing.allocator)) |m| {
            defer std.testing.allocator.free(m);
            std.debug.print("\nharden regression: {s}\n", .{m});
        } else |_| {}
        return e;
    };
    defer result.deinit();
}

// ── SubscriptionEntry tests (Gap 2.1 Phase A) ───────────────────────

test "SubscriptionEntry.deinit frees kv spec" {
    const a = std.testing.allocator;
    var entry: SubscriptionEntry = .{
        .name = try a.dupe(u8, "process-jobs"),
        .module_path = try a.dupe(u8, "_subscriptions/process-jobs/index.mjs"),
        .spec = .{ .kv = .{ .prefix = try a.dupe(u8, "jobs/") } },
    };
    entry.deinit(a);
}


test "the kv write caps match the snapshot stream's frame bounds" {
    // The caps are a CONTRACT and live in `rove-reserved`, where the offline
    // engines can read them without importing the kv stack. Their REASON is
    // the stream frame, which lives here. This is the seam between the two:
    // raise the frame without raising the contract (or the reverse) and the
    // engines start disagreeing about which writes are legal — the shape of
    // rove#502, one layer down.
    try std.testing.expectEqual(kv_mod.snapshot_stream.STREAM_KEY_MAX, reserved.KV_KEY_MAX);
    // Not equality: the write cap is bounded by what one raft message can
    // carry, the stream by what a store may already hold. The stream must be
    // able to move anything a write could ever have created — narrowing it
    // under the write cap is what would strand a tenant mid-catch-up.
    try std.testing.expect(reserved.KV_VAL_MAX <= kv_mod.snapshot_stream.STREAM_VAL_MAX);
}
