// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// surface test: platform — the customer-facing contract of the admin
// surface is the natively-enforced gate: every method reached from a
// normal tenant activation (request.admin all-null) throws. The admin
// happy paths are cluster-level (platform_* smokes).

const NOT_ADMIN = /platform is only available on the admin handler/;

export default function ({ platform }) {
  check("platform.scope", () => {
    throws(() => platform.scope("some-tenant"), NOT_ADMIN);
  });

  check("platform.root.get", () => {
    throws(() => platform.root.get("instance/x"), NOT_ADMIN);
  });
  check("platform.root.set", () => {
    throws(() => platform.root.set("instance/x", "{}"), NOT_ADMIN);
  });
  check("platform.root.delete", () => {
    throws(() => platform.root.delete("instance/x"), NOT_ADMIN);
  });
  check("platform.root.prefix", () => {
    throws(() => platform.root.prefix("instance/", null, 10), NOT_ADMIN);
  });

  check("platform.instances.create", () => {
    throws(() => platform.instances.create("acme"), NOT_ADMIN);
  });
  check("platform.instances.deployStarter", () => {
    throws(() => platform.instances.deployStarter("acme"), NOT_ADMIN);
  });

  check("platform.dispatch", () => {
    // The gate here is worth stating, because this verb is composed rather
    // than native: `dispatch` writes a `_dispatch/owed/` marker and arms a
    // scheduler wake, so without an admin check a customer tenant could arm
    // wakes for a dispatch the router would refuse anyway. It gates by
    // RESOLVING the target through `platform.scope`, which is natively
    // enforced — so the refusal a customer sees is the same one every other
    // `platform.*` verb gives, from the same place.
    throws(() => platform.dispatch("acme", "__system/release", { ctx: { a: 1 } }), NOT_ADMIN);
    // Argument validation runs BEFORE the gate, so a malformed call is a
    // TypeError rather than a confusing admin refusal — and a customer
    // probing this surface learns nothing about which tenants exist.
    throws(() => platform.dispatch("", "__system/release"), /tenant must be a non-empty string/);
    throws(() => platform.dispatch("acme", "handlers/mine.mjs"), /must be a baked/);
    throws(() => platform.dispatch("acme", "__system/release", { actor: "root" }), /actor must be one of/);
  });

  check("platform.releases.publish", () => {
    throws(() => platform.releases.publish("acme", "0123456789abcdef"), NOT_ADMIN);
  });

  // No `platform.auth` check: the verb is gone. The operator-root verdict is
  // `request.rewind.isRoot`, installed only on a platform-bound handler, so a
  // customer tenant has no surface to probe. If a bearer-taking verb ever comes
  // back, direction 1 of the inventory gate ("public name with no covering
  // test") fails loudly — which is the guard that matters here.

  check("platform.stage", () => {
    // Like compile, staging lowers to a bound fetch at a trusted door and is
    // admin-checked door-side, so the emission itself succeeds here.
    const id = platform.stage([{ path: "index.mjs", source: "export default ()=>1" }],
                              { scope: "acme" });
    ok(typeof id === "string" && id.startsWith("ftch_"), "bound fetch id: " + id);
  });

  check("platform.compile", () => {
    // Unlike the sys.platform natives, compile lowers to a bound
    // after.fetch at the trusted compile door — the call itself is
    // NOT gated; the admin check happens door-side when the fetch
    // fires. From a customer activation the emission succeeds and
    // returns the bound fetch id.
    const id = platform.compile(
      [{ path: "index.mjs", source: "export default ()=>1" }],
      { scope: "acme" });
    ok(typeof id === "string" && id.startsWith("ftch_"), "bound fetch id: " + id);
  });

  return done();
}
