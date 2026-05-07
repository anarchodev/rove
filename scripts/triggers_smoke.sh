#!/usr/bin/env bash
# End-to-end smoke test for the trigger system (PLAN §2.5).
#
# Covers the full path through deploy → fire → kv state:
#   - Deploy a tenant with two trigger modules
#     (_triggers/users/sessions/index.mjs, _triggers/orders/index.mjs)
#     plus a handler that exercises both
#   - afterPut maintains a reverse index in customer kv
#   - beforePut throw rejects the write; handler catches with
#     `e.code === "trigger_rejected"`; rejected write does not land
#   - beforePut return-value mutates the stored value
#   - afterDelete cleans up the reverse index using event.previousValue
#
# Pattern: signup a fresh tenant, deploy modules via the single-file
# admin endpoint (PUT /_system/files/{instance}/file/<path>), hit the
# handler at the tenant subdomain, verify resulting kv state via
# admin listKv with X-Rove-Scope: <tenant>.

set -euo pipefail

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-triggers-smoke}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8265}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40365}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee}"
ADMIN_HOST="app.loop46.localhost"
PUBLIC_SUFFIX="loop46.localhost"

# TLS via mkcert. Both URLs are https://, so the worker has to listen
# under TLS for curl to make it past the handshake.
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

FILES_ADDR="${FILES_ADDR:-127.0.0.1:8214}"
LOG_ADDR="${LOG_ADDR:-127.0.0.1:8213}"
FILES_PORT="${FILES_ADDR##*:}"
LOG_PORT="${LOG_ADDR##*:}"
FILES_HOST="files.${PUBLIC_SUFFIX}"
LOG_HOST="logs.${PUBLIC_SUFFIX}"
FILES_ORIGIN="https://${FILES_HOST}:${FILES_PORT}"

# 3-node cluster (Phase 5.5(?) — `loop46 worker` requires --peers ≥ 2).
. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=triggers-smoke
SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

RESOLVE=()
for h in "${HTTP_ADDRS[@]}"; do
    p="${h##*:}"
    RESOLVE+=(--resolve "${ADMIN_HOST}:${p}:127.0.0.1" \
              --resolve "trigsmoke.${PUBLIC_SUFFIX}:${p}:127.0.0.1")
done
RESOLVE+=(--resolve "${FILES_HOST}:${FILES_PORT}:127.0.0.1" \
          --resolve "${LOG_HOST}:${LOG_PORT}:127.0.0.1")
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")
AUTH=(-H "Authorization: Bearer $TOKEN")

export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"

PIDS=()
for i in 0 1 2; do
    "$BIN" worker \
        --node-id "$i" \
        --peers "$PEERS_CSV" \
        --listen "${RAFT_ADDRS[$i]}" \
        --http "${HTTP_ADDRS[$i]}" \
        --log-public-base "https://logs.${PUBLIC_SUFFIX}:${LOG_PORT}" \
        --files-public-base "https://files.${PUBLIC_SUFFIX}:${FILES_PORT}" \
        --data-dir "${DATA_DIRS[$i]}" \
        --bootstrap-root-token "$TOKEN" \
        --public-suffix "$PUBLIC_SUFFIX" \
        --tls-cert "$TLS_CERT" \
        --tls-key "$TLS_KEY" \
        --workers 2 \
        "${RAFT_TIMING_FLAGS[@]}" \
        --fresh >"/tmp/${SMOKE_TAG}-worker-${i}.out" 2>&1 &
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

discover_leader "$ADMIN_HOST" "$TOKEN" || exit 1
ADMIN_ORIGIN="https://${ADMIN_HOST}:${LEADER_PORT}"
TENANT_ORIGIN="https://trigsmoke.${PUBLIC_SUFFIX}:${LEADER_PORT}"
echo "ok  leader elected: node $LEADER_IDX at $LEADER_HTTP"

spawn_files_server "$FILES_ADDR" "${DATA_DIRS[$LEADER_IDX]}" /tmp/${SMOKE_TAG}-cs.out "$ADMIN_ORIGIN" || exit 1
spawn_log_server "$LOG_ADDR" "${DATA_DIRS[$LEADER_IDX]}" /tmp/${SMOKE_TAG}-ls.out "$ADMIN_ORIGIN" || exit 1

ROVE_TOKEN="$TOKEN"
mint_services_token

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    echo "--- worker log (last 60 lines) ---" >&2
    tail -60 /tmp/${SMOKE_TAG}-worker-${LEADER_IDX}.out >&2
    exit 1
}

# ── 1. Signup + redeem creates the trigsmoke tenant ────────────────────────
# Lazy creation: signup writes pending/{name} only; the tenant
# directory + starter deploy happen at /v1/auth redeem time.
body=$("${CURL[@]}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"trigsmoke","email":"trigsmoke@example.com"}' \
    "${ADMIN_ORIGIN}/v1/signup")
echo "$body" | grep -q '"ok":true' || fail "signup not ok: $body"
MT=$(echo "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["magic_link"])' \
    | sed 's/.*mt=//')
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${ADMIN_ORIGIN}/v1/auth?mt=${MT}")
[[ "$code" == "302" ]] || fail "redeem trigsmoke: got $code"
ok "POST /v1/signup + /v1/auth redeem trigsmoke"

# Helper: PUT a single file into trigsmoke's deployment. Each call commits
# a fresh deployment AND pushes the new dep_id to the worker via
# /_system/release (Phase 5.5(e) F2 retired the polling fallback).
put_file() {
    local path="$1"
    local body="$2"
    local resp
    resp=$("${CURL[@]}" -w $'\n%{http_code}' \
        -X PUT \
        -H "Authorization: Bearer $JWT" \
        -H "Content-Type: application/javascript" \
        --data-binary "$body" \
        "${FILES_BASE}/trigsmoke/file/${path}")
    local code="${resp##*$'\n'}"
    local dep_id="${resp%$'\n'*}"
    [[ "$code" == "201" ]] || fail "PUT $path: got $code"
    release_deployment "trigsmoke" "$dep_id" || fail "release after PUT $path failed"
}

# Helper: read a kv value from trigsmoke's app.db via admin listKv.
# Returns the value field for the matching key (or empty if not found).
# resp + key go through env vars so we don't have to worry about
# quote-escaping the JSON response into a Python string literal.
kv_get_trigsmoke() {
    local key="$1"
    local args
    args=$(KEY="$key" python3 -c '
import json, os, urllib.parse
print(urllib.parse.quote(json.dumps([os.environ["KEY"], "", 100])))
')
    local resp
    resp=$("${CURL[@]}" "${AUTH[@]}" -H "X-Rove-Scope: trigsmoke" \
        "${ADMIN_ORIGIN}/?fn=listKv&args=${args}")
    KEY="$key" RESP="$resp" python3 -c '
import json, os, sys
doc = json.loads(os.environ["RESP"])
key = os.environ["KEY"]
for e in doc.get("entries", []):
    if e["key"] == key:
        print(e["value"], end="")
        sys.exit(0)
'
}

# ── 2. Deploy: trigger module + handler ──────────────────────────────
# Trigger maintains a reverse index (sid → user_id) on every put,
# rejects sessions missing user_id, lowercases the user_id before
# storage, and cleans up the index on delete.
TRIGGER_SRC='export function beforePut(event) {
  const sess = JSON.parse(event.value);
  if (!sess.user_id) throw new Error("session missing user_id");
  // Mutation: lowercase the user_id before storage.
  return JSON.stringify({ ...sess, user_id: sess.user_id.toLowerCase() });
}
export function afterPut(event) {
  const sess = JSON.parse(event.value);
  const sid = event.key.split("/").pop();
  kv.set("users/by-session/" + sid, sess.user_id);
}
export function afterDelete(event) {
  if (event.previousValue) {
    const sess = JSON.parse(event.previousValue);
    const sid = event.key.split("/").pop();
    kv.delete("users/by-session/" + sid);
  }
}'
put_file "_triggers/users/sessions/index.mjs" "$TRIGGER_SRC"

# Handler routes by request.path:
#   POST /create  → create session (calls kv.set)
#   POST /create-bad → tries to create a session missing user_id;
#                      catches the trigger_rejected error and reports it
#   POST /delete  → delete session (calls kv.delete)
HANDLER_SRC='export default function () {
  const path = request.path;
  if (path === "/create") {
    const body = JSON.parse(request.body);
    kv.set("users/sessions/" + body.sid, JSON.stringify({ user_id: body.user_id }));
    return { ok: true };
  }
  if (path === "/create-bad") {
    try {
      kv.set("users/sessions/bad", JSON.stringify({}));
      return { ok: false, note: "should not reach" };
    } catch (e) {
      return { ok: false, code: e.code, message: e.message };
    }
  }
  if (path === "/delete") {
    const body = JSON.parse(request.body);
    kv.delete("users/sessions/" + body.sid);
    return { ok: true };
  }
  return { ok: false, error: "unknown path" };
}'
put_file "index.mjs" "$HANDLER_SRC"
sleep 0.4
ok "deployed trigger + handler"

# ── 3. Successful create fires afterPut (reverse index built) ────────
code=$("${CURL[@]}" -o /tmp/triggers-create.out -w '%{http_code}' \
    -X POST -H "Content-Type: application/json" \
    -d '{"sid":"abc","user_id":"ALICE"}' \
    "${TENANT_ORIGIN}/create")
[[ "$code" == "200" ]] || fail "POST /create: got $code (body: $(cat /tmp/triggers-create.out))"
grep -q '"ok":true' /tmp/triggers-create.out \
    || fail "create body: $(cat /tmp/triggers-create.out)"

# Verify the session row exists AND the BEFORE mutation lowercased
# the user_id.
sess=$(kv_get_trigsmoke "users/sessions/abc")
[[ -n "$sess" ]] || fail "session row missing after /create"
echo "$sess" | grep -q '"user_id":"alice"' \
    || fail "BEFORE mutation didn't lowercase: $sess"
ok "afterPut maintained session row + beforePut mutated value"

# Verify the reverse index was built by afterPut.
indexed=$(kv_get_trigsmoke "users/by-session/abc")
[[ "$indexed" == "alice" ]] || fail "reverse index missing or wrong: '$indexed'"
ok "afterPut built reverse index users/by-session/abc → alice"

# ── 4. beforePut rejection: handler catches trigger_rejected ─────────
code=$("${CURL[@]}" -o /tmp/triggers-bad.out -w '%{http_code}' \
    -X POST -H "Content-Type: application/json" \
    -d '{}' \
    "${TENANT_ORIGIN}/create-bad")
[[ "$code" == "200" ]] || fail "POST /create-bad: got $code"
grep -q '"code":"trigger_rejected"' /tmp/triggers-bad.out \
    || fail "create-bad missing code=trigger_rejected: $(cat /tmp/triggers-bad.out)"
grep -q 'session missing user_id' /tmp/triggers-bad.out \
    || fail "create-bad missing original message: $(cat /tmp/triggers-bad.out)"
grep -q '_triggers/users/sessions/index.mjs' /tmp/triggers-bad.out \
    || fail "create-bad missing trigger path in message: $(cat /tmp/triggers-bad.out)"
ok "beforePut throw → catchable Error{ code:'trigger_rejected', message:'<path>: <orig>' }"

# Verify the rejected write did NOT land in kv.
bad_sess=$(kv_get_trigsmoke "users/sessions/bad")
[[ -z "$bad_sess" ]] || fail "rejected write leaked into kv: '$bad_sess'"
ok "rejected write is NOT in kv (inner savepoint rolled back)"

# ── 5. afterDelete cleanup uses event.previousValue ──────────────────
code=$("${CURL[@]}" -o /tmp/triggers-del.out -w '%{http_code}' \
    -X POST -H "Content-Type: application/json" \
    -d '{"sid":"abc"}' \
    "${TENANT_ORIGIN}/delete")
[[ "$code" == "200" ]] || fail "POST /delete: got $code"

# Both the session row AND its reverse index should be gone.
sess_after=$(kv_get_trigsmoke "users/sessions/abc")
[[ -z "$sess_after" ]] || fail "session row survived /delete: '$sess_after'"
indexed_after=$(kv_get_trigsmoke "users/by-session/abc")
[[ -z "$indexed_after" ]] || fail "reverse index survived /delete: '$indexed_after'"
ok "afterDelete cleaned up reverse index via event.previousValue"

echo ""
echo "all triggers smoke checks passed"
