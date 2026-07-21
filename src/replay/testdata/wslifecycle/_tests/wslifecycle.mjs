// WS lifecycle parity vs the worker (#31): terminal/errored frames close the
// socket; a pre-frame close runs nothing.
import { scenario, expect } from "rewind:test";

const s = scenario({ entry: "index.mjs", now: "2026-07-01T00:00:00Z" });

// ── a pre-frame client close runs NOTHING (the chain is lazy on frame 1) ──
const pre = s.ws({ path: "/" }).disconnect();
expect(pre.disposition).toBe("terminal");
expect(pre.effects).toEqual([]);
expect(pre.kv("disconnected")).toBe(null); // onDisconnect never ran
// The socket is gone — no frame can follow a pre-frame close.
let afterPre = false;
try { pre.receive("late"); } catch (_) { afterPre = true; }
expect(afterPre).toBe(true);

// ── a held frame keeps the socket open; disconnect from it runs onDisconnect ──
const held = s.ws({ path: "/" }).receive("hi");
expect(held.disposition).toBe("held");
expect(held).toHaveSentFrame("echo:hi");
const gone = held.disconnect();
expect(gone).toHaveWritten("disconnected", "1");

// ── a TERMINAL frame closes the socket — no further frame/close is deliverable ──
const term = s.ws({ path: "/" }).receive("bye");
expect(term.disposition).toBe("terminal");
let afterTerm = false;
try { term.receive("again"); } catch (_) { afterTerm = true; }
expect(afterTerm).toBe(true);
let discTerm = false;
try { term.disconnect(); } catch (_) { discTerm = true; }
expect(discTerm).toBe(true);

// ── a THROWING frame closes WITHOUT onDisconnect — disconnect() refuses ──
const boom = s.ws({ path: "/" }).receive("boom");
expect(boom.status).toBe(500);
let discBoom = false;
try { boom.disconnect(); } catch (_) { discBoom = true; }
expect(discBoom).toBe(true);
