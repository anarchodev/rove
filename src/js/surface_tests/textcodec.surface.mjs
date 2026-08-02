// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// TextEncoder / TextDecoder — WHATWG UTF-8 subset over the native
// byte work.
export default function () {
  check("TextEncoder()", () => {
    ok(new TextEncoder() instanceof TextEncoder);
  });

  check("TextEncoder#encoding", () => {
    eq(new TextEncoder().encoding, "utf-8");
  });

  check("TextEncoder#encode", () => {
    const bytes = new TextEncoder().encode("héllo");
    ok(bytes instanceof Uint8Array);
    eq(Array.from(bytes), [104, 0xc3, 0xa9, 108, 108, 111]); // é → 2 bytes
    eq(new TextEncoder().encode("").length, 0);
    eq(new TextEncoder().encode(null).length, 0);   // nullish → ""
    eq(Array.from(new TextEncoder().encode(42)), [52, 50]); // coerced
    // Lone surrogate encodes as the raw 3-byte surrogate sequence
    // (WTF-8), NOT the U+FFFD replacement the JSDoc claims — pinned
    // as-built; see the shim's @example drift note.
    eq(Array.from(new TextEncoder().encode("\ud800")), [0xed, 0xa0, 0x80]);
  });

  check("TextDecoder()", () => {
    ok(new TextDecoder() instanceof TextDecoder);
    ok(new TextDecoder("utf8") instanceof TextDecoder); // alias accepted
    throws(() => new TextDecoder("latin1"), /only utf-8/);
  });

  check("TextDecoder#encoding", () => {
    eq(new TextDecoder().encoding, "utf-8");
  });

  check("TextDecoder#decode", () => {
    const dec = new TextDecoder();
    eq(dec.decode(new Uint8Array([104, 105])), "hi");
    eq(dec.decode(), "");                                  // nullish → ""
    eq(dec.decode(new Uint8Array([104, 105]).buffer), "hi"); // ArrayBuffer ok
    // Round-trip through the encoder.
    eq(dec.decode(new TextEncoder().encode("héllo…")), "héllo…");
    // Malformed: U+FFFD by default; fatal:true throws.
    eq(dec.decode(new Uint8Array([0xff])), "�");
    throws(() => new TextDecoder("utf-8", { fatal: true }).decode(new Uint8Array([0xff])));
    throws(() => dec.decode("not bytes"), /BufferSource/);
  });

  return done();
}
