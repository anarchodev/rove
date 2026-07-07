// surface test: sessions — full lifecycle in one activation via kv
// read-your-writes. The standard request's cookie header carries
// "sid=abc", so an inline config with cookie_name "sid" has a live
// session id to operate on.

export default function () {
  check("sessions.fromConfig", () => {
    ok(sessions.fromConfig(), "seeded _config/sessions/default resolves");
    ok(sessions.fromConfig("default"), "named form resolves");
    ok(sessions.fromConfig({ cookie_name: "sid" }), "inline config resolves");
    throws(() => sessions.fromConfig("nope"),
      /config not found at _config\/sessions\/nope/);
    throws(() => sessions.fromConfig(42), /expected string name or inline config/);
  });

  check("sessions.parseCookies", () => {
    eq(sessions.parseCookies("sid=abc; theme=dark"), { sid: "abc", theme: "dark" });
    eq(sessions.parseCookies("a=1;noeq; b = 2 "), { a: "1", b: "2" });
    eq(sessions.parseCookies(""), {});
    eq(sessions.parseCookies(null), {});
  });

  const s = sessions.fromConfig({ cookie_name: "sid", state_path: "state/sessions/t" });

  check("Sessions#get", () => {
    // Cookie id "abc" with no row → null; default config's cookie
    // name ("session") isn't in the request at all → null.
    eq(s.get(), null);
    eq(sessions.fromConfig().get(), null);
    kv.set("state/sessions/t/abc", JSON.stringify({ user: "jess" }));
    eq(s.get(), { user: "jess" });
  });

  check("Sessions#update", () => {
    eq(s.update({ role: "admin" }), { user: "jess", role: "admin" });
    eq(s.get(), { user: "jess", role: "admin" });
    // Function form replaces wholesale.
    eq(s.update((cur) => ({ n: (cur.role === "admin") ? 1 : 0 })), { n: 1 });
    eq(sessions.fromConfig().update({ x: 1 }), null); // no session → null
  });

  check("Sessions#create", () => {
    const before = (response.cookies || []).length;
    const id = s.create({ user_sub: "u1" });
    ok(/^[0-9a-f-]{36}$/.test(id), "uuid id");
    const row = JSON.parse(kv.get("state/sessions/t/" + id));
    eq(row.user_sub, "u1");
    ok(typeof row.created_at === "number", "created_at stamped");
    const cookie = response.cookies[before];
    ok(cookie.startsWith("sid=" + id + "; "), "cookie set: " + cookie);
    ok(cookie.includes("HttpOnly") && cookie.includes("Secure") &&
       cookie.includes("SameSite=Lax") && cookie.includes("Path=/"),
      "hardened defaults: " + cookie);
  });

  check("Sessions#rotate", () => {
    const new_id = s.rotate(); // current id is still the cookie's "abc"
    ok(new_id && new_id !== "abc", "fresh id");
    eq(kv.get("state/sessions/t/abc"), null); // old row gone
    eq(JSON.parse(kv.get("state/sessions/t/" + new_id)).n, 1); // data kept
    eq(sessions.fromConfig().rotate(), null); // no session → null
  });

  check("Sessions#destroy", () => {
    kv.set("state/sessions/t/abc", JSON.stringify({ back: true }));
    const before = (response.cookies || []).length;
    eq(s.destroy(), undefined);
    eq(kv.get("state/sessions/t/abc"), null);
    const cookie = response.cookies[before];
    ok(cookie.startsWith("sid=; ") && cookie.includes("Max-Age=0"),
      "clearing cookie: " + cookie);
  });

  // Don't leak the lifecycle's Set-Cookie noise into the harness reply.
  response.cookies = [];
  return done();
}
