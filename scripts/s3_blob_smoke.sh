#!/usr/bin/env bash
# Exercise rove-blob's S3BlobStore against a real S3-compatible
# endpoint. Defaults configured for OVH Object Storage; works
# unchanged against AWS, MinIO, Cloudflare R2, Backblaze B2.
#
# Required env (no defaults — secrets):
#   AWS_ACCESS_KEY_ID
#   AWS_SECRET_ACCESS_KEY
#
# Optional env (sensible OVH defaults if unset):
#   S3_ENDPOINT       hostname only, no scheme (default
#                     s3.gra.io.cloud.ovh.net — OVH Gravelines
#                     high-performance tier)
#   S3_REGION         SigV4 signing region (default gra)
#   S3_BUCKET         bucket name (REQUIRED if not set; no default
#                     because every operator's bucket name differs)
#   S3_KEY_PREFIX     optional prefix to scope the smoke (default empty)
#
# Usage:
#   export AWS_ACCESS_KEY_ID=...
#   export AWS_SECRET_ACCESS_KEY=...
#   export S3_BUCKET=loop46-smoke
#   bash scripts/s3_blob_smoke.sh
#
# Other endpoints:
#   S3_ENDPOINT=s3.us-east-1.amazonaws.com S3_REGION=us-east-1 \
#   S3_BUCKET=mybucket bash scripts/s3_blob_smoke.sh

set -euo pipefail

BIN="${BIN:-./zig-out/bin/s3-blob-smoke}"

if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN missing — run 'zig build install' first" >&2
    exit 2
fi

if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
    echo "error: AWS_ACCESS_KEY_ID is required" >&2
    exit 2
fi
if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    echo "error: AWS_SECRET_ACCESS_KEY is required" >&2
    exit 2
fi
if [[ -z "${S3_BUCKET:-}" ]]; then
    echo "error: S3_BUCKET is required (no default)" >&2
    exit 2
fi

# OVH defaults — Gravelines high-performance tier. Override
# S3_ENDPOINT + S3_REGION for any other OVH region (de, uk, sgp,
# bhs, ...) or for AWS / MinIO / R2 / etc.
export S3_ENDPOINT="${S3_ENDPOINT:-s3.gra.io.cloud.ovh.net}"
export S3_REGION="${S3_REGION:-gra}"
export S3_KEY_PREFIX="${S3_KEY_PREFIX:-}"

echo "scripts/s3_blob_smoke.sh: targeting ${S3_ENDPOINT} (region ${S3_REGION}) bucket ${S3_BUCKET}"
exec "$BIN"
