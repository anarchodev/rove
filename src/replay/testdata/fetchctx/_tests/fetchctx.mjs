// Fetch-resume ctx override (decisions.md §4.14) — the sim matches prod
// (worker_streaming.fetchResumeCtx): a held-chain after.fetch resume reads the
// fetch's own ctx if present, else the chain's next({ctx}). Regression guard
// for the sim/prod disagreement on a WS fetch resume's request.ctx.
import { scenario, expect } from "rewind:test";

const s = scenario({});
const ws = s.ws({ path: "/" });

// No fetch ctx → request.ctx is the chain's next({tag}).
const m1 = ws.receive(JSON.stringify({ t: "noctx" }));
expect(m1).toHaveFetched(/x\.test/);
const r1 = m1.fetch(/x\.test/).resolve({ status: 200 });
expect(r1).toHaveWritten("saw", { tag: "chain-42" });

// Fetch carries its own ctx → it wins over the chain's next({tag}).
const m2 = ws.receive(JSON.stringify({ t: "withctx" }));
const r2 = m2.fetch(/x\.test/).resolve({ status: 200 });
expect(r2).toHaveWritten("saw", { f: "FF" });
