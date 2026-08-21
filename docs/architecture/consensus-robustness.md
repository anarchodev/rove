# Consensus robustness — conventions, invariants, and the shipped record

> **Reference** (graduated from `plans/`). The governing conventions and
> architectural invariants that dictate how consensus hardening work gets
> done, plus the shipped-proof record so closed items are not re-opened.
> The **open backlog itself lives in GitHub issues** — tracker #128; the
> per-item map is in "Open items" below.

This consolidates the durable residue of the 2026-06-20 consensus/storage
triage and the two-repo `raft-correctness-plan`. The 2026-06-20 production
incident itself is **CLOSED** (root-caused, state-healed, and code-fixed
where it was the trigger). The SHIPPED/closed history lives in git history
and in [`../decisions.md`](../decisions.md) §10.5b (async-append commit =
fsynced-majority), §10.12, and §10.13, plus
[`consensus-and-storage.md`](consensus-and-storage.md).
Sibling docs that carry adjacent leads:
[`raft-native-alignment.md`](raft-native-alignment.md)
(as-built), [`raft-best-practices.md`](raft-best-practices.md).

## Open items (tracked in issues; tracker #128)

| Item | Issue |
|---|---|
| RC-3 — `wal.flush` failure drops staged commit notifications | #99 |
| RC-4 — CP move/provision UAF + stale follower routing | #100 |
| RC-5 — corruption-gated silent defaults (epoch `catch 0`; wrong-length compaction marker) | #101 |
| C4 — debug dirty-since-last-flush assertion in `on_persist` | #102 |
| D — power-loss crash-consistency validation (`dm-flakey` soak; includes C3 rename durability) | #103 |
| Truncation-after-fold soak — the deterministic RC-1 reproducer | #104 |
| Engine sweep — C1 storage-rc collapse, C2 loud malformed-record skips, C5/B4 informational | #105 |
| Transport — truncated coalesced frame drops the rest of the batch | #106 |
| Scrutiny — speculative overlay vs apply-on-commit | #107 |
| Scrutiny — leader-only reads vs `read_index` / follower reads | #108 |

## Governing conventions

These two conventions are carried forward verbatim from the correctness plan
because they dictate **how** the open items (tracker #128) get fixed.

### Error classification (four-way)

Every error site is exactly one of:

- **Invariant violation** (impossible if callers are correct) → fail fast.
  Prefer a returned error / rejected op over a process-wide panic when the pump
  is shared (`panic = "abort"` in raft-sys takes down every tenant on the node);
  keep the raft-rs `commit_to` fatal as a last-resort backstop.
- **Bad external input** (HTTP, FFI args, wire) → reject loudly (4xx / error
  code), never silently default or clamp.
- **Resource exhaustion** (OOM, ENOBUFS, SQE-full, disk full) → fail loud /
  operator-visible; don't disguise as a benign transient.
- **Raft-tolerated transient** (a dropped message — raft re-emits) → soft is
  correct; do **not** panic.

The illegitimate fourth category we are removing everywhere: **silent default**
(`catch 0`, `catch return false`, `catch {}`, `orelse <default>`).

### Pin / coordination protocol (rove ⇄ raft-rs-zig)

The rove `build.zig.zon` pins a single raft-rs-zig commit. To avoid a mid-flight
build break:

- **Additive engine changes** (a new return code, a new wrapper `Error`
  variant) are non-breaking on a pin bump — rove callers absorb them via `else`
  arms. Land in raft-rs-zig, push, then bump the rove pin in its own commit.
- **Signature changes** (e.g. adding an out-param to `raft_manager_log_term`)
  are breaking. Land them as: (1) raft-rs-zig FFI + wrapper, push `main`; (2) the
  rove caller update **and** the pin bump together in one rove commit. Never bump
  the pin ahead of the rove caller update.
- Every pin bump is gated on: `zig build` (release cargo) + `v2-test` + `test` +
  the reconciler smokes (`membership_reconciler`, `learner_add`,
  `fresh_voter_join`, `promote_back`).

Standing acceptance criterion for every open item: *the fold gate
(`committed_seq`) fires only for a provably truncation-safe entry* — enforced in
code or asserted, with a test that reproduces the failure mode, not adjacent
green tests.

## Open architectural scrutiny (from raft-native-alignment)

Two divergences that the now-as-built `raft-native-alignment.md` left marked
**OPEN** — not bugs, but standing design questions to re-decide if the relevant
pressure shows up. The rest of that doc's divergences reached a verdict (align /
justified) and are recorded there + in `decisions.md` §10.12.

- **Speculative overlay (apply-before-commit + rollback) vs apply-on-commit
  (issue #107).**
      raft applies *after* commit; rove applies speculatively into a volatile
      overlay and rolls back on fault. Scrutinize whether the latency win is
      worth the rollback path and the divergence from the native model. Not
      obviously harmful — on the ledger, not urgent. (This is the same fold-gate
      surface as the truncation-safety acceptance criterion above.)

- **Leader-only reads (dispatch-gate) vs `read_index` / follower-reads
  (issue #108).**
      `read_index` / lease-read is raft's native linearizable-read **and**
      read-scaling mechanism; rove diverged to a strict leader-only dispatch
      gate. Justified *only* while we don't need read scaling — re-scrutinize if
      we do. The full analysis (why it is consciously deferred, the bounded
      partition-window staleness, and the exact code path `read_index` would
      wire into) lives in `raft-best-practices.md`, "Blocked on NEW FFI methods"
      item 1.

## Design notes

- **RC-1 deeper lesson (from triage) — atomic {snapshot, applied-index} capture.**
  The point fix landed and is closed: the out-of-band catch-up baseline source
  (`Node.baselineIndex`, formerly `appliedIndex`) now returns
  `slot.durabilized_idx` (the folded watermark, `≤` snapshot content by
  construction, still `snapshot_grace` entries above the compaction floor); fix
  `0fcaa73`, deterministic unit gate green, plus the
  `scripts/smoke/snapshot_catchup_no_fork_smoke_v2.py` 3-node convergence smoke. **But
  the underlying design lesson is not discharged by the point fix:** the baseline
  index and the snapshot data were captured at **two different times on two
  different threads** with no invariant relating them (index = `appliedIndex` on
  the PUMP thread at trigger time, `bridge.zig:1194`; data = the committed/folded
  overlay on the DRIVER thread at run time, `snapshot_catchup.zig:305`
  `StreamDumper.init` → `openSnapshot`). The correct shape — TiKV's — is to
  capture `{snapshot, applied_index_of_that_MVCC_view}` **atomically from one
  consistent point** (the same txn / cursor that produces the data returns the
  index), so `index ≤ content` holds by construction and the trigger-vs-run skew
  is gone. Any future change to the catch-up / move baseline path must preserve
  this atomic-capture property rather than re-reading a live `applied_idx`.

- **The architectural invariant (acceptance criterion for any fold-path work).**
  > Nothing folds from the speculative volatile overlay into the durable store
  > until the entry is committed-to-raft **and cannot roll back**. The durable
  > store therefore never needs an undo path — by construction.

  Consequence: there must be **no** "roll back the durable store on truncation"
  path. If one is ever needed, the invariant has already been violated upstream —
  the fix space is "make the fold gate (`committed_seq`) provably
  truncation-safe," never "add a store rollback." The 2026-06-20 `__auth__`
  orphan was this invariant biting via the leader-change/truncation path (not
  catch-up); it is closed by RC-2's fence-storm fix plus the `awaiting_worker`
  OOM early-return (both shipped — see git history / decisions.md §10.5b), but
  every new fold-path change is held to this gate.

- **RC-2 reframe (closed as code, kept as orientation).** The transport
  silent-drop of inbound messages for an unknown/epoch-fenced group
  (`transport.zig:346`) is **not** fixed by a TiKV-style form-or-buffer
  `maybe_create_peer` — that is unsafe (stale-epoch resurrection of a moved-away
  tenant) and could not reach a non-member anyway (the leader never sends to a
  node absent from its confstate). The safe authoritative form-or-buffer is the
  CP membership reconciler (`reconcileMembership`/`ensureMember`, `cp/main.zig`),
  which RC-6 hardened (demote requires SUSTAINED inactivity past
  `demote_grace_ns`, default 60s). The durable group record (`recordGroup`
  `put`+`checkpoint` fsync, `9ded66d`) and per-group named fence-drop alarm
  (`0528e52`) shipped. Remaining transport sub-findings worth a future pass:
  `transport.zig:316/321` — a truncated coalesced frame `break`s the parse loop,
  dropping the rest of the batch rather than just the bad record (no per-payload
  CRC on the coalesced frame; raft-net CRCs only the connection frame). A
  coalesced-frame test (corrupt one record mid-batch; assert only that record is
  dropped, the rest still step) is unwritten.

## Already shipped (proof, not backlog)

Listed so they are not re-opened. Provenance preserved.

| Tag | What | Proof |
|---|---|---|
| RC-1 (triage) point fix | Catch-up baseline = `durabilized_idx`, not `applied_idx`; inverted doc comment corrected | `0fcaa73`; unit gate + `snapshot_catchup_no_fork_smoke_v2.py` green |
| RC-1 bridge-OOM | `onCommitted` early-returns on `awaiting_worker.append` OOM (fail-loud via `apply_err`) instead of advancing `committed_seq` | shipped on the fix branch |
| RC-2 durable group record | `recordGroup` `put`+`checkpoint()` fsync; survives crash, re-attaches via `recoverGroups` | `9ded66d`, deployed `ec527b2` |
| RC-2 named fence drops | `stepBatch` skip logs `gid + msg_epoch + local_epoch + sender + reason` | `0528e52`, deployed |
| RC-6 demote-on-transient | Demote requires SUSTAINED `!recent_active` past `demote_grace_ns` (default 60s, `REWIND_CP_DEMOTE_GRACE_MS`); `ConfChangeQuorumGuard` ≥2 voters | `src/cp/main.zig`; `rewind-cp-test` transient-then-recover case + `membership_reconciler_smoke_v2.py` |
| A1 (correctness) `logTerm` error channel | `raft_manager_log_term` out-param + i32 rc (0 / -1 unknown-group / -2 no-term); `?u64` through `manager`/`Node`/`Bridge`; `v2-applied-baseline` → 409 via `orelse` | raft-rs-zig `f34e8c6`, rove `9d5fc0f` |
| A2 (correctness) snapshot watermark | `node.applyLocalSnapshot` stamps `setLastAppliedRaftIdx` to the baseline + bumps `applied_idx`/`durabilized_idx` so a crash in the rejoin window can't recover a store BELOW the raft baseline | rove (reconciler branch); exercised by `promote_back` + soak D |
| B1 (correctness) demote-on-transient-lag | `ensureMember` demotes only a genuinely-stuck (`!recent_active`) voter, not a responsive-but-lagging one | `src/cp/main.zig` |
| B2 (correctness) `nodeApplied`→`nodeLastIndex` | signal was already correct (compares `last_index` like-with-like); name + misleading comment fixed | `src/cp/main.zig` |
| B3 (correctness) reconciler re-address UAF | `Directory.resolveOwned` deep-copies the node set UNDER THE LOCK; reconciler uses it + `deinit`s per tenant. NOTE: move paths still aliased → **RC-4 (open above)** | `src/cp/main.zig` + `src/cp/directory.zig` |
| raft-rs-zig WAL (C1–C5 first pass) | `ed29bac` (release-optimized staticlib, closes `-O0` `movaps` GPF in `confchange::restore`), `c5c9a9c` (term-0 baseline reject `-5`, null-checks, loud drops), `6165419` (`-1`→`UnknownGroup`, baseline gate, `GapInLog` panic), `87ed59e` (C1 compaction-marker fsync-before-unlink, C2 `roll()` header+dir fsync, C4 malformed fixed-size reject, C5 confstate corruption propagation, S3 `FileNotFound` distinction, C3 unlink-fail log) | raft-rs-zig `main` |
| D soak harness | `scripts/smoke/raft_soak_prod.py` 3-node crash-recovery + wipe-heal soak, green incl. leader-kill mid-churn | (power-loss coverage still open — see Crash-consistency above) |
| RC-1 truncation-after-fold reproducer | `scripts/smoke/truncation_after_fold_smoke_v2.py` — an entry appended on a leader that cannot reach quorum is refused to the client, absent on the survivors, and truncated when its leader rejoins. The precondition is asserted (`last_index` must GROW), so a run that reproduces nothing fails rather than passing empty | `scripts/smoke/` |
| D — power-loss crash consistency | `scripts/ops/powerloss/run.py` — the real `rewind-worker` on a `dm-flakey` device that stops accepting writes mid-run. Every ACKED write survives the cut; a never-fsynced sentinel must be ABSENT or the round is VOID rather than passing. C3 covered when a run rolls a segment (`--writes 2000 --value-bytes 65536`, >64 MiB of WAL) | `scripts/ops/powerloss/` |
