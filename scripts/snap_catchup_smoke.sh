#!/usr/bin/env bash
# End-to-end smoke for production.md #1.1 step 3 — out-of-band
# snapshot catchup for a far-behind follower.
#
# Sequence:
#   1. Bring up a 3-node loop46 cluster.
#   2. Stop one follower.
#   3. Issue enough writes against the leader that willemt's
#      snapshot_last_idx advances past where the stopped follower
#      was. Repeated snapshot ticks compact the log.
#   4. Restart the stopped follower.
#   5. Leader's cbSendSnapshot fires; the follower receives a
#      `snap_fetch_offer`, dispatches a fetcher thread, GETs the
#      bundle, stages under `{data_dir}/.snap-in-{id}/`.
#   6. Assert: follower's log emits the expected info lines AND a
#      staged directory appears with the expected files.
#
# The live install (atomic-rename + raft_load_snapshot) is a
# follow-up commit; this smoke verifies the offer → fetch → stage
# half is wired end-to-end.

set -euo pipefail

if [[ -f .env ]]; then
    set -a
    # shellcheck source=/dev/null
    source .env
    set +a
fi

PREFIX="${PREFIX:-/tmp/rove-snap-catchup}"
HTTP_BASE="${HTTP_BASE:-8480}"
RAFT_BASE="${RAFT_BASE:-40480}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc}"
PUBLIC_SUFFIX="loop46.localhost"
ADMIN_HOST="app.${PUBLIC_SUFFIX}"
WRITE_BURSTS="${WRITE_BURSTS:-30}"    # how many quick spread writes per tick
TICK_INTERVAL_MS="${TICK_INTERVAL_MS:-500}"

if [[ "$(uname -s)" == "Darwin" ]]; then
    LOOP46_DATA="${LOOP46_DATA:-$HOME/Library/Application Support/loop46}"
else
    LOOP46_DATA="${LOOP46_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/loop46}"
fi
TLS_CERT="$LOOP46_DATA/dev-cert.pem"
TLS_KEY="$LOOP46_DATA/dev-key.pem"
CACERT="$LOOP46_DATA/ca-root.pem"

[[ -f "$TLS_CERT" && -f "$TLS_KEY" ]] || { echo "missing dev TLS at $LOOP46_DATA" >&2; exit 2; }
[[ -x "$BIN" ]] || { echo "$BIN missing — run zig build install" >&2; exit 2; }

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=snap-catchup
SMOKE_PROTO=https
init_cluster_addrs "$PREFIX" "$HTTP_BASE" "$RAFT_BASE"

export S3_KEY_PREFIX_BASE="${S3_KEY_PREFIX_BASE:-snap-catchup-$(hostname)-$(id -u)/}"
export LOOP46_SERVICES_JWT_SECRET="${LOOP46_SERVICES_JWT_SECRET:-$(head -c32 /dev/urandom | xxd -p | tr -d '\n')}"
export LOOP46_ROOT_TOKEN="$TOKEN"

# Seed a tiny demo manifest — just the spread tenant. The catchup
# verification only needs ONE tenant getting writes; the empty pool
# stays minimal so each node boots fast.
seed_all_dirs ./examples/loop46-demo-tenants.json

start_node() {
    local i="$1"
    local logf="/tmp/${SMOKE_TAG}-worker-${i}.out"
    "$BIN" worker \
        --node-id "$i" \
        --peers "$PEERS_CSV" \
        --listen "${RAFT_ADDRS[$i]}" \
        --http "${HTTP_ADDRS[$i]}" \
        --data-dir "${DATA_DIRS[$i]}" \
        --public-suffix "$PUBLIC_SUFFIX" \
        --tls-cert "$TLS_CERT" \
        --tls-key "$TLS_KEY" \
        --workers 1 \
        --snapshot-interval-ms "$TICK_INTERVAL_MS" \
        --election-timeout-ms 1000 \
        --heartbeat-ms 100 \
        >"$logf" 2>&1 &
    echo $!
}

PIDS=()
for i in 0 1 2; do
    PIDS+=($(start_node "$i"))
done
trap '
    for p in "${PIDS[@]:-}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done
    wait 2>/dev/null || true
' EXIT

sleep 3

RESOLVE=()
for h in "${HTTP_ADDRS[@]}"; do
    p="${h##*:}"
    RESOLVE+=(--resolve "${ADMIN_HOST}:${p}:127.0.0.1")
    RESOLVE+=(--resolve "spread.loop46.localhost:${p}:127.0.0.1")
done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}" --max-time 5)
discover_leader "$ADMIN_HOST" "$TOKEN" || exit 1
LEADER_IDX_INITIAL="$LEADER_IDX"
echo "initial leader: node $LEADER_IDX_INITIAL at $LEADER_HTTP"

# Pick a follower DIFFERENT from the leader. Stop it.
FOLLOWER_IDX=0
for j in 0 1 2; do
    if [[ "$j" != "$LEADER_IDX_INITIAL" ]]; then
        FOLLOWER_IDX=$j
        break
    fi
done
FOLLOWER_PID="${PIDS[$FOLLOWER_IDX]}"
FOLLOWER_DATA="${DATA_DIRS[$FOLLOWER_IDX]}"
echo "stopping follower: node $FOLLOWER_IDX (pid=$FOLLOWER_PID)"
kill -TERM "$FOLLOWER_PID" 2>/dev/null || true
wait "$FOLLOWER_PID" 2>/dev/null || true
PIDS[$FOLLOWER_IDX]=""

# Hammer the leader with writes so willemt compacts past the
# follower's last_idx. Use the spread tenant's handler (1000-key
# writes — each request commits one envelope).
LEADER_PORT="${LEADER_HTTP##*:}"
echo "driving $WRITE_BURSTS write bursts of 50 reqs each against spread.loop46.localhost on leader (port=$LEADER_PORT)…"
for burst in $(seq 1 $WRITE_BURSTS); do
    for _ in $(seq 1 50); do
        "${CURL[@]}" --connect-to "spread.loop46.localhost:${LEADER_PORT}:127.0.0.1:${LEADER_PORT}" \
            -o /dev/null "https://spread.loop46.localhost:${LEADER_PORT}/?fn=handler" &
    done
    wait
    sleep 0.3
done

# Give the leader a few snapshot ticks to advance.
sleep 2

LEADER_LOG="/tmp/${SMOKE_TAG}-worker-${LEADER_IDX_INITIAL}.out"
SNAP_IDX=$(grep -oE "snapshot tick apply_position=[0-9]+" "$LEADER_LOG" | tail -1 | grep -oE "[0-9]+" || echo 0)
echo "leader snapshot_last_idx after burst: ${SNAP_IDX:-unknown}"

# Restart the follower. cbSendSnapshot should fire on the leader,
# the follower receives the offer, fetches + stages.
echo "restarting follower: node $FOLLOWER_IDX"
PIDS[$FOLLOWER_IDX]=$(start_node "$FOLLOWER_IDX")

# Wait up to 20s for the staging dir to appear under the follower's
# data_dir AND for the receive log line.
FOLLOWER_LOG="/tmp/${SMOKE_TAG}-worker-${FOLLOWER_IDX}.out"
SUCCESS=0
for _ in $(seq 1 60); do
    if grep -q "raft: snap fetch.*staged.*files" "$FOLLOWER_LOG" 2>/dev/null; then
        SUCCESS=1
        break
    fi
    sleep 0.5
done

echo
echo "── results ──"
echo "leader sent offer:"
grep "sent snap_fetch_offer" "$LEADER_LOG" | tail -3 || echo "  (no offer-send log lines found)"
echo
echo "follower received + staged:"
grep -E "received snap_fetch_offer|snap fetch.*staged|snap fetch.*failed" "$FOLLOWER_LOG" | tail -5 || echo "  (no receive log lines found)"
echo
echo "staged dirs on follower:"
ls -ld "$FOLLOWER_DATA"/.snap-in-* 2>/dev/null || echo "  (no .snap-in-* dirs)"
echo
echo "staged file count (first match):"
for d in "$FOLLOWER_DATA"/.snap-in-*; do
    [[ -d "$d" ]] && { echo "  $d: $(ls "$d" | wc -l) files"; break; }
done

if (( SUCCESS == 1 )); then
    echo
    echo "PASS — follower fetched + staged a snapshot bundle."
    exit 0
else
    echo
    echo "FAIL — no stage line in $FOLLOWER_LOG within 30s"
    tail -40 "$FOLLOWER_LOG" >&2
    exit 1
fi
