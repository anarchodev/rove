"""Child-process survival rules for the smoke harness.

The V2 harness inherited `smoke_lib.py`'s SHAPE — spawn, tear down in
`__exit__` — but not its safety net. `smoke_lib.py` tracks every child,
registers `atexit`, and traps SIGINT/SIGTERM so that cleanup runs on paths a
context manager never sees. None of that came across, and the result is
visible on any shared box: orphaned `rewind-worker`s aged hours, each holding
a data dir and a port.

Four holes, closed here in order of how much they leak:

1. **A failure DURING spawn.** `V2Cluster.spawn` builds a cluster and only
   then does the caller enter `with`, so an exception mid-boot — the exact
   case a flaky `await_ready` produces — leaks every node already started,
   because `__exit__` was never armed. Tracking at Popen time closes it.
2. **A signal.** Python's default SIGTERM exits without running `atexit`, so
   a `kill` of a wedged smoke leaves the whole cluster behind.
3. **The harness dying outright** (SIGKILL, OOM, a crashed agent session).
   Nothing in-process can help, so the CHILD is told to die instead:
   `PR_SET_PDEATHSIG` asks the kernel to SIGTERM it when its parent goes.
4. **Orphans that already exist**, from runs that predate all of the above.
   `reap_orphans` clears them, keyed on a discriminator that cannot touch a
   live sibling session's run.
"""

from __future__ import annotations

import atexit
import ctypes
import os
import signal
import subprocess
import sys
import time
from contextlib import suppress

# Every child this process spawned, live or not. Append-only: a dead entry is
# cheap and removing them races the signal handler.
_TRACKED: list = []

PR_SET_PDEATHSIG = 1

# Resolved in the PARENT, at import, on purpose. `preexec_fn` runs in the child
# between fork and exec, where only async-signal-safe work is legal — and a
# `dlopen` there can deadlock outright if any other thread held the dynamic
# loader's lock at the moment of the fork. Doing the load up front leaves the
# child with a single already-resolved call.
try:
    _LIBC = ctypes.CDLL("libc.so.6", use_errno=True)
except OSError:  # not glibc / not Linux — the in-process nets still apply
    _LIBC = None


def _pdeathsig():
    """Ask the kernel to SIGTERM this child when its parent dies.

    The one guarantee that survives the harness being SIGKILLed, which is
    where every hours-old orphan comes from — `atexit` and signal handlers
    both need the parent to still be running to help. A failure is not worth
    aborting a spawn over: this is a backstop behind three in-process nets,
    not a replacement for them.
    """
    if _LIBC is not None:
        _LIBC.prctl(PR_SET_PDEATHSIG, signal.SIGTERM)


def popen(argv, **kwargs) -> subprocess.Popen:
    """`subprocess.Popen` that cannot outlive this process by accident."""
    kwargs.setdefault("preexec_fn", _pdeathsig)
    p = subprocess.Popen(argv, **kwargs)
    _TRACKED.append(p)
    return p


def track(p: subprocess.Popen) -> subprocess.Popen:
    """Register a process spawned elsewhere. Idempotent."""
    if p not in _TRACKED:
        _TRACKED.append(p)
    return p


def terminate_all(timeout: float = 5.0) -> None:
    """SIGTERM every tracked child, wait, then SIGKILL the holdouts."""
    live = [p for p in _TRACKED if p.poll() is None]
    if not live:
        return
    for p in live:
        with suppress(ProcessLookupError, OSError):
            p.terminate()
    deadline = time.monotonic() + timeout
    for p in live:
        with suppress(subprocess.TimeoutExpired, ProcessLookupError, OSError):
            p.wait(timeout=max(0.0, deadline - time.monotonic()))
    for p in live:
        if p.poll() is None:
            with suppress(ProcessLookupError, OSError):
                p.kill()


def install() -> None:
    """Arm the in-process nets. Safe to call repeatedly."""
    if getattr(install, "_armed", False):
        return
    install._armed = True
    atexit.register(terminate_all)

    def handler(signum, _frame):
        sys.stderr.write(f"\nsmoke: caught signal {signum}, tearing down children\n")
        # sys.exit runs atexit; _exit would not.
        sys.exit(130 if signum == signal.SIGINT else 143)

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        with suppress(ValueError, OSError):  # not the main thread / unsupported
            signal.signal(sig, handler)


# ── reaping what earlier runs left behind ─────────────────────────────────

# Binaries a smoke spawns. Matched on the EXE name, never with `pkill -f`,
# whose pattern would also match the shell wrapper doing the matching.
_SMOKE_BINARIES = {"rewind-worker", "rewind-cp", "rewind-front", "rewind-logs"}


def _orphans() -> list[tuple[int, str]]:
    """(pid, cmdline) for smoke binaries whose parent is gone.

    The discriminator is **PPID == 1**, and it is the whole safety argument: a
    process belonging to a LIVE run has a live parent, so it can never appear
    here. Reparenting to init is exactly the state we want to clear, and it is
    not reachable while the owning smoke is alive — so this cannot disturb a
    sibling session, no matter how many are running.
    """
    out = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        try:
            with open(f"/proc/{pid}/comm") as f:
                comm = f.read().strip()
            if comm not in _SMOKE_BINARIES:
                continue
            with open(f"/proc/{pid}/status") as f:
                ppid = next(int(l.split()[1]) for l in f if l.startswith("PPid:"))
            if ppid != 1:
                continue
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmdline = f.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
        except (OSError, StopIteration, ValueError):
            continue
        out.append((pid, cmdline))
    return out


def reap_orphans(*, dry_run: bool = False) -> int:
    """SIGTERM (then SIGKILL) orphaned smoke binaries. Returns how many."""
    found = _orphans()
    for pid, cmdline in found:
        print(f"smoke: reaping orphan pid {pid}: {cmdline[:110]}", flush=True)
        if dry_run:
            continue
        with suppress(ProcessLookupError, PermissionError):
            os.kill(pid, signal.SIGTERM)
    if found and not dry_run:
        time.sleep(1.0)
        for pid, _ in found:
            with suppress(ProcessLookupError, PermissionError):
                os.kill(pid, 0)          # still there?
                os.kill(pid, signal.SIGKILL)
    return len(found)


if __name__ == "__main__":
    n = reap_orphans(dry_run="--dry-run" in sys.argv)
    print(f"smoke: {n} orphan(s) {'found' if '--dry-run' in sys.argv else 'reaped'}")
