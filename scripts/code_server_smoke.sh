#!/usr/bin/env bash
# End-to-end smoke test for the rove-code-server background thread.
#
# Spawns the `code-server-standalone` binary, reads the bound port off
# stdout, then drives upload / deploy / source / error paths via curl.
#
# Exits non-zero on any mismatch.

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-cs-smoke}"
BIN="${BIN:-./zig-out/bin/code-server-standalone}"

if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN not found — run 'zig build install' first" >&2
    exit 2
fi

rm -rf "$DATA_DIR"

"$BIN" --data-dir "$DATA_DIR" >/tmp/cs-smoke.out 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true' EXIT

# Wait for the "listening on port N" line.
for _ in $(seq 1 20); do
    if grep -q "listening on port" /tmp/cs-smoke.out; then break; fi
    sleep 0.05
done
PORT=$(grep -oE 'port [0-9]+' /tmp/cs-smoke.out | awk '{print $2}')
if [[ -z "${PORT:-}" ]]; then
    echo "FAIL: code-server did not bind a port" >&2
    cat /tmp/cs-smoke.out >&2
    exit 1
fi
echo "code-server listening on port $PORT"

expect() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL $label: expected $expected, got $actual" >&2
        exit 1
    fi
    echo "ok  $label: $actual"
}

SOURCE='export function handler() { return "hi from smoke"; }'

# Upload a source file.
code=$(curl -s --http2-prior-knowledge -o /dev/null -w '%{http_code}' \
    -X POST -H "X-Rove-Path: index.mjs" \
    --data-binary "$SOURCE" \
    "http://127.0.0.1:$PORT/acme/upload")
expect "upload /acme index.mjs" 204 "$code"

# Missing header → 400.
code=$(curl -s --http2-prior-knowledge -o /dev/null -w '%{http_code}' \
    -X POST --data-binary 'x' \
    "http://127.0.0.1:$PORT/acme/upload")
expect "upload without header" 400 "$code"

# Deploy the working tree.
body=$(curl -s --http2-prior-knowledge \
    -X POST \
    "http://127.0.0.1:$PORT/acme/deploy")
echo "ok  deploy /acme: id=$(echo "$body" | tr -d '\n')"
case "$body" in
    1*) : ;;
    *) echo "FAIL deploy expected id 1, got '$body'" >&2; exit 1 ;;
esac

# Find the source blob on disk by grepping for known content. (The
# blob dir holds both the source and the bytecode — only the source
# matches plain-text grep.)
SRC_BLOB=""
for f in "$DATA_DIR"/acme/code-blobs/*; do
    if grep -q "hi from smoke" "$f" 2>/dev/null; then
        SRC_BLOB="$(basename "$f")"
        break
    fi
done
if [[ -z "$SRC_BLOB" ]]; then
    echo "FAIL: could not find source blob on disk" >&2
    exit 1
fi

# Fetch the source blob over HTTP.
code=$(curl -s --http2-prior-knowledge -o /tmp/cs-src.out -w '%{http_code}' \
    "http://127.0.0.1:$PORT/acme/source/$SRC_BLOB")
expect "GET /source valid hash" 200 "$code"
if ! grep -q "hi from smoke" /tmp/cs-src.out; then
    echo "FAIL: fetched source does not match upload" >&2
    cat /tmp/cs-src.out >&2
    exit 1
fi
echo "ok  source bytes match"

# Source fetch with a bogus hash → 404.
code=$(curl -s --http2-prior-knowledge -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$PORT/acme/source/00000000000000000000000000000000")
expect "GET /source bogus hash" 404 "$code"

# Unknown path → 404.
code=$(curl -s --http2-prior-knowledge -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$PORT/unknown")
expect "GET /unknown" 404 "$code"

echo "PASS code-server smoke"
