#!/usr/bin/env bash
# End-to-end smoke test for the rate limiter (PLAN §2.10).
#
# Covers:
#   - Per-instance request bucket: hammer the tenant's URL until
#     the bucket is exhausted, verify the next request gets 429
#     with a Retry-After header. Capacity is dialed down via
#     --rate-limit-request-capacity for testability.
#   - Admin requests are not subject to per-instance rate limits
#     (admin token from the same machine should keep working even
#     after a tenant is throttled).
#   - email.send rate limit: deploy a handler that calls email.send,
#     hammer it past the email bucket capacity, verify the catchable
#     Error{code:"rate_limited"} surfaces in the handler response.
#   - Independence: a different tenant's bucket is unaffected by the
#     first tenant's exhaustion.

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-rate-limit-smoke}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8200}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40300}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff}"
ADMIN_HOST="app.loop46.localhost"
PUBLIC_SUFFIX="loop46.localhost"
PORT="${HTTP_ADDR##*:}"
ADMIN_ORIGIN="https://${ADMIN_HOST}:${PORT}"

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

# Tiny capacities + zero refill so a few requests exhaust the bucket
# and it stays exhausted for the duration of the test (no flakes from
# wall-clock-driven refills landing mid-sequence).
FILES_ADDR="${FILES_ADDR:-127.0.0.1:8223}"
LOG_ADDR="${LOG_ADDR:-127.0.0.1:8222}"
FILES_PORT="${FILES_ADDR##*:}"
LOG_PORT="${LOG_ADDR##*:}"
FILES_HOST="files.${PUBLIC_SUFFIX}"
LOG_HOST="logs.${PUBLIC_SUFFIX}"

# Phase 5.5(e) Task #62 — files-server runs as a separate process.
. "$(dirname "$0")/_smoke_helpers.sh"
export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"
spawn_files_server "$FILES_ADDR" "$DATA_DIR" /tmp/rate-limit-smoke-cs.out "$ADMIN_ORIGIN" || exit 1
spawn_log_server "$LOG_ADDR" "$DATA_DIR" /tmp/rate-limit-smoke-ls.out "$ADMIN_ORIGIN" || exit 1

"$BIN" worker \
    --node-id 0 \
    --peers "$RAFT_ADDR" \
    --listen "$RAFT_ADDR" \
    --http "$HTTP_ADDR" \
    --log-public-base "https://logs.${PUBLIC_SUFFIX}:${LOG_PORT}" \
    --files-public-base "https://files.${PUBLIC_SUFFIX}:${FILES_PORT}" \
    --data-dir "$DATA_DIR" \
    --bootstrap-root-token "$TOKEN" \
    --admin-origin "$ADMIN_ORIGIN" \
    --public-suffix "$PUBLIC_SUFFIX" \
    --tls-cert "$TLS_CERT" \
    --tls-key "$TLS_KEY" \
    --workers 1 \
    --rate-limit-request-capacity 5 \
    --rate-limit-request-refill 0 \
    --rate-limit-email-capacity 2 \
    --rate-limit-email-refill 0 \
    --fresh >/tmp/rate-limit-smoke.out 2>&1 &
PID=$!
trap 'kill $PID $CS_PID $LS_PID 2>/dev/null || true; wait $PID $CS_PID $LS_PID 2>/dev/null || true' EXIT

sleep 1.2

RESOLVE=(--resolve "${ADMIN_HOST}:${PORT}:127.0.0.1" \
         --resolve "rl1.${PUBLIC_SUFFIX}:${PORT}:127.0.0.1" \
         --resolve "rl2.${PUBLIC_SUFFIX}:${PORT}:127.0.0.1" \
         --resolve "${FILES_HOST}:${FILES_PORT}:127.0.0.1" \
         --resolve "${LOG_HOST}:${LOG_PORT}:127.0.0.1")
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")
AUTH=(-H "Authorization: Bearer $TOKEN")

ROVE_TOKEN="$TOKEN"
mint_services_token

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    echo "--- worker log (last 40 lines) ---" >&2
    tail -40 /tmp/rate-limit-smoke.out >&2
    exit 1
}

# Helper: PUT a single file into a tenant's deployment AND release the
# new dep_id to the worker (Phase 5.5(e) F2 retired the polling
# fallback, so the worker only reloads on a release POST).
put_file() {
    local instance="$1" path="$2" body="$3"
    local resp
    resp=$("${CURL[@]}" -w $'\n%{http_code}' \
        -X PUT -H "Authorization: Bearer $JWT" \
        -H "Content-Type: application/javascript" \
        --data-binary "$body" \
        "${FILES_BASE}/${instance}/file/${path}")
    local code="${resp##*$'\n'}"
    local dep_id="${resp%$'\n'*}"
    [[ "$code" == "201" ]] || fail "PUT ${instance}/${path}: got $code"
    release_deployment "$instance" "$dep_id" || fail "release ${instance}/${dep_id}"
}

# ── 1. Two tenants signed up + magic-link redeemed ────────────────────
# Lazy creation: signup writes pending/{name} only; the tenant
# directory + starter deploy happen at /v1/auth redeem time.
for name in rl1 rl2; do
    body=$("${CURL[@]}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${name}\",\"email\":\"${name}@example.com\"}" \
        "${ADMIN_ORIGIN}/v1/signup")
    echo "$body" | grep -q '"ok":true' || fail "signup ${name}: $body"
    mt=$(echo "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["magic_link"])' \
        | sed 's/.*mt=//')
    code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${ADMIN_ORIGIN}/v1/auth?mt=${mt}")
    [[ "$code" == "302" ]] || fail "redeem ${name}: got $code"
done
ok "POST /v1/signup + /v1/auth redeem rl1 + rl2"

# ── 2. Per-instance request bucket: capacity=5, then 429 ─────────────
# Hit rl1's URL 5 times — all 200 (starter content's index.html). The
# 6th must be 429 + Retry-After.
RL1="https://rl1.${PUBLIC_SUFFIX}:${PORT}"
for i in 1 2 3 4 5; do
    code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${RL1}/")
    [[ "$code" == "200" ]] || fail "request ${i}: expected 200, got $code"
done
ok "request 1-5 succeed (within capacity)"

# 6th request: bucket exhausted.
code=$("${CURL[@]}" -D /tmp/rate-limit-hdrs.txt -o /tmp/rate-limit-body.txt \
    -w '%{http_code}' "${RL1}/")
[[ "$code" == "429" ]] || fail "request 6: expected 429, got $code (body: $(cat /tmp/rate-limit-body.txt))"
ok "request 6 → 429 (bucket exhausted)"

grep -iq "^retry-after:" /tmp/rate-limit-hdrs.txt \
    || fail "missing Retry-After header: $(cat /tmp/rate-limit-hdrs.txt)"
ok "Retry-After header present on 429"

grep -q "rate limit exceeded" /tmp/rate-limit-body.txt \
    || fail "429 body missing 'rate limit exceeded': $(cat /tmp/rate-limit-body.txt)"
ok "429 body explains the limit"

# ── 3. Different tenant has its own bucket (independence) ────────────
# rl2 should still be at full capacity.
RL2="https://rl2.${PUBLIC_SUFFIX}:${PORT}"
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${RL2}/")
[[ "$code" == "200" ]] || fail "rl2 request: expected 200, got $code"
ok "rl2 not affected by rl1's exhaustion (per-instance buckets)"

# ── 4. Admin requests bypass the per-instance limit ──────────────────
# Admin (api.test) handler scopes to __admin__ and is exempt. Even
# after rl1's bucket is dry, admin requests must still work.
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    "${AUTH[@]}" "${ADMIN_ORIGIN}/v1/session")
[[ "$code" == "200" ]] || fail "admin /v1/session: expected 200, got $code"
ok "admin requests bypass the rate limit"

# ── 5. Email bucket: catchable Error{code:"rate_limited"} ────────────
# Deploy a handler on rl2 that calls email.send and reports the result
# (or caught error). Capacity 2 → first 2 calls go through (queue
# outbox row), 3rd throws.
EMAIL_HANDLER='export default function () {
  try {
    email.send({
      key: "re_test",
      from: "test@example.com",
      to: "user@example.com",
      subject: "hi",
      text: "test",
    });
    return { ok: true };
  } catch (e) {
    return { ok: false, code: e.code, message: e.message };
  }
}'
put_file "rl2" "email/index.mjs" "$EMAIL_HANDLER"
sleep 0.4

RL2_EMAIL="${RL2}/email"
# Two successes (capacity 2).
for i in 1 2; do
    body=$("${CURL[@]}" "${RL2_EMAIL}")
    echo "$body" | grep -q '"ok":true' \
        || fail "email call ${i}: expected ok, got $body"
done
ok "email.send 1-2 succeed (within email bucket capacity)"

# Third call: caught, code=rate_limited.
body=$("${CURL[@]}" "${RL2_EMAIL}")
echo "$body" | grep -q '"code":"rate_limited"' \
    || fail "email call 3: expected code=rate_limited, got $body"
echo "$body" | grep -q "email rate limit exceeded" \
    || fail "email call 3: missing message text, got $body"
ok "email.send 3 → catchable Error{code:'rate_limited'}"

echo ""
echo "all rate limit smoke checks passed"
