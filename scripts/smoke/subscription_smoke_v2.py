#!/usr/bin/env python3
"""V2 port of `subscription_smoke.py` — held outbound subscription via
`http.subscribe` (`docs/curl-multi-plan.md` Phase 3 / gap 2.5), on the
`V2Cluster` harness (`smoke_lib_v2`).

Two tenants on a single node:
  - `acme` opens a held subscription against `wb/drip` and records each
    chunk under `sub/chunk/<id>/<seq>` (subscribe_oc.mjs).
  - `wb` serves an infinite SSE-style drip (`wb/drip`), one frame ~120 ms.

Handler JS reused VERBATIM from the V1 demo tenant
(`examples/loop46-demo-tenants/{acme,wb}/…`).

Flow / essential assertions (unchanged from V1):
  1. GET acme/subscribe?url=<wb/drip> → sub_id (200, non-empty body).
  2. Poll the tenant KV until ≥3 chunks have landed (held transfer is
     streaming + on_chunk activations fire).
  3. POST acme/cancel_subscribe?id=… → cancels the subscription.
  4. Assert no `sub/done/<id>` marker (cooperative cancel doesn't
     synthesize a terminal — curl-multi-plan §5 invariant 3).
  5. Confirm chunk count stops growing past the cancel.

Dropped from V1: TLS/https, 3-node leader election / discover_leader
(single-node behavior smoke; front door is serve-or-forward).

The held subscription fetches `http://wb.<suffix>:<node_port>/drip`. The
worker binds `0.0.0.0`, so the on-box outbound libcurl reaches the same
node over loopback; the `<tenant>.<suffix>` Host carries the tenant
routing (`REWIND_PUBLIC_SUFFIX=localhost` → `wb.localhost` resolves to the
`wb` tenant). No SSRF escape hatch is needed — the V2 fetch path doesn't
enforce the loopback/plaintext block.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import sys
import time
import urllib.parse as up
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, PUBLIC_SUFFIX  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants"


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


ACME_HANDLERS = {
    "subscribe/index.mjs": _src("acme/subscribe/index.mjs"),
    "subscribe_oc.mjs": _src("acme/subscribe_oc.mjs"),
    "cancel_subscribe/index.mjs": _src("acme/cancel_subscribe/index.mjs"),
    "readkey/index.mjs": _src("acme/readkey/index.mjs"),
    "index.mjs": _src("acme/index.mjs"),
}
WB_HANDLERS = {
    "index.mjs": _src("wb/index.mjs"),
    "drip/index.mjs": _src("wb/drip/index.mjs"),
}


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("subs", nodes=1) as c:
        print("step 1: provision + deploy acme (subscriber) and wb (drip upstream)")
        r = c.provision("acme")
        check("provision acme → 204", r.status == 204, f"got {r.status} {r.body!r}")
        r = c.provision("wb")
        check("provision wb → 204", r.status == 204, f"got {r.status} {r.body!r}")
        try:
            c.deploy_handlers("acme", ACME_HANDLERS)
            c.deploy_handlers("wb", WB_HANDLERS)
            check("deploy acme + wb", True)
        except RuntimeError as e:
            check("deploy acme + wb", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        # Warm BOTH tenants so wb/drip is loaded before acme subscribes.
        r = c.wait_for_handler("wb", "/", want_status=200, timeout_s=25.0)
        check("wb reachable", r.status == 200, f"got {r.status} {r.body!r}")
        r = c.wait_for_handler("acme", "/readkey?key=__warm", want_status=404,
                               timeout_s=25.0)
        check("acme reachable", r.status in (200, 404),
              f"got {r.status} {r.body!r}")
        if failures:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "404",
                                  "error", "warn"])
            print("\nFAILURES:", failures)
            return 1
        print("ok  acme + wb both warm")

        # The upstream URL the held subscription fetches. wb is served on the
        # node port; acme's worker fetches it over loopback h2c. The
        # `wb.<suffix>` Host carries the tenant routing (a bare 127.0.0.1
        # URL would 404 — no tenant in the Host).
        drip_url = f"http://wb.{PUBLIC_SUFFIX}:{c.node_ports[0]}/drip"

        # ── 1. Open the subscription. ─────────────────────────────────
        r = c.get("acme", f"/subscribe?url={up.quote(drip_url)}",
                  headers={"Host": c.host_for("acme")})
        if r.status != 200 or not r.body.strip():
            check("open http.subscribe → sub_id", False,
                  f"status={r.status} body={r.body!r}")
            c.dump_node_log(grep=["subscribe", "fetch", "ssrf", "block",
                                  "error", "warn"])
            print("\nFAILURES:", failures)
            return 1
        sub_id = r.body.strip()
        check("open http.subscribe → sub_id", True, f"id={sub_id[:16]}…")

        # ── 2. Poll until ≥3 chunks have landed. ──────────────────────
        def chunks_up_to(cap: int) -> int:
            n = 0
            for seq in range(0, cap):
                rr = c.admin_kv_get("acme", f"sub/chunk/{sub_id}/{seq}")
                if rr.status != 200 or not rr.body.strip():
                    break
                n += 1
            return n

        target = 3
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if chunks_up_to(target) >= target:
                break
            # Early failure detection: a terminal `sub/done` with a non-2xx
            # upstream status before any chunk means the fetch never streamed
            # (e.g. upstream 404 — wrong Host routing, or the drip didn't load).
            done = c.admin_kv_get("acme", f"sub/done/{sub_id}")
            if done.status == 200 and done.body.strip() and chunks_up_to(1) == 0:
                check("held subscription streams ≥3 chunks", False,
                      f"terminal before any chunk (sub/done={done.body!r})")
                c.dump_node_log(grep=["subscribe", "fetch", "drip", "404",
                                      "error", "warn"])
                print("\nFAILURES:", failures)
                return 1
            time.sleep(0.4)
        got = chunks_up_to(target + 4)
        check("held subscription streams ≥3 chunks", got >= target,
              f"{got} chunks" if got >= target else f"only {got} chunks in 20s")
        if got < target:
            c.dump_node_log(grep=["subscribe", "fetch", "ssrf", "block",
                                  "blocked", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1
        print(f"ok  {got} chunks streamed before cancel (wb/drip ~120 ms)")

        # ── 3. Cancel. ────────────────────────────────────────────────
        r = c.request("acme", f"/cancel_subscribe?id={sub_id}", method="POST",
                      headers={"Host": c.host_for("acme")})
        check("cancel_subscribe → 200", r.status == 200,
              f"status={r.status} body={r.body!r}")

        # ── 4. Cooperative cancel: no terminal event synthesized. ─────
        time.sleep(0.5)
        # admin_kv_get → 404 "no such key" when the key is absent (the
        # cooperative-cancel expectation); 200 means a terminal was synthesized.
        done = c.admin_kv_get("acme", f"sub/done/{sub_id}")
        terminal_present = done.status == 200
        check("no terminal event after cancel (cooperative)",
              not terminal_present,
              f"sub/done present: {done.body!r}" if terminal_present else "")

        # ── 5. Chunk count stops growing past cancel. ─────────────────
        time.sleep(1.0)
        post = chunks_up_to(got + 8)
        check("chunks stop after cancel (≤2 in-flight slack)",
              post <= got + 2, f"pre={got} post={post}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS subscription smoke (v2): held outbound subscription via "
          "http.subscribe; FetchEngine streams + cancel is cooperative")
    return 0


if __name__ == "__main__":
    sys.exit(main())
