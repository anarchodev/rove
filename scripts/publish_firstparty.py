#!/usr/bin/env python3
"""publish_firstparty.py — deploy the first-party tenants from web/manifest.json.

This is the FIRST-PARTY tenant driver. It reads a declarative manifest of the
operator's own tenants (tenant id, source dir, host(s)) and drives the
`rewind-ops` operator CLI to provision + deploy + release + host-map each one.
The engine has no built-in knowledge of these tenants — point this at your own
manifest + content dirs and the same driver stands up YOUR first-party tenants
on YOUR cluster.

Where this sits in the deploy surface:
  - scripts/deploy.sh / the /deploy skill  — platform BINARIES (rewind/-cp/-front)
  - rewind-ops <verb>                       — the per-operation primitives
  - THIS                                    — composes those verbs per manifest entry

For each manifest tenant the driver runs, in order:
  1. provision   (if `provision` is true) — `rewind-ops provision <tenant>
                 --cluster <c> [--host hosts[0]]`. Idempotent: 409/already-placed
                 is fine.
  2. deploy      — `rewind-ops deploy <tenant> web/<dir> [--release]` (classify +
                 stage + optional release flip, all in the one CLI call).
  3. host add    — `rewind-ops host add <h> <tenant>` for every host past hosts[0]
                 (hosts[0] is already mapped by provision --host).

Secrets come from the same env file rewind-ops reads
(~/.config/rove/prod.env, then ./.env.prod); pass --env to override and it is
forwarded to every rewind-ops call.

Usage:
  scripts/publish_firstparty.py                    # every operator tenant
  scripts/publish_firstparty.py marketing docs     # only these (any kind)
  scripts/publish_firstparty.py --include-examples # operator + example tenants
  scripts/publish_firstparty.py --dry-run          # print the rewind-ops calls only
  scripts/publish_firstparty.py --no-release       # stage but don't flip live
  scripts/publish_firstparty.py --ops-bin ./zig-out/bin/rewind-ops --env ./.env.prod
"""
import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
# First-party app content (manifest.json + the per-tenant dirs). This driver is
# operator-neutral and ships in the engine repo; the CONTENT lives in the
# operator's own repo. Point it via --apps-dir or REWIND_APPS_DIR; falls back to
# ./web for an operator who keeps apps in-repo. (rewindjs: ~/src/rewind-apps.)
WEB = pathlib.Path(os.environ.get("REWIND_APPS_DIR") or (REPO / "web"))


def load_manifest(path: pathlib.Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        sys.exit(f"manifest not found: {path}")
    except json.JSONDecodeError as e:
        sys.exit(f"manifest {path}: invalid JSON: {e}")
    if not isinstance(data.get("tenants"), list):
        sys.exit(f"manifest {path}: missing top-level 'tenants' array")
    return data


def resolve_ops_bin(explicit: str | None) -> str:
    """Locate rewind-ops: --ops-bin, then zig-out/bin, then PATH."""
    if explicit:
        if not pathlib.Path(explicit).exists():
            sys.exit(f"--ops-bin {explicit}: not found")
        return explicit
    built = REPO / "zig-out" / "bin" / "rewind-ops"
    if built.exists():
        return str(built)
    found = shutil.which("rewind-ops")
    if found:
        return found
    sys.exit("rewind-ops not found — build it (`zig build rewind-ops`) or pass --ops-bin")


def run_ops(ops_bin: str, env_path: str | None, *args: str, dry_run: bool) -> None:
    cmd = [ops_bin, *args]
    if env_path:
        cmd += ["--env", env_path]
    printable = " ".join(cmd)
    if dry_run:
        print(f"    [dry-run] {printable}")
        return
    print(f"    $ {printable}")
    r = subprocess.run(cmd)
    if r.returncode != 0:
        sys.exit(f"rewind-ops failed (exit {r.returncode}): {printable}")


def publish_tenant(t: dict, defaults: dict, ops_bin: str, env_path: str | None,
                   release_override: bool | None, dry_run: bool) -> None:
    tenant = t.get("tenant") or sys.exit(f"manifest entry missing 'tenant': {t}")
    src = t.get("dir") or sys.exit(f"tenant {tenant}: missing 'dir'")
    bundle = WEB / src
    if not bundle.is_dir():
        sys.exit(f"tenant {tenant}: source dir {bundle} not found")

    hosts = t.get("hosts") or []
    cluster = t.get("cluster") or defaults.get("cluster", "prod")
    release = release_override if release_override is not None \
        else t.get("release", defaults.get("release", True))

    print(f"\n== {tenant}  ({WEB.name}/{src} → {', '.join(hosts) or '<no custom host>'})")

    # 1. provision (idempotent — rewind-ops treats 409/already-placed as success)
    if t.get("provision", True):
        prov = ["provision", tenant, "--cluster", cluster]
        if hosts:
            prov += ["--host", hosts[0]]
        run_ops(ops_bin, env_path, *prov, dry_run=dry_run)

    # 2. deploy (+ release flip)
    deploy = ["deploy", tenant, str(bundle)]
    if release:
        deploy.append("--release")
    run_ops(ops_bin, env_path, *deploy, dry_run=dry_run)

    # 3. additional hosts (hosts[0] already mapped by provision --host)
    extra_hosts = hosts[1:] if t.get("provision", True) else hosts
    for h in extra_hosts:
        run_ops(ops_bin, env_path, "host", "add", h, tenant, dry_run=dry_run)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tenants", nargs="*",
                    help="tenant ids to publish (default: every 'operator' tenant). "
                         "Naming a tenant publishes it regardless of kind.")
    ap.add_argument("--apps-dir", type=pathlib.Path, default=None,
                    help="first-party app content root (manifest.json + dirs); "
                         "default $REWIND_APPS_DIR or ./web")
    ap.add_argument("--manifest", type=pathlib.Path, default=None,
                    help="manifest path (default: <apps-dir>/manifest.json)")
    ap.add_argument("--env", default=None,
                    help="operator env file forwarded to rewind-ops "
                         "(default: rewind-ops' own ~/.config/rove/prod.env)")
    ap.add_argument("--ops-bin", default=None,
                    help="path to rewind-ops (default: zig-out/bin/rewind-ops, then PATH)")
    ap.add_argument("--include-examples", action="store_true",
                    help="also publish kind=='example' tenants")
    ap.add_argument("--no-release", dest="release", action="store_false", default=None,
                    help="stage the deploy but do not flip _deploy/current live")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the rewind-ops calls without running them")
    args = ap.parse_args()

    global WEB
    if args.apps_dir:
        WEB = args.apps_dir
    manifest_path = args.manifest or (WEB / "manifest.json")
    manifest = load_manifest(manifest_path)
    defaults = manifest.get("defaults", {})
    all_tenants = manifest["tenants"]
    by_id = {t.get("tenant"): t for t in all_tenants}

    if args.tenants:
        selected = []
        for name in args.tenants:
            if name not in by_id:
                sys.exit(f"unknown tenant '{name}' — manifest has: "
                         f"{', '.join(sorted(t for t in by_id if t))}")
            selected.append(by_id[name])
    else:
        selected = [t for t in all_tenants
                    if t.get("kind", "operator") == "operator"
                    or (args.include_examples and t.get("kind") == "example")]

    if not selected:
        print("no tenants selected (operator tenants only by default; "
              "pass names or --include-examples)")
        return 0

    ops_bin = resolve_ops_bin(args.ops_bin)
    print(f"driver: {len(selected)} tenant(s) via {ops_bin}"
          + (" [dry-run]" if args.dry_run else ""))
    for t in selected:
        publish_tenant(t, defaults, ops_bin, args.env, args.release, args.dry_run)

    print(f"\ndone: published {len(selected)} tenant(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
