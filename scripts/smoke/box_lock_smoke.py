#!/usr/bin/env python3
"""Gate on the cross-session box lock (`smoke_quiet`) and the orphan reaper
(`smoke_reap`) — the two pieces of shared infrastructure every OTHER smoke now
depends on.

Worth gating precisely because it is invisible: nothing else in the suite
fails if the lock silently stops excluding, or starts excluding too much. The
first makes timing-sensitive smokes flaky again; the second wedges every
session's suite at once. Neither shows up as a test failure anywhere else.

Needs no S3, no binaries, no cluster — it runs against its own lock files via
`SMOKE_QUIET_GATE` / `SMOKE_QUIET_DATA`, so it never touches the lock held by
the suite running it.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import smoke_quiet  # noqa: E402
import smoke_reap  # noqa: E402

failures: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
    if not ok:
        failures.append(label)


def holder(mode: str, seconds: float, env: dict) -> subprocess.Popen:
    """A child that takes the lock in `mode` and holds it for `seconds`."""
    # The child reports the WALL TIME it acquired at. Comparing children on a
    # shared clock is the only way to order them: measuring from when the
    # parent starts watching would time each from a different origin, and
    # would score "the writer got in first" as the reader not having waited.
    code = (
        "import sys,time; sys.path.insert(0,%r); import smoke_quiet\n"
        "with smoke_quiet.%s('test') as got:\n"
        "    print('ACQUIRED', got, repr(time.time()), flush=True)\n"
        "    time.sleep(%r)\n" % (str(HERE), mode, seconds)
    )
    return subprocess.Popen([sys.executable, "-c", code], env={**os.environ, **env},
                            stdout=subprocess.PIPE, text=True)


def await_acquired(p: subprocess.Popen, timeout: float) -> float | None:
    """The child's wall-clock acquisition time, or None if it never acquired."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        line = p.stdout.readline()
        if line.startswith("ACQUIRED"):
            return float(line.split()[2])
        if not line and p.poll() is not None:
            return None
    return None


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="boxlock-") as tmp:
        env = {"SMOKE_QUIET_GATE": f"{tmp}/gate", "SMOKE_QUIET_DATA": f"{tmp}/data",
               "SMOKE_QUIET_TIMEOUT": "20"}

        print("step 1: two shared holders overlap (the common path stays parallel)")
        t_start = time.time()
        a = holder("shared", 3.0, env)
        b = holder("shared", 3.0, env)
        ta, tb = await_acquired(a, 5), await_acquired(b, 5)
        check("both shared holders acquired", ta is not None and tb is not None)
        check("neither waited for the other",
              ta is not None and tb is not None
              and max(ta, tb) - t_start < 1.5,
              f"{max(ta or 0, tb or 0) - t_start:.2f}s after launch")
        a.wait(); b.wait()

        print("step 2: ⭐ a writer waits for readers to drain")
        r = holder("shared", 2.5, env)
        tr = await_acquired(r, 5)
        check("reader acquired", tr is not None)
        w = holder("exclusive", 0.2, env)
        tw = await_acquired(w, 20)
        check("writer eventually acquired", tw is not None)
        check("writer waited out the reader's hold",
              tw is not None and tr is not None and tw - tr >= 2.0,
              f"{tw - tr:.2f}s after the reader" if (tw and tr) else "never")
        r.wait(); w.wait()

        print("step 3: ⭐ a waiting writer blocks NEW readers (no writer starvation)")
        r1 = holder("shared", 3.0, env)
        check("first reader acquired", await_acquired(r1, 5) is not None)
        w = holder("exclusive", 0.2, env)
        time.sleep(0.5)                      # let the writer take the gate
        r2 = holder("shared", 0.2, env)      # arrives while the writer waits
        tw = await_acquired(w, 20)
        tr2 = await_acquired(r2, 20)
        check("writer got in", tw is not None)
        # Without the gate, flock has no writer preference and this reader
        # would slip in ahead — a steady stream of them starves the soak.
        check("the late reader queued BEHIND the writer",
              tw is not None and tr2 is not None and tr2 >= tw,
              f"writer at {tw}, reader at {tr2}" if (tw and tr2) else "never")
        for p in (r1, w, r2):
            p.wait()

        print("step 4: a dead holder releases the lock (no stale-lock wedge)")
        v = holder("exclusive", 30.0, env)
        check("victim acquired", await_acquired(v, 5) is not None)
        v.kill(); v.wait()
        w = holder("exclusive", 0.2, env)
        check("a killed holder does not wedge the lock", await_acquired(w, 10) is not None)
        w.wait()

        print("step 5: the kill switch bypasses entirely")
        blocker = holder("exclusive", 5.0, env)
        tb2 = await_acquired(blocker, 5)
        check("blocker acquired", tb2 is not None)
        t_off = time.time()
        off = holder("exclusive", 0.1, {**env, "SMOKE_QUIET_LOCK": "0"})
        toff = await_acquired(off, 5)
        check("SMOKE_QUIET_LOCK=0 does not block",
              toff is not None and toff - t_off < 2.0,
              f"{toff - t_off:.2f}s" if toff else "never")
        off.wait(); blocker.kill(); blocker.wait()

    print("step 6: the reaper's discriminator")
    # A live child of THIS process must never be reaped: its parent is alive,
    # so it cannot be reparented to init. That is the whole safety argument
    # for touching processes a sibling session may own.
    live = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(5)"])
    try:
        orphans = smoke_reap._orphans()
        check("a live child is not an orphan", live.pid not in [pid for pid, _ in orphans])
        check("only known smoke binaries are candidates",
              all(any(b in cmd for b in smoke_reap._SMOKE_BINARIES) for _, cmd in orphans),
              f"{len(orphans)} candidate(s)")
    finally:
        live.kill(); live.wait()

    print("step 7: ⭐ a SIGKILLed harness does not leave its nodes behind")
    # The case every hours-old orphan comes from: `atexit` and the signal
    # handlers both need the parent alive to run, so only the kernel can help.
    # A grandchild started through `smoke_reap.popen` must die when its parent
    # is SIGKILLed, with nothing in userspace involved.
    code = ("import sys,time; sys.path.insert(0,%r); import smoke_reap\n"
            "p = smoke_reap.popen(['sleep','60'])\n"
            "print(p.pid, flush=True); time.sleep(60)\n" % str(HERE))
    parent = subprocess.Popen([sys.executable, "-c", code],
                              stdout=subprocess.PIPE, text=True)
    gpid = int(parent.stdout.readline().strip())
    time.sleep(0.5)
    parent.kill()
    parent.wait()
    time.sleep(1.5)
    check("the grandchild died with its SIGKILLed parent",
          not os.path.exists(f"/proc/{gpid}"),
          f"pid {gpid} still alive" if os.path.exists(f"/proc/{gpid}") else "")

    print("step 8: io_stall reports a number or None, never a crash")
    stall = smoke_quiet.io_stall()
    check("io_stall readable", stall is None or 0.0 <= stall <= 100.0, f"{stall}")

    print("step 9: ⭐ await_ready survives a half-written log line")
    # rove#637. `await_ready` polls a log the node is still writing, so a poll
    # can land mid-multi-byte-character. Strict decoding RAISES there, and the
    # traceback escaped `V2Cluster.spawn` — leaking the nodes already up.
    from v2_topology import read_log_text
    raw = "rewind: listening on 0.0.0.0:20000 — ready".encode("utf-8")
    path = tempfile.mktemp(suffix=".log")
    open(path, "wb").write(raw[:37])          # stopped mid em-dash
    h = open(path, "r+")
    try:
        strict_raised = False
        try:
            h.seek(0)
            h.read()
        except UnicodeDecodeError:
            strict_raised = True
        check("the truncated line still breaks a strict read", strict_raised,
              "if this stops failing the fixture no longer reproduces #637")
        text = read_log_text(h)
        check("the tolerant read returns the line", "listening on" in text)
    finally:
        h.close()
        os.unlink(path)

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS harness infrastructure — mutual exclusion, no starvation, no "
          "stale wedge, children die with a SIGKILLed parent, the reaper cannot "
          "touch a live run, and a half-written log line does not abort a spawn. ⭐")
    return 0


if __name__ == "__main__":
    sys.exit(main())
