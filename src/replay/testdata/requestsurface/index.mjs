// Reads back the engine-pinned request surface (globals.zig installRequest):
// identity always set (session null / tenant / sagaId ""), the two ip
// channels, the activation bag, prod's tag validation (a capability on the
// activation object, #849 — beside unmaskedIp and shredKey, which are OFF
// `request`), and the ABSENCE of the retired driver-only surfaces
// (request.body, on.*, and now request.tag/.unmaskedIp/.shredKey).
export default function ({ tag, unmaskedIp }) {
  tag("route", "surface");
  const throws = (fn) => {
    try { fn(); return null; } catch (e) { return String(e.message || e); }
  };
  return JSON.stringify({
    session: request.session,
    tenant: request.tenant,
    corr: request.sagaId,
    ip: request.ip,
    unmasked: unmaskedIp(),
    // The three effects are capabilities, not request members (#849).
    offRequest: [request.tag, request.unmaskedIp, request.shredKey].every((m) => m === undefined),
    hasBody: "body" in request,
    onGlobal: typeof globalThis.on,
    activation: request.activation,
    tagValid: tag("attempt", "1") === undefined,
    tagBadChars: throws(() => tag("Bad-Key", "v")),
    tagReserved: throws(() => tag("_saga", "v")),
    tagNonString: throws(() => tag("k", 42)),
    tagLongKey: throws(() => tag("k".repeat(33), "v")),
    tagLongVal: throws(() => tag("k2", "v".repeat(65))),
    tagCtl: throws(() => tag("k3", "a\u0001b")),
    // route + attempt + t3 + t4 = the 4-key cap; re-tagging an existing key
    // updates in place (doesn't count); the 5th distinct key throws.
    tagCap: (() => {
      tag("t3", "x");
      tag("t4", "x");
      tag("route", "again");
      return throws(() => tag("t5", "x"));
    })(),
  });
}
