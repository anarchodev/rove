// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// The `_system.*` primitive layer the offline runtimes compose over — ONE
// source shared by the CLI sim (src/replay/sim_globals.zig embeds it into
// the reactor base) and the browser replay arena
// (scripts/ops/gen_replay_prelude.py folds it into arena-prelude.js).
// Neither runtime has the worker's native effect bindings, so the public
// shims in `globals/*.js` bottom out here instead.
//
// `crypto` maps onto the native crypto the replay bindings install
// (getRandomValues/randomBytes/randomUUID/sha256/hmacSha256 are real);
// streaming SHA-256, SHA-512/384 and RSA/ECDSA verify are supplied here in
// pure JS, and the slots that remain unimplemented throw a named error
// rather than returning a wrong answer — a bogus `valid:false` on a good
// token is the worst possible offline failure.
//
// The effect primitives (`http`/`after`/`blob`/`stream`/`platform`) are
// RECORDERS: they never fire, they push `{kind:…}` entries into the
// per-run sink `globalThis.__rove_effects`. Replay re-executes recorded
// inputs, so an effect that already happened live must be observed, not
// repeated. The durable verbs (`webhook`/`email`/`schedule`/`blob`) stay
// the REAL shims on top of these, so they decompose into the primitives
// that actually replicate (`_send/owed` + `_sched/*` kv rows +
// `http.fetch`) exactly as production does.
//
// Prod's synchronous argument validation is mirrored throughout, each
// check naming its Zig source — change one side, change both.
//
// The host must seed the per-run state these recorders read before each
// activation: `__rove_effects`, `__rove_fetch_seq`, `__rove_stream_bytes`,
// `__rove_blob_receive_used`, `__rove_activation_kind`, `__rove_captured`,
// `__rove_email_sends`.

;(function(){
  var nat = globalThis.crypto;
  var no = function(n){ return function(){ throw new Error("crypto." + n + " is not available in `rewind test` (the offline sim has SHA-256/HMAC + random only — no streaming sha, RSA or ECDSA)"); }; };
  // A verify path reached an alg/curve the offline sim doesn't implement.
  // THROW (a loud, declared gap) rather than return a silent `valid:false`
  // — a wrong verdict on a valid token is the worst offline failure (it
  // greens a login-rejection prod would accept). Verify those against a live
  // cluster until the sim grows the alg. Issue #45.
  var __cryptoGap = function(what){ throw new Error("crypto." + what + " is not available in `rewind test` (the offline sim implements RS256 + ES256/P-256 verify + SHA-256/HMAC only) — verify this alg against a live cluster"); };
  var push = function(e){ (globalThis.__rove_effects || (globalThis.__rove_effects = [])).push(e); };
  var b2s = function(c){ if (typeof c === "string") return c; var s = ""; for (var i = 0; i < c.length; i++) s += String.fromCharCode(c[i]); return s; };
  // ── prod's synchronous effect-argument validation, mirrored so a call
  // shape that throws live also throws offline with the same error type and
  // message (customer `catch` branches keyed on them are testable). Each
  // check names its prod source; change one side, change both. ──
  // http_b.isValidExportName (bindings/http.zig): ASCII alnum/_/$, first
  // char non-digit — gates every bound-export override ({on}/name).
  var isExportName = function(s){ return typeof s === "string" && /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(s); };
  // JS_ToInt64-style coercion (after.ms): ToNumber, then NaN/±Infinity → 0,
  // fraction truncated. The ToInt32 sites (randomBytes n, blob.url ttl) use
  // JS's own `| 0` — the exact ECMA ToInt32 incl. the mod-2^32 wrap prod's
  // JS_ToInt32 performs, so out-of-range wrapping accepts/rejects the same
  // values as prod.
  var toInt = function(x){ var n = Number(x); return Number.isFinite(n) ? Math.trunc(n) : 0; };
  // UTF-8 byte length of a string chunk / byte length of a Uint8Array —
  // the wire size prod's caps measure (surrogate pairs 4 bytes, lone 3).
  var u8len = function(s){ if (typeof s !== "string") return s.length; var n = 0; for (var i = 0; i < s.length; i++) { var cp = s.charCodeAt(i); if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < s.length && s.charCodeAt(i + 1) >= 0xDC00 && s.charCodeAt(i + 1) <= 0xDFFF) { n += 4; i++; } else if (cp < 0x80) n += 1; else if (cp < 0x800) n += 2; else n += 3; } return n; };
  // dupeJsStringOrBytes (bindings/http.zig): a fetch body is a string or
  // Uint8Array; absent (undefined) defaults — anything else (incl. null)
  // throws. Shared by http.fetch / after.fetch / http.subscribe.
  var checkFetchBody = function(o){ if (o.body !== undefined && typeof o.body !== "string" && !(o.body instanceof Uint8Array)) throw new TypeError("fetch: `body` must be a string or Uint8Array"); };
  // buildFetchRow (bindings/http.zig) — the shared unbound-fetch option
  // validation jsHttpFetch AND jsHttpSubscribe run: url required, body
  // shape, `name` identifier, `on_chunk` (module path) required. The
  // native reads ONLY `on_chunk` (the public shims lower `on` to it), so
  // no `on` fallback here. Returns the module path.
  var checkFetchOpts = function(o){
    if (typeof o.url !== "string") throw new TypeError("http.fetch requires a `url` string");
    checkFetchBody(o);
    var nm = o.name === undefined ? "" : String(o.name);
    if (nm.length > 0 && !isExportName(nm)) throw new TypeError("http.fetch: `name` must be a JS identifier (alphanumeric/underscore/$, first char non-digit)");
    if (!o.on_chunk) throw new TypeError("http.fetch: `on_chunk` (module path) is required");
    return o.on_chunk;
  };
  // The outbound rate limit (prod's per-tenant OUTBOUND budget) is armed
  // by `scenario({ emailBudget: N })` and enforced in `recFetch` below
  // (the sim's fetch chokepoint), mirroring prod's move off the retired
  // email-specific `__rove_check_email_rate` native onto the fetch
  // primitive. No bare `__rove_*` global remains — the continuation native
  // lives on `_system.continuation` below (next.js captures it at
  // base-eval; the bare `__rove_next` global is gone).
  // Streaming SHA-256 in pure JS (the portable replay engine has one-shot
  // `nat.sha256` only). Same posture as the RSA/ECDSA verify above; drives
  // `crypto.sha256Init/Update/Final` so `blob.write`/`blob.seal` (recipe
  // midstate) work offline. Final(Update*(Init())) === nat.sha256(concat) —
  // string chunks UTF-8-encoded to match nat.sha256's string handling. The
  // midstate token ("js2:" H32hex : totalLen : bufHex) is sim-internal
  // (never crosses to native) — its own format, not the worker's `s2:`.
  var K256 = [0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];
  var H256_0 = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
  var rotr = function(x, n){ return ((x >>> n) | (x << (32 - n))) >>> 0; };
  var shaCompress = function(H, blk){
    var w = new Array(64), i;
    for (i = 0; i < 16; i++) w[i] = ((blk[i*4] << 24) | (blk[i*4+1] << 16) | (blk[i*4+2] << 8) | blk[i*4+3]) >>> 0;
    for (i = 16; i < 64; i++) { var s0 = rotr(w[i-15],7) ^ rotr(w[i-15],18) ^ (w[i-15] >>> 3); var s1 = rotr(w[i-2],17) ^ rotr(w[i-2],19) ^ (w[i-2] >>> 10); w[i] = (((w[i-16] + s0) >>> 0) + ((w[i-7] + s1) >>> 0)) >>> 0; }
    var a=H[0],b=H[1],c=H[2],d=H[3],e=H[4],f=H[5],g=H[6],h=H[7];
    for (i = 0; i < 64; i++) {
      var S1 = rotr(e,6) ^ rotr(e,11) ^ rotr(e,25); var ch = (e & f) ^ ((~e) & g);
      var t1 = (((h + S1) >>> 0) + ((ch + ((K256[i] + w[i]) >>> 0)) >>> 0)) >>> 0;
      var S0 = rotr(a,2) ^ rotr(a,13) ^ rotr(a,22); var maj = (a & b) ^ (a & c) ^ (b & c);
      var t2 = (S0 + maj) >>> 0;
      h=g; g=f; f=e; e=(d + t1) >>> 0; d=c; c=b; b=a; a=(t1 + t2) >>> 0;
    }
    H[0]=(H[0]+a)>>>0; H[1]=(H[1]+b)>>>0; H[2]=(H[2]+c)>>>0; H[3]=(H[3]+d)>>>0; H[4]=(H[4]+e)>>>0; H[5]=(H[5]+f)>>>0; H[6]=(H[6]+g)>>>0; H[7]=(H[7]+h)>>>0;
  };
  var shaStrU8 = function(s){ var out = [], i, cp; for (i = 0; i < s.length; i++) { cp = s.charCodeAt(i); if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < s.length) { var lo = s.charCodeAt(i+1); if (lo >= 0xDC00 && lo <= 0xDFFF) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); i++; } } if (cp < 0x80) out.push(cp); else if (cp < 0x800) out.push(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F)); else if (cp < 0x10000) out.push(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)); else out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)); } return out; };
  var shaBytes = function(d){ if (typeof d === "string") return shaStrU8(d); var out = [], i; for (i = 0; i < d.length; i++) out.push(d[i] & 0xff); return out; };
  var hx8 = function(x){ return ("00000000" + (x >>> 0).toString(16)).slice(-8); };
  var hx2 = function(x){ return ("0" + (x & 0xff).toString(16)).slice(-2); };
  // Emit the WORKER's `s2:` wire format (bindings/crypto.zig midstateToToken):
  // "s2:" + base64url_no_pad( 8×u32 BE state ‖ u64 BE total_len ‖ u8 buf_len
  // ‖ buf ). So a sim-produced midstate round-trips into prod-shaped fixtures.
  // shaParse ALSO decodes it (and keeps reading the legacy "js2:" hex form
  // for old worlds), so a prod-captured world whose kv carries an `s2:` token
  // replays offline (issue #47).
  var shaSer = function(st){ var raw = [], i, w; for (i = 0; i < 8; i++){ w = st.h[i] >>> 0; raw.push((w>>>24)&0xff,(w>>>16)&0xff,(w>>>8)&0xff,w&0xff); } var len = st.len, hi = Math.floor(len/0x100000000), lo = len%0x100000000; raw.push(Math.floor(hi/0x1000000)%256, Math.floor(hi/0x10000)%256, Math.floor(hi/0x100)%256, hi%256, Math.floor(lo/0x1000000)%256, Math.floor(lo/0x10000)%256, Math.floor(lo/0x100)%256, lo%256); raw.push(st.buf.length & 0xff); for (i = 0; i < st.buf.length; i++) raw.push(st.buf[i] & 0xff); return "s2:" + globalThis.base64url.encode(new Uint8Array(raw)); };
  var shaParse = function(tok){ if (typeof tok !== "string") throw new Error("crypto.sha256: invalid midstate token"); var h = [], buf = [], i, len; if (tok.indexOf("s2:") === 0){ var raw = globalThis.base64url.decode(tok.slice(3)); if (raw.length < 41) throw new Error("crypto.sha256: invalid midstate token"); for (i = 0; i < 8; i++) h.push(((raw[i*4]<<24)|(raw[i*4+1]<<16)|(raw[i*4+2]<<8)|raw[i*4+3])>>>0); len = 0; for (i = 32; i < 40; i++) len = len*256 + raw[i]; var bl = raw[40]; for (i = 0; i < bl; i++) buf.push(raw[41+i]); return { h: h, len: len, buf: buf }; } if (tok.indexOf("js2:") === 0){ var p = tok.slice(4).split(":"); var hs = p[0], bh = p[2] || ""; len = Number(p[1]); for (i = 0; i < 8; i++) h.push(parseInt(hs.substr(i*8, 8), 16) >>> 0); for (i = 0; i < bh.length; i += 2) buf.push(parseInt(bh.substr(i, 2), 16)); return { h: h, len: len, buf: buf }; } throw new Error("crypto.sha256: invalid midstate token"); };
  var shaInit = function(){ return shaSer({ h: H256_0.slice(), len: 0, buf: [] }); };
  var shaUpdate = function(tok, data){ var st = shaParse(tok); var bytes = shaBytes(data); var buf = st.buf.concat(bytes); var i = 0; while (buf.length - i >= 64) { shaCompress(st.h, buf.slice(i, i + 64)); i += 64; } st.buf = buf.slice(i); st.len += bytes.length; return shaSer(st); };
  var shaFinal = function(tok){ var st = shaParse(tok); var buf = st.buf.slice(); buf.push(0x80); while (buf.length % 64 !== 56) buf.push(0x00); var bitHi = Math.floor(st.len / 0x20000000), bitLo = (st.len * 8) >>> 0; buf.push((bitHi >>> 24) & 0xff, (bitHi >>> 16) & 0xff, (bitHi >>> 8) & 0xff, bitHi & 0xff, (bitLo >>> 24) & 0xff, (bitLo >>> 16) & 0xff, (bitLo >>> 8) & 0xff, bitLo & 0xff); for (var i = 0; i < buf.length; i += 64) shaCompress(st.h, buf.slice(i, i + 64)); var out = ""; for (i = 0; i < 8; i++) out += hx8(st.h[i]); return out; };
  // SHA-512 / SHA-384 one-shot (BigInt 64-bit words) — the portable engine
  // has native sha256 only. Drives RS384/RS512 verify (and ES384/512 later).
  // Round constants + IVs are FIPS 180-4; the compress loop mirrors sha256's
  // but over 64-bit words with the 512 rotation schedule. `bytes` is a byte
  // array (shaBytes UTF-8-encodes a string, matching nat.sha256).
  var __M64 = (1n << 64n) - 1n;
  var rotr64 = function(x, n){ var b = BigInt(n); return ((x >> b) | (x << (64n - b))) & __M64; };
  var K512 = [0x428a2f98d728ae22n,0x7137449123ef65cdn,0xb5c0fbcfec4d3b2fn,0xe9b5dba58189dbbcn,0x3956c25bf348b538n,0x59f111f1b605d019n,0x923f82a4af194f9bn,0xab1c5ed5da6d8118n,0xd807aa98a3030242n,0x12835b0145706fben,0x243185be4ee4b28cn,0x550c7dc3d5ffb4e2n,0x72be5d74f27b896fn,0x80deb1fe3b1696b1n,0x9bdc06a725c71235n,0xc19bf174cf692694n,0xe49b69c19ef14ad2n,0xefbe4786384f25e3n,0x0fc19dc68b8cd5b5n,0x240ca1cc77ac9c65n,0x2de92c6f592b0275n,0x4a7484aa6ea6e483n,0x5cb0a9dcbd41fbd4n,0x76f988da831153b5n,0x983e5152ee66dfabn,0xa831c66d2db43210n,0xb00327c898fb213fn,0xbf597fc7beef0ee4n,0xc6e00bf33da88fc2n,0xd5a79147930aa725n,0x06ca6351e003826fn,0x142929670a0e6e70n,0x27b70a8546d22ffcn,0x2e1b21385c26c926n,0x4d2c6dfc5ac42aedn,0x53380d139d95b3dfn,0x650a73548baf63den,0x766a0abb3c77b2a8n,0x81c2c92e47edaee6n,0x92722c851482353bn,0xa2bfe8a14cf10364n,0xa81a664bbc423001n,0xc24b8b70d0f89791n,0xc76c51a30654be30n,0xd192e819d6ef5218n,0xd69906245565a910n,0xf40e35855771202an,0x106aa07032bbd1b8n,0x19a4c116b8d2d0c8n,0x1e376c085141ab53n,0x2748774cdf8eeb99n,0x34b0bcb5e19b48a8n,0x391c0cb3c5c95a63n,0x4ed8aa4ae3418acbn,0x5b9cca4f7763e373n,0x682e6ff3d6b2b8a3n,0x748f82ee5defb2fcn,0x78a5636f43172f60n,0x84c87814a1f0ab72n,0x8cc702081a6439ecn,0x90befffa23631e28n,0xa4506cebde82bde9n,0xbef9a3f7b2c67915n,0xc67178f2e372532bn,0xca273eceea26619cn,0xd186b8c721c0c207n,0xeada7dd6cde0eb1en,0xf57d4f7fee6ed178n,0x06f067aa72176fban,0x0a637dc5a2c898a6n,0x113f9804bef90daen,0x1b710b35131c471bn,0x28db77f523047d84n,0x32caab7b40c72493n,0x3c9ebe0a15c9bebcn,0x431d67c49c100d4cn,0x4cc5d4becb3e42b6n,0x597f299cfc657e2an,0x5fcb6fab3ad6faecn,0x6c44198c4a475817n];
  var H512_0 = [0x6a09e667f3bcc908n,0xbb67ae8584caa73bn,0x3c6ef372fe94f82bn,0xa54ff53a5f1d36f1n,0x510e527fade682d1n,0x9b05688c2b3e6c1fn,0x1f83d9abfb41bd6bn,0x5be0cd19137e2179n];
  var H384_0 = [0xcbbb9d5dc1059ed8n,0x629a292a367cd507n,0x9159015a3070dd17n,0x152fecd8f70e5939n,0x67332667ffc00b31n,0x8eb44a8768581511n,0xdb0c2e0d64f98fa7n,0x47b5481dbefa4fa4n];
  var __sim_sha512 = function(bytes, is384){ var H = (is384 ? H384_0 : H512_0).slice(); var msg = bytes.slice(); var bitLen = BigInt(bytes.length) * 8n; msg.push(0x80); while (msg.length % 128 !== 112) msg.push(0); for (var i = 15; i >= 0; i--) msg.push(Number((bitLen >> BigInt(i*8)) & 0xffn)); for (var off = 0; off < msg.length; off += 128){ var w = new Array(80), t, x, j; for (t = 0; t < 16; t++){ x = 0n; for (j = 0; j < 8; j++) x = (x << 8n) | BigInt(msg[off+t*8+j]); w[t] = x; } for (t = 16; t < 80; t++){ var s0 = rotr64(w[t-15],1) ^ rotr64(w[t-15],8) ^ (w[t-15] >> 7n); var s1 = rotr64(w[t-2],19) ^ rotr64(w[t-2],61) ^ (w[t-2] >> 6n); w[t] = (w[t-16] + s0 + w[t-7] + s1) & __M64; } var a=H[0],b=H[1],c=H[2],d=H[3],e=H[4],f=H[5],g=H[6],h=H[7]; for (t = 0; t < 80; t++){ var S1 = rotr64(e,14) ^ rotr64(e,18) ^ rotr64(e,41); var ch = (e & f) ^ ((~e & __M64) & g); var t1 = (h + S1 + ch + K512[t] + w[t]) & __M64; var S0 = rotr64(a,28) ^ rotr64(a,34) ^ rotr64(a,39); var maj = (a & b) ^ (a & c) ^ (b & c); var t2 = (S0 + maj) & __M64; h=g; g=f; f=e; e=(d+t1)&__M64; d=c; c=b; b=a; a=(t1+t2)&__M64; } H[0]=(H[0]+a)&__M64; H[1]=(H[1]+b)&__M64; H[2]=(H[2]+c)&__M64; H[3]=(H[3]+d)&__M64; H[4]=(H[4]+e)&__M64; H[5]=(H[5]+f)&__M64; H[6]=(H[6]+g)&__M64; H[7]=(H[7]+h)&__M64; } var nwords = is384 ? 6 : 8, out = []; for (i = 0; i < nwords; i++) for (j = 7; j >= 0; j--) out.push(Number((H[i] >> BigInt(j*8)) & 0xffn)); return out; };
  var __bytesBig = function(b){ var x = 0n; for (var i = 0; i < b.length; i++) x = (x << 8n) | BigInt(b[i]); return x; };
  // RS256/384/512 verify (RSASSA-PKCS1-v1.5) in pure JS over BigInt — the
  // common OIDC algs. Portable (no OpenSSL). ECDSA below.
  var __sim_verifyRsa = function(jwk, alg, data, sig){
    var a = (alg || "sha256").toLowerCase();
    if (a !== "sha256" && a !== "sha384" && a !== "sha512") __cryptoGap("verifyRsa(" + a + ")");
    try {
      if (!jwk || jwk.kty !== "RSA") return false;
      var b64u = globalThis.base64url;
      var toBig = function(b){ var x = 0n; for (var i = 0; i < b.length; i++) x = (x << 8n) | BigInt(b[i]); return x; };
      var n = toBig(b64u.decode(jwk.n)), e = toBig(b64u.decode(jwk.e));
      var sb = (typeof sig === "string") ? b64u.decode(sig) : sig;
      var s = toBig(sb);
      if (s >= n) return false;
      var r = 1n, base = s % n, ee = e;
      while (ee > 0n){ if (ee & 1n) r = (r * base) % n; ee >>= 1n; base = (base * base) % n; }
      var klen = 0, nn = n; while (nn > 0n){ nn >>= 8n; klen++; }
      var em = new Uint8Array(klen), mm = r;
      for (var i2 = klen - 1; i2 >= 0; i2--){ em[i2] = Number(mm & 0xffn); mm >>= 8n; }
      if (em[0] !== 0x00 || em[1] !== 0x01) return false;
      var p = 2; while (p < em.length && em[p] === 0xff) p++;
      if (em[p] !== 0x00) return false; p++;
      // DigestInfo: the PKCS#1-v1.5 ASN.1 prefix + the digest, per alg
      // (RFC 8017). sha384/512 hash via the pure-JS __sim_sha512.
      var hash, PFX;
      if (a === "sha384") { hash = __sim_sha512(shaBytes(data), true); PFX = [0x30,0x41,0x30,0x0d,0x06,0x09,0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x02,0x02,0x05,0x00,0x04,0x30]; }
      else if (a === "sha512") { hash = __sim_sha512(shaBytes(data), false); PFX = [0x30,0x51,0x30,0x0d,0x06,0x09,0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x02,0x03,0x05,0x00,0x04,0x40]; }
      else { var hex = nat.sha256(data); hash = []; for (var j = 0; j < 32; j++) hash.push(parseInt(hex.substr(j*2, 2), 16)); PFX = [0x30,0x31,0x30,0x0d,0x06,0x09,0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x02,0x01,0x05,0x00,0x04,0x20]; }
      if (em.length - p !== PFX.length + hash.length) return false;
      for (var k = 0; k < PFX.length; k++) if (em[p + k] !== PFX[k]) return false;
      for (var k2 = 0; k2 < hash.length; k2++) if (em[p + PFX.length + k2] !== hash[k2]) return false;
      return true;
    } catch (_) { return false; }
  };
  // ES256/384/512 verify (ECDSA P-256/P-384/P-521 + SHA-256/384/512) in pure
  // JS over BigInt. Point math uses Jacobian coordinates (a = -3, shared by
  // every NIST P-curve) so the whole verify costs ONE modular inverse at the
  // end. Accepts JWS raw r||s (2·flen bytes) or DER. The digest is chosen by
  // `alg`, the curve by the jwk's `crv`.
  var __sim_verifyEcdsa = function(jwk, alg, data, sig){
    var a = (alg || "sha256").toLowerCase();
    var crv = jwk && jwk.crv;
    // Digest → e, by alg. sha384/512 via the pure-JS __sim_sha512.
    var digestE;
    if (a === "sha256") digestE = function(){ return BigInt("0x" + nat.sha256(data)); };
    else if (a === "sha384") digestE = function(){ return __bytesBig(__sim_sha512(shaBytes(data), true)); };
    else if (a === "sha512") digestE = function(){ return __bytesBig(__sim_sha512(shaBytes(data), false)); };
    else __cryptoGap("verifyEcdsa(" + a + ")");
    // Curve params, by crv (a = p-3 for all). flen = field byte length (the
    // raw r||s half-width). Unknown curve → loud gap.
    var C;
    if (crv === "P-256") C = { p: 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffffn, n: 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n, Gx: 0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296n, Gy: 0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5n, flen: 32 };
    else if (crv === "P-384") C = { p: 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffffn, n: 0xffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973n, Gx: 0xaa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7n, Gy: 0x3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5fn, flen: 48 };
    else if (crv === "P-521") C = { p: 0x1ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffn, n: 0x1fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa51868783bf2f966b7fcc0148f709a5d03bb5c9b8899c47aebb6fb71e91386409n, Gx: 0xc6858e06b70404e9cd9e3ecb662395b4429c648139053fb521f828af606b4d3dbaa14b5e77efe75928fe1dc127a2ffa8de3348b3c1856a429bf97e7e31c2e5bd66n, Gy: 0x11839296a789a3bc0045c8a5fb42c7d1bd998f54449579b446817afbd17273e662c97ee72995ef42640c550b9013fad0761353c7086a272c24088be94769fd16650n, flen: 66 };
    else __cryptoGap("verifyEcdsa(crv=" + String(crv) + ")");
    try {
      if (!jwk || jwk.kty !== "EC") return false;
      var b64u = globalThis.base64url;
      var toBig = __bytesBig;
      var p = C.p, n = C.n, Gx = C.Gx, Gy = C.Gy, flen = C.flen;
      var acurve = p - 3n;
      var mod = function(x, m){ x %= m; return x < 0n ? x + m : x; };
      var inv = function(x, m){ var r = 1n, b = mod(x, m), e = m - 2n; while (e > 0n){ if (e & 1n) r = (r * b) % m; e >>= 1n; b = (b * b) % m; } return r; };
      // Jacobian point [X, Y, Z]; Z === 0n is the point at infinity.
      var jdbl = function(P){
        if (P[2] === 0n || P[1] === 0n) return [0n, 0n, 0n];
        var YY = (P[1] * P[1]) % p; var S = mod(4n * P[0] * YY, p); var ZZ = (P[2] * P[2]) % p;
        var M = mod(3n * P[0] * P[0] + acurve * ZZ % p * ZZ, p);
        var X3 = mod(M * M - 2n * S, p);
        return [X3, mod(M * (S - X3) - 8n * YY % p * YY, p), mod(2n * P[1] * P[2], p)];
      };
      var jadd = function(P, Q){
        if (P[2] === 0n) return Q; if (Q[2] === 0n) return P;
        var Z1Z1 = (P[2] * P[2]) % p, Z2Z2 = (Q[2] * Q[2]) % p;
        var U1 = mod(P[0] * Z2Z2, p), U2 = mod(Q[0] * Z1Z1, p);
        var S1 = mod(P[1] * Q[2] % p * Z2Z2, p), S2 = mod(Q[1] * P[2] % p * Z1Z1, p);
        if (U1 === U2){ if (S1 !== S2) return [0n, 0n, 0n]; return jdbl(P); }
        var H = mod(U2 - U1, p); var I = mod(2n * H % p * (2n * H), p); var J = mod(H * I, p);
        var rr = mod(2n * (S2 - S1), p); var V = mod(U1 * I, p);
        var X3 = mod(rr * rr - J - 2n * V, p);
        var ZS = mod(P[2] + Q[2], p);
        return [X3, mod(rr * (V - X3) - 2n * S1 % p * J, p), mod((ZS * ZS % p - Z1Z1 - Z2Z2) * H, p)];
      };
      var jmul = function(k, P){ var R = [0n, 0n, 0n]; k = mod(k, n); while (k > 0n){ if (k & 1n) R = jadd(R, P); P = jdbl(P); k >>= 1n; } return R; };
      var Q = [toBig(b64u.decode(jwk.x)), toBig(b64u.decode(jwk.y)), 1n];
      var sb = (typeof sig === "string") ? b64u.decode(sig) : sig;
      var r, s;
      if (sb.length === 2 * flen){ r = toBig(sb.slice(0, flen)); s = toBig(sb.slice(flen, 2 * flen)); }
      else if (sb[0] === 0x30){ var i = 2; if (sb[1] & 0x80) i = 2 + (sb[1] & 0x7f); var rl = sb[i + 1]; r = toBig(sb.slice(i + 2, i + 2 + rl)); i = i + 2 + rl; var sl = sb[i + 1]; s = toBig(sb.slice(i + 2, i + 2 + sl)); }
      else return false;
      if (r <= 0n || r >= n || s <= 0n || s >= n) return false;
      var e = digestE();
      var w = inv(s, n);
      var R = jadd(jmul(mod(e * w, n), [Gx, Gy, 1n]), jmul(mod(r * w, n), Q));
      if (R[2] === 0n) return false;
      var zi = inv(R[2], p);
      return mod(mod(R[0] * zi % p * zi, p), n) === r;
    } catch (_) { return false; }
  };
  // Offline OIDC provider signing (issue #46). Real RSA keygen is slow +
  // complex offline, so oidcGenerateKey returns a FIXED deterministic 2048-bit
  // dev key — the determinism contract is same run → same signatures
  // (replay-exact). The kid derives from the key so it's stable; a
  // keyset/rotation flow reuses this material (realistic enough for
  // provider-mode round-trip tests offline). `priv` is a sim-internal JSON
  // blob {n,d} — oidcGenerateKey/oidcSign are the only producer/consumer.
  var __OIDC_N = "sk2buuLi4Pv9BoOsn8-0m6TBjKbIDpa54s2JKccxMROnshPPL65yjeV9w7kkeRsXMslRfqwzR4KuOHjoPhhZUje5rmEEiZ5ewP-DB2nES3MLYN5nyA6Cr4-VriOyRQaYYFjWox8N-_d0z_DEEicwJud0sgQPNQltgeglNP4a64TbEZD4E20VnP6LjUXIqfG5_qSeIf9-VZoVFg08tH8K56gQwU9w4dPysMj_jySPev7oTqS7pbrM_J663f9x43ZQRn1cMjXQWCfJp9F6k-Eu4ov0iSu8_gIJWGQA46Sc8nVopsqnTPDu3e9YgU4BddaEBs8ybtKJkYkqSQ840Uj23w";
  var __OIDC_E = "AQAB";
  var __OIDC_D = "GVAbQ7TiML6VdU9MOoPqSA5jy-wBitCrIx-60UuOGEGKFSXqzAIgETT7XcXy_55w9KzP_QPFY-mRgkLn9ajPRXTTz4XGdyMcoJmlqG_DhlKW0vHAGg61Tuc7gLVgoZwGFeeG0TGfcp32325253zYwS0qy_r3jbgA6-hhH9zTRYwiRBPZ9ZhHVLyzMbTEEUmENqnNGgmY4vA3jUH0GW0Npaf2g8eQglfViniOo8t3DIMCA8faED3I_nTvThShBEy0Hfz5vPcWR9TvzHvM_5pK1gTslbpIvDaGaRjMzA2PGU3k-4FiFGK1SNGT5tSkRO4CfonydW_I9xNGD3wmYXyTwQ";
  var __OIDC_KID = "sim-rsa-" + nat.sha256(__OIDC_N).slice(0, 16);
  var __oidcGenerateKey = function(){ return { priv: JSON.stringify({ n: __OIDC_N, d: __OIDC_D }), jwk: { kty: "RSA", n: __OIDC_N, e: __OIDC_E, kid: __OIDC_KID, use: "sig", alg: "RS256" }, kid: __OIDC_KID }; };
  // RSASSA-PKCS1-v1.5 sign (RS256) over BigInt: EM = 00 01 FF..FF 00 ‖
  // DigestInfo(SHA-256(signingInput)); sig = EM^d mod n; return base64url.
  var __oidcSign = function(priv, signingInput){ var pk = (typeof priv === "string" && priv.charAt(0) === "{") ? JSON.parse(priv) : null; if (!pk || !pk.n || !pk.d) throw new Error("crypto.oidcSign: private key not from crypto.oidcGenerateKey (the offline sim uses its own key format)"); var b64u = globalThis.base64url; var n = __bytesBig(b64u.decode(pk.n)), d = __bytesBig(b64u.decode(pk.d)); var klen = 0, nn = n; while (nn > 0n){ nn >>= 8n; klen++; } var hex = nat.sha256(signingInput); var T = [0x30,0x31,0x30,0x0d,0x06,0x09,0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x02,0x01,0x05,0x00,0x04,0x20]; for (var i = 0; i < 32; i++) T.push(parseInt(hex.substr(i*2,2),16)); var em = [0x00, 0x01]; var padLen = klen - 3 - T.length; for (i = 0; i < padLen; i++) em.push(0xff); em.push(0x00); for (i = 0; i < T.length; i++) em.push(T[i]); var m = __bytesBig(em); var r = 1n, base = m % n, ee = d; while (ee > 0n){ if (ee & 1n) r = (r * base) % n; ee >>= 1n; base = (base * base) % n; } var sig = new Uint8Array(klen), mm = r; for (i = klen - 1; i >= 0; i--){ sig[i] = Number(mm & 0xffn); mm >>= 8n; } return b64u.encode(sig); };
  // Per-instance / root kv isolation for `platform.*`. Each store namespaces
  // its keys under `__rove_store/{tag}/` in the one closed-world map, so a
  // scoped or root write never collides with the tenant's own kv (or another
  // instance's). The facade pushes CLEAN store-tagged effect entries; the
  // epilogue kv wrapper skips recording and hides the namespaced keys, so a
  // tenant read / prefix scan never sees another store.
  var NS_STORE = "__rove_store/";
  // Published so every consumer tests the SAME prefix. This namespace is a
  // harness construct: it exists nowhere in the worker, so a key under it is
  // bookkeeping no production run ever performed. Anything that records what a
  // handler did — the sim epilogue's kv wrapper, the browser arena's — has to
  // exclude it, or it reports reads and writes the worker never made and folds
  // them into the interaction digest.
  //
  // One definition rather than one per engine: the sim excluded these from the
  // start and the browser arena did not, which is exactly the drift a repeated
  // string literal invites (rove#442).
  globalThis.__roveStorePrefix = NS_STORE;
  var storeKv = function(P, tag){
    return {
      // `value` is load-bearing, not decoration: the digest folds
      // `r <key> <found> <valuehash>`, so an entry without it hashes the
      // empty string and every cross-store read of a DIFFERENT value
      // digests alike. The ordinary kv wrapper carries it; this one did
      // not, which is what made an admin replay disagree with capture
      // while the store's prefix scan agreed (rove#487).
      get: function(k){ var v = globalThis.kv.get(P + k); var present = v !== undefined && v !== null; push(present ? { kind: "read", store: tag, key: k, present: true, value: v } : { kind: "read", store: tag, key: k, present: false }); return v; },
      set: function(k, val){ push({ kind: "write", store: tag, key: k, value: val }); return globalThis.kv.set(P + k, val); },
      delete: function(k){ push({ kind: "delete", store: tag, key: k }); return globalThis.kv.delete(P + k); },
      // The digest folds a cross-store prefix as `p <namespaced> <found>
      // <count> <rowsfold>` (interaction_digest.zig kvPrefix), where the
      // rows-fold is `key=<valuehash>;` per returned row IN ORDER, over the
      // NAMESPACED keys — see globals_platform.zig's accumulator. Compute it
      // here, because only the recorder sees the rows; the fold downstream
      // gets a scalar. Folding 0/0 instead (what this used to push) makes
      // every prefix scan digest alike, which is a false AGREEMENT, not
      // merely a mismatch.
      prefix: function(p, cursor, limit){
        var r = globalThis.kv.prefix(P + (p || ""), cursor, limit) || [];
        var acc = "";
        for (var i = 0; i < r.length; i++) acc += r[i].key + "=" + globalThis.__interactionDigest.foldValue(r[i].value) + ";";
        push({ kind: "read", op: "prefix", store: tag, key: (p || ""), count: r.length,
               rowsFold: globalThis.__interactionDigest.foldValue(acc) });
        return r.map(function(e){ return { key: e.key.slice(P.length), value: e.value }; });
      },
    };
  };
  // platform.* is admin-only (prod: throws off the `__admin__` handler). Fail
  // closed for AUTHORED worlds — every sync method is gated unless the run opts
  // in (`scenario({ admin: true })` → the hidden `__rove_store/admin` key). Note
  // `platform.compile` is NOT gated here: it lowers to a bound fetch (via the
  // real platform.js over `_system.after`), admin-checked door-side in prod.
  //
  // A CAPTURED world skips the gate for the same reason it skips `scope`'s
  // resolve check below: the recording is proof the call was admitted live.
  // Fail-closed is a harness affordance for worlds an author wrote, not a
  // security boundary — the real gate is `state.platform` in the worker — and
  // applying it to a capture turned every admin replay into a spurious
  // "platform is only available on the admin handler" (docs/architecture/
  // replay-and-sim.md, the privileged-surface section).
  var GATE_MSG = "platform is only available on the admin handler";
  var gate = function(fn){ return function(){ if (!globalThis.__rove_captured && globalThis.kv.get(NS_STORE + "admin") !== "1") throw new TypeError(GATE_MSG); return fn.apply(null, arguments); }; };
  var rootStore_r = storeKv(NS_STORE + "r/", "r");
  // Fetch/subscribe recorder. Ids are unique per run (`ftch_<seq>` — the
  // epilogue resets the counter each activation), NOT prod's ftch_<64hex>:
  // determinism over realism, but distinct so a handler can correlate the
  // returned id with the `request.fetchId` its resume observes.
  // The effect entry carries the FULL option bag prod reads
  // (http.zig buildFetchRow), defaults applied, in the PUBLIC spellings
  // (timeoutMs/maxChunkBytes/maxTotalBytes — this recorder sits under the
  // after.js/http.js shims, which already lowered them to the native
  // snake_case, so translate back) — so `toHaveSent("fetch", { headers,
  // stream, timeoutMs, … })` matches what the handler wrote and `.not.`
  // variants aren't vacuous.
  var nextSeq = function(){ return (globalThis.__rove_fetch_seq = (globalThis.__rove_fetch_seq || 0) + 1); };
  // `bound` distinguishes the connection-scoped `after.fetch` (binds to the
  // held socket or is DROPPED at the success seam — http.zig jsOnFetch)
  // from the unbound `http.fetch` primitive (fires regardless — what
  // webhook.send/blob compose on). The epilogue's drop-tagging pass and the
  // harness's fetchesPending count both key on it.
  var recFetch = function(url, o, on, bound){
    // Outbound rate limit — prod enforces a per-tenant OUTBOUND budget at
    // the fetch primitive (bindings/http.zig `outboundRateOk`): every
    // customer-initiated egress (on.fetch / http.fetch / the immediate
    // fire of webhook.send / email.send) shares one bucket. Offline the
    // bucket is UNMETERED by default; `scenario({ emailBudget: N })` arms
    // a per-activation allowance (hidden reserved kv key) so the N+1-th
    // outbound in a run throws prod's exact Error{code:"rate_limited"} and
    // the customer's `catch (e){ e.code === "rate_limited" }` branch is
    // testable. Enforced HERE (the shared recorder = the sim's fetch
    // chokepoint) so a rejected send throws before its durable _send/owed
    // marker is recorded — mirroring prod's fetch-before-marker order. The
    // epilogue resets the per-activation counter.
    // Platform-internal doors (`*.internal` — blob/compose/platform/logs
    // storage + control-plane I/O) are exempt, matching prod's
    // `targetsInternalDoor` (bindings/http.zig) — they aren't third-party
    // egress.
    var __isInternal = (function(u){ var s = String(u || "").indexOf("://"); if (s < 0) return false; var a = String(u).slice(s + 3); var h = a.split(/[\/:?#]/)[0]; return h.slice(-9) === ".internal"; })(url);
    var __ob = __isInternal ? null : globalThis.kv.get("__rove_store/email_budget");
    if (__ob !== undefined && __ob !== null) {
      var __n = Number(__ob);
      if (Number.isFinite(__n)) {
        var __used = globalThis.__rove_email_sends || 0;
        if (__used >= __n) { var __e = new Error("outbound rate limit exceeded, retry after 1s"); __e.code = "rate_limited"; throw __e; }
        globalThis.__rove_email_sends = __used + 1;
      }
    }
    var id = "ftch_" + nextSeq();
    push({ kind: "fetch", id: id, url: url, bound: !!bound, method: (o && o.method) || "GET",
      body: (o && o.body !== undefined) ? o.body : null,
      headers: (o && o.headers) || {},
      ctx: (o && o.ctx !== undefined) ? o.ctx : null,
      on: on || null,
      stream: !!(o && o.stream),
      timeoutMs: (o && o.timeout_ms != null) ? o.timeout_ms : 30000,
      maxChunkBytes: (o && o.max_response_chunk_bytes != null) ? o.max_response_chunk_bytes : 262144,
      maxTotalBytes: (o && o.max_total_response_bytes != null) ? o.max_total_response_bytes : 52428800 });
    return id;
  };
  // Record-format versions for the shim-owned `_`-namespaces
  // (docs/architecture/format-versioning.md §1f). The worker installs these
  // natively from `RecordVersions` in src/js/globals.zig; the offline
  // runtimes have no native bindings, so the same numbers are declared here.
  //
  // These two declarations are pinned to each other by
  // `test "record versions agree with the offline recorders"` in globals.zig,
  // which parses THIS file. Change one side and that test fails — which is
  // the point, because the shims and baked modules that read this write
  // records the worker later has to read.
  globalThis.__rove = globalThis.__rove || {};
  globalThis.__rove.formats = {
    unstamped: 1,
    sched: 1,
    sendOwed: 1,
    blobOwed: 1,
    dispatchOwed: 1,
    segIdx: 1,
    exportRec: 1,
  };

  // ── held-promise cells (src/js/held.zig parity) ──
  // A bare same-connection arm (`after.ms/kv`, a non-streamed bare
  // `after.fetch`, a `request.messages` pull) on a HOLDABLE activation
  // returns a promise the settle hop resolves — the promise flow. The
  // resolver rides the cell (request-arena memory, like the worker's
  // Zig-side HostPromise list); `__rove_held_promises` is non-null only
  // when the driver declared the activation holdable, so on every other
  // run these return undefined exactly as the worker's bindings do when
  // `state.host_promises` is null. `id` is the STABLE settle address
  // ("p<n>", creation order across the whole chain — the sim keeps one
  // growing table where the worker replaces its per-activation list, so
  // a chain's settle CHOICE stays unambiguous).
  var heldProm = function(cell){
    var hp = globalThis.__rove_held_promises;
    if (!hp) return undefined;
    cell.settled = false;
    var p = new Promise(function(res, rej){ cell._resolve = res; cell._reject = rej; });
    cell.id = "p" + hp.length;
    // The per-hop address (the worker's per-activation promise_idx): which
    // hop created this cell, and its index among that hop's creations —
    // heldProm is the single creation point, so the counter mirrors the
    // worker's combined resolver list exactly.
    cell.act = globalThis.__rove_hop_n || 0;
    cell.actIdx = globalThis.__rove_hop_created || 0;
    globalThis.__rove_hop_created = (globalThis.__rove_hop_created || 0) + 1;
    hp.push(cell);
    return p;
  };
  globalThis._system = {
    // The park/continue native (`next.js` captures this at base-eval).
    // Mirrors the worker's disposition: target "" = same-module;
    // non-empty = cross-module re-entry — the worker parks the target
    // as the continuation's path and dispatches every later resume on
    // the held chain there, so the epilogue surfaces it on the bundle
    // (`target`) and the harness resume folds re-enter it
    // (`heldEntry`). `fn` is the native's optional named-export
    // override (`next(path, { fn?, ctx? })`), carried for the same
    // reason.
    continuation: {
      next: function(target, o){ return { __rove_disposition: "next", target: (target ? target : null), fn: (o && typeof o.fn === "string") ? o.fn : null, ctx: (o && o.ctx !== undefined) ? o.ctx : null }; },
    },
    // The held-request input pull (on.zig jsHeldNextInput parity): one
    // pending pull at a time; rejects loudly on an activation that
    // cannot be held. The settle hop resolves it with the iterator
    // result ({value:{opcode,bytes,text},done:false} or {done:true}).
    held: {
      nextInput: function(){
        var hp = globalThis.__rove_held_promises;
        if (!hp) return Promise.reject(new Error("request input cannot be awaited on this activation"));
        if (globalThis.__rove_input_pulled != null) return Promise.reject(new Error("request input is already being awaited (one pull at a time)"));
        var p = heldProm({ kind: "input" });
        globalThis.__rove_input_pulled = "p" + (hp.length - 1);
        return p;
      },
      // One chunk pull on a headers-settled streamed fetch (rove#930) —
      // the worker's jsHeldNextFetchChunk rule: one outstanding pull.
      nextFetchChunk: function(fid){
        var hp = globalThis.__rove_held_promises;
        if (!hp) return Promise.reject(new Error("fetch chunks cannot be awaited on this activation"));
        if (globalThis.__rove_fetch_pull != null) return Promise.reject(new Error("a fetch chunk is already being awaited (one pull at a time)"));
        var p = heldProm({ kind: "fetch_chunk", fetchId: String(fid) });
        globalThis.__rove_fetch_pull = "p" + (hp.length - 1);
        return p;
      },
    },
    crypto: {
      getRandomValues: function(a){ return nat.getRandomValues(a); },
      // jsCryptoRandomBytes (bindings/crypto.zig): ToInt32(n) ∈ [0, 65536].
      randomBytes: function(n){ var v = Number(n) | 0; if (v < 0 || v > 65536) throw new RangeError("crypto.randomBytes: n must be in [0, 65536]"); return nat.randomBytes(v); },
      randomUUID: function(){ return nat.randomUUID(); },
      sha256: function(d){ return nat.sha256(d); },
      hmacSha256: function(k,d){ return nat.hmacSha256(k,d); },
      sha256Init: function(){ return shaInit(); },
      sha256Update: function(t,d){ return shaUpdate(t,d); },
      sha256Final: function(t){ return shaFinal(t); },
      verifyRsa: function(jwk, alg, data, sig){ return __sim_verifyRsa(jwk, alg, data, sig); },
      verifyEcdsa: function(jwk, alg, data, sig){ return __sim_verifyEcdsa(jwk, alg, data, sig); },
      ecdsaGenerateKey: no("ecdsaGenerateKey"), ecdsaSign: no("ecdsaSign"), ecdsaVerify: no("ecdsaVerify"),
      oidcGenerateKey: function(){ return __oidcGenerateKey(); }, oidcSign: function(priv, si){ return __oidcSign(priv, si); },
    },
    http: {
      // Validation mirrors jsHttpFetch → buildFetchRow (bindings/http.zig).
      fetch: function(o){
        if (o === null || o === undefined || typeof o !== "object") throw new TypeError("http.fetch requires an options object");
        return recFetch(o.url, o, checkFetchOpts(o), false);
      },
      cancelFetch: function(){},
      // jsHttpSubscribe reuses buildFetchRow, so the inner throws keep the
      // http.fetch spelling — matched verbatim.
      subscribe: function(o){
        if (o === null || o === undefined || typeof o !== "object") throw new TypeError("http.subscribe requires an options object");
        var oc = checkFetchOpts(o);
        // A held subscription reuses buildFetchRow (http.zig jsHttpSubscribe),
        // so record the FULL option bag prod reads — minus timeout_ms/stream
        // (held transfers always stream and never time out). Public spellings,
        // like recFetch, so `toHaveSent("subscribe", { headers, maxChunkBytes,
        // … })` matches and `.not.` isn't vacuous.
        var id = "sub_" + nextSeq();
        push({ kind: "subscribe", id: id, url: o.url, method: (o && o.method) || "GET",
          body: (o && o.body !== undefined) ? o.body : null,
          headers: (o && o.headers) || {},
          ctx: (o && o.ctx !== undefined) ? o.ctx : null,
          on: oc,
          maxChunkBytes: (o && o.max_response_chunk_bytes != null) ? o.max_response_chunk_bytes : 262144,
          maxTotalBytes: (o && o.max_total_response_bytes != null) ? o.max_total_response_bytes : 52428800 });
        return id;
      },
      cancelSubscription: function(){},
    },
    after: {
      // `on` is the ONE spelling end to end — the after.js shim passes the
      // opts bag through and the worker bindings read `opts.on` the same way.
      // Validation mirrors jsOnFetch/buildOnFetchRow: url string required;
      // the bound `{on}` must be a bare identifier (a `/` or `.` module
      // path is rejected at issue time — cross-module continuations are
      // webhook.send's `on`, not a bound fetch's).
      fetch: function(url, o){
        if (typeof url !== "string") throw new TypeError("after.fetch(url, opts?) requires a url string");
        o = o || {};
        checkFetchBody(o);
        var onv = o.on === undefined ? "" : String(o.on);
        if (onv.length > 0 && !isExportName(onv)) throw new TypeError("after.fetch: `on` must be a JS identifier (alphanumeric/underscore/$, first char non-digit)");
        var id = recFetch(url, o, o.on || null, true);
        // Promise form (http.zig jsOnFetch parity): a bare NON-STREAMED
        // after.fetch resolves once with the whole buffered response;
        // `{on}` keeps the export flow and so does stream:true. The
        // fetch id rides the promise as `.fetchId`.
        if (!(o && o.on) && !(o && o.stream)) {
          var p = heldProm({ kind: "fetch", fetchId: id, url: url });
          if (p !== undefined) {
            p.fetchId = id;
            // The shim's collector cap (http.zig stamps the same).
            p.capBytes = (o && o.max_response_chunk_bytes != null) ? o.max_response_chunk_bytes : 262144;
            return p;
          }
        }
        return id;
      },
      // jsOnKv: string prefix required. jsOnTimer: ToInt64(ms) must be > 0
      // (so undefined/NaN/0/negative/fractional-below-1 all throw) — with
      // JS_ToInt64's mod-2^64 wrap, so an overflowing delay (≥ 2^63 wraps
      // negative) throws here exactly as live.
      kv: function(prefix, o){ if (typeof prefix !== "string") throw new TypeError("after.kv(prefix, opts?) requires a string prefix"); push({ kind: "kv-wake", prefix: prefix, on: (o && o.on) || null }); if (!(o && o.on)) return heldProm({ kind: "kv", prefix: prefix }); },
      timer: function(ms, o){ ms = Number(BigInt.asIntN(64, BigInt(toInt(ms)))); if (ms <= 0) throw new TypeError("after.ms(ms): ms must be > 0"); push({ kind: "timer", ms: ms, on: (o && o.on) || null }); if (!(o && o.on)) return heldProm({ kind: "timer", ms: ms }); },
    },
    blob: {
      // jsBlobPresign (bindings/blob.zig): hash = 64 lowercase hex; a
      // present ttl must land in 1..604800 after ToInt32; pool (arg 4) is a
      // closed set; target (arg 5, the `platform.scope(t).blob` shims) is
      // admin-only — the sim mirrors the throw, keyed on the same platform
      // grant the scope object itself uses.
      presign: function(hash, ttl, ct, pool, target){
        if (typeof hash !== "string") throw new TypeError("blob.url requires a hash string");
        if (!/^[0-9a-f]{64}$/.test(hash)) throw new TypeError("blob.url: hash must be 64 lowercase hex chars");
        if (ttl !== undefined && ttl !== null) { var t = Number(ttl) | 0; if (t < 1 || t > 604800) throw new TypeError("blob.url: ttl must be 1..604800 seconds"); }
        var subdir = "app-blobs";
        if (pool !== undefined && pool !== null && typeof pool === "string") {
          if (pool === "exports" || pool === "file-blobs") subdir = pool;
          else if (pool !== "app-blobs") throw new TypeError("blob presign: unknown pool");
        }
        if (target !== undefined && target !== null && typeof target === "string") {
          // Same admin predicate as the platform.* gate above: authored
          // worlds opt in via `scenario({admin:true})`; a captured world is
          // proof the call was admitted live.
          if (!globalThis.__rove_captured && globalThis.kv.get(NS_STORE + "admin") !== "1") throw new TypeError("blob presign: scoped presign is admin-only");
          return "https://sim.invalid/" + target + "/" + subdir + "/" + hash + (ttl != null ? "?ttl=" + ttl : "");
        }
        return "https://sim.invalid/" + (subdir === "app-blobs" ? "blob/" : subdir + "/") + hash + (ttl != null ? "?ttl=" + ttl : "");
      },
      write: function(){}, seal: function(){ return {}; },
      // `blob.receive(on)` (own-tenant) and `platform.scope(id).blob.receive`
      // (which lowers to `receive(on, id, JSON.stringify(ctx))`) both bottom
      // out here. Record `scope` + the issue-time `app` ctx so a
      // `.receive().stored({...})` continuation can echo `app` back exactly
      // as `emitTerminal` does (`request.ctx = {hash, len, app}`).
      // jsBlobReceive gates, in prod's order: onHeaders-only (the body is
      // still at the door), once per request (a receive consumes THE
      // body), then the `on` export-name checks. The epilogue stamps
      // `__rove_activation_kind` and resets the once-gate per run.
      receive: function(on, scope, appJson){
        if (globalThis.__rove_activation_kind !== "inbound_headers") throw new TypeError("blob.receive: only callable from an onHeaders activation");
        if (globalThis.__rove_blob_receive_used) throw new TypeError("blob.receive: already called for this request (one inbound body)");
        if (typeof on !== "string" || !on.length) throw new TypeError("blob.receive requires an `on` export name");
        if (!isExportName(on)) throw new TypeError("blob.receive: `on` must be a JS identifier");
        globalThis.__rove_blob_receive_used = true;
        var app = null; if (appJson !== undefined && appJson !== null) { try { app = JSON.parse(appJson); } catch (_) { app = null; } } push({ kind: "blob", op: "receive", on: on, scope: (scope !== undefined ? scope : null), app: app });
      },
    },
    stream: {
      start: function(){},
      // jsStreamWrite (bindings/stream.zig): chunk must be a string or
      // Uint8Array (no String() fallback — "[object Object]" must never
      // ship as a wire chunk), and one activation's cumulative writes are
      // capped at StreamChunks.QUEUE_HARD_CAP (4 MiB) — a synchronous
      // flood throws; paginate with next(). The epilogue resets the
      // per-activation counter.
      write: function(c){
        if (typeof c !== "string" && !(c instanceof Uint8Array)) throw new TypeError("stream.write: chunk must be a string or Uint8Array");
        var prev = globalThis.__rove_stream_bytes || 0;
        // UTF-8 length ≥ UTF-16 code-unit count, so an over-cap chunk can be
        // rejected on .length alone; the per-char scan only runs for chunks
        // that could fit, and an all-ASCII chunk short-circuits via one
        // native regex test (its UTF-8 length IS .length).
        var nbytes = (typeof c !== "string" || !/[^\x00-\x7F]/.test(c)) ? c.length
          : (prev + c.length > 4194304 ? c.length : u8len(c));
        var tot = prev + nbytes;
        if (tot > 4194304) throw new RangeError("stream.write: too many bytes buffered in one activation; emit fewer per activation and continue with next()");
        globalThis.__rove_stream_bytes = tot;
        // `bytes` is the WIRE size (what the cap counts and prod ships).
        push({ kind: "stream", bytes: nbytes, data: b2s(c) });
      },
    },
    platform: {
      // scope(id).kv → instance `id`'s isolated store; `blob` is a bare object
      // the real platform.js augments (receive/get). root → the __root__ store.
      // Each is admin-gated (see `gate` above); the returned scope/root handle
      // is then a granted capability (its ops aren't re-checked).
      // jsPlatformScope (globals.zig): id required + non-empty (ToString
      // coerced), and the instance must RESOLVE — prod throws
      // Error{code:"InstanceNotFound"} at the call site for a ghost id.
      // Known offline = declared via `scenario({instances})` or created by
      // `instances.create` this run (both set the hidden exists marker).
      scope: gate(function(id){
        if (id === undefined) throw new TypeError("platform.scope requires (instance_id)");
        id = String(id);
        if (!id.length) throw new TypeError("platform.scope: instance_id must be non-empty");
        // The exists marker is harness-seeded, so a CAPTURED tape (which
        // carries no scenario) skips the resolve check — the tape already
        // proves the instance resolved live.
        if (!globalThis.__rove_captured && globalThis.kv.get(NS_STORE + "exists/i/" + id) !== "1") { var e = new Error("instance not found"); e.code = "InstanceNotFound"; throw e; }
        push({ kind: "platform", op: "scope", id: id });
        return { kv: storeKv(NS_STORE + "i/" + id + "/", "i/" + id), blob: {} };
      }),
      root: { get: gate(rootStore_r.get), set: gate(rootStore_r.set), delete: gate(rootStore_r.delete), prefix: gate(rootStore_r.prefix) },
      // instances.create records the exists marker as a STORE-TAGGED write
      // (not just a hidden native set): resumes rebuild kv from the folded
      // effect log, and only recorded writes fold forward — so an instance
      // created in one activation stays scope-resolvable in the next.
      // create(name): prod takes a NAME string (valueToOwnedString) and
      // returns undefined — the instance id IS the name. Record it, and seed
      // the exists marker keyed by name so a later platform.scope(name) folds.
      instances: { create: gate(function(name){ push({ kind: "platform", op: "instances.create", name: name }); push({ kind: "write", store: "exists", key: "i/" + name, value: "1" }); globalThis.kv.set(NS_STORE + "exists/i/" + name, "1"); }), deployStarter: gate(function(name){ push({ kind: "platform", op: "instances.deployStarter", name: name }); }) },
      releases: { publish: gate(function(tenant, depId){ push({ kind: "platform", op: "releases.publish", tenant: tenant, depId: depId }); }) },
      // No `auth` verb: the operator-root verdict is `request.rewind.isRoot`,
      // supplied by the world (scenario({ isRoot })) and folded from the
      // root_verdict tape entry — never a call taking the bearer. A token the
      // handler holds is a token the request surface records.
    },
  };
})();
