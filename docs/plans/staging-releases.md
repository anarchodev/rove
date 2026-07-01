# Staging / preview releases — design plan

Status: **proposal, 2026-06-30.** No code yet. This doc proposes a way to
run a non-default version of a tenant's code, selected per-request by a
signed cookie, so a developer can exercise newly-deployed code against the
live tenant before flipping it to the default release.

## 0. The ask

The workflow we want:

1. A developer deploys a bundle. Today this already mints a `dep_id` and
   does **not** flip the default release (`rewind deploy` without
   `--release`). So the new code is live in storage but nothing serves it.
2. The developer clicks a URL (printed by `rewind deploy`, or a button in
   the editor / dashboard). Clicking it sets a cookie in their browser.
3. From then on, that browser's requests to the tenant's normal host are
   served by the **preview** deployment, while everyone else keeps getting
   the default release.
4. Happy with it, the developer runs `rewind release <dep_id>` and the
   preview becomes the default for everyone. The preview cookie becomes a
   no-op (it now points at what is already current).

The point is to test *the real thing on the real host against real data*
before making it the default — not a separate staging environment with its
own URL and its own state.

## 1. Why this is a small change, not a big one

Three properties of the existing system do most of the work:

- **Deployments are content-addressed and coexist.** A "release" is just
  the kv key `_deploy/current` holding a hex `dep_id`
  (`src/js/starter.zig:200`). Every deploy mints a distinct `dep_id`, and
  the compiled bytecode lives in a node-wide **content-addressed** cache
  that is never overwritten (`src/js/deployment_cache.zig`). So a
  non-default version already physically exists on the node the moment it
  is deployed — we are not adding storage, only a way to *select* it.

- **The deploy step already produces the staging artifact.** `rewind
  deploy` stages a bundle and returns a `dep_id` without touching
  `_deploy/current`; release is a separate flip. "Code that is live in
  storage but not the default" is precisely a freshly-deployed,
  not-yet-released `dep_id`. Nothing new to produce.

- **The front door needs no changes.** `rewind-front` is a pure
  Host→cluster reverse proxy (`src/front/main.zig`); it forwards all
  headers and cookies verbatim and does not inspect them for routing. The
  preview cookie flows straight through to the worker. The entire feature
  lives in the worker plus a little JS — the ingress path is untouched.

## 2. The one piece of engine work

### 2.1 Where version is chosen today

Request dispatch pins exactly one deployment snapshot per request:

```zig
// src/js/worker_dispatch.zig ~2832
const snap = slot.pinCurrent() orelse { … 503 "no deployment" … };
const tc = worker_mod.TenantFiles{ .slot = slot, .snap = snap };
defer tc.release();
const dep_id = snap.deployment_id;
```

`pinCurrent()` loads the tenant slot's `current` snapshot (an atomic
pointer) and retains a refcount for the life of the request. Bytecode is
then fetched from that pinned snapshot (`findBytecode(tc, …)` ~2975).
Pinning **once per request** is exactly the property we want — it
guarantees a single request sees one consistent code version end to end.

The only real constraint is that a tenant slot holds **one** snapshot
(`current`). To serve a preview we need a slot to be able to hold *more than
one* live snapshot and choose which to pin.

> Open question to confirm before coding: whether `dispatchOnce` pins once
> per request or once per batched group of requests for a tenant. If
> per-request (which the pin-then-`defer release` shape suggests), concurrent
> preview and production requests need no special handling. If per-batch,
> the batch key must include the selected `dep_id`. This is a
> read-the-code confirmation, not a design fork.

### 2.2 The change

Teach the per-tenant deployment slot to hold the always-loaded `current`
snapshot **plus a small, bounded set of preview snapshots**, and pick which
to pin using a per-request cookie:

- **Slot** (`deployment_cache.zig`): add `pinDeployment(dep_id)` alongside
  `pinCurrent()`. It returns the snapshot for an arbitrary `dep_id`,
  building it on demand via the existing loader (which already constructs a
  snapshot from a `dep_id` + manifest, fully offline) and caching it under
  an **LRU + TTL** keyed by `dep_id`. The bytecode leases it references are
  already shared and content-addressed, so a preview snapshot mostly reuses
  bytecode that may already be resident.

- **Dispatch** (`worker_dispatch.zig`): before pinning, read the preview
  cookie from the already-parsed request headers (available well before
  bytecode selection — `src/js/request.zig`). If present and valid, call
  `pinDeployment(dep_id)`; otherwise `pinCurrent()` as today. Everything
  downstream is unchanged — it just operates on a different pinned
  snapshot.

- **Selector storage**: simplest is for the cookie to carry the `dep_id`
  directly (signed — see §3). A named indirection
  (`_deploy/preview/{name}` → `dep_id` in kv, cookie carries `name`) is a
  possible v2 nicety but adds a kv read on the hot path and is not needed
  for the core workflow.

That is the whole engine surface: one new pin method backed by a bounded
snapshot cache, and one cookie read in dispatch.

## 3. Security — the one thing that must be right

An unauthenticated request must **not** be able to make a worker load an
arbitrary `dep_id`. If it could, an attacker could force a worker to build
and hold many snapshots (memory-growth denial of service), and — worse —
run a stale or attacker-chosen deployment against live tenant data.

**The preview selector must be signed.** Options, cheapest first:

- **Platform-HMAC signed cookie/URL** — the preview URL embeds
  `{dep_id, exp}` and an HMAC over them using an existing platform key.
  The worker verifies the signature and expiry before pinning. Only someone
  holding a link minted by the deploy tooling can activate a preview. This
  matches the "developer clicks a URL" workflow directly and needs no
  login.

- **Scoped `deploy`-cap token** — reuse the tenant-scoped capability token
  the deploy path already mints; a preview is only selectable by a caller
  who could have deployed it. Stronger, but requires the previewer to carry
  a cap, which is a worse fit for "click a link in a browser."

Recommendation: **signed URL → signed cookie**, minted by the deploy
tooling, short expiry, HMAC with a platform key. Additionally, only allow
pinning a `dep_id` whose manifest actually exists for this tenant (reject
unknown ids loudly) so a valid signature can never load nonsense.

## 4. The workflow layer (trivial JS, no engine work)

- A small system route — `GET /__preview/{dep_id}?sig=…&exp=…` — validates
  the signature, sets `Set-Cookie: rewind-preview=<signed>; HttpOnly;
  Path=/`, and 302-redirects to `/`. A matching `GET /__preview/clear`
  deletes the cookie.
- `rewind deploy` prints the ready-to-click preview URL next to the
  `dep_id` it already returns. The editor/dashboard can surface the same
  URL as a button.

Nothing here touches raft, storage, or the front door.

## 5. Sharp edges (all bounded — decide before building)

1. **Sign the selector.** §3. The one non-negotiable.
2. **Snapshot budget.** Cap preview snapshots per tenant with LRU + TTL and
   fail loud on exhaustion rather than growing unbounded. Preview
   deployments hold bytecode leases in RAM until evicted.
3. **Follower / any-node loading.** `current` auto-loads on every node via
   `_deploy/current` replication. A preview `dep_id` referenced only by a
   cookie must load on whichever node happens to serve the request — the
   loader already builds snapshots lazily and offline, so this is a
   confirm-the-path item, not new machinery.
4. **Preview code writes to real kv.** A preview handler shares the
   tenant's real kv namespace. This is usually the point (test new code
   against real data), but it is **not** an isolated sandbox — state a
   preview mutates is the tenant's actual state. If true isolation is ever
   wanted, *that* is when a separate tenant/instance earns its cost; it is
   explicitly out of scope here.
5. **Observability.** Request logs / metrics should record which `dep_id`
   served a request so preview traffic is distinguishable from production
   in Grafana.

## 6. Why not "make the preview a separate tenant"

It is the obvious alternative and it is worse for this workflow: a separate
instance means a different host, a different (empty) kv namespace, and a
separate provision/move lifecycle. That is a *staging environment*, which is
a different feature. The whole value of the cookie approach is that preview
runs on the tenant's real host against the tenant's real data, differing
*only* in which content-addressed code version executes — which the system
is already built to represent.

## 7. Effort estimate

- Engine: bounded snapshot cache + `pinDeployment` + cookie read in
  dispatch + signature verify. The reused pieces (content-addressed
  bytecode cache, offline snapshot loader, per-request pin) are the bulk of
  the work and already exist.
- Tooling/JS: the `__preview` set-cookie route and the `rewind deploy` URL
  print.
- Confirm-first items: §2.1 per-request vs per-batch pin; §5.3 any-node
  lazy load.

Rough order: a focused few days including a smoke test, not a rewrite.

## 8. Fit with replay / sim

A preview `dep_id` is exactly the object `rewind sim` already reasons about
(a specific content-addressed code version run against a world). "Preview
this deployment in the browser" and "sim this deployment offline" become two
front-ends onto the same artifact, which is a nice consistency rather than a
new concept.
