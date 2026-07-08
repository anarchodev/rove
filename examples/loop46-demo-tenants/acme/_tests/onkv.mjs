// Offline cross-check of on_kv_smoke_v2.py: the same acme onkv handler, the same
// held POST + trigger write, the same "woke:hello" result — pure `rewind test`.
// Agreement with the smoke's through-the-stack wake proves the after.kv held
// resume faithful.
import { scenario, expect } from "rewind:test";

const PREFIX = "onkv/";
const s = scenario({ entry: "onkv/index.mjs" });

// The held inbound: baseline-reads <prefix>flag, arms after.kv, holds via next().
const held = s.inbound({ method: "POST", path: "/onkv", body: { prefix: PREFIX } });
expect(held.disposition).toBe("held");
expect(held.ctx).toEqual({ prefix: PREFIX });
expect(held).toHaveScheduled(); // armed the after.kv watch

// A kv write under the watched prefix (what /writekv does in the smoke) resumes
// onWake, which re-reads authoritative kv and returns "woke:<value>".
const woke = held.wakeKv({ [PREFIX + "flag"]: "hello" });
expect(woke.status).toBe(200);
expect(woke.body).toBe("woke:hello"); // the smoke's core assertion, offline
