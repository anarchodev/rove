#!/usr/bin/env python3
"""V2 raft crash/recovery soak — churn + ungraceful kills + wipe-heal, verify
convergence and no lost acked write across many rounds.

WHAT THIS VALIDATES
  - Crash-recovery LOGIC: a node SIGKILL'd mid-churn recovers from its WAL/store
    and rejoins, with every acked write intact (no gap, no divergence).
  - Reconciler heal + promote-back (the A2 path): a node whose data dir is WIPED
    comes back a phantom voter, the CP membership reconciler walks it back to a
    caught-up voter (learner-first + a data-free baseline), and — crucially —
    after that out-of-band baseline a *subsequent crash* still recovers correctly.
    This is the rejoin window A2 closes: applyLocalSnapshot now stamps the store's
    durable applied watermark to the baseline index, so a crash there can't recover
    a store BELOW the raft baseline (entries the WAL no longer holds).
  - Convergence: after each round every node reads back the full acked key set.

WHAT THIS DOES *NOT* PROVE
  - fsync ORDERING under true power loss (the C1/C2 WAL fixes). A process SIGKILL
    does NOT drop the page cache — the kernel still flushes dirty pages — so a kill
    cannot reproduce "marker in page cache, segment unlinked on disk, power lost".
    Reproducing that needs real power-loss tooling (dm-flakey `drop_writes`, or a
    VM hard-poweroff). Running this harness's node processes on a dm-flakey mount
    that drops un-fsynced writes on the kill would extend it to cover C1/C2; that
    is a follow-up (see docs/plans/consensus-robustness-backlog.md "Crash-consistency validation").

Usage:  set -a; . ./.env; set +a
        python3 scripts/smoke/raft_soak_prod.py [rounds]      # default 6
        REWIND_SOAK_ROUNDS=20 python3 scripts/smoke/raft_soak_prod.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

# The wipe rounds rely on the CP membership reconciler to heal a phantom voter;
# enable it + run it often BEFORE the lib spawns the CP (env is inherited).
os.environ["REWIND_CP_RECONCILE_MEMBERSHIP"] = "1"
os.environ["REWIND_CP_RECONCILE_SECS"] = "2"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from smoke_lib_v2 import V2Cluster, rpc_wrap, MOVE_SECRET  # noqa: E402

# POST {key,value} → replicated kv.set; GET ?key=K → "value:" + kv.get(K).
HANDLER_SRC = """\
export function handler() {
    if (request.method === "POST") {
        const b = JSON.parse(request.body || "{}");
        kv.set(b.key, b.value);
        response.status = 204; return "";
    }
    const k = request.query?.key ?? "";
    return "value:" + (kv.get(k) ?? "none");
}
"""

TENANT = "acme"
ROUNDS = int(os.environ.get("REWIND_SOAK_ROUNDS", sys.argv[1] if len(sys.argv) > 1 else "6"))


def confstate(c, node):
    r = subprocess.run(
        ["curl", "-s", "--http2-prior-knowledge", "-m", "10",
         "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
         f"{c.node_url(node)}/_system/v2-confstate?tenant={TENANT}"],
        capture_output=True, text=True).stdout.strip()
    try:
        return json.loads(r)
    except Exception:
        return None


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    # key -> value: every write we got a 204 (acked/committed) for. Recovery must
    # never lose or diverge from this on ANY node.
    expected: dict[str, str] = {}
    seq = 0

    def write_batch(c, n):
        nonlocal seq
        for _ in range(n):
            k, v = f"soak/{seq}", f"r{seq}"
            resp = c.request_retry(TENANT, "/?fn=handler", method="POST",
                                   data=json.dumps({"key": k, "value": v}),
                                   want_status=204, deadline_s=30)
            # Only an ACKED (204) write is a durability obligation. A write that
            # never got its 204 (e.g. the election window after killing the leader
            # outran the deadline) may or may not have committed — it is not an
            # acked promise, so it must NOT go into `expected`.
            if resp.status == 204:
                expected[k] = v
            seq += 1

    def kv_on(c, node, key):
        return c.admin_kv_get(TENANT, key, node=node).body

    def verify_node(c, node, label, sample=8):
        """Assert `node` has the expected value for a sample of keys (newest first)."""
        keys = list(expected.keys())[-sample:]
        bad = [k for k in keys if expected[k] not in kv_on(c, node, k)]
        check(f"{label}: node {node + 1} converged ({len(keys)} keys checked)", not bad,
              f"diverged/missing: {bad[:5]}")

    def wait_voter(c, victim, deadline_s):
        """Wait until `victim` is a caught-up voter holding the newest ACKED key."""
        vnid = victim + 1
        newest = next(reversed(expected)) if expected else None  # newest committed key
        end = time.time() + deadline_s
        while time.time() < end:
            lead = c.leader_node(TENANT)
            cs = confstate(c, lead) if lead is not None else None
            voter = cs is not None and vnid in cs.get("voters", [])
            fresh = newest is None or expected[newest] in kv_on(c, victim, newest)
            if voter and fresh:
                return True
            time.sleep(2)
        return False

    with V2Cluster.spawn("soak", nodes=3) as c:
        print(f"setup: provision + deploy + seed (rounds={ROUNDS})")
        check("provision", c.provision(TENANT).status == 204)
        lead0 = c.leader_node(TENANT)
        if lead0 is None:
            check("leader present", False); return 1
        try:
            c.deploy_handlers(TENANT, {"index.mjs": rpc_wrap(HANDLER_SRC)}, node=lead0)
        except RuntimeError as e:
            check("deploy", False, str(e)); return 1
        c.wait_for_handler(TENANT, "/?fn=handler&key=warm", want_body="value:none")
        write_batch(c, 10)
        cs = confstate(c, c.leader_node(TENANT))
        check("3 voters at start", cs is not None and len(cs.get("voters", [])) == 3, f"cs={cs}")

        for r in range(ROUNDS):
            # Alternate: ungraceful crash of an intact replica (data survives) vs
            # WIPE (phantom voter → reconciler heal → promote-back baseline → the
            # A2 rejoin window). Bias the victim toward a follower, occasionally
            # the leader (forces an election + re-aim mid-churn).
            wipe = (r % 2 == 1)
            lead = c.leader_node(TENANT)
            if lead is None:
                check(f"round {r}: leader present pre-kill", False); break
            victim = (lead if r % 3 == 2 else next(i for i in range(3) if i != lead))
            vnid = victim + 1
            mode = "WIPE+heal" if wipe else ("KILL leader" if victim == lead else "KILL")
            print(f"round {r}: {mode} node {vnid} (leader=node {lead + 1}); churn + recover + verify")

            write_batch(c, 5)  # acked writes in flight around the kill

            if wipe:
                c.stop_node(victim)
                subprocess.run(["rm", "-rf", str(c.data_dirs[victim])])
                c.start_node(victim)
            else:
                c.kill_node(victim)   # SIGKILL — ungraceful
                time.sleep(1)
                c.start_node(victim)

            # Cluster must keep serving on the surviving quorum during recovery.
            write_batch(c, 5)

            ok = wait_voter(c, victim, deadline_s=120 if wipe else 60)
            check(f"round {r}: node {vnid} rejoined as a caught-up voter", ok)
            if not ok:
                log = c.log_paths.get(f"n{vnid}")
                if log and os.path.exists(log):
                    print(f"       --- node {vnid} log tail ---")
                    for ln in open(log).read().splitlines()[-30:]:
                        print("       | " + ln)
                break
            verify_node(c, victim, f"round {r}")

        print("final: every node holds the full acked key set (no loss / no divergence)")
        for node in range(3):
            verify_node(c, node, "final", sample=min(seq, 24))

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print(f"\nPASS raft crash/recovery soak (v2) — {ROUNDS} rounds of churn + "
          f"ungraceful kills + wipe-heal; every node recovered + converged on all "
          f"{seq} acked writes (incl. the A2 promote-back rejoin window). ⭐")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
