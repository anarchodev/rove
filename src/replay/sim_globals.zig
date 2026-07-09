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
//! The EFFECT globals (after/webhook/email/schedule/cron/blob/stream/next/kv)
//! are deliberately NOT installed here — the epilogue's recorders still provide
//! them, keeping the effect log unchanged. Installing the real effect shims
//! (which decompose `webhook.send` into `http.fetch`+`kv`+`schedule`) is a
//! separate step with effect-log implications.

// `_system.crypto` over the native replay crypto. Sha256/hmac/random are real;
// the rest fail loud rather than silently mis-behaving.
const SYSTEM_SHIM =
    \\;(function(){
    \\  var nat = globalThis.crypto;
    \\  var no = function(n){ return function(){ throw new Error("crypto." + n + " is not available in `rewind test` (the offline sim has SHA-256/HMAC + random only — no streaming sha, RSA or ECDSA)"); }; };
    \\  globalThis._system = { crypto: {
    \\    getRandomValues: function(a){ return nat.getRandomValues(a); },
    \\    randomBytes: function(n){ return nat.randomBytes(n); },
    \\    randomUUID: function(){ return nat.randomUUID(); },
    \\    sha256: function(d){ return nat.sha256(d); },
    \\    hmacSha256: function(k,d){ return nat.hmacSha256(k,d); },
    \\    sha256Init: no("sha256Init"), sha256Update: no("sha256Update"), sha256Final: no("sha256Final"),
    \\    verifyRsa: no("verifyRsa"), verifyEcdsa: no("verifyEcdsa"),
    \\    ecdsaGenerateKey: no("ecdsaGenerateKey"), ecdsaSign: no("ecdsaSign"), ecdsaVerify: no("ecdsaVerify"),
    \\    oidcGenerateKey: no("oidcGenerateKey"), oidcSign: no("oidcSign"),
    \\  } };
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
    "\n;" ++ @embedFile("g_request") ++
    "\n;" ++ @embedFile("g_base64") ++
    "\n;" ++ @embedFile("g_urlsearchparams") ++
    "\n;" ++ @embedFile("g_jwt") ++
    "\n;" ++ @embedFile("g_oauth") ++
    "\n;" ++ @embedFile("g_oidc") ++
    "\n;" ++ @embedFile("g_sessions") ++
    "\n;" ++ @embedFile("g_retry") ++
    "\n;" ++ @embedFile("g_segments") ++
    "\n;" ++ @embedFile("g_users") ++
    "\n;" ++ @embedFile("g_activitypub") ++
    "\n;delete globalThis._system;\n";
