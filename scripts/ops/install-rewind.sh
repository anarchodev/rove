#!/bin/sh
# install-rewind.sh — download + install the `rewind` customer CLI.
#
#   curl -fsSL https://github.com/anarchodev/rove/releases/latest/download/install.sh | sh
#
# Env:
#   REWIND_VERSION      install a specific tag (e.g. v0.1.0); default: latest
#   REWIND_INSTALL_DIR  install dir; default: ~/.local/bin
#
# Picks the right prebuilt binary for this OS/arch, verifies its SHA256 against
# the release's SHA256SUMS, and installs it. Runtime dep: `curl` must be on PATH
# (the CLI shells out to it). Windows: download rewind-windows-x86_64.exe from
# the releases page manually (no shell installer).
set -eu

REPO="anarchodev/rove"
BIN_DIR="${REWIND_INSTALL_DIR:-$HOME/.local/bin}"

os=$(uname -s)
arch=$(uname -m)
case "$os" in
  Linux)  os=linux ;;
  Darwin) os=macos ;;
  *) echo "rewind: unsupported OS '$os' — for Windows, grab rewind-windows-x86_64.exe from https://github.com/$REPO/releases" >&2; exit 1 ;;
esac
case "$arch" in
  x86_64|amd64)  arch=x86_64 ;;
  aarch64|arm64) arch=aarch64 ;;
  *) echo "rewind: unsupported arch '$arch'" >&2; exit 1 ;;
esac
asset="rewind-${os}-${arch}"

if [ -n "${REWIND_VERSION:-}" ]; then
  base="https://github.com/$REPO/releases/download/$REWIND_VERSION"
else
  base="https://github.com/$REPO/releases/latest/download"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "rewind: downloading $asset …"
curl -fsSL "$base/$asset" -o "$tmp/rewind"

# Verify against SHA256SUMS if present in the release.
if curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS" 2>/dev/null; then
  want=$(grep " $asset\$" "$tmp/SHA256SUMS" | awk '{print $1}')
  if [ -n "$want" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      got=$(sha256sum "$tmp/rewind" | awk '{print $1}')
    else
      got=$(shasum -a 256 "$tmp/rewind" | awk '{print $1}')
    fi
    if [ "$want" != "$got" ]; then
      echo "rewind: checksum mismatch for $asset (want $want, got $got)" >&2
      exit 1
    fi
    echo "rewind: checksum ok"
  fi
fi

mkdir -p "$BIN_DIR"
chmod +x "$tmp/rewind"
mv "$tmp/rewind" "$BIN_DIR/rewind"
echo "rewind: installed → $BIN_DIR/rewind"

command -v curl >/dev/null 2>&1 || echo "rewind: note — needs 'curl' on PATH at runtime"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "rewind: add $BIN_DIR to your PATH" ;;
esac
"$BIN_DIR/rewind" --version 2>/dev/null || true
