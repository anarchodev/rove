# Phase 12 — Sim test framework + simulator library

Implements [`docs/PLAN.md`](PLAN.md) §10.7 (simulator primitive) and §10.8 (sim test framework).

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
