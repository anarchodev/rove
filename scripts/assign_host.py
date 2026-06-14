#!/usr/bin/env python3
"""assign_host.py — map a system-suffix host to a tenant via the admin
dashboard's operator-gated assignDomain RPC.

Writes the worker-side `domain/{host}` → tenant alias (replicated via the
root writeset) that the worker's host resolver needs for any host outside
`*.{public_suffix}` (e.g. docs./auth. on the system suffix). The CP-side
host index (front routing) is a separate `POST /_control/host` call.

This replaces the retired interim `__admin__` ops handler that
`publish_tenant.py --host` used: with the real admin dashboard deployed,
domain assignment is an operator-authenticated RPC. So this drives the
full OIDC relying-party login as the operator, then calls assignDomain.

  scripts/assign_host.py docs.rewindjs.com docs

Config from ~/.config/rove/prod.env: REWIND_ADMIN_DOMAIN (the app/RP host),
REWIND_SYSTEM_SUFFIX (→ auth.<suffix> IdP host). Operator identity from
$OPERATOR_EMAIL (default mike@loop46.com).

CAVEAT: relies on the IdP's magic-link dev seam (link returned in the JSON
login response because no Resend key is seeded). Once email delivery is
configured the link won't be in the response and this needs a real inbox /
a different operator path.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path


def load_env(path: Path) -> dict:
    env = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def req(url, method="GET", headers=None, data=None):
    hf, bf = tempfile.mktemp(), tempfile.mktemp()
    cmd = ["curl", "-s", "-D", hf, "-o", bf, "--max-time", "20", "-X", method, url]
    for k, v in (headers or {}).items():
        cmd += ["-H", f"{k}: {v}"]
    if data is not None:
        cmd += ["--data", data]
    subprocess.run(cmd, capture_output=True)
    head, body = open(hf).read(), open(bf).read()
    os.remove(hf); os.remove(bf)
    status = int(re.search(r"HTTP/[\d.]+ (\d+)", head).group(1))
    loc = (re.search(r"(?im)^location:\s*(.+?)\s*$", head) or [None, None])
    loc = loc[1] if loc else None
    ck = re.search(r"(?im)^set-cookie:\s*(__Host-rove_sid=[^;]+)", head)
    return status, body, loc, (ck.group(1) if ck else None)


def operator_cookie(app: str, auth: str, email: str) -> str:
    absu = lambda base, l: l if l.startswith("http") else base + l
    s, b, loc, app_ck = req(app + "/_rp/login?return_to=" + urllib.parse.quote("/"))
    assert s == 302 and app_ck, f"/_rp/login {s}"
    s, b, loc, auth_ck = req(loc)
    assert s == 302 and auth_ck, f"/authorize {s}"
    login_loc = absu(auth, loc)
    return_to = urllib.parse.parse_qs(urllib.parse.urlparse(login_loc).query)["return_to"][0]
    s, b, loc, _ = req(auth + "/login", "POST",
                       {"content-type": "application/x-www-form-urlencoded", "Cookie": auth_ck},
                       "email=" + urllib.parse.quote(email) + "&return_to=" + urllib.parse.quote(return_to))
    assert s == 200, f"/login {s}: {b[:120]}"
    magic = json.loads(b)["magic_link"]
    s, b, loc, _ = req(magic, headers={"Cookie": auth_ck})
    assert s == 302, f"/login/verify {s}"
    s, b, loc, _ = req(absu(auth, loc), headers={"Cookie": auth_ck})
    assert s == 302, f"/authorize#2 {s}"
    s, b, loc, _ = req(loc, headers={"Cookie": app_ck})
    assert s == 202, f"/_rp/callback {s}: {b[:120]}"
    for _ in range(160):
        s, b, _, _ = req(app + "/_rp/poll", headers={"Cookie": app_ck})
        if s == 200 and json.loads(b).get("authed"):
            return app_ck
        time.sleep(0.25)
    raise SystemExit("operator login never completed")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: assign_host.py <host> <tenant>", file=sys.stderr)
        return 2
    host, tenant = sys.argv[1], sys.argv[2]
    env = load_env(Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "rove" / "prod.env")
    app = "https://" + env["REWIND_ADMIN_DOMAIN"]
    auth = "https://auth." + env["REWIND_SYSTEM_SUFFIX"]
    email = os.environ.get("OPERATOR_EMAIL", "mike@loop46.com")

    cookie = operator_cookie(app, auth, email)
    print(f"operator session established ({email})")
    args = urllib.parse.quote(json.dumps([host, tenant]))
    s, b, _, _ = req(f"{app}/?fn=assignDomain&args={args}", "POST", {"Cookie": cookie})
    if s not in (200, 201):
        raise SystemExit(f"assignDomain {host}→{tenant}: {s} {b[:200]}")
    print(f"assigned worker domain alias: {host} → {tenant}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
