//! The sim base prelude — the COMPUTE half of the worker's handler surface,
//! evaled into the replay/sim reactor's base (via arenajs 0.3.4's
//! `arena_reactor_eval_base`, pre-freeze) so `rewind test`/`sim`/`replay`
//! handlers get `crypto`/`base64url`/`jwt`/`oidc`/`oauth`/`sessions`/… for real
//! instead of ReferenceError-ing.
//!
//! These `globals/*.js` are PURE (no effects) — the only primitive they bottom
//! out on is `_system.crypto`, which we map onto the native `crypto.*` the
//! `arenajs-replay` bindings install (getRandomValues/randomBytes/randomUUID +
//! the 0.3.4 sha256/hmacSha256). Streaming sha256 (`sha256Init/Update/Final`,
//! for `blob`'s recipe midstate) + RSA/ECDSA verify aren't in the portable
//! replay engine, so they're supplied here in pure JS; sign / sha384/512 slots
//! still throw a clear error.
//!
//! The effect globals are installed here real, over `_system.*` RECORDERS that
//! push the same `{kind:…}` shapes into a per-run global effect sink
//! (`globalThis.__rove_effects`, which the epilogue aliases as `__effects`) — so
//! base globals and per-request shims share one ordered log:
//!   - `http`/`platform`/`browser` and the connection/continuation trio
//!     `after`/`stream`/`next` are faithful recorders (they don't decompose),
//!     installed unconditionally — the epilogue does not stub them;
//!   - the durable-effect verbs `cron`/`schedule`/`webhook`/`email` are the REAL
//!     shims, so `webhook.send`/`email.send` decompose into `http.fetch`+`kv`
//!     (`_send/owed`) + a watchdog `schedule` (`_sched/*`), and `schedule`/`cron`
//!     into `_sched/*` kv rows — the primitives that actually replicate;
//!   - `blob` is the real shim too, over the `_system.blob` recorder + the pure-JS
//!     streaming sha256 above (recipe rows + owed markers land in `kv`, the
//!     PUT/compose as `http.fetch`).
//! Still epilogue-local: the `kv` recorder wrapper.

// The `_system.*` primitives the globals compose over. `crypto` maps onto the
// native replay crypto (sha256/hmac/random real; streaming-sha + RSA/ECDSA
// verify pure-JS above; sign not yet). The
// effect primitives (`http`/`after`/`blob`/`platform`) are RECORDERS: they push
// the same `{kind:…}` shapes the epilogue's stubs do, into the per-run global
// sink `__rove_effects` (base globals can't reach the epilogue's local array),
// so the ordered effect log stays coherent. `platform.scope(id)` / `platform.root`
// get ISOLATED kv stores (each namespaces under `__rove_store/{tag}/` in the one
// map — see `storeKv` below), so cross-tenant/root writes never collide with the
// tenant's own kv. `checkRootToken(token)` validates against the configured
// operator root token (a hidden reserved kv key), not blanket success.
const SYSTEM_SHIM =
    \\;(function(){
    \\  var nat = globalThis.crypto;
    \\  var no = function(n){ return function(){ throw new Error("crypto." + n + " is not available in `rewind test` (the offline sim has SHA-256/HMAC + random only — no streaming sha, RSA or ECDSA)"); }; };
    \\  var push = function(e){ (globalThis.__rove_effects || (globalThis.__rove_effects = [])).push(e); };
    \\  var b2s = function(c){ if (typeof c === "string") return c; var s = ""; for (var i = 0; i < c.length; i++) s += String.fromCharCode(c[i]); return s; };
    \\  // Native rate-limit builtin the email global bottoms out on
    \\  // (worker-native — no-op offline: there's no per-worker bucket to
    \\  // exhaust). The continuation native lives on `_system.continuation`
    \\  // below (next.js captures it at base-eval — privileged-surface
    \\  // unification; the bare `__rove_next` global is gone).
    \\  globalThis.__rove_check_email_rate = function(){};
    \\  // Streaming SHA-256 in pure JS (the portable replay engine has one-shot
    \\  // `nat.sha256` only). Same posture as the RSA/ECDSA verify above; drives
    \\  // `crypto.sha256Init/Update/Final` so `blob.write`/`blob.seal` (recipe
    \\  // midstate) work offline. Final(Update*(Init())) === nat.sha256(concat) —
    \\  // string chunks UTF-8-encoded to match nat.sha256's string handling. The
    \\  // midstate token ("js2:" H32hex : totalLen : bufHex) is sim-internal
    \\  // (never crosses to native) — its own format, not the worker's `s2:`.
    \\  var K256 = [0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];
    \\  var H256_0 = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
    \\  var rotr = function(x, n){ return ((x >>> n) | (x << (32 - n))) >>> 0; };
    \\  var shaCompress = function(H, blk){
    \\    var w = new Array(64), i;
    \\    for (i = 0; i < 16; i++) w[i] = ((blk[i*4] << 24) | (blk[i*4+1] << 16) | (blk[i*4+2] << 8) | blk[i*4+3]) >>> 0;
    \\    for (i = 16; i < 64; i++) { var s0 = rotr(w[i-15],7) ^ rotr(w[i-15],18) ^ (w[i-15] >>> 3); var s1 = rotr(w[i-2],17) ^ rotr(w[i-2],19) ^ (w[i-2] >>> 10); w[i] = (((w[i-16] + s0) >>> 0) + ((w[i-7] + s1) >>> 0)) >>> 0; }
    \\    var a=H[0],b=H[1],c=H[2],d=H[3],e=H[4],f=H[5],g=H[6],h=H[7];
    \\    for (i = 0; i < 64; i++) {
    \\      var S1 = rotr(e,6) ^ rotr(e,11) ^ rotr(e,25); var ch = (e & f) ^ ((~e) & g);
    \\      var t1 = (((h + S1) >>> 0) + ((ch + ((K256[i] + w[i]) >>> 0)) >>> 0)) >>> 0;
    \\      var S0 = rotr(a,2) ^ rotr(a,13) ^ rotr(a,22); var maj = (a & b) ^ (a & c) ^ (b & c);
    \\      var t2 = (S0 + maj) >>> 0;
    \\      h=g; g=f; f=e; e=(d + t1) >>> 0; d=c; c=b; b=a; a=(t1 + t2) >>> 0;
    \\    }
    \\    H[0]=(H[0]+a)>>>0; H[1]=(H[1]+b)>>>0; H[2]=(H[2]+c)>>>0; H[3]=(H[3]+d)>>>0; H[4]=(H[4]+e)>>>0; H[5]=(H[5]+f)>>>0; H[6]=(H[6]+g)>>>0; H[7]=(H[7]+h)>>>0;
    \\  };
    \\  var shaStrU8 = function(s){ var out = [], i, cp; for (i = 0; i < s.length; i++) { cp = s.charCodeAt(i); if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < s.length) { var lo = s.charCodeAt(i+1); if (lo >= 0xDC00 && lo <= 0xDFFF) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); i++; } } if (cp < 0x80) out.push(cp); else if (cp < 0x800) out.push(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F)); else if (cp < 0x10000) out.push(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)); else out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)); } return out; };
    \\  var shaBytes = function(d){ if (typeof d === "string") return shaStrU8(d); var out = [], i; for (i = 0; i < d.length; i++) out.push(d[i] & 0xff); return out; };
    \\  var hx8 = function(x){ return ("00000000" + (x >>> 0).toString(16)).slice(-8); };
    \\  var hx2 = function(x){ return ("0" + (x & 0xff).toString(16)).slice(-2); };
    \\  var shaSer = function(st){ var i, hs = ""; for (i = 0; i < 8; i++) hs += hx8(st.h[i]); var bh = ""; for (i = 0; i < st.buf.length; i++) bh += hx2(st.buf[i]); return "js2:" + hs + ":" + st.len + ":" + bh; };
    \\  var shaParse = function(tok){ if (typeof tok !== "string" || tok.indexOf("js2:") !== 0) throw new Error("crypto.sha256: invalid midstate token"); var p = tok.slice(4).split(":"); var hs = p[0], len = Number(p[1]), bh = p[2] || ""; var h = [], i; for (i = 0; i < 8; i++) h.push(parseInt(hs.substr(i*8, 8), 16) >>> 0); var buf = []; for (i = 0; i < bh.length; i += 2) buf.push(parseInt(bh.substr(i, 2), 16)); return { h: h, len: len, buf: buf }; };
    \\  var shaInit = function(){ return shaSer({ h: H256_0.slice(), len: 0, buf: [] }); };
    \\  var shaUpdate = function(tok, data){ var st = shaParse(tok); var bytes = shaBytes(data); var buf = st.buf.concat(bytes); var i = 0; while (buf.length - i >= 64) { shaCompress(st.h, buf.slice(i, i + 64)); i += 64; } st.buf = buf.slice(i); st.len += bytes.length; return shaSer(st); };
    \\  var shaFinal = function(tok){ var st = shaParse(tok); var buf = st.buf.slice(); buf.push(0x80); while (buf.length % 64 !== 56) buf.push(0x00); var bitHi = Math.floor(st.len / 0x20000000), bitLo = (st.len * 8) >>> 0; buf.push((bitHi >>> 24) & 0xff, (bitHi >>> 16) & 0xff, (bitHi >>> 8) & 0xff, bitHi & 0xff, (bitLo >>> 24) & 0xff, (bitLo >>> 16) & 0xff, (bitLo >>> 8) & 0xff, bitLo & 0xff); for (var i = 0; i < buf.length; i += 64) shaCompress(st.h, buf.slice(i, i + 64)); var out = ""; for (i = 0; i < 8; i++) out += hx8(st.h[i]); return out; };
    \\  // RS256 verify (RSASSA-PKCS1-v1.5 + SHA-256) in pure JS over BigInt — the
    \\  // common OIDC alg. Portable (no OpenSSL). sha384/512 + ECDSA not covered.
    \\  var __sim_verifyRsa = function(jwk, alg, data, sig){
    \\    try {
    \\      if (!jwk || jwk.kty !== "RSA") return false;
    \\      if ((alg || "sha256").toLowerCase() !== "sha256") return false;
    \\      var b64u = globalThis.base64url;
    \\      var toBig = function(b){ var x = 0n; for (var i = 0; i < b.length; i++) x = (x << 8n) | BigInt(b[i]); return x; };
    \\      var n = toBig(b64u.decode(jwk.n)), e = toBig(b64u.decode(jwk.e));
    \\      var sb = (typeof sig === "string") ? b64u.decode(sig) : sig;
    \\      var s = toBig(sb);
    \\      if (s >= n) return false;
    \\      var r = 1n, base = s % n, ee = e;
    \\      while (ee > 0n){ if (ee & 1n) r = (r * base) % n; ee >>= 1n; base = (base * base) % n; }
    \\      var klen = 0, nn = n; while (nn > 0n){ nn >>= 8n; klen++; }
    \\      var em = new Uint8Array(klen), mm = r;
    \\      for (var i2 = klen - 1; i2 >= 0; i2--){ em[i2] = Number(mm & 0xffn); mm >>= 8n; }
    \\      if (em[0] !== 0x00 || em[1] !== 0x01) return false;
    \\      var p = 2; while (p < em.length && em[p] === 0xff) p++;
    \\      if (em[p] !== 0x00) return false; p++;
    \\      var PFX = [0x30,0x31,0x30,0x0d,0x06,0x09,0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x02,0x01,0x05,0x00,0x04,0x20];
    \\      var hex = nat.sha256(data), hash = new Uint8Array(32);
    \\      for (var j = 0; j < 32; j++) hash[j] = parseInt(hex.substr(j*2, 2), 16);
    \\      if (em.length - p !== PFX.length + 32) return false;
    \\      for (var k = 0; k < PFX.length; k++) if (em[p + k] !== PFX[k]) return false;
    \\      for (var k2 = 0; k2 < 32; k2++) if (em[p + PFX.length + k2] !== hash[k2]) return false;
    \\      return true;
    \\    } catch (_) { return false; }
    \\  };
    \\  // ES256 verify (ECDSA P-256 + SHA-256) in pure JS over BigInt. Point math
    \\  // uses Jacobian coordinates so the whole verify costs ONE modular inverse
    \\  // (at the end) instead of one per point op — affine would churn the bump
    \\  // arena past any sane ceiling. Accepts JWS raw r||s (64B) or DER.
    \\  var __sim_verifyEcdsa = function(jwk, alg, data, sig){
    \\    try {
    \\      if (!jwk || jwk.kty !== "EC" || jwk.crv !== "P-256") return false;
    \\      if ((alg || "sha256").toLowerCase() !== "sha256") return false;
    \\      var b64u = globalThis.base64url;
    \\      var toBig = function(b){ var x = 0n; for (var i = 0; i < b.length; i++) x = (x << 8n) | BigInt(b[i]); return x; };
    \\      var p = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffffn;
    \\      var acurve = p - 3n;
    \\      var n = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n;
    \\      var Gx = 0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296n;
    \\      var Gy = 0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5n;
    \\      var mod = function(x, m){ x %= m; return x < 0n ? x + m : x; };
    \\      var inv = function(x, m){ var r = 1n, b = mod(x, m), e = m - 2n; while (e > 0n){ if (e & 1n) r = (r * b) % m; e >>= 1n; b = (b * b) % m; } return r; };
    \\      // Jacobian point [X, Y, Z]; Z === 0n is the point at infinity.
    \\      var jdbl = function(P){
    \\        if (P[2] === 0n || P[1] === 0n) return [0n, 0n, 0n];
    \\        var YY = (P[1] * P[1]) % p; var S = mod(4n * P[0] * YY, p); var ZZ = (P[2] * P[2]) % p;
    \\        var M = mod(3n * P[0] * P[0] + acurve * ZZ % p * ZZ, p);
    \\        var X3 = mod(M * M - 2n * S, p);
    \\        return [X3, mod(M * (S - X3) - 8n * YY % p * YY, p), mod(2n * P[1] * P[2], p)];
    \\      };
    \\      var jadd = function(P, Q){
    \\        if (P[2] === 0n) return Q; if (Q[2] === 0n) return P;
    \\        var Z1Z1 = (P[2] * P[2]) % p, Z2Z2 = (Q[2] * Q[2]) % p;
    \\        var U1 = mod(P[0] * Z2Z2, p), U2 = mod(Q[0] * Z1Z1, p);
    \\        var S1 = mod(P[1] * Q[2] % p * Z2Z2, p), S2 = mod(Q[1] * P[2] % p * Z1Z1, p);
    \\        if (U1 === U2){ if (S1 !== S2) return [0n, 0n, 0n]; return jdbl(P); }
    \\        var H = mod(U2 - U1, p); var I = mod(2n * H % p * (2n * H), p); var J = mod(H * I, p);
    \\        var rr = mod(2n * (S2 - S1), p); var V = mod(U1 * I, p);
    \\        var X3 = mod(rr * rr - J - 2n * V, p);
    \\        var ZS = mod(P[2] + Q[2], p);
    \\        return [X3, mod(rr * (V - X3) - 2n * S1 % p * J, p), mod((ZS * ZS % p - Z1Z1 - Z2Z2) * H, p)];
    \\      };
    \\      var jmul = function(k, P){ var R = [0n, 0n, 0n]; k = mod(k, n); while (k > 0n){ if (k & 1n) R = jadd(R, P); P = jdbl(P); k >>= 1n; } return R; };
    \\      var Q = [toBig(b64u.decode(jwk.x)), toBig(b64u.decode(jwk.y)), 1n];
    \\      var sb = (typeof sig === "string") ? b64u.decode(sig) : sig;
    \\      var r, s;
    \\      if (sb.length === 64){ r = toBig(sb.slice(0, 32)); s = toBig(sb.slice(32, 64)); }
    \\      else if (sb[0] === 0x30){ var i = 2; if (sb[1] & 0x80) i = 2 + (sb[1] & 0x7f); var rl = sb[i + 1]; r = toBig(sb.slice(i + 2, i + 2 + rl)); i = i + 2 + rl; var sl = sb[i + 1]; s = toBig(sb.slice(i + 2, i + 2 + sl)); }
    \\      else return false;
    \\      if (r <= 0n || r >= n || s <= 0n || s >= n) return false;
    \\      var e = BigInt("0x" + nat.sha256(data));
    \\      var w = inv(s, n);
    \\      var R = jadd(jmul(mod(e * w, n), [Gx, Gy, 1n]), jmul(mod(r * w, n), Q));
    \\      if (R[2] === 0n) return false;
    \\      var zi = inv(R[2], p);
    \\      return mod(mod(R[0] * zi % p * zi, p), n) === r;
    \\    } catch (_) { return false; }
    \\  };
    \\  // Per-instance / root kv isolation for `platform.*`. Each store namespaces
    \\  // its keys under `__rove_store/{tag}/` in the one closed-world map, so a
    \\  // scoped or root write never collides with the tenant's own kv (or another
    \\  // instance's). The facade pushes CLEAN store-tagged effect entries; the
    \\  // epilogue kv wrapper skips recording and hides the namespaced keys, so a
    \\  // tenant read / prefix scan never sees another store.
    \\  var NS_STORE = "__rove_store/";
    \\  var storeKv = function(P, tag){
    \\    return {
    \\      get: function(k){ var v = globalThis.kv.get(P + k); push({ kind: "read", store: tag, key: k, present: v !== undefined && v !== null }); return v; },
    \\      set: function(k, val){ push({ kind: "write", store: tag, key: k, value: val }); return globalThis.kv.set(P + k, val); },
    \\      delete: function(k){ push({ kind: "delete", store: tag, key: k }); return globalThis.kv.delete(P + k); },
    \\      prefix: function(p, cursor, limit){ var r = globalThis.kv.prefix(P + (p || ""), cursor, limit); push({ kind: "read", op: "prefix", store: tag, key: (p || "") }); return (r || []).map(function(e){ return { key: e.key.slice(P.length), value: e.value }; }); },
    \\    };
    \\  };
    \\  // platform.* is admin-only (prod: throws off the `__admin__` handler). Fail
    \\  // closed — every sync method is gated unless the run is flagged admin
    \\  // (`scenario({ admin: true })` → the hidden `__rove_store/admin` key). Note
    \\  // `platform.compile` is NOT gated here: it lowers to a bound fetch (via the
    \\  // real platform.js over `_system.after`), admin-checked door-side in prod.
    \\  var GATE_MSG = "platform is only available on the admin handler";
    \\  var gate = function(fn){ return function(){ if (globalThis.kv.get(NS_STORE + "admin") !== "1") throw new TypeError(GATE_MSG); return fn.apply(null, arguments); }; };
    \\  var rootStore_r = storeKv(NS_STORE + "r/", "r");
    \\  // Fetch/subscribe recorder. Ids are unique per run (`ftch_<seq>` — the
    \\  // epilogue resets the counter each activation), NOT prod's ftch_<64hex>:
    \\  // determinism over realism, but distinct so a handler can correlate the
    \\  // returned id with the `request.fetchId` its resume observes (issue #24).
    \\  // The effect entry carries the FULL option bag prod reads
    \\  // (http.zig buildFetchRow), defaults applied, in the PUBLIC spellings
    \\  // (timeoutMs/maxChunkBytes/maxTotalBytes — this recorder sits under the
    \\  // after.js/http.js shims, which already lowered them to the native
    \\  // snake_case, so translate back) — so `toHaveSent("fetch", { headers,
    \\  // stream, timeoutMs, … })` matches what the handler wrote and `.not.`
    \\  // variants aren't vacuous.
    \\  var nextSeq = function(){ return (globalThis.__rove_fetch_seq = (globalThis.__rove_fetch_seq || 0) + 1); };
    \\  var recFetch = function(url, o, on){
    \\    var id = "ftch_" + nextSeq();
    \\    push({ kind: "fetch", id: id, url: url, method: (o && o.method) || "GET",
    \\      body: (o && o.body !== undefined) ? o.body : null,
    \\      headers: (o && o.headers) || {},
    \\      ctx: (o && o.ctx !== undefined) ? o.ctx : null,
    \\      on: on || null,
    \\      stream: !!(o && o.stream),
    \\      timeoutMs: (o && o.timeout_ms != null) ? o.timeout_ms : 30000,
    \\      maxChunkBytes: (o && o.max_response_chunk_bytes != null) ? o.max_response_chunk_bytes : 262144,
    \\      maxTotalBytes: (o && o.max_total_response_bytes != null) ? o.max_total_response_bytes : 52428800 });
    \\    return id;
    \\  };
    \\  globalThis._system = {
    \\    // The park/continue native (`next.js` captures this at base-eval).
    \\    // Mirrors the worker's disposition: target "" = same-module;
    \\    // non-empty = cross-module re-entry (recorded for fidelity; the
    \\    // sim consumer keys on `__rove_disposition` + `ctx`).
    \\    continuation: {
    \\      next: function(target, o){ return { __rove_disposition: "next", target: (target ? target : null), ctx: (o && o.ctx !== undefined) ? o.ctx : null }; },
    \\    },
    \\    crypto: {
    \\      getRandomValues: function(a){ return nat.getRandomValues(a); },
    \\      randomBytes: function(n){ return nat.randomBytes(n); },
    \\      randomUUID: function(){ return nat.randomUUID(); },
    \\      sha256: function(d){ return nat.sha256(d); },
    \\      hmacSha256: function(k,d){ return nat.hmacSha256(k,d); },
    \\      sha256Init: function(){ return shaInit(); },
    \\      sha256Update: function(t,d){ return shaUpdate(t,d); },
    \\      sha256Final: function(t){ return shaFinal(t); },
    \\      verifyRsa: function(jwk, alg, data, sig){ return __sim_verifyRsa(jwk, alg, data, sig); },
    \\      verifyEcdsa: function(jwk, alg, data, sig){ return __sim_verifyEcdsa(jwk, alg, data, sig); },
    \\      ecdsaGenerateKey: no("ecdsaGenerateKey"), ecdsaSign: no("ecdsaSign"), ecdsaVerify: no("ecdsaVerify"),
    \\      oidcGenerateKey: no("oidcGenerateKey"), oidcSign: no("oidcSign"),
    \\    },
    \\    http: {
    \\      fetch: function(o){ o = o || {}; return recFetch(o.url, o, o.on_chunk || o.on || null); },
    \\      cancelFetch: function(){},
    \\      subscribe: function(o){ o = o || {}; var id = "sub_" + nextSeq(); push({ kind: "subscribe", id: id, url: o.url, headers: o.headers || {}, on: o.on_chunk || o.on || null }); return id; },
    \\      cancelSubscription: function(){},
    \\    },
    \\    after: {
    \\      // `on` is the ONE spelling end to end — the after.js shim passes the
    \\      // opts bag through and the worker bindings read `opts.on` the same way.
    \\      fetch: function(url, o){ return recFetch(url, o, (o && o.on) || null); },
    \\      kv: function(prefix, o){ push({ kind: "kv-wake", prefix: prefix, on: (o && o.on) || null }); },
    \\      timer: function(ms, o){ push({ kind: "timer", ms: ms, on: (o && o.on) || null }); },
    \\    },
    \\    blob: {
    \\      presign: function(hash, ttl, ct){ return "https://sim.invalid/blob/" + hash + (ttl != null ? "?ttl=" + ttl : ""); },
    \\      write: function(){}, seal: function(){ return {}; },
    \\      // `blob.receive(on)` (own-tenant) and `platform.scope(id).blob.receive`
    \\      // (which lowers to `receive(on, id, JSON.stringify(ctx))`) both bottom
    \\      // out here. Record `scope` + the issue-time `app` ctx so a
    \\      // `.receive().stored({...})` continuation can echo `app` back exactly
    \\      // as `emitTerminal` does (`request.ctx = {hash, len, app}`).
    \\      receive: function(on, scope, appJson){ var app = null; if (appJson !== undefined && appJson !== null) { try { app = JSON.parse(appJson); } catch (_) { app = null; } } push({ kind: "blob", op: "receive", on: on || null, scope: (scope !== undefined ? scope : null), app: app }); },
    \\    },
    \\    stream: {
    \\      start: function(){},
    \\      write: function(c){ var t = b2s(c); push({ kind: "stream", bytes: t.length, data: t }); },
    \\    },
    \\    platform: {
    \\      // scope(id).kv → instance `id`'s isolated store; `blob` is a bare object
    \\      // the real platform.js augments (receive/get). root → the __root__ store.
    \\      // Each is admin-gated (see `gate` above); the returned scope/root handle
    \\      // is then a granted capability (its ops aren't re-checked).
    \\      scope: gate(function(id){ push({ kind: "platform", op: "scope", id: id }); return { kv: storeKv(NS_STORE + "i/" + id + "/", "i/" + id), blob: {} }; }),
    \\      root: { get: gate(rootStore_r.get), set: gate(rootStore_r.set), delete: gate(rootStore_r.delete), prefix: gate(rootStore_r.prefix) },
    \\      instances: { create: gate(function(spec){ push({ kind: "platform", op: "instances.create", spec: spec }); return (spec && spec.id) || "inst_sim"; }), deployStarter: gate(function(){ push({ kind: "platform", op: "instances.deployStarter" }); }) },
    \\      releases: { publish: gate(function(){ push({ kind: "platform", op: "releases.publish" }); }) },
    \\      // checkRootToken(token) → true iff it matches the operator root token
    \\      // (env-supplied in prod); the sim carries it as a hidden reserved kv key
    \\      // seeded by `scenario({ rootToken })`. Unconfigured → nothing is root.
    \\      auth: { checkRootToken: gate(function(token){ var rt = globalThis.kv.get(NS_STORE + "auth/token"); var ok = (typeof rt === "string" && rt.length > 0 && token === rt); push({ kind: "platform", op: "auth.checkRootToken", ok: ok }); return ok; }) },
    \\    },
    \\  };
    \\})();
    \\
;

// The compute `globals/*.js`, in the worker's dependency order (globals.zig).
// `crypto.js` first (it captures `_system.crypto`); the rest compose on the
// public globals the earlier ones install.
// The `globals/*.js` are embedded via anonymous imports (build.zig
// `addSimGlobalEmbeds` — they live in src/js/globals/, outside this module's
// package, so `@embedFile` takes the import NAME, not a path).
pub const PRELUDE: [:0]const u8 = SYSTEM_SHIM ++
    "\n;" ++ @embedFile("g_crypto") ++
    "\n;" ++ @embedFile("g_http") ++
    "\n;" ++ @embedFile("g_request") ++
    "\n;" ++ @embedFile("g_base64") ++
    "\n;" ++ @embedFile("g_urlsearchparams") ++
    "\n;" ++ @embedFile("g_jwt") ++
    "\n;" ++ @embedFile("g_oauth") ++
    "\n;" ++ @embedFile("g_oidc") ++
    "\n;" ++ @embedFile("g_sessions") ++
    "\n;" ++ @embedFile("g_platform") ++
    "\n;" ++ @embedFile("g_retry") ++
    "\n;" ++ @embedFile("g_segments") ++
    "\n;" ++ @embedFile("g_browser") ++
    "\n;" ++ @embedFile("g_users") ++
    "\n;" ++ @embedFile("g_activitypub") ++
    // The connection/continuation shims — `after` (wake triggers), `stream`
    // (output frames), `next` (park disposition). Faithful recorders (they don't
    // decompose), installed unconditionally; the epilogue does not stub them.
    // All three are IIFE-wrapped upstream, so freeze-safe as embedded.
    "\n;" ++ @embedFile("g_after") ++
    "\n;" ++ @embedFile("g_stream") ++
    "\n;" ++ @embedFile("g_next") ++
    // The durable-effect shims — the real webhook/schedule/cron/email verbs, so
    // they decompose to primitives (`_send/owed` + `_sched/*` kv writes +
    // `http.fetch`) in the effect log; the epilogue does not stub them.
    // Order mirrors the worker's GLOBALS_FILES: `cron` (fire-time helpers + the
    // recurring verb) → `schedule` (reuses `cron.parseDuration`) → `webhook`
    // (composes over `kv`+`schedule`+the `_system.http` fetch primitive it
    // captures at eval — so it MUST land before the `delete globalThis._system`
    // below) → `email` (layers on `webhook.send`). `webhook.js` isn't IIFE-wrapped
    // (top-level `const sysHttp`), so wrap it here to keep its lexicals out of the
    // base-snapshot's global lexical scope (the freeze corrupts on bare top-level
    // bindings — see globals-shim-iife-required); `email.js` is a plain
    // `globalThis.email = {…}` assignment, freeze-safe as-is.
    "\n;" ++ @embedFile("g_cron") ++
    "\n;" ++ @embedFile("g_schedule") ++
    "\n;(function(){\n" ++ @embedFile("g_webhook") ++ "\n})();" ++
    "\n;" ++ @embedFile("g_email") ++
    // `blob` — real shim over the `_system.blob` recorder + `_system.http` (PUT /
    // compose) + the pure-JS streaming sha256; `blob.get` composes on the base
    // `after.fetch`, so it lands after `g_after`. Its recipe rows / owed markers
    // are ordinary kv writes. IIFE-wrapped upstream (`(() => { … })()`), so it
    // captures `_system` before the delete below and stays freeze-safe.
    "\n;" ++ @embedFile("g_blob") ++
    "\n;delete globalThis._system;\n";
