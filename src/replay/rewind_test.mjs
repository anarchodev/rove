// rewind:test — the saga test library (docs/architecture/replay-and-sim.md,
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

/** Effects that SURVIVED the activation. A thrown handler rolls its txn back
 *  in prod (500 "handler threw"), so the sim marks that activation's
 *  writes/cmds `rolledBack` — they must not fold forward or satisfy matchers
 *  (issue #10). They stay on `node.effects` for debugging. */
function live(effects) {
  return (effects || []).filter((e) => !e.rolledBack);
}

/** UTF-8 byte length of a chunk (string) or byte array — prod's fetch-chunk
 *  `byteOffset` counts wire bytes, not JS chars. */
function byteLen(x) {
  if (x == null) return 0;
  if (typeof x !== "string") return x.length;
  let n = 0;
  for (let i = 0; i < x.length; i++) {
    const c = x.charCodeAt(i);
    if (c < 0x80) n += 1;
    else if (c < 0x800) n += 2;
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < x.length &&
             x.charCodeAt(i + 1) >= 0xdc00 && x.charCodeAt(i + 1) <= 0xdfff) { n += 4; i++; }
    else n += 3;
  }
  return n;
}

/** base kv object, overlaid with a bundle's writes/deletes (read-your-writes). */
function foldKv(base, effects) {
  const kvOut = Object.assign({}, base || {});
  for (const e of live(effects)) {
    if (e.kind !== "write" && e.kind !== "delete") continue;
    // A store-tagged write/delete (platform.scope(id) / platform.root) folds into
    // that store's namespaced slot, so it never collides with the tenant's own
    // kv or another instance's — the same `__rove_store/{tag}/` layout the sim
    // base + host use at runtime.
    const slot = e.store ? ("__rove_store/" + e.store + "/" + e.key) : e.key;
    if (e.kind === "write") kvOut[slot] = e.value;
    else delete kvOut[slot];
  }
  return kvOut;
}

// ── effect views: the durable verbs run their REAL shims from the sim base, so
// they decompose to primitives in the effect log. These views read that
// primitive shape back into the readable form the matchers assert against —
// `webhook`/`email` from `_send/owed/*` markers, `schedule`/`cron` from
// `_sched/by_id/*` rows. The connection wakes `after.ms`/`after.kv` remain
// direct `{kind:"timer"|"kv-wake"}` recorder entries. ──

/** Schedules armed by this activation, each as `{ target, kind, key?, msg? }`.
 *  Durable `schedule`/`cron` are `_sched/by_id/{id}` writes — and since
 *  `cron(spec, t)` composes as `schedule(_, "__system/cron_tick", {spec,
 *  target:t})`, the customer target is unwrapped from `msg.target`. The
 *  connection wakes `after.ms`/`after.kv` are direct `{kind:"timer"|"kv-wake"}`
 *  recorder entries. */
function scheduledEffects(effects) {
  const out = [];
  for (const e of live(effects)) {
    if (e.kind === "timer") out.push({ target: e.on, kind: "timer" });
    else if (e.kind === "kv-wake") out.push({ target: e.on, kind: "kv-wake" });
    else if (e.kind === "write" && typeof e.key === "string" && e.key.startsWith("_sched/by_id/")) {
      try {
        const r = JSON.parse(e.value);
        // Unwrap the cron indirection so `toHaveScheduled(customerTarget)` still
        // matches; a plain schedule keeps its own target.
        if (r.target === "__system/cron_tick" && r.msg && r.msg.target)
          out.push({ target: r.msg.target, kind: "cron", key: r.key, msg: r.msg });
        else
          out.push({ target: r.target, kind: "schedule", key: r.key, msg: r.msg });
      } catch (_) { /* skip a non-JSON _sched row */ }
    }
  }
  return out;
}

/** Durable sends (`webhook.send`, and `email.send` which layers on it) armed by
 *  this activation — the parsed `_send/owed/{id}` marker ({url, method, body,
 *  on_result, context, …}), the durable artifact that actually replicates. */
function sentEffects(effects) {
  const out = [];
  for (const e of live(effects)) {
    if (e.kind === "write" && typeof e.key === "string" && e.key.startsWith("_send/owed/")) {
      try { const m = JSON.parse(e.value); out.push({ url: m.url, method: m.method, body: m.body, on: m.on_result, context: m.context }); }
      catch (_) { /* skip a non-JSON marker */ }
    }
  }
  return out;
}

/** Emails sent by this activation. `email.send` layers on `webhook.send`, so
 *  it's a `_send/owed/{id}` marker pointed at the Resend API — parse its request
 *  body back to a readable `{to, from, subject, cc, bcc}` (the Resend `to` is
 *  always an array). Only resend-url markers are emails; other durable sends are
 *  webhooks (read those with `toHaveSent("webhook", …)`). */
function emailSent(effects) {
  const out = [];
  for (const e of live(effects)) {
    if (e.kind === "write" && typeof e.key === "string" && e.key.startsWith("_send/owed/")) {
      try {
        const m = JSON.parse(e.value);
        if (m.url !== "https://api.resend.com/emails") continue;
        const b = JSON.parse(m.body);
        out.push({ to: b.to, from: b.from, subject: b.subject, cc: b.cc, bcc: b.bcc, on: m.on_result, context: m.context });
      } catch (_) { /* skip a non-JSON marker */ }
    }
  }
  return out;
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

// Split a durable-wake target `"module.method"` into module + optional export
// (handler-shape.md §2.4, issue #9). The method suffix is recognized ONLY when
// the module part ends in `.mjs`/`.js` — so a bare `"reports.mjs"`, a slash
// path, or a `__system/` module stays whole (default export). MUST match the
// worker's `splitDurableTarget` in `src/js/worker_streaming.zig`.
function splitDurableTarget(target) {
  const dot = target.lastIndexOf(".");
  if (dot < 0) return { module: target, method: null };
  const head = target.slice(0, dot);
  const tail = target.slice(dot + 1);
  if (tail.length > 0 && (head.endsWith(".mjs") || head.endsWith(".js")))
    return { module: head, method: tail };
  return { module: target, method: null };
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
    // Per-instance / root store seeds (read by platform.scope(id).kv /
    // platform.root). Seeded into the closed-world map under the same
    // `__rove_store/{tag}/` layout the base facades + host use at runtime.
    this.instances = cfg.instances || {}; // { "<id>": { kv: {…} } }
    this.rootKv = (cfg.root && cfg.root.kv) || {};
    // The operator root token `platform.auth.checkRootToken(t)` validates against
    // (env-supplied in prod). Carried as a hidden reserved kv key; unset → nothing
    // authenticates as root.
    this.rootToken = cfg.rootToken || null;
    // `platform.*` is admin-only (prod throws off the `__admin__` handler). Fail
    // closed: a run is admin only when opted in, so a non-admin handler that
    // touches `platform.*` throws — like prod. Carried as a hidden reserved key.
    this.admin = cfg.admin || false;
    // Per-chain identity the engine pins on EVERY activation (worker-set in
    // prod). `tenant` is this handler's tenant id; `correlationId` is minted by
    // inbound and inherited by every resume — so it's scenario-level (set once,
    // threads through inbound → frame → fetch/receive resumes, like the ctx). A
    // per-activation `inbound({ correlationId })` override is honored over these.
    this.tenant = cfg.tenant != null ? cfg.tenant : null;
    this.correlationId = cfg.correlationId != null ? cfg.correlationId : null;
    this.now = toMs(cfg.now);
    this.seed = cfg.seed || 0;
    this.entry = cfg.entry || "index.mjs";
  }

  /** Stamp the scenario's per-chain identity onto a world's `request`, without
   *  clobbering a per-activation override already present. */
  _stampIdentity(w) {
    if (this.tenant == null && this.correlationId == null) return w;
    const r = (w.request = w.request || {});
    if (this.tenant != null && r.tenant === undefined) r.tenant = this.tenant;
    if (this.correlationId != null && r.correlationId === undefined) r.correlationId = this.correlationId;
    return w;
  }

  _base(partial) {
    const kv = Object.assign({}, this.baseKv);
    for (const id of Object.keys(this.instances)) {
      const ikv = (this.instances[id] && this.instances[id].kv) || {};
      for (const k of Object.keys(ikv)) kv["__rove_store/i/" + id + "/" + k] = ikv[k];
    }
    for (const k of Object.keys(this.rootKv)) kv["__rove_store/r/" + k] = this.rootKv[k];
    if (this.rootToken) kv["__rove_store/auth/token"] = this.rootToken;
    if (this.admin) kv["__rove_store/admin"] = "1";
    const w = Object.assign(
      { entry: this.entry, seed: this.seed, now_ms: this.now, kv },
      partial,
    );
    if (this.sourceDir) w.source_dir = this.sourceDir;
    if (this.inlineSources) {
      w.sources = Object.keys(this.inlineSources).map((path) => ({
        path, kind: "handler", source: this.inlineSources[path],
      }));
    }
    return this._stampIdentity(w);
  }

  /** An inbound HTTP activation → the root node. If the app has a
   *  `_middlewares/index.mjs`, its real `before` runs first (it may set
   *  `request.auth` or short-circuit). `session` is injected (the worker
   *  resolves it from a cookie in prod — no code to run offline). */
  inbound(req = {}) {
    return new Node(this, this._base({
      activation: "inbound",
      request: {
        method: req.method || "GET",
        path: req.path || "/",
        host: req.host || "",
        headers: req.headers || {},
        // An AUTHORED bodyless request reads as empty in prod (request.text ===
        // "", 0-length bytes), NOT "missing" — so default to "" when the caller
        // omits `body`. (Only the initial authored activation; the replay path's
        // read-your-tape `miss()` is untouched, and a supplied body is kept.)
        body: req.body !== undefined ? req.body : "",
        ip: req.ip,
        session: req.session,
        // Per-activation override (undefined ⇒ inherit the scenario default).
        tenant: req.tenant,
        correlationId: req.correlationId,
      },
    }));
  }

  /** A headers-first inbound activation → the root node at `onHeaders`. The
   *  streaming-body trust boundary: the export runs BEFORE the body is accepted,
   *  so the only body-accepting move from here is `blob.receive({on})` then
   *  `return next()` (which opens the valve — resume the receive with
   *  `node.receive().stored({...})`). Same request surface as `inbound`
   *  (`_middlewares/before` runs first if the app has one); the export resolves
   *  to `onHeaders` via the `inbound_headers` kind. */
  inboundHeaders(req = {}) {
    const w = this._base({
      activation: "inbound_headers",
      request: {
        method: req.method || "GET",
        path: req.path || "/",
        host: req.host || "",
        headers: req.headers || {},
        // Empty (readable) payload by default — see `inbound`.
        body: req.body !== undefined ? req.body : "",
        ip: req.ip,
        session: req.session,
        tenant: req.tenant,
        correlationId: req.correlationId,
      },
    });
    // onHeaders normally carries no ctx; thread one only if the caller supplies
    // it (parity with the documented `{ ctx? }` surface).
    if (req.ctx !== undefined) w.ctx = req.ctx;
    return new Node(this, w);
  }

  /** A DETACHED durable delivery callback (`webhook.send` / `email.send` `on`),
   *  authored directly — NOT folded from an emitter. The send fires after the
   *  handler commits and its `on` module runs later as its own activation, so
   *  you test that module in isolation given a delivery result. Mirrors the
   *  flattened send_callback surface (dispatcher.zig): the response on
   *  `request.status`/`.bytes`, the echoed `ctx` bare on `request.ctx`,
   *  and delivery metadata on `request.activation.*`. `status` is the
   *  single success signal (2xx = delivered, 0 = never reached) — there
   *  is no `request.ok` (issue #7).
   *
   *  spec: { on: "<result-module path>", result?: {status, body?, attempts?,
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

  /** A bare fetch-continuation MODULE authored in isolation — the `on` module of
   *  an `after.fetch`/`http.fetch`, driven standalone given an upstream result
   *  (parallel to `sendCallback`, but the fetch-result surface rather than the
   *  send-callback one). The response lands flattened on `request.{status,
   *  done, body}` and the echoed `ctx` bare on `request.ctx` — the same shape a
   *  folded `FetchHandle.resolve` produces, so a `_rp/complete.mjs`-style module
   *  is testable without standing up the emitter that would reach it. `status`
   *  is the single success signal (2xx = ok, 0 = transport failure) — there is
   *  no `request.ok` (issue #7).
   *
   *  spec: { on: "<continuation module path>", ctx?: <echoed context>,
   *          status?, done?, body? }
   */
  fetchResult(spec = {}) {
    if (typeof spec.on !== "string")
      throw new Error("fetchResult({ on }): `on` must be the continuation module path");
    const status = spec.status != null ? spec.status : 200;
    const done = spec.done != null ? spec.done : true;
    // Mirror the bound-resume surface prod builds (globals.zig): chunkSeq /
    // fetchesPending / fetchId on every event; status/bodyTruncated
    // TERMINAL-only (defaulted only when done — an explicit spec still wins;
    // no `ok` — status is the single success signal, issue #7).
    const request = {
      done,
      body: spec.body != null ? spec.body : null,
      chunkSeq: spec.chunkSeq != null ? spec.chunkSeq : 0,
      fetchesPending: spec.fetchesPending != null ? spec.fetchesPending : 1,
    };
    if (spec.fetchId != null) request.fetchId = spec.fetchId;
    if (done || spec.status != null) request.status = status;
    if (done) request.bodyTruncated = spec.bodyTruncated != null ? spec.bodyTruncated : false;
    return new Node(this, this._base({
      entry: spec.on, // the continuation module IS this activation's entry
      activation: "fetch_chunk",
      export: "default",
      ctx: spec.ctx === undefined ? null : spec.ctx,
      request,
    }));
  }

  /** A DETACHED durable schedule/cron callback (`schedule(...)` / `cron(...)`
   *  target), authored directly — NOT folded from an emitter. A due schedule
   *  fires its `target` as a fresh `durable_wake` activation: connectionless,
   *  no held socket, surviving crashes and leader changes. So — like a
   *  `sendCallback` — you test that target module in isolation, given a fire.
   *
   *  Mirrors the runtime surface (globals.zig durable-wake block): the payload
   *  arrives on `request.ctx` (the one-ctx rule — the same slot every callback
   *  reads, NOT `request.activation.msg`), with delivery metadata on
   *  `request.activation.{kind, id, key, scheduledAtNs}`. `key` is present only
   *  when the schedule carried an idempotency key (`opts.key`) — omitted
   *  otherwise, matching the runtime and `schedule.get`. A recurring `cron`
   *  target fires the same way (via the baked `cron_tick`, which the customer
   *  never sees); each occurrence is one `wake(...)`.
   *
   *  `on` is the target as passed to `schedule`/`cron`: a bare module
   *  (`"jobs/reminder"` → `default` export) or the `module.method` form
   *  (`"reports.mjs.weekly"` → the `weekly` export — the method suffix is
   *  only recognized after a `.mjs`/`.js` module, issue #9). You may also
   *  split it explicitly with `method`.
   *
   *  spec: { on: "<target>", ctx?: <payload>, method?: "<export>",
   *          id?: "<schedule id>", key?: "<idempotency key>",
   *          scheduledAtNs?: <ns since epoch>, now?: <fire time> }
   */
  wake(spec = {}) {
    if (typeof spec.on !== "string")
      throw new Error("wake({ on }): `on` must be the scheduled target module path");
    // The fire happens AT/AFTER the scheduled time; run the activation with the
    // clock at the fire time so the target's `Date.now()` is deterministic.
    const fireMs = spec.now !== undefined ? toMs(spec.now) : this.now;
    const scheduledAtNs = spec.scheduledAtNs != null ? spec.scheduledAtNs : fireMs * 1_000_000;
    const activation = {
      kind: "durable_wake",
      // A fired schedule always carries its id; default a stable placeholder so
      // `request.activation.id` is the string a real target reads.
      id: spec.id != null ? spec.id : "sched_test",
      scheduledAtNs,
    };
    // Present only when the schedule was armed with an idempotency key.
    if (spec.key != null) activation.key = spec.key;
    // A `module.method` target (`on: "reports.mjs.weekly"`) resolves the same
    // way the worker fires it (splitDurableTarget); an explicit `spec.method`
    // wins for the split-out form (`on: "reports.mjs", method: "weekly"`).
    const _t = splitDurableTarget(spec.on);
    return new Node(this, this._base({
      entry: _t.module, // the scheduled target module IS this activation's entry
      activation: "durable_wake",
      // durable_wake dispatches at the target's default export (rpc_dispatch);
      // a `module.method` target overrides the export (issue #9).
      export: spec.method || _t.method || "default",
      ctx: spec.ctx === undefined ? null : spec.ctx,
      now_ms: fireMs,
      request: { activation },
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

  /** Post-state of another instance's isolated store (`platform.scope(id).kv`) —
   *  seeds via `scenario({ instances: { <id>: { kv } } })`, folded writes and
   *  all. Absent keys read `null`, like `kv()`. */
  instanceKv(id, key) {
    const eff = foldKv(this.world.kv, this.force().effects);
    const slot = "__rove_store/i/" + id + "/" + key;
    return slot in eff ? tryParse(eff[slot]) : null;
  }

  /** Post-state of the platform root store (`platform.root`) — seeds via
   *  `scenario({ root: { kv } })`. Absent keys read `null`. */
  rootKv(key) {
    const eff = foldKv(this.world.kv, this.force().effects);
    const slot = "__rove_store/r/" + key;
    return slot in eff ? tryParse(eff[slot]) : null;
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

  /** Drive ≥2 concurrently-outstanding `after.fetch`es (emitted by THIS held
   *  activation) whose results race — where an invariant must hold no matter
   *  which upstream responds first. `specs` is `[{ match, resolve?, label? }]`,
   *  one per outstanding fetch (`match` = url matcher, `resolve` = its response).
   *  `.forEachOrder(fn)` / `.invariant(project)` fold each arrival order,
   *  threading every resolution's writes into the next resume's overlay — so a
   *  leg that observes an earlier leg's write is expressible (which the
   *  single-parent `.fetch().resolve()` fold cannot do). See the class doc. */
  whenConcurrent(specs) {
    requireHeld(this, "whenConcurrent");
    if (!Array.isArray(specs) || specs.length < 2)
      throw new Error("whenConcurrent([...]): pass ≥2 {match, resolve} specs (one per racing effect)");
    return new Interleaving(this, specs);
  }

  /** Locate an emitted `blob.receive` (headers-first streamed upload) → a
   *  handle that resumes the held chain at its `on` export once the object is
   *  durable. `opts.on` selects a specific receive when several were armed;
   *  otherwise the first. Only meaningful on a held node (the handler armed the
   *  receive then `next()`d to open the body valve). */
  receive(opts = {}) {
    requireHeld(this, "receive");
    const rx = this.effects.filter((e) => e.kind === "blob" && e.op === "receive");
    if (!rx.length) throw new Error("receive(): the activation armed no blob.receive");
    const hit = opts.on ? rx.find((e) => e.on === opts.on) : rx[0];
    if (!hit) throw new Error(`receive({on:${opts.on}}): no armed blob.receive matched`);
    return new ReceiveHandle(this, hit);
  }

  /** Locate the `platform.compile` door this held activation armed (a bound
   *  after.fetch to `rove-compile.internal`) → a handle whose `.staged()`
   *  delivers the compile result on the resume's `request.ctx` (NOT
   *  `request.body`) — the `routeCompileEvent` contract (`deploy_thread.zig`
   *  §buildResultsJson). Parallel to `receive()`; a plain `fetch().resolve()`
   *  would hand the resume the fetch's ISSUE-TIME ctx instead of the door
   *  result. `opts.on` selects a specific compile when several were armed (e.g.
   *  a handler vs a package batch), otherwise the first. */
  compile(opts = {}) {
    requireHeld(this, "compile");
    const cx = this._byKind("fetch").filter((e) => matchUrl(e.url, /rove-compile\.internal/));
    if (!cx.length) throw new Error("compile(): the activation armed no platform.compile door");
    const hit = opts.on ? cx.find((e) => e.on === opts.on) : cx[0];
    if (!hit) throw new Error(`compile({on:${opts.on}}): no armed platform.compile matched`);
    return new CompileHandle(this, hit);
  }

  /** Locate the `platform.scope(t).deploy.stampManifest` staging barrier this
   *  held activation armed (a bound after.fetch to `rove-stage.internal`) → a
   *  handle whose `.cut()` delivers `{ok, dep_id}` on the resume's
   *  `request.ctx` — the `processManifestPut` contract (`deploy_thread.zig`).
   *  `opts.on` selects a specific stamp when several were armed. */
  stampManifest(opts = {}) {
    requireHeld(this, "stampManifest");
    const sx = this._byKind("fetch").filter((e) => matchUrl(e.url, /rove-stage\.internal/));
    if (!sx.length) throw new Error("stampManifest(): the activation armed no deploy.stampManifest door");
    const hit = opts.on ? sx.find((e) => e.on === opts.on) : sx[0];
    if (!hit) throw new Error(`stampManifest({on:${opts.on}}): no armed deploy.stampManifest matched`);
    return new StampHandle(this, hit);
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
   *  overlay (null = delete). The resume surfaces the FIRED PREFIXES — one
   *  `{kind:"kv", prefix, firedAt}` per armed `after.kv` a change key falls
   *  under, never the keys themselves (issue #8; the handler re-reads kv).
   *  `opts.prefix` selects which armed `after.kv`'s `{on}` export resumes
   *  when several are armed. */
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
    const keys = Object.keys(changes);
    for (const key of keys) {
      const v = changes[key];
      if (v === null) delete kv[key];
      else kv[key] = typeof v === "string" ? v : JSON.stringify(v);
    }
    // One entry per fired ARM, matching the worker (drainFired): an arm
    // fires when any change key starts with its prefix; N matches on one
    // arm surface once.
    const entries = armed
      .filter((e) => keys.some((k) => k.startsWith(e.prefix)))
      .map((e) => ({ kind: "kv", prefix: e.prefix, firedAt: now }));
    if (!entries.length)
      throw new Error(`wakeKv(): no change key falls under an armed after.kv prefix (armed: ${armed.map((e) => JSON.stringify(e.prefix)).join(", ")})`);
    return resumeNode(parent, carrySources(parent.world, {
      entry: parent.world.entry,
      activation: "wake_batch",
      export: kw.on || "onWake",
      ctx: heldCtx(parent),
      kv,
      seed: (parent.world.seed || 0) + 1,
      now_ms: now,
      request: { activation: { kind: "wake_batch", wakes: entries } },
    }));
  }

  /** The client disconnected while the connection was held → the `onDisconnect`
   *  resume (a held stream's terminal cleanup activation). */
  disconnect() {
    requireHeld(this, "disconnect");
    const parent = this;
    const pb = parent.force();
    return resumeNode(parent, carrySources(parent.world, {
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

/** The `request.ctx` a located `after.fetch`'s resume observes (decisions.md
 *  §4.14): the fetch's OWN ctx (`fx.ctx`) when it carried one, else the held
 *  chain's parked `next({ctx})` (`heldCtx(parent)`). One deterministic rule,
 *  matching the worker (`worker_streaming.fetchResumeCtx`) on both transports —
 *  so a no-ctx fetch on a held chain threads the connection's `next()` state. */
function fetchResumeCtx(parent, fx) {
  // `!= null` catches both undefined and the null the recorder stores for a
  // no-ctx fetch — matching the worker, which treats JSON "null" as absent.
  return fx.ctx != null ? fx.ctx : heldCtx(parent);
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
    return resumeNode(parent, carrySources(parent.world, {
      entry: parent.world.entry,
      activation: "wake_batch",
      export: t.on || "onWake",
      ctx: heldCtx(parent),
      kv: foldKv(parent.world.kv, pb.effects),
      seed: (parent.world.seed || 0) + 1,
      now_ms: now,
      request: { activation: { kind: "wake_batch", wakes: [{ kind: "timer", firedAt: now }] } },
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
    // A stream:true fetch never delivers one whole-body event in prod — it
    // arrives as per-chunk onFetchChunk events + a terminal done. Warn (a
    // passing record, visible in the run output) rather than fail: the fold
    // still works, but the offline shape diverges from what prod would send.
    if (this.fx.stream)
      record("warn: .resolve() on a streaming fetch (stream:true) — prod delivers per-chunk events; use .stream([...])", true, { url: this.fx.url });
    const world = fetchResumeWorld(
      parent.world, this.fx, response,
      foldKv(parent.world.kv, pb.effects),
      (parent.world.seed || 0) + 1,
      (parent.world.now_ms || 0) + (response.latencyMs || 1),
      fetchResumeCtx(parent, this.fx),
      armedFetches(parent),
    );
    return resumeNode(parent, world);
  }

  /** Deliver a STREAMED fetch (`after.fetch({ stream: true })`): one
   *  `fetch_chunk` resume per chunk (`done:false`, the chunk on
   *  `request.text`/`.bytes`), then a terminal empty `done:true` event — the
   *  shape `fetch_engine` emits (per-writeback chunks + a final empty). Each
   *  resume threads the fetch's ctx and folds the prior chunk's KV writes
   *  forward (read-your-writes across the stream), so an accumulate-in-kv
   *  handler reconstructs the body. Returns the terminal node (the one that
   *  responds). `chunks` are strings (or `{ binary }` bytes via `opts`).
   *  Assumes the handler re-holds (`next()`) between chunks until `done`. */
  stream(chunks, opts = {}) {
    // Prod only chunk-delivers a fetch issued with `stream: true` — one issued
    // without it arrives as a single whole-body onFetchResult, so streaming it
    // offline would pass a shape prod never sends. Fail loud (issue #24).
    if (!this.fx.stream)
      throw new Error(`stream(): this fetch was issued WITHOUT stream:true (${this.fx.url}) — prod delivers one whole-body result; use .resolve({...}) or issue the fetch with { stream: true }`);
    const parentNode = this.node;
    const pw = this.node.world;
    const fx = this.fx;
    const on = fx.on;
    const ctx = fetchResumeCtx(parentNode, fx);
    // The fetch stays pending through every chunk INCLUDING its terminal done
    // event (prod counts "including this one").
    const pending = opts.fetchesPending != null ? opts.fetchesPending : armedFetches(parentNode);
    let kv = foldKv(pw.kv, this.node.force().effects);
    let seed = pw.seed || 0;
    let now = pw.now_ms || 0;
    let node = null;
    // Prod's per-event activation bag stamps `byteOffset` — the cumulative
    // wire bytes BEFORE this chunk — and the parsed response headers on the
    // seq-0 event (globals.zig fetch_chunk arm); thread both so the offline
    // bag matches (`opts.headers` supplies the upstream's headers).
    let off = 0;
    const step = (body, done, seq) => {
      const t = onTarget(pw.entry, on, done ? "onFetchDone" : "onFetchChunk");
      // Prod stamps status/bodyTruncated ONLY on the terminal event
      // (globals.zig `if (fc.final)`); non-final chunks carry done/chunkSeq/
      // fetchId/fetchesPending + the payload, nothing else. No `ok` —
      // status is the single success signal (issue #7).
      const request = { done, chunkSeq: seq, body, fetchesPending: pending };
      const bag = { byteOffset: off };
      if (seq === 0 && opts.headers) bag.headers = opts.headers;
      request.activation = bag;
      off += byteLen(body);
      if (fx.id != null) request.fetchId = fx.id;
      if (done) {
        request.status = opts.status != null ? opts.status : 200;
        request.bodyTruncated = opts.bodyTruncated != null ? opts.bodyTruncated : false;
      }
      node = resumeNode(parentNode, carrySources(pw, {
        entry: t.entry,
        activation: "fetch_chunk",
        export: t.export,
        ctx,
        kv,
        seed: ++seed,
        now_ms: ++now,
        request,
      }));
      kv = foldKv(kv, node.force().effects); // thread writes to the next chunk
    };
    chunks.forEach((c, i) => step(c, false, i));
    step(null, true, chunks.length); // terminal empty done event
    return node;
  }

  /** Fork the shared prefix into one dependent node per response. */
  branch(responses) { return responses.map((r) => this.resolve(r)); }

  /** Iterate every case's dependent node (invariant-across-futures). */
  cases(responses) {
    const self = this;
    return { forEachPath(fn) { return responses.map((r) => fn(self.resolve(r))); } };
  }
}

/** A located `blob.receive` → resolve its completion into the dependent
 *  resume at the receive's `on` export. Parallel to `FetchHandle.resolve`: the
 *  parent's writes/ctx/clock fold forward; the completion arrives on
 *  `request.ctx` (NOT `request.body`) and durability on `request.status`
 *  (2xx = stored, 0 = failed; no `request.ok`, issue #7) — the exact
 *  `emitTerminal` contract (`blob_receive.zig`, which emits status 200/0):
 *    success → `request.ctx = { hash, len, app }`, `request.status === 200`
 *    failure → `request.ctx = { error, app }`,        `request.status === 0`
 *  where `app` echoes the issue-time ctx the caller threaded (recorded on the
 *  receive effect); the test may override it with `spec.app`. */
class ReceiveHandle {
  constructor(node, fx) { this.node = node; this.fx = fx; }

  /** Resume the held chain with the durable object. `spec`: `{ hash, len, ok?,
   *  app?, error? }`. `ok` defaults true; on `ok:false` nothing was stored, so
   *  `hash`/`len` are dropped and `error` (default "receive failed") rides ctx. */
  stored(spec = {}) {
    const parent = this.node;
    const pb = parent.force();
    const ok = spec.ok != null ? spec.ok : true;
    // `app` echoes the recorded issue-time ctx unless the caller overrides.
    const app = spec.app !== undefined ? spec.app
      : (this.fx.app !== undefined ? this.fx.app : null);
    const ctx = ok
      ? { hash: spec.hash, len: spec.len != null ? spec.len : 0, app }
      : { error: spec.error != null ? spec.error : "receive failed", app };
    const world = carrySources(parent.world, {
      entry: parent.world.entry,
      // Receive completions resume through the FetchEngine router (a bound
      // terminal event) — the same continuation shape as a fetch result.
      activation: "fetch_chunk",
      export: this.fx.on || "onStored",
      ctx,
      kv: foldKv(parent.world.kv, pb.effects),
      seed: (parent.world.seed || 0) + 1,
      now_ms: (parent.world.now_ms || 0) + 1,
      request: { status: ok ? 200 : 0, activation: { kind: "blob_stored" } },
    });
    return resumeNode(parent, world);
  }
}

/** A located `platform.compile` door → resolve its completion into the
 *  dependent resume at the door's `on` export. Like `ReceiveHandle`, the door
 *  is a BOUND fetch whose result rides `request.ctx` (NOT `request.body`): a
 *  compile is a fetch completion whose `ctx_json` is set, so it reuses the
 *  fetch-completion fold with the door JSON as ctx and a null body — the exact
 *  `routeCompileEvent` shape (`deploy_thread.zig`, terminal `UpstreamFetchEvent`):
 *  The compile OUTCOME rides `request.ctx.ok` (a door can HTTP-200 yet
 *  fail to compile); the door's HTTP status is `request.status` (no
 *  `request.ok`, issue #7):
 *    success → `request.ctx = { ok:true, results:[{path, source_hex,
 *              bytecode_hex}, …], app }`, `request.status === 200`
 *    failure → `request.ctx = { ok:false, status, error }`, `request.status === 500`
 *  where `app` echoes the issue-time `platform.compile(..., {ctx})` (recorded on
 *  the door fetch); the test may override it with `spec.app`. */
class CompileHandle {
  constructor(node, fx) { this.node = node; this.fx = fx; }

  /** Resume with the staged bytecode. `spec`: `{ results, ok?, app?, status?,
   *  error? }`. `ok` defaults true; on `ok:false` nothing was staged, so
   *  `results`/`app` are dropped and `{status, error}` ride ctx. */
  staged(spec = {}) {
    const parent = this.node;
    const pb = parent.force();
    const ok = spec.ok != null ? spec.ok : true;
    const status = spec.status != null ? spec.status : (ok ? 200 : 500);
    // `app` echoes the recorded issue-time on.fetch ctx unless overridden.
    const app = spec.app !== undefined ? spec.app
      : (this.fx.ctx != null ? this.fx.ctx : null);
    const ctx = ok
      ? { ok: true, results: spec.results != null ? spec.results : [], app }
      : { ok: false, status, error: spec.error != null ? spec.error : "compile failed" };
    const world = fetchResumeWorld(
      parent.world, this.fx, { status, body: null },
      foldKv(parent.world.kv, pb.effects),
      (parent.world.seed || 0) + 1,
      (parent.world.now_ms || 0) + 1,
      ctx,
      armedFetches(parent),
    );
    return resumeNode(parent, world);
  }
}

/** A located `deploy.stampManifest` staging barrier → resolve it into the
 *  dependent resume at the door's `on` export. The staging-barrier completion
 *  delivers `request.ctx = { ok, dep_id }` (`processManifestPut`), with no
 *  body — the same bound-fetch-with-ctx fold as `CompileHandle`. */
class StampHandle {
  constructor(node, fx) { this.node = node; this.fx = fx; }

  /** Resume with the cut release. `spec`: `{ dep_id, ok?, status? }`. `ok`
   *  defaults true; `dep_id` (16-hex) is echoed on ctx either way — a failed
   *  PUT still carries the dep_id the manifest would have taken. */
  cut(spec = {}) {
    const parent = this.node;
    const pb = parent.force();
    const ok = spec.ok != null ? spec.ok : true;
    const status = spec.status != null ? spec.status : (ok ? 200 : 502);
    const ctx = { ok, dep_id: spec.dep_id != null ? spec.dep_id : "0000000000000000" };
    const world = fetchResumeWorld(
      parent.world, this.fx, { status, body: null },
      foldKv(parent.world.kv, pb.effects),
      (parent.world.seed || 0) + 1,
      (parent.world.now_ms || 0) + 1,
      ctx,
      armedFetches(parent),
    );
    return resumeNode(parent, world);
  }
}

/** Concurrent-effect interleaving over a held node's multiple outstanding
 *  fetches. Each arrival ORDER is folded as an ordered chain: resolve the first
 *  effect against the parent's post-writes overlay, take THAT resume's folded kv
 *  as the base for the next effect, and so on — so a later leg reads the earlier
 *  leg's writes (read-your-writes ACROSS the race), the thing the single-parent
 *  `.fetch().resolve()` fold can't express. All effects are located on the
 *  parent (they were emitted together in the one held activation); only the kv
 *  overlay threads. Full factorial is exponential, so `forEachOrder` caps auto-
 *  enumeration at 5 legs — pass explicit orders via `.orders([...])` beyond that. */
class Interleaving {
  constructor(node, specs) { this.node = node; this.specs = specs; }

  _locate(match) {
    const fx = this.node.effects.filter((e) => e.kind === "fetch");
    const hit = fx.find((e) => matchUrl(e.url, match));
    if (!hit) {
      const seen = fx.map((f) => f.url).join(", ") || "none";
      throw new Error(`whenConcurrent: no emitted after.fetch matched ${match} (saw: ${seen})`);
    }
    return hit;
  }

  /** Fold the specs in one arrival order (array of spec indices) → terminal node. */
  _foldOrder(order) {
    const parent = this.node;
    const pb = parent.force();
    let kv = foldKv(parent.world.kv, pb.effects);
    let seed = parent.world.seed || 0;
    let now = parent.world.now_ms || 0;
    let node = parent;
    // Each arrival retires one outstanding fetch: the first leg sees every
    // armed fetch pending (including itself), the last sees only itself.
    let pending = armedFetches(parent);
    for (const i of order) {
      const spec = this.specs[i];
      const fx = this._locate(spec.match);
      node = resumeNode(parent, fetchResumeWorld(parent.world, fx, spec.resolve || {}, kv, ++seed, ++now, fetchResumeCtx(parent, fx), Math.max(pending, 1)));
      pending--;
      kv = foldKv(kv, node.force().effects); // thread this leg's writes to the next
    }
    return node;
  }

  _label(order) { return order.map((i) => (this.specs[i].label != null ? this.specs[i].label : i)); }

  /** All permutations of [0..n-1]. */
  _permutations() {
    const n = this.specs.length;
    if (n > 5) throw new Error(`whenConcurrent.forEachOrder: ${n} legs = ${n}! orders — pass explicit orders via .orders([[...], ...]) instead of blind enumeration`);
    const idx = Array.from({ length: n }, (_, i) => i);
    const out = [];
    const permute = (prefix, rest) => {
      if (!rest.length) { out.push(prefix); return; }
      for (let i = 0; i < rest.length; i++)
        permute(prefix.concat(rest[i]), rest.slice(0, i).concat(rest.slice(i + 1)));
    };
    permute([], idx);
    return out;
  }

  /** Resolve `orders` (arrays of spec indices OR label strings) to index arrays. */
  _resolveOrders(orders) {
    return orders.map((ord) => ord.map((step) => {
      if (typeof step === "number") return step;
      const i = this.specs.findIndex((sp) => sp.label === step);
      if (i < 0) throw new Error(`whenConcurrent: no spec labelled ${JSON.stringify(step)}`);
      return i;
    }));
  }

  /** Run `fn(terminalNode, orderLabels)` for every arrival order (all
   *  permutations). Returns the array of `fn` results (one per order). */
  forEachOrder(fn) {
    return this._permutations().map((order) => fn(this._foldOrder(order), this._label(order)));
  }

  /** Run only the caller-supplied `orders` (each an array of spec indices or
   *  labels) — for when the factorial is too large to enumerate blindly. */
  orders(orders) {
    return this._resolveOrders(orders).map((order) => this._foldOrder(order));
  }

  /** Invariant helper: `project(terminalNode)` must yield the SAME value under
   *  every arrival order. Records one streamed assertion (pass iff all orders
   *  agree), so a divergence fails the test with each order's value shown. */
  invariant(project, label) {
    const results = this._permutations().map((order) => ({ order, value: project(this._foldOrder(order)) }));
    const agree = results.every((r) => deepEq(r.value, results[0].value));
    return record("invariant" + (label ? " " + label : ""), agree, {
      values: results.map((r) => ({ order: this._label(r.order), value: r.value })),
    });
  }
}

function carrySources(parentWorld, world) {
  if (parentWorld.source_dir) world.source_dir = parentWorld.source_dir;
  if (parentWorld.sources) world.sources = parentWorld.sources;
  // Per-chain identity (tenant / correlation_id) threads to every resume, like
  // the connection ctx — inbound mints, resumes inherit. The parent world always
  // carries it (stamped at construction), so copy it into the resume's request.
  const pr = parentWorld.request || {};
  if (pr.tenant !== undefined || pr.correlationId !== undefined) {
    const r = (world.request = world.request || {});
    if (pr.tenant !== undefined && r.tenant === undefined) r.tenant = pr.tenant;
    if (pr.correlationId !== undefined && r.correlationId === undefined) r.correlationId = pr.correlationId;
  }
  return world;
}

/** Build a resume node that PRESERVES a WS connection. When the parent
 *  activation is part of a WS chain (a `WsNode`), the fetch/timer/kv/receive
 *  resume is itself a `WsNode` bound to the same connection — so `.receive(next
 *  frame)` continues the conversation past the resume (the agent-loop shape:
 *  onMessage → fetch → onLLM → next frame). Its `.receive` folds THIS resume's
 *  ctx + writes forward, exactly like frame-to-frame. A non-WS resume stays a
 *  plain `Node`. */
function resumeNode(parent, world) {
  return parent instanceof WsNode
    ? new WsNode(parent.scenario, world, parent._conn)
    : new Node(parent.scenario, world);
}

/** Resolve a continuation `on` to its `{entry, export}`. A bare name (no `/`,
 *  not `.mjs`) is an export in the SAME module — the common case (admin's
 *  `onFetchResult` / agent's `onLLM`), so `entry` stays the parent's and the
 *  name is the export. A module PATH (`hooks/onX.mjs`) names a DIFFERENT file
 *  reached only as a continuation (admin's `_rp/jwks.mjs`), so that file becomes
 *  the entry, invoked at its `default` export — mirroring how `sendCallback` /
 *  `wake` set `entry: spec.on`. */
function onTarget(parentEntry, on, fallbackExport) {
  if (typeof on === "string" && (on.includes("/") || on.endsWith(".mjs")))
    return { entry: on, export: "default" };
  return { entry: parentEntry, export: on || fallbackExport };
}

/** Build the `fetch_chunk` resume world for a located fetch effect against an
 *  EXPLICIT kv/seed/now base — the shared core of `FetchHandle.resolve` and the
 *  `whenConcurrent` interleaving fold (which threads a running overlay through a
 *  chosen arrival order rather than always folding from the one parent). */
function fetchResumeWorld(parentWorld, fx, response, kvBase, seed, now, ctx, pending) {
  const status = response.status != null ? response.status : (response.timeout ? 0 : 200);
  const done = response.done != null ? response.done : true;
  const t = onTarget(parentWorld.entry, fx.on, "onFetchResult");
  const request = {
    done,
    body: response.body != null ? response.body : null,
    // Prod stamps chunkSeq + fetchesPending on EVERY bound fetch event, and the
    // ftch_ id the arm returned (globals.zig) — thread the recorded id so the
    // documented correlate-by-id and `done && fetchesPending === 1` patterns
    // work offline (issue #24).
    chunkSeq: response.chunkSeq != null ? response.chunkSeq : 0,
    fetchesPending: response.fetchesPending != null ? response.fetchesPending
      : (pending != null ? pending : 1),
  };
  if (fx.id != null) request.fetchId = fx.id;
  // status/bodyTruncated are TERMINAL-only in prod (set iff `final`,
  // globals.zig) — default them only on the final event; honor an explicit
  // override so a deliberate off-spec world stays authorable. `status` is
  // the single success signal (2xx = ok, 0 = transport failure — here
  // `response.timeout`); the real engine surfaces NO `request.ok` (issue #7).
  if (done || response.status != null) request.status = status;
  if (done) request.bodyTruncated = response.bodyTruncated != null ? response.bodyTruncated : false;
  // Prod's seq-0 activation bag carries the upstream's parsed headers
  // (globals.zig fetch_chunk arm) — a whole-body resolve IS the seq-0 event.
  if (response.headers) request.activation = { headers: response.headers };
  return carrySources(parentWorld, {
    entry: t.entry,
    activation: "fetch_chunk",
    export: t.export,
    // §4.14 override, resolved by the caller (fetchResumeCtx): the fetch's own
    // ctx if it carried one, else the held chain's next() ctx.
    ctx: ctx === undefined ? null : ctx,
    kv: kvBase,
    seed,
    now_ms: now,
    request,
  });
}

/** Bound fetches a node armed that are still outstanding — prod's
 *  `request.fetchesPending` base ("including this one"). Rolled-back arms never
 *  issued, so they don't count. */
function armedFetches(node) {
  return live(node.force().effects).filter((e) => e.kind === "fetch").length;
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
    // The frame IS the request payload: `request.text` is the frame text
    // regardless of opcode (the runtime contract `browser.message()` reads), and
    // a binary frame's `request.bytes` is the decoded bytes. Deliver it as the
    // body (a binary frame rides base64 → request.bytes, like activation.dataB64);
    // `activation.data` carries it too, so handlers read either.
    const req = binary
      ? { activation, bodyB64: b64(data) }
      : { activation, body: String(data) };
    const world = this.scenario._base({
      entry: this.scenario.entry,
      activation: "ws_message",
      export: "onMessage",
      ctx,
      kv,
      seed: seed + 1,
      request: req,
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
    // Tenant store only — a `platform.scope(id)` / `platform.root` write carries
    // a `store` tag and is asserted with `instanceKv(id, …)` / `rootKv(…)`.
    // Rolled-back writes (thrown handler) never commit in prod, so they never
    // satisfy the matcher.
    const writes = live(node.effects).filter((e) => e.kind === "write" && e.key === key && !e.store);
    const pass = writes.some((w) => subsetMatch(tryParse(w.value), subset));
    return this._record(`toHaveWritten ${fmt(key)}`, pass, {
      subset: subset === undefined ? null : subset,
      writes: writes.map((w) => ({ key: w.key, value: tryParse(w.value) })),
    });
  }

  toHaveFetched(matcher) {
    const node = this._node("toHaveFetched");
    if (!node) return false;
    const fx = live(node.effects).filter((e) => e.kind === "fetch");
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
    // `webhook`/`email` read through effect VIEWS over the durable `_send/owed`
    // marker the real shims produce (email layers on webhook, so it's a
    // resend-url marker). Other kinds (blob/…) match the raw effect entry.
    const sent = kind === "webhook"
      ? sentEffects(node.effects)
      : kind === "email"
      ? emailSent(node.effects)
      : live(node.effects).filter((e) => e.kind === kind);
    const pass = sent.some((e) => subsetMatch(e, subset));
    return this._record(`toHaveSent ${fmt(kind)}`, pass, { subset: subset === undefined ? null : subset, sent });
  }

  toHaveScheduled(matcher) {
    const node = this._node("toHaveScheduled");
    if (!node) return false;
    const sch = scheduledEffects(node.effects);
    const pass = sch.some((e) => matcher == null || matchUrl(e.target, matcher));
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
 *  and the writes/cmds from the effect log (logs + reads excluded — noisy;
 *  rolled-back entries excluded — they never commit in prod). */
function snapshotFacets(b) {
  const cmds = live(b.effects).filter((e) =>
    e.kind !== "read" && e.kind !== "log");
  return {
    response: b.response || null,
    disposition: b.disposition,
    body: b.disposition === "held" ? b.ctx : (b.body === undefined ? null : b.body),
    effects: cmds,
    ok: b.ok,
  };
}
