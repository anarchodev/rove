// The epilogue's request surface mirrors prod's installRequest
// (src/js/globals.zig) on authored worlds: identity always pinned
// (session null / tenant "sim" / sagaId ""), the ip channels
// masked+raw (null when un-authored, never a throw), the activation bag on
// every kind, prod's tag-capability validation, payload accessors reading
// undefined on payload-less resumes, and the retired driver-only surfaces
// (request.body, on.*) gone.
import { scenario, expect } from "rewind:test";

// ── inbound: pinned identity, ip channels, tag validation, retired surfaces
//    (incl. request.tag/.unmaskedIp/.shredKey — capabilities now, #849) ──
const s = scenario({});
const r = s.inbound({ method: "POST", path: "/x", body: "hi", ip: "203.0.113.9" });
expect(r.error).toBe(null);
const out = JSON.parse(r.body);
expect(out.session).toBe(null);
expect(out.tenant).toBe("sim");
expect(out.corr).toBe("");
expect(out.ip).toBe("203.0.113.0"); // v4 mask: last octet zeroed
expect(out.unmasked).toBe("203.0.113.9"); // raw channel works offline
expect(out.hasBody).toBe(false); // request.body is retired live
expect(out.onGlobal).toBe("undefined"); // on.* is retired live
expect(out.activation).toEqual({ kind: "inbound" });
expect(out.offRequest).toBe(true);
expect(out.tagValid).toBe(true);
expect(out.tagBadChars).toContain("[a-z0-9_]");
expect(out.tagReserved).toContain("reserved");
expect(out.tagNonString).toContain("two string arguments");
expect(out.tagLongKey).toContain("1..32");
expect(out.tagLongVal).toContain("1..64");
expect(out.tagCtl).toContain("control characters");
expect(out.tagCap).toContain("max 4");
// accepted tags land in the effect log (what would index the log record)
expect(r.effects.some((e) => e.kind === "tag" && e.key === "route" && e.value === "surface")).toBe(true);

// authored identity + session win over the defaults
const s2 = scenario({ tenant: "acme", sagaId: "corr-9" });
const r2 = s2.inbound({ path: "/x", session: { id: "sess_" + "a".repeat(64) } });
const out2 = JSON.parse(r2.body);
expect(out2.tenant).toBe("acme");
expect(out2.corr).toBe("corr-9");
expect(out2.session).toEqual({ id: "sess_" + "a".repeat(64) });
expect(out2.ip).toBe(null); // un-authored ip reads null, never throws
expect(out2.unmasked).toBe(null);

// v6 masking keeps the /48
const r3 = s.inbound({ path: "/x", ip: "2001:0db8:85a3:0000:0000:8a2e:0370:7334" });
expect(JSON.parse(r3.body).ip).toBe("2001:db8:85a3::");

// ── wake resume: payload accessors undefined; bag + identity pinned ──
const sh = scenario({ entry: "hold.mjs" });
const held = sh.inbound({ path: "/hold" });
expect(held.disposition).toBe("held");
const wake = held.clock.advance("100ms").fire();
const w = JSON.parse(wake.body);
expect(w.textUndef).toBe(true);
expect(w.bytesUndef).toBe(true);
expect(w.jsonUndef).toBe(true);
expect(w.kind).toBe("wake_batch");
expect(w.sessionNull).toBe(true);
expect(w.corr).toBe("");
expect(w.tenant).toBe("sim");

// ── bound-fetch resume: prod's per-event bag filled from the fold ──
const sf = scenario({ entry: "fetcher.mjs" });
const heldF = sf.inbound({ path: "/f" });
const done = heldF.fetch(/upstream/).resolve({
  status: 200,
  body: "OK",
  headers: { "content-type": "text/plain" },
});
const fb = JSON.parse(done.body);
expect(fb.kind).toBe("fetch_chunk");
expect(fb.seq).toBe(0);
expect(fb.byteOffset).toBe(0);
expect(fb.final).toBe(true);
expect(fb.status).toBe(200);
expect(fb.bytesLen).toBe(2);
expect(fb.headers).toEqual({ "content-type": "text/plain" });

// ── streamed fetch: cumulative byteOffset per event, headers on seq 0 only ──
const ss = scenario({ entry: "streamer.mjs" });
const heldS = ss.inbound({ path: "/s" });
const doneS = heldS.fetch(/upstream/).stream(["abc", "de"], { headers: { etag: "x" } });
const parts = doneS.body.split("|").map((x) => JSON.parse(x));
expect(parts[0]).toEqual({ off: 0, final: false, hasHeaders: true });
expect(parts[1]).toEqual({ off: 3, final: false, hasHeaders: false });
expect(parts[2]).toEqual({ off: 5, final: true, hasHeaders: false });
