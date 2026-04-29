# Signup flow

> **Status:** draft. Not canon. The locked architecture lives in
> [`docs/PLAN.md`](../PLAN.md); this doc is an explainer of the *current*
> implementation, written to surface simplification candidates and seed a
> future technical article.
>
> **Heads up:** the current flow described below allocates the customer
> tenant up-front, before the magic link is redeemed. That has an
> abuse-prevention problem (an unredeemed signup squats the name and
> leaks per-tenant resources). A redesign — *lazy creation on redeem* — is
> documented at the end of this doc as the proposed Phase 4 amendment, and
> tracked in PLAN.md Phase 4. The phase-by-phase description below still
> describes today's code.

This walks one customer signup from `POST /v1/signup` through tenant creation,
starter content deploy, magic-link mint, transactional-outbox email queue, the
asynchronous drain that calls Resend, the user clicking the link, magic-link
redeem, session-cookie mint, and the first authenticated request. Five
modules, three raft envelope types, two SQLite databases, and an HTTP
side-effect that lives or dies on at-least-once semantics.

It is the only multi-module path that combines all of: leader-local writes,
raft-replicated writes, a transactional outbox, an external HTTP side effect,
and short-lived single-use credentials. If any cross-module ordering bug
exists in this codebase, this is the most likely place to find it.

---

## The shape of a signup

```
HTTP POST /v1/signup
  ├─ validate name + email                   (sync, in-memory only)
  ├─ tenant.createInstance(name)             (writes root.db; in-memory map)
  ├─ proposeRootWriteSet(instance/{name})    (raft type 2 → followers)
  ├─ deployStarterContent(...)               (writes {id}/files.db + blobs)
  ├─ proposeFilesWriteSet(name)              (raft type 3 → followers)
  ├─ tenant.mintMagic(...)                   (admin app.db, leader-only)
  └─ queueSignupEmail(...)                   (tenant app.db: _outbox/{id})
                                                       │
                          (200ms-tick, leader-only)    │
       outbox-drainer thread ─────────────────────────►│
         ├─ scan _outbox/* → move to _outbox_inflight/
         ├─ HTTP POST to Resend
         └─ on success: delete inflight row

                  user clicks link in email
                                            │
                                            ▼
HTTP GET /v1/auth?mt=<token>
  ├─ tenant.redeemMagic(token)              (admin app.db, single-use delete)
  ├─ tenant.createSession(...)              (admin app.db, leader-only)
  └─ 302 → /#/{instance_id} + Set-Cookie    (cookie = opaque session id)

  next request with cookie
                                            │
                                            ▼
HTTP GET / (any path on customer subdomain)
  └─ requireAdminAuth → authenticateSession  (admin app.db lookup by hash)
```

Five physical writes for one signup: root.db marker (raft type 2), files.db
manifest + blobs (raft type 3 + filesystem blobs), magic token (leader-only),
outbox row (carried in the type 3 envelope above). The session, when it's
minted later, is one more leader-only write to admin app.db.

---

## Phase 0 — Request arrival and validation
(`handleAdminSignup`, `src/js/worker.zig:3805`)

Body parses as `{name, email}`. Synchronous gates:

- Email format and instance-id format check (`worker.zig:3832`–3849).
- Reserved-name check — protects names like `app`, `admin`, `__admin__`.
- `tenant.instanceExists(name)` (`worker.zig:3846`) for a duplicate-name 409.

All validation is in-memory against root.db's instance map. No raft activity
yet. Failures here return 400/409 cleanly without touching state — once we're
past line 3851, every failure becomes a 500-class error with partial state.

---

## Phase 1 — Instance creation
(`tenant.createInstance`, `src/tenant/root.zig:274`)

Two distinct steps:

1. `ensureOpen(id)` (`root.zig:533`) creates `{data_dir}/{id}/` and opens
   `{id}/app.db`. Adds the `Instance*` to `tenant.instances` (the worker's
   in-memory map). **The new tenant is now routable on the leader.**
2. `writeInstanceMarker(id)` (`root.zig:512`) writes
   `instance/{name}` → `""` to local root.db.

Then back in the handler, `proposeRootWriteSet` (`worker.zig:2755`) builds
a type-2 envelope (`apply.zig:121`) carrying the same `instance/{name}` key
and proposes it through raft. Followers apply the marker via
`applyRootWriteSet` (`apply.zig:457`) **after** raft commit.

**Important consequence**: between the local write (step 2) and the raft
commit, the leader has the marker and followers don't. If the leader fails
over in this window, the new leader has no record of the new tenant. The
customer would see their signup succeed (202) but find their domain 404.
Window is small (single raft round trip) but real.

No domain alias is written. `acme.loop46.me` resolves via the
public-suffix wildcard path in `tenant.resolveDomain` — the wildcard
extracts `acme` and looks up `instance/acme`. Custom domains (Phase 10)
will add explicit `domain/{host}` aliases.

---

## Phase 2 — Starter content deploy
(`deployStarterContent`, `src/js/worker.zig:4066`)

Optional — only fires if a JS compile function is wired. Behavior:

- Open `{id}/files.db`, build a `FileStore`, call `putSource("index.mjs",
  STARTER_INDEX_MJS)` and `putStatic("_static/index.html", ...)`.
- The store collects ops into a passed-in `files_ws` writeset.
- `store.deploy()` writes the manifest entry into files.db locally.
- Back in the handler, `proposeFilesWriteSet` (`worker.zig:2741`) sends a
  type-3 envelope keyed on the new tenant's instance id.

Failure here is **not fatal to signup** (`worker.zig:3896` logs and
continues). Customer gets a usable account but their domain returns 503
"no deployment" until they push code. Defensible — better to give them a
working magic link than to fail the whole signup over starter content.

---

## Phase 3 — Magic-link mint
(`tenant.mintMagic`, `src/tenant/root.zig:856`)

Generates 32 random bytes → 64-char opaque hex (the secret the user sees).
SHA-256 of the opaque → hash_hex. Stores
`magic/{hash_hex}` → `{"email", "instance_id", "expires_at_ns"}`
**in admin tenant's app.db** (`__admin__/app.db`), not in root.db. TTL
hardcoded at 15 minutes (`MAGIC_TTL_NS`).

Hash-at-rest pattern: only the hash is on disk; only the opaque is sent to
the user. A read of admin app.db cannot recover an unredeemed link.

**Not raft-replicated.** Magic tokens are short-lived single-use credentials;
losing them on leader failover is acceptable (TTL is shorter than typical
failover detection). The user can re-signup if their link disappears.

---

## Phase 4 — Outbox enqueue
(`queueSignupEmail`, `src/js/worker.zig:4142`)

Builds the Resend POST envelope (URL, auth header, body, retry knobs:
`max_attempts=5`, `timeout_ms=30000`) and writes
`_outbox/{random_64_hex}` → JSON envelope **into the new tenant's app.db**.

Crucially, this write happens *inside* the same raft propose as the
starter content (the `files_ws` from Phase 2 carries it). So the outbox
row is replicated for free; followers see it after the type-3 envelope
applies. Transactional outbox in the strict sense — the email side effect
is atomically queued with the deploy that triggers it.

If `bootstrap-resend-key` is unset (dev mode), the response body returns
the magic link directly so the developer can click it without an email
service.

---

## Phase 5 — Outbox drain
(`src/outbox/drainer.zig`, separate thread, leader-only, 250ms tick)

The drainer thread runs once per worker process, iterates every tenant
on each tick, opens their app.db, and prefix-scans `_outbox/*` (up to 64
per pass). For each row:

1. Move to `_outbox_inflight/{id}` with a lease timestamp.
2. Call `http_client.deliver()` with the envelope.
3. On 2xx: delete the inflight row.
4. On retry-eligible failure: write back to `_outbox/{id}` with bumped
   `retry_at_ms` and incremented attempts.
5. On terminal failure (5 attempts): move to `_dlq/{id}`.

**Lease recovery**: if the drainer crashes mid-delivery, stale inflight
leases (>60s) sweep back to `_outbox/*` on the next leader's first tick.
**At-least-once**: failures during delivery or leader failover can re-send;
receivers must dedup on `X-Rove-Webhook-Id`.

---

## Phase 6 — Magic-link redeem
(`handleAdminAuth`, `src/js/worker.zig:4222`; `tenant.redeemMagic`,
`src/tenant/root.zig:901`)

User clicks `https://app.loop46.me/v1/auth?mt={opaque}`.

`redeemMagic` hashes the token, looks up `magic/{hash_hex}` in admin
app.db, checks expiry, **deletes the row before returning** (`root.zig:981`)
— single-use, prevents replay even if the user reloads. Returns
`{email, instance_id}` on success.

Failure modes (`root.zig:920`–956): not found, expired (deletes stale
row), corrupted JSON (deletes corrupted row). All return null and the
handler responds 401.

### Phase 6a — Auto-resend on expired-but-resendable click (Phase 4 amendment)

15 minutes is short. Users routinely click magic links well after they
expire (email lag, distraction, "I'll do it later"). Today that's a
401 with no recovery path other than starting signup over from
scratch. Better UX: detect the expired-but-recent case and email a
fresh link automatically.

Implementation needs a small lifecycle change:

- `magic/{hash}` records grow a `resend_grace_until_ns` field
  (`expires_at_ns + 15min` by default).
- `redeemMagic` returns a three-state result: `Valid{email, instance}`,
  `Expired{email, instance}` (within grace), or `null` (gone).
- `pending/{name}` reservations share the same grace lifecycle so the
  name stays held during the resend window.

On `Expired{email, instance}`:

1. **Rate-limit check** before doing anything else. Two buckets via the
   Phase 8 limiter primitive:
   - `magic_resend` keyed on email — e.g., 3 resends per hour. Prevents
     email-bombing a target by repeatedly clicking expired links.
   - `magic_resend` global — fleet-wide cap (e.g., 100/min) as
     defense-in-depth against a botnet hitting expired links to burn
     Resend budget.
2. If allowed: mint a fresh magic record (new opaque, new
   `expires_at_ns`, new `resend_grace_until_ns`), update `pending/{name}`
   to match, **delete the old expired magic record** (one-shot — no
   click amplification), queue the new email through the outbox.
3. Return a 202-ish response: "We sent you a fresh link, check your
   email." UI ideally renders a friendly page; raw 202 is fine for v1.
4. If rate-limited: 429 with Retry-After.

Subsequent clicks of the *same* (now deleted) old link return 401 —
the user has to look at their email for the new link, not re-click the
old one.

Outside the grace window (`now >= resend_grace_until_ns`), the record
is fully purged and behavior matches today's: 401, user must start
signup over. Two adjacent grace windows do not chain — a fresh magic
created via resend has its own independent lifecycle, and once *that*
expires past grace, the user is done.

---

## Phase 7 — Session mint
(`tenant.createSession`, `src/tenant/root.zig:721`)

Same pattern as magic-link mint:

- 32 random bytes → 64-char opaque (the cookie value).
- SHA-256 → hash_hex.
- Store `session/{hash_hex}` → 9 bytes (8B little-endian `expires_at_ns` +
  1B `is_root` flag) in admin app.db. TTL 7 days
  (`ADMIN_SESSION_TTL_NS`).

Handler responds 302 to `/#/{instance_id}` (deep-link to the new tenant
in the dashboard) with `Set-Cookie: rove_session={opaque}; HttpOnly;
Secure; SameSite=Lax; Path=/; Max-Age=604800`.

**Not raft-replicated**, same rationale as magic tokens. On failover, the
user is silently logged out; cookie is still valid bytes but lookup misses
on the new leader. Re-login via magic link.

---

## Phase 8 — First authenticated request
(`requireAdminAuth`, `src/js/worker.zig:3597`; `tenant.authenticateSession`,
`src/tenant/root.zig:757`)

Every subsequent admin request:

1. `findCookie(rh, "rove_session")` extracts the opaque from the request.
2. `authenticateSession` hashes it, looks up `session/{hash_hex}`, validates
   expiry (deletes stale row opportunistically), returns `AuthContext{is_root}`.
3. If null → 401. Otherwise the request proceeds through normal dispatch.

User-tenant requests (the customer hitting their own subdomain) don't go
through `requireAdminAuth` — they're routed via `tenant.resolveDomain`
straight to the customer's own handler. The session cookie matters only
for admin-host requests.

---

## Sequence diagram (happy path, production with Resend wired)

```
  client                worker (leader)                   raft / followers           outbox drainer                Resend
    │ POST /v1/signup     │                                        │                          │                       │
    │────────────────────►│                                        │                          │                       │
    │                     │ validate (name, email)                 │                          │                       │
    │                     │ tenant.createInstance — local marker   │                          │                       │
    │                     │ proposeRootWriteSet (type 2) ─────────►│ replicate + apply        │                       │
    │                     │ deployStarterContent — files.db + blobs│                          │                       │
    │                     │ proposeFilesWriteSet (type 3) ────────►│ replicate + apply        │                       │
    │                     │   payload includes _outbox/{id} row    │                          │                       │
    │                     │ tenant.mintMagic — admin app.db        │                          │                       │
    │                     │ queueSignupEmail (already in payload)  │                          │                       │
    │ 202 {ok: true}      │                                        │                          │                       │
    │◄────────────────────│                                        │                          │                       │
    │                     │                                        │                          │ tick (every 250ms)    │
    │                     │                                        │                          │ drainTenant           │
    │                     │                                        │                          │  scan _outbox/*       │
    │                     │                                        │                          │  move to _inflight    │
    │                     │                                        │                          │  POST ────────────────►│
    │                     │                                        │                          │  ◄────── 200          │
    │                     │                                        │                          │  delete _inflight     │
    │                     │                                        │                          │                       │
    │  user clicks email  │                                        │                          │                       │
    │ GET /v1/auth?mt=... │                                        │                          │                       │
    │────────────────────►│                                        │                          │                       │
    │                     │ tenant.redeemMagic — delete magic/{h}  │                          │                       │
    │                     │ tenant.createSession — admin app.db    │                          │                       │
    │ 302 + Set-Cookie    │                                        │                          │                       │
    │◄────────────────────│                                        │                          │                       │
    │                     │                                        │                          │                       │
    │ GET / (with cookie) │                                        │                          │                       │
    │────────────────────►│                                        │                          │                       │
    │                     │ requireAdminAuth → authenticateSession │                          │                       │
    │                     │ ... normal dispatch                    │                          │                       │
```

---

## Why it's shaped this way

A few choices that aren't obvious from the code:

- **Two raft proposes, not one combined envelope.** The instance marker
  goes in root.db (`__root__.db`), the starter content goes in the new
  tenant's `files.db`. Each apply path targets one SQLite file; combining
  envelopes would cross that invariant. Cost: a tiny window where the
  marker is committed but files aren't (or vice versa).
- **Magic tokens and sessions are leader-local, not replicated.** Both are
  short-lived single-use credentials. Replication would add latency to
  the signup response without correctness benefit, and on failover the
  cost is the user re-logs-in (sessions) or re-signs-up (tokens) — both
  acceptable.
- **Outbox row replicates inside the files writeset.** Single-tenant data
  writes piggyback the deploy. The drainer is leader-only, so on failover
  the new leader's drainer picks up the same row and re-sends. Receivers
  must dedup.
- **Starter content failure is non-fatal.** A signup with a 503-on-customer-
  domain is recoverable (push code via ctl); a signup that fails entirely
  isn't. The tradeoff favours customer success over consistency.
- **Hash-at-rest for both magic tokens and sessions.** Same pattern: opaque
  random in the cookie/URL, SHA-256 in the DB. Read of either DB cannot
  forge credentials; only the in-flight HTTP traffic exposes the opaque.

---

## Open questions for simplification review

1. **Two non-atomic raft proposes per signup.** If the root_writeset
   commits and the files_writeset doesn't, the tenant exists (and resolves)
   but has no deployment — 503s. If the files_writeset commits but
   root_writeset doesn't, the files are orphaned (no instance marker → no
   tenant lookup). Worth handling? Two options: (a) propose both in one
   raft entry pair with a single commit barrier (probably needs envelope
   format change), (b) startup-time reconciliation that detects orphans
   and either repairs or cleans up.

2. **Phase 7 session mint is not retryable across token redemption.**
   `redeemMagic` deletes the row before `createSession` runs
   (`worker.zig:4258`). If session creation fails (KV error, OOM), the
   user has burnt their token and has no way to retry — they must
   re-signup. Either (a) defer the redeem-delete until after session
   creation succeeds, or (b) accept the brittleness because the failure
   modes are catastrophic anyway and would be caught by the panic PR's
   infallibility framework.

3. **No domain alias is written at signup.** Routing relies on the
   public-suffix wildcard for `{id}.loop46.me`. Phase 10 will add custom
   domains with explicit `domain/{host}` aliases, but should signup *also*
   write a `domain/{id}.{public_suffix}` alias today so the routing path
   has one shape regardless of customisation? Currently the wildcard path
   is the only entry for new customers.

4. **`MAGIC_TTL_NS` and `ADMIN_SESSION_TTL_NS` are hardcoded.** 15 min and
   7 days respectively. Worth promoting to operator config for production
   security tuning?

5. ~~**Outbox drainer scans every tenant on every tick.**~~ **Promoted to
   Phase 5.5 deliverable (d) on 2026-04-29 — design evolved through
   discussion.** Initial proposal was a leader-side dirty-set
   (`Set<instance_id>` populated via writeset-apply hook); the final
   shape is more structural — a centralized webhook subsystem with a
   single node-scoped `_webhooks.db` that replaces all per-tenant
   outbox state in steady operation. Apply hook on `_outbox/*` writes
   does an idempotent enqueue (keyed by the existing 64-hex outbox id)
   into `_webhooks.db`; the subsystem then owns delivery, retry, DLQ.
   After successful delivery the subsystem proposes a writeset on the
   source tenant deleting `_outbox/{id}`. Tenant app.db stays clean
   in steady state. v1 keeps `_webhooks.db` leader-local (not
   raft-replicated) — idempotent recovery makes that safe but moves
   the per-tenant-scan cost from every-tick to once-per-failover.
   Tracked in PLAN.md Phase 5.5.

6. **Signup→reachable timing.** `tenant.createInstance` adds the in-memory
   instance map entry synchronously, so resolveDomain finds the tenant
   immediately on the leader. But `worker.tenant_files_map` (the bytecode
   cache, owned by rove-js) is populated only at startup or via lazy-open
   on first request. The first user request to a freshly-signed-up tenant
   pays open-cost + bytecode-load. For latency-sensitive customers, worth
   pre-warming after deploy?

---

## Sidebar — why ctl deploy is *not* a signup path

`rove-js-ctl deploy <tenant>` writes files to disk and proposes a type-3
envelope, but it **doesn't call `tenant.createInstance`**. So if the tenant
doesn't already exist (in root.db's instance map), `resolveDomain` 404s
the customer's subdomain even though files are present.

Signup is the only HTTP path that creates instances on a live worker.
Other paths:

- `loop46 seed --manifest` (offline) — creates instances + writes domain
  aliases against an offline data dir before workers open it. Used in
  tests and demos.
- The smoke tests (after our fix) — use `loop46 seed` to pre-create acme
  before running ctl deploy, because there's no other live-worker path to
  do tenant creation outside signup.

The asymmetry is deliberate. `ctl deploy` is for an established tenant
pushing code; signup is the only way to *create* a tenant via HTTP. But
it does mean any "deploy a new tenant" flow today needs either signup or
offline seed — there's no "ctl create-instance" subcommand. Worth
considering for Phase 7 (CLI) if power users need it.

---

## Proposed redesign — lazy creation on redeem (Phase 4 amendment)

The abuse-prevention problem: today every `POST /v1/signup` immediately
allocates `instance/{name}` in root.db, `{id}/app.db`, `{id}/files.db`, the
file-blob directory, and the starter content — even for spam signups, even
for typos, even for users who never receive the email. The name is
squatted forever (no sweep), and the per-tenant resources leak. The only
thing that *does* expire is the magic-link row, but its expiry doesn't
unwind any of the rest.

The fix shifts every state-creating step out of signup and into redemption,
gated on the user having proven email control. Signup becomes a
*reservation* of the name plus an email-out-of-band step; everything else
happens when the user clicks the link.

### New signup flow

`POST /v1/signup`:

1. Validate name + email (unchanged).
2. Duplicate-name check covers **both** `instance/{name}` and non-expired
   `pending/{name}` entries in admin app.db.
3. Write `pending/{name}` → `{email, expires_at_ns, magic_hash_hex}` in
   admin app.db.
4. `tenant.mintMagic` writes `magic/{hash}` exactly as today.
5. Queue signup email — but the outbox row goes into **admin** app.db,
   not into the (nonexistent) customer tenant's app.db. The drainer scans
   admin's outbox along with every other tenant's; nothing else changes.
6. Return 202.

No `createInstance`. No `proposeRootWriteSet`. No starter content. No
files writeset. No customer-tenant outbox. The only durable artifacts on
the leader are two small KV rows in admin app.db (`pending/{name}`,
`magic/{hash}`) plus the outbox row.

### New redeem flow

`GET /v1/auth?mt=<token>`:

1. `redeemMagic` returns `{email, instance_id}` and deletes the `magic/*`
   row (unchanged).
2. Look up `pending/{name}`. Fail if missing or expired or email
   mismatch. (Email mismatch shouldn't happen in practice, but it
   protects against magic-row corruption-and-replay.)
3. **Atomically** in the same handler:
   - `tenant.createInstance(name)` — local marker + in-memory map.
   - `proposeRootWriteSet` — replicates the marker.
   - `deployStarterContent` — writes files.db + blobs.
   - `proposeFilesWriteSet` — replicates files.db.
   - Delete `pending/{name}`.
   - `tenant.createSession` — admin app.db.
4. 302 → `/#/{instance_id}` with `Set-Cookie: rove_session=...` (unchanged).

The two non-atomic raft proposes (Open question 1) are still here, just
shifted from signup time to redemption time. Same correctness story; same
fix surface if you decide to atomicize them.

### New sweep

A periodic task walks `pending/*` in admin app.db, deletes entries whose
`resend_grace_until_ns < now_ns` (note: not `expires_at_ns` — pending
records, like magic records, stick around past expiry to support
auto-resend on expired-but-resendable clicks; see Phase 6a). Magic
records `magic/*` get the same sweep; the two share their grace
lifecycle so they purge together. Two natural homes:

- Inside the existing outbox drainer's tick (it already iterates per
  tenant; admin-tenant ticks could include the pending + magic sweep).
- A new generic janitor task — overkill for two jobs, but cleaner if
  more periodic work accumulates.

Cost: a few SQLite `DELETE`s per sweep interval. Negligible.

### What changes in the open questions

- **Question 1 (two non-atomic proposes)** — unchanged. Both proposes
  shift to redemption but they're still separate envelopes.
- **Question 2 (session mint not retryable across token redeem)** —
  *worse*. With lazy creation, the redeem handler now also runs
  `createInstance` + propose + `deployStarterContent` + propose, all
  before `createSession`. Any failure in that chain after the magic-row
  delete is unrecoverable for the user. Mitigations: defer the
  `magic/*` delete until *after* `createSession` succeeds (single-use
  semantics preserved because the next click would race the same
  pre-delete window); or accept these failures as panic-class under the
  infallibility framework.
- **Question 3 (no domain alias at signup)** — unchanged.
- **Question 4 (hardcoded TTLs)** — `pending/*` shares
  `MAGIC_TTL_NS`'s 15 minutes; same config story.
- **Question 6 (signup→reachable timing)** — partly resolved. The new
  tenant doesn't exist *at all* until after redemption returns, so the
  first user request happens on a tenant that's already been opened
  during redemption. The bytecode-cache miss still costs on whatever
  worker the first request hits, but the on-disk state is fully
  warmed.

### What's the abuse surface after this

- An attacker can still spam-create `pending/*` entries to exhaust admin
  app.db storage. Mitigations: rate-limit `/v1/signup` per source IP
  (the rate-limiter primitive from Phase 8 already exists); cap pending
  count per email; cap pending count globally.
- An attacker who guesses or steals a magic link can still claim a
  tenant (same as today), but the link is single-use and short-lived.
- Email enumeration via `instanceExists` 409 still leaks tenant
  existence to anyone who can guess names. Out of scope for this
  amendment; tracked separately if it becomes a concern.

### Implementation cost

Mostly a re-shuffle within `handleAdminSignup` and `handleAdminAuth`:

- Move the bulk of `handleAdminSignup`'s body (createInstance, both
  proposes, deployStarterContent) into a new helper called from
  `handleAdminAuth`.
- Add `pending/*` reservation read/write to admin app.db.
- Update `instanceExists` (or its callers) to check both namespaces.
- Move the outbox enqueue target from customer tenant to admin tenant.
- Add the periodic sweep — fold into outbox drainer's loop.

Existing `signup_smoke.sh` needs an update: the smoke should observe
that the customer tenant *doesn't* exist after signup, *does* exist
after redemption.

---

## File:line index

Cited locations as of this writing — verify with `git blame` if these have shifted:

- `src/js/worker.zig:3597` — `requireAdminAuth`
- `src/js/worker.zig:3805` — `handleAdminSignup`
- `src/js/worker.zig:4066` — `deployStarterContent`
- `src/js/worker.zig:4111` — `buildSignupEmailText`
- `src/js/worker.zig:4142` — `queueSignupEmail`
- `src/js/worker.zig:4222` — `handleAdminAuth`
- `src/js/worker.zig:2741` — `proposeFilesWriteSet`
- `src/js/worker.zig:2755` — `proposeRootWriteSet`
- `src/tenant/root.zig:274` — `createInstance`
- `src/tenant/root.zig:512` — `writeInstanceMarker`
- `src/tenant/root.zig:533` — `ensureOpen`
- `src/tenant/root.zig:721` — `createSession`
- `src/tenant/root.zig:757` — `authenticateSession`
- `src/tenant/root.zig:856` — `mintMagic`
- `src/tenant/root.zig:901` — `redeemMagic`
- `src/js/apply.zig:121` — `encodeRootWriteSetEnvelope` (type 2)
- `src/js/apply.zig:132` — `encodeFilesWriteSetEnvelope` (type 3)
- `src/js/apply.zig:437` — `applyFilesWriteSet`
- `src/js/apply.zig:457` — `applyRootWriteSet`
- `src/outbox/drainer.zig` — drainer thread (entry at `:109`)
