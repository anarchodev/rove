# Customer blob storage — the `blob.*` surface

> **Status:** design, 2026-06-09. Revives the `blob.put` / `blob.get`
> JS shims that were specced and then canceled 2026-05-27
> (`effect-algebra.md` §3 — "defer until concrete use case forces
> it"). The concrete use case arrived: a paper exercise implementing a
> Matrix homeserver as a rewindjs customer reduced every gap to this
> surface (plus ed25519, which is a sibling primitive outside this
> plan's scope). The adopt-model question in §5 is **code-verified**
> against `src/blob/coordinator.zig` + `src/js/worker_dispatch.zig`
> as of `d4a2266`; everything else is design.

## 1. Motivation — the storage doctrine, surfaced

The engine already lives by one storage discipline: **raft replicates
the pointer, object storage holds the bytes.** Deployment manifests in
kv → content-addressed blobs in S3; log batches sealed S3-direct;
readset bodies in blob storage with BodyRefs in the raft entry. This
plan surfaces that same discipline as customer API:

> **kv is for state you mutate; the object store is for facts you
> accumulate.**

Every event-sourced app — the natural shape for a purely-functional
platform — has this anatomy: immutable accumulating facts (events,
uploads, history) plus a small mutable projection (cursors, indices,
current-state pointers). Without a blob surface, the facts pile into
kv and hit the size cap; with it, kv usage plateaus at the working set
while history grows in cheap object storage. The two pricing axes
(`pricing-model.md`: kv hard-cap + object-storage byte-ring) already
assume exactly this split — the pricing and the storage doctrine are
the same statement.

The validating workload is a Matrix homeserver implemented entirely as
a customer app: event DAG as CAS (Matrix event IDs *are* content
hashes in room v3+), media repo, resolved-state snapshots as
derivable-class blobs, history sealed out of kv. Everything in that
exercise that didn't already compose from shipped primitives reduced
to the verbs below.

## 2. Addressing doctrine — CAS only; names are kv's job

Every object is content-addressed at
`{key_prefix_base}{instance_id}/app-blobs/{hash}`. The store has **no
names** — the customer's naming layer (`media/{id} → hash`,
`segments/{room}/{seq} → hash`) lives in kv, where it is
transactional, replicated, and indexed.

This kills four problems at birth: overwrite semantics, key
collisions, LIST, and read-after-write naming races — and dedup falls
out free. It also makes replay cheap by construction: a read by hash
is deterministic, so the tape records the hash, not the bytes
(`tape-minimization.md` CAS-extent record kind). An app that pushes
its bulk into the CAS gets *cheaper* replay — the incentive gradient
points at the architecture we want customers to use.

The tenant prefix is the third sibling of the existing per-tenant S3
layout (`file-blobs/`, `log-blobs/`), so isolation, ops, and metering
ride infrastructure that already exists.

## 3. The verb surface

Two design laws govern everything here (from `handler-shape.md` /
`effect-algebra.md` §6): **the verb is the scope** (no durability
flags), and **bytes the handler doesn't execute on never transit the
worker** ([[feedback_storage_origin_vs_worker_ram]]).

### 3.1 `blob.put(bytes) → hash` — small objects, durable-intent

```js
const hash = blob.put(bytes);                       // arena-bounded (≤ ~1 MB)
kv.set(`media/${id}`, { hash, ct: 'image/png' });   // same writeset — atomic
```

The hash is a pure function of the bytes, so `put` returns it
**synchronously** without violating the Msg invariant (like
`webhook.send` returning an id) — the handler indexes it in kv in the
same activation, atomic with the durability marker. Mechanically this
is the canceled 2026-05-27 spec unchanged: the standard rule-4
composition — `_blob/owed/{hash}` kv marker (rides envelope-0 atomic
with the handler's writes) + idempotent content-addressed PUT + retry
cron + boot subscription. Recovery re-derives bytes by re-executing
the source activation against its readset (`effect-algebra.md` §2.5).

### 3.2 `blob.get(hash)` / `blob.pipe(hash)` — reads

`blob.get` is `on.fetch` against the blob backend wearing a hash
instead of a URL; the fetch engine's three response dispositions are
already the right shapes:

```js
blob.get(hash, { to: 'onBlob' });    // whole → one activation with the bytes
blob.get(hash, { to: 'onSeg' });     // streamed → chunk-shaped activations
blob.pipe(hash);                     // Pattern B: backend → held connection
```

`pipe` serves bytes storage→socket with zero activation hops, untaped
by derivation (no Msg origin — and harmless: the content is
CAS-stable). Ephemeral, no marker; a backend miss is a 503 and the
client retries.

### 3.3 `blob.url(hash, {ttl}) → url` — presign, the one platform-only verb

A pure computation — SigV4 over platform-held keys, no I/O, no Msg.
The handler answers a media download with a `307` to a presigned URL
and the bytes never touch the worker at all. One determinism rule:
the signature's timestamp derives from the activation's **taped
clock**, never a wall-clock read — replay then reproduces the URL
bit-for-bit.

This is the only verb in the plan a customer categorically cannot
compose (they don't hold signing keys), which makes it the clearest
platform obligation. The presign code substantially exists in
`rove-blob` (path-style SigV4); the work is exposure + tenant-prefix
enforcement.

### 3.4 Streaming in, Case A — `blob.write` / `blob.seal` (handler observes the chunks)

For handlers whose logic depends on chunk content (parse, validate,
transform — and also archive the raw bytes):

```js
export function onChunk() {
  blob.write(request.body);            // accumulate into this connection's session
  if (!request.done) return next();
  blob.seal({ to: 'onSealed' });       // complete multipart → hash
  return next();
}
export function onSealed() {
  kv.set(`media/${id}`, { hash: request.result.hash });
  return json({ ... });
}
```

Scope-as-verb does the safety work: the upload session is
**connection-scoped** — an ephemeral ECS entity, one implicit session
per connection ([[feedback_model_simplicity_safety]]: ship one;
explicit handles wait for a customer with concurrent uploads),
abandoned on disconnect (S3 `AbortMultipartUpload`). Nothing durable
exists until `seal`, whose commit point is the ordinary `_blob/owed`
marker.

**Implementation: RAM-sourced assembly, not re-buffering.** The
chunks were already coordinator-submitted as tape inputs before the
handler observed them (§5). The session does not copy bytes out of
the activation: `blob.write` records the chunk's `(worker_id, seq)`;
`seal` assembles the tenant-prefix multipart by reading parts back
from the coordinator's retained RAM (`readBody`,
`coordinator.zig:557`) — zero S3 GETs — buffering to the 5 MiB
part-minimum in a bounded per-session buffer, then `release`-ing each
consumed submission (the chunk-spool P6 refcount). Cost: the bytes
hit S3 twice (pool as tape input + tenant prefix as the object). That
is the correct price for Case A — the handler *observed* the bytes,
so replay needs them.

### 3.5 Streaming in, Case B — `blob.receive` + `onHeaders` (handler doesn't need the bytes)

The Matrix media endpoint decides everything from headers: bearer
token, content-type, quota. No body byte influences the disposition.
The right shape is not inverted homing of chunk Msgs — it is **no
chunk Msgs at all**: the inbound mirror of `pipe_to` (Cmd ⊕ Cmd, no
Msg origin), bytes flowing socket → tenant-prefix multipart without
entering an activation.

```js
export function onHeaders() {           // fires before any body byte is accepted
  if (!authed(request.headers)) { response.status = 401; return 'unauthorized'; }
  blob.receive({ to: 'onStored' });     // pipe the entire body; zero chunk Msgs
  return next();
}
export function onStored() {            // one completion Msg: { hash, len }
  kv.set(`media/${mxc()}`, { hash: request.result.hash });
  return json({ content_uri: ... });
}
```

Three properties make this clean:

- **`onHeaders` extends an existing mechanism.** The engine already
  picks dispatch shape by export introspection at load (`default` vs
  `onChunk`); "exports `onHeaders` → headers-first dispatch" is one
  more row, not a new system. HTTP/2 flow control makes it
  zero-buffer: hold the stream window closed until the disposition is
  decided, then open it for the pipe — the client is held at the
  door, not buffered in the hallway.
- **S3 multipart natively has commit-gate semantics.** Parts stream
  up eagerly as bytes arrive, but *nothing is externally observable
  until `CompleteMultipartUpload`* — so the complete call is
  commit-gated like any Cmd (L4), and a dropped connection or
  rolled-back activation maps to `AbortMultipartUpload` (L2 abandon
  semantics, for free).
- **Untaped bytes are correct here by the same derivation as
  `pipe_to`**: there is no Msg to record. The input-bytes home is the
  customer object itself; the completion Msg tapes `{hash, len}`,
  which is all replay strictly needs.

**Why `onHeaders` is load-bearing and not a nicety:** without it, the
pipe must be declared from an activation that already carries body
bytes, and the durability gate has pool-homed those bytes first. The
tax is up to 1 MB per streamed upload — and *the whole object* for
bodies under 1 MB, since the buffered `default` path delivers (and
therefore pool-homes) the entire body. Small media — the
high-frequency case — pays 2× without it. With it, the accounting is
exact: bytes the handler's logic depends on are taped; bytes it
doesn't are piped, one PUT, at every object size.

The customer litmus mirrors the existing scope litmus, pointed at
bytes: *does your logic depend on the content of the chunks?* Yes →
`onChunk` + `blob.write` (Case A — you pay the tape, correctly). No →
`onHeaders` + `blob.receive` (Case B — one PUT).

### 3.5.1 P3 as-built (slice A 2026-06-09, slice B 2026-06-10)

**Slice A — the storage half** (`s3-blob-smoke` step 8 against real
S3): `S3BlobStore.createMultipartUpload / uploadPart /
completeMultipartUpload / abortMultipartUpload / copyObject`
(`src/blob/s3.zig`), on a generalized `requestExt` (wire-encoded
query signed verbatim via `query_canonical` so uploadId encoding
can't drift; ETag captured from response headers;
`<Error>`-in-200-body detected on create/complete/copy), plus
`sigv4.sign` extended with `extra_signed_headers` (SigV4 mandates
signing `x-amz-copy-source`). The temp→CAS move is `complete` at
`app-blobs/.uploads/{id}` then server-side `copyObject` to
`app-blobs/{hash}` + delete — zero bytes transit the worker.

**Slice B — the transport half** (`blob_receive_smoke_v2.py` +
`inbound_body_smoke_v2.py`), as built:

- **headers_first h2** (`h2_opts.headers_first`, rewind worker only —
  front door/examples keep the classic contract): server sessions
  run `NGHTTP2_OPT_NO_AUTO_WINDOW_UPDATE`; every body-carrying
  request is emitted into the new `request_receiving` collection at
  the HEADERS frame with the stream's window held shut (`.hold`).
  State is collection membership: `request_receiving` (undecided) →
  `request_buffering` (classic decision) → `request_out` (body
  attached — its body-complete contract is preserved). h2 never
  auto-completes from `request_receiving`, so dispatch shape is
  uniform regardless of body timing (a 1 KiB and a 12 MiB upload to
  the same module take the same path).
- **`onHeaders` dispatch row**: wire activation source
  `inbound_headers = 10`; the worker's disposition point
  (`drainRequestReceiving` → `dispatchOnce`) consults a worker-local
  per-(deployment, module) `onHeaders` export cache — exported →
  `.inbound_headers` activation with an EMPTY body (early 4xx and
  the plan-tier 413 fire before any body byte is accepted; body is
  untaped by construction); not exported (the cached common case) →
  attach-in-place + same-tick classic dispatch, zero hot-path cost.
  First request per module probes (the `RunOutcome.no_onheaders`
  fallback) and fills the cache; deployments are immutable.
- **`blob.receive({to})`** is a connection-scoped PendingFetch
  through the `rove-receive.internal` door — `blob.seal`'s exact
  pattern, so bind-or-drop at handler success, commit-gating via
  `Cmd.http_fetch`, and the held-chain resume machinery are all
  reused verbatim. The worker intercepts the door URL at its two
  commit points (`interpretCmd` + the read-only flush) and arms a
  per-upload driver thread (`src/js/blob_receive.zig`): h2 `.sink`
  mode routes DATA into its queue; it accumulates ≥5 MiB parts,
  hashes incrementally, completes + copies + deletes on END_STREAM,
  aborts on disconnect, and emits ONE terminal `UpstreamFetchEvent`
  (`request.ctx = {hash, len}`) through the FetchEngine's router.
  Flow control is end-to-end: `sweepBodySinks` repays window only as
  the driver drains, so the client's send rate follows the S3 upload
  rate (≤ one window + one 5 MiB part buffer RAM per job; node cap
  64 jobs). Receive-holding chains park with a 15 min deadline
  (zero Msgs ever bump a receive park).
- h1 ingress is unchanged (bodies complete at emission — h1
  streaming can follow, not gate, the h2 path). The h2-layer size
  cap exposure is narrowed but not closed: the per-tenant 413 now
  fires from the declared content-length before buffering;
  a length-less h2 stream still buffers up to the cap before the
  recheck (follow-up: h2-level running-length cap).

## 4. The verbs against the effect-algebra contract

No new singleton: every verb decomposes into Model writes + the
outbound-HTTP Cmd runtime + existing Msg origins + (for sessions) an
ephemeral connection-scoped entity. Durability never leaves its one
home — `seal`/`put`'s commit point is a kv marker (L1, rule 4).

| Verb | Cmd | Msg | Durability | Failure |
|---|---|---|---|---|
| `put` | `_blob/owed/{hash}` marker + PUT | shim `onResult` | durable-intent composition | at-least-once, idempotent via CAS |
| `get` | fetch | result / chunks | ephemeral | at-most-once; miss = 503, client retries |
| `pipe` | fetch ⊕ connection-write | none (no Msg origin) | ephemeral | at-most-once; untaped by derivation |
| `url` | — (pure fn over taped clock) | — | — | n/a |
| `write`/`seal` | part-PUTs + marker at seal | seal result | ephemeral until seal; durable-intent at seal | abandon on disconnect; seal idempotent |
| `receive` | inbound-pipe ⊕ part-PUTs; commit-gated complete | one completion Msg | object durable at complete | abort on disconnect; nothing promised pre-complete |

**Trust boundary.** Unlike `webhook.send.js`, these shims cannot sign
with raw `on.fetch` — SigV4 keys and prefix enforcement cannot live in
forkable customer JS. The shape that preserves rule 4 anyway: the
verbs stay readable JS shims, but they target a **node-local blob
proxy** that signs and enforces `{instance_id}/app-blobs/`. Policy
stays in JavaScript; the credential stays behind a thin trusted door.

## 5. The adopt investigation — why Case A pays twice (code-verified)

The tempting design was *adoption*: inbound bytes are already durable
in tenant object storage before any handler observes them (the
callback-gating invariant), so a streaming put could just retain
pointers into the readset blobs instead of re-uploading. Verified
against the coordinator, **per-request addressability holds but
adoption-by-reference is dead**:

- **Addressable: yes.** Every >16 KB submission gets an exact
  `BodyRef {batch_id, offset, len}` (`coordinator.zig:49`), recorded
  durably in the readset that rides the raft entry
  (`worker_dispatch.zig:2853`). Submission boundary = activation
  boundary (`coordinator.zig:432`).
- **Cross-tenant pool.** Since Phase 5, all workers' and all tenants'
  submissions mix freely in one S3 object under
  `_pool/{batch_id:0>20}` (`coordinator.zig:704`). Adopted ranges
  would point into objects containing other tenants' bytes — presign
  is impossible (a presigned GET authorizes the *object*; Range is
  client-supplied), so every read would proxy forever.
- **Lifecycle coupling.** Pool batches are tape-input storage, scoped
  to tape retention. Media must outlive retention → adoption means
  pinning shared 16 MiB batches (`max_batch_bytes`,
  `coordinator.zig:87`) full of other tenants' expired bytes —
  un-GC-able, un-attributable. And bodies ≤ 16 KB never reach S3 at
  all — they ride inline in the raft entry
  (`INBOUND_INLINE_THRESHOLD`, `worker_dispatch.zig:2844`): nothing
  to adopt.
- **Fragmentation vs S3 copy semantics.** Chunks are ~64 KB–1 MB,
  scattered across drain passes and interleaved within batches; S3
  `UploadPartCopy` requires ≥ 5 MiB per part. Server-side assembly is
  not expressible; GET+re-PUT pays download *plus* upload — worse
  than transport.

What survives is the §3.4 design: the chunk-spool P6 retained-RAM +
`readBody`/`release` hooks feed the multipart with no S3 GET and no
handler re-buffering.

**Post-evidence option (recorded, not planned): inverted homing.**
For Case A streamed uploads, home the bytes at the tenant prefix
*first* and point the readset BodyRef into
`{tenant}/app-blobs/{hash}` — one PUT shared by tape and customer.
Bill: a new BodyRef interpretation (the `NO_BATCH = 0` sentinel
already proves the field is a discriminated union in disguise —
[[feedback_wire_width_vs_interpretation]]), a READSET_VERSION bump,
chunk-dispatch gating degrading to 5 MiB part boundaries, and
`blob.delete` fenced to tape retention. Only worth it if a real
workload is both transform-heavy *and* archive-heavy; Case B already
gives the byte-heavy path one-PUT semantics without any of this.

## 6. Standard-library recipe: sealed segments (`segments.js`)

The first thing every append-heavy app does with this surface is the
universal log-structured move: hot mutable tier + sealed immutable
runs (memtable→SSTable, Kafka segments, raft log+snapshot). It is
**not a primitive** — decomposed it is Model writes + `blob.put` +
cron + the commit gate — so per rule 4 it ships as a readable,
forkable stdlib shim:

- **Hot tail:** recent records as kv rows
  (`timeline/{stream}/{seq} → record`) — addressable, atomic with the
  handler, counted against the kv cap.
- **Seal (cron):** range-read the oldest N rows, serialize with an
  offset table, `blob.put`; in the PUT's `onResult`, write the
  segment index row (`segments/{stream}/{firstSeq} → {hash, count,
  offsets}`) and delete the N hot rows **in one writeset**.
- **Read:** stitch — hot window via kv, older via segment-index
  lookup + `blob.get` + offset slice.

The crash-safety nuance is the design content: a sealed segment is
**durable-class, not cache-class** (unlike derivable snapshots/
indices) — once the hot rows are deleted it is the sole copy past
tape retention. So the delete is gated on the confirmed PUT
(callback-gating, the discipline the platform already has), and the
swap is atomic.

Why it matters beyond convenience: the seal cadence is the knob that
trades kv-cap consumption against byte-ring consumption — the hot
window size *is* the kv bill. An append-heavy app without sealing
eventually hits the kv cap; with it, kv plateaus at the working set
forever. If customers keep forking `segments.js` in the same
direction, that is the promotion signal
([[feedback_compose_from_primitives]]).

**As-built (P4, 2026-06-09).** `globals/segments.js` ships
`append` / `get` / `slice` / `seal` over `_seg/{stream}/…` keys
(NOT platform-reserved — the `_send/` rule), with
`__system/segments_onsealed.mjs` as the swap half (index write +
hot-row deletes, one atomic writeset, strictly after the PUT
confirmed). Deltas from the sketch above: the v1 segment format is a
JSON envelope `{v, stream, first_seq, values: […]}` rather than a
binary offset table — `segments.slice` indexes by `seq − first_seq`,
the 100 MiB arena makes parsing whole segments cheap, and the offset
optimization waits for evidence; sealed reads thread their slicing
info via `blob.get`'s `ctx:` passthrough (added for this) instead of
kv round-trips; overlapping seals converge by construction (same
`first_seq` ⇒ last index write wins and its CAS blob carries a
superset). Hot reads are synchronous; `segments.get` returns
string (hot) / `null` (gone) / `undefined` (sealed — finish in
`{to}` with `segments.slice`).

## 7. Open questions

1. **Delete / GC.** CAS + customer-owned naming means the platform
   cannot know liveness. Candidate: `blob.delete(hash)`, customer
   owns refcounting, metering reconciles from the prefix. Defensible
   day one: no delete at all (media retention forces it eventually;
   eventually ≠ launch). Any delete must be fenced against tape
   retention where the object is an input home (Case B).
2. **Quota enforcement point.** Reject at `put`/`seal`/`receive`
   (before bytes land) — the only placement that strands nothing;
   byte-ring metering reconciles platform-side from prefix listing.
3. **`seal` sync vs Msg.** A synchronous hash requires the runtime to
   gate the response on the final part landing behind the scenes;
   the Msg form (`{to}`) is honest about the wait. Current lean: Msg
   form (shown in §3.4) — consistent with "results arrive as future
   Msgs."
4. **`onHeaders` semantics beyond uploads.** Headers-first dispatch
   is useful for any early-rejection (auth, rate-limit) before
   accepting a body. Decide whether it composes with `default`
   /`onChunk` in one module or is exclusive.
5. **Local-backend fast path.** Single-node / fs-backend deployments
   could short-circuit the proxy; the original spec called this a
   JS-shim choice, not a primitive distinction. Confirm under the
   no-dev-only-paths rule ([[feedback_avoid_dev_only_features]]).

## 8. Phasing

| Phase | Ships | Notes |
|---|---|---|
| P1 ✅ | signing door + `put`/`get`/`url` shims (2026-06-09, `scripts/blob_smoke_v2.py`) | smallest end-to-end slice; covers events, snapshots, small media; `url` unlocks 307-to-presigned downloads |
| P2 ✅ | `write`/`seal` upload sessions (2026-06-09, same smoke, 19/19) | bounded single-PUT sessions (64 MiB cap), NOT multipart — see as-built deltas |
| P3 ✅ | slice A (S3 multipart substrate) 2026-06-09 + slice B (transport + `blob.receive`) 2026-06-10 (`scripts/blob_receive_smoke_v2.py`) | §3.5.1: full Case-B pipe live-proven — 12 MiB streamed byte-exact, zero chunk activations |
| P4 ✅ | `segments.js` stdlib recipe (2026-06-09, smoke step 8, 28/28) | the kv-cap ↔ byte-ring lever; as-built notes in §6 |
| — | byte-ring metering + quota | alongside P1–P3; enforcement points per §7.2 |

Each phase is independently useful; P1 alone un-blocks the Matrix
exercise's event store and media reads.

**P2 as-built deltas.** Sessions are a capped Zig-side buffer (64 MiB,
2/tenant, 120 s idle TTL sweep) on a worker-owned `blob_sessions`
collection, keyed `(tenant, correlation_id)`, sealed with ONE PUT
through the P1 door — S3 multipart (unbounded size, part ETags,
abort lifecycles) deferred until a real >64 MiB case (Synapse's
default media cap is 50 MB, so the reference Matrix deployment
fits). Nothing reaches storage before `seal`, so an abandoned
session is pure RAM reclaim — L2 abandon for free, and no owed
marker: the customer's `{to}` export observing `ok` then writing
its kv index IS the durability commit point. `seal` returns the
hash synchronously (incremental hasher) AND delivers it as
`request.ctx.hash` on the resume. Sources: streamed `on.fetch`
chunks, WS frames, JS-generated bytes — inbound `onChunk` joins
when gap 2.4 (streaming inbound body) lands; the plan's
"RAM-sourced assembly via coordinator `readBody`" applies only to
that future inbound source. Two pre-existing platform gaps P2 fixed
because the session flows were the first to need them: (1) bound
fetch resumes never delivered the fetch's `ctx:` (handler-shape §7
documented it; the install dropped it), (2) fetches issued FROM a
bound-fetch resume were silently discarded (handler-shape §5.3's
chained-fetch pattern; `flushResumeFetches` now binds + submits on
the read-only resume arms, post-commit per L4 — WRITING resumes
that fetch still drop loudly until the commit-gated Cmd path covers
resumes). (An arena bound surfaced here — pure-JS TextDecoder's per-char
garbage OOMing ~139 KB decodes in the then-4 MiB request arena — was
fixed in the same branch: native `_system.textcodec` transcode +
arena raised to 100 MiB.)

**P1 as-built deltas.** The "node-local signing proxy" shipped as a
fetch-engine special-origin interceptor (`fetch_engine.zig`
`rewriteAndSignBlobFetch`): the shims fetch
`http://rove-blob.internal/{hash}`, the engine rewrites + SigV4-signs
in-process — same trust boundary (tenant from `pf.tenant_id`, keys
never in JS), no extra hop, no listener. `blob.pipe` deferred out of
P1: the engine's `pipe_to` disposition was retired in reification
Phase 5 PR-1, and `blob.url` 307-redirect covers the
serve-bytes-to-client case better; revisit with P3 if a real
in-handler pipe case appears. `blob.put` is single-attempt in P1
(marker persists `failed:true` as evidence; no re-fire — the marker
deliberately carries no bytes, §2.5 re-execution recovery is the
follow-up). `_blob/` is deliberately NOT platform-reserved (the
`_send/` rule: the shim writes the marker as customer JS).

## 9. Relation to other docs

- **`effect-algebra.md`** — §3 once marked `blob.put`/`blob.get`
  deferred; this plan was the deferral's exit condition arriving (§3 now
  records the shipped composition). §2.5 (input/output byte asymmetry)
  is the recovery model `put` leans on; §6 scope axes classify every
  verb here.
- **`handler-shape.md`** — the verb-is-scope surface these verbs
  extend; `onHeaders` adds a row to §3's activation table.
- **`architecture/effects-and-handlers.md`** — callback-gating /
  durable-input substrate; the Continuation the sessions park on.
- **`architecture/routing-and-ingress.md`** — `pipe_to` (Pattern B),
  whose inbound mirror is `blob.receive`; the 1 MB ceiling and
  `onChunk` dispatch.
- **`pricing-model.md`** — the kv-cap + byte-ring axes this surface
  makes legible.
- **`tape-minimization.md`** — CAS-extent tape records; why CAS reads
  are nearly free on the tape.
- **`docs/chunk-spool-plan.md`** (folded) — the P6 retained-RAM
  `readBody`/`release` hooks §3.4 builds on.
