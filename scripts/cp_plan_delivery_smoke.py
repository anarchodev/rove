#!/usr/bin/env python3
"""CP→DP plan delivery smoke (gap #1, step 2; docs/v2-cp-operational-state.md
"Delivery to the DP", docs/architecture/control-plane.md).

Step 1 proved the CP stores + serves the opaque plan blob. This proves the DP
LEARNS its plan over the two channels the design names — and resolves the blob
into effective limits cached on the tenant's hot-path slot
(`TenantSlot.effectivePlan`):

  - LIVE PUSH: a `POST /_control/plan` on the CP single-targets the serving
    cluster (`POST /_system/v2-plan`), which bumps the slot's plan generation.
  - ATTACH HANDSHAKE: on a tenant MOVE the plan rides `v2-attach` (the
    `X-Rewind-Plan` header) so the destination enforces from its first request.

The DP-side `GET /_system/v2-plan?tenant=` returns the RESOLVED effective limits
(move-secret gated, like the rest of the v2-* surface) — the read-back that
makes delivery observable end to end.

Topology (single-node clusters; no front door needed — we talk to the workers'
move surface directly):

    rewind-cp :18213    (plan control + move orchestrator + directory)
      ├─ cluster-1 → rewind :18211   (planco starts here)
      └─ cluster-2 → rewind :18212   (planco moves here)

Proof legs:
  A. seed planco on c1 (creates the instance/slot); GET v2-plan → FREE table
     (no plan set ⇒ free tier).
  B. POST /_control/plan {pro} → live push to c1; GET v2-plan on c1 → PRO
     table, plan_gen advanced.
  C. update to {enterprise + max_body_bytes override}; GET v2-plan on c1 →
     enterprise table with the override folded in, plan_gen advanced again.
  D. move planco c1 → c2; GET v2-plan on c2 → the SAME enterprise+override
     limits (delivered by the attach handshake, not a push).

Requires S3 env (the move ships a bundle; there is no fs BlobBackend) — source
the repo `.env` first:
  `set -a; . ./.env; set +a; python3 scripts/cp_plan_delivery_smoke.py`

Build first:  `zig build rewind && zig build rewind-cp`
"""

import json
import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_topology import spawn_cp, await_line, CP_BIN

BINDIR = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin")
REWIND = os.path.join(BINDIR, "rewind")

PCP = int(os.environ.get("CP_PORT", "18213"))
P1 = int(os.environ.get("C1_PORT", "18211"))
P2 = int(os.environ.get("C2_PORT", "18212"))

MOVE_SECRET = "rewindmovesecretpadding0123456789abcdef0"
TENANT = "planco"
HOST = "planco.localhost"
KEY = "k"
VALUE = "v"

# Mirror src/js/plan.zig's baked tier table so the smoke fails loudly if the
# numbers drift apart (the table is the contract the DP enforces).
FREE = dict(request_capacity=1000, request_refill_per_sec=500,
            email_capacity=100, email_refill_per_sec=10,
            max_body_bytes=4 * 1024 * 1024, retention_days=7)
PRO = dict(request_capacity=10000, request_refill_per_sec=5000,
           email_capacity=1000, email_refill_per_sec=100,
           max_body_bytes=32 * 1024 * 1024, retention_days=30)
ENT_OVERRIDE_BODY = 1048576
ENT = dict(request_capacity=100000, request_refill_per_sec=50000,
           email_capacity=10000, email_refill_per_sec=1000,
           max_body_bytes=ENT_OVERRIDE_BODY, retention_days=365)

PLAN_PRO = '{"tier":"pro"}'
PLAN_ENT = json.dumps({"tier": "enterprise",
                       "overrides": {"max_body_bytes": ENT_OVERRIDE_BODY}},
                      separators=(",", ":"))

procs = []


def spawn_rewind(name, port, data_dir):
    env = dict(os.environ)
    env["REWIND_ADMIN_DOMAIN"] = f"{name}.localhost"
    env["REWIND_MOVE_SECRET"] = MOVE_SECRET
    env["REWIND_ROOT_TOKEN"] = "smoke-nonprod-root-token-0123456789abcdef"  # non-default: rewind rejects unset/default
    p = subprocess.Popen(
        [REWIND, data_dir, str(port)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
    procs.append(p)
    await_line(p, name, "listening on")
    return p


def _curl(args):
    out = subprocess.run(
        ["curl", "-s", "-w", "\n%{http_code}", "-m", "15", "--http2-prior-knowledge"] + args,
        capture_output=True, text=True,
    )
    text = out.stdout
    nl = text.rfind("\n")
    if nl < 0:
        return (0, text)
    body, code = text[:nl], text[nl + 1:].strip()
    try:
        return (int(code), body)
    except ValueError:
        return (0, body)


def kv_put(port, tenant, key, value):
    return _curl([
        "-X", "PUT", f"http://127.0.0.1:{port}/_system/v2-kv",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
        "-H", "Content-Type: application/json",
        "--data", f'{{"tenant":"{tenant}","key":"{key}","value":"{value}"}}',
    ])[0]


def set_plan(plan):
    body = json.dumps({"tenant": TENANT, "plan": plan}, separators=(",", ":"))
    return _curl([
        "-X", "POST", f"http://127.0.0.1:{PCP}/_control/plan",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
        "-H", "Content-Type: application/json",
        "--data", body,
    ])


def get_dp_plan(port, tenant=TENANT):
    """Worker-side resolved effective limits (move-secret gated). Returns
    (status, dict|None)."""
    st, body = _curl([
        f"http://127.0.0.1:{port}/_system/v2-plan?tenant={tenant}",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
    ])
    if st != 200:
        return (st, None)
    try:
        return (st, json.loads(body))
    except json.JSONDecodeError:
        return (st, None)


def move(tenant, dest):
    return _curl([
        "-X", "POST", f"http://127.0.0.1:{PCP}/_control/move",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
        "-H", "Content-Type: application/json",
        "--data", f'{{"tenant":"{tenant}","dest":"{dest}"}}',
    ])


def poll_dp_plan(port, want, timeout=8):
    """Poll the worker's effective limits until every key in `want` matches
    (delivery is synchronous on the happy path, but a brief poll absorbs
    scheduling jitter). Returns the last-seen dict."""
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        st, got = get_dp_plan(port)
        if got is not None:
            last = got
            if all(got.get(k) == v for k, v in want.items()):
                return got
        time.sleep(0.1)
    return last


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
    for b in (REWIND, CP_BIN):
        if not os.path.exists(b):
            raise SystemExit(f"{b} not found — run `zig build rewind && zig build rewind-cp`")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")

    d1 = f"/tmp/plan-deliv-c1-{os.getpid()}"
    d2 = f"/tmp/plan-deliv-c2-{os.getpid()}"
    dcp = f"/tmp/plan-deliv-cp-{os.getpid()}"
    for d in (d1, d2, dcp):
        subprocess.run(["rm", "-rf", d])

    failures = []

    def check(label, got, want, predicate="eq"):
        ok = (got == want) if predicate == "eq" else (got != want)
        sign = "==" if predicate == "eq" else "!="
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} ({sign} {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}")

    def check_limits(label, got, want):
        if got is None:
            check(label, None, want)
            return
        for k, v in want.items():
            check(f"{label}.{k}", got.get(k), v)

    try:
        print("boot: two rewind clusters + CP (plan control)")
        spawn_rewind("c1", P1, d1)
        spawn_rewind("c2", P2, d2)
        spawn_cp(
            procs, PCP,
            clusters=f"cluster-1=http://127.0.0.1:{P1};cluster-2=http://127.0.0.1:{P2}",
            hosts=f"{HOST}={TENANT}",
            placement=f"{TENANT}=cluster-1",
            cp_data_dir=dcp,
            move_secret=MOVE_SECRET,
        )

        # ── A. seed → instance/slot exists; no plan ⇒ free tier ───────
        print("leg A: seed planco on c1 → DP resolves the FREE tier")
        check("PUT c1 seed", kv_put(P1, TENANT, KEY, VALUE), 204)
        st, got = get_dp_plan(P1)
        check("GET v2-plan c1 status", st, 200)
        check_limits("free", got, FREE)
        gen0 = got.get("plan_gen") if got else None

        # ── B. live push: pro ────────────────────────────────────────
        print("leg B: set {pro} on CP → live push to c1")
        st, body = set_plan(PLAN_PRO)
        check("POST /_control/plan {pro} status", st, 200)
        got = poll_dp_plan(P1, PRO)
        check_limits("pro (live push)", got, PRO)
        check("plan_gen advanced after push", (got or {}).get("plan_gen", gen0) != gen0, True)

        # ── C. live push: enterprise + override ──────────────────────
        print("leg C: update to {enterprise + max_body_bytes override}")
        st, _ = set_plan(PLAN_ENT)
        check("POST /_control/plan {ent} status", st, 200)
        got = poll_dp_plan(P1, ENT)
        check_limits("enterprise+override (live push)", got, ENT)

        # ── D. attach handshake: plan rides the move ─────────────────
        print("leg D: move planco c1 → c2 → plan rides the attach handshake")
        st, body = move(TENANT, "cluster-2")
        check("POST /_control/move status", st, 200)
        print(f"       move says: {body.strip()!r}")
        got = poll_dp_plan(P2, ENT)
        check_limits("enterprise+override (on c2 via attach)", got, ENT)
    finally:
        stop_all()
        for d in (d1, d2, dcp):
            subprocess.run(["rm", "-rf", d])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — DP learns its plan via live push AND the attach handshake; "
          "blob resolves to the right effective limits. ✅")


if __name__ == "__main__":
    main()
