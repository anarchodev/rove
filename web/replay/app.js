// Loop46 replay shell (PLAN §10.12, beta scope).
//
// Runs at `replay.{public_suffix}`. Opened in a new tab from the
// dashboard's "Replay" button on each Logs row. Receives a bundle
// from the dashboard via postMessage (no worker round-trip from
// here), parses the captured tapes, builds a sandboxed iframe with
// stubbed Loop46 globals, injects `debugger;` at the handler entry,
// and lets the user step through using their browser's DevTools.
//
// Why everything-in-one-file: the shell is small, served as a static
// asset, and we want the source visible in DevTools without a build
// step. ES modules would force us to ship multiple files; one file
// keeps the deploy footprint minimal.

(() => {
  "use strict";

  const $status = document.getElementById("status");
  const $meta = document.getElementById("meta");
  const $iframeMount = document.getElementById("iframe-mount");
  const $sideEffects = document.getElementById("side-effects");

  function setStatus(text, kind) {
    $status.textContent = text;
    $status.className = "status " + (kind || "info");
  }

  // The dashboard origin is `app.<suffix>` and we're at `replay.<suffix>`.
  // Derive the expected origin instead of hardcoding the suffix — works
  // across `loop46.me`, `loop46.localhost`, future custom suffixes.
  function expectedDashboardOrigin() {
    return window.location.origin.replace("://replay.", "://app.");
  }

  // ── postMessage handshake ──────────────────────────────────────────
  //
  // We were window.open'd by the dashboard. Tell the opener we're
  // ready, then wait for a single `replay:bundle` message back.
  // Origin-checked against the derived dashboard origin so a stray
  // page on the same browser can't impersonate the opener.
  function awaitBundle() {
    if (!window.opener) {
      setStatus("error: this page must be opened from the dashboard — close it and click Replay", "error");
      return Promise.reject(new Error("no opener"));
    }
    const expectedOrigin = expectedDashboardOrigin();
    setStatus("waiting for bundle from dashboard…", "info");
    window.opener.postMessage({ kind: "replay:ready" }, expectedOrigin);

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        window.removeEventListener("message", onMsg);
        reject(new Error("bundle timeout (10s)"));
      }, 10_000);
      function onMsg(e) {
        if (e.origin !== expectedOrigin) return;
        if (e.source !== window.opener) return;
        if (e.data?.kind !== "replay:bundle") return;
        clearTimeout(timer);
        window.removeEventListener("message", onMsg);
        resolve(e.data.bundle);
      }
      window.addEventListener("message", onMsg);
    });
  }

  // ── Tape parser ────────────────────────────────────────────────────
  //
  // Mirrors `src/tape/root.zig`'s wire format, big-endian throughout.
  //
  //   [u32 magic 'RTAP'][u16 ver][u16 channel][u32 count]
  //   for each entry: [u32 len][entry bytes]
  //
  // Per-entry layouts in the order the channel union expects them.
  const RTAP_MAGIC = 0x52544150;
  const CHANNEL_KV = 0;
  const CHANNEL_DATE = 1;
  const CHANNEL_MATH_RANDOM = 2;
  const CHANNEL_CRYPTO_RANDOM = 3;
  const CHANNEL_MODULE = 4;

  const KV_OP_GET = 0;
  const KV_OP_SET = 1;
  const KV_OP_DELETE = 2;
  const KV_OP_PREFIX = 3;
  const KV_OUTCOME_OK = 0;
  const KV_OUTCOME_NOT_FOUND = 1;
  const KV_OUTCOME_ERR = 2;

  function parseTapeBlob(bytes) {
    if (!(bytes instanceof Uint8Array)) {
      throw new Error("parseTapeBlob: expected Uint8Array");
    }
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let off = 0;
    const magic = view.getUint32(off); off += 4;
    if (magic !== RTAP_MAGIC) throw new Error("bad tape magic 0x" + magic.toString(16));
    const version = view.getUint16(off); off += 2;
    if (version !== 1) throw new Error("unsupported tape version " + version);
    const channel = view.getUint16(off); off += 2;
    const count = view.getUint32(off); off += 4;
    const entries = [];
    for (let i = 0; i < count; i++) {
      const elen = view.getUint32(off); off += 4;
      const ebytes = bytes.subarray(off, off + elen); off += elen;
      entries.push(decodeEntry(channel, ebytes));
    }
    return { channel, entries };
  }

  function decodeEntry(channel, bytes) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const dec = new TextDecoder();
    let off = 0;
    function readLenPrefixed() {
      const n = view.getUint32(off); off += 4;
      const slice = bytes.subarray(off, off + n); off += n;
      return slice;
    }
    function readUtf8() { return dec.decode(readLenPrefixed()); }
    switch (channel) {
      case CHANNEL_KV: {
        const op = bytes[off]; off++;
        const outcome = bytes[off]; off++;
        const key = readUtf8();
        if (op === KV_OP_PREFIX) {
          // Wire shape: prefix, cursor, u32 limit, u32 count, then count
          // (key, value) pairs. Mirrors `encodeEntry` in src/tape/root.zig.
          const cursor = readUtf8();
          const limit = view.getUint32(off); off += 4;
          const count = view.getUint32(off); off += 4;
          const results = [];
          for (let i = 0; i < count; i++) {
            const k = readUtf8();
            const v = readUtf8();
            results.push({ key: k, value: v });
          }
          return { op, outcome, key, cursor, limit, results };
        }
        const value = readUtf8();
        return { op, outcome, key, value };
      }
      case CHANNEL_DATE: {
        // i64 big-endian. Native `getBigInt64` returns BigInt; we want
        // a plain JS number (ms epoch fits comfortably in 53 bits for
        // any sane request capture).
        return { ms: Number(view.getBigInt64(off)) };
      }
      case CHANNEL_MATH_RANDOM: {
        // `Math.random` was captured as the 8 raw bytes of the f64
        // result. `getFloat64` decodes to the same f64 the original
        // call returned — bit-identical replay.
        return { value: view.getFloat64(off) };
      }
      case CHANNEL_CRYPTO_RANDOM: {
        return { bytes: readLenPrefixed() };
      }
      case CHANNEL_MODULE: {
        const specifier = readUtf8();
        const source_hash_hex = readUtf8();
        return { specifier, source_hash_hex };
      }
      default:
        throw new Error("unknown tape channel " + channel);
    }
  }

  function parseTapesFromBundle(bundle) {
    const out = { kv: [], date: [], math_random: [], crypto_random: [] };
    const blobs = bundle.tape_blobs || {};
    for (const name of Object.keys(out)) {
      if (blobs[name]) {
        const parsed = parseTapeBlob(blobs[name]);
        out[name] = parsed.entries;
      }
    }
    return out;
  }

  // ── Iframe construction ────────────────────────────────────────────
  //
  // The iframe is sandbox="allow-scripts allow-modals" — no
  // allow-same-origin. That gives it a NULL origin, which means even
  // if the handler tries `document.cookie` or `localStorage` it can't
  // reach this page's storage (and we don't have any sensitive
  // storage on `replay.<suffix>` anyway).
  //
  // Multi-module support: each handler file in the deployment
  // becomes its own blob: URL inside the iframe. An importmap
  // injected before any module evaluates maps a stable specifier
  // (`loop46-replay/<path>`) to that blob URL. We rewrite each
  // module's relative imports (`import "./lib/foo"`) to the bare
  // specifier shape so the importmap can resolve them — relative
  // imports against blob URLs would resolve to gibberish otherwise.
  //
  // The import-rewrite is regex-based: matches `import "..."` and
  // `import ... from "..."` at the top of the source. Doesn't catch
  // dynamic `import(expr)` (handled at runtime, would need executable
  // string mapping) or imports inside template literals / comments.
  // For beta-scope handler patterns this is sufficient; documented
  // limitation otherwise.

  /// Resolve a relative specifier (`./x`, `../x`) against the
  /// importing module's path into a canonical deployment-relative
  /// key. Mirrors the QJS module loader's resolver in
  /// `src/js/dispatcher.zig:resolveSpecifier`.
  function resolveRelative(base, specifier) {
    if (!specifier.startsWith("./") && !specifier.startsWith("../")) {
      return specifier;
    }
    let dir = base.includes("/") ? base.slice(0, base.lastIndexOf("/")) : "";
    let rest = specifier;
    while (true) {
      if (rest.startsWith("./")) {
        rest = rest.slice(2);
      } else if (rest.startsWith("../")) {
        const slash = dir.lastIndexOf("/");
        dir = slash >= 0 ? dir.slice(0, slash) : "";
        rest = rest.slice(3);
      } else break;
    }
    return dir ? dir + "/" + rest : rest;
  }

  /// Rewrite static `import` statements in `source` to use a stable
  /// `loop46-replay/<resolved>` bare specifier the iframe importmap
  /// can resolve. Catches the four common forms — `import "x"`,
  /// `import default from "x"`, `import { ... } from "x"`,
  /// `import * as m from "x"` — plus `export ... from "x"`.
  function rewriteImports(source, modulePath) {
    const re = /(\b(?:import|export)\b[^"';\n]*?\bfrom\s*['"]|\bimport\s*['"])([^"']+)(['"])/g;
    return source.replace(re, (_match, pre, spec, post) => {
      const resolved = resolveRelative(modulePath, spec);
      return pre + "loop46-replay/" + resolved + post;
    });
  }

  function buildIframeSrcdoc(bundle, parsedTapes) {
    const meta = JSON.stringify({
      request: bundle.request || {},
      response_was: bundle.response || {},
      deployment_id: bundle.deployment_id ?? null,
    });

    // Pre-process every module: rewrite relative imports to bare
    // specifiers and append a `//# sourceURL=` comment so DevTools
    // shows them as real files under `loop46-replay/<path>`. The
    // entry path is whichever module the dispatcher picked as the
    // request handler.
    const entryPath = bundle.entry_path ||
      (bundle.modules?.find((m) => m.path === "index.mjs") ? "index.mjs" : null);
    const modulesIn = bundle.modules || [];
    const modulesOut = modulesIn.map((m) => ({
      path: m.path,
      source: rewriteImports(m.source, m.path) +
        "\n//# sourceURL=loop46-replay/" + m.path + "\n",
    }));
    // Fallback for the legacy single-file shape (entry_source set,
    // modules empty): synthesize a single-entry list so the
    // importmap path still applies.
    if (modulesOut.length === 0 && bundle.entry_source) {
      modulesOut.push({
        path: entryPath || "index.mjs",
        source: bundle.entry_source +
          "\n//# sourceURL=loop46-replay/" + (entryPath || "index.mjs") + "\n",
      });
    }
    const modulesJson = JSON.stringify(modulesOut);
    const entryPathJson = JSON.stringify(entryPath || "index.mjs");

    return `<!doctype html>
<html>
<head><meta charset="utf-8"><title>Loop46 replay</title></head>
<body>
<script>
const META = ${meta};
const MODULES = ${modulesJson};
const ENTRY_PATH = ${entryPathJson};

// Stubs — the rest of this script installs Loop46 globals reading
// from tapes that the parent page sends in a moment. We can't run
// the handler until those tapes arrive, so we wire up a promise
// gate the module loader waits on.
let __resolveTapes;
const __tapesReady = new Promise((r) => { __resolveTapes = r; });

let __state = null;
let __resolveDone, __rejectDone;
const __done = new Promise((r, e) => { __resolveDone = r; __rejectDone = e; });

window.addEventListener("message", (e) => {
  // Parent (replay.<suffix>) is same-origin from the iframe's null
  // origin perspective only via window.parent — origin will be
  // "null" or something funky depending on the browser. We accept
  // messages from window.parent only.
  if (e.source !== window.parent) return;
  if (e.data?.kind === "replay:tapes") {
    __resolveTapes(e.data.tapes);
  }
});

function installStubs(tapes) {
  const cur = { kv: 0, date: 0, math_random: 0, crypto_random: 0 };
  const sideEffects = [];

  function consume(name) {
    const arr = tapes[name];
    const i = cur[name]++;
    if (i >= arr.length) {
      throw new Error("tape exhausted: " + name + " (consumed " + (i + 1) + ", captured " + arr.length + ")");
    }
    return arr[i];
  }

  window.kv = {
    get(key) {
      const e = consume("kv");
      if (e.op !== ${KV_OP_GET} || e.key !== key) {
        throw new Error("tape divergence: expected kv." + ["get","set","delete"][e.op] + "(" + JSON.stringify(e.key) + "), got kv.get(" + JSON.stringify(key) + ")");
      }
      if (e.outcome === ${KV_OUTCOME_NOT_FOUND}) return null;
      if (e.outcome === ${KV_OUTCOME_ERR}) throw new Error("tape: kv error on get(" + key + ")");
      return e.value;
    },
    set(key, value) {
      const e = consume("kv");
      if (e.op !== ${KV_OP_SET} || e.key !== key) {
        throw new Error("tape divergence: expected kv." + ["get","set","delete"][e.op] + "(" + JSON.stringify(e.key) + "), got kv.set(" + JSON.stringify(key) + ")");
      }
    },
    delete(key) {
      const e = consume("kv");
      if (e.op !== ${KV_OP_DELETE} || e.key !== key) {
        throw new Error("tape divergence: expected kv." + ["get","set","delete"][e.op] + "(" + JSON.stringify(e.key) + "), got kv.delete(" + JSON.stringify(key) + ")");
      }
    },
    prefix(prefix, cursor, limit) {
      const e = consume("kv");
      if (e.op !== ${KV_OP_PREFIX} || e.key !== prefix || (e.cursor || "") !== (cursor || "")) {
        throw new Error("tape divergence: expected kv." + ["get","set","delete","prefix"][e.op] + "(" + JSON.stringify(e.key) + (e.op === ${KV_OP_PREFIX} ? ", " + JSON.stringify(e.cursor) : "") + "), got kv.prefix(" + JSON.stringify(prefix) + ", " + JSON.stringify(cursor || "") + ")");
      }
      if (e.outcome === ${KV_OUTCOME_ERR}) throw new Error("tape: kv.prefix error");
      // Original binding (src/js/globals.zig:jsKvPrefix) returns a flat
      // array of {key, value} — match that shape exactly. The captured
      // limit is informational; we don't validate against the handler's
      // limit arg (callers may pass undefined and get the default).
      return e.results.map((p) => ({ key: p.key, value: p.value }));
    },
  };

  // Replace Date.now without breaking the rest of Date — wrap rather
  // than reassign, so `new Date(ms)` still works.
  const origDate = window.Date;
  const dateFn = function (...args) {
    if (this instanceof dateFn) return new origDate(...args);
    return new origDate().toString();
  };
  dateFn.now = () => consume("date").ms;
  dateFn.UTC = origDate.UTC;
  dateFn.parse = origDate.parse;
  dateFn.prototype = origDate.prototype;
  window.Date = dateFn;

  // Math.random — copy the existing Math object so we keep all the
  // other functions (.floor, .max, etc.) and just override .random.
  const wrappedMath = Object.create(window.Math);
  wrappedMath.random = () => consume("math_random").value;
  Object.defineProperty(window, "Math", { value: wrappedMath, writable: false, configurable: true });

  // crypto.* — random ops consume from the crypto_random tape;
  // sha256 / hmacSha256 are deterministic over inputs (not captured)
  // and are computed in-iframe via the sync SHA-256 implementation
  // below. The Loop46 binding is sync (`crypto.hmacSha256(k, d) →
  // hex`), so the stub has to match — Web Crypto's subtle.* is
  // promise-based and would force every existing handler to add
  // \`await\`. Bundle a sync SHA-256 instead.
  const realCrypto = window.crypto;
  function bytesFromInput(v) {
    if (typeof v === "string") return new TextEncoder().encode(v);
    if (v instanceof Uint8Array) return v;
    if (v && v.buffer instanceof ArrayBuffer) return new Uint8Array(v.buffer, v.byteOffset || 0, v.byteLength);
    throw new TypeError("crypto: expected string or Uint8Array");
  }
  function bytesToHex(bytes) {
    let s = "";
    for (let i = 0; i < bytes.length; i++) s += bytes[i].toString(16).padStart(2, "0");
    return s;
  }
  // SHA-256 (FIPS 180-4). Self-checked at install time below — a wrong
  // implementation would silently diverge the handler from prod, so
  // we'd rather panic loudly on iframe boot.
  const SHA256_K = new Uint32Array([
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
  ]);
  function ror32(n, bits) { return ((n >>> bits) | (n << (32 - bits))) >>> 0; }
  function sha256Bytes(input) {
    const data = bytesFromInput(input);
    // Padding: 0x80 byte, zeros, then 8-byte big-endian bit length.
    const bitLen = data.length * 8;
    const padLen = ((data.length + 9 + 63) & ~63) - data.length;
    const padded = new Uint8Array(data.length + padLen);
    padded.set(data);
    padded[data.length] = 0x80;
    const view = new DataView(padded.buffer, padded.byteOffset, padded.byteLength);
    view.setUint32(padded.length - 8, Math.floor(bitLen / 0x100000000), false);
    view.setUint32(padded.length - 4, bitLen >>> 0, false);

    let h0=0x6a09e667,h1=0xbb67ae85,h2=0x3c6ef372,h3=0xa54ff53a,
        h4=0x510e527f,h5=0x9b05688c,h6=0x1f83d9ab,h7=0x5be0cd19;
    const w = new Uint32Array(64);
    for (let block = 0; block < padded.length; block += 64) {
      for (let i = 0; i < 16; i++) w[i] = view.getUint32(block + i * 4, false);
      for (let i = 16; i < 64; i++) {
        const s0 = ror32(w[i-15], 7) ^ ror32(w[i-15], 18) ^ (w[i-15] >>> 3);
        const s1 = ror32(w[i-2], 17) ^ ror32(w[i-2], 19) ^ (w[i-2] >>> 10);
        w[i] = (w[i-16] + s0 + w[i-7] + s1) >>> 0;
      }
      let a=h0,b=h1,c2=h2,d=h3,e=h4,f=h5,g=h6,hh=h7;
      for (let i = 0; i < 64; i++) {
        const S1 = ror32(e, 6) ^ ror32(e, 11) ^ ror32(e, 25);
        const ch = (e & f) ^ ((~e) & g);
        const t1 = (hh + S1 + ch + SHA256_K[i] + w[i]) >>> 0;
        const S0 = ror32(a, 2) ^ ror32(a, 13) ^ ror32(a, 22);
        const mj = (a & b) ^ (a & c2) ^ (b & c2);
        const t2 = (S0 + mj) >>> 0;
        hh=g; g=f; f=e; e=(d+t1)>>>0; d=c2; c2=b; b=a; a=(t1+t2)>>>0;
      }
      h0=(h0+a)>>>0; h1=(h1+b)>>>0; h2=(h2+c2)>>>0; h3=(h3+d)>>>0;
      h4=(h4+e)>>>0; h5=(h5+f)>>>0; h6=(h6+g)>>>0; h7=(h7+hh)>>>0;
    }
    const out = new Uint8Array(32);
    const ov = new DataView(out.buffer);
    ov.setUint32(0,h0,false); ov.setUint32(4,h1,false);
    ov.setUint32(8,h2,false); ov.setUint32(12,h3,false);
    ov.setUint32(16,h4,false); ov.setUint32(20,h5,false);
    ov.setUint32(24,h6,false); ov.setUint32(28,h7,false);
    return out;
  }
  function hmacSha256Hex(key, data) {
    let keyBytes = bytesFromInput(key);
    if (keyBytes.length > 64) keyBytes = sha256Bytes(keyBytes);
    const padded = new Uint8Array(64);
    padded.set(keyBytes);
    const ipad = new Uint8Array(64);
    const opad = new Uint8Array(64);
    for (let i = 0; i < 64; i++) {
      ipad[i] = padded[i] ^ 0x36;
      opad[i] = padded[i] ^ 0x5c;
    }
    const dataBytes = bytesFromInput(data);
    const inner = new Uint8Array(64 + dataBytes.length);
    inner.set(ipad);
    inner.set(dataBytes, 64);
    const innerHash = sha256Bytes(inner);
    const outer = new Uint8Array(64 + 32);
    outer.set(opad);
    outer.set(innerHash, 64);
    return bytesToHex(sha256Bytes(outer));
  }
  // Self-check: SHA-256("abc") and HMAC-SHA-256("key", "The quick
  // brown fox jumps over the lazy dog") have well-known expected
  // values. A wrong impl breaks every handler that hashes anything,
  // and the symptoms (auth tokens, kv keys all wrong) are confusing
  // to debug. Loud failure here is much friendlier.
  const SHA_ABC = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
  if (bytesToHex(sha256Bytes("abc")) !== SHA_ABC) {
    throw new Error("replay shell: sha256 self-check failed");
  }
  const HMAC_KEY = "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8";
  if (hmacSha256Hex("key", "The quick brown fox jumps over the lazy dog") !== HMAC_KEY) {
    throw new Error("replay shell: hmacSha256 self-check failed");
  }

  window.crypto = {
    getRandomValues(arr) {
      const e = consume("crypto_random");
      const src = e.bytes;
      // Copy as much as we have; if the request is larger than the
      // captured slice, the original would have made another call —
      // tape divergence.
      if (arr.byteLength !== src.byteLength) {
        throw new Error("tape divergence: getRandomValues(" + arr.byteLength + " bytes) but tape has " + src.byteLength);
      }
      new Uint8Array(arr.buffer, arr.byteOffset, arr.byteLength).set(src);
      return arr;
    },
    randomBytes(n) {
      // Loop46 binding allocates n random bytes via crypto.randomBytes(n)
      // and captures them. The replay just consumes the next entry.
      const e = consume("crypto_random");
      if (e.bytes.byteLength !== n) {
        throw new Error("tape divergence: randomBytes(" + n + ") but tape has " + e.bytes.byteLength);
      }
      // Copy out so the handler can mutate without aliasing the tape.
      return new Uint8Array(e.bytes);
    },
    randomUUID() {
      // RandomUUID was captured as 16 bytes via the same channel.
      const e = consume("crypto_random");
      const b = e.bytes;
      const hex = (n) => n.toString(16).padStart(2, "0");
      const h = Array.from(b).map(hex).join("");
      return h.slice(0,8) + "-" + h.slice(8,12) + "-" + h.slice(12,16) + "-" + h.slice(16,20) + "-" + h.slice(20,32);
    },
    sha256(input) { return bytesToHex(sha256Bytes(input)); },
    hmacSha256(key, data) { return hmacSha256Hex(key, data); },
    subtle: realCrypto?.subtle,
  };

  // webhook + email: record-only. Captured outbox is in the tape too
  // (via _outbox/* kv writes), so the kv tape will handle the actual
  // outbox row — these are just the customer-visible API surface.
  let fakeId = 1;
  window.webhook = {
    send(opts) {
      const id = "replay-fake-webhook-" + (fakeId++);
      sideEffects.push({ kind: "webhook.send", opts, id });
      window.parent.postMessage({ kind: "replay:side-effect", se: { kind: "webhook.send", opts, id } }, "*");
      return id;
    },
  };
  window.email = {
    send(opts) {
      const id = "replay-fake-email-" + (fakeId++);
      sideEffects.push({ kind: "email.send", opts, id });
      window.parent.postMessage({ kind: "replay:side-effect", se: { kind: "email.send", opts, id } }, "*");
      return id;
    },
  };

  // console.log — forward to outer page's UI. (DevTools console
  // already shows them too.)
  const origLog = console.log.bind(console);
  console.log = (...args) => {
    origLog(...args);
    try {
      window.parent.postMessage({ kind: "replay:console", args: args.map(safeStringify) }, "*");
    } catch (e) { /* postMessage can fail on un-cloneable args */ }
  };

  // Ambient request / response globals.
  window.request = META.request;
  window.response = { status: 200, headers: {}, cookies: [] };

  return { state: { tapes, cur, sideEffects } };
}

function safeStringify(v) {
  if (typeof v === "string") return v;
  try { return JSON.stringify(v); } catch (e) { return String(v); }
}

(async () => {
  const tapes = await __tapesReady;
  __state = installStubs(tapes);

  // Build a blob URL for every module and inject an importmap so
  // bare \`loop46-replay/<path>\` specifiers (already in the
  // rewritten source) resolve to the right blob. Importmap MUST be
  // injected before any module loads — that's why we do this in a
  // regular script before the dynamic import below.
  const importmap = { imports: {} };
  for (const m of MODULES) {
    const blob = new Blob([m.source], { type: "application/javascript" });
    importmap.imports["loop46-replay/" + m.path] = URL.createObjectURL(blob);
  }
  const mapScript = document.createElement("script");
  mapScript.type = "importmap";
  mapScript.textContent = JSON.stringify(importmap);
  document.head.appendChild(mapScript);

  let mod;
  try {
    // Pause one step before the handler runs so the user can set
    // breakpoints in any module's Sources panel entry. Module
    // top-level evaluation has already finished by this point —
    // \`mod.default()\` is the actual handler call.
    mod = await import("loop46-replay/" + ENTRY_PATH);
  } catch (err) {
    window.parent.postMessage({ kind: "replay:error", phase: "module-load", message: err.message, stack: err.stack }, "*");
    return;
  }

  if (typeof mod.default !== "function") {
    window.parent.postMessage({ kind: "replay:error", phase: "no-default-export", message: "handler must export default function" }, "*");
    return;
  }

  let result;
  try {
    debugger;
    result = await mod.default();
  } catch (err) {
    window.parent.postMessage({ kind: "replay:error", phase: "handler-throw", message: err.message, stack: err.stack }, "*");
    return;
  }

  // Body shape: see PLAN §2.4 — string emits as-is, undefined/null
  // empty body, object → JSON. We just forward the raw return value;
  // outer page formats it for display.
  window.parent.postMessage({
    kind: "replay:done",
    return_value: result === undefined ? null : result,
    response: { status: window.response.status, headers: window.response.headers, cookies: window.response.cookies },
    side_effects: __state.state.sideEffects,
  }, "*");
})();
</script>
</body></html>`;
  }

  // ── Side-effect log (outer page UI) ────────────────────────────────
  function appendSideEffect(label, body) {
    const li = document.createElement("li");
    const span = document.createElement("span");
    span.className = "se-label";
    span.textContent = label;
    li.appendChild(span);
    const pre = document.createElement("pre");
    pre.textContent = typeof body === "string" ? body : JSON.stringify(body, null, 2);
    li.appendChild(pre);
    $sideEffects.appendChild(li);
  }

  function renderMeta(bundle) {
    const r = bundle.request || {};
    const w = bundle.response || {};
    $meta.innerHTML = "";
    function row(k, v) {
      const dt = document.createElement("dt"); dt.textContent = k;
      const dd = document.createElement("dd"); dd.textContent = v;
      $meta.appendChild(dt);
      $meta.appendChild(dd);
    }
    row("method", r.method || "?");
    row("path", r.path || "?");
    row("host", r.host || "?");
    row("status (original)", String(w.status ?? "?"));
    row("outcome", w.outcome || "?");
    row("deployment", String(bundle.deployment_id ?? "?"));
    if (w.exception) {
      row("exception (original)", w.exception);
    }
  }

  // ── Outer page driver ─────────────────────────────────────────────
  async function main() {
    let bundle;
    try {
      bundle = await awaitBundle();
    } catch (err) {
      setStatus("error: " + err.message, "error");
      return;
    }

    renderMeta(bundle);

    let parsedTapes;
    try {
      parsedTapes = parseTapesFromBundle(bundle);
    } catch (err) {
      setStatus("error parsing tapes: " + err.message, "error");
      return;
    }

    setStatus("running handler in sandboxed iframe — open DevTools to step through", "info");

    // Build + mount the iframe.
    const iframe = document.createElement("iframe");
    iframe.sandbox = "allow-scripts allow-modals";
    iframe.srcdoc = buildIframeSrcdoc(bundle, parsedTapes);
    $iframeMount.innerHTML = "";
    $iframeMount.appendChild(iframe);

    // Forward parsed tapes to the iframe once it's ready. We'd race
    // the iframe's listener registration if we posted before it
    // attached the handler. Easier: poll-post for the first ~500ms
    // until the iframe acknowledges. (Inline-script setup runs
    // synchronously, so this almost always lands on the first try.)
    let ack = false;
    function postTapes() {
      if (ack || !iframe.contentWindow) return;
      iframe.contentWindow.postMessage({ kind: "replay:tapes", tapes: parsedTapes }, "*");
    }
    iframe.addEventListener("load", postTapes);
    setTimeout(postTapes, 50);
    setTimeout(postTapes, 200);

    // Receive results from the iframe.
    window.addEventListener("message", (e) => {
      if (e.source !== iframe.contentWindow) return;
      const m = e.data;
      if (!m || typeof m !== "object") return;
      switch (m.kind) {
        case "replay:tapes-ack": ack = true; break;
        case "replay:console": {
          appendSideEffect("console.log", m.args.join(" "));
          break;
        }
        case "replay:side-effect": {
          appendSideEffect(m.se.kind, m.se.opts);
          break;
        }
        case "replay:done": {
          setStatus("handler completed", "ok");
          appendSideEffect("return value", m.return_value);
          appendSideEffect("response (replayed)", m.response);
          break;
        }
        case "replay:error": {
          setStatus("handler error (" + (m.phase || "?") + "): " + m.message, "error");
          if (m.stack) appendSideEffect("stack", m.stack);
          break;
        }
      }
    });
  }

  main();
})();
