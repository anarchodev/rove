#!/usr/bin/env python3
"""V2 port of `s3_blob_smoke.py` — exercise rove-blob's `S3BlobStore`
against a real S3 endpoint.

This smoke is INFRA-LEVEL and stack-agnostic: it exec's the `s3-blob-smoke`
Zig binary (`examples/s3_blob_smoke.zig`), which drives `rove-blob`'s
`S3BlobStore` directly (exists / put / get / overwrite / delete /
idempotent-delete) against the configured bucket. It does NOT use
`loop46`, the worker, the CP/front door, or any per-tenant raft group — so
there is nothing `loop46`-coupled to migrate. `rove-blob` is the SAME
module V2 (`rewind`) links for its content-addressed blob backend, so this
smoke validates the exact storage primitive V2 depends on, unchanged.

It is therefore identical to the V1 smoke; this `_v2.py` exists only so the
V2 suite is name-complete. Reads `.env` at repo root for AWS / S3_* env
vars (`set -a; . ./.env; set +a` first, or rely on the in-script loader).

Build: `zig build s3-blob-smoke` (binary at zig-out/bin/s3-blob-smoke).
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import BIN_DIR, _load_dotenv  # noqa: E402


def main() -> int:
    _load_dotenv()
    for var in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "S3_BUCKET"):
        if not os.environ.get(var):
            sys.exit(f"error: {var} is required (source the repo .env first)")

    os.environ.setdefault("S3_ENDPOINT", "s3.gra.io.cloud.ovh.net")
    os.environ.setdefault("S3_REGION", "gra")
    os.environ.setdefault("S3_KEY_PREFIX", "")

    bin_path = BIN_DIR / "s3-blob-smoke"
    if not bin_path.exists():
        sys.exit(f"error: {bin_path} missing — run `zig build s3-blob-smoke`")

    print(f"targeting {os.environ['S3_ENDPOINT']} (region {os.environ['S3_REGION']}) "
          f"bucket {os.environ['S3_BUCKET']}")
    return subprocess.call([str(bin_path)])


if __name__ == "__main__":
    sys.exit(main())
