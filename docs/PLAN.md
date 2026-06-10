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
mandatory SSRF block + TLS-always. Why durability-as-JS-shim (and the three
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
the limits live on the CP plan axis (`architecture/control-plane.md`). Plan-tier
strategy: [plan-tiers.md](plan-tiers.md).

### 2.11 CLI (v1 scope)

`loop46 deploy ./dir` (content-addressed two-phase upload) + a `loop46.json`
project file; token copy-paste auth. Ships at 1.0, not beta (§10.16). Later
`kv` / `logs` / `init` commands deferred (§4).

### 2.12 Live UI updates — customer-defined streaming, not a platform pipe

There is **no** platform-managed SSE / event pipe (the original `events.emit` +
sse-server was deleted). Customers write their own streaming handler returning
`stream(...)`, with watched-prefix kv-write wakes driving frame emission — the
customer's kv *is* the event log they choose to keep; cross-node correctness
rides raft. SSE is the default push channel (HTTP/2-native, browser
auto-reconnect with `Last-Event-ID`); inbound WebSocket is a separate baseline
([websocket-plan.md](websocket-plan.md)). Surviving locked decision: notification
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

**Cross-cutting for every phase**:
- `deployment_id` on all request logs.
- Raft apply hook for cache invalidation.
- Shared path-validation module across upload APIs.
- Logger nesting for triggers/webhooks/callbacks under parent `request_id`.
- All admin API paths versioned `/v1/` from day one.

### Phase 1 — Domain infrastructure

- Register `rewindjs.app`.
- DNS: apex + wildcard `*.rewindjs.app` pointed at server IP, proxied through Cloudflare.
- Wildcard LE cert via `scripts/rove-lego-renew.sh` (ACME DNS-01). rove-js reads `cert.pem`/`key.pem` directly and terminates TLS in-process; Cloudflare fronts with Full/Strict.
- Host routing lives in the worker (`*.rewindjs.app` + `app.rewindjs.com` both hit js-worker; dispatcher splits by host). No reverse proxy.
- Response layer: sanitize `Set-Cookie` `Domain=` attribute (strip).  **Done**: `sanitizeSetCookie` in `src/js/dispatcher.zig:819`, applied in `extractResponseMetadata` on every JS handler response. Covered by 9 inline tests.
- `rove-tenant` wildcard domain resolution — accept any `*.rewindjs.app` matching a registered instance id.
- PSL submission (`rewindjs.app` → `publicsuffix/list`) **deferred to Phase 10**. Server-side Domain stripping above is the authoritative defense; PSL is defense-in-depth at the browser level and its propagation lag makes it unsuitable for the launch path.

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

> Note: as initially shipped, Phase 3 used a per-tenant
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
- Starter content: one `index.mjs` (uses `kv`, returns JSON), one `_static/index.html` that fetches it and shows "your API is live at `{name}.rewindjs.app`".
- **Lazy-creation-on-redeem (abuse prevention).** The customer tenant is *not* created at signup — only a `pending/{name}` reservation in admin app.db. Tenant creation, root_writeset propose, and starter-content deploy all happen inside `redeemMagic`, atomically with the session mint. A periodic sweep deletes expired `pending/*` entries to free the name. Without this, an unredeemed signup squats the name and leaks `{id}/app.db`, `{id}/files.db`, and the file-blob directory indefinitely. Detailed flow in [`docs/flows/signup.md`](flows/signup.md).
- **Per-account instance limit.** Email is the account identity. New `account/{sha256(email)}/...` namespace in admin app.db owns the plan tier (`account/{hash}/plan`) and the instance ownership index (`account/{hash}/instances/{instance_id}`). Signup-time check counts owned instances *plus* non-expired `pending/*` reservations against the account's `max_instances` — both count, otherwise the free tier is trivially evadable by squatting names via incomplete signups. Same check repeats at redeem-time as the authoritative gate (two simultaneous signups by one email could both pass at signup time; only the second to redeem hits the limit). v1 hardcodes `max_instances = 1` for free; Phase 10 wires the value from a per-tier config keyed on `account/{hash}/plan`. Seed-manifest tenants stay outside the account model entirely — operator-provisioned, no associated email, no `account/*` record. The same `account/{hash}/plan` lookup will eventually drive *all* per-account caps (request/email rate limits, DLQ retention, blob storage caps, custom-domain counts, plus Stripe customer linkage in Phase 10).

### Phase 5 — Minimal admin UI

- Deploy admin UI to `app.rewindjs.com` **using Phase 2's file API**. Dogfood.
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
> `docs/architecture/deployment-and-logs.md` covers item 1 (logs leave raft entirely, go S3-direct
> with a sidecar-indexed log-server on `logs.{public_suffix}`).
> `docs/architecture/consensus-and-storage.md` covers item 3 (per-tenant snapshot indices with
> S3 transport — replaces the original "raft snapshot + log compaction" with
> a no-pause file-shipping model).
> Item 4 (originally a webhook-shaped subsystem) shipped through three
> generations and finally landed as durability-as-JS-shim — see
> `architecture/effects-and-handlers.md` Phase 5 + memory
> `project_durability_as_js_shim`.
> `docs/architecture/deployment-and-logs.md` covers item 5 (files-server moves to its own
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
   state via `webhooks.db` with zero scan cost. The current generation
   (durability-as-JS-shim, shipped 2026-05-24) replaces all of this
   with composition over `kv.set` + `http.fetch` — see
   `architecture/effects-and-handlers.md` Phase 5.

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
   runtime release signal becomes a `_deploy/current` kv marker written by
   a `POST /_system/release` worker route and picked up via apply.zig's
   writeset-value scan into a process-wide ReleaseTable (no polling), worker reads
   bytecodes/statics on demand from S3 with content-hash ETags +
   Cloudflare in front. Worker drops the entire `/_system/files/*` proxy
   and the `files.db` per-tenant store (envelope type 3 retires); the §2.4
   routing/cache/path-validation/size-cap rules carry forward unchanged.
   Detail in `docs/architecture/deployment-and-logs.md`. Lower urgency than (a)/(c)
   (files.db doesn't blow up under sustained traffic the way log.db does)
   but unblocks multi-node deployment (S3-backed manifest IS the cross-node
   share path) and removes ~2 replicas-worth of in-process state from the
   worker.

Single-host launch defaults to `FilesystemBlobStore` against the local `{data_dir}`; multi-node launch picks `S3BlobStore` (shipped — see §10.5 + `architecture/consensus-and-storage.md` "Blob replication") or a shared FS mount via `BLOB_BACKEND`. The work above is backend-agnostic because `BlobStore` is already the abstraction seam. **First customer can now take real production traffic without disk-fill within weeks.** MVP complete.

The further detach of files-server / log-server into separately-deployed
processes that admin's JS handler calls via `webhook.send` (rather than
the worker proxying) is **post-1.0** — see §10.13 + `architecture/deployment-and-logs.md`
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
customer-arbitrary SSE handlers on `__rove_stream` + kv-write wakes
replace it. See §2.12 + `docs/architecture/effects-and-handlers.md`.

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

What's deferred (not in v1): hosted HTTP MCP at `mcp.rewindjs.com`, `loop46-mcp` binary, MCP wire-format code. Build when a real remote-agent use case shows up.

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

- `docs/architecture/deployment-and-logs.md` — §2.4 + Phase 5.5 (e) expansion:
  own subdomain, manifest in S3, marker-driven release, async
  load + atomic pointer swap, Cloudflare-fronted static serving.
  Also contains the post-1.0 detach detail (§11) — editor
  bearer-auth flow, deploy-notification path, work-order list,
  latency mitigations.
- `docs/architecture/deployment-and-logs.md` — §2.9 + Phase 5.5 (a) expansion: S3-direct
  batches with `.idx.json` sidecars, log-server on
  `logs.{public_suffix}`. Envelope type 1 retires.
- `docs/architecture/effects-and-handlers.md` — covers §2.6 outbound HTTP after
  the 2026-05-24 durability-as-JS-shim retirement. Customer-facing
  `webhook.send` / `email.send` API preserved as JS shims composing
  on `http.fetch` + `kv.set("_send/owed/{id}", ...)`. Earlier
  generations (`webhooks.db` envelopes 4/5/6 shipped 2026-05-06,
  `schedules.db` envelopes 8/9/10/11 shipped 2026-05-09, per-tenant
  `_send/owed/` + leader-local `SendDispatch` shipped 2026-05-19) are
  all retired; the sub-plan docs were removed.
- `docs/architecture/consensus-and-storage.md` — §2.13 + Phase 5.5 (c) expansion:
  per-tenant snapshot indices, S3 transport, no global
  write-pause. Replaces the row-level delta protocol in
  `src/kv/raft_snapshot.zig`.
- `docs/sim-test-framework.md` — §10.7 + §10.8 expansion: simulator
  module, `_tests/` directory, `loop46 test` / `loop46 simulate`.
- `docs/fixture-lifecycle.md` — §10.9 + §10.11 expansion: fixture
  authoring tooling + worker dry-run dispatch mode.
- `docs/agent-surface.md` — §10.10 expansion: skill file, `--json`
  audit, `loop46 doctor`, scoped tokens.
- `docs/architecture/observability.md` — §2.9 expansion on the operator side:
  Grafana Cloud cutover plan. Inventories today's `/_system/metrics`
  (15 series, postmortem-shaped) and phases the gap to a fleet
  scrape — auth via a `scrape` services-JWT cap, node/worker labels,
  histogram primitive, OpenMetrics exemplars carrying
  trace_id/tenant_id/request_id. Load-bearing constraint: customer
  request logs stay in the replay store (`docs/architecture/deployment-and-logs.md`); only
  operator signals go to Grafana.

## 6b. Architectural principle: separability follows raft participation

The right axis for "should this subsystem be its own process /
binary / machine" is **whether it participates in raft**, NOT
whether it has a public TLS surface (the original heuristic).

> **Subsystems that participate in raft live in the worker binary.
> Subsystems that don't can be split into their own processes /
> machines.**

Participation = reads raft-replicated state, OR proposes
envelopes, OR is leader-pinned by definition.

> **V2 note.** The principle holds and is *why* `files-server-v2` and
> `log-server` are separate binaries (no raft participation, state in S3) while
> the per-tenant consensus stays in `rewind`. The V1 examples in the table below
> (the single `loop46` binary, the leader-pinned `webhook-server` thread) are
> retired; durability is now a JS shim, not a raft-participating subsystem. See
> §13 for the live V2 process map.

| Subsystem | Participates in raft? | Where it lives |
|---|---|---|
| worker (customer kv path) | yes (proposes envelope 0; leader-only) | loop46 binary |
| files-server | no (state in S3) | own binary, own subdomain, separable to its own machine |
| log-server | no (state in S3 + local index cache) | own binary, own subdomain, separable to its own machine |
| webhook-server | yes (reads webhooks.db; proposes 4/5/6; leader-pinned) | thread in loop46 binary |
| (future) anything else needing raft state | yes by definition | thread in loop46 binary |
| (future) anything else stateless wrt raft | no | candidate for separate binary |

The principle lets us cleanly answer the "split or not" question
without re-litigating the tradeoffs case by case.

## 6c. Leader-only public surface

> **V2 note.** This subsection described V1's *single* raft group (one cluster
> leader). V2 is **multi-raft — one group per tenant** — so leadership is
> per-tenant, not per-node: any node may lead some tenants and follow others.
> The model below is reframed in V2 as: the stateless front door
> (`rewind-front`) proxies each request leader-aware *per tenant*
> (`proxyToCluster`, retry-on-503), reads are served by any synced node, and a
> write self-routes to that tenant's group leader. See
> `architecture/consensus-and-storage.md` + `architecture/routing-and-ingress.md`.

Related architectural property (V1): **only the raft leader accepts
customer requests.** Workers run only on the leader; followers are
pure raft replicas with no public listeners. Customer-facing LBs
route the worker subdomain (and the files-server / log-server
subdomains) to the current leader; on raft election, the LB switches.

Implication for the separable subsystems: while files-server /
log-server CAN run on different machines from any raft node (their
state is in S3), they're typically deployed on every node with a
leader-pinned active state — same pattern as webhook-server but at
process granularity instead of thread granularity. Operators who want
to scale them independently can, because nothing in their architecture
requires co-location.

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
- **SSE rows in customer's `app.db` under reserved prefix `_events/{sid}/{seq}`**, replicated through raft envelope 0, with a per-tenant retention sweep + Last-Event-ID catch-up over the persisted rows. Rejected (2026-05): SSE is a notification channel, not a source-of-truth state store; the reserved-prefix storage entangled SSE state with customer kv writesets, raft replication, the markDirtyFromWriteset scan, and a 365-line retention sweep — for semantics that are explicitly losable and recoverable via replay. The "notification ≠ state store" decision carried first into a platform-managed sse-service (deleted 2026-05-19) and now into customer-arbitrary `__rove_stream` handlers backed by the customer's own kv watched prefixes (see `docs/architecture/effects-and-handlers.md`).
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
- **Cmd-pattern outbound path: `webhook.send` is the only door to the outside world**, accumulated alongside the writeset and proposed atomically with kv writes.
- **Deterministic triggers in the same KV transaction as the write.**
- **Tape capture on every request, encrypted at rest.**
- **Browser-based replay with DevTools breakpoints on production bugs.**
- **One URL for the whole app (static + API + admin-of-admin).**
- **Magic-link signup → live API in under a minute.**

Nobody is offering this combination. The marketing headline is the functional core + replay; the developer hook is the one-minute demo. The rest of the plan is making both of those true.

## 9. Implementation status

Live status is **not** tracked in this document anymore. The authoritative
current picture is:

- `docs/v2-cutover-checklist.md` — the V2 dashboard (what's shipped / in-flight /
  open on branch `v2`).
- The `architecture/` reference set — each doc's **"Known limitations
  (as-built)"** section is the per-subsystem status of record.

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
| 10.7 | Simulator primitive (purely client-side, KV-less) | [sim-test-framework.md](sim-test-framework.md); decisions.md §8 |
| 10.8 | Sim test framework (deterministic, local-only) | [sim-test-framework.md](sim-test-framework.md); decisions.md §8 |
| 10.9 | Fixture lifecycle (curated observations) | [fixture-lifecycle.md](fixture-lifecycle.md) |
| 10.10 | AI agent surface — CLI + skill file in v1, hosted MCP deferred | [agent-surface.md](agent-surface.md); decisions.md §8 |
| 10.11 | Worker dry-run dispatch mode | [fixture-lifecycle.md](fixture-lifecycle.md) |
| 10.12 | Replay — two paths (browser page + DAP CLI), one per audience | [replay-wasm-plan.md](replay-wasm-plan.md); decisions.md §8 |
| 10.13 | files-server + log-server detached to their own processes | `architecture/deployment-and-logs.md`; §13 here |
| 10.14 | Distributed Elm ports (webhook + callback + streaming) | [effect-algebra.md](effect-algebra.md); `architecture/effects-and-handlers.md` |
| 10.15 | `analytics.track` / `metrics.*` — speculative, post-1.0 | decisions.md §12; `architecture/observability.md` |

### 10.16 Launch sequencing: lead with replay, two-audience framing locked in (decided 2026-04-30)

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
4. **Phase 14 LLM skill file** (`docs/skills/loop46.md`) — AI-assisted rewind.js coding. Without it, LLMs default to imperative `await fetch()` patterns that don't compile. ~1 week.
5. **Story 1 leaderboard example tenant** — the literal Firebase-pain demo, 5 lines of handler + one HTML page. ~½ day. Pairs with the beta launch post.
6. **Beta operational** — free-tier caps wired to existing rate limiter defaults, beta banner in dashboard, data-continuity promise visible at signup, feedback channel link, per-account storage cap enforcement. ~3-5 days. Detail in §10.17.

**Beta total**: ~5 weeks serialized; ~3 weeks with two-person parallelization (Phase 5 polish + replay page parallelize cleanly; CodeMirror upgrade lands alongside Phase 5 polish without coupling).

**1.0 launch path** (Story 2 audience adds, builds on top of operating beta):

1. **Tape-replay DAP CLI** (§10.12 Story 2 path) — `loop46 replay <request_id>` CLI fetching bundle + tape, writing a Node entry script with stubs preloaded, spawning under `--inspect-brk`, printing attach instructions for VS Code / JetBrains / nvim-dap / dap-mode. Reuses the stubs library shipped in beta. ~1-2 weeks.
2. **rewind.js-the-project Stripe integration for supporter payments** — *the real production integration that doubles as the customer-facing docs example.* rewind.js's admin handler exposes a "support rewind.js" page that creates a Stripe Checkout session via `webhook.send`, returns a tiny shell page that opens a `__rove_stream` connection, the callback writes a kv key that wakes the stream which emits the session URL to the connected client, browser navigates. Receives `checkout.session.completed` webhook with timing-safe HMAC signature verification, writes a `supporter/{email}` row in admin's app.db, the same stream wakes a second time and emits "Thanks!" so the originating tab updates without a refresh. **Docs example is extracted from this**: the patterns we actually use become the patterns we teach. ~1.5-2 weeks, plus the small primitives audit (`crypto.timingSafeEqual` confirmed; `base64Encode/Decode` and `hmacSha1` if needed).
3. **Phase 7 `loop46 deploy` CLI** subset — content-addressed two-phase upload, `loop46.json` parsing, deploy-token issuance UI in dashboard. ~1-2 weeks for v1 scope; later CLI subcommands (`kv`, `logs`, `init`) deferred.
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
- DAP CLI replay (`loop46 replay`)
- Stripe-on-rewind.js supporter payments
- `loop46 deploy` CLI
- Plan tiers + paid pricing
- Custom domains
- Phase 9 encryption (only if B2B compliance demand surfaces during beta)

**What's NOT in either beta or 1.0** (recorded so future-us doesn't second-guess):
- §10.13 / §10.14 file-server + log-server detach + bearer-auth dogfooding. Multi-week refactor that makes the architecture purer but doesn't make the product more useful to a first user. **Post-1.0** when the dashboard-to-file-server path's in-process proxy starts hurting (it doesn't yet). The detach is gated only on engineering bandwidth, not blocking primitives.
- §10.15 `analytics.track` + `metrics.*` primitives. Their absence is workable (customers `webhook.send` to their OLAP / TSDB of choice). **Post-1.0** alongside the loop46-olap / loop46-tsdb pseudo-third-party companion services that motivate them.
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
- The `loop46` binary during beta only ships operator commands (`loop46 dev`, `loop46 worker`) — no customer-facing subcommands.
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
- **A dev-only flag relaxes SSRF + HTTPS-only on the outbound `http.fetch` path** for local smokes. NEVER set in production — a malicious customer handler could probe localhost and leak bodies over plaintext.

### Auth / signup

- **Magic link TTL 30 min, single-use.** A redeemed link 401s on replay. (Was 15 min in early drafts; bumped 2026-04-30 so click-late users land on the happy path — full flow in [`flows/signup.md`](flows/signup.md).)
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
- Running more than one node requires a shared `BlobStore` backend: a shared
  filesystem mount at `{data_dir}` (NFS/EFS/Ceph) or `BLOB_BACKEND=s3` (+ the
  `S3_*` / `AWS_*` env vars). With single-host `fs`, tape/asset bytes are
  node-local and replay 404s after a move for old request IDs.
- **A write in flight at a leader change is *faulted + retried*, not lost** — the
  parked worker fails fast (503) and the front door's leader-aware proxy retries
  the new leader (decisions.md §10.5). On failover the new leader has the full
  manifest but may 503 on a blob not yet served by the shared backend (served on
  first read for S3; transparently for an FS mount).
- Outbound HTTP delivery (`webhook.send` shim): per-tenant `_send/owed/{id}`
  markers ride envelope-0 atomic with handler writes; on leader change a boot/cron
  sweep replays unresolved markers — at-least-once with id dedup. See
  `architecture/effects-and-handlers.md`.
- WAL growth is bounded by the per-tenant **durabilize/compaction** tick, not a
  global snapshot pass (`architecture/consensus-and-storage.md`). Tenant placement
  + no-downtime moves are the control plane's job (`architecture/control-plane.md`).

### Operational

The V2 operator surface (the five binaries, their flags / env, deploy + rollout)
is **not** documented here — see [`v2-production-deploy-plan.md`](v2-production-deploy-plan.md),
the `/deploy` skill, and the per-subsystem `architecture/` docs
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
| `rewind` | `src/rewind/main.zig` | `zig build rewind` | The **worker / data-plane node**: per-worker QuickJS (arenajs) dispatcher; the per-tenant `Bridge` over the multi-raft `Node`; HTTP/2 serving; held-connection + streaming state; the durable-wake scheduler sweep (`_sched/`, gap 2.6 — webhook/email deferred fires, durable cron, and crash-recovery watchdogs all ride it; the per-feature owed/cron sweeps are deleted); `/_system/release`, `/_system/v2-*` (move), `/_system/services-token` machine-to-machine endpoints. Hosts the DP system tenants `__admin__` / `__replay__` / `__auth__`. |
| `rewind-front` | `src/front/main.zig` | `zig build rewind-front` | The **front door** (stateless edge): terminates TLS (own ACME), routes `Host → cluster` from the CP directory (cached, off the hot path), leader-aware proxy (`proxyToCluster`, retry-on-503), orchestrates tenant moves (`POST /_control/move`). |
| `rewind-cp` | `src/cp/main.zig` | `zig build rewind-cp` | The **control plane** (a small dedicated raft cluster, 3–5 voters): the replicated `__directory__` group — authoritative `Host → cluster` placement, per-tenant `plan/*`, ACME `cert/*`. Sequences tenant moves; the directory flip is the move commit point. |
| `files-server-v2` | `examples/files_server_v2.zig` | `zig build files-server-v2` | The **deploy publisher** (cluster-free): compiles + uploads bytecode/static blobs + a content-addressed manifest to S3; bootstraps the `__admin__` / `__replay__` bundles; flips `_deploy/current` via the worker's `/_system/release`. Runs no raft of its own. |
| `log-server` | `src/log_server/*` | (standalone) | The **request-log query surface**: polls S3 for per-node `.ndjson` log batches + sidecars, maintains a local SQLite `log_index.db`, serves `/v1/{tenant}/{list,show,count}` to the dashboard. No raft. |

The CP/DP split is the V2 structural call (decisions.md §10.1): per-tenant
consensus lives in `rewind`, placement authority lives in `rewind-cp`, the edge
is stateless. `files-server-v2` and `log-server` participate in no raft — their
state is in S3 — so they live outside the worker. That is the §6b separability
principle restated for V2: the axis is **raft participation**, not public-TLS
presence.

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
| `{id}/file-blobs/{hash}` | per tenant, in `BlobBackend` (fs\|s3) | shared backend across nodes | files-server-v2 writes; worker reads on bytecode-cache miss; bytes never ride raft |
| `{prefix}{id}/deployments/{dep_id}.json` | per-tenant manifest, S3/fs | shared backend | files-server-v2 writes; worker fetches on the `_deploy/current` flip; `dep_id` content-addressed, immutable |
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
reading §3 for *what* a phase delivers, cross-check this section and
`docs/v2-cutover-checklist.md` for what actually exists today.
