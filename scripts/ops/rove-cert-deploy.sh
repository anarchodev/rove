#!/bin/bash
#
# rove-cert-deploy.sh — certbot deploy hook for the Tier-1 platform
# wildcard (see rove docs/architecture/configuration-and-network.md, "Two-tier
# TLS architecture"; our certbot/Cloudflare distribution lives in rewind-infra).
#
# Install at /etc/letsencrypt/renewal-hooks/deploy/ on the ONE host that
# runs certbot; certbot executes it as root after every successful
# issuance/renewal (including the first). It installs the renewed cert at
# the front units' REWIND_TLS_CERT/KEY paths for the local deploy user and
# every peer host, then restarts the (stateless) fronts — restart, not
# reload: the front has no proven cert hot-reload (plan §10 open item).
#
# Peer access: root on the certbot host needs an ssh key authorized for
# ${DEPLOY_USER} on each peer (public IP — the vRack firewall doesn't
# carry :22).
set -euo pipefail

LINEAGE=${RENEWED_LINEAGE:-/etc/letsencrypt/live/platform}
DEPLOY_USER=rove
# Peer hosts running rewind-front (ssh targets) to distribute the renewed
# cert to — the OTHER fronts besides this (the certbot) host. No prod hosts
# are hardcoded here (this script ships in a public repo): set via
# ROVE_CERT_PEERS, or list them (space/newline-separated) in a root-readable
# /etc/rove/cert-peers on the certbot host. Empty ⇒ local front only.
PEERS="${ROVE_CERT_PEERS:-}"
if [ -z "$PEERS" ] && [ -r /etc/rove/cert-peers ]; then
    PEERS="$(tr '\n' ' ' < /etc/rove/cert-peers)"
fi
[ -z "$PEERS" ] && echo "rove-cert-deploy: no peers (ROVE_CERT_PEERS / /etc/rove/cert-peers) — updating local front only" >&2

HOME_DIR=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)
TLS_DIR="$HOME_DIR/.rove/tls"

restart_front='XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user try-restart rewind-front.service'

# ── local front ──────────────────────────────────────────────────────────
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m0755 "$TLS_DIR"
install -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m0644 "$LINEAGE/fullchain.pem" "$TLS_DIR/platform.crt"
install -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m0600 "$LINEAGE/privkey.pem" "$TLS_DIR/platform.key"
runuser -u "$DEPLOY_USER" -- bash -c "$restart_front"
echo "rove-cert-deploy: local front updated"

# ── peer fronts ──────────────────────────────────────────────────────────
for peer in $PEERS; do
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$DEPLOY_USER@$peer" \
    'mkdir -p ~/.rove/tls && umask 077 && cat > ~/.rove/tls/platform.key.new' \
    < "$LINEAGE/privkey.pem"
  ssh -o BatchMode=yes "$DEPLOY_USER@$peer" \
    'cat > ~/.rove/tls/platform.crt.new && chmod 644 ~/.rove/tls/platform.crt.new
     mv ~/.rove/tls/platform.crt.new ~/.rove/tls/platform.crt
     mv ~/.rove/tls/platform.key.new ~/.rove/tls/platform.key
     '"$restart_front" < "$LINEAGE/fullchain.pem"
  echo "rove-cert-deploy: $peer updated"
done
