#!/usr/bin/env python3
"""Keyring shard transport smoke — the `/_system/v2-keyring-shard` door.

Crypto shredding makes a key's destruction the erasure, which only works
if the key reached more than one node in the first place: a key that
exists on a single node dies with it, and whatever it sealed becomes
unreadable with no retry and no repair. This endpoint is how a sealed
shard gets to a peer.

What this proves today:

  - the route exists and is gated by the move secret (401 without it),
    so key material is never installable by an unauthenticated caller
  - a frame this build cannot understand is REFUSED, not half-applied —
    a partially-understood keyring transfer installs wrong key material,
    which is worse than failing
  - a rejected push writes nothing

What it deliberately does NOT prove: that a valid shard installs. Doing
that from Python would mean a second implementation of the seal and the
shard body, and two implementations of a key format is exactly the
drift this design avoids elsewhere. The install path is covered where
the real producer lives — `src/crypt/keyring.zig`'s replication seam
tests mint on one node, ship the bytes, and open them on another. The
end-to-end version lands with the slot pool's wiring, when the worker
itself can produce a frame.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import MOVE_SECRET, V2Cluster, _curl  # noqa: E402

ROUTE = "/_system/v2-keyring-shard"

# `[4B magic 'RKX1' BE][2B version LE][2B tenant_len LE][4B shard LE][4B sealed_len LE]`
# Built here only to be REJECTED — nothing below constructs a frame the
# worker should accept.
MAGIC = b"\x52\x4b\x58\x31"


def frame(tenant: bytes, shard: int, sealed: bytes, version: int = 1) -> bytes:
    return (
        MAGIC
        + version.to_bytes(2, "little")
        + len(tenant).to_bytes(2, "little")
        + shard.to_bytes(4, "little")
        + len(sealed).to_bytes(4, "little")
        + tenant
        + sealed
    )


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"{'ok  ' if ok else 'FAIL'} {label}" + (f"  [{detail}]" if detail else ""))
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("keyring", nodes=1) as c:
        url = c.node_url(0) + ROUTE
        auth = {"X-Rewind-Move-Secret": MOVE_SECRET}

        # 1. Unauthenticated. Key material must never be installable by a
        #    caller who cannot prove it is part of the cluster.
        r = _curl(url, method="POST", data=b"anything")
        check("no move secret is rejected", r.status == 401, f"status={r.status}")

        # 2. A wrong secret is no better than none.
        r = _curl(url, method="POST", headers={"X-Rewind-Move-Secret": "wrong"},
                  data=b"anything")
        check("a wrong move secret is rejected", r.status == 401, f"status={r.status}")

        # 3. Garbage body — no magic at all.
        r = _curl(url, method="POST", headers=auth, data=b"not a frame")
        check("a non-frame body is refused", r.status == 400, f"status={r.status}")

        # 4. Right magic, wrong version. A peer running a newer wire
        #    format must be refused loudly rather than have its frame
        #    half-understood: installing wrong key material is worse
        #    than installing none.
        r = _curl(url, method="POST", headers=auth,
                  data=frame(b"acme", 0, b"x" * 64, version=99))
        check("a future wire version is refused", r.status == 400, f"status={r.status}")

        # 5. Self-consistent header, but the sealed body is not a shard
        #    and does not open under this node's KEK. Either way it must
        #    not land.
        r = _curl(url, method="POST", headers=auth,
                  data=frame(b"acme", 0, b"x" * 64))
        check("an unopenable shard body is refused",
              r.status in (409, 422), f"status={r.status}")

        # 6. Truncated: the declared length disagrees with the bytes. An
        #    exact-length check is what stops a partial frame being
        #    treated as a whole one.
        good = frame(b"acme", 0, b"x" * 64)
        r = _curl(url, method="POST", headers=auth, data=good[:-8])
        check("a truncated frame is refused", r.status == 400, f"status={r.status}")

        # 7. GET is not an install verb.
        r = _curl(url, method="GET", headers=auth)
        check("GET is rejected", r.status == 405, f"status={r.status}")

        # 8. Nothing above should have created a keyring. A rejected
        #    push that still wrote is the failure mode that would make
        #    every check above meaningless.
        keyrings = Path(c.data_dirs[0]) / "keyrings"
        check("no keyring was written by a rejected push",
              not keyrings.exists() or not any(keyrings.iterdir()),
              f"dir={keyrings}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): " + ", ".join(failures))
        return 1
    print("\nkeyring shard transport smoke: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
