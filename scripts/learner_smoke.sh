#!/usr/bin/env bash
# Non-voting learner smoke (production.md #1.2). Stands up a
# 3-voter + 1-learner cluster and verifies:
#
#   1. The cluster elects a leader from the 3 voters (the learner
#      doesn't count toward quorum).
#   2. Writes that go to the leader replicate to the learner —
#      the learner's `_apply_state.last_applied_raft_idx` advances
#      in lockstep with the voters'.
#   3. The learner's app.db has the same kv content as a voter
#      (verified via direct sqlite3 read of a planted row).
#
# What this does NOT verify (defer to the promotion-endpoint
# follow-up):
#   - Killing 2/3 voters loses quorum.
#   - Promoting the learner restores quorum.
# Both need an admin endpoint that calls `raft_node_set_voting`,
# which doesn't exist yet.
#
# Uses port bases 8480/40480 to avoid conflict with other
# in-flight smokes / benches.

set -euo pipefail

BIN="${BIN:-./zig-out/bin/loop46}"
if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN missing — run 'zig build install' first" >&2
    exit 2
fi
command -v sqlite3 >/dev/null 2>&1 || { echo "error: sqlite3 not in PATH" >&2; exit 2; }

PREFIX="${PREFIX:-/tmp/rove-learner-smoke}"
HTTP_BASE="${HTTP_BASE:-8480}"
RAFT_BASE="${RAFT_BASE:-40480}"
ROOT_TOKEN=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

if [[ "$(uname -s)" == "Darwin" ]]; then
    LOOP46_DATA="${LOOP46_DATA:-$HOME/Library/Application Support/loop46}"
else
    LOOP46_DATA="${LOOP46_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/loop46}"
fi
TLS_CERT="$LOOP46_DATA/dev-cert.pem"
TLS_KEY="$LOOP46_DATA/dev-key.pem"
CACERT="$LOOP46_DATA/ca-root.pem"

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=learner-smoke
SMOKE_PROTO=https

# ── 4-node addressing (3 voters + 1 learner) ──────────────────────
# init_cluster_addrs is hardcoded for 3 nodes; build our own.
HTTP_ADDRS=(); RAFT_ADDRS=(); DATA_DIRS=()
for i in 0 1 2 3; do
    HTTP_ADDRS+=("127.0.0.1:$((HTTP_BASE + i))")
    RAFT_ADDRS+=("127.0.0.1:$((RAFT_BASE + i))")
    DATA_DIRS+=("${PREFIX}-${i}")
done
rm -rf "${DATA_DIRS[@]}"
# Voters are 0/1/2; learner is 3. Encode in --peers.
PEERS_CSV="${RAFT_ADDRS[0]},${RAFT_ADDRS[1]},${RAFT_ADDRS[2]},${RAFT_ADDRS[3]}:learner"
echo "peers: $PEERS_CSV"

if [[ -z "${RAFT_TIMING_FLAGS+x}" ]]; then
    RAFT_TIMING_FLAGS=(--election-timeout-ms 200 --heartbeat-ms 50)
fi

# ── Seed acme onto every node (incl. learner) ─────────────────────
SEED_MANIFEST=$(mktemp --suffix=.json)
echo '{"tenants":[{"id":"acme","domains":[],"files":[]}]}' > "$SEED_MANIFEST"
trap 'rm -f "$SEED_MANIFEST"' EXIT
echo "seeding 4 nodes (acme tenant only)…"
# Serial first node creates S3 manifest; rest parallel hits the
# fast-path. Same shape as the scalability bench's seed strategy.
"$BIN" seed --data-dir "${DATA_DIRS[0]}" --manifest "$SEED_MANIFEST" >/dev/null
SEED_PIDS=()
for d in "${DATA_DIRS[@]:1}"; do
    "$BIN" seed --data-dir "$d" --manifest "$SEED_MANIFEST" >/dev/null &
    SEED_PIDS+=($!)
done
for p in "${SEED_PIDS[@]}"; do wait "$p"; done
rm -f "$SEED_MANIFEST"
echo "ok  4 dirs seeded"

# Per-smoke S3 prefix so this run's bootstrap state is isolated.
export S3_KEY_PREFIX_BASE="smoke-learner-$(hostname)-$(id -u)/"

# ── Spawn workers ─────────────────────────────────────────────────
export LOOP46_SERVICES_JWT_SECRET=$(head -c32 /dev/urandom | xxd -p | tr -d '\n')
export LOOP46_ROOT_TOKEN="$ROOT_TOKEN"
PIDS=()
for i in 0 1 2 3; do
    role="voter"
    [[ "$i" == "3" ]] && role="learner"
    "$BIN" worker \
        --node-id "$i" \
        --peers "$PEERS_CSV" \
        --listen "${RAFT_ADDRS[$i]}" \
        --http "${HTTP_ADDRS[$i]}" \
        --data-dir "${DATA_DIRS[$i]}" \
        --public-suffix loop46.localhost \
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
sleep 3

# ── Discover leader (must be one of nodes 0/1/2 — NOT the learner) ─
RESOLVE=()
for h in "${HTTP_ADDRS[@]}"; do
    p="${h##*:}"
    RESOLVE+=(--resolve "app.loop46.localhost:${p}:127.0.0.1")
done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}" --max-time 5)

LEADER_IDX=""
LEADER_HTTP=""
for tries in $(seq 1 30); do
    for i in 0 1 2 3; do
        h="${HTTP_ADDRS[$i]}"
        p="${h##*:}"
        if "${CURL[@]}" -H "Authorization: Bearer $ROOT_TOKEN" \
            "https://app.loop46.localhost:${p}/_system/leader" 2>/dev/null \
            | grep -q '"is_leader":true'; then
            LEADER_IDX=$i
            LEADER_HTTP=$h
            break 2
        fi
    done
    sleep 0.5
done
[[ -n "$LEADER_IDX" ]] || { echo "FAIL: no leader elected within 15s" >&2; exit 1; }
echo "ok  leader: node $LEADER_IDX at $LEADER_HTTP"

if [[ "$LEADER_IDX" == "3" ]]; then
    echo "FAIL: learner (node 3) became leader — it shouldn't have a vote" >&2
    exit 1
fi
echo "ok  learner did not become leader (only voters 0/1/2 are election candidates)"

# ── Drive some commits via _system/release against acme ───────────
LEADER_PORT="${LEADER_HTTP##*:}"
COMMITS=10
for i in $(seq 1 $COMMITS); do
    "${CURL[@]}" \
        -H "Authorization: Bearer $ROOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"tenant_id\":\"acme\",\"dep_id\":$i}" \
        "https://app.loop46.localhost:${LEADER_PORT}/_system/release" >/dev/null
done
echo "ok  drove $COMMITS release POSTs through the leader"

# Give applies time to land on every node (including learner).
sleep 3

# ── Verify learner's app.db reflects the same state ───────────────
LEARNER_DIR="${DATA_DIRS[3]}"
LEARNER_ACME_DB="$LEARNER_DIR/acme/app.db"
[[ -f "$LEARNER_ACME_DB" ]] || {
    echo "FAIL: learner's acme/app.db missing — applies didn't land on the learner" >&2
    exit 1
}

LEARNER_DEPLOY=$(sqlite3 "$LEARNER_ACME_DB" \
    "SELECT value FROM kv WHERE key='_deploy/current';" 2>/dev/null || echo "")
LEARNER_APPLY_IDX=$(sqlite3 "$LEARNER_ACME_DB" \
    "SELECT v FROM _apply_state WHERE k='last_applied_raft_idx';" 2>/dev/null || echo 0)

# Pick any voter that's not the leader to compare against.
COMPARE_IDX=0
[[ "$LEADER_IDX" == "0" ]] && COMPARE_IDX=1
COMPARE_DB="${DATA_DIRS[$COMPARE_IDX]}/acme/app.db"
COMPARE_DEPLOY=$(sqlite3 "$COMPARE_DB" \
    "SELECT value FROM kv WHERE key='_deploy/current';" 2>/dev/null || echo "")
COMPARE_APPLY_IDX=$(sqlite3 "$COMPARE_DB" \
    "SELECT v FROM _apply_state WHERE k='last_applied_raft_idx';" 2>/dev/null || echo 0)

echo "  voter   $COMPARE_IDX: _deploy/current=$COMPARE_DEPLOY apply_idx=$COMPARE_APPLY_IDX"
echo "  learner 3: _deploy/current=$LEARNER_DEPLOY apply_idx=$LEARNER_APPLY_IDX"

if [[ "$LEARNER_DEPLOY" != "$COMPARE_DEPLOY" ]]; then
    echo "FAIL: learner's _deploy/current ($LEARNER_DEPLOY) != voter's ($COMPARE_DEPLOY)" >&2
    exit 1
fi

# Apply idx may be slightly behind on the learner (no quorum
# pressure to catch it up immediately) but should be close.
if (( LEARNER_APPLY_IDX + 5 < COMPARE_APPLY_IDX )); then
    echo "FAIL: learner apply_idx ($LEARNER_APPLY_IDX) significantly behind voter ($COMPARE_APPLY_IDX)" >&2
    exit 1
fi

echo "ok  learner replicated $COMMITS releases (deploy_id matches; apply_idx within 5 of voter)"

# Last expected dep_id is the COMMITS value padded to 16 hex.
EXPECTED_DEPLOY=$(printf '%016x' "$COMMITS")
if [[ "$LEARNER_DEPLOY" != "$EXPECTED_DEPLOY" ]]; then
    echo "FAIL: learner _deploy/current ($LEARNER_DEPLOY) != expected ($EXPECTED_DEPLOY)" >&2
    exit 1
fi
echo "ok  learner _deploy/current = expected $EXPECTED_DEPLOY"

echo ""
echo "PASS learner smoke"
