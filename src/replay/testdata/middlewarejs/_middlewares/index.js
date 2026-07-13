// The SAME gate as testdata/middleware, spelled `.js` — prod resolves
// `_middlewares/index.mjs` THEN `_middlewares/index.js` (dispatcher.zig), so
// the sim must run this spelling too (issue #51). Mutates request.auth or
// short-circuits 401.
export function before() {
  const tok = request.headers["authorization"] || "";
  if (tok === "Bearer good") { request.auth = { user: "jess", scopes: ["read"] }; return; }
  response.status = 401;
  return "denied";
}
