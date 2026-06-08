# Effect reification plan

> **Status**: Phases 0–6 SHIPPED. The arc reified the four primitives
> of `effect-algebra.md` (Model, Continuation, Msg origins, Cmd
> runtimes) into concrete code artifacts under `src/js/effect/`,
> retired `http.send` as a Zig primitive (durability moved to JS
> shims), and closed the §7 worklist. Phase 4.1.4 (`conn_write` Cmd
> slot) + Phase 7 (files-server collapse) cancelled 2026-05-27. This
> doc is now reference for the as-built shape; the day-by-day phase
> history lives in `git log main..effect-reification`.
>
> **Prerequisite reading**: `docs/effect-algebra.md` — the model this
> plan reified. §3 below is the load-bearing implementation reference
> for anyone touching the dispatch core.

## 1. Goal

Turn `effect-algebra.md`'s four primitives — the Model, the
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

## 2. What it fixed

`effect-algebra.md §6` established that every divergence in the §5
audit had one root cause: the four primitives weren't factored out, so
each effect hand-rolled its slice and the copies drifted. Reification
was the single fix. Against the original `effect-algebra.md §7`
worklist (which is now ~empty — see that doc):

- **#1 fetch-A chunk bytes untaped** (live correctness bug) — became
  unconstructible: the only path a Msg reaches a handler is
  `enqueueMsg`, which tapes. **Closed by Phase 2.**
- **#3 uneven backpressure** — the bound is a property of the one
  `MsgQueue`; every origin inherits it. **Closed by Phase 2.**
- **#4 cross-worker resume O(workers×parked) scan** — the Continuation
  primitive owns a wake-correlation index. **Closed by Phase 3.**
- **#5 `cron_state` in a plain hashmap** — moved to a rove collection.
  **Closed by Phase 6.**
- **#2 streaming chunks ship pre-commit** + **#7 `events.emit` not
  commit-gated** — forced into one Cmd-release point via Phase 4.0.b;
  shipping pre-commit is now an explicit opt-in (`__rove_stream({
  eager_ship: true })`) reserved for customer demand.
- **#6 boot subscription double-fire UNCLEAR** — was already correct in
  the impl (`_boot_fired/<dep_id>` marker rides the writeset). Doc
  comment fixed in Phase 6.
- **#7 retire `http.send`** — DONE; durability is JS-shim composition.
  See [[project_durability_as_js_shim]].

## 3. As-built shape (load-bearing reference)

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
`kv_write` is an ordinary `Cmd` variant, and durable-intent (`webhook.send`'s
`_send/owed` marker) is a JS-shim that emits a `kv_write` Cmd rather
than a binding reaching into the txn directly.

### 3.2 The two unions — the contract as types

```zig
// effect/cmd.zig — every producer-bearing variant
pub const Cmd = union(enum) {
    kv_wake_broadcast: KvWake,
    stream_chunk:      StreamChunk,
    stream_close:      StreamClose,
    http_fetch:        HttpFetch,
    respond:           Respond,    // move-only h2 entity routing
};

// effect/msg.zig — consolidates pre-reification ActivationSource
pub const Msg = union(enum) {
    inbound_http:       Request,
    cron, boot, disconnect,
    kv_react:           KvReact,
    send_callback:      SendResult,
    fetch_chunk:        FetchChunk,
    fetch_done:         FetchDone,
    fetch_pipe_done:    FetchPipeDone,
    subscription_fire:  SubscriptionFire,
    // ...
};
```

The point is not the unions — it is that **every `switch` over them is
exhaustive**. Adding an effect = adding a variant; the compiler refuses
to build until the variant is handled in the tape path, the interpret
path, and the replay path. The contract stops being a doc you audit
against.

A `conn_write` variant for inbound-WebSocket frame writes was reserved
here (Phase 4.1.4) but is **no longer planned**: the Phase-2 handler
reshape made `stream.write` the one connection-output surface, so
outbound WS frames lower to the existing `Cmd.stream_chunk` (opcode-
tagged, RFC-6455-framed at the h2 serialize fork) rather than a new Cmd
([`docs/websocket-plan.md`](websocket-plan.md) §2.4 / §5). The "don't
park typed slots without a producer" rule still held — the producer that
finally shipped (`stream.write`) just turned out to reuse an existing
slot.

### 3.3 The Continuation + reconciler

Generalizes the Option-B `ParkedUnit` mechanism into the universal
primitive.

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
rove's deinit discipline, not by hope.

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
closes on itself. The Option-A one-request-lifecycle convergence —
every Msg-driven activation runs through the same park/drain/release
machinery, regardless of origin.

## 4. What was collapsed

The reification arc retired the following bespoke sites; each is now a
declaration on the typed Cmd/Msg unions instead of its own subsystem:

- `pending_txns` + `RaftWait` + `drainRaftPending` → the reconciler
  (the reference instance, byte-identical first then generalized)
- `raft_pending_response` / `_cont` / `_stream` → three Continuation
  collections sharing one reconciler
- `subscription_fire_pending` + `fetch_event_pending` → one `MsgQueue`
- `BatchSideEffects` writeset accumulator → typed `effect.Cmd` list
- `ParkedUnit` (`worker.zig`) → `effect.Continuation`
- `parkSendOps` + `parkKvWakes` → folded into `Continuation.buffered`
- `SendDispatch` + `InflightSet` + `send_outbox` + `callback_dispatch`
  (~4.7 kLOC of Zig) → deleted; durability is JS-shim composition
- `events.emit` + the platform-managed SSE pipe → deleted; customer-
  arbitrary SSE rides `__rove_stream` + kv-write wakes
  ([`streaming-model.md`](streaming-model.md))

## 5. Invariants — held at every step

1. **H2 is the reference.** The H2 request path's behavior stayed
   byte-identical until the generalized reconciler reproduced it.
   Generalize with H2 first, prove via smokes, *then* add non-H2
   registrants.
2. **Gate effect *release*, never KV *visibility*.** The reconciler
   gates externally-observable effects on commit. Local KV reads see
   the speculative overlay immediately (kvexp design). Conflating the
   two was the Stage-5 apply-after-replicate mistake (reverted) —
   memory `project_kv_batched_dispatch`. Do not repeat it.
3. **Determinism.** Every Msg is taped (L3). This is why reification is
   correctness, not just cleanup.
4. **No perf regression** vs the recent peak (~162k req/s 8-worker
   sharded per `project_perf_push_2026_05_21`; ~100k readonly floor
   per `project_kv_read_txn_per_op`). Compare to recent peak, never
   an old baseline — memory `feedback_regression_baseline_current_peak`.
5. **Every phase is independently shippable and reversible.**

## 6. Phase history (all shipped or cancelled)

| Phase | What | When |
|---|---|---|
| **0** | Inventory + baseline numbers in §4's table | 2026-05-22, tree at `90e2847` |
| **1** | Reify vocabulary — `effect/cmd.zig` + `effect/msg.zig` skeletons | shipped |
| **2** | Reify Msg ingress — unified `MsgQueue` + `enqueueMsg`; closed #1 fetch-A taping bug, #3 uneven backpressure | shipped |
| **3** | Reify Continuation + reconciler — generalized `drainRaftPending` to the universal park/wake/resume primitive; three siblings for the resume engines | shipped |
| **4.0.b** | Commit-gated stream chunks — resume-hop chunks stage on entity until writeset commits, then move into `StreamChunks` | 2026-05-22 |
| **4.1.1** | Typed Cmd union + `interpretCmd` exhaustive switch | 2026-05-24 |
| **4.1.2** | `http_fetch` staging — closes the marker-commit race | 2026-05-24 |
| **4.1.3** | `respond` Cmd routes H2 entity commit-move through `interpretCmd` | 2026-05-24 |
| **4.1.4** | `conn_write` Cmd slot — **WITHDRAWN:** outbound WS frames reuse `Cmd.stream_chunk` via `stream.write` ([`websocket-plan.md`](websocket-plan.md) §2.4); no new slot | n/a |
| **5** | Retire `http.send` as a Zig primitive; durability becomes JS-shim composition. ~4.7 kLOC Zig deleted | 2026-05-24, `b908953` |
| **6** | Cleanup tail — delete `src/connection_holder/`, move `cron_state` to a rove collection, resolve boot UNCLEAR (was already correct), rewrite effect-algebra §5/§6/§7, sweep CLAUDE.md dispatch wording | 2026-05-27 |
| **7** | Collapse `files-server` into Cmds + in-process compile worker — **CANCELLED** 2026-05-27. Files-server stays as a separate binary; customer-facing blob primitives deferred until concrete demand. |
| **3.5** | `WakeKey` index for O(1) cross-worker wake routing — **DEFERRED** (no trigger yet; per-worker scan isn't measured hot). Reactivate when connection-actor cross-worker work lands or measurement shows it. |

Per-phase commit messages on `effect-reification` branch have the
implementation detail.

## 7. Test & perf strategy

Per memory `user_freeze_workflow`: reification modified shipped,
smoke-tested code — this was **test-first** work. Each phase confirmed
the gating smoke pinned current behavior, refactored, proved green.

**Gating smoke set** (stayed green every phase): `leader_failover_smoke.py`,
`heldsync_smoke.py`, `http_send_smoke.py` (now the webhook.send JS-shim
path), the streaming smokes, `ctl_smoke.py`, `oidc_smoke.py`,
`readonly_speculation_faultinj_smoke.py`.

**Perf gate**: kv-bench hot single-tenant + 8w sharded, every phase
touching the dispatch path (3, 4, 5). All phases stayed within +/- of
the Phase-0 baseline.

## 8. Risks (retired)

- ~~**The dragon.**~~ The reconciler generalized the speculative-apply
  core every H2 request depends on. Mitigated via H2-reference-first,
  byte-identical, proven before any non-H2 registrant. No regression.
- ~~**The Stage-5 precedent.**~~ Reification gated effect *release*,
  not KV *visibility*. Invariant 2 held; no Stage-5-class regression.
- ~~**Merge collision with `streaming-model`.**~~ Mitigated by
  prerequisite ordering.

## 9. Out of scope

- **Streaming inbound body (gap 2.4)** — NOT BUILT; design locked in
  `streaming-model.md` §3. Reification made it a cheap declaration
  when someone ships the h2 chunk delivery wire-up.
- **Connection-actor WebSocket (gap 2.5 inbound)** — in progress
  (single-tenant / single-node); see
  [`websocket-plan.md`](websocket-plan.md). Outbound frames reuse
  `Cmd.stream_chunk` via `stream.write` — the reserved `conn_write` slot
  was withdrawn, not added.
- **Phase 7 files-server collapse** — cancelled 2026-05-27. Files-server
  stays as a separate binary; customer-facing `blob.put` / `blob.get`
  primitives deferred until concrete demand.
