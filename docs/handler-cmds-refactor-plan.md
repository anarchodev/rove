# Streaming-handlers structural refactor — kill the side tables

> **Supersedes the earlier "Terminal type" draft of this doc (commit
> sibling).** That plan unified three entity-keyed `AutoHashMap`
> side stores (`parked_meta` / `parked_streams_meta` /
> `pending_stream_meta`) into one. The rove library principles
> (`~/.claude/memory/rove-library.md`) forbid all of them: principle
> #1 (state is collection membership, never an enum/bool flag) and
> #2 (data lifetime through components, never side tables). Unifying
> the violations is not the fix. This plan eliminates them.

## The current violations

**Three entity-keyed side stores** (principle #2):

```zig
worker.parked_meta:         AutoHashMap(Entity, ParkedCont)
worker.parked_streams_meta: AutoHashMap(Entity, StreamCell)
worker.pending_stream_meta: AutoHashMap(Entity, StreamFirstHopMeta)
```

Each holds per-entity state with manual cleanup at four sites
(`cleanupResponses`, `drainRaftPending` fault branch,
`drainOnLeadershipLoss`, `Worker.destroy`). The principle says: "side
tables create orphan bugs — destroying the entity doesn't clean up
the side table entry. Component deinit fires automatically." Every
one of those manual cleanup calls is the symptom.

**Two boolean-flag state fields** (principle #1):

```zig
StreamCell.close_pending: bool   // "drain remaining chunks then close, no more wakes"
SuccessRec.cont != null          // "this success is a continuation, redirect on commit"
SuccessRec.stream != null        // "this success is a stream-first-hop, redirect on commit"
```

Each is a discriminant the dispatch reads to decide where the entity
moves next. Per principle #1, those are collections, not flags.

**Hot-path defensive checks** that wouldn't exist with collection-as-
state:

```zig
if (worker.parked_meta.count() != 0 and worker.parked_meta.contains(ent)) ...
if (worker.parked_streams_meta.count() != 0) ...
if (worker.pending_stream_meta.count() != 0) ...
```

These short-circuits exist precisely because non-cont/non-stream
entities shouldn't pay the side-table-probe cost. If state were
membership, entities in `raft_pending_response` would never reach
the cont/stream logic — the iteration target itself would filter
them out.

## Target architecture

### Components (data lives on the entity)

```zig
/// Chain-level identity (shared by cont + stream chains). Borrowed
/// none — every slice is allocator-owned and freed via deinit.
pub const ChainContext = struct {
    tenant_id: []u8,
    correlation_id: ?[]u8,
    deployment_id: u64,

    pub fn deinit(allocator: std.mem.Allocator, items: []ChainContext) void {
        for (items) |*item| {
            allocator.free(item.tenant_id);
            if (item.correlation_id) |c| allocator.free(c);
        }
    }
};

/// Cont-trampoline state. Lives on entities in
/// `parked_continuations` and `raft_pending_cont`.
pub const ContDescriptor = struct {
    cont: Continuation,
    deadline_ns: i64,
    bound_schedule_id: ?[]u8,

    pub fn deinit(allocator: std.mem.Allocator, items: []ContDescriptor) void {
        for (items) |*item| {
            item.cont.deinit(allocator);
            if (item.bound_schedule_id) |s| allocator.free(s);
        }
    }
};

/// Stream-chain identity + per-activation state. Lives on entities
/// in `parked_streams_*` and `raft_pending_stream`.
pub const StreamChain = struct {
    module_path: []u8,
    ctx_json: []u8,
    activation_count: u32,

    pub fn deinit(allocator: std.mem.Allocator, items: []StreamChain) void {
        for (items) |*item| {
            allocator.free(item.module_path);
            allocator.free(item.ctx_json);
        }
    }
};

/// Chunk queue waiting to be framed onto the held socket. Mutates
/// per tick in `serviceParkedStreams`. Lives on the same
/// collections as StreamChain.
pub const StreamChunks = struct {
    queue: std.ArrayListUnmanaged([]u8),

    pub fn deinit(allocator: std.mem.Allocator, items: []StreamChunks) void {
        for (items) |*item| {
            for (item.queue.items) |chunk| allocator.free(chunk);
            item.queue.deinit(allocator);
        }
    }
};

/// Wake registrations + outstanding match. `kv_prefixes` is rewritten
/// each `__rove_stream` return; `pending_wake` set by the
/// apply-thread fan-out drain (`drainKvWakeInbox`). Lives on the
/// same collections as StreamChain.
pub const StreamWakes = struct {
    interval_ms: i64,
    next_wake_ns: i64,
    kv_prefixes: [][]u8,
    pending_wake: ?PendingKvWake,

    pub fn deinit(allocator: std.mem.Allocator, items: []StreamWakes) void {
        for (items) |*item| {
            for (item.kv_prefixes) |p| allocator.free(p);
            if (item.kv_prefixes.len > 0) allocator.free(item.kv_prefixes);
            if (item.pending_wake) |*w| w.deinit(allocator);
        }
    }
};
```

`close_pending: bool` disappears — it becomes the
`parked_streams_draining` sibling collection (see below).

### Collection topology (state is membership)

**Pre-commit gate (`raft_pending` becomes three siblings):**

| Collection | Row | Post-commit destination |
|---|---|---|
| `raft_pending_response` | base + `RaftWait` | `response_in` |
| `raft_pending_cont`     | base + `RaftWait` + `ChainContext` + `ContDescriptor` | `parked_continuations` |
| `raft_pending_stream`   | base + `RaftWait` + `ChainContext` + `StreamChain` + `StreamChunks` + `StreamWakes` | `stream_response_in` |

`drainRaftPending` walks each independently; each branch knows its
destination at compile time. No `parked_meta.contains(ent)` probe,
no tag dispatch. Three loops, each with one move.

**Held cont (1 collection, same Row as today + ContDescriptor):**

- `parked_continuations` — entity holds the cont; resume engine fires on send-callback or §6.4 deadline.

**Held streams (2 sibling collections — wake-subscribed vs draining-to-close):**

| Collection | Row addition | Behavior |
|---|---|---|
| `parked_streams_active` | `ChainContext` + `StreamChain` + `StreamChunks` + `StreamWakes` | Subscribes to wakes; `serviceParkedStreams` drains chunks + fires `resumeStream` on timer/kv-wake. |
| `parked_streams_draining` | Same Row (close-pending state) | No wakes; just drains remaining chunks then moves to `stream_close_in`. Replaces `close_pending: bool`. |

(These overlap with h2's `stream_data_out` — see "Open question" below.)

### What stays a transient

`Dispatcher.RunOutcome` (the function return value from
`runOutcome`) stays a tagged union — it's a transient classification
of "what did the handler return this time?", consumed immediately
by the caller. Returning a tagged union from a function is normal
Zig; it's the *storage* that violates the principles.

`SuccessRec.terminal` (the per-success-row record in the batch
walk) stays as a per-tick record carrying which raft_pending
sibling to move to. It's not entity state — it's a "where to move
this entity on this tick" decision that consumes the
`RunOutcome` immediately.

Both serve the same role as `Cmd Msg` in TEA: descriptions of
what to do next, not state of what is. They cross zero flush
boundaries.

## Phased build plan

Each phase keeps build clean + all unit tests + all 7 streaming
smokes + heldsync_smoke green. Each phase is independently
revertable.

### Phase 1 — Define components + put them on the Row (structural, no behavior)

- Add `ChainContext`, `ContDescriptor`, `StreamChain`,
  `StreamChunks`, `StreamWakes`, `PendingKvWake` to a new
  `src/js/components.zig` with proper `deinit` semantics.
- Extend the worker's `merged_request_row` so h2's full server-
  stream pipeline + worker `parked_continuations` + worker
  `raft_pending` carry the new components. Default-init values
  are inert; nothing reads them yet.
- Unit-test the components' deinit (populated + default-empty).

**Why no dual-write yet:** the dual-write at park sites needs to
clone the Continuation / chunk slices BEFORE the side table takes
ownership; the mutation sites need parallel updates. Splitting
that across all 10+ sites in one commit is noisy. Cleaner pattern:
do the dual-write + reader-switch together, **per site**, in
Phases 2-4.

**Gate:** build clean, all tests + smokes pass. ~400 LOC.

### Phase 2 — Migrate `parked_meta` site-by-site to ContDescriptor + ChainContext

Each commit picks one read site + the matching write/mutation
sites that feed it, switches them together, and gates on the
smoke suite. Approximate per-site list:

- **2a:** `contParkIfAny` writes ContDescriptor + ChainContext;
  `sweepParkedContinuations` reads them. The `parked_meta.put` in
  contParkIfAny stays; the read in sweepParkedContinuations
  flips.
- **2b:** `contRecordIfAny` writes ContDescriptor + ChainContext
  on the request_out entity; `drainRaftPending`'s commit branch
  reads them when moving raft_pending → parked_continuations.
- **2c:** `resumeBoundContinuation` reads ContDescriptor (the
  bound_schedule_id lookup); `resumeContinuation` reads
  ContDescriptor + ChainContext.
- **2d:** `proposeAndParkContResume` mutates the components
  instead of `parked_meta` for the repark case.
- **2e:** `drainOnLeadershipLoss` + propose-fail discard +
  cleanupResponses + Worker.destroy all stop reading
  `parked_meta`. By here, `parked_meta` writes are unread; the
  map is functionally dead. (Don't delete yet — Phase 7.)

**Gate:** per-step smoke run. ~400 LOC total.

### Phase 3 — Migrate `parked_streams_meta` site-by-site to StreamChain + StreamChunks + StreamWakes

Same per-site pattern:

- **3a:** `registerStreamCell` populates the components;
  `serviceParkedStreams` reads them (chunk drain + close-pending
  check + timer check).
- **3b:** `drainKvWakeInbox` writes `StreamWakes.pending_wake`
  on the entity instead of the cell.
- **3c:** `resumeStream` reads + mutates the components (stream
  return updates StreamChain + StreamWakes; terminal appends to
  StreamChunks).
- **3d:** `fireDisconnectActivation` reads the components.
- **3e:** `cleanupResponses` stops the `parked_streams_meta`
  walk.

**Gate:** same. ~500 LOC.

### Phase 4 — Migrate `pending_stream_meta` site-by-site

- **4a:** `streamRecordIfAnyAt` populates the components on the
  request_out entity (the entity carries them through
  raft_pending into stream_response_in).
- **4b:** `drainRaftPending` commit branch reads them when
  redirecting to stream_response_in.
- **4c:** fault / leadership-loss branches read them for the
  cleanup discard (which becomes structural in Phase 7).

**Gate:** same. ~200 LOC.

### Phase 5 — Split `raft_pending` into three sibling collections

- New collections: `raft_pending_response`, `raft_pending_cont`,
  `raft_pending_stream`. Each with the right Row extension.
- `finalizeBatch` write-path: switch on `SuccessRec.terminal` to
  decide which sibling to move into.
- `drainRaftPending` becomes three loops (or one parametric
  function called three times). Each branch knows its destination.
- `drainOnLeadershipLoss` walks all three.
- The `cont_record_if_any` / `stream_record_if_any` helpers
  collapse — the move target IS the discriminator.

**Gate:** same; hot-path bench `drainRaftPending` before/after. ~400 LOC.

### Phase 6 — Add `parked_streams_draining` sibling; kill `close_pending`

- New collection `parked_streams_draining` (same Row as
  `parked_streams_active`).
- `resumeStream`'s terminal branch + cap-hit branch move the
  entity to `parked_streams_draining` instead of setting
  `close_pending = true`.
- `serviceParkedStreams` iterates both:
  - `parked_streams_active` — drain chunks, fire wakes.
  - `parked_streams_draining` — drain chunks only; when empty,
    move to `stream_close_in`.
- `StreamCell.close_pending` field deleted.

**Gate:** same. ~200 LOC.

### Phase 7 — Delete the side tables + the park/record/discard helpers

- Delete `worker.parked_meta`, `worker.parked_streams_meta`,
  `worker.pending_stream_meta` + all their initialization,
  cleanup, and access sites.
- Delete `ParkedCont`, `StreamCell`, `StreamFirstHopMeta`
  structs (their fields are components now).
- Delete `contParkIfAny` / `contRecordIfAny` / `contDiscardIfAny` /
  `streamParkIfAny` / `streamRecordIfAnyAt` /
  `streamDiscardIfAny` / `freeContMeta` / `freeStreamCell` /
  `registerStreamCell`. The dispatch sites already do `reg.move`
  + `reg.set` directly.
- The manual cleanup in `cleanupResponses`,
  `drainOnLeadershipLoss`, `Worker.destroy` for these maps —
  delete. Component deinit handles it.

**Gate:** same. ~500 LOC deletion.

### Phase 8 — Collapse the three resume engines

With components, the resume engines all look like:

```zig
fn runWakeActivation(worker, ent, activation) !void {
    // Read ChainContext + ContDescriptor-or-StreamChain components from ent.
    // Synthesize request body (outcome_json for send_callback, ctx for timer/kv_wake/disconnect).
    // Run handler.
    // Apply result based on outcome + current collection.
}
```

- `resumeContinuation`, `resumeStream`, `fireDisconnectActivation`
  become thin wrappers (~20 LOC each) that prep the
  activation-specific request body and call `runWakeActivation`.
- The "wrong terminal kind for this collection" rejection (e.g.
  `.continuation` returned from a stream-resume, currently 501) is
  enforced at the move site — moving to `parked_continuations`
  requires the entity to NOT be in a stream collection, etc. The
  comptime row-subset check catches some of these; runtime checks
  catch the rest.

**Gate:** same. The 7 streaming smokes verify each engine still
behaves identically. ~400 LOC consolidation.

### Phase 9 — Docs + framing

- `docs/PLAN.md` §13.3 — handler-as-TEA-`update` framing.
- `docs/streaming-handlers-plan.md` §6 — expand to name the
  Cmd-shaped return value.
- This doc moves to "Done 2026-XX-XX" status.
- `~/.claude/memory/project_handler_returns_cmds.md` updated to
  reflect that the framing AND the structural refactor landed.

**Gate:** docs only. ~150 LOC.

## Effort + risk

- ~2700-3000 LOC touched across 9 commits.
- ~8-12 focused sessions (vs 3-5 for the Terminal-type plan).
- Riskiest phases: 5 (raft_pending split — hot path) and 8 (resume
  engine collapse — smoke parity across three subtle paths).
- Each phase is independently revertable — side tables stay live
  through Phases 1-6, so an issue in Phase N can be fixed before
  Phase 7 deletes the safety net.

## Open question — h2 row composition

The current h2 `request_row` user fragment is merged into every h2
stream collection. If we add `StreamChunks` (24 bytes) +
`StreamWakes` (~88 bytes) + `StreamChain` (~52 bytes) +
`ChainContext` (~48 bytes) + `ContDescriptor` (~112 bytes) as
components, the SoA cost lands on EVERY h2 entity including
non-stream non-cont requests — ~324 bytes × concurrent connections.
At 10k concurrent that's ~3.2 MB of overhead.

Three options:

1. **Pay the cost** — simplest; all components on the h2 request
   row; SoA overhead acceptable for the cleanliness. Probably
   the right call; 3.2 MB is ~0.03% of typical worker RAM
   budget.

2. **Split `request_row` from `stream_row` in h2** — h2 already
   distinguishes server-stream collections from non-stream ones
   (`SERVER_STREAM_CHAIN`). Add a second user-row option for
   stream-only components. Components only live on stream
   collections (`stream_response_in` / `stream_data_out` etc.)
   not on `request_out` / `response_in`. Smaller SoA cost (no
   stream components on non-stream entities); requires an h2
   API change.

3. **Worker-owned sibling collections only** — keep h2's row
   pristine; put the components on worker-owned collections that
   the entity moves into. Moves between worker collections and
   h2 stream-pipeline collections need careful row-subset
   handling. Probably most complex.

Recommendation: start with option 1 in Phase 1 (simplest, lets us
validate the components-on-entity model end-to-end), revisit in
Phase 7 or later if the SoA cost shows up in benches. The
principle compliance is the same in all three; this is a memory
optimization, not a correctness call.

## Non-goals

- **Customer-facing surface unchanged.** `kv.set` / `http.send`
  stay inline-effectful; `Response` / `__rove_next` /
  `__rove_stream` stay as the three customer-visible return shapes.
- **No new functionality.** This is structure cleanup against the
  principles, not a feature.
- **No required perf gain.** The hot-path care in Phase 5 is
  "don't regress," not "improve." (A perf win from eliminating the
  `parked_meta.count()` branch + side-table probe would be nice
  but isn't the motivation.)

## Comparison with the prior "Terminal type" plan

| | Terminal-type plan (superseded) | Components + sibling collections (this plan) |
|---|---|---|
| Side stores | Unified into one (`pending_terminals`) | **Eliminated entirely** |
| Cleanup | Still manual at 4 sites | Structural via component deinit |
| State discriminant | `Terminal` tagged union read at dispatch sites | Collection membership read by iteration target |
| Hot path | `pending_terminals.contains(ent)` probe | No probe — iteration targets non-cont / non-stream entities |
| Principle #1 compliance | No (bool flags + enum-as-state remain) | **Yes** |
| Principle #2 compliance | No (side table unified, not eliminated) | **Yes** |
| LOC | ~1500-2000 | ~2700-3000 |
| Sessions | 3-5 | 8-12 |
| Next-effect-class cost | Add a Terminal variant + a case | Add a collection or component |

The principles aren't aesthetics. They're load-bearing — every
manual `freeStreamCell` call, every `parked_meta.count() != 0`
short-circuit, every `discardIfAny` helper exists because the
data isn't living on the entity where it belongs. Fixing the
shape eliminates the helpers categorically, not one at a time.
