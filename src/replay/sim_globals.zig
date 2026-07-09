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
//! The effect globals split two ways. `http`/`platform`/`browser` (NOT stubbed
//! by the epilogue) are installed here real, over `_system.*` RECORDERS that
//! push the same `{kind:…}` shapes into a per-run global effect sink
//! (`globalThis.__rove_effects`, which the epilogue aliases as `__effects`) — so
//! base globals and per-request stubs share one ordered log. The rest
//! (after/webhook/email/schedule/cron/blob/stream/next/kv) stay the epilogue's
//! stubs — installing the REAL shims would decompose `webhook.send` into
//! `http.fetch`+`kv`+`schedule` and shift the effect log to primitive level,
//! which is a separate (breaking) step.

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
    \\  globalThis._system = {
    \\    crypto: {
    \\      getRandomValues: function(a){ return nat.getRandomValues(a); },
    \\      randomBytes: function(n){ return nat.randomBytes(n); },
    \\      randomUUID: function(){ return nat.randomUUID(); },
    \\      sha256: function(d){ return nat.sha256(d); },
    \\      hmacSha256: function(k,d){ return nat.hmacSha256(k,d); },
    \\      sha256Init: no("sha256Init"), sha256Update: no("sha256Update"), sha256Final: no("sha256Final"),
    \\      verifyRsa: function(jwk, alg, data, sig){ return __sim_verifyRsa(jwk, alg, data, sig); },
    \\      verifyEcdsa: no("verifyEcdsa"),
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
    "\n;delete globalThis._system;\n";
