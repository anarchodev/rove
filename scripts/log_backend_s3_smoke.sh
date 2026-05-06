#!/usr/bin/env bash
# Phase 5.5 (a) step 3 smoke — worker `--log-backend s3` with the
# fs-backed BatchStore. Verifies the new flush path end-to-end:
#
#   1. Spawn loop46 with `--log-backend s3` + LOG_BATCH_STORE_DIR.
#   2. Drive a few requests against acme.
#   3. Wait for `flushLogs` to run and produce sidecar + ndjson on
#      disk under `{LOG_BATCH_STORE_DIR}/acme/{node}/...`.
#   4. Spawn the standalone log-server pointing at the SAME dir.
#   5. Curl `/v1/acme/list` and verify the records the worker just
#      logged are visible.
#
# Cross-validates two pieces with one fixture: the worker's
# flush_writer-built sidecar shape AND the standalone log-server's
# indexer + query API. If either side diverges the smoke catches it.

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-logbackend-smoke}"
LOG_BATCH_DIR="${LOG_BATCH_DIR:-${DATA_DIR}/log-batches}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8200}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40300}"
LS_PORT="${LS_PORT:-0}"
BIN="${BIN:-./zig-out/bin/loop46}"
LS_BIN="${LS_BIN:-./zig-out/bin/log-server-standalone}"
TOKEN="${ROVE_TOKEN:-ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff}"
ADMIN_HOST="app.loop46.localhost"
ACME_HOST="acme.loop46.localhost"
PORT="${HTTP_ADDR##*:}"
ADMIN_ORIGIN="https://${ADMIN_HOST}:${PORT}"
ACME_ORIGIN="https://${ACME_HOST}:${PORT}"

if [[ "$(uname -s)" == "Darwin" ]]; then
    LOOP46_DATA="${LOOP46_DATA:-$HOME/Library/Application Support/loop46}"
else
    LOOP46_DATA="${LOOP46_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/loop46}"
fi
TLS_CERT="$LOOP46_DATA/dev-cert.pem"
TLS_KEY="$LOOP46_DATA/dev-key.pem"
CACERT="$LOOP46_DATA/ca-root.pem"

if [[ ! -f "$TLS_CERT" || ! -f "$TLS_KEY" ]]; then
    echo "error: missing dev TLS at $LOOP46_DATA. Run 'loop46 dev ...' once." >&2
    exit 2
fi
if [[ ! -x "$BIN" || ! -x "$LS_BIN" ]]; then
    echo "error: $BIN or $LS_BIN missing — run 'zig build install' first" >&2
    exit 2
fi

rm -rf "$DATA_DIR"
mkdir -p "$LOG_BATCH_DIR"

# Pre-create acme via seed.
"$BIN" seed \
    --data-dir "$DATA_DIR" \
    --manifest examples/loop46-demo-tenants.json >/tmp/lbs-seed.out 2>&1 \
    || { cat /tmp/lbs-seed.out >&2; exit 2; }

# ── Spawn worker with --log-backend s3 ─────────────────────────────
LOG_BATCH_STORE_DIR="$LOG_BATCH_DIR" \
"$BIN" worker \
    --node-id 0 \
    --peers "$RAFT_ADDR" \
    --listen "$RAFT_ADDR" \
    --http "$HTTP_ADDR" \
    --data-dir "$DATA_DIR" \
    --bootstrap-root-token "$TOKEN" \
    --admin-origin "$ADMIN_ORIGIN" \
    --admin-api-domain "$ADMIN_HOST" \
    --public-suffix loop46.localhost \
    --tls-cert "$TLS_CERT" \
    --tls-key "$TLS_KEY" \
    --workers 1 \
    --refresh-interval-ms 100 \
    --log-backend s3 \
    >/tmp/lbs-worker.out 2>&1 &
WORKER_PID=$!

# ── Spawn log-server pointing at the same batch dir ───────────────
"$LS_BIN" \
    --batch-store-dir "$LOG_BATCH_DIR" \
    --listen 127.0.0.1:${LS_PORT} \
    --poll-interval-ms 200 \
    >/tmp/lbs-server.out 2>&1 &
LS_PID=$!

cleanup() {
    kill $WORKER_PID $LS_PID 2>/dev/null || true
    wait $WORKER_PID $LS_PID 2>/dev/null || true
}
trap cleanup EXIT

# Wait for both to be ready.
sleep 1.2

LS_BOUND_PORT=""
for _ in $(seq 1 50); do
    if grep -q '^listening on port ' /tmp/lbs-server.out 2>/dev/null; then
        LS_BOUND_PORT=$(awk '/^listening on port / {print $4; exit}' /tmp/lbs-server.out)
        break
    fi
    sleep 0.1
done
if [[ -z "$LS_BOUND_PORT" ]]; then
    echo "FAIL log-server didn't bind" >&2
    cat /tmp/lbs-server.out >&2 || true
    exit 1
fi

# Confirm worker reported s3 backend at startup.
grep -q "log backend: s3" /tmp/lbs-worker.out \
    || { echo "FAIL worker didn't report 's3' backend" >&2; tail -40 /tmp/lbs-worker.out >&2; exit 1; }
echo "ok  worker started with --log-backend s3"

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    echo "--- worker log (tail 40) ---" >&2
    tail -40 /tmp/lbs-worker.out >&2 || true
    echo "--- log-server log (tail 40) ---" >&2
    tail -40 /tmp/lbs-server.out >&2 || true
    echo "--- log batch dir contents ---" >&2
    find "$LOG_BATCH_DIR" -type f 2>/dev/null >&2 || true
    exit 1
}

RESOLVE=(--resolve "${ACME_HOST}:${PORT}:127.0.0.1")
WORKER_CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")
LS_CURL=(curl -sS --http2-prior-knowledge --max-time 5)

# ── Drive 3 requests against acme's /api handler ──────────────────
for n in 1 2 3; do
    code=$("${WORKER_CURL[@]}" -o /dev/null -w '%{http_code}' "${ACME_ORIGIN}/api?fn=handler")
    [[ "$code" == "200" ]] || fail "request $n got $code (want 200)"
done
ok "drove 3 acme requests, all 200"

# ── Wait for ALL 3 requests to surface in the indexer ─────────────
#
# `flushLogs` fires when shouldFlush() returns true; the relevant
# threshold here is `flush_interval_ns = 1s`. With 3 sequential
# requests + a single-worker setup, all three may not land in the
# same batch (request 1 triggers a flush at t=1s, requests 2-3 sit
# in the buffer for the next flush window). Poll the indexer until
# it returns >=3 records, with a generous ceiling.
LIST=""
for _ in $(seq 1 60); do
    LIST=$("${LS_CURL[@]}" -X GET "http://127.0.0.1:${LS_BOUND_PORT}/v1/acme/list?limit=100" || true)
    n=$(echo "$LIST" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(len([r for r in d.get("records", []) if r.get("path", "").startswith("/api")]))
except Exception:
    print(0)
' 2>/dev/null || echo 0)
    if [[ "$n" -ge 3 ]]; then
        break
    fi
    sleep 0.2
done

sidecar_count=$(find "$LOG_BATCH_DIR/acme" -name "*.idx.json" 2>/dev/null | wc -l)
ndjson_count=$(find "$LOG_BATCH_DIR/acme" -name "*.ndjson" 2>/dev/null | wc -l)
[[ "$sidecar_count" -ge 1 ]] || fail "no .idx.json appeared in $LOG_BATCH_DIR/acme"
[[ "$ndjson_count" -eq "$sidecar_count" ]] \
    || fail "ndjson count $ndjson_count != sidecar count $sidecar_count"
ok "worker flushed $sidecar_count batch(es) to disk ($ndjson_count payload(s))"
echo "$LIST" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
records = d["records"]
assert len(records) >= 3, f"want >=3 records, got {len(records)}: {d}"
# All three /api requests must show up — same path, same host, same method.
api_records = [r for r in records if r["path"].startswith("/api")]
assert len(api_records) >= 3, f"want >=3 /api records: {api_records}"
for r in api_records[:3]:
    assert r["method"] == "GET", f"unexpected method: {r}"
    assert r["host"] == "acme.loop46.localhost", f"unexpected host: {r}"
    assert r["status"] == 200, f"unexpected status: {r}"
    assert r["outcome"] == "ok", f"unexpected outcome: {r}"
' || fail "log-server /list didn't return the worker's records"
ok "log-server indexed the worker's batches; /list shows acme records"

# ── Spot-check /show on one record ─────────────────────────────────
FIRST_ID=$(echo "$LIST" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
api = [r for r in d["records"] if r["path"].startswith("/api")]
print(api[0]["request_id"])
')
SHOW=$("${LS_CURL[@]}" -X GET "http://127.0.0.1:${LS_BOUND_PORT}/v1/acme/show/${FIRST_ID}")
echo "$SHOW" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
r = d["record"]
assert r["status"] == 200
assert r["method"] == "GET"
assert r["path"].startswith("/api")
' || fail "show on a worker-emitted record didn't round-trip"
ok "show: range-read returned the worker-emitted record"

echo ""
echo "all log-backend=s3 smoke checks passed"
