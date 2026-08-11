// Reads back the engine-pinned request surface (globals.zig installRequest):
// identity always set (session null / tenant / sagaId ""), the two ip
// channels, the activation bag, prod's request.tag validation, and the
// ABSENCE of the retired driver-only surfaces (request.body, on.*).
export default function () {
  request.tag("route", "surface");
  const throws = (fn) => {
    try { fn(); return null; } catch (e) { return String(e.message || e); }
  };
  return JSON.stringify({
    session: request.session,
    tenant: request.tenant,
    corr: request.sagaId,
    ip: request.ip,
    unmasked: request.unmaskedIp(),
    hasBody: "body" in request,
    onGlobal: typeof globalThis.on,
    activation: request.activation,
    tagValid: request.tag("attempt", "1") === undefined,
    tagBadChars: throws(() => request.tag("Bad-Key", "v")),
    tagReserved: throws(() => request.tag("_saga", "v")),
    tagNonString: throws(() => request.tag("k", 42)),
    tagLongKey: throws(() => request.tag("k".repeat(33), "v")),
    tagLongVal: throws(() => request.tag("k2", "v".repeat(65))),
    tagCtl: throws(() => request.tag("k3", "a\u0001b")),
    // route + attempt + t3 + t4 = the 4-key cap; re-tagging an existing key
    // updates in place (doesn't count); the 5th distinct key throws.
    tagCap: (() => {
      request.tag("t3", "x");
      request.tag("t4", "x");
      request.tag("route", "again");
      return throws(() => request.tag("t5", "x"));
    })(),
  });
}
