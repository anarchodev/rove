# Phase 12 — Sim test framework + simulator library

Implements [`docs/PLAN.md`](../PLAN.md) §10.7 (simulator primitive) and §10.8 (sim test framework).

> **Status 2026-07-01 — much of this plan has SHIPPED, differently than drawn.**
> The V1-era decomposition (npm/WASM CLI, `loop46` subcommands, a layered
> `ReplaySource` + `--miss-policy`/typed-holes, separate `__snapshots__` files)
> is **superseded by what was actually built.** Current reality, and the only
> accurate parts of this doc, are: **"The model"**, **"What's shipped"**, **"The
> saga test model"**, and **"What's left"** below. The `T1–T12` decomposition,
> its `Critical files`, `Verification`, and `Open questions` were removed — they
> described retired modules (`src/loop46`, `src/simulator`, `src/test_runner`,
> `src/files_server`, `examples/log_cli.zig`, all GONE) and a retired
> miss-policy/holes model.
>
> The CLI is the **Zig `rewind` binary** (`src/cli/rewind.zig`, 5-target
> cross-compile, `v0.1.0` released) linking the native arenajs replay engine
> (`rove-replay`, `src/replay/`); `loop46` is retired at the V2 cutover. The
> world is **closed-world** (no miss-policy, no holes); faithfulness is the
> `expected`/`verify` partial matcher + `--update` golden regen.

**Scope**: handler authors get deterministic, offline-capable tests (the saga
test model below); agents and developers run ad-hoc simulations via `rewind sim`.
**All execution happens in the `rewind` CLI — the worker is not involved.**

**No worker work.** No `/_system/simulate/{id}` endpoint, no thread pool, no
`simulate` rate-limit action. The engine is purely a client-side library. Worker
side is unchanged.

**Builds on** tape capture (done) + h2 dispatch (done). Independently shippable.

**Public-contract note**: the **bundle JSON shape** (emitted by `runWorld` in
`src/replay/root.zig`) and the **tape blob format** (`src/tape/root.zig`) are
external contracts — consumed by the CLI sim/replay, the browser-replay page on
`replay.rewindjs.com`, and the DAP-attach CLI (`rewind replay <id>`) per PLAN.md
§10.12. Treat them as versioned interfaces.

## The model — one run, parameterized (2026-06-30)

The framework is **one operation**, not three. An activation is the pure function
the engine already runs — `update(Msg, KV snapshot, ctx) → (writeset, Cmds,
disposition)` (`architecture/effects-and-handlers.md`). Sim, replay, and test are
all just **running that function against a *world*** and choosing what to do with
the result. There is no separate replay engine: `runWorld` (`src/replay/root.zig`)
*is* the engine, and "replay" is a corner of its input space.

### The world (per activation)

A **world** is everything an activation reads:

- the **`Msg`** — the trigger + payload (`inbound` request, a `fetch_chunk`
  result, an `on.kv`/`on.timer` wake, a `ws_message`, …);
- the **read-recorded `request` surface** — headers/body/cookies/ip, captured
  *on access* (the `request_reads` channel, `handler-shape.md` §7.1);
- the **pinned KV readset** — the values reads resolve to;
- the threaded **`ctx`** (`next({ctx})` → `request.ctx`), the only handler state
  that crosses activations, plus the deterministic **seeds** (clock/random, from
  `received_ns`).

This is exactly what the tape captures and what `export-fixture` transcodes into
a `world.json`. A **recording** is a world that was *captured*; a **fixture** is a
world that was *authored*. Same shape.

Fetches don't complicate this: `http.fetch` is a `Cmd` (an *output* of an
activation), and its result arrives as a *new* `Msg` (`fetch_chunk`) — a new
activation with its own world. So a whole request is a **chain of per-activation
worlds** linked by `Cmd(http_fetch) → fetch_chunk Msg`; each activation is
independently runnable, and a "saga run" is the optional composition that feeds
one activation's emitted fetch result into the next activation's `Msg`. No
continuation is ever reconstructed — there are no live closures across
activations, only serializable `ctx`.

### One operation: `run(world, code)`

Everything is a parameterization of one run:

| mode | world | code | what the output answers |
|---|---|---|---|
| **replay** | a **captured** recording (via `export-fixture`) | the **original** code | reproduce — "what actually happened" |
| **sim / what-if** | authored (or a captured world, edited) | any (e.g. `--source-dir` working tree) | inspect — "what *would* happen if" |
| **test** | authored | any | assert on outputs (`expected`/`verify`) |
| **regression** | a recording | original vs changed | `diff(run(rec, original), run(rec, changed))` |

**Replay is a degenerate sim** — the corner where the world is a faithful
recording and the code is the original, so the run reproduces reality. It is not
a separate verb or engine: `rewind replay` and `rewind sim` are the **same
`runWorld`** over the **same closed-world `world.json`** (`src/replay/root.zig`).
The only difference is provenance and intent — a replay world was *captured* (by
`export-fixture` from a `pull`), a sim world was *authored*.

### The closed world — a key not supplied reads `not_found`

There is no miss-policy and no "hole." A world is a **closed world**: KV reads
resolve by key against the supplied map, and a key that isn't there reads
`not_found` — a legitimate answer, never a divergence. `kv.prefix` scans the map;
`kv.set`/`kv.delete` update it (read-your-writes overlay). This replaced the
earlier `.tape` ordered-cursor + `--miss-policy fail|resolve` + typed-holes model
(all retired): an authored world carries no access order to verify against, so
faithfulness lives at the **output**, not per-read.

### Faithfulness is the `expected` matcher, not per-read checking

How do you assert a replay reproduced reality? The world optionally carries an
`expected` object — a **partial, order-independent** matcher over the produced
bundle (response subset, disposition, body, and the writes/cmds present in the
effect log). Present ⇒ the bundle gets a `verify:{pass, failures[]}`, and a failed
match exits non-zero (CI). `rewind {sim,replay} --update <world>` snapshots the
bundle's facets back into `expected` (golden regen). `export-fixture` seeds it
with the recorded status (`expected:{response:{status}}`), so a replay of the
original code against its own recording verifies clean, and any behavioral change
surfaces as a `verify` failure.

### Why this matters for the agent (the primary CLI user)

The CLI's primary user is an LLM, and the model collapses to one tool with two
knobs (`world`, `code`):

- **replay = the agent's ground-truth source** — reproduce a real recorded
  request against the original code and confirm (via `verify`) it still matches;
  diagnose an incident from what actually happened.
- **sim = the agent's counterfactual / authoring space** — author a world (or
  edit a captured one), run any code (`--source-dir` = the working tree), inspect
  the effect log. It can express things that never happened, so treat it as a
  claim, not truth.
- **fixing a bug = `diff(replay of the failure, sim of the fix)`** on the same
  recorded input — the same primitive, two code args, composed.

The honest one-liner: **replay reproduces what happened; sim shows what-if and is
only as good as the world you (or the LLM) supply.**

## What's shipped

The one engine over a **closed-world** `world.json` is live for both `sim` and
`replay`, reusing the single native arenajs link (`rove-replay`) — no second
engine, exactly as the model demands.

- **The declarative world** (`src/replay/world.zig`) is a plain JSON document an
  author or LLM writes. Schema: `{ entry, activation, export?, request{method,
  path,host,headers,body,ip,status?,ok?,done?,fetchId?,chunkSeq?,activation?},
  kv{key→value}, ctx?, seed, now_ms, sources[], expected? }`. KV is a key→value
  **map** (order-independent — an authored world carries no access order to
  verify against); values are JSON-stringified for convenience (write
  `{ "name": "Jess" }`, not a hand-escaped string).
- **Map-mode reads** (`src/replay/host.zig`): order-independent lookup with a
  write-through overlay (`kv.set`/`delete` → read-your-writes); a missing key is
  `not_found`; `kv.prefix` scans the map (cursor + limit honored). The request
  surface is rebuilt by synthesizing `request_reads` entries from the declared
  request, so the epilogue serves it untouched.
- **All activation kinds**, not just `inbound`: the world declares the
  `activation` kind + the resolved `export` (a callback's `{to}`/`onFetchResult`/
  `onWake` name — the runtime resolves this on the wake, so the world carries it;
  `architecture/replay-and-sim.md` §2), the threaded `ctx` (→ `request.ctx`), and
  the flattened fetch/callback result under `request`.
- **`runWorld`** (`src/replay/root.zig`) emits the bundle: `{ activation, export,
  response{status,headers,cookies}, disposition (terminal+body | held+ctx),
  effects[] (one ordered log of read|write|fetch|…|log), error, ok }`, plus
  `verify:{pass,failures[]}` when the world carried `expected`. It is now
  **multi-shot** — one `arena_init`, per-run `JS_ResetRequestArena` — so a process
  can fold many activations (the saga model below; `driver_smoke multi`).
- **CLI**: `rewind sim|replay <world.json> [--source-dir DIR] [--update] [-o FILE]`
  — fully offline, bundle to stdout so `rewind sim … | jq` works. `--source-dir`
  is the *code* knob (swap in the working tree); `--update` is the golden knob.
- **`export-fixture`** (`rewind export-fixture <base64-record.json> [-o world.json]`)
  transcodes a captured recording (from `rewind pull`) into an editable, offline
  closed-world `world.json`: the ordered read cursor → an initial-snapshot kv map
  (re-reads / post-write reads drop, reproduced by the overlay); `request_reads`
  → the `request` surface; recorded status → `expected:{response:{status}}`;
  sources and seed/now carried. Inbound family; non-inbound warns — the pulled
  fixture has no ctx / fetch-result / resolved export
  (`architecture/replay-and-sim.md` §5 G1–G3).
- **The saga fold** exists as a Python prototype (`scripts/sim/scenario_driver.py`)
  over the single-activation engine — the native JS target it prefigures is the
  saga model below.

## The saga test model — a lazy tree of pure activations (2026-07-01)

The single-activation `run(world, code)` above is the atom. A real test composes
atoms: you supply a world, run an activation, assert on what it emitted, then
**resolve the effects it emitted** to drive the activations that depend on them.
A test is a walk over a tree of activations.

### What you supply, what the engine produces

The split is clean and total:

- **You own the world (inputs)** — the `Msg`, the KV readset, `ctx`, seed, clock
  — and the **resolutions** of the effects an activation emits (what the outside
  returns: an upstream fetch's status/body, a delivery's success, the passage of
  time).
- **The engine owns the activation** — a pure function `simulate(world) → bundle`.
  The bundle's **effect log** is the output: an ordered list of reads, writes,
  and `Cmd`s the handler decided to perform.

Input (`world`) and output (`bundle`) never blur. You assert on the effect log —
what the handler *decided to do* — because that is the same artifact production
replicates through raft. To drive what happens next, you hand a `Cmd` its result,
and that produces the next activation's world.

### Effects are values, and they carry their own correlation

A `Cmd` in the effect log is data, and it carries everything needed to build the
activation that consumes its result. A `fetch` cmd carries its continuation
export (`to`) and the `ctx` the handler attached; a `schedule` carries its due
time and wake key. So "resolve the fetch" means: supply only the *external*
answer (the upstream response) — the engine already knows which export to invoke,
which `ctx` to thread, and which KV overlay to carry in. You never hand-assemble
the dependent world.

### The world threads forward (the fold)

Resolving a cmd folds the parent activation's outputs into the dependent
activation's world:

- **KV overlay** — the parent's writes/deletes fold into the child's readset
  (read-your-writes across activations);
- **`ctx`** — the parent's `next({ctx})` / the cmd's attached `ctx` becomes the
  child's `request.ctx`;
- **clock** — `now_ms` advances by the effect's latency (a fetch's round-trip, a
  schedule's delay), so `Date.now()` in the child reflects when it actually runs;
- **seed** — each activation gets its own deterministic per-activation seed.

`world' = fold(world, bundle, resolution)` is a pure function of values. The
successor world is itself a value.

### Nodes are lazy and immutable → a dependency DAG

Because the successor world is a value and `simulate` is pure, a test node need
not be an executed result — it is a **thunk that knows how to compute itself**.
Forcing a node (by asserting on it) runs the memoized chain from the nearest
already-evaluated ancestor; siblings share the parent's evaluation. So an inbound
that fans into three branches runs **once**, and each branch forks from its
memoized world.

Deferring, memoizing, and re-ordering evaluation are sound for one reason: an
activation is a pure function of its world, and the world is a value with no
hidden engine state (the runtime resets between runs; the KV overlay is explicit;
clock and seed are fields). This is why threading the clock and per-activation
seed is not merely faithful but *required* — a memoized branch must be
deterministic on re-force.

### The authoring surface — eager by default, combinators for the tree

The default reads as a straight-line test: `expect` forces its own node and fails
locally.

```js
import { scenario, expect } from "rewind:test";

const s = scenario({
  sourceDir: "./src",
  kv: { "cart/jess": JSON.stringify({ item: "book", price: 1200 }) },
  now: "2026-07-01T00:00:00Z",
  seed: 42,
});

// run the request
const req = s.inbound({ method: "POST", path: "/checkout", body: { user: "jess" } });
expect(req.status).toBe(202);                            // forces `req` — inbound runs once
expect(req).toHaveWritten("order/jess", { status: "pending" });
expect(req).toHaveFetched(/stripe/);

// resolve the effect it emitted → the dependent activation
const charged = req.fetch(/stripe/).resolve({ status: 200, body: { id: "ch_1" } });
expect(charged).toHaveWritten("order/jess", { status: "paid" });
expect(charged).toHaveSent("email", { to: "jess@ex.com" });
expect(charged.kv("order/jess")).toEqual({ status: "paid" });
```

Reaching for the tree is opt-in. A branch point forks the shared prefix:

```js
const [paid, declined, timedOut] = req.fetch(/stripe/).branch([
  { status: 200, body: { id: "ch_1" } },
  { status: 402 },
  { timeout: true },
]);
expect(paid).toHaveWritten("order/jess", { status: "paid" });
expect(declined).toHaveWritten("order/jess", { status: "failed" });
expect(timedOut).toHaveScheduled(/retry/);
```

An invariant across every future, without naming them:

```js
req.fetch(/stripe/).cases(STRIPE_RESPONSES).forEachPath(node =>
  expect(node.kv("order/jess").status).toMatch(/paid|failed|pending/)
);
```

Concurrent effects and their delivery orders:

```js
req.whenConcurrent(/stripe/, /inventory/).interleavings().forEachPath(node =>
  expect(node.kv("order/jess")).toBeConsistent()
);
```

Advancing time to fire a due wake is the same shape:

```js
const retry = charged.clock.advance("1h").fire();   // fires scheduled wakes now due
```

### Correlation catalog — which cmd spawns which activation

| Emitted `Cmd` | You supply | Dependent activation |
|---|---|---|
| `fetch` | the upstream response | `fetch_chunk` → the `to` export, ctx + overlay threaded |
| `schedule` / timer | `clock.advance(…).fire()` | wake → the wake export, `now_ms` advanced |
| `webhook.send` / `email.send` | delivery success / failure | send-callback (the retry/idempotency ladder) |
| `ws.send` / subscription | inbound frame / fire | connection activation |

Fetch is the built path (`scenario_driver.py`); the rest are the correlation work this model
calls for (clock-advanced wakes and send-callbacks are the highest-value because
the durable scheduler and retry ladder are otherwise unexercised end-to-end).

### Expectations — assertion and snapshot, at node and saga granularity

Two kinds, both available at any node and over the whole run:

- **Assertion** (`expect(node).toHaveWritten(…)`, `toHaveSent(…)`, `.kv(k)`) —
  intent that must hold, and survives unrelated refactors.
- **Snapshot** (`expect(node).toMatchSnapshot()`, `scenario.toMatchSnapshot()`)
  — captured behavior, re-baselined with `--update`. This is the same
  `expected`/`--update` machinery the single-activation world already has
  (`src/replay/root.zig`), lifted to node and saga scope.

### Architecture — one native atom, the rest is JS

`simulate(world) → bundle` is the only native operation (the multi-shot
resettable `runWorld` — one `arena_init`, per-run `JS_ResetRequestArena`). The
tree, the fold, the correlation, the clock, the combinators, and the `expect`
matchers are a **JS library over that atom**. The declarative scenario file is a
thin reader that folds through the same library. So the saga layer is authored in
the same JS the handlers are, and the native surface stays "run one pure
activation."

### Recording and authored world are the same input

A world can be **captured** (`rewind export-fixture` from a `rewind pull`
recording) or **authored** by hand or by an agent. Same shape, same engine, same
tree composition on top. A test fixture and a slice of real production traffic
are interchangeable inputs — a captured recording *is* a runnable, forkable test
world.

## What's left

- **The JS test runner** (`rewind test` + `_tests/*.mjs`) — the saga model above,
  authored as JS. Blocked on a **second runtime**: the test body runs its own
  `expect`/control flow in a harness runtime while `simulate()` drives worlds in
  a separate reset-reused sim runtime (you can't reset the harness's own request
  arena mid-test). arenajs arena state is per-runtime, so two runtimes on one
  thread are safe (verified 2026-07-01); the work is de-singletoning the reactor
  (`g_rt`/`g_ctx` → instance-based + a `simulate` native bridging to `runWorld`).
  That is an arenajs C change (push-then-pin).
- **Correlation beyond fetch** — the saga fold today (`scenario_driver.py`) only
  resolves `fetch → fetch_chunk`. Add **clock-advanced timer/schedule wakes** and
  **webhook/email send-callbacks** (the durable scheduler + retry ladder,
  otherwise unexercised end-to-end), plus threading the clock into `now_ms` and a
  per-activation seed. See the correlation catalog above.
- **In-process scenario driver** — port `scripts/sim/scenario_driver.py` onto the
  now-multi-shot `runWorld` (no more subprocess per activation). Cheap adjacent
  win, no dep change.
- **Production-strip of `_tests/`** — exclude `_tests/`, `__snapshots__/`,
  `__fixtures__/` from deploy manifests (client-side strip in the deploy path +
  server-side reject in the worker's `/_system/deploy`). The client-side strip
  already lives in `common.classify`.

## Critical files (current)

- `src/replay/root.zig` — `runWorld` (the engine), `appendVerify`/`updateExpected`
  (the `expected` matcher + `--update`), bundle emit. Multi-shot.
- `src/replay/world.zig` — the closed-world `world.json` schema + parser.
- `src/replay/host.zig` — map-mode KV host (reads/writes/prefix, overlay). Still
  carries a vestigial `.tape` mode + a stale `miss` doc-comment — dead code.
- `src/replay/epilogue.zig` — request/ctx/result reconstruction + export invoke.
- `src/replay/export_fixture.zig` — capture → closed-world transcode.
- `src/replay/driver_smoke.zig` — end-to-end native smoke (`inbound`/`fetch`/`multi`).
- `src/cli/rewind.zig` — the `sim`/`replay`/`export-fixture`/`pull` verbs.
- `scripts/sim/scenario_driver.py` — the saga fold prototype (to be ported to JS).

## Open questions (current)

1. **JS saga surface: threading shape** — dependent activations hang off the
   parent node (`req.fetch(…).resolve(…)`, immutable/forkable) vs a stateful
   scenario. Leaning node-threaded — forking is the power (see the saga model).
2. **Test discovery** — every `.mjs` in `_tests/` is walked; underscore-prefix
   (`_helpers.mjs`) opts out. Confirm the convention.
3. **Golden storage for saga tests** — the single-activation golden lives inline
   in the world's `expected` (`--update`). For saga/JS tests, keep it inline per
   node, or a sibling `__snapshots__` file? Inline matches what shipped.
