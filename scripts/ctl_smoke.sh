#!/usr/bin/env bash
# End-to-end smoke for the deploy flow against a live loop46 worker.
#
# Mirrors what `loop46-files-cli` would do (Phase 5.5(e) Step F1
# retired the in-process rove-js-ctl Zig binary): mint a JWT via
# `/_system/services-token`, upload sources via the standalone
# files-server's `/{tenant}/upload`, deploy via `/{tenant}/deploy`,
# then drive the resulting routes against the worker.

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-ctl-smoke}"
SRC_DIR="${SRC_DIR:-/tmp/rove-ctl-smoke-src}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8197}"
LOG_ADDR="${LOG_ADDR:-127.0.0.1:8224}"
FILES_ADDR="${FILES_ADDR:-127.0.0.1:8225}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40297}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
PORT="${HTTP_ADDR##*:}"
LOG_PORT="${LOG_ADDR##*:}"
FILES_PORT="${FILES_ADDR##*:}"
PUBLIC_SUFFIX="loop46.localhost"
ADMIN_HOST="app.${PUBLIC_SUFFIX}"
FILES_HOST="files.${PUBLIC_SUFFIX}"
LOG_HOST="logs.${PUBLIC_SUFFIX}"
ADMIN_ORIGIN="http://${HTTP_ADDR}"

if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN missing — run 'zig build install' first" >&2
    exit 2
fi

rm -rf "$DATA_DIR" "$SRC_DIR"

# Pre-create the acme tenant via `loop46 seed` so the running worker
# has it in its instance map.
SEED_MANIFEST=$(mktemp --suffix=.json)
cat > "$SEED_MANIFEST" <<'EOF'
{"tenants": [{"id": "acme", "domains": [], "files": []}]}
EOF
"$BIN" seed --data-dir "$DATA_DIR" --manifest "$SEED_MANIFEST"

# Phase 5.5(e) Task #62 — files-server runs as a separate process.
# Both the worker and the standalone need the same JWT secret in env
# so the worker's `/_system/services-token` mints tokens that the
# standalone verifies.
. "$(dirname "$0")/_smoke_helpers.sh"
export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"

# Spawn the standalone first so the worker has somewhere to point
# `--files-public-base` at right from boot.
spawn_files_server "$FILES_ADDR" "$DATA_DIR" /tmp/ctl-smoke-cs.out "$ADMIN_ORIGIN" || exit 1

"$BIN" worker \
    --node-id 0 \
    --peers "$RAFT_ADDR" \
    --listen "$RAFT_ADDR" \
    --http "$HTTP_ADDR" \
    --log-listen "$LOG_ADDR" \
    --files-public-base "http://${FILES_ADDR}" \
    --data-dir "$DATA_DIR" \
    --public-suffix "$PUBLIC_SUFFIX" \
    --bootstrap-root-token "$TOKEN" \
    >/tmp/ctl-smoke.out 2>&1 &
PID=$!
trap 'kill $PID $CS_PID 2>/dev/null || true; wait $PID $CS_PID 2>/dev/null || true; rm -f "$SEED_MANIFEST"' EXIT
sleep 1.0

# Smoke runs against h2c (no TLS); CURL is plain curl + h2c flag.
CURL=(curl -sS --http2-prior-knowledge)

# Mint the JWT by curling the worker. /_system/services-token returns
# both files_url and log_url so smokes can hit each subdomain.
ROVE_TOKEN="$TOKEN"
mint_services_token

# Build a small source tree with two routes.
mkdir -p "$SRC_DIR/api"
cat > "$SRC_DIR/index.mjs" <<'EOF'
export function handler() { return "ctl-root\n"; }
EOF
cat > "$SRC_DIR/api/index.mjs" <<'EOF'
export function handler() { return "ctl-api\n"; }
EOF

expect() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL $label: expected '$expected', got '$actual'" >&2
        echo "--- worker log ---" >&2
        tail -30 /tmp/ctl-smoke.out >&2
        exit 1
    fi
    echo "ok  $label"
}

# Files-server is bound on the loopback addr by spawn_files_server; we
# call it directly with the JWT (no TLS — h2c on loopback). The
# default log/files origins from /_system/services-token assume TLS
# + a public suffix; here we override with the loopback addr.
FILES_LOOP="http://${FILES_ADDR}"

# Upload each source file by walking the dir.
upload_file() {
    local rel="$1"
    local code
    code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
        -X POST -H "Authorization: Bearer $JWT" \
        -H "X-Rove-Path: $rel" \
        --data-binary "@${SRC_DIR}/${rel}" \
        "${FILES_LOOP}/acme/upload")
    [[ "$code" == "204" ]] || { echo "FAIL upload $rel: $code" >&2; exit 1; }
    echo "uploaded $rel"
}
upload_file "index.mjs"
upload_file "api/index.mjs"

# Deploy.
dep_id=$("${CURL[@]}" -X POST -H "Authorization: Bearer $JWT" \
    "${FILES_LOOP}/acme/deploy")
[[ -n "$dep_id" ]] || { echo "FAIL deploy: empty response" >&2; exit 1; }
echo "deployed 2 file(s) → id=${dep_id}"

# Phase 5.5(e) F2 — push the release to the worker. Replaces the
# 2-second `refreshDeployments` poll. Auth is the root bearer token.
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    -X POST -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"tenant_id\":\"acme\",\"dep_id\":${dep_id}}" \
    "${ADMIN_ORIGIN}/_system/release")
[[ "$code" == "204" ]] || { echo "FAIL release: $code" >&2; exit 1; }
echo "released dep_id=${dep_id}"

# Hit the deployed handlers via the named-export RPC.
got_root=$(curl -s --http2-prior-knowledge -H "Host: acme.${PUBLIC_SUFFIX}" "${ADMIN_ORIGIN}/?fn=handler")
expect "GET /?fn=handler (ctl-deployed root handler)" "ctl-root" "$got_root"

got_api=$(curl -s --http2-prior-knowledge -H "Host: acme.${PUBLIC_SUFFIX}" "${ADMIN_ORIGIN}/api?fn=handler")
expect "GET /api?fn=handler (ctl-deployed sub-route)" "ctl-api" "$got_api"

# Wrong JWT secret → 401 from the files-server. We mint a token with
# a randomly-different secret and confirm the upload is rejected.
WRONG_SECRET=$(head -c16 /dev/urandom | xxd -p | tr -d '\n')
WRONG_JWT=$(WRONG_SECRET="$WRONG_SECRET" python3 - <<'PY'
import base64, hmac, hashlib, json, os, time
secret = bytes.fromhex(os.environ["WRONG_SECRET"])
header = b'{"alg":"HS256","typ":"JWT"}'
payload = json.dumps({"exp": int(time.time() * 1000) + 5 * 60 * 1000}).encode()
def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
signing_input = b64u(header) + "." + b64u(payload)
sig = hmac.new(secret, signing_input.encode(), hashlib.sha256).digest()
print(signing_input + "." + b64u(sig))
PY
)
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    -X POST -H "Authorization: Bearer $WRONG_JWT" \
    -H "X-Rove-Path: index.mjs" \
    --data-binary "@${SRC_DIR}/index.mjs" \
    "${FILES_LOOP}/acme/upload")
[[ "$code" == "401" ]] || { echo "FAIL wrong jwt: expected 401, got $code" >&2; exit 1; }
echo "ok  deploy with wrong JWT: rejected (401)"

echo "PASS ctl smoke"
