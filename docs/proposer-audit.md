# Raft proposer audit (divergence workstream — keystone)

> **Status**: scoping artifact, 2026-05-17. Enumerates every
> application-level raft proposer and classifies each by whether it
> can leave the leader's local durable state diverged from the cluster
> on a post-propose fault. Read-only analysis; feeds the
> fault-injection test and the unified-reconciler design.

## The bug class

The H2 request lifecycle and several side paths all mutate replicated
state by proposing a raft entry. The divergence bug is specific:

> A proposer is **unsafe** iff it makes a **local durable state
> mutation** (commits a kvexp `TrackedTxn`, `root.put`, materialises a
> file, …) **before or independent of** the raft propose, **and** has
> **no post-propose fault reconciler** — nothing that, if the leader
> loses leadership *after* `propose()` returns but *before* the entry
> reaches quorum, rolls back / reconciles that local mutation.

On such a fault the proposing node has applied a write the rest of the
cluster never will; when it rejoins as a follower, raft truncates the
uncommitted log entry but the local commit is **not** undone →
permanent divergence until a snapshot resync overwrites it.

`cluster.propose` returning `NotLeader` (incl. `faultedSeq() >= seq`)
only covers *synchronous* "lost leadership **before** propose". The
**post-propose** window (propose returned ok, then no quorum) is the
gap. Only the H2 path closes it (`pending_txns` + `RaftWait{seq}` +
`drainRaftPending`: commit-on-`committedSeq≥S` / `undoTxn`-on-fault).

## Classification

- **Class A** — propose-only; **apply is the sole writer**. No local
  durable mutation precedes the propose. A fault just means the entry
  never applies anywhere → no divergence (at most an at-least-once
  re-fire, which is an inherent, contracted property).
- **Class B-correct** — commits local state speculatively but **does
  the dance**: parks the txn, finalises on raft-commit, `undoTxn` on
  fault. Safe.
- **Class B-broken** — commits local state then proposes with **no
  post-propose reconciler**. Divergence window. *(self-healing)* =
  the diverged state is idempotently re-derived by a periodic pass,
  so the window is transient rather than permanent — lower severity,
  still a window.

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
  divergence is permanent (not self-healing), and it is the cleanest
  single fix point. Kill the proposing leader after propose-returns
  but before quorum; assert app.db divergence on the demoted node.
- **Design doc (task 15)**: the user's one-request-lifecycle model
  (every request an entity in `request_out`, origin-tagged finalize)
  is the leading option — it makes the dance automatic for all 9 by
  collapsing the side paths into the H2 lifecycle that already does
  it; the narrower `ParkedUnit{seq,txn,on_commit,on_fault}` reconciler
  is the fallback if full migration proves too invasive. Stage
  H2-reference-first, each migration gated by the fault test.
