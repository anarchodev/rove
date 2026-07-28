import jwt from "@rewind/jwt";
// OIDC ES256 verification offline: crypto.verifyEcdsa (native SHA-256 + pure-JS
// P-256 ECDSA in the sim base) + jwt.verify over a real EC IdP JWK. Same shape
// as the RS256 fixture, exercising the elliptic-curve path an ES256 IdP uses.
export default function () {
  const { token, jwk } = request.json;
  const p = token.split(".");
  const rawOk = crypto.verifyEcdsa(jwk, "sha256", p[0] + "." + p[1], base64url.decode(p[2]));
  const tampered = crypto.verifyEcdsa(jwk, "sha256", "x" + p[0] + "." + p[1], base64url.decode(p[2]));
  const r = jwt.verify(token, { keys: [jwk] });
  response.status = 200;
  return { rawOk, tampered, valid: r.valid, sub: r.payload.sub, iss: r.payload.iss };
}
