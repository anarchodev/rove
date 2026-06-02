#!/usr/bin/env python3
"""Phase 3.2 parity gate — `raft_pending_response` commit-arm invariants.

This is the **pre-migration baseline gate** for collapsing the H2
reference path off the hand-rolled `RaftWait` component onto
`effect.Continuation` + a unified `reconcile()` (effect-reification-plan
Phase 3.2). Run it on the current tree to establish green, then re-run
it after the migration to prove byte-identical observable behavior.

It exercises the invariants the migration is most likely to break, on
the `raft_pending_response` arm (`worker_drain.drainEntityArm` →
commit-gated `Cmd.respond` move), which NO existing smoke asserts
directly (the cont / stream / fault / multi-worker arms are covered
elsewhere — see `scripts/phase32_gate.sh` for the full manifest):

  A. Read-your-writes within one handler — a write is visible to a
     later `kv.get` in the same activation (TrackedTxn speculative
     overlay).
  B. Commit-before-response (sequential durability) — once a write
     request returns 200, the value is durably readable by the NEXT
     request. If commit and the response-move ever decoupled (the
     Phase 4.1.3 window the `pending_txns.contains()` gate closes),
     a follow-up read could miss a just-acked write.
  C. Concurrent same-tenant batching, zero dropped writes — N
     concurrent distinct-key writes fold into shared TrackedTxns
     (one batch → one propose → one seq → one txn; first drain arm
     commits, the rest see `.absent`). EVERY write must end up
     durable. Distinct keys (not RMW on one key) so the assertion
     doesn't depend on serializable read-modify-write — only on the
     commit machinery not dropping a parked entity's writeset.

Run with WORKERS=4 (default) to also drive cross-worker concurrent
same-tenant writes through the shared raft commit path (the
kvexp NotChainHead retry posture the multi-worker heldsync comments
flag as historically fragile).

Env: WORKERS (4), CONCURRENCY (64), SEQ_WRITES (16).
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl, expect_eq, expect_status  # noqa: E402

TOKEN = "ba12ba12ba12ba12ba12ba12ba12ba12ba12ba12ba12ba12ba12ba12ba12ba12"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
TENANT = "rpparity"
OPERATOR_EMAIL = "operator@example.com"

WORKERS = int(os.environ.get("WORKERS", "4"))
CONCURRENCY = int(os.environ.get("CONCURRENCY", "64"))
SEQ_WRITES = int(os.environ.get("SEQ_WRITES", "16"))

# index.mjs — a pure write/read handler. `put`/`get` use distinct
# per-index keys so the concurrency test depends only on the commit
# machinery, not on serializable RMW.
HANDLER_SRC = '''
export function ryw(n) {
  // Read-your-writes inside one activation (speculative overlay).
  kv.set("val", String(n));
  return kv.get("val");
}
export function put(i) {
  kv.set("k/" + i, String(i));
  return "ok";
}
export function get(i) {
  return kv.get("k/" + i) || "";
}
export default function () { return "ok"; }
'''

_OP: dict = {}


def q(args: list) -> str:
    return urllib.parse.quote(json.dumps(args))


def provision(c: Cluster, cc, name: str) -> None:
    """Create a tenant via the operator OIDC session (Fork B)."""
    r = curl(cc, f"{c.admin_origin()}/?fn=createInstance&args={q([name])}",
             headers={"Cookie": _OP["cookie"]})
    if r.status not in (200, 201):
        sys.exit(f"FAIL createInstance {name}: {r.status} {r.body}")


def main() -> int:
    cluster = Cluster.spawn(
        tag="raft-pending-parity-smoke",
        http_base=8410,
        raft_base=40420,
        files_port=8414,
        log_port=8413,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        admin_origin_per_node=True,
        workers_per_node=WORKERS,
        # OIDC token-exchange + JWKS hops http.send to loopback IdP.
        worker_extra_args=["--dev-webhook-unsafe"],
    )
    with cluster as c:
        c.discover_leader()
        print(f"ok  leader elected: node {c.leader_idx} "
              f"(workers_per_node={WORKERS})")

        admin_origin = c.admin_origin()
        c.spawn_files_server(
            cors_origin=admin_origin, leader_url=admin_origin,
            extra_args=c.admin_oidc_kv(OPERATOR_EMAIL),
        )
        c.spawn_log_server(cors_origin=admin_origin)
        c.mint_services_token()

        cc = c.curl_ctx(f"auth.{SYSTEM_SUFFIX}", f"{TENANT}.{PUBLIC_SUFFIX}")
        origin = f"https://{TENANT}.{PUBLIC_SUFFIX}:{c.leader_port()}"

        # Wait for the admin tenant to load.
        leader_log = Path(f"/tmp/raft-pending-parity-smoke-worker-{c.leader_idx}.out")
        deadline = time.monotonic() + 15.0
        while time.monotonic() < deadline:
            if leader_log.exists() and \
               "tenant __admin__ loaded deployment" in leader_log.read_text(errors="replace"):
                break
            time.sleep(0.1)

        # Operator OIDC login → createInstance → deploy index.mjs.
        deadline = time.monotonic() + 20.0
        r = curl(cc, f"{admin_origin}/?fn=listInstance", headers={"Origin": admin_origin})
        while time.monotonic() < deadline and r.status != 401:
            time.sleep(0.25)
            r = curl(cc, f"{admin_origin}/?fn=listInstance", headers={"Origin": admin_origin})
        for _ in range(80):
            if curl(cc, c.auth_base() + "/login").status == 200:
                break
            time.sleep(0.25)
        _OP["cookie"] = c.oidc_login(cc, OPERATOR_EMAIL)
        provision(c, cc, TENANT)
        print(f"ok  provisioned {TENANT}")

        dep_id = c.put_file(TENANT, "index.mjs", HANDLER_SRC)
        c.release(TENANT, dep_id)
        deadline = time.monotonic() + 10.0
        target = f"tenant {TENANT} loaded deployment {dep_id}"
        while time.monotonic() < deadline:
            if target in leader_log.read_text(errors="replace"):
                break
            time.sleep(0.1)
        # Confirm the handler actually serves before timing anything.
        r = c.wait_for_handler(TENANT, "/?fn=get&args=" + q([0]), timeout_s=10.0)
        expect_status("handler reachable", 200, r)
        print(f"ok  deployed {TENANT} index.mjs")

        # ── A. Read-your-writes within one activation. ───────────────
        r = curl(cc, f"{origin}/?fn=ryw&args={q([7])}")
        expect_status("A.ryw status", 200, r)
        expect_eq("A.ryw read-your-writes", "7", r.body)

        # ── B. Commit-before-response (sequential durability). ───────
        # Each write returns 200, then the NEXT request must observe it.
        for i in range(1, SEQ_WRITES + 1):
            w = curl(cc, f"{origin}/?fn=put&args={q([i])}")
            expect_status(f"B.put[{i}] status", 200, w)
            rd = curl(cc, f"{origin}/?fn=get&args={q([i])}")
            expect_status(f"B.get[{i}] status", 200, rd)
            if rd.body != str(i):
                sys.exit(f"FAIL B.durability[{i}]: acked write not "
                         f"readable next request (got {rd.body!r})")
        print(f"ok  B.commit-before-response durable across {SEQ_WRITES} seq writes")

        # ── C. Concurrent same-tenant batching, zero dropped writes. ─
        # N distinct keys written concurrently; all must commit.
        keys = list(range(1000, 1000 + CONCURRENCY))

        def do_put(i: int):
            return i, curl(cc, f"{origin}/?fn=put&args={q([i])}")

        with concurrent.futures.ThreadPoolExecutor(max_workers=32) as ex:
            results = list(ex.map(do_put, keys))
        bad = [i for i, resp in results if resp.status != 200]
        if bad:
            sys.exit(f"FAIL C.concurrent puts: {len(bad)} non-200 "
                     f"(first few: {bad[:5]})")
        print(f"ok  C.{CONCURRENCY} concurrent puts all 200")

        # Read every key back — any missing key is a dropped write
        # (a parked entity whose writeset never committed).
        missing = []
        for i in keys:
            rd = curl(cc, f"{origin}/?fn=get&args={q([i])}")
            if rd.status != 200 or rd.body != str(i):
                missing.append((i, rd.status, rd.body))
        if missing:
            sys.exit(f"FAIL C.durability: {len(missing)}/{CONCURRENCY} "
                     f"writes dropped (first few: {missing[:5]})")
        print(f"ok  C.all {CONCURRENCY} concurrent writes durable "
              f"(no dropped writeset)")

        print("PASS raft_pending_parity_smoke")
        return 0


if __name__ == "__main__":
    sys.exit(main())
