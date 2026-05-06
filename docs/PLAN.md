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
- All external effects route through declarative Cmd-style primitives: `webhook.send` (§2.6) for outbound HTTP, `email.send` (§2.6) for transactional mail, `events.emit` (§2.12) for live UI push to the customer's connected clients. Each accumulates a deterministic Cmd record on the dispatch state during the handler's transaction; at commit, the Cmds ride alongside the kv writeset through raft, and a separate delivery loop carries them out.
- All nondeterministic inputs are tape-captured.
- Every request gets a fresh QuickJS context via snapshot-restore (existing mechanism in `src/js/worker.zig`).
- **CPU budget: one 10ms envelope covers the whole request — handler body + every trigger it fires (BEFORE and AFTER) + every cascade those triggers trigger.** No per-trigger or per-cascade sub-budgets. Exceeding 10ms terminates the request and rolls back the transaction. Callbacks run as independent handler invocations in their own transactions and get their own fresh 10ms envelope when they fire.

**Why so strict?** Determinism is what lets us offer the replay-with-breakpoints story that differentiates Loop46. The moment a handler can `await fetch(...)` inline, replay has to either re-execute the fetch (loses determinism) or fake it (diverges from prod). Forcing all external I/O through Cmds means replay is exact, always — the captured response that drove the original callback drives the callback on replay too.

The cost: "call an external API and use the result inline" is impossible. Customers rewrite as "fire webhook → return 'accepted' → callback updates state → client observes via poll/SSE." This is where modern serverless is going anyway (every SaaS backend is full of async job queues), so it's a calculated bet.

### 2.4 File API + static serving

> **See `docs/files-server-plan.md`** for the implementable expansion:
> files-server moves to `files.{public_suffix}` with its own TLS,
> manifest moves from per-tenant `files.db` to S3
> (`tenants/{id}/deployments/{dep_id}.json`), runtime release signal is
> a `_deploy/active` kv marker observed via the existing
> writeset-scan path (no polling), worker reads bytecodes/statics on
> demand from S3 with content-hash ETags + Cloudflare in front. Worker
> drops the entire `/_system/files/*` proxy and the `files.db` per-
> tenant store. The §2.4 routing/cache/path-validation/size-cap rules
> below are unchanged and carry forward to the new layout.


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
- **Platform-prefix guard at two layers.** Deploy-load rejects trigger paths whose derived prefix overlaps any of: `_audit/`, `_deploy/`, `_callback/`, `_magic/`, `_triggers/`, `_events/`, `_sessions/` (and any future system namespace). Fire-time also skips trigger dispatch when the kv key has a platform prefix — defense in depth. (`_outbox/*` and friends are not in this list because they don't live in tenant `app.db` — webhook state lives in cluster-wide `webhooks.db`; see §2.6.)
- **Cascade depth tracked on `DispatchState`.** Single counter, incremented before each recursive trigger fire, decremented after; throws at 8.
- **`previousValue` event field**: implementation does an extra `kv.get` for the existing value before each write that has matching triggers. Acceptable cost given the 32-trigger ceiling and the read-your-writes guarantee from `TrackedTxn`.
- **Storage is just files.** Trigger modules live in the customer's deployment manifest exactly like any other handler file: `file/_triggers/users/sessions/index.mjs → {hash, kind: "handler", content_type}` plus source + bytecode bytes content-addressed in the deploy blob store. Same content-addressed two-phase upload pipeline (§2.4). (Today these flow through `files.db` + raft envelope type 3; after Phase 5.5 (e) they live in S3 per `docs/files-server-plan.md`.) What's *new* and lives in the worker (not files-server) is the in-memory **trigger registry** on `TenantFiles`, derived at deploy-load time. Same split as handlers (source in files-server, runtime bytecode cache in worker).
- **Rove ECS audit per `~/.claude/memory/feedback_state_is_collection.md`**: triggers introduce no new entities or collections. The registry sits on `TenantFiles` next to the existing `bytecodes` map; execution is recursive enhancement of `kv.set` / `kv.delete` JS globals inside the handler's existing QuickJS context. The handler entity in `request_out` remains the only entity in flight. No new Rows, no new systems at the rove layer.

### 2.6 Webhooks (Cmd pattern)

> **See `docs/webhook-server-plan.md`** for the implementable
> expansion: in-flight webhook state lives in a cluster-wide
> `webhooks.db` (raft-replicated via new envelope types 4/5/6); a
> leader-pinned webhook-server thread inside the loop46 binary
> owns delivery. Webhook intent rides through raft as **envelope 4
> in the same raft entry as the customer's writeset (envelope 0)**,
> so by the time the response returns to the user, the webhook is
> durably enqueued cluster-wide. There is no per-tenant
> `_outbox/{id}` row, no drainer, no orphan-recovery scan. The
> §2.6 customer-facing API + at-least-once-with-X-Rove-Webhook-Id
> contract carry forward unchanged.


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

- **`webhooks.db`** — cluster-wide, raft-replicated, holds every pending / inflight / failed-pending-callback webhook across every tenant. Indexed by `tenant_id`. Written via envelope 4 (enqueue) / 5 (complete) / 6 (retry-schedule) apply.
- **`_callback/{id}`** — per-tenant `app.db` row written by envelope-5 apply when a webhook reaches a terminal outcome. Drives the existing `dispatchCallbacks` worker phase that fires the customer's `onResult` handler.

No per-tenant `_outbox/{id}`, no `_outbox_inflight/{id}`, no `_dlq/{id}`. Failed webhooks live in `webhooks.db` as `state = 'failed_pending_callback'` until the callback fires.

**Webhook id derivation**: `hash(request_id || call_index)`. Deterministic across replays. Call index = 0-based order of `webhook.send` within one handler execution.

#### Enqueue path

- Customer's `webhook.send` call accumulates in the dispatcher's per-handler webhook list (parallel to the kv writeset, not part of it).
- On savepoint release, the list merges into the per-tenant batch's webhook accumulator. On rollback, both writeset and webhooks discard.
- At batch commit, dispatcher proposes ONE raft entry carrying envelope 0 (merged writeset) + envelope 4 (merged webhook batch). Apply on every node writes both atomically (writeset to tenant `app.db`, webhook batch INSERT into `webhooks.db`).
- Customer response gates on raft commit, so by the time the user sees a 2xx, the webhook is durable cluster-wide.

#### Delivery loop

- Runs as a leader-pinned thread inside the loop46 binary (see `docs/webhook-server-plan.md`). Single instance per cluster, guaranteed by raft leader uniqueness.
- Reads `webhooks.db` directly: `WHERE state = 'pending' AND next_attempt_at_ns <= now()`. Apply-side wakeup on envelope-4 commit signals new rows (no polling).
- POSTs the customer URL with the row's body + headers + `X-Rove-Webhook-Id` + `X-Rove-Webhook-Attempt`.
- On 2xx: propose envelope 5 (`webhook_complete`, outcome=delivered). Apply removes from `webhooks.db` + writes `_callback/{id}` to tenant app.db.
- On retryable failure (and attempts < max): propose envelope 6 (`webhook_retry_schedule`) with new `next_attempt_at_ns`. Apply updates the row in place.
- On terminal failure: propose envelope 5 with outcome=failed. Apply same as the success case (removes row, writes callback with failure outcome).

#### Retry defaults

- Exponential with full jitter (0..delay). Base 1s, cap 5min.
- Default `maxAttempts: 10` (≈1 hour envelope).
- Retryable: 408, 425, 429, 5xx, network errors, timeouts. Non-retryable: all other 4xx.

#### Delivery guarantees

**At-least-once.** Receivers must dedupe via the `X-Rove-Webhook-Id` header (stable across retries). Industry-standard shape matching Stripe/GitHub/Shopify.

#### Ordering

**No ordering guarantees**, not even per-instance. Different destinations have different latencies/failure rates; strict ordering would kill throughput and can't be meaningfully delivered anyway. Customers who need ordering chain via callbacks.

#### Headers injected

- `X-Rove-Webhook-Id: <webhook_id>`
- `X-Rove-Webhook-Attempt: <n>`
- Optional `X-Rove-Idempotency-Key: <customer-provided>` passthrough

`webhook.send` is vendor-neutral — no platform-owned signing header. Customers
that need vendor-specific signatures (Stripe, Slack, AWS SigV4, etc.)
construct them in the handler via `crypto.hmacSha256(key, body)` and pass the
result through `headers`. See §10.4 for the rationale.

#### Security

- **SSRF protection (mandatory, non-optional)**: block private IP ranges (`10/8`, `172.16/12`, `192.168/16`, `127/8`, link-local `169.254/16`, metadata `169.254.169.254`), IPv6 equivalents. Re-resolve on each retry (DNS rebinding defense).
- **TLS always on**. No `rejectUnauthorized: false` anywhere. Invalid cert = failure.
- Redirect cap: follow up to 3, else error.
- DNS resolve timeout 5s, connect timeout 10s, per-attempt total 30s default (5min hard cap).

#### Response body capture

Default 256KB; truncation flagged as `truncated: true`. Larger caps as plan-tier knob. Truncated bytes are what the callback sees on replay too (determinism).

#### Draft webhooks

`?__draft=` deploys route `webhook.send` to a **sandbox webhook batch**: visible in dashboard (see what would fire), never enqueued into `webhooks.db`. Avoids spooky action where a QA preview causes production side effects.

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

> **See `docs/logs-plan.md`** for the implementable expansion:
> worker batches log records in memory and PUTs directly to S3 as
> `.ndjson.gz` payloads + `.idx.json` sidecars (no raft for the log
> path). A standalone log-server on `logs.{public_suffix}` polls S3
> sidecars, maintains a local SQLite `log_index.db`, serves dashboard
> queries with JWT-handoff auth. Drops envelope type 1 (log_batch),
> per-tenant `log.db` files, and the worker's `/_system/log/*` proxy.
> The §2.9 semantics below (deployment_id tagging, parent_request_id,
> tape sampling, TTL) carry forward.


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

> **See `docs/sse-plan.md`** for the implementable expansion (wire
> formats, sse-service module layout, ring-cache sizing, JWT shape,
> backpressure rules, migration sequence). The §2.12 sections below
> mirror sse-plan.md's locked decisions; sse-plan.md has the
> implementation detail.


The companion to webhooks (§2.6): handlers fire events from inside their transaction, connected clients receive them over a long-lived SSE stream. Same Cmd / replay / determinism story; same "pure handler + declarative side effects" model. Different direction — webhooks push out to the world, events push out to *this customer's clients*.

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

**No `_events/*` rows in tenant app.db.** SSE is a notification channel, not a durable state store; the customer's `app.db` is the source of truth and SSE just tells the UI "something changed, refetch." `events.emit()` appends to an in-memory **emit buffer** on the request's execution context. After the kv writeset commits, the worker fires the buffer fire-and-forget to sse-service. Event ids are deterministic (`{request_id:020d}-{call_index:06d}`) so tape replay synthesizes the same sequence.

#### Connection endpoint

```
GET https://sse.{public_suffix}/v1/{tenant_id}/sse?token=<jwt>
                                  [?last_event_id=<id>]   (optional cursor)
                                  [Last-Event-ID: <id>]   (header, EventSource standard)
```

Lives on **sse-service**, a separate process on its own subdomain (`sse.{public_suffix}`) with its own TLS listener. JWT is signed by the platform key with payload `{tenant_id, sid, caps, exp}`; the customer's app fetches it from a same-origin endpoint `/_session/sse-token` (worker-served, reads `_rove_sess` cookie, mints the JWT). Single platform-managed hostname for all customers — no per-tenant SSE subdomain, no per-tenant TLS provisioning. EventSource opens with `withCredentials: false` so it's a "simple" cross-origin request — no preflight, no `Access-Control-*` headers needed, `__Host-` cookies stay safely pinned to the customer's app domain.

#### Pump (worker → sse-service)

After the writeset commits, the worker spawns a fire-and-forget POST to `sse-internal/v1/emit` with the emit buffer (auth via shared `SSE_INTERNAL_TOKEN`). 1s timeout cap; on failure the worker logs and moves on — the customer response is never blocked. sse-service appends events to a per-(tenant, sid) **ring cache** (30 entries, sized for brief reconnect catch-up — network blip, page hidden for 30s) and pushes to any open EventSource connections for the target sids.

On reconnect with `Last-Event-ID`: if the id is in the ring, replay from there; if it's been evicted, emit a `rove:resync` sentinel event telling the client to refetch state. The ring is bounded by entry count, not time — there's no "retention" concept beyond reconnect-window catch-up.

#### Caps (plan-tier, single-struct interface)

```zig
pub const EventsCaps = struct {
    max_concurrent_connections_per_instance: u32,
    max_concurrent_connections_per_session: u32,
    max_emits_per_request: u32,
    max_event_payload_bytes: u32,
};
pub fn eventsCapsForPlan(plan: tenant.PlanTier) EventsCaps;
```

Starting numbers:

| Cap | Free | Paid | Notes |
|---|---|---|---|
| Concurrent SSE connections / instance | 100 | 10,000 | Enforced at sse-service connect |
| Concurrent SSE connections / session | 16 | 16 | Multi-tab sanity guard, not plan-tiered |
| Emits per request | 100 | 1,000 | Enforced on the worker at `events.emit` time |
| Event payload bytes | 64 KB | 256 KB | Enforced on the worker; inherits kv value cap as floor |

Caps that bound persistent state (`retention_seconds`, `max_events_per_session_in_retention`) go away — there's no persistent state to retain. The 30-entry ring cache is fixed by sse-service and not plan-tiered.

Caps are embedded in the JWT at mint time (1h TTL), so cap changes propagate within the token lifetime. Saves an HTTP roundtrip per connect; eliminates a sse-service → worker dependency on the connect path.

#### Authorization

JWT in the connect URL is the auth. The token endpoint `/_session/sse-token` on the customer's app domain reads the `_rove_sess` cookie, mints a JWT scoped to `(tenant_id, sid, caps)` for 1h, and returns it. Customer's responsibility to bind session→user themselves (via their `/login` handler writing `sessions/{sid}/user = X`) and to refuse to emit to sessions that aren't authorized.

#### Draft mode + tape

`?__draft=` deploys: worker swaps in a "capture, don't fire" emit binding — appends to a captured-emits list visible in the dashboard sidebar but never POSTs to sse-service. Tape replay uses the same hook so step-through debug doesn't fan out events to live connections.

#### Failover

Single sse-service process per cluster. If it dies: all EventSource connections die (TCP reset), browsers auto-reconnect to whatever sse-service is now answering the LB, the new process has empty rings → any `Last-Event-ID` hits the sentinel path → clients refetch state and catch up. Worker emit POSTs during the dead window fail with connection refused → worker logs and drops → events lost (acceptable; SSE is best-effort by design).

No election protocol, no state migration, no raft for sse-service. Operator (or k8s/systemd) handles "process died, restart it."

#### What's gone (vs the v1 model)

The earlier v1 SSE plan stored events as `_events/{sid}/{seq}` rows in customer app.db, replicated via raft, with a per-tenant retention sweep. All of that is rejected (see §7) and replaced by the response-attached-emit-buffer + sse-service model above. Notably gone: `events_pump.zig`, `events_sweep.zig`, the `_events/` reserved prefix, `markDirtyFromWriteset`'s `_events/` scan, the `pumpEvents` worker phase, and the SSE retention sweep timer.

#### Deferred

- Multi-instance sse-service with cross-instance fan-out (single process is the v1 bet).
- Customer-defined `_events/auth.mjs` connect-time auth (JWT scope is enough for v1).
- Topic / room / channel abstraction (customers compose with their own kv subscription maps).
- Per-message client acknowledgment (would require WS).
- Binary message types (SSE is text-only).
- mTLS between worker and sse-service (shared bearer token suffices for v1).

### 2.13 Raft snapshot strategy

> **See `docs/snapshot-plan.md`** for the implementable expansion.

Per-tenant snapshot indices with always-refresh-all-tenants
discipline. Snapshots transport via S3 (per-tenant `app.db` files
captured via `VACUUM INTO`, content-addressed in S3, manifest
references previous-snapshot files for unchanged tenants). No global
write-pause during capture; the always-refresh property prevents
dormant tenants from pinning the willemt compaction floor. Followers
load by downloading from S3 in parallel and atomic-renaming into
`data_dir`. Per-tenant `_apply_state` table on each `app.db` filters
duplicate applies during catch-up. Replaces the row-level delta
protocol that exists today (only meaningful in `.kv` apply mode,
which loop46 doesn't use).

The decision was driven by the worker-kv-path north star: keep the
worker fast, consistent, and uninterrupted. Pause-and-snapshot was
considered and rejected because even a few-seconds cluster-wide
write pause is incompatible with that goal at the "many tenants per
node" density.

## 3. Build plan (ordered phases)

> **Note on ordering**: the *content* of these phases is canonical, but
> the original number-order is no longer the launch sequence. §10.16
> (Launch sequencing) owns the beta / 1.0 / post-1.0 split and remaps
> phases across those windows. Read this section for what each phase
> *contains*; read §10.16 for what ships *when*.

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

> Note: as initially shipped (see §9), Phase 3 used a per-tenant
> `_outbox/*` + `_outbox_inflight/*` + `_dlq/*` schema with a
> drainer thread doing the deliveries. Phase 5.5 item 4 replaces
> that with a cluster-wide raft-replicated `webhooks.db` and a
> leader-pinned webhook-server thread; the customer-facing API is
> unchanged. The bullets below describe the eventual end state (not
> the historical Phase-3 implementation).

- `webhooks.db` cluster-wide schema (raft-replicated via envelope types 4/5/6).
- HTTP client: SSRF blocklist, TLS always, redirect cap, timeouts.
- `crypto.hmacSha256(key, data)` JS primitive so customers can build vendor-specific signatures (Stripe, Slack, etc.) in their handlers — no platform-owned signing header (see §10.4).
- Webhook-server (leader-pinned thread inside loop46 binary): reads `webhooks.db`, POSTs customer URLs, proposes envelopes 5/6 on completion. Exponential backoff + full jitter.
- Callback invocation: envelope 5 apply writes `_callback/{id}` to tenant app.db; existing `dispatchCallbacks` worker phase fires the customer's `onResult` handler in a fresh transaction.
- `email.send` wraps `webhook.send` with platform SMTP creds.
- Observability: log each attempt, dashboard queries `webhooks.db` for pending / inflight / failed views.
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

> **The work items below are now elaborated in dedicated sub-plans.**
> `docs/logs-plan.md` covers item 1 (logs leave raft entirely, go S3-direct
> with a sidecar-indexed log-server on `logs.{public_suffix}`).
> `docs/snapshot-plan.md` covers item 3 (per-tenant snapshot indices with
> S3 transport — replaces the original "raft snapshot + log compaction" with
> a no-pause file-shipping model).
> `docs/webhook-server-plan.md` covers item 4 (cluster-wide raft-replicated
> `webhooks.db` with a leader-pinned webhook-server thread; the per-tenant
> `_outbox/*` row + drainer are dropped because envelope 4 rides with
> envelope 0 in the same raft entry).
> `docs/files-server-plan.md` covers item 5 (files-server moves to its own
> subdomain with manifest-in-S3, marker-driven release).
> Item 2 (tape body capture) is straightforward and remains an
> implementation detail rather than a separate plan.

Five coupled work items, all following the existing file-blob pattern
(bytes on `BlobStore`, raft replicates only the manifest where applicable;
state moves out of raft where stronger guarantees aren't needed):

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

4. **Centralized webhook subsystem (raft-replicated `webhooks.db`).** Today
   `drainOnce` (`src/outbox/drainer.zig:137`) snapshots the entire instance
   set every tick and opens a fresh SQLite connection per tenant for an
   `_outbox/*` prefix scan — ~40k SQLite open+scan ops/sec at 4 ticks ×
   10k tenants, almost all empty. Replace with a single cluster-wide
   `webhooks.db` raft-replicated via new envelope types 4 (enqueue
   batch), 5 (complete), and 6 (retry-schedule). The dispatcher
   accumulates `webhook.send` calls per-handler and proposes envelope 4
   in **the same raft entry as envelope 0 (the writeset)**, so by the
   time the customer response returns (gated on raft commit), the
   webhook is durable cluster-wide. There is no per-tenant
   `_outbox/{id}` row, no apply-hook forwarding, no drainer. Delivery
   runs from a leader-pinned webhook-server thread inside the loop46
   binary; on leader change, the new leader inherits all in-flight
   state via `webhooks.db` with zero scan cost. Detail in
   `docs/webhook-server-plan.md`.

   The earlier "leader-local in v1, raft-replicate later" and
   "transactional `_outbox/*` handoff with apply-hook forwarding"
   positions were both rejected (see §7) — neither paid for the
   complexity once envelope 4 could ride with envelope 0 directly.

5. **Files-server architectural move.** Today the worker holds per-tenant
   `files.db` SQLite + an in-memory manifest cache mirroring files-server's
   local SQLite, kept in sync via raft envelope type 3 + a 2s polling
   refresh. Two replicas of the same state, expensive to keep coherent.
   Replace with: files-server moves to its own subdomain
   (`files.{public_suffix}`) with its own TLS, manifest moves to S3
   (`tenants/{id}/deployments/{dep_id}.json` + `tenants/{id}/blobs/{hash}`),
   runtime release signal becomes a `_deploy/active` kv marker observed
   via the existing post-commit writeset scan (no polling), worker reads
   bytecodes/statics on demand from S3 with content-hash ETags +
   Cloudflare in front. Worker drops the entire `/_system/files/*` proxy
   and the `files.db` per-tenant store (envelope type 3 retires); the §2.4
   routing/cache/path-validation/size-cap rules carry forward unchanged.
   Detail in `docs/files-server-plan.md`. Lower urgency than (a)/(c)
   (files.db doesn't blow up under sustained traffic the way log.db does)
   but unblocks multi-node deployment (S3-backed manifest IS the cross-node
   share path) and removes ~2 replicas-worth of in-process state from the
   worker.

Single-host launch defaults to `FilesystemBlobStore` against the local `{data_dir}`; multi-node launch picks `S3BlobStore` (shipped — see §9 "Blob replication" and §10.5) or a shared FS mount via `BLOB_BACKEND`. The work above is backend-agnostic because `BlobStore` is already the abstraction seam. **First customer can now take real production traffic without disk-fill within weeks.** MVP complete.

The further detach of files-server / log-server into separately-deployed
processes that admin's JS handler calls via `webhook.send` (rather than
the worker proxying) is **post-1.0** — see §10.13 + `files-server-plan.md`
§11.

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
- Billing hookup (Stripe) — implement via `webhook.send` + callbacks to dogfood the Cmd path. Customer id stored at `account/{hash}/stripe_customer_id`.
- **PSL submission** for `loop46.me` (GitHub PR to `publicsuffix/list`). Fire-and-wait; propagation can take weeks-to-months across browser releases. Defense-in-depth only — server-side `Set-Cookie Domain=` stripping from Phase 1 is the authoritative guard.

### Phase 11 — Server-sent events (§2.12)

Detail in `docs/sse-plan.md`. sse-service is a separate process on its own subdomain from inception — there is no "in-worker SSE then detach later" intermediate phase.

- `_rove_sess` cookie: 64-hex-char opaque token, HttpOnly + Secure + SameSite=Lax. Eager mint on handler invocations that arrive without one; `Set-Cookie` added on response. Static asset serving short-circuits before mint.
- `request.session: { id }` global. Null when handler invoked outside browser context (callbacks, signup, system).
- `events.emit(...)` JS global. Implicit-target form (no `to:`) routes to current session; explicit `to: sid | [sid, ...]` for fan-out. Appends to in-memory emit buffer on the request's execution context — no kv writes, no `_events/*` rows.
- **sse-service** (new module `src/sse_server/`): own subdomain `sse.{public_suffix}`, own TLS listener, own h2 server. Routes `GET /v1/{tenant_id}/sse?token=<jwt>` (EventSource connect, JWT-validated) and `POST /v1/emit` (worker → sse-service, fire-and-forget, internal bearer token). Holds per-(tenant, sid) ring cache (30 entries) for reconnect catch-up; emits `rove:resync` sentinel when `Last-Event-ID` hits an evicted entry.
- `pumpEmitsForContext` worker phase: after kv commit, fire-and-forget POST emit buffer to sse-service. 1s timeout; never blocks the customer response.
- `/_session/sse-token` token-handoff endpoint on the customer's app domain (worker-served): reads `_rove_sess`, mints JWT scoped to `(tenant_id, sid, caps)` for 1h, returns it. Customer JS uses the token in the EventSource URL — keeps `__Host-` cookies pinned to the app domain, makes the EventSource a "simple" cross-origin request (no CORS preflight).
- `EventsCaps` struct + `eventsCapsForPlan(plan)` lookup — caps embedded in JWT at mint time. Same shape used for future plan-tiered caps in other subsystems.
- Single sse-service process per cluster. Failover is "process dies, LB picks a replacement, clients reconnect, sentinel triggers refetch." No raft for sse-service, no state migration, no election protocol.
- Has no hard predecessor — depends on §2.6 webhooks (done) + existing kv/h2/handler infra. **Sequencing per §10.16 (2026-04-30): NOT in beta, IS in 1.0** as launch path item #1 — needed for the live use cases (Stripe Checkout, OAuth, AI-agent results) that beta deliberately omits.

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
- `loop46 export-fixture` writes sibling-file pairs (`_tests/from-prod-{id}.mjs` + `_tests/__fixtures__/from-prod-{id}.json`) so fixtures stay offline-runnable.
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
- `POST /_system/dry-run/{id}` endpoint — runs synthetic request through dispatch with always-rollback + propose-disabled. Returns bundle (response, kv writes, would-have-enqueued webhook rows, tape entries) inline; nothing persists.
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
- **Blob backend for multi-node**: shared filesystem mount (`BLOB_BACKEND=fs`) vs `S3BlobStore` (`BLOB_BACKEND=s3`). Both shipped; ops decision per deployment. Single-node launch defaults to `fs` against local `{data_dir}`. See §10.5.

## 6. Relevant existing code

- `src/files/root.zig:14` — content-addressed manifest + blob scheme; Phase 2 extends this.
- `src/files/root.zig:73` — `MAX_PATH_LEN = 192`; reused in path validation.
- `src/tenant/root.zig:459` — `__admin__` KV aliases to root.db. Pivot may keep, repurpose, or deprecate; re-evaluate in Phase 5.
- `src/tenant/root.zig:518` — root-token hash scheme; pattern reused for magic-link tokens (`_magic/{hash}`, 30-min TTL).
- `src/js/worker.zig` — QuickJS snapshot-restore per-request; trigger and callback invocations reuse this.
- `vendor/README.md` — dependency posture (no network installs, everything vendored). Informs Phase 9 SQLCipher-vs-VFS decision.
- `web/admin/` — existing admin UI skeleton. Will be largely rewritten in Phase 5 against the new auth + file API.

## 6a. Sub-plans expanding sections of this document

- `docs/files-server-plan.md` — §2.4 + Phase 5.5 (e) expansion:
  own subdomain, manifest in S3, marker-driven release, async
  load + atomic pointer swap, Cloudflare-fronted static serving.
  Also contains the post-1.0 detach detail (§11) — editor
  bearer-auth flow, deploy-notification path, work-order list,
  latency mitigations.
- `docs/logs-plan.md` — §2.9 + Phase 5.5 (a) expansion: S3-direct
  batches with `.idx.json` sidecars, log-server on
  `logs.{public_suffix}`. Envelope type 1 retires.
- `docs/sse-plan.md` — §2.12 + Phase 11 expansion: centralized
  sse-service singleton on `sse.{public_suffix}` from inception
  (no in-worker phase), response-attached emit buffers,
  `rove:resync` sentinel for cache eviction, JWT token handoff
  from `/_session/sse-token`.
- `docs/webhook-server-plan.md` — §2.6 + Phase 5.5 (d)
  expansion: cluster-wide raft-replicated `webhooks.db` written
  via new envelope types 4/5/6; envelope 4 rides with envelope 0
  in the same raft entry so there is no per-tenant `_outbox/*`
  row and no drainer; the delivery loop is a leader-pinned thread
  INSIDE the loop46 binary (not a separate process — see
  architectural principle below).
- `docs/snapshot-plan.md` — §2.13 + Phase 5.5 (c) expansion:
  per-tenant snapshot indices, S3 transport, no global
  write-pause. Replaces the row-level delta protocol in
  `src/kv/raft_snapshot.zig`.
- `docs/sim-test-framework.md` — §10.7 + §10.8 expansion: simulator
  module, `_tests/` directory, `loop46 test` / `loop46 simulate`.
- `docs/fixture-lifecycle.md` — §10.9 + §10.11 expansion: fixture
  authoring tooling + worker dry-run dispatch mode.
- `docs/agent-surface.md` — §10.10 expansion: skill file, `--json`
  audit, `loop46 doctor`, scoped tokens.

## 6b. Architectural principle: separability follows raft participation

The right axis for "should this subsystem be its own process /
binary / machine" is **whether it participates in raft**, NOT
whether it has a public TLS surface (the original heuristic).

> **Subsystems that participate in raft live in the loop46 binary.
> Subsystems that don't can be split into their own processes /
> machines.**

Participation = reads raft-replicated state, OR proposes
envelopes, OR is leader-pinned by definition.

| Subsystem | Participates in raft? | Where it lives |
|---|---|---|
| worker (customer kv path) | yes (proposes envelope 0; leader-only) | loop46 binary |
| files-server | no (state in S3) | own binary, own subdomain, separable to its own machine |
| log-server | no (state in S3 + local index cache) | own binary, own subdomain, separable to its own machine |
| sse-service | no (state in memory only — ring cache + connection table; no persistence) | own binary, own subdomain, separable to its own machine |
| webhook-server | yes (reads webhooks.db; proposes 4/5/6; leader-pinned) | thread in loop46 binary |
| (future) anything else needing raft state | yes by definition | thread in loop46 binary |
| (future) anything else stateless wrt raft | no | candidate for separate binary |

The principle lets us cleanly answer the "split or not" question
without re-litigating the tradeoffs case by case.

## 6c. Leader-only public surface

Related architectural property: **only the raft leader accepts
customer requests.** Workers run only on the leader; followers are
pure raft replicas with no public listeners. Customer-facing LBs
route the worker subdomain (and the files-server / log-server /
sse-service subdomains) to the current leader; on raft election,
the LB switches.

Implication for the separable subsystems: while files-server /
log-server / sse-service CAN run on different machines from any
raft node (their state is in S3), they're typically deployed on
every node with a leader-pinned active state — same pattern as
webhook-server but at process granularity instead of thread
granularity. Operators who want to scale them independently can,
because nothing in their architecture requires co-location.

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
- **SSE rows in customer's `app.db` under reserved prefix `_events/{sid}/{seq}`**, replicated through raft envelope 0, with a per-tenant retention sweep + Last-Event-ID catch-up over the persisted rows. Rejected (2026-05): SSE is a notification channel, not a source-of-truth state store; the reserved-prefix storage entangled SSE state with customer kv writesets, raft replication, the markDirtyFromWriteset scan, and a 365-line retention sweep — for semantics that are explicitly losable and recoverable via replay. Replaced by `docs/sse-plan.md`: centralized sse-service singleton, response-attached emit buffers, in-memory ring cache with sentinel-on-eviction.
- **Log batches replicated through raft (envelope type 1) + per-tenant `log.db` apply on every node.** Rejected (2026-05): logs are best-effort and lossy by design (PLAN §2.9), don't need raft's strong durability, and forcing them through the raft log dominates cluster bandwidth at scale. Replaced by `docs/logs-plan.md`: per-node S3-direct batch upload + a single log-server process polling S3 to maintain a local SQLite index.
- **Per-tenant `files.db` on every worker mirroring the manifest via raft envelope type 3.** Rejected (2026-05): worker-as-read-only-consumer model is cleaner. Replaced by `docs/files-server-plan.md`: manifest lives in S3, runtime release signal is a `_deploy/active` kv marker on the customer's app.db, worker reads on demand.
- **Worker hairpin proxy `/_system/files/*` and `/_system/log/*`.** Rejected (2026-05): these subsystems should be on their own subdomains (`files.{public_suffix}`, `logs.{public_suffix}`), terminating their own TLS, with token-handoff auth from the customer's app domain. Worker stops mediating their traffic entirely. Per `docs/files-server-plan.md` and `docs/logs-plan.md`.
- **Webhook subsystem leader-local in v1 with per-tenant `_outbox/*` scan recovery on leader change.** Rejected (2026-05): the per-tenant scan is exactly the cost we're trying to eliminate; replicating recovery state via raft from day one removes it. Replaced by `docs/webhook-server-plan.md`: cluster-wide `webhooks.db` raft-replicated via new envelope types 4/5/6.
- **Per-tenant `_outbox/{id}` as the transactional handoff point, with an apply-hook forwarding committed outbox rows into `webhooks.db`.** Rejected (2026-05): the only thing the per-tenant row could buy was customer-visible kv inspection of pending webhooks, which isn't a real customer benefit (customers observe webhook state via callbacks, not by peeking kv). And once envelope 4 can ride in the same raft entry as envelope 0 (the writeset), the handoff happens atomically at propose time — by the time the customer response gates on raft commit, `webhooks.db` is already durable cluster-wide. Replaced by direct envelope 0 + envelope 4 propose at handler-batch commit; the dispatcher accumulates `webhook.send` calls in a per-handler list parallel to the writeset, and the per-tenant `_outbox/*` prefix is gone entirely.
- **Drainer thread doing the actual webhook delivery.** Rejected (2026-05): with `webhooks.db` raft-replicated and webhook-server as a leader-pinned thread, there is nothing left for a drainer to do. No orphan recovery (every committed writeset already has its corresponding webhook rows committed cluster-wide), no fall-back delivery (webhook-server owns delivery), no retry scheduling (envelope 6 covers it). Replaced by deleting `src/outbox/drainer.zig` outright.
- **Webhook-server as a separate binary `rove-webhook-server`.** Considered (2026-05) and rejected. Webhook-server participates in raft (reads `webhooks.db`, proposes envelopes, leader-pinned) — separating across a process boundary forces RPC for proposes and file-share or learner-replication for `webhooks.db` reads, re-introducing the very plumbing the consolidation was supposed to eliminate. The right separability axis is raft participation, not public-TLS-surface presence. Webhook-server lives as a leader-pinned thread inside the loop46 binary; the cluster-wide `webhooks.db` design (envelope types 4/5/6) stays. Architectural principle captured in §6.
- **Pause-and-snapshot raft snapshot strategy** (briefly stopping all applies during VACUUM pass to capture every tenant's `app.db` at a single global raft index). Rejected (2026-05): contradicts the worker-kv-path north star — even a few seconds of cluster-wide write pause every snapshot interval is unacceptable at the "many tenants per node" density. Replaced by per-tenant snapshot indices with always-refresh-all-tenants discipline (`docs/snapshot-plan.md`). The slow-tenant pinning concern is mitigated by the always-refresh trick (dormant tenants get manifest-bookkeeping refresh without re-VACUUM).
- **Static file serving via 302-to-S3 redirect (public bucket or pre-signed).** Rejected (2026-05): considered as a way to take the worker entirely out of the static bytes path, but Cloudflare in front already absorbs essentially all repeat traffic. The marginal further reduction isn't worth a per-deployment flag, public-bucket security model, CSP friction, or per-request HMAC signing. Worker proxies with hash ETag + immutable Cache-Control; Cloudflare does the heavy lifting.
- **Polling `current.json` (or per-tenant `latest.json`) for files-server release detection.** Rejected (2026-05): adds per-tenant LIST/GET cost to every worker every interval. Replaced by `_deploy/active` kv marker observed via the existing `markDirtyFromWriteset` post-commit scan path — no polling, no new envelope type, marker rides through the customer kv writeset that the customer's deploy CLI writes.

## 8. Why this is a compelling product

The uniqueness isn't any single feature — it's the coherence of the set:

- **Purely functional handlers** (no async IO, no fetch, all effects are Cmds).
- **Cmd-pattern outbound path: `webhook.send` is the only door to the outside world**, accumulated alongside the writeset and proposed atomically with kv writes.
- **Deterministic triggers in the same KV transaction as the write.**
- **Tape capture on every request, encrypted at rest.**
- **Browser-based replay with DevTools breakpoints on production bugs.**
- **One URL for the whole app (static + API + admin-of-admin).**
- **Magic-link signup → live API in under a minute.**

Nobody is offering this combination. The marketing headline is the functional core + replay; the developer hook is the one-minute demo. The rest of the plan is making both of those true.

## 9. Implementation status (as of 2026-04-30)

Build sessions between 2026-04-17 and 2026-04-30 shipped Phases 1–4, 6, and 8 (narrow scope), restructured several architectural decisions (flagged in §10), and locked the beta-first launch sequencing in §10.16/§10.17. Current status against the §3 phase list:

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

### Phase 3 — Webhooks + email — **done (initial implementation; will be replaced by Phase 5.5 item 4)**
- `_outbox/*`, `_outbox_inflight/*`, `_dlq/*`, lease-based drainer (the historical shape; `webhook-server-plan.md` replaces it)
- SSRF blocklist + HTTP client + exponential backoff with full jitter
- `webhook.send` JS global with deterministic ids (`sha256(request_id || call_index)`)
- `email.send` JS wrapper (key as explicit arg — vendor-neutral; see §10)
- `crypto.hmacSha256(key, data)` primitive — customers roll vendor-specific signatures themselves
- `X-Rove-Webhook-Id` + `X-Rove-Webhook-Attempt` headers stamped; the planned `X-Rove-Signature` was dropped per §10
- Callback dispatch phase (`dispatchCallbacks`) invokes `onResult` handlers in their own tx
- Inflight lease + stale-lease sweep covers drainer crash recovery
- End-to-end smoke in `scripts/webhook_smoke.sh` against a Python echo target
- **Cutover note**: this whole stack — drainer, `_outbox/*` shape, `_outbox_inflight/*`, `_dlq/*` — is being replaced by the Phase 5.5 item 4 work. The customer-facing API (`webhook.send`, callback shape, X-Rove-Webhook-Id contract) carries forward unchanged; the storage layer and delivery loop swap underneath.

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
- Promoted into MVP scope 2026-04-29. Five deliverables, each with its own sub-plan: (a) log batch payload offload — superseded by `docs/logs-plan.md` (logs leave raft entirely, go S3-direct with sidecar index); (b) tape body capture wired through the pre-staged `tape_refs` + `LogStore.blob` slots, bodies offloaded to `{inst.dir}/log-blobs/` with §2.4's 256 KB truncation; (c) raft snapshot + log compaction — see `docs/snapshot-plan.md` (per-tenant snapshot indices, S3 transport, no global write-pause); (d) centralized webhook subsystem — see `docs/webhook-server-plan.md` (cluster-wide raft-replicated `webhooks.db` via new envelope types 4/5/6, no per-tenant `_outbox/*` row, no drainer; envelope 4 rides with envelope 0 in the same raft entry); (e) files-server architectural move — see `docs/files-server-plan.md` (own subdomain `files.{public_suffix}`, manifest in S3, marker-driven release, worker drops `files.db` + `/_system/files/*` proxy + envelope type 3).
- Without (a)–(c), `raft.log.db` grows unbounded under any sustained traffic and bodies (when added) overwhelm both raft replication and per-tenant `log.db`. Estimate: ~43 GB/day in raft.log.db at 1000 req/s × ~500 B per log record, doubled by apply, ~100× worse with bodies.
- Without (d), the drainer's steady-state tick cost is O(N tenants) — ~40k SQLite open+scan ops/sec at 4 ticks × 10k tenants. The raft-replicated `webhooks.db` design eliminates that per-tick scan; on leader change, the new leader inherits committed state with no per-tenant outbox scan. Webhook intent rides through raft as envelope 4 in the same raft entry as envelope 0 (the writeset), so the per-tenant `_outbox/{id}` row goes away entirely — the handoff IS the propose, and the customer response (gated on raft commit) guarantees `webhooks.db` durability cluster-wide. The drainer is deleted along with the `_outbox/*` / `_outbox_inflight/*` / `_dlq/*` prefixes.
- (e) is lower urgency than (a)/(c) (files.db doesn't fill disk under sustained traffic the way raft.log.db does) but unblocks multi-node deployment — S3-backed manifest IS the cross-node share path — and removes ~2 replicas-worth of in-process state (per-tenant `files.db` + in-memory manifest cache in the worker, both mirroring files-server's authoritative store via envelope type 3 + 2s polling refresh).
- The supersede comment in `src/log/root.zig` header that mentions "Phase 6 changes this so the leader uploads the batch blob to S3" is stale terminology — it predates the current PLAN numbering. Cleanup as part of this work.
- The further detach (files-server / log-server become separately-deployed processes that admin's JS handler calls via `webhook.send`, with the worker no longer proxying) is **post-1.0** — see §10.13 + `files-server-plan.md` §11.

### Phase 6 — Triggers — **done 2026-04-27**
- Path-based registration (PLAN §2.5): `_triggers/users/sessions/index.mjs` fires on writes to `users/sessions/*`. Tree-traversal order across overlapping prefixes — outermost-first BEFORE, innermost-first AFTER. Catch-all via top-level `_triggers/index.mjs` (prefix `""`).
- Named exports for op×timing: `beforePut`, `afterPut`, `beforeDelete`, `afterDelete`, plus `default` as the catchall.
- BEFORE return-value mutates the written value (string return only; non-string returns leave the value untouched).
- Catchable `Error{ code: "trigger_rejected", message: "<trigger_path>: <original>" }` in the handler. Inner savepoint scopes BEFORE chain + actual write + AFTER chain so a throw anywhere rolls back all three (the audit gotcha is real and tested). Uncaught throws bubble to the §11 handler-exception path → 500.
- Cascade depth tracked on `DispatchState`, throws at 8. Platform-key fire-time guard (defense in depth alongside deploy-load guard) — customer catch-alls don't see writes to `_audit/`, `_callback/`, etc. Per-request module-namespace cache so trigger top-level state persists across fires within one request.
- 15 inline dispatcher tests cover registry derivation, BEFORE+AFTER chains, op×timing dispatch + default catchall, tree-traversal order, cascade depth (well-bounded + runaway), platform-prefix block, return-value mutation, audit-gotcha rollback, previousValue exposure, trigger_rejected error shape.
- `scripts/triggers_smoke.sh` end-to-end against a live worker: signup → deploy trigger module + handler → exercise via curl → verify reverse-index built, BEFORE mutation lowercased the value, rejection caught with the right code, afterDelete cleaned up.

### Phase 8 — Rate limiter — **done 2026-04-27 (v1 narrow scope)**
- `src/js/limiter.zig`: `TokenBucket` (capacity + refill_per_sec; `tryTake`, `secondsUntil`), `RateLimitCaps` (request + email pairs), `RateLimiter` (per-instance × per-action map, lazy bucket creation, `check`, `retryAfterSeconds`). 11 inline tests cover bucket math + per-instance/per-action isolation + Retry-After hint.
- `request` action: checked at request dispatch in `worker.zig:dispatchOnce` (before `tryServeStatic` so static file requests count too — they consume worker resources). Admin requests bypass entirely. On exhaustion: 429 with `Retry-After: <seconds>` header via `setRateLimitedResponse`.
- `email` action: checked at the entry of the `email.send` JS wrapper via the `__rove_check_email_rate` hidden builtin. On exhaustion: throws `Error{code:"rate_limited", message:"email rate limit exceeded, retry after Ns"}`. Customer can `try { email.send(...) } catch (e)` and react.
- Per-worker, in-memory only — no cross-worker sync in v1. Multi-worker configs effectively give each instance Nx the configured limit; acceptable overshoot at launch scale.
- Single tier in v1 — `WorkerConfig.rate_limit_caps` is operator-tunable via `--rate-limit-{request,email}-{capacity,refill}` CLI flags. Phase 10 will branch on instance plan tier.
- `scripts/rate_limit_smoke.sh` end-to-end: hammer a tenant past `request_capacity` and verify 429 + Retry-After + body explanation; verify per-instance independence (a second tenant stays at full capacity); verify admin requests bypass; deploy a handler that calls `email.send` in a try/catch and verify the 3rd call surfaces `e.code === "rate_limited"`.
- Deferred from PLAN §2.10's full action list: `deploy` (low volume), `webhook_attempt` (already paced via webhook batch depth + per-destination cap + exponential backoff), `kv_write` (hot path, real per-call cost). Add when concrete demand arises.
- Deferred: per-plan branching, root.db sync for cross-worker coordination, dashboard view of bucket state.

### Phases 7, 9, 10 — **not started**

### Phase 12 — Sim test framework + simulator library — **not started; partially absorbed into beta + 1.0**
- Locked in §10.7 + §10.8 (2026-04-28); scope narrowed by the §10.12 two-path replay wedge (2026-04-30) and the beta-first sequencing in §10.16 / §10.17 (2026-04-30). Detailed plan in `docs/sim-test-framework.md`. **Pure client-side**: simulator module (`src/simulator/`) library-linked into the `loop46` CLI; `ReplaySource`; bundle module extraction; bundle JSON additions; module tape wiring; request body capture; `_tests/` directory + `loop46 test` and `loop46 simulate` CLI subcommands; snapshot machinery; sibling-file fixture export; production strip of `_tests/`. **No server endpoints, no thread pool, no rate-limit action** — worker is unchanged.
- **Beta absorbs**: bundle JSON shape (extracted into `src/tape/bundle.zig`), stubs-library shape (Loop46 globals reading from tape, shared with the `replay.loop46.me` browser-replay page), request body capture into the tape. Beta-path prerequisites for §10.12's Story 1 path and stop being Phase-12-specific work.
- **1.0 absorbs**: nothing additional from Phase 12 — the DAP CLI reuses the beta stubs library directly.
- **Stays post-1.0**: Zig + QuickJS `ReplaySource` (the strict-determinism authority — distinct from the V8-based launch interactive-replay paths), sim test framework + assertions, snapshot machinery, fixture lifecycle, `_tests/` directory + `loop46 test` / `loop46 simulate` subcommands.

### Phase 13 — Fixture lifecycle + worker dry-run — **not started**
- Locked in §10.9 + §10.11 (2026-04-28). Detailed plan in `docs/fixture-lifecycle.md`. Two related pieces: (1) fixture-lifecycle tools (`/_system/kv/{id}/*` admin endpoint, `loop46 kv`, `loop46 fixture` CLI families, runner `--auto-fix-from`); (2) worker dry-run dispatch mode (`POST /_system/dry-run/{id}` endpoint, `dry_run` flag on `dispatchOnce`, `loop46 dry-run` + `loop46 fixture from-dry-run` CLIs). The dry-run path is ~50 lines added to existing dispatch; fixture lifecycle reuses the same kv admin endpoint that backs dashboard KV browser.

### Phase 14 — AI agent surface — **not started**
- Locked in §10.10 (2026-04-28). Detailed plan in `docs/agent-surface.md`. Pieces: skill file at `docs/skills/loop46.md`, `--json` output audit across CLI, `loop46 doctor` env-check subcommand, scoped tokens at `scoped_token/{hash}` with capability + instance subsets, `/_system/scoped_tokens` admin routes, dashboard "Tokens" tab. **No MCP server in v1** — hosted MCP deferred until remote-agent demand surfaces.

### Tape-replay wedge (browser page for Story 1 in beta + DAP CLI for Story 2 at 1.0) — **launch path** as of 2026-04-30
- Locked architecturally in §10.12 (2026-04-28; two-path split 2026-04-30). Beta-first sequencing per §10.16 / §10.17 (decided 2026-04-30): browser page (Story 1) ships in beta; DAP CLI (Story 2) ships at 1.0. Two paths share bundle JSON shape, tape blob format, and stubs library — beta lands all three plus the browser-side consumer; 1.0 adds the CLI orchestration on top.
- **Beta scope**: bundle endpoint + `replay.loop46.me` page + sandboxed iframe + stubs library + `debugger;` injection + "Replay" button + "copy request ID" affordance. ~1-2 weeks.
- **1.0 adds**: `loop46 replay <id>` CLI spawning Node under `--inspect-brk` for DAP-aware editor attach (VS Code / JetBrains / nvim-dap / dap-mode). ~1-2 weeks.
- No Chrome extension, no in-dashboard debugger UI. CodeMirror 6 lands in beta but only for syntax highlighting in the Code tab, not for an integrated debugger view (see §10.12 closing note + §10.16 beta launch list item 3).

### Blob replication (multi-node prerequisite) — **done**
- Raft envelopes include `type=3` files_writeset replicating `{id}/files.db` across nodes — **done**
- Blob bytes (`{id}/file-blobs/*`) are not carried through raft envelopes (a 1MB static per envelope would blow raft-log size/latency budget). Multi-node setups configure a shared `BlobStore` backend via `BLOB_BACKEND=fs|s3`:
  - **`fs`** (`FilesystemBlobStore`) — points at `{data_dir}` on every node, expects a shared mount (NFS / EFS / Ceph). Zero new code; ops responsibility.
  - **`s3`** (`S3BlobStore`) — **shipped**. Path-style + SigV4-signed; works against AWS S3, Cloudflare R2, Backblaze B2, DigitalOcean Spaces, MinIO, OVH Object Storage. Configured via `S3_ENDPOINT` / `S3_REGION` / `S3_BUCKET` / `S3_KEY_PREFIX_BASE` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `S3_USE_TLS`. Smoke-tested via `scripts/s3_blob_smoke.sh` (env vars sourced from repo-root `.env` per `reference_s3_smoke_env.md`).
- Single-node launch defaults to `fs` against the local `{data_dir}`. Multi-node launch picks either backend; both work today.

## 10. Architecture decisions post-2026-04-17

Architectural calls captured here so future sessions don't re-derive them. §10.1–§10.6 from 2026-04-17 to 2026-04-21; §10.7–§10.12 added and iterated 2026-04-28 (earlier drafts had different §10.9 / §10.11 for trial deploys + live-state acceptance tests; both dropped after design review favored the FP-pure client-side simulator path); §10.13–§10.17 added 2026-04-30 covering the post-1.0 detach, the distributed-Elm-ports framing, the post-1.0 observability primitives, and beta/1.0 launch sequencing.

### 10.1 Admin is a real instance with a `platform` capability

**Change**: dropped the `__admin__.kv` aliases-to-root hack. The admin tenant now has its own `{data_dir}/__admin__/app.db` like every other tenant. `Instance.platform: ?*Tenant` points back at the `Tenant` on the singleton admin instance only; the JS dispatcher installs `platform.root.*` globals gated on that field.

**Why**: the aliasing made admin-tenant Cmd records (webhook.send / email.send) unreachable to the delivery path (which expects per-tenant `app.db`, not the root store) and leaked root-store key shapes into admin-handler JS code. Making admin "an instance like any other, plus a capability" solves both — admin-fired webhook batches ride through the same envelope-4 path as customer handlers, and platform-level operations become a well-typed JS surface instead of raw `__root__/…` key writes.

**Side effects**:
- Sessions, magic-link rows, resend key, admin-fired Cmd records all moved from root.db to `__admin__/app.db` (and onward to cluster-wide `webhooks.db` for webhook intent).
- `__root__/` key prefixes dropped — root.db holds only identity+routing tables (`instance/`, `domain/`, `root_token/`).
- `Tenant.create` / `.destroy` replaced `init` / `deinit` (heap-allocated; the `platform` interior pointer requires stable address — rove-library principle 14).
- Admin JS handler rewritten to use `platform.root.*` for root-kv reads/writes.

### 10.2 Root replication via raft envelope type 2

Envelopes today (in shipped code):

| Type | Target store | Producer | Status |
|---|---|---|---|
| `0` writeset | `{id}/app.db` | Customer handler `kv.*` via TrackedTxn + writeset | active |
| `1` log_batch | `{id}/log.db` | Worker `flushLogs` | retires in Phase 5.5 (a) — logs go S3-direct per `docs/logs-plan.md` |
| `2` root_writeset | `__root__.db` | Signup's `tenant.createInstance`; admin JS `platform.root.*` | active |
| `3` files_writeset | `{id}/files.db` | Signup's `deployStarterContent`; files-server `putFileAndDeploy` | retires in Phase 5.5 (e) — manifest moves to S3 per `docs/files-server-plan.md` |
| `4` webhook_enqueue_batch | `webhooks.db` | Worker dispatcher (rides with envelope 0) | added in Phase 5.5 (d) per `docs/webhook-server-plan.md` |
| `5` webhook_complete | `webhooks.db` + tenant `app.db` (`_callback/{id}`) | webhook-server thread | added in Phase 5.5 (d) |
| `6` webhook_retry_schedule | `webhooks.db` | webhook-server thread | added in Phase 5.5 (d) |

Multi-envelope-per-raft-entry support also lands in Phase 5.5 (d) so envelope 0 and envelope 4 can ride atomically in one raft entry.

Type-2 writes come from two producers: the signup HTTP handler (mirrors `tenant.createInstance`'s local write into a root writeset) and the admin JS handler's `platform.root.set/delete` calls (collected into a per-request root writeset, proposed after commit). **Divergence on propose failure is logged, not compensated** — at-least-once semantics consistent with the Cmd/callback layers. A future iteration wraps root writes in a TrackedTxn with undo semantics.

### 10.3 Two-phase deploy protocol on FS backend

Implemented PLAN §2.4's three-leg content-addressed protocol:

- `POST /v1/instances/{id}/blobs/check` → `{missing, uploads}` with upload URLs + method + TTL
- `PUT /v1/instances/{id}/blobs/{hash}` → server hashes on arrival, rejects mismatch
- `POST /v1/instances/{id}/deployments` → full-replacement manifest commit, optional `parent_id` CAS

The `uploads` object's URL is path-relative on the FS backend (client resolves against whichever origin it reached); on the S3 backend (shipped — see §9 "Blob replication") it returns absolute pre-signed S3 URLs and the client follows them verbatim. **Same client code, different backends.** Admin UI JS exposes `api.bulkDeploy(instance_id, files, {parent_id, comment})` that hashes client-side with `crypto.subtle.digest("SHA-256")`, checks, uploads missing in parallel, commits.

### 10.4 `webhook.send` stays vendor-neutral; `email.send` takes key as parameter

**Dropped from PLAN §2.6**: the planned `X-Rove-Signature` HMAC header with per-instance webhook secret. Each destination has its own signing format (Stripe `Stripe-Signature: t=...,v1=...`, Slack `X-Slack-Signature` with a different scheme, AWS SigV4, etc.); a one-size-fits-all HMAC is meaningless to every real destination.

**What ships instead**:
- `crypto.hmacSha256(key, data) → hex` JS global — primitive for customers to roll their own signing
- `X-Rove-Webhook-Id` + `X-Rove-Webhook-Attempt` headers (vendor-neutral; receivers use the id for dedup)
- `email.send({key, from, to, subject, text?, html?, …})` takes the Resend key as an explicit argument. Customer's abuse-control concern: they can only email using a Resend key they provide. Our own magic-link email reads the platform Resend key from `__admin__/app.db` and accumulates a webhook batch entry on the dispatch state (proposed via envelope 4 alongside the writeset); customer handlers never see that key.

### 10.5 Replication-ready blob backend (path B: shared object store) — **shipped**

Ruled out: "raft carries blob bytes." A 1MB static file per envelope would blow raft-log size and commit-fsync budget. Two options for multi-node, both shipped:

- **Shared filesystem mount** (NFS/EFS/Ceph) at `{data_dir}` on every node. Zero code — `FilesystemBlobStore` treats the mount like any other directory. Ops tradeoff: depends on reliable distributed FS.
- **`S3BlobStore` + SigV4 signer**, in `rove-blob`. Targets S3 the *protocol* — works against AWS S3, Cloudflare R2, Backblaze B2, DigitalOcean Spaces, MinIO, OVH Object Storage. Path-style URLs. Credentials via env vars; no IAM metadata fetch in v1 (SSRF carve-out deferred). Smoke-tested via `scripts/s3_blob_smoke.sh`.

Backend pick is process-wide via `BLOB_BACKEND=fs|s3` (+ the `S3_*` / `AWS_*` env vars per CLAUDE.md), threaded through `WorkerConfig.blob_backend`, `ApplyCtx.blob_backend_cfg`, and the files-server / log-server `spawn` so every per-tenant backend opens against the same store. Per-tenant scoping in S3 uses key prefix `{key_prefix_base}{instance_id}/{file-blobs|log-blobs}/`, mirroring the on-disk layout exactly so leader and followers hit identical keys.

OVH setup notes (if that's the target host): use OVH Object Storage "Standard" tier (S3-compatible), pick region matching compute (EU: GRA/SBG; NA: BHS), endpoint `https://s3.{region}.io.cloud.ovh.net`, path-style URLs.

Caching shape for followers: a `CachedBlobStore` wrapper composing local-FS in front of S3 is a future-deferred optimization. Content-addressed → no staleness, just an avoid-the-S3-roundtrip win. Not yet built; pick up if S3 latency starts hurting reads.

### 10.6 dispatchOnce refactored into phase-shaped helpers

The 750-line `dispatchOnce` loop body was split into named helpers:
- `tryHandleSystem` — `/_system/*` proxy routing + preflight
- `resolveRequest` — admin/customer branch → either `.handled` or `.dispatch{handler_inst, scope_inst, is_admin}`
- `finalizeBatch` — end-of-walk commit + propose + move

`dispatchOnce` ended at 388 lines, reading as phase selection. The per-handler dispatch body (anchor → savepoint → run → release → success-record) stays inline — it's linear, context-heavy, and extracting it would threaten more parameters than readability gained.

### 10.7 Simulator primitive (purely client-side, KV-less)

The simulator is a **client-side library only** — no `/_system/simulate/{id}` endpoint, no thread pool, no `simulate` rate-limit action. The worker's job is dispatch (live or dry-run, §10.11) + observation (recording tapes); simulation is purely a client concern. Two implementations share a contract (bundle JSON shape + tape blob format):

- **CLI simulator** (Zig + QuickJS, `src/simulator/`) — linked into `loop46 test` and `loop46 simulate`. Hermetic, deterministic, used in CI and inner-loop dev. Authoritative for strict-determinism replay.
- **Browser-replay page** (V8 in browser, launch-path per §10.12) — interactive replay for Story 1 in a sandboxed iframe at `replay.loop46.me`. Stubs Loop46 globals from the tape, injects `debugger;` at handler entry. Engine differences with QuickJS apply uniformly.

`ReplaySource` is **KV-less** — the dependency surface deliberately excludes `rove-kv` / SQLite. Modes (`strict`, `what_if`, `isolated`) are layer combinations over write-buffer / overlay / tape / miss-policy. **No live-KV pass-through layer**: live-state mixing was rejected as conceptually muddy. Writes go to the buffer only; outbox effects (`webhook.send`, `email.send`) are recorded as "would-have-enqueued" rows, never delivered.

Detail in `docs/sim-test-framework.md`.

### 10.8 Sim test framework (deterministic, local-only)

`_tests/` directory + `loop46 test` CLI subcommand that embeds QuickJS and links the simulator library. **Entirely local** — no worker contact, no auth, works offline; pre-commit hooks, TDD, and CI sim phase all run without network. Injected globals: `simulate(req)`, `expect(value)`, `snapshot(name, value)`. `_tests/` is platform-prefix-guarded and **stripped from production manifests at deploy time**.

Detail in `docs/sim-test-framework.md`.

### 10.9 Fixture lifecycle (curated observations)

Fixtures are **curated observations of production state** — files in `_tests/__fixtures__/` that hold kv data a test uses as `simulate`'s overlay. Two authoring paths: (1) from a recorded request via `loop46 export-fixture --request <id>` (sibling-file pair, snapshot-style), (2) from live state selectively via `loop46 fixture from-keys <key>... --from <instance>`. A "snapshot the whole instance" tool was considered and rejected — too coarse, expresses no intent, instantly stale.

Primitive set: `/_system/kv/{id}/*` admin endpoint, `loop46 kv` CLI family, `loop46 fixture` CLI family, runner `--auto-fix-from <instance>` flag.

Detail in `docs/fixture-lifecycle.md`.

### 10.10 AI agent surface — CLI + skill file in v1, hosted MCP deferred

Loop46's primary AI agent surface in v1 is **the CLI itself**, taught to agents via a skill file. **No MCP protocol server, no `loop46-mcp` binary.** Hosted MCP at `mcp.loop46.me` is deferred until concrete remote-agent demand surfaces — the dominant case (Claude Code, Codex, Cursor in the customer's working tree) already has shell access, and the MCP wins (typed schemas, server-side rate limiting, cross-machine) only matter for remote/hosted scenarios.

What ships in v1: skill file at `docs/skills/loop46.md`, `--json` output on every CLI subcommand, `loop46 doctor` readiness check, and **scoped tokens** at `scoped_token/{sha256_hex}` (capability subset + instance scope). Scoped tokens are independent of MCP — a security primitive worth having for any agent integration.

Detail in `docs/agent-surface.md`.

### 10.11 Worker dry-run dispatch mode

`POST /_system/dry-run/{instance_id}` runs a synthetic request through the existing dispatch path with one behavioral change: the savepoint is **always rolled back, never proposed to raft**. Returns the bundle inline (response, would-have-written kv ops, would-have-enqueued webhook batch entries, captured tape entries); nothing persists. Implementation is roughly 50 lines — a `dry_run: bool` flag on `dispatchOnce` plus a new admin route.

**Distinct from the simulator**: dry-run is literal dispatch (same bytecode, real `app.db` reads, real time/random, real trigger cascades) with commit + propose suppressed. The simulator (§10.7, client-side) handles modified-source / overlay / replay; dry-run answers "what would real dispatch do here, without committing." Cost shape is close to read-only — skips the two expensive parts of a write (SQLite commit fsync + raft propose) — so customers and agents can dry-run liberally.

Detail in `docs/fixture-lifecycle.md`.

### 10.12 Replay — two paths, one per audience: browser page (Story 1) + DAP CLI (Story 2) (PROMOTED to launch path 2026-04-30; two-path split 2026-04-30)

**Change**: tape replay ships as **two paths sharing bundle JSON, tape blob format, and the stubs library** — one optimized for each launch audience (§10.16).
- **Story 1 (new programmer)**: dashboard "Replay" button → new tab on `replay.loop46.me` (sandboxed iframe + global stubs + `debugger;` injection at handler entry). User opens F12 to step through using their browser's own DevTools.
- **Story 2 (engineering team)**: `loop46 replay <request_id>` CLI in the engineer's terminal. Spawns Node.js under `--inspect-brk` with stubs preloaded; their DAP-aware editor (VS Code / JetBrains / Neovim with nvim-dap / Emacs with dap-mode) attaches via V8 Inspector Protocol. They debug in the editor they already live in. **Story 2 is expected to never use the browser path** — the dashboard Logs view's job for them is request-ID discovery (one-click copy on each row → paste into terminal).

**Promoted into the launch path** — see §10.16 for sequencing. The original "deferred until Phase 5 admin UI is mature" stance flipped because tape replay is the load-bearing differentiator: every other Loop46 capability has a competitor that does it better, but **nobody else can let you click a failed request and step through the actual reproducer in your usual debugger**. Story 1 hears "click any 500, hit replay, step through it in F12"; Story 2 hears "`loop46 replay <id>` in your terminal, attach VS Code, step through it in your editor."

**Story 1 path — `replay.loop46.me` page (page-only, "use real DevTools, free")**:
1. Dashboard ships a "Replay" button on each Logs row → opens `https://replay.loop46.me/{request_id}` in a new tab.
2. The replay page hosts an iframe sandboxed with `sandbox="allow-scripts"`, served from a separate origin so dashboard cookies / localStorage stay out of the handler's reach.
3. The iframe page:
   - Fetches bundle + tape from server endpoints (compose, or use a new `/_system/replay/bundle/{request_id}` aggregator).
   - Sets up Loop46 global stubs (`globalThis.kv`, `webhook`, `email`, `Date.now`, `Math.random`, `crypto.*`) that read from the tape.
   - Loads handler modules via `<script type="module">` (with `//# sourceURL=...` for synthesized cases) so source shows up as a real file in DevTools' Sources panel — module imports resolve through an import map populated from the bundle.
   - Injects `debugger;` at handler entry (and optionally at the recorded throw site).
   - Calls the handler with the replay request.
4. User opens F12, lands paused, steps through.

Why this for Story 1: no install, no auth setup, no editor configuration. They click a button, they're in DevTools.

**Story 2 path — `loop46 replay <request_id>` CLI (DAP-attach via Node `--inspect-brk`)**:
1. Engineer copies the request ID from the dashboard Logs view (one-click copy) and runs `loop46 replay <id>` in their terminal.
2. CLI fetches bundle + tape from the same server endpoints the browser path uses.
3. CLI writes a small entry script to a temp dir: loads stubs, dynamic-imports handler modules, invokes `handler(replayRequest)`.
4. CLI spawns `node --inspect-brk=127.0.0.1:9229 <entry>` and prints attach instructions ("In VS Code: pick 'Node.js: Attach' from the Run panel" + a pasteable `launch.json` snippet for first-time setup; equivalent recipes for JetBrains / nvim-dap / dap-mode).
5. Engineer's DAP-aware editor attaches to the V8 Inspector Protocol port. Real breakpoints, watches, call stack, variable inspection — all in their IDE.

Why this for Story 2: Story 2 engineers live in their editor 8 hours a day. Sending them to a browser tab for debugging would be a worse version of tools they already have. The dashboard Logs view is a request-ID-discovery surface; the actual debugging happens in their terminal + editor.

**Why DAP / V8 Inspector instead of writing a custom debugger**:
- **V8's Inspector Protocol is a free byproduct of `node --inspect-brk`.** Every DAP-aware editor has built-in adapters that translate. We don't write a debug adapter — we lean on Node's inspector + every editor's existing tooling.
- **We don't reimplement debugger UI for either audience.** Story 1 gets browser DevTools; Story 2 gets VS Code / JetBrains / nvim-dap. Both are battle-tested.
- **No WASM toolchain.** Shipping quickjs-wasm + a custom debugger would mean ~MB+ wasm binary plus debugger UI from scratch.
- **Same engine for both interactive paths**: V8. The browser runs V8 natively; the CLI runs Node which embeds V8. Engine differences with QuickJS apply uniformly to both interactive paths; sim tests (Phase 12, Zig + QuickJS) remain the strict-determinism authority.

**Tradeoffs**:
- **V8 vs QuickJS engine differences** (BigInt, regex edges, etc.) — acceptable for interactive debugging on both paths; not bit-identical with production. The Phase 12 simulator (post-launch, Zig + QuickJS) is the determinism authority.
- **Node.js becomes a Story 2 runtime dependency.** Almost every Story 2 engineer has it; minor friction for Zig/Rust-only shops who can fall back to the browser path.
- **Engineers using non-DAP editors** (raw vim without nvim-dap, plain Sublime, etc.) — fall back to the browser path. ~5% of Story 2 affected.
- **Less integrated than a dashboard-owned editor + variables panel** would be — but Story 2 wouldn't want that anyway (their editor is the integrated experience), and Story 1 is a button-click away from F12. The dashboard-owned debugger UX is the *wrong* answer for both audiences once they're framed separately.

**What ships at launch**:
- Bundle JSON shape on the worker (deployment + module dependency graph + source per module). New `/_system/replay/bundle/{request_id}` aggregator or composed from existing endpoints.
- Tape blob format consumed as-is from existing tape capture.
- **Stubs library** (Loop46 globals reading from tape) shared between both paths — same JS module, served to the iframe and required from the Node entry script.
- **Browser path**: replay page on `replay.loop46.me` (sandboxed iframe + module loader + `debugger;` injection). Dashboard "Replay" button on each Logs row.
- **CLI path**: `loop46 replay <request_id>` subcommand on the existing `loop46` binary. Loads bundle + tape, writes Node entry script, spawns under `--inspect-brk`, prints editor-specific attach instructions.
- **Logs row affordance**: one-click copy of request ID for terminal paste — equally useful to Story 1 ("can I just send my friend the failing request?") and Story 2.

**Synergy with Phase 12** (post-launch sim test framework + Zig+QuickJS strict-determinism simulator):
The bundle JSON shape, stubs-library design, and request body capture into the tape all land at launch as part of this work. Phase 12's *Zig + QuickJS deterministic CLI simulator* (`loop46 test`, `loop46 simulate`, `_tests/` directory, snapshot machinery, fixture lifecycle) is **still post-launch** — different engine, different purpose (deterministic CI authority, not interactive debug). What Phase 12 absorbs at launch: bundle module extraction (`src/tape/bundle.zig`), stubs-library shape, request body capture wiring. What stays post-launch: the Zig + QuickJS `ReplaySource`, the test framework + assertions, fixture tooling.

**Side effects**:
- New origin to provision (`replay.loop46.me`) under the existing `*.loop46.me` wildcard cert.
- The bundle JSON + tape format become a semi-public contract (consumed by browser page, CLI, eventually Phase 12 simulator).
- `loop46 replay` is the first launch-path CLI subcommand. Phase 7 (`loop46 deploy`, `kv`, `logs`) is still post-launch, but the `loop46` binary growing subcommands incrementally is fine — `loop46 dev` / `loop46 worker` already exist.

**Chrome extension dropped entirely.** Earlier drafts of §10.12 considered a Chrome extension as a CDP bridge to an in-dashboard debugger UX (CodeMirror 6 viewer + breakpoint gutter + variables panel + step controls). The two-audience framing makes that the wrong answer for both audiences: Story 1 gets a simpler experience from browser DevTools directly; Story 2 gets a strictly better experience by debugging in their actual IDE via DAP. No post-launch enhancement path for the extension is recorded — DAP attach is the durable answer for the integrated UX Story 2 wants.

### 10.13 files-server + log-server further detach (post-1.0)

The Phase 5.5 architectural moves (item (a) for log-server, item (e) for files-server) put both subsystems on their own subdomains with their state in S3, but the worker still proxies dashboard / CLI traffic to them via `/_system/files/*` and `/_system/log/*`. The post-1.0 further detach drops that proxy entirely: `rove-files-server` and `rove-log-server` become **external HTTP services that loop46 integrates with the same way it integrates with Resend or Stripe**. Admin's JS handler calls them via `webhook.send`, receives results via callback dispatch, and pushes the result to the dashboard browser via SSE. The dashboard never talks to files-server / log-server directly — admin's JS is the integration seam. Worker drops another ~2-3k lines (`/_system/files/*` and `/_system/log/*` proxies, `code_proxy` / `log_proxy` collections, the cross-thread h2 client, `extractAdminAuth` and friends).

Sequencing is **post-1.0** — architectural purification that doesn't differentiate value to Story 1 (beta) or Story 2 (1.0). With SSE shipping at 1.0, the prerequisite is satisfied; the detach becomes a clean refactor gated only on engineering bandwidth.

Detail (latency mitigations, editor bearer-auth flow, deploy-notification path, work-order list) in `docs/files-server-plan.md` §11.

### 10.14 Distributed Elm ports: webhook + callback + SSE (decided 2026-04-30)

**Framing**: Loop46's customer model is **Elm with distribution**. Pure handler functions (`request × kv → response × cmds`); explicit Cmd-shaped side effects via `webhook.send` and `email.send`; Sub-shaped reactive intake via triggers (kv-write subscriptions), callback handlers (webhook-result subscriptions), and SSE (server-pushed events to client). The combination is **distributed Elm ports** — typed channels between pure-functional handlers and the imperative world.

This isn't just a metaphor. The architectural claim is: real-world reactive applications can be expressed in Loop46's pure-functional handler model *without escape hatches*, because every imperative concern (HTTP I/O, time, retries, browser updates, third-party integrations) has a port-shaped primitive.

**Cmd taxonomy: two axes, four quadrants.** The handler's outputs are governed by two axes — whether deliveries are **batched** (combined with sibling Cmds before going out) or **unbatched** (one delivery per emit), and whether they're **guaranteed** (at-least-once with retry / commit-with-writeset) or **best-effort** (lost on crash / backpressure / eviction). The four quadrants each have a named platform verb today or in the speculative-post-1.0 sketch:

|  | Best-effort | Guaranteed |
|---|---|---|
| **Unbatched** | `events.emit` (SSE — push to current connections, lost if no listener) | `webhook.send` (HTTP POST with retry / DLQ / callback) |
| **Batched** | log emit (auto-captured per request, lossy on node failure per `docs/logs-plan.md`) | `analytics.track(transacted)` (post-1.0 sketch in §10.15 — commits with writeset, drained to OLAP) |

**Ports are platform-declared, not customer-declared.** Each named verb IS a port — it's just declared by the platform rather than by customer code. The (batched, guaranteed) tuple is a property of the destination's *nature* (an OLAP sink wants batches; an arbitrary HTTP webhook can't be batched across destinations; a browser EventSource has no ack channel so guaranteed delivery is undefined), not a property the caller picks per-call. Letting customers declare arbitrary ports would push that decision onto them without the context to make it well — they don't know whether a given platform destination is per-record HTTP or columnar batch ingest. So ports stay platform-declared; if a fifth use case emerges that doesn't fit the four named verbs, we add a fifth named verb (and platform-decide its tuple).

A literal unified `send({batched, guaranteed, ...})` API was considered and dropped — same reasoning. Per-call parameterization wouldn't carry the weight (those parameters are channel properties, not call properties), and per-channel parameterization would require customer-declared ports. Per `feedback_compose_from_primitives.md`: every primitive added is forever; the four named verbs cover the four quadrants without locking us into a shape we can't yet justify.

**Customer third-party auth toolkit**:
- **Stored keys**: customer puts API tokens in kv (`kv.set("stripe_secret", "sk_live_...")`).
- **Arbitrary headers**: `webhook.send({ headers: { Authorization: "Bearer " + kv.get("stripe_secret") } })` covers Bearer, API-Key, custom-header.
- **HMAC per-request signing**: `crypto.hmacSha256(key, canonicalRequest)` covers AWS SigV4, Twilio, Stripe webhook verification, etc.
- **OAuth refresh flows**: refresh token in kv; on-401 callback handler mints fresh access token via `webhook.send`; new access_token written back to kv. ~30 lines of customer JS, no new primitive.

**Audit gap-fills** (add when concrete demand surfaces, not pre-emptively):
- `crypto.base64Encode(Uint8Array) → string` and `crypto.base64Decode(string) → Uint8Array`. Twilio basic-auth needs it; QJS-ng has no built-in `btoa/atob`. ~30 lines (Zig native via `std.base64`).
- `crypto.hmacSha1(key, data) → hex`. AWS SigV2 (legacy), Twilio request signing. ~10 lines, mirrors `hmacSha256`.
- **Deferred**: RSA/ECDSA signing (GitHub Apps, Google service accounts, Apple Push). Bigger surface; HMAC-signed JWTs cover a meaningful subset.

**Editor auth (dashboard-internal)** is orthogonal to the customer third-party auth toolkit — the cookie-to-bearer flow only makes sense for clients that *have* a Loop46 cookie session. The flow specifics (`/v1/files-token` endpoint, HMAC-signed bearer, 5-minute TTL, files-server-side validation without admin round-trip) live in `docs/files-server-plan.md` §11.4.

### 10.15 `analytics.track` and `metrics.*` — speculative, post-1.0

Two future observability primitives are explicitly held back per `feedback_compose_from_primitives.md` ("every primitive added is forever — defer the dedicated API until concrete customer demand"). Both fill the **batched** row of the §10.14 Cmd taxonomy:

- **`analytics.track(event)`** — fills the (batched, guaranteed) quadrant. Fire-and-forget bulk-batched event emit into an OLAP-shaped sink. Distinct from `webhook.send` (request/response with retry-to-DLQ); same architectural family (structured data via a port), different ergonomics. Two-tier durability sketch: `best_effort` (in-memory buffer, periodic batch flush — fills the (batched, best-effort) quadrant alongside platform logs) and `transacted` (commits in the originating writeset, same machinery as `webhook.send`'s envelope-4-with-envelope-0 propose). North-star claim worth recording: logs would become a specific case of this primitive once it exists.
- **`metrics.*`** — pre-aggregated counters / gauges / histograms flushed to a TSDB push gateway. Distinct from `analytics.track` because aggregation happens in worker memory, not per-event storage. Cardinality guardrails (per-metric label cap, UUID-shape detection on label values) would be a real differentiator over Prometheus / OpenTelemetry SDKs.

**Both are post-1.0.** v1 customers compose: `webhook.send` to their OLAP / TSDB of choice for events and metrics; the existing logs surface (`/_system/log/*`) for request-level data. Workable, not great. The dedicated primitives become the answer when (a) concrete customer demand for high-volume custom observability surfaces and (b) operator-deployed companion services (`loop46-olap`, `loop46-tsdb`) exist as the receivers. Those probably co-arrive — the receiver is what motivates the primitive; the primitive is what makes the receiver usable.

**Launch pitch already works without these.** Tape replay (§10.12) is the wedge: "click any 500, step through it in your browser DevTools or your editor via DAP." Events + metrics complete the three-layer observability story (events / metrics / tapes ≈ logs / metrics / traces, with replay replacing sampled traces) but the wedge sentence stands without them.

### 10.16 Launch sequencing: lead with replay, two-audience framing locked in (decided 2026-04-30)

**Two audiences served by one product**, both motivating the build from day one:

- **"Story 1 — the new programmer"**: brand-new dev, helped by a friend, currently stuck composing Firebase = Google account + billing account + Firebase console + Firestore + Cloud Functions IAM + three different log views just to add a persistent leaderboard. Loop46 collapses all of that to magic-link signup + one dashboard + kv-comes-free + zero permissions to configure. When her app breaks (it will), she has zero mental model for `gcloud logs read` — she just clicks the failed request in her dashboard. Tape replay is what turns "I give up" into "oh, I see what happened."
- **"Story 2 — the engineering team"**: small team, junior-to-senior, perpetually rebuilding ad-hoc observability stacks (Sentry + Datadog + LogRocket + a homegrown webhook outbox), and shipping the same classic transaction-boundary / read-modify-write race bugs every quarter. Loop46's writeset model serializes those races structurally (SQLite IMMEDIATE locking serializes concurrent r-m-w on the same kv keys; the writeset's all-or-nothing commit eliminates "I forgot to wrap this in a transaction"). The observability stack is built in, the webhook outbox is durable by default, the senior engineer's accumulated wisdom about "things teams keep messing up" is baked into the platform.

The framings differ but the product is identical: **Story 1 hears "ship in minutes"; Story 2 hears "step through it in your browser"**; same launch sentence ("Build a working app in minutes. When it breaks, you can see exactly why and step through the reproducer in your browser") serves both.

**Tape replay is the wedge.** Every other capability has a competitor that does it better — Cloudflare Workers is faster, Vercel has slicker DX, Supabase is more familiar (Postgres-shaped), Firebase has the brand. None of them can match **per-request browser-DevTools replay**. The pure-functional handler choice + tape capture for all non-determinism + the dashboard replay page (§10.12) is the combo that uniquely enables this. Without replay shipped at launch, the differentiation pitch is hand-wavy ("we capture deterministic tapes"); with it shipped, the pitch is concrete ("click any 500, debug it"). That sentence is the difference between "interesting weird platform" and "I have to try this."

**Sequencing — beta-first launch (decided 2026-04-30).** Open beta with Story 1 scope ~3-5 weeks from this decision; 1.0 adds Story 2 scope another ~9-13 weeks later. Beta is **web-only, free-tier-only, no CLI**. See §10.17 for beta operational specifics (data-continuity promise, free-tier caps, banner, feedback channel, no-CLI positioning).

**Beta launch path** (Story 1 audience):

1. **Phase 5 dashboard polish** — instance health indicators, logs view discoverability for Story 1, "Replay" button on Logs rows, "copy request ID" affordance. ~2 weeks.
2. **Tape-replay browser page** (§10.12 Story 1 path) — bundle JSON shape on the worker (compose from existing endpoints, or new `/_system/replay/bundle/{request_id}` aggregator), sandboxed iframe replay page on `replay.loop46.me`, stubs library (Loop46 globals reading from tape), `<script type="module">` source loading, `debugger;` injection at handler entry. ~1-2 weeks.
3. **CodeMirror 6 syntax-highlighting upgrade for the Code tab** — replaces the existing `<textarea>` with a CM6 `EditorView`. Language modes by file extension: `.mjs` / `.js` → `@codemirror/lang-javascript`, `.html` → `@codemirror/lang-html`, `.css` → `@codemirror/lang-css`; default plain text. Line numbers + basic editing extensions. **Out of scope for beta**: autocomplete, lint, fold gutter, breakpoint gutter, draft workflow integration. Vendored bundle (no third-party CDN at runtime). ~½ week.
4. **Phase 14 LLM skill file** (`docs/skills/loop46.md`) — AI-assisted Loop46 coding. Without it, LLMs default to imperative `await fetch()` patterns that don't compile. ~1 week.
5. **Story 1 leaderboard example tenant** — the literal Firebase-pain demo, 5 lines of handler + one HTML page. ~½ day. Pairs with the beta launch post.
6. **Beta operational** — free-tier caps wired to existing rate limiter defaults, beta banner in dashboard, data-continuity promise visible at signup, feedback channel link, per-account storage cap enforcement. ~3-5 days. Detail in §10.17.

**Beta total**: ~5 weeks serialized; ~3 weeks with two-person parallelization (Phase 5 polish + replay page parallelize cleanly; CodeMirror upgrade lands alongside Phase 5 polish without coupling).

**1.0 launch path** (Story 2 audience adds, builds on top of operating beta):

1. **SSE primitive (Phase 11 / §2.12).** Single sse-service process on its own subdomain (`sse.{public_suffix}`); long-lived HTTP/2 streams from customer browsers; per-(tenant, sid) ring cache for reconnect catch-up. Worker `events.emit(...)` appends to an in-memory emit buffer; after kv commit, worker fire-and-forget POSTs the buffer to sse-service. JWT token handoff from the customer's app domain (`/_session/sse-token`) keeps `__Host-` cookies pinned. Browser uses native `EventSource`. Single-process v1: failover is "process dies, LB swap, clients reconnect, sentinel triggers refetch." Detail in `docs/sse-plan.md`. ~3 weeks. **The "first patterns sticky" risk dissolves under beta sequencing**: beta docs deliberately omit live use cases (Stripe Checkout, OAuth, AI-agent results, slow API calls) entirely, so SSE arrives at 1.0 as the *first* answer for those flows, not as a replacement for established polling.
2. **Tape-replay DAP CLI** (§10.12 Story 2 path) — `loop46 replay <request_id>` CLI fetching bundle + tape, writing a Node entry script with stubs preloaded, spawning under `--inspect-brk`, printing attach instructions for VS Code / JetBrains / nvim-dap / dap-mode. Reuses the stubs library shipped in beta. ~1-2 weeks.
3. **Loop46-the-project Stripe integration for supporter payments** — *the real production integration that doubles as the customer-facing docs example.* Loop46's admin handler exposes a "support Loop46" page that creates a Stripe Checkout session via `webhook.send`, returns a tiny shell page that subscribes via SSE, the callback `events.emit`s the session URL to the connected client, browser navigates. Receives `checkout.session.completed` webhook with timing-safe HMAC signature verification, writes a `supporter/{email}` row in admin's app.db, fires another SSE event so the originating tab updates to "Thanks!" without a refresh. **Docs example is extracted from this**: the patterns we actually use become the patterns we teach. ~1.5-2 weeks, plus the small primitives audit (`crypto.timingSafeEqual` confirmed; `base64Encode/Decode` and `hmacSha1` if needed).
4. **Phase 7 `loop46 deploy` CLI** subset — content-addressed two-phase upload, `loop46.json` parsing, deploy-token issuance UI in dashboard. ~1-2 weeks for v1 scope; later CLI subcommands (`kv`, `logs`, `init`) deferred.
5. **Plan tiers + paid pricing** — first paid tier, plan-tier branching in rate limiter caps, billing wiring via Stripe (uses item 3's primitives). ~1-2 weeks.
6. **Custom domains** (Phase 10) — customer CNAME + per-domain Let's Encrypt. ~2 weeks.

**1.0 additional**: ~9-13 weeks serialized; ~5-7 weeks parallelized.

**Total time to 1.0**: ~14-18 weeks serialized; ~8-10 weeks parallelized. **~3-4 months from this decision**, with beta operating in production for ~2-3 of those months gathering real-user signal.

Phase 9 encryption at rest joins the 1.0 path only if B2B compliance demand surfaces during beta — otherwise it stays post-1.0.

**Why dogfooding Stripe (item 2) matters beyond the credibility argument**:
- **Authenticity**: every "Loop46 + Stripe" code snippet in the docs is code we actually run in production. No theoretical-best-practice patterns that fall apart on first contact with real Stripe API quirks (idempotency keys, webhook ordering, test-vs-live mode handling, the dual-redirect dance for Connect onboarding).
- **Funding**: Loop46 the project costs money to operate (hosting, domain, eventual TLS, mkcert isn't forever). A supporter model lets people who get value from the platform contribute, sustaining the project without VC dependence.
- **Forces us to think like a customer**: building Stripe integration *as a customer of our own platform* is the cleanest possible test of "does this primitive set actually work for a real production integration." If we hit friction, we fix the platform — and customers benefit. The friction we don't fix becomes the friction we document. Either way customers win.
- **Failure-mode audit**: real money is real stakes. The webhook signature timing-safe-equal becomes load-bearing when it's *our* customers' card charges flowing through it. We'll discover the actual gaps in the toolkit far faster than a contrived example would surface them.

**What's NOT in beta but lands at 1.0**:
- SSE primitive
- DAP CLI replay (`loop46 replay`)
- Stripe-on-Loop46 supporter payments
- `loop46 deploy` CLI
- Plan tiers + paid pricing
- Custom domains
- Phase 9 encryption (only if B2B compliance demand surfaces during beta)

**What's NOT in either beta or 1.0** (recorded so future-us doesn't second-guess):
- §10.13 / §10.14 file-server + log-server detach + bearer-auth dogfooding. Multi-week refactor that makes the architecture purer but doesn't make the product more useful to a first user. **Post-1.0** when the dashboard-to-file-server path's in-process proxy starts hurting (it doesn't yet). With SSE shipping at 1.0, §10.14's prerequisite is satisfied — the detach is gated only on engineering bandwidth, not blocking primitives.
- §10.15 `analytics.track` + `metrics.*` primitives. Their absence is workable (customers `webhook.send` to their OLAP / TSDB of choice). **Post-1.0** alongside the loop46-olap / loop46-tsdb pseudo-third-party companion services that motivate them.
- **Multi-instance sse-service + persistent emit buffering**. The 1.0 SSE is a single sse-service process with a 30-entry ring cache for reconnect catch-up; cross-instance fan-out and replay-after-restart wait until usage exposes whether they actually matter. The single-process bet matches "customers fit on dedicated bare metal" and lets the `rove:resync` sentinel handle reconnect cases where the ring's been evicted.
- Phase 5.5 storage scalability (log batch offload, tape body capture, raft snapshot, centralized webhook subsystem, files-server architectural move). Matters when sustained production traffic forces it; not at beta or first-1.0 volumes.
- **Phase 12 / 13 sim test framework + fixture lifecycle + worker dry-run**. Beta absorbs the bundle JSON shape, stubs library, and request body capture (§10.12); the Zig + QuickJS strict-determinism `ReplaySource` + sim test framework + fixtures wait. Post-1.0.

**Marketing surface this locks in** (one-sentence variants for different channels):

*Beta launch* (Story 1 audience):
- *General audience*: "Build a working app in minutes. When it breaks, see exactly why and step through it in your browser."
- *Indie-dev pitch*: "Skip the 47 setup steps Firebase makes you do. Sign up with email, get an API + database + dashboard. Build your leaderboard in 5 minutes."
- *AI-coding pitch*: "Tight, narrow handler surface that LLMs can't get wrong + deterministic per-request replay that turns LLM-generated bugs from frustrating into delightful. The AI-friendly platform."

*1.0 launch adds* (Story 2 audience):
- *Senior-engineer pitch*: "Pure-functional handlers eliminate the transaction-boundary / race-condition class of bugs structurally. Built-in observability with full per-request replay (browser or your IDE via DAP attach). Every external integration goes through a durable outbox by default. Stop building this stuff yourself."

All four variants are TRUE — they're not different products, they're different cuts of the same observation.

### 10.17 Beta launch operational specifics (decided 2026-04-30)

Operational items required to open Loop46 beta to external Story 1 users. All small, all needed before the dashboard URL gets shared publicly.

**Free tier scope**:
- Existing per-instance rate-limiter defaults (`request` + `email`) become the free-tier caps. Operator-tunable via `WorkerConfig.rate_limit_caps` from §8.
- Per-account instance cap visible to customers (the Phase 4 hardcode becomes an explicit displayed cap).
- Per-account total-storage cap (sum across all that account's instances) — enforced at deploy time, small addition over Phase 2's per-instance caps.
- No paid tier in beta. Stripe-on-Loop46 supporter payments ships at 1.0.

**Data-continuity promise**:
- Visible at signup and in the beta banner: *"Your data carries forward to 1.0. Beta data will not be wiped."*
- Binding commitment. Schema changes during beta require migration, not reset. Tape replay (§10.12) provides natural fixture data for migration testing.
- If a migration becomes prohibitively expensive, the framing has to change to "preview" without that promise — don't break the commitment silently.

**Beta banner**:
- Persistent banner in `app.loop46.me` shell: *"Loop46 is in beta. [Feedback]."* Click opens the feedback channel.
- Dismissible per-session (so users see it again next visit).
- Removed at 1.0 launch.

**Feedback channel**:
- Single low-friction surface (email address, forum, or Discord — pick whichever captures most signal).
- Goal: surface real Story 1 needs informing 1.0 priorities (does SSE matter? custom domains? does the basic editor frustrate? do they hit the "I want to integrate Stripe" wall?).

**Sign-up gating**:
- Open beta. No waitlist, no invite codes — friction-free is the point. Rate limiter + storage caps keep first ~thousand users tractable.
- Reserve the right to introduce a waitlist if abuse or capacity becomes an issue.

**No-CLI positioning**:
- Beta docs explicitly say *"All workflows are dashboard-driven. CLI ships at 1.0."* Pre-empts "where's the CLI?" feedback from Story 2 visitors and lets them self-select to wait.
- The `loop46` binary during beta only ships operator commands (`loop46 dev`, `loop46 worker`) — no customer-facing subcommands.
- Beta docs omit live use cases (Stripe Checkout, OAuth code exchange, AI agent results, slow API calls) entirely rather than teaching polling for them. SSE arrives at 1.0 as the *first* answer for those flows.

**Beta-open checklist** (items to complete before public URL):
- Beta banner + feedback link in dashboard shell
- Per-account storage cap enforcement
- Free-tier caps documented at `app.loop46.me/docs/limits`
- Data-continuity promise text in signup flow
- End-to-end smoke test: signup → magic link via prod Resend → deploy starter via Code tab → trigger a 500 → click Replay → step through in browser DevTools

Total: ~3-5 days, included in §10.16 beta launch path item 6.

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

- **Magic link TTL 30 min, single-use.** A redeemed link 401s on replay. (Was 15 min in early drafts; bumped 2026-04-30 so click-late users land on the happy path — see §9 Phase 4 amendments.)
- **Session cookie is `HttpOnly + Secure + SameSite=Lax`.** `Secure` requires HTTPS; localhost is treated as a secure context by modern browsers, but plain-HTTP non-localhost dev won't get the cookie. Use `curl -H 'Cookie: rove_session=...'` manually for HTTP-only dev.
- **Signup without Resend key configured** → response body carries `magic_link` in-band so dev + CI smoke tests still work. When a key IS configured, `magic_link` is suppressed and the email is queued via outbox.
- **Reserved instance names** rejected with 409: `admin`, `api`, `app`, `www`, `__admin__`, `auth`, `login`, `signup`, `logout`, `dashboard`, `static`, `system`, `public`, `root`, `mail`. Collisions on real signups also return 409 with the same body (no enumeration).

### Admin scope + platform capability

- `platform.*` JS globals exist only on the `__admin__` handler. Other tenants' handlers see `platform === undefined` and get a `TypeError` if they try to call `platform.root.*`.
- **`X-Rove-Scope: <instance_id>` header** rebinds the admin handler's `kv` to the target tenant's `app.db`. Without it, `kv.*` on the admin handler operates on admin's own `app.db` (NOT root — that's the §10.1 change).
- **Admin JS writes to `platform.root.*` are replicated via type-2 root writeset**, but they land locally on the leader first and propose-on-commit. A propose failure leaves leader/follower divergence (logged, not compensated).

### Multi-node setup

- Customer KV writes, request logs, root metadata, and files.db manifests all replicate via raft. **Blob bytes do not.**
- Running more than one node requires either a shared filesystem mount at `{data_dir}` (NFS/EFS/Ceph) or the shipped `S3BlobStore` backend (`BLOB_BACKEND=s3` + the `S3_*` / `AWS_*` env vars). Both work today.
- Tape bodies (Phase 5.5 b — staged but not wired) live in `{inst.dir}/log-blobs/` only on the leader; on leader change, replay for old request IDs would 404 until that phase ships.
- On leader failover, the new leader has full manifests but may 503 on any blob not yet served by the shared backend (FS mount serves them transparently; S3 backend serves them on first read).
- Webhook delivery: today's drainer is leader-pinned and does an O(N tenants) scan of `_outbox/*` on leader change to enqueue any pending webhooks (Phase 5.5 d eliminates this with cluster-wide raft-replicated `webhooks.db`).
- `raft.log.db` grows unbounded under sustained traffic until Phase 5.5 c (snapshot + log compaction) ships.

### Operational

- `--bootstrap-root-token <hex>` seeds the operator bearer token at startup. Token can be any 32–128 printable ASCII chars; hex is convention not requirement.
- `--bootstrap-resend-key <key>` seeds the platform Resend key into `__admin__/app.db`.
- `--public-suffix <domain>` enables wildcard `{id}.<domain>` → instance routing. Without it, every host needs an explicit `assignDomain` entry.
- `--admin-api-domain <domain>` routes that host's traffic through the `__admin__` handler with auth. Separate from `--public-suffix`.
- `--dev-webhook-unsafe` enables loopback + plaintext webhook targets for local smoke tests.
