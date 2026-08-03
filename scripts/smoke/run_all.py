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
import json
import os
import queue
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent

sys.path.insert(0, str(HERE))
from smoke_ports import acquire_slots  # noqa: E402

# Not smokes: shared harness modules, and helpers imported by them.
NOT_SMOKES = {"smoke_lib.py", "smoke_lib_v2.py", "v2_topology.py", "run_all.py",
              "smoke_ports.py"}

# Scripts that are deliberately not part of the suite. Each needs a REASON —
# "it fails" is not one; that is what the report is for.
EXCLUDED = {
    # Standalone reproduction for an open bug: expected to fail until it is
    # fixed, and a known-red member would train you to ignore the report.
    "front_write_reaim_repro.py": "rove#353 repro — red by design until fixed",
}

# Known-red members that ARE in the suite, so the report keeps counting them.
# Both are genuine product defects, not stale fixtures — which is why they stay
# in and stay red rather than being excluded:
#   tls_large_body_smoke.py    — rove#361, concurrent large static downloads
#                                abort mid-stream (sequential ones are fine).
#   dispatch_gate_smoke_v2.py  — rove#362, a leader that idles past the
#                                hibernation window spuriously steps down.
#                                INTERMITTENT (~2 of 3), so it moves between
#                                pass and fail across runs; `--baseline` will
#                                call it a regression on a run where it flips.
#                                Check it against rove#362 before believing it.

# Members that run ALONE, after the parallel pool drains. These assert timing
# that co-tenant CPU load can skew — an election-timeout soak or a
# hibernation-window race read under load produces flakes that look exactly
# like product bugs, and a flaky red trains people to ignore the report.
# Membership is empirical: a member that proves load-tolerant should move to
# the pool (the tail bounds the parallel suite's floor).
SERIAL = {
    "raft_soak_prod.py",        # 6 kill/wipe/heal rounds on election timing
    "raft_soak_v2.py",          # same shape, shorter
    "dispatch_gate_smoke_v2.py",  # rove#362: already intermittent serially —
                                  # co-load noise would make the flip unreadable
    "leader_failover_smoke_v2.py",  # asserts exactly ONE re-election after the
                                    # kill; co-load stretches heartbeats enough
                                    # to fire a second (#362's fingerprint)
    "tls_large_body_smoke.py",  # rove#361: red via ITS OWN download
                                # concurrency — keep the repro conditions fixed
}

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
            status = "pass" if rc == 0 else "fail"
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
    ap.add_argument("--jobs", type=int, default=1,
                    help="concurrent smokes (SERIAL members always run alone)")
    ap.add_argument("--timeout", type=int, default=420,
                    help="per-smoke seconds (TIMEOUTS overrides it per smoke)")
    ap.add_argument("--logs", default=None, help="directory for per-smoke logs")
    ap.add_argument("--json", default=None, help="write a machine-readable summary here")
    ap.add_argument("--baseline", default=None, help="compare against a prior --json summary")
    args = ap.parse_args()

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

    # Preflight the binaries. Several smokes drive the h2/ws example servers,
    # which the DEFAULT `zig build` install step produces — not the `rewind-*`
    # steps. Without this the suite reports a pile of unrelated-looking
    # failures whose real cause is one missing build, which is exactly the
    # kind of noise that teaches people to stop reading the report.
    bin_dir = HERE.parent.parent / "zig-out" / "bin"
    needed = ["rewind-worker", "rewind-cp", "rewind-front", "rewind-logs",
              "rewind-ops", "h2-echo-server", "echo-server", "ws-echo"]
    missing = [b for b in needed if not (bin_dir / b).exists()]
    if missing:
        print(f"missing binaries in {bin_dir}: {', '.join(missing)}", file=sys.stderr)
        print("run `zig build` (default install) AND `zig build rewind-worker rewind-cp "
              "rewind-front rewind-logs rewind-ops` first", file=sys.stderr)
        return 2

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
            mark = {"pass": "ok  ", "fail": "FAIL", "timeout": "HUNG"}[res["status"]]
            print(f"  [{done_count:3d}/{len(smokes)}] {mark} {p.name}  "
                  f"({res['seconds']:.0f}s)", flush=True)
            if res["status"] != "pass":
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

        # Serial tail: timing-sensitive members, alone on a quiet box.
        for p in serial_members:
            report(p, run_one(p, TIMEOUTS.get(p.name, args.timeout), log_dir,
                              slots.get()))

    elapsed = time.time() - started
    passed = [n for n, r in results.items() if r["status"] == "pass"]
    failed = [n for n, r in results.items() if r["status"] != "pass"]
    print(f"\n{'=' * 62}")
    print(f"{len(passed)}/{len(results)} passed in {elapsed / 60:.0f}m")

    if args.json:
        Path(args.json).write_text(json.dumps(results, indent=2, sort_keys=True))
        print(f"summary → {args.json}")

    if args.baseline and os.path.exists(args.baseline):
        base = json.loads(Path(args.baseline).read_text())
        newly_broken = [n for n in failed if base.get(n, {}).get("status") == "pass"]
        newly_fixed = [n for n in passed if base.get(n, {}).get("status") not in (None, "pass")]
        still_broken = [n for n in failed if base.get(n, {}).get("status") not in (None, "pass")]
        print(f"\nvs baseline: {len(newly_broken)} newly broken, "
              f"{len(newly_fixed)} newly fixed, {len(still_broken)} still broken")
        for n in newly_broken:
            print(f"  REGRESSION {n}")
        for n in newly_fixed:
            print(f"  fixed      {n}")
        # A regression fails the run even if the absolute count improved.
        return 1 if newly_broken else 0

    if failed:
        print(f"\nfailing ({len(failed)}):")
        for n in failed:
            print(f"  {results[n]['status']:7s} {n}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
