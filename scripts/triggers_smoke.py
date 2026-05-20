#!/usr/bin/env python3
"""Smoke for the trigger system (beforePut, afterPut, afterDelete).

Python port of `scripts/triggers_smoke.sh`. Signs up trigsmoke, deploys
a trigger module + handler, then verifies:
  - afterPut maintains a reverse index
  - beforePut can throw → handler catches Error{code:'trigger_rejected'}
  - the rejected write rolls back (not in kv)
  - afterDelete cleans up using event.previousValue
"""

from __future__ import annotations

import json
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl, expect_status  # noqa: E402

TOKEN = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
ADMIN_HOST = f"app.{SYSTEM_SUFFIX}"


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


OPERATOR_EMAIL = "operator@example.com"
# Operator OIDC session cookie, set in main() (Fork B — admin is a
# pure RP, no Bearer). kv_get reads it for the scoped admin call.
_OP: dict = {}


def kv_get(c: Cluster, cc, key: str) -> str:
    args = urllib.parse.quote(json.dumps([key, "", 100]))
    r = curl(
        cc, f"{c.admin_origin()}/?fn=listKv&args={args}",
        headers={
            "Cookie": _OP["cookie"],
            "X-Rove-Scope": "trigsmoke",
        },
    )
    doc = json.loads(r.body)
    for e in doc.get("entries", []):
        if e["key"] == key:
            return e["value"]
    return ""


def provision(c: Cluster, cc, name: str) -> None:
    """Create a test tenant via the operator OIDC session (Fork B)."""
    args = urllib.parse.quote(json.dumps([name]))
    r = curl(cc, f"{c.admin_origin()}/?fn=createInstance&args={args}",
             headers={"Cookie": _OP["cookie"]})
    if r.status not in (200, 201):
        sys.exit(f"FAIL createInstance {name}: {r.status} {r.body}")


def main() -> int:
    cluster = Cluster.spawn(
        tag="triggers-smoke",
        http_base=8265,
        raft_base=40365,
        files_port=8214,
        log_port=8213,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        admin_origin_per_node=True,
        # OIDC token-exchange + JWKS hops http.send to loopback IdP;
        # bypass SSRF gate.
        worker_extra_args=["--dev-webhook-unsafe"],
    )
    with cluster as c:
        c.discover_leader()
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        admin_origin = c.admin_origin()
        c.spawn_files_server(
            cors_origin=admin_origin, leader_url=admin_origin,
            extra_args=c.admin_oidc_kv(OPERATOR_EMAIL),
        )
        c.spawn_log_server(cors_origin=admin_origin)
        c.mint_services_token()

        cc = c.curl_ctx(f"auth.{SYSTEM_SUFFIX}", f"trigsmoke.{PUBLIC_SUFFIX}")
        tenant_origin = f"https://trigsmoke.{PUBLIC_SUFFIX}:{c.leader_port()}"

        # Wait for admin tenant.
        leader_log = Path(f"/tmp/triggers-smoke-worker-{c.leader_idx}.out")
        deadline = time.monotonic() + 15.0
        while time.monotonic() < deadline:
            if leader_log.exists():
                if "tenant __admin__ loaded deployment" in leader_log.read_text(errors="replace"):
                    break
            time.sleep(0.1)

        # RP-config-seeded + IdP readiness, then operator login →
        # createInstance (Fork B; createInstance only sets the routing
        # marker — no starter — so the put_file/release below is what
        # gives trigsmoke its first deployment).
        deadline = time.monotonic() + 20.0
        r = curl(cc, f"{admin_origin}/?fn=listInstance",
                 headers={"Origin": admin_origin})
        while time.monotonic() < deadline and r.status != 401:
            time.sleep(0.25)
            r = curl(cc, f"{admin_origin}/?fn=listInstance",
                     headers={"Origin": admin_origin})
        for _ in range(80):
            if curl(cc, c.auth_base() + "/login").status == 200:
                break
            time.sleep(0.25)
        _OP["cookie"] = c.oidc_login(cc, OPERATOR_EMAIL)
        provision(c, cc, "trigsmoke")
        print("ok  provisioned trigsmoke (operator OIDC session)")

        dep_id = c.put_file("trigsmoke", "_triggers/users/sessions/index.mjs", TRIGGER_SRC)
        c.release("trigsmoke", dep_id)
        dep_id = c.put_file("trigsmoke", "index.mjs", HANDLER_SRC)
        c.release("trigsmoke", dep_id)
        # Wait for the trigger + handler deploy to land. The deployment
        # has 2 handlers + 1 trigger.
        target = f"tenant trigsmoke loaded deployment {dep_id} (2 handler(s), 0 static(s), 1 trigger(s)"
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            if target in leader_log.read_text(errors="replace"):
                break
            time.sleep(0.1)
        print("ok  deployed trigger + handler")

        # 3. Create session — afterPut maintains reverse index.
        r = curl(
            cc, f"{tenant_origin}/create",
            method="POST",
            headers={"Content-Type": "application/json"},
            data='{"sid":"abc","user_id":"ALICE"}',
        )
        expect_status("POST /create", 200, r)
        if '"ok":true' not in r.body:
            sys.exit(f"FAIL create body: {r.body}")

        sess = kv_get(c, cc, "users/sessions/abc")
        if not sess:
            sys.exit("FAIL session row missing after /create")
        if '"user_id":"alice"' not in sess:
            sys.exit(f"FAIL beforePut didn't lowercase: {sess}")
        print("ok  afterPut maintained session row + beforePut mutated value")

        indexed = kv_get(c, cc, "users/by-session/abc")
        if indexed != "alice":
            sys.exit(f"FAIL reverse index missing or wrong: '{indexed}'")
        print("ok  afterPut built reverse index users/by-session/abc → alice")

        # 4. beforePut rejection.
        r = curl(
            cc, f"{tenant_origin}/create-bad",
            method="POST",
            headers={"Content-Type": "application/json"},
            data="{}",
        )
        expect_status("POST /create-bad", 200, r)
        for needle in ['"code":"trigger_rejected"', "session missing user_id",
                       "_triggers/users/sessions/index.mjs"]:
            if needle not in r.body:
                sys.exit(f"FAIL create-bad missing {needle!r}: {r.body}")
        print("ok  beforePut throw → catchable Error{ code:'trigger_rejected' }")

        bad_sess = kv_get(c, cc, "users/sessions/bad")
        if bad_sess:
            sys.exit(f"FAIL rejected write leaked into kv: '{bad_sess}'")
        print("ok  rejected write is NOT in kv (inner savepoint rolled back)")

        # 5. afterDelete cleanup.
        r = curl(
            cc, f"{tenant_origin}/delete",
            method="POST",
            headers={"Content-Type": "application/json"},
            data='{"sid":"abc"}',
        )
        expect_status("POST /delete", 200, r)

        if kv_get(c, cc, "users/sessions/abc"):
            sys.exit("FAIL session row survived /delete")
        if kv_get(c, cc, "users/by-session/abc"):
            sys.exit("FAIL reverse index survived /delete")
        print("ok  afterDelete cleaned up reverse index via event.previousValue")

        print()
        print("all triggers smoke checks passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
