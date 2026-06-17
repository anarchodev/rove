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

### rove `feat/cp-membership-reconciler` (pushed)

| commit | what |
|---|---|
| `29c4c25` | DP: `v2-attach` baseline header → 400 on garbage (was `catch 0`), reject `index>0 && term==0`; `v2-confchange` rejects `node_id==0`; `v2-apply-snapshot` rejects `index==0`/`term==0`. Consensus: tear down a half-born group if the atomic baseline install fails; `Error.InvalidBaseline` term-0 guard. CP reconciler: tri-state `nodeGroupState` (remove only on confirmed-404, never on a probe error); `.failed` vs `.progressed` so one stuck node can't starve backfill; boot refusal when the reconciler is enabled without `REWIND_MOVE_SECRET`. Transport: oversize-frame loud teardown + flush-side coalescing cap; unknown-peer loud teardown; fixed reconnect backoff; recv self-heal sweep. |
| `49d9974` | Bump raft-rs-zig pin `da0129f → 87ed59e`. |

## Remaining work

Severity is post-verification engineering judgment. "Coordinated" = touches both
repos and needs the protocol above.

### A. Coordinated cross-repo

**A1 — `logTerm` has no error channel (HIGH, coordinated).**
`raft_manager_log_term` returns `u64`, collapsing {compacted, beyond-log, unknown
group, genuine term-0} all into `0`. The reconciler stamps this as the promote-back
baseline term; on an unknown-group drift it would build a `{index, term:0}`
baseline. The engine now rejects term-0 (`-5`) and the wrapper gates `term>0`, so
the *crash* is contained — but the reconciler still can't tell "unknown group" from
"real term 0", so it silently fails to promote instead of surfacing the drift.
Fix: add an out-param (mirror `last_index`'s `(out_term, rc)` shape) →
`manager.logTerm` returns `?u64` → rove `Node.logTerm` + the reconciler caller →
pin bump. Signature change ⇒ land per the protocol.

**A2 — `applyLocalSnapshot` doesn't stamp the store durability watermark (MEDIUM,
known Ph2 hazard).** After installing a baseline at index N, the raft log baseline
is N but the kvexp store's `lastAppliedRaftIdx` / `slot.applied_idx` are not moved
to N. A crash in the rejoin window recovers a store below N while the WAL no longer
holds entries ≤ N → silent divergence / lost coverage. Fix lives at the
`node.applyLocalSnapshot` seam (rove `src/consensus/node.zig`) — stamp the store
watermark in the same op; verify against `promote_back` + a crash-injection test.

### B. rove-only (from the first reconciler audit)

**B1 — Demote-on-transient-lag churn (MEDIUM).** `ensureMember`: a hosted voter
that is `recent_active` but lags more than `RECONCILE_SLACK=16` (a write burst)
falls through to `demote`. On a busy group this demote/promote-cycles healthy
voters. Gate the demote on `!recent_active` (genuinely stuck), or widen/relativize
the slack. `src/cp/main.zig` (`ensureMember`).

**B2 — `nodeApplied` semantics (MEDIUM, verify).** The comment says "applied /
committed (`v2-committed`)" but the code reads `v2-last-index`/`last_index`. If
that is log-received rather than applied, the promote gate can fire before the
learner has applied. Confirm the `v2-last-index` semantics match `leader_last` and
fix the comment or the signal. `src/cp/main.zig` (`nodeApplied`).

**B3 — Cluster re-address use-after-free (MEDIUM, verify thread model).**
`applyClusterLocal` frees the old `nodes` array while a reconcile pass may hold
`res.cluster.nodes` across blocking HTTP. Safe only if directory apply and the
reconcile pass are on the same thread (blocking the loop). Confirm; if the
directory raft applies off-thread, snapshot the node set into pass-local storage.
`src/cp/main.zig` + `src/cp/directory.zig`.

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

### D. Cross-cutting validation gap

Crash-consistency (the C1/C2 fsync-ordering fixes, A2's watermark, C3's rename
durability) is **not** unit-tested — the WAL suite covers normal operation only.
Build a fault/crash-injection harness (kill between marker-write and GC, between
`roll` header-write and the next flush, in the rejoin window) — `scripts/
raft_soak_prod.py` is the natural home for a soak/kill loop. Until then these fixes
are reasoned, not proven.

## Suggested sequencing

1. **A1 (logTerm error channel)** — highest-value coordinated fix; closes the last
   silent drift signal on the promote path. Do it next, per the protocol.
2. **A2 (snapshot watermark)** + **D (crash-injection harness)** together — the
   harness is what proves A2 (and retroactively the landed C1/C2).
3. **B1–B3** — rove reconciler hardening; independent, land anytime.
4. **C1/C2/C4** — engine robustness; additive, land + bump.
5. **B4 / C5** — informational / cosmetic; opportunistic.

Do not enable `REWIND_CP_RECONCILE_MEMBERSHIP=1` on prod until A1 + A2 land and the
crash-injection harness (D) is green — A2 is a data-coverage hazard and A1 is the
drift-visibility gap the reconciler exists to surface.
