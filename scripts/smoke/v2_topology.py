"""Shared spawn helpers for the V2 two-process edge topology.

After the front-door / control-plane split (the front door —
`docs/architecture/routing-and-ingress.md`),
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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import smoke_reap  # noqa: E402

BINDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "zig-out", "bin")
CP_BIN = os.path.join(BINDIR, "rewind-cp")
FRONT_BIN = os.path.join(BINDIR, "rewind-front")


def read_log_text(logf) -> str:
    """Read a log file that a live process is still WRITING, tolerantly.

    A poll can land mid-multi-byte-character, leaving the file ending on an
    incomplete UTF-8 sequence — and strict decoding RAISES there rather than
    returning what it has. That traceback escaped `V2Cluster.spawn`, which
    leaked every node already started, because the caller only enters `with`
    once spawn returns (rove#637). rove's log lines are full of em-dashes, so
    the target is wide, and it is load-dependent rather than random: more
    interleaving between writer and reader means more chances to land badly.

    Reads through the BINARY buffer so the seek and the read agree; a text
    wrapper's own buffering makes mixing the two levels unsound. The next poll
    0.1s later sees the complete line, so a replacement character costs
    nothing.
    """
    buf = getattr(logf, "buffer", None)
    if buf is None:                      # already binary, or an odd handle
        logf.seek(0)
        data = logf.read()
        return data.decode("utf-8", "replace") if isinstance(data, bytes) else data
    buf.seek(0)
    return buf.read().decode("utf-8", "replace")


def await_ready(proc, name, needle, timeout=25, also=None):
    """Block until `proc` logs `needle`. Handles both transports:
    file-logged procs (those carrying `_logf`, from `log_dir=`) are read from
    the file; PIPE procs are read line-by-line and tee'd to our stdout.
    Returns True iff an optional second needle `also` was also seen. Raises
    SystemExit if the process exits early or the deadline passes."""
    deadline = time.time() + timeout
    if hasattr(proc, "_logf"):
        while time.time() < deadline:
            data = read_log_text(proc._logf)
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
        p = smoke_reap.popen(argv, stdout=logf, stderr=subprocess.STDOUT, env=env)
        p._logf = logf
        p._name = name
        return p
    return smoke_reap.popen(
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
    public_suffix=None,
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

    `public_suffix` turns on wildcard tenant routing (`{tenant}.{suffix}` →
    the tenant's placement, no host row) and must match what the workers get.

    Directory config (required): `clusters` (`id=url,...;...`), `hosts`
    (`host=tenant;...`), `placement` (`tenant=cluster;...`), `cp_data_dir`
    (durable directory store). `move_secret` enables the move surface.
    Multi-node (HA) CP: pass `node_id` / `voters` / `peers` / `peer_urls`
    (the directory raft group spans the voter set), `wait=False` (await all
    nodes after launching them all), and `log_dir` (file transport).
    `want_needle` asserts a boot-log line (e.g. the seed-vs-replay decision)
    appears before "listening on". Returns the proc (appended to `procs`)."""
    env = dict(os.environ)
    # No operator-metrics listener by default: concurrent smokes would fight
    # over (or worse, silently share) the fixed :9111. A smoke that tests the
    # surface passes its own allocated port via extra_env / its environ.
    env.setdefault("REWIND_CP_METRICS_PORT", "0")
    env["REWIND_CLUSTERS"] = clusters
    env["REWIND_HOSTS"] = hosts
    env["REWIND_PLACEMENT"] = placement
    env["REWIND_CP_DATA_DIR"] = cp_data_dir
    # The CP resolves `{tenant}.{suffix}` for the front door and the worker
    # resolves it again for itself, so BOTH must carry the same suffix — a CP
    # without it 404s every tenant that has no explicit host row.
    if public_suffix is not None:
        env["REWIND_PUBLIC_SUFFIX"] = public_suffix
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
    # Same rationale as spawn_cp: the fixed :9112 default cannot be shared
    # between concurrent smokes.
    env.setdefault("REWIND_FRONT_METRICS_PORT", "0")
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
