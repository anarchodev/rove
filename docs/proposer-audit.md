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

---

## Addendum — the read-side dual (idiom-0), 2026-05-17

> Added after a fresh-eyes pass asked the broader question this
> doc's title scopes away: not "which *proposer* releases early"
> but "which *externally-visible result* is derived from state
> that has not committed." A proposer audit is structurally blind
> to one path, because that path **never proposes**.

### The hole

A **read-only batch** (`worker_dispatch.zig:147-194`,
`finalizeBatch`'s `!has_writes and !has_cmds` branch) does no raft
hop: it commits its txn locally and immediately moves its entities
`request_out → response_in` — the HTTP response escapes. kvexp's
chain model lets a reader walk *backward through chain
predecessors* (`manifest.zig:1258-1307`, `getLocked`); if this
batch read a key an earlier, still-raft-pending batch wrote, it
observed that predecessor's **speculative, not-yet-committed**
value and kvexp set `Txn.saw_speculation = true`
(`manifest.zig:1245-1249`). On commit the txn takes the chain-head
slow path and returns `Conflict` (the predecessor has not
applied); the code `rollback()`s it — **but still externalises the
response anyway** (the `for (successes.items)` move runs
regardless of the commit/rollback outcome). The in-code comment
already states the defect verbatim:

> *"The customer sees the response based on speculative state that
> hasn't been confirmed yet — same linearizability posture as
> pre-kvexp-bump (the bigger fix is to park such read-only batches
> on raft apply, which needs new plumbing)."*

If the leader crashes before that predecessor's entry reaches
quorum, raft truncates it (it never happened, by raft's own
rules) — but a client was already told a value the durable system
never held. This is exactly the escaped-effect class §"The bug
class" defines; the read-only batch is simply not in the
per-site table because it issues no `propose()`.

### Why the writer dual is already safe and this one is not

A *writing* reader that crossed speculation **is** safe for free:
it parks on its **own** propose seq, raft's commit index is
monotonic, and per-tenant chain order = propose order, so its
commit implies every predecessor it read also committed (and its
txn applies after them). It needs no extra gate — `drainRaftPending`
already covers it.

A **read-only** batch has no seq of its own to park on. It is the
*only* effect class with no native gate, which is precisely why
it is the residual the proposer framing cannot enumerate. (Note
`kvstore.zig:471-473` — "in-flight chain Txns are invisible …
speculative until raft commits" — guards the *no-active-txn lease*
read, which is safe; the leak is the *active-txn chain-backward*
read in a non-proposing batch, a different path than that comment
covers.)

### The engine already exposes the exact predicate

kvexp's `Txn.canSkipRaftPropose()` (`manifest.zig:1456-1462`)
returns `overlay.count() == 0 and !saw_speculation` — i.e. it
*already* answers "is this read-only batch safe to release without
raft." `finalizeBatch` does not consult it; it gates the fast path
on `has_writes`/`has_cmds` (writeset emptiness) **alone**, ignoring
`saw_speculation`. The fix is to honour the predicate the engine
is already computing.

### Classification

| Site | What it externalises | Gate today | Reconciler | Class |
|---|---|---|---|---|
| `worker_dispatch.zig:147` finalizeBatch read-only branch | HTTP response carrying a value read from a chain predecessor's speculative overlay (`saw_speculation`) | none — released at local commit/rollback, independent of predecessor durability | **none** | **B-broken (read-derived)** |

This does not change the proposer tally (it is not a proposer);
it adds one **read-derived** escaped-effect site that the
invariant must also cover. `unified-effect-gating.md` §2's
invariant is hereby read to bind **effects derived from a read of
speculative state**, not only effects released by their own
proposer. The clean-read path (`saw_speculation == false`, the
overwhelming common case — a clean read of applied state) is
unaffected and keeps its zero-cost fast path; the ~100k-req/s
single-tenant readonly floor does not regress.

### The fix (idiom-0)

Minimal, robust, reuses the proven machinery verbatim. In
`finalizeBatch`'s read-only branch, when
`!txn.top.?.canSkipRaftPropose()` (i.e. `saw_speculation` — there
are no writes by construction here):

1. Do **not** take the immediate-release fast path.
2. Issue an empty-writeset **barrier propose**
   (`raft_propose.proposeWriteSet` already always proposes even
   for an empty writeset — its own doc: *"the seq stamp is still
   meaningful as a synchronization point for downstream
   parking"*). This yields a unique gating seq `B =
   highWatermark()+1`, never colliding with any real proposer's
   `pending_txns[seq]` slot. It applies as a no-op type-0 envelope
   on every node.
3. Mirror the H2 write path **exactly** (`worker_dispatch.zig:243-261`):
   `pending_txns.put(B, txn)`; stamp `RaftWait{B,…}`; move the
   entities `request_out → raft_pending`.
4. No `drainRaftPending` change. Its existing entity loop already
   gates the *entity release* on `tracked.commit()` **succeeding**
   (`error.Conflict => continue`, retry next tick), not merely on
   `committed >= seq`. So the response is released only when the
   read-only txn becomes chain head — i.e. every predecessor it
   read has committed **and** applied. Fault / timeout → existing
   rollback + 503. The predecessor-fault **cascade** that frees
   successor txns and nulls their `pending_txns` slots
   (`drainRaftPending.zig` fault branch, the documented
   "later-seq entries … slot already null" path) covers our
   read-only txn for free.

Correctness is therefore robust **even under the
release-lease-before-propose ordering hazard**
(`worker_dispatch.zig:202` releaseLease precedes `:204`
proposeBatch, so propose order need not match chain order): the
chain-head `commit()` gate is causally tied to predecessor
*detachment*, not to seq arithmetic. The borrowed seq `B` only
governs *when polling starts* and the fault/timeout downgrade —
both bounded by the existing `commit_wait_timeout_ns` deadline.

Cost: one extra empty raft entry per *speculation-tainted*
read-only batch only — rare (a read crossing an in-flight
predecessor's overlay under concurrent cross-tenant write load).
`proposeWriteSet` was explicitly designed to carry exactly this
barrier.

### Migration slot

This is **idiom-0**: a precondition-class fix (the read-side dual
of the §"bug class" invariant), independent of idioms 1–4 and
landed the same way — additive, H2-reference-first, gated by its
own paired fault-injection test
(`scripts/readonly_speculation_faultinj_smoke.py`): a read-only
request reads a frozen-follower predecessor's speculative write;
the leader is killed pre-commit; the regression observable is the
escaped read response (the value the client was told, which the
durable cluster never held). Same shape as the idiom-1 gate
(`scripts/divergence_faultinj_smoke.py`), asserting on the
escaped *effect*, not on-disk KV (kvexp volatility → no KV
divergence).

---

## Addendum 2 — idiom-2 remainder: the trampoline determination, 2026-05-17

> Resolves the empirical question commit `01a9592` (admin-kv
> idiom-2) explicitly gated the 3 cross-tenant trampolines on:
> *"parkUndo would be a speculative mechanism without a justified
> caller; their fix shape is gated on resolving the empirical
> kvexp-volatility harm question."* Read-only analysis; no code.

### The three sites

`deployStarter` (`worker.zig:1259-1279`), `releasePublishTrampoline`
(`:1353-1374`), `scopeKvWriteTrampoline` (`:1411-1441`). Identical
shape: `beginTrackedImmediate()` → `txn.put` → `txn.commit()` →
fire-and-forget `proposeWriteSet(target_id)` → `inst.kv.commitTxn(
txn_seq)`. Each writes a **different** tenant's app.db than the
calling handler's dispatch batch, on its **own** txn (deliberate —
`worker.zig:1391-1393`), so it has no entity in the dispatch
lifecycle.

### Finding 1 — the "drop-undo" framing is vacuous under kvexp

`KvStore.commitTxn()` is a **complete no-op**
(`kvstore.zig:949-952`: `_ = self; _ = txn_seq;`).
`KvStore.undoTxn()` is a **no-op stub** (`:940-947`, "do not rely
on it; callers that need this should hold the TrackedTxn and call
`.rollback()` directly"). There is no `kv_undo` table under kvexp
(`recoverOrphans` `:959-966`). So the per-site table's "commit →
fire-and-forget → `commitTxn` **drops undo immediately**" column
describes the **pre-kvexp SQLite undo-log world** and is *stale*:
post-kvexp there is no drop-undo step and no force-durable step —
`commitTxn` does nothing. `txn.commit()` is purely the kvexp
speculative-overlay commit (→ LMDB only at raft-**apply**, per the
§"bug class" empirical finding).

### Finding 2 — zero on-disk divergence; the prior deferral was right

Because `commitTxn`/`undoTxn` are no-ops and the only durability
path is raft-apply, a post-propose pre-quorum fault on a
trampoline behaves **exactly** like every other kvexp-backed
write: the speculative overlay is volatile, a crash/truncation
before apply discards it, and the target tenant's app.db shows
**no divergence**. A trampoline-side parkUndo would therefore be
**dead code** — there is nothing to undo (kvexp already "undoes"
by losing the volatile overlay) and nothing to keep-durable-until-
commit (`commitTxn` is a no-op). Commit `01a9592`'s refusal to
port the admin-kv park onto the trampolines is **confirmed
correct**; the question it gated on is hereby resolved: *no
trampoline-side mechanism is justified*.

### Finding 3 — the only real escaped effect is the *caller's* response

What still escapes is the **calling handler's success response**:
`platform.releases.publish(...)` / `platform.scope(id).kv.set(...)`
/ signup→`deployStarter` returns, the handler's HTTP response is
released, and the client believes the cross-tenant write is
durable — while the trampoline's `target_id` propose may never
reach quorum. The handler's own response parks on the handler's
**own** batch seq (or releases immediately if read-only); it does
**not** wait on the trampoline's `target_id` seq. That is a
genuine premature external effect — but the parkable, justified
caller is the **handler entity** (which exists in the dispatch
lifecycle), *not* the trampoline. The correct fix is to thread the
trampoline's propose seq back up to `finalizeBatch` and gate the
caller's `RaftWait` on `max(own_seq, trampoline_seq)` — an
extension of the idiom-0 / admin-kv entity-park to "the calling
request also waits on a secondary seq from a trampoline it
invoked." This needs the handler→trampoline→finalize seq-threading
plumbing (a deliberate design step, the kind `unified-effect-
gating.md` Option A subsumes), **not** a mechanical port.

### Severity split (drives priority, not correctness)

| Site | Effect on caller-response escape | Disposition |
|---|---|---|
| `scopeKvWriteTrampoline` | client told a cross-tenant **data write** succeeded; it may not have. A real linearizability break. | **gate the caller** (seq-threading); highest priority of the three |
| `releasePublishTrampoline` / `deployStarter` | client told a **deploy pointer** activated; idempotent, operator-initiated, the `deployment_loader` re-converges, and the in-code contract already says "success regardless of raft outcome; raft settles async" (`worker.zig:1306-1313`). Closer to the **contracted at-least-once** Class-A posture (cf. the external scheduler) than to a silent data loss. | either gate the caller *or* formalise the at-least-once contract in the API docs — a **product/API decision**, not a pure correctness one (cf. the "workarounds are API design signals" discipline) |

### Reclassification

The per-site table's `deployStarter` / `releases.publish` /
`platform.scope.kv` rows: keep **B-broken**, but the broken effect
is the **caller's response**, not a trampoline-side divergence
(Findings 1–2 retire that). Reconciler = caller-seq-threading
(shared with the idiom-0/admin-kv entity-park), gated by a paired
fault test (a frozen-quorum trampoline call; assert the caller's
2xx does not escape). `scopeKvWriteTrampoline` first. No
trampoline-side parkUndo is ever built.

### Net

idiom-2 remainder is **not blocked on an unresolved empirical
question** any longer (resolved: no divergence, no trampoline
mechanism justified). It is blocked on a **design step**
(caller-seq-threading) plus, for the two deploy paths, a
**product call** (gate vs. formalise at-least-once). Neither is a
mechanical port; both are tracked here rather than implemented
speculatively.
