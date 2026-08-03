"""Port authority for the smoke suite — the one place ports come from.

Every smoke process owns one SLOT: a disjoint range of ports it may bind.
Within its slot, `alloc(n)` hands out contiguous blocks (a `V2Cluster` takes
one block per spawn; a hand-rolled topology or helper upstream takes what it
needs). Two smokes can never collide, because two processes can never hold
the same slot:

  - Under `run_all.py --jobs`, the runner assigns each child a distinct slot
    via `SMOKE_PORT_SLOT` — coordination by construction, no probing races.
  - Standalone (a hand-run smoke, possibly while a suite runs), the process
    `flock`s a slot lockfile in /tmp and keeps the fd for its lifetime, so
    concurrent hand-runs self-partition the same way.

This replaces the fixed per-smoke port table (each smoke hardcoding its own
`18xxx` bases), which only worked while the suite ran serially — and even
then leaked collisions through `_free_base`'s pid-modular nudge, whose
stride (20) was smaller than a cluster's actual port span (~110).

The whole range sits BELOW the kernel ephemeral range (32768+ on Linux), so
an outbound connection's source port can never squat a listener port between
the allocator's probe and the binary's bind.

Blocks are probed (bind + close each port) before being handed out; a block
with a busy port — e.g. a leftover process from a killed run — is skipped,
not fought over.
"""

from __future__ import annotations

import fcntl
import os
import socket

SLOT_BASE = 20000   # slots span [20000, 32600) — below the ephemeral range
SLOT_SIZE = 600     # ports per smoke process (a V2Cluster block is 128)
SLOT_COUNT = 21

# One V2Cluster's span: worker HTTP at +0..+N, cp +50, front +51, log +53,
# TLS front +54, raft transport at +100..+100+N.
CLUSTER_BLOCK = 128

_slot: int | None = None
_slot_lock_fd: int | None = None  # held open for the process lifetime
_cursor = 0
_freed: list[tuple[int, int]] = []  # (base, n) blocks returned by free()


def _bindable(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def _acquire_slot() -> int:
    global _slot, _slot_lock_fd
    if _slot is not None:
        return _slot
    env = os.environ.get("SMOKE_PORT_SLOT")
    if env is not None:
        _slot = int(env)
        if not (0 <= _slot < SLOT_COUNT):
            raise SystemExit(f"SMOKE_PORT_SLOT={_slot} out of range 0..{SLOT_COUNT - 1}")
        return _slot
    for i in range(SLOT_COUNT):
        fd = os.open(f"/tmp/rove-smoke-slot-{i}.lock", os.O_CREAT | os.O_RDWR, 0o666)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            continue
        _slot_lock_fd = fd
        _slot = i
        return _slot
    raise SystemExit(
        f"no free smoke port slot ({SLOT_COUNT} concurrent smoke processes?) — "
        "a dead run may be holding /tmp/rove-smoke-slot-*.lock via a live child")


def alloc(n: int = CLUSTER_BLOCK) -> int:
    """Base port of a contiguous block of `n` free ports, disjoint from every
    other block handed out in this process and (via the slot) from every
    concurrent smoke run. Blocks are never reused within a process, so a
    stopped-then-restarted node keeps its port."""
    global _cursor
    if n > SLOT_SIZE:
        raise ValueError(f"alloc({n}) exceeds the slot size {SLOT_SIZE}")
    slot = _acquire_slot()
    # Freed blocks first (exact-size match) — a smoke that brings clusters up
    # and down repeatedly (a genesis flake harness runs 12) would otherwise
    # exhaust its slot.
    for i, (base, fn) in enumerate(_freed):
        if fn == n and all(_bindable(p) for p in range(base, base + n)):
            _freed.pop(i)
            return base
    lo = SLOT_BASE + slot * SLOT_SIZE
    while True:
        base = lo + _cursor
        if base + n > lo + SLOT_SIZE:
            raise SystemExit(
                f"smoke port slot {slot} exhausted (asked for {n} more after "
                f"{_cursor}) — this smoke allocates more than {SLOT_SIZE} ports")
        _cursor += n
        if all(_bindable(p) for p in range(base, base + n)):
            return base


def free(base: int, n: int) -> None:
    """Return a block for reuse by a LATER alloc in this process — only once
    every process bound to it has exited (V2Cluster.shutdown waits). A live
    block is never freed: a stopped-then-restarted node keeps its port."""
    _freed.append((base, n))


def alloc_port() -> int:
    """A single free port from this process's slot. For helper servers (an
    upstream echo, a metrics listener) that sit beside a cluster block."""
    return alloc(1)


def acquire_slots(n: int) -> list[int]:
    """For a RUNNER: flock `n` slots (held for the runner's lifetime) to hand
    to children via SMOKE_PORT_SLOT. Going through the same lockfiles the
    standalone path uses means a hand-run smoke beside a running suite still
    self-partitions — the runner's slots are visibly taken."""
    got: list[int] = []
    for i in range(SLOT_COUNT):
        if len(got) == n:
            break
        fd = os.open(f"/tmp/rove-smoke-slot-{i}.lock", os.O_CREAT | os.O_RDWR, 0o666)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            continue
        got.append(i)  # fd deliberately left open — the lock IS the lease
    if len(got) < n:
        raise SystemExit(f"only {len(got)} of {n} port slots free — "
                         "another suite running?")
    return got
