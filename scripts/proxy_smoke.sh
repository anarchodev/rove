#!/usr/bin/env bash
# End-to-end smoke test for the worker's `/_system/files/*` proxy.
#
# Starts a js-worker (which spawns the in-process rove-files-server
# thread at startup), then drives:
#   - POST /_system/files/acme/upload
#   - POST /_system/files/acme/deploy
#   - GET /_system/foo         → 501 (reserved-but-unimplemented)
#   - GET / (unrelated JS handler, proves normal traffic still works)
#
# Verifies that /_system/files/* requests are forwarded through the
# rove-h2 client side of the worker to the code thread, the code
# thread's response is mapped back onto the original server entity,
# and the user observes the code-thread's status + body.

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-proxy-smoke}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8195}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40295}"
BIN="${BIN:-./zig-out/bin/js-worker}"
# 64-char hex root token installed at bootstrap.
ROVE_TOKEN="${ROVE_TOKEN:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"

if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN not found — run 'zig build install' first" >&2
    exit 2
fi

rm -rf "$DATA_DIR"

"$BIN" \
    --node-id 0 \
    --peers "$RAFT_ADDR" \
    --listen "$RAFT_ADDR" \
    --http "$HTTP_ADDR" \
    --data-dir "$DATA_DIR" \
    --bootstrap-root-token "$ROVE_TOKEN" \
    --fresh >/tmp/proxy-smoke.out 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true' EXIT

# Let the worker bind + the code thread come up + the client connect.
sleep 1.0

expect() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL $label: expected $expected, got $actual" >&2
        echo "--- worker log ---" >&2
        tail -30 /tmp/proxy-smoke.out >&2
        exit 1
    fi
    echo "ok  $label: $actual"
}

# Upload a file under the existing `acme` tenant. The worker strips
# the `/_system/files` prefix and proxies the rest (`/acme/upload`)
# to the code thread.
code=$(curl -s --http2-prior-knowledge -o /dev/null -w '%{http_code}' \
    -X POST \
    -H "Host: acme.test" \
    -H "X-Rove-Path: smoke/index.mjs" \
    -H "Authorization: Bearer $ROVE_TOKEN" \
    --data-binary 'export function handler() { return "smoke"; }' \
    "http://$HTTP_ADDR/_system/files/acme/upload")
expect "proxy upload /acme" 204 "$code"

# Missing token → 401 (auth gate).
code=$(curl -s --http2-prior-knowledge -o /dev/null -w '%{http_code}' \
    -X POST \
    -H "Host: acme.test" \
    -H "X-Rove-Path: smoke/index.mjs" \
    --data-binary 'export function handler() { return "smoke"; }' \
    "http://$HTTP_ADDR/_system/files/acme/upload")
expect "proxy upload /acme (no token)" 401 "$code"

# Wrong token → 401.
code=$(curl -s --http2-prior-knowledge -o /dev/null -w '%{http_code}' \
    -X POST \
    -H "Host: acme.test" \
    -H "X-Rove-Path: smoke/index.mjs" \
    -H "Authorization: Bearer bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    --data-binary 'export function handler() { return "smoke"; }' \
    "http://$HTTP_ADDR/_system/files/acme/upload")
expect "proxy upload /acme (wrong token)" 401 "$code"

# Deploy. The body is the new deployment id — acme already had
# deployment 1 from the bootstrap, so the new one should be >= 2.
body=$(curl -s --http2-prior-knowledge \
    -X POST \
    -H "Host: acme.test" \
    -H "Authorization: Bearer $ROVE_TOKEN" \
    "http://$HTTP_ADDR/_system/files/acme/deploy" | tr -d '\n')
case "$body" in
    [2-9]*|[1-9][0-9]*)
        echo "ok  proxy deploy /acme: id=$body"
        ;;
    *)
        echo "FAIL proxy deploy expected >=2, got '$body'" >&2
        exit 1
        ;;
esac

# Unrelated user traffic still works — the JS handler at acme's
# `index.js` should serve GET / and return its hit counter.
code=$(curl -s --http2-prior-knowledge -o /tmp/proxy-home.out -w '%{http_code}' \
    -H "Host: acme.test" "http://$HTTP_ADDR/?fn=handler")
expect "GET / (unrelated JS handler)" 200 "$code"
if ! grep -q "acme hit count" /tmp/proxy-home.out; then
    echo "FAIL: unexpected body for GET /" >&2
    cat /tmp/proxy-home.out >&2
    exit 1
fi

# /_system/ path that isn't /_system/files/* → 501 stub.
code=$(curl -s --http2-prior-knowledge -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $ROVE_TOKEN" \
    "http://$HTTP_ADDR/_system/foo/acme/x")
expect "GET /_system/foo/.. (unimplemented)" 501 "$code"

# Drive a couple of real requests so the tenant's log.db has
# something to return, then exercise the /_system/log/* proxy.
curl -s --http2-prior-knowledge -o /dev/null \
    -H "Host: acme.test" "http://$HTTP_ADDR/?fn=handler" >/dev/null
curl -s --http2-prior-knowledge -o /dev/null \
    -H "Host: acme.test" "http://$HTTP_ADDR/?fn=handler" >/dev/null
# Give the log buffer a moment to flush.
sleep 1.2

# GET /_system/log/acme/count — proxied through to log-server.
body=$(curl -s --http2-prior-knowledge \
    -H "Authorization: Bearer $ROVE_TOKEN" \
    "http://$HTTP_ADDR/_system/log/acme/count" | tr -d '\n')
case "$body" in
    [1-9]*) echo "ok  proxy log count: $body" ;;
    *) echo "FAIL log count: expected >=1, got '$body'" >&2; exit 1 ;;
esac

# GET /_system/log/acme/list?limit=5 — should return JSON with records.
body=$(curl -s --http2-prior-knowledge \
    -H "Authorization: Bearer $ROVE_TOKEN" \
    "http://$HTTP_ADDR/_system/log/acme/list?limit=5")
case "$body" in
    *'"records":['*)
        echo "ok  proxy log list: JSON returned"
        ;;
    *)
        echo "FAIL log list: unexpected body '$body'" >&2
        exit 1
        ;;
esac

# Missing auth on log endpoint → 401.
code=$(curl -s --http2-prior-knowledge -o /dev/null -w '%{http_code}' \
    "http://$HTTP_ADDR/_system/log/acme/count")
expect "proxy log count (no token)" 401 "$code"

echo "PASS proxy smoke"
