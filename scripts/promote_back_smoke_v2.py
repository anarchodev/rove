#!/usr/bin/env python3
"""V2 conf_change Phase-2 smoke — out-of-band PROMOTE-BACK of a below-floor learner.

The hard half of Phase 2. A voter demoted to a learner falls BELOW the
voters-only WAL-compaction floor (the point of demoting — the floor advances
past it so the leader compacts). When that node returns it can NOT catch up by
replication (the leader truncated the entries it needs) and rove has no
in-protocol snapshot transport — its leader-side Progress is stuck forever.

Promote-back rejoins it out-of-band, leader never sending a snapshot:
  GET  v2-applied-baseline (leader) → {index X, term T}
  GET  v2-snapshot         (leader) → a store bundle (⊇ X), saved to a file
  POST v2-load-replace     (learner) → overwrite-load the bundle (store ← fresh)
  POST v2-apply-snapshot   (learner, {index:X, term:T}) → install a DATA-FREE raft
       baseline at X locally → the leader can now replicate the tail (> X)
  POST v2-confchange{promote} (leader) → back to a voter
Then a FRESH write must replicate to the rejoined node — proving the raft
handshake (not just the bundle) brought it back as a productive voter.

Setup forces the below-floor condition deterministically: demote node 3, STOP
it, advance + compact the log well past its frozen match, then restart it.

Needs S3 env: `set -a; . ./.env; set +a` first.
Build: `zig build rewind rewind-cp rewind-front files-server-v2`
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
        if (body.del) { kv.delete(body.del); response.status = 204; return ""; }
        kv.set(body.key ?? "cc/value", body.value ?? "");
        response.status = 204;
        return "";
    }
    const v = kv.get("cc/value");
    return "value:" + (v ?? "none");
}
"""

KEY = "cc/value"
PHANTOM = "cc/phantom"
SECRET = ["-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}"]


def _curl_json(url, *, method="GET", data=None, tenant=None):
    args = ["curl", "-s", "-w", "\n%{http_code}", "-m", "15",
            "--http2-prior-knowledge", "-X", method, *SECRET]
    if data is not None:
        args += ["-H", "Content-Type: application/json", "--data", data]
    if tenant:
        args += ["-H", f"X-Rewind-Tenant: {tenant}"]
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


def _curl_from_file(url, path, *, tenant):
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

    with V2Cluster.spawn("promoteback", nodes=3) as c:
        def url(node, suffix):
            return f"{c.node_url(node)}/_system/{suffix}"

        def confchange(node, node_id, op):
            return _curl_json(url(node, "v2-confchange"), method="POST",
                              data=json.dumps({"tenant": "acme", "node_id": node_id, "op": op}))[0]

        def confstate(node):
            st, body = _curl_json(url(node, "v2-confstate?tenant=acme"))
            try:
                return json.loads(body) if st == 200 else None
            except Exception:
                return None

        def wait_membership(node, node_id, *, learner, deadline_s=25.0):
            end = time.time() + deadline_s
            last = None
            while time.time() < end:
                last = confstate(node)
                if last is not None:
                    where = last["learners"] if learner else last["voters"]
                    if node_id in where:
                        return last
                time.sleep(0.4)
            return last

        print("step 1: provision 'acme' + deploy the kv handler")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status}")
        lead0 = c.leader_node("acme")
        if lead0 is None:
            check("leader present", False)
            return 1
        try:
            dep_id = c.deploy_handlers("acme", {"index.mjs": rpc_wrap(HANDLER_SRC)}, node=lead0)
            check("deploy → dep_id", bool(dep_id))
        except RuntimeError as e:
            check("deploy", False, str(e))
            return 1

        print("step 2: seed cc/value + cc/phantom; confirm 3 voters hold the phantom")
        c.wait_for_handler("acme", "/?fn=handler", want_body="value:none")
        c.request_retry("acme", "/?fn=handler", method="POST", data='{"value":"seed"}', want_status=204)
        c.request_retry("acme", "/?fn=handler", method="POST",
                        data=f'{{"key":"{PHANTOM}","value":"present"}}', want_status=204)
        cs = confstate(lead0)
        check("3 voters at start", cs is not None and len(cs["voters"]) == 3, f"cs={cs}")

        print("step 3: demote node 3 → learner, then STOP it")
        lead = c.leader_node("acme")
        victim = 2 if lead != 2 else next(i for i in range(3) if i != lead)
        vnid = victim + 1
        print(f"       leader=node {lead + 1}; victim=node {vnid}")
        check("demote → 204", confchange(lead, vnid, "demote") == 204)
        cs = wait_membership(lead, vnid, learner=True)
        check(f"node {vnid} is a learner", cs is not None and vnid in cs["learners"], f"cs={cs}")
        check(f"victim holds {PHANTOM} before it dies",
              c.admin_kv_get("acme", PHANTOM, node=victim).status == 200)
        c.stop_node(victim)

        print("step 4: advance + compact past the victim's match; DELETE the phantom")
        for i in range(150):
            c.request_retry("acme", "/?fn=handler", method="POST",
                            data=f'{{"value":"adv-{i}"}}', want_status=204, deadline_s=10)
        latest = "adv-149"
        # Delete a key the (stopped) victim still holds — it must NOT survive on
        # the rejoined node, or the promoted-back voter diverges from the cluster.
        c.request_retry("acme", "/?fn=handler", method="POST",
                        data=f'{{"del":"{PHANTOM}"}}', want_status=204, deadline_s=10)
        # Let several durabilize+compact cycles (500ms each) truncate below the
        # victim's stale match, so on restart it is genuinely below the floor.
        time.sleep(8.0)

        print(f"step 5: RESTART node {vnid} — recovers as a stale learner below the floor")
        c.start_node(victim)
        cs = wait_membership(victim, vnid, learner=True, deadline_s=30.0)
        check(f"node {vnid} back as a learner", cs is not None and vnid in cs["learners"], f"cs={cs}")
        # ⭐ It must be STUCK: replication alone cannot fix a below-floor learner,
        # so its store stays stale for a while.
        stuck = True
        for _ in range(12):  # ~6s
            rg = c.admin_kv_get("acme", KEY, node=victim)
            if rg.status == 200 and latest in rg.body:
                stuck = False
                break
            time.sleep(0.5)
        check("victim STUCK below floor (replication alone can't catch up)", stuck,
              "would-be false positive if plain replication caught it up")

        print("step 6: promote-back — pull baseline + bundle from the leader")
        lead = c.leader_node("acme")
        st, body = _curl_json(url(lead, "v2-applied-baseline?tenant=acme"))
        check("applied-baseline → 200", st == 200, f"got {st} {body!r}")
        base = json.loads(body) if st == 200 else {"index": 0, "term": 0}
        print(f"       baseline index={base['index']} term={base['term']}")
        with tempfile.NamedTemporaryFile(suffix=".bundle", delete=False) as tf:
            bpath = tf.name
        code = _curl_to_file(url(lead, "v2-snapshot"), bpath, data='{"tenant":"acme"}')
        check("snapshot bundle → 200", code == "200", f"got {code}")

        print("step 7: load-replace into the victim + install the raft baseline")
        code = _curl_from_file(url(victim, "v2-load-replace"), bpath, tenant="acme")
        check("load-replace → 204", code == "204", f"got {code}")
        st, body = _curl_json(url(victim, "v2-apply-snapshot"), method="POST",
                              data=json.dumps({"tenant": "acme", "index": base["index"], "term": base["term"]}))
        check("apply-snapshot → 204", st == 204, f"got {st} {body!r}")

        print("step 8: promote the victim back to a voter")
        check("promote → 204", confchange(lead, vnid, "promote") == 204)
        cs = wait_membership(lead, vnid, learner=False)
        check(f"node {vnid} is a voter again", cs is not None and vnid in cs["voters"], f"cs={cs}")

        print("step 9: ⭐ a FRESH write replicates to the rejoined voter")
        # Historical state came via the bundle; this proves the raft handshake —
        # the leader replicates a NEW entry (> baseline) and the victim applies it.
        c.request_retry("acme", "/?fn=handler", method="POST",
                        data='{"value":"after-rejoin"}', want_status=204, deadline_s=15)
        caught = False
        for _ in range(60):  # ~30s
            rg = c.admin_kv_get("acme", KEY, node=victim)
            if rg.status == 200 and "after-rejoin" in rg.body:
                caught = True
                break
            time.sleep(0.5)
        check("⭐ fresh write replicated to the rejoined voter", caught,
              "the below-floor learner is a productive voter again")

        # ⭐ The phantom key deleted on the cluster while the victim was gone must
        # NOT survive the replace-load — else the rejoined voter diverges.
        pg = c.admin_kv_get("acme", PHANTOM, node=victim)
        gone = pg.status != 200 or not pg.body or "present" not in pg.body
        check("⭐ source-deleted phantom key is GONE on the rejoined node (no divergence)",
              gone, f"got {pg.status} {pg.body!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS promote-back smoke (v2) — a below-floor learner rejoined out-of-band "
          "(bundle + data-free local snapshot baseline), was promoted back to a voter, "
          "and a fresh write replicated to it from the leader's log. ⭐")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
