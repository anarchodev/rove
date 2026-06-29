#!/usr/bin/env python3
"""V2 fresh-voter join smoke — bring a node with NO group instance into an
existing per-tenant group (the bhs-3 case), via the ensureMember sequence.

Distinct from promote_back_smoke (which re-promotes a DEMOTED learner that still
has a stale group): here node 3 stays a VOTER (conf_state voters:[1,2,3]) but its
group instance is GONE (wiped data dir = a fresh node). This reproduces the
"phantom voter" exactly: a configured voter that holds nothing and gets no
replication, because the leader has no group instance on node 3 to replicate to.

The ensureMember sequence (no conf_change — node 3 is already a voter):
  GET  v2-applied-baseline (leader) → {index X, term T}
  GET  v2-snapshot         (leader) → store bundle (⊇ X)
  POST v2-attach           (node 3) → CREATE the group at epoch 1 + load the bundle
  POST v2-apply-snapshot   (node 3, {index:X, term:T}) → data-free raft baseline at X
Then the leader replicates the tail (> X) to node 3 automatically, and a FRESH
write must reach it — proving attach+baseline made it a productive voter.

This is the Phase-3 hard gate for docs/plans/cp-membership-reconciler-plan.md: prove
the compose is safe (epoch/membership) on a throwaway tenant BEFORE the reconciler
drives it on real tenants.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from smoke_lib_v2 import V2Cluster, rpc_wrap, MOVE_SECRET  # noqa: E402

HANDLER_SRC = """\
export function handler() {
    if (request.method === "POST") {
        const body = JSON.parse(request.body || "{}");
        kv.set(body.key ?? "cc/value", body.value ?? "");
        response.status = 204;
        return "";
    }
    return "value:" + (kv.get("cc/value") ?? "none");
}
"""

KEY = "cc/value"
SECRET = ["-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}"]


def _curl_json(url, *, method="GET", data=None):
    args = ["curl", "-s", "-w", "\n%{http_code}", "-m", "15",
            "--http2-prior-knowledge", "-X", method, *SECRET]
    if data is not None:
        args += ["-H", "Content-Type: application/json", "--data", data]
    args.append(url)
    out = subprocess.run(args, capture_output=True, text=True).stdout
    nl = out.rfind("\n")
    return int(out[nl + 1:].strip() or 0), out[:nl]


def _curl_to_file(url, path, *, data=None):
    args = ["curl", "-s", "-o", path, "-w", "%{http_code}", "-m", "20",
            "--http2-prior-knowledge", "-X", "POST", *SECRET]
    if data is not None:
        args += ["-H", "Content-Type: application/json", "--data", data]
    args.append(url)
    return subprocess.run(args, capture_output=True, text=True).stdout.strip()


def _curl_post_file(url, path, *, tenant):
    args = ["curl", "-s", "-w", "%{http_code}", "-m", "20",
            "--http2-prior-knowledge", "-X", "POST", *SECRET,
            "-H", f"X-Rewind-Tenant: {tenant}", "--data-binary", f"@{path}", url]
    return subprocess.run(args, capture_output=True, text=True).stdout.strip()


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("freshvoter", nodes=3) as c:
        def url(node, suffix):
            return f"{c.node_url(node)}/_system/{suffix}"

        def confstate(node):
            st, body = _curl_json(url(node, "v2-confstate?tenant=acme"))
            try:
                return json.loads(body) if st == 200 else None
            except Exception:
                return None

        print("step 1: provision 'acme' + deploy handler + seed a log tail")
        check("provision → 204", c.provision("acme").status == 204)
        lead0 = c.leader_node("acme")
        if lead0 is None:
            check("leader present", False)
            return 1
        try:
            check("deploy → dep_id", bool(c.deploy_handlers("acme", {"index.mjs": rpc_wrap(HANDLER_SRC)}, node=lead0)))
        except RuntimeError as e:
            check("deploy", False, str(e))
            return 1
        c.wait_for_handler("acme", "/?fn=handler", want_body="value:none")
        for i in range(40):
            c.request_retry("acme", "/?fn=handler", method="POST",
                            data=f'{{"value":"v-{i}"}}', want_status=204, deadline_s=10)
        latest = "v-39"
        cs = confstate(lead0)
        check("3 voters at start", cs is not None and len(cs["voters"]) == 3, f"cs={cs}")

        # node 3 = the one that is NOT the leader (so we never kill the leader here).
        lead = c.leader_node("acme")
        victim = next(i for i in range(3) if i != lead)
        vnid = victim + 1
        print(f"       leader=node {lead + 1}; victim (fresh-voter) = node {vnid}")

        print(f"step 2: STOP node {vnid}, WIPE its data dir → a fresh voter with NO group")
        check(f"victim holds data before wipe", latest in c.admin_kv_get("acme", KEY, node=victim).body)
        c.stop_node(victim)
        subprocess.run(["rm", "-rf", str(c.data_dirs[victim])])
        c.start_node(victim)
        time.sleep(3.0)
        # It is a configured voter (others' conf_state says so) but holds nothing
        # and cannot catch up by replication (no local group instance to receive).
        stuck = True
        for _ in range(12):  # ~6s
            rg = c.admin_kv_get("acme", KEY, node=victim)
            if rg.status == 200 and latest in rg.body:
                stuck = False
                break
            time.sleep(0.5)
        check("wiped node is STUCK (no group instance → no replication)", stuck,
              "if it caught up on its own, the repro is wrong")
        cs = confstate(lead)
        check("cluster still lists it as a voter (phantom)", cs is not None and vnid in cs["voters"], f"cs={cs}")

        print("step 3: ensureMember — pull baseline + bundle from the leader")
        lead = c.leader_node("acme")
        st, body = _curl_json(url(lead, "v2-applied-baseline?tenant=acme"))
        check("applied-baseline → 200", st == 200, f"got {st} {body!r}")
        base = json.loads(body) if st == 200 else {"index": 0, "term": 0}
        print(f"       baseline index={base['index']} term={base['term']}")
        with tempfile.NamedTemporaryFile(suffix=".bundle", delete=False) as tf:
            bpath = tf.name
        check("snapshot bundle → 200",
              _curl_to_file(url(lead, "v2-snapshot"), bpath, data='{"tenant":"acme"}') == "200")

        print(f"step 4: v2-attach the bundle on node {vnid} (CREATE group@epoch1 + load) + apply-snapshot")
        check("attach → 204", _curl_post_file(url(victim, "v2-attach"), bpath, tenant="acme") == "204")
        st, body = _curl_json(url(victim, "v2-apply-snapshot"), method="POST",
                              data=json.dumps({"tenant": "acme", "index": base["index"], "term": base["term"]}))
        check("apply-snapshot → 204", st == 204, f"got {st} {body!r}")

        print(f"step 5: ⭐ node {vnid} catches up to the bundle/log state")
        caught = False
        for _ in range(40):  # ~20s
            rg = c.admin_kv_get("acme", KEY, node=victim)
            if rg.status == 200 and latest in rg.body:
                caught = True
                break
            time.sleep(0.5)
        check(f"⭐ node {vnid} now holds the tenant data", caught, "attach+baseline brought the group up")
        cs = confstate(lead)
        check(f"node {vnid} still a voter (not demoted)", cs is not None and vnid in cs["voters"], f"cs={cs}")

        print(f"step 6: ⭐ a FRESH write replicates to node {vnid} (proves the raft handshake)")
        c.request_retry("acme", "/?fn=handler", method="POST",
                        data='{"value":"after-join"}', want_status=204, deadline_s=15)
        repl = False
        for _ in range(60):  # ~30s
            rg = c.admin_kv_get("acme", KEY, node=victim)
            if rg.status == 200 and "after-join" in rg.body:
                repl = True
                break
            time.sleep(0.5)
        check(f"⭐ fresh write replicated to node {vnid}", repl, "fresh voter is productive")

        print(f"step 7: 3-of-3 HA — kill the leader, the others (incl. node {vnid}) keep quorum")
        lead = c.leader_node("acme")
        c.stop_node(lead)
        new_lead = c.leader_node("acme", deadline_s=25.0)
        check("a survivor leads after killing the leader", new_lead is not None and new_lead != lead,
              f"new_lead={new_lead}")
        if new_lead is not None:
            wrote = False
            for _ in range(20):
                if c.admin_kv_put("acme", "cc/post-kill", "ok", node=new_lead).status in (200, 204):
                    wrote = True
                    break
                time.sleep(0.5)
            check("write commits on the surviving 2-of-3 quorum", wrote)

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS fresh-voter join smoke (v2) — a wiped configured-voter with no group "
          "instance was brought in via v2-attach (epoch-1) + apply-snapshot baseline, "
          "caught up, took a fresh write, and the cluster survived a leader kill 3-of-3. ⭐")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
