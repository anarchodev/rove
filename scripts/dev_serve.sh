#!/usr/bin/env bash
# Start `loop46 dev` for local browser testing of the admin UI.
#
# - Builds zig-out/bin/loop46 first (incremental rebuild).
# - Uses dev defaults: TLS via mkcert, public_suffix=loop46.localhost,
#   listener on :8443. mkcert auto-installs its CA into the browser
#   trust store on first run (may prompt for sudo).
# - Persists data + the dev root token under ~/.local/share/loop46.
#   Same token across restarts; rm dev-root-token to rotate.
#
# Override DATA_DIR / PORT via env. --fresh wipes the data dir before
# starting (forces re-bootstrap of __admin__ + __replay__). Pass any
# extra args through (e.g. --bootstrap-kv resend_key=re_...).
#
#   scripts/dev_serve.sh
#   scripts/dev_serve.sh --fresh
#   PORT=8444 scripts/dev_serve.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR"

PORT="${PORT:-8443}"
DATA_DIR="${DATA_DIR:-$HOME/.local/share/loop46/data}"
LOOP46_DIR="${HOME}/.local/share/loop46"
TOKEN_FILE="${LOOP46_DIR}/dev-root-token"

echo "▶ building loop46…"
zig build install

mkdir -p "$DATA_DIR"

# Run a quick "is it up" probe later; need the URL handy.
ADMIN_URL="https://app.loop46.localhost:${PORT}"

cat <<EOF

┌───────────────────────────────────────────────────────────────────┐
│ loop46 dev — local browser harness                                │
│                                                                   │
│   admin UI : ${ADMIN_URL}
│   data dir : ${DATA_DIR}
│   port     : ${PORT}
│                                                                   │
│ on first run mkcert may prompt for sudo to install its CA.        │
│ open the admin URL above in a browser; paste the token below      │
│ when prompted to log in.                                          │
└───────────────────────────────────────────────────────────────────┘

EOF

if [[ -r "$TOKEN_FILE" ]]; then
    echo "  root token: $(cat "$TOKEN_FILE")"
    echo "  (saved at $TOKEN_FILE; first --fresh start will rotate it)"
else
    echo "  root token: (will be generated and printed by the worker on first start)"
fi
echo

# Phase 5.5(a)/5.5(e) Task #61 + #62 — files-server + log-server
# run as separate processes. Generate a per-run JWT secret, spawn
# both standalones on fixed dev ports, and tear them down when
# loop46 dev exits. The worker reads the same env to mint
# matching tokens.
FILES_PORT="${FILES_PORT:-8444}"
LOG_PORT="${LOG_PORT:-8445}"
TLS_CERT="${LOOP46_DIR}/dev-cert.pem"
TLS_KEY="${LOOP46_DIR}/dev-key.pem"
export LOOP46_SERVICES_JWT_SECRET="$(head -c32 /dev/urandom | xxd -p | tr -d '\n')"

CS_LOG="${LOOP46_DIR}/files-server-dev.log"
"./zig-out/bin/files-server-standalone" \
    --data-dir "$DATA_DIR" \
    --listen "127.0.0.1:${FILES_PORT}" \
    ${TLS_CERT:+--tls-cert "$TLS_CERT"} \
    ${TLS_KEY:+--tls-key "$TLS_KEY"} \
    --cors-origin "https://app.loop46.localhost:${PORT}" \
    >"$CS_LOG" 2>&1 &
CS_PID=$!
echo "  files-server: log at $CS_LOG (pid $CS_PID, port $FILES_PORT)"

LS_LOG="${LOOP46_DIR}/log-server-dev.log"
"./zig-out/bin/log-server-standalone" \
    --data-dir "$DATA_DIR" \
    --listen "127.0.0.1:${LOG_PORT}" \
    --poll-interval-ms 500 \
    ${TLS_CERT:+--tls-cert "$TLS_CERT"} \
    ${TLS_KEY:+--tls-key "$TLS_KEY"} \
    --cors-origin "https://app.loop46.localhost:${PORT}" \
    >"$LS_LOG" 2>&1 &
LS_PID=$!
echo "  log-server  : log at $LS_LOG (pid $LS_PID, port $LOG_PORT)"

trap 'kill $CS_PID $LS_PID 2>/dev/null || true; wait $CS_PID $LS_PID 2>/dev/null || true' EXIT
echo

exec ./zig-out/bin/loop46 dev \
    --data-dir "$DATA_DIR" \
    --http "127.0.0.1:${PORT}" \
    --files-public-base "https://files.loop46.localhost:${FILES_PORT}" \
    --log-public-base "https://logs.loop46.localhost:${LOG_PORT}" \
    "$@"
