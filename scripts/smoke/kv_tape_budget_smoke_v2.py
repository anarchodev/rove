#!/usr/bin/env python3
"""The kv tape's read budget (rove#430 §3): a broad read stays replicable, and
what the budget drops is REFUSED on replay rather than answered.

The kv channel rides the raft entry (the readset is serialized into the type-0
envelope), and the coalesced transport tears a peer connection down when one
message exceeds the receiver's fixed recv buffer (`src/kv/raft_net.zig`
`RECV_BUF_SIZE`, 512 KiB). Uncapped, an activation that read broadly and then
wrote proposed an entry no follower could receive — three 300 KB values are
enough — and the write came back `503 raft commit failed` with
`oversize frame … tearing down` in the followers' logs. That is what
`KV_TAPE_BUDGET` bounds.

The second half is the one the reference-discipline tracker (#550) insists on:
a value the budget drops must not come back on replay as a plausible absence.
The record carries an `elided` entry with the lost byte count, and every reader
refuses it.

  1. Seed three 300 KB values — each write replicates on its own.
  2. One activation reads all three AND writes → must COMMIT (200).
  3. No node logged an oversize frame.
  4. `tape_kv_elided_total` counted the dropped reads.
  5. `rewind replay` of that record REFUSES: a divergence naming the key,
     never a run that quietly saw `null`.

Run:
    zig build rewind-worker rewind-cp rewind-front rewind-logs rewind
    set -a; . ./.env; set +a
    python3 scripts/smoke/kv_tape_budget_smoke_v2.py
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, metric_counter  # noqa: E402
from replay_matrix_smoke_v2 import replay  # noqa: E402

TENANT = "kvbudget"
# 3 × 300 KB: every individual write fits a raft frame, the READ of all three
# in one writing activation did not.
SEED_BYTES = 300_000
SRC = """
export default function () {
  const p = new URLSearchParams(request.query || "");
  const op = p.get("op");
  if (op === "seed") {
    kv.set("big/" + p.get("k"), "x".repeat(%d));
    return "seeded";
  }
  if (op === "readwrite") {
    let total = 0;
    for (const k of ["a", "b", "c"]) {
      const v = kv.get("big/" + k);
      total += v ? v.length : 0;
    }
    kv.set("touch", "1");
    return "read " + total;
  }
  return "ok";
}
""" % SEED_BYTES


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    print("=== kv tape budget: broad reads stay replicable, dropped values refuse (#430 §3) ===")
    with V2Cluster.spawn("kvbudget", nodes=3) as c:
        c.spawn_log_server(poll_interval_ms=200)
        c.provision(TENANT)
        c.wait_for_membership(TENANT, voters=3)
        c.deploy_handlers(TENANT, {"index.mjs": SRC})
        c.wait_for_handler(TENANT, "/", want_body="ok", timeout_s=30.0)

        for k in ("a", "b", "c"):
            r = c.request(TENANT, f"/?op=seed&k={k}", timeout=30.0)
            check(f"seed big/{k} ({SEED_BYTES} B) → 200", r.status == 200, f"{r.status} {r.body[:40]!r}")

        # ── The activation that used to wedge replication ──
        r = c.request(TENANT, "/?op=readwrite", timeout=60.0)
        check("read 3×300 KB + write COMMITS (the readset stays inside a raft frame)",
              r.status == 200 and r.body == f"read {3 * SEED_BYTES}",
              f"{r.status} {r.body[:60]!r}")

        logs = "".join(Path(p).read_text(errors="replace")
                       for p in c.log_paths.values() if Path(p).exists())
        oversize = "oversize frame" in logs
        check("no node tore a peer down for an oversize frame", not oversize,
              "found 'oversize frame' in a node log" if oversize else "")

        # The counter is NODE-LOCAL (incremented where the activation ran),
        # and the tenant's group lands on a node by startup-timing luck —
        # scraping node 0 alone reads a forever-0 counter whenever
        # placement lands elsewhere (which is what an in-suite run's
        # slower interleaving produced while standalone runs passed).
        # Sum across the cluster: placement is not the assertion.
        def elided_total() -> int:
            return sum(metric_counter(c.metrics(i), "tape_kv_elided_total") or 0
                       for i in range(3))
        elided = elided_total()
        for _ in range(20):
            if elided:
                break
            time.sleep(0.5)
            elided = elided_total()
        check("tape_kv_elided_total counted the dropped reads", elided >= 1, f"got {elided}")

        # ── The record must say so, and replay must refuse it ──
        # The record for the read+write hop specifically (find_record keys on
        # activation kind, and every request here is `inbound`).
        target, listed = None, 0
        deadline = time.time() + 60.0
        while time.time() < deadline and target is None:
            lr = c.log_get(f"{TENANT}/list?limit=50")
            recs = json.loads(lr.body).get("records", []) if lr.status == 200 else []
            listed = len(recs)
            for x in recs:
                if "op=readwrite" not in (x.get("path") or ""):
                    continue
                sr = c.log_get(f"{TENANT}/show/{x['request_id']}")
                if sr.status != 200:
                    continue
                target = json.loads(sr.body)["record"]
                break
            if target is None:
                time.sleep(1.0)
        check("the read+write record is queryable", target is not None,
              "" if target else f"last list had {listed} records")

        art = replay(target, TENANT, "inbound", SRC) if target else None
        div = (art or {}).get("divergence") or ""
        check("replay REFUSES the elided read (never answers it as absent)",
              art is not None and "elided" in div and "big/" in div,
              f"divergence={div[:160]!r}")
        check("the refused run is not reported ok", art is not None and art.get("ok") is False,
              f"ok={(art or {}).get('ok')}")

        if failures:
            c.dump_node_log(grep=["oversize", "kv tape budget", "error"])

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print("\nPASS — a broad read replicates, and every value the budget dropped "
          "refuses on replay instead of replaying as absent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
