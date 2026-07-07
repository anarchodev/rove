// surface test: jwt — decode/verify/validateClaims against a REAL
// RS256 token minted in-process (crypto.oidcGenerateKey + oidcSign),
// not a fixture string.

function b64uJson(obj) {
  return base64url.encode(new TextEncoder().encode(JSON.stringify(obj)));
}

export default function () {
  const { priv, jwk, kid } = crypto.oidcGenerateKey();
  const now_s = Math.floor(Date.now() / 1000);
  const payload = {
    iss: "https://idp.example", aud: "cid", sub: "u1",
    exp: now_s + 3600, nbf: now_s - 10,
  };
  const signing_input =
    b64uJson({ alg: "RS256", typ: "JWT", kid }) + "." + b64uJson(payload);
  const token = signing_input + "." + crypto.oidcSign(priv, signing_input);

  check("jwt.decode", () => {
    const d = jwt.decode(token);
    eq(d.header.alg, "RS256");
    eq(d.header.kid, kid);
    eq(d.payload.sub, "u1");
    eq(d.signing_input, signing_input);
    // Malformed inputs are null, never a throw.
    eq(jwt.decode("a.b"), null);
    eq(jwt.decode("not.base64url.!!!"), null);
    eq(jwt.decode(42), null);
  });

  check("jwt.verify", () => {
    // Bare JWK, JWKS set, and bare array all select the key.
    eq(jwt.verify(token, jwk).valid, true);
    eq(jwt.verify(token, { keys: [jwk] }).valid, true);
    eq(jwt.verify(token, [jwk]).valid, true);
    ok(jwt.verify(token, jwk).payload.iss === "https://idp.example");
    // Wrong key → valid:false (not a throw).
    const other = crypto.oidcGenerateKey().jwk;
    eq(jwt.verify(token, other).valid, false);
    // kid-mismatch in a multi-key set is ambiguous → throws.
    throws(() => jwt.verify(token, { keys: [other, crypto.oidcGenerateKey().jwk] }),
      /no key in JWKS matches/);
    throws(() => jwt.verify("nope", jwk), /malformed token/);
    // alg-confusion refusal: HS256 is unsupported by design.
    const hs_input = b64uJson({ alg: "HS256" }) + "." + b64uJson({});
    throws(() => jwt.verify(hs_input + ".AAAA", jwk), /unsupported alg: HS256/);
  });

  check("jwt.validateClaims", () => {
    eq(jwt.validateClaims(payload, { iss: "https://idp.example", aud: "cid" }), null);
    eq(jwt.validateClaims(null), "no-payload");
    eq(jwt.validateClaims(payload, { iss: "https://other.example" }), "issuer-mismatch");
    eq(jwt.validateClaims(payload, { aud: "not-cid" }), "audience-mismatch");
    // aud array membership passes.
    eq(jwt.validateClaims({ aud: ["a", "cid"] }, { aud: "cid" }), null);
    // exp with leeway: expired 31s ago fails the default 30s leeway,
    // passes a 60s one.
    const stale = { exp: now_s - 31 };
    eq(jwt.validateClaims(stale, { now: now_s * 1000 }), "expired");
    eq(jwt.validateClaims(stale, { now: now_s * 1000, leewaySeconds: 60 }), null);
    eq(jwt.validateClaims({ nbf: now_s + 3600 }, { now: now_s * 1000 }), "not-yet-valid");
    // The renamed option fails loud.
    throws(() => jwt.validateClaims(payload, { leeway_s: 5 }), /renamed.*leewaySeconds/);
  });

  return done();
}
