# Webhook-server plan — consolidated, raft-backed delivery subsystem

This document expands `docs/PLAN.md` §2.6 (Webhooks) and Phase 5.5
item 4 (Centralized webhook subsystem) into an implementable plan.

The motivating framing:

- **Webhooks need strong durability + consistency.** Once a customer's
  `webhook.send()` returns, the platform owes "delivered or
  terminally failed with a callback." This guarantee can't lean on
  best-effort storage.
- **Per-tenant outbox + drainer doesn't scale.** Today's drainer
  scans every tenant's `_outbox/*` every tick, mostly empty. At 10k
  tenants that's ~40k SQLite open+scan ops/sec.
- **Consolidated webhook state, raft-replicated.** A single
  `webhooks.db` (cluster-wide, not per-tenant) holds every pending
  webhook across every tenant, replicated through raft so any node
  can become webhook-leader on failover with zero scan cost.
- **No per-tenant `_outbox/` row at all.** The customer handler's
  `webhook.send` calls accumulate in the dispatcher's per-handler
  state (alongside the writeset). At commit time the dispatcher
  proposes the writeset envelope AND the webhook-enqueue envelope
  in **the same raft entry**, so by the time the customer response
  returns (gated on raft commit), webhooks.db already holds the
  pending row durably across the cluster. There is nothing to
  recover, nothing to drain, nothing to forward.

What stays from today: the JS API (`webhook.send`), the
X-Rove-Webhook-Id at-least-once contract, the `onResult` handler
dispatch from `_callback/{id}` rows, the SSRF guards. What changes:
in-flight webhook state moves from per-tenant `_outbox/*` to
cluster-wide `webhooks.db`; the delivery loop moves from the
worker's drainer thread to a leader-pinned webhook-server thread;
the drainer goes away entirely.

---

## 1. Architecture

**Webhook-server is a leader-pinned thread inside the loop46 binary,
NOT a separate process.** Unlike files-server / log-server /
sse-service — which can be separate processes (and even separate
machines) because their state lives in S3 and they don't participate
in raft — webhook-server **does** participate in raft: it reads
`webhooks.db` (raft-replicated), proposes envelopes 5/6, and is
leader-pinned by definition. Crossing a process boundary would
force RPC for raft proposes, file-share or learner-replication for
`webhooks.db` access, and would re-introduce the very plumbing the
consolidation was supposed to eliminate.

The architectural rule that emerges and is worth carrying forward
to other future subsystems:

> **Subsystems that participate in raft live in the loop46 binary.
> Subsystems that don't can be split into their own processes /
> machines.**

The thread runs **only on the raft leader**, guaranteeing a single
delivery loop per cluster without any election protocol of its own.
Leader failover starts the thread on the new leader's loop46
binary; it opens the local `webhooks.db` (already populated via
raft replication) and resumes processing.

```
┌─── leader node — loop46 binary ────────────────────────────────────┐
│                                                                    │
│  ┌──────────────┐    customer handler runs                         │
│  │   worker     │    TrackedTxn accumulates writeset               │
│  │   thread(s)  │    webhook.send() accumulates webhook batch      │
│  │              │    on commit: propose ONE raft entry             │
│  │              │      = envelope 0 (writeset)                     │
│  │              │      + envelope 4 (webhook_enqueue batch)        │
│  │              │    response returned after raft commit           │
│  └──────────────┘                                                  │
│                                                                    │
│              raft apply hooks ▼                                    │
│              ┌─────────────────────────────┐                       │
│              │ tenant app.db (envelope 0)  │                       │
│              │ data_dir/webhooks.db        │                       │
│              │   (envelope 4 INSERT)       │                       │
│              └─────────────────────────────┘                       │
│                       ▲                                            │
│                       │ envelope 5/6 proposed by webhook-server    │
│  ┌─────────────────────────────────┐                               │
│  │ webhook-server thread           │ reads webhooks.db             │
│  │  (leader-pinned)                │ POSTs customer URLs           │
│  │  - delivery loop                │ proposes envelope 5 on done   │
│  │  - retry scheduler              │ proposes envelope 6 on retry  │
│  │  - raft proposer (local)        │                               │
│  └─────────────────────────────────┘                               │
│                       │ POST customer URL                          │
│                       ▼                                            │
│              ┌─────────────────────┐                               │
│              │ customer's webhook  │                               │
│              │ receiver            │                               │
│              └─────────────────────┘                               │
│                                                                    │
│  (Other subsystems that DON'T participate in raft —                │
│   rove-files-server, rove-log-server, rove-sse-service —           │
│   are separate processes/binaries; can be on the same node         │
│   or on entirely different machines.)                              │
└────────────────────────────────────────────────────────────────────┘
                                  │ raft replication
                                  ▼
┌─── follower node — loop46 binary ──────────────────────────────────┐
│  - no public listeners (leader-only takes requests)                │
│  - no worker threads serving customer traffic                      │
│  - webhook-server thread present but IDLE (no leader signal)       │
│  - apply hooks update local data_dir/webhooks.db via raft          │
│  - ready to assume leadership on raft election                     │
└────────────────────────────────────────────────────────────────────┘
```

Two flow paths:

1. **Enqueue (worker → raft):** the worker dispatcher accumulates
   `webhook.send` calls during handler execution into a per-handler
   list (parallel to the kv writeset). On savepoint release, the
   list moves into the batch's webhook accumulator. On batch
   commit, the dispatcher proposes a single raft entry carrying
   envelope 0 (merged writeset across handlers) AND envelope 4
   (webhook batch). Apply on every node is sequential within the
   entry: writeset to tenant app.db, then webhook-batch INSERT into
   `webhooks.db`. The customer response is gated on raft commit, so
   by the time the user sees the response, both writes are durable
   cluster-wide.
2. **Completion (webhook-server → raft → apply on every node):**
   webhook-server's delivery loop attempts the customer URL; on
   terminal outcome it proposes envelope 5 (`webhook_complete`)
   carrying tenant_id + webhook_id + outcome + result. Apply
   atomically:
   - removes the row from `webhooks.db`
   - writes `_callback/{id}` into tenant's `app.db`
   The customer's existing `dispatchCallbacks` worker phase fires
   the `onResult` handler from the `_callback/` row — running on
   the leader, since that's where workers run.

**There is no drainer.** No per-tenant scan, no orphan recovery, no
re-forward path. The propose IS the handoff.

---

## 2. Data model

### 2.1 What persists where

| Data | Where | Lifetime | Why |
|---|---|---|---|
| `webhooks.db` rows | cluster-wide `data_dir/webhooks.db`, envelopes 4/5/6 | Until delivered or terminally failed | Consolidated authoritative state, raft-replicated |
| `_callback/{id}` | tenant `app.db`, envelope 5 | Until customer's `onResult` runs and worker deletes | Triggers customer onResult dispatch |

Notable: **no `_outbox/{id}` in tenant app.db**, no
`_outbox_inflight/{id}`, no `_dlq/{id}`. Failed webhooks live in
`webhooks.db` as `state = 'failed_pending_callback'` until the
callback fires; the consolidated db replaces all three per-tenant
prefixes.

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
delivery loop detect stale leases across leader failover (the old
leader can't have completed delivery if it lost leadership before
its envelope-5 propose committed). Lease duration = max delivery
timeout × small fudge factor.

### 2.3 Multi-envelope raft entries

Today's raft entries carry one envelope each. To propose envelope 0
(writeset) + envelope 4 (webhook batch) atomically, the entry
payload becomes a length-prefixed sequence of envelopes:

```
entry payload := count:u8 || (envelope_type:u8 || envelope_len:u32 || envelope_bytes){count}
```

Apply iterates envelopes in order; each one routes to its target
DB (tenant app.db, webhooks.db, root.db, etc.) via the existing
type dispatch. A single follower transaction per target DB covers
the per-DB writes; cross-DB atomicity is via raft entry boundary
(both apply or neither does).

Backwards compat for callers that still propose a single envelope:
`count = 1` with the old envelope-bytes layout. The wire change is
adding the count prefix; existing single-envelope callers update to
write `count = 1`.

### 2.4 New raft envelope types

**Type 4: `webhook_enqueue_batch`**

Payload (after the type byte + standard envelope header) is a
length-prefixed sequence of webhook rows:

```
{
  "v": 1,
  "rows": [
    {
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
    },
    ...
  ]
}
```

Apply on every node: `INSERT OR IGNORE INTO webhooks (...)` for
each row, into `webhooks.db`. The `OR IGNORE` makes the apply
idempotent — a duplicate entry (e.g., from raft entry redelivery
during recovery) is a no-op. Initial state = `'pending'`,
`next_attempt_at_ns` = `enqueued_at_ns`.

Webhook ids are deterministic (`hash(request_id || call_index)`)
so replay of the same request produces the same id; idempotency
covers the rare cases where a raft entry gets re-applied.

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

Apply on every node, in one logical transaction across BOTH
`webhooks.db` AND tenant's `app.db`:

1. `DELETE FROM webhooks WHERE webhook_id = ?` (in `webhooks.db`)
2. `INSERT OR REPLACE INTO kv (key, value) VALUES ('_callback/{id}', serialize(result))` (in tenant `app.db`)

The cross-db atomicity uses ATTACH (`ATTACH 'app.db' AS tenant_db; BEGIN; UPDATE webhooks ...; UPDATE tenant_db.kv ...; COMMIT;`)
or sequential commits with idempotent retry on partial failure.
Envelope 5 apply is idempotent (DELETE is a no-op on missing row;
INSERT OR REPLACE on `_callback/{id}` is idempotent), so retry is
safe.

**Type 6: `webhook_retry_schedule`**

Payload:

```
{
  "v": 1,
  "webhook_id": "<64-hex>",
  "attempts": 2,
  "next_attempt_at_ns": 1730764920000000000
}
```

Apply: `UPDATE webhooks SET attempts = ?, next_attempt_at_ns = ?,
state = 'pending', inflight_lease_ns = NULL WHERE webhook_id = ?`.
Used by the delivery loop after a retryable failure to push the
row's next attempt into the future.

---

## 3. Worker integration

### 3.1 webhook.send binding

Customer's JS handler calls `webhook.send({...})` exactly as today.
Binding builds the outbox row and appends to a **per-handler
webhook accumulator** on the dispatch state, NOT to the kv
writeset. The accumulator is parallel to the writeset: each
contributes to the same final propose, but they live in distinct
data structures because their destinations are distinct
(tenant app.db vs webhooks.db).

### 3.2 Per-handler savepoint + commit

Within a per-tenant batch, each handler runs under a SAVEPOINT.
On successful release, both the handler's writeset rows AND its
webhook accumulator entries are merged into the batch's combined
state. On rollback (handler threw), both are discarded.

This means the abort case is structurally identical to today's
`_outbox/*` model: a handler that calls `webhook.send` and then
throws produces no committed kv writes AND no enqueued webhook,
because neither the writeset nor the webhook batch reached the
propose.

### 3.3 Combined propose at batch commit

After all handlers in the per-tenant batch have run, the dispatcher
proposes ONE raft entry carrying:

- envelope 0 = the merged kv writeset (all handlers' kv changes),
  which may be empty if no handler wrote
- envelope 4 = the merged webhook batch (all handlers' webhook
  enqueues), which may be empty if no handler called webhook.send

Empty envelopes are skipped — if the batch produced only kv writes,
only envelope 0 ships; if only webhook calls, only envelope 4. The
common mixed case ships both in one raft entry.

The customer-response gate is unchanged: response returns to the
user after raft commit. Because the entry is atomic, both the kv
writes and the webhook enqueues are durable cluster-wide by the
time the user sees a response.

### 3.4 What the worker does NOT do

- **No drainer.** No periodic scan of any kv prefix.
- **No `_outbox/{id}` writes.** Webhook state never lives in tenant
  app.db.
- **No HTTP delivery from worker.** webhook-server owns all outbound
  HTTP.
- **No retry timing.** webhook-server owns the schedule.
- **No `pumpWebhooksForResponse` phase.** The propose in §3.3 IS the
  handoff; nothing further is needed.

### 3.5 Callback dispatch (unchanged)

When envelope 5 applies (webhook completed), `_callback/{id}`
appears in the tenant's app.db. The existing `dispatchCallbacks`
worker phase reads `_callback/*` rows, runs the customer's
`onResult` handler in a fresh transaction, and deletes the row on
success. This path is unchanged.

---

## 4. Webhook-server

New module: `src/webhook_server/` inside the loop46 binary.
Leader-pinned thread spawned by the loop46 main loop on
leadership-acquired and stopped on leadership-lost. Single instance
per cluster guaranteed by raft leader uniqueness.

### 4.1 Process model

- **Same binary as the worker.** No new binary, no new operational
  artifact. Justified because webhook-server participates in raft
  (reads webhooks.db, proposes envelopes, leader-pinned by
  definition); separating across a process boundary would force
  RPC for proposes and file-share for webhooks.db reads.
- **No HTTP listener at all.** Webhook-server's only network
  presence is its outbound HTTPS client (for customer URL
  delivery).
- **No accept API for workers.** The worker proposes envelope 4
  directly via the local raft proposer; webhook-server learns of
  new rows by watching `webhooks.db` (or by being signalled from
  the apply path on envelope-4 commit).
- **Raft proposer.** Webhook-server proposes envelopes 5 and 6
  through the local raft node — same in-process raft client every
  other proposer uses.
- **Outbound HTTPS client** for delivery. Reuses the SSRF guards
  factored out of the old drainer.
- **Reads `webhooks.db`** directly via a local SQLite handle.
  Writes only via envelope proposals.

### 4.2 Apply-side wakeup

When envelope 4 applies on the leader, the apply path signals
webhook-server (a condvar / eventfd) so it doesn't have to poll.
Followers also apply envelope 4 but their webhook-server thread is
idle, so the wakeup is a no-op there.

### 4.3 Delivery loop

```
loop forever:
  query webhooks.db:
    SELECT * FROM webhooks
    WHERE state = 'pending' AND next_attempt_at_ns <= now()
    ORDER BY next_attempt_at_ns
    LIMIT N

  for each row:
    take lease (in-memory mark + propose-when-needed if multi-replica)

    POST row.url with row.method, row.headers + X-Rove-Webhook-Id,
         row.body, timeout = row.timeout_ms

    if 2xx:
      propose envelope 5 (webhook_complete, outcome=delivered)
      → raft commits → apply removes from webhooks.db,
                       writes _callback/ to tenant app.db
    elif retryable AND attempts+1 < max_attempts:
      compute next_attempt_at_ns = now + backoff
      propose envelope 6 (webhook_retry_schedule)
      → raft commits → apply updates row's attempts + next_attempt_at_ns
    else (terminal failure):
      propose envelope 5 (webhook_complete, outcome=failed)

  if no rows ready: wait on apply-side wakeup or next deadline
```

### 4.4 Failover via raft leader change

Because webhook-server is a leader-pinned thread, "failover" is just
"the raft leader changed." The previous leader's webhook-server
thread shuts down (it sees the leadership-loss signal); the new
leader's webhook-server thread starts (it sees the
leadership-acquired signal). The new thread opens the local
`webhooks.db` (already in sync via raft replication) and resumes
processing.

The lease columns (`inflight_lease_ns`, `inflight_leader_term`)
remain useful for one specific case: a row was being delivered when
the old leader lost leadership. The new leader's first sweep
checks the lease — if `inflight_leader_term < current_term`, the
lease is stale (the old leader can't have completed delivery
because it lost leadership before that propose-cycle). Treat as
unleased and re-attempt. The customer URL receives a duplicate
delivery; X-Rove-Webhook-Id dedup contract handles it.

### 4.5 Backpressure / pacing

Per-instance `webhook_attempt` rate limit (PLAN §2.10) lives in
webhook-server's delivery loop — same token bucket, checked before
each POST attempt. Tenant exceeding budget gets its row deferred
(`next_attempt_at_ns` = now + 1s).

Per-destination-URL rate-limit / circuit-breaker is a v2 feature.

### 4.6 Crash recovery

The loop46 process crashing on the leader → raft elects a new
leader → the new leader's loop46 process spawns the webhook-server
thread → that thread opens `webhooks.db` (durable on local disk,
in-sync via raft) and sees all pending rows → resumes delivery
loop from `WHERE state = 'pending'`. **Zero scan of tenant app.db
needed** — the consolidated `webhooks.db` IS the recovery state.

Worker-side crash recovery is also trivial: any in-flight webhook
batch that didn't reach raft propose is lost along with the
handler's writeset. The customer either saw an error response (and
will retry) or never sees a response at all (request died with the
worker). Either way, no half-committed state on the platform side.

---

## 5. Authentication

### 5.1 Worker → webhook-server

No auth needed. There is no worker → webhook-server call. Workers
propose envelope 4 directly via the local raft proposer; webhook-
server reads from the locally-applied `webhooks.db`.

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

- **`src/outbox/drainer.zig` entirely.** No replacement. There is
  nothing to drain.
- The per-tenant `_outbox/{id}` storage shape. No row ever exists
  in tenant app.db.
- The `_outbox_inflight/{id}` lease pattern. Replaced by
  `inflight_lease_ns` columns in `webhooks.db`.
- The drainer's HTTP delivery code path. webhook-server owns all
  HTTP-out.
- The drainer's retry-timing logic. webhook-server owns the schedule.
- The `_dlq/{id}` per-tenant prefix. Failed webhooks live in
  `webhooks.db` as `state = 'failed_pending_callback'` until the
  callback fires.

### 6.2 Changed

- `webhook.send` JS binding: appends to a per-handler webhook
  accumulator on the dispatch state, not to the kv writeset.
- The dispatcher's batch-commit path: proposes a single raft entry
  carrying envelope 0 (writeset) + envelope 4 (webhook batch)
  together, instead of two separate proposes.
- Raft entry payload shape: now a length-prefixed sequence of
  envelopes (count = 1 for the existing single-envelope cases).
- `src/js/apply.zig` gains `applyWebhookEnqueueBatch`,
  `applyWebhookComplete`, `applyWebhookRetrySchedule` for envelopes
  4/5/6, plus the multi-envelope-per-entry dispatcher.
- Customer's `onResult` handler dispatch: unchanged (fired from
  `_callback/{id}` rows, written by envelope 5 apply).

### 6.3 Added

- `src/webhook_server/` module — leader-pinned thread inside the
  loop46 binary. Spawned on leadership-acquired, stopped on
  leadership-lost. Reads `webhooks.db`, POSTs customer URLs,
  proposes envelopes 5/6.
- New raft envelope types 4 (enqueue batch), 5 (complete), 6
  (retry schedule).
- New cluster-wide SQLite db: `data_dir/webhooks.db`. Initialized
  at cluster bootstrap; opened by every node's apply path (write
  side); opened by the leader's webhook-server thread (read side).
- No new binaries, no new env vars.

---

## 7. Migration order

The current code has a fully-functional drainer + per-tenant outbox.
Cutover happens in steps so each is independently shippable +
smoke-testable.

1. **Add `webhooks.db` schema + envelope types 4/5/6 + multi-
   envelope-entry support to apply path.** Default behavior
   unchanged because nothing proposes the new types yet. Smoke:
   hand-craft an envelope 4 batch, observe the rows appear in
   `webhooks.db` on every node.
2. **Build webhook-server thread** in `src/webhook_server/`:
   leader-pinned spawn/stop wired into the raft leadership signals,
   delivery loop, raft proposer for envelopes 5/6. Smoke: become
   leader → thread starts; lose leadership → thread stops;
   hand-craft an envelope 4 batch → delivery loop POSTs the URL →
   envelope 5 applies → `_callback/` appears.
3. **Switch dispatcher to combined propose** behind a feature flag
   (`webhook.path = drainer | direct`). Default `drainer`. When
   `direct`: dispatcher accumulates webhook.send calls per-handler,
   proposes envelope 0 + envelope 4 together. Existing drainer
   path keeps working when flag is `drainer`.
4. **Cut over to `direct` in dev**, run all webhook smokes
   end-to-end: enqueue → deliver → callback. Verify the
   `_outbox/*` prefix is empty during steady state.
5. **Drop the feature flag.** `direct` is the only path.
6. **Delete `src/outbox/drainer.zig`** and the
   `_outbox/`-related code paths in worker / dispatcher / apply.

Smokes after cutover:
- Existing webhook smoke runs through the new path end-to-end.
- New smoke: webhook-server killed mid-delivery → restart →
  continues from `webhooks.db` state without scanning any tenant
  app.db.
- New smoke: cluster failover during delivery → new leader's
  webhook-server picks up `webhooks.db` state and continues
  delivery (duplicate POST possible; X-Rove-Webhook-Id dedup
  expected).
- New smoke: handler throws after webhook.send → no row in
  `webhooks.db`, no kv write committed.

---

## 8. Open questions / deferred

### 8.1 Cross-db atomicity in envelope 5 apply

Envelope 5 apply touches both `webhooks.db` and tenant's `app.db`.
SQLite supports cross-db transactions via ATTACH
(`ATTACH 'app.db' AS tenant_db; BEGIN; DELETE FROM webhooks ...; INSERT INTO tenant_db.kv ...; COMMIT;`)
but ATTACH has caveats around journal mode interaction. Verify
during implementation that ATTACH+WAL works correctly across both
attached dbs. Fallback: sequential commits with idempotent retry
on partial failure (`webhooks.db` delete first; if tenant app.db
write fails, the next apply attempt retries from the still-present
`_callback/{id}` `INSERT OR REPLACE` semantics — idempotent).

### 8.2 Resolved: no per-tenant outbox, no drainer

This iterated multiple times during planning. Final resolution
(2026-05): the per-tenant `_outbox/{id}` row and the drainer go
away entirely. The dispatcher proposes envelope 0 + envelope 4 in
the same raft entry; customer-response gating on raft commit
guarantees `webhooks.db` durability before the user sees a
response. There is nothing to recover, nothing to drain, nothing
to forward.

The argument that earlier drafts retained the outbox + drainer
("transactional handoff", "drainer as safety net") was unsound:
the only thing the outbox row could buy was customer-visible kv
inspection of pending webhooks, which isn't a real customer
benefit (customers observe webhook state via callbacks, not by
peeking kv). The drainer was solving a problem that doesn't exist
once envelope 4 rides with envelope 0.

### 8.3 Resolved: in-process leader-pinned thread, NOT separate binary

Leader-pinned thread inside the loop46 binary. The architectural
principle:

> **Subsystems that participate in raft live in the loop46 binary.
> Subsystems that don't can be split into their own processes /
> machines.**

By "participate in raft" we mean: reads raft-replicated state OR
proposes envelopes OR is leader-pinned by definition. Webhook-
server hits all three. files-server / log-server / sse-service
hit none — their state lives in S3, they don't propose, they
serve customer requests on their own subdomains.

Tying webhook delivery to raft-leader liveness is the explicit
tradeoff: webhook delivery pauses briefly during leader election.
Acceptable because elections are rare (seconds, after a leader
crash) and webhook delivery has no per-second SLA.

### 8.4 Backfill / schema migration for `webhooks.db`

When the new code rolls out, `webhooks.db` doesn't exist yet on
any node. First worker startup needs to create it and apply
schema. Not hard; flag as one of the "first-time bootstrap" tasks.

### 8.5 webhooks.db growth + retention

Delivered webhooks are deleted on envelope 5 apply. Failed
webhooks transition to `state = 'failed_pending_callback'` until
the callback fires; a follow-up envelope 5 (or a callback-cleanup
envelope) deletes the row when the customer's `onResult` returns.
For v1, delete on terminal outcome after callback dispatch. Audit
window for failed webhooks is a v2 knob.

### 8.6 Customer-facing webhook visibility

With consolidated `webhooks.db`, the admin UI could expose a
"pending webhooks" view per tenant via a query into `webhooks.db`.
Punt for now; flag as future-admin-UI feature.

### 8.7 Per-destination circuit breaker

Per-customer-URL circuit-breaker (back off entirely from a
consistently-failing destination instead of pounding it with
retries) is a real production concern. V2 knob; defer.

### 8.8 Inbound webhooks

Out of scope for this plan. Inbound webhooks are normal HTTP
requests to customer worker subdomains.
