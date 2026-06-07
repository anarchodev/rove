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
list (matching the existing per-smoke cleanup pattern). By default they pipe
stdout (tee'd live to our stdout) and block until the process logs
"listening on". For multi-node CP bootstrap — where all nodes must be up
before any can elect — pass `wait=False` and await each later with
`await_ready`; and pass `log_dir=...` so each process logs to a FILE rather
than a PIPE (3+ steadily-logging processes would fill an un-drained pipe and
wedge mid-move — the classic multi-process-smoke flake).
"""

import os
import subprocess
import sys
import time

BINDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "zig-out", "bin")
CP_BIN = os.path.join(BINDIR, "rewind-cp")
FRONT_BIN = os.path.join(BINDIR, "rewind-front")


def await_ready(proc, name, needle, timeout=25, also=None):
    """Block until `proc` logs `needle`. Handles both transports:
    file-logged procs (those carrying `_logf`, from `log_dir=`) are read from
    the file; PIPE procs are read line-by-line and tee'd to our stdout.
    Returns True iff an optional second needle `also` was also seen. Raises
    SystemExit if the process exits early or the deadline passes."""
    deadline = time.time() + timeout
    if hasattr(proc, "_logf"):
        while time.time() < deadline:
            proc._logf.seek(0)
            data = proc._logf.read()
            if needle in data:
                return bool(also) and (also in data)
            if proc.poll() is not None:
                raise SystemExit(f"{name} exited early: rc={proc.returncode}")
            time.sleep(0.1)
        raise SystemExit(f"{name} did not reach '{needle}' within {timeout}s")
    saw_also = False
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


# Back-compat alias — smokes await PIPE-spawned workers via `await_line`.
await_line = await_ready


def _popen(name, argv, env, log_dir):
    """Popen `argv`. With `log_dir`, stdout+stderr go to a per-process file and
    the proc carries `_logf` (file transport); otherwise a tee-able PIPE."""
    if log_dir is not None:
        logf = open(os.path.join(log_dir, f"{name}-{os.getpid()}.log"), "w+")
        p = subprocess.Popen(argv, stdout=logf, stderr=subprocess.STDOUT, env=env)
        p._logf = logf
        p._name = name
        return p
    return subprocess.Popen(
        argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )


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
    wait=True,
    log_dir=None,
):
    """Spawn a `rewind-cp` on `port`.

    Directory config (required): `clusters` (`id=url,...;...`), `hosts`
    (`host=tenant;...`), `placement` (`tenant=cluster;...`), `cp_data_dir`
    (durable directory store). `move_secret` enables the move surface.
    Multi-node (HA) CP: pass `node_id` / `voters` / `peers` / `peer_urls`
    (the directory raft group spans the voter set), `wait=False` (await all
    nodes after launching them all), and `log_dir` (file transport).
    `want_needle` asserts a boot-log line (e.g. the seed-vs-replay decision)
    appears before "listening on". Returns the proc (appended to `procs`)."""
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
    p = _popen(name, [CP_BIN, str(port)], env, log_dir)
    procs.append(p)
    if wait:
        saw = await_ready(p, name, "listening on", also=want_needle)
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
    wait=True,
    log_dir=None,
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
    p = _popen(name, [FRONT_BIN, str(port)], env, log_dir)
    procs.append(p)
    if wait:
        await_ready(p, name, "listening on")
    return p
