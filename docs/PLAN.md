# rewind.js product plan

> **Status**: the product **roadmap** layer (V2 line, branch `v2`). This is one of
> three durable layers — the *why* + considered-and-rejected lives in
> [decisions.md](decisions.md), the as-built *mechanics* live in `architecture/`,
> and this captures the product vision, the locked product-shaping decisions (as
> an index, §2), and the forward build plan. See [README.md](README.md) for the
> full documentation map. Restructured 2026-06; the older inline rationale +
> shipped-status detail was harvested into decisions.md / `architecture/` and
> removed (git history has it).
>
> **Navigation**: §1 vision · §2 the locked-decision index (pointers out) · §3–§6
> the build plan + deferred/open items · §7 the canonical considered-and-rejected
> list · §8 the product thesis · §10.16/§10.17 beta→1.0 launch sequencing · **§13
> the V2 "servers and surfaces" map** (start there for which process owns what).
> §9/§10/§11 are now pointer stubs to where that content moved.

## 1. What rewind.js is

rewind.js is the productized face of `rove`. It sells the rove substrate as:

> "A backend in 30 seconds. JS handlers, KV store, free static hosting."

The deeper product identity — the thing nobody else is offering:

> **Purely functional serverless.** Handlers are pure functions of `(request, kv)`. All outbound side effects are declarative commands that resolve asynchronously. End-to-end replay determinism → time-travel debugging with DevTools breakpoints on any production request.

### Audiences

- **C1 — direct customers**: developers who sign up, pick an API name, upload code, run an API.
- **C2 — customers of our customers**: end users hitting the C1's site/PWA that talks to the C1's API.

### Onboarding promise

1. User visits `app.rewindjs.com`.
2. Types a preferred API name + email, clicks Create.
3. Receives magic-link email; clicks through.
4. Lands in dashboard with a working code editor, KV viewer, log tail.
5. Their API is already live at `{name}.rewindjs.app` with starter code.

## 2. Locked architecture decisions

The product-shaping decisions, stated as locked conclusions. This section is the
*index of what is settled*; the **why** (and the alternatives ruled out) lives in
[decisions.md](decisions.md), the considered-and-rejected list is §7, the
as-built **mechanics** live in `architecture/`, and the customer-facing API
surface is [handler-shape.md](handler-shape.md) + [effect-algebra.md](effect-algebra.md).
Follow the pointers for detail.

### 2.1 Domain + origin layout

Own `rewindjs.app` as the **customer wildcard**, one origin per tenant (static +
handler API share it, so first-party cookies work with no Public Suffix List
wait), and a **distinct** registrable domain `rewindjs.com` for system surfaces
(`app.`/`replay.`/`auth.`/`files.`/`logs.`). The different eTLD+1 *is* the
security-isolation boundary. Wildcard TLS terminates at the front door (own
ACME). Why + the rejected origin layouts: decisions.md §1 + §6; mechanics:
`architecture/auth-and-domains.md`, `architecture/routing-and-ingress.md`.

### 2.2 Auth model

C1 (admin) auth is **OIDC**: `auth.rewindjs.com` is a full OIDC IdP that is
itself an ordinary tenant running the customer `oidc.provider()` library, and
admin/replay/logs are relying parties — no privileged platform-only auth path.
C2 (the customer's own end users) is the customer's problem, served by primitives
(`oidc`, `jwt`, `sessions`, cookie + crypto helpers). Why + the rejected
bearer-token / `admin.rewindjs.com` shapes: decisions.md §6 + §7; mechanics:
`architecture/auth-and-domains.md`.

### 2.3 Execution model

Handlers are **pure functions** of `(Msg, Ctx)` — no `fetch` / `setTimeout` /
uncaptured `Date.now()` / `Math.random()`. All external effects are declarative
`Cmd`s; all nondeterministic inputs are taped, so any activation replays exactly.
One 10 ms CPU envelope covers a request plus every trigger and cascade it fires.
This determinism is the replay-with-breakpoints differentiator (and its cost —
"call an API and use the result inline" becomes fire → callback). Model + why:
decisions.md §3; the four-primitive algebra: [effect-algebra.md](effect-algebra.md);
mechanics: `architecture/effects-and-handlers.md`.

### 2.4 File API + static serving

Content-addressed deploy (two-phase blob upload + an immutable manifest), static
served by path with a fixed routing/fallback order, handler source compiled to
shared bytecode, top-level `_*` paths system-reserved, per-file + per-instance
size caps. Publishing is **cluster-free**; a separate approval-gated **release**
flips `_deploy/current`; static assets **302-redirect** to presigned S3 rather
than buffering in the worker. The customer-facing file API (`files.*`) + routing
rules are in [handler-shape.md](handler-shape.md); the deploy/release split +
mechanics are in `architecture/deployment-and-logs.md` (decisions.md §11).

### 2.5 Triggers

"JS stored procedures": deterministic, in-transaction code registered by **path
convention** under `_triggers/` (the path *is* the kv prefix). Named exports per
op×timing (`beforePut` / `afterPut` / `beforeDelete` / `afterDelete` / `default`),
tree-traversal order across overlapping prefixes, cascades depth-capped at 8,
platform-prefix-guarded, sharing the request's 10 ms envelope. Raft replicates
the **final write-set**, not the trigger. Customer-facing contract:
[handler-shape.md](handler-shape.md); mechanics:
`architecture/effects-and-handlers.md`. Index-backfill composes from the
self-webhook chain (a dedicated `batch.*` primitive stays deferred — §4).

### 2.6 Webhooks / outbound HTTP

There is **one** native outbound primitive, `http.fetch`. `webhook.send` /
`email.send` / `retry.*` are JS standard-library shims that compose durability on
top: an `_send/owed/{id}` owed-marker (an ordinary envelope-0 kv write, atomic
with the handler's writeset) + `http.fetch` + a boot/cron sweep that re-fires
stale markers. At-least-once (receivers dedup on the id header); vendor-neutral
(no platform signing header — customers stamp HMAC/SigV4 via `crypto.*`);
mandatory SSRF block + TLS-always (wired 2026-06-11: per-attempt gate +
full-set `CURLOPT_RESOLVE` pin + redirects-off for customer fetches —
decisions.md §3.8). Why durability-as-JS-shim (and the three
retired native generations — `webhooks.db`, `http.send`+`schedules.db`,
`SendDispatch`): decisions.md §3.3 + §3.4 + §7; mechanics:
`architecture/effects-and-handlers.md` (the primitive itself:
`architecture/routing-and-ingress.md` §4).

### 2.7 Encryption at rest

Page-level AES-256-GCM on all per-tenant storage (not per-value), keyed by
`HKDF(master, label‖instance_id)` with the master key held **outside** rove's
persisted state and distinct labels per subsystem. Tapes encrypted the same;
browser replay is server-side-decrypted over TLS (no client-side key
distribution). SQLCipher vs a vendored AES-GCM VFS is the open Phase-9 call (§5).
Why page-level (and the rejected write-only `env` / value-level encryption):
decisions.md §7 + §7 here.

### 2.8 Cache invalidation via the apply hook

Manifest / release / routing cache invalidation rides the raft **apply hook**,
never per-instance polling — a deploy already goes through raft, so reusing the
apply notification scales to many tenants per node for free. Mechanics: the
`_deploy/current` marker → loader (`architecture/deployment-and-logs.md`) and the
directory apply-observer projection (`architecture/control-plane.md`).

### 2.9 Logs + observability

Every request log is tagged with `deployment_id` and `parent_request_id` (for
nested trigger / webhook / callback threads); tapes are sampled, TTL'd, and
encrypted. Logs **bypass raft entirely** (per-node S3-direct batches, indexed by
a standalone log-server) — they are the customer-facing replay store; operator
signals go to Grafana Cloud (the two-sink split). Mechanics:
`architecture/deployment-and-logs.md` + `architecture/observability.md`
(decisions.md §7 + §11).

### 2.10 Rate limiter (general primitive)

Token bucket per `(instance, action)`, per-plan-configured — the same knob that
differentiates plan tiers. Shipped v1 narrow scope is `request` + `email`
(per-worker, in-memory). Plan-tier wiring lands with custom domains (Phase 10);
the limits live on the CP plan axis; enforcement levers + tier model:
`architecture/control-plane.md` "Operational state" (decisions.md §10.9).

### 2.11 CLI (v1 scope)

`rewind deploy ./dir` (content-addressed two-phase upload) + a `rewind.json`
project file; token copy-paste auth. Ships at 1.0, not beta (§10.16). Later
`kv` / `logs` / `init` commands deferred (§4).

### 2.12 Live UI updates — customer-defined streaming, not a platform pipe

There is **no** platform-managed SSE / event pipe (the original `events.emit` +
sse-server was deleted). Customers write their own streaming handler returning
`stream(...)`, with watched-prefix kv-write wakes driving frame emission — the
customer's kv *is* the event log they choose to keep; cross-node correctness
rides raft. SSE is the default push channel (HTTP/2-native, browser
auto-reconnect with `Last-Event-ID`); inbound WebSocket is shipped
([architecture/websockets.md](architecture/websockets.md); outbound WS remains
[websocket-plan.md](plans/websocket-plan.md)). Surviving locked decision: notification
≠ state store, reconnect → state-refetch from kv. Mechanics:
`architecture/effects-and-handlers.md` + `architecture/routing-and-ingress.md`.

### 2.13 Per-tenant durability & snapshot

Each tenant is its own raft group (`tenant == group`, 1:1). A customer write
lands in a speculative kvexp overlay + a parallel raft propose, committing on
quorum (the writer is **never** held across the round-trip). A per-tenant
durabilize/compaction tick bounds WAL replay; a tenant is a *movable* unit
precisely because it is a whole group (detach → ship committed state → attach a
fresh group at a new epoch elsewhere). Why + the rejected pause-and-snapshot
model: decisions.md §2 + §10; mechanics: `architecture/consensus-and-storage.md`.

## 3. Build plan (ordered phases)

> **Note on ordering**: the *content* of these phases is canonical, but
> the original number-order is no longer the launch sequence. §10.16
> (Launch sequencing) owns the beta / 1.0 / post-1.0 split and remaps
> phases across those windows. Read this section for what each phase
> *contains*; read §10.16 for what ships *when*.
>
> **Shipped phases are collapsed** (2026-06-11) to a status line + pointers —
> the phase numbers stay because code comments and other docs cite them; the
> original work-item detail is in git history and, where it survived contact
> with reality, in `architecture/` / decisions.md. Unbuilt phases (9, 10, 12,
> 13, 14) keep their content; 12–14 defer to their sub-plan docs.

**Cross-cutting for every phase**:
- `deployment_id` on all request logs.
- Raft apply hook for cache invalidation.
- Shared path-validation module across upload APIs.
- Logger nesting for triggers/webhooks/callbacks under parent `request_id`.
- All admin API paths versioned `/v1/` from day one.

### Phase 1 — Domain infrastructure — SHIPPED (re-platformed in V2)

Domains, wildcard TLS, host routing. In V2 the stateless front door
(`rewind-front`) terminates TLS with its own ACME issuer and routes
Host→cluster from the CP directory; `Set-Cookie Domain=` stripping (the
authoritative cookie-isolation defense) shipped with inline tests. PSL
submission stays deferred to Phase 10. Mechanics:
`architecture/routing-and-ingress.md` + `architecture/auth-and-domains.md`.

### Phase 2 — File API + static serving — SHIPPED

Content-addressed two-phase deploy (blobs + immutable manifest), static-first
routing with the §2.4 fallback order, ETag/304, drafts + history, size caps.
Customer surface: [handler-shape.md](handler-shape.md); mechanics:
`architecture/deployment-and-logs.md`.

### Phase 3 — Webhooks + email — SHIPPED, then re-platformed twice

Outbound HTTP, `webhook.send` / `email.send`, callbacks, `crypto.hmacSha256`
for vendor-specific signing (no platform signing header — §10.4). The final
shape is durability-as-JS-shim over the single `http.fetch` primitive
(decisions.md §3.3); the intermediate generations (per-tenant `_outbox/*`
drainer → `webhooks.db` envelopes 4/5/6 → `http.send` + `schedules.db` →
leader-local `SendDispatch`) are recorded in §7 +
`architecture/effects-and-handlers.md`. Resend is the email provider
(decisions.md §1.2). The SSRF-blocklist half of the outbound contract was
wired 2026-06-11 (decisions.md §3.8; `scripts/smoke/ssrf_smoke_v2.py`).

### Phase 4 — Signup + auth — SHIPPED (admin auth re-platformed to OIDC in V2)

Magic-link signup (`_magic/{hash}`, 30-min single-use), revocable session
cookies, starter content. Two policy decisions made here stay load-bearing:

- **Lazy-creation-on-redeem**: signup only writes a `pending/{name}`
  reservation; tenant creation + starter deploy happen atomically at
  redemption, and a periodic sweep expires stale reservations (otherwise
  unredeemed signups squat names and leak per-tenant state).
- **The account namespace** `account/{sha256(email)}/...` (plan tier +
  instance-ownership index): signup *and* redeem count owned instances plus
  live reservations against `max_instances` (v1 hardcodes 1); Phase 10 wires
  all per-account caps + Stripe linkage through the same
  `account/{hash}/plan` lookup. Seed-manifest tenants live outside the
  account model (operator-provisioned, no email).

Admin/dashboard auth is now OIDC end-to-end (`architecture/auth-and-domains.md`).

### Phase 5 — Minimal admin UI — SHIPPED

Dashboard at `app.rewindjs.com`, dogfooded on the platform's own file API:
Code (CodeMirror) / KV / Logs / Deploys tabs. The remaining dashboard work is
beta polish — §10.16's launch path item 1.

### Phase 5.5 — Storage scalability (MVP boundary) — SHIPPED in evolved forms

The "nothing heavy rides raft" bucket — without it, log records and captured
bodies ride the raft log and disk pressure kills the cluster in weeks. All
five work items landed, each in a shape that evolved past the original sketch:

1. **Logs leave raft entirely** — per-node S3-direct batches + a standalone
   log-server index (`architecture/deployment-and-logs.md`).
2. **Tape body capture** — subsumed by readset replication + the blob
   coordinator (`BodyRef` inline-vs-blob routing; decisions.md §5).
3. **Snapshot + compaction** — per-tenant snapshot indices with S3 transport,
   no global write pause (`architecture/consensus-and-storage.md`); the V2
   multi-raft engine compacts per group.
4. **Webhook subsystem** — converged on durability-as-JS-shim (decisions.md
   §3.3); every rejected dedicated-subsystem generation is recorded in §7.
5. **Files-server move** — manifest in S3, `_deploy/current` marker release,
   cluster-free publisher (`files-server-v2`); envelope 3 retired
   (`architecture/deployment-and-logs.md`).

Blob storage is **S3-only in V2** — there is no filesystem backend; production
is multi-node and every node must read the same content-addressed store. The
original "post-1.0 files/log detach" note is moot: V2 ships them as separate
binaries (§13.1).

### Phase 6 — Triggers — SHIPPED

`_triggers/` prefix-trie registration, before/after dispatch inside the write
transaction, depth-8 cascades, platform-prefix guard, replay-for-free (kv op
capture re-fires them). Contract: [handler-shape.md](handler-shape.md);
mechanics: `architecture/effects-and-handlers.md`.

### Phase 7 — CLI — UNBUILT, ships at 1.0

- `rewind deploy`: walk dir, hash, check, upload missing, commit manifest.
- `rewind.json` parsing.
- Deploy-token issuance UI in dashboard (one-time plaintext print).
- Later commands deferred.

### Phase 8 — Rate limiter primitive — SHIPPED (narrow v1 scope)

Token bucket per `(instance, action)`; the shipped scope is `request` +
`email` (per-worker, in-memory). Plan-tier wiring lands with Phase 10 on the
CP plan axis (`architecture/control-plane.md` "Operational state").

### Phase 9 — Encryption at rest — UNBUILT

- Master-key loader (file + env var).
- Per-instance HKDF derivations (distinct labels per subsystem).
- **SQLite page encryption — vendored AES-GCM VFS (preferred) vs SQLCipher (decide in this phase)**.
- Blob encryption paths.
- Tape encryption.
- **DESIGN GATE (pre-customer, format-versioning-audit.md §7.8):** every
  ciphertext written by this phase MUST carry a self-describing envelope —
  `[alg_id][key_version][nonce/iv]…[tag]` — with a documented `alg_id` space,
  from the very first byte persisted. This is the one-shot window: once customer
  data is encrypted, an envelope that lacks an algorithm id and a key version
  can never rotate the cipher or the key without a migration we can't do
  retroactively. Bare ciphertext (or a version byte without an algorithm id) is
  rejected at design review. Rotation *tooling* stays deferred; the *envelope*
  is non-negotiable.

### Phase 10 — Custom domains + polish — UNBUILT (DNS-01 wildcard + per-host HTTP-01 issuers exist; the customer-facing tier does not)

- Customer CNAME `api.myapp.com` → `foo.rewindjs.app`.
- Per-custom-domain Let's Encrypt cert provisioning. Watch ACME rate limits at signup surges.
- Domain assignment UI in dashboard.
- Plan tiers wired to all per-account caps via the `account/{sha256(email)}/plan` namespace introduced in Phase 4. Single lookup drives `max_instances` (Phase 4 hardcode goes away), `request` / `email` rate-limit caps, DLQ retention, blob storage caps, custom-domain counts, and Stripe customer-id linkage below.
- Billing hookup (Stripe) — implement via `webhook.send` + callbacks to dogfood the Cmd path. Customer id stored at `account/{hash}/stripe_customer_id`.
- **PSL submission** for `rewindjs.app` (GitHub PR to `publicsuffix/list`). Fire-and-wait; propagation can take weeks-to-months across browser releases. Defense-in-depth only — server-side `Set-Cookie Domain=` stripping from Phase 1 is the authoritative guard.

### Phase 11 — Live UI updates — superseded by streaming-handlers

Phase 11 originally specified a platform-managed SSE primitive
(`events.emit`, sse-server, JWT handoff). That subsystem shipped
2026-04 and was **deleted 2026-05-19** in streaming-handlers Phase 5;
customer-arbitrary streaming handlers replace it (initially the
`__rove_stream` surface, since renamed by the handler-surface redesign to
`stream(...)` + `on.kv` watched-prefix wakes). See §2.12 +
`docs/architecture/effects-and-handlers.md`.

### Phase 12 — Sim test framework + simulator library (§10.7, §10.8) — UNBUILT, post-1.0

Client-side simulator library + deterministic handler test framework: `rewind
simulate` (synthetic request + kv overlay + mode → bundle), `rewind test`
(`_tests/`, snapshots), `rewind export-fixture`. Purely client-side — the
worker is a recording device, never a simulator; no live-KV pass-through.
**[sim-test-framework.md](plans/sim-test-framework.md) is the authoritative plan**
(CLI host since re-decided as the `rewind` npm package — decisions.md §8.3).

### Phase 13 — Fixture lifecycle + worker dry-run (§10.9, §10.11) — UNBUILT, post-1.0

Fixture authoring/editing tooling (`rewind kv` / `rewind fixture` families,
the `--auto-fix-from` recovery flow) plus the worker-side
`POST /_system/dry-run/{id}` always-rollback dispatch mode (the one worker
piece). **[fixture-lifecycle.md](plans/fixture-lifecycle.md) is the authoritative
plan.**

### Phase 14 — AI agent surface (§10.10) — UNBUILT (skill file pulled forward to beta)

Skill file (`docs/skills/rewind.md` — a §10.16 beta item) + `--json` CLI
audit + `rewind doctor` + scoped capability tokens. No MCP server in v1;
hosted MCP deferred until remote-agent demand. **[agent-surface.md](plans/agent-surface.md)
is the authoritative plan.**

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
- Local dev CLI (`rewind dev` mini-rove for offline testing).
- Symlinks / aliases / redirects (rules.json).
- Private blobs that handlers read but URL doesn't serve — if needed, use `_static/_private/*` convention.
- Runtime external imports (esm.sh at handler runtime).
- "Mark secret key as dots in dashboard" affordance.

## 5. Items to confirm before their phase

Resolved items moved to §10. Open items:

- **Phase 9 (encryption)**: commit to SQLCipher vs a first-party AES-GCM VFS.
  Audit implications differ. (The old "vendored VFS" wording predates the
  pin-and-fetch dependency model.)
- **Phase 10 (custom domains)**: ACME rate-limit strategy for a signup surge.

Resolved since this list was written (recorded so they aren't re-asked):
admin-UI hosting = platform-hosted dogfood (docs and dashboard are tenants);
blob backend = **S3-only, mandatory, no
filesystem variant** (production is multi-node; every node reads the same
content-addressed store).

## 6. Relevant existing code

The 2026-04 pointer list rotted (line numbers drifted; `vendor/` no longer
exists) and was removed. Each `architecture/` reference opens with a **Code
map** table for its subsystem — start there.

## 6a. Sub-plans expanding sections of this document

[README.md](README.md) is the documentation map and owns this index: the
`architecture/` as-built set (mechanics per subsystem), the customer contracts
([handler-shape.md](handler-shape.md) + [effect-algebra.md](effect-algebra.md)),
and the in-flight plan docs. The former inline list here duplicated it and
drifted.

## 6b. Architectural principle: separability follows raft participation

The right axis for "should this subsystem be its own process /
binary / machine" is **whether it participates in raft**, NOT
whether it has a public TLS surface (the original heuristic).

> **Subsystems that participate in raft live in the worker binary.
> Subsystems that don't can be split into their own processes /
> machines.**

Participation = reads raft-replicated state, OR proposes
envelopes, OR is leader-pinned by definition.

The principle holds in V2 and is *why* `log-server` is a separate binary (no
raft participation, state in S3) while the per-tenant consensus stays in
`rewind`. (Deploy/publish was *also* a separate binary — `files-server-v2` —
on the same reasoning, but it folded back into the worker's `/_system/deploy`
once it turned out to need no cross-tenant reach: compile + content-address +
stamp run in-tenant on the worker, `rewind-cli-plan.md` §4.) The V1 examples
that used to live in a table here
(the single `loop46` binary, the leader-pinned `webhook-server` thread) are
retired — durability is now a JS shim, not a raft-participating subsystem. The
live process map is §13; the principle lets us answer "split or not" without
re-litigating case by case.

## 6c. Leadership and the public surface

V1's version of this section said "only the raft leader accepts customer
requests" — a whole-cluster property, because V1 was a single raft group. V2
is **multi-raft (one group per tenant)**, so leadership is per-tenant, not
per-node: any node may lead some tenants and follow others, and every node
accepts traffic. The surviving property: the stateless front door
(`rewind-front`) proxies each request leader-aware *per tenant*
(`proxyToCluster`, retry-on-503); reads are served by any synced node; a write
self-routes to that tenant's group leader. See
`architecture/consensus-and-storage.md` + `architecture/routing-and-ingress.md`.

## 7. Superseded decisions (do not re-propose)

This is the **canonical considered-and-rejected list** for the core architecture
(decisions.md cross-references it rather than duplicating it — see decisions.md's
preamble). Entries span the 2026-04-17 design conversation and the later 2026-05
restructures; captured here so future sessions don't re-derive them.

- **`admin.rewindjs.com` + bearer tokens** as the admin UI origin. Rejected: wanted to dogfood the customer auth path, and bearer tokens force customers into `headers: Authorization` plumbing.
- **`{name}.api.rewindjs.com` + `site.rewindjs.com` (PSL)** for separate static/API origins. Rejected: PSL propagation is a launch blocker, and per-customer wildcard TLS for two-label-deep API hosts is operational pain. Single origin per tenant with path routing is simpler.
- **Admin UI served by the root JS instance.** Rejected: violates dogfooding — we should host the admin UI the same way a customer hosts theirs (static bundle + cross-origin to its API is actually not needed here either, since same-origin on `app.rewindjs.com`).
- **Write-only `env` / secrets primitive.** Rejected: ceremony without defense (handler code can exfiltrate any value it can read). Replaced by page-level encryption for all KV.
- **Value-level encryption for secrets.** Rejected: unified page-level encryption covers more surface with one code path.
- **Redact env values from replay tapes.** Rejected: breaks determinism (downstream captures derive from env values, can't be recomputed). Replaced by encrypting tapes at rest and access-gating admin reads.
- **Cookie-based auth for C2 API calls by default.** Rejected for customers whose UI is on a third-party host — Safari ITP eats third-party cookies. Same-origin on `{name}.rewindjs.app` via path routing recovers the cookie path for the default layout; bearer tokens remain as a third-party-host fallback.
- **Admin UI auto-detecting `.ejs` / `.ts` file extensions and running a built-in transform** (as shift-js did). Rejected: platform-not-framework. Transforms are libraries customers import, not platform primitives.
- **Synthetic "deploy" event in the request log stream.** Rejected: misleading across the transition window. Per-request `deployment_id` tagging is accurate and more useful.
- **Per-worker polling of `deployment/current` for cache invalidation.** Rejected: doesn't scale to thousands of instances. Raft apply hook is the correct notification channel.
- **Strict FIFO ordering guarantees for webhooks.** Rejected: impossible to deliver meaningfully across destinations with different latencies; customers who need ordering chain via callbacks.
- **Fan-in of multiple webhooks into one callback.** Rejected for v1. Customers build saga patterns by hand with triggers/callback-chaining.
- **Auto-resend on expired-but-recent magic-link click** (15-min validity + 15-min grace window with `resend_grace_until_ns`, `magic_resend` rate-limit action, "we sent a fresh link" UI page). Rejected: trades a friendly page for an extra email round-trip that's strictly worse than just bumping the magic TTL. Replaced by 30-minute flat validity + an `email` URL hint on the signup form pre-fill for the 401-page case. Also avoids a name-squat amplification in the original design — the resend chain renews `pending/{name}` lifecycle, letting one signup hold a name for hours within the 3/hr per-email rate limit; flat TTL caps the reservation at 30 min.
- **SSE rows in customer's `app.db` under reserved prefix `_events/{sid}/{seq}`**, replicated through raft envelope 0, with a per-tenant retention sweep + Last-Event-ID catch-up over the persisted rows. Rejected (2026-05): SSE is a notification channel, not a source-of-truth state store; the reserved-prefix storage entangled SSE state with customer kv writesets, raft replication, the markDirtyFromWriteset scan, and a 365-line retention sweep — for semantics that are explicitly losable and recoverable via replay. The "notification ≠ state store" decision carried first into a platform-managed sse-service (deleted 2026-05-19), then into customer-arbitrary `__rove_stream` handlers backed by the customer's own kv watched prefixes — a surface the handler-surface redesign later replaced with the named-export `stream.*` / `on.kv` model (see `docs/handler-shape.md` + `docs/architecture/effects-and-handlers.md`; the trigger model itself is `docs/decisions.md` §13).
- **Log batches replicated through raft (envelope type 1) + per-tenant `log.db` apply on every node.** Rejected (2026-05): logs are best-effort and lossy by design (PLAN §2.9), don't need raft's strong durability, and forcing them through the raft log dominates cluster bandwidth at scale. Replaced by `docs/architecture/deployment-and-logs.md`: per-node S3-direct batch upload + a single log-server process polling S3 to maintain a local SQLite index.
- **Per-tenant `files.db` on every worker mirroring the manifest via raft envelope type 3.** Rejected (2026-05): worker-as-read-only-consumer model is cleaner. Replaced by `docs/architecture/deployment-and-logs.md`: manifest lives in S3, runtime release signal is a `_deploy/current` kv marker written by a `POST /_system/release` worker route and picked up via apply.zig's writeset-value scan into a process-wide ReleaseTable, worker reads on demand.
- **Worker hairpin proxy `/_system/files/*` and `/_system/log/*`.** Rejected (2026-05): these subsystems should be on their own subdomains (`files.{public_suffix}`, `logs.{public_suffix}`), terminating their own TLS, with token-handoff auth from the customer's app domain. Worker stops mediating their traffic entirely. Per `docs/architecture/deployment-and-logs.md`.
- **Every dedicated-subsystem shape for outbound webhooks/durability** — all rejected, converging on durability-as-JS-shim (decisions.md §3.3, shipped 2026-05-24). The dead ends, kept so they aren't re-derived: (a) **leader-local with per-tenant `_outbox/*` scan recovery** — the per-tenant scan is exactly the hot-path cost to eliminate; (b) **per-tenant `_outbox/{id}` transactional handoff + apply-hook forwarding** — the only thing the per-tenant row bought was kv-inspectable pending webhooks, not a real customer benefit, and atomic envelope-0+marker propose makes it durable at commit anyway; (c) **a drainer thread** and (d) **a separate `rove-webhook-server` binary** — both moot once delivery state rides raft. (d) also settled the separability axis: a webhook subsystem that participates in raft must live in the worker binary, not a separate process (the §6b principle). The actually-shipped chain of *implemented* generations (cluster-wide `webhooks.db` envelopes 4/5/6 → `http.send`+`schedules.db` envelopes 8/9/10/11 → per-tenant `_send/owed/` + leader-local `SendDispatch` → durability-as-JS-shim) is in `architecture/effects-and-handlers.md` Phase 5 + PLAN §10.2's envelope-evolution pointer.
- **Pause-and-snapshot raft snapshot strategy** (briefly stopping all applies during VACUUM pass to capture every tenant's `app.db` at a single global raft index). Rejected (2026-05): contradicts the worker-kv-path north star — even a few seconds of cluster-wide write pause every snapshot interval is unacceptable at the "many tenants per node" density. Replaced by per-tenant snapshot indices with always-refresh-all-tenants discipline (`docs/architecture/consensus-and-storage.md`). The slow-tenant pinning concern is mitigated by the always-refresh trick (dormant tenants get manifest-bookkeeping refresh without re-VACUUM).
- **Static file serving via worker-proxied bytes (with hash ETag + immutable Cache-Control + Cloudflare in front).** Briefly preferred 2026-05 over a 302-to-S3 redirect (the reasoning then: Cloudflare already absorbs repeat traffic, so the marginal reduction wasn't worth a per-deployment flag / public-bucket model / CSP friction). **Reversed in V2**: static assets now **302-redirect to a presigned S3 URL** so the worker never buffers MB-sized bytes (deployment-snapshots P4 pivot; decisions.md §11.3; `architecture/deployment-and-logs.md`). Kept here as a reversed call, not a standing rejection — see §2.4.
- **Polling `current.json` (or per-tenant `latest.json`) for files-server release detection.** Rejected (2026-05): adds per-tenant LIST/GET cost to every worker every interval. Replaced by `_deploy/current` kv marker written by a `POST /_system/release` worker route and picked up via apply.zig's writeset-value scan into a process-wide ReleaseTable — no polling, no new envelope type, marker rides through the customer kv writeset that the customer's deploy CLI writes.

**Superseding note (2026-05-16 — `docs/architecture/auth-and-domains.md` Phases 1–3 landed).** The first and last *admin/auth* bullets of this section (`admin.rewindjs.com`+bearer; cookie-auth-for-C2) objected to *specific shapes*, not the underlying need. They are now **resolved, not re-proposed**, by the landed auth/domain architecture — read `architecture/auth-and-domains.md` before touching auth:

- System surfaces live on a **second registrable domain** (`*.rewindjs.com`: `app.`/`replay.`/`logs.`/`auth.`), distinct from the customer wildcard (`*.rewindjs.app`). Different eTLD+1 *is* the security-isolation boundary. The worker now requires both `--public-suffix` and a distinct `--system-suffix`.
- `auth.rewindjs.com` is **not** the rejected `admin.rewindjs.com`+bearer: it is a tenant (`__auth__`) running the *customer-facing* `oidc.provider()` library — a full OIDC IdP. admin/replay/logs are pure OIDC **relying parties** of it. This *satisfies* the dogfooding objection (auth is just a tenant running the customer auth lib; no privileged platform-only auth path) instead of violating it.
- The admin dashboard has **no bearer/root-token human path** anymore (OIDC-only). `/_system/*` keeps its root-token gate as the separate machine-to-machine surface (§4.1 of the sub-plan; consistent with the worker→standalone HS256 decision). Operator `is_root` = an OIDC `sub` in the `_admin/operator/*` allowlist, seeded from `LOOP46_OPERATOR_EMAILS`.
- §0 host-relative invariant: `iss` / JWKS / endpoints / `redirect_uris` derive from the request host (or host-relative `${ISSUER_*}` config templating), never a compiled platform-domain literal — this is what lets `rewindjs.com` be "just a custom domain" and lets customers run their own IdP from the same library.

The `{name}.api.rewindjs.com` **PSL** bullet still stands and is *not* contradicted: the two-domain split is two separate single-label wildcards (no PSL dependency, no two-label-deep wildcard).

## 8. Why this is a compelling product

The uniqueness isn't any single feature — it's the coherence of the set:

- **Purely functional handlers** (no async IO, no fetch, all effects are Cmds).
- **Cmd-pattern outbound path: one native door to the outside world (`http.fetch`)**, commit-gated and atomic with the writeset; durability (`webhook.send` / `email.send` / `retry.*`) composes in JS on top.
- **Deterministic triggers in the same KV transaction as the write.**
- **Tape capture on every request, encrypted at rest.**
- **Browser-based replay with DevTools breakpoints on production bugs.**
- **One URL for the whole app (static + API + admin-of-admin).**
- **Magic-link signup → live API in under a minute.**

Nobody is offering this combination. The marketing headline is the functional core + replay; the developer hook is the one-minute demo. The rest of the plan is making both of those true.

## 9. Implementation status

Live status is **not** tracked in this document anymore. The authoritative
current picture is:

- The `architecture/` reference set — each doc's **"Known limitations
  (as-built)"** section is the per-subsystem status of record. (The V2 cutover
  checklist was retired at the cutover, 2026-06-10; its open items were folded
  into those sections.)

The original 2026-04-30 phase-by-phase snapshot was removed in the 2026-06 docs
restructure: it described the retired V1 stack and had been superseded several
times over. It lives in git history if a point-in-time read is ever needed.

## 10. Architecture decisions (post-2026-04-17) — moved to decisions.md + architecture/

These calls were captured here as they were made; the durable record has since
moved. Each former subsection now lives in [decisions.md](decisions.md) (the
*why* + the rejected alternatives) and/or an `architecture/` reference (the
as-built mechanics) or a dedicated plan. This table preserves the **§10.N
labels** other docs cite and points to the current home. Launch sequencing
(§10.16 / §10.17) stays below as the beta/1.0 roadmap of record.

| Former § | Decision | Now in |
|---|---|---|
| 10.1 | Admin is a real instance with a `platform` capability | `architecture/auth-and-domains.md`; decisions.md §6 |
| 10.2 | Root replication via raft envelope type 2 (+ the full envelope evolution table) | `architecture/consensus-and-storage.md` ("What replicates through raft"); the CLAUDE.md raft-envelope table |
| 10.3 | Two-phase content-addressed deploy protocol | `architecture/deployment-and-logs.md`; decisions.md §11 |
| 10.4 | `webhook.send` vendor-neutral; `email.send` takes the key as a parameter | decisions.md §3.3; `architecture/effects-and-handlers.md` |
| 10.5 | Replication-ready blob backend (shared object store, not raft-carried bytes) | `architecture/consensus-and-storage.md` ("Blob replication"); decisions.md §11 |
| 10.6 | `dispatchOnce` refactored into phase-shaped helpers | V1 mechanics — superseded by the V2 single-re-entry `runOutcome` dispatcher in `architecture/effects-and-handlers.md` |
| 10.7 | Simulator primitive (purely client-side, KV-less) | [sim-test-framework.md](plans/sim-test-framework.md); decisions.md §8 |
| 10.8 | Sim test framework (deterministic, local-only) | [sim-test-framework.md](plans/sim-test-framework.md); decisions.md §8 |
| 10.9 | Fixture lifecycle (curated observations) | [fixture-lifecycle.md](plans/fixture-lifecycle.md) |
| 10.10 | AI agent surface — CLI + skill file in v1, hosted MCP deferred | [agent-surface.md](plans/agent-surface.md); decisions.md §8 |
| 10.11 | Worker dry-run dispatch mode | [fixture-lifecycle.md](plans/fixture-lifecycle.md) |
| 10.12 | Replay — two paths (browser page + DAP CLI), one per audience | replay-wasm-plan.md (moved to the private rewind-apps repo, `replay/replay-wasm-plan.md`); decisions.md §8 |
| 10.13 | files-server + log-server detached to their own processes | `architecture/deployment-and-logs.md`; §13 here |
| 10.14 | Distributed Elm ports (webhook + callback + streaming) | [effect-algebra.md](effect-algebra.md); `architecture/effects-and-handlers.md` |
| 10.15 | `analytics.track` / `metrics.*` — speculative, post-1.0 | decisions.md §12; `architecture/observability.md` |

### 10.16 Launch sequencing: lead with replay, two-audience framing locked in (decided 2026-04-30)

> The week-estimates below are 2026-04-30 figures and predate the V2
> re-platform that intervened (multi-raft, CP/DP split, cutover — all done).
> The *relative sequencing* and the audience framing are the locked part;
> treat durations as historical.

**Two audiences served by one product**, both motivating the build from day one:

- **"Story 1 — the new programmer"**: brand-new dev, helped by a friend, currently stuck composing Firebase = Google account + billing account + Firebase console + Firestore + Cloud Functions IAM + three different log views just to add a persistent leaderboard. rewind.js collapses all of that to magic-link signup + one dashboard + kv-comes-free + zero permissions to configure. When her app breaks (it will), she has zero mental model for `gcloud logs read` — she just clicks the failed request in her dashboard. Tape replay is what turns "I give up" into "oh, I see what happened."
- **"Story 2 — the engineering team"**: small team, junior-to-senior, perpetually rebuilding ad-hoc observability stacks (Sentry + Datadog + LogRocket + a homegrown webhook outbox), and shipping the same classic transaction-boundary / read-modify-write race bugs every quarter. rewind.js's writeset model serializes those races structurally (SQLite IMMEDIATE locking serializes concurrent r-m-w on the same kv keys; the writeset's all-or-nothing commit eliminates "I forgot to wrap this in a transaction"). The observability stack is built in, the webhook outbox is durable by default, the senior engineer's accumulated wisdom about "things teams keep messing up" is baked into the platform.

The framings differ but the product is identical: **Story 1 hears "ship in minutes"; Story 2 hears "step through it in your browser"**; same launch sentence ("Build a working app in minutes. When it breaks, you can see exactly why and step through the reproducer in your browser") serves both.

**Tape replay is the wedge.** Every other capability has a competitor that does it better — Cloudflare Workers is faster, Vercel has slicker DX, Supabase is more familiar (Postgres-shaped), Firebase has the brand. None of them can match **per-request browser-DevTools replay**. The pure-functional handler choice + tape capture for all non-determinism + the dashboard replay page (§10.12) is the combo that uniquely enables this. Without replay shipped at launch, the differentiation pitch is hand-wavy ("we capture deterministic tapes"); with it shipped, the pitch is concrete ("click any 500, debug it"). That sentence is the difference between "interesting weird platform" and "I have to try this."

**Sequencing — beta-first launch (decided 2026-04-30).** Open beta with Story 1 scope ~3-5 weeks from this decision; 1.0 adds Story 2 scope another ~9-13 weeks later. Beta is **web-only, free-tier-only, no CLI**. See §10.17 for beta operational specifics (data-continuity promise, free-tier caps, banner, feedback channel, no-CLI positioning).

**Beta launch path** (Story 1 audience):

1. **Phase 5 dashboard polish** — instance health indicators, logs view discoverability for Story 1, "Replay" button on Logs rows, "copy request ID" affordance. ~2 weeks.
2. **Tape-replay browser page** (§10.12 Story 1 path) — bundle JSON shape on the worker (compose from existing endpoints, or new `/_system/replay/bundle/{request_id}` aggregator), sandboxed iframe replay page on `replay.rewindjs.com`, stubs library (rewind.js globals reading from tape), `<script type="module">` source loading, `debugger;` injection at handler entry. ~1-2 weeks.
3. **CodeMirror 6 syntax-highlighting upgrade for the Code tab** — replaces the existing `<textarea>` with a CM6 `EditorView`. Language modes by file extension: `.mjs` / `.js` → `@codemirror/lang-javascript`, `.html` → `@codemirror/lang-html`, `.css` → `@codemirror/lang-css`; default plain text. Line numbers + basic editing extensions. **Out of scope for beta**: autocomplete, lint, fold gutter, breakpoint gutter, draft workflow integration. Vendored bundle (no third-party CDN at runtime). ~½ week.
4. **Phase 14 LLM skill file** (`docs/skills/rewind.md`) — AI-assisted rewind.js coding. Without it, LLMs default to imperative `await fetch()` patterns that don't compile. ~1 week.
5. **Story 1 leaderboard example tenant** — the literal Firebase-pain demo, 5 lines of handler + one HTML page. ~½ day. Pairs with the beta launch post.
6. **Beta operational** — free-tier caps wired to existing rate limiter defaults, beta banner in dashboard, data-continuity promise visible at signup, feedback channel link, per-account storage cap enforcement. ~3-5 days. Detail in §10.17.

**Beta total**: ~5 weeks serialized; ~3 weeks with two-person parallelization (Phase 5 polish + replay page parallelize cleanly; CodeMirror upgrade lands alongside Phase 5 polish without coupling).

**1.0 launch path** (Story 2 audience adds, builds on top of operating beta):

1. **Tape-replay DAP CLI** (§10.12 Story 2 path) — `rewind replay <request_id>` CLI fetching bundle + tape, writing a Node entry script with stubs preloaded, spawning under `--inspect-brk`, printing attach instructions for VS Code / JetBrains / nvim-dap / dap-mode. Reuses the stubs library shipped in beta. ~1-2 weeks.
2. **rewind.js-the-project Stripe integration for supporter payments** — *the real production integration that doubles as the customer-facing docs example.* rewind.js's admin handler exposes a "support rewind.js" page that creates a Stripe Checkout session via `webhook.send`, returns a tiny shell page that opens a streaming connection (a `stream(...)` handler with an `on.kv` watched prefix), the callback writes a kv key that wakes the stream which emits the session URL to the connected client, browser navigates. Receives `checkout.session.completed` webhook with timing-safe HMAC signature verification, writes a `supporter/{email}` row in admin's app.db, the same stream wakes a second time and emits "Thanks!" so the originating tab updates without a refresh. **Docs example is extracted from this**: the patterns we actually use become the patterns we teach. ~1.5-2 weeks. (The primitives audit is closed — `crypto.timingSafeEqual`, `hmacSha1`, and `base64` are all shipped, §13.3.)
3. **Phase 7 `rewind deploy` CLI** subset — content-addressed two-phase upload, `rewind.json` parsing, deploy-token issuance UI in dashboard. ~1-2 weeks for v1 scope; later CLI subcommands (`kv`, `logs`, `init`) deferred.
4. **Plan tiers + paid pricing** — first paid tier, plan-tier branching in rate limiter caps, billing wiring via Stripe (uses item 2's primitives). ~1-2 weeks.
5. **Custom domains** (Phase 10) — customer CNAME + per-domain Let's Encrypt. ~2 weeks.

Live UI delivery — originally planned as item #1 (platform-managed SSE primitive, ~3 weeks) — landed earlier as the streaming-handlers framework (2026-05-20). It's no longer a 1.0 launch-path line item; live updates are a baseline capability.

**1.0 additional**: ~9-13 weeks serialized; ~5-7 weeks parallelized.

**Total time to 1.0**: ~14-18 weeks serialized; ~8-10 weeks parallelized. **~3-4 months from this decision**, with beta operating in production for ~2-3 of those months gathering real-user signal.

Phase 9 encryption at rest joins the 1.0 path only if B2B compliance demand surfaces during beta — otherwise it stays post-1.0.

**Why dogfooding Stripe (item 2) matters beyond the credibility argument**:
- **Authenticity**: every "rewind.js + Stripe" code snippet in the docs is code we actually run in production. No theoretical-best-practice patterns that fall apart on first contact with real Stripe API quirks (idempotency keys, webhook ordering, test-vs-live mode handling, the dual-redirect dance for Connect onboarding).
- **Funding**: rewind.js the project costs money to operate (hosting, domain, eventual TLS, mkcert isn't forever). A supporter model lets people who get value from the platform contribute, sustaining the project without VC dependence.
- **Forces us to think like a customer**: building Stripe integration *as a customer of our own platform* is the cleanest possible test of "does this primitive set actually work for a real production integration." If we hit friction, we fix the platform — and customers benefit. The friction we don't fix becomes the friction we document. Either way customers win.
- **Failure-mode audit**: real money is real stakes. The webhook signature timing-safe-equal becomes load-bearing when it's *our* customers' card charges flowing through it. We'll discover the actual gaps in the toolkit far faster than a contrived example would surface them.

**What's NOT in beta but lands at 1.0**:
- DAP CLI replay (`rewind replay`)
- Stripe-on-rewind.js supporter payments
- `rewind deploy` CLI
- Plan tiers + paid pricing
- Custom domains
- Phase 9 encryption (only if B2B compliance demand surfaces during beta)

**What's NOT in either beta or 1.0** (recorded so future-us doesn't second-guess):
- §10.13 / §10.14 file-server + log-server detach + bearer-auth dogfooding. Multi-week refactor that makes the architecture purer but doesn't make the product more useful to a first user. **Post-1.0** when the dashboard-to-file-server path's in-process proxy starts hurting (it doesn't yet). The detach is gated only on engineering bandwidth, not blocking primitives.
- §10.15 `analytics.track` + `metrics.*` primitives. Their absence is workable (customers `webhook.send` to their OLAP / TSDB of choice). **Post-1.0** alongside the rewind-olap / rewind-tsdb pseudo-third-party companion services that motivate them.
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

Operational items required to open rewind.js beta to external Story 1 users. All small, all needed before the dashboard URL gets shared publicly.

**Free tier scope**:
- Existing per-instance rate-limiter defaults (`request` + `email`) become the free-tier caps. Operator-tunable via `WorkerConfig.rate_limit_caps` from §8.
- Per-account instance cap visible to customers (the Phase 4 hardcode becomes an explicit displayed cap).
- Per-account total-storage cap (sum across all that account's instances) — enforced at deploy time, small addition over Phase 2's per-instance caps.
- No paid tier in beta. Stripe-on-rewind.js supporter payments ships at 1.0.

**Data-continuity promise**:
- Visible at signup and in the beta banner: *"Your data carries forward to 1.0. Beta data will not be wiped."*
- Binding commitment. Schema changes during beta require migration, not reset. Tape replay (§10.12) provides natural fixture data for migration testing.
- If a migration becomes prohibitively expensive, the framing has to change to "preview" without that promise — don't break the commitment silently.

**Beta banner**:
- Persistent banner in `app.rewindjs.com` shell: *"rewind.js is in beta. [Feedback]."* Click opens the feedback channel.
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
- The platform binaries during beta ship only operator surfaces (`rewind` / `rewind-cp` / `rewind-front`) — no customer-facing CLI subcommands.
- Beta docs omit live use cases (Stripe Checkout, OAuth code exchange, AI agent results, slow API calls) entirely rather than teaching polling for them. SSE arrives at 1.0 as the *first* answer for those flows.

**Beta-open checklist** (items to complete before public URL):
- Beta banner + feedback link in dashboard shell
- Per-account storage cap enforcement
- Free-tier caps documented at `app.rewindjs.com/docs/limits`
- Data-continuity promise text in signup flow
- End-to-end smoke test: signup → magic link via prod Resend → deploy starter via Code tab → trigger a 500 → click Replay → step through in browser DevTools

Total: ~3-5 days, included in §10.16 beta launch path item 6.

## 11. Rove-library principles audit

The 2026-04-21 audit (admin-kv aliasing, the `dispatchOnce` monolith, interior
pointers on a stack-allocated `Tenant`, and a sweep of fail-fast error sites) was
against the **V1** code and is resolved — see git history for the findings and
fixes. The living invariants it enforced are now stated as decisions and held
across the V2 `architecture/` set: **state is collection membership, not a flag**
and **one reconcile system, not parallel engines** (decisions.md §3.1);
**resource-owning components declare `deinit`**; **fail loud on
infallibility-violations**, don't swallow.

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

§13.3 is the canonical shipped list (native bindings + JS shims + curated
libraries). The surprises worth flagging for first-run docs:

- **`http.fetch` is the only native outbound primitive.** `webhook.send` /
  `email.send` / `retry.*` are JS shims over it; there is no `http.send` /
  `http.cancel` (retired) and no `events.emit` (retired — live push is a
  `stream(...)` handler).
- **No `fetch` / `setTimeout` / `setInterval` / `XMLHttpRequest`** — outbound is
  `http.fetch` (or the `webhook.send` shim); delayed/durable delivery composes via
  the owed-marker + a cron sweep.
- **No full `URL`** (only `URLSearchParams` is polyfilled), **no `Response` /
  `Headers`** (the fetch-API class hierarchy was intentionally dropped — return a
  value, set `response.*`), **no `atob` / `btoa`** (use `base64.{encode,decode}`),
  **only `console.log`** (not `.error` / `.warn` / `.info`), **no `WeakRef` /
  `Proxy` / `DOMException`** (skipped in snapshot init).

### File layout conventions

- Handler source lives at top-level paths (`index.mjs`, `foo/index.mjs`, `api/users.mjs`). An earlier draft of PLAN §2.4 mandated a `_code/` prefix; dropped 2026-04-27 — extension + manifest kind already disambiguates from static, so the prefix was pure ceremony.
- `_static/<path>` is the system-reserved prefix for raw bytes; other top-level `_*` paths are reserved for system use (`_triggers/`, `_404/`, `_500/`, etc.)
- `MAX_PATH_LEN = 192`; file-size caps of 1MB static / 64KB handler (plan; not yet enforced)
- Bulk deploy is **full-replacement** — client sends the entire manifest. Single-file save endpoint exists for the "edit one file" UX; bulk deploy replaces everything not in the request.

### Webhook / email semantics

- **At-least-once delivery.** Receivers must dedup on the stable id header the
  `webhook.send` shim stamps (see handler-shape.md / `architecture/effects-and-handlers.md`).
- **No ordering guarantees.** Chain via callbacks if ordering matters.
- **`webhook.send` is vendor-neutral.** No default signing header; use `crypto.hmacSha256` to build vendor-specific signatures in the handler before `webhook.send`.
- **`email.send` takes `key` as an explicit argument.** Customer's abuse-control concern; keep the Resend key in KV and pass it at call site.
- **Response body captured at 256KB max.** Anything larger is truncated with `truncated: true` on the callback event.
- **Outbound is gated (SSRF + TLS-always; wired 2026-06-11).** Every
  customer-supplied URL is policy-checked per attempt — `https` only, every
  resolved address blocklist-checked (RFC 1918 / loopback / link-local
  metadata / CGNAT / …), the vetted address set pinned on the connection —
  and **`http.fetch` does not follow redirects** (the handler sees the 3xx
  and composes the follow; each hop re-enters the gate). A blocked fetch
  surfaces as a failed outcome (`ok=false, status=0`). decisions.md §3.8;
  as-built: `architecture/routing-and-ingress.md` "Outbound policy gate";
  smoke: `scripts/smoke/ssrf_smoke_v2.py`. The smoke-only
  `REWIND_UNSAFE_OUTBOUND=1` hatch relaxes loopback + TLS-always for test
  topologies — never production.

### Auth / signup

- **Magic link TTL 30 min, single-use.** A redeemed link 401s on replay. (Was 15 min in early drafts; bumped 2026-04-30 so click-late users land on the happy path.)
- **Session cookie is `HttpOnly + Secure + SameSite=Lax`.** `Secure` requires HTTPS; localhost is treated as a secure context by modern browsers, but plain-HTTP non-localhost dev won't get the cookie. Use `curl -H 'Cookie: rove_session=...'` manually for HTTP-only dev.
- **Signup without Resend key configured** → response body carries `magic_link` in-band so dev + CI smoke tests still work. When a key IS configured, `magic_link` is suppressed and the email is queued via outbox.
- **Reserved instance names** rejected with 409: `admin`, `api`, `app`, `www`, `__admin__`, `auth`, `login`, `signup`, `logout`, `dashboard`, `static`, `system`, `public`, `root`, `mail`. Collisions on real signups also return 409 with the same body (no enumeration).

### Admin scope + platform capability

- `platform.*` JS globals exist only on the `__admin__` handler. Other tenants' handlers see `platform === undefined` and get a `TypeError` if they try to call `platform.root.*`.
- **Cross-tenant admin access is the explicit `platform.scope(id).kv` accessor** — the V2 change from the old `X-Rove-Scope` header, which no longer rebinds the global `kv` (so admin's own home store, including sessions, is scope-independent). `kv.*` on the admin handler always operates on admin's own `app.db`. See `architecture/auth-and-domains.md`.
- **Admin JS writes to `platform.root.*` are replicated via type-2 root writeset**, but they land locally on the leader first and propose-on-commit. A propose failure is logged, not compensated (kvexp volatility → no on-disk divergence on crash; the residual is the caller-response escaped effect, tracked as idiom-3 in `docs/decisions.md` §9).

### Multi-node setup (V2)

- **Each tenant is its own raft group.** Customer KV writes, root metadata, and
  the per-tenant `_deploy/current` release pointer replicate via raft (envelopes
  0/1/2). **Blob bytes do not** — bytecode/statics, deploy manifests, and log
  batches all live in the shared content-addressed store / S3.
- The blob backend is **S3-shaped object storage only** (`S3_*` / `AWS_*` env
  vars — `rove-blob`'s `env.zig`); there is no filesystem variant, even
  single-node, so every node reads the same content-addressed store and
  replay survives tenant moves.
- **A write in flight at a leader change is *faulted + retried*, not lost** — the
  parked worker fails fast (421 not-leader) and the front door's leader-aware
  proxy re-aims at the new leader (decisions.md §10.5; ambiguous post-propose
  503s relay un-retried). On failover the new leader has the full
  manifest but may 503 on a blob not yet visible in the shared backend (served
  on first read).
- Outbound HTTP delivery (`webhook.send` shim): per-tenant `_send/owed/{id}`
  markers ride envelope-0 atomic with handler writes; on leader change a boot/cron
  sweep replays unresolved markers — at-least-once with id dedup. See
  `architecture/effects-and-handlers.md`.
- WAL growth is bounded by the per-tenant **durabilize/compaction** tick, not a
  global snapshot pass (`architecture/consensus-and-storage.md`). Tenant placement
  + no-downtime moves are the control plane's job (`architecture/control-plane.md`).

### Operational

The V2 operator surface (the five binaries, their flags / env, deploy + rollout)
is **not** documented here — see [`architecture/configuration-and-network.md`](architecture/configuration-and-network.md)
(binaries, flags/env, ports, the firewall boundary, TLS) + the operator's own
deploy specifics in the private `rewind-infra` repo, the `/deploy` skill, and the per-subsystem `architecture/` docs
(`control-plane.md` for the CP/directory, `consensus-and-storage.md` for node
config, `deployment-and-logs.md` for the publisher + log-server). The V1
`loop46`-era flags (`LOOP46_ROOT_TOKEN`, `--snapshot-interval-ms`,
`--files-public-base`, the `files-server-standalone` / `log-server-standalone`
process pair) are retired with the V1 binary.

## 13. Servers and surfaces (V2)

The canonical map of "which process owns what." This is the **V2** line; the V1
`loop46` single-binary world — the leader-pinned schedule-server / `SendDispatch`
threads, `schedules.db`, the in-process files/log proxies — is retired. The
`architecture/` set owns the detail (start at
[`architecture/overview.md`](architecture/overview.md)); this is the orientation
table.

### 13.1 Process inventory

rewind.js ships as **five binaries**, all `zig build` steps from this repo:

| Binary | Source | Build step | Owns |
|---|---|---|---|
| `rewind-worker` | `src/rewind/main.zig` | `zig build rewind-worker` | The **worker / data-plane node**: per-worker QuickJS (arenajs) dispatcher; the per-tenant `Bridge` over the multi-raft `Node`; HTTP/2 serving; held-connection + streaming state; the durable-wake scheduler sweep (`_sched/`, gap 2.6 — webhook/email deferred fires, durable cron, and crash-recovery watchdogs all ride it; the per-feature owed/cron sweeps are deleted); `/_system/deploy` (compile + content-address + stamp manifest, on a background `DeployThread` off the poll loop — files-server dissolved, `rewind-cli-plan.md` §4), `/_system/release`, `/_system/v2-*` (move), `/_system/services-token` machine-to-machine endpoints. Hosts the DP system tenants `__admin__` / `__replay__` / `__auth__`. |
| `rewind-front` | `src/front/main.zig` + `src/front/proxy.zig` | `zig build rewind-front` | The **front door** (stateless edge): terminates TLS (own ACME), routes `Host → cluster` from the CP directory (cached, off the hot path), STREAMING leader-aware proxy (pooled h2c client legs, bodies relay both directions as they arrive, 421 re-aim with replay buffer). (Tenant moves are the CP's `POST /_control/move`.) |
| `rewind-cp` | `src/cp/main.zig` | `zig build rewind-cp` | The **control plane** (a small dedicated raft cluster, 3–5 voters): the replicated `__directory__` group — authoritative `Host → cluster` placement, per-tenant `plan/*`, ACME `cert/*`. Sequences tenant moves; the directory flip is the move commit point. |
| `log-server` | `src/log_server/*` | (standalone) | The **request-log query surface**: polls S3 for per-node `.ndjson` log batches + sidecars, maintains a local SQLite `log_index.db`, serves `/v1/{tenant}/{list,show,count}` to the dashboard. No raft. |

Deploy/publish is **not** a separate binary: the worker's `/_system/deploy`
endpoint compiles + content-addresses + stamps the manifest in-tenant on a
background thread (files-server dissolved — `rewind-cli-plan.md` §4); the
`_deploy/current` flip stays `/_system/release`.

The CP/DP split is the V2 structural call (decisions.md §10.1): per-tenant
consensus lives in `rewind`, placement authority lives in `rewind-cp`, the edge
is stateless. `log-server` participates in no raft — its state is in S3 — so it
lives outside the worker. That is the §6b separability principle restated for
V2: the axis is **raft participation**, not public-TLS presence.

Inside `rewind` there are two threading roles:

- **Worker threads** (one per `--workers`, default `cpus-1`; all bind the h2 port
  via `SO_REUSEPORT`). Each owns a per-worker arenajs `Dispatcher`. Any worker
  handles any tenant — no tenant pinning. Inbound lands on any worker; async wakes
  hash to `hash(tenant) % N`, with `MsgRouter` routing a wake to the worker that
  *holds* the continuation when held state lives elsewhere (continuation-affinity
  — `architecture/effects-and-handlers.md`).
- **The consensus pump** (the `Node`, `src/consensus/`). Drives the active
  (non-hibernated) raft groups, the shared-fsync WAL (one fsync per pump cycle),
  role-aware apply, and the periodic durabilize/compaction tick.

The system surfaces resolve on the **system domain**: `app.` → `__admin__` (the
OIDC-RP dashboard), `replay.` → `__replay__`, `auth.` → `__auth__` (a full OIDC
IdP running the customer `oidc.provider()` library). They are ordinary DP
tenants, not a privileged platform path (`architecture/auth-and-domains.md`).

### 13.2 Storage map

| Store | Scope | Replicated via | Owner / notes |
|---|---|---|---|
| `__root__.db` | per cluster | raft envelope 2 | routing + tenant registry (`domain/`, `instance/`); ACME `cert/{host}` |
| `{id}/app.db` | per tenant | raft envelope 0 | customer kv; `_deploy/current`; `_callback/{id}`; `_send/owed/{id}` markers; `_config/*` (deploy-mirrored, read-only to handlers) |
| `__admin__` / `__auth__` / `__replay__` `app.db` | per cluster (system tenants) | raft envelope 0 | OIDC RP/IdP state, operator allowlist, account/instance ownership, platform config |
| CP `__directory__` (kvexp) | CP cluster | CP raft (apply-observer projection on every node) | `cluster/{id}`, `placement/{tenant}`, `plan/{tenant}`, `host/{host}`, `cert/{host}` |
| shared WAL | per node | n/a (it *is* the log) | all of a node's raft groups interleaved; one fsync per pump cycle; per-group recovery + compaction watermark |
| `{id}/file-blobs/{hash}` | per tenant, in `BlobBackend` (s3) | shared backend across nodes | the worker's `/_system/deploy` writes; worker reads on bytecode-cache miss; bytes never ride raft |
| `{prefix}{id}/deployments/{dep_id}.json` | per-tenant manifest, S3 | shared backend | the worker's `/_system/deploy` writes; worker fetches on the `_deploy/current` flip; `dep_id` content-addressed, immutable |
| `{prefix}_logs/{node_id}/{batch_id}.ndjson` (+ sidecar) | per node, S3/fs | n/a (log-server polls + by-key push) | worker batches; log-server indexes |
| `log_index.db` | log-server-local | rebuildable from S3 | log-server |

Only three envelope types replicate through raft (`0` writeset, `1` multi,
`2` root_writeset); the full evolution + the retired-and-rejected type bytes are
in §10.2 / `architecture/consensus-and-storage.md`. Blob bytes, deploy manifests,
and logs all bypass raft (shared content-addressed store / S3).

### 13.3 JS surface for handlers (current)

The customer-visible handler API is specified in
[handler-shape.md](handler-shape.md); the effect model in
[effect-algebra.md](effect-algebra.md). In brief, what a handler sees:

- **Native bindings** (Zig → arenajs): `kv.{get,set,delete,prefix}`;
  **`http.fetch`** — the *single* native outbound primitive; `crypto.*`
  (`getRandomValues`, `randomUUID`, `randomBytes`, `sha256`, `hmacSha1` /
  `hmacSha256`, `verifyRsa`, `verifyEcdsa`, `timingSafeEqual`); the streaming /
  held-connection verbs (`stream` / `next` / `on.*`); `platform.*` (admin tenant
  only); standard intrinsics (`JSON`, `Date`, `RegExp`, `Map`/`Set`, `Promise`,
  `BigInt`, typed arrays).
- **JS standard-library shims** (embedded into every context): `webhook.send` /
  `email.send` / `retry.*` (durability composed over `http.fetch` + `_send/owed/` markers + durable-wake
  markers; vendor-neutral), `base64` / `base64url` / `hex`, `URLSearchParams`,
  `TextEncoder` / `TextDecoder` (UTF-8).
- **Curated libraries** (opt-in by call site): `jwt`, `oauth.fromConfig(name)`,
  `sessions.fromConfig(name)`, `cron.*` — backed by the deploy-time `_config/*`
  mirror (§13.4).

Deliberately **not** available: `http.send` / `http.cancel` and `events.emit`
(retired); `fetch`, `setTimeout` / `setInterval`, `XMLHttpRequest`, full `URL`,
`Response` / `Headers`, `atob` / `btoa`, `console.error`/`.warn`/`.info`,
`WeakRef` / `Proxy` (never offered — see §12 + handler-shape.md).

The handler is `update : (Msg, Ctx) → (Effects, Cmd Msg)` — the runtime IS the
Elm runtime, ferrying recorded `Msg`s to the handler, applying the writeset, and
routing the returned `Cmd` (terminal response / `next` continuation / `stream`)
to the next state. The Cmd-shape return is the single customer-visible API that
drives all downstream runtime behavior; customer code never sees the chain-level
state on the entity. Full model: decisions.md §3.1 +
`architecture/effects-and-handlers.md`.

### 13.4 Deploy-time `_config/*` mirror

At deploy release-time the worker walks the new manifest for `_config/{...}.json`
entries, fetches each blob, and stages writes to `_config/{path-without-.json}`
in the customer's app.db inside the same `TrackedTxn` that flips `_deploy/current`
(stale `_config/*` rows absent from the new manifest are staged for delete — the
file tree is authoritative). Customers cannot write `_config/*` from handlers
(reserved prefix); handlers read via `kv.get("_config/...")`. This is what makes
`oauth.fromConfig("google")` and `sessions.fromConfig("default")` clean — config
is in version control, atomic with the deploy, and read-cheap from kv.
Implementation in `src/js/config_mirror.zig`.

### 13.5 Relationship to the §3 phase plan

§3 still describes the *content* of each phase, but several phases were
substantially restructured by Phase 5.5 and the V1→V2 cutover (Webhooks/email →
the `http.fetch` + JS-shim model; the platform SSE pipe → customer `stream(...)`
handlers; the single `loop46` binary → the five-binary CP/DP split above). When
reading §3 for *what* a phase delivers, cross-check this section and the
`architecture/` reference set for what actually exists today.
