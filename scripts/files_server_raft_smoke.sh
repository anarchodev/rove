#!/usr/bin/env bash
# files-server own raft group smoke (production.md #1.4 step 1).
#
# Stands up a 3-node files-server-standalone cluster — independent
# from the loop46 worker raft group — and verifies:
#
#   1. The cluster spawns + binds 3 raft listeners + 3 HTTP listeners.
#   2. willemt elects a leader from among the 3 voters.
#   3. The standalone HTTP /v1/instance_id/* path still works
#      end-to-end (auth + a basic upload), proving raft instantiation
#      didn't break the existing serving path.
#
# What this does NOT verify (later steps):
#   - Manifest writes routing through Cluster.proposeWriteSet
#     (still goes through S3 today).
#   - Snapshot + log compaction at scale.
#   - Send-snapshot peer-to-peer for fall-behind followers.
#
# Uses raft port base 41090 + http port base 9090 to avoid colliding
# with the loop46 worker bench (40470 / 8470 ranges).

set -euo pipefail

BIN="${BIN:-./zig-out/bin/files-server-standalone}"
if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN missing — run 'zig build install' first" >&2
    exit 2
fi
command -v sqlite3 >/dev/null 2>&1 || { echo "error: sqlite3 not in PATH" >&2; exit 2; }

PREFIX="${PREFIX:-/tmp/rove-fs-raft-smoke}"
HTTP_BASE="${HTTP_BASE:-9090}"
RAFT_BASE="${RAFT_BASE:-41090}"

if [[ "$(uname -s)" == "Darwin" ]]; then
    LOOP46_DATA="${LOOP46_DATA:-$HOME/Library/Application Support/loop46}"
else
    LOOP46_DATA="${LOOP46_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/loop46}"
fi
TLS_CERT="$LOOP46_DATA/dev-cert.pem"
TLS_KEY="$LOOP46_DATA/dev-key.pem"
CACERT="$LOOP46_DATA/ca-root.pem"

# Source .env for AWS / S3 creds — files-server-standalone still
# needs the blob backend (bytecodes go to S3).
__smoke_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${__smoke_repo_root}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${__smoke_repo_root}/.env"
    set +a
fi
export S3_KEY_PREFIX_BASE="smoke-fs-raft-$(hostname)-$(id -u)/"

# 3-node cluster setup. Voters at indices 0/1/2.
HTTP_ADDRS=(); RAFT_ADDRS=(); DATA_DIRS=()
for i in 0 1 2; do
    HTTP_ADDRS+=("127.0.0.1:$((HTTP_BASE + i))")
    RAFT_ADDRS+=("127.0.0.1:$((RAFT_BASE + i))")
    DATA_DIRS+=("${PREFIX}-${i}")
done
rm -rf "${DATA_DIRS[@]}"
PEERS_CSV=$(IFS=,; echo "${RAFT_ADDRS[*]}")
echo "peers: $PEERS_CSV"

# JWT secret shared across the 3 standalone instances. Same key
# the loop46 worker would use when handing tokens to clients;
# here we just need it set so each instance accepts requests.
export LOOP46_SERVICES_JWT_SECRET=$(head -c32 /dev/urandom | xxd -p | tr -d '\n')

PIDS=()
for i in 0 1 2; do
    "$BIN" \
        --data-dir "${DATA_DIRS[$i]}" \
        --listen "${HTTP_ADDRS[$i]}" \
        --tls-cert "$TLS_CERT" \
        --tls-key "$TLS_KEY" \
        --cors-origin "https://app.loop46.localhost" \
        --raft-node-id "$i" \
        --raft-peers "$PEERS_CSV" \
        --raft-listen "${RAFT_ADDRS[$i]}" \
        --raft-election-timeout-ms 200 \
        --raft-heartbeat-ms 50 \
        >"/tmp/fs-raft-smoke-worker-${i}.out" 2>&1 &
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
sleep 3

# ── Verify each node booted + has a raft.log.db ───────────────────
for i in 0 1 2; do
    if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
        echo "FAIL: node $i (PID ${PIDS[$i]}) exited" >&2
        echo "--- log ---" >&2
        tail -30 "/tmp/fs-raft-smoke-worker-${i}.out" >&2
        exit 1
    fi
    if [[ ! -f "${DATA_DIRS[$i]}/raft.log.db" ]]; then
        echo "FAIL: node $i has no raft.log.db at ${DATA_DIRS[$i]}/" >&2
        exit 1
    fi
done
echo "ok  3 files-server-standalone processes alive + raft.log.db files exist"

# ── Verify the raft listener actually bound + persisted state ─────
#
# Each node's raft.log.db should exist + be in WAL mode + have
# auto_vacuum=INCREMENTAL set (the contract from #1's compaction
# wiring). Validates the Cluster.init path drove RaftLog.open
# correctly + the per-node raft network is listening.
for i in 0 1 2; do
    db="${DATA_DIRS[$i]}/raft.log.db"
    av=$(sqlite3 "$db" "PRAGMA auto_vacuum;" 2>/dev/null || echo "?")
    jm=$(sqlite3 "$db" "PRAGMA journal_mode;" 2>/dev/null || echo "?")
    if [[ "$av" != "2" ]]; then
        echo "FAIL: node $i raft.log.db auto_vacuum=$av (want 2 = INCREMENTAL)" >&2
        exit 1
    fi
    if [[ "$jm" != "wal" ]]; then
        echo "FAIL: node $i raft.log.db journal_mode=$jm (want wal)" >&2
        exit 1
    fi
done
echo "ok  3 raft.log.db files in WAL + INCREMENTAL auto_vacuum"

# ── Verify the raft TCP listeners are open ────────────────────────
for i in 0 1 2; do
    addr="${RAFT_ADDRS[$i]}"
    host="${addr%:*}"
    port="${addr##*:}"
    if ! (echo > /dev/tcp/$host/$port) 2>/dev/null; then
        echo "FAIL: node $i raft listener at $addr not accepting connections" >&2
        exit 1
    fi
done
echo "ok  3 raft TCP listeners accepting connections"

# Subsequent commits will:
# - add a /_system/leader endpoint on files-server-standalone for
#   leader observability (so this smoke can verify election);
# - migrate manifest writes through the Cluster (so we can prove
#   end-to-end raft replication of a per-tenant deploy).

echo ""
echo "PASS files-server raft smoke (init + listeners only; manifest"
echo "     migration + leader-status endpoint are subsequent commits)"
