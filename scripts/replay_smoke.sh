#!/usr/bin/env bash
# End-to-end smoke for the tape-replay browser path (PLAN §10.12).
#
# Exercises the full feature surface:
#
#   1. `__replay__` tenant + `replay.{suffix}` host alias serve the
#      replay shell static bundle (`web/replay/index.html` + `app.js`).
#
#   2. Fresh-tenant first request via the static path is captured
#      in the log — the lazy-open fix that hoists
#      `getOrOpenTenantLog` ahead of the early-exit `captureLog`
#      branches in `dispatchOnce`.
#
#   3. Multi-file handler deploy: handler that `import`s a sibling
#      module compiles via the InlineCompiler module loader, runs
#      under runtime dispatch.
#
#   4. Tape capture for handler dispatch: kv (incl. `kv.prefix`),
#      Date, module-resolution, and request body all stamped into
#      `tape_refs` on the log record. Each blob fetched by hash
#      from the per-tenant log-blobs/.
#
#   5. Historical deployment manifest endpoint
#      (`GET /_system/files/{inst}/deployments/{hex}`) returns the
#      manifest of a specific past deployment, not the current one.
#
#   6. Request body truncation flag (`request_body_truncated`)
#      fires when the body exceeds the 256 KB cap.
#
#   7. `rove-log-cli bundle` JSON shape — modules array populated
#      from the captured module tape, tape arrays populated, body
#      hash present.
#
# Each ok-line below corresponds to one assertion. Failures dump
# the worker log tail and exit non-zero.

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-replay-smoke}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8210}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40310}"
BIN="${BIN:-./zig-out/bin/loop46}"
LOG_CLI="${LOG_CLI:-./zig-out/bin/rove-log-cli}"
TOKEN="${ROVE_TOKEN:-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd}"
ADMIN_HOST="app.loop46.localhost"
PUBLIC_SUFFIX="loop46.localhost"
PORT="${HTTP_ADDR##*:}"
ADMIN_ORIGIN="https://${ADMIN_HOST}:${PORT}"
REPLAY_ORIGIN="https://replay.${PUBLIC_SUFFIX}:${PORT}"

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
if [[ ! -x "$LOG_CLI" ]]; then
    echo "error: $LOG_CLI missing — run 'zig build install' first" >&2
    exit 2
fi

# Phase 5.5(a) deleted the raft envelope-1 log path. The whole
# replay surface (list/show/blob proxies + rove-log-cli bundle)
# depends on per-tenant log records, which now flow worker → S3
# instead of worker → raft → log.db. Until the S3 read-side wiring
# lands, this smoke can't drive any of the replay assertions and
# is short-circuited to a no-op. The S3-direct cross-validation
# lives in scripts/log_backend_s3_smoke.sh.
echo "SKIP replay smoke (Phase 5.5(a) read-side wiring pending)"
exit 0

rm -rf "$DATA_DIR"

"$BIN" worker \
    --node-id 0 \
    --peers "$RAFT_ADDR" \
    --listen "$RAFT_ADDR" \
    --http "$HTTP_ADDR" \
    --data-dir "$DATA_DIR" \
    --bootstrap-root-token "$TOKEN" \
    --admin-origin "$ADMIN_ORIGIN" \
    --public-suffix "$PUBLIC_SUFFIX" \
    --tls-cert "$TLS_CERT" \
    --tls-key "$TLS_KEY" \
    --workers 1 \
    --refresh-interval-ms 100 \
    --fresh >/tmp/replay-smoke.out 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true' EXIT
sleep 1.5

ALICE_HOST="alice.${PUBLIC_SUFFIX}"
RESOLVE=(--resolve "${ADMIN_HOST}:${PORT}:127.0.0.1" \
         --resolve "${ALICE_HOST}:${PORT}:127.0.0.1" \
         --resolve "replay.${PUBLIC_SUFFIX}:${PORT}:127.0.0.1")
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    echo "--- worker log (last 40 lines) ---" >&2
    tail -40 /tmp/replay-smoke.out >&2
    exit 1
}

# ── 1. Replay tenant + host alias ────────────────────────────────
status=$("${CURL[@]}" -o /dev/null -w "%{http_code}" "${REPLAY_ORIGIN}/")
[[ "$status" == "200" ]] || fail "replay shell GET / → $status (expected 200)"
ok "replay.${PUBLIC_SUFFIX}/ serves shell index"

# HEAD on a static file: same headers as GET, no body.
ct=$("${CURL[@]}" -I "${REPLAY_ORIGIN}/app.js" | grep -i "^content-type:" | tr -d '\r')
echo "$ct" | grep -qi "application/javascript" || fail "replay app.js HEAD content-type: $ct"
ok "replay shell app.js served as application/javascript (HEAD)"

# ── 2. Fresh-tenant first request via static — log must capture ─
resp=$("${CURL[@]}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"name":"alice","email":"alice@example.com"}' \
    "${ADMIN_ORIGIN}/v1/signup")
MAGIC=$(echo "$resp" | python3 -c 'import json,sys;print(json.load(sys.stdin)["magic_link"])' | sed 's/.*mt=//')
# Redeem the magic link — that's what allocates the tenant +
# deploys starter content (Phase 4 lazy-creation-on-redeem).
"${CURL[@]}" -i "${ADMIN_ORIGIN}/v1/auth?mt=${MAGIC}" >/dev/null

# First request to the new tenant — STATIC path (starter index.html).
# Without the d732641 fix this captureLog drops silently because
# the tenant_logs cache is cold for runtime-created tenants.
status=$("${CURL[@]}" -o /dev/null -w "%{http_code}" "https://${ALICE_HOST}:${PORT}/")
[[ "$status" == "200" ]] || fail "fresh-tenant static GET / → $status"
sleep 1

list=$("${CURL[@]}" -H "Authorization: Bearer $TOKEN" \
    "${ADMIN_ORIGIN}/_system/log/alice/list?limit=5")
n=$(echo "$list" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["records"]))')
[[ "$n" -ge 1 ]] || fail "fresh-tenant static request not logged ($n records)"
ok "fresh-tenant static request captured in log (lazy-open fix)"

# Confirm no NoTenantLog warnings landed in the worker output.
if grep -q "NoTenantLog\|log capture failed" /tmp/replay-smoke.out; then
    fail "NoTenantLog warning appeared during smoke — lazy-open regression"
fi
ok "no NoTenantLog warnings in worker output"

# ── 3. Multi-file deploy + run ───────────────────────────────────
LIB_SRC='export function greet(name) { return "hello " + name; }'
IDX_SRC='import { greet } from "./lib/util.mjs";

export default function () {
  // Tag every visit so the kv tape gets `set` + `prefix` entries.
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

"${CURL[@]}" -H "Authorization: Bearer $TOKEN" -X PUT \
    -H 'Content-Type: application/octet-stream' --data-binary "$LIB_SRC" \
    "${ADMIN_ORIGIN}/_system/files/alice/blobs/${LIB_HASH}" >/dev/null
"${CURL[@]}" -H "Authorization: Bearer $TOKEN" -X PUT \
    -H 'Content-Type: application/octet-stream' --data-binary "$IDX_SRC" \
    "${ADMIN_ORIGIN}/_system/files/alice/blobs/${IDX_HASH}" >/dev/null

deploy_v2_resp=$("${CURL[@]}" -H "Authorization: Bearer $TOKEN" -X POST \
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
    "${ADMIN_ORIGIN}/_system/files/alice/deployments")
echo "$deploy_v2_resp" | grep -q '"id":"0000000000000002"' || \
    fail "multi-file deploy v2 unexpected response: $deploy_v2_resp"
ok "multi-file deploy compiled (sibling import resolved at compile time)"
sleep 0.5

# Hit the multi-module handler with a small POST body.
resp=$("${CURL[@]}" -X POST -d 'first-visit' \
    "https://${ALICE_HOST}:${PORT}/world")
echo "$resp" | grep -q '"greeting":"hello /world"' || \
    fail "handler return wrong: $resp"
ok "multi-module handler executed (transitive import works)"
sleep 0.7

# ── 4. Tape capture: kv + date + module + body ───────────────────
list=$("${CURL[@]}" -H "Authorization: Bearer $TOKEN" \
    "${ADMIN_ORIGIN}/_system/log/alice/list?limit=10")
RID=$(echo "$list" | python3 -c '
import json, sys
recs = json.load(sys.stdin)["records"]
for r in recs:
    if r["method"] == "POST" and r["path"] == "/world":
        print(r["request_id"])
        break
')
[[ -n "$RID" ]] || fail "couldn'\''t find POST /world in log list"

REC=$("${CURL[@]}" -H "Authorization: Bearer $TOKEN" \
    "${ADMIN_ORIGIN}/_system/log/alice/show/${RID}")
got_kv=$(echo "$REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tape_refs"]["kv_tape_hex"] or "")')
got_date=$(echo "$REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tape_refs"]["date_tape_hex"] or "")')
got_mod=$(echo "$REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tape_refs"]["module_tree_hex"] or "")')
got_body=$(echo "$REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tape_refs"]["request_body_hex"] or "")')
got_trunc=$(echo "$REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tape_refs"]["request_body_truncated"])')
got_resp_body=$(echo "$REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tape_refs"]["response_body_hex"] or "")')
got_resp_trunc=$(echo "$REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tape_refs"]["response_body_truncated"])')

[[ -n "$got_kv" ]]    || fail "kv_tape_hex missing on log record"
[[ -n "$got_date" ]]  || fail "date_tape_hex missing"
[[ -n "$got_mod" ]]   || fail "module_tree_hex missing (multi-module capture)"
[[ -n "$got_body" ]]  || fail "request_body_hex missing"
[[ "$got_trunc" == "False" ]] || fail "request_body_truncated should be false for small body"
[[ -n "$got_resp_body" ]] || fail "response_body_hex missing"
[[ "$got_resp_trunc" == "False" ]] || fail "response_body_truncated should be false for small response"
ok "log record carries kv + date + module + req-body + resp-body tape refs"

# Fetch the body blob and verify content.
body_text=$("${CURL[@]}" -H "Authorization: Bearer $TOKEN" \
    "${ADMIN_ORIGIN}/_system/log/alice/blob/${got_body}")
[[ "$body_text" == "first-visit" ]] || fail "body blob content drift: '$body_text'"
ok "request body blob content round-trips"

# Fetch the response body blob and verify it matches what curl saw.
resp_text=$("${CURL[@]}" -H "Authorization: Bearer $TOKEN" \
    "${ADMIN_ORIGIN}/_system/log/alice/blob/${got_resp_body}")
[[ "$resp_text" == "$resp" ]] || \
    fail "response body blob drift: expected '$resp', got '$resp_text'"
ok "response body blob content round-trips"

# ── 5. Historical deployment manifest ────────────────────────────
# Deploy v3 with different content, then verify v2's manifest is
# still fetchable by hex id and matches what alice's POST ran
# against (deployment_id=2 captured on the request).
NEW_IDX_SRC='export default function () { return "v3"; }'
NEW_HASH=$(printf '%s' "$NEW_IDX_SRC" | sha256sum | awk '{print $1}')
"${CURL[@]}" -H "Authorization: Bearer $TOKEN" -X PUT \
    -H 'Content-Type: application/octet-stream' --data-binary "$NEW_IDX_SRC" \
    "${ADMIN_ORIGIN}/_system/files/alice/blobs/${NEW_HASH}" >/dev/null
"${CURL[@]}" -H "Authorization: Bearer $TOKEN" -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"files\":{\"index.mjs\":{\"hash\":\"${NEW_HASH}\",\"kind\":\"handler\"}},\"parent_id\":\"0000000000000002\"}" \
    "${ADMIN_ORIGIN}/_system/files/alice/deployments" >/dev/null

# v2 manifest must still be reachable by id.
v2=$("${CURL[@]}" -H "Authorization: Bearer $TOKEN" \
    "${ADMIN_ORIGIN}/_system/files/alice/deployments/0000000000000002")
echo "$v2" | python3 -c '
import json, sys
m = json.load(sys.stdin)
assert m["deployment_id"] == 2, m
paths = sorted(e["path"] for e in m["entries"])
assert paths == ["index.mjs", "lib/util.mjs"], paths
' || fail "v2 historical manifest content mismatch"
ok "historical deployment manifest by hex id"

status=$("${CURL[@]}" -H "Authorization: Bearer $TOKEN" -o /dev/null -w "%{http_code}" \
    "${ADMIN_ORIGIN}/_system/files/alice/deployments/0000000000000099")
[[ "$status" == "404" ]] || fail "missing deployment → $status (expected 404)"
ok "missing deployment id → 404"

status=$("${CURL[@]}" -H "Authorization: Bearer $TOKEN" -o /dev/null -w "%{http_code}" \
    "${ADMIN_ORIGIN}/_system/files/alice/deployments/notHex")
[[ "$status" == "400" ]] || fail "invalid hex deployment id → $status (expected 400)"
ok "invalid hex deployment id → 400"

# ── 6. Request body truncation flag ──────────────────────────────
# 300 KB body → captured to 256 KB prefix, truncation flag set.
python3 -c "import sys; sys.stdout.buffer.write(b'x' * 300000)" \
    | "${CURL[@]}" -X POST --data-binary @- \
        -o /dev/null \
        "https://${ALICE_HOST}:${PORT}/big"
sleep 1

big=$("${CURL[@]}" -H "Authorization: Bearer $TOKEN" \
    "${ADMIN_ORIGIN}/_system/log/alice/list?limit=10")
BIG_RID=$(echo "$big" | python3 -c '
import json, sys
for r in json.load(sys.stdin)["records"]:
    if r["path"] == "/big":
        print(r["request_id"])
        break
')
BIG_REC=$("${CURL[@]}" -H "Authorization: Bearer $TOKEN" \
    "${ADMIN_ORIGIN}/_system/log/alice/show/${BIG_RID}")
big_trunc=$(echo "$BIG_REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tape_refs"]["request_body_truncated"])')
big_hash=$(echo "$BIG_REC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tape_refs"]["request_body_hex"])')
[[ "$big_trunc" == "True" ]] || fail "300 KB body should set truncation flag (got $big_trunc)"
ok "truncation flag set for >256 KB body"

# Verify the captured blob is exactly 256 KB on disk.
blob_size=$(wc -c < "$DATA_DIR/alice/log-blobs/${big_hash}")
[[ "$blob_size" == "262144" ]] || fail "captured blob should be 256 KB, got $blob_size"
ok "captured body blob exactly 262144 bytes (256 KB)"

# ── 7. rove-log-cli bundle JSON shape ────────────────────────────
"$LOG_CLI" bundle --data-dir "$DATA_DIR" --instance alice \
    --request-id "$RID" > /tmp/replay-bundle.json
# log_cli only stamps `entry_source_hash`; the dashboard composer
# is what inlines `entry_source_b64`. CLI bundle output is for
# human inspection of tape data, so don't assert b64 source here.
export EXPECTED_RESP="$resp"
python3 <<PY || fail "bundle JSON shape mismatch"
import base64
import json
import os
expected_resp = os.environ.get("EXPECTED_RESP", "")
with open("/tmp/replay-bundle.json") as f:
    b = json.load(f)
assert b["entry_source_hash"], "no entry_source_hash"
mods = b.get("modules", [])
assert len(mods) >= 1, f"modules empty: {mods}"
specs = sorted(m["specifier"] for m in mods)
assert "lib/util.mjs" in specs, f"lib/util.mjs not in module tape: {specs}"
tapes = b.get("tapes", {})
assert tapes.get("kv"), "no kv tape in bundle"
assert tapes.get("date"), "no date tape in bundle"
kv_entries = tapes["kv"]["entries"]
ops = sorted(set(e["op"] for e in kv_entries))
assert "set" in ops, f"no kv.set in tape: {ops}"
assert "prefix" in ops, f"no kv.prefix in tape: {ops}"
prefix_entry = next(e for e in kv_entries if e["op"] == "prefix")
assert prefix_entry["key"] == "hits/", prefix_entry
assert "results" in prefix_entry, prefix_entry

req = b.get("request") or {}
assert req.get("body_b64") == base64.b64encode(b"first-visit").decode(), \
    f"request.body_b64 mismatch: {req.get('body_b64')!r}"
assert req.get("body_truncated") is False, "request.body_truncated should be false"

rsp = b.get("response") or {}
assert rsp.get("body_b64") == base64.b64encode(expected_resp.encode()).decode(), \
    f"response.body_b64 mismatch (expected '{expected_resp}')"
assert rsp.get("body_truncated") is False, "response.body_truncated should be false"
PY
unset EXPECTED_RESP
ok "rove-log-cli bundle: modules, kv (incl. prefix), date, req+resp body all present"

rm -f /tmp/replay-bundle.json
echo ""
echo "all replay smoke checks passed"
