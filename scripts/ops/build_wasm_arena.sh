#!/usr/bin/env bash
# Build the browser replay arena wasm IN-TREE: rove's Zig (the common
# binding + guards + the arena delegate, src/arena/root.zig) compiled to a
# wasm32-emscripten archive and linked into arenajs's qjs_arena_wasm via its
# ROVE_ARENA seam — so the arena runs the SAME compiled checks the worker
# and the sim run (the engine-parity epic; this is what retired the emitted
# JS rules).
#
# Usage: build_wasm_arena.sh <arenajs-src-dir> <out-dir>
#   <arenajs-src-dir>  the fetched arenajs package (build.zig passes it)
#   <out-dir>          receives qjs_arena_wasm.js + .wasm + librove_arena.a
#
# Needs emsdk: $EMSDK, or ~/src/emsdk as the fallback. The build dir lives
# under <out-dir>/build (the arenajs source tree is read-only package cache).
set -euo pipefail

ARENAJS_SRC="${1:?arenajs source dir}"
OUT_DIR="${2:?output dir}"
ROVE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -z "${EMSDK:-}" ]; then
    if [ -f "$HOME/src/emsdk/emsdk_env.sh" ]; then
        # shellcheck disable=SC1091
        source "$HOME/src/emsdk/emsdk_env.sh" >/dev/null 2>&1
    else
        echo "build_wasm_arena: emsdk not found — set \$EMSDK or install to ~/src/emsdk" >&2
        exit 2
    fi
fi
SYSROOT="$EMSDK/upstream/emscripten/cache/sysroot"

mkdir -p "$OUT_DIR"
ARCHIVE="$OUT_DIR/librove_arena.a"

echo "== rove arena archive (zig → wasm32-emscripten) =="
zig build-lib -target wasm32-emscripten -O ReleaseSmall -lc \
    -I "$ARENAJS_SRC" -I "$SYSROOT/include" --sysroot "$SYSROOT" \
    -femit-bin="$ARCHIVE" \
    --dep rove-binding -Mroot="$ROVE_ROOT/src/arena/root.zig" \
    --dep rove-guards --dep interaction-digest -Mrove-binding="$ROVE_ROOT/src/binding/root.zig" \
    --dep rove-reserved --dep rove-sizing -Mrove-guards="$ROVE_ROOT/src/guards/root.zig" \
    -Minteraction-digest="$ROVE_ROOT/src/tape/interaction_digest.zig" \
    --dep rove-reserved -Mrove-sizing="$ROVE_ROOT/src/sizing/root.zig" \
    -Mrove-reserved="$ROVE_ROOT/src/reserved/root.zig"

echo "== qjs_arena_wasm (emcc, arenajs C + the archive) =="
BUILD_DIR="$OUT_DIR/build"
rm -rf "$BUILD_DIR"  # the package path changes with every pin bump; never reuse a cache
QJS_ARENA_WASM_ONLY=1 ROVE_ARENA_LIB="$ARCHIVE" emcmake cmake -S "$ARENAJS_SRC" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release >/dev/null
QJS_ARENA_WASM_ONLY=1 ROVE_ARENA_LIB="$ARCHIVE" emmake make -C "$BUILD_DIR" qjs_arena_wasm -j"$(nproc)" \
    | tail -1

cp "$BUILD_DIR/qjs_arena_wasm.js" "$BUILD_DIR/qjs_arena_wasm.wasm" "$OUT_DIR/"
sha256sum "$OUT_DIR/qjs_arena_wasm.js" "$OUT_DIR/qjs_arena_wasm.wasm" | sed "s|$OUT_DIR/||"
echo "== wasm arena built → $OUT_DIR =="
