#!/usr/bin/env python3
"""A write too large to replicate is REFUSED, never sent (rove#646).

A raft message rides one frame into the receiver's fixed 512 KiB buffer
(`raft_net.RECV_BUF_SIZE`), nothing fragments it, and one entry rides one
message. So an entry above that limit could only ever be dropped — and the
old behaviour was worse than dropping: the frame went out, every follower
tore the CONNECTION down, and that connection carries the heartbeats and
appends of every OTHER tenant hosted on the same pair of nodes. One tenant's
oversize write cost its neighbours an election storm.

The rule this pins: never send a message we know a priori is too large.

  1. A single value over `KV_VAL_MAX` is refused at the call site, by the
     kv guard, with a code the handler can branch on.
  2. A batch of legal values whose ENTRY exceeds the wire limit is refused at
     propose — a defined 413, not the retry-safe 421 (every node would refuse
     it identically) and not a 503 after the links tear down.
  3. Nothing reaches the wire: no `oversize frame` in any node log, and
     `raft_oversize_dropped_total` stays 0 — the transport backstop never
     even has to fire.
  4. An innocent co-tenant on the same three nodes is untouched while all
     that happens.

Run:
    zig build rewind-worker rewind-cp rewind-front rewind-logs rewind-ops
    set -a; . ./.env; set +a
    python3 scripts/smoke/entry_size_guard_smoke_v2.py
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, metric_counter  # noqa: E402

# Mirrors src/reserved/root.zig KV_VAL_MAX (384 KiB) — the largest value one
# raft entry can carry, with room for the envelope and the readset.
KV_VAL_MAX = 384 * 1024

SRC = """
export default function () {
  const p = new URLSearchParams(request.query || "");
  const op = p.get("op");
  if (op === "one") {
    // A single value over the guard's cap: refused at the call site.
    try { kv.set("big/one", "x".repeat(parseInt(p.get("n"), 10))); return "wrote"; }
    catch (e) { return "refused:" + (e.code || "?"); }
  }
  if (op === "many") {
    // Each value is legal; the ENTRY they build together is not.
    const n = parseInt(p.get("n"), 10), each = parseInt(p.get("each"), 10);
    for (let i = 0; i < n; i++) kv.set("many/" + i, "y".repeat(each));
    return "wrote " + n;
  }
  if (op === "small") { kv.set("s/" + p.get("k"), "ok"); return "s"; }
  return "ok";
}
"""


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    print("=== entry-size guard: refuse a priori, never send an undeliverable message ===")
    with V2Cluster.spawn("entryguard", nodes=3) as c:
        for t in ("victim", "bystander"):
            c.provision(t)
            c.wait_for_membership(t, voters=3)
            c.deploy_handlers(t, {"index.mjs": SRC})
            c.wait_for_handler(t, "/", want_body="ok", timeout_s=30.0)

        # ── 1. a single oversize value: a rule at the call site ──
        r = c.request("victim", f"/?op=one&n={KV_VAL_MAX + 1}", timeout=30.0)
        check("a value over the cap is refused by the kv guard, with a code",
              r.status == 200 and r.body == "refused:value_too_large",
              f"{r.status} {r.body[:60]!r}")
        r = c.request("victim", f"/?op=one&n={KV_VAL_MAX}", timeout=30.0)
        check("a value AT the cap still commits (the cap is reachable, not decorative)",
              r.status == 200 and r.body == "wrote", f"{r.status} {r.body[:60]!r}")

        # ── 2. legal values, illegal entry: a defined 413 at propose ──
        r = c.request("victim", "/?op=many&n=8&each=200000", timeout=60.0)
        check("an entry over the wire limit answers 413, not 421/503",
              r.status == 413, f"{r.status} {r.body[:80]!r}")
        check("…and says what to change",
              "too large to replicate" in r.body, f"{r.body[:120]!r}")

        # ── 3. nothing reached the wire ──
        logs = "".join(Path(p).read_text(errors="replace")
                       for p in c.log_paths.values() if Path(p).exists())
        oversize = "oversize frame" in logs
        check("no follower ever saw an oversize frame", not oversize,
              "found 'oversize frame' in a node log" if oversize else "")
        dropped = sum((metric_counter(c.metrics(i), "raft_oversize_dropped_total") or 0)
                      for i in range(len(c.node_ports)))
        check("the transport backstop never had to fire", dropped == 0, f"got {dropped}")

        # ── 4. the co-tenant is untouched ──
        ok, statuses = 0, []
        for i in range(40):
            rr = c.request("bystander", f"/?op=small&k={i}", timeout=30.0)
            statuses.append(rr.status)
            if rr.status == 200:
                ok += 1
        check("the co-tenant on the same nodes is unaffected", ok == 40,
              f"{ok}/40 ok, statuses={sorted(set(statuses))}")

        # ── and the victim's own group is still healthy ──
        r = c.request("victim", "/?op=small&k=after", timeout=30.0)
        check("the refusing tenant keeps serving", r.status == 200, f"{r.status}")

        if failures:
            c.dump_node_log(grep=["oversize", "EntryTooLarge", "error"])

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print("\nPASS — an undeliverable write is refused where the customer can see it, "
          "and no oversize message is ever put on the wire.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
