#!/usr/bin/env bash
#
# chain_fusion_ab.sh — controlled A/B for the internal_schedules.zig
# same-tenant continuation-fusion change.
#
#   fusion   = working tree as-is (src/js/internal_schedules.zig
#              carries the fusion loop)
#   baseline = the SAME tree with ONLY internal_schedules.zig reverted
#              (git stash of that one path)
#
# Both built ReleaseFast (perf numbers off a Debug build are
# meaningless — reference_benchmarking). The new bench files
# (chainbench handler, manifest, driver) are untracked, so a
# single-path stash leaves them in place for both runs. Unrelated
# tracked edits (docs) are untouched.
#
# Usage: scripts/chain_fusion_ab.sh [depth] [count]
#   env passthrough: CHAIN_TIMEOUT_S
set -euo pipefail

cd "$(dirname "$0")/.."
DEPTH="${1:-64}"
COUNT="${2:-32}"
FILE="src/js/internal_schedules.zig"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

build() { echo ">> zig build -Doptimize=ReleaseFast ($1)"; \
          zig build -Doptimize=ReleaseFast >/dev/null; }

run() { # $1=tag
  CHAIN_DEPTH="$DEPTH" CHAIN_COUNT="$COUNT" CHAIN_TAG="$1" \
    python3 scripts/chain_fusion_bench.py 2>&1 | tee "$OUT/$1.log" \
    | grep -E '^(ok|METRIC|FAIL)' || true
}

if ! git diff --quiet -- "$FILE"; then
  echo "== fusion build =="
  build fusion
  run fusion
else
  echo "ERROR: $FILE has no uncommitted changes — nothing to A/B." >&2
  exit 1
fi

echo "== baseline build (stashing $FILE only) =="
git stash push -q -- "$FILE"
restore() { git stash pop -q || true; }
trap 'restore; rm -rf "$OUT"' EXIT
build baseline
run baseline

echo "== restore fusion tree =="
restore
trap 'rm -rf "$OUT"' EXIT
build "fusion-restore"

echo
echo "================ A/B RESULT (depth=$DEPTH count=$COUNT) ================"
grep -h '^METRIC' "$OUT/fusion.log" "$OUT/baseline.log" 2>/dev/null || {
  echo "missing METRIC line(s) — inspect $OUT/*.log"; exit 1; }
echo "======================================================================="
python3 - "$OUT/fusion.log" "$OUT/baseline.log" <<'PY'
import re, sys
def metric(p):
    for ln in open(p):
        if ln.startswith("METRIC"):
            return dict(kv.split("=",1) for kv in ln.split()[1:])
    return {}
f, b = metric(sys.argv[1]), metric(sys.argv[2])
if not f or not b:
    sys.exit("could not parse both METRIC lines")
def d(k, lower_better=True):
    fv, bv = float(f[k]), float(b[k])
    if bv == 0: return f"{k}: fusion={fv} baseline={bv}"
    pct = (fv - bv) / bv * 100.0
    better = (pct < 0) if lower_better else (pct > 0)
    arrow = "improvement" if better else "REGRESSION"
    return f"{k}: fusion={fv} baseline={bv} ({pct:+.1f}% {arrow})"
print(d("wall_s"))
print(d("chains_per_s", lower_better=False))
PY
