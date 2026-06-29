#!/usr/bin/env python3
"""V2 graceful leadership-transfer smoke.

Proves the `transfer_leader` raft best practice (the #1 item in
`docs/plans/raft-best-practices.md`): on a GRACEFUL shutdown (SIGTERM, the `/deploy`
rolling-restart path) the outgoing leader hands each group it leads to a
caught-up follower via `RawNode::transfer_leader`, so a new leader emerges in
~one heartbeat instead of after a full election timeout.

Contrast with `leader_failover_smoke_v2` (a SIGKILL — no chance to hand off;
survivors elect after a timeout) and `three_node_smoke` leg F (also SIGKILL).
Here the leader is stopped with SIGTERM, so `rewind`'s shutdown path runs
`bridge.transferAllLeadership()` before tearing the pump down.

  flow:
    provision 'acme' across a 3-node cluster (group forms on all 3)
    deploy a kv handler, commit a value → replicated to all 3 (followers
      caught up, so the handoff target is current and TimeoutNow is immediate)
    find the leader; SIGTERM it (graceful)
    ⭐ the dead leader's log shows "handed off leadership of N group(s)"
    ⭐ a survivor leads quickly and a fresh write commits + reads back
       (handoff preserved HA, and re-leadership was fast)

Needs S3 env: `set -a; . ./.env; set +a` first.
Build: `zig build rewind rewind-cp rewind-front files-server-v2`
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

HANDLER_SRC = """\
export function handler() {
    if (request.method === "POST") {
        const body = JSON.parse(request.body || "{}");
        kv.set("xfer/value", body.value ?? "");
        response.status = 204;
        return "";
    }
    const v = kv.get("xfer/value");
    return "value:" + (v ?? "none");
}
"""

KEY = "xfer/value"
VALUE1 = "committed-before-transfer"
VALUE2 = "committed-after-transfer"

# Generous upper bound on "a survivor leads again" after a graceful handoff.
# A handoff should be ~one heartbeat; a full election timeout (the thing this
# feature avoids) plus retries would blow well past this. Loose enough not to
# flake on CI noise, tight enough to catch a regression to election-timeout.
FAST_RELEAD_S = 8.0


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("graceful-xfer", nodes=3) as c:
        print("step 1: provision 'acme' across the 3-node cluster")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy the kv handler on the current leader")
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

        print(f"step 3: commit {VALUE1!r}, confirm it replicated to all 3 nodes")
        r = c.wait_for_handler("acme", "/?fn=handler", want_body="value:none")
        check("GET → value:none", r.status == 200 and "value:none" in r.body,
              f"got {r.status} {r.body!r}")
        r = c.request_retry("acme", "/?fn=handler", method="POST",
                            data='{"value":"%s"}' % VALUE1, want_status=204)
        check("POST write → 204", r.status == 204, f"got {r.status} {r.body!r}")
        for i in range(3):
            r = c.admin_kv_get("acme", KEY, node=i)
            check(f"replicated to node {i + 1}",
                  r.status == 200 and VALUE1 in r.body, f"got {r.status} {r.body!r}")

        print("step 4: find the leader, SIGTERM it (graceful)")
        lead = c.leader_node("acme")
        check("found a leader node", lead is not None, f"lead={lead}")
        if lead is None:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        print(f"       leader is node {lead + 1} — SIGTERM (graceful shutdown)")
        t0 = time.time()
        c.stop_node(lead)  # SIGTERM + wait; the handoff runs during shutdown
        survivors = [i for i in range(3) if i != lead]

        print("step 5: ⭐ the dead leader handed off leadership before exiting")
        log_path = c.log_paths.get(f"n{lead + 1}")
        handed_line = None
        if log_path and os.path.exists(log_path):
            with open(log_path) as f:
                for ln in f.read().splitlines():
                    if "handed off leadership of" in ln:
                        handed_line = ln.strip()
        check("dead leader log shows 'handed off leadership of N group(s)'",
              handed_line is not None, handed_line or "(no handoff log line)")
        if handed_line is None:
            c.dump_node_log(node=lead, grep=["leader", "handed", "shut", "drain"])

        print("step 6: ⭐ a survivor leads again quickly (handoff, not a timeout)")
        # Fine-grained (10ms single-shot poll, not the 0.4s leader_node loop) so
        # the measured handoff resolves the ~one-heartbeat transfer rather than
        # rounding up to the poll interval.
        new_lead = None
        relead_s = None
        deadline = t0 + FAST_RELEAD_S + 2.0
        while time.time() < deadline:
            got = c.leader_now("acme", nodes=survivors)
            if got is not None:
                new_lead = got
                relead_s = time.time() - t0
                break
            time.sleep(0.01)
        check("new leader promoted among survivors",
              new_lead is not None and new_lead in survivors,
              f"new_lead={new_lead}, {relead_s if relead_s is not None else float('nan'):.3f}s after SIGTERM")
        if relead_s is not None:
            # Parseable timing line (grep GRACEFUL_HANDOFF_S=... from CI logs).
            print(f"       GRACEFUL_HANDOFF_S={relead_s:.3f}  (SIGTERM → survivor leads, "
                  f"node {new_lead + 1 if new_lead is not None else '?'})")
        check(f"re-leadership was fast (≤{FAST_RELEAD_S}s)",
              relead_s is not None and relead_s <= FAST_RELEAD_S,
              f"{relead_s if relead_s is not None else float('nan'):.3f}s")

        print("step 7: a fresh write commits on the new leader + reads back")
        wrote = False
        rp = None
        if new_lead is not None:
            deadline = time.time() + 20.0
            while time.time() < deadline:
                rp = c.admin_kv_put("acme", KEY, VALUE2, node=new_lead)
                if rp.status in (200, 204):
                    wrote = True
                    break
                nl = c.leader_node("acme", deadline_s=2.0)
                if nl is not None and nl in survivors:
                    new_lead = nl
                time.sleep(0.4)
            check("admin_kv_put post-transfer committed", wrote,
                  f"last {rp.status if rp else '-'} {rp.body if rp else ''!r}")
        if wrote:
            for i in survivors:
                ok_read = False
                rg = None
                deadline = time.time() + 15.0
                while time.time() < deadline:
                    rg = c.admin_kv_get("acme", KEY, node=i)
                    if rg.status == 200 and VALUE2 in rg.body:
                        ok_read = True
                        break
                    time.sleep(0.4)
                check(f"survivor node {i + 1} read-back → {VALUE2!r}",
                      ok_read, f"got {rg.status} {rg.body!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS graceful-transfer smoke (v2) — the leader handed off "
          "leadership on SIGTERM, a survivor led again within "
          f"{FAST_RELEAD_S}s (no election-timeout gap), and a fresh write "
          "committed and replicated on the new leader. ⭐")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
