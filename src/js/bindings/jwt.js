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

globalThis.jwt = {
  /// Split a JWT into header + payload + raw signature (base64url
  /// string). Does NOT verify. Returns null on malformed input
  /// (wrong number of dots, invalid base64url, non-JSON header /
  /// payload). Use `jwt.verify` for the verifying path.
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

  /// Verify a JWT signature against a single JWK or a JWKS document
  /// (`{keys: [...]}` or a bare array of keys).
  ///
  ///   - When given a JWKS, picks the key whose `kid` matches the
  ///     token header's `kid` (or the only key when no kid hints
  ///     are present). Falls back to ignoring kid when only one key
  ///     is in the set.
  ///   - Dispatches to `crypto.verifyRsa` / `crypto.verifyEcdsa`
  ///     based on the token header's `alg`.
  ///   - Throws on malformed token, unsupported alg, missing
  ///     matching key. Returns `{valid:bool, header, payload}` on
  ///     a successful dispatch (valid=false means cryptographic
  ///     verify failed — sig mismatch).
  ///
  /// Does NOT validate claims (iss / aud / exp / iat / nbf) — call
  /// `jwt.validateClaims` on the returned payload.
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

  /// Validate standard JWT claims. Returns null when all checks
  /// pass; returns an error string identifying the first failed
  /// check otherwise. Customer calls AFTER a successful
  /// `jwt.verify`.
  ///
  /// Accepted opts:
  ///   - iss (string): expected issuer (`payload.iss`).
  ///   - aud (string): expected audience. `payload.aud` may be a
  ///     string or array; check passes if `aud` appears.
  ///   - now (ms since epoch): defaults to `Date.now()`.
  ///   - leeway_s (number): clock-skew tolerance for exp/nbf.
  ///     Defaults to 30s.
  ///
  /// Returns errors as the strings "expired" / "not-yet-valid" /
  /// "issuer-mismatch" / "audience-mismatch" so callers can branch
  /// on the failure mode without parsing.
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
