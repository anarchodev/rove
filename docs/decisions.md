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
  - **The living sub-plans** (`effect-algebra.md`, `effect-reification-plan.md`,
    `handler-shape.md`, `snapshot-plan.md`, `readset-replication-plan.md`,
    `streaming-handlers-plan.md`, `deployment-snapshots-plan.md`,
    `auth-domain-plan.md`, `durable-wake-plan.md`, …) which remain the as-built
    architectural references for *how* each shipped system works. This file
    records *what was decided and why*, not the mechanics.
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
- **Decision** (as-built, from the retired `raft-kv-design.md`): the `rove-kv`
  `Cluster` is one raft group fronting N pluggable stores, with
  **multiple-envelopes-per-entry atomicity** (`LeaderTxn` for multi-store atomic
  commits). Backend is pluggable (SQLite today). Snapshot tick is
  stamp-and-compact across all stores. Learner peer mode + peer-to-peer
  `send_snapshot`. Application-level request routing is registered separately
  from the library. Two live consumers: loop46 and the files-server standalone.
  The optional `rove-kv`→`raft-kv` rename is deferred (build.zig still exports
  `rove-kv`).

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
  `effect-reification-plan.md` + `effect-algebra.md`): every external effect must
  be a *declaration* over four reified primitives (Model, Continuation, Msg
  origins, Cmd runtimes) under `src/js/effect/`, not a hand-rolled subsystem.
  `Cmd` and `Msg` are compiler-enforced tagged unions. Cancelled as part of this
  arc: Phase 4.1.4 `conn_write` (deferred to inbound-WS) and Phase 7
  files-server collapse.

### 3.3 Durability is composed in JavaScript shims, not Zig primitives
- **Decision** (shipped 2026-05-24, `b908953`, net −4.7 kLOC Zig): there is **one
  outbound HTTP primitive** (`http.fetch`). `webhook.send` / `email.send` /
  `retry.*` are JS standard-library shims that compose durability on top of it
  (`kv.set` owed-marker + `http.fetch` + a per-worker sweep). The dedicated
  `http.send` Zig primitive, the schedule envelopes, and the leader-local
  `SendDispatch` were all retired.
- **Inputs durable / outputs derivable**: `blob.put` / `blob.get` are likewise
  **JS shims, not Zig Cmd primitives** — the marker key holds a pointer
  (`{correlation_id, seq, call_index, dest_key}`), never the bytes; recovery is
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
  5. Marker-commit race: an inline fetch can complete before the handler's
     writeset commits via raft. Shipped mitigation is sweep-only (~1s first-fire
     latency); the proper fix is the commit-gated Cmd buffer (effect-reification
     Phase 4.1, the one remaining active phase).

### 3.4 Owed-recovery is a boot-scan of `_send/owed/`
- **Decision** (Option (b), shipped 2026-05-19): at process start, reconstruct
  the in-flight/timer set with a single-pass boot-scan of `_send/owed/` across all
  tenant DBIs (the per-tenant kv write is the authoritative source). Measured
  ~89µs/tenant realistic, ~210µs pessimal → ~0.9–2.2s per 10k tenants; the
  ~1–2s/10k RTO budget is accepted. Mitigation levers (fold the probe into
  `Manifest.init`; shard across workers) are known but deliberately not built —
  escalate only past ~10k tenants/node and re-run `owed_recovery_scan_bench.zig`.
- **Rejected**: (a) lazy recover-on-tenant-open — silently drops a quiet
  tenant's cron/delayed sends; (c) "snapshot-in-one-shot" — illusory in kvexp,
  where walking the snapshot ≡ walking the DBIs ≡ the boot-scan. The only way to
  avoid the per-tenant walk is a central index (rejected: cross-tenant hot spot)
  or a second raft snapshot.

### 3.5 Subscriptions & streaming gaps (shipped semantics)
- **Subscriptions (gap 2.1, shipped)**: three chain origins without an inbound
  request — cron / kv-react / boot. Cron is throttled to 1 Hz and is **not**
  raft-replicated (leader change resets the clock, by design). The boot marker
  **must** be injected into the handler's writeset *before* the handler runs
  (post-handler injection hits a conflict). Defer in-loop kv-react fires to a
  post-loop drain (avoid iterate-while-modify). Use `JS_NewBigUint64` for `u64 >
  2^63` (deployment ids).
- **Backpressure (gap 2.2, shipped)**: surfaces are bounded — a K=32 wake-
  accumulator ring with a `lost_oldest` counter, and a 256 KB StreamChunks soft
  cap with drop-newest + `dropped_chunks`. Caps are deliberately hard-coded;
  per-tenant configurability is deferred to an operator hook on demand.
- **Streaming `http.fetch` (gap 2.3, shipped)**: Pattern A (`on_chunk`) fires a
  handler activation per chunk; Pattern B (`pipe_to`) streams directly to the
  held response with no handler. **Pattern B bytes are structurally untaped** by
  construction (they never enter an activation), so the tape cap is an
  `on_chunk`-only concern. `correlation_id` is the pipe link.

### 3.6 Per-chain tape cap removed; retention is the right axis
- **Decision** (2026-05-26): the §6 per-chain tape cap was removed. Its
  worst-case (a single chain emitting hundreds of thousands of small
  activations) is already bounded by sequential commit latency (~ms/activation),
  while aggregate traffic outpaces any single chain by 2–3 orders of magnitude.
  The cap traded a small bound for node-wide mutex traffic on the dispatch hot
  path. Per-tenant retention/sampling (a deferred `tape_mode` knob) is the
  correct lever.

---

## 4. Handler surface

### 4.1 One streaming surface: `stream.*` / `on.*` / `next`
- **Decision** (handler-surface redesign, shipped 2026-06-03; see
  `handler-shape.md`): **verb is scope, output is a commit-gated effect, return
  is a disposition.** `stream.*` / `on.*` are current-connection effects;
  `webhook.send` / `schedule` / `cron` are connectionless. Return is a terminal
  body or `next({ctx?})`. The response head is the **ambient `response` global**,
  not a return argument. Dispatch is by named export keyed on activation kind
  (`onWake` / `onDisconnect` / `onFetchChunk` / default). The `stream` pipeline is
  unchanged — only the entry trigger, head, and disposition changed. The old
  `bind:true` / `stream`-return-verb / `detach` framings are retired.

### 4.2 `http.fetch` auto-binds to the held chain; `detach:true` opts out
- **Decision** (shipped 2026-05-29): a held handler's `http.fetch` binds to the
  held chain by default; `detach:true` is the opt-out; `bind:true` was removed.
  Registration happens at the **handler-success seam** (only there is held-vs-
  terminal known). Gotchas: `applyWriteSet` is leader-skipped so only inbound H2
  dispatch sets the `pending_fetches` accumulator; `webhook.send` must be
  excluded from auto-bind via `bound_send_id.len==0` to avoid stealing chunks
  from `__system/webhook_onresult`.

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

---

## 5. Readset replication

### 5.1 Replicate readsets (not intents); gate the callback, not the propose
- **Decision** (Phases 1–6 shipped 2026-05-25/27; see
  `readset-replication-plan.md`): the three-substrate model is **Raft = inputs +
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

- **Decision** (Phases 1–4 shipped/verified 2026-05-16; see `auth-domain-plan.md`):
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
