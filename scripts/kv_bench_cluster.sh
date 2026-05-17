#!/usr/bin/env bash
# Bring up a 3-node loop46 cluster (TLS, S3 backend, raft-replicated)
# and run kv_write_bench + kv_shard_bench against it. Use after a
# `zig build install -Doptimize=ReleaseFast`.
#
# Args (all optional):
#   $1 requests_per_tenant (default 30000)
#   $2 clients              (default 10)
#   $3 streams              (default 10)
#
# h2load drives traffic via --connect-to so the URL host (e.g.
# hot.rewindjsapp.localhost) provides SNI + :authority while the TCP socket points
# at the leader's 127.0.0.1:PORT — no /etc/hosts edits needed.
# The dev cert covers *.rewindjsapp.localhost, so SNI validation passes
# against the bench tenant subdomains. (We don't use *.test even
# though the cert lists it — curl/OpenSSL refuses single-label TLD
# wildcards like `*.test` per public-suffix-list rules.)

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
WORKERS="${WORKERS:-4}"

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-kv-bench}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8265}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40365}"
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

[[ -f "$TLS_CERT" && -f "$TLS_KEY" ]] || {
    echo "missing dev TLS at $LOOP46_DATA — run 'loop46 dev' once" >&2
    exit 2
}
[[ -x "$BIN" ]] || { echo "$BIN missing — run zig build install" >&2; exit 2; }

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=kv-bench
SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

# Per-run S3 prefix so prior runs' blobs don't pollute the manifest
# keyspace (and the bench numbers).
export S3_KEY_PREFIX_BASE="${S3_KEY_PREFIX_BASE:-bench-kv-$(hostname)-$(id -u)-$(date +%s)/}"
export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"
export LOOP46_ROOT_TOKEN="$TOKEN"

# Seed bench tenants onto every node's data dir. seed_all_dirs writes
# manifest blobs to S3 + stamps `_deploy/current` in the local app.db.
seed_all_dirs ./examples/loop46-demo-tenants.json

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
        --system-suffix "$SYSTEM_SUFFIX" \
        --tls-cert "$TLS_CERT" \
        --tls-key "$TLS_KEY" \
        --workers "$WORKERS" \
        --rate-limit-request-capacity 1000000 \
        --rate-limit-request-refill 1000000 \
        --snapshot-interval-ms 1000 \
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

discover_leader "$ADMIN_HOST" "$TOKEN" || exit 1
echo "leader: node $LEADER_IDX at $LEADER_HTTP"

# No files-server: tenants are seeded directly into app.db + S3 by
# seed_all_dirs above, so deployments are already live. The
# files-server is only for runtime admin/replay deploys (never
# benchmarked here), and its bootstrap POSTs to https://127.0.0.1
# which the dev cert (no IP SAN) rejects — it would fail the whole
# run. Matches kv_read_profile.sh / kv_read_timeseries.sh.

# Verify a bench tenant is reachable before kicking off load. h2load
# floods open connections; if hot.rewindjsapp.localhost isn't dispatched yet we'd
# count startup latency in the throughput number.
for _ in $(seq 1 30); do
    code=$("${CURL[@]}" --connect-to "hot.rewindjsapp.localhost:${LEADER_PORT}:127.0.0.1:${LEADER_PORT}" \
        -o /dev/null -w '%{http_code}' "https://hot.rewindjsapp.localhost:${LEADER_PORT}/?fn=handler" || echo 000)
    [[ "$code" == "200" ]] && break
    sleep 0.2
done
[[ "$code" == "200" ]] || { echo "FAIL: hot.rewindjsapp.localhost never returned 200 (got $code)"; exit 1; }
echo "hot.rewindjsapp.localhost ready (HTTP $code)"

H2LOAD=(h2load --connect-to "127.0.0.1:${LEADER_PORT}")

extract_rps() {
    awk '/finished in/ { for (i=1;i<=NF;i++) if ($i ~ /req\/s/) print $(i-1); exit }'
}

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " kv contention benchmark"
echo " requests=$REQUESTS  clients=$CLIENTS  streams=$STREAMS"
echo " leader=https://hot.rewindjsapp.localhost:${LEADER_PORT} (via 127.0.0.1)"
echo "═══════════════════════════════════════════════════════════════"

# Warm up spread keyspace (1000-key INSERTs become REPLACEs).
echo ""
echo "── warmup: spread.rewindjsapp.localhost 1000-key keyspace ──"
"${H2LOAD[@]}" -n 5000 -c 20 -m 10 \
    "https://spread.rewindjsapp.localhost:${LEADER_PORT}/?fn=handler" 2>&1 | grep -E "finished|req/s" || true

echo ""
echo "── (1) hot.rewindjsapp.localhost — single tenant, single key 'k' ──"
hot_out=$("${H2LOAD[@]}" -n "$REQUESTS" -c "$CLIENTS" -m "$STREAMS" \
    "https://hot.rewindjsapp.localhost:${LEADER_PORT}/?fn=handler" 2>&1)
echo "$hot_out" | grep -E "finished in|req/s|status codes"
hot_rps=$(echo "$hot_out" | extract_rps)

echo ""
echo "── (2) spread.rewindjsapp.localhost — single tenant, 1000 keys, same payload ──"
spread_out=$("${H2LOAD[@]}" -n "$REQUESTS" -c "$CLIENTS" -m "$STREAMS" \
    "https://spread.rewindjsapp.localhost:${LEADER_PORT}/?fn=handler" 2>&1)
echo "$spread_out" | grep -E "finished in|req/s|status codes"
spread_rps=$(echo "$spread_out" | extract_rps)

echo ""
echo "── (3) sharded — $TENANTS tenants in parallel (write0..write$((TENANTS-1)).test) ──"
LOG_DIR=$(mktemp -d -t rove-kv-bench-XXXXXX)
PID_LIST=()
for i in $(seq 0 $((TENANTS - 1))); do
    "${H2LOAD[@]}" -n "$REQUESTS" -c "$CLIENTS" -m "$STREAMS" \
        "https://write${i}.rewindjsapp.localhost:${LEADER_PORT}/?fn=handler" \
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
    echo "  write${i}.rewindjsapp.localhost: $rps req/s"
done
rm -rf "$LOG_DIR"

echo ""
echo "═══════════════════════════════════════════════════════════════"
printf " hot     (1 tenant, 1 key):    %s req/s\n" "$hot_rps"
printf " spread  (1 tenant, 1000 k):   %s req/s\n" "$spread_rps"
printf " sharded ($TENANTS tenants, sum):     %d req/s\n" "$shard_total"
echo "═══════════════════════════════════════════════════════════════"
