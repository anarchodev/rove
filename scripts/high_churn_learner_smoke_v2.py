#!/usr/bin/env python3
"""V2 high-churn learner-add smoke — add a learner to a CONTINUOUSLY-WRITTEN group.

This is the hard case `learner_add` does NOT cover: the group keeps taking writes
WHILE a new learner is bootstrapped + caught up. It reproduces the prod `__admin__`
strand and proves the fix.

The strand (on the unfixed engine):
  - `v2-applied-baseline` returns the leader's DURABILIZED store watermark
    (`lastAppliedRaftIdx`), which under continuous writes lags the live applied
    index by ~one durabilize cycle (DEFAULT_DURABILIZE_NS = 500ms). The leader's
    WAL has already been COMPACTED past that lagging watermark (compaction tracks
    the live min-match floor). So the learner is born at a baseline BELOW the
    leader's first log index.
  - rove is snapshot-free, and `min_match_index` excluded learners, so the leader
    would never retain the gap for the learner either — it asks its storage for a
    snapshot, gets "unavailable", and the learner is stuck FOREVER, silently
    ("receiving nothing", never catching up). Exactly the prod __admin__ wall.

The fix (this branch):
  A. `v2-applied-baseline` returns the LIVE applied index (`slot.applied_idx`),
     which is always >= the leader's first log index (compaction floors at
     `min(applied, ...)`), so the learner is born at an in-log baseline.
  B. `min_match_index` includes `recent_active` learners, so once the learner is
     replicating the leader retains its tail — it can never be compacted past
     while catching up (impossible by construction). A stalled learner is excluded
     so the WAL stays bounded.
  C. the storage snapshot callback logs LOUD instead of silently returning -1, so
     any residual strand is observable, not silent.

Sequence (writes flow the ENTIRE time, from step 2 until the final assert):
  1. provision acme [1,2,3], deploy, seed.
  2. ⭐ start a continuous background writer (high churn).
  3. remove node 3 (-> [1,2]) + evict its instance: a clean non-member.
  4. AddLearner(3) on the leader (-> voters[1,2] learners[3]).
  5. bootstrap node 3 as a born learner (GET baseline + snapshot, atomic attach) —
     all WHILE writes are flowing, so the baseline must be fresh + in-log.
  6. ⭐ node 3 catches up to the leader (per-peer matched via v2-member-status)
     DESPITE the ongoing write load — on the unfixed engine it never does.
  7. promote(3) -> [1,2,3]; stop writes; a final fresh write replicates to node 3.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import threading
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
# last_index-vs-leader_last tolerance for "caught up" under live churn. The
# learner is always a few in-flight entries behind the still-writing leader;
# generous headroom (the reconciler's promote gate uses 16 on a calmer group).
SLACK = 64


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


def _attach_file(url, path, *, tenant, index, term, as_learner, epoch=None):
    args = ["curl", "-s", "-w", "%{http_code}", "-m", "20",
            "--http2-prior-knowledge", "-X", "POST", *SECRET,
            "-H", f"X-Rewind-Tenant: {tenant}",
            "-H", f"X-Rewind-Baseline-Index: {index}",
            "-H", f"X-Rewind-Baseline-Term: {term}",
            "-H", f"X-Rewind-Join-As-Learner: {'1' if as_learner else '0'}"]
    if epoch is not None:  # birth the group at the leader's epoch, not the default 1
        args += ["-H", f"X-Rewind-Epoch: {epoch}"]
    args += ["--data-binary", f"@{path}", url]
    return subprocess.run(args, capture_output=True, text=True).stdout.strip()


class Churner:
    """Background thread hammering writes through the front door — keeps the
    group's applied index advancing (and the leader compacting) for the whole
    join, so the baseline must be fresh + the learner must catch a moving tail."""

    def __init__(self, c, tenant):
        self.c = c
        self.tenant = tenant
        self.n = 0
        self.ok = 0
        self._stop = threading.Event()
        self._t = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        while not self._stop.is_set():
            self.n += 1
            r = self.c.request(self.tenant, "/?fn=handler", method="POST",
                               data=f'{{"value":"w-{self.n}"}}', timeout=10)
            if r.status == 204:
                self.ok += 1

    def start(self):
        self._t.start()

    def stop(self):
        self._stop.set()
        self._t.join(timeout=10)

    @property
    def last(self):
        return f"w-{self.n}"


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("hichurn", nodes=3) as c:
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

        def member_status(leader):
            st, body = _curl_json(url(leader, "v2-member-status?tenant=acme"))
            try:
                return json.loads(body) if st == 200 else None
            except Exception:
                return None

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

        print("step 2: ⭐ start the continuous background writer (high churn)")
        churn = Churner(c, "acme")
        churn.start()
        try:
            # Let the writer get well ahead so the durabilized watermark genuinely
            # lags the compaction floor before we read a baseline.
            time.sleep(4.0)
            check("writer is making progress", churn.ok > 20, f"ok={churn.ok}/{churn.n}")

            lead = c.leader_node("acme")
            victim = next(i for i in range(3) if i != lead)
            vnid = victim + 1
            print(f"       leader=node {lead + 1}; learner-add target = node {vnid}; writes so far={churn.ok}")

            print(f"step 3: remove node {vnid} (-> [1,2]) + evict its instance")
            check("remove → 204", confchange(lead, vnid, "remove") == 204)
            time.sleep(1.0)
            _curl_json(url(victim, "v2-evict"), method="POST", data='{"tenant":"acme"}')
            time.sleep(1.0)
            st, _ = _curl_json(url(victim, "v2-confstate?tenant=acme"))
            check(f"node {vnid} no longer hosts the group", st == 404, f"got {st}")

            print(f"step 4: AddLearner({vnid}) on the leader")
            lead = c.leader_node("acme")
            check("AddLearner → 204", confchange(lead, vnid, "add") == 204)
            cs_lead = confstate(lead)
            check(f"leader sees node {vnid} as a LEARNER",
                  cs_lead is not None and vnid in cs_lead.get("learners", []), f"cs={cs_lead}")

            print(f"step 5: bootstrap node {vnid} as a born learner (writes still flowing)")
            st, body = _curl_json(url(lead, "v2-applied-baseline?tenant=acme"))
            check("applied-baseline → 200", st == 200, f"got {st} {body!r}")
            base = json.loads(body) if st == 200 else {"index": 0, "term": 0}
            check("baseline carries the leader's epoch", "epoch" in base, f"base={base}")
            ms = member_status(lead)
            leader_last0 = ms.get("leader_last", 0) if ms else 0
            # ⭐ the diagnostic: on the unfixed engine the baseline lags far below
            # the leader's log tail (and below its compacted first index) under load.
            print(f"       baseline index={base['index']} term={base['term']}  "
                  f"leader_last={leader_last0}  (gap={leader_last0 - base['index']})")
            with tempfile.NamedTemporaryFile(suffix=".bundle", delete=False) as tf:
                bpath = tf.name
            check("snapshot bundle → 200",
                  _curl_to_file(url(lead, "v2-snapshot"), bpath, data='{"tenant":"acme"}') == "200")
            check("attach (join-as-learner) → 204",
                  _attach_file(url(victim, "v2-attach"), bpath, tenant="acme",
                               index=base["index"], term=base["term"], as_learner=True,
                               epoch=base.get("epoch")) == "204")

            cs_v = confstate(victim)
            check(f"⭐ node {vnid} born as a LEARNER (not voter)",
                  cs_v is not None and vnid not in cs_v.get("voters", []), f"local cs={cs_v}")

            print(f"step 6: ⭐ node {vnid} catches the MOVING tail despite ongoing writes")
            # The learner's catch-up signal is its OWN raft last_index (via the
            # non-leader-gated v2-last-index — the leader's per-peer voter_progress
            # is voters-only and does NOT list a learner). Compare it against the
            # leader's leader_last. On the unfixed engine the learner is compacted
            # past and frozen far below leader_last → never within SLACK.
            def last_index(node):
                st, body = _curl_json(url(node, "v2-last-index?tenant=acme"))
                try:
                    return json.loads(body).get("last_index", 0) if st == 200 else 0
                except Exception:
                    return 0
            caught = False
            t_end = time.time() + 30.0
            while time.time() < t_end:
                ms = member_status(c.leader_node("acme"))
                ll = ms.get("leader_last", 0) if ms else 0
                vlast = last_index(victim)
                if ll > 0 and vlast + SLACK >= ll:
                    caught = True
                    print(f"       caught up: node {vnid} last_index={vlast} leader_last={ll}")
                    break
                time.sleep(0.5)
            check(f"⭐ node {vnid} caught up under load (unfixed engine strands here)", caught)

            print(f"step 7: promote({vnid}) -> [1,2,3], stop writes, final fresh write replicates")
            if caught:
                check("promote → 204", confchange(c.leader_node("acme"), vnid, "promote") == 204)
                time.sleep(1.0)
                cs_lead = confstate(c.leader_node("acme"))
                check(f"node {vnid} is a voter again",
                      cs_lead is not None and vnid in cs_lead.get("voters", []), f"cs={cs_lead}")
        finally:
            churn.stop()
        print(f"       writer totals: {churn.ok} committed / {churn.n} attempted")

        # Distinct key so a late churner straggler (which writes cc/value) can't
        # overwrite the marker and mask replication.
        w = c.request_retry("acme", "/?fn=handler", method="POST",
                            data='{"key":"final/marker","value":"after-promote"}',
                            want_status=204, deadline_s=15)
        check("final write accepted (204)", w.status == 204, f"got {w.status}")
        repl = False
        seen = ""
        for _ in range(40):
            seen = c.admin_kv_get("acme", "final/marker", node=victim).body
            if "after-promote" in seen:
                repl = True; break
            time.sleep(0.5)
        check(f"⭐ final fresh write replicated to node {vnid}", repl, f"node{vnid} saw {seen!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS high-churn learner-add smoke (v2) — a learner was bootstrapped onto a "
          "CONTINUOUSLY-written group, caught a moving log tail, and was promoted; the "
          "baseline was fresh + in-log and the leader retained the learner's tail. ⭐")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
