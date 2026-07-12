# Testing handlers with `rewind test`

`rewind test` runs your handlers offline — no cluster, no network — and lets you
assert on exactly what each one did. It exists because a rewind handler is a
**pure function of its inputs**: an activation reads a trigger, some KV, and a
threaded `ctx`, and produces a response, some writes, and some effects. Nothing
else. So a test can supply those inputs, run the handler through the real engine,
and check the outputs — deterministically, in milliseconds.

Tests live in `_tests/*.mjs` next to your handlers and are written in the same JS
your handlers are. `_tests/` never ships — the deploy path strips it (and the
server rejects it), so tests and fixtures stay in your repo.

```
myapp/
  index.mjs
  hooks/onDelivered.mjs
  _tests/
    checkout.mjs
```

Run them from your app directory:

```
rewind test                      # runs ./_tests/*.mjs against ./ handlers
rewind test ./myapp              # a specific app dir
rewind test --update             # re-baseline snapshots
```

Any failing assertion exits non-zero, so it drops straight into CI.

## The shape of a test

You import two things: `scenario` (the world your handlers run in) and `expect`
(the assertion). A scenario produces **nodes** — one per activation — and you
assert on a node directly.

```js
import { scenario, expect } from "rewind:test";

const s = scenario({
  kv: { "cart/jess": JSON.stringify({ item: "book", price: 1200 }) },
  now: "2026-07-01T00:00:00Z",
  seed: 42,
});

// Run the inbound request. `req` is a node — forcing it (by asserting) runs the
// handler once and memoizes the result.
const req = s.inbound({ method: "POST", path: "/checkout", body: { user: "jess" } });

expect(req.status).toBe(202);
expect(req).toHaveWritten("order/jess", { status: "pending" });
expect(req).toHaveFetched(/stripe/);
```

`scenario(config)` takes:

- `kv` — the starting store. It's a **closed world**: a key that isn't there
  reads `null` (`not_found`), never an error. Non-string values are
  JSON-stringified for you, so you can write `{ item: "book" }` instead of a
  hand-escaped string.
- `now` — a fixed clock (ISO string or ms). `Date.now()` in the handler returns
  it, so time-dependent handlers are deterministic.
- `seed` — the deterministic seed for `Math.random()` / `crypto.randomUUID()`.
- `sourceDir` — where handler code resolves from (defaults to the app dir you
  ran `rewind test` in). Use it to point a scenario at a different tree.
- `entry` — the handler module (defaults to `index.mjs`).
- `instances` / `root` — seed other stores for a `platform.*` handler:
  `instances: { acme: { kv: {…} } }` seeds another instance's store, `root: { kv: {…} }`
  the platform root store (see [Platform and admin handlers](#platform-and-admin-handlers)).
- `rootToken` — the operator token `platform.auth.checkRootToken` validates against.
- `admin` — mark the run as the admin handler so `platform.*` is allowed. It's
  admin-only and **off by default**, so a normal handler that touches it throws.
- `tenant` / `correlationId` — the per-chain identity the engine pins on every
  activation (`request.tenant` and `request.correlation_id`). The worker sets them
  in prod — inbound mints the correlation id, every resume inherits it — so a
  scenario supplies them once and they thread through inbound → WS frame →
  fetch/receive resumes automatically. Set them when a handler branches on the
  per-connection identity (e.g. `browser.getReplay`, which needs both). A single
  activation can override with `inbound({ correlationId })`.

The **request body** is whatever you pass as `inbound({ body })` (JSON-stringified
if it's not a string). Omit it and the request is bodyless — reading `request.text`
/ `.bytes` / `.json` returns empty (`""`, 0-length), exactly as a real bodyless
request (a GET, an empty POST) does. (A *replayed* recording is stricter: reading a
body the original run never read is a divergence — but an authored world asserts a
real empty request, not a missing one.)

## A node's surface

- `req.status` — the response status (the ambient `response.status`).
- `req.body` — the terminal return value (or, when held, the threaded ctx).
- `req.ctx` — the ctx a held activation parked with `next({ctx})`.
- `req.disposition` — `"terminal"` (it responded) or `"held"` (it called
  `next()` and is waiting).
- `req.kv(key)` — the effective value of `key` after this activation (starting KV
  plus its writes), so `req.kv("order/jess").status` reads what the handler left.
- `req.instanceKv(id, key)` / `req.rootKv(key)` — the same, for another instance's
  isolated store (`platform.scope(id).kv`) / the platform root store
  (`platform.root`). See [Platform and admin handlers](#platform-and-admin-handlers).
- `req.effects` / `req.frames` — the raw effect log / the frames it `stream.write`'d.

## Assertions

`expect(value)` accepts a node or a plain value:

```js
expect(node.status).toBe(200);
expect(node.kv("order/jess")).toEqual({ status: "paid" });
expect(node).toHaveWritten("order/jess", { status: "pending" });  // subset match; arrays are exact
expect(node).toHaveFetched(/stripe/);
expect(node).toHaveSent("webhook", { url: "https://hooks.example.com/notify" }); // webhook.send
expect(node).toHaveSent("email", { to: ["jess@example.com"] });    // email.send (to is a list)
expect(node).toHaveScheduled();                                    // a timer / kv / cron wake
expect(node).toHaveSentFrame(/welcome/);                           // a stream.write / WS frame
expect(node).toMatchSnapshot("checkout-inbound");
```

Every matcher also negates via `.not` (`expect(node).not.toHaveFetched(/paypal/)`).
A failing assertion **records and continues** — the whole file runs, and you get
every failure at once, not just the first.

## Following what a handler set in motion

Most handlers don't finish in one activation: they hold the connection with
`next()` and are resumed later — when a fetch result arrives, a timer fires, a
watched key changes, a WebSocket frame lands. Each resume is its **own**
activation with the previous one's writes and ctx folded forward. A test drives
those resumes by **resolving the effect** the held activation emitted — you
supply only the external answer; the engine builds the dependent activation.

### A fetch result

```js
// The inbound emitted after.fetch(...) and held. Resolve the upstream response
// to get the callback activation, with the parent's writes + ctx threaded in.
const charged = req.fetch(/stripe/).resolve({ status: 200, body: { id: "ch_1" } });

expect(charged).toHaveWritten("order/jess", { status: "paid" });
expect(charged.kv("order/jess")).toEqual({ status: "paid" });
```

Fork over several outcomes from the same held activation (it runs once, shared):

```js
const [paid, declined] = req.fetch(/stripe/).branch([
  { status: 200, body: { id: "ch_1" } },
  { status: 402 },
]);
expect(paid).toHaveWritten("order/jess", { status: "paid" });
expect(declined).toHaveWritten("order/jess", { status: "failed" });
```

An invariant that must hold across every outcome, without naming them:

```js
req.fetch(/stripe/).cases([{ status: 200 }, { status: 402 }, { status: 500 }])
  .forEachPath((node) => expect(node.kv("order/jess").status).toMatch(/paid|failed/));
```

A **streamed** fetch (`after.fetch({ stream: true })`) delivers chunk by chunk:

```js
const done = req.fetch(/upstream/).stream(["chunk-1", "chunk-2", "chunk-3"]);
expect(done.body).toBe("chunk-1chunk-2chunk-3");   // an accumulate-in-kv handler reconstructs it
```

When the fetch's `on` names a **different module** (a path like `hooks/onX.mjs`,
not a bare same-module export), `.resolve()` runs that module at its `default`
export — the same entry-switch `sendCallback`/`wake` use. So a continuation that
lives in its own file (an `oidc.rp()` internal, a shared hook) resolves correctly,
and you can also drive one in isolation with `scenario.fetchResult` (below).

### Concurrent effects that race

When one held activation emits **two or more** fetches whose results race, an
invariant may need to hold no matter which upstream answers first. `whenConcurrent`
folds every arrival order, threading each leg's writes into the next resume's
overlay (so a later leg reads an earlier leg's write — read-your-writes across the
race):

```js
const inter = req.whenConcurrent([
  { match: /a\.example/, resolve: { status: 200 }, label: "A" },
  { match: /b\.example/, resolve: { status: 200 }, label: "B" },
]);

inter.forEachOrder((terminal, order) => {   // once per arrival order (all permutations)
  expect(terminal.body).toEqual({ total: 30 });
});
inter.invariant((terminal) => terminal.body.total);   // one pass iff every order agrees
```

`forEachOrder` enumerates all permutations (capped at 5 legs); past that, pass the
orders you care about explicitly with `.orders([["B", "A"], …])`.

### A timer, a watched key, a disconnect

These carry no external payload — they resume the held connection with its
`next({ctx})` threaded through:

```js
const woke   = held.clock.advance("1h").fire();          // after.ms timer
const notified = held.wakeKv({ "msg/room1/1": "hi" });   // after.kv — the change folds into the overlay
const gone   = held.disconnect();                        // client closed → onDisconnect
```

Resolving on an activation that already responded (didn't hold) throws — `after.*`
only fires while the connection is held, so the test mirrors reality.

### A WebSocket

A WS connection runs no code at upgrade; each frame runs `onMessage`. Drive it
frame by frame — the connection threads its ctx and KV writes forward:

```js
const ws = s.ws({ path: "/chat" });
const m1 = ws.receive("hello");
expect(m1).toHaveSentFrame(/echo:hello/);
const m2 = m1.receive("again");          // next frame, state folded from m1
const closed = m1.disconnect();          // → onDisconnect
ws.receive(new Uint8Array([1, 2, 3]), { binary: true });   // a binary frame
```

The frame is the request payload: inside `onMessage`, `request.text` is the
frame text (what `browser.message()` parses as JSON), a binary frame's
`request.bytes` is the decoded bytes, and the frame is on
`request.activation.data` too — read whichever the handler uses.

A WS handler can issue an `after.fetch` (or arm a timer / `after.kv`) mid-chain
and keep going: resolve the fetch, then call `.receive(nextFrame)` on the
resolved node to run the next `onMessage` on the same connection, seeing the
resume's threaded ctx and writes — the agent-loop shape (frame → fetch → resume →
next frame):

```js
const f1 = ws.receive(JSON.stringify({ t: "start" }));   // issues after.fetch, holds
const r  = f1.fetch(/llm/).resolve({ status: 200, body: "…" });  // onResult runs, re-holds
const f2 = r.receive(JSON.stringify({ t: "next" }));     // continues the conversation
```

### A streamed upload (headers-first)

A handler that exports `onHeaders` runs *before* the body is accepted, and the
only body-accepting move from there is `blob.receive({ on })` then `return
next()` — the body streams straight to storage with no chunk activations, and the
chain resumes at `on` once the object is durable. Drive the entry with
`scenario.inboundHeaders`, then resume the receive with `.receive().stored(...)`:

```js
const h = s.inboundHeaders({ method: "PUT", path: "/upload?path=logo.png",
                             headers: { authorization: "Bearer …" } });
expect(h.disposition).toBe("held");            // onHeaders armed the receive + held

const stored = h.receive().stored({ hash: "abc123", len: 4096 });
expect(stored.status).toBe(200);               // onStored ran with request.ctx = {hash, len, app}
```

`stored({ hash, len })` resumes at the receive's `on` with `request.status
=== 200` and `request.ctx = { hash, len, app }`, where `app` echoes the issue-time
ctx (for a scoped `platform.scope(t).blob.receive({ ctx })`, that's how `onStored`
recovers the target path). A torn upload is `stored({ ok: false })` — the resume
runs with `request.status === 0` (a hard failure — `status` is the single
success signal, no `request.ok`; issue #7) and `request.ctx = { error, app }`,
nothing stored.

### The deploy doors (result-in-ctx)

`platform.compile(files, { on })` and `platform.scope(t).deploy.stampManifest(
entries, { on })` are the two admin deploy doors: like `blob.receive`, they bind
to the held chain (`return next()` after) and deliver their result on the
resume's `request.ctx`, not `request.body`. Drive them with `.compile().staged(
...)` and `.stampManifest().cut(...)`:

```js
const file = s.inbound({ method: "POST", path: "/v1/deploy/file",
  headers: { authorization: "Bearer …" },
  body: JSON.stringify({ tenant: "acme", path: "index.mjs", source: "…" }) });
expect(file.disposition).toBe("held");           // the compile door armed + held

const staged = file.compile().staged({
  results: [{ path: "index.mjs", source_hex: "aa11", bytecode_hex: "bb22" }] });
expect(staged.status).toBe(200);                 // onFileStaged ran with request.ctx
```

`staged({ results })` resumes at the compile's `on` with `request.ctx = { ok:
true, results, app }`, where `app` echoes the issue-time `platform.compile(...,
{ ctx })` (override it with `staged({ app })`). A failed compile is `staged({ ok:
false, status, error })` — the resume sees `request.ctx = { ok: false, status,
error }`. `stampManifest().cut({ dep_id })` resumes at the stamp's `on` with
`request.ctx = { ok: true, dep_id }` (a failed PUT is `cut({ ok: false, dep_id })`,
still echoing the dep_id). When a handler arms more than one compile door (a
handler batch and a package batch), select with `.compile({ on: "onPkgStaged" })`.

## Detached delivery callbacks

`webhook.send` and `email.send` fire *after* the handler commits — their `on`
handler runs later as its own activation, not a resume of the sending one. Test
that handler directly with a supplied delivery result:

```js
const delivered = s.sendCallback({
  on: "hooks/onDelivered.mjs",
  result: { status: 200, attempts: 1 },
  ctx: { order: "o9" },
});
expect(delivered).toHaveWritten("delivery/o9", { ok: true });
```

A `schedule(...)` or `cron(...)` target fires the same way — later, as its own
connectionless activation, with your payload on `request.ctx` and delivery
metadata on `request.activation`. Author that fire directly with `wake`:

```js
const fired = s.wake({
  on: "jobs/reminder.mjs",
  ctx: { user: "ada" },        // arrives as request.ctx
  key: "reminder/ada",         // request.activation.key (omit if none)
});
expect(fired).toHaveWritten("reminder/ada", { count: 1 });
expect(fired).toHaveScheduled("jobs/reminder");   // it re-armed the next one
```

Both `schedule` and `cron` deliver a target this way, so one `wake(...)` is one
firing. As with `sendCallback`, the target is tested in isolation — the
scheduler's own queueing and at-least-once firing aren't re-run.

A bare **fetch continuation module** — the `on` of an `after.fetch`/`http.fetch`,
in its own file — is drivable the same way with `scenario.fetchResult`, given an
upstream result on the flattened `request.{status, ok, done, body}` surface:

```js
const done = s.fetchResult({
  on: "hooks/onFetched.mjs",
  status: 502,                  // 5xx → the handler derives ok:false (no request.ok, #7)
  ctx: { key: "beta" },        // arrives as request.ctx
});
expect(done).toHaveWritten("result/beta", { ok: false, status: 502 });
```

## Platform and admin handlers

Handlers on the `__admin__` control plane use `platform.*` — cross-tenant KV, the
platform root store, instance lifecycle, root-token auth. That surface is
**admin-only**: off a normal tenant handler every call throws, so a scenario has
to opt in with `admin: true` before `platform.*` is allowed.

Each store is isolated, exactly like production: a tenant's own `kv`, another
instance's store (`platform.scope(id).kv`), and the root store (`platform.root`)
never bleed into one another. Seed the other stores on the scenario, and read
their post-state back with `instanceKv` / `rootKv`:

```js
const s = scenario({
  admin: true,                                    // platform.* is admin-only
  rootToken: "op-secret",                         // what checkRootToken validates
  instances: { acme: { kv: { profile: "{}" } } }, // seed acme's isolated store
});

const r = s.inbound({
  method: "POST", path: "/provision",
  headers: { authorization: "op-secret" },
});
expect(r.instanceKv("acme", "profile")).toEqual({ plan: "pro" });  // a platform.scope write
expect(r.rootKv("instance/acme")).toEqual({ created: true });      // a platform.root write

// A wrong (or missing) root token is rejected — checkRootToken returns true only
// for the configured token, so both paths are testable:
const denied = s.inbound({
  method: "POST", path: "/provision",
  headers: { authorization: "wrong" },
});
expect(denied.status).toBe(403);
```

The handler behind this writes into the scoped and root stores and gates on the
token:

```js
export default function () {
  if (!platform.auth.checkRootToken(request.headers["authorization"])) {
    response.status = 403; return "forbidden";
  }
  platform.scope("acme").kv.set("profile", JSON.stringify({ plan: "pro" }));
  platform.root.set("instance/acme", JSON.stringify({ created: true }));
  return { ok: true };
}
```

Leaving out `admin` (the default) makes every `platform.*` call throw — which is
itself worth asserting if a handler is supposed to stay off that surface.

## Snapshots

`toMatchSnapshot(name)` captures a node's response, disposition, body, and
effects into `_tests/__snapshots__/<file>.json`. The first run writes it; later
runs compare; a mismatch fails until you re-baseline with `rewind test --update`.
Useful for pinning a handler's whole behavior without spelling out every field.

## What it does and doesn't tell you

`rewind test` runs your handler logic through the real engine, so it's faithful
to what the handler *computes*: reads, writes, emitted effects, branch behavior,
held-resume chains. It does **not** run the distributed machinery — consensus,
routing, real network fetches, the durable retry ladder. You supply each external
result; the platform's delivery of it is covered by the platform's own tests. A
green `rewind test` means "the handler does the right thing with these inputs,"
which is exactly the layer you own.
