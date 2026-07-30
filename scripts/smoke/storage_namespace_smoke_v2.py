#!/usr/bin/env python3
"""Does a second cluster lifetime over the same object store keep its records?

This is the regression test for rove#266. A cold bring-up wipes `~/.rove/data`,
which resets the per-tenant request-id counter, but it does NOT wipe S3 (there
is no delete-by-prefix, and the blobs are the deployed code). The log index is
keyed `(tenant_id, request_id)` and written `INSERT OR IGNORE`, so the second
lifetime re-issues ids the re-imported history already owns and every colliding
record is discarded — silently, with all health counters green. On production
that cost an hour of request logs and left them unreplayable.

The storage namespace (`src/blob/namespace.zig`) is what prevents it: genesis
bumps a generation, the new lifetime writes under `{prefix}{n}/`, and no id it
mints can address a previous lifetime's key.

Two lifetimes over ONE prefix, with the local state wiped between them exactly
as genesis does:

  1. lifetime A serves requests; its records are queryable.
  2. WITHOUT a bump, lifetime B's records collide with A's re-imported ids and
     vanish — the negative control. A test that only ran the fixed path would
     pass just as happily if the namespace did nothing at all, so this asserts
     the failure is real and that this smoke can see it.
  3. WITH a bump, lifetime C's records survive.

Ports: 19830/19930 (see the per-smoke port table; do not run two smokes at
once). Needs S3 credentials: `set -a; . ./.env; set +a`.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke_lib_v2 import V2Cluster, BIN_DIR  # noqa: E402

FIXTURE = {
    "index.mjs": """
export default function () {
  response.status = 200;
  return "lifetime";
}
""",
}

TENANT = "acme"
# Off the default 9110 so a stray local worker can't answer for ours.
METRICS_PORT = 19839


def worker_storage_prefix() -> str | None:
    """The prefix the running worker reports on its operator metrics port —
    the same signal `deploy.sh` asserts on across all three prod nodes."""
    deadline = time.time() + 20.0
    while time.time() < deadline:
        try:
            import urllib.request
            with urllib.request.urlopen(
                    f"http://127.0.0.1:{METRICS_PORT}/metrics", timeout=5) as r:
                for line in r.read().decode().splitlines():
                    if line.startswith("storage_namespace_info{"):
                        return line.split('prefix="', 1)[1].split('"', 1)[0]
        except Exception:
            pass
        time.sleep(1.0)
    return None


def ops_namespace(prefix: str, *args) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env["S3_KEY_PREFIX_BASE"] = prefix
    return subprocess.run(
        [str(BIN_DIR / "rewind-ops"), "storage-namespace", *args,
         "--env", "/nonexistent-so-only-the-process-env-is-read"],
        env=env, capture_output=True, text=True, timeout=60)


def serve_and_collect(c: V2Cluster, marker: str, *, deploy: bool) -> list[str]:
    """Serve three requests tagged `marker` and return the paths the log index
    ends up holding for them."""
    if deploy:
        c.deploy_handlers(TENANT, FIXTURE)
        c.wait_for_handler(TENANT, f"/?m={marker}&warm=1", want_body="lifetime",
                           timeout_s=40.0)
    for i in range(3):
        r = c.request(TENANT, f"/?m={marker}&n={i}", timeout=30.0)
        if r.status != 200:
            raise RuntimeError(f"request {marker}/{i} returned {r.status}")

    seen: list[str] = []
    deadline = time.time() + 45.0
    while time.time() < deadline:
        resp = c.log_get(f"{TENANT}/list?limit=200", timeout=15.0)
        if resp.status == 200:
            recs = json.loads(resp.body).get("records", [])
            seen = [r.get("path") or "" for r in recs if f"m={marker}" in (r.get("path") or "")]
            if len(seen) >= 3:
                break
        time.sleep(1.0)
    return seen


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    print("=== a second cluster lifetime keeps its records (rove#266) ===")

    # ── lifetime A ────────────────────────────────────────────────────
    with V2Cluster.spawn("nsA", nodes=1, http_base=19830, raft_base=19930) as c:
        prefix = c.s3_prefix
        c.spawn_log_server(poll_interval_ms=200)
        c.provision(TENANT)
        a_paths = serve_and_collect(c, "A", deploy=True)
        check("lifetime A's records are queryable", len(a_paths) >= 3,
              f"{len(a_paths)} of 3 — nothing else in this smoke means anything if this fails")

    ns = ops_namespace(prefix)
    print(f"    namespace after lifetime A: {ns.stdout.strip().splitlines()[0] if ns.stdout.strip() else ns.returncode}")

    # ── lifetime B: the same store, local state wiped, NO bump ────────
    #
    # The negative control. `spawn` wipes the data dirs (same tag+pid → same
    # paths), so the id counter restarts exactly as it does after a genesis.
    # Wait for the indexer to re-import lifetime A's batches first, so the
    # collision is deterministic rather than a race.
    with V2Cluster.spawn("nsA", nodes=1, http_base=19830, raft_base=19930) as c:
        c.spawn_log_server(poll_interval_ms=200)
        deadline = time.time() + 45.0
        reimported = 0
        while time.time() < deadline:
            resp = c.log_get(f"{TENANT}/list?limit=200", timeout=15.0)
            if resp.status == 200:
                recs = json.loads(resp.body).get("records", [])
                reimported = len([r for r in recs if "m=A" in (r.get("path") or "")])
                if reimported >= 3:
                    break
            time.sleep(1.0)
        check("lifetime A's records are re-imported from S3 into the fresh index",
              reimported >= 3, f"{reimported} of 3 — without this the control proves nothing")
        c.provision(TENANT)
        b_paths = serve_and_collect(c, "B", deploy=True)
        check("WITHOUT a namespace bump, lifetime B's records are LOST (the bug)",
              len(b_paths) < 3,
              f"{len(b_paths)} of 3 survived — if all 3 survived the collision did not "
              f"happen here, so the positive result below would prove nothing")

    # ── lifetime C: same store, wiped again, WITH a bump ──────────────
    bump = ops_namespace(prefix, "--bump")
    check("the namespace bumps", bump.returncode == 0, bump.stdout + bump.stderr)
    print(f"    {bump.stdout.strip().splitlines()[0] if bump.stdout.strip() else ''}")

    os.environ["REWIND_METRICS_PORT"] = str(METRICS_PORT)
    with V2Cluster.spawn("nsA", nodes=1, http_base=19830, raft_base=19930) as c:
        c.spawn_log_server(poll_interval_ms=200)

        # The generation a process is USING is only observable if it says so.
        # An operator (and the deploy script) has to be able to assert that
        # every node came up on the new generation — "we bumped before starting
        # anything" is an ordering argument, not evidence.
        reported = worker_storage_prefix()
        check("the worker reports the bumped prefix on its metrics port",
              reported == f"{prefix}1/", f"reported {reported!r}, expected {prefix + '1/'!r}")

        c.provision(TENANT)
        c_paths = serve_and_collect(c, "C", deploy=True)
        check("WITH a namespace bump, lifetime C keeps all its records", len(c_paths) >= 3,
              f"{len(c_paths)} of 3")
        # And it must not have inherited the previous lifetimes' history: a new
        # generation is a new key space, not a filtered view of the old one.
        resp = c.log_get(f"{TENANT}/list?limit=200", timeout=15.0)
        older = 0
        if resp.status == 200:
            recs = json.loads(resp.body).get("records", [])
            older = len([r for r in recs if "m=A" in (r.get("path") or "")])
        check("the bumped generation does not inherit the previous lifetime's records",
              older == 0, f"{older} of lifetime A's records leaked in")

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s): {', '.join(failures)}")
        return 1
    print("PASSED: a bumped storage namespace keeps a new cluster lifetime's records")
    return 0


if __name__ == "__main__":
    sys.exit(main())
