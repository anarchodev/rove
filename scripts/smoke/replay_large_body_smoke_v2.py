#!/usr/bin/env python3
"""A spilled body is load-bearing: replay without it computes a DIFFERENT digest.

An inbound body over 16 KiB is not stored in the log record — it spills to the
cross-tenant body pool and the record keeps only a pointer. Every engine that
replays such a record therefore has to resolve that pointer, and until one did,
a replay ran the handler against an EMPTY body and reported agreement anyway.

That last part is the reason this smoke exists rather than a unit test. The
failure was invisible precisely because nothing compared the two runs on a
handler whose ANSWER depends on the body. So the handler here folds the body
into its response, and the smoke asserts both directions:

  negative control — replay the record AS CAPTURED (pointer unresolved, body
                     absent) and the digest MUST DIFFER from the captured one.
                     This is what proves the check is not vacuous: if this
                     assertion ever passes, the guard below is measuring
                     nothing.

  positive        — resolve the body through the log-server door, hand the
                    replay engine the same bytes the worker saw, and the
                    digest MUST MATCH.

Together they say: the resolver is not a nicety, it is the difference between a
replay that reproduces the run and one that quietly does something else.

ASCII body — `request.text` is a JS string.

Run:
    zig build rewind-worker rewind-cp rewind-front rewind-logs rewind-ops
    set -a; . ./.env; set +a
    REWIND_APPS_DIR=~/src/rewind-apps python3 scripts/smoke/replay_large_body_smoke_v2.py
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])

from smoke_lib_v2 import V2Cluster, APPS_DIR  # noqa: E402

# The response IS a function of the whole body, and the digest folds the
# response (`interaction_digest.response`). A replay that runs on "" therefore
# cannot coincidentally agree.
FIXTURE = {
    "index.mjs": """
export default function () {
  const data = request.text || "";
  return crypto.sha256(data) + ":" + data.length;
}
""",
}

BIG_LEN = 64 * 1024


def _payload(n: int) -> str:
    out = []
    i = 0
    while sum(len(s) for s in out) < n:
        out.append(f"big-{i:08d}-")
        i += 1
    return "".join(out)[:n]


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    apps = str(APPS_DIR)
    checker = os.path.join(apps, "e2e", "replay-digest-check.mjs")
    if not os.path.exists(checker):
        # A cross-engine smoke that silently degrades to single-engine reports a
        # pass having proved nothing. Refuse instead.
        print(f"FAIL no rewind-apps checkout at {apps} — this smoke IS the "
              f"cross-engine comparison; set REWIND_APPS_DIR")
        return 1

    body = _payload(BIG_LEN)

    print("=== a spilled body changes the replay digest (resolve or diverge) ===")
    with V2Cluster.spawn("bigbody", nodes=1) as c:
        c.spawn_log_server(poll_interval_ms=200)

        r = c.provision("acme")
        check("provision acme → 200/409", r.status in (200, 409), f"got {r.status}")
        c.deploy_handlers("acme", FIXTURE)
        c.wait_for_handler("acme", "/", want_body=None, timeout_s=30.0)

        rr = c.request("acme", "/", method="POST", data=body, timeout=30.0)
        check(f"handler saw all {BIG_LEN} bytes", rr.status == 200 and rr.body.endswith(f":{BIG_LEN}"),
              f"status={rr.status} body={rr.body[:80]!r}")
        captured_response = rr.body

        # Find the record.
        records: list = []
        deadline = time.time() + 40.0
        while time.time() < deadline:
            resp = c.log_get("acme/list?limit=50", timeout=15.0)
            if resp.status == 200:
                try:
                    records = json.loads(resp.body).get("records", [])
                except json.JSONDecodeError:
                    records = []
                if any(x.get("method") == "POST" and x.get("status") == 200 for x in records):
                    break
            time.sleep(1.0)
        post = next((x for x in records
                     if x.get("method") == "POST" and x.get("status") == 200), None)
        check("the POST record is indexed", post is not None,
              f"{len(records)} records listed")
        if post is None:
            print(f"\n{len(failures)} failure(s)")
            return 1

        rid = post["request_id"]
        show = c.log_get(f"acme/show/{rid}", timeout=15.0)
        full = json.loads(show.body).get("record", {})
        tapes = full.get("tapes") or {}
        captured_digest = tapes.get("interaction_digest")

        check("the record carries a digest", captured_digest is not None,
              f"got {captured_digest!r}")
        # The premise of the whole smoke: the bytes are NOT in the record.
        # If this ever fails, request_body_b64 is present and the body did NOT
        # spill — the smoke would then be exercising the inline path and
        # proving nothing about resolution.
        check("the record does NOT inline the body (it spilled)",
              not tapes.get("request_body_b64"),
              f"request_body_b64 present={bool(tapes.get('request_body_b64'))}")

        # ── resolve through the door ───────────────────────────────────
        d = c.log_get(f"acme/body/{rid}/trigger_payload/0", timeout=30.0)
        resolved = {}
        if d.status == 200:
            try:
                resolved = json.loads(d.body)
            except json.JSONDecodeError:
                resolved = {}
        check("the door resolves the spilled body", d.status == 200 and resolved.get("source") == "pool",
              f"status={d.status} source={resolved.get('source')!r}")
        resolved_b64 = resolved.get("bytes_b64")
        if resolved_b64:
            got_bytes = base64.b64decode(resolved_b64).decode("utf-8", "replace")
            check("the resolved bytes are the bytes the handler saw",
                  got_bytes == body,
                  f"{len(got_bytes)} bytes, want {len(body)}")

        def replay(record_obj) -> dict:
            with tempfile.TemporaryDirectory() as td:
                rec_path = os.path.join(td, "record.json")
                src_path = os.path.join(td, "index.mjs")
                with open(rec_path, "w") as f:
                    json.dump(record_obj, f)
                with open(src_path, "w") as f:
                    f.write(FIXTURE["index.mjs"])
                proc = subprocess.run(["node", checker, rec_path, src_path],
                                      capture_output=True, text=True, timeout=120)
            out = (proc.stdout or "").strip()
            line = out.splitlines()[-1] if out else "{}"
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                return {"replayed": None,
                        "error": f"unparseable: {proc.stdout[:200]} {proc.stderr[:200]}"}

        # ── negative control ───────────────────────────────────────────
        # As captured, the record has no body bytes. A replay of it MUST NOT
        # agree with the capture. If it does, either the handler stopped
        # depending on its input or the digest stopped folding the response —
        # and in both cases every assertion below is measuring nothing.
        bare = replay(full)
        print(f"    unresolved replay: digest={bare.get('replayed')} "
              f"result={bare.get('result')!r}")
        # A PASS here means the two runs disagree, which is the point: it shows
        # the assertions below can fail. Were this to fail, the handler would
        # have stopped depending on its input (or the digest stopped folding
        # the response) and everything after it would be measuring nothing.
        check("WITHOUT the body, replay diverges from the capture "
              "(the guard can fail)",
              bare.get("replayed") is not None and bare.get("replayed") != captured_digest,
              bare.get("error") or
              f"unresolved={bare.get('replayed')} captured={captured_digest}")

        # ── positive ───────────────────────────────────────────────────
        # Hand the replay engine the resolved bytes and it must reproduce the
        # run exactly: same digest, same answer.
        if resolved_b64:
            healed = json.loads(json.dumps(full))
            healed.setdefault("tapes", {})["request_body_b64"] = resolved_b64
            got = replay(healed)
            print(f"    resolved replay:   digest={got.get('replayed')} "
                  f"result={got.get('result')!r}")
            check("WITH the resolved body, replay recomputes the SAME digest",
                  got.get("replayed") is not None and got.get("replayed") == captured_digest,
                  got.get("error") or
                  f"replay={got.get('replayed')} vs captured={captured_digest}")
            # The checker reports `result` truncated to 40 chars, so compare a
            # prefix. The digest above is the byte-exact assertion — it folds
            # the response, so an identical digest already means identical
            # answers; this is the human-legible confirmation.
            replayed_result = got.get("result") or ""
            check("WITH the resolved body, replay reproduces the same answer",
                  bool(replayed_result) and captured_response.startswith(replayed_result),
                  f"replay={replayed_result!r} is a prefix of captured={captured_response[:48]!r}")

    print()
    if failures:
        print(f"{len(failures)} failure(s): {failures}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
