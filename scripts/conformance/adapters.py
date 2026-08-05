# SPDX-FileCopyrightText: 2026 Loop46, Inc.
# SPDX-License-Identifier: AGPL-3.0-or-later
"""One corpus, three adapters behind one interface.

An adapter takes a world (the language-neutral trigger + readset document
`docs/architecture/replay-and-sim.md` defines) plus the case's source tree, runs
it on ONE engine, and returns a normalized `Outcome`. It asserts nothing — the
comparison is the runner's job, and an adapter that judged its own result would
be an engine grading its own homework.

Three engines run customer handlers, so there are three adapters:

- `sim`    — the offline reactor, via `rewind sim`. No cluster, no network.
- `replay` — the browser WASM arena, driven headless from node through
             `replay_driver.mjs`. No cluster either; it needs `$REWIND_APPS_DIR`
             for the porcelain, and reports itself unavailable without it.
- `prod`   — the worker on a live V2Cluster. Needs S3 credentials and port
             slots, so it is the CLUSTER lane, not the cheap one; one cluster is
             brought up per process and amortized across the whole corpus.

An adapter that cannot run raises `EngineUnavailable` rather than being omitted:
a case that names an engine must visibly not-run on it, because "did not run"
and "ran and agreed" have to stay distinguishable — that distinction is what
makes a three-way disagreement localize a fault instead of merely reporting
one.
"""

from __future__ import annotations

import atexit
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from outcome import (
    Outcome,
    from_prod_response,
    from_replay_result,
    from_sim_bundle,
)

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


class EngineUnavailable(Exception):
    """The engine cannot run this world at all — no adapter, no binary, or the
    case declares itself unrunnable there. Never a comparison result."""


class AdapterError(Exception):
    """The engine ran and failed in a way that is not a behavioral outcome — a
    crashed binary, unparseable output, a run that never terminated. A real
    failure, not a divergence."""


# Per-engine wall-clock ceilings. Deliberately generous: they exist to stop one
# non-terminating case from taking the whole run down, not to measure anything.
# A timeout is reported as an adapter error, never as agreement.
SIM_TIMEOUT_S = 120
REPLAY_TIMEOUT_S = 60


# ── sim ──────────────────────────────────────────────────────────────────────


# Set by the build step (`--rewind-bin`), which passes the artifact it just
# built. A path handed in by the build system cannot be stale; a path discovered
# on disk can, and a stale binary silently testing yesterday's engine is the
# exact failure mode the smoke suite spent months in. Discovery is the fallback
# for running the script by hand.
REWIND_BIN: Path | None = None


def _rewind_bin() -> Path:
    """The `rewind` CLI, built by `zig build rewind`."""
    if REWIND_BIN is not None:
        return REWIND_BIN
    candidate = REPO_ROOT / "zig-out" / "bin" / "rewind"
    if candidate.exists():
        return candidate
    found = shutil.which("rewind")
    if found:
        return Path(found)
    raise EngineUnavailable(
        "the `rewind` CLI is not built — run `zig build rewind`"
    )


def run_sim(world: dict, source_dir: Path, *, compared_headers) -> Outcome:
    binary = _rewind_bin()
    with tempfile.NamedTemporaryFile(
        "w", suffix=".json", delete=False, encoding="utf-8"
    ) as fh:
        json.dump(world, fh)
        world_path = Path(fh.name)
    try:
        proc = subprocess.run(
            [str(binary), "sim", str(world_path), "--source-dir", str(source_dir)],
            capture_output=True,
            text=True,
            timeout=SIM_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        # A hung engine is an outcome the suite has to REPORT, not an exception
        # that takes the whole run down with it — one non-terminating case would
        # otherwise hide the results of every case after it.
        raise AdapterError(
            f"`rewind sim` did not terminate within {SIM_TIMEOUT_S}s — the "
            f"handler may not terminate on this engine"
        )
    finally:
        world_path.unlink(missing_ok=True)

    # The sim writes the bundle to stdout and diagnostics to stderr. A non-zero
    # exit with no bundle is an adapter error; a bundle that reports a thrown
    # handler is a legitimate OUTCOME and must survive to the comparison — prod
    # turns that into a 500, and the two agreeing is exactly what the
    # thrown-handler rollback invariant needs to assert.
    stdout = proc.stdout.strip()
    if not stdout:
        raise AdapterError(
            f"`rewind sim` produced no bundle (exit {proc.returncode}): "
            f"{proc.stderr.strip()[:500]}"
        )
    try:
        bundle = json.loads(stdout)
    except json.JSONDecodeError as e:
        raise AdapterError(f"`rewind sim` output is not JSON: {e}: {stdout[:300]}")
    return from_sim_bundle(bundle, compared_headers=compared_headers)


# ── prod (rove#417) ──────────────────────────────────────────────────────────


# One cluster for the WHOLE corpus, not one per case. Bring-up is by far the
# most expensive thing this suite does, and it is per-PROCESS work, not
# per-case: amortizing it is the difference between a lane that can run the
# corpus and one that can run a handful of cases. Torn down at exit.
_CLUSTER = None
_DEPLOYED: dict[str, str] = {}  # case source_dir → tenant already deployed


def _cluster():
    global _CLUSTER
    if _CLUSTER is not None:
        return _CLUSTER
    try:
        sys.path.insert(0, str(REPO_ROOT / "scripts" / "smoke"))
        from smoke_lib_v2 import V2Cluster
    except Exception as e:  # noqa: BLE001
        raise EngineUnavailable(f"the V2 smoke harness is not importable: {e}")

    if not os.environ.get("AWS_ACCESS_KEY_ID") or not os.environ.get("S3_ENDPOINT"):
        # V2 has no filesystem blob backend — every node must read the same
        # content-addressed store, so S3 is mandatory even single-node.
        raise EngineUnavailable(
            "no S3 credentials in the environment — run `set -a; . ./.env; set +a` "
            "first (the prod engine needs a real blob store)"
        )
    for exe in ("rewind-worker", "rewind-cp", "rewind-front", "rewind-logs", "rewind-ops"):
        if not (REPO_ROOT / "zig-out" / "bin" / exe).exists():
            raise EngineUnavailable(f"{exe} is not built — run `zig build {exe}`")

    cluster = V2Cluster.spawn("conf", nodes=1)
    cluster.__enter__()
    cluster.spawn_log_server(poll_interval_ms=200)
    atexit.register(lambda: cluster.__exit__(None, None, None))
    _CLUSTER = cluster
    return cluster


def _tenant_for(source_dir: Path) -> str:
    """One tenant PER CASE. Sharing a tenant would let one case's kv writes be
    read by the next, which is the difference between a corpus of independent
    behaviors and a corpus whose results depend on ordering."""
    name = "".join(ch for ch in source_dir.name.lower() if ch.isalnum())[:20]
    return f"c{name}" if name else "ccase"


def _manifest_specs(source_dir: Path) -> list[str]:
    """The `@rewind/*` specifiers a case's `manifest.json` declares.

    A manifest is not itself deployable — the customer CLI READS it and resolves
    the declared dependencies into the deploy, rather than shipping the file
    (`classify` in `src/cli/common.zig` picks up only `.mjs`). Mirroring that is
    what lets a case that imports a first-party package deploy at all.
    """
    manifest = source_dir / "manifest.json"
    if not manifest.exists():
        return []
    try:
        doc = json.loads(manifest.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return []
    deps = doc.get("dependencies") or doc.get("imports") or {}
    if isinstance(deps, dict):
        return [s for s in deps if str(s).startswith("@rewind/")]
    if isinstance(deps, list):
        return [str(s) for s in deps if str(s).startswith("@rewind/")]
    return []


def _deploy_case(cluster, tenant: str, source_dir: Path) -> None:
    """Deploy a case's tree, resolving first-party packages the way the CLI does."""
    sources = _collect_sources(source_dir)
    specs = _manifest_specs(source_dir)
    if not specs:
        cluster.deploy_handlers(tenant, sources)
        return
    packages, app_imports = cluster.firstparty_packages(specs)
    cluster.deploy_with_packages(tenant, sources, packages, app_imports)


def _provision_patiently(cluster, tenant: str, timeout_s: float = 180.0):
    """Provision, waiting out the platform's own creation-velocity gate.

    The CP rate-limits tenant creation — a burst of 10 then one per 30s — which
    is a deliberate abuse control, not a test-harness inconvenience, and it has
    no env knob. A corpus that provisions one tenant per case therefore runs
    into it almost immediately: a 57-case sweep is bounded at roughly half an
    hour by this alone.

    Waiting is the honest response. Sharing tenants to dodge the limit would let
    one case's kv writes be read by the next, trading a slow lane for a corpus
    whose results depend on ordering.
    """
    deadline = time.time() + timeout_s
    last = None
    while True:
        last = cluster.provision(tenant)
        if last.status != 429:
            return last
        if time.time() >= deadline:
            return last
        time.sleep(5.0)


def _await_deployment(cluster, tenant: str, timeout_s: float = 40.0) -> None:
    """Block until the release is actually serving.

    A release is applied asynchronously — the worker fetches the manifest and
    bytecode from S3 and swaps a snapshot — so a request driven immediately
    after `deploy_handlers` gets `503 no deployment for this tenant`. Waiting on
    a specific STATUS would be wrong here: a conformance case is free to expect
    a 500 or a 404, and this adapter must not assume the case's outcome. So wait
    for the deployment to exist, whatever it then answers.
    """
    deadline = time.time() + timeout_s
    last = None
    while time.time() < deadline:
        r = cluster.request(tenant, "/", timeout=20.0)
        last = r
        if not (r.status == 503 and "no deployment" in (r.body or "")):
            return
        time.sleep(0.4)
    raise AdapterError(
        f"{tenant}: deployment never became live within {timeout_s:.0f}s "
        f"(last: {getattr(last, 'status', '?')} {str(getattr(last, 'body', ''))[:120]!r})"
    )


def _record_for(cluster, tenant: str, method: str, path: str, timeout_s: float = 60.0):
    """The newest log record matching this request.

    Correlated by (method, path) and recency rather than by request id: no
    request-id header comes back through the front door, and the runner drives
    one request at a time, so the newest match is the one just driven. A
    parallel runner would need a real correlator first.
    """
    want_path = path.split("?", 1)[0]
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        resp = cluster.log_get(f"{tenant}/list?limit=50", timeout=15.0)
        if resp.status == 200:
            try:
                records = json.loads(resp.body).get("records", [])
            except json.JSONDecodeError:
                records = []
            hits = [
                r
                for r in records
                if (r.get("path") or "").split("?", 1)[0] == want_path
                and (r.get("method") or "GET") == method
            ]
            if hits:
                hits.sort(key=lambda r: int(r.get("received_ns") or 0))
                rid = hits[-1].get("request_id")
                full = cluster.log_get(f"{tenant}/show/{rid}", timeout=15.0)
                if full.status == 200:
                    body = json.loads(full.body)
                    return body.get("record", body)
        time.sleep(1.0)
    return None


def run_prod(world: dict, source_dir: Path, *, compared_headers) -> Outcome:
    cluster = _cluster()
    tenant = _tenant_for(source_dir)

    if _DEPLOYED.get(str(source_dir)) != tenant:
        r = _provision_patiently(cluster, tenant)
        if r.status not in (200, 409):
            raise AdapterError(f"provision {tenant} → {r.status}: {r.body[:200]}")
        try:
            _deploy_case(cluster, tenant, source_dir)
        except RuntimeError as e:
            # A bundle prod refuses to compile is a real outcome for the case,
            # but not one this adapter can normalize into a response — surface
            # it as an error rather than an empty comparison.
            raise AdapterError(f"deploy to {tenant} failed: {e}")
        _await_deployment(cluster, tenant)
        _DEPLOYED[str(source_dir)] = tenant

    req = world.get("request") or {}
    method = req.get("method", "GET")
    path = req.get("path", "/")
    body = req.get("body")
    if body is not None and not isinstance(body, str):
        body = json.dumps(body)
    headers = {str(k): str(v) for k, v in (req.get("headers") or {}).items()}

    resp = cluster.request(
        tenant, path, method=method, data=body, headers=headers or None, timeout=45.0
    )
    return from_prod_response(
        resp,
        record=_record_for(cluster, tenant, method, path),
        compared_headers=compared_headers,
    )


# ── replay (rove#418) ────────────────────────────────────────────────────────


def _apps_dir() -> Path:
    """The rewind-apps checkout holding the replay porcelain (rtap /
    request-replay / qjs_arena_wasm). `$REWIND_APPS_DIR` is the smoke harness's
    convention; honour it rather than inventing a second one."""
    env = os.environ.get("REWIND_APPS_DIR")
    if env and (Path(env) / "replay" / "_static" / "qjs_arena_wasm.js").exists():
        return Path(env)
    raise EngineUnavailable(
        "REWIND_APPS_DIR is not set to a rewind-apps checkout — the replay "
        "porcelain lives there (private repo)"
    )


# The case's handler sources, shared by the replay and prod adapters — the two
# engines that need the tree handed to them rather than read from disk. `_tests/`
# is the sim's own assertion tree, not handler code: shipping it would deploy
# modules no other engine loads.
_SOURCE_SUFFIXES = (".mjs", ".js")


def _collect_sources(source_dir: Path) -> dict:
    out = {}
    for p in sorted(source_dir.rglob("*")):
        if not p.is_file() or p.suffix not in _SOURCE_SUFFIXES:
            continue
        rel = p.relative_to(source_dir)
        if "_tests" in rel.parts:
            continue
        out[str(rel)] = p.read_text(encoding="utf-8")
    return out


def run_replay(world: dict, source_dir: Path, *, compared_headers) -> Outcome:
    apps = _apps_dir()
    if not shutil.which("node"):
        raise EngineUnavailable("node is not on PATH — it drives the WASM arena")

    job = {
        "apps_dir": str(apps),
        "world": world,
        "sources": _collect_sources(source_dir),
    }
    with tempfile.NamedTemporaryFile(
        "w", suffix=".json", delete=False, encoding="utf-8"
    ) as fh:
        json.dump(job, fh)
        job_path = Path(fh.name)
    try:
        proc = subprocess.run(
            ["node", str(Path(__file__).resolve().parent / "replay_driver.mjs"), str(job_path)],
            capture_output=True,
            text=True,
            timeout=REPLAY_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        raise AdapterError(
            f"the replay driver did not terminate within {REPLAY_TIMEOUT_S}s — "
            f"the WASM arena has no CPU budget, so a handler the sim bounds with "
            f"a 504 runs forever here (rove#443)"
        )
    finally:
        job_path.unlink(missing_ok=True)

    # Exit 3/4 are the driver's own preconditions (no porcelain, no entry
    # source) — not an engine result, so they are unavailability rather than a
    # failed comparison.
    if proc.returncode == 3:
        raise EngineUnavailable(proc.stderr.strip() or "replay porcelain missing")
    if proc.returncode not in (0, 4):
        raise AdapterError(
            f"replay driver exited {proc.returncode}: {proc.stderr.strip()[:500]}"
        )
    if not proc.stdout.strip():
        raise AdapterError(
            f"replay driver produced no output: {proc.stderr.strip()[:500]}"
        )
    try:
        res = json.loads(proc.stdout.strip())
    except json.JSONDecodeError as e:
        raise AdapterError(f"replay driver output is not JSON: {e}")

    return from_replay_result(res, stderr=proc.stderr)


ADAPTERS = {
    "sim": run_sim,
    "prod": run_prod,
    "replay": run_replay,
}

# The engines the cheap lane can run — no cluster, no S3, no ports. `zig build
# conformance` runs exactly these; the cluster lane (rove#420) adds `prod`.
CHEAP_LANE = ("sim", "replay")
