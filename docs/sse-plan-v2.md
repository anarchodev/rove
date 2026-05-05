# SSE plan v2 — notification only, centralized service, response-attached emits

This document **supersedes** `docs/sse-plan.md`. The original plan
treated SSE events as source-of-truth state living in customer
`app.db` under reserved prefix `_events/{sid}/{seq}`, replicated
through raft, with a per-tenant retention sweep + reconnect catch-up
window. This plan replaces all of that with a much simpler model:

- **SSE is a notification channel, not a durable state store.** The
  customer's `app.db` is the source of truth; SSE events tell the UI
  "something changed, refetch what you need."
- **Events live on the response, not in storage.** `events.emit()`
  appends to an in-memory buffer on the request's execution context.
  After the kv writeset commits, the worker fires the buffer to a
  centralized sse-service.
- **sse-service is its own subsystem on its own subdomain
  (`sse.{public_suffix}`).** It owns every EventSource connection,
  the per-(tenant, sid) recent-event cache, and per-tenant
  connection caps. The worker has zero SSE connection state.
- **Single sse-service process per cluster** (the bet locked in
  conversation: customers fit on dedicated bare metal; multiraft is
  a future-problem horizon). Failover is "load balancer picks a new
  node, clients reconnect." Lost in-flight events are acceptable; a
  Last-Event-ID sentinel signals the client to refetch when cache
  history isn't available.

What's locked carries from the original plan: cross-tenant isolation
guarantees (sid namespacing, server-controlled session id assignment),
per-instance + per-session connection caps, rate limits on
`events.emit`, the deterministic event_id scheme. What's gone: the
`_events/{sid}/{seq}` storage layer, the retention sweep, raft
replication of SSE state, the persistent catch-up window.

---

## 1. Architecture

```
┌──────────────────┐  EventSource  ┌────────────────────────────────┐
│ customer browser │──────────────▶│ sse.{public_suffix}            │
│ (Last-Event-ID   │  with token   │  (sse-service — single process,│
│  on reconnect)   │  query param  │   own h2 listener, own TLS,    │
└──────────────────┘               │   per-(tenant, sid) ring cache)│
                                   └─────────────▲──────────────────┘
                                                 │ POST /v1/emit
                                                 │ {tenant, events[]}
                                                 │ (fire-and-forget,
                                                 │  worker → sse-service,
                                                 │  internal token)
                                                 │
┌──────────────────┐  HTTPS req    ┌──────────────┴─────────────────┐
│ customer browser │──────────────▶│ acme.loop46.me (worker)        │
│ (regular API)    │               │  - runs handler                │
└──────────────────┘               │  - events.emit() → emit_buffer │
                                   │  - kv writeset commits         │
                                   │  - POST emit_buffer to sse-svc │
                                   │  - returns response            │
                                   └────────────────────────────────┘
```

Three coupling channels, no cross-coupling between worker and
sse-service beyond the one outbound POST:

1. **Worker → sse-service:** `POST sse-internal/v1/emit`. Best-effort
   fire-and-forget after kv commit. Worker doesn't block the response
   on it.
2. **Customer browser → worker:** regular HTTPS requests on the
   customer subdomain. Worker terminates TLS, runs handler, returns
   response.
3. **Customer browser → sse-service:** EventSource on
   `sse.{public_suffix}`. sse-service terminates TLS, validates the
   token, holds the long-lived h2 stream.

Worker has no SSE connection state. sse-service has no kv access.
Neither knows the other's address beyond the outbound emit POST URL
(configured at worker startup).

---

## 2. Data model

### 2.1 Emit buffer (worker side, in-memory)

Lives on the request's execution context (the same struct that owns
the `TrackedTxn` and `WriteSet`). One buffer per request / trigger /
callback invocation:

```zig
const EmitBuffer = std.ArrayListUnmanaged(EmitEntry);

const EmitEntry = struct {
    /// {request_id:020d}-{call_index:06d} — deterministic from
    /// (request_id, call index within the request). Stable across
    /// tape replays.
    event_id: [27]u8,
    /// Customer-supplied "type" (defaults to "message").
    event_type: []u8,
    /// Customer-supplied payload, JSON-serialized.
    data_json: []u8,
    /// Target sids: defaults to [request.session.id]; can be a
    /// customer-supplied list of sids.
    target_sids: []const []const u8,
    /// Wall-clock at emit, for the sse-service ring cache.
    created_at_ms: i64,
};
```

The buffer is allocator-owned by the request's arena and freed when
the request completes. No persistence; no cross-request lifetime.

### 2.2 Wire format: worker → sse-service

`POST sse-internal/v1/emit` with `Authorization: Bearer <internal-token>`:

```json
{
  "v": 1,
  "tenant_id": "acme",
  "request_id": 1234,
  "events": [
    {
      "event_id":      "00000000000001234-000001",
      "type":          "comment_added",
      "data":          { "id": 99, "author": "alice" },
      "target_sids":   ["abc...sid-hex..."],
      "created_at_ms": 1730764800000
    },
    ...
  ]
}
```

Response: 204 No Content on success; non-204 is logged and ignored
by the worker (best-effort).

The internal token is a shared secret between worker and sse-service,
configured via env (`SSE_INTERNAL_TOKEN`) at startup. Rotated by
restarting both with a new value. mTLS is a possible future upgrade
when an operator wants stronger boundaries.

### 2.3 Recent-event ring cache (sse-service, in-memory)

Per-(tenant, sid) bounded ring:

```zig
const RingEntry = struct {
    event_id:       [27]u8,
    event_type:     []u8,
    data_json:      []u8,
    posted_at_ns:   i64,
};

// Per tenant: HashMap<sid, RingBuffer<RingEntry, RING_CAPACITY>>
// RING_CAPACITY = 30 entries per sid.
// Oldest evicted on overflow. Evicted entries are unrecoverable
// (reconnect with a Last-Event-ID older than the ring hits the
// sentinel path in §4.4).
```

Sized for brief reconnect catch-up (network blip, page hidden for
30s), not for backlog buffering. Math: a customer reconnecting
within 30s at 1 event/sec/sid (already a high notification rate)
sees 30 events — a 30-entry ring covers it. Anything longer hits
sentinel and the customer's UI refetches state, which is cheaper
than replaying minutes of stale notifications.

Memory bounds:

| Tier              | Conn cap | Per-tenant ring memory     |
|-------------------|----------|----------------------------|
| Free              | 100      | 100 × 30 × ~500B ≈ 1.5 MB  |
| Paid v1           | 1k       | 1k × 30 × ~500B ≈ 15 MB    |
| Pathological paid | 10k      | 10k × 30 × ~500B ≈ 150 MB  |

Comfortable on bare metal at any v1 scale. Revisit only if
measurement shows the ring eating real memory.

### 2.4 Connection table (sse-service, in-memory)

Per-tenant:

```zig
const Connection = struct {
    sid:             []const u8,
    h2_stream_ent:   rove.Entity,
    last_send_ns:    i64,
    last_event_id:   ?[27]u8, // most recent event delivered on this conn
};

// Per tenant: ArrayList<Connection>. Linear scan on emit (capped at
// per-tenant connection limit; ms scan time at any cap we'd allow).
```

---

## 3. Worker integration

### 3.1 `events.emit()` JS binding

Replaces the existing kv-write implementation. The new shape:

```zig
// src/js/bindings/events.zig (rewritten)

pub fn emit(...) {
    1. Validate args (existing logic for type/data/to/cap shapes)
    2. Resolve target sids (default = [request.session.id])
    3. Apply per-instance emit rate limit (existing)
    4. Build EmitEntry, append to ctx.emit_buffer
    5. Return undefined
}
```

Two writeset implications, both wins:

- **No reserved-prefix `_events/` writes.** The reserved-prefix guard
  in `reserved.zig` no longer needs the `_events/` entry. Customer
  JS may write to `_events/foo` if it wants; it has no special
  meaning. (The guard still protects `_outbox/`, `_deploy/`, etc.)
- **Writeset envelopes shrink.** Customer kv writeset envelopes
  (envelope type 0) stop carrying SSE rows. Replication bandwidth
  drops by however much SSE rows were contributing today (varies by
  tenant; for chat-heavy ones, meaningful).

### 3.2 `pumpEmitsForResponse` worker phase

New phase, runs after `dispatchOnce` and before the response is
flushed to the client:

```
For each just-completed request:
    if ctx.emit_buffer.items.len > 0:
        spawn fire-and-forget POST to sse-service:
            body = {tenant_id, request_id, events: emit_buffer}
            timeout = 1s (cap on how long the worker will wait
                          before logging + moving on)
        free emit_buffer (the POST takes ownership of a copy)
```

Implementation: an h2 client connection from the worker to
sse-service, parking the POST request in a `sse_emit_pending` queue
that drains independently of the request response. Worker sends the
client response immediately; the emit POST completes (or fails) on
its own timeline.

Key invariants:

- **Emit POST never blocks the client response.** Fire and forget;
  log on failure.
- **Emit POST happens after kv commit.** A failed kv write (raft
  rejected, conflict, etc.) means the customer's intended state
  change didn't happen — emitting an event "the thing changed!"
  would be a lie. Emit only on the successful-commit path.
- **Triggers and webhook callbacks fire too.** Their execution
  contexts also have emit_buffers; their completion paths invoke
  the same `pumpEmitsForResponse` (renamed `pumpEmitsForContext`
  if that's clearer).

### 3.3 What the worker no longer does

- `events_pump.zig` (777 lines) — gone. No connection management,
  no dirty-sid scan, no per-tenant `sse_connections` / `dirty_sids`.
- `events_sweep.zig` (365 lines) — gone. No retention sweep.
- `_events/` reserved prefix — removed from `reserved.zig`.
- `markDirtyFromWriteset` no longer scans for `_events/` keys.
- `/_events` route on the customer subdomain — moved to sse-service
  on `sse.{public_suffix}`.
- `EventsCaps` per-tenant config — moves to sse-service (the entity
  that enforces them). Caps stay; their enforcer changes.

---

## 4. sse-service

New module: `src/sse_server/` (mirrors `files_server/` and
`log_server/` shape). One process; own h2 server; own TLS listener
on `sse.{public_suffix}`.

### 4.1 Routes

```
GET  /v1/{tenant_id}/sse?token=<jwt>              ← EventSource connect
                       [?last_event_id=<id>]      (optional cursor)
                       [Last-Event-ID: <id>]      (header, EventSource standard)

POST /v1/emit                                     ← worker → sse-service
     Authorization: Bearer <internal-token>
     body: {v, tenant_id, request_id, events[]}

GET  /v1/health                                   ← LB health check
```

### 4.2 EventSource connect flow

```
1. Validate token (JWT signed by platform key; payload includes
   {tenant_id, sid, caps, exp}). Reject 401 on signature/expiry/
   tenant mismatch with URL path.
2. Check per-tenant connection cap (caps embedded in JWT, see §5.1).
3. Send response headers:
     200 OK
     Content-Type: text/event-stream
     Cache-Control: no-store
     X-Accel-Buffering: no
4. If Last-Event-ID present:
     if id in this sid's ring: replay events after id, then stream future
     if id not in ring (evicted, or sse-service restarted since):
        emit sentinel:
          event: rove:resync
          data:  {"reason": "events_evicted"}
        then stream future
5. Hold the h2 stream open. Send keepalive (`: keepalive\n\n`) every
   15s. On stream error / client disconnect: remove from connection
   table, free the connection record.
```

No CORS headers needed — EventSource opens with `withCredentials:
false` (auth is the JWT, not cookies), which makes it a "simple"
cross-origin request: no preflight, no `Access-Control-*` response
headers required, browser accepts events from any origin. Same code
path for `acme.loop46.me` customers and `acme.com` custom-domain
customers; sse-service doesn't need to know the origin.

**Token leakage hardening:** sse-service MUST strip `?token=` from
its access-log query string before logging. Standard concern with
token-in-query; bounded for SSE because EventSource URLs aren't
stored in browser navigation history and SSE responses don't
trigger sub-resource fetches (no Referer leaks). 1h token TTL +
`(tenant, sid)` scope further bounds blast radius.

### 4.3 Emit POST flow

```
1. Validate internal token. Reject 401 on mismatch.
2. For each event in body.events:
     append to (tenant, sid) ring cache (evict oldest if full)
     for sid in event.target_sids:
         look up sid in tenant's connection table
         if found:
             try to push SSE frame to h2 stream's stream_data_in
             if would-block (send buffer full):
                 increment connection.backpressure_strikes
                 if strikes >= MAX_STRIKES (5) within STRIKE_WINDOW (30s):
                     close the connection (client will reconnect → sentinel)
3. Respond 204.
```

The ring cache is updated regardless of whether a connection is
currently open — that's how a brief connect-window race is handled
(events posted before the connect arrives are cached and replayed
on catch-up). The cache update happens *before* the push attempt so
a slow consumer doesn't lose events from the ring; they only lose
the live push, which the next reconnect's catch-up replays.

**Backpressure rationale:** blocking the emit POST would create
head-of-line for other emits in the same batch and tie worker
threads to slow consumers — no. Dropping the connection on first
strike would over-react to transient slowness (window-resize lag,
GC pause) — no. Skip-with-strikes-counter bounds how far a slow
consumer can fall behind without forcing immediate disconnect on
hiccups: 5 strikes within 30s = "consistently can't keep up" → close
→ client reconnects → sentinel → refetch.

### 4.4 Sentinel event

Reserved event type `rove:resync` — the colon-namespace makes
collision with customer event types impossible (customer types are
free-form strings; the `rove:` prefix is reserved by convention,
documented in the customer-facing docs).

```
event: rove:resync
id: 00000000000000000000-000000
data: {"reason": "events_evicted", "advice": "refetch_state"}
```

Customer's UI listens for `EventSource.addEventListener('rove:resync', ...)`
and responds by refetching whatever state it cares about. Standard
pattern; documented as part of the SSE getting-started guide.

### 4.5 Per-tenant cap enforcement

Existing `EventsCaps` (in PLAN §2.12 and the original sse-plan) move
to sse-service:

- `max_concurrent_connections_per_instance` — checked at connect.
- `max_concurrent_connections_per_session` — checked at connect.
- `max_emits_per_request` — enforced *on the worker* still (it's a
  per-request limit; worker is the right gatekeeper).
- `max_event_payload_bytes` — enforced on the worker (rejects
  oversize at `events.emit` time).
- `retention_seconds` — replaced by ring buffer capacity. The
  "retention" concept goes away; the cache is purely for reconnect
  catch-up and is bounded by entry count, not time.

### 4.6 Failover model

Single process. If it dies:

- All EventSource connections die (TCP reset). Browsers auto-reconnect
  (EventSource standard behavior; default 3s reconnect delay).
- Reconnect lands on whatever sse-service is now answering the LB.
- New process has empty ring cache → any Last-Event-ID hits the
  sentinel path → clients refetch state → catch up.
- Worker emit POSTs during the dead window fail with connection
  refused → worker logs and drops → events lost (acceptable).

No election protocol, no state migration, no raft for sse-service.
Operator (or k8s, or systemd) handles "process died, restart it."

---

## 5. Authentication

### 5.1 EventSource auth: token handoff (cross-origin)

The customer's app on `acme.loop46.me` (or `acme.com`, custom
domain — same flow either way) opens an EventSource to a single
platform-managed hostname `sse.loop46.me`. **One TLS cert, one DNS
record, no per-tenant SSE subdomains, no SSE in custom-domain TLS
provisioning.** The JWT carries identity; `withCredentials` is
false, so no cookies cross origins and `__Host-` cookies stay
safely pinned to the customer's app domain.

```
1. Customer's JS code: fetch('/_session/sse-token')
     (same-origin to whatever domain the app is on; sends
      __Host-rove_sid cookie automatically)
     Response: { token: "<JWT>", expires_in: 3600 }

   The JWT is signed by the platform key, payload:
     {
       "v":         1,
       "tenant_id": "acme",
       "sid":       "<session id hex>",
       "caps":      { "max_conns_per_session": 5,
                      "max_event_payload_bytes": 65536,
                      ... },
       "exp":       1730768400
     }

2. Customer's JS code:
     const es = new EventSource(
       'https://sse.loop46.me/v1/acme/sse?token=' + token
     );

3. sse-service validates token signature + expiry + tenant_id ==
   URL path tenant. Opens stream.

4. Customer's JS code refreshes the token before expiry (e.g.,
   5min before exp) and reconnects with the new token. Or just
   lets the connection die and gets a fresh one — EventSource
   auto-reconnect handles it as long as the reconnect handler
   fetches a fresh token first.
```

The token endpoint `/_session/sse-token` is a new well-known route
on the customer's app domain (worker handles it via existing
custom-domain routing). Thin wrapper around the existing session
lookup: verifies the cookie, looks up the `EventsCaps` for the
session's plan tier, mints a JWT scoped to
`(tenant_id, sid, caps)`, returns it.

**Caps embedded in JWT, not queried per-connect.** Cap changes
propagate within `token_ttl` (1h default) when clients refresh.
Saves an HTTP roundtrip per connect; removes a sse-service →
worker dependency on the connect path (one fewer failure mode).
The 1h propagation delay is acceptable — caps are not a security
boundary that needs instant revocation; for emergency cap
tightening (e.g., abuse), revoking the session itself drops the
token's effective scope on next refresh.

### 5.2 Worker → sse-service auth: shared internal token

The internal `Authorization: Bearer <token>` between worker and
sse-service uses a static shared secret from `SSE_INTERNAL_TOKEN`
env, set identically on both. mTLS is a future upgrade when an
operator wants stronger isolation; v1 doesn't need it given the
internal-network deployment context.

---

## 6. What gets removed

- `src/js/events_pump.zig` — entire file.
- `src/js/events_sweep.zig` — entire file.
- `src/js/events.zig` — replaced by a much smaller stub if anything
  remains (the `/_events` route definition is gone; `EventsCaps`
  moves to sse-service).
- `src/js/bindings/events.zig` — rewritten to append-to-buffer
  instead of writing kv rows. ~80% smaller.
- `TenantFiles.sse_connections` field + supporting code.
- `TenantFiles.dirty_sids` field + supporting code.
- `markDirtyFromWriteset`'s `_events/` scan (the SSE-specific
  scanner; the `_deploy/` scanner stays per `files-server-plan.md`).
- `_events/` entry in `reserved.zig`.
- `pumpEvents`, `cleanupClosedSseConnections` worker phases.
- The SSE retention sweep timer (`next_sse_sweep_ns`).
- The `/_events` route on the customer subdomain.

---

## 7. Migration order

Because v1 SSE is shipping on the existing model, this is a rip-and-
replace rather than a blue-green migration. Suggested sequence:

1. **Stand up sse-service skeleton** (new module, new subdomain, TLS
   listener, just /v1/health responding). No behavior change in the
   worker yet.
2. **Implement the emit POST endpoint** + ring cache + connection
   table on sse-service. Add `/v1/{tenant}/sse` with token validation
   and basic streaming. Smoke: hand-craft an emit POST + open an
   EventSource against sse-service standalone.
3. **Add the worker → sse-service POST path** behind a feature flag
   (`sse.deliver_via = legacy | service`). Default stays `legacy`.
   Worker writes both kv rows AND fires the POST when `service` is
   selected (parallel run for safety).
4. **Add the token-handoff endpoint** `/_session/sse-token` on the
   worker. Customer admin UI updated to use it for SSE connects.
5. **Switch worker default to `service`**. Existing customers'
   EventSource clients continue hitting `/_events` on the customer
   subdomain (legacy worker route still wired) but new code paths
   are recommended to use the sse-service endpoint.
6. **Deprecate the worker `/_events` route** + the legacy code paths.
   Customers migrate over a deprecation window.
7. **Delete legacy code:** events_pump, events_sweep, kv-write path
   in the binding, reserved-prefix entry, dirty_sids machinery,
   sse_connections table, retention sweep timer, the
   `/_events` route handler.

Smokes at each step:
- Existing SSE smokes (cross-tenant isolation, end-to-end emit-and-
  receive, reconnect catch-up) get rewritten in step 2 to target
  sse-service directly. The reconnect-catch-up smoke specifically
  rewrites to "Last-Event-ID hits sentinel when ring is empty;
  hits replay when ring has the id."
- New smoke for the fire-and-forget worker → sse-service POST
  failure mode (sse-service down → worker continues serving requests
  fine, emits silently dropped).

---

## 8. Open questions / deferred

The bulk of the original v2 open questions are now resolved and live
in the relevant sections (ring sizing → §2.3; token-in-JWT auth +
single-hostname for all customers → §5.1; backpressure
skip-with-strikes → §4.3; emits-not-stored via determinism → §8.2
below). What remains:

### 8.1 Triggers and webhook callbacks wiring

Both have execution contexts; both can emit. Their completion paths
need to invoke `pumpEmitsForContext` the same way the request
handler path does. Concrete wiring is mechanical; the data model
(buffer on the context, fire POST after commit) is identical to the
request path. Implementation will likely live alongside
`trigger_dispatch.zig` and `dispatchCallbacks` — one call to the
pump after each successful commit.

### 8.2 Replay UI capture mode

Tape replay re-runs the handler, which means `events.emit` calls
happen during replay. The binding needs a "capture, don't fire"
mode for replay context — appends to a captured-emits list visible
in the replay UI sidebar but doesn't POST to sse-service. Hook
point is the same place tape replay already swaps in stub
implementations of other side-effect bindings (webhook.send, etc.).
Implementation detail; design is fine as is.

### 8.3 Future: pluggable emit transport

The worker-to-sse-service POST is a hard-coded HTTP call. If a
future deployment wants to skip sse-service entirely (single-binary
mode, embedded test mode, or a custom delivery target), the emit
sink could become an interface with HTTP as the v1 implementation.
Not needed for v1; flagged so the binding doesn't bake the URL
into too many places.
