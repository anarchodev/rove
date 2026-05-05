# Webhook-server plan — consolidated, raft-backed delivery subsystem

This document expands `docs/PLAN.md` §2.6 (Webhooks/outbox) and
Phase 5.5 item 4 (Centralized webhook subsystem) into an
implementable plan. It promotes PLAN's "leader-local
`_webhooks.db` in v1, raft-replicate later" decision to **raft-
replicated from day one** because the user's north-star is keeping
the worker kv path fast and consistent — and a leader-local
webhook db forces a recovery scan across every tenant's app.db on
leader change, which is exactly the per-tenant scan cost we're
trying to eliminate.

The motivating framing:

- **Webhooks need strong durability + consistency.** Once a customer's
  `webhook.send()` returns, the platform owes "delivered or terminally
  failed with a callback." This guarantee can't lean on best-effort
  storage.
- **Per-tenant outbox alone forces 10k-SQLite-scans-per-tick at
  scale.** Today's drainer scans every tenant's `_outbox/*` every
  tick, mostly empty. Doesn't scale.
- **Consolidated webhook state, raft-replicated.** A single
  `webhooks.db` (cluster-wide, not per-tenant) holds every pending
  webhook across every tenant, replicated through raft so any node
  can become webhook-leader on failover with zero scan cost.
- **Per-tenant `_outbox/` is the transactional handoff point only.**
  It exists for the brief window between handler commit and
  handoff-to-webhook-server. Steady-state, customer's app.db carries
  no webhook state.

What stays from today: the JS API (`webhook.send`), the
X-Rove-Webhook-Id at-least-once contract, the `onResult` handler
dispatch from `_callback/{id}` rows, the SSRF guards. What changes:
the storage layer for in-flight webhooks (per-tenant → consolidated)
and the delivery loop's location (worker drainer thread → dedicated
webhook-server process).

---

## 1. Architecture

```
┌──────────────────┐  customer handler runs:           ┌──────────────────────────────┐
│      worker      │  TrackedTxn writes:               │  raft cluster                │
│                  │    customer kv ops                │  (existing — single cluster, │
│                  │    _outbox/{webhook_id}           │   new envelope types added)  │
│                  │  raft commit (envelope 0) ───────▶│                              │
│                  │                                    │  envelope types:             │
│                  │  POST /v1/accept                   │   0: customer kv writeset    │
│                  │  to webhook-server  ───────┐       │   2: root kv writeset        │
└──────────────────┘                            │       │   4: webhook_enqueue (NEW)   │
       ▲                                         │       │   5: webhook_complete (NEW)  │
       │                                         ▼       └──────────────────────────────┘
       │                            ┌──────────────────────┐         │
       │                            │  webhook-server      │         │ apply on every node
       │                            │  - HTTP listener     │         ▼
       │ raft apply of              │  - raft proposer     │  ┌─────────────────────────┐
       │ envelope 5 also            │  - delivery loop     │  │  data_dir/webhooks.db   │
       │ writes _callback/          │    (leader only)     │  │  cluster-wide,          │
       │ deletes _outbox/           │                      │  │  raft-applied,          │
       │ in tenant's app.db         └──────────┬───────────┘  │  consistent across      │
       │                                       │              │  every node             │
       │                                       │ POST customer URL│                     │
       │                                       │ (X-Rove-Webhook-Id)                    │
       │                                       ▼              │  rows:                  │
       │                            ┌─────────────────────┐   │  pending/{id}           │
       │                            │ customer's webhook  │   │  inflight/{id}          │
       │                            │ receiver            │   │  delivered/{id}         │
       │                            └─────────────────────┘   │  failed/{id}            │
       │                                                       └─────────────────────────┘
       │                                                                 ▲
       │                                                                 │ apply hooks
       └─────────────────────────────────────────────────────────────────┘
                                                              (envelopes 4 + 5
                                                               update webhooks.db
                                                               AND tenant app.db
                                                               atomically in one
                                                               raft commit)
```

Three flow paths:

1. **Handoff (worker → webhook-server → raft):** worker fires POST
   to webhook-server; webhook-server proposes envelope 4
   (`webhook_enqueue`); raft commits + applies; webhook-server returns
   204 to worker.
2. **Cleanup (worker → raft, optional):** worker writes a kv delete on
   `_outbox/{id}` after receiving 204. Optional because the
   `webhook_complete` apply (path 3) also deletes `_outbox/{id}` —
   the explicit cleanup is just a fast-path so steady state has the
   row gone in milliseconds rather than seconds.
3. **Completion (webhook-server → raft):** webhook-server's delivery
   loop attempts the customer URL; on terminal outcome it proposes
   envelope 5 (`webhook_complete`) carrying tenant_id + webhook_id +
   outcome + result. Apply on every node atomically:
   - removes the row from `webhooks.db`
   - writes `_callback/{id}` into tenant's `app.db`
   - deletes `_outbox/{id}` from tenant's `app.db` (idempotent if
     worker already deleted it)
   The customer's existing `dispatchCallbacks` worker phase fires the
   `onResult` handler from the `_callback/` row.

**The drainer becomes a tiny safety net.** Its only job is "did
some `_outbox/{id}` row exist for more than N seconds without a
matching `webhooks.db` entry?" If so, the worker crashed before its
POST to webhook-server completed; re-POST. webhook-server's
idempotency check (envelope 4 with same webhook_id is a no-op if
already enqueued) handles dupes safely.

---

## 2. Data model

### 2.1 What persists where

| Data | Where | Lifetime | Why |
|---|---|---|---|
| `_outbox/{id}` | tenant `app.db`, envelope 0 | ms (steady state); seconds-to-minutes if webhook-server lags | Transactional with kv writes; transient handoff |
| `webhooks.db` rows | cluster-wide `data_dir/webhooks.db`, envelopes 4+5 | Until delivered or terminally failed | Consolidated authoritative state, raft-replicated |
| `_callback/{id}` | tenant `app.db`, envelope 5 | Until customer's `onResult` runs and worker deletes | Triggers customer onResult dispatch |

`webhooks.db` is **cluster-wide** — one file per node, all replicated
to identical state via raft. Workers don't open `webhooks.db`
directly; only the apply path writes it (via raft envelope apply)
and the webhook-server's delivery loop reads it.

### 2.2 `webhooks.db` schema

```sql
CREATE TABLE webhooks (
    webhook_id        TEXT PRIMARY KEY,    -- 64-hex
    tenant_id         TEXT NOT NULL,
    state             TEXT NOT NULL,       -- 'pending' | 'inflight' | 'failed_pending_callback'
    url               TEXT NOT NULL,
    method            TEXT NOT NULL,
    headers_json      TEXT NOT NULL,
    body              BLOB NOT NULL,
    max_attempts      INTEGER NOT NULL,
    timeout_ms        INTEGER NOT NULL,
    retry_on_json     TEXT NOT NULL,
    context_json      TEXT NOT NULL,       -- round-trips to onResult
    on_result_path    TEXT NOT NULL,
    enqueued_at_ns    INTEGER NOT NULL,
    next_attempt_at_ns INTEGER NOT NULL,
    attempts          INTEGER NOT NULL DEFAULT 0,
    inflight_lease_ns INTEGER,             -- leader's lease expiry; NULL when not inflight
    inflight_leader_term INTEGER           -- leader term that took the lease
);
CREATE INDEX webhooks_ready ON webhooks (state, next_attempt_at_ns)
    WHERE state = 'pending';
CREATE INDEX webhooks_tenant ON webhooks (tenant_id);
```

The `inflight_lease_ns` + `inflight_leader_term` columns let the
delivery loop take a lease before attempting (so a leader-failover
mid-delivery doesn't double-fire). Lease duration = max delivery
timeout × small fudge factor.

### 2.3 New raft envelope types

**Type 4: `webhook_enqueue`**

Payload (after the type byte + standard envelope header):

```
{
  "v": 1,
  "webhook_id": "<64-hex>",
  "tenant_id": "acme",
  "url": "...",
  "method": "POST",
  "headers": { ... },
  "body": "<base64-or-binary>",
  "max_attempts": 10,
  "timeout_ms": 30000,
  "retry_on": [...],
  "context": { ... },
  "on_result_path": "stripe/charge_result",
  "enqueued_at_ns": 1730764800000000000
}
```

Apply on every node: `INSERT OR IGNORE INTO webhooks (...) VALUES (...)`
into `webhooks.db`. The `OR IGNORE` makes the apply idempotent — a
duplicate envelope (e.g., from a re-fire after restart) is a no-op.
Initial state = 'pending', `next_attempt_at_ns` = `enqueued_at_ns`.

**Type 5: `webhook_complete`**

Payload:

```
{
  "v": 1,
  "webhook_id": "<64-hex>",
  "tenant_id": "acme",
  "outcome": "delivered",        // "delivered" | "failed"
  "attempts": 3,
  "response": {
    "status": 200,
    "headers": { ... },
    "body": "<truncated>"
  }
}
```

Apply on every node, in one SQLite transaction across BOTH
`webhooks.db` AND tenant's `app.db`:

1. `DELETE FROM webhooks WHERE webhook_id = ?` (in `webhooks.db`)
2. `INSERT OR REPLACE INTO kv (key, value) VALUES ('_callback/{id}', serialize(result))` (in tenant `app.db`)
3. `DELETE FROM kv WHERE key = '_outbox/{id}'` (in tenant `app.db`,
   idempotent — usually already deleted)

The cross-db atomicity is fine because both are local-file SQLite
opens on the same node; the apply uses ATTACH or just sequential
commits with a try-except wrapper to roll back. (Pure SQLite
multi-db transaction support via ATTACH gives single-tx semantics.)

### 2.4 Per-tenant `_outbox/{id}` shape

Unchanged from today. The row exists as the transactional handoff;
its content mirrors what gets serialized into the type 4 envelope.

---

## 3. Worker integration

### 3.1 webhook.send binding (unchanged)

Customer's JS handler calls `webhook.send({...})` exactly as today.
Binding builds the outbox row and appends to TrackedTxn.

### 3.2 New worker phase: pumpWebhooksForResponse

After kv commit confirms (raft commit, envelope 0), scan the writeset
for newly-written `_outbox/*` keys. For each:

```
fire-and-forget POST to webhook-server /v1/accept:
  body = serialize(outbox_row)
  timeout = 1s
on response:
  204:    log success; optionally fire a follow-up kv writeset to
          delete _outbox/{id} (fast-path cleanup; not strictly needed
          since envelope 5 apply also deletes it)
  4xx/5xx/timeout: log; do nothing — drainer will retry
```

Implementation: per-worker h2 client connection to webhook-server,
parking the POST in a `webhook_emit_pending` queue (mirrors the SSE
emit POST pattern). Worker's tick drains the queue independently of
request response timing.

**Worker never blocks the customer's response on the webhook-server
POST.**

### 3.3 Drainer simplification

The current `src/outbox/drainer.zig` does heavy work: scans every
tenant's `app.db` every tick, makes HTTP calls, computes retries,
writes results. After this change:

- Drainer no longer makes HTTP calls. webhook-server owns delivery.
- Drainer no longer computes retry timing. webhook-server owns the
  schedule.
- Drainer's only job: periodic scan of `_outbox/*` rows older than
  threshold (~5s — longer than worker→webhook-server round trip).
  For each: re-POST to webhook-server `/v1/accept`. Idempotent
  envelope 4 apply makes this safe.
- Optional further optimization: maintain a leader-local index of
  "tenants with non-zero outbox count" so the drainer scans only
  active tenants. Adds an apply hook to maintain the index. Defer
  unless the unbounded scan starts costing.

### 3.4 What about workers vs webhook-server geometry?

**Workers** are stateless wrt webhooks beyond firing the accept POST
and apply path. Run on every node.

**Webhook-server** is one process per cluster (with HA via active-
backup LB later). It owns the delivery loop. The leader of the
delivery loop is whichever webhook-server replica currently holds
the inflight lease for each row — naturally serialized via the
lease columns in `webhooks.db`.

Worker's accept POST can land on any webhook-server replica (LB
round-robins). The replica that received it proposes envelope 4 to
the raft leader (raft handles forwarding if not the leader). Apply
hits every node's `webhooks.db`.

Webhook-server's delivery loop runs on whichever replica is willing
to take the lease. With single replica, that's just "the one process";
with multi-replica, the active-backup LB or a simple lease lottery
picks one.

---

## 4. Webhook-server

New module: `src/webhook_server/`. Single process per cluster (in
v1; multi-replica with leader election later for HA).

### 4.1 Process model

- **Internal-only listener.** No public TLS, no public subdomain.
  Workers POST to it via shared-secret auth on a private-network
  address (or loopback if co-located).
- **Raft proposer.** Webhook-server uses the same raft cluster as
  the rest of the system; proposes envelopes 4 and 5 like any other
  proposer. (Raft doesn't care which process the proposer is.)
- **Outbound HTTPS client** for delivery. Reuses
  `src/outbox/ssrf.zig` guards.
- **Reads `webhooks.db`** to drive the delivery loop. Writes only via
  envelope proposals (which apply through raft, like every other
  write to a raft-replicated db).

### 4.2 Routes

```
POST /v1/accept          ← worker → webhook-server (immediate enqueue)
GET  /v1/health          ← LB health check
```

No public surface; no per-tenant routing. The only customer-visible
HTTP traffic is webhook-server's outbound POSTs to customer URLs.

### 4.3 Accept flow

```
on POST /v1/accept:
  validate internal token
  parse body → outbox_row
  build envelope 4 (webhook_enqueue) from outbox_row
  propose envelope 4 through raft
  on raft commit:
    return 204
  on raft propose failure:
    return 503 (worker logs; drainer will retry)
```

### 4.4 Delivery loop

```
loop forever:
  query webhooks.db:
    SELECT * FROM webhooks
    WHERE state = 'pending' AND next_attempt_at_ns <= now()
    ORDER BY next_attempt_at_ns
    LIMIT N

  for each row:
    take lease: propose a small "lease" envelope
                (or update inflight_lease_ns inline via envelope 5 variant)
    [v1: simpler — single replica, lease is just an in-memory mark]

    POST row.url with row.method, row.headers + X-Rove-Webhook-Id,
         row.body, timeout = row.timeout_ms

    if 2xx:
      propose envelope 5 (webhook_complete, outcome=delivered)
      → raft commits → apply on every node (removes from webhooks.db,
         writes _callback/, deletes _outbox/)
    elif retryable AND attempts+1 < max_attempts:
      compute next_attempt_at_ns = now + backoff
      propose envelope 5b "webhook_retry_schedule" (or update via 4 variant)
      → raft commits → apply updates the row's attempts + next_attempt_at_ns
    else (terminal failure):
      propose envelope 5 (webhook_complete, outcome=failed)

  if no rows ready: sleep until next deadline or wakeup signal
```

The "envelope 5b" for retry-schedule could either be a third type or
a discriminated variant of envelope 5. Slight schema choice; either
works. Probably make it envelope 6 = `webhook_retry_schedule` for
clarity.

### 4.5 Multi-replica considerations (v2)

V1: single webhook-server process. The delivery loop has no
contention because only one process is reading `webhooks.db` for
delivery purposes.

V2: multiple webhook-server replicas behind active-backup LB. The
lease columns (`inflight_lease_ns`, `inflight_leader_term`) prevent
double-fire — a replica only takes a row whose lease is expired or
absent, and proposes a "lease taken" envelope before attempting
delivery. If the proposing replica dies mid-delivery, the lease
expires, another replica picks up.

Defer the lease envelope and multi-replica logic to v2.

### 4.6 Backpressure / pacing

Per-instance `webhook_attempt` rate limit (PLAN §2.10) moves from
the drainer to webhook-server's delivery loop — same token bucket,
checked before each POST attempt. Tenant exceeding budget gets its
row deferred (`next_attempt_at_ns` = now + 1s).

Per-destination-URL rate-limit / circuit-breaker is a v2 feature
(PLAN §8.5 in webhook-server-plan original).

### 4.7 Crash recovery

Webhook-server crashes → restart on any node. New process opens
`webhooks.db`, sees all pending rows (raft has them durably). Resumes
delivery loop from `WHERE state = 'pending'`. **Zero scan of tenant
app.db needed** — the consolidated `webhooks.db` IS the recovery
state.

This is the entire reason the user pushed for raft-replicated
webhook-server: leader/process failover is O(1) instead of
O(num_tenants).

---

## 5. Authentication

### 5.1 Worker → webhook-server

Static shared secret in env: `WEBHOOK_INTERNAL_TOKEN`. Set
identically on workers and webhook-server. Sent as
`Authorization: Bearer <token>` on every POST. Rotated by restarting
both with a new value. mTLS is the future upgrade.

### 5.2 Webhook-server → customer URL

Existing semantics:
- Customer-supplied URL + headers go out as-is (subject to SSRF
  guards).
- Adds `X-Rove-Webhook-Id: <webhook_id>` for receiver dedup.
- Adds `X-Rove-Webhook-Attempt: <n>` for receiver visibility.
- Strips any customer-supplied `X-Rove-Webhook-*` headers.

No change.

---

## 6. What gets removed / changed

### 6.1 Removed

- The drainer's HTTP delivery code path. Webhook-server owns all
  HTTP-out.
- The drainer's retry-timing logic. Webhook-server owns the
  schedule.
- The `_outbox_inflight/{id}` lease pattern in tenant app.db.
  Replaced by `inflight_lease_ns` columns in `webhooks.db`.
- The drainer's per-tenant SQLite-open-and-scan-all-tenants pattern.
  Drainer becomes a thin re-POST-orphan loop.

### 6.2 Changed

- `src/outbox/drainer.zig` shrinks to ~50-100 lines: periodic scan
  of `_outbox/*` rows older than threshold, re-POST to webhook-server.
- `webhook.send` JS binding: unchanged.
- Customer's `onResult` handler dispatch: unchanged (fired from
  `_callback/{id}` rows, written by envelope 5 apply).
- `src/js/apply.zig` gains `applyWebhookEnqueue` and
  `applyWebhookComplete` for envelopes 4 and 5 (and 6 for retry-
  schedule).

### 6.3 Added

- `src/webhook_server/` module — internal HTTP listener + delivery
  loop + raft proposer.
- New raft envelope types 4 (enqueue), 5 (complete), 6 (retry-
  schedule).
- New cluster-wide SQLite db: `data_dir/webhooks.db`. Initialized at
  cluster bootstrap; opened by every node's apply path; opened by
  webhook-server's delivery loop for reads.
- `WEBHOOK_INTERNAL_TOKEN`, `WEBHOOK_SERVER_ADDR` env config.

---

## 7. Migration order

Each step independently shippable + smoke-testable.

1. **Add `webhooks.db` schema + envelope types 4/5/6 to apply path.**
   Default behavior unchanged because nothing proposes them yet.
   Smoke: hand-craft an envelope 4, observe the row appears in
   `webhooks.db` on every node.
2. **Build webhook-server skeleton** (HTTP listener, raft proposer
   wiring, no delivery loop yet). Smoke: POST /v1/accept → envelope
   4 proposed → row appears.
3. **Build the delivery loop in webhook-server.** Reads `webhooks.db`,
   POSTs customer URLs, proposes envelope 5 on completion. Smoke:
   end-to-end accept → deliver → callback row appears.
4. **Add `pumpWebhooksForResponse` to worker** behind feature flag
   (`webhook.deliver_via = drainer | service`). Default `drainer`.
   Workers fire the POST in parallel with drainer behavior; validate
   webhook-server delivery matches drainer outcome.
5. **Switch worker default to `service`.** Drainer becomes the
   safety net; webhook-server is the primary path.
6. **Trim the drainer** to the safety-net role (re-POST orphans
   only).
7. **Drop `_outbox_inflight/{id}` lease pattern.** Webhook-server's
   `inflight_lease_ns` replaces it.
8. **Drop the feature flag.** `service` is the only path.

Smokes:
- Existing webhook smoke runs through the new path end-to-end.
- New smoke: webhook-server killed mid-delivery → restart → continues
  from `webhooks.db` state without scanning any tenant app.db.
- New smoke: worker crash between handler commit and accept-POST →
  drainer's next pass enqueues via webhook-server → delivery
  completes.
- New smoke: cluster failover during delivery → new leader's
  webhook-server picks up `webhooks.db` state and continues delivery.

---

## 8. Open questions / deferred

### 8.1 Cross-db atomicity in envelope 5 apply

Envelope 5 apply touches both `webhooks.db` and tenant's `app.db`
in one logical transaction. SQLite supports this via ATTACH
(`ATTACH 'app.db' AS tenant_db; BEGIN; UPDATE webhooks ...; UPDATE tenant_db.kv ...; COMMIT;`)
but ATTACH has caveats around journal mode interaction. Verify
during implementation that ATTACH+WAL works correctly across both
attached dbs. Fallback: sequential commits with idempotent retry
on partial failure (`webhooks.db` delete first; if tenant app.db
write fails, the next apply attempt retries from the still-present
state — but envelope 5 apply needs to be idempotent, which it is
if `_callback/{id}` insert uses INSERT OR REPLACE).

### 8.2 webhook-server HA via raft-aware leader election

V1: single webhook-server process, restart-on-crash. Acceptable
because `webhooks.db` is durable and recovery is O(1).

V2: multiple replicas with the lease-based delivery contention
described in §4.5. Or simpler: pin webhook-server to the raft leader
(election handled implicitly by following the raft leader). The
latter is operationally simplest — no separate election protocol —
but ties webhook delivery to raft-leader liveness.

### 8.3 Backfill / schema migration for `webhooks.db`

When the new code rolls out, `webhooks.db` doesn't exist yet on any
node. First worker startup needs to create it and apply schema. Not
hard; flag as one of the "first-time bootstrap" tasks.

### 8.4 webhooks.db growth + retention

Delivered webhooks are deleted on envelope 5 apply. Failed webhooks
might want to stick around for an audit window before deletion (so
operators can inspect "what failed and why"). Flag for v2 — for v1,
delete on terminal outcome.

### 8.5 Customer-facing outbox visibility

Today customers can't easily inspect their pending webhooks. With
consolidated `webhooks.db`, the admin UI could expose a "pending
webhooks" view per tenant via a query into `webhooks.db`. Punt for
now; flag as future-admin-UI feature.

### 8.6 Per-destination circuit breaker

Per-customer-URL circuit-breaker (back off entirely from a
consistently-failing destination instead of pounding it with
retries) is a real production concern. V2 knob; defer.

### 8.7 Inbound webhooks

Out of scope for this plan. Inbound webhooks are normal HTTP requests
to customer worker subdomains.
