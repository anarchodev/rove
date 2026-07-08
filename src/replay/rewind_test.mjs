// rewind:test — the saga test library (docs/plans/sim-test-framework.md,
// "The saga test model"). This is the JS layer over the ONE native atom,
// `simulate(world) → bundle`: the scenario, the lazy activation tree, the
// fetch→fetch_chunk fold, the clock, and the `expect` matchers all live here.
//
// It runs inside the harness reactor. `simulate` is bridged over the KV channel
// (harness.zig): stash a world, trigger the run, parse the bundle. Assertions
// stream to the host as they resolve (a failure records and continues — it does
// NOT throw, so every assertion in a file runs). Snapshots read/write through
// the same channel.
//
// The bundle shape (src/replay/root.zig emitWorld):
//   { activation, export, response:{status,headers,cookies}, disposition:"terminal"|"held",
//     body|ctx, effects:[ {kind:"read"|"write"|"delete"|"fetch"|"webhook"|"email"|
//                          "schedule"|"cron"|"timer"|"kv-wake"|"stream"|"log", …} ],
//     error, ok, divergence? }

const WORLD_KEY = "\x00rt/world";
const RUN_KEY = "\x00rt/run";
const ASSERT_KEY = "\x00rt/assert";
const SNAP_PREFIX = "\x00rt/snap/";
const UPDATE_KEY = "\x00rt/update";

const UPDATE = kv.get(UPDATE_KEY) === "1";

// ── the atom ────────────────────────────────────────────────────────────────

/** Run one world on the sim reactor, return its parsed bundle. */
function simulate(world) {
  kv.set(WORLD_KEY, JSON.stringify(world));
  const raw = kv.get(RUN_KEY);
  return JSON.parse(raw);
}

/** Stream one assertion outcome to the host (never throws — fails locally). */
function record(name, pass, detail) {
  kv.set(ASSERT_KEY, JSON.stringify({ name, pass, detail: detail === undefined ? null : detail }));
  return pass;
}

// ── helpers ─────────────────────────────────────────────────────────────────

const NODE = Symbol("rewind.node");
const isNode = (v) => v && typeof v === "object" && v[NODE] === true;

// KV values are byte strings the handler parses itself. Only decode STRUCTURED
// JSON (objects / arrays) for ergonomic assertions; leave scalar-shaped strings
// ("10", "true", "null") as the strings the handler actually observes — else a
// stored "10" would compare as the number 10, and "null" as absent.
function tryParse(v) {
  if (typeof v !== "string") return v;
  const c = v.length ? v[0] : "";
  if (c !== "{" && c !== "[") return v;
  try { return JSON.parse(v); } catch (_) { return v; }
}

function toMs(v) {
  if (v == null) return 0;
  if (typeof v === "number") return v;
  const t = Date.parse(v);
  return Number.isNaN(t) ? 0 : t;
}

function toRe(m) {
  if (m instanceof RegExp) return m;
  // A plain string matches as a substring.
  return new RegExp(String(m).replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
}

function matchUrl(url, m) {
  if (m == null) return true;
  return toRe(m).test(String(url == null ? "" : url));
}

function deepEq(a, b) {
  if (a === b) return true;
  if (typeof a !== typeof b) return false;
  if (a && b && typeof a === "object") {
    const ka = Object.keys(a), kb = Object.keys(b);
    if (Array.isArray(a) !== Array.isArray(b)) return false;
    if (ka.length !== kb.length) return false;
    for (const k of ka) { if (!deepEq(a[k], b[k])) return false; }
    return true;
  }
  return false;
}

/** Every key in `subset` deep-equals the same path in `obj`. Objects match
 *  partially (only the named keys); ARRAYS match exactly (length + elements),
 *  so `{ items: ['a'] }` does NOT match a three-element `items`. */
function subsetMatch(obj, subset) {
  if (subset == null) return true;
  if (Array.isArray(subset)) return deepEq(obj, subset);
  if (typeof subset !== "object") return deepEq(obj, subset);
  if (obj == null || typeof obj !== "object") return false;
  for (const k of Object.keys(subset)) {
    if (subset[k] !== null && typeof subset[k] === "object") {
      if (!subsetMatch(obj[k], subset[k])) return false;
    } else if (!deepEq(obj[k], subset[k])) return false;
  }
  return true;
}

/** base kv object, overlaid with a bundle's writes/deletes (read-your-writes). */
function foldKv(base, effects) {
  const kvOut = Object.assign({}, base || {});
  for (const e of effects || []) {
    if (e.kind === "write") kvOut[e.key] = e.value;
    else if (e.kind === "delete") delete kvOut[e.key];
  }
  return kvOut;
}

function fmt(x) {
  try { return typeof x === "string" ? JSON.stringify(x) : JSON.stringify(x); }
  catch (_) { return String(x); }
}

// stable stringify for snapshots (sorted keys → order-independent)
function stable(v) {
  if (v === null || typeof v !== "object") return JSON.stringify(v);
  if (Array.isArray(v)) return "[" + v.map(stable).join(",") + "]";
  const keys = Object.keys(v).sort();
  return "{" + keys.map((k) => JSON.stringify(k) + ":" + stable(v[k])).join(",") + "}";
}

// ── the scenario + activation tree ───────────────────────────────────────────

export function scenario(cfg = {}) {
  return new Scenario(cfg);
}

class Scenario {
  constructor(cfg) {
    this.sourceDir = cfg.sourceDir || null;
    this.inlineSources = cfg.sources || null; // { "index.mjs": "…source…" }
    this.baseKv = cfg.kv || {};
    this.now = toMs(cfg.now);
    this.seed = cfg.seed || 0;
    this.entry = cfg.entry || "index.mjs";
  }

  _base(partial) {
    const w = Object.assign(
      { entry: this.entry, seed: this.seed, now_ms: this.now, kv: this.baseKv },
      partial,
    );
    if (this.sourceDir) w.source_dir = this.sourceDir;
    if (this.inlineSources) {
      w.sources = Object.keys(this.inlineSources).map((path) => ({
        path, kind: "handler", source: this.inlineSources[path],
      }));
    }
    return w;
  }

  /** An inbound HTTP activation → the root node. */
  inbound(req = {}) {
    return new Node(this, this._base({
      activation: "inbound",
      request: {
        method: req.method || "GET",
        path: req.path || "/",
        host: req.host || "",
        headers: req.headers || {},
        body: req.body,
        ip: req.ip,
      },
    }));
  }

  /** A DETACHED durable delivery callback (`webhook.send` / `email.send` `on`),
   *  authored directly — NOT folded from an emitter. The send fires after the
   *  handler commits and its `on` module runs later as its own activation, so
   *  you test that module in isolation given a delivery result. Mirrors the
   *  flattened send_callback surface (dispatcher.zig): the response on
   *  `request.status`/`.ok`/`.bytes`, the echoed `ctx` bare on `request.ctx`,
   *  and delivery metadata on `request.activation.*`.
   *
   *  spec: { on: "<result-module path>", result?: {status, ok?, body?, attempts?,
   *          error?, id?, headers?}, ctx?: <echoed context> }
   */
  sendCallback(spec = {}) {
    if (typeof spec.on !== "string")
      throw new Error("sendCallback({ on }): `on` must be the result-handler module path");
    const r = spec.result || {};
    const status = r.status != null ? r.status : 200;
    return new Node(this, this._base({
      entry: spec.on, // the on_result module IS this activation's entry
      activation: "send_callback",
      export: "default",
      ctx: spec.ctx === undefined ? null : spec.ctx,
      request: {
        status,
        ok: r.ok != null ? r.ok : (status >= 200 && status < 300),
        done: true,
        body: r.body != null ? r.body : null,
        activation: {
          kind: "send_callback",
          attempts: r.attempts != null ? r.attempts : 1,
          error: r.error != null ? r.error : null,
          id: r.id != null ? r.id : null,
          headers: r.headers || {},
        },
      },
    }));
  }

  /** A held WebSocket connection. The upgrade runs NO code (the chain parks
   *  with ctx `{}`); each inbound frame runs `onMessage`, so the fold starts at
   *  the first `.receive(frame)`. Per-connection ctx threads via each frame's
   *  `next({ctx})` and KV writes fold forward (read-your-writes across frames);
   *  outbound frames are `stream.write` (assert with `toHaveSentFrame`). */
  ws(cfg = {}) {
    return new WsConnection(this, cfg);
  }
}

/** One activation — a lazy thunk over `simulate(world)`, memoized on force. */
class Node {
  constructor(scn, world) {
    this[NODE] = true;
    this.scenario = scn;
    this.world = world;
    this._b = null;
  }

  force() {
    if (this._b === null) this._b = simulate(this.world);
    return this._b;
  }

  get bundle() { return this.force(); }
  get status() { const b = this.force(); return b.response ? b.response.status : undefined; }
  get ok() { return this.force().ok; }
  get disposition() { return this.force().disposition; }
  get effects() { return this.force().effects || []; }
  get error() { return this.force().error; }
  get response() { return this.force().response; }
  /** The terminal body (or, when held, the ctx). Already a decoded JSON value
   *  in the bundle — NOT re-parsed, so a string body like "42" stays the string
   *  "42" the response actually carries. */
  get body() {
    const b = this.force();
    return b.disposition === "held" ? b.ctx : b.body;
  }
  get ctx() { const b = this.force(); return b.disposition === "held" ? b.ctx : undefined; }

  _byKind(kind) { return this.effects.filter((e) => e.kind === kind); }

  /** Outbound frames/chunks this activation wrote (`stream.write`), in order —
   *  the content, not just the byte count. WS replies and SSE lines both land
   *  here. */
  get frames() { return this._byKind("stream").map((e) => e.data); }

  /** Effective value of `key` after this activation (base kv + its writes).
   *  Absent/deleted keys read `null` — the same `kv.get` returns to the handler
   *  for a miss — so tests mirror what the handler actually observes. */
  kv(key) {
    const eff = foldKv(this.world.kv, this.force().effects);
    return key in eff ? tryParse(eff[key]) : null;
  }

  // ── held-connection resume folds ──
  // Every `after.*` wake fires ONLY while the connection is held (the handler
  // returned `next()` or is streaming) — inert otherwise. So each resume below
  // requires this node to be held, and threads the held continuation forward:
  // the parent's writes fold into the child's KV overlay, and the child's
  // `request.ctx` is the effect's own ctx (fetch) or the held `next({ctx})`
  // (timer/kv/disconnect — they carry no ctx of their own).

  /** Locate an emitted `after.fetch` by url matcher → a handle that resolves
   *  its upstream result into the dependent `fetch_chunk` resume. */
  fetch(matcher) {
    requireHeld(this, "fetch");
    const fx = this._byKind("fetch");
    const hit = fx.find((e) => matchUrl(e.url, matcher));
    if (!hit) {
      const seen = fx.map((f) => f.url).join(", ") || "none";
      throw new Error(`fetch(${matcher}): no emitted after.fetch matched (saw: ${seen})`);
    }
    return new FetchHandle(this, hit);
  }

  /** Advance the clock; `.fire()` delivers the due `after.ms` timer wake. */
  get clock() {
    const node = this;
    return {
      advance(delta) {
        const ms = typeof delta === "number" ? delta : parseDuration(delta);
        return new Clock(node, ms);
      },
    };
  }

  /** An `after.kv` wake: a change under a watched prefix resumes the held
   *  connection. `changes` is a `{ key: value | null }` map folded into the KV
   *  overlay (null = delete); each surfaces on `request.activation.wakes`.
   *  `opts.prefix` selects which armed `after.kv` fires when several are armed. */
  wakeKv(changes = {}, opts = {}) {
    requireHeld(this, "wakeKv");
    const parent = this;
    const pb = parent.force();
    const armed = parent._byKind("kv-wake");
    if (!armed.length) throw new Error("wakeKv(): the activation armed no after.kv wake");
    const kw = opts.prefix ? armed.find((e) => matchUrl(e.prefix, opts.prefix)) : armed[0];
    if (!kw) throw new Error(`wakeKv(): no armed after.kv matched prefix ${opts.prefix}`);
    const kv = foldKv(parent.world.kv, pb.effects);
    const now = (parent.world.now_ms || 0) + 1;
    const entries = [];
    for (const key of Object.keys(changes)) {
      const v = changes[key];
      if (v === null) { delete kv[key]; entries.push({ kind: "kv", key, op: "d", firedAt: now }); }
      else { kv[key] = typeof v === "string" ? v : JSON.stringify(v); entries.push({ kind: "kv", key, op: "p", firedAt: now }); }
    }
    return new Node(parent.scenario, carrySources(parent.world, {
      entry: parent.world.entry,
      activation: "wake_batch",
      export: kw.on || "onWake",
      ctx: heldCtx(parent),
      kv,
      seed: (parent.world.seed || 0) + 1,
      now_ms: now,
      request: { activation: { kind: "wake_batch", wakes: entries, overflow: { lost_oldest: 0 } } },
    }));
  }

  /** The client disconnected while the connection was held → the `onDisconnect`
   *  resume (a held stream's terminal cleanup activation). */
  disconnect() {
    requireHeld(this, "disconnect");
    const parent = this;
    const pb = parent.force();
    return new Node(parent.scenario, carrySources(parent.world, {
      entry: parent.world.entry,
      activation: "disconnect",
      export: "onDisconnect",
      ctx: heldCtx(parent),
      kv: foldKv(parent.world.kv, pb.effects),
      seed: (parent.world.seed || 0) + 1,
      now_ms: (parent.world.now_ms || 0) + 1,
      request: { activation: { kind: "disconnect" } },
    }));
  }
}

/** A resume fold is meaningful only on a HELD node — `after.*` wakes never
 *  armed on an activation that returned a terminal response. */
function requireHeld(node, verb) {
  if (node.force().disposition !== "held")
    throw new Error(`${verb}: this activation returned a terminal response (it did not next()/hold), so its connection wakes never armed — after.* fires only while the socket is held`);
}

/** The held continuation's parked `next({ctx})` — the ctx a timer/kv/disconnect
 *  resume observes on `request.ctx` (these triggers carry no ctx of their own). */
function heldCtx(node) {
  const b = node.force();
  const c = b.disposition === "held" ? b.ctx : null;
  return c === undefined ? null : c;
}

function parseDuration(s) {
  const m = /^(\d+(?:\.\d+)?)\s*(ms|s|m|h|d)?$/.exec(String(s).trim());
  if (!m) throw new Error(`clock.advance: unrecognized duration ${JSON.stringify(s)} (use e.g. 500, "1500ms", "1.5s", "2m", "1h", "3d")`);
  const n = Number(m[1]);
  return n * ({ ms: 1, s: 1000, m: 60000, h: 3600000, d: 86400000 }[m[2] || "ms"]);
}

class Clock {
  constructor(node, ms) { this.node = node; this.ms = ms; }
  /** Fire the due `after.ms` timer as a wake_batch resume, clock advanced. */
  fire() {
    const parent = this.node;
    requireHeld(parent, "clock.advance().fire()");
    const pb = parent.force();
    const timers = parent._byKind("timer");
    if (!timers.length) throw new Error("clock.advance().fire(): the activation armed no after.ms timer wake");
    const t = timers[0];
    const now = (parent.world.now_ms || 0) + this.ms;
    return new Node(parent.scenario, carrySources(parent.world, {
      entry: parent.world.entry,
      activation: "wake_batch",
      export: t.on || "onWake",
      ctx: heldCtx(parent),
      kv: foldKv(parent.world.kv, pb.effects),
      seed: (parent.world.seed || 0) + 1,
      now_ms: now,
      request: { activation: { kind: "wake_batch", wakes: [{ kind: "timer", firedAt: now }], overflow: { lost_oldest: 0 } } },
    }));
  }
}

/** A located fetch cmd → resolve its upstream response into the dependent
 *  `fetch_chunk` activation, folding the parent's writes/ctx/clock forward. */
class FetchHandle {
  constructor(node, fx) { this.node = node; this.fx = fx; }

  resolve(response = {}) {
    const parent = this.node;
    const pb = parent.force();
    const status = response.status != null ? response.status : (response.timeout ? 0 : 200);
    const world = carrySources(parent.world, {
      entry: parent.world.entry,
      activation: "fetch_chunk",
      export: this.fx.on || "onFetchResult",
      ctx: this.fx.ctx === undefined ? null : this.fx.ctx,
      kv: foldKv(parent.world.kv, pb.effects),
      seed: (parent.world.seed || 0) + 1,
      now_ms: (parent.world.now_ms || 0) + (response.latencyMs || 1),
      request: {
        status,
        // The real engine sets fetch/callback `ok` = status in [200,300) (a 3xx
        // is NOT ok) — match it so a handler's `if (request.ok)` branch agrees.
        ok: response.ok != null ? response.ok : (!response.timeout && status >= 200 && status < 300),
        done: response.done != null ? response.done : true,
        body: response.body != null ? response.body : null,
      },
    });
    return new Node(parent.scenario, world);
  }

  /** Fork the shared prefix into one dependent node per response. */
  branch(responses) { return responses.map((r) => this.resolve(r)); }

  /** Iterate every case's dependent node (invariant-across-futures). */
  cases(responses) {
    const self = this;
    return { forEachPath(fn) { return responses.map((r) => fn(self.resolve(r))); } };
  }
}

function carrySources(parentWorld, world) {
  if (parentWorld.source_dir) world.source_dir = parentWorld.source_dir;
  if (parentWorld.sources) world.sources = parentWorld.sources;
  return world;
}

// ── WebSocket held-socket fold ────────────────────────────────────────────

/** A held WS connection: a stateful cursor over ctx + KV overlay that folds
 *  forward one frame at a time. Not a node itself (the upgrade runs no code). */
class WsConnection {
  constructor(scn, cfg) {
    this.scenario = scn;
    this.path = cfg.path || "/";
    this.host = cfg.host || "";
  }

  /** Deliver an inbound frame → the `onMessage` activation for it. Text by
   *  default; `{ binary: true }` delivers `data` as a binary frame. */
  receive(data, opts = {}) {
    return this._frame(this.scenario.baseKv, {}, 0, data, opts);
  }

  /** Client close before any frame → `onDisconnect` (ctx `{}`). */
  disconnect() {
    return this._disc(this.scenario.baseKv, {}, 0);
  }

  // Build one ws_message world. `ctx` is the connection ctx this frame runs
  // under; `kv` is the folded overlay; `seed` is the prior activation's seed.
  _frame(kv, ctx, seed, data, opts) {
    const binary = !!(opts && opts.binary);
    const activation = binary
      ? { kind: "ws_message", opcode: 2, dataB64: b64(data) }
      : { kind: "ws_message", opcode: 1, data: String(data) };
    const world = this.scenario._base({
      entry: this.scenario.entry,
      activation: "ws_message",
      export: "onMessage",
      ctx,
      kv,
      seed: seed + 1,
      request: { activation },
    });
    return new WsNode(this.scenario, world, this);
  }

  _disc(kv, ctx, seed) {
    const world = this.scenario._base({
      entry: this.scenario.entry,
      activation: "disconnect",
      export: "onDisconnect",
      ctx,
      kv,
      seed: seed + 1,
      request: { activation: { kind: "disconnect" } },
    });
    return new WsNode(this.scenario, world, this);
  }
}

/** A ws_message / onDisconnect activation node that can fold the NEXT frame:
 *  the connection ctx after this frame is its `next({ctx})` if it re-held, else
 *  the ctx it ran under; its KV writes fold into the next frame's overlay. */
class WsNode extends Node {
  constructor(scn, world, conn) {
    super(scn, world);
    this._conn = conn;
  }
  _nextCtx() {
    const b = this.force();
    if (b.disposition === "held") return b.ctx === undefined ? {} : b.ctx;
    return this.world.ctx; // terminal onMessage: connection ctx unchanged
  }
  receive(data, opts) {
    return this._conn._frame(foldKv(this.world.kv, this.force().effects), this._nextCtx(), this.world.seed || 0, data, opts);
  }
  disconnect() {
    return this._conn._disc(foldKv(this.world.kv, this.force().effects), this._nextCtx(), this.world.seed || 0);
  }
}

/** Standard base64 (matches the epilogue's `atob`) — for binary WS frames,
 *  without depending on a `btoa` in the reactor base. */
function b64(u) {
  const bytes = typeof u === "string" ? Array.from(u, (c) => c.charCodeAt(0) & 0xff) : Array.from(u);
  const A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const b0 = bytes[i], b1 = bytes[i + 1], b2 = bytes[i + 2];
    out += A[b0 >> 2];
    out += A[((b0 & 3) << 4) | ((b1 || 0) >> 4)];
    out += i + 1 < bytes.length ? A[((b1 & 15) << 2) | ((b2 || 0) >> 6)] : "=";
    out += i + 2 < bytes.length ? A[b2 & 63] : "=";
  }
  return out;
}

// ── expect ────────────────────────────────────────────────────────────────

let snapCounter = 0;

export function expect(value) {
  return new Matcher(value, false);
}

class Matcher {
  constructor(value, negated) { this.value = value; this.negated = negated; }
  get not() { return new Matcher(this.value, !this.negated); }

  _record(name, rawPass, detail) {
    const pass = this.negated ? !rawPass : rawPass;
    return record((this.negated ? "not " : "") + name, pass, detail);
  }

  _node(matcherName) {
    if (!isNode(this.value)) {
      // A type error is unconditionally a failure — record it RAW, bypassing
      // `.not` (else `expect(notANode).not.toHaveWritten(...)` would flip the
      // failure to a spurious pass).
      record(`${matcherName} (needs a node)`, false, { message: `got ${typeof this.value}` });
      return null;
    }
    return this.value;
  }

  // ── value matchers ──
  toBe(x) { return this._record(`toBe ${fmt(x)}`, this.value === x, { actual: this.value, expected: x }); }
  toEqual(x) { return this._record(`toEqual ${fmt(x)}`, deepEq(this.value, x), { actual: this.value, expected: x }); }
  toMatch(re) { return this._record(`toMatch ${re}`, toRe(re).test(String(this.value)), { actual: this.value }); }
  toBeTruthy() { return this._record("toBeTruthy", !!this.value, { actual: this.value }); }
  toBeGreaterThan(n) { return this._record(`toBeGreaterThan ${n}`, this.value > n, { actual: this.value }); }
  toContain(x) {
    const ok = typeof this.value === "string"
      ? this.value.includes(x)
      : Array.isArray(this.value) && this.value.some((e) => deepEq(e, x));
    return this._record(`toContain ${fmt(x)}`, ok, { actual: this.value });
  }

  // ── node matchers ──
  toHaveWritten(key, subset) {
    const node = this._node("toHaveWritten");
    if (!node) return false;
    const writes = node.effects.filter((e) => e.kind === "write" && e.key === key);
    const pass = writes.some((w) => subsetMatch(tryParse(w.value), subset));
    return this._record(`toHaveWritten ${fmt(key)}`, pass, {
      subset: subset === undefined ? null : subset,
      writes: writes.map((w) => ({ key: w.key, value: tryParse(w.value) })),
    });
  }

  toHaveFetched(matcher) {
    const node = this._node("toHaveFetched");
    if (!node) return false;
    const fx = node.effects.filter((e) => e.kind === "fetch");
    return this._record(`toHaveFetched ${matcher == null ? "" : matcher}`, fx.some((e) => matchUrl(e.url, matcher)), {
      fetched: fx.map((e) => e.url),
    });
  }

  /** A `stream.write` frame/line whose content matches (WS reply or SSE line). */
  toHaveSentFrame(matcher) {
    const node = this._node("toHaveSentFrame");
    if (!node) return false;
    const frames = node.frames;
    const pass = frames.some((f) => matchUrl(f == null ? "" : f, matcher));
    return this._record(`toHaveSentFrame ${matcher == null ? "" : matcher}`, pass, { frames });
  }

  toHaveSent(kind, subset) {
    const node = this._node("toHaveSent");
    if (!node) return false;
    const sent = node.effects.filter((e) => e.kind === kind);
    const pass = sent.some((e) => subsetMatch(e, subset));
    return this._record(`toHaveSent ${fmt(kind)}`, pass, { subset: subset === undefined ? null : subset, sent });
  }

  toHaveScheduled(matcher) {
    const node = this._node("toHaveScheduled");
    if (!node) return false;
    const sch = node.effects.filter((e) =>
      e.kind === "schedule" || e.kind === "timer" || e.kind === "cron" || e.kind === "kv-wake");
    const pass = sch.some((e) => matcher == null
      || matchUrl(e.target || e.on || e.prefix || String(e.when || e.ms || ""), matcher));
    return this._record(`toHaveScheduled ${matcher == null ? "" : matcher}`, pass, { scheduled: sch });
  }

  toMatchSnapshot(name) {
    const node = this._node("toMatchSnapshot");
    if (!node) return false;
    const key = name || `snapshot-${++snapCounter}`;
    const facets = snapshotFacets(node.force());
    const current = stable(facets);
    const stored = kv.get(SNAP_PREFIX + key);
    if (stored == null) {
      kv.set(SNAP_PREFIX + key, current); // new snapshot — write + pass
      return this._record(`toMatchSnapshot ${fmt(key)}`, true, { new: true });
    }
    if (stored === current) return this._record(`toMatchSnapshot ${fmt(key)}`, true);
    if (UPDATE) {
      kv.set(SNAP_PREFIX + key, current); // rebaseline under --update
      return this._record(`toMatchSnapshot ${fmt(key)}`, true, { updated: true });
    }
    return this._record(`toMatchSnapshot ${fmt(key)}`, false, { stored: tryParse(stored), current: facets });
  }
}

/** The stable facets a snapshot captures: response head, disposition, body/ctx,
 *  and the writes/cmds from the effect log (logs + reads excluded — noisy). */
function snapshotFacets(b) {
  const cmds = (b.effects || []).filter((e) =>
    e.kind !== "read" && e.kind !== "log");
  return {
    response: b.response || null,
    disposition: b.disposition,
    body: b.disposition === "held" ? b.ctx : (b.body === undefined ? null : b.body),
    effects: cmds,
    ok: b.ok,
  };
}
