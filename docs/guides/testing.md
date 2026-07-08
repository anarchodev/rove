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

## A node's surface

- `req.status` — the response status (the ambient `response.status`).
- `req.body` — the terminal return value (or, when held, the threaded ctx).
- `req.ctx` — the ctx a held activation parked with `next({ctx})`.
- `req.disposition` — `"terminal"` (it responded) or `"held"` (it called
  `next()` and is waiting).
- `req.kv(key)` — the effective value of `key` after this activation (starting KV
  plus its writes), so `req.kv("order/jess").status` reads what the handler left.
- `req.effects` / `req.frames` — the raw effect log / the frames it `stream.write`'d.

## Assertions

`expect(value)` accepts a node or a plain value:

```js
expect(node.status).toBe(200);
expect(node.kv("order/jess")).toEqual({ status: "paid" });
expect(node).toHaveWritten("order/jess", { status: "pending" });  // subset match; arrays are exact
expect(node).toHaveFetched(/stripe/);
expect(node).toHaveSent("email", { to: "jess@example.com" });     // webhook / email cmd
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
