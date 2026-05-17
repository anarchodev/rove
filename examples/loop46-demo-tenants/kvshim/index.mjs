// Shim-overhead benchmark — SHIM arm.
//
// Byte-identical workload to kvdirect, but every kv read goes through
// the exact indirection the proposed model adds: a thin per-namespace
// JS object (stand-in for globals/kv.js) forwarding to a `_system`
// namespace object (stand-in for the native bindings moved under
// _system). One extra JS frame + one extra property access per op.
const _system = { kv };           // stand-in: native bindings under _system.*
const $kv = {                     // stand-in: globals/kv.js public shim
    get: (k) => _system.kv.get(k),
    set: (k, v) => _system.kv.set(k, v),
};

export function handler() {
    let acc = 0;
    for (let i = 0; i < 200; i++) acc += ($kv.get("seed") || "").length;
    return "shim " + acc + "\n";
}
