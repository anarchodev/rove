// OIDC PROVIDER mode offline (#46): mint an id_token with a generated key and
// verify it against the published JWK — the keyset → mint → verify round-trip an
// OIDC provider (or ActivityPub actor signer) runs, now testable without a live
// crypto backend.
export default function () {
  const k = crypto.oidcGenerateKey(); // { priv, jwk, kid }
  const header = base64url.encode(JSON.stringify({ alg: "RS256", typ: "JWT", kid: k.kid }));
  const payload = base64url.encode(JSON.stringify({ sub: request.json.sub, iss: "https://sim.test" }));
  const signingInput = header + "." + payload;
  const token = signingInput + "." + crypto.oidcSign(k.priv, signingInput);
  // Verify with the published JWK (what a relying party does).
  const r = jwt.verify(token, { keys: [k.jwk] });
  // A tampered token must fail.
  const bad = jwt.verify(token.slice(0, -4) + "AAAA", { keys: [k.jwk] });
  return { kid: k.kid, kty: k.jwk.kty, valid: r.valid, sub: r.valid ? r.payload.sub : null, badValid: bad.valid };
}
