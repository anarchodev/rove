#!/usr/bin/env bash
# End-to-end smoke for the deploy flow against a 3-node loop46 cluster.
#
# Phase 5.5(?) — `loop46 worker` requires --peers ≥ 2; this smoke
# spins up 3 workers (matching the typical production 3-node deploy:
# 1 leader + 2 followers, raft 2/3 quorum, 1-failure tolerance),
# discovers the leader by probing each node's admin port, and drives
# the deploy flow against the leader. Followers replicate via raft;
# `dispatchOnce` leader-skips them on every request (existing
# behavior — followers reject with 503 not leader).

set -euo pipefail

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-ctl-smoke}"
SRC_DIR="${SRC_DIR:-/tmp/rove-ctl-smoke-src}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8197}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40297}"
LOG_ADDR="${LOG_ADDR:-127.0.0.1:8224}"
FILES_ADDR="${FILES_ADDR:-127.0.0.1:8225}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
PUBLIC_SUFFIX="loop46.localhost"
ADMIN_HOST="app.${PUBLIC_SUFFIX}"
LOG_PORT="${LOG_ADDR##*:}"
FILES_PORT="${FILES_ADDR##*:}"

if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN missing — run 'zig build install' first" >&2
    exit 2
fi

# 3-node addresses derived from the port bases.
HTTP_ADDRS=()
RAFT_ADDRS=()
DATA_DIRS=()
for i in 0 1 2; do
    HTTP_ADDRS+=("127.0.0.1:$((HTTP_PORT_BASE + i))")
    RAFT_ADDRS+=("127.0.0.1:$((RAFT_PORT_BASE + i))")
    DATA_DIRS+=("${DATA_DIR_PREFIX}-${i}")
done
PEERS_CSV=$(IFS=,; echo "${RAFT_ADDRS[*]}")

rm -rf "$SRC_DIR" "${DATA_DIRS[@]}"

# Seed the same tenant on every node — each maintains its own
# __root__.db, but the membership has to match across the cluster
# so raft's apply path replicates writes consistently.
SEED_MANIFEST=$(mktemp --suffix=.json)
cat > "$SEED_MANIFEST" <<'EOF'
{"tenants": [{"id": "acme", "domains": [], "files": []}]}
EOF
for d in "${DATA_DIRS[@]}"; do
    "$BIN" seed --data-dir "$d" --manifest "$SEED_MANIFEST"
done

. "$(dirname "$0")/_smoke_helpers.sh"
export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"

# Spawn the 3-node cluster first. Workers are configured with
# `--files-public-base` / `--log-public-base` set to the eventual
# (fixed) standalone addresses; the standalones don't have to be
# up at worker startup — workers only need the URL strings to
# return via /_system/services-token. We'll spawn the standalones
# below pointing at whichever node ends up leader.
PIDS=()
for i in 0 1 2; do
    "$BIN" worker \
        --node-id "$i" \
        --peers "$PEERS_CSV" \
        --listen "${RAFT_ADDRS[$i]}" \
        --http "${HTTP_ADDRS[$i]}" \
        --log-public-base "http://${LOG_ADDR}" \
        --files-public-base "http://${FILES_ADDR}" \
        --data-dir "${DATA_DIRS[$i]}" \
        --public-suffix "$PUBLIC_SUFFIX" \
        --bootstrap-root-token "$TOKEN" \
        >"/tmp/ctl-smoke-worker-${i}.out" 2>&1 &
    PIDS+=($!)
done
trap '
    for p in "${PIDS[@]}" "${CS_PID:-}" "${LS_PID:-}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done
    for p in "${PIDS[@]}" "${CS_PID:-}" "${LS_PID:-}"; do
        [ -n "$p" ] && wait "$p" 2>/dev/null || true
    done
    rm -f "$SEED_MANIFEST"
' EXIT
sleep 2

# Smoke runs against h2c (no TLS); CURL is plain curl + h2c flag.
CURL=(curl -sS --http2-prior-knowledge)

# Discover the leader by probing each node's admin port. Followers
# reject every request with 503 + "not leader; retry against the
# cluster leader" (existing leader-skip in dispatchOnce). The
# leader's `?fn=listInstance` returns 200. Tries up to 30 × 200ms
# = 6s, generous enough for willemt's election timeout.
LEADER_HTTP=""
LEADER_IDX=""
for _ in $(seq 1 30); do
    for i in 0 1 2; do
        code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
            -H "Host: $ADMIN_HOST" \
            -H "Authorization: Bearer $TOKEN" \
            "http://${HTTP_ADDRS[$i]}/?fn=listInstance" 2>/dev/null || echo 000)
        if [[ "$code" == "200" ]]; then
            LEADER_HTTP="${HTTP_ADDRS[$i]}"
            LEADER_IDX="$i"
            break 2
        fi
    done
    sleep 0.2
done
if [[ -z "$LEADER_HTTP" ]]; then
    echo "FAIL: no leader elected within 6s" >&2
    for i in 0 1 2; do
        echo "--- worker $i log (last 30 lines) ---" >&2
        tail -30 "/tmp/ctl-smoke-worker-${i}.out" >&2
    done
    exit 1
fi
ADMIN_ORIGIN="http://${LEADER_HTTP}"
echo "ok  leader elected: node $LEADER_IDX at $LEADER_HTTP"

# Spawn files-server / log-server pinned to the leader's data_dir.
# Multi-node deploys need a shared blob backend (S3 / NFS) so
# blobs survive failover; for this smoke (no failover, just steady-
# state leader processing) the leader's local data_dir is the
# correct operational choice.
spawn_files_server "$FILES_ADDR" "${DATA_DIRS[$LEADER_IDX]}" /tmp/ctl-smoke-cs.out "$ADMIN_ORIGIN" || exit 1
spawn_log_server   "$LOG_ADDR"   "${DATA_DIRS[$LEADER_IDX]}" /tmp/ctl-smoke-ls.out "$ADMIN_ORIGIN" || exit 1

# Mint the JWT by curling the leader. /_system/services-token
# returns both files_url and log_url so smokes can hit each
# subdomain.
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
        for i in 0 1 2; do
            echo "--- worker $i log ---" >&2
            tail -30 "/tmp/ctl-smoke-worker-${i}.out" >&2
        done
        exit 1
    fi
    echo "ok  $label"
}

FILES_LOOP="http://${FILES_ADDR}"

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

dep_id=$("${CURL[@]}" -X POST -H "Authorization: Bearer $JWT" \
    "${FILES_LOOP}/acme/deploy")
[[ -n "$dep_id" ]] || { echo "FAIL deploy: empty response" >&2; exit 1; }
echo "deployed 2 file(s) → id=${dep_id}"

# Phase 5.5(e) F2 — push the release to the worker. Goes to the
# leader; each worker process maintains its own ReleaseTable, so
# the release fires reload only on the node receiving the request.
# Followers will pick it up after raft replicates the kv write
# (envelope 0 → `_deploy/current`); the existing
# applyPendingReleases tick handles it.
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    -X POST -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"tenant_id\":\"acme\",\"dep_id\":${dep_id}}" \
    "${ADMIN_ORIGIN}/_system/release")
[[ "$code" == "204" ]] || { echo "FAIL release: $code" >&2; exit 1; }
echo "released dep_id=${dep_id}"

# Hit the deployed handlers via the named-export RPC, against the
# leader.
got_root=$(curl -s --http2-prior-knowledge -H "Host: acme.${PUBLIC_SUFFIX}" "${ADMIN_ORIGIN}/?fn=handler")
expect "GET /?fn=handler (ctl-deployed root handler)" "ctl-root" "$got_root"

got_api=$(curl -s --http2-prior-knowledge -H "Host: acme.${PUBLIC_SUFFIX}" "${ADMIN_ORIGIN}/api?fn=handler")
expect "GET /api?fn=handler (ctl-deployed sub-route)" "ctl-api" "$got_api"

# Followers (every node that's NOT the leader) should reject with
# 503 not-leader.
for i in 0 1 2; do
    [[ "$i" == "$LEADER_IDX" ]] && continue
    code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
        -H "Host: acme.${PUBLIC_SUFFIX}" "http://${HTTP_ADDRS[$i]}/?fn=handler")
    [[ "$code" == "503" ]] || { echo "FAIL: follower $i should 503, got $code" >&2; exit 1; }
done
echo "ok  followers reject with 503 not-leader"

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

echo "PASS ctl smoke (3-node)"
