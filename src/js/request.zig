//! `Request` — the input packet a `Dispatcher.runOutcome` consumes for
//! one handler activation, plus the response/outcome types it produces.
//!
//! This is the data model only; the dispatch engine lives in
//! `dispatcher.zig`, which re-exports `Request` / `Response` /
//! `RunOutcome` / `ActivationSource` / `SubscriptionFireSource` so
//! external `dispatcher.Request` references keep resolving.
//!
//! `Request` groups its fields by concern: the wire HTTP basics stay
//! top-level, the activation payload is a tagged `Activation` union
//! (only the variant matching the activation source is meaningful — the
//! union makes "exactly one payload" structural), and the remaining
//! cross-cutting references are bundled into small sub-structs
//! (`plan` / `trace` / `admin` / `trampolines` / `effects`).

const std = @import("std");
const kv_mod = @import("raft-kv");
const tape_mod = @import("rove-tape");
const tenant_mod = @import("rove-tenant");
const h2 = @import("rove-h2");
const log_mod = @import("rove-log");
const rove = @import("rove");

const globals = @import("globals.zig");
const limiter_mod = @import("limiter.zig");
const blob_mod = @import("rove-blob");
const blob_sessions_mod = @import("blob_sessions.zig");
const continuation_mod = @import("bindings/continuation.zig");
const stream_mod = @import("bindings/stream.zig");
const components_mod = @import("components.zig");

/// Re-export so handlers/dispatch code can refer to it as
/// `dispatcher.ActivationSource` / `request.ActivationSource` without a
/// separate import. Canonical definition lives in `log_mod` (it's
/// metadata for the log record).
pub const ActivationSource = log_mod.ActivationSource;

/// Gap 2.1 subscription-fire payload, discriminated by origin kind.
/// Carried on `Activation.subscription_fire`; the variant IS the
/// `source.kind` the JS surface reports (no "whichever slot is set"
/// re-derivation). Borrowed slices — the caller
/// (`fireSubscriptionActivation`) owns the bytes for the dispatch.
/// `worker_streaming.SubscriptionFireSource` aliases this.
pub const SubscriptionFireSource = union(enum) {
    kv: struct { key: []const u8, op: u8 },
    boot: struct { deployment_id: u64 },
};

// ---------------------------------------------------------------------
// Activation — the per-source payload, discriminated by source kind.
// ---------------------------------------------------------------------

/// Gap 2.3 / Phase 5 PR-1 `http.fetch` activation payload. `id`
/// correlates every activation of one fetch; surfaces as
/// `request.activation.fetch_id`. Borrowed slices — the caller
/// (`fireFetchEventActivation`) owns the bytes for the dispatch.
pub const FetchChunk = struct {
    id: ?[]const u8 = null,
    /// 0-based chunk index.
    seq: u32 = 0,
    /// Cumulative bytes delivered before this chunk.
    byte_offset: u64 = 0,
    /// The chunk payload (surfaces as `request.activation.bytes`, a
    /// Uint8Array). May be empty on a transport-error / empty-body final.
    bytes: []const u8 = &.{},
    /// Parsed upstream response headers (JSON-encoded `{"name":"value"}`),
    /// present on `seq == 0` only.
    headers: ?[]const u8 = null,
    /// True on the last activation for this fetch; the terminal fields
    /// below are valid only then.
    final: bool = false,
    /// `final` only: upstream HTTP status (0 on transport error).
    terminal_status: u16 = 0,
    /// `final` only: transport-only success flag. `ok: true, status: 503`
    /// is "transport worked, server said no"; `ok: false` is libcurl-level
    /// failure (timeout / DNS / TLS / cancel). The JS layer interprets.
    terminal_ok: bool = false,
    /// `final` only: true if upstream sent more body than the cap and the
    /// runtime aborted the rest. Surfaces as
    /// `request.activation.body_truncated`.
    body_truncated: bool = false,
};

/// Wake-batch payload (Gap 2.2 Phase D / streaming-handlers-plan §9.4).
pub const WakeBatch = struct {
    /// A temporal-order slice drained from the held stream's `PendingWakes`
    /// ring. Surfaces as `request.activation.wakes`. Borrowed slice — the
    /// caller (`resumeStream`) owns the entries + their `kv_key` bytes for
    /// the duration of the dispatch.
    wakes: []const components_mod.WakeEntry = &.{},
    /// Ring-overflow count snapshotted at drain time. Surfaces as
    /// `request.activation.overflow.lost_oldest`; 0 in the common case.
    lost_oldest: u32 = 0,
};

/// Gap 2.1 subscription_fire payload. `name` is the subscription's
/// directory name (common to all kinds); `source` is the
/// kind-discriminated payload. Borrowed slices — the caller
/// (`fireSubscriptionActivation`) owns the bytes for the dispatch.
pub const SubscriptionFire = struct {
    name: ?[]const u8 = null,
    source: ?SubscriptionFireSource = null,
};

/// §2.6 durable-wake activation payload. Surfaces as
/// `request.activation.{id, key, scheduled_at_ns, msg}` where `msg` is the
/// parsed `msg_json`. Borrowed slices — the caller
/// (`fireDurableWakeActivation`) owns the bytes for the dispatch.
pub const DurableWake = struct {
    id: ?[]const u8 = null,
    key: ?[]const u8 = null,
    scheduled_at_ns: i64 = 0,
    /// JSON-encoded customer `msg` ("null" when omitted); decoded back to a
    /// JS value as `request.activation.msg`.
    msg_json: ?[]const u8 = null,
};

/// Inbound WebSocket frame payload (`docs/websocket-plan.md` §5).
/// Surfaces as `request.activation.{opcode, data}` to the `onMessage`
/// export. `opcode` is the RFC 6455 data opcode (1 = text → `data` is a
/// string, 2 = binary → `data` is a Uint8Array). `data` is the borrowed
/// frame payload — the caller (`fireWsMessage`) owns the bytes for the
/// dispatch's duration.
pub const WsMessage = struct {
    opcode: u8 = 0,
    data: []const u8 = &.{},
};

/// Gap 2.4 streaming-inbound-body chunk payload
/// (`docs/inbound-chunk-plan.md`). The chunk bytes themselves ride
/// `Request.body` (the documented customer surface is `request.body` =
/// THIS chunk); this carries the per-chunk bookkeeping that surfaces as
/// `request.chunkSeq` / `request.done`.
pub const InboundChunk = struct {
    /// 0-based chunk index (`request.chunkSeq`).
    seq: u32 = 0,
    /// Cumulative bytes delivered before this chunk.
    byte_offset: u64 = 0,
    /// True on the last chunk (`request.done`). A body that completed
    /// under the cap fires exactly once with `seq == 0` and
    /// `done == true`.
    done: bool = false,
    /// The held chain's `next({ctx})` payload (JSON text, borrowed
    /// from the parked ContDescriptor for the dispatch) — surfaces as
    /// `request.ctx` on chunk 1+. Null on the first fire (no
    /// continuation yet).
    ctx_json: ?[]const u8 = null,
};

/// What caused this activation, carrying the per-source payload. Only the
/// active variant is meaningful; `installRequest` switches on it to build
/// the JS-side `request.activation` shape. Recorded on the tape via
/// `source()`. Inbound is the wire-request case; `send_callback` covers
/// both `__rove_next` resumes (§6.4) and the plain on_result callback.
pub const Activation = union(enum) {
    inbound,
    /// Headers-first inbound (blob-storage-plan §3.5; `docs/architecture/routing-and-ingress.md`): the
    /// body is still inbound; the handler's `onHeaders` export runs
    /// with an empty body to decide the disposition.
    inbound_headers,
    send_callback,
    /// Timer wake on a held stream (streaming-handlers-plan §4.5).
    timer,
    /// Client disconnect on a held stream (streaming-handlers-plan §4.4).
    disconnect,
    /// Legacy single-slot kv-write wake. Superseded by `wake_batch`;
    /// retained so replay can still decode pre-§9.4 tapes.
    kv_wake,
    wake_batch: WakeBatch,
    subscription_fire: SubscriptionFire,
    fetch_chunk: FetchChunk,
    durable_wake: DurableWake,
    ws_message: WsMessage,
    inbound_chunk: InboundChunk,

    /// The log/tape wire enum for this activation. Keeps
    /// `log_mod.ActivationSource` authoritative for the record while the
    /// union models the in-RAM payload.
    pub fn source(self: Activation) ActivationSource {
        return switch (self) {
            .inbound => .inbound,
            .inbound_headers => .inbound_headers,
            .send_callback => .send_callback,
            .timer => .timer,
            .disconnect => .disconnect,
            .kv_wake => .kv_wake,
            .wake_batch => .wake_batch,
            .subscription_fire => .subscription_fire,
            .fetch_chunk => .fetch_chunk,
            .durable_wake => .durable_wake,
            .ws_message => .ws_message,
            .inbound_chunk => .inbound_chunk,
        };
    }

    /// True for activations that RESUME a handler's own prior async work
    /// (callbacks, wakes, held-stream lifecycle) rather than carrying a fresh
    /// external request. `_middlewares` is an authn/authz gate for the trust
    /// boundary — the inbound request — and a continuation already ran behind
    /// that gate, so the dispatcher SKIPS middleware for these. Otherwise a
    /// tenant's own auth middleware 401s its own callbacks: the reason
    /// `__system/*` modules were special-cased, and the bound-fetch-through-
    /// middleware footgun A5 surfaced (an `onFetchResult` resume — a
    /// `fetch_chunk` — short-circuited by `__admin__`'s RP guard). Auth that a
    /// continuation needs is threaded via its ctx, not re-derived here. New
    /// activation kinds default to NON-continuation (gated) — the safe side.
    pub fn isContinuation(self: Activation) bool {
        return switch (self) {
            .inbound, .inbound_headers, .ws_message, .inbound_chunk => false,
            .send_callback, .timer, .disconnect, .kv_wake, .wake_batch,
            .subscription_fire, .fetch_chunk, .durable_wake => true,
        };
    }

    /// Build the payload-LESS arm matching `src`. For sources that carry a
    /// payload, the caller must build the arm explicitly — reaching here
    /// with one is an invariant violation (the source set a payload-source
    /// tag without providing the payload).
    pub fn fromSource(src: ActivationSource) Activation {
        return switch (src) {
            .inbound => .inbound,
            .inbound_headers => .inbound_headers,
            .send_callback => .send_callback,
            .timer => .timer,
            .disconnect => .disconnect,
            .kv_wake => .kv_wake,
            .wake_batch, .subscription_fire, .fetch_chunk, .durable_wake, .ws_message, .inbound_chunk => std.debug.panic(
                "Activation.fromSource: {s} carries a payload; build the arm explicitly",
                .{@tagName(src)},
            ),
        };
    }
};

// ---------------------------------------------------------------------
// Concern clusters — cross-cutting references bundled by subsystem. Each
// is embedded (non-optional) with fully-defaulted fields, so omitting a
// sub-field is identical to the pre-decomposition flat default.
// ---------------------------------------------------------------------

/// Rate-limit / plan inputs, threaded to `DispatchState` so both the
/// request-rate check and the `email.send` rate check size their buckets
/// from the tenant's plan (docs/architecture/control-plane.md Lever 1). Defaults = the
/// free/default caps for paths with no resolved plan (tests, internal
/// callback dispatch).
pub const PlanLimits = struct {
    /// Per-worker rate limiter. Null in test paths that don't exercise it.
    limiter: ?*limiter_mod.RateLimiter = null,
    /// Instance id this request scopes to (the limiter's per-instance
    /// bucket key). Empty outside a worker context (test paths).
    instance_id: []const u8 = "",
    plan_rate: limiter_mod.RateLimitCaps = .{},
    plan_gen: u64 = 0,
    /// blob-storage-plan P1; `docs/architecture/routing-and-ingress.md`: the node's S3 backend config
    /// for `_system.blob.presign` (borrowed from
    /// `NodeState.blob_backend_cfg`). Null outside a worker context —
    /// presign throws "not configured".
    blob_cfg: ?*const blob_mod.BackendConfig = null,
};

/// Per-request tracing + tape-replay metadata.
pub const Trace = struct {
    /// Optional captured readset. When set, every source of handler
    /// non-determinism (`kv.*`, `Date.now`, `Math.random`, crypto, the
    /// module loader's `(specifier, source_hash)` resolutions) is captured
    /// so the worker can persist it and replay can re-drive the handler.
    /// Owned by the caller. See `docs/readset-replication-plan.md`.
    readset: ?*tape_mod.Readset = null,
    /// Pre-minted per-request identifier. `webhook.send` derives a stable
    /// outbox id (`sha256(request_id || call_index)`) from it; the log
    /// record + outbox rows share it.
    request_id: u64 = 0,
    /// Per-chain identifier; the same string on every activation of one
    /// logical interaction (streaming-handlers-plan §5/§6). Inbound mints
    /// it (accepting an `X-Rove-Correlation-Id` header when present);
    /// resumes inherit. Null on test paths that don't care.
    correlation_id: ?[]const u8 = null,
};

/// Admin-tenant platform surface. All-null for every non-admin request;
/// the JS callables reject at the gate when `platform == null`.
pub const Admin = struct {
    /// Non-null on admin-tenant requests — points back at the `Tenant` so
    /// the JS globals can install `platform.root.*`.
    platform: ?*tenant_mod.Tenant = null,
    /// Collects `platform.root.*` writes for the worker to propose through
    /// raft. Null = writes land locally only (fine for tests / single-node,
    /// not multi-node correctness).
    root_writeset: ?*kv_mod.WriteSet = null,
    /// Admin platform-capability trampolines (deployStarter /
    /// releases.publish / scope().kv), bundled all-or-nothing. See
    /// `globals.PlatformCaps`.
    platform_caps: ?globals.PlatformCaps = null,
};

/// Worker-supplied re-entry trampolines (opaque ctx + concrete fn so the
/// worker's generic type never leaks into globals.zig). Each is null on
/// test paths / non-worker dispatches; the matching JS callable degrades
/// gracefully (returns false / no-ops) when null.
pub const Trampolines = struct {
    /// Phase 5 PR-3: `_system.continuation.resumeIfBound(send_id,
    /// event_json)` — the §6.4 held-sync resume hook. Wired to
    /// `worker.resumeBoundContinuation`.
    resume_if_bound: ?*const fn (
        ctx: *anyopaque,
        tenant_id: []const u8,
        send_id: []const u8,
        event_json: []const u8,
    ) bool = null,
    resume_if_bound_ctx: ?*anyopaque = null,
    /// `docs/curl-multi-plan.md` Phase 2: cancel-fetch trampoline. Wired to
    /// `FetchEngine.cancel`.
    cancel_fetch: ?*const fn (ctx: *anyopaque, id: []const u8) void = null,
    cancel_fetch_ctx: ?*anyopaque = null,
    /// §2.6 durable-wake trampolines. `set_wake` stores this tenant's
    /// next-fire watermark; `fire_wake` enqueues a `durable_wake`
    /// activation per due entry. Non-null only on the baked
    /// `__system/scheduler_tick` fire path.
    set_wake: ?*const fn (ctx: *anyopaque, tenant_id: []const u8, when_ns: i64) void = null,
    set_wake_ctx: ?*anyopaque = null,
    fire_wake: ?*const fn (ctx: *anyopaque, input: globals.FireWakeInput) bool = null,
    fire_wake_ctx: ?*anyopaque = null,
    /// blob-storage-plan P2; `docs/architecture/routing-and-ingress.md`: blob upload sessions.
    /// `blob_write` appends to (creating on first write) the chain's
    /// session; `blob_seal` finalizes it and hands back hash + bytes
    /// for the binding's seal-PUT PendingFetch. Wired to the worker's
    /// `blobWriteTrampoline` / `blobSealTrampoline`; null on paths
    /// with no worker (the bindings then throw "not supported").
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
};

/// Caller-owned accumulators the bindings append to during the dispatch;
/// the dispatcher threads the pointers into `DispatchState` and the worker
/// flushes / frees them after the run.
pub const PendingEffects = struct {
    /// `http.fetch` accumulator (Gap 2.3 Phase C1).
    pending_fetches: ?*std.ArrayListUnmanaged(globals.PendingFetch) = null,
    /// `on.timer` / `on.kv` accumulator (Handler-surface Phase 1). Set only
    /// on connection activations; null elsewhere (`on.*` inert).
    pending_wakes: ?*std.ArrayListUnmanaged(globals.PendingWakeReg) = null,
    /// `stream.write(chunk)` accumulator (Handler-surface Phase 2).
    /// `finishResponse` drains it into the `Stream` descriptor (next() ⇒
    /// keep streaming) or prepends it to the terminal body (close).
    pending_stream_chunks: ?*std.ArrayListUnmanaged([]u8) = null,
    /// websocket-plan §5: per-chunk WS data opcode accumulator, pushed in
    /// lockstep with `pending_stream_chunks`. Non-null only on a WS
    /// connection activation; null elsewhere.
    pending_stream_chunk_opcodes: ?*std.ArrayListUnmanaged(u8) = null,
};

// ---------------------------------------------------------------------
// Request
// ---------------------------------------------------------------------

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    /// Wire host (HTTP/2 `:authority`, or HTTP/1 `Host:`). Includes the
    /// `:port` segment when present — admin's JS handler uses it verbatim to
    /// build absolute magic-link URLs. Empty when the worker dispatches
    /// without a wire request (test paths, internal callback dispatch).
    host: []const u8 = "",
    body: []const u8 = "",
    /// Query string (everything after `?`, not including it). Null when the
    /// URL had none. Surfaced as `request.query` — opaque to the platform
    /// (the former `?fn=`/`&args=` platform dispatch is retired; handlers
    /// that want query-based routing parse it in JS, decisions.md §4.5).
    query: ?[]const u8 = null,
    /// Internal resume-path dispatch target. The platform's own resume
    /// engines (send-callback / wake / bound-fetch / subscription /
    /// chained dispatch) name the export to invoke here — first-class,
    /// never via the customer-visible body or query string (the
    /// `{fn,args}` envelope is retired, decisions.md §4.5). Null →
    /// the activation kind's conventional export
    /// (`rpc_dispatch.defaultExportForKind`). The export is invoked
    /// with no positional arguments — resume payloads (ctx / outcome)
    /// ride `body` and the `activation` union. Borrowed slice owned by
    /// the dispatching worker frame.
    fn_override: ?[]const u8 = null,
    /// Wire HTTP headers, lowercase per HTTP/2. Surfaced to JS as
    /// `request.headers` (pseudo-headers filtered) and `request.cookies`.
    /// Null = none supplied (test paths that don't care).
    headers: ?h2.ReqHeaders = null,
    /// Resolved session id (`__Host-rove_sid` cookie value or freshly
    /// minted). 64 lowercase hex chars when set; null on paths with no
    /// browser context. Surfaces as `request.session.id` / `null`.
    session_id: ?[64]u8 = null,
    /// Phase 5 PR-2b: true when the dispatched module belongs to the
    /// `__system/` namespace. Built-in modules are platform-trusted — they
    /// bypass the `isCustomerWriteReserved` check and skip middleware.
    is_system_module: bool = false,

    /// `docs/streaming-model.md` §7 item 1: the entity owning the chain
    /// this activation runs against. The http.fetch binding reads it when
    /// `bind: true` to register the held entity. Cross-source: set on every
    /// activation path that can host a bound fetch; null on test paths and
    /// subscription/cron/boot fires.
    activation_entity: ?rove.Entity = null,
    /// Bound-fetch count snapshot — surfaces as `request.fetchesPending` on
    /// onFetchChunk activations (includes the current fetch). Cross-source
    /// like `activation_entity`; 0 elsewhere.
    activation_fetches_pending: u32 = 0,
    /// §9.4 write-pressure: count of chunks dropped from the held stream's
    /// `StreamChunks` queue since the last surfacing. Snapshotted + reset on
    /// each stream-chain activation; surfaces as
    /// `request.activation.write_pressure.dropped_chunks`. Read on every
    /// activation (0 for non-stream), so it stays top-level rather than in a
    /// union arm.
    activation_write_pressure_dropped: u32 = 0,

    /// What caused this activation + its per-source payload.
    activation: Activation = .inbound,

    /// Rate-limit / plan inputs.
    plan: PlanLimits = .{},
    /// Tracing + tape-replay metadata.
    trace: Trace = .{},
    /// Admin-tenant platform surface (all-null for customer requests).
    admin: Admin = .{},
    /// Worker-supplied re-entry trampolines.
    trampolines: Trampolines = .{},
    /// Caller-owned effect accumulators.
    effects: PendingEffects = .{},
};

// ---------------------------------------------------------------------
// Response / RunOutcome
// ---------------------------------------------------------------------

/// One `(name, value)` pair extracted from the handler's
/// `response.headers` object. Both fields are owned allocator slices; the
/// outer `Response` frees them on `deinit`.
pub const ResponseHeader = struct {
    name: []u8,
    value: []u8,
};

pub const Response = struct {
    status: i32 = 200,
    body: []u8,
    /// Captured `console.log` output (one line per call, newline-terminated).
    console: []u8,
    /// Exception message if the script threw. Empty on success.
    exception: []u8,
    /// Already-sanitized Set-Cookie header values, one per entry the handler
    /// pushed onto `response.cookies`. Each string is an owned, filter-passed
    /// cookie with any `Domain=...` attribute stripped (see
    /// `sanitizeSetCookie`). Empty slice = no cookies.
    set_cookies: [][]u8 = &.{},
    /// Custom response headers the handler set via `response.headers`. Names
    /// are already lowercased (HTTP/2 wire format) and vetted —
    /// pseudo-headers and hop-by-hop names are rejected in
    /// `extractResponseMetadata`. `set-cookie` is NOT accepted here.
    headers: []ResponseHeader = &.{},
    /// True when the body came from `JSON.stringify(ret)`. The worker stamps
    /// `content-type: application/json` when true. Suppressed when the
    /// handler set a content-type via `response.headers`.
    body_is_json: bool = false,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        allocator.free(self.console);
        allocator.free(self.exception);
        for (self.set_cookies) |cookie| allocator.free(cookie);
        if (self.set_cookies.len > 0) allocator.free(self.set_cookies);
        for (self.headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        if (self.headers.len > 0) allocator.free(self.headers);
        self.* = undefined;
    }
};

/// Outcome of a dispatch run. A *transient* function result the caller
/// consumes immediately to choose the next collection move — NOT a
/// discriminant persisted on a per-entity record (that would be the
/// `feedback_state_is_collection` antipattern). `.terminal` is today's
/// behavior verbatim; `.continuation` means the handler returned
/// `next(...)` and the request is mid-trampoline.
pub const RunOutcome = union(enum) {
    terminal: Response,
    continuation: continuation_mod.Continuation,
    /// Iterative streaming descriptor (streaming-handlers-plan §3.3, Phase
    /// 2). The handler returned `__rove_stream(...)`. The worker's success
    /// path drives the held h2 entity through the chunked-write lifecycle.
    stream: stream_mod.Stream,
    /// An `.inbound_headers` probe found no `onHeaders` export — the
    /// module wants the classic buffered path. Not a response: the
    /// dispatch site rolls back the probe's savepoint and asks h2 to
    /// buffer the body (`requestBodyBuffer`), re-dispatching the
    /// request body-complete later. Never produced by any other
    /// activation kind.
    no_onheaders,
    /// An `.inbound_chunk` probe found no `onChunk` export — the module
    /// wants the classic buffered path (gap 2.4,
    /// `docs/inbound-chunk-plan.md`). Same posture as `no_onheaders`:
    /// the dispatch site rolls back the probe's savepoint, caches the
    /// miss, and re-dispatches as a classic `.inbound`. Never produced
    /// by any other activation kind.
    no_onchunk,
};
