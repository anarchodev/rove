#!/usr/bin/env python3
"""Off-provider backup + tested restore (rove#341; `rewind-backup`).

Three raft nodes in one datacenter is replication, not backup — raft
faithfully replicates a bad apply, an operator mistake, and a delete a
customer regrets. The answer is a copy in a store the cluster's own
credentials do not reach, and the only backup worth having is one that has
been RESTORED: this drives the real tool against a real cluster, then
restores into a SECOND cluster that shares no data directory with the first
and reads the value back.

The two clusters here share an S3 provider, because a test cannot have a
second one. That is the honest limit of this smoke: "off-provider" is a
property of which credentials `BACKUP_S3_*` carries in production, and what
the code knows is only that the backup target is a SEPARATE store with its
own config — which is the part a test can check, by pointing it at a prefix
the cluster never writes to.

Proof legs:
  A. a tenant's committed kv pair is backed up, and the run verifies —
     size, sha256, and a well-formed snapshot-stream header.
  B. a run whose tenant does not exist FAILS and writes NO manifest: a
     manifest is the claim that a set is restorable, and a partial run has
     no business making it.
  C. the backup restores into a fresh cluster and the value reads back —
     attached under the INCARNATION the manifest records, because that is
     what the pairs are addressed by.
  D. restoring into a group attached under a DIFFERENT incarnation is
     REFUSED (409), not accepted-and-empty. Before the guard this returned
     204 and read back 404: a restore that reported success and put the data
     where nothing reads.
  E. `verify` of a run that was never taken FAILS — an unverified backup is
     a belief, not a control, and a verifier that cannot fail is neither.

Build first: `zig build smoke-bins && zig build rewind-backup`
"""

import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from smoke_lib_v2 import V2Cluster, MOVE_SECRET, attach_join, BIN_DIR  # noqa: E402

BACKUP_BIN = os.path.join(BIN_DIR, "rewind-backup")

TENANT = "acme"
KEY = "greeting"
VALUE = "hello-from-the-backup"
RUN_ID = f"smoke{os.getpid()}"


def curl(args):
    out = subprocess.run(["curl", "-s", "-w", "\n%{http_code}", "-m", "30",
                          "--http2-prior-knowledge"] + args,
                         capture_output=True, text=True).stdout
    nl = out.rfind("\n")
    return (int(out[nl + 1:].strip() or 0), out[:nl])


def kv_put(node, tenant, key, value):
    return curl(["-X", "PUT", f"{node}/_system/v2-kv",
                 "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
                 "-H", "Content-Type: application/json",
                 "--data", json.dumps({"tenant": tenant, "key": key, "value": value})])[0]


def kv_get(node, tenant, key):
    return curl([f"{node}/_system/v2-kv?tenant={tenant}&key={key}",
                 "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}"])


def backup_tool(*args):
    """Run `rewind-backup`, tee'ing its output. Returns (rc, output)."""
    p = subprocess.run([BACKUP_BIN, *args], capture_output=True, text=True, timeout=300)
    out = (p.stdout or "") + (p.stderr or "")
    for line in out.strip().splitlines():
        print(f"    | {line}")
    return p.returncode, out


def main():
    if not os.path.exists(BACKUP_BIN):
        raise SystemExit(f"{BACKUP_BIN} not found — run `zig build rewind-backup`")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")

    # The backup target: the same provider (a test has one), a prefix the
    # clusters never touch, and its OWN env vars — which is what the worker
    # and the tool both read. In production these carry another provider's
    # endpoint and another account's keys; nothing in the code knows the
    # difference, which is the point.
    os.environ["BACKUP_S3_ENDPOINT"] = os.environ["S3_ENDPOINT"]
    os.environ["BACKUP_S3_REGION"] = os.environ["S3_REGION"]
    os.environ["BACKUP_S3_BUCKET"] = os.environ["S3_BUCKET"]
    os.environ["BACKUP_S3_KEY_PREFIX_BASE"] = f"backupsmoke-{os.getpid()}/"
    os.environ["BACKUP_S3_USE_TLS"] = os.environ.get("S3_USE_TLS", "1")
    os.environ["BACKUP_AWS_ACCESS_KEY_ID"] = os.environ["AWS_ACCESS_KEY_ID"]
    os.environ["BACKUP_AWS_SECRET_ACCESS_KEY"] = os.environ["AWS_SECRET_ACCESS_KEY"]
    os.environ["REWIND_MOVE_SECRET"] = MOVE_SECRET

    failures = []

    def check(label, got, want):
        ok = got == want
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} (== {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}, want {want!r}")

    with V2Cluster.spawn("bkup", nodes=1) as a:
        a.provision(TENANT, host=f"{TENANT}.a.localhost")
        check("kv put on the source cluster", kv_put(a.node_url(0), TENANT, KEY, VALUE), 204)

        print("leg A: back the tenant up, then verify the run")
        rc, _ = backup_tool("run", "--nodes", a.node_url(0),
                            "--tenants", TENANT, "--run-id", RUN_ID)
        check("backup run", rc, 0)
        rc, out = backup_tool("verify", "--run", RUN_ID)
        check("verify", rc, 0)
        check("verify names the tenant", f"ok {TENANT}" in out, True)

        print("leg B: a run covering a tenant that does not exist writes no manifest")
        rc, out = backup_tool("run", "--nodes", a.node_url(0),
                             "--tenants", "no-such-tenant", "--run-id", f"{RUN_ID}-partial")
        check("partial run fails", rc != 0, True)
        check("says no manifest was written", "no manifest written" in out, True)
        rc, _ = backup_tool("verify", "--run", f"{RUN_ID}-partial")
        check("verify of the partial run fails", rc != 0, True)

    # A SECOND cluster: its own data dirs, its own raft state, no knowledge
    # of the first. The only thing crossing between them is the object.
    # The manifest is what a restore reads: it carries the incarnation the
    # tenant's pairs are addressed by, which nothing else on the destination
    # side can work out.
    rc, manifest_json = backup_tool("show", "--run", RUN_ID)
    check("show", rc, 0)
    # The tool tees S3 debug lines to stderr; the manifest is the JSON line.
    manifest_line = next(l for l in manifest_json.splitlines() if l.startswith("{"))
    entry = json.loads(manifest_line)["tenants"][0]
    incarnation = entry["incarnation"]
    print(f"  manifest says incarnation={incarnation}")

    with V2Cluster.spawn("bkdst", nodes=1) as b:
        print("leg D: a destination attached under the WRONG incarnation is refused")
        check("attach under a foreign incarnation",
              attach_join(f"{b.node_url(0)}/_system/v2-attach", tenant=TENANT,
                          incarnation="0000000000000000"), "204")
        rc, out = backup_tool("restore", "--run", RUN_ID,
                              "--tenant", TENANT, "--nodes", b.node_url(0))
        check("restore into the wrong lifetime fails", rc != 0, True)
        check("refused with 409", "409" in out, True)
        check("nothing was written", kv_get(b.node_url(0), TENANT, KEY)[0], 404)

    with V2Cluster.spawn("bkgood", nodes=1) as b:
        print("leg C: restore into a fresh cluster and read the value back")
        check("attach the tenant under the recorded incarnation",
              attach_join(f"{b.node_url(0)}/_system/v2-attach", tenant=TENANT,
                          incarnation=incarnation), "204")
        check("the destination has no data yet",
              kv_get(b.node_url(0), TENANT, KEY)[0], 404)
        rc, _ = backup_tool("restore", "--run", RUN_ID,
                            "--tenant", TENANT, "--nodes", b.node_url(0))
        check("restore", rc, 0)
        st, body = kv_get(b.node_url(0), TENANT, KEY)
        check("restored value reads back", (st, body), (200, VALUE))

        print("leg E: verifying a run nobody took must FAIL")
        rc, _ = backup_tool("verify", "--run", "run-that-never-happened")
        check("verify of a missing run fails", rc != 0, True)

    if failures:
        print(f"\nFAILED ({len(failures)}):")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nbackup/restore smoke: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
