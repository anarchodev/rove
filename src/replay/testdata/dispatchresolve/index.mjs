// The offline eager dispatch resolution, seen from the dispatching handler.
// Offline the recorder resolves a `platform.dispatch` at the call: it writes
// the result row and deletes the owed marker. A driver written as "harvest if
// resolved, else park" therefore answers in one activation — but only if
// those writes land in the store the handler's own `kv` reads.
export default function ({ kv, platform }) {
  const out = {};
  const run = (name, fn) => {
    try { out[name] = fn(); } catch (e) { out[name] = "threw: " + (e.code || e.message); }
  };
  const result = (id) => {
    const raw = kv.get("_dispatch/result/" + id);
    return raw === null ? null : JSON.parse(raw);
  };
  run("scopeKv", () => {
    const id = platform.dispatch("acme", "__system/scope_kv",
      { ctx: { pairs: [{ key: "k", value: "v" }] }, actor: "system" });
    const r = result(id);
    return { owed: kv.get("_dispatch/owed/" + id), status: r && r.status };
  });
  run("rootQuery", () => {
    const id = platform.dispatch("__root__", "__system/root_query",
      { ctx: { instances: true, instance: "ghost", domain: "nowhere.example" }, actor: "system" });
    const r = result(id);
    return r && JSON.parse(r.body);
  });
  run("rootRequires", () => {
    const id = platform.dispatch("__root__", "__system/root_kv_install",
      { ctx: { pairs: [{ key: "domain/x.example", value: "acme" }], requires: ["instance/ghost"] }, actor: "system" });
    const r = result(id);
    return r && r.status;
  });
  return out;
}
