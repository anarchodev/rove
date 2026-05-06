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
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd}"
ADMIN_HOST="app.loop46.localhost"
PUBLIC_SUFFIX="loop46.localhost"
PORT="${HTTP_ADDR##*:}"
ADMIN_ORIGIN="https://${ADMIN_HOST}:${PORT}"
ALICE_ORIGIN="https://alice.${PUBLIC_SUFFIX}:${PORT}"

# TLS via mkcert (run `loop46 dev` once to bootstrap if missing).
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

FILES_ADDR="${FILES_ADDR:-127.0.0.1:8219}"
LOG_ADDR="${LOG_ADDR:-127.0.0.1:8218}"
FILES_PORT="${FILES_ADDR##*:}"
LOG_PORT="${LOG_ADDR##*:}"
FILES_HOST="files.${PUBLIC_SUFFIX}"
LOG_HOST="logs.${PUBLIC_SUFFIX}"

"$BIN" worker \
    --node-id 0 \
    --peers "$RAFT_ADDR" \
    --listen "$RAFT_ADDR" \
    --http "$HTTP_ADDR" \
    --log-listen "$LOG_ADDR" \
    --files-listen "$FILES_ADDR" \
    --data-dir "$DATA_DIR" \
    --bootstrap-root-token "$TOKEN" \
    --admin-origin "$ADMIN_ORIGIN" \
    --public-suffix "$PUBLIC_SUFFIX" \
    --tls-cert "$TLS_CERT" \
    --tls-key "$TLS_KEY" \
    --workers 1 \
    --refresh-interval-ms 100 \
    --fresh >/tmp/signup-smoke.out 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true' EXIT

sleep 1.2

RESOLVE=(--resolve "${ADMIN_HOST}:${PORT}:127.0.0.1" \
         --resolve "alice.${PUBLIC_SUFFIX}:${PORT}:127.0.0.1" \
         --resolve "bob.${PUBLIC_SUFFIX}:${PORT}:127.0.0.1" \
         --resolve "${FILES_HOST}:${FILES_PORT}:127.0.0.1" \
         --resolve "${LOG_HOST}:${LOG_PORT}:127.0.0.1")
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")

ROVE_TOKEN="$TOKEN"
. "$(dirname "$0")/_smoke_helpers.sh"
mint_services_token

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

# ── 4a. Per-account instance limit (pending state) ─────────────────────
# alice@example.com still has the pending(alice) reservation from
# section 1 — a second signup with the SAME email but a DIFFERENT name
# must hit the limit (free tier, max_instances=1).
code=$("${CURL[@]}" -o /tmp/ss-limit-pending.json -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"alice2","email":"alice@example.com"}' \
    "${ADMIN_ORIGIN}/v1/signup")
[[ "$code" == "403" ]] || fail "limit (pending) got $code: $(cat /tmp/ss-limit-pending.json)"
grep -q '"error":"account_limit_reached"' /tmp/ss-limit-pending.json \
    || fail "limit (pending) body: $(cat /tmp/ss-limit-pending.json)"
ok "second signup for same email (pending state) → 403 account_limit_reached"

# A different email is unaffected — proves the limit is per-account, not global.
code=$("${CURL[@]}" -o /tmp/ss-other-email.json -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"carol","email":"carol@example.com"}' \
    "${ADMIN_ORIGIN}/v1/signup")
[[ "$code" == "202" ]] || fail "different email got $code: $(cat /tmp/ss-other-email.json)"
ok "different email accepted (limit is per-account, not global)"

# ── 5. Redeem the magic link → 302 + Set-Cookie + Location ───────────
hdrs=$("${CURL[@]}" -D - -o /dev/null -w '%{http_code}' "${ADMIN_ORIGIN}/v1/auth?mt=${MT}")
status=$(echo "$hdrs" | tail -n1)
[[ "$status" == "302" ]] || fail "redeem got $status"
echo "$hdrs" | grep -iq '^location: /#/alice' || fail "redeem missing Location: /#/alice"
echo "$hdrs" | grep -iq '^set-cookie: rove_session=' || fail "redeem missing session cookie"
echo "$hdrs" | grep -iq 'httponly' || fail "redeem cookie missing HttpOnly"
# Full admin CORS envelope: origin + credentials + vary + expose-headers.
# Same shape every other admin response uses, so caches behave consistently.
echo "$hdrs" | grep -iq "^access-control-allow-origin: ${ADMIN_ORIGIN}" \
    || fail "redeem missing CORS allow-origin"
echo "$hdrs" | grep -iq '^access-control-allow-credentials: true' \
    || fail "redeem missing CORS allow-credentials"
echo "$hdrs" | grep -iq '^vary: origin' || fail "redeem missing Vary: origin"
echo "$hdrs" | grep -iq '^access-control-expose-headers: content-type' \
    || fail "redeem missing CORS expose-headers"
# Extract the cookie for the subsequent whoami check. (`__Host-rove_sid`
# is the SSE pre-mint that arrives on every response — pick out the
# auth `rove_session` specifically.)
cookie=$(echo "$hdrs" | grep -iE '^set-cookie:.*rove_session' \
    | sed 's/^[^:]*: //' | awk -F'; ' '{print $1}' | tr -d '\r')
ok "GET /v1/auth?mt=... → 302 + session cookie + Location:/#/alice + full CORS envelope"

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

# ── 9a. Per-account instance limit (owned state) ──────────────────────
# alice@example.com now owns the alice tenant; pending is empty. A
# new signup with the same email must still hit the limit — the cap
# applies to (owned + pending), and owned is now 1.
code=$("${CURL[@]}" -o /tmp/ss-limit-owned.json -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"alicepost","email":"alice@example.com"}' \
    "${ADMIN_ORIGIN}/v1/signup")
[[ "$code" == "403" ]] || fail "limit (owned) got $code: $(cat /tmp/ss-limit-owned.json)"
grep -q '"error":"account_limit_reached"' /tmp/ss-limit-owned.json \
    || fail "limit (owned) body: $(cat /tmp/ss-limit-owned.json)"
ok "second signup for same email (owned state) → 403 account_limit_reached"

# ── 9a. Starter content answers on the new instance ───────────────────
# `/` should resolve via the wildcard public suffix to alice's static
# index.html (starter bundle). Hit `/api?fn=default` to exercise the
# handler too. Give refreshDeployments a tick to see the new deploy.
sleep 0.3
code=$("${CURL[@]}" -o /tmp/ss-alice-html.txt -w '%{http_code}' "${ALICE_ORIGIN}/")
[[ "$code" == "200" ]] || fail "starter static /: got $code (body: $(cat /tmp/ss-alice-html.txt))"
grep -q 'Your Loop46 app is live' /tmp/ss-alice-html.txt || fail "starter HTML body missing expected text"
ok "starter content: GET ${ALICE_ORIGIN}/ → 200 with expected HTML"

# The handler lives at index.mjs; hit a non-static path so static
# resolution misses and routes to the handler. No `?fn=` needed —
# missing fn invokes the default export with no args.
code=$("${CURL[@]}" -o /tmp/ss-alice-api.txt -w '%{http_code}' "${ALICE_ORIGIN}/api")
[[ "$code" == "200" ]] || fail "starter handler /api: got $code (body: $(cat /tmp/ss-alice-api.txt))"
grep -q 'Your Loop46 API is live' /tmp/ss-alice-api.txt || fail "starter handler body missing expected text"
ok "starter content: GET ${ALICE_ORIGIN}/api → 200 with expected JSON (default export, no fn=)"

# ── 9b. Throwing handler → 500 with the exception in the body ─────────
# Customer day-one footgun: until this fix, any uncaught throw came back
# as a 200 with an empty body. Now the worker translates it to a 500
# with `handler threw: <message>` so the customer sees what blew up.
THROW_SRC='export default function () { throw new Error("boom from smoke"); }'
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    -X PUT \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/javascript" \
    --data-binary "$THROW_SRC" \
    "${FILES_BASE}/alice/file/throw/index.mjs")
[[ "$code" == "201" ]] || fail "deploy throw.mjs: got $code"
sleep 0.3
code=$("${CURL[@]}" -o /tmp/ss-alice-throw.txt -w '%{http_code}' "${ALICE_ORIGIN}/throw")
[[ "$code" == "500" ]] || fail "throw handler: expected 500, got $code (body: $(cat /tmp/ss-alice-throw.txt))"
grep -q 'handler threw' /tmp/ss-alice-throw.txt || fail "throw body missing 'handler threw' prefix: $(cat /tmp/ss-alice-throw.txt)"
grep -q 'boom from smoke' /tmp/ss-alice-throw.txt || fail "throw body missing exception message: $(cat /tmp/ss-alice-throw.txt)"
ok "throwing handler → 500 with exception message in body"

# ── 9c. request.headers + request.cookies reach the handler ───────────
# Customer-facing primitive: handler reads incoming HTTP headers
# (lowercase keys, pseudo-headers filtered) and pre-parsed cookies.
# Webhook signature verification, custom auth, content-type branching
# all hang off this.
ECHO_SRC='export default function () {
  return JSON.stringify({
    ua: request.headers["user-agent"] ?? null,
    sig: request.headers["x-test-sig"] ?? null,
    sess: request.cookies["sid"] ?? null,
    extra: request.cookies["extra"] ?? null,
    method_pseudo: request.headers[":method"] ?? null,
  });
}'
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    -X PUT \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/javascript" \
    --data-binary "$ECHO_SRC" \
    "${FILES_BASE}/alice/file/echo/index.mjs")
[[ "$code" == "201" ]] || fail "deploy echo/index.mjs: got $code"
sleep 0.3
ECHO_BODY=$("${CURL[@]}" \
    -H "User-Agent: smoke/1" \
    -H "X-Test-Sig: v0=abc" \
    -H "Cookie: sid=alice123; extra=x; bare" \
    "${ALICE_ORIGIN}/echo")
echo "$ECHO_BODY" | grep -q '"ua":"smoke/1"' || fail "request.headers user-agent missing: $ECHO_BODY"
echo "$ECHO_BODY" | grep -q '"sig":"v0=abc"' || fail "request.headers custom header missing: $ECHO_BODY"
echo "$ECHO_BODY" | grep -q '"sess":"alice123"' || fail "request.cookies sid missing: $ECHO_BODY"
echo "$ECHO_BODY" | grep -q '"extra":"x"' || fail "request.cookies multi-value missing: $ECHO_BODY"
echo "$ECHO_BODY" | grep -q '"method_pseudo":null' || fail "pseudo-header :method should be filtered: $ECHO_BODY"
ok "request.headers + request.cookies expose wire data to handler"

# ── 10. With ROVE_RESEND_KEY configured: signup queues an outbox email
#        and drops magic_link from the response body. ───────────────────
#
# Stop the current worker and relaunch with --bootstrap-resend-key. The
# data dir is reused so alice's instance stays visible, and we add a
# fresh "bob" signup to exercise the email-queuing path.
RESEND_KEY="re_smoke_${RANDOM}_${RANDOM}"
kill $PID 2>/dev/null || true
wait $PID 2>/dev/null || true

"$BIN" worker \
    --node-id 0 \
    --peers "$RAFT_ADDR" \
    --listen "$RAFT_ADDR" \
    --http "$HTTP_ADDR" \
    --data-dir "$DATA_DIR" \
    --bootstrap-root-token "$TOKEN" \
    --bootstrap-kv "resend_key=$RESEND_KEY" \
    --bootstrap-kv "platform_email_from=noreply@smoke.test" \
    --admin-origin "$ADMIN_ORIGIN" \
    --public-suffix "$PUBLIC_SUFFIX" \
    --tls-cert "$TLS_CERT" \
    --tls-key "$TLS_KEY" \
    --workers 1 \
    --refresh-interval-ms 100 \
    >>/tmp/signup-smoke.out 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true' EXIT
sleep 1.2

body=$("${CURL[@]}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"bob","email":"bob@example.com"}' \
    "${ADMIN_ORIGIN}/v1/signup")
echo "$body" | grep -q '"ok":true' || fail "resend-path signup not ok: $body"
echo "$body" | grep -q '"name":"bob"' || fail "resend-path signup missing name: $body"
if echo "$body" | grep -q '"magic_link"'; then
    fail "resend-path signup leaked magic_link in response: $body"
fi
ok "signup with Resend key → 202, magic_link suppressed"

# Inspect __admin__'s outbox via the admin listKv RPC. Lazy-creation
# (Phase 4 amendment) keeps bob from existing as a tenant until magic
# redeem completes — the signup email outbox row therefore lands in
# admin's app.db, not in a (nonexistent) bob/. The drainer scans
# every tenant's _outbox/* on tick, so it picks this one up the
# same way it picks up customer-fired email.send rows.
qs=$(python3 -c "
import json, urllib.parse
print(urllib.parse.quote(json.dumps(['_outbox/','',10])))
")
outbox=$("${CURL[@]}" \
    -H "Authorization: Bearer $TOKEN" \
    "${ADMIN_ORIGIN}/?fn=listKv&args=${qs}")
# The envelope body is JSON-encoded inside the envelope's "body"
# string, which in turn is JSON-encoded inside the listKv response,
# so the dynamic fields appear with one layer of JSON escaping. We
# grep for substrings (avoiding quote characters) rather than reach
# through two levels of JSON.parse.
echo "$outbox" | grep -q '"key":"_outbox/' || fail "no _outbox row in __admin__'s kv: $outbox"
echo "$outbox" | grep -q 'api.resend.com/emails' || fail "outbox envelope missing Resend URL"
echo "$outbox" | grep -q 'bob@example.com' || fail "outbox envelope missing recipient"
echo "$outbox" | grep -q 'noreply@smoke.test' || fail "outbox envelope missing from address"
echo "$outbox" | grep -q 'Finish signing up' || fail "outbox envelope missing subject"
echo "$outbox" | grep -q "$RESEND_KEY" || fail "outbox envelope missing Resend auth key"
ok "outbox row carries Resend URL + from/to/subject + auth header"

echo ""
echo "all signup smoke checks passed"
