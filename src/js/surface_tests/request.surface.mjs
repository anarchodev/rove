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

  // No edge proxy headers in the harness request → both IP surfaces null.
  check("request.ip", () => eq(request.ip, null));
  check("request.unmaskedIp", () => eq(request.unmaskedIp(), null));

  check("request.tag", () => {
    eq(request.tag("k1", "v1"), undefined);
    eq(request.tag("k1", "v2"), undefined);  // same key updates in place
    throws(() => request.tag("k1"), /requires two string arguments/);
    throws(() => request.tag("_x", "v"), /reserved/);
    throws(() => request.tag("BadKey", "v"), /must match \[a-z0-9_\]/);
    throws(() => request.tag("k2", ""), /value length/);
  });

  // No chain context in this dispatch → empty string (documented).
  check("request.correlation_id", () => {
    eq(typeof request.correlation_id, "string");
    eq(request.correlation_id, "");
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
