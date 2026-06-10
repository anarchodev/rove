// UTF-8 `TextEncoder` / `TextDecoder` (QuickJS-ng ships neither).
// WHATWG Encoding-standard shaped; UTF-8 only. Used by base64url /
// URLSearchParams for byte-accurate handling.
//
// The class shells (label validation, `fatal`, BufferSource
// normalization) live here; the byte work is NATIVE
// (`_system.textcodec`, bindings/textcodec.zig). The earlier
// pure-JS per-char decode loop generated O(N) string-realloc
// garbage, which the no-reclaim request arena counts in full —
// ~139 KB decodes exhausted it. Natively each direction is one
// conversion (QuickJS strings construct from / convert to UTF-8).

(function () {
  const sysTc = _system.textcodec;

  /**
   * Encodes a JS string to UTF-8 bytes. WHATWG `TextEncoder` subset
   * (UTF-8 only).
   *
   * @class TextEncoder
   */
  class TextEncoder {
    /** @returns {string} Always `"utf-8"`. */
    get encoding() { return "utf-8"; }
    /**
     * Encode a string as UTF-8.
     *
     * @param {string} input - Coerced to a string; nullish → `""`.
     * @returns {Uint8Array} The UTF-8 bytes. Lone surrogates encode
     *   as U+FFFD (WHATWG replacement behavior).
     *
     * @example
     * const bytes = new TextEncoder().encode("héllo"); // 6 bytes
     */
    encode(input) {
      return sysTc.encode(String(input ?? ""));
    }
  }

  /**
   * Decodes UTF-8 bytes to a JS string. WHATWG `TextDecoder` subset
   * (UTF-8 only).
   *
   * @class TextDecoder
   */
  class TextDecoder {
    /**
     * @param {string} [label="utf-8"] - Encoding label. Only
     *   `"utf-8"`/`"utf8"` accepted; anything else throws
     *   `RangeError`.
     * @param {{fatal?: boolean}} [options] - `fatal: true` throws
     *   `TypeError` on malformed UTF-8 instead of substituting U+FFFD.
     */
    constructor(label, options) {
      const enc = String(label ?? "utf-8").toLowerCase();
      if (enc !== "utf-8" && enc !== "utf8") {
        throw new RangeError("TextDecoder: only utf-8 is supported");
      }
      this._fatal = !!(options && options.fatal);
    }
    /** @returns {string} Always `"utf-8"`. */
    get encoding() { return "utf-8"; }
    /**
     * Decode UTF-8 bytes to a string.
     *
     * @param {Uint8Array|ArrayBuffer|ArrayBufferView} [buffer] -
     *   Bytes to decode; nullish → `""`. Non-BufferSource →
     *   `TypeError`.
     * @returns {string} The decoded string. Malformed sequences
     *   become U+FFFD unless `fatal` was set.
     *
     * @example
     * const s = new TextDecoder().decode(new Uint8Array([104, 105]));
     * // "hi"
     */
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
      return sysTc.decode(bytes, this._fatal);
    }
  }

  globalThis.TextEncoder = TextEncoder;
  globalThis.TextDecoder = TextDecoder;
})();
