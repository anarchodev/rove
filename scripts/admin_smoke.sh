#!/usr/bin/env bash
# End-to-end smoke test for the admin RPC API.
#
# Contract:
#   - Every call is a named export on the `__admin__` handler.
#   - GET:  ?fn=<name>[&args=<url-encoded-JSON-array>]
#   - POST: JSON body {"fn":"<name>","args":[...]}
#   - Return value is the response body (auto-JSON for objects).
#   - Status / headers / cookies come from the `response` global.
#
# Two scopes:
#   - bare admin domain `api.test`  → kv = root (tenant + domain CRUD)
#   - `{id}.api.test`               → kv = {id}'s app.db (KV browsing)
#
# Log + code stay as native Zig proxies under /_system/log/* and
# /_system/files/* — tested separately.

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-admin-smoke}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8198}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40298}"
ORIGIN="${ADMIN_ORIGIN:-http://localhost:5173}"
BIN="${BIN:-./zig-out/bin/js-worker}"
TOKEN="${ROVE_TOKEN:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
API_HOST="api.test"
PORT="${HTTP_ADDR##*:}"
API_URL_BASE="http://${API_HOST}:${PORT}"
ACME_URL="http://acme.${API_HOST}:${PORT}"
RW_URL="http://randwrite.${API_HOST}:${PORT}"

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
    --fresh >/tmp/admin-smoke.out 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true' EXIT

sleep 1.2

RESOLVE_FLAGS=(
    --resolve "${API_HOST}:${PORT}:127.0.0.1"
    --resolve "admintest.${API_HOST}:${PORT}:127.0.0.1"
    --resolve "acme.${API_HOST}:${PORT}:127.0.0.1"
    --resolve "randwrite.${API_HOST}:${PORT}:127.0.0.1"
    --resolve "ghost.${API_HOST}:${PORT}:127.0.0.1"
)
CURL_BASE=(curl --http2-prior-knowledge -sS "${RESOLVE_FLAGS[@]}")
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
    -X OPTIONS "${API_URL_BASE}/?fn=listInstance" \
    -H "Origin: $ORIGIN" \
    -H "Access-Control-Request-Method: POST" \
    -H "Access-Control-Request-Headers: authorization, content-type")
echo "$resp" | head -1 | grep -q " 204" || fail "preflight status"
echo "$resp" | grep -iq "access-control-allow-origin: $ORIGIN" || fail "preflight allow-origin"
echo "$resp" | grep -iq "access-control-allow-methods:" || fail "preflight allow-methods"
ok "preflight returns 204 with CORS headers"

# ── 2. Preflight with disallowed origin → 403 ───────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
    -X OPTIONS "${API_URL_BASE}/?fn=listInstance" \
    -H "Origin: http://evil.example.com")
[[ "$code" == "403" ]] || fail "preflight rejects wrong origin (got $code)"
ok "preflight rejects wrong origin"

# ── 3. Missing bearer token → 401 ──────────────────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
    -H "Origin: $ORIGIN" \
    "${API_URL_BASE}/?fn=listInstance")
[[ "$code" == "401" ]] || fail "missing token (got $code)"
ok "missing bearer token returns 401"

# ── 4. Bad bearer token → 401 ──────────────────────────────────────
bad_token=$(printf '0%.0s' {1..64})
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
    -H "Origin: $ORIGIN" -H "Authorization: Bearer $bad_token" \
    "${API_URL_BASE}/?fn=listInstance")
[[ "$code" == "401" ]] || fail "bad token (got $code)"
ok "bad bearer token returns 401"

# ── 5. listInstance includes bootstrap tenants + __admin__ ─────────
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "${API_URL_BASE}/?fn=listInstance")
echo "$resp" | grep -q '"id":"acme"' || fail "listInstance missing acme: $resp"
echo "$resp" | grep -q '"id":"__admin__"' || fail "listInstance missing __admin__"
ok "GET ?fn=listInstance returns the tenant list"

# ── 6. POST createInstance ─────────────────────────────────────────
code=$("${CURL_BASE[@]}" -o /tmp/admin-smoke-create.json -w '%{http_code}' \
    "${AUTH_HDR[@]}" -H "Content-Type: application/json" \
    -d '{"fn":"createInstance","args":["admintest"]}' \
    "${API_URL_BASE}/")
[[ "$code" == "201" ]] || fail "createInstance (got $code)"
grep -q '"id":"admintest"' /tmp/admin-smoke-create.json || fail "create response body"
ok "POST createInstance creates new instance"

# ── 7. Malformed RPC envelope → 400 ──────────────────────────────
# Valid JSON, but `fn` is not a string → BadRequest. (A non-JSON body
# or a JSON body without `fn` is now treated as opaque payload and
# routed to the default export — admin has none, so that path returns
# 404 instead. We test the envelope-shape error here.)
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
    "${AUTH_HDR[@]}" -H "Content-Type: application/json" \
    -d '{"fn":42}' "${API_URL_BASE}/")
[[ "$code" == "400" ]] || fail "malformed RPC envelope (got $code)"
ok "POST with malformed RPC envelope returns 400"

# ── 8. getInstance existing → 200 ──────────────────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' "${AUTH_HDR[@]}" \
    "${API_URL_BASE}/?fn=getInstance&args=%5B%22admintest%22%5D")
[[ "$code" == "200" ]] || fail "getInstance existing (got $code)"
ok "GET getInstance returns 200 for existing"

# ── 9. getInstance unknown → 404 ───────────────────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' "${AUTH_HDR[@]}" \
    "${API_URL_BASE}/?fn=getInstance&args=%5B%22neverexisted%22%5D")
[[ "$code" == "404" ]] || fail "getInstance unknown (got $code)"
ok "GET getInstance returns 404 for unknown"

# ── 10. assignDomain ──────────────────────────────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' "${AUTH_HDR[@]}" \
    -H "Content-Type: application/json" \
    -d '{"fn":"assignDomain","args":["admintest.example.com","admintest"]}' \
    "${API_URL_BASE}/")
[[ "$code" == "201" ]] || fail "assignDomain (got $code)"
ok "POST assignDomain assigns host → instance"

# ── 11. assignDomain unknown instance → 404 ───────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' "${AUTH_HDR[@]}" \
    -H "Content-Type: application/json" \
    -d '{"fn":"assignDomain","args":["dangling.test","does-not-exist"]}' \
    "${API_URL_BASE}/")
[[ "$code" == "404" ]] || fail "assignDomain unknown instance (got $code)"
ok "POST assignDomain rejects unknown instance"

# ── 12. listDomain includes the new assignment ────────────────────
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "${API_URL_BASE}/?fn=listDomain")
echo "$resp" | grep -q '"host":"admintest.example.com"' || fail "domain listing missing host"
echo "$resp" | grep -q '"instance_id":"admintest"' || fail "domain listing missing instance_id"
ok "GET listDomain lists assignment"

# ── 13. deleteInstance ────────────────────────────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' "${AUTH_HDR[@]}" \
    -H "Content-Type: application/json" \
    -d '{"fn":"deleteInstance","args":["admintest"]}' "${API_URL_BASE}/")
[[ "$code" == "204" ]] || fail "deleteInstance (got $code)"
ok "POST deleteInstance returns 204"

# ── 14. After delete: 404 + dangling domains swept ────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' "${AUTH_HDR[@]}" \
    "${API_URL_BASE}/?fn=getInstance&args=%5B%22admintest%22%5D")
[[ "$code" == "404" ]] || fail "deleted instance still visible ($code)"
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "${API_URL_BASE}/?fn=listDomain")
if echo "$resp" | grep -q "admintest.example.com"; then
    fail "dangling domain survived delete"
fi
ok "deleteInstance sweeps dangling domains"

# ── 15. Real GET response carries CORS headers ────────────────────
headers=$("${CURL_BASE[@]}" -D - -o /dev/null "${AUTH_HDR[@]}" \
    "${API_URL_BASE}/?fn=listInstance")
echo "$headers" | grep -iq "access-control-allow-origin: $ORIGIN" || fail "CORS header missing"
ok "real response carries CORS headers"

# ── 16. Seed acme via its named export ────────────────────────────
for _ in 1 2 3; do
    "${CURL_BASE[@]}" -o /dev/null -H "Host: acme.test" "http://$HTTP_ADDR/?fn=handler"
done
ok "seeded acme KV via 3 handler requests"

# ── 17. listKv on tenant subdomain → reads acme's store ───────────
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "${ACME_URL}/?fn=listKv")
echo "$resp" | grep -q '"key":"hits"' || fail "listKv missing hits: $resp"
echo "$resp" | grep -q '"value":"3"' || fail "listKv value mismatch (want 3): $resp"
ok "GET {id}.api?fn=listKv returns tenant KV"

# ── 18. getKv returns the value as-is ─────────────────────────────
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" \
    "${ACME_URL}/?fn=getKv&args=%5B%22hits%22%5D")
[[ "$resp" == "3" ]] || fail "getKv: expected '3', got '$resp'"
ok "GET getKv returns the raw string value"

# ── 19. getKv unknown key → 404 ───────────────────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' "${AUTH_HDR[@]}" \
    "${ACME_URL}/?fn=getKv&args=%5B%22neverset%22%5D")
[[ "$code" == "404" ]] || fail "getKv unknown (got $code)"
ok "getKv unknown key → 404"

# ── 20. listKv prefix filter ──────────────────────────────────────
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" \
    "${ACME_URL}/?fn=listKv&args=%5B%22hi%22%5D")
echo "$resp" | grep -q '"key":"hits"' || fail "prefix=hi: missing hits: $resp"
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" \
    "${ACME_URL}/?fn=listKv&args=%5B%22zz%22%5D")
echo "$resp" | grep -q '"entries":\[\]' || fail "prefix=zz should be empty: $resp"
ok "listKv prefix filter"

# ── 21. listKv cursor pagination over randwrite ───────────────────
for _ in 1 2 3 4 5; do
    "${CURL_BASE[@]}" -o /dev/null -H "Host: randwrite.test" "http://$HTTP_ADDR/?fn=handler"
done
page1=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" \
    "${RW_URL}/?fn=listKv&args=%5B%22%22%2C%22%22%2C2%5D")
# args: ["", "", 2]
count1=$(printf '%s' "$page1" | grep -oE '"key":' | wc -l | tr -d ' ')
[[ "$count1" == "2" ]] || fail "page1 should have 2 entries, got $count1: $page1"
printf '%s' "$page1" | grep -q '"next_cursor":' || fail "page1 missing next_cursor"
cursor=$(printf '%s' "$page1" | sed -E 's/.*"next_cursor":"([^"]*)".*/\1/')
cursor_encoded=$(printf '%s' "$cursor" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))')
args_page2="%5B%22%22%2C%22${cursor_encoded}%22%2C2%5D"
page2=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" \
    "${RW_URL}/?fn=listKv&args=${args_page2}")
count2=$(printf '%s' "$page2" | grep -oE '"key":' | wc -l | tr -d ' ')
[[ "$count2" == "2" ]] || fail "page2 should have 2 entries, got $count2: $page2"
printf '%s' "$page2" | grep -q "\"key\":\"$cursor\"" && fail "cursor echoed in page2"
ok "listKv cursor pagination advances past prior page's last key"

# ── 22. unknown instance subdomain → listKv returns empty ─────────
# (listKv doesn't know or care — it just reads whatever kv the
# dispatcher bound. For a never-created instance, the scope tenant's
# lazy-open creates a fresh app.db and the scan returns no entries.)
# We test the dispatcher's "unknown instance" 404 here — a subdomain
# request where the instance id doesn't exist in the root store.
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' "${AUTH_HDR[@]}" \
    "http://ghost.${API_HOST}:${PORT}/?fn=listKv")
[[ "$code" == "404" ]] || fail "ghost subdomain should 404 (got $code)"
ok "{unknown}.api → 404"

# ── 23. Log count reflects seeded requests (native proxy) ─────────
sleep 1.5
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "${API_URL_BASE}/_system/log/acme/count")
count_n=$(printf '%s' "$resp" | tr -d '[:space:]')
[[ "$count_n" -ge 3 ]] || fail "log count: expected >=3, got '$count_n'"
ok "GET /_system/log/{id}/count returns a decimal"

# ── 24. Log list returns records with CORS headers ────────────────
headers_file=/tmp/admin-smoke-log-hdrs.txt
"${CURL_BASE[@]}" -D "$headers_file" -o /tmp/admin-smoke-log.json \
    "${AUTH_HDR[@]}" "${API_URL_BASE}/_system/log/acme/list?limit=50" >/dev/null
grep -iq "access-control-allow-origin: $ORIGIN" "$headers_file" \
    || fail "log list missing CORS header"
rec_count=$(grep -oE '"request_id":' /tmp/admin-smoke-log.json | wc -l | tr -d ' ')
[[ "$rec_count" -ge 3 ]] || fail "log list: expected >=3 records, got $rec_count"
ok "GET /_system/log/{id}/list returns records + CORS"

# ── 25. Log show returns full record for a known id ───────────────
req_id=$(sed -E 's/.*"request_id":"([0-9a-f]+)".*/\1/' /tmp/admin-smoke-log.json | head -1)
[[ ${#req_id} -eq 16 ]] || fail "couldn't parse request_id (got '$req_id')"
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "${API_URL_BASE}/_system/log/acme/show/$req_id")
printf '%s' "$resp" | grep -q "\"request_id\":\"$req_id\"" \
    || fail "log show: request_id mismatch"
ok "GET /_system/log/{id}/show/{hex} returns the full record"

# ── 26. Log show with unknown id → 404 ────────────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' "${AUTH_HDR[@]}" \
    "${API_URL_BASE}/_system/log/acme/show/ffffffffffffffff")
[[ "$code" == "404" ]] || fail "unknown log id (got $code)"
ok "log show with unknown id → 404"

echo ""
echo "all admin smoke tests passed"
