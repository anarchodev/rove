// Standing __admin__ deploy app (docs/rewind-cli-plan.md §4.1 (f)) — composes
// a customer deploy entirely from platform.* primitives, no Zig deploy route.
// This is what publish_tenant + the smoke harness POST bundles to; the Zig
// /_system/deploy route then only bootstraps the system tenants (incl. THIS
// app onto __admin__).
//
// Wire: POST (Host = the admin host), Authorization: Bearer <root token>, body
//   { "tenant": "<id>",
//     "handlers": [{ "path": "index.mjs", "source": "<text>" }, ...],
//     "statics":  [{ "path": "_static/x", "content_type": "...", "b64": "..." }, ...] }
// Returns 200 { "ok": true, "dep_id": "<016x>" } once staging is durable (the
// stampManifest barrier). Does NOT release — activation stays a separate,
// gated /_system/release (the approval-gated stance).

function bytesFromB64(b64) {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
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
  try {
    b = JSON.parse(request.body);
  } catch (e) {
    response.status = 400;
    return "expected JSON {tenant, handlers, statics}\n";
  }
  const target = b.tenant;
  if (!target) {
    response.status = 400;
    return "tenant required\n";
  }
  const handlers = b.handlers || [];
  const statics = b.statics || [];

  // Stage statics now: cross-tenant content-addressed write (sync hash +
  // deferred PUT). Build the static manifest entries from the returned hashes.
  const staticEntries = statics.map(function (s) {
    const hash = platform.scope(target).blob.put(bytesFromB64(s.b64), {
      content_type: s.content_type,
    });
    return {
      path: s.path,
      kind: "static",
      source_hex: hash,
      content_type: s.content_type,
    };
  });

  // Compile the handlers (async, bound); thread {target, statics} forward so
  // onCompiled can compose the full manifest after the bytecode hashes return.
  platform.compile(handlers, {
    scope: target,
    name: "onCompiled",
    ctx: { target: target, statics: staticEntries },
  });
  return next();
}

export function onCompiled() {
  const ctx = request.ctx;
  if (!ctx || !ctx.ok) {
    response.status = 500;
    return JSON.stringify({ stage: "compile", ctx: ctx || null });
  }
  const app = ctx.app || {};
  const entries = ctx.results
    .map(function (r) {
      return {
        path: r.path,
        kind: "handler",
        source_hex: r.source_hex,
        bytecode_hex: r.bytecode_hex,
      };
    })
    .concat(app.statics || []);
  // stampManifest is the staging BARRIER — onStamped fires only once the
  // manifest + every prior bytecode/static PUT is durable.
  platform.scope(app.target).deploy.stampManifest(entries, { name: "onStamped" });
  return next();
}

export function onStamped() {
  // request.ctx = { ok, dep_id } — the whole deploy is durable here.
  response.status = 200;
  return JSON.stringify(request.ctx);
}
