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
