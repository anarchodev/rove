// P-Lift (rove#123) — the FIRST lifted lib: `@rewind/jwt`.
//
// `JWT_PKG` below is `src/js/globals/jwt.js` LIFTED from an ambient global to
// an ES-module package: `globalThis.jwt = { … }` → `export function …` (plus a
// default export of the same object, so a consumer's `jwt.decode(…)` reads
// exactly as the ambient global did); the internal `jwt.decode` call in
// `verify` becomes the local `decode`; the module-scoped `_selectJwk` helper
// and the ambient `base64url`/`crypto` references are unchanged (packages may
// use ambient primitives). This proves the lift resolves + runs offline
// through the same PackageResolver prod uses at deploy — before jwt is removed
// from the engine's embed list (a strictly later piece). The canonical source
// moves to rewind-apps `packages/jwt/` when the registry publish/genesis-seed
// path lands.
import { scenario, expect } from "rewind:test";

const JWT_PKG = `
function _selectJwk(jwks_or_jwk, header) {
  if (jwks_or_jwk && typeof jwks_or_jwk === "object" && jwks_or_jwk.kty) return jwks_or_jwk;
  let keys;
  if (Array.isArray(jwks_or_jwk)) keys = jwks_or_jwk;
  else if (jwks_or_jwk && Array.isArray(jwks_or_jwk.keys)) keys = jwks_or_jwk.keys;
  else return null;
  if (keys.length === 0) return null;
  if (header.kid) { const m = keys.find((k) => k.kid === header.kid); if (m) return m; }
  if (keys.length === 1) return keys[0];
  return null;
}
export function decode(token) {
  if (typeof token !== "string") return null;
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const header_bytes = base64url.decode(parts[0]);
    const payload_bytes = base64url.decode(parts[1]);
    const dec = new TextDecoder();
    const header = JSON.parse(dec.decode(header_bytes));
    const payload = JSON.parse(dec.decode(payload_bytes));
    if (!header || typeof header !== "object") return null;
    return { header, payload, signature_b64: parts[2], signing_input: parts[0] + "." + parts[1] };
  } catch (_) { return null; }
}
export function verify(token, jwks_or_jwk) {
  const decoded = decode(token);
  if (!decoded) throw new TypeError("jwt.verify: malformed token");
  const { header, payload, signature_b64, signing_input } = decoded;
  const jwk = _selectJwk(jwks_or_jwk, header);
  if (!jwk) throw new Error("jwt.verify: no key in JWKS matches token header");
  const data = new TextEncoder().encode(signing_input);
  const sig = base64url.decode(signature_b64);
  let valid;
  switch (header.alg) {
    case "RS256": valid = crypto.verifyRsa(jwk, "sha256", data, sig); break;
    case "RS384": valid = crypto.verifyRsa(jwk, "sha384", data, sig); break;
    case "RS512": valid = crypto.verifyRsa(jwk, "sha512", data, sig); break;
    case "ES256": valid = crypto.verifyEcdsa(jwk, "sha256", data, sig); break;
    case "ES384": valid = crypto.verifyEcdsa(jwk, "sha384", data, sig); break;
    case "ES512": valid = crypto.verifyEcdsa(jwk, "sha512", data, sig); break;
    default: throw new TypeError("jwt.verify: unsupported alg: " + header.alg);
  }
  return { valid, header, payload };
}
export function validateClaims(payload, opts) {
  if (!payload || typeof payload !== "object") return "no-payload";
  opts = opts || {};
  const now_s = (opts.now || Date.now()) / 1000;
  if ("leeway_s" in opts) throw new TypeError("jwt: option \`leeway_s\` was renamed — use \`leewaySeconds\`");
  const leeway = opts.leewaySeconds != null ? opts.leewaySeconds : 30;
  if (typeof payload.exp === "number" && now_s - leeway >= payload.exp) return "expired";
  if (typeof payload.nbf === "number" && now_s + leeway < payload.nbf) return "not-yet-valid";
  if (opts.iss != null && payload.iss !== opts.iss) return "issuer-mismatch";
  if (opts.aud != null) {
    const aud = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (aud.indexOf(opts.aud) < 0) return "audience-mismatch";
  }
  return null;
}
const jwt = { decode, verify, validateClaims };
export default jwt;
`;

const HASH = "1a".repeat(32);
const r = scenario({
  packages: [{ spec: "@rewind/jwt", version: "1.0.0", pkg_hash: HASH, files: { "index.mjs": JWT_PKG } }],
  app_imports: { "@rewind/jwt": HASH },
}).inbound({ method: "GET", path: "/" });

expect(r.status).toBe(200);
// decode round-tripped a real token through the package's ambient base64url.
expect(r.body.alg).toBe("RS256");
expect(r.body.kid).toBe("k1");
expect(r.body.sub).toBe("user1");
// validateClaims (a pure export) works: passing claims → null; wrong issuer → the code.
expect(r.body.goodClaims).toBe(null);
expect(r.body.badIss).toBe("issuer-mismatch");
// decode rejects a malformed token; verify is exported.
expect(r.body.malformed).toBe(null);
expect(r.body.hasVerify).toBe(true);
