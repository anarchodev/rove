// __auth__ — the OIDC identity provider (auth-domain-plan.md §4.7).
//
// A normal tenant (no `platform.*`), reached at `auth.{system_suffix}`.
// It runs the dogfooded `oidc.provider()` library for the OIDC routes
// and a magic-link login for the authentication step ("magic-link
// stays the authN primitive, OIDC wraps it" — §4.1). On successful
// login it binds the platform's per-request sid to a user at
// `_oidc/session/{sid}` — exactly the seam oidc.js._authorize reads.
//
// §0: every URL is derived from request.host — no compiled-in domain.

const MAGIC_TTL_MS = 15 * 60 * 1000; // 15 min, single-use
const MAGIC_PREFIX = "_oidc/magic/";
const SESSION_PREFIX = "_oidc/session/"; // must match oidc cfg.session_path

function iss() {
  return "https://" + request.host;
}

function rand() {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  return base64url.encode(b);
}

// return_to MUST be an absolute URL on THIS issuer (open-redirect
// defense — the login is otherwise a redirector an attacker could aim
// anywhere). In practice it's the /authorize URL oidc.js bounced here.
function safeReturnTo(rt) {
  const base = iss() + "/";
  if (typeof rt === "string" && (rt === iss() || rt.indexOf(base) === 0)) {
    return rt;
  }
  return iss() + "/"; // fall back to the issuer root
}

function loginForm(return_to, msg) {
  response.status = 200;
  response.headers = { "content-type": "text/html; charset=utf-8" };
  const rt = String(return_to || "").replace(/"/g, "&quot;");
  return "<!doctype html><meta charset=utf-8><title>Sign in</title>" +
    "<h1>Sign in</h1>" +
    (msg ? "<p>" + msg + "</p>" : "") +
    '<form method=post action="/login">' +
    '<input type=hidden name=return_to value="' + rt + '">' +
    '<input name=email type=email placeholder="you@example.com" required>' +
    "<button>Email me a sign-in link</button></form>";
}

// POST /login {email, return_to} → mint a single-use magic token,
// email it (or, with no Resend key configured, return it in the JSON
// so a dev/test relying party can follow it — same dev seam admin's
// signup uses).
function startLogin() {
  const f = new URLSearchParams(request.body || "");
  // NB: name this `addr`, NOT `email` — a local `email` would shadow the
  // global `email` API object, turning `email.send(...)` below into
  // `String.prototype.send` (undefined) → "TypeError: not a function".
  const addr = (f.get("email") || "").trim().toLowerCase();
  const return_to = safeReturnTo(f.get("return_to"));
  if (!addr || addr.indexOf("@") < 1) {
    return loginForm(return_to, "Enter a valid email.");
  }

  const opaque = rand();
  // sha256-at-rest: a leaked kv can't replay live magic tokens.
  kv.set(MAGIC_PREFIX + crypto.sha256(opaque), JSON.stringify({
    email: addr,
    return_to,
    exp: Date.now() + MAGIC_TTL_MS,
  }));
  const link = iss() + "/login/verify?mt=" + opaque;

  const resendKey = kv.get("resend_key");
  if (resendKey) {
    email.send({
      key: resendKey,
      from: kv.get("platform_email_from") || "login@" + request.host,
      to: addr,
      subject: "Your sign-in link",
      text: "Sign in: " + link + "\n\nThis link expires in 15 minutes.",
    });
    response.status = 200;
    response.headers = { "content-type": "text/html; charset=utf-8" };
    return "<!doctype html><meta charset=utf-8><title>Check your email</title>" +
      "<p>Check your email for a sign-in link.</p>";
  }
  // No email configured (dev/test): hand the link back directly.
  response.status = 200;
  response.headers = { "content-type": "application/json" };
  return JSON.stringify({ ok: true, magic_link: link });
}

// GET /login/verify?mt=… → consume the token (single-use), bind the
// per-request sid to the user, bounce back to the original authorize
// URL where oidc.js now finds the session and issues the code.
function verifyLogin() {
  const q = new URLSearchParams(request.query || "");
  const mt = q.get("mt");
  if (!mt) {
    response.status = 400;
    return "missing token";
  }
  const key = MAGIC_PREFIX + crypto.sha256(mt);
  const raw = kv.get(key);
  kv.delete(key); // single-use: consume before any check
  if (raw == null) {
    response.status = 400;
    return "invalid or used sign-in link";
  }
  const m = JSON.parse(raw);
  if (Date.now() > m.exp) {
    response.status = 400;
    return "sign-in link expired";
  }

  const sid = request.session && request.session.id;
  if (!sid) {
    response.status = 400;
    return "no session context";
  }
  // Bind sid → user. `sub` is the stable subject identifier; the
  // email is fine for v1 (one IdP, opaque to RPs via id_token.sub).
  kv.set(SESSION_PREFIX + sid, JSON.stringify({
    sub: m.email,
    auth_time: Math.floor(Date.now() / 1000),
  }));

  response.status = 302;
  response.headers = { location: safeReturnTo(m.return_to) };
  return null;
}

export default function () {
  const path = (request.path || "").split("?")[0];
  const m = request.method;

  if (m === "GET" && path === "/login") {
    const q = new URLSearchParams(request.query || "");
    return loginForm(q.get("return_to"));
  }
  if (m === "POST" && path === "/login") return startLogin();
  if (m === "GET" && path === "/login/verify") return verifyLogin();

  // Everything else (/.well-known/*, /authorize, /token) → the
  // dogfooded provider library.
  return oidc.provider("default").handle();
}
