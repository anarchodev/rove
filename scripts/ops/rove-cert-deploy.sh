#!/bin/bash
#
# rove-cert-deploy.sh — distribute a renewed Tier-1 platform wildcard to
# every front, then verify every front is serving it (see rove
# docs/architecture/configuration-and-network.md, "Two-tier TLS architecture";
# the renewal schedule + env live in rewind-infra, in its certs runbook).
#
# Two ways in, same work:
#   • rove-cert-renew.sh calls it as the deploy user after lego issues or
#     renews (the fleet's arrangement — no root anywhere, the DNS token
#     arrives through the unit's EnvironmentFile).
#   • as a certbot deploy hook, dropped in /etc/letsencrypt/renewal-hooks/
#     deploy/ on the one host running certbot as root.
# The source pair is ROVE_CERT_SRC/ROVE_KEY_SRC, defaulting to certbot's
# renewed lineage. It installs that pair at the front units'
# REWIND_TLS_CERT/KEY paths locally and on every peer host, then VERIFIES
# that every front is serving it.
#
# No restart: the front reloads the default context when the pair changes on
# disk, within one cert-sync tick (`CertSync.reloadDefault` in
# src/front/main.zig — the platform wildcard). Restarting instead would cut
# every in-flight request on the node, on the one path that has to run for
# every host to keep serving. The verification below is what makes the reload
# load-bearing: a front that did not pick the certificate up fails this hook
# loudly, rather than serving a retired certificate until someone probes it by
# hand.
#
# Each file is written beside its target and renamed into place, so a front
# polling the pair never reads a half-written PEM. The window where the key is
# new and the cert is not (they cannot be renamed in one instant) is a
# mismatched pair, which the reload refuses — keeping the old pair in service —
# and retries on the next tick.
#
# Peer access: root on the certbot host needs an ssh key authorized for
# ${DEPLOY_USER} on each peer (public IP — the vRack firewall doesn't
# carry :22).
#
# The renewing node is itself a front, so "distribution" includes installing
# the pair locally; every node ends up with byte-identical files.
#
# Usage: no arguments to distribute + verify, or `--verify-only` to re-run
# just the convergence check against the current source pair — "do all the
# fronts serve the same certificate?" asked on demand, e.g. after a deploy.
set -euo pipefail

LINEAGE=${RENEWED_LINEAGE:-/etc/letsencrypt/live/platform}
CERT_SRC=${ROVE_CERT_SRC:-$LINEAGE/fullchain.pem}
KEY_SRC=${ROVE_KEY_SRC:-$LINEAGE/privkey.pem}
DEPLOY_USER=${ROVE_DEPLOY_USER:-rove}
# Seconds to wait for every front to serve the new certificate. One cert-sync
# tick is REWIND_CERT_SYNC_MS (2s by default); the rest of the budget covers a
# front that happens to be restarting for an unrelated reason.
VERIFY_TIMEOUT=${ROVE_CERT_VERIFY_TIMEOUT:-60}
# The port the fronts terminate TLS on. Overridable so the convergence check
# can be exercised against a real front rather than only read (the smoke,
# scripts/smoke/front_cert_deploy_smoke.py).
CERT_PORT=${ROVE_CERT_PORT:-443}
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

# Running AS the deploy user (the renew timer) installs into our own home
# with no ownership to set; running as root (the certbot hook) has to look
# the user's home up and hand the files over.
if [ "$(id -un)" = "$DEPLOY_USER" ]; then
    TLS_DIR="$HOME/.rove/tls"
    OWNER_FLAGS=()
else
    TLS_DIR="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)/.rove/tls"
    OWNER_FLAGS=(-o "$DEPLOY_USER" -g "$DEPLOY_USER")
fi

# The `notAfter` of the certificate a front is serving on CERT_PORT. No
# -servername: the front answers an absent SNI with its default context,
# which is exactly the wildcard being deployed, so a per-host custom-domain
# cert cannot mask the thing under test.
served_not_after() {
    local target=$1
    echo | openssl s_client -connect "$target:$CERT_PORT" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null \
        | cut -d= -f2
}

# Fail unless every front converges on `want` within VERIFY_TIMEOUT. This is
# the check that was missing when one of three nodes served a retired
# certificate for two days: the fleet was diverged, every node reported
# healthy, and nothing asked the one question that tells those apart.
verify_converged() {
    local want=$1 deadline=$((SECONDS + VERIFY_TIMEOUT)) pending ok target got
    pending="127.0.0.1 $PEERS"
    while :; do
        ok=""
        for target in $pending; do
            got=$(served_not_after "$target")
            if [ "$got" = "$want" ]; then
                echo "rove-cert-deploy: $target serves notAfter=$got"
            else
                ok="$ok $target"
            fi
        done
        pending="$(echo "$ok" | xargs)"
        [ -z "$pending" ] && { echo "rove-cert-deploy: all fronts converged on notAfter=$want"; return 0; }
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "rove-cert-deploy: NOT SERVING the new certificate after ${VERIFY_TIMEOUT}s:" >&2
            for target in $pending; do
                echo "  $target serves notAfter=$(served_not_after "$target") want=$want" >&2
            done
            echo "  the certificate is on disk there; the front has not picked it up." >&2
            echo "  Check: journalctl --user -u rewind-front -n 50 | grep -i cert" >&2
            return 1
        fi
        sleep 3
    done
}

WANT=$(openssl x509 -noout -enddate -in "$CERT_SRC" | cut -d= -f2)

if [ "${1:-}" = "--verify-only" ]; then
    verify_converged "$WANT"
    exit $?
fi

# ── local front ──────────────────────────────────────────────────────────
install -d "${OWNER_FLAGS[@]}" -m0755 "$TLS_DIR"
install "${OWNER_FLAGS[@]}" -m0600 "$KEY_SRC" "$TLS_DIR/platform.key.new"
install "${OWNER_FLAGS[@]}" -m0644 "$CERT_SRC" "$TLS_DIR/platform.crt.new"
mv "$TLS_DIR/platform.key.new" "$TLS_DIR/platform.key"
mv "$TLS_DIR/platform.crt.new" "$TLS_DIR/platform.crt"
echo "rove-cert-deploy: local front updated"

# ── peer fronts ──────────────────────────────────────────────────────────
for peer in $PEERS; do
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$DEPLOY_USER@$peer" \
    'mkdir -p ~/.rove/tls && umask 077 && cat > ~/.rove/tls/platform.key.new' \
    < "$KEY_SRC"
  ssh -o BatchMode=yes "$DEPLOY_USER@$peer" \
    'cat > ~/.rove/tls/platform.crt.new && chmod 644 ~/.rove/tls/platform.crt.new
     mv ~/.rove/tls/platform.key.new ~/.rove/tls/platform.key
     mv ~/.rove/tls/platform.crt.new ~/.rove/tls/platform.crt
     ' < "$CERT_SRC"
  echo "rove-cert-deploy: $peer updated"
done

verify_converged "$WANT"
