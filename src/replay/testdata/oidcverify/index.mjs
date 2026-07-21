// OIDC RS256 verification offline: crypto.verifyRsa (native SHA-256 + pure-JS
// RSA in the sim base) + jwt.verify over a real IdP JWK. This is what an auth
// middleware does — now testable without the IdP.
export default function () {
  const { token, jwk } = request.json;
  const p = token.split(".");
  const rawOk = crypto.verifyRsa(jwk, "sha256", p[0] + "." + p[1], base64url.decode(p[2]));
  const tampered = crypto.verifyRsa(jwk, "sha256", "x" + p[0] + "." + p[1], base64url.decode(p[2]));
  const r = jwt.verify(token, { keys: [jwk] });
  response.status = 200;
  return { rawOk, tampered, valid: r.valid, sub: r.payload.sub, iss: r.payload.iss };
}

// #45: an unsupported alg/curve must THROW a loud declared-gap error offline —
// never a silent valid:false (which would green a login-rejection prod accepts).
export function gaps() {
  const rsaJwk = { kty: "RSA", n: "AQAB", e: "AQAB" };
  const ecJwk = { kty: "EC", crv: "P-384", x: "AA", y: "AA" };
  const probe = (fn) => { try { fn(); return "no-throw"; } catch (e) { return String(e.message); } };
  return {
    rs512: probe(() => crypto.verifyRsa(rsaJwk, "sha512", "data", new Uint8Array(0))),
    es384: probe(() => crypto.verifyEcdsa(ecJwk, "sha384", "data", new Uint8Array(0))),
    p521:  probe(() => crypto.verifyEcdsa({ kty: "EC", crv: "P-521" }, "sha256", "data", new Uint8Array(0))),
  };
}
