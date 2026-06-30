#!/usr/bin/env python3
"""Smoke for the trigger system (beforePut, afterPut, afterDelete) — V2 port
on the `V2Cluster` harness (branch `v2`).

Provisions a `trig` tenant, deploys a trigger module + handler, then verifies:
  - afterPut maintains a reverse index
  - beforePut mutates the value (lowercases user_id)
  - beforePut can throw → handler catches Error{ code:'trigger_rejected' }
  - the rejected write rolls back (NOT in kv)
  - afterDelete cleans up using event.previousValue

V2 specifics (vs the V1 original):
  - Plaintext h2c through the FRONT door; no TLS / leader-direct / 503.
  - No OIDC operator session / files-server admin listKv: tenant kv reads go
    through the worker's move-secret-gated `/_system/v2-kv` via
    `c.admin_kv_get(tenant, key)`.
  - No `--dev-webhook-unsafe` (no outbound here at all).
  - Trigger module lives at `_triggers/users/sessions/index.mjs` (verbatim
    trigger JS from the V1 smoke).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

TENANT = "trig"

# Trigger module + handler verbatim from scripts/triggers_smoke.py (V1).
TRIGGER_SRC = '''export function beforePut(event) {
  const sess = JSON.parse(event.value);
  if (!sess.user_id) throw new Error("session missing user_id");
  return JSON.stringify({ ...sess, user_id: sess.user_id.toLowerCase() });
}
export function afterPut(event) {
  const sess = JSON.parse(event.value);
  const sid = event.key.split("/").pop();
  kv.set("users/by-session/" + sid, sess.user_id);
}
export function afterDelete(event) {
  if (event.previousValue) {
    const sess = JSON.parse(event.previousValue);
    const sid = event.key.split("/").pop();
    kv.delete("users/by-session/" + sid);
  }
}'''

HANDLER_SRC = '''export default function () {
  const path = request.path;
  if (path === "/create") {
    const body = JSON.parse(request.body);
    kv.set("users/sessions/" + body.sid, JSON.stringify({ user_id: body.user_id }));
    return { ok: true };
  }
  if (path === "/create-bad") {
    try {
      kv.set("users/sessions/bad", JSON.stringify({}));
      return { ok: false, note: "should not reach" };
    } catch (e) {
      return { ok: false, code: e.code, message: e.message };
    }
  }
  if (path === "/delete") {
    const body = JSON.parse(request.body);
    kv.delete("users/sessions/" + body.sid);
    return { ok: true };
  }
  return { ok: false, error: "unknown path" };
}'''


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    def kv_val(key: str) -> str:
        """Tenant kv read via the worker's move-secret-gated /_system/v2-kv.
        Returns the raw value, or '' when absent (404)."""
        r = c.admin_kv_get(TENANT, key)
        if r.status == 200:
            return r.body
        return ""

    with V2Cluster.spawn("triggers", nodes=1) as c:
        print(f"step 1: provision tenant '{TENANT}' via the CP")
        r = c.provision(TENANT)
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy trigger module + handler")
        try:
            dep_id = c.deploy_handlers(TENANT, {
                "index.mjs": HANDLER_SRC,
                "_triggers/users/sessions/index.mjs": TRIGGER_SRC,
            })
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            dep_id = None

        if not dep_id:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 3: wait for the deployment to load")
        # Drive the handler until it serves (the unknown-path branch 200s with
        # the trigger module loaded alongside).
        ready = c.wait_for_handler(TENANT, "/", want_status=200)
        check("handler loaded", ready.status == 200, f"got {ready.status} {ready.body!r}")
        if ready.status != 200:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "trigger",
                                  "resolve", "404", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 4: create session — afterPut reverse index + beforePut mutation")
        r = c.request(TENANT, "/create", method="POST",
                      headers={"Content-Type": "application/json"},
                      data='{"sid":"abc","user_id":"ALICE"}')
        check("POST /create → 200", r.status == 200, f"got {r.status} {r.body!r}")
        check("create body ok:true", '"ok":true' in r.body, f"got {r.body!r}")

        sess = kv_val("users/sessions/abc")
        check("session row present after /create", bool(sess), f"got {sess!r}")
        check("beforePut lowercased user_id", '"user_id":"alice"' in sess,
              f"got {sess!r}")

        indexed = kv_val("users/by-session/abc")
        check("afterPut built reverse index → alice", indexed == "alice",
              f"got {indexed!r}")

        print("step 5: beforePut rejection (throw → catchable trigger_rejected)")
        r = c.request(TENANT, "/create-bad", method="POST",
                      headers={"Content-Type": "application/json"}, data="{}")
        check("POST /create-bad → 200", r.status == 200, f"got {r.status} {r.body!r}")
        for needle in ['"code":"trigger_rejected"', "session missing user_id",
                       "_triggers/users/sessions/index.mjs"]:
            check(f"create-bad body contains {needle!r}", needle in r.body,
                  f"got {r.body!r}")

        bad_sess = kv_val("users/sessions/bad")
        check("rejected write NOT in kv (inner savepoint rolled back)",
              not bad_sess, f"leaked {bad_sess!r}")

        print("step 6: afterDelete cleanup via event.previousValue")
        r = c.request(TENANT, "/delete", method="POST",
                      headers={"Content-Type": "application/json"},
                      data='{"sid":"abc"}')
        check("POST /delete → 200", r.status == 200, f"got {r.status} {r.body!r}")
        check("session row gone after /delete", not kv_val("users/sessions/abc"),
              "session row survived /delete")
        check("reverse index gone after /delete", not kv_val("users/by-session/abc"),
              "reverse index survived /delete")

        if failures:
            c.dump_node_log(grep=["deploy", "loader", "trigger", "resolve",
                                  "404", "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS triggers smoke (v2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
