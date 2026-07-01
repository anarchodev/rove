#!/usr/bin/env python3
"""Scenario driver — the *saga* layer over the single-activation `runWorld`.

`rewind sim <world.json>` runs ONE activation (the arenajs engine is process-
global / one-shot — `src/replay/root.zig` §13). A real request is a *fold* of
activations linked by `Cmd(http_fetch) -> fetch_chunk Msg`
(`replay-and-sim.md` §2). This driver is that fold: it runs an activation,
reads the fetches it emitted, matches each to a scenario-supplied response,
synthesises the next activation's world (threading `ctx` + the evolving `kv`
overlay), and repeats — ordering concurrent resumes with a **seeded** or
**explicit** scheduler so the whole run is deterministic yet interleaving-aware.

It shells out to the real `rewind sim` per activation (one process per
activation is the one-shot engine's native shape), so this exercises the ACTUAL
engine, not a mock. Offline: no cluster, no network.

    scenario.json:
      { kind, seed, entry, now_ms, missPolicy,
        request:{method,path,headers,body,ip},   # the inbound activation
        kv:{...}, kvAbsent:[...],                 # initial state, folded forward
        fetches:[ {id, match:{method?,url|urlPrefix|urlRegex},
                   latency_ms, responses:[ {status,body,headers?}, ... ]} ],
        scheduler:{ mode:"seed"|"order"|"fifo", order?:[ "ledger","stripe#1" ] } }
"""
import argparse, json, os, random, re, subprocess, sys, tempfile


def match_fetch(fetches, wake):
    """Find the scenario `fetches` entry whose matcher matches this fetch wake."""
    url, method = wake.get("url", ""), (wake.get("method") or "GET").upper()
    for f in fetches:
        m = f.get("match", {})
        if "method" in m and m["method"].upper() != method:
            continue
        if "url" in m and m["url"] != url:
            continue
        if "urlPrefix" in m and not url.startswith(m["urlPrefix"]):
            continue
        if "urlRegex" in m and not re.search(m["urlRegex"], url):
            continue
        return f
    return None


def synth_world(ev, kv, absent, base):
    """Build a single-activation world.json for the popped event."""
    w = {
        "entry": base["entry"],
        "seed": base["seed"],
        "now_ms": base["now_ms"],
        "missPolicy": base["missPolicy"],
        "kv": kv,
        "kvAbsent": sorted(absent),
    }
    if ev["kind"] == "inbound":
        w["activation"] = "inbound"
        w["request"] = base["request"]
    elif ev["kind"] == "fetch_chunk":
        r = ev["response"]
        st = r.get("status", 200)
        w["activation"] = "fetch_chunk"
        w["export"] = ev["to"] or "onFetchResult"
        w["request"] = {"status": st, "ok": st < 400, "done": True,
                        "fetchId": ev["id"], "body": r.get("body")}
        if ev.get("ctx") is not None:
            w["ctx"] = ev["ctx"]
    else:
        raise SystemExit(f"unsupported event kind: {ev['kind']}")
    return w


def run_activation(rewind_bin, world, source_dir):
    """Run ONE activation through the real `rewind sim`; return its output bundle."""
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as tf:
        json.dump(world, tf)
        wp = tf.name
    try:
        cmd = [rewind_bin, "sim", wp, "--miss-policy", world["missPolicy"]]
        if source_dir:
            cmd += ["--source-dir", source_dir]
        p = subprocess.run(cmd, capture_output=True, text=True)
        if p.returncode != 0:
            raise SystemExit(f"rewind sim failed ({p.returncode}):\n{p.stderr}\n{p.stdout}")
        return json.loads(p.stdout)
    finally:
        os.unlink(wp)


class Scheduler:
    """A seeded discrete-event queue over pending resumes/events.

    seed  — deliver by simulated time (emit_clock + latency + seeded jitter);
            vary the seed to explore interleavings, deterministic per seed.
    order — deliver in an explicit id order (pin a known interleaving).
    fifo  — deliver in emission order (the trivial deterministic default).
    """
    def __init__(self, spec, seed, clock0):
        self.mode = spec.get("mode", "seed")
        self.order = list(spec.get("order", []))
        self.rng = random.Random(seed)
        self.clock = clock0
        self.pending = []   # list of (sim_time, seq, event)
        self.seq = 0

    def enqueue(self, ev, latency_ms):
        jitter = self.rng.uniform(0, latency_ms * 0.5) if self.mode == "seed" else 0
        t = self.clock + latency_ms + jitter
        self.pending.append((t, self.seq, ev))
        self.seq += 1

    def pop(self):
        if not self.pending:
            return None
        if self.mode == "order":
            want = next((i for i in self.order if any(e[2]["id"] == i for e in self.pending)), None)
            idx = 0 if want is None else next(k for k, e in enumerate(self.pending) if e[2]["id"] == want)
        elif self.mode == "fifo":
            idx = min(range(len(self.pending)), key=lambda k: self.pending[k][1])
        else:  # seed
            idx = min(range(len(self.pending)), key=lambda k: (self.pending[k][0], self.pending[k][1]))
        t, _, ev = self.pending.pop(idx)
        self.clock = max(self.clock, t)
        return ev


def drive(scenario, rewind_bin, source_dir):
    base = {k: scenario.get(k, d) for k, d in
            (("entry", "index.mjs"), ("seed", 0), ("now_ms", 0), ("missPolicy", "resolve"))}
    base["request"] = scenario.get("request", {"method": "GET", "path": "/"})
    fetches = scenario.get("fetches", [])
    attempts = {}                       # fetch id -> next response index (retry sequencing)
    kv = dict(scenario.get("kv", {}))   # the overlay, folded forward
    absent = set(scenario.get("kvAbsent", []))
    sched = Scheduler(scenario.get("scheduler", {}), base["seed"], base["now_ms"])

    trace, sends, unmatched, delivery_order = [], [], [], []
    final_response = None

    sched.enqueue({"kind": "inbound", "id": "inbound"}, 0)

    while (ev := sched.pop()) is not None:
        delivery_order.append(ev["id"])
        out = run_activation(rewind_bin, synth_world(ev, kv, absent, base), source_dir)
        # The activation's EFFECT LOG — one ordered list (occurrence order) of
        # reads / writes / cmds. Everything below reads from it.
        effects = out.get("effects", [])

        # 1. fold writes/deletes into the overlay (→ read-your-writes across acts)
        for e in effects:
            if e["kind"] == "write":
                kv[e["key"]] = e["value"]; absent.discard(e["key"])
            elif e["kind"] == "delete":
                kv.pop(e["key"], None); absent.add(e["key"])

        # 2. each emitted fetch → match a response → enqueue a resume (or unmatched)
        for e in effects:
            if e["kind"] != "fetch":
                continue
            f = match_fetch(fetches, e)
            if f is None:
                unmatched.append({"from": ev["id"], "url": e.get("url"),
                                  "method": e.get("method")})
                continue
            i = attempts.get(f["id"], 0); attempts[f["id"]] = i + 1
            resp = f["responses"][min(i, len(f["responses"]) - 1)]
            sched.enqueue({"kind": "fetch_chunk", "id": f'{f["id"]}#{i+1}',
                           "to": e.get("to"), "ctx": e.get("ctx"), "response": resp},
                          f.get("latency_ms", 0))

        # 3. record durable sends (recorded, not re-run) for the top-level rollup
        for e in effects:
            if e["kind"] in ("webhook", "email", "schedule", "cron"):
                sends.append({"from": ev["id"], **e})

        # The CLIENT response is the INBOUND activation's response HEAD (status/
        # headers/cookies); resumes run in the background.
        resp = out.get("response")
        if ev["kind"] == "inbound":
            final_response = resp
        err = out.get("error")
        trace.append({"activation": ev["id"], "export": out.get("export"),
                      "disposition": out.get("disposition"),
                      "effects": effects,
                      "error": err.get("message") if isinstance(err, dict) else None,
                      "status": (resp or {}).get("status") if isinstance(resp, dict) else None})

    return {"seed": base["seed"], "scheduler": sched.mode,
            "delivery_order": delivery_order, "final_response": final_response,
            "kv_final": kv, "sends": sends,
            "unmatched_fetches": unmatched, "trace": trace}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario")
    ap.add_argument("--source-dir", required=True)
    ap.add_argument("--rewind-bin", default="./zig-out/bin/rewind")
    ap.add_argument("--seed", type=int, help="override scenario.seed (interleaving sweep)")
    args = ap.parse_args()
    with open(args.scenario) as f:
        scenario = json.load(f)
    if args.seed is not None:
        scenario["seed"] = args.seed
    print(json.dumps(drive(scenario, args.rewind_bin, args.source_dir), indent=2))


if __name__ == "__main__":
    main()
