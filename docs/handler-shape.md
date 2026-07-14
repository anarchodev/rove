# Handler shape — pattern-matching at module level

> **Status:** SHIPPED (2026-06-03). All phases of the implementation plan
> landed (the plan doc is folded-and-deleted; this doc is the contract):
> `on.*` connection wakes (Phase 1), the `stream.*` effect surface with
> `__rove_stream` retired (Phase 2), `on.fetch` (now `after.fetch`) + `detach` + the customer
> `http.fetch` spelling retired (Phase 3), named-export dispatch by
> activation kind (Phase 4), and `schedule`/`cron` (Phase 5). It
> supersedes the `__rove_stream` / `request.activation.kind`-switch
> surface and the old multi-shape return values. The engine model (coalesce
> budget, blob coordinator, one-rule semantics — see
> `architecture/routing-and-ingress.md`) is **unchanged**;
> only the customer-facing handler API changed. Phase 6 (polish) landed
> the ambient `next` verb; the §6 export-coverage validation is CLI-side
> (static analysis over arenajs-WASM), backstopped at runtime by the
> missing-`onWake` 404.
>
> **Revised 2026-07-05 (rev 3 — the ergonomics arc,
> `decisions.md` §4.11).** The grammar is
> `after.*` (was `on.*`; `after.ms` was `on.timer`) with ONE
> callback-target key — `{on: "module.method"}` — across every effect;
> `webhook.send(url, opts)` takes a positional url; the durable
> the timer surface is ONE verb (`schedule`, with `.cancel`/`.get` —
> the `scheduler` lib folded in 2026-07-06); the payload is uniform
> `request.bytes`/`.text`/`.json` on every payload-carrying activation;
> threaded context is `ctx` in / `request.ctx` out everywhere (one-ctx,
> no exceptions); fetch ids are `ftch_…` on all three surfaces. The
> pre-rename spellings (`on.*`, `{to}`, `{on_result}`/`{context}`,
> `webhook.send({url})`, `scheduler.after`, `request.activation.msg`,
> snake_case field aliases) lived for one deploy cycle and are **GONE**
> (window closed 2026-07-06), and **`request.body` is retired too**
> (2026-07-06, once the replay driver gained accessor parity) — the
> payload surface is `request.bytes`/`.text`/`.json`, full stop. The
> replay driver alone still synthesizes a `body` so records from
> pre-retirement deployments replay their pinned code.
>
> **Revised 2026-06-02 (rev 2 — `stream.*` model).** Organized around one
> axis — **scope: current-connection vs connectionless** — derived in
> [`effect-algebra.md`](effect-algebra.md) §6. **The verb is the scope;
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
| Side-effects (`Cmd`) | effects called in the body — connection (`stream.*`, `after.*`) + connectionless (`webhook.send`/`schedule`/`cron`), queued during the activation, fired post-commit |
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
| **Connection triggers** | `after.ms(ms,{on?})` / `after.kv(prefix,{on?})` / `after.fetch(url,opts?,{on?})` | current connection (ephemeral) |
| **Connectionless triggers** | `webhook.send` / `schedule` / `cron` | connectionless (durable, new request) |
| **Disposition (return)** | `next({ctx?})` · terminal body / `""` | the only return shapes |

The body **accumulates** the Cmd as you compute — `kv.*` builds the
Model; `stream.*`, `after.*`, and the connectionless verbs are effects that
fire post-commit — and the **return value** picks the connection's
disposition. Together that's the TEA pair `(Model', Cmd)`
(`effect-algebra.md` §6 is the derivation; §1 the determinism invariant).

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

`next` is an **ambient global** (like `stream`, `after`, `kv`, `response`) —
no import. `next()` resumes THIS module's conventional export for the
activation kind; you never name the module or export.

### 2.2 Connection output — `stream.start` / `stream.write`

`stream` is an **effect namespace** (ambient, like `kv`), not a return
verb. It produces the streaming response over time:

- `stream.start()` — commit the head (from ambient `response.*`) and
  begin the response. Use it to open an SSE stream so the client's
  `onopen` fires before any data. Optional — the first `stream.write()`
  starts implicitly.
- `stream.write(chunk)` — emit a chunk. **Commit-gated**: the chunk
  reaches the wire only after this activation's writes commit
  (the one rule — `architecture/routing-and-ingress.md`). Call it as many times per activation as you
  like; raw bytes (SSE `data:` framing is yours to write).

**In a continuing activation (`onWake` etc.), call `stream.start()`
unconditionally, before any conditional writes.** The runtime classifies
an activation as streaming by whether it touched `stream.*`
(`finishResponse`, the one classification point): a wake that happens to
write zero frames and returns `next()` without `stream.start()` is parked
as a plain continuation — not a stream re-park — and the stream closes.
`stream.start()` is idempotent on an already-started stream, so the
unconditional call is free.

Pair `stream.*` with `next()` to keep producing across activations;
close with a terminal return:

```js
stream.start();
after.kv(`notif/${user}/`, { on: 'onNotify' });
return next({ since });
```

`stream` is **only** a namespace — `stream.start()` / `stream.write()`,
never `return stream(...)`.

### 2.3 Connection triggers — `after.*`

`after.*` registers a ONE-SHOT wake **for the current connection** — body builder
calls that re-invoke a handler still holding the socket. Ephemeral
(drop with the connection); node-local (never touch raft).

- `after.ms(ms)` — wake after `ms` milliseconds. Named for its unit
  (durations are always ms; there is deliberately no `after.seconds`
  family — write `after.ms(5 * 60_000)`).
- `after.kv(prefix, { on? })` — wake when any key under `prefix` changes
  **since the version this activation read** (anchored to the read view,
  so a write between "you read" and "you parked" still fires it, and the
  common "wait on a key, write it from a connectionless callback"
  pattern is lossless — `effect-algebra.md` §6.4).
- `after.fetch(url, opts?, { on? })` — perform an outbound request and wake
  on its result (whole or chunked). Connection-scoped outbound; its
  durable twin is `webhook.send` (§2.4). On the resume, `request.ctx` is the
  fetch's own `{ctx}` option if you passed one, else the connection's
  `next({ctx})` memory (decisions.md §4.14) — one rule on WS and HTTP. So a
  no-ctx fetch on a held chain still reads the state you threaded via `next()`.

`{ on: "module.method" }` routes the wake to a different export (still
holding *this* connection) — the UNIVERSAL callback-target key, the
same spelling every effect takes. Without `on`, an `after.kv`/
`after.ms` wake defaults to `onWake`; `after.fetch` to
`onFetchResult`/`onFetchChunk`/`onFetchDone` by event shape (§3).

```js
const rooms = request.ctx?.rooms ?? [];
for (const room of rooms) after.kv(`rooms/${room}/`);  // dynamic sets are natural
return next({ rooms });
```

The runtime arms `after.*` wakes **before** firing any connectionless
effects of the same activation, so a wake can't be missed even when a
connectionless callback writes the key it watches (`effect-algebra.md`
§6.4).

### 2.4 Connectionless triggers — `webhook.send` / `schedule` / `cron`

These create a **connectionless request** — a fresh, durable activation
with no held socket. They survive leader changes, route by tenant, and
run whether or not anyone is connected. Each names the export it invokes:

- `webhook.send(url, { on: "module.method", … })` — durable
  outbound; run the target as a new request when it completes.
- `schedule({ at } | { in }, "module.method", ctx?)` — run the target
  once, at a time.
- `cron(spec, "module.method")` — run the target on a recurring schedule.

For `schedule`/`cron`, the target is a single string. A bare module
(`"jobs/reminder"`) fires its `default` export; the `module.method` form
fires a named export — but the method suffix is only recognized **after a
`.mjs`/`.js` module** (`"reports.mjs.weekly"` → the `weekly` export of
`reports.mjs`). So `"reports.mjs"` is the whole module (not module
`reports` + method `mjs`), and to name a method you include the
extension: `"jobs/reminder.mjs.retry"`.

A connectionless request can read/write `kv`, register more
connectionless triggers, and do work — but it has **no connection**, so
the disposition verbs and `stream.*` / `after.*` are **inert** there. To
surface a connectionless result *to* a still-connected client, compose:
the callback writes `kv`, the connection watches that key with `after.kv`
(the SSE example, §5.7; the model, `effect-algebra.md` §6.5).

> `subscribe.kv` (a runtime durable kv-react) is **deferred** — `after.kv`
> covers the connection case; no runtime durable kv-react for now.

### 2.5 The Model — `kv`

`kv.get` / `kv.set` / `kv.delete` are neither connection nor
connectionless — they're the **Model** half of `(Model, Cmd)`. They stay
in the body because they're **read-your-writes**: `kv.set('x',1);
kv.get('x')` returns `1` in the same activation (the kvexp overlay).
That immediate visibility is why a write can't be deferred — it builds
the Model the rest of the activation reads. The trigger/output effects
(`stream.*`, `after.*`, connectionless), by contrast, never return a result
into *this* activation — their results arrive as future Msgs — which is
why they're Cmd-builders, not Model mutations.

### 2.6 The rule, and why there are no scope flags

> **All wakes registered through `after.*` are for the current connection.
> Every other trigger creates a connectionless request.**

Scope must be a *verb*, not a flag, because a connectionless trigger is
**durable**, and durability isn't a boolean — it's a Model-row +
commit-gate + reload-on-leader-change overlay (`effect-algebra.md` §2.2,
§6.1). A `{ durable: true }` / `{ detach: true }` flag can't conjure
that lifecycle; flipping scope with a flag is the `bind` mistake the
model retired (§6.3). So:

- **`detach` is retired.** "A fetch that outlives my connection" is the
  connectionless verb (`webhook.send`), not `after.fetch({ detach:true })`.
- Connectionless work is **durable by default**; a connectionless-
  ephemeral fire-and-forget fast path is intentionally not offered until
  a real high-volume case demands it ([[feedback_model_simplicity_safety]]).

## 3. Activation kinds — the runtime's Msg union

| Activation | Export | Scope | When it fires |
|---|---|---|---|
| inbound HTTP (buffered) | `default` | connection | body ≤ 1 MB; > 1 MB → 413 if no `onChunk` |
| inbound HTTP, headers-first | `onHeaders` | connection | SHIPPED 2026-06-10 (`architecture/routing-and-ingress.md`): module exports `onHeaders` → every body-carrying request dispatches it with an EMPTY body before any body byte is accepted (the client is flow-control-held at the door). Decide from headers alone: early 4xx terminal, or `blob.receive({on}) + next()` to pipe the body socket→storage with zero chunk activations — `{on}` resumes with `request.ctx = {hash, len}` when the object is durable. Uniform regardless of body timing or size |
| inbound HTTP chunk | `onChunk` | connection | per chunk (≤ 1 MB → fires once with the whole body) |
| `after.fetch` result | `onFetchResult` (or `to`) | connection | a connection `after.fetch` returned its whole body |
| `after.fetch` chunk | `onFetchChunk` (or `to`) | connection | per chunk of a streamed `after.fetch` |
| `after.fetch` end | `onFetchDone` (or `to`) | connection | a streamed `after.fetch` terminated |
| `after.kv` / `after.ms` wake | `onWake` (or `to`) | connection | a connection wake fired (held socket) |
| inbound WebSocket frame | `onMessage` | connection | per complete WS data message; the frame payload reads as `request.bytes`/`.text`/`.json` (§7); `request.activation = { opcode, data }` keeps the framing detail (opcode 1 = text → `data` is a string, 2 = binary → Uint8Array); `stream.write` replies (string → text frame, bytes → binary), `next()` parks for the next frame, a terminal return closes. Replies are strictly in message order, and a frame behind an in-flight durable write activates only after that write commits — so each frame reads its predecessors' writes (`architecture/websockets.md`, the input gate) |
| held client disconnected | `onDisconnect` | connection | the held stream closed early — or the WS client closed / dropped |
| `webhook.send` result | the `{on}` target | connectionless | a `webhook.send` completed |
| `cron` / `schedule` fire | the named target | connectionless | scheduled time arrived |
| subscription fire (generic) | `onSubscription` | connectionless | external push (atproto firehose, etc.) |

The set of *kinds* is closed (runtime-defined). The `to:` option on
`after.*` (and the target on the connectionless verbs) chooses **which
export** a trigger's activation lands in; it does not invent a kind.

> **Shipped (Phase 4 + finer conventions):** the runtime maps
> `activation_source → export` when the resume path didn't name one.
> `wake_batch` (`after.kv`/`after.ms`) → `onWake`; `disconnect` →
> `onDisconnect` (a missing `onDisconnect` is a no-op — cleanup is
> optional).
>
> **`after.fetch` (bound, connection-scoped) now splits by event shape**
> when no `{on}` is given: a non-streaming fetch (one `final` event with
> the whole body) → `onFetchResult`; a streaming fetch's intermediate
> chunks (`final == false`) → `onFetchChunk`; its terminal event
> (`final == true`) → `onFetchDone`. An explicit `{on}` overrides for
> every event of the fetch (the handler then branches on
> `request.done`).
>
> **`_subscriptions/` fires dispatch to `onSubscription`** (kv-react —
> the one live subscription kind), so a subscription module never
> branches on `request.activation.source.kind`. A fire is a
> **coalesced level trigger with at-least-once delivery**
> (durable-kv-subscriptions): a write under the watched prefix sets a
> durable dirty marker in the SAME writeset (the owed fire survives
> crashes and leader changes), N writes coalesce into ≥1 fire, and the
> payload names only the dirty prefix —
> `request.activation.source = {kind:"kv", prefix}`, never a key/op.
> The handler reads current committed state under the prefix and
> reconciles; it must tolerate a redundant re-fire and must NOT assume
> one fire per write. (The manifest
> `kind=cron` subscription and its `onCron` export RETIRED with
> durable-wake P5(b): recurrence is the `cron(spec, target, …)` verb —
> durable, surviving leader change — or a self-re-arming
> `schedule({in}, …, {key})` re-arming for sub-minute intervals. The
> `kind=boot`
> subscription and its `onBoot` export RETIRED 2026-07-05, unused:
> seed registrations from any handler activation — they are
> idempotent by key and `_sched/*` entries are durable kv that survive
> deploys.) `webhook.send` results route through the shim's named
> `{on}` target; an unnamed cross-module `next({module})` chain legitimately
> targets that module's `default`, so there is no forced `onSendCallback`
> default.
>
> A missing conventional export is the fail-loud 404 backstop
> (`runModule`). `request.activation.kind` is no longer a dispatch
> discriminator (the named export is); it remains on
> `request.activation` alongside the wake / source payload (`wakes` /
> `source`). The inbound-chunk
> (`onChunk`) split in the table above is SHIPPED (gap 2.4,
> 2026-06-10): a chunk activation's payload is arbitrary bytes — read
> it as `request.bytes` (or `.text`/`.json`, same as every payload
> surface, §7) — and `next({ctx})` between chunks surfaces as
> `request.ctx` on the following chunk.

The scope column is load-bearing: a **connection** activation runs with
the held socket (it can call `stream.*`/`after.*` and return `next`/a
terminal); a **connectionless** activation has no socket (those are
inert — it does `kv` + connectionless triggers + returns nothing). The
default for `after.kv`/`after.ms` is one generic `onWake` because they're
*edge* wakes — "go look"; the handler re-queries state regardless of
which fired (the SSE cursor pattern, §5.7). `after.fetch` keeps per-result
exports because it carries a payload.

### 3.1 Named-function RPC is handler JS (the `rpc` recipe)

The platform invokes **only** the activation's export (the table
above). The former platform-level `?fn=name&args=…` query and
`{"fn":…,"args":[…]}` POST-body dispatch are RETIRED (decisions.md
§4.5): `request.query` and the request payload are opaque bytes the
engine never interprets. Internal resume targeting (`{on}`,
`next({fn})`) is first-class on the runtime's Request and
unaffected.

A handler that wants named-function routing composes it from
primitives — and because the shim reads `request.query` /
`request.text` in JS, the dispatch inputs land on the replay tape like
every other read:

```js
function rpc(fns) {
  return function () {
    let fn = null, args = [];
    for (const part of (request.query || "").split("&")) {
      const eq = part.indexOf("=");
      const k = eq === -1 ? part : part.slice(0, eq);
      if (k !== "fn" && k !== "args") continue;
      const v = eq === -1 ? "" : decodeURIComponent(part.slice(eq + 1).replace(/\+/g, "%20"));
      if (k === "fn" && v) fn = v;
      else if (k === "args" && v) { try { args = JSON.parse(v); } catch (_) {} }
    }
    if (!fn && request.text) {
      try {
        const b = request.json;
        if (b && typeof b.fn === "string") { fn = b.fn; args = Array.isArray(b.args) ? b.args : []; }
      } catch (_) {}
    }
    const f = fn ? fns[fn] : null;
    if (!f) { response.status = 404; return "no such fn: " + fn; }
    return f(...args);
  };
}

function whoami() { return "it me"; }
function add(a, b) { return a + b; }
export default rpc({ whoami, add });
```

The wire shapes are unchanged — `GET /?fn=whoami` and
`POST {"fn":"add","args":[1,2]}` work exactly as before; the dispatch
just belongs to the app now (the `__admin__` dashboard handler,
`web/admin/index.mjs`, is the dogfood example).

## 4. Buffered vs streaming inbound — the 1 MB ceiling

**Any inbound HTTP request body ≤ 1 MB is delivered in a single
`default` activation** with the full payload readable as
`request.bytes` / `.text` / `.json` (§7).
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

### 4.1 Memory: the per-activation allocation budget

Each activation runs against a fixed-size request arena (100 MiB). The
default allocator is a bump arena: **the budget is cumulative
allocation, not live memory** — transient garbage counts in full, which
is what buys the platform its per-request reset cost of one cursor
write. A handler that exhausts it is transparently re-executed once
under a reclaiming GC allocator (budget = peak live set, ~20-30%
slower), and the platform remembers — subsequent activations of that
handler skip straight to the GC regime until its next deploy. You never
opt in or out; the visible effect of a "churny" handler is latency, not
failure. Replays reproduce whichever regime the live request completed
under.

## 5. Worked examples

### 5.1 Buffered request (the 80%+ case)

```js
export default function () {
  return process(request.text);                // read the payload; status defaults to 200
}
```

### 5.2 Buffered with auth + status

```js
export default function () {
  if (!authorized(request.headers)) { response.status = 401; return 'unauthorized'; }
  return process(request.text);
}
```

### 5.3 Streaming inbound — per-chunk upload to storage

```js
export function onChunk() {
  after.fetch(`${STORAGE_URL}/${request.headers['x-key']}?seq=${request.chunkSeq}`,
           { method: 'PUT', body: request.bytes, on: 'onPut' });
  if (request.done) { response.status = 201; return 'uploaded'; }
  return next();                                 // await the next inbound chunk
}

export function onPut() {                        // each PUT result resumes here (held)
  if (request.status >= 400) { response.status = 502; return 'storage failed'; }
  return next();
}
```

### 5.4 Gateway — hold the client, forward upstream, return its status

```js
export default function () {
  after.fetch('https://upstream.example.com',
           { method: 'POST', body: request.bytes, on: 'onUpstream' });
  return next();                                 // held, uncommitted — status still open
}

export function onUpstream() {
  response.status = request.status;              // forward upstream's status verbatim
  return request.bytes;                          // raw response bytes, forwarded verbatim
}
```

`next()` keeps the head uncommitted so `onUpstream` can return any
status (a `502`). The fetch is connection-scoped — if the client leaves,
abandoning it is correct.

### 5.5 LLM proxy — streamed connection fetch + held client

```js
export default function () {
  after.fetch(LLM_URL, { method: 'POST', body: request.bytes, on: 'onUpstream' });
  return next();                                 // hold the client; wait for the first chunk
}

export function onUpstream() {
  if (request.done) return "";                   // close the held response
  stream.write(transform(request.bytes));        // emit a chunk (commits the head on first write)
  return next();
}
```

### 5.6 Connectionless work — fire durable, respond now

```js
export default function () {
  webhook.send('https://billing.example.com/charge', { body: request.text, on: 'onCharge' });
  schedule({ in: '24h' }, 'sendReminder', { user: request.user });
  response.status = 202;
  return 'queued';                               // respond immediately; the above outlive this request
}

export function onCharge() {                      // connectionless {on} callback — no socket; does work, returns nothing
  if (request.status < 200 || request.status >= 300) return;  // delivery failed (request.activation.error says why; status 0 = never reached)
  const charge = request.json;                    // the response payload, parsed (§7)
  kv.set(`charges/${charge.id}`, JSON.stringify(charge));
}
```

### 5.7 SSE notifications — connection + connectionless composed

Notifications are written under zero-padded sequence keys —
`notif/{user}/{seq:020}` — so ascending key order IS delivery order and
the last-seen KEY is the cursor. `kv.prefix(prefix, cursor)` resumes
after the cursor key.

```js
const PAD = (n) => String(n).padStart(20, '0');

// Connect (or reconnect via Last-Event-ID = the last seq delivered).
export default function () {
  response.headers = { 'content-type': 'text/event-stream' };       // ambient head
  const last = request.headers['last-event-id'];
  const cursor = last ? `notif/${user}/${PAD(Number(last))}` : null;
  stream.start();                                                    // open the stream (fires onopen)
  after.kv(`notif/${user}/`, { on: 'onNotify' });
  return next({ cursor });
}

// Connection-held resume: drain everything past the cursor key.
export function onNotify() {
  const rows = kv.prefix(`notif/${user}/`, request.ctx.cursor);
  after.kv(`notif/${user}/`, { on: 'onNotify' });                    // re-arm
  for (const r of rows) {
    const seq = Number(r.key.slice(r.key.lastIndexOf('/') + 1));
    stream.write(`id:${seq}\ndata:${r.value}\n\n`);
  }
  return next({ cursor: rows.length ? rows.at(-1).key : request.ctx.cursor });
}

// Connectionless cleanup — cron('0 3 * * *', 'gcNotifs'); each value
// carries its write time, so retention is a scan-and-delete.
export function gcNotifs() {
  const horizon = Date.now() - 7 * 24 * 3600 * 1000;
  let cursor = null;
  for (;;) {
    const page = kv.prefix('notif/', cursor, 1000);
    if (page.length === 0) break;
    for (const r of page) if (JSON.parse(r.value).at < horizon) kv.delete(r.key);
    cursor = page.at(-1).key;
  }
}
```

`after.kv` (connection, ephemeral) waits for changes *since the read
view*; each wake **drains the prefix past the cursor** (so coalesced
wakes never lose notifications) and advances the cursor in `ctx`. The
notifications live in `kv` (durable) and the client's resume point is
its `Last-Event-ID`, so a dropped connection just reconnects — no
durable server-side connection state. (`effect-algebra.md` §6.5;
retention bounds the reconnect-replay window.)

### 5.8 Fan-in / join — wait for all, then combine

```js
export default function () {
  const a = after.fetch(API_A, { on: 'onResult' });   // returns the fetch id (`ftch_…`)
  const b = after.fetch(API_B, { on: 'onResult' });
  after.ms(30_000, { on: 'onTimeout' });                  // deadline
  return next({ a, b, got: {} });                         // uncommitted: response unknown until both land
}

export function onResult() {
  // request.fetchId is the SAME `ftch_…` string after.fetch returned.
  const got = { ...request.ctx.got,
                [request.fetchId]: { status: request.status, body: request.text } };
  if (got[request.ctx.a] && got[request.ctx.b])
    return combine(got[request.ctx.a], got[request.ctx.b]);
  return next({ ...request.ctx, got });                   // still waiting on the other
}

export function onTimeout() { response.status = 504; return 'upstream timeout'; }
```

`next({ctx})` makes `ctx` the continuation's accumulator. Each fetch
result fires its own `onResult` (value-triggers are delivered
individually — `effect-algebra.md` §6.2), resumes are serialized, and
each `next(ctx)` updates the threaded `ctx` the next resume reads — so
the join is race-free with no lock. `next` (not committing) the whole
time, because the response could be `200` or, via `onTimeout`, `504`.
This is `Promise.all` from primitives — no dedicated combinator.

### 5.9 Browser agent — let an LLM drive your own UI (`browser.*`)

`browser.*` is a JS-shim (same pattern as `webhook.send` — `globals/browser.js`)
for building "a Playwright for LLMs" **scoped to the customer's own app**: the
in-page SDK (`_static/rove-agent.js`) opens a held WebSocket, sends an enriched,
pixel-free DOM/accessibility **snapshot** (`[ref] role "name" = value (state)`),
and executes ref-targeted actions the handler sends back. The handler is the
*brain wiring*, not the brain — the LLM call is the customer's own `after.fetch`
with their key; durable reasoning state lives in `kv` (the durable-brain /
ephemeral-hands split). Scope is **same-origin only by construction** — an agent
acting inside the customer's own page is ~equivalent to JS they could already
run there, so there's no new trust boundary (see `decisions.md` §4.8).

```js
// Held WS chain: each page snapshot → call the LLM → send one action.
export function onMessage() {
  const frame = browser.message(request);                 // decode the ws_message
  const ctx = request.ctx || {};
  if (!frame) return next(ctx);
  if (frame.t === "hello") { kv.set(`goal/${frame.sid}`, frame.goal); return next({ sid: frame.sid }); }
  if (frame.t !== "snapshot") return next(ctx);           // result/bye/confirm_result

  browser.status("thinking…");
  after.fetch(LLM_URL, { method: "POST", headers: authHeaders(),
    body: JSON.stringify({ model, tools: browser.tools(),  // vendor-neutral action schema
      messages: history(ctx.sid).concat({ role: "user", content: browser.render(frame) }) }) },
    { on: "onLLM" });                                      // binds to THIS held chain
  return next(ctx);                                        // read-only turn — a writing frame can't bind after.fetch
}

export function onLLM() {                                  // flattened result surface (§7): request.json/.status/.done
  if (!request.done || request.status >= 400) { browser.status("LLM error"); return next(request.ctx); }
  const reply = request.json;
  const action = pickAction(reply);                        // adapt the model's tool call → {op, ref, ...}
  if (!action) { browser.done(reply.text); return next(request.ctx); }
  if (isDestructive(action)) { browser.confirm({ id: action.id, prompt: "Allow?", action }); }
  else browser.act(action);                                // page executes, auto-sends a fresh snapshot → onMessage
  return next(request.ctx);
}
```

Perception is **structural by default** (DOM + geometry + computed visibility +
occlusion); pixel screenshots are a separate **opt-in** tier (`getDisplayMedia` →
`blob.put`). The SDK renders a non-disableable "agent is driving · STOP"
indicator + kill switch. The brain is pluggable: the same snapshot/action
protocol can be driven by the customer's handler-hosted LLM (above) or, as a
fast-follow, the end-user's own local Claude over MCP — no change to the SDK or
page protocol.

**Replay context — the "why" channel (`browser.getReplay`).** The third
perception tier (DOM = what, screenshot = how, **replay = why**). `getReplay`
pulls this session's recent *server-side* activations — handler runs, their kv
reads/writes and effects, status + timing — from the durable log so the brain
can root-cause a wrong UI instead of guessing from the symptom. It's a brain
tool (`browser.tools({replay:true})`): the model emits `getReplay`, the handler
issues it from a **read-only** frame (a writing frame can't bind the fetch — same
rule as `after.fetch`), and feeds the result back as the tool's result.

```js
browser.getReplay(request, { on: "onReplay" });   // read-only frame; then return next(...)
export function onReplay() {                        // fetch callback (read-only)
  const text = browser.renderReplay(browser.replayResult(request));
  return callLLM(request.ctx.sid, toolResult(text), parkCtx);  // feed it back to the model
}
```

It reads through the internal `rewind-logs.internal` door, which the engine pins
to **this handler's own tenant** — a customer can read only its own logs, never
another's (`decisions.md` §4.8/§4.10). By default it filters by the engine
per-connection session key (`request.correlation_id`, auto-stamped on every
activation as the reserved `_corr` tag), so no per-frame tagging is needed; pass
`{session}` to filter by a `request.tag("session", …)` value instead (survives
reconnects).

**User-defined index tags (`request.tag`).** Not browser-specific — any handler
can attach low-cardinality index tags to its request's log record:
`request.tag("flow", "checkout")`. The log query surface then filters
`?tag.flow=checkout` (and `/v1/{tenant}/session/{id}` is sugar for
`tag.session`). Bounded + fail-loud: ≤4 tags/record, keys `[a-z0-9_]` (a leading
`_` is reserved for engine tags like `_corr`), value ≤64 bytes — a violation
throws (it's a handler bug, not a silent drop). Keep values low-cardinality (a
plan, a flow, a session — never a per-row unique like a raw user id).

## 6. Validation — exhaustiveness without a type system

The loader validates `module.exports` against the activations the
module's verbs could trigger (deploy-time warnings/errors, not
request-time):

- If a handler calls `webhook.send` and its `{on}` target is missing
  → warn (result discarded).
- If a handler calls `after.fetch` / `after.kv` / `after.ms` whose `{on}`
  target (or the conventional export for its kind — `onFetchResult`,
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

- **The payload, uniformly (`bytes` / `text` / `json`):** every
  activation that carries a payload — inbound `default`, an `onChunk`
  chunk, a bound `after.fetch`/`blob.get` resume, a result callback,
  a WS `onMessage` frame — presents it through the SAME three views:
  **`request.bytes`** (Uint8Array, the raw payload), **`request.text`**
  (lenient UTF-8 — invalid sequences decode as U+FFFD), and
  **`request.json`** (`JSON.parse(request.text)`; throws on non-JSON —
  a handler asking for JSON that isn't JSON is a real error). All
  three derive from the same recorded bytes. On a payload-less
  activation (wakes, `cron`/`schedule` targets, `onDisconnect`) all
  three read `undefined`. (`request.body` — whose type varied by
  activation kind — is RETIRED; the accessors are the only payload
  surface.)
- **`default`:** the payload views above, plus `.headers`, `.method`,
  `.path`, `.query`, `.cookies`, `.ip`, `.unmaskedIp()`. `request.path`
  never includes the query string: for `GET /a/b?x=1`, `path` is
  `"/a/b"` and the query lives only on `request.query` (`"x=1"`, or
  `null` when the URL has none).
- **`onChunk`:** `request.bytes` = THIS chunk; `request.done`;
  `request.chunkSeq` (from 0).
- **`next()` continuations — one ctx rule (`decisions.md §4.9`):** every
  activation that exists because a prior activation called `next({ctx})`
  reads that payload as **`request.ctx`** — `onMessage`, `onChunk`,
  `onWake` (`after.kv`/`after.ms`), `onDisconnect`, a bound `after.fetch`/
  `blob.get` resume, and a `webhook.send`-family `{on}` callback, all the same way.
  `request.ctx` is `undefined` on the **first** activation of a chain
  (nothing threaded yet). A `cron`/`schedule` target reads the payload
  it was scheduled with as `request.ctx` too — the one-ctx rule has no
  exceptions. `after.kv`/`after.ms` are edge ("go look") wakes — they
  carry **no** matched key or value; `onWake` re-reads authoritative
  `kv`. What the resume tells you is **which watch fired**, on
  **`request.activation.wakes[]`**: one entry per fired arm, `{ kind:
  "kv", prefix, firedAt }` (the armed prefix, exactly as you passed it
  to `after.kv`) or `{ kind: "timer", firedAt }`, with `firedAt` in
  milliseconds since epoch. A burst of writes under one prefix is one
  entry (latest `firedAt` wins) — the signal is complete by
  construction, so there is nothing to overflow and no missed-wakes
  counter to check. Identical on every resume path (a streaming chain,
  a buffered held `next()`, and a held WebSocket).
- **Fetch / effect results — one flattened surface:** a bound `after.fetch` /
  `blob.get` resume **and** a `webhook.send` / `blob.put` / `retry`
  `{on}` callback (and a §6.4 held-sync resume) present the result
  identically — the response payload on **`request.bytes`/`.text`/
  `.json`** (the whole body for a non-streamed fetch, this chunk for a
  streamed one), with `request.status` / `request.done`
  (+ `request.fetchId` / `request.chunkSeq` for fetch chunks) at the
  **top level**. **`request.status` is the single success signal — there
  is no `request.ok`.** Branch on the status: `200 ≤ status < 300` is
  success; a non-zero non-2xx is an upstream error you can inspect
  (`request.status === 502`); and **`request.status === 0`** is a hard
  transport failure (timeout, DNS, connect refused, policy block —
  we never reached a server). One field, three cases, nothing derived
  to disagree with it. (A derived `ok` boolean used to ride here; it was
  removed because it was fully recomputable from `status` yet drifted
  into three disagreeing definitions — issue #7. If you want the web
  `Response.ok` shorthand, write it yourself:
  `const ok = request.status >= 200 && request.status < 300`. The
  `webhook.send` / `retry` durability shims classify *delivery* with a
  wider `status < 400` rule — a 302 is a delivered webhook — but that is
  the shim's own retry bookkeeping; your `{on}` handler still just reads
  `request.status`.) The threaded `ctx` on **`request.ctx`** (bare); and
  per-delivery metadata (`attempts`, `error`, `id`, `headers`, blob
  `hash`) on **`request.activation.*`**. `request.fetchId` is the SAME
  opaque `ftch_…` string `after.fetch()` returned, so the two compare
  equal. `request.fetchesPending` counts this chain's in-flight bound
  fetches including this one — branch on
  `request.done && request.fetchesPending === 1` for "last chunk of
  the last fetch". There is **no `request.result`**. (Exception:
  `blob.seal`/`blob.receive` resume with the threaded `{hash, len}` on
  `request.ctx` — that *is* the ctx you threaded, not delivery metadata.)
- **Connectionless fires** (`onSubscription`, a `cron`/`schedule`
  target): the scheduled payload on `request.ctx`, origin-specific
  metadata on `request.activation.*` (`scheduledAtNs`, the schedule
  `id`/`key`, a kv-react fire's `source`), but **no** inbound HTTP
  `headers`/payload, and the connection verbs are inert (§2.4).

### 7.1 The request surface is read-recorded

Everything on `request` your handler can branch on is a replay input,
so it is **recorded on access** (the `request_reads` tape channel —
the tape stores exactly what your code read, nothing else; that IS the
data-minimization story, see `decisions.md` §4.6):

- `request.headers` is a flat lowercase object of **accessors**, one
  per wire header. Header *names* are always recorded (so
  `Object.keys` replays faithfully); a header's *value* is recorded
  only when you read it. Pseudo-headers (`:method` etc.) and the IP
  transport headers (`x-forwarded-for`, `x-real-ip`,
  `cf-connecting-ip`, `forwarded`) are not present — the client IP is
  reachable only via the two surfaces below. Duplicate names: last
  value wins. Assigning to `request.headers.x` throws in module code
  (accessor without setter); decorate `request` itself instead
  (`request.auth = …` still works).
- `request.cookies` materializes on first access; the access counts
  as reading the whole `cookie` header.
- The payload views (`request.bytes` / `.text` / `.json`) are
  accessors too, and record ONE shared body-read fact — reading any
  (or several) of them records once. An inbound
  body your handler never reads is **absent from the replay record
  entirely** (storage/durability is unaffected — only the log-side
  reference is elided). Chunk / fetch-result / WS activations are the
  exception: their payload IS the activation's Msg (§3), so it is
  always recorded — read or not.
- `request.ip` is the **masked** client IP — IPv4 with the last octet
  zeroed (`203.0.113.0`), IPv6 truncated to /48 (`2001:db8:85a3::`) —
  derived from `cf-connecting-ip`, else the rightmost (edge-appended,
  spoof-resistant) `x-forwarded-for` entry; `null` when no edge proxy
  reported one. Masked covers coarse geo and abuse heuristics without
  putting a precise IP on the tape.
- `request.unmaskedIp()` returns the raw client IP. It is a *method*
  deliberately: calling it is your explicit decision, as the data
  controller, to process precise IPs — and the call puts the raw IP
  on your replay tape, where your retention window applies.

On replay, reading anything the original run didn't read raises a
loud `REPLAY DIVERGENCE` error rather than silently returning
`undefined`.

## 8. App manifest (reserved seam)

A bundle MAY ship a root **`manifest.json`** declaring the app's
identity and intent:

```json
{
  "name": "link-shortener",
  "version": "1.0.0",
  "config":   { "schema": { "API_KEY": { "type": "string" } } },
  "effects":  { "declared": ["kv", "after.fetch"] },
  "metadata": { "description": "…", "homepage": "…" }
}
```

Required: `name` + `version` (non-empty strings). Optional: `config`
(install-time secrets/config schema), `effects` (declared — later
auto-derivable from the replay tape), `metadata` (listing). Unknown
top-level fields are accepted while the schema is still wet.

**Why now, even though nothing consumes it.** This is the deliberate
seam for the self-hosters marketplace (a community-installable app = a
tenant). Apps written *today* should be born-distributable; retrofitting
a manifest later means re-authoring every app. So the seam is reserved
pre-launch even though the consumer (install-time capability grants, a
registry, runtime config injection) is post-launch.

**Status — reserved + INERT.**
- **Validated at deploy.** `deployManifest` (files-server) structurally
  validates a root `manifest.json` before mutating the working tree; a
  malformed one rejects the deploy `400 InvalidAppManifest` (immediate
  author feedback). Absent is fine — the file is optional.
- **Born-distributable for free.** `manifest.json` is an ordinary static
  bundle file, so it ships content-addressed in the deployment and
  travels with the app — no separate storage.
- **Nothing consumes it yet.** No capability enforcement, no registry,
  and no runtime `_deploy/manifest` pointer. The `_deploy/manifest`
  *kv* key is reserved for whichever consumer first needs the active
  manifest without resolving the file blob; it deliberately is *not*
  written today (it would have to be threaded through three distinct
  release paths — the Zig bootstrap release, the `__admin__`
  `publishRelease` RPC, and the seed — and a one-of-three wiring would
  be a half-seam).

The validator lives in `rove-files` (`app_manifest.zig`); see the
self-hosters marketplace plan for the consuming side.

## 9. Reserved for the platform (names you must not use)

Pre-customer, the platform claims these namespaces so it can grow the surface
later without colliding with anything a handler already relies on. Reserving a
name now is free; reclaiming one after handlers depend on it is a breaking
change (Hyrum's law). See `architecture/format-versioning.md` §7.1/§7.3/§7.6.

- **Export names.** Handlers dispatch by export name (§3). The `on*` prefix is
  the activation-handler namespace; `onError` / `onPanic` are specifically
  reserved for a future uncaught-exception callback (§12 open question; today a
  throw → runtime 500). Don't export `onError`/`onPanic` for your own use.
- **Effect option keys.** Every effect options object (`after.fetch`,
  `webhook.send`, `http.subscribe`, `blob.*`, `email.send`, …) reserves keys
  beginning with `$` for future platform directives (e.g. a `$rewind` hint
  block). Unknown keys are ignored today — keep your own option keys to plain
  identifiers so a future platform directive can't collide with them.
- **`request.*` fields.** The request object reserves the `request.rewind`
  namespace for future platform-provided per-activation metadata. Your own
  per-chain state lives on `request.ctx` (your shape, threaded via `next({ctx})`).
- **`kv` keys.** Any leading-`_` key is platform-reserved (§2.5;
  `architecture/format-versioning.md` §7.1). Customer keys use the non-`_` space.
- **HTTP headers.** `x-rewind-*` and `x-rove-internal-*` are stripped from the
  inbound `request.headers` and rejected from responses
  (`architecture/format-versioning.md` §7.3). `x-rove-correlation-id` is the one
  platform-set header you may read.
- **Reserved identities.** The `__name__` tenant form (`__admin__`, `__auth__`,
  `__replay__`) and `__system/*` module paths are platform-only.
- **Platform identifiers are opaque.** Treat every platform-issued id —
  `request.actor.request_id`, a deployment id, a fetch/subscription id, a
  session id — as an opaque token. Compare it for equality and pass it back
  verbatim where an API expects it, but do **not** parse, decode, slice, or
  assume an ordering/structure: the encoding (length, charset, any embedded
  fields such as the node that minted it) is an internal detail that may change.
  These now carry Stripe-style type prefixes — `request.actor.request_id` is
  `req_…`, a deployment id is `dep_…`, `request.session.id` is `sess_…`, and
  `activation.fetch_id` is `ftch_…` — precisely so the format stays versionable
  behind the prefix. Treat everything after the prefix as opaque; a handler that
  depends on a bare-hex shape (or the prefix's exact contents) will break
  (`architecture/format-versioning.md` §7.5).

## 10. What's gone (vs prior streaming revisions)

> This list has teeth: `src/js/doc_examples.zig` fails `zig build test`
> if any retired spelling below appears in a ```js example in this
> document or in a `globals/*.js` `@example` — and it compiles +
> executes the examples besides. Add a retirement here → add its
> spelling to that lint's list.

Ergonomics arc (2026-07-04/05; the old spellings lived for one deploy
cycle — the dual-name window, closed 2026-07-06):

- `on.*` → `after.*`; `on.timer(ms)` → `after.ms(ms)`
- `{to}` / `{on_result}` / positional-only targets → the universal
  `{on: "module.method"}` callback key (exception: `schedule`/`cron`
  keep their positional target — the target IS the payload there)
- `{context}` → `{ctx}`; `request.activation.msg` → `request.ctx`
  (one-ctx, no exceptions)
- `webhook.send({url, …})` → `webhook.send(url, opts)`
- `scheduler.*` → folded into `schedule` (2026-07-06): `schedule(when,
  target, ctx?, opts?)` + `schedule.cancel`/`schedule.get`; there is no
  `scheduler` global. Interim history: `scheduler.after` had already
  become `scheduler.in` in the window ("after" is exclusively the
  connection-wake namespace — the verb is the scope)
- bare-hex fetch ids → `ftch_…` on all three surfaces (the
  `after.fetch()` return, `request.fetchId`,
  `request.activation.fetchId`)
- snake_case handler-visible fields → camelCase (`bodyTruncated`,
  `scheduledAtNs`, `activation.fetchId`)
- per-surface `request.body` types → uniform `request.bytes`/`.text`/
  `.json`; `request.body` retired outright (2026-07-06)
- `kind=boot` subscriptions + `onBoot` → retired outright (unused):
  seed registrations from any handler activation — idempotent by key,
  `_sched/*` entries are durable kv that survive deploys
- `return Uint8Array` now ships raw bytes; `kv.set` takes primitives
  only; `stream.write` takes string|Uint8Array only; a provided
  unserializable `next({ctx})` throws (the fail-loud sweep, plan §2.1)

Prior streaming revisions:

- `request.activation.kind` switch → runtime dispatches by export name
- `__rove_stream({…})` / the `stream` **return verb** → `stream.start()`
  / `stream.write()` **effects** (§2.2); `stream` is now a namespace
- `__rove_next()` → `next()`
- `stream({until})` → `after.*` builder calls (§2.3)
- `return { status, headers, body }` → body-only return; the head is
  ambient `response.*` (matches the engine `extractResponseMetadata`)
- `detach: true` → retired; connectionless outbound is `webhook.send`
- `subscribe.kv` → deferred (`after.kv` covers the connection case)
- the three-way inbound choice → "1 MB ceiling, above → 413 or `onChunk`"
- `ctx.state` scratchpad → forbidden; durable state in `kv`, ephemeral
  connection state in `ctx`

## 11. What's unchanged

- The engine model: pure function per activation, arena reset between
  activations, no closure smuggling
- Effects-accumulate / return-disposition: effects (`kv`, `stream.*`,
  `after.*`, connectionless) accumulate during the activation and fire
  post-commit; the return declares the disposition
- The one rule (`architecture/routing-and-ingress.md`): a chunk reaches the wire only
  after the activation that produced it has committed — `stream.write()`
  is commit-gated
- Replay: `foldl(handlers, kv0, activations)` over the recorded inputs
- The substrate: blob coordinator, readset replication, content-
  addressed extents; the 64 KiB internal coalesce budget

## 12. Open questions

1. **`stream.*` / `after.*` as ambient namespaces vs imports.** Current:
   `stream`/`on`/`kv`/`response` are ambient (effects/state); only `next`
   (the return ctor) is imported. Keep that split?
2. **Wake re-arm vs persist.** Current model re-declares `after.*` each
   activation (self-cleaning; the SSE loop re-calls `after.kv`). Persistent
   registration (cancel to stop) is the alternative — re-arm chosen for
   simplicity; revisit if a use case wants persistence.
3. **`onError` / module-level state / strict mode.** Thrown exceptions →
   runtime 500 (Erlang posture; defer `onError`); module-top-level `let`
   does not persist (lint to forbid); validation strictness per-tenant.
4. **`default` vs `onInbound`.** Keep `default` for the familiar simple
   case; alias to `onInbound` internally.

## 13. Relation to other plans

- `effect-algebra.md` §6 — the scope model; §6.3 `bind`/`detach`
  retirement; §6.4 watch-before-write; §6.5 "grammar position = scope."
  The verbs here are the customer names for §2's primitives.
- `architecture/effects-and-handlers.md` — the collection-lifecycle state
  machine the surface lowers onto.
- `architecture/routing-and-ingress.md` — the engine substrate (the one rule,
  coalescing, blob coordinator), unchanged.
- `architecture/effects-and-handlers.md` — the `detach` mechanism, retired here (§2.6).
- `architecture/effects-and-handlers.md` "Durable scheduled wake" — the
  `schedule`/`cron` substrate (gap 2.6; decisions in `decisions.md` §3.7).
- `architecture/routing-and-ingress.md` — inbound streaming body (`onChunk`).
- `architecture/effects-and-handlers.md` — chunk capture making `onChunk` + the
  stream loop replayable.
