#!/usr/bin/env python3
"""idiom-0 regression gate — a read-only response must NOT escape
carrying a chain predecessor's uncommitted speculative write.

docs/proposer-audit.md Addendum (idiom-0) /
docs/unified-effect-gating.md §2 scope clarification. The bug: a
non-proposing read-only batch whose `kv.get` crosses an in-flight
write's chain-predecessor overlay (kvexp sets `saw_speculation`)
takes finalizeBatch's immediate-release fast path — the
uncommitted value escapes to the client. A proposer audit is
blind to it because the read issues no `propose()`. The fix
(idiom-0): such a batch takes an empty-writeset barrier propose +
park, releasing only once the predecessor write commits (chain
head); under frozen quorum it 503s on the commit-wait deadline.

Deterministic reproduction of the post-propose / pre-quorum
window (single tenant `specread`, so the read and the write share
one kvexp store/chain — `saw_speculation` only fires on a
chain-predecessor walk within a tenant):

  1. SIGSTOP both followers → quorum impossible.
  2. `?fn=write&args=["spec",SENTINEL]` to the leader. The write
     handler speculative-commits `spec=SENTINEL` into the tenant
     chain and proposes; the propose ACCEPTS (local log append)
     but cannot commit (no quorum). The overlay now sits in the
     chain, uncommitted, for ~commit_wait_timeout (2s default).
  3. Within that window, `?fn=read&args=["spec"]` to the leader.
     The read-only handler's `kv.get("spec")` crosses the frozen
     write's predecessor overlay → `saw_speculation`.
     **ASSERTION 1 (regression guard): the read response must NOT
     contain SENTINEL.** PRE-fix it returns SENTINEL immediately
     (escaped effect → FAIL). POST-fix the batch is parked on a
     barrier seq that cannot commit → 503 at the deadline, no
     SENTINEL.
  4. SIGKILL the leader; SIGCONT followers → new leader (2/3).
     The write never reached quorum and was a client request (no
     schedule re-fire), so `spec` never durably exists.
     **ASSERTION 2 (advisory): `?fn=read` on the new leader
     reports found:false** — confirming the pre-fix escape was a
     phantom the durable cluster never held.

Timing fault-injection is delicate; the 2s commit-wait window is
wide enough that an immediate (<200ms) pre-fix read lands inside
it deterministically. If the read cannot be issued in-window the
run is INCONCLUSIVE (not a pass).
"""

from __future__ import annotations

import secrets
import signal
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
ADMIN_HOST = f"app.{SYSTEM_SUFFIX}"
SPECREAD_HOST = f"specread.{PUBLIC_SUFFIX}"


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    sentinel = "ESCAPED-" + secrets.token_hex(8)

    cluster = Cluster.spawn(
        tag="readonly-spec-faultinj",
        http_base=8494,
        raft_base=40494,
        files_port=8498,
        log_port=8499,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        admin_origin_per_node=True,
        admin_api_domain=ADMIN_HOST,
        with_log_files_bases=False,
        workers_per_node=1,
        seed_manifest=repo_root / "examples" / "specread-tenant.json",
    )

    def leader_probe(c: Cluster, candidates) -> int | None:
        # Admin /_system/leader Bearer probe (leader_failover pattern):
        # 200 on leader, 503/refused on follower. Never touches the
        # specread handler.
        cc = c.curl_ctx(SPECREAD_HOST, ADMIN_HOST)
        for i in candidates:
            try:
                r = curl(cc,
                         f"https://{ADMIN_HOST}:{c.addrs.http_port(i)}"
                         f"/_system/leader",
                         headers={"Authorization": f"Bearer {TOKEN}"},
                         timeout=2.0)
            except RuntimeError:
                continue
            if r.status == 200:
                return i
        return None

    leaked = True  # fail-closed until proven otherwise
    read_body = "<not captured>"
    write_proc = None

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
        cc = c.curl_ctx(SPECREAD_HOST)
        origin = f"https://{SPECREAD_HOST}:{Lport}"
        print(f"ok  leader=node{L} followers={followers}")

        # Freeze followers — quorum now impossible.
        for i in followers:
            c.workers[i].send_signal(signal.SIGSTOP)
        print(f"ok  froze followers {followers} (SIGSTOP)")

        # Write: speculative-commits spec=SENTINEL into the tenant
        # chain + proposes (accepts locally, cannot commit). Runs in
        # the background — it parks and 503s at the ~2s commit-wait
        # deadline; we only need the speculative overlay present.
        wargs = urllib.parse.quote(f'["spec","{sentinel}"]')
        write_url = f"{origin}/?fn=write&args={wargs}"
        resolves = sum(
            (["--resolve", f"{h}:{p}:127.0.0.1"] for h, p in cc.resolves),
            [])
        write_proc = subprocess.Popen(
            ["curl", "-sS", "--cacert", str(c.tls.cacert),
             "--max-time", "10", *resolves, write_url],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(f"ok  fired write spec={sentinel} (parks; no quorum)")
        time.sleep(0.5)  # let the handler speculative-commit + propose

        # Read within the commit-wait window. PRE-fix: returns the
        # uncommitted SENTINEL immediately. POST-fix: parked → 503.
        rargs = urllib.parse.quote('["spec"]')
        try:
            r = curl(cc, f"{origin}/?fn=read&args={rargs}", timeout=6.0)
            read_body = r.body
            status = r.status
        except RuntimeError as e:
            read_body = f"<curl error: {e}>"
            status = -1
        leaked = sentinel in read_body
        print(f"    read status={status} body={read_body[:160]!r}")

        # Kill leader (its parked write/read die with it). Thaw → new
        # leader from the 2 survivors.
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
            if write_proc and write_proc.poll() is None:
                write_proc.terminate()
            return 2
        print(f"ok  killed node{L}; new leader=node{nl}")

        # Advisory: the durable cluster must NOT hold the escaped
        # value (the write never reached quorum; client request, no
        # re-fire). Poll briefly — failover + raft recovery latency.
        nport = c.addrs.http_port(nl)
        norigin = f"https://{SPECREAD_HOST}:{nport}"
        ncc = c.curl_ctx(SPECREAD_HOST)
        conv = "not confirmed"
        cdl = time.monotonic() + 20.0
        while time.monotonic() < cdl:
            try:
                rr = curl(ncc, f"{norigin}/?fn=read&args={rargs}",
                          timeout=4.0)
            except RuntimeError:
                time.sleep(2.0)
                continue
            if rr.status == 200 and '"found":false' in rr.body:
                conv = "found:false (phantom confirmed — never durable)"
                break
            if rr.status == 200 and sentinel in rr.body:
                conv = (f"DURABLE {sentinel} — unexpected; the write "
                        f"reached quorum, scenario invalid")
                break
            time.sleep(2.0)

        if write_proc and write_proc.poll() is None:
            write_proc.terminate()
        for i in followers:
            if c.workers[i].poll() is None:
                c.stop_node(i)

    # ── Regression-critical property (the gate's one job): the
    #    read-only response must NOT carry the predecessor's
    #    uncommitted speculative write. A regression of idiom-0
    #    (read-only fast path ignores saw_speculation) escapes the
    #    SENTINEL → leaked.
    if leaked:
        print()
        print(f"FAIL  read response ESCAPED the uncommitted value: "
              f"SENTINEL {sentinel} appeared in a read issued while "
              f"the predecessor write could not reach quorum. idiom-0's "
              f"read-side gate is absent/regressed "
              f"(docs/proposer-audit.md Addendum).")
        return 1

    print()
    print("PASS idiom-0 regression gate: the read-only response did "
          "NOT escape the predecessor's uncommitted speculative write "
          "— no SENTINEL in the frozen pre-quorum window (pre-fix this "
          "leaks). Read-derived premature-effect-release is closed for "
          "the finalizeBatch read-only path.")
    print(f"     advisory — post-failover convergence: {conv}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
