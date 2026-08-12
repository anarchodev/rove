// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The kv write guardrails, as ONE implementation shared by every offline
// engine (rove#502).
//
// The worker enforces these in Zig at the `kv.set` / `kv.delete` natives —
// that is the un-bypassable point and it stays there. What must not also be
// true is that each OFFLINE engine re-states the same rules in its own JS:
// the sim + native replay had a copy in `src/replay/epilogue.zig` and the
// browser arena had none at all, so a handler writing a reserved key threw
// in one engine and succeeded in another. Replay's whole claim is that the
// handler executes the same interactions; a guard that fires in one engine
// and not another breaks that claim in the worst direction, since the
// permissive engine makes a run look successful where the real one refused.
//
// This file is the rules. It installs nothing and reads no globals it does
// not declare below — each engine wires `__kvGuardWrite` into its own kv
// path, because where the guard sits differs (the sim's recording wrapper
// calls it inline; the arena wraps the WASM host binding with it).
//
// ## Required data globals
//
// The VALUES are not here. They are generated from the Zig source of truth
// by each engine's prelude builder — `epilogue.zig` at comptime, and
// `scripts/ops/gen_replay_prelude.py` for the arena — so a cap or a prefix
// changes in one place:
//
//   __SHIM_WRITABLE   string[]  reserved prefixes a shim may still write
//                               (rove-reserved's SHIM_WRITABLE_PREFIXES)
//   __KV_KEY_MAX      number    bytes (kv/snapshot_stream STREAM_KEY_MAX)
//   __KV_VAL_MAX      number    bytes (kv/snapshot_stream STREAM_VAL_MAX)
//
// Sharing the rules but generating the data is deliberate: the data has a
// single authority in Zig and no reason to be transcribed, while the rules
// are logic that cannot be generated from a constant and would otherwise be
// written once per engine — which is exactly how they drifted.

// UTF-8 byte COUNT without materializing the encoded array: the worker
// measures bytes, and running a 1 MiB value through TextEncoder just to
// learn its length would blow the request arena. Mirrors the encoder's
// output including WTF-8 lone surrogates.
const __utf8Len = (s) => {
  s = String(s == null ? "" : s);
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    let cp = s.charCodeAt(i);
    if (cp >= 0xD800 && cp <= 0xDBFF) {
      const lo = i + 1 < s.length ? s.charCodeAt(i + 1) : 0;
      if (lo >= 0xDC00 && lo <= 0xDFFF) { cp = 0x10000; i++; }
    }
    if (cp < 0x80) n += 1;
    else if (cp < 0x800) n += 2;
    else if (cp < 0x10000) n += 3;
    else n += 4;
  }
  return n;
};

// The whole leading-`_` keyspace is platform-reserved against customer
// writes, minus the prefixes the JS shims must write from handler context.
// Reserving the namespace rather than an enumerated list is what lets a new
// platform `_…/` family appear without colliding with customer data.
const __kvReserved = (k) => {
  if (k.length === 0 || k[0] !== "_") return false;
  for (const p of __SHIM_WRITABLE) if (k.startsWith(p)) return false;
  return true;
};

const __kvErr = (message, code) => { const e = new Error(message); e.code = code; return e; };

const __kvCoerce = (x, what) => {
  if (x === null || x === undefined || typeof x === "object" || typeof x === "function") {
    throw new TypeError("kv: " + what + " must be a string (or number/boolean/bigint); JSON.stringify objects explicitly");
  }
  return String(x);
};

// Order matches the worker's: coerce key type, coerce value type,
// reserved-prefix, then size (key reported before value). The ORDER is part
// of what is shared, not an incidental detail — a key that breaks two rules
// at once must report the same one everywhere, or the engines disagree about
// an error the customer sees.
//
// `isExempt` is the one genuinely per-engine decision, so it is injected
// rather than assumed: the sim namespaces every store behind a prefix and
// exempts its own bookkeeping writes, and the arena has no such prefix.
// Coercion still applies to an exempt key — a non-string key is a type error
// wherever it is written.
const __kvGuardWrite = (k, hasVal, val, isExempt) => {
  const ks = __kvCoerce(k, "key");
  const vs = hasVal ? __kvCoerce(val, "value") : "";
  if (!(isExempt && isExempt(ks))) {
    if (__kvReserved(ks)) throw __kvErr("kv: '" + ks + "' is in a platform-reserved prefix", "reserved_key");
    if (__utf8Len(ks) > __KV_KEY_MAX) throw __kvErr("kv: key exceeds the " + __KV_KEY_MAX + "-byte limit", "key_too_large");
    if (hasVal && __utf8Len(vs) > __KV_VAL_MAX) throw __kvErr("kv: value exceeds the " + __KV_VAL_MAX + "-byte limit", "value_too_large");
  }
  return ks;
};
