(function () {
  class TextEncoder {
    get encoding() { return "utf-8"; }
    encode(input) {
      const s = String(input ?? "");
      const out = [];
      for (let i = 0; i < s.length; i++) {
        let cp = s.charCodeAt(i);
        if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < s.length) {
          const low = s.charCodeAt(i + 1);
          if (low >= 0xdc00 && low <= 0xdfff) {
            cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
            i++;
          }
        }
        if (cp < 0x80) {
          out.push(cp);
        } else if (cp < 0x800) {
          out.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
        } else if (cp < 0x10000) {
          out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
        } else {
          out.push(
            0xf0 | (cp >> 18),
            0x80 | ((cp >> 12) & 0x3f),
            0x80 | ((cp >> 6) & 0x3f),
            0x80 | (cp & 0x3f),
          );
        }
      }
      return new Uint8Array(out);
    }
  }
  class TextDecoder {
    constructor(label, options) {
      const enc = String(label ?? "utf-8").toLowerCase();
      if (enc !== "utf-8" && enc !== "utf8") {
        throw new RangeError("TextDecoder: only utf-8 is supported");
      }
      this._fatal = !!(options && options.fatal);
    }
    get encoding() { return "utf-8"; }
    decode(buffer) {
      if (buffer === undefined || buffer === null) return "";
      let bytes;
      if (buffer instanceof Uint8Array) {
        bytes = buffer;
      } else if (ArrayBuffer.isView(buffer)) {
        bytes = new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength);
      } else if (buffer instanceof ArrayBuffer) {
        bytes = new Uint8Array(buffer);
      } else {
        throw new TypeError("TextDecoder.decode: expected BufferSource");
      }
      let s = "";
      let i = 0;
      while (i < bytes.length) {
        const b = bytes[i++];
        if (b < 0x80) {
          s += String.fromCharCode(b);
        } else if ((b & 0xe0) === 0xc0 && i < bytes.length) {
          const b2 = bytes[i++];
          s += String.fromCharCode(((b & 0x1f) << 6) | (b2 & 0x3f));
        } else if ((b & 0xf0) === 0xe0 && i + 1 < bytes.length) {
          const b2 = bytes[i++], b3 = bytes[i++];
          s += String.fromCharCode(((b & 0x0f) << 12) | ((b2 & 0x3f) << 6) | (b3 & 0x3f));
        } else if ((b & 0xf8) === 0xf0 && i + 2 < bytes.length) {
          const b2 = bytes[i++], b3 = bytes[i++], b4 = bytes[i++];
          let cp = ((b & 0x07) << 18) | ((b2 & 0x3f) << 12) | ((b3 & 0x3f) << 6) | (b4 & 0x3f);
          cp -= 0x10000;
          s += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
        } else if (this._fatal) {
          throw new TypeError("TextDecoder: malformed utf-8");
        } else {
          s += "�";
        }
      }
      return s;
    }
  }
  globalThis.TextEncoder = TextEncoder;
  globalThis.TextDecoder = TextDecoder;
})();
