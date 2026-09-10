// platform.* per-store kv isolation. An admin-style handler touches three
// distinct stores — its own tenant kv and two instances (via platform.scope)
// — writing the SAME key "shared" to each. In the sim these
// are isolated (namespaced under __rove_store/{tag}/), so no write bleeds across
// stores, and seeded values read back through the right facade.
export default function ({ kv, platform }) {
  kv.set("shared", "own");

  const acme = platform.scope("acme");
  const acmeSeed = acme.kv.get("profile"); // seeded in acme's store
  acme.kv.set("profile", "acme-new");
  acme.kv.set("shared", "acme");

  platform.scope("beta").kv.set("shared", "beta");

  // The platform root store is not reachable from a handler at all now
  // (rove#852) — both its reads and its writes are dispatched activations in
  // `__root__`'s own scope. The isolation matrix below is the writable
  // facades, which is what this fixture is about.

  return {
    ownShared: kv.get("shared"),       // "own" — untouched by scoped/root "shared"
    ownSeed: kv.get("seed-own"),        // seeded in tenant kv
    acmeSeed,                           // read back the acme seed
    acmeShared: acme.kv.get("shared"),  // read-your-write inside acme's store → "acme"
  };
}
