// Public `crypto` surface — the documentation source of truth for
// handler cryptography (docs/builtin-libs-docs-plan.md Phase A).
//
// Thin shim over the native `_system.crypto` binding. Top-level
// `crypto.*` names are unchanged; `_system.*` is the internal ABI and
// customer code must never reference it directly. The bundled
// jwt/oauth/oidc/sessions libraries compose on this shim.
//
// Evaluated as a global script (no module/exports) into every
// dispatcher context after the native bindings install.

(function () {
  const sys = _system.crypto;

  /**
   * Cryptographic primitives. Random sources (`getRandomValues`,
   * `randomUUID`, `randomBytes`) are replay-deterministic — captured
   * to the request tape and re-issued identically on replay. Hash and
   * signature-verify operations are pure functions of their inputs and
   * are not taped.
   *
   * @namespace crypto
   */
  globalThis.crypto = {
    /**
     * Fill a typed array with cryptographically random bytes, in
     * place. Web Crypto compatible.
     *
     * @param {Uint8Array} typedArray - The array to fill.
     * @returns {Uint8Array} The same array instance, now filled.
     *
     * @example
     * const salt = crypto.getRandomValues(new Uint8Array(16));
     */
    getRandomValues(typedArray) {
      return sys.getRandomValues(typedArray);
    },

    /**
     * Generate a random RFC 4122 v4 UUID string.
     *
     * @returns {string} e.g. `"f47ac10b-58cc-4372-a567-0e02b2c3d479"`.
     *
     * @example
     * const id = crypto.randomUUID();
     */
    randomUUID() {
      return sys.randomUUID();
    },

    /**
     * Return `n` cryptographically random bytes.
     *
     * @param {number} n - Byte count. Non-negative integer ≤ 65536;
     *   out of range throws `RangeError`.
     * @returns {Uint8Array} `n` fresh random bytes.
     *
     * @example
     * const token = base64url.encode(crypto.randomBytes(32));
     */
    randomBytes(n) {
      return sys.randomBytes(n);
    },

    /**
     * SHA-256 digest of `data`.
     *
     * @param {string|Uint8Array} data - String (hashed as UTF-8
     *   bytes) or raw bytes.
     * @returns {string} Lowercase hex, 64 characters.
     *
     * @example
     * const fp = crypto.sha256(JSON.stringify(payload));
     */
    sha256(data) {
      return sys.sha256(data);
    },

    /**
     * HMAC-SHA256 of `data` under `key`. The vendor-neutral primitive
     * for Stripe-Signature / X-Slack-Signature / AWS SigV4 style
     * derivations (compose the provider's exact scheme in handler JS).
     *
     * @param {string|Uint8Array} key - Secret key (UTF-8 if string).
     * @param {string|Uint8Array} data - Message bytes (UTF-8 if
     *   string).
     * @returns {string} Lowercase hex, 64 characters.
     *
     * @example
     * const sig = crypto.hmacSha256(webhookSecret, request.body);
     * if (sig !== request.headers["x-signature"]) return unauthorized();
     */
    hmacSha256(key, data) {
      return sys.hmacSha256(key, data);
    },

    /**
     * Verify an RSA-PKCS#1 v1.5 (RS256/RS384/RS512) signature. Used to
     * validate OIDC id_tokens. Does NOT validate JWT claims (iss/aud/
     * exp/iat/nbf) — verify the signature here, then check claims.
     *
     * @param {{kty:string,n:string,e:string}} jwk - Public key from
     *   the provider JWKS (`n`/`e` base64url). Other fields ignored.
     * @param {string} alg - `"sha256"` | `"sha384"` | `"sha512"`
     *   (case-insensitive).
     * @param {Uint8Array} data - JWS signing input bytes
     *   (`header_b64 + "." + payload_b64`, UTF-8).
     * @param {Uint8Array} sig - Raw signature bytes (the base64url-
     *   decoded third JWS segment).
     * @returns {boolean} `true` if valid, `false` if it does not
     *   match. Throws on malformed input.
     *
     * @example
     * const ok = crypto.verifyRsa(jwks.keys[0], "sha256", signingInput, sigBytes);
     */
    verifyRsa(jwk, alg, data, sig) {
      return sys.verifyRsa(jwk, alg, data, sig);
    },

    /**
     * Verify a JWS ECDSA (ES256/ES384/ES512) signature — Sign in with
     * Apple, AWS Cognito on EC keys, etc. Does NOT validate JWT
     * claims. The signature is raw `R||S` per JWS (not DER); the
     * binding converts internally.
     *
     * @param {{kty:string,crv:string,x:string,y:string}} jwk - EC
     *   public key; `crv` is `"P-256"` | `"P-384"` | `"P-521"`.
     * @param {string} alg - `"sha256"` | `"sha384"` | `"sha512"`
     *   (case-insensitive; match it to the curve).
     * @param {Uint8Array} data - JWS signing input bytes.
     * @param {Uint8Array} sig - Raw `R||S` (64 B for P-256, 96 for
     *   P-384, 132 for P-521).
     * @returns {boolean} `true` if valid, `false` otherwise. Throws on
     *   malformed input.
     *
     * @example
     * const ok = crypto.verifyEcdsa(appleKey, "sha256", signingInput, sigBytes);
     */
    verifyEcdsa(jwk, alg, data, sig) {
      return sys.verifyEcdsa(jwk, alg, data, sig);
    },

    /**
     * Generate an RSA-2048 keypair for an OIDC identity provider. The
     * private key is returned as an opaque PEM the IdP stores and
     * never parses (key custody stays in Zig/OpenSSL).
     *
     * @returns {{priv:string, jwk:{kty:string,n:string,e:string,alg:string,use:string,kid:string}, kid:string}}
     *   `priv` is an opaque PKCS#8 PEM; `jwk` is publishable at the
     *   JWKS endpoint; `kid` is the key id.
     *
     * @example
     * const { priv, jwk, kid } = crypto.oidcGenerateKey();
     * kv.set("oidc/privkey", priv);
     * kv.set("oidc/jwks", JSON.stringify({ keys: [jwk] }));
     */
    oidcGenerateKey() {
      return sys.oidcGenerateKey();
    },

    /**
     * RS256-sign an OIDC JWS signing input with a private key minted
     * by {@link crypto.oidcGenerateKey}.
     *
     * @param {string} privPem - The opaque PEM from `oidcGenerateKey`.
     * @param {string} signingInput - `header_b64 + "." + payload_b64`.
     * @returns {string} base64url-encoded RS256 signature (the third
     *   JWS segment).
     *
     * @example
     * const jwt = signingInput + "." + crypto.oidcSign(priv, signingInput);
     */
    oidcSign(privPem, signingInput) {
      return sys.oidcSign(privPem, signingInput);
    },

    /**
     * Generate a raw ECDSA keypair over `secp256k1` or `P-256` — the
     * two signing curves the AT Protocol (Bluesky) uses for repo
     * signing keys and `did:plc` rotation keys.
     *
     * Distinct from {@link crypto.oidcGenerateKey} (RSA, JOSE) and the
     * JWK {@link crypto.verifyEcdsa} path (JOSE, DER-tolerant): this
     * surface is raw bytes, SHA-256, compact `R‖S` signatures, with
     * **low-S enforced** — the malleability rule the atproto data
     * model requires. Multibase/multicodec `did:key` encoding of the
     * public key is pure JS (done in the `atproto` library).
     *
     * @param {string} curve - `"secp256k1"` | `"P-256"`.
     * @returns {{privateKey:Uint8Array, publicKey:Uint8Array}}
     *   `privateKey` is the 32-byte scalar; `publicKey` is the
     *   33-byte compressed SEC1 point (`0x02`/`0x03 ‖ X`).
     *
     * @example
     * const { privateKey, publicKey } = crypto.ecdsaGenerateKey("secp256k1");
     * kv.set("repo/signing-key", base64url.encode(privateKey));
     */
    ecdsaGenerateKey(curve) {
      return sys.ecdsaGenerateKey(curve);
    },

    /**
     * ECDSA-sign `data` (SHA-256 digest) with a raw private scalar
     * from {@link crypto.ecdsaGenerateKey}. The signature is the
     * 64-byte compact `R‖S` form atproto stores in signed commits,
     * always low-S normalized.
     *
     * @param {string} curve - `"secp256k1"` | `"P-256"`.
     * @param {Uint8Array} privateKey - 32-byte scalar.
     * @param {Uint8Array} data - Message bytes (e.g. the dag-cbor
     *   encoding of an unsigned commit).
     * @returns {Uint8Array} 64-byte raw `R‖S` signature.
     *
     * @example
     * const sig = crypto.ecdsaSign("secp256k1", priv, dagCborBytes);
     */
    ecdsaSign(curve, privateKey, data) {
      return sys.ecdsaSign(curve, privateKey, data);
    },

    /**
     * Verify a 64-byte compact ECDSA signature (SHA-256). A high-S
     * signature returns `false` even if it is mathematically valid —
     * atproto rejects malleable signatures, so this primitive enforces
     * the rule rather than leaving it to callers.
     *
     * @param {string} curve - `"secp256k1"` | `"P-256"`.
     * @param {Uint8Array} publicKey - SEC1 point: 33-byte compressed
     *   or 65-byte uncompressed.
     * @param {Uint8Array} data - Message bytes that were signed.
     * @param {Uint8Array} sig - 64-byte raw `R‖S` signature.
     * @returns {boolean} `true` iff valid and low-S.
     *
     * @example
     * const ok = crypto.ecdsaVerify("secp256k1", pub, commitBytes, sig);
     */
    ecdsaVerify(curve, publicKey, data, sig) {
      return sys.ecdsaVerify(curve, publicKey, data, sig);
    },
  };
})();
