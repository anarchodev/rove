#!/usr/bin/env bash
# kv_read_timeseries.sh — answer "does the read path degrade over a
# sustained run?". One long h2load run against `kvdirect` with
# --log-file (per-request: start_us \t status \t duration_us), bucketed
# into 1s bins → req/s and mean/p99 latency vs elapsed seconds. One set
# of connections, no per-invocation reconnect confound.
#
# Flat req/s ≈ steady ceiling. Ramp-down from a high start = a
# depleting resource (batch-read-view long-reader hypothesis).
#
# Cluster bring-up copied from kv_read_profile.sh (no perf).
#
# Args (optional):  $1 requests (default 200000)  $2 clients (10)  $3 streams (10)

set -euo pipefail

if [[ -f .env ]]; then set -a; source .env; set +a; fi

REQUESTS="${1:-200000}"
CLIENTS="${2:-10}"
STREAMS="${3:-10}"
WORKERS="${WORKERS:-4}"
HOST_T="${HOST_T:-kvdirect}"

OUT_DIR="${OUT_DIR:-$HOME/bench}"
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/h2_timeseries.log"

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-kv-ts}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8295}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40395}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
PUBLIC_SUFFIX="rewindjsapp.localhost"
SYSTEM_SUFFIX="rewindjscom.localhost"
ADMIN_HOST="app.${PUBLIC_SUFFIX}"

if [[ "$(uname -s)" == "Darwin" ]]; then
    LOOP46_DATA="${LOOP46_DATA:-$HOME/Library/Application Support/loop46}"
else
    LOOP46_DATA="${LOOP46_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/loop46}"
fi
TLS_CERT="$LOOP46_DATA/dev-cert.pem"
TLS_KEY="$LOOP46_DATA/dev-key.pem"
CACERT="$LOOP46_DATA/ca-root.pem"

[[ -x "$BIN" ]] || { echo "$BIN missing — zig build install -Doptimize=ReleaseFast"; exit 2; }
[[ -f "$TLS_CERT" ]] || { echo "missing dev TLS at $LOOP46_DATA"; exit 2; }

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=kv-ts
SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

export S3_KEY_PREFIX_BASE="${S3_KEY_PREFIX_BASE:-bench-ts-$(hostname)-$(id -u)-$(date +%s)/}"
export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"
export LOOP46_ROOT_TOKEN="$TOKEN"

seed_all_dirs ./examples/loop46-demo-tenants.json

PIDS=()
for i in 0 1 2; do
    P="${HTTP_ADDRS[$i]##*:}"
    "$BIN" worker \
        --node-id "$i" --peers "$PEERS_CSV" \
        --listen "${RAFT_ADDRS[$i]}" --http "${HTTP_ADDRS[$i]}" \
        --data-dir "${DATA_DIRS[$i]}" \
        --admin-origin "https://${ADMIN_HOST}:${P}" --admin-api-domain "$ADMIN_HOST" \
        --public-suffix "$PUBLIC_SUFFIX" --system-suffix "$SYSTEM_SUFFIX" \
        --tls-cert "$TLS_CERT" --tls-key "$TLS_KEY" \
        --workers "$WORKERS" \
        --rate-limit-request-capacity 1000000 --rate-limit-request-refill 1000000 \
        "${RAFT_TIMING_FLAGS[@]}" \
        >"/tmp/${SMOKE_TAG}-worker-${i}.out" 2>&1 &
    PIDS+=($!)
done
trap 'for p in "${PIDS[@]}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done' EXIT
sleep 2

RESOLVE=()
for h in "${HTTP_ADDRS[@]}"; do p="${h##*:}"; RESOLVE+=(--resolve "${ADMIN_HOST}:${p}:127.0.0.1"); done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")
discover_leader "$ADMIN_HOST" "$TOKEN" || exit 1
echo "leader: node $LEADER_IDX port $LEADER_PORT"

for _ in $(seq 1 30); do
    code=$("${CURL[@]}" --connect-to "${HOST_T}.${PUBLIC_SUFFIX}:${LEADER_PORT}:127.0.0.1:${LEADER_PORT}" \
        -o /dev/null -w '%{http_code}' "https://${HOST_T}.${PUBLIC_SUFFIX}:${LEADER_PORT}/?fn=handler" || echo 000)
    [[ "$code" == "200" ]] && break
    sleep 0.2
done
[[ "$code" == "200" ]] || { echo "FAIL: ${HOST_T} not ready ($code)"; exit 1; }
echo "${HOST_T} ready; sustained run: ${REQUESTS} req (200 kv.get each)…"

rm -f "$LOG"
h2load --connect-to "127.0.0.1:${LEADER_PORT}" -n "$REQUESTS" -c "$CLIENTS" -m "$STREAMS" \
    --log-file="$LOG" \
    "https://${HOST_T}.${PUBLIC_SUFFIX}:${LEADER_PORT}/?fn=handler" 2>&1 \
    | grep -E "finished in|status codes|requests:"

echo ""
echo "── req/s + latency by elapsed second (from $LOG) ──"
echo "  sec   req/s   mean_ms   max_ms"
awk -F'\t' '
  $1 ~ /^[0-9]+$/ {
    if (t0=="") t0=$1;
    b=int(($1-t0)/1000000);
    if (b>maxb) maxb=b;
    n[b]++; sum[b]+=$3; if ($3>mx[b]) mx[b]=$3;
  }
  END {
    for (b=0; b<=maxb; b++) {
      if (!(b in n)) { printf "  %3d  %6d\n", b, 0; continue }
      printf "  %3d  %6d   %7.1f   %7.1f\n", b, n[b], (sum[b]/n[b])/1000.0, mx[b]/1000.0;
    }
  }' "$LOG"
