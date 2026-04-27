#!/usr/bin/env bash
# End-to-end smoke test for Phase 2a static file serving.
#
# Covers:
#   - PUT /_system/files/{id}/file/_static/<path> (single-file upload+deploy)
#   - GET /<path> on the tenant subdomain → 200 with ETag + Content-Type
#   - Static fallback chain: /foo → _static/foo.html → _static/foo/index.html
#   - Root path /    → _static/index.html
#   - If-None-Match → 304
#   - Trailing slash → 301
#   - Convention 404 via _static/_404.html
#   - Path validation (uppercase, `..`, missing prefix) → 400

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-static-smoke}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8199}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40299}"
ORIGIN="${ADMIN_ORIGIN:-http://localhost:5173}"
BIN="${BIN:-./zig-out/bin/js-worker}"
TOKEN="${ROVE_TOKEN:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
API_HOST="api.test"
PORT="${HTTP_ADDR##*:}"

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
    --fresh >/tmp/static-smoke.out 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true' EXIT

sleep 1.2

CUSTOMER_HOST="demo.test"
RESOLVE_FLAGS=(
    --resolve "${API_HOST}:${PORT}:127.0.0.1"
    --resolve "${CUSTOMER_HOST}:${PORT}:127.0.0.1"
)
CURL=(curl --http2-prior-knowledge -sS "${RESOLVE_FLAGS[@]}")
ADMIN_HDRS=(-H "Authorization: Bearer $TOKEN" -H "Origin: $ORIGIN")

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    echo "--- worker log ---" >&2
    tail -40 /tmp/static-smoke.out >&2
    exit 1
}

# ── setup: create a customer instance + assign its public hostname ────
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    "${ADMIN_HDRS[@]}" -H "Content-Type: application/json" \
    -d '{"fn":"createInstance","args":["demo"]}' \
    "http://${API_HOST}:${PORT}/")
[[ "$code" == "201" ]] || fail "createInstance demo (got $code)"
ok "createInstance demo"

code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    "${ADMIN_HDRS[@]}" -H "Content-Type: application/json" \
    -d "{\"fn\":\"assignDomain\",\"args\":[\"${CUSTOMER_HOST}\",\"demo\"]}" \
    "http://${API_HOST}:${PORT}/")
[[ "$code" == "201" ]] || fail "assignDomain ${CUSTOMER_HOST} → demo (got $code)"
ok "assignDomain ${CUSTOMER_HOST} → demo"

put_static() {
    local path="$1" ct="$2" body="$3"
    local code
    code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
        "${ADMIN_HDRS[@]}" -X PUT \
        -H "Content-Type: $ct" \
        --data-binary "$body" \
        "http://${API_HOST}:${PORT}/_system/files/demo/file/${path}")
    # Wait long enough for the worker's refresh poll (100ms + slack)
    # to pick up the new deployment before the next GET.
    sleep 0.25
    printf '%s\n' "$code"
}

# ── 1. PUT _static/index.html via admin api ──────────────────────────
code=$(put_static "_static/index.html" "text/html" '<!doctype html><h1>home</h1>')
[[ "$code" == "201" ]] || fail "PUT _static/index.html (got $code)"
ok "PUT _static/index.html → 201"

# ── 2. GET / → 200 + html + ETag + Cache-Control ──────────────────────
hdrs=$("${CURL[@]}" -D - -o /tmp/static-body.html "http://${CUSTOMER_HOST}:${PORT}/")
echo "$hdrs" | head -1 | grep -q " 200" || fail "GET / status ($hdrs)"
echo "$hdrs" | grep -iq "content-type: text/html" || fail "content-type missing"
etag=$(echo "$hdrs" | grep -i "^etag:" | awk '{print $2}' | tr -d '\r')
[[ -n "$etag" ]] || fail "etag missing"
echo "$hdrs" | grep -iq "cache-control: public" || fail "cache-control missing"
grep -q '<h1>home</h1>' /tmp/static-body.html || fail "body mismatch"
ok "GET / returns index.html with ETag + Cache-Control"

# ── 3. If-None-Match matching ETag → 304 ─────────────────────────────
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    -H "If-None-Match: $etag" "http://${CUSTOMER_HOST}:${PORT}/")
[[ "$code" == "304" ]] || fail "If-None-Match match → 304 (got $code)"
ok "If-None-Match match → 304"

# ── 4. If-None-Match not matching → 200 ──────────────────────────────
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    -H 'If-None-Match: "different"' "http://${CUSTOMER_HOST}:${PORT}/")
[[ "$code" == "200" ]] || fail "If-None-Match mismatch → 200 (got $code)"
ok "If-None-Match mismatch → 200"

# ── 5. .html fallback: GET /about → _static/about.html ───────────────
code=$(put_static "_static/about.html" "text/html" '<p>about</p>')
[[ "$code" == "201" ]] || fail "PUT about.html (got $code)"
body=$("${CURL[@]}" "http://${CUSTOMER_HOST}:${PORT}/about")
grep -q '<p>about</p>' <<<"$body" || fail ".html fallback body: $body"
ok ".html fallback: /about → _static/about.html"

# ── 6. directory index fallback: GET /blog → _static/blog/index.html ─
code=$(put_static "_static/blog/index.html" "text/html" '<p>blog</p>')
[[ "$code" == "201" ]] || fail "PUT blog/index.html"
body=$("${CURL[@]}" "http://${CUSTOMER_HOST}:${PORT}/blog")
grep -q '<p>blog</p>' <<<"$body" || fail "dir index body: $body"
ok "dir-index fallback: /blog → _static/blog/index.html"

# ── 7. trailing slash canonicalization: /blog/ → 301 /blog ──────────
hdrs=$("${CURL[@]}" -D - -o /dev/null "http://${CUSTOMER_HOST}:${PORT}/blog/")
echo "$hdrs" | head -1 | grep -q " 301" || fail "trailing slash 301 ($hdrs)"
echo "$hdrs" | grep -iq "location: /blog" || fail "redirect location"
ok "trailing slash → 301 /blog"

# ── 8. convention 404: missing URL with _static/_404.html ─────────────
code=$(put_static "_static/_404.html" "text/html" '<h1>nope</h1>')
[[ "$code" == "201" ]] || fail "PUT _404.html"
resp=$("${CURL[@]}" -D /tmp/static-404-hdrs.txt -o /tmp/static-404-body.html \
    -w '%{http_code}' "http://${CUSTOMER_HOST}:${PORT}/nonexistent")
[[ "$resp" == "404" ]] || fail "convention 404 status (got $resp)"
grep -q '<h1>nope</h1>' /tmp/static-404-body.html || fail "404 body"
grep -iq "content-type: text/html" /tmp/static-404-hdrs.txt || fail "404 content-type"
ok "convention 404 served from _static/_404.html"

# ── 9. PUT at bad prefix → 400 ────────────────────────────────────────
code=$(put_static "evil/foo.html" "text/html" 'x')
[[ "$code" == "400" ]] || fail "bad prefix (got $code)"
ok "PUT outside _static and not .mjs/.js → 400"

# ── 10. PUT with traversal → 400 ──────────────────────────────────────
code=$(put_static "_static/../escape" "text/html" 'x')
[[ "$code" == "400" ]] || fail "traversal (got $code)"
ok "PUT with '..' → 400"

# ── 11. PUT with uppercase → 400 ──────────────────────────────────────
code=$(put_static "_static/Index.html" "text/html" 'x')
[[ "$code" == "400" ]] || fail "uppercase (got $code)"
ok "PUT with uppercase → 400"

# ── 12. ETag survives a re-upload of identical bytes ─────────────────
code=$(put_static "_static/index.html" "text/html" '<!doctype html><h1>home</h1>')
[[ "$code" == "201" ]] || fail "re-upload identical (got $code)"
hdrs=$("${CURL[@]}" -D - -o /dev/null "http://${CUSTOMER_HOST}:${PORT}/")
new_etag=$(echo "$hdrs" | grep -i "^etag:" | awk '{print $2}' | tr -d '\r')
[[ "$new_etag" == "$etag" ]] || fail "etag changed on identical re-upload ($etag vs $new_etag)"
ok "identical re-upload keeps the same ETag"

echo ""
echo "all static smoke tests passed"
