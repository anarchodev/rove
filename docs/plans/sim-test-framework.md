# Phase 12 — Sim test framework + simulator library

Implements [`docs/PLAN.md`](../PLAN.md) §10.7 (simulator primitive) and §10.8 (sim test framework).

> **CLI naming/host updated 2026-06-10.** This plan predates `decisions.md`
> §8.3 (2026-05-15): the CLI ships as the **`rewind` npm package** (Node over
> the arenajs-WASM replay porcelain), not as Zig subcommands of a server
> binary — and the V1 `loop46` binary is retired (V2 cutover). CLI verbs here
> are now spelled `rewind <verb>`; the `src/loop46/*_cmd.zig` implementation
> pointers and the "embeds QuickJS via `rove-qjs`" hosting details below are
> V1-era — the verb surface, modes, and semantics stand, the host is the npm
> CLI (package layout decided at build time).

**Scope**: handler authors get deterministic, offline-capable tests via `rewind test` and a `_tests/` directory; agents and developers can run ad-hoc simulations via `rewind simulate`. **All execution happens in the `rewind` CLI — the worker is not involved.**

**No worker work in this phase.** No `/_system/simulate/{id}` endpoint, no thread pool, no `simulate` rate-limit action. The simulator is purely a client library. Worker side is unchanged.

**No dependencies on other Phase 12+ work.** Builds on tape capture (already done) + h2 dispatch (Phase 1, done). Independently shippable.

**Public-contract note**: once Phase 12 ships, the **bundle JSON shape** (`src/tape/bundle.zig`) and the **tape blob format** (`src/tape/root.zig`) become external contracts — consumed by the CLI sim, the launch-path browser-replay page on `replay.rewindjs.com`, and the launch-path DAP-attach CLI (`rewind replay <id>`) per PLAN.md §10.12. Changes to either are coordination points across the test runner, the export-fixture tool, the dashboard, and both replay paths. Treat them as versioned interfaces from the start (T4's `replay_available` flag exists partly for forward-compat signaling).

## The model — one run, parameterized (2026-06-30)

The framework is **one operation**, not three. An activation is the pure function
the engine already runs — `update(Msg, KV snapshot, ctx) → (writeset, Cmds,
disposition)` (`architecture/effects-and-handlers.md`). Sim, replay, and test are
all just **running that function against a *world*** and choosing what to do with
the result. There is no separate replay engine: the simulator (T5/T6) *is* the
engine, and "replay" is a corner of its input space.

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

This is exactly the bundle the tape captures (T2/T3/T4) and the `ReplaySource`
layers serve (T5). A **recording** is a world that was *captured*; a **fixture**
is a world that was *authored*. Same shape.

Fetches don't complicate this: `http.fetch` is a `Cmd` (an *output* of an
activation), and its result arrives as a *new* `Msg` (`fetch_chunk`) — a new
activation with its own world. So a whole request is a **chain of per-activation
worlds** linked by `Cmd(http_fetch) → fetch_chunk Msg`; each activation is
independently runnable, and a "saga run" is the optional composition that feeds
one activation's emitted fetch result into the next activation's `Msg`. No
continuation is ever reconstructed — there are no live closures across
activations, only serializable `ctx`.

### One operation: `run(world, code, on-miss)`

Everything is a parameterization of one run:

| mode | world | code | on-miss | what the output answers |
|---|---|---|---|---|
| **replay** | a **captured** recording | the **original** code | **fail-loud** | reproduce — "what actually happened" |
| **sim / what-if** | captured and/or authored | any (e.g. working tree) | **resolve** | inspect — "what *would* happen if" |
| **test** | authored (often grown via sim) | any | fail (under-specified) | assert on outputs |
| **regression** | a recording | original vs changed | — | `diff(run(rec, original), run(rec, changed))` |

**Replay is a degenerate sim** — the corner where the world is a faithful,
complete recording and the code is the original, so the run provably reproduces
reality. It is not a separate verb or engine; it is the *named contract*
`captured ∧ original-code ∧ no-holes`. The value of the name is being able to
**assert** that contract — to demand "run this and fail if you'd have to invent
or diverge" — so that "what actually happened" can be trusted. Drop the contract
and a run can silently fill a gap, and you can no longer tell reconstruction from
fabrication.

### The on-miss policy *is* the replay↔sim axis

When a run reads something the world doesn't supply (a changed handler takes a
new branch; an authored world is partial), the engine emits a **typed hole** — a
read-descriptor `{kind, key, expected-shape, activation}` — and the **calling
surface binds it**:

- **replay** sets on-miss = **fail-loud** (the `REPLAY DIVERGENCE` already built,
  §7.1): a miss means the run left reality. Replay therefore needs **no
  resolver** — a faithful run of the original code against its own recording
  structurally *cannot* miss.
- **sim** sets on-miss = **resolve**, bound per surface: the web UI renders the
  hole as a form field (and the answer authors the fixture); a tty CLI prompts; a
  flag returns `empty`/`default`; an **LLM** receives the hole as a structured
  "unresolved read" (Phase 13 `fixture-lifecycle.md` T4) and answers it — which
  *runs and authors a fixture in the same pass* (lazy world-building: the handler
  pulls the values it needs, the answers snapshot into a golden fixture). One
  hole, many bindings — the agent uses the same surface a human does.

So "replay vs sim" is not two verbs; it is the `--miss-policy` already in T7
(`fail` vs `not_found`/resolve), over one engine.

### Provenance is tracked per read

`on-miss = fail` guarantees **no holes**, but not that the world is *real* — a
fully-authored world with no holes still isn't "what happened." So each resolved
read records its **source** (T5 already emits `{source: tape|overlay|buffer}`);
that per-read provenance is what lets a run claim faithfulness. `captured` (every
read served from the tape) ∧ `original-code` ∧ `no-holes` ⇒ the run *is* reality;
anything else is a sim, however complete.

### Why this matters for the agent (the primary CLI user)

The CLI's primary user is an LLM, and the model collapses to one tool with three
knobs (`world`, `code`, `miss-policy`):

- **replay = the agent's zero-hallucination truth source** — diagnosing a real
  incident from ground truth; it *cannot* invent, because there are no holes to
  fill (`--miss-policy fail` on a captured world).
- **sim = the agent's counterfactual / authoring space** — and *because* it can
  invent (holes → the LLM answers), it is the part to guard (typed holes,
  fidelity caveats). Answering holes lazily authors the fixture/test, which feeds
  Phase 13's `rewind test --auto-fix-from`.
- **fixing a bug = `diff(replay of the failure, sim of the fix)`** on the same
  recorded input — the same primitive, two code args, composed.

The honest one-liner: **replay tells you what happened and cannot be wrong; sim
tells you what-if and is only as good as the world you (or the LLM) supply.**
Keeping `--source-dir` and hole-resolution *out* of the faithful corner is what
preserves that distinction.

### Built 2026-06-30 — `rewind sim` over a declarative world

The first slice of the one engine for an **authored** world (the sim corner)
shipped. It reuses the native replay engine (`rove-replay`, the same
arenajs link `rewind replay` already uses) — no second engine, exactly as the
model demands.

- **The declarative world** (`src/replay/world.zig`) is a plain JSON document an
  author or LLM writes: `{ entry, activation, request{method,path,host,headers,
  body,ip}, kv{key→value}, seed, now_ms, missPolicy, sources[] }`. KV is a
  key→value **map** (not an ordered tape) because an authored world carries no
  access order to verify against. Non-string `kv`/`body`/header values are
  JSON-stringified (so you write `{ "name": "Jess" }`, not a hand-escaped
  string).
- **Map-keyed reads + miss policy** (`src/replay/host.zig`): the replay host
  gained a `.map` mode (order-independent lookup; `kv.prefix` scans the map) and
  a `MissPolicy` — `fail` (refuse to invent → divergence, the replay corner) or
  `resolve` (answer `not_found` and record a **typed hole**). The replay
  cursor path (`.tape`) is byte-identical. The request surface is rebuilt by
  *synthesizing* `request_reads` entries from the declared request, so the
  existing epilogue serves it untouched — undeclared header reads are naturally
  `undefined`.
- **`runWorld`** (`src/replay/root.zig`) emits a sim bundle: `{ mode:"sim",
  miss_policy, run_rc, divergence, kv_writes[], holes[], run{response,result,
  error,console}, ok }`. `holes[]` is the typed-hole list the calling surface
  binds (CLI/UI/LLM) — the load-bearing T5 provenance, surfaced.
- **CLI**: `rewind sim <world.json> [--source-dir DIR] [--miss-policy
  fail|resolve] [-o FILE]` — fully offline (handled before `loadCfg`, like
  `replay`); the bundle goes to **stdout** so `rewind sim … | jq` works.

This subsumes the old T7 `--mode strict|what_if|isolated` knob: the world itself
declares what's present, `--source-dir` is the *code* knob, and `--miss-policy`
is the *replay↔sim* knob — three knobs, one `run`.

**Extended same day to all activation kinds.** A world isn't limited to
`inbound`: it declares the `activation` kind, the resolved `export` (a callback's
`{to}`/`onFetchResult`/`onWake`/… name — the runtime resolves this on the wake,
not from the kind, so the world must carry it; `architecture/replay-and-sim.md`
§2), the threaded `ctx` (→ `request.ctx`), the flattened fetch/callback result
under `request` (`status`/`ok`/`done`/`fetchId`/`chunkSeq`, body delivered on
`request.body`), and a `request.activation` metadata bag (`wakes`/`msg`/…). The
host's `.map` mode and miss policy are unchanged; the epilogue gained the
ctx/result/activation installation (null for inbound → the inbound path is
byte-identical). Verified by `rewind sim` on a `fetch_chunk`→`onFetchResult`
gateway world and a `wake_batch`→`onWake` SSE-drain world. This is the cheap,
recording-free half of the replay/sim asymmetry: **sim** of any activation works
now; **faithful replay** of non-inbound activations still needs the recording to
persist the dispatch target (`architecture/replay-and-sim.md` §5 G1–G3).

**`export-fixture` landed 2026-06-30 (T10), inbound family.** `rewind
export-fixture <pulled-fixture.json> [-o world.json]` transcodes a captured
recording (a `rewind pull` fixture — same JSON `rewind replay` consumes) into an
editable, offline, fail-loud declarative world `rewind sim` reproduces — the
bridge from the replay corner to the sim corner. The KV transcode walks the
ordered read cursor into an **initial-snapshot map** (first taped read per key;
re-reads / post-write reads drop, reproduced by the sim host's write-through
overlay) plus a **`kvAbsent`** list (recorded `not_found` reads), so a
`missPolicy:"fail"` sim reproduces the recording exactly and any *new* read
diverges. `request_reads` → the `request` surface; sources pass through
(self-contained); seed/now carried. This rests on the host's **write-through
overlay** (`kv.set`/`delete` update the read map — read-your-writes) + the
**`kvAbsent`** read rule (a known absence is `not_found` with no hole), both
landed same day in `src/replay/host.zig`. Non-inbound activations warn — the
pulled fixture has no ctx / fetch-result / resolved export
(`architecture/replay-and-sim.md` §5 G1/G3).

Still ahead (T8/T9/T11): the `_tests/` runner + `expect`/`snapshot` globals
(a test = `run(authored-world, code, on-miss=fail)` + assertions), and the
production-strip of `_tests/` (the client-side strip already lives in
`common.classify`; the server-side 422 reject remains).

## What already exists

- **Tape capture — done.** `uploadTapes` (`src/js/worker.zig:901-938`), `LogRecord.tape_refs` populated, blob storage at `{data_dir}/{id}/log-blobs/`.
- **Bundle JSON emission — done in CLI.** `rove-log-cli bundle --request-id H` (`examples/log_cli.zig:208-433`) produces the canonical bundle shape.
- **PRNG seeding — done.** `Request.received_ns` (`src/js/dispatcher.zig:110, 292`) makes math/crypto deterministic from the seed.
- **Module tape infrastructure — partly done.** `Channel.module`, `appendModule`, serialize/decode in `src/tape/root.zig`, but no caller in `src/`. T3 below wires it in.
- **`ReplaySource` — not built.** `src/js/globals.zig:862-863`: "the next slice."
- **Test runner — not built.**
- **Request body capture — not built.** Tape has no request-input channel today; T2 adds one.

## T1–T11 ordered

### T1. Bundle module extraction

Move `runBundle` and friends out of `examples/log_cli.zig` into `src/tape/bundle.zig`. CLI keeps a thin wrapper. The simulator library and the test runner both import the module. (Note: `examples/log_cli.zig` no longer exists; bundle JSON now rides inline in the log-server ndjson record — adjust extraction target accordingly.)

### T2. Request body capture (new tape channel)

Tape currently has no request-input channel. Without it, replays from `from_recorded_request_id` can't reproduce the original POST body. Add a request-input channel to the tape, wire capture at request-receive time in `dispatchOnce`. Bundle JSON's `request.body` field gets populated when the channel is present.

This T-step also unblocks Phase 13's dry-run bundles (which want to capture the request input alongside other tape entries).

### T3. Module tape wiring

`Channel.module` exists but isn't recorded. Wire `appendModule` at the `JS_ResolveModule` boundary in `src/js/globals.zig`. Needed for multi-file handler determinism in sim replays.

### T4. Bundle JSON additions

Small evolutions in the JSON-emit layer (no binary tape format change):
- **Cross-channel `seq`**: tape entries already have a reserved `seq: u32` field (`src/tape/root.zig:46`). Start writing it at capture time so consumers can reconstruct cross-channel order. Emit a flat `effects: [...]` list alongside per-channel tapes.
- **Structured stack frames**: split freeform `exception` string into `{ "message": "...", "stack": [{"file","line","col","fn"}, ...] }`.
- **Value previews**: kv tape entries embed full `value` bytes today. Switch to `value_preview` (truncated at e.g. 1KiB) + `value_bytes: N` + the existing hash so a follow-up call can fetch the full value.
- **Structured console**: array of `{level, msg}` objects.
- **`replay_available` flag**: tells consumers whether the simulator can rerun this bundle.
- **`tape_entries` field**: for inline tape data (used by Phase 13 dry-run bundles where there's no persisted blob hash). Optional alongside `tape_refs` (which references blobs by hash for live-dispatched bundles).

### T5. `ReplaySource` with composable read layers

New module `src/simulator/replay_source.zig`. Layers high → low:

1. Request-scoped write buffer (always active).
2. Overlay map (optional).
3. Tape — parsed from blob or inline (optional).
4. Miss policy — `fail` (structured "unresolved read on K") or `not_found`.

Each read returns the first hit and records its source on the output bundle (`{"source": "tape" | "overlay" | "buffer"}`). Inline tests per layer in isolation.

There is **no live-KV layer**. The simulator stays KV-less by design (PLAN.md §10.7 explains why).

### T6. Simulator module

New module `src/simulator/`:
- `root.zig` — public API; mode → layer dispatch; bundle assembly. Library-only entry point (no thread pool, no standalone binary).
- `replay_source.zig` — the layered read stack (T5).
- `bytecode_cache.zig` — LRU keyed by `(deployment_id_or_path, file_path)`. Used by `rewind test` and `rewind simulate` to avoid recompiling the same source across many test invocations.
- `compile.zig` — small wrapper around `Context.compileToBytecode` for compiling overlay sources on demand. The simulator already needs QuickJS for execution; compilation is the same library.

The simulator deliberately does not depend on `rove-kv` — its only inputs come from `ReplaySource` layers + compiled bytecode. This is what makes the library CLI-linkable and keeps the binary small.

### T7. `rewind simulate` CLI subcommand

New CLI subcommand at `src/loop46/simulate_cmd.zig`. Exposes the simulator library directly:

```
rewind simulate \
  --request '{"method":"POST","path":"/api/orders","body":"..."}' \
  [--kv-overlay <fixture.json>] \
  [--from-recorded <request_id>] \
  [--source-dir <path>]              # default: cwd
  [--mode strict|what_if|isolated]   # default: isolated
  [--miss-policy fail|not_found]     # default: not_found
  [--tape-blob <path>]               # for replay against a saved tape file
  [--json]                           # default: human-readable
→ bundle JSON on stdout
```

No HTTP. Reads handler source from `--source-dir` (or fetches via the existing `/_system/files/{id}/source/{hash}` endpoints if `--from-recorded` references a non-local deployment). Runs the simulator library in-process, emits a bundle. Useful for:
- Quick "what does this handler do given input X" checks.
- Agent ad-hoc debugging without writing a full test file.
- Composing into shell pipelines (`rewind simulate ... | jq`).

### T8. `rewind test` CLI subcommand

New CLI subcommand entry at `src/loop46/test_cmd.zig`. Embeds QuickJS via `rove-qjs` (for executing the test code itself) and links the simulator library directly (so `simulate(...)` from inside test code is in-process).

Walks `_tests/` from the working tree (or `--source-dir` override), parses each `.mjs` file as an ES module, runs each exported async function in its own QuickJS context with injected globals.

Flags:
- `rewind test` — runs all sim tests in `_tests/`.
- `rewind test --filter <pattern>` — name-glob filter.
- `rewind test --update-snapshots` — regenerate snapshots.
- `rewind test --json` — structured pass/fail output.
- `rewind test --source-dir <path>` — override working tree.

Exit code 0 on green, 1 on any failure. Output: pass/fail per test, aggregate counts.

### T9. Test runner infrastructure

New module `src/test_runner/`:
- `root.zig` — walks `_tests/`, parses files, dispatches each test function to its own QuickJS context.
- `loader.zig` — module loader for test code. Enforces that test files cannot import from non-`_tests/` underscore-prefixed paths (they're platform-reserved).
- `globals.zig` — injected globals: `simulate`, `expect`, `snapshot`.
- `snapshot.zig` — capture, compare, regenerate. Storage at `_tests/__snapshots__/{name}.json`.

Globals in detail:
- `simulate(req)` — calls into the simulator library directly. `req.deployment` may be `"current"` (loads working-tree source) or a deployment_id (fetches via `/_system/files/{id}/source/{hash}`, but rare in tests).
- `expect(value)` — assertion DSL: `.toBe(x)`, `.toEqual(x)`, `.toMatchObject(x)`, `.toContainKeyMatching(re)`, etc. Throws on mismatch with structured diff.
- `snapshot(name, value)` — first run captures to `_tests/__snapshots__/{name}.json`; subsequent runs assert structural equality, fail with diff.

### T10. `rewind export-fixture` tool

CLI: `rewind export-fixture --request <hex_request_id> [--instance <id>]`. Writes two files atomically:
- `_tests/from-prod-{request_id}.mjs` — test code that calls `simulate({from_recorded_request_id: ...})` and asserts via `snapshot(...)` against the recorded bundle.
- `_tests/__fixtures__/from-prod-{request_id}.json` — captured tape data + recorded bundle.

The runner detects fixture files by sibling-file convention: when `simulate(...)` is called with `from_recorded_request_id` and a sibling `__fixtures__/from-prod-{id}.json` exists, load it from disk instead of any network call. Fixtures stay offline-runnable forever.

### T11. Production-strip of `_tests/`

Modify the deploy path to exclude `_tests/`, `_tests/__snapshots__/`, and `_tests/__fixtures__/` from manifests submitted via `POST /v1/instances/{id}/deployments`. Test files live in the dev repo only; production deployments never include test code.

Implementation: client-side strip in `rewind deploy` (avoids wasted upload) AND server-side reject (defensive — 422 if any underscore-test path slips through).

### T12. Drive-by — fix `src/log/root.zig:71` stale comment

"Phase 4 will populate these. Phase 3 keeps them all null." Wrong — `tape_refs` is populated end-to-end. Two-line fix.

## Critical files

**New code**:
- `src/tape/bundle.zig` — bundle JSON emit (extracted from `examples/log_cli.zig`). T1 + T4.
- `src/simulator/{root,replay_source,bytecode_cache,compile}.zig` — simulator library. T5 + T6.
- `src/test_runner/{root,loader,globals,snapshot}.zig` — test runner module. T9.
- `src/loop46/simulate_cmd.zig` — `rewind simulate` CLI subcommand. T7.
- `src/loop46/test_cmd.zig` — `rewind test` CLI subcommand. T8.

**Extend**:
- `src/js/globals.zig` — wire `appendModule` at module-resolve boundary (T3); wire request body capture into the tape (T2).
- `src/js/worker.zig` — capture request body at dispatch entry (T2).
- `src/tape/root.zig` — request-input channel + serialize/decode (T2).
- `src/loop46/main.zig` — register `simulate`, `test`, and `export-fixture` subcommands.
- `src/files_cli/` (or wherever the deploy client lives) — strip `_tests/` paths (T11).
- `src/files_server/root.zig` — server-side reject of `_tests/` in deploy manifests (T11).
- `src/log/root.zig:71` — fix stale comment (T12).
- `examples/log_cli.zig` — convert to thin wrapper around `src/tape/bundle.zig` (T1).

**Worker is otherwise unchanged.** No new endpoints, no new rate-limit actions, no new modules touching the dispatch hot path.

## Verification

- Inline Zig tests in `src/simulator/replay_source.zig` for each layer + each mode boundary.
- Inline Zig tests in `src/test_runner/snapshot.zig` for capture / compare / regenerate / diff format.
- `scripts/simulate_smoke.sh` covers all three modes via the CLI:
  - **strict**: `rewind simulate --from-recorded <id> --source-overlay <modified> --mode strict` → assert bundle reflects modified source. Introduce a new read in modified handler → assert `unresolved` reported.
  - **what_if**: `rewind simulate --from-recorded <id> --kv-overlay <fixture> --mode what_if` → assert overlay value flows through.
  - **isolated**: `rewind simulate --request '...' --kv-overlay <fixture> --mode isolated` → assert handler runs and bundle effects are captured. Confirm zero network connections.
- `scripts/sim_test_framework_smoke.sh`:
  - Set up a working tree with `_tests/orders.mjs`. Run `rewind test` with no server running → assert all sim tests pass; first run captures snapshots. Confirm zero network connections.
  - Modify handler to change recorded behavior → `rewind test` → assert sim test fails with structural snapshot diff; assert diff is human-readable.
  - `rewind test --update-snapshots` → assert snapshot file updated, next run green.
  - `rewind export-fixture --request <recorded_id>` → assert two files written (test + fixture); subsequent `rewind test` runs the fixture offline (kill server, confirm pass).
  - `rewind deploy` → assert resulting manifest contains no `_tests/` paths.

## Open questions

1. **CLI: bundled subcommand or separate binary?** `rewind simulate` and `rewind test` as subcommands keep deploy story simple; separate `rewind-test` binary keeps QuickJS deps out of the main `rewind` package if size matters. Probably subcommand for v1.
2. **Test discovery**: every `.mjs` file in `_tests/` is walked. Convention: a file with no exported async functions matching the test signature contributes no tests. Allow underscore-prefix filenames (`_helpers.mjs`) for "definitely not a test"?
3. **Snapshot file format**: pretty-printed JSON for diff readability (more bytes) vs compact JSON (smaller, faster). Default to pretty for v1; revisit if repo size becomes a complaint.
4. **`rewind simulate` request input**: `--request` accepts inline JSON; for complex requests, accepting `--request-file <path>` would be ergonomic. Probably yes for v1.
5. **Source override on `simulate(...)` in test code**: should test code be able to pass `simulate({source_overlay: {...}, ...})` to test against a modified handler within a sim test? Useful for "would my fix affect this case?" Probably yes; it's just another layer the simulator library already supports.
