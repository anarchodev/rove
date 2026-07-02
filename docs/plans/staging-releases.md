# Staging / preview releases — design plan

Status: **proposal, 2026-06-30 (restructured 2026-07-01).** No code yet.
This doc explores how a developer can exercise candidate code against a
live tenant — its real host, real data — before making it the default
release. Three models emerged, each a refinement of the last. They are laid
out in the order they were reasoned through. **Model C (the dev tunnel) is
the recommended direction**; A and B are documented because C composes
both and because either is a smaller stepping stone if C's transport
dependency isn't ready.

## 0. The ask

The workflow we want:

1. A developer has candidate code (newly deployed, or just sitting in their
   editor — the models differ on this).
2. The developer clicks a URL. Clicking it sets a cookie in their browser.
3. From then on, that browser's requests to the tenant's **normal host**
   are served by the candidate code, while everyone else keeps getting the
   default release.
4. Happy with it, the developer promotes the candidate to the default for
   everyone (`rewind release`), and the cookie becomes a no-op.

The point is to test *the real thing on the real host* before making it the
default — not a separate staging environment with its own URL and its own
state. The three models below differ in **where the candidate code runs**
and **where its state lives**.

## 1. What the existing system already gives us

Three properties do most of the work in every model:

- **Deployments are content-addressed and coexist.** A "release" is just
  the kv key `_deploy/current` holding a hex `dep_id`
  (`src/js/starter.zig:200`). Every deploy mints a distinct `dep_id`, and
  compiled bytecode lives in a node-wide **content-addressed** cache that is
  never overwritten (`src/js/deployment_cache.zig`). A non-default version
  already physically exists the moment it is deployed.

- **The deploy step already produces a staging artifact.** `rewind deploy`
  stages a bundle and returns a `dep_id` without touching `_deploy/current`;
  release is a separate flip.

- **The front door needs no changes.** `rewind-front` is a pure
  Host→cluster reverse proxy (`src/front/main.zig`); it forwards headers and
  cookies verbatim and does not inspect them for routing. A preview cookie
  flows straight through to the worker. The whole feature lives worker-side
  plus a little JS — ingress is untouched.

- **Execution is a pure function of a recorded world.** A handler
  activation is `update(Msg, KV snapshot, ctx, seed) → (writeset, Cmds,
  disposition)`. `rewind sim` already runs candidate code locally on the
  same JS engine (`arenajs-replay`) against an authored or captured world.
  This is what makes Models B and C possible at all.

## 2. Model A — prod-side cookie preview

**Candidate runs:** on the prod worker. **State:** the tenant's real kv.

Serve a non-default `dep_id` on the real host, selected per-request by a
signed cookie.

### 2.1 The engine change

Dispatch pins exactly one deployment snapshot per request:

```zig
// src/js/worker_dispatch.zig ~2832
const snap = slot.pinCurrent() orelse { … 503 "no deployment" … };
const tc = worker_mod.TenantFiles{ .slot = slot, .snap = snap };
defer tc.release();
const dep_id = snap.deployment_id;
```

`pinCurrent()` loads the tenant slot's `current` snapshot (atomic pointer)
and retains a refcount for the life of the request. Pinning **once per
request** is exactly the property we want — one request sees one consistent
version end to end. The only constraint is that a slot holds **one**
snapshot. The change: let a slot hold `current` **plus a bounded LRU of
preview snapshots**, and pick which to pin from a cookie.

- **Slot** (`deployment_cache.zig`): add `pinDeployment(dep_id)` alongside
  `pinCurrent()`, building the snapshot on demand via the existing offline
  loader and caching it under LRU + TTL keyed by `dep_id`. Bytecode leases
  are already shared and content-addressed, so a preview snapshot mostly
  reuses resident bytecode.
- **Dispatch** (`worker_dispatch.zig`): before pinning, read the preview
  cookie from the already-parsed request headers (`src/js/request.zig`).
  Present and valid → `pinDeployment(dep_id)`; else `pinCurrent()`.
  Everything downstream is unchanged.

> Confirm before coding: whether `dispatchOnce` pins once per request or
> once per batched group of requests for a tenant. If per-request (which the
> pin-then-`defer release` shape suggests), concurrent preview and
> production requests need no special handling.

### 2.2 What's good and what isn't

- ✅ Real host, real ingress, **shareable link** — anyone with the URL sees
  it on the real site.
- ✅ Smallest engine change; no new transport.
- ⚠️ **Preview writes hit the tenant's real kv.** A preview handler shares
  the real namespace — usually the point (test against real data), but *not*
  an isolated sandbox. This is the model's scariest edge.
- ⚠️ Requires a deploy to produce the `dep_id` first — not a
  code-on-the-laptop inner loop.

## 3. Model B — client-side copy-on-write sim

**Candidate runs:** on the dev laptop (`arenajs-replay`). **State:** local
overlay over a read-through to prod.

Don't deploy at all. Run the candidate on the laptop, and back its KV with a
**copy-on-write read-through**: reads that miss the local overlay resolve
from prod; writes land in the local overlay and never touch prod.

### 3.1 This is a sim read-source, not a new engine

`rewind sim` already runs candidate code against a world, already has
`--miss-policy {fail|resolve}`, and already carries per-read provenance
(`{source}` layers). Model B decomposes entirely into pieces that exist:

- **Copy-on-write writes** = the write overlay sim already has — the same
  shape as the worker's speculative `TrackedTxn` overlay (volatile writes
  over committed state) and sim's `world.kv` map.
- **Read-through** = a new miss policy, `--miss-policy=live`: a KV miss
  resolves by fetching the key from prod instead of failing/prompting. And
  **resolving-a-miss-from-prod-and-recording-it is lazily authoring a
  fixture** — after the first run each touched key is captured, so a second
  run goes fully offline and deterministic. That is precisely the sim
  framework's "resolve → record a typed hole" story with prod as the
  resolver.

### 3.2 What it reverses, and the costs

Sim was consciously scoped **client-side only, no live-KV**. Model B
reopens that, and the reasons that stance existed are its real costs:

- **Determinism** — a live read-through over moving prod data is
  non-reproducible *unless* you pin a snapshot (read at a fixed raft index,
  or capture-on-first-read and freeze). Capture-on-read restores
  determinism, so it's solvable, but it's the thing to design.
- **A scoped, authed remote KV read endpoint** — KV reads happen *inside*
  the worker today; reading from a laptop needs a real read API with
  tenant-scoped auth and defined snapshot semantics. This is the actual new
  surface.
- **KV is only one effect.** A handler also does `http.fetch`, `blob.*`,
  timers, WS, scheduler. COW solves KV; the rest still need mock-or-proxy.
  Sim's typed-hole/miss-policy frames each, but "live" mode multiplies the
  question (do you *also* live-proxy outbound fetches, firing real prod-side
  side-effects from a laptop?).

### 3.3 What's good and what isn't

- ✅ **Writes are isolated** — fixes Model A's scariest edge.
- ✅ No deploy; instant iteration on laptop code.
- ✅ Mostly reuses the shipped sim engine.
- ⚠️ **Developer-local only — no shareable URL, no real ingress.** You are
  not exercising the real worker/front/TLS/h2 path.

## 4. Model C — the dev tunnel (recommended)

**Candidate runs:** on the dev laptop, as a real local `rewind-worker`.
**State:** the laptop worker's COW read-through (Model B, nested).
**Ingress:** the real prod host (Model A's cookie gating, nested).

This is the synthesis. The industry pattern is the "personal dev
override" / traffic intercept: `wrangler dev --remote`, Telepresence
intercepts, ngrok-with-cookie-routing. Cookie-bearing requests to the real
tenant host are **routed to the developer's laptop**, which executes and
returns the response; the prod worker relays it back to the browser.
Everyone without the cookie hits the real deployment, untouched.

### 4.1 Why it dominates A and B

It is the only model that satisfies every dimension at once:

| | A · cookie preview | B · local COW sim | **C · dev tunnel** |
|---|---|---|---|
| Real host / ingress / shareable URL | ✅ | ❌ | ✅ |
| No deploy; laptop-code inner loop | ❌ | ✅ | ✅ |
| Real prod data available | ✅ | ✅ (read-through) | ✅ (read-through) |
| **Writes isolated** | ❌ | ✅ | ✅ |
| Exercises real runtime path | ✅ | ❌ | ✅ (real worker binary) |
| Blast radius on real users | none¹ | none | none¹ |
| New machinery | small | medium | largest |

¹ only cookie-bearing requests diverge from the default deployment.

It also **composes down** into A and B rather than replacing them: the thing
on the laptop is a real `rewind-worker` (so effect semantics are identical,
not simulated), its state backend is Model B's COW read-through, and the
gating is Model A's signed cookie — now meaning "route me to my tunnel"
instead of "pin dep_id X."

### 4.2 The one question that doesn't disappear: effects and state

The tunnel moves *where* you answer "where do `kv`/`fetch` go," not
*whether*. Two options:

- **Thick laptop (recommended):** the laptop runs a full local worker whose
  KV is COW read-through to prod (Model B). Reads see real data; writes stay
  in a local overlay thrown away or promoted on release; you test the actual
  `rewind-worker` binary. The tunnel carries only the request/response
  envelope.
- **Thin laptop:** the laptop runs only handler logic and RPCs every effect
  back to the prod worker as the real tenant. Simpler transport, but
  reintroduces "writes hit prod" unless the tunnel session gets a
  server-side speculative overlay.

Go thick.

### 4.3 It maps onto machinery that mostly exists

- **Forward-request, relay-response** = the bound-fetch held-connection
  resume pattern (the `platform.compile` / `rove-compile.internal`
  bound-respond work). A cookie-gated request becomes a bound "fetch" whose
  upstream is the tunnel; the held browser connection resumes when the
  laptop answers. Same shape.
- **Route the request to the node holding the tunnel** = the
  continuation-affinity / connection-holder model (callbacks route to the
  worker *holding* the continuation, not `hash(tenant)`). "Route to the node
  holding the dev tunnel" is the identical primitive.
- **The genuinely new piece** = an outbound-dialed, held tunnel. The laptop
  is behind NAT, so it dials *out* to prod and the worker→laptop direction
  rides that held connection. This is exactly the **outbound-WS /
  connection-actor** gap already on the roadmap (the "firehose consumer"
  forcing function, TEA gap 2.5) — so C is a concrete motivating use case
  for a primitive already planned, not a new transport invented here.
- **Signed cookie / tenant-scoped dev cap** = §5, unchanged from Model A.

### 4.4 What C keeps, drops, absorbs

- **Drops** Model A's §2.1 multi-snapshot slot work — unneeded; the code
  lives on the laptop, prod never selects a preview version.
- **Keeps** the signed-cookie gating (§5) and the `/__preview` set-cookie
  route (now "route me to my tunnel").
- **Absorbs** Model B as the laptop worker's state backend.

### 4.5 Costs specific to C

- **A prod↔laptop hop per request.** Fine for a dev loop; a shared
  stakeholder demo eats one extra RTT, acceptable.
- **Leans hard on the connection-actor primitive being solid** — the
  outbound held tunnel is the real build. If that primitive isn't ready, ship
  Model A first as a stepping stone.
- **The tunnel holder sees real request traffic and (via COW) real read
  data** — so the dev session must be a short-lived, tenant-scoped
  capability (§5).

## 5. Security — common to all models

The selector (cookie / URL) that diverges a request from the default
**must be signed**. Otherwise an unauthenticated request could:

- in Model A, force a worker to load arbitrary `dep_id`s (memory-growth
  denial of service, or run a stale/attacker-chosen deployment);
- in Model C, route real prod traffic to an attacker's tunnel.

Approach, cheapest first:

- **Platform-HMAC signed cookie/URL** — the preview URL embeds
  `{selector, exp}` and an HMAC over them using a platform key; the worker
  verifies signature + expiry before diverging. Only someone holding a link
  minted by the deploy/dev tooling can activate it. Fits "developer clicks a
  URL," no login required.
- **Scoped `deploy`-cap token** — reuse the tenant-scoped capability the
  deploy path already mints. Stronger, but a worse fit for a browser click.

Recommendation: **signed URL → signed cookie**, short expiry, HMAC with a
platform key. For Model A additionally reject any `dep_id` whose manifest
doesn't exist for this tenant, so a valid signature can never load nonsense.
For Model C the cookie authorizes *routing to a registered tunnel* held by a
short-lived tenant-scoped dev session.

## 6. Why not "make the preview a separate tenant"

The obvious alternative, and worse for this workflow: a separate instance
means a different host, a different (empty) kv namespace, and a separate
provision/move lifecycle — a *staging environment*, a different feature. The
value of all three models here is running on the tenant's real host and
(reads of) real data, differing only in which code executes and where. If
true isolation is ever wanted, *that* is when a separate tenant earns its
cost; it is out of scope here.

## 7. The workflow / JS layer (trivial in every model)

- A small system route — `GET /__preview/...?sig=…&exp=…` — validates the
  signature and sets `Set-Cookie: rewind-preview=<signed>; HttpOnly;
  Path=/`, then 302s to `/`. A matching `GET /__preview/clear` deletes it.
  In Model A the cookie carries a `dep_id`; in Model C it names the dev
  session / tunnel.
- `rewind deploy` (A) or `rewind dev` (C) prints the ready-to-click URL.

Nothing here touches raft, storage, or the front door.

## 8. Recommendation and sequencing

- **Target Model C.** It is the only model that is simultaneously
  shareable-on-the-real-host, deploy-free, write-isolated, and runs the real
  binary — and it reuses more machinery than it looks (bound-fetch resume +
  connection-affinity + the already-planned outbound connection primitive).
- **If the outbound-connection primitive isn't ready, ship Model A first**
  as a genuinely useful stepping stone (small, no new transport), accepting
  its real-kv-writes caveat, and layer C on later. A and C share the signed
  cookie and the `/__preview` route, so A is not throwaway.
- **Model B is worth building regardless** as the laptop-side state backend
  for C and as a standalone offline-iteration tool — it's mostly a new sim
  miss-policy on the shipped engine.
- Confirm-first items: §2.1 per-request vs per-batch pin; §3.2 snapshot
  pinning for deterministic read-through; the maturity of the connection-
  actor / outbound-WS primitive C depends on.

## 9. Fit with replay / sim

Every model reasons about a specific content-addressed code version run
against a world — exactly the object `rewind sim` already handles. "Preview
this in the browser" (A), "run it locally against real data" (B), and
"intercept my real traffic to my laptop" (C) become three front-ends onto
the same artifact, which is a consistency win rather than a new concept.
