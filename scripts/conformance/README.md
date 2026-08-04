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
```

The **cheap lane** (`sim`, `replay`) needs no cluster and hangs off `zig build
test`. The **cluster lane** adds `prod`, which needs S3 credentials and port
slots, so it gets a scheduled runner instead (rove#420).

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

1. every entry names the issue that deletes it
2. entries match by **signature**, never by value
3. every entry prints on every run
4. **a stale entry fails the gate** — if an entry matched nothing, either the
   divergence was fixed or the case stopped exercising it, and both need a human

It is currently **empty**, which is not an oversight: one engine produces no
pairs, so there is nothing yet to excuse. Entries are expected with the prod
adapter — wall clock vs. the sim's virtual clock, S3-backed blob bytes the sim
carries inline, node-partitioned request ids.

## Why `selftest.py` exists

The suite runs one engine today, so it cannot catch a real divergence — which
means the comparison, the allowlist, and the stale-entry rule are all
unexercised, and unexercised gate machinery is decoration. `selftest.py` drives
them with synthetic outcomes so the gate is provably able to go red *before* the
engine that would turn it red exists. It runs first in the same build step, and
is not optional.

## Adding a case

1. Point at an app tree (reuse one under `src/replay/testdata/` where possible).
2. Write the world(s). Declare the engines the case should run on — all three
   unless there is a reason, and if there is a reason it belongs in an issue,
   not in a silent omission (rove#419).
3. Run `zig build conformance`. A case that runs on one engine reports
   `unproven`, which is accurate: it has established nothing yet.

## Status

Phase 0 (rove#415) is the runner, the outcome shape, and the allowlist. The
adapters land separately: prod is rove#417, replay is rove#418, and the sim's
missing interaction digest is rove#416. Until a second adapter exists the suite
is wired but not load-bearing, and it says so in its own summary line rather
than reporting a pass.

Tracker: rove#195.
