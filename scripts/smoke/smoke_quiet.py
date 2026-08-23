"""Box-quietness authority for the smoke suite — the cross-SESSION half of it.

Two mechanisms, because they answer different questions:

  - `shared()` / `exclusive()` — a readers-writer lock coordinating the smokes
    THIS repo runs, across every clone on the machine.
  - `io_stall()` — a measurement of what we do NOT control (a sibling's
    `zig build`, someone's `cargo`, an unrelated tenant on the box).

Neither alone is enough. A lock without measurement produces false confidence
("I held it, so this red is real") exactly when a neighbour is compiling; a
measurement without a lock leaves the timing-sensitive smokes fighting each
other for a resource they could simply have taken turns with.

## Why flock, and why two files

`smoke_ports.py` already partitions PORTS across sessions with `flock` on
`/tmp`, and the reasoning carries over unchanged: the lock is released by the
kernel when the fd closes, so a killed run cannot wedge the machine, and there
is no daemon to own. This module is the same trick applied to time rather than
address space.

Two lock files, not one, because `flock` on Linux has **no writer
preference**: a steady stream of pool members can starve a waiting soak
indefinitely. So a writer takes `gate` exclusively FIRST and holds it while it
waits for `data` — new readers then block on `gate` while in-flight readers
drain, and the writer gets in. Readers touch `gate` only briefly (acquire,
then acquire `data`, then release `gate`), so the common path stays cheap.

## Escape hatches, deliberately

`SMOKE_QUIET_LOCK=0` disables the lock entirely, and every wait is bounded —
on timeout the smoke proceeds CONTENDED rather than failing. This is shared
infrastructure for several agent sessions at once: a bug here would wedge
every session's suite simultaneously, so the failure mode is "coordinate
worse", never "stop working".
"""

from __future__ import annotations

import fcntl
import os
import sys
import time
from contextlib import contextmanager

# Overridable so the self-test can exercise the real code against its own
# files — pointing a test at the production lock would have it queue behind
# (or worse, block) the suite that is running it.
GATE_PATH = os.environ.get("SMOKE_QUIET_GATE", "/tmp/rove-smoke-quiet.gate")
DATA_PATH = os.environ.get("SMOKE_QUIET_DATA", "/tmp/rove-smoke-quiet.lock")

# Smokes that need the box to themselves. Single source of truth: `run_all.py`
# imports this as its serial tail, and `smoke_lib_v2` consults it so a
# HAND-RUN member takes the exclusive lock too — the case the in-run serial
# tail could never cover.
#
# Membership is empirical, and the bar is "co-load makes its assertion
# unreadable", not "it once went red". A member that proves load-tolerant
# should move back to the pool: the tail bounds the parallel suite's floor.
QUIET_EXCLUSIVE = {
    "raft_soak_prod.py",            # kill/wipe/heal rounds on election timing
    "raft_soak_v2.py",              # same shape, shorter
    "dispatch_gate_smoke_v2.py",    # rove#362: intermittent even serially
    "leader_failover_smoke_v2.py",  # one acquisition per ORPHANED group
    "snapshot_trigger_smoke_v2.py", # SIGSTOP/SIGCONT against a compaction
                                    # window: co-load stretches the freeze and
                                    # the victim catches up before the gap
                                    # opens. Flaked "failed under load, passed
                                    # alone" in 2 of 3 suite runs on 2026-08-18.
    "churn_kv_convergence_smoke_v2.py",  # six writers on ONE key + forced
                                    # leadership flips + rolling restarts, then
                                    # a three-node agreement check. Co-load
                                    # stretches the quiesce window and the
                                    # apply lag it is measuring against, so a
                                    # neighbour's build reads as a fork.
}

# How long a waiter blocks before giving up and running contended.
WAIT_TIMEOUT_S = float(os.environ.get("SMOKE_QUIET_TIMEOUT", "900"))
# Announce a wait that outlasts this, so a human or agent watching a silent
# terminal can tell "queued behind a soak" from "hung".
ANNOUNCE_AFTER_S = 5.0


def enabled() -> bool:
    return os.environ.get("SMOKE_QUIET_LOCK", "1") != "0"


def _open(path: str) -> int:
    return os.open(path, os.O_CREAT | os.O_RDWR, 0o666)


def _describe(fd: int) -> str:
    """Whatever the current holder wrote about itself. Best-effort: an empty
    or half-written record just reads as unknown."""
    try:
        os.lseek(fd, 0, os.SEEK_SET)
        return os.read(fd, 256).decode("utf-8", "replace").strip() or "unknown holder"
    except OSError:
        return "unknown holder"


def _stamp(fd: int, what: str) -> None:
    try:
        os.ftruncate(fd, 0)
        os.lseek(fd, 0, os.SEEK_SET)
        os.write(fd, f"{what} pid={os.getpid()} since={time.strftime('%H:%M:%S')}".encode())
    except OSError:
        pass  # the lock is the contract; the label is a courtesy


def _acquire(fd: int, op: int, label: str, kind: str) -> bool:
    """Block for `op` on `fd`, announcing a long wait. False on timeout."""
    deadline = time.monotonic() + WAIT_TIMEOUT_S
    announced = False
    started = time.monotonic()
    while True:
        try:
            fcntl.flock(fd, op | fcntl.LOCK_NB)
            return True
        except OSError:
            pass
        waited = time.monotonic() - started
        if not announced and waited >= ANNOUNCE_AFTER_S:
            print(f"smoke: waiting for the {kind} box lock ({label}) — "
                  f"held by {_describe(fd)}", flush=True)
            announced = True
        if time.monotonic() >= deadline:
            print(f"smoke: WAITED {waited:.0f}s for the {kind} box lock and gave up — "
                  f"running CONTENDED; a timing-sensitive result here is not "
                  f"trustworthy (rove#655)", file=sys.stderr, flush=True)
            return False
        time.sleep(0.25)


@contextmanager
def shared(label: str = "smoke"):
    """Hold the box as one of many concurrent smokes."""
    if not enabled():
        yield True
        return
    gate = _open(GATE_PATH)
    data = _open(DATA_PATH)
    got = False
    try:
        # Pass through the gate so a waiting writer can shut the door behind us.
        _acquire(gate, fcntl.LOCK_SH, label, "shared")
        got = _acquire(data, fcntl.LOCK_SH, label, "shared")
        fcntl.flock(gate, fcntl.LOCK_UN)
        yield got
    finally:
        for fd in (gate, data):
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)


@contextmanager
def exclusive(label: str = "smoke"):
    """Hold the box alone. Yields False if the wait timed out and we are
    proceeding contended, so the caller can label its result."""
    if not enabled():
        yield True
        return
    gate = _open(GATE_PATH)
    data = _open(DATA_PATH)
    try:
        # Shut the door FIRST and keep it shut: new readers queue on the gate
        # while the in-flight ones drain, so this cannot starve.
        _acquire(gate, fcntl.LOCK_EX, label, "exclusive")
        _stamp(gate, f"exclusive:{label}")
        got = _acquire(data, fcntl.LOCK_EX, label, "exclusive")
        _stamp(data, f"exclusive:{label}")
        yield got
    finally:
        for fd in (gate, data):
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)


def io_stall() -> float | None:
    """Percentage of the last 60s that ALL tasks were stalled on I/O, or None
    where the kernel does not report it.

    `full` rather than `some`, and I/O rather than CPU, because that is what
    the evidence pointed at: a run that tripped a spurious election showed
    io.full avg60 = 59% while cpu.full was 0.00 and load average was 1.1 on 32
    cores. Every CPU-shaped indicator looked idle while the box could not
    fsync — which is precisely the pause-tail an election timeout races.
    """
    try:
        with open("/proc/pressure/io") as f:
            for line in f:
                if line.startswith("full"):
                    for field in line.split():
                        if field.startswith("avg60="):
                            return float(field.split("=", 1)[1])
    except (OSError, ValueError):
        return None
    return None


# Above this, a timing-sensitive failure cannot be attributed to the code.
# Deliberately generous: the observed bad run sat at ~59%, and a quiet box
# measures ~0. The gap is wide, so a threshold anywhere in it costs nothing.
STALL_INCONCLUSIVE_PCT = float(os.environ.get("SMOKE_STALL_THRESHOLD", "20"))
