// @rove/jwt — JWS / JWT decoding + verification helpers.
//
// Pure JS layered on `crypto.verifyRsa` / `crypto.verifyEcdsa` +
// `base64url.decode`. The full OIDC id_token verification recipe in
// ~3 lines:
//
//   const { valid, header, payload } = jwt.verify(token, jwks_set);
//   if (!valid) return reject;
//   const claim_err = jwt.validateClaims(payload, { iss, aud });
//
// Algorithms supported: RS256 / RS384 / RS512 (RSA-PKCS#1 v1.5) and
// ES256 / ES384 / ES512 (ECDSA P-256/P-384/P-521 with raw R||S sig
// per JWS). PS* (RSA-PSS) and HS* (HMAC) are intentionally not
// included; HMAC-shaped tokens are vulnerable to alg-confusion
// attacks and `crypto.verifyEcdsa` doesn't yet support PSS variants.

/**
 * JWS/JWT decode + verification, layered on
 * {@link crypto.verifyRsa}/{@link crypto.verifyEcdsa} +
 * {@link base64url}. Supports RS256/384/512 and ES256/384/512. PS\*
 * (RSA-PSS) and HS\* (HMAC) are intentionally excluded — HMAC tokens
 * enable alg-confusion attacks.
 *
 * @namespace jwt
 * @example
 * const { valid, payload } = jwt.verify(token, jwksSet);
 * if (!valid) return reject();
 * if (jwt.validateClaims(payload, { iss, aud })) return reject();
 */
globalThis.jwt = {
  /**
   * Split a JWT into its parts. Does NOT verify the signature.
   *
   * @param {string} token - Compact JWS (`header.payload.sig`).
   * @returns {{header:object, payload:object, signature_b64:string,
   *   signing_input:string}|null} `null` on malformed input (wrong
   *   dot count, bad base64url, non-JSON header/payload).
   * @example
   * const kid = jwt.decode(token)?.header.kid;
   */
  decode(token) {
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
  },

  /**
   * Verify a JWT signature. Does NOT validate claims — call
   * {@link jwt.validateClaims} on the returned `payload` next.
   *
   * Key selection: a bare JWK is used directly; from a JWKS the key
   * matching the header `kid` is chosen, or the sole key when there
   * is exactly one. Algorithm comes from the header `alg`.
   *
   * @param {object} token - Compact JWS string.
   * @param {object|object[]} jwks_or_jwk - A bare JWK, a JWKS
   *   (`{keys:[…]}`), or a bare array of JWKs.
   * @returns {{valid:boolean, header:object, payload:object}}
   *   `valid:false` means the signature did not match.
   * @throws {TypeError} Malformed token / unsupported `alg`.
   * @throws {Error} No key in the JWKS matches the header.
   * @example
   * const { valid, payload } = jwt.verify(idToken, jwks);
   */
  verify(token, jwks_or_jwk) {
    const decoded = jwt.decode(token);
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
  },

  /**
   * Validate standard JWT claims. Call AFTER a successful
   * {@link jwt.verify}.
   *
   * @param {object} payload - The verified token payload.
   * @param {object} [opts]
   * @param {string} [opts.iss] - Expected issuer.
   * @param {string} [opts.aud] - Expected audience; passes if it
   *   appears in `payload.aud` (string or array).
   * @param {number} [opts.now] - Now, ms since epoch (default
   *   `Date.now()`).
   * @param {number} [opts.leeway_s=30] - Clock-skew tolerance for
   *   `exp`/`nbf`.
   * @returns {string|null} `null` if all checks pass, else the first
   *   failure: `"no-payload"` | `"expired"` | `"not-yet-valid"` |
   *   `"issuer-mismatch"` | `"audience-mismatch"`.
   * @example
   * const err = jwt.validateClaims(payload, { iss, aud: clientId });
   * if (err) return new Response(err, { status: 401 });
   */
  validateClaims(payload, opts) {
    if (!payload || typeof payload !== "object") return "no-payload";
    opts = opts || {};
    const now_s = (opts.now || Date.now()) / 1000;
    const leeway = opts.leeway_s != null ? opts.leeway_s : 30;
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
  },
};

function _selectJwk(jwks_or_jwk, header) {
  // Bare JWK: a single object with kty + the key params. Use it
  // directly even if kid doesn't match (single-key trust).
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
  // No kid hint OR no match by kid: if exactly one key is in the
  // set, accept it. Multiple keys + no match = ambiguous; reject.
  if (keys.length === 1) return keys[0];
  return null;
}
