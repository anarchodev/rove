# Raft correctness — coordinated fix plan (rove ⇄ raft-rs-zig)

A single roadmap for the consensus-stack correctness work, spanning **rove**
(`src/consensus`, `src/cp`, `src/js/v2_move.zig`, `src/kv/raft_net.zig`) and the
pinned **raft-rs-zig** engine (`raft-sys/src/lib.rs`, `src/manager.zig`,
`src/storage.zig`, `src/grouped_file_storage.zig`).

It records what two audit passes found, what has landed, and what remains —
especially the fixes that must change **both** repos in lockstep.

## Guiding rule (the classification)

Every error site is exactly one of:

- **Invariant violation** (impossible if callers are correct) → fail fast. Prefer
  a returned error / rejected op over a process-wide panic when the pump is shared
  (`panic = "abort"` in raft-sys takes down every tenant on the node); keep the
  raft-rs `commit_to` fatal as a last-resort backstop.
- **Bad external input** (HTTP, FFI args, wire) → reject loudly (4xx / error code),
  never silently default or clamp.
- **Resource exhaustion** (OOM, ENOBUFS, SQE-full, disk full) → fail loud /
  operator-visible; don't disguise as a benign transient.
- **Raft-tolerated transient** (a dropped message — raft re-emits) → soft is
  correct; do **not** panic.

The illegitimate fourth category we are removing everywhere: **silent default**
(`catch 0`, `catch return false`, `catch {}`, `orelse <default>`).

## Pin / coordination protocol

The rove `build.zig.zon` pins a single raft-rs-zig commit. To avoid a mid-flight
build break:

- **Additive engine changes** (a new return code, a new wrapper `Error` variant)
  are non-breaking on a pin bump — rove callers absorb them via `else` arms. Land
  in raft-rs-zig, push, then bump the rove pin in its own commit.
- **Signature changes** (e.g. adding an out-param to `raft_manager_log_term`) are
  breaking. Land them as: (1) raft-rs-zig FFI + wrapper, push `main`; (2) the rove
  caller update **and** the pin bump together in one rove commit. Never bump the
  pin ahead of the rove caller update.
- Every pin bump is gated on: `zig build` (release cargo) + `v2-test` + `test` +
  the reconciler smokes (`membership_reconciler`, `learner_add`,
  `fresh_voter_join`, `promote_back`).

## Status — landed

### raft-rs-zig `main` (pushed)

| commit | layer | what |
|---|---|---|
| `ed29bac` | build | Build the Rust staticlib optimized regardless of Zig optimize mode — closes the `-O0` misaligned-`movaps` GPF in `confchange::restore` (gdb-proven; committed `Cargo.lock` only masked it). + corrected bug doc + `CLAUDE.md`. |
| `c5c9a9c` | FFI | `apply_local_snapshot` rejects a term-0 baseline (new code `-5`) — engine backstop for the `commit_to`-past-empty-log fatal. `conf_state`/`voter_progress` null-check out-pointers. Loud logs on dropped outbound messages / failed committed conf-changes. |
| `6165419` | wrapper | Map FFI `-1`→`Error.UnknownGroup` in `step`/`stepFenced`/`proposeConfChange`/`applyLocalSnapshot`. `applyLocalSnapshot` input gate (`index>0 && term>0`) + `-5`→`InvalidBaseline`. Loud-log discarded truncation in `confState`/`voterProgress`. `appendEntriesCb` `GapInLog` → panic. |
| `87ed59e` | WAL | C1: fsync the compaction marker before `gcSealed` unlinks the segment it protects (`compact` + `applyLocalSnapshot`). C2: `roll()` fsyncs the new header + parent dir. C4: malformed fixed-size (hardstate/compaction) record → reject. C5: `initRecover` propagates confstate corruption. S3: `discoverSealedSegments` distinguishes `FileNotFound` from I/O error. C3: `gcSealed` logs a failed unlink. |
| `f34e8c6` | FFI+wrapper | **A1**: `raft_manager_log_term` → out-param + i32 rc (0 ok / -1 unknown-group / -2 no-term-at-index); `manager.logTerm` → `?u64`, `null` distinct from a genuine term 0. |

### rove `feat/cp-membership-reconciler` (pushed)

| commit | what |
|---|---|
| `29c4c25` | DP: `v2-attach` baseline header → 400 on garbage (was `catch 0`), reject `index>0 && term==0`; `v2-confchange` rejects `node_id==0`; `v2-apply-snapshot` rejects `index==0`/`term==0`. Consensus: tear down a half-born group if the atomic baseline install fails; `Error.InvalidBaseline` term-0 guard. CP reconciler: tri-state `nodeGroupState` (remove only on confirmed-404, never on a probe error); `.failed` vs `.progressed` so one stuck node can't starve backfill; boot refusal when the reconciler is enabled without `REWIND_MOVE_SECRET`. Transport: oversize-frame loud teardown + flush-side coalescing cap; unknown-peer loud teardown; fixed reconnect backoff; recv self-heal sweep. |
| `49d9974` | Bump raft-rs-zig pin `da0129f → 87ed59e`. |
| `9d5fc0f` | **A1** (rove half): `Node.logTerm`/`Bridge.logTerm` → `?u64` (the `log_term` control cmd carries an `lt_ok` flag, mirroring `vp_ok`); `v2-applied-baseline` uses `orelse 409` instead of the `term==0` band-aid; pin → `f34e8c6`. |
| (this branch) | **A2**: `node.applyLocalSnapshot` stamps the store's durable applied watermark (`setLastAppliedRaftIdx`) to the baseline index + bumps `slot.applied_idx`/`durabilized_idx`. **D**: `scripts/raft_soak_prod.py` crash/recovery soak. |
| (this branch) | **B1**: demote only a STUCK (`!recent_active`) voter, not a responsive-but-lagging one. **B2**: `nodeApplied`→`nodeLastIndex` + corrected comment (the signal was already correct). **B3**: `Directory.resolveOwned` deep-copies the node set under the lock — fixes a re-address UAF in the reconcile pass. |

## Remaining work

Severity is post-verification engineering judgment. "Coordinated" = touches both
repos and needs the protocol above.

### A. Coordinated cross-repo

**A1 — `logTerm` error channel — DONE** (raft-rs-zig `f34e8c6`, rove `9d5fc0f`).
`raft_manager_log_term` no longer collapses {compacted, beyond-log, unknown group,
genuine term-0} into `0`: an out-param + i32 rc (0 / -1 unknown-group / -2 no-term)
threads `?u64` through `manager`/`Node`/`Bridge.logTerm` (via an `lt_ok` control-cmd
flag), and `v2-applied-baseline` refuses with 409 via `orelse`. `null` is distinct
from a genuine term 0, so no caller stamps a fake 0 into a baseline. Landed as a
coordinated signature change per the protocol.

**A2 — store watermark on `applyLocalSnapshot` — DONE** (rove, this branch).
`node.applyLocalSnapshot` now synchronously stamps the store's durable applied
watermark (`setLastAppliedRaftIdx`) to the baseline index and bumps
`slot.applied_idx`/`durabilized_idx`, so a crash in the rejoin window can't recover
a store BELOW the raft baseline (entries ≤ index gone from the WAL). Stamping at /
ahead of the not-yet-durable raft snapshot errs safe — a store AHEAD of raft only
re-applies idempotently on recovery; a store BEHIND loses data. Exercised by
`promote_back` + the soak (D).

### B. rove-only (from the first reconciler audit)

**B1 — Demote-on-transient-lag churn — DONE.** `ensureMember` now demotes a hosted
voter only when it is NOT `recent_active` (genuinely stuck: partitioned / dead /
campaigning-without-acking — the __admin__ wall). A responsive voter that is merely
behind (`recent_active`, lagging under write load) is left alone (`.done`) — it is
catching up via normal replication and isn't disrupting elections, so demoting it
only churned healthy voters on a busy group. `src/cp/main.zig`.

**B2 — `nodeApplied` semantics — DONE (verified correct; doc/name fixed).** Traced
`v2-last-index` → the FFI's `raft_log.last_index()` (entries RECEIVED), and
`leader_last` is the leader's `last_index()` too — so the gate compares like with
like, and a node whose LOG has caught up is a valid voter (raft votes on log
position, not apply). The SIGNAL was right; the misleading comment ("applied /
committed (`v2-committed`)" — no such endpoint) and the name were fixed
(`nodeApplied` → `nodeLastIndex`). `src/cp/main.zig`.

**B3 — Cluster re-address use-after-free — DONE (was real).** Confirmed:
`reconcileMembership` runs on the CP main loop, `applyClusterLocal` (which frees the
old `nodes` array on re-address — exactly the `/_control/cluster` grow) runs on the
pump thread under the directory mutex — different threads — and `resolve`'s
`ClusterRef.nodes` aliases the freed projection (its "stable for its lifetime"
claim is violated by re-address). Fixed: new `Directory.resolveOwned` deep-copies
the node set UNDER THE LOCK; the reconciler uses it + `deinit`s per tenant. (A copy
*after* `resolve` returns wouldn't close it — the array can be freed in the
unlock→copy window; the copy must be under the lock.) `src/cp/main.zig` +
`src/cp/directory.zig`. NOTE: the move paths (`reconcileStuckMoves`,
`handleMoveLive`, `clusterById`) hold `resolve`/`clusterById` refs across blocking
calls too — same latent UAF, but operator-driven + transient (a re-address mid-move
is far rarer); left as a follow-up.

**B4 — Lower / informational.** member-status `recent_active` idle false-negative
(heartbeats keep it true — low); `lastIndex`/`logTerm` = 0 conflation surfaced to
the reconciler (benign retry, but see A1); `apply.zig` read-only readset extraction
silently skips a retired/corrupt inner envelope (by-design best-effort, but
inconsistent with fail-loud — add a counter/log).

### C. raft-rs-zig-only

**C1 — `initial_state` / `first_index` / `last_index` collapse every storage rc to
`Unavailable` (LOW-MEDIUM).** Only `entries`/`term` honor the `-2→Compacted`
distinction. If a storage impl ever returns "compacted" from these, it is silently
downgraded, changing raft's snapshot-vs-retry decision. `raft-sys/src/lib.rs`.

**C2 — Recovery read-path malformed-record skips (LOW-MEDIUM).** `scanForReplay`
and the `initRecover` compaction pre-pass silently skip a CRC-valid-but-wrong-length
record. Left soft to avoid bricking recovery; revisit with a loud per-record log so
corruption is visible without failing the whole recover.
`src/grouped_file_storage.zig`.

**C3 — Directory-fsync is best-effort only (LOW, needs crash testing).** `roll()`
fsyncs the parent dir via the raw syscall with the result ignored (std's wrapper
panics on EINVAL). Full crash-consistency of segment rolling (rename durability +
ordering vs the new active create) is unverified — see the validation gap below.

**C4 — `flush`-before-`on_persist` is a pure caller contract (S1, HIGH if
violated).** The "commit quorum counts only fsynced entries" safety holds only if
every pump does `process_ready → flush → on_persist` per group. The storage layer
can't enforce it. Add a debug-mode "dirty-since-last-flush" flag asserted in
`on_persist` so a missing flush fails loud in tests rather than silently acking
volatile data in production. `src/grouped_file_storage.zig` + `src/manager.zig`.

**C5 — Lower / informational.** broad `m`-null-check sweep across ~23 `extern "C"`
fns (the manager handle is process-lifetime, never null in practice — cosmetic
consistency); `MAX_REPLAY_PAYLOAD` aggregate cap (S2, low); `file_storage.zig`
`truncate_at` unguarded index (benchmark-only backend, low).

### D. Crash/recovery soak — DONE (harness); power-loss coverage still open

`scripts/raft_soak_prod.py`: a 3-node cluster under write churn + ungraceful
`kill_node` (crash-recovery of an intact replica) + `wipe→reconciler-heal` rounds
(the A2 promote-back rejoin window), asserting after each round that quorum holds,
the victim rejoins as a caught-up voter, and every ACKED write is intact on every
node (no loss / no divergence). Validated green (incl. killing the leader mid-churn).

**Caveat — what it does NOT prove:** a process SIGKILL does not drop the page cache
(the kernel still flushes dirty pages), so the soak validates recovery LOGIC + A2's
*persisted* watermark, but NOT the C1/C2 fsync ORDERING under true power loss. That
needs power-loss tooling — run the node processes on a `dm-flakey` mount with
`drop_writes`, or a VM hard-poweroff. Open until then: C1/C2 under power loss, C3
rename durability.

## Suggested sequencing

1. ~~**A1 (logTerm error channel)**~~ — DONE (`f34e8c6` + `9d5fc0f`).
2. ~~**A2 (snapshot watermark)** + **D (soak harness)**~~ — DONE (soak green). Still
   open under D: re-run the soak under `dm-flakey` to cover the C1/C2 fsync ordering
   under real power loss.
3. ~~**B1–B3**~~ — DONE (this branch). Remaining under B: the move-path re-address
   UAF (`reconcileStuckMoves`/`handleMoveLive`/`clusterById`, operator-driven) and
   B4 (informational).
4. **C1/C2/C4** — engine robustness; additive, land + bump.
5. **B4 / C5** — informational / cosmetic; opportunistic.

A1, A2, and the soak (D) are landed/green, so the original prod-enable gate is met
for the promote-path hazards. Before enabling `REWIND_CP_RECONCILE_MEMBERSHIP=1` on
prod, two things still warrant attention: extend D to power-loss tooling (`dm-flakey`)
to actually prove the C1/C2 fsync ordering, and weigh the B-series reconciler
hardening (esp. B1 demote-churn under load).
