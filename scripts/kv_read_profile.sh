#!/usr/bin/env bash
# kv_read_profile.sh — profile the read-heavy path. Drives load at the
# `kvdirect` tenant (200 kv.get/request, read-only) and attaches perf
# to the leader for a fixed window mid-load, so the per-op cost of the
# rove<->JS kv glue (key marshal / value dup / tape append / JS string)
# shows up as self-time, not buried behind raft/TLS.
#
# Also captures h2load's `status codes:` / `requests:` lines so the
# run's 2xx-ness is recorded alongside the profile.
#
# Cluster bring-up copied from kv_bench_profile.sh (canonical scripts
# untouched). No files-server: seed_all_dirs makes deployments live.
#
# Args (optional):  $1 requests (default 8000)  $2 clients (10)  $3 streams (10)  $4 perf_secs (12)

set -euo pipefail

if [[ -f .env ]]; then set -a; source .env; set +a; fi

REQUESTS="${1:-8000}"
CLIENTS="${2:-10}"
STREAMS="${3:-10}"
PERF_SECS="${4:-12}"
WORKERS="${WORKERS:-4}"
HOST_T="${HOST_T:-kvdirect}"

OUT_DIR="${OUT_DIR:-$HOME/bench}"
mkdir -p "$OUT_DIR"

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-kv-read-prof}"
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

[[ -x "$BIN" ]] || { echo "$BIN missing — run zig build install -Doptimize=ReleaseFast"; exit 2; }
[[ -f "$TLS_CERT" ]] || { echo "missing dev TLS at $LOOP46_DATA"; exit 2; }
command -v perf >/dev/null || { echo "perf not in PATH"; exit 2; }

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=kv-read-prof
SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

export S3_KEY_PREFIX_BASE="${S3_KEY_PREFIX_BASE:-bench-readprof-$(hostname)-$(id -u)-$(date +%s)/}"
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
trap '
    for p in "${PIDS[@]}" "${LOAD_PID:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
' EXIT
sleep 2

RESOLVE=()
for h in "${HTTP_ADDRS[@]}"; do p="${h##*:}"; RESOLVE+=(--resolve "${ADMIN_HOST}:${p}:127.0.0.1"); done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")
discover_leader "$ADMIN_HOST" "$TOKEN" || exit 1
LEADER_PID="${PIDS[$LEADER_IDX]}"
echo "leader: pid=$LEADER_PID node=$LEADER_IDX port=$LEADER_PORT"

# Warm the target tenant's JS context + open its files/logs.
for _ in $(seq 1 30); do
    code=$("${CURL[@]}" --connect-to "${HOST_T}.${PUBLIC_SUFFIX}:${LEADER_PORT}:127.0.0.1:${LEADER_PORT}" \
        -o /dev/null -w '%{http_code}' "https://${HOST_T}.${PUBLIC_SUFFIX}:${LEADER_PORT}/?fn=handler" || echo 000)
    [[ "$code" == "200" ]] && break
    sleep 0.2
done
[[ "$code" == "200" ]] || { echo "FAIL: ${HOST_T} not ready (got $code)"; exit 1; }
echo "${HOST_T}.${PUBLIC_SUFFIX} ready (HTTP $code)"

echo "kicking off read load: ${REQUESTS} req on ${HOST_T} (200 kv.get each)…"
h2load --connect-to "127.0.0.1:${LEADER_PORT}" -n "$REQUESTS" -c "$CLIENTS" -m "$STREAMS" \
    "https://${HOST_T}.${PUBLIC_SUFFIX}:${LEADER_PORT}/?fn=handler" \
    > "$OUT_DIR/load_read.log" 2>&1 &
LOAD_PID=$!

sleep 1   # let load ramp before sampling
echo "perf record -F 999 -g --call-graph dwarf -p $LEADER_PID -- sleep $PERF_SECS"
perf record -F 999 -g --call-graph dwarf -p "$LEADER_PID" \
    -o "$OUT_DIR/perf.data" -- sleep "$PERF_SECS"

wait "$LOAD_PID" 2>/dev/null || true

echo ""
echo "── h2load result (kvdirect, ${REQUESTS} req × 200 kv.get) ──"
grep -E "requests:|status codes:|finished in|errored|timeout" "$OUT_DIR/load_read.log" | sed 's/^/  /'

echo ""
echo "── perf: top self time (≥0.5%) → $OUT_DIR/top_self.txt ──"
perf report -i "$OUT_DIR/perf.data" --stdio --no-children --percent-limit 0.5 \
    > "$OUT_DIR/top_self.txt" 2>/dev/null
head -45 "$OUT_DIR/top_self.txt"

echo ""
echo "── perf: cumulative tree (≥2%) → $OUT_DIR/call_tree.txt ──"
perf report -i "$OUT_DIR/perf.data" --stdio --percent-limit 2.0 \
    > "$OUT_DIR/call_tree.txt" 2>/dev/null
head -35 "$OUT_DIR/call_tree.txt"
