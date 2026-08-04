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
- `prod`   — the worker on a live V2Cluster (rove#417), still a stub.

An adapter that cannot run raises `EngineUnavailable` rather than being omitted:
a case that names an engine must visibly not-run on it, because "did not run"
and "ran and agreed" have to stay distinguishable — that distinction is what
makes a three-way disagreement localize a fault instead of merely reporting
one.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from outcome import Outcome, from_replay_result, from_sim_bundle

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


def run_prod(world: dict, source_dir: Path, *, compared_headers) -> Outcome:
    raise EngineUnavailable(
        "prod adapter not built — rove#417 (V2Cluster.run_world: "
        "deploy → drive → observe → normalize)"
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


# Source files the replay engine is handed. `_tests/` is the sim's own
# assertion tree, not handler code: shipping it would put modules in the replay
# that no other engine loads.
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
