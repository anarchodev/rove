// Mixed read/write benchmark handler. ~90% reads, ~10% writes —
// matches the typical SaaS access pattern more closely than the
// pure-write `write/index.mjs`. Reads of the missing key (until
// the first write lands) return null, which still exercises the
// read path. Math.random is captured by the replay tape, so this
// handler is deterministic on replay despite the coin flip.
export function handler() {
    if (Math.random() < 0.1) {
        kv.set("k", "0123456789abcdef0123456789abcdef");
    } else {
        kv.get("k");
    }
    return "rwbench\n";
}
