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
//   /v1/deploy/reset   {tenant}                             → clear workspace
//   /v1/deploy/file    {tenant, path, kind, source | b64,
//                       content_type?, resolution?}         → stage one file
//   /v1/deploy/pkgfile {tenant, pkg_hash, path, source,
//                       resolution?}                        → stage one PACKAGE file
//   /v1/deploy/cut     {tenant, resolution?}                → {ok, dep_id}
//
// Packages (PM P1): stage each package file via /pkgfile (compiled under
// its /pkg/<pkg_hash>/ virtual name; dep-bearing packages pass their own
// `resolution` so imports validate at compile — leaves first). Handler
// files that import packages pass the deploy's `resolution` on /file.
// `cut` takes the lockfile `resolution` = {packages:[{spec, version,
// pkg_hash, imports}], app_imports} — package `files` are filled in
// server-side from the staged _workspace_pkg rows, then the whole thing
// bakes into the manifest v2 sections.

const WS = "_workspace/";
const WSPKG = "_workspace_pkg/";

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
  const prows = sk.prefix(WSPKG, "", 1000);
  for (let i = 0; i < prows.length; i++) sk.delete(prows[i].key);
  return JSON.stringify({ ok: true, cleared: rows.length + prows.length });
}

// Stage one HANDLER into the workspace: content-address its source; the
// bundle COMPILES at cut. A file is not compiled here because compilation
// resolves imports eagerly, so a handler that imports a sibling could only be
// compiled after every sibling had been uploaded — and mid-upload the bundle
// is merely incomplete, not wrong (rove#344). STATICS do not come through
// here — they stream straight to S3 via PUT /v1/upload (scope(t).blob.receive),
// which records their workspace entry directly.
function wsFile(b) {
  if (!b.tenant || !b.path) return jerr(400, "tenant + path required");
  if (b.kind !== "handler")
    return jerr(400, "kind must be 'handler' (statics stream via PUT /v1/upload)");
  platform.stage([{ path: b.path, source: b.source || "" }], {
    scope: b.tenant, on: "onFileStaged",
    ctx: { target: b.tenant, path: b.path, content_type: b.content_type || "" },
  });
  return next();
}

// Stage one PACKAGE file: compiled under /pkg/<pkg_hash>/<path> (its
// module identity), recorded under _workspace_pkg/{pkg_hash}/{path} so
// `cut` can assemble the manifest's packages[].files.
function wsPkgFile(b) {
  if (!b.tenant || !b.pkg_hash || !b.path)
    return jerr(400, "tenant + pkg_hash + path required");
  const copts = {
    scope: b.tenant, pkg_hash: b.pkg_hash, on: "onPkgStaged",
    ctx: { target: b.tenant, pkg_hash: b.pkg_hash, path: b.path },
  };
  if (b.resolution !== undefined) copts.resolution = b.resolution;
  platform.compile([{ path: b.path, source: b.source || "" }], copts);
  return next();
}

export function onPkgStaged() {
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
  return JSON.stringify({
    ok: true, pkg_hash: app.pkg_hash, path: app.path,
    source_hex: r.source_hex, bytecode_hex: r.bytecode_hex,
  });
}

export function onFileStaged() {
  const ctx = request.ctx;
  if (!ctx || !ctx.ok) {
    response.status = 500;
    return JSON.stringify({ stage: "stage", ctx: ctx || null });
  }
  const app = ctx.app || {};
  const r = ctx.results[0];
  // No bytecode_hex yet — cut compiles the bundle and fills it in.
  platform.scope(app.target).kv.set(WS + app.path, JSON.stringify({
    kind: "handler", content_type: app.content_type || "",
    source_hex: r.source_hex,
  }));
  response.status = 200;
  return JSON.stringify({ ok: true, path: app.path, hash: r.source_hex });
}

// Cut a release from whatever is in the workspace: COMPILE the staged
// handlers as one bundle, then stampManifest (the staging barrier) → dep_id.
// Does NOT activate (that's the separate /_system/release).
//
// Compiling here rather than per upload is what lets a handler import a
// sibling: only now is the whole bundle present, and compilation resolves
// every import eagerly (rove#344). It is also where a bad import fails — the
// compile error names the file.
function wsCut(b) {
  if (!b.tenant) return jerr(400, "tenant required");
  const sk = platform.scope(b.tenant).kv;
  const rows = sk.prefix(WS, "", 1000);
  if (rows.length === 0) return jerr(400, "workspace empty — nothing to cut");
  const handlers = [];
  for (let i = 0; i < rows.length; i++) {
    const e = JSON.parse(rows[i].value);
    if (e.kind === "handler")
      handlers.push({ path: rows[i].key.slice(WS.length), source_hash: e.source_hex });
  }
  if (handlers.length === 0) return cutStamp(b, {});  // statics-only bundle
  // Compile against the SERVER-authoritative resolution (the join below), not
  // the client's lockfile: the engine needs each package file's staged
  // bytecode hash to load it, and validating against anything other than what
  // the manifest will record would validate the wrong thing.
  const res = buildResolution(sk, b);
  if (res && res.error) return jerr(400, res.error);
  const copts = {
    scope: b.tenant, on: "onBundleCompiled",
    // The client's lockfile has to survive the compile hop to reach the stamp.
    ctx: { target: b.tenant, resolution: b.resolution === undefined ? null : b.resolution },
  };
  if (res) copts.resolution = res;
  platform.compile(handlers, copts);
  return next();
}

// The bundle compiled: fold each handler's bytecode hash into its workspace
// row, then stamp.
export function onBundleCompiled() {
  const ctx = request.ctx;
  if (!ctx || !ctx.ok) {
    // A compile failure here is the author's — a syntax error or an import
    // that resolves to nothing. Relay it with the status the engine chose so
    // it reads as a bad bundle, not a broken deploy service.
    response.status = (ctx && ctx.status) || 500;
    return JSON.stringify({ stage: "compile", ctx: ctx || null });
  }
  const app = ctx.app || {};
  const bc = {};
  for (let i = 0; i < ctx.results.length; i++) bc[ctx.results[i].path] = ctx.results[i].bytecode_hex;
  return cutStamp(
    { tenant: app.target, resolution: app.resolution === null ? undefined : app.resolution },
    bc,
  );
}

// Assemble the manifest from the workspace + the just-compiled bytecode
// hashes (`bc`, path → bytecode_hex) and stamp it.
function cutStamp(b, bc) {
  const sk = platform.scope(b.tenant).kv;
  const rows = sk.prefix(WS, "", 1000);
  const entries = rows.map(function (row) {
    const e = JSON.parse(row.value);
    const path = row.key.slice(WS.length);
    return {
      path: path, kind: e.kind,
      content_type: e.content_type || "",
      source_hex: e.source_hex, bytecode_hex: bc[path] || e.bytecode_hex || "",
    };
  });
  const sopts = { on: "onCut" };
  const res = buildResolution(sk, b);
  if (res && res.error) return jerr(400, res.error);
  if (res) sopts.resolution = res;
  platform.scope(b.tenant).deploy.stampManifest(entries, sopts);
  return next();
}

// PM P1: join the client's lockfile (spec/version/pkg_hash/imports) with the
// server-staged package files — hashes stay server-authoritative (recorded by
// onPkgStaged). The SAME resolution feeds the cut compile and the manifest, so
// a handler's `@scope/pkg` import validates against exactly the package files
// the deployment will record. Returns null when the deploy has no packages, or
// `{error}` when a declared package was never staged.
function buildResolution(sk, b) {
  if (b.resolution === undefined) return null;
  const res = { packages: [], app_imports: b.resolution.app_imports || {} };
  const pkgs = b.resolution.packages || [];
  for (let i = 0; i < pkgs.length; i++) {
    const p = pkgs[i];
    const staged = sk.prefix(WSPKG + p.pkg_hash + "/", "", 1000);
    if (staged.length === 0)
      return { error: "package " + p.spec + "@" + p.version + " has no staged files" };
    const files = staged.map(function (row) {
      const f = JSON.parse(row.value);
      return {
        path: row.key.slice((WSPKG + p.pkg_hash + "/").length),
        source_hash: f.source_hex, bytecode_hash: f.bytecode_hex,
      };
    });
    res.packages.push({
      spec: p.spec, version: p.version, pkg_hash: p.pkg_hash,
      files: files, imports: p.imports || {}, capabilities: p.capabilities || [],
      private: !!p.private,
    });
  }
  return res;
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
  try { b = request.json; }
  catch (e) { return jerr(400, "expected JSON body"); }
  const p = request.path;
  if (p === "/v1/deploy/reset") return wsReset(b);
  if (p === "/v1/deploy/file") return wsFile(b);
  if (p === "/v1/deploy/pkgfile") return wsPkgFile(b);
  if (p === "/v1/deploy/cut") return wsCut(b);
  return jerr(404, "unknown deploy route");
}
