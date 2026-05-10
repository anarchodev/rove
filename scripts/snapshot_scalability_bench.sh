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
# Files-server cluster ports — distinct from loop46's so both can
# co-exist on the same machine. Production.md #1.4 step 4: loop46
# fetches manifests from this cluster over HTTP/2 instead of S3.
FS_HTTP_BASE="${FS_HTTP_BASE:-9090}"
FS_RAFT_BASE="${FS_RAFT_BASE:-41090}"
FS_PREFIX="${FS_PREFIX:-/tmp/rove-snap-bench-fs}"
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

# Source .env for AWS / S3 creds — the files-server we're spawning
# below still needs them at startup (file-blobs go to S3 even
# though manifests now live in the cluster store). Same approach
# as scripts/files_server_raft_smoke.sh.
__bench_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${__bench_repo_root}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${__bench_repo_root}/.env"
    set +a
fi
export S3_KEY_PREFIX_BASE="${S3_KEY_PREFIX_BASE:-snap-bench-$(hostname)-$(id -u)/}"

FS_BIN="${FS_BIN:-./zig-out/bin/files-server-standalone}"
if [[ ! -x "$FS_BIN" ]]; then
    echo "error: $FS_BIN missing — run 'zig build install' first" >&2
    exit 2
fi

FS_HTTP_ADDRS=(); FS_RAFT_ADDRS=(); FS_DATA_DIRS=()
for i in 0 1 2; do
    FS_HTTP_ADDRS+=("127.0.0.1:$((FS_HTTP_BASE + i))")
    FS_RAFT_ADDRS+=("127.0.0.1:$((FS_RAFT_BASE + i))")
    FS_DATA_DIRS+=("${FS_PREFIX}-${i}")
done
rm -rf "${FS_DATA_DIRS[@]}"
FS_PEERS_CSV=$(IFS=,; echo "${FS_RAFT_ADDRS[*]}")

# Shared JWT secret across loop46 + files-server (the dashboard +
# inter-service paths verify with the same key on both sides).
export LOOP46_SERVICES_JWT_SECRET=$(head -c32 /dev/urandom | xxd -p | tr -d '\n')
export LOOP46_ROOT_TOKEN="$ROOT_TOKEN"

# ── Phase A: spawn files-server cluster ────────────────────────────
echo "phase A: starting 3-node files-server cluster on ${FS_PEERS_CSV}…"
FS_PIDS=()
for i in 0 1 2; do
    "$FS_BIN" \
        --data-dir "${FS_DATA_DIRS[$i]}" \
        --listen "${FS_HTTP_ADDRS[$i]}" \
        --tls-cert "$TLS_CERT" \
        --tls-key "$TLS_KEY" \
        --raft-node-id "$i" \
        --raft-peers "$FS_PEERS_CSV" \
        --raft-listen "${FS_RAFT_ADDRS[$i]}" \
        --raft-election-timeout-ms 200 \
        --raft-heartbeat-ms 50 \
        --max-connections 4096 \
        >"/tmp/${SMOKE_TAG}-fs-${i}.out" 2>&1 &
    FS_PIDS+=($!)
done
sleep 2

# Mint a JWT for files-server inter-service calls (same secret as
# loop46's services tokens; same 5-minute expiry shape).
mint_jwt() {
    LOOP46_SERVICES_JWT_SECRET="$LOOP46_SERVICES_JWT_SECRET" python3 - <<'PY'
import base64, hmac, hashlib, json, os, time
secret = bytes.fromhex(os.environ["LOOP46_SERVICES_JWT_SECRET"])
header = b'{"alg":"HS256","typ":"JWT"}'
payload = json.dumps({"exp": int(time.time() * 1000) + 60 * 60 * 1000}).encode()
def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
signing_input = b64u(header) + "." + b64u(payload)
sig = hmac.new(secret, signing_input.encode(), hashlib.sha256).digest()
print(signing_input + "." + b64u(sig))
PY
}
FS_JWT=$(mint_jwt)

# Find the files-server leader.
FS_LEADER_IDX=""
for tries in $(seq 1 30); do
    for i in 0 1 2; do
        port="${FS_HTTP_ADDRS[$i]##*:}"
        code=$(curl -sS --cacert "$CACERT" --max-time 2 -o /dev/null -w '%{http_code}' \
            -H "Authorization: Bearer $FS_JWT" \
            "https://127.0.0.1:${port}/_system/leader" 2>/dev/null || echo 000)
        if [[ "$code" == "200" ]]; then
            FS_LEADER_IDX="$i"
            break 2
        fi
    done
    sleep 0.3
done
if [[ -z "$FS_LEADER_IDX" ]]; then
    echo "FAIL: no files-server leader elected after 9s" >&2
    for i in 0 1 2; do
        echo "--- fs node $i log ---" >&2
        tail -20 "/tmp/${SMOKE_TAG}-fs-${i}.out" >&2
    done
    exit 1
fi
FS_LEADER_PORT="${FS_HTTP_ADDRS[$FS_LEADER_IDX]##*:}"
echo "  files-server leader: node $FS_LEADER_IDX at 127.0.0.1:${FS_LEADER_PORT}"

# ── Phase A.1: seed N_TOTAL tenants (no S3 manifest PUTs) ─────────
echo "phase A.1: seeding $N_TOTAL tenants on each of 3 loop46 nodes…"
SEED_MANIFEST=$(mktemp --suffix=.json)
trap '
    rm -f "$SEED_MANIFEST"
    for p in "${PIDS[@]:-}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done
    for p in "${PIDS[@]:-}"; do
        [ -n "$p" ] && wait "$p" 2>/dev/null || true
    done
    for p in "${FS_PIDS[@]}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done
    for p in "${FS_PIDS[@]}"; do
        [ -n "$p" ] && wait "$p" 2>/dev/null || true
    done
' EXIT
{
    echo -n '{"tenants":['
    for (( i = 0; i < N_TOTAL; i++ )); do
        if (( i > 0 )); then echo -n ','; fi
        printf '{"id":"t%05d","domains":[],"files":[]}' "$i"
    done
    echo ']}'
} > "$SEED_MANIFEST"

t0=$(date +%s)
# Cluster-backed manifest mode: --no-files-bootstrap skips the
# legacy per-tenant S3 PUT entirely. seed just creates per-tenant
# dirs + writes `_deploy/current = 1`. The manifest goes into
# files-server's cluster store via the next phase.
SEED_PIDS=()
for d in "${DATA_DIRS[@]}"; do
    "$BIN" seed --data-dir "$d" --manifest "$SEED_MANIFEST" --no-files-bootstrap --deploy-id 1 >/dev/null &
    SEED_PIDS+=($!)
done
for p in "${SEED_PIDS[@]}"; do wait "$p"; done
t1=$(date +%s)
echo "  seeded $N_TOTAL × 3 dirs in $((t1 - t0))s (no-files-bootstrap)"
rm -f "$SEED_MANIFEST"

# ── Phase A.2: PUT empty manifest 1 for every tenant ──────────────
#
# Each PUT is one raft propose through the files-server cluster.
# Sequential at first (curl pipelining keeps the TCP+TLS warm),
# can shard parallelism when N_TOTAL is large.
echo "phase A.2: PUT empty manifest 1 for $N_TOTAL tenants via files-server leader…"
# manifest_json.zig schema: {v, deployment_id, entries}. Empty
# entries = no handlers + no static files → reload returns
# success with no bytecodes. Worker can boot / reload without
# logging InvalidManifest warnings.
#
# Single curl invocation reads a `--config` file with N requests,
# each separated by `next`. curl reuses the TLS connection across
# them — at parallel-curl-per-PUT (xargs) we'd open N fresh TLS
# handshakes and the rove-h2 server's per-second new-connection
# accept budget caps out. Persistent connection sidesteps that.
EMPTY_MANIFEST_FILE=$(mktemp --suffix=.json)
printf '{"v":1,"deployment_id":1,"entries":[]}' > "$EMPTY_MANIFEST_FILE"
CURL_CONFIG=$(mktemp --suffix=.curlcfg)
# `next` separates requests; the last must NOT be followed by
# `next` or curl errors with "no URL specified". Build with
# leading `next` (skipped on the first iteration) instead of a
# trailing one.
{
    echo "silent"
    echo "max-time = 60"
    echo "connect-timeout = 5"
    echo "cacert = \"${CACERT}\""
    for (( i = 0; i < N_TOTAL; i++ )); do
        if (( i > 0 )); then echo "next"; fi
        tid=$(printf "t%05d" "$i")
        cat <<CFG
url = "https://127.0.0.1:${FS_LEADER_PORT}/${tid}/deployments/1/manifest.bin"
request = "PUT"
data-binary = "@${EMPTY_MANIFEST_FILE}"
header = "Authorization: Bearer ${FS_JWT}"
header = "Content-Type: application/octet-stream"
CFG
    done
} > "$CURL_CONFIG"

t_mf_start=$(date +%s)
CURL_OUT="/tmp/${SMOKE_TAG}-put-out.log"
# Bodies stream to stdout. Each successful PUT's body is exactly
# `committed at seq=N\n`. Counting those lines = success count.
# Per-request `-w` write-outs only fire for the LAST request when
# config-file `next`-separated; bodies are reliable per-request.
curl -K "$CURL_CONFIG" > "$CURL_OUT" 2>&1 || true
t_mf_end=$(date +%s)
rm -f "$EMPTY_MANIFEST_FILE" "$CURL_CONFIG"

ok_count=$(grep -c '^committed at seq=' "$CURL_OUT" || echo 0)
echo "  $N_TOTAL manifest PUTs (raft-replicated) in $((t_mf_end - t_mf_start))s — $ok_count committed"
if (( ok_count != N_TOTAL )); then
    echo "FAIL: $((N_TOTAL - ok_count)) PUTs did not commit (no 'committed at seq=' line)" >&2
    grep -v '^committed at seq=' "$CURL_OUT" | head -10 >&2
    exit 1
fi
rm -f "$CURL_OUT"

# ── Phase B: spawn workers ─────────────────────────────────────────
# (LOOP46_SERVICES_JWT_SECRET + LOOP46_ROOT_TOKEN already exported
# above so the files-server cluster boot used the same shared
# secrets.)

PIDS=()
echo "phase B: starting 3-node loop46 cluster, --snapshot-interval-ms=$SNAPSHOT_INTERVAL_MS…"
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
        --files-internal-base "https://${FS_HTTP_ADDRS[0]}" \
        --files-internal-insecure-tls \
        "${RAFT_TIMING_FLAGS[@]}" \
        >"/tmp/${SMOKE_TAG}-worker-${i}.out" 2>&1 &
    PIDS+=($!)
done
sleep 2

RESOLVE=()
for h in "${HTTP_ADDRS[@]}"; do
    p="${h##*:}"
    RESOLVE+=(--resolve "app.loop46.localhost:${p}:127.0.0.1")
done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}" --max-time 30)
# Worker startup walks data_dir and opens every tenant's app.db
# at boot. At 10k tenants this can take 30-60+ seconds before the
# /_system/leader endpoint responds 200. Scale leader-discovery
# timeout proportionally so the bench works at any density.
# Floor 15s (default) for small clusters, ~1s per 100 tenants
# above that.
export LEADER_DISCOVER_TIMEOUT_S=$(( 15 + N_TOTAL / 100 ))
echo "  leader-discovery timeout: ${LEADER_DISCOVER_TIMEOUT_S}s (scaled for $N_TOTAL tenants)"
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
