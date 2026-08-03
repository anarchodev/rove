# Smoke suite

End-to-end tests against real binaries: each script spawns its own cluster
(`rewind-cp` + front + N workers), drives it over HTTP, and tears it down.
They are the only tests that exercise raft, S3, the front door and the JS
dispatcher together.

## Running them

```bash
zig build                         # the h2 example servers a few smokes drive
zig build rewind-worker rewind-cp rewind-front rewind-logs rewind-ops
zig build rewind                  # the customer CLI — five smokes drive it
set -a; . ./.env; set +a          # S3 credentials — V2 has no fs blob backend
export REWIND_APPS_DIR=~/src/rewind-apps    # only for smokes that deploy first-party apps

scripts/smoke/run_all.py --jobs 8              # the whole suite, parallel
scripts/smoke/run_all.py                       # the whole suite, serially
scripts/smoke/run_all.py --filter deploy       # substring match on the name
scripts/smoke/run_all.py --list                # what would run ([serial] = tail)
python3 scripts/smoke/ctl_smoke_v2.py          # one smoke directly
```

`--jobs N` runs a longest-first pool of N concurrent smokes, then a small
SERIAL tail (election soaks and other members whose timing assertions
co-tenant CPU load can skew) one at a time on a quiet box. The runner leases
port slots through the same locks a standalone smoke takes, so a hand-run
smoke beside a running suite still gets its own range.

Ports come from `smoke_ports.py`, the suite's one port authority: every smoke
process owns a disjoint slot (`flock`ed standalone; assigned via
`SMOKE_PORT_SLOT` by the runner) and draws blocks from it, so concurrent
smokes — including a hand-run one beside a running suite — cannot collide.
Never hardcode a port in a smoke; take it from the harness
(`V2Cluster` allocates its own) or `smoke_ports.alloc()`.

`run_all.py` preflights those binaries and refuses to start without them —
a missing build otherwise shows up as a scatter of unrelated-looking failures.

## Keeping it honest

The suite rotted badly once (rove#355): nothing ran it, so smokes broke one at
a time as unrelated changes landed, and the breakage was invisible for weeks.
Every failure had the same shape — a legitimate change elsewhere, and a smoke
nobody re-ran:

| when | change | what it broke |
|---|---|---|
| 2026-06-17 | per-file workspace deploy protocol | smokes POSTing the old mega-bundle |
| 2026-06-28 | `web/` extracted to the rewind-apps repo | smokes reading `web/…` in-repo |
| 2026-07-05 | `name:` → `on:` resume-export key | smokes passing the retired spelling |
| 2026-07-28 | 12 ambient libs became `@rewind/*` packages | fixtures using `oidc.` / `schedule.` / … as globals |
| — | `v2-bundle` → `v2-snapshot`; pause/resume dropped when the dump went non-quiescing | a door that 404s |
| — | plan tiers `email_*` → `outbound_*`; `email.send`'s `key` → `apiKey` | `None` where a number was expected |
| — | the cert frame gained a leading version byte | an unpacker returning None, read as "certs are broken" |
| — | `stream.write` became lossless (soft cap = back-pressure, hard cap throws) | a smoke that required drops, i.e. required data loss |
| — | provision answers 200 + a body, not 204 | a guard that bailed out after a SUCCESSFUL provision |
| — | the storage incarnation (#357) | joiners opening a legacy-keyed store and reading empty |

None of these were bad changes. The lesson is narrower and duller: **a test
suite nobody runs is not coverage, it is the appearance of coverage** — and it
is worse than no suite, because it is counted.

### How it runs now (nobody has to remember)

Two standing hooks (rove#363 class 10):

- **Nightly**: `nightly.sh`, fired by the `rove-smoke-nightly.timer` systemd
  user unit (`systemd/` here has the units + install steps). It builds
  `origin/main` in a dedicated checkout (`~/src/rove-nightly`), runs the full
  suite with `--jobs`, diffs against the committed baseline, and comments on
  the standing issue **rove#373** when something is newly broken — or when
  the nightly itself could not run. Silence only ever means "nothing new".
- **Deploy gate**: `scripts/ops/build.sh` (which every deploy drives) runs
  the full suite against the ReleaseFast binaries it just built and refuses
  to ship on a newly-broken smoke. `ROVE_SKIP_SMOKES=1` skips it — a
  conscious act; a missing `.env` is a hard stop, not a silent skip.

Self-test after touching either hook: `SMOKE_FILTER=ctl_smoke
scripts/smoke/nightly.sh` runs the whole pipeline against one fast smoke.

Running it once found three live production bugs, none of which any unit test
could reach: an unconditional worker panic on every over-threshold inbound
body, a `blob.url` that signed keys nothing had written, and a CP that
delivered the storage incarnation only at provision (so a move, a reconciler
grow, or a node rejoin silently opened the wrong store).

So: run `run_all.py` before you claim a change is safe, and after anything that
touches the deploy protocol, a global/shim surface, the front door, or the
harness itself.

### Baselines

```bash
scripts/smoke/run_all.py --json today.json                  # record
scripts/smoke/run_all.py --json now.json --baseline today.json   # compare
```

`--baseline` reports *newly broken*, *newly fixed* and *still broken*, and
exits non-zero **only on a new failure**. That is deliberate: with a suite this
size there will usually be something red, and the question worth answering is
"did I break something?", not "is everything green?". A long-standing failure is
a backlog item; a new one is a regression, and only the second should block you.

`smoke-baseline.json` in this directory is the last recorded full run:
**141/143 in 10m at `--jobs 8`** (26m of member-time). The two reds are
product defects, not stale fixtures: rove#361 (`tls_large_body`, concurrent
large static downloads abort mid-stream — intermittent, ~1 in 2) and rove#377
(`raft_soak_v2`'s spurious elections under load on btrfs — reproduces at the
PROD `REWIND_RAFT_TICK_MS=10` as well as the 1ms default, so it is a live
finding rather than the smoke measuring a config nobody runs). Refresh the
baseline when you fix something, so the next person's diff is meaningful.

Where the 10m goes: a ~2.5m parallel pool (bounded by its longest member,
`churn_kv_convergence` at ~140s) plus a ~7.3m SERIAL tail. **The tail is the
floor** — halving the pool again would buy almost nothing. Cutting further
means cutting what the soaks prove (`raft_soak_prod` honours
`REWIND_SOAK_ROUNDS`, default 6), which is a deliberate trade, not a tidy-up.

Three members are INTERMITTENT, so a run where one flips will read as a
regression or a fix when it is neither — check the issue before believing
either: rove#361 (`tls_large_body`, ~1 in 2), rove#362 (`dispatch_gate`,
~2 in 3 — green in the baseline run), and `s3_blob_smoke_v2` (transient
object-store 503s under suite load; usually reported FLKY, not fail). A
`"flaky"` status in the JSON means failed in the pool, passed on the
automatic solo retry — counted as passing by `--baseline`, printed
distinctly so it stays visible.

`leader_failover`'s ~40% flake (rove#374) is FIXED — it was a test bug, not
a product defect: `raft_leadership_acquisitions_total` is a NODE-WIDE counter
summed over every raft group, and the smoke asserted a per-group property
with it while the victim usually led two groups.

A smoke that cannot run in the current environment (no rewind-apps checkout,
say) prints `SKIP — <why>` and exits **77** (`run_all.SKIP_RC`); the runner
reports it as `skip`, never `pass`. A skip is invisible coverage, and the
distinction matters most under `--baseline`: a member that passed in the
baseline but only skipped now gets a loud NEWLY SKIPPED warning — the run
proves less than the baseline did, usually because the environment is
stripped, and a green summary must not paper over that.

## Writing one

- Copy the shape of `ctl_smoke_v2.py` — it is the canonical example.
- Use `V2Cluster.spawn(...)` from `smoke_lib_v2.py`; `v2_topology.py` holds the
  per-binary spawn primitives.
- Read first-party app sources through `APPS_DIR`, never a repo-relative
  `web/…` path (that directory now lives in rewind-apps).
- Check the status of every call you depend on, including setup. A smoke whose
  *setup* fails silently looks like the thing under test is broken — that cost
  a real debugging cycle in rove#355.
- Writes are leader-gated: a follower answers 421/503, so retry across nodes
  rather than assuming node 0 leads.
- If a script is a reproduction for an open bug and is *meant* to be red, add it
  to `EXCLUDED` in `run_all.py` with the issue number. A permanently-red member
  teaches people to ignore the report. When the bug is fixed, graduate the
  script INTO the suite (rename `*_repro.py` → `*_smoke.py`) — an excluded
  green repro is a regression gate nobody runs.
- If a smoke needs something the environment may not have (a rewind-apps
  checkout, a credential), print `SKIP — <why>` and exit 77 — never 0. Exit 0
  records a pass for a smoke that never ran.
- A smoke that legitimately runs long (the raft soak: 6 kill/wipe/heal rounds)
  needs an entry in `TIMEOUTS`, or it is reported HUNG and reads as a product
  hang rather than a slow test.
- Don't build while the suite runs. A saturated CPU trips raft election
  timeouts, and a spurious leader step-down looks exactly like a real one.
- Never hand-build a tenant's S3 key. `V2Cluster.incarnation()` reads the real
  segment from the product; guessing the layout is how several of these smokes
  started 404ing.
- Simulating the CP means sending what the CP sends. Use
  `smoke_lib_v2.attach_bundle` rather than a private copy of the attach
  contract — four smokes each had their own, so a new header landed in none.
