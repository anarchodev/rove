#!/usr/bin/env python3
"""A tenant's raft WAL entries are sealed at rest, and recover (rove#611).

Every tenant's entries interleave in one WAL file per node, and it is the only
place readsets live — so a tenant's writes and reads would otherwise sit on
disk in the clear with no time bound. Each tenant group's entry data is now
sealed under a subkey of its own stored secret.

The proof is a CONTRAST between two clusters running the same handler,
because an absent string alone proves nothing (the grep could be looking in
the wrong place):

  * CONTROL — a cluster with the keyring surface off writes the value, and it
    IS in its WAL files: the WAL is where this grep looks, and the value is
    what it looks for;
  * a sealed cluster writes the same value (no `shredKey` — the ordinary
    case), and it is in NO node's WAL, while the WAL does hold sealed-entry
    records (tag 5) — sealing happened, rather than nothing being written;
  * every node of the sealed cluster restarts, recovery opens what it sealed,
    and the value still reads back.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

TENANT = "walseal"
MARKER = "anchovy-walseal-5d0e"

SRC = (
    'export default function ({ kv }) {\n'
    '  const fn = ((request.query || "").match(/fn=([^&]+)/) || [])[1];\n'
    '  if (fn === "write") { kv.set("card", "' + MARKER + '"); return "wrote"; }\n'
    '  if (fn === "read") return "read:" + kv.get("card");\n'
    '  return "ready";\n'
    '}\n'
)


def wal_bytes(c, i) -> bytes:
    out = b""
    for p in sorted(c.data_dirs[i].glob("raft-wal*")):
        out += p.read_bytes()
    return out


def record_tags(wal: bytes) -> list[int]:
    """The tag of every CRC-framed record: [tag:u8][group:u64][len:u32][payload][crc:u32]."""
    tags, off = [], 0
    while off + 13 <= len(wal):
        tag = wal[off]
        plen = int.from_bytes(wal[off + 9:off + 13], "little")
        if tag not in (1, 2, 3, 4, 5) or off + 13 + plen + 4 > len(wal):
            break
        tags.append(tag)
        off += 13 + plen + 4
    return tags


def write_value(c, check, label) -> None:
    r = c.provision(TENANT)
    check(f"{label}: provision → 200/409", r.status in (200, 409), f"{r.status} {r.body!r}")
    c.wait_for_membership(TENANT, voters=3)
    c.deploy_handlers(TENANT, {"index.mjs": SRC})
    c.wait_for_handler(TENANT, "/?fn=ready", want_body="ready", timeout_s=45.0)
    r = c.request(TENANT, "/?fn=write", timeout=30.0)
    check(f"{label}: the tenant writes a value", r.status == 200 and r.body == "wrote", f"{r.status} {r.body!r}")
    time.sleep(2.0)  # every replica applies and appends it


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    print("=== a tenant's WAL entries are sealed at rest, and recover (rove#611) ===")
    print("step 1: CONTROL — keyring surface off, so nothing is sealed")
    with V2Cluster.spawn("walplain", nodes=3, keyring=False) as c:
        write_value(c, check, "control")
        for i in range(3):
            check(f"control node {i + 1}: the value IS in its WAL",
                  MARKER.encode() in wal_bytes(c, i), "the grep cannot see the WAL")

    print("step 2: sealed — the same write")
    with V2Cluster.spawn("walseal", nodes=3) as c:
        write_value(c, check, "sealed")
        for i in range(3):
            wal = wal_bytes(c, i)
            check(f"node {i + 1}: the value is NOT in its WAL", MARKER.encode() not in wal,
                  "the value is on disk in the clear")
            tags = record_tags(wal)
            check(f"node {i + 1}: the WAL holds sealed-entry records", tags.count(5) > 0,
                  f"tags={sorted(set(tags))}")

        print("step 3: restart every node — recovery must open what it sealed")
        for i in range(3):
            c.stop_node(i)
        for i in range(3):
            c.start_node(i)
        c.wait_for_membership(TENANT, voters=3)
        r = c.request_retry(TENANT, "/?fn=read", want_status=200, deadline_s=60.0)
        check("the value reads back after a full restart",
              r.status == 200 and r.body == "read:" + MARKER, f"{r.status} {r.body[:120]!r}")

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print("\nPASS — a tenant's WAL entries are ciphertext on disk and recover whole.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
