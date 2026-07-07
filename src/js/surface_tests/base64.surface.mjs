// base64 — btoa/atob (binary-string, padded standard alphabet),
// base64url (bytes, URL alphabet, unpadded), hex (bytes ⇄ lowercase).
export default function () {
  check("btoa()", () => {
    eq(btoa("hello"), "aGVsbG8=");
    eq(btoa(""), "");
    eq(btoa("\xff\x00"), "/wA=");           // binary string, std alphabet
    throws(() => btoa("héllo…"), /non-Latin-1/); // >0xff chars fail loud
  });

  check("atob()", () => {
    eq(atob("aGVsbG8="), "hello");
    eq(atob("aGVsbG8"), "hello");            // padding optional
    eq(atob("aGVs\nbG8="), "hello");         // whitespace tolerated
    eq(atob("/wA="), "\xff\x00");
    throws(() => atob("a$b!"), /invalid base64/);
  });

  check("base64url.encode", () => {
    eq(base64url.encode(new Uint8Array([0xff, 0x00])), "_wA"); // URL alphabet, no padding
    eq(base64url.encode("hi"), "aGk");       // string input is UTF-8 encoded
    eq(base64url.encode([104, 105]), "aGk"); // number[] accepted
  });

  check("base64url.decode", () => {
    eq(Array.from(base64url.decode("_wA")), [255, 0]);
    eq(Array.from(base64url.decode("/wA=")), [255, 0]); // liberal: std alphabet + padding
    throws(() => base64url.decode("a$bc"), /invalid base64/);
  });

  check("hex.encode", () => {
    eq(hex.encode(new Uint8Array([255, 0])), "ff00");
    eq(hex.encode([1, 2, 171]), "0102ab");
    eq(hex.encode(new Uint8Array(0)), "");
  });

  check("hex.decode", () => {
    eq(Array.from(hex.decode("ff00")), [255, 0]);
    eq(Array.from(hex.decode("FF00")), [255, 0]); // case-insensitive
    throws(() => hex.decode("abc"), /odd-length/);
    throws(() => hex.decode("zz"), /non-hex/);
    throws(() => hex.decode(5), /must be a string/);
  });

  // The documented PKCE bridge composes across all three namespaces.
  check("base64url.encode", () => {
    const digest_hex = crypto.sha256("verifier");
    eq(base64url.encode(hex.decode(digest_hex)).length, 43); // 32 bytes → 43 chars
  });

  return done();
}
