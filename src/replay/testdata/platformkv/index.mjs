// platform.* per-store kv isolation. An admin-style handler touches four
// distinct stores — its own tenant kv, two instances (via platform.scope), and
// the platform root — writing the SAME key "shared" to each. In the sim these
// are isolated (namespaced under __rove_store/{tag}/), so no write bleeds across
// stores, and seeded values read back through the right facade.
export default function ({ kv, platform }) {
  kv.set("shared", "own");

  const acme = platform.scope("acme");
  const acmeSeed = acme.kv.get("profile"); // seeded in acme's store
  acme.kv.set("profile", "acme-new");
  acme.kv.set("shared", "acme");

  platform.scope("beta").kv.set("shared", "beta");

  const rootSeed = platform.root.get("cfg"); // seeded in the root store
  platform.root.set("cfg", "root-new");
  platform.root.set("shared", "root");

  return {
    ownShared: kv.get("shared"),       // "own" — untouched by scoped/root "shared"
    ownSeed: kv.get("seed-own"),        // seeded in tenant kv
    acmeSeed,                           // read back the acme seed
    acmeShared: acme.kv.get("shared"),  // read-your-write inside acme's store → "acme"
    rootSeed,                           // read back the root seed
  };
}
