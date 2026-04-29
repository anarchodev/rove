// Random-key write benchmark handler. Each request writes to a unique
// key (crypto.randomUUID), so there is zero row contention in SQLite.
export function handler() {
    const key = crypto.randomUUID();
    kv.set(key, "v");
    return "randwrite: " + key + "\n";
}
