#!/usr/bin/env python3
"""Cross-store reads are RECORDED — proven against a REAL capture, not a fixture.

`platform.root.get/prefix` and `platform.scope(id).kv.get/prefix` return data to
the handler, so they are inputs under the determinism boundary and must be taped
or the activation is unreplayable. They are the first input class that leaves
the activation's own tenant (a cross-raft-group read), so the kv channel — which
is tenant-implicit — carries the STORE as a key prefix: `__rove_store/r/{key}`
for the platform root store, `__rove_store/i/{id}/{key}` for another instance's.

Why a smoke and not just a unit test: `docs/architecture/replay-and-sim.md` §5
records the exact trap this guards. A programmatic fixture passed while a REAL
recording refuted the assumption baked into it — the tapes were empty at the
recording layer. So this asserts against a live cut on the standing `__admin__`
deploy app, whose `cutStamp` does a real `platform.scope(t).kv.prefix` over the
target's workspace.

Three halves, all against real records:
  1. RECORDING — the pulled record's kv tape carries namespaced cross-store
     rows, and nothing un-namespaced leaked into the tenant's own keyspace.
  2. TRANSCODE — `rewind export-fixture` carries them into the world's kv map,
     which is what the offline `platform.*` facade resolves against.
  3. REPLAY — a captured `__admin__` world actually RUNS and reproduces the
     cross-store values it read live. Before the captured-world exemption, every
     admin replay threw "platform is only available on the admin handler" before
     reaching a single taped read: the sim's fail-closed gate is armed by a
     scenario key that no capture carries. Steps 1-2 can pass while 3 fails,
     which is why the reproduction is asserted rather than "it did not throw".

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402
from admin_deploy_smoke_v2 import deploy_post  # noqa: E402
from replay_matrix_smoke_v2 import _REMAP  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
REWIND_BIN = REPO_ROOT / "zig-out" / "bin" / "rewind"

TARGET = "crossread"
NS = "__rove_store/"
HANDLER_SRC = 'export default function () { return "cross-read-ok\\n"; }'

# The replay subject (rove#411): an ADMIN handler whose entire observable output
# is cross-store reads. If the captured world replays, every link in the chain
# holds — the reads were taped under the namespaced key, export-fixture carried
# them into the world's map, and the offline facade resolved them there.
ADMIN_PROBE_SRC = """
export default function () {
  const root = platform.root.get("probe/root");
  const scoped = platform.scope("REPLACE_TARGET").kv.get("probe/scoped");
  const rows = platform.scope("REPLACE_TARGET").kv.prefix("probe/p/", "", 10)
    .map(function (e) { return e.key + "=" + e.value; }).join(",");
  const missing = String(platform.root.get("probe/absent"));
  kv.set("probe/seen", root + "|" + scoped + "|" + rows + "|" + missing);
  response.status = 200;
  return root + "|" + scoped + "|" + rows + "|" + missing;
}
"""


def find_record_with_store_reads(c, tries=60):
    """The `__admin__` record whose kv tape carries cross-store rows. Which
    activation performs the scan is an implementation detail of the deploy app,
    so select on the PROPERTY rather than on a kind."""
    for _ in range(tries):
        lr = c.log_get("__admin__/list?limit=50")
        recs = json.loads(lr.body).get("records", []) if lr.status == 200 else []
        for x in recs:
            rid = x.get("request_id")
            if not rid:
                continue
            sr = c.log_get(f"__admin__/show/{rid}")
            if sr.status != 200:
                continue
            try:
                r = json.loads(sr.body)["record"]
            except (json.JSONDecodeError, KeyError):
                continue
            if _kv_keys(r):
                return r
        time.sleep(0.5)
    return None


def _kv_keys(rec):
    """Decode the record's kv tape to its keys via `rewind export-fixture` —
    the same transcode `pull` runs online, so this reads the tape exactly the
    way replay will."""
    world = transcode(rec)
    if world is None:
        return []
    return sorted((world.get("kv") or {}).keys())


def transcode(rec, source=HANDLER_SRC):
    tapes = rec.get("tapes", {})
    fixture = {
        "request_id": rec.get("request_id", ""), "tenant": "__admin__",
        "activation": rec.get("activation", "inbound"), "entry": "index.mjs",
        "request": {"method": rec.get("method", "GET"), "path": rec.get("path", "/"),
                    "host": rec.get("host", "")},
        "recorded": {"status": rec.get("status", 0)},
        "seed": tapes.get("seed", "0"), "timestamp_ns": tapes.get("timestamp_ns", "0"),
        "tapes": {fx: tapes[rf] for rf, fx in _REMAP if tapes.get(rf)},
        "sources": [{"path": "index.mjs", "kind": "handler", "source": source}],
    }
    if tapes.get("export"):
        fixture["export"] = tapes["export"]
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(fixture, f)
        fx_path = f.name
    exp = subprocess.run([str(REWIND_BIN), "export-fixture", fx_path],
                         capture_output=True, text=True, timeout=30)
    if exp.returncode != 0:
        return None
    try:
        return json.loads(exp.stdout)
    except json.JSONDecodeError:
        return None


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("platformreads", nodes=1) as c:
        c.spawn_log_server()
        print("step 1: bootstrap the standing __admin__ deploy app + a target tenant")
        c._ensure_admin_app()
        r = c.provision(TARGET)
        check("provision target → 200", r.status == 200, f"got {r.status} {r.body!r}")

        print("step 2: a real deploy — cutStamp scans the target's workspace "
              "through platform.scope(t).kv.prefix")
        r = deploy_post(c, "reset", {"tenant": TARGET}, token=c.root_token)
        check("reset → 200", r.status == 200, f"got {r.status} {r.body!r}")
        r = deploy_post(c, "file", {"tenant": TARGET, "path": "index.mjs",
                                    "kind": "handler", "source": HANDLER_SRC},
                        token=c.root_token)
        check("stage index.mjs → 200", r.status == 200, f"got {r.status} {r.body!r}")
        r = deploy_post(c, "cut", {"tenant": TARGET}, token=c.root_token)
        check("cut → dep_id", r.status == 200 and '"ok":true' in r.body,
              f"got {r.status} {r.body!r}")

        print("step 3: the RECORDING half — the real record's kv tape carries "
              "namespaced cross-store rows")
        rec = find_record_with_store_reads(c)
        check("an __admin__ record carries cross-store reads", rec is not None,
              "" if rec is not None else
              "no record with __rove_store/ keys — the reads went untaped")
        if rec is None:
            print("\nFAIL platform-reads replay smoke (v2)")
            return 1

        keys = _kv_keys(rec)
        scoped = [k for k in keys if k.startswith(f"{NS}i/{TARGET}/")]
        check("scoped rows land under __rove_store/i/{target}/", len(scoped) > 0,
              f"keys={keys[:8]}")
        # The whole point of the namespace: a cross-store row must never be
        # indistinguishable from one of the dispatching tenant's own keys.
        # `__admin__`'s OWN reads are legitimately un-namespaced, so the precise
        # assertion is that no row the scan returned shows up bare.
        unnamespaced = [k for k in keys if not k.startswith(NS)]
        bare_rows = [k for k in unnamespaced if k.startswith("_workspace/")]
        check("no cross-store row leaked into __admin__'s own keyspace",
              not bare_rows, f"bare={bare_rows[:8]} (all unnamespaced={unnamespaced[:8]})")
        # The rows are the target's workspace entries the deploy app scanned.
        check("the scanned workspace rows are present",
              any(k.startswith(f"{NS}i/{TARGET}/_workspace/") for k in scoped),
              f"scoped={scoped[:8]}")

        print("step 4: the TRANSCODE half — export-fixture carries them into "
              "the world the offline facade resolves against")
        world = transcode(rec)
        check("export-fixture produced a world", world is not None)
        if world is not None:
            wkv = world.get("kv") or {}
            check("the world's kv map is keyed the way the facade scans",
                  any(k.startswith(f"{NS}i/{TARGET}/_workspace/") for k in wkv),
                  f"world kv keys={sorted(wkv)[:8]}")

        # ── the REPLAY half (rove#411) ──
        #
        # Steps 3-4 prove the reads are recorded and transcode. They do not
        # prove a captured admin world RUNS: before the gate exemption, every
        # admin replay threw "platform is only available on the admin handler"
        # before reaching a single taped read, because the sim's fail-closed
        # gate is armed by a scenario key no capture carries.
        print("step 5: a captured __admin__ world actually REPLAYS")
        probe_src = ADMIN_PROBE_SRC.replace("REPLACE_TARGET", TARGET)
        c.admin_kv_put(TARGET, "probe/scoped", "S")
        c.admin_kv_put(TARGET, "probe/p/1", "one")
        c.admin_kv_put("__admin__", "_x", "")  # ensure the store exists
        # Our own bundle replaces the standing deploy app; nothing after this
        # step needs it.
        c.deploy_handlers("__admin__", {"index.mjs": probe_src})
        live = None
        deadline = time.time() + 45.0
        while time.time() < deadline:
            rr = c.request("__admin__", "/probe", timeout=15.0)
            if rr.status == 200 and "|" in rr.body:
                live = rr
                break
            time.sleep(1.0)
        check("the admin probe handler is live", live is not None,
              "" if live is not None else "deploy did not take")
        if live is None:
            print("\nFAIL platform-reads replay smoke (v2)")
            return 1
        # `probe/root` was never written, so it reads null both live and on
        # replay — the point is that the two AGREE, not what the value is.
        print(f"    live body: {live.body!r}")

        prec = None
        deadline = time.time() + 40.0
        while time.time() < deadline and prec is None:
            lr = c.log_get("__admin__/list?limit=50", timeout=15.0)
            if lr.status == 200:
                try:
                    recs = json.loads(lr.body).get("records", [])
                except json.JSONDecodeError:
                    recs = []
                # The readiness loop above polls /probe while the BAKED app is
                # still serving, and each 405 is a record at this path too.
                # Select the successful one, or the world gets transcoded from a
                # different handler's activation entirely.
                hit = next((x for x in recs
                            if "/probe" in (x.get("path") or "")
                            and int(x.get("status") or 0) == 200), None)
                if hit:
                    sr = c.log_get(f"__admin__/show/{hit.get('request_id')}", timeout=15.0)
                    if sr.status == 200:
                        prec = json.loads(sr.body).get("record")
            if prec is None:
                time.sleep(1.0)
        check("the probe request produced a record", prec is not None)
        if prec is None:
            print("\nFAIL platform-reads replay smoke (v2)")
            return 1

        world = transcode(prec, source=probe_src)
        check("export-fixture produced a world for the probe", world is not None)
        if world is not None:
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
                json.dump(world, f)
                wpath = f.name
            proc = subprocess.run([str(REWIND_BIN), "replay", wpath],
                                  capture_output=True, text=True, timeout=60)
            raw = (proc.stdout or "") + (proc.stderr or "")
            out = next((json.loads(ln) for ln in raw.splitlines()
                        if ln.strip().startswith("{") and '"effects"' in ln), None)
            replayed_ok = out is not None and not (out.get("error") or {}).get("message")
            check("the captured admin world replays without throwing", replayed_ok,
                  "" if replayed_ok else
                  (((out or {}).get("error") or {}).get("message") or raw[-300:]))
            if out is not None:
                # The handler's own kv write is the reproduction witness: its
                # value is built entirely from cross-store reads.
                w = next((e for e in (out.get("effects") or [])
                          if e.get("kind") == "write" and e.get("key") == "probe/seen"), None)
                check("...and reproduces the cross-store values it read live",
                      w is not None and w.get("value") == live.body.strip(),
                      f"replay={(w or {}).get('value')!r} live={live.body.strip()!r}")

    if failures:
        print(f"\nFAIL platform-reads replay smoke (v2): {len(failures)} check(s)")
        return 1
    print("\nPASS platform-reads replay smoke (v2): cross-store reads are recorded "
          "and transcode into the replay world, verified against a live capture")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
