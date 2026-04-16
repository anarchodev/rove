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

# ── 16. Seed KV state via the acme hit-counter handler ────────────
# The `acme` tenant ships with `kv.set("hits", ...)` as its handler,
# so a few plain GETs populate a known key we can read back through
# the admin KV endpoint. Host header picks the tenant.
for _ in 1 2 3; do
    "${CURL_BASE[@]}" -o /dev/null -H "Host: acme.test" "http://$HTTP_ADDR/"
done
ok "seeded acme KV via 3 handler requests"

# ── 17. KV list returns the seeded key ────────────────────────────
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/kv/acme")
echo "$resp" | grep -q '"key":"hits"' || fail "kv list missing hits key: $resp"
echo "$resp" | grep -q '"value_b64":"Mw=="' || fail "kv list wrong value_b64 (want Mw== = base64 of \"3\"): $resp"
ok "GET /_system/kv/{id} lists keys with base64 values"

# ── 18. KV single-get returns raw bytes ───────────────────────────
code=$("${CURL_BASE[@]}" -o /tmp/admin-smoke-kv.bin -w '%{http_code}' \
    "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/kv/acme/value?key=hits")
[[ "$code" == "200" ]] || fail "kv value (got $code)"
val=$(cat /tmp/admin-smoke-kv.bin)
[[ "$val" == "3" ]] || fail "kv value: expected '3', got '$val'"
ok "GET /_system/kv/{id}/value?key=... returns raw bytes"

# ── 19. KV single-get missing-key returns 404 ─────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
    "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/kv/acme/value?key=neverset")
[[ "$code" == "404" ]] || fail "kv unknown key (got $code)"
ok "GET /_system/kv/{id}/value unknown key → 404"

# ── 20. KV prefix filter ──────────────────────────────────────────
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/kv/acme?prefix=hi")
echo "$resp" | grep -q '"key":"hits"' || fail "prefix=hi didn't include hits: $resp"
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/kv/acme?prefix=zz")
echo "$resp" | grep -q '"entries":\[\]' || fail "prefix=zz should be empty: $resp"
ok "kv prefix filter returns the matching subset"

# ── 21. KV cursor pagination over randwrite (handler mints UUIDs) ─
for _ in 1 2 3 4 5; do
    "${CURL_BASE[@]}" -o /dev/null -H "Host: randwrite.test" "http://$HTTP_ADDR/"
done
page1=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/kv/randwrite?limit=2")
count1=$(printf '%s' "$page1" | grep -oE '"key":' | wc -l | tr -d ' ')
[[ "$count1" == "2" ]] || fail "page1 should have 2 entries, got $count1: $page1"
printf '%s' "$page1" | grep -q '"next_cursor":' || fail "page1 missing next_cursor: $page1"
# Extract cursor value (first-match sed, newline-free).
cursor=$(printf '%s' "$page1" | sed -E 's/.*"next_cursor":"([^"]*)".*/\1/')
page2=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" \
    "http://$HTTP_ADDR/_system/kv/randwrite?limit=2&cursor=$cursor")
count2=$(printf '%s' "$page2" | grep -oE '"key":' | wc -l | tr -d ' ')
[[ "$count2" == "2" ]] || fail "page2 should have 2 entries, got $count2: $page2"
# Page2's first key must be strictly greater than the cursor.
printf '%s' "$page2" | grep -q "\"key\":\"$cursor\"" && fail "cursor was echoed as page2 entry"
ok "kv cursor pagination advances past prior page's last key"

# ── 22. KV on unknown instance → 404 ─────────────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
    "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/kv/ghost")
[[ "$code" == "404" ]] || fail "unknown instance (got $code)"
ok "kv list for unknown instance → 404"

# ── 23. Log count reflects the seeded requests ────────────────────
# Log flushing is time-based (flush_interval_ns = 1s by default);
# give the worker a tick to drain the in-memory batch.
sleep 1.5
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/log/acme/count")
# resp is plain "<N>\n"; expect at least 3 from the KV seed.
count_n=$(printf '%s' "$resp" | tr -d '[:space:]')
[[ "$count_n" -ge 3 ]] || fail "log count: expected >=3, got '$count_n'"
ok "GET /_system/log/{id}/count returns a decimal"

# ── 24. Log list returns records (proxied + CORS-wrapped) ─────────
headers=$("${CURL_BASE[@]}" -D /tmp/admin-smoke-log-hdrs.txt -o /tmp/admin-smoke-log.json \
    "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/log/acme/list?limit=50")
grep -iq "access-control-allow-origin: $ORIGIN" /tmp/admin-smoke-log-hdrs.txt \
    || fail "log list missing CORS header"
rec_count=$(grep -oE '"request_id":' /tmp/admin-smoke-log.json | wc -l | tr -d ' ')
[[ "$rec_count" -ge 3 ]] || fail "log list: expected >=3 records, got $rec_count"
ok "GET /_system/log/{id}/list returns records with CORS headers"

# ── 25. Log show returns full record for a known id ───────────────
req_id=$(sed -E 's/.*"request_id":"([0-9a-f]+)".*/\1/' /tmp/admin-smoke-log.json | head -1)
[[ ${#req_id} -eq 16 ]] || fail "couldn't parse request_id (got '$req_id')"
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/log/acme/show/$req_id")
printf '%s' "$resp" | grep -q "\"request_id\":\"$req_id\"" \
    || fail "log show: request_id mismatch: $resp"
printf '%s' "$resp" | grep -q '"host":"acme.test"' \
    || fail "log show: missing host field: $resp"
ok "GET /_system/log/{id}/show/{hex} returns the full record"

# ── 26. Log show with unknown id → 404 ────────────────────────────
# ffffffffffffffff is the top of the u64 request-id space; real seqs
# come from a counter that starts at 0 and increments, so ffff...f is
# guaranteed unseen. (0000000000000000 WOULD have matched the first
# acme request — the log-store's seq counter starts at 0, a pre-
# existing quirk worth noting but not fixing here.)
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
    "${AUTH_HDR[@]}" "http://$HTTP_ADDR/_system/log/acme/show/ffffffffffffffff")
[[ "$code" == "404" ]] || fail "unknown log id (got $code)"
ok "log show with unknown id → 404"

echo ""
echo "all admin smoke tests passed"
