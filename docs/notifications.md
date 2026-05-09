# Notifications

Rove gives your handler a single way to tell a browser "something
happened, here it is": `events.emit({to, type, data})`. The browser
subscribes with `rove.events.subscribe()` and sees the events as they
fire. Same primitive lights up live order updates, multi-tab sync,
chat, presence, real-time dashboards, and async-to-sync recipes like
"call Stripe and resolve a promise when the response comes back."

This document is the customer-facing reference. The internal
architecture (sse-server, ring caches, token mint, raft hop) lives in
[`sse-plan.md`](sse-plan.md) — you don't need to read it to use this.

---

## The shape

**Server (your handler):**

```js
events.emit({
  to:   request.session.id,    // sid string, or array of sids for fan-out
  type: 'order.paid',          // free-form string; you choose the type names
  data: { orderId: 'o-42', total_cents: 9900 },
});
```

`events.emit` is a Cmd — it accumulates on the request's execution
context and fires after your kv writeset commits. Ids are
deterministic across replays. See the runtime reference for the full
options shape (rate-limit, fan-out caps).

**Browser:**

```html
<script src="/static/rove.js"></script>
<script>
  const events = await rove.events.subscribe();

  events.on('order.paid', (e) => {
    console.log('Paid:', e.data.orderId, e.data.total_cents);
    refreshUi();
  });
</script>
```

`subscribe()` mints a session-scoped JWT against your app domain
(`/_session/sse-token`), opens an `EventSource` to the platform's
notifications channel, and dispatches incoming events to your
handlers. The token + URL come back from a single fetch — the browser
doesn't need to know the SSE host.

---

## What you should know

**Notifications are not a durable store.** Your `kv` is the source of
truth. An event tells the browser "go look" or carries the new state
opportunistically; on disconnect or restart, the browser refetches
state from your handlers. When sse-server fails over, the browser
gets a `rove:resync` event — see "Recovering from disconnect" below.

**Sessions are per-browser, not per-user.** `request.session.id` is
a 64-hex cookie value. If a single user is logged in across two
laptops, that's two sessions; an emit to one sid lands on one
browser. Customers who want multi-device fan-out maintain their own
`(user_id → [sid, ...])` index in kv and pass `to: [...sids]`.

**Failure model is explicit.** The browser's EventSource can drop
(network blip, tab backgrounded, sse-server failover) — this is
visible to your code, not hidden. Plan for it: write the new state to
kv inside the same handler that emits, then let the browser refetch
on `rove:resync` or stale-state checks.

---

## Recipes

### 1. Live updates

Standard pub/sub. Server emits when anything interesting happens; the
browser updates the UI in place.

```js
// handler: /api/comments/post.mjs
export default async function () {
  const c = JSON.parse(request.body);
  kv.set(`comments/${c.id}`, JSON.stringify(c));
  events.emit({
    to: request.session.id,
    type: 'comment.added',
    data: c,
  });
  return { status: 200, body: '{"ok":true}' };
}
```

```js
// browser
events.on('comment.added', (e) => appendComment(e.data));
```

### 2. RPC-with-correlation-id (Stripe Checkout, etc.)

For "browser kicks off an external call, then waits for the result"
flows. The handler can't synchronously await Stripe — it dispatches a
`webhook.send` with a callback, and the callback fans the response
back via `events.emit`. The browser uses `waitFor` to bridge the
two.

```js
// browser
const correlationId = crypto.randomUUID();

// Subscribe before initiating so we don't race the response.
const checkoutPromise = events.waitFor(
  'checkout.created',
  e => e.data.correlation_id === correlationId,
  { timeoutMs: 30_000 },
);

await fetch('/api/checkout/start', {
  method: 'POST',
  body: JSON.stringify({ items, correlation_id: correlationId }),
});

const checkout = await checkoutPromise;
window.location = checkout.data.stripe_url;
```

```js
// handler: /api/checkout/start.mjs
export default async function () {
  const body = JSON.parse(request.body);
  webhook.send({
    url:      'https://api.stripe.com/v1/checkout/sessions',
    method:   'POST',
    headers:  { Authorization: `Bearer ${kv.get('_secrets/stripe_key')}` },
    body:     stripeCheckoutBody(body.items),
    callback: 'on_stripe_checkout',
    context:  { sid: request.session.id, correlation_id: body.correlation_id },
  });
  return { status: 202, body: '{"queued":true}' };
}

// callback: /api/checkout/on_stripe_checkout.mjs
export function on_stripe_checkout(event) {
  const { sid, correlation_id } = event.context;
  const stripe = JSON.parse(event.body);

  // Persist to kv FIRST so a refresh / disconnect can recover via a
  // GET. The notification is the fast path; kv is the safety net.
  kv.set(`checkouts/${correlation_id}`, JSON.stringify({
    stripe_url: stripe.url,
    session_id: stripe.id,
  }));

  events.emit({
    to:   sid,
    type: 'checkout.created',
    data: { correlation_id, stripe_url: stripe.url, session_id: stripe.id },
  });
}
```

The `correlation_id` lets the same browser kick off multiple
checkouts in parallel without aliasing. Time out after 30s and let
the browser fall back to polling the kv-backed result endpoint —
covered next.

### 3. Recovering from disconnect (`rove:resync`)

When the EventSource drops past the platform's reconnect window
(currently 30 events per session), sse-server emits a `rove:resync`
sentinel on reconnect. Treat it as "I might have missed something —
refetch what I care about."

```js
events.on('rove:resync', () => {
  // Recover anything that was in flight. The customer chose what
  // "in flight" means — here we re-poll any pending checkouts.
  for (const id of pendingCheckouts) {
    fetch(`/api/checkouts/${id}`).then(r => r.json()).then(applyResult);
  }
});
```

The handler that backs `/api/checkouts/:id` reads from the kv key
the callback wrote. Same path your `waitFor` timeout fallback should
use.

### 4. Multi-tab sync

Open one EventSource per tab, emit to the session id, every tab gets
it. No special code on either side.

```js
// All tabs of the same browser run:
const events = await rove.events.subscribe();
events.on('todo.changed', e => mergeTodo(e.data));
```

```js
// Any handler that mutates a todo:
events.emit({ to: request.session.id, type: 'todo.changed', data: todo });
```

The cookie scopes the session id; sse-server delivers to every open
EventSource with that sid. Tab that originated the change receives
its own emit too — the trivial filter is `if (e.data.editorId ===
myEditorId) return`.

### 5. Fan-out to a group of users

Server-side, look up the sids you want and pass them as an array.

```js
const memberSids = JSON.parse(kv.get(`teams/${team_id}/sids`)) || [];
events.emit({
  to:   memberSids,
  type: 'team.message',
  data: msg,
});
```

The fan-out cap is per-tier (free plan: 100 targets per emit).

---

## API reference

### Server

`events.emit({to, type?, data?})`

| field | shape | default |
|---|---|---|
| `to`   | sid string, or array of sid strings | `request.session.id` |
| `type` | string                              | `"message"` |
| `data` | any JSON-serializable value         | `null` |

Returns the deterministic event id (`{request_id}-{call_index}`).
Throws `Error{code: "events_cap_exceeded"}` if you exceed the
per-request emit cap or the per-event payload size.

### Browser

`rove.events.subscribe(opts?) → Promise<RoveEvents>`

Mints the token and opens the notifications channel. `opts.tokenPath`
overrides the default `/_session/sse-token` if your app routes the
mint somewhere else.

`events.on(type, handler) → unsubscribe`

`handler` receives `{type, id, data}`. Returns a function that
removes the subscription.

`events.waitFor(type, predicate, {timeoutMs?}) → Promise<event>`

Resolves to the next event of `type` for which `predicate(event)`
returns true. Rejects on timeout. The promise rejects with `'rove
client closed'` if you `close()` while it's pending — wrap in
try/catch if that matters.

`events.close()`

Closes the EventSource and rejects every pending `waitFor`. Call on
page unload if you care about the open connection count.

`'rove:resync'` is a reserved event type the platform emits after a
forced reconnect (server failover, ring eviction past your last seen
event). Subscribe to it and refetch state.

---

## Error model cheatsheet

| What happens | What you do |
|---|---|
| Browser tab closes mid-flight | Server-side write completed (raft committed). Recover on next page load by reading from kv. |
| EventSource drops briefly | `rove.js` reconnects automatically; recent events come through via the ring cache. |
| EventSource drops past the ring window | You get a `rove:resync` event on reconnect. Refetch state. |
| `waitFor` times out | Same recovery path: poll the kv-backed result endpoint. The notification is the fast path; your kv is the safety net. |
| `notifications_url: null` from the token mint | Operator hasn't wired sse-server. Surface a clear error in your UI; don't try to subscribe. |

---

## See also

- [`sse-plan.md`](sse-plan.md) — internal architecture (transport,
  ring cache, failover model, replication choices). Read this if
  you're operating Rove, not consuming it.
- [`PLAN.md`](PLAN.md) §2.12 — the roadmap entry that placed
  notifications in the broader product shape.
