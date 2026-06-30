#!/usr/bin/env python3
"""V2 membership-from-snapshot smoke — a joiner learns its membership from the
baseline's ConfState, not the static REWIND_VOTERS (raft-native-alignment Phase 2d).

raft-rs `restore` rebuilds a group's membership from the snapshot's ConfState
(`raft.rs:2629`), and DISCARDS a snapshot whose ConfState omits the recipient
(`raft.rs:2581`). Phase 2c/2d make `apply_local_snapshot` carry an optional
caller-supplied ConfState (the source leader's, read consistently from the
extended `v2-applied-baseline`) and `v2-attach` forward it as `X-Rewind-Voters` /
`X-Rewind-Learners`, so a joining node adopts the real membership from the
snapshot instead of a static env voter set.

Sequence:
  1. provision acme [1,2,3], deploy, seed.
  2. remove a follower from the group + evict it → a clean non-member.
  3. AddLearner(victim) on the leader → its ConfState now lists victim as a learner.
  4. ⭐ v2-applied-baseline returns {index, term, epoch, voters, learners} in ONE
     read (closes the index-vs-confstate TOCTOU); victim is in learners.
  5. ⭐ attach with a ConfState that OMITS victim → 409 (the -6 guard enforces
     raft.rs:2581). This is the distinguisher: WITHOUT 2d the headers are ignored
     and the attach 204s via the static born-learner path.
  6. attach with the correct ConfState (from the baseline) → 204.
  7. ⭐ victim's LOCAL ConfState now equals the leader's — it learned membership
     from the snapshot. Promote it; a fresh write replicates.

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


def _attach(url, path, *, tenant, index, term, epoch, voters=None, learners=None):
    # -o /dev/null so a non-2xx response BODY (the error message) doesn't get
    # concatenated ahead of %{http_code} in stdout.
    args = ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "20",
            "--http2-prior-knowledge", "-X", "POST", *SECRET,
            "-H", f"X-Rewind-Tenant: {tenant}",
            "-H", f"X-Rewind-Baseline-Index: {index}",
            "-H", f"X-Rewind-Baseline-Term: {term}",
            "-H", f"X-Rewind-Epoch: {epoch}",
            "-H", "X-Rewind-Join-As-Learner: 1"]
    if voters is not None:
        args += ["-H", "X-Rewind-Voters: " + ",".join(str(v) for v in voters)]
    if learners is not None:
        args += ["-H", "X-Rewind-Learners: " + ",".join(str(l) for l in learners)]
    args += ["--data-binary", f"@{path}", url]
    return subprocess.run(args, capture_output=True, text=True).stdout.strip()


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("memsnap", nodes=3) as c:
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
            check("deploy → dep_id", bool(c.deploy_handlers(
                "acme", {"index.mjs": rpc_wrap(HANDLER_SRC)}, node=lead0)))
        except RuntimeError as e:
            check("deploy", False, str(e)); return 1
        c.wait_for_handler("acme", "/?fn=handler", want_body="value:none")
        for i in range(10):
            c.request_retry("acme", "/?fn=handler", method="POST",
                            data=f'{{"value":"v-{i}"}}', want_status=204, deadline_s=10)

        lead = c.leader_node("acme")
        victim = next(i for i in range(3) if i != lead)
        vnid = victim + 1
        print(f"       leader=node {lead + 1}; victim = node {vnid}")

        print(f"step 2: remove node {vnid} + evict → clean non-member")
        check("remove → 204", confchange(lead, vnid, "remove") == 204)
        time.sleep(1.0)
        _curl_json(url(victim, "v2-evict"), method="POST", data='{"tenant":"acme"}')
        time.sleep(1.0)

        print(f"step 3: AddLearner({vnid}) → leader ConfState lists it as a learner")
        lead = c.leader_node("acme")
        check("AddLearner → 204", confchange(lead, vnid, "add") == 204)
        cs_lead = confstate(lead)
        check(f"leader sees node {vnid} as a learner",
              cs_lead is not None and vnid in cs_lead.get("learners", []), f"cs={cs_lead}")

        print("step 4: ⭐ v2-applied-baseline returns the ConfState in one read")
        st, body = _curl_json(url(lead, "v2-applied-baseline?tenant=acme"))
        check("applied-baseline → 200", st == 200, f"got {st} {body!r}")
        base = json.loads(body) if st == 200 else {}
        check("baseline carries voters+learners",
              "voters" in base and "learners" in base, f"base={base}")
        check(f"⭐ baseline learners include node {vnid} (consistent read)",
              vnid in base.get("learners", []), f"base={base}")
        with tempfile.NamedTemporaryFile(suffix=".bundle", delete=False) as tf:
            bpath = tf.name
        check("snapshot bundle → 200",
              _curl_to_file(url(lead, "v2-snapshot"), bpath, data='{"tenant":"acme"}') == "200")

        print(f"step 5: ⭐ attach with a ConfState OMITTING node {vnid} → 409 (the -6 guard)")
        rc = _attach(url(victim, "v2-attach"), bpath, tenant="acme",
                     index=base["index"], term=base["term"], epoch=base.get("epoch", 1),
                     voters=base["voters"], learners=[])  # victim deliberately omitted
        check("⭐ attach with self-omitting ConfState → 409 (membership is read + enforced; "
              "pre-2d this 204s via the static path)", rc == "409", f"got {rc}")

        print(f"step 6: attach with the correct ConfState (from the baseline) → 204")
        rc = _attach(url(victim, "v2-attach"), bpath, tenant="acme",
                     index=base["index"], term=base["term"], epoch=base.get("epoch", 1),
                     voters=base["voters"], learners=base["learners"])
        check("attach with baseline ConfState → 204", rc == "204", f"got {rc}")

        print(f"step 7: ⭐ node {vnid} adopted the leader's membership from the snapshot")
        cs_v, cs_l = None, confstate(lead)
        for _ in range(20):
            cs_v = confstate(victim)
            if cs_v is not None:
                break
            time.sleep(0.3)
        cs_l = confstate(lead)
        ok = (cs_v is not None and cs_l is not None
              and sorted(cs_v.get("voters", [])) == sorted(cs_l.get("voters", []))
              and sorted(cs_v.get("learners", [])) == sorted(cs_l.get("learners", [])))
        check(f"⭐ node {vnid} ConfState == leader's (learned from the snapshot, not REWIND_VOTERS)",
              ok, f"victim={cs_v} leader={cs_l}")

        print(f"step 8: promote node {vnid} → voter; a fresh write replicates")
        # Wait for it to catch up (last_index vs leader_last) before promoting.
        time.sleep(2.0)
        if confchange(c.leader_node("acme"), vnid, "promote") == 204:
            check("promote → 204", True)
        w = c.request_retry("acme", "/?fn=handler", method="POST",
                            data='{"key":"final/marker","value":"after-2d"}',
                            want_status=204, deadline_s=15)
        check("final write accepted (204)", w.status == 204, f"got {w.status}")
        repl = False
        for _ in range(40):
            if "after-2d" in c.admin_kv_get("acme", "final/marker", node=victim).body:
                repl = True; break
            time.sleep(0.5)
        check(f"⭐ fresh write replicated to node {vnid}", repl)

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS membership-from-snapshot smoke (v2) — a joiner adopted its membership "
          "from the baseline's ConfState (the native raft-rs mechanism), the self-omitting "
          "ConfState was rejected (raft.rs:2581), and a fresh write replicated. ⭐")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
