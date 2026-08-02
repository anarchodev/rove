# Smoke suite

End-to-end tests against real binaries: each script spawns its own cluster
(`rewind-cp` + front + N workers), drives it over HTTP, and tears it down.
They are the only tests that exercise raft, S3, the front door and the JS
dispatcher together.

## Running them

```bash
zig build                         # the h2 example servers a few smokes drive
zig build rewind-worker rewind-cp rewind-front rewind-logs rewind-ops
set -a; . ./.env; set +a          # S3 credentials — V2 has no fs blob backend
export REWIND_APPS_DIR=~/src/rewind-apps    # only for smokes that deploy first-party apps

scripts/smoke/run_all.py                       # the whole suite, serially
scripts/smoke/run_all.py --filter deploy       # substring match on the name
scripts/smoke/run_all.py --list                # what would run
python3 scripts/smoke/ctl_smoke_v2.py          # one smoke directly
```

They bind fixed ports, so **they run serially and only one suite at a time** —
two runs (or a run alongside a hand-started smoke) collide with `EADDRINUSE`.
The full suite takes about an hour.

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
**140/142 in 33m**, the two reds being rove#361 (concurrent large static
downloads abort mid-stream) and rove#362 (a leader that idles past the
hibernation window spuriously steps down). Both are product defects, not
stale fixtures. Refresh the baseline when you fix something, so the next
person's diff is meaningful.

rove#362 is INTERMITTENT (~2 runs in 3), so a run where it flips will read as
a regression or a fix when it is neither — check it against the issue before
believing either.

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
  teaches people to ignore the report.
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
