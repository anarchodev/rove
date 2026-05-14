// replay_demo: a handler engineered to exercise the captured tape
// channels the WASM replay path consumes — kv (get + set), date
// (Date.now), math_random (Math.random), crypto_random
// (crypto.getRandomValues) — and to produce a non-trivial call tree
// so the SCAN-mode trace stream has structure for the timeline /
// stack walker to chew on. Module-level `let` lives in closure
// storage; `?fn=throw` exercises THROW capture.
//
// One file by design: the offline seed compiles each .mjs in
// isolation, so cross-module imports don't survive `loop46 seed`.
// Multi-file imports work end-to-end through files-server's
// POST /<tenant>/deployments route (see scripts/replay_smoke.py),
// which is a separate smoke.

let totalCalls = 0;
let totalRolls = 0;

function fmtSalt(buf) {
    let out = "";
    for (const b of buf) out += b.toString(16).padStart(2, "0");
    return out;
}

function bumpCount(prior) {
    totalCalls++;
    return prior + 1;
}

function rollDie() {
    totalRolls++;
    return 1 + Math.floor(Math.random() * 6);
}

export function handler() {
    if (request && request.path && request.path.includes("/throw")) {
        throw new Error("intentional replay-demo throw at " + Date.now());
    }

    const buf = new Uint8Array(4);
    crypto.getRandomValues(buf);
    const salt = fmtSalt(buf);

    const at = Date.now();
    const die = rollDie();
    const r = Math.random();

    const prior = parseInt(kv.get("count") ?? "0", 10);
    const next = bumpCount(prior);
    kv.set("count", String(next));

    return (
        "count=" + next +
        " die=" + die +
        " r=" + r.toFixed(4) +
        " at=" + at +
        " salt=" + salt +
        " totalCalls=" + totalCalls +
        " totalRolls=" + totalRolls + "\n"
    );
}
