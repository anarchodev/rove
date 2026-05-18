# Unified post-propose effect gating (reconciler design)

> **Status**: design, 2026-05-17. Resolves the bug class in
> `docs/proposer-audit.md` (premature external-effect release at
> *accept*). Design only — no implementation. Depends on / must be
> reconciled with the parallel `docs/connection-actor-plan.md` (SSE
> delivery model) — see §7.

## 1. Problem (one paragraph)

Per `proposer-audit.md`: kvexp `txn.commit()` is a speculative
volatile overlay (persists to LMDB only at raft-apply), so a crash
before quorum causes **no on-disk KV divergence**. The real bug is
**premature external-effect release**: 9 Class-B-broken proposers
release an externally-observable effect (synthesized response, SSE
`events.emit`, `on_result` callback, `email.send`, `webhook.send`)
at **accept** (`propose()` returned) instead of at the durability
gate. Raft may truncate an accepted-but-uncommitted entry on leader
change (it never happened, by raft's rules) — but the effect already
escaped. Only the H2 path gates correctly, and only for the *response*
(`pending_txns`+`RaftWait`+`drainRaftPending`); even H2 fires SSE
emits at accept (§3.2).

## 2. The invariant + the gate

> No externally-observable effect may be released until its raft entry
> is **committed** (`committedSeq() >= seq`).

**One uniform gate: `committedSeq() >= seq`.** The commit-vs-apply
sub-distinction collapses here — kvexp's speculative overlay serves
reads on the committing (leader) node from local-commit time, and
reads are leader-only (§6c), so commit ≈ apply for read-visibility
for every kvexp-backed effect (KV + schedule store = the whole
surface). No per-effect-kind branch. (`proposer-audit.md` kvexp-
collapse note.)

## 3. Mechanism (the non-negotiable correctness core)

Two pieces, both already present in the H2 path — generalise them:

1. **Effect buffering.** Every external effect a dispatch produces is
   *accumulated, not released*: the response (already staged on the
   entity), SSE emits (today fired immediately by `fireEmits` —
   `tenant_batch.zig` post-`propose`, and worker_dispatch per §3.2),
   `on_result`-trigger, callback-receipt finalisation. The buffer is
   attached to the parked unit.
2. **One seq-keyed park + one drain.** Generalise H2's
   `pending_txns[seq]` + `RaftWait{seq}` + `drainRaftPending` into a
   single reconciler keyed by propose seq. The drain, each tick:
   - `committedSeq() >= seq` → **commit**: finalise the txn
     (drop-undo) and **release the buffered effects**.
   - fault / `faultedSeq() >= seq` / timeout → **rollback**:
     `undoTxn` (where a local speculative commit exists) and
     **discard the buffered effects** (they never escaped).

This is exactly what `drainRaftPending` does for the H2 *response*
today. The fix is (a) extend it to release the *emit/callback*
buffer too (closes §3.2 systemically — see §6), and (b) let non-H2
proposers register parked units instead of fire-and-forgetting.

## 4. Two options — and the recommended decoupling

**Option A — one-request-lifecycle (the destination).** Every request
— H2, internal-schedule, callback, … — becomes an entity in the
shared `request_out → dispatch → raft_pending → response_in`
lifecycle; origin only selects the finalize disposition. The dance
becomes *structural* (collection membership = "pending raft"),
re-implemented nowhere. Subsumes the per-tenant-batching refactor
(tasks 7–9): internal/callback flowing through `dispatchOnce`'s
anchor/blocked/`finalizeBatch` get batching for free. Most
principled; the user's model. **Highest blast radius** — it
restructures the most sensitive H2 machinery *and* injects synthetic
entities (no client stream) into it.

**Option B — `ParkedUnit{seq, txn, effects, on_commit, on_fault}`
reconciler (the mechanism).** Extract H2's park/drain concept into a
generic seq-keyed unit + one drain. Each Class-B proposer registers a
unit after propose instead of fire-and-forgetting; the side paths keep
their structure. Smaller blast radius; does not dedupe the parallel
dispatch paths (the thing A cleans up).

**Recommendation — decouple correctness from cleanup** (the discipline
this session has repeatedly validated: minimal correct fix first,
architectural unification as a separate deliberate follow-up; never
gate correctness on the dragon):

- **Correctness fix = Option B's mechanism, and it is mandatory.** A
  single `ParkedUnit` + one drain (generalised `drainRaftPending`).
  Migrate Class-B proposers onto it idiom-cluster by idiom-cluster.
  This closes the divergence bug **without** restructuring the H2 hot
  path or injecting entities — it can ship incrementally and safely.
- **Cleanup = Option A is the destination, and it *follows*.** The
  side paths' structural collapse into `request_out` happens
  opportunistically *after*, where it removes code — driven by the
  parallel `connection-actor-plan.md` (which is already heading at the
  request/connection unification). Correctness does **not** wait on
  the full A migration.

Net: ship B (correctness), converge to A (architecture) — same
"mechanism now, unification deliberately later" call as the
drainTenantBatch / envelope-merge decisions earlier in this stream.

## 5. Per-origin finalize dispositions

The park/gate is uniform; only `on_commit`/`on_fault` differ. All
bounded:

| Origin | on_commit (release) | on_fault (discard) |
|---|---|---|
| H2 (reference) | deliver response + buffered emits | `undoTxn` + 503 (existing) |
| internal-schedule (`tenant_batch`) | release `schedule_complete` + emits + `on_result` trigger | discard; schedule stays due → re-fires on new leader (at-least-once; nothing escaped) |
| callback (`tenant_batch`) | release receipt-delete + emits | discard; receipt stays → re-runs |
| idiom-2 (deployStarter / releases.publish / `platform.scope.kv` / admin-kv) | drop-undo | `undoTxn` (undo log already present) |
| idiom-3 (`platform.root.*` / ACME cert) | drop-undo | `undoTxn` / re-derive on next ACME pass |
| idiom-4 (config-mirror) | drop-undo | none needed (idempotently re-derived) |

## 6. The §3.2 systemic SSE fix

Even the *correct* H2 path fires SSE emits at accept (sse-plan §3.2,
"ordering relative to local accept, not cluster commit"). Decision
2026-05-17 overruled that: SSE emit must gate on commit. The fix is
small and lands in the same generalised drain — the emit buffer is
released by `on_commit`, discarded by `on_fault` — applied to **all**
origins including H2. This fixes §3.2 systemically rather than per
path. **This is exactly the surface `connection-actor-plan.md` owns**
(SSE delivery) → §7.

## 7. Open questions / risks

- **The dragon.** Generalising `drainRaftPending`/`pending_txns`
  touches the speculative-apply core every H2 request depends on, and
  adds ~9 new registrants. The codebase has eaten this class before
  (Stage-5 apply-after-replicate, reverted). **H2-reference-first:**
  generalise the drain with H2 behaviour *byte-identical* (prove via
  existing `http_send` / `leader_failover` / kv-bench smokes), *then*
  add non-H2 registrants one idiom-cluster at a time.
- **Connection-actor overlap (load-bearing).** `connection-actor-plan
  .md` (parallel work, commit `92b26e6`) designs the SSE/WS delivery
  model. §6's emit-gating and that doc's delivery model **must be
  designed together** — gating emits at commit changes when the
  connection actor sees them. Reconcile before implementing §6; do
  not ship two SSE delivery models.
- **Effect-buffer location.** Where does the emit/`on_result` buffer
  live between accept and the drain? H2 stages the response on the
  ECS entity. Non-H2 paths have no entity (until Option A). For
  Option B the `ParkedUnit` owns the buffer (allocated with the unit,
  freed on commit-or-fault). Bounded by per-dispatch effect count.
- **email.send / webhook.send.** These are themselves `http.send`
  Cmds that ride the writeset/outbox and are carried out by a
  *separate delivery loop after the schedule row applies* — so they
  are **already apply-gated** and are *not* in the premature-release
  set. Confirm (read the delivery-loop trigger) before excluding
  them; the audit lists them for completeness but the live offenders
  are the response, SSE emits, and `on_result`.
- **Migration order:** idiom-1 (`tenant_batch` internal+callback)
  first — highest traffic, externally observable, single fix point,
  and the SSE-escaped-effect fault test (task 14) is built alongside
  it as its regression gate. Then idiom-2 (4-site fire-and-forget
  family), idiom-3 (root/ACME), idiom-4 last (self-healing).

## 8. Scope

Design only. Follow-on (not this session): generalise the drain
(H2-reference-first); build the SSE-escaped-effect fault gate
(task 14, paired with idiom-1); migrate idioms 1→4, each gated by
that test; reconcile §6 with `connection-actor-plan.md`. The
correctness fix (B mechanism) is mandatory and incremental; the
Option-A collapse is the deliberate architectural follow-up.
