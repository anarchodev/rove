// URLSearchParams — WHATWG subset; toString() round-trips through
// request.query (the standard request carries "alpha=1&beta=two").
export default function () {
  check("URLSearchParams()", () => {
    eq(new URLSearchParams().size, 0);
    eq(new URLSearchParams("?a=1").get("a"), "1");        // leading ? stripped
    eq(new URLSearchParams({ a: 1, b: "x" }).toString(), "a=1&b=x");
    eq(new URLSearchParams([["a", "1"], ["a", "2"]]).getAll("a"), ["1", "2"]);
    const src = new URLSearchParams("a=1");
    const clone = new URLSearchParams(src);
    clone.set("a", "2");
    eq(src.get("a"), "1");                                 // clone, not alias
    throws(() => new URLSearchParams([["only-name"]]), /\[name, value\] pairs/);
    // Parses the live request.query.
    const q = new URLSearchParams(request.query);
    eq(q.get("alpha"), "1");
    eq(q.get("beta"), "two");
  });

  check("URLSearchParams#size", () => {
    eq(new URLSearchParams("a=1&b=2&a=3").size, 3); // pairs, not names
  });

  check("URLSearchParams#append", () => {
    const q = new URLSearchParams("a=1");
    eq(q.append("a", "3"), undefined);
    eq(q.toString(), "a=1&a=3");
  });

  check("URLSearchParams#delete", () => {
    const q = new URLSearchParams("a=1&b=2&a=3");
    eq(q.delete("a"), undefined);
    eq(q.toString(), "b=2");
    q.delete("missing"); // no-op
  });

  check("URLSearchParams#get", () => {
    const q = new URLSearchParams("a=1&a=2");
    eq(q.get("a"), "1");        // first value
    eq(q.get("zz"), null);
  });

  check("URLSearchParams#getAll", () => {
    const q = new URLSearchParams("a=1&a=2");
    eq(q.getAll("a"), ["1", "2"]);
    eq(q.getAll("zz"), []);
  });

  check("URLSearchParams#has", () => {
    const q = new URLSearchParams("a=");
    eq(q.has("a"), true);       // present with empty value
    eq(q.has("b"), false);
  });

  check("URLSearchParams#set", () => {
    const q = new URLSearchParams("a=1&b=2&a=3");
    eq(q.set("a", "9"), undefined);
    eq(q.toString(), "a=9&b=2"); // replaces all, keeps first slot
    q.set("c", "1");             // absent → appends
    eq(q.get("c"), "1");
  });

  check("URLSearchParams#sort", () => {
    const q = new URLSearchParams("b=1&a=2&b=0");
    eq(q.sort(), undefined);
    eq(q.toString(), "a=2&b=1&b=0"); // stable by name
  });

  check("URLSearchParams#toString", () => {
    const q = new URLSearchParams();
    q.append("k", "a b+c");
    eq(q.toString(), "k=a+b%2Bc");   // space → +, + percent-encoded
    // Round-trip incl. non-ASCII (UTF-8 percent-encoded byte-wise).
    const r = new URLSearchParams();
    r.append("n", "héllo");
    eq(new URLSearchParams(r.toString()).get("n"), "héllo");
  });

  check("URLSearchParams#entries", () => {
    eq(Array.from(new URLSearchParams("a=1&b=2").entries()), [["a", "1"], ["b", "2"]]);
    // Symbol.iterator aliases entries (for...of works).
    eq(Array.from(new URLSearchParams("a=1")), [["a", "1"]]);
  });

  check("URLSearchParams#keys", () => {
    eq(Array.from(new URLSearchParams("a=1&b=2").keys()), ["a", "b"]);
  });

  check("URLSearchParams#values", () => {
    eq(Array.from(new URLSearchParams("a=1&b=2").values()), ["1", "2"]);
  });

  check("URLSearchParams#forEach", () => {
    const seen = [];
    const q = new URLSearchParams("a=1&b=2");
    eq(q.forEach(function (v, k, self) {
      ok(self === q);
      seen.push(k + "=" + v + ":" + this.tag);
    }, { tag: "t" }), undefined);
    eq(seen, ["a=1:t", "b=2:t"]);
  });

  return done();
}
