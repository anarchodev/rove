"""Shared spawn helpers for the V2 two-process edge topology.

After the front-door / control-plane split (docs/v2-front-door-architecture.md),
the edge is two binaries:

  - `rewind-cp`    — the control plane: owns the replicated directory
                     (placement + host→tenant index) + the directory raft
                     group, orchestrates moves (`/_control/move`), and serves
                     `/_cp/route` + `/_cp/leader`. Its OWN small raft cluster.
  - `rewind-front` — a STATELESS proxy that resolves placement from the CP's
                     `/_cp/route` (cached) and reverse-proxies to the owning
                     cluster. Holds no directory/raft state.

A smoke spawns ONE CP (single- or multi-node) and one-or-more front doors
pointed at it via `REWIND_CP_URL`. Control/`/_cp` calls go to the CP port;
customer traffic goes to the front port.

`spawn_cp` / `spawn_front` append the spawned process to the caller's `procs`
list (matching the existing per-smoke cleanup pattern) and block until the
process logs "listening on".
"""

import os
import subprocess
import sys
import time

BINDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "zig-out", "bin")
CP_BIN = os.path.join(BINDIR, "rewind-cp")
FRONT_BIN = os.path.join(BINDIR, "rewind-front")


def await_line(proc, name, needle, timeout=15, also=None):
    """Read `proc.stdout` (teeing to our stdout) until `needle` appears.
    Returns True iff an optional second needle `also` was seen first.
    Raises SystemExit if the process exits early or the deadline passes."""
    saw_also = False
    deadline = time.time() + timeout
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            if proc.poll() is not None:
                raise SystemExit(f"{name} exited early: rc={proc.returncode}")
            continue
        sys.stdout.write(f"  [{name}] " + line)
        if also and also in line:
            saw_also = True
        if needle in line:
            return saw_also
    raise SystemExit(f"{name} did not reach '{needle}' within {timeout}s")


def spawn_cp(
    procs,
    port,
    *,
    clusters,
    hosts,
    placement,
    cp_data_dir,
    move_secret=None,
    node_id=None,
    voters=None,
    peers=None,
    peer_urls=None,
    reconcile_secs=None,
    name="cp",
    want_needle=None,
    extra_env=None,
):
    """Spawn a `rewind-cp` on `port`.

    Directory config (required): `clusters` (`id=url,...;...`), `hosts`
    (`host=tenant;...`), `placement` (`tenant=cluster;...`), `cp_data_dir`
    (durable directory store). `move_secret` enables the move surface.
    Multi-node (HA) CP: pass `node_id` / `voters` / `peers` / `peer_urls`
    (the directory raft group spans the voter set). `want_needle` asserts a
    boot-log line (e.g. the seed-vs-replay decision) appears before
    "listening on". Returns the proc (appended to `procs`)."""
    env = dict(os.environ)
    env["REWIND_CLUSTERS"] = clusters
    env["REWIND_HOSTS"] = hosts
    env["REWIND_PLACEMENT"] = placement
    env["REWIND_CP_DATA_DIR"] = cp_data_dir
    if move_secret is not None:
        env["REWIND_MOVE_SECRET"] = move_secret
    if node_id is not None:
        env["REWIND_CP_NODE_ID"] = str(node_id)
    if voters is not None:
        env["REWIND_CP_VOTERS"] = voters
    if peers is not None:
        env["REWIND_CP_PEERS"] = peers
    if peer_urls is not None:
        env["REWIND_CP_PEER_URLS"] = peer_urls
    if reconcile_secs is not None:
        env["REWIND_CP_RECONCILE_SECS"] = str(reconcile_secs)
    if extra_env:
        env.update(extra_env)
    p = subprocess.Popen(
        [CP_BIN, str(port)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
    procs.append(p)
    saw = await_line(p, name, "listening on", also=want_needle)
    if want_needle and not saw:
        raise SystemExit(f"{name}: expected boot log {want_needle!r} not seen")
    return p


def spawn_front(
    procs,
    port,
    cp_url,
    *,
    route_cache_ms=None,
    name="front",
    extra_env=None,
):
    """Spawn a stateless `rewind-front` on `port`, resolving placement from
    `cp_url` (`REWIND_CP_URL`; `;`-join multiple CP origins for HA). Returns
    the proc (appended to `procs`)."""
    env = dict(os.environ)
    env["REWIND_CP_URL"] = cp_url
    if route_cache_ms is not None:
        env["REWIND_ROUTE_CACHE_MS"] = str(route_cache_ms)
    if extra_env:
        env.update(extra_env)
    p = subprocess.Popen(
        [FRONT_BIN, str(port)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
    procs.append(p)
    await_line(p, name, "listening on")
    return p
