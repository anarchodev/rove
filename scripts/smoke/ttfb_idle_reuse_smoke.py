#!/usr/bin/env python3
"""Idle-keepalive reuse-vs-reap regression smoke (the prod ~10s browser TTFB
stall; see memory project_ttfb_frontdoor_stall).

Reproduces the exact race that stalled rewindjs.com: a client reuses a pooled
idle HTTP/2 connection at the same instant the front's idle reaper closes it.
Before the fix (reap ran in `pollPrelude` BEFORE inbound reads were fed to
nghttp2) a reuse request landing right as the idle timer expired was reaped
out from under itself → the client got no response and no timely close → it
waited its full timeout (~stall). After the fix (reap moved to `pollPostlude`
AFTER reads + graceful GOAWAY) the reuse either lands cleanly on the live
connection or fast-reconnects on a GOAWAY — never a silent multi-second stall.

Topology (no S3 / worker / DP needed — the race is purely in the front's
rove-h2 server leg):
  h2-echo-server  :8081   real h2c upstream (200 + echo), same fixed rove-h2
  rewind-cp       :PCP    routing only (host 127.0.0.1 → tenant → cluster-1)
  rewind-front    :PF     TLS termination — the component that stalled in prod
                          REWIND_FRONT_IDLE_TIMEOUT_MS small so the boundary is
                          reproducible without waiting 30s per trial.

The sweep: warm a pooled h2 connection, idle for `gap` seconds straddling the
reap boundary, then time a reuse request. A reuse that takes > STALL_S (or
raises) is a stall. PASS = zero stalls across all gaps × trials.

Build first:  `zig build rewind-cp rewind-front && zig build h2-echo-server`
"""

import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_topology import spawn_cp, CP_BIN, FRONT_BIN  # noqa: E402

import httpx  # noqa: E402

BINDIR = os.path.join(os.path.dirname(__file__), "..", "..", "zig-out", "bin")

PCP = int(os.environ.get("CP_PORT", "18240"))
PF = int(os.environ.get("FRONT_PORT", "18241"))
PUP = int(os.environ.get("UPSTREAM_PORT", "8081"))   # h2-echo-server hardcodes 8081
MOVE_SECRET = "rewindmovesecretpadding0123456789abcdef0"

# Small browser-facing idle so the reuse boundary is the reap boundary.
FRONT_IDLE_MS = int(os.environ.get("FRONT_IDLE_MS", "3000"))
FRONT_UPSTREAM_IDLE_MS = int(os.environ.get("FRONT_UPSTREAM_IDLE_MS", "2000"))
IDLE_S = FRONT_IDLE_MS / 1000.0

# Gaps straddling the reap boundary (fractions of the idle timeout), and trials
# per gap. The race window is tiny under precise local timing, so we hammer the
# exact boundary many times.
# Gap factors (× idle) straddling the boundary; override with GAP_FACTORS
# (comma-separated) to focus the sweep, e.g. "0.98,1.0,1.02,1.05" for a fast
# boundary-only run.
_factors = os.environ.get("GAP_FACTORS")
_factors = ([float(x) for x in _factors.split(",")] if _factors
            else (0.5, 0.8, 0.9, 0.95, 0.98, 1.0, 1.02, 1.05, 1.1, 1.3, 1.6))
GAPS = sorted(set(round(IDLE_S * f, 3) for f in _factors))
TRIALS = int(os.environ.get("TRIALS", "12"))
STALL_S = 1.0  # a reuse slower than this on localhost is a stall
# httpx per-request timeout. A stalled reuse fails as a ReadTimeout at this
# bound, so keep it modest (> STALL_S) to detect stalls cheaply.
CLIENT_TIMEOUT_S = float(os.environ.get("CLIENT_TIMEOUT_S", "20"))

TENANT = "acme"
CLUSTERS = f"cluster-1=http://127.0.0.1:{PUP}"
HOSTS = f"127.0.0.1={TENANT}"
PLACEMENT = f"{TENANT}=cluster-1"

procs = []


def gen_cert(tmp):
    cert = os.path.join(tmp, "front.cert.pem")
    key = os.path.join(tmp, "front.key.pem")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", key, "-out", cert, "-days", "1",
         "-subj", "/CN=front-default",
         "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
        check=True, capture_output=True,
    )
    return cert, key


def stop_all():
    for p in procs:
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
    for p in procs:
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()


def wait_listen(p, name, needle, deadline_s=15):
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        line = p.stdout.readline()
        if not line:
            if p.poll() is not None:
                raise SystemExit(f"{name} exited early (rc={p.returncode})")
            continue
        sys.stdout.write(f"  [{name}] {line}")
        if needle in line:
            return True
    raise SystemExit(f"{name}: never logged {needle!r}")


def main():
    for b in (CP_BIN, FRONT_BIN):
        if not os.path.exists(b):
            raise SystemExit(f"{b} not found — run `zig build rewind-cp rewind-front`")

    tmp = f"/tmp/ttfb-sweep-{os.getpid()}"
    os.makedirs(tmp, exist_ok=True)
    cpd = f"{tmp}/cp"
    failures = []
    stalls = []

    try:
        print(f"setup: idle={FRONT_IDLE_MS}ms upstream_idle={FRONT_UPSTREAM_IDLE_MS}ms "
              f"gaps={GAPS} trials={TRIALS}")
        cert, key = gen_cert(tmp)

        # 1) h2c upstream (real 200s). h2-echo-server hardcodes :8081.
        print("boot: h2-echo-server (h2c upstream :%d)" % PUP)
        echo = subprocess.Popen(
            ["zig", "build", "h2-echo-server"],
            cwd=os.path.join(os.path.dirname(__file__), "..", ".."),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        procs.append(echo)
        wait_listen(echo, "echo", "listening on")

        # 2) CP (routing only).
        print("boot: rewind-cp (routing)")
        spawn_cp(procs, PCP, clusters=CLUSTERS, hosts=HOSTS, placement=PLACEMENT,
                 cp_data_dir=cpd, move_secret=MOVE_SECRET)

        # 3) TLS front with a small idle timeout.
        print("boot: rewind-front (TLS edge)")
        fenv = dict(os.environ)
        fenv["REWIND_CP_URL"] = f"http://127.0.0.1:{PCP}"
        fenv["REWIND_TLS_CERT"] = cert
        fenv["REWIND_TLS_KEY"] = key
        fenv["REWIND_HTTP_PORT"] = "0"
        fenv["REWIND_ROUTE_CACHE_MS"] = "500"
        fenv["REWIND_FRONT_IDLE_TIMEOUT_MS"] = str(FRONT_IDLE_MS)
        fenv["REWIND_FRONT_UPSTREAM_IDLE_TIMEOUT_MS"] = str(FRONT_UPSTREAM_IDLE_MS)
        front = subprocess.Popen([FRONT_BIN, str(PF)], stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, env=fenv)
        procs.append(front)
        wait_listen(front, "front", "listening on")
        time.sleep(0.5)

        base = f"https://127.0.0.1:{PF}"
        limits = httpx.Limits(max_connections=1, max_keepalive_connections=1,
                              keepalive_expiry=600)

        # Warm-up: confirm the proxy path returns 200 before timing anything.
        with httpx.Client(http2=True, verify=False, limits=limits, timeout=CLIENT_TIMEOUT_S) as c:
            r = None
            for _ in range(40):
                try:
                    r = c.get(base + "/")
                    if r.status_code == 200:
                        break
                except Exception as e:  # noqa: BLE001
                    r = e
                time.sleep(0.25)
            ok = isinstance(r, httpx.Response) and r.status_code == 200
            print(f"  {'ok  ' if ok else 'FAIL'} warmup proxied 200: "
                  f"{getattr(r, 'status_code', r)!r}  http={getattr(r,'http_version',None)}")
            if not ok:
                failures.append("warmup never returned 200")
                raise SystemExit("upstream/proxy not serving 200 — aborting sweep")

        # The sweep. Fresh client per gap so each gap starts from a clean pooled
        # connection; reuse within the gap loop is what races the reaper.
        print("\nsweep (reuse latency per gap; STALL = reuse > %.1fs or error):" % STALL_S)
        for gap in GAPS:
            worst = 0.0
            errs = 0
            with httpx.Client(http2=True, verify=False, limits=limits, timeout=CLIENT_TIMEOUT_S) as c:
                # establish the pooled conn
                c.get(base + "/")
                for _ in range(TRIALS):
                    time.sleep(gap)
                    t0 = time.perf_counter()
                    try:
                        rr = c.get(base + "/")
                        dt = time.perf_counter() - t0
                        if rr.status_code != 200:
                            errs += 1
                            stalls.append((gap, f"status {rr.status_code}", dt))
                        if dt > worst:
                            worst = dt
                        if dt > STALL_S:
                            stalls.append((gap, "slow reuse", dt))
                    except Exception as e:  # noqa: BLE001
                        dt = time.perf_counter() - t0
                        errs += 1
                        stalls.append((gap, type(e).__name__, dt))
            flag = "STALL" if (worst > STALL_S or errs) else "ok   "
            rel = gap / IDLE_S
            print(f"  {flag} gap={gap:5.2f}s ({rel:4.2f}× idle)  "
                  f"worst-reuse={worst*1000:7.1f}ms  errors={errs}/{TRIALS}")

    finally:
        stop_all()
        subprocess.run(["rm", "-rf", tmp])

    if failures or stalls:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        for gap, kind, dt in stalls[:30]:
            print(f"  - gap={gap:.2f}s {kind} ({dt*1000:.0f}ms)")
        if len(stalls) > 30:
            print(f"  ... and {len(stalls)-30} more")
        sys.exit(1)
    print("\nPASS — no silent stalls at any idle-reuse boundary; the reaper "
          "terminates connections gracefully (reap-after-reads + GOAWAY). ✅")


if __name__ == "__main__":
    main()
