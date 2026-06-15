#!/usr/bin/env python3
"""V2 dispatch-gate smoke — strict-serializable leader reads.

The worker's dispatch-gate (src/js/worker_dispatch.zig) enforces that ONLY the
leader of a tenant's raft group runs the handler: a non-leader 421s BEFORE the
handler executes, so a read (which never reaches the propose-time leader-gate)
can't serve from a lagging follower. This smoke proves the contract directly,
which `three_node_smoke` / `leader_failover_smoke_v2` cannot — those read via
the internal `/_system/v2-kv` endpoint, which short-circuits before the gate.

  flow:
    provision acme across a 3-node cluster (group forms on all 3)
    deploy a kv handler (POST writes kv; GET reads it back) on the leader
    POST a value through the front → committed on leader, replicated
    confirm every node holds the replicated value (so followers have applied
      the deploy + the write — they'll reach the gate, not 404/503)
    ⭐ a CUSTOMER GET sent DIRECTLY to each node (Host=tenant, the handler
      dispatch path) returns 200 on the leader and 421 on each follower
    ⭐ the same GET via the front returns 200 (the front re-aims the 421 to
      the leader — the read is served, strict-serializable)
    ⭐ a CUSTOMER write sent directly to a follower also 421s (one gate for
      reads and writes)

Needs S3 env: `set -a; . ./.env; set +a` first.
Build: `zig build rewind rewind-cp rewind-front files-server-v2`
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

HANDLER_SRC = """\
export function handler() {
    if (request.method === "POST") {
        const body = JSON.parse(request.body || "{}");
        kv.set("gate/value", body.value ?? "");
        response.status = 204;
        return "";
    }
    const v = kv.get("gate/value");
    return "value:" + (v ?? "none");
}
"""

KEY = "gate/value"
VALUE = "served-by-leader-only"


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("gate", nodes=3) as c:
        host = c.host_for("acme")

        print("step 1: provision 'acme' across the 3-node cluster")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy the kv handler on the group leader")
        lead0 = c.leader_node("acme")
        check("leader present pre-deploy", lead0 is not None, f"lead={lead0}")
        try:
            dep_id = c.deploy_handlers("acme", {"index.mjs": rpc_wrap(HANDLER_SRC)},
                                       node=lead0 if lead0 is not None else 0)
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            dep_id = None
        if not dep_id:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 3: handler serves through the front (leader alive)")
        r = c.wait_for_handler("acme", "/?fn=handler", want_body="value:none")
        check("GET /?fn=handler (front) → value:none",
              r.status == 200 and "value:none" in r.body, f"got {r.status} {r.body!r}")

        print(f"step 4: POST {VALUE!r} via the front (commits on leader, replicates)")
        r = c.request_retry("acme", "/?fn=handler", method="POST",
                            data='{"value":"%s"}' % VALUE, want_status=204)
        check("POST write → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 5: every node holds the replicated value (gate-reachable)")
        # admin_kv_get hits /_system/v2-kv (ungated) — it confirms the follower
        # has APPLIED the write, which implies it also applied the earlier
        # deploy marker, so a customer GET will reach the gate (not 404/503).
        for i in range(3):
            ok_rep = False
            rg = None
            deadline = time.time() + 15.0
            while time.time() < deadline:
                rg = c.admin_kv_get("acme", KEY, node=i)
                if rg.status == 200 and VALUE in rg.body:
                    ok_rep = True
                    break
                time.sleep(0.3)
            check(f"node {i + 1} replicated the value", ok_rep,
                  f"got {rg.status} {rg.body!r}")

        print("step 6: find the leader of acme's group")
        lead = c.leader_node("acme")
        check("found a leader node", lead is not None, f"lead={lead}")
        if lead is None:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        followers = [i for i in range(3) if i != lead]
        print(f"       leader is node {lead + 1}; followers {[f + 1 for f in followers]}")

        print("step 7: ⭐ CUSTOMER GET direct to each node — leader 200, followers 421")
        rl = c.node_request("/?fn=handler", node=lead, host=host)
        check(f"direct GET leader (node {lead + 1}) → 200 value",
              rl.status == 200 and VALUE in rl.body, f"got {rl.status} {rl.body!r}")
        for i in followers:
            rf = c.node_request("/?fn=handler", node=i, host=host)
            check(f"direct GET follower (node {i + 1}) → 421",
                  rf.status == 421, f"got {rf.status} {rf.body!r}")

        print("step 8: ⭐ same GET via the front → 200 (front re-aims the 421 to leader)")
        r = c.request_retry("acme", "/?fn=handler", want_body="value:" + VALUE)
        check("front GET → 200 value (strict-serializable read)",
              r.status == 200 and VALUE in r.body, f"got {r.status} {r.body!r}")

        print("step 9: ⭐ CUSTOMER write direct to a follower → 421 (one gate, reads+writes)")
        wf = c.node_request("/?fn=handler", node=followers[0], method="POST",
                            data='{"value":"x"}', host=host)
        check(f"direct POST follower (node {followers[0] + 1}) → 421",
              wf.status == 421, f"got {wf.status} {wf.body!r}")

        # check_quorum × hibernation: a leader that idles past the hibernate
        # window stops ticking and so never evaluates check_quorum — it must
        # NOT spuriously step down. Idle quietly, then confirm leadership is
        # unchanged and the gate still serves (the group wakes cleanly, the
        # leader is still the leader, followers still 421).
        print("step 10: ⭐ idle past hibernation — leader stable under check_quorum")
        time.sleep(4.0)  # exceed the (default 2s) hibernate window
        lead2 = c.leader_node("acme")
        check("leader unchanged after idle (no spurious step-down)",
              lead2 == lead, f"was node {lead + 1}, now {None if lead2 is None else lead2 + 1}")
        r = c.node_request("/?fn=handler", node=lead, host=host)
        check(f"direct GET leader (node {lead + 1}) after idle → 200 value",
              r.status == 200 and VALUE in r.body, f"got {r.status} {r.body!r}")
        rf = c.node_request("/?fn=handler", node=followers[0], host=host)
        check(f"direct GET follower (node {followers[0] + 1}) after idle → 421",
              rf.status == 421, f"got {rf.status} {rf.body!r}")

        # NOTE on the front leader cache (proxy.zig `LeaderCache`): the front
        # learns the leader from a 421→success re-aim and starts subsequent
        # requests for the host there, removing the redirect tax. Its LOGIC is
        # unit-tested deterministically (note/startIdx/drop/stale-fallback in
        # proxy.zig). It isn't asserted here because exercising it end-to-end
        # needs the elected leader at a non-zero node index (uncontrollable),
        # and serving a customer handler right after a forced leadership change
        # depends on the promoted node's deployment-load path — an orthogonal,
        # timing-sensitive concern that `leader_failover_smoke_v2` deliberately
        # avoids too. The re-aim itself is observable in production via the
        # `[front] 421 re-aim` info log (rare once the cache is warm).

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS dispatch-gate smoke (v2) — only the leader runs the handler; "
          "followers 421 customer reads AND writes before executing, and the "
          "front re-aims to the leader so reads stay strict-serializable.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
