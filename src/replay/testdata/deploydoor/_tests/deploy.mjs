// The two RESULT-IN-CTX bound door ops — `platform.compile(files, {on})` and
// `platform.scope(t).deploy.stampManifest(entries, {on})` — driven offline
// (docs/architecture/replay-and-sim.md). Before the harness gained
// `node.compile().staged()` / `node.stampManifest().cut()` (issue #6), both
// resumes were undriveable: a plain `fetch().resolve()` hands the resume the
// fetch's ISSUE-TIME ctx instead of the door result, so `onFileStaged` / `onCut`
// saw `request.ctx.ok === undefined` → 500. These drivers place the door result
// on the resume's `request.ctx`, matching the prod `routeCompileEvent` /
// `processManifestPut` contract (`deploy_thread.zig`). The handler touches
// `platform.*`, so the run is admin + carries the operator root token.
import { scenario, expect } from "rewind:test";

const s = scenario({
  admin: true,
  rootToken: "root-secret",
  now: "2026-07-01T00:00:00Z",
  // platform.scope resolves eagerly (ghost id ⇒ InstanceNotFound, like
  // prod) — declare every tenant the handler scopes.
  instances: { acme: {}, other: {} },
});

function post(path, body, auth = "Bearer root-secret") {
  return s.inbound({
    method: "POST",
    path,
    headers: auth ? { authorization: auth } : {},
    body: JSON.stringify(body),
  });
}

// ── auth branch: no/invalid token → 401 before any door arms ──
const noauth = post("/v1/deploy/file", { tenant: "acme", path: "index.mjs" }, "");
expect(noauth.status).toBe(401);
expect(noauth.disposition).toBe("terminal");

// ── platform.compile → onFileStaged ─────────────────────────────────────────
// A valid POST holds + arms exactly one compile door (rove-compile.internal).
const file = post("/v1/deploy/file", {
  tenant: "acme", path: "index.mjs", content_type: "", source: "export default () => 'hi';",
});
expect(file.disposition).toBe("held");
expect(file.effects.some((e) => e.kind === "fetch" && /rove-compile\.internal/.test(e.url))).toBe(true);

// The compile completes → the result lands on the resume's request.ctx (NOT
// request.body), with `app` defaulting to the recorded issue-time ctx.
const staged = file.compile().staged({
  results: [{ path: "index.mjs", source_hex: "aa11", bytecode_hex: "bb22" }],
});
expect(staged.status).toBe(200);
expect(JSON.parse(staged.body)).toEqual({ ok: true, path: "index.mjs", hash: "aa11" });
// The resume READ its ctx — proving `request.ctx.{ok, results, app}` are all
// wired: the workspace row it wrote is keyed by app.target + app.path (from the
// threaded issue-time ctx) and carries the compiled hashes.
expect(staged.instanceKv("acme", "_workspace/index.mjs")).toEqual({
  kind: "handler", content_type: "", source_hex: "aa11", bytecode_hex: "bb22",
});

// A failed compile → onFileStaged sees ctx.ok === false → 500, nothing staged.
const badCompile = file.compile().staged({ ok: false, status: 400, error: "syntax error" });
expect(badCompile.status).toBe(500);
expect(JSON.parse(badCompile.body)).toEqual({
  stage: "compile", ctx: { ok: false, status: 400, error: "syntax error" },
});
expect(badCompile.instanceKv("acme", "_workspace/index.mjs")).toBe(null);

// An explicit `app` override replaces the recorded issue-time ctx.
const rehomed = file.compile().staged({
  results: [{ path: "index.mjs", source_hex: "cc33", bytecode_hex: "dd44" }],
  app: { target: "other", path: "moved.mjs", content_type: "text/plain" },
});
expect(rehomed.instanceKv("other", "_workspace/moved.mjs")).toEqual({
  kind: "handler", content_type: "text/plain", source_hex: "cc33", bytecode_hex: "dd44",
});

// ── two compile doors in one class → compile({on}) selects the package one ───
const pkg = post("/v1/deploy/pkg", {
  tenant: "acme", pkg_hash: "pk99", path: "lib.mjs", source: "export const x = 1;",
});
expect(pkg.disposition).toBe("held");
const pkgStaged = pkg.compile({ on: "onPkgStaged" }).staged({
  results: [{ path: "lib.mjs", source_hex: "ee55", bytecode_hex: "ff66" }],
});
expect(pkgStaged.status).toBe(200);
expect(JSON.parse(pkgStaged.body)).toEqual({ ok: true, pkg_hash: "pk99", path: "lib.mjs" });
expect(pkgStaged.instanceKv("acme", "_workspace_pkg/pk99/lib.mjs")).toEqual({
  source_hex: "ee55", bytecode_hex: "ff66",
});

// ── deploy.stampManifest → onCut ────────────────────────────────────────────
// Seed the target workspace so `cut` has entries to stamp; the barrier arms a
// door to rove-stage.internal.
const cutScenario = scenario({
  admin: true,
  rootToken: "root-secret",
  now: "2026-07-01T00:00:00Z",
  instances: {
    acme: {
      kv: {
        "_workspace/index.mjs": JSON.stringify({
          kind: "handler", content_type: "", source_hex: "aa11", bytecode_hex: "bb22",
        }),
      },
    },
  },
});
const cut = cutScenario.inbound({
  method: "POST",
  path: "/v1/deploy/cut",
  headers: { authorization: "Bearer root-secret" },
  body: JSON.stringify({ tenant: "acme" }),
});
expect(cut.disposition).toBe("held");
expect(cut.effects.some((e) => e.kind === "fetch" && /rove-stage\.internal/.test(e.url))).toBe(true);

// The staging barrier clears → request.ctx = { ok, dep_id } at onCut.
const done = cut.stampManifest().cut({ dep_id: "00000000deadbeef" });
expect(done.status).toBe(200);
expect(JSON.parse(done.body)).toEqual({ ok: true, dep_id: "00000000deadbeef" });

// A failed manifest PUT → onCut sees ctx.ok === false → 500 (dep_id still echoed).
const failStamp = cut.stampManifest().cut({ ok: false, dep_id: "00000000deadbeef" });
expect(failStamp.status).toBe(500);
expect(JSON.parse(failStamp.body)).toEqual({
  stage: "stamp", ctx: { ok: false, dep_id: "00000000deadbeef" },
});
