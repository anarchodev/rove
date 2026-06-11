#!/usr/bin/env python3
"""V2 port of `durable_wake_smoke.py` — the §2.6 durable scheduled wake
primitive (durable-wake P0–P4; docs/architecture/effects-and-handlers.md) on the `V2Cluster` harness.

A handler calls `scheduler.after(...)`, the engine's leader-gated sweep fires
the baked `__system/scheduler_tick` when the watermark falls due, the tick
fans the entry out to its `target` as a `durable_wake` activation, and the
entry's `_sched/` keys are deleted in the target's own writeset.

Handler JS is reused VERBATIM from the V1 demo tenant
(examples/loop46-demo-tenants/acme/{schedfire,schedtarget}).

Gates (essential behavior, unchanged from V1):
  A. Basic fire — schedule a 2 s wake; observe sched-fire-count >= 1, the
     recorded id matches, msg round-trips, scheduled_at_ns is recent.
  B. Failover survival (the property that MOTIVATED the gap) — schedule a
     wake, kill the leader BEFORE it fires, and assert the new leader still
     fires it (the per-tenant-group durable _sched state survives + the new
     leader's promotion sweep reconstructs next_wake_ns). nodes=3.
  C. Fail-loud cap — a >16 KiB msg trips SCHED_MAX_MSG_BYTES → 500.

V2 specifics (vs V1): plaintext h2c (no TLS/cacert); no V1 discover_leader —
multi-node uses V2Cluster.leader_node/stop_node + request_retry. Side-effect
reads go through the worker's move-secret-gated /_system/v2-kv
(c.admin_kv_get) instead of the /readkey handler + leader-direct origin.
Scheduler fires are leader-gated + throttled-sweep → generous deadlines.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants" / "acme"


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


# Handler JS reused verbatim from the V1 demo tenant.
HANDLERS = {
    "schedfire/index.mjs": _src("schedfire/index.mjs"),
    "schedtarget.mjs": _src("schedtarget.mjs"),
}


def _kv_int(c, key: str, *, node: int = 0) -> int | None:
    rr = c.admin_kv_get("acme", key, node=node)
    if rr.status == 200 and rr.body.strip().lstrip("-").isdigit():
        return int(rr.body.strip())
    return None


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    # nodes=3 — Gate B kills the leader before a scheduled wake is due and
    # asserts the new leader's promotion sweep still fires it.
    with V2Cluster.spawn("durwake", nodes=3) as c:
        print("step 1: provision + deploy the scheduling handlers")
        r = c.provision("acme")
        check("provision acme → 204", r.status == 204, f"got {r.status} {r.body!r}")
        # release() writes _deploy/current through raft — it must hit the
        # group's leader (else 503). The group formed at provision; target it.
        lead0 = c.leader_node("acme")
        check("leader present pre-deploy", lead0 is not None, f"lead={lead0}")
        try:
            dep_id = c.deploy_handlers("acme", HANDLERS,
                                       node=lead0 if lead0 is not None else 0)
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        r = c.wait_for_handler("acme", "/schedfire?delay=999999&tag=__warm",
                               want_status=200, timeout_s=25.0)
        if r.status != 200:
            check("schedfire reachable", False, f"got {r.status} {r.body!r}")
            c.dump_node_log(grep=["deploy", "loader", "manifest", "sched",
                                  "resolve", "404", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1
        print("ok  scheduling handlers reachable")

        # ── Gate A: basic fire ────────────────────────────────────────
        r = c.get("acme", "/schedfire?delay=2000&tag=basic")
        basic_id = None
        if r.status != 200:
            check("Gate A: schedfire", False, f"status={r.status} body={r.body!r}")
        else:
            try:
                basic_id = json.loads(r.body)["id"]
                print(f"ok  scheduled basic wake id={basic_id} (delay=2000ms)")
            except Exception as e:
                check("Gate A: schedfire JSON", False, f"{e} body={r.body!r}")
        check("Gate A: schedfire returned an id", bool(basic_id))

        if basic_id:
            # Wake rounds up to the next tick + the sweep is throttled →
            # generous headroom.
            count = 0
            deadline = time.monotonic() + 25.0
            while time.monotonic() < deadline:
                v = _kv_int(c, "sched-fire-count")
                if v is not None and v >= 1:
                    count = v
                    break
                time.sleep(0.4)
            check("Gate A: basic wake fired (sched-fire-count>=1)", count >= 1,
                  "sched-fire-count still 0 after 25s" if count < 1 else "")
            if count < 1:
                c.dump_node_log(grep=["sched", "wake", "durable", "tick", "error", "warn"])

            if count >= 1:
                rr = c.admin_kv_get("acme", "sched-last-id")
                check("Gate A: recorded id matches", rr.status == 200 and rr.body.strip() == basic_id,
                      f"sched-last-id={rr.body!r} != {basic_id!r}")
                rr = c.admin_kv_get("acme", "sched-last-msg")
                msg_ok = False
                try:
                    msg_ok = rr.status == 200 and json.loads(rr.body) == {"tag": "basic"}
                except Exception:
                    pass
                check("Gate A: msg round-trip {tag:'basic'}", msg_ok, f"got {rr.body!r}")

                rr = c.admin_kv_get("acme", "sched-last-scheduled-at-ns")
                if rr.status == 200 and rr.body.strip().isdigit():
                    age_s = (time.time() * 1e9 - int(rr.body.strip())) / 1e9
                    check("Gate A: scheduled_at_ns recent (|age|<25s)", abs(age_s) < 25.0,
                          f"{age_s:.1f}s from now")
                else:
                    check("Gate A: scheduled_at_ns present", False, f"got {rr.body!r}")

        # ── Gate C: fail-loud cap (SCHED_MAX_MSG_BYTES) ───────────────
        # Run before the kill (independent of failover) so the deployment is
        # loaded on the leader serving it.
        print("step 2: oversized msg trips SCHED_MAX_MSG_BYTES")
        r = c.request_retry("acme", "/schedfire?big=20000", want_status=500)
        check("Gate C: >16 KiB msg → 500 (fail-loud)", r.status == 500,
              f"got {r.status}: {r.body!r}")

        # ── Gate B: failover survival ─────────────────────────────────
        print("step 3: schedule a wake, kill the leader before it fires, "
              "assert the new leader fires it")
        # Schedule far enough out that it won't fire before the kill, with a
        # deterministic id (key=).
        r = c.request_retry("acme", "/schedfire?delay=6000&tag=failover&key=ff-wake",
                            want_status=200)
        ff_id = None
        if r.status != 200:
            check("Gate B: schedfire (failover)", False, f"status={r.status} body={r.body!r}")
        else:
            try:
                ff_id = json.loads(r.body)["id"]
                print(f"ok  scheduled failover wake id={ff_id} (delay=6000ms)")
            except Exception as e:
                check("Gate B: schedfire (failover) JSON", False, f"{e} body={r.body!r}")

        if ff_id:
            # Let the _sched entry replicate through the group.
            time.sleep(1.5)
            orig_leader = c.leader_node("acme")
            check("Gate B: found a leader for acme", orig_leader is not None)
            if orig_leader is not None:
                print(f"killing leader node{orig_leader + 1} before the wake fires…")
                c.stop_node(orig_leader)
                new_leader = c.leader_node("acme", deadline_s=30.0)
                check("Gate B: a new leader was elected", new_leader is not None,
                      "no leader after kill")
                check("Gate B: leader changed", new_leader is not None and new_leader != orig_leader,
                      f"leader unchanged ({new_leader})")

                # ⭐ Gap A (deploy auto-load on promotion): on V2 a promoted
                # follower's on-promotion hook (`runPromotionHook` in
                # `src/rewind/main.zig`) reads the replicated
                # `_deploy/current` and enqueues the loader, so the handler is
                # served on the new leader with NO re-release. The `__warm`
                # probe schedules a far-future (delay=999999) wake purely to
                # confirm the handler serves — it does NOT arm a near-term
                # `next_wake_ns` (monotone-min keeps any earlier ff-wake
                # arming), so it cannot fire the overdue `ff-wake` within the
                # 40 s window below; only the promotion sweep can.
                w = c.request_retry("acme", "/schedfire?delay=999999&tag=__warm",
                                    want_status=200, deadline_s=25.0)
                check("Gate B: deployment auto-loaded on new leader (no re-release)",
                      w.status == 200, f"warm got {w.status} {w.body!r}")

                # ⭐ Gap B (promotion wake reconstruction): the same hook runs
                # `sweepDurableWakesOnPromotion`, which fires
                # `__system/scheduler_tick` for any tenant with `_sched/by_time`
                # entries — reconstructing the volatile `next_wake_ns` watermark
                # (never raft-replicated) from the replicated `_sched` state, so
                # the overdue `ff-wake` that survived the leader change fires on
                # its own. NO nudge: the assertion below is now a real test of
                # the automatic promotion reconstruction.

                # Per-id fire counter is raft-replicated → visible on the
                # surviving nodes.
                ff_fires = 0
                read_node = new_leader if new_leader is not None else (
                    (orig_leader + 1) % 3)
                deadline = time.monotonic() + 40.0
                while time.monotonic() < deadline:
                    v = _kv_int(c, f"sched-fires/{ff_id}", node=read_node)
                    if v is not None and v >= 1:
                        ff_fires = v
                        break
                    time.sleep(0.5)
                check("Gate B: failover wake fired on the new leader", ff_fires >= 1,
                      "sched-fires never reached 1 within 40s" if ff_fires < 1 else "")
                if ff_fires < 1:
                    for i in range(3):
                        if i != orig_leader:
                            c.dump_node_log(node=i, grep=["sched", "wake", "sweep",
                                                          "promot", "leader", "tick",
                                                          "error", "warn"])
                else:
                    print(f"ok  failover wake fired (sched-fires/{ff_id}={ff_fires}) "
                          "— survived leader change")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS durable-wake smoke (v2): schedule → fire → failover-survival "
          "→ fail-loud cap")
    return 0


if __name__ == "__main__":
    sys.exit(main())
