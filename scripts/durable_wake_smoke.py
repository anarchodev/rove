#!/usr/bin/env python3
"""End-to-end smoke for the §2.6 durable scheduled wake primitive
(docs/durable-wake-plan.md P0–P4).

Exercises the full path a customer sees: a handler calls
`scheduler.after(...)`, the engine's 1 Hz sweep fires the baked
`__system/scheduler_tick` when the watermark falls due, `scheduler_tick`
fans the entry out to its `target` as a `durable_wake` activation, and
the entry's `_sched/` keys are deleted in the target's own writeset.

  acme/schedfire   — calls scheduler.after(delay, "schedtarget", {tag})
  acme/schedtarget — the durable_wake target; records each fire to kv
                     (sched-fire-count, sched-last-id, sched-last-msg,
                     sched-last-scheduled-at-ns, sched-fires/{id})
  acme/readkey     — reads a kv key (existing demo helper)

Three gates:
  A. Basic fire — schedule a 2 s wake; observe sched-fire-count >= 1,
     the recorded id matches, msg round-trips, scheduled_at_ns is recent.
  B. Failover survival (the property that MOTIVATED the gap) — schedule
     a 4 s wake, kill the leader BEFORE it fires, and assert the new
     leader still fires it (volatile next_wake_ns reconstructed by
     sweepDurableWakesOnPromotion from the raft-replicated _sched state).
  C. Fail-loud cap — a >16 KiB msg trips SCHED_MAX_MSG_BYTES → 500.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "dwdwdwdwdwdwdwdwdwdwdwdwdwdwdwdwdwdwdwdwdwdwdwdwdwdwdwdwdwdwdwdw01"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"


def _readkey(cc, origin: str, key: str):
    return curl(cc, f"{origin}/readkey?key={key}", method="GET")


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="durable-wake-smoke",
        http_base=8520,
        raft_base=40620,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=1,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
    )
    with cluster as c:
        c.discover_leader()
        leader_port = c.leader_port()
        cc = c.curl_ctx(ACME_HOST)
        leader_origin = f"https://{ACME_HOST}:{leader_port}"
        print(f"ok  leader=node{c.leader_idx} ({c.addrs.http[c.leader_idx]})")

        # Wait for acme reachable on the leader.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            r = curl(cc, f"{leader_origin}/", method="GET")
            if r.status in (200, 404):
                break
            time.sleep(0.2)
        else:
            sys.exit("FAIL acme not reachable on leader")
        print("ok  acme reachable on leader")

        # ── Gate A: basic fire ────────────────────────────────────────
        r = curl(cc, f"{leader_origin}/schedfire?delay=2000&tag=basic", method="GET")
        if r.status != 200:
            sys.exit(f"FAIL schedfire (basic): status={r.status} body={r.body}")
        try:
            basic_id = json.loads(r.body)["id"]
        except (json.JSONDecodeError, KeyError):
            sys.exit(f"FAIL schedfire (basic) bad body: {r.body}")
        if not basic_id:
            sys.exit("FAIL schedfire (basic) returned empty id")
        print(f"ok  scheduled basic wake id={basic_id} (delay=2000ms)")

        # The wake rounds up to the next 1 s tick + the sweep is 1 Hz, so
        # allow generous headroom.
        deadline = time.monotonic() + 12.0
        count = 0
        while time.monotonic() < deadline:
            rr = _readkey(cc, leader_origin, "sched-fire-count")
            if rr.status == 200:
                count = int(rr.body.strip())
                if count >= 1:
                    break
            time.sleep(0.2)
        if count < 1:
            sys.exit("FAIL basic wake never fired (sched-fire-count still 0 after 12s)")
        print(f"ok  basic wake fired (sched-fire-count={count})")

        rr = _readkey(cc, leader_origin, "sched-last-id")
        if rr.status != 200 or rr.body.strip() != basic_id:
            sys.exit(f"FAIL sched-last-id={rr.body!r} != {basic_id!r}")
        rr = _readkey(cc, leader_origin, "sched-last-msg")
        if rr.status != 200 or json.loads(rr.body) != {"tag": "basic"}:
            sys.exit(f"FAIL sched-last-msg={rr.body!r} != {{'tag':'basic'}}")
        print("ok  fire recorded correct id + msg round-trip")

        rr = _readkey(cc, leader_origin, "sched-last-scheduled-at-ns")
        if rr.status != 200:
            sys.exit("FAIL sched-last-scheduled-at-ns absent")
        scheduled_at_ns = int(rr.body.strip())
        age_s = (time.time() * 1e9 - scheduled_at_ns) / 1e9
        if age_s > 20.0 or age_s < -20.0:
            sys.exit(f"FAIL scheduled_at_ns {age_s:.1f}s from now (expected recent)")
        print(f"ok  scheduled_at_ns is recent ({age_s:.1f}s)")

        # Per-id fire count == 1 on the normal path (exactly-once: the
        # entry's deletes committed with the target's writeset).
        rr = _readkey(cc, leader_origin, f"sched-fires/{basic_id}")
        if rr.status == 200 and int(rr.body.strip()) != 1:
            print(f"note basic wake fired {rr.body.strip()} times "
                  "(>1 = a benign at-least-once re-fire, not a failure)")

        # ── Gate B: failover survival ─────────────────────────────────
        # Schedule a wake far enough out that it won't fire before we
        # kill the leader (4 s), using a key so the id is deterministic.
        r = curl(cc, f"{leader_origin}/schedfire?delay=4000&tag=failover&key=ff-wake", method="GET")
        if r.status != 200:
            sys.exit(f"FAIL schedfire (failover): status={r.status} body={r.body}")
        ff_id = json.loads(r.body)["id"]
        print(f"ok  scheduled failover wake id={ff_id} (delay=4000ms)")

        # Let the _sched entry replicate through raft, then kill the
        # leader BEFORE the 4 s fire.
        time.sleep(1.5)
        orig_leader = c.leader_idx
        print(f"killing leader node{orig_leader} before the wake fires…")
        c.stop_node(orig_leader)

        # New leader: discover_leader skips the dead node.
        new_leader = c.discover_leader(timeout_s=25.0)
        if new_leader == orig_leader:
            sys.exit("FAIL leader index unchanged after kill")
        new_origin = f"https://{ACME_HOST}:{c.leader_port()}"
        print(f"ok  new leader=node{new_leader} after failover")

        # The new leader's promotion sweep reconstructs next_wake_ns from
        # the replicated _sched state and fires the wake. Poll its
        # per-id fire counter (raft-replicated kv → visible on the new
        # leader).
        deadline = time.monotonic() + 25.0
        ff_fires = 0
        while time.monotonic() < deadline:
            rr = _readkey(cc, new_origin, f"sched-fires/{ff_id}")
            if rr.status == 200:
                ff_fires = int(rr.body.strip())
                if ff_fires >= 1:
                    break
            time.sleep(0.3)
        if ff_fires < 1:
            sys.exit("FAIL failover wake never fired on the new leader (25s)")
        print(f"ok  failover wake fired on the new leader (sched-fires/{ff_id}={ff_fires}) "
              "— survived leader change")

        # ── Gate C: fail-loud cap (SCHED_MAX_MSG_BYTES) ───────────────
        r = curl(cc, f"{new_origin}/schedfire?big=20000", method="GET")
        if r.status != 500:
            sys.exit(f"FAIL oversized msg should trip SCHED_MAX_MSG_BYTES (500), got {r.status}: {r.body}")
        print("ok  >16 KiB msg tripped SCHED_MAX_MSG_BYTES (fail-loud 500)")

        print("\ndurable-wake smoke passed (P0–P4: schedule → fire → "
              "failover-survival → fail-loud cap)")
        return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.TimeoutExpired as e:
        sys.exit(f"FAIL subprocess timeout: {e}")
