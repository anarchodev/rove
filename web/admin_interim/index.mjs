// __admin__ tenant — INTERIM operator surface (pre-dashboard).
//
// The full dashboard bundle (web/admin/) is an OIDC relying party and
// needs the __auth__ IdP tenant (deploy-plan §11 step 2). Until that
// lands, this minimal bearer-gated handler exposes the one platform
// write the first-party tenants need: explicit domain/{host} → tenant
// aliases (the worker's host resolver consults these for any host that
// isn't {tenant}.{public suffix}).
//
// OPS_SECRET is stamped at deploy time and recorded in the operator's
// .env.prod (same custody class as REWIND_ROOT_TOKEN — handlers can't
// read process env, so it must be baked into the bundle).
const OPS_SECRET = "%OPS_SECRET%";

function pathOnly() {
  const p = request.path;
  const q = p.indexOf("?");
  return q === -1 ? p : p.slice(0, q);
}

function queryParam(name) {
  for (const part of (request.query || "").split("&")) {
    const eq = part.indexOf("=");
    if (eq === -1) continue;
    if (part.slice(0, eq) === name) {
      return decodeURIComponent(part.slice(eq + 1).replace(/\+/g, "%20"));
    }
  }
  return null;
}

function authorized() {
  return (request.headers["authorization"] ?? "") === `Bearer ${OPS_SECRET}`;
}

export default function () {
  const path = pathOnly();

  if (path === "/ops/assign-domain" && request.method === "POST") {
    if (!authorized()) { response.status = 401; return "unauthorized\n"; }
    let body;
    try { body = JSON.parse(request.body); }
    catch { response.status = 400; return "expected JSON {host, tenant}\n"; }
    const { host, tenant } = body ?? {};
    if (!host || !tenant || /[^a-z0-9.-]/.test(host)) {
      response.status = 400;
      return "expected {host, tenant}, host = lowercase fqdn\n";
    }
    platform.root.set(`domain/${host}`, tenant);
    response.status = 204;
    return "";
  }

  if (path === "/ops/resolve-domain" && request.method === "GET") {
    if (!authorized()) { response.status = 401; return "unauthorized\n"; }
    const host = queryParam("host") ?? "";
    const tenant = platform.root.get(`domain/${host}`);
    if (tenant === null) { response.status = 404; return "no alias\n"; }
    return { host, tenant };
  }

  response.status = 404;
  return "admin: interim ops surface (dashboard not yet deployed)\n";
}
