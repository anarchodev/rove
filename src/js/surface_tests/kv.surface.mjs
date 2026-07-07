// kv — tenant KV store: read-your-writes within the activation txn,
// reserved-prefix enforcement, prefix pagination.
export default function () {
  check("kv.get", () => {
    eq(kv.get("nope/absent"), null);
  });

  check("kv.set", () => {
    eq(kv.set("st/user/1", JSON.stringify({ name: "jess" })), undefined);
    eq(JSON.parse(kv.get("st/user/1")).name, "jess");
    kv.set("st/user/1", "v2"); // overwrite
    eq(kv.get("st/user/1"), "v2");
  });

  // Platform-reserved prefixes fail loud with err.code === "reserved_key".
  check("kv.set", () => {
    let code = null;
    try { kv.set("_config/x", "v"); } catch (e) { code = e.code; }
    eq(code, "reserved_key");
  });

  check("kv.delete", () => {
    kv.set("st/tmp", "x");
    eq(kv.delete("st/tmp"), undefined);
    eq(kv.get("st/tmp"), null);
    eq(kv.delete("st/never-existed"), undefined); // no-op
  });

  check("kv.prefix", () => {
    kv.set("st/scan/a", "1");
    kv.set("st/scan/b", "2");
    kv.set("st/scan/c", "3");
    const page = kv.prefix("st/scan/");
    eq(page, [
      { key: "st/scan/a", value: "1" },
      { key: "st/scan/b", value: "2" },
      { key: "st/scan/c", value: "3" },
    ]);
    // cursor resumes AFTER the given key; limit caps the page.
    eq(kv.prefix("st/scan/", "st/scan/a"), [
      { key: "st/scan/b", value: "2" },
      { key: "st/scan/c", value: "3" },
    ]);
    eq(kv.prefix("st/scan/", null, 1).length, 1);
    eq(kv.prefix("st/scan/", null, 0).length, 3); // non-positive → default 100
    eq(kv.prefix("st/none/"), []);
  });

  return done();
}
