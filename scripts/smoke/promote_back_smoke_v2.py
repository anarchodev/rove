#!/usr/bin/env python3
"""V2 promote-back smoke — a below-floor learner heals via the AUTO catch-up.

A voter demoted to a learner falls BELOW the WAL-compaction floor (the point
of demoting — the floor advances past it so the leader compacts; the grace is
forced LOW here so the churn genuinely truncates past it). When that node
returns it can NOT catch up by replication (the leader truncated the entries
it needs). The recovery is the streamed snapshot catch-up, fully automatic:
the leader's trigger detects the below-floor peer, streams its store to the
peer's `v2-snapshot-stream` in REPLACE mode (every stale pair cleared — a key
the cluster deleted while the learner was gone must NOT survive as a phantom)
with the data-free baseline + ConfState in headers, and the peer installs at
END_STREAM. Then `v2-confchange{promote}` brings it back to a voter and a
FRESH write must replicate to it.

The crash-in-window leg: the raft baseline is in the WAL and the streamed
data is in LMDB, but the store watermark may lag. A crash right after the
rejoin must recover cleanly (raft drives applied from the WAL compaction
marker, not the store watermark) — no applied>committed panic, no
compacted-gap, data intact.

Setup forces the below-floor condition deterministically: demote a follower,
STOP it, advance + compact the log well past its frozen match, restart it.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

# Force mechanism-A compaction past the churned writes (floor = durabilized −
# grace), so the returning learner is GENUINELY below the floor and only the
# streamed catch-up can recover it.
os.environ["REWIND_SNAPSHOT_GRACE"] = "20"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from smoke_lib_v2 import V2Cluster, rpc_wrap, MOVE_SECRET  # noqa: E402

HANDLER_SRC = """\
export function handler() {
    if (request.method === "POST") {
        const body = JSON.parse(request.text || "{}");
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
        check("provision → 200", r.status == 200, f"got {r.status}")
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

        print(f"step 6: ⭐ the AUTO catch-up streams the store onto the below-floor learner")
        healed = False
        for _ in range(80):  # ~40s — trigger ≤100ms; dump+stream is the tail
            # Keep the group AWAKE on the live nodes: the trigger scans only the
            # active set, so a fully idle tenant's leader hibernates and the
            # heal waits for the victim's leaderless escalation (~40s) instead.
            # Production tenants have traffic; model it (a v2-kv GET nudges the
            # group awake on the node it lands on).
            for n in range(3):
                if n != victim:
                    c.admin_kv_get("acme", KEY, node=n)
            rg = c.admin_kv_get("acme", KEY, node=victim)
            if rg.status == 200 and latest in rg.body:
                healed = True
                break
            time.sleep(0.5)
        check(f"⭐ node {vnid} auto-caught-up to the latest value (streamed replace)", healed)

        print("step 8: promote the victim back to a voter")
        lead = c.leader_node("acme")
        check("promote → 204", confchange(lead, vnid, "promote") == 204)
        cs = wait_membership(lead, vnid, learner=False)
        check(f"node {vnid} is a voter again", cs is not None and vnid in cs["voters"], f"cs={cs}")

        print("step 8b: ⭐ CRASH the victim in the rejoin window (before any heal write)")
        # The raft baseline is in the WAL, the streamed data is in LMDB, but the
        # store watermark may still be stale. Recovery must reconcile (raft drives
        # applied from the WAL compaction marker, not the store watermark) — no
        # applied>committed panic, no compacted-gap. Restart and confirm it's
        # back as a voter member that still holds the streamed data.
        # Confirm the victim itself persisted the promote first, so the crash
        # lands AFTER the rejoin completed but BEFORE any healing write.
        check("victim sees itself a voter pre-crash",
              wait_membership(victim, vnid, learner=False, deadline_s=20.0) is not None)
        c.stop_node(victim)
        time.sleep(1.0)
        c.start_node(victim)
        cs = wait_membership(victim, vnid, learner=False, deadline_s=30.0)
        check(f"node {vnid} recovered as a voter after a rejoin-window crash",
              cs is not None and vnid in cs["voters"], f"cs={cs}")
        rg = c.admin_kv_get("acme", KEY, node=victim)
        check("recovered victim still holds the streamed data", rg.status == 200 and latest in rg.body,
              f"got {rg.status} {rg.body!r}")

        print("step 9: ⭐ a FRESH write replicates to the rejoined voter")
        # Historical state came via the streamed catch-up; this proves the raft handshake —
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
    print("\nPASS promote-back smoke (v2) — a below-floor learner was healed by the AUTO "
          "streamed catch-up (replace + data-free baseline), was promoted back to a voter, "
          "and a fresh write replicated to it from the leader's log. ⭐")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
