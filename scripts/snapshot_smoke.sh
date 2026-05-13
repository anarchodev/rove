#!/usr/bin/env bash
# End-to-end smoke for the snapshot capture + restore round-trip.
# Phase 5.5(c) steps 3a + 4 + S3 wiring.
#
# Drives the full operator flow:
#   1. `loop46 seed` provisions a tenant on disk
#   2. `loop46 snapshot --data-dir ...` captures it (writes manifest +
#      per-tenant DBs to the S3 snapshot store)
#   3. `loop46 restore-from-snapshot --snap-id ...` installs into a
#      fresh data dir
#   4. Verify the restored db has the same state as the source

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-snapshot-smoke}"
RESTORE_DIR="${RESTORE_DIR:-/tmp/rove-snapshot-restored}"
BIN="${BIN:-./zig-out/bin/loop46}"

if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN missing — run 'zig build install' first" >&2
    exit 2
fi
# Source .env early so the standalone `loop46 snapshot` /
# `restore-from-snapshot` CLI calls below see S3 creds.
__snap_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${__snap_repo_root}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${__snap_repo_root}/.env"
    set +a
fi
export S3_KEY_PREFIX_BASE="${S3_KEY_PREFIX_BASE:-smoke-snapshot-$(hostname)-$(id -u)/}"

rm -rf "$DATA_DIR" "$RESTORE_DIR"

# ── 1. Seed a tenant + plant kv state via the manifest ─────────────
# `seed_kv` stamps strings into the tenant's app.db. Under kvexp these
# land inside cluster.kv as `acme` store entries; `loop46 kv-get`
# reads them back.
SEED_MANIFEST=$(mktemp --suffix=.json)
trap 'rm -f "$SEED_MANIFEST"' EXIT
cat > "$SEED_MANIFEST" <<'EOF'
{"tenants": [{"id": "acme", "domains": [], "files": [],
              "seed_kv": {"greeting": "hello-from-smoke", "counter": "42"}}]}
EOF
"$BIN" seed --data-dir "$DATA_DIR" --manifest "$SEED_MANIFEST"

# ── 2. Capture via `loop46 snapshot` ───────────────────────────────
SNAP_OUT=$("$BIN" snapshot --data-dir "$DATA_DIR" --apply-position 100 --willemt-term 7 2>&1)
echo "$SNAP_OUT"
SNAP_ID=$(echo "$SNAP_OUT" | awk '/^captured snapshot / {print $3; exit}')
[[ -n "$SNAP_ID" ]] || { echo "FAIL: no snap_id in output" >&2; exit 1; }
echo "ok  loop46 snapshot captured snap_id=$SNAP_ID"

# Snapshots land in S3 — the restore round-trip below is the
# end-to-end verification that the manifest + per-tenant DBs were
# written correctly.

# ── 3. Restore into a fresh data dir ───────────────────────────────
"$BIN" restore-from-snapshot --snap-id "$SNAP_ID" --data-dir "$RESTORE_DIR" 2>&1 | tee /tmp/snapshot-smoke-restore.out

# ── 4. Verify the restored state via `loop46 kv-get` ───────────────
# Under kvexp the restored data lives in cluster.kv; verify via the
# standalone offline reader since no cluster is running here.
got_greeting=$("$BIN" kv-get --data-dir "$RESTORE_DIR" --store acme --key greeting)
got_counter=$( "$BIN" kv-get --data-dir "$RESTORE_DIR" --store acme --key counter)
got_apply=$(   "$BIN" kv-get --data-dir "$RESTORE_DIR" --store acme --apply-idx)

[[ "$got_greeting" == "hello-from-smoke" ]] || { echo "FAIL: greeting='$got_greeting'" >&2; exit 1; }
[[ "$got_counter"  == "42" ]]               || { echo "FAIL: counter='$got_counter'"  >&2; exit 1; }
# `restore` stamps the manifest's durable raft idx to
# `--apply-position`; replay resumes from idx + 1.
[[ "$got_apply"    == "100" ]]              || { echo "FAIL: durable raft idx='$got_apply'" >&2; exit 1; }

echo "ok  greeting='$got_greeting' counter='$got_counter'"
echo "ok  durable raft idx = $got_apply (== --apply-position)"

echo ""
echo "ok  capture + restore round-trip (operator CLI)"

# ── 5. Periodic raft-thread capture (--snapshot-interval-ms) ──────
#
# Phase 5.5(c) step B. Spin up a worker with the in-process
# periodic capture enabled, drive a few raft commits via the
# release POST so willemt has something to snapshot, wait, verify
# that captures landed in the snapshot store AND that willemt's
# snapshot_last_idx advanced past 0 (i.e. log compaction is now
# bounded by our snapshots, not unbounded).
PERIODIC_PREFIX="${PERIODIC_PREFIX:-/tmp/rove-snapshot-periodic}"
PERIODIC_HTTP_BASE="${PERIODIC_HTTP_BASE:-8460}"
PERIODIC_RAFT_BASE="${PERIODIC_RAFT_BASE:-40460}"
PERIODIC_TOKEN=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

if [[ "$(uname -s)" == "Darwin" ]]; then
    LOOP46_DATA="${LOOP46_DATA:-$HOME/Library/Application Support/loop46}"
else
    LOOP46_DATA="${LOOP46_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/loop46}"
fi
TLS_CERT="$LOOP46_DATA/dev-cert.pem"
TLS_KEY="$LOOP46_DATA/dev-key.pem"
CACERT="$LOOP46_DATA/ca-root.pem"

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=snapshot-smoke
SMOKE_PROTO=https
init_cluster_addrs "$PERIODIC_PREFIX" "$PERIODIC_HTTP_BASE" "$PERIODIC_RAFT_BASE"

# Seed acme + quiet onto every node. quiet receives exactly one
# release POST below; after that it never gets another. The
# by-reference reuse path is what we'll verify: subsequent
# manifests must reference the FIRST manifest's quiet/app.db key,
# not re-VACUUM + re-PUT a new copy every interval.
PERIODIC_MANIFEST=$(mktemp --suffix=.json)
cat > "$PERIODIC_MANIFEST" <<'EOF'
{"tenants":[
  {"id":"acme","domains":[],"files":[]},
  {"id":"quiet","domains":[],"files":[]}
]}
EOF
seed_all_dirs "$PERIODIC_MANIFEST"
rm -f "$PERIODIC_MANIFEST"

export LOOP46_SERVICES_JWT_SECRET=$(head -c32 /dev/urandom | xxd -p | tr -d '\n')
export LOOP46_ROOT_TOKEN="$PERIODIC_TOKEN"

PIDS=()
for i in 0 1 2; do
    "$BIN" worker \
        --node-id "$i" \
        --peers "$PEERS_CSV" \
        --listen "${RAFT_ADDRS[$i]}" \
        --http "${HTTP_ADDRS[$i]}" \
        --data-dir "${DATA_DIRS[$i]}" \
        --public-suffix loop46.localhost \
        --snapshot-interval-ms 500 \
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
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}" --max-time 5)
discover_leader "app.loop46.localhost" "$PERIODIC_TOKEN" || exit 1
echo "ok  periodic-loop leader: node $LEADER_IDX at $LEADER_HTTP"
LEADER_DIR="${DATA_DIRS[$LEADER_IDX]}"

# Drive a first batch of raft commits so willemt has > 1 log entry
# (begin_snapshot returns -1 below that threshold — willemt's invariant,
# not ours), then wait for the periodic capture loop to fire at least
# once. The PRE_BURST commits are what the FIRST snapshot pass compacts
# away, so we record raft.log.db's row count + file size after that
# bootstrap window — that's our baseline for "compaction is bounded."
#
# One write to `quiet` first, then nothing — that gets it into
# ApplyCtx.kv_stores so it appears in subsequent manifests, while
# leaving its tenant_apply_idx fixed once written. After the first
# capture all subsequent captures should reuse quiet's db_key by
# reference (verified at the end of this section against S3).
"${CURL[@]}" \
    -H "Authorization: Bearer $PERIODIC_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"tenant_id":"quiet","dep_id":1}' \
    "https://app.loop46.localhost:${LEADER_PORT}/_system/release" >/dev/null

PRE_BURST=20
for i in $(seq 1 $PRE_BURST); do
    "${CURL[@]}" \
        -H "Authorization: Bearer $PERIODIC_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"tenant_id\":\"acme\",\"dep_id\":$i}" \
        "https://app.loop46.localhost:${LEADER_PORT}/_system/release" >/dev/null
done
sleep 3

# tickRaftCapture now logs `snapshot tick apply_position=N stamped_tenants=K
# stamped_root=B duration_ms=M` (per docs/production.md #1.1: stamp-and-
# compact, no byte capture). Verify the leader fired at least one tick.
TICK_LOGS=$(awk '/snapshot tick apply_position=/ {n++} END {print n+0}' \
    "/tmp/${SMOKE_TAG}-worker-${LEADER_IDX}.out")
if (( TICK_LOGS < 1 )); then
    echo "FAIL: no 'snapshot tick' log lines on leader" >&2
    tail -30 "/tmp/${SMOKE_TAG}-worker-${LEADER_IDX}.out" >&2
    exit 1
fi
echo "ok  worker logged $TICK_LOGS tick(s) after burst-1"

# Pass duration must be well under the willemt election timeout —
# that's the load-bearing property of #1.1. Expectation: tens of
# milliseconds for a few-tenant cluster, never seconds. Check the
# max across all ticks.
MAX_DURATION=$(awk '/snapshot tick apply_position=/ {
    for (i=1;i<=NF;i++) if (substr($i,1,12)=="duration_ms=") {
        d=substr($i,13)+0; if (d>m) m=d
    }
} END {print m+0}' "/tmp/${SMOKE_TAG}-worker-${LEADER_IDX}.out")
if (( MAX_DURATION > 1000 )); then
    echo "FAIL: max snapshot tick duration ($MAX_DURATION ms) > 1000 ms" >&2
    echo "      — pass should be ~ms not seconds; check that nothing is" >&2
    echo "      doing per-tenant S3 work on the raft thread again." >&2
    exit 1
fi
echo "ok  max snapshot tick duration: ${MAX_DURATION}ms (well under heartbeat budget)"

# ── 6. Verify raft.log.db actually compacts (rows + file size) ────
#
# Without `compactLogPages`, willemt's `cbLogPoll` still DELETEs rows
# but the SQLite file keeps growing forever — the freed pages stay on
# the freelist. Drive a much larger second burst, wait for snapshots,
# then verify both row count and file size are bounded.
RAFT_LOG="$LEADER_DIR/raft.log.db"
[[ -f "$RAFT_LOG" ]] || { echo "FAIL: $RAFT_LOG missing" >&2; exit 1; }

ROWS_BASELINE=$(sqlite3 "$RAFT_LOG" "SELECT COUNT(*) FROM raft_log;")
SIZE_BASELINE=$(stat -c %s "$RAFT_LOG" 2>/dev/null || stat -f %z "$RAFT_LOG")
echo "ok  baseline after burst-1: rows=$ROWS_BASELINE size=$SIZE_BASELINE bytes"

# Drive a much larger second burst — 5x the first. Without
# compaction, rows + size would grow ~5x.
POST_BURST=100
for i in $(seq $((PRE_BURST + 1)) $((PRE_BURST + POST_BURST))); do
    "${CURL[@]}" \
        -H "Authorization: Bearer $PERIODIC_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"tenant_id\":\"acme\",\"dep_id\":$i}" \
        "https://app.loop46.localhost:${LEADER_PORT}/_system/release" >/dev/null
done
# Wait long enough for the periodic loop (--snapshot-interval-ms 500)
# to fire at least 3 more times after the burst settles.
sleep 4

ROWS_AFTER=$(sqlite3 "$RAFT_LOG" "SELECT COUNT(*) FROM raft_log;")
SIZE_AFTER=$(stat -c %s "$RAFT_LOG" 2>/dev/null || stat -f %z "$RAFT_LOG")
echo "ok  after burst-2 (+$POST_BURST commits): rows=$ROWS_AFTER size=$SIZE_AFTER bytes"

# Row count should be bounded — at most a small handful of post-snapshot
# entries, NOT proportional to total commits (PRE_BURST + POST_BURST = 120).
# Allow a generous ceiling (~PRE_BURST) to absorb in-flight entries
# captured between begin_snapshot and end_snapshot on the last pass.
if [[ "$ROWS_AFTER" -gt $PRE_BURST ]]; then
    echo "FAIL: raft_log row count ($ROWS_AFTER) > $PRE_BURST after compaction" >&2
    echo "      compaction is NOT bounded — willemt's log_poll chain or" >&2
    echo "      RaftLog.truncateBefore is not firing as expected." >&2
    exit 1
fi
echo "ok  raft_log row count bounded after compaction ($ROWS_AFTER <= $PRE_BURST)"

# File size growth should also be bounded. With auto_vacuum=INCREMENTAL +
# compactPages, the file should be at most ~2x the baseline (some
# slack for WAL fragmentation between checkpoints). Without
# auto_vacuum + incremental_vacuum, growth would be roughly proportional
# to total commits — well past 2x.
SIZE_CEILING=$((SIZE_BASELINE * 3))
if [[ "$SIZE_AFTER" -gt "$SIZE_CEILING" ]]; then
    echo "FAIL: raft.log.db size ($SIZE_AFTER) > ${SIZE_CEILING} (3x baseline $SIZE_BASELINE)" >&2
    echo "      incremental_vacuum is not releasing freed pages — check" >&2
    echo "      auto_vacuum=INCREMENTAL was set on the fresh DB and" >&2
    echo "      RaftNode.compactLogPages() is being called after each" >&2
    echo "      successful endSnapshotOpaque." >&2
    exit 1
fi
echo "ok  raft.log.db file size bounded after compaction ($SIZE_AFTER <= ${SIZE_CEILING})"

# Confirm the auto_vacuum mode is actually INCREMENTAL on disk — guards
# against a future regression where someone disables the PRAGMA.
AV_MODE=$(sqlite3 "$RAFT_LOG" "PRAGMA auto_vacuum;")
[[ "$AV_MODE" == "2" ]] || { echo "FAIL: auto_vacuum=$AV_MODE on raft.log.db (want 2 = INCREMENTAL)" >&2; exit 1; }
echo "ok  raft.log.db auto_vacuum=INCREMENTAL"

# ── 7. Verify the snapshot tick is stamping the durable raft idx ──
#
# Under kvexp the per-tenant `_apply_state` is gone — the cluster has
# a single durable raft idx in `cluster.kv`, stamped atomically by
# `Manifest.durabilize(apply_position)`. After the burst the latest
# tick's apply_position should be reflected on disk. Shut the
# cluster down so the standalone `loop46 kv-get` can open the env.
LATEST_APPLY_POS=$(awk '/snapshot tick apply_position=/ {
    for (i=1;i<=NF;i++) if (substr($i,1,15)=="apply_position=") {
        a=substr($i,16)+0; if (a>m) m=a
    }
} END {print m+0}' "/tmp/${SMOKE_TAG}-worker-${LEADER_IDX}.out")
if (( LATEST_APPLY_POS == 0 )); then
    echo "FAIL: could not parse apply_position from snapshot tick logs" >&2
    exit 1
fi
echo "ok  latest snapshot tick apply_position=$LATEST_APPLY_POS"

# Shut down all nodes — kvexp's MDB_NOLOCK means we can't open
# cluster.kv from a second process while the cluster is running.
for p in "${PIDS[@]}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
for p in "${PIDS[@]}"; do [ -n "$p" ] && wait "$p" 2>/dev/null || true; done
# Clear PIDS so the EXIT trap doesn't try again.
PIDS=()

DURABLE_IDX=$("$BIN" kv-get --data-dir "$LEADER_DIR" --store __root__ --apply-idx)
echo "  cluster.kv durable raft idx = $DURABLE_IDX"

# The durable idx should be at or above the latest tick's
# apply_position. A small grace covers the race where a tick fires
# between the burst's last commit and our log parse.
GRACE=1
if (( DURABLE_IDX + GRACE < LATEST_APPLY_POS )); then
    echo "FAIL: durable raft idx ($DURABLE_IDX) < latest_apply_position ($LATEST_APPLY_POS)" >&2
    exit 1
fi
echo "ok  durable raft idx ($DURABLE_IDX) >= latest tick apply_position ($LATEST_APPLY_POS - $GRACE)"

echo ""
echo "PASS snapshot smoke"
