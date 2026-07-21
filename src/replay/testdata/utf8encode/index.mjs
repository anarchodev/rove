// UTF-8 TextEncoder / TextDecoder parity. The sim base ships no
// native TextEncoder; the fix gives it a real WHATWG UTF-8 codec so bytes /
// hashes / base64url / signatures over non-ASCII match prod byte-for-byte.
// Every value below is the same offline (rewind test) and online (worker).
export default function () {
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  const s = "héllo €🚀";          // 2- + 3- + 4-byte code points
  const bytes = enc.encode(s);
  // Code points of a decode — JSON-safe view of a string that may hold U+FFFD
  // or a lone surrogate (raw surrogates would break JSON.stringify).
  const decCps = (arr) => Array.from(dec.decode(new Uint8Array(arr))).map((ch) => ch.codePointAt(0));
  return {
    hex: hex.encode(bytes),
    b64: base64url.encode(s),      // base64url.encode(string) runs through TextEncoder
    sha: crypto.sha256(bytes),
    text: dec.decode(bytes),                       // round-trips back to the string
    loneHex: hex.encode(enc.encode("\uD800")),     // lone surrogate → 3-byte WTF-8 (prod/QuickJS)
    // Decoder over malformed input — whatever prod does, the sim must match.
    decInvalidLead: decCps([0x41, 0xff, 0x42]),    // A, <invalid ff>, B
    decIncomplete: decCps([0x41, 0xc3]),           // A, <incomplete 2-byte>
    decOverlong: decCps([0xc0, 0x80]),             // overlong encoding of NUL
    decSurrogate: decCps([0xed, 0xa0, 0x80]),      // 3-byte WTF-8 for U+D800
  };
}
