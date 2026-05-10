// Base64 + base64url encoding/decoding + hex byte helpers.
//
// `atob` / `btoa` are the standard browser-shaped APIs (binary
// string on either side, padded standard base64). `base64url`
// works on Uint8Array (the shape PKCE / JWT verification needs:
// digest bytes in, URL-safe string out, no padding).
//
// `hex.encode` / `hex.decode` bridge between the platform's
// hex-string-returning crypto APIs and the byte-oriented
// base64url surface — `base64url.encode(hex.decode(crypto.sha256(x)))`
// is the PKCE code_challenge in two lines.

const STD_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

function _encodeBase(bytes, alphabet, padding) {
  let out = "";
  let i = 0;
  while (i + 2 < bytes.length) {
    const b0 = bytes[i++], b1 = bytes[i++], b2 = bytes[i++];
    out += alphabet[b0 >> 2];
    out += alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
    out += alphabet[((b1 & 0x0f) << 2) | (b2 >> 6)];
    out += alphabet[b2 & 0x3f];
  }
  const remaining = bytes.length - i;
  if (remaining === 1) {
    const b0 = bytes[i];
    out += alphabet[b0 >> 2];
    out += alphabet[(b0 & 0x03) << 4];
    if (padding) out += "==";
  } else if (remaining === 2) {
    const b0 = bytes[i], b1 = bytes[i + 1];
    out += alphabet[b0 >> 2];
    out += alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
    out += alphabet[(b1 & 0x0f) << 2];
    if (padding) out += "=";
  }
  return out;
}

function _decodeBase(str, lookup) {
  // Strip padding + any whitespace (atob tolerates both).
  let s = "";
  for (let i = 0; i < str.length; i++) {
    const ch = str[i];
    if (ch === "=" || ch === " " || ch === "\n" || ch === "\r" || ch === "\t") continue;
    s += ch;
  }
  const out_len = (s.length * 3) >> 2;
  const out = new Uint8Array(out_len);
  let oi = 0;
  let i = 0;
  while (i + 3 < s.length) {
    const v0 = lookup[s.charCodeAt(i)],
          v1 = lookup[s.charCodeAt(i + 1)],
          v2 = lookup[s.charCodeAt(i + 2)],
          v3 = lookup[s.charCodeAt(i + 3)];
    if (v0 < 0 || v1 < 0 || v2 < 0 || v3 < 0) {
      throw new Error("invalid base64 input");
    }
    out[oi++] = (v0 << 2) | (v1 >> 4);
    out[oi++] = ((v1 & 0x0f) << 4) | (v2 >> 2);
    out[oi++] = ((v2 & 0x03) << 6) | v3;
    i += 4;
  }
  const tail = s.length - i;
  if (tail === 2) {
    const v0 = lookup[s.charCodeAt(i)], v1 = lookup[s.charCodeAt(i + 1)];
    if (v0 < 0 || v1 < 0) throw new Error("invalid base64 input");
    out[oi++] = (v0 << 2) | (v1 >> 4);
  } else if (tail === 3) {
    const v0 = lookup[s.charCodeAt(i)],
          v1 = lookup[s.charCodeAt(i + 1)],
          v2 = lookup[s.charCodeAt(i + 2)];
    if (v0 < 0 || v1 < 0 || v2 < 0) throw new Error("invalid base64 input");
    out[oi++] = (v0 << 2) | (v1 >> 4);
    out[oi++] = ((v1 & 0x0f) << 4) | (v2 >> 2);
  }
  return out.subarray(0, oi);
}

function _buildLookup(alphabet) {
  const arr = new Int8Array(128).fill(-1);
  for (let i = 0; i < alphabet.length; i++) arr[alphabet.charCodeAt(i)] = i;
  return arr;
}
const STD_LOOKUP = _buildLookup(STD_ALPHABET);
const URL_LOOKUP = _buildLookup(URL_ALPHABET);
// Cross-tolerant decoder: accept either alphabet on input. Useful
// because code in the wild emits both styles and parsers should be
// liberal in what they accept.
const ANY_LOOKUP = (() => {
  const arr = new Int8Array(STD_LOOKUP);
  for (let i = 0; i < arr.length; i++) {
    if (URL_LOOKUP[i] >= 0) arr[i] = URL_LOOKUP[i];
  }
  return arr;
})();

function _stringToBytes(s) {
  // Treat string as binary (each char = byte 0-255). Matches btoa
  // semantics. Throws on out-of-range chars to surface bugs early.
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    const code = s.charCodeAt(i);
    if (code > 0xff) throw new Error("btoa: input contains non-Latin-1 character");
    out[i] = code;
  }
  return out;
}

function _bytesToString(bytes) {
  // Inverse of _stringToBytes — binary string out. Use TextDecoder
  // if you want UTF-8 interpretation.
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return s;
}

globalThis.btoa = function (s) {
  if (typeof s !== "string") s = String(s);
  return _encodeBase(_stringToBytes(s), STD_ALPHABET, true);
};

globalThis.atob = function (s) {
  if (typeof s !== "string") s = String(s);
  return _bytesToString(_decodeBase(s, STD_LOOKUP));
};

globalThis.base64url = {
  // Encode Uint8Array (or array-like of bytes) as URL-safe base64,
  // no padding. Strings are interpreted as UTF-8 bytes via TextEncoder.
  encode(input) {
    let bytes;
    if (typeof input === "string") {
      bytes = new TextEncoder().encode(input);
    } else if (input instanceof Uint8Array) {
      bytes = input;
    } else {
      bytes = new Uint8Array(input);
    }
    return _encodeBase(bytes, URL_ALPHABET, false);
  },

  // Decode URL-safe base64 (with or without padding) to Uint8Array.
  // Tolerates the standard alphabet too.
  decode(s) {
    if (typeof s !== "string") s = String(s);
    return _decodeBase(s, ANY_LOOKUP);
  },
};

globalThis.hex = {
  // Uint8Array → lowercase hex string.
  encode(bytes) {
    if (!(bytes instanceof Uint8Array)) bytes = new Uint8Array(bytes);
    const tab = "0123456789abcdef";
    let out = "";
    for (let i = 0; i < bytes.length; i++) {
      out += tab[bytes[i] >> 4];
      out += tab[bytes[i] & 0x0f];
    }
    return out;
  },

  // Hex string → Uint8Array. Accepts upper or lower case; throws on
  // odd-length input or non-hex chars.
  decode(s) {
    if (typeof s !== "string") throw new TypeError("hex.decode: input must be a string");
    if ((s.length & 1) !== 0) throw new Error("hex.decode: odd-length input");
    const out = new Uint8Array(s.length >> 1);
    for (let i = 0; i < out.length; i++) {
      const hi = _hexNibble(s.charCodeAt(i * 2));
      const lo = _hexNibble(s.charCodeAt(i * 2 + 1));
      if (hi < 0 || lo < 0) throw new Error("hex.decode: non-hex character");
      out[i] = (hi << 4) | lo;
    }
    return out;
  },
};

function _hexNibble(code) {
  if (code >= 0x30 && code <= 0x39) return code - 0x30;
  if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10;
  if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10;
  return -1;
}
