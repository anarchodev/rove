#!/usr/bin/env bash
# Canonical dev TLS cert for local smokes / benches.
#
# rove-h2 serves ONE cert pair (single SSL_CTX — per-host SNI
# selection is Phase 2 of docs/auth-domain-plan.md). The two-domain
# split means that one cert must carry SANs for BOTH registrable
# domains the tests mirror from production:
#
#   *.rewindjsapp.localhost   customer tenants   (mirrors rewindjs.app)
#   *.rewindjscom.localhost   system surfaces    (mirrors rewindjs.com)
#                             — admin (app.), replay (replay.)
#
# This used to be a per-developer "run mkcert once" guess with no
# canonical SAN list; the two-domain work made that fragility load-
# bearing, so it's a committed script now. Re-run after pulling a
# change that alters the SAN set.
set -euo pipefail

# Mirror smoke_lib.loop46_data_dir() exactly — TlsBundle.from_env()
# reads dev-cert.pem / dev-key.pem / ca-root.pem from here.
if [[ -n "${LOOP46_DATA:-}" ]]; then
    DATA="$LOOP46_DATA"
elif [[ "$(uname -s)" == "Darwin" ]]; then
    DATA="$HOME/Library/Application Support/loop46"
else
    DATA="${XDG_DATA_HOME:-$HOME/.local/share}/loop46"
fi

if ! command -v mkcert >/dev/null 2>&1; then
    echo "error: mkcert not found in PATH." >&2
    echo "  install it: https://github.com/FiloSottile/mkcert" >&2
    exit 1
fi

mkdir -p "$DATA"

mkcert \
    -cert-file "$DATA/dev-cert.pem" \
    -key-file "$DATA/dev-key.pem" \
    "*.rewindjsapp.localhost" rewindjsapp.localhost \
    "*.rewindjscom.localhost" rewindjscom.localhost

# smoke_lib passes --cacert ca-root.pem to curl; copy mkcert's CA so
# the smokes trust this cert without touching the system trust store.
# Skip the copy if ca-root.pem already resolves to the same file (a
# prior setup may have sym/hard-linked it — cp would error under -e).
CA_SRC="$(mkcert -CAROOT)/rootCA.pem"
CA_DST="$DATA/ca-root.pem"
if [[ "$(readlink -f "$CA_SRC" 2>/dev/null)" != "$(readlink -f "$CA_DST" 2>/dev/null)" ]]; then
    cp "$CA_SRC" "$CA_DST"
fi

echo "wrote:"
echo "  $DATA/dev-cert.pem"
echo "  $DATA/dev-key.pem"
echo "  $DATA/ca-root.pem"
echo "SANs: *.rewindjsapp.localhost rewindjsapp.localhost" \
     "*.rewindjscom.localhost rewindjscom.localhost"
echo
echo "browser smokes (notifications_browser_smoke) additionally need" \
     "the CA in the system/NSS trust store: run 'mkcert -install' once."
