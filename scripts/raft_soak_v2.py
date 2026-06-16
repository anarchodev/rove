#!/usr/bin/env python3
"""Raft election/heartbeat SIZING SOAK (docs/raft-best-practices.md "how to size
election/heartbeat in our environment").

Drives sustained, HIGH-throughput WRITE load through a 3-node cluster and measures
the two inputs that justify the election timeout:

  • SPURIOUS ELECTIONS — leadership acquisitions beyond the one-per-group
    formation baseline, observed WHILE under load. A correctly-sized election
    timeout yields ZERO: leadership stays put. Any >0 means the timeout is below
    the pump/fsync/scheduler pause tail under load — widen REWIND_RAFT_TICK_MS.
  • broadcastTime — the heartbeat RTT histogram under load.

Three things make this a REAL stressor (vs an idle functional smoke):
  1. Real disk. The raft WAL must fsync to actual NVMe, not tmpfs — a too-tight
     election timeout only flakes when fsync STALLS. This script forces
     V2_SMOKE_DATA_BASE onto $HOME (real disk) before the lib loads; it refuses
     to run on tmpfs.
  2. High throughput. Load is driven by h2load (persistent h2c connections, many
     concurrent streams) through the FRONT door against the real handler write
     path (front → worker → JS kv.set → propose → commit) — curl-per-request
     tops out ~300/s and never pressures the pump.
  3. No rate cap. The tenant's plan is raised to effectively-unlimited so the
     front-door write path isn't throttled (the realistic path, uncapped).

Run at the default tick, then REWIND_RAFT_TICK_MS=10, and compare the spurious
counts — that comparison justifies the value.

  RAFT_SOAK_SECONDS    load duration (default 90)
  RAFT_SOAK_CLIENTS    h2load connections (default 8)
  RAFT_SOAK_STREAMS    concurrent streams per connection (default 4) — the front
                       is single-threaded, so total concurrency c×m past ~64
                       saturates it into 5xx; ~32 maximizes clean throughput
  REWIND_RAFT_TICK_MS  raft tick interval handed to the nodes (labels the run)
  V2_SMOKE_DATA_BASE   WAL data base (default ~/.cache/rove-soak — must be disk)

Needs S3 env: `set -a; . ./.env; set +a` first; h2load on PATH.
Build: `zig build rewind rewind-cp rewind-front files-server-v2`
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import time

# Force the raft WAL onto REAL DISK (not tmpfs) BEFORE importing the lib (it reads
# V2_SMOKE_DATA_BASE at import). Override explicitly if $HOME isn't the fast disk.
os.environ.setdefault("V2_SMOKE_DATA_BASE", os.path.expanduser("~/.cache/rove-soak"))

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from smoke_lib_v2 import (  # noqa: E402
    V2Cluster, rpc_wrap, metric_counter, metric_hist_mean_us,
)

# POST writes a kv key (fsync pressure on the leader's pump); GET returns "ready".
HANDLER_SRC = """\
export function handler() {
    if (request.method === "POST") {
        const body = JSON.parse(request.body || "{}");
        kv.set("soak/" + (body.k ?? "x"), body.v ?? "");
        response.status = 204;
        return "";
    }
    return "ready";
}
"""

# Effectively-unlimited limits so the front-door write path isn't rate-throttled.
PLAN_UNLIMITED = ('{"tier":"enterprise","overrides":'
                  '{"request_capacity":100000000,"request_refill_per_sec":100000000}}')


def fstype_of(path: str) -> str:
    r = subprocess.run(["findmnt", "-no", "FSTYPE", "--target", path],
                       capture_output=True, text=True)
    return r.stdout.strip() or "?"


def sum_acquisitions(c: V2Cluster, n: int = 3) -> float:
    s = 0.0
    for i in range(n):
        v = metric_counter(c.metrics(i), "raft_leadership_acquisitions_total")
        if v is not None:
            s += v
    return s


def parse_h2load(out: str) -> dict:
    """Pull req/s + status-code split from h2load's summary."""
    res = {"req_per_s": None, "c2xx": 0, "c3xx": 0, "c4xx": 0, "c5xx": 0, "failed": None}
    import re
    m = re.search(r"([\d.]+)\s+req/s", out)
    if m:
        res["req_per_s"] = float(m.group(1))
    m = re.search(r"status codes:\s*(\d+)\s+2xx,\s*(\d+)\s+3xx,\s*(\d+)\s+4xx,\s*(\d+)\s+5xx", out)
    if m:
        res["c2xx"], res["c3xx"], res["c4xx"], res["c5xx"] = (int(m.group(i)) for i in range(1, 5))
    m = re.search(r"requests:.*?(\d+)\s+failed", out)
    if m:
        res["failed"] = int(m.group(1))
    return res


def main() -> int:
    dur = float(os.environ.get("RAFT_SOAK_SECONDS", "90"))
    clients = int(os.environ.get("RAFT_SOAK_CLIENTS", "8"))
    streams = int(os.environ.get("RAFT_SOAK_STREAMS", "4"))
    tick = os.environ.get("REWIND_RAFT_TICK_MS")
    tick_label = f"{tick}ms" if tick else "default(1ms)"
    data_base = os.environ["V2_SMOKE_DATA_BASE"]
    os.makedirs(data_base, exist_ok=True)
    fstype = fstype_of(data_base)

    h2load = shutil.which("h2load")
    print(f"=== raft sizing soak: tick={tick_label} duration={dur:.0f}s "
          f"h2load c={clients} m={streams} ===")
    print(f"    WAL data base: {data_base}  (fstype={fstype})")
    if fstype in ("tmpfs", "ramfs"):
        print(f"REFUSING: {data_base} is {fstype} (RAM) — WAL fsync would be a no-op, "
              "the soak can't probe the real fsync stall tail. Set V2_SMOKE_DATA_BASE "
              "to a real-disk path.")
        return 2
    if not h2load:
        print("REFUSING: h2load not on PATH (needed for high-throughput load).")
        return 2

    with V2Cluster.spawn("raftsoak", nodes=3) as c:
        print("setup: provision + deploy the write handler")
        if c.provision("acme").status != 204:
            print("FAIL provision")
            return 1
        lead0 = c.leader_node("acme")
        dep = c.deploy_handlers("acme", {"index.mjs": rpc_wrap(HANDLER_SRC)},
                                node=lead0 if lead0 is not None else 0)
        if not dep:
            print("FAIL deploy_handlers")
            c.dump_node_log(grep=["deploy", "loader", "error", "warn"])
            return 1
        if c.wait_for_handler("acme", "/?fn=handler", want_body="ready").status != 200:
            print("FAIL handler not live")
            return 1

        # Raise limits on every node (per-node hot-path state; the leader enforces,
        # but a mid-soak leadership change must find the new leader already uncapped).
        for i in range(3):
            c.set_plan("acme", PLAN_UNLIMITED, node=i)

        print("setup: settling 6s before baseline...")
        time.sleep(6.0)
        base_acq = sum_acquisitions(c)
        print(f"baseline: cluster-wide leadership acquisitions = {base_acq:.0f}")

        # ── h2load write load through the front door (real path) ──────────
        body_path = os.path.join(tempfile.gettempdir(), f"raftsoak-body-{os.getpid()}.json")
        with open(body_path, "w") as f:
            f.write('{"k":"soak","v":"x"}')
        url = f"{c.front_url()}/?fn=handler"
        cmd = [h2load, "-D", str(int(dur)), "-c", str(clients), "-m", str(streams),
               "-H", f"Host: {c.host_for('acme')}", "-d", body_path, url]
        print(f"load: {' '.join(cmd)}")
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

        # Sample spurious elections every 5s while h2load runs.
        spurious_events = []
        last_seen = base_acq
        t_start = time.time()
        next_sample = t_start + 5.0
        while proc.poll() is None:
            time.sleep(0.5)
            now = time.time()
            if now >= next_sample:
                next_sample += 5.0
                cur = sum_acquisitions(c)
                if cur > last_seen:
                    spurious_events.append((now - t_start, cur - last_seen))
                    last_seen = cur
                lead = c.leader_now("acme")
                print(f"  t={now - t_start:5.1f}s  acq={cur:.0f}  "
                      f"leader=node{(lead + 1) if lead is not None else '?'}")

        out = proc.stdout.read() if proc.stdout else ""
        elapsed = time.time() - t_start
        try:
            os.unlink(body_path)
        except OSError:
            pass

        # ── results ───────────────────────────────────────────────────────
        final_acq = sum_acquisitions(c)
        spurious = final_acq - base_acq
        h = parse_h2load(out)
        lead = c.leader_now("acme")
        hb = metric_hist_mean_us(c.metrics(lead), "raft_heartbeat_rtt_us") if lead is not None else None

        print("\n=== SOAK RESULTS ===")
        print(f"SOAK_TICK_MS={tick or 1}")
        print(f"SOAK_WAL_FSTYPE={fstype}")
        print(f"SOAK_DURATION_S={elapsed:.1f}")
        print(f"SOAK_H2LOAD_REQ_PER_S={h['req_per_s']}")
        print(f"SOAK_STATUS_2xx={h['c2xx']}  3xx={h['c3xx']}  4xx={h['c4xx']}  5xx={h['c5xx']}  failed={h['failed']}")
        print(f"SOAK_SPURIOUS_ELECTIONS={spurious:.0f}")
        if spurious_events:
            print("  spurious timeline: " +
                  ", ".join(f"+{d:.0f}@{t:.0f}s" for t, d in spurious_events))
        if hb is not None:
            print(f"SOAK_HB_RTT_MEAN_US={hb[0]:.1f}")
            print(f"SOAK_HB_RTT_N={hb[1]}")

        ok = spurious <= 0 and (h["c2xx"] or 0) > 0
        verdict = "zero spurious elections" if spurious <= 0 else f"{spurious:.0f} SPURIOUS ELECTION(S)"
        print(f"\n{'PASS' if ok else 'FAIL'} — {verdict} under "
              f"{h['req_per_s'] or 0:.0f} req/s ({h['c2xx']} 2xx) for {elapsed:.0f}s "
              f"on {fstype} at tick={tick_label}. " +
              ("Election timeout is comfortably above the load pause-tail."
               if spurious <= 0 else
               "Election timeout is BELOW the load pause-tail — widen REWIND_RAFT_TICK_MS."))
        return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
