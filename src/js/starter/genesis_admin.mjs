// Standing __admin__ deploy app — per-file WORKSPACE deploy. Files are
// uploaded ONE AT A TIME into a durable per-tenant workspace, then a release
// is CUT from whatever's currently in the workspace. This replaces the old
// single mega-POST (it base64-buffered the whole bundle in the JS heap and hit
// QuickJS's per-context memory limit — InternalError: out of memory — on any
// real static-bearing bundle). Per-file keeps each request small.
//
// Workspace model: `scope(t).kv` holds `_workspace/{path}` → the staged
// manifest entry (kind, content_type, source_hex, bytecode_hex). The bytes are
// content-addressed in S3 via `blob.put` (statics) / `platform.compile`
// (handlers → source + bytecode blobs). `cut` reads the workspace + stamps a
// manifest (the immutable deployment). Activation stays separate + gated
// (`/_system/release`).
//
// This is the bootstrap/break-glass app (root-token only); the standing
// web/admin app owns the same surface + ownership-gating once deployed.
//
// Wire (root bearer, POST JSON):
//   /v1/deploy/reset  {tenant}                              → clear workspace
//   /v1/deploy/file   {tenant, path, kind, source | b64,
//                      content_type?}                       → stage one file
//   /v1/deploy/cut    {tenant}                              → {ok, dep_id}

const WS = "_workspace/";

function jerr(status, msg) {
  response.status = status;
  return JSON.stringify({ ok: false, error: msg });
}

// Clear the workspace so a `deploy <bundle>` means EXACTLY that bundle (no
// carry-forward of files a prior deploy left behind).
function wsReset(b) {
  if (!b.tenant) return jerr(400, "tenant required");
  const sk = platform.scope(b.tenant).kv;
  const rows = sk.prefix(WS, "", 1000);
  for (let i = 0; i < rows.length; i++) sk.delete(rows[i].key);
  return JSON.stringify({ ok: true, cleared: rows.length });
}

// Stage one HANDLER into the workspace: compile (async, bound); onFileStaged
// records the entry once the source+bytecode blobs are staged. STATICS do not
// come through here — they stream straight to S3 via PUT /v1/upload
// (scope(t).blob.receive), which records their workspace entry directly.
function wsFile(b) {
  if (!b.tenant || !b.path) return jerr(400, "tenant + path required");
  if (b.kind !== "handler")
    return jerr(400, "kind must be 'handler' (statics stream via PUT /v1/upload)");
  platform.compile([{ path: b.path, source: b.source || "" }], {
    scope: b.tenant, name: "onFileStaged",
    ctx: { target: b.tenant, path: b.path, content_type: b.content_type || "" },
  });
  return next();
}

export function onFileStaged() {
  const ctx = request.ctx;
  if (!ctx || !ctx.ok) {
    response.status = 500;
    return JSON.stringify({ stage: "compile", ctx: ctx || null });
  }
  const app = ctx.app || {};
  const r = ctx.results[0];
  platform.scope(app.target).kv.set(WS + app.path, JSON.stringify({
    kind: "handler", content_type: app.content_type || "",
    source_hex: r.source_hex, bytecode_hex: r.bytecode_hex,
  }));
  response.status = 200;
  return JSON.stringify({ ok: true, path: app.path, hash: r.source_hex });
}

// Cut a release from whatever is in the workspace → stampManifest (the staging
// barrier) → dep_id. Does NOT activate (that's the separate /_system/release).
function wsCut(b) {
  if (!b.tenant) return jerr(400, "tenant required");
  const rows = platform.scope(b.tenant).kv.prefix(WS, "", 1000);
  if (rows.length === 0) return jerr(400, "workspace empty — nothing to cut");
  const entries = rows.map(function (row) {
    const e = JSON.parse(row.value);
    return {
      path: row.key.slice(WS.length), kind: e.kind,
      content_type: e.content_type || "",
      source_hex: e.source_hex, bytecode_hex: e.bytecode_hex || "",
    };
  });
  platform.scope(b.tenant).deploy.stampManifest(entries, { name: "onCut" });
  return next();
}

export function onCut() {
  response.status = 200;
  return JSON.stringify(request.ctx); // { ok, dep_id }
}

export default function () {
  if (request.method !== "POST") {
    response.status = 405;
    return "POST only\n";
  }
  const auth = request.headers["authorization"] || "";
  const tok = auth.indexOf("Bearer ") === 0 ? auth.slice(7) : "";
  if (!platform.auth.checkRootToken(tok)) {
    response.status = 401;
    return "unauthenticated\n";
  }
  let b;
  try { b = JSON.parse(request.body); }
  catch (e) { return jerr(400, "expected JSON body"); }
  const p = request.path;
  if (p === "/v1/deploy/reset") return wsReset(b);
  if (p === "/v1/deploy/file") return wsFile(b);
  if (p === "/v1/deploy/cut") return wsCut(b);
  return jerr(404, "unknown deploy route");
}
