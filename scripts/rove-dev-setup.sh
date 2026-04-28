#!/usr/bin/env bash
# Set up the local-dev TLS story for rove / Loop46.
#
# What this does (idempotent — safe to re-run):
#   1. Confirm `mkcert` is installed (errors with install hint otherwise).
#   2. `mkcert -install` to register the local CA into the system + browser
#      trust stores. No-op if already installed.
#   3. Create the loop46 data directory at the platform-default location:
#        Linux:   ${XDG_DATA_HOME:-$HOME/.local/share}/loop46/
#        macOS:   $HOME/Library/Application Support/loop46/
#   4. Generate a cert + key into that dir covering the domains rove's
#      smokes + dev workflows use:
#        *.test, test, *.api.test, api.test, localhost, 127.0.0.1, ::1
#      Files: dev-cert.pem + dev-key.pem
#   5. Symlink the mkcert root CA into the loop46 dir as ca-root.pem so
#      tools that need an explicit --cacert flag (e.g. the upcoming
#      loop46 CLI in non-system-trust setups) have a stable path.
#
# After this runs once, `js-worker --dev` will auto-discover the cert
# and listen TLS without any --tls-cert / --tls-key flags.

set -euo pipefail

# ── 1. mkcert installed? ─────────────────────────────────────────────
if ! command -v mkcert >/dev/null; then
    cat >&2 <<EOF
error: mkcert is not installed.

mkcert installs a local-dev certificate authority into your system trust
store. Install instructions:

  Linux (Debian/Ubuntu):  sudo apt install libnss3-tools && \\
                          curl -L https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-v1.4.4-linux-amd64 -o /usr/local/bin/mkcert && \\
                          sudo chmod +x /usr/local/bin/mkcert
  Linux (Fedora):         sudo dnf install nss-tools && \\
                          (download mkcert binary as above)
  macOS:                  brew install mkcert nss
  Other:                  https://github.com/FiloSottile/mkcert#installation

Then re-run this script.
EOF
    exit 2
fi

# ── 2. mkcert -install (idempotent) ──────────────────────────────────
echo "==> mkcert -install (registers local CA in system + browser trust stores)"
mkcert -install

# ── 3. Resolve loop46 data dir per OS ────────────────────────────────
case "$(uname -s)" in
    Linux)
        DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/loop46"
        ;;
    Darwin)
        DATA_DIR="$HOME/Library/Application Support/loop46"
        ;;
    *)
        # Fall back to the XDG path on unknown systems.
        DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/loop46"
        ;;
esac
mkdir -p "$DATA_DIR"
echo "==> loop46 data dir: $DATA_DIR"

CERT="$DATA_DIR/dev-cert.pem"
KEY="$DATA_DIR/dev-key.pem"

# ── 4. Generate cert covering the dev domains ────────────────────────
# Matches the public_suffix + admin_api_domain values our smokes use,
# plus localhost + loopback IPs for direct connections.
echo "==> mkcert generating cert into $CERT"
mkcert \
    -cert-file "$CERT" \
    -key-file "$KEY" \
    "*.test" "test" "*.api.test" "api.test" "localhost" "127.0.0.1" "::1"

# ── 5. Stable symlink to mkcert root CA ──────────────────────────────
CA_ROOT="$(mkcert -CAROOT)/rootCA.pem"
if [[ -f "$CA_ROOT" ]]; then
    ln -sf "$CA_ROOT" "$DATA_DIR/ca-root.pem"
    echo "==> symlinked $CA_ROOT → $DATA_DIR/ca-root.pem"
else
    echo "warning: mkcert -CAROOT/rootCA.pem not found at $CA_ROOT — skipping symlink" >&2
fi

cat <<EOF

setup complete.

Next:
  - Start the worker in dev mode (auto-loads the cert above):
      js-worker --dev --http localhost:8443 --public-suffix test ...
  - Browsers + curl + the loop46 CLI now trust *.test certs locally.
  - For tools that want an explicit CA bundle:
      $DATA_DIR/ca-root.pem
EOF
