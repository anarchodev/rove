#!/usr/bin/env python3
"""C1 crypto-shred smoke — deprovision destroys a tenant's keyring on EVERY
node, and an eviction that is not a deprovision leaves it alone.

The tenant-level shred is what puts code behind the account-closure promise:
the CP's object sweep only reaches per-tenant prefixes, so a closed account's
bytes survive in shared objects and in every backup. Destroying the tenant's
keyring makes all of it permanently unreadable instead.

Both directions are asserted here, because only one of them is recoverable.
A deprovision that fails to shred leaves key material behind — untidy, and
fixable by running the delete again. An eviction that shreds when it should
not destroys a LIVE tenant's keys, which is unrecoverable and looks exactly
like data loss because it is. `/_system/v2-evict` serves both paths and tells
them apart only by the `shred` flag the CP sets, so the flag is the thing
under test.

Step 3 sends the identical request a move's source eviction sends — same
route, same body, no `shred` — rather than staging a two-cluster move, so the
assertion is about the flag and nothing else.

Three nodes, because "destroyed on every node" is the actual claim and a
single-node run cannot see a node that was missed.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import MOVE_SECRET, V2Cluster, _curl  # noqa: E402


def keyring_dir(data_dir: Path, tenant: str) -> Path:
    """Where a tenant's keyring lives on one node.

    Mirrors `Keyring.init`: the tenant id is hashed into the path rather
    than used raw, so a directory listing does not enumerate tenants and a
    customer-chosen id cannot carry characters a path cannot.
    """
    digest = hashlib.sha256(tenant.encode()).digest()[:16].hex()
    return data_dir / "keyrings" / digest


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("kshred", nodes=3) as c:
        cp = c.front_url().replace(str(c.front_port), str(c.cp_port))

        print("step 1: provision — every birth node writes the tenant's keyring")
        r = c.provision("acme")
        check("provision → 200", r.status == 200, f"got {r.status} {r.body!r}")

        dirs = [keyring_dir(d, "acme") for d in c.data_dirs]
        present = [d.is_dir() for d in dirs]
        check("keyring exists on all 3 nodes", all(present),
              f"present={present}")
        # The secret file is the C1 key itself. Without it the directory
        # could exist and hold nothing, which would make step 4 pass for
        # the wrong reason.
        secrets = [(d / "tenant.kr").is_file() for d in dirs]
        check("each node holds the tenant secret", all(secrets), f"secret={secrets}")

        print("step 2: provision a second tenant, to prove the shred is scoped")
        r = c.provision("bystander")
        check("provision bystander → 200", r.status == 200, f"got {r.status} {r.body!r}")
        bystander = [keyring_dir(d, "bystander") for d in c.data_dirs]
        check("bystander keyring exists", all(d.is_dir() for d in bystander))

        print("step 3: an eviction WITHOUT shred leaves the keyring — the move path")
        # Byte-for-byte what `move.evictAll` sends for a move's source
        # cleanup. If this shredded, a routine move would destroy the keys
        # of a tenant that is still serving on the destination.
        for i, port in enumerate(c.node_ports):
            r = _curl(f"http://127.0.0.1:{port}/_system/v2-evict",
                      method="POST",
                      headers={"X-Rewind-Move-Secret": MOVE_SECRET,
                               "Content-Type": "application/json"},
                      data=json.dumps({"tenant": "bystander"}))
            check(f"v2-evict node{i + 1} (no shred) → 204", r.status == 204,
                  f"got {r.status} {r.body[:120]!r}")
        survived = [d.is_dir() for d in bystander]
        check("keyring SURVIVES an evict with no shred flag", all(survived),
              f"present={survived}")

        print("step 4: deprovision — the keyring is destroyed on every node")
        r = _curl(f"{cp}/_control/delete",
                  method="POST",
                  headers={"X-Rewind-Move-Secret": MOVE_SECRET,
                           "Content-Type": "application/json"},
                  data=json.dumps({"tenant": "acme"}))
        check("delete → 204", r.status == 204, f"got {r.status} {r.body[:200]!r}")

        gone = [not d.exists() for d in dirs]
        check("keyring destroyed on all 3 nodes", all(gone),
              f"gone={gone} dirs={[str(d) for d in dirs]}")

        print("step 5: the shred is scoped to the deprovisioned tenant")
        check("bystander keyring untouched", all(d.is_dir() for d in bystander),
              f"present={[d.is_dir() for d in bystander]}")

        print("step 6: deprovision is idempotent")
        r = _curl(f"{cp}/_control/delete",
                  method="POST",
                  headers={"X-Rewind-Move-Secret": MOVE_SECRET,
                           "Content-Type": "application/json"},
                  data=json.dumps({"tenant": "acme"}))
        check("second delete → 204", r.status == 204, f"got {r.status} {r.body[:200]!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
