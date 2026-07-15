// Prod's synchronous effect-argument validation fires offline too (issue #21):
// each row pins the exact error type + message the worker binding throws
// (bindings/{on,http,stream,blob,crypto}.zig + globals.zig), so a customer
// `catch` branch keyed on them is testable under `rewind test`.
import { scenario, expect } from "rewind:test";

const s = scenario({ admin: true, now: "2026-07-01T00:00:00Z" });
const r = s.inbound({ method: "POST", path: "/" });
expect(r.status).toBe(200);
const b = r.body;

const row = (name, type, msg, code) => {
  expect(b[name] && b[name].type).toBe(type);
  expect(b[name] && b[name].message).toMatch(msg); // plain string = substring
  if (code !== undefined) expect(b[name] && b[name].code).toBe(code);
};

row("msZero", "TypeError", "after.ms(ms): ms must be > 0");
row("msNegative", "TypeError", "after.ms(ms): ms must be > 0");
row("msMissing", "TypeError", "after.ms(ms): ms must be > 0");
row("kvNonString", "TypeError", "after.kv(prefix, opts?) requires a string prefix");
row("fetchNoUrl", "TypeError", "after.fetch(url, opts?) requires a url string");
row("fetchBadBody", "TypeError", "fetch: `body` must be a string or Uint8Array");
row("fetchNullBody", "TypeError", "fetch: `body` must be a string or Uint8Array");
row("fetchPathOn", "TypeError", "after.fetch: `on` must be a JS identifier");
row("subscribeNoOn", "TypeError", "http.fetch: `on_chunk` (module path) is required");
row("streamBadChunk", "TypeError", "stream.write: chunk must be a string or Uint8Array");
row("streamFlood", "RangeError", "too many bytes buffered in one activation");
row("blobTtlZero", "TypeError", "blob.url: ttl must be 1..604800 seconds");
row("blobTtlHuge", "TypeError", "blob.url: ttl must be 1..604800 seconds");
row("receiveBuffered", "TypeError", "blob.receive: only callable from an onHeaders activation");
row("scopeEmpty", "TypeError", "platform.scope: instance_id must be non-empty");
row("scopeGhost", "Error", "instance not found", "InstanceNotFound");
row("randomHuge", "RangeError", "crypto.randomBytes: n must be in [0, 65536]");

// ── onHeaders branch: first receive arms, second throws (one inbound body) ──
const h = s.inboundHeaders({ method: "PUT", path: "/up" });
expect(h.disposition).toBe("held");
const tw = h.kv("receiveTwice");
expect(tw && tw.type).toBe("TypeError");
expect(tw && tw.message).toMatch("blob.receive: already called for this request");
