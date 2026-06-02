# Handler shape — pattern-matching at module level

> **Status:** Proposal. Supersedes the `__rove_stream` / `__rove_next`
> / `request.activation.kind`-switch surface in `streaming-model.md`
> §3 and the multi-shape return values in §4–§5. The engine model
> (coalesce budget, blob coordinator, one-rule semantics — see
> `streaming-model.md` §1–§2 and §7.X) is **unchanged**. Only the
> customer-facing handler API changes. Implementation plan:
> [`handler-surface-impl-plan.md`](handler-surface-impl-plan.md).
>
> **Revised 2026-06-02 (rev 2 — `stream.*` model).** Organized around one
> axis — **scope: current-connection vs connectionless** — derived in
> [`effect-algebra.md`](effect-algebra.md) §8. **The verb is the scope;
> output is a commit-gated effect; the return is pure disposition.**
> Streamed output is `stream.start()` / `stream.write()` (effects), not a
> `stream` return verb. The only return shapes are `next(...)` (park) and
> a terminal body (close). The head is ambient `response.*`. `detach` is
> retired; `subscribe.kv` is deferred.
>
> Motivation: the surface should read like intent — multi-activation
> chains, no closure smuggling — without exposing implementation details.
> The scope axis makes the one decision every author faces — *"does this
> happen for the current caller, or as new work?"* — a property of which
> verb you reach for, never a flag.

## 1. The frame — TEA at module level

A rewind handler module is one Elm-style `update : Msg → Model →
(Effects, Cmd)` function with **each case-of arm hoisted to its own
named export**. The runtime knows the full set of Msg variants
(activation kinds); each named export handles one variant.

| Elm | Rewind handler |
|---|---|
| `Model` | the tenant's `kv` |
| `Msg` (sealed sum type) | the runtime's fixed set of activation kinds |
| `case msg of` | the runtime's dispatch on activation kind → named export |
| each `case` arm | each `export function on…` |
| `Model` update | `kv.*` (read-your-writes within the activation) |
| Side-effects (`Cmd`) | effects called in the body — connection (`stream.*`, `on.*`) + connectionless (`webhook.send`/`schedule`/`cron`), queued during the activation, fired post-commit |
| `Cmd Msg` disposition | the return value: `next(...)` or a terminal body |

A module exports the subset of variants it cares about; the runtime
introspects exports at load (§6) and dispatches each activation to its
matching export. The default export handles inbound HTTP — the 80%+
case; everything else is opt-in via additional named exports.

## 2. The verb surface — the verb is the scope

Every outbound thing a handler does sits on one axis: does it act on the
**current connection** (the held socket — ephemeral, dies when the
caller disconnects), or does it create a **connectionless request** (a
fresh activation with no socket — durable, runs whether or not anyone is
connected)?

**The scope is the verb.** No `durable:` / `detach:` flag — you choose
by which verb you reach for. The litmus test:

> **If the caller closed their laptop right now, should this still
> happen?** No → a current-connection verb. Yes → a connectionless verb.

The whole surface is five roles:

| Role | Surface | Scope |
|---|---|---|
| **Model** | `kv.get` / `kv.set` / `kv.delete` | — (read-your-writes; the Model half of `(Model, Cmd)`) |
| **Connection output** | `stream.start()` / `stream.write(chunk)` | current connection (commit-gated effects) |
| **Connection triggers** | `on.timer(ms)` / `on.kv(prefix,{to?})` / `on.fetch(url,opts?,{to?})` | current connection (ephemeral) |
| **Connectionless triggers** | `webhook.send` / `schedule` / `cron` | connectionless (durable, new request) |
| **Disposition (return)** | `next({ctx?})` · terminal body / `""` | the only return shapes |

The body **accumulates** the Cmd as you compute — `kv.*` builds the
Model; `stream.*`, `on.*`, and the connectionless verbs are effects that
fire post-commit — and the **return value** picks the connection's
disposition. Together that's the TEA pair `(Model', Cmd)`
(`effect-algebra.md` §8 is the derivation; §1 the determinism invariant).

### 2.1 Disposition — the return value

The return is only one of two things:

| Return | Means | Wire effect |
|---|---|---|
| `string` (or any value → JSON) | terminal response | commit; ship body + the ambient head; close |
| `next({ctx?})` | held — hold the connection; resume when a registered trigger fires | commit; hold; resume via the trigger's export |

There is **no `stream` return verb**. Streaming is done by calling
`stream.*` output effects (§2.2) and returning `next()`; you close by
returning a terminal body (a final chunk) or `""`.

The response **head** — status, headers, cookies — is the ambient
`response` global, not a return argument (matching the engine,
`dispatcher.zig` `extractResponseMetadata`):

```js
response.status  = 201;
response.headers = { 'content-type': 'text/event-stream' };
response.cookies = ['sid=…; HttpOnly'];
```

The head is committed (sent to the wire) by the first `stream.start()` /
`stream.write()` or a terminal response; **`next()` alone commits
nothing** — the head stays open, so a later resume can still set any
`response.status` and return any body (the await-then-respond / gateway
pattern, forward an upstream's `502`). That commit-or-not is the only
state distinction; `next` reduces to `{ctx?}` and the terminal verb to
the body.

`ctx` threads small per-connection state to the next activation — a
stream loop's cursor, a fan-in accumulator (§5.8). It is **not** heap
state across activations (the arena resets); state that must survive a
disconnect lives in `kv`.

```js
import { next } from 'rove';
```

### 2.2 Connection output — `stream.start` / `stream.write`

`stream` is an **effect namespace** (ambient, like `kv`), not a return
verb. It produces the streaming response over time:

- `stream.start()` — commit the head (from ambient `response.*`) and
  begin the response. Use it to open an SSE stream so the client's
  `onopen` fires before any data. Optional — the first `stream.write()`
  starts implicitly.
- `stream.write(chunk)` — emit a chunk. **Commit-gated**: the chunk
  reaches the wire only after this activation's writes commit
  (`streaming-model.md` §2). Call it as many times per activation as you
  like; raw bytes (SSE `data:` framing is yours to write).

Pair `stream.*` with `next()` to keep producing across activations;
close with a terminal return:

```js
stream.start();
on.kv(`notif/${user}/`, { to: 'onNotify' });
return next({ since });
```

`stream` is **only** a namespace — `stream.start()` / `stream.write()`,
never `return stream(...)`.

### 2.3 Connection triggers — `on.*`

`on.*` registers a wake **for the current connection** — body builder
calls that re-invoke a handler still holding the socket. Ephemeral
(drop with the connection); node-local (never touch raft).

- `on.timer(ms)` — wake after `ms`.
- `on.kv(prefix, { to? })` — wake when any key under `prefix` changes
  **since the version this activation read** (anchored to the read view,
  so a write between "you read" and "you parked" still fires it, and the
  common "wait on a key, write it from a connectionless callback"
  pattern is lossless — `effect-algebra.md` §8.4).
- `on.fetch(url, opts?, { to? })` — perform an outbound request and wake
  on its result (whole or chunked). Connection-scoped outbound; its
  durable twin is `webhook.send` (§2.4).

`{ to: "module.method" }` routes the wake to a different export (still
holding *this* connection). Without `to`, an `on.kv`/`on.timer` wake
defaults to `onWake`; `on.fetch` to `onFetchResult`/`onFetchChunk` (§3).

```js
for (const room of request.ctx.rooms) on.kv(`rooms/${room}/`);  // dynamic sets are natural
return next({ rooms: request.ctx.rooms });
```

The runtime arms `on.*` wakes **before** firing any connectionless
effects of the same activation, so a wake can't be missed even when a
connectionless callback writes the key it watches (`effect-algebra.md`
§8.4).

### 2.4 Connectionless triggers — `webhook.send` / `schedule` / `cron`

These create a **connectionless request** — a fresh, durable activation
with no held socket. They survive leader changes, route by tenant, and
run whether or not anyone is connected. Each names the export it invokes:

- `webhook.send(url, { onResult: "module.method", … })` — durable
  outbound; run the target as a new request when it completes.
- `schedule({ at } | { in }, "module.method", ctx?)` — run the target
  once, at a time.
- `cron(spec, "module.method")` — run the target on a recurring schedule.

A connectionless request can read/write `kv`, register more
connectionless triggers, and do work — but it has **no connection**, so
the disposition verbs and `stream.*` / `on.*` are **inert** there. To
surface a connectionless result *to* a still-connected client, compose:
the callback writes `kv`, the connection watches that key with `on.kv`
(the SSE example, §5.7; the model, `effect-algebra.md` §8.5).

> `subscribe.kv` (a runtime durable kv-react) is **deferred** — `on.kv`
> covers the connection case; no runtime durable kv-react for now.

### 2.5 The Model — `kv`

`kv.get` / `kv.set` / `kv.delete` are neither connection nor
connectionless — they're the **Model** half of `(Model, Cmd)`. They stay
in the body because they're **read-your-writes**: `kv.set('x',1);
kv.get('x')` returns `1` in the same activation (the kvexp overlay).
That immediate visibility is why a write can't be deferred — it builds
the Model the rest of the activation reads. The trigger/output effects
(`stream.*`, `on.*`, connectionless), by contrast, never return a result
into *this* activation — their results arrive as future Msgs — which is
why they're Cmd-builders, not Model mutations.

### 2.6 The rule, and why there are no scope flags

> **All wakes registered through `on.*` are for the current connection.
> Every other trigger creates a connectionless request.**

Scope must be a *verb*, not a flag, because a connectionless trigger is
**durable**, and durability isn't a boolean — it's a Model-row +
commit-gate + reload-on-leader-change overlay (`effect-algebra.md` §2.2,
§8.1). A `{ durable: true }` / `{ detach: true }` flag can't conjure
that lifecycle; flipping scope with a flag is the `bind` mistake the
model retired (§8.3). So:

- **`detach` is retired.** "A fetch that outlives my connection" is the
  connectionless verb (`webhook.send`), not `on.fetch({ detach:true })`.
- Connectionless work is **durable by default**; a connectionless-
  ephemeral fire-and-forget fast path is intentionally not offered until
  a real high-volume case demands it ([[feedback_model_simplicity_safety]]).

## 3. Activation kinds — the runtime's Msg union

| Activation | Export | Scope | When it fires |
|---|---|---|---|
| inbound HTTP (buffered) | `default` | connection | body ≤ 1 MB; > 1 MB → 413 if no `onChunk` |
| inbound HTTP chunk | `onChunk` | connection | per chunk (≤ 1 MB → fires once with the whole body) |
| `on.fetch` result | `onFetchResult` (or `to`) | connection | a connection `on.fetch` returned its whole body |
| `on.fetch` chunk | `onFetchChunk` (or `to`) | connection | per chunk of a streamed `on.fetch` |
| `on.fetch` end | `onFetchDone` (or `to`) | connection | a streamed `on.fetch` terminated |
| `on.kv` / `on.timer` wake | `onWake` (or `to`) | connection | a connection wake fired (held socket) |
| held client disconnected | `onDisconnect` | connection | the held stream closed early |
| `webhook.send` result | the `onResult` target | connectionless | a `webhook.send` completed |
| `cron` / `schedule` fire | the named target | connectionless | scheduled time arrived |
| boot fire | `onBoot` | connectionless | once per fresh deployment |
| subscription fire (generic) | `onSubscription` | connectionless | external push (atproto firehose, etc.) |

The set of *kinds* is closed (runtime-defined). The `to:` option on
`on.*` (and the target on the connectionless verbs) chooses **which
export** a trigger's activation lands in; it does not invent a kind.

The scope column is load-bearing: a **connection** activation runs with
the held socket (it can call `stream.*`/`on.*` and return `next`/a
terminal); a **connectionless** activation has no socket (those are
inert — it does `kv` + connectionless triggers + returns nothing). The
default for `on.kv`/`on.timer` is one generic `onWake` because they're
*edge* wakes — "go look"; the handler re-queries state regardless of
which fired (the SSE cursor pattern, §5.7). `on.fetch` keeps per-result
exports because it carries a payload.

## 4. Buffered vs streaming inbound — the 1 MB ceiling

**Any inbound HTTP request body ≤ 1 MB is delivered in a single
`default` activation** with `request.body` containing the full bytes.
The common case never has to think about streaming.

- **`default` only:** body ≤ 1 MB → one `default` activation; body > 1 MB
  → `413`, handler never runs.
- **`onChunk` only:** any size → per-chunk dispatch. A body ≤ 1 MB fires
  `onChunk` once with the whole body and `request.done = true`; larger
  bodies fire N times. `onChunk` returns `next()` to await the next
  chunk, a terminal to respond.

`onChunk` is strictly more general; `default` is the optimization for
handlers that never deal with chunks. The 1 MB ceiling is customer-
facing; the 64 KiB internal chunk size is implementation detail.

## 5. Worked examples

### 5.1 Buffered request (the 80%+ case)

```js
export default function () {
  return process(request.body);                 // returns the body; status defaults to 200
}
```

### 5.2 Buffered with auth + status

```js
export default function () {
  if (!authorized(request.headers)) { response.status = 401; return 'unauthorized'; }
  return process(request.body);
}
```

### 5.3 Streaming inbound — per-chunk upload to storage

```js
import { next } from 'rove';

export function onChunk() {
  on.fetch(`${STORAGE_URL}/${request.headers['x-key']}?seq=${request.chunkSeq}`,
           { method: 'PUT', body: request.body }, { to: 'onPut' });
  if (request.done) { response.status = 201; return 'uploaded'; }
  return next();                                 // await the next inbound chunk
}

export function onPut() {                        // each PUT result resumes here (held)
  if (request.result.status >= 400) { response.status = 502; return 'storage failed'; }
  return next();
}
```

### 5.4 Gateway — hold the client, forward upstream, return its status

```js
import { next } from 'rove';

export default function () {
  on.fetch('https://upstream.example.com', { method: 'POST', body: request.body },
           { to: 'onUpstream' });
  return next();                                 // held, uncommitted — status still open
}

export function onUpstream() {
  response.status = request.result.status;       // forward upstream's status verbatim
  return request.result.body;
}
```

`next()` keeps the head uncommitted so `onUpstream` can return any
status (a `502`). The fetch is connection-scoped — if the client leaves,
abandoning it is correct.

### 5.5 LLM proxy — streamed connection fetch + held client

```js
import { next } from 'rove';

export default function () {
  on.fetch(LLM_URL, { method: 'POST', body: request.body }, { to: 'onUpstream' });
  return next();                                 // hold the client; wait for the first chunk
}

export function onUpstream() {
  if (request.done) return "";                   // close the held response
  stream.write(transform(request.body));         // emit a chunk (commits the head on first write)
  return next();
}
```

### 5.6 Connectionless work — fire durable, respond now

```js
import { next } from 'rove';

export default function () {
  webhook.send('https://billing.example.com/charge', { body: request.body, onResult: 'onCharge' });
  schedule({ in: '24h' }, 'sendReminder', { user: request.user });
  response.status = 202;
  return 'queued';                               // respond immediately; the above outlive this request
}

export function onCharge() {                      // connectionless — no socket; does work, returns nothing
  kv.set(`charges/${request.result.body.id}`, request.result.body);
}

export function onCron()  { kv.set('last_cron', now()); }
export function onBoot()  { kv.set('booted_at', now()); }
```

### 5.7 SSE notifications — connection + connectionless composed

```js
import { next } from 'rove';

// Connect (or reconnect via Last-Event-ID).
export default function () {
  response.headers = { 'content-type': 'text/event-stream' };       // ambient head
  const since = Number(request.headers['last-event-id'] ?? latestSeq(`notif/${user}/`));
  stream.start();                                                    // open the stream (fires onopen)
  on.kv(`notif/${user}/`, { to: 'onNotify' });
  return next({ since });
}

// Connection-held resume: drain everything since the cursor.
export function onNotify() {
  const rows = kv.range(`notif/${user}/`, { afterSeq: request.ctx.since });
  on.kv(`notif/${user}/`, { to: 'onNotify' });                      // re-arm
  for (const r of rows) stream.write(`id:${r.seq}\ndata:${r.value}\n\n`);
  return next({ since: rows.length ? rows.at(-1).seq : request.ctx.since });
}

// Connectionless cleanup — registered once (e.g. cron('0 3 * * *', 'gcNotifs')).
export function gcNotifs() {
  for (const r of kv.range(`notif/`, { olderThan: '7d' })) kv.delete(r.key);
}
```

`on.kv` (connection, ephemeral) waits for changes *since the read
cursor*; each wake **range-drains** from the cursor (so coalesced wakes
never lose notifications) and advances it in `ctx`. The notifications
live in `kv` (durable) and the client's resume point is its
`Last-Event-ID`, so a dropped connection just reconnects — no durable
server-side connection state. (`effect-algebra.md` §8.5; retention
bounds the reconnect-replay window.)

### 5.8 Fan-in / join — wait for all, then combine

```js
import { next } from 'rove';

export default function () {
  on.fetch(API_A, {}, { to: 'onResult' });       // fetchId: 'a'
  on.fetch(API_B, {}, { to: 'onResult' });       // fetchId: 'b'
  on.timer(30_000, { to: 'onTimeout' });          // deadline
  return next({ a: null, b: null });              // uncommitted: response unknown until both land
}

export function onResult() {
  const ctx = { ...request.ctx, [request.fetchId]: request.result };
  if (ctx.a && ctx.b) return combine(ctx.a, ctx.b);
  return next(ctx);                               // still waiting on the other
}

export function onTimeout() { response.status = 504; return 'upstream timeout'; }
```

`next({ctx})` makes `ctx` the continuation's accumulator. Each fetch
result fires its own `onResult` (value-triggers are delivered
individually — `effect-algebra.md` §8.2), resumes are serialized, and
each `next(ctx)` updates the threaded `ctx` the next resume reads — so
the join is race-free with no lock. `next` (not committing) the whole
time, because the response could be `200` or, via `onTimeout`, `504`.
This is `Promise.all` from primitives — no dedicated combinator.

## 6. Validation — exhaustiveness without a type system

The loader validates `module.exports` against the activations the
module's verbs could trigger (deploy-time warnings/errors, not
request-time):

- If a handler calls `webhook.send` and its `onResult` target is missing
  → warn (result discarded).
- If a handler calls `on.fetch` / `on.kv` / `on.timer` whose `to` target
  (or the conventional export for its kind — `onFetchResult`,
  `onWake`, …) is not exported → warn (wake has nowhere to land).
- If a handler calls `schedule` / `cron` whose target is missing → error
  (a connectionless trigger with no handler is dead on arrival).
- `onChunk` exported but nothing can trigger a receive → warn.
- Unknown `on…` exports (typos) → "did you mean…?".

`stream.*` needs no resume export — it's output. Strict mode (errors
instead of warnings) is per-tenant.

## 7. The `request` global per activation kind

`request` is a module-level global, populated fresh per activation and
**replaced** (not mutated) across a chain — so "no state across
activations" is structural (your prior `request` is gone when the next
fires; the arena reset wipes it). Cross-activation connection state
rides `ctx` (§2.1); disconnect-surviving state rides `kv`.

- **`default`:** `request.body`, `.headers`, `.method`, `.path`,
  `.query`, `.cookies`, `.ip`.
- **`onChunk`:** `request.body` = THIS chunk; `request.done`;
  `request.chunkSeq` (from 0).
- **Connection wakes / fetch resumes:** `request.ctx`, plus
  `request.result` (`on.fetch` whole / `webhook.send`), `request.body` +
  `request.fetchId` (streamed `on.fetch` chunk), or `request.key` /
  `request.value` (`on.kv`).
- **Connectionless fires** (`onCron`, `onBoot`, `onSubscription`, an
  `onResult` callback): origin-specific fields (`cronName`,
  `deploymentId`, `result`, …) but **no** HTTP `headers`/`body`, and the
  connection verbs are inert (§2.4).

## 8. What's gone vs `streaming-model.md` §3 (and prior revisions)

- `request.activation.kind` switch → runtime dispatches by export name
- `__rove_stream({…})` / the `stream` **return verb** → `stream.start()`
  / `stream.write()` **effects** (§2.2); `stream` is now a namespace
- `__rove_next()` → `next()`
- `stream({until})` → `on.*` builder calls (§2.3)
- `return { status, headers, body }` → body-only return; the head is
  ambient `response.*` (matches the engine `extractResponseMetadata`)
- `detach: true` → retired; connectionless outbound is `webhook.send`
- `subscribe.kv` → deferred (`on.kv` covers the connection case)
- the three-way inbound choice → "1 MB ceiling, above → 413 or `onChunk`"
- `ctx.state` scratchpad → forbidden; durable state in `kv`, ephemeral
  connection state in `ctx`

## 9. What's unchanged

- The engine model: pure function per activation, arena reset between
  activations, no closure smuggling
- Effects-accumulate / return-disposition: effects (`kv`, `stream.*`,
  `on.*`, connectionless) accumulate during the activation and fire
  post-commit; the return declares the disposition
- The one rule (`streaming-model.md` §2): a chunk reaches the wire only
  after the activation that produced it has committed — `stream.write()`
  is commit-gated
- Replay: `foldl(handlers, kv0, activations)` over the recorded inputs
- The substrate: blob coordinator, readset replication, content-
  addressed extents; the 64 KiB internal coalesce budget

## 10. Open questions

1. **`stream.*` / `on.*` as ambient namespaces vs imports.** Current:
   `stream`/`on`/`kv`/`response` are ambient (effects/state); only `next`
   (the return ctor) is imported. Keep that split?
2. **Wake re-arm vs persist.** Current model re-declares `on.*` each
   activation (self-cleaning; the SSE loop re-calls `on.kv`). Persistent
   registration (cancel to stop) is the alternative — re-arm chosen for
   simplicity; revisit if a use case wants persistence.
3. **`onError` / module-level state / strict mode.** Thrown exceptions →
   runtime 500 (Erlang posture; defer `onError`); module-top-level `let`
   does not persist (lint to forbid); validation strictness per-tenant.
4. **`default` vs `onInbound`.** Keep `default` for the familiar simple
   case; alias to `onInbound` internally.

## 11. Relation to other plans

- `effect-algebra.md` §8 — the scope model; §8.3 `bind`/`detach`
  retirement; §8.4 watch-before-write; §8.5 "grammar position = scope."
  The verbs here are the customer names for §2's primitives.
- `handler-surface-impl-plan.md` — the phased implementation.
- `collection-lifecycle-map.md` — the state machine the surface lowers
  onto (the impl plan §3 notes the deltas).
- `streaming-model.md` — engine substrate; §1 frame, §2 one rule, §7.X
  blob coordinator unchanged. This supersedes §3's surface.
- `auto-bind-plan.md` — the `detach` mechanism, retired here (§2.6).
- `durable-wake-plan.md` — gap 2.6, the `schedule`/`cron` substrate.
- `primitive-gaps.md` §2.4 — inbound streaming body (`onChunk`).
- `readset-replication-plan.md` — chunk capture making `onChunk` + the
  stream loop replayable.
