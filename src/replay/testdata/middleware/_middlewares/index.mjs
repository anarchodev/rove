// A real middleware: gate on an Authorization header, set request.auth for the
// handler, or short-circuit with a 401. The sim runs this for real (it can make
// arbitrary changes to `request`), so tests exercise the actual gate — not a
// hand-reproduced stand-in.
export function before() {
  const tok = request.headers["authorization"] || "";
  if (tok === "Bearer good") { request.auth = { user: "jess", scopes: ["read"] }; return; }
  response.status = 401;
  return "denied";
}
