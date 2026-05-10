#!/usr/bin/env bash
# Snapshot scalability benchmark — verifies the stamp-and-compact
# log compaction (docs/production.md #1.1) stays well under the
# willemt heartbeat budget across tenant scales.
#
# The proof point: after warmup (where every tenant gets at least one
# write so it appears in apply_ctx.tenant_apply_idx), drive writes
# against N_active out of N_total tenants. Steady-state snapshot
# ticks should:
#   - fire at the configured cadence (no leadership flap)
#   - have duration_ms well under the election timeout
#   - stamp _apply_state for every tenant (always-refresh-all)
#
# Pass duration scales linearly with N_total (one small SQLite
# write per tenant per pass) but with a steep slope: ~1ms per
# tenant in fs backend. At 10k tenants this is the next bottleneck
# — to push further we'd batch stamps across multiple ticks.
#
# Usage:
#   N_TOTAL=1000 N_ACTIVE=100 STEADY_S=60 bash scripts/snapshot_scalability_bench.sh
#
# Env knobs (defaults shown):
#   N_TOTAL=100             total tenants to seed
#   N_ACTIVE=10             tenants to write to during the steady phase
#   STEADY_S=60             steady-state load duration (seconds)
#   SNAPSHOT_INTERVAL_MS=3000  --snapshot-interval-ms passed to the worker
#   WARMUP_PARALLEL=16      curl concurrency for the warmup phase
#   STEADY_PARALLEL=4       curl concurrency for the steady phase
#   POST_WARMUP_SETTLE_S=8  wait for ≥2 ticks to fire after warmup
#                           before starting the measurement window
#
# Requires: sqlite3.

set -euo pipefail

N_TOTAL="${N_TOTAL:-100}"
N_ACTIVE="${N_ACTIVE:-10}"
STEADY_S="${STEADY_S:-60}"
SNAPSHOT_INTERVAL_MS="${SNAPSHOT_INTERVAL_MS:-3000}"
WARMUP_PARALLEL="${WARMUP_PARALLEL:-16}"
STEADY_PARALLEL="${STEADY_PARALLEL:-4}"
POST_WARMUP_SETTLE_S="${POST_WARMUP_SETTLE_S:-8}"

if (( N_ACTIVE > N_TOTAL )); then
    echo "error: N_ACTIVE ($N_ACTIVE) > N_TOTAL ($N_TOTAL)" >&2
    exit 2
fi

BIN="${BIN:-./zig-out/bin/loop46}"
if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN missing — run 'zig build install' first" >&2
    exit 2
fi
for tool in sqlite3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not in PATH" >&2; exit 2; }
done

PREFIX="${PREFIX:-/tmp/rove-snap-bench}"
HTTP_BASE="${HTTP_BASE:-8470}"
RAFT_BASE="${RAFT_BASE:-40470}"
ROOT_TOKEN=ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd

if [[ "$(uname -s)" == "Darwin" ]]; then
    LOOP46_DATA="${LOOP46_DATA:-$HOME/Library/Application Support/loop46}"
else
    LOOP46_DATA="${LOOP46_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/loop46}"
fi
TLS_CERT="$LOOP46_DATA/dev-cert.pem"
TLS_KEY="$LOOP46_DATA/dev-key.pem"
CACERT="$LOOP46_DATA/ca-root.pem"

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=snap-bench
SMOKE_PROTO=https
init_cluster_addrs "$PREFIX" "$HTTP_BASE" "$RAFT_BASE"

# ── Phase A: seed N_TOTAL tenants ──────────────────────────────────
echo "phase A: seeding $N_TOTAL tenants on each of 3 nodes…"
SEED_MANIFEST=$(mktemp --suffix=.json)
trap 'rm -f "$SEED_MANIFEST"' EXIT
{
    echo -n '{"tenants":['
    for (( i = 0; i < N_TOTAL; i++ )); do
        if (( i > 0 )); then echo -n ','; fi
        printf '{"id":"t%05d","domains":[],"files":[]}' "$i"
    done
    echo ']}'
} > "$SEED_MANIFEST"

t0=$(date +%s)
seed_all_dirs "$SEED_MANIFEST"
t1=$(date +%s)
echo "  seeded $N_TOTAL × 3 dirs in $((t1 - t0))s"
rm -f "$SEED_MANIFEST"

# ── Phase B: spawn workers ─────────────────────────────────────────
export LOOP46_SERVICES_JWT_SECRET=$(head -c32 /dev/urandom | xxd -p | tr -d '\n')
export LOOP46_ROOT_TOKEN="$ROOT_TOKEN"

PIDS=()
echo "phase B: starting 3-node cluster, --snapshot-interval-ms=$SNAPSHOT_INTERVAL_MS…"
for i in 0 1 2; do
    "$BIN" worker \
        --node-id "$i" \
        --peers "$PEERS_CSV" \
        --listen "${RAFT_ADDRS[$i]}" \
        --http "${HTTP_ADDRS[$i]}" \
        --data-dir "${DATA_DIRS[$i]}" \
        --public-suffix loop46.localhost \
        --snapshot-interval-ms "$SNAPSHOT_INTERVAL_MS" \
        --tls-cert "$TLS_CERT" \
        --tls-key "$TLS_KEY" \
        --workers 1 \
        "${RAFT_TIMING_FLAGS[@]}" \
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
    rm -f "$SEED_MANIFEST"
' EXIT
sleep 2

RESOLVE=()
for h in "${HTTP_ADDRS[@]}"; do
    p="${h##*:}"
    RESOLVE+=(--resolve "app.loop46.localhost:${p}:127.0.0.1")
done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}" --max-time 30)
discover_leader "app.loop46.localhost" "$ROOT_TOKEN" || exit 1
echo "  leader: node $LEADER_IDX at $LEADER_HTTP"
LEADER_DIR="${DATA_DIRS[$LEADER_IDX]}"
LEADER_LOG="/tmp/${SMOKE_TAG}-worker-${LEADER_IDX}.out"
LEADER_PORT="${LEADER_HTTP##*:}"

# ── Phase C: warmup — one release POST per tenant ─────────────────
echo "phase C: warmup — 1 release/tenant × $N_TOTAL (parallel=$WARMUP_PARALLEL)…"
t_warmup_start=$(date +%s)
seq 0 $((N_TOTAL - 1)) | xargs -n1 -P "$WARMUP_PARALLEL" -I{} \
    bash -c '
        i=$1
        tid=$(printf "t%05d" "$i")
        curl -sS --cacert "'"$CACERT"'" \
            '"${RESOLVE[*]}"' \
            --max-time 60 \
            -o /dev/null \
            -H "Authorization: Bearer '"$ROOT_TOKEN"'" \
            -H "Content-Type: application/json" \
            -d "{\"tenant_id\":\"$tid\",\"dep_id\":1}" \
            "https://app.loop46.localhost:'"$LEADER_PORT"'/_system/release"
    ' _ {} 2>/dev/null || true
t_warmup_end=$(date +%s)
echo "  warmup done in $((t_warmup_end - t_warmup_start))s"

# Wait for the warmup writes to settle and a couple of compaction
# ticks to fire (so tenant_apply_idx has every tenant in it for
# subsequent ticks).
echo "phase C': waiting ${POST_WARMUP_SETTLE_S}s for warmup applies to settle…"
sleep "$POST_WARMUP_SETTLE_S"

# Mark the start of the measurement window: how many compaction
# ticks have fired already? Subtract from the end count to get
# steady-state ticks.
START_TICKS=$(awk '/snapshot tick apply_position=/ {n++} END {print n+0}' "$LEADER_LOG")
echo "  ticks before steady phase: $START_TICKS"
if (( START_TICKS < 2 )); then
    echo "  WARN: fewer than 2 ticks before steady phase — measurement may be skewed"
fi

# ── Phase D: steady-state load ────────────────────────────────────
echo "phase D: steady-state load ($N_ACTIVE active tenants × ${STEADY_S}s, parallel=$STEADY_PARALLEL)…"
END_AT=$(( $(date +%s) + STEADY_S ))

# Slot drivers: each loops over its share of active ids.
seq 0 $((STEADY_PARALLEL - 1)) | xargs -n1 -P "$STEADY_PARALLEL" -I{} \
    bash -c '
        slot=$1
        N_ACTIVE='"$N_ACTIVE"'
        END_AT='"$END_AT"'
        PORT='"$LEADER_PORT"'
        STEADY_PARALLEL='"$STEADY_PARALLEL"'
        cnt=0
        dep=2
        while (( $(date +%s) < END_AT )); do
            idx=$(( cnt % N_ACTIVE ))
            i=$(( (slot + idx * STEADY_PARALLEL) % N_ACTIVE ))
            tid=$(printf "t%05d" "$i")
            curl -sS --cacert "'"$CACERT"'" '"${RESOLVE[*]}"' \
                --max-time 30 -o /dev/null \
                -H "Authorization: Bearer '"$ROOT_TOKEN"'" \
                -H "Content-Type: application/json" \
                -d "{\"tenant_id\":\"$tid\",\"dep_id\":$dep}" \
                "https://app.loop46.localhost:${PORT}/_system/release" 2>/dev/null \
                && cnt=$((cnt + 1))
            dep=$((dep + 1))
        done
        echo "$cnt"
    ' _ {} > "/tmp/${SMOKE_TAG}-slots.out" 2>&1

TOTAL_COMMITS=$(awk '{s+=$1} END {print s}' "/tmp/${SMOKE_TAG}-slots.out")

# Give one final snapshot interval to capture post-burst state.
sleep $(( (SNAPSHOT_INTERVAL_MS / 1000) + 1 ))

# ── Phase E: parse snapshot stats from the leader log ─────────────
echo "phase E: parsing snapshot tick stats from leader log…"
END_TICKS=$(awk '/snapshot tick apply_position=/ {n++} END {print n+0}' "$LEADER_LOG")
echo "  ticks after steady phase:  $END_TICKS (delta = $((END_TICKS - START_TICKS)))"

mapfile -t ALL_LINES < <(grep -oE 'snapshot tick apply_position=[0-9]+ stamped_tenants=[0-9]+ stamped_root=(true|false) duration_ms=[0-9]+' "$LEADER_LOG" || true)

if (( END_TICKS <= START_TICKS )); then
    echo "FAIL: no new compaction ticks fired during the steady phase" >&2
    echo "      (heartbeat starvation? leadership flap? check leader log)" >&2
    tail -30 "$LEADER_LOG" >&2
    exit 1
fi

# Slice to steady window. ALL_LINES is in chronological order.
N_STEADY=$(( END_TICKS - START_TICKS ))
N_AVAILABLE=${#ALL_LINES[@]}
if (( N_AVAILABLE < N_STEADY )); then
    N_STEADY=$N_AVAILABLE
fi
STEADY_LINES=("${ALL_LINES[@]: -$N_STEADY}")

# Aggregate.
TOTAL_STAMPED=0; TOTAL_DUR=0; MAX_DUR=0
for line in "${STEADY_LINES[@]}"; do
    s=$(echo "$line" | grep -oE 'stamped_tenants=[0-9]+' | cut -d= -f2)
    d=$(echo "$line" | grep -oE 'duration_ms=[0-9]+' | cut -d= -f2)
    TOTAL_STAMPED=$((TOTAL_STAMPED + s))
    TOTAL_DUR=$((TOTAL_DUR + d))
    (( d > MAX_DUR )) && MAX_DUR=$d
done

if (( N_STEADY > 0 )); then
    AVG_STAMPED=$(( TOTAL_STAMPED / N_STEADY ))
    AVG_DUR=$(( TOTAL_DUR / N_STEADY ))
else
    AVG_STAMPED=0; AVG_DUR=0
fi

# raft.log.db steady-state size on the leader.
RAFT_LOG="$LEADER_DIR/raft.log.db"
RAFT_SIZE=$(stat -c %s "$RAFT_LOG" 2>/dev/null || stat -f %z "$RAFT_LOG")
RAFT_ROWS=$(sqlite3 "$RAFT_LOG" "SELECT COUNT(*) FROM raft_log;" 2>/dev/null || echo "?")

# Commits/sec.
if (( STEADY_S > 0 )); then
    COMMITS_PER_S=$(( TOTAL_COMMITS / STEADY_S ))
else
    COMMITS_PER_S=0
fi

# Spot-check the always-refresh-all property: a dormant tenant
# (one we wrote to ONCE in warmup, never since) must have its
# _apply_state advance past warmup time. Pick the highest-numbered
# warmup tenant (the one furthest from the active set 0..N_ACTIVE-1).
DORMANT_ID=$(printf 't%05d' "$((N_TOTAL - 1))")
DORMANT_DB="$LEADER_DIR/$DORMANT_ID/app.db"
DORMANT_STAMP=0
if [[ -f "$DORMANT_DB" ]]; then
    DORMANT_STAMP=$(sqlite3 "$DORMANT_DB" "SELECT v FROM _apply_state WHERE k='last_applied_raft_idx';" 2>/dev/null || echo 0)
fi

# ── Report ─────────────────────────────────────────────────────────
echo
echo "═════ snapshot scalability bench results ═════"
printf '  %-32s %s\n' "N_total"                    "$N_TOTAL"
printf '  %-32s %s\n' "N_active"                   "$N_ACTIVE"
printf '  %-32s %ss\n' "steady_duration"           "$STEADY_S"
printf '  %-32s %sms\n' "snapshot_interval"        "$SNAPSHOT_INTERVAL_MS"
echo
printf '  %-32s %s (across %d steady ticks)\n' "avg stamped tenants/tick" "$AVG_STAMPED" "$N_STEADY"
printf '  %-32s %sms (max %sms)\n' "avg tick duration" "$AVG_DUR" "$MAX_DUR"
echo
printf '  %-32s %s commits (%s/s)\n' "steady-state apply throughput" "$TOTAL_COMMITS" "$COMMITS_PER_S"
printf '  %-32s %s bytes (%s rows)\n' "raft.log.db steady-state"     "$RAFT_SIZE" "$RAFT_ROWS"
printf '  %-32s %s (last warmup tenant)\n' "dormant _apply_state ($DORMANT_ID)" "$DORMANT_STAMP"
echo

# Sanity: max tick duration must stay well under typical raft
# election timeout (200-500ms). If it doesn't, the heartbeat-
# starvation problem is back.
ELECTION_BUDGET_MS=200
if (( MAX_DUR > ELECTION_BUDGET_MS )); then
    echo "WARN: max tick duration ($MAX_DUR ms) > $ELECTION_BUDGET_MS ms"
    echo "      — risk of heartbeat starvation; pass is doing too much"
    echo "      raft-thread work. Check that no S3 / VACUUM-INTO crept"
    echo "      back into tickRaftCapture."
fi

# Always-refresh-all: a dormant tenant's _apply_state should
# advance every pass even though it's never written to.
if (( DORMANT_STAMP < START_TICKS )); then
    echo "WARN: dormant tenant _apply_state ($DORMANT_STAMP) didn't advance"
    echo "      — always-refresh-all is broken; willemt's compaction"
    echo "      floor will be pinned by dormant tenants."
fi

echo "DONE"
