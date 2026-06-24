#!/usr/bin/env python3
"""RC-1 end-to-end gate: the out-of-band catch-up must NOT fork the receiver's store.

Companion to the deterministic unit test (`src/consensus/bridge.zig`,
"catch-up baseline index never exceeds the durable snapshot content watermark").
The unit test proves the seam; THIS smoke proves the whole catch-up path
end-to-end: a follower stranded past the compaction floor recovers via the
out-of-band baseline + snapshot stream and converges to the leader's state with
**every** acked write intact (no fork).

The bug (RC-1, `docs/raft-consensus-storage-triage.md`): the catch-up baseline
index was `slot.applied_idx`, which under worker_overlay LEADS the folded
snapshot content; the receiver `apply_local_snapshot` then fast-forwarded commit
PAST writes the snapshot lacked, and those entries (≤ its commit / below
first_index) never replayed → a permanent store fork at an agreed log index (the
prod __auth__ divergence). The fix ships `durabilized_idx` (≤ snapshot content).

To exercise the real out-of-band path (not plain log replication) the compaction
buffer is forced low (`REWIND_SNAPSHOT_GRACE`) so a brief churn strands the
victim past it. Distinct keys (not one overwritten key) + a CONCURRENT churner
running THROUGH the rejoin/catch-up maximize the applied>folded window the bug
needs; the assertion then compares every acked key on the recovered victim
against the leader — a fork shows up as a missing/stale distinct key.

HONESTY NOTE: the over-claim is a narrow timing race (the worker-fold lag at the
instant the dump fires), so this smoke is not a *deterministic* reproducer — on
the fixed code it must always pass (the path converges, no fork); on the buggy
code it forks only when the race lands. The deterministic regression gate is the
unit test. This smoke is the end-to-end convergence coverage.

Needs S3 env: `set -a; . ./.env; set +a` first.
Build: `zig build rewind-worker rewind-cp rewind-front`
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# Low compaction buffer so a brief churn strands the victim past it (prod ~5000),
# forcing the OUT-OF-BAND catch-up path rather than plain tail replication. Set
# before spawn — `_spawn_node` inherits the process env.
os.environ["REWIND_SNAPSHOT_GRACE"] = "20"
# Disable auto-demote so the frozen voter is recovered purely via the snapshot
# trigger, not demoted to a learner mid-test.
os.environ["REWIND_AUTO_DEMOTE_LAG"] = "0"

from smoke_lib_v2 import V2Cluster, rpc_wrap, MOVE_SECRET  # noqa: E402

# POST {key, value} writes a distinct kv pair; GET ?key= reads one back.
HANDLER_SRC = """\
export function handler() {
    if (request.method === "POST") {
        const body = JSON.parse(request.body || "{}");
        kv.set(body.key, body.value);
        response.status = 204;
        return "";
    }
    return kv.get(request.query.key ?? "") ?? "none";
}
"""

SECRET = ["-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}"]
SLACK = 64  # last_index-vs-leader tolerance while the leader keeps writing

N_SEED = 40           # distinct keys committed on all 3 before the victim drops
N_STRAND = 240        # > grace(20): strands the victim past the compaction floor
CHURN_THREADS = 8     # concurrent in-flight writes → widen the applied>folded window


def _curl_json(url):
    out = subprocess.run(
        ["curl", "-s", "-w", "\n%{http_code}", "-m", "15",
         "--http2-prior-knowledge", *SECRET, url],
        capture_output=True, text=True).stdout
    nl = out.rfind("\n")
    try:
        return int(out[nl + 1:].strip() or 0), out[:nl]
    except Exception:
        return 0, ""


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("nofork", nodes=3) as c:
        def last_index(node):
            st, body = _curl_json(f"{c.node_url(node)}/_system/v2-last-index?tenant=acme")
            try:
                return json.loads(body).get("last_index", 0) if st == 200 else 0
            except Exception:
                return 0

        # ── the authoritative write log: key -> value, only ACKED writes ──
        written: dict[str, str] = {}
        wlock = threading.Lock()
        ctr = [0]

        def put(node, *, n=1):
            """Seed/strand writer: distinct keys via the admin propose path (fast
            log advance). Pump-applied, so fully folded before catch-up."""
            for _ in range(n):
                with wlock:
                    ctr[0] += 1
                    i = ctr[0]
                k, v = f"k/{i}", f"v/{i}"
                r = c.admin_kv_put("acme", k, v, node=node)
                if r.status in (200, 204):
                    with wlock:
                        written[k] = v

        def put_handler(*, n=1):
            """Churn writer through the JS HANDLER (front door) — kv.set via the
            worker's TrackedTxn = the worker_overlay SKIP path on the leader, where
            applied_idx LEADS the folded overlay. This is the window the RC-1
            over-claim needs; admin_kv_put (pump-applied) does NOT exercise it."""
            for _ in range(n):
                with wlock:
                    ctr[0] += 1
                    i = ctr[0]
                k, v = f"k/{i}", f"v/{i}"
                r = c.request("acme", "/?fn=handler", method="POST",
                              data=json.dumps({"key": k, "value": v}), timeout=10)
                if r.status == 204:
                    with wlock:
                        written[k] = v

        print("step 1: provision acme [1,2,3] + deploy")
        check("provision → 204", c.provision("acme").status == 204)
        lead = c.leader_node("acme")
        if lead is None:
            check("leader present", False)
            return 1
        try:
            check("deploy → dep_id", bool(c.deploy_handlers(
                "acme", {"index.mjs": rpc_wrap(HANDLER_SRC)}, node=lead)))
        except RuntimeError as e:
            check("deploy", False, str(e))
            return 1

        print(f"step 2: seed {N_SEED} distinct keys on leader node {lead + 1}")
        put(lead, n=N_SEED)
        check("seed keys acked", len(written) == N_SEED, f"{len(written)}/{N_SEED}")
        # all 3 nodes hold the seed set (sample the last seeded key)
        seed_k = f"k/{ctr[0]}"
        for i in range(3):
            ok = False
            deadline = time.time() + 10.0
            while time.time() < deadline:
                if c.admin_kv_get("acme", seed_k, node=i).body.find(written[seed_k]) >= 0:
                    ok = True
                    break
                time.sleep(0.3)
            check(f"node {i + 1} holds seed", ok)

        print("step 3: STOP a follower (the victim)")
        lead = c.leader_node("acme")
        victim = next(i for i in range(3) if i != lead)
        print(f"       leader=node {lead + 1}; victim follower = node {victim + 1}")
        c.stop_node(victim)

        print(f"step 4: strand the victim — {N_STRAND} distinct writes (> grace=20)")
        put(lead, n=N_STRAND)
        leader_li = last_index(lead)
        victim_gap = leader_li - last_index(victim)
        check("victim stranded past the compaction floor", victim_gap > 20,
              f"gap={victim_gap} (grace=20)")

        print("step 5: RESTART the victim WITH concurrent churn through catch-up")
        churn_stop = threading.Event()

        def churn_worker():
            while not churn_stop.is_set():
                put_handler(n=1)  # worker_overlay path — the RC-1 window

        pool = ThreadPoolExecutor(max_workers=CHURN_THREADS)
        for _ in range(CHURN_THREADS):
            pool.submit(churn_worker)
        c.start_node(victim)

        # Wait until the victim's log catches up to the leader's (out-of-band
        # baseline install + tail replication), under live churn.
        print("step 6: wait for the victim's log to catch up (out-of-band path)")
        caught = False
        deadline = time.time() + 90.0
        while time.time() < deadline:
            if last_index(victim) >= leader_li and (last_index(lead) - last_index(victim)) <= SLACK:
                caught = True
                break
            time.sleep(0.5)
        churn_stop.set()
        pool.shutdown(wait=True)
        check("victim caught up to leader's log", caught,
              f"victim_li={last_index(victim)} leader_li={last_index(lead)}")

        print(f"step 7: quiesce; total acked keys = {len(written)}")
        # A final marker write + wait for it on the victim ⇒ apply has drained.
        put(lead, n=1)
        marker = f"k/{ctr[0]}"
        deadline = time.time() + 30.0
        while time.time() < deadline:
            if c.admin_kv_get("acme", marker, node=victim).body.find(written.get(marker, "\0")) >= 0:
                break
            time.sleep(0.5)

        print("step 8: ⭐ NO-FORK — every acked key present + correct on the victim")
        # Give convergence a final settle, then compare the FULL key set on the
        # victim against what was acked. A fork = a key the leader committed that
        # never landed on the victim (over-claimed baseline skipped it).
        missing, mismatch = [], []
        keys = dict(written)  # snapshot under no further writers
        for k, v in keys.items():
            # brief per-key retry to absorb in-flight apply, not to mask a fork
            ok = False
            for _ in range(3):
                b = c.admin_kv_get("acme", k, node=victim).body
                if v in b:
                    ok = True
                    break
                time.sleep(0.2)
            if not ok:
                b = c.admin_kv_get("acme", k, node=victim).body
                (missing if (b == "" or "none" in b or "404" in b) else mismatch).append(k)
        check(f"⭐ victim holds ALL {len(keys)} acked keys (no fork)",
              not missing and not mismatch,
              f"missing={len(missing)} mismatch={len(mismatch)} "
              f"e.g. {(missing + mismatch)[:5]}")

        if missing or mismatch:
            c.dump_node_log(node=victim, grep=["snapshot", "catchup", "baseline",
                                               "apply_local", "fork", "warn", "error"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS snapshot-catchup-no-fork smoke (v2) — a follower stranded past "
          "the compaction floor recovered via the out-of-band baseline and "
          "converged to the leader with every acked write intact (RC-1).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
