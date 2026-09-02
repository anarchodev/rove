// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
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

// The `_system.*` recorder layer, shared verbatim with the browser replay
// arena (js/system_recorders.js — see its header). Embedded rather than
// inlined so the two offline runtimes cannot drift.
const SYSTEM_SHIM = @embedFile("js/system_recorders.js");

// The compute `globals/*.js`, in the worker's dependency order (globals.zig).
// `crypto.js` first (it captures `_system.crypto`); the rest compose on the
// public globals the earlier ones install.
// The `globals/*.js` are embedded via anonymous imports (build.zig
// `addSimGlobalEmbeds` — they live in src/js/globals/, outside this module's
// package, so `@embedFile` takes the import NAME, not a path).
pub const PRELUDE: [:0]const u8 = SYSTEM_SHIM ++
    // The factory registry, the same shape the worker's installStatic
    // creates (`_factories.js`): a factory-shaped shim registers itself
    // here instead of assigning a global, and the invoker at the end of
    // this prelude calls it with the caps a platform shim receives.
    "\n;globalThis.__rove_factories = {};" ++
    "\n;" ++ @embedFile("g_crypto") ++
    "\n;" ++ @embedFile("g_http") ++
    "\n;" ++ @embedFile("g_request") ++
    // `held.js` — the worker's request.messages / request.chunks iterables,
    // patched onto the SAME `__rove_request_proto` request.js publishes.
    // Bottoms out on the `_system.held.nextInput` recorder (a held-promise
    // cell), so a `for await (const m of request.messages)` handler runs
    // offline with the worker's own shim rather than a second one.
    "\n;" ++ @embedFile("g_held") ++
    "\n;" ++ @embedFile("g_base64") ++
    "\n;" ++ @embedFile("g_urlsearchparams") ++
    "\n;" ++ @embedFile("g_platform") ++
    // The connection/continuation shims — `after` (wake triggers), `stream`
    // (output frames), `next` (park disposition). Faithful recorders (they don't
    // decompose), installed unconditionally; the epilogue does not stub them.
    // All three are IIFE-wrapped upstream, so freeze-safe as embedded.
    "\n;" ++ @embedFile("g_after") ++
    "\n;" ++ @embedFile("g_stream") ++
    "\n;" ++ @embedFile("g_next") ++
    // The durable-effect shims — the real webhook + the private scheduler
    // core, so webhook.send decomposes to primitives (`_send/owed` +
    // `_sched/*` kv writes + `http.fetch`) in the effect log; the epilogue
    // does not stub them. Order: `time` (the shared time-coercion library) →
    // `schedule` (coerces `{at}`/`{in}` through `time`; installs the PRIVATE
    // `_system.sched`, NOT a customer global — that's the @rewind/schedule
    // package, resolved per-request like the other lifted libs) → `webhook`
    // (a factory: it receives `http`/`sched`/`kv`/`formats` from the
    // invoker below rather than capturing `_system.*` at eval, so eval
    // order no longer constrains it; the registration itself has no
    // top-level bindings, so it is freeze-safe embedded bare).
    // `schedule.js` is self-IIFE'd (freeze-safe as embedded).
    "\n;" ++ @embedFile("g_time") ++
    "\n;" ++ @embedFile("g_schedule") ++
    "\n;" ++ @embedFile("g_webhook") ++
    // `blob` — real shim over the `_system.blob` recorder + `_system.http` (PUT /
    // compose) + the pure-JS streaming sha256; `blob.get` composes on the base
    // `after.fetch`, so it lands after `g_after`. Its recipe rows / owed markers
    // are ordinary kv writes. IIFE-wrapped upstream (`(() => { … })()`), so it
    // captures `_system` before the delete below and stays freeze-safe.
    "\n;" ++ @embedFile("g_blob") ++
    // Invoke the registered factories — after every shim, before the
    // `_system` delete, mirroring the worker's `_factories_invoke.js` with
    // one sim-shaped difference: the kv recorder is EPILOGUE-local (per
    // run), so `kv` is a call-time forwarder to whatever `globalThis.kv`
    // the epilogue has installed — exactly the late binding the ambient
    // reference used to provide. The other caps are the base recorders.
    "\n;(function () {" ++
    "\n  const reg = globalThis.__rove_factories;" ++
    "\n  const caps = {" ++
    "\n    http: _system.http," ++
    "\n    sched: _system.sched," ++
    "\n    kv: {" ++
    "\n      get: (k) => globalThis.kv.get(k)," ++
    "\n      set: (k, v) => globalThis.kv.set(k, v)," ++
    "\n      delete: (k) => globalThis.kv.delete(k)," ++
    "\n      prefix: (p, c, l) => globalThis.kv.prefix(p, c, l)," ++
    "\n    }," ++
    "\n    formats: __rove.formats," ++
    "\n  };" ++
    "\n  for (const name of Object.keys(reg)) {" ++
    "\n    globalThis[name] = reg[name](caps);" ++
    "\n  }" ++
    "\n})();" ++
    "\n;delete globalThis._system;\n";
