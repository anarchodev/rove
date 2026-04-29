#!/usr/bin/env bash
# End-to-end smoke test for rove-js-ctl.
#
# Starts a loop46 with a bootstrap root token, builds a small
# source tree in /tmp, uses `rove-js-ctl deploy` to upload and
# publish it against the `acme` tenant, then curls the resulting
# routes to verify the worker picked up the new deployment.

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-ctl-smoke}"
SRC_DIR="${SRC_DIR:-/tmp/rove-ctl-smoke-src}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8197}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40297}"
BIN="${BIN:-./zig-out/bin/loop46}"
CTL="${CTL:-./zig-out/bin/rove-js-ctl}"
TOKEN="${ROVE_TOKEN:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
export ROVE_TOKEN="$TOKEN"

if [[ ! -x "$BIN" ]] || [[ ! -x "$CTL" ]]; then
    echo "error: $BIN or $CTL missing — run 'zig build install' first" >&2
    exit 2
fi

rm -rf "$DATA_DIR" "$SRC_DIR"

# Pre-create the acme tenant via `loop46 seed` so the running worker
# has it in its instance map. (`ctl deploy` writes files but doesn't
# create the tenant on a live worker — that's a signup-flow concern.)
SEED_MANIFEST=$(mktemp --suffix=.json)
cat > "$SEED_MANIFEST" <<'EOF'
{"tenants": [{"id": "acme", "domains": [], "files": []}]}
EOF
"$BIN" seed --data-dir "$DATA_DIR" --manifest "$SEED_MANIFEST"

"$BIN" worker \
    --node-id 0 \
    --peers "$RAFT_ADDR" \
    --listen "$RAFT_ADDR" \
    --http "$HTTP_ADDR" \
    --data-dir "$DATA_DIR" \
    --public-suffix loop46.localhost \
    --bootstrap-root-token "$TOKEN" \
    >/tmp/ctl-smoke.out 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true; rm -f "$SEED_MANIFEST"' EXIT

sleep 1.0

# Build a small source tree with two routes. Each is a `.mjs` with
# a named export called `handler` (our RPC convention).
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

# Deploy via ctl. The debug line `uploaded <path>` goes to stderr,
# the final `deployed ...` line to stdout — we capture both together
# so grep can check for them.
"$CTL" --url "http://$HTTP_ADDR" deploy acme "$SRC_DIR" >/tmp/ctl-deploy.out 2>&1
cat /tmp/ctl-deploy.out
grep -q "uploaded api/index.mjs" /tmp/ctl-deploy.out \
    || { echo "FAIL: missing api/index.mjs upload line" >&2; exit 1; }
grep -q "uploaded index.mjs" /tmp/ctl-deploy.out \
    || { echo "FAIL: missing index.mjs upload line" >&2; exit 1; }
grep -q "deployed 2 file" /tmp/ctl-deploy.out \
    || { echo "FAIL: missing deploy summary" >&2; exit 1; }

# Wait for the worker's deployment refresh poll to observe the new
# deployment (2s default interval, give it a little extra).
sleep 2.5

# Hit the deployed handlers via the named-export RPC.
got_root=$(curl -s --http2-prior-knowledge -H "Host: acme.loop46.localhost" "http://$HTTP_ADDR/?fn=handler")
expect "GET /?fn=handler (ctl-deployed root handler)" "ctl-root" "$got_root"

got_api=$(curl -s --http2-prior-knowledge -H "Host: acme.loop46.localhost" "http://$HTTP_ADDR/api?fn=handler")
expect "GET /api?fn=handler (ctl-deployed sub-route)" "ctl-api" "$got_api"

# Deploy with no token — should fail at the auth gate.
if "$CTL" --url "http://$HTTP_ADDR" --token bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb deploy acme "$SRC_DIR" >/tmp/ctl-bad.out 2>&1; then
    echo "FAIL: deploy with wrong token should have errored" >&2
    exit 1
fi
echo "ok  deploy with wrong token: rejected"

echo "PASS ctl smoke"
