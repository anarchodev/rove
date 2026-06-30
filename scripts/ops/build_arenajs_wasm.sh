#!/usr/bin/env bash
# Rebuild the arenajs WASM artifacts that drive the replay shell.
#
# The vendored snapshot at `vendor/arenajs/` is consumed by rove's
# native Zig build (server-side QJS) — it has only the C library
# sources + headers + arena reactor that the Zig build pulls in.
# The WASM-side build needs additional files (CMakeLists.txt,
# qjs-arena-reactor.c, qjs-arena-replay-bindings.c, test fixtures)
# that don't live in the vendored snapshot — those stay in the
# upstream tree at `$ARENAJS_SRC`.
#
# Usage:
#   scripts/ops/build_arenajs_wasm.sh
#
# Environment knobs (with defaults):
#   ARENAJS_SRC   Path to the arenajs source tree.
#                 Default: $HOME/src/arenajs
#   EMSDK         Path to the emsdk install.
#                 Default: $HOME/src/emsdk
#
# Output:
#   web/replay/_static/qjs_arena_wasm.{wasm,js}
#
# Workflow when changing arenajs:
#   1. Edit C sources in $ARENAJS_SRC/qjs-arena-replay-bindings.c
#      (or other arenajs files) directly.
#   2. Run this script.
#   3. If the Zig-side server build also needs the change, re-sync
#      the affected files into vendor/arenajs/ — the C library
#      sources (quickjs.c, qjs-arena.c, headers) live in BOTH the
#      upstream tree and the vendored snapshot; the replay-bindings
#      files live only upstream.
#   4. Verify with `zig build test` + `python3 scripts/replay_wasm_smoke.py`.
#   5. Commit the resulting changes to both `web/replay/_static/`
#      and (if synced) `vendor/arenajs/`.
#
# Reproducibility: a clean rebuild against an unmodified arenajs
# upstream commit produces a byte-identical WASM. As of 2026-05-26
# the vendored snapshot at `9a22a55` produces:
#   qjs_arena_wasm.wasm: sha256 0309d0f3...e6d4725b

set -euo pipefail

ARENAJS_SRC="${ARENAJS_SRC:-$HOME/src/arenajs}"
EMSDK="${EMSDK:-$HOME/src/emsdk}"

ROVE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="$ROVE_ROOT/web/replay/_static"

if [[ ! -d "$ARENAJS_SRC" ]]; then
    echo "error: ARENAJS_SRC=$ARENAJS_SRC does not exist" >&2
    exit 1
fi
if [[ ! -f "$EMSDK/emsdk_env.sh" ]]; then
    echo "error: EMSDK=$EMSDK does not look like an emsdk install (no emsdk_env.sh)" >&2
    exit 1
fi
if [[ ! -d "$OUT_DIR" ]]; then
    echo "error: rove output dir $OUT_DIR does not exist" >&2
    exit 1
fi

# Source emsdk in a subshell-friendly way. `emsdk_env.sh` mutates
# PATH + sets EM_CONFIG. After this line, `emcmake` / `emcc` resolve.
# shellcheck disable=SC1091
source "$EMSDK/emsdk_env.sh" >/dev/null

cd "$ARENAJS_SRC"

BUILD_DIR="build-wasm"
if [[ ! -d "$BUILD_DIR" ]]; then
    echo "==> emcmake cmake -B $BUILD_DIR"
    emcmake cmake -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
fi

echo "==> cmake --build $BUILD_DIR --target qjs_arena_wasm"
cmake --build "$BUILD_DIR" --target qjs_arena_wasm -j

cp "$BUILD_DIR/qjs_arena_wasm.wasm" "$OUT_DIR/"
cp "$BUILD_DIR/qjs_arena_wasm.js"   "$OUT_DIR/"

echo
echo "==> WASM artifacts copied to $OUT_DIR/"
sha256sum "$OUT_DIR/qjs_arena_wasm.wasm" "$OUT_DIR/qjs_arena_wasm.js"
