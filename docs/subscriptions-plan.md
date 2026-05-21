# Subscriptions — chain origins without an inbound request

**Status:** Phases A–C + E shipped 2026-05-20 on
`gap-2-1-subscriptions` branch. Phase D (boot firing) stubbed —
the deployment_loader thread doesn't have a worker context, and the
clean loader→worker handoff is a separate sub-design. Phase F
(cron firing) deferred — needs either a Zig duration parser +
worker-tick sweep, or piggybacking on SendDispatch with an
internal-target flavor; neither was scoped this session. Phase G
covers boot/cron smokes when D + F land. Implements
`docs/primitive-gaps.md` §2.1 + `streaming-handlers-plan.md`
§5 unfinished design ("chain origins that are NOT inbound
requests"). See §10 below for the per-phase status detail.

---

## 1. The shape

A **subscription** is a customer-registered handler that fires
**without an inbound HTTP request** — on a schedule, on a kv-write
match, or once on deployment activation. The handler is a normal
TEA `update : (Msg, Ctx) → (Effects, Cmd Msg)`; the difference is
the activation source (`subscription_fire`) and that there's
**no held socket** to flush to.

Three kinds:

| Kind  | Fires when | Use case |
|---|---|---|
| `cron` | A cron expression matches wall-clock time | Daily cleanup, scheduled reports, periodic reconciliation |
| `kv`   | Any key under `prefix` is put/deleted by ANY chain on this tenant | Inbox / job queue / event-sourced projection / audit trail |
| `boot` | Once on deployment activation | One-shot migration, index rebuild, schema bump |

The handler is a normal module; its return value (`Response` /
`__rove_next` / `__rove_stream`) is recorded on the tape but bytes
go nowhere — no socket to write to. `kv.set` and `http.send`
effects DO fire normally (commit through raft + leader-local
SendDispatch). `__rove_next` parking on a send completion DOES
work — the chain just has no flush target.

This is §5 of `streaming-handlers-plan.md` made concrete.

---

## 2. Customer surface

Two files per subscription, mirroring the trigger pattern's
path-based discovery (`_triggers/{prefix}/index.{mjs,js}`):

```
_subscriptions/<name>/index.mjs   ← the handler module
_subscriptions/<name>/spec.json   ← {kind, ...} metadata
```

Spec shapes:

```jsonc
// cron — fires on schedule
{ "kind": "cron", "schedule": "0 3 * * *" }

// kv-react — fires on writes under a tenant-scoped prefix
{ "kind": "kv", "prefix": "jobs/" }

// boot — fires once per deployment activation
{ "kind": "boot" }
```

The handler signature is the same as any other handler:

```js
export default function () {
  const a = request.activation;          // {kind: "subscription_fire", name, source}
  if (a.source.kind === "cron")  { ... }   // a.source.fired_at_ns
  if (a.source.kind === "kv")    { ... }   // a.source.key, a.source.op
  if (a.source.kind === "boot")  { ... }   // a.source.deployment_id

  // Reads + writes work normally.
  kv.set("audit/" + a.source.key, "processed");
  http.send({ url: "https://alerts.example.com", body: "..." });

  return { status: 200 };  // recorded; not transmitted
}
```

`request.session` is `null` (no browser context).
`request.correlation_id` is freshly minted per fire.
`request.activation.kind` is always `"subscription_fire"`; the
sub-`source.kind` discriminates cron / kv / boot.

---

## 3. Storage

Subscriptions live in the **deployment** (immutable per deploy),
not in `app.db`. Customers add/remove by re-deploying. Matches the
trigger pattern; matches the "deploy is the source of truth"
discipline.

The TenantFilesSnapshot grows one field:

```zig
subscriptions: []const SubscriptionEntry,
```

```zig
pub const SubscriptionEntry = struct {
    name: []u8,           // "cleanup-daily"
    module_path: []u8,    // "_subscriptions/cleanup-daily/index.mjs"
    spec: Spec,

    pub const Spec = union(enum) {
        cron: struct { schedule: []u8 },  // crontab string
        kv:   struct { prefix: []u8 },
        boot,
    };
};
```

---

## 4. Firing mechanisms

### 4.1 Boot

At snapshot-activation time (`worker.zig:reload`), after the
swap, walk `new_snap.subscriptions` for any `.boot` entries that
haven't fired for THIS deployment_id yet, and fire each.
Idempotency marker: `_boot_fired/{deployment_id}` in app.db
(written by the boot subscription's first apply); subsequent
restarts skip already-fired ones.

### 4.2 cron

A cron subscription is a self-rescheduling internal `http.send`.
**No new persistent thread.** Reuses the existing SendDispatch
machinery:

- Deploy-time arming: for each cron subscription on the new
  snapshot, if there's no live `_send/owed/<sub-id>` arm,
  write one with `fire_at_ns = next(spec)`. The sub-id is a
  deterministic hash of `(tenant, name, deployment_id)` so deploy
  is idempotent.
- Firing: SendDispatch fires the arm at the scheduled time —
  but the target is INTERNAL (`__subscription__://<name>` URL
  shape; the send dispatcher routes in-process to
  `fireSubscriptionActivation` instead of curl).
- Re-arming: the subscription handler's apply phase writes the
  next `_send/owed/<sub-id>` with `fire_at_ns = next(spec)`.

Cross-node correctness comes from raft (the `_send/owed/` write
is envelope-0; the leader fires it).

### 4.3 kv-react

Apply-time hook (extending the existing kv-write fan-out in
`apply.zig`'s `applyWriteSet`). For each writeset entry, scan the
tenant's subscription registry for matching kv prefixes (separate
from the parked-stream prefix scan that's already there). On
match, fire `fireSubscriptionActivation` directly.

Critical question: **leader-only vs follower-also?** Apply runs
on every node (raft replication). If kv-react fires on every
node, the same subscription fires N times for N nodes — duplicate
effects.

Resolution: fire **only on the leader**. The apply hook checks
`node.is_leader()` before firing. (Same posture as the existing
SendDispatch — leader-local per `http_send_plan` §4.) Followers
skip; the chain origin is leader-only.

---

## 5. Dispatcher entry

`fireSubscriptionActivation(worker, tenant_id, sub_entry, source)`
— structural twin of `fireDisconnectActivation`:

- Resolve deployment via the standard path.
- Synthesize a request: `correlation_id` minted fresh, `activation_source
  = .subscription_fire`, `activation_subscription = {name, source}`.
- Run handler via `dispatcher.runOutcome`.
- Apply effects (writeset propose through raft; http.send through
  SendDispatch).
- Record the return value on the tape; no flush.

The return Cmd is honored: `__rove_next` parks awaiting send
completion (works), `__rove_stream` parks awaiting wakes (works,
chunks recorded but never transmitted), `Response` is the
terminal-with-no-flush case.

---

## 6. Replay determinism

Per-activation tape; same shape as existing wake-driven entries.
The chain's `correlation_id` is fresh on each fire. The activation
payload (cron `fired_at_ns`, kv `{key, op}`, boot `deployment_id`)
is a taped input.

A cron fire that triggers an `http.send` whose callback writes kv
that triggers a kv-react that... cascades through normal chain
mechanics. The tape records each activation independently;
correlation_id links the cron's own chain; cross-chain edges
(kv-react chain whose origin write came from cron chain) are
recoverable from the tape but not separately stored — same as
streaming-handlers-plan §5.

---

## 7. Cross-cutting

**Tenant scoping.** kv-react subscriptions match only their own
tenant's writes — same invariant as the parked-stream §4.6 wake.

**Resource caps.** Per-tenant simultaneous subscription firings
(default in the hundreds; configurable). Hitting the cap drops
new fires with a logged warning — same shape as the §9.2 strike
posture on streams.

**Error handling.** A subscription handler that throws or hits its
budget records a `handler_error` tape entry; the chain dies; no
cascading effect (the platform doesn't auto-retry). Customer
composes retries via `retry.js` or by writing failures to a
recovery kv prefix that another subscription drains.

**Catch-up after downtime.** A cron schedule that "should have
fired" while the cluster was down: on leader election, fire ONCE
(the schedule's most-recent missed slot) then resume normal
cadence. Missed slots beyond the most-recent are dropped — same
"notify, don't replay" posture as §7/§10.1. Customers who need
exhaustive backfill compose via boot + kv-list of work pending.

**No filter-function kv-wakes.** Predicate filters stay rejected
(`streaming-handlers-plan.md` §4.6 + `primitive-gaps.md` §4) — a
subscription matches by prefix, then the handler can filter
post-wake.

---

## 8. Phased build

Each phase keeps build clean + all unit tests + all 9 streaming
smokes + heldsync_smoke green.

### Phase A — `SubscriptionEntry` types + snapshot field

Define `SubscriptionEntry` + `Spec` union in `globals.zig` next to
`TriggerEntry`. Add `subscriptions: []const SubscriptionEntry` to
the `TenantFilesSnapshot`. Empty default. Build clean; no behavior
change.

### Phase B — Deploy-time discovery

In `worker.zig`'s snapshot-build loop (the same loop that builds
`triggers_slice`), scan for `_subscriptions/<name>/spec.json`
manifest entries; pair each with `_subscriptions/<name>/index.mjs`;
parse the spec JSON; populate `subscriptions`. Validation
errors (missing handler, bad JSON, unknown kind) fail the deploy
with a logged error.

### Phase C — `fireSubscriptionActivation` + `.subscription_fire` enum

Add the activation-source variant. Implement
`fireSubscriptionActivation` (synthesize request, run handler,
apply effects, no flush). Plumb a new Request field
`activation_subscription: ?SubscriptionFireInfo` and surface it as
`request.activation = { kind: "subscription_fire", name, source: ... }`
via globals.zig.

Cmd vocabulary: terminal Response is the no-flush case; `__rove_next`
and `__rove_stream` from a subscription origin work via the
existing park/resume engines (the existing entity-component
machinery handles a no-socket chain; the held entity stays in a
worker-owned `parked_continuations` or `stream_*` collection
without an h2 stream backing it).

Actually that last paragraph is a real design question — h2's
stream pipeline collections currently presume an h2 stream
identity exists. A subscription chain may not have one. Verify
the existing collections tolerate a "no h2 stream" entity, OR
introduce a worker-owned mirror collection for chain-without-socket
chains. Resolved at implementation time.

### Phase D — Boot firing

In `worker.zig` snapshot swap, after `slot.current.swap(...)`,
walk new_snap subscriptions for `.boot` kind. For each, check
`_boot_fired/{deployment_id}` marker; if absent, fire
activation + write the marker on success.

### Phase E — kv-react firing (leader-only)

In `apply.zig`'s `applyWriteSet` (or its leader-side mirror in
`worker_dispatch.zig`), scan the tenant's subscriptions for `.kv`
kind whose prefix matches each writeset key. Fire only if
`node.is_leader()`. Each match fires
`fireSubscriptionActivation` with the kv source payload.

### Phase F — cron firing via internal http.send

Cron subscriptions arm a self-rescheduling internal
`http.send`-like row. Deploy-time arms the initial fire; the
handler's apply phase re-arms the next fire.

The cleanest path: introduce a new `_send/owed/<id>` flavor with
a marker indicating "this is a subscription fire, not an HTTP
call." SendDispatch routes flavor=subscription to
`fireSubscriptionActivation` instead of curl.

### Phase G — Smokes

Three smokes (one per kind):
- `streaming_subscription_boot_smoke.py` — deploy fires boot
  once; redeploy fires it again; restart-without-redeploy does
  NOT re-fire.
- `streaming_subscription_kv_smoke.py` — kv write under watched
  prefix fires a subscription handler that writes a marker; only
  the leader fires (followers see no marker write); tenant
  scoping verified.
- `streaming_subscription_cron_smoke.py` — short-interval cron
  fires N times over a window; leader change preserves cron
  (the schedule rides raft).

### Phase H — Docs + framing

Update `primitive-gaps.md` §2.1 status to DONE. Update
`streaming-handlers-plan.md` §5 to reference the implementation
venue. Memory pointer.

---

## 10. Phase status (2026-05-20)

| Phase | What | Status |
|---|---|---|
| A | `SubscriptionEntry` + `Spec` tagged-union on TenantFilesSnapshot | **shipped** |
| B | `discoverSubscriptions` deploy-time scan of `_subscriptions/<name>/{spec.json,index.mjs}` pairs | **shipped** |
| C | `.subscription_fire` enum + Request fields + `fireSubscriptionActivation` + JS surface | **shipped** |
| D | boot firing on snapshot swap | **stub** — loader thread has no worker context; needs handoff design |
| E | kv-react firing via apply-time hook (`firePendingKvWakes` → deferred-drain queue) | **shipped** |
| F | cron firing | **deferred** — Zig duration parser + worker-tick sweep, or SendDispatch ride |
| G | smokes — boot ✗, kv ✓ (`streaming_subscription_kv_smoke.py`), cron ✗ | **partial (kv only)** |
| H | docs + framing | **partial (this update)** |

**Phase E load-bearing detail:** the kv-react fire site
(`fireKvReactSubscriptions`, called from `firePendingKvWakes` in
`drainRaftPending`) cannot fire directly because
`fireSubscriptionActivation`'s recursive dispatch appends to
`worker.pending_units` and invalidates the loop's
pointer-into-items iteration. Fires queue onto
`worker.pending_subscription_fires` and drain at the END of
`drainRaftPending`. Caught by the first smoke run as a General
Protection Exception in `unit.deinit`.

---

## 9. Out of scope (v1)

- **Mutable-at-runtime subscriptions.** Customer can't add/remove
  subscriptions without re-deploying. Lift later if customer pull
  appears.
- **Cron expressions richer than crontab.** v1 is crontab strings
  (already exposed via `cron.js` for the http.send self-reschedule
  pattern). Sub-second cadence is rejected at deploy time.
- **Predicate-filter kv-react.** Locked rejection per
  `streaming-handlers-plan.md` §4.6.
- **Cross-tenant kv-react.** A tenant's subscriptions watch their
  own writes only.
- **Reliable exactly-once cron firing across leader changes.** The
  catch-up posture (§7) is "fire once for the most-recent missed
  slot, no backfill" — same notify-don't-replay thesis.
