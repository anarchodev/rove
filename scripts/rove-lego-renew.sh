#!/usr/bin/env bash
# Obtain or renew the Loop46 wildcard TLS cert via ACME DNS-01, using
# `lego` as the ACME client. Idempotent: first run issues, subsequent
# runs renew only when the cert is within lego's default renew
# window (30 days before expiry).
#
# Covers both `$BASE_DOMAIN` (apex) and `*.$BASE_DOMAIN` (wildcard)
# on a single cert — what rove-js needs for customer subdomain
# traffic when it terminates TLS directly.
#
# ── Required env vars ────────────────────────────────────────────────
#   BASE_DOMAIN        e.g. loop46.me
#   ACME_EMAIL         LE contact address (used for renewal reminders)
#   LEGO_PATH          where lego keeps state + certs
#                      (recommended: /etc/rove/tls — parent must exist
#                      and be writable by the running user)
#   ROVE_CERT_DIR      stable output dir rove-js reads from, e.g.
#                      /etc/rove/tls — symlinks are created there
#   DNS_PROVIDER       lego provider id (cloudflare, route53, gcloud,
#                      digitalocean, ...). Full list:
#                        https://go-acme.github.io/lego/dns/
#
# ── Provider-specific credentials ────────────────────────────────────
# Each provider reads its own env vars; examples:
#   Cloudflare  → CLOUDFLARE_DNS_API_TOKEN (token with DNS:edit on zone)
#   Route 53    → AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
#   Gcloud      → GCE_PROJECT, GCE_SERVICE_ACCOUNT_FILE
#
# ── Staging vs production ────────────────────────────────────────────
# Set ACME_STAGING=1 to use LE's staging endpoint (no rate limits,
# untrusted certs — useful for testing the plumbing). Default is
# production.
#
# ── Usage ────────────────────────────────────────────────────────────
# One-shot (interactive):
#   BASE_DOMAIN=loop46.me ACME_EMAIL=ops@example.com \
#   LEGO_PATH=/etc/rove/tls ROVE_CERT_DIR=/etc/rove/tls \
#   DNS_PROVIDER=cloudflare CLOUDFLARE_DNS_API_TOKEN=xxx \
#   scripts/rove-lego-renew.sh
#
# Typical: driven by systemd (see scripts/systemd/rove-cert-renew.*).

set -euo pipefail

: "${BASE_DOMAIN:?set to the root domain, e.g. loop46.me}"
: "${ACME_EMAIL:?set to the LE contact address}"
: "${LEGO_PATH:?set to the lego state dir, e.g. /etc/rove/tls}"
: "${ROVE_CERT_DIR:?set to the dir rove-js reads, e.g. /etc/rove/tls}"
: "${DNS_PROVIDER:?set to a lego provider id (cloudflare, route53, ...)}"

if ! command -v lego >/dev/null; then
    echo "error: lego not found on PATH; install from" \
         "https://github.com/go-acme/lego/releases" >&2
    exit 2
fi

mkdir -p "$LEGO_PATH" "$ROVE_CERT_DIR"

SERVER_FLAG=()
if [[ "${ACME_STAGING:-0}" == "1" ]]; then
    SERVER_FLAG=(--server "https://acme-staging-v02.api.letsencrypt.org/directory")
    echo "note: using LE staging endpoint — cert will be untrusted" >&2
fi

# lego names the output files after the FIRST `--domains` argument.
# We list the apex first, so the files land at
# `$LEGO_PATH/certificates/$BASE_DOMAIN.{crt,key}`. (If we swapped the
# order so the wildcard came first, lego would write
# `_.${BASE_DOMAIN}.{crt,key}` — the `*` gets sanitized to `_`.)
CERT_SRC="$LEGO_PATH/certificates/${BASE_DOMAIN}.crt"
KEY_SRC="$LEGO_PATH/certificates/${BASE_DOMAIN}.key"

# Pick `run` (first issuance) or `renew` (subsequent) based on whether
# lego already has state for this domain. `renew` is a no-op when the
# cert isn't near expiry, so daily timer runs are cheap.
if [[ -f "$CERT_SRC" ]]; then
    VERB=renew
    EXTRA_FLAGS=(--days 30)  # renew if within 30 days of expiry
else
    VERB=run
    EXTRA_FLAGS=()
fi

echo "lego: $VERB wildcard cert for *.${BASE_DOMAIN} (+ apex) via $DNS_PROVIDER"
lego \
    --path "$LEGO_PATH" \
    --email "$ACME_EMAIL" \
    --dns "$DNS_PROVIDER" \
    --domains "$BASE_DOMAIN" \
    --domains "*.${BASE_DOMAIN}" \
    --accept-tos \
    "${SERVER_FLAG[@]}" \
    "$VERB" "${EXTRA_FLAGS[@]}"

# Stable, lego-layout-independent paths for rove-js to pick up. Atomic
# via `ln -sfn`: if the symlinks already point at these files, this
# is a no-op; otherwise they're swapped in place.
ln -sfn "$CERT_SRC" "$ROVE_CERT_DIR/cert.pem"
ln -sfn "$KEY_SRC"  "$ROVE_CERT_DIR/key.pem"

# Tighten perms on the private key. lego already 0600's its own
# output; this is belt-and-suspenders in case LEGO_PATH differs from
# ROVE_CERT_DIR and permissions didn't follow.
chmod 0600 "$KEY_SRC"

echo "lego: ok — cert at $ROVE_CERT_DIR/cert.pem, key at $ROVE_CERT_DIR/key.pem"
