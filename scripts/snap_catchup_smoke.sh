#!/usr/bin/env bash
# End-to-end smoke for production.md #1.1 step 3 — out-of-band
# snapshot catchup for a far-behind follower.
#
# Sequence:
#   1. Bring up a 3-node loop46 cluster.
#   2. Stop one follower.
#   3. Issue enough writes against the leader that willemt's
#      snapshot_last_idx advances past where the stopped follower
#      was.
#   4. Restart the stopped follower (first time).
#   5. Leader sends a `snap_fetch_offer`; follower fetches the
#      bundle and stages it under `{data_dir}/.snap-in-{snap_id}/`,
#      then exits cleanly (SnapReceiver calls `std.process.exit(0)`
#      after stage).
#   6. Smoke notices the follower process exited and re-spawns
#      it (manual one-shot, not a supervisor loop).
#   7. Re-spawn boots into `installStagedSnapshotIfPresent`,
#      atomic-renames the staged files into place, calls
#      `raft_load_snapshot(snap_last_idx, snap_last_term)`, and
#      the worker proceeds normally — caught up.
#
# Why no supervisor loop: bash supervisors don't reliably propagate
# signals to children and the lifecycle is hard to pin down. A
# manual two-spawn flow keeps the smoke deterministic.

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
WRITE_BURSTS="${WRITE_BURSTS:-30}"
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
        >>"$logf" 2>&1 &
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

LEADER_PORT="${LEADER_HTTP##*:}"
echo "driving $WRITE_BURSTS write bursts of 50 reqs each…"
for burst in $(seq 1 $WRITE_BURSTS); do
    for _ in $(seq 1 50); do
        "${CURL[@]}" --connect-to "spread.loop46.localhost:${LEADER_PORT}:127.0.0.1:${LEADER_PORT}" \
            -o /dev/null "https://spread.loop46.localhost:${LEADER_PORT}/?fn=handler" &
    done
    wait
    sleep 0.3
done

sleep 2

LEADER_LOG="/tmp/${SMOKE_TAG}-worker-${LEADER_IDX_INITIAL}.out"
SNAP_IDX=$(grep -oE "snapshot tick apply_position=[0-9]+" "$LEADER_LOG" | tail -1 | grep -oE "[0-9]+" || echo 0)
echo "leader snapshot_last_idx after burst: ${SNAP_IDX:-unknown}"

# First respawn: receiver fetches + stages + exits cleanly.
echo "restarting follower (1st time — stages bundle, then exits)…"
FOLLOWER_LOG="/tmp/${SMOKE_TAG}-worker-${FOLLOWER_IDX}.out"
FOLLOWER_LOG_OFFSET=$(stat -c %s "$FOLLOWER_LOG" 2>/dev/null || echo 0)
PIDS[$FOLLOWER_IDX]=$(start_node "$FOLLOWER_IDX")

# Wait for stage + exit. exit(0) → wait returns rc=0.
STAGE_OK=0
for _ in $(seq 1 60); do
    if ! kill -0 "${PIDS[$FOLLOWER_IDX]}" 2>/dev/null; then
        # Process exited.
        if tail -c +"$FOLLOWER_LOG_OFFSET" "$FOLLOWER_LOG" | grep -q "raft: snap fetch.*staged.*files"; then
            STAGE_OK=1
        fi
        break
    fi
    sleep 0.5
done
wait "${PIDS[$FOLLOWER_IDX]}" 2>/dev/null || true
PIDS[$FOLLOWER_IDX]=""

# Confirm staged dir exists with _install_meta.json.
STAGED_DIRS=("$FOLLOWER_DATA"/.snap-in-*)
META_FOUND=0
if [[ -d "${STAGED_DIRS[0]:-}" && -f "${STAGED_DIRS[0]}/_install_meta.json" ]]; then
    META_FOUND=1
fi

# Second respawn: boot-time install picks up the staged dir.
echo "restarting follower (2nd time — boot-time install)…"
FOLLOWER_LOG_OFFSET=$(stat -c %s "$FOLLOWER_LOG" 2>/dev/null || echo 0)
PIDS[$FOLLOWER_IDX]=$(start_node "$FOLLOWER_IDX")

INSTALL_OK=0
LOAD_OK=0
for _ in $(seq 1 60); do
    if tail -c +"$FOLLOWER_LOG_OFFSET" "$FOLLOWER_LOG" | grep -q "loop46: installing staged snapshot from"; then
        INSTALL_OK=1
    fi
    if tail -c +"$FOLLOWER_LOG_OFFSET" "$FOLLOWER_LOG" | grep -q "staged snapshot installed and raft_load_snapshot called"; then
        LOAD_OK=1
        break
    fi
    sleep 0.5
done

# Confirm staged dir was cleaned up after install.
CLEANUP_OK=0
if ! ls "$FOLLOWER_DATA"/.snap-in-* >/dev/null 2>&1; then
    CLEANUP_OK=1
fi

echo
echo "── results ──"
echo "leader sent offer:"
grep "sent snap_fetch_offer" "$LEADER_LOG" | tail -3 || echo "  (none)"
echo
echo "follower lifecycle:"
grep -E "received snap_fetch_offer|snap fetch.*staged|exiting for boot-time install|installing staged snapshot|raft_load_snapshot called" "$FOLLOWER_LOG" | tail -10 || echo "  (none)"
echo
echo "checks: stage=$STAGE_OK meta_file=$META_FOUND install=$INSTALL_OK load=$LOAD_OK cleanup=$CLEANUP_OK"

if (( STAGE_OK == 1 && META_FOUND == 1 && INSTALL_OK == 1 && LOAD_OK == 1 && CLEANUP_OK == 1 )); then
    echo
    echo "PASS — full catchup cycle: stage → exit → install → raft_load_snapshot → cleanup."
    exit 0
else
    echo
    echo "FAIL — one or more checks did not pass within 30s"
    echo "--- follower log (last 60 lines) ---"
    tail -60 "$FOLLOWER_LOG" >&2 || true
    exit 1
fi
