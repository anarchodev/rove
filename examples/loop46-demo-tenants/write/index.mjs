// Write benchmark handler. Used by the `write0..write7` tenants to
// measure how the writer-lock ceiling on a single app.db scales when
// the same workload is sharded across independent tenants. Matches
// hot's body exactly so cross-tenant sharded runs are directly
// comparable to single-tenant `hot.test` runs.
export function handler() {
    kv.set("k", "0123456789abcdef0123456789abcdef");
    return "wbench\n";
}
