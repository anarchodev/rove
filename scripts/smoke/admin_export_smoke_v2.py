#!/usr/bin/env python3
"""Cross-tenant export start (rove#340) — the dashboard's mechanism: an
`__admin__` handler starts an export FOR a customer tenant via
`@rewind/export.forScope(platform.scope(T))`, and the durable wake those two
kv writes arm fires PROMPTLY on the target's group leader.

The regression under test is the wake-spine fix. A `platform.scope(t).kv`
write of `_sched/` rows rides the batch's TARGET envelope, which used to arm
nothing anywhere: the export existed in kv but slept until the target's next
leadership transition — potentially forever on a quiet cluster. Two halves
close it, and this smoke's deadline is what distinguishes "armed live" from
"recovered eventually":

  - `Cmd.target_sched_wake` on the PROPOSING node (worker_dispatch →
    noteCommittedSchedWrites), the only half that exists on a single node;
  - the apply observer's `_sched/by_time/` branch (rewind/main.zig) on
    whichever OTHER node leads the target's group.

Phase A (nodes=1) pins the proposing-node half deterministically. Phase B
(nodes=3) hunts the cross-node half: several targets, pick one whose group
leader differs from `__admin__`'s. Best-effort — if every target co-elects
with admin it says so loudly and the run still asserts the prompt start.

Phase A's target carries a deployment, so the artifact also exercises the
format-2 code slice END TO END from a cross-tenant start: the bundle part is
the deployment manifest, and a manifest entry's hash downloads through the
scoped `fileUrl` presign.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

SEEDED = 40

# The target's own (trivial) app — gives the tenant a deployment, which is
# what makes the bundle phase reachable and matches reality: every
# provisioned instance has one (the starter deploy).
TARGET_SRC = 'export default function () { return "hi"; }\n'

# The __admin__ probe — the dashboard's server-side shape, verbatim: seed the
# target through the scoped kv, start/poll/link through the scoped export
# verbs. `?t=` names the target so one probe serves every phase.
PROBE_SRC = """\
import exp from "@rewind/export";
function _param(name) {
    for (const pair of (request.query || "").split("&")) {
        const eq = pair.indexOf("=");
        if (eq > 0 && pair.slice(0, eq) === name) return decodeURIComponent(pair.slice(eq + 1));
    }
    return "";
}
function _scoped() { return exp.forScope(platform.scope(_param("t"))); }
export function seedx() {
    const n = parseInt(_param("n") || "0", 10);
    const skv = platform.scope(_param("t")).kv;
    for (let i = 0; i < n; i++) skv.set("data/" + String(i).padStart(4, "0"), "value-" + i);
    return "seeded:" + n;
}
export function xstart() {
    return _scoped().start();
}
export function xget() {
    const st = _scoped().get(_param("id"));
    if (!st) return "none";
    if (st.state === "done") st.links = _scoped().links(_param("id"));
    return JSON.stringify(st);
}
export function xfileurl() {
    return platform.scope(_param("t")).blob.fileUrl(_param("h"));
}
"""


def _drive_export(c, check, fn, target, *, deadline_s, label):
    """Start an export on `target` through the admin probe and poll it to
    `done` inside `deadline_s` — the deadline IS the live-arm assertion."""
    r = fn(f"xstart&t={target}")
    export_id = r.body.strip()
    check(f"{label}: forScope(scope).start() → an id",
          r.status == 200 and len(export_id) > 10, f"got {r.status} {r.body!r}")

    started = time.time()
    state = None
    while time.time() - started < deadline_s:
        rr = fn(f"xget&t={target}&id={export_id}")
        if rr.status == 200 and rr.body.strip().startswith("{"):
            try:
                state = json.loads(rr.body)
            except ValueError:
                state = None
            if state and state.get("state") in ("done", "failed"):
                break
        time.sleep(0.5)
    elapsed = time.time() - started
    check(f"{label}: export reached done within {deadline_s:.0f}s "
          f"(live wake arm, not promotion-pass luck)",
          bool(state) and state.get("state") == "done",
          f"state={(state or {}).get('state')} after {elapsed:.1f}s "
          f"error={(state or {}).get('error')}")
    return export_id, state


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    # ── Phase A: single node — the proposing-node half, deterministically ──
    print("phase A: nodes=1 — Cmd.target_sched_wake (the proposing-node half)")
    with V2Cluster.spawn("adminexp1", nodes=1) as c:
        target = "expa-target"
        c._ensure_admin_app()
        r = c.provision(target)
        check("provision target → 200", r.status == 200, f"got {r.status} {r.body!r}")
        dep = c.deploy_handlers(target, {"index.mjs": TARGET_SRC})
        check("deploy target app", bool(dep), f"dep_id={dep}")
        pkgs, imports = c.firstparty_packages(["@rewind/export"])
        dep2 = c.deploy_with_packages("__admin__", {"index.mjs": rpc_wrap(PROBE_SRC)}, pkgs, imports)
        check("deploy admin probe", bool(dep2), f"dep_id={dep2}")
        c.wait_for_handler("__admin__", f"/?fn=xget&t={target}&id=zz", want_status=200)

        def fn(q):
            return c.get("__admin__", f"/?fn={q}")

        r = fn(f"seedx&t={target}&n={SEEDED}")
        check("seed target through scope.kv", "seeded" in r.body, f"got {r.status} {r.body!r}")

        export_id, state = _drive_export(c, check, fn, target,
                                         deadline_s=30, label="A")
        if not state or state.get("state") != "done":
            c.dump_node_log(0, grep=["kv-export", "sched", "error"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        parts = state.get("parts") or []
        kv_parts = [p for p in parts if p.get("kind") != "bundle"]
        bundle_parts = [p for p in parts if p.get("kind") == "bundle"]
        check("A: kv parts present", len(kv_parts) >= 1, f"parts={parts}")
        check(f"A: the walk covered the {SEEDED} seeded keys",
              state.get("entries", 0) >= SEEDED, f"entries={state.get('entries')}")
        check("A: exactly one bundle part (the target HAS a deployment)",
              len(bundle_parts) == 1, f"parts={parts}")
        check("A: marker records which deployment the code slice captured",
              isinstance((state.get("bundle") or {}).get("dep_id"), str)
              and len(state["bundle"]["dep_id"]) == 16,
              f"bundle={state.get('bundle')}")

        links = state.get("links") or []
        check("A: a presigned link per part", len(links) == len(parts),
              f"links={len(links)} parts={len(parts)}")

        # The kv part downloads and contains the seeded data.
        proc = subprocess.run(["curl", "-sS", "--fail-with-body", links[0]],
                              capture_output=True, text=True, timeout=60)
        check("A: GET kv part → 200", proc.returncode == 0,
              f"rc={proc.returncode} {proc.stderr[:120]}")
        check("A: the kv part carries the seeded keys",
              '"data/0007"' in proc.stdout and '"value-7"' in proc.stdout,
              proc.stdout[:120])
        # The job's own `_export/{id}` record is excluded from its own walk.
        # Keyed on the parsed KEYS — the `_sched/by_id/` watchdog row's VALUE
        # legitimately contains the marker key as its idempotency key.
        marker_keys = [json.loads(ln)["key"] for ln in proc.stdout.splitlines()
                       if ln.strip()]
        check("A: the job's own marker is not in the artifact",
              not any(k.startswith("_export/") for k in marker_keys), "")

        # The bundle part IS the deployment manifest; a manifest entry's hash
        # downloads through the scoped fileUrl — the pointers are real.
        bi = parts.index(bundle_parts[0])
        proc = subprocess.run(["curl", "-sS", "--fail-with-body", links[bi]],
                              capture_output=True, text=True, timeout=60)
        check("A: GET bundle part → 200", proc.returncode == 0,
              f"rc={proc.returncode} {proc.stderr[:120]}")
        manifest = {}
        try:
            manifest = json.loads(proc.stdout)
        except ValueError:
            pass
        entries = manifest.get("entries") or []
        check("A: the bundle part parses as the deploy manifest with entries",
              any(e.get("path") == "index.mjs" for e in entries),
              proc.stdout[:160])
        src_entry = next((e for e in entries if e.get("path") == "index.mjs"), None)
        if src_entry:
            r = fn(f"xfileurl&t={target}&h={src_entry['hash']}")
            check("A: scoped fileUrl mints a link for a manifest hash",
                  r.status == 200 and r.body.strip().startswith("http"),
                  f"got {r.status} {r.body[:100]!r}")
            proc = subprocess.run(["curl", "-sS", "--fail-with-body", r.body.strip()],
                                  capture_output=True, text=True, timeout=60)
            check("A: the fileUrl link returns the DEPLOYED SOURCE bytes",
                  proc.returncode == 0 and proc.stdout == TARGET_SRC,
                  f"rc={proc.returncode} got={proc.stdout[:80]!r}")

    # ── Phase B: three nodes — the cross-node apply-observer half ──────────
    print("phase B: nodes=3 — the apply observer arms the wake on the "
          "target's group leader")
    with V2Cluster.spawn("adminexp3", nodes=3) as c:
        c._ensure_admin_app()
        # Provision + deploy every candidate BEFORE the probe replaces
        # __admin__'s standing deploy app — after that, no deploy path exists.
        provisioned = []
        for i in range(5):
            t = f"expb-t{i}"
            r = c.provision(t)
            if r.status != 200:
                continue
            c.deploy_handlers(t, {"index.mjs": TARGET_SRC})
            provisioned.append(t)
        check("B: candidate targets provisioned", len(provisioned) >= 2,
              f"provisioned={provisioned}")

        pkgs, imports = c.firstparty_packages(["@rewind/export"])
        dep = c.deploy_with_packages("__admin__", {"index.mjs": rpc_wrap(PROBE_SRC)}, pkgs, imports)
        check("B: deploy admin probe", bool(dep), f"dep_id={dep}")
        c.wait_for_handler("__admin__", "/?fn=xget&t=nope&id=zz", want_status=200)

        admin_leader = c.leader_node("__admin__")
        check("B: __admin__ elected a leader", admin_leader is not None,
              f"leader={admin_leader}")

        # Hunt a target whose group leads on a DIFFERENT node than admin's —
        # that is the placement where the pre-fix bug was absolute (nothing on
        # the proposing node could arm the target's watermark).
        divergent = None
        candidates = []
        for t in provisioned:
            lt = c.leader_node(t)
            candidates.append((t, lt))
            if lt is not None and admin_leader is not None and lt != admin_leader:
                divergent = t
                break
        if divergent is None:
            print(f"  WARN: no divergent-leader target found "
                  f"(admin={admin_leader}, candidates={candidates}) — "
                  f"the cross-node half is untested THIS RUN; asserting the "
                  f"prompt start on the last target anyway")
            target = candidates[-1][0] if candidates else None
        else:
            print(f"  divergent placement: __admin__ leads on node "
                  f"{admin_leader}, {divergent} on {dict(candidates)[divergent]}")
            target = divergent
        check("B: a provisioned target exists", target is not None,
              f"candidates={candidates}")
        if target is None:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        def fnb(q):
            return c.get("__admin__", f"/?fn={q}")

        r = fnb(f"seedx&t={target}&n={SEEDED}")
        check("B: seed target through scope.kv", "seeded" in r.body,
              f"got {r.status} {r.body!r}")

        _, state = _drive_export(c, check, fnb, target, deadline_s=45,
                                 label="B")
        if state and state.get("state") == "done":
            check(f"B: the walk covered the {SEEDED} seeded keys",
                  state.get("entries", 0) >= SEEDED,
                  f"entries={state.get('entries')}")
        else:
            for i in range(3):
                c.dump_node_log(i, grep=["kv-export", "sched", "error"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS admin-export smoke (v2) — a cross-tenant start arms the "
          "target's durable wake LIVE on both placements, and the artifact's "
          "code slice downloads through the scoped presigns")
    return 0


if __name__ == "__main__":
    sys.exit(main())
