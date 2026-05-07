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

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-static-smoke}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8202}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40302}"
ORIGIN="${ADMIN_ORIGIN_OVERRIDE:-https://localhost:5173}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
API_HOST="app.loop46.localhost"
PUBLIC_SUFFIX="loop46.localhost"

# TLS via mkcert (Phase 8 + step 2 of the launch checklist). Expects
# scripts/rove-dev-setup.sh OR `loop46 dev` to have been run
# once on this machine to generate the cert + register the CA.
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

FILES_ADDR="${FILES_ADDR:-127.0.0.1:8221}"
LOG_ADDR="${LOG_ADDR:-127.0.0.1:8220}"
FILES_PORT="${FILES_ADDR##*:}"
LOG_PORT="${LOG_ADDR##*:}"
FILES_HOST="files.loop46.localhost"
LOG_HOST="logs.loop46.localhost"

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=static-smoke
SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"

CUSTOMER_HOST="demo.loop46.localhost"

PIDS=()
for i in 0 1 2; do
    "$BIN" worker \
        --node-id "$i" \
        --peers "$PEERS_CSV" \
        --listen "${RAFT_ADDRS[$i]}" \
        --http "${HTTP_ADDRS[$i]}" \
        --log-public-base "https://${LOG_HOST}:${LOG_PORT}" \
        --files-public-base "https://${FILES_HOST}:${FILES_PORT}" \
        --data-dir "${DATA_DIRS[$i]}" \
        --bootstrap-root-token "$TOKEN" \
        --admin-origin "$ORIGIN" \
        --admin-api-domain "$API_HOST" \
        --public-suffix "$PUBLIC_SUFFIX" \
        --tls-cert "$TLS_CERT" \
        --tls-key "$TLS_KEY" \
        --workers 2 \
        >"/tmp/${SMOKE_TAG}-worker-${i}.out" 2>&1 &
    PIDS+=($!)
done
trap '
    for p in "${PIDS[@]}" "${CS_PID:-}" "${LS_PID:-}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done
    for p in "${PIDS[@]}" "${CS_PID:-}" "${LS_PID:-}"; do
        [ -n "$p" ] && wait "$p" 2>/dev/null || true
    done
' EXIT
sleep 2

RESOLVE_FLAGS=(
    --resolve "${FILES_HOST}:${FILES_PORT}:127.0.0.1"
    --resolve "${LOG_HOST}:${LOG_PORT}:127.0.0.1"
)
for h in "${HTTP_ADDRS[@]}"; do
    p="${h##*:}"
    RESOLVE_FLAGS+=(--resolve "${API_HOST}:${p}:127.0.0.1")
    RESOLVE_FLAGS+=(--resolve "${CUSTOMER_HOST}:${p}:127.0.0.1")
done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE_FLAGS[@]}")
ADMIN_HDRS=(-H "Authorization: Bearer $TOKEN" -H "Origin: $ORIGIN")

discover_leader "$API_HOST" "$TOKEN" || exit 1
echo "ok  leader elected: node $LEADER_IDX at $LEADER_HTTP"

PORT="$LEADER_PORT"
ADMIN_ORIGIN="https://${API_HOST}:${PORT}"

spawn_files_server "$FILES_ADDR" "${DATA_DIRS[$LEADER_IDX]}" /tmp/static-smoke-cs.out "$ORIGIN" || exit 1
spawn_log_server   "$LOG_ADDR"   "${DATA_DIRS[$LEADER_IDX]}" /tmp/static-smoke-ls.out "$ORIGIN" || exit 1

ROVE_TOKEN="$TOKEN"
mint_services_token

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    for i in 0 1 2; do
        echo "--- worker $i log ---" >&2
        tail -30 "/tmp/${SMOKE_TAG}-worker-${i}.out" >&2
    done
    exit 1
}

# ── setup: create a customer instance + assign its public hostname ────
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    "${ADMIN_HDRS[@]}" -H "Content-Type: application/json" \
    -d '{"fn":"createInstance","args":["demo"]}' \
    "https://${API_HOST}:${PORT}/")
[[ "$code" == "201" ]] || fail "createInstance demo (got $code)"
ok "createInstance demo"

code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    "${ADMIN_HDRS[@]}" -H "Content-Type: application/json" \
    -d "{\"fn\":\"assignDomain\",\"args\":[\"${CUSTOMER_HOST}\",\"demo\"]}" \
    "https://${API_HOST}:${PORT}/")
[[ "$code" == "201" ]] || fail "assignDomain ${CUSTOMER_HOST} → demo (got $code)"
ok "assignDomain ${CUSTOMER_HOST} → demo"

put_static() {
    local path="$1" ct="$2" body="$3"
    local resp
    resp=$("${CURL[@]}" -w $'\n%{http_code}' \
        -H "Authorization: Bearer $JWT" -X PUT \
        -H "Content-Type: $ct" \
        --data-binary "$body" \
        "${FILES_BASE}/demo/file/${path}")
    local code="${resp##*$'\n'}"
    local dep_id="${resp%$'\n'*}"
    if [[ "$code" == "201" ]]; then
        # Push the release so the worker reloads before the next GET.
        # Phase 5.5(e) F2 retired the polling fallback.
        release_deployment "demo" "$dep_id" >/dev/null 2>&1 || true
    fi
    printf '%s\n' "$code"
}

# ── 1. PUT _static/index.html via admin api ──────────────────────────
code=$(put_static "_static/index.html" "text/html" '<!doctype html><h1>home</h1>')
[[ "$code" == "201" ]] || fail "PUT _static/index.html (got $code)"
ok "PUT _static/index.html → 201"

# ── 2. GET / → 200 + html + ETag + Cache-Control ──────────────────────
hdrs=$("${CURL[@]}" -D - -o /tmp/static-body.html "https://${CUSTOMER_HOST}:${PORT}/")
echo "$hdrs" | head -1 | grep -q " 200" || fail "GET / status ($hdrs)"
echo "$hdrs" | grep -iq "content-type: text/html" || fail "content-type missing"
etag=$(echo "$hdrs" | grep -i "^etag:" | awk '{print $2}' | tr -d '\r')
[[ -n "$etag" ]] || fail "etag missing"
echo "$hdrs" | grep -iq "cache-control: public" || fail "cache-control missing"
grep -q '<h1>home</h1>' /tmp/static-body.html || fail "body mismatch"
ok "GET / returns index.html with ETag + Cache-Control"

# ── 2b. HEAD / → 200 + identical headers, no body (RFC 9110 §9.3.2) ──
head_resp=$("${CURL[@]}" -D - -o /tmp/static-head-body.html -X HEAD "https://${CUSTOMER_HOST}:${PORT}/")
echo "$head_resp" | head -1 | grep -q " 200" || fail "HEAD / status ($head_resp)"
echo "$head_resp" | grep -iq "content-type: text/html" || fail "HEAD / content-type missing"
echo "$head_resp" | grep -iq "^etag:" || fail "HEAD / etag missing"
echo "$head_resp" | grep -iq "cache-control: public" || fail "HEAD / cache-control missing"
[[ ! -s /tmp/static-head-body.html ]] || fail "HEAD / returned a body ($(wc -c < /tmp/static-head-body.html) bytes)"
ok "HEAD / matches GET headers but omits body"

# ── 3. If-None-Match matching ETag → 304 ─────────────────────────────
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    -H "If-None-Match: $etag" "https://${CUSTOMER_HOST}:${PORT}/")
[[ "$code" == "304" ]] || fail "If-None-Match match → 304 (got $code)"
ok "If-None-Match match → 304"

# ── 4. If-None-Match not matching → 200 ──────────────────────────────
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    -H 'If-None-Match: "different"' "https://${CUSTOMER_HOST}:${PORT}/")
[[ "$code" == "200" ]] || fail "If-None-Match mismatch → 200 (got $code)"
ok "If-None-Match mismatch → 200"

# ── 5. .html fallback: GET /about → _static/about.html ───────────────
code=$(put_static "_static/about.html" "text/html" '<p>about</p>')
[[ "$code" == "201" ]] || fail "PUT about.html (got $code)"
body=$("${CURL[@]}" "https://${CUSTOMER_HOST}:${PORT}/about")
grep -q '<p>about</p>' <<<"$body" || fail ".html fallback body: $body"
ok ".html fallback: /about → _static/about.html"

# ── 6. directory index fallback: GET /blog → _static/blog/index.html ─
code=$(put_static "_static/blog/index.html" "text/html" '<p>blog</p>')
[[ "$code" == "201" ]] || fail "PUT blog/index.html"
body=$("${CURL[@]}" "https://${CUSTOMER_HOST}:${PORT}/blog")
grep -q '<p>blog</p>' <<<"$body" || fail "dir index body: $body"
ok "dir-index fallback: /blog → _static/blog/index.html"

# ── 7. trailing slash canonicalization: /blog/ → 301 /blog ──────────
hdrs=$("${CURL[@]}" -D - -o /dev/null "https://${CUSTOMER_HOST}:${PORT}/blog/")
echo "$hdrs" | head -1 | grep -q " 301" || fail "trailing slash 301 ($hdrs)"
echo "$hdrs" | grep -iq "location: /blog" || fail "redirect location"
ok "trailing slash → 301 /blog"

# ── 8. convention 404: missing URL with _static/_404.html ─────────────
code=$(put_static "_static/_404.html" "text/html" '<h1>nope</h1>')
[[ "$code" == "201" ]] || fail "PUT _404.html"
resp=$("${CURL[@]}" -D /tmp/static-404-hdrs.txt -o /tmp/static-404-body.html \
    -w '%{http_code}' "https://${CUSTOMER_HOST}:${PORT}/nonexistent")
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
hdrs=$("${CURL[@]}" -D - -o /dev/null "https://${CUSTOMER_HOST}:${PORT}/")
new_etag=$(echo "$hdrs" | grep -i "^etag:" | awk '{print $2}' | tr -d '\r')
[[ "$new_etag" == "$etag" ]] || fail "etag changed on identical re-upload ($etag vs $new_etag)"
ok "identical re-upload keeps the same ETag"

echo ""
echo "all static smoke tests passed"
