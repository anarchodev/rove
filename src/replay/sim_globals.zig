//! The sim base prelude — the COMPUTE half of the worker's handler surface,
//! evaled into the replay/sim reactor's base (via arenajs 0.3.4's
//! `arena_reactor_eval_base`, pre-freeze) so `rewind test`/`sim`/`replay`
//! handlers get `crypto`/`base64url`/`jwt`/`oidc`/`oauth`/`sessions`/… for real
//! instead of ReferenceError-ing.
//!
//! These `globals/*.js` are PURE (no effects) — the only primitive they bottom
//! out on is `_system.crypto`, which we map onto the native `crypto.*` the
//! `arenajs-replay` bindings install (getRandomValues/randomBytes/randomUUID +
//! the 0.3.4 sha256/hmacSha256). Streaming sha + RSA/ECDSA aren't in the
//! portable replay engine, so those `_system.crypto` slots throw a clear error.
//!
//! The effect globals are installed here real, over `_system.*` RECORDERS that
//! push the same `{kind:…}` shapes into a per-run global effect sink
//! (`globalThis.__rove_effects`, which the epilogue aliases as `__effects`) — so
//! base globals and per-request shims share one ordered log:
//!   - `http`/`platform`/`browser` and the connection/continuation trio
//!     `after`/`stream`/`next` are faithful recorders (they don't decompose),
//!     installed unconditionally — the epilogue no longer stubs them;
//!   - the durable-effect verbs `cron`/`schedule`/`webhook`/`email` are the REAL
//!     shims, so `webhook.send`/`email.send` decompose into `http.fetch`+`kv`
//!     (`_send/owed`) + a watchdog `schedule` (`_sched/*`), and `schedule`/`cron`
//!     into `_sched/*` kv rows — the primitives that actually replicate.
//! Still epilogue-local: `blob` (its recipe path needs streaming sha256, absent
//! offline) and the `kv` recorder wrapper.

// The `_system.*` primitives the globals compose over. `crypto` maps onto the
// native replay crypto (sha256/hmac/random real; sign/verify not yet). The
// effect primitives (`http`/`after`/`blob`/`platform`) are RECORDERS: they push
// the same `{kind:…}` shapes the epilogue's stubs do, into the per-run global
// sink `__rove_effects` (base globals can't reach the epilogue's local array),
// so the ordered effect log stays coherent. Platform reads hit the one
// closed-world kv (no per-instance store isolation yet) and `checkRootToken`
// assumes root — known first-pass limitations.
const SYSTEM_SHIM =
    \\;(function(){
    \\  var nat = globalThis.crypto;
    \\  var no = function(n){ return function(){ throw new Error("crypto." + n + " is not available in `rewind test` (the offline sim has SHA-256/HMAC + random only — no streaming sha, RSA or ECDSA)"); }; };
    \\  var push = function(e){ (globalThis.__rove_effects || (globalThis.__rove_effects = [])).push(e); };
    \\  var b2s = function(c){ if (typeof c === "string") return c; var s = ""; for (var i = 0; i < c.length; i++) s += String.fromCharCode(c[i]); return s; };
    \\  // Native continuation + rate-limit builtins the base globals bottom out on
    \\  // (worker-native — the sim supplies faithful equivalents). `__rove_next`
    \\  // mirrors the disposition the epilogue used to synthesize inline; the email
    \\  // rate limiter is a no-op offline (there's no per-worker bucket to exhaust).
    \\  globalThis.__rove_next = function(_, o){ return { __rove_disposition: "next", ctx: (o && o.ctx !== undefined) ? o.ctx : null }; };
    \\  globalThis.__rove_check_email_rate = function(){};
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
    \\  globalThis._system = {
    \\    crypto: {
    \\      getRandomValues: function(a){ return nat.getRandomValues(a); },
    \\      randomBytes: function(n){ return nat.randomBytes(n); },
    \\      randomUUID: function(){ return nat.randomUUID(); },
    \\      sha256: function(d){ return nat.sha256(d); },
    \\      hmacSha256: function(k,d){ return nat.hmacSha256(k,d); },
    \\      sha256Init: no("sha256Init"), sha256Update: no("sha256Update"), sha256Final: no("sha256Final"),
    \\      verifyRsa: function(jwk, alg, data, sig){ return __sim_verifyRsa(jwk, alg, data, sig); },
    \\      verifyEcdsa: function(jwk, alg, data, sig){ return __sim_verifyEcdsa(jwk, alg, data, sig); },
    \\      ecdsaGenerateKey: no("ecdsaGenerateKey"), ecdsaSign: no("ecdsaSign"), ecdsaVerify: no("ecdsaVerify"),
    \\      oidcGenerateKey: no("oidcGenerateKey"), oidcSign: no("oidcSign"),
    \\    },
    \\    http: {
    \\      fetch: function(o){ o = o || {}; push({ kind: "fetch", url: o.url, method: o.method || "GET", body: (o.body !== undefined ? o.body : null), ctx: (o.ctx !== undefined ? o.ctx : null), on: o.on_chunk || o.on || null }); return "ftch_sim"; },
    \\      cancelFetch: function(){},
    \\      subscribe: function(o){ o = o || {}; push({ kind: "subscribe", url: o.url, on: o.on_chunk || o.on || null }); return "sub_sim"; },
    \\      cancelSubscription: function(){},
    \\    },
    \\    after: {
    \\      fetch: function(url, o, tgt){ push({ kind: "fetch", url: url, method: (o && o.method) || "GET", body: (o && o.body !== undefined) ? o.body : null, ctx: (o && o.ctx !== undefined) ? o.ctx : null, on: (tgt && tgt.to) || (o && o.on) || null }); return "ftch_sim"; },
    \\      kv: function(prefix, tgt){ push({ kind: "kv-wake", prefix: prefix, on: (tgt && tgt.to) || null }); },
    \\      timer: function(ms, tgt){ push({ kind: "timer", ms: ms, on: (tgt && tgt.to) || null }); },
    \\    },
    \\    blob: {
    \\      presign: function(){ return "https://sim.invalid/presign"; },
    \\      write: function(){}, seal: function(){ return {}; },
    \\      receive: function(){ push({ kind: "blob", op: "receive" }); },
    \\    },
    \\    stream: {
    \\      start: function(){},
    \\      write: function(c){ var t = b2s(c); push({ kind: "stream", bytes: t.length, data: t }); },
    \\    },
    \\    platform: {
    \\      scope: function(id){ push({ kind: "platform", op: "scope", id: id }); return { kv: { get: function(k){ return globalThis.kv.get(k); }, set: function(k,v){ globalThis.kv.set(k,v); }, delete: function(k){ globalThis.kv.delete(k); }, prefix: function(p,o){ return globalThis.kv.prefix(p,o); } } }; },
    \\      root: { get: function(k){ return globalThis.kv.get(k); }, set: function(k,v){ globalThis.kv.set(k,v); }, delete: function(k){ globalThis.kv.delete(k); }, prefix: function(p,o){ return globalThis.kv.prefix(p,o); } },
    \\      instances: { create: function(spec){ push({ kind: "platform", op: "instances.create", spec: spec }); return (spec && spec.id) || "inst_sim"; }, deployStarter: function(){ push({ kind: "platform", op: "instances.deployStarter" }); } },
    \\      releases: { publish: function(){ push({ kind: "platform", op: "releases.publish" }); } },
    \\      auth: { checkRootToken: function(){ push({ kind: "platform", op: "auth.checkRootToken" }); return true; } },
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
    // decompose), installed unconditionally; the epilogue no longer stubs them.
    // All three are IIFE-wrapped upstream, so freeze-safe as embedded.
    "\n;" ++ @embedFile("g_after") ++
    "\n;" ++ @embedFile("g_stream") ++
    "\n;" ++ @embedFile("g_next") ++
    // The durable-effect shims — the real webhook/schedule/cron/email verbs, so
    // they decompose to primitives (`_send/owed` + `_sched/*` kv writes +
    // `http.fetch`) in the effect log; the epilogue no longer stubs them.
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
    "\n;delete globalThis._system;\n";
