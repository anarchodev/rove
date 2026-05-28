# Chunk spool — decouple chunk arrival from raft

## Problem

Today's bound-fetch path (`http.fetch({bind: true})`, `webhook.send`
shim) processes each upstream chunk through a full raft round-trip:

```
chunk arrives → UpstreamFetchEvent queued → dispatch picks Msg →
handler activation → handler returns next() with writes →
proposeAndParkContResume → reg.move (deferred) → raft propose →
quorum commit → entity moves back to parked_continuations →
ready for next chunk
```

The held entity's state machine serializes one chunk per raft RTT.
With upstream pushing N chunks/sec and raft RTT ~ms, single-bind
handlers that return `next()` without per-chunk writes survive
(stream({write}) doesn't reg.move). But:

- **Multi-bind + writes-per-chunk** (committed safety net at `8bd53bb`):
  same-tick chunks for different fetches arriving on one entity end
  up cycling in the in-RAM Msg queue under `isMoving`/`raft_pending_*`
  detection. The defer prevents the `PendingMove` panic but doesn't
  fix the throughput mismatch — chunks pile up in the queue, bounded
  by BATCH=64 per tick.
- **Large body buffering** — a 10MB LLM-proxy response chunked into
  64KB pieces holds ~160 events in RAM if the handler is slow.
- **Backpressure** doesn't flow naturally — when the handler can't
  keep up, the producer (fetch_engine on the libcurl thread) keeps
  reading from upstream and queuing Msgs.

The structural fix: chunk arrival should not be coupled to raft
commit rate. Chunks land in durable storage (the existing blob
coordinator, `docs/streaming-model.md` §7.X). The handler's
processing of each chunk goes through raft as usual, at its own pace.

## Goal

Decouple producer (chunk arrival) and consumer (handler activation)
rates via a per-fetch FIFO spool:

- Producer writes chunks to spool tail at upstream rate. Bytes land
  in the blob coordinator immediately (already happens for unbound
  chunks via `fetch_pending_durability`, post-readset-replication
  Phase 4 — extending it to bound).
- Spool holds K-deep RAM ring for fast dispatch; chunks beyond K
  evict their inline RAM bytes (the coord copy stays).
- Consumer (dispatch) pops spool head when the held entity is ready
  for the next activation (post-commit of the prior chunk's writeset).
  Bytes come from RAM if in-window, otherwise blob via `coord.bodyRef`.
- No new JS surface — `onFetchChunk` still sees `request.body` +
  `request.done` + `request.fetchId` + `request.chunkSeq` exactly
  as today.

## Non-goals

- No change to Pattern A (unbound) chunk flow — it already submits
  bytes to coord and parks via `fetch_pending_durability`.
- No change to `pipe_to` (Pattern B). Bytes bypass handler
  activation, stay untaped, stay outside this spool.
- No change to outbound stream chunks (`stream({write})` from
  handler to client). Those already stage via
  `BufferedSendKvOps.staged_chunks` until raft commit. This is the
  symmetric inbound mirror.
- No new JS-visible API surface. No `request.fetchBufferDepth`,
  no `setSpoolDepth(K)` — K is a worker-config knob, tunable via
  env. We pick a default + measure.
- No auto-bind reshape. That's a follow-up after the spool ships;
  the spool unblocks it because auto-bind otherwise inherits the
  same arrival-rate mismatch.

## Design

### ChunkSpool struct

```zig
const ChunkSpool = struct {
    fetch_id: []const u8,      // owns the key in worker.bound_fetch_spools
    tenant_id: []const u8,     // for coord submit attribution + tape
    holder_entity: rove.Entity,// the held chain consuming chunks

    // Sliding window of pending chunks, ordered by ev.seq ascending.
    // head_seq = next seq to dispatch; tail_seq = highest received + 1.
    head_seq: u32,
    tail_seq: u32,

    // Per-entry state. Indexed [head_seq .. tail_seq), modulo ring
    // size for the RAM slots. Entries beyond K-deep evict inline
    // bytes but keep the coord_seq for later read.
    entries: std.ArrayListUnmanaged(Entry),

    // Cleanup signal — set when fetch_engine reports final + when
    // the cancel path runs. Dispatch drains remaining entries then
    // drops the spool.
    closed: bool,
};

const Entry = struct {
    seq: u32,
    final: bool,
    coord_worker_id: u8,       // for coord.durableSeq + bodyRef
    coord_seq: u64,            // worker-local seq from coord.submit
    inline_bytes: ?[]u8,       // null if evicted to blob-only
    // Carry-through fields from the original UpstreamFetchEvent:
    headers_json: ?[]u8,       // seq==0 only
    byte_offset: u64,
    terminal_status: u16,      // final only
    terminal_ok: bool,         // final only
    body_truncated: bool,      // final only
};
```

The RAM ring is logical, not a fixed-size array: `entries` holds
all in-flight chunks but only the first K have `inline_bytes != null`.
When a new chunk pushes the count past K, the oldest entry's
`inline_bytes` is freed (the coord copy remains addressable via
`coord_seq`).

### Worker-local map

```zig
// In Worker (src/js/worker.zig, alongside bound_fetch_entities).
bound_fetch_spools: std.StringHashMapUnmanaged(*ChunkSpool) = .empty,
```

Heap-allocated `*ChunkSpool`; pointers are stable across hashmap
rehashes. Cleanup is explicit — extend the existing
`unregisterBoundFetch` + `scanAndCancelBoundFetches` paths to drop
the matching spool. We do NOT promote the spool into a rove
component; the worker map is consistent with `bound_fetch_entities`
/ `bound_send_owners` (the existing per-fetch-id routing maps).

### Producer side — `fetch_engine.zig`

Today (post-readset-replication Phase 4) every chunk does:

```
1. Build UpstreamFetchEvent{ fetch_id, tenant_id, seq, bytes, final, ... }
2. Route via NodeState.enqueueFetchEventForTenant (hash by tenant)
   — UNLESS ev.bind && bound_fetch_owners[fetch_id] exists, in
   which case route to that owner worker.
3. Owner worker enqueues to its Msg inbox.
4. Owner worker's drainFetchPendingDurability submits to coord +
   gates on HWM (for the unbound path; bound path skips this today).
```

The change (bound path only):

```
1. fetch_engine builds chunk (same as today).
2. fetch_engine calls coord.submit(worker_id_of_owner, bytes) — the
   chunk goes durable via the coord substrate at upstream rate.
3. Route a SLIM Msg to the owner worker: { fetch_id, seq, final,
   coord_seq, coord_worker_id, headers_json, terminal_* }. Bytes
   are NOT carried in the Msg; the owner reads them from coord
   when ready (or from inline RAM cache — see below).
4. Owner worker's Msg handler pushes a new Entry onto the spool
   for fetch_id. The entry holds `coord_seq` always; `inline_bytes`
   is set IFF the chunk arrived with RAM bytes available.
```

To preserve the K-deep RAM cache, the fetch_engine ALSO ships a
short-lived RAM copy of the bytes alongside the slim Msg, but only
for chunks the producer estimates will be in the K-window. Two
realistic policies:

- **Policy A — always inline, evict at consumer.** The Msg carries
  bytes for every chunk; the consumer worker's spool keeps the
  first K inline, evicts the rest. Simpler, but the Msg queue
  briefly holds bytes for chunks that will be evicted on arrival
  (e.g. when K=4 and 100 chunks arrive in a tick, 96 of them ship
  bytes through the Msg queue only to be freed on push).
- **Policy B — never inline in Msg, always read via coord.** The
  Msg is slim; spool reads via `coord.bodyRef` even for the K
  in-window entries. Removes the briefly-held bytes but adds coord
  read latency to every activation. Coord reads are bucket-local
  (no S3 round-trip for the current batch — the bytes haven't
  necessarily been PUT yet).

Recommendation: **Policy A**. The K-window churn is fine — bytes are
already heap-allocated by the producer thread; the Msg queue push
is one pointer hand-off; eviction at push happens in O(1). The
"never inline" policy pays read latency on the hot path; the
"always inline + evict" policy pays only on the cold path (chunks
beyond K).

Cross-worker routing is unchanged: the slim Msg uses the same
`bound_fetch_owners` hop as today. Owner worker is sole spool owner.

### Consumer side — `worker_streaming.zig`

`dispatchPendingMsgs` `.fetch_chunk` arm becomes:

```zig
case .fetch_chunk => |ev| {
    // Push to spool (creates spool if needed). Returns true if
    // spool head is now ready to dispatch.
    const ready = try worker.pushToSpool(ev);
    if (!ready) continue;
    try worker.dispatchSpoolHead(ev.fetch_id);
}
```

`dispatchSpoolHead(fetch_id)`:

1. Lookup spool. Verify holder_entity still exists + is in a steady
   state (not `raft_pending_*`, not `isMoving`). If mid-transition,
   bail — the existing post-commit drain (a new `drainSpools` pass)
   will retry.
2. Look at `entries[0]` (head). Resolve bytes:
   - If `inline_bytes != null`, take RAM copy (transfer ownership
     into the synthesized activation event).
   - Else, gate on `coord.durableSeq(coord_worker_id) > coord_seq`.
     If not durable, bail — `drainSpools` retries when HWM advances.
     If durable, `coord.bodyRef()` → `BodyStore.fetch(ref)` → bytes.
3. Build a synthetic `UpstreamFetchEvent` (or reuse the entry's
   carry-through fields), invoke `resumeBoundFetchChain` /
   `resumeBoundFetchStream` exactly as today.
4. Existing engines handle the activation. Their post-commit
   side-effects (entity moves, raft propose) are unchanged.

Spool head advances after the activation's writeset COMMITS — this
is the back-pressure point. Hook the advance into the existing
`raft_pending_*` flush path: when the entity exits `raft_pending_cont`
/ `raft_pending_stream` via the post-commit drain, run
`drainSpools` on the worker; if the holder's spool has a ready head,
dispatch it.

If the head was terminal (`final: true`), drop the spool entry and
unregister the fetch. If the activation produced a terminal Response
(`.terminal` outcome), drop the WHOLE spool and cancel the fetch
(reuse `scanAndCancelBoundFetches`).

### Spill / eviction policy

K (default RAM-window depth) — start at **K=4 chunks**. Default
`max_response_chunk_bytes` is 64KB, so K=4 caps per-fetch RAM at
~256KB. Env override: `ROVE_BOUND_FETCH_SPOOL_DEPTH`. Measure under
multi-bind smoke + benchfetch before tuning.

Eviction trigger: on push, if `inline_count >= K`, free
`entries[head_idx + K - 1].inline_bytes` (the oldest still-in-window
entry that's about to fall out of the window). The newly-pushed
entry retains its inline bytes.

Edge cases:
- `final: true` chunk always retains inline_bytes (cheaper than a
  blob read for the final activation).
- `headers_json` is small + never evicted — first-chunk-only.
- Empty-body chunks (transport-error terminals) have no bytes to
  evict.

### Tape semantics — unchanged

The tape captures `request.body` bytes at activation time. With the
spool, bytes still arrive at the activation either inline (RAM) or
via coord read (blob → bytes). Either way the activation sees the
exact byte sequence, and the tape records what the handler saw. No
new tape entries, no new replay considerations.

For replay determinism: the spool itself is platform-internal and
not taped. Replay re-feeds the captured bytes per activation, never
needing to consult the coord or spool. The substrate is "ephemeral
between input and tape capture."

### Cross-worker boundary

The held entity lives on worker X (determined at handler-success
time; tracked in `NodeState.bound_fetch_owners[fetch_id] = X`).
Chunks routed to worker X regardless of which thread the
fetch_engine runs on. Spool lives on X. No cross-worker reads of
the spool.

The slim Msg shipped between workers is small (~80 bytes + headers
on seq=0). The coord submit happens on the fetch_engine thread
(any worker_id can be the submitter — coord queues are per-worker_id
but durability gates per-worker_id, so the consumer needs to know
which worker_id submitted to wait on its HWM). The Msg carries
`coord_worker_id` so the consumer can poll the right HWM.

### Cleanup

Three cleanup paths, all converge on `dropSpool(fetch_id)`:

1. **Terminal chunk consumed.** After the final chunk's activation
   commits, `dropSpool` frees all remaining inline bytes + the
   entries list. The coord-side bytes age out via the coord's
   normal lifecycle.
2. **Client disconnect (held entity destroyed).** Existing
   `scanAndCancelBoundFetches` already walks `bound_fetch_owners`
   for entries pointing at the disconnecting entity. Extend it to
   also drop the matching spool entries + free their bytes.
3. **Cancel from JS** (`http.cancelFetch(id)`). Walks the cancel
   path which already unregisters bound_fetch_entities — extend
   to also drop the spool.

Orphan coord submissions (coord_seq reserved but spool dropped
before consume) are harmless — coord lifecycle doesn't reference-count
per-tenant. The `_pool/` objects age out naturally.

### Interaction with readset-replication

Readset replication's Phase 4 chunk-park already submits bytes to
coord + parks the activation on durability. This plan REPLACES the
parked event with a spool entry for bound chunks; the same coord
submit + HWM gate is used. The unbound path (`fetch_pending_durability`)
is unaffected.

The 16KB inline/coord cutoff in readset-replication is a
raft-entry-size optimization (small bodies ride inline in the
raft entry, not in coord). It doesn't apply here — chunks always
go through coord regardless of size, because the spool needs a
uniform durability story. The K-window cache is the optimization
for fast dispatch; the coord copy is the durability ground truth.

## Files to modify

Producer:
- `src/js/fetch_engine.zig` — chunk callback (`emitChunkEvent` /
  `routeEvent` / `buildChunkEvent`) calls `coord.submit` for bound
  chunks before routing the slim Msg.
- `src/js/components.zig` — `UpstreamFetchEvent` either splits into
  a slim variant (Msg payload) + a fat activation event, or keeps
  the existing shape and the producer fills `coord_seq`/
  `coord_worker_id` + leaves `bytes` non-empty when riding Policy A.
  Simplest: add `coord_seq: u64 = 0` + `coord_worker_id: u8 = 0`
  fields, keep `bytes` carrying inline when present.

Consumer:
- `src/js/worker.zig` — add `bound_fetch_spools` map next to
  `bound_fetch_entities`. Init/deinit. Helpers: `pushToSpool(ev)`,
  `lookupSpool(fetch_id)`, `dropSpool(fetch_id)`, `dispatchSpoolHead`.
- `src/js/worker_streaming.zig` — replace the direct
  `resumeBoundFetchChain/Stream` call in `dispatchPendingMsgs`
  `.fetch_chunk` arm with `pushToSpool` + `dispatchSpoolHead`. The
  existing `isMoving`/`raft_pending_*` defer (`8bd53bb`) becomes
  the "head not ready" branch.
- `src/js/worker_drain.zig` — new `drainSpools(worker)` system,
  called from the existing post-commit drain pass (alongside
  `drainBodyPending` + `drainFetchPendingDurability`). Walks the
  spool map, checks holder readiness + head durability, dispatches.
- `src/js/worker_drain.zig` — extend `scanAndCancelBoundFetches`
  to drop spools alongside owner entries.

New struct:
- `src/js/components.zig` or a new `src/js/chunk_spool.zig` —
  `ChunkSpool` + `Entry`. Since this is platform-internal state
  (not a rove component, not on the wire), `chunk_spool.zig` is
  cleaner — keeps `components.zig` for entity-attached components.

Tests:
- Inline unit tests for `ChunkSpool` push/pop/evict invariants.
- Smoke `scripts/bound_fetch_spool_smoke.py`: multi-bind handler
  returns `next()` with kv writes per chunk; producer fires N
  chunks at upstream rate; assert all N chunks processed in order,
  no drops, no panic, no `PendingMove`.
- Smoke `scripts/bound_fetch_large_body_smoke.py`: single bind,
  10MB body / 64KB chunks; assert RAM watermark stays bounded
  (peak ≤ K × 64KB + epsilon), all chunks processed in order.

## Phasing

Phase 1 — **Producer-side coord submit + slim Msg**.
- Add `coord_seq` + `coord_worker_id` to `UpstreamFetchEvent`.
- Fetch_engine submits bound chunks to coord, attaches seq to Msg.
- Consumer ignores the new fields for now (continues to use
  `bytes` inline as today). No behavior change; ground truth
  becomes coord.
- Tests: existing bound-fetch smokes green.

Phase 2 — **Spool data structure + push path**.
- Land `ChunkSpool` struct + `bound_fetch_spools` map.
- Consumer's `.fetch_chunk` arm pushes to spool, immediately pops
  head if entity ready. Single-entry-at-a-time behavior is
  identical to today.
- Tests: existing bound-fetch smokes + heldsync_multiworker still
  green.

Phase 3 — **K-deep ring + eviction**.
- Inline-bytes eviction on push when window > K.
- Consumer reads via `coord.bodyRef` for evicted entries.
- New `drainSpools` system in the post-commit drain pass.
- Smokes: large-body smoke (peak RAM bound), multi-bind smoke
  (throughput at upstream rate).

Phase 4 — **Cleanup hooks**.
- Extend `scanAndCancelBoundFetches` to drop spools.
- Disconnect path drops spools.
- Smokes: disconnect mid-stream, cancel mid-stream.

Phase 5 — **Measure + tune K**.
- benchfetch with bound mode + writes-per-chunk.
- Compare arrival rate vs activation rate; assert decoupled.
- Tune K based on memory profile + dispatch latency.

## Risks

- **Coord submit latency on the engine thread.** Today
  `fetch_engine` is single-threaded around `curl_multi_poll`.
  Adding a `coord.submit` per chunk could backpressure libcurl
  reads. Mitigation: coord submit is non-blocking (push to MPSC
  queue, return seq). Worth measuring: chunk-rate during the
  submit.
- **Slim Msg's coord_seq referencing a not-yet-PUT batch.** Phase
  1 has bytes inline as the source of truth; coord is shadow. Once
  Phase 3 starts reading from coord, the consumer might hit a seq
  whose batch hasn't sealed yet. Gate via `durableSeq` — the head
  waits. This is the normal park-on-durability story.
- **Stale spool on rapid bind-unbind cycles.** A fetch terminates,
  spool dropped, but a stale Msg for the same fetch_id arrives
  later. The Msg's payload should be reconstructible-ignorable
  (no spool → log + drop). Already the pattern for stale
  `bound_fetch_owners` entries.
- **Multi-bind ordering at K=4.** If 8 chunks for two fetches
  interleave on one entity, the spool ordering per-fetch_id is
  preserved (separate spools) but ACROSS fetches the order is
  determined by Msg arrival, then by `drainSpools`' walk order.
  Spec the per-fetch ordering; cross-fetch ordering is observation
  order at the entity, matching today's behavior.
- **K-tuning.** Wrong K = either high memory (large K, slow
  consumer) or slow dispatch (small K, lots of blob reads under
  load). Env override exists; measure before defaulting.

## Verification

Tier-1 regression (must stay green):
- `bound_fetch_smoke`, `bound_fetch_multiworker_smoke`
- `heldsync_smoke`, `heldsync_concurrent_smoke`, `heldsync_multiworker_smoke`
- `webhook_fastpath_smoke`, `fetch_chunk_smoke`, `upstream_streaming_smoke`

New smokes (Phase 3+):
- `bound_fetch_spool_smoke.py` — multi-bind + writes-per-chunk;
  the failing case from the safety-net commit. Asserts no drops,
  in-order activation, throughput matches upstream rate.
- `bound_fetch_large_body_smoke.py` — single bind, large body,
  bounded RAM watermark.

Microbenches:
- `kvexp_chain_bench` — confirm raft-bound throughput unchanged.
- benchfetch with `bind: true` + `writes_per_chunk: 1` — compare
  chunks/sec pre- and post-spool; expect upstream-rate not
  raft-rate.

## Followups (out of scope here)

- **Auto-bind reshape** — drop `bind: true`, add `detach: true`,
  register at handler-success time. Unblocked by spool (no
  arrival-rate cliff). Land after spool.
- **Spool for inbound body streaming** (Gap 2.2 follow-up).
  Streaming inbound bodies that arrive faster than the handler
  could land here too — same shape, different producer. Defer
  until customer demand.
- **Cross-tenant spool batching** — today each spool is single-
  tenant. If many small bound fetches share coord batches via
  `_pool/` (they already do — coord is cross-tenant), no extra
  work. If we ever need per-tenant rate accounting, slot it in
  coord, not the spool.
