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
// Packages (PM P1): stage each package file via /pkgfile — staged like
// handler files, NOT compiled (a package's modules may import each other,
// and a file uploaded on its own can't resolve siblings that haven't
// arrived — the same #344 shape the handler path had). At `cut` each
// package's files compile as ONE batch under its /pkg/<pkg_hash>/
// virtual dir, dependency-ordered (a package importing another compiles
// after it), then the handlers compile against the completed graph.
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
  // TRY to compile now (no resolution — the file alone): a self-contained
  // file (the common single-file package) gets its bytecode here, keeping
  // the compile cost spread across the staging requests. A file that
  // imports a sibling or another package can't resolve yet — that is not
  // an error, the bundle is merely incomplete (rove#344) — so it falls
  // back to stage-only and cut's batch phase compiles it.
  platform.compile([{ path: b.path, source: b.source || "" }], {
    scope: b.tenant, pkg_hash: b.pkg_hash, on: "onPkgTryCompiled",
    ctx: { target: b.tenant, pkg_hash: b.pkg_hash, path: b.path, source: b.source || "" },
  });
  return next();
}

export function onPkgTryCompiled() {
  const ctx = request.ctx;
  const app = (ctx && ctx.app) || {};
  if (ctx && ctx.ok) {
    const r = ctx.results[0];
    platform.scope(app.target).kv.set(WSPKG + app.pkg_hash + "/" + app.path, JSON.stringify({
      source_hex: r.source_hex, bytecode_hex: r.bytecode_hex,
    }));
    response.status = 200;
    return JSON.stringify({
      ok: true, pkg_hash: app.pkg_hash, path: app.path, source_hex: r.source_hex,
    });
  }
  // The privileged-surface gate is a verdict on the SOURCE, not on the
  // bundle's completeness — reject now, don't defer to cut.
  if (ctx && ctx.error && ctx.error.indexOf("privileged surface") !== -1) {
    response.status = ctx.status || 400;
    return JSON.stringify({ stage: "pkg-compile", ctx: ctx });
  }
  // Unresolvable import (sibling/dep not staged yet) — or any other
  // compile error, which cut's batch compile re-surfaces naming the file.
  // Record the row stage-only; the source hash is the same sha256 the
  // engine content-addresses with (and the failed compile already staged
  // the source blob before compiling).
  const source_hex = crypto.sha256(app.source);
  platform.scope(app.target).kv.set(WSPKG + app.pkg_hash + "/" + app.path, JSON.stringify({
    source_hex: source_hex,
  }));
  response.status = 200;
  return JSON.stringify({
    ok: true, pkg_hash: app.pkg_hash, path: app.path,
    source_hex: source_hex, staged_only: true,
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
  // Phase 1: any staged package files without bytecode compile first, one
  // batch per package in dependency order — a package's own siblings
  // resolve from its batch, and a package it imports resolves from the
  // batch compiled before it. Then the handlers (phase 2).
  const q = pkgCompileQueue(sk, b);
  if (q && q.error) return jerr(400, q.error);
  if (q && q.length > 0) return compileNextPkg(b, q, 0, {});
  return cutCompileHandlers(b, {});
}

// Phase 2 of cut: batch-compile the workspace's handlers against the
// (now bytecode-complete) package graph, then stamp. `done` is the chain's
// accumulated {pkg_hash → files[]} from phase 1 — carried in ctx, NEVER
// written to kv mid-chain: a resume hop that writes and then fires a
// platform call gets the call dropped (bind-from-writing-resume is not
// wired), which would silently stall the held cut.
function cutCompileHandlers(b, done) {
  const sk = platform.scope(b.tenant).kv;
  const rows = sk.prefix(WS, "", 1000);
  const handlers = [];
  for (let i = 0; i < rows.length; i++) {
    const e = JSON.parse(rows[i].value);
    if (e.kind === "handler")
      handlers.push({ path: rows[i].key.slice(WS.length), source_hash: e.source_hex });
  }
  if (handlers.length === 0) return cutStamp(b, {}, done);  // statics-only bundle
  // Compile against the SERVER-authoritative resolution (the join below), not
  // the client's lockfile: the engine needs each package file's staged
  // bytecode hash to load it, and validating against anything other than what
  // the manifest will record would validate the wrong thing.
  const res = buildResolution(sk, b, done);
  if (res && res.error) return jerr(400, res.error);
  const copts = {
    scope: b.tenant, on: "onBundleCompiled",
    // The client's lockfile has to survive the compile hop to reach the stamp.
    ctx: {
      target: b.tenant, done: done,
      resolution: b.resolution === undefined ? null : b.resolution,
    },
  };
  if (res) copts.resolution = res;
  platform.compile(handlers, copts);
  return next();
}

// The packages whose staged rows still need bytecode, dependency-ordered
// (leaves first — DFS over each package's `imports` targets). A dep whose
// pkg_hash isn't in this deploy's resolution is fine (its rows compiled in
// an earlier deploy); a cycle is an author error. `{error}` on a declared
// package with nothing staged, so the failure names the package instead of
// surfacing as an unresolvable import later.
function pkgCompileQueue(sk, b) {
  if (b.resolution === undefined) return null;
  const pkgs = b.resolution.packages || [];
  const byHash = {};
  for (let i = 0; i < pkgs.length; i++) byHash[pkgs[i].pkg_hash] = pkgs[i];
  const order = [];
  const state = {}; // pkg_hash → 1 visiting, 2 done
  function visit(p) {
    if (state[p.pkg_hash] === 2) return null;
    if (state[p.pkg_hash] === 1)
      return "package import cycle involving " + p.spec + "@" + p.version;
    state[p.pkg_hash] = 1;
    const imp = p.imports || {};
    for (const spec in imp) {
      const dep = byHash[imp[spec]];
      if (dep) { const e = visit(dep); if (e) return e; }
    }
    state[p.pkg_hash] = 2;
    order.push(p);
    return null;
  }
  for (let i = 0; i < pkgs.length; i++) {
    const e = visit(pkgs[i]);
    if (e) return { error: e };
  }
  const q = [];
  for (let i = 0; i < order.length; i++) {
    const p = order[i];
    const staged = sk.prefix(WSPKG + p.pkg_hash + "/", "", 1000);
    if (staged.length === 0)
      return { error: "package " + p.spec + "@" + p.version + " has no staged files" };
    let needs = false;
    for (let j = 0; j < staged.length; j++)
      if (!JSON.parse(staged[j].value).bytecode_hex) { needs = true; break; }
    if (needs) q.push(p.pkg_hash);
  }
  return q;
}

// Compile package `q[idx]`'s staged files as one batch under its
// /pkg/<hash>/ virtual dir. Its resolution carries the packages that are
// already bytecode-complete — from stage-time try-compiles (kv rows) or
// earlier chain hops (`done`); the deploy thread prefetches every listed
// file's bytecode eagerly, so an incomplete package lists empty files.
// Dependency order makes the complete set exactly what this package may
// import from.
function compileNextPkg(b, q, idx, done) {
  const sk = platform.scope(b.tenant).kv;
  const pkg_hash = q[idx];
  const staged = sk.prefix(WSPKG + pkg_hash + "/", "", 1000);
  const files = staged.map(function (row) {
    return {
      path: row.key.slice((WSPKG + pkg_hash + "/").length),
      source_hash: JSON.parse(row.value).source_hex,
    };
  });
  const copts = {
    scope: b.tenant, pkg_hash: pkg_hash, on: "onPkgBatchCompiled",
    ctx: {
      target: b.tenant, pkg_hash: pkg_hash, queue: q, idx: idx, done: done,
      resolution: b.resolution === undefined ? null : b.resolution,
    },
  };
  const res = compiledResolution(sk, b, done);
  if (res) copts.resolution = res;
  platform.compile(files, copts);
  return next();
}

export function onPkgBatchCompiled() {
  const ctx = request.ctx;
  if (!ctx || !ctx.ok) {
    response.status = (ctx && ctx.status) || 500;
    return JSON.stringify({ stage: "pkg-compile", ctx: ctx || null });
  }
  const app = ctx.app || {};
  // Accumulate this package's compiled files in ctx (`done`) — NOT in kv:
  // this hop chains another platform.compile, and a write here would drop
  // it (bind-from-writing-resume is not wired). The manifest gets these
  // via the `done` merge in buildResolution.
  const files = [];
  for (let i = 0; i < ctx.results.length; i++) {
    const r = ctx.results[i];
    files.push({ path: r.path, source_hash: r.source_hex, bytecode_hash: r.bytecode_hex });
  }
  const done = app.done || {};
  done[app.pkg_hash] = files;
  const b = {
    tenant: app.target,
    resolution: app.resolution === null ? undefined : app.resolution,
  };
  const nextIdx = app.idx + 1;
  if (nextIdx < app.queue.length) return compileNextPkg(b, app.queue, nextIdx, done);
  return cutCompileHandlers(b, done);
}

// This deploy's resolution with files listed ONLY for bytecode-complete
// packages (stage-time try-compile rows, or a `done` entry from an earlier
// chain hop), an empty files array otherwise. Every package stays present —
// the per-importer resolver needs the CURRENT package's own imports map to
// resolve its `@scope/pkg` specifiers mid-compile — while the empty files
// keep the deploy thread's eager bytecode prefetch off the not-yet-compiled
// ones. Rows are all-or-nothing per pkg_hash (content identity), so a
// package is never half-listed.
function compiledResolution(sk, b, done) {
  if (b.resolution === undefined) return null;
  const res = { packages: [], app_imports: b.resolution.app_imports || {} };
  const pkgs = b.resolution.packages || [];
  for (let i = 0; i < pkgs.length; i++) {
    const p = pkgs[i];
    let files = done[p.pkg_hash] || null;
    if (!files) {
      const staged = sk.prefix(WSPKG + p.pkg_hash + "/", "", 1000);
      let complete = staged.length > 0;
      const fromRows = [];
      for (let j = 0; j < staged.length; j++) {
        const f = JSON.parse(staged[j].value);
        if (!f.bytecode_hex) { complete = false; break; }
        fromRows.push({
          path: staged[j].key.slice((WSPKG + p.pkg_hash + "/").length),
          source_hash: f.source_hex, bytecode_hash: f.bytecode_hex,
        });
      }
      files = complete ? fromRows : [];
    }
    res.packages.push({
      spec: p.spec, version: p.version, pkg_hash: p.pkg_hash,
      files: files, imports: p.imports || {},
      capabilities: p.capabilities || [], private: !!p.private,
    });
  }
  if (res.packages.length === 0) return null;
  return res;
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
    app.done || {},
  );
}

// Assemble the manifest from the workspace + the just-compiled bytecode
// hashes (`bc`, path → bytecode_hex; `done`, the chain's package results)
// and stamp it.
function cutStamp(b, bc, done) {
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
  const res = buildResolution(sk, b, done);
  if (res && res.error) return jerr(400, res.error);
  if (res) sopts.resolution = res;
  platform.scope(b.tenant).deploy.stampManifest(entries, sopts);
  return next();
}

// PM P1: join the client's lockfile (spec/version/pkg_hash/imports) with the
// server-staged package files — hashes stay server-authoritative. A package's
// files come from cut's own batch compiles (`done`, carried in the chain's
// ctx) or from stage-time try-compile rows. The SAME resolution feeds the
// cut compile and the manifest, so a handler's `@scope/pkg` import validates
// against exactly the package files the deployment will record. Returns null
// when the deploy has no packages, or `{error}` when a declared package was
// never staged.
function buildResolution(sk, b, done) {
  if (b.resolution === undefined) return null;
  const res = { packages: [], app_imports: b.resolution.app_imports || {} };
  const pkgs = b.resolution.packages || [];
  for (let i = 0; i < pkgs.length; i++) {
    const p = pkgs[i];
    let files = done[p.pkg_hash] || null;
    if (!files) {
      const staged = sk.prefix(WSPKG + p.pkg_hash + "/", "", 1000);
      if (staged.length === 0)
        return { error: "package " + p.spec + "@" + p.version + " has no staged files" };
      files = staged.map(function (row) {
        const f = JSON.parse(row.value);
        return {
          path: row.key.slice((WSPKG + p.pkg_hash + "/").length),
          source_hash: f.source_hex, bytecode_hash: f.bytecode_hex,
        };
      });
    }
    res.packages.push({
      spec: p.spec, version: p.version, pkg_hash: p.pkg_hash,
      files: files, imports: p.imports || {}, capabilities: p.capabilities || [],
      private: !!p.private,
    });
  }
  return res;
}

// Relay the control plane's answer verbatim — status included. A control op's
// STATUS is its result (204 placed, 409 name taken, 4xx refused), so collapsing
// it to 200 would make every outcome read as success to the caller.
export function onCpRelay() {
  response.status = request.status || 502;
  return request.text || "";
}

export function onCut() {
  response.status = 200;
  return JSON.stringify(request.ctx); // { ok, dep_id }
}

// GET/PUT /v1/instances/:id/kv — read or seed a tenant's kv as the operator.
//
// Same argument as the CP relay below: the deployed dashboard has this route
// (`web/admin` `/v1/instances/:id/kv`, via `platform.scope(id).kv`), and the
// BAKED app needs it too, or a tenant's kv is unreadable on every cluster that
// has not published the dashboard — which is every freshly-genesis'd one.
//
// It reads through `platform.scope(id).kv`, the same door the dashboard uses,
// so it answers in whatever spelling a handler of that tenant would use. That
// is the point: an operator asking "what does this tenant see at K" gets the
// tenant's answer, not storage's. `/_system/v2-kv` answers the other question —
// it belongs to the tenant-MOVE protocol, where the store's own spelling is
// what a move has to carry — and the two must not be conflated (rove#870).
//
// Shape mirrors `v2-kv`'s so callers read the same: 200 + the raw value, or
// 404 `no such key`.
// One parameter out of a raw query string. Decodes `+` and %-escapes, so a key
// with a slash or a space round-trips.
function qsParam(qs, name) {
  const parts = qs.split("&");
  for (let i = 0; i < parts.length; i++) {
    const eq = parts[i].indexOf("=");
    if (eq === -1) continue;
    if (decodeURIComponent(parts[i].slice(0, eq)) !== name) continue;
    return decodeURIComponent(parts[i].slice(eq + 1).replace(/\+/g, " "));
  }
  return null;
}

function kvStoreFor(id) {
  try {
    return platform.scope(id).kv;
  } catch (e) {
    if (e && e.code === "InstanceNotFound") return null;
    throw e;
  }
}

// `/v1/instances/{id}/kv` and nothing else. Matching is separate from serving
// so the dispatcher can decide the route BEFORE the method gate without
// changing what any other path answers.
function isKvRoute(p) {
  if (p.indexOf("/v1/instances/") !== 0) return false;
  const rest = p.slice("/v1/instances/".length);
  const slash = rest.indexOf("/");
  return slash > 0 && rest.slice(slash) === "/kv";
}

function instanceKvRoute(p, method, body) {
  const rest = p.slice("/v1/instances/".length);
  const id = rest.slice(0, rest.indexOf("/"));
  const store = kvStoreFor(id);
  if (store === null) return jerr(404, "unknown instance");

  if (method === "GET") {
    // `request.path` never carries the query string — it lives only on
    // `request.query`, as a raw string (handler-shape.md, the default-activation
    // surface). Splitting `path` on "?" yields an empty query and a door that
    // never sees its parameter.
    const key = qsParam(request.query || "", "key");
    if (!key) return jerr(400, "missing ?key");
    const v = store.get(key);
    if (v === null) {
      response.status = 404;
      return "no such key\n";
    }
    response.status = 200;
    return v;
  }
  if (method === "PUT" || method === "POST") {
    if (!body || typeof body.key !== "string" || !body.key) {
      return jerr(400, "missing key");
    }
    if (typeof body.value !== "string") return jerr(400, "value must be a string");
    store.set(body.key, body.value);
    // 204, matching `/_system/v2-kv`'s PUT — the two doors answer different
    // QUESTIONS, but a caller switching between them should not also have to
    // switch status codes.
    response.status = 204;
    return "";
  }
  return jerr(405, "GET to read, PUT to write");
}

export default function () {
  // The kv route serves GET, so it is decided BEFORE the POST-only gate below.
  // Everything else keeps the original order — an unauthenticated GET of any
  // other path still answers 405, which is what the readiness probe asserts.
  if (isKvRoute(request.path)) {
    // The operator-root verdict, computed by the engine. `authorization` is not
    // readable here — a bearer the handler reads is a bearer the tape records
    // (docs/architecture/privileged-surface.md).
    if (!request.rewind.isRoot) {
      response.status = 401;
      return "unauthenticated\n";
    }
    let kb;
    if (request.method !== "GET") {
      try { kb = request.json; }
      catch (e) { return jerr(400, "expected JSON body"); }
    }
    return instanceKvRoute(request.path, request.method, kb);
  }
  if (request.method !== "POST") {
    response.status = 405;
    return "POST only\n";
  }
  // The operator-root verdict, computed by the engine. `authorization` is not
  // readable here — a bearer the handler reads is a bearer the tape records
  // (docs/architecture/privileged-surface.md).
  if (!request.rewind.isRoot) {
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
  // Control-plane relay (rove#414). The operator CLI drives provision / move /
  // delete / host / plan through this chokepoint rather than by holding the
  // move-secret on a shell, and doing so makes the action an ordinary
  // `__admin__` activation — logged, taped, replayable. The deployed dashboard
  // has the same route; the BAKED app needs it too, or the CLI's primary verb
  // is unusable on every cluster that has not published the dashboard yet —
  // which includes every freshly-genesis'd one, since genesis itself ends here.
  //
  // The worker opens `rewind-cp.internal` only for `__admin__` and attaches the
  // move-secret itself, so nothing secret passes through this handler. The
  // root-token gate above is the authority check.
  if (p.indexOf("/v1/cp/") === 0) {
    const op = p.slice("/v1/cp/".length);
    if (!op || op.indexOf("/") !== -1) return jerr(404, "unknown cp op");
    after.fetch("http://rewind-cp.internal/_control/" + op, {
      method: "POST",
      body: JSON.stringify(b === undefined ? {} : b),
      headers: { "content-type": "application/json" },
      on: "onCpRelay",
    });
    return next();
  }
  return jerr(404, "unknown deploy route");
}
