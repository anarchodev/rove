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
  probe("instances", () => platform.instances.create("x"));
  probe("releases", () => platform.releases.publish("acme", "0123456789abcdef"));
  // `request.rewind` is not gated — it simply doesn't EXIST off a
  // platform-bound handler, so the probe reports presence rather than a throw.
  out.rewind = typeof request.rewind === "undefined" ? "absent" : String(request.rewind.isRoot);
  probe("compile", () => platform.compile([{ path: "a.mjs", source: "export default () => {}" }], { scope: "acme" }));
  return out;
}
