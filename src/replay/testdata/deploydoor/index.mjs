// Admin deploy door module (mirrors admin/v1/deploy in rewind-apps + the
// in-repo `src/js/starter/genesis_admin.mjs`): the two RESULT-IN-CTX bound door
// ops whose completion lands on `request.ctx`, not `request.body` —
//   • `platform.compile(files, {on})`  → resumes at `on` with
//       `request.ctx = {ok, results:[{path, source_hex, bytecode_hex}], app}`
//     (`app` echoes the issue-time `{ctx}`).
//   • `platform.scope(t).deploy.stampManifest(entries, {on})` → resumes at `on`
//     with `request.ctx = {ok, dep_id}`.
//
// Before the harness gained `node.compile().staged()` / `node.stampManifest().cut()`,
// both resumes were undriveable — a plain `fetch().resolve()` hands
// the resume the fetch's ISSUE-TIME ctx instead of the door result, so
// `onFileStaged` / `onCut` were asserted only up to the door emission.
//
// POST /v1/deploy/file  { tenant, path, source }              → compile → onFileStaged
// POST /v1/deploy/pkg   { tenant, pkg_hash, path, source }    → compile → onPkgStaged
// POST /v1/deploy/cut   { tenant }                            → stampManifest → onCut
const WS = "_workspace/";
const WSPKG = "_workspace_pkg/";

function jerr(status, msg) {
  response.status = status;
  return JSON.stringify({ error: msg });
}

// Stage one HANDLER file: compile → content-address into the target's blobs,
// record the workspace entry from the `onFileStaged` continuation.
// `platform` and `next` are threaded rather than ambient: a module-scope
// helper has no activation to receive them from, so the export that
// routes to it hands them over.
function deployFile(platform, next, b) {
  if (!b.tenant || !b.path) return jerr(400, "tenant + path required");
  platform.compile([{ path: b.path, source: b.source || "" }], {
    scope: b.tenant,
    on: "onFileStaged",
    ctx: { target: b.tenant, path: b.path, content_type: b.content_type || "" },
  });
  return next();
}

export function onFileStaged({ platform }) {
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

// Stage one PACKAGE file: compiled under the package's module identity, keyed
// on `onPkgStaged` — a SECOND compile door in the same handler class, so the
// harness `compile({on})` selector is exercised.
function deployPkg(platform, next, b) {
  if (!b.tenant || !b.pkg_hash || !b.path)
    return jerr(400, "tenant + pkg_hash + path required");
  platform.compile([{ path: b.path, source: b.source || "" }], {
    scope: b.tenant, pkg_hash: b.pkg_hash,
    on: "onPkgStaged",
    ctx: { target: b.tenant, pkg_hash: b.pkg_hash, path: b.path },
  });
  return next();
}

export function onPkgStaged({ platform }) {
  const ctx = request.ctx;
  if (!ctx || !ctx.ok) {
    response.status = 500;
    return JSON.stringify({ stage: "pkg-compile", ctx: ctx || null });
  }
  const app = ctx.app || {};
  const r = ctx.results[0];
  platform.scope(app.target).kv.set(WSPKG + app.pkg_hash + "/" + app.path, JSON.stringify({
    source_hex: r.source_hex, bytecode_hex: r.bytecode_hex,
  }));
  response.status = 200;
  return JSON.stringify({ ok: true, pkg_hash: app.pkg_hash, path: app.path });
}

// Cut a release: assemble the manifest from the workspace → stampManifest (the
// staging barrier) → dep_id resumes at `onCut`.
function deployCut(platform, next, b) {
  if (!b.tenant) return jerr(400, "tenant required");
  const sk = platform.scope(b.tenant).kv;
  const rows = sk.prefix(WS, "", 1000);
  if (rows.length === 0) return jerr(400, "workspace empty — nothing to cut");
  const entries = rows.map(function (row) {
    const e = JSON.parse(row.value);
    return {
      path: row.key.slice(WS.length), kind: e.kind,
      content_type: e.content_type || "",
      source_hex: e.source_hex, bytecode_hex: e.bytecode_hex || "",
    };
  });
  platform.scope(b.tenant).deploy.stampManifest(entries, { on: "onCut" });
  return next();
}

export function onCut() {
  const ctx = request.ctx;
  if (!ctx || !ctx.ok) {
    response.status = 500;
    return JSON.stringify({ stage: "stamp", ctx: ctx || null });
  }
  response.status = 200;
  return JSON.stringify(ctx); // { ok, dep_id }
}

export default function ({ platform, next }) {
  if (request.method !== "POST") { response.status = 405; return "POST only\n"; }
  // Engine-computed operator-root verdict; the bearer is stripped from
  // request.headers on a platform-bound handler so it can't reach the tape.
  if (!request.rewind.isRoot) {
    response.status = 401;
    return "unauthorized\n";
  }
  const b = request.json || {};
  switch (request.path) {
    case "/v1/deploy/file": return deployFile(platform, next, b);
    case "/v1/deploy/pkg": return deployPkg(platform, next, b);
    case "/v1/deploy/cut": return deployCut(platform, next, b);
    default: response.status = 404; return "not found\n";
  }
}
