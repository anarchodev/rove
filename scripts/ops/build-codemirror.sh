#!/usr/bin/env bash
# Rebuild the vendored CodeMirror 6 bundle at
# `web/admin/codemirror.mjs`. Run after updating the upstream
# package versions or the entry's exported surface.
#
# Requires: npm + a temp dir with internet access.
#
# Side effect: overwrites web/admin/codemirror.mjs. The header
# comment is re-prepended after esbuild emits the bundle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

cat > "$BUILD_DIR/package.json" <<'EOF'
{ "name": "cm-bundle", "version": "0.0.0", "type": "module", "private": true }
EOF

cd "$BUILD_DIR"
npm install --no-audit --no-fund --silent \
  codemirror \
  @codemirror/state \
  @codemirror/view \
  @codemirror/commands \
  @codemirror/language \
  @codemirror/lang-javascript \
  @codemirror/lang-html \
  @codemirror/lang-css \
  esbuild

cp "$ROOT/web/admin/codemirror-entry.mjs" entry.mjs
./node_modules/.bin/esbuild entry.mjs \
  --bundle --format=esm --minify --target=es2020 \
  --outfile=cm.bundle.mjs

OUT="$ROOT/web/admin/codemirror.mjs"
{
  cat <<'HDR'
// Vendored CodeMirror 6 bundle for the Loop46 admin Code tab.
// Built from web/admin/codemirror-entry.mjs via esbuild --bundle
// --format=esm --minify --target=es2020. Regenerate via
// scripts/ops/build-codemirror.sh when bumping the upstream version.
//
// Exports: EditorView, EditorState, Compartment, lineNumbers,
// highlightActiveLine, keymap, defaultKeymap, history, historyKeymap,
// indentWithTab, syntaxHighlighting, defaultHighlightStyle,
// bracketMatching, indentOnInput, javascript, html, css.
HDR
  cat cm.bundle.mjs
} > "$OUT"

echo "wrote $OUT ($(wc -c < "$OUT") bytes)"
