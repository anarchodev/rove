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
# Scope:
#   - All admin calls hit the bare admin host (`app.loop46.localhost`).
#   - `kv.*` defaults to admin's own app.db (root surface for tenant +
#     domain CRUD lives behind `platform.root.*`).
#   - `X-Rove-Scope: <id>` rebinds `kv` onto `<id>`'s app.db so the
#     dashboard can browse a tenant's keyspace through admin handlers.
#
# Log + code stay as native Zig proxies under /_system/log/* and
# /_system/files/* — tested separately.

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-admin-smoke}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8198}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40298}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
API_HOST="app.loop46.localhost"
PUBLIC_SUFFIX="loop46.localhost"
PORT="${HTTP_ADDR##*:}"
API_URL_BASE="https://${API_HOST}:${PORT}"
ORIGIN="${ADMIN_ORIGIN:-$API_URL_BASE}"

# TLS via mkcert. `loop46 dev` generates the cert + installs the
# CA on first run; this smoke just consumes those files.
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

rm -rf "$DATA_DIR"

# Seed acme + randwrite (and the rest of the demo set) before starting
# the worker. The worker discovers tenants on disk; the manifest +
# files live under examples/.
"$BIN" seed \
    --data-dir "$DATA_DIR" \
    --manifest ./examples/loop46-demo-tenants.json \
    >/tmp/admin-smoke-seed.out 2>&1 || {
    echo "FAIL seed step:" >&2
    cat /tmp/admin-smoke-seed.out >&2
    exit 1
}

"$BIN" worker \
    --node-id 0 \
    --peers "$RAFT_ADDR" \
    --listen "$RAFT_ADDR" \
    --http "$HTTP_ADDR" \
    --data-dir "$DATA_DIR" \
    --bootstrap-root-token "$TOKEN" \
    --admin-origin "$ORIGIN" \
    --public-suffix "$PUBLIC_SUFFIX" \
    --tls-cert "$TLS_CERT" \
    --tls-key "$TLS_KEY" \
    --workers 1 >/tmp/admin-smoke.out 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true' EXIT

sleep 1.2

RESOLVE_FLAGS=(
    --resolve "${API_HOST}:${PORT}:127.0.0.1"
    --resolve "acme.${PUBLIC_SUFFIX}:${PORT}:127.0.0.1"
    --resolve "randwrite.${PUBLIC_SUFFIX}:${PORT}:127.0.0.1"
)
CURL_BASE=(curl -sS --cacert "$CACERT" "${RESOLVE_FLAGS[@]}")
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
# Hits the customer-facing tenant URL (not the admin host) so the
# request runs the acme handler, which bumps a `hits` counter in
# acme's app.db.
ACME_URL="https://acme.${PUBLIC_SUFFIX}:${PORT}"
for _ in 1 2 3; do
    "${CURL_BASE[@]}" -o /dev/null "${ACME_URL}/?fn=handler"
done
ok "seeded acme KV via 3 handler requests"

# ── 17. listKv with X-Rove-Scope: acme → reads acme's store ───────
SCOPE_ACME=(-H "X-Rove-Scope: acme")
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "${SCOPE_ACME[@]}" "${API_URL_BASE}/?fn=listKv")
echo "$resp" | grep -q '"key":"hits"' || fail "listKv missing hits: $resp"
echo "$resp" | grep -q '"value":"3"' || fail "listKv value mismatch (want 3): $resp"
ok "GET ?fn=listKv with X-Rove-Scope: acme returns tenant KV"

# ── 18. getKv returns the value as-is ─────────────────────────────
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "${SCOPE_ACME[@]}" \
    "${API_URL_BASE}/?fn=getKv&args=%5B%22hits%22%5D")
[[ "$resp" == "3" ]] || fail "getKv: expected '3', got '$resp'"
ok "GET getKv returns the raw string value"

# ── 19. getKv unknown key → 404 ───────────────────────────────────
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' "${AUTH_HDR[@]}" "${SCOPE_ACME[@]}" \
    "${API_URL_BASE}/?fn=getKv&args=%5B%22neverset%22%5D")
[[ "$code" == "404" ]] || fail "getKv unknown (got $code)"
ok "getKv unknown key → 404"

# ── 20. listKv prefix filter ──────────────────────────────────────
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "${SCOPE_ACME[@]}" \
    "${API_URL_BASE}/?fn=listKv&args=%5B%22hi%22%5D")
echo "$resp" | grep -q '"key":"hits"' || fail "prefix=hi: missing hits: $resp"
resp=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "${SCOPE_ACME[@]}" \
    "${API_URL_BASE}/?fn=listKv&args=%5B%22zz%22%5D")
echo "$resp" | grep -q '"entries":\[\]' || fail "prefix=zz should be empty: $resp"
ok "listKv prefix filter"

# ── 21. listKv cursor pagination over randwrite ───────────────────
RW_URL="https://randwrite.${PUBLIC_SUFFIX}:${PORT}"
for _ in 1 2 3 4 5; do
    "${CURL_BASE[@]}" -o /dev/null "${RW_URL}/?fn=handler"
done
SCOPE_RW=(-H "X-Rove-Scope: randwrite")
page1=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "${SCOPE_RW[@]}" \
    "${API_URL_BASE}/?fn=listKv&args=%5B%22%22%2C%22%22%2C2%5D")
# args: ["", "", 2]
count1=$(printf '%s' "$page1" | grep -oE '"key":' | wc -l | tr -d ' ')
[[ "$count1" == "2" ]] || fail "page1 should have 2 entries, got $count1: $page1"
printf '%s' "$page1" | grep -q '"next_cursor":' || fail "page1 missing next_cursor"
cursor=$(printf '%s' "$page1" | sed -E 's/.*"next_cursor":"([^"]*)".*/\1/')
cursor_encoded=$(printf '%s' "$cursor" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))')
args_page2="%5B%22%22%2C%22${cursor_encoded}%22%2C2%5D"
page2=$("${CURL_BASE[@]}" "${AUTH_HDR[@]}" "${SCOPE_RW[@]}" \
    "${API_URL_BASE}/?fn=listKv&args=${args_page2}")
count2=$(printf '%s' "$page2" | grep -oE '"key":' | wc -l | tr -d ' ')
[[ "$count2" == "2" ]] || fail "page2 should have 2 entries, got $count2: $page2"
printf '%s' "$page2" | grep -q "\"key\":\"$cursor\"" && fail "cursor echoed in page2"
ok "listKv cursor pagination advances past prior page's last key"

# ── 22. Unknown scope → 404 ───────────────────────────────────────
# The dispatcher rejects an X-Rove-Scope referencing an instance that
# doesn't exist in the root store.
code=$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' "${AUTH_HDR[@]}" \
    -H "X-Rove-Scope: ghost" \
    "${API_URL_BASE}/?fn=listKv")
[[ "$code" == "404" ]] || fail "unknown scope should 404 (got $code)"
ok "X-Rove-Scope: <unknown> → 404"

# Cases 23–27 (log count / list / show / pagination via /_system/log/*)
# moved out — Phase 5.5(a) deleted the raft log envelope. The replacement
# is the standalone log-server backed by S3 (see scripts/log_backend_s3_smoke.sh);
# wiring that into admin_smoke is its own task.

echo ""
echo "all admin smoke tests passed"
