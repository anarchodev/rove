// Streamed static-upload module for the deploy app (routed at /v1/upload).
// onHeaders-only: pipe the raw inbound request body STRAIGHT into the target
// tenant's file-blobs (platform.scope(t).blob.receive — zero JS buffering, no
// chunk activations), then record the workspace entry. This is how large
// statics deploy without base64-buffering through the JS heap (which OOM'd).
//
// A separate module on purpose: a handler that exports onHeaders dispatches
// EVERY request headers-first, and from onHeaders the only body-accepting move
// is blob.receive — so the buffered JSON deploy routes (reset/file/cut) stay in
// index.mjs, and this module owns just the streamed PUT. It does its own auth
// (the dashboard _middlewares skips /v1/upload via PRE_AUTH_PATHS); genesis has
// no middleware and gates on the root token.
//
// PUT /v1/upload?tenant=X&path=Y&content_type=Z   (raw bytes as the body)
const WS = "_workspace/";

// Ownership (mirrors web/admin/index.mjs — duplicated rather than imported so
// this stays a standalone onHeaders module, incl. in the baked genesis bundle).
function ownsTenant(sub, tenant) {
  const hash = crypto.sha256(sub);
  const pre = "account/" + hash + "/instances/";
  return kv.prefix(pre, "", 1000).some((e) => e.key.slice(pre.length) === tenant);
}

// Returns the authorized actor ({ is_root } / { sub }) for `tenant`, or null
// after stamping the error response. Root token → operator; else an OIDC
// session that owns `tenant`.
function authFor(tenant) {
  const hdr = request.headers["authorization"] || "";
  const tok = hdr.indexOf("Bearer ") === 0 ? hdr.slice(7) : "";
  if (tok && platform.auth.checkRootToken(tok)) return { is_root: true };
  let sess = null;
  try { sess = oidc.rp("default").guard(); } catch (_) { sess = null; }
  if (sess && sess.sub) {
    if (sess.is_root || ownsTenant(sess.sub, tenant)) return sess;
    response.status = 403; return null;
  }
  response.status = 401; return null;
}

export function onHeaders() {
  const q = new URLSearchParams(request.query || "");
  const tenant = q.get("tenant");
  const path = q.get("path");
  const ct = q.get("content_type") || "";
  if (!tenant || !path) { response.status = 400; return "tenant + path required\n"; }
  if (!authFor(tenant)) return ""; // status already stamped (401/403)
  // Stream the body → target's file-blobs; onStored records the entry.
  platform.scope(tenant).blob.receive({
    to: "onStored",
    ctx: { tenant: tenant, path: path, content_type: ct },
  });
  return next();
}

export function onStored() {
  const ctx = request.ctx || {};
  const app = ctx.app || {};
  const ok = request.activation && request.activation.ok;
  if (!ok || !ctx.hash) {
    response.status = 502;
    return JSON.stringify({ ok: false, error: "receive failed" });
  }
  platform.scope(app.tenant).kv.set(WS + app.path, JSON.stringify({
    kind: "static", content_type: app.content_type || "", source_hex: ctx.hash,
  }));
  response.status = 200;
  response.headers = { "content-type": "application/json" };
  return JSON.stringify({ ok: true, path: app.path, hash: ctx.hash });
}
