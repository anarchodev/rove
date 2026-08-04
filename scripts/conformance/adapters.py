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
- `prod`   — the worker on a live V2Cluster (rove#417).
- `replay` — the browser WASM arena, driven headless from node (rove#418).

The prod and replay adapters are declared here and raise `EngineUnavailable`.
They are NOT omitted: a case that names an engine must visibly not-run on it,
because "did not run" and "ran and agreed" have to stay distinguishable — that
distinction is what makes a three-way disagreement localize a fault instead of
merely reporting one.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from outcome import Outcome, from_sim_bundle

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


class EngineUnavailable(Exception):
    """The engine cannot run this world at all — no adapter, no binary, or the
    case declares itself unrunnable there. Never a comparison result."""


class AdapterError(Exception):
    """The engine ran and failed in a way that is not a behavioral outcome — a
    crashed binary, unparseable output. A real failure, not a divergence."""


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
            timeout=120,
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


def run_replay(world: dict, source_dir: Path, *, compared_headers) -> Outcome:
    raise EngineUnavailable(
        "replay adapter not built — rove#418 (headless WASM arena over a "
        "captured case). Note this engine re-executes a RECORDED world, so it "
        "composes with the prod adapter rather than standing alone."
    )


ADAPTERS = {
    "sim": run_sim,
    "prod": run_prod,
    "replay": run_replay,
}

# The engines the cheap lane can run — no cluster, no S3, no ports. `zig build
# conformance` runs exactly these; the cluster lane (rove#420) adds `prod`.
CHEAP_LANE = ("sim", "replay")
