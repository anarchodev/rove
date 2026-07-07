// users — the managed user store; pure kv composition, so the whole
// CRUD + index lifecycle runs in one activation via read-your-writes.
export default function () {
  let uid;

  check("users.create", () => {
    const u = users.create({
      email: "  Ada@Example.COM ",   // normalized: trim + lowercase
      email_verified: true,
      name: "Ada",
      metadata: { public: { plan: "pro" }, private: { note: "vip" } },
    });
    uid = u.uid;
    ok(/^usr_[0-9a-f]{24}$/.test(u.uid), "uid shape: " + u.uid);
    eq(u.email, "ada@example.com");
    eq(u.email_verified, true);
    eq(u.status, "active");
    eq(u.metadata, { public: { plan: "pro" }, private: { note: "vip" } });
    ok(typeof u.created_at === "number" && u.updated_at === u.created_at, "timestamps");
    throws(() => users.create({ email: "ada@example.com" }), /email_exists/); // index is the join key
    throws(() => users.create({ email: "nope" }), /valid email required/);
    throws(() => users.create(), /valid email required/);
  });

  check("users.get", () => {
    eq(users.get(uid).email, "ada@example.com");
    eq(users.get("usr_000000000000000000000000"), null);
    eq(users.get(""), null);
  });

  check("users.byEmail", () => {
    eq(users.byEmail("ADA@example.com  ").uid, uid);  // normalized lookup
    eq(users.byEmail("ghost@example.com"), null);
    eq(users.byEmail(""), null);
  });

  check("users.update", () => {
    const u = users.update(uid, {
      name: "Ada L.",
      email: "hijack@example.com",              // NOT patchable — ignored
      metadata: { public: { theme: "dark" } },  // merges, not replaces
    });
    eq(u.name, "Ada L.");
    eq(u.email, "ada@example.com");
    eq(u.metadata.public, { plan: "pro", theme: "dark" });
    throws(() => users.update("usr_000000000000000000000000", {}), /not_found/);
  });

  check("users.list", () => {
    users.create({ email: "bob@example.com" });
    const all = users.list();
    eq(all.users.length, 2);
    ok(!("next_cursor" in all), "no cursor when the page wasn't full");
    const p1 = users.list(undefined, 1);
    eq(p1.users.length, 1);
    ok(typeof p1.next_cursor === "string", "full page carries next_cursor");
    const p2 = users.list(p1.next_cursor, 10);
    eq(p2.users.length, 1);
    ok(p1.users[0].uid !== p2.users[0].uid, "pages advance");
  });

  check("users.disable", () => {
    eq(users.disable(uid).status, "disabled");
    eq(users.get(uid).status, "disabled");
    throws(() => users.disable("usr_000000000000000000000000"), /not_found/);
  });

  check("users.enable", () => {
    eq(users.enable(uid).status, "active");
    throws(() => users.enable("usr_000000000000000000000000"), /not_found/);
  });

  return done();
}
