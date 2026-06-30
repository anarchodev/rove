#!/usr/bin/env python3
"""SSRF outbound-gate smoke (V2).

Proves the PLAN §2.6 outbound contract end-to-end against `rewind`:

Cluster A (production posture — `unsafe_outbound=False`, so NO
`REWIND_UNSAFE_OUTBOUND` in the worker env):
  1. plaintext `http://` upstream      → fetch fails (PlaintextBlocked)
  2. `https://127.0.0.1:9/`            → fetch fails (BlockedAddress, loopback)
  3. `https://169.254.169.254/...`     → fetch fails (BlockedAddress, metadata)
  4. `https://10.1.2.3/`               → fetch fails (BlockedAddress, RFC 1918)
  5. `file:///etc/passwd`              → fetch fails (UnsupportedScheme),
                                         and no file bytes ever reach JS
  …each surfaced to the handler as a failed outcome (the heldsync fixture
  returns 502 + the failure), never as a hang, and logged by the engine as
  `outbound blocked`.

Cluster B (smoke default — `REWIND_UNSAFE_OUTBOUND=1`):
  6. the standard loopback h2c echo flow still works (the escape hatch
     covers exactly the smoke topology; the metadata range stays blocked
     even with the hatch on — checked as 7).

Uses the heldsync fixture (webhook.send + onResult → response) so each
outcome comes back synchronously in one POST.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, PUBLIC_SUFFIX, rpc_wrap  # noqa: E402

HELDSYNC_SRC = r"""export default function () {
    const req = JSON.parse(request.body);
    webhook.send({
        url: req.target,
        method: "POST",
        body: JSON.stringify({ from: "ssrf-smoke", tag: req.tag }),
        headers: { "content-type": "application/json" },
        max_attempts: 1,
        timeout_ms: 8000,
    });
    return __rove_next("probe/onresult", {
        fn: "onResult",
        ctx: { tag: req.tag },
    });
}
"""

ONRESULT_SRC = r"""export function onResult(ctx, outcome) {
    if (!outcome.ok) {
        response.status = 502;
        return "blocked:" + ctx.tag + ":" + (outcome.error || outcome.reason || outcome.status);
    }
    return "passed:" + ctx.tag + ":" + outcome.body;
}
"""

WB_SRC = r"""export default function () {
    let payload = null;
    try { payload = JSON.parse(request.body); } catch (_) {}
    const tag = (payload && payload.tag) || "<no-tag>";
    response.status = 200;
    return "echoed:" + tag;
}
"""

READY_SRC = 'export function handler() { return "ready"; }\n'

FIXTURE = {
    "index.mjs": rpc_wrap(READY_SRC),
    "probe/index.mjs": HELDSYNC_SRC,
    "probe/onresult.mjs": ONRESULT_SRC,
}


def probe(c: V2Cluster, tag: str, target: str):
    return c.request("acme", "/probe", method="POST",
                     headers={"content-type": "application/json"},
                     data=json.dumps({"target": target, "tag": tag}),
                     timeout=30.0)


def deploy_and_wait(c: V2Cluster, check) -> bool:
    r = c.provision("acme")
    check("provision acme → 204", r.status == 204, f"got {r.status} {r.body!r}")
    try:
        dep_id = c.deploy_handlers("acme", FIXTURE)
    except RuntimeError as e:
        check("deploy_handlers", False, str(e))
        return False
    check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
    ready = c.wait_for_handler("acme", "/?fn=handler", want_body="ready")
    check("acme loaded", ready.status == 200 and "ready" in ready.body,
          f"got {ready.status} {ready.body!r}")
    return ready.status == 200


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    print("=== cluster A: production posture (no REWIND_UNSAFE_OUTBOUND) ===")
    with V2Cluster.spawn("ssrfA", nodes=1, http_base=19300,
                         raft_base=19400, unsafe_outbound=False) as c:
        if not deploy_and_wait(c, check):
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        # 1. plaintext http → blocked at the scheme gate (TLS-always).
        plain = f"http://wb.{PUBLIC_SUFFIX}:{c.front_port}/echo"
        r = probe(c, "plain", plain)
        check("http:// upstream → blocked 502",
              r.status == 502 and r.body.startswith("blocked:plain:"),
              f"got {r.status} {r.body!r}")

        # 2-4. https to blocklisted addresses.
        for tag, target in (
            ("loop", "https://127.0.0.1:9/"),
            ("meta", "https://169.254.169.254/latest/meta-data/"),
            ("rfc1918", "https://10.1.2.3/"),
        ):
            r = probe(c, tag, target)
            check(f"{target} → blocked 502",
                  r.status == 502 and r.body.startswith(f"blocked:{tag}:"),
                  f"got {r.status} {r.body!r}")

        # 5. non-http(s) scheme. The shim may reject it before the engine;
        # either way it must fail and no file content may surface.
        r = probe(c, "file", "file:///etc/passwd")
        check("file:// → fails, no file bytes",
              r.status != 200 and "root:" not in r.body,
              f"got {r.status} {r.body!r}")

        # The engine logs every gate rejection operator-readably.
        log = Path(c.log_paths["n1"]).read_text(errors="replace")
        n_blocked = log.count("outbound blocked")
        check("engine logged 'outbound blocked'", n_blocked >= 4,
              f"{n_blocked} 'outbound blocked' line(s) in n1 log")

    print("=== cluster B: smoke default (REWIND_UNSAFE_OUTBOUND=1) ===")
    with V2Cluster.spawn("ssrfB", nodes=1, http_base=19600,
                         raft_base=19700) as c:
        r = c.provision("wb")
        check("provision wb → 204", r.status == 204, f"got {r.status} {r.body!r}")
        if not deploy_and_wait(c, check):
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        c.deploy_handlers("wb", {"index.mjs": WB_SRC, "echo/index.mjs": WB_SRC})

        # wb cold-start: poll the echo directly before the probe.
        deadline = time.time() + 25.0
        wb_ok = False
        while time.time() < deadline:
            w = c.node_request("/echo", method="POST", host=f"wb.{PUBLIC_SUFFIX}",
                               headers={"content-type": "application/json"},
                               data=json.dumps({"tag": "sanity"}))
            if w.status == 200 and w.body == "echoed:sanity":
                wb_ok = True
                break
            time.sleep(0.4)
        check("wb echo reachable", wb_ok, f"got {w.status} {w.body!r}")

        # 6. the loopback h2c flow every other smoke relies on still works.
        wb_url = f"http://wb.{PUBLIC_SUFFIX}:{c.front_port}/echo"
        r = probe(c, "hatch", wb_url)
        check("hatch: loopback h2c echo → 200 passed",
              r.status == 200 and r.body == "passed:hatch:echoed:hatch",
              f"got {r.status} {r.body!r}")

        # 7. metadata range stays blocked even with the hatch on.
        r = probe(c, "meta2", "http://169.254.169.254/latest/meta-data/")
        check("metadata blocked even with hatch",
              r.status == 502 and r.body.startswith("blocked:meta2:"),
              f"got {r.status} {r.body!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nssrf_smoke_v2: ALL OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
