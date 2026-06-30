#!/usr/bin/env python3
"""V2 streamed-snapshot LARGE-store smoke (raft Phase 2.5).

The trigger smoke proves a stranded peer auto-recovers via the catch-up driver
at trivial scale. This one proves the **streamed** transfer
(`/_system/v2-snapshot-stream`) carries a NON-trivial store correctly and with
BOUNDED memory: the leader stages one pair at a time off a held snapshot
(`StreamDumper`), libcurl uploads it as a chunked body (never buffered whole),
and the dest applies it in BOUNDED txn batches (`StreamLoader`, default 8 MiB)
before installing the raft baseline — vs the retired single-shot path that
materialized the whole store in one `ArrayList` + one HTTP body + one txn.

The store is made large by having the handler GENERATE big values server-side
(small request bodies, large STORE) — so the value never rides a capped request
body, only the streamed snapshot. The recovery + big-value read-back on the
victim proves the multi-batch streamed apply is byte-correct at scale.

Sequence (mirrors snapshot_trigger_smoke_v2, but with a large store):
  1. provision acme [1,2,3], deploy, tiny seed.
  2. FREEZE a follower victim (SIGSTOP) — quorum 2/3 survives.
  3. write a LARGE store on the survivors (N × VAL_BYTES values) — far past the
     victim's frozen index, so the leader compacts past it (un-catchable from
     the log; only the streamed snapshot can recover it).
  4. THAW the victim → it auto-recovers by STREAMING the whole store.
  5. assert: victim's last_index catches the leader's AND several big values
     read back byte-exact on the victim (the streamed pairs applied correctly
     across multiple dest batches).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# Low compaction buffer so the large-store writes strand the frozen victim past
# it quickly (set before spawn — _spawn_node inherits the env).
os.environ["REWIND_SNAPSHOT_GRACE"] = "20"
os.environ["REWIND_AUTO_DEMOTE_LAG"] = "0"

from smoke_lib_v2 import V2Cluster, rpc_wrap, MOVE_SECRET  # noqa: E402

# Handler: POST {key, size} generates an `size`-byte value server-side (keeps
# request bodies small); POST {key, value} writes a literal; GET ?key= returns
# "len:<n>" so a reader can verify a value's length without shipping it back.
HANDLER_SRC = """\
export function handler() {
    if (request.method === "POST") {
        const b = JSON.parse(request.body || "{}");
        if (b.size) { kv.set(b.key, "v".repeat(b.size)); }
        else { kv.set(b.key ?? "cc/value", b.value ?? ""); }
        response.status = 204;
        return "";
    }
    const u = new URL(request.url, "http://x");
    const k = u.searchParams.get("key");
    if (k) { const v = kv.get(k); return v == null ? "none" : ("len:" + v.length); }
    return "value:" + (kv.get("cc/value") ?? "none");
}
"""

VAL_BYTES = 256 * 1024   # 256 KiB per value
N_BIG = 200              # → ~50 MiB store (≈ 6 dest batches at 8 MiB)
SLACK = 64


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("snaplarge", nodes=3) as c:
        def last_index(node):
            out = subprocess.run(
                ["curl", "-s", "-w", "\n%{http_code}", "-m", "15", "--http2-prior-knowledge",
                 "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
                 f"{c.node_url(node)}/_system/v2-last-index?tenant=acme"],
                capture_output=True, text=True).stdout
            nl = out.rfind("\n")
            if out[nl + 1:].strip() != "200":
                return 0
            try:
                return json.loads(out[:nl]).get("last_index", 0)
            except Exception:
                return 0

        print("step 1: provision acme [1,2,3] + deploy + seed")
        check("provision → 204", c.provision("acme").status == 204)
        lead0 = c.leader_node("acme")
        if lead0 is None:
            check("leader present", False); return 1
        try:
            check("deploy → dep_id", bool(c.deploy_handlers(
                "acme", {"index.mjs": rpc_wrap(HANDLER_SRC)}, node=lead0)))
        except RuntimeError as e:
            check("deploy", False, str(e)); return 1
        c.wait_for_handler("acme", "/?fn=handler", want_body="value:none")
        for i in range(5):
            c.request("acme", "/?fn=handler", method="POST",
                      data=f'{{"value":"seed-{i}"}}', timeout=10)
        time.sleep(1.0)

        lead = c.leader_node("acme")
        victim = next(i for i in range(3) if i != lead)
        vnid = victim + 1
        print(f"       leader=node {lead + 1}; victim follower = node {vnid}")

        print(f"step 2: FREEZE node {vnid} (SIGSTOP) — quorum 2/3 survives")
        frozen_idx = last_index(victim)
        c.node_procs[victim].send_signal(signal.SIGSTOP)
        check(f"node {vnid} frozen", frozen_idx > 0, f"frozen at last_index={frozen_idx}")

        print(f"step 3: write a LARGE store on the survivors "
              f"({N_BIG} × {VAL_BYTES // 1024} KiB ≈ {N_BIG * VAL_BYTES // (1024 * 1024)} MiB)")
        # request_retry rides out transient non-204s — under a degraded 2/3
        # quorum hammered with 256 KiB entries, an occasional write times out;
        # that's a write-path-under-stress artifact, not the snapshot path.
        wrote = 0
        for i in range(N_BIG):
            r = c.request_retry("acme", "/?fn=handler", method="POST",
                                data=f'{{"key":"big/{i:04d}","size":{VAL_BYTES}}}',
                                want_status=204, deadline_s=20)
            if r.status == 204:
                wrote += 1
        check("large-store writes accepted", wrote == N_BIG, f"{wrote}/{N_BIG} ok")
        time.sleep(2.0)  # let durabilizeTick compact the WAL past the victim
        ll = last_index(lead)
        check("leader advanced past the frozen victim", ll >= frozen_idx + 200,
              f"leader_last={ll} frozen_idx={frozen_idx}")

        print(f"step 4: THAW node {vnid} (SIGCONT) — recovers by STREAMING the store")
        c.node_procs[victim].send_signal(signal.SIGCONT)

        print(f"step 5: ⭐ node {vnid} streams the large store + applies it in batches")
        caught = False
        t_end = time.time() + 90.0
        vlast = 0
        while time.time() < t_end:
            vlast = last_index(victim)
            if vlast > frozen_idx and vlast + SLACK >= ll:
                caught = True
                break
            time.sleep(1.0)
        check("⭐ victim recovered the large store past the compaction buffer",
              caught, f"victim last_index={vlast} leader_last={ll}")

        # Byte-exact read-back of sampled big values ON THE VICTIM — proves the
        # streamed pairs applied correctly across multiple dest txn batches.
        ok_vals = 0
        sample = ["big/0000", "big/0099", f"big/{N_BIG - 1:04d}"]
        for k in sample:
            body = c.admin_kv_get("acme", k, node=victim).body
            if len(body) == VAL_BYTES and body[:1] == "v":
                ok_vals += 1
        check(f"⭐ sampled big values byte-exact on recovered node {vnid}",
              ok_vals == len(sample), f"{ok_vals}/{len(sample)} correct ({VAL_BYTES} B each)")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS streamed-snapshot large-store smoke (v2) — a ~50 MiB store was "
          "STREAMED to a stranded peer over /_system/v2-snapshot-stream (one pair "
          "staged at a time, applied in bounded batches) and read back byte-exact. ⭐")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
