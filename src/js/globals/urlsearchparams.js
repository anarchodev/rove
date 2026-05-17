// `URLSearchParams` polyfill — spec-compliant subset for parsing
// + building query strings without depending on the full URL class.
//
// Construct with:
//   - a string ("a=1&b=2", optionally with a leading "?")
//   - a plain object ({a:1, b:2})
//   - an array of [name, value] pairs
//   - another URLSearchParams (clones)
//
// Methods: append, delete, entries, forEach, get, getAll, has, keys,
// set, sort, toString, values, [Symbol.iterator], `size`.
//
// Encoding follows application/x-www-form-urlencoded — same as the
// dispatcher's query-string parser (`?fn=&args=`), so a value
// produced by `toString()` round-trips through the platform.

class URLSearchParams {
  constructor(init) {
    this._list = []; // array of [name, value] pairs; both strings

    if (init === undefined || init === null || init === "") {
      return;
    }
    if (typeof init === "string") {
      this._parseString(init);
      return;
    }
    if (init instanceof URLSearchParams) {
      this._list = init._list.map((p) => [p[0], p[1]]);
      return;
    }
    if (Array.isArray(init)) {
      for (const entry of init) {
        if (!Array.isArray(entry) || entry.length !== 2) {
          throw new TypeError("URLSearchParams: array init requires [name, value] pairs");
        }
        this._list.push([String(entry[0]), String(entry[1])]);
      }
      return;
    }
    if (typeof init === "object") {
      for (const k of Object.keys(init)) {
        this._list.push([String(k), String(init[k])]);
      }
      return;
    }
    throw new TypeError("URLSearchParams: unsupported init type");
  }

  _parseString(s) {
    if (s[0] === "?") s = s.slice(1);
    if (s.length === 0) return;
    for (const pair of s.split("&")) {
      if (pair.length === 0) continue;
      const eq = pair.indexOf("=");
      let name, value;
      if (eq === -1) {
        name = pair;
        value = "";
      } else {
        name = pair.slice(0, eq);
        value = pair.slice(eq + 1);
      }
      this._list.push([_decode(name), _decode(value)]);
    }
  }

  get size() {
    return this._list.length;
  }

  append(name, value) {
    this._list.push([String(name), String(value)]);
  }

  delete(name) {
    name = String(name);
    this._list = this._list.filter((p) => p[0] !== name);
  }

  get(name) {
    name = String(name);
    for (const p of this._list) if (p[0] === name) return p[1];
    return null;
  }

  getAll(name) {
    name = String(name);
    return this._list.filter((p) => p[0] === name).map((p) => p[1]);
  }

  has(name) {
    name = String(name);
    return this._list.some((p) => p[0] === name);
  }

  set(name, value) {
    name = String(name);
    value = String(value);
    let replaced = false;
    const next = [];
    for (const p of this._list) {
      if (p[0] === name) {
        if (!replaced) {
          next.push([name, value]);
          replaced = true;
        }
      } else {
        next.push(p);
      }
    }
    if (!replaced) next.push([name, value]);
    this._list = next;
  }

  sort() {
    // Stable sort by name (UCS-2 code units, per spec).
    const indexed = this._list.map((p, i) => [p, i]);
    indexed.sort((a, b) => {
      if (a[0][0] < b[0][0]) return -1;
      if (a[0][0] > b[0][0]) return 1;
      return a[1] - b[1];
    });
    this._list = indexed.map((entry) => entry[0]);
  }

  toString() {
    const parts = [];
    for (const p of this._list) {
      parts.push(_encode(p[0]) + "=" + _encode(p[1]));
    }
    return parts.join("&");
  }

  *entries() {
    for (const p of this._list) yield [p[0], p[1]];
  }

  *keys() {
    for (const p of this._list) yield p[0];
  }

  *values() {
    for (const p of this._list) yield p[1];
  }

  [Symbol.iterator]() {
    return this.entries();
  }

  forEach(callback, thisArg) {
    for (const p of this._list) callback.call(thisArg, p[1], p[0], this);
  }
}

// application/x-www-form-urlencoded: encode every byte that isn't
// in the unreserved set + space → +. The receiver (parseDispatch
// in dispatcher.zig) accepts either +-as-space or %20.
function _encode(s) {
  let out = "";
  // Iterate UTF-8 bytes via TextEncoder so non-ASCII characters
  // get percent-encoded byte-by-byte.
  const bytes = new TextEncoder().encode(s);
  const hex = "0123456789ABCDEF";
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i];
    if (b === 0x20) {
      out += "+";
    } else if (
      (b >= 0x41 && b <= 0x5a) || // A-Z
      (b >= 0x61 && b <= 0x7a) || // a-z
      (b >= 0x30 && b <= 0x39) || // 0-9
      b === 0x2a || b === 0x2d || b === 0x2e || b === 0x5f
      // * - . _ — application/x-www-form-urlencoded unreserved
    ) {
      out += String.fromCharCode(b);
    } else {
      out += "%" + hex[b >> 4] + hex[b & 0x0f];
    }
  }
  return out;
}

function _decode(s) {
  // Replace '+' with space first, then percent-decode UTF-8.
  let bytes_len = 0;
  // First pass: compute byte length.
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "%") {
      i += 2;
    }
    bytes_len++;
  }
  const bytes = new Uint8Array(bytes_len);
  let bi = 0;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "+") {
      bytes[bi++] = 0x20;
    } else if (ch === "%" && i + 2 < s.length) {
      const hi = _hexCh(s.charCodeAt(i + 1));
      const lo = _hexCh(s.charCodeAt(i + 2));
      if (hi >= 0 && lo >= 0) {
        bytes[bi++] = (hi << 4) | lo;
        i += 2;
      } else {
        bytes[bi++] = ch.charCodeAt(0);
      }
    } else {
      bytes[bi++] = ch.charCodeAt(0);
    }
  }
  return new TextDecoder().decode(bytes.subarray(0, bi));
}

function _hexCh(code) {
  if (code >= 0x30 && code <= 0x39) return code - 0x30;
  if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10;
  if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10;
  return -1;
}

globalThis.URLSearchParams = URLSearchParams;
