# Handler API ergonomics — one payload model, one grammar

> **Status:** DRAFT (2026-07-04). Contract-change plan for the customer
> handler surface (`handler-shape.md` is the contract this revises).
> Pre-customer: every change here is a clean break, no compat shims
> (per the no-pre-launch-back-compat rule). Phases land in order; each
> phase leaves the tree green and the docs true.

## 0. Motivation

An audit of the handler-facing surface (docs + `src/js/globals*` +
`src/js/bindings/*` + `src/js/builtin_modules/*` + first-party
handlers) found three classes of friction:

1. **Silent data corruption** on input paths that should fail loudly.
2. **Per-surface payload types** — `request.body` is a string, a
   Uint8Array, a lossily-decoded string, or absent, depending on which
   activation delivered it; the docs claim these surfaces are
   identical.
3. **Five spellings for one concept** (the callback target), two homes
   for threaded context, three formats for one id, and mixed casing on
   one object.

The measurable symptom: `JSON.parse(new TextDecoder().decode(
request.body))` appears in `oidc.js`, `retry.js`, `segments.js`,
`browser.js`, every fetch example, and the platform's own
`webhook_onresult.mjs`. When the platform's shims fight the surface,
customers will too (workarounds are API design signals).

## 1. Audit summary

### 1.1 Payload type per surface (as-built)

| Surface | `request.body` is | Where |
|---|---|---|
| inbound `default` | string (invalid UTF-8 → raw latin-1 fallback) | `globals.zig` `jsBodyGetter` |
| `onChunk` | Uint8Array | `globals.zig` inbound_chunk |
| bound `on.fetch` / `blob.get` resume | Uint8Array | `globals.zig` fetch_chunk (bound) |
| `webhook`/`email`/`retry` `on_result` | string via lossy `TextDecoder` | `webhook_onresult.mjs` |
| `blob.put` `on_result` | undefined (no body) | `blob_onresult.mjs` |
| WS `onMessage` | n/a — payload is `request.activation.data` | `globals.zig` ws_message |

`handler-shape.md` §7 claims the fetch/effect-result surfaces are
identical. They are not.

### 1.2 Silent-corruption inputs (fail-loud violations)

| # | Surface | Today | Class |
|---|---|---|---|
| C1 | terminal `return new Uint8Array(...)` | JSON-stringifies to `{"0":1,...}` — the only payload surface with no bytes path | corruption |
| C2 | `kv.set(k, v)` non-primitive `v` (or `k`) | `String()` coerces: Uint8Array→`"1,2,3"`, object→`"[object Object]"` | corruption |
| C3 | `webhook.send` Uint8Array body | JSON round-trip through the `_send/owed` marker mangles it; its ephemeral twin `on.fetch` takes bytes losslessly | corruption |
| C4 | `next({ctx})` with unserializable ctx (BigInt, Map) | silently stores `"null"` — continuation state vanishes | corruption |
| C5 | `stream.write(nonStringNonBytes)` | `String()` fallback → `"[object Object]"` as a wire chunk | corruption |
| C6 | inbound body with invalid UTF-8 | raw latin-1 string semantics, undocumented | posture |

### 1.3 Grammar inconsistencies

- Callback target: `{to}` opts key (`on.timer`/`on.kv`/`blob.get`),
  `{to}` as a separate third argument (`on.fetch`), `{on_result}`
  snake_case (`webhook`/`email`/`retry`/`blob.put`), positional target
  (`schedule`/`cron`).
- Context: passed as `ctx` or `context` or positional; read back on
  `request.ctx` or `request.activation.msg`.
- `fetchId`: `on.fetch()` returns bare hex; `request.fetchId` bare hex;
  `request.activation.fetch_id` is `ftch_`-prefixed. Only one of three
  surfaces got the §7.5 versionable prefix.
- Casing: `fetchId`/`chunkSeq` camel next to `body_truncated`/
  `fetch_id`/`scheduled_at_ns` snake, on the same object.
- `blob.receive` resumes with `request.activation.ok`; every sibling
  uses top-level `request.ok`.
- `webhook.send` code takes `{url}` embedded; the docs and sibling
  `on.fetch` use positional url.

### 1.4 Doc-vs-code fiction

- **`kv.range` does not exist.** §5.7/§5.8 use `kv.range(prefix,
  {afterSeq})` / `{olderThan}` and read `r.seq`; the real API is
  `kv.prefix(prefix, cursor, limit)` → `{key, value}`. The canonical
  SSE-cursor example is unimplementable as written.
- §5.6 reads `request.ctx.error`; errors live on
  `request.activation.error`. `webhook.js`'s JSDoc makes the same
  mistake.
- `next({module})` cross-module chaining (§3.1) is not exposed by the
  customer shim.
- `on.js` JSDoc says the un-targeted `on.fetch` default is
  `onFetchChunk`, omitting the `onFetchResult`/`onFetchDone` split.
- `request.fetchesPending` exists and is undocumented.

## 2. Decisions

### 2.1 Fail-loud inputs (fixes C1–C5)

- **C1** — terminal return grows a bytes branch: `string` → bytes
  verbatim (as today), **`Uint8Array` → bytes verbatim** (no JSON
  flag), everything else → `JSON.stringify` (as today). Symmetric with
  `stream.write`.
- **C2** — `kv.set` accepts **primitives only** for key and value
  (string, number, boolean, bigint — each has one deterministic,
  faithful string form). `undefined`, `null`, objects, arrays, typed
  arrays, functions, symbols → `TypeError`. Numbers stay legal because
  `kv.set('count', n)` is common and round-trips faithfully;
  `"[object Object]"` and `"1,2,3"` do not. kv stays string-valued;
  JSON encoding remains the handler's explicit choice.
- **C3** — `webhook.send` body must be a **string**; anything else
  (except `undefined` → `""`) throws `TypeError`. Byte bodies for the
  durable path (base64 in the marker) are deferred until a real case
  demands them; today they corrupt silently, which is strictly worse
  than refusing.
- **C4** — `next({ctx})`: if `ctx` is **provided** and
  `JSON.stringify` throws or yields `undefined` → `TypeError`.
  `next()` / absent ctx stays legal. Same rule applies to every other
  threaded-context input (`on.fetch` ctx, `blob.put` context,
  `scheduler` msg) — those already throw or cap; `next` was the
  outlier.
- **C5** — `stream.write` accepts **string | Uint8Array** only;
  the `String()` fallback is removed → `TypeError`. Matches the
  `on.fetch` body posture.

### 2.2 One payload model: bytes are truth, accessors present

The tape already stores raw bytes; the JS type is a presentation
decision at the accessor. So present uniformly. Every activation that
carries a payload exposes the same three lazy, read-recorded
accessors:

- **`request.bytes`** — Uint8Array, always.
- **`request.text`** — UTF-8 decode, **lenient** (invalid sequences →
  U+FFFD, WHATWG `TextDecoder` default). Rationale: `.text` is a
  convenience view; a handler that must reject non-UTF-8 checks
  `request.bytes` explicitly. This also retires the undocumented
  latin-1 fallback (C6).
- **`request.json`** — `JSON.parse(request.text)`; throws on parse
  failure (a handler asking for JSON that isn't JSON is a real error).

Each accessor records on first access (`request_reads` tape channel,
same as headers/body today); all three derive deterministically from
the same recorded bytes, so replay is unaffected and the record is
made at most once regardless of which views are read.

Applies to: inbound `default`, `onChunk`, bound fetch/blob resumes,
`webhook`/`email`/`retry`/`blob.put` result callbacks (the result body
rides as bytes end-to-end — no more lossy decode in
`webhook_onresult.mjs`; `blob.put` results gain the response body they
currently drop), and WS `onMessage` (the frame payload; `opcode`
remains on `request.activation` for handlers that care about
text-vs-binary framing).

**`request.body` is retired.** One deprecation sweep of first-party
code, then the property is gone; a partial alias would keep the
"which type is it" question alive forever.

### 2.3 The grammar: `after.*` + universal `{on}`

- The connection-trigger namespace **`on.*` is renamed `after.*`**:
  `after.kv(prefix, opts)`, `after.fetch(url, opts, {on})`,
  **`after.ms(n, opts)`** (replacing `on.timer`). "after" matches the
  actual one-shot, re-armed-per-activation semantics ("on" wrongly
  connotes a persistent subscription) and frees `on` for the option
  key. `after.ms` wears its unit in its name; it is **not** the first
  of a family — no `after.seconds`. Readable durations are
  `after.ms(5 * 60_000)` or a userland helper. Durable schedules keep
  human strings (`schedule({in: '24h'})`): connection wakes are
  programmatic and short; schedules are human-scale. That split falls
  on the scope axis, deliberately.
- The callback-target option is **`{on: "module.method"}` on every
  effect**: `after.*`, `blob.*` (replacing `to` and `on_result`),
  `webhook.send`, `email.send`, `retry.send`. `schedule`/`cron` keep
  their positional target (the target *is* the payload there, not an
  option). `email.send`'s recipient keeps `to` — recipient and
  callback now coexist without collision.
- **`scheduler.after` is renamed `scheduler.in`** so "after" is
  exclusively connection-scoped (the verb is the scope).
- **`webhook.send(url, opts)`** — url goes positional, matching
  `after.fetch` and the existing docs.

### 2.4 Identifier and field unification

- Platform ids carry their type prefix on **every** surface:
  `after.fetch()`'s return, `request.fetchId`, and
  `request.activation.fetchId` are all the same `ftch_…` string.
- Handler-visible field casing is **camelCase**: `bodyTruncated`,
  `scheduledAtNs`, `fetchId` (the `request.activation.*` snake
  survivors migrate).
- The one-ctx rule (`decisions.md` §4.9) completes: threaded context
  is passed as `ctx` and read as `request.ctx` on **every** callback,
  including `schedule`/`cron` targets (`request.activation.msg`
  retires into `request.ctx`).
- `blob.receive` resumes with top-level `request.ok` like its
  siblings.

### 2.5 kv surface (the §1.4 feature decision)

The documented `kv.range(prefix, {afterSeq})` pattern is the right
customer surface for the drain-since-cursor loop — the engine already
anchors `after.kv` wakes to the read view, so exposing a
sequence-based range is coherent. But it is a real feature (seq
plumbing through kvexp reads), not a doc fix. Decision: **rewrite the
§5.7/§5.8 examples against the real `kv.prefix` now** (Phase 4), and
leave seq-exposed `kv.range` as a separate proposal when a real
handler needs lossless drain by sequence rather than by key prefix.
The docs must not describe fiction in the meantime.

## 3. Phases

Each phase is independently green (build + `zig build test` + the V2
smokes that touch the changed surface).

- **Phase 1 — fail-loud inputs (C1–C5).** `response_building.zig`
  (bytes return), `globals.zig` (kv.set primitives-only),
  `bindings/stream.zig` (drop `String()` fallback),
  `bindings/continuation.zig` (throw on unserializable provided ctx),
  `globals/webhook.js` (string-only body). Update any first-party
  caller the new strictness catches.
- **Phase 2 — payload accessors.** `request.bytes`/`.text`/`.json` on
  every payload activation; result bodies ride as bytes end-to-end
  (`webhook_onresult.mjs` carries base64url `body_b64` — the JSON
  envelope can't hold raw bytes; `blob.put` results carry the body);
  WS `onMessage` gains the accessors; first-party shims/handlers
  migrated off `TextDecoder` boilerplate; latin-1 fallback retired.
  Implementation notes (as-built): `bytes` is the only per-kind Zig
  materialization (a read-recording accessor on plain inbound, a data
  property on chunk/fetch/ws/send_callback); `text`/`json` derive on a
  shared prototype (`globals/request.js`, `__rove_request_proto`) so
  they are snapshot-baked. The held-sync positional
  `onResult(ctx, outcome)` consumers read `outcome.body`, so the
  send envelope carries BOTH `body_b64` and the text `body` until the
  Phase-3 sweep revisits that surface. **`request.body` retirement is
  deferred to a coordinated cross-repo step** — rewind-apps handlers
  read it, and the replay/sim driver (arenajs shell + rewind-apps
  porcelain) builds its own `request` object, which must grow the
  accessor parity BEFORE first-party code depends on `.text`/`.json`
  under replay (`scripts/sim/example/handler.mjs` deliberately not
  migrated for this reason).
- **Phase 3 — grammar sweep.** `on.*` → `after.*` (+ `after.ms`),
  universal `{on}`, `scheduler.after` → `scheduler.in`,
  `webhook.send(url, opts)`, id-prefix + camelCase + one-ctx + blob
  `ok` unification. One breaking sweep across bindings, shims,
  builtin modules, examples, loader validation (§6 export checks
  follow the new names), and first-party apps.
  As-built (2026-07-04): landed with a **ONE-DEPLOY-CYCLE dual-name
  window** so already-deployed rewind-apps bundles keep working across
  the rollout. Canonical implementations live under the new names; the
  old spellings are thin aliases. `blob.receive` needed no code — its
  resume rides the bound-fetch path, which already carries top-level
  `request.ok` (the `activation.ok` claim was doc fiction). The
  internal namespace renamed `_system.on` → `_system.after` (lint(c)
  pivots on it); the native option field stays `to` internally — the
  shims normalize `{on}` → `{to}` at the boundary.

  **Window-close checklist (the follow-up deploy, AFTER rewind-apps
  migrates + publishes):**
  - `globals/after.js`: delete `globalThis.on` + the `{to}` arm of
    `tgt()`.
  - `webhook.js`: delete the `{url,...}` single-object form and the
    `on_result`/`context` keys. `email.js`/`retry.js`/`blob.js`
    (`put`/`get`/`seal`/`receive`)/`segments.js` (`get`)/`browser.js`
    (`getReplay`): delete the `on_result`/`on_result_module`/
    `context`/`to` aliases.
  - `scheduler.js`: delete the `after` alias.
  - `globals.zig`: delete the snake aliases (`activation.fetch_id`,
    `activation`/top-level `body_truncated`,
    `activation.scheduled_at_ns`) and `activation.msg` — first migrate
    the internal readers (`cron_tick.mjs`, `scheduler_tick.mjs`,
    `webhook_fire.mjs`) to `request.ctx`.
  - Migrate the deliberately-legacy window-teeth smokes
    (`webhook_recovery_smoke_v2`, `ssrf_smoke_v2`,
    `scheduler_heartbeat_smoke_v2`) and delete the alias unit tests.
  - Then also retire `request.body` (needs the replay-driver accessor
    parity — open question 4).
- **Phase 4 — docs reconciliation.** `handler-shape.md` rewritten to
  the new surface (including honest `kv.prefix` examples,
  `request.fetchesPending`, the §5.6/§5.9 fixes); `effect-algebra.md`
  §6 verb names; shim JSDoc; sibling docs per the docs-lag rule.

## 4. Open questions

1. Byte bodies on the durable send path (C3 follow-up): base64 in the
   `_send/owed` marker, or a BodyRef-style pointer? Deferred until
   demanded.
2. Seq-exposed `kv.range` (§2.5): separate proposal.
3. The unbound (Pattern-A) fetch resume shape (`activation.bytes` +
   ctx smuggled in a JSON body) is internal-only today; unify it with
   the bound shape when it next needs touching — not part of this
   sweep.
4. Replay/sim driver parity for `request.bytes`/`.text`/`.json` (the
   arenajs replay shell + rewind-apps porcelain synthesize `request`
   from the tape) — required before the `request.body` retirement and
   before shims that run under replay lean on the accessors.

## 4.1 Retired alongside this arc

- **`kind=boot` subscriptions + `onBoot`** (2026-07-05): audited unused
  (no rewind-apps consumer; only its own example + smokes). The "run
  once on deploy" hook is gone — recurring registrations (`cron`,
  `scheduler.in`) seed from any handler activation; they are
  idempotent by key and `_sched/*` entries are durable kv that survive
  deploys. `kind=boot` in a manifest now fails the deploy with a
  pointed retirement error (same posture as `kind=cron`). The
  `_boot_fired/*` marker keys are dead (harmless residue in existing
  stores). kv-react (`kind=kv` → `onSubscription`) is unchanged.

## 5. Not changing

The engine model is untouched: activation purity, arena reset,
effects-accumulate/return-disposition, the one rule (commit-gated
output), read-recording, envelope formats, the tape format (bytes
were already truth), scope-is-the-verb. This plan renames and
re-presents; it does not re-model.
