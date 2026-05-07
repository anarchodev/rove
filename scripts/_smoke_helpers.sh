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
