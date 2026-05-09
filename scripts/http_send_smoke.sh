#!/usr/bin/env bash
# End-to-end smoke for the http.send → in-process worker phase →
# schedule_complete → on_result handler pipeline.
#
# Covers (http-send-plan §3.2 + slice 5c):
#   - acme handler calls `http.send` targeting wb.{public_suffix}
#   - dispatcher accumulates a ScheduleRow + multi-envelope (writeset
#     + envelope-8 schedule_upsert) commits atomically through raft
#   - apply-time `is_internal=true` stamping (acme + wb both registered
#     under loop46.localhost; the URL parses as in-cluster)
#   - the worker phase (`dispatchInternalSchedules`) finds wb in
#     `tenant_files_map` and dispatches in-process via
#     `dispatcher.run` against wb's index.mjs
#   - wb's response (status + body) AND wb's kv writes ride a multi-
#     envelope: target writeset (env-0) + caller schedule_complete
#     (env-9), atomic with the schedules.db delete + acme's
#     `_callback/{id}` write
#   - dispatchCallbacks invokes acme's `httpresult.mjs` with the
#     camelCase event (id, ok, status, version, body, context)
#   - on_result kv writes are durable + visible via the admin API
#
# Requirements:
#   - zig-out/bin/loop46 + files-server-standalone (run `zig build install` first)
#   - python3 for JSON munging
#
# `--dev-webhook-unsafe` is set so the libcurl scheduler thread
# (which would fire if internal dispatch failed) accepts http://
# loopback. Should never trigger in this smoke — wb is hosted on
# every node, so the worker phase always wins.

set -euo pipefail

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-http-send-smoke}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8275}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40375}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc}"
ADMIN_HOST="app.loop46.localhost"
ACME_HOST="acme.loop46.localhost"
WB_HOST="wb.loop46.localhost"
PUBLIC_SUFFIX="loop46.localhost"

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
if ! command -v python3 >/dev/null; then
    echo "error: python3 needed" >&2
    exit 2
fi

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=http-send-smoke
SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"
export LOOP46_ROOT_TOKEN="$TOKEN"

# Seed acme (httpfire/ + httpresult.mjs handlers) AND wb (target).
seed_all_dirs ./examples/loop46-demo-tenants.json

# Start cluster.
PIDS=()
for i in 0 1 2; do
    P="${HTTP_ADDRS[$i]##*:}"
    "$BIN" worker \
        --node-id "$i" \
        --peers "$PEERS_CSV" \
        --listen "${RAFT_ADDRS[$i]}" \
        --http "${HTTP_ADDRS[$i]}" \
        --data-dir "${DATA_DIRS[$i]}" \
        --admin-origin "https://${ADMIN_HOST}:${P}" \
        --admin-api-domain "$ADMIN_HOST" \
        --public-suffix "$PUBLIC_SUFFIX" \
        --tls-cert "$TLS_CERT" \
        --tls-key "$TLS_KEY" \
        --workers 2 \
        "${RAFT_TIMING_FLAGS[@]}" \
        --dev-webhook-unsafe \
        >"/tmp/${SMOKE_TAG}-worker-${i}.out" 2>&1 &
    PIDS+=($!)
done

VERIFY_PY=""
cleanup() {
    for p in "${PIDS[@]}" "${CS_PID:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
    for p in "${PIDS[@]}" "${CS_PID:-}"; do [ -n "$p" ] && wait "$p" 2>/dev/null || true; done
    [ -n "$VERIFY_PY" ] && rm -f "$VERIFY_PY"
}
trap cleanup EXIT
sleep 2

RESOLVE=()
for h in "${HTTP_ADDRS[@]}"; do
    p="${h##*:}"
    RESOLVE+=(--resolve "${ADMIN_HOST}:${p}:127.0.0.1" \
              --resolve "${ACME_HOST}:${p}:127.0.0.1" \
              --resolve "${WB_HOST}:${p}:127.0.0.1")
done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")

discover_leader "$ADMIN_HOST" "$TOKEN" || exit 1
echo "ok  leader elected: node $LEADER_IDX at $LEADER_HTTP"
PORT="$LEADER_PORT"
ADMIN_ORIGIN="https://${ADMIN_HOST}:${PORT}"
ACME_ORIGIN="https://${ACME_HOST}:${PORT}"

FILES_ADDR="${FILES_ADDR:-127.0.0.1:8279}"
spawn_files_server "$FILES_ADDR" "${DATA_DIRS[$LEADER_IDX]}" /tmp/http-send-smoke-cs.out "$ADMIN_ORIGIN" "$ADMIN_ORIGIN" || exit 1

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    for i in 0 1 2; do
        echo "--- worker $i log ---" >&2
        tail -40 "/tmp/${SMOKE_TAG}-worker-${i}.out" >&2
    done
    exit 1
}

# ── 1. Sanity: wb tenant is reachable on the leader ───────────────────
SANITY_BODY=$("${CURL[@]}" -X POST -H 'content-type: application/json' \
    -d '{"tag":"sanity"}' "https://${WB_HOST}:${PORT}/")
[[ "$SANITY_BODY" == "echoed:sanity" ]] \
    || fail "wb tenant sanity check returned: $SANITY_BODY"
ok "wb tenant reachable; index.mjs returns echoed:<tag>"

# ── 2. Fire the http.send through acme ────────────────────────────────
#
# acme/httpfire/index.mjs?fn=fire&args=[targetUrl, tag] →
#   http.send({url:targetUrl, body:JSON({from,tag}),
#              on_result:{module:"httpresult"}, context:{tag}})
# returns { id }.
TARGET_URL="https://${WB_HOST}:${PORT}/echo"
ARGS_JSON=$(python3 -c "
import json, urllib.parse
print(urllib.parse.quote(json.dumps(['${TARGET_URL}', 'optimization-win'])))
")
FIRE_BODY=$("${CURL[@]}" "${ACME_ORIGIN}/httpfire?fn=fire&args=${ARGS_JSON}")
ID=$(echo "$FIRE_BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
[[ -n "$ID" ]] || fail "fire didn't return an id: $FIRE_BODY"
ok "handler called http.send, id=$ID (${#ID} chars)"

# ── 3. Wait for the on_result callback to land in acme's kv ───────────
#
# Internal-pool path (worker phase → dispatcher.run → multi-envelope):
# typical latency is one raft round-trip (~10-50ms). 4s polling
# headroom covers slow CI without papering over real bugs.
RESULT_BODY=""
for _ in $(seq 1 40); do
    QS=$(python3 -c "
import json, urllib.parse
print(urllib.parse.quote(json.dumps(['http/result/','',100])))
")
    RESULT_BODY=$("${CURL[@]}" \
        -H "Authorization: Bearer $TOKEN" \
        -H "X-Rove-Scope: acme" \
        "${ADMIN_ORIGIN}/?fn=listKv&args=${QS}")
    if echo "$RESULT_BODY" | grep -q '"key":"http/result/'; then
        break
    fi
    sleep 0.1
done
echo "$RESULT_BODY" | grep -q '"key":"http/result/' \
    || fail "no http/result/* row after 4s: $RESULT_BODY"
ok "httpresult.mjs ran on acme's tenant; http/result/{id} written"

# ── 4. Verify the event shape passed to httpresult.mjs ────────────────
VERIFY_PY=$(mktemp --suffix=.py)
cat >"$VERIFY_PY" <<'PY'
import json, sys, os
expected_id = os.environ["ID"]
doc = json.loads(sys.stdin.read())
match = None
for e in doc.get("entries", []):
    if e["key"] == "http/result/" + expected_id:
        match = json.loads(e["value"])
        break
if match is None:
    print("no entry for http/result/" + expected_id, file=sys.stderr)
    sys.exit(2)
assert match["id"] == expected_id, f"id={match['id']!r} != {expected_id!r}"
assert match["ok"] is True, f"ok={match['ok']!r}"
assert match["status"] == 200, f"status={match['status']!r}"
assert match["version"] == 1, f"version={match['version']!r}"
assert match["body"] == "echoed:optimization-win", f"body={match['body']!r}"
assert match["context"]["tag"] == "optimization-win", f"context={match['context']!r}"
assert match["error"] in (None, ""), f"error={match['error']!r}"
print(json.dumps(match))
PY
ID="$ID" python3 "$VERIFY_PY" <<<"$RESULT_BODY" \
    || fail "event shape check failed: $RESULT_BODY"
ok "event shape: id=$ID, ok=true, status=200, version=1, body='echoed:optimization-win'"

# ── 5. Verify wb's writeset round-tripped (proves in-process path) ────
#
# In-process dispatch ran wb's handler against wb's app.db. The
# handler did `kv.set("wb/last_tag", tag)`. That write rides
# envelope-0 in the multi-envelope alongside envelope-9; every node
# applies it. Reading it via admin scope=wb confirms the writeset
# committed atomically.
QS=$(python3 -c "
import json, urllib.parse
print(urllib.parse.quote(json.dumps(['wb/last_tag'])))
")
WB_KV=$("${CURL[@]}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-Rove-Scope: wb" \
    "${ADMIN_ORIGIN}/?fn=getKv&args=${QS}")
echo "$WB_KV" | grep -q 'optimization-win' \
    || fail "wb/last_tag missing or wrong: $WB_KV"
ok "wb tenant writeset round-tripped: wb/last_tag=optimization-win"

# ── 6. Verify the worker phase took the in-process path ──────────────
#
# The leader's worker 0 logs `internal-schedules: ... dispatched
# in-process to wb status=200 outcome=delivered` exactly when the
# fast path won. If we somehow demoted to libcurl (e.g., wb wasn't
# in tenant_files_map), this assertion catches it — the smoke would
# still have passed all the previous checks (libcurl path is
# functionally identical) but we'd want to know.
LEADER_LOG="/tmp/${SMOKE_TAG}-worker-${LEADER_IDX}.out"
grep -q "internal-schedules:.*dispatched in-process to wb status=200" "$LEADER_LOG" \
    || fail "leader didn't log in-process dispatch (path may have demoted to libcurl): $(grep -i schedule "$LEADER_LOG" | tail -5)"
ok "leader took the in-process fast path (no libcurl roundtrip)"

# ── 7. Verify the schedule row was deleted (apply-side) ───────────────
#
# After envelope-9 commits, applyComplete deletes s/acme/{id} from
# schedules.db. The admin API doesn't expose schedules.db directly;
# instead, verify the receipt was cleared (callback ran + drop fired).
QS=$(python3 -c "
import json, urllib.parse
print(urllib.parse.quote(json.dumps(['_callback/','',100])))
")
CB_BODY=$("${CURL[@]}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-Rove-Scope: acme" \
    "${ADMIN_ORIGIN}/?fn=listKv&args=${QS}")
if echo "$CB_BODY" | grep -q '"key":"_callback/'; then
    fail "_callback/{id} receipt not cleared: $CB_BODY"
fi
ok "_callback/{id} receipt cleared (httpresult.mjs ran + receipt drop committed)"

echo ""
echo "all http.send fast-path smoke checks passed"
