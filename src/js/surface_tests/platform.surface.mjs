// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// surface test: platform — the customer-facing contract of the admin
// surface is the natively-enforced gate: every method reached from a
// normal tenant activation (request.admin all-null) throws. The admin
// happy paths are cluster-level (platform_* smokes).

const NOT_ADMIN = /platform is only available on the admin handler/;

export default function () {
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

  check("platform.releases.publish", () => {
    throws(() => platform.releases.publish("acme", "0123456789abcdef"), NOT_ADMIN);
  });

  check("platform.auth.checkRootToken", () => {
    throws(() => platform.auth.checkRootToken("tok"), NOT_ADMIN);
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
