// surface test: crypto — both signature families (JWK/JOSE vs raw
// bytes) exercised with real keys; hash/hmac pinned to known-answer
// vectors. First execution of this shim under zig build test (it is
// exec-exempt in the doc-examples lint).

export default function () {
  check("crypto.sha256", () => {
    eq(crypto.sha256("abc"),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    // Uint8Array input hashes the same bytes.
    eq(crypto.sha256(new TextEncoder().encode("abc")),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    throws(() => crypto.sha256(42), /string or Uint8Array/);
  });

  check("crypto.hmacSha256", () => {
    eq(crypto.hmacSha256("key", "The quick brown fox jumps over the lazy dog"),
      "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8");
    // The shim forwards (key, undefined) so the native's arity check
    // passes and the type check answers.
    throws(() => crypto.hmacSha256("key"), /data must be a string or Uint8Array/);
    throws(() => crypto.hmacSha256(1, "d"), /key must be a string or Uint8Array/);
  });

  check("crypto.getRandomValues", () => {
    const a = new Uint8Array(16);
    const ret = crypto.getRandomValues(a);
    ok(ret === a, "returns the same instance");
    ok(a.some((b) => b !== 0), "filled in place");
  });

  check("crypto.randomBytes", () => {
    const b = crypto.randomBytes(32);
    ok(b instanceof Uint8Array && b.length === 32, "32 fresh bytes");
    eq(crypto.randomBytes(0).length, 0);
    throws(() => crypto.randomBytes(65537), /n must be in \[0, 65536\]/);
    throws(() => crypto.randomBytes(-1), /n must be in \[0, 65536\]/);
  });

  check("crypto.randomUUID", () => {
    const id = crypto.randomUUID();
    ok(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(id),
      "RFC 4122 v4 shape: " + id);
    ok(crypto.randomUUID() !== id, "fresh per call");
  });

  // ── JOSE family: RSA keygen → sign → verify, real keys ────────────
  check("crypto.oidcGenerateKey", () => {
    const { priv, jwk, kid } = crypto.oidcGenerateKey();
    ok(priv.includes("BEGIN") && priv.includes("PRIVATE KEY"), "opaque PEM");
    eq(jwk.kty, "RSA");
    eq(jwk.alg, "RS256");
    eq(jwk.use, "sig");
    ok(typeof jwk.n === "string" && jwk.n.length > 300, "2048-bit modulus");
    eq(jwk.kid, kid);
  });

  {
    const { priv, jwk } = crypto.oidcGenerateKey();
    const input = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJzdXJmYWNlIn0";
    const sig_b64 = crypto.oidcSign(priv, input);
    const data = new TextEncoder().encode(input);
    const sig = base64url.decode(sig_b64);
    check("crypto.oidcSign", () => {
      ok(typeof sig_b64 === "string", "base64url signature");
      eq(sig.length, 256); // raw RS256 sig over a 2048-bit key
    });
    check("crypto.verifyRsa", () => {
      eq(crypto.verifyRsa(jwk, "sha256", data, sig), true);
      const tampered = new TextEncoder().encode(input + "x");
      eq(crypto.verifyRsa(jwk, "sha256", tampered, sig), false);
    });
  }

  // ── JOSE family: ECDSA verify against a pinned P-256 vector ──────
  check("crypto.verifyEcdsa", () => {
    const jwk = {
      kty: "EC", crv: "P-256",
      x: "vXxzuIsum0ztpiAistqL4TGTpbVu3Cbn33hC4kzQtes",
      y: "BgWtp72oOsaiuA1-MUBA-kf_Frg7rIXO2wFEUbt85xo",
    };
    const data = new TextEncoder().encode("surface-test-es256-vector");
    const sig = base64url.decode(
      "32dQBuSA9m9IrPjvl1Q5K5b-aVsHkCJ2ZBUxCdQu4uBQyxeXUdYIvJukStuov8tmnsakJtdayZKk8Qw9bo8DYg");
    eq(crypto.verifyEcdsa(jwk, "sha256", data, sig), true);
    const flipped = new Uint8Array(sig);
    flipped[10] ^= 0xff;
    eq(crypto.verifyEcdsa(jwk, "sha256", data, flipped), false);
  });

  // ── Raw-bytes family: both supported curves roundtrip ─────────────
  check("crypto.ecdsaGenerateKey", () => {
    for (const curve of ["secp256k1", "P-256"]) {
      const { privateKey, publicKey } = crypto.ecdsaGenerateKey(curve);
      eq(privateKey.length, 32);
      eq(publicKey.length, 33);
      ok(publicKey[0] === 2 || publicKey[0] === 3, "compressed SEC1 point");
    }
  });

  check("crypto.ecdsaSign", () => {
    const { privateKey } = crypto.ecdsaGenerateKey("secp256k1");
    const sig = crypto.ecdsaSign("secp256k1", privateKey, new TextEncoder().encode("m"));
    eq(sig.length, 64);
  });

  check("crypto.ecdsaVerify", () => {
    for (const curve of ["secp256k1", "P-256"]) {
      const { privateKey, publicKey } = crypto.ecdsaGenerateKey(curve);
      const data = new TextEncoder().encode("commit-bytes-" + curve);
      const sig = crypto.ecdsaSign(curve, privateKey, data);
      eq(crypto.ecdsaVerify(curve, publicKey, data, sig), true);
      const other = new TextEncoder().encode("tampered");
      eq(crypto.ecdsaVerify(curve, publicKey, other, sig), false);
    }
  });

  return done();
}
