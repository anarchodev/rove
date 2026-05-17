// Shim-overhead benchmark — DIRECT arm.
//
// Read-only tight loop calling the native kv.get binding directly.
// Pair with kvshim (byte-identical workload routed through a one-JS-
// frame wrapper that forwards to the native binding) to measure the
// per-op cost of the proposed `globals/kv.js -> _system.kv.*` model.
//
// Read-only on purpose: reads skip raft + WAL fsync, so the JS call
// frame is the largest possible fraction of per-op cost. This is the
// worst case for the shim and the number that decides the design.
export function handler() {
    let acc = 0;
    for (let i = 0; i < 200; i++) acc += (kv.get("seed") || "").length;
    return "direct " + acc + "\n";
}
