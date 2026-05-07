#!/usr/bin/env bash
# End-to-end smoke for the snapshot capture + restore round-trip.
# Phase 5.5(c) steps 3a + 4 + S3 wiring.
#
# Drives the full operator flow:
#   1. `loop46 seed` provisions a tenant on disk
#   2. `loop46 snapshot --data-dir ...` captures it (writes manifest +
#      app.db files into the snapshot store under
#      cluster/snapshots/{snap_id}/)
#   3. `loop46 restore-from-snapshot --snap-id ...` installs into a
#      fresh data dir
#   4. Verify the restored db has the same state as the source
#
# Backend defaults to fs (`BLOB_BACKEND` unset). Set BLOB_BACKEND=s3 +
# the standard S3 env vars to drive the real bucket — this same script
# round-trips against either.

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

# In fs mode, verify the manifest landed under the expected on-disk
# key shape. In s3 mode the keys are in the bucket — restore round-
# trip below is the verification.
if [[ "${BLOB_BACKEND:-fs}" == "fs" ]]; then
    MANIFEST_PATH="$DATA_DIR/.snapshots/cluster/snapshots/$SNAP_ID/manifest.json"
    [[ -f "$MANIFEST_PATH" ]] || { echo "FAIL: manifest missing at $MANIFEST_PATH" >&2; exit 1; }
    echo "ok  manifest at $MANIFEST_PATH"
    ACME_PATH="$DATA_DIR/.snapshots/cluster/snapshots/$SNAP_ID/acme/app.db"
    [[ -f "$ACME_PATH" ]] || { echo "FAIL: acme/app.db missing at $ACME_PATH" >&2; exit 1; }
    echo "ok  acme/app.db at $ACME_PATH"
    ROOT_PATH="$DATA_DIR/.snapshots/cluster/snapshots/$SNAP_ID/__root__.db"
    [[ -f "$ROOT_PATH" ]] || { echo "FAIL: __root__.db missing at $ROOT_PATH" >&2; exit 1; }
    echo "ok  __root__.db at $ROOT_PATH"
fi

# ── 3. Restore into a fresh data dir ───────────────────────────────
RESTORE_FLAGS=(--snap-id "$SNAP_ID" --data-dir "$RESTORE_DIR")
if [[ "${BLOB_BACKEND:-fs}" == "fs" ]]; then
    RESTORE_FLAGS+=(--snapshot-dir "$DATA_DIR/.snapshots")
fi
"$BIN" restore-from-snapshot "${RESTORE_FLAGS[@]}" 2>&1 | tee /tmp/snapshot-smoke-restore.out

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
echo "PASS snapshot smoke (capture + restore round-trip)"
