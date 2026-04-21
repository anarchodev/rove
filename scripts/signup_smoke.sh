#!/usr/bin/env bash
# End-to-end smoke test for the magic-link signup + auth flow.
#
# Covers:
#   - POST /v1/signup with a fresh name → 202 + magic_link in body
#   - Duplicate signup on the same name → 409 (name unavailable)
#   - Signup on a reserved name → 409 (prevents impersonation)
#   - Invalid email → 400
#   - GET /v1/auth?mt=<token> → 302 + Set-Cookie + Location:/#/{name}
#   - Session cookie from /v1/auth authenticates /v1/session
#   - Replay of the same magic link → 401 (single-use)
#
# This smoke intentionally does NOT exercise email delivery — the
# current signup endpoint returns the magic_link directly in the
# response body (documented as a dev/MVP shape). A follow-up commit
# wires link delivery through email.send + the outbox.

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-signup-smoke}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8198}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40298}"
BIN="${BIN:-./zig-out/bin/js-worker}"
TOKEN="${ROVE_TOKEN:-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd}"
ADMIN_HOST="api.test"
PORT="${HTTP_ADDR##*:}"
ADMIN_ORIGIN="http://${ADMIN_HOST}:${PORT}"

if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN missing — run 'zig build install' first" >&2
    exit 2
fi

rm -rf "$DATA_DIR"

"$BIN" \
    --node-id 0 \
    --peers "$RAFT_ADDR" \
    --listen "$RAFT_ADDR" \
    --http "$HTTP_ADDR" \
    --data-dir "$DATA_DIR" \
    --bootstrap-root-token "$TOKEN" \
    --admin-origin "$ADMIN_ORIGIN" \
    --admin-api-domain "$ADMIN_HOST" \
    --workers 1 \
    --refresh-interval-ms 100 \
    --fresh >/tmp/signup-smoke.out 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true' EXIT

sleep 1.2

RESOLVE=(--resolve "${ADMIN_HOST}:${PORT}:127.0.0.1")
CURL=(curl --http2-prior-knowledge -sS "${RESOLVE[@]}")

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    echo "--- worker log (last 40 lines) ---" >&2
    tail -40 /tmp/signup-smoke.out >&2
    exit 1
}

# ── 1. Fresh signup → 202 + magic_link in body ────────────────────────
resp=$("${CURL[@]}" -w "\nHTTP_STATUS=%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"alice","email":"alice@example.com"}' \
    "${ADMIN_ORIGIN}/v1/signup")
status=$(echo "$resp" | tail -n1 | sed 's/HTTP_STATUS=//')
body=$(echo "$resp" | sed '$d')
[[ "$status" == "202" ]] || fail "fresh signup got $status: $body"
echo "$body" | grep -q '"ok":true' || fail "signup body missing ok:true: $body"
echo "$body" | grep -q '"name":"alice"' || fail "signup body missing name: $body"
MAGIC_LINK=$(echo "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["magic_link"])')
[[ -n "$MAGIC_LINK" ]] || fail "signup body missing magic_link: $body"
ok "POST /v1/signup (fresh) → 202 + magic_link"

# Extract the token from the link (everything after mt=).
MT=$(echo "$MAGIC_LINK" | sed 's/.*mt=//')
[[ ${#MT} -eq 64 ]] || fail "magic token wrong length: ${#MT}"
ok "magic token is 64 hex chars"

# ── 2. Duplicate signup on same name → 409 ────────────────────────────
code=$("${CURL[@]}" -o /tmp/ss-dup.json -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"alice","email":"someone@example.com"}' \
    "${ADMIN_ORIGIN}/v1/signup")
[[ "$code" == "409" ]] || fail "duplicate name got $code"
grep -q '"error":"name unavailable"' /tmp/ss-dup.json || fail "duplicate name body: $(cat /tmp/ss-dup.json)"
ok "duplicate name → 409"

# ── 3. Reserved name → 409 (no enumeration via shape difference) ──────
code=$("${CURL[@]}" -o /tmp/ss-reserved.json -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"admin","email":"evil@example.com"}' \
    "${ADMIN_ORIGIN}/v1/signup")
[[ "$code" == "409" ]] || fail "reserved name got $code"
grep -q '"error":"name unavailable"' /tmp/ss-reserved.json || fail "reserved name body"
ok "reserved name → 409 (same shape as already-taken)"

# ── 4. Invalid email → 400 ────────────────────────────────────────────
code=$("${CURL[@]}" -o /tmp/ss-bademail.json -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"bob","email":"no-at-sign"}' \
    "${ADMIN_ORIGIN}/v1/signup")
[[ "$code" == "400" ]] || fail "bad email got $code"
ok "invalid email → 400"

# ── 5. Redeem the magic link → 302 + Set-Cookie + Location ───────────
hdrs=$("${CURL[@]}" -D - -o /dev/null -w '%{http_code}' "${ADMIN_ORIGIN}/v1/auth?mt=${MT}")
status=$(echo "$hdrs" | tail -n1)
[[ "$status" == "302" ]] || fail "redeem got $status"
echo "$hdrs" | grep -iq '^location: /#/alice' || fail "redeem missing Location: /#/alice"
echo "$hdrs" | grep -iq '^set-cookie: rove_session=' || fail "redeem missing session cookie"
echo "$hdrs" | grep -iq 'httponly' || fail "redeem cookie missing HttpOnly"
# Extract the cookie for the subsequent whoami check.
cookie=$(echo "$hdrs" | grep -i '^set-cookie:' \
    | sed 's/^[^:]*: //' | awk -F'; ' '{print $1}' | tr -d '\r')
ok "GET /v1/auth?mt=... → 302 + session cookie + Location:/#/alice"

# ── 6. Cookie authenticates /v1/session ───────────────────────────────
whoami=$("${CURL[@]}" -H "Cookie: $cookie" "${ADMIN_ORIGIN}/v1/session")
echo "$whoami" | grep -q '"is_root":true' || fail "whoami after magic: $whoami"
ok "magic-link session authenticates /v1/session"

# ── 7. Magic link is single-use — second redeem fails ─────────────────
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${ADMIN_ORIGIN}/v1/auth?mt=${MT}")
[[ "$code" == "401" ]] || fail "replay got $code (want 401)"
ok "second redeem of the same link → 401 (single-use)"

# ── 8. Expired / malformed tokens → 401 ───────────────────────────────
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${ADMIN_ORIGIN}/v1/auth?mt=zz")
[[ "$code" == "401" ]] || fail "malformed mt got $code"
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${ADMIN_ORIGIN}/v1/auth")
[[ "$code" == "401" ]] || fail "missing mt got $code"
ok "malformed / missing magic token → 401"

# ── 9. The freshly-signed-up instance exists in listInstance ──────────
list=$("${CURL[@]}" -H "Authorization: Bearer $TOKEN" "${ADMIN_ORIGIN}/?fn=listInstance")
echo "$list" | grep -q '"id":"alice"' || fail "listInstance missing alice: $list"
ok "signup-created instance visible via listInstance"

echo ""
echo "all signup smoke checks passed"
