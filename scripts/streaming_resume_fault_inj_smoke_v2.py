#!/usr/bin/env python3
"""V2 port of `streaming_resume_fault_inj_smoke.py` — effect-reification
Phase 4.0.b regression gate on the `V2Cluster` harness.

`docs/streaming-model.md` §2: "a chunk reaches the wire only after the
activation that produced it has committed." The resume/wake path must NOT
let a `tick` chunk escape while its `kv.set` propose is parked awaiting a
quorum it can never reach.

THE FAULT-TRIGGER MECHANISM (V2): there is no env-var / magic-key fault
hook. The fault is a *runtime quorum denial* — exactly as in V1, but on
the V2 multi-raft stack:

  - Provision `streamfi` on a 3-NODE cluster. `/_control/provision` empty-
    attaches the tenant's raft group to ALL THREE nodes (src-v2/cp/main.zig
    handleProvision → attachToAll), so the group spans the cluster and a
    write needs a 2-of-3 quorum.
  - Open the held SSE stream DIRECT to the leader node. The inbound
    activation is read-only (just `stream.write("event: ready…")` +
    `on.timer(1500)`), so it commits without raft and `ready` ships.
  - SIGSTOP the two FOLLOWERS. Quorum is now impossible: the leader is
    alone, so any subsequent propose parks on the commit-wait deadline.
  - At T+1.5s the timer wake fires. `onWake` does `kv.set("counter", …)`
    + `stream.write("event: tick…")`. The kv.set's propose parks (no
    quorum); the staged `tick` chunk MUST NOT reach the wire during the
    commit-wait window. At the deadline the parked unit faults and the
    staged chunk is discarded — the customer only ever saw `ready`.

  ASSERTION 1 (regression guard): the SSE body contains `event: ready`
  and must NOT contain `event: tick` within the fault window.

  ASSERTION 2 (advisory): after killing the (frozen-out) leader, thawing
  the followers, and a new leader electing, the tenant's `counter` key is
  absent (read via `/_system/v2-kv`) — the kv.set never reached quorum.
  Unlike V1 (no kv-read route on streamfi), V2 *does* expose a
  move-secret-gated debug read, so we can assert the durable absence
  directly.

CRITICAL V2 streaming addressing: the held SSE GET goes DIRECT to the
leader node (the front door buffers the full response, so an open-ended
SSE stream yields 0 bytes within the read window).

The handler JS is reused VERBATIM from the V1 demo tenant
(`examples/loop46-demo-tenants/streaming_fault_inj/index.mjs`) — it
already uses the V2 `stream.*` / `on.timer` / `onWake` surface.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, MOVE_SECRET  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants"

# Handler JS reused VERBATIM from the V1 demo tenant. `export default` is
# the held SSE stream (ready frame + 1.5s timer); `onWake` is the gated
# write+chunk arm.
STREAMFI_SRC = (DEMO / "streaming_fault_inj" / "index.mjs").read_text()

# A trivial root readiness probe so we can poll the deployment-loaded
# state without opening the (held) default stream.
READY_SRC = 'export function handler() { return "ready"; }\n'


def _open_stream_direct(node_base: str, path: str, host: str,
                        max_time: float) -> subprocess.Popen:
    """Held SSE GET DIRECT to the leader node (the front buffers full
    responses, so an open-ended stream would yield 0 bytes in the read
    window). Raw curl -N (no buffering), --max-time read window, -D -
    headers — mirrors the V1 watcher."""
    args = [
        "curl", "-sS", "--http2-prior-knowledge", "-N",
        "-H", f"Host: {host}",
        "--max-time", str(max_time),
        "-D", "-", "-o", "-", "-X", "GET",
        f"{node_base}{path}",
    ]
    return subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    # 3 nodes so a frozen 2-of-3 follower set denies quorum (the fault).
    with V2Cluster.spawn("strm-faultinj", nodes=3) as c:
        host = c.host_for("streamfi")

        print("step 1: provision tenant 'streamfi' (group forms across all 3 nodes)")
        r = c.provision("streamfi")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")
        if r.status != 204:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        # The release writes `_deploy/current` through raft, so it must hit
        # the leader (a follower 503s "raft commit failed").
        Ldeploy = c.leader_node("streamfi")
        if Ldeploy is None:
            check("leader for deploy", False, "no leader for release")
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print(f"step 2: deploy streamfi handler via leader node{Ldeploy} "
              "(+ a root readiness probe)")
        try:
            dep_id = c.deploy_handlers("streamfi", {
                "index.mjs": READY_SRC,
                "stream/index.mjs": STREAMFI_SRC,
            }, node=Ldeploy)
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 3: wait for the deployment to load (GET / → 'ready')")
        ready = c.wait_for_handler("streamfi", "/?fn=handler", want_body="ready")
        check("deployment loaded", ready.status == 200 and "ready" in ready.body,
              f"got {ready.status} {ready.body!r}")
        if ready.status != 200:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve",
                                  "404", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 4: find the leader node for streamfi's group")
        L = c.leader_node("streamfi")
        check("found a leader", L is not None, f"leader_node={L}")
        if L is None:
            c.dump_node_log(grep=["leader", "elect", "raft", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        followers = [i for i in range(3) if i != L]
        print(f"  ok  leader=node{L} followers={followers}")

        print("step 5: open the held SSE stream DIRECT to the leader node")
        # The `/stream` handler is the SSE held stream (ready frame + 1.5s
        # timer wake). --max-time 5s bounds the read window across the
        # T+1.5s wake + T+~3.5s commit-wait fault.
        watcher = _open_stream_direct(c.node_url(L), "/stream", host, max_time=5.0)

        # Let the inbound activation ship `ready` + park the 1.5s timer.
        time.sleep(0.3)

        print(f"step 6: SIGSTOP followers {followers} — quorum now impossible")
        for i in followers:
            c.node_procs[i].send_signal(signal.SIGSTOP)
        print(f"  ok  froze followers {followers} (SIGSTOP)")

        # Wait through the fault window:
        #   T+1.5s  onWake fires → kv.set propose parks (no quorum)
        #   T+~3.5s commit-wait deadline → fault → staged `tick` discarded
        try:
            stdout, _ = watcher.communicate(timeout=8.0)
        except subprocess.TimeoutExpired:
            watcher.kill()
            stdout, _ = watcher.communicate()

        raw = stdout or b""
        split = raw.rfind(b"\r\n\r\n")
        if split < 0:
            print(f"  INCONCLUSIVE  no header block in response: {raw!r}")
            for i in followers:
                if c.node_procs[i].poll() is None:
                    c.node_procs[i].send_signal(signal.SIGCONT)
            c.dump_node_log(node=L, grep=["stream", "wake", "commit", "fault",
                                          "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 2
        body_str = raw[split + 4:].decode(errors="replace")

        # Gate 1: `ready` must be present (the stream opened pre-freeze).
        # Absence ⇒ the smoke never reached the fault window (inconclusive).
        if "event: ready" not in body_str:
            print(f"  INCONCLUSIVE  initial `ready` frame missing — the stream "
                  f"never opened pre-freeze. body={body_str!r}")
            for i in followers:
                if c.node_procs[i].poll() is None:
                    c.node_procs[i].send_signal(signal.SIGCONT)
            c.dump_node_log(node=L, grep=["stream", "ready", "deploy", "loader",
                                          "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 2

        # Gate 2 (THE regression gate): `tick` must NOT appear in the body.
        # Pre-fix the wake hop's chunk leaks within ~1.6s of freeze;
        # post-fix it never does (the parked unit's fault arm discards the
        # staged chunk).
        leaked = "event: tick" in body_str
        print(f"    stream body: bytes={len(body_str)} "
              f"ready={'event: ready' in body_str} "
              f"tick={'event: tick' in body_str}")
        check("ASSERTION 1: resume-hop `tick` did NOT escape pre-commit",
              not leaked, f"body={body_str!r}" if leaked else "")

        print("step 7: advisory — kill the frozen-out leader, thaw followers, "
              "re-elect, assert `counter` absent on the new leader")
        # Kill the leader (it was the only live quorum member; the followers
        # were frozen, so nothing committed). Thaw the followers → they form
        # a fresh 2-node quorum + elect a new leader.
        c.node_procs[L].send_signal(signal.SIGKILL)
        c.node_procs[L].wait()
        for i in followers:
            if c.node_procs[i].poll() is None:
                c.node_procs[i].send_signal(signal.SIGCONT)

        # New leader among the (now-thawed) followers.
        nl = None
        deadline = time.time() + 25.0
        while time.time() < deadline and nl is None:
            for i in followers:
                if c.node_procs[i].poll() is None:
                    r = c.node_request(f"/_system/v2-leader?tenant=streamfi",
                                       node=i,
                                       headers={"X-Rewind-Move-Secret": MOVE_SECRET})
                    if r.status == 200:
                        nl = i
                        break
            if nl is None:
                time.sleep(0.4)
        if nl is None:
            print("  INCONCLUSIVE  no new leader within 25s (advisory only)")
            advisory = "no new leader elected; rely on ASSERTION 1"
        else:
            print(f"  ok  killed node{L}; new leader=node{nl}")
            r = c.admin_kv_get("streamfi", "counter", node=nl)
            # An absent key returns 404 (or 200 with an empty/sentinel body).
            absent = r.status == 404 or (r.status == 200 and r.body.strip() == "")
            check("ASSERTION 2 (advisory): `counter` absent on the new leader",
                  absent, f"got {r.status} {r.body!r}")
            advisory = f"counter read on new leader: {r.status} {r.body!r}"

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        print("FAIL  resume-hop chunk ESCAPED pre-commit OR durable state leaked "
              "— streaming-model.md §2 / Phase 4.0.b commit-arm chunk-gate "
              "regressed.")
        return 1

    print("\nPASS streaming-resume-fault-inj smoke (v2): the resume-hop's "
          "`tick` frame did NOT escape during the frozen-quorum window "
          "(streaming-model.md §2 honored), and `counter` never reached "
          "durable quorum.")
    print(f"     advisory: {advisory}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
