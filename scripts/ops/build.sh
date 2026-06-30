#!/usr/bin/env bash
#
# build.sh — build the V2 deploy binaries (ReleaseFast) + run the test gate.
#
# The BUILD half of the deploy split: this stays in the public rove repo and
# owns "produce shippable binaries from this checkout". The DEPLOY half (ship +
# restart, rolling/genesis orchestration, host topology) lives in the private
# operator repo (rewind-infra `scripts/deploy.sh`), which calls this script
# before shipping. Run it standalone to validate a build, or let deploy drive it.
#
# Output: zig-out/bin/{rewind-worker,rewind-cp,rewind-front,rewind-logs,rewind-ops}.
#
# Build a CONTROLLED delta: check out the exact commit you intend to ship, then
# run this — `deploy.sh` ships whatever this leaves in zig-out/bin.
#
# Usage:
#   scripts/ops/build.sh                 # build all deploy binaries + test gate
#   ROVE_SKIP_TESTS=1 scripts/ops/build.sh   # binaries only (skip the heavy gate)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKIP_TESTS="${ROVE_SKIP_TESTS:-0}"
OUT="$REPO_ROOT/zig-out/bin"

# All deploy-relevant binaries. The four shipped per node + rewind-ops (the
# operator driver for genesis; runs on the deploy box, not shipped). Building
# rewind-ops unconditionally keeps this mode-free; the deploy uses it only for
# genesis.
BINS=(rewind-worker rewind-cp rewind-front rewind-logs rewind-ops)

c_info=$'\033[1;36m'; c_ok=$'\033[1;32m'; c_err=$'\033[1;31m'; c_off=$'\033[0m'
log(){ printf '%s== %s ==%s\n' "$c_info" "$*" "$c_off"; }
ok(){  printf '%s   ✓ %s%s\n' "$c_ok" "$*" "$c_off"; }
warn(){ printf '%s   ! %s%s\n' "$c_err" "$*" "$c_off"; }
die(){ printf '%sFATAL: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

log "Building V2 binaries (ReleaseFast): ${BINS[*]}"
( cd "$REPO_ROOT" && zig build "${BINS[@]}" -Doptimize=ReleaseFast ) || die "build failed"
for b in "${BINS[@]}"; do [ -x "$OUT/$b" ] || die "missing build output: $OUT/$b"; done
ok "built ${BINS[*]}"

if [ "$SKIP_TESTS" = 1 ]; then
    warn "skipping tests (ROVE_SKIP_TESTS=1)"
else
    log "Test gate"
    ( cd "$REPO_ROOT" && zig build v2-test ) || die "v2-test failed — not shipping"
    ( cd "$REPO_ROOT" && zig build test )    || die "zig build test failed — not shipping"
    ok "tests green"
fi

ok "build complete — binaries in $OUT"
