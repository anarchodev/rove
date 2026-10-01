// platform.instances.incarnation — the token naming a tenant lifetime, and
// the ownership check the admin app builds on it: a row recorded beside the
// owner under one incarnation must stop granting access once the name is
// reborn under another.
export default function ({ kv, platform }) {
  if (request.path === "/usage") {
    const out = {};
    for (const id of ["acme", "bare", "ghost"]) {
      try { out[id] = platform.instances.usage(id); } catch (e) { out[id] = e.code; }
    }
    return out;
  }
  const name = new URLSearchParams(request.query || "").get("name") || "acme";
  let current;
  try {
    current = platform.instances.incarnation(name);
  } catch (e) {
    response.status = 404;
    return { code: e.code, message: e.message };
  }
  if (request.method === "POST") {
    kv.set("instance/" + name + "/incarnation", current);
    return { recorded: current };
  }
  const recorded = kv.get("instance/" + name + "/incarnation");
  return { current, owned: recorded === current };
}
