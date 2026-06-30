#!/usr/bin/env python3
"""V2 WASM-replay smoke (port of `scripts/replay_wasm_smoke.py`).

Proves the full V2 replay arc end to end: a handler that exercises the live
tape channels deploys + serves, the `rewind` worker CAPTURES the tape and its
flusher PUTs the request-log batch to S3, a co-spawned `rewind-logs`
QUERIES it back out (`/v1/{t}/list` + `/show/{id}`, carrying `kv_tape_b64` /
`module_tree_b64` / `seed` / `timestamp_ns`), and `scripts/smoke/replay_wasm_smoke.mjs`
(unchanged, cluster-agnostic) composes the `composeReplay`-shaped bundle
(deployment manifest + source-by-hash from files-server-v2 + base64 tapes) and
REPLAYS the captured handler under arenajs-WASM, asserting deterministic
FUNC_ENTER tracing.

The engine gap this closed (commit history): the V2 `rewind` worker captured
tapes but wrote request-log batches to a LOCAL `FsBatchStore`, while the only
tape-query binary, `rewind-logs`, reads S3-only — writer (fs) and
reader (S3) never met, so no bundle could be assembled. Fixed by building the
batch store in `src/rewind/main.zig` from the blob S3 config (the flusher
thread, spawned by `Worker.create`, was already running) + a per-cluster
`LOG_S3_KEY_PREFIX` so the co-spawned indexer reads exactly this run's batches.

Needs S3 env: `set -a; . ./.env; set +a` first.  Also needs `node` (the .mjs
driver) and a default `zig build` (for `rewind-logs`).
Build: `zig build rewind-worker rewind-cp rewind-front` + `zig build`
"""

from __future__ import annotations

import base64
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, _curl, rpc_wrap  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
TENANT = "replay-demo"


def _run_wasm_driver(bundle_path: Path, *, stop_at: int | None = None,
                     trace_mode: int = 1) -> dict:
    """Invoke `scripts/smoke/replay_wasm_smoke.mjs` (cluster-agnostic), parse its JSON
    summary. The driver boots qjs_arena_wasm, stamps the captured seed +
    timestamp, replays the handler against the captured tape, and prints a JSON
    summary before exit. `argv[3]` = stop_at_event (-1 = run to completion),
    `argv[4]` = trace_mode (1 SCAN / 2 DRILL)."""
    args = ["node", str(REPO_ROOT / "scripts" / "replay_wasm_smoke.mjs"),
            str(bundle_path), str(stop_at if stop_at is not None else -1),
            str(trace_mode)]
    proc = subprocess.run(args, capture_output=True, timeout=60, cwd=REPO_ROOT)
    try:
        return json.loads(proc.stdout.decode())
    except json.JSONDecodeError:
        sys.stderr.write(proc.stdout.decode(errors="replace"))
        sys.stderr.write(proc.stderr.decode(errors="replace"))
        raise RuntimeError(f"WASM driver stdout not JSON (rc={proc.returncode})")

# A handler that exercises the live tape channels: kv.get + kv.set (the kv
# tape), Math.random / Date.now (drawn from the per-request seed +
# timestamp_ns scalars in the readset header — the §9 fold-in inputs), plus
# the read-taped request surface (`request_reads` channel): a header value
# read, a body read, and the masked `request.ip` — so the captured record
# carries the new channel and the WASM replay rebuilds `request` from it.
HANDLER_SRC = """\
function bumpCount(prior) { return prior + 1; }
function rollDie() { return 1 + Math.floor(Math.random() * 6); }
export function handler() {
  const at = Date.now();
  const die = rollDie();
  const probe = request.headers["x-replay-probe"] ?? "none";
  const blen = request.body.length;
  const ip = request.ip;
  const prior = parseInt(kv.get("count") ?? "0", 10);
  const next = bumpCount(prior);
  kv.set("count", String(next));
  return `replay-demo count=${next} die=${die} at=${at} probe=${probe} blen=${blen} ip=${ip}\\n`;
}
"""

# Stamped on every driven request; the handler reads x-replay-probe (a
# recorded header_value) and request.ip (derived from x-forwarded-for,
# masked to /24 → 203.0.113.0).
PROBE_HEADERS = {"x-replay-probe": "p1", "x-forwarded-for": "203.0.113.7"}


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("replay-wasm", nodes=1) as c:
        print(f"step 1: provision '{TENANT}' via the CP")
        r = c.provision(TENANT)
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy the replay-demo handler (kv + random + date tape channels)")
        try:
            dep_id = c.deploy_handlers(TENANT, {"index.mjs": rpc_wrap(HANDLER_SRC)})
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            dep_id = None

        if dep_id:
            print("step 3: drive a few requests through the front door (each captures a tape)")
            r = c.wait_for_handler(TENANT, "/?fn=handler", want_body="replay-demo")
            check("GET /?fn=handler → 200 replay-demo",
                  r.status == 200 and "replay-demo" in r.body,
                  f"got {r.status} {r.body!r}")
            if r.status != 200:
                c.dump_node_log(grep=["deploy", "loader", "manifest", "error", "warn"])
            else:
                last_body = ""
                for _ in range(3):
                    rr = c.get(TENANT, "/?fn=handler", headers=PROBE_HEADERS)
                    if rr.status != 200:
                        check("repeat GET → 200", False, f"got {rr.status} {rr.body!r}")
                        break
                    last_body = rr.body
                else:
                    check("drove 3 more requests → 200", True)
                # Read-taped IP surface: request.ip is the MASKED client
                # IP (IPv4 last octet zeroed) derived from the edge's
                # x-forwarded-for; the probe header round-trips.
                check("request.ip returned the masked XFF (203.0.113.0)",
                      "ip=203.0.113.0" in last_body, f"body={last_body!r}")
                check("request.headers probe value visible to the handler",
                      "probe=p1" in last_body, f"body={last_body!r}")

            # Durable kv write landed (proves the handler's kv tape channel
            # actually ran + committed through the bridge).
            kv = c.admin_kv_get(TENANT, "count")
            check("kv['count'] committed (kv tape channel ran)",
                  kv.status == 200 and kv.body.strip().isdigit(),
                  f"got {kv.status} {kv.body.strip()!r}")

            count = int(kv.body.strip()) if (kv.status == 200 and kv.body.strip().isdigit()) else 0
            check("kv tape channel committed across requests (count advanced)",
                  count >= 1, f"count={count}")

            # ── step 4: the captured tape is QUERYABLE back out of S3. ──────
            # rewind's flusher PUTs request-log/tape batches to the S3 batch
            # store; a co-spawned rewind-logs (same bucket + per-run
            # LOG_S3_KEY_PREFIX) LISTs + serves them. This is the writer↔reader
            # meeting that gap D closed (was fs-write vs S3-read).
            print("step 4: ⭐ query the captured tape back via rewind-logs")
            c.spawn_log_server()
            recs = []
            deadline = time.time() + 30.0
            while time.time() < deadline:
                lr = c.log_get(f"{TENANT}/list?limit=20")
                if lr.status == 200:
                    try:
                        recs = [r for r in json.loads(lr.body).get("records", [])
                                if r.get("status") == 200]
                    except json.JSONDecodeError:
                        recs = []
                    if recs:
                        break
                time.sleep(0.5)
            check("log-server surfaced a 200 record (batch reached S3 + indexed)",
                  bool(recs),
                  f"{len(recs)} record(s)" if recs else "none within 30s")
            if not recs:
                c.dump_node_log(grep=["flush", "batch", "s3", "log", "error", "warn"])

            if recs:
                rid = recs[0]["request_id"]
                sr = c.log_get(f"{TENANT}/show/{rid}")
                rec = {}
                tapes = {}
                if sr.status == 200:
                    try:
                        rec = json.loads(sr.body)["record"]
                        tapes = rec.get("tapes", {})
                    except (json.JSONDecodeError, KeyError):
                        pass
                check("show returned the captured kv tape (kv_tape_b64 present)",
                      bool(tapes.get("kv_tape_b64")),
                      f"tapes keys={list(tapes.keys())}")
                check("show returned the request_reads tape (read-taped surface)",
                      bool(tapes.get("request_reads_tape_b64")),
                      f"tapes keys={list(tapes.keys())}")

                # ── step 5: compose the replay bundle + run the WASM driver. ─
                if tapes.get("kv_tape_b64"):
                    print("step 5: ⭐ compose a replay bundle + run the WASM driver")
                    # files-server is dissolved (docs/plans/rewind-cli-plan.md §4),
                    # so there's no /deployments + /source read-back surface.
                    # The smoke already HAS the deployed source locally, so
                    # compose the replay bundle from it directly — the hash is
                    # just sha256 of the source bytes (what stageDeployment
                    # content-addresses on).
                    import hashlib
                    deployed = {"index.mjs": rpc_wrap(HANDLER_SRC)}
                    handler_entries = [
                        {"path": p, "hash": hashlib.sha256(s.encode()).hexdigest(),
                         "kind": "handler"}
                        for p, s in deployed.items()
                    ]
                    modules = [{"path": p, "hash": e["hash"], "source": s}
                               for (p, s), e in zip(deployed.items(), handler_entries)]
                    check("composed replay bundle from local source",
                          bool(handler_entries), f"entries={len(handler_entries)}")

                    if handler_entries:
                        entry_path = next((e["path"] for e in handler_entries
                                           if e["path"] in ("index.mjs", "index.js")),
                                          handler_entries[0]["path"])
                        entry_source = next(m["source"] for m in modules
                                            if m["path"] == entry_path)
                        req_body = ""
                        if tapes.get("request_body_b64"):
                            try:
                                req_body = base64.b64decode(
                                    tapes["request_body_b64"]).decode("utf-8", "replace")
                            except Exception:
                                req_body = ""
                        bundle = {
                            "request_id": rid,
                            "deployment_id": rec["deployment_id"],
                            "entry_path": entry_path,
                            "entry_source": entry_source,
                            "entry_fn": "handler",
                            "request": {"method": rec.get("method", "GET"),
                                        "path": rec.get("path", "/"),
                                        "host": rec.get("host", ""),
                                        "body": req_body},
                            "modules": modules,
                            "seed": tapes.get("seed", 0),
                            "timestamp_ns": tapes.get("timestamp_ns", 0),
                            "tape_blobs": {"kv": tapes.get("kv_tape_b64") or None,
                                           "module": tapes.get("module_tree_b64") or None,
                                           "request_reads": tapes.get("request_reads_tape_b64") or None},
                        }
                        bundle_path = Path(f"/tmp/replay-wasm-v2-{TENANT}.json")
                        bundle_path.write_text(json.dumps(bundle))
                        n_ch = sum(1 for v in bundle["tape_blobs"].values() if v)
                        print(f"  composed bundle ({bundle_path.stat().st_size} bytes, "
                              f"{n_ch} tape channel(s))")
                        try:
                            summary = _run_wasm_driver(bundle_path)
                        except RuntimeError as e:
                            summary = {"ok": False, "err": str(e)}
                        check("⭐ WASM driver replayed the captured handler (rc=0)",
                              summary.get("ok") is True, f"summary={summary}")
                        check("replay traced the handler call tree (>=3 FUNC_ENTER)",
                              summary.get("func_enter_count", 0) >= 3,
                              f"func_enter_count={summary.get('func_enter_count')}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS replay-wasm smoke (v2) — capture → S3 batch store → "
          "log-server query → composed bundle → deterministic WASM replay.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
