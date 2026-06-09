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
decisions and rejected paths only. V2 is on branch `v2`; Phases 0–7 shipped
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

### 10.5 Role-aware apply + store unification
- **Decision**: the **leader** skips the replicated store write (the worker's
  `TrackedTxn.commit` is durable); a **follower** writes it, into the worker's
  *own* serving store (`StoreResolver`), so a promoted follower serves exactly
  what it replicated.
- A write in flight at a leader change is **faulted + retried** (503), **not
  lost** — explicit per-entry FIFO seq binding (counting seqs is wrong multi-
  node: proposes can fail; followers apply with no local proposer). Zero-failed-
  request moves under continuous load are Phase 7.

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

### 10.7 Codec: prost (pre-generated), vendored raft-rs
- **Decision**: vendor raft-rs with **prost-codec**, pre-generated `.rs` (no
  `protoc` at build time), `panic = abort` / `lto`.
- **Why**: per-message protobuf **decode** is the real per-message cost (batching
  the `step` FFI bought 0× — the Zig↔C↔Rust boundary is sub-µs), so a
  faster/smaller codec is the lever, not the FFI shape.

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
  `architecture/control-plane.md`; enforcement levers: `plan-tiers.md`; accounts/
  billing product layer: `platform-accounts-model.md`.

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
