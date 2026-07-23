// @rewind/jwt — JWS / JWT decoding + verification helpers (P-Lift, rove#123).
//
// The lifted form of the former ambient `globalThis.jwt` (was
// `src/js/globals/jwt.js`): pure JS over the ambient `crypto.verifyRsa` /
// `crypto.verifyEcdsa` + `base64url.decode` primitives (which stay baked). The
// object's methods are now ES exports, and a default export of the same object
// keeps a consumer's `jwt.decode(…)` reading exactly as the ambient global did.
// This file is the first-party genesis-seed source (embedded at build time);
// a tenant may still resolve/pin a different published version via the
// registry (the embedded set is the default, not the only source).
//
// Algorithms: RS256/384/512 (RSA-PKCS#1 v1.5) and ES256/384/512 (ECDSA raw
// R||S per JWS). PS* (RSA-PSS) and HS* (HMAC) are intentionally excluded —
// HMAC tokens enable alg-confusion attacks.

/**
 * Split a JWT into its parts. Does NOT verify the signature.
 *
 * @param {string} token - Compact JWS (`header.payload.sig`).
 * @returns {{header:object, payload:object, signature_b64:string,
 *   signing_input:string}|null} `null` on malformed input.
 */
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
    return {
      header,
      payload,
      signature_b64: parts[2],
      signing_input: parts[0] + "." + parts[1],
    };
  } catch (_) {
    return null;
  }
}

/**
 * Verify a JWT signature. Does NOT validate claims — call
 * {@link validateClaims} on the returned `payload` next.
 *
 * @param {string} token - Compact JWS string.
 * @param {object|object[]} jwks_or_jwk - A bare JWK, a JWKS (`{keys:[…]}`),
 *   or a bare array of JWKs.
 * @returns {{valid:boolean, header:object, payload:object}}
 * @throws {TypeError} Malformed token / unsupported `alg`.
 * @throws {Error} No key in the JWKS matches the header.
 */
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
    default:
      throw new TypeError("jwt.verify: unsupported alg: " + header.alg);
  }
  return { valid, header, payload };
}

/**
 * Validate standard JWT claims. Call AFTER a successful {@link verify}.
 *
 * @param {object} payload - The verified token payload.
 * @param {object} [opts] - `{ iss?, aud?, now?, leewaySeconds? }`.
 * @returns {string|null} `null` if all pass, else the first failure:
 *   `"no-payload"` | `"expired"` | `"not-yet-valid"` | `"issuer-mismatch"` |
 *   `"audience-mismatch"`.
 */
export function validateClaims(payload, opts) {
  if (!payload || typeof payload !== "object") return "no-payload";
  opts = opts || {};
  const now_s = (opts.now || Date.now()) / 1000;
  if ("leeway_s" in opts) throw new TypeError("jwt: option `leeway_s` was renamed — use `leewaySeconds`");
  const leeway = opts.leewaySeconds != null ? opts.leewaySeconds : 30;
  if (typeof payload.exp === "number" && now_s - leeway >= payload.exp) {
    return "expired";
  }
  if (typeof payload.nbf === "number" && now_s + leeway < payload.nbf) {
    return "not-yet-valid";
  }
  if (opts.iss != null && payload.iss !== opts.iss) {
    return "issuer-mismatch";
  }
  if (opts.aud != null) {
    const aud = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (aud.indexOf(opts.aud) < 0) return "audience-mismatch";
  }
  return null;
}

function _selectJwk(jwks_or_jwk, header) {
  if (jwks_or_jwk && typeof jwks_or_jwk === "object" && jwks_or_jwk.kty) {
    return jwks_or_jwk;
  }
  let keys;
  if (Array.isArray(jwks_or_jwk)) keys = jwks_or_jwk;
  else if (jwks_or_jwk && Array.isArray(jwks_or_jwk.keys)) keys = jwks_or_jwk.keys;
  else return null;
  if (keys.length === 0) return null;
  if (header.kid) {
    const match = keys.find((k) => k.kid === header.kid);
    if (match) return match;
  }
  if (keys.length === 1) return keys[0];
  return null;
}

const jwt = { decode, verify, validateClaims };
export default jwt;
