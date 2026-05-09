#!/usr/bin/env bash
# sse-server-standalone end-to-end smoke (docs/sse-plan.md).
#
# Boots the standalone process, then drives every wire shape the
# worker / browser will exercise, by hand:
#
#   - GET  /v1/health                                    → 200 ok
#   - POST /v1/emit  with bad bearer                     → 401
#   - POST /v1/emit  with malformed body                 → 400
#   - POST /v1/emit  with the worker-shaped body         → 204
#   - GET  /v1/{tenant}/sse?token=<JWT>
#       - missing token                                  → 401
#       - bad signature                                  → 401
#       - tenant claim != URL tenant                     → 403
#       - happy path                                     → 200 text/event-stream
#   - End-to-end live push: open EventSource on tenant A
#     for sid X, POST emit targeting (tenant=A, sid=X),
#     observe the wire frame.
#   - Cross-tenant isolation: emit on tenant B targeting
#     the same sid X → tenant A's stream sees nothing.
#
# JWT minting is hand-rolled with openssl HMAC so the smoke can
# exercise the auth path without booting a worker. The format
# matches rove-jwt's `mintWithPayload`: HEADER.PAYLOAD.SIG with
# base64url-no-pad sections and HMAC-SHA256(secret_bytes,
# HEADER.PAYLOAD).

set -euo pipefail

BIN="${BIN:-./zig-out/bin/sse-server-standalone}"
PORT="${PORT:-18230}"

if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN missing — run 'zig build install' first" >&2
    exit 2
fi

# 32 hex bytes (the platform key shape `LOOP46_SERVICES_JWT_SECRET`
# uses). Stable per-run is fine; nothing here is durable.
JWT_SECRET_HEX="$(head -c 32 /dev/urandom | xxd -p | tr -d '\n')"
INTERNAL_TOKEN="$(head -c 24 /dev/urandom | xxd -p | tr -d '\n')"

PIDS=()
trap '
    for p in "${PIDS[@]}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done
    for p in "${PIDS[@]}"; do
        [ -n "$p" ] && wait "$p" 2>/dev/null || true
    done
' EXIT

# ── Helpers ─────────────────────────────────────────────────────────

# base64url-no-pad encode stdin → stdout.
b64url() {
    base64 -w0 | tr '+/' '-_' | tr -d '='
}

# mint_jwt <payload-json>
# Output: <token> on stdout. Uses $JWT_SECRET_HEX as the platform key.
mint_jwt() {
    local payload="$1"
    # rove-jwt's pre-encoded HEADER_B64 = base64url('{"alg":"HS256","typ":"JWT"}').
    local header_b64="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    local payload_b64
    payload_b64=$(printf '%s' "$payload" | b64url)
    local signing_input="${header_b64}.${payload_b64}"
    local sig
    sig=$(printf '%s' "$signing_input" \
        | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${JWT_SECRET_HEX}" -binary \
        | b64url)
    printf '%s.%s' "$signing_input" "$sig"
}

# now_ms: current time in milliseconds (matches what
# `verifyAndCopyPayload` compares `exp` against).
now_ms() {
    date +%s%3N
}

# expect_status <expected> <label> <status>
expect_status() {
    local expected="$1" label="$2" got="$3"
    if [[ "$got" != "$expected" ]]; then
        echo "FAIL ($label): expected HTTP $expected, got $got" >&2
        exit 1
    fi
    echo "ok: $label → $got"
}

# 64-hex sids that match the worker's session.zig SID_LEN.
SID_A_X="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SID_A_Y="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# ── Boot sse-server ─────────────────────────────────────────────────

SSE_INTERNAL_TOKEN="$INTERNAL_TOKEN" \
LOOP46_SERVICES_JWT_SECRET="$JWT_SECRET_HEX" \
"$BIN" --listen "127.0.0.1:$PORT" >/tmp/sse-smoke-server.log 2>&1 &
PIDS+=("$!")

# Wait for /v1/health to answer (ports race on cold boot).
for _ in $(seq 1 50); do
    if curl -sf --http2-prior-knowledge "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1; then
        break
    fi
    sleep 0.05
done

curl_h2() {
    curl -s --http2-prior-knowledge "$@"
}

# ── 1: health ───────────────────────────────────────────────────────

CODE=$(curl_h2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/health")
expect_status 200 "GET /v1/health" "$CODE"

# ── 2: /v1/emit auth + body validation ──────────────────────────────

GOOD_BODY=$(cat <<JSON
{"v":1,"tenant_id":"acme","request_id":1,"events":[{"event_id":"00000000000000000001-000000","type":"comment_added","data":{"id":99},"target_sids":["$SID_A_X"],"created_at_ms":1730764800000}]}
JSON
)

CODE=$(curl_h2 -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:$PORT/v1/emit" \
    -H "Authorization: Bearer wrong-token" \
    -H "Content-Type: application/json" \
    -d "$GOOD_BODY")
expect_status 401 "POST /v1/emit (bad bearer)" "$CODE"

CODE=$(curl_h2 -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:$PORT/v1/emit" \
    -H "Authorization: Bearer $INTERNAL_TOKEN" \
    -H "Content-Type: application/json" \
    -d 'not-json')
expect_status 400 "POST /v1/emit (malformed body)" "$CODE"

CODE=$(curl_h2 -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:$PORT/v1/emit" \
    -H "Authorization: Bearer $INTERNAL_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$GOOD_BODY")
expect_status 204 "POST /v1/emit (worker-shaped body)" "$CODE"

# ── 3: EventSource auth ────────────────────────────────────────────

EXP=$(( $(now_ms) + 60000 ))
TOKEN_A=$(mint_jwt "{\"v\":1,\"tenant_id\":\"acme\",\"sid\":\"$SID_A_X\",\"caps\":{\"max_conns_per_session\":16,\"max_event_payload_bytes\":65536},\"exp\":$EXP}")
TOKEN_B=$(mint_jwt "{\"v\":1,\"tenant_id\":\"beta\",\"sid\":\"$SID_A_X\",\"caps\":{\"max_conns_per_session\":16,\"max_event_payload_bytes\":65536},\"exp\":$EXP}")

CODE=$(curl_h2 -o /dev/null -w '%{http_code}' --max-time 1 \
    "http://127.0.0.1:$PORT/v1/acme/sse")
expect_status 401 "GET /v1/acme/sse (no token)" "$CODE"

CODE=$(curl_h2 -o /dev/null -w '%{http_code}' --max-time 1 \
    "http://127.0.0.1:$PORT/v1/acme/sse?token=not-a-jwt")
expect_status 401 "GET /v1/acme/sse (malformed token)" "$CODE"

# Tamper signature — flip the last char.
TAMPERED="${TOKEN_A%?}X"
CODE=$(curl_h2 -o /dev/null -w '%{http_code}' --max-time 1 \
    "http://127.0.0.1:$PORT/v1/acme/sse?token=$TAMPERED")
expect_status 401 "GET /v1/acme/sse (bad signature)" "$CODE"

# Token claims tenant=beta, URL says acme → 403.
CODE=$(curl_h2 -o /dev/null -w '%{http_code}' --max-time 1 \
    "http://127.0.0.1:$PORT/v1/acme/sse?token=$TOKEN_B")
expect_status 403 "GET /v1/acme/sse (tenant mismatch)" "$CODE"

# Happy path: 200 + text/event-stream. --max-time 1 lets the
# long-lived stream close cleanly so curl exits.
HEAD_OUT=$(curl_h2 -i --max-time 1 \
    "http://127.0.0.1:$PORT/v1/acme/sse?token=$TOKEN_A" 2>/dev/null || true)
if ! grep -qE '^HTTP/2 200' <<<"$HEAD_OUT"; then
    echo "FAIL: EventSource happy path didn't return 200" >&2
    echo "$HEAD_OUT" | head -20 >&2
    exit 1
fi
if ! grep -qiE '^content-type:.*text/event-stream' <<<"$HEAD_OUT"; then
    echo "FAIL: EventSource happy path missing text/event-stream content-type" >&2
    echo "$HEAD_OUT" | head -20 >&2
    exit 1
fi
echo "ok: GET /v1/acme/sse (happy path) → 200 text/event-stream"

# ── 4: end-to-end live push ────────────────────────────────────────
#
# Open the EventSource in the background, then POST an emit and
# capture the frame the stream emits. curl --max-time 2 lets the
# stream close after we've collected the frame.

STREAM_OUT=$(mktemp)
curl_h2 --max-time 2 "http://127.0.0.1:$PORT/v1/acme/sse?token=$TOKEN_A" \
    >"$STREAM_OUT" 2>/dev/null &
STREAM_PID=$!
PIDS+=("$STREAM_PID")
sleep 0.3  # let the EventSource register before we emit

EMIT_E2E=$(cat <<JSON
{"v":1,"tenant_id":"acme","request_id":42,"events":[{"event_id":"00000000000000000042-000000","type":"comment_added","data":{"id":99},"target_sids":["$SID_A_X"],"created_at_ms":1730764800000}]}
JSON
)
curl_h2 -X POST "http://127.0.0.1:$PORT/v1/emit" \
    -H "Authorization: Bearer $INTERNAL_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$EMIT_E2E" >/dev/null
wait "$STREAM_PID" 2>/dev/null || true

if ! grep -qE '^id: 00000000000000000042-000000$' "$STREAM_OUT"; then
    echo "FAIL: live frame missing id line" >&2
    sed -n '1,20p' "$STREAM_OUT" >&2
    exit 1
fi
if ! grep -qE '^event: comment_added$' "$STREAM_OUT"; then
    echo "FAIL: live frame missing event line" >&2
    sed -n '1,20p' "$STREAM_OUT" >&2
    exit 1
fi
if ! grep -qE '^data: \{"id":99\}$' "$STREAM_OUT"; then
    echo "FAIL: live frame missing data line" >&2
    sed -n '1,20p' "$STREAM_OUT" >&2
    exit 1
fi
echo "ok: end-to-end emit → EventSource frame"

# ── 5: cross-tenant isolation ──────────────────────────────────────
#
# Open the EventSource on tenant A, sid X. Then POST an emit on
# tenant B targeting the SAME sid X. tenant A's stream MUST NOT
# see the frame — sse-server keys ring caches + connections
# per-tenant. Frame's event_id 9999 makes it easy to grep for.

STREAM_OUT_A=$(mktemp)
curl_h2 --max-time 2 "http://127.0.0.1:$PORT/v1/acme/sse?token=$TOKEN_A" \
    >"$STREAM_OUT_A" 2>/dev/null &
STREAM_A_PID=$!
PIDS+=("$STREAM_A_PID")
sleep 0.3

EMIT_B=$(cat <<JSON
{"v":1,"tenant_id":"beta","request_id":99,"events":[{"event_id":"00000000000000009999-000000","type":"leak","data":null,"target_sids":["$SID_A_X"],"created_at_ms":1730764800000}]}
JSON
)
curl_h2 -X POST "http://127.0.0.1:$PORT/v1/emit" \
    -H "Authorization: Bearer $INTERNAL_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$EMIT_B" >/dev/null
wait "$STREAM_A_PID" 2>/dev/null || true

if grep -qE 'leak|9999' "$STREAM_OUT_A"; then
    echo "FAIL: cross-tenant frame leaked into tenant A's stream" >&2
    sed -n '1,20p' "$STREAM_OUT_A" >&2
    exit 1
fi
echo "ok: cross-tenant isolation (beta emit invisible on acme stream)"

echo ""
echo "PASS: sse-server-standalone smoke"
