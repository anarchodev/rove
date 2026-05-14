#!/usr/bin/env python3
"""End-to-end smoke for the WASM replay path (replay-wasm-plan §8.1).

Spawns a 3-node cluster + files-server + log-server with the demo
seed manifest. Hits the acme tenant a few times so its kv handler
produces a captured log record with tape entries. Composes a replay
bundle JSON the same way `web/admin/api.js::composeReplay` would
(deployment manifest from files-server + source files by content
hash + base64 tape blobs from the log record). Hands the bundle to
`scripts/replay_wasm_smoke.mjs` which boots arenajs-WASM via Node,
runs the captured handler under SCAN-mode tracing, and prints a
JSON summary. The Python side asserts the summary looks plausible
(rc=0, non-zero events, non-zero output).

The WASM browser UI is not exercised here — this smoke validates
the wire format + WASM driver chain end-to-end against bytes from
a real capture, which is the concrete §8.1 milestone.
"""

from __future__ import annotations

import base64
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, CurlContext, curl, mint_jwt  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
PUBLIC_SUFFIX = "loop46.localhost"
TENANT_ID = "replay_demo"
TENANT_HOST = f"replay-demo.{PUBLIC_SUFFIX}"
TOKEN = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"


def _ls(jwt: str, url: str, *, timeout_s: float = 10.0) -> str:
    """Plain curl against log-server's HTTP/1 (or h2c) port."""
    args = [
        "curl", "-sS", "--http2-prior-knowledge", "--max-time", str(timeout_s),
        "-H", f"Authorization: Bearer {jwt}", url,
    ]
    return subprocess.run(args, capture_output=True, timeout=timeout_s + 5.0).stdout.decode()


def _run_wasm_driver(bundle_path: Path, *, stop_at: int | None = None, expect_throw: bool = False) -> dict:
    """Invoke scripts/replay_wasm_smoke.mjs, parse its JSON summary.

    The driver writes its summary JSON to stdout BEFORE process.exit,
    so we always try to parse it — a captured throw means the
    arena_run_module call returned -1 and the driver exits non-zero
    with `ok: false` in the summary. Callers that expect a throw
    pass `expect_throw=True`.
    """
    args = ["node", str(REPO_ROOT / "scripts" / "replay_wasm_smoke.mjs"), str(bundle_path)]
    if stop_at is not None:
        args.append(str(stop_at))
    proc = subprocess.run(args, capture_output=True, timeout=60, cwd=REPO_ROOT)
    try:
        summary = json.loads(proc.stdout.decode())
    except json.JSONDecodeError:
        sys.stderr.write(proc.stdout.decode(errors="replace"))
        sys.stderr.write(proc.stderr.decode(errors="replace"))
        sys.exit(f"FAIL WASM driver stdout was not JSON (rc={proc.returncode}, stop_at={stop_at})")
    if expect_throw:
        # rc=1 expected, summary.ok=false. Don't gate on returncode.
        return summary
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr.decode(errors="replace"))
        sys.exit(f"FAIL WASM driver exited {proc.returncode} (stop_at={stop_at}): {summary}")
    return summary


def main() -> int:
    cluster = Cluster.spawn(
        tag="replay-wasm-smoke",
        http_base=8260,
        raft_base=40360,
        files_port=8264,
        log_port=8263,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        seed_manifest=REPO_ROOT / "examples" / "loop46-demo-tenants.json",
    )
    with cluster as c:
        c.discover_leader()
        admin_origin = c.admin_origin()
        c.spawn_files_server(cors_origin=admin_origin, leader_url=admin_origin)
        c.spawn_log_server(cors_origin=admin_origin)
        c.mint_services_token()
        print(f"ok  cluster up: leader={c.addrs.http[c.leader_idx]} log={c.log_url()} files={c.files_url()}")

        cc = c.curl_ctx(TENANT_HOST)
        leader_origin = f"https://{TENANT_HOST}:{c.leader_port()}"

        # Drive a few requests through the demo handler. It exercises
        # every captured tape channel: kv.get + kv.set (kv), Date.now
        # (date), Math.random (math_random), crypto.getRandomValues
        # (crypto_random), and one local import (module).
        c.wait_for_handler(TENANT_ID, "/?fn=handler", expected_status=200, timeout_s=15.0)
        last_body = ""
        for _ in range(3):
            r = curl(cc, f"{leader_origin}/?fn=handler")
            if r.status != 200:
                sys.exit(f"FAIL {TENANT_ID} GET /?fn=handler: {r.status} {r.body[:200]}")
            last_body = r.body
        print(f"ok  drove 3 {TENANT_ID} requests — last response: {last_body.strip()!r}")

        # Mint a services JWT for log-server + files-server (both
        # accept the same secret per smoke_lib's setup).
        jwt = mint_jwt(c.services_jwt_secret, {"exp": int(time.time() * 1000) + 5 * 60 * 1000})

        # Poll log-server for the records.
        recs = []
        for _ in range(60):
            body = _ls(jwt, f"{c.log_url()}/v1/{TENANT_ID}/list?limit=20")
            try:
                d = json.loads(body)
            except json.JSONDecodeError:
                d = {}
            recs = [r for r in d.get("records", []) if r.get("status") == 200]
            if len(recs) >= 1:
                break
            time.sleep(0.5)
        if not recs:
            sys.exit(f"FAIL no {TENANT_ID} records surfaced in log-server")
        rec_summary = recs[0]
        rid = rec_summary["request_id"]
        print(f"ok  log-server surfaced {TENANT_ID} record {rid}")

        # Fetch the full record (carries the base64 tape fields).
        show_body = _ls(jwt, f"{c.log_url()}/v1/{TENANT_ID}/show/{rid}")
        rec = json.loads(show_body)["record"]
        tapes_field = rec.get("tapes", {})
        present = [
            ch for ch in ("kv_tape_b64", "date_tape_b64", "math_random_tape_b64",
                          "crypto_random_tape_b64", "module_tree_b64")
            if tapes_field.get(ch)
        ]
        if "kv_tape_b64" not in present:
            sys.exit(f"FAIL kv_tape_b64 missing from record: tapes keys={list(tapes_field.keys())}")
        print(f"ok  fetched full log record — tape channels present: {present}")

        # Fetch the historical deployment manifest by hex id.
        dep_id = rec["deployment_id"]
        dep_hex = f"{dep_id:016x}"
        mf_body = _ls(jwt, f"{c.files_url()}/{TENANT_ID}/deployments/{dep_hex}")
        manifest = json.loads(mf_body)
        entries = manifest.get("entries", [])
        handler_entries = [e for e in entries if e.get("kind") == "handler"]
        if not handler_entries:
            sys.exit(f"FAIL no handler entries in deployment {dep_hex}: {entries}")
        print(f"ok  manifest dep_id={dep_hex} has {len(handler_entries)} handler entry(ies)")

        # Fetch source for every handler entry (mirrors composeReplay
        # so multi-file imports resolve at replay time).
        modules = []
        for e in handler_entries:
            src_url = f"{c.files_url()}/{TENANT_ID}/source/{e['hash']}"
            args = [
                "curl", "-sS", "--http2-prior-knowledge", "--max-time", "10",
                "-H", f"Authorization: Bearer {jwt}", src_url,
            ]
            r = subprocess.run(args, capture_output=True, timeout=15.0)
            if r.returncode != 0:
                sys.exit(f"FAIL source fetch {e['path']}: rc={r.returncode}")
            modules.append({
                "path": e["path"],
                "hash": e["hash"],
                "source": r.stdout.decode(errors="replace"),
            })

        # Pick the entry handler (index.mjs / index.js, else the first).
        entry_path = None
        for e in handler_entries:
            if e["path"] in ("index.mjs", "index.js"):
                entry_path = e["path"]
                break
        if not entry_path:
            entry_path = handler_entries[0]["path"]
        entry_source = next((m["source"] for m in modules if m["path"] == entry_path), None)
        if not entry_source:
            sys.exit(f"FAIL no source for entry {entry_path}")

        # Compose the bundle. tape_blobs as base64 strings (the .mjs
        # driver decodes back to Uint8Array). Channel name mapping
        # matches buildTapesFromBlobs.
        def get_b64(key: str) -> str | None:
            return tapes_field.get(key) or None

        # Reconstruct the request object the handler reads. The
        # driver stamps globalThis.request before calling handler()
        # so handlers that read request.path / request.body don't
        # diverge from the captured execution.
        req_body = ""
        if tapes_field.get("request_body_b64"):
            try:
                req_body = base64.b64decode(tapes_field["request_body_b64"]).decode("utf-8", errors="replace")
            except Exception:
                req_body = ""
        bundle = {
            "request_id": rid,
            "deployment_id": dep_id,
            "entry_path": entry_path,
            "entry_source": entry_source,
            "entry_fn": "handler",
            "request": {
                "method": rec.get("method", "GET"),
                "path": rec.get("path", "/"),
                "host": rec.get("host", ""),
                "body": req_body,
            },
            "modules": modules,
            "tape_blobs": {
                "kv": get_b64("kv_tape_b64"),
                "date": get_b64("date_tape_b64"),
                "math_random": get_b64("math_random_tape_b64"),
                "crypto_random": get_b64("crypto_random_tape_b64"),
                # `module_tree_b64` is the wire-format tape for the
                # module channel; the WASM module loader treats it
                # the same as any other channel even though replay
                # resolves imports out of Module.module_sources.
                "module": get_b64("module_tree_b64"),
            },
        }
        bundle_path = Path("/tmp/replay-wasm-smoke-bundle.json")
        bundle_path.write_text(json.dumps(bundle))
        print(f"ok  composed bundle ({bundle_path.stat().st_size} bytes, "
              f"{sum(1 for v in bundle['tape_blobs'].values() if v)} tape channel(s))")

        # Pass 1: no stop — establish baseline + harvest the event log
        # so we can pick a meaningful stop point for pass 2.
        baseline = _run_wasm_driver(bundle_path)
        if not baseline.get("ok"):
            sys.exit(f"FAIL WASM rc={baseline['rc']} summary={baseline}")
        if baseline["func_enter_count"] < 3:
            sys.exit(f"FAIL want >=3 FUNC_ENTER events (module body + handler + inner call): {baseline}")
        if baseline["name_count"] < 2:
            sys.exit(f"FAIL want >=2 NAME entries (function + file atoms): {baseline}")
        # We exercised 4 channels in the original capture (kv, date,
        # math_random, crypto_random). Assert they all reached the
        # log record so the bundle composer has something to feed
        # into the WASM replay's tape readers.
        expected_channels = {"kv_tape_b64", "date_tape_b64", "math_random_tape_b64", "crypto_random_tape_b64"}
        missing = expected_channels - set(present)
        if missing:
            sys.exit(f"FAIL captured record missing channels: {missing}. Present: {present}")
        print(f"ok  WASM replay ran handler {entry_path}: "
              f"rc={baseline['rc']} events={baseline['event_count']} "
              f"enters={baseline['func_enter_count']} names={baseline['name_count']} "
              f"output_lines={baseline['output_lines']}")

        # Pass 2: stop at the FUNC_ENTER of bumpCount and inspect.
        # That point sits deep enough that handler has populated all
        # of its locals (salt, at, die, r, prior) and rollDie has
        # already run once (so totalRolls == 1). bumpCount's own
        # frame should carry the `n` arg matching `prior`.
        bump_event = next(
            (e for e in baseline["events"] if e.get("kind") == "enter" and e.get("name") == "bumpCount"),
            None,
        )
        if not bump_event:
            sys.exit(f"FAIL no bumpCount FUNC_ENTER in baseline events:\n{json.dumps(baseline['events'], indent=2)}")
        stop_idx = bump_event["idx"]
        print(f"ok  picked stop point: event #{stop_idx} = FUNC_ENTER bumpCount "
              f"at {bump_event['file']}:{bump_event['line']}")

        paused = _run_wasm_driver(bundle_path, stop_at=stop_idx)
        if not paused.get("ok"):
            sys.exit(f"FAIL paused-run rc={paused['rc']}: {paused}")
        snap = paused.get("snapshot")
        if not snap:
            sys.exit(f"FAIL no snapshot captured at stop_at={stop_idx}: {paused}")
        if not isinstance(snap, list) or len(snap) < 1:
            sys.exit(f"FAIL snapshot is not a non-empty frame array: {snap!r}")

        # Top-of-stack frame should be the function we stopped just
        # before entering. The stack walker emits frames top-down, so
        # snap[0] is bumpCount. Its single arg is named `prior`
        # (function bumpCount(prior) in the source), and it closes
        # over the module-level `totalCalls` — both should land in
        # `vars`. The merged-arg+local+closure shape is exactly what
        # §6 of replay-wasm-plan.md describes.
        top = snap[0]
        if top.get("func") != "bumpCount":
            sys.exit(f"FAIL snapshot[0].func != 'bumpCount':\n{json.dumps(snap, indent=2)}")
        top_vars = top.get("vars") or {}
        if "prior" not in top_vars:
            sys.exit(f"FAIL bumpCount frame missing arg 'prior': {top}")
        prior_at_call = top_vars["prior"]
        if not isinstance(prior_at_call, (int, float)):
            sys.exit(f"FAIL bumpCount arg 'prior' is not numeric: {top_vars!r}")
        # totalCalls is closed over for write (bumpCount does
        # `totalCalls++`). Before the function body runs, it should
        # still be 0 (bumpCount hasn't bumped yet at FUNC_ENTER).
        if top_vars.get("totalCalls") != 0:
            sys.exit(f"FAIL bumpCount.totalCalls expected 0 at entry: got {top_vars.get('totalCalls')!r}")
        print(f"ok  snapshot[0]: func=bumpCount prior={prior_at_call} totalCalls=0 at line {top.get('line')}")

        # Find handler's frame deeper in the stack and validate its
        # locals include the names the source uses.
        handler_frame = next((f for f in snap if f.get("func") == "handler"), None)
        if not handler_frame:
            sys.exit(f"FAIL no 'handler' frame in snapshot:\n{json.dumps(snap, indent=2)}")
        handler_vars = handler_frame.get("vars") or {}
        missing_vars = [v for v in ("salt", "at", "die", "r", "prior") if v not in handler_vars]
        if missing_vars:
            sys.exit(f"FAIL handler frame missing locals {missing_vars}: have {list(handler_vars.keys())}")
        if handler_vars["prior"] != prior_at_call:
            sys.exit(f"FAIL bumpCount(prior) ≠ handler's `prior`: {prior_at_call} vs {handler_vars['prior']}")
        print(f"ok  snapshot handler frame: prior={handler_vars['prior']} "
              f"salt={handler_vars['salt']!r} die={handler_vars['die']} "
              f"r≈{handler_vars['r']:.4f}")

        # Module-level `totalCalls` / `totalRolls` should be visible
        # via closure on the handler frame (closure-referenced names).
        # rollDie has fired once by this point → totalRolls == 1;
        # bumpCount hasn't entered yet → totalCalls == 0.
        if handler_vars.get("totalCalls") != 0:
            sys.exit(f"FAIL handler.totalCalls expected 0 at bumpCount entry: got {handler_vars.get('totalCalls')!r}")
        if handler_vars.get("totalRolls") != 1:
            sys.exit(f"FAIL handler.totalRolls expected 1 at bumpCount entry: got {handler_vars.get('totalRolls')!r}")
        print("ok  module-level closure vars on handler frame: totalCalls=0, totalRolls=1")

        # Pass 3: stepping. Same captured bundle, stop at three
        # consecutive call sites inside handler — fmtSalt, then
        # rollDie, then bumpCount — and verify the snapshot evolves
        # the way the source dictates. Each stop is a fresh
        # arena_run_module from the same tape; the orchestrator
        # plays the part of a "step into" user clicking forward.
        # This is the deterministic-rerun foundation §8.5 needs.
        step_targets = []
        for fn_name in ("fmtSalt", "rollDie", "bumpCount"):
            ev = next(
                (e for e in baseline["events"]
                 if e.get("kind") == "enter" and e.get("name") == fn_name),
                None,
            )
            if not ev:
                sys.exit(f"FAIL no FUNC_ENTER {fn_name} in baseline events")
            step_targets.append((fn_name, ev["idx"]))

        # Run each stop point and collect handler-frame vars at that
        # moment. The smoke asserts a specific evolution shape: which
        # locals are defined, what totalRolls is, etc.
        step_snapshots = []
        for fn_name, idx in step_targets:
            res = _run_wasm_driver(bundle_path, stop_at=idx)
            if not res.get("ok"):
                sys.exit(f"FAIL step stop_at={idx} rc={res['rc']}")
            snap_i = res.get("snapshot")
            if not snap_i:
                sys.exit(f"FAIL step stop_at={idx} no snapshot")
            hf = next((f for f in snap_i if f.get("func") == "handler"), None)
            if not hf:
                sys.exit(f"FAIL step stop_at={idx} no handler frame")
            step_snapshots.append((fn_name, idx, snap_i[0], hf.get("vars") or {}))

        # Assertions per stop point. The source layout is:
        #   const buf = new Uint8Array(4);
        #   crypto.getRandomValues(buf);
        #   const salt = fmtSalt(buf);          // ← step 1 stops just before
        #   const at = Date.now();
        #   const die = rollDie();              // ← step 2 stops just before
        #   const r = Math.random();
        #   const prior = parseInt(kv.get("count") ?? "0", 10);
        #   const next = bumpCount(prior);      // ← step 3 stops just before
        #
        # The §6 stop semantics ("before the opcode at cur_pc") means
        # at each FUNC_ENTER, every const/let declared on a prior line
        # in handler is already bound. Cross-checks verify that.

        # Step 1: at fmtSalt entry — buf is set but salt is not yet.
        # Module-level totalRolls is still 0 (rollDie hasn't run).
        fn1, idx1, top1, hv1 = step_snapshots[0]
        assert fn1 == "fmtSalt"
        if "buf" not in hv1:
            sys.exit(f"FAIL step1: handler.buf should be set at fmtSalt entry: {list(hv1.keys())}")
        # salt is declared on the SAME line as the fmtSalt call —
        # const salt = fmtSalt(buf). At the FUNC_ENTER for fmtSalt,
        # salt hasn't received the return value yet, so it should be
        # in TDZ ("[uninitialized]") OR simply absent from vars.
        # Both are acceptable; we just require it's not the eventual
        # string value.
        salt1 = hv1.get("salt")
        if isinstance(salt1, str) and len(salt1) == 8 and all(c in "0123456789abcdef" for c in salt1):
            sys.exit(f"FAIL step1: handler.salt looks already-resolved at fmtSalt entry: {salt1!r}")
        if hv1.get("totalRolls") != 0:
            sys.exit(f"FAIL step1: totalRolls expected 0 at fmtSalt entry: got {hv1.get('totalRolls')!r}")
        print(f"ok  step 1: stop at fmtSalt (event #{idx1}) — buf set, salt unresolved, totalRolls=0")

        # Step 2: at rollDie entry — fmtSalt has returned, so handler
        # has salt + at. die not yet set. totalRolls still 0.
        fn2, idx2, top2, hv2 = step_snapshots[1]
        assert fn2 == "rollDie"
        if "salt" not in hv2 or not isinstance(hv2["salt"], str) or len(hv2["salt"]) != 8:
            sys.exit(f"FAIL step2: handler.salt should be the 8-hex result at rollDie entry: {hv2.get('salt')!r}")
        if "at" not in hv2 or not isinstance(hv2["at"], (int, float)):
            sys.exit(f"FAIL step2: handler.at should be a number: {hv2.get('at')!r}")
        if hv2.get("totalRolls") != 0:
            sys.exit(f"FAIL step2: totalRolls expected 0 at rollDie entry: got {hv2.get('totalRolls')!r}")
        print(f"ok  step 2: stop at rollDie  (event #{idx2}) — salt={hv2['salt']!r}, at set, totalRolls=0")

        # Step 3: at bumpCount entry — rollDie has bumped totalRolls
        # to 1. handler has die set. totalCalls still 0. This is the
        # same point Pass 2 inspected, used here only to confirm the
        # stepping sequence converges.
        fn3, idx3, top3, hv3 = step_snapshots[2]
        assert fn3 == "bumpCount"
        if not isinstance(hv3.get("die"), (int, float)) or not (1 <= hv3["die"] <= 6):
            sys.exit(f"FAIL step3: handler.die should be 1..6: got {hv3.get('die')!r}")
        if hv3.get("totalRolls") != 1:
            sys.exit(f"FAIL step3: totalRolls expected 1 at bumpCount entry: got {hv3.get('totalRolls')!r}")
        if hv3.get("totalCalls") != 0:
            sys.exit(f"FAIL step3: totalCalls expected 0 at bumpCount entry: got {hv3.get('totalCalls')!r}")
        print(f"ok  step 3: stop at bumpCount (event #{idx3}) — die={hv3['die']}, totalRolls=1, totalCalls=0")

        # Sanity check: the three stops are strictly increasing
        # (we stepped FORWARD), and the same captured bundle
        # produced consistent values across all three reruns
        # (deterministic replay).
        if not (idx1 < idx2 < idx3):
            sys.exit(f"FAIL step indices not monotonically increasing: {idx1}, {idx2}, {idx3}")
        if hv2["salt"] != hv3["salt"]:
            sys.exit(f"FAIL salt differs across reruns: step2={hv2['salt']!r} vs step3={hv3['salt']!r}")
        if hv2["at"] != hv3["at"]:
            sys.exit(f"FAIL at differs across reruns: step2={hv2['at']} vs step3={hv3['at']}")
        print("ok  three stops, same bundle, deterministic — salt/at match across reruns")

        # ── Pass 4: THROW capture ──────────────────────────────────────
        # replay_demo's handler throws on request.path containing
        # "/throw". Drive that path once, fetch the 500'd record from
        # log-server, replay it in WASM, and assert a THROW event
        # surfaces with the right message.
        r = curl(cc, f"{leader_origin}/throw?fn=handler")
        if r.status != 500:
            sys.exit(f"FAIL /throw expected 500, got {r.status}: {r.body[:200]}")
        print(f"ok  drove /throw request — worker responded {r.status} as expected")

        throw_rec = None
        for _ in range(60):
            body = _ls(jwt, f"{c.log_url()}/v1/{TENANT_ID}/list?limit=20")
            try:
                d = json.loads(body)
            except json.JSONDecodeError:
                d = {}
            for rec_summary in d.get("records", []):
                # 500 + path that includes "/throw" identifies our request.
                if rec_summary.get("status") == 500 and "/throw" in (rec_summary.get("path") or ""):
                    throw_rec = rec_summary
                    break
            if throw_rec is not None:
                break
            time.sleep(0.5)
        if throw_rec is None:
            sys.exit("FAIL no 500/throw record surfaced in log-server")

        throw_rid = throw_rec["request_id"]
        throw_show = json.loads(_ls(jwt, f"{c.log_url()}/v1/{TENANT_ID}/show/{throw_rid}"))["record"]
        throw_tapes = throw_show.get("tapes", {})
        # The handler throws BEFORE crypto.getRandomValues / kv / etc.
        # so the throw record only has the date tape (Date.now() is
        # evaluated as part of the throw message). That date entry
        # MUST survive: worker_dispatch.zig::dispatchOnce now calls
        # captureTapes on the handler-throw path so replay re-consumes
        # the same captured timestamp.
        if not throw_tapes.get("date_tape_b64"):
            sys.exit(f"FAIL throw record missing date tape — worker is dropping fault-time tapes: keys={list(throw_tapes.keys())}")
        print(f"ok  throw record carries date_tape_b64 ({len(throw_tapes['date_tape_b64'])} b64 chars)")

        throw_req_body = ""
        if throw_tapes.get("request_body_b64"):
            try:
                throw_req_body = base64.b64decode(throw_tapes["request_body_b64"]).decode("utf-8", errors="replace")
            except Exception:
                throw_req_body = ""
        throw_bundle = {
            "request_id": throw_rid,
            "deployment_id": throw_show["deployment_id"],
            "entry_path": entry_path,
            "entry_source": entry_source,
            "entry_fn": "handler",
            "request": {
                "method": throw_show.get("method", "GET"),
                "path": throw_show.get("path", "/throw"),
                "host": throw_show.get("host", ""),
                "body": throw_req_body,
            },
            "modules": modules,
            "tape_blobs": {
                "kv": throw_tapes.get("kv_tape_b64") or None,
                "date": throw_tapes.get("date_tape_b64") or None,
                "math_random": throw_tapes.get("math_random_tape_b64") or None,
                "crypto_random": throw_tapes.get("crypto_random_tape_b64") or None,
                "module": throw_tapes.get("module_tree_b64") or None,
            },
        }
        throw_bundle_path = Path("/tmp/replay-wasm-smoke-throw-bundle.json")
        throw_bundle_path.write_text(json.dumps(throw_bundle))

        throw_summary = _run_wasm_driver(throw_bundle_path, expect_throw=True)
        if throw_summary.get("ok"):
            sys.exit(f"FAIL throw bundle should have rc != 0 in WASM: {throw_summary}")
        if throw_summary["throw_count"] < 1:
            sys.exit(f"FAIL no THROW events captured: {throw_summary}")
        throw_event = next((e for e in throw_summary["events"] if e.get("kind") == "throw"), None)
        if not throw_event:
            sys.exit(f"FAIL no throw entry in events log: {throw_summary['events']}")
        msg = throw_event.get("message") or ""
        if "intentional replay-demo throw" not in msg:
            sys.exit(f"FAIL throw message mismatch: {msg!r}")
        print(f"ok  WASM replay captured THROW at {throw_event['file']}:{throw_event['line']} — "
              f"message: {msg!r}")

        print()
        print("all replay-wasm smoke checks passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
