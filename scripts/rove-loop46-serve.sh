#!/usr/bin/env bash
# Start the rove-js worker serving Loop46 on loop46.me at
# 15.204.47.158:443, with TLS terminated in-process from certs at
# ~/.rove/tls/{cert,key}.pem (maintained by scripts/rove-lego-renew.sh).
#
# ── Prerequisites ────────────────────────────────────────────────────
# 1. scripts/rove-lego-renew.sh has issued a cert at least once:
#      ls -l ~/.rove/tls/{cert,key}.pem   # both symlinks resolve
#
# 2. Your user can bind port 443. Pick one (see README-style note in
#    scripts/systemd/rove-cert-renew.service for the fuller rundown):
#      a) lower the privileged-port threshold:
#           sudo sysctl -w net.ipv4.ip_unprivileged_port_start=443
#           # persist: /etc/sysctl.d/99-rove.conf
#      b) grant the capability to the binary (shared hosts):
#           sudo setcap cap_net_bind_service=+ep zig-out/bin/js-worker
#
# 3. DNS at your registrar:
#      loop46.me.        A  15.204.47.158
#      *.loop46.me.      A  15.204.47.158
#    Verify: `dig +short loop46.me any.loop46.me` returns the IP.
#
# ── Overrides ────────────────────────────────────────────────────────
# All env vars below are optional; defaults match this deployment.
#   BIND_ADDR, BASE_DOMAIN, TLS_CERT, TLS_KEY, DATA_DIR, WORKERS
#   ROVE_TOKEN  (optional; if set, (re-)installs a root bearer token)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

BIND_ADDR="${BIND_ADDR:-15.204.47.158:443}"
BASE_DOMAIN="${BASE_DOMAIN:-loop46.me}"
TLS_CERT="${TLS_CERT:-$HOME/.rove/tls/cert.pem}"
TLS_KEY="${TLS_KEY:-$HOME/.rove/tls/key.pem}"
DATA_DIR="${DATA_DIR:-$HOME/.rove/data}"
WORKERS="${WORKERS:-4}"

# Raft single-node. Binds loopback so it doesn't conflict with the
# public listener and doesn't need a port opened in any firewall.
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40146}"

WORKER_BIN="${WORKER_BIN:-$REPO_DIR/zig-out/bin/js-worker}"

# ── Sanity checks ────────────────────────────────────────────────────
if [[ ! -x "$WORKER_BIN" ]]; then
    echo "error: $WORKER_BIN missing — run 'zig build install' first" >&2
    exit 2
fi
if [[ ! -r "$TLS_CERT" ]]; then
    echo "error: cannot read TLS cert at $TLS_CERT" >&2
    echo "       run scripts/rove-lego-renew.sh first" >&2
    exit 2
fi
if [[ ! -r "$TLS_KEY" ]]; then
    echo "error: cannot read TLS key at $TLS_KEY" >&2
    exit 2
fi

mkdir -p "$DATA_DIR"

# The admin UI + API both dogfood the customer experience at
# app.$BASE_DOMAIN — `__admin__` handler routes internally.
ADMIN_API_DOMAIN="app.${BASE_DOMAIN}"
ADMIN_ORIGIN="https://${ADMIN_API_DOMAIN}"

# Bootstrap plumbing. Flags only pass through when the matching env
# var is set; otherwise boot reuses what's already in root.db.
#   ROVE_TOKEN        → --bootstrap-root-token        (admin login)
#   ROVE_RESEND_KEY   → --bootstrap-resend-key        (platform email default)
BOOTSTRAP_ARGS=()
if [[ -n "${ROVE_TOKEN:-}" ]]; then
    BOOTSTRAP_ARGS+=(--bootstrap-root-token "$ROVE_TOKEN")
fi
if [[ -n "${ROVE_RESEND_KEY:-}" ]]; then
    BOOTSTRAP_ARGS+=(--bootstrap-resend-key "$ROVE_RESEND_KEY")
fi

cat <<EOF
rove-js: starting
  bind       : https://${BIND_ADDR}
  base domain: ${BASE_DOMAIN}  (wildcard + apex)
  admin      : ${ADMIN_ORIGIN}
  cert       : ${TLS_CERT}
  key        : ${TLS_KEY}
  data       : ${DATA_DIR}
  workers    : ${WORKERS}

EOF

exec "$WORKER_BIN" \
    --node-id 0 \
    --peers "$RAFT_ADDR" \
    --listen "$RAFT_ADDR" \
    --http "$BIND_ADDR" \
    --tls-cert "$TLS_CERT" \
    --tls-key "$TLS_KEY" \
    --public-suffix "$BASE_DOMAIN" \
    --admin-api-domain "$ADMIN_API_DOMAIN" \
    --admin-origin "$ADMIN_ORIGIN" \
    --data-dir "$DATA_DIR" \
    --workers "$WORKERS" \
    "${BOOTSTRAP_ARGS[@]}"
