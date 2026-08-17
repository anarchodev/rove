// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Public `export` verb — take a copy of this tenant's data out (rove#340).
//
// The same composition `webhook.send` uses, deliberately: a durable kv marker
// written from ordinary handler context, plus a scheduled wake aimed at a
// baked `__system/*` module that does the work. No new primitive, no door, no
// engine-side job registry — starting an export is two ordinary writes.
//
// Pure composition over `kv` + `crypto` (+ `blob` for links). The same verbs
// run cross-tenant from the `__admin__` dashboard via {@link forScope}: a
// `platform.scope(t)` handle carries `kv`/`blob` twins of the ambient
// globals, and the rows written through them are identical — the engine arms
// the target tenant's durable wake at commit (the target-envelope sched-write
// arm; `worker_dispatch.appendTargetSchedWakeCmds` and the apply observer's
// `_sched/by_time/` branch are the two halves).
//
// Storage (ordinary tenant kv; `_export/` is shim-writable, so a customer
// *could* write these, affecting only their own tenant — the same posture as
// `_sched/` and `_send/`):
//   _export/{id} -> {format, state, cursor, parts[], bytes, entries, ...}
//
// ## What the job never sees
//
// The exported VALUES never pass through a handler. `__system/export_run`
// issues a Cmd that the engine rewrites into a content-addressed PUT, so the
// bytes go store → S3 directly; what comes back is a cursor and a digest.
// The naive shape — a handler looping `kv.prefix` — would record the entire
// store onto the request tape and bill the tenant's own log-ingest budget for
// the export (rove#391's defect at export scale).
//
// ## The artifact (format 2)
//
// A SET of content-addressed parts plus the record above, never one object: a
// write chain caps at 64 MiB while a tenant may hold a plan's whole
// `max_kv_bytes`. `get(id).parts` is the manifest, in store order; each entry
// is `{hash, bytes, entries, kind?}` where `kind` absent means a KV JSONL
// part and `kind: "bundle"` is the deployed-code slice — the raw deployment
// manifest, whose per-file source hashes presign out of the tenant's
// immutable `file-blobs/` via `blob.fileUrl`. Concatenating the KV parts in
// order reproduces the KV JSONL exactly. Bytecode is deliberately not
// exported — it is platform-internal and reproducible from the sources the
// bundle names. Markers written before format 2 lack the `format` field;
// `get`/`links` never key on it.
//
// Parts land in the tenant's `exports/` pool, which is UNMETERED (rove#429):
// charging an export against `max_stored_bytes` would deny it to a tenant at
// its cap — the one most likely to be leaving, and the case #313's "always be
// able to get their data out" is about. The pool is swept with the tenant at
// teardown, so unmetered does not mean unbounded.

function _key(id) {
  return "_export/" + id;
}

// Durable-scheduler arm against an arbitrary kv handle — the exact `_sched/`
// rows globals/schedule.js writes (and `__system/export_run`'s inlined
// re-arm), spelled here so a scoped handle can carry them cross-tenant. The
// sched id derives from the idempotency key (`sha256b64url(key)`), which is
// what lets the job's own watchdog re-arm MOVE this entry rather than
// accumulate one per attempt.
const SCHED_TICK_NS = 1_000_000_000n;
function _schedByTimeKey(whenNs, id) {
  return "_sched/by_time/" + String(whenNs).padStart(20, "0") + "/" + id;
}
function _schedArm(kvh, whenNs, target, msg, key) {
  const rounded = whenNs <= 0n ? 0n
    : ((whenNs + SCHED_TICK_NS - 1n) / SCHED_TICK_NS) * SCHED_TICK_NS;
  const id = crypto.sha256b64url(key);
  const byIdKey = "_sched/by_id/" + id;
  const prev = kvh.get(byIdKey);
  if (prev !== null) {
    try {
      const old = JSON.parse(prev);
      const oldWhen = BigInt(old.when_ns);
      if (oldWhen !== rounded) kvh.delete(_schedByTimeKey(oldWhen, id));
    } catch (_e) { /* corrupt prior record — overwrite below */ }
  }
  const rec = { when_ns: String(rounded), target: target, msg: msg, key: key };
  kvh.set(byIdKey, JSON.stringify(rec));
  kvh.set(_schedByTimeKey(rounded, id), "");
  return id;
}

function _start(kvh, opts) {
  const id = crypto.randomUUID();
  // The marker IS the job: `export_run` reads it on every activation and
  // no-ops when it is absent, so writing it is what makes the export exist.
  // Written BEFORE the wake is armed — a wake that fired first would find
  // nothing and drop the chain.
  kvh.set(_key(id), JSON.stringify({
    format: 2,
    state: "running",
    cursor: "",
    parts: [],
    // The code slice is on by default: a leaving customer wants bytes, and
    // a kv-only artifact is the OPT-OUT ({bundle: false}), not the default.
    bundle_requested: !(opts && opts.bundle === false),
    started_at: Date.now(),
  }));
  _schedArm(kvh, BigInt(Date.now()) * 1_000_000n, "__system/export_run",
    { id: id }, _key(id));
  return id;
}

function _get(kvh, id) {
  if (typeof id !== "string" || id.length === 0) return null;
  const raw = kvh.get(_key(id));
  if (raw === null) return null;
  try {
    return JSON.parse(raw);
  } catch (_e) {
    return null;
  }
}

function _links(kvh, blobh, id, opts) {
  const st = _get(kvh, id);
  if (st === null || !Array.isArray(st.parts)) return [];
  // `blob.exportUrl`, not `blob.url`: parts live in the unmetered `exports/`
  // pool rather than the tenant's own `app-blobs/` (rove#429), so that a
  // tenant at its storage cap can still produce and fetch an export.
  return st.parts.map((p) => blobh.exportUrl(p.hash, opts));
}

/**
 * Start an export of this tenant's data — the KV store, plus (by default)
 * the deployed code bundle. Returns immediately with an id; the walk runs as
 * a durable background job across many activations.
 *
 * At-least-once by construction — a part may be produced twice, and because
 * parts are content-addressed a repeat yields the identical object.
 *
 * @param {object} [opts]
 * @param {boolean} [opts.bundle] - Include the deployed-code slice
 *   (default true). `false` produces a kv-only artifact.
 * @returns {string} The export id, for {@link get}.
 *
 * @example
 * const id = start();
 * // ...later, from another request
 * const st = get(id);
 * if (st.state === "done") {
 *   const urls = links(id);
 * }
 */
export function start(opts) {
  return _start(kv, opts);
}

/**
 * Read an export's progress, or its finished manifest.
 *
 * @param {string} id - The id {@link start} returned.
 * @returns {?object} `null` when there is no such export. Otherwise
 *   `{format, state, parts, bytes, entries, ...}`, where `state` is
 *   `"running"`, `"done"`, or `"failed"` (with `error` naming why), and
 *   `parts` is `[{hash, bytes, entries, kind?}]` in store order — the
 *   manifest. {@link links} turns those hashes into download URLs.
 */
export function get(id) {
  return _get(kv, id);
}

/**
 * Download links for a finished export — one presigned URL per part, in
 * store order. Concatenating the KV parts in this order reproduces the KV
 * JSONL exactly; a `kind: "bundle"` part is the deployment manifest.
 *
 * @param {string} id - The id {@link start} returned.
 * @param {object} [opts]
 * @param {number} [opts.ttl] - Link validity in seconds (default 300,
 *   max 604800 = 7 days).
 * @returns {string[]} Empty when the export does not exist or has produced
 *   no parts yet, so a caller can render progress without special-casing.
 */
export function links(id, opts) {
  return _links(kv, blob, id, opts);
}

/**
 * The same three verbs bound to a `platform.scope(t)` handle, so the
 * `__admin__` dashboard runs a customer's export FOR them (admin-only — the
 * scope handle itself throws elsewhere). `scope.kv` writes ride the batch's
 * target envelope and the engine arms the target tenant's durable wake at
 * commit, so a cross-tenant `start` behaves identically to a self-start.
 *
 * @param {object} scope - A `platform.scope(t)` handle (`{kv, blob}`).
 * @returns {{start, get, links}} The bound verbs.
 *
 * @example
 * const exp = forScope(platform.scope(instance_id));
 * const id = exp.start();          // later: exp.get(id), exp.links(id)
 */
export function forScope(scope) {
  return {
    start: (opts) => _start(scope.kv, opts),
    get: (id) => _get(scope.kv, id),
    links: (id, opts) => _links(scope.kv, scope.blob, id, opts),
  };
}

export default { start, get, links, forScope };
