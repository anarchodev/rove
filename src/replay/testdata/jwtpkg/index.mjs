// A consumer of the lifted `@rewind/jwt` package (P-Lift, rove#123) — the
// shape `admin/_middlewares` takes after jwt stops being an ambient global.
// Imports jwt as a package (default export, so `jwt.decode(...)` reads exactly
// as the ambient global did), builds a token with the ambient `base64url`,
// then decodes + validates claims — proving the lifted ES module resolves,
// its exports work, and its ambient `base64url` reference still resolves
// inside a package.
import jwt from "@rewind/jwt";

const enc = (obj) => base64url.encode(JSON.stringify(obj));

export default function () {
  const header = { alg: "RS256", typ: "JWT", kid: "k1" };
  const payload = { sub: "user1", iss: "https://issuer.test", aud: "client-x", exp: 4102444800 };
  const token = enc(header) + "." + enc(payload) + ".SIGNATURE";

  const decoded = jwt.decode(token);
  const goodClaims = jwt.validateClaims(decoded.payload, {
    iss: "https://issuer.test", aud: "client-x", now: 1700000000000,
  });
  const badIss = jwt.validateClaims(decoded.payload, { iss: "https://evil.test" });

  return {
    alg: decoded.header.alg,
    kid: decoded.header.kid,
    sub: decoded.payload.sub,
    goodClaims,               // null when all claims pass
    badIss,                   // "issuer-mismatch"
    malformed: jwt.decode("nope"),          // null (not 3 parts)
    hasVerify: typeof jwt.verify === "function",
  };
}
