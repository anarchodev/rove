// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Pure-JS UTF-8 `TextEncoder` / `TextDecoder` — the codec for arenas that
// have no native textcodec binding: the CLI sim/replay epilogue splices this
// file into its per-run script, and the browser WASM replay prelude
// (scripts/ops/gen_replay_prelude.py) evals it into the arena base. Prod is
// different: it installs globals/textcodec.js over the native
// `_system.textcodec` (bindings/textcodec.zig) and never sees this file.
//
// The codec matches prod byte-for-byte — a latin1 (`charCodeAt & 0xff`)
// shortcut diverges on EVERY non-ASCII byte, which silently corrupts every
// hash/HMAC/JWT/base64url/signature computed over non-ASCII text offline.
// That includes the lone-surrogate corner: prod (QuickJS) encodes a LONE
// surrogate as its 3-byte WTF-8 form (ED A0 80), NOT the WHATWG U+FFFD
// replacement, and so does this encoder.
//
// Idempotent: installs only where `TextDecoder` is absent, so a request-arena
// re-eval over a base that already ran it keeps the base copy.
(function () {
  if (typeof globalThis.TextDecoder !== "undefined") return;
  const __utf8Encode = (s) => { s = String(s == null ? "" : s); const out = []; for (let i = 0; i < s.length; i++) { let cp = s.charCodeAt(i); if (cp >= 0xD800 && cp <= 0xDBFF) { const lo = i + 1 < s.length ? s.charCodeAt(i + 1) : 0; if (lo >= 0xDC00 && lo <= 0xDFFF) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); i++; } } if (cp < 0x80) out.push(cp); else if (cp < 0x800) out.push(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F)); else if (cp < 0x10000) out.push(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)); else out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)); } const u = new Uint8Array(out.length); for (let i = 0; i < out.length; i++) u[i] = out[i]; return u; };
  const __utf8Decode = (bytes, fatal) => { let b = bytes; if (typeof b === "string") { const t = new Uint8Array(b.length); for (let i = 0; i < b.length; i++) t[i] = b.charCodeAt(i) & 0xff; b = t; } let s = ""; let i = 0; const n = b.length; const bad = () => { if (fatal) throw new TypeError("TextDecoder: malformed UTF-8"); s += "\uFFFD"; }; while (i < n) { const c0 = b[i]; if (c0 < 0x80) { s += String.fromCharCode(c0); i++; continue; } let need, cp, min; if (c0 >= 0xC2 && c0 <= 0xDF) { need = 1; cp = c0 & 0x1F; min = 0x80; } else if (c0 >= 0xE0 && c0 <= 0xEF) { need = 2; cp = c0 & 0x0F; min = 0x800; } else if (c0 >= 0xF0 && c0 <= 0xF4) { need = 3; cp = c0 & 0x07; min = 0x10000; } else { bad(); i++; continue; } let ok = i + need < n; for (let k = 1; ok && k <= need; k++) { const cc = b[i + k]; if (cc < 0x80 || cc > 0xBF) { ok = false; break; } cp = (cp << 6) | (cc & 0x3F); } if (!ok || cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) { bad(); i++; continue; } if (cp < 0x10000) s += String.fromCharCode(cp); else { cp -= 0x10000; s += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF)); } i += need + 1; } return s; };
  globalThis.TextDecoder = function (label, options) { const enc = String(label == null ? "utf-8" : label).toLowerCase(); if (enc !== "utf-8" && enc !== "utf8") throw new RangeError("TextDecoder: only utf-8 is supported"); this._fatal = !!(options && options.fatal); };
  globalThis.TextDecoder.prototype.decode = function (u) { if (u == null) return ""; return __utf8Decode(u, this._fatal); };
  globalThis.TextEncoder = function () {};
  globalThis.TextEncoder.prototype.encode = function (s) { return __utf8Encode(s); };
})();
