#!/usr/bin/env python3
"""V2 fresh-voter join smoke — bring a node with NO group instance into an
existing per-tenant group (the bhs-3 case), via the ensureMember sequence.

Reproduces the "phantom voter" exactly: a configured voter whose group
instance is GONE (wiped data dir = a fresh node) — it holds nothing and gets
no replication. The heal is the reconciler's raft-native re-add, driven BY
HAND here (the manual compose gate before the reconciler runs it on real
tenants — docs/architecture/cp-membership-reconciler.md):

  POST v2-confchange{remove}  (leader) → tear out the phantom (its stale-high
       Progress.match is the commit_to-out-of-range hazard; a fresh add
       starts at match=0)
  GET  v2-applied-baseline    (leader) → {epoch, voters, learners, incarnation}
  POST v2-attach              (node 3) → EMPTY: born learner at the leader's
       epoch with the augmented ConfState — no bundle, no baseline
  POST v2-confchange{add}     (leader) → the leader tracks it; the data then
       arrives raft-natively (here: the auto-catchup streams it — the grace
       is forced low so the log tail is compacted and replication alone
       cannot cover it)
  POST v2-confchange{promote} (leader) → back to a voter once caught up

Then a FRESH write must reach it — proving the join made it a productive
voter.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

# Compact past the seeded writes (floor = durabilized − grace), so the reborn
# empty node CANNOT be covered by log replication — the heal must go through
# the auto-catchup's streamed snapshot onto the group born empty.
os.environ["REWIND_SNAPSHOT_GRACE"] = "20"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from smoke_lib_v2 import V2Cluster, rpc_wrap, MOVE_SECRET, attach_join  # noqa: E402

HANDLER_SRC = """\
export function handler() {
    if (request.method === "POST") {
        const body = JSON.parse(request.text || "{}");
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
        check("provision → 200", c.provision("acme").status == 200)
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

        print(f"step 3: REMOVE the phantom voter {vnid} (stale-high match must never meet a fresh empty group)")
        lead = c.leader_node("acme")

        def confchange(node, nid, op):
            st, _ = _curl_json(url(node, "v2-confchange"), method="POST",
                               data=json.dumps({"tenant": "acme", "node_id": nid, "op": op}))
            return st

        check("remove phantom → 204", confchange(lead, vnid, "remove") == 204)
        removed = None
        deadline = time.time() + 20.0
        while time.time() < deadline:
            removed = confstate(lead)
            if removed is not None and vnid not in removed.get("voters", []):
                break
            time.sleep(0.5)
        check("phantom out of the config", removed is not None and vnid not in removed["voters"], f"cs={removed}")

        print(f"step 4: attach node {vnid} EMPTY (born learner, augmented ConfState) + AddLearner")
        st, body = _curl_json(url(lead, "v2-applied-baseline?tenant=acme"))
        check("applied-baseline → 200", st == 200, f"got {st} {body!r}")
        base = json.loads(body) if st == 200 else {}
        # Retired-protocol gate: an attach that still ships a bundle body is
        # rejected BEFORE any instance side-effect.
        bundle_rc = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "10",
             "--http2-prior-knowledge", "-X", "POST", *SECRET,
             "-H", "X-Rewind-Tenant: acme", "-H", "X-Rewind-Incarnation: legacy",
             "--data-binary", "not-a-bundle", url(victim, "v2-attach")],
            capture_output=True, text=True).stdout.strip()
        check("attach with a bundle body → 400 (retired protocol)", bundle_rc == "400", f"got {bundle_rc}")
        # Envelope decode gate (rove#363 class 3): an attach that OMITS the
        # incarnation header is rejected loudly — absence means the sender
        # bypassed the shared encoder; it must never quietly read as legacy.
        check("attach without incarnation → 400",
              attach_join(url(victim, "v2-attach"), tenant="acme",
                          incarnation=None, discard_body=True) == "400")
        # The reconciler's augmented ConfState: the leader's membership plus
        # this node as a learner.
        aug_learners = sorted(set(base.get("learners", [])) | {vnid})
        check("attach EMPTY → 204",
              attach_join(url(victim, "v2-attach"), tenant="acme",
                          epoch=base.get("epoch"), as_learner=True,
                          voters=base.get("voters"), learners=aug_learners,
                          incarnation=base.get("incarnation", "")) == "204")
        check("AddLearner → 204", confchange(lead, vnid, "add") == 204)

        print(f"step 5: ⭐ the auto-catchup streams the store onto the empty-born node {vnid}")
        caught = False
        for _ in range(80):  # ~40s — trigger fires ≤100ms; dump+stream is the tail
            rg = c.admin_kv_get("acme", KEY, node=victim)
            if rg.status == 200 and latest in rg.body:
                caught = True
                break
            time.sleep(0.5)
        check(f"⭐ node {vnid} now holds the tenant data", caught,
              "the streamed catch-up brought the empty-born group up")

        print(f"step 5b: promote node {vnid} back to a voter")
        promoted = False
        deadline = time.time() + 30.0
        while time.time() < deadline:
            if confchange(lead, vnid, "promote") == 204:
                cs = confstate(lead)
                if cs is not None and vnid in cs.get("voters", []):
                    promoted = True
                    break
            time.sleep(1.0)
        check(f"node {vnid} a voter again", promoted, f"cs={confstate(lead)}")

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
    print("\nPASS fresh-voter join smoke (v2) — a wiped configured-voter was removed, "
          "re-attached EMPTY as a born learner, caught up via the streamed auto-catchup, "
          "was promoted back, took a fresh write, and the cluster survived a leader "
          "kill 3-of-3. ⭐")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
