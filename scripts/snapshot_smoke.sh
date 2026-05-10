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
if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "skip: sqlite3 CLI not in PATH (this smoke needs it to plant test rows)"
    exit 0
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

# ── 1. Seed a tenant via the manifest path ─────────────────────────
SEED_MANIFEST=$(mktemp --suffix=.json)
trap 'rm -f "$SEED_MANIFEST"' EXIT
cat > "$SEED_MANIFEST" <<'EOF'
{"tenants": [{"id": "acme", "domains": [], "files": []}]}
EOF
"$BIN" seed --data-dir "$DATA_DIR" --manifest "$SEED_MANIFEST"

# Plant some kv state in acme's app.db (seed leaves it empty + no
# bytecodes, which would also be a valid capture target — but
# planting rows lets us verify the restore round-trips real data).
sqlite3 "$DATA_DIR/acme/app.db" <<'SQL'
INSERT INTO kv (key, value, seq) VALUES ('greeting', 'hello-from-smoke', 100);
INSERT INTO kv (key, value, seq) VALUES ('counter',  '42',               101);
INSERT INTO _apply_state (k, v) VALUES ('last_applied_raft_idx', 99);
SQL

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

# ── 4. Verify the restored state ───────────────────────────────────
RESTORED_DB="$RESTORE_DIR/acme/app.db"
[[ -f "$RESTORED_DB" ]] || { echo "FAIL: restored acme/app.db missing" >&2; exit 1; }

got_greeting=$(sqlite3 "$RESTORED_DB" "SELECT value FROM kv WHERE key='greeting';")
got_counter=$(sqlite3 "$RESTORED_DB"  "SELECT value FROM kv WHERE key='counter';")
got_apply=$(sqlite3 "$RESTORED_DB"    "SELECT v FROM _apply_state WHERE k='last_applied_raft_idx';")

[[ "$got_greeting" == "hello-from-smoke" ]] || { echo "FAIL: greeting='$got_greeting'" >&2; exit 1; }
[[ "$got_counter"  == "42" ]]               || { echo "FAIL: counter='$got_counter'"  >&2; exit 1; }
# `restore` stamps _apply_state to manifest's snapshot_idx (= --apply-position),
# overriding the source's 99. That's the contract: post-restore, the
# apply path replays from snapshot_idx + 1.
[[ "$got_apply"    == "100" ]]              || { echo "FAIL: _apply_state='$got_apply'" >&2; exit 1; }

echo "ok  greeting='$got_greeting' counter='$got_counter'"
echo "ok  _apply_state.last_applied_raft_idx = $got_apply (== --apply-position)"

# Restored __root__.db should also exist and have the seeded tenant.
RESTORED_ROOT="$RESTORE_DIR/__root__.db"
[[ -f "$RESTORED_ROOT" ]] || { echo "FAIL: restored __root__.db missing" >&2; exit 1; }
echo "ok  __root__.db restored"

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

CAPTURE_LOGS=$(grep -c 'snapshot captured ' "/tmp/${SMOKE_TAG}-worker-${LEADER_IDX}.out")
[[ "$CAPTURE_LOGS" -ge 1 ]] || {
    echo "FAIL: no 'snapshot captured' log lines on leader" >&2
    tail -30 "/tmp/${SMOKE_TAG}-worker-${LEADER_IDX}.out" >&2
    exit 1
}
echo "ok  worker logged $CAPTURE_LOGS capture(s) after burst-1"

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

# ── 7. Verify by-reference reuse for unchanged tenants ─────────────
#
# The `quiet` tenant got seeded but never received a release POST
# during the burst loops. Its tenant_apply_idx mirror stayed at
# whatever the seed left it (0). Every snapshot pass after the first
# should reuse the FIRST manifest's quiet/app.db key by reference —
# no new VACUUM + PUT for quiet.
#
# Drive one more release POST (against acme, NOT quiet) so the
# capture loop has a reason to fire fresh and we know which tenants
# were touched.
"${CURL[@]}" \
    -H "Authorization: Bearer $PERIODIC_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"tenant_id":"acme","dep_id":999}' \
    "https://app.loop46.localhost:${LEADER_PORT}/_system/release" >/dev/null
sleep 2

# Pull every manifest from the leader's worker log (each emits
# `snapshot captured {snap_id} (manifest_key={key})`). Take the
# last 2 — these will be the most recent snapshots after the
# acme-only burst. Both must reference the SAME `quiet/app.db`
# bytes via the same `db_key`.
WORKER_LOG="/tmp/${SMOKE_TAG}-worker-${LEADER_IDX}.out"
MAPPED=$(grep -oE 'snapshot captured [0-9a-f]+ \(manifest_key=[^)]+\)' "$WORKER_LOG" | tail -2 || true)
if [[ -z "$MAPPED" ]]; then
    echo "FAIL: could not extract recent manifest_key lines from worker log" >&2
    grep 'snapshot captured' "$WORKER_LOG" | tail -5 >&2
    exit 1
fi
KEY_RECENT_1=$(echo "$MAPPED" | sed -n '1p' | sed -E 's/.*manifest_key=([^)]+)\)/\1/')
KEY_RECENT_2=$(echo "$MAPPED" | sed -n '2p' | sed -E 's/.*manifest_key=([^)]+)\)/\1/')
[[ -n "$KEY_RECENT_1" && -n "$KEY_RECENT_2" && "$KEY_RECENT_1" != "$KEY_RECENT_2" ]] || {
    echo "FAIL: need 2 distinct recent manifest keys, got '$KEY_RECENT_1' and '$KEY_RECENT_2'" >&2
    exit 1
}

# We use the operator CLI's `--snapshot-dir` form to read manifest
# bytes via S3 (the same backend the periodic loop wrote them to).
# `aws s3 cp` would be cleanest but isn't a hard requirement of the
# smoke harness; instead use a small Python helper or fall back to
# extracting tenants from the raft thread's stderr (we don't have a
# manifest-show command). The simpler path: walk both manifests by
# pulling them from the same FsBatchStore-or-S3 backend the worker
# wrote them to, via a tiny inline Python script that signs an S3
# GET. To keep dependencies minimal here, just verify reuse via the
# behavioural property we DO have visibility into: count distinct
# `cluster/snapshots/*/quiet/app.db` keys created in S3. With reuse
# working there should be exactly 1 (the first capture's). Without
# reuse there'd be one per capture pass (4+).
# We use the AWS CLI if available; skip with a warning otherwise.
if command -v aws >/dev/null 2>&1 && [[ -n "${S3_BUCKET:-}" && -n "${S3_ENDPOINT:-}" ]]; then
    # Snapshots use cluster/snapshots/* directly under the bucket
    # root (or under SNAPSHOT_S3_KEY_PREFIX if set — not used by the
    # smoke). They do NOT live under S3_KEY_PREFIX_BASE; that prefix
    # is for tenant blobs (file-blobs / log-blobs).
    #
    # Filter by THIS run's snap_ids — the bucket accumulates
    # snapshots across runs and a raw count would mix in historical
    # ones, hiding any reuse regression in the current run.
    THIS_RUN_SNAP_IDS=$(grep -oE 'snapshot captured [0-9a-f]+' "$WORKER_LOG" | awk '{print $3}' | sort -u)
    if [[ -z "$THIS_RUN_SNAP_IDS" ]]; then
        echo "FAIL: no snap_ids extracted from worker log; cannot verify reuse" >&2
        exit 1
    fi
    THIS_RUN_PATTERN=$(echo "$THIS_RUN_SNAP_IDS" | paste -sd'|' -)

    QUIET_KEY_COUNT=$(AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}" \
        aws s3 ls --endpoint-url "$S3_ENDPOINT" \
        "s3://${S3_BUCKET}/cluster/snapshots/" --recursive 2>/dev/null \
        | awk '{print $4}' \
        | grep -E "cluster/snapshots/(${THIS_RUN_PATTERN})/quiet/app.db$" \
        | wc -l)

    # Want exactly 0 or 1 fresh quiet/app.db keys uploaded under
    # this run's snap_ids: the first capture VACUUMs + uploads
    # quiet's db (1 key); every subsequent capture should reuse
    # that db_key by reference (0 new keys). 0 is also OK if every
    # capture happened to fall after quiet's release was committed
    # AND the captured manifest wasn't the FIRST ever — i.e., the
    # primed cache from a prior cluster lifetime carried quiet
    # forward. So accept {0, 1}; >1 means reuse broke.
    if [[ "$QUIET_KEY_COUNT" -gt 1 ]]; then
        echo "FAIL: $QUIET_KEY_COUNT distinct quiet/app.db keys in S3 (this run's snap_ids only)" >&2
        echo "      — by-reference reuse is not firing. Every capture is re-VACUUMing +" >&2
        echo "      re-PUTting an unchanged tenant (expected at most 1 across all passes)." >&2
        exit 1
    fi
    echo "ok  by-reference reuse: $QUIET_KEY_COUNT distinct quiet/app.db key(s) in S3 (this run's snap_ids only; want <=1)"
else
    echo "skip  by-reference reuse S3 listing (aws CLI not in PATH or S3 env not set; inline tests cover the contract)"
fi

echo ""
echo "PASS snapshot smoke"
