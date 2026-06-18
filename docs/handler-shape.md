# Handler shape — pattern-matching at module level

> **Status:** SHIPPED (2026-06-03). All phases of the implementation plan
> landed (the plan doc is folded-and-deleted; this doc is the contract):
> `on.*` connection wakes (Phase 1), the `stream.*` effect surface with
> `__rove_stream` retired (Phase 2), `on.fetch` + `detach` + the customer
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

`next` is an **ambient global** (like `stream`, `on`, `kv`, `response`) —
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
  pattern is lossless — `effect-algebra.md` §6.4).
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
§6.4).

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
(the SSE example, §5.7; the model, `effect-algebra.md` §6.5).

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
§6.1). A `{ durable: true }` / `{ detach: true }` flag can't conjure
that lifecycle; flipping scope with a flag is the `bind` mistake the
model retired (§6.3). So:

- **`detach` is retired.** "A fetch that outlives my connection" is the
  connectionless verb (`webhook.send`), not `on.fetch({ detach:true })`.
- Connectionless work is **durable by default**; a connectionless-
  ephemeral fire-and-forget fast path is intentionally not offered until
  a real high-volume case demands it ([[feedback_model_simplicity_safety]]).

## 3. Activation kinds — the runtime's Msg union

| Activation | Export | Scope | When it fires |
|---|---|---|---|
| inbound HTTP (buffered) | `default` | connection | body ≤ 1 MB; > 1 MB → 413 if no `onChunk` |
| inbound HTTP, headers-first | `onHeaders` | connection | SHIPPED 2026-06-10 (`architecture/routing-and-ingress.md`): module exports `onHeaders` → every body-carrying request dispatches it with an EMPTY body before any body byte is accepted (the client is flow-control-held at the door). Decide from headers alone: early 4xx terminal, or `blob.receive({to}) + next()` to pipe the body socket→storage with zero chunk activations — `{to}` resumes with `request.ctx = {hash, len}` when the object is durable. Uniform regardless of body timing or size |
| inbound HTTP chunk | `onChunk` | connection | per chunk (≤ 1 MB → fires once with the whole body) |
| `on.fetch` result | `onFetchResult` (or `to`) | connection | a connection `on.fetch` returned its whole body |
| `on.fetch` chunk | `onFetchChunk` (or `to`) | connection | per chunk of a streamed `on.fetch` |
| `on.fetch` end | `onFetchDone` (or `to`) | connection | a streamed `on.fetch` terminated |
| `on.kv` / `on.timer` wake | `onWake` (or `to`) | connection | a connection wake fired (held socket) |
| inbound WebSocket frame | `onMessage` | connection | per complete WS data message; `request.activation = { opcode, data }` (opcode 1 = text → string, 2 = binary → Uint8Array); `stream.write` replies (string → text frame, bytes → binary), `next()` parks for the next frame, a terminal return closes. Replies are strictly in message order, and a frame behind an in-flight durable write activates only after that write commits — so each frame reads its predecessors' writes (websocket-plan §4.5 input gate) |
| held client disconnected | `onDisconnect` | connection | the held stream closed early — or the WS client closed / dropped |
| `webhook.send` result | the `onResult` target | connectionless | a `webhook.send` completed |
| `cron` / `schedule` fire | the named target | connectionless | scheduled time arrived |
| boot fire | `onBoot` | connectionless | once per fresh deployment |
| subscription fire (generic) | `onSubscription` | connectionless | external push (atproto firehose, etc.) |

The set of *kinds* is closed (runtime-defined). The `to:` option on
`on.*` (and the target on the connectionless verbs) chooses **which
export** a trigger's activation lands in; it does not invent a kind.

> **Shipped (Phase 4 + finer conventions):** the runtime maps
> `activation_source → export` when the resume path didn't name one.
> `wake_batch` (`on.kv`/`on.timer`) → `onWake`; `disconnect` →
> `onDisconnect` (a missing `onDisconnect` is a no-op — cleanup is
> optional).
>
> **`on.fetch` (bound, connection-scoped) now splits by event shape**
> when no `{to}` is given: a non-streaming fetch (one `final` event with
> the whole body) → `onFetchResult`; a streaming fetch's intermediate
> chunks (`final == false`) → `onFetchChunk`; its terminal event
> (`final == true`) → `onFetchDone`. An explicit `{to}` overrides for
> every event of the fetch (the handler then branches on
> `request.done`).
>
> **`_subscriptions/` fires now dispatch by trigger source:** a boot
> fire → `onBoot`, a kv-react fire → `onSubscription` — so a
> subscription module no longer branches on
> `request.activation.source.kind`. (The manifest `kind=cron`
> subscription and its `onCron` export RETIRED with durable-wake P5(b):
> recurrence is the `cron(spec, target, …)` verb — durable, surviving
> leader change — or a self-re-arming `scheduler.after` for sub-minute
> intervals, seeded from `onBoot`.) `webhook.send` results route through the shim's named
> `onResult`; an unnamed cross-module `next({module})` chain legitimately
> targets that module's `default`, so there is no forced `onSendCallback`
> default.
>
> A missing conventional export is the fail-loud 404 backstop
> (`runModule`). `request.activation.kind` is no longer a dispatch
> discriminator (the named export is); it remains on
> `request.activation` alongside the wake / source payload (`wakes` /
> `overflow` / `write_pressure` / `source`). The inbound-chunk
> (`onChunk`) split in the table above is SHIPPED (gap 2.4,
> 2026-06-10): `request.body` for a chunk activation is a
> **Uint8Array** (chunks are arbitrary bytes — same posture as bound
> fetch chunks), and `next({ctx})` between chunks surfaces as
> `request.ctx` on the following chunk.

The scope column is load-bearing: a **connection** activation runs with
the held socket (it can call `stream.*`/`on.*` and return `next`/a
terminal); a **connectionless** activation has no socket (those are
inert — it does `kv` + connectionless triggers + returns nothing). The
default for `on.kv`/`on.timer` is one generic `onWake` because they're
*edge* wakes — "go look"; the handler re-queries state regardless of
which fired (the SSE cursor pattern, §5.7). `on.fetch` keeps per-result
exports because it carries a payload.

### 3.1 Named-function RPC is handler JS (the `rpc` recipe)

The platform invokes **only** the activation's export (the table
above). The former platform-level `?fn=name&args=…` query and
`{"fn":…,"args":[…]}` POST-body dispatch are RETIRED (decisions.md
§4.5): `request.query` and `request.body` are opaque payload the
engine never interprets. Internal resume targeting (`{to}`,
`next({fn})`, `onResult`) is first-class on the runtime's Request and
unaffected.

A handler that wants named-function routing composes it from
primitives — and because the shim reads `request.query` /
`request.body` in JS, the dispatch inputs land on the replay tape like
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
    if (!fn && request.body) {
      try {
        const b = JSON.parse(request.body);
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
export function onChunk() {
  on.fetch(`${STORAGE_URL}/${request.headers['x-key']}?seq=${request.chunkSeq}`,
           { method: 'PUT', body: request.body }, { to: 'onPut' });
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
  on.fetch('https://upstream.example.com', { method: 'POST', body: request.body },
           { to: 'onUpstream' });
  return next();                                 // held, uncommitted — status still open
}

export function onUpstream() {
  response.status = request.status;              // forward upstream's status verbatim
  return request.body;
}
```

`next()` keeps the head uncommitted so `onUpstream` can return any
status (a `502`). The fetch is connection-scoped — if the client leaves,
abandoning it is correct.

### 5.5 LLM proxy — streamed connection fetch + held client

```js
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
export default function () {
  webhook.send('https://billing.example.com/charge', { body: request.body, onResult: 'onCharge' });
  schedule({ in: '24h' }, 'sendReminder', { user: request.user });
  response.status = 202;
  return 'queued';                               // respond immediately; the above outlive this request
}

export function onCharge() {                      // connectionless on_result — no socket; does work, returns nothing
  if (!request.ok) return;                        // delivery failed (request.ctx.error says why)
  const charge = JSON.parse(request.body);        // the response on the flattened surface
  kv.set(`charges/${charge.id}`, charge);
}

export function onBoot()  { kv.set('booted_at', now()); }
```

### 5.7 SSE notifications — connection + connectionless composed

```js
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
server-side connection state. (`effect-algebra.md` §6.5; retention
bounds the reconnect-replay window.)

### 5.8 Fan-in / join — wait for all, then combine

```js
export default function () {
  on.fetch(API_A, {}, { to: 'onResult' });       // fetchId: 'a'
  on.fetch(API_B, {}, { to: 'onResult' });       // fetchId: 'b'
  on.timer(30_000, { to: 'onTimeout' });          // deadline
  return next({ a: null, b: null });              // uncommitted: response unknown until both land
}

export function onResult() {
  const ctx = { ...request.ctx, [request.fetchId]: { status: request.status, body: request.body } };
  if (ctx.a && ctx.b) return combine(ctx.a, ctx.b);
  return next(ctx);                               // still waiting on the other
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
*brain wiring*, not the brain — the LLM call is the customer's own `on.fetch`
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
  on.fetch(LLM_URL, { method: "POST", headers: authHeaders(),
    body: JSON.stringify({ model, tools: browser.tools(),  // vendor-neutral action schema
      messages: history(ctx.sid).concat({ role: "user", content: browser.render(frame) }) }) },
    { to: "onLLM" });                                      // binds to THIS held chain
  return next(ctx);                                        // read-only turn — a writing frame can't bind on.fetch
}

export function onLLM() {                                  // flattened result surface (§7): request.body/.status/.done
  if (!request.done || request.status >= 400) { browser.status("LLM error"); return next(request.ctx); }
  const reply = JSON.parse(new TextDecoder().decode(request.body));
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
rule as `on.fetch`), and feeds the result back as the tool's result.

```js
browser.getReplay(request, { to: "onReplay" });   // read-only frame; then return next(...)
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
  `.query`, `.cookies`, `.ip`, `.unmaskedIp()`.
- **`onChunk`:** `request.body` = THIS chunk; `request.done`;
  `request.chunkSeq` (from 0).
- **`next()` continuations — one ctx rule (`decisions.md §4.9`):** every
  activation that exists because a prior activation called `next({ctx})`
  reads that payload as **`request.ctx`** — `onMessage`, `onChunk`,
  `onWake` (`on.kv`/`on.timer`), `onDisconnect`, a bound `on.fetch`/
  `blob.get` resume, and an `on_result` callback, all the same way.
  `request.ctx` is `undefined` on the **first** activation of a chain
  (nothing threaded yet) and on a standalone scheduled `durable_wake`
  (which carries `request.activation.msg`). `on.kv`/`on.timer` are edge
  ("go look") wakes — they carry **no** matched key/value; `onWake`
  re-reads authoritative `kv`, and which keys fired is on
  `request.activation.wakes[]` if you need it.
- **Fetch / effect results — one flattened surface:** a bound `on.fetch` /
  `blob.get` resume **and** a `webhook.send` / `blob.put` / `retry`
  `on_result` callback (and a §6.4 held-sync resume) present the result
  identically — the response bytes on **`request.body`** (the whole body
  for a non-streamed fetch, this chunk for a streamed one), with
  `request.status` / `request.ok` / `request.done` (+ `request.fetchId` /
  `request.chunkSeq` for fetch chunks) at the **top level**; the threaded
  ctx / echoed `context` on **`request.ctx`** (bare); and per-delivery
  metadata (`attempts`, `error`, `id`, `headers`, blob `hash`) on
  **`request.activation.*`**. There is **no `request.result`**. (Exception:
  `blob.seal`/`blob.receive` resume with the threaded `{hash, len}` on
  `request.ctx` — that *is* the ctx you threaded, not delivery metadata.)
- **Connectionless fires** (`onBoot`, `onSubscription`, a `cron`/
  `schedule` target): origin-specific fields (`deploymentId`,
  `request.activation.msg`, …) but **no** inbound HTTP `headers`/`body`,
  and the connection verbs are inert (§2.4).

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
- `request.body` is an accessor too. A body your handler never reads
  is **absent from the replay record entirely** (storage/durability
  is unaffected — only the log-side reference is elided). Chunk
  activations are the exception: the chunk payload IS the activation's
  Msg (a binary Uint8Array, §3), so it is always recorded — read or
  not.
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
  "effects":  { "declared": ["kv", "on.fetch"] },
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

## 9. What's gone (vs prior streaming revisions)

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

## 10. What's unchanged

- The engine model: pure function per activation, arena reset between
  activations, no closure smuggling
- Effects-accumulate / return-disposition: effects (`kv`, `stream.*`,
  `on.*`, connectionless) accumulate during the activation and fire
  post-commit; the return declares the disposition
- The one rule (`architecture/routing-and-ingress.md`): a chunk reaches the wire only
  after the activation that produced it has committed — `stream.write()`
  is commit-gated
- Replay: `foldl(handlers, kv0, activations)` over the recorded inputs
- The substrate: blob coordinator, readset replication, content-
  addressed extents; the 64 KiB internal coalesce budget

## 11. Open questions

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

## 12. Relation to other plans

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
