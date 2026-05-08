#!/usr/bin/env bash
# Run the cluster bench under perf and emit a flame graph + top-self
# table. Workload is the sharded shape (8 tenants in parallel) since
# that saturates the leader. Profile attaches to the leader worker
# process for a fixed window mid-load.
#
# Args (all optional):
#   $1 requests_per_tenant (default 50000)
#   $2 clients              (default 10)
#   $3 streams              (default 10)
#   $4 perf_window_secs     (default 8)
#
# Outputs land in $HOME/bench/:
#   perf.data          raw perf record output
#   top_self.txt       perf report --no-children (self time, hot funcs)
#   call_tree.txt      perf report --children (cumulative attribution)
#   flame.svg          flame graph (if FlameGraph repo is available)

set -euo pipefail

if [[ -f .env ]]; then
    set -a
    # shellcheck source=/dev/null
    source .env
    set +a
fi

REQUESTS="${1:-50000}"
CLIENTS="${2:-10}"
STREAMS="${3:-10}"
PERF_SECS="${4:-8}"

OUT_DIR="${OUT_DIR:-$HOME/bench}"
mkdir -p "$OUT_DIR"

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-kv-bench-prof}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8285}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40385}"
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

[[ -x "$BIN" ]] || { echo "$BIN missing — run zig build install -Doptimize=ReleaseFast"; exit 2; }
[[ -f "$TLS_CERT" ]] || { echo "missing dev TLS at $LOOP46_DATA"; exit 2; }
command -v perf >/dev/null || { echo "perf not in PATH"; exit 2; }

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=kv-bench-prof
SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

export S3_KEY_PREFIX_BASE="${S3_KEY_PREFIX_BASE:-bench-prof-$(hostname)-$(id -u)-$(date +%s)/}"
export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"
export LOOP46_ROOT_TOKEN="$TOKEN"
export LOOP46_DISABLE_TAPE_CAPTURE=1

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
    for p in "${PIDS[@]}" "${CS_PID:-}" "${LOAD_PIDS[@]:-}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
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
LEADER_PID="${PIDS[$LEADER_IDX]}"
echo "leader: pid=$LEADER_PID node=$LEADER_IDX port=$LEADER_PORT"

# Warm: drive a quick round through every bench tenant so JS contexts
# are ready and tenant_logs / tenant_files are open.
for t in hot spread write0 write1 write2 write3 write4 write5 write6 write7; do
    "${CURL[@]}" --connect-to "$t.${PUBLIC_SUFFIX}:${LEADER_PORT}:127.0.0.1:${LEADER_PORT}" \
        -o /dev/null "https://$t.${PUBLIC_SUFFIX}:${LEADER_PORT}/?fn=handler" 2>/dev/null || true
done

H2LOAD=(h2load --connect-to "127.0.0.1:${LEADER_PORT}")

echo "kicking off load on 8 tenants (${REQUESTS} req each)…"
LOAD_PIDS=()
for i in 0 1 2 3 4 5 6 7; do
    "${H2LOAD[@]}" -n "$REQUESTS" -c "$CLIENTS" -m "$STREAMS" \
        "https://write${i}.${PUBLIC_SUFFIX}:${LEADER_PORT}/?fn=handler" \
        > "$OUT_DIR/load_${i}.log" 2>&1 &
    LOAD_PIDS+=($!)
done

# Give the load a moment to ramp up before sampling.
sleep 1

echo "perf record -F 999 -g --call-graph dwarf -p $LEADER_PID -- sleep $PERF_SECS"
perf record -F 999 -g --call-graph dwarf -p "$LEADER_PID" \
    -o "$OUT_DIR/perf.data" -- sleep "$PERF_SECS"

# Wait for h2load to finish so we get the bench summary too.
for p in "${LOAD_PIDS[@]}"; do wait "$p" 2>/dev/null || true; done

extract_rps() {
    awk '/finished in/ { for (i=1;i<=NF;i++) if ($i ~ /req\/s/) print $(i-1); exit }'
}

total=0
echo ""
echo "── shard throughput (during profile window + tail) ──"
for i in 0 1 2 3 4 5 6 7; do
    rps=$(extract_rps < "$OUT_DIR/load_${i}.log")
    rps_i=${rps%.*}
    [[ -n "$rps_i" ]] || rps_i=0
    total=$((total + rps_i))
    echo "  write${i}: $rps req/s"
done
echo "  total:   $total req/s"

echo ""
echo "── perf report (top self time, ≥0.5%) → $OUT_DIR/top_self.txt ──"
perf report -i "$OUT_DIR/perf.data" --stdio --no-children --percent-limit 0.5 \
    > "$OUT_DIR/top_self.txt" 2>/dev/null
head -40 "$OUT_DIR/top_self.txt"

echo ""
echo "── perf report (cumulative tree, ≥2%) → $OUT_DIR/call_tree.txt ──"
perf report -i "$OUT_DIR/perf.data" --stdio --percent-limit 2.0 \
    > "$OUT_DIR/call_tree.txt" 2>/dev/null
head -30 "$OUT_DIR/call_tree.txt"

# Flame graph if FlameGraph clone is reachable.
FG_DIR="${FG_DIR:-/tmp/FlameGraph}"
if [[ ! -d "$FG_DIR" ]]; then
    git clone --depth 1 https://github.com/brendangregg/FlameGraph "$FG_DIR" 2>/dev/null || true
fi
if [[ -x "$FG_DIR/stackcollapse-perf.pl" && -x "$FG_DIR/flamegraph.pl" ]]; then
    perf script -i "$OUT_DIR/perf.data" 2>/dev/null \
        | "$FG_DIR/stackcollapse-perf.pl" \
        | "$FG_DIR/flamegraph.pl" > "$OUT_DIR/flame.svg"
    echo ""
    echo "flame graph: $OUT_DIR/flame.svg"
else
    echo "FlameGraph not available; skipping flame.svg"
fi
