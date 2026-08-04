// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Public `export` verb — take a copy of this tenant's data out (rove#340).
//
// The same composition `webhook.send` uses, deliberately: a durable kv marker
// written from ordinary handler context, plus a scheduled wake aimed at a
// baked `__system/*` module that does the work. No new primitive, no door, no
// engine-side job registry — starting an export is two ordinary writes.
//
// Pure composition over `kv` + `crypto` + `@rewind/schedule`.
//
// Storage (ordinary tenant kv; `_export/` is shim-writable, so a customer
// *could* write these, affecting only their own tenant — the same posture as
// `_sched/` and `_send/`):
//   _export/{id} -> {state, cursor, parts[], bytes, entries, ...}
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
// ## The artifact
//
// A SET of content-addressed parts plus the record above, never one object: a
// write chain caps at 64 MiB while a tenant may hold a plan's whole
// `max_kv_bytes`. `get(id).parts` is the manifest, in store order;
// `blob.url(part.hash)` presigns each part, so the download links compose
// from the primitive that already serves content-addressed bytes.

import schedule from "@rewind/schedule";

function _key(id) {
  return "_export/" + id;
}

/**
 * Start an export of this tenant's KV. Returns immediately with an id; the
 * walk runs as a durable background job across many activations.
 *
 * At-least-once by construction — a part may be produced twice, and because
 * parts are content-addressed a repeat yields the identical object.
 *
 * @returns {string} The export id, for {@link get}.
 *
 * @example
 * const id = start();
 * // ...later, from another request
 * const st = get(id);
 * if (st.state === "done") {
 *   const links = st.parts.map((p) => blob.url(p.hash));
 * }
 */
export function start() {
  const id = crypto.randomUUID();
  // The marker IS the job: `export_run` reads it on every activation and
  // no-ops when it is absent, so writing it is what makes the export exist.
  // Written BEFORE the wake is armed — a wake that fired first would find
  // nothing and drop the chain.
  kv.set(_key(id), JSON.stringify({
    state: "running",
    cursor: "",
    parts: [],
    started_at: Date.now(),
  }));
  // Keyed on the marker so the job's own watchdog re-arms MOVE this entry
  // rather than accumulating one per attempt.
  schedule({ in: 0 }, "__system/export_run", { id: id }, { key: _key(id) });
  return id;
}

/**
 * Read an export's progress, or its finished manifest.
 *
 * @param {string} id - The id {@link start} returned.
 * @returns {?object} `null` when there is no such export. Otherwise
 *   `{state, parts, bytes, entries, ...}`, where `state` is `"running"` or
 *   `"done"` and `parts` is `[{hash, bytes, entries}]` in store order — the
 *   manifest. Pass each `hash` to `blob.url` for a download link.
 */
export function get(id) {
  if (typeof id !== "string" || id.length === 0) return null;
  const raw = kv.get(_key(id));
  if (raw === null) return null;
  try {
    return JSON.parse(raw);
  } catch (_e) {
    return null;
  }
}

export default { start, get };
