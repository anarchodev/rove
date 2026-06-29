# Consensus robustness backlog

This is the open residue of two now-retired docs — the 2026-06-20
consensus/storage triage (`raft-consensus-storage-triage.md`) and the two-repo
`raft-correctness-plan.md`. The 2026-06-20 production incident itself is
**CLOSED** (root-caused, state-healed, and code-fixed where it was the trigger);
only forward hardening remains here. The SHIPPED/closed history lives in git
history and in [`../decisions.md`](../decisions.md) §10.5b (async-append commit =
fsynced-majority), §10.12, and §10.13, plus
[`../architecture/consensus-and-storage.md`](../architecture/consensus-and-storage.md).
Sibling docs that carry adjacent leads:
[`../architecture/raft-native-alignment.md`](../architecture/raft-native-alignment.md)
(as-built), `raft-best-practices.md`.

## Governing conventions

These two conventions are carried forward verbatim from the correctness plan
because they dictate **how** the open items below get fixed.

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

Standing acceptance criterion for everything below: *the fold gate
(`committed_seq`) fires only for a provably truncation-safe entry* — enforced in
code or asserted, with a test that reproduces the failure mode, not adjacent
green tests.

## Fail-loud / correctness hardening

- [ ] **RC-3 (from triage) — fsync failure drops commit notifications.** In the
      pump, on `wal.flush()` failure the guarded apply/ack block is correctly
      skipped (do not ack volatile data) but
      `commit_notify.clearRetainingCapacity()` runs **unconditionally**, so
      commit notifications staged in pass 1 are dropped: applied entries are
      never notified and the worker's `committed_seq` watermark fails to advance
      for them. Parked workers time out to 503 (acceptable), but coupling
      durability failure to apply-notification loss should not exist.
      File: `src/consensus/node.zig` pump (~1330-1381). Test: fault-inject
      `wal.flush()` failure with staged commit notifications; assert
      notifications are retained/retried, not dropped, and the watermark recovers
      on the next successful flush.

- [ ] **RC-4 (from triage) — CP move/provision use-after-free + stale follower
      routing.** `handleMoveLive` and `handleProvision` hold `resolve()` /
      `clusterById()` slices (aliasing the directory projection) across blocking
      HTTP calls, while a concurrent `/_control/cluster` re-address frees the
      projection on another thread — a UAF on the source/dest node arrays. The B3
      fix (`resolveOwned` deep-copy under the lock) was only wired into the
      reconciler; the move and provision paths still use the aliasing form
      (confirmed live: `src/cp/main.zig` `handleMoveLive` `resolve` at ~1147 +
      `clusterById` at ~1156, `handleProvision` `resolve` at ~645 + `clusterById`
      at ~649; only the reconciler at ~1086 uses `resolveOwned`). Separately,
      follower `resolve()` serves stale placement with no forward-to-leader
      guard, and the directory group itself inherits RC-1/RC-2.
      Files: `src/cp/main.zig` (`handleMoveLive` ~1134-1101, `handleProvision`
      ~625-652, plus the move-path siblings `reconcileStuckMoves` /
      `clusterById`), `src/cp/directory.zig` (`resolve`/`resolveOwned` ~638-644,
      `applyDirWrite` ~450-458). Tests: (a) re-address a cluster
      (`/_control/cluster`) during a live move/provision; assert no UAF under the
      sanitizer — fix by using `resolveOwned` on the move/provision paths; (b)
      follower routing read during a placement flip: assert it forwards to the
      leader or errors, never serves a stale route as authoritative.

- [ ] **RC-5 (from triage) — corruption-gated fail-loud violations**
      (MEDIUM/LOW; corruption-gated, not normal-operation loss).
      - `node.zig:775` — `epoch = std.fmt.parseInt(u64, e.value, 10) catch 0`: a
        corrupt groups-manifest epoch value defaults to 0, which would recover a
        moved group at the wrong epoch → fenced → stranded (feeds RC-2). Silent
        default that should fail loud.
      - `grouped_file_storage.zig:835` — the recovery pre-pass uses a compaction
        marker only `if (payload.len == COMPACTION_PAYLOAD_LEN)`; a CRC-valid but
        wrong-length marker is silently skipped, so compacted entries would be
        replayed. (This is the engine-side **C2** below; tracked here for the
        rove-visible failure mode.)
      Tests: corrupt the manifest epoch value, assert recovery fails loud, not
      `catch 0`; wrong-length-but-CRC-valid compaction marker, assert loud
      reject, not silent skip.

- [ ] **C4 assertion (from both docs) — `flush`-before-`on_persist`
      defense-in-depth.** The async-append safety ("commit quorum counts only
      fsynced entries", `decisions.md` §10.5b) holds **only** if every pump cycle
      does `process_ready → wal.flush → on_persist` per group. The production
      path was audited and **honors** this (the only production `on_persist`
      caller is the rove pump at `node.zig:1348`, guarded by `wal.flush()` at
      `node.zig:1330`; every other `on_persist` caller in raft-rs-zig
      `manager.zig` — 690, 709, 948, 1008, 1129 — is a test helper/body). So this
      is **not** an incident fix — but the storage layer can't enforce the
      contract, so add a debug-mode "dirty-since-last-flush" flag asserted in
      `on_persist` to catch a future non-flush-guarded caller in tests rather
      than silently acking volatile data in production.
      Files: raft-rs-zig `src/grouped_file_storage.zig` +
      `src/manager.zig` (`raft_manager_on_persist`). Land this first within the
      C-series — it converts the unenforced contract into a red test.

## Crash-consistency validation

- [ ] **D power-loss / fsync-ordering gap (from correctness-plan) — the single
      most important item here; tracked nowhere else.** `scripts/raft_soak_prod.py`
      exists and is green: a 3-node cluster under write churn + ungraceful
      `kill_node` + `wipe→reconciler-heal` rounds (the A2 promote-back rejoin
      window), asserting after each round that quorum holds, the victim rejoins
      as a caught-up voter, and every ACKED write is intact on every node.

      **What it does NOT prove:** a process SIGKILL does not drop the page cache
      (the kernel still flushes dirty pages), so the soak validates recovery
      LOGIC + A2's *persisted* watermark, but NOT the C1/C2 fsync ORDERING under
      true power loss. That needs power-loss tooling — run the node processes on a
      `dm-flakey` mount with `drop_writes`, or a VM hard-poweroff. Open until
      then: C1/C2 fsync ordering under power loss, and C3 segment-rename
      durability. This gate must be met (re-run the soak under `dm-flakey`) before
      `REWIND_CP_RECONCILE_MEMBERSHIP=1` can be argued as fully proven on prod.

- [ ] **Truncation-after-fold soak (RC-1 test, from triage).** Propose a write
      on a leader, induce a leader change before the entry is durable on a
      majority (partition/restart the other voters during the propose window),
      then assert the store does **not** retain the orphaned write and the
      response was a 503 (unknown outcome), never a 2xx. Today's soak only
      SIGKILLs (page cache survives) and never exercises this path — it is the
      deterministic reproducer the incident still lacks.

## Engine (raft-rs-zig) items

These are additive engine-robustness changes — land in raft-rs-zig, push, then
bump the rove pin (additive arm of the protocol above).

- [ ] **C1 (from correctness-plan) — `initial_state` / `first_index` /
      `last_index` collapse every storage rc to `Unavailable`** (LOW-MEDIUM).
      Only `entries`/`term` honor the `-2→Compacted` distinction. If a storage
      impl ever returns "compacted" from these, it is silently downgraded,
      changing raft's snapshot-vs-retry decision. File: `raft-sys/src/lib.rs`.

- [ ] **C2 (from correctness-plan) — recovery read-path malformed-record skips**
      (LOW-MEDIUM). `scanForReplay` and the `initRecover` compaction pre-pass
      silently skip a CRC-valid-but-wrong-length record. Left soft to avoid
      bricking recovery; revisit with a loud per-record log so corruption is
      visible without failing the whole recover. File:
      `src/grouped_file_storage.zig`. (Same site as RC-5's compaction-marker
      skip.)

- [ ] **C3 (from correctness-plan) — directory-fsync is best-effort only** (LOW,
      needs crash testing). `roll()` fsyncs the parent dir via the raw syscall
      with the result ignored (std's wrapper panics on EINVAL). Full
      crash-consistency of segment rolling (rename durability + ordering vs the
      new active create) is unverified — covered by the D power-loss gap above.

- [ ] **C4 (engine half — see Fail-loud above).** The debug
      "dirty-since-last-flush" assertion lives in
      `src/grouped_file_storage.zig` + `src/manager.zig`.

- [ ] **C5 (from correctness-plan) — lower / informational.** Broad `m`-null-
      check sweep across ~23 `extern "C"` fns (the manager handle is
      process-lifetime, never null in practice — cosmetic consistency);
      `MAX_REPLAY_PAYLOAD` aggregate cap (S2, low); `file_storage.zig`
      `truncate_at` unguarded index (benchmark-only backend, low).

- [ ] **B4 (from correctness-plan) — lower / informational (rove-side).**
      member-status `recent_active` idle false-negative (heartbeats keep it true
      — low); `lastIndex`/`logTerm` = 0 conflation surfaced to the reconciler
      (benign retry, but tied to A1, which is DONE); `apply.zig` read-only readset
      extraction silently skips a retired/corrupt inner envelope (by-design
      best-effort, but inconsistent with fail-loud — add a counter/log).

## Open architectural scrutiny (from raft-native-alignment)

Two divergences that the now-as-built `raft-native-alignment.md` left marked
**OPEN** — not bugs, but standing design questions to re-decide if the relevant
pressure shows up. The rest of that doc's divergences reached a verdict (align /
justified) and are recorded there + in `decisions.md` §10.12.

- [ ] **Speculative overlay (apply-before-commit + rollback) vs apply-on-commit.**
      raft applies *after* commit; rove applies speculatively into a volatile
      overlay and rolls back on fault. Scrutinize whether the latency win is
      worth the rollback path and the divergence from the native model. Not
      obviously harmful — on the ledger, not urgent. (This is the same fold-gate
      surface as the truncation-safety acceptance criterion above.)

- [ ] **Leader-only reads (dispatch-gate) vs `read_index` / follower-reads.**
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
  `scripts/snapshot_catchup_no_fork_smoke_v2.py` 3-node convergence smoke. **But
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
| D soak harness | `scripts/raft_soak_prod.py` 3-node crash-recovery + wipe-heal soak, green incl. leader-kill mid-churn | (power-loss coverage still open — see Crash-consistency above) |
