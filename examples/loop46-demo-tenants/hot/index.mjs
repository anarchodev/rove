// Fixed-payload, fixed-key contention benchmark. Writes a 32-byte
// value to a single hot key. Pair with spread (same payload, 1000-key
// keyspace) to isolate row-contention cost from B-tree growth.
export function handler() {
    kv.set("k", "0123456789abcdef0123456789abcdef");
    return "hot\n";
}
