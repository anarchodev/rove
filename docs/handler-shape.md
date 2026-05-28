# Handler shape — pattern-matching at module level

> **Status:** Proposal. Supersedes the `__rove_stream` / `__rove_next`
> / `request.activation.kind`-switch surface in `streaming-model.md`
> §3 and the multi-shape return values in §4–§5. The engine model
> (coalesce budget, blob coordinator, one-rule semantics — see
> `streaming-model.md` §1–§2 and §7.X) is **unchanged**. Only the
> customer-facing handler API changes.
>
> Motivation: the existing surface is honest about the underlying
> model — multi-activation chains, Cmd-return discipline, no
> closure smuggling — but exposes implementation details (`a.kind`
> switch, underscore-prefixed primitives, four-way-overloaded
> return values) in every streaming handler. This shape keeps the
> model intact and replaces the surface with one customers can read.

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
| `Cmd Msg` ADT | the three Cmd verbs in §2 |
| Side-effects via `Cmd Msg` | Effects via `http.*` / `webhook.*` / `kv.*` (queued during activation, fired post-commit) |

A module exports the subset of variants it cares about. The runtime
introspects exports at load time, validates coverage (§6), and
dispatches each activation to its matching export.

The default export handles inbound HTTP — the case 80%+ of
modules care about. Everything else is opt-in via additional
named exports.

## 2. The Cmd surface — three verbs

Every handler returns one of three things:

| Return value | Means | Engine action |
|---|---|---|
| `string` or `{status?, body?, headers?}` | terminal response | commit writeset, ship response, close chain |
| `stream()` / `stream({write: bytes})` | streaming handler: more chunks coming; optionally emit one | commit writeset, ship emitted chunk if any, dispatch next chunk activation when it arrives |
| `next()` | held client + I/O resume: I just kicked off I/O, park me, wake on its return | commit writeset (Effects fire after), hold the held HTTP connection, dispatch the matching resume export when the I/O resolves |

`stream` and `next` are named imports from the runtime:

```js
import { stream, next } from 'rove';
```

No underscores. No sentinels. No `__rove_*`. The Cmd surface is
exactly three verbs, and every return type-narrows cleanly: it's
either a response value, a `stream(...)` call, or a `next()` call.

A `string` return is sugar for `{body: string}`. A `{status, body,
headers}` object is sugar for the same — terminal response. The
shape stays "return what the response is" for the common case;
streaming and parking require the explicit verbs.

## 3. Activation kinds — the runtime's Msg union

| Activation | Named export | When it fires | `request` shape |
|---|---|---|---|
| inbound HTTP (buffered) | `default` | request arrived, body ≤ 1 MB; > 1 MB → 413 if no `onChunk` | full `request` with `body` |
| inbound HTTP chunk | `onChunk` | request arrived; fires per chunk for any body size (≤ 1 MB → fires once with the whole body) | `request.body` = this chunk's bytes (or whole body if it fits); `request.done` = true on last/only chunk; `request.chunkSeq` = monotonic |
| webhook.send resume | `onSendCallback` | a `webhook.send` you kicked off returned | `request.result` = `{status, body, headers, sendId}` |
| http.fetch resume (coalesced) | `onFetchResult` | a non-bound `http.fetch` returned its whole body | `request.result` = `{status, body, headers, fetchId}` |
| http.fetch chunk (bound + streamed) | `onFetchChunk` | per chunk from a `http.fetch({bind: true})` | `request.body` = chunk bytes; `request.done` on last; `request.fetchId` |
| http.fetch end (bound + streamed) | `onFetchDone` | a bound+streamed fetch terminated | `request.result` = `{ok, status, fetchId}` |
| subscription fire (generic) | `onSubscription` | external push (atproto firehose, etc.) | `request.event` = subscription-specific payload |
| cron fire | `onCron` | scheduled cron entry triggered | `request.cronName`, `request.scheduledTime` |
| kv-react fire | `onKvWake` | watched key changed | `request.key`, `request.value` |
| boot fire | `onBoot` | once per fresh deployment activation | `request.deploymentId` |
| held client disconnected | `onDisconnect` | the held HTTP/2 stream closed before the chain terminated normally | (none) |

The set is closed — modules can't define new activation kinds; only
the runtime can. Adding a kind is a runtime change with a coordinated
loader bump.

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
  if (!authorized(request.headers)) return { status: 401 };
  return { status: 200, body: process(request.body) };
}
```

### 5.3 Streaming inbound — per-chunk upload to storage

```js
import { stream } from 'rove';

export function onChunk() {
  http.fetch({
    url: STORAGE_URL + '/' + request.headers['x-key'] + '?seq=' + request.chunkSeq,
    method: 'PUT',
    body: request.body,
  });
  if (request.done) return { status: 201, body: 'uploaded' };
  return stream();
}
```

No `default` — the export of `onChunk` declares this route
accepts any body size, handled chunk-by-chunk. A small body (≤ 1
MB) fires `onChunk` once with the whole body and `request.done =
true`; a larger body fires multiple times. Either way the same
function handles both.

### 5.4 webhook.send + resume (held client during I/O)

```js
import { next } from 'rove';

export default function () {
  webhook.send({ url: 'https://upstream.example.com', body: request.body });
  return next();
}

export function onSendCallback() {
  if (request.result.status >= 400) return { status: 502, body: 'upstream failed' };
  return { status: 200, body: 'forwarded' };
}
```

Two exports, two activations, two named handlers. The
discrimination "am I the initial dispatch or a resume?" is in the
file's *structure*, not in branching at the top of one function.

### 5.5 LLM proxy — bound streaming fetch + held client

```js
import { stream, next } from 'rove';

export default function () {
  http.fetch({
    url: LLM_URL,
    method: 'POST',
    body: request.body,
    bind: true,
  });
  return next();                            // hold the client; wait for first upstream chunk
}

export function onFetchChunk() {
  if (request.done) return "";              // close held response
  return stream({ write: transform(request.body) });
}
```

Same `default` + `next()` pattern as 5.4, but the resume kind is
`onFetchChunk` (per upstream chunk) instead of `onSendCallback`
(one-shot).

### 5.6 Chain origins (no inbound HTTP)

```js
// Fires on cron schedule.
export function onCron() {
  kv.set('last_cron', new Date().toISOString());
  // No response — there's no client. Returning undefined is fine; the
  // chain commits its writeset and ends. Errors thrown still tape.
}

// Fires when a watched key changes.
export function onKvWake() {
  if (request.key.startsWith('queue/')) {
    webhook.send({ url: 'https://worker.example.com', body: request.value });
  }
}

// Fires once per fresh deployment.
export function onBoot() {
  kv.set('booted_at', new Date().toISOString());
}
```

Same module can also export `default` for an HTTP API on the same
route; the cron / kv-wake / boot fires are independent chains
sharing the module's kv namespace.

### 5.7 Multi-fetch with discrimination

```js
import { stream, next } from 'rove';

export default function () {
  http.fetch({ url: API_A, bind: true });   // fetchId: 'a' (auto-assigned or via name option)
  http.fetch({ url: API_B, bind: true });
  return next();
}

export function onFetchChunk() {
  // request.fetchId tells you which one
  switch (request.fetchId) {
    case 'a': return stream({ write: 'A:' + request.body });
    case 'b': return stream({ write: 'B:' + request.body });
  }
}
```

Single export handling N fetches via a switch is back, but only when
the customer has N concurrent bound fetches. Most cases have one;
the switch is rare.

(Future ergonomic: a `name:` option on `http.fetch` lets the customer
write `onFetchChunk_<name>` exports, skipping the switch.
Defer until measured.)

## 6. Validation — exhaustiveness without a type system

JS modules aren't a sum type the compiler sees; a typo in
`onSendCallback` → handler silently never fires. Mitigation: the
loader validates `module.exports` against the activation kinds the
module's effects could trigger:

- If `default` exists and the body is large, dispatch happens or 413
  fires — no validation needed.
- If `onChunk` is exported, the route is a streaming receiver.
- If any handler calls `webhook.send` and the module doesn't export
  `onSendCallback`, the loader emits a deploy-time warning: "your
  module calls webhook.send but doesn't export onSendCallback —
  the send's callback will be discarded."
- If any handler calls `http.fetch({bind: true})` without `onFetchChunk`
  (streamed) or `onFetchResult` (coalesced) exported, same warning.
- If `onChunk` is exported but no `default` and no other dispatchable
  origin (`onCron`, `onSubscription`, etc.), the loader emits: "your
  module exports `onChunk` but nothing can trigger a streaming
  receive."
- Unknown `on...` exports (typos) emit: "your module exports
  `onSendCallbck` which the runtime doesn't recognize. Did you mean
  `onSendCallback`?"

These are deploy-time errors / warnings, not request-time failures.
Strict mode (errors instead of warnings) is configurable per-tenant.

## 7. The `request` global per activation kind

`request` is a module-level global the runtime populates fresh for
every activation. Across activations of the same chain, `request`
*is replaced*, not mutated — its identity changes each dispatch.
This makes "no state across activations" structurally obvious:
your reference to `request` from a prior activation is gone when
the new one fires (the arena reset wipes it anyway).

Per-activation shapes are listed in §3's table. A few highlights:

- **`default` (inbound):** `request.body`, `.headers`, `.method`,
  `.path`, `.query`, `.cookies`, `.ip` etc. — same as today's
  buffered handler.
- **`onChunk`:** `request.body` = THIS chunk's bytes (NOT the
  cumulative prefix); `request.done` = boolean true on the last
  chunk; `request.chunkSeq` = monotonic counter starting at 0.
  Headers/cookies/method etc. are still present and unchanged
  across chunks.
- **`onSendCallback` / `onFetchResult`:** `request.result` =
  `{status, body, headers, id}` (id is the sendId or fetchId).
- **`onFetchChunk`:** like `onChunk` but for an outbound fetch's
  response stream. `request.body` = upstream chunk bytes;
  `request.fetchId` discriminates between multiple bound fetches.
- **Chain origins** (`onCron`, `onKvWake`, `onBoot`, `onSubscription`):
  `request` carries origin-specific fields (`cronName`, `key`,
  `deploymentId`, etc.) but has no HTTP `headers` / `body` because
  there's no inbound HTTP request.

## 8. What's gone vs `streaming-model.md` §3

- `request.activation.kind === '...'` switch → runtime dispatches by export name
- `__rove_stream({write: [...], waitFor: ...})` → `stream({write: ...})`
- `__rove_next()` → `next()`
- The three-way choice (`(a) respond / (b) parkUntilBodyComplete / (c) streamBody`) → collapses to "1 MB ceiling, above → 413 or `onChunk`"
- Four return shapes overloading one slot → three verbs, each typed and named
- `ctx.state` cross-activation scratchpad → forbidden; state lives in kv (the model)

## 9. What's unchanged

- The engine model: pure function per activation, arena reset
  between activations, no closure smuggling
- Effects vs Cmds split: Effects (`http.*`, `webhook.*`, `kv.*`)
  accumulate during the activation and fire post-commit; Cmds
  (`stream`, `next`, response value) declare the next chain state
- The one rule (§2 of `streaming-model.md`): a chunk reaches the
  wire only after the activation that produced it has committed
- Replay: `foldl(handlers, kv0, activations)` — re-run all
  activations against the recorded inputs from the readset, derive
  everything else
- The substrate: blob coordinator, readset replication, content-
  addressed extents — all unchanged
- The 64 KiB internal coalesce budget for streaming chunks

## 10. Open questions

1. **`fetch` naming for outbound name-keyed dispatch.** If a customer
   has N bound fetches and finds `switch (request.fetchId)` annoying,
   the `name:` option + `onFetchChunk_<name>` export shape works but
   requires the loader to parse export names. Worth doing eagerly,
   or defer until measured?

2. **`onResume` as generic fallback.** Customers wanting one handler
   for all I/O resumes (rather than `onSendCallback` / `onFetchResult`
   separately) could export `onResume` and discriminate on
   `request.result.kind`. Useful or footgun?

3. **`onError` for handler exceptions.** Today thrown exceptions →
   500 from the runtime. An `onError(err)` export could customize.
   Goes against the "let it crash, the runtime owns 500" Erlang
   posture — defer unless customers ask.

4. **Module-level state.** `let counter = 0;` at module top level —
   does it persist across activations? Today no (arena reset wipes
   the module's per-request closure). Forbidding it formally
   (loader-time lint) keeps the model honest; allowing it (with
   warning) is a footgun. Recommend: forbid; surface clearly.

5. **`default` vs `onInbound`.** ES module convention is `export
   default` for "the main export." Pure consistency would name it
   `onInbound` to match the rest of the `on…` family. Tradeoff:
   default-export shorthand is more familiar for the simple case
   (`export default (req) => "hello"`); `onInbound` is more
   consistent with the family. Current pick: keep `default` for
   familiarity; alias to `onInbound` internally.

6. **Strict mode for validation.** Default: deploy-time warnings.
   Strict: deploy-time errors. Per-tenant config or per-deployment
   manifest flag?

## 11. Relation to other plans

- **`streaming-model.md`** — engine substrate. §1 frame, §2 one rule,
  §4.A `http.fetch` as-built, §7.X blob coordinator all unchanged.
  This doc supersedes §3's three-way-choice surface and the
  `__rove_stream` / `__rove_next` shape in §5.
- **`effect-algebra.md`** — Cmd verbs (`stream`, `next`,
  response) align with the four-primitive frame. No semantic change;
  the renames are surface-level.
- **`effect-reification-plan.md`** — Phases 0–5 shipped; the existing
  `streaming-handler` machinery in worker.zig is what this doc's
  surface lowers onto. No runtime change required beyond the
  binding renames.
- **`primitive-gaps.md` §2.4** — inbound streaming body. The
  implementation work for gap 2.4 (h2 wire + per-chunk dispatch +
  blob coordinator wiring) is the substrate this doc's `onChunk`
  rides on. No new engine work to support the surface change.
- **`readset-replication-plan.md`** — chunk capture in the readset
  is what makes `onChunk` replayable. Already shipped (Phases 1–6).
