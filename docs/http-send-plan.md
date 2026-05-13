# http.send plan — outbound HTTP primitive + customer-JS retry policy

> **2026-05-09 corrigendum** — sections referring to a system
> tenant (`webhook.loop46.com`) that runs the default retry policy
> are **superseded**. Retries are now a pure customer-side
> JavaScript library (`globalThis.retry` in `src/js/bindings/
> retry.js`), layered on top of `http.send`. All retry state lives
> in the customer's tenant kv; there's no system tenant with
> cross-tenant write privileges. The rest of the doc — the
> primitive, the in-process fast path (§3.2), the envelope wire
> shapes (§4), the leader-handover contract (§7) — stays accurate.
> References to `webhook.loop46.com` should be read as "an
> example of an in-cluster URL that the in-process fast path
> optimizes" rather than "a system tenant the platform ships."
> See `src/js/bindings/retry.js` for the retry library API
> (`retry.send`, `retry.shouldRetry`, `retry.next`,
> `retry.stripContext`).
>
> What this changed: dropped the cross-tenant `_callback/{id}`
> write privilege (envelope-9 only writes to the schedule's own
> tenant), dropped the system-tenant deployment + handler code,
> dropped the special "webhook.loop46.com" envelope shape.

This document supersedes `docs/webhook-server-plan.md`'s framing of
webhook delivery as a webhook-shaped subsystem. It re-grounds the
design on a single, more general primitive — an outbound HTTP call (fired now or at a future time)
— and moves all webhook-specific policy (retries, signing, dead-
letter, fanout) into customer JS. The platform
ships the primitive; customers compose retry policy with the
included `retry.*` JS helper library.

The motivating framing:

- **The current `webhook.send` is one specific shape of a more
  general operation.** "Make an HTTP call, optionally with a delay,
  optionally route the result back" is general — webhooks-with-
  retries, scheduled emails, abandoned-cart reminders, "remind me in
  30 days," cron-style jobs, saga orchestration, and "fire-this-API-
  call-on-Stripe-webhook-receipt" are all the same primitive with
  different policy on top.
- **Retry policy is opinionated and vendor-specific.** Stripe wants
  idempotency keys + don't-retry-on-4xx. Slack wants exponential
  backoff with jitter. Internal services often want fail-fast with
  alerting. The platform shipping ONE retry policy fights every
  customer's vendor-specific needs; shipping NO retry policy and
  letting customers compose is the right level.
- **The platform is a substrate; system tenants implement features.**
  Same pattern that makes `email.send` work — it's a JS wrapper at
  the admin tenant that calls `webhook.send`. Generalizing further:
  `webhook.send` itself becomes a JS wrapper at a system tenant
  (`webhook.loop46.com`) calling the more primitive `http.send`.

What stays from today: customer-visible API (`webhook.send` and
`email.send` keep their shapes), the at-least-once contract, the
X-Rove-Webhook-Id header, the on-result callback dispatch path.
What changes: the platform's native outbound surface shrinks to
exactly two bindings — `http.send` and `http.cancel`. Both
`webhook.send` and `email.send` become JS libraries on top
(client-side polyfills + server-side system tenant). The
leader-pinned thread becomes generic. Webhook-specific retry /
signing / dead-letter logic moves to customer-equivalent JS at
`webhook.loop46.com`.

---

## 1. The primitive: `http.send`

JS binding shape:

```js
const id = http.send({
  // Optional. If provided, this is the row id (scoped to the
  // calling tenant). Same handle re-scheduled = the previous
  // schedule is overwritten. Without a handle, the platform
  // derives a deterministic id (sha256 of request_id || call_index)
  // — same rule as today's `webhook.send`. See §1.1.
  handle: `reminder-${user_id}`,

  url:       "https://api.stripe.com/v1/charges",
  method:    "POST",
  headers:   { "authorization": "Bearer sk_...", "idempotency-key": "..." },
  body:      "amount=...",
  fire_at_ns: null,           // null/now → fire ASAP; future ns → delay
  on_result: {                // optional; null = fire-and-forget
    tenant: "acme",           // defaults to the calling tenant
    module: "stripe_response",// see §1.2 — module reference, not URL
    context: { order_id: "o-42", correlation_id: "..." },
  },
  timeout_ms: 30_000,         // per-call deadline, default 30s
  max_body_bytes: 256 * 1024, // bytes captured back into on_result
});

// Cancel a scheduled row before it fires.
http.cancel({ handle: `reminder-${user_id}` });
// Or by the id `http.send` returned (works whether handle was
// customer-provided or platform-derived):
http.cancel({ id: previously_returned_id });
```

`http.send` returns the row id — equal to the handle if one was
provided, the platform-derived sha256 hex otherwise. Either form is
accepted by `http.cancel`.

Semantics:

- **Atomic with the calling handler's writeset.** Both
  `http.send` and `http.cancel` accumulate onto the request's
  execution context (same shape as `events.emit` / `webhook.send`
  already do). At handler commit they ride alongside the kv
  writeset envelope in the same raft entry. By the time the
  customer response returns, the row is durably committed (or
  durably gone) cluster-wide.
- **Fire timing.** `fire_at_ns ≤ now` → leader's scheduler thread
  picks it up on its next tick and dispatches the HTTP call. Future
  `fire_at_ns` → row sits in `schedules.db` until that time arrives.
- **One fire per scheduled row.** No internal retry. The HTTP call
  fires once; the result (status + body, capped at
  `max_body_bytes`, or a transport error) routes to `on_result`.
  Customers wanting retries write a callback handler that decides
  whether to call `http.send` again.
- **Apply-side wakeup.** Same shape as today's webhook wakeup: when
  the apply path commits a schedule row whose `fire_at_ns ≤ now`,
  it fires the scheduler's wake event. Future-`fire_at_ns` rows
  schedule a wakeup at that absolute time.
- **Tape replay.** Replay re-runs the handler. `http.send` /
  `http.cancel` calls are captured; replay synthesizes the
  deterministic id but does NOT re-fire the HTTP call (same posture
  as `webhook.send` today).

### 1.1 Handles, cancellation, replacement

`handle` is a customer-supplied row id, scoped to the calling
tenant. Same handle = same row — the most recent
`http.send({handle: H, ...})` is the row that fires; everything
earlier with that handle is silently replaced.

This collapses cancel + replace + customer-meaningful naming into
one mechanism:

- **Replace**: a per-order timeout that gets pushed out on each
  user activity uses one stable handle; every call overwrites
  the previous schedule.
- **Cancel**: `http.cancel({handle: "reminder-${user_id}"})` after
  the user does the thing the reminder was about.
- **Idempotency under replay**: handlers retrying from a transient
  fault re-call `http.send({handle: H, ...})` — converges on
  one row regardless of how many times the handler runs. Stronger
  than the platform-derived sha256 id (which can drift if the
  handler's call sequence varies between attempts).
- **Cron**: a self-rescheduling cron module uses
  `handle: "cron-${job_name}"`; if a concurrent dispatch tries to
  reschedule, the second call just overwrites the first — no
  duplicate cron schedule.

Without a handle, the platform derives the id from
`(request_id, call_index)` as today. Customers who don't need
cancellation pay nothing for the feature.

Handle constraints: 1-256 bytes, UTF-8, no NUL byte. Tenant-scoped,
so two tenants can each have a `"reminder-1"` without collision.

The "overwrite while firing" race is resolved via a row version
counter — see §7.

### 1.2 Why `on_result` is a module reference, not a URL

Customer changes their URL routing → URL-based callbacks silently
break at fire time, days or weeks after the routing change, with
no deploy-time signal. Module references survive routing changes
— the customer's `stripe_response.mjs` keeps its filename across
URL refactors. The decoupling is the load-bearing property; an
`on_result.url` field would create a footgun where the customer's
CHOICE of how to lay out their app changes the platform's behavior
weeks later.

Module references also skip the URL-parse + auth-check + Request-
synthesis overhead a URL-based callback would carry. Same reason
internal routing (§3.2) is faster than libcurl-then-h2-ingress:
in-process module dispatch is cheaper than synthesizing HTTP
shapes around an in-cluster call.

Customers wanting an external (cross-cluster) callback write a
thin shim module that calls `http.send({url: "https://my-aws.../"})`
from their on_result handler. One extra envelope hop; clean
separation between "the platform invokes my code" (module) and
"my code invokes an external service" (URL).

---

## 2. Architecture

```
                   ┌─────────────────────────────────┐
                   │  customer handler at acme.../   │
                   │  http.send({ url:           │
                   │    "https://api.stripe.com/...",│
                   │    on_result: { module:         │
                   │      "stripe_response" } });    │
                   └──────────────┬──────────────────┘
                                  │ rides as raft envelope 4
                                  │ (alongside writeset env 0)
                                  ▼
                   ┌─────────────────────────────────┐
                   │  apply path → schedules.db row  │
                   │  (cluster-wide, raft-replicated)│
                   └──────────────┬──────────────────┘
                                  │ wake leader scheduler
                                  ▼
                   ┌─────────────────────────────────┐
                   │  leader-pinned scheduler thread │
                   │  - poll for fire_at_ns ≤ now    │
                   │  - libcurl request              │
                   │  - propose envelope 5 (result)  │
                   └──────────────┬──────────────────┘
                                  │ envelope 5 → apply path
                                  │ writes _callback/{id} to
                                  │ tenant's app.db, deletes
                                  │ schedule row from schedules.db
                                  ▼
                   ┌─────────────────────────────────┐
                   │ next dispatch tick:             │
                   │ dispatchCallbacks invokes       │
                   │ <on_result.module>'s default    │
                   │ export with { ok, status,      │
                   │ body, error, context }         │
                   └─────────────────────────────────┘
```

Two architectural rules carry forward from `webhook-server-plan.md`:

> **Subsystems that participate in raft live in the loop46 binary.**

The scheduler thread reads `schedules.db` (raft-replicated) and
proposes envelopes; it stays in-process.

> **Leader-pinned, no separate election protocol.** The thread runs
> only when `raft.isLeader()` returns true. Failover = the new
> leader's scheduler thread starts; the old leader's stops on its
> next tick.

---

## 3. Transport at each hop

Five different "an HTTP-shaped thing happens" hops in the design;
worth being explicit about which protocol carries which:

| Hop | Direction | Protocol | Notes |
|---|---|---|---|
| Browser / webhook sender → cluster | inbound | h2 (or whatever the edge proxy negotiates) | Operator runs an edge proxy (Cloudflare, AWS ALB, Fastly, nginx/Caddy/Envoy) that handles HTTP/1.x and HTTP/3 from the public internet, speaks h2 to origin. See §3.1. |
| Cluster ingress → worker | inbound | h2 over TLS via ALPN, OR h2c if the proxy is co-located | rove-h2 listener; customer-tenant subdomain routing. |
| Scheduler / worker → in-cluster target (e.g. `webhook.loop46.com`) | in-process | n/a | Detected at apply time (host matches a known cluster tenant); the worker hosting that tenant picks the row up directly via `dispatchInternalSchedules` and runs the handler in its own QJS runtime. No HTTP at all. Falls back to libcurl outbound (the row below) if no worker hosts the target locally. See §3.2. |
| Scheduler thread → external target | outbound | h2 over TLS via libcurl + ALPN, falls back to 1.1 if upstream is 1.1-only | The scheduler picks rows whose `is_internal` is false. libcurl negotiates whatever the upstream supports. Stripe / Slack / GitHub all speak h2; long-tail upstreams may not. |
| Scheduler thread → on_result callback | none — in-process | n/a | NOT an HTTP call. Envelope-5 from the scheduler writes `_callback/{id}` into the tenant's `app.db`; `dispatchCallbacks` reads it on the leader's next tick and invokes the customer's module directly in the leader-worker's QJS runtime. Same in-process JS dispatch as any other handler invocation, just triggered by a kv row instead of an h2 request. |

### 3.1 Edge proxy as a deployment requirement

rove-h2 speaks HTTP/2 only — HTTP/1.x clients hitting the listener
directly get a 426 Upgrade Required. Production deployments need
an edge proxy (Cloudflare with "HTTP/2 to Origin" enabled, AWS ALB
with h2-on-backend, Fastly, GCP load balancer, nginx/Caddy/Envoy
configured for h2-to-upstream) handling protocol termination. The
edge accepts HTTP/1.0/1.1/2/3 from the public internet and forwards
h2 to our workers.

This is the standard pattern for modern PaaS (Vercel, Heroku-
router, Fly.io, Cloud Run all do this). Modern HTTPS clients
negotiate h2 via ALPN by default, so direct origin hits work for
nearly everything anyway; the edge proxy covers the long tail of
HTTP/1.x-only clients (typically older or hand-rolled tools).

Adding HTTP/1.x to rove-h2 was considered and rejected: ~500-1500
lines of parser + io_uring integration plus ongoing maintenance,
versus a deployment requirement that production-grade clusters
already meet for unrelated reasons (DDoS protection, TLS
flexibility, geographic edge). The deployment-doc note plus a
clear startup warning when no proxy is detected is the right
investment.

### 3.2 Internal routing for in-cluster targets (v1, in-scope)

The default-policy hop (scheduler → `webhook.loop46.com`) is
expensive if it goes outbound: libcurl issues an HTTPS request to
the cluster's ingress, ingress routes back to a worker hosting
the system tenant — a TLS round-trip + h2 frame exchange + worker
h2 ingress on a request that never needed to leave the worker
process. Empirically ~10-50ms same-AZ, which compounds in chained
sagas (step1 → step2 → step3).

This hits the *steady-state* path: every customer's
`webhook.send` goes through `webhook.loop46.com`. The optimization
isn't for a few advanced customers — it's how the default works.
**Ship in v1.**

Detection runs once at apply time, not per-fire:

```zig
// when envelope-4 (schedule_enqueue) commits, stamp is_internal
const is_internal = blk: {
    const uri = std.Uri.parse(row.url) catch break :blk false;
    const host = stripPort(uri.host orelse break :blk false);
    if (!std.mem.endsWith(u8, host, public_suffix)) break :blk false;
    if (host.len <= public_suffix.len + 1) break :blk false;
    const tenant_id = host[0 .. host.len - public_suffix.len - 1];
    break :blk tenant_registry.exists(tenant_id);
};
store.markInternal(row.id, is_internal);
```

Dispatch uses a new worker phase parallel to `dispatchCallbacks`:

```
dispatchInternalSchedules (every worker, every tick):
  1. SELECT WHERE is_internal=true AND fire_at_ns ≤ now AND
     inflight_until_ns < now ORDER BY fire_at_ns LIMIT MAX_PER_PASS.
  2. For each row: try lease (UPDATE ... WHERE inflight_until_ns < now).
     If lease lost (a peer worker grabbed it), skip.
  3. Look up the target tenant locally. If not hosted on this node:
     release the lease, continue (a worker that hosts it will pick it up).
  4. Synthesize dispatcher.Request from row's method/path/headers/body.
     Resolve the URL's path (strip leading scheme+host).
  5. Run dispatcher.run() against the target tenant's bytecode + kv,
     same as any inbound h2 request would.
  6. Capture response (status, body, error).
  7. Propose envelope-5 with the result — identical wire shape to
     the libcurl path. Apply writes _callback/{id} on the caller
     tenant; dispatchCallbacks invokes the customer's on_result
     module unchanged.
```

Multi-node: every worker runs the phase; the row-level lease
ensures one worker per row wins. If no node hosts the target
tenant locally (misconfiguration / tenant just got removed), a
fallback timer (5s default) flips `is_internal=false` and the
scheduler thread takes over via libcurl outbound. Failsafe;
shouldn't fire under healthy operation.

Hidden-from-customer optimization — `http.send` semantics are
unchanged whether the call routes in-process or via libcurl. The
on_result event shape is identical. Customer code doesn't know
which path it took.

Cost: ~300-400 lines (URL parser + apply-side stamp + dispatch
phase + tests). Risk is low: bugs degrade to "row stays
in-flight until the fallback timer fires libcurl outbound,"
not customer-visible failures.

---

## 4. Wire format

### 4.1 `schedules.db`

Cluster-wide SQLite, raft-replicated. Same shape pattern as today's
`webhooks.db`:

```sql
CREATE TABLE schedules (
  tenant_id       TEXT NOT NULL,       -- scopes the id; routing for on_result
  id              TEXT NOT NULL,       -- customer handle (1-256 utf8) OR
                                       -- platform-derived sha256 hex (64 chars)
  version         INTEGER NOT NULL,    -- bumped on every overwrite-by-handle;
                                       -- envelope 5 carries the version it
                                       -- saw at fire time so apply can drop
                                       -- stale results (see §7).
  fire_at_ns      INTEGER NOT NULL,    -- absolute ns; 0 = ASAP
  url             TEXT NOT NULL,
  method          TEXT NOT NULL,       -- "GET", "POST", ...
  headers_json    TEXT NOT NULL,       -- JSON object
  body            BLOB NOT NULL,
  timeout_ms      INTEGER NOT NULL,
  max_body_bytes  INTEGER NOT NULL,
  on_result_module TEXT,               -- null = fire-and-forget
  context_json    TEXT,                -- opaque blob for on_result
  inflight_until_ns INTEGER NOT NULL DEFAULT 0,  -- in-memory mirror; not raft-replicated
  is_internal     INTEGER NOT NULL DEFAULT 0,    -- §3.2 in-cluster routing flag
  created_at_ns   INTEGER NOT NULL,
  PRIMARY KEY (tenant_id, id)
);
CREATE INDEX schedules_due ON schedules (fire_at_ns) WHERE inflight_until_ns = 0;
```

The `(tenant_id, id)` PK gives free `http.cancel` lookups by handle
and free tenant-scoped uniqueness. Customer handles can collide
across tenants without coordination.

### 4.2 Raft envelope shape

Generalizes today's webhook envelope:

| Type | Name              | Payload                                | Producer                |
|------|-------------------|----------------------------------------|-------------------------|
| 0    | writeset          | tenant kv writes                       | dispatcher              |
| 2    | root_writeset     | __root__.db writes                     | admin / signup          |
| 4    | schedule_upsert   | one or more rows (UPSERT on (tenant, id), bumps version) | dispatcher (rides w/ 0) |
| 5    | schedule_complete | (tenant, id, version, result)          | scheduler / worker      |
| 6    | schedule_retry    | id + new fire_at_ns + attempts++       | (deprecated — see §8)   |
| 7    | multi             | container for env 0 + env 4/8 atomically | dispatcher            |
| 8    | schedule_cancel   | one or more (tenant, id) tuples; deletes | dispatcher (rides w/ 0) |

**Envelope 4 is the renamed-and-generalized envelope 4.** Existing
`webhook_enqueue` becomes `schedule_upsert` with a strictly-larger
payload (adds `fire_at_ns`, `handle/id`, `version`). Migration: ship
the new payload shape, leave the type number; old in-flight webhook
rows are drained before the bump (zero-row cutover).

**Envelope 4 is UPSERT, not insert.** `http.send({handle: H,
...})` for an existing `(tenant_id, H)` overwrites the row and bumps
`version`. The previous row's stamp (`url`, `body`, etc.) is
discarded. Any in-flight fire of the previous version sees a
version mismatch when it tries to apply envelope 5 — its result is
silently dropped (see §7).

**Envelope 8 (`schedule_cancel`) is new.** Rides with the writeset
the same way envelope 4 does. Apply path looks up
`(tenant_id, id)` and deletes the row if present (idempotent — a
double-cancel is a no-op).

**Envelope 6 retires.** Today's `webhook_retry_schedule` advances
attempts + reschedules the next fire. Under the new design, the
scheduler doesn't retry; it proposes envelope 5 with the result
and the customer's callback decides whether to call
`http.send` again (which is just another envelope 4). Removes
~150 lines of retry-policy code from the apply path.

---

## 5. The scheduler thread

`src/schedule_server/thread.zig` (replaces `src/webhook_server/thread.zig`).
Same shape as today's webhook thread, but generic:

```zig
while (!stop) {
    if (raft.isLeader()) {
        // Read all rows with fire_at_ns ≤ now, capped at MAX_PER_PASS.
        const due = store.dueRows(now_ns, MAX_PER_PASS);
        for (due) |row| {
            // Lease so a slow delivery doesn't get re-picked next pass.
            store.leaseUntil(row.id, now_ns + LEASE_NS);
            // libcurl POST/GET/etc; SSRF check; bounded body capture.
            const result = http_client.deliver(row);
            // Propose envelope 5 — apply path writes _callback/{id}
            // to tenant's app.db AND deletes this schedule row.
            raft.propose(env5(row.id, result));
        }
    }
    wake.timedWait(next_due_or_default);  // apply-side wakeup signals
}
```

Differences from today's webhook thread:

- **No retry logic.** Whatever the result, we propose envelope 5 and
  drop the row. Customer callback decides what's next.
- **No webhook-specific headers stamped.** Today the worker stamps
  `X-Rove-Webhook-Id` + `X-Rove-Webhook-Attempt` on the outbound
  call. Under the new design, customer JS at `webhook.loop46.com`
  stamps whatever it wants — including platform-default headers if
  the customer wants the same shape.
- **Sleep-until-next-due, not poll.** Today's thread polls every
  `poll_interval_ms` (250). With future-`fire_at_ns` rows, the
  thread sleeps until the next row is due (or the apply-side wake
  fires, whichever comes first). Idle clusters wake essentially
  never. (Production today already has the apply-side wake;
  this just removes the 250ms cap.)

Net code: ~250 lines, replacing the ~750 lines of
`webhook_server/thread.zig` + retry-helper code spread across
apply.zig.

---

## 6. Atomicity with the customer's writeset

This is the load-bearing concern. Today's invariant:

> Once `webhook.send()` returns from a handler, the customer's kv
> writes AND the webhook row commit atomically — there's no crash
> window in which the kv update succeeded but the webhook never
> queued.

Preserved by riding envelope 4 alongside envelope 0 in a type-7
multi-envelope. The dispatcher proposes one raft entry containing
both; apply path replays both atomically.

**The new design preserves this exactly** — the only change is
generalizing what envelope 4's payload describes (any HTTP call, not
just a customer-shaped webhook). The atomicity argument doesn't
change.

**Rejected alternative: cross-tenant atomic kv writes.** Would let
the customer handler write a "schedule this" row into
`webhook.loop46.com`'s kv as part of the customer's writeset.
Cleaner-feeling — schedule storage is "just kv" — but introduces a
new primitive (cross-tenant raft writes) bigger than the one it
replaces, and exposes a sharp footgun (any tenant scribbling on
any other tenant's kv). The envelope path is narrower.

---

## 7. Leadership change + at-least-once

The scheduler thread is leader-pinned: `if (raft.isLeader())` gate
at each tick, idle otherwise. Same shape as today's webhook
delivery thread. `dispatchInternalSchedules` (§3.2) is also
leader-only, for the same reason — one in-flight set per leader,
one demote/promote cycle.

**Lifecycle:**

1. **Steady state.** Leader holds an in-memory `in_flight`
   hashset of `(schedule_id)`s it has fired but not yet seen
   envelope-5 commit for. Used to skip same-tick re-firing.
2. **Demote.** Next tick's gate closes; thread idles. In-memory
   `in_flight` cleared. Any libcurl call already in flight
   finishes naturally — libcurl doesn't know about leadership.
   When it returns, the thread tries to propose envelope-5;
   raft rejects (not leader). **The result is lost.**
3. **Promote.** Next tick the gate opens. Scan rows with
   `fire_at_ns ≤ now`. The new leader has no idea what the old
   leader was working on; it just fires whatever's due:
   - Rows the old leader successfully fired AND whose envelope-5
     reached quorum before the leadership change: row was
     already deleted by `applyScheduleComplete`, scan misses
     them. No double-fire.
   - Rows the old leader fired but whose envelope-5 didn't reach
     quorum: row still pending. New leader fires again.
     **Double-fire window — at-least-once.**

**At-least-once is the contract.** A row may be delivered more
than once if leadership changes mid-flight. The customer's
`on_result` is invoked at least once. Same shape as today's
`webhook.send`.

**Idempotency is the customer's responsibility.** Every outbound
request carries an `X-Rove-Schedule-Id` header (the row's id —
either the customer's handle or the platform-derived sha256 hex)
plus an `X-Rove-Schedule-Version` header (the row's version
counter at fire time). Upstreams with idempotency-key support
(Stripe, etc.) accept the id directly. Customer-side, the
`on_result` handler can dedupe by checking
`kv.get("_seen/" + event.id + "/" + event.version)` before
processing.

**Overwrite-while-firing race.** Customer schedules `handle="X"`
for tomorrow. Tomorrow arrives, leader fires libcurl. Mid-flight,
the customer's handler runs `http.send({handle: "X",
fire_at_ns: future_2})` to replace. Without protection, the
in-flight fire's envelope-5 would land AFTER the new row's
envelope 4 and either delete the new row or write `_callback/{id}`
with the old fire's data — both wrong.

The version counter resolves this:

1. Each row carries a monotonic `version`. Fresh insert: 1.
   Same-handle UPSERT: bump.
2. Scheduler's `in_flight` set tracks `(id, version_at_fire)`.
3. When libcurl returns, scheduler proposes envelope 5 with
   `(id, version, result)`.
4. Apply path checks the row's CURRENT `version`:
   - Match → write `_callback/{id}` with the result, delete the
     row, deliver `on_result`.
   - Mismatch (newer version exists) → silently drop the
     envelope-5. The newer row stays scheduled; the old fire's
     result is discarded.

Customer-visible contract: the most recent `http.send` with a
given handle is what fires; everything earlier is silently
replaced. At-least-once becomes "the most-recently-scheduled
version is delivered at-least-once." Earlier in-flight fires that
get superseded just disappear — usually what the customer wanted
when they overwrote in the first place.

**Cancel during firing.** Same shape: `http.cancel({handle: "X"})`
deletes the row. If a fire was in-flight, its envelope-5 finds no
matching row at apply time and is dropped. Customer's `on_result`
does NOT fire — they cancelled, they don't get a delivery
notification. Documented behavior.

**On-disk leasing (`inflight_until_ns`)** is included in the
schema for ops visibility (`SELECT * FROM schedules WHERE
inflight_until_ns > now()` for debugging) and as a future
tightening — but **not raft-replicated in v1**. Same posture as
today's `webhooks.db`. A raft-replicated lease bump would add
~5-15ms to every fire (one extra propose), dwarfing the actual
delivery latency. The double-fire rate during *healthy* leadership
churn is low enough that the in-memory set + at-least-once
contract is the right tradeoff. v2 candidate: batched lease
bumps amortized across many rows (one propose per N rows
instead of per-row).

**Internal routing during leadership change** (§3.2): same
contract, with one extra wrinkle. Double-fire of an in-cluster
target means the target handler runs twice — its kv writes may
land twice. Customer-built system handlers (the cookbook
examples in §10, and `webhook.loop46.com` itself) MUST be
idempotent in their kv writes, using the schedule id as dedupe
key. The default-policy implementation at `webhook.loop46.com`
does this — `kv.get("_processed/" + schedule_id)` gate before
the actual delivery scheduling, atomic with the kv write that
records "this schedule_id has been seen."

---

## 8. The on_result callback path

Reuses today's envelope-5 → `_callback/{id}` → `dispatchCallbacks`
machinery unchanged. The only shape change is the event handed to
the customer's callback:

```js
// Today (webhook.send onResult):
{ webhookId, outcome, attempts, response: {status, body}, error, context }

// Under http.send:
{ id, ok: bool, status, body, error, context }
```

Differences:

- `outcome` and `attempts` go away. The callback runs ONCE per
  schedule row. Retry semantics are the customer's problem (or
  `webhook.loop46.com`'s, for customers using the default policy).
- `id` is exposed (was `webhookId`); same value, less webhook-
  specific name.
- `ok: bool` is a convenience: `status >= 200 && status < 300 &&
  !error`. Customers who care about exact status codes still get
  them via `status`.

The `context` blob round-trips verbatim — that's the customer's
opaque correlation handle.

---

## 9. `webhook.send` and `email.send` are libraries, not bindings

The platform ships exactly two outbound primitives as native
bindings: `http.send` and `http.cancel`. Everything customers
think of as "send a webhook" or "send an email" is JS code on top
— a library composed of two cooperating pieces:

  1. **A client-side polyfill** evaluated into every QJS context
     at startup, exposing the global API customers call
     (`webhook.send`, `email.send`).
  2. **A server-side system tenant** holding the durable
     retry/policy/dead-letter state and running the dispatch
     loop using `http.send`.

Both pieces are customer-equivalent JS. Operators can replace
either or both without recompiling the engine; advanced customers
can skip the platform's libraries entirely and compose on
`http.send` directly (§10).

This is the same pattern `email.js` follows today (built into
every QJS context at startup as a polyfill that wrapped the C
`webhook.send` binding). What changes: the C `webhook.send`
binding is gone. `webhook.js` becomes the new polyfill, calling
`http.send`. `email.js` continues to call `webhook.send`,
which now resolves to the polyfill instead of a C binding —
zero change to email's source.

### 9.1 `webhook.send` polyfill (client-side)

```js
// src/js/bindings/webhook.js — embedded as runtime polyfill,
// just like email.js + textcodec.js today.
globalThis.webhook = {
  send(opts) {
    return http.send({
      handle: opts.id,           // optional customer-supplied
      url:    "https://webhook.loop46.com/v1/webhooks/send",
      method: "POST",
      headers: { "content-type": "application/json" },
      body:   JSON.stringify({
        tenant_id: __tenant_id,  // platform-set, not spoofable
        target_url:    opts.url,
        target_method: opts.method,
        target_headers: opts.headers,
        target_body:   opts.body,
        on_result:     opts.onResult,  // module name on customer side
        context:       opts.context,
        max_attempts:  opts.maxAttempts ?? 5,
        signing:       opts.signing,   // hmac config, etc.
      }),
    });
  },
};
```

`__tenant_id` is set by the platform on the dispatch state — the
customer can't spoof it. The polyfill keeps the existing
`webhook.send` API shape so existing customer code compiles
unchanged.

### 9.2 `webhook.loop46.com` (server-side)

System tenant deployed at `webhook.loop46.com`. Its handlers
implement the "default webhook" experience customers expect:

- POST `/v1/webhooks/send` — receives the spec from the
  client-side polyfill. Persists into its own kv, schedules the
  first attempt via `http.send`.
- on_result module `webhook_result` — receives every fire's
  outcome via the standard envelope-5 → `_callback/{id}` →
  `dispatchCallbacks` path. Decides:
  - 2xx → propagate to the customer's `onResult` handler (one
    more `http.send` call with `on_result.tenant: <calling>`).
  - 5xx + retries left → exponential backoff via another
    `http.send` with future `fire_at_ns`, same handle so
    the in-flight row is overwritten cleanly.
  - 4xx OR retries exhausted → write to
    `_failed_webhooks/{id}` in the customer's tenant AND
    propagate the final outcome to the customer's `onResult`.

Roughly 200 lines of JS. The retry curve, the dead-letter
behavior, the X-Rove-Webhook-Id header, the customer-supplied
HMAC signing — all customer JS. Read it, debug it, replace it.

### 9.3 `email.js` keeps composing the same way

Today's `src/js/bindings/email.js` calls `webhook.send`; under
this design, that becomes `webhook.send` (the polyfill) calling
`http.send`. Two-layer composition: `email.send` →
`webhook.send` → `http.send`. The customer-visible
`email.send` API is unchanged; its implementation didn't change
either, only what `webhook.send` underneath it points at.

If a customer wants different email semantics (different SMTP
provider, different retry policy, different bounce handling),
they write their own email library on top of `webhook.send` (or
even directly on `http.send`). Same composition all the way
down.

---

## 10. Customer escape hatch

Advanced customers bypass `webhook.loop46.com` and call
`http.send` directly. Examples this enables (cookbook entries):

### 10.1 Stripe-style idempotency

```js
// in customer's stripe.mjs handler
export function charge(amount, customer_id) {
  const idempotency_key = `charge-${customer_id}-${Date.now()}`;
  // Dedupe by idempotency_key in the customer's own kv.
  if (kv.get(`_pending_charges/${idempotency_key}`)) {
    return { error: "duplicate" };
  }
  kv.set(`_pending_charges/${idempotency_key}`, JSON.stringify({
    customer_id, amount, started_ms: Date.now(),
  }));
  http.send({
    url: "https://api.stripe.com/v1/charges",
    method: "POST",
    headers: {
      "authorization": `Bearer ${kv.get("_secrets/stripe_key")}`,
      "idempotency-key": idempotency_key,
    },
    body: `amount=${amount}&customer=${customer_id}`,
    on_result: { module: "stripe_charge_result", context: { idempotency_key } },
  });
}

// stripe_charge_result.mjs
export default function (event) {
  const { idempotency_key } = event.context;
  if (event.ok) {
    kv.delete(`_pending_charges/${idempotency_key}`);
    kv.set(`charges/${idempotency_key}`, event.body);
    return;
  }
  if (event.status >= 400 && event.status < 500) {
    // Stripe says don't retry on 4xx. Surface to ops.
    kv.set(`_failed_charges/${idempotency_key}`, JSON.stringify(event));
    return;
  }
  // 5xx or transport error — retry with backoff up to 3 times.
  const pending = JSON.parse(kv.get(`_pending_charges/${idempotency_key}`));
  pending.attempts = (pending.attempts || 0) + 1;
  if (pending.attempts >= 3) {
    kv.set(`_failed_charges/${idempotency_key}`, JSON.stringify({
      ...event, exhausted: true,
    }));
    kv.delete(`_pending_charges/${idempotency_key}`);
    return;
  }
  kv.set(`_pending_charges/${idempotency_key}`, JSON.stringify(pending));
  const backoff_ms = Math.min(60_000, 1000 * Math.pow(2, pending.attempts));
  http.send({
    url: "https://api.stripe.com/v1/charges",
    method: "POST",
    headers: { ... },
    body: ...,
    fire_at_ns: BigInt(Date.now() + backoff_ms) * 1_000_000n,
    on_result: { module: "stripe_charge_result", context: { idempotency_key } },
  });
}
```

### 10.2 Scheduled email (no webhook semantic at all)

```js
// "send a reminder in 30 days" — handle so the customer can cancel
// it later if the user does the thing the reminder was about.
http.send({
  handle: `reminder-${user_id}`,
  url: "https://webhook.loop46.com/v1/email/send",  // platform email service
  body: JSON.stringify({ to, subject, html }),
  fire_at_ns: BigInt(Date.now() + 30 * 24 * 60 * 60 * 1000) * 1_000_000n,
});

// Later, if the user does the thing:
http.cancel({ handle: `reminder-${user_id}` });
```

### 10.3 Abandoned-cart reminder (replace + cancel)

```js
// User added something to their cart — schedule a reminder for 24h.
// Handle is keyed by cart_id so re-scheduling on each cart update
// just pushes the deadline out.
http.send({
  handle: `cart-${cart_id}`,
  url: "https://webhook.loop46.com/v1/email/send",
  body: JSON.stringify({ to: user.email, template: "cart_reminder", cart_id }),
  fire_at_ns: BigInt(Date.now() + 24 * 60 * 60 * 1000) * 1_000_000n,
});

// User checked out — cancel the reminder.
http.cancel({ handle: `cart-${cart_id}` });
```

### 10.4 Cron-style recurring job

```js
// in customer's cron_tick.mjs handler — invoked via on_result
export default function (event) {
  // ... do periodic work ...
  // Reschedule next tick. Stable handle so concurrent dispatches
  // (rare but possible) don't accidentally double-schedule.
  http.send({
    handle: `cron-${event.context.job_name}`,
    url: `https://${request.host}/cron/tick`,
    method: "POST",
    fire_at_ns: BigInt(Date.now() + 60_000) * 1_000_000n,
    on_result: { module: "cron_tick", context: event.context },
  });
}
```

Bootstrapping the loop is a one-time `http.send` from an admin
handler that uses the same handle — running the bootstrap twice
just overwrites itself, no parallel cron.

### 10.5 Order timeout that gets pushed out on user activity

```js
// Initial: 30-minute timeout to abandon the order.
function startOrder(order_id) {
  http.send({
    handle: `order-${order_id}-timeout`,
    url: `https://${request.host}/orders/expire`,
    method: "POST",
    body: JSON.stringify({ order_id }),
    fire_at_ns: BigInt(Date.now() + 30 * 60 * 1000) * 1_000_000n,
  });
}

// Any user activity on the order pushes the timeout out:
function bumpOrderTimeout(order_id) {
  http.send({
    handle: `order-${order_id}-timeout`,  // same handle — overwrites
    url: `https://${request.host}/orders/expire`,
    method: "POST",
    body: JSON.stringify({ order_id }),
    fire_at_ns: BigInt(Date.now() + 30 * 60 * 1000) * 1_000_000n,
  });
}

// Order completes — cancel the timeout.
http.cancel({ handle: `order-${order_id}-timeout` });
```

### 10.6 Topics / fanout

```js
// publish.mjs
export function publish(topic, payload) {
  const subscribers = JSON.parse(kv.get(`subscribers/${topic}`)) || [];
  for (const sub of subscribers) {
    http.send({
      url: sub.url,
      method: "POST",
      body: payload,
      on_result: { module: "publish_result", context: { topic, sub: sub.id } },
    });
  }
}
```

### 10.7 Custom signing (HMAC, oauth2)

```js
// signed_send.mjs
export function send(url, body, secret) {
  const sig = crypto.hmacSha256(secret, body);
  http.send({
    url, method: "POST",
    headers: { "x-signature": sig },
    body,
    on_result: { module: "signed_send_result" },
  });
}
```

### 10.8 Saga orchestration

```js
// step1.mjs
export function start(order_id) {
  http.send({
    url: "https://api.shipping/v1/labels",
    on_result: { module: "step2", context: { order_id } },
  });
}

// step2.mjs — receives shipping result, kicks off step 3
export default function (event) {
  if (!event.ok) return; // saga aborted
  const { order_id } = event.context;
  http.send({
    url: "https://api.payments/v1/capture",
    on_result: { module: "step3", context: { order_id, label: event.body } },
  });
}
```

---

## 11. Migration plan

Six steps; each is a no-flag-day cutover (the zero-customer-traffic
posture today's `webhook.send` enjoys lets us collapse the
parallel-run phasing the plan-doc'd webhook-server migration would
otherwise require):

1. **Add `http.send` JS binding + scheduler thread, alongside the
   existing webhook system.** New thread reads from a new
   `schedules.db`; new envelope payload shape under a new envelope
   type (8) until cutover. webhook.send keeps its existing path.

2. **Stand up `webhook.loop46.com` system tenant** with the default
   policy implemented in JS using `http.send`. Tenant boots
   alongside `__admin__` and `__replay__`; deploy is part of the
   files-server bootstrap.

3. **Drop the `webhook.send` C binding; ship `webhook.js`
   polyfill.** Same shape as today's `email.js` /
   `textcodec.js` — `addAnonymousImport` for a new
   `src/js/bindings/webhook.js`, evaluated into every QJS context
   at startup. The polyfill installs `globalThis.webhook.send` and
   calls `http.send` against `webhook.loop46.com`. End-to-end
   behavior unchanged from the customer's perspective; existing
   `webhook_smoke.py` passes against the new path.

4. **Drain webhooks.db.** Run the legacy webhook_server thread
   until `SELECT count(*) FROM webhooks WHERE state='pending' = 0`.
   With no new rows arriving (step 3 routed everything through
   the new path), this completes in the time of the longest
   in-flight retry curve — minutes at most.

5. **Delete the legacy webhook_server.** Drop
   `src/webhook_server/`, drop the C `jsWebhookSend` binding +
   `pending_webhooks` plumbing in `dispatcher.Request` /
   `DispatchState`, drop envelopes 4/5/6's old shape, drop
   `webhook_dispatch.zig`'s retry helpers. The platform's
   outbound surface is now exactly two C bindings:
   `http.send` and `http.cancel`. Everything else is JS.

6. **Rename envelope 8 → envelope 4.** With the legacy gone, the
   numeric type can take over the freed slot. Pure raft-log
   change; no semantics change. Followers replay the new shape on
   the next raft restart.

---

## 12. What's locked in

Decided in conversation, not up for re-litigation without new
information:

- **One primitive, not two.** "Fire once with callback" and "call
  with delay" collapse into `http.send({ fire_at_ns? })`.
  Resisted as a separate `delay.call`; it added an API surface
  that did the same thing as `http.send({fire_at_ns: t})`.
- **Atomicity via envelope, not cross-tenant kv.** §6 above. The
  cross-tenant-kv alternative was considered and rejected as
  larger and sharper than the problem it solves.
- **Retry policy lives in customer JS.** The platform ships zero
  retry policy. `webhook.loop46.com` is a *default* policy
  implemented in customer-equivalent JS — operators can replace it
  without recompiling the engine, customers can bypass it
  entirely. (Saved feedback note: "compose from primitives, defer
  dedicated APIs" — same rule.)
- **The leader-pinned scheduler thread stays in-process.** Same
  rationale as `webhook-server-plan.md`: subsystems that
  participate in raft live in the loop46 binary.
- **Tape-replay does not re-fire the HTTP call.** Same as today's
  webhook.send: replay synthesizes the deterministic id and feeds
  the captured response from the tape. New `http.send` calls
  during replay are ignored.
- **Handles are the cancellation + replacement story.** §1.1.
  Customer-supplied row id; same handle re-scheduled silently
  overwrites. `http.cancel({handle})` deletes the row. The
  alternative (a separate `cancel` primitive plus immutable rows)
  was rejected because it forces customers to track ids and adds a
  primitive that handles couldn't. Version counter on the row
  resolves the overwrite-while-firing race (§7).
- **`on_result` is a module reference, not a URL.** §1.2. Module
  references survive customer URL refactors; URL-based callbacks
  silently break at fire time when routing changes. Customers
  wanting an external (cross-cluster) callback write a thin shim
  module that calls `http.send({url: ...})` to the external
  endpoint.
- **Internal routing is auto-detected from the URL, not a separate
  `http.dispatch` primitive.** §3.2. Detection at apply time stamps
  `is_internal=true` on rows whose URL host resolves to a
  cluster-local tenant; `dispatchInternalSchedules` picks them up
  and runs the target handler in-process. Hidden optimization;
  customer-visible semantics identical regardless of route.
- **`webhook.send` and `email.send` are JS polyfills, not C
  bindings.** §9. The platform's native outbound surface is
  exactly `http.send` + `http.cancel`. Everything customers
  recognize as "send a webhook" / "send an email" is JS — a
  client-side polyfill (same pattern as today's `email.js` /
  `textcodec.js`) plus a server-side system tenant
  (`webhook.loop46.com`). Both pieces are customer-equivalent
  code; advanced customers can write their own libraries on top
  of `http.send` directly. Operators can replace the default
  policy without recompiling the engine.

---

## 13. Open questions / deferred

### 13.1 Rate limits + backpressure

Handing retry policy to customer JS means a customer's bad retry
curve becomes the platform's outbound traffic problem. Two
distinct concerns to cap:

- **Per-tenant rate.** A tight `http.send({fire_at_ns: now+10ms,
  on_result: { module: 'self_reschedule' }})` loop can queue
  thousands of rows per second. Cap calls to `http.send`
  per-tenant (token bucket on the existing `RateLimiter`, same
  shape as `events_emit` etc). Default: 100/s sustained, 200
  burst. Throws `Error{code:"rate_limited"}` at queue time so the
  customer's handler sees it and can choose to backoff.

- **Per-(tenant, host) rate.** Even with a sane per-tenant cap, a
  customer whose retry policy is broken could pin all their
  budget at one outbound host — hammering Stripe with 100 req/s
  from one tenant gets the cluster's egress IP rate-limited (or
  banned) by the upstream service. Cap per-(tenant, normalized-
  host) separately. Default: 10/s, 50 burst. Same throw shape as
  the per-tenant cap; customer's `on_result` retry handler can
  observe the throw and backoff.

  Host normalization: lowercase `Uri.host`, IP literals (v4 + v6)
  used verbatim, port stripped. Distinct hosts under the same
  parent (`api.stripe.com` vs `files.stripe.com`) get distinct
  buckets — fair, since the upstream services rate-limit
  independently.

  Storage: in-memory `(tenant_id, host) → TokenBucket` map on
  each worker. Per-worker not per-cluster — the cluster-wide
  variant is deferred (see the next bullet).

- **Cluster-wide per-host.** Defends against the
  cluster-as-a-whole getting banned by a target service when many
  tenants hammer the same host. Defer to v2 — needs a raft-
  replicated counter or eventual-consistency dance, both bigger
  than the per-tenant version. The per-(tenant, host) cap in
  practice prevents the worst case on a normally-loaded cluster
  (10/s × N tenants × P workers ≪ rate limits at well-resourced
  upstream services).

- **In-flight row cap.** Independent of rate: cap the count of
  unfired-future rows per tenant in `schedules.db`. Defends
  storage growth from a customer scheduling a million far-future
  rows. Default: 10,000 in-flight per tenant. Plan tier knob
  later.

All four enforce at `http.send`-queue time, not at fire time —
keeps the failure mode synchronous and predictable for customer
code. Customers writing retry policies in JS see the rate-limit
throw and can react (their retry handler is itself JS that hits
these caps).

Punt exact numeric defaults to first traffic — start
conservative, observe, raise.

### 13.2 Long-future schedule rows + snapshots

`fire_at_ns = now + 90 days` rows sit in `schedules.db` for 90
days. Snapshots include them. Snapshot growth = O(in-flight
schedule rows). For typical workloads (webhooks, short-term
retries), this is fine. For "schedule a renewal in 1 year" use
cases at scale, the snapshot footprint matters. Possible
mitigations: archive long-future rows to a separate table /
backend; or simply let snapshots carry them — disk is cheap, raft
log compaction handles the steady-state cost. Decide at first
real workload.

### 13.3 Cross-tenant on_result routing

`on_result.tenant` defaulting to the calling tenant is the obvious
shape. Should we allow `on_result.tenant: "<other>"`? Use case:
`webhook.loop46.com` calls `http.send` and wants the result
routed back to the customer's tenant, not its own. For the
internal `webhook.send` shim path this is fine because
`webhook.loop46.com`'s handler can synthesize the customer-side
`on_result` itself (do the work in its own dispatch tick, then
schedule a final `http.send` whose URL is the customer's
tenant). Native cross-tenant `on_result` is a bigger primitive
(introduces "any tenant can dispatch into any other tenant's
kv via callbacks"); defer until concrete demand.

### 13.4 Simulation / replay shape

Sim tests run handlers without firing real HTTP. Today's
`webhook.send` captures into the per-handler list and tests
inspect it. `http.send` gets the same treatment — the sim
runner provides a stub `http.send` that records the call into
a tape and returns a deterministic id; tests assert on the tape.
Adjacent change to `docs/sim-test-framework.md` to formalize.

### 13.5 What happens when `webhook.loop46.com` itself is down

`webhook.loop46.com` is a normal tenant — if it can't be dispatched
(deployment broken, panic loop, etc.), `webhook.send` calls fail.
That's actually the correct behavior: if the platform's *default*
webhook policy is broken, customer code should see the failure
rather than silently lose webhooks. But it does shift the failure
mode from "platform infrastructure issue" to "customer-shaped
issue" (a system tenant being down looks like a deploy issue).
Surface it via existing tenant-down monitoring; document as a
debug-checklist entry.

---

## 14. Side benefits

Things that fall out for free that nobody planned for:

- **Cron jobs.** §10.3 — recursive `http.send` reschedules itself.
  Customers can build cron without a separate primitive.
- **Scheduled emails.** §10.2 — "send this email in 30 days" is one
  call.
- **Saga orchestration.** §10.6 — chained `on_result` handlers
  compose into multi-step workflows with persistence between
  steps.
- **Dead-letter queues.** Customer's `on_result` writes failed rows
  into a `_failed_*/` kv prefix; admin UI scans it.
- **Custom signing per vendor.** §10.5 — HMAC for Stripe, oauth2
  refresh for Google APIs, mTLS for internal services. Platform
  ships zero signing; every customer's needs are met.
- **Topics / fanout.** §10.4 — pub-sub built from one primitive.
- **Workflow stalling for human approval.** Schedule a callback far
  in the future; cancel via `kv.set` of a flag the callback
  inspects on fire. (Cancel-by-flag rather than delete-row keeps
  the design narrow.)

The pattern is general enough that "outbound HTTP from a handler"
becomes one primitive, and most of what customers want to do with
HTTP-going-out (delays, retries, fanout, signing, workflows)
becomes JS they can read, debug, and customize.

---

## See also

- [`PLAN.md`](PLAN.md) §2.6 — the original webhook framing this
  supersedes.
- [`webhook-server-plan.md`](webhook-server-plan.md) — the
  webhook-specific subsystem this design replaces. Kept in tree for
  history; will be pruned after migration step 5.
- [`notifications.md`](notifications.md) — the customer-facing
  notifications channel. `http.send` and notifications cover
  different jobs (outbound vs inbound; durable scheduled vs
  ephemeral push); both compose well.
