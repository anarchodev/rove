#!/usr/bin/env bash
# End-to-end smoke test for the CPU-budget interrupt handler + penalty box.
#
# Boots loop46 (single-node) with the `penalty` tenant wired to a
# `while (true) {}` handler, then fires requests and asserts:
#
#   1) the first 3 requests return 504 (interrupt fired, handler killed
#      mid-spin; penalty box accumulates kills)
#   2) the 4th request returns 503 (penalty box tripped open → short
#      circuit, qjs never runs)
#   3) after a fresh redeploy the next request goes back to 504 (auto-
#      release on deployment change — not exercised here because M1
#      has no redeploy path; documented for Phase 5 smoke)
#
# Exits non-zero on any mismatch.

set -euo pipefail

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-penalty-smoke}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8092}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40192}"
BIN="${WORKER_BIN:-./zig-out/bin/loop46}"
WORKER_BIN="$BIN"
HOST_HEADER="penalty.loop46.localhost"
PUBLIC_SUFFIX="loop46.localhost"
ADMIN_HOST="app.${PUBLIC_SUFFIX}"

if [[ ! -x "$WORKER_BIN" ]]; then
    echo "error: $WORKER_BIN not found — run 'zig build install' first" >&2
    exit 2
fi

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=penalty-smoke
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

# Seed `penalty` tenant onto every node. The tenant ships a
# `while(true)` handler that the budget interrupt fires on.
seed_all_dirs ./examples/loop46-demo-tenants.json

# --workers 1: penalty-box state is per-worker, so SO_REUSEPORT spread
# across N workers would dilute kill counts and never trip the box.
PIDS=()
for i in 0 1 2; do
    "$WORKER_BIN" worker \
        --node-id "$i" \
        --peers "$PEERS_CSV" \
        --listen "${RAFT_ADDRS[$i]}" \
        --http "${HTTP_ADDRS[$i]}" \
        --data-dir "${DATA_DIRS[$i]}" \
        --public-suffix "$PUBLIC_SUFFIX" \
        --workers 1 \
        >"/tmp/${SMOKE_TAG}-worker-${i}.out" 2>&1 &
    PIDS+=($!)
done
trap '
    for p in "${PIDS[@]}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done
    for p in "${PIDS[@]}"; do
        [ -n "$p" ] && wait "$p" 2>/dev/null || true
    done
' EXIT
sleep 2

# Discover leader by probing for a non-handler path (avoid consuming
# penalty-box budget kills). The penalty tenant has no static, so the
# leader returns 404 and followers return 503 (leader-skip).
LEADER_HTTP=""
LEADER_IDX=""
for _ in $(seq 1 75); do
    for i in 0 1 2; do
        c=$(curl --http2-prior-knowledge --max-time 2 -s -o /dev/null -w '%{http_code}' \
            -H "Host: $HOST_HEADER" \
            "http://${HTTP_ADDRS[$i]}/__leader_probe__" 2>/dev/null || echo 000)
        # 404 = leader (route miss); 503 = follower (leader-skip)
        if [[ "$c" == "404" ]]; then
            LEADER_HTTP="${HTTP_ADDRS[$i]}"
            LEADER_IDX="$i"
            break 2
        fi
    done
    sleep 0.2
done
[[ -n "$LEADER_HTTP" ]] || {
    echo "FAIL: no leader returned 404 within 15s" >&2
    for i in 0 1 2; do
        echo "--- worker $i log ---" >&2
        tail -30 "/tmp/${SMOKE_TAG}-worker-${i}.out" >&2
    done
    exit 1
}
echo "ok  leader elected: node $LEADER_IDX at $LEADER_HTTP"

curl_status() {
    curl \
         --http2-prior-knowledge \
         --max-time 5 \
         -s -o /dev/null \
         -w '%{http_code}' \
         -H "Host: $HOST_HEADER" \
         "http://$LEADER_HTTP/?fn=handler"
}

expect() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL $label: expected $expected, got $actual" >&2
        for i in 0 1 2; do
            echo "--- worker $i log ---" >&2
            tail -40 "/tmp/${SMOKE_TAG}-worker-${i}.out" >&2
        done
        exit 1
    fi
    echo "ok  $label: $actual"
}

# First three requests: each hits the 10ms budget → 504.
for i in 1 2 3; do
    code=$(curl_status || true)
    expect "request $i (expect 504 from budget kill)" 504 "$code"
done

# Fourth request: penalty box is now open (kill_threshold=3) → short-
# circuit 503 without entering qjs. This request should come back
# basically instantly, unlike the 504s which each burned ~10ms.
code=$(curl_status || true)
expect "request 4 (expect 503 from penalty box)" 503 "$code"

# Fifth and sixth stay 503 while the box is open.
for i in 5 6; do
    code=$(curl_status || true)
    expect "request $i (expect 503, still boxed)" 503 "$code"
done

echo "PASS penalty smoke"
