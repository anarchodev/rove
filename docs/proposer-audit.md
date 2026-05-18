# Raft proposer audit (divergence workstream — keystone)

> **Status**: scoping artifact, 2026-05-17 (revised — bug class
> re-framed after empirical fault-injection). Enumerates every
> application-level raft proposer and classifies each by whether it
> releases an externally-visible effect before the entry is durable.
> Read-only analysis; feeds the fault-injection test and the
> unified-reconciler design.

## The bug class (revised)

**Superseded framing (kept per the §7-superseded discipline):** the
first cut of this doc called the bug *on-disk KV divergence* — a
proposer commits a local `TrackedTxn` then proposes, and on a
post-propose fault the leader keeps a write the cluster truncates.
**Empirical fault-injection (`scripts/divergence_faultinj_smoke.py`)
disproved that:** kvexp's `txn.commit()` is a **speculative, volatile
in-memory overlay** that only persists to LMDB at raft-*apply*. A
crash before quorum loses the overlay entirely → **no on-disk KV
divergence.** That half of the original premise was wrong.

**The actual bug — premature effect release.** kvexp volatility keeps
the *KV store* consistent, but it does not unsend an
**externally-observable, irreversible effect** that was released
against the speculative state:

> A proposer is **unsafe** iff it releases an external effect — the
> synthesized/HTTP response, an SSE `events.emit`, an `on_result`
> callback with external side effects, `email.send`, `webhook.send` —
> at **accept** (`propose()` returned) rather than at the effect's
> correct durability gate. On a post-propose fault raft truncates the
> entry (it never happened, by raft's own rules) but the effect
> already escaped: the outside world believes X; the durable system
> has no X.

`propose()` returning ok = **appended to the leader's local log**
(accept), **not** quorum. Raft's safety rule is *act only on
*committed* entries*; releasing an effect at accept is acting on a
merely-appended entry that raft may discard on leader change.
`cluster.propose` → `NotLeader`/`faultedSeq()` only covers the
*synchronous* "lost leadership **before** propose"; the post-propose
window is the gap. Only the H2 path closes it **for the response**
(`pending_txns`+`RaftWait`+`drainRaftPending` release the response at
`committedSeq≥seq`) — and **not even H2 closes it for SSE** (§3.2
fires emits at accept by an explicit, now-overruled tradeoff).

## The release gate is per-effect-kind

The invariant is *effects only on committed entries*, but the trigger
splits:

- **Self-contained effects** — HTTP response with the result inline,
  `email.send`/`webhook.send` with a full payload: gate on **commit**
  (`committedSeq >= seq`). Durable, no follow-on read. H2's
  `drainRaftPending` already does exactly this; it is sufficient
  there.
- **Notify-then-read effects** — SSE `events.emit` ("something
  changed → go read"), an `on_result` that makes a client/handler
  re-fetch: in principle gate on **apply**, not merely commit (the
  recipient *immediately reads*, and "committed in the raft log" ≠
  "applied to the store about to be queried").

> **kvexp collapse (note 2026-05-17):** for kvexp-backed effects —
> i.e. KV writesets **and** the schedule store, which is the dominant
> case here — commit ≈ apply for *read-visibility*. kvexp's
> speculative `main_overlay` serves reads on the committing node from
> local-commit time, and loop46 reads are leader-only (§6c), so once
> `committedSeq >= seq` the value is already read-visible on the
> leader via the overlay; the apply→LMDB step is a *durability*
> concern, not a read-visibility one. So the apply-vs-commit split
> largely **collapses to a single gate, `committedSeq >= seq`
> (commit)**, for essentially every effect in this codebase. A true
> apply gate would only matter for a non-overlay-backed or
> genuinely-cross-node-read effect, which loop46 does not have. Net:
> the reconciler needs **one** gate, not a per-effect-kind branch —
> a useful simplification for task 15. The accept-vs-commit invariant
> is unchanged; only the commit-vs-apply sub-distinction evaporates.

**§3.2 resolved (decision 2026-05-17):** accept-time SSE emit is a
**bug**, unconditionally in scope — accept isn't even commit. "SSE on
apply" is correct in principle but, per the kvexp-collapse note, in
practice means "SSE on commit" (`committedSeq >= seq`) here. The
`rove:resync` sub-question is moot: the window is being closed.

## Classification

(The site inventory below is unchanged — the same proposers are the
offenders — but read "commit vs propose" as *effect-release vs the
per-effect gate above*, and "divergence" as *escaped-effect /
state mismatch*, not on-disk KV divergence.)

- **Class A** — propose-only; **apply is the sole writer**; releases
  no external effect against speculative state. A fault → the entry
  never applies anywhere → at most an at-least-once re-fire (a
  contracted property). Safe.
- **Class B-correct** — releases its effect only at the correct gate
  (H2 response: `drainRaftPending` at `committedSeq≥seq`).
- **Class B-broken** — releases an external effect at **accept**
  (propose-returns), before its gate. *(self-healing)* = the only
  escaped effect is an idempotently re-derived state write with no
  external observer, so the window is benign — still mis-gated.

## Per-site classification (evidence)

| Site | What it writes | commit vs propose | Reconciler | Class |
|---|---|---|---|---|
| `worker_dispatch.zig:204` proposeBatch (H2 hot path) | tenant app.db writeset | txn **parked** (`pending_txns[seq]`), not committed until raft confirms | `RaftWait`+`drainRaftPending` (commit / `undoTxn`+503) | **B-correct** |
| `worker_dispatch.zig:1077` proposeWriteSet (`POST /_system/release`) | `_deploy/current` + manifest writeset | speculative `txn.commit()` (undo-logged) then propose | parks `RaftWait{seq,txn_seq}`; `drainRaftPending` drop-undo / `undoTxn`+503 | **B-correct** |
| `worker_dispatch.zig:1212` proposeWriteSet (admin-kv bootstrap) | `__admin__` app.db writeset | `txn.commit()` → propose (catch-warn) → `commitTxn` **drops undo immediately** | none | **B-broken** |
| `worker_dispatch.zig:1942` proposeRootWriteSet (`platform.root.*`) | `root.db` (written in handler callbacks) | local write already landed, then propose (catch-warn) | none — comment: *"leader wrote, followers may diverge"* | **B-broken** |
| `worker.zig:1235` proposeWriteSet (deployStarter `_deploy/current`) | tenant app.db `_deploy/current` | `txn.commit()` → propose (catch-warn) → `commitTxn` drops undo | none | **B-broken** |
| `worker.zig:1328` proposeWriteSet (releases.publish `_deploy/current`) | tenant app.db `_deploy/current` | same idiom; comment: *"Fire-and-forget … local commit is durable; raft settles async"* | none | **B-broken** |
| `worker.zig:1398` proposeWriteSet (`platform.scope.kv` cross-tenant) | target tenant app.db | `txn.commit()` → fire-and-forget propose → `commitTxn` | none — comment: *"Fire-and-forget"* | **B-broken** |
| `worker.zig:2114` proposeWriteSet (config mirror) | tenant app.db `_config/*` | `txn.commit()` → propose (else-warn) | none, but mirror is idempotently re-derived from the manifest each pass | **B-broken (self-healing)** |
| `internal_schedules.zig:540` proposeMulti (`InternalPolicy` via `tenant_batch`) | tenant app.db writeset + schedule_completes | `txn.commit()` then `proposeMulti` | `undoTxn` **only on synchronous** propose error (`tenant_batch.zig:111`); seq-gate stops *re-dispatch* but not *divergence* | **B-broken** |
| `callback_dispatch.zig:211` proposeBatch (via `tenant_batch`) | tenant app.db writeset (incl. receipt-delete) | `txn.commit()` then `proposeBatch` | `undoTxn` only on synchronous propose error; no post-propose reconciler | **B-broken** (confirms the latent callback bug — same class as internal) |
| `acme.zig:210` raft.propose (`cert/{host}`) | `root.db` `root.put` + on-disk cert materialise | local `root.put` + materialise, then propose (catch-warn) | none (partially self-heals on next ACME renew) | **B-broken** |
| `internal_schedules.zig:559` proposeDemote (envelope-11) | nothing local — apply flips `is_internal` | propose-only | n/a — fault → demote never applies → row retried (at-least-once) | **A** |
| `schedule_server/thread.zig:367` raft.propose (external/libcurl scheduler) | nothing local — apply writes schedules.db; external HTTP already done | propose-only | n/a — fault → schedule_complete never applies → re-deliver (the contracted http.send at-least-once) | **A** |

(`cluster.zig:745` is the low-level `raft.propose` primitive every
site above is built on, not an application proposer.)

## Tally + scope

- **Class A (safe):** 2 — `proposeDemote`, external scheduler.
- **Class B-correct (does the dance):** 2 — both in the H2 request
  lifecycle (`proposeBatch`, release).
- **Class B-broken (divergence window):** **9** — admin-kv, root_
  writeset/`platform.root.*`, deployStarter, releases.publish,
  `platform.scope.kv`, config-mirror *(self-healing)*, internal-
  schedule, callback, ACME cert.

**Only the H2 lifecycle does the post-propose fault dance.** Every
other commit-local-then-propose path is broken — the user's hypothesis
("anything firing off the hot path not doing the dance is probably a
correctness bug") is empirically confirmed and bounded to 9 sites.

The 9 collapse into **a few idioms, each fixable once**:

1. **`tenant_batch` path** — internal-schedule + callback (2 sites,
   one shared fix; `tenant_batch.zig` already centralises their
   commit/propose).
2. **`commit → fire-and-forget proposeWriteSet → commitTxn(drop-undo)`
   idiom** — deployStarter, releases.publish, `platform.scope.kv`,
   admin-kv (4 sites, identical shape; one shared fix).
3. **root.db replicate-after-local-write** — `platform.root.*`,
   ACME cert (2 sites; root_writeset variant of idiom 2).
4. **config-mirror** — self-healing; lowest priority (idempotent
   re-derivation already bounds the window).

## Conclusion → next steps

The proven template is the H2 lifecycle's `RaftWait` +
`drainRaftPending` + kvexp undo-log: *propose, park the
speculatively-committed txn keyed by seq, finalise (drop-undo) when
`committedSeq() >= seq`, `undoTxn` on fault/timeout.* The unified
reconciler generalises exactly this so the 9 Class-B-broken sites
park a unit instead of fire-and-forgetting.

- **Fault-injection test (task 14)** should target idiom 1 (internal-
  schedule + callback — `tenant_batch`) first: highest traffic, the
  effect is externally observable, cleanest single fix point. Subscribe
  SSE to the target tenant; trigger the internal schedule; freeze
  followers so it cannot reach quorum; **assert the SSE subscriber
  receives the emit** (effect escaped at accept); kill the leader
  pre-commit → the writeset that emit announced never durably exists.
  Asserting on-disk KV is wrong (kvexp volatility → no KV divergence);
  the observable is the *escaped effect*, not the store.
- **Design doc (task 15)**: the user's one-request-lifecycle model
  (every request an entity in `request_out`, origin-tagged finalize)
  is the leading option — it makes the dance automatic for all 9 by
  collapsing the side paths into the H2 lifecycle that already does
  it; the narrower `ParkedUnit{seq,txn,on_commit,on_fault}` reconciler
  is the fallback if full migration proves too invasive. Stage
  H2-reference-first, each migration gated by the fault test.
