// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// kv — tenant KV store: read-your-writes within the activation txn,
// reserved-prefix enforcement, prefix pagination.
export default function ({ kv }) {
  check("kv.get", () => {
    eq(kv.get("nope/absent"), null);
  });

  check("kv.set", () => {
    eq(kv.set("st/user/1", JSON.stringify({ name: "jess" })), undefined);
    eq(JSON.parse(kv.get("st/user/1")).name, "jess");
    kv.set("st/user/1", "v2"); // overwrite
    eq(kv.get("st/user/1"), "v2");
  });

  // The leading-`_` keyspace is the handler's own. It used to be refused with
  // err.code === "reserved_key"; a handler's kv is rooted now, so a name like
  // this reaches a row of the handler's own and the platform's row of that
  // name is not addressable at all. Nothing to refuse, and the customer gets
  // the whole keyspace back.
  check("kv.set", () => {
    let code = null;
    try { kv.set("_config/x", "v"); } catch (e) { code = e.code; }
    eq(code, null);
    eq(kv.get("_config/x"), "v");
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
