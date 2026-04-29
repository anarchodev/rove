# Phase 14 — AI agent surface (CLI + skill file + scoped tokens)

Implements [`docs/PLAN.md`](PLAN.md) §10.10.

**Scope**: make Loop46 a first-class target for AI agents (Claude Code, Codex, Cursor, future runtimes) without building an MCP protocol server in v1. The local-agent path is fully served by:

1. A skill file teaching the workflow.
2. A polished CLI with consistent JSON output.
3. Scoped tokens for security-isolated agent integrations.

**Hosted MCP at `mcp.loop46.me` is deferred** until concrete remote-agent demand surfaces (third-party integrations, cloud agents that don't run on the customer's machine). Until then, no MCP protocol code in the repo.

**Why this is the right v1**: agents in the customer's working tree (the dominant case) already have shell access, can read `--help`, can parse JSON. The MCP wins (typed schemas, server-side rate limiting, token isolation, cross-machine access) only matter for remote scenarios. Token isolation is worth building anyway as an independent security primitive — it's not MCP-specific.

## What already exists (after Phase 12 + 13)

- **CLI subcommands** from earlier phases: `loop46 worker`, `loop46 dev`, `loop46 deploy`, `loop46 logs` (existing); `loop46 simulate`, `loop46 test`, `loop46 export-fixture` (Phase 12); `loop46 kv`, `loop46 fixture` (Phase 13).
- **Bearer-token auth** via `Authorization: Bearer <hex>` and session cookies (`src/tenant/root.zig:584-794`).
- **No skill file** — greenfield.
- **No scoped tokens** — only root tokens and sessions exist.
- **No `loop46 doctor`** — agents currently have no quick env-readiness check.
- **No `--json` flag audit** — some subcommands have it, others don't.

## T1–T5 ordered

### T1. `--json` output mode audit + standardization

Walk every CLI subcommand. Confirm or add `--json` flag that emits a structured result (single JSON object per invocation, parseable by any agent or shell pipeline).

Define a standard envelope:
```json
{
  "ok": true | false,
  "data": { ... },
  "error": { "code": "...", "message": "..." } | null
}
```

Subcommands that natively emit lists (e.g., `loop46 logs`, `loop46 fixture diff`) include them in `data.entries` or similar. Non-zero exit code on `ok: false`.

This is mostly small per-command edits in `src/loop46/*` and `src/files_cli/`.

### T2. `loop46 doctor` — environment readiness check

New subcommand. Probes the environment and reports a structured readiness report:

```
loop46 doctor [--json]

Checks:
- Working tree detected (handler.mjs, _tests/, etc.)
- LOOP46_TOKEN env var set + non-empty
- LOOP46_SCOPE env var set
- LOOP46_HOST reachable (HTTP HEAD to admin endpoint)
- Token scope verifiable (calls /_system/whoami or equivalent)
- `loop46 worker` binary version matches deployed version (optional)
```

Output:
- Human-readable: green check / red X per item with hints to fix.
- JSON: structured `{checks: [{name, ok, hint}], all_ok: bool}`.

First thing an agent runs in a session. Surfaces config issues before tools start failing in confusing ways.

### T3. Scoped tokens

New token type alongside existing root tokens (`root_token/{hash}`) and sessions (`session/{hash}`).

**Storage**: `scoped_token/{sha256(token_hex)}` in root.db (likely; tokens may span instances). Value: serialized scope record:

```json
{
  "label": "ci-deploy-bot",
  "instances": ["acme", "acme-staging"] | "*",
  "capabilities": ["read", "simulate", "deploy", "fixture", "kv", "logs"],
  "created_at": <iso>,
  "expires_at": <iso> | null,
  "last_used_at": <iso>
}
```

**Capability vocabulary** (initial set; extensible):
- `read` — read manifests, list deployments, read logs.
- `simulate` — call `/_system/simulate/{id}` (server-side simulation).
- `deploy` — create new deployments.
- `fixture` — read kv via `/_system/kv/{id}/*` (scoped to fixture authoring).
- `kv` — read kv (overlap with `fixture`; either grants read; reserved for future read+write split if needed).
- `logs` — read log records.

**Wire format**: `Authorization: Bearer loop46_scoped_<hex>` (or just keep `Bearer <hex>` if simpler, with the hex string distinguishable by length / prefix in the lookup).

**Auth flow**: each request validates token capabilities against the operation. E.g., `POST /v1/instances/<id>/deployments` requires `deploy` capability + `<id>` in `instances`.

New functions in `src/tenant/root.zig`: `installScopedToken(scope_record) → token_hex`, `authenticateScoped(token_hex) → ?ScopedAuth`. Analogous to existing `installRootToken` / `authenticate`.

### T4. `/_system/scoped_tokens` admin routes

CRUD for scoped tokens (admin-only, requires root token or admin session):

```
POST   /_system/scoped_tokens                     → mint (returns plaintext once)
GET    /_system/scoped_tokens                     → list (metadata only, never plaintext)
DELETE /_system/scoped_tokens/{hash}              → revoke
PATCH  /_system/scoped_tokens/{hash}              → modify capabilities/instances/expires_at
```

Plus CLI:
```
loop46 mint-token --label <l> --capabilities <c1,c2,...> --instances <i1,i2,...> [--expires <duration>]
                                                  → emits token_hex once on stdout
loop46 list-tokens [--json]
loop46 revoke-token <hash>
```

### T5. Skill file

New file at `docs/skills/loop46.md` (final path TBD when Anthropic skill conventions stabilize; for now committed to the repo, published on the Loop46 docs site for agent discovery).

Sections:
- **Overview**: what Loop46 is in one paragraph from an agent's POV.
- **Workflow**: edit handler → `loop46 test` → fix fixtures via `loop46 fixture *` → `loop46 deploy`. Concrete examples.
- **Tool catalog**: every CLI subcommand with a one-line purpose, expected args, and a JSON-output example.
- **Auth setup**: `LOOP46_TOKEN`, `LOOP46_SCOPE`, `LOOP46_HOST`. How to mint a scoped token.
- **Common patterns**:
  - "Fix unresolved-read failure in a sim test" — invoke `loop46 fixture add ... --from <instance>`.
  - "Pull a real production scenario as a test" — `loop46 export-fixture --request <id>`.
  - "Build a fixture from scratch" — `loop46 fixture from-keys customer/42 ... --from <instance>`.
  - "Deploy a candidate" — push, run `loop46 test`, deploy.
  - "Investigate a failure" — `loop46 logs ...`, identify failing request, export fixture, fix, redeploy.
- **Gotchas**:
  - Sim tests run locally — the agent needs the working tree.
  - Tests are stripped from production manifests at deploy time (see PLAN.md §10.8).
  - `simulate(...)` defaults to `mode: isolated` for sim tests; use `mode: strict` for replay-against-recording.
  - Snapshots commit alongside test code; `--update-snapshots` regenerates.
  - Outbox effects don't actually fire in simulation — assert on the bundle's would-have-enqueued list.
  - **`loop46 dry-run` is cheap** (skips raft propose + commit fsync; cost class is read-only-equivalent). Use it freely for fixture authoring; no need to ration calls.
  - Dry-run results are non-deterministic across calls (live state varies between runs). If you want reproducibility, capture once into a fixture and run sim tests against the fixture instead.

The skill file should be small enough for Claude to load fully (~500-1500 lines), structured enough to be navigable, and updated as the CLI evolves.

## Critical files

**New code**:
- `src/loop46/doctor_cmd.zig` — `loop46 doctor`. T2.
- `src/loop46/token_cmd.zig` — `mint-token`, `list-tokens`, `revoke-token`. T3 + T4.
- `docs/skills/loop46.md` — the skill file. T5.

**Extend**:
- `src/loop46/main.zig` — register new subcommands.
- `src/loop46/*` and `src/files_cli/*` — `--json` output mode audit. T1.
- `src/tenant/root.zig` — scoped-token install/authenticate functions. T3.
- `src/js/worker.zig` — `/_system/scoped_tokens` admin routes (T4); per-request capability gate when a scoped token authenticates.
- `web/admin/` — "Tokens" tab in dashboard for human token management.

## Verification

- `scripts/agent_surface_smoke.sh`:
  - **JSON output**: invoke each CLI subcommand with `--json`, assert each returns the standard envelope shape.
  - **Doctor**: with no env vars set, `loop46 doctor --json` reports failures correctly. With a valid setup, all checks pass.
  - **Mint scoped token**: `loop46 mint-token --capabilities deploy,test --instances acme` → emits a token. List shows it. Use it for a deploy → succeeds. Use it for a `simulate` call → 403 (capability not granted).
  - **Revoke**: revoke the token, retry the deploy → 401.
  - **Capability gate**: scoped token with only `read` cannot deploy or fixture.
- Manual: configure Claude Code with the skill file in a Loop46 source tree → ask "find the most recent failing request and propose a fix" → confirm the agent reads the skill, runs `loop46 logs`, finds the failure, runs `loop46 export-fixture`, edits the handler, runs `loop46 test`, iterates.
- Inline Zig tests for scoped token install/authenticate roundtrip + capability validation.

## Open questions

1. **Skill file location**: `docs/skills/loop46.md` in the repo plus published at `loop46.me/skills/`? Bundled with the CLI binary as a `loop46 skill` subcommand? Anthropic's skill convention is still settling; for v1, just commit it to the repo and document it on the website.
2. **Token format prefix**: `loop46_scoped_<hex>` distinguishes scoped tokens from root tokens visually; or just hex with the kind stored at the lookup site. Prefix is more grep-friendly but couples format to logic. Probably prefix, since git scanners (GitHub secret scanning) match on prefix patterns.
3. **Capability hierarchy**: `read` should imply log read, kv read, manifest read. Should it also imply `fixture`? Or are they independent? Likely `read` is a base, others are additive. Document explicit relationships.
4. **Audit log for token use**: should every scoped-token-authenticated request log to a security-audit channel? Useful for "what did this CI bot's token do this week?" Defer until usage shows demand.
5. **Token expiration**: support `expires_at` from day one (yes, planned). What's the default? No expiration (caller must explicitly request one)? Or default 30 days? Probably no default — explicit is safer.
6. **Hosted MCP timeline**: when do we revisit? Concrete signals — third-party integration request, customer asking "can my Cursor instance running on a friend's laptop manage my account," remote-CI vendor wanting to wrap Loop46. None imminent; revisit at the 6-month mark with usage data.
