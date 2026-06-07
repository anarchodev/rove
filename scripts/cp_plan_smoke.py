#!/usr/bin/env python3
"""CP plan/limits axis smoke (gap #1, step 1; docs/v2-cp-operational-state.md,
docs/plan-tiers.md).

Per-tenant operational state (plan/limits) lives in the CP `__directory__`
group, authored via a capability-gated control write and read by the DP. The
CP is dumb — it stores the `{tier, overrides}` blob verbatim and serves it; the
DP parses it into effective limits. This proves the CP-side foundation:

  A. GET /_cp/plan?tenant=acme → 404 (unset ⇒ DP uses the free tier).
  B. POST /_control/plan {tenant, plan} (move-secret gated) → 200; read back
     the exact blob via /_cp/plan.
  C. update the plan → the new blob replaces the old (read reflects it).
  D. POST /_control/plan WITHOUT the secret → 401 (admin-gated write).
  E. durability — kill -9 the CP, restart over the same REWIND_CP_DATA_DIR,
     the plan REPLAYS from the durable directory store (placement-independent
     state survives a control-plane restart).

The CP needs no DP workers and no S3 (plan is pure directory state).

Build first:  `zig build rewind-cp`
"""

import json
import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_topology import spawn_cp, CP_BIN

PCP = int(os.environ.get("CP_PORT", "18200"))
MOVE_SECRET = "rewindmovesecretpadding0123456789abcdef0"
TENANT = "acme"
HOST = "acme.localhost"

CLUSTERS = "cluster-1=http://127.0.0.1:18201"
HOSTS = f"{HOST}={TENANT}"
PLACEMENT = f"{TENANT}=cluster-1"

PLAN_PRO = '{"tier":"pro"}'
PLAN_ENT = '{"tier":"enterprise","overrides":{"max_body_bytes":1048576}}'

procs = []


def _curl(args):
    out = subprocess.run(
        ["curl", "-s", "-w", "\n%{http_code}", "-m", "10", "--http2-prior-knowledge"] + args,
        capture_output=True, text=True,
    ).stdout
    nl = out.rfind("\n")
    if nl < 0:
        return (0, out)
    try:
        return (int(out[nl + 1:].strip() or 0), out[:nl])
    except ValueError:
        return (0, out[:nl])


def set_plan(plan, secret=MOVE_SECRET):
    body = json.dumps({"tenant": TENANT, "plan": plan}, separators=(",", ":"))
    args = ["-X", "POST", f"http://127.0.0.1:{PCP}/_control/plan",
            "-H", "Content-Type: application/json", "--data", body]
    if secret is not None:
        args += ["-H", f"X-Rewind-Move-Secret: {secret}"]
    return _curl(args)


def get_plan(tenant=TENANT):
    return _curl([f"http://127.0.0.1:{PCP}/_cp/plan?tenant={tenant}"])


def spawn(want_needle, cpd):
    return spawn_cp(
        procs, PCP,
        clusters=CLUSTERS, hosts=HOSTS, placement=PLACEMENT,
        cp_data_dir=cpd, move_secret=MOVE_SECRET, want_needle=want_needle,
    )


def stop_all():
    for p in procs:
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
    for p in procs:
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()


def main():
    if not os.path.exists(CP_BIN):
        raise SystemExit(f"{CP_BIN} not found — run `zig build rewind-cp`")

    cpd = f"/tmp/cp-plan-{os.getpid()}"
    subprocess.run(["rm", "-rf", cpd])

    failures = []

    def check(label, got, want):
        ok = got == want
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} (== {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}")

    try:
        print("boot: single-node CP (plan/limits surface)")
        cp = spawn(want_needle="seeded directory", cpd=cpd)

        # ── A. unset → 404 ───────────────────────────────────────────
        print("leg A: an unset tenant has no plan (free tier)")
        check("GET /_cp/plan unset → 404", get_plan()[0], 404)

        # ── B. set + read back the exact blob ────────────────────────
        print("leg B: set a plan, read it back verbatim")
        check("POST /_control/plan → 200", set_plan(PLAN_PRO)[0], 200)
        check("GET /_cp/plan → pro blob", get_plan(), (200, PLAN_PRO))

        # ── C. update replaces ───────────────────────────────────────
        print("leg C: update the plan (new blob replaces old)")
        check("POST /_control/plan (update) → 200", set_plan(PLAN_ENT)[0], 200)
        check("GET /_cp/plan → enterprise blob", get_plan(), (200, PLAN_ENT))

        # ── D. write is admin-gated ──────────────────────────────────
        print("leg D: a plan write without the move secret is rejected")
        check("POST /_control/plan no-secret → 401", set_plan(PLAN_PRO, secret=None)[0], 401)
        check("plan unchanged after rejected write", get_plan(), (200, PLAN_ENT))

        # ── E. durability across a CP restart ────────────────────────
        print("leg E: kill -9 the CP; the plan replays from the durable store")
        os.kill(cp.pid, signal.SIGKILL)
        cp.wait()
        procs.remove(cp)
        spawn(want_needle="skipping static seed", cpd=cpd)
        check("GET /_cp/plan after restart → enterprise blob", get_plan(), (200, PLAN_ENT))
    finally:
        stop_all()
        subprocess.run(["rm", "-rf", cpd])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — the CP stores + serves per-tenant plan blobs (admin-gated "
          "write, DP read), replicated through the directory group and durable "
          "across a restart. (gap #1 step 1)")


if __name__ == "__main__":
    main()
