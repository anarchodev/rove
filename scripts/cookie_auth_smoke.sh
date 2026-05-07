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

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-cookie-smoke}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8235}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40335}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
API_HOST="app.loop46.localhost"
PUBLIC_SUFFIX="loop46.localhost"

if [[ "$(uname -s)" == "Darwin" ]]; then
    LOOP46_DATA="${LOOP46_DATA:-$HOME/Library/Application Support/loop46}"
else
    LOOP46_DATA="${LOOP46_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/loop46}"
fi
TLS_CERT="$LOOP46_DATA/dev-cert.pem"
TLS_KEY="$LOOP46_DATA/dev-key.pem"
CACERT="$LOOP46_DATA/ca-root.pem"

if [[ ! -f "$TLS_CERT" || ! -f "$TLS_KEY" ]]; then
    echo "error: missing dev TLS at $LOOP46_DATA. Run 'loop46 dev ...' once to bootstrap." >&2
    exit 2
fi

if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN missing — run 'zig build install' first" >&2
    exit 2
fi

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=cookie-smoke
SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

PIDS=()
for i in 0 1 2; do
    P="${HTTP_ADDRS[$i]##*:}"
    "$BIN" worker \
        --node-id "$i" \
        --peers "$PEERS_CSV" \
        --listen "${RAFT_ADDRS[$i]}" \
        --http "${HTTP_ADDRS[$i]}" \
        --data-dir "${DATA_DIRS[$i]}" \
        --bootstrap-root-token "$TOKEN" \
        --admin-origin "https://${API_HOST}:${P}" \
        --admin-api-domain "$API_HOST" \
        --public-suffix "$PUBLIC_SUFFIX" \
        --tls-cert "$TLS_CERT" \
        --tls-key "$TLS_KEY" \
        --workers 2 \
        >"/tmp/${SMOKE_TAG}-worker-${i}.out" 2>&1 &
    PIDS+=($!)
done
trap '
    for p in "${PIDS[@]}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done
    for p in "${PIDS[@]}"; do
        [ -n "$p" ] && wait "$p" 2>/dev/null || true
    done
' EXIT
sleep 2

RESOLVE=()
for h in "${HTTP_ADDRS[@]}"; do
    p="${h##*:}"
    RESOLVE+=(--resolve "${API_HOST}:${p}:127.0.0.1")
done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")

discover_leader "$API_HOST" "$TOKEN" || exit 1
echo "ok  leader elected: node $LEADER_IDX at $LEADER_HTTP"
PORT="$LEADER_PORT"
ORIGIN="https://${API_HOST}:${PORT}"

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    for i in 0 1 2; do
        echo "--- worker $i log ---" >&2
        tail -30 "/tmp/${SMOKE_TAG}-worker-${i}.out" >&2
    done
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
# The platform pre-mints `__Host-rove_sid` (a guest session id used
# by SSE) on every request — that's expected and not the auth
# cookie. Only `rove_session` (set on a successful login) should be
# absent on 401.
if echo "$hdrs" | grep -iE "^set-cookie:.*rove_session" >/dev/null; then
    fail "bad-token login emitted rove_session cookie"
fi
ok "POST /v1/login with bad token → 401, no rove_session cookie"

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
cookie=$(echo "$hdrs" | grep -iE "^set-cookie:.*rove_session" \
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
