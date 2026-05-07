#!/usr/bin/env bash
# End-to-end smoke test for the rove-files-server background thread.
#
# Spawns the `files-server-standalone` binary, reads the bound port off
# stdout, then drives upload / deploy / source / error paths via curl.
#
# Exits non-zero on any mismatch.

set -euo pipefail

if [[ -f .env ]]; then
    set -a
    # shellcheck source=/dev/null
    source .env
    set +a
fi

DATA_DIR="${DATA_DIR:-/tmp/rove-cs-smoke}"
BIN="${BIN:-./zig-out/bin/files-server-standalone}"

# Isolate S3 keys per run so static bytes uploaded by a prior run
# don't pre-fill the bucket and turn /blobs/check missing→present.
export S3_KEY_PREFIX_BASE="${S3_KEY_PREFIX_BASE:-smoke-files-server-$(hostname)-$(id -u)-$(date +%s)/}"

if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN not found — run 'zig build install' first" >&2
    exit 2
fi

rm -rf "$DATA_DIR"

# Per-run JWT secret. Standalone binary verifies; smoke mints
# matching test tokens. Uses the post-Task-#62 env name shared
# between the worker and every standalone service.
LOOP46_SERVICES_JWT_SECRET=$(head -c16 /dev/urandom | xxd -p | tr -d '\n')
export LOOP46_SERVICES_JWT_SECRET

"$BIN" --data-dir "$DATA_DIR" --listen 127.0.0.1:0 >/tmp/cs-smoke.out 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true' EXIT

# Wait for the "listening on" line.
for _ in $(seq 1 20); do
    if grep -q "listening on" /tmp/cs-smoke.out; then break; fi
    sleep 0.05
done
PORT=$(grep -oE 'port [0-9]+' /tmp/cs-smoke.out | awk '{print $2}')
if [[ -z "${PORT:-}" ]]; then
    echo "FAIL: files-server did not bind a port" >&2
    cat /tmp/cs-smoke.out >&2
    exit 1
fi
echo "files-server listening on port $PORT"

# Mint an HS256 JWT signed with $LOOP46_SERVICES_JWT_SECRET. 5-minute expiry.
mint_jwt() {
    LOOP46_SERVICES_JWT_SECRET="$LOOP46_SERVICES_JWT_SECRET" python3 - <<'PY'
import base64, hmac, hashlib, json, os, time
secret = bytes.fromhex(os.environ["LOOP46_SERVICES_JWT_SECRET"])
header = b'{"alg":"HS256","typ":"JWT"}'
payload = json.dumps({"exp": int(time.time() * 1000) + 5 * 60 * 1000}).encode()
def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
signing_input = b64u(header) + "." + b64u(payload)
sig = hmac.new(secret, signing_input.encode(), hashlib.sha256).digest()
print(signing_input + "." + b64u(sig))
PY
}
JWT=$(mint_jwt)
AUTH=(-H "Authorization: Bearer ${JWT}")

expect() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL $label: expected $expected, got $actual" >&2
        exit 1
    fi
    echo "ok  $label: $actual"
}

SOURCE='export function handler() { return "hi from smoke"; }'

# Upload a source file.
code=$(curl -s --http2-prior-knowledge "${AUTH[@]}" -o /dev/null -w '%{http_code}' \
    -X POST -H "X-Rove-Path: index.mjs" \
    --data-binary "$SOURCE" \
    "http://127.0.0.1:$PORT/acme/upload")
expect "upload /acme index.mjs" 204 "$code"

# Missing header → 400.
code=$(curl -s --http2-prior-knowledge "${AUTH[@]}" -o /dev/null -w '%{http_code}' \
    -X POST --data-binary 'x' \
    "http://127.0.0.1:$PORT/acme/upload")
expect "upload without header" 400 "$code"

# Deploy the working tree.
body=$(curl -s --http2-prior-knowledge "${AUTH[@]}" \
    -X POST \
    "http://127.0.0.1:$PORT/acme/deploy")
echo "ok  deploy /acme: id=$(echo "$body" | tr -d '\n')"
case "$body" in
    1*) : ;;
    *) echo "FAIL deploy expected id 1, got '$body'" >&2; exit 1 ;;
esac

# Source blobs are content-addressed, so the source hash is just
# sha256 of the upload bytes. Pre-S3, the smoke discovered this by
# grepping the local blob dir; that file no longer exists (blobs
# live in S3 now), so compute the hash directly.
SRC_BLOB=$(printf '%s' "$SOURCE" | sha256sum | awk '{print $1}')

# Fetch the source blob over HTTP.
code=$(curl -s --http2-prior-knowledge "${AUTH[@]}" -o /tmp/cs-src.out -w '%{http_code}' \
    "http://127.0.0.1:$PORT/acme/source/$SRC_BLOB")
expect "GET /source valid hash" 200 "$code"
if ! grep -q "hi from smoke" /tmp/cs-src.out; then
    echo "FAIL: fetched source does not match upload" >&2
    cat /tmp/cs-src.out >&2
    exit 1
fi
echo "ok  source bytes match"

# Source fetch with a bogus hash → 404.
code=$(curl -s --http2-prior-knowledge "${AUTH[@]}" -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$PORT/acme/source/00000000000000000000000000000000")
expect "GET /source bogus hash" 404 "$code"

# Unknown path → 404.
code=$(curl -s --http2-prior-knowledge "${AUTH[@]}" -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$PORT/unknown")
expect "GET /unknown" 404 "$code"

# ── Content-addressed two-phase flow ──────────────────────────────────
# Stage 1 of the new upload protocol: /blobs/check + PUT /blobs/{hash}.
# Stage 2 (/deployments) lands in a follow-up commit; this smoke just
# proves the upload half round-trips and hash verification fires on
# mismatch.

BYTES='hello blob storage'
HASH=$(printf '%s' "$BYTES" | sha256sum | awk '{print $1}')

# /blobs/check says the hash is missing + hands us an upload URL.
check=$(curl -s --http2-prior-knowledge "${AUTH[@]}" \
    -X POST -H "Content-Type: application/json" \
    --data-raw "{\"hashes\":[\"$HASH\"]}" \
    "http://127.0.0.1:$PORT/acme/blobs/check")
echo "$check" | grep -q "\"missing\":\[\"$HASH\"\]" \
    || { echo "FAIL blobs/check missing: $check" >&2; exit 1; }
echo "$check" | grep -q "\"url\":\"/v1/instances/acme/blobs/$HASH\"" \
    || { echo "FAIL blobs/check upload url: $check" >&2; exit 1; }
echo "ok  /blobs/check reports missing hash with upload url"

# Upload with correct hash → 204, blob lands.
code=$(curl -s --http2-prior-knowledge "${AUTH[@]}" -o /dev/null -w '%{http_code}' \
    -X PUT --data-raw "$BYTES" \
    "http://127.0.0.1:$PORT/acme/blobs/$HASH")
expect "PUT /blobs/{hash} correct bytes" 204 "$code"

# /blobs/check now reports the hash as present (empty missing, empty uploads).
check=$(curl -s --http2-prior-knowledge "${AUTH[@]}" \
    -X POST -H "Content-Type: application/json" \
    --data-raw "{\"hashes\":[\"$HASH\"]}" \
    "http://127.0.0.1:$PORT/acme/blobs/check")
echo "$check" | grep -q "\"missing\":\[\]" \
    || { echo "FAIL blobs/check after upload: $check" >&2; exit 1; }
echo "ok  /blobs/check reports present hash after upload"

# Upload with mismatched hash → 400. Claim the hash of different bytes.
BAD_HASH=$(printf 'xxx' | sha256sum | awk '{print $1}')
code=$(curl -s --http2-prior-knowledge "${AUTH[@]}" -o /dev/null -w '%{http_code}' \
    -X PUT --data-raw "$BYTES" \
    "http://127.0.0.1:$PORT/acme/blobs/$BAD_HASH")
expect "PUT /blobs/{hash} hash mismatch" 400 "$code"

# Upload with invalid hash shape (not 64 hex chars) → 400.
code=$(curl -s --http2-prior-knowledge "${AUTH[@]}" -o /dev/null -w '%{http_code}' \
    -X PUT --data-raw "$BYTES" \
    "http://127.0.0.1:$PORT/acme/blobs/notahash")
expect "PUT /blobs/{hash} malformed hash" 400 "$code"

# ── Full two-phase deploy: check → PUT blobs → POST /deployments ─────
# Stage 2 of the new upload protocol. Build a manifest with one
# static file + one handler, upload both blobs, stamp the deployment.

STATIC_BYTES='<!doctype html><title>two-phase</title>'
STATIC_HASH=$(printf '%s' "$STATIC_BYTES" | sha256sum | awk '{print $1}')
HANDLER_BYTES='export function handler() { return "two-phase!"; }'
HANDLER_HASH=$(printf '%s' "$HANDLER_BYTES" | sha256sum | awk '{print $1}')

# /blobs/check on both: both missing.
check=$(curl -s --http2-prior-knowledge "${AUTH[@]}" \
    -X POST -H "Content-Type: application/json" \
    --data-raw "{\"hashes\":[\"$STATIC_HASH\",\"$HANDLER_HASH\"]}" \
    "http://127.0.0.1:$PORT/twophase/blobs/check")
echo "$check" | grep -q "$STATIC_HASH" \
    || { echo "FAIL expected static hash missing: $check" >&2; exit 1; }
echo "$check" | grep -q "$HANDLER_HASH" \
    || { echo "FAIL expected handler hash missing: $check" >&2; exit 1; }
echo "ok  /blobs/check on two new hashes → both missing"

# Upload both.
code=$(curl -s --http2-prior-knowledge "${AUTH[@]}" -o /dev/null -w '%{http_code}' \
    -X PUT --data-raw "$STATIC_BYTES" \
    "http://127.0.0.1:$PORT/twophase/blobs/$STATIC_HASH")
expect "PUT static blob" 204 "$code"

code=$(curl -s --http2-prior-knowledge "${AUTH[@]}" -o /dev/null -w '%{http_code}' \
    -X PUT --data-raw "$HANDLER_BYTES" \
    "http://127.0.0.1:$PORT/twophase/blobs/$HANDLER_HASH")
expect "PUT handler blob" 204 "$code"

# Commit the manifest. First deploy: no parent_id means "don't CAS".
body=$(curl -s --http2-prior-knowledge "${AUTH[@]}" \
    -X POST -H "Content-Type: application/json" \
    --data-raw "{
        \"files\": {
            \"_static/index.html\": {\"hash\":\"$STATIC_HASH\",\"kind\":\"static\",\"content_type\":\"text/html\"},
            \"index.mjs\":          {\"hash\":\"$HANDLER_HASH\",\"kind\":\"handler\"}
        }
    }" \
    "http://127.0.0.1:$PORT/twophase/deployments")
echo "$body" | grep -q '"id":"' \
    || { echo "FAIL /deployments missing id: $body" >&2; exit 1; }
echo "ok  POST /deployments commits manifest: $body"

# Fetch the bundle metadata to confirm the manifest landed.
list=$(curl -s --http2-prior-knowledge "${AUTH[@]}" "http://127.0.0.1:$PORT/twophase/list")
echo "$list" | grep -q '"_static/index.html"' \
    || { echo "FAIL /list missing static: $list" >&2; exit 1; }
echo "$list" | grep -q '"index.mjs"' \
    || { echo "FAIL /list missing handler: $list" >&2; exit 1; }
echo "ok  /list shows both files after deploy"

# CAS: a second deploy with parent_id=0 (wrong — current is 1) → 409.
code=$(curl -s --http2-prior-knowledge "${AUTH[@]}" -o /dev/null -w '%{http_code}' \
    -X POST -H "Content-Type: application/json" \
    --data-raw "{
        \"parent_id\":\"0000000000000000\",
        \"files\": {\"index.mjs\":{\"hash\":\"$HANDLER_HASH\",\"kind\":\"handler\"}}
    }" \
    "http://127.0.0.1:$PORT/twophase/deployments")
expect "POST /deployments stale parent_id" 409 "$code"

# CAS with the correct parent_id → 201.
body=$(curl -s --http2-prior-knowledge "${AUTH[@]}" \
    -X POST -H "Content-Type: application/json" \
    --data-raw "{
        \"parent_id\":\"0000000000000001\",
        \"files\": {\"index.mjs\":{\"hash\":\"$HANDLER_HASH\",\"kind\":\"handler\"}}
    }" \
    "http://127.0.0.1:$PORT/twophase/deployments")
echo "$body" | grep -q '"id":"0000000000000002"' \
    || { echo "FAIL expected deployment id 2: $body" >&2; exit 1; }
echo "ok  POST /deployments with matching parent_id → id=2"

# Deploy referencing a hash we never uploaded → 400.
NEVER_HASH=$(printf 'never uploaded' | sha256sum | awk '{print $1}')
code=$(curl -s --http2-prior-knowledge "${AUTH[@]}" -o /dev/null -w '%{http_code}' \
    -X POST -H "Content-Type: application/json" \
    --data-raw "{\"files\":{\"ghost.mjs\":{\"hash\":\"$NEVER_HASH\",\"kind\":\"handler\"}}}" \
    "http://127.0.0.1:$PORT/twophase/deployments")
expect "POST /deployments missing blob" 400 "$code"

echo "PASS files-server smoke"
