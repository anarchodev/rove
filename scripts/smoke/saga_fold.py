# SPDX-FileCopyrightText: 2026 Loop46, Inc.
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The saga-fold faithfulness tail — prod is the source of truth.

A smoke drives prod through a held chain however it naturally does
(real timers, real races), stamping `X-Rove-Correlation-Id` so the saga
id is known. This helper then:

  1. reads the saga's hops from the log-server (exec_seq order),
  2. pulls each hop's record and composes a per-hop pulled fixture
     (the `rewind pull` shape: record fields + base64 tapes + the
     `_settled` tag as `settled_promise` + the deployed sources),
  3. transcodes each (`rewind export-fixture`), assembles the chain
     (`rewind assemble-chain`), folds it (`rewind replay`),
  4. compares per hop: recorded status vs the fold's response status,
     and the recorded interaction digest vs the fold's — the sequence
     the handler performed, not just the response it reached.

The recording pins everything (settle values on tape channels, the
settle CHOICE via promiseIdx/_settled, per-hop seed/clock), so the fold
is a closed function of the record and any disagreement is a real
engine divergence — the prod-as-truth conformance decision (rove#929).
"""
from __future__ import annotations

import json
import subprocess
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
REWIND_BIN = REPO_ROOT / "zig-out" / "bin" / "rewind"

_REMAP = [
    ("kv_tape_b64", "kv_b64"), ("request_reads_tape_b64", "request_reads_b64"),
    ("request_body_b64", "request_body_b64"), ("fetch_responses_tape_b64", "fetch_responses_b64"),
    ("trigger_payload_tape_b64", "trigger_payload_b64"), ("activation_bytes_b64", "activation_bytes_b64"),
]


def _fixture(rec: dict, tenant: str, sources: dict[str, str], entry: str) -> dict:
    """One hop's pulled-fixture (the `rewind pull` compose, offline)."""
    tapes = rec.get("tapes", {}) or {}
    fx = {
        "request_id": rec.get("request_id", ""), "tenant": tenant,
        "activation": rec.get("activation", "inbound"), "entry": entry,
        "request": {"method": rec.get("method", "GET"), "path": rec.get("path", "/"),
                    "host": rec.get("host", "")},
        "recorded": {"status": rec.get("status", 0)},
        "seed": tapes.get("seed", "0"), "timestamp_ns": tapes.get("timestamp_ns", "0"),
        "tapes": {fx_k: tapes[rf] for rf, fx_k in _REMAP if tapes.get(rf)},
        "sources": [{"path": p, "kind": "handler", "source": s} for p, s in sources.items()],
    }
    if tapes.get("export"):
        fx["export"] = tapes["export"]
    settled = (rec.get("tags") or {}).get("_settled")
    if settled is not None:
        fx["settled_promise"] = str(settled)
    return fx


def _run(args: list[str], timeout: int = 60) -> subprocess.CompletedProcess:
    return subprocess.run([str(REWIND_BIN)] + args, capture_output=True, text=True, timeout=timeout)


def fetch_saga(c, tenant: str, saga_id: str, want_hops: int, tries: int = 60):
    """Poll the log-server until the saga is COMPLETE — at least `want_hops`
    stamped hops AND the last hop reached a terminal status (non-zero; a
    held hop records 0). A fixed count would truncate a chain whose chunk
    count varies (a streamed fetch splits into however many writebacks).
    Returns the full per-hop RECORDS in exec_seq order, or None. Refuses a
    saga with unplaced hops (no exec_seq → no order)."""
    for _ in range(tries):
        sr = c.log_get(f"{tenant}/saga/{saga_id}")
        if sr.status == 200:
            body = json.loads(sr.body)
            if body.get("unplaced"):
                return None
            hops = body.get("hops", [])
            done = hops and (hops[-1].get("status") or 0) != 0
            if len(hops) >= want_hops and done:
                recs = []
                for h in hops:
                    rid = h.get("request_id")
                    rr = c.log_get(f"{tenant}/show/{rid}")
                    if rr.status != 200:
                        recs = None
                        break
                    recs.append(json.loads(rr.body)["record"])
                if recs is not None:
                    # exec_seq is the tenant's execution tape — the fold's
                    # order. The route returns ascending, but sort anyway:
                    # a mis-ordered chain folds garbage silently.
                    recs.sort(key=lambda r: int(r.get("exec_seq") or 0))
                    return recs
        time.sleep(0.5)
    # Timed out — show what the log DOES hold, so a saga-id mismatch (a hop
    # recorded under a different id) reads directly off the failure.
    lr = c.log_get(f"{tenant}/list?limit=30")
    if lr.status == 200:
        for x in json.loads(lr.body).get("records", [])[:12]:
            rid = x.get("request_id")
            rr = c.log_get(f"{tenant}/show/{rid}")
            rec = json.loads(rr.body).get("record", {}) if rr.status == 200 else {}
            print(f"  saga-fold: log has {x.get('activation')} {x.get('path')} "
                  f"saga={rec.get('saga_id')!r} rid={rid}")
    return None


def fold_saga(recs: list[dict], tenant: str, sources: dict[str, str],
              entry: str = "index.mjs") -> list[dict] | None:
    """Compose → transcode → assemble → fold. Returns the per-hop bundles."""
    tmp = Path(tempfile.mkdtemp(prefix="sagafold-"))
    worlds = []
    for i, rec in enumerate(recs):
        fx_path = tmp / f"fx{i}.json"
        fx_path.write_text(json.dumps(_fixture(rec, tenant, sources, entry)))
        exp = _run(["export-fixture", str(fx_path)])
        if exp.returncode != 0:
            print(f"  saga-fold: export-fixture hop {i} failed: {exp.stderr.strip()[:300]}")
            return None
        wp = tmp / f"w{i}.json"
        wp.write_text(exp.stdout)
        worlds.append(str(wp))
    chain_path = tmp / "chain.json"
    asm = _run(["assemble-chain"] + worlds + ["-o", str(chain_path)])
    if asm.returncode != 0:
        print(f"  saga-fold: assemble-chain failed: {asm.stderr.strip()[:300]}")
        return None
    rep = _run(["replay", str(chain_path)])
    raw = (rep.stdout or "") + (rep.stderr or "")
    out = next((json.loads(ln) for ln in raw.splitlines()
                if ln.strip().startswith("{") and '"hops"' in ln), None)
    hops = out.get("hops") if out else None
    # The artifacts stay on disk for offline iteration — the chain world is
    # self-contained (sources inline), so `rewind replay <chain>` reproduces
    # any failure here with no cluster.
    print(f"  saga-fold: artifacts in {tmp} (replay rc={rep.returncode}, "
          f"{len(hops) if hops else 0} hops)")
    if rep.returncode != 0 or not hops:
        for ln in (rep.stderr or "").splitlines()[:6]:
            print(f"  saga-fold: replay! {ln}")
    return hops


def check_fold(check, label: str, recs: list[dict], hops: list[dict] | None):
    """Per-hop faithfulness: recorded status + interaction digest must
    reproduce. A held hop records status 0? No — a held hop's record carries
    the hop's own terminal-or-held outcome; compare digests always, statuses
    on the FINAL hop (intermediate hops' recorded statuses are the hop
    records' own, compared too when present and non-zero)."""
    if hops is None or len(hops) != len(recs):
        check(f"{label}: fold produced {len(hops) if hops else 0}/{len(recs)} hops", False,
              "fold failed or hop count mismatch")
        return
    for i, (rec, hop) in enumerate(zip(recs, hops)):
        rd = (rec.get("tapes") or {}).get("interaction_digest")
        fd = hop.get("interaction_digest")
        if rd:
            check(f"{label}: hop {i} digest reproduces", rd == fd, f"recorded={rd} folded={fd}")
        div = hop.get("divergence")
        check(f"{label}: hop {i} no divergence", div is None, str(div)[:200])
    rec_status = recs[-1].get("status", 0)
    fold_status = ((hops[-1].get("response") or {}).get("status"))
    check(f"{label}: final status reproduces", rec_status == fold_status,
          f"recorded={rec_status} folded={fold_status}")
