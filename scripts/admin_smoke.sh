#!/usr/bin/env bash
# End-to-end smoke test for the admin `/_system/*` surface: CORS
# preflight + response headers, bearer-token auth, and tenant CRUD.
#
# Starts a single-worker js-worker with `--admin-origin` set, then
# walks through the endpoints the browser admin UI will call.

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-admin-smoke}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8198}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40298}"
ORIGIN="${ADMIN_ORIGIN:-http://localhost:5173}"
BIN="${BIN:-./zig-out/bin/js-worker}"
TOKEN="${ROVE_TOKEN:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"

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
    --workers 1 \
    --fresh >/tmp/admin-smoke.out 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true' EXIT

sleep 1.0

CURL_BASE=(curl --http2-prior-knowledge -sS)
AUTH_HDR=(-H "Authorization: Bearer $TOKEN" -H "Origin: $ORIGIN")

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    echo "--- worker log ---" >&2
    tail -30 /tmp/admin-smoke.out >&2
    exit 1
}

# ── 1. Preflight with allowed origin → 204 + CORS headers ──────────
resp=$("${CURL_BASE[@]}" -D - -o /dev/null \
    -X OPTIONS "http://$HTTP_ADDR/_system/tenant/instance" \
    -H "Origin: $ORIGIN" \
    -H "Access-Control-Request-Method: POST" \
    -H "Access-Control-Request-Headers: authorization, content-type")
echo "$resp" | head -1 | grep -q " 204" || fail "preflight status (got: $(echo "$resp" | head -1))"
echo "$resp" | grep -iq "access-control-allow-origin: $ORIGIN" || fail "preflight allow-origin header missing"
echo "$resp" | grep -iq "access-control-allow-methods:" || fail "preflight allow-methods header missing"
echo "$resp" | grep -iq "access-control-max-age:" || fail "preflight max-age header missing"
ok "preflight returns 204 with CORS headers"

# ── 2. Preflight with disallowed origin → 403 ───────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
    -X OPTIONS "http://$HTTP_ADDR/_system/tenant/instance" \
    -H "Origin: http://evil.example.com")
[[ "$code" == "403" ]] || fail "preflight rejects wrong origin (got $code)"
ok "preflight rejects wrong origin"

# ── 3. Missing bearer token → 401 ──────────────────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
    -H "Origin: $ORIGIN" \
    "http://$HTTP_ADDR/_system/tenant/instance")
[[ "$code" == "401" ]] || fail "missing token (got $code)"
ok "missing bearer token returns 401"

# ── 4. Bad bearer token → 401 ──────────────────────────────────────
bad_token=$(printf '0%.0s' {1..64})
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
    -H "Origin: $ORIGIN" \
    -H "Authorization: Bearer $bad_token" \
    "http://$HTTP_ADDR/_system/tenant/instance")
[[ "$code" == "401" ]] || fail "bad token (got $code)"
ok "bad bearer token returns 401"

# ── 5. List instances — includes the bootstrap tenants ────────────
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/tenant/instance")
echo "$resp" | grep -q '"id":"acme"' || fail "list instances missing acme: $resp"
ok "GET /instance lists bootstrap tenants"

# ── 6. Create a new instance ──────────────────────────────────────
code=$("${CURL_BASE[@]}" -o /tmp/admin-smoke-create.json -w '%{http_code}' \
    "${AUTH_HDR[@]}" -H "Content-Type: application/json" \
    -d '{"id":"admintest"}' \
    "http://$HTTP_ADDR/_system/tenant/instance")
[[ "$code" == "201" ]] || fail "POST /instance (got $code)"
grep -q '"id":"admintest"' /tmp/admin-smoke-create.json || fail "create response body: $(cat /tmp/admin-smoke-create.json)"
ok "POST /instance creates new instance"

# ── 7. Malformed POST body → 400 ──────────────────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
    "${AUTH_HDR[@]}" -H "Content-Type: application/json" \
    -d 'not-json' \
    "http://$HTTP_ADDR/_system/tenant/instance")
[[ "$code" == "400" ]] || fail "bad json (got $code)"
ok "POST /instance with bad JSON returns 400"

# ── 8. GET existing instance → 200 ────────────────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
    "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/tenant/instance/admintest")
[[ "$code" == "200" ]] || fail "GET existing instance (got $code)"
ok "GET /instance/{id} returns 200 for existing"

# ── 9. GET unknown instance → 404 ─────────────────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
    "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/tenant/instance/neverexisted")
[[ "$code" == "404" ]] || fail "GET unknown instance (got $code)"
ok "GET /instance/{id} returns 404 for unknown"

# ── 10. Assign a domain ───────────────────────────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
    "${AUTH_HDR[@]}" -H "Content-Type: application/json" \
    -d '{"host":"admintest.example.com","instance_id":"admintest"}' \
    "http://$HTTP_ADDR/_system/tenant/domain")
[[ "$code" == "201" ]] || fail "POST /domain (got $code)"
ok "POST /domain assigns host → instance"

# ── 11. Assign domain to unknown instance → 404 ───────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
    "${AUTH_HDR[@]}" -H "Content-Type: application/json" \
    -d '{"host":"dangling.test","instance_id":"does-not-exist"}' \
    "http://$HTTP_ADDR/_system/tenant/domain")
[[ "$code" == "404" ]] || fail "POST /domain for unknown instance (got $code)"
ok "POST /domain rejects unknown instance"

# ── 12. List domains — includes the new assignment ────────────────
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/tenant/domain")
echo "$resp" | grep -q '"host":"admintest.example.com"' || fail "domain listing missing host: $resp"
echo "$resp" | grep -q '"instance_id":"admintest"' || fail "domain listing missing instance_id: $resp"
ok "GET /domain lists assignment"

# ── 13. Delete instance ───────────────────────────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
    -X DELETE "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/tenant/instance/admintest")
[[ "$code" == "204" ]] || fail "DELETE /instance (got $code)"
ok "DELETE /instance/{id} returns 204"

# ── 14. After delete: exists → 404, domain is swept ───────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
    "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/tenant/instance/admintest")
[[ "$code" == "404" ]] || fail "deleted instance still visible ($code)"
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/tenant/domain")
if echo "$resp" | grep -q "admintest.example.com"; then
    fail "dangling domain survived delete: $resp"
fi
ok "DELETE sweeps dangling domains"

# ── 15. Real GET response carries CORS headers ────────────────────
headers=$("${CURL_BASE[@]}" -D - -o /dev/null "${AUTH_HDR[@]}" \
    "http://$HTTP_ADDR/_system/tenant/instance")
echo "$headers" | grep -iq "access-control-allow-origin: $ORIGIN" || fail "CORS header missing on GET: $headers"
echo "$headers" | grep -iq "content-type: application/json" || fail "content-type missing on GET: $headers"
ok "real response carries CORS + content-type headers"

echo ""
echo "all admin smoke tests passed"
