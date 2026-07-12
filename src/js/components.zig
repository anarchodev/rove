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
    /// §6.4 binding: the single `_send/owed/{id}` the chain's most
    /// recent WRITING hop wrote (allocator-owned). null = deadline-only
    /// resume (no send bound, or >1 sends written — ambiguous, no
    /// implicit pick). PERSISTS across read-only reparks: a hop that
    /// wrote nothing fired no send, and the chain may still be awaiting
    /// an earlier hop's owed send — its callback must keep resuming
    /// this park. Only a writing repark rewrites it.
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

/// Wake registrations + fired state for a held stream. The
/// `kv_prefixes` arm slice is rewritten on every `__rove_stream(...)`
/// return (a rearm starts unfired by construction). Fired state rides
/// ON the arm (`KvArm.fired_at_ns`) plus the scalar `timer_fired_ns`
/// — issue #8: the wake contract is "which armed prefix fired", never
/// the matched keys, so there is no per-match accumulator, no ring
/// cap, and no overflow signal. `drainKvWakeInbox` marks kv arms
/// fired; the per-tick timer-due detection (`serviceParkedStreams` /
/// `sweepParkedContinuations`) stamps `timer_fired_ns`; every resume
/// path drains via `drainFired`.
/// `next_wake_ns == maxInt(i64)` is the "no timer pending"
/// sentinel; we never compare against it as an active deadline.
pub const StreamWakes = struct {
    interval_ms: i64 = 0,
    next_wake_ns: i64 = std.math.maxInt(i64),
    kv_prefixes: []KvArm = &.{},
    /// Non-zero when the interval timer fired since the last drain
    /// (the fire's wall-clock ns). Surfaces as a `{kind:"timer"}`
    /// entry on `request.activation.wakes[]`.
    timer_fired_ns: i64 = 0,
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

    /// True when at least one arm (kv or timer) fired since the last
    /// drain — the "a resume is due" Msg predicate.
    pub fn anyFired(self: *const StreamWakes) bool {
        if (self.timer_fired_ns != 0) return true;
        for (self.kv_prefixes) |arm| {
            if (arm.fired_at_ns != 0) return true;
        }
        return false;
    }

    /// Drain the fired arms into an owned `WakeEntry` slice (prefix
    /// bytes duped; entries sorted by fire time) and reset the fired
    /// state so nothing re-fires next sweep. Empty slice when nothing
    /// fired (a `drainFired` on an idle chain is a no-op). On OOM the
    /// fired state is left intact — the wake re-fires next tick, which
    /// is safe under edge ("go look") semantics.
    pub fn drainFired(
        self: *StreamWakes,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}![]WakeEntry {
        var count: usize = 0;
        for (self.kv_prefixes) |arm| {
            if (arm.fired_at_ns != 0) count += 1;
        }
        if (self.timer_fired_ns != 0) count += 1;
        if (count == 0) return &.{};

        const out = try allocator.alloc(WakeEntry, count);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |*w| w.deinit(allocator);
            allocator.free(out);
        }
        for (self.kv_prefixes) |arm| {
            if (arm.fired_at_ns == 0) continue;
            out[built] = .{
                .tag = .kv,
                .prefix = try allocator.dupe(u8, arm.prefix),
                .fired_at_ns = arm.fired_at_ns,
            };
            built += 1;
        }
        if (self.timer_fired_ns != 0) {
            out[built] = .{ .tag = .timer, .fired_at_ns = self.timer_fired_ns };
            built += 1;
        }
        // Every dupe landed — reset fired state now (not before: an
        // OOM above must leave the arms fired so the wake retries).
        for (self.kv_prefixes) |*arm| arm.fired_at_ns = 0;
        self.timer_fired_ns = 0;
        std.mem.sort(WakeEntry, out, {}, struct {
            fn lessThan(_: void, a: WakeEntry, b: WakeEntry) bool {
                return a.fired_at_ns < b.fired_at_ns;
            }
        }.lessThan);
        return out;
    }

    pub fn deinit(allocator: std.mem.Allocator, items: []StreamWakes) void {
        for (items) |*item| {
            for (item.kv_prefixes) |arm| allocator.free(arm.prefix);
            if (item.kv_prefixes.len > 0) allocator.free(item.kv_prefixes);
            if (item.wake_to) |t| allocator.free(t);
            item.* = .{};
        }
    }
};

/// One armed `after.kv` prefix + its fired state. `prefix` is
/// allocator-owned; `fired_at_ns != 0` means a kv write landed under
/// the prefix since the last drain (value = the latest match's
/// wall-clock ns). A bit-per-arm can't overflow, so "which prefix
/// fired" is always complete — the honest form of an edge wake.
pub const KvArm = struct {
    prefix: []u8 = &.{},
    fired_at_ns: i64 = 0,
};

/// Wrap freshly-registered prefix strings into unfired arms. Takes
/// ownership of every string AND the old spine (freed here); the
/// returned arm slice owns the strings. On OOM nothing is consumed —
/// the caller still owns `prefixes` and frees it on its error path.
pub fn armsFromPrefixes(
    allocator: std.mem.Allocator,
    prefixes: [][]u8,
) error{OutOfMemory}![]KvArm {
    if (prefixes.len == 0) return &.{};
    const arms = try allocator.alloc(KvArm, prefixes.len);
    for (prefixes, arms) |p, *arm| arm.* = .{ .prefix = p };
    allocator.free(prefixes);
    return arms;
}

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

/// One drained fired-wake entry, surfaced to the handler as
/// `request.activation.wakes[i]`. The tag picks which fields are
/// meaningful; `prefix` is the ARMED `after.kv` prefix that fired
/// (allocator-owned dup made at drain time), never a matched key —
/// issue #8: the wake tells you which watch fired; the handler
/// re-reads authoritative kv under it ("go look").
pub const WakeEntry = struct {
    tag: Tag = .timer,
    /// Set when `tag == .kv`; allocator-owned. Empty slice when
    /// `tag == .timer` (the default leaves `prefix.len == 0` so a
    /// drain consumer can branch on `entry.tag` without checking
    /// for sentinel strings).
    prefix: []u8 = &.{},
    /// Set on every entry — wall-clock ns the wake fired (latest
    /// match for a kv arm; scheduled fire time for a timer).
    /// Surfaces to the handler as `wakes[i].firedAt` in MILLISECONDS.
    fired_at_ns: i64 = 0,

    pub const Tag = enum(u8) { kv, timer };

    /// Free owned slices. Safe to call on a default-init entry
    /// (`prefix.len == 0` short-circuits).
    pub fn deinit(self: *WakeEntry, allocator: std.mem.Allocator) void {
        if (self.tag == .kv and self.prefix.len > 0) {
            allocator.free(self.prefix);
        }
        self.* = .{};
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

test "StreamWakes deinit frees kv arm spine + prefixes" {
    const a = testing.allocator;
    const prefixes = try a.alloc([]u8, 2);
    prefixes[0] = try a.dupe(u8, "orders/");
    prefixes[1] = try a.dupe(u8, "alerts/");
    var items = [_]StreamWakes{.{
        .interval_ms = 200,
        .next_wake_ns = 1_500_000_000,
        .kv_prefixes = try armsFromPrefixes(a, prefixes),
    }};
    items[0].kv_prefixes[1].fired_at_ns = 100; // fired state is inert to deinit
    StreamWakes.deinit(a, &items);
    try testing.expectEqual(@as(usize, 0), items[0].kv_prefixes.len);
}

test "StreamWakes.drainFired surfaces fired PREFIXES (not keys), sorted, and resets" {
    const a = testing.allocator;
    const prefixes = try a.alloc([]u8, 3);
    prefixes[0] = try a.dupe(u8, "orders/");
    prefixes[1] = try a.dupe(u8, "alerts/");
    prefixes[2] = try a.dupe(u8, "quiet/");
    var items = [_]StreamWakes{.{ .kv_prefixes = try armsFromPrefixes(a, prefixes) }};
    defer StreamWakes.deinit(a, &items);
    const sw = &items[0];

    try testing.expect(!sw.anyFired());
    sw.kv_prefixes[1].fired_at_ns = 50; // alerts/ fired first
    sw.kv_prefixes[0].fired_at_ns = 200; // orders/ fired later
    sw.timer_fired_ns = 100;
    try testing.expect(sw.anyFired());

    const drained = try sw.drainFired(a);
    defer {
        for (drained) |*w| w.deinit(a);
        a.free(drained);
    }
    // quiet/ never fired → 2 kv entries + 1 timer, sorted by fire time.
    try testing.expectEqual(@as(usize, 3), drained.len);
    try testing.expectEqual(WakeEntry.Tag.kv, drained[0].tag);
    try testing.expectEqualStrings("alerts/", drained[0].prefix);
    try testing.expectEqual(WakeEntry.Tag.timer, drained[1].tag);
    try testing.expectEqual(@as(i64, 100), drained[1].fired_at_ns);
    try testing.expectEqual(WakeEntry.Tag.kv, drained[2].tag);
    try testing.expectEqualStrings("orders/", drained[2].prefix);

    // Fired state fully reset — a second drain is empty.
    try testing.expect(!sw.anyFired());
    const again = try sw.drainFired(a);
    try testing.expectEqual(@as(usize, 0), again.len);
}

test "StreamWakes.drainFired dedupes per arm — N matches surface once" {
    const a = testing.allocator;
    const prefixes = try a.alloc([]u8, 1);
    prefixes[0] = try a.dupe(u8, "feed/");
    var items = [_]StreamWakes{.{ .kv_prefixes = try armsFromPrefixes(a, prefixes) }};
    defer StreamWakes.deinit(a, &items);
    const sw = &items[0];

    // A burst of matches just re-stamps the arm — latest wins; a
    // bit-per-arm can't overflow, so there is no lost_oldest.
    sw.kv_prefixes[0].fired_at_ns = 10;
    sw.kv_prefixes[0].fired_at_ns = 20;
    sw.kv_prefixes[0].fired_at_ns = 30;

    const drained = try sw.drainFired(a);
    defer {
        for (drained) |*w| w.deinit(a);
        a.free(drained);
    }
    try testing.expectEqual(@as(usize, 1), drained.len);
    try testing.expectEqualStrings("feed/", drained[0].prefix);
    try testing.expectEqual(@as(i64, 30), drained[0].fired_at_ns);
}

test "armsFromPrefixes takes ownership; empty input is a no-op" {
    const a = testing.allocator;
    try testing.expectEqual(@as(usize, 0), (try armsFromPrefixes(a, &.{})).len);

    const prefixes = try a.alloc([]u8, 1);
    prefixes[0] = try a.dupe(u8, "x/");
    const arms = try armsFromPrefixes(a, prefixes);
    defer {
        for (arms) |arm| a.free(arm.prefix);
        a.free(arms);
    }
    try testing.expectEqualStrings("x/", arms[0].prefix);
    try testing.expectEqual(@as(i64, 0), arms[0].fired_at_ns);
}

test "WakeEntry default-init has empty prefix + deinit is safe" {
    const a = testing.allocator;
    var entry: WakeEntry = .{};
    entry.deinit(a);
    try testing.expectEqual(@as(usize, 0), entry.prefix.len);
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
