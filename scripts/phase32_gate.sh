#!/usr/bin/env bash
#
# phase32_gate.sh — the parity + perf gate for effect-reification
# Phase 3.2 (migrate the H2 reference path off the hand-rolled
# `RaftWait` component onto `effect.Continuation` + a unified
# `reconcile()`; delete the paired `Cmd.respond` parked_units coupling
# and the `pending_txns.contains()` window-closer).
#
# The migration's whole cost is proving observable behavior didn't
# move. This runner is that proof. Run it GREEN on the current tree,
# do the migration, run it GREEN again.
#
#   # 1. baseline (current tree, ReleaseFast for the perf number):
#   zig build -Doptimize=ReleaseFast install
#   python3 scripts/raft_pending_perf_bench.py --record
#   scripts/phase32_gate.sh            # correctness should pass too
#
#   # 2. after the migration:
#   zig build -Doptimize=ReleaseFast install
#   scripts/phase32_gate.sh            # must still pass, incl. --check
#
# Coverage manifest — which raft_pending arm / risk each test gates:
#
#   raft_pending_response (commit + batching + durability)
#       → raft_pending_parity_smoke.py        [NEW, this PR]
#   raft_pending_cont (next(...) trampoline commit move)
#       → chained_dispatch_smoke.py
#   raft_pending_stream (streamed chunk commit + close)
#       → streaming_smoke.py
#       → streaming_resume_fault_inj_smoke.py  (stream fault arm)
#   fault downgrade → 503 (rollbackAndTake + move to response_in)
#       → leader_failover_smoke.py
#       → streaming_resume_fault_inj_smoke.py
#   cross-worker concurrent same-tenant (kvexp NotChainHead retry)
#       → heldsync_multiworker_smoke.py
#       → raft_pending_parity_smoke.py with WORKERS=4 (default)
#   hot write-commit throughput (no perf regression)
#       → raft_pending_perf_bench.py --check
#
# NOT gated here (explicit, not silent): the SHARDED throughput
# ceiling. Run it manually and compare to the recent peak (memory:
# `feedback_regression_baseline_current_peak`):
#       scripts/kv_shard_bench.sh
#
set -uo pipefail

cd "$(dirname "$0")/.."

CORRECTNESS=(
  raft_pending_parity_smoke.py
  chained_dispatch_smoke.py
  streaming_smoke.py
  streaming_resume_fault_inj_smoke.py
  heldsync_multiworker_smoke.py
  leader_failover_smoke.py
)

fail=0
declare -a results

run() {
  local label="$1"; shift
  echo "═══════════════════════════════════════════════════════════════"
  echo "▶ $label"
  echo "═══════════════════════════════════════════════════════════════"
  if "$@"; then
    results+=("PASS  $label")
  else
    results+=("FAIL  $label")
    fail=1
  fi
}

for smoke in "${CORRECTNESS[@]}"; do
  run "$smoke" python3 "scripts/$smoke"
done

# Perf gate (skip with SKIP_PERF=1 — e.g. on a non-ReleaseFast build).
if [[ "${SKIP_PERF:-0}" != "1" ]]; then
  run "raft_pending_perf_bench.py --check" \
      python3 scripts/raft_pending_perf_bench.py --check
else
  results+=("SKIP  raft_pending_perf_bench.py (SKIP_PERF=1)")
fi

echo
echo "═══════════════════════════════════════════════════════════════"
echo " Phase 3.2 gate summary"
echo "═══════════════════════════════════════════════════════════════"
for r in "${results[@]}"; do echo "  $r"; done
echo "  (sharded ceiling NOT gated here — run scripts/kv_shard_bench.sh)"
echo

if [[ "$fail" -ne 0 ]]; then
  echo "GATE FAILED"
  exit 1
fi
echo "GATE PASSED"
