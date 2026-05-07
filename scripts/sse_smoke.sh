#!/usr/bin/env bash
# End-to-end smoke test for SSE (PLAN §2.12, docs/sse-plan.md).
#
# Covers the full path through cookie mint → emit → pump → wire:
#   - GET /_events on a fresh browser mints `__Host-rove_sid` and
#     keeps the long-lived stream open with text/event-stream
#     headers
#   - A handler call that runs `events.emit("hello")` writes a row
#     into the tenant's app.db and the pump pushes it to the
#     connected EventSource client within one tick
#   - The wire frame carries the right `id:`, `event:` and `data:`
#     lines per the SSE spec
#   - Multiple emits in one request stream out in order with
#     monotonic ids
#   - Cross-tenant isolation: a second tenant emitting to the SAME
#     sid value produces NO frame on tenant A's stream (the row
#     lands in tenant B's app.db where tenant A's pump never reads)
#   - Session cookie is host-bound: a request to tenant B does not
#     carry tenant A's `__Host-rove_sid` cookie

set -euo pipefail

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-sse-smoke}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8214}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40314}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff}"
ADMIN_HOST="app.loop46.localhost"
PUBLIC_SUFFIX="loop46.localhost"
TENANT_A="ssesmoke"
TENANT_B="ssesmokeb"

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

FILES_ADDR="${FILES_ADDR:-127.0.0.1:8227}"
LOG_ADDR="${LOG_ADDR:-127.0.0.1:8226}"
FILES_PORT="${FILES_ADDR##*:}"
LOG_PORT="${LOG_ADDR##*:}"
FILES_HOST="files.${PUBLIC_SUFFIX}"
LOG_HOST="logs.${PUBLIC_SUFFIX}"

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=sse-smoke
SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

# --workers 1: SSE pump state lives per worker process. With
# --workers 2 + SO_REUSEPORT, the /_events long-poll connection
# can land on worker A while /emit lands on worker B; B writes the
# event to app.db but A's pump tick races the read (or the kernel
# doesn't wake it before max-time). Surfaces as flaky "missing
# first emit" failures. Real fix is shared pump state across
# workers (or pin an SSE-affinity scheme); see docs/sse-plan.md.
export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"

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
        --public-suffix "$PUBLIC_SUFFIX" \
        --tls-cert "$TLS_CERT" \
        --tls-key "$TLS_KEY" \
        --workers 1 \
        "${RAFT_TIMING_FLAGS[@]}" \
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

RESOLVE=(--resolve "${FILES_HOST}:${FILES_PORT}:127.0.0.1" \
         --resolve "${LOG_HOST}:${LOG_PORT}:127.0.0.1")
for h in "${HTTP_ADDRS[@]}"; do
    p="${h##*:}"
    RESOLVE+=(--resolve "${ADMIN_HOST}:${p}:127.0.0.1" \
              --resolve "${TENANT_A}.${PUBLIC_SUFFIX}:${p}:127.0.0.1" \
              --resolve "${TENANT_B}.${PUBLIC_SUFFIX}:${p}:127.0.0.1")
done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")
AUTH=(-H "Authorization: Bearer $TOKEN")

discover_leader "$ADMIN_HOST" "$TOKEN" || exit 1
echo "ok  leader elected: node $LEADER_IDX at $LEADER_HTTP"
PORT="$LEADER_PORT"
ADMIN_ORIGIN="https://${ADMIN_HOST}:${PORT}"
TENANT_A_ORIGIN="https://${TENANT_A}.${PUBLIC_SUFFIX}:${PORT}"
TENANT_B_ORIGIN="https://${TENANT_B}.${PUBLIC_SUFFIX}:${PORT}"

spawn_files_server "$FILES_ADDR" "${DATA_DIRS[$LEADER_IDX]}" /tmp/sse-smoke-cs.out "$ADMIN_ORIGIN" "$ADMIN_ORIGIN" || exit 1
spawn_log_server   "$LOG_ADDR"   "${DATA_DIRS[$LEADER_IDX]}" /tmp/sse-smoke-ls.out "$ADMIN_ORIGIN" || exit 1

ROVE_TOKEN="$TOKEN"
mint_services_token

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    for i in 0 1 2; do
        echo "--- worker $i log ---" >&2
        tail -40 "/tmp/${SMOKE_TAG}-worker-${i}.out" >&2
    done
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

# ── 2. Deploy a handler that emits ────────────────────────────────
HANDLER_SRC='export default function () {
  if (request.path === "/emit") {
    const id = events.emit({type: "ping", data: {n: 1}});
    events.emit({type: "ping", data: {n: 2}});
    events.emit({type: "ping", data: {n: 3}});
    return { sid: request.session ? request.session.id : null, ids: [id] };
  }
  if (request.path === "/spoof") {
    // Try to emit to a sid argument (used for cross-tenant test).
    const target = (request.query || "").split("=")[1];
    events.emit({to: target, type: "spoof", data: "should_not_arrive"});
    return { spoofed: target };
  }
  return { hello: request.session ? request.session.id : null };
}'
put_file_to "$TENANT_A" "index.mjs" "$HANDLER_SRC"
put_file_to "$TENANT_B" "index.mjs" "$HANDLER_SRC"
sleep 0.4
ok "deployed emit handler to both tenants"

# ── 3. Open SSE on tenant A and capture the cookie + a few frames ─
#
# Strategy: run curl in the background with --no-buffer streaming
# /_events output to a file. Wait briefly for headers + cookie, then
# fire the /emit endpoint. The pump should push all three events
# within one tick (~1ms). Read the file after a short delay and
# look for the wire frames.
SSE_LOG=/tmp/sse-smoke-stream.out
COOKIE_JAR=/tmp/sse-smoke-cookies.txt
rm -f "$SSE_LOG" "$COOKIE_JAR"

# First, fetch the cookie via a HEAD on /_events with a brief timeout.
# We only need the Set-Cookie value; the long-poll itself will be
# done in a separate streamed call.
"${CURL[@]}" -I --max-time 1.5 -c "$COOKIE_JAR" "${TENANT_A_ORIGIN}/_events" >/tmp/sse-head.out 2>&1 || true
SID_A=$(grep -E '__Host-rove_sid=[a-f0-9]+' /tmp/sse-head.out | head -1 | sed -E 's/.*__Host-rove_sid=([a-f0-9]+).*/\1/')
[[ -n "$SID_A" && ${#SID_A} -eq 64 ]] || fail "no __Host-rove_sid set on /_events response (got '${SID_A}')"
ok "GET /_events minted __Host-rove_sid=${SID_A:0:12}…"

# Confirm headers carry the right SSE content-type + cache-control.
grep -qi '^content-type: text/event-stream' /tmp/sse-head.out \
    || fail "missing content-type: text/event-stream on /_events"
grep -qi '^cache-control: no-store' /tmp/sse-head.out \
    || fail "missing cache-control: no-store on /_events"
ok "/_events carries content-type + cache-control headers"

# ── 4. Open the long-poll, fire /emit, look for frames ────────────
"${CURL[@]}" --no-buffer -b "$COOKIE_JAR" --max-time 4 \
    "${TENANT_A_ORIGIN}/_events" >"$SSE_LOG" 2>/dev/null &
SSE_PID=$!
sleep 0.3   # let the connection settle into stream_data_out

"${CURL[@]}" -b "$COOKIE_JAR" "${TENANT_A_ORIGIN}/emit" >/dev/null
sleep 0.5   # one pump tick + h2 flush

# Wait for the curl to either time out (max-time) or end naturally,
# but don't block the smoke for the full 4 seconds.
wait $SSE_PID 2>/dev/null || true

# The stream should contain 3 frames in order. Check for the data
# lines.
grep -q '^data: {"n":1}$' "$SSE_LOG" || fail "missing first emit (data: {n:1})"
grep -q '^data: {"n":2}$' "$SSE_LOG" || fail "missing second emit (data: {n:2})"
grep -q '^data: {"n":3}$' "$SSE_LOG" || fail "missing third emit (data: {n:3})"
ok "pump delivered 3 emits to connected EventSource"

# Frames carry the right id: prefix (zero-padded request_id-call_index).
grep -qE '^id: [0-9]{20}-[0-9]{6}$' "$SSE_LOG" \
    || fail "missing id: line in zero-padded format"
ok "wire frames carry id: {request_id:020d}-{call_index:06d}"

# event: type echoes through.
grep -q '^event: ping$' "$SSE_LOG" || fail "missing event: ping line"
ok "wire frames carry event: <type>"

# Three distinct call_index values (000000, 000001, 000002) present.
n_distinct_ids=$(grep -E '^id: [0-9]{20}-00000[0-9]$' "$SSE_LOG" | sort -u | wc -l)
[[ "$n_distinct_ids" -eq 3 ]] || fail "expected 3 distinct ids, got $n_distinct_ids"
ok "three monotonic ids delivered (call_index 000000-000002)"

# ── 5. Cross-tenant isolation ─────────────────────────────────────
#
# Open a fresh SSE stream on tenant A and have tenant B emit to
# tenant A's sid value. Tenant B's emit lands in tenant B's
# _events/{sid_a}/... rows where tenant A's pump never reads, so the
# frame must NOT appear on tenant A's stream.
SSE_LOG_X=/tmp/sse-smoke-stream-cross.out
rm -f "$SSE_LOG_X"
"${CURL[@]}" --no-buffer -b "$COOKIE_JAR" --max-time 3 \
    "${TENANT_A_ORIGIN}/_events" >"$SSE_LOG_X" 2>/dev/null &
SSE_PID_X=$!
sleep 0.3

# Hit tenant B's /spoof?to=<sid_a>. This emits {to: sid_a, ...} on
# tenant B. The cross-host call carries no cookie (browser would
# refuse __Host- cookie cross-host, and our raw curl sends nothing).
"${CURL[@]}" "${TENANT_B_ORIGIN}/spoof?to=${SID_A}" >/dev/null
sleep 0.5

wait $SSE_PID_X 2>/dev/null || true

# The spoof must NOT have arrived on tenant A's stream.
if grep -q 'should_not_arrive' "$SSE_LOG_X"; then
    fail "cross-tenant emit leaked into tenant A's stream"
fi
ok "cross-tenant emit did NOT leak to tenant A's SSE stream"

# ── 6. Reconnect catch-up: events emitted while disconnected ─────
#
# Models the closed-browser-then-reopen case. With the cookie alive
# (Max-Age=1y), the new EventSource connect should see historical
# events emitted while no client was attached. Without the
# pending_catchup gate in events_pump, those events sit in kv until
# retention expiry — the dirty-mark optimization drops them because
# nobody was listening at emit time.
#
# Emit 3 more events from /emit while NO stream is open. Then open
# /_events with the same cookie file (sid stays the same) and
# confirm the historical events arrive within one pump tick.
#
# We need fresh wire ids each time, so this implicitly relies on
# request_id incrementing across requests.

# Note: the previous /emit calls used request_ids 2 and 3; this one
# will use a higher one. The pump reads all rows past last_event_id
# so it picks up everything.
"${CURL[@]}" -b "$COOKIE_JAR" "${TENANT_A_ORIGIN}/emit" >/dev/null
sleep 0.1
"${CURL[@]}" -b "$COOKIE_JAR" "${TENANT_A_ORIGIN}/emit" >/dev/null
sleep 0.5  # let pump + kv writes settle, no listener attached

# Now reopen the SSE stream. With pending_catchup=true on the new
# SseConnection and the events still in retention, the first pump
# tick should deliver everything past the previous last_event_id.
SSE_LOG_R=/tmp/sse-smoke-stream-reconnect.out
rm -f "$SSE_LOG_R"
"${CURL[@]}" --no-buffer -b "$COOKIE_JAR" --max-time 4 \
    "${TENANT_A_ORIGIN}/_events" >"$SSE_LOG_R" 2>/dev/null &
SSE_PID_R=$!
sleep 1.0  # one pump tick (~1ms) but allow generous wall-clock for h2 flush
wait $SSE_PID_R 2>/dev/null || true

# Should have delivered the 6 emits (2 calls * 3 emits each) that
# happened while no listener was connected.
n_pings=$(grep -c '^event: ping$' "$SSE_LOG_R")
[[ "$n_pings" -ge 6 ]] || fail "reconnect catch-up missed events: got $n_pings ping frames, expected ≥6"
ok "reconnect with stale events: catch-up delivered $n_pings frames"

# Cookie scoping: a request to tenant B with no cookie file should
# get a fresh, different sid in Set-Cookie. (We can't force the
# browser-level __Host- send-cross-host refusal here, but we can
# confirm the worker treats cookie-absent requests independently.)
"${CURL[@]}" -I --max-time 1.5 "${TENANT_B_ORIGIN}/_events" >/tmp/sse-head-b.out 2>&1 || true
SID_B=$(grep -E '__Host-rove_sid=[a-f0-9]+' /tmp/sse-head-b.out | head -1 | sed -E 's/.*__Host-rove_sid=([a-f0-9]+).*/\1/')
[[ -n "$SID_B" && ${#SID_B} -eq 64 ]] || fail "no __Host-rove_sid on tenant B /_events"
[[ "$SID_A" != "$SID_B" ]] || fail "tenant A and tenant B got the same sid (mint should be independent)"
ok "tenant B mints a different sid than tenant A"

echo
echo "all SSE smoke checks passed"
