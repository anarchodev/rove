//! rove-js per-entity components.
//!
//! These types are the principle-compliant replacement for the three
//! entity-keyed side stores (`worker.parked_meta` /
//! `worker.parked_streams_meta` / `worker.pending_stream_meta`) that
//! `~/.claude/memory/rove-library.md` principle #2 forbids. Per the
//! refactor plan (`docs/streaming-handlers-plan.md`), they live as
//! components on the entity's Row; rove's auto-deinit on
//! entity-move / entity-destroy handles cleanup structurally instead
//! of via manual cleanup sites.
//!
//! The migration shipped (Phase 7 fold, 2026-05-24): the side stores
//! are deleted, `raft_pending` is split into siblings
//! (`raft_pending_response` / `_cont` / `_stream`), and these
//! components are the sole structural home for per-entity
//! cont/stream state.

const std = @import("std");
const continuation_mod = @import("bindings/continuation.zig");
const Continuation = continuation_mod.Continuation;

/// Per-chain identity carried by both cont and stream chains. The
/// inbound activation populates it on park; resume activations
/// inherit it via the entity surviving the move (principle #8).
/// Default values are sentinels for "this entity has no chain
/// context yet" — read sites must gate on the entity's collection
/// membership, not on `tenant_id.len > 0`.
pub const ChainContext = struct {
    /// Tenant id the chain is scoped to. Allocator-owned when
    /// `tenant_id.len > 0`; empty slice = uninitialized.
    tenant_id: []u8 = &.{},
    /// Per-chain correlation id. Allocator-owned when non-null.
    correlation_id: ?[]u8 = null,
    /// Deployment id active when the chain opened. Zero ⇒
    /// uninitialized; deployments use the full u64 space so zero
    /// would never be a real value on a populated entity.
    deployment_id: u64 = 0,

    pub fn deinit(allocator: std.mem.Allocator, items: []ChainContext) void {
        for (items) |*item| {
            if (item.tenant_id.len > 0) allocator.free(item.tenant_id);
            if (item.correlation_id) |c| allocator.free(c);
            item.* = .{};
        }
    }
};

/// Cont-trampoline state. Populated only on entities that returned
/// `__rove_next(...)` and are awaiting a wake (either the bound
/// `http.send` completion or the §6.4 deadline). Read sites gate
/// on the entity being in `parked_continuations` /
/// `raft_pending_cont` (Phase 5), not on `cont != null` — the
/// optional just covers "this Row carries the component but THIS
/// entity isn't in a cont chain."
pub const ContDescriptor = struct {
    /// The handler's `__rove_next` descriptor. Null when the
    /// entity has no cont attached.
    cont: ?Continuation = null,
    /// §6.4 mandatory-timeout deadline (absolute monotonic ns).
    /// Zero when `cont == null`.
    deadline_ns: i64 = 0,
    /// §6.4 binding: the single `_send/owed/{id}` this hop wrote
    /// (allocator-owned). null = deadline-only resume (no send
    /// bound, or >1 sends written — ambiguous, no implicit pick).
    bound_schedule_id: ?[]u8 = null,

    pub fn deinit(allocator: std.mem.Allocator, items: []ContDescriptor) void {
        for (items) |*item| {
            if (item.cont) |*c| c.deinit(allocator);
            if (item.bound_schedule_id) |s| allocator.free(s);
            item.* = .{};
        }
    }
};

/// Stream-chain identity + per-activation state. Populated on
/// entities holding an active `__rove_stream(...)` chain — during the
/// raft park (`raft_pending_stream`) and then across h2's stream
/// pipeline (`stream_response_in` → `stream_data_out`). The module
/// path stays fixed across the chain's lifetime; `ctx_json` is
/// replaced on every `__rove_stream(...)` return.
pub const StreamChain = struct {
    /// Module path the resume engine invokes on each wake.
    /// Allocator-owned when set; empty slice = inactive.
    module_path: []u8 = &.{},
    /// Customer ctx JSON, threaded forward into the next activation's
    /// synthesized request body. Allocator-owned.
    ctx_json: []u8 = &.{},
    /// Number of activations the chain has had so far (inbound + every
    /// wake-driven resume). Hard-capped to `MAX_STREAM_ACTIVATIONS`.
    activation_count: u32 = 0,

    pub fn deinit(allocator: std.mem.Allocator, items: []StreamChain) void {
        for (items) |*item| {
            if (item.module_path.len > 0) allocator.free(item.module_path);
            if (item.ctx_json.len > 0) allocator.free(item.ctx_json);
            item.* = .{};
        }
    }
};

/// Chunk queue waiting to be framed onto the held socket. Drained
/// one entry per worker tick by `serviceParkedStreams`; populated
/// by `__rove_stream(...)` returns. Default empty list is the
/// "no chunks queued" state; nothing distinguishes it from "no
/// stream attached" — that's the collection's job.
///
/// `stream.write` output is LOSSLESS — the queue NEVER silently drops a
/// chunk. Two caps with different jobs:
///   - SOFT cap (`QUEUE_SOFT_CAP`): the backpressure high-water. A producer
///     that can be paced — a bound fetch feeding the stream — is NOT dispatched
///     while the queue is at/over this (the spool holds the backlog; see
///     `dispatchSpoolHead`). So a fast upstream never outruns a slow client.
///   - HARD cap (`QUEUE_HARD_CAP`): a backstop for the one case that can't be
///     paced — a single synchronous activation that `stream.write`s more than
///     this in one go. `tryAppend` then returns `error.StreamBufferFull` (the
///     binding surfaces it as a loud JS throw: "paginate with next()"). Never a
///     silent drop.
pub const StreamChunks = struct {
    queue: std.ArrayListUnmanaged([]u8) = .empty,
    /// Running sum of `queue.items[i].len` — kept in lockstep with
    /// the queue so `tryAppend`/`atSoftCap` are O(1).
    queue_bytes: usize = 0,

    /// Backpressure high-water. A bound-fetch producer pauses (leaves its
    /// chunk spooled) while `queue_bytes >= QUEUE_SOFT_CAP`. Sized at one max
    /// fetch chunk so one chunk is in flight at a time, drained one/tick.
    pub const QUEUE_SOFT_CAP: usize = 256 * 1024;

    /// Hard ceiling for a single un-paceable synchronous activation's writes.
    /// `tryAppend` past this errors (loud) rather than dropping or buffering
    /// unboundedly. Generous so normal handlers never hit it.
    pub const QUEUE_HARD_CAP: usize = 4 * 1024 * 1024;

    /// True when the queue is at/over the backpressure high-water — the
    /// producer-pacing gate reads this to decide whether to feed more.
    pub fn atSoftCap(self: *const StreamChunks) bool {
        return self.queue_bytes >= QUEUE_SOFT_CAP;
    }

    /// Enqueue `chunk` (ownership transferred on success). LOSSLESS: never
    /// drops. Past the HARD cap it frees `chunk` and returns
    /// `error.StreamBufferFull` (a single synchronous activation overran the
    /// buffer — the binding throws so the customer sees it). Allocator failure
    /// surfaces as `error.OutOfMemory`. The SOFT cap is enforced upstream by
    /// the producer-pacing gate, not here.
    pub fn tryAppend(self: *StreamChunks, allocator: std.mem.Allocator, chunk: []u8) error{ OutOfMemory, StreamBufferFull }!void {
        if (self.queue_bytes + chunk.len > QUEUE_HARD_CAP) {
            allocator.free(chunk);
            return error.StreamBufferFull;
        }
        self.queue.append(allocator, chunk) catch |e| {
            allocator.free(chunk);
            return e;
        };
        self.queue_bytes += chunk.len;
    }

    /// Pop the oldest queued chunk + decrement `queue_bytes`.
    /// Caller takes ownership. Returns null when the queue is
    /// empty (caller decides what that means — drain-then-close
    /// fires here).
    pub fn popOldest(self: *StreamChunks) ?[]u8 {
        if (self.queue.items.len == 0) return null;
        const chunk = self.queue.orderedRemove(0);
        self.queue_bytes -= chunk.len;
        return chunk;
    }

    pub fn deinit(allocator: std.mem.Allocator, items: []StreamChunks) void {
        for (items) |*item| {
            for (item.queue.items) |chunk| allocator.free(chunk);
            item.queue.deinit(allocator);
            item.* = .{};
        }
    }
};

/// Wake registrations + outstanding matches for a held stream. The
/// `kv_prefixes` slice is rewritten on every `__rove_stream(...)`
/// return; `pending_wakes` is the §9.4 accumulator (ring of
/// `PENDING_WAKES_CAP`, fan-in of kv + timer events; `lost_oldest`
/// exposed to the handler as rate-limit backpressure) populated by
/// `drainKvWakeInbox` (kv matches) and the per-tick timer-due
/// detection in `serviceParkedStreams` (timer fires).
/// `next_wake_ns == maxInt(i64)` is the "no timer pending"
/// sentinel; we never compare against it as an active deadline.
pub const StreamWakes = struct {
    interval_ms: i64 = 0,
    next_wake_ns: i64 = std.math.maxInt(i64),
    kv_prefixes: [][]u8 = &.{},
    pending_wakes: PendingWakes = .{},
    /// Handler-surface Phase 1 (`on.kv`): the §8.4 watch baseline — the
    /// kvexp write-clock version the arming handler read at. A kv-write
    /// event fires this watch only when its `writeVersion` is strictly
    /// greater (i.e. the write landed after the read view), so a watch
    /// never fires for state the handler already saw. 0 = unanchored
    /// (the pre-`on.kv` stream path, which matches on any post-arm event).
    read_version: u64 = 0,
    /// Handler-surface Phase 1 (`on.*`): the export a wake routes to —
    /// `"module.method"` or a bare `"method"`, or null → the default
    /// `onWake` (the generic "edge wake — go look" export). Allocator-
    /// owned; set from the last `on.*` registration's `{to}` selector.
    wake_to: ?[]u8 = null,

    pub fn deinit(allocator: std.mem.Allocator, items: []StreamWakes) void {
        for (items) |*item| {
            for (item.kv_prefixes) |p| allocator.free(p);
            if (item.kv_prefixes.len > 0) allocator.free(item.kv_prefixes);
            if (item.wake_to) |t| allocator.free(t);
            item.pending_wakes.deinit(allocator);
            item.* = .{};
        }
    }
};

/// One `http.fetch` upstream event awaiting handler dispatch on a
/// local worker. Phase 5 PR-1 collapsed today's three-variant shape
/// (`chunk` / `end` / `pipe_done`) into a single chunk-with-`final`
/// shape: every event is a chunk; the LAST event in a fetch sets
/// `final = true` and carries the terminal fields (status / ok /
/// body_truncated). `on_done` and `pipe_to` retired in the same PR.
///
/// One activation kind: `fetch_chunk`. For non-streaming fetches
/// (`stream: false`) exactly one event fires (with `final: true`,
/// up to `max_response_chunk_bytes` of body). For streaming
/// (`stream: true`) one event per upstream writeback fires, last
/// one with `final: true`. Transport errors / cap aborts / empty
/// responses still fire one `final: true` event (with empty
/// `bytes`) so the handler always gets a callback.
///
/// `FetchPool` builds these on its libcurl thread; events route
/// via `enqueueFetchEventForTenant` → the destination worker's
/// `effect.MsgInbox`. The component shape mirrors `WakeEntry` —
/// flat fields, SoA-friendly, owned slices freed structurally on
/// entity destroy via rove's component-deinit.
pub const UpstreamFetchEvent = struct {
    /// The originating `http.fetch`-returned id, allocator-owned
    /// when non-empty. Shared across every event for one fetch so
    /// the handler can correlate.
    fetch_id: []u8 = &.{},

    /// Owning tenant's instance id. The worker serves many tenants;
    /// this names which one's deployment the `on_chunk` module
    /// resolves against. Carried forward from `PendingFetch
    /// .tenant_id` by the `FetchPool`. Allocator-owned.
    tenant_id: []u8 = &.{},

    /// Chain ctx threaded forward from the originating `http.fetch`
    /// (the `ctx` blob passed to the call). Allocator-owned JSON.
    /// Empty by default; the handler reads it as `request.ctx`.
    ctx_json: []u8 = &.{},

    /// Module path of the `on_chunk` handler — dispatched once per
    /// event. Allocator-owned. The binding rejects a fetch with no
    /// `on_chunk` (no fire-and-forget surface in PR-1; can be
    /// re-added cleanly as `on_chunk: null` + capture-and-tape if
    /// concrete demand appears).
    on_chunk_module: []u8 = &.{},

    /// 0-based chunk index. `seq == 0` is the first/only event;
    /// streaming continuations are 1, 2, …. Surfaces as
    /// `request.activation.seq`.
    seq: u32 = 0,
    /// Cumulative bytes received BEFORE this chunk. Surfaces as
    /// `request.activation.byteOffset`.
    byte_offset: u64 = 0,
    /// The chunk payload. Allocator-owned; surfaces as
    /// `request.activation.bytes` (Uint8Array view, runtime owns
    /// the buffer; handler must copy if retaining). May be empty
    /// on a transport-error / empty-body final event.
    bytes: []u8 = &.{},
    /// On `seq == 0` only: parsed response-header object as a
    /// JSON-encoded string `{"name":"value", …}`. Allocator-owned
    /// when non-null. The binding decodes it back into a JS object
    /// on `request.activation.headers`.
    fetch_headers: ?[]u8 = null,

    /// True on the LAST event for this fetch (one event for non-
    /// streaming; final streaming event otherwise). The terminal
    /// fields below are valid only when `final == true`. Surfaces
    /// as `request.activation.final`.
    final: bool = false,
    /// `final` only: upstream HTTP status (0 on transport error).
    /// Surfaces as `request.activation.status`.
    terminal_status: u16 = 0,
    /// `final` only: transport-only success flag (libcurl returned
    /// cleanly AND any cap-based abort was deliberate, not an
    /// error). `ok: true, status: 503` is "transport worked, server
    /// said no" — the JS shim decides retry policy. Surfaces as
    /// `request.activation.ok`.
    terminal_ok: bool = false,
    /// `final` only: true iff the response body exceeded the cap
    /// (`max_response_chunk_bytes` when `stream: false`, or
    /// `max_total_response_bytes` when `stream: true`) and the
    /// runtime aborted the rest. Surfaces as
    /// `request.activation.body_truncated`.
    body_truncated: bool = false,

    /// True iff the originating fetch was issued with `stream: true`
    /// (`PendingFetch.stream`). Carried so the bound-fetch resume can
    /// pick the conventional named export per `docs/handler-shape.md`
    /// §3: a non-streaming fetch (`stream == false`, one `final` event
    /// with the whole body) lands in `onFetchResult`; a streaming
    /// fetch's intermediate chunks (`final == false`) land in
    /// `onFetchChunk` and its terminal event (`final == true`) lands
    /// in `onFetchDone`. The customer's `{to}` override (`name`)
    /// supersedes this for every event of the fetch. Plain bool — no
    /// allocation, so `deinitItem` needs no change.
    stream: bool = false,

    /// `docs/streaming-model.md` §7 item 1 + `docs/handler-shape.md`
    /// §5.5: this event belongs to a bound fetch
    /// (`http.fetch({bind: true})`). The dispatcher routes bound
    /// events into the held chain's `onFetchChunk` resume instead
    /// of firing a separate `fireFetchEventActivation` chain.
    /// Carried from `PendingFetch.bind` by the FetchEngine.
    bind: bool = false,
    /// `docs/cross-worker-held-state-plan.md` Phase 2B: webhook.send
    /// shim's send_id. Set when the fetch was issued by
    /// `webhook.send` (via the `bound_send_id` option); empty
    /// otherwise. The chunk router consults
    /// `bound_send_owners[bound_send_id]` to route the callback
    /// to the cont's owning worker. Allocator-owned dupe; freed
    /// in `deinitItem`.
    bound_send_id: []u8 = &.{},
    /// Customer-facing `name:` override (see `PendingFetch.name`).
    /// Empty → resume dispatches to `onFetchChunk`; non-empty →
    /// resume dispatches to the supplied identifier. Allocator-
    /// owned dupe; freed in `deinitItem`.
    name: []u8 = &.{},

    /// `docs/chunk-spool-plan.md` Phase 1: for bound-fetch chunks,
    /// the producer (`fetch_engine`) writes the chunk bytes to the
    /// process-global blob coordinator at upstream rate — durable
    /// ground truth decoupled from the held chain's raft cadence —
    /// and stamps the resulting per-worker submission seq here.
    /// `coord_seq == 0` with `coord_worker_id == 0` and a non-empty
    /// `bytes` means "not submitted" (unbound chunk, coord absent, or
    /// owner unresolved); the consumer falls back to inline `bytes`.
    /// Phase 1 consumers IGNORE these fields entirely — `bytes`
    /// remains the source of truth. Phases 2-3 introduce the spool
    /// that reads bytes back via `coord.bodyRef(coord_worker_id,
    /// coord_seq)` once the chunk is durable. Plain integers — no
    /// allocation, so `deinitItem` needs no change.
    coord_seq: u64 = 0,
    /// Companion to `coord_seq`: which coordinator per-worker queue
    /// the bytes were submitted under (the bound-fetch owner worker's
    /// id). The consumer polls `coord.durableSeq(coord_worker_id)`
    /// against `coord_seq` to gate the spool head. See `coord_seq`.
    coord_worker_id: u8 = 0,
    /// True iff the producer successfully submitted this chunk's bytes
    /// to the coordinator (so `coord_seq`/`coord_worker_id` are
    /// meaningful and the bytes can be read back via
    /// `coord.readBody`). Needed because `coord_seq == 0` /
    /// `coord_worker_id == 0` are both legitimate values — there is no
    /// in-band sentinel. The Phase 3 spool only evicts inline bytes
    /// for chunks where this is set; un-submitted chunks (coord
    /// absent, owner unresolved) stay inline.
    coord_submitted: bool = false,

    pub fn deinit(allocator: std.mem.Allocator, items: []UpstreamFetchEvent) void {
        for (items) |*item| deinitItem(item, allocator);
    }

    /// `docs/handler-shape.md` §3: resolve the named export this event
    /// dispatches to on the bound (connection-scoped) `on.fetch`
    /// resume. An explicit `{to}` (`name`) overrides for every event of
    /// the fetch; otherwise the export is chosen by the event shape:
    ///   - non-streaming (`stream == false`) — one `final` event with
    ///     the whole body → `onFetchResult`.
    ///   - streaming intermediate chunk (`final == false`) →
    ///     `onFetchChunk`.
    ///   - streaming terminal (`final == true`) → `onFetchDone`.
    /// A missing conventional export is the fail-loud 404 backstop
    /// (runModule), same as the other named-export kinds.
    pub fn resolvedExport(item: *const UpstreamFetchEvent) []const u8 {
        if (item.name.len > 0) return item.name;
        if (!item.stream) return "onFetchResult";
        if (item.final) return "onFetchDone";
        return "onFetchChunk";
    }

    /// Single-item variant of `deinit` for callers that hold one
    /// event by value (e.g. an `effect.Msg.fetch_chunk` variant
    /// payload after dequeue). Equivalent to `deinit(allocator,
    /// (item)[0..1])` but spelled where Zig's single-item slicing
    /// is awkward.
    pub fn deinitItem(item: *UpstreamFetchEvent, allocator: std.mem.Allocator) void {
        if (item.fetch_id.len > 0) allocator.free(item.fetch_id);
        if (item.tenant_id.len > 0) allocator.free(item.tenant_id);
        if (item.ctx_json.len > 0) allocator.free(item.ctx_json);
        if (item.on_chunk_module.len > 0) allocator.free(item.on_chunk_module);
        if (item.bytes.len > 0) allocator.free(item.bytes);
        if (item.fetch_headers) |h| allocator.free(h);
        if (item.bound_send_id.len > 0) allocator.free(item.bound_send_id);
        if (item.name.len > 0) allocator.free(item.name);
        item.* = .{};
    }
};

/// Per-chain count of in-flight bound fetches. Incremented at
/// `http.fetch({bind: true})` register time; decremented at the
/// matching `unregisterBoundFetch` site (i.e. either a `final:
/// true` chunk arriving at the dispatch, or the auto-cancel
/// sibling sweep when the chain goes terminal).
///
/// Surfaced to the customer as `request.fetchesPending` on every
/// `onFetchChunk` activation — they branch on it for "is this the
/// last chunk of the last fetch?" logic. Default 0 is the natural
/// "no binds yet" state. Lives on the merged Row so it survives
/// entity moves between parked_continuations → raft_pending_cont →
/// stream_response_in → stream_data_out etc.
pub const BoundFetchCount = struct {
    pending: u32 = 0,

    pub fn deinit(_: std.mem.Allocator, _: []BoundFetchCount) void {}
};

/// Phase 7: replaces the Phase-6 `parked_streams_active` /
/// `parked_streams_draining` map split — the entity stays in h2's
/// `stream_data_out` (h2 owns the chunk-shipping pipeline, so we
/// can't move the entity to a worker-owned sibling collection),
/// and this component encodes "chunks-drain-then-close" instead.
///
/// Caveat (commit message reiterates): this is a bool flag, the
/// strictest reading of rove-library principle #1 would prefer a
/// sibling collection. The architectural constraint (h2 watches
/// its own collections, not the worker's) prevents that without
/// reshaping h2's stream pipeline — out of scope for this
/// refactor. The shift from "side-table map membership"
/// (Phase 6) to "component bool" (Phase 7) is principle-neutral;
/// the real win of this phase is the side-table deletion + the
/// structural deinit (no manual cleanup sites).
pub const StreamDraining = struct {
    is_draining: bool = false,

    pub fn deinit(_: std.mem.Allocator, _: []StreamDraining) void {}
};

/// Ring-buffer capacity for `PendingWakes` (streaming-handlers §9.4 +
/// §11.4 — K=32 starting target). Per-stream constant for now;
/// per-tenant / per-stream configurability hooks are cheap to add
/// later if benches show one stream-class wants a different K.
pub const PENDING_WAKES_CAP: usize = 32;

/// One entry in the per-stream wake accumulator. The tag picks
/// which payload field is meaningful; `kv_key` is allocator-owned
/// when `tag == .kv`. Both kv and timer wakes go through the same
/// ring so the handler sees them in temporal order on each
/// activation (`streaming-handlers-plan.md` §9.4).
pub const WakeEntry = struct {
    tag: Tag = .timer,
    /// Set when `tag == .kv`; allocator-owned. Empty slice when
    /// `tag == .timer` (the default leaves `kv_key.len == 0` so a
    /// drain consumer can branch on `entry.tag` without checking
    /// for sentinel keys).
    kv_key: []u8 = &.{},
    /// Set when `tag == .kv`. `'p'` (put) or `'d'` (delete). Zero
    /// when `tag == .timer`.
    kv_op: u8 = 0,
    /// Set on every entry — monotonic ns the wake matched. For
    /// timers this is the scheduled fire time; for kv-writes it's
    /// the apply-thread observe time. Surfaces to the handler as
    /// `wakes[i].firedAt` so it can order / dedupe across kinds.
    fired_at_ns: i64 = 0,

    pub const Tag = enum(u8) { kv, timer };

    /// Free owned slices. Safe to call on a default-init entry
    /// (`kv_key.len == 0` short-circuits).
    pub fn deinit(self: *WakeEntry, allocator: std.mem.Allocator) void {
        if (self.tag == .kv and self.kv_key.len > 0) {
            allocator.free(self.kv_key);
        }
        self.* = .{};
    }
};

/// The §9.4 per-stream wake accumulator. Bounded ring of
/// `PENDING_WAKES_CAP` entries; pushed-to on every kv-prefix match
/// (apply-thread fan-out) and every timer fire while the handler
/// is running or queued; drained as one batch by `resumeStream`
/// when the cell is free.
///
/// On ring-full, the oldest entry is dropped (its `kv_key` freed)
/// and `lost_oldest` is incremented — the rate-limit IS the ring,
/// and `lost_oldest > 0` is the signal the handler reads on the
/// next activation ("re-snapshot kv state; you missed some
/// writes"). Wraps on u32 overflow which is fine for a counter
/// that resets to 0 on every drain.
///
/// Default-init is the "empty ring" state — `len == 0`,
/// `lost_oldest == 0`, all entries inert. Safe to leave on every
/// `StreamWakes` even when the stream never uses the accumulator
/// (e.g., timer-only streams pay one extra ~1KB SoA slot).
pub const PendingWakes = struct {
    /// Ring storage. Entries between `head` and `head+len` (mod
    /// CAP) are valid; everything else is the default `.{}`.
    entries: [PENDING_WAKES_CAP]WakeEntry = [_]WakeEntry{.{}} ** PENDING_WAKES_CAP,
    /// Index of the oldest valid entry.
    head: u8 = 0,
    /// Number of valid entries currently in the ring (0..=CAP).
    len: u8 = 0,
    /// Cumulative count of entries dropped to make room since the
    /// last drain. Reset to 0 by `drainInto`. Wraps on u32
    /// overflow (saturating not needed — drain frequency caps the
    /// running total).
    lost_oldest: u32 = 0,

    /// Push an entry. On full ring, drop the oldest (freeing its
    /// `kv_key`) + bump `lost_oldest`. Takes ownership of any
    /// allocator-owned fields on `entry`.
    pub fn push(self: *PendingWakes, allocator: std.mem.Allocator, entry: WakeEntry) void {
        if (self.len == PENDING_WAKES_CAP) {
            self.entries[self.head].deinit(allocator);
            self.head = @intCast((@as(usize, self.head) + 1) % PENDING_WAKES_CAP);
            self.lost_oldest +%= 1;
        } else {
            self.len += 1;
        }
        const tail = @as(usize, self.head) + self.len - 1;
        self.entries[tail % PENDING_WAKES_CAP] = entry;
    }

    /// Drain all valid entries into an allocator-owned slice + the
    /// `lost_oldest` snapshot. Resets the ring to empty + clears
    /// `lost_oldest`. Caller owns the returned slice and every
    /// entry's `kv_key`; on success the ring no longer references
    /// them. Returns an empty slice when `len == 0` (still useful
    /// for the `lost_oldest` snapshot — a ring that overflowed
    /// completely and then was drained-but-empty still wants to
    /// report the loss).
    pub fn drainInto(
        self: *PendingWakes,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}!struct { wakes: []WakeEntry, lost_oldest: u32 } {
        const lost = self.lost_oldest;
        self.lost_oldest = 0;
        if (self.len == 0) {
            return .{ .wakes = &.{}, .lost_oldest = lost };
        }
        const out = try allocator.alloc(WakeEntry, self.len);
        var idx: usize = self.head;
        for (out) |*slot| {
            slot.* = self.entries[idx];
            self.entries[idx] = .{}; // ownership moved; clear retained ref
            idx = (idx + 1) % PENDING_WAKES_CAP;
        }
        self.head = 0;
        self.len = 0;
        return .{ .wakes = out, .lost_oldest = lost };
    }

    /// Free every retained entry. Called by `StreamWakes.deinit`.
    pub fn deinit(self: *PendingWakes, allocator: std.mem.Allocator) void {
        var idx: usize = self.head;
        var rem: u8 = self.len;
        while (rem > 0) : (rem -= 1) {
            self.entries[idx].deinit(allocator);
            idx = (idx + 1) % PENDING_WAKES_CAP;
        }
        self.head = 0;
        self.len = 0;
        self.lost_oldest = 0;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "ChainContext default-init is benign + deinit is no-op" {
    var items = [_]ChainContext{ .{}, .{}, .{} };
    ChainContext.deinit(testing.allocator, &items);
    try testing.expectEqualStrings("", items[0].tenant_id);
    try testing.expectEqual(@as(?[]u8, null), items[0].correlation_id);
    try testing.expectEqual(@as(u64, 0), items[0].deployment_id);
}

test "ChainContext deinit frees populated entry" {
    var items = [_]ChainContext{.{
        .tenant_id = try testing.allocator.dupe(u8, "acme"),
        .correlation_id = try testing.allocator.dupe(u8, "0000000000000001"),
        .deployment_id = 12345,
    }};
    ChainContext.deinit(testing.allocator, &items);
    try testing.expectEqualStrings("", items[0].tenant_id);
    try testing.expectEqual(@as(?[]u8, null), items[0].correlation_id);
    try testing.expectEqual(@as(u64, 0), items[0].deployment_id);
}

test "ContDescriptor default-init is benign + deinit is no-op" {
    var items = [_]ContDescriptor{ .{}, .{} };
    ContDescriptor.deinit(testing.allocator, &items);
    try testing.expectEqual(@as(?Continuation, null), items[0].cont);
}

test "ContDescriptor deinit frees the embedded Continuation + bound_schedule_id" {
    var items = [_]ContDescriptor{.{
        .cont = .{
            .path = try testing.allocator.dupe(u8, "feed"),
            .fn_name = null,
            .ctx_json = try testing.allocator.dupe(u8, "{}"),
        },
        .deadline_ns = 1_000_000_000,
        .bound_schedule_id = try testing.allocator.dupe(u8, "send-123"),
    }};
    ContDescriptor.deinit(testing.allocator, &items);
    try testing.expectEqual(@as(?Continuation, null), items[0].cont);
    try testing.expectEqual(@as(?[]u8, null), items[0].bound_schedule_id);
}

test "StreamChain deinit frees module_path + ctx_json" {
    var items = [_]StreamChain{.{
        .module_path = try testing.allocator.dupe(u8, "feed"),
        .ctx_json = try testing.allocator.dupe(u8, "{\"n\":3}"),
        .activation_count = 5,
    }};
    StreamChain.deinit(testing.allocator, &items);
    try testing.expectEqualStrings("", items[0].module_path);
    try testing.expectEqualStrings("", items[0].ctx_json);
}

test "StreamChunks deinit drains + frees every queued chunk" {
    const a = testing.allocator;
    var items = [_]StreamChunks{.{ .queue = .empty }};
    try items[0].queue.append(a, try a.dupe(u8, "frame1"));
    try items[0].queue.append(a, try a.dupe(u8, "frame2"));
    StreamChunks.deinit(a, &items);
    try testing.expectEqual(@as(usize, 0), items[0].queue.items.len);
}

test "StreamChunks.tryAppend tracks bytes; popOldest reverses (Gap 2.2 Phase H)" {
    const a = testing.allocator;
    var sc: StreamChunks = .{};
    defer StreamChunks.deinit(a, (&sc)[0..1]);

    try sc.tryAppend(a, try a.dupe(u8, "abc"));
    try sc.tryAppend(a, try a.dupe(u8, "defghij"));
    try testing.expectEqual(@as(usize, 10), sc.queue_bytes);
    try testing.expectEqual(@as(usize, 2), sc.queue.items.len);

    const c1 = sc.popOldest().?;
    defer a.free(c1);
    try testing.expectEqualStrings("abc", c1);
    try testing.expectEqual(@as(usize, 7), sc.queue_bytes);

    const c2 = sc.popOldest().?;
    defer a.free(c2);
    try testing.expectEqualStrings("defghij", c2);
    try testing.expectEqual(@as(usize, 0), sc.queue_bytes);

    try testing.expectEqual(@as(?[]u8, null), sc.popOldest());
}

test "StreamChunks.tryAppend errors (lossless, no drop) on HARD cap overflow" {
    const a = testing.allocator;
    var sc: StreamChunks = .{};
    defer StreamChunks.deinit(a, (&sc)[0..1]);

    // Fill ~most of the HARD cap with one big chunk.
    const big_len: usize = StreamChunks.QUEUE_HARD_CAP - 10;
    const big = try a.alloc(u8, big_len);
    @memset(big, 'X');
    try sc.tryAppend(a, big);

    // Small chunk that fits — succeeds.
    try sc.tryAppend(a, try a.dupe(u8, "fits"));

    // A chunk that would exceed the HARD cap — ERRORS (never silently dropped).
    // tryAppend frees the chunk on error, so no leak.
    const overflow = try a.alloc(u8, 100);
    @memset(overflow, 'Y');
    try testing.expectError(error.StreamBufferFull, sc.tryAppend(a, overflow));
    // Queue unchanged by the rejected append.
    try testing.expectEqual(@as(usize, big_len + 4), sc.queue_bytes);
    try testing.expectEqual(@as(usize, 2), sc.queue.items.len);
}

test "StreamChunks.atSoftCap reflects the backpressure high-water" {
    const a = testing.allocator;
    var sc: StreamChunks = .{};
    defer StreamChunks.deinit(a, (&sc)[0..1]);

    try testing.expect(!sc.atSoftCap());
    const chunk = try a.alloc(u8, StreamChunks.QUEUE_SOFT_CAP);
    @memset(chunk, 'Z');
    try sc.tryAppend(a, chunk);
    try testing.expect(sc.atSoftCap()); // at the high-water → producer pauses
}

test "StreamWakes deinit frees kv_prefixes spine + entries" {
    const a = testing.allocator;
    const prefixes = try a.alloc([]u8, 2);
    prefixes[0] = try a.dupe(u8, "orders/");
    prefixes[1] = try a.dupe(u8, "alerts/");
    var items = [_]StreamWakes{.{
        .interval_ms = 200,
        .next_wake_ns = 1_500_000_000,
        .kv_prefixes = prefixes,
    }};
    StreamWakes.deinit(a, &items);
    try testing.expectEqual(@as(usize, 0), items[0].kv_prefixes.len);
}

test "StreamWakes deinit drains the §9.4 PendingWakes ring (Gap 2.2 Phase A)" {
    const a = testing.allocator;
    var items = [_]StreamWakes{.{}};
    items[0].pending_wakes.push(a, .{
        .tag = .kv,
        .kv_key = try a.dupe(u8, "orders/u/12"),
        .kv_op = 'p',
        .fired_at_ns = 100,
    });
    items[0].pending_wakes.push(a, .{
        .tag = .timer,
        .fired_at_ns = 200,
    });
    StreamWakes.deinit(a, &items);
    try testing.expectEqual(@as(u8, 0), items[0].pending_wakes.len);
}

test "PendingWakes push/drain preserves temporal order" {
    const a = testing.allocator;
    var ring: PendingWakes = .{};
    defer ring.deinit(a);

    ring.push(a, .{ .tag = .kv, .kv_key = try a.dupe(u8, "k1"), .kv_op = 'p', .fired_at_ns = 1 });
    ring.push(a, .{ .tag = .timer, .fired_at_ns = 2 });
    ring.push(a, .{ .tag = .kv, .kv_key = try a.dupe(u8, "k2"), .kv_op = 'd', .fired_at_ns = 3 });

    const drained = try ring.drainInto(a);
    defer {
        for (drained.wakes) |*w| w.deinit(a);
        a.free(drained.wakes);
    }
    try testing.expectEqual(@as(usize, 3), drained.wakes.len);
    try testing.expectEqual(@as(u32, 0), drained.lost_oldest);
    try testing.expectEqual(WakeEntry.Tag.kv, drained.wakes[0].tag);
    try testing.expectEqualStrings("k1", drained.wakes[0].kv_key);
    try testing.expectEqual(WakeEntry.Tag.timer, drained.wakes[1].tag);
    try testing.expectEqual(@as(i64, 2), drained.wakes[1].fired_at_ns);
    try testing.expectEqual(WakeEntry.Tag.kv, drained.wakes[2].tag);
    try testing.expectEqualStrings("k2", drained.wakes[2].kv_key);
    try testing.expectEqual(@as(u8, 'd'), drained.wakes[2].kv_op);

    // Ring is empty after drain.
    try testing.expectEqual(@as(u8, 0), ring.len);
    try testing.expectEqual(@as(u32, 0), ring.lost_oldest);
}

test "PendingWakes drops oldest on overflow + counts lost_oldest" {
    const a = testing.allocator;
    var ring: PendingWakes = .{};
    defer ring.deinit(a);

    // Fill ring + push 5 extra; CAP+5 total → oldest 5 dropped.
    var i: usize = 0;
    while (i < PENDING_WAKES_CAP + 5) : (i += 1) {
        const key = try std.fmt.allocPrint(a, "k{d}", .{i});
        ring.push(a, .{ .tag = .kv, .kv_key = key, .kv_op = 'p', .fired_at_ns = @intCast(i) });
    }
    try testing.expectEqual(@as(u8, @intCast(PENDING_WAKES_CAP)), ring.len);
    try testing.expectEqual(@as(u32, 5), ring.lost_oldest);

    const drained = try ring.drainInto(a);
    defer {
        for (drained.wakes) |*w| w.deinit(a);
        a.free(drained.wakes);
    }
    // Oldest surviving entry is k5 (k0..k4 were dropped).
    try testing.expectEqualStrings("k5", drained.wakes[0].kv_key);
    try testing.expectEqual(@as(i64, 5), drained.wakes[0].fired_at_ns);
    // Newest entry is k{CAP+4}.
    var buf: [16]u8 = undefined;
    const expected_last = try std.fmt.bufPrint(&buf, "k{d}", .{PENDING_WAKES_CAP + 4});
    try testing.expectEqualStrings(expected_last, drained.wakes[drained.wakes.len - 1].kv_key);
    try testing.expectEqual(@as(u32, 5), drained.lost_oldest);
}

test "PendingWakes drainInto on empty ring returns empty slice + lost_oldest snapshot" {
    const a = testing.allocator;
    var ring: PendingWakes = .{};
    defer ring.deinit(a);

    // Push a single entry, drain it, then drain again on empty.
    ring.push(a, .{ .tag = .timer, .fired_at_ns = 42 });
    const first = try ring.drainInto(a);
    a.free(first.wakes);

    const second = try ring.drainInto(a);
    try testing.expectEqual(@as(usize, 0), second.wakes.len);
    try testing.expectEqual(@as(u32, 0), second.lost_oldest);
}

test "WakeEntry default-init has empty kv_key + deinit is safe" {
    const a = testing.allocator;
    var entry: WakeEntry = .{};
    entry.deinit(a);
    try testing.expectEqual(@as(usize, 0), entry.kv_key.len);
}

test "UpstreamFetchEvent default-init + deinit is benign" {
    const a = testing.allocator;
    var items = [_]UpstreamFetchEvent{ .{}, .{} };
    UpstreamFetchEvent.deinit(a, &items);
    try testing.expectEqual(@as(usize, 0), items[0].fetch_id.len);
    try testing.expectEqual(@as(usize, 0), items[0].bytes.len);
}

test "UpstreamFetchEvent.deinit frees intermediate chunk slices" {
    const a = testing.allocator;
    var items = [_]UpstreamFetchEvent{.{
        .fetch_id = try a.dupe(u8, "send-abc-123"),
        .ctx_json = try a.dupe(u8, "{\"n\":3}"),
        .seq = 5,
        .byte_offset = 4096,
        .bytes = try a.dupe(u8, "data: hello\n\n"),
        .fetch_headers = try a.dupe(u8, "{\"content-type\":\"text/event-stream\"}"),
        .final = false,
    }};
    UpstreamFetchEvent.deinit(a, &items);
    try testing.expectEqual(@as(usize, 0), items[0].fetch_id.len);
    try testing.expectEqual(@as(usize, 0), items[0].bytes.len);
    try testing.expectEqual(@as(?[]u8, null), items[0].fetch_headers);
}

test "UpstreamFetchEvent.deinit frees final-event slices" {
    const a = testing.allocator;
    var items = [_]UpstreamFetchEvent{.{
        .fetch_id = try a.dupe(u8, "send-abc-123"),
        .ctx_json = try a.dupe(u8, "{\"final\":true}"),
        .seq = 1,
        .byte_offset = 4096,
        .final = true,
        .terminal_status = 200,
        .terminal_ok = true,
        .body_truncated = false,
    }};
    UpstreamFetchEvent.deinit(a, &items);
    try testing.expectEqual(@as(usize, 0), items[0].fetch_id.len);
}

test "UpstreamFetchEvent.deinit frees transport-error final event (empty bytes)" {
    const a = testing.allocator;
    var items = [_]UpstreamFetchEvent{.{
        .fetch_id = try a.dupe(u8, "send-xyz-789"),
        .seq = 0,
        .final = true,
        .terminal_status = 0,
        .terminal_ok = false,
    }};
    UpstreamFetchEvent.deinit(a, &items);
    try testing.expectEqual(@as(usize, 0), items[0].fetch_id.len);
}
