#!/usr/bin/env python3
"""V2 learner-add smoke — add a node to an existing group as a BORN LEARNER.

Reproduces the __admin__ wall and proves the born-learner fix. Distinct from
fresh_voter_join (a configured VOTER rejoining) and promote_back (a DEMOTED
learner that still holds a stale group): here node 3 is NOT a member at all and is
ADDED back learner-first.

The bug it guards against: a freshly-attached group seeded its ConfState from the
static voter set [1,2,3], so a node added as a LEARNER (leader sees [1,2]+learner3)
was born a VOTER locally → it campaigned, and since the leader treats it as a
learner (ignores its votes/term), it conflict-rejected the leader's appends forever
and never caught up. Worse on a high-term group (the prod __admin__ at term ~219).

The fix: v2-attach honours `X-Rewind-Join-As-Learner: 1` → the local group is BORN
with this node as a non-voting learner (voters = the rest). A learner never
campaigns, so it just follows the leader and catches up. Then `promote` finishes it.

Sequence:
  1. provision acme [1,2,3], deploy, seed; CHURN the term (kill/restart leaders).
  2. remove node 3 (-> [1,2]) + evict its instance: node 3 is now a clean non-member.
  3. AddLearner(3) on the leader (-> voters[1,2] learners[3]).
  4. bootstrap node 3 with X-Rewind-Join-As-Learner: 1 (atomic baseline attach).
  5. ⭐ ASSERT node 3's LOCAL confstate == voters[1,2] learners[3] (BORN LEARNER;
     a born-voter would be [1,2,3] and deadlock).
  6. node 3 catches up (no deadlock); promote(3) -> [1,2,3]; fresh write replicates.

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


def _curl_json(url, *, method="GET", data=None, headers=()):
    args = ["curl", "-s", "-w", "\n%{http_code}", "-m", "15",
            "--http2-prior-knowledge", "-X", method, *SECRET]
    for h in headers:
        args += ["-H", h]
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


def _attach_file(url, path, *, tenant, index, term, as_learner):
    args = ["curl", "-s", "-w", "%{http_code}", "-m", "20",
            "--http2-prior-knowledge", "-X", "POST", *SECRET,
            "-H", f"X-Rewind-Tenant: {tenant}",
            "-H", f"X-Rewind-Baseline-Index: {index}",
            "-H", f"X-Rewind-Baseline-Term: {term}",
            "-H", f"X-Rewind-Join-As-Learner: {'1' if as_learner else '0'}",
            "--data-binary", f"@{path}", url]
    return subprocess.run(args, capture_output=True, text=True).stdout.strip()


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("learneradd", nodes=3) as c:
        def url(node, suffix):
            return f"{c.node_url(node)}/_system/{suffix}"

        def confstate(node):
            st, body = _curl_json(url(node, "v2-confstate?tenant=acme"))
            try:
                return json.loads(body) if st == 200 else None
            except Exception:
                return None

        def confchange(node, node_id, op):
            st, _ = _curl_json(url(node, "v2-confchange"), method="POST",
                               data=json.dumps({"tenant": "acme", "node_id": node_id, "op": op}))
            return st

        print("step 1: provision acme [1,2,3] + deploy + seed")
        check("provision → 204", c.provision("acme").status == 204)
        lead0 = c.leader_node("acme")
        if lead0 is None:
            check("leader present", False); return 1
        try:
            check("deploy → dep_id", bool(c.deploy_handlers("acme", {"index.mjs": rpc_wrap(HANDLER_SRC)}, node=lead0)))
        except RuntimeError as e:
            check("deploy", False, str(e)); return 1
        c.wait_for_handler("acme", "/?fn=handler", want_body="value:none")
        for i in range(20):
            c.request_retry("acme", "/?fn=handler", method="POST", data=f'{{"value":"v-{i}"}}', want_status=204, deadline_s=10)

        print("step 1b: CHURN the term — kill+restart the leader twice (3-voter keeps quorum)")
        for _ in range(2):
            ld = c.leader_node("acme")
            c.stop_node(ld)
            nl = c.leader_node("acme", deadline_s=25.0)
            check(f"re-elected after killing node {ld + 1}", nl is not None and nl != ld, f"nl={nl}")
            c.start_node(ld)
            time.sleep(3.0)
        for i in range(20, 30):
            c.request_retry("acme", "/?fn=handler", method="POST", data=f'{{"value":"v-{i}"}}', want_status=204, deadline_s=10)
        latest = "v-29"

        # node 3 = a non-leader, the one we'll remove then re-add as a learner.
        lead = c.leader_node("acme")
        victim = next(i for i in range(3) if i != lead)
        vnid = victim + 1
        print(f"       leader=node {lead + 1}; learner-add target = node {vnid}")

        print(f"step 2: remove node {vnid} (-> [1,2]) + evict its instance (clean non-member)")
        check("remove → 204", confchange(lead, vnid, "remove") == 204)
        time.sleep(1.0)
        _curl_json(url(victim, "v2-evict"), method="POST", data='{"tenant":"acme"}')
        time.sleep(1.0)
        cs_lead = confstate(lead)
        check("leader confstate is [1,2]", cs_lead is not None and sorted(cs_lead["voters"]) == sorted([n + 1 for n in range(3) if n != victim]),
              f"cs={cs_lead}")
        st, _ = _curl_json(url(victim, "v2-confstate?tenant=acme"))
        check(f"node {vnid} no longer hosts the group", st == 404, f"got {st}")

        print(f"step 3: AddLearner({vnid}) on the leader (-> voters[1,2] learners[{vnid}])")
        check("AddLearner → 204", confchange(lead, vnid, "add") == 204)
        cs_lead = confstate(lead)
        check(f"leader sees node {vnid} as a LEARNER", cs_lead is not None and vnid in cs_lead.get("learners", []),
              f"cs={cs_lead}")

        print(f"step 4: bootstrap node {vnid} as a BORN LEARNER (atomic baseline attach)")
        st, body = _curl_json(url(lead, "v2-applied-baseline?tenant=acme"))
        check("applied-baseline → 200", st == 200, f"got {st} {body!r}")
        base = json.loads(body) if st == 200 else {"index": 0, "term": 0}
        print(f"       baseline index={base['index']} term={base['term']}")
        with tempfile.NamedTemporaryFile(suffix=".bundle", delete=False) as tf:
            bpath = tf.name
        check("snapshot bundle → 200", _curl_to_file(url(lead, "v2-snapshot"), bpath, data='{"tenant":"acme"}') == "200")
        check("attach (join-as-learner) → 204",
              _attach_file(url(victim, "v2-attach"), bpath, tenant="acme",
                           index=base["index"], term=base["term"], as_learner=True) == "204")

        print(f"step 5: ⭐ node {vnid}'s LOCAL confstate must NOT list it as a voter (BORN LEARNER, not [1,2,3])")
        # The anti-deadlock property is that the joining node is NOT born a VOTER:
        # a born-voter campaigns past a high-term leader and conflict-rejects its
        # appends forever. It is born a learner (and, while replaying the log tail,
        # transiently absent from its own confstate between the recorded remove and
        # AddLearner) — but NEVER a voter. catch-up + promote (steps 6-7) prove the
        # functional outcome.
        cs_v = confstate(victim)
        not_born_voter = (cs_v is not None and vnid not in cs_v.get("voters", []))
        check(f"⭐ node {vnid} NOT born as a voter [1,2,3] (born learner)", not_born_voter,
              f"local cs={cs_v} — if it shows {vnid} in voters, the fix regressed")

        print(f"step 6: ⭐ node {vnid} catches up (no deadlock) — holds the latest value")
        caught = False
        for _ in range(40):  # ~20s
            rg = c.admin_kv_get("acme", KEY, node=victim)
            if rg.status == 200 and latest in rg.body:
                caught = True
                break
            time.sleep(0.5)
        check(f"⭐ node {vnid} caught up as a learner", caught, "born-voter would deadlock here")

        print(f"step 7: promote({vnid}) -> [1,2,3] + a fresh write replicates")
        if caught:
            check("promote → 204", confchange(c.leader_node("acme"), vnid, "promote") == 204)
            time.sleep(1.0)
            cs_lead = confstate(c.leader_node("acme"))
            check(f"node {vnid} is a voter again", cs_lead is not None and vnid in cs_lead["voters"], f"cs={cs_lead}")
            c.request_retry("acme", "/?fn=handler", method="POST", data='{"value":"after-promote"}', want_status=204, deadline_s=15)
            repl = False
            for _ in range(40):
                if "after-promote" in c.admin_kv_get("acme", KEY, node=victim).body:
                    repl = True; break
                time.sleep(0.5)
            check(f"⭐ fresh write replicated to node {vnid}", repl)

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS learner-add smoke (v2) — a non-member node was added to a term-churned "
          "group as a BORN LEARNER (X-Rewind-Join-As-Learner), caught up without "
          "deadlocking (where a born-voter would), and was promoted back to a voter. ⭐")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
