# Loop46 product plan

> **Status**: canonical plan as of 2026-04-21. Supersedes any earlier admin-UI-only roadmap.
>
> **Purpose of this document**: capture the locked architecture decisions, the rationale behind them (including options considered and rejected), and the phased build plan. Future work sessions should read this end-to-end before making decisions that could contradict it.
>
> **Navigation**: §1–§8 are the original plan (2026-04-17). §9 onward was appended on 2026-04-21 and captures what's shipped, what we considered, audit findings against rove-library principles, and pre-release surprises customers may hit.

## 1. What Loop46 is

Loop46 is the productized face of `rove`. It sells the rove substrate as:

> "A backend in 30 seconds. JS handlers, KV store, free static hosting."

The deeper product identity — the thing nobody else is offering:

> **Purely functional serverless.** Handlers are pure functions of `(request, kv)`. All outbound side effects are declarative commands that resolve asynchronously. End-to-end replay determinism → time-travel debugging with DevTools breakpoints on any production request.

### Audiences

- **C1 — direct customers**: developers who sign up, pick an API name, upload code, run an API.
- **C2 — customers of our customers**: end users hitting the C1's site/PWA that talks to the C1's API.

### Onboarding promise

1. User visits `app.loop46.me`.
2. Types a preferred API name + email, clicks Create.
3. Receives magic-link email; clicks through.
4. Lands in dashboard with a working code editor, KV viewer, log tail.
5. Their API is already live at `{name}.loop46.me` with starter code.

## 2. Locked architecture decisions

Each decision includes the **why**, often with notes on alternatives that were considered and ruled out. When editing this document, preserve the rationale — it's what keeps future sessions from re-opening settled questions.

### 2.1 Domain + origin layout

- **Register and own `loop46.me`.** `.site` is already a public suffix (real TLD).
- **`loop46.com`**: marketing site only. No auth, no API, no cookies.
- **`{name}.loop46.me`**: each customer's instance. **Single origin** hosts both static files and handler API. Static served by path (e.g. `/index.html`); handler dispatch covers everything else. Same-origin by construction → first-party cookies work, no CORS for customer UIs talking to their own API.
- **`app.loop46.me`**: admin UI. Same path layout as a customer subdomain — **dogfooded**.
- Wildcard TLS `*.loop46.me` terminated in-process by rove-js. Cert obtained via Let's Encrypt DNS-01 (`scripts/rove-lego-renew.sh`). Cloudflare sits in front as CDN/WAF; origin still presents a valid cert (Full/Strict).

**Why a separate `.site` TLD?** Originally explored `{name}.api.loop46.com` for the API and a separate host for static. That required Public Suffix List registration for `site.loop46.com` before browsers would isolate tenants' cookies, and PSL propagation takes weeks-to-months — a launch blocker. Using `loop46.me` as a distinct registered domain puts `{name}.loop46.me` one level below an existing public suffix (`.site`), so default host-only cookies work immediately. PSL submission for `loop46.me` still happens in parallel for defense-in-depth but is not a launch blocker.

**Why one origin per tenant, not separate static + API origins?** To make first-party cookies work without PSL. Split origins (`{name}.loop46.me` + `api.{name}.loop46.me`) need `loop46.me` to be on the PSL *and* require per-customer wildcard TLS (two labels deep). Collapsing to one origin gives first-party cookies trivially and a single wildcard cert covers everyone.

**Why dogfood the admin UI?** If the auth model must work cross-origin for our customers (e.g. Safari ITP, third-party cookie deprecation), then proving it by hosting the admin UI the same way a customer would is the cleanest test. If the admin UI needs a privileged carve-out, something is wrong with the customer story.

**Defense against cross-tenant cookie injection**: the response layer sanitizes `Set-Cookie` `Domain=` attributes. A handler attempting `Set-Cookie: foo=bar; Domain=loop46.me` gets stripped to host-only. This protects against a malicious customer pushing cookies onto other tenants. PSL gives the same guarantee at the browser level once it propagates.

### 2.2 Auth model

- **C1 auth (admin)**: HttpOnly + Secure + SameSite=Lax session cookies on `app.loop46.me`. Opaque session tokens, stored server-side in root.db, revocable.
- **C2 auth (customer's end users)**: customer's problem. We expose primitives (HMAC helper, cookie parse/serialize, encrypted KV). Customer's handler code mints and verifies whatever token/cookie shape it wants. Because customer UI and customer API share one origin, cookies are first-party out of the box.
- **C2 sessions for SSE (`_rove_sess`)**: a separate platform-managed cookie (HttpOnly + Secure + SameSite=Lax) eagerly minted on handler invocations to give every browser a stable identity for the SSE/events stream (§2.12). NOT an auth claim — just an opaque id. Customer binds session→user themselves if they need that link. Distinct namespace from the customer's own auth cookies above.
- **Magic-link signup**:
  1. `POST /v1/signup` with name + email.
  2. Server validates name available, creates instance, deploys starter content, assigns `{name}.loop46.me`, mints magic token (32 bytes, 15-min TTL, single-use, hashed under `_magic/{hash}`), fires `email.send`.
  3. User clicks `GET /v1/auth?mt=...` → server validates, sets session cookie, 302 to `/dashboard#{name}`.

**Why cookies, not bearer tokens?** Bearer tokens work on every browser and every origin, but they require customers to write `headers: { Authorization: 'Bearer ' + token }` on every fetch and manage token storage themselves. Cookies, made first-party by the one-origin-per-tenant layout, recover the "simple fetch" developer story with no setup. Bearer tokens remain as a documented fallback for customers whose UI lives on a genuinely external host (Neocities, GitHub Pages, etc.).

**Why no `env` / secrets primitive?** Considered a write-only env API (`PUT /env/{key}` but never a `GET` that returns values). Rejected because any handler can deploy code that reads the value and returns it — so the write-only UI is ceremony, not real defense. Secrets are just KV entries; page-level encryption at rest provides the actual protection. Customers pick their own naming convention (`config/*`, `secrets/*`, whatever). If we want a "mark this key as sensitive → show dots in dashboard" affordance later, that's a UI flag, not a new storage primitive.

### 2.3 Execution model

**Handlers are pure functions of `(request, kv_snapshot)`.** Deterministic only.

- No `fetch`, no `setTimeout`, no uncaptured `Date.now()` / `Math.random()`.
- All external effects route through declarative outbox-style primitives: `webhook.send` (§2.6) for outbound HTTP, `email.send` (§2.6) for transactional mail, `events.emit` (§2.12) for live UI push to the customer's connected clients. Each writes a deterministic outbox row inside the handler's transaction; the actual delivery happens in a separate pump.
- All nondeterministic inputs are tape-captured.
- Every request gets a fresh QuickJS context via snapshot-restore (existing mechanism in `src/js/worker.zig`).
- **CPU budget: one 10ms envelope covers the whole request — handler body + every trigger it fires (BEFORE and AFTER) + every cascade those triggers trigger.** No per-trigger or per-cascade sub-budgets. Exceeding 10ms terminates the request and rolls back the transaction. Callbacks run as independent handler invocations in their own transactions and get their own fresh 10ms envelope when they fire.

**Why so strict?** Determinism is what lets us offer the replay-with-breakpoints story that differentiates Loop46. The moment a handler can `await fetch(...)` inline, replay has to either re-execute the fetch (loses determinism) or fake it (diverges from prod). Forcing all external I/O through the outbox means replay is exact, always — a captured response from the outbox record drives the callback on replay just like it did in prod.

The cost: "call an external API and use the result inline" is impossible. Customers rewrite as "fire webhook → return 'accepted' → callback updates state → client observes via poll/SSE." This is where modern serverless is going anyway (every SaaS backend is full of async job queues), so it's a calculated bet.

### 2.4 File API + static serving

#### Storage layout

Extends the content-addressed scheme already in `src/files/root.zig:14`:

```
file/{path}                 → {hash, kind, content_type}
bytecode/{source_hash}      → {bytecode_hash}
deployment/{id}             → manifest (gains content_type + kind per entry)
deployment/current          → {id}
```

- **Prefix `_static/<path>`**: raw bytes. Kind = `static`. Served at URL `/<path>`. No compile. The prefix earns its keep because static files have free-form names (`logo.png`, `style.css`) and need explicit "raw bytes, do not compile" tagging.
- **Top-level `<path>.mjs` / `<path>.js`**: JS source. Kind = `handler`. Compiled to bytecode. No prefix — the `.mjs`/`.js` extension plus the manifest `kind` field already disambiguates from static. (An earlier draft mandated a `_code/` prefix here for symmetry with `_static/`; dropped 2026-04-27 as pure ceremony.)
- **Top-level `_*` paths are system-reserved.** `_static/`, `_triggers/`, `_404/`, `_500/`, future system namespaces. Customers cannot claim them.
- Uploads outside these rules are rejected.

#### Routing resolution (for incoming `GET /foo`)

Order:
1. `_static/foo` exact match
2. `_static/foo.html`
3. `_static/foo/index.html`
4. Handler: `foo/index.mjs`, `foo.mjs`, walk up to `index.mjs`
5. Convention 404: `_static/_404.html` → `_404/index.mjs` → built-in 404
6. Convention 500: `_static/_500.html` → `_500/index.mjs` → built-in 500

Trailing slash: redirect `/foo/` → `/foo` (301).

#### Path validation

Reject `..`, `//`, NUL, percent-encoded slashes, leading `/`. Lowercase + digits + `-_./` only. Cap at `MAX_PATH_LEN` (192, per `src/files/root.zig:73`).

#### Content type

Extension → MIME table (browser-standard). Override via upload `Content-Type` header or handler `opts.contentType`. No magic-byte sniffing.

#### Cache headers

- `ETag: "<hash>"` on every static response (free from content addressing).
- Default `Cache-Control: public, max-age=0, must-revalidate` (browser keeps bytes, always revalidates → almost always 304).
- Convention: files under `_static/_immutable/` get `max-age=31536000, immutable`.
- Cloudflare fronts static; edge caches decrypted bytes.

#### Size caps (v1)

| | Cap | Notes |
|-|-|-|
| Static file | 1 MB | per-file |
| Handler source | 64 KB | per-file |
| Total static per instance | 25 MB | plan-tier knob |
| Total handler source per instance | 1 MB | plan-tier knob |

#### Handler signature

Default export is the modern path; it's called with **no arguments** — handler reads from the ambient `request` global and writes to `response`. Named exports + `?fn=` stays as a power-user knob for RPC-shaped APIs.

```javascript
// index.mjs
export default function () {
  const items = JSON.parse(kv.get("items") || "[]");
  response.headers = { "content-type": "text/html" };
  return `<ul>${items.map(i => `<li>${i.name}</li>`).join("")}</ul>`;
}
```

**Body comes from the return value**, not from `response.body`:
- `string` → emitted as-is, no auto-content-type
- `undefined` / `null` → empty body
- anything else → `JSON.stringify(value)` with `content-type: application/json` auto-stamped (handler can override via `response.headers["content-type"]`)

**No `new Response(...)` / `Headers` / `fetch` / `URL`.** The aspirational fetch-API shape was dropped 2026-04-21 — a return-value + `response.*` globals shape is shorter, avoids a class hierarchy we'd have to maintain, and keeps replay determinism obvious (the return value is the captured body). Customers reach for `response.status = 404`, `response.headers = {...}`, `response.cookies.push("foo=bar; HttpOnly")`.

**No built-in EJS / Sucrase / TypeScript transforms.** Customers who want templating write template literals or `import` a library. Rationale: shift-js had built-in `.ejs` + `.ts` transforms; on a platform-not-framework, these become version-management liabilities and lock customers out of other choices. Keeping the platform small is more defensible than shipping a specific framework's idioms.

#### Handler-side globals

```javascript
files.get(path)                   // → Uint8Array | null
files.getText(path)               // → string | null
files.put(path, content, opts?)   // → { deployment_id }; opts: { contentType }
files.delete(path)                // → { deployment_id }
files.list(prefix?)               // → [{path, size, hash, contentType}], paginated
```

Handler-initiated writes create new deployments — same transport, different path. Enables CMS-style apps that edit themselves.

#### Admin HTTP API

```
# Browse + edit
GET    /v1/instances/{id}/files
GET    /v1/instances/{id}/files/<path>
PUT    /v1/instances/{id}/files/<path>         # single-file → new deployment
DELETE /v1/instances/{id}/files/<path>         # single-file → new deployment

# Bulk / CLI — content-addressed two-phase
POST   /v1/instances/{id}/blobs/check          {hashes:[]} → {missing:[]}
PUT    /v1/instances/{id}/blobs/<hash>          body = bytes
POST   /v1/instances/{id}/deployments           {files:{path:{hash,content_type?}}, comment?, parent_id}
GET    /v1/instances/{id}/deployments           list
POST   /v1/instances/{id}/deployments/{id}/activate   rollback / re-promote
GET    /v1/instances/{id}/deployments/{id}      manifest
POST   /v1/instances/{id}/lint                  compile-without-deploy
```

Two-phase content-addressed upload matches `docker push`. CLI (`loop46 deploy ./dir`) hashes locally, queries `blobs/check`, uploads only missing, commits manifest. Incremental redeploys are cheap.

#### Drafts

A draft is a pending deployment with `status: draft`. Editor saves write to draft, compile-on-save validates. "Deploy" button CAS-swaps `current`. Drafts are per-user, expire after N days if unpromoted. Preview URL `{name}.loop46.me?__draft={id}` serves from draft manifest (session-gated).

#### Concurrent-deploy safety

Optimistic CAS: every `POST /deployments` includes `parent_id` = the deployment the draft was based on. If `current` has moved past `parent_id`, reject 409 and dashboard re-applies. Rationale: lock-per-instance would silently serialize; CAS surfaces conflict visibly and lets the customer save-as-different-name to compare.

#### Retention

Keep last 50 deployments + last 7 days (whichever is larger). Blob GC only when no live manifest references a blob.

#### Compile errors on bulk deploy

Reject whole deploy with `{file, line, col, message}`. Dashboard also runs `POST /lint` on editor debounce for inline error surfacing before Deploy is pressed.

#### Deploy metadata

`{id, created_at, created_by, parent_id, comment, file_count, total_size}`. CLI supports `--message`. Dashboard takes optional comment.

#### Deploy diffs

Trivial because content-addressed: compare manifest entries A vs B, classify as added / removed / changed. History view in dashboard.

#### Module imports

Between handler files: relative paths resolve through the current deployment's manifest only. **No external imports at runtime** in v1 (no `import 'https://esm.sh/...'` inside the runtime — that's a syscall and a security/determinism headache). Customers vendor libraries into a `lib/` folder (or anywhere they like — the manifest is flat).

### 2.5 Triggers

"JS stored procedures" — deterministic, in-transaction code that fires on KV writes matching a prefix.

#### Registration via path convention

The path under `_triggers/` IS the prefix. `_triggers/users/sessions/index.mjs` fires on writes whose kv key starts with `users/sessions/`. Symmetric with handler routing (PLAN §2.4) — customers already know "path = config" from `users/index.mjs` → `/users`. No `config` export, no typo'd prefixes, no extra discovery step.

```
_triggers/
    index.mjs                    fires on every write (prefix "")
    users/
        index.mjs                fires on `users/*`
        sessions/index.mjs       fires on `users/sessions/*` (more specific)
    secrets/index.mjs            fires on `secrets/*`
    orders/index.mjs             fires on `orders/*`
```

Each trigger module hooks specific op×timing combinations via named exports, with `default` as a catch-all:

```javascript
// _triggers/users/sessions/index.mjs
// Fires on writes to users/sessions/*

export function beforePut(event) {
  // Validate the new value. Throw to reject; return a value to mutate;
  // return undefined to leave alone.
  const sess = JSON.parse(event.value);
  if (!sess.user_id) throw new Error("session missing user_id");
}

export function afterPut(event) {
  // Maintain a reverse index — runs in the same transaction as the
  // originating write.
  const sess = JSON.parse(event.value);
  const sid = event.key.split('/').pop();
  kv.set(`users/by-session/${sid}`, sess.user_id);
}

export function afterDelete(event) {
  if (event.previousValue) {
    kv.delete(`users/by-session/${event.key.split('/').pop()}`);
  }
}

// No `beforeDelete` exported → delete is allowed without validation.
// No `default` exported → ops without a named export are no-ops here.
```

Available named exports:

| Export | Fires when | Can throw? | Return value |
|---|---|---|---|
| `beforePut(event)` | before a put commits | yes (rejects write, see §catchable-throw) | new value (or `undefined` to leave alone) |
| `afterPut(event)` | after a put commits | yes (rolls back the originating write) | ignored |
| `beforeDelete(event)` | before a delete commits | yes (rejects delete) | ignored |
| `afterDelete(event)` | after a delete commits | yes (rolls back the originating delete) | ignored |
| `default(event)` | any op×timing not specifically named | as above (depends on `event.timing`) | as above |

A trigger module exporting nothing (other than imports) is a no-op for that prefix.

Triggers are part of the deployment manifest — versioned with code, rolled back atomically with everything else. No runtime `triggers.register()`.

#### Event object

```javascript
{
  key, value, previousValue, op: "put" | "delete",
  timing: "before" | "after",
  timestamp,
  actor: { request_id, ... } | null,
  depth: number,     // 0 for user-initiated writes; +1 per cascade level
}
```

`event.op` and `event.timing` are useful inside `default` (catch-all) handlers; the named exports above know their own op×timing implicitly.

#### Semantics

- **Synchronous, in-transaction.** A throw in BEFORE rejects the originating write (catchable in handler — see §catchable-throw below); a throw in AFTER rolls back the originating write plus everything the trigger did.
- **BEFORE** can reject (throw) or mutate (return new value). **AFTER** can cascade further KV writes in the same transaction.
- **Tree-traversal order on multiple matches.** Writing key `users/sessions/abc` matches `_triggers/index.mjs`, `_triggers/users/index.mjs`, AND `_triggers/users/sessions/index.mjs` if all exist. BEFORE chain fires **outermost-first** (catchall → users → sessions); the actual write happens; AFTER chain fires **innermost-first** (sessions → users → catchall). Mirrors typical onion-shell middleware composition: broad policies validate before narrow ones; narrow cleanup runs before broad cleanup.
- **Cascades allowed**, depth limit 8. Platform-reserved prefixes (see "Platform-prefix guard" below) are un-triggerable from customer code.
- **Same deterministic rules as handlers**: no `fetch`, no async IO, no uncaptured nondeterminism. Trigger CPU time counts against the request's shared 10ms envelope (§2.3) — no separate per-trigger budget.
- **Raft**: leader runs triggers; replicated log entry contains the *final write-set*, not the original write. Replicas apply atomically without re-running JS. This is the only way to stay deterministic given potential future nondeterminism in triggers.
- **Tape replay**: triggers re-fire automatically when kv ops are replayed — breakpoints in trigger code work on replay.

#### Limits (v1)

- CPU time counts against the request's shared 10ms envelope. No separate per-trigger wall-clock cap.
- 1MB total writes per invocation.
- Depth 8.
- 32 triggers per instance (plan-tier).

#### Backfill / reapply (advanced technique, no new primitive)

Common need: customer adds an index trigger (or changes one), wants to apply it to existing data so the index is populated before reads start hitting it. Loop46 ships no `batch.*` API for this — composes from existing primitives.

**Synchronous one-shot (small data):** customer writes a regular handler that scans a page via `kv.prefix(prefix, cursor, limit)` and applies the trigger logic to each key. Trigger logic should be extracted to a shared module the trigger module and the backfill handler both import — single source of truth.

```javascript
// _backfill_session_index.mjs (called from admin / cron / one-time)
import { rebuildSessionIndex } from "./lib/session_index.mjs";
export default function () {
  const cursor = request.query?.split("cursor=")[1] ?? "";
  const page = kv.prefix("users/sessions/", cursor, 100);
  for (const { key, value } of page.entries) rebuildSessionIndex(key, value);
  return { processed: page.entries.length, next_cursor: page.entries.at(-1)?.key ?? null };
}
```

**Asynchronous chain (large data, ergonomic):** customer's handler processes one batch and fires a self-webhook to continue with the cursor in the callback context. Each link gets a fresh 10ms budget; failures surface via standard webhook retry + DLQ; the customer can monitor progress via the request log.

```javascript
// _backfill_session_index.mjs
import { rebuildSessionIndex } from "./lib/session_index.mjs";
export default function () {
  const cursor = JSON.parse(request.body || "{}").cursor ?? "";
  const page = kv.prefix("users/sessions/", cursor, 100);
  for (const { key, value } of page.entries) rebuildSessionIndex(key, value);

  const next_cursor = page.entries.length === 100 ? page.entries.at(-1).key : null;
  if (next_cursor) {
    webhook.send({
      url: `https://${request.headers.host}/_backfill_session_index`,
      method: "POST",
      body: JSON.stringify({ cursor: next_cursor }),
      onResult: "_backfill_done",   // optional — fires on terminal failure
    });
  }
  return { processed: page.entries.length, done: !next_cursor };
}
```

A dedicated `batch.*` primitive (background drainer, progress tracking, cascade-during-batch policy, plan-tier rate limits, programmatic semantics) is deferred to v2 — see §4. The self-webhook chain covers the "advanced customer needs to backfill an index" case without committing the platform to those decisions before a real customer asks.

#### Implementation notes (decided 2026-04-27, before code lands)

- **No deploy-load JS evaluation.** The path-based registration model means we don't need to evaluate trigger modules just to learn what prefix they fire on — the path tells us. Deploy-load just walks the manifest for entries matching `_triggers/.../index.{mjs,js}`, derives the prefix from the path, and stores `prefix → bytecode_path` in a per-tenant registry on `TenantFiles`. Compile errors in the trigger source surface at upload time the same way they do for any handler file (PLAN §2.4) — no special-case logic.
- **Lazy export lookup at fire time.** Trigger modules are evaluated into the handler's QuickJS context on first fire (same machinery handlers use), then the named export (`beforePut` / `afterPut` / `beforeDelete` / `afterDelete` / `default`) is looked up via `JS_GetPropertyStr`. Missing export → no-op for that op×timing. Hash lookup is O(1); negligible cost per fire.
- **BEFORE-trigger value mutation via return value.** Trigger function's return value becomes the new value being written. Returning `undefined` leaves the value untouched. Symmetric with PLAN §2.4's "body comes from the return value" rule for handler default exports — same shape, no `event.value =` mutation surface.
- **Trigger rejection is a catchable JS exception (§catchable-throw).** When a BEFORE trigger throws, an inner savepoint (opened only when the registry shows matching BEFORE triggers — no cost when none match) rolls back any writes the trigger made before throwing, then `kv.set` / `kv.delete` re-throws into the handler as `Error` with `code: "trigger_rejected"` and `message: "<trigger_path>: <original message>"`. The customer can `try { kv.set(...) } catch (e) { ... }` to handle the rejection; uncaught throws bubble to the handler-exception path (§11) → 500 with the message in the body. The trigger's *protection* is never bypassable — the rejected write doesn't apply regardless of whether the handler catches; only the handler's *control flow* is affected.
- **Rollback gotcha to document for customers**: a BEFORE trigger that does `kv.set("audit/last-attempt", ...)` *before* throwing has that audit write also rolled back (the inner savepoint covers everything inside the trigger invocation). Customers who want "log every rejected attempt" should do it from an `afterPut` (only fires on successful writes) or from the handler itself.
- **Lookup structure: sorted array, linear scan.** With a 32-trigger ceiling, O(32) per kv write is well under any budget. The array is sorted by prefix length (descending) for stable tree-traversal order. Defer a prefix trie to v2 if the cap ever raises.
- **Platform-prefix guard at two layers.** Deploy-load rejects trigger paths whose derived prefix overlaps any of: `_audit/`, `_deploy/`, `_outbox/`, `_outbox_inflight/`, `_dlq/`, `_callback/`, `_magic/`, `_triggers/`, `_events/`, `_sessions/` (and any future system namespace). Fire-time also skips trigger dispatch when the kv key has a platform prefix — defense in depth.
- **Cascade depth tracked on `DispatchState`.** Single counter, incremented before each recursive trigger fire, decremented after; throws at 8.
- **`previousValue` event field**: implementation does an extra `kv.get` for the existing value before each write that has matching triggers. Acceptable cost given the 32-trigger ceiling and the read-your-writes guarantee from `TrackedTxn`.
- **Storage is just files.** Trigger modules live in the customer's deployment manifest exactly like any other handler file: `file/_triggers/users/sessions/index.mjs → {hash, kind: "handler", content_type}` in `files.db`, source + bytecode bytes in `file-blobs/{hash}`, replicated via raft envelope type 3 (files_writeset). Same content-addressed two-phase upload pipeline (§2.4). What's *new* and lives in the worker (not files-server) is the in-memory **trigger registry** on `TenantFiles`, derived at deploy-load time. Same split as handlers (source in files-server, runtime bytecode cache in worker).
- **Rove ECS audit per `~/.claude/memory/feedback_rove_design_first.md`**: triggers introduce no new entities or collections. The registry sits on `TenantFiles` next to the existing `bytecodes` map; execution is recursive enhancement of `kv.set` / `kv.delete` JS globals inside the handler's existing QuickJS context. The handler entity in `request_out` remains the only entity in flight. No new Rows, no new systems at the rove layer.

### 2.6 Webhooks (outbox pattern)

The only path to the outside world. Directly inspired by Elm's `Cmd` model.

#### API

```javascript
const id = webhook.send({
  url: "https://api.stripe.com/v1/charges",
  method: "POST",
  headers: { Authorization: "Bearer " + kv.get("stripe_key") },
  body: JSON.stringify({ ... }),
  onResult: "stripe/charge_result",      // string path to callback handler
  context: { charge_id: "c_abc", user_id: 42 },
  maxAttempts: 10,
  timeout: 30_000,
  retryOn: [408, 425, 429, 500, 502, 503, 504, "network"],
});
```

#### Callback handler

```javascript
// stripe/charge_result.mjs
export default function (event) {
  // event.context     → what was passed in
  // event.outcome     → "delivered" | "failed" | "cancelled"
  // event.response    → { status, headers, body }
  // event.attempts    → number
  // event.webhookId   → matches the id returned by webhook.send
  if (event.outcome === "delivered") {
    kv.put(`charges/${event.context.charge_id}`, event.response.body);
  }
}
```

**Callback is a string path, not a closure.** Closures can't survive serialization or a deploy cycle; string references resolve against the *current* deployment at callback time.

**Callback runs in its own transaction.** Not same-tx as the originating request (that already committed). Can fire more webhooks → saga patterns compose naturally.

#### Storage

- `_outbox/{monotonic_id}` — pending deliveries, committed in originating transaction.
- `_outbox_inflight/{id}` — lease records while drainer holds an item.
- `_dlq/{id}` — terminal failures (paid-tier feature).

**Outbox id derivation**: `hash(request_id || call_index)`. Deterministic across replays. Call index = 0-based order of `webhook.send` within one handler execution.

#### Drainer

- Runs on raft leader. Lease-based for failover.
- Scans `_outbox/*` where `nextAttemptAt <= now`, leases, attempts delivery.
- On 2xx: delete outbox, enqueue callback invocation (itself a raft-replicated "run handler" event so callback timing matches normal request timing).
- On retryable failure: update attempts, compute `nextAttemptAt = now + base * 2^attempts + jitter`, release lease.
- On non-retryable failure or attempts exhausted: move to `_dlq`, enqueue callback with `outcome: "failed"`.

#### Retry defaults

- Exponential with full jitter (0..delay). Base 1s, cap 5min.
- Default `maxAttempts: 10` (≈1 hour envelope).
- Retryable: 408, 425, 429, 5xx, network errors, timeouts. Non-retryable: all other 4xx.

#### Delivery guarantees

**At-least-once.** Receivers must dedupe via the `X-Rove-Webhook-Id` header (stable across retries). Industry-standard shape matching Stripe/GitHub/Shopify.

#### Ordering

**No ordering guarantees**, not even per-instance. Different destinations have different latencies/failure rates; strict ordering would kill throughput and can't be meaningfully delivered anyway. Customers who need ordering chain via callbacks.

#### Headers injected

- `X-Rove-Webhook-Id: <outbox_id>`
- `X-Rove-Webhook-Attempt: <n>`
- `X-Rove-Signature: <hmac-sha256 of body with per-instance webhook secret>`
- Optional `X-Rove-Idempotency-Key: <customer-provided>` passthrough

Per-instance webhook signing secret auto-provisioned on instance create, rotatable.

#### Security

- **SSRF protection (mandatory, non-optional)**: block private IP ranges (`10/8`, `172.16/12`, `192.168/16`, `127/8`, link-local `169.254/16`, metadata `169.254.169.254`), IPv6 equivalents. Re-resolve on each retry (DNS rebinding defense).
- **TLS always on**. No `rejectUnauthorized: false` anywhere. Invalid cert = failure.
- Redirect cap: follow up to 3, else error.
- DNS resolve timeout 5s, connect timeout 10s, per-attempt total 30s default (5min hard cap).

#### Response body capture

Default 256KB; truncation flagged as `truncated: true`. Larger caps as plan-tier knob. Truncated bytes are what the callback sees on replay too (determinism).

#### Draft webhooks

`?__draft=` deploys route `webhook.send` to a **sandbox outbox**: visible in dashboard (see what would fire), never delivered. Avoids spooky action where a QA preview causes production side effects.

#### Replay

- Original handler replay: re-calls `webhook.send`, deterministic ids match original, doesn't actually deliver.
- Callback replay: synthesized from captured response record. Breakpoints work.

#### `email.send` specialization

Wraps `webhook.send` with platform-provided URL + creds.

```javascript
email.send({
  to: "user@example.com",
  subject: "Verify your Loop46 account",
  text: "Click: https://app.loop46.me/v1/auth?mt=...",
  onResult: "signup/email_sent",
  context: { user_id: 42 },
});
```

Platform fills in SMTP gateway URL + auth. Customer sees a clean API. Paid-tier BYOSMTP just overrides `url` + auth headers.

Magic-link emails go through this same primitive — dogfood from day one.

#### Plan-tier caps

- `maxAttempts` ceiling (20 free / 100 paid).
- Concurrent deliveries (10 free / higher paid), 3 per destination (avoids hammering one URL).
- Outbox depth limit (10k default; over-limit → `webhook.send` throws → tx rolls back).
- DLQ: paid feature. Free tier discards terminal failures after callback fires with `outcome: "failed"`.

#### Deferred

- Fan-in (multiple webhooks → one callback). Customers chain manually via callbacks.
- Async / fire-and-forget (no callback). Add as distinct primitive later to keep sync/async semantics unmixed.
- Circuit breaker per destination URL.
- Cancellation (`webhook.cancel(id)`). Design is compatible; add when requested.

### 2.7 Encryption at rest

**Page-level encryption on all SQLite files.** Not per-value, not per-namespace.

- **Master key** lives outside rove's persisted state: `ROVE_MASTER_KEY_FILE=/etc/rove/master.key` or env var. **Never in root.db** — root.db is copied freely (backups, raft replicas, dev dumps); a leaked root.db must not decrypt anything.
- **Per-instance data key**: `HKDF(master, "rove-db-v1:" || instance_id)`.
- **Different HKDF labels** per subsystem: `rove-db-v1`, `rove-blob-v1`, `rove-tape-v1`. Compromise of one subsystem's derived key doesn't auto-leak the others.
- **Platform key** (separate derivation) for root.db itself.
- **Format**: `version(1) || nonce(12) || ciphertext || tag(16)` using AES-256-GCM. Version byte gives rotation path.
- **Tapes are sensitive**: encrypted same as other storage. Browser replay is server-side-decrypted and shipped plaintext-over-TLS to the authenticated admin session. No client-side decryption (no key distribution problem).

**Why page-level, not per-value?** Original proposal was a separate `env` primitive with value-level encryption. That turned out to be security theater — any handler can exfiltrate secrets via deployed code, so a write-only admin UI doesn't actually keep secrets from an authenticated admin. Page-level encryption is the actual at-rest protection. One code path. Applied uniformly. Marketable story: "everything is encrypted at rest, per tenant, with keys we can rotate."

**Why vendored AES-GCM SQLite VFS, not SQLCipher?** SQLCipher is proven but adds a nontrivial dependency. `vendor/README.md` captures an invariant: all C deps are vendored, no network installs, no package managers. A ~300-line custom VFS matches that posture. Decision not 100% locked — audit implications differ and SQLCipher's battle-testing has real value; confirm in Phase 9.

**Ops consequences**: losing `master.key` = permanent tenant data loss. Document loudly. Master must be backed up separately from rove's persisted state.

### 2.8 Raft / cache invalidation

- **Manifest cache invalidation uses the raft apply hook**, not polling. `deployment/{instance}/current` writes replicate; on apply, invalidate that instance's cached manifest. Scales to thousands/millions of instances without per-instance polling.
- Same mechanism extends to trigger set, host → instance cache, webhook secret rotation.
- SSE / push for the *dashboard client* watching live deploy or log state is a separate layer, not in the raft critical path.

**Why not poll?** Polling thousands of instances every second (the naïve "re-check current deployment pointer on every request") doesn't scale and burns CPU. Since deploys already go through raft, reusing the apply notification is free.

### 2.9 Logs + observability

- **Every request log tagged with `deployment_id`.** Enables "all 12 failures were on deployment 42" debugging.
- No synthetic "deploy event" in the stream — the per-request tag is more accurate and doesn't mislead about the transition window.
- Trigger fires + webhook attempts + callback invocations log with `parent_request_id` for nested-thread display in the dashboard log view.
- Every HTTP response carries `X-Rove-Tape-Id: {id}` → DevTools click-through to the dashboard replay viewer.
- Tape sampling: 100% in dev, configurable % in prod (plan-tier).
- Tape TTL 30 days default.
- Tapes encrypted at rest; admin access gated by session auth.
- For external sharing of a tape: deferred (customer shares the tape id with support; support looks it up. No redacted-export tooling in v1).

### 2.10 Rate limiter (general primitive)

- Token bucket per `(instance, action)`. Actions: `request`, `deploy`, `email`, `webhook_attempt`, `kv_write`.
- Per-plan configuration on instance record.
- Per-worker bucket with periodic sync to root.db (multi-worker accepts small overshoot).
- Applied at: request dispatch, deploy API, `email.send`, each webhook attempt, optionally kv writes.
- Dashboard shows per-instance state.

Designed as a general primitive from day one — also the knob used to differentiate plan tiers.

### 2.11 CLI (v1 scope)

- `loop46 deploy ./dir` only.
- `loop46.json` at project root: `{ instance: "foo", apiBase: "https://app.loop46.me" }`. Defaults `apiBase` to prod.
- Auth: token copy-paste. Dashboard has "Create deploy token" button; prints plaintext once.
- Wire protocol: content-addressed two-phase (see 2.4). Incremental deploys upload only changed bytes.
- **Future**: `loop46 kv get/put`, `loop46 logs tail`, `loop46 init`, `loop46 dev` (local mini-rove).

### 2.12 Server-sent events (live UI updates)

The companion to webhooks (§2.6): handlers fire events from inside their transaction, connected clients receive them over a long-lived SSE stream. Same outbox/replay/determinism story; same "pure handler + declarative side effects" model. Different direction — webhooks push out to the world, events push out to *this customer's clients*.

**Why SSE not WebSockets**: HTTP/2, server→client only, browsers auto-reconnect with `Last-Event-ID` resume built in. WebSockets and HTTP/2 don't naturally compose — RFC 6455 is HTTP/1.1 `Upgrade:` (forbidden in h2), RFC 8441 bridges via extended CONNECT but Cloudflare in front (per §2.1) downgrades WS traffic to HTTP/1.1 to the origin. Adding WS support would require a parallel HTTP/1.1 server stack alongside our nghttp2-based h2 stack: separate parser, separate framing (RFC 6455 masking + fragmentation + ping/pong), separate connection lifecycle, ALPN negotiation. Several thousand LOC and a two-stack maintenance burden. WS stays in §4 deferred-to-v2; SSE covers ~90% of "server pushes to client" use cases.

#### Sessions (platform-managed)

A new server-managed cookie `_rove_sess` (parallel to admin's `rove_session` but in customer namespace):
- 64-hex-char opaque token, HttpOnly + Secure + SameSite=Lax. No server-side validation table — the cookie value IS the id.
- **Eagerly minted** on any handler invocation that arrives without one. Static asset serving short-circuits before the handler, so `favicon.ico` etc. don't pollute. `Set-Cookie` added to the response when a new id was minted during the request.
- **One logical stream per session, N concurrent EventSource connections under that session, all receive every event.** Multi-tab works naturally.
- Customer binds session→user themselves: `kv.set('sessions/${request.session.id}/user', user_id)`.

#### API

```javascript
events.emit("hello");                                 // current session, type="message"
events.emit({ data: { count: 42 }, type: "tick" });  // current session, custom type
events.emit({ to: someSessionId, data: ... });        // explicit target
events.emit({ to: [sid1, sid2], data: ... });         // fan-out by enumeration
```

`request.session.id` is always a string when the handler was invoked by a browser request (eager mint). For handlers invoked outside a browser context (webhook callbacks, signup, system maintenance), `request.session === null` and the implicit-target form throws — explicit `to:` required.

Cross-session fan-out is the customer's job: they keep their own subscription map (`subs/{post_id}/{sid}`) and iterate on emit. The platform deliberately doesn't ship a topics / rooms / channels abstraction — every chat-app vendor reinvents it differently, and the customer's subscription model usually needs domain shape (per-post, per-team) anyway.

#### Storage

`_events/{sid}/{request_id}-{call_index}` rows in customer's `app.db`, written inside the handler's transaction. Per-session monotonic by `request_id` (already monotonic per `src/log/root.zig`). The composite seq is the SSE `id:` field. Replay determinism inherits from §2.6.

#### Connection endpoint

```
GET /_events                  → text/event-stream; honors Last-Event-ID
GET /_events?since=<id>       → query-string variant for non-EventSource clients
```

Reads `_rove_sess` cookie; mints + sets if absent. Wire format: standard SSE. Keepalive `:ping\n\n` every 25s to survive proxies. On disconnect, subscription cleared from the worker's connection table; `_events/...` rows persist until retention GC.

#### Pump (in js-worker)

Per-tenant subscription map keyed by session id. On every commit that touches `_events/{sid}/...`, mark corresponding connections dirty; pump cycle reads new events (`> last_sent_id`), writes to wire, advances `last_sent_id`. Single-node v1; multi-node deferred (same call as the webhook drainer's leader-only model, OR session→node registry — decide when multi-node lands).

#### Caps (plan-tier, single-struct interface)

```zig
pub const EventsCaps = struct {
    max_concurrent_connections_per_instance: u32,
    max_concurrent_connections_per_session: u32,
    max_emits_per_request: u32,
    retention_seconds: u32,
    max_events_per_session_in_retention: u32,
    max_event_payload_bytes: u32,
};
pub fn eventsCapsForPlan(plan: tenant.PlanTier) EventsCaps;
```

Starting numbers:

| Cap | Free | Paid | Notes |
|---|---|---|---|
| Concurrent SSE connections / instance | 100 | 10,000 | Real resource cap |
| Concurrent SSE connections / session | 16 | 16 | Multi-tab sanity guard, not plan-tiered |
| Emits per request | 100 | 1,000 | Mirrors webhook outbox depth |
| Retention window | 300s | 3,600s | Last-Event-ID resume window |
| Events / session in retention | 100 | 1,000 | Slow-consumer defense |
| Event payload bytes | 64 KB | 256 KB | Inherits kv value cap as floor |

Same `*CapsForPlan(plan)` shape extends to other plan-tiered caps as we add them (KV storage, file size, etc.) — one function per subsystem, one struct of fields, easy to grow.

#### Authorization

Cookie IS the auth. HttpOnly + SameSite=Lax means client JS can't steal it cross-origin and the browser sends it automatically. Customer's responsibility to bind session to a user (via their `/login` handler writing `sessions/{sid}/user = X`) and to refuse to emit to sessions that aren't authorized. No connect-time customer auth handler in v1; add `_events/auth.mjs` convention if revocation demand emerges.

#### Draft mode + tape

`?__draft=` deploys route events to a sandbox bucket, never delivered, visible in dashboard. Tape capture is free — `events.emit` is a KV write, the existing tape covers it.

#### Rove ECS design (must precede implementation per `rove-design-first`)

New collection in js-worker: `events_connections`. Components: `EventsSession { sid }`, `EventsLastEventId { id }`, plus standard h2 stream/session components. Lifecycle: SSE connect → entity created → pump system iterates → disconnect → entity destroyed (component deinit clears subscription). New system: `pumpEvents`, pure function iterating `events_connections`, called between `poll()` and `reg.flush()` like other systems. Detailed Row design + dirty-marking happens at code time.

#### Deferred

- Multi-node session routing.
- Customer-defined `_events/auth.mjs` connect-time auth.
- Topic/room/channel abstraction.
- Per-message client acknowledgment (would require WS).
- Binary message types (SSE is text-only).

## 3. Build plan (ordered phases)

**Cross-cutting for every phase**:
- `deployment_id` on all request logs.
- Raft apply hook for cache invalidation.
- Shared path-validation module across upload APIs.
- Logger nesting for triggers/webhooks/callbacks under parent `request_id`.
- All admin API paths versioned `/v1/` from day one.

### Phase 1 — Domain infrastructure

- Register `loop46.me`.
- DNS: apex + wildcard `*.loop46.me` pointed at server IP, proxied through Cloudflare.
- Wildcard LE cert via `scripts/rove-lego-renew.sh` (ACME DNS-01). rove-js reads `cert.pem`/`key.pem` directly and terminates TLS in-process; Cloudflare fronts with Full/Strict.
- Host routing lives in the worker (`*.loop46.me` + `app.loop46.me` both hit js-worker; dispatcher splits by host). No reverse proxy.
- Response layer: sanitize `Set-Cookie` `Domain=` attribute (strip).  **Done**: `sanitizeSetCookie` in `src/js/dispatcher.zig:819`, applied in `extractResponseMetadata` on every JS handler response. Covered by 9 inline tests.
- `rove-tenant` wildcard domain resolution — accept any `*.loop46.me` matching a registered instance id.
- PSL submission (`loop46.me` → `publicsuffix/list`) **deferred to Phase 10**. Server-side Domain stripping above is the authoritative defense; PSL is defense-in-depth at the browser level and its propagation lag makes it unsuitable for the launch path.

### Phase 2 — File API + static serving

- Extend `rove-files` for `_static/` prefix (raw bytes, no compile, content-type in manifest).
- Routing rule in dispatcher: static-first with full fallback order (see 2.4).
- Shared path-validation module.
- ETag + `If-None-Match` → 304 on static.
- Deploy API: single-file (`PUT/DELETE /files/<path>`), bulk (`POST /blobs/check` + `PUT /blobs/<hash>` + `POST /deployments`).
- Draft track with CAS. `POST /deployments/{id}/activate`. Deploy history + diff.
- Compile-on-save: `POST /lint`.
- File + deploy-size caps, plan-tier configurable.
- Retention: last 50 + last 7 days; blob GC.

### Phase 3 — Webhooks + email

- Outbox schema (`_outbox/*`, `_outbox_inflight/*`, `_dlq/*`) in instance `app.db`.
- HTTP client: SSRF blocklist, TLS always, redirect cap, timeouts.
- HMAC signing with per-instance webhook secret (auto-provisioned on instance create).
- Drainer on raft leader (lease-based). Exponential backoff + full jitter.
- Callback invocation as a handler event in its own transaction.
- `email.send` wraps `webhook.send` with platform SMTP creds.
- Observability: log each attempt, dashboard queue/inflight/DLQ views.
- **SMTP provider decision** (SES / Postmark / Resend) must be made before this phase kicks off.

### Phase 4 — Signup + auth

- Magic-link primitive: `_magic/{hash}` in root.db, 30-min TTL, single-use.
- Session cookie: opaque token, revocable, stored in root.db.
- `POST /v1/signup`: validate, **reserve the name** via `pending/{name}` in admin app.db, mint magic, enqueue magic-link email — does **not** allocate the customer tenant yet (abuse-prevention amendment, see below).
- `GET /v1/auth?mt=...`: validate, **create instance + deploy starter content as part of redemption**, mint session, 302 to dashboard.
- `POST /v1/logout`: clear cookie, revoke session.
- Starter content: one `index.mjs` (uses `kv`, returns JSON), one `_static/index.html` that fetches it and shows "your API is live at `{name}.loop46.me`".
- **Lazy-creation-on-redeem (abuse prevention).** The customer tenant is *not* created at signup — only a `pending/{name}` reservation in admin app.db. Tenant creation, root_writeset propose, and starter-content deploy all happen inside `redeemMagic`, atomically with the session mint. A periodic sweep deletes expired `pending/*` entries to free the name. Without this, an unredeemed signup squats the name and leaks `{id}/app.db`, `{id}/files.db`, and the file-blob directory indefinitely. Detailed flow in [`docs/flows/signup.md`](flows/signup.md).
- **Per-account instance limit.** Email is the account identity. New `account/{sha256(email)}/...` namespace in admin app.db owns the plan tier (`account/{hash}/plan`) and the instance ownership index (`account/{hash}/instances/{instance_id}`). Signup-time check counts owned instances *plus* non-expired `pending/*` reservations against the account's `max_instances` — both count, otherwise the free tier is trivially evadable by squatting names via incomplete signups. Same check repeats at redeem-time as the authoritative gate (two simultaneous signups by one email could both pass at signup time; only the second to redeem hits the limit). v1 hardcodes `max_instances = 1` for free; Phase 10 wires the value from a per-tier config keyed on `account/{hash}/plan`. Seed-manifest tenants stay outside the account model entirely — operator-provisioned, no associated email, no `account/*` record. The same `account/{hash}/plan` lookup will eventually drive *all* per-account caps (request/email rate limits, DLQ retention, blob storage caps, custom-domain counts, plus Stripe customer linkage in Phase 10).

### Phase 5 — Minimal admin UI

- Deploy admin UI to `app.loop46.me` **using Phase 2's file API**. Dogfood.
- Pages: signup/login, dashboard home, instance detail with tabs (Code, KV, Logs, Deploys).
- CodeMirror 6 in Code tab. Save-draft + Deploy buttons.
- Deploy history with diff view.
- Logs tab uses existing `rove-log` surface; add `deployment_id` display.
- **First customer can now sign up, deploy, see it live, debug.**

### Phase 5.5 — Storage scalability for production load (MVP boundary)

Production-blocking. Without this, every observability record rides the raft
log, request/response bodies (once captured) would too, and `raft.log.db`
grows without bound. Back-of-envelope at ~500 bytes per log record × 1000
req/s × one tenant: ~43 GB/day into `raft.log.db` alone, doubled by the
per-tenant `log.db` apply. Captured bodies make this ~100× worse if they
land in raft. The cluster lasts days or weeks before disk pressure forces
ops intervention.

Three coupled work items, all following the existing file-blob pattern
(bytes on `BlobStore`, raft replicates only the manifest):

1. **Log batch payload offload to blob store.** Today the raft entry payload
   IS the batch bytes (see the now-stale "Phase 6" comment in
   `src/log/root.zig` header). Change so the leader writes the drained
   batch to its `BlobStore` (already used for files), and the raft entry
   carries `{tenant_id, batch_hash, manifest}`. Apply on followers fetches
   the blob via the shared backend (`FilesystemBlobStore` for single-host,
   `S3BlobStore` for multi-node). Propose gated on blob-write completion
   so applies are referentially valid — same constraint file blobs already
   honor today.

2. **Tape body capture (request + response).** Infrastructure pre-staged:
   `tape_refs` slot on `LogRecord`, `BlobStore` field on `LogStore`, 256 KB
   default truncation cap from §2.4. Wire it. Bodies go straight to the
   per-tenant blob backend (`{inst.dir}/log-blobs/`); only the hash + meta
   lands in the log record. Truncation marker preserved across replay so
   the simulator (Phase 12) sees the same bytes.

3. **Raft snapshot + log compaction.** `willemt/raft` has the snapshot hooks
   but no integration in `src/kv/raft_*`. Snapshot trigger on size threshold
   of `raft.log.db`; prune committed entries behind it. Single-node-only is
   fine for v1 (snapshot lives next to the raft log); multi-node snapshot
   transfer deferred to the multi-node milestone alongside `S3BlobStore`.

4. **Centralized webhook subsystem.** Today `drainOnce`
   (`src/outbox/drainer.zig:137`) snapshots the entire instance set every
   tick and opens a fresh SQLite connection per tenant for an `_outbox/*`
   prefix scan — ~40k SQLite open+scan ops/sec at 4 ticks × 10k tenants,
   almost all empty. Replace with a webhook subsystem structurally
   analogous to files-server / log-server: single node-scoped database
   `{data_dir}/_webhooks.db` owns all pending/inflight/DLQ state across
   every tenant; drainer reads from one DB, not N.

   **Handover.** Apply hook on writeset commit: any `_outbox/*` keys
   trigger `webhook_subsystem.enqueue(id, payload)` into `_webhooks.db`.
   Enqueue is keyed by `id` (the existing 64-hex outbox suffix) and
   idempotent — second call with same id is a no-op. After successful
   delivery, the subsystem proposes a writeset on the source tenant
   deleting `_outbox/{id}`. Tenant app.db stays clean in steady state.
   Idempotency makes the handover eventually consistent rather than
   transactional (SQLite can't span a transaction across two `.db` files
   under our connection model anyway), which means a crash between
   commit-and-enqueue is safe: recovery re-enqueues, dedup no-ops where
   needed, no data loss and no double-send. Receivers already dedup on
   `X-Rove-Webhook-Id` per the at-least-once contract.

   **`_webhooks.db` is leader-local in v1** (not raft-replicated). A new
   envelope type would be cleaner architecturally but adds apply paths
   and more code surface; idempotent recovery makes raft replication
   unnecessary for correctness. Promote when multi-node failover latency
   forces the decision.

   **Failover/startup recovery cost — flagged as the v1 tradeoff.**
   Without raft replication, a new leader (after election OR fresh
   start) must scan every tenant app.db's `_outbox/*` once to enqueue
   anything that wasn't drained before the transition. At 10k tenants
   that's ~10k SQLite opens + prefix-scans during recovery, almost all
   returning empty — linear in fleet size, and it can dominate failover
   latency at scale. The same per-tenant-scan cost the steady-state
   path is being designed to avoid moves to the recovery path. Mitigations,
   in increasing cost: (a) parallelize the scan across the existing
   worker thread pool — cheap, do by default; (b) maintain a
   leader-local persistent index of "tenants with non-zero outbox" in
   admin app.db so the new leader only opens those tenants — adds an
   apply-side write per outbox enqueue but bounds recovery to active
   tenants; (c) promote `_webhooks.db` to a raft target so failover is
   just leader-promotion with no scan at all. Land (a) by default;
   measure before committing to (b) or (c).

`S3BlobStore` itself stays deferred (single-host launch uses
`FilesystemBlobStore`); the work above is ready for it because `BlobStore`
is already the abstraction seam. **First customer can now take real
production traffic without disk-fill within weeks.** MVP complete.

### Phase 6 — Triggers

- Load `_triggers/*.mjs` into a per-instance prefix trie at deployment-load time.
- `rove-kv` transaction wrapping: before/after trigger dispatch on `put` and `delete`.
- Cascade with depth limit (8). Platform-prefix guard.
- Tape replay auto-re-fires triggers (free from kv op capture).
- Dashboard: Triggers tab. Fire counts, error rates, recent invocations nested under parent request.

### Phase 7 — CLI

- `loop46 deploy`: walk dir, hash, check, upload missing, commit manifest.
- `loop46.json` parsing.
- Deploy-token issuance UI in dashboard (one-time plaintext print).
- Later commands deferred.

### Phase 8 — Rate limiter primitive

- Token-bucket data structure per `(instance, action)`.
- Configured on instance record; per-plan defaults.
- Applied at request dispatch, deploy, email send, each webhook attempt, kv writes (optional).
- Dashboard: per-instance bucket state.

### Phase 9 — Encryption at rest

- Master-key loader (file + env var).
- Per-instance HKDF derivations (distinct labels per subsystem).
- **SQLite page encryption — vendored AES-GCM VFS (preferred) vs SQLCipher (decide in this phase)**.
- Blob encryption paths.
- Tape encryption.
- Key-rotation format stamped with version byte; rotation tooling deferred.

### Phase 10 — Custom domains + polish

- Customer CNAME `api.myapp.com` → `foo.loop46.me`.
- Per-custom-domain Let's Encrypt cert provisioning. Watch ACME rate limits at signup surges.
- Domain assignment UI in dashboard.
- Plan tiers wired to all per-account caps via the `account/{sha256(email)}/plan` namespace introduced in Phase 4. Single lookup drives `max_instances` (Phase 4 hardcode goes away), `request` / `email` rate-limit caps, DLQ retention, blob storage caps, custom-domain counts, and Stripe customer-id linkage below.
- Billing hookup (Stripe) — implement via `webhook.send` + callbacks to dogfood the outbox. Customer id stored at `account/{hash}/stripe_customer_id`.
- **PSL submission** for `loop46.me` (GitHub PR to `publicsuffix/list`). Fire-and-wait; propagation can take weeks-to-months across browser releases. Defense-in-depth only — server-side `Set-Cookie Domain=` stripping from Phase 1 is the authoritative guard.

### Phase 11 — Server-sent events (§2.12)

- `_rove_sess` cookie: 64-hex-char opaque token, HttpOnly + Secure + SameSite=Lax. Eager mint on handler invocations that arrive without one; `Set-Cookie` added on response. Static asset serving short-circuits before mint.
- `request.session: { id }` global. Null when handler invoked outside browser context (callbacks, signup, system).
- `events.emit(...)` JS global. Implicit-target form (no `to:`) routes to current session; explicit `to: sid | [sid, ...]` for fan-out.
- `_events/{sid}/{request_id}-{call_index}` storage in customer's `app.db`, written inside handler tx.
- `GET /_events` system endpoint: text/event-stream, honors `Last-Event-ID`, mints+sets cookie if absent. Keepalive `:ping\n\n` every 25s.
- Pump in `js-worker`: per-tenant subscription map keyed by sid, dirty-flag on commits touching `_events/`, drains to wire.
- `EventsCaps` struct + `eventsCapsForPlan(plan)` lookup — same shape used for future plan-tiered caps in other subsystems.
- Single-node only. Multi-node session routing deferred (decide when multi-node lands; same call as the webhook drainer's leader-only model OR a session→node registry).
- Has no hard predecessor — depends on §2.6 webhooks (done) + existing kv/h2/handler infra. Position in the phase list reflects "non-blocking for first-customer launch"; could be pulled forward into the MVP if SSE turns out to be a hot demo feature.

### Phase 12 — Sim test framework + simulator library (§10.7, §10.8)

Client-side simulator library + deterministic handler test framework. Worker has no simulator role. Independently shippable: customers get sim tests on day one with no live-state dependency.

- New module `src/simulator/` (CLI library only): `root.zig` + `replay_source.zig` + `bytecode_cache.zig` + small `compile.zig`. **No `thread.zig`, no `main.zig` stub** — there's no worker hosting and no separate binary in v1.
- `ReplaySource` with composable layers: write buffer / overlay / tape / miss policy. Modes (`strict`, `what_if`, `isolated`) are layer combinations.
- Dependency surface excludes `rove-kv` (no SQLite in the simulator).
- New CLI subcommand `loop46 simulate` exposes the simulator library directly: synthetic request + kv overlay + mode flag → bundle on stdout.
- Bundle JSON module extracted from `examples/log_cli.zig` into `src/tape/bundle.zig`.
- Bundle JSON additions: cross-channel `seq` ordering, structured stack frames, value previews, structured console, `replay_available`. New `tape_entries` field for inline tapes (used by §10.11 dry-run bundles).
- Module tape wiring at `JS_ResolveModule` — `appendModule` infrastructure exists in `src/tape/root.zig` but has no caller. Needed for multi-file determinism.
- Test framework (§10.8): `_tests/` directory + `loop46 test` CLI subcommand embedding QuickJS for test code execution outside the handler sandbox. Sim tests run **fully locally** from the working tree.
- Snapshot machinery (`_tests/__snapshots__/{name}.json`, `--update-snapshots`).
- `loop46_export_fixture` writes sibling-file pairs (`_tests/from-prod-{id}.mjs` + `_tests/__fixtures__/from-prod-{id}.json`) so fixtures stay offline-runnable.
- Production-strip of `_tests/` — test files live in dev repo only.
- Request body capture into the tape (new request-input channel) — needed for fixtures and replays to faithfully reproduce POST bodies.
- Stale-comment cleanup at `src/log/root.zig:71`.

**No server endpoints in this phase.** No `simulate` rate-limit action, no `/_system/simulate/{id}` route, no thread pool in worker. The worker is unchanged.

Detailed plan: `docs/sim-test-framework.md`.

### Phase 13 — Fixture lifecycle + worker dry-run (§10.9, §10.11)

Tooling for authoring, editing, and refreshing the fixture data sim tests run against — plus the worker-side dry-run dispatch mode that lets customers capture realistic tapes from synthetic requests without persistence.

**Fixture lifecycle** (§10.9):
- `/_system/kv/{id}/*` admin endpoint (read-only, paginated): `get/{key}`, `?prefix=...&limit=N&after=<key>`, `count?prefix=...`.
- New CLI subcommand `loop46 kv` (`get`, `list-prefix`, `count`).
- New CLI subcommand `loop46 fixture` family: `from-keys`, `add`, `remove`, `edit`, `diff`, `refresh`, `merge`.
- Runner integration: structured "unresolved read on K" error referencing fixture path + missing key. Optional `loop46 test --auto-fix-from <instance>` flag pulls missing keys on-the-fly and writes them back.

**Worker dry-run** (§10.11):
- `POST /_system/dry-run/{id}` endpoint — runs synthetic request through dispatch with always-rollback + propose-disabled. Returns bundle (response, kv writes, outbox rows, tape entries) inline; nothing persists.
- Implementation: `dry_run: bool` flag on `dispatchOnce`. Roughly 50 lines.
- Optional `dry_run` rate-limit action (default: share `request` budget).
- New CLI subcommand `loop46 dry-run --request '{...}' --instance <id>`.
- Composite tool: `loop46 fixture from-dry-run --request '{...}' --instance <id> -o <fixture.json>` runs dry-run, extracts the kv tape, writes a fixture file. Single command, end-to-end fixture authoring from a synthetic request.

**Web UI follow-on** (deferred; lands alongside Phase 5 admin UI maturity): "Fixtures" tab in dashboard with same affordances over the same backend endpoints.

Detailed plan: `docs/fixture-lifecycle.md`.

### Phase 14 — AI agent surface (§10.10)

Skill file + CLI polish + scoped tokens. **No MCP server in v1.** Hosted MCP deferred until concrete remote-agent demand surfaces. The local agent path (Claude Code in customer's working tree) is fully served by CLI + skill file.

- `docs/skills/loop46.md` — canonical skill file for Claude Code (and similar agents). Teaches the workflow, tool catalog, common patterns, gotchas.
- `--json` output mode audit on every CLI subcommand.
- New CLI subcommand `loop46 doctor` — environment + connectivity readiness check; first-thing-an-agent-runs.
- Scoped tokens — new token type at `scoped_token/{sha256_hex}` in root.db. Carries a capability subset (`read`, `simulate`, `deploy`, `fixture`, `kv`, etc.) and instance scope. Independent of MCP; security primitive worth having for any agent integration. Mint via dashboard or `loop46 mint-token --capabilities ...`.
- `/_system/scoped_tokens` admin routes (mint/list/revoke).
- Dashboard "Tokens" tab.

What's deferred (not in v1): hosted HTTP MCP at `mcp.loop46.me`, `loop46-mcp` binary, MCP wire-format code. Build when a real remote-agent use case shows up.

Detailed plan: `docs/agent-surface.md`.

## 4. Deferred to v2

These are explicitly not in v1 so future sessions don't accidentally design around them.

- Fan-in aggregation for webhooks (multiple → one callback).
- Async / fire-and-forget webhooks (no callback).
- Circuit breaker per destination URL.
- Per-destination rate shaping.
- Read triggers (`beforeGet` / `afterGet`). The path-based registration model (§2.5) accommodates them naturally — same file layout, named exports just expand. Held back because read triggers fire on every `kv.get` (rather than only writes, which are rare), turning every read into a registry scan + potential JS dispatch. The cost story isn't established yet; revisit when a real customer asks.
- Dedicated `batch.*` task primitive. Background drainer that runs a JS module over a kv prefix in batches with progress tracking, cascade-during-batch policy, plan-tier rate limits, programmatic poll semantics, etc. Motivating use cases: index rebuild after a trigger change, schema migration (transform every value), bulk re-encrypt, audit/report jobs. Held back because v1 covers the common case (index rebuild) via the self-webhook chain pattern documented in §2.5 — fresh 10ms budget per link, standard retry/DLQ for failures, no new platform surface. Revisit when a customer asks for "click button → rebuild index" UX, or when schema migration becomes painful enough that customers complain about composing it from the chain primitive.
- Cross-instance triggers.
- Scheduled / cron execution (falls out of outbox with `nextAttemptAt` when needed).
- Streaming response bodies; Range requests for static.
- HMR / live-reload websocket in editor.
- Pre-compressed blob storage (gzip/br) — rely on Cloudflare for compression.
- Cancellation API (`webhook.cancel(id)`).
- BYOSMTP for paid tiers.
- Redacted-tape export for external sharing.
- Local dev CLI (`loop46 dev` mini-rove for offline testing).
- Symlinks / aliases / redirects (rules.json).
- Private blobs that handlers read but URL doesn't serve — if needed, use `_static/_private/*` convention.
- Runtime external imports (esm.sh at handler runtime).
- "Mark secret key as dots in dashboard" affordance.

## 5. Items to confirm before their phase

Resolved items moved to §10. Open items:

- **Phase 9 (encryption)**: commit to SQLCipher vs vendored VFS. Audit implications differ.
- **Phase 10 (custom domains)**: ACME rate-limit strategy for a signup surge.
- **Phase 5 (admin UI hosting)**: Cloudflare Pages vs rove-hosted dogfood for the admin UI static bundle in production. Dogfood is more honest; Cloudflare is lower risk for launch.
- **Blob backend for multi-node** (new, §10 detail): shared filesystem mount vs `S3BlobStore` + SigV4 signer. Single-node launch doesn't need either; multi-node launch needs one.

## 6. Relevant existing code

- `src/files/root.zig:14` — content-addressed manifest + blob scheme; Phase 2 extends this.
- `src/files/root.zig:73` — `MAX_PATH_LEN = 192`; reused in path validation.
- `src/tenant/root.zig:459` — `__admin__` KV aliases to root.db. Pivot may keep, repurpose, or deprecate; re-evaluate in Phase 5.
- `src/tenant/root.zig:518` — root-token hash scheme; pattern reused for magic-link tokens (`_magic/{hash}`, 15-min TTL).
- `src/js/worker.zig` — QuickJS snapshot-restore per-request; trigger and callback invocations reuse this.
- `vendor/README.md` — dependency posture (no network installs, everything vendored). Informs Phase 9 SQLCipher-vs-VFS decision.
- `web/admin/` — existing admin UI skeleton. Will be largely rewritten in Phase 5 against the new auth + file API.

## 7. Superseded decisions (do not re-propose)

The following were explored during the 2026-04-17 design conversation and ruled out. Captured here so future sessions don't re-derive them.

- **`admin.loop46.com` + bearer tokens** as the admin UI origin. Rejected: wanted to dogfood the customer auth path, and bearer tokens force customers into `headers: Authorization` plumbing.
- **`{name}.api.loop46.com` + `site.loop46.com` (PSL)** for separate static/API origins. Rejected: PSL propagation is a launch blocker, and per-customer wildcard TLS for two-label-deep API hosts is operational pain. Single origin per tenant with path routing is simpler.
- **Admin UI served by the root JS instance.** Rejected: violates dogfooding — we should host the admin UI the same way a customer hosts theirs (static bundle + cross-origin to its API is actually not needed here either, since same-origin on `app.loop46.me`).
- **Write-only `env` / secrets primitive.** Rejected: ceremony without defense (handler code can exfiltrate any value it can read). Replaced by page-level encryption for all KV.
- **Value-level encryption for secrets.** Rejected: unified page-level encryption covers more surface with one code path.
- **Redact env values from replay tapes.** Rejected: breaks determinism (downstream captures derive from env values, can't be recomputed). Replaced by encrypting tapes at rest and access-gating admin reads.
- **Cookie-based auth for C2 API calls by default.** Rejected for customers whose UI is on a third-party host — Safari ITP eats third-party cookies. Same-origin on `{name}.loop46.me` via path routing recovers the cookie path for the default layout; bearer tokens remain as a third-party-host fallback.
- **Admin UI auto-detecting `.ejs` / `.ts` file extensions and running a built-in transform** (as shift-js did). Rejected: platform-not-framework. Transforms are libraries customers import, not platform primitives.
- **Synthetic "deploy" event in the request log stream.** Rejected: misleading across the transition window. Per-request `deployment_id` tagging is accurate and more useful.
- **Per-worker polling of `deployment/current` for cache invalidation.** Rejected: doesn't scale to thousands of instances. Raft apply hook is the correct notification channel.
- **Strict FIFO ordering guarantees for webhooks.** Rejected: impossible to deliver meaningfully across destinations with different latencies; customers who need ordering chain via callbacks.
- **Fan-in of multiple webhooks into one callback.** Rejected for v1. Customers build saga patterns by hand with triggers/callback-chaining.
- **Auto-resend on expired-but-recent magic-link click** (15-min validity + 15-min grace window with `resend_grace_until_ns`, `magic_resend` rate-limit action, "we sent a fresh link" UI page). Rejected: trades a friendly page for an extra email round-trip that's strictly worse than just bumping the magic TTL. Replaced by 30-minute flat validity + an `email` URL hint on the signup form pre-fill for the 401-page case. Also avoids a name-squat amplification in the original design — the resend chain renews `pending/{name}` lifecycle, letting one signup hold a name for hours within the 3/hr per-email rate limit; flat TTL caps the reservation at 30 min.

## 8. Why this is a compelling product

The uniqueness isn't any single feature — it's the coherence of the set:

- **Purely functional handlers** (no async IO, no fetch, all effects are Cmds).
- **Transactional outbox as the only outbound path.**
- **Deterministic triggers in the same KV transaction as the write.**
- **Tape capture on every request, encrypted at rest.**
- **Browser-based replay with DevTools breakpoints on production bugs.**
- **One URL for the whole app (static + API + admin-of-admin).**
- **Magic-link signup → live API in under a minute.**

Nobody is offering this combination. The marketing headline is the functional core + replay; the developer hook is the one-minute demo. The rest of the plan is making both of those true.

## 9. Implementation status (2026-04-21)

A long build session between 2026-04-17 and 2026-04-21 shipped Phases 1–4 almost entirely and restructured a few architectural decisions (flagged in §10). Current status against the §3 phase list:

### Phase 1 — Domain infrastructure
- Wildcard DNS, Let's Encrypt, `rove-lego-renew.sh`, Cloudflare Full/Strict — **operator work, gated on domain registration**
- `sanitizeSetCookie` + 9 inline tests — **done**
- Wildcard tenant resolution — **done** (`--public-suffix` CLI flag → `tenant.resolveDomain`)
- PSL submission — deferred to Phase 10 as planned

### Phase 2 — File API + static serving — **done**
- `_static/<path>` prefix, kind+content-type in manifest
- Static-first dispatch with fallback order (see §2.4)
- ETag + 304
- Single-file `PUT /v1/instances/{id}/file/{path}` (upload-and-deploy)
- Content-addressed two-phase deploy: `POST /blobs/check`, `PUT /blobs/{hash}`, `POST /deployments` with `parent_id` CAS — **done, FS backend**
- Admin JS client helpers for the two-phase flow (`api.bulkDeploy`) — **done**
- NOT yet: draft-with-CAS workflow, `POST /lint`, deploy history/diff UI, deploy-size caps, retention/GC. Deferred into Phase 5 finish.

### Phase 3 — Webhooks + email — **done**
- `_outbox/*`, `_outbox_inflight/*`, `_dlq/*`, lease-based drainer
- SSRF blocklist + HTTP client + exponential backoff with full jitter
- `webhook.send` JS global with deterministic outbox ids (`sha256(request_id || call_index)`)
- `email.send` JS wrapper (key as explicit arg — vendor-neutral; see §10)
- `crypto.hmacSha256(key, data)` primitive — customers roll vendor-specific signatures themselves
- `X-Rove-Webhook-Id` + `X-Rove-Webhook-Attempt` headers stamped; the planned `X-Rove-Signature` was dropped per §10
- Callback dispatch phase (`dispatchCallbacks`) invokes `onResult` handlers in their own tx
- Inflight lease + stale-lease sweep covers drainer crash recovery
- End-to-end smoke in `scripts/webhook_smoke.sh` against a Python echo target

### Phase 4 — Signup + auth — **done** (modulo deferred sweep)
- `mintMagic` / `redeemMagic` primitive (15-min TTL, single-use, hashed-at-rest) — **done**
- `POST /v1/signup`: validates name (reserved list + uniqueness) + email, mints magic, queues signup email via outbox — **done** (lazy: writes pending/{name}, doesn't allocate the tenant — see amendment below)
- `GET /v1/auth?mt=...`: redeems, creates session, 302 to `/#/{name}` with HttpOnly+Secure+SameSite=Lax cookie — **done**
- `POST /v1/login` (direct-token) + `POST /v1/logout` — cookie auth — **done**
- Starter content (`index.mjs` + `_static/index.html`) deploys at redemption time through the files writeset — **done** (moved from signup-time per the amendment below)
- Smoke in `scripts/signup_smoke.sh` covers every branch including CAS, replay rejection, Resend-key vs dev-fallback paths — **done**
- **DONE — lazy-creation-on-redeem + admin-handler port to JS (2026-04-30).** Two coupled amendments folded into one work item — they touched the same handlers, and porting Zig that was about to be rewritten anyway was wasted churn. **(a) Lazy creation:** signup writes only `pending/{name}` → `{email, expires_at_ns, magic_hash_hex}` in admin app.db; duplicate check covers both `instance/*` and non-expired `pending/*`; outbox row for the magic email lives in admin app.db; redemption is where instance creation, root_writeset propose, starter deploy, files_writeset propose, `pending/*` cleanup, and session mint all happen. Magic TTL bumped to 30 minutes (was 15) so click-late users land on the happy path; pending shares the same TTL. **(b) Zig→JS handler port:** `/v1/signup`, `/v1/auth`, `/v1/login`, `/v1/logout`, `/v1/session` plus admin's RPC auth all run as JS in admin's deployed bundle. The whole `handleAdmin*` family in `worker.zig` and the `mintMagic`/`redeemMagic`/`createSession`/`authenticateSession` family in `tenant/root.zig` deleted. Auth gating lives in `_middlewares/index.mjs`. Three new JS primitives: `platform.instances.create(name)` / `.deployStarter(name)`, `crypto.randomBytes(n)` + `crypto.sha256(data)` (extending the existing `crypto.hmacSha256` namespace), plus `request.host` and the `_middlewares` mechanism itself. **Deferred:** periodic sweep over `pending/*` + `magic/*` past `expires_at_ns`. Functionality works without it — every access path lazy-expires stale rows (`handleSignup`'s pending-dup check, `handleAuth`'s magic-redeem expiry check, `countAccountUsage`'s pending filter). Storage growth is the only concern; revisit when admin's app.db row count starts mattering. Detailed flow in [`docs/flows/signup.md`](flows/signup.md).
- **DONE — per-account instance limit (2026-04-30).** Email is the account identity. `account/{sha256(email)}/plan` stores the tier; `account/{hash}/instances/{instance_id}` marks ownership. Signup-time check (`countAccountUsage` in admin's bundle) counts `account/{hash}/instances/*` + this email's non-expired `pending/*` against `max_instances` from the plan tier; rejects 403 with `{error:"account_limit_reached", limit, owned, pending}` when over. Redeem-time recheck is the authoritative gate against simultaneous-signup races. v1 hardcodes `PLAN_LIMITS.free.max_instances = 1` in admin's bundle; Phase 10 wires the value from a tier-keyed config. Seed-manifest tenants stay outside the account model — no email, no `account/*` row, no count toward any limit. The same `account/{hash}/plan` lookup becomes the seam for all Phase 10 per-account caps (rate limits, DLQ retention, blob caps, custom-domain counts, Stripe linkage). signup_smoke covers pending-state limit + owned-state limit + the per-account-not-global property (different email accepted).

### Phase 5 — Minimal admin UI — **partial**
- Pages: login, dashboard home, instance detail with Logs + KV + Code tabs — **done**
- Cookie-based auth, `X-Rove-Scope` header for cross-tenant admin access — **done**
- Two-phase deploy client helpers (`api.bulkDeploy`) — **done**
- Logs tab: newest-first table (time / **deploy** / method / path / status / duration / outcome), click-row drawer with full record incl. console + exception, refresh button, count, **Load older button with cursor pagination** — **done**
- Log pagination: `LogStore.list` accepts `after: u64` (a `request_id`); `ListResult` returns `next_cursor: u64`. Wire endpoint `/_system/log/{id}/list?limit=N&after=<hex>` returns `{records: [...], next_cursor: "<hex>" | null}`. Admin UI tracks the cursor and appends pages on Load older — **done 2026-04-27**
- NOT yet: Logs auto-refresh / live tail, Logs filtering (by status / outcome / deployment / path), nested-thread display under `parent_request_id` (waits on Phase 6 trigger / callback log emits), Deploys tab with history + diff, CodeMirror 6 upgrade, draft workflow, signup form on the login page, tape replay click-through (waits on Phase 4 tape capture)

### Phase 5.5 — Storage scalability — **not started**
- Promoted into MVP scope 2026-04-29 (this revision). Four deliverables: (a) log batch payload offload to BlobStore — leader writes batch blob, raft entry carries `{tenant_id, batch_hash, manifest}` only, propose gated on blob-write completion, apply fetches blob from the shared backend; (b) tape body capture wired through the pre-staged `tape_refs` + `LogStore.blob` slots, bodies offloaded to `{inst.dir}/log-blobs/` with §2.4's 256 KB truncation; (c) raft snapshot + log compaction integration via `willemt/raft`'s existing hooks, single-node only in v1; (d) centralized webhook subsystem with leader-local `_webhooks.db` and idempotent enqueue, replacing the per-tenant scan in `outbox/drainer.zig`.
- Without (a)–(c), `raft.log.db` grows unbounded under any sustained traffic and bodies (when added) overwhelm both raft replication and per-tenant `log.db`. Estimate: ~43 GB/day in raft.log.db at 1000 req/s × ~500 B per log record, doubled by apply, ~100× worse with bodies.
- Without (d), the drainer's steady-state tick cost is O(N tenants) — ~40k SQLite open+scan ops/sec at 4 ticks × 10k tenants. The subsystem move-to-`_webhooks.db` design (see §3 Phase 5.5) eliminates the per-tick scan; idempotency on the handover key (the existing 64-hex outbox id) keeps recovery safe across crashes and failover. **Tradeoff: leader-local `_webhooks.db` means a new leader must scan every tenant app.db `_outbox/*` once during recovery — the same per-tenant-scan cost moves from steady-state to the failover path. Linear in fleet size, can dominate failover latency at scale.** Default mitigation is to parallelize that scan across the worker pool; promote to a persistent "tenants with non-zero outbox" index in admin app.db, or to raft-replicating `_webhooks.db`, only when measurement justifies it.
- The supersede comment in `src/log/root.zig` header that mentions "Phase 6 changes this so the leader uploads the batch blob to S3" is stale terminology — it predates the current PLAN numbering. Cleanup as part of this work.

### Phase 6 — Triggers — **done 2026-04-27**
- Path-based registration (PLAN §2.5): `_triggers/users/sessions/index.mjs` fires on writes to `users/sessions/*`. Tree-traversal order across overlapping prefixes — outermost-first BEFORE, innermost-first AFTER. Catch-all via top-level `_triggers/index.mjs` (prefix `""`).
- Named exports for op×timing: `beforePut`, `afterPut`, `beforeDelete`, `afterDelete`, plus `default` as the catchall.
- BEFORE return-value mutates the written value (string return only; non-string returns leave the value untouched).
- Catchable `Error{ code: "trigger_rejected", message: "<trigger_path>: <original>" }` in the handler. Inner savepoint scopes BEFORE chain + actual write + AFTER chain so a throw anywhere rolls back all three (the audit gotcha is real and tested). Uncaught throws bubble to the §11 handler-exception path → 500.
- Cascade depth tracked on `DispatchState`, throws at 8. Platform-key fire-time guard (defense in depth alongside deploy-load guard) — customer catch-alls don't see writes to `_outbox/`, `_audit/`, etc. Per-request module-namespace cache so trigger top-level state persists across fires within one request.
- 15 inline dispatcher tests cover registry derivation, BEFORE+AFTER chains, op×timing dispatch + default catchall, tree-traversal order, cascade depth (well-bounded + runaway), platform-prefix block, return-value mutation, audit-gotcha rollback, previousValue exposure, trigger_rejected error shape.
- `scripts/triggers_smoke.sh` end-to-end against a live worker: signup → deploy trigger module + handler → exercise via curl → verify reverse-index built, BEFORE mutation lowercased the value, rejection caught with the right code, afterDelete cleaned up.

### Phase 8 — Rate limiter — **done 2026-04-27 (v1 narrow scope)**
- `src/js/limiter.zig`: `TokenBucket` (capacity + refill_per_sec; `tryTake`, `secondsUntil`), `RateLimitCaps` (request + email pairs), `RateLimiter` (per-instance × per-action map, lazy bucket creation, `check`, `retryAfterSeconds`). 11 inline tests cover bucket math + per-instance/per-action isolation + Retry-After hint.
- `request` action: checked at request dispatch in `worker.zig:dispatchOnce` (before `tryServeStatic` so static file requests count too — they consume worker resources). Admin requests bypass entirely. On exhaustion: 429 with `Retry-After: <seconds>` header via `setRateLimitedResponse`.
- `email` action: checked at the entry of the `email.send` JS wrapper via the `__rove_check_email_rate` hidden builtin. On exhaustion: throws `Error{code:"rate_limited", message:"email rate limit exceeded, retry after Ns"}`. Customer can `try { email.send(...) } catch (e)` and react.
- Per-worker, in-memory only — no cross-worker sync in v1. Multi-worker configs effectively give each instance Nx the configured limit; acceptable overshoot at launch scale.
- Single tier in v1 — `WorkerConfig.rate_limit_caps` is operator-tunable via `--rate-limit-{request,email}-{capacity,refill}` CLI flags. Phase 10 will branch on instance plan tier.
- `scripts/rate_limit_smoke.sh` end-to-end: hammer a tenant past `request_capacity` and verify 429 + Retry-After + body explanation; verify per-instance independence (a second tenant stays at full capacity); verify admin requests bypass; deploy a handler that calls `email.send` in a try/catch and verify the 3rd call surfaces `e.code === "rate_limited"`.
- Deferred from PLAN §2.10's full action list: `deploy` (low volume), `webhook_attempt` (already paced via outbox depth + per-destination cap + exponential backoff), `kv_write` (hot path, real per-call cost). Add when concrete demand arises.
- Deferred: per-plan branching, root.db sync for cross-worker coordination, dashboard view of bucket state.

### Phases 7, 9, 10 — **not started**

### Phase 12 — Sim test framework + simulator library — **not started**
- Locked in §10.7 + §10.8 (2026-04-28). Detailed plan in `docs/sim-test-framework.md`. **Pure client-side**: simulator module (`src/simulator/`) library-linked into the `loop46` CLI; `ReplaySource`; bundle module extraction; bundle JSON additions; module tape wiring; request body capture; `_tests/` directory + `loop46 test` and `loop46 simulate` CLI subcommands; snapshot machinery; sibling-file fixture export; production strip of `_tests/`. **No server endpoints, no thread pool, no rate-limit action** — worker is unchanged.

### Phase 13 — Fixture lifecycle + worker dry-run — **not started**
- Locked in §10.9 + §10.11 (2026-04-28). Detailed plan in `docs/fixture-lifecycle.md`. Two related pieces: (1) fixture-lifecycle tools (`/_system/kv/{id}/*` admin endpoint, `loop46 kv`, `loop46 fixture` CLI families, runner `--auto-fix-from`); (2) worker dry-run dispatch mode (`POST /_system/dry-run/{id}` endpoint, `dry_run` flag on `dispatchOnce`, `loop46 dry-run` + `loop46 fixture from-dry-run` CLIs). The dry-run path is ~50 lines added to existing dispatch; fixture lifecycle reuses the same kv admin endpoint that backs dashboard KV browser.

### Phase 14 — AI agent surface — **not started**
- Locked in §10.10 (2026-04-28). Detailed plan in `docs/agent-surface.md`. Pieces: skill file at `docs/skills/loop46.md`, `--json` output audit across CLI, `loop46 doctor` env-check subcommand, scoped tokens at `scoped_token/{hash}` with capability + instance subsets, `/_system/scoped_tokens` admin routes, dashboard "Tokens" tab. **No MCP server in v1** — hosted MCP deferred until remote-agent demand surfaces.

### Future — Browser-side replay (Chrome extension) — not yet phased
- Locked architecturally in §10.12 (2026-04-28). Implementation deferred until Phase 5 admin UI matures and a "click in dashboard → DevTools-style replay" UX becomes the natural next step. Will be a separate repo (Chrome extension toolchain), consuming the bundle JSON + tape blob format from existing server endpoints. No work item in the current phase list.

### Blob replication (multi-node prerequisite)
- Raft envelopes now include `type=3` files_writeset replicating `{id}/files.db` across nodes — **done**
- Blob bytes (`{id}/file-blobs/*`) **still local to the leader**. Multi-node setups need one of:
  - Shared filesystem mount at `{data_dir}` (NFS/EFS/Ceph) — zero code, operator work
  - Future `S3BlobStore` impl in `rove-blob` — not yet written
- Single-node launch is unaffected; multi-node launch is gated on picking one.

## 10. Architecture decisions post-2026-04-17

Architectural calls captured here so future sessions don't re-derive them. §10.1–§10.6 from 2026-04-17 to 2026-04-21; §10.7–§10.12 added and iterated 2026-04-28 (earlier drafts had different §10.9 / §10.11 for trial deploys + live-state acceptance tests; both dropped after design review favored the FP-pure client-side simulator path).

### 10.1 Admin is a real instance with a `platform` capability

**Change**: dropped the `__admin__.kv` aliases-to-root hack. The admin tenant now has its own `{data_dir}/__admin__/app.db` like every other tenant. `Instance.platform: ?*Tenant` points back at the `Tenant` on the singleton admin instance only; the JS dispatcher installs `platform.root.*` globals gated on that field.

**Why**: the aliasing made admin-tenant outbox rows unreachable to the drainer (which scans per-tenant `app.db` files, never the root store) and leaked root-store key shapes into admin-handler JS code. Making admin "an instance like any other, plus a capability" solves both — drainer sees admin-fired email queues naturally, and platform-level operations become a well-typed JS surface instead of raw `__root__/…` key writes.

**Side effects**:
- Sessions, magic-link rows, resend key, admin-fired outbox rows all moved from root.db to `__admin__/app.db`.
- `__root__/` key prefixes dropped — root.db holds only identity+routing tables (`instance/`, `domain/`, `root_token/`).
- `Tenant.create` / `.destroy` replaced `init` / `deinit` (heap-allocated; the `platform` interior pointer requires stable address — rove-library principle 14).
- Admin JS handler rewritten to use `platform.root.*` for root-kv reads/writes.

### 10.2 Root replication via raft envelope type 2

Envelopes now have four types:

| Type | Target store | Producer |
|---|---|---|
| `0` writeset | `{id}/app.db` | Customer handler `kv.*` via TrackedTxn + writeset |
| `1` log_batch | `{id}/log.db` | Worker `flushLogs` |
| `2` root_writeset | `__root__.db` | Signup's `tenant.createInstance`; admin JS `platform.root.*` |
| `3` files_writeset | `{id}/files.db` | Signup's `deployStarterContent`; files-server `putFileAndDeploy` |

Type-2 writes come from two producers: the signup HTTP handler (mirrors `tenant.createInstance`'s local write into a root writeset) and the admin JS handler's `platform.root.set/delete` calls (collected into a per-request root writeset, proposed after commit). **Divergence on propose failure is logged, not compensated** — at-least-once semantics consistent with the outbox/callback layers. A future iteration wraps root writes in a TrackedTxn with undo semantics.

### 10.3 Two-phase deploy protocol on FS backend

Implemented PLAN §2.4's three-leg content-addressed protocol:

- `POST /v1/instances/{id}/blobs/check` → `{missing, uploads}` with upload URLs + method + TTL
- `PUT /v1/instances/{id}/blobs/{hash}` → server hashes on arrival, rejects mismatch
- `POST /v1/instances/{id}/deployments` → full-replacement manifest commit, optional `parent_id` CAS

The `uploads` object's URL is path-relative on the FS backend (client resolves against whichever origin it reached); when a future `S3BlobStore` lands it will return absolute pre-signed S3 URLs, client follows them verbatim. **Same client code, different backends.** Admin UI JS exposes `api.bulkDeploy(instance_id, files, {parent_id, comment})` that hashes client-side with `crypto.subtle.digest("SHA-256")`, checks, uploads missing in parallel, commits.

### 10.4 `webhook.send` stays vendor-neutral; `email.send` takes key as parameter

**Dropped from PLAN §2.6**: the planned `X-Rove-Signature` HMAC header with per-instance webhook secret. Each destination has its own signing format (Stripe `Stripe-Signature: t=...,v1=...`, Slack `X-Slack-Signature` with a different scheme, AWS SigV4, etc.); a one-size-fits-all HMAC is meaningless to every real destination.

**What ships instead**:
- `crypto.hmacSha256(key, data) → hex` JS global — primitive for customers to roll their own signing
- `X-Rove-Webhook-Id` + `X-Rove-Webhook-Attempt` headers (vendor-neutral; receivers use the id for dedup)
- `email.send({key, from, to, subject, text?, html?, …})` takes the Resend key as an explicit argument. Customer's abuse-control concern: they can only email using a Resend key they provide. Our own magic-link email reads the platform Resend key from `__admin__/app.db` and queues an outbox row; customer handlers never see that key.

### 10.5 Replication-ready blob backend (path B: shared object store)

Ruled out: "raft carries blob bytes." A 1MB static file per envelope would blow raft-log size and commit-fsync budget. Two options remain for multi-node:

- **Shared filesystem mount** (NFS/EFS/Ceph) at `{data_dir}` on every node. Zero code — existing `FilesystemBlobStore` treats the mount like any other directory. Ops tradeoff: depends on reliable distributed FS.
- **`S3BlobStore` + SigV4 signer** (~500-800 LOC, uses `std.http.Client`). Targets S3 the *protocol* — works against AWS S3, Cloudflare R2, Backblaze B2, DigitalOcean Spaces, MinIO, etc. Credentials via env vars; no IAM metadata fetch in v1 (SSRF carve-out deferred).

OVH setup notes (if that's the target host): use OVH Object Storage "Standard" tier (S3-compatible), pick region matching compute (EU: GRA/SBG; NA: BHS), endpoint `https://s3.{region}.io.cloud.ovh.net`, path-style URLs.

Caching shape for followers: `CachedBlobStore` wrapper composing local-FS in front of S3. Content-addressed → no staleness. Not yet built.

### 10.6 dispatchOnce refactored into phase-shaped helpers

The 750-line `dispatchOnce` loop body was split into named helpers:
- `tryHandleSystem` — `/_system/*` proxy routing + preflight
- `resolveRequest` — admin/customer branch → either `.handled` or `.dispatch{handler_inst, scope_inst, is_admin}`
- `finalizeBatch` — end-of-walk commit + propose + move

`dispatchOnce` ended at 388 lines, reading as phase selection. The per-handler dispatch body (anchor → savepoint → run → release → success-record) stays inline — it's linear, context-heavy, and extracting it would threaten more parameters than readability gained.

### 10.7 Simulator primitive (purely client-side, KV-less)

**Change**: Loop46 gains a simulator primitive — `simulate(request, source_overlay, kv_overlay, tape, mode, miss_policy) → bundle` — implemented as a **client-side library only**. The worker has no simulator role: no `/_system/simulate/{id}` endpoint, no thread pool, no `simulate` rate-limit action. The worker's job is dispatch (live or dry-run, §10.11) + observation (recording tapes); simulation is purely a client concern.

Two implementations of the simulator share a contract (bundle JSON shape + tape blob format) but otherwise live independently:

- **CLI simulator** (Zig + QuickJS, this repo at `src/simulator/`) — linked into `loop46 test` and `loop46 simulate`. Hermetic, deterministic, used in CI and inner-loop dev. Reads handler source from the working tree (or fetched via existing files-server endpoints when targeting a deployment id).
- **Browser simulator** (JS + V8 via Chrome DevTools Protocol, separate repo, future per §10.12) — interactive replay debugging in the browser. Loads tape + source from server endpoints, stubs Loop46 globals (`kv`, `webhook`, `email`, etc.) via injected JS, lets the developer use real DevTools (breakpoints, stepping, variable inspection).

**Why purely client-side**: every v1 caller has either local source (CLI) or sufficient browser plumbing (the extension fetches source as needed). The server-side use cases that motivated a worker endpoint — single-request simulation for hosted MCP, cross-machine remote agents — are all deferred to v2. The worker is a recording device + dispatcher; observation flows worker → client; the client does all the compute.

A previously-considered second primitive ("trial-run" against live state, with savepoint rollback) was dropped — it conflicted with the FP story (non-deterministic), and the use cases it served (testing against current data, pre-deploy canaries) are better served by snapshot-derived fixtures (§10.9), running candidates on a separate Loop46 instance (multi-instance staging story), or the dry-run dispatch mode (§10.11).

**Read resolution stack** in `ReplaySource` (precedence high → low; each read records its source in the output bundle):

1. Request-scoped write buffer — handler's own writes during this simulation. Always active so read-after-write within a single request works. Discarded at simulation end.
2. Overlay map — supplied `{key → value}` for tests / what-if. Optional.
3. Tape — recorded values from a prior request. Optional.
4. Miss policy — `fail` (structured "unresolved read on K") or `not_found`. Per-simulation.

**No live KV pass-through layer.** Live state mixing was rejected as conceptually muddy (point-in-time mismatch between tape and live data leads to misleading results).

**Modes** are layer combinations:
- `strict` (1, 3, miss=fail) — apples-to-apples replay; unresolved reads surface as a first-class signal.
- `what_if` (1, 2, 3, miss=not_found) — overlay over tape.
- `isolated` (1, 2, miss=not_found) — overlay only, no tape. The mode sim tests use.

**Why `ReplaySource` is KV-less**: the simulator's dependency surface deliberately excludes `rove-kv` / SQLite. It links rove-tape (parse side only — recording is one-way), rove-files (manifests, when fetching from server), rove-blob (source bytes, when fetching from server), rove-qjs (execution), and the JS API surface from `src/js/globals.zig`. This makes the library CLI-linkable; for the browser implementation, the equivalent stubs are written in JS.

**Safety invariants** (load-bearing):
- Writes go to the buffer only and are discarded at simulation end. No promotion path through any tool, endpoint, or mode.
- Outbox effects (`webhook.send`, `email.send`) are recorded as "would-have-enqueued" rows in the bundle; the delivery worker never sees them. Loop46's transactional outbox is declarative, so this is structural.
- "Re-process this failed request after my fix" is **not** a simulation operation. Real re-processing is a normal HTTP request against a new deployment.

**Side effects**:
- Bundle JSON format from `rove-log-cli bundle` (`examples/log_cli.zig:210`) becomes the canonical shape consumed by both CLI sim and the future Chrome extension. Code moves into a shared module (`src/tape/bundle.zig`).
- Tape capture (`uploadTapes` in `src/js/worker.zig`) is unchanged; missing pieces are `ReplaySource` in the CLI simulator (`src/js/globals.zig:862-863` flagged the gap), request body capture, and module tape wiring.
- New module `src/simulator/` (CLI library only, no thread pool, no standalone-binary stub): `root.zig` + `replay_source.zig` + `bytecode_cache.zig` + small `compile.zig`.
- New CLI subcommands `loop46 simulate` and `loop46 test` (the latter spec'd in §10.8) link the simulator library.
- The browser implementation is a separate work item with its own architectural decision (§10.12) — it's not built in v1.
- Implementation plan: `docs/sim-test-framework.md`.

### 10.8 Sim test framework (deterministic, local-only)

**Change**: Loop46 ships a first-class in-deployment sim test framework. Tests live in a reserved `_tests/` directory of the developer's source repo, are imperative async JS, and run **entirely locally** via a `loop46 test` CLI subcommand that embeds QuickJS and links the simulator library (§10.7). No worker contact, no auth, works offline.

`_tests/` is a platform-prefix-guarded directory (alongside `_static/`, `_triggers/`, etc.). Customer handlers and trigger cascades cannot read or write into it.

**Injected globals** (test code receives these as a destructured argument):
- `simulate(req)` — invokes the simulator library in-process; reads handler source from the working tree.
- `expect(value)` — assertions.
- `snapshot(name, value)` — captures on first run, asserts structural equality on subsequent runs.

**Why first-class**: Loop46's simulator primitive (§10.7) makes handler tests structurally different from typical JS testing — no mocks needed (handlers can't `fetch`, can't bypass `kv`, can't directly send email; their I/O is overlay-able), side effects asserted not dispatched (would-have-enqueued outbox rows checked, never delivered), deterministic by construction (tape-pinned time/random + overlay-pinned state = bit-reproducible). Encoding this as a platform feature rather than leaving customers to choose a framework gives the agent loop a clean surface: production failure → `loop46_export_fixture` writes a sim test → fix → run tests → deploy.

**Why local-only is load-bearing**:
- Sim tests run from the working tree against the locally-linked simulator. No worker contact. Pre-commit hooks, TDD, CI sim phase all work offline.
- The worker has no simulation role at all (§10.7) — sim test workloads never hit it. The fixture-authoring story uses dry-run dispatch (§10.11) when capturing realistic state from live instances.
- Bisect on sim tests is local — fetch each historical deployment's source via `/_system/files/{id}/source/{hash}`, run sim suite locally per deployment, find the regression point. No remote simulation needed.
- Browser-side replay debugging (§10.12) is a separate Chrome-extension implementation that consumes the same tape + bundle format, also without server-side simulator help.

**Snapshot mechanism**:
- `snapshot(name, value)` compares against `_tests/__snapshots__/{name}.json` in the dev repo.
- First run captures; subsequent runs assert structural equality, fail with diff on mismatch.
- Regenerate via `loop46 test --update-snapshots`. Snapshots commit alongside test code.

**Fixture sibling-file pattern** (for `loop46_export_fixture`):
- Export writes two files atomically: `_tests/from-prod-{request_id}.mjs` (the test code) and `_tests/__fixtures__/from-prod-{request_id}.json` (captured tape + recorded bundle for the snapshot).
- The runner detects fixtures referenced by `from_recorded_request_id` in `simulate(...)` calls and loads them from disk instead of any network call. Tests run offline forever, never re-fetching from the server.

**Side effects**:
- New platform-reserved path `_tests/`. Lives in dev repo only — **stripped from production manifests at deploy time**. Production deployments never include test code.
- Snapshot files (`__snapshots__/`) and fixtures (`__fixtures__/`) follow the same strip rule.
- New CLI subcommand `loop46 test`. Embeds QuickJS + simulator library.
- Fixture-management primitives (§10.9) handle the editing / refreshing workflow that arises when handler changes require new fixture data.
- Implementation plan: `docs/sim-test-framework.md`.

### 10.9 Fixture lifecycle (curated observations)

**Change**: Loop46 ships fixture-management tooling for sim tests. Fixtures are **curated observations of production state** — files in `_tests/__fixtures__/` that hold the kv data a test uses as `simulate`'s overlay. Two paths to authoring fixtures:

1. **From a recorded request** (already in §10.8) — `loop46_export_fixture --request <id>` promotes a real production observation into a sibling-file fixture pair. Self-contained, snapshot-style.
2. **From live state, selectively** (this section) — pull specific keys from a target instance into a fixture. Lets the author construct realistic scenarios from production data without dumping the entire instance.

A "snapshot the whole instance" tool was considered and rejected — too coarse, expresses no intent, instantly stale. The right primitives are targeted: pull these keys, edit this fixture, refresh that one, diff fixture-vs-prod.

**Why**: sim tests are pure functions over (request, overlay, source). Realistic test data is the hardest part of authoring tests. As handlers evolve and read new keys, fixtures need updates. The lifecycle tools (add missing keys, refresh stale ones, diff drift) make fixture maintenance ergonomic without breaking the FP story — fixtures stay frozen JSON files committed to the dev repo, used as deterministic inputs to pure functions.

**Primitive set**:

Reading from live state:
- `/_system/kv/{id}/*` admin endpoint (read-only, paginated): `get/{key}`, `?prefix=...&limit=N&after=<key>`, `count?prefix=...`. Same endpoint backs the dashboard KV browser.
- `loop46 kv get <key>` / `list-prefix <prefix>` / `count <prefix>` — CLI wrappers.

Authoring + editing fixtures:
- `loop46 fixture from-keys <key>... [--from <instance>] -o <fixture>` — pull a curated slice into a fixture file.
- `loop46 fixture add <fixture> <key> [--value <v> | --from <instance>]` — fill in missing keys.
- `loop46 fixture remove <fixture> <key>`.
- `loop46 fixture edit <fixture>` — opens $EDITOR.
- `loop46 fixture diff <fixture-a> [<fixture-b> | --against <instance>]` — show drift.
- `loop46 fixture refresh <fixture> [--from <instance>] [--key <k>]` — re-pull keys currently in the fixture.
- `loop46 fixture merge <a> <b> -o <c>` — combine.

Runner integration:
- Structured "unresolved read on K" error referencing the fixture path + missing key. Easy to act on programmatically.
- Optional `loop46 test --auto-fix-from <instance>` — on unresolved read, pulls the value, writes back to the fixture, retries. Single-pass fixture filling.

**Side effects**:
- New admin endpoint `/_system/kv/{id}/*` (also useful for dashboard KV browser, scoped-token auditing, agent ad-hoc state queries).
- New `loop46 kv` and `loop46 fixture` CLI subcommand families.
- Web UI follow-on (deferred): "Fixtures" tab in the dashboard with the same affordances over the same backend endpoints. Likely lands alongside Phase 5 admin UI maturity.
- Implementation plan: `docs/fixture-lifecycle.md`.

### 10.10 AI agent surface — CLI + skill file in v1, hosted MCP deferred

**Change**: Loop46's primary AI agent surface in v1 is **the CLI itself**, taught to agents via a skill file. **No MCP protocol server, no MCP wire-format code, no separate `loop46-mcp` binary in v1.** Hosted MCP at `mcp.loop46.me` is deferred until concrete remote-agent demand surfaces (third-party integrations, cloud agents that don't run on the customer's machine).

**Why this beats the original "MCP server as separate binary" plan**:

- The dominant agent use case (Claude Code, Codex, Cursor running in the customer's working tree) already has shell access. Skill file + CLI is genuinely sufficient — agents read `--help`, compose subcommands, parse JSON output.
- The MCP wins (typed schemas, server-side rate limiting, token isolation, cross-machine access) only matter for **remote/hosted** scenarios. None apply to local agents on the customer's machine.
- The MCP spec has been a moving target (SSE → Streamable HTTP). Building against it now means tracking spec churn; deferring lets it settle.
- The biggest concrete agent-security win (token isolation) is worth building independently of MCP. See "scoped tokens" below.
- Loop46's actual differentiator is the FP-pure simulation/test/fixture story (§10.7–§10.9). Wrapping it in MCP is icing; if the cake is right, customers don't need the icing yet.

**What ships in v1**:
- **Skill file** at `docs/skills/loop46.md` (or the path Anthropic's skill convention lands on). Teaches the canonical workflow (edit handler → `loop46 test` → fix fixtures via `loop46 fixture *` → `loop46 deploy`), the tool catalog, common patterns, gotchas, auth setup.
- **`--json` output mode** on every CLI subcommand for parseable structured results.
- **`loop46 doctor`** — environment + connectivity readiness check; the first thing an agent runs to confirm working tree, deployment, and credentials are in order.
- **Scoped tokens** — new token type alongside session/root, stored at `scoped_token/{sha256_hex}` in root.db. Carries a capability subset (`read`, `simulate`, `deploy`, `fixture`, `kv`, etc.) and an instance scope. Customer mints via dashboard or `loop46 mint-token --capabilities ...`. Agent runs with `LOOP46_TOKEN=<scoped>`; if compromised, blast radius is contained to the granted capabilities. **Independent of MCP** — a security primitive worth having for any agent integration (CI bots, hosted automations, third-party tools).

**What's deferred**:
- Hosted HTTP MCP at `mcp.loop46.me`. Build when a real remote-agent use case demands it. Until then, no protocol code in the repo, no subdomain reservation.
- `loop46-mcp` binary. Doesn't exist in v1.
- All MCP-specific tool schemas. They're skill-file documentation instead.

**Side effects**:
- New scoped-token install/auth functions in `src/tenant/root.zig` (analogues of `installRootToken` / `authenticate`).
- New `/_system/scoped_tokens` admin routes for mint/list/revoke.
- Dashboard "Tokens" tab.
- New `loop46 doctor` and `loop46 mint-token` CLI subcommands.
- Implementation plan: `docs/agent-surface.md`.

### 10.11 Worker dry-run dispatch mode

**Change**: a new `POST /_system/dry-run/{instance_id}` endpoint runs a synthetic request through the existing dispatch path with one behavioral change: the savepoint is **always rolled back, never proposed to raft**. Returns the bundle inline (response, would-have-written kv ops, would-have-enqueued outbox rows, captured tape entries). Nothing persists.

**Why**: complements §10.9 fixture lifecycle. Customers and agents need a way to capture **realistic tape data** for use as test fixtures — running a synthetic request through the real handler against current state, observing what it reads, but without polluting state. Without this, the only way to get a tape is to fire a real persistent request.

**Why this isn't a "simulator"**: dry-run is literal dispatch — same handler bytecode (precompiled, from the deployment manifest), same kv access (real `app.db` reads), same time/random (wall clock + OS), same trigger cascades. The only behavioral difference is "always rollback the savepoint and skip the propose." It's not running modified source, it's not using overlays, it's not replaying a tape. The simulation primitive (§10.7, purely client-side) handles all the *what-if* / *modified-source* cases; dry-run handles only *what would real dispatch do here, without committing*.

**Endpoint surface**:
```
POST /_system/dry-run/{instance_id}
{
  "request": { "method": "...", "host": "...", "path": "...", "headers": {...}, "body": "..." }
}
→ 200: <bundle JSON>   // includes inline tape entries; nothing persisted to log-blobs
```

**Implementation**: a small flag on `dispatchOnce` (`dry_run: bool`) plus a new admin route. Roughly 50 lines:
- Set `dry_run` on the dispatch state.
- After the handler runs, snapshot the writeset + outbox rows + tape entries from `TrackedTxn` and the recorder.
- Always rollback the savepoint regardless of handler success/failure.
- Skip the raft propose unconditionally.
- Return the snapshot inline as a bundle JSON instead of persisting to log-blobs.

**Cost shape — close to read-only**: dry-run skips the two expensive parts of a write request — the SQLite commit fsync AND the raft propose (network roundtrips + per-follower fsyncs in multi-node). What remains is handler CPU + SQLite reads + the in-memory writeset/tape capture. In multi-node setups where raft propose dominates write latency by several ms, dry-run is essentially as cheap as a synthetic read. Customers and agents can dry-run liberally without worrying about expensive operations or live-write contention.

**Side effects**:
- New admin endpoint, gated behind the existing admin auth + scope.
- Optional `dry_run` rate-limit action. Because the cost profile is closer to reads than writes, a more permissive default than `request` is justifiable. v1 simplest: share the `request` budget. Future tuning can give dry-run its own (more generous) bucket once load shapes are observed.
- Bundle JSON shape adds an inline `tape_entries` field (or includes the tape as a parsed structure) since dry-run tapes don't get a blob hash. Dual-purpose: live dispatch's bundle references tape blobs by hash (persistent); dry-run bundle includes them inline (ephemeral). Test/sim consumers handle both.
- New CLI: `loop46 dry-run --request '{...}' --instance <id> [--json]`. Prints bundle on stdout.
- New fixture authoring tool (Phase 13): `loop46 fixture from-dry-run --request '{...}' --instance <id> -o <fixture.json>` composes `dry-run` + extract-kv-tape + write fixture file.
- Worker dispatch path gets one new flag; the rest of the production hot path is unchanged.
- Implementation plan: detail in `docs/fixture-lifecycle.md`.

### 10.12 Browser-side replay via Chrome extension (deferred)

**Change**: the dashboard replay viewer described in §2.9 ("DevTools click-through to the dashboard replay viewer") is implemented as a **Chrome extension** that uses the Chrome DevTools Protocol (CDP) to run handler source in the browser's V8 with stubbed Loop46 globals. **Not built in v1** — flagged here so future-us doesn't accidentally re-derive a different approach (e.g., quickjs-wasm).

**Why CDP + V8 instead of quickjs-wasm**:
- **Real DevTools, free**: with CDP access, the extension gets breakpoints, stepping, variable inspection, source maps — all the standard debugging affordances Chrome already provides. Implementing this on top of quickjs-wasm would mean reinventing a debugger UI.
- **No WASM toolchain**: shipping quickjs-wasm + a custom debugger would mean a ~MB+ wasm binary plus DevTools-equivalent UI. The extension is much smaller.
- **Familiar developer experience**: anyone who has used Chrome DevTools recognizes the workflow; no new mental model.
- **Shared contract**: the extension consumes the same bundle JSON + tape blob format that the CLI simulator produces. Inputs come from existing server endpoints (`/_system/log/{id}/list` + `/blob/{hash}` + `/_system/files/{id}/source/{hash}`). No server-side simulator help needed.

**Tradeoffs**:
- **V8 vs QuickJS engine differences** (BigInt, regex edge cases, etc.) — not bit-identical with the CLI simulator. For interactive debugging this is acceptable; the goal is "let the developer see what happened and try changes," not strict semantic reproduction. Sim tests (in CI/CLI) remain the determinism authority.
- **Chrome-only** — Firefox would need a different extension model. v1 / early-adopter audience makes this acceptable.
- **Extension distribution** — Chrome Web Store publishing is its own small ops cost.

**What ships in the extension** (when it gets built):
- A stubs library that overrides Loop46 globals (`globalThis.kv`, `globalThis.webhook`, `globalThis.email`, `Date.now`, `Math.random`, `crypto.*`) with implementations that read from a recorded tape (loaded from the worker via `/_system/log/{id}/blob/{hash}`).
- A CDP client that loads the handler source into the active page's debugger, sets up the stubs, lets the developer drive execution from DevTools.
- UI for picking a request (from a list of recorded ones), loading its tape, and starting a debug session.
- Optional: edit-and-rerun affordance once breakpoints + stepping are working.

**Why deferred**: Phase 12's CLI sim covers the test-authoring + agent-driven debugging cases. The browser extension is a separate developer-experience addition; it depends on stable Phase 12 bundle/tape formats but doesn't gate any other Phase 12+ work. Build when Phase 5 admin UI is mature enough that "dashboard click → DevTools-style replay" is the natural next UX step.

**Side effects**:
- Future repo separate from rove (Chrome extensions have their own toolchain). Probably `loop46-replay-extension` or similar.
- The bundle JSON + tape format become a public contract (the extension is an external consumer).
- No PLAN.md §3 phase entry until the work is scheduled; recorded here as locked architecture only.

### 10.13 files-server + log-server detach: external services, not tenants (decided 2026-04-30)

**Change**: `rove-files-server` and `rove-log-server` stop being in-process worker threads and become **external HTTP services that loop46 integrates with the same way it integrates with Resend or Stripe**. Admin's JS handler calls them via `webhook.send`, receives results via the existing callback dispatch (`_callback/*` rows + `dispatchCallbacks`), and pushes the result to the dashboard browser via SSE (PLAN §2.12). The dashboard never talks to files-server / log-server directly — admin's JS is the integration seam.

**Why this framing, not "tenants"**: an earlier sketch had files-server + log-server as Loop46 tenants with their own deployed handlers. Wrong shape — they have their own storage layer, their own data model, no need for QJS or the per-tenant kv-undo machinery. Treating them as third-party HTTP services preserves Loop46's purely-functional handler model AND keeps files-server / log-server as **standalone, swappable HTTP servers**: an operator can replace them with S3 + a managed log aggregator without touching loop46.

**What deletes from the worker** (combined with the auth-middleware move planned alongside):
- `/_system/files/*` and `/_system/log/*` proxy paths in `src/js/worker.zig` — `tryHandleSystem`, the path-rewriting + scope-resolution + per-system auth gate.
- `code_proxy` + `log_proxy` rove collections + `ProxySubsystem` machinery.
- The cross-thread h2 *client* embedded in the worker (only the h2 server stays).
- The in-process spawning of files-server + log-server threads in `loop46/main.zig` — they become separately-deployed binaries pointed at via operator config.
- `extractAdminAuth` + `findCookie` + `extractBearerToken` + `tenant.authenticate` + `tenant.authenticateSession` (only used by /_system/* auth + the admin-host RPC gate; with /_system/* gone and the admin-host gate moving to a JS `_middlewares/*`, no Zig caller remains).

Net deletion: ~2-3k lines. The platform collapses to: HTTP/2 server, host→tenant routing, QJS dispatch, rate limit + penalty box, outbox drainer, raft apply, tape capture, SSE, static-asset fast path. Everything else is JS in admin's bundle (or in customer bundles).

**Latency cost**: today's `/_system/files/{tenant}/blobs/check` is a microsecond in-process forward. New shape pays drainer-tick + HTTP round-trip + callback-tick + SSE push. At the 250ms default drainer tick, a 50-file bulk deploy goes from <1s to ~25s — unacceptable for the developer-experience promise.

**Latency mitigations** (must land alongside the detach):
1. **Drainer kick on outbox write.** Handlers writing `_outbox/{id}` wake the drainer immediately rather than waiting for the next 250ms tick. New primitive — probably an eventfd or a per-worker condvar the drainer waits on. Brings round-trip floor to ~10ms.
2. **Parallel webhook dispatch.** Admin JS fires N `webhook.send` calls in one handler invocation; drainer dispatches them concurrently per tenant rather than serially. Today's drainer is per-tenant-serial — fine for low volume, a bottleneck here.
3. **SSE-driven optimistic UI.** Dashboard shows "saving…" / "uploading…" immediately, confirms when the SSE event lands. Modern admin-UI aesthetic; works fine at <100ms confirm latency.

Combined target: <100ms effective round-trip from dashboard click to confirmed result, even on 50-file bulk operations.

**Why this is right**:
- **Dogfoods webhook + callback + SSE harder than any customer use case will.** Admin's own tooling exercises them on every dashboard interaction; design issues surface for *us* before they surface for customers.
- **Keeps Loop46 pure.** No in-process escape hatches "just because the platform itself wants to call something." The same `webhook.send` primitive customers use *is* how the platform integrates with everything external.
- **Makes files-server + log-server swappable at the HTTP layer.** Operator can run them on the same box, on different boxes, behind a managed service (S3 for blobs; CloudWatch / Loki for logs), or reimplement them entirely. As long as they speak the agreed HTTP shape, loop46 doesn't care.

**Prerequisites (must land before the detach is realistic)**:
- **SSE primitive** (PLAN Phase 11 / §2.12). Dashboard can't get reactive updates without it.
- **Drainer-kick primitive.** Without immediate dispatch on outbox write, the 250ms tick is the latency floor.
- **HTTP auth on files-server + log-server.** Today's auth model is "trust the local proxy"; new shape needs bearer-token (or HMAC) auth on the HTTP API. Operator provisions the secret via `--bootstrap-kv files_server_token=... files_server_url=...` (the bootstrap-kv mechanism §10's recent generalization handles this trivially — Zig knows nothing about either key).
- **Operator-side CLI / docs** for deploying files-server + log-server alongside loop46. Today they're spawned automatically; new shape requires the operator to start them and pass URLs.

**Sequencing**: **pre-launch (revised 2026-04-30).** Originally framed as post-launch refactor, but the detach is the load-bearing exercise of the webhook + callback + SSE + bearer-auth loop that customers will use to integrate with arbitrary third-party services (§10.14). Shipping launch without this means: (a) we haven't dogfooded the end-to-end async-port story, and (b) the dashboard-to-file-server path still goes through an in-process proxy that contradicts the architectural framing. Better to fold it into the launch-path Phase 5/5.5 work. Auth specifics in §10.14.

### 10.14 Distributed Elm ports: webhook + callback + SSE + bearer auth (decided 2026-04-30)

**Framing**: Loop46's customer model is **Elm with distribution**. Pure handler functions (`request × kv → response × cmds`); explicit Cmd-shaped side effects via `webhook.send` and `email.send`; Sub-shaped reactive intake via triggers (kv-write subscriptions), callback handlers (webhook-result subscriptions), and SSE (server-pushed events to client). The combination is **distributed Elm ports** — typed channels between pure-functional handlers and the imperative world.

This isn't just a metaphor. The architectural claim is: real-world reactive applications can be expressed in Loop46's pure-functional handler model *without escape hatches*, because every imperative concern (HTTP I/O, time, retries, browser updates, third-party integrations) has a port-shaped primitive. The combination of webhook + callback + SSE + bearer-mediated cross-origin auth is what makes the model complete enough that customers don't reach for an escape hatch.

**What this unblocks for launch**: the full third-party integration story. Customers integrate with Stripe, Twilio, GitHub, AWS, etc. through these ports without any pure-functional escape hatch. Loop46-the-platform dogfoods the same pattern: file-server and log-server (§10.13) become pseudo-third-party services that admin's editor and runtime talk to via bearer-authed HTTP, with deploy notifications and live UI updates flowing back through webhook + SSE.

**Customer third-party auth toolkit** (orthogonal to editor auth — different surface, different primitives):
- **Stored keys**: customer puts API tokens in kv (`kv.set("stripe_secret", "sk_live_...")`); operator-config'd or end-user-supplied via signup forms.
- **Arbitrary headers**: `webhook.send({ headers: { Authorization: "Bearer " + kv.get("stripe_secret") } })`. Covers Bearer (Stripe / GitHub PAT / Slack / Resend), API-Key, custom-header.
- **HMAC per-request signing**: `crypto.hmacSha256(key, canonicalRequest)` covers AWS SigV4, Twilio request-signature verification, Stripe webhook verification, etc.
- **OAuth refresh flows**: refresh token in kv; on-401 callback handler mints fresh access token via `webhook.send` to the OAuth provider's token endpoint; new access_token written back to kv. ~30 lines of customer JS, no new primitive.

**Audit gap-fills** (small primitives to add when concrete demand surfaces — not pre-emptively):
- `crypto.base64Encode(Uint8Array) → string` and `crypto.base64Decode(string) → Uint8Array`. Twilio basic-auth (`Basic base64(sid:token)`) needs it; many APIs return base64 signature material. QJS-ng has no built-in `btoa/atob`. ~30 lines (Zig native using `std.base64`).
- `crypto.hmacSha1(key, data) → hex`. AWS SigV2 (legacy), Twilio request signing on TwiML callbacks. ~10 lines, same shape as the existing `hmacSha256`.
- **Deferred**: RSA/ECDSA signing (GitHub Apps, Google service accounts, Apple Push). Bigger surface; HMAC-signed JWTs (which our stack already handles via hmacSha256 + base64) cover a meaningful subset. Add when a customer asks.

**Editor auth (dashboard-internal; does NOT generalize to third parties)**:
- Editor's session lives in the existing HttpOnly cookie set by `/v1/auth` or `/v1/login`.
- For cross-origin calls to file-server / log-server, editor exchanges its cookie for a short-lived bearer via a new `GET /v1/files-token` endpoint on admin. Admin signs the bearer (HMAC over `session_opaque || expiry_ms`, with a shared signing secret operator-provisioned via `--bootstrap-kv files_token_signing_secret=...`).
- File-server validates the bearer locally — same shared secret, same HMAC verification. **No round-trip to admin per request.**
- Bearer TTL: 5 minutes. Editor refreshes transparently on 401 by re-calling `/v1/files-token`.
- Logout invalidates the session row in admin's kv; existing bearers continue to work until they expire (≤5 min). Acceptable revocation latency for a development tool; tighten if it ever matters by including `session_revoked_at_ms` in the signed token and re-checking on file-server.

**Why this isn't generalized to customer third-party auth**: the cookie-to-bearer flow only makes sense for clients that *have* a Loop46 cookie session — i.e., the dashboard. Stripe / GitHub / AWS don't have access to that cookie; customers' integrations with them use the kv-stored-keys + arbitrary-headers + crypto-signing toolkit above. The two paths are orthogonal and don't share API surface beyond `webhook.send` itself.

**Deploy notification**: editor orchestrates v1. After committing a deploy on file-server, the editor receives the new manifest hash in the response; it then POSTs that hash to admin (`POST /v1/internal/deploy-applied`) which updates `tenant_files_map.current_deployment_id` and fires an SSE event for any listening dashboard sessions. File-server-pushes-to-worker is left as a v2 option — useful when CLI deploys land that don't go through the editor.

**Pre-launch implications**:
- §10.13 sequencing flips from post-launch to pre-launch (already done above).
- The customer third-party-auth story becomes documented + audited — operators can promise customers "integrate with any HTTP API using webhook.send + crypto.\*."
- The ports/commands framing becomes the documentation north star for the customer-facing handler model. PLAN §1 / §2 audience descriptions update accordingly.

**Order** (each row is its own work-window, several PRs):
1. **SSE primitive** (Phase 11). Without it the post-save / deploy-confirmation loop has nowhere to land.
2. **`crypto.base64Encode/Decode` + `crypto.hmacSha1`** if any pre-launch customer integration needs them. Audit the in-flight customer integrations before launch.
3. **Bearer-token issuance** in admin's JS (`/v1/files-token`) + HMAC-signed-bearer validation in file-server. Operator provisions `files_token_signing_secret` via `--bootstrap-kv`.
4. **Editor switches** to direct-to-file-server bearer-authed calls (parallel with the existing /_system/files/* proxy during migration).
5. **Editor orchestrates deploy**: after file-server commit, POST manifest hash to admin. Admin updates state, fires SSE.
6. **Drop the worker proxy + in-process file-server thread.** File-server runs as separate operator-deployed process. Update PLAN §10.13's "what deletes" list as actually-deleted.
7. **Same shape for log-server**, slightly easier (query-only, latency-tolerant, no deploy-notification path).

## 11. Rove-library principles audit (2026-04-21)

Audited against `~/.claude/memory/rove-library.md`. Findings:

### Fixed
- **Admin-kv aliasing** (violated principle 1 "state is collection membership" — admin was a special case). Admin is now an instance with a capability component; see §10.1.
- **`dispatchOnce` monolith** (violated principle 5 "small systems with flush boundaries"). Split into phases; see §10.6.
- **Interior pointers on stack-allocated struct** (violated principle 14). `Tenant` now heap-allocates via `create`/`destroy`.
- **Silent error swallowing on kv-undo** (violated fail-fast). Now logs `std.log.err` on undoTxn failure.
- **Handler exceptions → 200 empty body** (2026-04-27). The dispatcher captured the throw into `resp.exception` but the worker only checked `last_kv_error` and savepoint-release errors. Now translates `resp.exception.len > 0` into a 500 with `handler threw: <msg>` in body + log, after rolling back the savepoint. Fix in `src/js/worker.zig` per-handler dispatch; covered by `signup_smoke.sh` section 9b.
- **Silent error swallowing on log-batch fallback** (2026-04-27, fail-fast). `tl.store.applyBatch(batch) catch {}` in `src/js/worker.zig` flushLogs envelope-encode-failure path now logs `std.log.warn` with batch size and tenant.
- **Silent error swallowing on failed-response** (2026-04-27, fail-fast). The `setResponse(... 500 ...) catch {}` instances in `src/files_server/thread.zig` and `src/log_server/thread.zig` per-request error paths now log `std.log.err` with the inner error name. Did NOT propagate (would kill the whole server thread on a single bad response — see runThread loop) but the entity-stuck-in-request_out condition is now visible.
- **Silent error swallowing on `txn.rollbackTo` after handler failure** (2026-04-27, fail-fast). Three sites in `src/js/worker.zig` per-handler dispatch (dispatcher.run catch, handler exception, kv error) now log `std.log.err` with the tenant id and rollback error name. Rollback failure here indicates kv state inconsistency worth surfacing.

### Outstanding (nice-to-fix)
- **Header builder duplication**: `buildSystemRespHeaders` and `buildHandlerRespHeaders` both pack pair-lists into one contiguous buffer. The other two builders (`buildAuthRespHeaders`, `buildRedirectRespHeaders`) deleted with the admin-handler JS port — only these two remain, and could collapse to one builder taking a pair slice.
- **Dev-mode escape hatches as `pub var`**: `ssrf.dev_allow_loopback` + `http_client.dev_allow_plaintext` are module-level mutable globals. Works but is ugly; should be plumbed as `DrainerConfig` fields.

## 12. Pre-release surprises (customer-visible gotchas)

What customers writing handlers against rove may not expect. Flag any that should get first-run documentation or UI affordances before we open signup.

### Handler API shape

- **Default export is called with NO arguments.** Read `request.method` / `request.path` / `request.body` / `request.query` / `request.headers` / `request.cookies` from the ambient `request` global. The common "handler takes `req, res`" reflex doesn't apply.
- **`request.headers` keys are lowercase** per HTTP/2 wire convention. Use `request.headers["content-type"]`, not `request.headers["Content-Type"]`. Pseudo-headers (`:method`, `:path`, etc.) are filtered out. Last-write-wins on duplicates (HTTP/2 clients SHOULD coalesce; if a real customer hits a producer that doesn't, we revisit).
- **`request.cookies` is pre-parsed** from the `cookie` header — `{name: value}`, RFC 6265 semicolon-separated, whitespace trimmed from both name and value (matches browser / Express / Hono parsers). Empty / no-cookie → `{}`.
- **Return value = response body.** No `response.body = "..."`. String returns emit as-is; objects are `JSON.stringify`-ed with `content-type: application/json` auto-stamped.
- **Handler exceptions return 500 with `handler threw: <message>` in the body.** Customers debugging should look at the response body for the JS exception text; the same text is also captured into the request log's `exception` field.
- **10ms CPU budget** covers handler + every trigger fired + every cascade those triggers caused, *in aggregate*. Not a per-handler or per-trigger cap. Runaway `while(true)` trips the budget and returns 504.

### Available / missing globals

Shipped:
- `kv.get/set/delete/prefix`
- `webhook.send`, `email.send`
- `crypto.getRandomValues`, `crypto.randomUUID`, `crypto.hmacSha256(key, data) → hex`
- `console.log`
- `Date.now`, `Math.random` (seeded/deterministic; captured for tape replay)
- `TextEncoder` / `TextDecoder` (UTF-8 only polyfill)
- `platform.root.{get,set,delete,prefix}` (admin handler only; undefined elsewhere)
- Standard intrinsics: `JSON`, `Date`, `RegExp`, `Map`/`Set`, `Promise`, `BigInt`, typed arrays

Not available:
- `fetch`, `setTimeout`, `setInterval`, `XMLHttpRequest` — use `webhook.send` for outbound
- `URL`, `URLSearchParams` — parse `request.query` by hand (`split("&")` + percent-decode), or ship a polyfill later
- `Response`, `Headers` — fetch-API class hierarchy intentionally dropped (§10 removed the aspirational `new Response(...)` shape)
- `atob`, `btoa` — base64 helpers not there yet; if customers need them, add a polyfill
- `console.error` / `console.warn` / `console.info` — only `console.log`
- `WeakRef`, `Proxy`, `DOMException` — explicitly skipped in the snapshot init to save per-request memcpy bandwidth

### File layout conventions

- Handler source lives at top-level paths (`index.mjs`, `foo/index.mjs`, `api/users.mjs`). An earlier draft of PLAN §2.4 mandated a `_code/` prefix; dropped 2026-04-27 — extension + manifest kind already disambiguates from static, so the prefix was pure ceremony.
- `_static/<path>` is the system-reserved prefix for raw bytes; other top-level `_*` paths are reserved for system use (`_triggers/`, `_404/`, `_500/`, etc.)
- `MAX_PATH_LEN = 192`; file-size caps of 1MB static / 64KB handler (plan; not yet enforced)
- Bulk deploy is **full-replacement** — client sends the entire manifest. Single-file save endpoint exists for the "edit one file" UX; bulk deploy replaces everything not in the request.

### Webhook / email semantics

- **At-least-once delivery.** Receivers must dedup on `X-Rove-Webhook-Id`.
- **No ordering guarantees.** Chain via callbacks if ordering matters.
- **`webhook.send` is vendor-neutral** (§10.4). No default signing header; use `crypto.hmacSha256` to build vendor-specific signatures in the handler before `webhook.send`.
- **`email.send` takes `key` as an explicit argument.** Customer's abuse-control concern; keep the Resend key in KV and pass it at call site.
- **Response body captured at 256KB max.** Anything larger is truncated with `truncated: true` on the callback event.
- **Dev-only flag `--dev-webhook-unsafe`** relaxes SSRF + HTTPS-only for local smokes. NEVER set in production — a malicious customer handler could probe localhost and leak bodies over plaintext.

### Auth / signup

- **Magic link TTL 15 min, single-use.** A redeemed link 401s on replay.
- **Session cookie is `HttpOnly + Secure + SameSite=Lax`.** `Secure` requires HTTPS; localhost is treated as a secure context by modern browsers, but plain-HTTP non-localhost dev won't get the cookie. Use `curl -H 'Cookie: rove_session=...'` manually for HTTP-only dev.
- **Signup without Resend key configured** → response body carries `magic_link` in-band so dev + CI smoke tests still work. When a key IS configured, `magic_link` is suppressed and the email is queued via outbox.
- **Reserved instance names** rejected with 409: `admin`, `api`, `app`, `www`, `__admin__`, `auth`, `login`, `signup`, `logout`, `dashboard`, `static`, `system`, `public`, `root`, `mail`. Collisions on real signups also return 409 with the same body (no enumeration).

### Admin scope + platform capability

- `platform.*` JS globals exist only on the `__admin__` handler. Other tenants' handlers see `platform === undefined` and get a `TypeError` if they try to call `platform.root.*`.
- **`X-Rove-Scope: <instance_id>` header** rebinds the admin handler's `kv` to the target tenant's `app.db`. Without it, `kv.*` on the admin handler operates on admin's own `app.db` (NOT root — that's the §10.1 change).
- **Admin JS writes to `platform.root.*` are replicated via type-2 root writeset**, but they land locally on the leader first and propose-on-commit. A propose failure leaves leader/follower divergence (logged, not compensated).

### Multi-node setup

- Customer KV writes, request logs, root metadata, and files.db manifests all replicate via raft. **Blob bytes do not.**
- Running more than one node requires either a shared filesystem mount at `{data_dir}` (NFS/EFS/Ceph) or a future `S3BlobStore` backend.
- On leader failover, the new leader has full manifests but may 503 on any blob not yet cached locally until either (a) the shared backend serves them or (b) the leader pushes them to S3.

### Operational

- `--bootstrap-root-token <hex>` seeds the operator bearer token at startup. Token can be any 32–128 printable ASCII chars; hex is convention not requirement.
- `--bootstrap-resend-key <key>` seeds the platform Resend key into `__admin__/app.db`.
- `--public-suffix <domain>` enables wildcard `{id}.<domain>` → instance routing. Without it, every host needs an explicit `assignDomain` entry.
- `--admin-api-domain <domain>` routes that host's traffic through the `__admin__` handler with auth. Separate from `--public-suffix`.
- `--dev-webhook-unsafe` enables loopback + plaintext webhook targets for local smoke tests.
