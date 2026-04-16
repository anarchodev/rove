#!/usr/bin/env bash
#
# kv_shard_bench.sh — measure aggregate write throughput when a hot-key
# workload is sharded across N independent tenants (each with its own
# app.db → its own SQLite WAL writer lock), but still sharing a single
# raft log.
#
# Compares:
#   (1) one tenant at full blast (single app.db WAL writer lock)
#   (2) N tenants in parallel (N app.db locks, shared raft log)
#
# If (2) is significantly faster than (1), the per-tenant WAL writer
# lock is the bottleneck. If (2) ≈ (1), the shared raft log fsync is.
#
# Prerequisites:
#   - js-worker running with write0..write7 tenants
#   - h2load installed
#
# Usage:
#   scripts/kv_shard_bench.sh [requests_per_tenant] [clients] [streams]

set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8082}"
REQUESTS="${1:-50000}"
CLIENTS="${2:-10}"
STREAMS="${3:-10}"
TENANTS=8

echo "═══════════════════════════════════════════════════════════════"
echo " KV write sharding benchmark"
echo " h2load → http://$HOST:$PORT"
echo " requests per tenant=$REQUESTS  clients=$CLIENTS  streams=$STREAMS"
echo "═══════════════════════════════════════════════════════════════"

# Extract req/s from h2load's "finished in ..." line
extract_rps() {
  awk '/finished in/ { for (i=1;i<=NF;i++) if ($i ~ /req\/s/) print $(i-1) }'
}

echo ""
echo "── (1) Single tenant: all load on hot.test ──"
single_out=$(h2load -n "$((REQUESTS * TENANTS))" -c "$CLIENTS" -m "$STREAMS" \
  --header="host: hot.test" "http://$HOST:$PORT/" 2>&1)
echo "$single_out" | grep -E "finished in|req/s"
single_rps=$(echo "$single_out" | extract_rps)

echo ""
echo "── (2) Sharded: $TENANTS tenants in parallel (write0..write$((TENANTS-1)).test) ──"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

start_ts=$(date +%s.%N)
for i in $(seq 0 $((TENANTS - 1))); do
  h2load -n "$REQUESTS" -c "$CLIENTS" -m "$STREAMS" \
    --header="host: write${i}.test" \
    "http://$HOST:$PORT/" > "$tmpdir/w${i}.log" 2>&1 &
done
wait
end_ts=$(date +%s.%N)

total_requests=$((REQUESTS * TENANTS))
wall_sec=$(awk "BEGIN { printf \"%.3f\", $end_ts - $start_ts }")
aggregate_rps=$(awk "BEGIN { printf \"%.0f\", $total_requests / ($end_ts - $start_ts) }")

for i in $(seq 0 $((TENANTS - 1))); do
  per_rps=$(extract_rps < "$tmpdir/w${i}.log")
  printf "  write%d.test: %s req/s\n" "$i" "$per_rps"
done

echo ""
echo "── Summary ──"
printf "  single tenant (hot):     %10.0f req/s\n" "$single_rps"
printf "  %d tenants aggregate:     %10.0f req/s  (wall=%.2fs, total=%d reqs)\n" \
  "$TENANTS" "$aggregate_rps" "$wall_sec" "$total_requests"

speedup=$(awk "BEGIN { printf \"%.2f\", $aggregate_rps / $single_rps }")
echo ""
echo "  speedup vs single tenant: ${speedup}×"
echo ""
echo "  ≈1.0×  →  shared raft log fsync is the ceiling"
echo "  >1.0×  →  per-tenant app.db WAL writer lock is a meaningful limit"
echo "═══════════════════════════════════════════════════════════════"
