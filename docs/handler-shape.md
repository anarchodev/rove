# Handler shape — pattern-matching at module level

> **Status:** Proposal. Supersedes the `__rove_stream` / `__rove_next`
> / `request.activation.kind`-switch surface in `streaming-model.md`
> §3 and the multi-shape return values in §4–§5. The engine model
> (coalesce budget, blob coordinator, one-rule semantics — see
> `streaming-model.md` §1–§2 and §7.X) is **unchanged**. Only the
> customer-facing handler API changes.
>
> **Revised 2026-06-02.** Reorganized around one axis —
> **scope: current-connection vs connectionless** — derived in
> `effect-algebra.md` §8. The verb you call *is* the scope; there are
> no scope flags. This revision moves stream wakes out of
> `stream({until})` into `on.*` builder calls and **retires `detach`**
> (see §2.4, §10).
>
> Motivation: the surface should read like intent — multi-activation
> chains, Cmd-return discipline, no closure smuggling — without
> exposing implementation details (`a.kind` switch,
> underscore-prefixed primitives, four-way-overloaded return values).
> The scope axis makes the one decision every handler author actually
> faces — *"does this happen for the current caller, or as new
> work?"* — a property of **which verb you reach for**, never a flag
> to remember.

## 1. The frame — TEA at module level

A rewind handler module is one Elm-style `update : Msg → Model →
(Effects, Cmd)` function with **each case-of arm hoisted to its
own named export**. The runtime knows the full set of Msg variants
(activation kinds); each named export handles one variant.

| Elm | Rewind handler |
|---|---|
| `Model` | the tenant's `kv` |
| `Msg` (sealed sum type) | the runtime's fixed set of activation kinds |
| `update : Msg -> Model -> (Model, Cmd Msg)` | the module as a whole |
| `case msg of` | the runtime's dispatch on activation kind → named export |
| each `case` arm | each `export function on…` |
| `(Model, Cmd Msg)` return | (kv writes accumulated, Cmd returned) |
| `Cmd Msg` ADT | the verbs in §2 |
| Model update | `kv.*` (read-your-writes within the activation) |
| Side-effects via `Cmd Msg` | the scope verbs of §2: current-connection (`on.*`, the return verb) + connectionless (`subscribe.*` / `schedule` / `cron` / `webhook.send`) — queued during the activation, fired post-commit |

A module exports the subset of variants it cares about. The runtime
introspects exports at load time, validates coverage (§6), and
dispatches each activation to its matching export.

The default export handles inbound HTTP — the case 80%+ of
modules care about. Everything else is opt-in via additional
named exports.

## 2. The verb surface — the verb is the scope

Every outbound thing a handler does sits on one axis: does it act on
the **current connection** (the held socket — ephemeral, dies when
the caller disconnects), or does it create a **connectionless
request** (a fresh activation with no socket — durable, runs whether
or not anyone is connected)?

**The scope is the verb.** There is no `durable:` or `detach:` flag;
you choose connection vs connectionless by which verb you reach for.
The author's litmus test:

> **If the caller closed their laptop right now, should this still
> happen?** No → a current-connection verb. Yes → a connectionless
> verb.

The whole surface is four cells:

| Role | Verbs | Scope |
|---|---|---|
| **Model** | `kv.get` / `kv.set` / `kv.delete` | — (read-your-writes; the Model half of `(Model, Cmd)`) |
| **Connection — output / disposition** | `response(...)` / `stream(...)` / `next()` — the **return value** | current connection |
| **Connection — triggers** | `on.timer(...)` / `on.kv(...)` / `on.fetch(...)` — body builder calls | current connection (ephemeral) |
| **Connectionless — triggers** | `subscribe.kv(...)` / `schedule(...)` / `cron(...)` / `webhook.send(...)` | connectionless (durable, new request) |

The body of an activation **accumulates** the Cmd as you compute —
`kv.*` builds the Model, the trigger verbs register what fires later
— and the **return value** picks the connection's disposition.
Together that's the TEA pair `(Model', Cmd)`. (`effect-algebra.md`
§8 is the model derivation; `effect-algebra.md` §1 is the
determinism invariant the whole surface preserves.)

### 2.1 Return verbs — what leaves this activation

The return value carries **only the body**; each verb reduces to its
per-hop essence. The response **head** — status, headers, cookies —
is the ambient `response` global, not a return argument (this matches
the engine: `dispatcher.zig` `extractResponseMetadata` reads
`response.status` / `response.headers` / `response.cookies`, and "body
is NOT read from here — it always comes from the return value"):

```js
response.status  = 201;
response.headers = { 'content-type': 'text/event-stream' };
response.cookies = ['sid=…; HttpOnly'];
```

| Return | Means | Wire effect |
|---|---|---|
| `string` (or any value → JSON) | terminal response | commit writeset; ship body + the ambient head; close |
| `stream({write?, ctx?})` | **committed** streaming response — head is on the wire; more body chunks coming | commit; first hop flushes the ambient head; ship `write`; re-invoke on a registered `on.*` wake |
| `next({ctx?})` | **held, uncommitted** — nothing on the wire yet; head still open | commit; hold the connection; resume via the registered trigger's export when it fires |

So `next` reduces to `{ctx?}`, `stream` to `{write?, ctx?}`, and the
terminal verb to the body alone. `status` / `headers` / `cookies`
don't appear in any of them because they're not per-hop data — they're
the response head, set once on the ambient `response.*` and committed
**by which verb you return**:

- `stream` **commits** the staged head — it flushes status (default
  `200`) + headers on the first hop, which is what lets an SSE
  client's `onopen` fire on an idle stream. Once committed, only body
  chunks remain; you cannot change the head.
- `next` commits **nothing** — the head is still open, so its resume
  can set any `response.status` and return any body. This is the
  await-then-respond / gateway pattern (forward an upstream's `502`).
  You can't express it with `stream`, which would lock in the head.

That commit-or-not is the whole `stream`-vs-`next` distinction, and
with the head ambient there's no per-hop `status`/`headers` carve-out
to remember — the verbs are uniformly `{write?, ctx?}` / `{ctx?}`.

`ctx` threads small per-connection state forward to the next
activation — a stream loop's cursor, a fan-in accumulator (§5.8), etc.
It is **not** heap state that persists across activations — it's
serialized and threaded through the return (the arena resets between
activations, so nothing else survives). State that must survive a
disconnect lives in `kv`, not `ctx`.

```js
import { stream, next } from 'rove';
```

### 2.2 Connection triggers — `on.*`

`on.*` registers a wake **for the current connection**. They're
imperative builder calls in the body (like any effect), and they
re-invoke a handler that still holds the socket. Ephemeral: if the
connection drops, every `on.*` registration drops with it.
Node-local — they never touch raft.

- `on.timer(ms)` — wake after `ms`.
- `on.kv(prefix, { to? })` — wake when any key under `prefix` changes
  **since the version this activation read**. The watch is anchored to
  the activation's read view, so a write that lands between "you read"
  and "you parked" still fires it — and the same property makes the
  common "wait on a key, write it from a connectionless callback"
  pattern lossless (`effect-algebra.md` §8.4).
- `on.fetch(url, opts?, { to? })` — perform an outbound request and
  wake on its result (whole or chunked). This is the connection-scoped
  outbound; its durable connectionless twin is `webhook.send` (§2.3).

The optional **`{ to: "module.method" }`** routes the wake to a
different export (still holding *this* connection) — the
connection-scoped state machine. Without `to`, the wake dispatches to
the conventional export for its kind (§3).

Because they're body builders, dynamic and conditional sets are
natural — the same reason effects live in the body (§2.5):

```js
for (const room of request.ctx.rooms) on.kv(`rooms/${room}/`);
return stream({ write: render(request.ctx) });
```

The runtime arms all `on.*` registrations **before** firing any
connectionless effects of the same activation, so a wake can't be
missed even when a connectionless callback writes the key the wake
watches (`effect-algebra.md` §8.4).

### 2.3 Connectionless triggers — `subscribe.*` / `schedule` / `cron` / `webhook.send`

These create a **connectionless request** — a fresh, durable
activation with no held socket. They survive leader changes (a Model
row re-arms them on promotion — `effect-algebra.md` §2.2, §8.1),
route by tenant, and run whether or not anyone is connected. Each
names the export it will invoke:

- `subscribe.kv(prefix, "module.method")` — run the target as a new
  request whenever a key under `prefix` changes.
- `schedule({ at } | { in }, "module.method", ctx?)` — run the target
  once, at a time.
- `cron(spec, "module.method")` — run the target on a recurring
  schedule.
- `webhook.send(url, { onResult: "module.method", ... })` — durable
  outbound; run the target as a new request when it completes.

A connectionless request can read/write `kv`, register more
connectionless triggers, and do work — but it has **no connection**,
so the return verbs (`response` / `stream` / `next`) and `on.*` are
**inert** there (no socket to write to or hold). That inertness is
what keeps the two scopes from bleeding into each other.

To surface a connectionless result *to* a still-connected client,
compose the two scopes: the connectionless callback writes `kv`, and
the connection watches that key with `on.kv` (the worked SSE example,
§5.7; the model in `effect-algebra.md` §8.5).

### 2.4 The rule, and why there are no scope flags

> **All wakes registered through `on.*` are for the current
> connection. Every other trigger creates a connectionless request.**

That is the whole model. Scope must be a *verb*, not a flag, because a
connectionless trigger is **durable**, and durability isn't a boolean
— it's a Model-row + commit-gate + reload-on-leader-change overlay
(`effect-algebra.md` §2.2, §8.1). A `{ durable: true }` /
`{ detach: true }` flag can't conjure that lifecycle; flipping scope
with a flag is exactly the `bind` mistake the model retired
(`effect-algebra.md` §8.3). So:

- **`detach` is retired.** "A fetch that outlives my connection" is
  not `on.fetch(url, { detach: true })` — it's the connectionless verb
  (`webhook.send`). One verb, one scope, no exceptions.
- Connectionless work is **durable by default** (it goes through the
  durable verbs). A connectionless-ephemeral "fire-and-forget, don't
  care if it's lost" fast path is intentionally *not* offered; add it
  only if a real high-volume case demands it
  ([[feedback_model_simplicity_safety]]).

### 2.5 The Model — `kv`

`kv.get` / `kv.set` / `kv.delete` are neither connection nor
connectionless — they're the **Model** half of `(Model, Cmd)`. They
stay in the body because they're **read-your-writes**:
`kv.set('x', 1); kv.get('x')` returns `1` in the same activation (the
kvexp overlay). That immediate visibility is exactly why a write can't
be deferred to the return — it's building the Model the rest of the
activation reads, not describing a future effect. The connection
triggers (`on.*`) and connectionless triggers, by contrast, never
return a result *into this activation* — their results arrive as
future Msgs — which is why they're Cmd-builders, not Model mutations.

## 3. Activation kinds — the runtime's Msg union

| Activation | Export | Scope | When it fires | `request` shape |
|---|---|---|---|---|
| inbound HTTP (buffered) | `default` | connection | request arrived, body ≤ 1 MB; > 1 MB → 413 if no `onChunk` | full `request` with `body` |
| inbound HTTP chunk | `onChunk` | connection | request arrived; per chunk for any body size (≤ 1 MB → fires once with the whole body) | `request.body` = this chunk; `request.done` on last; `request.chunkSeq` monotonic |
| `on.fetch` result (coalesced) | `onFetchResult` (or `to`) | connection | a connection `on.fetch` returned its whole body | `request.result` = `{status, body, headers, fetchId}` |
| `on.fetch` chunk (streamed) | `onFetchChunk` (or `to`) | connection | per chunk from a streamed connection `on.fetch` | `request.body` = chunk bytes; `request.done` on last; `request.fetchId` |
| `on.fetch` end (streamed) | `onFetchDone` (or `to`) | connection | a streamed connection `on.fetch` terminated | `request.result` = `{ok, status, fetchId}` |
| `on.kv` / `on.timer` wake | the `to` export | connection | a connection wake fired (held socket) | `request.ctx`; for kv: `request.key`, `request.value` |
| held client disconnected | `onDisconnect` | connection | the held stream closed before the chain terminated | (none) |
| `webhook.send` result | `onSendCallback` (or `onResult`) | connectionless | a `webhook.send` completed | `request.result` = `{status, body, headers, sendId}` |
| `subscribe.kv` fire | `onKvWake` (or target) | connectionless | a subscribed key prefix changed | `request.key`, `request.value` |
| `cron` fire | `onCron` (or target) | connectionless | a scheduled `cron` / `schedule` entry triggered | `request.cronName`, `request.scheduledTime` |
| subscription fire (generic) | `onSubscription` | connectionless | external push (atproto firehose, etc.) | `request.event` |
| boot fire | `onBoot` | connectionless | once per fresh deployment activation | `request.deploymentId` |

The set of *kinds* is closed — modules can't define new activation
kinds; only the runtime can. The `to:` option on `on.*` (and the
target on the connectionless verbs) chooses **which export** a given
trigger's activation lands in; it does not invent a new kind. Adding a
kind is a runtime change with a coordinated loader bump.

The scope column is load-bearing: a **connection** activation runs
with the held socket (it may return `response`/`stream`/`next` and
register `on.*`); a **connectionless** activation has no socket (those
verbs are inert — it does `kv` + connectionless triggers + returns
nothing). The same key change can fire *both* a connection `on.kv`
(resume a held stream) and a connectionless `subscribe.kv` (a new
request); each dispatches by its own registration, so they never
collide on one export.

## 4. Buffered vs streaming — the 1 MB ceiling

The runtime guarantees: **any inbound HTTP request body ≤ 1 MB is
delivered in a single `default` activation** with `request.body`
containing the full bytes. The common case — APIs, webhooks, JSON
payloads, small uploads — never has to think about streaming.

**If the module exports `default` only:** body ≤ 1 MB → single
`default` activation with the full body in `request.body`. Body >
1 MB → `413 Payload Too Large`, handler never runs.

**If the module exports `onChunk` only:** body of any size →
dispatched per chunk to `onChunk`. The first-chunk case is the
degenerate one: a body ≤ 1 MB fires `onChunk` exactly once with
`request.body` = the whole body, `request.done = true`. The
handler returns a response on that first call and the chain ends.
For larger bodies, `onChunk` fires N times with `request.done`
true on the last.

`onChunk` is strictly more general than `default` — it handles the
buffered case as "one chunk that happens to be the whole body."
`default` is the optimization for handlers that *know* they'll
never deal with chunks and want the simplest possible signature
(no `request.done` check, no `stream()` return option).

A module can export `default` AND `onChunk` if the customer wants
distinct logic for the two paths (rare); otherwise pick one.

The 1 MB number is the customer-facing hard ceiling for `default`.
The 64 KiB internal chunk size is implementation detail; customers
writing `default` handlers never see it. `onChunk` handlers see
whatever the runtime's per-chunk coalesce delivers, with the
guarantee that small bodies (≤ 1 MB) get coalesced into one chunk
rather than artificially split.

## 5. Worked examples

### 5.1 Buffered request (the 80%+ case)

```js
export default function () {
  return process(request.body);
}
```

No imports, no other exports. Returns the body (a string); runtime
wraps as `{body: string, status: 200}`. Identical to today.

### 5.2 Buffered with auth + status

```js
export default function () {
  if (!authorized(request.headers)) { response.status = 401; return 'unauthorized'; }
  return process(request.body);                 // status defaults to 200
}
```

### 5.3 Streaming inbound — per-chunk upload to storage

```js
import { stream } from 'rove';

export function onChunk() {
  on.fetch(`${STORAGE_URL}/${request.headers['x-key']}?seq=${request.chunkSeq}`, {
    method: 'PUT',
    body: request.body,
  }, { to: 'onPut' });
  if (request.done) { response.status = 201; return 'uploaded'; }
  return stream();
}

// connection-scoped: each PUT result resumes here, still holding the upload.
export function onPut() {
  if (request.result.status >= 400) { response.status = 502; return 'storage failed'; }
  return stream();
}
```

`on.fetch` is a connection trigger — the PUTs are bound to this
upload and their results resume `onPut` (named via `to`). Drop the
connection and the in-flight PUTs drop with it, which is correct: the
upload is abandoned anyway.

### 5.4 Gateway — hold the client, forward upstream, return its status

```js
import { next } from 'rove';

export default function () {
  on.fetch('https://upstream.example.com', { method: 'POST', body: request.body },
           { to: 'onUpstream' });
  return next();                              // held, uncommitted — status still open
}

export function onUpstream() {
  response.status = request.result.status;     // forward upstream's status verbatim
  return request.result.body;
}
```

`next()` (not `stream()`) because the response status isn't known
until the upstream answers — `next` keeps the status line uncommitted
so `onUpstream` can return a `502`. The fetch is connection-scoped
(`on.fetch`): if the client leaves, there's no one to forward to, so
abandoning it is correct. (Contrast §5.6, where the work must outlive
the client → `webhook.send`.)

### 5.5 LLM proxy — streamed connection fetch + held client

```js
import { stream, next } from 'rove';

export default function () {
  on.fetch(LLM_URL, { method: 'POST', body: request.body }, { to: 'onUpstream' });
  return next();                              // hold the client; wait for the first chunk
}

export function onUpstream() {
  if (request.done) return "";               // close the held response
  return stream({ write: transform(request.body) });
}
```

`next()` first (status uncommitted), then the first `onUpstream` chunk
returns `stream({write})` — which commits `200` and begins the body.
Waiting for the first upstream chunk before committing means a clean
upstream failure can still become a `502` from `next`'s resume.

### 5.6 Connectionless work — fire durable, respond now

```js
import { schedule } from 'rove';

export default function () {
  // These outlive this request — they run whether or not the client stays.
  webhook.send('https://billing.example.com/charge', {
    body: request.body, onResult: 'onCharge',
  });
  schedule({ in: '24h' }, 'sendReminder', { user: request.user });
  response.status = 202;
  return 'queued';                             // respond immediately
}

// A connectionless request — no socket. Does work, returns nothing.
export function onCharge() {
  kv.set(`charges/${request.result.body.id}`, request.result.body);
}

// Chain origins — also connectionless (no inbound client).
export function onCron()  { kv.set('last_cron', now()); }
export function onBoot()  { kv.set('booted_at', now()); }
```

`webhook.send` / `schedule` are connectionless: the charge happens and
`onCharge` runs even if the client disconnected the instant after the
`202`. `onCharge` / `onCron` / `onBoot` have no socket — they return
nothing; the chain commits its writeset and ends.

### 5.7 SSE notifications — connection + connectionless composed

```js
import { stream } from 'rove';

// Connect (or reconnect via Last-Event-ID).
export default function () {
  const since = Number(request.headers['last-event-id'] ?? latestSeq(`notif/${user}/`));
  response.headers = { 'content-type': 'text/event-stream' };   // ambient head
  on.kv(`notif/${user}/`, { to: 'onNotify' });                 // connection wake
  return stream({ ctx: { since } });                           // commits the head, opens SSE
}

// Connection-held resume: drain everything since the cursor.
export function onNotify() {
  const rows = kv.range(`notif/${user}/`, { afterSeq: request.ctx.since });
  if (!rows.length) return stream({ ctx: request.ctx });
  return stream({
    write: rows.map(r => `id:${r.seq}\ndata:${r.value}\n\n`),
    ctx: { since: rows.at(-1).seq },
  });
}

// Connectionless cleanup — registered once (e.g. cron('0 3 * * *', 'gcNotifs')).
export function gcNotifs() {
  for (const r of kv.range(`notif/`, { olderThan: '7d' })) kv.delete(r.key);
}
```

The whole pattern: `on.kv` (connection, ephemeral) waits for changes
*since the read cursor*; on each wake the handler **range-drains** from
the cursor (so coalesced wakes never lose notifications) and advances
it in `ctx`. The notifications themselves live in `kv` (durable) and
the client's resume point is its `Last-Event-ID`, so a dropped
connection just reconnects and resumes — no durable server-side
connection state. `cron` cleanup is the connectionless counterpart.
(Model derivation: `effect-algebra.md` §8.5; retention bounds the
reconnect-replay window.)

### 5.8 Fan-in / join — wait for all, then combine

`next({ctx})` takes only a context object, which makes `ctx` the
continuation's **accumulator**. A join is just that accumulator plus a
completion check:

```js
import { next } from 'rove';

export default function () {
  on.fetch(API_A, {}, { to: 'onResult' });     // fetchId: 'a'
  on.fetch(API_B, {}, { to: 'onResult' });     // fetchId: 'b'
  on.timer(30_000, { to: 'onTimeout' });        // deadline (optional)
  return next({ a: null, b: null });            // uncommitted: response unknown until both land
}

export function onResult() {
  const ctx = { ...request.ctx, [request.fetchId]: request.result };
  if (ctx.a && ctx.b) return combine(ctx.a, ctx.b);   // status defaults to 200
  return next(ctx);                             // still waiting on the other
}

export function onTimeout() {
  response.status = 504;
  return 'upstream timeout';
}
```

Each fetch result fires `onResult` as its **own** activation (fetch
results are value-triggers — delivered individually, never coalesced,
`effect-algebra.md` §8.2), the activations for this connection run
**one at a time** (serialized), and each `next(ctx)` updates the
threaded `ctx` the next resume reads. So the two completions accumulate
into `ctx` with no lock and no race; the handler returns a terminal
response only once both have landed. `next` (not `stream`) the whole
time, because the response isn't known until the join resolves — it
could be `200`, or via `onTimeout` a `504`.

This is `Promise.all` built from primitives: the fan-in is `ctx` + a
completion check, no dedicated combinator. A sugar `all([...])` could
lower onto exactly this later, if measured demand appears
([[feedback_compose_from_primitives]]). The simpler "stream each
result independently as it lands" shape is the same skeleton with
`stream({write})` per `onResult` instead of an accumulator.

## 6. Validation — exhaustiveness without a type system

JS modules aren't a sum type the compiler sees; a typo in a target
export → handler silently never fires. Mitigation: the loader
validates `module.exports` against the activations the module's verbs
could trigger:

- If `default` exists and the body is large, dispatch happens or 413
  fires — no validation needed.
- If `onChunk` is exported, the route is a streaming receiver.
- If any handler calls `webhook.send` and neither its `onResult`
  target nor `onSendCallback` is exported, the loader warns: "your
  module calls `webhook.send` but its callback export is missing —
  the result will be discarded."
- If any handler calls `on.fetch` / `on.kv` / `on.timer` whose `to`
  target (or the conventional export for its kind) is not exported,
  same warning — the wake has nowhere to land.
- If any handler calls `subscribe.*` / `schedule` / `cron` whose
  target export is missing, the loader errors — a connectionless
  trigger with no handler is dead on arrival.
- If `onChunk` is exported but nothing can trigger a receive (no
  `default`, no other inbound origin), the loader warns.
- Unknown `on…` exports (typos) emit a "did you mean…?" suggestion.

These are deploy-time errors / warnings, not request-time failures.
Strict mode (errors instead of warnings) is configurable per-tenant.

## 7. The `request` global per activation kind

`request` is a module-level global the runtime populates fresh for
every activation. Across activations of the same chain, `request`
*is replaced*, not mutated — its identity changes each dispatch.
This makes "no state across activations" structurally obvious:
your reference to `request` from a prior activation is gone when
the new one fires (the arena reset wipes it anyway). Cross-activation
state on a connection rides `ctx` (§2.1); state that must survive a
disconnect rides `kv`.

Per-activation shapes are listed in §3's table. A few highlights:

- **`default` (inbound):** `request.body`, `.headers`, `.method`,
  `.path`, `.query`, `.cookies`, `.ip` etc. — same as today's
  buffered handler.
- **`onChunk`:** `request.body` = THIS chunk's bytes (NOT the
  cumulative prefix); `request.done` = boolean true on the last
  chunk; `request.chunkSeq` = monotonic counter from 0. Headers etc.
  are present and unchanged across chunks.
- **Connection wakes / fetch resumes:** `request.ctx` (the threaded
  state), plus `request.result` (`on.fetch` whole / `webhook.send`),
  `request.body` + `request.fetchId` (`on.fetch` streamed chunk), or
  `request.key` / `request.value` (`on.kv`).
- **Connectionless fires** (`onCron`, `onKvWake`, `onBoot`,
  `onSubscription`, `onCharge`-style): origin-specific fields
  (`cronName`, `key`, `deploymentId`, `result`, …) but **no** HTTP
  `headers` / `body` — there is no inbound HTTP request, and the
  connection verbs are inert (§2.3).

## 8. What's gone vs `streaming-model.md` §3 (and the prior revision)

- `request.activation.kind === '...'` switch → runtime dispatches by export name
- `__rove_stream({write, waitFor})` → `stream({write})` + `on.*` wakes
- `__rove_next()` → `next()`
- `stream({until: [...]})` → wakes are `on.*` builder calls in the body (§2.2)
- `detach: true` → **retired**; connectionless outbound is `webhook.send`, not a flag (§2.4)
- the three-way choice (`respond` / `parkUntilBodyComplete` / `streamBody`) → "1 MB ceiling, above → 413 or `onChunk`"
- `return { status, headers, body }` → return is the **body only**; the head (`status` / `headers` / `cookies`) is the ambient `response.*` global (§2.1). This matches the engine (`extractResponseMetadata`); the prior revision's return-based head was a doc divergence (`return {status:401}` actually JSON-stringifies as the body with a `200`). `stream` thus reduces to `{write?, ctx?}`, `next` to `{ctx?}`.
- four return shapes overloading one slot → return verbs carry only body + threading (`write` / `ctx`); the head is ambient; triggers are separate verbs
- `ctx.state` cross-activation scratchpad → forbidden; durable state lives in `kv`, ephemeral connection state in `ctx`

## 9. What's unchanged

- The engine model: pure function per activation, arena reset
  between activations, no closure smuggling
- The Effects vs return split (now stated as the scope axis):
  trigger/effect verbs accumulate during the activation and fire
  post-commit; the return verb declares the connection disposition
- The one rule (§2 of `streaming-model.md`): a chunk reaches the
  wire only after the activation that produced it has committed
- Replay: `foldl(handlers, kv0, activations)` — re-run all
  activations against the recorded inputs from the readset, derive
  everything else
- The substrate: blob coordinator, readset replication, content-
  addressed extents — all unchanged
- The 64 KiB internal coalesce budget for streaming chunks

## 10. Open questions

1. **`on.fetch` vs `http.fetch` spelling.** "Verb is the scope" puts
   the connection-scoped outbound in the `on.*` namespace (`on.fetch`),
   with `webhook.send` as its connectionless twin. The prior
   auto-bound `http.fetch` (`auto-bind-plan.md`) is what `on.fetch`
   replaces. Keep `http.fetch` as an alias for familiarity, or commit
   to `on.fetch` for namespace-is-scope consistency?

2. **Default resume export for `on.kv` / `on.timer`.** `on.fetch` has
   natural result exports (`onFetchResult` / `onFetchChunk`). For
   `on.kv` / `on.timer` without `to`, what's the default target — a
   generic `onWake`, or require `to`? Examples here use `to`
   explicitly to sidestep it.

3. **Runtime-registerable durable `subscribe.kv`.** Today tenant
   kv-react is a deploy-time spec (`effect-algebra.md` §5). A runtime
   `subscribe.kv(...)` symmetric to `schedule` needs the durable-wake
   substrate (gap 2.6, `durable-wake-plan.md`). Worth the symmetry, or
   keep kv subscriptions deploy-time?

4. **`schedule` / `cron` / `webhook.send` under `subscribe.*`.** Full
   namespace symmetry (`subscribe.timer` = `schedule`,
   `subscribe.fetch` = `webhook.send`) vs keeping the domain names
   that carry intent. Current lean: keep the domain names
   (`effect-algebra.md` §8 discussion).

5. **`onError` / module-level state / strict mode.** As before:
   thrown exceptions → runtime 500 (Erlang posture; defer `onError`);
   module-top-level `let` does not persist (arena reset; lint to
   forbid); validation strictness per-tenant.

6. **`default` vs `onInbound`.** Keep `default` for the familiar
   simple case (`export default (req) => "hello"`); alias to
   `onInbound` internally for family consistency.

## 11. Relation to other plans

- **`effect-algebra.md`** — the model this surface lowers onto. §8 is
  the scope axis (connection vs tenant/connectionless), §8.3 the
  `bind`/`detach` retirement, §8.4 the watch-before-write / read-view
  anchoring, §8.5 the "grammar position = scope" framing. The verbs
  here are the customer-facing names for §2's primitives; no semantic
  change.
- **`streaming-model.md`** — engine substrate. §1 frame, §2 one rule,
  §4.A `http.fetch` as-built, §7.X blob coordinator all unchanged.
  This doc supersedes §3's three-way-choice surface and the
  `__rove_stream` / `__rove_next` shape in §5.
- **`auto-bind-plan.md`** — the auto-bind/`detach` mechanism. `detach`
  is **retired** here (§2.4); the connection-bound default it provided
  is subsumed by `on.fetch` being connection-scoped by construction.
- **`effect-reification-plan.md`** — Phases 0–5 shipped; the existing
  `streaming-handler` machinery in `worker.zig` is what this surface
  lowers onto. The `on.*` builder + `subscribe.*` verbs are the
  unbuilt surface work; the engine (one Continuation runtime, the
  trigger sources) already exists.
- **`primitive-gaps.md` §2.4** — inbound streaming body, the substrate
  `onChunk` rides on.
- **`readset-replication-plan.md`** — chunk capture in the readset is
  what makes `onChunk` and the stream loop replayable.
- **`durable-wake-plan.md`** — gap 2.6, the durable substrate a
  runtime `subscribe.*` / `schedule` re-arms from on leader change.
