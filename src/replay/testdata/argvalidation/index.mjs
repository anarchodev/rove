// Effect-argument validation probes — each row calls an effect verb with a
// shape prod rejects synchronously, catches, and reports the error surface
// (type / message / code) so the test can pin it against the prod throw
// table (bindings/{on,http,stream,blob,crypto}.zig + globals.zig).
export default function () {
  const out = {};
  const probe = (name, fn) => {
    try { fn(); out[name] = null; }
    catch (e) { out[name] = { type: e.constructor.name, message: String(e.message), code: e.code === undefined ? null : e.code }; }
  };
  probe("msZero", () => after.ms(0));
  probe("msNegative", () => after.ms(-5));
  probe("msMissing", () => after.ms());
  probe("kvNonString", () => after.kv(42));
  probe("fetchNoUrl", () => after.fetch());
  probe("fetchBadBody", () => after.fetch("https://api.example.test/x", { body: { a: 1 } }));
  probe("fetchNullBody", () => after.fetch("https://api.example.test/x", { body: null }));
  probe("fetchPathOn", () => after.fetch("https://api.example.test/x", { on: "hooks/next.mjs" }));
  probe("subscribeNoOn", () => http.subscribe({ url: "https://feed.example.test/x" }));
  probe("subscribeBadName", () => http.subscribe({ url: "https://feed.example.test/x", on: "ingest", name: "9bad" }));
  probe("streamBadChunk", () => stream.write({}));
  // One 5 MiB chunk crosses the 4 MiB per-activation buffered cap in a single
  // call, so nothing is recorded before the throw.
  probe("streamFlood", () => stream.write("x".repeat(5 * 1024 * 1024)));
  probe("blobTtlZero", () => blob.url("a".repeat(64), { ttl: 0 }));
  probe("blobTtlHuge", () => blob.url("a".repeat(64), { ttl: 604801 }));
  probe("receiveBuffered", () => blob.receive({ on: "onStored" }));
  probe("scopeEmpty", () => platform.scope(""));
  probe("scopeGhost", () => platform.scope("ghost"));
  probe("randomHuge", () => crypto.randomBytes(65537));
  return out;
}

// Headers-first branch: the SECOND receive throws (one inbound body per
// request); the first arms normally and the chain holds.
export function onHeaders() {
  blob.receive({ on: "onStored" });
  try {
    blob.receive({ on: "onStored" });
    kv.set("receiveTwice", "no-throw");
  } catch (e) {
    kv.set("receiveTwice", JSON.stringify({ type: e.constructor.name, message: String(e.message) }));
  }
  return next();
}

export function onStored() {
  return "";
}
