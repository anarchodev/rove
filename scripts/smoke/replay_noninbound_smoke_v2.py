#!/usr/bin/env python3
"""Validate NON-INBOUND replay against a REAL recording (not a programmatic
fixture). This is the gate for `docs/architecture/replay-and-sim.md` §5 G1/G2:
proving the offline `rewind replay` driver faithfully re-runs a callback
(`fetch_chunk` → `onFetchResult`) activation captured by a live worker.

Flow:
  1. spawn a 1-node cluster + log server; provision + deploy `acme` (the
     onfetchbuf handler as the entry) + `wb` (a deterministic upstream body).
  2. drive `acme /?url=<wb>` — a non-streaming `on.fetch` (no `{to}`) whose
     whole body arrives in one `onFetchResult` activation (a `fetch_chunk`).
  3. query the log server for the `fetch_chunk` record (with inline tapes).
  4. reshape it into the fixture shape `rewind pull` writes (remapping the
     `*_tape_b64` fields), embedding the handler source.
  5. run the offline `./zig-out/bin/rewind replay` and assert: no divergence,
     and the replayed `onFetchResult` reproduces the recorded upstream body.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import base64
import json
import subprocess
import sys
import tempfile
import time
import urllib.parse as up
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, PUBLIC_SUFFIX  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants"
REWIND_BIN = REPO_ROOT / "zig-out" / "bin" / "rewind"

# A minimal buffered-on.fetch handler deployed AS THE ENTRY (index.mjs), so
# replay runs it directly (the fixture has no router). Its default does a
# buffered on.fetch (no {to}); the whole body resumes onFetchResult — the
# conventional export. Avoids TextDecoder (absent in the bare replay arena);
# returns a JSON summary that lets replay be asserted byte-for-byte.
HANDLER_SRC = r"""
export default function () {
  const q = request.query || "";
  let url = null;
  for (const p of q.split("&")) {
    const i = p.indexOf("=");
    if (i < 0) continue;
    if (decodeURIComponent(p.slice(0, i)) === "url") url = decodeURIComponent(p.slice(i + 1));
  }
  if (!url) { response.status = 400; return "no url"; }
  on.fetch(url);
  return next();
}
export function onFetchResult() {
  response.status = 200;
  const b = request.body;
  return JSON.stringify({
    len: b ? b.length : -1,
    status: request.status,
    ok: request.ok,
    done: request.done,
    fetchId: request.fetchId,
  });
}
"""
BULK_SRC = (DEMO / "wb" / "bulk" / "index.mjs").read_text()
EXPECTED_BODY = "".join(f"bulk-line-{i:02d}-zzz\n" for i in range(10))


def main() -> int:
    failures: list[str] = []

    def check(label: str, ok: bool, detail: str = "") -> None:
        print(f"  {'✓' if ok else '✗'} {label}" + (f"  — {detail}" if detail else ""))
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("replay-ni", nodes=1) as c:
        c.spawn_log_server()
        c.provision("acme")
        c.provision("wb")
        # Deploy each handler AS the entry module (index.mjs).
        c.deploy_handlers("acme", {"index.mjs": HANDLER_SRC})
        c.deploy_handlers("wb", {"index.mjs": BULK_SRC})

        r = c.wait_for_handler("wb", "/", want_status=200, want_body=EXPECTED_BODY,
                               timeout_s=25.0)
        check("wb upstream reachable + byte-exact", r.status == 200 and r.body == EXPECTED_BODY,
              f"status={r.status} len={len(r.body)}")
        if failures:
            print("\nFAILURES:", failures)
            return 1

        bulk_url = f"http://wb.{PUBLIC_SUFFIX}:{c.front_port}/"
        r = c.get("acme", f"/?url={up.quote(bulk_url)}", timeout=30.0)
        live = {}
        try:
            live = json.loads(r.body)
        except (json.JSONDecodeError, TypeError):
            pass
        check("live on.fetch → onFetchResult saw the 170B upstream body + status 200",
              r.status == 200 and live.get("len") == len(EXPECTED_BODY) and live.get("status") == 200,
              f"status={r.status} summary={live!r}")
        if failures:
            c.dump_node_log(grep=["fetch", "result", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        # ── find the fetch_chunk record ──
        # The /list summary omits `activation` (it's only in the full record), so
        # show each listed record and match on the full record's activation.
        rec = None
        seen: list[str] = []
        for _ in range(60):
            lr = c.log_get("acme/list?limit=50")
            recs = []
            if lr.status == 200:
                try:
                    recs = json.loads(lr.body).get("records", [])
                except json.JSONDecodeError:
                    recs = []
            for x in recs:
                rid = x.get("request_id")
                if not rid:
                    continue
                sr = c.log_get(f"acme/show/{rid}")
                if sr.status != 200:
                    continue
                try:
                    r_full = json.loads(sr.body)["record"]
                except (json.JSONDecodeError, KeyError):
                    continue
                act = r_full.get("activation", "")
                seen.append(act)
                if act == "fetch_chunk":
                    rec = r_full
                    break
            if rec is not None:
                break
            time.sleep(0.5)
        check("log server surfaced a fetch_chunk record with tapes", rec is not None,
              f"activations seen={sorted(set(seen))}" if rec is None else "")
        if rec is None:
            c.dump_node_log(grep=["flush", "batch", "s3", "fetch_chunk", "error"])
            print("\nFAILURES:", failures)
            return 1

        tapes = rec.get("tapes", {})

        # ── ground-truth diagnostics: where does the buffered fetch result live? ──
        # FINDING (2026-06-30): for a real buffered fetch, the readset tapes are
        # all empty; the fetch bytes ride `activation_bytes_b64` (→ request.body).
        # So faithful fetch_chunk replay must read activation_bytes, NOT
        # fetch_responses. See docs/architecture/replay-and-sim.md §5.
        def _declen(b64: str) -> int:
            try:
                return len(base64.b64decode(b64)) if b64 else 0
            except Exception:
                return -1
        def _decstr(b64: str, n: int = 60) -> str:
            try:
                return base64.b64decode(b64).decode("utf-8", "replace")[:n] if b64 else ""
            except Exception:
                return "<binary>"
        print("  · DIAG fetch_chunk record tape sizes:")
        for k in ("activation_bytes_b64", "fetch_responses_tape_b64",
                  "trigger_payload_tape_b64", "request_body_b64",
                  "request_reads_tape_b64", "kv_tape_b64"):
            print(f"      {k}: {_declen(tapes.get(k,''))}B")
        # The recording-side fix records the fetch event onto the fetch_responses
        # channel (inline bytes for ≤16 KB) — so a real fetch_chunk record now
        # carries its Msg, and offline replay can reconstruct it.
        check("fetch_chunk record now carries the fetch event (fetch_responses tape)",
              _declen(tapes.get("fetch_responses_tape_b64", "")) > 0,
              f"fetch_responses={_declen(tapes.get('fetch_responses_tape_b64',''))}B")
        print(f"      request_body decoded[:60]={_decstr(tapes.get('request_body_b64',''))!r}")
        print(f"      trigger_payload decoded[:80]={_decstr(tapes.get('trigger_payload_tape_b64',''),80)!r}")
        print(f"      recorded status={rec.get('status')} console={rec.get('console')!r}")

        # ── reshape the record → the pull fixture shape ──
        remap = [
            ("kv_tape_b64", "kv_b64"),
            ("request_reads_tape_b64", "request_reads_b64"),
            ("request_body_b64", "request_body_b64"),
            ("fetch_responses_tape_b64", "fetch_responses_b64"),
            ("trigger_payload_tape_b64", "trigger_payload_b64"),
        ]
        fx_tapes = {fx: tapes[rf] for rf, fx in remap if tapes.get(rf)}
        fixture = {
            "request_id": rec.get("request_id", ""),
            "tenant": "acme",
            "deployment_id": rec.get("deployment_id", ""),
            "activation": rec.get("activation", "fetch_chunk"),
            "entry": "index.mjs",
            "request": {
                "method": rec.get("method", "GET"),
                "path": rec.get("path", "/"),
                "host": rec.get("host", ""),
            },
            "recorded": {
                "status": rec.get("status", 0),
                "console": rec.get("console", ""),
                "exception": rec.get("exception", ""),
            },
            "seed": tapes.get("seed", "0"),
            "timestamp_ns": tapes.get("timestamp_ns", "0"),
            "tapes": fx_tapes,
            "sources": [{"path": "index.mjs", "kind": "handler", "source": HANDLER_SRC}],
        }

        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(fixture, f)
            fixture_path = f.name

        # ── run the offline replay driver ──
        proc = subprocess.run([str(REWIND_BIN), "replay", fixture_path],
                              capture_output=True, text=True, timeout=30)
        # `replay` prints the artifact to stderr (std.debug.print); tolerate both.
        raw = (proc.stdout or "") + (proc.stderr or "")
        art = None
        for line in raw.splitlines():
            line = line.strip()
            if line.startswith("{") and '"run_rc"' in line:
                try:
                    art = json.loads(line)
                    break
                except json.JSONDecodeError:
                    pass
        check("replay driver emitted an artifact", art is not None,
              raw[:300] if art is None else "")
        if art is None:
            print("\nFAILURES:", failures)
            return 1

        print(f"  · DIAG replay artifact: {json.dumps(art)[:400]}")

        # ── faithful replay: the recorded fetch result reproduces offline ──
        replay = art.get("replay") or {}
        summary = {}
        try:
            summary = json.loads(replay.get("result") or "{}")
        except (json.JSONDecodeError, TypeError):
            pass
        check("replay: no divergence (fetch result reconstructed from the tape)",
              art.get("divergence") is None, f"divergence={art.get('divergence')!r}")
        check("replay: no handler error", replay.get("error") is None,
              f"error={replay.get('error')!r}")
        check("replay: request.body = fetch result bytes (len 170)",
              summary.get("len") == len(EXPECTED_BODY), f"summary={summary!r}")
        check("replay: request.status = upstream 200 (flattened result surface)",
              summary.get("status") == 200, f"status={summary.get('status')!r}")
        check("replay: response.status 200",
              (replay.get("response") or {}).get("status") == 200)

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\n✅ non-inbound (fetch_chunk) replay validated against a REAL "
          "recording: the fetch event is taped and offline replay reproduces "
          "body + status.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
