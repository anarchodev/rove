// Intentionally runaway — used by scripts/penalty_smoke.sh to prove
// the interrupt handler + penalty-box pair actually protects the
// worker from a badly-behaved tenant.
export function handler() { while (true) {} }
