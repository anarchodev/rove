#!/usr/bin/env bash
# kv_shim_overhead_bench.sh — measure the per-op cost of the proposed
# `globals/*.js -> _system.*` shim model WITHOUT doing the refactor.
#
# Two tenants run a byte-identical read-only kv.get loop:
#   kvdirect.rewindjsapp.localhost — native kv.get called directly
#   kvshim.rewindjsapp.localhost   — same loop through a one-JS-frame
#                                    _system->globals wrapper
#
# Read-only by design: reads skip raft + WAL fsync, so the extra JS
# frame is the largest possible fraction of per-op cost. If the delta
# is negligible here, it's negligible everywhere; if it's significant,
# that's the signal to dual-expose hot primitives.
#
# Cluster bring-up is copied verbatim from kv_bench_cluster.sh so the
# canonical bench scripts stay untouched.
#
# Args (optional):  $1 requests (default 40000)  $2 clients (10)  $3 streams (10)  $4 trials (3)

set -euo pipefail

if [[ -f .env ]]; then set -a; source .env; set +a; fi

REQUESTS="${1:-40000}"
CLIENTS="${2:-10}"
STREAMS="${3:-10}"
TRIALS="${4:-3}"
WORKERS="${WORKERS:-4}"

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-kv-shim-bench}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8285}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40385}"
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

[[ -f "$TLS_CERT" && -f "$TLS_KEY" ]] || { echo "missing dev TLS at $LOOP46_DATA — run 'loop46 dev' once" >&2; exit 2; }
[[ -x "$BIN" ]] || { echo "$BIN missing — run zig build install -Doptimize=ReleaseFast" >&2; exit 2; }

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=kv-shim-bench
SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

export S3_KEY_PREFIX_BASE="${S3_KEY_PREFIX_BASE:-bench-shim-$(hostname)-$(id -u)-$(date +%s)/}"
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
        --snapshot-interval-ms 1000 \
        "${RAFT_TIMING_FLAGS[@]}" \
        >"/tmp/${SMOKE_TAG}-worker-${i}.out" 2>&1 &
    PIDS+=($!)
done
trap '
    for p in "${PIDS[@]}" "${CS_PID:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
    for p in "${PIDS[@]}" "${CS_PID:-}"; do [ -n "$p" ] && wait "$p" 2>/dev/null || true; done
' EXIT
sleep 2

RESOLVE=()
for h in "${HTTP_ADDRS[@]}"; do p="${h##*:}"; RESOLVE+=(--resolve "${ADMIN_HOST}:${p}:127.0.0.1"); done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")

discover_leader "$ADMIN_HOST" "$TOKEN" || exit 1
echo "leader: node $LEADER_IDX at $LEADER_HTTP"

# No files-server: tenants are seeded directly into app.db + S3 by
# seed_all_dirs, so deployments are already live. The files-server is
# only needed for runtime admin/replay deploys, which this read-only
# bench never does.

for host in kvdirect kvshim; do
    for _ in $(seq 1 30); do
        code=$("${CURL[@]}" --connect-to "${host}.rewindjsapp.localhost:${LEADER_PORT}:127.0.0.1:${LEADER_PORT}" \
            -o /dev/null -w '%{http_code}' "https://${host}.rewindjsapp.localhost:${LEADER_PORT}/?fn=handler" || echo 000)
        [[ "$code" == "200" ]] && break
        sleep 0.2
    done
    [[ "$code" == "200" ]] || { echo "FAIL: ${host} never returned 200 (got $code)"; exit 1; }
    echo "${host}.rewindjsapp.localhost ready (HTTP $code)"
done

H2LOAD=(h2load --connect-to "127.0.0.1:${LEADER_PORT}")
extract_rps() { awk '/finished in/ { for (i=1;i<=NF;i++) if ($i ~ /req\/s/) print $(i-1); exit }'; }

RAW_DIR=$(mktemp -d -t rove-shim-raw-XXXXXX)
run_arm() {
    local host="$1" f="$RAW_DIR/${1}.txt"
    "${H2LOAD[@]}" -n "$REQUESTS" -c "$CLIENTS" -m "$STREAMS" \
        "https://${host}.rewindjsapp.localhost:${LEADER_PORT}/?fn=handler" >"$f" 2>&1
    extract_rps < "$f"
}

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " kv shim-overhead benchmark — read-only, 200 kv.get/request"
echo " requests=$REQUESTS clients=$CLIENTS streams=$STREAMS trials=$TRIALS"
echo "═══════════════════════════════════════════════════════════════"

# Warm up both arms (open conns, JIT, page cache).
run_arm kvdirect >/dev/null; run_arm kvshim >/dev/null

direct_sum=0; shim_sum=0
for t in $(seq 1 "$TRIALS"); do
    d=$(run_arm kvdirect); s=$(run_arm kvshim)   # alternate to share noise
    di=${d%.*}; si=${s%.*}
    printf "  trial %d:  direct=%-10s shim=%-10s\n" "$t" "$d" "$s"
    direct_sum=$((direct_sum + ${di:-0})); shim_sum=$((shim_sum + ${si:-0}))
done

dmean=$((direct_sum / TRIALS)); smean=$((shim_sum / TRIALS))
echo ""
echo "── mean over $TRIALS trials ──"
printf "  direct:  %d req/s\n" "$dmean"
printf "  shim:    %d req/s\n" "$smean"
awk -v d="$dmean" -v s="$smean" 'BEGIN {
    pct = (d > 0) ? (d - s) / d * 100.0 : 0;
    printf "  shim overhead: %.2f%% slower  (%d req/s)\n", pct, d - s
}'
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "── h2load result detail (last trial of each arm) ──"
for arm in kvdirect kvshim; do
    echo "[$arm]"
    grep -E "requests:|status codes:|finished in|errored|timeout" "$RAW_DIR/${arm}.txt" | sed 's/^/  /'
done
rm -rf "$RAW_DIR"
