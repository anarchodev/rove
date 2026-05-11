#!/usr/bin/env bash
# Leader-failover smoke — production.md §7.
#
# Validates the at-least-once + version-counter dedup contract from
# http-send-plan.md §7 across a forced leadership change:
#
#   1. Stand up a 3-node loop46 cluster with the acme + wb demo
#      tenants.
#   2. Schedule a delayed `http.send` from acme → wb, fire_at_ns
#      set to "now + DELAY_MS". The schedule row commits through
#      raft to all 3 nodes' schedules.db.
#   3. After the schedule is committed but BEFORE the fire window
#      opens, kill the leader.
#   4. The remaining 2 voters elect a new leader. The new leader's
#      schedule-server thread scans schedules.db, finds the due
#      row, fires the http.send (in-process worker phase since wb
#      is in the cluster).
#   5. wb echoes back; the schedule-complete envelope-9 lands in
#      the target tenant's `_callback/{id}`; `dispatchCallbacks`
#      invokes acme's `httpresult.mjs`; acme writes
#      `http/result/{id}` with the captured event.
#   6. Smoke reads the kv row from acme via the admin API and
#      verifies it exists. Existence = "schedule survived leader
#      death + on_result fired against the new leader."
#
# What this covers from production.md #7:
#   ✓ Leader change with http.send rows in flight (the schedule_id
#     was committed but the libcurl fire happens on the NEW leader).
#   ✓ New leader picking up schedules.db rows the old leader hadn't
#     yet fired.
#
# What's deferred:
#   - sse-server `rove:resync` after worker restart (sse-server
#     smoke does that separately).
#   - Version-counter dedup under concurrent overwrite (would need
#     to race http.send with an overwriting http.send across the
#     failover — niche enough that the unit-level apply-path
#     dedup test plus the at-least-once contract here is enough).

set -euo pipefail

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-leader-failover}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8470}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40470}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc}"
ADMIN_HOST="app.loop46.localhost"
ACME_HOST="acme.loop46.localhost"
WB_HOST="wb.loop46.localhost"
PUBLIC_SUFFIX="loop46.localhost"
DELAY_MS="${DELAY_MS:-4000}"   # schedule fire delay
KILL_AFTER_S="${KILL_AFTER_S:-1}"  # how long after the http.send call to kill the leader
WAIT_FOR_RESULT_S="${WAIT_FOR_RESULT_S:-15}"

if [[ "$(uname -s)" == "Darwin" ]]; then
    LOOP46_DATA="${LOOP46_DATA:-$HOME/Library/Application Support/loop46}"
else
    LOOP46_DATA="${LOOP46_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/loop46}"
fi
TLS_CERT="$LOOP46_DATA/dev-cert.pem"
TLS_KEY="$LOOP46_DATA/dev-key.pem"
CACERT="$LOOP46_DATA/ca-root.pem"

[[ -f "$TLS_CERT" && -f "$TLS_KEY" ]] || { echo "missing dev TLS at $LOOP46_DATA" >&2; exit 2; }
[[ -x "$BIN" ]] || { echo "$BIN missing — run zig build install" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 needed" >&2; exit 2; }

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=leader-failover
SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

# Fresh S3 prefix per run so the seed step doesn't reuse stale
# manifests + we get a clean ApplyCtx history.
export S3_KEY_PREFIX_BASE="${S3_KEY_PREFIX_BASE:-smoke-leader-failover-$(date +%s)/}"
export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"
export LOOP46_ROOT_TOKEN="$TOKEN"

# Seed acme (with httpfire + httpresult) + wb (the echo target).
seed_all_dirs ./examples/loop46-demo-tenants.json

PIDS=()
for i in 0 1 2; do
    p="${HTTP_ADDRS[$i]##*:}"
    "$BIN" worker \
        --node-id "$i" \
        --peers "$PEERS_CSV" \
        --listen "${RAFT_ADDRS[$i]}" \
        --http "${HTTP_ADDRS[$i]}" \
        --data-dir "${DATA_DIRS[$i]}" \
        --admin-origin "https://${ADMIN_HOST}:${p}" \
        --admin-api-domain "$ADMIN_HOST" \
        --public-suffix "$PUBLIC_SUFFIX" \
        --tls-cert "$TLS_CERT" \
        --tls-key "$TLS_KEY" \
        --workers 1 \
        --dev-webhook-unsafe \
        "${RAFT_TIMING_FLAGS[@]}" \
        >"/tmp/${SMOKE_TAG}-worker-${i}.out" 2>&1 &
    PIDS+=($!)
done
trap '
    for p in "${PIDS[@]:-}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done
    pkill -x loop46 2>/dev/null || true
    wait 2>/dev/null || true
' EXIT

sleep 2

RESOLVE=()
for h in "${HTTP_ADDRS[@]}"; do
    p="${h##*:}"
    RESOLVE+=(--resolve "${ADMIN_HOST}:${p}:127.0.0.1")
    RESOLVE+=(--resolve "${ACME_HOST}:${p}:127.0.0.1")
    RESOLVE+=(--resolve "${WB_HOST}:${p}:127.0.0.1")
done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}" --max-time 10)

discover_leader "$ADMIN_HOST" "$TOKEN" || exit 1
ORIG_LEADER_IDX="$LEADER_IDX"
ORIG_LEADER_PORT="${LEADER_HTTP##*:}"
echo "ok  initial leader: node $ORIG_LEADER_IDX at $LEADER_HTTP"

# Fire the delayed http.send via acme/httpfire?fn=fireDelayed.
WB_URL="https://${WB_HOST}:${ORIG_LEADER_PORT}/"
ARGS_JSON=$(python3 -c "import json,sys; print(json.dumps([sys.argv[1], 'failover', int(sys.argv[2])]))" "$WB_URL" "$DELAY_MS")
ARGS_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$ARGS_JSON")

ACME_ORIGIN="https://${ACME_HOST}:${ORIG_LEADER_PORT}"
FIRE_BODY=$("${CURL[@]}" "${ACME_ORIGIN}/httpfire?fn=fireDelayed&args=${ARGS_ENC}")
echo "fire response: $FIRE_BODY"
SCHED_ID=$(python3 -c "import json,sys; print(json.loads(sys.stdin.read())['id'])" <<< "$FIRE_BODY")
[[ -n "$SCHED_ID" ]] || { echo "FAIL: empty schedule id from fireDelayed: $FIRE_BODY" >&2; exit 1; }
echo "ok  scheduled delayed http.send (id=$SCHED_ID, delay=${DELAY_MS}ms)"

# Confirm the row landed in EVERY node's schedules.db before the
# leader dies. Without this, the kill is racy and the test would
# sometimes pass on the old leader's pre-failover fire.
echo "verifying schedule row replicated to all 3 nodes…"
for i in 0 1 2; do
    db="${DATA_DIRS[$i]}/schedules.db"
    for _ in $(seq 1 30); do
        # The schedules.db key shape is `s/{tenant_id}/{id}`. The
        # smoke fired from acme so the tenant_id is "acme".
        cnt=$(sqlite3 "$db" "SELECT COUNT(*) FROM kv WHERE key='s/acme/${SCHED_ID}';" 2>/dev/null || echo 0)
        if [[ "$cnt" != "0" ]]; then
            break
        fi
        sleep 0.2
    done
    [[ "$cnt" != "0" ]] || {
        echo "FAIL: schedule row never reached node $i's schedules.db within 6s" >&2
        exit 1
    }
done
echo "ok  schedule row replicated to all 3 schedules.db files"

# Kill the leader. The remaining 2 voters should elect a new leader
# within ~election-timeout-ms (default 200ms).
sleep "$KILL_AFTER_S"
echo "killing original leader node $ORIG_LEADER_IDX (pid=${PIDS[$ORIG_LEADER_IDX]})…"
kill -TERM "${PIDS[$ORIG_LEADER_IDX]}" 2>/dev/null || true
wait "${PIDS[$ORIG_LEADER_IDX]}" 2>/dev/null || true
PIDS[$ORIG_LEADER_IDX]=""

# Wait for a NEW leader to be elected (one of the surviving nodes).
NEW_LEADER_IDX=""
NEW_LEADER_PORT=""
for tries in $(seq 1 40); do
    for i in 0 1 2; do
        [[ "$i" == "$ORIG_LEADER_IDX" ]] && continue
        p="${HTTP_ADDRS[$i]##*:}"
        code=$("${CURL[@]}" --max-time 2 -o /dev/null -w '%{http_code}' \
            -H "Authorization: Bearer $TOKEN" \
            "https://${ADMIN_HOST}:${p}/_system/leader" 2>/dev/null || echo 000)
        if [[ "$code" == "200" ]]; then
            NEW_LEADER_IDX=$i
            NEW_LEADER_PORT=$p
            break 2
        fi
    done
    sleep 0.5
done
[[ -n "$NEW_LEADER_IDX" ]] || {
    echo "FAIL: no new leader elected within 20s" >&2
    exit 1
}
echo "ok  new leader: node $NEW_LEADER_IDX (port $NEW_LEADER_PORT) elected after failover"

# Wait for the schedule to fire + on_result to land. acme writes
# `http/result/{id}` from `httpresult.mjs`. Poll the admin
# kv-read endpoint until it appears, up to WAIT_FOR_RESULT_S.
echo "waiting for on_result kv write (up to ${WAIT_FOR_RESULT_S}s)…"
RESULT=""
RESULT_KEY="http/result/${SCHED_ID}"
NEW_LEADER_DATA="${DATA_DIRS[$NEW_LEADER_IDX]}"
ACME_DB="${NEW_LEADER_DATA}/acme/app.db"
for tries in $(seq 1 $((WAIT_FOR_RESULT_S * 2))); do
    # Read acme's kv directly via sqlite3 on the new leader's
    # app.db. The smoke setup doesn't bootstrap __admin__ (that
    # would require spawning files-server-standalone), so the
    # admin-host getKv path returns 503 here. Direct DB read
    # works because the apply path writes every committed row
    # into each follower's app.db synchronously — by the time
    # we see it on the new leader, it's durable.
    if [[ -f "$ACME_DB" ]]; then
        VAL=$(sqlite3 "$ACME_DB" "SELECT value FROM kv WHERE key='${RESULT_KEY}';" 2>/dev/null || echo "")
        if [[ -n "$VAL" ]] && echo "$VAL" | grep -qE '"ok":(true|false)'; then
            RESULT="$VAL"
            break
        fi
    fi
    sleep 0.5
done
[[ -n "$RESULT" ]] || {
    echo "FAIL: on_result kv write never appeared within ${WAIT_FOR_RESULT_S}s after failover" >&2
    echo "Last admin response: $RESULT_BODY" >&2
    echo "--- new leader log tail ---" >&2
    tail -30 "/tmp/${SMOKE_TAG}-worker-${NEW_LEADER_IDX}.out" >&2
    exit 1
}
echo "ok  on_result kv write landed on acme via new leader"
echo "    result: $RESULT"

# Final sanity: the fire's `ok` field should be true. The getKv
# response IS the raw value httpresult.mjs serialized, so parse
# directly.
OK_FIELD=$(echo "$RESULT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('ok',False))" 2>/dev/null || echo "False")
[[ "$OK_FIELD" == "True" ]] || {
    echo "FAIL: result.ok != true (got $OK_FIELD)" >&2
    exit 1
}
echo "ok  result.ok == true — http.send completed successfully across failover"

echo ""
echo "PASS leader-failover smoke"
