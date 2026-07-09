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
