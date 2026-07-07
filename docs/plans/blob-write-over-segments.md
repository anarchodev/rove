# Blob write over segments — the recipe substrate

Status: **design note, not scheduled.** Drafted 2026-07-07 out of the
surface-test arc. Nothing here is built; the point of writing it down
now is that `blob_sessions` (the worker-RAM upload session) is a shape
we should stop building on, and the replacement touches the customer
contract (`blob.seal`'s completion semantics), so it wants agreement
before code.

Relates to: `docs/effect-algebra.md` §5 (the durability rule this
reuses), `docs/decisions.md` §3.3 (durability composed as marker +
sweep), `docs/architecture/replay-and-sim.md` (the purity contract this
restores), `docs/architecture/routing-and-ingress.md` (the blob doors
this extends), `docs/plans/retention-and-gc.md` (the pass this must
coordinate with).

## 1. What's wrong with the current shape

`blob.write`/`seal` today is a worker-RAM byte accumulator
(`src/js/blob_sessions.zig`): an ArrayList per session, 64 MiB cap, 2
sessions per tenant, idle-swept. Four independent problems:

1. **Double storage.** In the `onChunk` flow the bytes are already
   durable before the handler runs — the chunk-tape gate submits every
   fire's payload to the blob coordinator (or carries it inline) as a
   precondition of the activation existing. `blob.write(request.bytes)`
   then copies those same bytes into RAM. The worker holds a second
   copy of data the platform already owns.
2. **Outside the recorded world.** The replay contract says an
   activation is a pure function of (Msg + readset + ctx + seed). The
   session buffer — and `blob.write`'s running-total return, and
   `seal`'s hash — is worker state in none of those. Handlers that use
   it are not replayable or simulable, and no world-schema patch fixes
   that cleanly while the state lives in RAM.
3. **The caps are RAM protection, not policy.** 64 MiB / 2 sessions
   exist to bound worker memory, and they bound the feature with it.
4. **Segments has the same disease in a different organ.**
   `segments.seal` assembles its full payload inside the sealing
   activation — bounded by the request arena, paid on the hot path.

## 2. The substrate

One mechanism replaces both accumulations:

```
append rows (kv)  →  seal marker (kv)  →  compose (door job)  →  blob + completion activation
```

- **Recipe rows.** An open accumulation is kv rows, written through the
  ordinary writeset like any customer data. Each row is either
  `{inline: bytes}` (small payloads, and every segments record) or
  `{ref: bodyref}` (a pointer to a chunk-tape payload already durable
  in the coordinator). Only pointers and small values ride raft — the
  byte-budget rule that keeps bulk bytes off the log is preserved
  because the bulk bytes are already in S3 via the tape.
- **The midstate row.** The recipe carries a running sha256 midstate
  (§3), updated at every append while the bytes are in hand.
- **The seal marker.** `seal` flips the recipe's meta row to
  `{state: "sealed", hash, contentType, totalBytes}` — replicated,
  durable intent. From this commit, materialization is owed.
- **The compose.** A door job (the `armBlobReceive` species: job
  thread, off the dispatch loop) walks the rows in order — inline
  bytes directly, refs as ranged reads from the coordinator — streams
  a multipart PUT to `file-blobs/{hash}`, recomputes the sha256 as it
  goes, and verifies it equals the recipe's hash (end-to-end integrity
  of the refs, free). On success it proposes the flip writeset:
  `state = "materialized"`, plus the profile's bookkeeping (§6),
  atomically.
- **The completion.** A durable `{on}` activation (§5) announces
  servability.

State never blurs: everything load-bearing is replicated kv; the only
process-local things are the prompt compose job (allowed to die) and
the streaming window of the PUT.

## 3. The hash: midstate, not digest

sha256 is block-chained. From a finished digest `sha256(prefix)` you
cannot compute `sha256(prefix ‖ rest)` — finalization bakes in padding
and length. (The length-extension trick continues from a digest but
hashes the padding into the message; useless here.) From the suspended
**midstate** — chaining state (32 B) + total count (8 B) + partial
block (≤63 B) — continuation is exact.

So the recipe carries ≤ ~103 bytes of midstate, updated per append,
and `seal` finalizes it into the true `sha256(bytes)` **synchronously,
without reading any ref back**. The content-addressed namespace stays
uniformly "sha256 of the bytes" — no manifest-hash fork, dedup and
integrity conventions untouched.

Needs one native addition: a streaming-sha256 surface on `crypto` with
an exportable/importable midstate. `std.crypto.hash.sha2.Sha256` is a
plain struct (state, buffer, lengths) — the binding is small and the
surface is generally useful beyond this plan.

## 4. Seal: the prompt path

This is `webhook.send`'s durability pattern applied to compose — the
marker is the durable intent, the prompt dispatch is the latency path,
the materializer (§7) is the guarantee:

1. **In the activation** (`blob.seal({on, ctx, contentType})`, a pure
   JS shim): read the recipe meta (read-your-writes covers
   same-activation appends), finalize the midstate → hash, write the
   seal marker, emit the compose trigger — a fetch Cmd to the compose
   door, leader-local and deliberately moot-on-loss. Return the hash.
2. **Synchronous hash** means the handler can write its pointer row
   (`media/{id} → {hash, status: "processing"}`) in the SAME writeset
   as the seal marker — atomic, one raft entry.
3. **The door job** streams the compose (§2) and proposes the flip.
4. **The completion activation** fires (§5).

If the prompt path dies — worker crash after the marker committed,
tenant move mid-compose, S3 retries exhausted — nothing special
happens at failure time. The sealed-but-unmaterialized marker is
scanned up by the materializer, which runs the same compose code.
Idempotency is structural: the PUT is content-addressed (a
prompt/materializer race writes identical bytes to one key) and the
flip is an idempotent kv write.

Correctness lives entirely in replicated state; the prompt path is
pure optimization. Delete it and every blob still materializes within
one materializer period. Crash the materializer and fresh seals still
appear in seconds — only the crash-recovery tail degrades, behind the
GC guard.

## 5. Completion is a durable activation

There is no customer-visible "durably promised but not servable"
state to reason about. Readiness is announced, never inferred:

- `blob.seal({on: "onStored", ctx})` — the universal `{on}` key, with
  **`webhook.send`'s delivery semantics, not `after.fetch`'s**. The
  sealed marker (not the live connection) owes the callback, so the
  completion arrives as a `send_callback`-class activation: it resumes
  the held chain when the chain is still held (answer the waiting
  client with a working URL), and runs connectionless when it isn't
  (the pipeline continues). No moot-on-loss for a durable artifact.
- No new verb, no `after.seal`: `after.*` is the connection-scoped
  wake family by grammar, and this callback is not droppable. The
  scope difference is carried by the noun's family, exactly as
  `webhook.send` vs `after.fetch` today.
- **The hash is an identifier; readiness is the activation.**
  Dereferencing early (`blob.url`/`get` on a sealed-not-materialized
  hash) fails loud with a clear error. The canonical pattern never
  hits it:

```js
export function onChunk() {
  blob.write(request.bytes);
  if (!request.done) return next();
  const hash = blob.seal({ on: "onStored", ctx: { id: request.ctx.id } });
  kv.set(`media/${request.ctx.id}`, JSON.stringify({ hash, status: "processing" }));
  return next();
}

export function onStored() {
  const rec = JSON.parse(kv.get(`media/${request.ctx.id}`));
  kv.set(`media/${request.ctx.id}`, JSON.stringify({ ...rec, status: "ready" }));
  response.status = 200;
  return blob.url(rec.hash);
}
```

## 6. Two profiles, one substrate

Segments is not replaced; it is **re-based**. Its hot rows are already
inline recipe rows with a sequence index. The profiles differ on two
orthogonal axes:

| | `segments.*` | `blob.write`/`seal` |
|---|---|---|
| row type | inline required | inline or ref |
| why | hot read surface (`get(log, seq)` serves recent records from kv) | accumulation is opaque; nobody reads chunk N of a half-upload |
| boundaries | record-indexed; compose emits an offset index so sealed `get` can slice | byte stream; boundaries incidental |

Rule of the axis: **inline-required iff hot-readable.**

What segments gains from the re-base:

- **The seal ceiling disappears.** No more assembling the payload in
  the request arena; the compose job streams it off-thread.
- **Atomic bookkeeping.** Delete-hot-rows + write-sealed-pointer moves
  from the `__system/segments_onsealed` post-PUT builtin into the
  compose's flip writeset — one raft entry. Readers stay correct
  through the window for free: hot rows survive until the same entry
  that publishes the sealed pointer removes them.
- **One ladder.** `_blob/owed` retries, recipes, and the materializer
  replace segments' separate durability reasoning.

What segments keeps as its own JS layer (it already is one): the log
namespace and `logs()`, seq/NEXT counters, `get`'s hot-or-sealed
dispatch and slicing, `record()`.

## 7. The materializer, and the GC guard

A **dedicated pass**, not part of GC. Actor and guard stay separate:

- **Materializer**: on its own cadence, compose every recipe sealed
  longer than N minutes ago that the prompt path didn't finish. Same
  compose code, second trigger. Its progress defines a high-water
  mark: "all recipes sealed before T are materialized."
- **GC** (retention-and-gc): stays pure deletion, with one added
  *check*: never delete a tape batch newer than the materializer's
  high-water mark. If the constraint would bind (materializer wedged,
  horizon catching up), **fail loud and stop deleting** — retention
  pressure is recoverable; deleted refs are not. GC never composes.
- Ordering needs no reverse index: age margin does it (materialize
  everything sealed before `T_gc − margin`, then delete batches older
  than `T_gc`).
- **Metric**: recipes materialized by the pass (vs by prompt compose)
  should sit near zero. A rising count means the prompt path is
  dropping jobs — caught long before retention pressure exists.

The emergent ownership story is one sentence: bytes belong to the tape
until a compose claims them into the blob store or retention reclaims
them.

## 8. Surface changes

- `request.bodyRef` (name TBD) on `onChunk` activations: the taped
  payload's coordinator ref, so the `blob.write` shim appends a ref
  instead of re-staging bytes. Sub-inline-threshold fires have no ref;
  the shim appends inline — same decision the tape already made.
- `blob.write(bytes)` with **generated** bytes (not an inbound chunk):
  no pre-existing ref, so the shim stages the payload through the
  `rove-bodies` batch coordinator — the module exists to batch small
  payloads into S3 objects. Return value stays the running total (now
  derived from replicated state).
- `blob.seal(on, contentType?)` → `blob.seal({on, ctx?, contentType?})`
  returning the hash synchronously; completion semantics per §5.
  Pre-launch: no back-compat shim, update in place.
- `crypto`: streaming sha256 with exportable midstate (§3).
- New native: the compose door + job. It is the ONLY new native piece;
  `blob.write`/`seal` themselves become JS shims (per the Zig→JS audit
  direction — this is effect composition, not isolation/wire/crypto).

## 9. What gets deleted

- `src/js/blob_sessions.zig` (the RAM collection, caps, and sweep) and
  its worker trampolines (`blobWriteTrampoline`/`blobSealTrampoline`,
  `Request.trampolines` wiring, `DispatchState.blob_write/seal/
  session_ctx`).
- `segments.seal`'s in-arena payload assembly and the post-PUT
  bookkeeping half of `__system/segments_onsealed`.
- The "not supported in this context" arm of `blob.write`/`seal` (the
  shims work in any dispatch context once they're kv compositions) —
  and with it the surface-test pins on that error.

## 10. Replay and sim

Purity is restored **by construction**: appends, midstate, seal
marker, and pointer rows are ordinary writeset/readset traffic, so
handlers using `blob.write` become replayable and simulable with zero
replay-engine work. The completion is a `send_callback`-class Msg —
the sim saga fold's correlation catalog already lists send-callbacks
as the next correlation to add; `req.seal(…).resolve({ok: true})`
drives `onStored` offline.

Adjacent fixes worth doing regardless of this plan (found during the
surface-test arc): the replay shell's blob stub
(`src/replay/epilogue.zig:318`) is missing `write` entirely (replaying
any `blob.write` handler throws TypeError), and none of the blob stubs
log to the effect bundle or return values — contradicting the
"recorded but not re-run" comment ten lines above them.

## 11. Testing

- **Surface suite** (in-process, already exists): pins the shims'
  writesets — recipe row shapes, midstate progression, the seal
  marker's exact contents, the synchronous hash, the emitted compose
  Cmd, the fail-loud on early dereference. All observable through
  `Dispatcher.runOutcome`; no worker needed once the trampolines die.
- **Smoke**: one `blob_write_smoke_v2` driving a real multi-chunk
  upload through a cluster — chunked POST → recipe rows on followers →
  compose → `onStored` → `blob.url` serves. Plus a materializer leg:
  kill the worker between seal-commit and compose, restart, assert the
  backstop materializes and the completion still fires.
- **Sim**: the seal→`onStored` correlation as a saga-fold case once
  send-callback correlation lands.

## 12. Decisions (settled 2026-07-07)

1. **Recipe rows live under `_blob/recipe/{sid}/`** — `meta` (state,
   hash-or-midstate, contentType, totals, updated_at) plus
   `r/{seq, zero-padded}` rows. `_blob/` is already in
   `SHIM_WRITABLE_PREFIXES` (reserved.zig), so the shim writes them as
   ordinary tenant kv — no reserved changes. **sid = the chain's
   correlation id** (recorded → replay-pure), with `req{request_id}`
   as the chain-less fallback (test paths). **One open recipe per
   chain**, matching today's session-per-chain semantics; a second
   concurrent recipe on one chain is NOT supported. Abandoned unsealed
   recipes are deleted by the materializer when idle > 15 min
   (activation-clock `updated_at`) — the kv analog of today's
   2-minute RAM sweep.
2. **Caps are policy, plan-tier shaped**: ≤ 4096 rows per recipe
   (1 GiB at 256 KiB fires); total bytes per recipe is a plan input
   (default 1 GiB); inline appends ≤ 256 KiB each (mirrors
   MAX_FIRE_BYTES) and ≤ 16 MiB inline total per recipe — large
   *generated*-bytes accumulations wait for the rove-bodies staging
   path (§8, phase 2); ≤ 8 open recipes per tenant; ≤ 2 compose jobs
   per node.
3. **`bodyRef` is an opaque, version-prefixed string token** on the
   surface (`request.bodyRef`); internally `{worker, seq}` — fires map
   1:1 to coordinator entries today, so no offset/len. Rangeability
   is deferred; if it comes, it comes as a new token version
   (same-width-plus-interpretation, not a wider wire).
4. **The completion has no failure arm — say so.** Payload: the
   seal-time `ctx` as `request.ctx`, `{hash, totalBytes}` as the
   result body. `ok:false` is unreachable by design: the GC guard
   makes refs immortal until composed, and the materializer retries
   forever. A compose-time hash mismatch is data corruption — an
   infallibility violation that wedges the high-water mark and pages
   the operator (GC stops, alert fires); it is never translated into
   a customer error.
5. **Compose reads one coordinator payload per ref** (v1). Adjacent
   refs sharing a batch object are a batching optimization, taken only
   if the compose-duration metric says so; the job logs its duration
   from day one.

## 13. Build order

Each phase lands green on its own; no coexisting old/new customer
semantics (the shim cutover in B is atomic).

- **A — streaming sha256.** `crypto.sha256Init() → token`,
  `sha256Update(token, bytes) → token`, `sha256Final(token) → hex`:
  pure functions over an opaque serializable midstate token
  (base64url of Zig's Sha256 struct state). Surface tests + reflect
  entry in the same change.
- **B — the shim cutover (inline recipes).** `blob.write`/`seal`
  rewritten as JS over `_blob/recipe/*` rows + midstate; seal writes
  the marker, emits the compose Cmd, returns the hash. The
  `blob_sessions` trampolines stop being called by the shim (deleted
  in E). **This is the phase that makes `blob.write`/`seal`
  surface-testable in-process** — rows, midstate progression, marker
  contents, Cmd emission, synchronous hash, early-dereference
  fail-loud all pin under `zig build test`.
- **C — the compose door + completion.** Worker-side: intercept the
  compose fetch (the `armBlobReceive` posture), read the recipe rows
  on-thread (bounded by the inline caps), run the PUT job off-thread,
  flip on success, deliver the completion through the existing
  `_blob/owed`-style callback machinery (`__system` builtin → customer
  `{on}` module). Smoke: upload → onStored → blob.url serves.
- **D — bodyRef integration.** `request.bodyRef` on onChunk fires;
  ref-typed rows; compose job reads refs via the coordinator. The
  1 GiB cap becomes real.
- **E — materializer + GC guard + deletions.** The dedicated pass,
  the high-water-mark check in retention/GC, the backstop metric;
  delete `blob_sessions.zig` + trampolines + DispatchState fields.
- **F — segments re-base.** `segments.seal` onto the substrate
  (record-index emission in the compose flip, hot-row deletes atomic
  with the sealed pointer); retire the in-arena assembly and the
  bookkeeping half of `__system/segments_onsealed`.
