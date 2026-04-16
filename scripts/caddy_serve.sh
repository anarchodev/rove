#!/usr/bin/env bash
# Admin demo with Caddy fronting js-worker over real domains.
#
# Architecture:
#   browser ──HTTPS──> Caddy :8443 ──loopback h2c──> js-worker :8082
#
# Caddy terminates TLS (Caddy's internal CA — one-time `sudo caddy
# trust` so the browser accepts it) and splits traffic by hostname:
#   admin.loop46.com → static files from web/admin/
#   api.loop46.com   → reverse-proxy to js-worker
#
# Override any env var below; the defaults target loop46.com on port
# 8443 (no port-conflict with typical 443 services).
#
# First-time setup (once per machine):
#   sudo caddy trust
#
# Then just run this script. Ctrl-C tears down both processes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ── Public face (what the browser hits) ─────────────────────────────
export ADMIN_HOST="${ADMIN_HOST:-admin.loop46.com}"
export API_HOST="${API_HOST:-api.loop46.com}"
export TLS_PORT="${TLS_PORT:-8443}"

# ── Internal (loopback between Caddy and js-worker) ────────────────
WORKER_HTTP_ADDR="${WORKER_HTTP_ADDR:-127.0.0.1:8082}"
WORKER_RAFT_ADDR="${WORKER_RAFT_ADDR:-127.0.0.1:40182}"
export WORKER_HTTP="$WORKER_HTTP_ADDR"

# ── Worker tuning ──────────────────────────────────────────────────
DATA_DIR="${DATA_DIR:-/tmp/rove-admin-demo}"
WORKERS="${WORKERS:-4}"
TOKEN="${ROVE_TOKEN:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"

# ── Paths ──────────────────────────────────────────────────────────
export ROVE_ADMIN_DIR="$REPO_DIR/web/admin"
WORKER_BIN="${WORKER_BIN:-$REPO_DIR/zig-out/bin/js-worker}"
CADDYFILE="$SCRIPT_DIR/Caddyfile.admin"

if ! command -v caddy >/dev/null; then
	echo "error: caddy not found on PATH" >&2
	exit 2
fi
if [[ ! -x "$WORKER_BIN" ]]; then
	echo "error: $WORKER_BIN missing — run 'zig build install' first" >&2
	exit 2
fi
if [[ ! -f "$CADDYFILE" ]]; then
	echo "error: $CADDYFILE missing" >&2
	exit 2
fi

rm -rf "$DATA_DIR"

ADMIN_ORIGIN="https://${ADMIN_HOST}:${TLS_PORT}"

"$WORKER_BIN" \
	--node-id 0 \
	--peers "$WORKER_RAFT_ADDR" \
	--listen "$WORKER_RAFT_ADDR" \
	--http "$WORKER_HTTP_ADDR" \
	--data-dir "$DATA_DIR" \
	--bootstrap-root-token "$TOKEN" \
	--admin-origin "$ADMIN_ORIGIN" \
	--workers "$WORKERS" \
	--fresh &
WPID=$!

caddy run --config "$CADDYFILE" --adapter caddyfile &
CPID=$!

cleanup() {
	kill $WPID $CPID 2>/dev/null || true
	wait $WPID $CPID 2>/dev/null || true
}
trap cleanup EXIT INT TERM

sleep 0.5

cat <<EOF

┌─────────────────────────────────────────────────────────────────┐
│ rove admin demo (Caddy + js-worker)                             │
│                                                                 │
│ admin ui : https://${ADMIN_HOST}:${TLS_PORT}
│ api      : https://${API_HOST}:${TLS_PORT}
│ token    : ${TOKEN}
│                                                                 │
│ First browser visit (sets the API base in localStorage):        │
│   https://${ADMIN_HOST}:${TLS_PORT}/?api=https://${API_HOST}:${TLS_PORT}
│                                                                 │
│ Subsequent visits: just the admin URL.                          │
│                                                                 │
│ Ctrl-C to stop both processes.                                  │
└─────────────────────────────────────────────────────────────────┘

EOF

wait
