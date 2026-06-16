#!/usr/bin/env python3
"""V2 leader-failover smoke (port of `scripts/leader_failover_smoke.py`).

The V1 smoke proved the at-least-once http.send + version-counter dedup
contract across a forced leadership change (schedule delayed http.send, kill
the leader, new leader fires it, the on_result kv write survives) plus a
Phase-6 log-server assertion. On V2 the analog is the per-tenant raft group's
HA: a write commits through the leader, replicates across the 3-node group,
and SURVIVES killing the leader — a promoted follower holds + serves the data
it replicated, and a fresh write commits on the surviving quorum.

This V2 port keeps the ESSENCE (data survives a leader kill; a promoted
follower serves what it replicated; a new write commits post-failover) and
drops the V1-specific infra that doesn't map to the V2 stack: TLS/https,
leader-direct addressing / `discover_leader`, the echo-server + http.send
scheduling machinery, the offline `loop46 kv-get`, and the log-server /
Phase-6 unreplayability assertion (those exercise the http.send + log
pipeline, not the failover-survives-a-kill contract this smoke is named for).

Failover survival is asserted exactly like the V2 reference `three_node_smoke`
leg F: a handler write commits+replicates while the leader is alive, then
after the kill the replicated value is read back on each SURVIVING node via
`admin_kv_get`, and a fresh write commits on the surviving 2-node quorum
(`admin_kv_put` → leader propose) and reads back. (The handler-dispatch serve
path after a kill needs the follower deployment-load path — now wired via the
DP apply observer + on-promotion hook (`src/rewind/main.zig`) and exercised
by `durable_wake_smoke_v2`. This smoke asserts data survival through `v2-kv`
to mirror `three_node_smoke`, orthogonal to handler serving.)

  flow:
    provision acme across the 3-node cluster (group forms on all 3)
    deploy a kv handler (POST writes kv; GET reads it back) — proves deploy
    POST a value through the front door → committed on leader, replicated
    read it back through the front (handler serve works while leader alive)
    find the leader node; KILL it
    ⭐ each surviving node holds the replicated value (admin_kv_get)
    ⭐ a fresh write commits on the surviving 2-node quorum + reads back

Needs S3 env: `set -a; . ./.env; set +a` first.
Build: `zig build rewind rewind-cp rewind-front files-server-v2`
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap, metric_counter, metric_hist_mean_us  # noqa: E402

# A single handler: POST {value} writes kv["failover/value"]; GET reads it
# back. Verbatim-shape kv.get/kv.set bindings (matches on_kv_smoke_v2).
HANDLER_SRC = """\
export function handler() {
    if (request.method === "POST") {
        const body = JSON.parse(request.body || "{}");
        kv.set("failover/value", body.value ?? "");
        response.status = 204;
        return "";
    }
    const v = kv.get("failover/value");
    return "value:" + (v ?? "none");
}
"""

KEY = "failover/value"
VALUE1 = "committed-before-kill"
VALUE2 = "committed-after-failover"


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("failover", nodes=3) as c:
        print("step 1: provision 'acme' across the 3-node cluster")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy the kv handler (release on the current leader)")
        # release() writes _deploy/current through raft — it must hit the
        # group's leader node, else the commit 503s. The group formed at
        # provision time, so a leader already exists; target it.
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

        print("step 3: handler serves through the front door (leader alive)")
        r = c.wait_for_handler("acme", "/?fn=handler", want_body="value:none")
        check("GET /?fn=handler → value:none", r.status == 200 and "value:none" in r.body,
              f"got {r.status} {r.body!r}")
        if r.status != 200:
            c.dump_node_log(grep=["deploy", "loader", "resolve", "error", "warn"])

        print(f"step 4: POST {VALUE1!r} via the handler (commits on leader, replicates)")
        r = c.request_retry("acme", "/?fn=handler", method="POST",
                            data='{"value":"%s"}' % VALUE1, want_status=204)
        check("POST write → 204", r.status == 204, f"got {r.status} {r.body!r}")
        r = c.request_retry("acme", "/?fn=handler", want_body="value:" + VALUE1)
        check("GET reads written value (handler, leader alive)",
              r.status == 200 and VALUE1 in r.body, f"got {r.status} {r.body!r}")
        # And visible on every node's replicated store (sanity before the kill).
        for i in range(3):
            r = c.admin_kv_get("acme", KEY, node=i)
            check(f"admin_kv_get node {i + 1} pre-kill → {VALUE1!r}",
                  r.status == 200 and VALUE1 in r.body, f"got {r.status} {r.body!r}")

        print("step 5: find the leader node, HARD-KILL it (election-timeout failover)")
        lead = c.leader_node("acme")
        check("found a leader node", lead is not None, f"lead={lead}")
        if lead is None:
            for i in range(3):
                c.dump_node_log(node=i, grep=["leader", "elect", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        survivors = [i for i in range(3) if i != lead]

        # Pre-kill baseline of each survivor's leadership-acquisition counter.
        # A clean single re-election bumps exactly one survivor's count by 1;
        # extra bumps would mean spurious elections during the failover.
        import time
        base_acq = {i: (metric_counter(c.metrics(i), "raft_leadership_acquisitions_total") or 0.0)
                    for i in survivors}

        # SIGKILL (NOT SIGTERM) so there's NO graceful transfer_leader handoff —
        # this measures the election-timeout failover, the latency election_tick
        # governs. graceful_transfer_smoke_v2 covers the ~one-heartbeat path.
        print(f"       leader is node {lead + 1} — SIGKILL (no graceful handoff)")
        t0 = time.time()
        c.kill_node(lead)

        # Fine-grained time-to-new-leader (tight single-shot poll, not the 0.4s
        # leader_node loop). This is the number that sizes the election timeout.
        new_lead_timed = None
        failover_s = None
        deadline = t0 + 30.0
        while time.time() < deadline:
            got = c.leader_now("acme", nodes=survivors)
            if got is not None:
                new_lead_timed = got
                failover_s = time.time() - t0
                break
            time.sleep(0.01)
        check("a survivor was elected leader after the kill", new_lead_timed is not None,
              f"new_lead={new_lead_timed}")
        if failover_s is not None:
            # Parseable timing line (grep ELECTION_FAILOVER_S=... from CI logs).
            print(f"       ELECTION_FAILOVER_S={failover_s:.3f}  (kill → survivor leads, "
                  f"node {new_lead_timed + 1 if new_lead_timed is not None else '?'})")

        # Assert the re-election was a CLEAN single election: exactly one
        # survivor's acquisition counter rose, and by exactly 1.
        bumped = []
        for i in survivors:
            now = metric_counter(c.metrics(i), "raft_leadership_acquisitions_total") or 0.0
            delta = now - base_acq[i]
            if delta > 0:
                bumped.append((i, delta))
        check("clean single re-election (exactly one survivor +1 acquisition)",
              len(bumped) == 1 and bumped[0][1] == 1.0,
              f"bumped={[(i + 1, d) for i, d in bumped]}")

        print("step 6: ⭐ data survived the kill — each survivor holds it")
        for i in survivors:
            r = c.admin_kv_get("acme", KEY, node=i)
            check(f"admin_kv_get survivor node {i + 1} → {VALUE1!r}",
                  r.status == 200 and VALUE1 in r.body, f"got {r.status} {r.body!r}")

        print("step 7: ⭐ a fresh write commits on the surviving 2-node quorum")
        # A promoted follower leads the surviving quorum. Find it, then write
        # through its propose path (a follower 503s; retry across re-election).
        new_lead = c.leader_node("acme", deadline_s=25.0)
        check("new leader promoted among survivors",
              new_lead is not None and new_lead in survivors,
              f"new_lead={new_lead}")
        wrote = False
        if new_lead is not None:
            import time
            deadline = time.time() + 25.0
            while time.time() < deadline:
                rp = c.admin_kv_put("acme", KEY, VALUE2, node=new_lead)
                if rp.status in (200, 204):
                    wrote = True
                    break
                # leadership may still be settling; re-resolve + retry
                nl = c.leader_node("acme", deadline_s=2.0)
                if nl is not None and nl in survivors:
                    new_lead = nl
                time.sleep(0.4)
            check("admin_kv_put post-failover committed", wrote,
                  f"last {rp.status} {rp.body!r}")
        if wrote:
            # Read the post-failover value back on every survivor (replicated).
            import time
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
                check(f"admin_kv_get survivor node {i + 1} → {VALUE2!r}",
                      ok_read, f"got {rg.status} {rg.body!r}")

        print("step 8: broadcastTime — heartbeat RTT on the new leader "
              "(the floor the election timeout must clear)")
        # The new leader has been heartbeating the other survivor since the
        # failover, so its histogram has samples. Report mean + n; this is the
        # measured `broadcastTime` input for sizing election/heartbeat timeouts.
        if new_lead is not None:
            m = c.metrics(new_lead)
            hb = metric_hist_mean_us(m, "raft_heartbeat_rtt_us")
            if hb is not None:
                mean_us, n = hb
                # Parseable: grep HEARTBEAT_RTT_MEAN_US / HEARTBEAT_RTT_N.
                print(f"       HEARTBEAT_RTT_MEAN_US={mean_us:.1f}  HEARTBEAT_RTT_N={n}")
                check("heartbeat RTT samples recorded on the new leader", n > 0,
                      f"n={n}")
            else:
                # Not fatal — histogram may be empty if the survivor pair only
                # just settled; surface it rather than failing the smoke.
                print("       (no heartbeat RTT samples yet on the new leader)")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS leader-failover smoke (v2) — data survived the leader kill, "
          "each surviving node held the replicated value, and a fresh write "
          "committed on the surviving quorum.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
