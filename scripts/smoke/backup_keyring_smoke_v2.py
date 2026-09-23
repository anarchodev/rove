#!/usr/bin/env python3
"""A backup carries the tenant's keyring, or a restore reads back nothing
(rove#963; `rewind-backup`, `/_system/v2-keyring-restore`).

The store dump is ciphertext for every value a tenant sealed under
`shredKey`. The keys that open it are NOT raft state — they are node-local
files, rewritten whole, sealed under the cluster KEK. So a backup that copies
only the store restores a tenant whose rows are all present and all
unreadable, and reports success doing it.

What makes shipping the keys off-provider defensible is that they never leave
sealed: this moves the same bytes the node has on disk, and the copy is inert
without `REWIND_KEYRING_KEK`, which lives in SOPS and never in the backup
store. Two factors, separated by construction.

Proof legs:
  A. a tenant that seals a value has a keyring, and the backup's manifest
     names its parts — the secret plus every shard.
  B. restoring into a cluster that never had the tenant lands those parts
     BYTE-IDENTICALLY on disk. Same bytes, so the same keys; nothing was
     decrypted to make the copy.
  C. a cluster running a DIFFERENT cluster KEK refuses them (409) instead of
     writing key material it cannot open. An unverified install surfaces at a
     failover, which is exactly when that copy becomes the only copy.

Not asserted here, because it cannot be at this layer: that the restored
tenant SERVES the sealed value. Its handler bundle lives in the live cluster's
object store, which a backup does not yet cover (rove#965), so a second
cluster cannot load the deployment. The keys-are-there claim is made on the
bytes; the keys-still-work claim is a unit test in `tenant_keys.zig`, which
can assert it precisely — including that a restore does not resurrect a key
the tenant destroyed.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import smoke_lib_v2  # noqa: E402
from smoke_lib_v2 import V2Cluster, MOVE_SECRET, attach_join, BIN_DIR  # noqa: E402

BACKUP_BIN = os.path.join(BIN_DIR, "rewind-backup")
TENANT = "acme"
RUN_ID = f"kr{os.getpid()}"

# Seals a value under a named identity. `shredKey(id)` mints, so the shard
# files only exist if reserve → mint → quorum push completed.
SRC = (
    'export default function ({ kv, shredKey }) {\n'
    '  const q = request.query || "";\n'
    '  const fn = (q.match(/fn=([^&]+)/) || [])[1];\n'
    '  if (fn === "secret") {\n'
    '    shredKey("u_backup");\n'
    '    kv.set("card", "tuna-casserole-9f3a");\n'
    '    return "sealed\\n";\n'
    '  }\n'
    '  response.status = 404;\n'
    '  return "no such fn\\n";\n'
    '}\n'
)


def keyring_dir(data_dir: Path, tenant: str) -> Path:
    """Mirrors `Keyring.init`: the tenant id is hashed into the path, so a
    directory listing does not enumerate tenants."""
    digest = hashlib.sha256(tenant.encode()).digest()[:16].hex()
    return data_dir / "keyrings" / digest


def keyring_files(d: Path) -> dict[str, bytes]:
    if not d.is_dir():
        return {}
    return {f.name: f.read_bytes() for f in sorted(d.iterdir()) if f.is_file()}


def backup_tool(*args):
    p = subprocess.run([BACKUP_BIN, *args], capture_output=True, text=True, timeout=300)
    out = (p.stdout or "") + (p.stderr or "")
    for line in out.strip().splitlines():
        if "debug: rove-blob" not in line:
            print(f"    | {line}")
    return p.returncode, out


def main() -> int:
    if not os.path.exists(BACKUP_BIN):
        raise SystemExit(f"{BACKUP_BIN} not found — run `zig build rewind-backup`")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")

    os.environ["BACKUP_S3_ENDPOINT"] = os.environ["S3_ENDPOINT"]
    os.environ["BACKUP_S3_REGION"] = os.environ["S3_REGION"]
    os.environ["BACKUP_S3_BUCKET"] = os.environ["S3_BUCKET"]
    os.environ["BACKUP_S3_KEY_PREFIX_BASE"] = f"krbackupsmoke-{os.getpid()}/"
    os.environ["BACKUP_S3_USE_TLS"] = os.environ.get("S3_USE_TLS", "1")
    os.environ["BACKUP_AWS_ACCESS_KEY_ID"] = os.environ["AWS_ACCESS_KEY_ID"]
    os.environ["BACKUP_AWS_SECRET_ACCESS_KEY"] = os.environ["AWS_SECRET_ACCESS_KEY"]
    os.environ["REWIND_MOVE_SECRET"] = MOVE_SECRET

    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    source_files: dict[str, bytes] = {}
    incarnation = ""

    # Three nodes: minting publishes a slot only once the shard reached a
    # quorum, so a single-node source would prove less about the thing being
    # copied.
    with V2Cluster.spawn("krbk", nodes=3) as a:
        print("leg A: a tenant seals a value, and the backup names its keyring")
        r = a.provision(TENANT)
        check("provision → 200", r.status == 200, f"got {r.status}")
        a.deploy_handlers(TENANT, {"index.mjs": SRC})
        a.wait_for_handler(TENANT, "/?fn=secret")
        resp = a.get(TENANT, "/?fn=secret")
        check("handler sealed a value", "sealed" in resp.body,
              f"got {resp.status} {resp.body[:120]!r}")

        # Whichever node leads the tenant is the one the backup reads from;
        # every voter should hold the shards, so take the union.
        dirs = [keyring_dir(d, TENANT) for d in a.data_dirs]
        per_node = [keyring_files(d) for d in dirs]
        with_shards = [f for f in per_node if any(n != "tenant.kr" for n in f)]
        check("the tenant minted keys on at least a quorum",
              len(with_shards) >= 2, f"nodes with shards: {len(with_shards)}")
        source_files = with_shards[0] if with_shards else {}

        # Every node: the door is leader-only and answers 421 elsewhere, so
        # the run walks them until it finds the leader.
        rc, _ = backup_tool("run", "--nodes",
                            ",".join(a.node_url(i) for i in range(3)),
                            "--tenants", TENANT, "--run-id", RUN_ID,
                            "--cp", f"http://127.0.0.1:{a.cp_port}")
        check("backup run", rc == 0)

        rc, out = backup_tool("show", "--run", RUN_ID)
        check("show", rc == 0)
        manifest = json.loads(next(l for l in out.splitlines() if l.startswith("{")))
        entry = manifest["tenants"][0]
        incarnation = entry["incarnation"]
        parts = [p["part"] for p in entry.get("keyring_parts", [])]
        print(f"  manifest parts: {parts}")
        check("the manifest carries the tenant secret", "secret" in parts)
        check("the manifest carries at least one shard",
              any(p.startswith("shard-") for p in parts), f"parts={parts}")

        rc, _ = backup_tool("verify", "--run", RUN_ID)
        check("verify (dump + every keyring part)", rc == 0)

    print("leg B: restore into a cluster that never had this tenant")
    with V2Cluster.spawn("krdst", nodes=1) as b:
        check("attach under the recorded incarnation",
              attach_join(f"{b.node_url(0)}/_system/v2-attach", tenant=TENANT,
                          incarnation=incarnation) == "204")
        rc, _ = backup_tool("restore", "--run", RUN_ID,
                            "--tenant", TENANT, "--nodes", b.node_url(0))
        check("restore", rc == 0)

        restored = keyring_files(keyring_dir(b.data_dirs[0], TENANT))
        check("the destination now holds a keyring", bool(restored),
              f"files={list(restored)}")
        # Byte-identical, not merely present: the same sealed bytes are the
        # same keys. A re-encoded copy would be a second representation of
        # key material, and a divergence between them is unrecoverable.
        same = {n: restored.get(n) == b_ for n, b_ in source_files.items()}
        check("every part is byte-identical to the source",
              all(same.values()) and len(same) == len(source_files),
              f"per-file: {same}")

    print("leg C: a cluster under a different KEK refuses the keys")
    original_kek = smoke_lib_v2.KEYRING_KEK
    smoke_lib_v2.KEYRING_KEK = "a-different-cluster-kek-0123456789abcdef"
    try:
        with V2Cluster.spawn("krkek", nodes=1) as c:
            check("attach on the foreign-KEK cluster",
                  attach_join(f"{c.node_url(0)}/_system/v2-attach", tenant=TENANT,
                              incarnation=incarnation) == "204")
            rc, out = backup_tool("restore", "--run", RUN_ID,
                                  "--tenant", TENANT, "--nodes", c.node_url(0))
            check("restore FAILS", rc != 0)
            check("refused with 409, not written", "409" in out,
                  "no 409 in the tool's output")
            landed = keyring_files(keyring_dir(c.data_dirs[0], TENANT))
            check("no shard landed under the wrong KEK",
                  not any(n != "tenant.kr" for n in landed), f"files={list(landed)}")
    finally:
        smoke_lib_v2.KEYRING_KEK = original_kek

    if failures:
        print(f"\nFAILED ({len(failures)}):")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nbackup keyring smoke: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
