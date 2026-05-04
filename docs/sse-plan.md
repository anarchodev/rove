# SSE plan (Phase 11 build-out)

This document expands `docs/PLAN.md` §2.12 + Phase 11 into an
implementable plan. It assumes the framing already locked in PLAN
(SSE-not-WebSockets, eager-mint platform cookie, `_events/{sid}/...`
rows in customer's `app.db`, single-node v1) and focuses on the two
questions that matter most before implementation:

1. **How is the session id assigned?** — tied to the platform cookie,
   not customer-chosen. Why, and what the customer-facing surface looks
   like.
2. **How is cross-tenant isolation guaranteed?** — what makes it
   structurally impossible for tenant B to deliver events to tenant A's
   SSE connections, plus the within-tenant authorization story (which
   is the customer's problem).

Then a sequenced implementation breakdown that fits inside Phase 11 of
PLAN, calling out the small gaps in the existing PLAN text.

---

## 1. Session id assignment

### 1.1 The choice: platform-managed, not customer-assigned

Two viable models exist. Both were considered; A is the locked design.

**A. Platform-managed cookie (locked).** Server eagerly mints an
opaque token on the first handler invocation that arrives without one,
sets it as `Set-Cookie`, and exposes it as `request.session.id` to JS.
The browser sends the cookie automatically on every subsequent request
including the `EventSource` connect. One id per (browser, tenant);
multi-tab works because all tabs share the cookie and each
`EventSource` opens its own underlying h2 stream.

**B. Customer-chosen ids.** Customer picks a string, opens
`EventSource('/_events?id=foo')`, and emits with `events.emit("foo",
...)`. Rejected because:

- Name collisions: two browsers reusing the same id silently merge
  streams.
- Auth coupling: now we need a connect-time auth handler to verify the
  client may claim id "foo." That's `_events/auth.mjs`, deferred per
  PLAN.
- More API surface for the customer (`subscribe(id)`, `unsubscribe(id)`,
  collision rules, multi-tab semantics) that real apps don't actually
  need v1.
- The "two logical streams per session" use case (different topics on
  different sockets) is solvable without it via `event:` types — see
  §1.5.

Within model A, "channels" / "topics" / "rooms" are deliberately a
customer-side composition (PLAN §2.12; `feedback_compose_from_primitives`).
Customer maintains their own subscription map (`subs/{post_id}/{sid}`)
and iterates on emit. Pre-launch we don't ship a topics primitive; it
hardens too many decisions about a poorly-understood domain.

### 1.2 Cookie shape

PLAN names the cookie `_rove_sess`. Recommend tightening to
**`__Host-rove_sid`**:

| Attribute | Value | Why |
|---|---|---|
| `__Host-` prefix | (in name) | Browser refuses to set unless `Secure` + no `Domain=` + `Path=/`; refuses to send cross-host. Catches misconfiguration at the browser. |
| Value | 64 hex chars (256 bits CSPRNG) | Unguessable. Cookie value IS the id — no server-side validation table (PLAN). |
| `HttpOnly` | yes | Customer JS can't read it. Receiver-side `events.subscribe` doesn't need to. |
| `Secure` | yes | Required by `__Host-`. `loop46.me` is HTTPS-only. |
| `SameSite=Lax` | yes | First-party + top-level navigation only; blocks CSRF-style cross-site reads. EventSource connects are first-party (same `{name}.loop46.me`) so this is fine. |
| `Path=/` | yes | Required by `__Host-`. |
| `Max-Age` | 1 year | Stable id across browser restarts; rotation is a v2 concern. |

The single underscore in `_rove_sess` is also fine, but `__Host-` is
free defense-in-depth. Adopt it unless there's a specific reason not to
(I don't see one).

### 1.3 Mint policy — when to set the cookie

A handler invocation that arrives *without* `__Host-rove_sid` and is
served by JS dispatch gets a fresh id minted and a `Set-Cookie` added
to the response. Specifically:

- **Static-asset path skips.** `_static/*` resolution short-circuits
  before JS dispatch; `favicon.ico` etc. don't pollute. (PLAN §2.4
  routing order already gives us this for free.)
- **System endpoints skip** unless they explicitly opt in.
  `/_system/*` admin paths are bearer-auth or admin-cookie; no
  `__Host-rove_sid` minting.
- **`/_events` connect mints if absent.** A programmatic client (CLI,
  test harness) connecting `/_events` without a cookie still gets a
  fresh id and a `Set-Cookie`. This is the only system endpoint that
  participates in mint.
- **`request.session.id` is `null` outside browser context.** Webhook
  callbacks, signup, system maintenance, sim/dry-run all see `null`.
  Implicit-target `events.emit("hi")` throws when null — explicit
  `to: sid` required.
- **Customer opt-out: `response.session = false`** (defer; not v1).
  Useful for pure-JSON APIs that don't want cookie noise. Skip until
  asked.

### 1.4 Surface in JS

```javascript
// Inside any browser-facing handler:
request.session.id      // string, 64 hex chars; eager-minted if absent
request.session         // null in non-browser contexts (callbacks, signup, ...)

events.emit("hello");                                 // current sid, type=message
events.emit({ data: { count: 42 }, type: "tick" });   // current sid, custom type
events.emit({ to: someSessionId, data: { ... } });    // explicit target
events.emit({ to: [sid1, sid2], data: { ... } });     // fan-out by enumeration
```

Returns the wire id of the emitted event (`{request_id}-{call_index}`)
for symmetry with `webhook.send`. Customers rarely need it but it
costs nothing.

Customer-supplied `id` is **rejected** — id derivation must remain
`request_id || call_index` for replay determinism. Customer-supplied id
breaks tape-replay.

### 1.5 "I want two logical streams"

Customer use case: the post page wants `comment_added` events; the
sidebar wants `notification` events. One session, two browser
components.

Solution: one EventSource, filter client-side by `event:` type:

```javascript
const es = new EventSource('/_events');
es.addEventListener('comment_added', e => updateComments(JSON.parse(e.data)));
es.addEventListener('notification', e => bumpBadge(JSON.parse(e.data)));
```

Server side: `events.emit({ data: comment, type: "comment_added" })`.

This avoids both "two cookies" (impossible) and "two connections per
tab" (browsers cap concurrent h2 streams; not worth burning two slots
when one works). If a customer hits a real wall here we revisit the
topics primitive — but the PLAN's "compose from primitives, defer
abstractions" rule applies.

---

## 2. Cross-tenant isolation

### 2.1 The threat

> Tenant B's handler tries to send events to tenant A's connected SSE
> clients.

Could happen because tenant B:

- Guesses or scans session ids.
- Receives a tenant-A sid through some leak (URL param, log scrape).
- Calls `events.emit({to: sidFromTenantA, data: "spoof"})`.
- Tries some lower-level mechanism that bypasses `events.emit`.

### 2.2 Defense — structural (the strong one)

**Storage scoping.** `events.emit` writes to `_events/{sid}/...` rows
in **the *current tenant's* `app.db`** via `state.txn` + `state.writeset`
— exactly the same path `webhook.send` uses to write `_outbox/{id}`.
There is no API that lets a JS handler in tenant B reach tenant A's
`app.db`. The kv handle in JS globals is bound to the dispatching
tenant's instance.

**Connection scoping.** A `GET /_events` request arrives on
`{name-A}.loop46.me`. Worker routes by host → tenant A. The pump for
tenant A reads only from tenant A's `app.db`. Tenant B's writes are
never even considered for that connection.

The two together mean that even if tenant B *guesses* the exact sid of
a tenant-A connection, the worst it can do is write
`_events/{that-sid}/...` rows into **its own** `app.db` — where no
SSE connection will ever read them, because tenant B has no
connections subscribed to that sid (no client ever set a
`__Host-rove_sid` for tenant B's host with that value), and tenant A's
connections only read from tenant A's db.

This is the same isolation model as kv (per-tenant SQLite file) and
webhooks (per-tenant outbox). SSE inherits it.

### 2.3 Defense — cookie scoping

`__Host-rove_sid` is host-bound (no `Domain=` allowed under
`__Host-`). A browser that holds tenant A's cookie does **not** send it
to tenant B's subdomain. Each tenant the user visits gets its own
distinct cookie and its own distinct sid. Tenant B never observes
tenant A's sid through normal browser flow.

### 2.4 Defense — close the kv-write gap

**Current bug to fix as part of Phase 11.** `jsKvSet` /  `jsKvDelete`
in `src/js/globals.zig:227-313` do **not** check the
`PLATFORM_KV_PREFIXES` table. The reserved-prefix guard at
`src/js/worker.zig:176` is only for trigger *registration* prefixes,
and `PLATFORM_KV_PREFIXES_FIRE` in `src/js/trigger_dispatch.zig:35` is
only for the trigger fire-time skip.

This means today a customer can write `kv.set("_outbox/mine", "...")`
or `kv.set("_events/spoof/0001-000001", "...")` directly via `kv.set`.
For outbox that's a latent footgun (drainer would try to deliver). For
events it would let the customer:

- Spoof past events on their own SSE connection (rewriting history).
- Bypass the per-request cap and replay-determinism story.
- Fake monotonic ordering by inserting low-id rows.

It's not a cross-tenant exploit (still scoped to the customer's own
db), but it IS a within-tenant integrity problem and an API-shape
inconsistency. Fix:

```zig
// In jsKvSet / jsKvDelete, before state.txn.put / .delete:
if (isCustomerWriteReserved(key_str)) {
    _ = c.JS_ThrowTypeError(ctx, "kv.set: '%s' is a platform-reserved prefix", key_str.ptr);
    return js_exception;
}
```

`isCustomerWriteReserved` is the existing `PLATFORM_KV_PREFIXES` check
restricted to keys starting with one of `_outbox/ _outbox_inflight/
_dlq/ _callback/ _events/ _audit/ _deploy/ _magic/ _sessions/`. Note
that `_triggers/` is *not* in this list — the trigger files are
manifest entries, written through the files-server deploy path, not
through customer-runtime `kv.set`. `_triggers/` does not currently
appear as a key in `app.db` at all.

This belongs in Phase 11 because the SSE story relies on it, but it's
a one-screen fix that should land first as a standalone PR — its
absence is a footgun for the *existing* `_outbox/` and `_callback/`
namespaces too.

### 2.5 Within-tenant authorization

Once cross-tenant is structurally prevented, "is this customer-user
allowed to receive this event" becomes the *customer's* problem. The
platform deliberately does not ship:

- A "is sid X authenticated as user Y" lookup primitive.
- A connect-time `_events/auth.mjs` handler (deferred per PLAN).
- A "deny-by-default" policy on `events.emit({to: ...})`.

Because the customer's domain shape is what determines "should this
event go here" — per-post, per-team, per-room — and any platform
opinion would be wrong for somebody.

What the platform DOES give the customer:

- `request.session.id` and an eagerly-minted cookie so customer can
  bind `kv.set("sessions/${sid}/user", userId)` at login.
- `events.emit({to: sid})` with no further checks (customer is
  responsible).
- Composable kv prefixes (`subs/{post_id}/{sid}`) for fan-out.

Documented anti-pattern: **don't trust client-supplied sids in request
bodies for fan-out targets without verification.** A customer who lets
`POST /chat` accept `{to_session: ...}` and emits there directly has
built a within-tenant spam vector. They must look up the relevant set
of sids server-side. Worth a paragraph in customer docs.

### 2.6 Pump cross-check

Belt-and-suspenders even though §2.2 is the real defense: the pump
that reads `_events/{sid}/...` rows for a given connection should
match `sid` exactly against the connection's `EventsSession.sid`
component. Defense-in-depth against future bugs that cross-link
connection tables across tenants. Single-tenant pump means the prefix
scan already filters by sid — explicit assertion costs nothing.

---

## 3. Implementation phases

Within PLAN's Phase 11. Each sub-phase is its own commit / PR.

### 11a. Platform `kv.set` reserved-prefix guard (prerequisite)

Standalone PR, before any SSE code. Fixes the gap in §2.4.

- Add `isCustomerWriteReserved(key)` helper next to `PLATFORM_KV_PREFIXES`.
- Apply in `jsKvSet`, `jsKvDelete`.
- Also apply in any other customer-runtime write path
  (`platform.root.set` in admin context already has its own guard;
  audit `webhook.send` for completeness — it's a platform write
  through `state.txn.put` that bypasses `jsKvSet`, which is the
  intended pattern).
- Tests:
  - `kv.set("_outbox/x", "v")` → throws.
  - `kv.set("_events/sid/0001", "v")` → throws.
  - `kv.set("users/sessions/abc", "v")` → succeeds (only `_*` prefixes
    are reserved).
  - `webhook.send` still works (it uses `state.txn.put` directly,
    bypassing the guard — which is the intended platform-write path).

### 11b. Cookie mint + `request.session`

- New helper in `src/js/dispatcher.zig` (or `src/js/auth.zig` for
  symmetry with `extractAdminAuth`):

  ```zig
  pub fn ensureSessionCookie(
      hdrs: ?h2.ReqHeaders,
      rng: anytype,
      buf: *[64]u8,
  ) struct { sid: [64]u8, mint_set_cookie: bool } { ... }
  ```

  Reads `__Host-rove_sid`; if absent, mints from `rng`; returns the
  resolved sid plus a flag for "caller should append a Set-Cookie."
- Plumb through `Request` — add `session_id: ?[64]u8 = null`. Caller
  populates from `ensureSessionCookie` on browser-facing dispatches
  (skip on internal callback dispatch, signup, etc.).
- `installRequest` in `src/js/globals.zig:994` exposes:

  ```js
  request.session = {id: "<64 hex>"};   // or null when not set
  ```
- Response post-processing: if `mint_set_cookie` was true, append
  `Set-Cookie: __Host-rove_sid=<sid>; Secure; HttpOnly; SameSite=Lax;
  Path=/; Max-Age=31536000` to the response. Adjacent to the existing
  `set_cookies` array in `Response`, but separately tracked so it's
  always platform-controlled (no sanitization needed; the value is
  64 hex chars by construction).
- Tests:
  - First request → `Set-Cookie: __Host-rove_sid=<64 hex>` in
    response, `request.session.id` is the same 64 hex.
  - Subsequent request with the cookie → no `Set-Cookie`,
    `request.session.id` matches.
  - Static-asset path → no `Set-Cookie`.
  - `/_system/*` with bearer auth → no `Set-Cookie`.
  - Internal callback dispatch → `request.session` is `null`.

### 11c. `events.emit` JS binding

- New file `src/js/bindings/events.zig`. Pattern mirrors
  `webhook.zig:124` (`jsWebhookSend`).
- Per-request counter: add `events_call_index: u32 = 0` to
  `DispatchState` (parallel to `webhook_call_index`).
- Key encoding: `_events/{sid}/{request_id:020d}-{call_index:06d}`.
  Zero-pad to 20 / 6 digits so lexical order = numeric. (20 fits any
  u64; 6 fits the per-request emit cap of 1000 with headroom.)
- Argument handling:
  - `events.emit("text")` → `{data: "text", type: "message",
    to: [request.session.id]}`. Throws `Error{code:"no_session"}` when
    `request.session === null`.
  - `events.emit({data, type?, to?})` — `to` defaults to current sid;
    accepts string (single sid) or array of strings (fan-out).
  - Reject customer-supplied `id`.
  - Reject empty `to` array when explicit.
- Envelope (JSON) written to `_events/{sid}/{key}`:

  ```json
  {
    "v": 1,
    "id": "{request_id}-{call_index}",
    "type": "message" | "<custom>",
    "data": <any JSON value>,
    "created_at_ms": <epoch ms>,
    "parent_request_id": <u64>
  }
  ```

  Same `v: 1` versioning convention as `webhook.send`.
- Per-request emit cap (`events_call_index >= caps.max_emits_per_request`)
  → throws `Error{code:"events_cap_exceeded"}`.
- Per-emit payload size cap (envelope JSON length) → throws.
- Returns the wire `id` string to the caller.
- Writes via `state.txn.put` + `state.writeset.addPut` exactly like
  `webhook.send`. Tape capture is automatic (the kv tape sees the put).
- Tests:
  - String form, default sid.
  - Object form, custom type, default sid.
  - Explicit `to: sidB` from current sid `sidA` — write lands at
    `_events/sidB/{key}` (proves cross-target works).
  - Array `to: [a, b]` — N writes land at `_events/{each}/{key}`.
  - `events.emit("hi")` when `request.session === null` → throws.
  - Cap exceeded → throws.
  - Replay determinism: same inputs → same envelopes byte-for-byte.

### 11d. `/_events` system endpoint + handler-side bootstrap

- Carve `/_events` out as a system endpoint in the dispatcher router.
  (Mechanically similar to the `/_system/*` carve-out but case-by-case;
  `/_events` is the only one in this family.)
- Handler, in `src/js/worker.zig` or a new `src/js/events_endpoint.zig`:
  1. Resolve host → tenant. 404 if unknown.
  2. Call `ensureSessionCookie` — sid + maybe-mint flag.
  3. Read `Last-Event-ID` header; fall back to `?since=<id>`; default
     `00000000000000000000-000000` (i.e. start from the beginning of
     retention).
  4. Set response status 200 and headers:

     ```
     content-type: text/event-stream; charset=utf-8
     cache-control: no-store
     x-accel-buffering: no
     ```

     If minting, also append `Set-Cookie: __Host-rove_sid=...`.
  5. Cap check: instance has `concurrent_connections >=
     caps.max_concurrent_connections_per_instance` → 503. Same for
     per-session.
  6. Insert entity into `events_connections` with components below.
  7. Move entity from `request_out` → `stream_response_in`.

- New collection `events_connections` (held alongside h2 collections,
  managed by the SSE pump; uses the existing h2 stream's StreamId +
  Session components plus events-specific ones). Components:

  ```zig
  const EventsSession = struct {
      sid: [64]u8,
      instance_id: []const u8,   // borrowed from TenantFiles
  };
  const EventsLastEventId = struct {
      id: [27]u8,                // "{request_id:020d}-{call_index:06d}"
  };
  const EventsKeepalive = struct {
      last_send_ns: i64,
  };
  ```

- Tests:
  - Connect → returns `200 text/event-stream` with `Set-Cookie` if
    no cookie.
  - Connect with cookie → no `Set-Cookie`.
  - Connect with `Last-Event-ID: <id>` → entity created with that
    `last_event_id`.
  - Connect when at per-instance cap → 503.

### 11e. Pump (`pumpEvents`)

- New system in `src/js/worker.zig` (or `events_pump.zig`), called
  between `poll()` and `reg.flush()` like other systems.
- **Dirty-marked** per §4.1: `TenantFiles` gains a
  `dirty_sids: std.AutoHashMapUnmanaged([64]u8, void)` field. After
  every successful commit (handler / callback / trigger) the worker
  inspects the writeset for `_events/{sid}/...` keys and inserts
  matching sids — but only for sids that have at least one connection
  in the per-tenant connection index, so emits that no one's listening
  for cost zero pump work.
- Each tick:
  1. For each tenant, iterate `dirty_sids`. For each sid, look up
     connections (per-tenant `sid → [entity]` index) and
     `prefix("_events/{sid}/", last_event_id, BATCH_LIMIT)` —
     `BATCH_LIMIT=32` per connection per tick for fairness.
  2. After the pass, clear processed sids from `dirty_sids`.
  3. Independent keepalive cycle: iterate ALL connections (not just
     dirty), emit `:ping\n\n` to anything quiet > 25s. Cheap (one
     timestamp compare per connection).
- **Cold-start / reconnect always full-scans** from
  `last_event_id`. Subsumes any dirty-mark loss after worker crash.
- For each row in the prefix scan: format as SSE wire frame:

     ```
     id: {key_suffix}
     event: {envelope.type}
     data: {envelope.data as JSON}

     ```

     (Multi-line `data:` for newline-containing payloads if needed;
     v1 single-line JSON-stringified.)
  3. Append wire bytes to a buffer; advance `last_event_id`.
  4. If buffer non-empty: set `RespBody`, move entity into
     `stream_data_in`. Update `last_send_ns`.
  5. Else if `now - last_send_ns > 25_000_000_000` (25s): emit
     `:ping\n\n`, move into `stream_data_in`, update timestamp.
- On disconnect (entity drops via `stream_close_in`), the events_connections
  cleanup hook removes the entity from the table.
- `Last-Event-ID < oldest retained` boundary: if first batch fetch
  returns rows whose smallest key > `last_event_id + 1` (i.e. there's
  a gap), prepend a synthetic `event: rove_gap\ndata: {...}\n\n` frame
  before catch-up. Lets the customer's client decide what to do
  (resync, reload, etc.). Detail to specify when implementing — could
  also defer to v2 by just delivering-from-oldest.
- Tests:
  - Emit → connected client receives within one tick.
  - Two emits → client receives both in order.
  - Reconnect with `Last-Event-ID: <last_received>` → resumes from
    next event.
  - 25s of no emits → client receives `:ping`.

### 11f. Caps + plan-tier wiring

- `EventsCaps` struct (extended per §4.2 with rate-shape fields) +
  `eventsCapsForPlan(plan)` per PLAN §2.12.
- **Hard caps:**
  - Per-instance and per-session connection counters (atomic, per
    tenant). Decrement on disconnect. At-capacity → 503 on connect.
  - Per-request emit counter from §11c. Exceeded → throws
    `Error{code:"events_cap_exceeded"}`.
  - Per-emit payload byte cap. Exceeded → throws.
- **Rate caps (new):**
  - Add `events_emit`, `events_connect`, `events_bytes_out` actions
    to `RateLimiter` (`src/js/limiter.zig`).
  - `events.emit` JS binding calls
    `limiter.tryTake(.events_emit, 1)` before serializing; empty
    bucket → throws `Error{code:"rate_limited"}` (same shape as the
    existing email rate-limiter).
  - `/_events` connect handler calls
    `limiter.tryTake(.events_connect, 1)`; empty → 429 with
    `Retry-After`.
  - Pump calls `limiter.tryTake(.events_bytes_out, frame_len)`
    before each wire write; empty → skip this connection this tick,
    sid stays in `dirty_sids` for next tick.
- Tests: hitting each cap returns the documented response. Rate caps
  recover after `1 / rate_per_sec` seconds.

### 11g. Retention sweep (`pruneEvents`)

- Periodic per-tenant sweep, every 60s, called from the worker poll
  loop. Bounded per pass (1000 row deletes max) so it never starves
  request handling.
- Walks `_events/` prefix; deletes rows with `created_at_ms <
  now_ms - retention_seconds * 1000`. Bound check on count.
- **Replication question to resolve before merging:** does the sweep
  propose through raft, or run independently on each node?
  - Independent: simpler, but two nodes might GC at slightly
    different watermarks → diverged kv state in transient windows.
  - Replicated: leader-only sweep, deletion writeset proposes through
    raft. Symmetric apply on followers. Slightly more replication
    traffic. **Recommended.** Same shape as outbox row deletes.
- Tests:
  - Insert event with `created_at_ms` long past retention → sweep
    deletes it.
  - Recent event survives.
  - Cap on rows-per-pass respected when there's a backlog.

### 11h. Cross-tenant isolation tests

Concrete tests written explicitly to lock the structural argument from
§2:

- **Test 1 — emit `to:` cross-tenant sid lands in own db.** Tenant B
  handler runs `events.emit({to: "<sidA-value>", data: "spoof"})`.
  Assert: write lands at `tenant_b/_events/<sidA-value>/...`. Assert:
  no row appears in `tenant_a/_events/`.
- **Test 2 — connection on tenant A doesn't receive tenant B's
  emits.** Set up a real SSE connection on `{name-A}.loop46.me` with
  sid `S`. Have tenant B `events.emit({to: "S", data: "spoof"})`.
  Wait one pump tick. Assert: tenant A's client received nothing.
- **Test 3 — `__Host-rove_sid` is not sent cross-host.** Cookie
  set with `__Host-rove_sid=X` on `tenant-a.loop46.me`. Request to
  `tenant-b.loop46.me` without explicit cookie. Assert: dispatcher
  sees no cookie on the tenant-B request and mints a fresh sid.
- **Test 4 — kv reserved-prefix guard fires.** Customer
  `kv.set("_events/sid/0001-000001", "spoof")` → throws (covers §2.4
  fix from 11a, lock as regression).

### 11i. Smoke + bench

- `scripts/sse_smoke.sh`: deploy a handler that emits a counter on
  every GET; open EventSource against `/_events`; assert ordering
  and id format; reconnect with `Last-Event-ID` and assert resume.
- `scripts/sse_bench.sh` (could be deferred): N concurrent EventSource
  connections each receiving M events/sec, watch CPU + memory + tail
  latency. Target: 1000 connections × 10 events/sec on a single
  worker without falling behind.

---

## 4. Decisions (resolved 2026-05-03)

1. **Cookie name: `__Host-rove_sid`.** Update PLAN §2.12 and Phase 11
   text from `_rove_sess`.
2. **Pump iteration: dirty-marked, in-process.** See §4.1.
3. **`Last-Event-ID` < oldest-retained: synthetic `event: rove_gap`
   frame** before catch-up. Customer's client decides what to do.
4. **Retention sweep: raft-proposed deletes.** Leader-only sweep,
   deletion writeset replicates. Not a high-volume path — typical
   sweep at 60s intervals deletes ~retention-window-ms / 60s rows per
   pass, and most tenants have zero events to sweep.
5. **Single-node only for v1.** Multi-node deferred; Phase 11i tests
   document the gap loudly.
6. **No customer opt-out for cookie mint.** Cookie is universal on
   handler invocations. Customers who want a cookieless JSON API can
   ignore `request.session` and not call `events.emit`; the
   `Set-Cookie` overhead is one HTTP header.
7. **Rate-limiting hooks for SSE.** New limiter actions on the
   existing `RateLimiter`. See §4.2.

### 4.1 Dirty-marked pump (resolves #2)

The webhook drainer (`src/outbox/drainer.zig:25`) iterates every known
tenant every 250ms and notes a planned slice-3b optimization: a
`__root__/outbox_pending/{instance}` marker key the drainer consults
first, opening tenants only when there's work. SSE can do better than
that because the pump runs **in-process with the dispatcher**, not on
a separate thread reading from disk.

**Design:**

- Each `TenantFiles` (per-tenant worker state) gets a small in-memory
  `dirty_sids: std.AutoHashMapUnmanaged([64]u8, void)` — set of sids
  with new events since the last pump.
- After every successful handler / callback / trigger commit, the
  worker inspects the writeset for keys matching `_events/{sid}/...`,
  extracts the sid, and inserts into `dirty_sids`. This is one
  hashmap insert per `events.emit` call (the writeset already has the
  keys in hand — no extra scan needed).
- `pumpEvents` iterates `dirty_sids` per tenant. For each sid, look up
  the matching connection entities in the per-tenant connection
  index, prefix-scan `_events/{sid}/` from `last_event_id`, write to
  wire. After a successful pass, clear the sid from `dirty_sids`.
- Tenants with no `dirty_sids` and no keepalive due → zero work.
  Tenants with no connections at all → never get added to
  `dirty_sids` in the first place (the writeset-inspect step skips
  the insert when there's no connection table entry for that sid).

**Why this beats the webhook-drainer marker pattern here:** the
webhook drainer is a separate thread that reads marker keys from kv
because it doesn't share memory with the dispatcher. SSE pump runs in
the same worker thread as dispatch, so we can use a plain in-memory
hashmap and skip the kv round-trip entirely. The "dirty" signal is
already in our hand at commit time.

**Failure mode:** if the worker crashes between commit and pump, the
write replicated through raft and is durable, but the pump never saw
the dirty mark. Recovery: on connection establishment (or reconnect),
the pump always does one full `_events/{sid}/` scan from the
connection's `last_event_id` to catch up — which subsumes any
dirty-mark loss. Steady-state pump is dirty-driven; cold-start /
reconnect is full-scan. Same pattern as the webhook drainer's startup
recovery.

**Keepalive cycle:** runs independently of `dirty_sids`. Every tick,
iterate `events_connections` and emit `:ping\n\n` to anything quiet
> 25s. Cheap (timestamp compare per connection) — at 10k connections
that's a 10k-element loop per tick, fine.

### 4.2 Rate-limiting hooks (resolves #7)

The existing `src/js/limiter.zig` `RateLimiter` already gates
`request`, `email`, `webhook_attempt` etc. with token-bucket caps per
`(instance, action)`. SSE adds three new actions:

| Action | What it gates | Tier defaults |
|---|---|---|
| `events_emit` | Each `events.emit` call (counts 1, regardless of fan-out cardinality — explicit `to: [a, b, c]` is one emit, three writes). Throws `Error{code:"rate_limited"}` from JS when bucket empty, same shape as the email rate-limiter today. | Free: 100/s burst 200; Paid: 10k/s burst 20k. |
| `events_connect` | Each new `GET /_events` connection establishment. Returns 429 when bucket empty. Defends against connection-churn DoS (open/close/open/close). | Free: 5/s burst 20; Paid: 100/s burst 500. |
| `events_bytes_out` | Bytes the pump writes to wire per instance. Token = 1 byte. Consumed by pump before each write; when bucket empty, the pump skips that connection this tick (events queue locally, deliver next tick when bucket refills). Defends against high-volume per-event payloads bypassing the per-emit count. | Free: 64 KB/s burst 256 KB; Paid: 4 MB/s burst 16 MB. |

`events_emit` and `events_connect` slot into the existing
`limiter.tryTake(.{instance, .events_emit})` shape. `events_bytes_out`
is the new one — it's the first action the pump itself consumes (vs
handler-driven), so the bucket is checked from `pumpEvents` rather
than from a JS binding.

**Hard caps (already in PLAN §2.12) stay separate from rate caps.**
`max_concurrent_connections_per_instance` is a hard ceiling, not a
token bucket — at-capacity returns 503 immediately. The token-bucket
caps shape *throughput*; the hard caps bound *resource usage*.

**Cap struct extension:**

```zig
pub const EventsCaps = struct {
    // Existing hard caps (PLAN §2.12)
    max_concurrent_connections_per_instance: u32,
    max_concurrent_connections_per_session: u32,
    max_emits_per_request: u32,
    retention_seconds: u32,
    max_events_per_session_in_retention: u32,
    max_event_payload_bytes: u32,

    // New rate-shape caps (§4.2)
    emit_rate_per_sec: u32,        // events_emit token bucket fill rate
    emit_rate_burst: u32,          // bucket size
    connect_rate_per_sec: u32,
    connect_rate_burst: u32,
    bytes_out_per_sec: u32,        // events_bytes_out fill rate
    bytes_out_burst: u32,
};
```

Plan-tier defaults set in `eventsCapsForPlan(plan)`. Same shape as
existing per-action limiter caps, so growing more limits later
(e.g. `events_pump_cycles_per_sec`) is one-line additions.

**Sub-phase 11f wiring:** when adding the cap struct, also wire the
three new limiter actions into `RateLimiter.init` / per-tenant
buckets. The `events.emit` JS binding from §11c calls `limiter.tryTake`
before serializing; the pump calls `tryTake(.events_bytes_out, len)`
before writing.

---

## 5. What the customer-facing docs need to say

Once this lands, the SSE/events docs page must cover:

- **Cookie is platform-managed.** Customers don't pick session ids;
  read `request.session.id`.
- **Default-target emit.** `events.emit("text")` goes to the current
  request's session.
- **Fan-out is the customer's job.** Maintain your own `subs/...` map
  in kv; iterate on emit. With one example pattern (per-room chat,
  per-post comments) showing the recipe.
- **Authorization is the customer's job.** Don't trust client-supplied
  sids in request bodies; look up the relevant set server-side.
- **One connection per browser, multiple `event:` types.** Filter
  client-side; don't try to open two `EventSource` per session.
- **Replay determinism.** `events.emit` is captured in the tape — the
  *commands* replay, not the actual delivery. Customers debugging in
  DevTools see the emit fire on the same line, with the same envelope.
- **Caps.** Document the per-plan numbers from PLAN §2.12.
