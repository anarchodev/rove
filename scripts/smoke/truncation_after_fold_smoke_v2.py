#!/usr/bin/env python3
"""RC-1: an entry that never reached a majority must not survive its leader.

The deterministic reproducer the 2026-06-20 incident never got (rove#104).
`raft_soak_prod` covers crash RECOVERY — kill a node, it comes back with every
acked write — but it cannot reach this class at all, because it only ever kills
nodes that were fully replicating. The dangerous window is the other one: a
write proposed on a leader that CANNOT reach quorum, whose leader then dies.

Nothing here needs power-loss tooling. The entry does not have to be lost from
disk — it has to be lost from the LOG, which a majority never accepted. That
is reproducible with a freeze and a kill:

  1. provision across 3 nodes, seed a write, find the leader
  2. KILL both followers — the leader is now 1/3 and can append locally but
     can never commit. Killed rather than frozen: SIGSTOP only DELAYS a peer,
     whose socket buffer still holds the leader's AppendEntries, so on thaw it
     persists and commits the entry. Observed exactly that — both "survivors"
     came back holding the value, which is correct behaviour for a late
     follower and useless as a reproducer.
  3. ⭐ write through the leader. It must be REFUSED (503/504/421), never 2xx.
     This is the fold gate: `committed_seq` may only advance for an entry that
     is provably truncation-safe, and this one is the opposite of that.
  4. KILL the leader (SIGKILL) with the followers still frozen — its
     uncommitted tail is on its disk and nowhere else
  5. RESTART the followers: they hold 2/3 and elect among themselves, from
     WALs that never saw the entry
  6. ⭐ the orphaned key is absent on both survivors
  7. restart the old leader — it rejoins as a follower and raft must TRUNCATE
     the conflicting tail
  8. ⭐ the orphaned key is absent there too. A recovery that replayed its WAL
     without regard for what committed would resurrect it, and this node would
     serve a value no other node has: a silently diverged replica that can win
     a later election.
  9. the cluster still commits — the refusal cost the write, not the group

What a PASS means: an unacknowledged write left no trace anywhere, and the
client was told so. What a FAIL means: either the client was told a write
succeeded when it could not have, or a replica is now serving data that never
committed.

Needs S3 env: `set -a; . ./.env; set +a` first.
Build: `zig build rewind-worker rewind-cp rewind-front`
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# A WIDE election window, set before the nodes spawn. The reproducer needs the
# leader to still BELIEVE it leads while its followers are frozen — that is the
# only state in which it appends an entry it can never commit, which is the
# entry this smoke is about. At the default tick the leader steps down almost
# immediately and the write is refused 421 at the door, with nothing appended:
# the smoke would pass without having reproduced anything.
os.environ.setdefault("REWIND_RAFT_TICK_MS", "50")

from smoke_lib_v2 import V2Cluster, MOVE_SECRET  # noqa: E402

TENANT = "acme"
ORPHAN_KEY = "rc1-orphan"
ORPHAN_VALUE = "never-committed"

failures: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
    if not ok:
        failures.append(label)


def last_index(c: V2Cluster, node: int) -> int:
    """This node's local raft last_index, or 0 if it cannot answer."""
    out = subprocess.run(
        ["curl", "-sS", "--http2-prior-knowledge", "-m", "5",
         "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
         f"{c.node_url(node)}/_system/v2-last-index?tenant={TENANT}"],
        capture_output=True, text=True)
    try:
        return int(json.loads(out.stdout).get("last_index", 0))
    except Exception:
        return 0


def key_absent_on(c: V2Cluster, node: int) -> tuple[bool, str]:
    """(absent, detail) for the orphan key on one node."""
    r = c.node_kv_get(TENANT, ORPHAN_KEY, node=node)
    if r.status == 404:
        return True, "404"
    if r.status == 200 and ORPHAN_VALUE in r.body:
        return False, f"200 '{r.body.strip()[:40]}' — THE ORPHAN SURVIVED"
    # Any other status is not the value coming back, so the invariant holds;
    # report it so a changed refusal shape is visible rather than silent.
    return True, f"{r.status} '{r.body.strip()[:40]}'"


def main() -> int:
    with V2Cluster.spawn("rc1trunc", nodes=3) as c:
        print("step 1: provision acme across 3 nodes + seed a committed write")
        c.provision(TENANT)
        c.admin_kv_seed(TENANT, "baseline", "committed-before")
        leader = c.leader_node(TENANT)
        check("group elected a leader", leader is not None, f"node {(leader or -1) + 1}")
        if leader is None:
            return 1
        followers = [i for i in range(3) if i != leader]
        print(f"       leader = node {leader + 1}; followers = "
              f"{', '.join(str(f + 1) for f in followers)}")

        print("step 2: KILL both followers — the leader drops to 1/3")
        # KILLED, not frozen. SIGSTOP only DELAYS a follower: the leader's
        # AppendEntries still land in its socket buffer, and on SIGCONT it
        # reads them, persists the entry and commits it — so the "orphan"
        # legitimately survives and the smoke fails for the right behaviour.
        # (Observed exactly that: both survivors held the value after a thaw.)
        # A killed follower loses the buffer with the process and restarts from
        # a WAL that never saw the entry, which is what makes the entry
        # genuinely un-committable rather than merely late.
        before = last_index(c, leader)
        follower_idx_before = {f: last_index(c, f) for f in followers}
        for f in followers:
            c.kill_node(f)

        print("step 3: ⭐ a write that cannot reach quorum must be REFUSED, never acked")
        t0 = time.time()
        r = c.node_kv_put(TENANT, ORPHAN_KEY, ORPHAN_VALUE, node=leader)
        took = time.time() - t0
        check("the un-committable write was refused",
              not (200 <= r.status < 300),
              f"status={r.status} after {took:.1f}s "
              f"{'(2xx = the fold gate fired for an entry no majority holds)' if 200 <= r.status < 300 else ''}")

        # ⭐ The load-bearing precondition. Everything below asserts that an
        # ORPHANED ENTRY does not survive — which is vacuous if no entry was
        # ever appended. A 421 at the door (leader already stepped down) leaves
        # the log untouched and would let this smoke pass while reproducing
        # nothing, so the appended entry is asserted, not assumed.
        after = last_index(c, leader)
        check("⭐ the leader APPENDED the un-committable entry (the orphan exists)",
              after > before,
              f"last_index {before} → {after}"
              + ("" if after > before else
                 " — nothing was appended, so this run reproduced NOTHING;"
                 " widen REWIND_RAFT_TICK_MS or shorten the path to the write"))
        print("       (the followers are down, so nothing could have accepted it)")

        print("step 4: KILL the leader while the followers are still down")
        c.kill_node(leader)

        print("step 5: RESTART the followers — 2/3 elect among themselves")
        for f in followers:
            c.start_node(f)
        new_leader = c.leader_node(TENANT, deadline_s=45.0)
        check("the survivors elected a new leader",
              new_leader is not None and new_leader in followers,
              f"node {(new_leader or -1) + 1}")

        print("step 6: ⭐ the orphaned write is absent on both survivors")
        for f in followers:
            absent, detail = key_absent_on(c, f)
            check(f"node {f + 1} does not hold the orphan", absent, detail)

        print("step 7: restart the old leader — its conflicting tail must be truncated")
        c.start_node(leader)
        # Rejoining is enough; it does not need to lead again.
        deadline = time.time() + 45.0
        rejoined = False
        while time.time() < deadline:
            if c.node_kv_get(TENANT, "baseline", node=leader).status == 200:
                rejoined = True
                break
            time.sleep(0.5)
        check("the old leader rejoined and serves committed state", rejoined)

        print("step 8: ⭐ the orphan did NOT come back with it")
        absent, detail = key_absent_on(c, leader)
        check("the restarted old leader does not hold the orphan", absent, detail)

        print("step 9: the group still commits — the refusal cost the write, not the cluster")
        w = c.admin_kv_put(TENANT, "after-rc1", "committed-after", retry_s=30.0)
        check("a fresh write commits post-recovery", 200 <= w.status < 300, f"status={w.status}")
        for i in range(3):
            # Poll: a node that rejoined seconds ago catches up asynchronously,
            # so an immediate read races replication rather than testing it.
            deadline = time.time() + 30.0
            g = c.node_kv_get(TENANT, "after-rc1", node=i)
            while time.time() < deadline and not (
                    g.status == 200 and "committed-after" in g.body):
                time.sleep(0.5)
                g = c.node_kv_get(TENANT, "after-rc1", node=i)
            check(f"node {i + 1} holds the post-recovery write",
                  g.status == 200 and "committed-after" in g.body,
                  f"{g.status} '{g.body.strip()[:30]}'")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS truncation-after-fold (RC-1) — a write no majority accepted was "
          "refused to the client, left no trace on the survivors, and did not "
          "resurrect when its leader rejoined. ⭐")
    return 0


if __name__ == "__main__":
    sys.exit(main())
