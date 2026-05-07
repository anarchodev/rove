#!/usr/bin/env bash
# End-to-end smoke for the tape-replay browser path (PLAN §10.12).
#
# Phase 5.5(a) Step B layout: dashboard talks to two origins.
#   - app.{suffix}:{worker_port}  — worker (admin handler, files proxy,
#                                   /_system/log-token JWT minter)
#   - logs.{suffix}:{log_port}    — standalone log-server (TLS, JWT-gated
#                                   /v1/{tenant}/{list,show,count,blob})
#
# Each smoke section authenticates against the worker, mints a JWT,
# and uses it to call the standalone directly.
#
#   1. `__replay__` tenant + `replay.{suffix}` host alias serve the
#      replay shell static bundle (`web/replay/index.html` + `app.js`).
#   2. Fresh-tenant first request via the static path is captured in
#      the standalone server's index.
#   3. Multi-file handler deploy + run.
#   4. Tape capture for handler dispatch: kv, Date, module, request +
#      response body refs visible on the show response.
#   5. Historical deployment manifest endpoint.
#   6. Request body truncation flag fires for >256 KB bodies.
#   7. Tape blobs round-trip via the log-server's /v1/.../blob/{hash}.

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-replay-smoke}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8210}"
LOG_ADDR="${LOG_ADDR:-127.0.0.1:8211}"
FILES_ADDR="${FILES_ADDR:-127.0.0.1:8212}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40310}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd}"
ADMIN_HOST="app.loop46.localhost"
LOG_HOST="logs.loop46.localhost"
FILES_HOST="files.loop46.localhost"
PUBLIC_SUFFIX="loop46.localhost"
PORT="${HTTP_ADDR##*:}"
LOG_PORT="${LOG_ADDR##*:}"
FILES_PORT="${FILES_ADDR##*:}"
ADMIN_ORIGIN="https://${ADMIN_HOST}:${PORT}"
REPLAY_ORIGIN="https://replay.${PUBLIC_SUFFIX}:${PORT}"
LOG_ORIGIN="https://${LOG_HOST}:${LOG_PORT}"
FILES_ORIGIN="https://${FILES_HOST}:${FILES_PORT}"

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

# Phase 5.5(e) Task #62 — files-server runs as a separate process.
. "$(dirname "$0")/_smoke_helpers.sh"
export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"
spawn_files_server "$FILES_ADDR" "$DATA_DIR" /tmp/replay-smoke-cs.out "$ADMIN_ORIGIN" || exit 1
spawn_log_server "$LOG_ADDR" "$DATA_DIR" /tmp/replay-smoke-ls.out "$ADMIN_ORIGIN" || exit 1

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
    --fresh >/tmp/replay-smoke.out 2>&1 &
PID=$!
trap 'kill $PID $CS_PID $LS_PID 2>/dev/null || true; wait $PID $CS_PID $LS_PID 2>/dev/null || true' EXIT
sleep 1.5

ALICE_HOST="alice.${PUBLIC_SUFFIX}"
RESOLVE=(--resolve "${ADMIN_HOST}:${PORT}:127.0.0.1" \
         --resolve "${ALICE_HOST}:${PORT}:127.0.0.1" \
         --resolve "replay.${PUBLIC_SUFFIX}:${PORT}:127.0.0.1" \
         --resolve "${LOG_HOST}:${LOG_PORT}:127.0.0.1" \
         --resolve "${FILES_HOST}:${FILES_PORT}:127.0.0.1")
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    echo "--- worker log (last 40 lines) ---" >&2
    tail -40 /tmp/replay-smoke.out >&2
    exit 1
}

# Mint the services JWT against /_system/services-token. Returns
# both log_url and files_url so the smoke can call each standalone
# subdomain directly. ROVE_TOKEN drives the worker-side auth gate.
ROVE_TOKEN="$TOKEN"
mint_services_token
[[ "${LOG_BASE}" == "${LOG_ORIGIN}" ]] || \
    fail "log_url mismatch: got '${LOG_BASE}', expected '${LOG_ORIGIN}'"
[[ "${FILES_BASE}" == "${FILES_ORIGIN}" ]] || \
    fail "files_url mismatch: got '${FILES_BASE}', expected '${FILES_ORIGIN}'"
ok "minted services JWT via /_system/services-token (log=${LOG_BASE} files=${FILES_BASE})"

# Standalone log-server's indexer polls every 500ms (loop46 default).
# Each "did the record show up" check waits up to 12s.
wait_for_record() {
    local path_filter="$1"
    local max_attempts=30
    local i=0
    while (( i < max_attempts )); do
        local list
        list=$("${CURL[@]}" -H "Authorization: Bearer $JWT" \
            "${LOG_ORIGIN}/v1/alice/list?limit=20" 2>/dev/null || echo '{"records":[]}')
        local rid
        rid=$(echo "$list" | python3 -c "
import json, sys
recs = json.load(sys.stdin)['records']
for r in recs:
    if r['path'] == '$path_filter':
        print(r['request_id'])
        sys.exit(0)
" 2>/dev/null)
        if [[ -n "$rid" ]]; then
            echo "$rid"
            return 0
        fi
        sleep 0.4
        i=$((i + 1))
    done
    return 1
}

# ── 1. Replay tenant + host alias ────────────────────────────────
status=$("${CURL[@]}" -o /dev/null -w "%{http_code}" "${REPLAY_ORIGIN}/")
[[ "$status" == "200" ]] || fail "replay shell GET / → $status (expected 200)"
ok "replay.${PUBLIC_SUFFIX}/ serves shell index"

ct=$("${CURL[@]}" -I "${REPLAY_ORIGIN}/app.js" | grep -i "^content-type:" | tr -d '\r')
echo "$ct" | grep -qi "application/javascript" || fail "replay app.js HEAD content-type: $ct"
ok "replay shell app.js served as application/javascript (HEAD)"

# ── 2. Fresh-tenant first request via static — log must capture ─
resp=$("${CURL[@]}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"alice","email":"alice@example.com"}' \
    "${ADMIN_ORIGIN}/v1/signup")
MAGIC=$(echo "$resp" | python3 -c 'import json,sys;print(json.load(sys.stdin)["magic_link"])' | sed 's/.*mt=//')
"${CURL[@]}" -i "${ADMIN_ORIGIN}/v1/auth?mt=${MAGIC}" >/dev/null

status=$("${CURL[@]}" -o /dev/null -w "%{http_code}" "https://${ALICE_HOST}:${PORT}/")
[[ "$status" == "200" ]] || fail "fresh-tenant static GET / → $status"

# Wait for the standalone server's indexer to surface the record.
FRESH_RID=$(wait_for_record "/") || fail "fresh-tenant static request not indexed within 12s"
ok "fresh-tenant static request captured + indexed"

if grep -q "NoTenantLog\|log capture failed" /tmp/replay-smoke.out; then
    fail "NoTenantLog warning appeared during smoke — lazy-open regression"
fi
ok "no NoTenantLog warnings in worker output"

# ── 3. Multi-file deploy + run ───────────────────────────────────
LIB_SRC='export function greet(name) { return "hello " + name; }'
IDX_SRC='import { greet } from "./lib/util.mjs";

export default function () {
  kv.set("hits/" + Date.now(), request.body || "");
  const visits = kv.prefix("hits/", "", 100);
  response.headers = { "content-type": "application/json" };
  return JSON.stringify({
    greeting: greet(request.path),
    visit_count: visits.length,
  });
}'

LIB_HASH=$(printf '%s' "$LIB_SRC" | sha256sum | awk '{print $1}')
IDX_HASH=$(printf '%s' "$IDX_SRC" | sha256sum | awk '{print $1}')

"${CURL[@]}" -H "Authorization: Bearer $JWT" -X PUT \
    -H 'Content-Type: application/octet-stream' --data-binary "$LIB_SRC" \
    "${FILES_BASE}/alice/blobs/${LIB_HASH}" >/dev/null
"${CURL[@]}" -H "Authorization: Bearer $JWT" -X PUT \
    -H 'Content-Type: application/octet-stream' --data-binary "$IDX_SRC" \
    "${FILES_BASE}/alice/blobs/${IDX_HASH}" >/dev/null

deploy_v2_resp=$("${CURL[@]}" -H "Authorization: Bearer $JWT" -X POST \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c "
import json
print(json.dumps({
    'files': {
        'index.mjs':    {'hash': '$IDX_HASH', 'kind': 'handler'},
        'lib/util.mjs': {'hash': '$LIB_HASH', 'kind': 'handler'},
    },
    'parent_id': '0000000000000001',
}))
")" \
    "${FILES_BASE}/alice/deployments")
echo "$deploy_v2_resp" | grep -q '"id":"0000000000000002"' || \
    fail "multi-file deploy v2 unexpected response: $deploy_v2_resp"
ok "multi-file deploy compiled (sibling import resolved at compile time)"
release_deployment "alice" 2 || fail "release alice/2"

resp=$("${CURL[@]}" -X POST -d 'first-visit' \
    "https://${ALICE_HOST}:${PORT}/world")
echo "$resp" | grep -q '"greeting":"hello /world"' || \
    fail "handler return wrong: $resp"
ok "multi-module handler executed (transitive import works)"

# ── 4. Tape capture: kv + date + module + body ───────────────────
RID=$(wait_for_record "/world") || fail "couldn't find POST /world in indexed log"

REC=$("${CURL[@]}" -H "Authorization: Bearer $JWT" \
    "${LOG_ORIGIN}/v1/alice/show/${RID}")
got_kv=$(echo "$REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["record"]["tape_refs"]["kv_tape_hex"] or "")')
got_date=$(echo "$REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["record"]["tape_refs"]["date_tape_hex"] or "")')
got_mod=$(echo "$REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["record"]["tape_refs"]["module_tree_hex"] or "")')
got_body=$(echo "$REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["record"]["tape_refs"]["request_body_hex"] or "")')
got_trunc=$(echo "$REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["record"]["tape_refs"]["request_body_truncated"])')
got_resp_body=$(echo "$REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["record"]["tape_refs"]["response_body_hex"] or "")')
got_resp_trunc=$(echo "$REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["record"]["tape_refs"]["response_body_truncated"])')

[[ -n "$got_kv" ]]    || fail "kv_tape_hex missing on log record"
[[ -n "$got_date" ]]  || fail "date_tape_hex missing"
[[ -n "$got_mod" ]]   || fail "module_tree_hex missing (multi-module capture)"
[[ -n "$got_body" ]]  || fail "request_body_hex missing"
[[ "$got_trunc" == "False" ]] || fail "request_body_truncated should be false for small body"
[[ -n "$got_resp_body" ]] || fail "response_body_hex missing"
[[ "$got_resp_trunc" == "False" ]] || fail "response_body_truncated should be false for small response"
ok "log record carries kv + date + module + req-body + resp-body tape refs"

# Fetch the body blob and verify content.
body_text=$("${CURL[@]}" -H "Authorization: Bearer $JWT" \
    "${LOG_ORIGIN}/v1/alice/blob/${got_body}")
[[ "$body_text" == "first-visit" ]] || fail "body blob content drift: '$body_text'"
ok "request body blob content round-trips"

resp_text=$("${CURL[@]}" -H "Authorization: Bearer $JWT" \
    "${LOG_ORIGIN}/v1/alice/blob/${got_resp_body}")
[[ "$resp_text" == "$resp" ]] || \
    fail "response body blob drift: expected '$resp', got '$resp_text'"
ok "response body blob content round-trips"

# ── 5. Historical deployment manifest ────────────────────────────
NEW_IDX_SRC='export default function () { return "v3"; }'
NEW_HASH=$(printf '%s' "$NEW_IDX_SRC" | sha256sum | awk '{print $1}')
"${CURL[@]}" -H "Authorization: Bearer $JWT" -X PUT \
    -H 'Content-Type: application/octet-stream' --data-binary "$NEW_IDX_SRC" \
    "${FILES_BASE}/alice/blobs/${NEW_HASH}" >/dev/null
"${CURL[@]}" -H "Authorization: Bearer $JWT" -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"files\":{\"index.mjs\":{\"hash\":\"${NEW_HASH}\",\"kind\":\"handler\"}},\"parent_id\":\"0000000000000002\"}" \
    "${FILES_BASE}/alice/deployments" >/dev/null

v2=$("${CURL[@]}" -H "Authorization: Bearer $JWT" \
    "${FILES_BASE}/alice/deployments/0000000000000002")
echo "$v2" | python3 -c '
import json, sys
m = json.load(sys.stdin)
assert m["deployment_id"] == 2, m
paths = sorted(e["path"] for e in m["entries"])
assert paths == ["index.mjs", "lib/util.mjs"], paths
' || fail "v2 historical manifest content mismatch"
ok "historical deployment manifest by hex id"

status=$("${CURL[@]}" -H "Authorization: Bearer $JWT" -o /dev/null -w "%{http_code}" \
    "${FILES_BASE}/alice/deployments/0000000000000099")
[[ "$status" == "404" ]] || fail "missing deployment → $status (expected 404)"
ok "missing deployment id → 404"

status=$("${CURL[@]}" -H "Authorization: Bearer $JWT" -o /dev/null -w "%{http_code}" \
    "${FILES_BASE}/alice/deployments/notHex")
[[ "$status" == "400" ]] || fail "invalid hex deployment id → $status (expected 400)"
ok "invalid hex deployment id → 400"

# ── 6. Request body truncation flag ──────────────────────────────
python3 -c "import sys; sys.stdout.buffer.write(b'x' * 300000)" \
    | "${CURL[@]}" -X POST --data-binary @- \
        -o /dev/null \
        "https://${ALICE_HOST}:${PORT}/big"

BIG_RID=$(wait_for_record "/big") || fail "couldn't find POST /big in indexed log"
BIG_REC=$("${CURL[@]}" -H "Authorization: Bearer $JWT" \
    "${LOG_ORIGIN}/v1/alice/show/${BIG_RID}")
big_trunc=$(echo "$BIG_REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["record"]["tape_refs"]["request_body_truncated"])')
big_hash=$(echo "$BIG_REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["record"]["tape_refs"]["request_body_hex"])')
[[ "$big_trunc" == "True" ]] || fail "300 KB body should set truncation flag (got $big_trunc)"
ok "truncation flag set for >256 KB body"

# Verify the captured blob is exactly 256 KB by fetching it.
big_body=$("${CURL[@]}" -H "Authorization: Bearer $JWT" -o /tmp/replay-smoke-big.bin -w '%{http_code}' \
    "${LOG_ORIGIN}/v1/alice/blob/${big_hash}")
[[ "$big_body" == "200" ]] || fail "big body blob fetch got $big_body"
blob_size=$(wc -c < /tmp/replay-smoke-big.bin)
[[ "$blob_size" == "262144" ]] || fail "captured blob should be 256 KB, got $blob_size"
ok "captured body blob exactly 262144 bytes (256 KB)"
rm -f /tmp/replay-smoke-big.bin

# JWT gate sanity: the same /v1 path without a bearer must 401.
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${LOG_ORIGIN}/v1/alice/list")
[[ "$code" == "401" ]] || fail "log-server without bearer should 401, got $code"
ok "log-server /v1/* without bearer → 401"

echo ""
echo "all replay smoke checks passed"
