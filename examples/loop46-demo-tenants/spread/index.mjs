// Fair-comparison counterpart to hot. Each request picks one of 1000
// keys at random and writes the same 32-byte value. Bounded keyspace
// keeps the B-tree at a fixed size after a brief warmup.
export function handler() {
    const i = Math.floor(Math.random() * 1000);
    kv.set("k" + i, "0123456789abcdef0123456789abcdef");
    return "spread\n";
}
