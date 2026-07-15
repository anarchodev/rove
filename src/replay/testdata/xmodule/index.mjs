// A handler that tries to point a BOUND fetch's `on` at a separate module
// file. Prod rejects that at issue time (`after.fetch`'s `{on}` selects a bare
// export on the SAME held chain — bindings/http.zig isValidExportName; the
// cross-module continuation surfaces are `webhook.send`'s `on` and the
// system-internal unbound fetch's `on_chunk`), so the sim recorder throws the
// same TypeError. The continuation module itself (hooks/onFetched.mjs) stays
// testable standalone via `scenario.fetchResult`.
export default function () {
  const key = new URLSearchParams(request.query || "").get("k") || "k";
  try {
    after.fetch("https://api.example.com/data", {
      method: "GET",
      ctx: { key: key },
      on: "hooks/onFetched.mjs",
    });
  } catch (e) {
    return { threw: e.message, type: e.constructor.name };
  }
  return next();
}
