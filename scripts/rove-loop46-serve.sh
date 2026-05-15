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
#           sudo setcap cap_net_bind_service=+ep zig-out/bin/loop46
#
# 3. DNS at your registrar:
#      loop46.me.        A  15.204.47.158
#      *.loop46.me.      A  15.204.47.158
#    Verify: `dig +short loop46.me any.loop46.me` returns the IP.
#
# ── Overrides ────────────────────────────────────────────────────────
# All env vars below are optional; defaults match this deployment.
#   BIND_ADDR, BASE_DOMAIN, SYSTEM_DOMAIN, TLS_CERT, TLS_KEY,
#   DATA_DIR, WORKERS
#   (BASE_DOMAIN = customer wildcard; SYSTEM_DOMAIN = system surfaces
#    — admin/replay. They MUST be different registrable domains; see
#    docs/auth-domain-plan.md §1.)
#   ROVE_TOKEN  (optional; if set, (re-)installs a root bearer token)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

BIND_ADDR="${BIND_ADDR:-15.204.47.158:443}"
BASE_DOMAIN="${BASE_DOMAIN:-rewindjs.app}"
SYSTEM_DOMAIN="${SYSTEM_DOMAIN:-rewindjs.com}"
TLS_CERT="${TLS_CERT:-$HOME/.rove/tls/cert.pem}"
TLS_KEY="${TLS_KEY:-$HOME/.rove/tls/key.pem}"
DATA_DIR="${DATA_DIR:-$HOME/.rove/data}"
WORKERS="${WORKERS:-4}"

# Raft single-node. Binds loopback so it doesn't conflict with the
# public listener and doesn't need a port opened in any firewall.
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40146}"

WORKER_BIN="${WORKER_BIN:-$REPO_DIR/zig-out/bin/loop46}"

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

# The admin UI + API both dogfood the customer experience, but admin
# is a *system* surface → it lives on the system domain, never the
# customer BASE_DOMAIN. `__admin__` handler routes internally.
ADMIN_API_DOMAIN="app.${SYSTEM_DOMAIN}"
ADMIN_ORIGIN="https://${ADMIN_API_DOMAIN}"

# Bootstrap plumbing.
#   ROVE_TOKEN       → LOOP46_ROOT_TOKEN env (worker reads at startup;
#                       constant-time compared against the bearer on
#                       /_system/* and /v1/login).
#   ROVE_RESEND_KEY  → files-server --bootstrap-kv resend_key=... (one-shot
#                       admin-kv push at standalone startup).
if [[ -n "${ROVE_TOKEN:-}" ]]; then
    export LOOP46_ROOT_TOKEN="$ROVE_TOKEN"
fi
FILES_BOOTSTRAP_ARGS=()
if [[ -n "${ROVE_RESEND_KEY:-}" ]]; then
    FILES_BOOTSTRAP_ARGS+=(--bootstrap-kv "resend_key=$ROVE_RESEND_KEY")
fi

cat <<EOF
rove-js: starting
  bind       : https://${BIND_ADDR}
  base domain: ${BASE_DOMAIN}  (customer wildcard + apex)
  system dom : ${SYSTEM_DOMAIN}  (admin/replay)
  admin      : ${ADMIN_ORIGIN}
  cert       : ${TLS_CERT}
  key        : ${TLS_KEY}
  data       : ${DATA_DIR}
  workers    : ${WORKERS}

EOF

# Phase 5.5(e) Task #62 — files-server runs as a separate process.
# Spawn it on a fixed local port behind the same TLS cert as the
# worker, share LOOP46_SERVICES_JWT_SECRET so JWTs minted at the
# worker's `/_system/services-token` verify here. Production-grade
# supervision (systemd, etc.) should run them as separate units;
# this single-script helper just shells the process out for now.
FILES_PORT="${FILES_PORT:-8444}"
FILES_SERVER_BIN="${FILES_SERVER_BIN:-$REPO_DIR/zig-out/bin/files-server-standalone}"
JWT_SECRET_FILE="${JWT_SECRET_FILE:-$DATA_DIR/services-jwt-secret}"
if [[ ! -f "$JWT_SECRET_FILE" ]]; then
    head -c32 /dev/urandom | xxd -p | tr -d '\n' > "$JWT_SECRET_FILE"
    chmod 0600 "$JWT_SECRET_FILE"
fi
export LOOP46_SERVICES_JWT_SECRET="$(cat "$JWT_SECRET_FILE")"

CS_LOG="${CS_LOG:-$DATA_DIR/files-server.log}"
"$FILES_SERVER_BIN" \
    --data-dir "$DATA_DIR" \
    --listen "127.0.0.1:${FILES_PORT}" \
    --tls-cert "$TLS_CERT" \
    --tls-key "$TLS_KEY" \
    --cors-origin "$ADMIN_ORIGIN" \
    --leader-url "https://${BIND_ADDR}" \
    "${FILES_BOOTSTRAP_ARGS[@]}" \
    >"$CS_LOG" 2>&1 &
CS_PID=$!
echo "  files-server: log at $CS_LOG (pid $CS_PID, port $FILES_PORT)"

LOG_PORT="${LOG_PORT:-8445}"
LS_BIN="${LS_BIN:-$REPO_DIR/zig-out/bin/log-server-standalone}"
LS_LOG="${LS_LOG:-$DATA_DIR/log-server.log}"
"$LS_BIN" \
    --data-dir "$DATA_DIR" \
    --listen "127.0.0.1:${LOG_PORT}" \
    --poll-interval-ms 500 \
    --tls-cert "$TLS_CERT" \
    --tls-key "$TLS_KEY" \
    --cors-origin "$ADMIN_ORIGIN" \
    >"$LS_LOG" 2>&1 &
LS_PID=$!
echo "  log-server  : log at $LS_LOG (pid $LS_PID, port $LOG_PORT)"

trap 'kill $CS_PID $LS_PID 2>/dev/null || true; wait $CS_PID $LS_PID 2>/dev/null || true' EXIT

# Foreground (no `exec`) so the EXIT trap above can tear down the
# standalones when the worker exits. For systemd-supervised deploys
# all three processes should be separate units instead.
"$WORKER_BIN" \
    --node-id 0 \
    --peers "$RAFT_ADDR" \
    --listen "$RAFT_ADDR" \
    --http "$BIND_ADDR" \
    --tls-cert "$TLS_CERT" \
    --tls-key "$TLS_KEY" \
    --public-suffix "$BASE_DOMAIN" \
    --system-suffix "$SYSTEM_DOMAIN" \
    --admin-api-domain "$ADMIN_API_DOMAIN" \
    --admin-origin "$ADMIN_ORIGIN" \
    --files-public-base "https://files.${BASE_DOMAIN}:${FILES_PORT}" \
    --log-public-base "https://logs.${BASE_DOMAIN}:${LOG_PORT}" \
    --data-dir "$DATA_DIR" \
    --workers "$WORKERS"
