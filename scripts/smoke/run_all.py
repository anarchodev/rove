#!/usr/bin/env python3
"""Run the smoke suite and report what actually passes.

Nothing ran these before, so they rotted silently: four were found dead by
accident in a single session (rove#355), each broken for weeks by a change
elsewhere that nobody connected to them. A suite nobody runs is not coverage,
it is the appearance of coverage — which is worse, because it is counted.

Smokes bind fixed ports and spawn real clusters, so they run SERIALLY. The
whole suite takes a while; that is the price of end-to-end tests against real
binaries, and it is why this prints progress per smoke rather than going quiet.

    scripts/smoke/run_all.py                  # everything
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
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Not smokes: shared harness modules, and helpers imported by them.
NOT_SMOKES = {"smoke_lib.py", "smoke_lib_v2.py", "v2_topology.py", "run_all.py"}

# Scripts that are deliberately not part of the suite. Each needs a REASON —
# "it fails" is not one; that is what the report is for.
EXCLUDED = {
    # Standalone reproduction for an open bug: expected to fail until it is
    # fixed, and a known-red member would train you to ignore the report.
    "front_write_reaim_repro.py": "rove#353 repro — red by design until fixed",
}

# Smokes that legitimately run longer than the default budget. Without an
# entry here a slow-but-healthy smoke is reported HUNG, which reads as a
# product hang and is the fastest way to teach people to distrust the report.
TIMEOUTS = {
    "raft_soak_prod.py": 1800,      # 6 rounds of kill/wipe/heal by design
}


def discover(filter_str: str | None) -> list[Path]:
    out = []
    for p in sorted(HERE.glob("*.py")):
        if p.name in NOT_SMOKES or p.name in EXCLUDED:
            continue
        if filter_str and filter_str not in p.name:
            continue
        out.append(p)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--filter", default=None, help="substring match on the script name")
    ap.add_argument("--list", action="store_true", help="list what would run, then exit")
    ap.add_argument("--timeout", type=int, default=420,
                    help="per-smoke seconds (TIMEOUTS overrides it per smoke)")
    ap.add_argument("--logs", default=None, help="directory for per-smoke logs")
    ap.add_argument("--json", default=None, help="write a machine-readable summary here")
    ap.add_argument("--baseline", default=None, help="compare against a prior --json summary")
    args = ap.parse_args()

    smokes = discover(args.filter)
    if args.list:
        for p in smokes:
            print(p.name)
        print(f"\n{len(smokes)} smoke(s); {len(EXCLUDED)} excluded")
        for name, why in EXCLUDED.items():
            print(f"  excluded: {name} — {why}")
        return 0

    if not os.environ.get("S3_ENDPOINT"):
        print("S3 env not set — `set -a; . ./.env; set +a` first", file=sys.stderr)
        return 2

    # Preflight the binaries. Several smokes drive the h2 example servers, which
    # the DEFAULT `zig build` install step produces — not the `rewind-*` steps.
    # Without this the suite reports a pile of unrelated-looking failures whose
    # real cause is one missing build, which is exactly the kind of noise that
    # teaches people to stop reading the report.
    bin_dir = HERE.parent.parent / "zig-out" / "bin"
    needed = ["rewind-worker", "rewind-cp", "rewind-front", "rewind-logs",
              "rewind-ops", "h2-echo-server", "echo-server"]
    missing = [b for b in needed if not (bin_dir / b).exists()]
    if missing:
        print(f"missing binaries in {bin_dir}: {', '.join(missing)}", file=sys.stderr)
        print("run `zig build` (default install) AND `zig build rewind-worker rewind-cp "
              "rewind-front rewind-logs rewind-ops` first", file=sys.stderr)
        return 2

    log_dir = Path(args.logs) if args.logs else Path(f"/tmp/smoke-run-{os.getpid()}")
    log_dir.mkdir(parents=True, exist_ok=True)
    print(f"running {len(smokes)} smoke(s) serially — logs in {log_dir}\n", flush=True)

    results: dict[str, dict] = {}
    started = time.time()
    for i, p in enumerate(smokes, 1):
        log_path = log_dir / f"{p.stem}.log"
        budget = TIMEOUTS.get(p.name, args.timeout)
        t0 = time.time()
        with open(log_path, "w") as lf:
            # Own process group, so a timeout can kill the smoke AND the
            # cluster it spawned. Killing only the script leaves its nodes
            # holding the fixed ports, and every later smoke fails on
            # EADDRINUSE — one hang reported as a dozen.
            proc = subprocess.Popen([sys.executable, str(p)], stdout=lf,
                                    stderr=subprocess.STDOUT,
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
        dur = time.time() - t0
        results[p.name] = {"status": status, "rc": rc, "seconds": round(dur, 1)}
        mark = {"pass": "ok  ", "fail": "FAIL", "timeout": "HUNG"}[status]
        print(f"  [{i:3d}/{len(smokes)}] {mark} {p.name}  ({dur:.0f}s)", flush=True)
        if status != "pass":
            # The first failing assertion is usually the whole story; show a
            # little of it inline so the report is readable without opening logs.
            tail = [ln for ln in log_path.read_text(errors="replace").splitlines()
                    if "FAIL" in ln or "Error" in ln or "error:" in ln]
            for ln in tail[:3]:
                print(f"         | {ln.strip()[:150]}", flush=True)

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
