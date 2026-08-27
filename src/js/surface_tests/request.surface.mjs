// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// request / response — the per-activation Zig-built surfaces, pinned
// against the harness's standard inbound request (see
// surface_tests.zig STD_HEADER_PAIRS/STD_BODY).
export default function () {
  check("request.method", () => eq(request.method, "POST"));
  check("request.path", () => eq(request.path, "/surface"));
  check("request.host", () => eq(request.host, "surface.test"));
  check("request.query", () => eq(request.query, "alpha=1&beta=two"));

  check("request.bytes", () => {
    ok(request.bytes instanceof Uint8Array);
    eq(new TextDecoder().decode(request.bytes), '{"n":42,"s":"str"}');
    // The prototype accessors derive from bytes (not separately
    // reflected — they live on the shared payload proto).
    eq(request.text, '{"n":42,"s":"str"}');
    eq(request.json.n, 42);
    eq(request.json.s, "str");
  });

  check("request.headers", () => {
    const h = request.headers;
    eq(h["content-type"], "application/json");
    eq(h["x-surface"], "yes");
    eq(h["user-agent"], "surface/1");
    eq(h[":method"], undefined);   // pseudo-headers filtered
    eq(h["cookie"], "sid=abc; theme=dark"); // cookie header IS visible raw
    throws(() => { h["x-surface"] = "no"; }); // accessors without setters
  });

  check("request.cookies", () => {
    eq(request.cookies, { sid: "abc", theme: "dark" });
  });

  // The activation object carries the three request-sourced effect
  // capabilities (#849) — data stays on `request`, effects arrive here.
  const A = arguments[0];

  // No edge proxy headers in the harness request → both IP surfaces null.
  check("request.ip", () => eq(request.ip, null));
  check("unmaskedIp()", () => {
    eq(A.unmaskedIp(), null);
    // Off `request` for good: a data shape carries no escalation.
    eq(request.unmaskedIp, undefined);
  });

  check("tag()", () => {
    eq(A.tag("k1", "v1"), undefined);
    eq(A.tag("k1", "v2"), undefined);  // same key updates in place
    throws(() => A.tag("k1"), /requires two string arguments/);
    throws(() => A.tag("_x", "v"), /reserved/);
    throws(() => A.tag("BadKey", "v"), /must match \[a-z0-9_\]/);
    throws(() => A.tag("k2", ""), /value length/);
    eq(request.tag, undefined);
  });

  check("shredKey()", () => {
    // Off `request` for good (#849): a data shape carries no capability
    // that replaces the activation's erasure identity.
    eq(request.shredKey, undefined);
    // Scopes the activation to an opaque identity. Returns undefined and
    // re-scopes on a second call — an activation has exactly one identity.
    eq(A.shredKey("u_7f3a9c"), undefined);
    eq(A.shredKey("u_0e11bd"), undefined);
    // The id's CONTENT is the tenant's business: the engine never learns
    // that an identity is a person, so anything printable is accepted.
    eq(A.shredKey("customer@example.com"), undefined);
    eq(A.shredKey("order:1234/line:7"), undefined);
    throws(() => A.shredKey(), /requires a string argument/);
    throws(() => A.shredKey(7), /requires a string argument/);
    // Empty is refused rather than read as "no identity" — a handler that
    // computed one from a missing cookie meant to scope and got nothing,
    // and falling back to the tenant key would silently downgrade
    // erasure from per-identity to per-tenant.
    throws(() => A.shredKey(""), /id length/);
    throws(() => A.shredKey("u_1\n"), /control characters/);
    throws(() => A.shredKey("x".repeat(129)), /id length/);
  });

  check("shredKey.destroy", () => {
    // Erasure hangs off the scoping function: one concept, two verbs.
    eq(typeof A.shredKey.destroy, "function");
    // An identity this tenant never named has nothing to erase — not an
    // error, so a delete-account flow run twice does not fail the second
    // time.
    eq(A.shredKey.destroy("never-named-identity"), undefined);
    // Same identity rules as scoping.
    throws(() => A.shredKey.destroy(), /requires a string argument/);
    throws(() => A.shredKey.destroy(""), /id length/);
    throws(() => A.shredKey.destroy("u\n"), /control characters/);
    // The per-activation cap is a RULE, and lives with the other rules in
    // `rove-guards` (`checkShredDestroyCap`) where it is unit-tested. It
    // counts engine state this harness does not carry, so asserting it
    // here would assert the harness, not the rule.
  });

  // No chain context in this dispatch → empty string (documented).
  check("request.sagaId", () => {
    eq(typeof request.sagaId, "string");
    eq(request.sagaId, "");
  });

  check("request.tenant", () => {
    eq(typeof request.tenant, "string");
  });

  // No session cookie resolved by the harness → null (the branch
  // customer code takes for callbacks / sim).
  check("request.session", () => eq(request.session, null));

  check("request.activation", () => {
    eq(request.activation, { kind: "inbound" });
  });

  check("response.status", () => {
    eq(response.status, 200); // initial
    response.status = 201;
    eq(response.status, 201);
    response.status = 200;
  });

  check("response.headers", () => {
    eq(response.headers, {}); // initial
    response.headers = { "x-surface-test": "1" };
    eq(response.headers["x-surface-test"], "1");
  });

  check("response.cookies", () => {
    eq(response.cookies, []); // initial
    response.cookies.push("sid=zzz; Path=/; HttpOnly");
    eq(response.cookies.length, 1);
  });

  return done();
}
