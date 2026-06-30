#!/usr/bin/env python3
"""V2 epoch-aware learner join — a learner must be born at the LEADER's epoch.

Guards the fix for the prod `__admin__` wall: a learner-join attach used to
hard-code migration-epoch 1, which only matched PROVISIONED tenants (epoch 1).
A genesis group like `__admin__` (born via `ensureGroup` at epoch 0) — or a moved
tenant (epoch >1) — would get a replica born at the WRONG epoch, so the leader's
epoch-stamped raft messages were FENCED at the receiver and silently dropped: the
join stalled forever at its baseline ("stepBatch skipped … fenced").

This reproduces that fence with a deliberate epoch MISMATCH and proves the fix:

  NEGATIVE — attach the learner at the WRONG epoch (leader_epoch + 1):
     the group is born locally, but every append from the leader is fenced →
     the learner NEVER advances past its baseline. (On the unfixed engine this is
     what `__admin__` did with the hard-coded 1 vs its real epoch 0.)
  POSITIVE — re-attach at the leader's ACTUAL epoch (from v2-applied-baseline):
     the learner catches up + is promoted + a fresh write replicates.

`acme` is a provisioned (epoch-1) tenant, so the mismatch is leader_epoch+1 vs the
real epoch — the mechanism is identical regardless of the absolute epoch value.

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
SLACK = 8


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


def _attach_file(url, path, *, tenant, index, term, epoch, as_learner=True):
    args = ["curl", "-s", "-w", "%{http_code}", "-m", "20",
            "--http2-prior-knowledge", "-X", "POST", *SECRET,
            "-H", f"X-Rewind-Tenant: {tenant}",
            "-H", f"X-Rewind-Baseline-Index: {index}",
            "-H", f"X-Rewind-Baseline-Term: {term}",
            "-H", f"X-Rewind-Epoch: {epoch}",
            "-H", f"X-Rewind-Join-As-Learner: {'1' if as_learner else '0'}",
            "--data-binary", f"@{path}", url]
    return subprocess.run(args, capture_output=True, text=True).stdout.strip()


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("epochjoin", nodes=3) as c:
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

        def leader_last(node):
            st, body = _curl_json(url(node, "v2-member-status?tenant=acme"))
            try:
                return json.loads(body).get("leader_last", 0) if st == 200 else 0
            except Exception:
                return 0

        def last_index(node):
            st, body = _curl_json(url(node, "v2-last-index?tenant=acme"))
            try:
                return json.loads(body).get("last_index", 0) if st == 200 else 0
            except Exception:
                return 0

        print("step 1: provision acme (epoch 1) + deploy + seed")
        check("provision → 204", c.provision("acme").status == 204)
        lead = c.leader_node("acme")
        if lead is None:
            check("leader present", False); return 1
        try:
            check("deploy → dep_id", bool(c.deploy_handlers("acme", {"index.mjs": rpc_wrap(HANDLER_SRC)}, node=lead)))
        except RuntimeError as e:
            check("deploy", False, str(e)); return 1
        c.wait_for_handler("acme", "/?fn=handler", want_body="value:none")

        lead = c.leader_node("acme")
        victim = next(i for i in range(3) if i != lead)
        vnid = victim + 1
        print(f"       leader=node {lead + 1}; join target = node {vnid}")

        print(f"step 2: identify join target = node {vnid} (each attempt does its own clean reset)")

        with tempfile.NamedTemporaryFile(suffix=".bundle", delete=False) as tf:
            bpath = tf.name

        # One self-contained join attempt at a given epoch, mirroring the
        # reconciler's heal-to-completion flow so the two legs are INDEPENDENT:
        #   reset  — remove the node from the leader's config (drops any stale
        #            Progress) + evict its local group → a clean non-member, then
        #            AddLearner (fresh Progress, matched=0);
        #   attach — fetch a FRESH baseline + snapshot from the CURRENT leader (so
        #            the baseline is always at/above the compaction floor, never a
        #            stale below-floor index), born-learner attach at `epoch`;
        #   drive  — a burst of writes so there's a live tail to replicate.
        # The ONLY variable between the two attempts is the epoch, so a stall is
        # attributable to epoch fencing — not a stale baseline or stale Progress.
        def attempt_join(epoch_to_use):
            lead_now = c.leader_node("acme")
            confchange(lead_now, vnid, "remove")  # ok whether it's a voter or learner now
            time.sleep(0.6)
            _curl_json(url(victim, "v2-evict"), method="POST", data='{"tenant":"acme"}')
            time.sleep(0.6)
            lead_now = c.leader_node("acme")
            if confchange(lead_now, vnid, "add") != 204:
                return None, False, 0, 0
            time.sleep(0.6)
            st2, body2 = _curl_json(url(lead_now, "v2-applied-baseline?tenant=acme"))
            if st2 != 200:
                return None, False, 0, 0
            b = json.loads(body2)
            if _curl_to_file(url(lead_now, "v2-snapshot"), bpath, data='{"tenant":"acme"}') != "200":
                return None, False, 0, 0
            ac = _attach_file(url(victim, "v2-attach"), bpath, tenant="acme",
                              index=b["index"], term=b["term"], epoch=epoch_to_use)
            # create a live gap AFTER the attach
            for i in range(12):
                c.request_retry("acme", "/?fn=handler", method="POST", data=f'{{"value":"e{epoch_to_use}-{i}"}}', want_status=204, deadline_s=10)
            caught = False
            for _ in range(24):  # ~12s
                ll = leader_last(c.leader_node("acme"))
                if ll > 0 and last_index(victim) + SLACK >= ll:
                    caught = True; break
                time.sleep(0.5)
            return ac, caught, last_index(victim), leader_last(c.leader_node("acme"))

        print("step 3: read the leader's epoch from a baseline")
        st, body = _curl_json(url(lead, "v2-applied-baseline?tenant=acme"))
        check("applied-baseline → 200 + carries epoch", st == 200 and "epoch" in (json.loads(body) if st == 200 else {}), f"got {st} {body!r}")
        real_epoch = (json.loads(body).get("epoch", 1)) if st == 200 else 1
        wrong_epoch = real_epoch + 1
        print(f"       leader epoch={real_epoch}; will test wrong={wrong_epoch} then right={real_epoch}")

        print(f"step 4: ⭐ NEGATIVE — born at the WRONG epoch ({wrong_epoch}) → must STALL (fenced)")
        ac, caught, vl, ll = attempt_join(wrong_epoch)
        check("attach (wrong epoch) → 204", ac == "204", f"got {ac}")
        check(f"⭐ node {vnid} STALLED (epoch-fenced) — last_index={vl} vs leader {ll}", not caught)

        print(f"step 5: ⭐ POSITIVE — born at the REAL epoch ({real_epoch}) → catches up + promote")
        ac, caught, vl, ll = attempt_join(real_epoch)
        check("attach (right epoch) → 204", ac == "204", f"got {ac}")
        check(f"⭐ node {vnid} caught up at the correct epoch — last_index={vl} vs leader {ll}", caught)
        if caught:
            check("promote → 204", confchange(c.leader_node("acme"), vnid, "promote") == 204)
            time.sleep(1.0)
            cs = confstate(c.leader_node("acme"))
            check(f"node {vnid} is a voter", cs is not None and vnid in cs.get("voters", []), f"cs={cs}")
            c.request_retry("acme", "/?fn=handler", method="POST", data='{"key":"final/marker","value":"epoch-ok"}', want_status=204, deadline_s=15)
            repl = False
            for _ in range(40):
                if "epoch-ok" in c.admin_kv_get("acme", "final/marker", node=victim).body:
                    repl = True; break
                time.sleep(0.5)
            check(f"⭐ fresh write replicated to node {vnid}", repl)

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS epoch-join smoke (v2) — a wrong-epoch learner is fenced + stalls; born at the "
          "leader's actual epoch it catches up + promotes. The join no longer assumes epoch 1. ⭐")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
