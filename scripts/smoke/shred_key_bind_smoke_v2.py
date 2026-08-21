#!/usr/bin/env python3
"""`request.shredKey(id)` binds an identity to a minted slot — the first
end-to-end exercise of the keyring pool.

Everything under this has been landing without a caller: the keyring opens
with a tenant slot, the pool mints ahead of demand, the shared driver turns
the crank, and `_keys/minted` says how far minting has got. A handler calling
`shredKey` is what finally drives all of it, so this is the smoke that can
tell whether any of it works.

What it proves, in the order it becomes true:

  1. naming an identity mints keys — shard files appear under the tenant's
     keyring directory, which only happens if reserve → mint → quorum push
     completed;
  2. rove#685 is really fixed. `reserve` proposes `_keys/next_slot` and then
     READS IT BACK to check its nonce. Before #685 those writes went through
     a control-plane helper whose entry a worker LEADER skips, so the value
     reached every follower and no leader — the read-back could never see
     its own write, reserve could never succeed, the pool could never fill,
     and `shredKey` would throw. A handler that returns 200 here is that
     whole chain working, on the leader;
  3. the keys reached a QUORUM — `prepareBlock` publishes a block only once
     the shard push returns, so a slot being handed out means a majority
     holds the keys, and shard files on ≥2 of 3 nodes is that made visible;
  4. an empty id is refused rather than read as "no identity".

Deliberately NOT asserted here: the shape of the `_keys/bind/` rows. There is
no operator read path for a tenant's kv, and adding one purely for a test
would be a dev-only surface. The binding codec — the HMAC key, the collision
guard, the fact that the plaintext identity never lands in a key name — is
covered by unit tests in `src/js/keyring_bind.zig`, which is where it can be
asserted precisely rather than inferred.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import hashlib
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

# Names an identity, then writes under it. The write is what makes the
# activation's raft entry carry the binding row.
SRC = (
    'export function bind() {\n'
    '  request.shredKey(request.query.split("=")[1] || "u_default");\n'
    '  kv.set("note", "v");\n'
    '  return "bound\\n";\n'
    '}\n'
    'export function secret() {\n'
    '  request.shredKey(request.query.split("=")[1] || "u_default");\n'
    '  kv.set("card", "tuna-casserole-9f3a");\n'
    '  return "readback:" + kv.get("card") + "\\n";\n'
    '}\n'
    'export function plain() {\n'
    '  kv.set("plainrow", "pilchard-control-2b7e");\n'
    '  return "plain\\n";\n'
    '}\n'
    'export function badId() {\n'
    '  try { request.shredKey(""); return "accepted\\n"; }\n'
    '  catch (e) { return "refused:" + e.constructor.name + "\\n"; }\n'
    '}\n'
)


def keyring_dir(data_dir: Path, tenant: str) -> Path:
    digest = hashlib.sha256(tenant.encode()).digest()[:16].hex()
    return data_dir / "keyrings" / digest


def shard_files(d: Path) -> list[Path]:
    """Shard files only — `{8 hex}.kr`, never the tenant secret.

    `tenant.kr` sits in the same directory and also ends `.kr`, so a naive
    `*.kr` glob counts one per node and every "keys were minted" assertion
    passes on a keyring that has never minted anything.
    """
    if not d.is_dir():
        return []
    return [f for f in d.glob("*.kr")
            if len(f.stem) == 8 and all(ch in "0123456789abcdef" for ch in f.stem)]


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("shredbind", nodes=3) as c:
        print("step 1: provision + deploy a handler that names an identity")
        r = c.provision("acme")
        check("provision → 200", r.status == 200, f"got {r.status}")
        dep = c.deploy_handlers("acme", {"index.mjs": rpc_wrap(SRC)})
        check("deploy → dep_id", bool(dep), f"dep_id={dep}")

        dirs = [keyring_dir(d, "acme") for d in c.data_dirs]
        shards_before = sum(len(shard_files(d)) for d in dirs)

        print("step 2: name an identity — this is what drives the pool")
        r = c.wait_for_handler("acme", "/?fn=bind&id=u_alpha", want_body="bound")
        check("shredKey + kv.set → 200", r.status == 200 and "bound" in r.body,
              f"got {r.status} {r.body!r}")
        if r.status != 200:
            c.dump_node_log(grep=["shred", "keyring", "pool", "reserve", "error", "warn"])

        print("step 3: keys were minted — shard files exist")
        deadline = time.time() + 30
        shards = 0
        while time.time() < deadline:
            shards = sum(len(shard_files(d)) for d in dirs)
            if shards > shards_before:
                break
            time.sleep(0.5)
        check("keyring shard files appear", shards > shards_before,
              f"before={shards_before} after={shards}")

        print("step 4: the keys reached a QUORUM — shards on more than one node")
        # `prepareBlock` only publishes a block once the shard push
        # returns, so a slot being handed out at all means a majority
        # holds the keys. Shards on ≥2 of 3 nodes is that, visibly.
        holders = [d for d in dirs if shard_files(d)]
        check("shards present on a majority of nodes", len(holders) >= 2,
              f"holders={len(holders)}/3")
        # A MAJORITY is the guarantee and the only thing that is
        # synchronous: `prepareBlock` waits for quorum, not for everyone.
        # #670 offers each shard to every voter, so the third normally
        # lands too — a moment later. Reported, never asserted, because
        # asserting it would be asserting a race.
        if len(holders) < 3:
            print(f"     note: {len(holders)}/3 hold shards; the last push "
                  "had not landed yet (quorum is what is awaited)")
            c.dump_node_log(grep=["keyring push", "no quorum", "REWIND_PEER_URLS"])

        print("step 5: a second identity also binds (the pool keeps serving)")
        r = c.get("acme", "/?fn=bind&id=u_beta")
        check("second identity → 200", r.status == 200 and "bound" in r.body,
              f"got {r.status} {r.body!r}")

        print("step 6: a returning identity still resolves")
        r = c.get("acme", "/?fn=bind&id=u_alpha")
        check("returning identity → 200", r.status == 200 and "bound" in r.body,
              f"got {r.status} {r.body!r}")

        print("step 7: the value is SEALED at rest, and reads back plaintext")
        # Round-tripping proves nothing on its own — a no-op seal
        # round-trips too. So: write a distinctive marker under an
        # identity, then grep the tenant's store files for it. Finding it
        # would mean the bytes went to disk in the clear.
        r = c.get("acme", "/?fn=secret&id=u_gamma")
        check("sealed write → 200", r.status == 200 and "readback:" in r.body,
              f"got {r.status} {r.body!r}")
        check("the handler reads its own value back as PLAINTEXT",
              "readback:tuna-casserole-9f3a" in r.body, f"got {r.body!r}")

        marker = b"tuna-casserole-9f3a"
        on_disk = []
        for d in c.data_dirs:
            for f in d.rglob("*"):
                if not f.is_file():
                    continue
                try:
                    if marker in f.read_bytes():
                        on_disk.append(str(f))
                except OSError:
                    pass
        check("the plaintext is NOWHERE on disk", not on_disk,
              f"found in {on_disk[:3]}")

        # CONTROL. Without it, "not found on disk" is equally consistent
        # with a grep that cannot find anything — wrong directory, value
        # not flushed yet, compressed page. So write an UNSEALED value
        # through the same path and require that the grep DOES find it.
        # Only if this passes does the assertion above mean sealing.
        r = c.get("acme", "/?fn=plain")
        check("control write → 200", r.status == 200, f"got {r.status} {r.body!r}")
        control = b"pilchard-control-2b7e"
        found_control = []
        for d in c.data_dirs:
            for f in d.rglob("*"):
                if not f.is_file():
                    continue
                try:
                    if control in f.read_bytes():
                        found_control.append(str(f))
                except OSError:
                    pass
        check("CONTROL: an unsealed value IS findable on disk",
              bool(found_control),
              "the grep found nothing at all, so the check above proves nothing"
              if not found_control else f"found in {len(found_control)} file(s)")

        print("step 8: an empty id is refused, not read as 'no identity'")
        r = c.get("acme", "/?fn=badId")
        check("shredKey('') throws TypeError", "refused:TypeError" in r.body,
              f"got {r.status} {r.body!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
