#!/usr/bin/env python3
"""log-push A/B perf bench — is worker→log-server batch push performance-neutral?

Background: prod disabled worker push once "because it killed performance"
(the disable was actually done by dropping LOOP46_SERVICES_JWT_SECRET, which
ALSO crash-looped rewind-logs — see the render-env fix). Push runs on a
background thread (`worker_log.pushLoop`), off the request hot path, so any
cost is CPU/libcurl contention on the worker plus load on the log-server
(each pushed key = an S3 GET + SQLite insert there). This measures it.

Method: two arms, identical single-node topology + load, toggling ONLY push.
  OFF — worker spawned with worker_log_push=False → log_public_base null → no
        push thread; flusher still PUTs batches to S3 (baseline log cost).
  ON  — worker_log_push=True (prod default) + a live rewind-logs so the POSTs
        actually complete (204) and the indexer does its S3-GET + insert.
Every request emits a log record, so a high request rate drives frequent
flushes → frequent pushes. Load is h2load straight at the worker's h2c port
(no front) so the delta is purely the worker's push path.

  set -a; . ./.env; set +a
  zig build rewind-worker rewind-cp rewind-front rewind-logs -Doptimize=ReleaseFast
  python3 scripts/smoke/bench/log_push_bench.py [--reqs N] [--clients C] [--streams M] [--rounds R]
"""
import argparse, json, re, statistics, subprocess, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from smoke_lib_v2 import V2Cluster, MOVE_SECRET  # noqa: E402


def lift_rate_cap(c: V2Cluster, tenant: str, node: int = 0):
    """Install a per-tenant plan override so the token-bucket limiter
    (free tier: 1000 burst / 500 rps) doesn't throttle the bench. Uses the
    worker's `POST /_system/v2-plan` hot-path push (move-secret gated). Without
    this, single-tenant flat-out load is limiter-bound (429s) and throughput is
    insensitive to the background push cost we're trying to measure."""
    blob = json.dumps({"tier": "free", "overrides": {
        "request_capacity": 100_000_000, "request_refill_per_sec": 100_000_000}})
    body = json.dumps({"tenant": tenant, "plan": blob})
    url = f"{c.node_url(node)}/_system/v2-plan"
    r = subprocess.run(
        ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
         "--http2-prior-knowledge", "-X", "POST",
         "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
         "--data-binary", body, url],
        capture_output=True, text=True, timeout=15).stdout.strip()
    if r != "204":
        raise RuntimeError(f"v2-plan install != 204 (got {r})")
    # read back to confirm the cap actually lifted on the hot-path slot
    rb = subprocess.run(
        ["curl", "-sS", "--http2-prior-knowledge",
         "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
         f"{url}?tenant={tenant}"],
        capture_output=True, text=True, timeout=15).stdout
    cap = json.loads(rb).get("request_capacity")
    if cap != 100_000_000:
        raise RuntimeError(f"cap not lifted: read back request_capacity={cap}")

TENANT = "pushbench"
# Trivial read-only handler: minimal per-request CPU so the push path is the
# dominant variable, not handler work. Still emits one log record per request.
HANDLER = "export default function(){ return 'ok\\n'; }\n"

H2LOAD_RE_RPS = re.compile(r"finished in [\d.]+\w+, ([\d.]+) req/s")
H2LOAD_RE_2XX = re.compile(r"status codes: (\d+) 2xx")
# The "time for request:" row: min max mean sd +/-sd  (mean is col 3)
H2LOAD_RE_REQTIME = re.compile(r"time for request:\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)")


def _dur_to_ms(tok: str) -> float:
    """h2load prints e.g. '1.23ms', '456us', '2.00s'. → milliseconds."""
    m = re.match(r"([\d.]+)(us|ms|s)", tok)
    if not m:
        return float("nan")
    v, u = float(m.group(1)), m.group(2)
    return v / 1000 if u == "us" else v * 1000 if u == "s" else v


def run_h2load(url: str, host: str, reqs: int, clients: int, streams: int):
    cmd = ["h2load", "-n", str(reqs), "-c", str(clients), "-m", str(streams),
           "-H", f"Host: {host}", url]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    txt = out.stdout + out.stderr
    rps = H2LOAD_RE_RPS.search(txt)
    n2xx = H2LOAD_RE_2XX.search(txt)
    rt = H2LOAD_RE_REQTIME.search(txt)
    codes = re.search(r"status codes: .*", txt)
    errline = re.search(r"\d+ failed, \d+ errored.*", txt)
    if not rps or not n2xx:
        raise RuntimeError(f"h2load parse failed:\n{txt}")
    return {
        "rps": float(rps.group(1)),
        "n2xx": int(n2xx.group(1)),
        "mean_ms": _dur_to_ms(rt.group(3)) if rt else float("nan"),
        "codes": codes.group(0) if codes else "?",
        "err": errline.group(0) if errline else "",
    }


def bench_arm(name: str, *, push: bool, reqs: int, clients: int,
              streams: int, rounds: int):
    print(f"\n=== ARM: {name} (push={'ON' if push else 'OFF'}) ===", flush=True)
    with V2Cluster.spawn(f"pushb-{'on' if push else 'off'}", nodes=1,
                         worker_log_push=push) as c:
        if push:
            # A live log-server so pushed keys land 204 + get indexed (real cost).
            c.spawn_log_server(poll_interval_ms=200)
        assert c.provision(TENANT).status in (200, 204), "provision failed"
        c.deploy_handlers(TENANT, {"index.mjs": HANDLER})
        c.wait_for_handler(TENANT, "/")
        lift_rate_cap(c, TENANT)  # so load isn't token-bucket throttled

        url = f"{c.node_url(0)}/"
        host = c.host_for(TENANT)
        # sanity: one request must be 200 straight at the worker port
        san = subprocess.run(
            ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
             "--http2-prior-knowledge", "-H", f"Host: {host}", url],
            capture_output=True, text=True, timeout=15).stdout.strip()
        if san != "200":
            raise RuntimeError(f"worker-direct sanity != 200 (got {san}) at {url} Host={host}")

        results = []
        for r in range(rounds):
            res = run_h2load(url, host, reqs, clients, streams)
            tag = "warmup" if r == 0 else f"round {r}"
            print(f"  {tag:8s}: {res['rps']:10.1f} req/s   mean {res['mean_ms']:.3f} ms"
                  f"   2xx={res['n2xx']}/{reqs}", flush=True)
            if res["n2xx"] != reqs:
                print(f"    WARN: {reqs - res['n2xx']} non-2xx | {res['codes']} | {res['err']}", flush=True)
            if r > 0:  # drop warmup
                results.append(res)
        # let the last flush + push drain before teardown
        time.sleep(1.5)
        if push:
            # Verify push ACTUALLY fired — else "ON" is a no-op and the A/B lies.
            m = subprocess.run(["curl", "-sS", "-m", "5",
                                "http://127.0.0.1:9113/metrics"],
                               capture_output=True, text=True).stdout
            def _mv(name):
                mm = re.search(rf"^{name}\s+(\d+)", m, re.M)
                return int(mm.group(1)) if mm else -1
            recv, idx, err = _mv("log_push_received_total"), _mv("log_push_indexed_total"), _mv("log_push_errors_total")
            print(f"  push metrics: received={recv} indexed={idx} errors={err}", flush=True)
            if recv <= 0:
                raise RuntimeError("push ON arm but log_push_received_total==0 — push never fired")
    rps = [x["rps"] for x in results]
    mean_ms = [x["mean_ms"] for x in results]
    return {
        "name": name, "push": push,
        "rps_median": statistics.median(rps),
        "rps_mean": statistics.mean(rps),
        "rps_stdev": statistics.pstdev(rps),
        "lat_median_ms": statistics.median(mean_ms),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reqs", type=int, default=200000)
    ap.add_argument("--clients", type=int, default=64)
    ap.add_argument("--streams", type=int, default=10)
    ap.add_argument("--rounds", type=int, default=8, help="incl. 1 warmup dropped")
    a = ap.parse_args()
    print(f"config: reqs={a.reqs} clients={a.clients} streams={a.streams} "
          f"rounds={a.rounds} (1 warmup dropped)")

    # Run OFF first, then ON (order-independent — each is a fresh cluster).
    off = bench_arm("push OFF", push=False, reqs=a.reqs, clients=a.clients,
                    streams=a.streams, rounds=a.rounds)
    on = bench_arm("push ON", push=True, reqs=a.reqs, clients=a.clients,
                   streams=a.streams, rounds=a.rounds)

    print("\n" + "=" * 64)
    print(f"{'arm':10s} {'median req/s':>14s} {'mean req/s':>12s} {'stdev':>8s} {'lat(ms)':>9s}")
    for x in (off, on):
        print(f"{x['name']:10s} {x['rps_median']:14.1f} {x['rps_mean']:12.1f} "
              f"{x['rps_stdev']:8.1f} {x['lat_median_ms']:9.3f}")
    delta = (on["rps_median"] - off["rps_median"]) / off["rps_median"] * 100
    print("-" * 64)
    print(f"push ON vs OFF: {delta:+.2f}% median req/s "
          f"({'neutral' if abs(delta) < 3 else 'REGRESSION' if delta < 0 else 'faster?'})")
    print("=" * 64)


if __name__ == "__main__":
    main()
