# Consensus / storage correctness triage (2026-06-20)

Status: **open investigation.** Nothing here is "fixed." Each root cause
carries a verdict, a confidence, and a reproducing-test checklist; an item is
not considered confirmed until a red test reproduces its failure mode, and not
done until that test is green.

## Why this exists

Two live production state-machine divergences were found on the 3-node BHS
cluster, both on tenant raft groups that **agree on leadership** (so this is not
a split-brain):

- **`__auth__`** — all three nodes at `last_index = 107` (logs agree), yet the
  applied store differs: leader node 1 = `ba78…` (OLD), node 2 = `77d40f1` (the
  published fix), node 3 = `ba78…` (OLD). A write that was acked to the
  publisher reached the durable store of **one** node and was then lost. The
  leader serves OLD → intermittent login `TypeError`.
- **`__admin__`** — nodes 1+2 agree on `7226…`; node 3 is stranded at
  `last_index = 0` (group **unformed**) yet still serves a stale `b7f20…`. The
  group fell out of replication and never re-attached.

Cluster facts at the time: `REWIND_VOTERS=1,2,3` (static), the CP membership
reconciler is **disabled** (`REWIND_CP_RECONCILE_MEMBERSHIP` unset, so auto
demote is not in play), and the worker journal shows the warning
`stepBatch skipped N/M inbound messages (unknown group / fenced / undecodable)`
at **every** restart, including a 1000-message burst on Jun 19.

## Method

Seven parallel read-only audits, one per subsystem
(`node.zig` durability, `node.zig` lifecycle/epoch/recovery, `bridge.zig`
commit-signal, `transport.zig`+`raft_net.zig` wire, raft-rs-zig WAL/storage,
`src/kv` overlay/apply, `src/cp` directory/reconciler), each applying one
rubric: a finding is **BLOCKING** only if its error/default path can lose or
corrupt a committed write, advance a commit/apply/durable watermark past true
fsynced-majority durability, silently degrade quorum, or break state-machine
determinism; **UNVERIFIED-INVARIANT** if a safety property is asserted but
unenforced/untested; **BENIGN** otherwise. The lens throughout is *where rove
diverges from how raft-rs is meant to be driven* (TiKV/etcd as reference).

Agent findings were then **re-verified against the source by hand** before
landing here. Two high-confidence agent findings were **refuted** that way (see
"False positives") — agent output is evidence, not conclusion.

## Incident root cause — RESOLVED (2026-06-20, post-deploy log read)

After deploying the read-only diagnostics (controlled delta off the prod-deployed
commit), the `v2-log-entry` readout settled it **decisively**:

- All three nodes' `__auth__` raft logs (entries **1–111, fully scanned + decoded**)
  contain **only OIDC runtime writes** (`_oidc/magic`, `_oidc/code`,
  `_config/oidc/default`). **No node's log contains a `_deploy/current` write at
  all** — confirmed by a bulletproof substring search over the raw entry bytes.
- Yet every node **serves** a `_deploy/current` value (node 1/3 = OLD `ba78…`,
  node 2 = fix `77d40f1`), and all are **fully applied** (`applied = durabilized =
  last_index = 111`). The restart did not heal it (recovery resumes from the
  durabilized watermark).

**Therefore the `_deploy/current` value is ORPHANED applied-state with no
surviving log entry on ANY node.** The entries that wrote it were applied/folded
into the stores, then **truncated/replaced out of the log** during the heavy term
churn (term 169 over 111 entries — constant elections), and the applied store
state was **never rolled back**. node 1 and node 2 had applied *different* values
before the truncation → permanent divergent store residue the current (converged)
log cannot reproduce.

**Root cause (airtight): the state machine is not a deterministic function of the
committed log — the speculative-apply / fold survives a log-suffix truncation
with no rollback** (the architectural invariant: *nothing folds until it cannot
roll back; the store never needs an undo path*). The **trigger** is RC-2's fence
storm (node 3 logged **358,000** dropped/fenced inbound messages → constant
re-elections → repeated uncommitted-suffix truncation); the **mechanism** is
apply-without-rollback turning that churn into permanent store divergence. This is
the *broad* form of the same invariant RC-1 lives under — but via the
leader-change/truncation path, not catch-up.

This **subsumes and orders** the earlier candidates: RC-1/catch-up (exonerated,
dormant), apply-drift (refuted, fully applied), orphan-vs-divergent-log (resolved:
orphan — the value is in no log). The two fixes that close the incident: **(1)
RC-2** — stop the silent fence/drop that drives the election churn (the trigger);
**(2) the apply/fold truncation-safety invariant** — the store must be derivable
from / rolled back to the committed log (the mechanism).

**Operational note — HEALED 2026-06-20.** The divergence was converged by a
fresh full re-publish (`rewind-ops deploy __auth__ web/auth --release` — NOT a
bare `release` flip: the deploy *manifest* writes were truncated too, so all
three nodes needed a fresh manifest+blobs+marker committed through the leader,
not just a marker pointing at an absent manifest — that orphaned manifest is the
`resolveDeployment failed: ResumeNoDeployment` seen in the journal). Post-heal:
all three nodes serve `_deploy/current = 77d40f1…` at a converged `last_index=113`
(2 fresh entries applied on all three), `https://auth.rewindjs.com/login → 200`.
This is a state heal only — it does **not** close the code paths below, and a
binary deploy (rolling restart) is itself the churn trigger, so the platform
deploy must follow RC-2, not precede it.

**Deployed-code reachability (the live question: can `ec527b2` still reach a
premature fold?). Yes.** The fold gate is one line — `committed_seq` advances in
`Bridge.onCommitted` off raft's commit hook — with NO independent rove-side check
that a folded entry stays in the log; truncation-safety rests entirely on the
engine's "committed" meaning "fsynced-majority, never-truncatable." Three
reachable paths in the deployed binary: **(1)** an unidentified premature-commit
path proven *by existence* (the `__auth__` orphan is real, yet RC-1 and the OOM
path below don't fit its conditions → a third, unpinned path — suspect: engine
commit-advance under fence/term churn, or worker_overlay leader-change apply
asymmetry; reachable for ANY tenant under the fence storm that is prod's current
normal); **(2)** the `awaiting_worker` OOM fall-through in `onCommitted` — **FIXED
on this branch** (early-return on OOM instead of advancing `committed_seq`;
fail-loud via `apply_err`); **(3)** RC-1 baseline over-claim — fix `0fcaa73` is
**NOT in the deployed lineage** (`baselineIndex` still returns `applied_idx`),
reachable for >compaction-grace / moved / reconciler-on tenants, dormant for
`__auth__`.

## Incident root cause (earlier hypotheses — superseded by RESOLVED above)

RC-1 was chased to a real, correct fix but **exonerated as the `__auth__` cause**
(forensics: catch-up / move / reconciler all dormant for `__auth__`). The
observed prod state is therefore **still unexplained**:

- `__auth__`: all 3 nodes at `last_index = 107` (logs same length), stores fork —
  leader node 1 = OLD, node 2 = fix, node 3 = OLD. With catch-up/move/reconciler
  ruled out, the fork is **apply-side**, on a never-compacted, low-traffic group
  across rolling restarts.

### Forensics (2026-06-20) — leader apply-drift REFUTED; "committed write lost on leader change" established; orphan-vs-divergent-log UNRESOLVED

Per-node `__auth__` state read from prod:

| node | role | last_index | applied | matched (leader view) | `_deploy/current` |
|---|---|---|---|---|---|
| 1 | leader | 107 | **107** (term 167) | — | OLD |
| 2 | follower | 107 | — | 107, active | **fix** |
| 3 | follower | 107 | — | 107, active | OLD |

- **Leader apply-drift REFUTED.** node 1 (leader) `applied_idx = 107 = last_index`
  — fully applied. Its store is OLD because *its log yields OLD* at the deploy
  index (the fix write is not the live value in node 1's log).
- **term = 167 at index 107** — ~1.5 terms/entry: massive leadership churn
  (rolling restarts + hibernation re-elections) — the environmental amplifier.
- `matched=107` for both peers only proves identical log **length**, and
  `applied-baseline` is **leader-gated**, so **node 2's / node 3's `applied_idx`
  and their log *contents* are unknown** from the current endpoints.

**Established:** a committed+verified write (`_deploy/current=fix`, served live)
was LOST across a leader change — node 2 holds it, the (now-leader) node 1 and
node 3 do not, all at the same converged log length. This is the incident-memory
description, now confirmed against live state.

**NOT yet distinguished — two candidate sub-cases (both serious):**
- **(A) Orphaned speculative fold** — node 2's *log* == OLD (same as the leader),
  but node 2's *store* = fix is a fold that was never rolled back when node 2's
  log entry was replaced on a leader change. Store ≠ log. This is the broad
  speculative-overlay-survives-truncation hazard (alignment doc OPEN item, the
  same invariant RC-1 lives under) via the leader-change path. Requires node 2 to
  have folded a write that wasn't truncation-safe → a **premature/false commit**
  (a non-majority or non-fsynced ack counted — plausibly **fence-induced, RC-2**,
  during a term change; if so the commit-accounting "correct" verdict has a hole
  under fencing/churn), or a follower acking pre-fsync that didn't survive its
  restart.
- **(B) Divergent committed logs** — node 2's *log* actually = fix at the deploy
  index while node 1's = OLD, i.e. a committed entry differs across nodes. That
  is a raft **election-safety violation** (more serious than A), with `matched`
  reporting a false-identical prefix.

Distinguishing A from B requires node 2's **log entry content** at the deploy
index (and node 2/3 `applied_idx`). The inference "node 2's store is an orphan"
is only valid in case A; do not assert it until the log content is read.

**Diagnostic instrumentation — BUILT + verified (2026-06-20), ready for a
controlled-delta deploy:**
- **Named fence drops** (`transport.zig`): a `stepBatch` skip now logs each batch
  entry's `gid` + `msg_epoch` + `local_epoch` + sender + reason
  (`fenced(epoch)` / `unknown-group?` / `undecodable`) — fixes RC-2's blind spot
  so the *inducing* event (a legit message fenced during a term change) is
  attributable. Zig-only.
- **`GET /_system/v2-raft-state?tenant=`** (not leader-gated): per-node
  `{last_index, applied_idx, durabilized_idx, term_at_last, epoch, leader}` —
  exposes followers' `applied`/`durabilized` (invisible today) and the
  `applied − durabilized` fold-lag gap. Zig-only.
- **`GET /_system/v2-log-entry?tenant=&index=`** (not leader-gated):
  `{index, term, len, data_hex}` — the raw LOG entry bytes; the client decodes
  the frame+envelope+writeset (ASCII keys/values) to read what each node's log
  actually holds at the deploy index. **This is the A-vs-B disambiguator.**
  Needs the engine FFI `raft_manager_log_entry` (raft-rs-zig `9a214aa`, pinned).

Once deployed: read `v2-log-entry` at the `_deploy/current` index on all three
nodes — node 2's log == OLD ⇒ case A (orphaned fold); node 2's log == fix ⇒
case B (divergent committed logs / election-safety violation). Then audit the
epoch-fence × raft-safety path (the suspected inducer) and fix RC-2.

**Decisive next step (no endpoint exposes log-entry content today):** a READ-ONLY
diagnostic — read each node's raft log entry by index (term + decoded envelope
key/value) + the durable applied watermark — deployed controlled-delta, to (1)
confirm node 2's log[deploy-index] == OLD (orphan confirmed, not divergent logs),
and (2) find the term where fix→OLD flipped, then reconstruct that term's
election / commit / fence sequence. Alternative without a deploy: read + decode
node 2's on-disk WAL for the `_deploy/current` entries.

Until that runs, the precise sub-mechanism is **open**; the *class* (orphaned
speculative fold on leader change) is established. The general hardening is the
speculative-overlay invariant (decisions §10.5 / the alignment doc's OPEN item):
**the durable fold must be truncation-safe — full stop.** There is NO
"rollback-on-truncation" alternative, and earlier drafts that hedged with one
were wrong: by the model's central invariant a fold only fires for an entry that
*cannot* roll back, so a needed fold-rollback is always proof the fold fired too
early upstream (a premature/false commit), never a feature to build. The fix
space is "make the gate provably truncation-safe," never "add a store undo path."
This is the same invariant RC-1 lives under, now shown to bite via the
leader-change path too, independent of catch-up.

## The architectural invariant (the acceptance criterion)

The speculative overlay model has one load-bearing rule:

> Nothing folds from the speculative volatile overlay into the durable store
> until the entry is committed-to-raft **and cannot roll back**. The durable
> store therefore never needs an undo path — by construction. The overlay is
> the only place an uncommitted write lives, and it rolls back freely because
> it is volatile.

Consequence: there must be **no** "roll back the durable store on truncation"
path. If one is ever needed, the invariant has already been violated upstream.
The entire safety of the model reduces to a single property:

> **The fold gate (`committed_seq`) fires only for a truncation-safe entry.**

Every Bug-A finding below is a way that gate can fire on an entry that is *not*
truncation-safe. The fix space is "make the gate provably truncation-safe,"
never "add a store rollback."

---

## Root causes

### RC-1 — The fold gate is not provably truncation-safe (Bug A; the `__auth__` loss)

**Verdict: REAL latent bug — FIXED + unit-gated — but EXONERATED as the prod
`__auth__` cause (forensics 2026-06-20).** RC-1 only fires on the out-of-band
catch-up / move / reconciler-join baseline paths. Prod forensics rule all three
out for `__auth__`: `REWIND_SNAPSHOT_GRACE` is unset (default **5000**) and
`__auth__` has **107** log entries (≪ 5000), so it never compacts → no peer can
fall below `first_index` → the out-of-band catch-up never triggers; node-1 and
node-2 journals show **zero** catch-up / `apply_local` / `StateSnapshot` events
in their entire history; no tenant *move* occurred (single cluster); the
reconciler is off. So RC-1 did **not** cause the incident — it is a latent bug
that would bite once a tenant exceeds the compaction grace. **The `__auth__`
root cause is REOPENED — see "Incident root cause (reopened)" below.** The
mechanism analysis is retained because the fix is correct and the bug is real.

#### ROOT CAUSE — catch-up baseline index over-claims vs the snapshot it ships

The out-of-band catch-up (Phase 1) captures the baseline index and the snapshot
data at **two different times on two different threads, with no invariant that
`index ≤ snapshot content`:**

- **Baseline index** = `Node.appliedIndex(gid)` = `slot.applied_idx`, read at
  **trigger time on the PUMP thread** (`bridge.zig:1194`,
  `snapshotTriggerTick`), then baked into the enqueued `CatchupJob`.
- **Snapshot data** = the committed/folded overlay, captured **later on the
  DRIVER thread** when the job runs (`snapshot_catchup.zig:305`,
  `StreamDumper.init` → `openSnapshot`: "a copy of the committed overlay").

`applied_idx` **leads** the committed overlay: on the leader, its own proposes
are `worker_overlay`-skipped — `applyEntry` (`node.zig:1733-1744`) bumps
`applied_idx` **without** writing the store; the write reaches the committed
overlay only when the **worker thread folds** it (`TrackedTxn.commit` on
`committed_seq`, `worker_drain.zig:150`). So at dump time the folded snapshot can
be missing the most-recently-applied entries that `applied_idx` already counts.
When `applied_idx(trigger) > folded-content(dump)`, the baseline **over-claims**:
the receiver `apply_local_snapshot` fast-forwards `committed` to an index whose
writes the snapshot lacks, and those entries are now ≤ its commit / below
`first_index`, so they never replicate from the log either → **permanent store
fork at an agreed log index.**

This is exactly `__auth__`: node 2 (leader/source) had applied its own
`_deploy/current=fix` (`applied_idx` bumped) but the worker had not yet folded
it into the snapshot; the catch-up dump shipped a baseline **past** the fix
without the fix data to nodes 1 & 3 → they serve OLD, node 2 (after its worker
folds) serves the fix. The `appliedIndex` doc comment (`node.zig:1027-1039`)
shows the inverted reasoning: it chose `applied_idx` *because* it leads the store
watermark — but the baseline index must match what the **snapshot contains**, not
the apply frontier that runs ahead of it.

The deeper flaw is the **non-atomic capture**: index (pump, trigger time) and
data (driver, run time) are read at unrelated points. Between them the leader
keeps applying; nothing constrains their relationship in either direction.

**Fix direction (aligned with the invariant + TiKV's model):** capture the
baseline index and the snapshot data from **ONE consistent point**. The baseline
index must be the applied/fold watermark **of the snapshot's own MVCC view**,
read in the same txn that produces the data — so `index ≤ content` holds by
construction. Concretely: `StreamDumper`/`openSnapshot` returns
`{snapshot, applied_index_of_this_view}` atomically, and the shipped baseline is
that index — never a separately-read live `applied_idx`. This is TiKV's
shape (snapshot metadata index == the state machine's applied index *as
snapshotted*). It also removes the trigger-vs-run time skew entirely.

**STATUS: CLOSED — fix landed (`0fcaa73`), deterministic unit gate green, and a
3-node end-to-end convergence smoke green through the real out-of-band path.**
The baseline source
(`Node.baselineIndex`, formerly `appliedIndex`, every caller a baseline source)
now returns `slot.durabilized_idx` — the folded watermark `≤` the snapshot
content by construction, and still `snapshot_grace` entries above the compaction
floor so the tail replicates. The inverted doc comment that justified
`applied_idx` is corrected.

**Reproducing test — DONE at the unit level (red→green):** `bridge.zig`,
*"catch-up baseline index never exceeds the durable snapshot content watermark"*
— folds write 1, then commits write 2 without acking the worker txn (so
`applied_idx > durabilized_idx`, the fold-lag window) and asserts the baseline
index `≤ durabilized_idx`. RED on the old code (returned `applied_idx`), GREEN
after the fix. `v2-test` + `rewind-worker` + `rewind-cp` build clean.

**End-to-end smoke — LANDED + green:** `scripts/snapshot_catchup_no_fork_smoke_v2.py`.
3-node cluster, `REWIND_SNAPSHOT_GRACE=20`; a follower is stranded past the
compaction floor (gap ≫ grace), then recovers via the **real out-of-band
baseline + snapshot stream** under a concurrent JS-handler churn (the
worker_overlay write path). It then compares **every** acked distinct key on the
recovered victim against the leader — a fork would show as a missing/stale key.
Green on the fixed code over 1000+ keys, multiple runs, zero fork.

**HONESTY — the smoke is convergence coverage, NOT a deterministic reproducer.**
On the buggy code (`baselineIndex` → `applied_idx`) it did **not** fork in 3
runs: the over-claim is `applied(trigger) − folded(openSnapshot)`, and folding
usually catches up to `applied` by the time the driver opens the snapshot, so the
window rarely lands at cluster scale (consistent with the prod fork being
*intermittent*). The smoke therefore proves the catch-up path **converges with no
fork**, but the **deterministic regression gate is the unit test** (which forces
`applied > durabilized` by withholding the worker ack — red→green). Both are
green; do not rely on the smoke alone to catch a regression here.

#### Earlier verdict (superseded by the root cause above)

hazard class real; the rove-side triggers are REFUTED on closer read
(see "Pinning result" below). The live trigger is NOT in the rove apply/overlay
layer — it is engine-level commit/apply accounting. (Superseded: the engine
accounting is correct; the defect is the baseline construction above.)

#### Pinning result (2026-06-20, code-verified)

Three candidate rove-side triggers were chased and **all refuted by source**:

- **C4 (`flush`-before-`on_persist`) is HONORED on the production path.** The
  only production `on_persist` caller is the rove pump (`node.zig:1348`),
  guarded by the cycle's `wal.flush()` (`node.zig:1330`). Every `on_persist`
  caller inside raft-rs-zig `manager.zig` (690, 709, 948, 1008, 1129) is a
  **test helper or test body** (`processReadyAndPersist`, `captureRealVote`,
  `hsReproPump`, `threadReproPump`, the async-append test). So no production
  path acks persistence without a covering fsync. The C4 *assertion* is still
  worth adding as defense-in-depth (it would catch a future non-flush-guarded
  caller), but it is **not the fix** for this incident.
- **`worker_overlay` proposer-skip is deterministic under a correct commit.**
  `applyEntry` (`node.zig:1719-1744`): on skip, the worker txn folds the
  identical bytes gated on `committed_seq`; otherwise the pump writes the same
  committed value. proposer-store == follower-store == committed entry, *as long
  as a committed entry is never truncated* — which true raft guarantees.
- **Authoritative multi-apply is atomic + fail-loud** (`node.zig:1756-1786`):
  every inner uses `try` (decode error → `apply_err`), not `catch continue`.

Conclusion: the rove apply/overlay/commit-gate layer is safe **under a correct
raft commit**. The `__auth__` orphan therefore implies an **engine-level
commit/apply anomaly** — an entry reported committed (so the worker folded it)
that was later truncated. `raft-native-alignment.md` already records the lead:
*"applied=52 vs committed/last=66 on a prod leader"* (apply/commit accounting
drift). The next probe is the raft-rs async-append commit-advance path
(`raft-sys/src/lib.rs` `on_persist_ready` → commit) and per-node
`{applied_idx, commit_index, last_index}` instrumentation on prod — not the rove
apply layer.

#### Engine commit-accounting audit result (2026-06-20, code-verified)

Audited raft-rs-zig's async-append flow (`raft-sys/src/lib.rs`
`process_ready` / `on_persist` / `apply_local_snapshot`):

- **Normal-path commit accounting is CORRECT.** `process_ready` calls
  `advance_append_async(ready)` (records the append **without** advancing the
  persist watermark) and stashes the persistence-asserting messages (append
  acks / vote responses) in `pending_persist`; the watermark only advances in
  `raft_manager_on_persist` (`on_persist_ready`, line 1767), called by the rove
  pump **after** `wal.flush()`. So the leader's own entries and followers' acks
  count toward commit **only once fsynced** — commit == fsynced-majority. The
  §10.5b fix holds. **No sub-majority commit-advance exists in the normal
  flow.** This further narrows the `__auth__` trigger away from "premature
  commit."

- **The live suspect is the out-of-band catch-up/move baseline path** (the
  arc's Phase 1 / 2.5). `raft_manager_apply_local_snapshot` (lib.rs:1212)
  synthesizes a data-free `MsgSnapshot` and steps it, so raft's `restore`
  **fast-forwards `raft_log.committed` to the baseline `index`** while the KV
  state arrives **out-of-band** (`v2-snapshot-stream` → the store; line 1274
  "data left empty"). Correctness depends on the baseline `index` and the
  shipped store bytes being **mutually consistent** — and the baseline index is
  the leader's `slot.applied_idx`, which `raft-native-alignment.md` already
  flags as drifting (*"applied=52 vs committed/last=66 on a prod leader"*) and
  load-bearing-but-unverified. During the rolling restarts, a node that fell
  below the compaction floor (`matched + 1 < first_index`) receives exactly
  this baseline; if the `applied_idx`-derived index disagrees with the shipped
  store state, the receiver fast-forwards commit to an index whose store state
  diverges from the leader's — a **permanent, log-agreed store fork**, which is
  the observed `__auth__` shape. This is arc-introduced, matches the incident
  memory, and matches the drift observation.

  **Next probe (this is now the RC-1 trigger hunt):** audit baseline
  construction consistency on the rove side — `v2-applied-baseline` (reads
  `slot.applied_idx`) and the snapshot dump (`v2-snapshot-stream` /
  `StreamDumper`, `openSnapshot`) — and prove `{baseline index}` and
  `{shipped store snapshot}` are read from ONE consistent point (same txn /
  cursor), and that `applied_idx` can never point past or behind the store's
  durable content. Instrument per-node `{applied_idx, commit_index,
  last_index, store durable watermark}` on prod to catch the drift empirically.

#### Original hazard analysis (retained for record)

**Verdict (as first written): VERIFIED hazard class; prod trigger partially
pinned.** Superseded by the pinning result above for the C4 sub-cause.

The fold (`worker_drain.commitAndTake` → durable store) is gated on
`committed_seq`, advanced by `Bridge.onCommitted` from the **post-fsync** commit
hook. In correct raft, "committed" implies "never truncated," so the fold would
be safe and the store would never need rollback (exactly the invariant). The
defect is that two paths let `committed_seq` advance for an entry that is **not**
durable on a true fsynced voter-majority:

- **C4 — `flush`-before-`on_persist` is an UNENFORCED caller contract.**
  raft-rs-zig's async-append safety ("commit quorum counts only fsynced
  entries", `decisions.md` §10.5b) holds **only** if every pump cycle does
  `process_ready → wal.flush → on_persist` per group. The storage layer does not
  and cannot enforce it — confirmed: **zero assertions** in
  `raft-sys/src/lib.rs` (`raft_manager_on_persist`) or
  `grouped_file_storage.zig`. If any `on_persist` caller acks without a covering
  `flush`, the leader counts **unfsynced** appends toward quorum → premature
  commit → fold → orphaned when the next leader truncates. This is the §10.5b
  failure mode, left as prose with no runtime guard.
  - **Fits the `__auth__` end-state exactly:** node 2 folded `77d40f1` to its
    durable store on a commit that was never durable on a real majority; node 1
    later won leadership with a log lacking it and replicated its own index 107;
    node 2's *log* was overwritten to match (all three now at 107) but its
    *store* kept the orphaned fold. Result: identical logs, divergent stores.
  - **Most likely prod trigger.** Not yet pinned: the specific `on_persist`
    caller that runs without a covering `flush`. Suspect paths to trace:
    the two-pass pump around the single fsync, the worker_overlay apply, and any
    snapshot/recovery apply that calls `on_persist`.

- **`bridge.zig:1444-1453` — `awaiting_worker` OOM advances `committed_seq`
  uncapped.** On `awaiting_worker.append` OOM, `onCommitted` sets
  `node.apply_err` but **does not early-return**; control falls through and
  `committed_seq` still advances. The durabilize floor is then not capped by
  this entry's raft index, so durabilize/compaction can stamp/truncate past an
  entry whose worker txn is still open → false durability. OOM-gated (narrower
  than C4), but a clean over-report-of-durability path.

There is **no** store rollback, and there should not be. The fix is the gate.

Files: `src/consensus/node.zig` (worker_overlay skip ~1706-1799, two-pass pump
~1315-1381, durabilize ~1463-1552), `src/consensus/bridge.zig`
(`onCommitted` 1415-1456, `sweepLostLeadership` 1396-1406, `noteWorkerCommitted`
1465), `src/js/worker_drain.zig` (140-157), raft-rs-zig
`raft-sys/src/lib.rs` (`raft_manager_on_persist`, `process_ready`).

**Reproducing-test checklist (RC-1):**
- [ ] **C4 assertion** — add a debug "dirty-since-last-flush" flag in the
      storage layer, asserted in `on_persist`, so any `on_persist`-without-`flush`
      fails loud in tests instead of silently acking volatile data. Land this
      first; it converts the unenforced contract into a red test.
- [ ] **Audit every `on_persist` call site** and prove each is preceded by a
      covering `flush` for that group — or fix the one that is not.
- [ ] **Truncation-after-fold soak:** propose a write on a leader, induce a
      leader change before the entry is durable on a majority (partition/restart
      the other voters during the propose window), then assert the store does
      **not** retain the orphaned write and the response was a 503 (unknown
      outcome), never a 2xx. Today's soak only SIGKILLs (page cache survives) and
      never exercises this.
- [ ] **Bridge OOM path:** fault-inject `awaiting_worker.append` OOM and assert
      `committed_seq` does **not** advance (early-return) and the durabilize
      floor stays capped.

### RC-2 — Transport silently black-holes raft traffic; no `maybe_create_peer` (Bug B; the `__admin__` strand)

**Verdict: VERIFIED. Matches the prod evidence directly. High priority.**

`stepBatch` drops inbound messages for an unknown or epoch-fenced group
(`transport.zig:346`), and the per-node group record is **best-effort**:
`node.zig:901` records the group with the explicit note "a manifest failure must
not abort a working group," and the groups-manifest store is not on the
durabilize path — so a hard crash loses a non-genesis group's record, and on
restart the node drops that tenant's raft traffic **forever**, degrading quorum
to N-1 with only a rate-limited aggregate warning that does not even name the
group. There is no equivalent of TiKV's `maybe_create_peer` (an inbound
vote/heartbeat/append for a group a node *should* host creates or buffers the
peer rather than dropping it).

Directly explains node 3 `__admin__` at `last_index = 0` serving a stale store,
and the per-restart `skipped … unknown group / fenced` journal warnings.

Sub-findings (same subsystem, lower severity):
- `transport.zig:316/321` — a truncated coalesced frame `break`s the parse loop,
  dropping **the rest of the batch**, not just the bad record. No per-payload
  CRC on the coalesced frame (raft-net CRCs only the connection frame).
- `transport.zig:356` — the aggregate skip warning hides which group/peer is
  black-holed; an operator cannot identify the stranded tenant.

Files: `src/consensus/transport.zig` (onRecv/stepBatch 305-361),
`src/kv/raft_net.zig`, `src/consensus/node.zig` (recordGroup/groups_manifest
~760-901).

**Reproducing-test checklist (RC-2):**
- [ ] Form a group on 3 nodes; SIGKILL one; confirm its group record survives
      restart (it must be durable, or recovered from the WAL ConfState) and the
      group re-attaches. Today it can be lost.
- [ ] On inbound raft traffic for a group this node should host (it is in the
      cluster voter set) but does not have, form-or-buffer the group instead of
      dropping. Assert quorum returns to N without operator action.
- [ ] Per-group loud alarm when a node drops traffic for a group it should host
      (silent quorum degradation must fail loud).
- [ ] Coalesced-frame test: corrupt one record mid-batch; assert only that
      record is dropped, the rest still step.

### RC-3 — fsync failure drops commit notifications

**Verdict: real, fsync-gated. Confirm the one line, then fix.**

In the pump, on `wal.flush()` failure the guarded apply/ack block is skipped
(correct — do not ack volatile data) but `commit_notify.clearRetainingCapacity()`
runs **unconditionally**, so commit notifications staged in pass 1 are dropped:
applied entries are never notified, and the worker's `committed_seq` watermark
fails to advance for them. Parked workers time out to 503 (acceptable), but the
notification loss is a coupling of durability failure to apply notification that
should not exist.

Files: `src/consensus/node.zig` pump (~1330-1381).

**Reproducing-test checklist (RC-3):**
- [ ] Fault-inject `wal.flush()` failure with staged commit notifications;
      assert notifications are retained/retried, not dropped, and the watermark
      recovers on the next successful flush.

### RC-4 — CP move/provision use-after-free + stale follower routing

**Verdict: VERIFIED live. Refutes a "done" claim (B3 follow-up). Operator/move-driven.**

`handleMoveLive` and `handleProvision` hold `resolve()` / `clusterById()`
slices (aliasing the directory projection) across blocking HTTP calls, while a
concurrent `/_control/cluster` re-address frees the projection on another thread
— a use-after-free on the source/dest node arrays. The B3 fix
(`resolveOwned` deep-copy under the lock) was only wired into the reconciler;
the move and provision paths still use the aliasing `resolve()`/`clusterById()`.
Separately, follower `resolve()` serves stale placement with no forward-to-leader
guard, and the directory group itself inherits RC-1/RC-2.

Files: `src/cp/main.zig` (`handleMoveLive` ~1026-1101, `handleProvision`
~584-610), `src/cp/directory.zig` (`resolve`/`resolveOwned` ~638-644,
`applyDirWrite` ~450-458).

**Reproducing-test checklist (RC-4):**
- [ ] Re-address a cluster (`/_control/cluster`) during a live move/provision;
      assert no UAF (run under the sanitizer). Fix by using `resolveOwned` on
      the move/provision paths.
- [ ] Follower routing read during a placement flip: assert it forwards to the
      leader or errors, never serves a stale route as authoritative.

### RC-5 — Corruption-gated fail-loud violations

**Verdict: real, MEDIUM/LOW (corruption-gated, not normal-operation loss).**

- `node.zig:775` — `epoch = std.fmt.parseInt(u64, e.value, 10) catch 0`: a
  corrupt groups-manifest epoch value defaults to 0, which would recover a moved
  group at the wrong epoch → fenced → stranded (feeds RC-2). Silent default that
  should fail loud.
- `grouped_file_storage.zig:835` — the recovery pre-pass uses a compaction
  marker only `if (payload.len == COMPACTION_PAYLOAD_LEN)`; a CRC-valid but
  wrong-length marker is silently skipped, so compacted entries would be
  replayed. Storage C2, confirmed.

**Reproducing-test checklist (RC-5):**
- [ ] Corrupt the manifest epoch value; assert recovery fails loud, not
      `catch 0`.
- [ ] Wrong-length-but-CRC-valid compaction marker; assert loud reject, not
      silent skip.

### RC-6 — Demote-on-transient (CP reconciler) — DORMANT

**Verdict: real but disabled in prod; gate before enabling.**

`ensureMember` can demote a voter judged not-`recent_active`; a rolling restart
makes a healthy voter transiently unreachable, and a stale `recent_active`
reading could shrink the voter set (enabling sub-majority commit — RC-1's
trigger by another route). The reconciler is **off** in prod, so this did not
cause today's incident, but it must be hardened before
`REWIND_CP_RECONCILE_MEMBERSHIP=1` is ever set.

Files: `src/cp/main.zig` (`ensureMember` ~1286-1301).

**Reproducing-test checklist (RC-6):**
- [ ] Transient-unreachable voter (rolling restart) under an enabled reconciler;
      assert it is **not** demoted (only a genuinely stuck/partitioned voter is).

---

## False positives filtered (the triage is filtered, not rubber-stamped)

- **"Partial multi-apply" (kv agent, reported BLOCKING/HIGH).** The flagged
  `catch continue` is in `apply.zig:forEachWriteSetEnvelope`, which has **zero
  callers** — it is the read-only envelope-tree helper, not the authoritative
  `Cluster.applyOne`. **Refuted.** (The authoritative multi-apply atomicity
  still warrants its own check, but the cited site is not it.)
- **"Recovery uses a stale static voter set → sub-majority commit"
  (node-lifecycle agent, reported BLOCKING/HIGH).** `initRecover`
  (`grouped_file_storage.zig:811`) passes static `self.voters` only as the seed,
  then replays the WAL's persisted `.confstate` records last-wins
  (lines 858-869), and a confstate that fails to decode **fails recovery
  loudly**. Membership is durably persisted and correctly restored. **Refuted.**
  This removes a leading prod-trigger theory and is why RC-1 (C4) carries the
  weight instead.

## What is NOT yet confirmed

No item here has a red test reproducing its failure mode yet. Specifically still
open before anything is called "confirmed":

- RC-1: the exact `on_persist`-without-`flush` call site (if any) — the C4
  assertion is the way to surface it.
- RC-1/RC-3: the bridge-OOM no-early-return and the unconditional
  `commit_notify` clear — read as described, but write the test.
- The authoritative `Cluster.applyOne` multi-envelope atomicity (separate from
  the refuted helper) — not yet audited end to end.

## Suggested fix sequencing

1. **RC-1 — now an engine-level hunt (the rove-side triggers are refuted).**
   The live `__auth__` trigger is an engine commit/apply anomaly (a committed
   entry that was truncated), not the rove apply layer. Next steps: (a)
   instrument per-node `{applied_idx, commit_index, last_index}` and confirm/
   quantify the known apply/commit drift; (b) audit the raft-rs async-append
   commit-advance accounting (`raft-sys/src/lib.rs` `on_persist_ready` → commit)
   for a path that advances commit without a fsynced voter-majority. Land the
   C4 debug assertion as **defense-in-depth** (cheap regression guard), but it
   is not this incident's fix. Keep the bridge-OOM early-return fix (the one
   real, narrow rove-side over-report) on this track.
2. **RC-2 form-or-buffer + per-group alarm.** Self-contained, clear fix, and it
   is the confirmed `__admin__` mechanism.
3. **RC-3, RC-4** — bounded, lower blast radius.
4. **RC-5, RC-6** — fail-loud hardening / gate-before-enable.

Standing acceptance criterion for all of the above: *the fold gate fires only
for a provably truncation-safe entry*, enforced in code or asserted, with a test
that reproduces the failure mode — not adjacent green tests.
