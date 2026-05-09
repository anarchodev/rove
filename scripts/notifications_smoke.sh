#!/usr/bin/env bash
# notifications_smoke.sh — end-to-end cluster smoke for the
# centralized notifications channel (docs/notifications.md +
# docs/sse-plan.md).
#
# Boots a 3-node loop46 cluster + files-server + log-server +
# sse-server-standalone, then exercises the full path the
# documentation promises:
#
#   1. /_session/sse-token returns
#      {token, expires_in, notifications_url, tenant_id}
#   2. EventSource opens at notifications_url with the minted token
#      → 200 + text/event-stream
#   3. Customer handler runs `events.emit({to: request.session.id,
#      type, data})`. Worker fires POST to sse-server after raft
#      commits; sse-server pushes the frame to the connected
#      EventSource.
#   4. Cross-tenant isolation: tenant B emits targeting tenant A's
#      sid value; the wire frame must NOT appear on tenant A's
#      stream (sse-server keys connection table per-tenant).
#   5. Token mismatch: tenant A's token used at /v1/<tenantB>/sse
#      → 403 from sse-server's tenant-claim check.
#
# Differs from `scripts/sse_smoke.sh`, which exercises the legacy
# `/_events` worker route + per-tenant pump path (still in-tree for
# the migration's parallel-run posture). When the legacy path
# retires (sse-plan §7 step 7), that smoke goes too.
#
# sse-server runs h2c (no TLS) for the smoke. The worker's libcurl
# emit POST goes plaintext to loopback — easier than wiring CA-bundle
# trust into the libcurl Easy handle for dev certs. Production
# operators run sse-server with TLS via `--tls-cert` / `--tls-key`.

set -euo pipefail

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-notifications-smoke}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8260}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40360}"
BIN="${BIN:-./zig-out/bin/loop46}"
SSE_BIN="${SSE_BIN:-./zig-out/bin/sse-server-standalone}"
TOKEN="${ROVE_TOKEN:-ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff}"
ADMIN_HOST="app.loop46.localhost"
PUBLIC_SUFFIX="loop46.localhost"
TENANT_A="notifsmokea"
TENANT_B="notifsmokeb"
SSE_PORT="${SSE_PORT:-8268}"
SSE_HOST="sse.${PUBLIC_SUFFIX}"
FILES_ADDR="${FILES_ADDR:-127.0.0.1:8267}"
LOG_ADDR="${LOG_ADDR:-127.0.0.1:8266}"
FILES_PORT="${FILES_ADDR##*:}"
LOG_PORT="${LOG_ADDR##*:}"
FILES_HOST="files.${PUBLIC_SUFFIX}"
LOG_HOST="logs.${PUBLIC_SUFFIX}"

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
for b in "$BIN" "$SSE_BIN" "${BIN%/loop46}/files-server-standalone" "${BIN%/loop46}/log-server-standalone"; do
    if [[ ! -x "$b" ]]; then
        echo "error: $b missing — run 'zig build install' first" >&2
        exit 2
    fi
done

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=notifications-smoke
SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"
export LOOP46_ROOT_TOKEN="$TOKEN"
SSE_INTERNAL_TOKEN_VAL="$(head -c 24 /dev/urandom | xxd -p | tr -d '\n')"
export SSE_INTERNAL_TOKEN="$SSE_INTERNAL_TOKEN_VAL"

PIDS=()
SSE_PID=""
trap '
    for p in "${PIDS[@]}" "${CS_PID:-}" "${LS_PID:-}" "${SSE_PID:-}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done
    for p in "${PIDS[@]}" "${CS_PID:-}" "${LS_PID:-}" "${SSE_PID:-}"; do
        [ -n "$p" ] && wait "$p" 2>/dev/null || true
    done
' EXIT

# ── sse-server first (so workers' first emit POST has something to
# hit when raft starts committing). h2c on a fixed loopback port.
"$SSE_BIN" --listen "127.0.0.1:${SSE_PORT}" \
    >/tmp/${SMOKE_TAG}-sse.out 2>&1 &
SSE_PID=$!
sse_ready=0
for _ in $(seq 1 30); do
    if curl -sf --http2-prior-knowledge "http://127.0.0.1:${SSE_PORT}/v1/health" >/dev/null 2>&1; then
        sse_ready=1; break
    fi
    sleep 0.1
done
[[ "$sse_ready" -eq 1 ]] \
    || { echo "sse-server didn't answer /v1/health"; cat /tmp/${SMOKE_TAG}-sse.out >&2; exit 1; }

SSE_PUBLIC_BASE="http://${SSE_HOST}:${SSE_PORT}"

# ── 3-node loop46 cluster pointing at sse-server.
for i in 0 1 2; do
    "$BIN" worker \
        --node-id "$i" \
        --peers "$PEERS_CSV" \
        --listen "${RAFT_ADDRS[$i]}" \
        --http "${HTTP_ADDRS[$i]}" \
        --log-public-base "https://${LOG_HOST}:${LOG_PORT}" \
        --files-public-base "https://${FILES_HOST}:${FILES_PORT}" \
        --sse-public-base "$SSE_PUBLIC_BASE" \
        --data-dir "${DATA_DIRS[$i]}" \
        --public-suffix "$PUBLIC_SUFFIX" \
        --tls-cert "$TLS_CERT" \
        --tls-key "$TLS_KEY" \
        --workers 1 \
        "${RAFT_TIMING_FLAGS[@]}" \
        >"/tmp/${SMOKE_TAG}-worker-${i}.out" 2>&1 &
    PIDS+=($!)
done
sleep 2

RESOLVE=(--resolve "${FILES_HOST}:${FILES_PORT}:127.0.0.1" \
         --resolve "${LOG_HOST}:${LOG_PORT}:127.0.0.1")
for h in "${HTTP_ADDRS[@]}"; do
    p="${h##*:}"
    RESOLVE+=(--resolve "${ADMIN_HOST}:${p}:127.0.0.1" \
              --resolve "${TENANT_A}.${PUBLIC_SUFFIX}:${p}:127.0.0.1" \
              --resolve "${TENANT_B}.${PUBLIC_SUFFIX}:${p}:127.0.0.1")
done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")
# sse-server speaks h2c on loopback — no --cacert needed and no
# resolve trick (we hit 127.0.0.1 directly).
SSE_CURL=(curl -sS --http2-prior-knowledge)

discover_leader "$ADMIN_HOST" "$TOKEN" || exit 1
echo "ok  leader elected: node $LEADER_IDX at $LEADER_HTTP"
PORT="$LEADER_PORT"
ADMIN_ORIGIN="https://${ADMIN_HOST}:${PORT}"
TENANT_A_ORIGIN="https://${TENANT_A}.${PUBLIC_SUFFIX}:${PORT}"
TENANT_B_ORIGIN="https://${TENANT_B}.${PUBLIC_SUFFIX}:${PORT}"

spawn_files_server "$FILES_ADDR" "${DATA_DIRS[$LEADER_IDX]}" \
    /tmp/${SMOKE_TAG}-cs.out "$ADMIN_ORIGIN" "$ADMIN_ORIGIN" || exit 1
spawn_log_server "$LOG_ADDR" "${DATA_DIRS[$LEADER_IDX]}" \
    /tmp/${SMOKE_TAG}-ls.out "$ADMIN_ORIGIN" || exit 1

ROVE_TOKEN="$TOKEN"
mint_services_token

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    for i in 0 1 2; do
        echo "--- worker $i log ---" >&2
        tail -40 "/tmp/${SMOKE_TAG}-worker-${i}.out" >&2
    done
    echo "--- sse-server log ---" >&2
    tail -40 /tmp/${SMOKE_TAG}-sse.out >&2
    exit 1
}

signup() {
    local name="$1"
    local body
    body=$("${CURL[@]}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${name}\",\"email\":\"${name}@example.com\"}" \
        "${ADMIN_ORIGIN}/v1/signup")
    echo "$body" | grep -q '"ok":true' || fail "signup ${name} not ok: $body"
    local mt
    mt=$(echo "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["magic_link"])' \
        | sed 's/.*mt=//')
    local code
    code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${ADMIN_ORIGIN}/v1/auth?mt=${mt}")
    [[ "$code" == "302" ]] || fail "redeem ${name}: got $code"
}

put_file_to() {
    local tenant="$1"
    local path="$2"
    local body="$3"
    local resp
    resp=$("${CURL[@]}" -w $'\n%{http_code}' \
        -X PUT \
        -H "Authorization: Bearer $JWT" \
        -H "Content-Type: application/javascript" \
        --data-binary "$body" \
        "${FILES_BASE}/${tenant}/file/${path}")
    local code="${resp##*$'\n'}"
    local dep_id="${resp%$'\n'*}"
    [[ "$code" == "201" ]] || fail "PUT ${tenant}/${path}: got $code"
    release_deployment "$tenant" "$dep_id" || fail "release ${tenant}/${dep_id}"
}

# ── 1. Two tenants ────────────────────────────────────────────────
signup "$TENANT_A"
signup "$TENANT_B"
ok "signed up two tenants ($TENANT_A, $TENANT_B)"

# ── 2. Customer handler with events.emit ──────────────────────────
HANDLER_SRC='export default function () {
  if (request.path === "/emit") {
    events.emit({type: "order.paid", data: {n: 1}});
    events.emit({type: "order.paid", data: {n: 2}});
    return { sid: request.session ? request.session.id : null };
  }
  if (request.path === "/spoof") {
    const target = (request.query || "").split("=")[1];
    events.emit({to: target, type: "order.paid", data: "should_not_arrive"});
    return { spoofed: target };
  }
  return { hello: request.session ? request.session.id : null };
}'
put_file_to "$TENANT_A" "index.mjs" "$HANDLER_SRC"
put_file_to "$TENANT_B" "index.mjs" "$HANDLER_SRC"
sleep 0.4
ok "deployed events.emit handler to both tenants"

# ── 3. /_session/sse-token shape ──────────────────────────────────
COOKIE_JAR=/tmp/${SMOKE_TAG}-cookies.txt
rm -f "$COOKIE_JAR"
TOKEN_RESP=$("${CURL[@]}" -c "$COOKIE_JAR" \
    "${TENANT_A_ORIGIN}/_session/sse-token")
TOKEN_A=$(echo "$TOKEN_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
NOTIF_URL=$(echo "$TOKEN_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["notifications_url"])')
TENANT_FROM_RESP=$(echo "$TOKEN_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tenant_id"])')
EXPIRES_IN=$(echo "$TOKEN_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["expires_in"])')

[[ -n "$TOKEN_A" && "$TOKEN_A" != "None" ]] || fail "token missing in /_session/sse-token response: $TOKEN_RESP"
[[ "$EXPIRES_IN" == "3600" ]] || fail "expires_in not 3600: '$EXPIRES_IN'"
[[ "$TENANT_FROM_RESP" == "$TENANT_A" ]] || fail "tenant_id mismatch: '$TENANT_FROM_RESP' vs '$TENANT_A'"
[[ "$NOTIF_URL" == "${SSE_PUBLIC_BASE}/v1/${TENANT_A}/sse" ]] \
    || fail "notifications_url unexpected: '$NOTIF_URL'"
ok "/_session/sse-token returns {token, expires_in:3600, notifications_url, tenant_id}"

# Capture the sid the worker minted on the same response so cross-
# tenant tests below can use it as a target.
SID_A=$(grep -E '__Host-rove_sid' "$COOKIE_JAR" | awk '{print $7}' | head -1)
[[ -n "$SID_A" && ${#SID_A} -eq 64 ]] || fail "no __Host-rove_sid set on /_session/sse-token (got '${SID_A}')"
ok "/_session/sse-token minted __Host-rove_sid=${SID_A:0:12}…"

# ── 4. EventSource open + emit + frame round-trip ─────────────────
SSE_LOG=/tmp/${SMOKE_TAG}-stream.out
rm -f "$SSE_LOG"
# notifications_url is http://sse.<suffix>:<port>/v1/<tenant>/sse —
# the host portion needs --resolve since SSE_HOST isn't a real DNS
# entry. We hit 127.0.0.1 directly (sse-server is loopback-only) but
# pass Host: header so it routes correctly.
"${SSE_CURL[@]}" --no-buffer --max-time 5 \
    --resolve "${SSE_HOST}:${SSE_PORT}:127.0.0.1" \
    "${NOTIF_URL}?token=${TOKEN_A}" >"$SSE_LOG" 2>/dev/null &
STREAM_PID=$!
sleep 0.5  # let the EventSource register on sse-server

"${CURL[@]}" -b "$COOKIE_JAR" "${TENANT_A_ORIGIN}/emit" >/dev/null
sleep 1.0  # raft commit + worker emit POST + sse-server push + h2 flush
wait $STREAM_PID 2>/dev/null || true

grep -q '^data: {"n":1}$' "$SSE_LOG" \
    || fail "missing first emit on EventSource (data: {n:1}); log:$(echo; cat "$SSE_LOG")"
grep -q '^data: {"n":2}$' "$SSE_LOG" \
    || fail "missing second emit on EventSource (data: {n:2}); log:$(echo; cat "$SSE_LOG")"
grep -q '^event: order.paid$' "$SSE_LOG" \
    || fail "missing event: order.paid line; log:$(echo; cat "$SSE_LOG")"
grep -qE '^id: [0-9]{20}-[0-9]{6}$' "$SSE_LOG" \
    || fail "missing id: line in {request_id:020d}-{call_index:06d} format"
ok "events.emit → worker POST → sse-server push → EventSource frame"

# ── 5. Cross-tenant isolation ─────────────────────────────────────
SSE_LOG_X=/tmp/${SMOKE_TAG}-cross.out
rm -f "$SSE_LOG_X"
"${SSE_CURL[@]}" --no-buffer --max-time 3 \
    --resolve "${SSE_HOST}:${SSE_PORT}:127.0.0.1" \
    "${NOTIF_URL}?token=${TOKEN_A}" >"$SSE_LOG_X" 2>/dev/null &
STREAM_X_PID=$!
sleep 0.5

# Tenant B emits with target=sid_a. Cross-tenant — sse-server keys
# the connection table per-tenant, so the spoof should land in
# tenant B's (empty) connection table and never reach tenant A's
# stream.
"${CURL[@]}" "${TENANT_B_ORIGIN}/spoof?to=${SID_A}" >/dev/null
sleep 1.0
wait $STREAM_X_PID 2>/dev/null || true

if grep -q 'should_not_arrive' "$SSE_LOG_X"; then
    fail "cross-tenant emit leaked into tenant A's notifications stream"
fi
ok "cross-tenant emit isolated (tenant B's emit invisible on tenant A's stream)"

# ── 6. Token / URL tenant mismatch → 403 ──────────────────────────
#
# Tenant A's token claims tenant_id=tenantA. Used at
# /v1/<tenantB>/sse it must 403 because sse-server checks the
# token's claim against the URL path tenant.
NOTIF_URL_B=$(echo "$NOTIF_URL" | sed "s|/${TENANT_A}/|/${TENANT_B}/|")
CODE=$("${SSE_CURL[@]}" -o /dev/null -w '%{http_code}' --max-time 1 \
    --resolve "${SSE_HOST}:${SSE_PORT}:127.0.0.1" \
    "${NOTIF_URL_B}?token=${TOKEN_A}")
[[ "$CODE" == "403" ]] || fail "tenant mismatch should be 403, got $CODE"
ok "tenant A's token rejected at /v1/${TENANT_B}/sse → 403"

echo
echo "all notifications smoke checks passed"
