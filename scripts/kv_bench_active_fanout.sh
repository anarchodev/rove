#!/usr/bin/env bash
# Sharded-write bench that scales the number of *active* write
# tenants under load. Complements `kv_bench_idle_tenants.sh`
# (which fattens the pool with idle tenants). This one drives
# traffic across N parallel tenants so we surface contention or
# fan-out cost that scales with concurrent active tenants.
#
# Each active tenant runs the `write/index.mjs` handler (same as
# write0..write7 in the demo manifest). Bytecode is content-
# addressed so all N tenants share one blob hash; per-tenant
# overhead is one compile + one S3 manifest PUT at seed, one
# SQLite app.db at runtime.
#
# Total in-flight target ≈ 1024 streams (matches the saturation
# point of the c=10 m=10 × 8 baseline). Per-tenant c×m drops
# as N_ACTIVE grows so we don't over-subscribe the loadgen side.
#
# Usage:
#   N_ACTIVE=64 bash scripts/kv_bench_active_fanout.sh
#   N_ACTIVE=128 N_IDLE=10000 bash scripts/kv_bench_active_fanout.sh
#
# Env knobs:
#   N_ACTIVE=64          parallel write tenants under load
#   N_IDLE=0             extra idle tenants in the pool
#   PER_REQUESTS=5000    h2load -n per active tenant
#   TARGET_INFLIGHT=1024 aggregate in-flight streams; per-tenant
#                        c×m derived from this

set -euo pipefail

if [[ -f .env ]]; then
    set -a
    # shellcheck source=/dev/null
    source .env
    set +a
fi

N_ACTIVE="${N_ACTIVE:-64}"
N_IDLE="${N_IDLE:-0}"
PER_REQUESTS="${PER_REQUESTS:-5000}"
TARGET_INFLIGHT="${TARGET_INFLIGHT:-1024}"

# Derive per-tenant c × m so c*m*N_ACTIVE ≈ TARGET_INFLIGHT, with
# m at least 2 and c at least 1. Picks m = sqrt(per_tenant) when
# per_tenant ≥ 4; otherwise (m=2, c=1).
per_tenant=$(( TARGET_INFLIGHT / N_ACTIVE ))
(( per_tenant < 2 )) && per_tenant=2
# Simple split: c = ceil(sqrt), m = per_tenant / c
PT_M=2
PT_C=$(( per_tenant / PT_M ))
(( PT_C < 1 )) && PT_C=1
if (( per_tenant >= 16 )); then
    PT_M=4; PT_C=$(( per_tenant / 4 ))
fi
if (( per_tenant >= 64 )); then
    PT_M=8; PT_C=$(( per_tenant / 8 ))
fi

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-kv-fanout}"
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
SMOKE_TAG=kv-fanout
SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

export S3_KEY_PREFIX_BASE="${S3_KEY_PREFIX_BASE:-bench-fanout-$(hostname)-$(id -u)-$(date +%s)/}"
export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"
export LOOP46_ROOT_TOKEN="$TOKEN"

# ── Phase 0: seed the 17 active demo tenants (provides hot/spread
# tenants + admin/replay infrastructure) ──
seed_all_dirs ./examples/loop46-demo-tenants.json

# ── Phase 0.5: generate + seed N_ACTIVE additional write tenants ──
#
# All point at the same write/index.mjs. Bytecode is content-
# addressed → one shared blob hash (S3 will see N PUTs of
# identical bytes but it's an idempotent overwrite per tenant
# prefix).
FANOUT_MANIFEST=$(mktemp --suffix=.json)
trap 'rm -f "$FANOUT_MANIFEST" "${IDLE_MANIFEST:-}" 2>/dev/null || true' EXIT

# Manifest dir = repo root; source paths are relative to manifest dir
# so we use the same form as `examples/loop46-demo-tenants.json`.
{
    echo -n '{"tenants":['
    for (( i = 0; i < N_ACTIVE; i++ )); do
        (( i > 0 )) && echo -n ','
        printf '{"id":"fan%05d","domains":["fan%05d.loop46.localhost"],"files":[{"path":"index.mjs","source":"loop46-demo-tenants/write/index.mjs"}]}' "$i" "$i"
    done
    echo ']}'
} > "$FANOUT_MANIFEST"
# Locate it under examples/ so the manifest_dir resolves the
# relative source path correctly.
cp "$FANOUT_MANIFEST" examples/.fanout_manifest.json
trap 'rm -f examples/.fanout_manifest.json "${IDLE_MANIFEST:-}" 2>/dev/null || true' EXIT
echo "── seeding $N_ACTIVE active write tenants (full bootstrap, content-addressed bytecode) ──"
t0=$(date +%s)
for d in "${DATA_DIRS[@]}"; do
    "$BIN" seed --data-dir "$d" --manifest examples/.fanout_manifest.json >/dev/null
done
t1=$(date +%s)
echo "  $N_ACTIVE active write tenants × ${#DATA_DIRS[@]} dirs seeded in $((t1 - t0))s"

# ── Phase 0.6: seed N_IDLE idle tenants ──
if (( N_IDLE > 0 )); then
    IDLE_MANIFEST=$(mktemp --suffix=.json)
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
        --workers "${WORKERS:-4}" \
        --rate-limit-request-capacity 1000000 \
        --rate-limit-request-refill 1000000 \
        "${RAFT_TIMING_FLAGS[@]}" \
        >"/tmp/${SMOKE_TAG}-worker-${i}.out" 2>&1 &
    PIDS+=($!)
done
trap '
    rm -f examples/.fanout_manifest.json "${IDLE_MANIFEST:-}" 2>/dev/null || true
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

N_TOTAL=$(( N_ACTIVE + N_IDLE + 17 ))
export LEADER_DISCOVER_TIMEOUT_S=$(( 30 + N_TOTAL / 100 ))
echo "leader-discovery timeout: ${LEADER_DISCOVER_TIMEOUT_S}s (scaled for $N_TOTAL tenants)"
discover_leader "$ADMIN_HOST" "$TOKEN" || exit 1
echo "leader: node $LEADER_IDX at $LEADER_HTTP"

FILES_ADDR="${FILES_ADDR:-127.0.0.1:8278}"
spawn_files_server "$FILES_ADDR" "${DATA_DIRS[$LEADER_IDX]}" /tmp/${SMOKE_TAG}-cs.out "$ADMIN_ORIGIN" "$ADMIN_ORIGIN" || exit 1

# Verify tenant 0 responds before kicking off the load.
for _ in $(seq 1 30); do
    code=$("${CURL[@]}" --connect-to "fan00000.loop46.localhost:${LEADER_PORT}:127.0.0.1:${LEADER_PORT}" \
        -o /dev/null -w '%{http_code}' "https://fan00000.loop46.localhost:${LEADER_PORT}/?fn=handler" || echo 000)
    [[ "$code" == "200" ]] && break
    sleep 0.2
done
[[ "$code" == "200" ]] || { echo "FAIL: fan00000.loop46.localhost never returned 200 (got $code)"; exit 1; }
echo "fan00000.loop46.localhost ready (HTTP $code)"

H2LOAD=(h2load --connect-to "127.0.0.1:${LEADER_PORT}")

extract_rps() {
    awk '/finished in/ { for (i=1;i<=NF;i++) if ($i ~ /req\/s/) print $(i-1); exit }'
}

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " kv active-fanout bench"
echo " N_ACTIVE=$N_ACTIVE  N_IDLE=$N_IDLE  N_TOTAL=$N_TOTAL"
echo " per-tenant c=$PT_C  m=$PT_M  (target in-flight ≈ $TARGET_INFLIGHT)"
echo " requests per tenant: $PER_REQUESTS  (total ≈ $((PER_REQUESTS * N_ACTIVE)))"
echo "═══════════════════════════════════════════════════════════════"

LOG_DIR=$(mktemp -d -t rove-kv-fanout-XXXXXX)
PID_LIST=()
t_start=$(date +%s.%N)
for i in $(seq 0 $((N_ACTIVE - 1))); do
    tid=$(printf "fan%05d" "$i")
    "${H2LOAD[@]}" -n "$PER_REQUESTS" -c "$PT_C" -m "$PT_M" \
        "https://${tid}.loop46.localhost:${LEADER_PORT}/?fn=handler" \
        > "$LOG_DIR/${tid}.log" 2>&1 &
    PID_LIST+=($!)
done
for p in "${PID_LIST[@]}"; do wait "$p"; done
t_end=$(date +%s.%N)

shard_total=0
ok_count=0
fail_count=0
slowest=0
fastest=999999999
for i in $(seq 0 $((N_ACTIVE - 1))); do
    tid=$(printf "fan%05d" "$i")
    f="$LOG_DIR/${tid}.log"
    [[ -f "$f" ]] || continue
    rps=$(extract_rps < "$f")
    rps_i=${rps%.*}
    [[ -n "$rps_i" ]] || rps_i=0
    shard_total=$((shard_total + rps_i))
    if grep -q "succeeded, .*$PER_REQUESTS succeeded" "$f" 2>/dev/null; then
        ok_count=$((ok_count + 1))
    fi
    if (( rps_i > slowest )); then slowest=$rps_i; fi
    if (( rps_i < fastest )); then fastest=$rps_i; fi
done

elapsed=$(awk "BEGIN {printf \"%.2f\", $t_end - $t_start}")
total_req=$((PER_REQUESTS * N_ACTIVE))
total_rps=$(awk "BEGIN {printf \"%.0f\", $total_req / ($t_end - $t_start)}")
mean_rps=$(( shard_total / N_ACTIVE ))

echo ""
echo "═══════════════════════════════════════════════════════════════"
printf " elapsed:                %ss\n" "$elapsed"
printf " sum of per-tenant rps:  %s req/s (sum across $N_ACTIVE tenants)\n" "$shard_total"
printf " wall-clock rps:         %s req/s (total_req / elapsed)\n" "$total_rps"
printf " per-tenant mean:        %s req/s\n" "$mean_rps"
printf " per-tenant min..max:    %s..%s req/s\n" "$fastest" "$slowest"
echo "═══════════════════════════════════════════════════════════════"
rm -rf "$LOG_DIR"
