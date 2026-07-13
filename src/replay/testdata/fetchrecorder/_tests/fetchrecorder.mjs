// Fetch recorder ≡ prod (issue #24): the effect entry carries the full option
// bag prod reads (headers/stream/timeoutMs/maxChunkBytes/maxTotalBytes, in
// the public spellings), arms return unique ftch_
// ids that resumes echo as request.fetchId, fetchesPending threads through the
// folds, status/bodyTruncated are terminal-only (request.ok does not exist,
// issue #7), and .stream() of a fetch
// issued WITHOUT stream:true fails loud.
import { scenario, expect } from "rewind:test";
const s = scenario({});

// ── option bag: toHaveSent matches headers + defaults ──
const h = s.inbound({ path: "/" });
expect(h).toHaveSent("fetch", {
  url: "https://a.example/x",
  headers: { "x-tok": "A" },
  stream: false,
  timeoutMs: 30000,
  maxChunkBytes: 262144,
  maxTotalBytes: 52428800,
});
expect(h).not.toHaveSent("fetch", { url: "https://a.example/x", headers: { "x-tok": "WRONG" } });
expect(h).not.toHaveSent("fetch", { url: "https://a.example/x", stream: true });

// ── unique ids: distinct per arm, recorded on the effect entry ──
const ids = h.kv("ids");
expect(ids.a).toMatch(/^ftch_/);
expect(ids.b).toMatch(/^ftch_/);
expect(ids.a !== ids.b).toBe(true);
expect(h).toHaveSent("fetch", { id: ids.a, url: "https://a.example/x" });
expect(h).toHaveSent("fetch", { id: ids.b, url: "https://b.example/y" });

// ── correlate two concurrent fetches by returned id through their resumes ──
// Independent single-resolve branches: both fetches still outstanding when
// either result arrives → fetchesPending = 2 ("including this one").
const ra = h.fetch(/a\.example/).resolve({ status: 200, body: "A" });
expect(ra.kv("seen/a")).toEqual({ idMatches: true, pending: 2, status: 200, hasOk: false, done: true });
const rb = h.fetch(/b\.example/).resolve({ status: 201, body: "B" });
expect(rb.kv("seen/b")).toEqual({ idMatches: true, pending: 2, status: 201, hasOk: false, done: true });

// Ordered arrival (whenConcurrent): pending counts down 2 → 1, and the
// documented `done && fetchesPending === 1` last-result pattern fires on the
// final leg.
const w = h.whenConcurrent([
  { match: /a\.example/, resolve: { body: "A" }, label: "a" },
  { match: /b\.example/, resolve: { body: "B" }, label: "b" },
]);
const [last] = w.orders([["a", "b"]]);
expect(last.kv("seen/a")).toEqual({ idMatches: true, pending: 2, status: 200, hasOk: false, done: true });
expect(last.kv("seen/b")).toEqual({ idMatches: true, pending: 1, status: 200, hasOk: false, done: true });

// ── streaming: chunk events are bare (no status/bodyTruncated until final) ──
const st = s.inbound({ path: "/stream" });
const done = st.fetch(/s\.example/).stream(["he", "llo"]);
expect(done.kv("chunk/0")).toEqual({ hasStatus: false, hasOk: false, hasTruncated: false, pending: 1 });
expect(done.kv("chunk/1")).toEqual({ hasStatus: false, hasOk: false, hasTruncated: false, pending: 1 });
expect(done.kv("final")).toEqual({ status: 200, hasOk: false, truncated: false, seq: 2, pending: 1, acc: "hello" });

// ── .stream() on a NON-streaming fetch fails loud ──
let threw = null;
try { h.fetch(/a\.example/).stream(["x"]); } catch (e) { threw = String(e); }
expect(threw).toMatch(/WITHOUT stream:true/);
