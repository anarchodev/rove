#!/usr/bin/env bash
#
# kv_write_bench.sh — compare write throughput under row-contention
# (every request writes the SAME key) vs spread (each request picks
# one of 1000 keys). Both handlers write a fixed 32-byte value so
# the only difference is whether concurrent writes collide on a row.
#
# Prerequisites:
#   - js-worker running: ./zig-out/bin/js-worker --fresh --workers 4
#   - h2load installed (nghttp2 package)
#
# Usage:
#   scripts/kv_write_bench.sh [requests] [clients] [streams]
#
# Defaults: 100000 requests, 10 clients, 10 max concurrent streams

set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8082}"
REQUESTS="${1:-100000}"
CLIENTS="${2:-10}"
STREAMS="${3:-10}"

echo "═══════════════════════════════════════════════════════════════"
echo " KV write contention benchmark"
echo " h2load → http://$HOST:$PORT"
echo " requests=$REQUESTS  clients=$CLIENTS  streams=$STREAMS"
echo "═══════════════════════════════════════════════════════════════"

# Warm up the spread tenant so its B-tree is already populated with
# all 1000 keys before the timed run — otherwise the first few
# thousand spread writes are INSERTs (allocating new pages) while
# hot writes are already doing REPLACE. We want both workloads doing
# in-place overwrites so the only variable is row contention.
echo ""
echo "── Warmup: populating spread tenant's 1000-key keyspace ──"
h2load -n 5000 -c 20 -m 10 \
  --header="host: spread.test" \
  "http://$HOST:$PORT/" 2>&1 | grep -E "finished|req/s" || true

echo ""
echo "── Hot-key writes (hot.test — all writes target key 'k') ──"
echo ""
h2load -n "$REQUESTS" -c "$CLIENTS" -m "$STREAMS" \
  --header="host: hot.test" \
  "http://$HOST:$PORT/"

echo ""
echo "── Spread writes (spread.test — 1000 distinct keys, same payload) ──"
echo ""
h2load -n "$REQUESTS" -c "$CLIENTS" -m "$STREAMS" \
  --header="host: spread.test" \
  "http://$HOST:$PORT/"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " Compare req/s between the two runs above."
echo " Spread > Hot  →  row-level contention matters at this concurrency."
echo " Spread ≈ Hot  →  bottleneck is elsewhere (raft fsync, proposal"
echo "                  queue, per-tenant WAL writer lock)."
echo "═══════════════════════════════════════════════════════════════"
