# Request lifecycle

> **Status:** draft. Not canon. The locked architecture lives in
> [`docs/PLAN.md`](../PLAN.md); this doc is an explainer of the *current*
> implementation, written to surface simplification candidates and seed a future
> technical article.

This walks one HTTP/2 request from the moment nghttp2 surfaces headers on a
worker socket through to the response bytes leaving the wire, including KV
writes, raft replication, undo-log compensation, and per-request log capture.

The worker is single-threaded by design: every step below runs on one thread,
broken into phases that each poll loop visits in order. The only other thread in
the picture is the raft thread, which applies committed envelopes to follower
SQLite databases.

---

## The shape of a poll loop

```
worker.poll() → h2.poll()
                  ├─ prelude   : drain h2.response_in → nghttp2 send queue
                  ├─ io.poll   : submit pending writes, wait for io_uring CQEs
                  └─ postlude  : triage reads, feed nghttp2, append to h2.request_out
              → dispatchOnce()        (handler execution)
              → finalizeBatch()       (commit + raft propose)
              → drainRaftPending()    (release responses once committed)
              → flushLogs()           (periodic, leader only)
```

Each named call is a phase. Entities flow between collections (`request_out`,
`raft_pending`, `response_in`, `_response_sending`); a request advances at most
one phase per poll on the happy path, and stalls in a collection until its
waiting condition fires. There is no async/await — phases are loops over
collection slices.

---

## Phase 0 — Arrival

`onHeadersReceived` (nghttp2 callback, `src/h2/root.zig:605`) creates a
`request_out` entity stamped with `{StreamId, Session, ReqHeaders, ReqBody}`.
The body trickles in through subsequent `DATA` frame callbacks, also synchronous
from nghttp2's perspective. Nothing else fires until the next worker poll.

---

## Phase 1 — Dispatch (`dispatchOnce`, `src/js/worker.zig:1825`)

A single walk over `h2.request_out`. Each entity is triaged in order:

1. **Follower short-circuit** — non-leaders respond `503` and move the entity
   straight to `response_in`. (Followers don't run handlers; they just apply
   replicated envelopes on the raft thread.)
2. **System routes** — `/_system/*` handled in-worker without JS.
3. **Static file cache** — `GET` hits served from `TenantFiles` directly.
4. **Router** — `src/js/router.zig:49` resolves the path to a module, looks up
   bytecode in `TenantFiles.bytecodes`. Misses → 404.
5. **Penalty box check** — tenants over CPU budget are skipped with a 503.

The first handler-bound request in the walk **opens a SQLite IMMEDIATE
transaction** for its tenant (`beginTrackedImmediate`, line 2003). Subsequent
requests in the same walk targeting the **same tenant** reuse this transaction;
requests for other tenants stay in `request_out` for the next poll. This is the
per-tenant batching introduced in the kv-batched-dispatch initiative.

Per handler, inside the shared transaction:

- **Savepoint open** (line 2097) — nested SQL savepoint scopes the handler's
  writes.
- **QuickJS context restore** (`dispatcher.run`, `src/js/dispatcher.zig:266`) —
  `snap.restore()` memcpys a frozen runtime+context image into a per-request
  arena. The fast path (`src/qjs/snap.zig:434`) is a single memcpy if the
  relocation cache is valid for the target base address; the slow path memcpys +
  walks a relocation bitmap. Fresh entropy (`JS_SetTimeOrigin`,
  `JS_SetRandomSeed`) is injected on every restore.
- **Handler runs.** `kv.set/delete` calls accumulate in a `WriteTape` and apply
  against the open savepoint. Console output, exceptions, and timing accumulate
  in the tenant log buffer (`captureLogInner`, line 1042).
- **Outcome:**
  - Success → `txn.release()` collapses the savepoint into the parent
    transaction (line 2181). Response status/body/headers are stamped on the
    entity via ECS components.
  - Throw / timeout → `txn.rollbackTo()` discards just this handler's writes.
    Other handlers in the batch are unaffected.

At the end of the walk, the per-tenant transaction is still open with all
successful handlers' writes buffered.

---

## Phase 2 — Commit + propose (`finalizeBatch`, `src/js/worker.zig:1430`)

For each tenant transaction opened during dispatch:

1. **Local commit** — `txn.commit()` (line 1448) makes writes durable in the
   leader's SQLite WAL.
2. **Raft propose** (`proposeWriteSet`, line 2682) — merges all batched
   writesets, encodes as a type-0 envelope (`{1B type}{2B id_len}{id}{payload}`,
   `src/js/apply.zig:98`), and calls `raft.propose(seq, envelope)`. No blocking
   — propose just queues.
3. **Park** — every successful entity is moved to `worker.raft_pending`,
   stamped with `RaftWait{seq, txn_seq, deadline_ns, store}`.

Read-only batches skip raft and move directly to `response_in`.

If the local commit fails, every success in the batch is rewritten to a 503.
(No undo work needed — the writes never landed.)

---

## Phase 3 — Raft apply on followers (raft thread, `src/js/apply.zig:391`)

Every committed entry hits `applyOne` on the follower's raft thread. It decodes
the envelope and routes by type byte:

| Type | Destination DB                         | Apply path                                  |
|------|----------------------------------------|---------------------------------------------|
| 0    | `{data_dir}/{id}/app.db`               | `applyWriteSet` → `kv.applyEncodedWriteSet` |
| 1    | `{data_dir}/{id}/log.db`               | `applyLogBatch`                             |
| 2    | `{data_dir}/__root__.db`               | `applyRootWriteSet`                         |
| 3    | `{data_dir}/{id}/files.db`             | `applyFilesWriteSet`                        |

**Leaders skip the apply** (`if (ctx.raft.isLeader()) return;`) — the writes
are already in the leader's WAL from Phase 2. The leader's raft thread still
observes the entry and advances `committedSeq`, which is what Phase 4 is waiting
on.

Followers are the sole writer to their per-tenant SQLite, so there's no
contention with anything else (followers don't serve handler traffic at all).

---

## Phase 4 — Drain (`drainRaftPending`, `src/js/worker.zig:2613`)

Back on the worker thread. Walks `raft_pending` once per poll, comparing each
`RaftWait.seq` against `raft.committedSeq()`:

**Committed** (the happy path, line 2632):
- `store.commitTxn(wait.txn_seq)` deletes the per-txn row from the **undo log**
  (line 2639). The comment at line 2634 is the load-bearing one: leaving the
  row would let a startup sweep silently roll back a write that's already
  replicated.
- Move entity to `response_in`.

**Faulted or past deadline** (line 2650):
- `store.undoTxn(wait.txn_seq)` walks the undo log in reverse, restoring
  pre-images (line 2660). The handler's writes were already committed locally
  in Phase 2, so this is the compensating-rollback path.
- Overwrite the response with 503.
- Move entity to `response_in`.

This is the heart of the durability model: **commit local fast, propose to
raft, and only release the response once raft has caught up**. The undo log
exists for the failure case where local commit succeeded but raft never agreed.

---

## Phase 5 — Response (`consumeResponses`, `src/h2/root.zig:1159`)

In the next h2 prelude, `consumeResponses` walks `response_in`, stamps response
headers/body onto the nghttp2 stream via `nghttp2_submit_response`, and moves
entities to `_response_sending`. The next `io.poll` flushes the bytes out via
io_uring.

---

## Phase 6 — Log flush (`flushLogs`, `src/js/worker.zig:1078`, leader only, periodic)

Per tenant, if `shouldFlush(now_ns)` says so:

1. Drain in-memory log records.
2. Encode as a type-1 envelope, propose to raft.
3. Locally apply via `tl.store.applyBatch` on the worker thread (single writer
   to leader's `log.db`).

Logging is best-effort: if the propose fails the local apply still happens, and
a leadership flip between record append and flush drops the batch entirely
(line 1094) rather than risk applying as a non-leader.

---

## Sequence diagram (happy path, single tenant, single handler)

```
client    nghttp2     worker                 raft (leader)    raft (followers)
  │ HEADERS  │           │                         │                    │
  │─────────►│ onHeaders │                         │                    │
  │          │──────────►│ request_out++           │                    │
  │  DATA    │           │                         │                    │
  │─────────►│ onData    │                         │                    │
  │          │           │ ── poll ──              │                    │
  │          │           │ dispatchOnce            │                    │
  │          │           │  beginTrackedImmediate  │                    │
  │          │           │  savepoint              │                    │
  │          │           │  qjs restore (memcpy)   │                    │
  │          │           │  handler runs           │                    │
  │          │           │  release savepoint      │                    │
  │          │           │ finalizeBatch           │                    │
  │          │           │  commit (local WAL)     │                    │
  │          │           │  propose ──────────────►│ append entry       │
  │          │           │  → raft_pending         │                    │
  │          │           │                         │ replicate ────────►│ append entry
  │          │           │                         │ committed         applyOne
  │          │           │ drainRaftPending        │                   (writeset → app.db)
  │          │           │  committedSeq ≥ wait    │                    │
  │          │           │  commitTxn (drop undo)  │                    │
  │          │           │  → response_in          │                    │
  │          │           │ ── poll ──              │                    │
  │          │           │ consumeResponses        │                    │
  │          │           │  submit_response        │                    │
  │          │ HEADERS+DATA queued                 │                    │
  │◄─────────│ io_uring write                      │                    │
```

---

## Why it's shaped this way

A few non-obvious choices:

- **Local commit before raft commit.** Optimises for the common case where raft
  will agree. The undo log is the price paid for this in the rare failure case.
- **Per-tenant batching at dispatch time.** Lets one SQLite transaction absorb
  multiple handler invocations for the same tenant in the same poll, amortising
  the SQLite IMMEDIATE lock cost. Different tenants block each other only
  briefly (via the lock-eager `txn.open()`); on conflict the tenant is parked
  for the next poll instead of spinning.
- **Snapshot restore instead of fresh QuickJS runtime.** A full `JS_NewRuntime`
  is hundreds of microseconds; a memcpy + relocation pass is ~1.7–5 µs.
- **Raft envelopes are typed bytes, not RPC.** One `applyOne` callback
  dispatches by leading type byte to four different SQLite databases. Adding a
  fifth replication target is a new type, a new apply function, and nothing
  else.
- **Logs ride raft.** Replicating logs through the same channel as data writes
  means follower log databases stay coherent for free. The cost is raft log
  volume; the benefit is one mechanism instead of two.

---

## Open questions for simplification review

These are things I noticed while writing this — not assertions, just questions
worth asking:

1. **Phase 4's two collections feel redundant on the leader.** The leader's
   raft thread is a no-op (line 415) and `drainRaftPending` is what actually
   releases the response. Could the leader keep responses in `request_out` with
   a stamped seq and skip `raft_pending` entirely? Or is the separation needed
   for clarity?
2. ~~**`finalizeBatch` rewrites every successful entity to 503 if the local
   commit fails.**~~ **Resolved in `8b9f483` (panic PR).** The audit
   confirmed the only reachable causes of `txn.commit()` failure on a
   freshly-opened IMMEDIATE txn are disk I/O / OOM / corruption, all
   catastrophic — soft-503-ing hid the violation from the supervisor while
   leaving local SQLite state ambiguous. Now panics. Same family of fix
   applied at 11 other sites in the same commit (savepoint/release/rollbackTo,
   commitTxn/undoTxn, follower apply paths).
3. **Log batch payload lives in the raft entry today** (`src/log/root.zig`
   header note: "Today the raft entry payload IS the batch bytes"). Phase 6
   plans to move payload to blob storage with the raft entry carrying only
   the index — mirroring the file-blob model where bytes go to a shared
   backend (FS mount or S3) and raft replicates the manifest. When that
   lands, the propose has to be gated on blob-write completion (otherwise
   followers apply a raft entry pointing at a blob that doesn't yet exist
   on the shared backend — same constraint as file blobs today). The
   throughput-shaped question becomes: what triggers a blob flush — byte-size
   threshold, record count, idle deadline, or some combination? Keep the
   trigger decoupled from writeset cadence so big-batch fsync (and eventual
   S3 PUT) amortization isn't being fought by the per-request data-write
   rate. An earlier draft of this doc asked whether log batches could
   piggyback on writeset envelopes to save a raft round-trip — that framing
   is wrong for the Phase 6 world: piggybacking would force log-blob writes
   onto the writeset's schedule and erase the very batching it's meant to
   enable.
4. **`RaftWait.deadline_ns` requires every `drainRaftPending` walk to read the
   clock per entity.** Could the deadline live on the worker as a single
   "oldest pending" watermark, with per-entity deadlines only computed on
   commit? Probably not worth it unless `raft_pending` regularly grows large.
5. **`captureLogInner` runs inside the dispatch hot path.** If the log buffer
   is contended (e.g. a tenant under a thundering herd), does that show up?
   Worth profiling under load.

---

## File:line index

Cited locations as of this writing — verify with `git blame` if these have
shifted:

- `src/h2/root.zig:605` — `onHeadersReceived`
- `src/h2/root.zig:1159` — `consumeResponses`
- `src/js/worker.zig:1042` — `captureLogInner`
- `src/js/worker.zig:1078` — `flushLogs`
- `src/js/worker.zig:1430` — `finalizeBatch`
- `src/js/worker.zig:1825` — `dispatchOnce`
- `src/js/worker.zig:2613` — `drainRaftPending`
- `src/js/worker.zig:2682` — `proposeWriteSet`
- `src/js/dispatcher.zig:266` — `run` (per-handler)
- `src/js/apply.zig:98` — `encodeWriteSetEnvelope`
- `src/js/apply.zig:391` — `applyOne`
- `src/js/router.zig:49` — path resolution
- `src/qjs/snap.zig:434` — restore fast path
