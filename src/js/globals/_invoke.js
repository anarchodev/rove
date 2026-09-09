// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// THE factory invoker — the one definition of which capabilities each
// shim factory receives, shared verbatim by all three engines: the
// worker (`globals.zig` installStatic), the CLI sim
// (`src/replay/sim_globals.zig` prelude), and the browser replay arena
// (`scripts/ops/gen_replay_prelude.py`).
//
// A FUNCTION EXPRESSION, not an IIFE: the engine evaluates this file to
// a value and CALLS it with the native `_system` holder. In the worker
// that holder is a detached object that is never a property of
// `globalThis` — an effect native cannot be named from handler code in
// any phase, so there is nothing to harden away (#861: not installing
// is the denial). The sim and arena build their recorder `_system` as a
// global for assembly, pass it in, and delete it before the base
// freezes — observationally the same surface.
//
// Post-cutover install rules (#861):
//   - A CAPABILITY name (`rove-reserved` CAPABILITY_NAMES) is NEVER
//     installed on `globalThis`. The constructed surface goes into the
//     persistent template `__rove.caps`, which `installRequest` (and
//     the offline activation builders) hand to every activation.
//     Naming one as a free variable is a ReferenceError.
//   - An ambient-STAYING name (`crypto`, `console`, the codecs, `time`)
//     installs on `globalThis` as before — pure computation and
//     web-platform standards are not authority.
//
// Subset-tolerant: each engine embeds only the shims it serves, so an
// ORDER entry with no registration is skipped (the sim's kv is per-run
// — its engine assigns `__rove.caps.kv` itself). A registered factory
// this file does not know is a loud error. The worker's
// capability-template test catches a worker shim that failed to
// register.
(function (_system) {
  const reg = globalThis.__rove_factories;

  // A namespace-rooted kv view — the per-shim narrowing: every key the
  // holder spells resolves under `root`, so the holder structurally
  // cannot touch a row outside its namespace. Keys come back in the
  // holder's spelling (the root strips on the way out), so a prefix
  // page's last key round-trips as the next cursor. Forwards at CALL
  // time to the template's kv — the one binding that exists in every
  // engine (the sim's is per-run, assigned by its epilogue).
  const rooted = (root) => {
    const kv = () => globalThis.__rove.caps.kv;
    return {
      get: (k) => kv().get(root + k),
      set: (k, v) => kv().set(root + k, v),
      delete: (k) => kv().delete(root + k),
      prefix: (p, c, l) =>
        (kv().prefix(root + p, c == null || c === "" ? c : root + c, l) || [])
          .map((e) => ({ key: e.key.slice(root.length), value: e.value })),
    };
  };

  // `sched` is constructed mid-walk and threaded to the durable-effect
  // shims below it in ORDER; it is never installed anywhere.
  let sched = null;
  // Constructed capability surfaces, gathered for the template.
  const built = {};

  const CAPS = {
    kv: () => ({ kv: _system.kv }),
    config: () => ({ config: _system.config }),
    console: () => ({ console: _system.console }),
    crypto: () => ({ crypto: _system.crypto }),
    http: () => ({ http: _system.http }),
    stream: () => ({ stream: _system.stream }),
    next: () => ({ next: _system.continuation.next }),
    after: () => ({ after: _system.after, http: _system.http }),
    TextEncoder: () => ({ textcodec: _system.textcodec }),
    TextDecoder: () => ({ textcodec: _system.textcodec }),
    __rove_request_proto: () => ({}),
    btoa: () => ({}),
    atob: () => ({}),
    base64url: () => ({}),
    hex: () => ({}),
    URLSearchParams: () => ({}),
    time: () => ({}),
    sched: () => ({ kv: rooted("_sched/"), formats: __rove.formats }),
    platform: () => ({
      platform: _system.platform, after: _system.after,
      blobReceive: _system.blob.receive, blobPresign: _system.blob.presign,
      sched: sched, kv: rooted("_dispatch/"), formats: __rove.formats,
    }),
    webhook: () => ({
      http: _system.http, sched: sched, kv: rooted("_send/"),
      formats: __rove.formats,
    }),
    blob: () => ({
      http: _system.http, blob: _system.blob, kv: rooted("_blob/"),
      after: built.after, formats: __rove.formats,
    }),
  };

  // The names that STAY on globalThis after the cutover — pure
  // computation and web-platform standards, plus the engine-internal
  // request prototype `installRequest` reads by name.
  const AMBIENT = new Set([
    "console", "crypto", "TextEncoder", "TextDecoder",
    "__rove_request_proto", "btoa", "atob", "base64url", "hex",
    "URLSearchParams", "time",
  ]);

  // Dependency order: the scheduler core precedes the shims that arm
  // through it; `after` precedes `blob` (blob.get composes on the
  // public after.fetch it receives via `built`).
  const ORDER = [
    "kv", "config", "console", "crypto", "http", "stream", "next",
    "after", "TextEncoder", "TextDecoder", "__rove_request_proto",
    "btoa", "atob", "base64url", "hex", "URLSearchParams", "time",
    "sched", "platform", "webhook", "blob",
  ];

  for (const name of ORDER) {
    if (!(name in reg)) continue; // this engine's subset lacks the shim
    const out = reg[name](CAPS[name]());
    if (name === "sched") { sched = out; continue; }
    built[name] = out;
    if (AMBIENT.has(name)) globalThis[name] = out;
  }
  for (const name of Object.keys(reg)) {
    if (!(name in CAPS))
      throw new Error("factory with no caps entry: " + name);
  }

  // The capability template — what `installRequest` (worker) and the
  // offline activation builders hand to every activation. MERGED, never
  // replaced: the offline engines install their native kv/config onto
  // this same object (before or after this runs — both orders hold), so
  // assignment is member-wise and an existing member is engine-owned.
  const caps = globalThis.__rove.caps || (globalThis.__rove.caps = {});
  for (const name of ORDER) {
    if (AMBIENT.has(name) || name === "sched") continue;
    if (name in built) caps[name] = built[name];
  }
})
