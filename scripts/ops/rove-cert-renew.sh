#!/usr/bin/env bash
#
# rove-cert-renew.sh — issue or renew the Tier-1 platform wildcard over ACME
# DNS-01 (lego), then hand it to rove-cert-deploy.sh for distribution +
# verification. Driven by rove-cert-renew.timer on ONE node of the fleet
# (the renewing node); the units, the env file and the peer list live in
# rewind-infra (its certs runbook has the install steps).
#
# Wildcards are DNS-01 only, so the in-tree HTTP-01 issuer that serves
# customer custom domains cannot produce this certificate — the platform's
# own wildcard is the one certificate that needs an external client. It
# covers every first-party and tenant host, so nothing else in the fleet has
# a blast radius like it: when it expires, every name stops answering at
# once, months of warning and no health check the wiser.
#
# Runs as the deploy user (no root): lego keeps its account key + certificates
# under $LEGO_PATH in that user's home, the DNS token arrives through the
# unit's EnvironmentFile, and distribution is user→user over ssh.
#
# ── Required env ─────────────────────────────────────────────────────────
#   ROVE_CERT_DOMAINS   space-separated SAN list. The FIRST entry names
#                       lego's output files, so it must be a bare name:
#                       lego sanitizes `*` to `_`, and a lineage called
#                       `_.rewindjs.app` is a path nobody guesses later.
#   ACME_EMAIL          contact address (expiry notices, account recovery)
#   LEGO_PATH           lego state dir (account key + certificates)
#   DNS_PROVIDER        lego provider id, e.g. `cloudflare`
#   plus that provider's own credential vars — for Cloudflare,
#   CLOUDFLARE_DNS_API_TOKEN, scoped to Zone.DNS:Edit + Zone:Read on
#   exactly the zones in ROVE_CERT_DOMAINS and nothing else.
#
# ── Optional ─────────────────────────────────────────────────────────────
#   ACME_STAGING=1      LE staging endpoint — untrusted certs, no rate
#                       limits. The whole path is worth one staging run
#                       before the first real issuance: a token with the
#                       wrong zone scope fails identically in both, and
#                       production issuance is rate-limited per week.
#   ROVE_CERT_RENEW_DAYS  renew this many days before expiry (default 30)
#   ROVE_CERT_PEERS     passed through to rove-cert-deploy.sh
set -euo pipefail

: "${ROVE_CERT_DOMAINS:?space-separated SAN list, apex first}"
: "${ACME_EMAIL:?the ACME contact address}"
: "${LEGO_PATH:?lego state dir, e.g. \$HOME/.rove/acme}"
: "${DNS_PROVIDER:?a lego provider id (cloudflare, route53, ...)}"

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_HOOK="${ROVE_CERT_DEPLOY_HOOK:-$HERE/rove-cert-deploy.sh}"
RENEW_DAYS="${ROVE_CERT_RENEW_DAYS:-30}"

command -v lego >/dev/null || {
    echo "rove-cert-renew: lego not on PATH — install from" \
         "https://github.com/go-acme/lego/releases" >&2
    exit 2
}
[ -x "$DEPLOY_HOOK" ] || {
    echo "rove-cert-renew: no deploy hook at $DEPLOY_HOOK" >&2
    exit 2
}

# shellcheck disable=SC2206
DOMAINS=($ROVE_CERT_DOMAINS)
LINEAGE_NAME=${DOMAINS[0]}
case "$LINEAGE_NAME" in
    \*.*) echo "rove-cert-renew: list the apex first — a leading wildcard names the files '_.${LINEAGE_NAME#\*.}'" >&2; exit 2 ;;
esac

DOMAIN_FLAGS=()
for d in "${DOMAINS[@]}"; do DOMAIN_FLAGS+=(--domains "$d"); done

SERVER_FLAG=()
if [ "${ACME_STAGING:-0}" = "1" ]; then
    SERVER_FLAG=(--server "https://acme-staging-v02.api.letsencrypt.org/directory")
    echo "rove-cert-renew: LE STAGING endpoint — the result is untrusted by browsers" >&2
fi

mkdir -p "$LEGO_PATH"
CERT_SRC="$LEGO_PATH/certificates/${LINEAGE_NAME}.crt"
KEY_SRC="$LEGO_PATH/certificates/${LINEAGE_NAME}.key"

# `renew` is a no-op outside the window, so a daily timer is cheap; `run` is
# the first issuance. Distribution is driven by whether the bytes actually
# changed, not by which verb ran: a renewal that lego declined must not
# restart the distribution+verification cycle, and a `run` on a node that
# already has the current certificate must not either.
before=""
[ -f "$CERT_SRC" ] && before=$(sha256sum "$CERT_SRC" | cut -d' ' -f1)
if [ -n "$before" ]; then
    VERB=renew
    VERB_FLAGS=(--days "$RENEW_DAYS")
else
    VERB=run
    VERB_FLAGS=()
fi

echo "rove-cert-renew: lego $VERB ${ROVE_CERT_DOMAINS} via $DNS_PROVIDER"
lego \
    --path "$LEGO_PATH" \
    --email "$ACME_EMAIL" \
    --dns "$DNS_PROVIDER" \
    "${DOMAIN_FLAGS[@]}" \
    --accept-tos \
    "${SERVER_FLAG[@]}" \
    "$VERB" "${VERB_FLAGS[@]}"

after=$(sha256sum "$CERT_SRC" | cut -d' ' -f1)
if [ "$before" = "$after" ]; then
    echo "rove-cert-renew: unchanged (expires $(openssl x509 -noout -enddate -in "$CERT_SRC" | cut -d= -f2))"
    exit 0
fi

echo "rove-cert-renew: new certificate, expires $(openssl x509 -noout -enddate -in "$CERT_SRC" | cut -d= -f2)"
ROVE_CERT_SRC="$CERT_SRC" ROVE_KEY_SRC="$KEY_SRC" "$DEPLOY_HOOK"
