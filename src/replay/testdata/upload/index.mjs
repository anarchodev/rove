// Streamed static-upload module (mirrors admin/v1/upload in rewind-apps): an
// onHeaders-only handler that authenticates, then pipes the raw inbound body
// STRAIGHT into the target tenant's blobs via `platform.scope(t).blob.receive`
// (zero JS buffering, no chunk activations) and records the workspace entry from
// the receive's `onStored` continuation. This is the headers-first + blob.receive
// path — both legs were undriveable before the harness gained
// `scenario.inboundHeaders` + `node.receive().stored()`.
//
// PUT /v1/upload?tenant=X&path=Y&content_type=Z  (raw bytes as the body)
const WS = "_workspace/";

export function onHeaders({ next, platform }) {
  const q = new URLSearchParams(request.query || "");
  const tenant = q.get("tenant");
  const path = q.get("path");
  const ct = q.get("content_type") || "";
  if (!tenant || !path) { response.status = 400; return "tenant + path required\n"; }
  // Operator auth (the genesis path — no session). The verdict is
  // engine-computed; the bearer is unreachable here by construction.
  if (!request.rewind.isRoot) { response.status = 401; return "unauthorized\n"; }
  // Stream the body → target's blobs; onStored records the entry, threading
  // {tenant, path, content_type} across the receive re-entry as `request.ctx.app`.
  platform.scope(tenant).blob.receive({
    on: "onStored",
    ctx: { tenant: tenant, path: path, content_type: ct },
  });
  return next();
}

export function onStored({ kv, platform }) {
  const ctx = request.ctx || {};
  const app = ctx.app || {};
  // A completed receive resumes as a BOUND fetch_chunk — record the surface
  // the worker actually delivers so the fold can't drift back to a bespoke
  // shape (kind "fetch_chunk", the top-level `done` flatten).
  kv.set("probe/resume", JSON.stringify({
    kind: request.activation && request.activation.kind,
    done: request.done,
  }));
  // blob.receive completion: 2xx = stored, status 0 = failed (no
  // request.ok — status is the single signal).
  const ok = request.status >= 200 && request.status < 300;
  if (!ok || !ctx.hash) {
    response.status = 502;
    return JSON.stringify({ ok: false, error: "receive failed" });
  }
  platform.scope(app.tenant).kv.set(WS + app.path, JSON.stringify({
    kind: "static", content_type: app.content_type || "", source_hex: ctx.hash, len: ctx.len,
  }));
  response.status = 200;
  response.headers = { "content-type": "application/json" };
  return JSON.stringify({ ok: true, path: app.path, hash: ctx.hash });
}
