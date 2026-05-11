#!/usr/bin/env bash
# Variant of kv_bench_cluster.sh that fattens the tenant pool with
# N idle tenants before running the same h2load workload against
# the same 8 sharded tenants. Tests whether per-request perf
# degrades when the cluster carries many idle tenants.
#
# Question this answers: does the dispatch / raft / SQLite hot
# path stay flat as N_total grows, with N_active held constant?
# Per CLAUDE.md: any per-tenant scan in the dispatch tick is a
# bug. This bench surfaces such bugs as a throughput cliff vs
# N_idle.
#
# Usage:
#   N_IDLE=1000 bash scripts/kv_bench_idle_tenants.sh 30000 10 10
#
# Args (positional): same as kv_bench_cluster.sh
#   $1 requests_per_tenant (default 30000)
#   $2 clients              (default 10)
#   $3 streams              (default 10)
#
# Env knobs:
#   N_IDLE=1000          extra idle tenants in the pool

set -euo pipefail

if [[ -f .env ]]; then
    set -a
    # shellcheck source=/dev/null
    source .env
    set +a
fi

REQUESTS="${1:-30000}"
CLIENTS="${2:-10}"
STREAMS="${3:-10}"
TENANTS=8
N_IDLE="${N_IDLE:-1000}"

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-kv-idlebench}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8265}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40365}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
PUBLIC_SUFFIX="loop46.localhost"
ADMIN_HOST="app.${PUBLIC_SUFFIX}"

if [[ "$(uname -s)" == "Darwin" ]]; then
    LOOP46_DATA="${LOOP46_DATA:-$HOME/Library/Application Support/loop46}"
else
    LOOP46_DATA="${LOOP46_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/loop46}"
fi
TLS_CERT="$LOOP46_DATA/dev-cert.pem"
TLS_KEY="$LOOP46_DATA/dev-key.pem"
CACERT="$LOOP46_DATA/ca-root.pem"

[[ -f "$TLS_CERT" && -f "$TLS_KEY" ]] || {
    echo "missing dev TLS at $LOOP46_DATA — run 'loop46 dev' once" >&2
    exit 2
}
[[ -x "$BIN" ]] || { echo "$BIN missing — run zig build install" >&2; exit 2; }

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=kv-idle-bench
SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

export S3_KEY_PREFIX_BASE="${S3_KEY_PREFIX_BASE:-bench-kvidle-$(hostname)-$(id -u)-$(date +%s)/}"
export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"
export LOOP46_ROOT_TOKEN="$TOKEN"

# ── Phase 0: seed the 17 active demo tenants (full bootstrap to S3) ──
seed_all_dirs ./examples/loop46-demo-tenants.json

# ── Phase 0.5: seed N_IDLE additional idle tenants (no-files-bootstrap) ──
if (( N_IDLE > 0 )); then
    IDLE_MANIFEST=$(mktemp --suffix=.json)
    trap 'rm -f "$IDLE_MANIFEST" 2>/dev/null || true' EXIT
    {
        echo -n '{"tenants":['
        for (( i = 0; i < N_IDLE; i++ )); do
            (( i > 0 )) && echo -n ','
            printf '{"id":"idle%05d","domains":[],"files":[]}' "$i"
        done
        echo ']}'
    } > "$IDLE_MANIFEST"
    echo "── seeding $N_IDLE idle tenants × ${#DATA_DIRS[@]} dirs (no-files-bootstrap) ──"
    t0=$(date +%s)
    IDLE_PIDS=()
    for d in "${DATA_DIRS[@]}"; do
        "$BIN" seed --data-dir "$d" --manifest "$IDLE_MANIFEST" \
            --no-files-bootstrap --deploy-id 0 >/dev/null &
        IDLE_PIDS+=($!)
    done
    for p in "${IDLE_PIDS[@]}"; do wait "$p"; done
    t1=$(date +%s)
    rm -f "$IDLE_MANIFEST"
    echo "  $N_IDLE idle tenants seeded in $((t1 - t0))s"
fi

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
        --workers 4 \
        --rate-limit-request-capacity 1000000 \
        --rate-limit-request-refill 1000000 \
        "${RAFT_TIMING_FLAGS[@]}" \
        >"/tmp/${SMOKE_TAG}-worker-${i}.out" 2>&1 &
    PIDS+=($!)
done
trap '
    for p in "${PIDS[@]}" "${CS_PID:-}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done
    for p in "${PIDS[@]}" "${CS_PID:-}"; do
        [ -n "$p" ] && wait "$p" 2>/dev/null || true
    done
' EXIT
sleep 2

RESOLVE=()
for h in "${HTTP_ADDRS[@]}"; do
    p="${h##*:}"
    RESOLVE+=(--resolve "${ADMIN_HOST}:${p}:127.0.0.1")
done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")

# Scale leader-discovery timeout with N_IDLE (matches snapshot bench's
# rule: workers open every tenant's app.db at boot). 30s floor + ~1s
# per 100 tenants.
N_TOTAL=$((N_IDLE + 17))
export LEADER_DISCOVER_TIMEOUT_S=$(( 30 + N_TOTAL / 100 ))
echo "leader-discovery timeout: ${LEADER_DISCOVER_TIMEOUT_S}s (scaled for $N_TOTAL tenants)"
discover_leader "$ADMIN_HOST" "$TOKEN" || exit 1
echo "leader: node $LEADER_IDX at $LEADER_HTTP"

FILES_ADDR="${FILES_ADDR:-127.0.0.1:8278}"
spawn_files_server "$FILES_ADDR" "${DATA_DIRS[$LEADER_IDX]}" /tmp/${SMOKE_TAG}-cs.out "$ADMIN_ORIGIN" "$ADMIN_ORIGIN" || exit 1

for _ in $(seq 1 30); do
    code=$("${CURL[@]}" --connect-to "hot.loop46.localhost:${LEADER_PORT}:127.0.0.1:${LEADER_PORT}" \
        -o /dev/null -w '%{http_code}' "https://hot.loop46.localhost:${LEADER_PORT}/?fn=handler" || echo 000)
    [[ "$code" == "200" ]] && break
    sleep 0.2
done
[[ "$code" == "200" ]] || { echo "FAIL: hot.loop46.localhost never returned 200 (got $code)"; exit 1; }
echo "hot.loop46.localhost ready (HTTP $code)"

H2LOAD=(h2load --connect-to "127.0.0.1:${LEADER_PORT}")

extract_rps() {
    awk '/finished in/ { for (i=1;i<=NF;i++) if ($i ~ /req\/s/) print $(i-1); exit }'
}

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " kv contention benchmark with $N_IDLE idle tenants in pool"
echo " requests=$REQUESTS  clients=$CLIENTS  streams=$STREAMS"
echo " leader=https://hot.loop46.localhost:${LEADER_PORT} (via 127.0.0.1)"
echo "═══════════════════════════════════════════════════════════════"

echo ""
echo "── warmup: spread.loop46.localhost 1000-key keyspace ──"
"${H2LOAD[@]}" -n 5000 -c 20 -m 10 \
    "https://spread.loop46.localhost:${LEADER_PORT}/?fn=handler" 2>&1 | grep -E "finished|req/s" || true

echo ""
echo "── (1) hot.loop46.localhost — single tenant, single key 'k' ──"
hot_out=$("${H2LOAD[@]}" -n "$REQUESTS" -c "$CLIENTS" -m "$STREAMS" \
    "https://hot.loop46.localhost:${LEADER_PORT}/?fn=handler" 2>&1)
echo "$hot_out" | grep -E "finished in|req/s|status codes"
hot_rps=$(echo "$hot_out" | extract_rps)

echo ""
echo "── (2) spread.loop46.localhost — single tenant, 1000 keys, same payload ──"
spread_out=$("${H2LOAD[@]}" -n "$REQUESTS" -c "$CLIENTS" -m "$STREAMS" \
    "https://spread.loop46.localhost:${LEADER_PORT}/?fn=handler" 2>&1)
echo "$spread_out" | grep -E "finished in|req/s|status codes"
spread_rps=$(echo "$spread_out" | extract_rps)

echo ""
echo "── (3) sharded — $TENANTS tenants in parallel (write0..write$((TENANTS-1)).test) ──"
LOG_DIR=$(mktemp -d -t rove-kv-idle-bench-XXXXXX)
PID_LIST=()
for i in $(seq 0 $((TENANTS - 1))); do
    "${H2LOAD[@]}" -n "$REQUESTS" -c "$CLIENTS" -m "$STREAMS" \
        "https://write${i}.loop46.localhost:${LEADER_PORT}/?fn=handler" \
        > "$LOG_DIR/w${i}.log" 2>&1 &
    PID_LIST+=($!)
done
for p in "${PID_LIST[@]}"; do wait "$p"; done
shard_total=0
for i in $(seq 0 $((TENANTS - 1))); do
    rps=$(extract_rps < "$LOG_DIR/w${i}.log")
    rps_i=${rps%.*}
    [[ -n "$rps_i" ]] || rps_i=0
    shard_total=$((shard_total + rps_i))
    echo "  write${i}.loop46.localhost: $rps req/s"
done
rm -rf "$LOG_DIR"

echo ""
echo "═══════════════════════════════════════════════════════════════"
printf " idle tenants in pool:        %s\n" "$N_IDLE"
printf " hot     (1 tenant, 1 key):    %s req/s\n" "$hot_rps"
printf " spread  (1 tenant, 1000 k):   %s req/s\n" "$spread_rps"
printf " sharded ($TENANTS tenants, sum):     %d req/s\n" "$shard_total"
echo "═══════════════════════════════════════════════════════════════"
