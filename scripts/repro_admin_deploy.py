#!/usr/bin/env python3
"""Repro: deploy the FULL web/admin bundle (handlers + _static/) through the
genesis /v1/deploy path — the path prod uses. The oidc_rp smoke only ever
deployed web/admin's 4 handler .mjs files (deploy_handlers), never the static
bundle, so this size/shape was never exercised locally."""
import base64
import mimetypes
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from smoke_lib_v2 import V2Cluster, REPO_ROOT  # noqa: E402


def classify(root: Path):
    files = []
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        rel = str(p.relative_to(root))
        if rel == "codemirror-entry.mjs":
            continue
        b = p.read_bytes()
        if rel.startswith("_static/") or rel.startswith("_config/"):
            kind, ct = "static", (mimetypes.guess_type(rel)[0] or "application/octet-stream")
        elif rel.endswith(".mjs"):
            kind, ct = "handler", ""
        else:
            continue
        files.append({"path": rel, "kind": kind, "content_type": ct,
                      "b64": base64.b64encode(b).decode()})
    return files


def main() -> int:
    full = classify(REPO_ROOT / "web/admin")
    nostatic = [f for f in full if f["kind"] == "handler"]
    nocm = [f for f in full if f["path"] != "_static/codemirror.mjs"]
    handlers = nostatic
    one_css = nostatic + [f for f in full if f["path"] == "_static/app.css"]
    with V2Cluster.spawn("reproadmin", nodes=1, http_base=19980, raft_base=20080) as c:
        c._ensure_admin_app()
        # Each case is the FIRST deploy to a FRESH tenant — isolates the bundle
        # from cross-deploy accumulation. Ordered small→large.
        for label, files, tenant in [
            ("handlers + 1 static (app.css 16KB)", one_css, "r1"),
            ("no-codemirror (13 files, ~115KB)", nocm, "r2"),
            ("handlers-only (4 files)", handlers, "r3"),
            ("FULL web/admin (14 files, ~530KB)", full, "r4"),
        ]:
            c.provision(tenant)
            nbytes = sum(len(f["b64"]) for f in files)
            print(f"\n=== {label}: {len(files)} files, {nbytes} b64 bytes -> tenant {tenant} ===")
            try:
                dep = c.deploy_bundle(tenant, files)
                print(f"  DEPLOY OK dep_id={dep}")
            except Exception as e:
                print(f"  DEPLOY FAILED: {str(e)[:300]}")
                c.dump_node_log(grep=["deploy", "compile", "memory", "InternalError",
                                      "oom", "out of memory", "error", "warn", "park"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
