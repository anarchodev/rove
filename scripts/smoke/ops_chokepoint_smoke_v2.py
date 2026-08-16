#!/usr/bin/env python3
"""The operator CLI drives control-plane ops through the `__admin__` chokepoint.

Two properties, and the security one is the interesting half:

  1. **The operator shell holds no platform secret.** This smoke runs
     `rewind-ops provision` with `REWIND_MOVE_SECRET` and `ROVE_CP_URL_INTERNAL`
     deliberately ABSENT from the environment. If it still places the tenant,
     the move-secret is genuinely not needed on the shell any more — the worker
     attaches it at the `rewind-cp.internal` door, which it opens only for
     `__admin__`. Asserting the absence is the point: with the vars present, a
     silent fallback to the direct path would pass a weaker version of this test.

  2. **The action leaves a record.** A direct `/_control/*` POST runs no handler,
     so it produces no log record and cannot be replayed — the operator plane
     had no audit trail at all (rove#414). Through the chokepoint it is an
     ordinary `__admin__` activation, so `/v1/cp/provision` shows up in the
     tenant's log.

Both the BAKED genesis app and the deployed dashboard carry the `/v1/cp/:op`
relay, and the smoke asserts BOTH — because the baked one is what a cluster runs
between genesis and its first dashboard publish, and without it the CLI's
primary verb would be unusable exactly then. (It was: routing the CLI through
the chokepoint before the baked app had the route broke `rewind-ops provision`
on every baked-app cluster, which is how this check earned its place.)

Needs S3 env: `set -a; . ./.env; set +a` first, and a rewind-apps checkout.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, APPS_DIR, BIN_DIR, MOVE_SECRET, _curl  # noqa: E402

TENANT = "chokepointed"


def follower_first_urls(c) -> str:
    """Every worker URL, with the `__admin__` group's LEADER deliberately
    LAST. The chokepoint is leader-gated, so a worker list that leads with a
    follower forces the CLI through its 421-retry path on every op — which
    is exactly the path that was broken (rove#535: the 421 was returned as
    final) and which a single-node cluster can never exercise."""
    leader = None
    for i in range(len(c.node_ports)):
        r = _curl(f"{c.node_url(i)}/_system/v2-leader?tenant=__admin__",
                  headers={"X-Rewind-Move-Secret": MOVE_SECRET})
        if r.status == 200:
            leader = i
            break
    order = [i for i in range(len(c.node_ports)) if i != leader]
    if leader is not None:
        order.append(leader)
    return ",".join(c.node_url(i) for i in order)


def run_ops(c, *args, with_secrets: bool = False, timeout: int = 120):
    """Invoke rewind-ops the way an operator shell would. `with_secrets=False`
    is the assertion: no move-secret, no CP URL — only the root token and the
    admin domain, which is all the chokepoint path needs."""
    env = dict(os.environ)
    env.pop("REWIND_MOVE_SECRET", None)
    env.pop("ROVE_CP_URL_INTERNAL", None)
    env["ROVE_WORKER_URLS"] = follower_first_urls(c)
    env["REWIND_ROOT_TOKEN"] = c.root_token
    env["REWIND_ADMIN_DOMAIN"] = c.host_for("__admin__")
    env["ROVE_CLUSTER"] = c.cluster_id
    if with_secrets:
        from smoke_lib_v2 import MOVE_SECRET
        env["REWIND_MOVE_SECRET"] = MOVE_SECRET
        env["ROVE_CP_URL_INTERNAL"] = c.front_url().replace(
            str(c.front_port), str(c.cp_port))
    return subprocess.run(
        [str(BIN_DIR / "rewind-ops"), *args,
         "--env", "/nonexistent-so-only-the-process-env-is-read"],
        env=env, capture_output=True, text=True, timeout=timeout)


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    admin_files = {p: (APPS_DIR / "admin" / p).read_text() for p in
                   ("index.mjs", "_middlewares/index.mjs",
                    "_rp/complete.mjs", "_rp/jwks.mjs", "v1/upload/index.mjs")}

    # 3 nodes, so the follower-first worker list (see `follower_first_urls`)
    # exercises the CLI's leader-gate retry on every chokepointed op (#535).
    with V2Cluster.spawn("opschoke", nodes=3) as c:
        c.spawn_log_server()
        c._ensure_admin_app()

        print("step 1: the BAKED app relays the chokepoint — a freshly-genesis'd\n"
              "      cluster can provision before any dashboard exists")
        r = run_ops(c, "provision", TENANT + "-baked")
        out0 = r.stdout + r.stderr
        check("provision through the BAKED app succeeded", r.returncode == 0,
              "" if r.returncode == 0 else repr(out0[-400:]))
        check("...and reported the placement",
              "provisioned" in out0 or "already placed" in out0,
              "" if ("provisioned" in out0 or "already placed" in out0) else repr(out0[-300:]))

        print("step 2: deploy the real dashboard, which carries the chokepoint")
        try:
            pkgs, imports = c.firstparty_packages(["@rewind/oidc", "@rewind/email", "@rewind/stripe"])
            c.deploy_with_packages("__admin__", admin_files, pkgs, imports)
        except RuntimeError as e:
            check("deploy web/admin → __admin__", False, str(e))
            return 1
        # The loader picks the new bundle up asynchronously; until it does, the
        # BAKED app is still answering. Poll on a shape only the dashboard has —
        # the baked app answers GET "/" with 405 (POST only).
        live = False
        deadline = time.time() + 45.0
        while time.time() < deadline:
            probe = c.request("__admin__", "/", timeout=15.0)
            if probe.status != 405:
                live = True
                break
            time.sleep(1.0)
        check("web/admin is the live bundle on __admin__ (GET / no longer 405)", live,
              "" if live else "the baked deploy app is still serving — the deploy did not take")
        if not live:
            return 1

        print("step 3: provision with NO move-secret and NO CP url on the shell")
        r = run_ops(c, "provision", TENANT)
        out = r.stdout + r.stderr
        check("provision through the chokepoint succeeded", r.returncode == 0, repr(out[-400:]))
        check("...and reported the placement", "provisioned" in out or "already placed" in out,
              repr(out[-300:]))
        if r.returncode != 0:
            c.dump_node_log(grep=["auth:", "root-token", "middleware", "rp", "cp"])

        print("step 4: the tenant is really placed (the CP agrees)")
        rr = c.provision(TENANT)   # re-provision via the CP → 409 already placed
        check("re-provision → 409 already placed", rr.status == 409,
              f"got {rr.status} {rr.body!r}")

        print("step 5: the action left a REPLAYABLE __admin__ record\n      (a direct /_control POST runs no handler and leaves nothing)")
        found = None
        deadline = time.time() + 40.0
        while time.time() < deadline and found is None:
            lr = c.log_get("__admin__/list?limit=50", timeout=15.0)
            if lr.status == 200:
                try:
                    recs = json.loads(lr.body).get("records", [])
                except json.JSONDecodeError:
                    recs = []
                # A 404 from the baked app is also a record at this path, so
                # match on a SUCCESSFUL one — otherwise the failure path
                # satisfies the check, which it did on the first run of this
                # smoke.
                cands = [x for x in recs if "/v1/cp/provision" in (x.get("path") or "")]
                # Two shapes land at this path: step 1's 404 from the baked app,
                # and the chokepointed run. The latter records status 0 because
                # the handler HOLDS (after.fetch at the CP door + next()) — the
                # terminal response is produced by the resume activation, which
                # is logged under the module path, not this one. So select by
                # "not the 404", and let the tapes assertion below carry the
                # weight: a record without them is logged but not replayable.
                found = next((x for x in cands if int(x.get("status") or 0) != 404), None)
            if found is None:
                time.sleep(1.0)
        check("the chokepointed op left an __admin__ record", found is not None,
              "" if found is not None else
              "the operator action ran no handler — no audit trail")
        if found is not None:
            sr = c.log_get(f"__admin__/show/{found.get('request_id')}", timeout=15.0)
            rec = json.loads(sr.body).get("record", {}) if sr.status == 200 else {}
            # A record without tapes cannot be replayed, which is the whole
            # point of routing the op through a handler.
            check("...carrying tapes (so it is replayable, not merely logged)",
                  bool(rec.get("tapes")), f"tapes={list((rec.get('tapes') or {}).keys())}")

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s): {', '.join(failures)}")
        return 1
    print("PASSED: operator control ops go through the __admin__ chokepoint — "
          "no platform secret on the shell, and the action is recorded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
