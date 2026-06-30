#!/usr/bin/env python3
"""Exercise rove-blob's S3BlobStore against a real S3 endpoint.

Python port of `scripts/s3_blob_smoke.sh`. Reads .env at repo root for
AWS / S3_* env vars and exec's the s3-blob-smoke binary.
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
            sys.exit(f"error: {var} is required")

    os.environ.setdefault("S3_ENDPOINT", "s3.gra.io.cloud.ovh.net")
    os.environ.setdefault("S3_REGION", "gra")
    os.environ.setdefault("S3_KEY_PREFIX", "")

    bin_path = BIN_DIR / "s3-blob-smoke"
    if not bin_path.exists():
        sys.exit(f"error: {bin_path} missing")

    print(f"targeting {os.environ['S3_ENDPOINT']} (region {os.environ['S3_REGION']}) bucket {os.environ['S3_BUCKET']}")
    return subprocess.call([str(bin_path)])


if __name__ == "__main__":
    sys.exit(main())
