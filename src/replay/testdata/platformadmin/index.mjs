// platform.* admin-only gating. Every sync platform method throws off a
// non-admin handler (prod: "platform is only available on the admin handler");
// platform.compile is the exception — it lowers to a bound fetch and is checked
// door-side, so its emission never throws. The handler probes each and reports
// "ok" or the thrown message, so one fixture covers both the admin and non-admin
// runs (selected by scenario({ admin })).
export default function () {
  const out = {};
  const probe = (name, fn) => {
    try { fn(); out[name] = "ok"; }
    catch (e) { out[name] = String((e && e.message) || e); }
  };
  probe("scope", () => platform.scope("acme").kv.get("x"));
  probe("root", () => platform.root.get("x"));
  probe("instances", () => platform.instances.create({ id: "x" }));
  probe("releases", () => platform.releases.publish("acme", "0123456789abcdef"));
  probe("auth", () => platform.auth.checkRootToken("t"));
  probe("compile", () => platform.compile([{ path: "a.mjs", source: "export default () => {}" }], { scope: "acme" }));
  return out;
}
