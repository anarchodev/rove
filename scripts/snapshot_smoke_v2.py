#!/usr/bin/env python3
"""V2 snapshot smoke (port of `scripts/snapshot_smoke.py`).

STATUS: SKIP — the V1 mechanism this smoke exercises is willemt-raft-internal
and has NO V2 analog at this layer. There is no V2 precondition to prove, so
this is a pure SKIP with a precise reason (no cluster is spawned).

The V1 smoke tested the willemt-raft SNAPSHOT machinery end to end:

  1. `loop46 snapshot --apply-position N --willemt-term T` captures a snapshot
     and `loop46 restore-from-snapshot` installs it into a fresh data dir
     (offline operator CLI on the retired `loop46` binary).
  2. A worker spawned with `--snapshot-interval-ms` runs a periodic
     raft-THREAD capture loop ("snapshot tick apply_position=… duration_ms=…").
  3. `raft.log.db` — the willemt-raft SQLite log — is COMPACTED (bounded row
     count + file size + `auto_vacuum=INCREMENTAL`) after the snapshot.
  4. The durable raft idx in `cluster.kv` keeps up with the tick apply_position.

Every one of those assertions is V1-raft-internal with no V2 equivalent:

  * `loop46` is RETIRED on V2 — there is no `snapshot` / `restore-from-snapshot`
    / `seed` / `kv-get` subcommand. The V2 runtime binary is `rewind`.
  * V2 has NO willemt raft. Per-tenant consensus is raft-rs (TiKV) behind the
    `Bridge`, one group per tenant — there is no `raft.log.db` SQLite log to
    compact, no `--snapshot-interval-ms` raft-thread capture loop, and no
    `--apply-position` / `--willemt-term` snapshot file. The compaction +
    auto_vacuum + apply-position assertions reference structures that do not
    exist on V2.
  * Tenant state on V2 moves via the kvexp bundle dump/load (the tenant-MOVE
    path: `Manager.createGroupEpoch` at a migration fence + a fresh raft group
    on the destination), NOT via a V1 willemt snapshot file. raft-rs manages
    its own internal log compaction inside the Rust engine; rove neither
    drives it from a CLI nor asserts on its on-disk form.

The OBSERVABLE essence the V1 snapshot mechanism ultimately served — "a
lagging/rejoined node catches up to the replicated state" — is the subject of
a SEPARATE V2 port, `scripts/snap_catchup_smoke_v2.py`, which proves the
catchup precondition and SKIPs the rejoin-catchup step on the known
boot-time-group-recovery engine gap. There is nothing left for THIS smoke to
assert on V2: the raft-internal snapshot-FILE / log-compaction layer it tested
simply does not exist here.

Confirming a SKIP needs no cluster — this script asserts nothing and spawns
nothing.
"""

from __future__ import annotations

import sys


def main() -> int:
    print("SKIP snapshot smoke (v2) — no V2 analog at this layer.")
    print()
    print("The V1 smoke tested willemt-raft-internal machinery that V2 does not have:")
    print("  - `loop46 snapshot` / `restore-from-snapshot` — `loop46` is RETIRED on V2")
    print("    (the V2 runtime binary is `rewind`; no snapshot/restore/seed/kv-get CLI).")
    print("  - `raft.log.db` compaction (rows + file size + auto_vacuum=INCREMENTAL) —")
    print("    V2 has no willemt raft + no SQLite raft log; consensus is raft-rs")
    print("    (one group per tenant) behind the Bridge, which manages its own")
    print("    internal log compaction inside the Rust engine (not CLI-driven,")
    print("    not asserted on-disk).")
    print("  - `--snapshot-interval-ms` raft-thread capture + `--apply-position` /")
    print("    `--willemt-term` snapshot files — none of these structures exist on V2.")
    print()
    print("V2 tenant state moves via the kvexp bundle dump/load (the tenant-MOVE")
    print("path: fresh raft group at a migration fence), NOT a willemt snapshot file.")
    print("The observable 'lagging node catches up' story is ported separately in")
    print("scripts/snap_catchup_smoke_v2.py (which SKIPs its final step on the known")
    print("boot-time group-recovery engine gap). This smoke has no remaining V2")
    print("precondition to assert.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
