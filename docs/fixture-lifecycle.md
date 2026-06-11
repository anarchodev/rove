# Phase 13 — Fixture lifecycle + worker dry-run

Implements [`docs/PLAN.md`](PLAN.md) §10.9 (fixture lifecycle tooling) and §10.11 (worker dry-run dispatch mode).

> **CLI naming/host updated 2026-06-10.** Per `decisions.md` §8.3 the CLI is
> the **`rewind` npm package** (Node over arenajs-WASM), and the V1 `loop46`
> binary is retired. Verbs here are spelled `rewind <verb>`; the
> `src/loop46/*_cmd.zig` pointers are V1-era hosting detail — the command
> surface and semantics stand. The worker-side dry-run endpoint (T7) is
> unaffected.

**Scope**: tooling to author, edit, refresh, and diff sim test fixtures (§10.9), plus the worker-side `dry-run` dispatch mode that lets customers capture realistic tape data from synthetic requests without persistence (§10.11).

**Why land them together**: dry-run is a fixture-authoring power tool. The natural flow is "fire a synthetic request via dry-run → get a bundle with inline tape → save the kv portion as a fixture file." `rewind fixture from-dry-run` composes both. The two pieces are small and synergistic.

**Why land independently of Phase 12**: customers can ship sim tests with hand-written or recorded-request fixture data on day one (Phase 12). Phase 13 makes the *editing* path ergonomic — especially "modified handler reads new keys" recovery — and adds the dry-run authoring path. The two phases compose but don't block each other.

## What already exists

- **`_tests/__fixtures__/` directory convention** — Phase 12 (§10.8). Fixture files referenced via `simulate({from_recorded_request_id: ...})` are auto-loaded from sibling `__fixtures__/from-prod-{id}.json`. Hand-written fixtures use `simulate({kv: <object>})` with imported JSON.
- **`rewind export-fixture --request <id>`** — Phase 12. Promotes a recorded request into a sibling-file fixture pair.
- **`dispatchOnce` per-handler savepoint** — exists in `src/js/worker.zig`. Phase 13 adds a `dry_run: bool` flag that always rolls back.
- **`TrackedTxn`** — captures pending writes within a request. Reused by dry-run to harvest the would-have-written kv ops.
- **No live-kv read endpoint** — `/_system/kv/{id}/*` doesn't exist yet.
- **No dry-run endpoint** — `/_system/dry-run/{id}` is new in this phase.
- **No `rewind kv`, `rewind fixture`, `rewind dry-run` CLI** — all new.

## T1–T9 ordered

T1, T7 are worker work. T2–T6 are CLI work. T8–T9 are CLI tools that depend on the worker T7 endpoint. Workstreams interleave; T7 is independent of T1.

### T1. `/_system/kv/{id}/*` admin endpoint

New routes on the worker (or proxied through the existing admin HTTP surface):

```
GET  /_system/kv/{instance_id}/{key}                              → value | 404
GET  /_system/kv/{instance_id}?prefix=...&limit=N&after=<key>     → { entries: [{key, value}], next_cursor }
GET  /_system/kv/{instance_id}/count?prefix=...                   → { count: N }
```

Read-only — no write paths exposed. Pagination matches the existing `/_system/log/*` shape: `limit` + `after` cursor, `next_cursor` in response.

Requires admin auth + `X-Rove-Scope` for cross-tenant access (existing pattern).

### T2. `rewind kv` CLI subcommands

Thin wrappers over T1:

```
rewind kv get <key> [--instance <id>]                  → value on stdout
rewind kv list-prefix <prefix> [--instance <id>] [--limit N] [--json]
rewind kv count <prefix> [--instance <id>]
```

Default `--instance` from `LOOP46_SCOPE` env var. JSON output mode
for agent consumption. (Note: an unrelated operator-debug
`loop46 kv-get` subcommand existed on the V1 binary; the Phase 13
`rewind kv` family is distinct.)

### T3. `rewind fixture` CLI subcommands

Composable fixture-management primitives:

```
rewind fixture from-keys <key>... --from <instance> -o <fixture>
                                                 # pull a curated slice; creates fixture file
rewind fixture add <fixture> <key> --value <v>
rewind fixture add <fixture> <key> --from <instance>
                                                 # fill missing keys from live state
rewind fixture remove <fixture> <key>
rewind fixture edit <fixture>                    # opens $EDITOR
rewind fixture diff <fixture-a> [<fixture-b> | --against <instance>]
                                                 # show drift; structured JSON output for agents
rewind fixture refresh <fixture> [--from <instance>] [--key <k>]
                                                 # re-pull keys currently in the fixture
rewind fixture merge <a> <b> -o <c>              # combine two fixtures
```

All operate on the JSON file format. Fixtures are just `{kv: {<key>: <value>}}` objects (matches `simulate`'s overlay shape).

Implementation: small Zig module, mostly file I/O + HTTP wrappers around T1.

### T4. Runner integration: structured "unresolved read" output

Today (Phase 12), the simulator's miss-policy `fail` returns "unresolved read on K" as part of the bundle. The test runner needs to surface this in a way tools can act on.

- Test failure output includes structured per-test fields: `{"test": "...", "fixture": "_tests/__fixtures__/...", "unresolved_keys": ["customer/42"]}`.
- Human-readable text: "Test foo failed — fixture _tests/__fixtures__/acme.json missing keys: customer/42. Run: rewind fixture add ... or rewind test --auto-fix-from <instance>"

The structured output lets agents and CI parse the failure cleanly.

### T5. `rewind test --auto-fix-from <instance>` flag

Composes T3 + T4: when a sim test fails with unresolved reads, the runner pulls the missing values from the specified instance, writes them back to the fixture, and retries. Loop until either all tests pass or no more progress (e.g., the missing key doesn't exist on the source instance either).

Per-key prompts available with `--interactive` for cases where the agent wants to confirm before mutating fixture files.

### T6. Documentation patterns

Update or add `docs/skills/rewind.md` with fixture-lifecycle patterns:
- "Fix unresolved read" workflow
- "Refresh stale fixtures" workflow
- "Build a new test scenario from production" workflow (compose `rewind export-fixture` + `rewind fixture from-keys` + `rewind fixture add` + the new `rewind fixture from-dry-run`)
- Anti-pattern: don't try to dump whole-instance state. Curate, don't snapshot.

### T7. Worker dry-run dispatch mode (§10.11)

Add `dry_run: bool` flag to `dispatchOnce` in `src/js/worker.zig`. When set:
- The handler runs against real `app.db` reads via the existing `TrackedTxn` (same machinery as live dispatch).
- Writes accumulate in the `TrackedTxn` writeset.
- Outbox enqueues land in the `TrackedTxn` writeset (declarative outbox is just kv writes to `_outbox/`).
- Tape recorder runs as normal, accumulating tape entries in memory.
- After the handler returns: snapshot the writeset + outbox rows + accumulated tape entries.
- **Always rollback the savepoint, regardless of handler success/failure.**
- **Skip the raft propose unconditionally.**
- Return the snapshot as a bundle JSON via `src/tape/bundle.zig`. Include `tape_entries` inline (not as blob refs — dry-run tapes don't get persisted).

New admin endpoint:
```
POST /_system/dry-run/{instance_id}
{ "request": { "method": "...", "host": "...", "path": "...", "headers": {...}, "body": "..." } }
→ 200: <bundle JSON with inline tape_entries>
```

Auth: existing admin auth + scope. Optional `dry_run` rate-limit action in `src/js/limiter.zig`; default sharing the `request` budget for v1.

**Cost shape**: dry-run skips both the SQLite commit fsync and the raft propose (the two dominant costs of a live write). What remains — handler CPU + SQLite reads + in-memory writeset/tape capture — puts dry-run in roughly the cost class of a read-only request. In multi-node setups especially (where raft propose adds several ms of network + fsync latency), this is significant. Operationally: customers can fire many dry-runs to author fixtures without competing meaningfully with live write throughput.

Implementation footprint: ~50 lines in `dispatchOnce` (the conditional behavior at savepoint commit/rollback) + a new route handler that wires the request body in and the bundle out.

### T8. `rewind dry-run` CLI subcommand

New CLI subcommand at `src/loop46/dryrun_cmd.zig`. Wraps T7's endpoint:

```
rewind dry-run \
  --request '{"method":"POST","path":"/api/orders","body":"..."}' \
  [--instance <id>]                          # default from LOOP46_SCOPE
  [--request-file <path>]                    # alternative to --request
  [--json]                                   # default: pretty bundle
→ bundle JSON on stdout
```

Useful for ad-hoc "what does this handler actually do given input X, against current state, without committing?" debugging.

### T9. `rewind fixture from-dry-run` composite

Composes T7 + T3 into a single command:

```
rewind fixture from-dry-run \
  --request '{"method":"POST",...}' \
  --instance <id> \
  -o _tests/__fixtures__/order-creation.json
  [--include-prefix <p>]   # filter which keys end up in the fixture
```

Internally: dry-run the request, parse the bundle's tape entries, extract kv reads matching `--include-prefix` (or all by default), write them as a `{kv: {<key>: <value>}}` fixture file.

This is the killer "build a new test scenario from production behavior" affordance. Single command, end-to-end fixture authoring.

## Endpoint surface (summary)

| Method | Path | Purpose | T-step |
|---|---|---|---|
| `GET` | `/_system/kv/{id}/{key}` | Read single key | T1 |
| `GET` | `/_system/kv/{id}?prefix=...` | Paginated list | T1 |
| `GET` | `/_system/kv/{id}/count?prefix=...` | Count | T1 |
| `POST` | `/_system/dry-run/{id}` | Dry-run dispatch (savepoint rolled back, propose disabled) | T7 |

## Critical files

**New code**:
- `src/loop46/kv_cmd.zig` — `rewind kv` subcommand. T2.
- `src/loop46/fixture_cmd.zig` — `rewind fixture` subcommand family (incl. `from-dry-run`). T3 + T9.
- `src/loop46/dryrun_cmd.zig` — `rewind dry-run` subcommand. T8.

**Extend**:
- `src/js/worker.zig` — add `/_system/kv/{id}/*` routes (T1) and `/_system/dry-run/{id}` route (T7).
- `src/js/dispatcher.zig` (or wherever `dispatchOnce` lives) — `dry_run: bool` flag at savepoint commit/rollback. T7.
- `src/js/limiter.zig` — optional `dry_run` rate-limit action (T7).
- `src/loop46/main.zig` — register `kv`, `fixture`, `dry-run` subcommands.
- `src/test_runner/` (from Phase 12) — structured unresolved-read output (T4); auto-fix-from logic (T5).
- `docs/skills/rewind.md` (Phase 14) — fixture-lifecycle patterns. T6.

## Verification

- `scripts/kv_admin_smoke.py` (T1):
  - Seed `app.db` with known keys, hit `/_system/kv/{id}/{key}` → assert value.
  - Hit `/_system/kv/{id}?prefix=...` with paginated key set → assert pages + cursor advance.
  - Count endpoint matches actual count.
  - Auth: missing token → 401. Wrong scope → 403.
- `scripts/fixture_lifecycle_smoke.sh` (T2-T6):
  - Create instance, seed kv with known keys.
  - `rewind kv get customer/42` → returns value.
  - `rewind fixture from-keys customer/42 customer/43 --from <inst> -o test.json` → assert fixture file written with both keys.
  - `rewind fixture add test.json customer/44 --value '{"name":"Foo"}'` → assert key added.
  - `rewind fixture remove test.json customer/44` → assert key removed.
  - `rewind fixture diff test.json --against <inst>` → modify a value in the instance, assert diff shows the changed key.
  - `rewind fixture refresh test.json --from <inst>` → assert values updated.
  - **Auto-fix workflow**: write a sim test that reads a key not in the fixture, run `rewind test` → assert structured unresolved-read output. Run `rewind test --auto-fix-from <inst>` → assert fixture updated, test passes on retry.
- `scripts/dry_run_smoke.sh` (T7-T9):
  - Deploy a handler that writes to `kv` and queues a `webhook.send`.
  - `POST /_system/dry-run/{id}` with a synthetic request → assert bundle returned with would-have-written kv ops + would-have-enqueued webhook + tape entries inline.
  - Re-read `app.db` after dry-run → assert no writes persisted.
  - Outbox check: confirm no `_outbox/` rows in `app.db` (rolled back).
  - `rewind dry-run --request ... --instance <id>` → assert same bundle structure on stdout.
  - `rewind fixture from-dry-run --request ... -o fixture.json` → assert fixture file written with the kv reads from the bundle. Run a sim test using the fixture → assert green.

## Open questions

1. **Fixture file format**: pretty-printed JSON (diff-friendly) vs JS module (typed, can have helpers). v1 = JSON for simplicity; revisit if customers ask for richer fixture authoring.
2. **`--auto-fix-from` safety**: should it require `--yes` confirmation by default? Or `--interactive` for prompts? Probably `--interactive` is the safe default; `--yes` for non-interactive CI usage.
3. **Bulk operations**: `rewind fixture refresh` defaults to all keys in the fixture. Is there a use case for `--all-fixtures` to refresh every fixture in a project? Probably yes, low cost to add.
4. **Fixture validation**: should the runner validate that fixture files have the right shape (`{kv: {...}}`) before running tests, with a clear error message? Yes — small but ergonomic addition.
5. **Multi-instance fixtures**: a test might want fixtures from multiple instances (e.g., admin instance + customer instance). The fixture file format is one map; should we allow `{kv_by_scope: {acme: {...}, admin: {...}}}`? Defer until a real use case shows up — sim tests today operate within one instance scope at a time.
6. **Dry-run rate-limit budget**: share the `request` budget (simple) or have its own (more permissive, since dry-run skips raft propose + commit fsync — closer to read-cost than write-cost)? Default to sharing for v1; revisit when usage surfaces real shapes — dry-run's lower cost may justify a more generous bucket later.
7. **Dry-run trigger cascades**: real dispatch fires triggers; dry-run inherits this behavior (triggers run, their writes are also captured + rolled back). Worth documenting that dry-run shows the full trigger fan-out, which is useful for "what does this kv write trigger?" exploration but might be surprising.
8. **Dry-run determinism**: two dry-runs of the same request can return different bundles if state changes between them (live state varies). That's by design — dry-run is observation, not deterministic replay. Skill-file callout for agents reasoning about results.
