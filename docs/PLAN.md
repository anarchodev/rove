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
- **Magic-link signup**:
  1. `POST /v1/signup` with name + email.
  2. Server validates name available, creates instance, deploys starter content, assigns `{name}.loop46.me`, mints magic token (32 bytes, 15-min TTL, single-use, hashed under `_magic/{hash}`), fires `email.send`.
  3. User clicks `GET /v1/auth?mt=...` → server validates, sets session cookie, 302 to `/dashboard#{name}`.

**Why cookies, not bearer tokens?** Bearer tokens work on every browser and every origin, but they require customers to write `headers: { Authorization: 'Bearer ' + token }` on every fetch and manage token storage themselves. Cookies, made first-party by the one-origin-per-tenant layout, recover the "simple fetch" developer story with no setup. Bearer tokens remain as a documented fallback for customers whose UI lives on a genuinely external host (Neocities, GitHub Pages, etc.).

**Why no `env` / secrets primitive?** Considered a write-only env API (`PUT /env/{key}` but never a `GET` that returns values). Rejected because any handler can deploy code that reads the value and returns it — so the write-only UI is ceremony, not real defense. Secrets are just KV entries; page-level encryption at rest provides the actual protection. Customers pick their own naming convention (`config/*`, `secrets/*`, whatever). If we want a "mark this key as sensitive → show dots in dashboard" affordance later, that's a UI flag, not a new storage primitive.

### 2.3 Execution model

**Handlers are pure functions of `(request, kv_snapshot)`.** Deterministic only.

- No `fetch`, no `setTimeout`, no uncaptured `Date.now()` / `Math.random()`.
- All external effects route through `webhook.send` (see 2.7).
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

#### Registration via file convention

```
_triggers/
    00_secrets_audit.mjs
    10_users_index.mjs
    50_orders_totals.mjs
```

```javascript
// _triggers/secrets_audit.mjs
export const config = {
  prefix: "secrets/",
  timing: "after",           // "before" | "after"
  ops: ["put", "delete"],    // default: both
};
export default function (event) {
  kv.put(
    `_audit/${event.timestamp}-${event.key}`,
    JSON.stringify({ op: event.op, key: event.key, actor: event.actor })
  );
}
```

Triggers are part of the deployment manifest — versioned with code, rolled back atomically. No runtime `triggers.register()`.

#### Event object

```javascript
{
  key, value, previousValue, op: "put" | "delete",
  timestamp,
  actor: { request_id, ... } | null,
  depth: number,     // 0 for user-initiated writes
}
```

#### Semantics

- **Synchronous, in-transaction**. Throw → rollback including the originating write.
- **BEFORE** can reject or mutate value. **AFTER** can cascade to further KV writes in the same transaction.
- **Prefix match only**. Multiple matches fire in **lexical order** of filename.
- **Cascades allowed**, depth limit 8. Platform-reserved prefixes (`_audit/`, `_deploy/`, `_outbox/`, `_magic/`) are un-triggerable from customer code.
- **Same deterministic rules as handlers**: no `fetch`, no async IO, no uncaptured nondeterminism. Trigger CPU time counts against the request's shared 10ms envelope (2.3) — no separate per-trigger budget.
- **Raft**: leader runs triggers; replicated log entry contains the *final write-set*, not the original write. Replicas apply atomically without re-running JS. This is the only way to stay deterministic given potential future nondeterminism in triggers.
- **Tape replay**: triggers re-fire automatically when kv ops are replayed — breakpoints in trigger code work on replay.

#### Limits (v1)

- CPU time counts against the request's shared 10ms envelope. No separate per-trigger wall-clock cap.
- 1MB total writes per invocation.
- Depth 8.
- 32 triggers per instance (plan-tier).

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

- Magic-link primitive: `_magic/{hash}` in root.db, 15-min TTL, single-use.
- Session cookie: opaque token, revocable, stored in root.db.
- `POST /v1/signup`: validate, create instance, deploy starter content, enqueue magic-link email.
- `GET /v1/auth?mt=...`: validate, set cookie, 302 to dashboard.
- `POST /v1/logout`: clear cookie, revoke session.
- Starter content: one `index.mjs` (uses `kv`, returns JSON), one `_static/index.html` that fetches it and shows "your API is live at `{name}.loop46.me`".

### Phase 5 — Minimal admin UI (MVP boundary)

- Deploy admin UI to `app.loop46.me` **using Phase 2's file API**. Dogfood.
- Pages: signup/login, dashboard home, instance detail with tabs (Code, KV, Logs, Deploys).
- CodeMirror 6 in Code tab. Save-draft + Deploy buttons.
- Deploy history with diff view.
- Logs tab uses existing `rove-log` surface; add `deployment_id` display.
- **First customer can now sign up, deploy, see it live, debug.** MVP complete.

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
- Plan tiers wired to rate limiter + size caps + DLQ access.
- Billing hookup (Stripe) — implement via `webhook.send` + callbacks to dogfood the outbox.
- **PSL submission** for `loop46.me` (GitHub PR to `publicsuffix/list`). Fire-and-wait; propagation can take weeks-to-months across browser releases. Defense-in-depth only — server-side `Set-Cookie Domain=` stripping from Phase 1 is the authoritative guard.

## 4. Deferred to v2

These are explicitly not in v1 so future sessions don't accidentally design around them.

- Fan-in aggregation for webhooks (multiple → one callback).
- Async / fire-and-forget webhooks (no callback).
- Circuit breaker per destination URL.
- Per-destination rate shaping.
- Read triggers (`on get`).
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

### Phase 4 — Signup + auth — **done**
- `mintMagic` / `redeemMagic` primitive (15-min TTL, single-use, hashed-at-rest)
- `POST /v1/signup`: validates name (reserved list + uniqueness) + email, creates instance via `tenant.createInstance`, mints magic, queues signup email via outbox
- `GET /v1/auth?mt=...`: redeems, creates session, 302 to `/#/{name}` with HttpOnly+Secure+SameSite=Lax cookie
- `POST /v1/login` (direct-token) + `POST /v1/logout` — cookie auth
- Starter content (`index.mjs` + `_static/index.html`) deploys during signup through the files writeset
- Smoke in `scripts/signup_smoke.sh` covers every branch including CAS, replay rejection, Resend-key vs dev-fallback paths

### Phase 5 — Minimal admin UI — **partial**
- Pages: login, dashboard home, instance detail with Logs + KV + Code tabs — **done**
- Cookie-based auth, `X-Rove-Scope` header for cross-tenant admin access — **done**
- Two-phase deploy client helpers (`api.bulkDeploy`) — **done**
- Logs tab: newest-first table (time / **deploy** / method / path / status / duration / outcome), click-row drawer with full record incl. console + exception, refresh button, count — **done** (deploy column added 2026-04-27 to surface §2.9's "all 12 failures were on deployment 42" debugging)
- NOT yet: Logs auto-refresh / live tail, Logs filtering (by status / outcome / deployment / path), Logs pagination past `limit=100` (core only supports `limit`, no cursor), nested-thread display under `parent_request_id` (waits on Phase 6 trigger / callback log emits), Deploys tab with history + diff, CodeMirror 6 upgrade, draft workflow, signup form on the login page, tape replay click-through (waits on Phase 4 tape capture)

### Phases 6–10 — **not started**

### Blob replication (multi-node prerequisite)
- Raft envelopes now include `type=3` files_writeset replicating `{id}/files.db` across nodes — **done**
- Blob bytes (`{id}/file-blobs/*`) **still local to the leader**. Multi-node setups need one of:
  - Shared filesystem mount at `{data_dir}` (NFS/EFS/Ceph) — zero code, operator work
  - Future `S3BlobStore` impl in `rove-blob` — not yet written
- Single-node launch is unaffected; multi-node launch is gated on picking one.

## 10. Architecture decisions post-2026-04-17

Six architectural calls were made between 2026-04-17 and 2026-04-21. Captured here so future sessions don't re-derive them.

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
- **Header builder duplication**: `buildSystemRespHeaders`, `buildHandlerRespHeaders`, `buildAuthRespHeaders`, `buildRedirectRespHeaders` all pack pair-lists into one contiguous buffer. ~80 lines of boilerplate collapses to one builder taking a pair slice.
- **Dev-mode escape hatches as `pub var`**: `ssrf.dev_allow_loopback` + `http_client.dev_allow_plaintext` are module-level mutable globals. Works but is ugly; should be plumbed as `DrainerConfig` fields.
- **`handleAdminSignup` 170 lines** doing six things; could split into validate → provision → build-magic → maybe-queue-email → respond. Low-value cleanup.

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
