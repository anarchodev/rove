#!/usr/bin/env bash
# Dev harness for the browser admin UI.
#
# Spins up a fresh js-worker (with --admin-origin wired for CORS) and
# serves web/admin/ over plain HTTP on :5173 so the browser can load
# the static files. Open http://127.0.0.1:5173/?api=http://127.0.0.1:8082
# on first run — the `?api=` query string saves the API base to
# localStorage so subsequent reloads don't need it.
#
# Uses the `bbbb...` bootstrap root token; paste that into the login
# page when prompted.
#
# Exits cleanly on Ctrl-C (traps kill both the worker and the static
# server).

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-admin-dev}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8082}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40182}"
UI_PORT="${UI_PORT:-5173}"
ORIGIN="${ADMIN_ORIGIN:-http://localhost:${UI_PORT}}"
WORKERS="${WORKERS:-4}"
TOKEN="${ROVE_TOKEN:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
BIN="${BIN:-./zig-out/bin/js-worker}"

if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN missing — run 'zig build install' first" >&2
    exit 2
fi

rm -rf "$DATA_DIR"

"$BIN" \
    --node-id 0 \
    --peers "$RAFT_ADDR" \
    --listen "$RAFT_ADDR" \
    --http "$HTTP_ADDR" \
    --data-dir "$DATA_DIR" \
    --bootstrap-root-token "$TOKEN" \
    --admin-origin "$ORIGIN" \
    --workers "$WORKERS" \
    --fresh &
WORKER_PID=$!

cd "$(dirname "$0")/../web/admin"
python3 -m http.server "$UI_PORT" &
UI_PID=$!

cleanup() {
    kill $WORKER_PID 2>/dev/null || true
    kill $UI_PID 2>/dev/null || true
    wait $WORKER_PID 2>/dev/null || true
    wait $UI_PID 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cat <<EOF

┌────────────────────────────────────────────────────────────────┐
│ rove admin dev harness                                         │
│                                                                │
│ worker : http://${HTTP_ADDR}  (workers=${WORKERS})                 │
│ ui     : http://localhost:${UI_PORT}                                 │
│ token  : ${TOKEN}                                               │
│                                                                │
│ First load: open                                               │
│   http://localhost:${UI_PORT}/?api=http://${HTTP_ADDR}               │
│ Subsequent loads: just http://localhost:${UI_PORT}                   │
│                                                                │
│ Ctrl-C to stop both processes.                                 │
└────────────────────────────────────────────────────────────────┘
EOF

wait
