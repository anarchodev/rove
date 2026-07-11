# Sim ↔ prod parity audit (2026-07-11)

> **Status: findings, not fixes.** A five-dimension audit of `rewind test` /
> `rewind sim` (src/replay/) against the production worker (src/js/), run at
> commit `3f36f0a` (includes the issue #3 ctx-rule fix and the issue #6
> compile/stampManifest drivers). Goal per the product bar: a customer must be
> able to test **any** handler offline and trust the result. Every finding
> below was verified against the actual code (file:line on both sides); the
> highest-severity ones were independently confirmed by 2–3 separate passes.
>
> Severity: **divergence** = sim and prod give different answers for the same
> handler (a test can green on behavior prod won't ship, or fail on behavior
> prod serves fine); **missing** = prod functionality the sim cannot express
> or enforce; **cosmetic** = observable but unlikely to flip a verdict.
>
> **Filed as issues (2026-07-11).** Worker-vs-docs conflicts, treated as PROD
> bugs (P1, per an@'s call): D1 → #7, D2 → #8, D3 → #9. Sim side: §1 error
> semantics → #10 (P1, **fixed** `2bd491a`); §5.1 TextEncoder → #11;
> §5.2-5.3 kv guardrails → #12. The remaining bundles were split into
> per-fix-locus leaf issues (2026-07-11, second pass), with the originals
> kept as tracking checklists: #13 → #20–#23 (recorder drop-parity +
> validation), #14 → #24–#26 (fetch/platform recorder + views), #15 →
> #27–#35 (resume folds; the inboundHeaders fallback shipped with #10),
> #16 → #36–#39 (coverage verbs; #39 blocked on #8), #17 → #40–#44
> (request/response surface), #18 → #45–#47 (crypto), #19 → #48–#55
> (substrate).

## 0. The three doc-vs-worker conflicts (decide before fixing the sim)

These are places the sim agrees with `docs/handler-shape.md` /
`replay-and-sim.md` but the **worker** does something else. Fixing the sim to
match the worker bakes in behavior that may itself be the bug:

- **D1. `request.ok` on fetch resumes.** Worker: transport-only —
  `transport_ok = result.ok and !s.failed` (`src/js/fetch_engine.zig:1381`),
  so an upstream **500 arrives with `ok:true`** (`src/js/globals.zig:2728`).
  Sim: `ok = status ∈ [200,300)` (`src/replay/rewind_test.mjs:1036-1039` —
  its comment claiming "the real engine sets ok = status in [200,300)" is
  false). A handler's `if (!request.ok) retry()` branch fires in the sim test
  and never fires in prod. Related: `sendCallback`'s ok default vs the real
  webhook classifier `ok = transport_ok && status < 400`
  (`src/js/builtin_modules/webhook_onresult.mjs:80`) — a 302 is ok:true in
  prod, ok:false by sim default (`rewind_test.mjs:374-376`).
- **D2. `request.activation.wakes[]`.** Worker: the held-continuation and WS
  wake paths **drain and free** the kv-match ring — "the matched keys aren't
  surfaced to the handler" — and dispatch `.wake_batch = .{}` (empty)
  (`src/js/worker_drain.zig:1779-1784,1849`; `src/js/worker_ws.zig:865-870`).
  Only the SSE/stream resume surfaces real entries
  (`src/js/worker_streaming.zig:868-873`). Sim always populates `wakes[]`
  (`rewind_test.mjs:614-628,703`), siding with handler-shape.md. Where prod
  does surface entries the encodings still differ: sim `op:"p"/"d"`, `firedAt`
  ms vs prod `op:"put"/"delete"`, `firedAt` ns (`src/js/globals.zig:2615-2628`).
- **D3. `schedule({...}, "module.method")`.** handler-shape.md §2.4 promises
  it and the sim's `wake({method})` models it (`rewind_test.mjs:408-433`), but
  the worker never splits a target on `.` — `fireDurableWakeActivation` sets
  no fn_override → always the default export
  (`src/js/worker_streaming.zig:1965-2026`, `src/js/rpc_dispatch.zig:63-72`).

## 1. Error semantics (the worst cluster — triple-confirmed)

- **1.1 Handler throw: sim reports status 200 / ok:true; prod ships 500 +
  full rollback.** divergence. Prod: exception → `txn.rollbackTo()` +
  `setSimpleResponse(500, "handler threw: …")`, handler-set response head
  discarded (`src/js/worker_dispatch.zig:3858-3887`; resume hops
  `src/js/worker_drain.zig:1482-1489`; WS frames close the socket,
  `src/js/worker_ws.zig:475-483`). Sim: the epilogue catches into
  `bundle.error`, emits the ambient `{status:200}` response
  (`src/replay/epilogue.zig:388-394`), and `root.zig:636-639` sets `ok:true`
  whenever the run produced output. An entire class of error-path tests
  (`expect(n.status).toBe(...)`, `n.ok`) greens offline and is wrong live.
- **1.2 Pre-throw KV writes persist and fold forward in sim.** divergence.
  Prod rolls the whole activation back; sim's host has already committed each
  `kv.set` to the world map (`src/replay/host.zig:144-149`) and `foldKv`
  threads them into every downstream resume and `toHaveWritten`/`node.kv()`
  (`rewind_test.mjs:105-118`). A saga can assert a write prod never commits.
- **1.3 Missing export: prod 404s (`src/js/module_execution.zig:332-338`);
  sim yields a 200-status bundle + error field.** divergence.
- **1.4 `_middlewares/index.mjs` without a `before` export: prod 500s
  (`module_execution.zig:241-255`); sim silently skips and runs the handler
  (`epilogue.zig:379-382`).** divergence.
- **1.5 Pending-promise return: prod treats it as a value → 200 `"{}"`
  (`src/js/response_building.zig:36-37`); sim never resolves → "the run
  produced no output" failure.** divergence (both directions misleading).

## 2. Effect recording vs prod's drop/validate rules

- **2.1 Connection-scoped effects recorded even where prod drops them.**
  divergence. `after.ms`/`after.kv` are no-ops without a held connection
  (`src/js/bindings/on.zig:70,99`), `stream.*` likewise
  (`src/js/bindings/stream.zig:111,128`), and an `after.fetch` from an
  activation that returns terminally (or from durable_wake/send_callback)
  is bind-or-drop — never fires (`src/js/bindings/http.zig:191-199,492-497`).
  Sim recorders push unconditionally (`src/replay/sim_globals.zig:215-237`);
  `requireHeld` gates only *resuming*, not *asserting* — so
  `expect(n).toHaveFetched(...)` passes on a fetch prod discards.
- **2.2 Fetch recorder drops `headers`, `stream`, `timeoutMs`,
  `maxChunkBytes`, `maxTotalBytes`.** missing. Prod carries all
  (`bindings/http.zig:271-296,525-557`). Consequences: header assertions
  match vacuously (incl. `.not.toHaveSent` false-passing), and
  `.fetch(...).stream([...])` can drive chunked delivery for a fetch issued
  *without* `stream:true` — prod would deliver one whole-body event.
- **2.3 Prod's synchronous argument validation never fires offline.**
  divergence. Each of these greens in sim, throws in prod: `after.ms(0)`
  (`on.zig:60-69`); `after.kv(nonString)` (`on.zig:90-93`); `after.fetch()`
  sans URL (`http.zig:207-210`); non-string/U8 fetch body (`http.zig:694`);
  `{on}`/`{to}` containing `/` or `.` (`http.zig:285-291` — see also 4.6);
  `http.subscribe` without `on` (`http.zig:549-551`); `stream.write({})` and
  the 4 MiB stream buffer cap (`stream.zig:146-212`); `blob.url` ttl range
  (`bindings/blob.zig:62-70`); `blob.receive` outside onHeaders / twice
  (`bindings/blob.zig:355-372`); `platform.scope("")`/unknown instance
  (`globals.zig:1734-1740`); `request.tag` validation (`globals.zig:1222-1288`
  vs the sim's `return request` stub, `epilogue.zig:368`);
  `crypto.randomBytes > 65536`.
- **2.4 Outbound policy unmodeled.** divergence. SSRF blocklist, TLS-only for
  customer fetches, method whitelist, redirect-off, inflight caps
  (`src/ssrf/root.zig:105-112`, `fetch_engine.zig:599,676-708`) surface in
  prod as an async terminal `ok:false` — a sim test can
  `.fetch("http://169.254.169.254/…").resolve({status:200})` and exercise a
  success path that is categorically unreachable in prod.
- **2.5 Fetch ids: constant `"ftch_sim"`/`"sub_sim"`; `request.fetchId` never
  set on resumes.** divergence. Prod: unique `ftch_<64hex>` returned and
  echoed on every wake (`http.zig:226-244,616-637`). Handlers correlating
  concurrent fetches by id collide or dead-branch in sim
  (`sim_globals.zig:215-221`; `rewind_test.mjs:1021-1043` sets no fetchId).
- **2.6 `http.subscribe` is record-only.** missing. Options beyond url/on are
  dropped and there is no SubscribeHandle — per-writeback events, the
  terminal "subscription ended" `ok:false`, and the 16-per-tenant cap event
  (`fetch_engine.zig:90,584-587`) are untestable. Same family: kv **triggers**
  and `_sub/dirty/{name}` marker injection (`globals.zig:842-869,913-978`)
  don't exist offline, so `onSubscription` flows can't be exercised end to
  end (`worker_streaming.zig:1750-1828` has no sim analog).
- **2.7 Email rate limit is a no-op offline.** missing (declared). Prod
  throws `Error{code:"rate_limited"}` from a plan-tier bucket
  (`bindings/email_rate.zig:26-58`); sim: `function(){}`
  (`sim_globals.zig:53`). The catch-branch is untestable.
- **2.8 `sentEffects`/`emailSent` views drop the marker's `headers` /
  `maxAttempts` / `timeoutMs`** (`rewind_test.mjs:156-165` vs
  `globals/webhook.js:232`) — `toHaveSent("webhook", {headers:…})` can never
  match. missing.
- **2.9 `releases.publish(tenant, depId)` / `deployStarter(name)` recorded
  argument-less; `instances.create` returns `"inst_sim"` vs prod
  `undefined`** (`sim_globals.zig:246-247` vs `globals.zig:1484,2222`).
  missing/cosmetic.
- **2.10 Response-head-commit timing at `stream.start` unmodeled; cancel
  verbs (`after.cancel`/`cancelFetch`/`cancelSubscription`) leave no effect
  entry** (`stream.zig:104-114`; `sim_globals.zig:216-218,236`). cosmetic.

## 3. Request/response surface

- **3.1 `request.path` keeps the query string in prod; sim strips it.**
  divergence. Prod passes the raw `:path` pseudo-header through
  (`src/js/worker_dispatch.zig:2753,3472` → `globals.zig:2516`; query is
  *also* split into `request.query`); the sim splits on `?`
  (`epilogue.zig:135-137`). `request.path === "/api/orders"` matches in sim,
  not in prod when a query is present.
- **3.2 Header hygiene absent.** divergence. Prod lowercases wire names
  (HTTP/2) and strips pseudo-headers, IP-carrying headers
  (`x-forwarded-for`/`x-real-ip`/`cf-connecting-ip`/`forwarded`) and
  `x-rewind-*`/`x-rove-internal-*` (`globals.zig:3058-3063,3143-3155`); the
  sim passes authored names verbatim (`world.zig:176-184`,
  `root.zig:159-168`). An authored `"Content-Type"` never matches
  `request.headers["content-type"]`; `"Cookie"` yields `cookies === {}`
  (`epilogue.zig:288` keys on lowercase); XFF is readable in sim only.
- **3.3 Response vetting absent.** missing. Prod lowercases response header
  names, drops non-strings and reserved names, rejects CR/LF, caps at 32,
  sanitizes Set-Cookie `Domain=` (`src/js/response_building.zig:94-199,
  290-320`); prod also clamps/coerces `status` (`:107-111`;
  `worker_dispatch.zig:3930`) and auto-sets
  `content-type: application/json` on object returns
  (`worker_dispatch.zig:3938`, suppression `dispatcher.zig:778-786`). The sim
  serializes the raw `response` object untouched (`root.zig:589-592`).
- **3.4 Returned `Uint8Array`: raw bytes in prod
  (`response_building.zig:61-69`); index-keyed JSON object in sim
  (`epilogue.zig:394`).** divergence — binary-body assertions meaningless.
- **3.5 Payload accessors throw REPLAY-DIVERGENCE where prod returns
  `undefined`.** divergence. Prod `request.text/json` → `undefined` when no
  payload (wakes, durable targets, disconnect) (`globals/request.js:29-45`);
  the sim's accessors throw whenever the world carries no body
  (`epilogue.zig:256-257`) — a defensive `if (request.text)` in `onWake`
  aborts the sim run. (The harness papers over inbound only via the `body:""`
  default, `rewind_test.mjs:280-284`.)
- **3.6 `request.body` and the `on.*` alias exist in sim only.** divergence.
  Both retired in prod (`globals/request.js:20-23`; `globals/after.js:19-20`)
  but installed unconditionally by the epilogue (`epilogue.zig:284,348-349` —
  the "driver only" comment notwithstanding; `rewind test` shares the
  epilogue via `root.zig:230`). New code written against them greens offline,
  ReferenceErrors/undefined in prod.
- **3.7 Identity/session pinning.** divergence. Prod always sets
  `request.session` (`null` when none), `request.tenant`, and
  `request.correlation_id` (`""`) (`globals.zig:2546-2570`); sim leaves them
  `undefined` unless authored (`epilogue.zig:306-312`) — the documented
  `session === null` branch is unreachable offline.
- **3.8 `request.activation` missing on sim inbound; thin on fetch resumes.**
  divergence. Prod installs `{kind:…}` unconditionally and fetch resumes
  carry `seq/byteOffset/bytes/final/headers` (`globals.zig:2582-2604,3032`);
  sim sets it only when the world declares one (`epilogue.zig:313-323`) —
  `request.activation.kind` throws on sim inbound. Also missing on bound
  resumes: `request.fetchesPending`, `request.bodyTruncated`
  (`globals.zig:2805,2813-2817`), and the sim stamps `status/ok` on
  non-final chunks where prod sets them only when `final`
  (`rewind_test.mjs:374-384`).
- **3.9 IP surface.** divergence/missing. Prod masks (`v4` last octet, `v6`
  /48; `globals.zig:3307-3396`) and `unmaskedIp()` returns raw-or-null; sim
  serves the authored ip verbatim as "masked", can never synthesize
  `ip_raw` → `unmaskedIp()` always throws, and an un-authored ip makes
  `request.ip` throw where prod returns a value (`root.zig:171-172`,
  `epilogue.zig:300-302`).
- **3.10 `request.tag` stub** — no validation, returns `request` (chainable)
  vs prod's strict two-string validate-and-return-`undefined` (see 2.3).

## 4. Activation dispatch and resume folds

- **4.1 Cross-module `next(target, ctx)` silently ignored.** divergence. The
  recorder keeps `target` (`sim_globals.zig:198`) but `root.zig:599-611`
  reads only disposition+ctx and every resume builder re-enters
  `parent.world.entry` (`rewind_test.mjs:620-629,695-704`). Prod resumes at
  the continuation's own path (`worker_drain.zig:1740-1752`).
- **4.2 Per-wake `{on}` routing.** divergence. Sim honors each armed wake's
  own export; prod keeps ONE `wake_to` per held connection — last `{to}`
  wins (`worker_dispatch.zig:376-386`, `worker_ws.zig:694-705`) — and the
  HTTP-stream resume path ignores it entirely (no fn_override in
  `resumeStream`, `worker_streaming.zig:899-924` → always `onWake`).
- **4.3 `wakeKv` fires unconditionally.** divergence. No prefix containment
  or read-version gating (`rewind_test.mjs:604-629`); prod fires only for a
  key under a registered prefix written after the arming activation's read
  view (`components.zig:197-203`). `held.wakeKv({"unrelated/key":…})` is a
  wake prod never delivers.
- **4.4 Multiple timers: sim fires `timers[0]`; prod arms only the LAST
  (`worker_dispatch.zig:378`); `clock.advance(delta).fire()` ignores whether
  delta reaches the armed interval.** cosmetic.
- **4.5 WS lifecycle.** divergence. (a) `ws().disconnect()` before any frame
  runs `onDisconnect`; prod runs nothing (chain is created lazily on first
  DATA frame — `worker_ws.zig:390-410`). (b) `WsNode.receive()` after a
  terminal frame continues a conversation prod cannot have (terminal return
  closes the socket, `worker_ws.zig:472-498`). (c) Prod closes without
  onDisconnect on gate fault or handler throw (`worker_ws.zig:288-292,
  475-483`) — no sim analog.
- **4.6 Bound `{on}` with a module path.** divergence. `onTarget`
  (`rewind_test.mjs:1011-1015`) routes any `/`-or-`.mjs` `on` to a different
  module for **bound** resumes too; prod treats a bound `{on}` as an export
  name verbatim (`components.zig:381-386`) and rejects `/`/`.` at issue time
  (`http.zig:285-291`). The whole sim flow works on a call prod throws on.
- **4.7 `receive().stored()` shape.** divergence. Sim invents
  `activation.kind === "blob_stored"` and skips the top-level flatten
  (`rewind_test.mjs:794-817`); prod resumes it as a bound `fetch_chunk` with
  `request.ok/status/done` set (`blob_receive.zig:426-459`,
  `globals.zig:2725-2817`) — `if (!request.ok)` takes the wrong arm in sim.
- **4.8 `fetchResult()` (detached continuation) mixes two prod surfaces.**
  divergence. It builds a cross-module entry WITH the bound-style top-level
  flatten; prod's unbound cross-module fire carries the result only on
  `request.activation.*` (`worker_streaming.zig:3159-3239`) — a
  `_rp/complete.mjs`-style module written against sim's `request.ok` reads
  `undefined` in prod.
- **4.9 `whenConcurrent` / `stream()` don't thread the evolving
  `next({ctx})` between legs/chunks.** divergence. Every leg gets the
  original parent's ctx (`rewind_test.mjs:739,919`); prod replaces chain ctx
  on every re-hold and a no-ctx fetch resume reads the CURRENT ctx
  (`worker_streaming.zig:1213-1217`) — precisely the racing-fan-in shape the
  verb exists to test.
- **4.10 `inboundHeaders` on a module without `onHeaders`: prod falls back
  to buffered inbound (`worker_dispatch.zig:3684-3700`); sim errors.**
  divergence.
- **4.11 No harness verb for:** `inbound_chunk`/`onChunk` streaming-body
  folds (`worker_inbound_chunk.zig`), subscription fires (see 2.6), mixed
  timer+kv batches, and `overflow.lost_oldest > 0` (`components.zig:501-556`)
  — the documented "you missed writes" branch is untestable. missing.

## 5. Compute primitives and KV

- **5.1 Sim `TextEncoder` is latin1-truncating (`charCodeAt & 0xff`), not
  UTF-8.** divergence, wide blast radius. `epilogue.zig:341-346` vs native
  UTF-8 (`globals/textcodec.js` over `bindings/textcodec.zig`); the sim base
  has no native TextEncoder so the broken one always wins. Affects
  `base64url.encode(string)` (`globals/base64.js:176`), URLSearchParams
  serialization, OIDC JWS payloads (`globals/oidc.js:641`), ActivityPub
  signing input (`globals/activitypub.js:492`), `blob.write` length
  accounting (`globals/blob.js:273`), any hash/HMAC over encoded text.
  `"é"` → `[0xe9]` in sim vs `[0xc3,0xa9]` in prod. (TextDecoder fallback is
  UTF-8-correct but ignores label/fatal — cosmetic.)
- **5.2 KV guardrails absent offline.** divergence. Prod: object/array/
  null/undefined values → TypeError (`globals.zig:693-706`); reserved
  leading-`_` keyspace minus shim prefixes → `reserved_key`
  (`globals.zig:892-894`, `reserved.zig:136-142`); key > 256 B / value >
  1 MiB → throw (`globals.zig:900-906`). Sim accepts all
  (`host.zig:128-152`) — `kv.set(k, {a:1})` stores `"[object Object]"`.
- **5.3 `kv.prefix` paging.** divergence. Prod defaults limit→100, caps at
  1000 (`globals.zig:1104-1111`); sim returns ALL matches when omitted
  (binding passes 0, host treats ≤0 as everything — `host.zig:198-201`).
  Pagination loops written against sim silently truncate in prod.
- **5.4 `jwt.verify` silently reports RS384/RS512/ES384/ES512 (and
  P-384/P-521) invalid.** divergence. `globals/jwt.js:94-99` dispatches six
  algs; the sim's pure-JS verifiers return `false` for anything non-sha256 /
  non-P-256 (`sim_globals.zig:92,122-123`) — not a throw, a plain
  `valid:false`. An RS512 IdP rejects every login offline with nothing
  pointing at the sim gap.
- **5.5 `crypto.oidcGenerateKey/oidcSign` throw → OIDC *provider* mode and
  ActivityPub outbound (actor create, HTTP-Signature delivery) fail
  offline** (`sim_globals.zig:211-212`; callers `globals/oidc.js:166,223,
  282,643`, `globals/activitypub.js:260,608`). missing (declared, but the
  blast radius includes two shipped verticals). Verify paths all work.
- **5.6 Streaming-sha256 midstate tokens mutually unreadable.** divergence.
  Prod `"s2:"+base64url(binary)` (`bindings/crypto.zig:243-252`) vs sim
  `"js2:"+hex`, and `shaParse` throws on `s2:` (`sim_globals.zig:82-83`).
  Digests agree, but the token is documented to ride kv across activations
  (blob recipes store `meta.mid`) — replaying a prod-captured mid-stream
  `blob.write` world throws "invalid midstate token".
- **5.7 console formatting.** cosmetic. Prod: ToString + space-join, level
  as a `"[warn]"` prefix (`globals/console.js:36-82`); sim: JSON.stringify +
  separate `level` field (`epilogue.zig:242-243`). Log assertions/snapshots
  don't transfer.

## 6. Execution substrate

- **6.1 No CPU budget offline.** missing. Prod interrupts at 1 s (admin
  10 s) → 504 "handler exceeded cpu budget" + penalty box
  (`dispatcher.zig:71-105,317`; `worker_dispatch.zig:3603-3612`); the sim
  installs no interrupt handler (`root.zig:249-271`) — a `while(true)` hangs
  `rewind test` forever.
- **6.2 Arena: sim 16 MiB, no GC-on-OOM retry; prod 100 MiB + automatic GC
  re-execution.** divergence (sim-stricter). `root.zig:98`
  (`arena_reactor_new_open(8192, 16384)`; its doc-comment still says "the
  worker's 8 MiB" — stale) vs `snap.zig:62` + the retry
  (`dispatcher.zig:415-533`). A ~20–90 MiB-allocating handler passes prod,
  OOMs offline. `scenario()` also can't author the `arena_gc` regime bit.
- **6.3 Package imports (`@scope/pkg`) unresolvable offline.** missing. Prod
  normalizes via PackageResolver to `/pkg/<hash>/…`
  (`module_execution.zig:441-450,577-616`); the sim loader serves raw
  specifiers from sources/source_dir (`host.zig:225-254`) — any app importing
  a published package cannot run under `rewind test` at all.
- **6.4 `_middlewares/index.js` (`.js`) runs in prod, skipped by sim.**
  divergence. Prod checks `.mjs` then `.js` (`dispatcher.zig:366-369`); sim
  hardcodes `.mjs` (`root.zig:209`). An auth middleware in `.js` → sim tests
  reach the handler unauthenticated.
- **6.5 Over-popped `../` imports: prod clamps to the deployment root
  (`module_execution.zig:541-549`); sim joins onto the real filesystem and
  escapes `source_dir` (`host.zig:238-240`, `harness.zig:304-305`).**
  divergence (edge, and mildly alarming for hermeticity).
- **6.6 Host timezone leaks.** divergence (env-dependent). `Date.now` is
  pinned on both sides, but local-time methods (getHours, toString) use the
  host TZ on both — prod is UTC, `rewind test` is the dev machine.
- **6.7 World schema is silently typo-tolerant** (`world.zig:118-217`
  ignores unknown keys — `"now"` instead of `"now_ms"` runs with epoch 0 and
  "passes"), and `scenario()` can't author `arena_gc`, inbound binary bodies
  (`bodyB64`), or an inbound `export` override. missing/cosmetic.
- **6.8 Snapshot sidecars never pruned** (`harness.zig:434-474`): a renamed/
  reordered assertion (esp. positional `snapshot-N` auto-names) can compare
  against a stale baseline with no indication. cosmetic-but-wrong-verdict.

## 7. Verified consistent (spot list)

Fetch-resume ctx rule (fetch's own ctx else held `next({ctx})`, `"null"` =
absent) ≡ worker on all transports; middleware trust-boundary set + before
semantics + per-WS-frame execution; default-export table incl.
`durable_wake → default`; resolvedExport event-shape mapping; send_callback
and durable_wake flattened surfaces (modulo D1); WS frame surface (opcode,
binary as Uint8Array, ctx threading, read-your-writes across frames);
held/terminal disposition rule; PRNG (same xorshift64star seed path →
byte-identical sequences) and Date.now pinning; arena regime plumbing; kv
read-your-writes overlay + get-miss → null + prefix result shape/ordering/
cursor convention; cookie parsing rules; duplicate-header last-wins;
response default `{200,{},[]}`; blob.js/webhook/email/schedule/cron real
shims decompose identically (marker shapes, ids, caps); platform.js
augmentation + admin gating parity; browser.js fully covered by the
recorders; the KV bridge protocol and per-file snapshot sidecars; sim's
IIFE-wrapping of webhook.js.

## 8. Suggested burn-down order

1. **Error semantics (1.1–1.4)** — one epilogue/root change: throw → 500
   bundle, `ok:false`, discard the activation's writes from the fold.
   Biggest trust win per line changed.
2. **Decide D1/D2/D3** (worker-vs-docs) — then align sim + docs + worker.
3. **TextEncoder (5.1)** — embed textcodec.js equivalents or add a native;
   pure-JS UTF-8 encode is ~10 lines (the sha shim already has one).
4. **KV guardrails (5.2, 5.3)** — enforce caps/reserved/coercion + paging in
   the epilogue kv wrapper or host; mechanical.
5. **Effect-drop parity (2.1) + validation shims (2.3)** — make the
   recorders context-aware (held vs terminal at return time) and add the
   prod TypeErrors to the sim `_system.*` layer.
6. **Resume-fold fidelity (4.x)** — wakes[] emptiness/encoding, wake_to
   last-wins, cross-module next, stored()/fetchResult shapes, ws lifecycle,
   whenConcurrent ctx threading.
7. **Coverage verbs (2.6, 4.11)** — subscription fire, onChunk fold, wake
   batching/overflow.
8. **Substrate (6.x)** — instruction budget, arena size + GC retry parity,
   package resolution, `.js` middleware, `../` confinement.
