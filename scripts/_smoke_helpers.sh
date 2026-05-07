#!/usr/bin/env bash
# Shared smoke helpers — auth flows for the standalone services
# (logs.{public_suffix}, files.{public_suffix}). Source from a
# smoke script after exporting:
#
#   - ADMIN_ORIGIN  (e.g. https://app.loop46.localhost:8210)
#   - ROVE_TOKEN    (root bearer for the worker /_system/services-token gate)
#   - CURL          a bash array of base curl args (resolves, --cacert, etc.)
#
# Then call `mint_services_token` to populate JWT / LOG_BASE / FILES_BASE.
# Use the JWT in `Authorization: Bearer ...` against the standalone
# services. `files_curl` and `log_curl` are convenience wrappers.
#
# rove is S3-only. Sourcing this file pulls AWS / S3_* from `.env` at
# the repo root and assigns each smoke a per-run S3_KEY_PREFIX_BASE so
# concurrent runs don't trample each other.

# Source .env (repo root) for AWS_* + S3_* env vars. The .env path is
# relative to the smoke script's caller — when sourced by a
# scripts/*_smoke.sh, $(dirname "$0")/.. is the repo root. Fall back
# to ./ when sourced directly.
__smoke_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${__smoke_repo_root}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${__smoke_repo_root}/.env"
    set +a
fi
for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY S3_BUCKET S3_ENDPOINT S3_REGION; do
    if [[ -z "${!v:-}" ]]; then
        echo "error: $v not set (need .env at repo root with S3 credentials)" >&2
        exit 2
    fi
done

# Stable dev id used to namespace each smoke's S3 prefix. The prefix
# itself is set by `init_cluster_addrs` once SMOKE_TAG is known.
__smoke_dev_id="$(hostname)-$(id -u)"

mint_services_token() {
    local resp
    resp=$("${CURL[@]}" -H "Authorization: Bearer $ROVE_TOKEN" \
        "${ADMIN_ORIGIN}/_system/services-token")
    JWT=$(echo "$resp" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')
    LOG_BASE=$(echo "$resp" | python3 -c 'import json,sys;print(json.load(sys.stdin)["log_url"])')
    FILES_BASE=$(echo "$resp" | python3 -c 'import json,sys;print(json.load(sys.stdin)["files_url"])')
    [[ -n "${JWT:-}" ]] || { echo "mint_services_token: empty JWT (resp=$resp)" >&2; return 1; }
}

# `files_curl <curl-args...>` — runs curl with the smoke's CURL prefix
# + the JWT bearer. JWT must already be set (call mint_services_token).
files_curl() {
    "${CURL[@]}" -H "Authorization: Bearer $JWT" "$@"
}

log_curl() {
    "${CURL[@]}" -H "Authorization: Bearer $JWT" "$@"
}

# `gen_jwt_secret` — print a fresh 32-byte hex secret for
# LOOP46_SERVICES_JWT_SECRET. Must be set in env before launching
# both the `loop46 worker` and the `files-server-standalone`
# subprocesses so JWTs minted by the worker verify on the standalone.
gen_jwt_secret() {
    head -c32 /dev/urandom | xxd -p | tr -d '\n'
}

# `spawn_files_server <listen> <data_dir> <log_path> [cors_origin]`
# — start the files-server-standalone subprocess. Reads
# LOOP46_SERVICES_JWT_SECRET from env (caller must export it). Sets
# CS_PID to the child pid; caller adds it to its trap.
#
# When TLS_CERT + TLS_KEY are set in env, the standalone runs HTTPS
# (matching the worker's TLS shape and the smoke's CURL --cacert
# wiring). Otherwise it runs plain h2c on the loopback addr.
# `cors_origin` (4th arg) becomes the standalone's CORS origin —
# normally the same value the worker gets via `--admin-origin`.
spawn_files_server() {
    local listen="$1"
    local data_dir="$2"
    local log_path="$3"
    local cors_origin="${4:-}"
    "${BIN%/loop46}/files-server-standalone" \
        --data-dir "$data_dir" \
        --listen "$listen" \
        ${TLS_CERT:+--tls-cert "$TLS_CERT"} \
        ${TLS_KEY:+--tls-key "$TLS_KEY"} \
        ${cors_origin:+--cors-origin "$cors_origin"} \
        >"$log_path" 2>&1 &
    CS_PID=$!
    # Wait for the standalone's startup line so the worker doesn't
    # mint tokens against an unbound listener.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if grep -q 'listening on' "$log_path" 2>/dev/null; then return 0; fi
        sleep 0.1
    done
    echo "spawn_files_server: didn't see 'listening on' in $log_path within 1s" >&2
    cat "$log_path" >&2
    return 1
}

# `spawn_log_server <listen> <data_dir> <log_path> [cors_origin]` —
# start the log-server-standalone subprocess. Same shape as
# spawn_files_server (TLS + CORS via env / arg, JWT secret read
# from LOOP46_SERVICES_JWT_SECRET). Sets LS_PID. Worker and
# standalone share `data_dir` so the fs batch-store path
# `{data_dir}/log-batches/` is the same physical directory.
spawn_log_server() {
    local listen="$1"
    local data_dir="$2"
    local log_path="$3"
    local cors_origin="${4:-}"
    "${BIN%/loop46}/log-server-standalone" \
        --data-dir "$data_dir" \
        --listen "$listen" \
        --poll-interval-ms 100 \
        ${TLS_CERT:+--tls-cert "$TLS_CERT"} \
        ${TLS_KEY:+--tls-key "$TLS_KEY"} \
        ${cors_origin:+--cors-origin "$cors_origin"} \
        >"$log_path" 2>&1 &
    LS_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if grep -q 'listening on' "$log_path" 2>/dev/null; then return 0; fi
        sleep 0.1
    done
    echo "spawn_log_server: didn't see 'listening on' in $log_path within 1s" >&2
    cat "$log_path" >&2
    return 1
}

# `init_cluster_addrs <data_dir_prefix> <http_port_base> <raft_port_base>` —
# allocate 3-node cluster addresses + data dirs. Sets the
# following globals for the caller:
#
#   HTTP_ADDRS=( 127.0.0.1:N 127.0.0.1:N+1 127.0.0.1:N+2 )
#   RAFT_ADDRS=( 127.0.0.1:M 127.0.0.1:M+1 127.0.0.1:M+2 )
#   DATA_DIRS=( ${prefix}-0 ${prefix}-1 ${prefix}-2 )
#   PEERS_CSV (raft addresses joined by commas)
#
# Each smoke picks unique port bases so multiple smokes can run
# in parallel without colliding. Production deploys are 3-node
# typical (1 leader + 2 followers); 2/3 quorum + 1-failure
# tolerance.
init_cluster_addrs() {
    local prefix="$1"
    local http_base="$2"
    local raft_base="$3"
    HTTP_ADDRS=()
    RAFT_ADDRS=()
    DATA_DIRS=()
    for i in 0 1 2; do
        HTTP_ADDRS+=("127.0.0.1:$((http_base + i))")
        RAFT_ADDRS+=("127.0.0.1:$((raft_base + i))")
        DATA_DIRS+=("${prefix}-${i}")
    done
    PEERS_CSV=$(IFS=,; echo "${RAFT_ADDRS[*]}")
    rm -rf "${DATA_DIRS[@]}"

    # Per-smoke S3 key prefix base, stable across runs of the same
    # smoke on the same dev box. Subsequent runs see bootstrap blobs
    # already in S3 → no re-upload, no startup delay.
    export S3_KEY_PREFIX_BASE="${S3_KEY_PREFIX_BASE:-smoke-${SMOKE_TAG:-default}-${__smoke_dev_id}/}"

    # Tighten raft timing for smokes: production default is 1000ms
    # election timeout / 200ms heartbeat (matches etcd / Consul /
    # TiKV). Smokes don't care about spurious-election resilience —
    # they care about fast first-election. 200ms / 50ms drops smoke
    # startup by 5-7s without changing the production envelope.
    # Smokes can override by setting RAFT_TIMING_FLAGS=(--election-timeout-ms 200 --heartbeat-ms 50) before
    # sourcing.
    if [[ -z "${RAFT_TIMING_FLAGS+x}" ]]; then
        RAFT_TIMING_FLAGS=(--election-timeout-ms 200 --heartbeat-ms 50)
    fi
}

# `seed_all_dirs <manifest_path>` — run `loop46 seed` against
# every node's data dir. Each node maintains its own __root__.db
# so the cluster shares the same membership view from boot.
seed_all_dirs() {
    local manifest="$1"
    for d in "${DATA_DIRS[@]}"; do
        "$BIN" seed --data-dir "$d" --manifest "$manifest" >/dev/null
    done
}

# `discover_leader <admin_host> <token>` — probe each HTTP_ADDRS
# entry's `?fn=listInstance` until one responds 200. Followers
# reject every request with 503 + "not leader; retry against the
# cluster leader" via the existing leader-skip in dispatchOnce,
# so the first 200 wins. Tries up to 30 × 200ms = 6s, generous
# enough for willemt's election timeout.
#
# Sets LEADER_IDX, LEADER_HTTP, ADMIN_ORIGIN. CURL must already
# be set up by the caller (`CURL=(curl -sS ...)`).
discover_leader() {
    local admin_host="$1"
    local token="$2"
    LEADER_HTTP=""
    LEADER_IDX=""
    for _ in $(seq 1 75); do
        for i in 0 1 2; do
            local code
            code=$("${CURL[@]}" --max-time 2 -o /dev/null -w '%{http_code}' \
                -H "Host: $admin_host" \
                -H "Authorization: Bearer $token" \
                "${SMOKE_PROTO:-http}://${HTTP_ADDRS[$i]}/?fn=listInstance" 2>/dev/null || echo 000)
            if [[ "$code" == "200" ]]; then
                LEADER_HTTP="${HTTP_ADDRS[$i]}"
                LEADER_IDX="$i"
                LEADER_PORT="${LEADER_HTTP##*:}"
                ADMIN_ORIGIN="${SMOKE_PROTO:-http}://${LEADER_HTTP}"
                return 0
            fi
        done
        sleep 0.2
    done
    echo "FAIL: no leader elected within 15s" >&2
    for i in 0 1 2; do
        local logf="/tmp/${SMOKE_TAG:-smoke}-worker-${i}.out"
        if [[ -f "$logf" ]]; then
            echo "--- worker $i log (last 30 lines) ---" >&2
            tail -30 "$logf" >&2
        fi
    done
    return 1
}

# `release_deployment <tenant_id> <dep_id>` — POST /_system/release on
# the worker so it reloads bytecodes for the tenant. Replaces the
# 2-second `refreshDeployments` poll retired in Phase 5.5(e) F2.
# ROVE_TOKEN must be the root bearer.
release_deployment() {
    local tenant="$1"
    local dep_id="$2"
    local code
    code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
        -X POST -H "Authorization: Bearer $ROVE_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"tenant_id\":\"${tenant}\",\"dep_id\":${dep_id}}" \
        "${ADMIN_ORIGIN}/_system/release")
    if [[ "$code" != "204" ]]; then
        echo "release_deployment ${tenant}/${dep_id}: got $code" >&2
        return 1
    fi
}
