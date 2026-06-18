#!/usr/bin/env python3
"""V2 snapshot-trigger smoke — a peer that falls BEYOND the compaction buffer
auto-recovers via raft-rs's native StateSnapshot trigger + the out-of-band
catch-up driver (raft-native-alignment Phase 1).

This is the replacement for `high_churn_learner_smoke_v2.py`, whose premise (the
mechanism-B `recent_active` learner-floor) the native arc DELETES. Here there is
NO manual bootstrap orchestration (no v2-applied-baseline / v2-attach /
v2-load-replace / v2-apply-snapshot calls from the harness): the recovery is
fully automatic, driven by the engine.

The mechanism under test:
  - Compaction is mechanism A (a FIXED catch-up buffer, `REWIND_SNAPSHOT_GRACE`,
    set LOW here so the trigger fires quickly): each node compacts its WAL to
    `durable_apply_watermark − grace`, per node, with NO cross-node min-match
    floor. A peer further back than `grace` can no longer catch up from the log.
  - the leader detects the peer's next needed entry (`matched + 1`) is below its
    first (compacted) log index — the condition raft itself uses to decide a
    snapshot is needed. (NOT `ProgressState::Snapshot`: raft only enters that
    state when it actually obtains a snapshot from storage; rove's `snapshotCb`
    stays Unavailable because the bulk data goes out-of-band, so the peer would
    otherwise sit in `Probe` forever. See raft-native-alignment.md.)
  - the pump's `snapshotTriggerTick` detects it and queues a `(gid, peer)` job;
    the worker's `SnapshotCatchupThread` dumps the leader's store and pushes
    `v2-load-replace` + `v2-apply-snapshot {index, term}` to the peer over its
    `REWIND_PEER_URLS` HTTP endpoint. The peer's `match` advances past the
    leader's compacted first_index, StateSnapshot clears, and the tail replicates.

The victim is FROZEN (SIGSTOP), not killed: this models a partitioned/slow peer
whose raft group state stays live in RAM, so the recovery under test is purely
the snapshot trigger — NOT boot-time group recovery (a hard crash before a tenant
group's node-local manifest record is durabilized is a separate, pre-existing
recovery gap; freezing sidesteps it).

Sequence:
  1. provision acme [1,2,3], deploy, seed.
  2. pick a follower victim; FREEZE it (SIGSTOP) — quorum 2/3 survives.
  3. ⭐ churn writes on the surviving two so the leader compacts WELL past the
     victim's frozen index (> grace entries) — the victim is now un-catchable
     from the log.
  4. THAW the victim (SIGCONT). On the unfixed (snapshot-free) engine it strands
     forever ("receiving nothing"); here the native trigger + catch-up driver
     recover it.
  5. ⭐ assert the victim's raft last_index catches up to the leader's — with NO
     manual bootstrap — and a fresh post-recovery write replicates to it.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# Force the mechanism-A buffer LOW so a brief churn strands the victim past it
# (prod default is ~5000). Set BEFORE importing/spawning — `_spawn_node` inherits
# the process env. REWIND_PEER_URLS is set by the harness from the node ports.
os.environ["REWIND_SNAPSHOT_GRACE"] = "20"
# Disable auto-demote so the frozen voter is recovered purely via the snapshot
# trigger (not demoted to a learner mid-test) — isolates the mechanism.
os.environ["REWIND_AUTO_DEMOTE_LAG"] = "0"

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

SECRET = ["-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}"]
# last_index-vs-leader_last tolerance for "caught up" under live churn — the
# recovered peer is always a few in-flight entries behind the still-writing leader.
SLACK = 64


def _curl_json(url, *, method="GET", data=None):
    args = ["curl", "-s", "-w", "\n%{http_code}", "-m", "15",
            "--http2-prior-knowledge", "-X", method, *SECRET]
    if data is not None:
        args += ["-H", "Content-Type: application/json", "--data", data]
    args.append(url)
    out = subprocess.run(args, capture_output=True, text=True).stdout
    nl = out.rfind("\n")
    return int(out[nl + 1:].strip() or 0), out[:nl]


class Churner:
    """Background writer through the front door — advances the leader's applied
    index (and compaction first_index) while the victim is down + recovering."""

    def __init__(self, c, tenant):
        self.c, self.tenant = c, tenant
        self.n = self.ok = 0
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


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("snaptrig", nodes=3) as c:
        def url(node, suffix):
            return f"{c.node_url(node)}/_system/{suffix}"

        def member_status(leader):
            st, body = _curl_json(url(leader, "v2-member-status?tenant=acme"))
            try:
                return json.loads(body) if st == 200 else None
            except Exception:
                return None

        def last_index(node):
            st, body = _curl_json(url(node, "v2-last-index?tenant=acme"))
            try:
                return json.loads(body).get("last_index", 0) if st == 200 else 0
            except Exception:
                return 0

        def leader_last(leader):
            ms = member_status(leader)
            return ms.get("leader_last", 0) if ms else 0

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

        lead = c.leader_node("acme")
        victim = next(i for i in range(3) if i != lead)
        vnid = victim + 1
        print(f"       leader=node {lead + 1}; victim follower = node {vnid}")

        # Seed a few writes so the group is live + applied on all three nodes.
        for i in range(10):
            c.request("acme", "/?fn=handler", method="POST",
                      data=f'{{"value":"seed-{i}"}}', timeout=10)
        time.sleep(1.0)
        vproc = c.node_procs.get(victim)

        print(f"step 2: FREEZE node {vnid} (SIGSTOP) — quorum 2/3 survives")
        frozen_idx = last_index(victim)
        vproc.send_signal(signal.SIGSTOP)
        check(f"node {vnid} frozen", frozen_idx > 0, f"frozen at last_index={frozen_idx}")

        caught = False
        churn = Churner(c, "acme")
        churn.start()
        try:
            print("step 3: ⭐ churn so the leader compacts past the frozen victim "
                  f"(> grace={os.environ['REWIND_SNAPSHOT_GRACE']} entries)")
            target_gap = int(os.environ["REWIND_SNAPSHOT_GRACE"]) + 200
            t_end = time.time() + 30.0
            ll = 0
            while time.time() < t_end:
                ll = leader_last(c.leader_node("acme"))
                if ll >= frozen_idx + target_gap:
                    break
                time.sleep(0.3)
        finally:
            # STOP churn before recovery: with a tiny grace the peer can't stay
            # within the buffer of a still-writing leader, so it would re-trigger
            # the catch-up every tick — and each dump durabilizes the shared
            # manifest, contending with the leader's write loop. In prod (grace
            # ~5000) one snapshot lands the peer inside the buffer and it never
            # re-triggers; stopping churn here reproduces that one-shot recovery.
            churn.stop()
        # Give durabilizeTick (500ms) + a couple ticks to actually COMPACT the
        # leader's WAL first_index above the frozen victim's index.
        time.sleep(2.0)
        ll = leader_last(c.leader_node("acme"))
        check("leader advanced well past the frozen victim's index",
              ll >= frozen_idx + target_gap,
              f"leader_last={ll} frozen_idx={frozen_idx} (gap={ll - frozen_idx})")

        print(f"step 4: THAW node {vnid} (SIGCONT) — un-catchable from the log; "
              "only the snapshot trigger can recover it")
        vproc.send_signal(signal.SIGCONT)

        print(f"step 5: ⭐ node {vnid} auto-recovers via the snapshot trigger "
              "(NO manual bootstrap, no ongoing load)")
        t_end = time.time() + 40.0
        while time.time() < t_end:
            vlast = last_index(victim)
            if vlast > frozen_idx and vlast + SLACK >= ll:
                caught = True
                print(f"       recovered: node {vnid} last_index={vlast} "
                      f"leader_last={ll} (was frozen at {frozen_idx})")
                break
            time.sleep(0.5)
        check(f"⭐ node {vnid} auto-recovered past the compaction buffer "
              "(snapshot-free engine strands here)", caught,
              f"victim last_index={last_index(victim)} leader_last={ll}")
        print(f"       writer totals: {churn.ok} committed / {churn.n} attempted")

        # A fresh post-recovery write must replicate to the recovered node.
        w = c.request_retry("acme", "/?fn=handler", method="POST",
                            data='{"key":"final/marker","value":"after-recovery"}',
                            want_status=204, deadline_s=15)
        check("final write accepted (204)", w.status == 204, f"got {w.status}")
        repl, seen = False, ""
        for _ in range(40):
            seen = c.admin_kv_get("acme", "final/marker", node=victim).body
            if "after-recovery" in seen:
                repl = True; break
            time.sleep(0.5)
        check(f"⭐ fresh write replicated to recovered node {vnid}", repl,
              f"node{vnid} saw {seen!r}")

        # Advisory (NOT a gating check): the leader logs a trigger + caught-up
        # line, but a node's stdout→file is fully buffered, so mid-run the lines
        # may still sit unflushed in the process buffer. The behavioral proof
        # above is authoritative — reaching `leader_last` is only possible via the
        # catch-up, since the entries between `frozen_idx` and the compacted
        # first_index no longer exist in the leader's log. So just report what's
        # visible so far, without failing on buffering.
        all_logs = "".join(
            Path(p).read_text(errors="ignore") for p in c.log_paths.values() if Path(p).exists())
        seen_trig = "snapshot-trigger" in all_logs
        seen_catch = "snapshot-catchup" in all_logs
        print(f"  info trigger/catch-up log lines visible so far: "
              f"trigger={seen_trig} catchup={seen_catch} (advisory; may be buffered)")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS snapshot-trigger smoke (v2) — a peer that fell beyond the "
          "compaction buffer was AUTOMATICALLY recovered by the matched<first_index "
          "trigger + out-of-band catch-up driver, with no manual bootstrap, and a "
          "fresh write replicated to it. ⭐")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
