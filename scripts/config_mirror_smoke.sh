#!/usr/bin/env bash
# End-to-end smoke for the deploy-time `_config/` → kv mirror
# (config_mirror.zig + handleRelease wire-in + seed.zig wire-in).
#
# Setup:
#   - acme tenant ships with `_config/oauth/google.json` in its tree
#     (see examples/loop46-demo-tenants.json) and a `cfg/index.mjs`
#     handler that returns `kv.get("_config/oauth/google")`.
#   - At seed time, the mirror copies the file's bytes into kv on
#     each node's app.db at `_config/oauth/google`.
#
# Verifies:
#   - Handler GET /cfg returns the JSON contents of the config file
#     verbatim (proves the row landed AND the bytes match).
#   - The same row is present on a non-leader follower (proves the
#     mirror ran on every node, not just the one that won the
#     election).
#
# Live-release path (handleRelease's mirror call) is exercised by
# unit tests in dispatcher.zig and config_mirror.zig — the smoke
# focuses on the seed path because it's the one most users hit
# first.

set -euo pipefail

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-config-mirror-smoke}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8316}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40416}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc}"
ADMIN_HOST="app.loop46.localhost"
ACME_HOST="acme.loop46.localhost"
PUBLIC_SUFFIX="loop46.localhost"

if [[ "$(uname -s)" == "Darwin" ]]; then
    LOOP46_DATA="${LOOP46_DATA:-$HOME/Library/Application Support/loop46}"
else
    LOOP46_DATA="${LOOP46_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/loop46}"
fi
TLS_CERT="$LOOP46_DATA/dev-cert.pem"
TLS_KEY="$LOOP46_DATA/dev-key.pem"
CACERT="$LOOP46_DATA/ca-root.pem"

if [[ ! -f "$TLS_CERT" || ! -f "$TLS_KEY" ]]; then
    echo "error: missing dev TLS at $LOOP46_DATA. Run 'loop46 dev ...' once to bootstrap." >&2
    exit 2
fi
if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN missing — run 'zig build install' first" >&2
    exit 2
fi
if ! command -v python3 >/dev/null; then
    echo "error: python3 needed" >&2
    exit 2
fi

# Per-run S3 prefix — same convention as the other smokes.
export S3_KEY_PREFIX_BASE="${S3_KEY_PREFIX_BASE:-smoke-config-mirror-$(date +%s)/}"

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=config-mirror-smoke
SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"
export LOOP46_ROOT_TOKEN="$TOKEN"

# Seed all three nodes — each node's seed runs the mirror locally,
# so all three end up with identical `_config/oauth/google` rows.
seed_all_dirs ./examples/loop46-demo-tenants.json

PIDS=()
for i in 0 1 2; do
    P="${HTTP_ADDRS[$i]##*:}"
    "$BIN" worker \
        --node-id "$i" \
        --peers "$PEERS_CSV" \
        --listen "${RAFT_ADDRS[$i]}" \
        --http "${HTTP_ADDRS[$i]}" \
        --data-dir "${DATA_DIRS[$i]}" \
        --admin-origin "https://${ADMIN_HOST}:${P}" \
        --admin-api-domain "$ADMIN_HOST" \
        --public-suffix "$PUBLIC_SUFFIX" \
        --tls-cert "$TLS_CERT" \
        --tls-key "$TLS_KEY" \
        --workers 2 \
        "${RAFT_TIMING_FLAGS[@]}" \
        >"/tmp/${SMOKE_TAG}-worker-${i}.out" 2>&1 &
    PIDS+=($!)
done

cleanup() {
    for p in "${PIDS[@]}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
    for p in "${PIDS[@]}"; do [ -n "$p" ] && wait "$p" 2>/dev/null || true; done
}
trap cleanup EXIT
sleep 2

RESOLVE=()
for h in "${HTTP_ADDRS[@]}"; do
    p="${h##*:}"
    RESOLVE+=(--resolve "${ADMIN_HOST}:${p}:127.0.0.1" \
              --resolve "${ACME_HOST}:${p}:127.0.0.1")
done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")

discover_leader "$ADMIN_HOST" "$TOKEN" || exit 1
echo "ok  leader elected: node $LEADER_IDX at $LEADER_HTTP"

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    for i in 0 1 2; do
        echo "--- worker $i log ---" >&2
        tail -30 "/tmp/${SMOKE_TAG}-worker-${i}.out" >&2
    done
    exit 1
}

EXPECTED=$(python3 -c "
import json
print(json.dumps(json.load(open('examples/loop46-demo-tenants/acme/_config/oauth/google.json'))))
")

# ── 1. Hit the handler on the leader ──────────────────────────────────
LEADER_BODY=$("${CURL[@]}" "https://${ACME_HOST}:${LEADER_PORT}/cfg")
GOT_LEADER=$(python3 -c "
import json, sys
print(json.dumps(json.loads(sys.argv[1])))
" "$LEADER_BODY")
[[ "$GOT_LEADER" == "$EXPECTED" ]] \
    || fail "leader /cfg returned $GOT_LEADER, want $EXPECTED"
ok "leader has _config/oauth/google row mirrored from the file tree"

# ── 2. Verify each node's cluster.kv has the row mirrored ─────────────
#
# Under kvexp the per-tenant data lives inside `cluster.kv` (LMDB,
# MDB_NOLOCK = single-process). Shut every node down so the offline
# `loop46 kv-get` reader can open the env cleanly.
for p in "${PIDS[@]}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
for p in "${PIDS[@]}"; do [ -n "$p" ] && wait "$p" 2>/dev/null || true; done
PIDS=()

for IDX in 0 1 2; do
    ROW=$("$BIN" kv-get --data-dir "${DATA_DIRS[$IDX]}" --store acme --key "_config/oauth/google") \
        || fail "node $IDX cluster.kv missing _config/oauth/google"
    GOT=$(python3 -c "import json,sys; print(json.dumps(json.loads(sys.argv[1])))" "$ROW")
    [[ "$GOT" == "$EXPECTED" ]] \
        || fail "node $IDX cluster.kv has wrong value: $GOT"
    ok "node $IDX cluster.kv has matching _config/oauth/google row"
done

# ── 3. Verify the marker field round-tripped (sanity on the bytes) ────
MARKER=$(echo "$LEADER_BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["marker"])')
[[ "$MARKER" == "from-config-mirror-smoke" ]] \
    || fail "marker field missing/wrong: $MARKER"
ok "marker field round-tripped: $MARKER"

echo
echo "all config-mirror smoke checks passed"
