# Collection & wait lifecycle map (rove-js worker)

A map of every collection an HTTP request (or a parked unit) lives in, what
moves it between them, and — the part that's easy to lose — the four
distinct *kinds of wait* and what wakes each. Written to de-risk any future
attempt at the "single-arm collapse" (effect-reification 3b); that change
rewrites exactly this state machine, so understand it cold first.

> Point-in-time map (2026-06-02, `effect-reification` @ `dd2b861`). Collection
> and function names are stable; exact line numbers drift — grep the function
> name. Source: `src/js/worker.zig`, `worker_dispatch.zig`, `worker_drain.zig`,
> `worker_streaming.zig`, `src/js/effect/cmd.zig`, `src/h2/root.zig`.

## 0. Two object kinds (don't conflate them)

- **h2 entity** — one HTTP request. A rove `Entity` (index+generation) that
  travels through the h2 and worker collections carrying its request/response
  components (`StreamId`, `Session`, `RespBody`, `Status`, …). Every stream
  collection shares one merged `Row`, so an entity keeps all its components
  across every move.
- **parked unit** — a record in `parked_units` (its own `ParkedUnit` =
  `effect.Continuation(BufferedCmds, *TrackedTxn)`). NOT an h2 request. It is
  the **batch-level commit gate**: it holds the deferred `Cmd`s
  (`kv_wake_broadcast`, `http_fetch`, `stream_chunk`, `stream_close`, and the
  per-entity `respond` moves) and either the shared txn's seq or its own txn.

**The governing principle** (`feedback_state_is_collection`): an entity's
*membership in a collection IS its state*. There is no `status` field saying
"waiting for raft" — being in `raft_pending_response` *is* that state.

## 1. The four kinds of "wait"

This is the organizing insight. Four independent reasons something is parked,
each with its own marker, home, and wake mechanism:

| Wait | Waits for | Marker component | Home collection(s) | Released by | Release trigger |
|---|---|---|---|---|---|
| **Raft-commit** | the handler's writes to reach raft quorum | `RaftWait{seq, deadline_ns}` (entity) + the seq key in `SharedTxnPool` (unit) | `raft_pending_response` / `_cont` / `_stream` + `parked_units` | `drainRaftPending` | `raft.committedSeq() >= seq` (commit) / `faultedSeq()` or deadline (fault→503) |
| **Body-durability** | a >16 KB inbound request body to become durable in the blob coordinator | `BodyDurabilityWait{worker_seq, worker_id, status}` | `body_pending` | `drainBodyPending` | `coord.durableSeq(worker_id) > worker_seq` |
| **Held-continuation** | an external callback (webhook/`http.send` result) OR a `next(...)` hop | `ContDescriptor{cont, deadline_ns, …}` | `parked_continuations` | callback resume or `sweepParkedContinuations` | bound-send callback arrives, OR `now >= ContDescriptor.deadline_ns` (→504) |
| **Stream-wake** | the next chunk-producing event | `StreamWakes{interval_ms, next_wake_ns, kv_prefixes, pending_wakes}` | `stream_data_out` | `serviceParkedStreams` | kv-write matches a watched prefix, OR timer `next_wake_ns` due, OR disconnect |

Raft-commit and body-durability are **watermark waits** (poll a monotonically
advancing counter). Held-continuation and stream-wake are **event waits**
(something external fires). A single request can pass through several in
sequence (e.g. a held continuation that writes → also takes a raft-commit
wait on `raft_pending_cont` for that hop's writes).

## 2. Collection inventory

**h2-side** (`src/h2/root.zig`, the `Server` registry). All share one `Row`
(the merged stream row: `StreamId`, `Session`, `Req/RespHeaders`,
`Req/RespBody`, `Status`, `H2IoResult` + the worker's `merged_request_row`:
`RaftWait`, `BodyDurabilityWait`, `ChainContext`, `ContDescriptor`,
`StreamChain/Chunks/Wakes/Draining`, `BoundFetchCount`):

| Collection | Membership means |
|---|---|
| `request_out` | freshly received from the wire, awaiting dispatch |
| `response_in` | response staged, awaiting h2 to frame + send it |
| `response_out` | response sent (or errored) — terminal, ready for cleanup |
| `stream_response_in` | streaming: first hop after commit, before initial frame |
| `stream_data_out` | streaming: parked between chunks (the stream-wake home) |
| `stream_data_in` | streaming: a chunk is being framed/sent by h2 |
| `stream_close_in` | streaming: draining done, awaiting END_STREAM send |
| `_response_sending` / `_stream_data_sending` | internal h2 "frame in flight" states |

**worker-side** (`src/js/worker.zig`, the `Worker` struct):

| Collection | Membership means |
|---|---|
| `raft_pending_response` | awaiting raft commit → then `response_in` |
| `raft_pending_cont` | awaiting raft commit → then back to `parked_continuations` (or `response_in`/`stream_response_in`) |
| `raft_pending_stream` | awaiting raft commit → then `stream_response_in` |
| `parked_continuations` | held open awaiting a continuation resume or §6.4 deadline |
| `body_pending` | awaiting big-body durability before (re-)dispatch |
| `parked_units` | the batch commit-gate records (hold deferred `Cmd`s) |
| `cron_state` | worker-0-only: per-(tenant, sub) next-fire timer |

**Not collections** (plain maps/lists, but part of the machine):
`pending_txns` (`SharedTxnPool`: seq → parked `TrackedTxn`),
`fetch_pending_durability` (list of outbound-chunk events awaiting durability),
`bound_send_owners` (node-wide: send_id → owning worker idx) +
`bound_send_entities` (worker-local: send_id → entity),
`msg_inbox`/`msg_queue` (cross-thread + in-thread Msg ingress),
`wake_inbox` (kv-write events feeding stream-wakes).

## 3. The skeleton (happy paths)

```
                            ┌─ read-only ─────────────────────────┐
                            │                                     ▼
inbound ─▶ request_out ─dispatch─┬─ writes ─▶ raft_pending_response ─commit─▶ response_in ─▶ response_out ─▶ (destroy)
                            │                                     ▲
                            ├─ next(...) ─▶ raft_pending_cont ─commit─▶ parked_continuations ─resume─┐
                            │                  (if the hop wrote)        ▲         │                 │
                            │                                            └─resume──┘ (repark loop)   │
                            │                                                       └─terminal──────▶ response_in
                            │
                            └─ stream(...) ─▶ raft_pending_stream ─commit─▶ stream_response_in ─▶ stream_data_out ⇄ stream_data_in
                                                                                                        │
                                                                                              (draining)└─▶ stream_close_in ─▶ response_out
```

Big inbound bodies insert a `request_out → body_pending → request_out` detour
before dispatch. A read-only request never parks: `request_out → response_in`
directly in `finalizeBatch`.

## 4. Transition edges (grouped by cluster, with triggers)

`FROM → TO  [trigger]  (function)`

**Dispatch / finalize** (`worker_dispatch.zig`):
- `request_out → body_pending`  [inbound body >16 KB, submitted to coordinator]  (`dispatchOnce`)
- `body_pending → request_out`  [`durableSeq` advanced (or failed)]  (`drainBodyPending`)
- `request_out → response_in`  [read-only batch, or propose-fail → 503, or system OPTIONS/204]  (`finalizeBatch` / `tryHandleSystem`)
- `request_out → raft_pending_{response,cont,stream}`  [handler had writes → proposed; sibling = response/cont/stream route]  (`parkSuccessesOnSiblings` → `moveToSibling`)
- `request_out → parked_continuations`  [`next(...)`, no writes]  (`contParkIfAny`)
- `request_out → stream_response_in`  [`stream(...)`, no writes]  (`streamParkIfAny`)

**Raft reconcile** (`worker_drain.zig` `drainRaftPending`, via `effect.reconcile`):
- `raft_pending_response → response_in`  [committed]  (entity-arm commit; the move is the unit's `Cmd.respond`)
- `raft_pending_cont → parked_continuations`  [committed]  (`Cmd.respond` → `stampAndMoveRespond`, `effect/cmd.zig`)
- `raft_pending_stream → stream_response_in`  [committed]  (`Cmd.respond`)
- `raft_pending_{any} → response_in`  [faulted / timed out → 503]  (`drainEntityArm.faultAt`)
- `parked_units → (destroy)`  [committed: `releaseAll` fires the Cmds, incl. the moves above; then destroy]  (`parked_units` arm)
- `parked_units → (destroy)`  [faulted: rollback txn, discard Cmds]  (`parked_units` arm / `drainOnLeadershipLoss`)

**Continuation loop** (`worker_drain.zig`):
- `parked_continuations → raft_pending_cont`  [resume hop WROTE — terminal/repark/cont→stream]  (`proposeAndParkContResume`)
- `parked_continuations → response_in`  [resume hop terminal, no writes → commit inline]  (`resolveParked`)
- `parked_continuations → response_in`  [§6.4 deadline → 504]  (`sweepParkedContinuations` → `resolveParked`)
- `parked_continuations → stream_response_in`  [cont→stream, no writes]  (`transitionParkedToStream` / `installStreamComponentsInline`)
- (repark, no writes: entity STAYS in `parked_continuations`; `ContDescriptor` mutated in place — not a move)

**Streaming pipeline** (`worker_streaming.zig` + `h2/root.zig`):
- `stream_response_in → stream_data_out`  [initial frame sent]  (`consumeStreamResponses`, h2)
- `stream_data_out → stream_data_in`  [popped one chunk → frame it]  (`serviceParkedStreams`)
- `stream_data_in → stream_data_out`  [chunk sent → back to drain]  (h2)
- `stream_data_out → stream_close_in`  [queue empty AND `StreamDraining.is_draining`]  (`serviceParkedStreams`)
- `stream_close_in → response_out`  [END_STREAM sent]  (`consumeStreamClose`, h2)
- `stream_* → response_out`  [client disconnect / h2 IO error]  (h2 IO handlers)

**Outbound** (`h2/root.zig` + `worker_drain.zig`):
- `response_in → response_out` (or `_response_sending` if DATA frames)  [headers+body framed]  (`consumeResponses`)
- `response_out → (destroy)`  [h2 finished]  (`cleanupResponses`)

## 5. Continuation lifecycle (detail)

A handler returns `next(path, {fn, ctx})` (or `webhook.send` held-sync) →
the request is **held open** in `parked_continuations`, not answered yet.

**What wakes it** (three triggers):
1. **Bound-send callback** — a webhook/`http.send` result lands, the baked
   `__system/webhook_onresult` shim runs, calls `__rove_resume_if_bound` →
   `resumeIfBoundTrampoline` → enqueues a `PendingBoundResume` →
   `drainPendingBoundResumes` → `resumeBoundContinuation`.
2. **Chained `send_callback`** — same resume path, `allow_repark = true`.
3. **§6.4 deadline** — `sweepParkedContinuations` fires every tick; when
   `now >= ContDescriptor.deadline_ns` it resumes with `allow_repark = false`,
   so any non-terminal outcome becomes a **504**.

**Re-entry**: all three call `resumeContinuation`, which re-invokes the
handler via `Dispatcher.runOutcome` on the parked entity. The outcome is one
of four, each split by whether the hop wrote:

| Outcome | No writes | With writes |
|---|---|---|
| **terminal** | commit inline → `resolveParked` → `response_in` | `proposeAndParkContResume(terminal)` → `raft_pending_cont`; on commit `Cmd.respond` routes → `response_in` |
| **repark** (`next` again) | mutate `ContDescriptor` in place, refresh deadline, STAY | `proposeAndParkContResume(repark)` → `raft_pending_cont`; on commit routes back → `parked_continuations` |
| **cont→stream** (`stream(...)`) | `installStreamComponentsInline` → `stream_response_in` | `proposeAndParkContResume(stream)` → `raft_pending_cont` → on commit `stream_response_in` |

So the write path always detours through `raft_pending_cont` (a raft-commit
wait for that hop's writes) and comes back. The read-only path resolves
immediately. This is why the same entity oscillates
`parked_continuations ⇄ raft_pending_cont` across a multi-hop chain.

**Cross-worker routing**: a continuation parks on worker A (kernel
SO_REUSEPORT picked A for the inbound socket), but its webhook callback may
land on worker B. At open-hop, A registers `bound_send_owners[send_id] = A`
(node-wide) and `bound_send_entities[send_id] = entity` (A-local). When B's
shim resolves the callback, it looks up `bound_send_owners`, enqueues the
resume Msg into A's `MsgInbox`; A drains it (`drainMsgInbox`), finds the
entity via its local map, and resumes. (See `cross-worker-held-state-plan.md`
Phase 2B; gated by `heldsync_multiworker_smoke.py`.)

## 6. Streaming lifecycle (detail)

A handler returns `stream({status, headers, write, waitFor, ctx})` → the
entity enters the streaming pipeline and produces chunks over time.

**The four stream components** (on the entity):
- `StreamChain{module_path, ctx_json, activation_count}` — identity: which
  module to re-invoke on each wake, the rolling customer context, and the
  activation cap (`MAX_STREAM_ACTIVATIONS` → 501).
- `StreamChunks{queue, queue_bytes, dropped_chunks}` — the FIFO chunk queue,
  soft-capped at 256 KB (§9.4 write-pressure; newest dropped on overflow).
- `StreamWakes{interval_ms, next_wake_ns, kv_prefixes, pending_wakes}` — the
  wake registration: a repeating timer and/or watched kv prefixes, plus the
  `pending_wakes` ring (K=32, drops oldest, surfaces `lost_oldest`).
- `StreamDraining{is_draining}` — set when the stream should close after the
  queue empties.

**The chunk loop** (`serviceParkedStreams`, every tick, per `stream_data_out`
entity):
1. If a chunk is queued → `popOldest` → stamp on `RespBody` → move to
   `stream_data_in` (h2 frames + sends it, then moves it back).
2. Else if `is_draining` and the queue is empty → move to `stream_close_in`
   (h2 sends END_STREAM → `response_out`).
3. Else if the timer is due → push a `.timer` `WakeEntry` to `pending_wakes`.
4. Else if `pending_wakes` is non-empty (and under the activation cap) →
   `resumeStream`: drain the wakes into a `wake_batch` activation, re-invoke
   the handler, append the chunks it returns. A `.terminal` return sets
   `is_draining`; a `.stream` return refreshes `ctx_json` + wake registration.

**What wakes it**: kv-react (`drainKvWakeInbox` + `matchEventsToWakes` match a
kv-write against `kv_prefixes` → push a `.kv` `WakeEntry`), the interval timer,
or client disconnect (h2 IO error moves the entity to `response_out`).

**Write-on-resume**: if a stream resume hop writes, its chunks are staged on a
`parked_units` unit and applied to `StreamChunks` only on raft commit (via
`Cmd.stream_chunk` / `interpretCmd`) — chunks reach the wire only after the
activation that produced them commits (`streaming-model.md` §2).

## 7. The two deadlines (commonly confused)

Both start from `now + CONT_HOLD_DEADLINE_NS` but mean different things and
are read by different sweeps:

- `ContDescriptor.deadline_ns` — the **§6.4 hold deadline**. Read by
  `sweepParkedContinuations`. "If no callback arrives by here, 504 the held
  request." Gates *resumption*.
- `RaftWait.deadline_ns` — the **commit-wait deadline** for an entity in a
  `raft_pending_*` collection. Read by `drainRaftPending` (via `classify`).
  "If raft doesn't commit this hop's writes by here, fault → 503." Gates
  *durability*.

`RaftWait` does double duty as both the seq carrier and this commit deadline;
`ContDescriptor` is purely the held-request lifecycle.

## 8. Where 3b would cut (tie-back)

3b ("the dragon") collapses the raft-commit reconcile from two arms into one:
make the `parked_units` batch record the sole owner of its seq — it commits
the shared txn AND moves its entities (via the `Cmd.respond` list it already
holds) — so `drainEntityArm`, the `RaftWait` marker, and the
`pending_txns.contains()` cross-arm gate all disappear. The cost is that the
**fault path inverts** (today `drainEntityArm` 503s+moves each entity directly
from the column; the unit would have to iterate its `respond` Cmds and
503+move each) and it touches **six** parking sites — the three in
`worker_dispatch.zig` (batch/release/admin) plus the **three continuation
re-park hops** in `proposeAndParkContResume` (§5). The continuation loop is
the riskiest surface: every `parked_continuations ⇄ raft_pending_cont`
oscillation is a parking site that 3b must keep byte-identical.

Gate for any 3b attempt: `scripts/phase32_gate.sh`.
