# The behavior conformance suite

One corpus of behavior cases, run against every engine that executes customer
handlers, failing when two of them disagree. **The corpus is the spec** —
reading `cases/` should be how you learn what the JS worker guarantees.

Three engines run customer handlers, and today each is tested separately
against hand-copied expected values:

| engine | what runs it | how it was tested before |
|---|---|---|
| `sim` | the offline reactor (`rewind sim` / `rewind test`) | `src/replay/testdata/<case>/_tests/*.mjs` |
| `prod` | the worker on a live cluster | `scripts/smoke/*_smoke_v2.py` |
| `replay` | the browser WASM arena | a human replaying a record and hitting the next wall |

All three run today.

`src/replay/testdata/utf8encode` and `scripts/smoke/utf8_encode_smoke_v2.py`
are the shape in miniature: the *same nine expected values*, written out twice
in two languages, each asserting against a literal rather than against the
other engine. Nothing detects drift, and nothing says which behaviors are
covered on which engines. This suite replaces that with one case and a
comparison.

## Running it

```bash
zig build conformance                          # the cheap lane (no cluster)
python3 scripts/conformance/run.py -v          # same, with each outcome printed
python3 scripts/conformance/run.py --list
python3 scripts/conformance/run.py --case utf8encode --engines sim
python3 scripts/conformance/selftest.py        # the gate's own non-vacuity check

# the cluster lane — all three engines
set -a; . ./.env; set +a                       # S3 credentials, mandatory
zig build rewind-worker rewind-cp rewind-front rewind-logs rewind-ops rewind
python3 scripts/conformance/run.py --engines sim,replay,prod
```

The **cheap lane** (`sim`, `replay`) needs no cluster and hangs off `zig build
test`. The **cluster lane** adds `prod`, which needs S3 credentials and port
slots, so it gets a scheduled runner instead (rove#420).

The prod engine brings up **one** `V2Cluster` per process and reuses it for the
whole corpus — bring-up is the most expensive thing here and it is per-process
work, not per-case. Each case gets its **own tenant**, so one case's kv writes
cannot be read by the next.

That tenant-per-case choice runs straight into the platform's own
creation-velocity gate: the CP allows a burst of 10 then one per 30s, with no
env knob, so a full-corpus prod sweep is bounded at roughly half an hour by the
abuse control rather than by the work. The adapter waits it out. Sharing tenants
would dodge the limit and buy a corpus whose results depend on ordering, which
is a worse trade than a slow lane.

The replay engine's prelude is **generated** from this repo's shim sources into
rewind-apps, so it can go stale without anything noticing — and it did once, when
a digest grammar bump left the arena folding a different version than the worker
and the sim. The runner now runs `gen_replay_prelude.py --check` before using
the replay engine and fails with the regeneration command, rather than letting
the staleness surface as a scatter of digest divergences (rove#474).

The replay engine needs **`REWIND_APPS_DIR`** pointing at a rewind-apps
checkout — the replay porcelain (`rtap.mjs`, `request-replay.mjs`,
`qjs_arena_wasm`) lives in that private repo. Without it the engine reports
itself unavailable and the run degrades to sim-only, which is reported as
`unproven` rather than as a pass.

### Running an AUTHORED world on a replay engine

Replay normally re-executes a CAPTURED world: tapes carry the reads the original
run made, and a read the tape lacks is a divergence. Conformance cases are
authored, so `replay_driver.mjs` seeds the world's closed-world kv map into the
host kv **overlay**, which `_arena_host_kv_get` consults *before* the tape.

What that does not buy is the sim's closed-world default: a read of a key the
world does not declare falls through to an empty tape and dies with REPLAY
DIVERGENCE where the sim answers `not_found`. That is an engine property, not a
driver limitation, and it means a case whose handler reads undeclared keys
cannot run on this engine (rove#436) — exactly the "declares its backends"
signal of rove#419.

## What a case looks like

`cases/<name>.json` — a world (or several) plus the app tree it runs against.
Cases point at existing app trees rather than copying them, so the sim corpus
and the conformance corpus cannot drift apart:

```json
{
  "name": "utf8encode",
  "description": "…what this case pins down…",
  "source_dir": "src/replay/testdata/utf8encode",
  "engines": ["sim", "prod", "replay"],
  "worlds": [
    { "label": "encode",
      "world": { "entry": "index.mjs", "activation": "inbound",
                 "request": { "method": "GET", "path": "/" } } }
  ]
}
```

`world` is the ordinary authored-world document —
`docs/architecture/replay-and-sim.md` defines it, `src/replay/world.zig` parses
it, and it rejects unknown keys, so a typo fails loudly instead of silently
running a different world. A case may set `compare_headers` to widen the
compared header set beyond the default.

## What is compared

The normalized outcome is not invented here: the sim already emits a flattened
bundle, and that bundle *is* the shape. `outcome.py` canonicalizes it into
`status`, `headers`, `body`, `body_sha256`, `disposition`, `writes`, `effects`,
`digest`, `error`, `ok`.

Two rules carry the weight:

- **A field is compared only across engines that supply it.** A field exactly
  one engine produces is reported `unverified`, never agreement. This is what
  stops the suite reading green while proving nothing.
- **Absent ≠ null.** An engine that *cannot* produce a field says so; an engine
  that produces an empty value says that instead. Collapsing the two lets a
  capture gap disguise itself as a match.

Comparison is **pairwise**, not against a designated reference, so a
disagreement names which pair disagrees. That is what makes a three-way run
localize a fault: sim+prod agreeing while replay differs points at the shell;
replay+prod agreeing while sim differs points at the sim's recorders.

## The allowlist

`allowlist.py` holds the reviewed set of legitimate engine differences. Four
rules, each because an allowlist without it becomes a junk drawer:

1. every entry is **owned** (names the issue that deletes it) or **by-design**
   (permanent, with the rationale) — never neither, never both; construction
   rejects it
2. entries match by **signature**, never by value
3. every entry prints on every run
4. **a stale entry fails the gate** — if an entry matched nothing *and the
   engines it concerns both ran*, either the divergence was fixed or the case
   stopped exercising it, and both need a human

Rule 4's engine clause matters: an entry about sim↔replay is not stale on a box
with no replay porcelain. Without it the gate would fail because an engine was
missing, which is the opposite of what the rule is for.

One entry ships today, and it is by-design: the replay engine has no console
recorder, because live console output is already on the LogRecord
(`gen_replay_prelude.py` excludes `console.js`). The interaction digest does not
fold console either, so the engines still agree on the sequence that matters.
More are expected with the prod adapter — wall clock vs. the sim's virtual
clock, S3-backed blob bytes the sim carries inline, node-partitioned request
ids.

## Why `selftest.py` exists

The corpus exercises the machinery only where two engines happen to disagree,
which is a thin and shifting slice — and on a box without the replay porcelain
it is no slice at all. `selftest.py` drives the comparison, the allowlist, and
the stale rule with synthetic outcomes, so the gate is provably able to go red
independently of which engines are available. It runs first in the same build
step and is not optional.

It has caught two of its own kind already: the rule that ABSENT never compares
as agreement, and the rule that an entry whose engines did not run is not
stale.

## Adding a case

1. Point at an app tree (reuse one under `src/replay/testdata/` where possible).
2. Write the world(s). Declare the engines the case should run on — all three
   unless there is a reason, and if there is a reason it belongs in an issue,
   not in a silent omission (rove#419).
3. Run `zig build conformance`. A case that runs on one engine reports
   `unproven`, which is accurate: it has established nothing yet. So does a case
   where an engine produced **no outcome** — two failed runs both report
   `ok: false` and would otherwise compare equal, which is agreement between a
   real result and a crash.

A naive `GET /` world is not enough for most of the corpus: cases needing
packages, a threaded ctx, or a non-inbound activation fail on *both* engines and
report `unproven`. That is the runner telling you the world is wrong, not the
engines agreeing.

## What each engine cannot report

Left ABSENT rather than filled with a plausible value, so the runner reports
them `unverified` instead of manufacturing agreement:

| field | engine | why |
|---|---|---|
| `headers` | replay | the parked outcome carries only a status (rove#437) |
| `error` | replay | a throwing handler parks nothing, so the message is unrecoverable |
| `effects` | prod | the record carries tapes (the reads a run made), not the ordered read/write/effect log the offline engines build |
| `writes` | prod | the record has no writeset, and there is no read-only kv listing door to reconstruct one (rove#83) |
| `disposition` | prod | not exposed on the record |
| `body_sha256` | sim | its bundle body has been through Zig's JSON re-serialization, so hashing it would test that round-trip rather than the engine |

`digest` used to be on this list. Since rove#416 both offline engines fold one,
and they agree — which is the strongest assertion the suite makes, because it
compares the SEQUENCE of reads and effects rather than the response two engines
could reach down different paths.

## Status

Phase 0 (rove#415) is the runner, the outcome shape, and the allowlist;
rove#418 added the replay adapter; rove#416 gave the sim an interaction digest,
so the two offline engines now agree on the interaction SEQUENCE and not merely
the response. prod is rove#417.

### Findings

A full sweep of `src/replay/testdata/` (57 cases) across sim and replay: **23
agree on all 7 comparable fields including the digest**, 22 are `unproven` (the
probe world is inadequate — packages, ctx, or a non-inbound activation), and 12
diverge. Every divergence is filed rather than worked around:

| issue | what | cases |
|---|---|---|
| rove#436 | the replay epilogue has no authored-world mode | `instancefold`, `platformadmin`, `roottoken`, `requestsurface`, `argvalidation` |
| rove#442 | harness bookkeeping folded into replay's effect log + digest | `concurrent`, `concurrentctx`, `fetchrecorder`, `ssrfgate`, `nexttarget` |
| rove#452 | the WASM arena has no CPU budget — a runaway handler hangs | `cpubudget` |
| rove#453 | module specifiers looked up verbatim, no `../` clamping | `importclamp` |
| rove#250 | request surface: `tag()` inert, activation bag null, no corr/session | `requestsurface` |
| rove#437 | no response headers in the parked outcome | (all — `headers` is unverified) |

Two nearby symptoms were *driver* bugs, fixed here rather than filed: the
body-read and ip-read markers were gated on the world declaring a body/ip, which
made a bodyless world throw where prod returns `""` and `request.ip` throw where
prod returns null. On a capture an absent marker means "the original run never
read this"; an authored world has no original run.

Tracker: rove#195.
