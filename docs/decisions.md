# Decisions

A consolidated, durable record of **locked architectural and product
decisions** and **alternatives that were considered and rejected** ("do not
re-propose without new information"). It exists so that finished plans and
status-snapshot memories can be pruned without losing the conclusions they
reached.

Scope and boundaries:

- This is the **committed** decisions log. Sensitive / unreleased product
  strategy lives in a separate memory-only file (not in this repo).
- This complements, and does not replace:
  - **PLAN.md §7** — the canonical considered-and-rejected list for the core
    architecture. Entries here cross-reference it rather than duplicate it.
  - **The as-built architecture references** in `architecture/` (`overview`,
    `consensus-and-storage`, `effects-and-handlers`, `routing-and-ingress`,
    `control-plane`, `deployment-and-logs`, `auth-and-domains`, `observability`),
    plus the customer-facing contracts `effect-algebra.md` + `handler-shape.md`,
    which remain the as-built references for *how* each shipped system works.
    This file records *what was decided and why*, not the mechanics. See
    `README.md` for the full documentation map.
  - **Coding-process feedback** (regression-baseline discipline, "verify 2xx in
    benches", etc.), which lives in the auto-memory `feedback_*` files.
- Performance war-stories with reusable detail (bench tooling, falsified
  hypotheses, commit hashes) stay in their `project_*` perf memories; only their
  *locked conclusions* are summarized here.

Each entry: **Decision · Why · Status/date · Rejected** (where applicable).

---

## 1. Product & naming

### 1.1 Customer product name is rewind.js; engine library stays `rove`
- **Decision**: `rove` = the Zig engine (unchanged). `rewind.js` = the
  customer-facing product (since 2026-05-14). Internal name "Loop46" persists in
  the codebase; the in-tree rename is deliberately deferred and tracked
  separately.
- **Domains**: `*.rewindjs.app` = customer wildcard; `rewindjs.com` = system
  surfaces (via the custom-domain mechanism).
- **Do not** preemptively rewrite internal `Loop46`/`loop46` references as part
  of unrelated work.

### 1.2 Transactional email provider is Resend
- **Decision**: Resend is the transactional-email provider. `email.send` wraps
  `webhook.send` with a Resend API POST (`https://api.resend.com/emails`, Bearer
  auth, JSON `{from,to,subject,html,text}`).
- **Key handling**: API key is platform-provided (env `ROVE_RESEND_KEY`,
  injected by the worker, customer-invisible).
- **Status**: chosen 2026-04-18; unblocks the webhook/email phase (not yet
  built). BYOSMTP override deferred to a paid tier. Gotcha: sending domain must
  be verified before non-onboarding sends.

---

## 2. Storage & consensus

### 2.1 `raft_log` stays on SQLite (do not migrate to kvexp)
- **Decision**: keep `raft_log.zig` on SQLite through and past the kvexp
  cutover. Neither a B-tree (SQLite) nor a CoW B-tree (kvexp) is the right shape
  for a raft log, which wants sequential tail-append + fast prefix-truncation
  after snapshot. A purpose-built segmented log is the eventual target — not yet
  designed.
- **Do not** propose folding `raft_log` into kvexp in a future cutover.

### 2.2 Never hold a write txn across a raft round-trip
- **Decision**: the per-tenant write path must not hold the SQLite/kvexp writer
  open while waiting for raft quorum.
- **Why / Rejected**: the "Stage 5" apply-after-replicate experiment (hold the
  txn through the raft RTT) regressed single-tenant 18.8k→3.7k (−80%) and
  aggregate 82.4k→31.7k (−61%) — holding the WAL writer lock for the ~1–5ms RTT
  serializes per-tenant workers to `batch_size / raft_latency`. Reverted to
  Stage 4 (savepoints per handler, one merged writeset per propose, kvexp
  volatile overlay for rollback). The per-tenant batched-dispatch arc is stable
  at Stage 4.

### 2.3 `journal_mode=DELETE` rejected (stay in WAL)
- **Rejected** 2026-05-11: swapping SQLite to a rollback journal to skip WAL's
  shm coordination. It does 2 fsyncs/commit vs WAL's 1 (1-worker −22%, 1w
  sharded −39%), and on 8 workers `COMMIT` upgrades RESERVED→EXCLUSIVE and fails
  `SQLITE_BUSY` on a shared DB. Do not retry the one-line swap.
- **Deferred escape hatch** (not a replacement): `PRAGMA
  locking_mode=EXCLUSIVE` *while staying in WAL* — viable only once a
  single-connection-per-DB constraint is guaranteed (see 2.4).

### 2.4 Tenant-affinity worker pinning rejected as a throughput lever
- **Rejected**: pinning each tenant to one worker to eliminate cross-thread WAL
  shm contention. The premise was falsified — at realistic multi-tenant fan-out
  (128/256 active tenants) shm contention amortizes (workers naturally rotate
  across tenants), so the redesign solves a non-dominant problem while adding
  ~50µs/request cross-worker routing overhead. Net loss at every tenant count
  (8w hot −9%, sharded −26%, 256 active −33%). Do not retry tenant-affinity as a
  ceiling-raising lever on multi-tenant workloads.

### 2.5 Keep the read fast path (read-only requests never propose to raft)
- **Decision** (user, 2026-05-29): read-only requests commit locally and never
  propose to raft (~101k req/s, scales per-tenant) vs raft-write ~38k (shared
  pipeline). They therefore cannot appear in the raft log, so the replay archive
  is **strong-best-effort by default**; a per-tenant "all-requests-replayable"
  hard guarantee is reserved for real customer demand, not built speculatively.
- **Do not** re-propose dropping the read fast path for the sake of a total
  replay projection. Treat as a PLAN §7-style closed item.

### 2.6 Cluster / raft-KV library shape
- **Decision** (V1 as-built, from the retired `raft-kv-design.md`; the V1
  `Cluster` itself was retired at the V2 cutover — V2 is the spine-free
  `kvlimbs` facade + the consensus `Bridge`, see §10): the `rove-kv`
  `Cluster` was one raft group fronting N pluggable stores, with
  **multiple-envelopes-per-entry atomicity** (`LeaderTxn` for multi-store atomic
  commits). Backend was pluggable (SQLite). Snapshot tick was
  stamp-and-compact across all stores. Learner peer mode + peer-to-peer
  `send_snapshot`. Application-level request routing was registered separately
  from the library. Its two consumers were loop46 and the files-server
  standalone, both retired/V2-ified at the cutover. (The `rove-kv`→`raft-kv`
  module rename did land in V2.)

---

## 3. Effects, durability & the handler model

### 3.1 The handler is `update : (Msg, Ctx) -> (Effects, Cmd Msg)` (TEA)
- **Decision** (shipped, `f231a8e..6c3f60a`, 2026-05-20): the Elm-style frame is
  the literal architecture. Per-entity state lives on rove **components**, not in
  entity-keyed side stores (three were deleted); dispatch is **collection
  membership** (`raft_pending` split into sibling collections
  `raft_pending_response/_cont/_stream`). The three resume engines differ only in
  *how* they apply the Cmd, not in prep/run structure — forcing further
  unification is rejected on readability grounds.

### 3.2 The four effect primitives are reified in code
- **Decision** (effect-reification Phases 0–6 shipped; see
  `architecture/effects-and-handlers.md` + `effect-algebra.md`): every external effect must
  be a *declaration* over four reified primitives (Model, Continuation, Msg
  origins, Cmd runtimes) under `src/js/effect/`, not a hand-rolled subsystem.
  `Cmd` and `Msg` are compiler-enforced tagged unions. Cancelled as part of this
  arc: Phase 4.1.4 `conn_write` (deferred to inbound-WS) and Phase 7
  files-server collapse.

### 3.3 Durability is composed in JavaScript shims, not Zig primitives
- **Decision** (shipped 2026-05-24, `b908953`, net −4.7 kLOC Zig): there is **one
  outbound HTTP primitive** (`http.fetch`). `webhook.send` / `email.send` /
  `retry.*` are JS standard-library shims that compose durability on top of it
  (`kv.set` owed-marker + `http.fetch` + a durable scheduled wake, §3.7). The
  dedicated `http.send` Zig primitive, the schedule envelopes, the leader-local
  `SendDispatch`, and later the per-feature owed sweep were all retired.
- **Inputs durable / outputs derivable**: `blob.put` / `blob.get` are likewise
  **JS shims, not Zig Cmd primitives** — the marker key holds a pointer
  (`{saga_id, seq, call_index, dest_key}`), never the bytes; recovery is
  re-execution against the recorded readset. Decision rule: small+bounded payload
  (webhook body) → body-in-marker; arbitrary size (blob bytes) →
  pointer+re-execution.
- **Load-bearing gotchas** (cost real debugging time):
  1. `_system.*` is unreachable from baked `__system/` modules — use
     `GLOBAL_BUILTINS` / `__rove_*` (e.g. `__rove_resume_if_bound`).
  2. Platform trampolines are wired per `Request` constructor; they do **not**
     auto-wire in `fireFetchEventActivation`.
  3. A `stream:false` fetch must emit exactly **one** event (body + `final:true`
     + terminal).
  4. Customer middleware **must** be skipped for `__system/` modules.
  5. Marker-commit race: an inline fetch could complete before the handler's
     writeset committed via raft. Closed by the commit-gated Cmd buffer
     (effect-reification Phase 4.1.2 `Cmd.http_fetch` staging, shipped
     2026-05-24) — the fetch submits to the FetchEngine only after the batch
     commits. Crash recovery is the send's durable-wake watchdog entry
     (§3.7) — the owed sweep is deleted.

### 3.4 Owed-recovery is a boot-scan (superseded: now the generic `_sched/` promotion pass)
- **Decision** (Option (b), shipped 2026-05-19): at process start, reconstruct
  the in-flight/timer set with a single-pass boot-scan of `_send/owed/` across all
  tenant DBIs (the per-tenant kv write is the authoritative source). Measured
  ~89µs/tenant realistic, ~210µs pessimal → ~0.9–2.2s per 10k tenants; the
  ~1–2s/10k RTO budget is accepted. Mitigation levers (fold the probe into
  `Manifest.init`; shard across workers) are known but deliberately not built —
  escalate only past ~10k tenants/node and re-run `owed_recovery_scan_bench.zig`.
- **Superseded** (durable-wake P5(a), 2026-06-10): the `_send/owed/`-specific
  sweep is deleted; reconstruction is the generic durable-wake promotion pass
  over `_sched/` (§3.7) plus a per-send watchdog wake entry. The measured scan
  costs and the rejected alternatives below carry over unchanged — the
  promotion pass is the same single-pass walk, generalized.
- **Rejected**: (a) lazy recover-on-tenant-open — silently drops a quiet
  tenant's cron/delayed sends; (c) "snapshot-in-one-shot" — illusory in kvexp,
  where walking the snapshot ≡ walking the DBIs ≡ the boot-scan. The only way to
  avoid the per-tenant walk is a central index (rejected: cross-tenant hot spot)
  or a second raft snapshot.

### 3.5 Subscriptions & streaming gaps (shipped semantics)
- **Subscriptions (gap 2.1, shipped; cron half retired)**: chain origins
  without an inbound request — kv-react / boot. The third origin (manifest
  `kind=cron`, a 1 Hz non-raft-replicated interval clock) retired with
  durable-wake P5(b) — recurrence is the durable `cron()` verb. The boot marker
  **must** be injected into the handler's writeset *before* the handler runs
  (post-handler injection hits a conflict). Defer in-loop kv-react fires to a
  post-loop drain (avoid iterate-while-modify). Use `JS_NewBigUint64` for `u64 >
  2^63` (deployment ids).
- **Backpressure (gap 2.2, shipped; wake half superseded)**: surfaces are
  bounded — originally a K=32 wake-accumulator ring with a `lost_oldest`
  counter, replaced 2026-07-11 by per-arm fired state (§3.10 — nothing to
  accumulate, nothing to overflow), and a 256 KB StreamChunks soft cap with
  drop-newest + `dropped_chunks`. Caps are deliberately hard-coded; per-tenant
  configurability is deferred to an operator hook on demand.
- **Streaming `http.fetch` (gap 2.3, shipped)**: Pattern A (`on_chunk`) fires a
  handler activation per chunk; the last carries `final: true`. **`pipe_to`
  (Pattern B) was retired in Phase 5 PR-1** — the three-variant
  `chunk`/`end`/`pipe_done` shape collapsed into one chunk-with-`final` kind, so
  `on_chunk` is the only streaming path and there is no longer any
  structurally-untaped stream (chunk bytes tape by reference — §3.9).

### 3.6 Per-chain tape cap removed; retention is the right axis
- **Decision** (2026-05-26): the §6 per-saga tape cap was removed. Its
  worst-case (a single chain emitting hundreds of thousands of small
  activations) is already bounded by sequential commit latency (~ms/activation),
  while aggregate traffic outpaces any single chain by 2–3 orders of magnitude.
  The cap traded a small bound for node-wide mutex traffic on the dispatch hot
  path. Per-tenant retention/sampling (a deferred `tape_mode` knob) is the
  correct lever — see the retention/GC design, issue #91 (the `tape_mode` lever).

### 3.7 Durable scheduled wake: one-shot, absolute-time, at-least-once *firing*
- **Decision** (gap 2.6, P0–P7 shipped in full 2026-06-10): the platform's only
  deferred-fire mechanism is a durable scheduled wake — `durable_wake` is a Msg
  origin like any other, and wake records are ordinary envelope-0 Model keys
  (`_sched/by_id/` + `_sched/by_time/`), not a second store. One-shot
  **absolute-time**, not interval-cron: webhook backoff needs irregular fire
  times an interval can't express; recurrence is a one-shot that re-arms itself
  (the `cron()` verb is sugar over it). Webhook / email / retry / durable cron /
  delayed jobs / debounce all became libraries over this one origin; the
  per-feature Zig sweeps (`sweepOwedRetries*`, `CronState` +
  `sweepCronSubscriptions`) are deleted.
- **Contract is at-least-once *firing*, not completion**: the wake guarantees
  the handler *runs*; retry **policy** (attempts, backoff) is a composition →
  JS; retry **budget** (rate, outstanding) is a resource bound → engine caps
  (`SCHED_MAX_OUTSTANDING` / `SCHED_MAX_FIRES_PER_TICK` / `SCHED_MAX_MSG_BYTES`,
  all fail-loud). Keeps the no-retry-kernel-in-Zig posture of §3.3.
- **Locus**: the engine keeps exactly **one** durable next-fire watermark per
  tenant (`TenantSlot.next_wake_ns`), reachable only via capability-scoped
  builtins (`__rove_set_wake` / `__rove_fire_wake`, `is_system_module`-gated);
  the queue / ordering / fan-out lives in the baked `scheduler` JS lib
  (ordinary taped kv). Customer surface is `scheduler.at/after/cancel/get` +
  `cron()`.
- **The marker-commit-race lesson, again**: a freshly-scheduled wake's
  watermark must be lowered from **committed** state, never from the handler
  that called `at()` — the bootstrap is a direct watermark-lower in the commit
  arm (`noteCommittedSchedWrites`), not a volatile set-on-call.
- **Manifest `kind=cron` retired outright** (not re-platformed under the hood):
  a `kind=cron` spec.json fails the deploy loudly; sub-minute intervals are a
  self-re-arming `scheduler.in` seeded from any handler activation
  (`onBoot`/`kind=boot` retired 2026-07-05 — unused; registrations are
  idempotent by key and `_sched/*` entries survive deploys)
  (`scripts/smoke/scheduler_heartbeat_smoke_v2.py` is the recipe).
- **Rejected**: a many-timer engine index (queue lives in the JS lib);
  at-least-once *completion* (engine absorbs the retry kernel); interval-cron
  as the primitive; bring-your-own scheduler override (deferred until a
  customer asks).
- **Gotcha that cost real debugging**: `pending_fetches` was null on every
  `runFire` / cont-resume / stream-resume path, so a fetch issued from a wake,
  subscription, or chained activation was *silently dropped* — masked for
  months by the old owed sweep re-driving the marker. Every fire/resume origin
  now owns a commit-gated fetch accumulator; deleting a safety net is what
  surfaced the class.

### 3.8 Customer blob storage: CAS-only, the Case A/B split, adoption rejected
- **Decision** (P1–P4 shipped 2026-06-09/10; mechanics in
  `architecture/routing-and-ingress.md`, surface in `handler-shape.md`): the
  customer object store is **content-addressed only** —
  `…{instance_id}/app-blobs/{hash}`, no names in the store; the naming layer
  (`media/{id} → hash`) is the customer's kv, where it is transactional and
  replicated. Kills overwrite semantics, key collisions, LIST, and
  read-after-write naming races at birth; dedup falls out free; replay records
  the hash, not the bytes. The doctrine: **kv is for state you mutate; the
  object store is for facts you accumulate** — the same statement as the two
  pricing axes (kv hard-cap + byte-ring).
- **The streaming-upload litmus is the scope litmus pointed at bytes**: does
  your logic depend on the chunk content? Yes → `onChunk` + `blob.write`/`seal`
  (Case A — bytes are taped, correctly: the handler observed them). No →
  `onHeaders` + `blob.receive` (Case B — the inbound mirror of `pipe_to`:
  no chunk Msgs at all, bytes flow socket→multipart untaped *by derivation*,
  one PUT at every object size; the completion Msg tapes `{hash, len}`).
  `onHeaders` is load-bearing, not a nicety: without it the durability gate
  pool-homes up to the whole body first, and small media pays 2×.
- **Rejected — adoption-by-reference** (code-verified against the
  coordinator): retaining readset pool bytes as the customer object is dead on
  four counts — the cross-tenant `_pool/` batches make presign impossible (a
  presigned GET authorizes the object; Range is client-supplied); media must
  outlive tape retention → pinning shared batches of other tenants' expired
  bytes; bodies ≤ 16 KB ride inline in the raft entry, nothing to adopt; and
  ~64 KB–1 MB scattered chunks can't meet `UploadPartCopy`'s 5 MiB floor.
  Recorded post-evidence option (not planned): inverted homing — tenant-prefix
  first, BodyRef points in — only if a real workload is both transform-heavy
  *and* archive-heavy.
- **Trust boundary**: SigV4 keys and prefix enforcement cannot live in
  forkable customer JS — the verbs stay readable shims targeting an in-process
  signing interceptor (`rove-blob.internal` / `rove-receive.internal`), not a
  proxy hop. `_blob/` is deliberately **not** platform-reserved (the `_send/`
  rule: the shim writes its marker as customer JS).
- **Deliberately bounded**: sessions are a 64 MiB single-PUT buffer (2/tenant,
  120 s idle TTL) — S3 multipart for `seal` is deferred until a real > 64 MiB
  case (Synapse's default media cap is 50 MB). `blob.pipe` deferred out
  (`pipe_to` disposition retired; `blob.url`'s 307-to-presigned covers
  serve-bytes-to-client). `blob.put` is single-attempt (marker persists
  `failed:true`; §2.5 re-execution recovery is the follow-up).
- **`segments.js` is a stdlib recipe, not a primitive** (rule 4): hot kv tail +
  sealed immutable CAS segments; the seal cadence is the knob trading kv-cap
  against byte-ring consumption. The design content is crash-safety: a sealed
  segment is **durable-class, not cache-class** — once the hot rows are
  deleted it is the sole copy past tape retention, so the hot-row delete is
  gated on the confirmed PUT and the index-write+delete swap is one atomic
  writeset. Customers forking it in the same direction is the promotion
  signal.
- **Open (deliberately undecided)**: delete/GC (candidate `blob.delete(hash)`,
  customer-owned refcounting; defensible day one: no delete — any delete must
  be fenced against tape retention where the object is an input home); quota
  enforcement at `put`/`seal`/`receive` before bytes land; whether `onHeaders`
  composes with `default`/`onChunk` in one module or is exclusive.

### 3.8 Outbound gate wired; customer fetches do not follow redirects
- **Decision** (shipped 2026-06-11; closes the PLAN §2.6 wiring gap): every
  customer-supplied outbound URL passes `rove-ssrf.checkUrl` per attempt
  (scheme = `https` / TLS-always, every resolved address blocklist-checked),
  the full vetted address set is pinned via `CURLOPT_RESOLVE` (rebinding
  defense without losing curl's multi-address connect fallback), transfers are
  protocol-restricted to `http,https`, and **`http.fetch` does not follow
  redirects** — the handler receives the 3xx and composes its own follow,
  which re-enters the gate as a fresh fetch. As-built:
  `architecture/routing-and-ingress.md` "Outbound policy gate".
- **Why redirects-off**: libcurl-internal redirect hops bypass the gate (a
  public URL can 302 to the metadata IP). Surfacing the 3xx is the one safe
  semantic (per the simplicity/safety default); auto-follow-with-per-hop-gate
  is a later opt-in if real demand appears. The trusted `rove-blob.internal`
  door keeps following (platform-controlled URL; S3 307s).
- **Test hatch**: `REWIND_UNSAFE_OUTBOUND=1` env relaxes only loopback +
  TLS-always for smoke topologies (metadata range unconditionally blocked);
  there is no production relax knob.
- **Rejected**: first-address-only pinning — kills the v6→v4 connect fallback
  (`*.localhost` resolves to `::1` first; a v4-only listener then refuses) —
  the gate vets ALL addresses, so pinning all is strictly safer AND compatible.

### 3.8b Third-party egress is a paid capability, metered on every path
- **Decision** (2026-08-09, rove#336): a plan either grants third-party
  egress or it does not (`RateLimitCaps.outbound_enabled`), checked before
  any rate bucket. **The free tier does not get outbound.** Payment is the
  identity signal that gates it; the refusal carries its own code
  (`outbound_not_enabled`) and no Retry-After, because no delay changes the
  answer. As-built: `architecture/control-plane.md` "Outbound admission".
- **Why not a ceiling alone**: a rate bound only bounds the *rate* of abuse.
  Outbound is the one capability whose victim is a third party, and a tenant
  costs an email address to create, so the useful question is admission, not
  throughput. The ceilings remain, and bound a tenant that *has* been granted
  outbound.
- **Why not self-serve opt-in**: a toggle the customer flips is only a gate if
  it is coupled to a signal a spammer cannot cheaply forge. Without a card on
  file (Stripe track, #310/#312) there is no such signal, so an opt-in buys
  one click. When that signal exists, "card on file → outbound granted"
  becomes a dashboard policy writing an override — no engine change.
- **The exemption that made the quota opt-in**: enforcement had exempted
  `is_system_module`, meaning "the platform re-issuing an already-admitted
  send". But that flag comes from the module path, so it is equally true of a
  FIRST fire the tenant armed itself — via `webhook.send({at})`, or by
  hand-writing the `_send/`+`_sched/` rows (both prefixes are
  customer-writable by design, §3.3). Nothing at that seam can distinguish an
  admitted send from an invented one, because the marker is customer data. So
  **every** third-party egress is charged to the tenant that owns the
  activation, retries included; only `*.internal` doors (storage / control
  plane) are exempt. A refused deferred fire is caught by
  `__system/webhook_fire` and backed off on its watchdog — an uncaught throw
  there rolls back the scheduler entry's own cleanup and re-fires at 1 Hz.
- **Cost accepted**: a free tenant cannot act as an OAuth/OIDC relying party,
  send webhooks, or send email. A tier wanting the middle ground (enough for
  federated login, worthless for bulk) grants `outbound_enabled` with a low
  daily ceiling — a one-line table edit, not a new mechanism.

### 3.8c The platform's own tenants are not customers
- **Decision** (2026-08-09): the reserved singletons (`__admin__`, `__auth__`,
  `__replay__`) resolve to a `platform` tier when the CP holds no plan blob,
  rather than to free. They run the dashboard, the identity provider and the
  replay arena; a customer-facing abuse limit landing on one is an outage, not
  a bound — `__auth__` is an OIDC relying party, so free-tier outbound-off
  would have taken the login path down.
- **Why derived from the id**: nothing writes a plan blob at provision, so
  "no blob" is the normal state. A rule that depends on an operator running
  `plan set` after every genesis is a rule that breaks on the next genesis.
  The set is closed against customers (`__…__` fails the DNS-label spec every
  customer id is validated against), so resolving a privilege from a name
  opens nothing. An explicit blob still wins.
- **Accepted trade**: our own apps stop dogfooding the free tier's limits. It
  was accidental coverage; deliberate limit exercise belongs in the smokes and
  the conformance corpus, not in whether prod happens to trip.
- **Not covered**: first-party tenants that are *not* reserved ids
  (`marketing`, `docs`, `registry`, `replay`, `agent-sample`) are ordinary
  tenants and stay on free. None of the operator-kind ones make handler
  outbound calls; `agent-sample` (an example tenant) does, and needs an
  explicit plan to keep working.

### 3.9 The minimal tape: four record kinds
- **Decision** (2026-05-26, §3–§5 shipped; consolidated here when
  `tape-minimization.md` was retired): a deterministic replay tape records
  only inputs that re-execution *cannot* reproduce. Replay re-runs the
  handler, so writes (`kv.set`/`.delete`) are outputs (re-issued by
  re-running) and own-reads (a `.get` of a key in the same activation's
  writeset) are not taped. What remains collapses onto **four record kinds**:
  - **read set** — foreign `kv` gets/prefixes resolving to pre-activation
    committed state, plus the read-taped inbound request surface
    (`request_reads`, §4.6); recorded inline when small.
  - **timestamp** — the per-request `timestamp_ns` scalar; a clock read is
    genuinely external, neither generative nor referential. `Date.now()` /
    `new Date()` are pinned per-request (arenajs `JS_SetDateNow`).
  - **seed** — one per-request PRNG seed; `Math.random` / `crypto.*` draws
    are recomputed by re-seeding (`JS_SetRandomSeed`), not recorded per-draw.
    Safe because the WASM replay engine runs rove's *own* JS host compiled to
    WASM, so the same PRNG executes in lockstep (engine/PRNG version pinned on
    the tape header).
  - **CAS extent** — `{address, offset, length}` for bytes that live in a
    content-addressed store; the tape carries the pointer. `module` always
    used this (it records a bytecode *hash*); a large kv value or a streamed
    fetch chunk over the inline threshold becomes one too.
- **Tape-by-reference for streamed bytes is shipped, not a future design.**
  `http.fetch` response chunks over the inline threshold PUT to S3 `_pool/`
  and the `fetch_responses` channel records a `BodyRef{batch_id, offset, len}`
  extent (`rove-bodies`); `seq` + `bytes_before` give the chunk-boundary list
  a streamed replay needs. This is the §3.5 `on_chunk` path — and since
  `pipe_to` was retired (Phase 5 PR-1, see §3.5 note), there is no longer any
  structurally-untaped streaming path. The one remaining piece is **pinning
  the referenced `_pool/` bytes against GC** for the tape's lifetime —
  tracked in issue #91 (input-home pinning), not here.
- **LLM-stream replay** (the worst CAS-extent case: non-reproducible by
  re-execution, re-calling the API costs money and returns different tokens)
  is captured by this same `on_chunk` + `BodyRef` path; making it an explicit
  billed opt-in is deferred to a real LLM-stream customer.
- Wire: `READSET_VERSION` is `7` (`src/tape/root.zig`); channels are `kv` +
  `module` + `fetch_responses` + `trigger_payload` + `request_reads`.

### 3.10 Wake resumes surface the fired prefix, never matched keys

**Decision (2026-07-11, issue #8).** An `after.kv`/`after.ms` resume tells the
handler **which watch fired** — `request.activation.wakes[]` carries one
`{kind:"kv", prefix, firedAt:<ms>}` entry per fired arm (the armed prefix,
verbatim) plus `{kind:"timer", firedAt:<ms>}` — and never the matched keys,
ops, or values. `onWake` stays a pure edge ("go look") wake: the handler
re-reads authoritative `kv` under the fired prefix. Identical on all three
resume paths (streaming chain, buffered held `next()`, held WebSocket) and in
the sim. Internals follow the contract: fired state is a per-arm timestamp on
`StreamWakes.kv_prefixes` (`KvArm.fired_at_ns`) + a scalar `timer_fired_ns` —
the K=32 `PendingWakes` key ring, its drop-oldest overflow, and the
`overflow.lost_oldest` JS surface are deleted.

**Rejected: delivering matched keys** (the pre-2026-07-11 streaming-path
behavior, and what handler-shape.md promised). Three reasons:
1. **It was best-effort by construction** — the ring overflowed under a match
   burst and the handler had to check `lost_oldest` and re-snapshot anyway, so
   keys were a hint that silently went incomplete exactly when they were
   interesting. Every correct handler needed the prefix-rescan fallback; the
   fast path was an attractive nuisance. A fired-prefix bit is always
   complete — one safe semantic instead of a fast path + mandatory fallback.
2. **Cost** — a key dup per matched write per parked chain on the kv fan-out
   path; prefix-fired is a timestamp stamp, no allocation.
3. **Bounded activation input** — `wakes[]` is part of the activation's Msg;
   prefixes bound it by the number of arms, keys made it proportional to
   matched writes.

---

## 4. Handler surface

### 4.1 One streaming surface: `stream.*` / `on.*` / `next`
- **Decision** (handler-surface redesign, shipped 2026-06-03; see
  `handler-shape.md`): **verb is scope, output is a commit-gated effect, return
  is a disposition.** `stream.*` / `on.*` are current-connection effects;
  `webhook.send` / `schedule` / `cron` are connectionless. Return is a terminal
  body or `next({ctx?})`. The response head is the **ambient `response` global**,
  not a return argument. Dispatch is by named export keyed on activation kind
  (`onWake` / `onDisconnect` / `onFetchResult` / `onFetchChunk` / `onFetchDone` /
  `onSubscription` / default; `onCron` retired with durable-wake, `onBoot` retired 2026-07-05 (unused)
  P5(b); `{on}` overrides). The
  `stream` pipeline is unchanged — only the entry trigger, head, and disposition
  changed. The old `bind:true` / `stream`-return-verb / `detach` framings are
  retired.

### 4.2 `on.fetch` is connection-scoped by construction; inert if not held
- **Decision** (auto-bind shipped 2026-05-29 as `http.fetch`+`detach`; reshaped
  to `on.fetch` 2026-06-03): a held handler's `on.fetch` binds to the held chain
  by construction — there is no opt-out flag (`detach` deleted, `bind:true`
  deleted before it), and a **non-held `on.fetch` is dropped inert** (no unbound
  fire; connectionless outbound is `webhook.send` only — user-confirmed). The
  customer `http.fetch` spelling is retired; `_system.http.fetch` remains the
  internal primitive `webhook.send` / `http.subscribe` compose over, and it
  never auto-binds. Registration happens at the **handler-success seam** (only
  there is held-vs-terminal known). Gotchas: `applyWriteSet` is leader-skipped
  so only inbound H2 dispatch sets the `pending_fetches` accumulator; the
  system fetch is excluded from auto-bind via `bound_send_id.len==0` to avoid
  stealing chunks from `__system/webhook_onresult`.
- **Rejected**: firing a non-held `on.fetch` as an unbound chain (the pre-3c
  auto-bind seam's behavior) — "inert if not held" keeps the verb's meaning
  scope-pure; and keeping a connectionless *transient* fetch primitive — the
  only genuine niche (loss-tolerant high-volume beacons) had no demonstrated
  demand, and `webhook.send` is durable-by-default.

### 4.3 Public APIs are JS shims; native hooks hide under `_system.*`
- **Decision** (shipped 2026-05-16): all Zig-provided native hooks move under the
  undocumented `_system.*` namespace; all customer-facing APIs are doc-commented
  JS shims in `globals/`; docs are extracted from the shim JSDoc. The shim-cost
  objection is empirically dead — measured worst case (200 `kv.get`/req through
  the JS wrapper, 3-node TLS+raft) is **0.00% overhead**. **Shim everything; do
  not dual-expose hot primitives.** `_system` is deleted after the native shims
  capture their closures and is baked out of the snapshot, so customer code
  cannot name it. Honest exceptions: `Date.now`/`Math.random` (intrinsic
  overrides) and `request`/`response`/`session` (data shapes).

### 4.4 `globals/*.js` shims must be IIFE-wrapped (load-bearing)
- A bare top-level `function` + `Object.assign` corrupts the arenajs base-
  snapshot freeze (segfault in `__JS_FindAtom` at the next live request, with
  green unit tests). Every shim must be `(function(){ … globalThis.X = … })()`.
  (Kept as an active gotcha memory; recorded here because it is non-obvious and
  must be enforced on every new shim.)

### 4.5 The `{fn,args}`/`?fn=` RPC envelope is retired — dispatch is one semantic
- **Decision** (2026-06-11): the platform invokes exactly ONE export per
  activation — the activation kind's conventional export (handler-shape §3) or
  the resume path's first-class target. The former platform-level dispatch
  envelope (`?fn=name&args=` query / `{"fn":…,"args":[…]}` POST body) is
  DELETED: `request.query` and `request.body` are opaque payload the engine
  never interprets. Named-function routing is handler JS — the `rpc({...})`
  recipe (handler-shape §3.1); the `__admin__` dashboard handler
  (`web/admin/index.mjs`) is the dogfood implementation, and the dashboard's
  HTTP wire shapes are unchanged.
- **Why**: (a) one invocation semantic, not two; (b) the envelope let body
  bytes influence execution NATIVELY (rpc_dispatch parsed `{fn,args}` out of
  the body), which is the one hole in the read-taping determinism model — a
  handler call shaped by a body the tape can't see as a read. With dispatch in
  JS, the shim's `request.query`/`request.body` reads are taped like any other
  input. This is the precursor the read-taped-request-surface slice is gated
  on; (c) the old internal resume targeting synthesized `{"fn":"<name>"…}`
  JSON bodies by string-format — an escaping hazard.
- **Internal resume targeting is first-class**: `Request.fn_override` +
  `Request.fn_args_json` (positional ctx/outcome args), set by the resume
  engines (send-callback / wake / bound-fetch chunk / subscription / chained
  dispatch). No synthetic `?fn=` queries or envelope bodies anywhere; the
  no-target callback form still carries the plain `{ctx,outcome}` body the
  default export reads.
- **Rejected**: keeping the envelope alongside read-taping by recording a
  `dispatch_call` tape kind (papers over the hole and parks a wire
  discriminator we planned to delete); auto-wrapping smoke handlers in the
  deploy helper (hidden magic — smokes opt in explicitly via
  `smoke_lib_v2.rpc_wrap`).

### 4.6 GDPR-safe request capture = read-recording; masked `request.ip` + `unmaskedIp()`
- **Decision** (2026-06-11): replay determinism requires capturing every
  request input the handler can branch on — and **redaction is structurally
  impossible** (a redacted input replays differently). GDPR safety therefore
  comes from **data minimization by read-recording**: the request surface is
  lazy accessors that record into the `request_reads` tape channel on first
  access. Header **names** record unconditionally per activation (so
  `Object.keys` replays); header **values** / the cookie header / the body /
  the ip surfaces record only when read. The tape stores exactly what the code
  observed, nothing else.
- **Body is reference-lazy, never storage-lazy**: the pre-dispatch durability
  gate (pool submit / raft-inline) is unconditional; if the handler never read
  `request.body`, `Readset.elideUnreadBody` drops the trigger_payload entry +
  `request_body_bytes`, so the replay record holds no pointer to the bytes.
  Unreferenced pool bytes age out with the pool lifecycle. **Chunk activations
  are exempt**: the chunk payload IS the activation's Msg (the gap-2.4
  chunk-tape record), `request.body` there is an eagerly-defined binary
  Uint8Array (not the recording getter — and the define must be
  `JS_DefinePropertyValueStr`, a [[Set]] silently no-ops against the
  setter-less accessor), so the worker sets `body_read` structurally at the
  chunk-append sites and the entry always survives.
- **Client IP**: the transport headers (`x-forwarded-for`, `x-real-ip`,
  `cf-connecting-ip`, `forwarded`) are stripped from `request.headers` (same
  mechanism as pseudo-headers). `request.ip` returns the **masked** IP (IPv4
  last octet zeroed; IPv6 /48) derived from `cf-connecting-ip` else the
  rightmost (edge-appended, spoof-resistant) XFF entry. The raw IP is
  `request.unmaskedIp()` — a *method*: the call is the customer's explicit
  controller-responsibility moment, and it puts the raw IP on their tape.
  Stripping is what makes the friction real — with XFF visible, everyone
  would just read the header.
- **Replay divergence is loud**: replay reading anything unrecorded throws
  `REPLAY DIVERGENCE`, never silently `undefined` (the replay epilogue is
  `web/replay/_static/request-replay.mjs`; the entry export is invoked via
  arenajs's `__arena_entry_ns()` — appended code cannot otherwise reach an
  anonymous `export default`, and self-imports diverge from the module tape).
- **Retention + encryption duties remain** for whatever WAS recorded (cookies,
  auth headers, raw IPs the handler read): per-tenant S3 prefix isolation
  exists; page-level encryption at rest is the locked direction (§7); a
  bounded retention window on log-blobs is the outstanding piece of the
  GDPR-processor story.
- **Deferred**: read-flagging `fetch_chunk`'s `request.activation.bytes`
  (needs keep-entry-drop-bytes partial elision — the fetch_responses entry
  doubles as the activation event record; `TODO(read-taping)` at
  `worker_log.captureTapesWithActivation`).
- **Rejected**: capture-all-visible headers (stores cookies/auth even when
  unread — weakest minimization); header-value redaction/allowlists (breaks
  replay determinism); a separate per-tenant "don't capture IPs" config knob
  (the read-recording model makes it the handler-code author's explicit,
  auditable choice instead).

### 4.6b A platform credential is never handler-readable
- **The rule**: on a replay platform, **a handler-readable input is a recorded
  input**. Redaction is not available as a mitigation (§4.6 — a redacted input
  replays differently), so the only lever is what a handler can reach at all.
  A *platform* credential — as opposed to a tenant's own application auth —
  must therefore not be reachable from any handler surface.
- **The pattern, generalized from `request.ip`**: **strip** the raw channel from
  the ambient surface, **derive** an ergonomic lower-fidelity value, and offer
  raw only through a deliberate **escalation** that tapes the escalation. Part
  one is the load-bearing part: with the raw channel visible, everyone reads it.
- **Applied to the operator root token**: `authorization` is stripped from
  `request.headers` on a platform-bound handler
  (`reserved_headers.zig` PLATFORM_CREDENTIAL_HEADERS), and the worker — which
  already holds both the header and the secret — computes the verdict and
  exposes it as **`request.rewind.isRoot`**, taped as
  `RequestReadKind.root_verdict`. There is **no escalation rung**: unlike an IP,
  nothing legitimately consumes the raw bearer, so the ladder collapses to one
  and the credential never becomes a JS string.
- **Not a re-proposal of §4.6's rejected redaction**: nothing is redacted. The
  *shape of the input changes* so the secret was never an input — the boolean is
  a complete, faithful, recorded input that replay serves exactly. Same move as
  stripping XFF.
- **Retired**: `platform.auth.checkRootToken(token)`. A verb taking the bearer
  means the handler holds the bearer, and a handler holds it by reading
  `request.headers` — which tapes it. The verb's disappearance is the fix, not a
  cleanup after it.
- **Scope**: customer tenants are unaffected; a tenant's own `authorization`
  header stays readable and stays that tenant's controller responsibility per
  §4.6. This is about the platform's credential on the platform's tape.
- **Where it comes up next**: any future credential reaching a handler surface —
  e.g. the `services-token` if `/_system/*` ever grows a JS path. Compute the
  verdict, expose the verdict.

### 4.6c Operator authority is resolved at login, so granting it needs a re-login (2026-08-09)
- **The rule**: an OIDC session's `is_root` is computed **once**, when the RP
  mints the session (`@rewind/oidc`: `kv.get(operator_prefix + sha256(sub)) !=
  null`), and frozen into `_rp/sess/{sid}`. Adding someone to the operator
  allowlist therefore has **no effect on their existing sessions** — they must
  log in again. Accepted deliberately.
- **Why not re-evaluate per request**: authority would then cost a kv read on
  every request to every operator-gated surface, to track a list that changes
  a handful of times in a platform's life. The session already carries `sub`
  and an expiry; `is_root` rides the same lifetime as the rest of what the
  session asserts, which is the consistent story rather than one field that
  silently means something newer than its neighbours.
- **The cost, stated plainly**: granting operator authority is not instant, and
  the failure mode is confusing rather than loud — a freshly-allowlisted
  operator sees ordinary-customer 403s, not an error that names the cause. The
  mitigation is documentation at the point of configuration (the
  `operator_prefix` docs) plus the re-login instruction wherever the allowlist
  is edited, NOT a shorter session TTL.
- **The direction it does NOT license**: *revoking* authority is the asymmetric
  half — removing someone from the allowlist likewise leaves their live session
  operator until it expires. Revocation that must take effect immediately needs
  session invalidation (drop `_rp/sess/*` for that `sub`), which is a different
  mechanism from this one and is not built. Decide it when a real revocation
  requirement appears; do not reach for per-request evaluation to get it.

### 4.7 One effect-result surface — flattened, no `request.result`
- **Partially superseded by §4.9** (2026-06-15): the flatten-the-result decision
  stands, but where the *threaded ctx* and *delivery metadata* live changed —
  §4.7 put both on `request.ctx` (as `{context, attempts, error, id, headers,
  hash}`); §4.9 makes `request.ctx` the **bare** threaded value and moves the
  metadata to `request.activation.*`. Read §4.9 for the current contract.
- **Decision** (2026-06-15): every effect-result resume — a bound `on.fetch` /
  `blob.get` (held chain) **and** a connectionless `webhook.send` / `blob.put` /
  `retry` `on_result` callback — presents the result the **same** way: the
  response bytes on `request.body`, `request.status` / `request.done` at
  the **top level** (`status` is the single success signal — `200 ≤ status
  < 300` is ok, `status === 0` is a hard transport failure; there is no
  derived `request.ok`, removed in issue #7 as redundant + drift-prone),
  and the echoed customer `context` +
  per-path delivery metadata (`attempts`, `error`, `id`, `headers`, blob `hash`)
  on `request.ctx`. **`request.result` does not exist** in any path — it was a
  doc fiction referenced in ~6 sites and implemented nowhere.
- **Why**: the surface had drifted into two real shapes — the bound path was
  already flattened (`request.body` + top-level status, the shipped/verified
  `onFetchChunk` contract), while the connectionless `on_result` arrived as a
  nested `JSON.parse(request.body).ctx.result` envelope. Two shapes for one
  concept is the "converge to one pattern" smell; the docs papering it with a
  third, non-existent `request.result` made it worse. The bound shape won
  because it's the one customers already use and the only one that also models
  streaming chunks.
- **Mechanism**: the `on_result` hop is a `.send_callback` activation whose body
  is `{"ctx":{result, context}}`. The runtime (`globals.zig`) detects that
  shape (a `.ctx.result` object, with no top-level `outcome` — which
  distinguishes it from the §13 held-sync `{ctx, outcome}` resume and from
  `webhook_onresult`'s own self-hops, which carry no `result`) and hoists it
  onto the flattened surface. No new envelope type, no marker. The internal
  shims (`oidc`/`segments_onsealed`/…) that consume a result were migrated to
  read the flattened surface — they are not back-compat-frozen (pre-real-user).
- **Rejected**: making `request.result` real (a second way to read the same
  thing — option-multiplication); standardizing on `request.ctx.result` (keeps
  a `result` indirection the bound path never had). Verified e2e by the webhook,
  webhook-recovery (durable wake), and blob+segments smokes + dispatcher unit
  tests.

### 4.9 One ctx convention — `request.ctx` for every `next()` continuation (Endpoint A)
- **Decision** (2026-06-15): there is **one** way an `on*` handler reads the state
  threaded into it. Every activation that is a continuation of a prior
  `next({ctx})` on the same chain reads that payload as **`request.ctx`**;
  results (effect responses, callee outcomes) flatten onto **`request.body`** +
  top-level **`request.status`/`.ok`/`.done`**; and per-activation metadata
  (delivery `attempts`/`error`/`id`/`headers`, blob `hash`, the wake `wakes[]`)
  lives on **`request.activation.*`**. The single rule: **`request.ctx` = what you
  threaded · `request.body`/`.status` = the result · `request.activation` = why/how
  this activation fired.** `request.ctx` is simply `undefined` on the first
  activation of a chain (nothing threaded yet) and on a standalone scheduled
  `durable_wake` (it carries `request.activation.msg`, not a threaded ctx).
- **Why**: the surface had drifted into **three** shapes for the same idea. (1)
  `request.ctx` for fetch resumes / `onChunk` / `send_callback`. (2) A **positional
  argument** `onWake(ctx)` for wakes — and only over WS; the SSE wake path passed
  a `{"ctx":…}` body that nothing lifted, so `onWake(ctx)` silently got `undefined`
  there. (3) A positional `onResult(ctx, outcome)` for the §13/§6.4 held-sync
  resume, with the result as a second arg. Three spellings of "the runtime handed
  me something" is the converge-to-one-pattern smell; it also blocked threading
  transient per-frame state through a held WS `onMessage` without a kv round-trip
  (the browser-agent screenshot bounce surfaced it). We picked `request.ctx`
  (Endpoint A) over positional-args-everywhere because the handler model is
  no-arg functions reading `request`/`response` globals, the first activation has
  no ctx to pass (an always-`undefined` first param is worse than `request.ctx`
  reading `undefined`), and `onResult` shows positional args aren't even uniform
  (sometimes two).
- **Mechanism**: `installRequest` (`globals.zig`) lifts the `next({ctx})` payload
  from the synthesized `{"ctx":…}` body to `request.ctx` for `ws_message` /
  `disconnect` / `kv_wake` / `wake_batch` / `timer` (the kinds that replace
  `request.body` — bound fetch, inbound chunk — lift inline first). The wake +
  held-sync resume paths (`worker_ws.resumeWakeChainWs`,
  `worker_drain.resumeContinuation`) stopped passing positional `[ctx]` /
  `[ctx, outcome]` and now build the same `{"ctx":…}` body envelope; a held-sync
  outcome is wrapped into the **same** `{"ctx":{result, context}}` shape an
  `on_result` hop uses (the held handler's threaded ctx fills `context`), so the
  one `send_callback` hoist serves both — flattening `result` → `request.body`/
  `.status`, `context` → `request.ctx`, metadata → `request.activation.*`.
- **Migrated** (pre-real-user, no back-compat): `onWake(ctx)` → `onWake()` reading
  `request.ctx`; held-sync `onResult(ctx, outcome)` → `onResult()` reading
  `request.body`/`.ok`/`request.ctx`; the on_result shims (`oidc._event`,
  `segments_onsealed`) + examples + smokes moved metadata reads from `request.ctx.*`
  to `request.activation.*`. Verified e2e by the heldsync (+concurrent), webhook,
  webhook-recovery, blob (+segments), on_kv, on_timer, ws-wake, and browser-agent
  smokes + dispatcher unit tests. **Note**: `blob.seal`/`blob.receive`'s
  `request.ctx.hash` is a *threaded* ctx (the seal/receive `next({hash})`), not
  delivery metadata — it stays on `request.ctx`.

### 4.8 Browser-agent surface (`browser.*`) — same-origin, vendor-neutral, structural-by-default
- **Decision** ("a Playwright for LLMs", 2026-06-15; `handler-shape.md` §5.9,
  shim `globals/browser.js`, SDK `web/rove-agent.js`): offer an LLM-drives-a-UI
  surface **scoped to the customer's own app** — an in-page same-origin SDK over
  a held WebSocket, paired with a `browser.*` JS-shim (same pattern as
  `webhook.send`). An agent acting inside the customer's *own* page is roughly
  equivalent to JS the customer can already run there → **no new trust
  boundary**, no install, no cross-origin reach.
- **Vendor-neutral brain**: the LLM call is the customer's own `on.fetch` with
  their key; `browser.tools()` returns a generic action schema the customer
  adapts to their model (the reference handler shows the Claude wiring). Durable
  reasoning state (goal, transcript) rides `kv`; the live tab + socket are
  ephemeral hands that re-derive on reload (durable-brain / ephemeral-hands).
- **Perception is structural by default**: an enriched DOM/accessibility
  snapshot (geometry + computed visibility + occlusion), pixel-free and
  token-cheap. True pixel capture (`getDisplayMedia` → `blob.put`) is a separate
  **opt-in** tier, not the default. The triad is DOM = *what*, screenshot =
  *how it looks*, replay = *why*.
- **Safety split**: rove-enforced & non-disableable (same-origin only; a visible
  "agent is driving · STOP" indicator + kill switch; screenshots only via the
  explicit consent path) vs customer-configured policy (which actions need human
  confirmation — `browser.confirm` — element allowlists, marking untrusted
  page content as a prompt-injection surface).
- **Pluggable brain**: the snapshot/action protocol is brain-agnostic, so the
  same surface can later be driven by the end-user's local Claude over **MCP**
  (a relay + session-pairing handshake) with no SDK/protocol change.
- **Replay-context channel** (the differentiator) **SHIPPED 2026-06-17** as
  `browser.getReplay` — see §4.10. The earlier security gate (log-server JWT not
  tenant-scoped) was closed first: `standalone.zig` now uses
  `verifyWithCapAndTenant`, and the read flows through the tenant-pinned
  `rewind-logs.internal` door.
- **Rejected**: a general "drive the user's whole browser" extension — a loaded
  gun an untrusted customer wields against their end-users (confused-deputy,
  prompt-injection, nothing rove can vouch for). Scoping to the customer's own
  app drops the scary part while keeping the LLM-enhanced-app use case.

### 4.10 Replay-context channel + user-defined index tags (2026-06-17)
- **Decision**: ship `browser.getReplay` (the "why" tier — DOM=what,
  screenshot=how, replay=why) on a general **user-defined index-tag** facility
  rather than a bespoke session column. A handler attaches low-cardinality tags
  to its request's log record via `request.tag(key, value)`; the log-server
  indexes them in a `log_tags` companion table, so queries filter `?tag.k=v`
  (and `/v1/{tenant}/session/{id}` is sugar for `tag.session`). Session-replay
  is then just *a tag query*, not a one-off.
- **Saga key = the engine `saga_id`**, auto-stamped on EVERY activation
  of a held connection (verified stable across `ws_message` + bound-fetch
  resumes) and surfaced to JS as `request.sagaId`. The indexer derives a
  reserved **`_saga`** tag from it, so `getReplay` returns a whole connection's
  activations with **zero per-frame handler tagging**. The user `session` tag
  (the app's own id) is the cross-reconnect bonus.
- **Bounds (low-cardinality posture, fail-loud)**: ≤4 tags/record, keys
  `[a-z0-9_]` (leading `_` reserved for engine tags), value ≤64 B. A violation
  **throws** (`request.tag` is a handler bug surfaced on the record, not a silent
  truncation). Capture rides the existing `console`-style path: tags move onto
  the `Response`/`Continuation` in `finishResponse` so they survive a `next()`
  (the dominant browser-agent path), and into the ndjson + sidecar so the indexer
  populates `log_tags` without decompressing.
- **Self-tenant logs door (Option A)**: ANY tenant may form
  `rewind-logs.internal` for its OWN logs — the engine pins the minted
  `logs-read` token to `pf.tenant_id` and requires the URL tenant to match, so a
  customer can read only its own logs; only `__admin__` may target another
  tenant (the operator path). Safe-by-construction: the read scope is the
  engine's, not the JS's.
- **Rejected**: positional `user1…userN` columns (opaque; meaning drifts across
  deploys) — named tags are self-documenting and the write cost is off the
  request hot path (the async indexer writes `log_tags`). Also rejected: a
  bespoke `session_id` column threaded end-to-end — `saga_id` already
  exists captured + replicated + in the ndjson, so it only needed indexing.

### 4.10a One name for the unit: **saga** (2026-08-05)

- **Decision**: the sequence of activations linked by one engine id is a
  **saga**, everywhere a human reads it. It had three names — *chain* (the
  engine's word), *fold*/`foldl` (the mechanism), and *saga* (already shipped
  in `rewind:test` and the `rewind test` runner). Saga wins because it is the
  only one that covers connectionless sequences (`durable_wake`, `cron`,
  `send_callback`, `onSubscription`) as naturally as held connections, and it
  had existing surface area.
- **The identifier moved with it.** `request.correlation_id` →
  **`request.sagaId`** (camel-case like the rest of the request surface —
  `chunkSeq`, `fetchId`); the reserved index tag `_corr` → **`_saga`**; the
  sidecar/ndjson wire key `correlation_id` → `saga_id`; the Zig field
  likewise. This was NOT treated as an internal name: the property is on
  `request`, in the handler contract, pinned by the surface-test gate, and
  consumed by the shipped `@rewind/browser` package.
- **Compat is read-side and one-way.** A world.json fixture may still carry
  `correlationId`, and a sidecar already in object storage may still carry
  `correlation_id`; both are read, neither is written. The `log_tags` rows are
  MIGRATED (`_corr` → `_saga`) rather than aliased, because an alias would put
  an `OR` back into the tag filter — the exact shape that cannot be planned
  (§ the tag-index fix, rove#443).
- **Rejected**: keeping `correlation_id` as "the internal id" while the
  customer surface said saga. That is the two-names-forever state the rename
  exists to prevent, and the field is not internal.
- **Accepted cost**: "saga" carries distributed-transaction baggage
  (compensating actions), which rewind's sagas do not have. Recorded so it is
  not re-litigated. "Session" was the alternative and collides with auth
  sessions.
- **Not renamed**: `ChainContext` and friends inside the worker, and the ~800
  uses of "chain" in `src/` (some unrelated — a PEM certificate chain). Zig
  identifiers with no external surface; a separate pass if it is ever worth it.

### 4.11 The ergonomics arc — one grammar, one payload surface (2026-07-04/05)

- **Decision** (as-built surface: `handler-shape.md`): the connection-wake namespace
  is **`after.*`** (`after.ms`/`after.kv`/`after.fetch`) — "after"
  matches the one-shot re-armed-per-activation semantics ("on" falsely
  connoted a persistent subscription) and frees `on` for the
  **universal callback-target key `{on: "module.method"}`** across
  every effect (`{to}`/`{on_result}` retired; `email.send`'s recipient
  `to` was the collision that ruled out `to` as the universal key).
  2026-07-11 follow-through: the native `_system.*` layer uses `on` too —
  the bindings read `opts.on` directly and the `{to}` third-arg wrapper
  object is gone, so surface and wire share one spelling (the shim-side
  lowering had already caused one bug: code written against internal
  comments used the retired form and its target was silently dropped).
  Threaded context is **`ctx` in / `request.ctx` out, no exceptions**
  (completes §4.9; `request.activation.msg` folded in).
  `webhook.send(url, opts)` takes a positional url; `scheduler.after`
  → **`scheduler.in`** so "after" is exclusively connection-scoped
  (the verb is the scope). `after.ms` is named for its unit —
  deliberately no `after.seconds` family. Fetch ids are the opaque
  `ftch_…` form on all three surfaces (return / `request.fetchId` /
  `activation.fetchId`); handler-visible fields are camelCase.
- **The payload surface is uniform**: `request.bytes` / `.text`
  (lenient UTF-8, U+FFFD) / `.json` on every payload-carrying
  activation — the tape stores raw bytes, the JS type is presentation,
  so all three derive from one recorded read. Result bodies ride
  byte-true end-to-end (base64url `body_b64` through the send-callback
  JSON envelope — the prior TextDecoder'd string corrupted binary).
  `request.body` (whose type varied per activation kind) is deprecated
  and removed with the window.
- **Fail-loud input sweep**: `return Uint8Array` ships raw bytes
  (was JSON `{"0":..}`); `kv.set` takes primitives only (silent
  `String()` mangle removed); `stream.write` takes string|Uint8Array
  only; `webhook.send` body is string-only (the durable marker is
  JSON); a provided-but-unserializable `next({ctx})` throws.
- **Rollout**: a ONE-DEPLOY-CYCLE dual-name window (old spellings were
  thin aliases) so deployed rewind-apps bundles survived the platform
  roll; opened with the 2026-07-06 deploy, **closed the same day**
  after the rewind-apps publish (`kv.set` of the aliases deleted,
  internal readers migrated). `request.body` retired 2026-07-06 once
  the replay driver (native epilogue + WASM shell) gained
  bytes/text/json parity; the driver alone keeps synthesizing a
  `body` so pre-retirement records replay their pinned code.
- **Retired outright alongside**: `kind=boot` subscriptions + `onBoot`
  (2026-07-05, unused — audited zero rewind-apps consumers). Seeding
  recipe: register `cron`/`scheduler.in` from any handler activation —
  idempotent by key; `_sched/*` entries are durable kv that survive
  deploys. A `kind=boot` manifest fails the deploy with a pointed
  error (same posture as `kind=cron`).
- **Rejected**: `to` as the universal callback key (email recipient
  collision); a unit family on `after` (`after.seconds` — one
  unit-bearing name beats a family); keeping `request.body` as a
  permanent alias (would keep the "which type is it" question alive
  forever); auto-JSON kv values (kv stays string-valued; JSON encoding
  is the handler's explicit choice).

---


### 4.12 Per-request arena regime: bump-first with a GC fallback (2026-07-07)

**Decision.** Handlers run on arenajs's bump allocator (ceiling =
CUMULATIVE allocation, ~3-instruction allocs, O(1) reset). When a
request exhausts the arena (`js_dual_arena_oom_hit` — the
capacity-vs-user-error discriminator), the dispatcher discards the
attempt wholesale — savepoint-rolled kv staging, attempt-scoped
readset tapes, effect accumulators, writeset contribution — and
re-executes ONCE under the GC regime (dlmalloc mspace +
refcount/cycle GC; ceiling = PEAK live set; ~20-30% slower). The
worker's in-memory churny map (keyed tenant + dep_id + module, so a
redeploy sheds the mark) routes known-churny handlers straight to GC.
Re-execution is safe because a failed attempt is pre-commit and
deterministic (same seed, same pinned clock, same inputs); an attempt
that fired an immediate worker-side effect (blob streaming,
cancel_fetch, fire_wake, resume_if_bound) is NOT retried.

**An unrecoverable OOM fails LOUD, never silently.** When the GC
re-execution ALSO exhausts the arena (a genuinely too-large request),
or the OOM was non-retryable (immediate side effect, or no savepoint),
the dispatcher discards the doomed attempt's outputs and returns a
terminal carrying a non-empty `exception` ("handler exhausted the
request memory arena (OOM)") → every dispatch site emits a **500**.
This closes the pre-existing swallow bug where a mangled OOM outcome
surfaced as a silent empty 200 (the fail-loud-on-resource-exhaustion
rule: an infallibility violation must be a loud 5xx, not a plausible
success). The error strings come from the worker allocator, not the
exhausted JS arena.

**Replay.** The regime is part of the execution identity (a
GC-completed churny request OOMs under bump), stamped as the HIGH BIT
of the readset's `js_engine_version` word (same-width interpretation
per the wire-width rule — zero frozen-format changes; old records
read as bump). `export-fixture` carries it into world.json
(`arena_gc`); the native driver sets the reactor mode per run; the
WASM shell errors clearly until its artifact is rebuilt from
arenajs ≥ 0.3.2.

**Rejected:** always-GC (a 20-30% tax on every handler for the rare
churny one); a customer-visible mode knob (the platform can learn it —
one safe semantic, no unsafe default); persisting the churny map
(a restart re-learns for the cost of one retry).

## 5. Readset replication

### 4.13 kv subscriptions: durable coalesced level-trigger (2026-07-07)

**Decision.** A kv-react subscription fire is a **coalesced level
trigger with at-least-once delivery**, not a per-write event. A
customer write under a watched prefix injects a durable
`_sub/dirty/{name}` marker into the WRITER'S OWN writeset (the kv
binding does this; atomic — a commit carries the write and the owed
fire together or neither). The post-commit arm marks the sub pending
in a bounded in-memory set (≤1 entry per tenant+sub — this replaces
the shared-msg-queue enqueue whose `error.Full` under back-pressure
silently LOST events, the silent-failure audit's M3); the tick drains
the set and fires `onSubscription` with the marker's delete injected
into the fire's writeset before the handler runs (the durable-wake
cleanup pattern) — clear commits atomically with the handler's
effects. A throttled sweep of `_sub/dirty/` (gated to tenants with
registrations; forced on promotion) is the guarantee; the immediate
path is pure latency and may be lost freely.

**Payload is the prefix only** — `source = {kind:"kv", prefix}`; key
and op are gone. The handler reads current committed state under the
prefix and reconciles. This makes the durable state O(subscriptions)
(a dirty bit, not per-key markers), makes write storms coalesce for
free, and matches the model (a handler is a pure function of its
readset — "the prefix is dirty, go read" hands it exactly that).

**Why no version-CAS on the clear:** same-tenant activations are
serialized into a total order, so a fire's read-reconcile-clear is one
point in that order — a write ordered before it is read; one ordered
after it re-arms the marker after the clear. The plain delete is safe.
This serialization is the load-bearing assumption; if per-tenant
execution ever becomes concurrent, the clear needs a version-CAS (or
handler-owned watermark) back.

**Rejected:** per-event delivery with a durable per-write marker
(O(writes) state, no coalescing); panicking on the old enqueue-full
(transient back-pressure would crash every tenant on the worker);
best-effort-with-metric (a reaction primitive that silently misses
under load is a footgun — the audit found exactly that).

### 4.14 A fetch resume's `request.ctx` — the fetch's own ctx, else the chain's `next({ctx})` (2026-07-10)
- **Decision**: on a held connection, a bound `after.fetch` (and everything that
  lowers to one — `blob.get`, `segments.get`, `platform.compile`/`deploy`/
  `stampManifest`/`release`) resumes with `request.ctx` = **the fetch's own ctx
  if it carried one, else the held chain's parked `next({ctx})`**. One
  deterministic rule, identical on WS and HTTP.
- **Why (issue #3)**: the two ctxs — a fetch's `{ctx}` option and the
  connection's `next({ctx})` memory — collided on the single `request.ctx` slot,
  and prod resolved the collision *by transport*: `worker_drain` (HTTP) read the
  fetch's `ev.ctx_json`; `worker_ws` (WS) read the chain's `chain_st.ctx_json`.
  So the same handler behaved differently by transport, and the `rewind test`
  sim (which matched HTTP) disagreed with prod-WS. The fix makes the fetch's own
  ctx win when present (matching the established §4.9 behavior — `blob.get`/
  compile all pass a ctx and read it back), and fall back to the chain's `next()`
  ctx when the fetch carried none (so a handler that threads connection state via
  `next()` and fetches with no ctx — the browser-agent `getReplay` shape — reads
  that state, on *both* transports).
- **Mechanism**: `worker_streaming.fetchResumeCtx(fetch_json, chain_json)`
  resolves the override worker-side (`ev.ctx_json` if non-`"null"`, else
  `c.ctx_json` / `chain_st.ctx_json`); the resume envelope stays `{"ctx":…}` and
  `installRequest` lifts it to `request.ctx` exactly as before — no new field.
  The sim mirrors it in `rewind_test.mjs` (`fetchResumeCtx(parent, fx)` =
  `fx.ctx ?? heldCtx(parent)`), so sim and prod agree by construction.
- **Rejected**: (a) *`request.ctx` = the chain's `next()` always, `request.extra`
  = the fetch's ctx* — clean in the abstract, but it moves EVERY bound-fetch
  effect callback (blob/compile/deploy/segments) off `request.ctx`, a large
  cross-cutting rename of shipped storage/deploy internals; and no real handler
  needs BOTH ctxs on one resume (each reads exactly one), so the second field is
  speculative. (b) *A separate `request.conn` for the chain memory alongside the
  fetch ctx* — same "nobody needs both" objection; deferred until a genuine
  both-case appears (a fetch that carries per-call correlation AND wants the
  connection state can put it in the fetch's own ctx). (c) *Drop `next(ctx)`,
  make every wake/frame carry its own ctx* — `next(ctx)` is the ONLY ctx channel
  for the un-armed continuations (WS frame, disconnect, inbound body chunk: there
  is no `after.message`/`after.disconnect`/`after.chunk` to hang a ctx on), so it
  is load-bearing and can't be removed.

### 5.1 Replicate readsets (not intents); gate the callback, not the propose
- **Decision** (Phases 1–6 shipped 2026-05-25/27; see
  `architecture/effects-and-handlers.md` §Readset replication): the three-substrate model is **Raft = inputs +
  cached writesets; BlobStore = input-bytes home (unrecoverable if lost) AND
  output-bytes cache (transient OK); Wire = ephemeral**. "Inputs durable, outputs
  derivable." The recorded readset **gates callback dispatch, not the propose**
  (downstream writes depend on the read bytes; gate at the callback boundary).
- **Inline vs blob**: inline ≤ 16 KB (the raft fsync *is* the durability); > 16 KB
  parks on S3. Each worker's `batch_id` lives in a `/w{worker_id}` subdir to
  prevent S3 collision (OVH `409 OperationAborted` without it).
- **Rejected (§7)**: (1) intents-only eager re-execution (CPU×N); (2)
  intents-only lazy (violates the kvexp local-snapshot); (3) S3-gated compaction
  (couples liveness to S3).
- **Open (perf only, not correctness)**: cross-tenant priority-flush coalescing;
  operator-side S3 GC (deferred to a bucket-lifecycle rule).

### 5.2 Body-durability failure must not re-submit
- **Decision** (fixed 2026-05-29, `bd756b9`): a > 16 KB inbound body parks on the
  blob coordinator; `BodyDurabilityWait.status: enum {fresh, resolved, failed}`
  makes the outcome explicit. `.failed` returns 503 and does **not** re-submit
  (the prior bug re-parked forever). Latent gap: no deadline sweep for
  `body_pending` (a stuck `.not_yet` body holds its entity indefinitely).

---

## 6. Auth & custom domains (OIDC)

- **Decision** (Phases 1–4 shipped/verified 2026-05-16; see `architecture/auth-and-domains.md`):
  full OIDC, dogfooded as a customer library. The IdP is the `__auth__` system
  tenant (magic-link + OIDC provider); RS256 signing is in Zig
  (`acme/crypto.zig`, OpenSSL) with JS calling `crypto.oidcSign` (hybrid fork).
- **Non-obvious durable invariants**:
  - **Host-relative invariant**: no platform-domain literals in code;
    `request.host` is carried on the outbound and `internal_routing` resolves the
    system domain; `redirect_uri` templated via `${ISSUER_PARENT}`.
  - `X-Rove-Scope` was **deleted** (do not reintroduce).
  - worker→standalone auth is a **shared secret** (HS256,
    `LOOP46_SERVICES_JWT_SECRET`) — machine-to-machine, not delegation.
  - `is_root` = an OIDC `sub` in the `_admin`/operator allowlist; admin app paths
    (`/`, `/?fn=`) require an operator session, while `/_system/*` accepts the
    root token.
- **Sole tracked follow-up**: ACME renewal / expiry-driven reissue (v1 issues a
  cert only when `cert/{host}` is absent).

---

## 7. Observability

- **Decision** (2026-05-13): two separate sinks. **Customer request logs** stay
  in the per-tenant replay store (S3-direct, page-encrypted) — a product feature
  addressable by `request_id`. **Operator signals** (raft commit rate, follower
  lag, queue depth, snapshot-install duration, blob latency, elections, panics)
  go to Grafana Cloud.
- **Enforced rule**: **never** use `tenant_id` or `request_id` as a Prometheus
  label — keep them as trace exemplars / low-cardinality structured-log fields.
  The Grafana Cloud bill is cardinality-driven; per-tenant cardinality would
  explode active series and duplicate replay-store cost while leaking plaintext
  to a third party.
- What the replay store may CONTAIN per request is governed by the
  read-recording decision (§4.6): exactly the request inputs the handler read,
  with client IPs masked unless the handler explicitly called
  `request.unmaskedIp()`.
- **Operator metrics ship on a dedicated loopback HTTP/1.1 `/metrics` listener
  per process, not an auth'd route on the data port** (decided + built
  2026-06-26; supersedes observability.md §2.1's scrape-JWT-on-`/_system/metrics`
  plan, which §2.1 had itself listed the dedicated-port form as a *rejected*
  alternative — reversed here). Each binary serves Prometheus text on
  `127.0.0.1:<port>` (worker `REWIND_METRICS_PORT`=9110, CP
  `REWIND_CP_METRICS_PORT`=9111, front `REWIND_FRONT_METRICS_PORT`=9112) off an
  independent thread + socket. **Why the reversal:** (1) the data ports are
  h2c-only (`accept_http1=false`) and stock Prometheus/Alloy can't scrape h2c;
  (2) loopback IS the auth (the node-local Grafana Alloy is the only scraper —
  the etcd/TiKV operator-metrics shape), so no scrape-JWT to mint/rotate; (3) a
  separate thread serving a pre-rendered snapshot keeps `/metrics` answerable
  *while the main request path is wedged* — exactly the incident you're
  debugging. The shared renderer is `metrics_server.zig` (a top-level build
  module) + each process's `build*MetricsText`.
- **The serving RED signal is `http_requests_total{code}`** — bucketed by status
  CLASS (`1xx`..`5xx`|`other`), counted in the shared rove-h2 response-emit path
  so worker/CP/front emit it uniformly. Per the no-`tenant_id`/`request_id` rule
  above, route/method/tenant stay OUT of the labels (trace exemplars, not
  labels). (Note: this is the bare name + class-only labels, narrower than
  observability.md §3's planned `rove_http_requests_total{route_class,method,...}`.)
- **As-built (2026-06-26):** all three processes' metrics + service logs flow to
  Grafana Cloud (Alloy per node → Prometheus + Loki). The version-controlled
  dashboards / alert rules / scrape config live in the `rewind-infra` repo
  (`grafana/`) (10 alert rules deployed Grafana-managed;
  the wedge signals `raft_groups_no_leader` + `raftnet_peers_unreachable` are the
  headline). observability.md's later phases (latency histogram, exemplars,
  tracing-to-OTLP) remain future work.

---

## 8. Replay UX & the CLI/agent surface

### 8.1 Recording shape: one invocation = one recording
- A recording is exactly one synchronous handler invocation (LMDB reads are sync;
  no async I/O inside). Cross-recording navigation (a tree of parent/children via
  `parent_request_id`) is delegated to the **send dashboard**, not the replay
  chrome. Intra-recording time is meaningless (sub-ms keyframes); inter-recording
  wall-clock (external service response time) is meaningful and lives on the
  dashboard.

### 8.2 Interaction encodes granularity (no mode toggle)
- **Scrubbing (drag) = scan** at event/side-effect grain; **stepping (click) =
  drill** at line grain. No mode toggle — the interaction *is* the intent. The
  scrubber is event-indexed, not time-indexed (keyframes only; no per-event
  wall-clock, since the handler is synchronous). Step-line resolves by
  deterministic re-execution from the prior keyframe.

### 8.3 The `rewind` CLI is a Node package over arenajs-WASM (not Zig)
- **Decision** (2026-05-15): the CLI + MCP server ship as one npm package
  (`rewind` / `rewind-mcp`, < ~1500 lines of Node) reusing the web replay
  porcelain (`cursor.mjs`, `wasm-app.mjs`, `qjs_arena_wasm.*`). No Zig / build
  profiles / cross-compile CI; distribution is npm. WASM ms-level latency is
  irrelevant (the agent is LLM-bound). A native N-API module is a deferred
  optimization, only if WASM proves insufficient (on proof, not suspicion). The
  server stays all-Zig; replay + CLI + MCP are all JS on one host.

---

## 9. Proposer / escaped-effect audit (from the retired `proposer-audit.md`)

- **Bug class**: the real risk is **premature effect release**, not on-disk KV
  divergence — kvexp volatility means a pre-quorum crash loses the speculative
  write with no on-disk divergence and needs no undo log. The release gate is
  **per-effect-kind**; proposers classify as Class A (safe), Class B-correct, or
  Class B-broken.
- **kvexp collapse**: on loop46, commit ≈ apply for read-visibility (the leader
  reads from its own overlay), so the apply-vs-commit distinction mostly
  evaporates to a single commit gate.
- **idiom-3 (escaped effect)**: when a `platform.root.*` / type-2 root write is
  proposed after local commit and the propose fails, the residual escaped effect
  is the **caller's success response** — logged, not compensated (at-least-once,
  consistent with the Cmd/callback layers). The earlier "wrap root writes in a
  `TrackedTxn` with undo semantics" direction is obsolete; the pre-kvexp
  `kv_undo` machinery was deleted. (Cross-referenced from PLAN.md §10 type-2
  notes.)

---

## 10. V2 multi-raft architecture

Mechanics live in the as-built references
(`architecture/consensus-and-storage.md`, `architecture/control-plane.md`,
`architecture/routing-and-ingress.md`). This section records the locked V2
decisions and rejected paths only. V2 is on `main`; Phases 0–7 shipped
through 2026-06; the substrate was de-risked by the `rewind2` / `raft-rs-zig`
prototype before V2 wrote code.

### 10.1 One raft group per tenant (`tenant == group`, 1:1)
- **Decision** (locked 2026-05-16): per-tenant raft groups on TiKV **raft-rs**
  (Zig/C wrapper), with a CP/DP split where DPs are N independent clusters.
- **Why**: per-tenant isolation (blast radius) and **no-downtime migration** — a
  tenant is a movable unit *because* it is a whole group.
- **Rejected**: N:1 group batching (erodes the movable-unit invariant). Framing
  V2 as a throughput win — at realistic handler costs the binding constraint is
  the apply pipeline, independent of raft topology (§10.3). The honest claim is
  "throughput parity, architecturally cleaner; the win is migration + isolation."

### 10.2 Shared-fsync WAL — one fsync per pump cycle
- **Decision**: all of a node's groups interleave into one append-only WAL,
  flushed **once per pump cycle** regardless of how many groups committed.
- **Why**: per-group fsync collapses throughput past ~K=4; this is the
  constraint that makes multi-tenant raft viable at all.
- **Known limitation** (not correctness): single-node nodes compact the WAL
  after a durabilize checkpoint; multi-node nodes durabilize (bounding replay)
  but do **not** truncate — safe multi-node truncation needs a follower-match-
  index floor + a data-carrying snapshot for lagging followers, deliberately
  deferred.

### 10.3 Apply-bound, not consensus-bound; the allocator is load-bearing
- **Finding** (prototype, transferred to V2): throughput scales with **apply-
  worker count** (`W` = physical cores; SMT oversubscribe *collapses* it), not
  with raft. Spend throughput effort on the apply path, multi-raft effort on
  migration/isolation.
- **Allocator**: keep `c_allocator` globally — Zig's GPA has a global mutex that
  becomes *the* wall under multi-threaded multi-raft; the Rust raft-rs shim sets
  a jemalloc/mimalloc `#[global_allocator]`. **Standing rule**: swap the
  allocator *before* any contention deep-dive (one-line probe).

### 10.4 Hibernation — heartbeats must not wake idle groups
- **Decision**: tick only an active set; `bumpActive` on propose / formation /
  non-heartbeat step; **never** on heartbeats (detected at the eraftpb wire-byte
  level, codec-independent). No pre-seed.
- **Why**: at K=thousands of mostly-idle tenants, ticking all groups plus
  heartbeat-driven self-wake buries the pump; O(active) restores it (≈31,000× at
  K=10k idle).
- **Intended tradeoff**: a fully-idle group whose leader dies does not auto-re-
  elect; the next request wakes + campaigns. An idle group has nothing to serve.

### 10.5 Provenance-keyed apply + store unification (revised 2026-06-09)
- **Decision**: the pump skips the replicated store write **iff the entry is
  this node's own still-pending propose** — every entry carries an identity
  frame (per-boot random `origin_id` + per-tenant seq) and the bridge answers
  a `skipQuery` against its pending set. Everything else (follower apply, a
  promoted leader's catch-up, restart replay, abandoned waiters) is written by
  the pump — into the worker's *own* serving store via **pump-owned sibling
  handles** (`PumpStores`: same kvexp manifest + store id, private txn state;
  sharing the worker's handle let applies land inside its open speculative
  txn) using **chain-bypassing authoritative writes** (kvexp
  `StoreLease.applyPut/applyDelete` — replicated truth never sequences behind
  the local speculative txn chain).
- The same identity drives the seq↔commit binding: the hook advances
  `committed_seq` only for its own pending seq, never by FIFO position.
  **Superseded** (2026-06-09): the leader-gated FIFO pop — an old-term entry
  resurrected by re-election could credit the wrong waiter (false durable
  ack); and skip-keyed-on-`isLeader` — it dropped catch-up/abandoned writes
  from the serving store. (Counting seqs was rejected before both.)
- A write in flight at a leader change is **faulted + retried** (503 =
  *unknown outcome*: the entry may still commit later, so retries are
  at-least-once). Zero-failed-request moves under continuous load are Phase 7.

### 10.5b Commit quorum counts only fsynced entries (2026-06-09)
- **Decision**: raft-rs-zig runs the async-append flow — `process_ready`
  records appends; the pump acks `on_persist` **after** the cycle's one fsync;
  persistence-asserting messages (append acks, vote responses) are held until
  the ack. The rove pump is two-pass around the fsync (apply prior-durable →
  flush → ack → apply unlocked commits), the commit hook fires post-fsync, and
  WAL compaction flushes once before truncating (the durable commit index lags
  one fsync). Single-node proposes still commit within one pump cycle.
- **Why**: the sync flow (`advance` inside `process_ready`) counted the
  leader's own *volatile* append toward quorum — a 3-node commit could be
  reached with one durable copy fewer than quorum, and a single voter
  committed (and could ack) entirely ahead of the fsync.
- The durabilize/compaction checkpoint is additionally floored by the
  **worker ack** (`noteWorkerCommitted`): a skipped entry's data lives in the
  worker's open txn until promoted, and the kvexp fold cannot see open txns —
  stamping/compacting past an un-acked entry claimed durability for volatile
  data.

### 10.5c Follower proposes fail fast; 421 re-aims, 503 is never platform-retried (2026-06-09)
- **Decision**: `Bridge.propose` rejects synchronously (`Error.NotLeader` →
  HTTP **421**) when the tenant's group is formed on this node and it is not
  the leader. The 421 contract is "nothing entered the log; re-execute
  elsewhere is safe" — the front door's `proxyToCluster`, the DP
  serve-or-forward (`proxy_engine`), and the move surface's v2-kv/v2-bundle
  gates all key their node-failover on 421 and **never on 503**. A 503 from
  the write path is the ambiguous post-propose failure (commit-wait
  fault/timeout, leadership-loss sweep — the entry may still commit under a
  new leader) and is relayed to the client, whose retry policy owns the
  at-least-once decision.
- **Why**: raft-rs 0.7 unconditionally FORWARDS a follower's proposal to the
  leader (`step_follower` MsgPropose; no `disable_proposal_forwarding` in
  this version). Pre-fix, a follower-addressed write committed cluster-wide
  while the local leadership sweep faulted the seq — the client was told
  "write failed" with the write durable, and the front door's then-blind
  503-retry re-executed the handler (observed as `durable_wake_smoke_v2`
  Gate A's double-minted wake; decisively reproduced by a direct-to-follower
  write probe: 503 + value committed on all nodes). A `formed` flag on
  `GroupSig` (pump-published) gates the check so lazy first-propose group
  formation still passes. Backstop: raft-rs-zig's `raft_manager_propose`
  leader-gates before stepping raft (refused proposes provably never
  commit), covering the one-refresh-stale race.
- **Rejected**: marking retry-safety with a response header (status-only is
  visible in every log/proxy hop and 421 is semantically exact); disabling
  forwarding via raft-rs config (knob doesn't exist in 0.7).

### 10.5d No method is read-shaped: ambiguous transport failures never replay (2026-08-13)
- **Decision**: the front door re-sends a request after a transport failure
  ONLY when the request head never reached the wire (no upstream stream id).
  Once the head went out, a responseless death is ambiguous for **every**
  method — GET/HEAD/OPTIONS included — and maps to a 502
  (`write-ambiguous`); the client's retry policy owns the at-least-once
  decision, mirroring §10.5c's never-retried post-propose 503.
- **Why**: the previous carve-out granted read-shaped methods RFC 9110
  §9.2.2's benefit of the doubt (nginx's `non_idempotent` line). But a
  rewind handler's method semantics are customer code — a GET writes kv
  exactly like a POST — and the doubt was observed double-executing in
  production: one client GET, a pooled-leg death after the head was
  submitted, two committed counter increments, first response lost
  (rove#532; both duplicates journal-attributed to
  `conn_died=true … idempotent=true` re-sends).
- **Rejected**: keeping the carve-out with an idempotency-key dedup at the
  worker (at-most-once machinery for a window the honest 502 already
  closes); declaring GET pure by contract (contradicts the handler surface —
  activations are method-agnostic customer code).

### 10.6 Tenant move = ship committed state to a fresh group
- **Decision**: detach dumps committed KV state to a self-describing bundle;
  attach forms a **fresh** group at the migration epoch on every destination
  node (`clearTombstone` lifts raft-rs's intentional id-reuse guard); the epoch
  fences stale messages. **Blobs never move** (shared content-addressed
  backend).
- Quiesce (pause/drain proposes) and the directory flip that make the move
  correct and no-downtime are the **CP's job** (see `control-plane.md`).
- **Rejected**: carrying the raft-log tail across a move — "quiesce → commit →
  ship state → fresh group" is sufficient and is what the prototype validated.

### 10.7 Codec: prost (pre-generated)
- **Decision**: raft-rs with **prost-codec**, pre-generated `.rs` (no `protoc`
  at build time), `panic = abort` / `lto`.
- **Why**: per-message protobuf **decode** is the real per-message cost (batching
  the `step` FFI bought 0× — the Zig↔C↔Rust boundary is sub-µs), so a
  faster/smaller codec is the lever, not the FFI shape.
- **Not a size lever**: protobuf-build vs prost makes no difference to the
  dependency-closure size (protobuf-build pulls ~33 MB of protoc binaries
  under both) — do not re-litigate prost-vs-protobuf on size grounds (§10.11).


### 10.8 The CP directory is itself raft-replicated (HA, strongly consistent)
- **Decision** (shipped 2026-06): the control plane is a small dedicated raft
  cluster (`rewind-cp`, 3–5 voters) holding one `__directory__` group on rove's
  **own** `bridge`/`Node` substrate — dogfooding the DP engine. Reads serve from
  an in-memory projection materialized by an `apply_observer` on the leader **and
  every follower** (a follower has no local proposer); writes propose through the
  leader, and a follower forwards `/_control/*` to it. The directory group is
  pinned always-active so a follower re-elects on leader death (a routing read
  never proposes to wake it).
- **Why**: Phase 7 made placement request-critical — every DP serve-or-forward
  reads it and the move's atomic flip writes it — so a single static front-door
  copy can't be the launch CP; it must be HA + strongly consistent.
- **Rejected**: the front door as a CP raft voter (the prototype welded the
  directory to the request-path proxy → front-door count == voter count, inverted
  scaling). Split the CP into its own binary; the front door is a **stateless
  cached read-replica** (serve-or-forward is the staleness backstop, not a raft
  learner at the edge). Mechanics: `architecture/control-plane.md`.

### 10.9 Operational state lives in the CP, authored by an admin app
- **Decision** (shipped 2026-06): per-tenant **operational state** — plan/limits,
  and the other admin-set placement-independent axes (domain → tenant index, ACME
  `cert/{host}`) — lives in the CP `__directory__` group as sibling axes to
  `placement/*`. The source of truth is the **dumb** CP (it holds *what* the
  limits are, not *why*); the authority that **mutates** it is a normal rewind.js
  admin app (a DP tenant) emitting **capability-gated** control writes
  (`/_control/*`). A CP write is an outbound `Cmd` in the effect algebra; the
  app's own `app.db` holds the idempotency/audit record.
- **Why (the CP-home filter)**: the criterion is "**admin-authored AND
  placement-independent**," the same pair that already puts placement in the CP —
  *not* "it determines limits" (limits are *enforced* DP-local). A tenant moves
  between clusters, so the per-cluster `__root__.db` is the wrong home (V1's
  `root_writeset` conflated source-of-truth with authority). Delivery reuses
  placement's channels: the plan rides the `v2-attach` handshake at cold-start/
  move; a live change is a single-target push to the serving cluster (a plan-
  generation bump). The front door can enforce body-size `413` at the edge from
  its cached read; rate (`429`) + retention clamp stay DP-local.
- **Rejected**: plan in `__root__.db` (per-cluster → must migrate on every move; N
  copies of one-per-tenant state). A dedicated control binary with business logic
  (keep the CP small/auditable; policy — "Pro costs $X," provisioning — lives in
  an iterable tenant app). The confused-deputy guard is a **capability grant**,
  not a hardcoded tenant id (future-proofs delegated/self-host admin). Mechanics:
  `architecture/control-plane.md`; accounts/billing product layer:
  `platform-accounts-model.md`.
- **Enforcement decisions** (the three levers shipped 2026-06; mechanics in
  `architecture/control-plane.md` "Operational state"): `rove` only *enforces*
  tiers — setting one (Stripe webhook → admin write) is product-layer; **rove
  never knows what a dollar is**. Effective limits resolve at **read-time**
  (`override ?? TIER_TABLE[tier].field`) and cache on the `TenantSlot` with a
  plan generation (no `O(N_tenants)` on dispatch). Rate buckets
  **generation-refresh** on a stale generation — stale-until-restart was
  rejected because the painful direction is a *paying* customer not getting
  their raise until restart. Retention ships as a **server-side read-path
  clamp**, not GC: upgrade reveals, downgrade hides-never-deletes (sidesteps
  the "downgrade retroactively deletes data" hazard); unbounded S3 until real
  GC was an accepted operator cost. **§11.6 completes this lever** — the clamp
  becomes its read half and gains a deleting sweep behind it, which narrows
  "upgrade reveals" to what the sweep has not yet taken.

### 10.10 Cutover strategy: freeze V1, branch, no dual-mode
- **Decision** (2026-05-29; executed, cutover complete 2026-06-10): freeze V1
  on main, build V2 as its replacement on branch `v2`, merge and delete V1
  when V2 can serve + move tenants. **Pre-release with no production data**
  collapses the migration problem: dual-mode (two raft engines coexisting in
  one binary — the single hardest piece of the earlier parallel-`src-v2/`
  plan) was answering a *live-migration* question that no longer existed.
  "Clean slate" meant clean-slate the **spine** (consensus/storage,
  `src/kv/` willemt) and reuse the **limbs** (`h2/`, `blob/`, the JS
  dispatcher, `tape/`, `tenant/`, files-server) as imports.
- **De-risking order**: the first cross-cluster move ran between two
  *single-node* "clusters" — mobility needs the whole bundle→ship→attach→
  reroute path but **not quorum**; multi-node HA became hardening *after*
  the capability was proven. Value-first: prove the differentiator (the
  move) before investing in HA and scale.
- **Why mobility forced the rewrite**: V1's raft was cluster-wide — one log,
  every tenant interleaved, the consensus index *cluster*-scoped — so a
  tenant's state (`durableRaftIdx`) and its consensus position did not
  travel together; moving off a shared log needs a bespoke dual-write/fence
  protocol that is error-prone at the fence and doesn't generalize. Per-
  tenant groups make state + consensus position one movable unit (§10.1,
  §10.6).

### 10.11 Dependency model: pin-and-fetch, not vendor
- **Decision** (2026-06-04, branch `v2`): third-party deps are **pinned and
  fetched at build time** — Zig/C packages (`arenajs`, `kvexp`,
  `raft-rs-zig`) via `build.zig.zon` full-SHA pins, the raft engine's Rust
  crates via `Cargo.lock`. The first build needs network; subsequent builds
  hit the Zig package cache. This **replaced the vendor-everything /
  offline-build mandate**.
- **Why**: the raft-rs Rust closure measured 60–143 MB — too large to vendor
  sanely, and no codec choice shrinks it (§10.7). The willemt/raft vendor
  (and `vendor/` entirely) was deleted at the V2 cutover.
- **Do not** re-vendor or re-propose the offline-build mandate without new
  information. `zig fetch --save=<name> git+https://…#<commit>` needs the
  **full SHA**.

### 10.12 Cross-cluster move stays bespoke — not raft conf-change
- **Decision** (2026-06-19, closing Phase 3 of `raft-native-alignment.md` after
  the arc's P1/P2/P2.5 landed): a cross-cluster tenant move stays the **bespoke**
  path (§10.6: fresh group on the destination cluster + HTTP forward-stream
  dual-write + atomic directory flip + epoch fence). It is **not** a raft
  conf-change (`addLearner(dest) → snapshot → promote → removeNode(src)` on one
  group, routing following membership) — even though P1/P2/P2.5 built all the
  conf-change *machinery* (ConfState-carrying snapshots, streamed multi-GB
  transfer, the learner→promote reconciler), so the objection is no longer
  mechanical.
- **Why (topology, not mechanics)**: rove's clusters are **deliberately disjoint
  raft transport meshes** — isolation / blast-radius is the point, and the scaling
  model is "move tenants *between* isolated clusters," not "grow one homogeneous
  pool." TiKV's conf-change move works *because* every store is mutually
  raft-reachable; a single rove group spanning two clusters would need
  cross-cluster raft connectivity, breaking the disjoint mesh on purpose. The
  bespoke move already does the cross-cluster data transfer over an **HTTP
  side-channel** (`v2-forward-begin` dual-write + `v2-snapshot-push` stream) and
  never joins the two raft meshes — so its apparatus is the *cost of preserving
  isolation*, the cross-*cluster* analog of TiKV's within-pool rebalance at the
  granularity rove actually scales by. "Who serves during the membership overlap"
  is also a real routing question the atomic directory-flip answers cleanly.
- **Rejected**: move-via-conf-change. Now mechanically possible (post-arc) but
  architecturally incompatible with the disjoint-mesh design.
- **Reopens only if** a deployment runs clusters on a **shared transport mesh**
  (all nodes mutually raft-reachable, isolation relaxed) — then conf-change move
  becomes viable and arguably simpler. That is a *product/topology* decision, not
  a consensus-mechanics one; today's topology + the isolation goal say no.

### 10.13 Cluster genesis is cold-multi — the ONE deploy path (bootstrap-1-grow superseded)
- **Decision** (2026-06-26): a cluster is brought up **cold-multi** — every raft
  group (CP directory + every tenant group) is born with the **full static voter
  set** (`REWIND_VOTERS`/`REWIND_PEERS`, `REWIND_CP_VOTERS`/`_PEERS`) and elects
  on its own. Genesis and rolling share **one** env profile; they differ only in
  what `deploy.sh` does (`--genesis` = wipe → start-all → cold-form → provision
  `__admin__`; default = quorum-safe rolling restart). The membership reconciler
  stays **OFF** by default.
- **Supersedes the bootstrap-one-then-grow arc**: groups born sole-voter
  `{self}` and grown by the CP reconciler. That model was
  adopted under the belief that cold multi-node genesis was *fundamentally* broken
  on real nodes (the 2026-06-24 outage: all-followers, no leader). **It wasn't** —
  the wedge was a `raft_net` transport bug (zombie-connect on a torn-down fd; recv
  armed on a still-`.connecting` socket tore down the in-flight dial, then the
  connect CQE mis-marked a dead fd `.connected` so `send` no-op'd forever). Fixed
  in `7feac92`; cross-host cold-multi now elects in 1–2 s. Validated end-to-end on
  real prod 2026-06-26 (full wipe → re-genesis → all tenants serving).
- **Why cold-multi is right (not just simpler):** rove is **small FIXED clusters**,
  every group fully replicated across its cluster's nodes; scale by adding
  *clusters* + tenant *moves* (§10.6, §10.12), not by growing a store pool.
  TiKV-style grow solves a placement problem this topology deliberately doesn't
  have. Cold-multi also avoids depending on the reconciler's timer-promote-to-voter
  (which had a promote-before-catch-up bug that wedged a prod grow at `{1,2}`).
- **The reconciler stays** (off by default), narrowed to deliberate ops — a DR
  async-learner add. Tenant moves remain a separate path (`rewind-ops move`).
  Re-arming promote-to-voter requires fixing the catch-up gate first.

---

## 11. Deployment & log storage

Mechanics: `architecture/deployment-and-logs.md`. This section records the
storage decisions that section assumes. (The customer-logs-vs-operator-signals
*sink* split is §7; these are about how each is stored.)

### 11.1 Deploy and release are separate steps
- **Decision**: `files-server-v2` publishes blobs + a content-addressed manifest
  to S3 (cluster-free); a *separate* `/_system/release` writes the one
  `_deploy/current` pointer through raft (envelope 0).
- **Why**: the release flip is the approval gate — deploys stay approval-gated by
  keeping the marker write distinct from the byte upload. Workers are pure
  consumers; the manifest pointer is the only deploy state that replicates.

### 11.2 Deployment snapshots are immutable, refcounted, content-addressed
- **Decision**: a `TenantFilesSnapshot` is immutable and refcounted; a reload
  swaps the slot pointer atomically and the old snapshot frees when the last
  in-flight request releases it. Bytecode is shared process-wide by content hash
  (`BytecodeCache`), so a reload is `O(changed files)`.
- **Rejected**: mutating deployment state in place — unsafe against in-flight
  requests, and it forced per-tenant byte duplication that the content-addressed
  cache eliminates.

### 11.3 Static assets 302-redirect to presigned S3 (not worker-RAM cache)
- **Decision**: the worker serves a static asset as a 302 to a presigned S3 URL
  (strong `ETag`, 304 support), never buffering the bytes.
- **Why / Rejected**: "just cache it in the worker" is the wrong default for
  MB-sized payloads the worker doesn't execute — the storage origin (+ the CDN
  edge by URL) is the right server. See the storage-origin-vs-worker-RAM rule.

### 11.4 Log batches are per-node interleaved, per-record raw-deflate
- **Decision**: each node writes **one** S3 object per flush, interleaving all
  tenants' records (`_logs/{node}/{batch}.ndjson`), each record raw-deflate-
  framed; a standalone `log-server` indexes them into SQLite (polling + a worker
  push that closes the S3-LIST consistency window).
- **Why**: a per-tenant key layout would be `O(active tenants on node)` PUTs per
  flush; one interleaved object collapses that to one. Per-record (not per-batch)
  deflate lets a single click-through decompress one record with one range-GET.
- **Gotcha**: compression is **libz** (`windowBits=-15`), not the Zig stdlib —
  `std.compress.flate.Compress` is incomplete (panics on real payloads).

### 11.5 The publish *mechanism* is engine surface; deploy *policy* stays tenant code (2026-08-15)
- **The rule**: a surface that installs the code which would fix it cannot be
  the tenant's to get wrong. Test to apply: **can a mistake here leave the
  platform unable to repair itself without operator intervention?** Deploy and
  module loading are the only yes. Everything else in the admin app fails
  *open* — a broken teams page, log door, or CP chokepoint can still be
  corrected by shipping a fix — while deploy fails *closed*.
- **Decision**: the engine owns bundle intake, compile, content-addressing,
  package staging/resolution, manifest stamping and the release flip, exposed as
  one credential-gated door. The admin app owns **authorization and ceremony** —
  who may deploy to which tenant, plan limits, approvals, audit, UI — and fronts
  that door rather than reimplementing it. The seam is a short-lived
  tenant-scoped **deploy capability**, the pattern already proven by the
  `logs-read` cap the log door mints (`auth-and-domains.md`).
- **What this changes about §4.1/§4.2 of `architecture/cli-and-deploy.md`**
  (2026-06-15): that decision put arbitrary-bundle deploy into a standing
  `__admin__` JS app so deploy logic would be "hackable JS on the same surface
  customers use", deleted the Zig arbitrary-bundle route, and left
  `POST /_system/reset` as the one native surface — bootstrap *and* break-glass,
  body-less, redeploying only the `@embedFile`'d bundle. Its reasoning held
  **because the baked bundle WAS the production deploy app**. Two of its
  premises expired without anyone noticing:
  - *"break-glass = restore a known-good `__admin__`"* — the baked bundle is no
    longer the dashboard, so reset now restores a **different, minimal** app.
    Break-glass costs the operator UI and the OIDC RP until a republish.
  - *"every smoke now exercises the production deploy path"* — `_ensure_admin_app`
    installs the baked bundle, so every smoke exercises the **baked**
    implementation while production runs the dashboard's copy.
- **The failure that forced it** (2026-08-15): `admin/index.mjs`'s
  `buildResolution` ignored the `done` map, so any package that had to be
  compiled *during* a cut reached `stampManifest` with no `bytecode_hash` and
  the deploy died with `invalid resolution`. Its sibling `compiledResolution` in
  the same file merged `done` correctly, and so did the baked
  `genesis_admin.mjs`. One protocol, three transcriptions, one wrong — and the
  wrong one was the copy every real publish goes through. Recovery required
  `/_system/reset` (dashboard down) before the fix could ship.
- **Ratio that makes the split cheap**: of the deploy surface in
  `admin/index.mjs`, the product's own contribution is `deployGate` — validate
  the tenant id, then `is_root || canAccess(...)`. The remaining ~400 lines
  choreograph engine verbs (`platform.compile`, `stampManifest`, workspace kv)
  whose formats the engine already defines and validates.
- **Preserves the original goal.** "As much policy as possible writable as
  tenant code" survives intact: authorization *is* the policy, and it stays in
  JS. What moves is machinery no product differentiates on.
- **Acceptance test (self-hosting)**: an operator can install the engine,
  provision a tenant, deploy a bundle, release it and route a host **without
  installing an admin app at all**. Today that is impossible — `rewind-ops
  bootstrap` is "provision `__admin__` + reset", so the platform's own product
  surface is a prerequisite for publishing anything.
- **Rejected**: (a) keeping two implementations and syncing them by review — the
  drift is silent and only surfaces as a bricked publish; (b) making the fix a
  conformance case alone — worth doing either way, but a spec that catches drift
  after it ships still leaves the bootstrap deadlock; (c) restoring the old
  `/_system/deploy` as a *second* permanent path — the goal is one
  implementation, not one more.
- **Costs, accepted**: the engine gains a public protocol it must version
  deliberately (§14), and a self-hosted door must be safe by default rather than
  incidentally shielded by the admin app in front of it.

### 11.6 Replay retention is a sold time window; capacity is derived (2026-08-17)
- **Decision**: axis 2 sells **days**, and records past the window are
  **deleted**. The byte capacity is derived, internal, and never quoted:
  `capacity = log_refill_bytes_per_sec × 86400 × retention_days + log_burst_bytes`.
  This **supersedes the capacity-ring model** (`strategy/pricing-model.md` §3 as
  written before this date; tracker rove#319), which sold bytes and derived a
  retention *floor*. Same identity — the decision is which side is sold.
- **Why (the legal half, which the ring model never weighed)**: replay records
  hold the customer's end-users' personal data and we hold it as a processor, so
  a retention **period** is a required term of the DPA (rove#326) and the privacy
  policy (rove#324). "Until your bytes run out, which depends on your traffic" is
  not a period; it is the absence of one. Bounded retention also shrinks what an
  erasure request must sweep (rove#340), what legal process can compel, and what
  one breach exposes. For the segment that pays most, "kept basically forever" is
  a liability, not a feature — an absent maximum is a procurement defect.
- **Why (the engineering half)**: the sold number becomes the COGS bound, so the
  promise and the spend cap are the same fact and cannot drift. It also fixes the
  ring's own sharp edge — under a ring a traffic spike contracts the window
  exactly when the logs matter most; under a fixed window a spike costs *us*
  bytes, bounded by the derived ceiling, and the customer's horizon is unchanged.
- **Derive from the byte bucket, never from `rps`.** A request is not a fixed
  quantity of log; `rps × max_body_bytes` at the free tier is 500 × 4 MiB =
  2 GB/s, a meaningless bound. Both caps are enforced at once and the `log_bytes`
  bucket always binds first. Request rate enters only via the `k·count` floor.
- **Enables the deletion to be compactor-free — conditionally.** Every axis-2
  object is cross-tenant (`_logs/{node}/{batch}.ndjson` per §11.4, plus the
  `_pool/` body spill); an earlier claim that log records are per-tenant prefixed
  at `{instance}/log-blobs/` is **retracted** — no such store exists. Per-*tenant*
  byte eviction from a shared object needs a compacting rewrite, which was the
  ring's true price. Deletion by *age* does not, provided each object is
  **homogeneous in expiry** — so shard the flush by retention class
  (`_logs/{node}/{class}/…`, class ∈ the tier windows) and a whole object dies at
  once. Cost is one PUT per class per node per flush: bounded by tier count (3),
  never by tenant count, so §11.4's O(active tenants) rationale survives.
- **Retention ≠ erasure.** Making objects homogeneous in expiry solves the
  window; it does nothing for erasing *one* tenant from a shared object, which
  still needs compaction or per-tenant crypto-shred (rove#91). The deprovision
  sweep (`src/cp/storage_sweep.zig`) only reaches per-tenant prefixes, so a closed
  account's records survive in `_logs/`/`_pool/` today. The window is deliverable
  without solving this; the account-closure promise is not.
- **The read clamp stays** as the *read* half of the lever: a downgrade must hide
  immediately but not destroy for 30 days (`strategy/billing-policy.md` rule 9),
  so the sweep's horizon lags a plan drop and the clamp makes the lag invisible.
  This narrows §10.9's "upgrade reveals" to "reveals whatever the sweep has not
  yet taken" — a pricing-page sentence, not a support surprise.
- **Costs, accepted**: the light customer loses the decade-long tail the ring
  would have given them; `log_max_ingest_rate` becomes a *billed* per-tier number
  rather than a uniform guardrail (it is uniform 64 KiB/s in the tree today —
  rove#301); and a published window is a promise the storage layer does not keep
  until the sweep (rove#333) ships, which is a policy exposure rather than merely
  an unpaid cost line.

---

## 12. Rejected effect-surface primitives

Effect/handler-surface primitives considered and **rejected** — do not re-propose
without new information (harvested from the retired `primitive-gaps.md` §4). These
are closed, not gaps.

- **Durable SSE replay log** — rejected. A customer composes replayable
  server-push via their own kv prefix; the platform does not own an SSE event log
  (see §3 / §8).
- **Cross-tenant kv subscriptions** — rejected. The tenant boundary is hard;
  cross-tenant access goes through `platform.scope(id).kv` or an outbound
  `http.fetch`, never a kv-wake spanning tenants.
- **Predicate-function kv-wakes** — rejected. A customer predicate would run
  customer JS on the raft apply thread; kv-wakes match on key *prefix* only.
- **Blocking inline external call** — rejected (PLAN line 79's Cmd bet, preserved
  verbatim). An external result reaches a handler only as a later Msg; the
  held-sync projection is cosmetic, not a relaxation (see §3.3).
- **Multi-tenant atomic writeset** — rejected. Each tenant's `app.db` is its own
  raft target; there is no cross-tenant atomic commit.

---

## 13. Connection-actor: the unified trigger model & callback execution

Recorded 2026-06-10 from the 2026-05-18 architecture session. This model
superseded the framing of the retired `connection-actor-plan.md` (§4
copyable-handle branch, §6 projections) and the retired `http-send-plan.md`;
both were deleted in the docs restructure with their mechanics folded into
`architecture/effects-and-handlers.md` and `architecture/routing-and-ingress.md`
("Held connections"), but the *decisions* had until now lived only in session
memory.

### 13.1 Affine trampoline + coalesced trigger — fan-in on the trigger, never the writer
- **Decision** (2026-05-18; the shipped shape is the Continuation primitive +
  parked-Msg queue): every connection has exactly one owner — an affine,
  single-threaded continuation chain. A handler activation either returns a
  terminal value (becomes the response; the connection closes) or a
  continue-disposition (the connection stays parked; the runtime invokes the
  next module). Many sources may *signal* the owner, but only via a coalesced
  trigger that carries **no data and no write capability** — "wake the owners
  subscribed to this", nothing more. Trigger activators: timer/delay, inbound
  message, named publish, fetch/send callback, durable-log advance. The woken
  owner's single-threaded callback decides what to read (request body / kv
  state / durable-log prefix) and what to write.
- **Why**: every projection (SSE, WebSocket, held-sync third-party call,
  subscription stream) collapses to this one primitive — only the activator
  and what the owner reads vary. Write races are impossible by construction
  (one writer per connection); fan-in complexity relocates onto the trigger,
  which is stateless and data-free. This also makes PLAN §7/§10.1's
  "notification ≠ state store; refetch beats replay" thesis the *universal*
  mechanism rather than an SSE special case.
- **Rejected**: a **copyable addressable connection handle** plus a sequencer
  for fan-in (the original plan-§4 branch). The affine chain needs no handle
  at all; the "fan-in needs sequencer + handle + 5-layer security" analysis
  was wrong. Corollary, intentional: broadcast *cannot* be "enumerate the
  connections and push" — fan-out is pub-sub on a trigger (the `on.kv` room
  recipe in `architecture/websockets.md`), a customer recipe rather than a
  platform API.

### 13.2 No connection handle in any JS projection (capability-by-construction)
- **Decision**: customer JS never receives a connection reference, in any
  projection. Resolve-once and leak-once bugs, and handle-based confused
  deputies, are structurally impossible rather than defended against.
- **Effect on the 5-layer holder isolation model** (locked 2026-05-18, when a
  handle still existed): layers 1 (unguessable 128-bit external handle) and 5
  (no JS surface to name a foreign id) are **mooted** — there is nothing to
  guess or name. Layers 2–4 remain load-bearing for the internal
  worker↔held-state transport: an owning-tenant chokepoint on every
  operation (fail loud on mismatch), privileged endpoints gated on an
  internal bearer never surfaced to QJS, and wake routing fixed to the
  owning tenant from the platform's own table — never a caller-supplied
  tenant. The live threat is the **confused deputy via customer
  `http.fetch`**: a handler can POST any URL, so an internal endpoint that
  mutates connection state must authenticate the platform, not trust its
  caller. The same reasoning keeps fleet keys out of customer-style sandboxes
  (the cluster-manager keeps its fleet authority server-side in the admin
  handler, never shipped to a customer-style sandbox).
- **Scope of trigger naming**: `trigger(name)` namespacing is DoS/quota
  hardening, **not a confidentiality boundary** — a cross-tenant trigger can
  at most cause a spurious refetch of the woken owner's *own* tenant state;
  no data crosses tenants on a trigger.

### 13.3 No peer-to-peer cross-node operations — raft is the only cross-node coordination
- **Decision** (user-asserted 2026-05-18; architectural invariant): there is
  no node-to-node operation in the system, and there must not be one. The
  only cross-node coordination is raft (the existing envelope/commit log
  every kv write already uses). The shipped connection-actor is worker-local
  park + worker-local resume; if push projections are ever built, their
  fan-out reuses a *centralized* side-process that workers POST to —
  architecturally identical to worker→files-server / worker→log-server —
  never a node-to-node primitive.
- **Why**: a second cross-node protocol would re-open the membership,
  ordering, and partial-failure questions raft already answers, for a
  notification path whose contents are explicitly losable.

### 13.4 Callback execution: continuation-affinity, nothing replicated, moot-on-loss
- **Decision** (modeled 2026-05-18; shipped 2026-06-03, `dcb7c6b`, as the
  cross-worker held-state routing): a continuation callback routes to the
  worker *holding* the continuation — a live, node-local, in-memory object —
  addressed by owner registry (`MsgRouter.bound_fetch_owners` /
  `bound_send_owners`; registry-first resume with the `hash(tenant)` route as
  fallback), not by hashing the tenant. Callback *result delivery* bypasses
  raft entirely; only the hop's own kv writeset rides envelope-0, like any
  request. Node death ⇒ the continuation is gone ⇒ the callback drops
  (moot-on-loss: the held connection died with the node, and the synchronous
  caller retries the whole request).
- **Why**: the chain is born on one worker and every hop routes back to it,
  so per-tenant lock-locality falls out without a pinning rule; replicating
  continuation state would buy durability for an object that is worthless
  once its connection is dead.
- **Two callback classes — do not conflate**: *continuation* callbacks
  (above) versus *stateless* fire-and-forget callbacks with no parked
  continuation. The latter's durability is the §3.3 owed/proof markers on
  the per-tenant kv path, recovered per §3.4. Likewise, an external call and
  an internal continuation are **distinct call shapes that compose** — there
  is no fused `http.send(on_result)` primitive; "held-sync" is a best-effort
  external call plus an explicitly returned continuation.

### 13.5 "At-least-once" split: no-silent-loss is platform; retry-to-2xx is a JS lib
- **Decision** (2026-05-18; implementation shipped via §3.3 + §3.4):
  "at-least-once" conflated two guarantees. **Meaning-1 — no-silent-loss**
  (a send is *owed* until there is durable proof it was attempted and
  recorded; absent proof after a crash, it re-fires) is the platform
  guarantee, and it rides the per-tenant kv/raft path: the owed marker is
  part of the issuing hop's own committing writeset (free and atomic), the
  proof is a per-tenant write on callback — N-way by construction, no
  central store, no pinned thread. **Meaning-2 — auto-retry-to-2xx** is an
  application policy and was never platform; it is the customer-composable
  `retry.*` JS lib. The old cluster-wide schedule store + leader-pinned
  firer was an *implementation* of Meaning-1, not its essence; deleting it
  removed the funnel while keeping the guarantee. Duplicate fires remain
  possible by design (re-fire on missing proof), so resolve-once /
  idempotency at the consumer stays a requirement — that is the irreducible
  cost of keeping no-silent-loss without a funnel.
- **Steady-state no-scan invariant** (engine-independent): dispatch work is
  found by per-worker collection membership fed at apply time; never a
  per-tick scan, and never an O(N_tenants) walk on the hot path. The durable
  `_send/owed/` rows are the crash-recovery backstop, not the dispatch
  trigger; they live in snapshotted per-tenant state precisely because raft
  log compaction would GC an owed-but-unproven entry older than the last
  snapshot.
- **Rejected** (recorded here because `http-send-plan.md` §15.8, where the
  full analysis lived, was deleted):
  - **Pure best-effort as the default** — loses no-silent-loss: on node
    death the handler receives *nothing* (not even a failure), and
    fire-and-forget sends vanish. Kept only as the semantics of the bare
    primitive; durability composes on top (§3.3).
  - **(c) Central send-index with N-way locator-routed execution** — wins
    recovery decisively (one central scan) but every `http.fetch`-with-
    durability writes one shared structure: a cross-tenant write hot spot,
    exactly the contention per-tenant `app.db` isolation measurably removes.
    The legacy funnel was the pinned firer, not the store — but a central
    store trades the execution funnel for a write funnel. Irreducible: you
    cannot have one place to scan *and* N independent places to write.
  - **(d) Per-worker schedule stores** — durable state keyed by `--workers`
    (an unstable runtime fan-out parameter; shrinking it orphans stores)
    reverses the interchangeable-workers architecture, and the owed marker
    in (b) is already free and atomic inside the hop's own writeset, which a
    separate per-worker keyspace cannot match without multi-envelope
    coupling. Stabilizing the shards (fixed shard ids + a rebalancer)
    reinvents a consumer group — the cross-node coordination §13.3 forbids.
  - The **tradeoff triangle** that frames all of these — pick two of
    {no-silent-loss · no resolve-once complexity · N-way (no funnel)}. The
    shipped choice keeps no-silent-loss and N-way, and pays resolve-once.

**Still open (tracked in issues, not decisions — outbound WS is issue #94):** push
projections (the centralized fan-out side-process) are unbuilt; outbound
WebSocket is unstarted; the fairness policy for the callback execution phase
(a held-sync continuation is a user waiting synchronously — plain FIFO against
fresh requests is not obviously right) is undecided.

### 13.6 Saga identity: the durability boundary is the saga boundary
- **Decision** (2026-08-17, locked in conversation): a saga follows the
  **live continuation structure** — a held connection's chain, or a
  connectionless root's direct `next()` chain. **Crossing the durability
  boundary roots a new saga**: anything that parks intent in the Model
  and fires later (`schedule`/`cron` `_sched/*` entries, `webhook.send`'s
  owed markers, subscription dirty markers) is a fresh external cause at
  fire time. Consequences: a `webhook.send` `{on}` callback belongs to the
  *delivery's* saga (the durable wake that executed the send), never the
  sender's; a send bound to a HELD caller resumes the held chain and so
  stays in the connection's saga — the same rule, since nothing durable
  was crossed on the resume path. This is L2's reconstruct-vs-abandon
  distinction surfacing in identity: a Continuation that reconstructs
  from the Model is connected to its armer only *through* the Model, and
  an unbounded causal-closure saga (webhook retries fire hours later)
  would never settle as a unit of playback.
- **Provenance, not inheritance**: the arming saga rides the durable
  entry (`_sched/*.armed_by`) and lands on the fired activation's record
  as the reserved `_parent` tag — the saga viewer's cross-saga jump. A
  coalesced subscription fire deliberately gets NO parent (N writes
  coalesce into one fire; a single parent would be a lie). A cron
  recurrence's re-arm records the previous fire as parent — a linked
  list back through fires, which is what actually happened.
- **Rejected**: full causal-closure inheritance (the pure reading of
  "one external cause and everything it triggers") — it makes every
  requesting saga unbounded through its durable effects, resurfaces
  week-old sagas on retry activity, and erases the connection/
  connectionless axis the whole verb surface teaches. Also rejected:
  literal connection-only continuation (shattering a connectionless
  root's `next()` chain into single-hop sagas) — those hops are one
  RAM-enqueued execution, not decoupled work.

## 14. Format & protocol versioning (pre-launch freeze)

The locked rules from the pre-launch versioning sweep. **Full as-built spec —
every wire/on-disk format, the JS-engine-version tag, and the freeze-list
mechanics — is [`architecture/format-versioning.md`](architecture/format-versioning.md);
the source cites its `§`-anchors directly.** Shipped 2026-06-23; prod
re-genesis'd under the frozen v1 formats 2026-06-26.

- **Version-byte + interpretation-switch, never silent widening** (`§3`): every
  wire/persisted format that can change carries an explicit version byte/field
  (frames, packed certs, node-address frames, readset/tape bundles); the reader
  switches interpretation on it. Prefer same-width + a version switch over
  widening a field (see also `feedback` wire-width-vs-interpretation). Freeze v1
  now + wipe dev/prod so there is never a v0→v1 migration — the field just has to
  be *in place* so the *next* change is backward-compatible (this is why
  no-pre-launch-back-compat is safe here).
- **JS engine version tag** (`§4`): every request records which engine ran it,
  so replay can pull the matching engine for an old record — a genuine net-new
  field, plumbed through the tape/log.
- **Reserved `_`-leading KV namespace** (`§7.1`): the entire leading-`_` keyspace
  is platform-only for **writes** (JS shims write it via a privileged path);
  customers own all non-`_` keys. Reads of `_` are not blocked. One rule,
  forever-extensible.
- **Reserved internal headers + URL paths/hostnames** (`§7.3`/`§7.7`): `x-rove-*`
  request headers and `/_system/*` paths + `*.internal` hosts are platform-owned
  and stripped/blocked at the boundary.
- **Customer-facing IDs are opaque prefixed strings** (`§7.5`): `req_`/`dep_`/
  `ftch_`/… — prefixed, not bare integers, so the internal representation stays
  free to change (Hyrum's-law insurance).
- **Widen-don't-tighten on customer-observable constraints** (`§7.4`): loosening
  a limit (tenant-id charset/length, write-size caps `§7.2`) is always safe;
  tightening one is a breaking change and needs a version gate.
- **Crypto algorithm agility** (`§7.8`): the signing algorithm is detectable in
  the artifact; verifiers ignore an unknown alg rather than hard-failing, so a
  new alg can roll without a flag day.

## 15. Code organization & refactoring

### 15.1 Decouple before you split — invert two-way logic coupling to a DAG *first*

- **Decision** (2026-07-22, from the front `proxy.zig` and `js/worker`
  decompositions): before decomposing a god-struct or god-file across multiple
  files, first **invert any two-way *logic* coupling** between the would-be
  clusters into a one-way edge — then the file split is a mechanical move. The
  ordering is load-bearing: **decouple, then split**, never the reverse.
- **What "invert to a one-way edge" means**: pick the natural DAG direction (the
  heavily-depended-on cluster is the base) and remove the light back-edges by one
  of — emitting **outcomes as data** the caller dispatches (front pool →
  `dispatchWaiterOutcomes` instead of the pool calling into flow/ws); making the
  cross-cluster handle **opaque** (the pool's `Waiter` became `{ kind, ptr:
  *anyopaque }`, so the pool never names `*Flow`/`*WsTunnel`); **relocating** a
  primitive to the base layer so both sides call it downward (`flushResumeFetches`
  moved into `worker_streaming`); or routing an up-call **through a hub** the
  caller already holds (`worker_streaming` dispatches held-chain resume via
  `worker.resumeHeldBoundFetch` instead of importing `worker_ws`/`worker_drain`).
- **Why**: a mechanical split of a cyclically-coupled cluster does not remove the
  cycle — it **relocates it behind an import cycle** and adds hot-path
  indirection (or, if done with `worker: anytype` to dodge naming the type, it
  *also erases the type-checking* that would have caught a mis-wire). The result
  compiles and looks decomposed but the dependency graph is unchanged. Inverting
  the logic edge first turns the split into a pure relocation whose moved bodies
  are byte-identical — verifiable and low-risk, even on the request hot path.
  Evidence: the front pool/ws_tunnel split was **blocked** until the pool↔flow↔ws
  decouple landed (opaque `Waiter` + outcomes-as-data); afterward the file moves
  were mechanical. The `worker_streaming↔ws↔drain` triangle inverted the same way
  (four back-edge call sites) with no behaviour change.
- **The distinction that scopes the work** (see the audit residue in the
  refactor tracker): an **import cycle is not automatically a logic cycle.** A
  reexport hub — one struct whose methods are split across sibling files, where
  the siblings import the core *for the type only* and the core re-exports the
  siblings' functions — is a **benign** import cycle (comptime-concrete, zero
  runtime cost) and is **left as-is** (`consensus/node_*`, the `globals`/
  `bindings` reexport hub, a module's `root.zig`). Only a genuine **two-way logic
  cycle** — each side *calling into the other's behaviour* — earns a decouple,
  and each is a deliberate, hot-path-gated change, not a mechanical sweep. An
  `@import`-graph scan finds the *former*; it **misses** the latter when it lives
  inside a single not-yet-split file (the front pool cycle was invisible until
  the split attempt surfaced it), so this is a per-cluster design judgement, not
  a lint.
- **Rejected**: (a) a blanket "make every module a strict DAG" sweep — most
  cycles are benign reexport hubs, so the sweep is churn; the cost lives in the
  few genuine logic cycles. (b) Splitting a god-struct via `self: anytype` / a
  reexport hub *without* first decoupling — it papers the cycle over and drops
  type-checking. (c) Dissolving a god-hub itself (e.g. `worker.zig`'s coupling to
  every spoke) as part of a cycle pass — that is the separate, larger
  illegal-states / owned-sub-struct goal, not decoupling.
