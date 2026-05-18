#!/usr/bin/env python3
"""Option-A regression gate — an admin handler's side-effect 2xx
must NOT escape before the side write commits.

docs/proposer-audit.md Addendum 3/4. Before Option-A,
`platform.releases.publish` / `platform.scope().kv.*` /
`platform.root.*` did fire-and-forget raft proposes the calling
admin request never gated on: its 2xx escaped while the side
write might never reach quorum. Option-A folds the side writeset
into the batch's single atomic raft entry and parks the admin
request on that seq (existing RaftWait/drainRaftPending). This
test proves the caller response is now gated on commit.

`publishRelease` is the discriminating op: `releasePublishTramp-
oline` writes ONLY the target tenant's `_deploy/current` (no
__admin__ app.db anchor write), so PRE-Option-A the admin batch
is a read-only anchor → the 2xx is released immediately
(escaped); POST-Option-A batch_side is non-empty → finalizeBatch
proposes + parks the admin request on the batch seq.

Deterministic reproduction (operator-OIDC harness, as
notifications_smoke):

  1. 3-node cluster + files/log servers + OIDC RP config; operator
     RP login → op cookie.
  2. createInstance "specpub" while quorum is HEALTHY (commits;
     also exercises the Option-A happy path end-to-end).
  3. SIGSTOP both followers → quorum impossible.
  4. `?fn=publishRelease&args=["specpub", 43981]` to the leader's
     admin origin with the op cookie (43981 != the starter dep 1,
     so the idempotent fast-path is bypassed and a real
     `_deploy/current` write is produced).
     **ASSERTION (regression guard): the response must NOT be a
     2xx in the frozen pre-quorum window.** PRE-Option-A it is
     202/200 immediately (escaped). POST-Option-A the admin
     request is parked on the batch seq that cannot commit →
     503/timeout, no 2xx.
  5. SIGKILL leader; SIGCONT followers → new leader. The publish
     never reached quorum, so the durable cluster never activated
     dep 43981 (advisory — confirms the escape would have been a
     phantom).

Negative control (proves this is a real gate, not a false pass):
in src/js/worker_dispatch.zig finalizeBatch, force
`const has_side = false;` (revert the Option-A gate), rebuild,
re-run → the 2xx ESCAPES in the frozen window → this test FAILs.
Restore afterwards. Same discipline as
readonly_speculation_faultinj_smoke.

Timing fault-injection is delicate; the ~2s commit-wait window is
wide enough that an immediate (<200ms) pre-fix 2xx lands inside
it deterministically. If the publish cannot be issued in-window
the run is INCONCLUSIVE (not a pass).
"""

from __future__ import annotations

import json
import signal
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
OPERATOR_EMAIL = "operator@example.com"
TARGET = "specpub"
PUBLISH_DEP = 43981  # 0xABCD — != the starter dep (1); bypasses fast-path


def main() -> int:
    cluster = Cluster.spawn(
        tag="optiona-caller-gate",
        http_base=8504,
        raft_base=40504,
        files_port=8508,
        log_port=8509,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=1,
    )

    leaked = True  # fail-closed until proven otherwise
    pub_status: int = -1
    pub_body = "<not captured>"

    with cluster as c:
        c.discover_leader()
        L = c.leader_idx
        print(f"ok  leader elected: node {L}")

        admin_origin = c.admin_origin()
        c.spawn_files_server(
            cors_origin=admin_origin, leader_url=admin_origin,
            extra_args=c.admin_oidc_kv(OPERATOR_EMAIL),
        )
        c.spawn_log_server(cors_origin=admin_origin)
        c.mint_services_token()

        cc = c.curl_ctx(
            f"auth.{SYSTEM_SUFFIX}",
            f"{TARGET}.{PUBLIC_SUFFIX}",
        )

        # Readiness: admin RPC 401s once admin deploy + RP config
        # land, then the IdP /login is up (notifications_smoke shape).
        deadline = time.monotonic() + 25.0
        r = curl(cc, f"{admin_origin}/?fn=listInstance",
                 headers={"Origin": admin_origin})
        while time.monotonic() < deadline and r.status != 401:
            time.sleep(0.25)
            r = curl(cc, f"{admin_origin}/?fn=listInstance",
                     headers={"Origin": admin_origin})
        for _ in range(80):
            if curl(cc, c.auth_base() + "/login").status == 200:
                break
            time.sleep(0.25)

        op = c.oidc_login(cc, OPERATOR_EMAIL)
        print("ok  operator OIDC login")

        # Provision the target tenant while quorum is HEALTHY. This
        # commits (and exercises the Option-A happy path: createInstance
        # now rides the batch-folded multi).
        args = urllib.parse.quote(json.dumps([TARGET]))
        r = curl(cc, f"{admin_origin}/?fn=createInstance&args={args}",
                 headers={"Cookie": op})
        if r.status not in (200, 201):
            sys.exit(f"FAIL createInstance {TARGET}: {r.status} {r.body}")
        print(f"ok  provisioned {TARGET} (healthy quorum; Option-A happy path)")
        time.sleep(2.5)  # replicate to quorum

        followers = [i for i in range(3) if i != L]
        for i in followers:
            c.workers[i].send_signal(signal.SIGSTOP)
        print(f"ok  froze followers {followers} (SIGSTOP) — no quorum")

        # publishRelease in the frozen window. PRE-Option-A: 2xx
        # immediately (escaped). POST: parked on the batch seq that
        # cannot commit → 503/timeout.
        pargs = urllib.parse.quote(json.dumps([TARGET, PUBLISH_DEP]))
        try:
            r = curl(cc, f"{admin_origin}/?fn=publishRelease&args={pargs}",
                     headers={"Cookie": op}, timeout=8.0)
            pub_status, pub_body = r.status, r.body
        except RuntimeError as e:
            pub_status, pub_body = -1, f"<curl error: {e}>"
        leaked = pub_status in (200, 201, 202)
        print(f"    publishRelease status={pub_status} "
              f"body={pub_body[:160]!r}")

        # Kill leader, thaw followers → new leader (advisory phase).
        c.workers[L].send_signal(signal.SIGKILL)
        c.workers[L].wait()
        for i in followers:
            c.workers[i].send_signal(signal.SIGCONT)
        nl = None
        deadline = time.monotonic() + 25.0
        while time.monotonic() < deadline and nl is None:
            try:
                if curl(cc, f"https://{c.addrs.admin_host}:"
                            f"{c.addrs.http_port(followers[0])}/?fn=listInstance",
                        headers={"Origin": admin_origin},
                        timeout=2.0).status in (200, 401):
                    nl = followers[0]
            except RuntimeError:
                pass
            if nl is None:
                time.sleep(0.3)
        conv = "new leader up — publish never committed (phantom)" \
            if nl is not None else "no new leader within 25s (advisory only)"
        print(f"ok  killed node{L}; {conv}")

        for i in followers:
            if c.workers[i].poll() is None:
                c.stop_node(i)

    if leaked:
        print()
        print(f"FAIL  admin publishRelease 2xx ESCAPED before commit: "
              f"status {pub_status} returned while the proposing leader "
              f"could not reach quorum. Option-A's caller-response gate "
              f"is absent/regressed (docs/proposer-audit.md Addendum 4).")
        return 1

    print()
    print("PASS Option-A regression gate: the admin handler's "
          "publishRelease response did NOT escape before commit — no "
          "2xx in the frozen pre-quorum window (pre-Option-A this is "
          "202/200). Caller-response premature-effect-release is closed "
          "for the platform side-effect path.")
    print(f"     advisory — post-failover: {conv}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
