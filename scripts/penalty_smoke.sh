#!/usr/bin/env bash
# End-to-end smoke test for the CPU-budget interrupt handler + penalty box.
#
# Boots js-worker (single-node) with the `penalty` tenant wired to a
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

DATA_DIR="${DATA_DIR:-/tmp/rove-penalty-smoke}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8092}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40192}"
WORKER_BIN="${WORKER_BIN:-./zig-out/bin/js-worker}"
HOST_HEADER="penalty.test"

if [[ ! -x "$WORKER_BIN" ]]; then
    echo "error: $WORKER_BIN not found — run 'zig build install' first" >&2
    exit 2
fi

rm -rf "$DATA_DIR"

"$WORKER_BIN" \
    --node-id 0 \
    --peers "$RAFT_ADDR" \
    --listen "$RAFT_ADDR" \
    --http "$HTTP_ADDR" \
    --data-dir "$DATA_DIR" \
    --fresh >/tmp/penalty-smoke.out 2>&1 &
WORKER_PID=$!
trap 'kill $WORKER_PID 2>/dev/null || true; wait $WORKER_PID 2>/dev/null || true' EXIT

# Let the worker bind + elect itself leader.
sleep 0.8

curl_status() {
    # --http2-prior-knowledge: speak h2c directly (no upgrade dance).
    # -s: silent; -o /dev/null: drop body; -w '%{http_code}': print just code.
    # --max-time 5: cap in case something is truly stuck.
    curl --http2-prior-knowledge \
         --max-time 5 \
         -s -o /dev/null \
         -w '%{http_code}' \
         -H "Host: $HOST_HEADER" \
         "http://$HTTP_ADDR/"
}

expect() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL $label: expected $expected, got $actual" >&2
        echo "--- worker log ---" >&2
        tail -40 /tmp/penalty-smoke.out >&2
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
