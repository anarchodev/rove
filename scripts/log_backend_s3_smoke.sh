#!/usr/bin/env bash
# Phase 5.5 (a) end-to-end smoke against real S3.
#
#   1. Spawn loop46 with `--log-backend s3` (worker writes
#      ndjson + sidecar to the bucket via S3BatchStore).
#   2. Spawn the standalone log-server pointing at the SAME bucket
#      (indexer polls + h2 query API serves).
#   3. Drive a few requests against acme.
#   4. Wait for the worker to flush and the indexer to pick up.
#   5. Query /v1/acme/list + /show, verify the worker-emitted
#      records round-trip via the indexer + range-read.
#
# Cross-validates the worker's flush_writer + the indexer + S3
# transport with one fixture; either side diverging breaks the
# smoke.
#
# Required env (or sourced from `.env`):
#   AWS_ACCESS_KEY_ID
#   AWS_SECRET_ACCESS_KEY
#   S3_BUCKET
#   S3_ENDPOINT          (hostname only, no scheme — strips leniently)
#   S3_REGION
#
# Each run picks a unique LOG_S3_KEY_PREFIX so concurrent runs +
# leftover objects from prior runs don't collide. The smoke does
# NOT clean up after itself — operators / OVH lifecycle policies
# handle the eventual sweep.

set -euo pipefail

if [[ -f .env ]]; then
    set -a
    # shellcheck source=/dev/null
    source .env
    set +a
fi

DATA_DIR="${DATA_DIR:-/tmp/rove-logbackend-smoke}"
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

# Required env checks.
need_env() {
    if [[ -z "${!1:-}" ]]; then
        echo "error: $1 not set (and not in .env)" >&2
        exit 2
    fi
}
need_env AWS_ACCESS_KEY_ID
need_env AWS_SECRET_ACCESS_KEY
need_env S3_BUCKET
need_env S3_ENDPOINT
need_env S3_REGION

if [[ ! -f "$TLS_CERT" || ! -f "$TLS_KEY" ]]; then
    echo "error: missing dev TLS at $LOOP46_DATA. Run 'loop46 dev ...' once." >&2
    exit 2
fi
if [[ ! -x "$BIN" || ! -x "$LS_BIN" ]]; then
    echo "error: $BIN or $LS_BIN missing — run 'zig build install' first" >&2
    exit 2
fi

# Unique prefix for this run — keeps concurrent runs from colliding
# in the shared bucket and makes leftover objects easy to identify
# (`smoke/{unix_ms}-{rand}/`).
RAND=$(head -c4 /dev/urandom | xxd -p)
SMOKE_PREFIX="smoke/$(date +%s%N | cut -c1-13)-${RAND}/"
export LOG_S3_KEY_PREFIX="$SMOKE_PREFIX"

INDEX_DB="/tmp/rove-logbackend-index-${RAND}.db"
rm -f "$INDEX_DB" "${INDEX_DB}-shm" "${INDEX_DB}-wal"

rm -rf "$DATA_DIR"

# Pre-create acme via seed.
"$BIN" seed \
    --data-dir "$DATA_DIR" \
    --manifest examples/loop46-demo-tenants.json >/tmp/lbs-seed.out 2>&1 \
    || { cat /tmp/lbs-seed.out >&2; exit 2; }

# ── Spawn worker with --log-backend s3 ─────────────────────────────
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

# ── Spawn log-server pointing at the SAME bucket+prefix ───────────
"$LS_BIN" \
    --index-db "$INDEX_DB" \
    --listen 127.0.0.1:${LS_PORT} \
    --poll-interval-ms 500 \
    >/tmp/lbs-server.out 2>&1 &
LS_PID=$!

cleanup() {
    kill $WORKER_PID $LS_PID 2>/dev/null || true
    wait $WORKER_PID $LS_PID 2>/dev/null || true
    rm -f "$INDEX_DB" "${INDEX_DB}-shm" "${INDEX_DB}-wal"
}
trap cleanup EXIT

# Wait for both to be ready.
sleep 1.5

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
echo "ok  worker started with --log-backend s3 → bucket=${S3_BUCKET} prefix=${SMOKE_PREFIX}"

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    echo "--- worker log (tail 40) ---" >&2
    tail -40 /tmp/lbs-worker.out >&2 || true
    echo "--- log-server log (tail 40) ---" >&2
    tail -40 /tmp/lbs-server.out >&2 || true
    exit 1
}

RESOLVE=(--resolve "${ACME_HOST}:${PORT}:127.0.0.1")
WORKER_CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")
LS_CURL=(curl -sS --http2-prior-knowledge --max-time 10)

# ── Drive 3 requests against acme's /api handler ──────────────────
for n in 1 2 3; do
    code=$("${WORKER_CURL[@]}" -o /dev/null -w '%{http_code}' "${ACME_ORIGIN}/api?fn=handler")
    [[ "$code" == "200" ]] || fail "request $n got $code (want 200)"
done
ok "drove 3 acme requests, all 200"

# ── Wait for ALL 3 records to surface in the indexer via S3 ────────
#
# Worker `flushLogs` fires when shouldFlush() returns true; relevant
# threshold is `flush_interval_ns = 1s`. Indexer polls every 500ms.
# S3 round-trip + propagation adds a few hundred ms — generous
# ceiling of 30s.
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
    sleep 0.5
done

echo "$LIST" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
records = d["records"]
api_records = [r for r in records if r["path"].startswith("/api")]
assert len(api_records) >= 3, f"want >=3 /api records, got {len(api_records)}: {records}"
for r in api_records[:3]:
    assert r["method"] == "GET", f"unexpected method: {r}"
    assert r["host"] == "acme.loop46.localhost", f"unexpected host: {r}"
    assert r["status"] == 200, f"unexpected status: {r}"
    assert r["outcome"] == "ok", f"unexpected outcome: {r}"
' || fail "log-server /list didn't return the worker's records"
ok "worker → S3 → indexer → /list shows all 3 acme records"

# ── /show round-trips one record via S3 range-read ────────────────
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
ok "show: S3 range-read returned the worker-emitted record"

echo ""
echo "all log-backend=s3 smoke checks passed"
echo "(left ~6 objects under s3://${S3_BUCKET}/${SMOKE_PREFIX} — operator/OVH lifecycle handles cleanup)"
