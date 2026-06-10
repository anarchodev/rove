#!/usr/bin/env python3
"""V2 Phase-7 slice (b) smoke — dual-write forwarding (docs/v2-build-order.md
§Phase 7, project_v2_zero_downtime_move memory).

Proves the DATA-OVERLAP half of a zero-downtime move: while a tenant is
moving, the source keeps serving AND forwards every committed write to the
destination, so the destination stays caught up — all WITHOUT a quiesce or a
directory flip (those are the cutover, slice c). No Cloudflare / front door
here; this is the cluster-to-cluster forwarding mechanism in isolation.

    source  → rewind :18121   (keeps serving throughout)
    dest    → rewind :18122   (acquiring: holds the group + applies forwards)

Legs:
  A.  seed key1 on the source; snapshot it onto the dest (bundle→attach→
      resume — the dest now holds the group + the snapshot; the source's
      brief quiesce is lifted immediately and it serves again).
  B.  open the overlap: `v2-forward-begin` on the source (dest = :18122).
  C.  write key2 + key3 on the SOURCE → each is committed locally AND
      forwarded → both appear on the DEST, while the source still serves
      every key (no flip — the source is still the owner).
  D.  close the overlap: `v2-forward-end`; a subsequent key4 on the source
      is NOT forwarded (the dest 404s it) but the source still serves it.

Ordering note: the snapshot is taken before forwarding opens, so a write in
that window would be missed — gap-free overlap ordering + the atomic cutover
are slice (c). The smoke takes no writes in that window.

Requires S3 env (no fs BlobBackend) — `set -a; . ./.env; set +a` first.
Build:  `zig build rewind`
"""

import os
import signal
import subprocess
import sys
import time

BINDIR = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin")
REWIND = os.path.join(BINDIR, "rewind")

PSRC = int(os.environ.get("SRC_PORT", "18121"))
PDST = int(os.environ.get("DST_PORT", "18122"))
MOVE_SECRET = "rewindmovesecretpadding0123456789abcdef0"
TENANT = "fwdtenant"

procs = []


def spawn(name, port, data_dir):
    env = dict(os.environ)
    env["REWIND_ADMIN_DOMAIN"] = f"{name}.localhost"
    env["REWIND_MOVE_SECRET"] = MOVE_SECRET
    p = subprocess.Popen(
        [REWIND, data_dir, str(port)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
    procs.append(p)
    _await_line(p, name, "listening on")
    return p


def _await_line(p, name, needle):
    deadline = time.time() + 15
    while time.time() < deadline:
        line = p.stdout.readline()
        if not line:
            if p.poll() is not None:
                raise SystemExit(f"{name} exited early: rc={p.returncode}")
            continue
        sys.stdout.write(f"  [{name}] " + line)
        if needle in line:
            return
    raise SystemExit(f"{name} did not reach '{needle}' within 15s")


def _curl(args):
    out = subprocess.run(
        ["curl", "-s", "-w", "\n%{http_code}", "-m", "15", "--http2-prior-knowledge"] + args,
        capture_output=True, text=True,
    )
    text = out.stdout
    nl = text.rfind("\n")
    if nl < 0:
        return (0, text)
    body, code = text[:nl], text[nl + 1:].strip()
    try:
        return (int(code), body)
    except ValueError:
        return (0, body)


def secret_hdr():
    return ["-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}"]


def kv_put(port, key, value):
    return _curl([
        "-X", "PUT", f"http://127.0.0.1:{port}/_system/v2-kv",
        *secret_hdr(), "-H", "Content-Type: application/json",
        "--data", f'{{"tenant":"{TENANT}","key":"{key}","value":"{value}"}}',
    ])[0]


def kv_get(port, key):
    return _curl([
        f"http://127.0.0.1:{port}/_system/v2-kv?tenant={TENANT}&key={key}",
        *secret_hdr(),
    ])


def post(port, suffix, payload):
    return _curl([
        "-X", "POST", f"http://127.0.0.1:{port}/_system/{suffix}",
        *secret_hdr(), "-H", "Content-Type: application/json",
        "--data", payload,
    ])


def bundle(port):
    """v2-bundle returns the raw snapshot bytes; capture to a temp file."""
    path = os.path.join(os.environ.get("CLAUDE_JOB_DIR", "/tmp"), f"fwd-bundle-{os.getpid()}.bin")
    rc = subprocess.run(
        ["curl", "-s", "-o", path, "-w", "%{http_code}", "-m", "15",
         "--http2-prior-knowledge", "-X", "POST",
         f"http://127.0.0.1:{port}/_system/v2-bundle",
         "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
         "-H", "Content-Type: application/json",
         "--data", f'{{"tenant":"{TENANT}"}}'],
        capture_output=True, text=True,
    )
    return (rc.stdout.strip(), path)


def attach(port, bundle_path):
    return subprocess.run(
        ["curl", "-s", "-w", "%{http_code}", "-m", "15", "--http2-prior-knowledge",
         "-X", "POST", f"http://127.0.0.1:{port}/_system/v2-attach",
         "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
         "-H", f"X-Rewind-Tenant: {TENANT}",
         "--data-binary", f"@{bundle_path}"],
        capture_output=True, text=True,
    ).stdout.strip()


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
    # A handled SIGTERM exits 0; anything else (SIGABRT = a Zig panic,
    # SIGSEGV, nonzero) is a teardown bug — drain and surface it.
    for p in procs:
        if p.returncode != 0:
            tail = p.stdout.read() if p.stdout else ""
            print(f"TEARDOWN: pid {p.pid} exited rc={p.returncode}")
            print("\n".join("  | " + l for l in tail.splitlines()[-40:]))


def main():
    if not os.path.exists(REWIND):
        raise SystemExit(f"{REWIND} not found — run `zig build rewind`")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")

    pid = os.getpid()
    dsrc = f"/tmp/zd-fwd-src-{pid}"
    ddst = f"/tmp/zd-fwd-dst-{pid}"
    for d in (dsrc, ddst):
        subprocess.run(["rm", "-rf", d])

    failures = []

    def check(label, got, want):
        ok = got == want
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} (== {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}")

    try:
        print("boot: source + dest rewind clusters")
        spawn("src", PSRC, dsrc)
        spawn("dst", PDST, ddst)

        # ── A. seed + snapshot onto the dest ──────────────────────────
        print("leg A: seed key1 on source, snapshot onto dest")
        check("PUT src key1", kv_put(PSRC, "key1", "v1"), 204)
        # Confirm the write is visible before snapshotting it — the bundle is
        # a snapshot read, and dumping in the same instant as the commit can
        # race to an empty snapshot.
        check("source read-back key1", kv_get(PSRC, "key1"), (200, "v1"))
        code, bpath = bundle(PSRC)
        check("v2-bundle src", code, "200")
        check("v2-attach dst", attach(PDST, bpath), "204")
        check("v2-resume src", post(PSRC, "v2-resume", f'{{"tenant":"{TENANT}"}}')[0], 204)
        st, body = kv_get(PDST, "key1")
        check("dest has snapshot key1", (st, body), (200, "v1"))

        # ── B. open the overlap ───────────────────────────────────────
        print("leg B: v2-forward-begin on source (dest = :%d)" % PDST)
        dest_url = f"http://127.0.0.1:{PDST}"
        check("forward-begin", post(PSRC, "v2-forward-begin",
              f'{{"tenant":"{TENANT}","dest":"{dest_url}"}}')[0], 204)

        # ── C. live writes on the source are forwarded to the dest ────
        print("leg C: write on source → forwarded → visible on dest (source still serves)")
        check("PUT src key2 (forwarded)", kv_put(PSRC, "key2", "v2"), 204)
        check("PUT src key3 (forwarded)", kv_put(PSRC, "key3", "v3"), 204)
        check("dest got forwarded key2", kv_get(PDST, "key2"), (200, "v2"))
        check("dest got forwarded key3", kv_get(PDST, "key3"), (200, "v3"))
        # the source is still the owner + still serving every key
        check("source still serves key1", kv_get(PSRC, "key1"), (200, "v1"))
        check("source still serves key2", kv_get(PSRC, "key2"), (200, "v2"))

        # ── D. closing the overlap stops forwarding ───────────────────
        print("leg D: v2-forward-end → later writes are NOT forwarded")
        check("forward-end", post(PSRC, "v2-forward-end", f'{{"tenant":"{TENANT}"}}')[0], 204)
        check("PUT src key4 (not forwarded)", kv_put(PSRC, "key4", "v4"), 204)
        check("source serves key4", kv_get(PSRC, "key4"), (200, "v4"))
        check("dest did NOT get key4", kv_get(PDST, "key4")[0], 404)
    finally:
        stop_all()
        for d in (dsrc, ddst):
            subprocess.run(["rm", "-rf", d])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — source keeps serving while every committed write is "
          "dual-written to the destination; the dest stays caught up. (slice b)")


if __name__ == "__main__":
    main()
