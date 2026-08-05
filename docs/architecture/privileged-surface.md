# The privileged surface — the `_system.*` / `__rove.*` model

> **Shipped** (graduated from `plans/`): the two-surface model, the
> assignment rule, and the `__rove_*` → `__rove.*` holder collapse
> (§0–§2, §4 steps 1/4/5) are as-built in `src/js/globals.zig`, which
> cites this doc. The rate-limiting half (§3) is now shipped too: the
> email-specific `__rove_check_email_rate` native + `email_rate.zig` are
> deleted, and the per-tenant plan-quota moved to a **general outbound
> limit** enforced at the frozen fetch primitive (`bindings/http.zig`
> `outboundRateOk`, the `.outbound` limiter action). Customer-facing
> rate limiting is the kv token-bucket recipe (§3b); shipping it as a
> first-party `@rewind/ratelimit` package waits for the registry (#121).
> After this, no bare `__rove_*` globals remain. The public-shim half of
> the surface is [`builtin-libs.md`](builtin-libs.md).

---

## 0. Why no gated getter

The natives split into two groups by *protection need*, and neither needs
a getter:

- **Dangerous ops** (`set_wake`, `fire_wake`, `systemFetch`) already
  **self-gate** — `if (!state.is_system_module) throw` inside the native
  (`scheduler.zig:68`, `http.zig:131`). That check is the real boundary
  and works regardless of naming/visibility.
- **Benign ops** (`next`, `resumeIfBound`) are already customer-reachable
  today (bare globals the `next()` shim calls) and are harmless
  (within-tenant dispatch).

So hiding the ops behind a getter buys nothing. The only thing the
`delete globalThis._system` protects is the **capability** natives
(`_system.kv`/`crypto`/`http`) from being *named* by customer code — pure
hygiene (they're tenant-scoped; reaching them isn't escalation). We keep
that delete as-is. This is the low-risk unification: **make the surface
principled, don't change the enforcement mechanism.**

## 1. The two-surface model + assignment rule

There are — and should remain — **two** physical binding surfaces,
distinguished by a single mechanical rule:

| Surface | Lifecycle | Who reaches it | Rule |
|---|---|---|---|
| **`_system.*`** (capabilities) | deleted after base-eval (hygiene) | ambient shims, by **closure capture** at base-eval | a native belongs here iff the **customer API exposes it** (a public shim wraps it) |
| **`__rove.*`** (privileged ops) | **persistent** (never deleted) | **badged activations only** (baked `__system/` modules), by live global ref | a native belongs here iff it is **called ONLY by badged handlers** AND is **`is_system_module`-gated** |

The `__rove.*` surface is **uniformly gated and system-only** — every entry
throws for customer code, and no customer-facing shim reaches it. Security
is (a) tenant-scoping via `getState(ctx)`, (b) the `is_system_module`
self-gate (now on *every* `__rove.*` entry), (c) `state.platform` on admin
natives; `_system`-deletion is hygiene.

**The dual-use resolution.** A native needed by *both* a customer shim and
baked modules (the classic case: `next`) does NOT get dual-homed. Instead
**widen the customer API** so the *public shim* serves both — baked modules
reach it by calling the public verb (they have the ambient globals; the
shim holds the captured `_system.*` ref). That keeps `__rove.*` purely
system-only. Applied to `next` in §2.

**Cleanup: collapse the remaining bare `__rove_*` globals into ONE gated
`__rove` namespace object.** Today they're 6 separate `globalThis`
properties (`GLOBAL_BUILTINS`, `globals.zig:2238`). After §2, the survivors
are `__rove.{resumeIfBound, wake:{set,fire}, fetch}` — one persistent
holder, every member `is_system_module`-gated, mirroring how `_system.*` is
one holder. Less global pollution; the lint/determinism allowlist
(`globals.zig:3465`) shrinks to one name.

## 2. Applying the rule — the audit

Run every current `__rove_*` through the rule (does a **baked module**
consume it?):

| Native | Callers | Verdict |
|---|---|---|
| `__rove_next` | **both** — the `next.js` *shim* AND baked modules (`webhook_onresult.mjs:161`, `blob_compose_onresult.mjs:39`) | **WIDEN the customer API** → `_system.continuation.next` (deleted, shim-captured). Widen `next(target?, ctx?)` so baked modules call the *public* `next()`. **No bare native.** |
| `__rove_resume_if_bound` | baked only — `webhook_onresult.mjs:156` (held-sync resume) | **`__rove.resumeIfBound`** — **ADD an `is_system_module` gate** (currently ungated; closes a customer-forge gap) |
| `__rove_set_wake` | baked only — `scheduler_tick.mjs` | **`__rove.wake.set`** (already gated) |
| `__rove_fire_wake` | baked only — `scheduler_tick.mjs` | **`__rove.wake.fire`** (already gated) |
| `__rove_fetch` | baked only — delivery modules | **`__rove.fetch`** (already gated) |
| `__rove_check_email_rate` | shim only — `email.js` | **REMOVE** — §3 |
| `__rove_request_proto` | (data object, not a native; engine reads it from Zig) | leave as-is (out of scope) |

`next` is the dual-use case: rather than dual-home it, **widen the public
`next` verb** (a target module — already a customer-facing shape via
`schedule`/`webhook.send({on})`) so both customers and baked modules use
the public shim, and the bare native disappears. `resumeIfBound`,
`wake.set`, `wake.fire`, `fetch` are genuinely baked-only → the gated
`__rove.*` holder. `check_email_rate` → §3.

## 3. `check_email_rate` → generic rate limiting + platform quota (shipped — issue #120)

`__rove_check_email_rate` tangled two different things into one
email-specific native (`email_rate.zig`): a **per-worker in-memory bucket
sized by the tenant's PLAN** (`state.plan_rate`). Both the native and
`email_rate.zig` are now deleted; the two concerns are untangled as below.

### 3a. Platform plan-quota — a general OUTBOUND limit (shipped)

The plan-rate check is the **platform** limiting the tenant per their
plan. Once `email` becomes a **tenant-pinnable package** (#123), a package
that simply *doesn't call* the quota native would bypass it. So
enforcement moved out of the email lib to a point the tenant can't
replace: **the frozen fetch primitive** (`bindings/http.zig`
`outboundRateOk`), a new `.outbound` action on the per-worker
`state.limiter`.

- **Verify-first (was §5.1), answered:** there was NO per-tenant outbound
  limit anywhere — the limiter had only `.request` (inbound) and `.email`.
  So this *adds* a general outbound limit rather than moving one. The
  `.email` action + its `email_capacity`/`email_refill_per_sec` caps were
  renamed to `.outbound` / `outbound_capacity` / `outbound_refill_per_sec`
  (`src/plan/root.zig`); the launch tier numbers are unchanged (a product
  call — decisions.md §10.9).
- **Un-bypassable by construction.** A tenant-pinnable email/webhook
  package can only reach third-party egress through the frozen verbs
  (`webhook.send`, `after.fetch`, `http.subscribe`) — it cannot name the
  raw `_system.http`/`__rove.fetch` natives (deleted / `is_system_module`-
  gated). All of those verbs funnel through `jsHttpFetch`/`jsOnFetch`/
  `jsHttpSubscribe`, where the check lives. `email.send` composes over
  `webhook.send`, so it inherits the limit with no email-specific code.
- **Two carve-outs, both correct-by-construction.** (1) Deferred platform
  delivery — the baked `__system/webhook_fire` retry / scheduled fire
  (`is_system_module == true`) — is exempt: it re-issues an
  already-admitted send, is bounded by the webhook retry budget + backoff,
  and re-counting it would burn a retry attempt / hot-loop the watchdog.
  (2) Fetches to platform-internal doors (`*.internal` — `blob.*`,
  `platform.*`, logs storage/control-plane I/O) are exempt
  (`targetsInternalDoor`); they aren't third-party egress.
- **Atomic rejection.** `webhook.send` now attempts its immediate fire
  *before* writing the durable `_send/owed` marker + watchdog, so a
  rate-limited send throws `Error{code:"rate_limited"}` leaving no durable
  residue — otherwise the watchdog would still deliver it and a caught +
  retried `rate_limited` would double-send.

### 3b. Generic customer rate limiting (the part the user wants)

For a tenant to rate-limit **its own** operations (customer-chosen limit,
not a plan quota): **compose over kv** — a token bucket in a kv key. This
is *correct under contention* because kv validates the readset
(§ grounding: `apply.zig` readset + `SeqCounter`), so a losing
read-modify-write retries rather than double-spends. **No new native.**
Ship as `@rewind/ratelimit` (a package) or document the recipe:

```js
// token bucket in kv — durable, accurate, tenant-owned
function take(key, limit, windowMs, cost = 1) {
  const now = Date.now();
  const b = JSON.parse(kv.get(key) || "null") || { tokens: limit, ts: now };
  const refill = ((now - b.ts) / windowMs) * limit;
  const tokens = Math.min(limit, b.tokens + refill);
  if (tokens < cost) { kv.set(key, JSON.stringify({ tokens, ts: now })); return false; }
  kv.set(key, JSON.stringify({ tokens: tokens - cost, ts: now }));
  return true;
}
```

### 3c. Optional: a per-worker best-effort primitive (defer)

`check_email_rate`'s *only* advantage over the kv recipe is that it's
**in-memory/per-worker** — no kv op on the hot path. If a proven hot-path
need appears (loss-tolerant, per-worker, no durability), expose ONE
**generic** primitive — `__rove`-tier is wrong (it's a customer
capability); it'd be a frozen public `ratelimit.take(name, {limit,
windowMs})` shim over a per-worker native. **Defer** per
`feedback_compose_from_primitives`: email doesn't need it (it's already a
durable/kv-touching op, so the kv recipe's cost is marginal), and adding a
per-worker primitive is a forever commitment. Build only on demand.

**Net for `check_email_rate`:** delete the native; plan-quota → the frozen
outbound boundary (3a); customer rate limiting → kv recipe / `@rewind/
ratelimit` (3b); per-worker primitive deferred (3c).

## 3.5 Platform credentials are not on any handler surface

The two-surface model (§1) governs *natives*. There is a third thing a
privileged handler can reach — the **credential the platform authenticates
itself with** — and it needs its own rule, because on a replay platform a
handler-readable input is a **recorded** input.

The operator root token used to arrive as an ordinary header the admin
middleware read and handed to a native:

```js
const hdr = request.headers["authorization"] || "";     // ← taped, verbatim
if (platform.auth.checkRootToken(hdr.slice(7))) { … }
```

`request.headers` is a read-recording accessor (`globals_request.zig`
`jsHeaderGetter` → `request_reads`), so line 1 put a platform-wide credential in
the tenant's replay archive. Gating the *native* fixes nothing: the value was
already recorded one line above it, by a different mechanism.

**The rule.** A platform credential must not be reachable from a handler
surface. Read-taping can't redact (a redacted input replays differently), so the
surface is minimized instead — the same lever `STRIPPED_IP_HEADERS` applies to
the client IP, for the same reason.

**As-built.** On a platform-bound handler (`state.platform != null`):

- `authorization` is stripped from `request.headers`
  (`reserved_headers.zig` `PLATFORM_CREDENTIAL_HEADERS`)
- the worker computes the verdict — it holds both the header and the secret —
  and exposes it as **`request.rewind.isRoot`** (`globals_request.zig`
  `jsIsRootGetter`), lazily, recorded as `RequestReadKind.root_verdict`
- there is **no escalation rung**. `request.ip` needs one because handlers
  consume the IP *value*; nothing consumes the raw bearer, so the ladder
  collapses to one rung and the token never becomes a JS string.

```js
if (!request.rewind.isRoot) { response.status = 403; return { error: "forbidden" }; }
```

`request.rewind` is the reserved platform-metadata namespace
(`../handler-shape.md`) and does not exist off a platform-bound handler, so a
customer tenant has no surface to probe. Offline, a scenario declares the
**answer** (`scenario({ admin: true, isRoot: true })`) — there is no token to
supply, because prod has none to compare.

**When this recurs.** Any credential that reaches a handler surface. Compute the
verdict in the engine; expose the verdict. See `../decisions.md` §4.6b.

## 3.6 Privileged reads are recorded inputs

The natives in §1 that **return data** — `platform.root.get`/`.prefix`,
`platform.scope(id).kv.get`/`.prefix` — are inputs under the determinism
boundary, and they are the first input class that leaves the activation's own
tenant. They ride the kv tape channel with the store carried as a key prefix
(`__rove_store/r/…`, `__rove_store/i/{id}/…`), so an `__admin__` activation
replays against the same cross-store values it saw live. The layout, the
no-format-change rationale, and why a foreign-store key can't reach a store it
doesn't belong to are in
[`replay-and-sim.md`](replay-and-sim.md) — see the cross-store reads section.

They are also **folded into the interaction digest**, which is what turns "the
reads are recorded" into "replay is checked to serve them". Cross-store reads and
writes get no digest verb of their own — they fold as ordinary kv elements under
the same namespaced key — and the instance/release lifecycle ops fold as `o`.
`platform.scope(id)` is deliberately not folded: the id is already carried by
every read and write the handle performs. The grammar and the reasoning live in
`src/tape/interaction_digest.zig`; the pair of implementations is pinned by
`src/tape/testdata/digest_vectors.json`.

Two consequences worth holding onto when adding to this surface:

- **A new privileged verb that returns data needs a tape line AND a digest
  fold**, in the same change, on BOTH engines. Not a
  follow-up: an untaped read is a silent replay hole, because the offline
  closed world answers a missing key with `not_found` rather than a divergence.
  `platform.instances.usage` is the open case — it is installed
  (`globals.zig`) but no public shim forwards it, so it is unreachable from JS
  today; exposing it (issue #299) means taping it in the same change.
- **Recording cross-store reads puts other tenants' values, and platform root
  records, in `__admin__`'s replay archive.** That is a deliberate consequence
  of making admin replay work at all, not an oversight — see the
  secrets-in-replay posture (issue #381). Note the asymmetry with a platform
  *credential* (§3.5), which is stricter and goes the other way: data the
  handler legitimately consumes gets recorded, whereas a credential it should
  never hold is removed from the surface instead of taped.

## 4. Migration steps

1. **Collapse `__rove_*` → `__rove.*`** (globals.zig `GLOBAL_BUILTINS` →
   one holder object, like `installNamespace`); rewrite baked-module +
   shim call sites (`__rove_next` → `__rove.next`, etc.). **Done.**
2. **Delete `__rove_check_email_rate`** + `email_rate.zig`; move the
   plan-rate check to the outbound boundary as the `.outbound` limiter
   action enforced in `bindings/http.zig` `outboundRateOk` (3a). **Done.**
3. **Update `email.js`** — drop the `check_email_rate` call; it no longer
   self-limits (the outbound boundary does, un-bypassably). Customer-facing
   limiting → the kv recipe/package. **Done.**
4. **Update lint/determinism allowlist** (`globals.zig`) — the
   `builtin_exceptions` list is now empty (`GLOBAL_BUILTINS` is empty); the
   sim `__rove_check_email_rate` stub is gone, its budget check relocated
   to the sim's `recFetch` chokepoint. **Done.**
5. **Docs:** the two-surface model + assignment rule (§1) recorded — this
   doc is the design-of-record (one ABI, split by the mechanical rule,
   secured by self-gate/tenant-scope — not by the names).

Keep every `is_system_module` self-gate and `state.platform` gate exactly
as-is — this cleanup does not touch the enforcement mechanism.

## 5. Open questions

1. ~~**Outbound plan-rate** (3a) — does a per-tenant outbound limit already
   exist?~~ — resolved: it did NOT (only `.request` inbound + the `.email`
   bucket), so 3a *added* a general `.outbound` limit. Shipped.
2. ~~Collapse churn vs. keep bare~~ — resolved: the collapse shipped (one
   clear surface object is the point).
3. **`@rewind/ratelimit` package vs. recipe** — ship the token bucket as a
   first-party package or just document the recipe. Lean: package (it's a
   real reusable lib; rung-1 of saas-in-a-box §6).
