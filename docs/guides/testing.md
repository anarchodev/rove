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
  it, so time-dependent handlers are deterministic. Handler time is **UTC**:
  local-time `Date` methods (`getHours`, `getTimezoneOffset`, `toString`) run in
  UTC regardless of your machine's timezone, matching production (UTC servers) —
  so a date-formatting test can't green offline and shift in prod.
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
- `emailBudget` — a per-activation `email.send` allowance. Production meters
  sends through a per-instance token bucket; offline they're unmetered unless
  this is set, in which case the N+1-th send in an activation throws the same
  `Error` prod does (`e.code === "rate_limited"`), so the catch branch is
  testable.
- `tenant` / `correlationId` — the per-chain identity the engine pins on every
  activation (`request.tenant` and `request.correlation_id`). The worker sets them
  in prod — inbound mints the correlation id, every resume inherits it — so a
  scenario supplies them once and they thread through inbound → WS frame →
  fetch/receive resumes automatically. Set them when a handler branches on the
  per-connection identity (e.g. `browser.getReplay`, which needs both). A single
  activation can override with `inbound({ correlationId })`. Un-supplied, they
  are still pinned — prod always sets them — with the placeholders `"sim"`
  (tenant) and `""` (correlation id), and `request.session` is `null` unless
  injected, so the documented `session === null` branch is reachable offline.

The **request body** is whatever you pass as `inbound({ body })` (JSON-stringified
if it's not a string). For a **binary** request body pass `inbound({ bodyBinary })`
(a `Uint8Array` or a base64 string) — it round-trips byte-exact on `request.bytes`.
Pass `inbound({ export })` to drive a specific export directly (an authored-dispatch
test) instead of the activation's default. (Misspelling a world/`scenario()` field
now fails loud with a "did you mean" hint, rather than being silently ignored.)
Omit the body and the request is bodyless — reading `request.text`
/ `.bytes` / `.json` returns empty (`""`, 0-length), exactly as a real bodyless
request (a GET, an empty POST) does. On a payload-less **resume** (a wake, a
`cron`/`schedule` target, `onDisconnect`) all three read `undefined`, exactly as
live. (A *replayed* recording is stricter: reading a body the original run never
read is a divergence — but an authored world asserts a real empty request, not a
missing one.)

The rest of the request surface matches the worker rule for rule: `request.ip`
is the **masked** form of the authored `inbound({ ip })` (v4 last octet zeroed,
v6 kept to the /48) with the raw value on `request.unmaskedIp()`, and both read
`null` when no ip is authored; `request.activation.kind` is set on every
activation; and `request.tag(key, value)` enforces prod's validation (key 1–32
bytes of `[a-z0-9_]`, no leading `_`; value 1–64 bytes, no control characters;
max 4 distinct keys) — each accepted tag lands in the effect log as
`{kind: "tag"}`. The retired surfaces (`request.body`, the pre-rename `on.*`)
don't exist in a test or sim run.

## A node's surface

- `req.status` — the response status (the ambient `response.status`, after
  the worker's coercion + clamp to 100–599).
- `req.body` — the terminal return value (or, when held, the threaded ctx).
  When the handler returned a `Uint8Array`, this is a byte-exact
  `Uint8Array` (prod ships raw bytes); when a first-hop terminal followed
  `stream.write` calls, the buffered chunks are prepended — the string you
  read is the full wire body.
- `req.response` — the vetted response head, exactly what the worker would
  emit: header names lowercased, reserved/hop-by-hop/`x-rewind-*` names and
  non-string or CR/LF values silently dropped (32-entry cap), `Set-Cookie`
  entries `Domain=`-stripped, and `content-type: application/json`
  auto-stamped on object returns unless the handler set its own.
- `req.ctx` — the ctx a held activation parked with `next({ctx})`.
- `req.disposition` — `"terminal"` (it responded) or `"held"` (it called
  `next()` and is waiting).
- `req.kv(key)` — the effective value of `key` after this activation (starting KV
  plus its writes), so `req.kv("order/jess").status` reads what the handler left.
- `req.instanceKv(id, key)` / `req.rootKv(key)` — the same, for another instance's
  isolated store (`platform.scope(id).kv`) / the platform root store
  (`platform.root`). See [Platform and admin handlers](#platform-and-admin-handlers).
- `req.effects` / `req.frames` — the raw effect log / the frames it `stream.write`'d.
- `req.ok` / `req.error` — did the activation complete cleanly? A handler that
  **throws** gets exactly the production outcome: `status` 500, the body
  `handler threw: …`, any response head it set discarded, and its KV writes
  and armed effects **rolled back** — they won't satisfy `toHaveWritten` /
  `toHaveFetched` and won't fold into resumes (they stay on `req.effects`
  tagged `rolledBack` for debugging). `req.error` carries the message and
  stack. A missing export 404s (`onDisconnect` is an optional no-op, and a
  module without `onHeaders`/`onChunk` falls back to its `default`), and a
  handler that returns a never-settling promise responds `200` with the body
  `{}` — all mirroring the worker, so an error-path test predicts production.
  The `kv.*` write guards fire the same way: a non-string value (object, array,
  `null`, `undefined`) throws a `TypeError`, a write into a platform-reserved
  `_` prefix throws `Error{code:"reserved_key"}`, and an oversized key/value
  throws `key_too_large` / `value_too_large` — so a `try/catch` on `err.code`
  behaves offline exactly as in production. `kv.prefix` pages identically too:
  an omitted or non-positive `limit` returns 100, and any request is capped at
  1000, so a pagination loop written against a test won't silently truncate live.

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

A bound fetch's `on` is a **bare export in the same module** — a `/` or `.`
module path throws at the call site, offline exactly as live (the cross-module
continuation surfaces are `webhook.send`'s `on` and the durable `schedule`
targets). A continuation module that lives in its own file is driven in
isolation with `scenario.fetchResult` (below).

Two outcomes are not yours to script. An effect that **never fires in prod**
is excluded from matchers and folds: a connection-scoped effect (`after.ms` /
`after.kv` / `after.fetch` / `stream.write`) recorded by an activation that
returned a terminal body instead of `next()`, or by a connectionless one (a
`schedule`/`webhook` callback, a disconnect), is tagged `dropped` in the
bundle with a warning naming it — so `.not.toHaveFetched(...)` passes, as it
should. And resolving a **success** for a URL prod categorically blocks
(plain `http://`, localhost, an SSRF-blocklisted address like
`169.254.169.254`) fails the test loudly naming the policy — the only
outcome such a fetch ever delivers live is the terminal transport failure,
`.resolve({ status: 0 })`, which stays authorable.

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

Each armed wake resumes into its OWN `{on}` export — an `after.ms(..,{on:"onTick"})`
fires `onTick`, an `after.kv("x/",{on:"onData"})` fires `onData`. Two matching
constraints on the fold keep it honest with the worker:

- **`clock.advance(d).fire()` only fires a timer the clock has reached.** Advancing
  by less than the armed `after.ms(N)` throws, rather than delivering a wake prod
  wouldn't. When a handler arms several `after.ms` on one connection, the worker
  keeps just the LAST — a single timer slot — so `.fire()` resolves the
  last-registered interval and `{on}`.
- **`wakeKv(changes)` only fires when a change key falls under an armed prefix.** A
  change entirely outside every `after.kv` prefix throws (it would validate a
  resume the worker never triggers). Keys outside the prefixes still fold into the
  KV overlay — they just can't be the trigger. Pass `{prefix}` to pick which armed
  `after.kv`'s export resumes when several are watching.

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

A frame stays live for the next frame only if it re-held via `next()`. A frame
that returns a terminal value, or throws, closes the socket and destroys the
chain — so `.receive()`/`.disconnect()` on that node throw (the worker cannot
deliver another frame). A throwing frame closes *without* running
`onDisconnect`. And a client close *before any frame* (`s.ws(...).disconnect()`
with no prior `.receive()`) runs nothing at all — the chain is established
lazily on the first frame, so there is no `onDisconnect` to fire.

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

### A streamed upload (raw onChunk)

A handler that exports `onChunk` sees the body as a sequence of `inbound_chunk`
activations (the trust-boundary streaming path, distinct from `blob.receive`).
Drive it with `scenario.inboundChunks({ method, path, headers }, chunks)` — one
activation per chunk, with `request.chunkSeq`, `request.done` on the last, and
the payload on `request.bytes` / `.text`. Per-connection ctx threads via each
chunk's `next({ctx})` (null on the first) and KV writes fold forward, so an
accumulate-in-kv handler reconstructs the body. Pass `{ binary: true }` for byte
chunks (`Uint8Array`).

```js
const r = s.inboundChunks({ method: "POST", path: "/upload" },
                          ["Hello, ", "streaming ", "world!"]);
expect(r.disposition).toBe("terminal");
expect(r.body.assembled).toBe("Hello, streaming world!"); // folded across 3 chunks
```

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

Declaring an instance also makes it **resolvable**: `platform.scope(id)`
resolves eagerly, so an id the scenario didn't declare (and the run didn't
`instances.create`) throws `Error{code:"InstanceNotFound"}` at the call site —
the same ghost-id behavior as production.

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
An unnamed `toMatchSnapshot()` is keyed by its call site (`file.mjs:line`), so
reordering assertions doesn't re-key baselines. A stored snapshot no assertion
reads (a deleted or renamed one) is warned about on a clean run and pruned by
`--update` — the sidecar stays exactly the live set.

## What it does and doesn't tell you

`rewind test` runs your handler logic through the real engine, so it's faithful
to what the handler *computes*: reads, writes, emitted effects, branch behavior,
held-resume chains. It does **not** run the distributed machinery — consensus,
routing, real network fetches, the durable retry ladder. You supply each external
result; the platform's delivery of it is covered by the platform's own tests. A
green `rewind test` means "the handler does the right thing with these inputs,"
which is exactly the layer you own.
