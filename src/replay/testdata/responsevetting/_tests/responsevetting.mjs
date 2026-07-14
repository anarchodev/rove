// The bundle's response head + body carry prod's EMIT-side vetting
// (response_building.zig + worker_dispatch), so offline assertions see the
// same wire the client would: sanitized headers/cookies, clamped status,
// the content-type rule, byte-exact binary bodies, and stream-prepend.
import { scenario, expect } from "rewind:test";

const s = scenario({});

// header sanitize: lowercase names; reserved/hop-by-hop/pseudo/x-rewind-*/
// CRLF-valued/non-string entries silently dropped; Domain= stripped from
// cookies, non-string cookie entries skipped; status ToInt32-coerced
const head = s.inbound({ path: "/head" });
expect(head.status).toBe(207);
expect(head.response.headers).toEqual({ "x-custom": "Yes" });
expect(head.response.cookies).toEqual(["sid=abc; Path=/; HttpOnly", "theme=dark"]);
expect(head.body).toBe("ok");

// status clamp 100..599
expect(s.inbound({ path: "/clamp-low" }).status).toBe(100);
expect(s.inbound({ path: "/clamp-high" }).status).toBe(599);

// 32-entry header cap (first 32 own props)
const cap = s.inbound({ path: "/cap" });
expect(Object.keys(cap.response.headers).length).toBe(32);

// auto content-type: application/json on object returns…
const j = s.inbound({ path: "/json" });
expect(j.response.headers["content-type"]).toBe("application/json");
expect(j.body).toEqual({ a: 1 });

// …suppressed when the handler set its own
const j2 = s.inbound({ path: "/json-own-ct" });
expect(j2.response.headers["content-type"]).toBe("text/x-custom");

// a returned Uint8Array is raw bytes — byte-exact through the bundle
const by = s.inbound({ path: "/bytes" });
expect(by.body instanceof Uint8Array).toBe(true);
expect(Array.from(by.body).join(",")).toBe("104,0,255");
expect(by.bundle.binary).toBe(true);

// terminal after stream.write: buffered chunks ship AHEAD of the body
const st = s.inbound({ path: "/stream-then-body" });
expect(st.body).toBe("chunk1|chunk2|tail");
// the frames stay visible as effects too
expect(st.frames).toEqual(["chunk1|", "chunk2|"]);
