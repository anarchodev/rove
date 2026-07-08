// The held-WebSocket fold: a connection whose frames run onMessage, thread the
// per-connection ctx via next({ctx}), fold KV writes forward, and reply with
// stream.write frames — plus onDisconnect.
import { scenario, expect } from "rewind:test";

const s = scenario({ entry: "chat.mjs", now: "2026-07-01T00:00:00Z" });
const ws = s.ws({ path: "/chat" });

// First frame → onMessage with ctx {} → count 1, echo reply.
const m1 = ws.receive("hello");
expect(m1.disposition).toBe("held");
expect(m1).toHaveSentFrame(/"echo":"hello"/);
expect(m1).toHaveSentFrame(/"n":1/);
expect(m1).toHaveWritten("chat/last", "hello");
expect(m1.ctx).toEqual({ count: 1 });

// Next frame folds the ctx forward → count 2.
const m2 = m1.receive("world");
expect(m2).toHaveSentFrame(/"n":2/);
expect(m2.ctx).toEqual({ count: 2 });

// A control frame (ping → pong) from m2 → count 3.
const m3 = m2.receive("ping");
expect(m3).toHaveSentFrame("pong");
expect(m3.ctx).toEqual({ count: 3 });

// Disconnect threads the connection's final ctx into onDisconnect.
const closed = m2.disconnect();
expect(closed).toHaveWritten("chat/closed", { count: 2 });
