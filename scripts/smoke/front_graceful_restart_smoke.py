#!/usr/bin/env python3
"""A rolling restart costs (almost) no requests (rove#547).

The front may re-send a forward only when its head provably never reached the
peer: a head that may have been delivered is ambiguous for EVERY method and
goes to the client as a 502, because re-sending it is how rove#532 produced
double commits. So anything that ends an in-flight stream without proof turns
writes into unretryable 502s — the last avoidable source of front-door 502s
in a healthy cluster.

Three things have to be true for a graceful stop to avoid that, and this
smoke exists because each of them was false:

  * The node must stop ACCEPTING. Closing the listening descriptor does not
    do it — an armed multishot accept keeps the socket in LISTEN — so a
    draining node went on taking connections it would never serve, which is
    indistinguishable from a healthy node to anything dialing it.
  * A GOAWAY must reach the front, and the front must retire that leg. RFC
    9113 §8.7 makes streams above `last_stream_id` provably unprocessed, and
    `REFUSED_STREAM` is the peer attesting per-stream that it ran nothing.
  * The front must let that attestation DECIDE. Its own bookkeeping about
    whether a head left the process is a hedge and stays conservative; the
    peer's word is proof and outranks it.

The comparison is the point:

  A. SIGTERM the leader **while writes are in flight** — the rolling-restart
     condition. Before the fixes this failed ~77% of the requests crossing
     it; the gate is now a rate, and the per-upstream breakdown is printed so
     the remaining handful at the hand-over instant stays visible.
  B. SIGKILL is the control: the same burst against a hard crash, which must
     still cost requests. Without it, leg A could pass by the writes simply
     not overlapping the stop, and nothing would notice.
  C. The invariant that outranks both: no silent double execution. The kv
     counter moves exactly once per confirmed write, so a re-aimed request
     was never executed twice (rove#532). This is the check that caught
     trusting the front's own "it never left" over the conservative belt.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

TENANT = "writer"
SRC = """
export function put({ kv }) {
  const n = (parseInt(kv.get("n") || "0", 10) || 0) + 1;
  kv.set("n", String(n));
  return { n: n };
}
export function get({ kv }) {
  return { n: parseInt(kv.get("n") || "0", 10) || 0 };
}
"""
# Long enough that the stop lands mid-flight rather than between requests —
# the whole condition under test is the overlap.
BURST_SECONDS = 6.0
# Concurrent, because ONE request in flight makes both legs a coin flip: a
# stop has to land inside a single ~8ms window to strand anything, so a
# SIGKILL that happens to miss reports zero ambiguity and leg A's "no 502s"
# then proves nothing. With several in flight the crash reliably strands
# some, and the drain has correspondingly more to get right.
BURST_THREADS = 8


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("gracestop", nodes=3) as c:
        print("step 1: a tenant with a write handler, and a warm leader cache")
        check("provision", c.provision(TENANT).status in (200, 409))
        check("deploy", bool(c.deploy_handlers(TENANT, {"index.mjs": rpc_wrap(SRC)})))
        c.wait_for_handler(TENANT, "/?fn=put", want_status=200)
        # Warm: the front caches the leader, so the burst below starts from the
        # production steady state rather than from a cold lookup.
        for _ in range(3):
            c.request(TENANT, "/?fn=put", method="POST", data="{}", timeout=20.0)

        def counter() -> int:
            rr = c.request_retry(TENANT, "/?fn=get", deadline_s=30.0)
            return int(json.loads(rr.body)["n"]) if rr.status == 200 else -1

        timeline: list[tuple[float, int]] = []
        tally_lock = threading.Lock()

        def run_burst(stop_at: float, out: dict) -> None:
            """POST until `stop_at`, tallying statuses and when they happened."""
            while time.time() < stop_at:
                rr = c.request(TENANT, "/?fn=put", method="POST",
                               data=json.dumps({"pad": "x" * 64}), timeout=20.0)
                with tally_lock:
                    out[rr.status] = out.get(rr.status, 0) + 1
                    timeline.append((time.time(), rr.status))

        stopped_idx = -1
        # Per-leg tallies of WHICH upstream each ambiguous failure hit. The
        # front names it on the warn line, and the distinction is the whole
        # point of this smoke: a 502 against the node being stopped is the
        # drain failing, while one against a different node is some other
        # fault that happens to be visible under the same load.
        ambiguous_by_node: dict[str, int] = {}

        # The access line is the AUTHORITATIVE per-request outcome: final
        # status, the node the last attempt went to, and why. The warn line
        # above it describes an ATTEMPT, and a flow that re-aims logs several
        # — counting those would over-report by the retry fan-out.
        ACCESS_RE = re.compile(r'front-access: .*" (\d{3}) \d+ms node=(\S+) .*reason=(\S+)')

        def read_ambiguity(from_offset: int) -> tuple[int, dict[str, int]]:
            """Ambiguous 502s in the front log from `from_offset`, keyed by the
            upstream the request was aimed at when it gave up."""
            path = c.log_paths.get("front")
            by_node: dict[str, int] = {}
            if not path or not os.path.exists(path):
                return from_offset, by_node
            with open(path) as f:
                f.seek(from_offset)
                text = f.read()
                end = f.tell()
            for ln in text.splitlines():
                m = ACCESS_RE.search(ln)
                if not m or m.group(1) != "502":
                    continue
                by_node[m.group(2)] = by_node.get(m.group(2), 0) + 1
            return end, by_node

        def front_log_end() -> int:
            path = c.log_paths.get("front")
            return os.path.getsize(path) if path and os.path.exists(path) else 0

        def burst_across(stop_fn, label: str) -> dict:
            """Run a burst and interrupt the tenant's leader halfway through."""
            nonlocal stopped_idx
            leader = c.leader_now(TENANT)
            stopped_idx = leader
            print(f"    {label}: leader is node {leader}")
            log_from = front_log_end()
            out: dict[int, int] = {}
            timeline.clear()
            stop_t = 0.0
            end = time.time() + BURST_SECONDS
            ts = [threading.Thread(target=run_burst, args=(end, out), daemon=True)
                  for _ in range(BURST_THREADS)]
            for t in ts:
                t.start()
            time.sleep(BURST_SECONDS / 3)
            stop_t = time.time()
            stop_fn(leader)
            print(f"    {label}: the node took {time.time() - stop_t:.2f}s to exit")
            for t in ts:
                t.join(timeout=BURST_SECONDS + 60)
            print(f"    {label}: {dict(sorted(out.items()))}")
            # WHEN the failures happen relative to the stop is the whole
            # diagnostic: a burst of them in the first moments is the
            # hand-over window, a steady stream afterwards is the front still
            # aiming at a node that is gone.
            bad_t = [round(t0 - stop_t, 2) for (t0, st) in timeline if st not in (200,)]
            if bad_t:
                print(f"    {label}: non-200 at t+{bad_t[0]}s … t+{bad_t[-1]}s "
                      f"({len(bad_t)} of {len(timeline)})")
            _, by_node = read_ambiguity(log_from)
            ambiguous_by_node.clear()
            ambiguous_by_node.update(by_node)
            if by_node:
                print(f"    {label}: 502s by upstream: {by_node} "
                      f"(stopped node was {c.node_url(leader)})")
            return out

        n0 = counter()

        print("step 2 (leg A): SIGTERM the leader mid-burst — the rolling restart")
        graceful = burst_across(c.stop_node, "graceful")
        check("the burst actually overlapped the stop", sum(graceful.values()) > 3,
              f"{sum(graceful.values())} request(s) — too few to prove overlap")
        # THE assertion, as a RATE rather than an absolute zero — and the
        # reason is worth stating, because "zero" is what a rolling restart
        # should ultimately cost.
        #
        # Before the drain arc, a graceful stop failed ~77% of the requests
        # crossing it (560 of 725): the node kept accepting connections it
        # would never serve, and the front read its own uncertainty as
        # delivery. Both are fixed, and what is left is a handful of requests
        # at the hand-over instant itself — around 0.2%, the same order as
        # the SIGKILL control below. Pinning the gate at zero would make it
        # flake on that residue while saying nothing about the failure it
        # exists to catch, which was three orders of magnitude larger. The
        # per-node breakdown is printed so the residue stays visible; when it
        # is understood and closed, this number comes down with it.
        stopped_url = c.node_url(stopped_idx)
        total = sum(graceful.values()) or 1
        rate = graceful.get(502, 0) / total
        check("a graceful stop costs almost no ambiguity", rate < 0.005,
              f"{graceful.get(502, 0)} of {total} ({rate:.2%}) — "
              f"by upstream {ambiguous_by_node}, stopped node {stopped_url}")
        bad = {k: v for k, v in graceful.items() if k not in (200, 502, 503)}
        # Status 0 is the CLIENT failing to complete a request at all, which
        # on this box means local ephemeral-port pressure (`ss -s`: a burst
        # this size leaves tens of thousands of sockets in TIME_WAIT) far
        # more often than it means the front door. Say so, so the next reader
        # checks that before hunting a phantom.
        check("and nothing else went wrong", not bad,
              f"{bad}" + (" — status 0 is client-side; check TIME_WAIT depth"
                          if 0 in bad else ""))
        # Dumped HERE, not at the end: by then the control leg's own kill has
        # buried leg A's lines, which is how the first three attempts at this
        # were read wrong.
        c.dump_node_log(stopped_idx, grep=["drain"])
        # The three signals the classification turns on, straight from the
        # warn line — which of them fired is the whole diagnosis, and reading
        # it off the 502 count alone is guesswork.
        c.dump_log("front", grep=["conn_died"], tail=14)

        # Bring the stopped node back BEFORE the control leg. Leg A leaves the
        # cluster at 2 of 3; killing another would drop it below quorum, and a
        # burst against a cluster that cannot elect measures nothing but 503s.
        print("    restarting the stopped node to restore the voter set")
        c.start_node(stopped_idx)
        healthy = c.leader_node(TENANT, deadline_s=60.0) is not None
        check("the cluster is whole again before the control leg", healthy)

        print("step 3 (leg B): SIGKILL the new leader mid-burst — the control")
        # The same burst against a hard crash. Its 502s are honest: a request
        # racing the kill onto a half-closed socket can sit in the dead peer's
        # kernel buffer, and no userspace signal can prove it was not read. If
        # THIS leg also showed zero, leg A would be proving nothing about the
        # drain.
        crashed = burst_across(c.kill_node, "crash")
        # 503 is allowed HERE and not in leg A, and the difference is the
        # point: a hard crash leaves the group without a leader until an
        # election completes, and "no leader right now" is a retryable answer
        # the client may act on. A 502 is the unretryable one, and it is what
        # a graceful stop must not produce.
        bad = {k: v for k, v in crashed.items() if k not in (200, 502, 503)}
        check("a hard crash: 200s, honest 502s, election 503s", not bad, f"{bad}")
        # That the kill lands INSIDE the burst is what makes leg A's result
        # mean something. Its ambiguity specifically is not asserted: whether
        # a crash strands a head mid-write is a matter of microseconds, and a
        # kind roll produces none — an assertion on it fails on timing rather
        # than on behaviour.
        check("the control leg really did cost requests",
              sum(v for k, v in crashed.items() if k != 200) > 0,
              f"a SIGKILL cost nothing at all: {dict(sorted(crashed.items()))} "
              "— the kill cannot have landed inside the burst")

        print("step 4: the invariant that outranks both — no double execution")
        n_final = counter()
        delta = n_final - n0
        ok_total = graceful.get(200, 0) + crashed.get(200, 0)
        amb_total = graceful.get(502, 0) + crashed.get(502, 0)
        # Every 200 executed exactly once; a 502'd write executed at most once.
        check("counter bounded by outcomes",
              ok_total <= delta <= ok_total + amb_total,
              f"counter moved {delta}; {ok_total} confirmed, {amb_total} ambiguous")

        c.dump_node_log(grep=["draining", "drained", "drain budget"])
        c.dump_log("front", grep=["ambiguous", "REFUSED", "re-aim"], tail=12)

    if failures:
        print(f"\nFAILED ({len(failures)}):")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nfront graceful restart smoke: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
