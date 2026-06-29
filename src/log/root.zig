//! rove-log — request-id minting + node-wide log buffer.
//!
//! Two responsibilities, two structs:
//!
//!   - `RequestIdMinter` is per-tenant. Mints `request_id`s by combining
//!     the worker_id (upper 16 bits) with a chunked-reservation seq
//!     (lower 48 bits) persisted into the tenant's app.db at
//!     `_log/next_request_seq`. Per-tenant because each tenant's
//!     request_id space must be monotonic across cluster restarts —
//!     replay would mismatch otherwise.
//!
//!   - `NodeLogBuffer` is per-node. A single in-memory `LogRecord`
//!     buffer that the dispatch path appends to from every tenant on
//!     the node. `flushLogs` periodically drains it into one combined
//!     batch and PUTs it to S3. Per-node because the on-the-wire
//!     layout interleaves tenants — the worker writes one object per
//!     flush window regardless of tenant fan-in.
//!
//! Pre-Phase-5.5(a-2): a single `LogStore` per tenant held both
//! responsibilities, plus a per-tenant in-memory buffer. The buffer
//! was leftover from the raft-era per-tenant `log.db` model — every
//! flush combined all tenants' buffers into one batch anyway, so the
//! per-tenant slicing was complexity with no purpose. Splitting the
//! struct removes a `HashMap(instance_id, *Buffer)` from the hot
//! append path and folds the two-pass `flushLogs` into a single
//! threshold check + drain.
//!
//! ## Best-effort, not durable
//!
//! Records sit in volatile memory between flushes. A worker crash
//! between `append` and the next flush loses those records. This is
//! intentional — logs are observability, not source-of-truth state.

const std = @import("std");
const kv_mod = @import("raft-kv");

pub const Error = error{
    Kv,
    OutOfMemory,
};

/// A low-cardinality, user-defined index tag attached to a request's
/// log record. Set by the handler via `request.tag(key, value)` and
/// indexed in the log-server's `log_tags` table so log queries can
/// filter `?tag.<key>=<value>` (and the `/v1/{tenant}/session/{id}`
/// sugar route filters `tag.session`). The browser-agent tags its
/// connection with `session = <app sid>` so the brain's `getReplay`
/// can pull just this session's activations.
///
/// Bounded by design (rove's low-cardinality posture): ≤`MAX_TAGS`
/// per record, key/value lengths capped, keys restricted to
/// `[a-z0-9_]`. A leading `_` is RESERVED for engine-populated tags
/// (e.g. `_corr`, derived from `correlation_id`) — `request.tag`
/// rejects it. `key`/`value` are allocator-owned by the `LogRecord`.
pub const Tag = struct {
    key: []const u8,
    value: []const u8,
};

/// Max user tags per record. Tags are an observability index, not a
/// payload — keep cardinality low. Over-cap is a handler bug
/// (`request.tag` throws), not a silent truncation.
pub const MAX_TAGS: usize = 4;
/// Tag key length cap. Keys are `[a-z0-9_]`.
pub const MAX_TAG_KEY_LEN: usize = 32;
/// Tag value length cap. Values should be low-cardinality (a plan
/// name, a flow id, a session id) — never a per-row unique like a
/// raw user id with millions of distinct values.
pub const MAX_TAG_VALUE_LEN: usize = 64;

/// Per-request lifecycle outcome.
pub const Outcome = enum(u8) {
    ok = 0,
    fault = 1,
    timeout = 2,
    handler_error = 3,
    kv_error = 4,
    no_deployment = 5,
    unknown_domain = 6,
};

/// What caused this handler activation (streaming-handlers-plan §2,
/// the wire enum behind `request.Activation` (via its `source()`) and
/// `LogRecord.activation`). v1 has the two implemented variants; the
/// enum grows (`kv_wake`, `timer`, `disconnect`) when `__rove_stream`
/// lands.
pub const ActivationSource = enum(u8) {
    inbound = 0,
    send_callback = 1,
    /// Timer wake on a held stream (streaming-handlers-plan §4.5).
    /// Phase 2b-ii: the streaming-handler primitive's `waitFor.timer`
    /// fires this when its `intervalMs` (or absMs) reaches the
    /// sweep's check.
    timer = 2,
    /// Client disconnect on a held stream (streaming-handlers-plan
    /// §4.4). Implicit on every parked chain — h2 detects FIN/RST,
    /// routes the entity to `response_out`, and `cleanupResponses`
    /// fires one final handler run with this activation so the
    /// customer can do cleanup (release resources, log a "session
    /// ended" event, etc.). The handler's return is recorded on the
    /// tape but no bytes reach the wire — the socket is already
    /// gone.
    disconnect = 3,
    /// kv-write match wake on a held stream (streaming-handlers-plan
    /// §4.6). The cell registered one or more tenant-scoped prefixes
    /// via `waitFor: { kv: { prefix } }`; `apply.zig`'s writeset
    /// hook fired on a matching `put`/`delete` and `resumeStream`
    /// runs the handler with `request.activation = { kind: "kv",
    /// key, op }`. Prefix-only — predicate filters out of scope
    /// (§4.6 + §11.1).
    ///
    /// Legacy single-slot activation source. Superseded by
    /// `wake_batch` (Gap 2.2). Retained in the enum so replay can
    /// still decode pre-§9.4 tapes.
    kv_wake = 4,
    /// Wake-batch activation (streaming-handlers-plan §9.4 +
    /// `docs/primitive-gaps.md` §2.2). The held stream's
    /// `PendingWakes` ring drained into a temporal-order batch of
    /// kv-write + timer entries; the handler sees
    /// `request.activation = { kind: "wake_batch", wakes: [...],
    /// overflow: { lost_oldest } }`. Supersedes the per-wake
    /// `kv_wake` / `timer` activation sources for held streams.
    wake_batch = 5,
    /// Subscription chain origin (`docs/primitive-gaps.md` §2.1 +
    /// `docs/subscriptions-plan.md`). A `_subscriptions/<name>/`
    /// handler is firing without an inbound HTTP request — driven
    /// by a cron schedule, an apply-time kv-write match, or a
    /// once-per-deployment-activation boot. The handler sees
    /// `request.activation = { kind: "subscription_fire", name,
    /// source: { kind:"cron"|"kv"|"boot", ... } }`. There's no
    /// held socket; `Response` is recorded but not transmitted.
    subscription_fire = 6,
    /// `http.fetch` event (`docs/primitive-gaps.md` §2.3 +
    /// `docs/effect-reification-plan.md` Phase 5 PR-1). Single
    /// activation kind covering both non-streaming (one event with
    /// `final: true`) and streaming (`stream: true`, multiple events,
    /// last one `final: true`). Activation shape: `{ kind:
    /// "fetch_chunk", fetch_id, seq, byteOffset, bytes, headers? (seq=0),
    /// final, status? (final), ok? (final), body_truncated? (final),
    /// ctx }`. Phase 5 PR-1 collapsed the prior `fetch_done` (8) and
    /// `fetch_pipe_done` (9) variants into this single tag along with
    /// dropping `pipe_to` / `on_done`.
    fetch_chunk = 7,
    /// Durable scheduled wake (`docs/primitive-gaps.md` §2.6 +
    /// `docs/architecture/effects-and-handlers.md`). A `scheduler.at(whenNs, target,
    /// msg)` entry fell due: the baked `__system/scheduler_tick`
    /// fanned out to `target` via `__rove_fire_wake`, and the target
    /// handler runs with `request.activation = { kind: "durable_wake",
    /// id, key, scheduled_at_ns, msg }`. At-least-once *firing* — the
    /// target owns dedup (the §2.6 firing contract). No held socket;
    /// the fired entry's two `_sched/` keys are deleted in this
    /// activation's own writeset (exactly-once on the normal path).
    durable_wake = 8,
    /// Inbound WebSocket frame (`docs/architecture/websockets.md`). A
    /// held WS connection is a parked continuation chain; each complete
    /// inbound data frame (text/binary) resumes it via `fireWsMessage`
    /// with `request.activation = { opcode, data }` dispatched to the
    /// `onMessage` export. Client close (opcode 8) routes to
    /// `onDisconnect` (the `disconnect` source above), not here. No
    /// held HTTP response — outbound frames are `stream.write` lowered
    /// to the h2 `ws_send_in` collection. Batch-of-1 durability: a
    /// frame costs raft iff its activation commits a non-empty writeset.
    ws_message = 9,
    /// Headers-first inbound dispatch (`docs/architecture/routing-and-ingress.md`
    /// §3.5, the `blob.receive` transport). The request's HEADERS
    /// frame arrived but body DATA is still inbound; the handler
    /// module exports `onHeaders`, so the activation runs with an
    /// EMPTY body and decides the disposition (early 4xx,
    /// `blob.receive` + `next()`) before the platform accepts a
    /// single body byte. The body bytes are untaped by derivation —
    /// no Msg carries them (§3.5's pipe_to symmetry).
    inbound_headers = 10,
    /// Streaming inbound body chunk (gap 2.4,
    /// `docs/architecture/effects-and-handlers.md` + `docs/handler-shape.md` §4). The
    /// handler module exports `onChunk`; the inbound body dispatches
    /// per-chunk — `request.body` = THIS chunk, `request.done` flags
    /// the last, `request.chunkSeq` counts from 0. A body that
    /// completed under the cap fires once with the whole body and
    /// `done = true`. Chunk bytes are recorded inputs (L3) — they ride
    /// the activation's tape like fetch chunks.
    inbound_chunk = 11,
};

/// Inline tape + body byte payloads for one request. Each `_bytes`
/// field is allocator-owned; empty (`&.{}`) for channels the handler
/// didn't touch. Tape capture stores these directly in the LogRecord
/// — the `tapes: TapePayloads` field — and the flush writer emits
/// them base64-encoded in the ndjson line.
///
/// Pre-Phase-5.5(a-2) these were content-addressed blobs in a
/// per-tenant `log-blobs/` S3 prefix, with the LogRecord carrying
/// only `*_hex` hash refs. The fanout (one PUT per channel per
/// request) capped tape capture at single-digit-thousand req/s
/// because std.http.Client serializes a single OVH connection that
/// drops mid-write under concurrent load. Inlining collapses the
/// per-request PUT count to zero — bytes ride the existing per-flush
/// ndjson PUT — and removes the read-side hash→blob fetch hop.
pub const TapePayloads = struct {
    /// `docs/primitive-gaps.md` §9 seed-not-draws. The PRNG seed
    /// used to initialize arenajs's per-context xorshift64star for
    /// this request's `Math.random` / `crypto.*` draws. Replay
    /// seeds the same value via `arena_set_random_seed` before
    /// running the handler — the scalar IS the entire input for
    /// random (no per-draw tape entries). Zero is the default for
    /// non-handler paths that build payloads without a Readset
    /// (early-error records, paths still being wired).
    seed: u64 = 0,
    /// `docs/primitive-gaps.md` §9 fold-in. Wall-clock nanoseconds
    /// captured at dispatch entry. Replay pins arenajs's per-
    /// context `Date.now()` to `@divTrunc(timestamp_ns, ns_per_ms)`
    /// via `arena_set_date_now`, so every `Date.now()` and
    /// `new Date()` (no args) inside the handler returns the same
    /// scalar — no per-call tape entries. Zero is the default for
    /// non-handler paths.
    timestamp_ns: i64 = 0,
    /// The JS engine version that executed this request
    /// (`docs/plans/format-versioning-audit.md` §4). Copied from
    /// `Readset.js_engine_version` at capture; surfaced in the log
    /// JSON so the replayer can later fetch the matching engine.
    /// Zero = unknown (non-handler / pre-stamp paths). A passenger on
    /// the record co-located with the other per-request execution
    /// scalars (`seed`/`timestamp_ns`).
    js_engine_version: u16 = 0,
    kv_tape_bytes: []const u8 = &.{},
    module_tree_bytes: []const u8 = &.{},
    /// `docs/readset-replication-plan.md` Phase 2c-2. Per-`http.fetch`
    /// chunk-activation tape: each entry carries a `BodyRef` into the
    /// per-tenant readset-blob store. Empty when the chain made no
    /// outbound fetches.
    fetch_responses_tape_bytes: []const u8 = &.{},
    /// `docs/readset-replication-plan.md` Phase 2d. Zero-or-one entry
    /// carrying the inbound request body's `BodyRef`. Empty when the
    /// request had no body — or when the handler never READ the body
    /// (read-taping: `Readset.elideUnreadBody` drops the reference;
    /// the `request_reads` channel's `body_read` marker is the
    /// discriminator between the two).
    trigger_payload_tape_bytes: []const u8 = &.{},
    /// The lazily-recorded request-surface reads (header names +
    /// read values, body-read marker, ip reads) — see
    /// `tape.Channel.request_reads`. Empty for activations with no
    /// recorded reads or non-handler producers.
    request_reads_tape_bytes: []const u8 = &.{},
    /// Captured request body, iff the handler read `request.body`
    /// AND it fit the inline cap (16 KB, `REQUEST_BODY_CAP` — larger
    /// read bodies live in BlobBackend via the trigger_payload
    /// BodyRef). Empty when the request had no body, the handler
    /// never read it, or the worker chose not to capture (no tenant
    /// log open).
    request_body_bytes: []const u8 = &.{},
    /// True iff `request_body_bytes` is a truncated prefix. Replay
    /// still feeds the captured bytes — the handler's view is what
    /// was captured, even if that's less than the original.
    request_body_truncated: bool = false,
    /// Captured activation input bytes (or its 256 KB prefix) for
    /// activations whose Msg payload carries bytes the handler
    /// reads — today only `fetch_chunk` (the upstream chunk
    /// payload, surfaced as `request.activation.bytes`). Empty for
    /// every other activation source. L3 (`docs/effect-algebra.md`):
    /// every Msg is recorded, including its bytes — closes the
    /// effect-audit's fetch-A untaped-chunk bug.
    activation_bytes: []const u8 = &.{},
    /// True iff `activation_bytes` is a truncated prefix.
    activation_bytes_truncated: bool = false,
    // Response body is NOT captured — deterministic replay
    // re-produces it from (request body, tapes, source). Storing
    // it on every batch PUT would be pure duplication on the S3
    // bill.

    pub fn deinit(self: *TapePayloads, allocator: std.mem.Allocator) void {
        if (self.kv_tape_bytes.len != 0) allocator.free(self.kv_tape_bytes);
        if (self.module_tree_bytes.len != 0) allocator.free(self.module_tree_bytes);
        if (self.fetch_responses_tape_bytes.len != 0) allocator.free(self.fetch_responses_tape_bytes);
        if (self.trigger_payload_tape_bytes.len != 0) allocator.free(self.trigger_payload_tape_bytes);
        if (self.request_reads_tape_bytes.len != 0) allocator.free(self.request_reads_tape_bytes);
        if (self.request_body_bytes.len != 0) allocator.free(self.request_body_bytes);
        if (self.activation_bytes.len != 0) allocator.free(self.activation_bytes);
        self.* = .{};
    }
};

// ── Customer-facing ID formatting (format-versioning-audit.md §7.5) ────
//
// All customer-visible IDs carry a Stripe-style type prefix so every ID
// format stays versionable behind its prefix and reads as opaque. The
// INTERNAL representation is unchanged (request/deployment ids stay a
// u64 — `worker_id<<48 | seq` for requests — in the index, cursors, and
// storage); the prefix is applied only at customer boundaries: the JS
// `request.actor.request_id` surface and the logs API the dashboard
// serves (`/show`, the list + its cursor). Documented opaque — customers
// must NOT parse these (handler-shape.md §9). The raw hex still encodes
// `worker_id`; the prefix signalling "opaque, don't parse" is the agreed
// mitigation (opaque-by-contract decision, 2026-06-23) rather than a
// reversible mix.
pub const REQUEST_ID_PREFIX = "req_";
pub const DEPLOYMENT_ID_PREFIX = "dep_";
/// Session / fetch ids are 64-hex (CSPRNG / SHA-256), not the u64 form
/// above, so they're prefixed by plain concatenation at their JS
/// surfaces (`request.session.id`, `activation.fetch_id`) rather than
/// through `formatPrefixedId`. The internal cookie / router-key / S3-key
/// representations stay bare. Same opaque-token contract (§7.5).
pub const SESSION_ID_PREFIX = "sess_";
pub const FETCH_ID_PREFIX = "ftch_";
/// Buffer size a `formatPrefixedId` caller must provide: longest req/dep
/// prefix (4) + 16 hex digits.
pub const PREFIXED_ID_BUF: usize = 4 + 16;

/// Write `{prefix}{id:0>16x}` into `buf`, returning the written slice.
/// `buf` must be ≥ `prefix.len + 16` bytes (`PREFIXED_ID_BUF`).
pub fn formatPrefixedId(buf: []u8, prefix: []const u8, id: u64) []const u8 {
    @memcpy(buf[0..prefix.len], prefix);
    _ = std.fmt.bufPrint(buf[prefix.len..], "{x:0>16}", .{id}) catch unreachable;
    return buf[0 .. prefix.len + 16];
}

/// Parse a `{prefix}{16hex}` customer id back to the internal u64, or
/// null if the prefix is missing or the hex is malformed. The logs API
/// uses this to accept the same opaque token it handed out (the `/show`
/// path segment and the list `after_request_id` cursor).
pub fn parsePrefixedId(prefix: []const u8, s: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, s, prefix)) return null;
    return std.fmt.parseInt(u64, s[prefix.len..], 16) catch null;
}

test "prefixed id round-trips and rejects bad input" {
    var buf: [PREFIXED_ID_BUF]u8 = undefined;
    // worker_id 0xCAFE in the top 16 bits, seq 1 — the real mint shape.
    const id: u64 = (@as(u64, 0xCAFE) << 48) | 1;
    const s = formatPrefixedId(&buf, REQUEST_ID_PREFIX, id);
    try std.testing.expectEqualStrings("req_cafe000000000001", s);
    try std.testing.expectEqual(id, parsePrefixedId(REQUEST_ID_PREFIX, s).?);
    // Wrong prefix / malformed hex / bare hex all reject.
    try std.testing.expect(parsePrefixedId(DEPLOYMENT_ID_PREFIX, s) == null);
    try std.testing.expect(parsePrefixedId(REQUEST_ID_PREFIX, "req_xyz") == null);
    try std.testing.expect(parsePrefixedId(REQUEST_ID_PREFIX, "cafe000000000001") == null);
}

/// One request's log entry. All `[]const u8` fields are owned by the
/// record (allocated via the buffer's allocator). `deinit` frees them.
pub const LogRecord = struct {
    /// Tenant the request was scoped to. Lives on the record so a
    /// single per-node ndjson can interleave records from many
    /// tenants — the indexer demuxes on this field. Owned slice.
    tenant_id: []const u8,
    /// Combined identifier: upper 16 bits = worker_id, lower 48 = seq.
    /// INTERNAL u64 (index key + pagination cursor). Surfaced to
    /// customers only as the opaque prefixed `req_<16hex>` form
    /// (`formatPrefixedId` / `REQUEST_ID_PREFIX`) — never the bare
    /// integer. See §7.5.
    request_id: u64,
    /// The deployment that was active when this request ran.
    /// Pulled from `TenantFiles.current_deployment_id`. Replay needs
    /// this to load the exact bytecode the handler used.
    deployment_id: u64,
    received_ns: i64,
    duration_ns: i64,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    status: u16,
    outcome: Outcome,
    /// Captured `console.log`/`console.warn`/`console.error` output.
    /// Empty if the handler didn't write to console.
    console: []const u8,
    /// JS exception message if the handler threw. Empty otherwise.
    exception: []const u8,
    tapes: TapePayloads = .{},
    /// Low-cardinality user-defined index tags (≤`MAX_TAGS`), set by
    /// the handler via `request.tag(k, v)`. Owned slice with owned
    /// key/value bytes; `deinit` frees them. Empty (`&.{}`) when the
    /// handler set none. The log-server indexes these into `log_tags`
    /// for `?tag.k=v` filtering; the leader-captured record carries
    /// them. Like `console`/`exception`, follower-rebuilt records (the
    /// readset-replication path, which has no `LogHeader` tag field)
    /// omit them — tags are leader-captured observability.
    tags: []Tag = &.{},
    /// Per-chain identifier (streaming-handlers-plan §6). Empty
    /// string when the record has no chain context (pre-Phase-1
    /// records, or paths where the runtime couldn't synthesize one
    /// — early-error captures before request handling started).
    /// Allocator-owned alongside the other `[]const u8` fields.
    correlation_id: []const u8 = "",
    /// What caused this activation (streaming-handlers-plan §2).
    /// Defaults to `.inbound` for back-compat with code paths that
    /// haven't been updated to set it explicitly; the inbound case
    /// is by far the dominant one historically.
    activation: ActivationSource = .inbound,
    /// `docs/readset-replication-plan.md` Phase 5b: the raft seq
    /// the envelope carrying this request's writeset was proposed at.
    /// Zero is a sentinel for "no associated raft seq" (early-error
    /// paths, read-only batches that never proposed, paths not yet
    /// plumbed). `flushLogs` advances the per-worker `last_uploaded_seq`
    /// checkpoint by `max(record.raft_seq)`.
    raft_seq: u64 = 0,

    pub fn deinit(self: *LogRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.method);
        allocator.free(self.path);
        allocator.free(self.host);
        allocator.free(self.console);
        allocator.free(self.exception);
        if (self.correlation_id.len > 0) allocator.free(self.correlation_id);
        for (self.tags) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        if (self.tags.len > 0) allocator.free(self.tags);
        self.tapes.deinit(allocator);
        self.* = undefined;
    }
};

/// Per-request scalar + string metadata needed to reconstruct a
/// `LogRecord` from a raft entry. Lives on the readset wire format
/// (`docs/readset-replication-plan.md` Phase 5a) so any node — not
/// just the leader that originally served the request — can build
/// the LogRecord and push it to the customer-facing log path on
/// follower-promotion.
///
/// `console` + `exception` bytes are intentionally not carried here:
/// they're per-handler stdout that the leader can capture but a
/// follower would have to re-execute to recover. Follower-rebuilt
/// records leave both empty; customers recover console via tape
/// replay when needed.
///
/// All `[]const u8` fields BORROW into the parent readset wire
/// buffer. Encoders own + free; decoders alias.
pub const LogHeader = struct {
    request_id: u64,
    deployment_id: u64,
    /// Wall-clock duration of the request from `received_ns` to log
    /// capture. Stamped by the leader; followers re-using this header
    /// inherit the leader's clock-skewed value, which is fine for a
    /// human-readable log surface.
    duration_ns: i64,
    status: u16,
    outcome: Outcome,
    activation: ActivationSource,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    correlation_id: []const u8,

    /// Big-endian wire layout. Scalars first (fixed width), then four
    /// length-prefixed strings in canonical order:
    /// ```
    /// [u64 request_id BE]
    /// [u64 deployment_id BE]
    /// [i64 duration_ns BE]
    /// [u16 status BE]
    /// [u8  outcome]
    /// [u8  activation]
    /// [u32 method_len BE][method_bytes]
    /// [u32 path_len BE  ][path_bytes  ]
    /// [u32 host_len BE  ][host_bytes  ]
    /// [u32 corr_len BE  ][corr_bytes  ]
    /// ```
    /// Encoded size is `28 + 16 + sum(len_fields)` (28 scalar bytes +
    /// 4×u32 length prefixes + the variable string payloads).
    pub fn serialize(self: *const LogHeader, allocator: std.mem.Allocator) ![]u8 {
        const fixed: usize = 8 + 8 + 8 + 2 + 1 + 1;
        const var_bytes = self.method.len + self.path.len + self.host.len + self.correlation_id.len;
        const len_prefixes: usize = 4 * 4;
        const total = fixed + len_prefixes + var_bytes;
        const out = try allocator.alloc(u8, total);
        var cur: usize = 0;
        std.mem.writeInt(u64, out[cur..][0..8], self.request_id, .big);
        cur += 8;
        std.mem.writeInt(u64, out[cur..][0..8], self.deployment_id, .big);
        cur += 8;
        std.mem.writeInt(i64, out[cur..][0..8], self.duration_ns, .big);
        cur += 8;
        std.mem.writeInt(u16, out[cur..][0..2], self.status, .big);
        cur += 2;
        out[cur] = @intFromEnum(self.outcome);
        cur += 1;
        out[cur] = @intFromEnum(self.activation);
        cur += 1;
        const strings = [_][]const u8{ self.method, self.path, self.host, self.correlation_id };
        for (strings) |s| {
            std.mem.writeInt(u32, out[cur..][0..4], @intCast(s.len), .big);
            cur += 4;
            @memcpy(out[cur..][0..s.len], s);
            cur += s.len;
        }
        std.debug.assert(cur == total);
        return out;
    }
};

pub const LogHeaderParseError = error{ Truncated, BadEnum };

/// Parse a serialized `LogHeader` blob; the returned strings BORROW
/// into `bytes` and remain valid as long as `bytes` does.
pub fn parseLogHeader(bytes: []const u8) LogHeaderParseError!LogHeader {
    const fixed: usize = 8 + 8 + 8 + 2 + 1 + 1;
    if (bytes.len < fixed) return LogHeaderParseError.Truncated;
    var cur: usize = 0;
    const request_id = std.mem.readInt(u64, bytes[cur..][0..8], .big);
    cur += 8;
    const deployment_id = std.mem.readInt(u64, bytes[cur..][0..8], .big);
    cur += 8;
    const duration_ns = std.mem.readInt(i64, bytes[cur..][0..8], .big);
    cur += 8;
    const status = std.mem.readInt(u16, bytes[cur..][0..2], .big);
    cur += 2;
    const outcome_byte = bytes[cur];
    cur += 1;
    const activation_byte = bytes[cur];
    cur += 1;
    const outcome = std.meta.intToEnum(Outcome, outcome_byte) catch return LogHeaderParseError.BadEnum;
    const activation = std.meta.intToEnum(ActivationSource, activation_byte) catch return LogHeaderParseError.BadEnum;

    var strings: [4][]const u8 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (cur + 4 > bytes.len) return LogHeaderParseError.Truncated;
        const slen = std.mem.readInt(u32, bytes[cur..][0..4], .big);
        cur += 4;
        if (cur + slen > bytes.len) return LogHeaderParseError.Truncated;
        strings[i] = bytes[cur .. cur + slen];
        cur += slen;
    }
    if (cur != bytes.len) return LogHeaderParseError.Truncated;
    return .{
        .request_id = request_id,
        .deployment_id = deployment_id,
        .duration_ns = duration_ns,
        .status = status,
        .outcome = outcome,
        .activation = activation,
        .method = strings[0],
        .path = strings[1],
        .host = strings[2],
        .correlation_id = strings[3],
    };
}

/// Request-id reservation window size. `nextRequestId` hands out this
/// many ids in memory before persisting a new high-water mark to the
/// kv store. Larger = fewer SQLite autocommits per request (which
/// dominated ~29% of dispatch CPU profiling before this was batched);
/// smaller = fewer ids wasted to sparse gaps after a crash.
///
/// Invariant: after a crash, the next process resumes from the last
/// persisted `reserved_until`. Any ids already minted from the prior
/// window but not yet committed become a gap (unused, sparse), which
/// is benign — ids never collide across restarts.
pub const REQUEST_ID_CHUNK: u48 = 1024;

/// Where the chunked-reservation counter lives. The worker passes
/// `inst.kv` (app.db) and `"_log/next_request_seq"`. Tests pass a
/// dedicated SQLite file. Both fields are required — there is no
/// implicit fallback.
pub const Options = struct {
    seq_kv: *kv_mod.KvStore,
    seq_key: []const u8,
};

/// Per-tenant request_id minter. Holds the chunked-reservation state
/// for one tenant; `nextRequestId` mints the next id and persists
/// every `REQUEST_ID_CHUNK`-th one to the kv store.
pub const RequestIdMinter = struct {
    allocator: std.mem.Allocator,
    /// Upper 16 bits of every `request_id` minted by this minter.
    /// Sourced from raft node id at the worker layer; unique per node.
    worker_id: u16,
    /// Where chunked-reservation persists. See `Options.seq_kv`.
    seq_kv: *kv_mod.KvStore,
    /// Owned key used by the chunked-reservation counter (heap-
    /// allocated copy of `Options.seq_key` so the caller can pass
    /// a stack-local literal without lifetime worries).
    seq_key: []u8,
    /// Lower 48 bits of the next `request_id` to hand out. In-memory
    /// counter that advances on every `nextRequestId` call. Only
    /// values < `reserved_until` are safe to hand out — when they
    /// catch up, `nextRequestId` reserves a new chunk on disk.
    next_request_seq: u48,
    /// Highest (exclusive) seq that has been reserved on disk via
    /// `seq_key`. On restart this value is loaded and
    /// `next_request_seq` resumes from it, which may leave a sparse
    /// gap up to `REQUEST_ID_CHUNK` wide — acceptable since the
    /// invariant we need is "ids never collide," not "ids are dense."
    reserved_until: u48,

    /// Open a minter. Reads its chunked-reservation counter from
    /// `opts.seq_kv` at `opts.seq_key`; if absent, starts at 0. Any
    /// gap between the loaded value and what was actually handed out
    /// before the previous crash is intentional — see `REQUEST_ID_CHUNK`.
    pub fn init(
        allocator: std.mem.Allocator,
        worker_id: u16,
        opts: Options,
    ) Error!RequestIdMinter {
        const seq_key = allocator.dupe(u8, opts.seq_key) catch return Error.OutOfMemory;
        var self: RequestIdMinter = .{
            .allocator = allocator,
            .worker_id = worker_id,
            .seq_kv = opts.seq_kv,
            .seq_key = seq_key,
            .next_request_seq = 0,
            .reserved_until = 0,
        };
        const loaded = self.loadNextSeq() catch 0;
        self.next_request_seq = loaded;
        self.reserved_until = loaded;
        return self;
    }

    pub fn deinit(self: *RequestIdMinter) void {
        self.allocator.free(self.seq_key);
        self.* = undefined;
    }

    /// Mint a new request_id for the next request. Combines worker_id
    /// (upper 16) with the monotonic local seq (lower 48).
    ///
    /// Hands out ids from a pre-reserved window — the kv store only
    /// sees a write once per `REQUEST_ID_CHUNK` ids, not once per
    /// request. This is load-bearing for dispatch throughput: the
    /// per-request autocommit was ~29% of CPU in a 2026-04-14 profile.
    /// On restart, any unused tail of the last reservation is
    /// abandoned — ids become sparse across restarts, but never
    /// collide.
    pub fn nextRequestId(self: *RequestIdMinter) Error!u64 {
        if (self.next_request_seq >= self.reserved_until) {
            self.reserved_until = self.next_request_seq + REQUEST_ID_CHUNK;
            self.persistReservedUntil() catch return Error.Kv;
        }
        const seq = self.next_request_seq;
        self.next_request_seq +%= 1;
        return (@as(u64, self.worker_id) << 48) | @as(u64, seq);
    }

    fn loadNextSeq(self: *RequestIdMinter) Error!u48 {
        const bytes = self.seq_kv.get(self.seq_key) catch |err| switch (err) {
            error.NotFound => return 0,
            else => return Error.Kv,
        };
        defer self.allocator.free(bytes);
        return std.fmt.parseInt(u48, bytes, 16) catch 0;
    }

    fn persistReservedUntil(self: *RequestIdMinter) !void {
        var buf: [12]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{x:0>12}", .{self.reserved_until}) catch unreachable;
        self.seq_kv.put(self.seq_key, s) catch return Error.Kv;
    }
};

/// Single per-node in-memory `LogRecord` buffer. The dispatch path
/// appends from every tenant on the node; `flushLogs` drains the
/// whole buffer into one batch per flush window. Thresholds are
/// applied to the combined buffer, not per tenant.
pub const NodeLogBuffer = struct {
    allocator: std.mem.Allocator,
    /// In-memory batch waiting for the next flush. Each record is
    /// fully owned (its slices were allocated by `allocator` when the
    /// caller built the record).
    buffer: std.ArrayList(LogRecord),
    /// Wall-clock at the last `drainRecords` call. Used by `shouldFlush`
    /// for the time-based threshold.
    last_flush_ns: i64,
    /// Guards `buffer` and `last_flush_ns`. Multiple dispatch threads
    /// (one per tenant in the worker pool, in principle) can call
    /// `append` concurrently with the flusher's `drainRecords`. The
    /// critical section is just an ArrayList.append — sub-microsecond.
    mutex: std.Thread.Mutex = .{},

    flush_threshold_records: u32 = 1024,
    flush_threshold_bytes: u32 = 1 * 1024 * 1024,
    flush_interval_ns: i64 = 1 * std.time.ns_per_s,

    pub fn init(allocator: std.mem.Allocator) NodeLogBuffer {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .last_flush_ns = @as(i64, @intCast(std.time.nanoTimestamp())),
        };
    }

    pub fn deinit(self: *NodeLogBuffer) void {
        for (self.buffer.items) |*r| r.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    /// Append a fully-owned LogRecord to the buffer. Caller transfers
    /// ownership of all slices; the buffer frees them on flush or
    /// deinit.
    pub fn append(self: *NodeLogBuffer, record: LogRecord) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.buffer.append(self.allocator, record) catch return Error.OutOfMemory;
    }

    /// Returns true if any flush threshold has been crossed:
    ///   - record count >= flush_threshold_records
    ///   - estimated buffer bytes >= flush_threshold_bytes
    ///   - elapsed since last flush >= flush_interval_ns (when buffer non-empty)
    /// Cheap to call every tick. Takes the mutex briefly.
    pub fn shouldFlush(self: *NodeLogBuffer, now_ns: i64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.buffer.items.len == 0) return false;
        if (self.buffer.items.len >= self.flush_threshold_records) return true;
        if (now_ns - self.last_flush_ns >= self.flush_interval_ns) return true;
        var estimated: usize = 0;
        for (self.buffer.items) |*r| estimated += estimateRecordBytes(r);
        if (estimated >= self.flush_threshold_bytes) return true;
        return false;
    }

    /// Hand the buffered records to the caller. Caller takes ownership
    /// of every record's `[]const u8` fields and the outer slice;
    /// deinit each then `free` the slice with `allocator`. Updates
    /// `last_flush_ns` so the time-based threshold doesn't fire
    /// repeatedly. Returns null when the buffer is empty.
    pub fn drainRecords(self: *NodeLogBuffer, allocator: std.mem.Allocator) Error!?[]LogRecord {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.last_flush_ns = @as(i64, @intCast(std.time.nanoTimestamp()));
        if (self.buffer.items.len == 0) return null;

        const out = allocator.alloc(LogRecord, self.buffer.items.len) catch
            return Error.OutOfMemory;
        @memcpy(out, self.buffer.items);
        // Records' []const u8 fields move into `out`. Clear the
        // buffer without re-freeing them — caller owns now.
        self.buffer.clearRetainingCapacity();
        return out;
    }
};

/// Approximate per-record byte cost used by `shouldFlush`'s byte
/// threshold. The flush path serializes to ndjson, which is roughly
/// 2-3× the raw struct size; the threshold is a soft cap, not exact.
fn estimateRecordBytes(r: *const LogRecord) usize {
    var n: usize = 64; // fixed-width header (request_id, timestamps, status, ...)
    n += r.method.len + r.path.len + r.host.len;
    n += r.console.len + r.exception.len;
    // Inline tape + body payloads ride in the ndjson record as
    // base64. The threshold is a soft cap so we skip the *4/3
    // expansion and just account raw bytes — slightly under-counts
    // but matches the original "approximate" intent.
    n += r.tapes.kv_tape_bytes.len;
    n += r.tapes.module_tree_bytes.len;
    n += r.tapes.request_reads_tape_bytes.len;
    n += r.tapes.request_body_bytes.len;
    n += r.tapes.activation_bytes.len;
    return n;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn buildRecord(
    allocator: std.mem.Allocator,
    request_id: u64,
    method: []const u8,
    path: []const u8,
    status: u16,
    outcome: Outcome,
    console: []const u8,
) !LogRecord {
    return .{
        .tenant_id = try allocator.dupe(u8, "acme"),
        .request_id = request_id,
        .deployment_id = 42,
        .received_ns = 1_000_000_000,
        .duration_ns = 500_000,
        .method = try allocator.dupe(u8, method),
        .path = try allocator.dupe(u8, path),
        .host = try allocator.dupe(u8, "acme.test"),
        .status = status,
        .outcome = outcome,
        .console = try allocator.dupe(u8, console),
        .exception = try allocator.dupe(u8, ""),
    };
}

const TestMinter = struct {
    allocator: std.mem.Allocator,
    tmp_dir: []u8,
    seq_kv: *kv_mod.KvStore,
    minter: RequestIdMinter,

    fn init(allocator: std.mem.Allocator) !TestMinter {
        const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
        const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/rove-log-test-{x}", .{seed});
        errdefer allocator.free(tmp_dir);
        std.fs.cwd().deleteTree(tmp_dir) catch {};
        try std.fs.cwd().makePath(tmp_dir);
        const seq_path = try std.fmt.allocPrintSentinel(allocator, "{s}/seq.db", .{tmp_dir}, 0);
        defer allocator.free(seq_path);
        const seq_kv = try kv_mod.KvStore.open(allocator, seq_path);
        errdefer seq_kv.close();
        const minter = try RequestIdMinter.init(allocator, 7, .{
            .seq_kv = seq_kv,
            .seq_key = "_log/next_request_seq",
        });
        return .{ .allocator = allocator, .tmp_dir = tmp_dir, .seq_kv = seq_kv, .minter = minter };
    }

    fn deinit(self: *TestMinter) void {
        self.minter.deinit();
        self.seq_kv.close();
        std.fs.cwd().deleteTree(self.tmp_dir) catch {};
        self.allocator.free(self.tmp_dir);
    }
};

test "NodeLogBuffer shouldFlush honors record-count threshold" {
    const a = testing.allocator;
    var buf = NodeLogBuffer.init(a);
    defer buf.deinit();
    buf.flush_threshold_records = 3;
    buf.flush_interval_ns = std.math.maxInt(i64); // disable time path

    const now: i64 = 0;
    try testing.expect(!buf.shouldFlush(now));
    try buf.append(try buildRecord(a, 1, "GET", "/", 200, .ok, ""));
    try testing.expect(!buf.shouldFlush(now));
    try buf.append(try buildRecord(a, 2, "GET", "/", 200, .ok, ""));
    try testing.expect(!buf.shouldFlush(now));
    try buf.append(try buildRecord(a, 3, "GET", "/", 200, .ok, ""));
    try testing.expect(buf.shouldFlush(now));
}

test "NodeLogBuffer shouldFlush honors time threshold" {
    const a = testing.allocator;
    var buf = NodeLogBuffer.init(a);
    defer buf.deinit();
    buf.flush_threshold_records = 1000;
    buf.flush_threshold_bytes = std.math.maxInt(u32);
    buf.flush_interval_ns = 1_000_000; // 1 ms
    buf.last_flush_ns = 0;

    try buf.append(try buildRecord(a, 1, "GET", "/", 200, .ok, ""));
    try testing.expect(!buf.shouldFlush(500_000));
    try testing.expect(buf.shouldFlush(1_500_000));
}

test "NodeLogBuffer drainRecords transfers ownership and clears the buffer" {
    const a = testing.allocator;
    var buf = NodeLogBuffer.init(a);
    defer buf.deinit();

    try buf.append(try buildRecord(a, 1, "GET", "/a", 200, .ok, ""));
    try buf.append(try buildRecord(a, 2, "POST", "/b", 503, .fault, "boom\n"));

    const drained = (try buf.drainRecords(a)).?;
    defer {
        for (drained) |*r| r.deinit(a);
        a.free(drained);
    }
    try testing.expectEqual(@as(usize, 2), drained.len);
    try testing.expectEqualStrings("/a", drained[0].path);
    try testing.expectEqualStrings("/b", drained[1].path);
    try testing.expectEqual(@as(usize, 0), buf.buffer.items.len);
    try testing.expectEqual(@as(?[]LogRecord, null), try buf.drainRecords(a));
}

test "RequestIdMinter persists next_request_seq across reopen (chunked)" {
    const a = testing.allocator;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(a, "/tmp/rove-log-persist-{x}", .{seed});
    defer a.free(tmp_dir);
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const seq_path = try std.fmt.allocPrintSentinel(a, "{s}/seq.db", .{tmp_dir}, 0);
    defer a.free(seq_path);

    var first_ids: [3]u64 = undefined;
    {
        const seq_kv = try kv_mod.KvStore.open(a, seq_path);
        defer seq_kv.close();
        var minter = try RequestIdMinter.init(a, 0, .{
            .seq_kv = seq_kv,
            .seq_key = "_log/next_request_seq",
        });
        defer minter.deinit();
        first_ids[0] = try minter.nextRequestId();
        first_ids[1] = try minter.nextRequestId();
        first_ids[2] = try minter.nextRequestId();
    }
    {
        const seq_kv = try kv_mod.KvStore.open(a, seq_path);
        defer seq_kv.close();
        var minter = try RequestIdMinter.init(a, 0, .{
            .seq_kv = seq_kv,
            .seq_key = "_log/next_request_seq",
        });
        defer minter.deinit();
        const next = try minter.nextRequestId();
        // Under chunked reservation: the first nextRequestId call in
        // the previous process persisted `reserved_until = REQUEST_ID_CHUNK`.
        // The reopened minter loads that value and hands out its first
        // id at exactly `REQUEST_ID_CHUNK` — the intervening seqs
        // 3..REQUEST_ID_CHUNK-1 become an intentional sparse gap.
        try testing.expectEqual(@as(u64, REQUEST_ID_CHUNK), next);
        for (first_ids) |prior| try testing.expect(next > prior);
    }
}

test "RequestIdMinter worker_id occupies the upper 16 bits of request_id" {
    const a = testing.allocator;
    var fx = try TestMinter.init(a);
    defer fx.deinit();
    // Override the worker_id by re-initing — fixture defaults to 7.
    fx.minter.deinit();
    fx.minter = try RequestIdMinter.init(a, 0xCAFE, .{
        .seq_kv = fx.seq_kv,
        .seq_key = "_log/next_request_seq",
    });
    const id = try fx.minter.nextRequestId();
    try testing.expectEqual(@as(u64, 0xCAFE), id >> 48);
    try testing.expectEqual(@as(u64, 0), id & 0xFFFFFFFFFFFF);
}

test "LogHeader: serialize + parseLogHeader roundtrip" {
    const header: LogHeader = .{
        .request_id = 0xCAFEBABEDEADBEEF,
        .deployment_id = 1_700_000_000_000_000_000,
        .duration_ns = 123_456_789,
        .status = 201,
        .outcome = .ok,
        .activation = .inbound,
        .method = "POST",
        .path = "/api/users",
        .host = "tenant.rewindjsapp.localhost",
        .correlation_id = "corr-7f1a-9e4b",
    };
    const bytes = try header.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    const parsed = try parseLogHeader(bytes);
    try testing.expectEqual(header.request_id, parsed.request_id);
    try testing.expectEqual(header.deployment_id, parsed.deployment_id);
    try testing.expectEqual(header.duration_ns, parsed.duration_ns);
    try testing.expectEqual(header.status, parsed.status);
    try testing.expectEqual(header.outcome, parsed.outcome);
    try testing.expectEqual(header.activation, parsed.activation);
    try testing.expectEqualStrings(header.method, parsed.method);
    try testing.expectEqualStrings(header.path, parsed.path);
    try testing.expectEqualStrings(header.host, parsed.host);
    try testing.expectEqualStrings(header.correlation_id, parsed.correlation_id);
}

test "LogHeader: empty strings roundtrip" {
    const header: LogHeader = .{
        .request_id = 0,
        .deployment_id = 0,
        .duration_ns = 0,
        .status = 0,
        .outcome = .ok,
        .activation = .inbound,
        .method = "",
        .path = "",
        .host = "",
        .correlation_id = "",
    };
    const bytes = try header.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    const parsed = try parseLogHeader(bytes);
    try testing.expectEqualStrings("", parsed.method);
    try testing.expectEqualStrings("", parsed.path);
    try testing.expectEqualStrings("", parsed.host);
    try testing.expectEqualStrings("", parsed.correlation_id);
}

test "LogHeader: non-default outcome + activation" {
    const header: LogHeader = .{
        .request_id = 1,
        .deployment_id = 2,
        .duration_ns = 3,
        .status = 500,
        .outcome = .handler_error,
        .activation = .fetch_chunk,
        .method = "GET",
        .path = "/",
        .host = "",
        .correlation_id = "",
    };
    const bytes = try header.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    const parsed = try parseLogHeader(bytes);
    try testing.expectEqual(Outcome.handler_error, parsed.outcome);
    try testing.expectEqual(ActivationSource.fetch_chunk, parsed.activation);
}

test "LogHeader: parseLogHeader rejects truncated scalar section" {
    try testing.expectError(LogHeaderParseError.Truncated, parseLogHeader(""));
    var bytes: [10]u8 = undefined;
    @memset(&bytes, 0);
    try testing.expectError(LogHeaderParseError.Truncated, parseLogHeader(&bytes));
}

test "LogHeader: parseLogHeader rejects bad outcome enum" {
    const header: LogHeader = .{
        .request_id = 0,
        .deployment_id = 0,
        .duration_ns = 0,
        .status = 0,
        .outcome = .ok,
        .activation = .inbound,
        .method = "",
        .path = "",
        .host = "",
        .correlation_id = "",
    };
    const bytes = try header.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    const mut = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(mut);
    // Stomp the outcome byte (offset 26) with an out-of-range value.
    mut[26] = 0xFF;
    try testing.expectError(LogHeaderParseError.BadEnum, parseLogHeader(mut));
}

test "LogHeader: parseLogHeader rejects truncated trailing string" {
    const header: LogHeader = .{
        .request_id = 0,
        .deployment_id = 0,
        .duration_ns = 0,
        .status = 0,
        .outcome = .ok,
        .activation = .inbound,
        .method = "GET",
        .path = "/x",
        .host = "h",
        .correlation_id = "c",
    };
    const bytes = try header.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectError(
        LogHeaderParseError.Truncated,
        parseLogHeader(bytes[0 .. bytes.len - 1]),
    );
}
