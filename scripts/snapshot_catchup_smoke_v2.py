#!/usr/bin/env python3
"""V2 snapshot catch-up smoke — the data-carrying snapshot path.

`snap_catchup_smoke_v2` proves a down follower rejoins and catches up via LOG
REPLAY (the leader keeps its entries, because a down voter pins the min-match
compaction floor). THIS smoke forces the other path: with a tiny WAL-retention
cap (`REWIND_WAL_RETENTION_MAX`), the leader compacts PAST the down follower's
position while it is gone, so on rejoin its needed entries are gone from the log
and it must be caught up by a DATA-CARRYING SNAPSHOT (dump the tenant store →
S3 → fetch → load), the multi-node compaction safety net.

  flow:
    REWIND_WAL_RETENTION_MAX=4 (force compaction past a lagging voter)
    provision + deploy a kv handler across 3 nodes; seed replicates to all 3
    STOP a follower; advance the log well past the retention cap on the quorum
    (the leader compacts past the stopped node → its entries leave the WAL)
    RESTART the follower
    ⭐ it catches up to the latest value — and its log shows
       "v2 snapshot applied" (caught up by snapshot, not log replay)

Needs S3 env: `set -a; . ./.env; set +a` first (snapshots stage in S3).
Build: `zig build rewind rewind-cp rewind-front files-server-v2`
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# Force the snapshot path: retain only a handful of entries below the
# durabilized point, so a follower more than that far behind is compacted past
# (and caught up by a snapshot). Set BEFORE spawn so every node inherits it.
os.environ["REWIND_WAL_RETENTION_MAX"] = "4"

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

HANDLER_SRC = """\
export function handler() {
    if (request.method === "POST") {
        const body = JSON.parse(request.body || "{}");
        kv.set("snap/value", body.value ?? "");
        response.status = 204;
        return "";
    }
    const v = kv.get("snap/value");
    return "value:" + (v ?? "none");
}
"""

KEY = "snap/value"
SEED = "seed-0"
ADVANCE_WRITES = 40  # well past REWIND_WAL_RETENTION_MAX=4


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("snapfetch", nodes=3) as c:
        print("step 1: provision 'acme' across the 3-node cluster")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy the kv handler on the current leader")
        lead = c.leader_node("acme")
        check("leader present pre-deploy", lead is not None, f"lead={lead}")
        try:
            dep_id = c.deploy_handlers("acme", {"index.mjs": rpc_wrap(HANDLER_SRC)},
                                       node=lead if lead is not None else 0)
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            dep_id = None
        if not dep_id:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print(f"step 3: seed {SEED!r}; confirm all 3 nodes hold it")
        r = c.wait_for_handler("acme", "/?fn=handler", want_body="value:none")
        check("handler serves (value:none)", r.status == 200, f"got {r.status} {r.body!r}")
        r = c.request_retry("acme", "/?fn=handler", method="POST",
                            data='{"value":"%s"}' % SEED, want_status=204)
        check("seed write → 204", r.status == 204, f"got {r.status} {r.body!r}")
        for i in range(3):
            rg = c.admin_kv_get("acme", KEY, node=i)
            check(f"node {i + 1} holds seed", rg.status == 200 and SEED in rg.body,
                  f"got {rg.status} {rg.body!r}")

        print("step 4: STOP a follower (not the current leader)")
        lead = c.leader_node("acme")
        check("leader present", lead is not None, f"lead={lead}")
        if lead is None:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        follower = next(i for i in range(3) if i != lead)
        print(f"       leader=node {lead + 1}; stopping follower node {follower + 1}")
        c.stop_node(follower)
        survivors = [i for i in range(3) if i != follower]

        print(f"step 5: advance the log — {ADVANCE_WRITES} writes (compacts past the stopped node)")
        latest = SEED
        for n in range(ADVANCE_WRITES):
            latest = f"advance-{n}"
            r = c.request_retry("acme", "/?fn=handler", method="POST",
                                data='{"value":"%s"}' % latest, want_status=204, deadline_s=10)
        check("final advance write committed", r is not None and r.status == 204,
              f"got {r.status if r else '-'} latest={latest!r}")
        # Give the leader's durabilize+compaction cadence time to truncate past
        # the stopped follower's position.
        time.sleep(2.0)

        print("step 6: surviving nodes hold the latest value")
        for i in survivors:
            rg = c.admin_kv_get("acme", KEY, node=i)
            check(f"survivor node {i + 1} holds {latest!r}",
                  rg.status == 200 and latest in rg.body, f"got {rg.status} {rg.body!r}")

        print("step 7: RESTART the stopped follower")
        c.start_node(follower)

        print("step 8: ⭐ rejoined node catches up — to the post-rejoin latest value")
        post = "after-rejoin"
        r = c.request_retry("acme", "/?fn=handler", method="POST",
                            data='{"value":"%s"}' % post, want_status=204, deadline_s=25)
        check("post-rejoin write committed", r is not None and r.status == 204,
              f"got {r.status if r else '-'}")
        ok_catchup = False
        deadline = time.time() + 40
        rg = None
        while time.time() < deadline:
            rg = c.admin_kv_get("acme", KEY, node=follower)
            if rg.status == 200 and post in rg.body:
                ok_catchup = True
                break
            time.sleep(0.5)
        check(f"⭐ rejoined node {follower + 1} caught up to {post!r}",
              ok_catchup, f"got {rg.status if rg else '-'} {rg.body if rg else ''!r}")

        print("step 9: ⭐ catch-up went through a SNAPSHOT (not log replay)")
        log_path = c.log_paths.get(f"n{follower + 1}")
        snap_applied = False
        if log_path and os.path.exists(log_path):
            with open(log_path) as f:
                snap_applied = any("v2 snapshot applied" in ln for ln in f)
        check("⭐ rejoined node log shows 'v2 snapshot applied'", snap_applied,
              "(no snapshot-applied line — did it catch up via log replay instead?)")
        if failures:
            # Dump the rejoined node's log tail for diagnosis on any failure.
            lp = c.log_paths.get(f"n{follower + 1}")
            if lp and os.path.exists(lp):
                print(f"  --- node {follower + 1} log tail ---")
                with open(lp) as f:
                    for ln in f.read().splitlines()[-45:]:
                        print(f"    | {ln}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS snapshot-catchup smoke (v2) — a follower compacted out of the "
          "log was caught up by a data-carrying snapshot (dump → S3 → fetch → "
          "load) and converged to the latest value. ⭐")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
