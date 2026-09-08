// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// THE factory invoker — the one definition of which capabilities each
// shim factory receives, shared verbatim by all three engines: the
// worker (`globals.zig` installStatic), the CLI sim
// (`src/replay/sim_globals.zig` prelude), and the browser replay arena
// (`scripts/ops/gen_replay_prelude.py`). It runs after every shim has
// registered `__rove_factories.<name>` and before the engine deletes
// `_system`, while the natives are still reachable to assemble caps
// from.
//
// Subset-tolerant by design: each engine embeds only the shims it
// serves (the sim has no kv/config/console/textcodec shim — its kv is
// per-run and epilogue-installed), so an ORDER entry with no
// registration is skipped. The check runs the other way: a registered
// factory this file does not know is a loud error, because it would
// otherwise install with caps nobody decided. The worker's
// capability-template test is what catches a shim that silently failed
// to register there.
//
// Caps members are internal `_system.*` slices (the capability the shim
// wraps) or a namespace-rooted marker kv. Names that STAY ambient at
// the cutover (`crypto`, `time`, `console`, `TextDecoder`, …) are read
// ambiently by factory bodies — handing them through caps would claim
// an authority distinction that does not exist.
(function () {
  const reg = globalThis.__rove_factories;

  // A namespace-rooted kv view — the per-shim narrowing: every key the
  // holder spells resolves under `root`, so the holder structurally
  // cannot touch a row outside its namespace. Keys come back in the
  // holder's spelling (the root strips on the way out), so a prefix
  // page's last key round-trips as the next cursor. Call-time
  // forwarding to `globalThis.kv` keeps one text across the engines
  // (the sim's kv is per-run, epilogue-installed).
  const rooted = (root) => ({
    get: (k) => globalThis.kv.get(root + k),
    set: (k, v) => globalThis.kv.set(root + k, v),
    delete: (k) => globalThis.kv.delete(root + k),
    prefix: (p, c, l) =>
      (globalThis.kv.prefix(root + p, c == null || c === "" ? c : root + c, l) || [])
        .map((e) => ({ key: e.key.slice(root.length), value: e.value })),
  });

  // `sched` is constructed mid-walk and threaded to the durable-effect
  // shims below it in ORDER; it is never installed at a global.
  let sched = null;

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
      after: globalThis.after, formats: __rove.formats,
    }),
  };

  // Dependency order: the scheduler core precedes the shims that arm
  // through it; `after` precedes `blob` (blob.get composes on the
  // public after.fetch).
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
    globalThis[name] = out;
  }
  for (const name of Object.keys(reg)) {
    if (!(name in CAPS))
      throw new Error("factory with no caps entry: " + name);
  }
})();
