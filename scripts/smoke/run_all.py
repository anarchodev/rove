#!/usr/bin/env python3
"""Run the smoke suite and report what actually passes.

Nothing ran these before, so they rotted silently: four were found dead by
accident in a single session (rove#355), each broken for weeks by a change
elsewhere that nobody connected to them. A suite nobody runs is not coverage,
it is the appearance of coverage — which is worse, because it is counted.

Smokes spawn real clusters but own disjoint port slots (smoke_ports.py), so
they can run CONCURRENTLY: `--jobs N` runs a longest-first pool, with a small
SERIAL set of timing-sensitive members (election soaks) run alone afterwards.
Progress prints per smoke either way.

    scripts/smoke/run_all.py                  # everything
    scripts/smoke/run_all.py --jobs 8         # parallel pool + serial tail
    scripts/smoke/run_all.py --filter deploy  # substring match
    scripts/smoke/run_all.py --list           # just names
    scripts/smoke/run_all.py --baseline b.json  # compare against a prior run

`--baseline` is the point of the JSON output: a suite with known-failing
members is only useful if you can see what CHANGED. New failures are what
matter; a long-standing one is a backlog item, not a regression.

Needs S3 env (`set -a; . ./.env; set +a`). Smokes needing a rewind-apps
checkout read REWIND_APPS_DIR and skip themselves when it is absent.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import queue
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import smoke_quiet  # noqa: E402
import smoke_reap  # noqa: E402

HERE = Path(__file__).resolve().parent

sys.path.insert(0, str(HERE))
from smoke_ports import acquire_slots  # noqa: E402

# Not smokes: shared harness modules, and helpers imported by them.
NOT_SMOKES = {"smoke_lib.py", "smoke_lib_v2.py", "v2_topology.py", "run_all.py",
              "smoke_ports.py", "smoke_quiet.py", "smoke_reap.py"}

# Scripts that are deliberately not part of the suite. Each needs a REASON —
# "it fails" is not one; that is what the report is for. (A fixed repro
# graduates INTO the suite instead: front_write_reaim_repro.py became
# front_write_reaim_smoke.py when rove#353's leader-hint re-aim fix landed.)
EXCLUDED = {
    # Diagnostic capture harness, not a gate: loops the genesis A–E flow to
    # print a Finding-1-vs-Finding-3 verdict on the leg-E failover flake,
    # which the wake-to-elect fix closed. genesis_smoke_v2 gates the same
    # flow once; run this BY HAND if that flake ever recurs.
    "genesis_capture.py": "diagnostic harness for the fixed leg-E failover "
                          "flake — genesis_smoke_v2 is the gate",
    # The browser-agent surface is unfinished and unsupported, and the work is
    # parked — so nothing should be gating on it. Excluded for THAT, not for
    # failing: it has been red on main while the baseline claimed pass, which
    # made it read as a fresh regression against whatever branch was under
    # test and cost two unrelated branches a diagnosis cycle each (rove#880).
    # The smoke and web/agent-sample are intact; if the feature is picked back
    # up, delete this line and it graduates straight back into the suite.
    "agent_smoke_v2.py": "browser-agent surface is unfinished/unsupported and "
                         "the work is parked — nothing should gate on it",
}

# Build steps a caller must invoke to produce what the suite spawns. Exported
# (`--build-steps`) so a builder — the nightly — asks this file instead of
# keeping its own copy. The two lists drifted once and cost six nights of
# coverage: the nightly built five of them, `run_all` had grown a dependency on
# the `rewind` CLI too, and every run exited before a single smoke (rove#373).
BUILD_STEPS = ["rewind-worker", "rewind-cp", "rewind-front", "rewind-logs",
               "rewind-ops", "rewind"]

# Produced by the DEFAULT `zig build` install step. Their same-named steps RUN
# the servers rather than building them, so a builder that passes these to
# `zig build` hangs forever holding a listening socket — which is exactly what
# happened the first time this list was exported as one flat set.
EXAMPLE_BINARIES = ["h2-echo-server", "echo-server", "ws-echo"]

# What must EXIST before any smoke starts.
REQUIRED_BINARIES = BUILD_STEPS + EXAMPLE_BINARIES

# A smoke that cannot run in this environment (e.g. no rewind-apps checkout)
# exits with THIS code after printing why. The runner reports it as "skip" —
# NOT as a pass: a baseline recorded in a stripped environment must not
# silently bless members that never ran.
SKIP_RC = 77
# The suite could not RUN — missing binaries, no env, nothing to execute. A
# caller must not report this as "newly broken vs baseline": it is the absence
# of a measurement, not the result of one, and conflating them is how a
# setup failure spends six nights impersonating a product regression.
CANNOT_RUN_RC = 2
# A timing-sensitive smoke that saw its failure while the box was stalled.
# Distinct from a fail: the assertion did not hold, but the run cannot say
# whether the code or the machine is responsible, so it must not be recorded
# as a regression (rove#655).
INCONCLUSIVE_RC = 78

# Known-INTERMITTENT members that stay in the suite so the report keeps
# counting them. All are genuine product defects, not stale fixtures — which
# is why they stay in rather than being excluded. Each moves between pass and
# fail across runs, so `--baseline` will call one a regression (or a fix) on
# the run where it flips: check the issue before believing either direction.
#   dispatch_gate_smoke_v2.py  — rove#362, a leader that idles past the
#                                hibernation window spuriously steps down
#                                (~2 of 3).
#   tls_large_body_smoke.py    — rove#361, concurrent large static downloads
#                                abort mid-stream (sequential ones are fine).
#   raft_soak_v2.py            — rove#377, spurious elections under load on
#                                btrfs. Reproduces at the PROD tick=10 too
#                                (1-2 per 90s run), not just the 1ms default
#                                (3-4), so neither the tick flip nor #384's
#                                off-thread fsync clears it here. The fsync
#                                tail is no longer the coupling — measure
#                                before blaming it (rove#377).

# Members that run ALONE, after the parallel pool drains. These assert timing
# that co-tenant CPU load can skew — an election-timeout soak or a
# hibernation-window race read under load produces flakes that look exactly
# like product bugs, and a flaky red trains people to ignore the report.
# Membership is empirical: a member that proves load-tolerant should move to
# the pool (the tail bounds the parallel suite's floor).
# The membership list itself lives in `smoke_quiet`, because it is now
# consulted from two places: here, for the serial tail, and by `smoke_lib_v2`
# so a HAND-RUN member takes the machine-wide exclusive lock too. The tail
# alone only ever meant "alone within this run" — a sibling session's suite
# was invisible to it, which is how a soak trips a spurious election on an
# idle-looking box (rove#655).
SERIAL = smoke_quiet.QUIET_EXCLUSIVE

# Smokes that legitimately run longer than the default budget. Without an
# entry here a slow-but-healthy smoke is reported HUNG, which reads as a
# product hang and is the fastest way to teach people to distrust the report.
TIMEOUTS = {
    "raft_soak_prod.py": 1800,      # 6 rounds of kill/wipe/heal by design
}

BASELINE_PATH = HERE / "smoke-baseline.json"


def discover(filter_str: str | None) -> list[Path]:
    out = []
    for p in sorted(HERE.glob("*.py")):
        if p.name in NOT_SMOKES or p.name in EXCLUDED:
            continue
        if filter_str and filter_str not in p.name:
            continue
        out.append(p)
    return out


def baseline_seconds() -> dict[str, float]:
    """Per-smoke durations from the checked-in baseline, for longest-first
    scheduling. Unknown smokes get a middling default so they start early
    enough not to straggle."""
    try:
        base = json.loads(BASELINE_PATH.read_text())
        return {n: r.get("seconds", 60.0) for n, r in base.items()}
    except Exception:
        return {}


def run_one(p: Path, budget: int, log_dir: Path, slot: int | None) -> dict:
    log_path = log_dir / f"{p.stem}.log"
    env = dict(os.environ)
    if slot is not None:
        env["SMOKE_PORT_SLOT"] = str(slot)
    t0 = time.time()
    with open(log_path, "w") as lf:
        # Own process group, so a timeout can kill the smoke AND the
        # cluster it spawned. Killing only the script leaves its nodes
        # holding their ports for every later smoke in the same slot.
        proc = subprocess.Popen([sys.executable, str(p)], stdout=lf,
                                stderr=subprocess.STDOUT, env=env,
                                start_new_session=True)
        try:
            rc = proc.wait(timeout=budget)
            status = ("pass" if rc == 0
                      else "skip" if rc == SKIP_RC
                      else "inconclusive" if rc == INCONCLUSIVE_RC else "fail")
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
            rc, status = -1, "timeout"
    return {"status": status, "rc": rc, "seconds": round(time.time() - t0, 1)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--filter", default=None, help="substring match on the script name")
    ap.add_argument("--list", action="store_true", help="list what would run, then exit")
    ap.add_argument("--build-steps", action="store_true",
                    help="print the `zig build` STEPS that produce what the suite "
                         "spawns (the examples come from the default install step, "
                         "and their same-named steps RUN rather than build)")
    ap.add_argument("--required-binaries", action="store_true",
                    help="print the binaries that must exist before a smoke starts")
    ap.add_argument("--jobs", type=int, default=1,
                    help="concurrent smokes (SERIAL members always run alone)")
    ap.add_argument("--timeout", type=int, default=420,
                    help="per-smoke seconds (TIMEOUTS overrides it per smoke)")
    ap.add_argument("--logs", default=None, help="directory for per-smoke logs")
    ap.add_argument("--json", default=None, help="write a machine-readable summary here")
    ap.add_argument("--baseline", default=None, help="compare against a prior --json summary")
    ap.add_argument("--no-queue", action="store_true",
                    help="fail immediately if another suite holds the box "
                         "instead of queueing behind it")
    args = ap.parse_args()

    # Answered before any environment check: a BUILD step asks this, and it has
    # nothing built and no S3 env yet by definition.
    if args.build_steps:
        print(" ".join(BUILD_STEPS))
        return 0
    if args.required_binaries:
        print(" ".join(REQUIRED_BINARIES))
        return 0

    smokes = discover(args.filter)
    if args.list:
        for p in smokes:
            print(p.name + ("  [serial]" if p.name in SERIAL else ""))
        print(f"\n{len(smokes)} smoke(s); {len(EXCLUDED)} excluded")
        for name, why in EXCLUDED.items():
            print(f"  excluded: {name} — {why}")
        return 0

    if not os.environ.get("S3_ENDPOINT"):
        print("S3 env not set — `set -a; . ./.env; set +a` first", file=sys.stderr)
        return 2

    # ── One suite per box ─────────────────────────────────────────────
    # Ports are already disjoint (smoke_ports.py); the resource suites
    # actually contend for is CPU — a saturated box trips raft election
    # timeouts, which read as spurious failovers in BOTH runs. So suite
    # runs queue on a box-global flock: the kernel blocks waiters and
    # releases on process exit (crash included — no stale locks; the
    # lock file itself is never unlinked, unlink+flock races). Several
    # agents in several clones can all just start a suite; they run one
    # at a time in roughly arrival order.
    lock_path = "/tmp/rove-smoke-suite.lock"
    lock_fd = open(lock_path, "a+", opener=lambda p, f: os.open(p, f, 0o666))
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        try:
            lock_fd.seek(0)
            holder = lock_fd.read().strip() or "unknown holder"
        except OSError:
            holder = "unknown holder"
        if args.no_queue:
            print(f"another suite is running ({holder}); --no-queue set, exiting", file=sys.stderr)
            return 3
        print(f"another suite is running ({holder}); queued — this run starts when it finishes ...",
              flush=True)
        wait_t0 = time.monotonic()
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        print(f"suite lock acquired after {time.monotonic() - wait_t0:.0f}s", flush=True)
    lock_fd.seek(0)
    lock_fd.truncate(0)
    lock_fd.write(f"pid={os.getpid()} cwd={os.getcwd()} started={time.strftime('%H:%M:%S')}\n")
    lock_fd.flush()
    # Held for the life of the process; the kernel releases it at exit.


    # Preflight the binaries. Several smokes drive the h2/ws example servers,
    # which the DEFAULT `zig build` install step produces — not the `rewind-*`
    # steps — and five drive the `rewind` CUSTOMER CLI, which is its own step
    # again (`zig build rewind`, no dash). Without this the suite reports a
    # pile of unrelated-looking failures whose real cause is one missing
    # build, which is exactly the kind of noise that teaches people to stop
    # reading the report.
    bin_dir = HERE.parent.parent / "zig-out" / "bin"
    missing = [b for b in REQUIRED_BINARIES if not (bin_dir / b).exists()]
    if missing:
        print(f"missing binaries in {bin_dir}: {', '.join(missing)}", file=sys.stderr)
        print("run `zig build` (default install) AND "
              f"`zig build {' '.join(BUILD_STEPS)}` first", file=sys.stderr)
        return CANNOT_RUN_RC

    # Clear what earlier runs left behind BEFORE allocating anything: an
    # orphaned node holds a port block and adds I/O the timing-sensitive
    # members will be measured against. Keyed on PPID==1, so a live sibling
    # session's run can never be touched.
    reaped = smoke_reap.reap_orphans()
    if reaped:
        print(f"smoke: reaped {reaped} orphaned node(s) from earlier runs\n", flush=True)

    jobs = max(1, args.jobs)
    log_dir = Path(args.logs) if args.logs else Path(f"/tmp/smoke-run-{os.getpid()}")
    log_dir.mkdir(parents=True, exist_ok=True)

    pool_members = [p for p in smokes if p.name not in SERIAL]
    serial_members = [p for p in smokes if p.name in SERIAL]
    if jobs > 1:
        # Longest-first: the pool's makespan is bounded by its longest member,
        # so start the long ones before the sub-20s crowd fills the slots.
        secs = baseline_seconds()
        pool_members.sort(key=lambda p: -secs.get(p.name, 60.0))

    print(f"running {len(smokes)} smoke(s) with --jobs {jobs}"
          f"{f' (+{len(serial_members)} serial tail)' if jobs > 1 and serial_members else ''}"
          f" — logs in {log_dir}\n", flush=True)

    results: dict[str, dict] = {}
    started = time.time()
    done_count = 0
    print_lock = threading.Lock()

    def report(p: Path, res: dict) -> None:
        nonlocal done_count
        with print_lock:
            done_count += 1
            results[p.name] = res
            mark = {"pass": "ok  ", "fail": "FAIL", "timeout": "HUNG",
                    "skip": "SKIP", "inconclusive": "INCO"}[res["status"]]
            print(f"  [{done_count:3d}/{len(smokes)}] {mark} {p.name}  "
                  f"({res['seconds']:.0f}s)", flush=True)
            if res["status"] == "skip":
                # Show the smoke's own one-line reason (it prints "SKIP — why"
                # before exiting SKIP_RC).
                log_path = log_dir / f"{p.stem}.log"
                for ln in log_path.read_text(errors="replace").splitlines():
                    if "SKIP" in ln:
                        print(f"         | {ln.strip()[:150]}", flush=True)
                        break
            elif res["status"] != "pass":
                # The first failing assertion is usually the whole story; show
                # a little of it inline so the report is readable without
                # opening logs.
                log_path = log_dir / f"{p.stem}.log"
                tail = [ln for ln in log_path.read_text(errors="replace").splitlines()
                        if "FAIL" in ln or "Error" in ln or "error:" in ln]
                for ln in tail[:3]:
                    print(f"         | {ln.strip()[:150]}", flush=True)

    if jobs == 1:
        for p in pool_members + serial_members:
            report(p, run_one(p, TIMEOUTS.get(p.name, args.timeout), log_dir, None))
    else:
        # The runner leases the slots through the same flocks the standalone
        # path uses, so a hand-run smoke beside the suite still partitions.
        slots: "queue.Queue[int]" = queue.Queue()
        for s in acquire_slots(jobs):
            slots.put(s)

        work: "queue.Queue[Path]" = queue.Queue()
        for p in pool_members:
            work.put(p)

        def worker() -> None:
            while True:
                try:
                    p = work.get_nowait()
                except queue.Empty:
                    return
                slot = slots.get()
                try:
                    report(p, run_one(p, TIMEOUTS.get(p.name, args.timeout),
                                      log_dir, slot))
                finally:
                    slots.put(slot)

        threads = [threading.Thread(target=worker, daemon=True)
                   for _ in range(jobs)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # One retry for pool failures, now that the box is quieter. A pass on
        # retry is reported FLKY — visibly distinct, counted as passing (a
        # transient S3 503 under 8-way load is not a regression), while a real
        # break fails twice and stays red. Never applied to the serial tail:
        # its members' flakiness is exactly what they exist to measure.
        for p in pool_members:
            if results[p.name]["status"] in ("pass", "skip"):
                continue
            first = results[p.name]
            # Keep the first failure's log — the retry would overwrite the
            # only evidence of what actually broke under load.
            first_log = log_dir / f"{p.stem}.log"
            if first_log.exists():
                first_log.rename(log_dir / f"{p.stem}.first.log")
            slot = slots.get()
            res = run_one(p, TIMEOUTS.get(p.name, args.timeout), log_dir, slot)
            slots.put(slot)
            with print_lock:
                if res["status"] == "pass":
                    results[p.name] = {**res, "status": "flaky",
                                       "first_try": first}
                    print(f"  [retry  ] FLKY {p.name}  ({res['seconds']:.0f}s)"
                          f" — failed under load, passed alone", flush=True)
                else:
                    results[p.name] = res
                    print(f"  [retry  ] FAIL {p.name}  ({res['seconds']:.0f}s)"
                          f" — failed twice", flush=True)

        # Serial tail: timing-sensitive members, alone on a quiet box.
        #
        # Return the slot. The pool worker does this in a `finally` and the
        # retry loop does it explicitly; leaking it here costs one slot per
        # member, and `slots` only ever holds `--jobs` of them. With five
        # exclusive members and `--jobs 4` the fifth `get()` blocks on an
        # empty queue FOREVER — after the last member the runner sits in a
        # futex with no children, so the summary and the `--baseline` diff
        # never print and the member itself never runs. A suite that cannot
        # reach its own verdict reports nothing while looking almost done.
        for p in serial_members:
            slot = slots.get()
            try:
                report(p, run_one(p, TIMEOUTS.get(p.name, args.timeout),
                                  log_dir, slot))
            finally:
                slots.put(slot)

    elapsed = time.time() - started

    # Every discovered member must have a result. A member that never ran is
    # not a pass and not a failure — it is absent coverage, and absent
    # coverage that says nothing is how a suite reports "162 ok" while one
    # member sat unstarted. The slot leak above made this reachable; the
    # check is what makes it VISIBLE if anything else ever does.
    missing = [p.name for p in smokes if p.name not in results]
    if missing:
        print(f"\n*** {len(missing)} member(s) discovered but never ran: {missing} ***\n"
              "The suite cannot speak for them. Treat this run as incomplete, not green.",
              flush=True)

    passed = [n for n, r in results.items() if r["status"] in ("pass", "flaky")]
    skipped = [n for n, r in results.items() if r["status"] == "skip"]
    # Held out of BOTH sides: not a pass, and not evidence of a regression.
    inconclusive = [n for n, r in results.items() if r["status"] == "inconclusive"]
    failed = [n for n, r in results.items()
              if r["status"] not in ("pass", "flaky", "skip", "inconclusive")]
    flaky = [n for n, r in results.items() if r["status"] == "flaky"]
    if not results:
        print("\nran ZERO smokes — nothing was measured. That is a broken runner, "
              "never a clean run (rove#373).", file=sys.stderr)
        return CANNOT_RUN_RC

    print(f"\n{'=' * 62}")
    print(f"{len(passed)}/{len(results) - len(skipped)} passed in {elapsed / 60:.0f}m"
          f"{f' ({len(flaky)} flaky)' if flaky else ''}"
          f"{f' ({len(skipped)} skipped)' if skipped else ''}"
          f"{f' ({len(inconclusive)} inconclusive)' if inconclusive else ''}")
    if inconclusive:
        print("  INCONCLUSIVE (assertion failed while the box was stalled — "
              "re-run on a quiet machine before believing it):")
        for n in inconclusive:
            print(f"    {n}")

    if args.json:
        Path(args.json).write_text(json.dumps(results, indent=2, sort_keys=True))
        print(f"summary → {args.json}")

    if args.baseline and os.path.exists(args.baseline):
        base = json.loads(Path(args.baseline).read_text())
        ok_states = ("pass", "flaky")
        newly_broken = [n for n in failed if base.get(n, {}).get("status") in ok_states]
        newly_fixed = [n for n in passed
                       if base.get(n, {}).get("status") not in (None, "skip", *ok_states)]
        still_broken = [n for n in failed if base.get(n, {}).get("status") not in (None, *ok_states)]
        # A member that PASSED in the baseline but only SKIPPED now never ran —
        # its coverage silently vanished (missing checkout / env). Warn loudly;
        # it is an environment problem, not a product regression, so it does
        # not fail the run.
        newly_skipped = [n for n in skipped if base.get(n, {}).get("status") in ok_states]
        print(f"\nvs baseline: {len(newly_broken)} newly broken, "
              f"{len(newly_fixed)} newly fixed, {len(still_broken)} still broken"
              f"{f', {len(newly_skipped)} NEWLY SKIPPED' if newly_skipped else ''}")
        for n in newly_broken:
            print(f"  REGRESSION {n}")
        for n in newly_fixed:
            print(f"  fixed      {n}")
        for n in newly_skipped:
            print(f"  SKIPPED    {n} — passed in the baseline but did not run; "
                  f"this run proves less than the baseline did")
        # A regression fails the run even if the absolute count improved, and
        # so does a member that never ran — an incomplete suite must not
        # certify a baseline it did not exercise.
        return 1 if (newly_broken or missing) else 0

    if failed:
        print(f"\nfailing ({len(failed)}):")
        for n in failed:
            print(f"  {results[n]['status']:7s} {n}")
    return 1 if (failed or missing) else 0


if __name__ == "__main__":
    sys.exit(main())
