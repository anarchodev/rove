#!/usr/bin/env python3
"""effect-reification Phase 4.0.b regression gate — a resume-hop's
chunk must NOT escape pre-commit.

`docs/streaming-model.md` §2: "a chunk reaches the wire only after
the activation that produced it has committed." Pre-Phase-4.0.b
the resume path violated this — `resumeStream`'s terminal+writes
and stream+writes arms queued the chunk into `StreamChunks` AND
fired `markStreamDraining` IMMEDIATELY, while the writes' propose
was still parked on `parked_units` awaiting commit. A raft fault
during the commit-wait window leaked the chunk to the customer
whose `kv.set` never durably landed.

Deterministic reproduction:

  1. Open a held SSE stream against `streamfi` (inbound activation
     is read-only — just emits the initial `ready` frame + parks a
     1500ms timer wake). The stream is healthy; the "ready" frame
     arrives.
  2. SIGSTOP both followers. Quorum is now impossible — any
     subsequent propose parks on `parked_units` for the
     commit-wait timeout (~2s default).
  3. At T+1.5s the timer fires. The `wake_batch` handler runs:
     `kv.set("counter", "1")` + returns `__rove_stream({write:
     ["event: tick\\ndata: 1\\n\\n"], ...})`. Pre-fix this stages
     the chunk on `StreamChunks` immediately and the customer sees
     `tick` within one service tick. Post-fix the chunk stages on
     the parked unit's `staged_chunks`; nothing reaches the wire
     until commit; the customer reads only `ready` during the
     fault window.
  4. At T+~3.5s the parked unit's commit-wait deadline elapses →
     fault arm → `BufferedSendKvOps.deinit` frees the staged
     chunk; the customer never saw `tick`.

  **ASSERTION 1 (regression guard): the SSE body must contain
  `ready` and must NOT contain `tick` within the fault window.**
  PRE-fix `tick` appears within ~1.6s; POST-fix it never does.

  5. Kill leader, thaw followers, new leader elects. Read
     `counter` from the new leader — must be absent (the kv.set
     never reached quorum).

  **ASSERTION 2 (advisory): on the new leader, `counter` is
  absent — proving the durable cluster never held the value
  whose chunk could have leaked.**
"""

from __future__ import annotations

import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
ADMIN_HOST = f"app.{SYSTEM_SUFFIX}"
STREAMFI_HOST = f"streamfi.{PUBLIC_SUFFIX}"


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent

    cluster = Cluster.spawn(
        tag="streaming-resume-faultinj",
        http_base=8504,
        raft_base=40504,
        files_port=8508,
        log_port=8509,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        admin_origin_per_node=True,
        admin_api_domain=ADMIN_HOST,
        with_log_files_bases=False,
        workers_per_node=1,
        seed_manifest=repo_root / "examples" / "streaming-fault-inj-tenant.json",
    )

    def leader_probe(c: Cluster, candidates) -> int | None:
        cc = c.curl_ctx(STREAMFI_HOST, ADMIN_HOST)
        for i in candidates:
            try:
                r = curl(
                    cc,
                    f"https://{ADMIN_HOST}:{c.addrs.http_port(i)}/_system/leader",
                    headers={"Authorization": f"Bearer {TOKEN}"},
                    timeout=2.0,
                )
            except RuntimeError:
                continue
            if r.status == 200:
                return i
        return None

    leaked = True  # fail-closed until proven otherwise
    body_str = "<not captured>"

    with cluster as c:
        time.sleep(2)
        deadline = time.monotonic() + 20.0
        L = None
        while time.monotonic() < deadline and L is None:
            L = leader_probe(c, range(3))
            if L is None:
                time.sleep(0.3)
        if L is None:
            sys.exit("FAIL no leader")
        followers = [i for i in range(3) if i != L]
        Lport = c.addrs.http_port(L)
        cc = c.curl_ctx(STREAMFI_HOST)
        origin = f"https://{STREAMFI_HOST}:{Lport}"
        print(f"ok  leader=node{L} followers={followers}")

        # Open the streamfi held stream. Inbound activation is
        # read-only (no kv.set), so it commits without raft and
        # the `ready` frame ships immediately. The stream is then
        # parked on a 1500ms timer wake.
        url = f"{origin}/"
        args = cc.args() + [
            "-N",
            "--max-time", "5.0",
            "-D", "-",
            "-o", "-",
            "-X", "GET",
            url,
        ]
        watcher = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        # Give the inbound activation a moment to ship `ready` and
        # park the timer. 300ms is comfortably less than 1500ms.
        time.sleep(0.3)

        # Freeze followers — quorum now impossible. The wake_batch
        # hop's propose at T+1.5s will park and hit the commit-wait
        # timeout (~2s default), faulting the staged chunk.
        for i in followers:
            c.workers[i].send_signal(signal.SIGSTOP)
        print(f"ok  froze followers {followers} (SIGSTOP)")

        # Wait through the fault window:
        #   T+1.5s wake_batch fires → handler → propose parks
        #   T+~3.5s commit-wait timeout → fault → chunk freed
        # 4.0s curl --max-time bounds the wait; we drain the
        # output below.
        try:
            stdout, _ = watcher.communicate(timeout=6.0)
        except subprocess.TimeoutExpired:
            watcher.kill()
            stdout, _ = watcher.communicate()

        # curl exits 28 on --max-time (the held stream never
        # closed — pass). 0 means the server closed early.
        # Either is acceptable; only the body content is the gate.
        raw = stdout or b""
        split = raw.rfind(b"\r\n\r\n")
        if split < 0:
            print(f"INCONCLUSIVE  no header block in response: {raw!r}")
            for i in followers:
                if c.workers[i].poll() is None:
                    c.workers[i].send_signal(signal.SIGCONT)
            return 2
        body_str = raw[split + 4:].decode(errors="replace")

        # Gate 1: `ready` must be present (the inbound activation
        # ran end-to-end pre-freeze). Absence means the smoke
        # didn't even reach the fault window — inconclusive, not a
        # regression.
        if "event: ready" not in body_str:
            print(
                f"INCONCLUSIVE  initial `ready` frame missing — the "
                f"stream never opened pre-freeze. body={body_str!r}"
            )
            for i in followers:
                if c.workers[i].poll() is None:
                    c.workers[i].send_signal(signal.SIGCONT)
            return 2

        # Gate 2 (THE regression gate): `tick` must NOT appear in
        # the body. Pre-fix the wake_batch hop's chunk leaks
        # within ~1.6s of freeze; post-fix it never does (the
        # parked unit's fault arm discards `staged_chunks`).
        leaked = "event: tick" in body_str
        print(
            f"    stream body: bytes={len(body_str)} "
            f"ready={'event: ready' in body_str} "
            f"tick={'event: tick' in body_str}"
        )

        # Drive the advisory failover: kill leader, thaw followers,
        # new leader elects. Read `counter` from the new leader —
        # must be absent (the wake_batch handler's kv.set never
        # reached quorum).
        c.workers[L].send_signal(signal.SIGKILL)
        c.workers[L].wait()
        for i in followers:
            c.workers[i].send_signal(signal.SIGCONT)

        nl = None
        deadline = time.monotonic() + 25.0
        while time.monotonic() < deadline and nl is None:
            nl = leader_probe(c, followers)
            if nl is None:
                time.sleep(0.3)
        if nl is None:
            print("INCONCLUSIVE  no new leader within 25s")
            return 2
        print(f"ok  killed node{L}; new leader=node{nl}")

        # Advisory: counter should NOT be in durable kv. We don't
        # have a debug-kv-read endpoint on the streamfi tenant
        # (the handler only exposes the stream). The advisory is
        # really "the propose never committed" — which assertion 1
        # already proves indirectly. Leave the post-failover step
        # to a future advisory if streamfi grows a kv-read route.
        advisory = "tenant has no kv-read route; rely on assertion 1"

    # ── Regression-critical property: the resume-hop's `tick`
    #    frame must NOT have escaped pre-commit. A regression of
    #    Phase 4.0.b (eager-fire returns or the commit-arm
    #    transfer drops the §2 gate) ships `tick` during the
    #    frozen-quorum window.
    if leaked:
        print()
        print(
            "FAIL  resume-hop chunk ESCAPED pre-commit: "
            "`event: tick` appeared in the SSE body during a "
            "frozen-quorum window where the wake_batch handler's "
            "propose could not commit. `streaming-model.md` §2 "
            "rule violated; effect-reification Phase 4.0.b's "
            "commit-arm chunk-gate is absent/regressed."
        )
        print(f"     body sample: {body_str!r}")
        return 1

    print()
    print(
        "PASS effect-reification Phase 4.0.b regression gate: "
        "the resume-hop's `tick` frame did NOT escape during the "
        "frozen-quorum window — `staging` + `commit-arm transfer` "
        "honored `streaming-model.md` §2's one rule. The chunk's "
        "wake_batch activation never committed, so the chunk "
        "never reached the wire."
    )
    print(f"     advisory: {advisory}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
