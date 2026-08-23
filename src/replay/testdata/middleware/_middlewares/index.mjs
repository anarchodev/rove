// A real middleware: gate on an Authorization header, set request.auth for the
// handler, or short-circuit with a 401. The sim runs this for real (it can make
// arbitrary changes to `request`), so tests exercise the actual gate — not a
// hand-reproduced stand-in.
// It destructures a CAPABILITY on purpose. Middleware is a platform-invoked
// entry point, and a real one reaches `kv` to check a session — but both
// fixtures here used to be capability-free, so nothing noticed that
// `runMiddleware` called `before` with zero arguments. A tenant whose
// middleware destructured `kv` threw on every request, and the gate was
// green. Keep a capability in this signature.
export function before({ kv }) {
  const tok = request.headers["authorization"] || "";
  if (tok === "Bearer good") {
    // A real read, so the capability has to be the live one and not a stub.
    request.auth = { user: "jess", scopes: ["read"], seen: kv.get("mw/seen") };
    return;
  }
  response.status = 401;
  return "denied";
}
