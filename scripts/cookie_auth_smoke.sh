#!/usr/bin/env bash
# End-to-end smoke test for cookie-based admin login on the prod-shape
# origin (UI + API served from the same subdomain).
#
# Covers:
#   - Public GET of the admin UI bundle (index.html, app.js, ...) without auth
#   - POST /v1/login with a good token → 200 + Set-Cookie rove_session
#   - POST /v1/login with a bad token → 401 (no cookie issued)
#   - Authed admin RPC via cookie (no Authorization header) → 200
#   - Unauthed admin RPC → 401
#   - Logout clears the server-side session + expires the cookie
#   - Bearer token still works side-by-side (back-compat)

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-cookie-smoke}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8196}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40296}"
BIN="${BIN:-./zig-out/bin/js-worker}"
TOKEN="${ROVE_TOKEN:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
API_HOST="api.test"
PORT="${HTTP_ADDR##*:}"
ORIGIN="http://${API_HOST}:${PORT}"

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
    --admin-origin "$ORIGIN" \
    --admin-api-domain "$API_HOST" \
    --workers 1 \
    --refresh-interval-ms 100 \
    --fresh >/tmp/cookie-smoke.out 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true' EXIT

sleep 1.2

RESOLVE=(--resolve "${API_HOST}:${PORT}:127.0.0.1")
CURL=(curl --http2-prior-knowledge -sS "${RESOLVE[@]}")

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    echo "--- worker log (last 30 lines) ---" >&2
    tail -30 /tmp/cookie-smoke.out >&2
    exit 1
}

# ── 1. UI bundle is public ────────────────────────────────────────────
code=$("${CURL[@]}" -o /tmp/cs-index.html -w '%{http_code}' "${ORIGIN}/")
[[ "$code" == "200" ]] || fail "GET / (no auth) got $code"
grep -q '<!doctype html>' /tmp/cs-index.html || fail "GET / body not HTML"
ok "GET / serves the UI bundle without auth"

code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${ORIGIN}/app.js")
[[ "$code" == "200" ]] || fail "GET /app.js got $code"
ok "GET /app.js serves without auth"

# ── 2. Unauthed admin RPC → 401 ──────────────────────────────────────
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${ORIGIN}/?fn=listInstance")
[[ "$code" == "401" ]] || fail "unauthed /?fn=listInstance got $code"
ok "unauthed admin RPC → 401"

# ── 3. Bad token → 401, no Set-Cookie ────────────────────────────────
hdrs=$("${CURL[@]}" -D - -o /dev/null -X POST \
    -H "Content-Type: application/json" \
    -d '{"token":"0000000000000000000000000000000000000000000000000000000000000000"}' \
    "${ORIGIN}/v1/login")
echo "$hdrs" | head -1 | grep -q " 401" || fail "bad-token login status"
if echo "$hdrs" | grep -iq "^set-cookie:"; then
    fail "bad-token login emitted Set-Cookie"
fi
ok "POST /v1/login with bad token → 401, no Set-Cookie"

# ── 4. Good token → 200 + Set-Cookie ─────────────────────────────────
hdrs=$("${CURL[@]}" -D - -o /tmp/cs-login.json -X POST \
    -H "Content-Type: application/json" \
    -d "{\"token\":\"$TOKEN\"}" \
    "${ORIGIN}/v1/login")
echo "$hdrs" | head -1 | grep -q " 200" || fail "login status"
echo "$hdrs" | grep -iq "^set-cookie: rove_session=" || fail "login missing Set-Cookie"
echo "$hdrs" | grep -iq "httponly" || fail "login cookie missing HttpOnly"
echo "$hdrs" | grep -iq "samesite=lax" || fail "login cookie missing SameSite=Lax"
echo "$hdrs" | grep -iq "secure" || fail "login cookie missing Secure"
grep -q '"ok":true' /tmp/cs-login.json || fail "login body not ok"
# Extract cookie for replay. The Secure attribute means curl won't
# autosave it over plain HTTP, so we do it by hand.
cookie=$(echo "$hdrs" | grep -i "^set-cookie:" \
    | sed 's/^[^:]*: //' | awk -F'; ' '{print $1}' | tr -d '\r')
ok "POST /v1/login → 200 + HttpOnly+Secure+SameSite=Lax cookie"

# ── 5. Authed admin RPC via cookie ────────────────────────────────────
body=$("${CURL[@]}" -H "Cookie: $cookie" "${ORIGIN}/?fn=listInstance")
echo "$body" | grep -q '"id":"__admin__"' || fail "authed RPC missing __admin__: $body"
ok "authed admin RPC via cookie → 200"

# ── 6. /v1/session returns is_root ───────────────────────────────────
body=$("${CURL[@]}" -H "Cookie: $cookie" "${ORIGIN}/v1/session")
echo "$body" | grep -q '"is_root":true' || fail "session body: $body"
ok "GET /v1/session → {is_root:true}"

# ── 7. Logout: 200 + expired cookie, session no longer authenticates ─
hdrs=$("${CURL[@]}" -D - -o /dev/null -X POST \
    -H "Cookie: $cookie" "${ORIGIN}/v1/logout")
echo "$hdrs" | head -1 | grep -q " 200" || fail "logout status"
echo "$hdrs" | grep -iq "^set-cookie: rove_session=;" || fail "logout didn't clear cookie"
echo "$hdrs" | grep -iq "max-age=0" || fail "logout cookie missing Max-Age=0"

code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    -H "Cookie: $cookie" "${ORIGIN}/?fn=listInstance")
[[ "$code" == "401" ]] || fail "post-logout RPC with same cookie got $code"
ok "POST /v1/logout revokes session (subsequent cookie use → 401)"

# ── 8. Bearer fallback still works (back-compat) ──────────────────────
body=$("${CURL[@]}" -H "Authorization: Bearer $TOKEN" -H "Origin: $ORIGIN" \
    "${ORIGIN}/?fn=listInstance")
echo "$body" | grep -q '"id":"__admin__"' || fail "bearer fallback body: $body"
ok "Authorization: Bearer still works alongside cookies"

# ── 9. /v1/session without auth → 401 ────────────────────────────────
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${ORIGIN}/v1/session")
[[ "$code" == "401" ]] || fail "unauthed /v1/session got $code"
ok "unauthed /v1/session → 401"

echo ""
echo "all cookie auth smoke tests passed"
