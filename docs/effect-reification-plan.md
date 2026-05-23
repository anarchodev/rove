# Effect reification plan

> **Status**: planned, not started — 2026-05-22.
> **Prerequisite reading**: `docs/effect-algebra.md` (the model this plan
> reifies) and `docs/unified-effect-gating.md` (the Option-A/B framing —
> this plan *is* the Option-A convergence).
> **Hard prerequisite**: the `streaming-model` branch must be merged to
> main first. Reification is a tree-wide refactor of the dispatch core;
> running it concurrently with a major feature branch guarantees merge
> conflict. Phase 0 (read-only inventory) can be done anytime; Phase 1+
> starts post-merge.

## 1. Goal

Turn the four primitives of `effect-algebra.md` — the Model, the
Continuation, Msg origins, Cmd runtimes — into four concrete code
artifacts under `src/js/effect/`. After reification, a named effect
(`http.send`, streaming, a subscription) is no longer a subsystem with
its own park/wake/tape/gate code: it is a *declaration* — one `Cmd`
union variant, one `Msg` union variant, and a transport. The
six-question contract of `effect-algebra.md §4` becomes
compiler-enforced: replay, backpressure, durability-gating and
failure-discard are inherited from the primitives; only Cmd shape and
Msg shape are declared, as tagged-union variants whose exhaustive
`switch` the compiler will not let you leave unwired.

## 2. Why now — what it fixes

`effect-algebra.md §6` established that every divergence in the §5 audit
has one root cause: the four primitives are not factored out, so each
effect hand-rolls its slice and the copies drift. Reification is the
single fix. Against the `effect-algebra.md §7` worklist:

- **#1 (fetch-A chunk bytes untaped — a live replay-correctness bug)** —
  becomes unconstructible: the only path a Msg can reach a handler is
  `enqueueMsg`, which tapes. Fixed in Phase 2.
- **#3 (uneven backpressure)** — the bound is a property of the one
  `MsgQueue`; every origin inherits it. Fixed in Phase 2.
- **#4 (cross-worker resume is an O(workers×parked) scan)** — the
  Continuation primitive owns a wake-correlation index. Fixed in Phase 3.
- **#5 (`cron_state` in a plain hashmap)** — becomes a Continuation /
  collection naturally. Phase 6.
- **#2 (streaming chunks ship pre-commit)** and **#7 (`events.emit` not
  commit-gated)** — forced into the open: Phase 4 creates exactly one
  Cmd-release point, so each becomes a one-line, documented decision
  instead of an emergent accident.

This is not cosmetic. #1 is a correctness bug today.

## 3. Target shape

### 3.1 Module layout

```
src/js/effect/
  root.zig          re-exports
  cmd.zig           the Cmd union + interpretCmd
  msg.zig           the Msg union + MsgQueue + enqueueMsg
  continuation.zig  the Continuation Row + reconcile (the reconciler)
```

The Model is **not** reified into this directory — it is already a
singleton (the kvexp `Cluster`). Reification's only Model-side change:
`kv_write` becomes an ordinary `Cmd` variant, and durable-intent
(`http.send`'s `_send/owed` marker) becomes "a Cmd runtime that *emits a
`kv_write` Cmd*" rather than a binding reaching into the txn directly.

### 3.2 The two unions — the contract as types

```zig
// effect/cmd.zig
pub const Cmd = union(enum) {
    kv_write:   WriteSet,        // the Model-targeted Cmd
    http_out:   HttpOut,         // send + fetch — durable? + disposition
    emit:       EmitEvent,
    respond:    ResponseChunk,   // response / stream output
    conn_write: FrameOut,
};

// effect/msg.zig — consolidates today's log_mod.ActivationSource
pub const Msg = union(enum) {
    inbound_http:  Request,
    cron, boot, disconnect,
    kv_react:      KvReact,
    send_callback: SendResult,
    fetch_chunk:   FetchChunk,
    fetch_done:    FetchDone,
    inbound_frame: Frame,
    body_chunk:    BodyChunk,
};
```

The point is not the unions — it is that **every `switch` over them is
exhaustive**. Adding an effect = adding a variant; the compiler then
refuses to build until the variant is handled in the tape path, the
interpret path, and the replay path. The contract stops being a doc you
audit against.

### 3.3 The Continuation + reconciler

Generalizes the already-shipped `ParkedUnit` (`unified-effect-gating.md`
Option B) into the universal primitive.

```zig
// effect/continuation.zig
pub const Continuation = struct {
    seq:         RaftSeq,      // the commit gate
    txn:         *TrackedTxn,
    buffered:    CmdBuffer,    // L4 — released only after seq commits
    wake:        WakeKey,      // what Msg resumes this; also the index key
    deadline_ns: i64,
    pub fn deinit(c: *Continuation) void { ... }  // abandon-safe (L2)
};

/// One system, run each tick. `resume` is a comptime parameter:
/// distinct resume behavior is a distinct collection (rove idiom —
/// state is collection membership), not a stored function pointer.
fn reconcile(comptime resume: ResumeFn, col: *Collection(Continuation)) void {
    for (col.live()) |*c| {
        if (committedSeq() >= c.seq) {
            c.txn.commit();
            interpretAll(c.buffered);   // L4 gate opens HERE
            resume(c, .ok);
        } else if (faulted(c.seq) or now() >= c.deadline_ns) {
            c.txn.rollback();
            c.buffered.discard();       // nothing escaped
            resume(c, .fault);
        }
    }
}
```

Because `Continuation.deinit` frees the txn and buffered Cmds, a
`Collection.deinit` on crash *is* L2 ("safe to abandon") — enforced by
rove's deinit discipline, not by hope (see memory
`project_resource_owning_components`).

### 3.4 The activation loop — every effect on one path

```
drain MsgQueue → for each Msg:
    c   = continuationFor(msg.wake)        // lookup (indexed) or create
    ctx = { model_snapshot, msg }
    (writeset, cmds) = runHandler(c.resume_point, ctx)
    c.seq      = propose(writeset)         // _send/owed markers ride inside
    c.buffered = cmds                      // NOT released
reconcile tick → commit ? interpret(cmds) + resume : discard + rollback
```

A released Cmd whose transport completes calls `enqueueMsg` — the loop
closes on itself. This is `unified-effect-gating.md §4` Option A.

## 4. Current state — the bespoke sites to collapse

Pointers confirmed against tree at `90e2847` (Phase 0, 2026-05-22).

| Bespoke today | Reified into | Notes |
|---|---|---|
| `BatchSideEffects` writeset accumulator (`worker.zig:508`) — the per-tick handler-emitted ops bundle | `effect.Cmd` (list) | shipped piece of `project_handler_returns_cmds`; Phase 1 consolidates the element type |
| `log_mod.ActivationSource` enum (`log/root.zig:58`) — 10 variants, used at `worker.zig:3247, 3290, 3333, 5457, 6846` | `effect.Msg` tag | already enumerates Msg kinds |
| `ParkedUnit` (`worker.zig:132`) + `parked_units` field (`worker.zig:2144`) + `proposeForgetfulWrites` (`worker.zig:6247`) | `effect.Continuation` | Option-B mechanism — generalize, don't rebuild |
| `pending_txns` (`worker.zig:2135`) + `RaftWait` (`worker.zig:114`) + `drainRaftPending` (`worker.zig:4308`; H2-path subfns at `4124`, `4184`, `4252`) | `reconcile` (the reference instance) | byte-identical first |
| `raft_pending_response` / `_cont` / `_stream` (`worker.zig:2082` / `2085` / `2088`) | `Continuation` collections | the "three siblings" |
| `parked_continuations` (`worker.zig:2099`); `stream_data_out` / `stream_response_in` (`h2/root.zig:397` / `396`) | `Continuation` collections | one Row, N collections by resume-disposition |
| `subscription_fire_pending` (`worker.zig:2156`); `fetch_event_pending` (`worker.zig:2182`) | one `MsgQueue` | |
| `SubscriptionFireInbox` (`worker.zig:399`); `FetchChunkInbox` (`worker.zig:454`) | one `MsgQueue` ingress | cross-thread |
| `SendDispatch` (`send_dispatch.zig:405`) + `InflightSet` (`send_inflight.zig:100`) + `send_outbox.zig` | **DELETE** in revised Phase 5 | `http.send` retires as a Zig primitive (2026-05-22); durability composes from kv + cron + boot subscription via `webhook.send.js` / `email.send.js` |
| `FetchPool` (`fetch_pool.zig:51`) | the single outbound HTTP runtime — `http_out` Cmd transport | response-disposition (whole / `on_chunk` / `pipe_to`) is the only parameter; `durable?` is gone |
| `_send/owed` / `_send/proof` apply-time markers (`apply.zig`) | regular env-0 kv writes — no special case | the JS shim writes them as ordinary keys; apply.zig's special branches go away with `SendDispatch` |
| `cron_state` `StringHashMapUnmanaged` (`worker.zig:1326-1327`, guarded by `cron_state_mutex`) | a collection | worklist #5 |
| `parkSendOps` (`worker.zig:7007`) + `parkKvWakes` (`worker.zig:7057`) — current ParkedUnit registrants | folded into `Continuation.buffered` | the helpers go away with the unification |

What is already done and must be *reused, not rebuilt*: the handler
returns a Cmd-list (`project_handler_returns_cmds`, shipped 2026-05-20);
the `ParkedUnit` commit-gated reconciler mechanism (Option B).

**Option-B `ParkedUnit` migration state — substantially complete for
the externally-observable-effect class.** Against
`unified-effect-gating.md §5`:

- **idiom-1** (`tenant_batch` internal + callback) — MIGRATED. Registrants:
  anchor path `worker_dispatch.zig:697-709` (`parkSendOps` +
  `parkKvWakes` after `proposeBatch`); callback path
  `callback_dispatch.zig:151-155`; cont-resume path
  `worker.zig:4548, 4574-4577`; disconnect/forgetful path
  `worker.zig:6247+` (`proposeForgetfulWrites` builds + creates the unit).
- **idiom-2** (`platform.releases.publish` / admin-kv / `deployStarter`
  / `platform.scope.kv`) — MIGRATED. Admin-handler trampolines
  (`worker.zig:2617, 2680, 2739`) fold writes into the dispatch tick's
  `BatchSideEffects` bundle, which goes through the same idiom-1 gate at
  `worker_dispatch.zig:651`. The release POST handler
  (`worker_dispatch.zig:1583`) and admin-kv POST (`worker_dispatch.zig:1726`)
  park the entity in `raft_pending_response` directly.
- **idiom-3a** (ACME cert propose) — **NOT MIGRATED.** `src/loop46/acme.zig:210`
  calls `cfg.raft.propose(seq, env)` directly; no `ParkedUnit`, no entity
  park. Acceptable today only because the bound effect (cert install)
  is self-healing on the next ACME pass — re-derived class.
- **idiom-3b** (`callback_dispatch.zig:288` Seam-A `_send/proof/` propose;
  `worker.zig:3622` `config_mirror` `mirrorDeployConfig` propose) —
  NOT MIGRATED. Both deliberate: the proof-propose recovery is the
  durable `_send/owed` + boot-scan path; `config_mirror` is idempotently
  re-derived on next deploy load.
- **`events.emit` / SSE worklist item #7** — **MOOT.** The
  platform-managed SSE pipe (in-process sse-server thread,
  `_session/sse-token` mint, `events.emit` global) was retired in
  streaming-handlers Phase 5 (note at `loop46/main.zig:1325-1340`).
  `ParkedUnit` carries no `emits` field because the surface no longer
  exists; customers compose SSE on `__rove_stream` + kv-write wakes.
  `effect-algebra.md §7` worklist #7 and `unified-effect-gating.md §6`'s
  systemic SSE-emit fix should both be marked closed-by-retirement.

Remaining fire-and-forget proposers (ACME, proof, config-mirror) sit
in the re-derivable / self-healing class, not the
externally-observable-effect class. The Option-B mechanism is in place
everywhere effects can escape pre-commit.

## 5. Invariants — hold at every step

1. **H2 is the reference.** The H2 request path's behavior stays
   byte-identical until the generalized reconciler is proven to
   reproduce it. Generalize with H2 behavior first, prove via smokes,
   *then* add non-H2 registrants.
2. **Gate effect *release*, never KV *visibility*.** The reconciler
   gates externally-observable effects on commit. Local KV reads still
   see the speculative overlay immediately (kvexp design). Conflating
   the two was the Stage-5 apply-after-replicate mistake that was
   reverted — see memory `project_kv_batched_dispatch`. Do not repeat it.
3. **Determinism.** Every Msg is taped (L3). This is why reification is
   correctness, not just cleanup.
4. **No perf regression** vs the current peak (Phase 0 measures it;
   reference points: ~162k req/s 8-worker sharded per
   `project_perf_push_2026_05_21`, ~100k readonly floor per
   `project_kv_read_txn_per_op`). Compare to the *recent peak*, never an
   old baseline — memory `feedback_regression_baseline_current_peak`.
5. **Every phase is independently shippable and reversible.** No phase
   leaves the tree in a non-building or behavior-divergent state.

## 6. Phases

Each phase: **Goal / Steps / Gate / New tests / Done / Rollback.**
Phases 2 and 3 are independent (Msg ingress vs Continuation) and may
interleave. Phase 4 needs 3; Phase 5 needs 3+4.

### Phase 0 — Inventory & baseline (read-only)

- **Goal**: remove all unknowns before touching code.
- **Steps**: fill §4's table with exact `file:line`; establish the
  Option-B `ParkedUnit` migration state against `unified-effect-gating.md
  §5`; run the gating smoke set (§7) and record green; run kv-bench (hot
  single-tenant + 8w sharded) and record the baseline numbers *into this
  doc*.
- **Done**: §4 table exact; baseline numbers recorded here; smoke set
  green on the starting branch.
- **Rollback**: n/a (no code change).

#### Phase 0 results — 2026-05-22, tree at `90e2847`

§4 pointers refreshed in place. Migration state: idiom-1 and idiom-2
fully on Option-B; idiom-3a (ACME) + idiom-3b (proof / config-mirror) intentional
fire-and-forget in the self-healing class; SSE/`events.emit` retired —
worklist #7 closed-by-retirement (not by reification).

Gating smokes green on `90e2847` (ReleaseFast, all 3-node clusters
self-spawned by the smokes):

- `ctl_smoke.py` ✓
- `leader_failover_smoke.py` ✓ (H2 reference)
- `heldsync_smoke.py` ✓ (continuation reference)
- `http_send_smoke.py` ✓
- `streaming_smoke.py` ✓ + 10 streaming-family smokes: `streaming_kv_wake`,
  `streaming_overflow`, `streaming_first_hop_writes`,
  `streaming_disconnect_writes`, `streaming_heartbeat`,
  `streaming_kv_wake_writes`, `streaming_write_pressure`,
  `streaming_subscription_cron`, `streaming_subscription_boot`,
  `streaming_subscription_kv` — all ✓
- `fetch_chunk_smoke.py` ✓ + `fetch_streaming_smoke.py` ✓ + `pipe_smoke.py` ✓
- `readonly_speculation_faultinj_smoke.py` ✓ (idiom-0 gate)
- `cookie_auth_smoke.py` — referenced in §7 but **does not exist in
  `scripts/`**; doc-stale (substitute: `oidc_smoke.py` covers the
  auth surface). Update §7 when next editing.

kv-bench baseline (3-node `kv_bench_cluster.sh` over `*.rewindjsapp.localhost`,
2 runs averaged; ReleaseFast, `WORKERS=8`, 30k req/tenant, c=10, m=10):

| Workload | Run 1 | Run 2 | Phase 0 baseline | Recent peak (reference) |
|---|---|---|---|---|
| hot (1 tenant, 1 key) | 45,531 | 46,284 | **~46k req/s** | n/a — write workload, not the ~100k readonly floor |
| spread (1 tenant, 1000 keys) | 42,742 | 41,004 | **~42k req/s** | n/a |
| sharded (8 tenants, write workload) | 145,598 | 134,443 | **~140k req/s** | ~162k (`project_perf_push_2026_05_21`) |

Sharded is ~86–90% of the recent peak — within plausible h2load
variance but on the lower side. Treat **`~140k 8w-sharded` as the
Phase 0 baseline** for the §6 perf gate; Phase 1+ must stay above
~135k (10% margin under the lower observed run). Compare to the
recent peak per `feedback_regression_baseline_current_peak` if a
single phase drops sharply.

Speculative-chain telemetry sampled at the same runs: mean depth
3.4–5.1, peak 10, `spec_commits` rate 0% — the chain stays short and
no apply-time speculation kicked in for these workloads, so the
baseline measures the dispatch-and-propose path, not the
speculative-commit path.

The hot/spread numbers (~46k / ~42k) are the *write* path; the
~100k readonly floor from `project_kv_read_txn_per_op` is a separate
workload not exercised by `kv_bench_cluster.sh`. Phase 3 (the
reconciler — the dragon) should add a readonly-path measurement to
the perf gate before any non-H2 registrant lands.

### Phase 1 — Reify the vocabulary

- **Goal**: `effect.Cmd` and `effect.Msg` are the single source of truth
  for the two vocabularies. No behavior change.
- **Steps**: create `effect/cmd.zig`, `effect/msg.zig`; move the handler
  Cmd-list element type to `effect.Cmd`; fold `ActivationSource` into
  `effect.Msg`. Mechanical consolidation only.
- **Gate**: `zig build test` + full smoke set green; behavior
  byte-identical.
- **New tests**: none (no behavior change) — but every `switch` over the
  old enums must now be exhaustive over the union; the compiler enforces
  the first slice of the contract here.
- **Done**: both unions live; nothing behavioral changed.
- **Rollback**: revert the two files (additive).

### Phase 2 — Reify the Msg ingress

- **Goal**: one `MsgQueue`; every Msg taped by construction; one bounded
  ring gives every origin backpressure.
- **Steps**: build `MsgQueue` + `enqueueMsg` (tapes unconditionally) +
  the cross-thread ingress. Migrate origins **one PR each**, lowest
  traffic first:
  - **2B** — cron + boot (done, `0ba3215`).
  - **2C** — kv-react (done, `9ac6ea3`).
  - **2D** — outbound HTTP (`http_chunk` / `http_done` /
    `http_pipe_done`). The `send_callback` Msg variant **does not
    exist** under the 2026-05-22 architecture decision: durability
    moves to JS shims, so what was `send_callback` is just
    `http_done` activating the shim's `on_result` chain hop.
  - **2F** — inbound-HTTP (the reference path).
- **Gate**: per origin, the matching smokes (subscription smokes,
  outbound HTTP smokes — `http_send_smoke` continues to gate `webhook.
  send.js` after Phase 5's JS-shim work lands, h2 smokes).
- **New tests**: a fetch + `on_chunk` **replay-equivalence smoke** — the
  regression gate proving worklist #1 fixed (a replayed fetch chain
  produces an identical writeset + Cmd sequence).
- **Done**: `subscription_fire_pending` (gone, 2C), `fetch_event_pending`
  (gone in 2D), and both cross-thread inboxes (collapse with 2D / 2F);
  every origin routes through `enqueueMsg`.
- **Rollback**: per-origin PRs revert independently.

### Phase 3 — Reify the Continuation + reconciler (the core)

- **Goal**: one `Continuation` Row + one `reconcile` system replace the
  ~6 hand-rolled park/wake/resume sites (`fetch_event_pending` retired
  in 2D, `subscription_fire_pending` in 2C); a wake-correlation index
  replaces the cross-worker scan.
- **Done**: one `Continuation` collection-family, one reconciler; the
  bespoke parked sites and `pending_txns` gone; resume is O(1).

Phase 3 is "the dragon" — generalizing the speculative-apply core
every H2 request rides. Broken into sub-phases so blast radius is
bounded; **invariant 1** governs: H2 stays byte-identical until the
generalized reconciler is proven to reproduce it.

#### Phase 3.0 — vocabulary + sub-plan (this PR-shape)

- Declare `effect.Continuation` (the generalized commit-gated unit) +
  `Disposition` enum + `WakeKey` (the future O(1) wake-route index
  key, declared but unindexed) + `reconcile` template.
- Comptime-generic over txn / buffered types — no import of
  `kv_mod` / `send_dispatch_mod` from the effect module (preserves
  the leaf shape, dodges the cycle).
- **No migration.** Pure type declarations, same pattern as Phase 1.
- Gate: `zig build test` + smokes byte-identical.

#### Phase 3.1 — migrate `parked_units` onto `Continuation`

The easiest existing parked site to generalize because it's already
commit-gated end to end (parkSendOps + parkKvWakes +
proposeForgetfulWrites all use it). H2-path-untouched.

- Convert `worker.ParkedUnit` into the concrete instantiation of
  `effect.Continuation` (or wrap — whichever lets `send_dispatch_mod.
  OwnedIntent` + `KvWakeOp` stay in `worker.zig`).
- Extract the `drainRaftPending` parked_units sweep into a
  `reconcile`-call against the generic.
- Gate: `heldsync_smoke` + `http_send_smoke` + `streaming_*` +
  `leader_failover` + perf gate (~135k 8w-sharded floor) +
  readonly perf measurement (Phase 0 noted this — the dragon's
  perf gate must include readonly; current kv-bench is write-only).
- Rollback: revert the migration; ParkedUnit-as-is keeps working.

#### Phase 3.2 — generalize `drainRaftPending` (the H2 reference)

The dragon's spine. The H2 request path's
`pending_txns + RaftWait + drainRaftPending` triad generalizes into
the same reconcile primitive, **byte-identical**.

- Map RaftWait → `Continuation.seq + deadline_ns`. pending_txns →
  `Continuation.txn` (or its instantiation). drainRaftPending's
  raft_pending_response sweep → reconcile-call.
- Prove byte-identical via the full smoke set + perf gate.
- Rollback: revert; the bespoke shape returns.

This is the high-risk PR. Approach: build the generalized
reconciler alongside the existing drainRaftPending arm (both run);
prove the generalized one produces identical behavior on the H2
reference; then delete the bespoke arm.

#### Phase 3.3 — migrate `raft_pending_cont` + `parked_continuations`

**No-op as a separate sub-phase** (re-evaluated after 3.2.b). The
3.2.b `drainEntityArm` helper already processes `raft_pending_cont`
identically to the other H2 siblings — the migration goal (one
Continuation drain for the three H2 sibs) is met. Held-sync
continuations route into `parked_continuations` on the 3.2.b commit
arm; resume happens via `resumeBoundContinuation` (a separate
mechanism not part of the parked-seq drain). No further unification
work required for Phase 3's "one Continuation runtime" claim.

#### Phase 3.4 — migrate `raft_pending_stream` + `stream_*`

**Same no-op as 3.3.** `raft_pending_stream` is processed by
`drainEntityArm` via the 3.2.b collapse. The stream lifecycle
proper (`stream_data_out` → `stream_response_in` → h2 ship)
operates after the entity leaves `raft_pending_stream` and is a
distinct h2-owned state machine, not a parked-seq drain.

#### Phase 3.5 — add the `WakeKey` index; delete the cross-worker scan

**Deferred** (decision 2026-05-22). The current scan in
`resumeBoundContinuation` (`worker.zig:4747`) is **worker-local**,
not cross-worker — it iterates the worker's own
`parked_continuations.entitySlice()`. Algebra worklist #4's
"cross-worker scan" framing was aspirational against
connection-actor's unbuilt cross-worker case; today's scan is
bounded by per-worker in-flight held-sync count and not measured
as hot. The index-maintenance discipline (every site that moves
entities into / out of `parked_continuations` — including the
`resumeContinuation` re-park path where `bound_schedule_id`
changes mid-chain — must keep the index in sync, or stale entries
silently break resume) is real cost.

Trigger conditions for picking 3.5 back up:
1. Measurement shows the worker-local scan is hot under realistic
   held-sync load.
2. Connection-actor's cross-worker case lands and forces an
   indexed route (its design will dictate the index shape).
3. A new origin needs O(1) wake routing (e.g., the WebSocket
   inbound frame path).

The `WakeKey` type declared in Phase 3.0 stays — it's the
vocabulary the eventual index uses. The `Continuation.wake_key`
slot is unused at the migrated parked_units site; no harm.

### Phase 3 status — substantially complete (2026-05-22)

The algebra's structural goal — **one Continuation runtime** — is
met for every active parked-seq path:

- ParkedUnit instantiates `effect.Continuation` (3.1).
- The three H2 sibling drains share `drainEntityArm` + classify
  (3.2.a / 3.2.b).
- `pending_txns` is encapsulated as `effect.SharedTxnPool` with a
  documented sharing invariant (3.2.c).
- 3.3 / 3.4 are met-by-coverage (the 3.2.b helper processes their
  collections uniformly); the rest of the stream lifecycle is
  h2-owned and not part of Phase 3's scope.
- 3.5 deferred per above.

Rollback for the substantially-complete set: each sub-phase
commit reverts independently to its bespoke predecessor (Phase 3.0
through 3.2.c).

### Phase 4 — Reify Cmd interpretation + the commit-gated buffer

Revised 2026-05-22 in light of two prior decisions:

1. **`events.emit` retired.** Worklist #7 ("`events.emit` becomes a
   buffered Cmd") is closed-by-retirement, not by reification.
   `events.emit` doesn't exist as a Cmd variant.
2. **`http.send` retiring in Phase 5** ([[project_durability_as_js_shim]]).
   `effect.Cmd.http_out`'s shape is fluid until Phase 5 lands — wiring
   `interpretCmd` for it now means rewiring it after Phase 5. Phase 5
   first, then Phase 4's interpretCmd sees a stable surface.

- **Goal (revised)**: force the streaming-pre-commit decision
  (algebra §7 worklist #2) — the last open architectural item Phase
  4 owns. Code-side `interpretCmd` is deferred to a post-Phase-5
  Phase 4.X.
- **Phase 4.0 (this PR's eventual shape)**: investigate the actual
  streaming-pre-commit code paths. The §2 rule —
  > A chunk reaches the wire only after the activation that
  > produced it has committed.
  — is what the model promises. The algebra audit flagged that
  `proposeForgetfulWrites` + the resume path may violate this in
  practice (the audit cites `streaming-model.md §7/§9.4` and the
  resume path's writes-async pattern). The decision either fixes
  the code or rewrites §2. **No "one rule with an exception" — pick
  one.**
- **Phase 4.1 (post-Phase-5)**: implement `interpretCmd` as the
  exhaustive switch over the post-Phase-5 Cmd union (kv_write +
  unified outbound HTTP + respond + conn_write). Move the effect
  buffer onto Continuation; the reconciler releases on commit,
  discards on fault.
- **Gate**: streaming smokes (for 4.0's pre-commit decision);
  `http_send` smokes + streaming smokes (for 4.1).
- **Done**: streaming model says what the code does and vice versa;
  no Cmd escapes except through the reconciler's commit gate (Phase
  4.1).
- **Rollback**: 4.0 is a doc + small code change per arm; 4.1 is
  per-Cmd-kind incremental.

### Phase 5 — Retire `http.send`; durability becomes JS-shim composition

Revised 2026-05-22. Earlier drafts said "collapse SendDispatch + FetchPool
into one transport." Per the
[[project_durability_as_js_shim]] decision, the right move is
**delete SendDispatch entirely** and rebuild its semantics as a
composition in the JS standard library. The cost (per-fire JS dispatch
overhead) is acceptable pre-launch and an obvious paid-tier-fast-path
target later.

- **Goal**: one outbound HTTP runtime in Zig (`FetchPool` renamed);
  durability is a JS-shim composition (`webhook.send.js` /
  `email.send.js`) on top of `kv` + the outbound primitive + cron
  subscriptions + boot subscriptions.
- **Steps** (one collapse per PR):
  1. **Ship `webhook.send.js` shim** that composes:
     - `kv.set("_send/owed/{id}", JSON.stringify({url, body,
       attempts, next_at_ns}))` — rides envelope-0 atomic with the
       handler's writeset.
     - `http.request(url, {on_result: "<shim's onresult module>"})` —
       first attempt fires immediately, same latency as today's
       SendDispatch.
     - `<shim's onresult>` module — clears `_send/owed/{id}` on
       success; updates `next_at_ns` + `attempts` on retryable
       failure; deletes the marker on giving-up.
     - `_subscriptions/_send_retry/` cron subscription (1 Hz default)
       — scans `_send/owed/` for entries past `next_at_ns`, re-fires.
     - `_subscriptions/_send_recover/` boot subscription — fires once
       per deployment activation; same scan logic, picks up orphans
       across leader changes.
  2. **Ship `email.send.js`** as a thin wrapper over `webhook.send.js`
     (or directly equivalent — Resend's API is HTTP).
  3. **Migrate `email.send` + `webhook.send` JS bindings** to use the
     shim. Existing customer code (calling `email.send` / `webhook.
     send`) is unchanged; only the implementation flips.
  4. **Delete the Zig kernel**: `send_dispatch.zig`, `send_inflight.
     zig`, `send_outbox.zig`. Delete `parkSendOps` /
     `firePendingSendOps`. Delete the apply.zig special-case branches
     for `_send/owed` and `_send/proof` (they become ordinary kv
     writes). Delete the `send_callback` activation source from
     `log_mod.ActivationSource` (replay tape compatibility note below).
  5. **Rename `FetchPool` → `OutboundHttpPool`** (or keep the name;
     bikeshed-grade). Confirm no `durable?` parameter survives.
  6. **Replay-tape compatibility** for `.send_callback`: old tapes
     have an enum value referencing it. Choose: (a) keep the variant
     in `ActivationSource` as a deprecated never-emitted entry,
     decoded but unused; or (b) bump the tape format major. (a)
     is cheaper and probably right pre-launch. Decision rides with
     this phase's first PR.
- **Gate**: per PR, the matching smokes:
  - `http_send_smoke` — exercises `email.send` / `webhook.send`
    end-to-end. After step 3 it tests the JS shim path; after step 4
    it confirms `SendDispatch` is gone (no metrics, no envelope-0
    handling).
  - `leader_failover_smoke` — verifies cross-failover delivery still
    works via the boot subscription. (Currently flaky per
    [[project_leader_failover_smoke_flake]] — fix the smoke as part
    of this phase or accept the known flake.)
  - perf gate: kv-bench + `http_send_smoke` end-to-end timing. Pre-
    launch we accept a slowdown vs native SendDispatch; the
    Phase-0 baseline is the regression floor for the *outbound HTTP
    primitive itself*, not for the durable path.
- **Done**: `src/js/send_dispatch.zig`, `send_inflight.zig`,
  `send_outbox.zig` deleted. `webhook.send.js` and `email.send.js`
  ship the durability composition. `http_send_smoke` exercises the
  JS-shim path. `apply.zig` has no remaining `_send/`-prefix
  special-casing. The §13 process map shrinks.
- **Risk**: this is a customer-visible behavioral change in latency
  characteristics (JS dispatch adds overhead per retry). Pre-launch
  it is acceptable; post-launch a paid-tier fast path
  (pattern-matches the shim's `kv.set` + `http.request` sequence and
  bypasses to native dispatch) restores the latency profile without
  changing the customer API. Out of scope here; tracked separately.

### Phase 6 — Cleanup tail

- **Goal**: `effect-algebra.md §7` worklist empty.
- **Steps**: delete `src/connection_holder/` dead scaffold; move
  `cron_state` onto a collection (#5); resolve the boot double-fire
  UNCLEAR (#6); rewrite `effect-algebra.md §5` audit + §6 to reflect the
  reified state; update `CLAUDE.md` if dispatch wording drifted.
- **Done**: audit re-run shows the reified state; worklist clear.

## 7. Test & perf strategy

Per memory `user_freeze_workflow`: reification modifies shipped,
smoke-tested code — this is **test-first** work. Each phase: confirm the
gating smoke pins current behavior, refactor, prove green.

**Gating smoke set** (all must stay green every phase):
`leader_failover_smoke.py`, `heldsync_smoke.py`, the `http_send` smokes,
the streaming smokes, `ctl_smoke.py`, `cookie_auth_smoke.py`,
`readonly_speculation_faultinj_smoke.py`.

**Perf gate**: kv-bench hot single-tenant + 8w sharded, every phase that
touches the dispatch path (3, 4, 5). Abort the phase on regression vs the
Phase-0 baseline.

## 8. Risks

- **The dragon.** The reconciler generalizes the speculative-apply core
  every H2 request depends on. Mitigation: H2-reference-first,
  byte-identical, proven before any non-H2 registrant (Invariant 1).
- **The Stage-5 precedent.** Apply-after-replicate regressed and was
  reverted (`project_kv_batched_dispatch`). Reification must gate effect
  *release*, not KV *visibility* (Invariant 2). If a phase needs to
  change visibility timing to work, stop — the design is wrong.
- **Merge collision with `streaming-model`.** Mitigated by the hard
  prerequisite: do not start Phase 1 until that branch merges.

## 9. Out of scope

- Streaming inbound body (gap 2.4) and connection-actor WebSocket (gap
  2.5) — NOT BUILT; reification does not build them, it makes them cheap
  *declarations* once someone does.
- No customer-observable behavior change, with two deliberate
  exceptions, both correctness: fetch-A becomes replayable (#1), and the
  streaming pre-commit semantics become explicit (#2).

## 10. First session (cold start)

You have just cleared context. To start:

1. Read `docs/effect-algebra.md`, then this doc, then
   `docs/unified-effect-gating.md §4–§5`.
2. Confirm `streaming-model` is merged to main. If not — **stop**; only
   Phase 0's read-only inventory may proceed.
3. Execute **Phase 0**: fill the §4 table with exact `file:line`;
   determine the Option-B `ParkedUnit` migration state; run the §7 smoke
   set and kv-bench; record the baseline numbers and the inventory
   *back into this doc* (§4 and a new "Phase 0 results" subsection).
4. That inventory is the gate for starting Phase 1. Do not skip it —
   the §4 pointers are from a 2026-05-22 audit and the tree moves.
